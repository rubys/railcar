# Emitter: Crystal AST → Elixir source code.
#
# Walks Crystal AST nodes and emits Elixir.
# Two entry points:
#   emit_model      — ClassDef → defmodule with module functions
#   emit_controller — Expressions (list of Defs) → controller module functions
#
# Shared emit_stmt / emit_value / emit_call handle Elixir syntax.

require "compiler/crystal/syntax"
require "../../generator/inflector"
require "../../generator/schema_extractor"

module Railcar
  module Cr2Ex
    class Emitter
      getter app_module : String

      def initialize(@app_module)
      end

      # ── Model emission ──

      def emit_model(node : Crystal::ClassDef, class_name : String, schema : TableSchema) : String
        io = IO::Memory.new
        singular = Inflector.underscore(class_name)
        table_name = Inflector.pluralize(singular)
        columns = schema.columns.reject { |c| c.name == "id" }.map { |c| ":#{c.name}" }

        io << "defmodule #{app_module}.#{class_name} do\n"
        io << "  use Railcar.Record, table: #{table_name.inspect}, columns: [#{columns.join(", ")}]\n"

        # Walk AST for methods
        body = case node.body
               when Crystal::Expressions then node.body.as(Crystal::Expressions).expressions
               else [node.body]
               end

        body.each do |expr|
          case expr
          when Crystal::Def
            io << "\n"
            emit_model_method(expr, io, class_name)
          end
        end

        io << "\nend\n"
        io.to_s
      end

      private def emit_model_method(defn : Crystal::Def, io : IO, class_name : String)
        case defn.name
        when "run_validations"
          emit_validations(defn, io)
        when "delete"
          emit_delete_override(defn, io, class_name)
        when "after_save", "after_delete"
          emit_callback(defn, io)
        else
          emit_module_function(defn, io)
        end
      end

      private def emit_module_function(defn : Crystal::Def, io : IO)
        # The filter already added "record" as first arg
        params = defn.args.map(&.name)
        params = ["record"] if params.empty?
        io << "  def #{defn.name}(#{params.join(", ")}) do\n"
        emit_body(defn.body, io, "    ")
        io << "  end\n"
      end

      private def emit_validations(defn : Crystal::Def, io : IO)
        io << "  def run_validations(record) do\n"
        io << "    errors = []\n"
        walk_validation_calls(defn.body, io)
        io << "    errors\n"
        io << "  end\n"
      end

      private def walk_validation_calls(node : Crystal::ASTNode, io : IO)
        case node
        when Crystal::Expressions
          node.expressions.each { |e| walk_validation_calls(e, io) }
        when Crystal::Call
          if node.obj.is_a?(Crystal::Path)
            path = node.obj.as(Crystal::Path)
            if path.names == ["Railcar", "Validation"]
              emit_validation_line(node, io)
              return
            end
          end
        end
      end

      private def emit_validation_line(node : Crystal::Call, io : IO)
        name = node.name
        args_str = node.args.map { |a| emit_value(a) }.join(", ")
        named_str = ""
        if named = node.named_args
          named_parts = named.map { |na| "#{na.name}: #{emit_value(na.value)}" }
          named_str = ", " + named_parts.join(", ") unless named_parts.empty?
        end
        io << "    errors = errors ++ Railcar.Validation.#{name}(#{args_str}#{named_str})\n"
      end

      private def emit_delete_override(defn : Crystal::Def, io : IO, class_name : String)
        io << "  def delete(record) do\n"

        body = case defn.body
               when Crystal::Expressions then defn.body.as(Crystal::Expressions).expressions
               else [defn.body]
               end

        body.each do |expr|
          case expr
          when Crystal::Call
            name = expr.name
            if name == "super"
              io << "    super(record)\n"
            else
              # Association call: comments(record) — from the filter
              # Emit as: assoc(record) |> Enum.each(&Module.delete/1)
              assoc_name = name
              target = Inflector.classify(Inflector.singularize(assoc_name))
              io << "    #{assoc_name}(record) |> Enum.each(&#{app_module}.#{target}.delete/1)\n"
            end
          end
        end

        io << "  end\n"
      end

      private def emit_callback(defn : Crystal::Def, io : IO)
        io << "  def #{defn.name}(record) do\n"
        emit_body(defn.body, io, "    ")
        io << "    :ok\n"
        io << "  end\n"
      end

      # ── Controller emission ──

      def emit_controller_function(defn : Crystal::Def, io : IO)
        io << "  def #{defn.name}(conn) do\n"
        emit_body(defn.body, io, "    ")
        io << "  end\n\n"
      end

      # ── Shared body/statement/expression emission ──

      def emit_body(node : Crystal::ASTNode, io : IO, indent : String)
        case node
        when Crystal::Expressions
          node.expressions.each do |e|
            next if e.is_a?(Crystal::Nop)
            emit_stmt(e, io, indent)
          end
        when Crystal::Nop
          # empty
        else
          emit_stmt(node, io, indent)
        end
      end

      def emit_stmt(node : Crystal::ASTNode, io : IO, indent : String)
        case node
        when Crystal::Assign
          target = emit_value(node.target)
          value = emit_value(node.value)
          io << "#{indent}#{target} = #{value}\n"

        when Crystal::If
          emit_if(node, io, indent)

        when Crystal::Call
          # Special: redirect pipe chain
          if node.name == "__redirect_pipe__"
            emit_redirect_pipe(node, io, indent)
          else
            io << "#{indent}#{emit_value(node)}\n"
          end

        when Crystal::Return
          if exp = node.exp
            io << "#{indent}#{emit_value(exp)}\n"
          end

        when Crystal::Nop
          # skip

        else
          io << "#{indent}# TODO: #{node.class.name}\n"
        end
      end

      private def emit_redirect_pipe(node : Crystal::Call, io : IO, indent : String)
        path = node.args.first? ? emit_value(node.args.first) : "\"/\""
        io << "#{indent}conn |> put_resp_header(\"location\", #{path}) |> send_resp(302, \"\")\n"
      end

      private def emit_if(node : Crystal::If, io : IO, indent : String)
        # Check for case-result pattern (create/update → case do {:ok}/{:error})
        if case_call = detect_case_result(node)
          emit_case_result(case_call, node, io, indent)
        else
          io << "#{indent}if #{emit_value(node.cond)} do\n"
          emit_body(node.then, io, indent + "  ")
          if node.else && !node.else.is_a?(Crystal::Nop)
            io << "#{indent}else\n"
            emit_body(node.else, io, indent + "  ")
          end
          io << "#{indent}end\n"
        end
      end

      private def detect_case_result(node : Crystal::If) : Crystal::Call?
        cond = node.cond
        if cond.is_a?(Crystal::Call)
          call = cond.as(Crystal::Call)
          if {"save", "update", "create"}.includes?(call.name)
            return call
          end
        end
        nil
      end

      private def emit_case_result(call : Crystal::Call, if_node : Crystal::If, io : IO, indent : String)
        call_str = emit_value(call)

        # Determine variable name from the model being created/updated
        # Extract singular name from call path: Blog.Article.create → article
        model_singular = extract_model_singular(call)

        # Check if the result is actually used in the branches
        ok_var = result_var_used?(if_node.then, model_singular) ? model_singular : "_#{model_singular}"
        err_var = result_var_used?(if_node.else, model_singular) ? model_singular : "_errors"

        io << "#{indent}case #{call_str} do\n"
        io << "#{indent}  {:ok, #{ok_var}} -> #{emit_single_line_or_block(if_node.then, indent + "    ")}"
        if if_node.else && !if_node.else.is_a?(Crystal::Nop)
          io << "#{indent}  {:error, #{err_var}} -> #{emit_single_line_or_block(if_node.else, indent + "    ")}"
        end
        io << "#{indent}end\n"
      end

      # Extract singular model name from a call like Blog.Article.create(...)
      private def extract_model_singular(call : Crystal::Call) : String
        if obj = call.obj
          case obj
          when Crystal::Path
            class_name = obj.as(Crystal::Path).names.last
            Inflector.underscore(class_name)
          else
            "result"
          end
        else
          "result"
        end
      end

      # Check if a variable name is referenced in a branch
      private def result_var_used?(node : Crystal::ASTNode, var_name : String) : Bool
        # Check render_view (uses var as assigns) or redirect with path helper using var
        case node
        when Crystal::Expressions
          node.expressions.any? do |e|
            node_references_var?(e, var_name)
          end
        else
          node_references_var?(node, var_name)
        end
      end

      # Recursively check if an AST node references a variable by name
      private def node_references_var?(node : Crystal::ASTNode, var_name : String) : Bool
        case node
        when Crystal::Var
          node.name == var_name
        when Crystal::Call
          # Check args and receiver
          return true if node.args.any? { |a| node_references_var?(a, var_name) }
          return true if node.obj && node_references_var?(node.obj.not_nil!, var_name)
          false
        when Crystal::Expressions
          node.expressions.any? { |e| node_references_var?(e, var_name) }
        else
          false
        end
      end

      # Emit a branch as single-line (after ->) or multi-line block
      private def emit_single_line_or_block(node : Crystal::ASTNode, indent : String) : String
        stmts = case node
                when Crystal::Expressions
                  node.as(Crystal::Expressions).expressions.reject(&.is_a?(Crystal::Nop))
                else
                  [node]
                end

        if stmts.size == 1
          io = IO::Memory.new
          emit_stmt(stmts.first, io, "")
          io.to_s
        else
          io = IO::Memory.new
          io << "\n"
          stmts.each { |s| emit_stmt(s, io, indent) }
          io.to_s
        end
      end

      # ── Expression emission ──

      def emit_value(node : Crystal::ASTNode) : String
        case node
        when Crystal::Var
          node.name
        when Crystal::InstanceVar
          "record.#{node.name.lchop("@")}"
        when Crystal::Path
          node.names.join(".")
        when Crystal::StringLiteral
          node.value.inspect
        when Crystal::StringInterpolation
          parts = node.expressions.map do |expr|
            case expr
            when Crystal::StringLiteral then expr.value
            else "\#{#{emit_value(expr)}}"
            end
          end
          "\"#{parts.join}\""
        when Crystal::NumberLiteral
          node.value.to_s.gsub(/_i64|_i32/, "")
        when Crystal::NilLiteral
          "nil"
        when Crystal::BoolLiteral
          node.value.to_s
        when Crystal::SymbolLiteral
          ":#{node.value}"
        when Crystal::ArrayLiteral
          "[#{node.elements.map { |e| emit_value(e) }.join(", ")}]"
        when Crystal::HashLiteral
          entries = node.entries.map do |e|
            if e.key.is_a?(Crystal::SymbolLiteral)
              "#{e.key.as(Crystal::SymbolLiteral).value}: #{emit_value(e.value)}"
            else
              "#{emit_value(e.key)} => #{emit_value(e.value)}"
            end
          end
          "%{#{entries.join(", ")}}"
        when Crystal::Call
          emit_call(node)
        when Crystal::Not
          "!#{emit_value(node.exp)}"
        when Crystal::And
          "#{emit_value(node.left)} && #{emit_value(node.right)}"
        when Crystal::Or
          "#{emit_value(node.left)} || #{emit_value(node.right)}"
        when Crystal::IsA
          emit_is_a(node)
        when Crystal::Cast
          emit_value(node.obj)
        when Crystal::Expressions
          if node.expressions.size > 0
            emit_value(node.expressions.last)
          else
            "nil"
          end
        else
          "# TODO: #{node.class.name}"
        end
      end

      private def emit_is_a(node : Crystal::IsA) : String
        type_name = node.const.to_s
        obj = emit_value(node.obj)
        case type_name
        when "Nil", "NilClass" then "is_nil(#{obj})"
        when "String"          then "is_binary(#{obj})"
        else                        "is_struct(#{obj}, #{type_name})"
        end
      end

      private def emit_call(node : Crystal::Call) : String
        name = node.name
        obj = node.obj
        args = node.args.map { |a| emit_value(a) }

        # Handle named args
        if named = node.named_args
          named.each do |na|
            args << "#{na.name}: #{emit_value(na.value)}"
          end
        end

        # Special cases
        case name
        when "nil?"
          obj_str = obj ? emit_value(obj) : "record"
          return "is_nil(#{obj_str})"
        when "empty?"
          obj_str = obj ? emit_value(obj) : "record"
          return "#{obj_str} == \"\" || is_nil(#{obj_str})"
        when "size", "length"
          obj_str = obj ? emit_value(obj) : ""
          return "String.length(#{obj_str})"
        when "to_s"
          return obj ? "to_string(#{emit_value(obj)})" : "to_string()"
        when "to_i"
          return obj ? "String.to_integer(#{emit_value(obj)})" : "String.to_integer()"
        when "[]"
          obj_str = obj ? emit_value(obj) : ""
          return "#{obj_str}[#{args.first? || ""}]"
        when "<", ">", "<=", ">=", "==", "!="
          left = obj ? emit_value(obj) : ""
          right = args.first? || "0"
          return "#{left} #{name} #{right}"
        when "+"
          left = obj ? emit_value(obj) : ""
          right = args.first? || "0"
          return "#{left} + #{right}"
        when "++"
          left = obj ? emit_value(obj) : ""
          right = args.first? || "[]"
          return "#{left} ++ #{right}"
        when "empty_struct"
          # %Blog.Article{} — empty struct literal
          obj_str = obj ? emit_value(obj) : ""
          return "%#{obj_str}{}"
        when "render_view"
          # Helpers.render_view(conn, "template", var, status?)
          return emit_render_view_call(node)
        when "__redirect_pipe__"
          path = args.first? || "\"/\""
          return "conn |> put_resp_header(\"location\", #{path}) |> send_resp(302, \"\")"
        end

        # Generic call
        if obj
          obj_str = emit_value(obj)
          if args.empty? && is_property_access?(name)
            "#{obj_str}.#{name}"
          else
            "#{obj_str}.#{name}(#{args.join(", ")})"
          end
        else
          "#{name}(#{args.join(", ")})"
        end
      end

      # Fields/properties that should not have () in Elixir
      private def is_property_access?(name : String) : Bool
        # Struct field names and known Plug.Conn properties
        ELIXIR_PROPERTIES.includes?(name) ||
          name.ends_with?("_id") ||
          name.ends_with?("_at") ||
          name == "id"
      end

      ELIXIR_PROPERTIES = %w[
        id path_params body_params params query_params
        host port method path scheme
        title body name commenter
        created_at updated_at
        errors persisted
      ]

      private def emit_render_view_call(node : Crystal::Call) : String
        args = node.args
        # args: [conn, template_string, var_for_assigns, optional_status]
        conn_str = args.size > 0 ? emit_value(args[0]) : "conn"
        template = args.size > 1 ? emit_value(args[1]) : "\"\""
        var_name = args.size > 2 && args[2].is_a?(Crystal::Var) ? args[2].as(Crystal::Var).name : "assigns"

        # Format as: Helpers.render_view(conn, "template", [{:var, var}], status?)
        assigns = "[{:#{var_name}, #{var_name}}]"
        status_str = args.size > 3 ? ", #{emit_value(args[3])}" : ""

        "Helpers.render_view(#{conn_str}, #{template}, #{assigns}#{status_str})"
      end
    end
  end
end
