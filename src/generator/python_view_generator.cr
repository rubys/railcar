# Generates Python view files from Rails ERB templates.
#
# Pipeline: ERB → ErbCompiler → Ruby _buf code → Prism → Crystal AST →
#           shared filters → Python view filter → Python emitter →
#           Python string-building function
#
# Each ERB template becomes a Python function that builds and returns HTML.
# Partials become helper functions callable from other views and broadcasts.

require "compiler/crystal/syntax"
require "./erb_compiler"
require "./source_parser"
require "./prism_translator"
require "./python_emitter"
require "./inflector"
require "../filters/instance_var_to_local"
require "../filters/python_constructor"
require "../filters/python_view"
require "../filters/render_to_partial"
require "../filters/rails_helpers"
require "../filters/link_to_path_helper"
require "../filters/button_to_path_helper"

module Railcar
  class PythonViewGenerator
    getter app : AppModel
    getter rails_dir : String
    getter properties : Hash(String, Set(String))

    def initialize(@app, @rails_dir)
      # Build properties map from schema
      @properties = {} of String => Set(String)
      schema_map = {} of String => TableSchema
      app.schemas.each { |s| schema_map[s.name] = s }

      app.models.each_key do |name|
        table_name = Inflector.pluralize(Inflector.underscore(name))
        if schema = schema_map[table_name]?
          props = Set.new(schema.columns.map(&.name))
          props << "id"
          @properties[name] = props
        end
      end
    end

    def generate(output_dir : String)
      views_dir = File.join(output_dir, "views")
      rails_views = File.join(rails_dir, "app/views")

      # Process each controller's views
      app.controllers.each do |info|
        controller_name = Inflector.underscore(info.name).chomp("_controller")
        model_name = Inflector.classify(Inflector.singularize(controller_name))
        singular = Inflector.underscore(model_name).downcase

        # Don't create subdirectories — view file goes directly in views/

        rails_controller_views = File.join(rails_views, controller_name)
        next unless Dir.exists?(rails_controller_views)

        io = IO::Memory.new
        io << "from helpers import *\n"
        io << "from models import *\n"

        # Check if ERB files reference associations that use partials from other controllers
        # Only import if needed (to avoid circular imports)
        rails_controller_views_check = File.join(rails_views, controller_name)
        if Dir.exists?(rails_controller_views_check)
          all_erb = Dir.glob(File.join(rails_controller_views_check, "*.html.erb")).map { |p| File.read(p) }.join
          app.models.each do |mname, mmodel|
            mmodel.associations.each do |assoc|
              next unless assoc.kind == :has_many
              assoc_controller = Inflector.pluralize(Inflector.singularize(assoc.name))
              next if assoc_controller == controller_name
              # Check if any ERB renders this association
              if all_erb.includes?("render @") && all_erb.includes?(".#{assoc.name}")
                io << "from views.#{assoc_controller} import *\n"
              end
            end
          end
        end
        io << "\n"

        # Process each ERB file
        Dir.glob(File.join(rails_controller_views, "*.html.erb")).sort.each do |erb_path|
          basename = File.basename(erb_path, ".html.erb")
          is_partial = basename.starts_with?('_')

          func_name = if is_partial
                        partial_name = basename.lstrip('_')
                        "render_#{partial_name}_partial"
                      else
                        "render_#{basename}"
                      end

          # Determine function parameters
          # Partials may be called as partial(child) or partial(parent, child)
          # from RenderToPartial which passes parent as first arg for associations
          params = if is_partial
                     ["*args"]
                   else
                     # Page views get the plural collection or singular model
                     case basename
                     when "index"
                       [Inflector.pluralize(singular)]
                     else
                       [singular]
                     end
                   end

          # Additional params
          params << "notice=None" if !is_partial

          source = File.read(erb_path)
          body = transpile_erb(source, controller_name, model_name, is_partial ? [singular] : params.map { |p| p.split('=').first })

          io << "def #{func_name}(#{params.join(", ")}):\n"
          if is_partial
            # Unpack *args: called as partial(child) or partial(parent, child)
            io << "    #{singular} = args[-1] if args else None\n"
          end
          body.each_line do |line|
            io << "    " << line.rstrip << "\n" unless line.strip.empty? && io.to_s.ends_with?("\n\n")
          end
          io << "\n"
        end

        # views/ is a package

        filename = "#{controller_name}.py"
        File.write(File.join(views_dir, filename), io.to_s)
        puts "  views/#{filename}"
      end

      # Write views/__init__.py
      File.write(File.join(views_dir, "__init__.py"), "")
    end

    private def transpile_erb(source : String, controller_name : String,
                               model_name : String, locals : Array(String)) : String
      compiler = ErbCompiler.new(source)
      ast = PrismTranslator.translate(compiler.src)

      singular = Inflector.underscore(model_name).downcase

      filters = [
        InstanceVarToLocal.new,
        RailsHelpers.new,
        LinkToPathHelper.new,
        ButtonToPathHelper.new,
        RenderToPartial.new,
        PythonConstructor.new,
        PythonView.new(locals),
      ] of Crystal::Transformer

      filtered = ast.as(Crystal::ASTNode)
      filters.each { |f| filtered = filtered.transform(f) }

      emitter = PythonEmitter.new(properties: @properties)
      output = emitter.emit(filtered)

      # The ErbCompiler wraps in def render ... end
      # Extract just the body (skip first line "def render():" and un-indent)
      lines = output.lines
      body_lines = [] of String

      # Skip the "def render():" line
      started = false
      lines.each do |line|
        if !started && line.strip.starts_with?("def render")
          started = true
          next
        end
        if started
          # Remove one level of indentation
          body_lines << (line.starts_with?("    ") ? line[4..] : line)
        end
      end

      # Replace final bare `_buf` with `return _buf`
      if body_lines.last?.try(&.strip) == "_buf"
        body_lines[-1] = "return _buf\n"
      end

      body_lines.join("\n")
    end
  end
end
