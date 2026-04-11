# Filter: Expand form_with blocks into raw HTML string operations.
#
# Converts Rails form builder calls into _buf string concatenation
# that produces HTML form tags and fields. After this filter runs,
# no form.label, form.text_field, etc. calls remain — only _buf
# string operations that any target language can serialize.
#
# Input (inside _buf.append= block):
#   form_with(model: article, class: "contents") do |form|
#     form.label :title, class: "block font-medium"
#     form.text_field :title, class: "border rounded p-2"
#     form.textarea :body, rows: 4, class: "border rounded p-2"
#     form.submit class: "bg-blue-600 text-white px-4 py-2"
#   end
#
# Output:
#   _buf += '<form action="..." method="post" class="contents">'
#   _buf += '<label for="article_title" class="block font-medium">Title</label>'
#   _buf += '<input type="text" name="article[title]" ...>'
#   _buf += '<textarea name="article[body]" rows="4" ...>...</textarea>'
#   _buf += '<input type="submit" value="..." class="...">'
#   _buf += '</form>'

require "compiler/crystal/syntax"
require "../generator/inflector"

module Railcar
  class FormToHTML < Crystal::Transformer
    # Transform _buf.append= form_with(...) do |form| ... end
    # into a sequence of _buf += "..." string operations
    def transform(node : Crystal::Call) : Crystal::ASTNode
      # Match: _buf.append= form_with(...) { |form| ... }
      if node.name == "append=" && node.obj.is_a?(Crystal::Var) && node.obj.as(Crystal::Var).name == "_buf"
        arg = node.args[0]?
        if arg.is_a?(Crystal::Call) && arg.name == "form_with" && arg.block
          return expand_form(arg, arg.block.not_nil!)
        end
      end

      # Recurse into children
      node.obj = node.obj.try(&.transform(self))
      node.args = node.args.map { |a| a.transform(self) }
      if named = node.named_args
        node.named_args = named.map { |na|
          Crystal::NamedArgument.new(na.name, na.value.transform(self))
        }
      end
      if block = node.block
        node.block = block.transform(self).as(Crystal::Block)
      end
      node
    end

    def transform(node : Crystal::If) : Crystal::ASTNode
      Crystal::If.new(
        node.cond.transform(self),
        node.then.transform(self),
        node.else.try(&.transform(self))
      )
    end

    private def expand_form(call : Crystal::Call, block : Crystal::Block) : Crystal::ASTNode
      # Extract model info from named args
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
              elsif elem1.is_a?(Crystal::Call) && elem1.name == "new"
                child_class = elem1.obj.to_s.downcase if elem1.obj
              end
            else
              model_var = val.to_s
            end
          when "class"
            css_class = val_to_string(na.value)
          end
        end
      end

      model_prefix = model_var || child_class || "item"
      stmts = [] of Crystal::ASTNode

      # Opening <form> tag
      css_attr = css_class ? " class=\"#{css_class}\"" : ""
      if parent_var && child_class
        plural = Inflector.pluralize(child_class)
        stmts << buf_str("<form action=\"' + str(#{parent_var}_#{plural}_path(#{parent_var})) + '\" method=\"post\"#{css_attr}>")
      elsif model_var
        plural = Inflector.pluralize(model_var)
        # Dynamic form: new vs edit
        stmts << buf_append(Crystal::Call.new(nil, "form_with_open_tag",
          named_args: [
            Crystal::NamedArgument.new("model", Crystal::Var.new(model_var)),
            css_class ? Crystal::NamedArgument.new("class", Crystal::StringLiteral.new(css_class)) : nil,
          ].compact))
      else
        stmts << buf_str("<form method=\"post\"#{css_attr}>")
      end

      # Process block body — convert form.* calls to HTML
      if body = block.body
        expand_form_body(body, stmts, model_prefix)
      end

      # Closing </form>
      stmts << buf_str("</form>")

      Crystal::Expressions.new(stmts)
    end

    private def expand_form_body(node : Crystal::ASTNode, stmts : Array(Crystal::ASTNode), model_prefix : String)
      case node
      when Crystal::Expressions
        node.expressions.each { |e| expand_form_body(e, stmts, model_prefix) }
      when Crystal::OpAssign
        # _buf += "..." — pass through
        stmts << node
      when Crystal::Call
        obj = node.obj
        if obj.is_a?(Crystal::Var) && obj.name == "_buf" && node.name == "append="
          actual = node.args[0]?
          actual = unwrap_to_s(actual) if actual
          if actual.is_a?(Crystal::Call) && actual.obj.is_a?(Crystal::Var) &&
             actual.obj.as(Crystal::Var).name == "form"
            # form.label, form.text_field, etc.
            stmts << expand_form_field(actual, model_prefix)
          elsif actual
            stmts << node
          end
        elsif node.block
          # Nested block (e.g., errors.each) — pass through with transform
          stmts << node.transform(self)
        else
          stmts << node
        end
      when Crystal::If
        # if article.errors.any? — pass through with form body expansion
        then_stmts = [] of Crystal::ASTNode
        expand_form_body(node.then, then_stmts, model_prefix)
        else_stmts = [] of Crystal::ASTNode
        expand_form_body(node.else, else_stmts, model_prefix) if node.else

        then_body = then_stmts.size == 1 ? then_stmts[0] : Crystal::Expressions.new(then_stmts)
        else_body = else_stmts.empty? ? nil : (else_stmts.size == 1 ? else_stmts[0] : Crystal::Expressions.new(else_stmts))
        stmts << Crystal::If.new(node.cond, then_body, else_body)
      when Crystal::Nop
        # skip
      end
    end

    private def expand_form_field(call : Crystal::Call, model_prefix : String) : Crystal::ASTNode
      method = call.name
      field = extract_symbol_arg(call)

      case method
      when "label"
        return buf_str("") unless field
        field_id = "#{model_prefix}_#{field}"
        css = extract_named_string(call, "class")
        css_attr = css ? " class=\"#{css}\"" : ""
        buf_str("<label for=\"#{field_id}\"#{css_attr}>#{field.capitalize}</label>")
      when "text_field"
        return buf_str("") unless field
        field_id = "#{model_prefix}_#{field}"
        css = extract_named_string(call, "class")
        css_attr = css ? " class=\"#{css}\"" : ""
        # Value needs to be dynamic — use _buf.append= with interpolation
        buf_concat(
          "<input type=\"text\" name=\"#{model_prefix}[#{field}]\" id=\"#{field_id}\" value=\"",
          Crystal::Call.new(Crystal::Var.new(model_prefix), field),
          "\"#{css_attr}>"
        )
      when "text_area", "textarea"
        return buf_str("") unless field
        field_id = "#{model_prefix}_#{field}"
        css = extract_named_string(call, "class")
        rows = extract_named_string(call, "rows")
        css_attr = css ? " class=\"#{css}\"" : ""
        rows_attr = rows ? " rows=\"#{rows}\"" : ""
        buf_concat(
          "<textarea name=\"#{model_prefix}[#{field}]\" id=\"#{field_id}\"#{rows_attr}#{css_attr}>\n",
          Crystal::Call.new(Crystal::Var.new(model_prefix), field),
          "</textarea>"
        )
      when "submit"
        explicit_text = call.args[0]?.is_a?(Crystal::StringLiteral) ? call.args[0].as(Crystal::StringLiteral).value : nil
        css = extract_named_string(call, "class")
        css_attr = css ? " class=\"#{css}\"" : ""
        if explicit_text
          buf_str("<button type=\"submit\"#{css_attr}>#{explicit_text}</button>")
        else
          # Dynamic submit text based on model state
          buf_append(Crystal::Call.new(nil, "form_submit_tag",
            named_args: [
              Crystal::NamedArgument.new("model", Crystal::Var.new(model_prefix)),
              css ? Crystal::NamedArgument.new("class", Crystal::StringLiteral.new(css)) : nil,
            ].compact))
        end
      else
        buf_str("")
      end
    end

    # --- Helpers ---

    # _buf += "string"
    private def buf_str(s : String) : Crystal::ASTNode
      Crystal::OpAssign.new(
        Crystal::Var.new("_buf"),
        "+",
        Crystal::StringLiteral.new(s)
      )
    end

    # _buf.append= expr (will become _buf += str(expr) in Python, <%= expr %> in Crystal)
    private def buf_append(expr : Crystal::ASTNode) : Crystal::ASTNode
      Crystal::Call.new(
        Crystal::Var.new("_buf"),
        "append=",
        [Crystal::Call.new(expr, "to_s")] of Crystal::ASTNode
      )
    end

    # _buf += "before" + str(expr) + "after"
    # Emitted as three statements: buf_str + buf_append + buf_str
    private def buf_concat(before : String, expr : Crystal::ASTNode, after : String) : Crystal::ASTNode
      Crystal::Expressions.new([
        buf_str(before),
        buf_append(expr),
        buf_str(after),
      ] of Crystal::ASTNode)
    end

    private def unwrap_to_s(node : Crystal::ASTNode?) : Crystal::ASTNode?
      return nil unless node
      result = node
      if result.is_a?(Crystal::Call) && result.name == "to_s" && result.obj
        result = result.obj.not_nil!
      end
      if result.is_a?(Crystal::Expressions) && result.expressions.size == 1
        result = result.expressions[0]
      end
      result
    end

    private def extract_symbol_arg(call : Crystal::Call) : String?
      arg = call.args[0]?
      case arg
      when Crystal::SymbolLiteral then arg.value
      when Crystal::StringLiteral then arg.value
      else nil
      end
    end

    private def extract_named_string(call : Crystal::Call, key : String) : String?
      call.named_args.try do |named|
        named.each do |na|
          if na.name == key
            return val_to_string(na.value)
          end
        end
      end
      nil
    end

    private def val_to_string(v : Crystal::ASTNode) : String?
      case v
      when Crystal::StringLiteral then v.value
      when Crystal::NumberLiteral then v.value
      when Crystal::ArrayLiteral
        # Conditional class arrays — extract first string
        if v.elements.size > 0 && v.elements[0].is_a?(Crystal::StringLiteral)
          v.elements[0].as(Crystal::StringLiteral).value
        else
          nil
        end
      else nil
      end
    end
  end
end
