# Converts Rails ERB templates to EEx templates for Elixir output.
#
# Pipeline: ERB → ErbCompiler → Ruby _buf code → Crystal AST →
#           shared view filters → walk AST → emit EEx template syntax.
#
# Mirrors the EjsConverter (ERB → EJS) and ERBConverter (ERB → ECR).
# EEx uses the same tag syntax: <%= expr %>, <% code %>, <%# comment %>

require "compiler/crystal/syntax"
require "./erb_compiler"
require "./source_parser"
require "./inflector"

module Railcar
  class EexConverter
    getter template_name : String
    getter controller : String
    getter app_module : String

    def initialize(@template_name, @controller, @app_module = "Blog")
    end

    def self.convert_file(path : String, template_name : String, controller : String,
                          view_filters : Array(Crystal::Transformer) = [] of Crystal::Transformer,
                          app_module : String = "Blog") : String
      new(template_name, controller, app_module).convert(File.read(path), path, view_filters)
    end

    def convert(source : String, path : String = "",
                view_filters : Array(Crystal::Transformer) = [] of Crystal::Transformer) : String
      compiler = ErbCompiler.new(source)
      ruby_src = compiler.src
      ast = SourceParser.parse_source(ruby_src, "template.rb")

      def_body = find_def_body(ast)
      return "" unless def_body

      filtered = def_body
      view_filters.each { |f| filtered = filtered.transform(f) }

      io = IO::Memory.new
      emit_statements(filtered, io)
      io.to_s
    end

    # --- Statement emission ---

    private def emit_statements(node : Crystal::ASTNode, io : IO)
      case node
      when Crystal::Expressions
        node.expressions.each { |stmt| emit_statement(stmt, io) }
      else
        emit_statement(node, io)
      end
    end

    private def emit_statement(node : Crystal::ASTNode, io : IO)
      case node
      when Crystal::Assign
        target = node.target
        return if target.is_a?(Crystal::Var) && target.name == "_buf"
        io << "<% " << to_ex(node) << " %>\n"
      when Crystal::OpAssign
        target = node.target
        if target.is_a?(Crystal::Var) && target.name == "_buf" && node.op == "+"
          case val = node.value
          when Crystal::StringLiteral then io << val.value
          when Crystal::StringInterpolation then emit_interpolation(val, io)
          else io << "<%= " << to_ex(val) << " %>"
          end
        else
          io << "<% " << to_ex(node) << " %>\n"
        end
      when Crystal::Call
        obj = node.obj
        if obj.is_a?(Crystal::Var) && obj.name == "_buf"
          case node.name
          when "append=" then emit_buf_output(node, io)
          when "to_s"    then nil
          end
        elsif node.block
          emit_call_with_block(node, io)
        else
          io << "<% " << to_ex(node) << " %>\n"
        end
      when Crystal::If
        emit_if(node, io)
      when Crystal::Expressions
        emit_statements(node, io)
      when Crystal::Nop
        # skip
      end
    end

    # --- Buffer output ---

    private def emit_buf_output(node : Crystal::Call, io : IO)
      args = node.args
      return if args.empty?
      expr_node = args[0]

      if expr_node.is_a?(Crystal::Call) && expr_node.block
        emit_block_expression(expr_node, expr_node.block.not_nil!, io)
        return
      end

      if block = node.block
        inner = unwrap_to_s(expr_node)
        if inner.is_a?(Crystal::Call)
          emit_block_expression(inner, block, io)
        end
        return
      end

      actual_expr = unwrap_to_s(expr_node)
      if actual_expr.is_a?(Crystal::Call) && actual_expr.block
        emit_call_with_block(actual_expr, io)
      else
        ex = to_ex(actual_expr)
        tag = html_returning?(ex) ? "<%=" : "<%="
        io << "#{tag} #{ex} %>"
      end
    end

    private def html_returning?(ex : String) : Bool
      ex.starts_with?("include(") ||
      ex.starts_with?("Helpers.link_to(") ||
      ex.starts_with?("Helpers.button_to(") ||
      ex.starts_with?("Helpers.form_with_open_tag(") ||
      ex.starts_with?("Helpers.form_submit_tag(") ||
      ex.starts_with?("Helpers.turbo_stream_from(")
    end

    private def unwrap_to_s(node : Crystal::ASTNode) : Crystal::ASTNode
      result = node
      if result.is_a?(Crystal::Call) && result.name == "to_s" && result.obj
        result = result.obj.not_nil!
      end
      if result.is_a?(Crystal::Expressions) && result.expressions.size == 1
        result = result.expressions[0]
      end
      result
    end

    # --- If/else ---

    private def emit_if(node : Crystal::If, io : IO)
      io << "<%= if " << to_ex_condition(node.cond) << " do %>\n"
      emit_statements(node.then, io)
      if node.else && !node.else.is_a?(Crystal::Nop)
        io << "<% else %>\n"
        emit_statements(node.else, io)
      end
      io << "<% end %>\n"
    end

    # --- Call with block (collection.each) ---

    private def emit_call_with_block(call : Crystal::Call, io : IO)
      block = call.block.not_nil!
      block_arg = block.args.first?.try(&.name) || "item"
      collection = to_ex(call.obj || Crystal::Nop.new)

      io << "<%= for #{block_arg} <- #{collection} do %>\n"
      if body = block.body
        emit_block_body(body, io)
      end
      io << "<% end %>"
    end

    private def emit_block_body(node : Crystal::ASTNode, io : IO)
      case node
      when Crystal::Expressions
        node.expressions.each { |stmt| emit_block_body(stmt, io) }
      when Crystal::OpAssign, Crystal::Assign
        emit_statement(node, io)
      when Crystal::Call
        obj = node.obj
        if obj.is_a?(Crystal::Var) && obj.name == "_buf"
          emit_statement(node, io)
        else
          ex = to_ex(node)
          io << "<%= #{ex} %>\n"
        end
      when Crystal::If
        emit_if(node, io)
      else
        emit_statement(node, io)
      end
    end

    # --- Block expressions (form_with) ---

    private def emit_block_expression(call : Crystal::Call, block : Crystal::Block, io : IO)
      model_var = nil
      parent_var = nil
      child_class = nil
      css_class = nil

      if named = call.named_args
        named.each do |na|
          case na.name
          when "model"
            val = na.value
            if val.is_a?(Crystal::ArrayLiteral) && val.elements.size == 2
              parent_var = val.elements[0].to_s
              elem1 = val.elements[1]
              if elem1.is_a?(Crystal::Call) && elem1.obj.is_a?(Crystal::Path)
                child_class = elem1.obj.as(Crystal::Path).names.last.downcase
              end
            else
              model_var = val.to_s
            end
          when "class"
            css_class = na.value.is_a?(Crystal::StringLiteral) ? na.value.as(Crystal::StringLiteral).value : na.value.to_s
          end
        end
      end

      css_attr = css_class ? %( class="#{css_class}") : ""
      app_module = Inflector.classify(@controller.split("/").first? || @controller)

      if parent_var && child_class
        plural = Inflector.pluralize(child_class)
        parent_singular = Inflector.singularize(parent_var)
        io << %(<form#{css_attr} action="<%= Helpers.#{parent_singular}_#{plural}_path(#{parent_var}) %>" accept-charset="UTF-8" method="post">\n)
      elsif model_var
        singular = model_var
        plural = Inflector.pluralize(singular)
        io << %(<%= if #{singular}.id do %>\n)
        io << %(<form#{css_attr} action="<%= Helpers.#{singular}_path(#{singular}) %>" accept-charset="UTF-8" method="post">\n)
        io << %(  <input type="hidden" name="_method" value="patch">\n)
        io << %(<% else %>\n)
        io << %(<form#{css_attr} action="<%= Helpers.#{plural}_path() %>" accept-charset="UTF-8" method="post">\n)
        io << %(<% end %>\n)
      else
        io << %(<form method="post"#{css_attr}>\n)
      end

      if body = block.body
        form_model = model_var || child_class || "item"
        if child_class && !model_var
          model_module = Inflector.classify(child_class)
          io << %(<% #{child_class} = %#{app_module}.#{model_module}{} %>\n)
        end
        emit_form_body(body, io, form_model)
      end

      io << "</form>"
    end

    # --- Form body ---

    private def emit_form_body(node : Crystal::ASTNode, io : IO, model_prefix : String)
      case node
      when Crystal::Expressions
        node.expressions.each { |stmt| emit_form_body(stmt, io, model_prefix) }
      when Crystal::OpAssign
        target = node.target
        if target.is_a?(Crystal::Var) && target.name == "_buf" && node.op == "+"
          case val = node.value
          when Crystal::StringLiteral then io << val.value
          when Crystal::StringInterpolation then emit_interpolation(val, io)
          end
        end
      when Crystal::Call
        obj = node.obj
        if obj.is_a?(Crystal::Var) && obj.name == "_buf"
          if node.name == "append="
            actual = node.args[0]?
            actual = unwrap_to_s(actual) if actual
            if actual.is_a?(Crystal::Call)
              emit_form_field(actual, io, model_prefix)
            elsif actual
              io << "<%= " << to_ex(actual) << " %>"
            end
          end
        elsif node.block
          emit_call_with_block(node, io)
        end
      when Crystal::If
        emit_if(node, io)
      end
    end

    private def emit_form_field(call : Crystal::Call, io : IO, model_prefix : String)
      method = call.name
      args = call.args
      named = call.named_args

      case method
      when "label_tag", "label"
        field = args[0]?.try { |a| a.to_s.strip(':').strip('"') } || ""
        css = extract_css(named)
        css_attr = css ? %( class="#{css}") : ""
        io << %(<label for="#{model_prefix}_#{field}"#{css_attr}>#{field.capitalize}</label>)
      when "text_field_tag", "text_field"
        field = args[0]?.try { |a| a.to_s.strip(':').strip('"') } || ""
        css = extract_css(named)
        css_attr = css ? %( class="#{css}") : ""
        io << %(<input type="text" name="#{model_prefix}[#{field}]" id="#{model_prefix}_#{field}" value="<%= #{model_prefix}.#{field} %>"#{css_attr}>)
      when "text_area_tag", "text_area"
        field = args[0]?.try { |a| a.to_s.strip(':').strip('"') } || ""
        rows = extract_named_value(named, "rows") || "4"
        css = extract_css(named)
        css_attr = css ? %( class="#{css}") : ""
        io << %(<textarea name="#{model_prefix}[#{field}]" id="#{model_prefix}_#{field}" rows="#{rows}"#{css_attr}>\n<%= #{model_prefix}.#{field} %></textarea>)
      when "submit_tag", "submit"
        text = args[0]?.try { |a| a.to_s.strip('"') }
        css = extract_css(named)
        css_attr = css ? %( class="#{css}") : ""
        if text
          io << %(<button type="submit"#{css_attr}>#{text}</button>)
        else
          io << %(<%= Helpers.form_submit_tag(#{model_prefix}, #{css ? "class: \"#{css}\"" : ""}) %>)
        end
      else
        io << "<%= " << to_ex(call) << " %>"
      end
    end

    private def extract_css(named : Array(Crystal::NamedArgument)?) : String?
      return nil unless named
      na = named.find { |n| n.name == "class" }
      return nil unless na
      na.value.is_a?(Crystal::StringLiteral) ? na.value.as(Crystal::StringLiteral).value : na.value.to_s
    end

    private def extract_named_value(named : Array(Crystal::NamedArgument)?, key : String) : String?
      return nil unless named
      na = named.find { |n| n.name == key }
      return nil unless na
      na.value.to_s
    end

    # --- StringInterpolation ---

    private def emit_interpolation(node : Crystal::StringInterpolation, io : IO)
      node.expressions.each do |part|
        case part
        when Crystal::StringLiteral
          io << part.value
        else
          io << "<%= " << to_ex(part) << " %>"
        end
      end
    end

    # --- Crystal AST → Elixir expression ---

    private def to_ex(node : Crystal::ASTNode) : String
      case node
      when Crystal::StringLiteral then node.value.inspect
      when Crystal::NumberLiteral then node.value.to_s.gsub(/_i64|_i32/, "")
      when Crystal::BoolLiteral then node.value.to_s
      when Crystal::NilLiteral then "nil"
      when Crystal::SymbolLiteral then ":#{node.value}"
      when Crystal::Var
        node.name == "self" ? "self" : node.name
      when Crystal::InstanceVar then node.name.lchop("@")
      when Crystal::Path then node.names.join(".")
      when Crystal::ArrayLiteral
        "[#{node.elements.map { |e| to_ex(e) }.join(", ")}]"
      when Crystal::StringInterpolation
        parts = node.expressions.map do |part|
          case part
          when Crystal::StringLiteral then part.value.gsub("\\", "\\\\").gsub("\"", "\\\"")
          else "\#{#{to_ex(part)}}"
          end
        end
        "\"#{parts.join}\""
      when Crystal::Call then to_ex_call(node)
      when Crystal::Assign then "#{to_ex(node.target)} = #{to_ex(node.value)}"
      when Crystal::Not then "!#{to_ex(node.exp)}"
      when Crystal::And then "#{to_ex(node.left)} && #{to_ex(node.right)}"
      when Crystal::Or then "#{to_ex(node.left)} || #{to_ex(node.right)}"
      when Crystal::IsA
        type_name = node.const.to_s.lstrip(":")
        obj = to_ex(node.obj)
        if type_name == "String"
          "is_binary(#{obj})"
        else
          "is_struct(#{obj}, #{type_name})"
        end
      when Crystal::Cast then to_ex(node.obj)
      when Crystal::NamedTupleLiteral
        entries = node.entries.map { |e| "#{e.key}: #{to_ex(e.value)}" }
        "%{#{entries.join(", ")}}"
      when Crystal::HashLiteral
        entries = node.entries.map do |e|
          key = case e.key
                when Crystal::SymbolLiteral then e.key.as(Crystal::SymbolLiteral).value
                when Crystal::StringLiteral then e.key.as(Crystal::StringLiteral).value
                else e.key.to_s
                end
          "#{key}: #{to_ex(e.value)}"
        end
        "%{#{entries.join(", ")}}"
      when Crystal::Nop then ""
      else "# TODO: #{node.class.name}"
      end
    end

    private def to_ex_call(node : Crystal::Call) : String
      name = node.name
      obj = node.obj
      args = node.args.map { |a| to_ex(a) }

      # Named args
      if named = node.named_args
        named.each do |na|
          args << "#{na.name}: #{to_ex(na.value)}"
        end
      end

      case name
      when "new"
        obj_str = obj ? to_ex(obj) : "Object"
        return "%#{obj_str}{#{args.join(", ")}}" if args.empty?
        return "struct(#{obj_str}, %{#{args.join(", ")}})"
      when "to_s" then return obj ? "to_string(#{to_ex(obj)})" : "to_string()"
      when "nil?" then return obj ? "is_nil(#{to_ex(obj)})" : "is_nil(self)"
      when "empty?"
        obj_str = obj ? to_ex(obj) : "self"
        return "(#{obj_str} == nil || #{obj_str} == \"\")"
      when "any?" then return obj ? to_ex(obj) : "self"
      when "size", "count", "length"
        obj_str = obj ? to_ex(obj) : "self"
        return "length(#{obj_str})"
      when "[]"
        obj_str = obj ? to_ex(obj) : ""
        return "#{obj_str}[#{args.join}]"
      end

      # Helper functions
      if !obj && {"link_to", "button_to", "truncate", "dom_id", "pluralize",
                   "turbo_stream_from", "turbo_cable_stream_tag", "content_for"}.includes?(name)
        fn_name = name == "turbo_cable_stream_tag" ? "turbo_stream_from" : name
        return "#{@app_module}.Helpers.#{fn_name}(#{args.join(", ")})"
      end

      # Form helpers — extract model as first positional arg
      if !obj && (name == "form_with_open_tag" || name == "form_submit_tag")
        if named_args = node.named_args
          model_arg = named_args.find { |na| na.name == "model" }
          other_args = named_args.reject { |na| na.name == "model" }
          call_args = [] of String
          call_args << to_ex(model_arg.value) if model_arg
          other_args.each { |na| call_args << "#{na.name}: #{to_ex(na.value)}" }
          return "#{@app_module}.Helpers.#{name}(#{call_args.join(", ")})"
        end
        return "#{@app_module}.Helpers.#{name}(#{args.join(", ")})"
      end

      # Path helpers
      if !obj && name.ends_with?("_path")
        return "#{@app_module}.Helpers.#{name}(#{args.join(", ")})"
      end

      # Render partials → Helpers.render_partial
      if !obj && name.starts_with?("render_") && name.ends_with?("_partial")
        partial_name = name.lchop("render_").chomp("_partial")
        var_name = args.last? || partial_name
        controller_plural = Inflector.pluralize(@controller)
        partial_model_plural = Inflector.pluralize(partial_name)
        is_model_partial = partial_name != "form" && partial_model_plural != controller_plural
        template_dir = is_model_partial ? partial_model_plural : controller_plural
        return "#{@app_module}.Helpers.render_partial(\"#{template_dir}/_#{partial_name}\", [{:#{partial_name}, #{var_name}}])"
      end

      # Bare name with no args — local variable
      if !obj && args.empty? && !node.block && !node.named_args
        return name
      end

      # Method calls on objects
      if obj
        obj_str = to_ex(obj)
        # Struct field access
        if {"title", "body", "commenter", "id", "errors", "persisted", "article_id",
            "created_at", "updated_at"}.includes?(name)
          return "#{obj_str}.#{name}"
        end
        # Association/method calls → Module.function(obj) pattern
        # Infer module from variable name: article → Blog.Article
        model_name = Inflector.classify(obj_str.split(".").last)
        return "#{@app_module}.#{model_name}.#{name}(#{([obj_str] + args).join(", ")})"
      end

      "#{name}(#{args.join(", ")})"
    end

    private def to_ex_condition(node : Crystal::ASTNode) : String
      case node
      when Crystal::Var then node.name
      when Crystal::Call
        if node.name == "any?" && node.obj
          "length(#{to_ex(node.obj.not_nil!)}) > 0"
        elsif node.name == "nil?" && node.obj
          "is_nil(#{to_ex(node.obj.not_nil!)})"
        elsif node.name == "present?" && node.obj
          to_ex(node.obj.not_nil!)
        else
          to_ex(node)
        end
      when Crystal::Not then "!(#{to_ex_condition(node.exp)})"
      when Crystal::And then "#{to_ex_condition(node.left)} && #{to_ex_condition(node.right)}"
      when Crystal::Or then "#{to_ex_condition(node.left)} || #{to_ex_condition(node.right)}"
      else to_ex(node)
      end
    end

    # --- AST traversal ---

    private def find_def_body(ast : Crystal::ASTNode) : Crystal::ASTNode?
      case ast
      when Crystal::Def
        return ast.body if ast.name == "render"
      when Crystal::Expressions
        ast.expressions.each do |expr|
          result = find_def_body(expr)
          return result if result
        end
      end
      nil
    end
  end
end
