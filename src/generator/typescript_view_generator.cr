# Generates TypeScript view functions from Rails ERB templates.
#
# Pipeline: ERB → ErbCompiler → Crystal AST → shared view filters →
#           TypeScriptView filter → ViewCleanup → BufToInterpolation →
#           Cr2Ts emitter → TypeScript template literal functions.

require "./inflector"
require "./source_parser"
require "./erb_compiler"
require "../filters/instance_var_to_local"
require "../filters/rails_helpers"
require "../filters/link_to_path_helper"
require "../filters/button_to_path_helper"
require "../filters/render_to_partial"
require "../filters/form_to_html"
require "../filters/typescript_view"
require "../filters/view_cleanup"
require "../filters/buf_to_interpolation"
require "../emitter/typescript/cr2ts"

module Railcar
  class TypeScriptViewGenerator
    getter app : AppModel
    getter rails_dir : String
    getter emitter : Cr2Ts::Emitter

    def initialize(@app, @rails_dir, @emitter = Cr2Ts::Emitter.new)
    end

    def generate(output_dir : String)
      views_dir = File.join(output_dir, "views")
      Dir.mkdir_p(views_dir)

      rails_views = File.join(rails_dir, "app/views")

      app.controllers.each do |info|
        controller_name = Inflector.underscore(info.name).chomp("_controller")
        template_dir = File.join(rails_views, Inflector.pluralize(controller_name))
        next unless Dir.exists?(template_dir)

        model_name = Inflector.classify(Inflector.singularize(controller_name))
        singular = Inflector.singularize(controller_name)
        plural = Inflector.pluralize(controller_name)

        io = IO::Memory.new
        io << "import * as helpers from \"../helpers.js\";\n"

        # Import models
        io << "import { #{model_name} } from \"../models/#{Inflector.underscore(model_name)}.js\";\n"
        app.models.each_key do |name|
          next if name == model_name
          has_ref = Dir.glob(File.join(template_dir, "*.html.erb")).any? do |path|
            File.read(path).includes?(name) || File.read(path).includes?(Inflector.underscore(name))
          end
          io << "import { #{name} } from \"../models/#{Inflector.underscore(name)}.js\";\n" if has_ref
        end

        # Import other view modules for cross-references (e.g., render_comment_partial)
        app.controllers.each do |other_info|
          other_name = Inflector.underscore(other_info.name).chomp("_controller")
          next if other_name == controller_name
          other_singular = Inflector.singularize(other_name)
          other_plural = Inflector.pluralize(other_name)
          has_ref = Dir.glob(File.join(template_dir, "*.html.erb")).any? do |path|
            content = File.read(path)
            content.includes?("render @article.#{other_plural}") ||
            content.includes?("render @#{other_singular}") ||
            content.includes?("render #{other_singular}")
          end
          if has_ref
            io << "import * as #{other_name}Views from \"./#{other_plural}.js\";\n"
          end
        end
        io << "\n"

        # Process each template through the AST pipeline
        Dir.glob(File.join(template_dir, "*.html.erb")).sort.each do |erb_path|
          basename = File.basename(erb_path, ".html.erb")
          emit_view_function(erb_path, basename, singular, io)
        end

        out_path = File.join(views_dir, "#{plural}.ts")
        File.write(out_path, io.to_s)
        puts "  views/#{plural}.ts"
      end
    end

    private def emit_view_function(erb_path : String, basename : String, singular : String, io : IO)
      is_partial = basename.starts_with?("_")
      func_name = if is_partial
                    "render#{Inflector.classify(basename.lstrip('_'))}Partial"
                  else
                    "render#{Inflector.classify(basename)}"
                  end

      # ERB → Ruby _buf code → Crystal AST
      erb_source = File.read(erb_path)
      ruby_code = ErbCompiler.new(erb_source).src

      begin
        ast = SourceParser.parse_source(ruby_code)

        # Shared view filter chain (same as Python2Generator)
        ast = ast.transform(InstanceVarToLocal.new)
        ast = ast.transform(RailsHelpers.new)
        ast = ast.transform(LinkToPathHelper.new)
        ast = ast.transform(ButtonToPathHelper.new)
        ast = ast.transform(RenderToPartial.new)
        ast = ast.transform(FormToHTML.new)

        # TypeScript-specific view filter
        locals = [singular]
        ast = ast.transform(TypeScriptView.new(locals))
        ast = ast.transform(ViewCleanup.new)

        # Convert bare calls matching parameter names to Var nodes
        plural = Inflector.pluralize(singular)
        ast = ViewCleanup.calls_to_vars(ast, [singular, plural, "_buf", "notice", "flash", "form"])
        ast = ast.transform(BufToInterpolation.new)

        # Strip def render wrapper
        body = ast
        while body.is_a?(Crystal::Def) && body.name == "render"
          body = body.body
        end

        # Build TypeScript function
        if is_partial
          io << "export function #{func_name}(...args: unknown[]): string {\n"
          io << "  const #{singular} = (args[args.length - 1]) as any;\n"
        else
          param_name = basename == "index" ? Inflector.pluralize(singular) : singular
          io << "export function #{func_name}(#{param_name}: any, notice?: string | null): string {\n"
        end

        # Emit body through Cr2Ts
        emit_view_body(body, io, singular)

        io << "  return _buf;\n"
        io << "}\n\n"
      rescue ex
        STDERR.puts "  WARN: #{func_name}: #{ex.message}"
        io << "export function #{func_name}(...args: unknown[]): string {\n"
        io << "  return `<!-- #{basename} template -->`;\n"
        io << "}\n\n"
      end
    end

    private def emit_view_body(node : Crystal::ASTNode, io : IO, singular : String)
      case node
      when Crystal::Expressions
        node.expressions.each do |expr|
          emit_view_stmt(expr, io, singular)
        end
      else
        emit_view_stmt(node, io, singular)
      end
    end

    private def emit_view_stmt(node : Crystal::ASTNode, io : IO, singular : String, indent : String = "  ")
      case node
      when Crystal::Assign
        target = emitter.emit_expr(node.target)
        value = emitter.emit_expr(node.value)
        io << "#{indent}let #{target} = #{value};\n"

      when Crystal::OpAssign
        # _buf += "string" or _buf += `template ${expr}`
        target = emitter.emit_expr(node.target)
        value = emit_view_value(node.value)
        io << "#{indent}#{target} #{node.op}= #{value};\n"

      when Crystal::If
        cond = emit_view_condition(node.cond)
        io << "#{indent}if (#{cond}) {\n"
        emit_view_body_indented(node.then, io, singular, indent + "  ")
        if node.else && !node.else.is_a?(Crystal::Nop)
          io << "#{indent}} else {\n"
          emit_view_body_indented(node.else, io, singular, indent + "  ")
        end
        io << "#{indent}}\n"

      when Crystal::Call
        if node.name == "each" && node.block && node.obj
          # for loop: collection.each { |item| ... }
          block = node.block.not_nil!
          block_arg = block.args.first?.try(&.name) || "item"
          collection = emit_view_value(node.obj.not_nil!)
          io << "#{indent}for (const #{block_arg} of #{collection}) {\n"
          emit_view_body_indented(block.body, io, singular, indent + "  ")
          io << "#{indent}}\n"
        else
          io << "#{indent}#{emit_view_value(node)};\n"
        end

      when Crystal::Nop
        # skip

      else
        io << "#{indent}#{emit_view_value(node)};\n"
      end
    end

    private def emit_view_body_indented(node : Crystal::ASTNode, io : IO, singular : String, indent : String)
      case node
      when Crystal::Expressions
        node.expressions.each { |e| emit_view_stmt(e, io, singular, indent) }
      else
        emit_view_stmt(node, io, singular, indent)
      end
    end

    private def emit_view_value(node : Crystal::ASTNode) : String
      case node
      when Crystal::StringLiteral
        # Use backtick template literal for multiline, quotes for single line
        if node.value.includes?("\n") || node.value.includes?("${")
          escaped = node.value.gsub("\\", "\\\\").gsub("`", "\\`")
          "`#{escaped}`"
        else
          node.value.inspect
        end

      when Crystal::StringInterpolation
        # Template literal with ${} expressions
        parts = node.expressions.map do |part|
          case part
          when Crystal::StringLiteral
            part.value.gsub("\\", "\\\\").gsub("`", "\\`")
          else
            "${#{emit_view_value(part)}}"
          end
        end
        "`#{parts.join}`"

      when Crystal::Call
        name = node.name
        obj = node.obj

        # _buf helper calls → helpers.name(args)
        if name == "str" && !obj && node.args.size == 1
          # str(expr) → String(expr) — but in template literals, auto-coerced
          "String(#{emit_view_value(node.args[0])})"
        elsif name == "render_article_partial" || name == "render_comment_partial" ||
              name == "render_form_partial" || name.starts_with?("render_") && name.ends_with?("_partial")
          # render_*_partial → camelCase function call
          ts_name = name.gsub(/_([a-z])/) { |_, m| m[1].upcase }
          args = node.args.map { |a| emit_view_value(a) }
          if named = node.named_args
            named.each { |na| args << "#{na.name}: #{emit_view_value(na.value)}" }
          end
          # Check if this is a cross-module partial
          if name.includes?("comment") && !name.includes?("article")
            "commentsViews.#{ts_name}(#{args.join(", ")})"
          else
            "#{ts_name}(#{args.join(", ")})"
          end
        elsif {"link_to", "button_to", "truncate", "dom_id", "pluralize",
               "turbo_stream_from", "form_with_open_tag", "form_submit_tag"}.includes?(name)
          ts_name = name.gsub(/_([a-z])/) { |_, m| m[1].upcase }
          args = node.args.map { |a| emit_view_value(a) }
          if named = node.named_args
            # Convert named args to object: { class: "...", method: "..." }
            opts = named.map { |na|
              key = na.name == "class" ? "class" : na.name
              "#{key}: #{emit_view_value(na.value)}"
            }
            args << "{ #{opts.join(", ")} }"
          end
          "helpers.#{ts_name}(#{args.join(", ")})"
        elsif name == "length" && obj
          "#{emit_view_value(obj)}.length"
        elsif name == "[]" && obj
          "#{emit_view_value(obj)}[#{node.args.map { |a| emit_view_value(a) }.join}]"
        elsif obj
          obj_str = emit_view_value(obj)
          args = node.args.map { |a| emit_view_value(a) }
          ts_name = name.gsub(/_([a-z])/) { |_, m| m[1].upcase }
          if args.empty? && !node.block
            "#{obj_str}.#{ts_name}"
          else
            "#{obj_str}.#{ts_name}(#{args.join(", ")})"
          end
        else
          args = node.args.map { |a| emit_view_value(a) }
          ts_name = name.gsub(/_([a-z])/) { |_, m| m[1].upcase }
          "#{ts_name}(#{args.join(", ")})"
        end

      when Crystal::Var
        node.name

      when Crystal::InstanceVar
        "this.#{node.name.lchop("@")}"

      when Crystal::Path
        node.names.join(".")

      when Crystal::NumberLiteral
        node.value.to_s.gsub(/_i64|_i32/, "")

      when Crystal::BoolLiteral
        node.value.to_s

      when Crystal::NilLiteral
        "null"

      when Crystal::SymbolLiteral
        node.value.inspect

      when Crystal::Not
        "!(#{emit_view_value(node.exp)})"

      when Crystal::Nop
        ""

      else
        "/* TODO: #{node.class.name} */"
      end
    end

    private def emit_view_condition(node : Crystal::ASTNode) : String
      case node
      when Crystal::Call
        if node.name == "nil?" && node.obj
          "#{emit_view_value(node.obj.not_nil!)} == null"
        elsif node.name == "any?" && node.obj
          "#{emit_view_value(node.obj.not_nil!)}.length > 0"
        elsif node.name == "empty?" && node.obj
          "!#{emit_view_value(node.obj.not_nil!)}"
        else
          emit_view_value(node)
        end
      when Crystal::Var
        node.name
      when Crystal::Not
        "!(#{emit_view_condition(node.exp)})"
      when Crystal::And
        "(#{emit_view_condition(node.left)} && #{emit_view_condition(node.right)})"
      when Crystal::Or
        "(#{emit_view_condition(node.left)} || #{emit_view_condition(node.right)})"
      when Crystal::BoolLiteral
        node.value.to_s
      else
        emit_view_value(node)
      end
    end
  end
end
