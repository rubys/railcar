# Emitter: Crystal AST → TypeScript source code.
#
# Walks typed Crystal AST nodes and emits TypeScript.
# Used by the TypeScript generator after shared filters and
# program.semantic() have been applied.
#
# Currently handles model emission:
#   - ClassDef with static TABLE, COLUMNS, tableName()
#   - Instance variable declarations → declare prop: type
#   - Method definitions → method signatures with TypeScript types
#   - Validations, associations, dependent destroy

require "compiler/crystal/syntax"

module Railcar
  module Cr2Ts
    class Emitter
      # Crystal type → TypeScript type mapping
      CRYSTAL_TO_TS = {
        "String"  => "string",
        "Int32"   => "number",
        "Int64"   => "number",
        "Float32" => "number",
        "Float64" => "number",
        "Bool"    => "boolean",
        "Nil"     => "null",
      }

      def emit_model(node : Crystal::ClassDef, class_name : String) : String
        io = IO::Memory.new

        io << "export class #{class_name} extends ApplicationRecord {\n"

        body = case node.body
               when Crystal::Expressions then node.body.as(Crystal::Expressions).expressions
               else [node.body]
               end

        # Separate node types for ordered emission
        table_assign = nil
        columns_assign = nil
        table_name_def = nil
        ivar_decls = [] of Crystal::TypeDeclaration | Crystal::Assign
        method_defs = [] of Crystal::Def
        other = [] of Crystal::ASTNode

        body.each do |expr|
          case expr
          when Crystal::Assign
            target_name = case expr.target
                          when Crystal::Path then expr.target.as(Crystal::Path).names.last
                          when Crystal::Var then expr.target.as(Crystal::Var).name
                          else ""
                          end
            case target_name
            when "TABLE"   then table_assign = expr
            when "COLUMNS" then columns_assign = expr
            else ivar_decls << expr
            end
          when Crystal::TypeDeclaration
            ivar_decls << expr
          when Crystal::InstanceVar
            # @var : Type = default — handled as ivar decl
            ivar_decls << Crystal::Assign.new(expr, Crystal::Nop.new)
          when Crystal::Def
            if expr.name == "self.table_name" || (expr.receiver.is_a?(Crystal::Var) && expr.receiver.as(Crystal::Var).name == "self" && expr.name == "table_name")
              table_name_def = expr
            else
              method_defs << expr
            end
          else
            other << expr
          end
        end

        # Static TABLE
        if table_assign
          value = emit_expr(table_assign.as(Crystal::Assign).value)
          io << "  static override TABLE = #{value};\n"
        end

        # Static COLUMNS
        if columns_assign
          value = emit_expr(columns_assign.as(Crystal::Assign).value)
          io << "  static override COLUMNS = #{value};\n"
        end

        io << "\n" if table_assign || columns_assign

        # Static tableName()
        if table_name_def
          ret_type = map_return_type(table_name_def.as(Crystal::Def).return_type)
          ret_val = extract_return_value(table_name_def.as(Crystal::Def).body)
          io << "  static override tableName()#{ret_type} { return #{ret_val}; }\n\n"
        end

        # Instance variable declarations → declare prop: type
        ivar_decls.each do |decl|
          case decl
          when Crystal::Assign
            target = decl.target
            if target.is_a?(Crystal::InstanceVar)
              name = target.name.lchop("@")
              # Find type from node annotation if present
              ts_type = infer_ivar_type(decl)
              io << "  declare #{name}: #{ts_type};\n"
            end
          when Crystal::TypeDeclaration
            name = decl.var.to_s.lchop("@")
            ts_type = map_type(decl.declared_type)
            io << "  declare #{name}: #{ts_type};\n"
          end
        end
        io << "\n" unless ivar_decls.empty?

        # Method definitions
        method_defs.each do |defn|
          emit_method(defn, io, class_name)
          io << "\n"
        end

        io << "}\n"
        io << "MODEL_REGISTRY[\"#{class_name}\"] = #{class_name};\n"

        io.to_s
      end

      private def emit_method(defn : Crystal::Def, io : IO, class_name : String)
        name = ts_method_name(defn.name)
        ret_type = map_return_type(defn.return_type)
        is_override = {"runValidations", "destroy"}.includes?(name)
        override = is_override ? "override " : ""
        needs_return = ret_type != ": void"

        io << "  #{override}#{name}()#{ret_type} {\n"
        emit_method_body(defn.body, io, class_name, indent: 2, implicit_return: needs_return)
        io << "  }\n"
      end

      private def emit_method_body(node : Crystal::ASTNode, io : IO, class_name : String,
                                    indent : Int32 = 2, implicit_return : Bool = false)
        prefix = "  " * indent
        case node
        when Crystal::Expressions
          node.expressions.each_with_index do |expr, i|
            is_last = (i == node.expressions.size - 1) && implicit_return
            emit_method_body(expr, io, class_name, indent: indent, implicit_return: is_last)
          end
        when Crystal::If
          cond = emit_condition(node.cond)
          io << "#{prefix}if (#{cond}) {\n"
          emit_method_body(node.then, io, class_name, indent: indent + 1)
          if node.else && !node.else.is_a?(Crystal::Nop)
            if node.else.is_a?(Crystal::If)
              io << "#{prefix}} else "
              emit_if_chain(node.else.as(Crystal::If), io, class_name, indent)
            else
              io << "#{prefix}} else {\n"
              emit_method_body(node.else, io, class_name, indent: indent + 1)
              io << "#{prefix}}\n"
            end
          else
            io << "#{prefix}}\n"
          end
        when Crystal::Call
          ret = implicit_return ? "return " : ""
          io << "#{prefix}#{ret}#{emit_call(node, class_name)};\n"
        when Crystal::Return
          if node.exp
            io << "#{prefix}return #{emit_expr(node.exp.not_nil!)};\n"
          else
            io << "#{prefix}return;\n"
          end
        when Crystal::Assign
          target = emit_expr(node.target)
          value = emit_expr(node.value)
          io << "#{prefix}#{target} = #{value};\n"
        when Crystal::ExceptionHandler
          # begin/rescue → try/catch
          io << "#{prefix}try {\n"
          emit_method_body(node.body, io, class_name, indent: indent + 1)
          io << "#{prefix}} catch (e) {\n"
          if node.rescues && !node.rescues.not_nil!.empty?
            emit_method_body(node.rescues.not_nil!.first.body, io, class_name, indent: indent + 1)
          end
          io << "#{prefix}}\n"
        when Crystal::Nop
          # skip
        else
          io << "#{prefix}#{emit_expr(node)};\n"
        end
      end

      private def emit_if_chain(node : Crystal::If, io : IO, class_name : String, indent : Int32)
        prefix = "  " * indent
        cond = emit_condition(node.cond)
        io << "if (#{cond}) {\n"
        emit_method_body(node.then, io, class_name, indent: indent + 1)
        if node.else && !node.else.is_a?(Crystal::Nop)
          if node.else.is_a?(Crystal::If)
            io << "#{prefix}} else "
            emit_if_chain(node.else.as(Crystal::If), io, class_name, indent)
          else
            io << "#{prefix}} else {\n"
            emit_method_body(node.else, io, class_name, indent: indent + 1)
            io << "#{prefix}}\n"
          end
        else
          io << "#{prefix}}\n"
        end
      end

      private def emit_condition(node : Crystal::ASTNode) : String
        case node
        when Crystal::Call
          if node.name == "nil?"
            obj = node.obj ? emit_expr(node.obj.not_nil!) : "this"
            return "#{obj} == null"
          end
          if node.name == "is_a?"
            obj = node.obj ? emit_expr(node.obj.not_nil!) : "this"
            type_arg = node.args.first?.try { |a| a.to_s } || "Object"
            return "typeof #{obj} === \"#{ts_typeof(type_arg)}\""
          end
          if node.name == "empty?" && node.obj
            obj = emit_expr(node.obj.not_nil!)
            return "!#{obj}"
          end
          if node.name == "<" || node.name == ">" || node.name == "<=" || node.name == ">="
            left = node.obj ? emit_expr(node.obj.not_nil!) : ""
            right = node.args.first? ? emit_expr(node.args.first) : ""
            return "#{left} #{node.name} #{right}"
          end
          if node.name == "size" && node.obj
            return "#{emit_expr(node.obj.not_nil!)}.length"
          end
          emit_call(node, "")
        when Crystal::Not
          inner = emit_condition(node.exp)
          "!(#{inner})"
        when Crystal::And
          "#{emit_condition(node.left)} && #{emit_condition(node.right)}"
        when Crystal::Or
          "#{emit_condition(node.left)} || #{emit_condition(node.right)}"
        when Crystal::IsA
          obj = emit_expr(node.obj)
          type_name = node.const.to_s.lstrip(":")
          if type_name == "Nil" || type_name == "NilClass"
            "#{obj} == null"
          elsif type_name == "String"
            "typeof #{obj} === \"string\""
          elsif type_name == "Int32" || type_name == "Int64" || type_name == "Float64" || type_name == "Number"
            "typeof #{obj} === \"number\""
          elsif type_name == "Bool"
            "typeof #{obj} === \"boolean\""
          else
            "#{obj} instanceof #{type_name}"
          end
        when Crystal::BoolLiteral
          node.value.to_s
        else
          emit_expr(node)
        end
      end

      private def emit_call(node : Crystal::Call, class_name : String) : String
        name = node.name
        obj = node.obj

        # errors/errors.add — errors is a property getter, not a method
        if name == "errors" && obj.nil? && node.args.empty?
          return "this.errors"
        end
        if name == "add" && obj
          obj_str = emit_expr(obj)
          args = node.args.map { |a| emit_expr(a) }.join(", ")
          return "#{obj_str}.add(#{args})"
        end

        # [] operator — MODEL_REGISTRY["Name"] or errors["field"]
        if name == "[]" && obj
          obj_str = emit_expr(obj)
          arg = node.args.first? ? emit_expr(node.args.first) : ""
          return "#{obj_str}[#{arg}]"
        end

        # super — in context of destroy override
        if name == "super"
          return "super.destroy()"
        end

        # .size → .length
        if name == "size" && obj
          return "#{emit_expr(obj.not_nil!)}.length"
        end

        # CollectionProxy.new(...)
        if name == "new" && obj
          obj_str = emit_expr(obj)
          if obj_str == "CollectionProxy"
            args = node.args.map { |a| emit_expr(a) }.join(", ")
            return "new CollectionProxy(#{args})"
          end
        end

        # .find(...) — no implicit return (caller decides)
        if name == "find" && obj
          obj_str = emit_expr(obj)
          args = node.args.map { |a| emit_expr(a) }.join(", ")
          return "#{obj_str}.find(#{args})"
        end

        # thing.destroy_all → thing.destroyAll()
        if name == "destroy_all"
          if obj
            obj_str = emit_expr(obj)
            # If obj is already a method call (e.g., comments()), don't add this.
            return "#{obj_str}.destroyAll()"
          end
          return "this.destroyAll()"
        end

        # Generic method call
        if obj
          obj_str = emit_expr(obj)
          # self → this
          obj_str = "this" if obj_str == "self"
          args = node.args.map { |a| emit_expr(a) }.join(", ")
          ts_name = ts_method_name(name)
          return "#{obj_str}.#{ts_name}(#{args})"
        end

        # Bare call
        args = node.args.map { |a| emit_expr(a) }.join(", ")
        ts_name = ts_method_name(name)
        "this.#{ts_name}(#{args})"
      end

      def emit_expr(node : Crystal::ASTNode) : String
        case node
        when Crystal::StringLiteral
          node.value.inspect
        when Crystal::NumberLiteral
          node.value.to_s.gsub(/_i64|_i32/, "")
        when Crystal::BoolLiteral
          node.value.to_s
        when Crystal::NilLiteral
          "null"
        when Crystal::SymbolLiteral
          node.value.inspect
        when Crystal::Var
          name = node.name
          name == "self" ? "this" : name
        when Crystal::InstanceVar
          "this.#{node.name.lchop("@")}"
        when Crystal::Path
          node.names.join(".")
        when Crystal::ArrayLiteral
          elements = node.elements.map { |e| emit_expr(e) }
          "[#{elements.join(", ")}]"
        when Crystal::StringInterpolation
          parts = node.expressions.map do |part|
            case part
            when Crystal::StringLiteral then part.value
            when Crystal::Call
              if part.obj
                "${#{emit_expr(part.obj.not_nil!)}.#{part.name}}"
              else
                "${this.#{part.name}}"
              end
            else "${#{emit_expr(part)}}"
            end
          end
          "`#{parts.join}`"
        when Crystal::Call
          emit_call(node, "")
        when Crystal::Cast
          # node.as(Type) → just emit the node
          emit_expr(node.obj)
        when Crystal::And
          "#{emit_condition(node.left)} && #{emit_condition(node.right)}"
        when Crystal::Or
          "#{emit_condition(node.left)} || #{emit_condition(node.right)}"
        when Crystal::Not
          "!#{emit_expr(node.exp)}"
        when Crystal::IsA
          obj = emit_expr(node.obj)
          type_name = node.const.to_s.lstrip(":")
          if type_name == "Nil" || type_name == "NilClass"
            "#{obj} == null"
          elsif type_name == "String"
            "typeof #{obj} === \"string\""
          elsif type_name == "Int32" || type_name == "Int64" || type_name == "Float64"
            "typeof #{obj} === \"number\""
          elsif type_name == "Bool"
            "typeof #{obj} === \"boolean\""
          else
            "#{obj} instanceof #{type_name}"
          end
        when Crystal::Assign
          "#{emit_expr(node.target)} = #{emit_expr(node.value)}"
        when Crystal::Nop
          ""
        when Crystal::Expressions
          # For single-expression bodies
          if node.expressions.size == 1
            emit_expr(node.expressions.first)
          else
            node.expressions.map { |e| emit_expr(e) }.join("; ")
          end
        else
          "/* TODO: #{node.class.name} */"
        end
      end

      # --- Type mapping ---

      private def map_type(node : Crystal::ASTNode?) : String
        return "unknown" unless node
        case node
        when Crystal::Path
          name = node.names.last
          CRYSTAL_TO_TS[name]? || name
        when Crystal::Union
          types = node.types.map { |t| map_type(t) }
          types.join(" | ")
        when Crystal::Generic
          base = map_type(node.name)
          args = node.type_vars.map { |t| map_type(t) }
          "#{base}<#{args.join(", ")}>"
        else
          "unknown"
        end
      end

      private def map_return_type(node : Crystal::ASTNode?) : String
        return ": void" unless node
        ts_type = map_type(node)
        ": #{ts_type}"
      end

      private def infer_ivar_type(assign : Crystal::Assign) : String
        # Check if the assignment has an inline type annotation in the AST
        # e.g., @title : String = ""
        # Crystal parser represents this differently depending on context
        value = assign.value
        case value
        when Crystal::StringLiteral then "string"
        when Crystal::NumberLiteral
          value.kind.to_s.starts_with?("f") ? "number" : "number"
        when Crystal::BoolLiteral then "boolean"
        when Crystal::NilLiteral then "unknown"
        else "string" # default for model columns
        end
      end

      private def extract_return_value(body : Crystal::ASTNode) : String
        case body
        when Crystal::StringLiteral then body.value.inspect
        when Crystal::Expressions
          last = body.expressions.last?
          last ? extract_return_value(last) : "\"\""
        when Crystal::Return
          body.exp ? emit_expr(body.exp.not_nil!) : "\"\""
        else emit_expr(body)
        end
      end

      # --- Naming ---

      private def ts_method_name(name : String) : String
        # Convert Ruby/Crystal snake_case to TypeScript camelCase
        # But preserve some names as-is
        case name
        when "run_validations" then "runValidations"
        when "destroy_all" then "destroyAll"
        when "table_name" then "tableName"
        when "new_record?" then "newRecord"
        when "persisted?" then "persisted"
        when "valid?" then "valid"
        when "nil?" then "isNil"
        when "is_a?" then "isA"
        when "empty?" then "isEmpty"
        when "any?" then "any"
        when "full_messages" then "fullMessages"
        when "broadcast_replace_to" then "broadcastReplaceTo"
        when "broadcast_append_to" then "broadcastAppendTo"
        when "broadcast_prepend_to" then "broadcastPrependTo"
        when "broadcast_remove_to" then "broadcastRemoveTo"
        when "model_class" then "modelClass"
        else
          # Generic snake_case → camelCase
          name.gsub(/_([a-z])/) { |_, m| m[1].upcase }
        end
      end

      private def ts_typeof(crystal_type : String) : String
        case crystal_type
        when "String" then "string"
        when "Int32", "Int64", "Float32", "Float64" then "number"
        when "Bool" then "boolean"
        else "object"
        end
      end
    end
  end
end
