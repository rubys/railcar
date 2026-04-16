# Converts Rails ERB templates to EJS templates for TypeScript output.
#
# Pipeline: ERB → ErbCompiler → Ruby _buf code → Crystal AST →
#           shared view filters → walk AST → emit EJS template syntax.
#
# Mirrors the ERBConverter pattern (ERB → ECR for Crystal), but emits
# JavaScript expressions instead of Crystal expressions inside <% %> tags.
#
# EJS uses the same tag syntax as ERB/ECR:
#   <%= expr %>  — output expression
#   <% code %>   — execute code
#   <%# comment %> — comment

require "compiler/crystal/syntax"
require "./erb_compiler"
require "./source_parser"
require "./inflector"
require "./type_resolver"
require "../filters/method_map"

module Railcar
  class EjsConverter
    getter template_name : String
    getter controller : String
    getter known_fields : Set(String)
    getter resolver : TypeResolver?

    def initialize(@template_name, @controller, @known_fields = Set(String).new, @resolver = nil)
    end

    def self.convert_file(path : String, template_name : String, controller : String,
                          view_filters : Array(Crystal::Transformer) = [] of Crystal::Transformer,
                          known_fields : Set(String) = Set(String).new,
                          resolver : TypeResolver? = nil) : String
      new(template_name, controller, known_fields, resolver).convert(File.read(path), path, view_filters)
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
        # Skip _buf = String.new initialization
        return if target.is_a?(Crystal::Var) && target.name == "_buf"
        io << "<% " << to_js(node) << " %>\n"
      when Crystal::OpAssign
        target = node.target
        if target.is_a?(Crystal::Var) && target.name == "_buf" && node.op == "+"
          case val = node.value
          when Crystal::StringLiteral then io << val.value
          when Crystal::StringInterpolation then emit_interpolation(val, io)
          else io << "<%= " << to_js(val) << " %>"
          end
        else
          io << "<% " << to_js(node) << " %>\n"
        end
      when Crystal::Call
        obj = node.obj
        if obj.is_a?(Crystal::Var) && obj.name == "_buf"
          case node.name
          when "append=" then emit_buf_output(node, io)
          when "to_s"    then nil  # final return — skip
          end
        elsif node.block
          emit_call_with_block(node, io)
        else
          io << "<% " << to_js(node) << " %>\n"
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
        js = to_js(actual_expr)
        # Use <%- for expressions that return HTML (includes, helpers)
        needs_raw = js.starts_with?("include(") ||
                    js.starts_with?("helpers.linkTo(") ||
                    js.starts_with?("helpers.buttonTo(") ||
                    js.starts_with?("helpers.formWithOpenTag(") ||
                    js.starts_with?("helpers.formSubmitTag(") ||
                    js.starts_with?("helpers.turboStreamFrom(") ||
                    js.starts_with?("helpers.turboCableStreamTag(") ||
                    js.starts_with?("turboCableStreamTag(")
        tag = needs_raw ? "<%-" : "<%="
        io << "#{tag} " << js << " %>"
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
      io << "<% if (" << to_js_condition(node.cond) << ") { %>\n"
      emit_statements(node.then, io)
      if node.else && !node.else.is_a?(Crystal::Nop)
        if node.else.is_a?(Crystal::If)
          io << "<% } else "
          emit_if_continuation(node.else.as(Crystal::If), io)
        else
          io << "<% } else { %>\n"
          emit_statements(node.else, io)
          io << "<% } %>\n"
        end
      else
        io << "<% } %>\n"
      end
    end

    private def emit_if_continuation(node : Crystal::If, io : IO)
      io << "if (" << to_js_condition(node.cond) << ") { %>\n"
      emit_statements(node.then, io)
      if node.else && !node.else.is_a?(Crystal::Nop)
        if node.else.is_a?(Crystal::If)
          io << "<% } else "
          emit_if_continuation(node.else.as(Crystal::If), io)
        else
          io << "<% } else { %>\n"
          emit_statements(node.else, io)
          io << "<% } %>\n"
        end
      else
        io << "<% } %>\n"
      end
    end

    # --- Call with block (e.g., collection.each from RenderToPartial) ---

    private def emit_call_with_block(call : Crystal::Call, io : IO)
      block = call.block.not_nil!
      block_arg = block.args.first?.try(&.name) || "item"

      # collection.each { |item| ... } → for (const item of collection) { ... }
      collection = to_js(call.obj || Crystal::Nop.new)
      io << "<% for (const " << block_arg << " of " << collection << ") { %>\n"

      if body = block.body
        emit_block_body(body, io)
      end

      io << "<% } %>"
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
          js = to_js(node)
          tag = js.starts_with?("include(") ? "<%-" : "<%="
          io << "#{tag} " << js << " %>\n"
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

      if parent_var && child_class
        plural = Inflector.pluralize(child_class)
        parent_singular = Inflector.singularize(parent_var)
        io << %(<form#{css_attr} action="<%= helpers.#{parent_singular}#{Inflector.classify(plural)}Path(#{parent_var}) %>" accept-charset="UTF-8" method="post">\n)
      elsif model_var
        singular = model_var
        plural = Inflector.pluralize(singular)
        io << %(<% const _action = #{singular}.persisted ? helpers.#{singular}Path(#{singular}) : helpers.#{plural}Path(); %>\n)
        io << %(<% const _method = #{singular}.persisted ? "patch" : "post"; %>\n)
        io << %(<form#{css_attr} action="<%= _action %>" accept-charset="UTF-8" method="post">\n)
        io << %(  <% if (_method !== "post") { %>\n)
        io << %(    <input type="hidden" name="_method" value="<%= _method %>">\n)
        io << %(  <% } %>\n)
      else
        io << %(<form method="post"#{css_attr}>\n)
      end

      if body = block.body
        form_model = model_var || child_class || "item"
        if child_class && !model_var
          model_class = Inflector.classify(child_class)
          io << %(<% const #{child_class} = new #{model_class}(); %>\n)
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
              io << "<%= " << to_js(actual) << " %>"
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
          io << %(<%= helpers.formSubmitTag(#{model_prefix}, { #{css ? "class: \"#{css}\"" : ""} }) %>)
        end
      else
        io << "<%= " << to_js(call) << " %>"
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

    # --- StringInterpolation → mixed text + expressions ---

    private def emit_interpolation(node : Crystal::StringInterpolation, io : IO)
      node.expressions.each do |part|
        case part
        when Crystal::StringLiteral
          io << part.value
        else
          io << "<%= " << to_js(part) << " %>"
        end
      end
    end

    # --- Crystal AST → JavaScript expression ---

    private def to_js(node : Crystal::ASTNode) : String
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
        node.name == "self" ? "this" : node.name
      when Crystal::InstanceVar
        node.name.lchop("@")
      when Crystal::Path
        node.names.join(".")
      when Crystal::ArrayLiteral
        "[#{node.elements.map { |e| to_js(e) }.join(", ")}]"
      when Crystal::StringInterpolation
        parts = node.expressions.map do |part|
          case part
          when Crystal::StringLiteral then part.value.gsub("\\", "\\\\").gsub("`", "\\`")
          else "${#{to_js(part)}}"
          end
        end
        "`#{parts.join}`"
      when Crystal::Call
        to_js_call(node)
      when Crystal::Assign
        "const #{to_js(node.target)} = #{to_js(node.value)}"
      when Crystal::Not
        "!#{to_js(node.exp)}"
      when Crystal::And
        "#{to_js(node.left)} && #{to_js(node.right)}"
      when Crystal::Or
        "#{to_js(node.left)} || #{to_js(node.right)}"
      when Crystal::IsA
        type_name = node.const.to_s.lstrip(":")
        obj = to_js(node.obj)
        if type_name == "String"
          "typeof #{obj} === \"string\""
        else
          "#{obj} instanceof #{type_name}"
        end
      when Crystal::Cast
        to_js(node.obj)
      when Crystal::NamedTupleLiteral
        entries = node.entries.map { |e| "#{e.key}: #{to_js(e.value)}" }
        "{ #{entries.join(", ")} }"
      when Crystal::HashLiteral
        entries = node.entries.map { |e| "#{to_js(e.key)}: #{to_js(e.value)}" }
        "{ #{entries.join(", ")} }"
      when Crystal::Nop
        ""
      else
        "/* TODO: #{node.class.name} */"
      end
    end

    private def to_js_call(node : Crystal::Call) : String
      name = node.name
      obj = node.obj
      args = node.args.map { |a| to_js(a) }

      # Named args → object literal
      if named = node.named_args
        opts = named.map { |na|
          key = na.name
          "#{key}: #{to_js(na.value)}"
        }
        args << "{ #{opts.join(", ")} }" unless opts.empty?
      end

      # Special methods
      case name
      when "new"
        obj_str = obj ? to_js(obj) : "Object"
        # Use MODEL_REGISTRY for model constructors in EJS templates
        if obj.is_a?(Crystal::Path)
          return "new MODEL_REGISTRY[#{obj_str.inspect}](#{args.join(", ")})"
        end
        return "new #{obj_str}(#{args.join(", ")})"
      when "to_s"
        return obj ? "String(#{to_js(obj)})" : "String()"
      when "nil?"
        obj_str = obj ? to_js(obj) : "this"
        return "#{obj_str} == null"
      when "empty?"
        obj_str = obj ? to_js(obj) : "this"
        return "!#{obj_str}"
      when "any?"
        obj_str = obj ? to_js(obj) : "this"
        return "#{obj_str}"
      when "size", "count"
        obj_str = obj ? to_js(obj) : "this"
        return "#{obj_str}.length"
      when "length"
        obj_str = obj ? to_js(obj) : "this"
        return "#{obj_str}.length"
      when "[]"
        obj_str = obj ? to_js(obj) : ""
        return "#{obj_str}[#{args.join}]"
      end

      # Form helpers — extract model as first positional arg, rest as opts
      if !obj && (name == "form_with_open_tag" || name == "form_submit_tag")
        ts_name = name.gsub(/_([a-z])/) { |_, m| m[1].upcase }
        if named = node.named_args
          model_arg = named.find { |na| na.name == "model" }
          other_args = named.reject { |na| na.name == "model" }
          call_args = [] of String
          call_args << to_js(model_arg.value) if model_arg
          unless other_args.empty?
            opts = other_args.map { |na| "#{na.name}: #{to_js(na.value)}" }
            call_args << "{ #{opts.join(", ")} }"
          end
          return "helpers.#{ts_name}(#{call_args.join(", ")})"
        end
        return "helpers.#{ts_name}(#{args.join(", ")})"
      end

      # Helper function calls → helpers.camelCase()
      if !obj && {"link_to", "button_to", "truncate", "dom_id", "pluralize",
                   "turbo_stream_from", "content_for"}.includes?(name)
        ts_name = name.gsub(/_([a-z])/) { |_, m| m[1].upcase }
        return "helpers.#{ts_name}(#{args.join(", ")})"
      end

      # Path helpers → helpers.camelCasePath()
      if !obj && name.ends_with?("_path")
        ts_name = name.gsub(/_([a-z])/) { |_, m| m[1].upcase }
        return "helpers.#{ts_name}(#{args.join(", ")})"
      end

      # render_*_partial → EJS include
      if !obj && name.starts_with?("render_") && name.ends_with?("_partial")
        partial_name = name.lchop("render_").chomp("_partial")
        var_name = args.last? || partial_name

        # Check if partial is in the same controller's views or a different one.
        # Model partials (article, comment) go in their model's view dir.
        # Non-model partials (form) are local to the current controller.
        controller_plural = Inflector.pluralize(@controller)
        partial_model_plural = Inflector.pluralize(partial_name)
        model_name = Inflector.classify(partial_name)
        is_model_partial = partial_name != "form" && partial_model_plural != controller_plural

        if is_model_partial
          partial_path = "../#{partial_model_plural}/_#{partial_name}"
        else
          # Local partial in same directory
          partial_path = "./_#{partial_name}"
        end

        # Pass the variable with its actual name as the local key
        # render_form_partial(article) → { article: article, helpers }
        # render_comment_partial(article, comment) → { comment: comment, helpers }
        return "include(\"#{partial_path}\", { #{var_name}: #{var_name}, helpers })"
      end

      # Method calls on objects
      if obj
        obj_str = to_js(obj)
        ts_name = name.gsub(/_([a-z])/) { |_, m| m[1].upcase }
        # Known properties vs method calls
        # Known properties: struct fields and common accessors
        is_field = @known_fields.includes?(ts_name) ||
                   {"id", "errors", "length", "persisted"}.includes?(ts_name)
        if args.empty? && is_field
          return "#{obj_str}.#{ts_name}"
        end
        # MethodMap fallback: consult TypeResolver for Ruby→TS translations
        # not already handled above (e.g., gsub, start_with?, downcase).
        if r = @resolver
          mapping = Railcar.lookup_method(:typescript, r.resolve(obj), name)
          if mapping
            return Railcar.apply_mapping(mapping, obj_str, args)
          end
        end
        return "#{obj_str}.#{ts_name}(#{args.join(", ")})"
      end

      # Bare name with no args — likely a local variable reference
      # (Prism parses Ruby locals as bare calls when there's no prior assignment)
      if args.empty? && !node.block && !node.named_args
        return name
      end

      # Bare function call
      ts_name = name.gsub(/_([a-z])/) { |_, m| m[1].upcase }
      "#{ts_name}(#{args.join(", ")})"
    end

    private def to_js_condition(node : Crystal::ASTNode) : String
      case node
      when Crystal::Var
        node.name
      when Crystal::Call
        if node.name == "any?" && node.obj
          "#{to_js(node.obj.not_nil!)}.length > 0"
        elsif node.name == "nil?" && node.obj
          "#{to_js(node.obj.not_nil!)} == null"
        elsif node.name == "present?" && node.obj
          to_js(node.obj.not_nil!)
        else
          to_js(node)
        end
      when Crystal::Not
        "!(#{to_js_condition(node.exp)})"
      when Crystal::And
        "#{to_js_condition(node.left)} && #{to_js_condition(node.right)}"
      when Crystal::Or
        "#{to_js_condition(node.left)} || #{to_js_condition(node.right)}"
      else
        to_js(node)
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
