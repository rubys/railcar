# Converts Rails ERB templates to Jinja2 templates for Python output.
#
# Text-level converter that handles the common Rails ERB patterns
# found in blog-style apps: link_to, button_to, form_with, render,
# turbo_stream_from, dom_id, pluralize, truncate.

require "./inflector"

module Railcar
  class PythonErbConverter
    getter controller : String
    getter block_stack : Array(Symbol)
    getter form_model : String

    def initialize(@controller : String)
      @block_stack = [] of Symbol
      @form_model = ""
    end

    def convert(source : String, is_partial : Bool = false) : String
      result = IO::Memory.new
      @block_stack.clear

      pos = 0
      while pos < source.size
        tag_start = source.index("<%", pos)

        if tag_start.nil?
          result << source[pos..]
          break
        end

        result << source[pos...tag_start]

        tag_end = source.index("%>", tag_start)
        break unless tag_end

        raw = source[(tag_start + 2)...tag_end]
        stripped = raw.strip

        if stripped.starts_with?('#')
          # Comment — skip
        elsif stripped.starts_with?('=')
          expr = stripped[1..].strip
          result << convert_output(expr)
        else
          result << convert_code(stripped)
        end

        pos = tag_end + 2
      end

      result.to_s
    end

    private def convert_output(expr : String) : String
      # Skip Rails-specific helpers
      return "" if expr == "csrf_meta_tags" || expr == "csp_meta_tag"
      return "" if expr.starts_with?("stylesheet_link_tag") || expr == "javascript_importmap_tags"
      return "" if expr.starts_with?("yield :head")

      # yield → block content
      if expr == "yield"
        return "{% block content %}{% endblock %}"
      end

      # content_for(:title) || "default"
      if expr =~ /content_for\(:title\)\s*\|\|\s*"([^"]*)"/
        return "{{ title|default(\"#{$1}\") }}"
      end

      # turbo_stream_from with interpolation
      if expr =~ /turbo_stream_from\s+"([^"]*)\#\{(@?\w+)\.(\w+)\}([^"]*)"/
        var = $2.lstrip('@')
        return "{{ turbo_stream_from(\"#{$1}\" ~ #{var}.#{$3}|string ~ \"#{$4}\") }}"
      end

      # turbo_stream_from simple
      if expr =~ /turbo_stream_from\s+"([^"]+)"/
        return "{{ turbo_stream_from(\"#{$1}\") }}"
      end

      # render collection: render @articles or render @article.comments
      if expr =~ /render\s+@(\w+)\.(\w+)/
        parent = $1
        assoc = $2
        singular = Inflector.singularize(assoc)
        model_controller = Inflector.pluralize(singular)
        return "{% for #{singular} in #{parent}.#{assoc}() %}{% include '#{model_controller}/_#{singular}.html' %}{% endfor %}"
      end

      if expr =~ /render\s+@(\w+)\s*$/
        collection = $1
        singular = Inflector.singularize(collection)
        return "{% for #{singular} in #{collection} %}{% include '#{controller}/_#{singular}.html' %}{% endfor %}"
      end

      # render partial: render "form", article: @article
      if expr =~ /render\s+"(\w+)"(?:,\s*\w+:\s*@\w+)?/
        return "{% include '#{controller}/_#{$1}.html' %}"
      end

      # link_to
      if expr.starts_with?("link_to ")
        return "{{ #{convert_link_to(expr[8..])} }}"
      end

      # button_to
      if expr.starts_with?("button_to ")
        return "{{ #{convert_button_to(expr[10..])} }}"
      end

      # dom_id with prefix
      if expr =~ /dom_id\((\w+),\s*:(\w+)\)/
        return "{{ dom_id(#{$1}, \"#{$2}\") }}"
      end

      # dom_id simple
      if expr =~ /dom_id\((\w+)\)/
        return "{{ dom_id(#{$1}) }}"
      end

      # pluralize
      if expr =~ /pluralize\((.+),\s*"(\w+)"\)/
        count_expr = convert_ruby_expr($1)
        return "{{ pluralize(#{count_expr}, \"#{$2}\") }}"
      end

      # truncate
      if expr =~ /truncate\((.+),\s*length:\s*(\d+)\)/
        text_expr = convert_ruby_expr($1)
        return "{{ #{text_expr}|truncate(#{$2}) }}"
      end

      # form builder fields
      if expr =~ /form\.(\w+)\s+(.*)/m
        return convert_form_field($1, $2.strip)
      end

      # Simple expressions: @var.prop or var.prop
      "{{ #{convert_ruby_expr(expr)} }}"
    end

    private def convert_code(stmt : String) : String
      # content_for :title, "text"
      if stmt =~ /content_for\s+:title,\s*"([^"]*)"/
        return "{% set title = \"#{$1}\" %}"
      end

      # if expr.present?
      if stmt =~ /if\s+(\w+)\.present\?/
        return "{% if #{$1} %}"
      end

      # if @collection.any?
      if stmt =~ /if\s+@(\w+)\.any\?/
        return "{% if #{$1} %}"
      end

      # if expr.errors.any?
      if stmt =~ /if\s+(\w+)\.errors\.any\?/
        return "{% if #{$1}.errors %}"
      end

      # collection.each do |var|
      if stmt =~ /(\w+)\.errors\.each\s+do\s*\|(\w+)\|/
        @block_stack.push(:for)
        return "{% for #{$2} in #{$1}.errors %}"
      end

      if stmt =~ /(@?\w+(?:\.\w+)*)\.each\s+do\s*\|(\w+)\|/
        @block_stack.push(:for)
        collection = convert_ruby_expr($1)
        return "{% for #{$2} in #{collection} %}"
      end

      # elsif
      if stmt =~ /elsif\s+(.*)/
        cond = convert_ruby_condition($1)
        return "{% elif #{cond} %}"
      end

      # else
      if stmt.strip == "else"
        return "{% else %}"
      end

      # end
      if stmt.strip == "end"
        if @block_stack.empty?
          return "{% endif %}"
        end
        kind = @block_stack.pop
        case kind
        when :for  then return "{% endfor %}"
        when :if   then return "{% endif %}"
        when :form then return "</form>"
        else            return "{% endif %}"
        end
      end

      # if condition
      if stmt =~ /if\s+(.*)/
        @block_stack.push(:if)
        cond = convert_ruby_condition($1)
        return "{% if #{cond} %}"
      end

      # form_with model: [parent, Child.new], class: "..." do |form|
      if stmt =~ /form_with[\s(]+model:\s*\[(@?\w+),\s*(\w+)\.new\](?:,\s*class:\s*"([^"]*)")?\s*(?:\))?\s*do\s*\|(\w+)\|/
        @block_stack.push(:form)
        parent = $1.lstrip('@')
        child = $2
        css = $3
        child_singular = Inflector.underscore(child)
        child_plural = Inflector.pluralize(child_singular)
        @form_model = child_singular
        css_attr = css.empty? ? "" : " class=\"#{css}\""
        return "<form action=\"{{ article_#{child_plural}_path(#{parent}) }}\" method=\"post\"#{css_attr}>"
      end

      # form_with(model: article, class: "...") do |form|
      if stmt =~ /form_with[\s(]+model:\s*(@?\w+)(?:,\s*class:\s*"([^"]*)")?\s*(?:\))?\s*do\s*\|(\w+)\|/
        @block_stack.push(:form)
        model = $1.lstrip('@')
        css = $2
        @form_model = model
        css_attr = css.empty? ? "" : " class=\"#{css}\""
        plural = Inflector.pluralize(model)
        return "{% if #{model}.id %}\n" \
               "<form action=\"/#{plural}/{{ #{model}.id }}\" method=\"post\"#{css_attr}>\n" \
               "<input type=\"hidden\" name=\"_method\" value=\"patch\">\n" \
               "{% else %}\n" \
               "<form action=\"/#{plural}\" method=\"post\"#{css_attr}>\n" \
               "{% endif %}"
      end

      # Fallback: emit as Jinja2 comment
      "{# #{stmt} #}"
    end

    private def convert_form_field(method : String, args_str : String) : String
      # Parse field name (first argument, usually a symbol :name)
      field = ""
      if args_str =~ /^:(\w+)/
        field = $1
        rest = args_str.sub(/^:\w+\s*,?\s*/, "")
      else
        rest = args_str
      end

      # Extract class
      css = ""
      if rest =~ /class:\s*"([^"]*)"/
        css = $1
      elsif rest =~ /class:\s*\[([^\]]*)\]/
        # Conditional class array — extract first string
        if $1 =~ /"([^"]*)"/
          css = $1
        end
      end

      # Extract rows
      rows = ""
      if rest =~ /rows:\s*(\d+)/
        rows = $1
      end

      prefix = @form_model
      field_id = "#{prefix}_#{field}"
      field_name = "#{prefix}[#{field}]"
      css_attr = css.empty? ? "" : " class=\"#{css}\""
      rows_attr = rows.empty? ? "" : " rows=\"#{rows}\""

      case method
      when "label"
        label_text = field.capitalize
        "<label for=\"#{field_id}\"#{css_attr}>#{label_text}</label>"
      when "text_field"
        "<input type=\"text\" name=\"#{field_name}\" id=\"#{field_id}\" value=\"{{ #{prefix}.#{field} or '' }}\"#{css_attr}>"
      when "text_area", "textarea"
        "<textarea name=\"#{field_name}\" id=\"#{field_id}\"#{rows_attr}#{css_attr}>\n{{ #{prefix}.#{field} or '' }}</textarea>"
      when "submit"
        # Check if there's an explicit text
        if args_str =~ /^"([^"]*)"/
          text = $1
          "<button type=\"submit\"#{css_attr}>#{text}</button>"
        else
          "<input type=\"submit\" value=\"{{ 'Update' if #{prefix}.id else 'Create' }} #{prefix.capitalize}\"#{css_attr}>"
        end
      else
        "{{ form.#{method}(#{args_str}) }}"
      end
    end

    private def convert_link_to(args_str : String) : String
      args = split_ruby_args(args_str)
      return "link_to()" if args.empty?

      text = convert_ruby_expr(args[0])
      path = args.size > 1 ? convert_path_arg(args[1]) : "\"/\""
      kwargs = convert_kwargs(args[2..])

      "link_to(#{text}, #{path}#{kwargs})"
    end

    private def convert_button_to(args_str : String) : String
      args = split_ruby_args(args_str)
      return "button_to()" if args.empty?

      text = convert_ruby_expr(args[0])
      path = args.size > 1 ? convert_path_arg(args[1]) : "\"/\""
      kwargs = convert_kwargs(args[2..])

      "button_to(#{text}, #{path}#{kwargs})"
    end

    private def convert_path_arg(arg : String) : String
      stripped = arg.strip

      # Route helpers
      if stripped =~ /^new_(\w+)_path$/
        model = $1
        return "\"/#{Inflector.pluralize(model)}/new\""
      end

      if stripped =~ /^(\w+)s_path$/
        return "\"/#{$1}s\""
      end

      if stripped =~ /^edit_(\w+)_path\((@?\w+)\)$/
        var = $2.lstrip('@')
        return "\"/#{Inflector.pluralize($1)}/\" ~ #{var}.id|string ~ \"/edit\""
      end

      if stripped =~ /^(\w+)_path\((@?\w+)\)$/
        var = $2.lstrip('@')
        return "\"/#{Inflector.pluralize($1)}/\" ~ #{var}.id|string"
      end

      # Array path: [comment.article, comment] → nested resource
      if stripped =~ /^\[(.+)\]$/
        elements = $1.split(",").map(&.strip)
        if elements.size == 2
          parent_expr = elements[0]
          child_expr = elements[1]
          # comment.article → use comment.article_id
          if parent_expr =~ /(\w+)\.(\w+)/
            child_var = $1
            parent_model = $2
            return "\"/#{Inflector.pluralize(parent_model)}/\" ~ #{child_var}.#{parent_model}_id|string ~ \"/#{Inflector.pluralize(child_expr)}/\" ~ #{child_expr}.id|string"
          end
        end
      end

      # Model variable as path: article or @article
      if stripped =~ /^@?(\w+)$/ && !stripped.starts_with?('"')
        var = stripped.lstrip('@')
        return "\"/#{Inflector.pluralize(var)}/\" ~ #{var}.id|string"
      end

      convert_ruby_expr(stripped)
    end

    private def convert_kwargs(args : Array(String)) : String
      return "" if args.empty?

      result = [] of String
      i = 0
      while i < args.size
        arg = args[i]

        # data: { turbo_confirm: "..." } — flatten to data_turbo_confirm
        if arg =~ /^data:\s*\{(.+)\}$/m
          inner = $1.strip
          inner.scan(/(\w+):\s*"([^"]*)"/) do |m|
            result << "data_#{m[1]}=\"#{m[2]}\""
          end
        elsif arg =~ /^(\w+):\s*:(\w+)$/
          result << "#{$1}=\"#{$2}\""
        elsif arg =~ /^(\w+):\s*"([^"]*)"$/
          result << "#{$1}=\"#{$2}\""
        elsif arg =~ /^(\w+):\s*(.+)$/
          result << "#{$1}=#{convert_ruby_expr($2)}"
        end
        i += 1
      end

      return "" if result.empty?
      ", " + result.join(", ")
    end

    private def convert_ruby_expr(expr : String) : String
      s = expr.strip

      # Strip @
      s = s.gsub(/@(\w+)/) { $1 }

      # .size → |length (for Jinja2 filter)
      s = s.gsub(/\.size\b/, "|length")

      # .count (no args) → |length
      s = s.gsub(/\.count\b(?!\()/, "|length")

      # .present? → (just truthy)
      s = s.gsub(/\.present\?/, "")

      # .any? → (just truthy)
      s = s.gsub(/\.any\?/, "")

      # error.full_message → error
      s = s.gsub(/\.full_message/, "")

      # Symbol :name → "name"
      s = s.gsub(/:(\w+)/) { "\"#{$1}\"" }

      s
    end

    private def convert_ruby_condition(cond : String) : String
      convert_ruby_expr(cond)
    end

    # Split arguments respecting quotes, parens, brackets, braces
    private def split_ruby_args(s : String) : Array(String)
      args = [] of String
      current = IO::Memory.new
      depth = 0
      in_string = false
      string_char = '"'
      i = 0

      while i < s.size
        c = s[i]

        if in_string
          current << c
          if c == string_char && (i == 0 || s[i - 1] != '\\')
            in_string = false
          end
        elsif c == '"' || c == '\''
          current << c
          in_string = true
          string_char = c
        elsif c == '(' || c == '[' || c == '{'
          current << c
          depth += 1
        elsif c == ')' || c == ']' || c == '}'
          current << c
          depth -= 1
        elsif c == ',' && depth == 0
          args << current.to_s.strip
          current = IO::Memory.new
        else
          current << c
        end
        i += 1
      end

      remainder = current.to_s.strip
      args << remainder unless remainder.empty?
      args
    end
  end
end
