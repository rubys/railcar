# GoViewEmitter — converts filtered Crystal AST to Go view functions.
#
# Pipeline: ERB → ErbCompiler → Crystal AST → shared view filters →
#           ViewCleanup → BufToInterpolation → GoViewEmitter → Go source.
#
# Views become Go functions returning strings, e.g.:
#   func RenderShow(article *models.Article) string { ... }
#
# This avoids html/template entirely — method calls, loops, and
# conditionals are plain Go code. Same approach as the Python target.

require "compiler/crystal/syntax"
require "./inflector"

module Railcar
  class GoViewEmitter
    getter controller : String
    getter known_fields : Set(String)
    # Parameter names available in the current function scope
    property param_names : Set(String) = Set(String).new

    def initialize(@controller, @known_fields = Set(String).new)
    end

    # Emit a Go expression from a Crystal AST node
    def to_go(node : Crystal::ASTNode) : String
      case node
      when Crystal::StringLiteral
        node.value.inspect
      when Crystal::NumberLiteral
        node.value.to_s.gsub(/_i64|_i32/, "")
      when Crystal::BoolLiteral
        node.value.to_s
      when Crystal::NilLiteral
        "nil"
      when Crystal::SymbolLiteral
        node.value.inspect
      when Crystal::Var
        go_var_name(node.name)
      when Crystal::InstanceVar
        go_var_name(node.name.lchop("@"))
      when Crystal::Path
        node.names.join(".")
      when Crystal::Not
        "!" + to_go(node.exp)
      when Crystal::And
        to_go(node.left) + " && " + to_go(node.right)
      when Crystal::Or
        to_go(node.left) + " || " + to_go(node.right)
      when Crystal::StringInterpolation
        emit_sprintf(node)
      when Crystal::Call
        to_go_call(node)
      when Crystal::Nop
        ""
      else
        "/* TODO: #{node.class.name} */"
      end
    end

    # Emit a Go call expression
    private def to_go_call(node : Crystal::Call) : String
      name = node.name
      obj = node.obj
      args = node.args.map { |a| to_go(a) }

      # Named args → additional args
      named_args_str = ""
      if named = node.named_args
        # For button_to: collect named args into specific slots
        if name == "button_to"
          method_val = "\"post\""
          form_cls_val = "\"\""
          cls_val = "\"\""
          confirm_val = "\"\""
          named.each do |na|
            case na.name
            when "method"     then method_val = na.value.to_s.strip(':').strip('"').inspect
            when "form_class" then form_cls_val = na.value.to_s.strip('"').inspect
            when "class"      then cls_val = na.value.to_s.strip('"').inspect
            when "data_turbo_confirm" then confirm_val = na.value.to_s.strip('"').inspect
            end
          end
          args << method_val << form_cls_val << cls_val << confirm_val
        else
          named.each do |na|
            case na.name
            when "class", "form_class"
              args << na.value.to_s.strip('"').inspect
            when "method"
              args << na.value.to_s.strip(':').strip('"').inspect
            when "data_turbo_confirm"
              args << na.value.to_s.strip('"').inspect
            when "model"
              args.unshift(to_go(na.value))
            when "length"
              args << na.value.to_s
            when "rows"
              # skip — handled in HTML attributes
            end
          end
        end
      end

      case name
      when "new"
        if obj.is_a?(Crystal::Path)
          model = obj.as(Crystal::Path).names.last
          return "models.New#{model}()"
        end
        return ""
      when "to_s"
        return obj ? to_go(obj) : ""
      when "str"
        return args.first? || ""
      when "nil?"
        obj_str = obj ? to_go(obj) : ""
        return "#{obj_str} == nil"
      when "empty?"
        obj_str = obj ? to_go(obj) : ""
        return "#{obj_str} == \"\""
      when "any?"
        obj_str = obj ? to_go(obj) : ""
        return "len(#{obj_str}) > 0"
      when "present?"
        return obj ? to_go(obj) + " != \"\"" : ""
      when "size", "count", "length"
        if obj.is_a?(Crystal::Call) && obj.obj && !known_fields.includes?(obj.name) && obj.name != "errors"
          # Method returning (value, error) — need safeLen helper
          return "helpers.SafeLen(#{to_go(obj)})"
        end
        obj_str = obj ? to_go(obj) : ""
        return "len(#{obj_str})"
      when "errors"
        # Model errors — call the method
        obj_str = obj ? to_go(obj) : ""
        return "#{obj_str}.Errors()"
      end

      # Helper functions
      if !obj && {"link_to", "button_to", "truncate", "dom_id", "pluralize",
                   "turbo_stream_from", "turbo_cable_stream_tag", "turbo_stream_tag",
                   "form_with_open_tag", "form_submit_tag"}.includes?(name)
        func_name = case name
                    when "link_to"                                     then "helpers.LinkTo"
                    when "button_to"                                   then "helpers.ButtonTo"
                    when "truncate"                                    then "helpers.Truncate"
                    when "dom_id"                                      then "helpers.DomID"
                    when "pluralize"                                   then "helpers.Pluralize"
                    when "turbo_stream_from", "turbo_cable_stream_tag",
                         "turbo_stream_tag"                            then "helpers.TurboStreamFrom"
                    when "form_with_open_tag"                          then "helpers.FormWithOpenTag"
                    when "form_submit_tag"                             then "helpers.FormSubmitTag"
                    else "helpers.#{name}"
                    end
        return "#{func_name}(#{args.join(", ")})"
      end

      # Path helpers
      if !obj && name.ends_with?("_path")
        func_name = name.split("_").map(&.capitalize).join("") + "()"
        # Remove trailing () and add args
        func_name = func_name.chomp("()")
        return "helpers.#{func_name}(#{args.join(", ")})"
      end

      # Render partials → view function calls
      if !obj && name.starts_with?("render_") && name.ends_with?("_partial")
        go_func = name.split("_").map(&.capitalize).join("")
        # Capitalize: render_article_partial → RenderArticlePartial
        return "#{go_func}(#{args.join(", ")})"
      end

      # Method calls on objects
      if obj
        # belongs_to: if method name matches a function parameter, use the param directly
        # e.g., comment.article → article (when article is a parameter)
        if param_names.includes?(name)
          return name
        end
        obj_str = to_go(obj)
        go_name = go_field_name(name)
        # Known schema fields → struct field access (no parens)
        if known_fields.includes?(name) || {"id", "errors"}.includes?(name)
          return "#{obj_str}.#{go_name}"
        end
        # Everything else → method call
        return "#{obj_str}.#{go_name}(#{args.join(", ")})"
      end

      # Bare variable reference
      if args.empty? && !node.block && !node.named_args
        return go_var_name(name)
      end

      "#{name}(#{args.join(", ")})"
    end

    # Convert StringInterpolation to fmt.Sprintf
    private def emit_sprintf(node : Crystal::StringInterpolation) : String
      format_parts = [] of String
      go_args = [] of String

      node.expressions.each do |part|
        case part
        when Crystal::StringLiteral
          format_parts << part.value.gsub("\\", "\\\\").gsub("%", "%%").gsub("`", "` + \"`\" + `")
        else
          expr = to_go(part)
          # Determine format verb
          format_parts << "%v"
          go_args << expr
        end
      end

      format_str = format_parts.join
      if go_args.empty?
        # Pure string literal — use backtick
        "`#{format_str}`"
      else
        "fmt.Sprintf(`#{format_str}`, #{go_args.join(", ")})"
      end
    end

    # Emit a statement to IO with proper indentation
    def emit_stmt(node : Crystal::ASTNode, io : IO, indent : String = "\t")
      case node
      when Crystal::Expressions
        node.expressions.each { |e| emit_stmt(e, io, indent) }
      when Crystal::Assign
        target = node.target
        value = node.value
        if target.is_a?(Crystal::Var) && target.name == "_buf"
          if value.is_a?(Crystal::StringLiteral) && value.value == ""
            io << "#{indent}var buf strings.Builder\n"
          else
            io << "#{indent}buf.WriteString(#{to_go(value)})\n"
          end
        else
          io << "#{indent}#{to_go(target)} := #{to_go(value)}\n"
        end
      when Crystal::OpAssign
        target = node.target
        if target.is_a?(Crystal::Var) && target.name == "_buf"
          value = node.value
          # String literals are static HTML — always safe
          if value.is_a?(Crystal::StringLiteral)
            io << "#{indent}buf.WriteString(#{to_go(value)})\n"
          else
            io << "#{indent}buf.WriteString(#{escape_if_needed(value)})\n"
          end
        else
          io << "#{indent}#{to_go(target)} += #{to_go(node.value)}\n"
        end
      when Crystal::Call
        if node.name == "each" && node.block
          emit_loop(node, io, indent)
        elsif node.obj.is_a?(Crystal::Var) && node.obj.as(Crystal::Var).name == "_buf"
          # _buf.to_s → return buf.String()
          if node.name == "to_s"
            # Skip — we handle return separately
          end
        else
          io << "#{indent}#{to_go(node)}\n"
        end
      when Crystal::Var
        if node.name == "_buf"
          # return _buf → return buf.String()
          io << "#{indent}return buf.String()\n"
        else
          io << "#{indent}_ = #{go_var_name(node.name)}\n"
        end
      when Crystal::If
        emit_if(node, io, indent)
      when Crystal::Nop
        # skip
      else
        io << "#{indent}// TODO: #{node.class.name}\n"
      end
    end

    private def emit_loop(call : Crystal::Call, io : IO, indent : String)
      block = call.block.not_nil!
      block_arg = block.args.first?.try(&.name) || "item"
      collection = call.obj

      # Handle association calls that return (value, error)
      coll_str = collection ? to_go(collection) : "items"

      # Check if collection is a method call (returns value, error)
      needs_error_handling = collection.is_a?(Crystal::Call) && collection.as(Crystal::Call).obj != nil &&
                             !known_fields.includes?(collection.as(Crystal::Call).name) &&
                             collection.as(Crystal::Call).name != "errors"

      if needs_error_handling
        # Pre-compute: items, _ := obj.Method()
        temp_var = "#{block_arg}s"
        io << "#{indent}#{temp_var}, _ := #{coll_str}\n"
        io << "#{indent}for _, #{block_arg} := range #{temp_var} {\n"
      else
        io << "#{indent}for _, #{block_arg} := range #{coll_str} {\n"
      end

      if body = block.body
        emit_stmt(body, io, indent + "\t")
      end
      io << "#{indent}}\n"
    end

    private def emit_if(node : Crystal::If, io : IO, indent : String)
      cond = to_go_condition(node.cond)
      # Skip dead code (e.g., notice checks that always eval to false)
      return if cond == "false"
      io << "#{indent}if #{cond} {\n"
      emit_stmt(node.then, io, indent + "\t")
      if node.else && !node.else.is_a?(Crystal::Nop)
        io << "#{indent}} else {\n"
        emit_stmt(node.else.not_nil!, io, indent + "\t")
      end
      io << "#{indent}}\n"
    end

    private def to_go_condition(node : Crystal::ASTNode) : String
      case node
      when Crystal::Var
        # Skip notice/flash — not passed to views
        return "false" if {"notice", "flash"}.includes?(node.name)
        # truthiness check: nil/empty check
        "#{go_var_name(node.name)} != nil"
      when Crystal::Call
        if node.name == "any?" && node.obj
          "len(#{to_go(node.obj.not_nil!)}) > 0"
        elsif node.name == "nil?" && node.obj
          "#{to_go(node.obj.not_nil!)} == nil"
        elsif node.name == "present?" && node.obj
          "#{to_go(node.obj.not_nil!)} != \"\""
        elsif node.name == "empty?" && node.obj
          "len(#{to_go(node.obj.not_nil!)}) == 0"
        else
          to_go(node)
        end
      when Crystal::Not
        "!(#{to_go_condition(node.exp)})"
      when Crystal::And
        "#{to_go_condition(node.left)} && #{to_go_condition(node.right)}"
      when Crystal::Or
        "#{to_go_condition(node.left)} || #{to_go_condition(node.right)}"
      else
        to_go(node)
      end
    end

    # Check if an expression produces safe HTML (helper output) vs user data (model fields)
    private def safe_html?(node : Crystal::ASTNode) : Bool
      case node
      when Crystal::StringLiteral
        true
      when Crystal::Call
        name = node.name
        obj = node.obj
        # Helper functions return safe HTML
        return true if !obj && {"link_to", "button_to", "dom_id", "pluralize",
                                 "turbo_stream_from", "turbo_cable_stream_tag", "turbo_stream_tag",
                                 "form_with_open_tag", "form_submit_tag"}.includes?(name)
        # truncate returns user data (just shortened) — NOT safe
        # Path helpers return URLs (safe)
        return true if !obj && name.ends_with?("_path")
        # Render partial calls return safe HTML
        return true if !obj && name.starts_with?("render_") && name.ends_with?("_partial")
        # str() wrapper — check inner expression
        return safe_html?(node.args[0]) if name == "str" && node.args.size == 1 && !obj
        # Model field access → user data, not safe
        false
      when Crystal::StringInterpolation
        true # Interpolations are format strings we construct
      else
        false
      end
    end

    # Wrap an expression in html.EscapeString() if it contains user data
    def escape_if_needed(node : Crystal::ASTNode) : String
      expr = to_go(node)
      if safe_html?(node)
        expr
      else
        # For string fields, escape directly; for others, format first
        if is_string_expr?(node)
          "html.EscapeString(#{expr})"
        else
          "html.EscapeString(fmt.Sprintf(\"%v\", #{expr}))"
        end
      end
    end

    private def is_string_expr?(node : Crystal::ASTNode) : Bool
      case node
      when Crystal::Call
        # str(x) wrapper or field access on a known string column
        if node.name == "str" && node.args.size == 1
          return true
        end
        if node.obj && known_fields.includes?(node.name)
          col_type = node.name  # field name
          # Most schema columns are strings; int fields are article_id etc.
          return !col_type.ends_with?("_id")
        end
      end
      false
    end

    private def go_field_name(name : String) : String
      name.split("_").map(&.capitalize).join("")
    end

    private def go_var_name(name : String) : String
      return "buf" if name == "_buf"
      name
    end
  end
end
