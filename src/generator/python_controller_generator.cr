# Generates Python controller files from Rails controller source.
#
# Pipeline: Ruby source → Prism → Crystal AST → shared filters →
#           Python filters → structural transformation → Python emitter
#
# The structural transformation handles:
# - Class methods → top-level async functions
# - before_action → inlined preamble (model loading)
# - params/form data → parse_form + form_value
# - Implicit renders for actions without explicit render/redirect
# - Request parameter injection and route param extraction

require "compiler/crystal/syntax"
require "./source_parser"
require "./prism_translator"
require "./controller_extractor"
require "./python_emitter"
require "./inflector"
require "../filters/instance_var_to_local"
require "../filters/params_expect"
require "../filters/respond_to_html"
require "../filters/strong_params"
require "../filters/python_constructor"
require "../filters/python_redirect"
require "../filters/python_render"

module Railcar
  class PythonControllerGenerator
    getter app : AppModel
    getter rails_dir : String

    def initialize(@app, @rails_dir)
    end

    def generate(output_dir : String)
      controllers_dir = File.join(output_dir, "controllers")
      Dir.mkdir_p(controllers_dir) unless Dir.exists?(controllers_dir)

      # __init__.py
      File.write(File.join(controllers_dir, "__init__.py"), "")

      app.controllers.each do |info|
        controller_name = Inflector.underscore(info.name).chomp("_controller")
        generate_controller(info, controller_name, controllers_dir)
      end
    end

    private def generate_controller(info : ControllerInfo, controller_name : String, output_dir : String)
      model_name = Inflector.classify(Inflector.singularize(controller_name))
      model = app.models[model_name]?

      # Get schema columns for this model
      schema_map = {} of String => TableSchema
      app.schemas.each { |s| schema_map[s.name] = s }
      table_name = Inflector.pluralize(Inflector.underscore(model_name))
      schema = schema_map[table_name]?
      columns = schema ? schema.columns.reject { |c| c.name == "id" && true }
                          .reject { |c| %w[id created_at updated_at].includes?(c.name) }
                          .map(&.name) : [] of String

      # Parse controller source
      source_path = File.join(rails_dir, "app/controllers/#{controller_name}_controller.rb")
      return unless File.exists?(source_path)

      # Extract before_action info
      before_actions = info.before_actions
      private_methods = {} of String => Prism::Node
      info.actions.select(&.is_private).each do |action|
        private_methods[action.name] = action.body.not_nil! if action.body
      end

      io = IO::Memory.new
      io << "from aiohttp import web\n"
      io << "from models import #{model_name}\n"

      # Import other models referenced by associations
      if model
        model.associations.each do |assoc|
          case assoc.kind
          when :has_many
            target = Inflector.classify(Inflector.singularize(assoc.name))
            io << "from models import #{target}\n" unless target == model_name
          when :belongs_to
            target = Inflector.classify(assoc.name)
            io << "from models import #{target}\n" unless target == model_name
          end
        end
      end

      io << "from helpers import *\n"
      io << "from views.#{controller_name} import *\n\n"

      # Determine which actions need which preambles
      id_actions = %w[show edit update destroy]
      form_actions = %w[create update]

      # Find the parent model for nested resources
      parent_model = nil
      before_actions.each do |ba|
        if method_body = private_methods[ba.method_name]?
          body_str = method_body.to_s
          # Check if it sets a parent: @article = Article.find(...)
          if body_str =~ /@(\w+)\s*=\s*(\w+)\.find/
            parent_model = $2 if $2 != model_name
          end
        end
      end

      # Generate each public action
      info.actions.reject(&.is_private).each do |action|
        generate_action(action, info, io, controller_name, model_name,
          columns, before_actions, private_methods, parent_model)
      end

      File.write(File.join(output_dir, "#{controller_name}.py"), io.to_s)
      puts "  controllers/#{controller_name}.py"
    end

    private def generate_action(action : ControllerAction, info : ControllerInfo,
                                 io : IO, controller_name : String, model_name : String,
                                 columns : Array(String),
                                 before_actions : Array(BeforeAction),
                                 private_methods : Hash(String, Prism::Node),
                                 parent_model : String?)
      name = action.name
      singular = Inflector.underscore(model_name).downcase
      plural = Inflector.pluralize(singular)

      # Determine if this action needs form data
      needs_form = %w[create update destroy].includes?(name)

      if needs_form
        io << "async def #{name}(request, data=None):\n"
      else
        io << "async def #{name}(request):\n"
      end

      # Extract route params from before_action bodies
      # Translate via Prism to find ParamsExpect patterns, then emit param extraction
      before_actions.each do |ba|
        next if ba.only && !ba.only.not_nil!.includes?(name)
        if method_body = private_methods[ba.method_name]?
          translated = PrismTranslator.new.translate(method_body)
          translated = translated.transform(ParamsExpect.new)
          # Walk the translated AST to find param names (Var nodes named like route params)
          find_param_names(translated).each do |param_name|
            io << "    #{param_name} = int(request.match_info['#{param_name}'])\n"
          end
        end
      end

      # Parse form data (accept pre-parsed data from dispatcher)
      if needs_form
        io << "    if data is None:\n"
        io << "        data = parse_form(await request.read())\n"
      end

      # Inline before_action
      before_actions.each do |ba|
        next if ba.only && !ba.only.not_nil!.includes?(name)
        if method_body = private_methods[ba.method_name]?
          # Translate the before_action body
          translated = PrismTranslator.new.translate(method_body)
          translated = translated.transform(InstanceVarToLocal.new)
          translated = translated.transform(ParamsExpect.new)

          # Emit as Python, skipping the param extraction (already done above)
          emitter = PythonEmitter.new(indent: 1)
          body_py = emitter.emit_body(translated)
          # Filter out lines that extract params (already handled)
          body_py.each_line do |line|
            stripped = line.strip
            next if stripped.empty?
            next if stripped =~ /^\w+ = int\(request/  # already emitted
            next if stripped.starts_with?("id =") || stripped.starts_with?("article_id =")
            io << "    " unless line.starts_with?("    ")
            io << line.rstrip << "\n"
          end
        end
      end

      # Process the action body through the filter chain
      if body = action.body
        translated = PrismTranslator.new.translate(body)
        filters = [
          InstanceVarToLocal.new,
          ParamsExpect.new,
          RespondToHTML.new,
          StrongParams.new,
          PythonConstructor.new,
          PythonRedirect.new,
          PythonRender.new(plural, singular),
        ] of Crystal::Transformer

        filtered = translated.as(Crystal::ASTNode)
        filters.each { |f| filtered = filtered.transform(f) }

        emitter = PythonEmitter.new(indent: 1)
        body_py = emitter.emit_body(filtered)

        # Post-process: replace extract_model_params with form_value calls
        body_py = expand_model_params(body_py, singular, columns)

        # Post-process: replace .update(extract_model_params...) with field assignments
        body_py = expand_update_call(body_py, singular, columns)

        # Post-process: replace ActiveRecord query chains with Python model API
        body_py = simplify_query_chain(body_py, model_name)

        body_py.each_line do |line|
          stripped = line.strip
          next if stripped.empty? && io.to_s.ends_with?("\n\n")
          io << line.rstrip << "\n"
        end
      end

      # Add implicit render if the action doesn't have an explicit render/redirect
      unless action_has_response?(action)
        io << "    return web.Response(text=layout(render_#{name}(#{singular}=#{singular})),\n" if %w[show new edit].includes?(name)
        io << "        content_type='text/html')\n" if %w[show new edit].includes?(name)
        if name == "index"
          io << "    return web.Response(text=layout(render_index(#{plural}=#{plural})),\n"
          io << "        content_type='text/html')\n"
        end
      end

      io << "\n"
    end

    private def action_has_response?(action : ControllerAction) : Bool
      return false unless body = action.body
      body_str = body.to_s
      body_str.includes?("redirect_to") || body_str.includes?("render")
    end

    # Find parameter names that need to be extracted from the request.
    # After ParamsExpect, params.expect(:id) becomes just `id` — a bare Var
    # used as an argument to Model.find(id). We look for these patterns.
    private def find_param_names(node : Crystal::ASTNode) : Array(String)
      names = [] of String
      case node
      when Crystal::Expressions
        node.expressions.each { |e| names.concat(find_param_names(e)) }
      when Crystal::Assign
        names.concat(find_param_names(node.value))
      when Crystal::Call
        # Look for Model.find(var) — the var is a param name
        if node.name == "find" && node.obj.is_a?(Crystal::Path)
          node.args.each do |arg|
            names << arg.as(Crystal::Var).name if arg.is_a?(Crystal::Var)
          end
        end
        # Also recurse into receiver and args
        names.concat(find_param_names(node.obj.not_nil!)) if node.obj
        node.args.each { |a| names.concat(find_param_names(a)) }
      end
      names.uniq
    end

    # Simplify ActiveRecord query chains to Python model API
    # Article.includes("comments").order(created_at="desc") → Article.all(order_by='created_at DESC')
    private def simplify_query_chain(source : String, model_name : String) : String
      # Match Model.includes(...).order(...) or Model.order(...)
      source.gsub(/#{model_name}\.includes\([^)]*\)\.order\(created_at="desc"\)/) do
        "#{model_name}.all(order_by='created_at DESC')"
      end.gsub(/#{model_name}\.includes\([^)]*\)\.order\(created_at="asc"\)/) do
        "#{model_name}.all(order_by='created_at ASC')"
      end.gsub(/#{model_name}\.includes\([^)]*\)/) do
        "#{model_name}.all()"
      end
    end

    # Replace Article(extract_model_params(params, "article"))
    # with Article(title=form_value(data, 'article[title]'), ...)
    private def expand_model_params(source : String, model_name : String, columns : Array(String)) : String
      pattern = /#{Inflector.classify(model_name)}\(extract_model_params\(params, "#{model_name}"\)\)/
      replacement = "#{Inflector.classify(model_name)}(#{columns.map { |c| "#{c}=form_value(data, '#{model_name}[#{c}]')" }.join(", ")})"
      source.gsub(pattern, replacement)
    end

    # Replace article.update(extract_model_params(params, "article"))
    # with individual field assignments + save
    private def expand_update_call(source : String, model_name : String, columns : Array(String)) : String
      pattern = /(\s*)if #{model_name}\.update\(extract_model_params\(params, "#{model_name}"\)\):/
      if source =~ pattern
        indent = $1
        assignments = columns.map { |c| "#{indent}#{model_name}.#{c} = form_value(data, '#{model_name}[#{c}]')" }.join("\n")
        replacement = "#{assignments}\n#{indent}if #{model_name}.save():"
        source = source.sub(pattern, replacement)
      end
      source
    end
  end
end
