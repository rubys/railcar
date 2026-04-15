# Converts Rails ERB templates to Go html/template files.
#
# Pipeline: ERB → ErbCompiler → Ruby _buf code → Crystal AST →
#           shared view filters → walk AST → emit Go template syntax.
#
# Go templates use: {{.Field}}, {{if .Cond}}...{{end}}, {{range .Items}}...{{end}}
# Functions are called via FuncMap: {{linkTo "text" (articlePath .article)}}

require "compiler/crystal/syntax"
require "./erb_compiler"
require "./source_parser"
require "./inflector"

module Railcar
  class GoTemplateConverter
    getter template_name : String
    getter controller : String
    getter known_fields : Set(String)

    def initialize(@template_name, @controller, @known_fields = Set(String).new)
    end

    def self.convert_file(path : String, template_name : String, controller : String,
                          view_filters : Array(Crystal::Transformer) = [] of Crystal::Transformer,
                          known_fields : Set(String) = Set(String).new) : String
      new(template_name, controller, known_fields).convert(File.read(path), path, view_filters)
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
        go_val = to_go(node)
        return if go_val.empty? || go_val.ends_with?(":= ")
        io << "{{" << go_val << "}}\n"
      when Crystal::OpAssign
        target = node.target
        if target.is_a?(Crystal::Var) && target.name == "_buf" && node.op == "+"
          case val = node.value
          when Crystal::StringLiteral then io << val.value
          when Crystal::StringInterpolation then emit_interpolation(val, io)
          else io << "{{" << to_go(val) << "}}"
          end
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
        emit_call_with_block(expr_node, io)
        return
      end

      actual_expr = unwrap_to_s(expr_node)
      if actual_expr.is_a?(Crystal::Call) && actual_expr.block
        emit_call_with_block(actual_expr, io)
      else
        io << "{{" << to_go(actual_expr) << "}}"
      end
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
      io << "{{if " << to_go_condition(node.cond) << "}}\n"
      emit_statements(node.then, io)
      if node.else && !node.else.is_a?(Crystal::Nop)
        io << "{{else}}\n"
        emit_statements(node.else, io)
      end
      io << "{{end}}\n"
    end

    # --- Call with block (collection.each) ---

    private def emit_call_with_block(call : Crystal::Call, io : IO)
      block = call.block.not_nil!
      block_arg = block.args.first?.try(&.name) || "item"
      collection = to_go(call.obj || Crystal::Nop.new)

      io << "{{range $#{block_arg} := #{collection}}}\n"
      if body = block.body
        emit_block_body(body, io, block_arg)
      end
      io << "{{end}}"
    end

    private def emit_block_body(node : Crystal::ASTNode, io : IO, loop_var : String = "")
      case node
      when Crystal::Expressions
        node.expressions.each { |stmt| emit_block_body(stmt, io, loop_var) }
      when Crystal::OpAssign, Crystal::Assign
        emit_statement(node, io)
      when Crystal::Call
        obj = node.obj
        if obj.is_a?(Crystal::Var) && obj.name == "_buf"
          emit_statement(node, io)
        else
          io << "{{" << to_go(node) << "}}\n"
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
      css_class = nil

      if named = call.named_args
        named.each do |na|
          case na.name
          when "model" then model_var = na.value.to_s
          when "class"
            css_class = na.value.is_a?(Crystal::StringLiteral) ? na.value.as(Crystal::StringLiteral).value : na.value.to_s
          end
        end
      end

      css_attr = css_class ? %( class="#{css_class}") : ""

      if model_var
        singular = model_var
        plural = Inflector.pluralize(singular)
        io << "{{if .#{singular.capitalize}.Id}}\n"
        io << %(<form#{css_attr} action="/#{plural}/{{.#{singular.capitalize}.Id}}" method="post">\n)
        io << %(<input type="hidden" name="_method" value="patch">\n)
        io << "{{else}}\n"
        io << %(<form#{css_attr} action="/#{plural}" method="post">\n)
        io << "{{end}}\n"
      else
        io << %(<form method="post"#{css_attr}>\n)
      end

      if body = block.body
        form_model = model_var || "item"
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
              io << "{{" << to_go(actual) << "}}"
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
      cap = model_prefix.capitalize

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
        io << %(<input type="text" name="#{model_prefix}[#{field}]" id="#{model_prefix}_#{field}" value="{{.#{cap}.#{go_field_name(field)}}}"#{css_attr}>)
      when "text_area_tag", "text_area"
        field = args[0]?.try { |a| a.to_s.strip(':').strip('"') } || ""
        rows = extract_named_value(named, "rows") || "4"
        css = extract_css(named)
        css_attr = css ? %( class="#{css}") : ""
        io << %(<textarea name="#{model_prefix}[#{field}]" id="#{model_prefix}_#{field}" rows="#{rows}"#{css_attr}>\n{{.#{cap}.#{go_field_name(field)}}}</textarea>)
      when "submit_tag", "submit"
        text = args[0]?.try { |a| a.to_s.strip('"') }
        css = extract_css(named)
        css_attr = css ? %( class="#{css}") : ""
        if text
          io << %(<button type="submit"#{css_attr}>#{text}</button>)
        else
          io << "{{formSubmitTag .#{cap}}}"
        end
      else
        io << "{{" << to_go(call) << "}}"
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
        when Crystal::StringLiteral then io << part.value
        else io << "{{" << to_go(part) << "}}"
        end
      end
    end

    # --- Crystal AST → Go template expression ---

    private def to_go(node : Crystal::ASTNode) : String
      case node
      when Crystal::StringLiteral then node.value.inspect
      when Crystal::NumberLiteral then node.value.to_s.gsub(/_i64|_i32/, "")
      when Crystal::BoolLiteral then node.value.to_s
      when Crystal::NilLiteral then "nil"
      when Crystal::SymbolLiteral then node.value.inspect
      when Crystal::Var
        name = node.name
        name == "self" ? "." : ".#{name}"
      when Crystal::InstanceVar
        ".#{node.name.lchop("@")}"
      when Crystal::Path then node.names.join(".")
      when Crystal::StringInterpolation
        # Go templates: use printf for string interpolation
        format_parts = [] of String
        go_args = [] of String
        node.expressions.each do |part|
          case part
          when Crystal::StringLiteral
            format_parts << part.value.gsub("%", "%%")
          when Crystal::Call
            if part.name == "id" || part.name =~ /.*_id$/
              format_parts << "%d"
            else
              format_parts << "%s"
            end
            go_args << to_go(part)
          else
            format_parts << "%v"
            go_args << to_go(part)
          end
        end
        if go_args.empty?
          format_parts.join.inspect
        else
          "(printf #{format_parts.join.inspect} #{go_args.join(" ")})"
        end
      when Crystal::Call then to_go_call(node)
      when Crystal::Assign then "$#{to_go(node.target)} := #{to_go(node.value)}"
      when Crystal::Not then "not #{to_go(node.exp)}"
      when Crystal::And then "and #{to_go(node.left)} #{to_go(node.right)}"
      when Crystal::Or then "or #{to_go(node.left)} #{to_go(node.right)}"
      when Crystal::Cast then to_go(node.obj)
      when Crystal::NamedTupleLiteral
        entries = node.entries.map { |e| "#{e.key}: #{to_go(e.value)}" }
        entries.join(", ")
      when Crystal::Nop then ""
      else "/* TODO: #{node.class.name} */"
      end
    end

    private def to_go_call(node : Crystal::Call) : String
      name = node.name
      obj = node.obj
      args = node.args.map { |a| to_go(a) }

      # Named args → additional args
      if named = node.named_args
        named.each do |na|
          if na.name == "class"
            args << na.value.to_s.strip('"').inspect
          elsif na.name == "method"
            args << na.value.to_s.strip(':').strip('"').inspect
          elsif na.name == "data_turbo_confirm"
            args << na.value.to_s.strip('"').inspect
          elsif na.name == "form_class"
            args << na.value.to_s.strip('"').inspect
          elsif na.name == "length"
            args << na.value.to_s
          end
        end
      end

      # Special form helpers
      case name
      when "new"
        return "" # Model.new() → empty struct, handled elsewhere
      when "to_s"
        return obj ? to_go(obj) : ""
      when "nil?"
        obj_str = obj ? to_go(obj) : "."
        return "not #{obj_str}"
      when "empty?"
        obj_str = obj ? to_go(obj) : "."
        return "eq #{obj_str} \"\""
      when "any?"
        return obj ? to_go(obj) : "."
      when "size", "count", "length"
        obj_str = obj ? to_go(obj) : "."
        return "len #{obj_str}"
      when "[]"
        obj_str = obj ? to_go(obj) : ""
        return "index #{obj_str} #{args.join(" ")}"
      end

      # Helper functions → FuncMap calls
      if !obj && {"link_to", "button_to", "truncate", "dom_id", "pluralize",
                   "turbo_stream_from", "turbo_cable_stream_tag",
                   "form_with_open_tag", "form_submit_tag"}.includes?(name)
        func_name = name.gsub("_", "").split("_").map(&.capitalize).join("")
        # camelCase for Go FuncMap
        func_name = case name
                    when "link_to" then "linkTo"
                    when "button_to" then "buttonTo"
                    when "turbo_stream_from", "turbo_cable_stream_tag" then "turboStreamFrom"
                    when "form_with_open_tag" then "formWithOpenTag"
                    when "form_submit_tag" then "formSubmitTag"
                    when "dom_id" then "domID"
                    else name
                    end

        # For form helpers, extract model from named args
        if {"form_with_open_tag", "form_submit_tag"}.includes?(name)
          if na = node.named_args.try(&.find { |n| n.name == "model" })
            model_arg = to_go(na.value)
            other_args = node.named_args.not_nil!.reject { |n| n.name == "model" }.map { |n| n.value.to_s.strip('"').inspect }
            all_args = [model_arg] + other_args
            return "#{func_name} #{all_args.join(" ")}"
          end
        end

        return "#{func_name} #{args.join(" ")}"
      end

      # Path helpers — in Go templates, function calls use (funcName args...)
      if !obj && name.ends_with?("_path")
        func_name = name.split("_").map(&.capitalize).join("")
        func_name = func_name[0].downcase + func_name[1..]
        if args.empty?
          return "(#{func_name})"  # Parenthesized for use as argument
        else
          return "(#{func_name} #{args.join(" ")})"
        end
      end

      # Render partials
      if !obj && name.starts_with?("render_") && name.ends_with?("_partial")
        partial_name = name.lchop("render_").chomp("_partial")
        controller_plural = Inflector.pluralize(@controller)
        partial_model_plural = Inflector.pluralize(partial_name)
        is_model_partial = partial_name != "form" && partial_model_plural != controller_plural
        template_dir = is_model_partial ? partial_model_plural : controller_plural
        var_name = args.last?.try(&.lstrip(".")) || partial_name
        return "template \"templates/#{template_dir}/_#{partial_name}.gohtml\" ."
      end

      # Bare name with no args — template variable (map key, lowercase)
      if !obj && args.empty? && !node.block && !node.named_args
        return ".#{name}"
      end

      # Method calls on objects → struct field access (capitalized)
      if obj
        obj_str = to_go(obj)
        field = go_field_name(name)  # Capitalize for Go struct fields
        return "#{obj_str}.#{field}"
      end

      "#{name} #{args.join(" ")}".strip
    end

    private def to_go_condition(node : Crystal::ASTNode) : String
      case node
      when Crystal::Var then ".#{node.name}"
      when Crystal::Call
        if node.name == "any?" && node.obj
          to_go(node.obj.not_nil!)
        elsif node.name == "nil?" && node.obj
          "not #{to_go(node.obj.not_nil!)}"
        elsif node.name == "present?" && node.obj
          to_go(node.obj.not_nil!)
        else
          to_go(node)
        end
      when Crystal::Not then "not (#{to_go_condition(node.exp)})"
      when Crystal::And then "and (#{to_go_condition(node.left)}) (#{to_go_condition(node.right)})"
      when Crystal::Or then "or (#{to_go_condition(node.left)}) (#{to_go_condition(node.right)})"
      else to_go(node)
      end
    end

    private def go_field_name(name : String) : String
      name.split("_").map(&.capitalize).join("")
    end

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
