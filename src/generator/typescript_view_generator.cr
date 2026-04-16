# Generates EJS template files from Rails ERB templates for TypeScript output.
#
# Pipeline: ERB → ErbCompiler → Crystal AST → shared view filters →
#           EjsConverter → .ejs template files.
#
# Mirrors the Crystal target's approach (ERB → ECR template files).
# Controllers render templates using the ejs package at runtime.

require "./inflector"
require "./ejs_converter"
require "./type_resolver"
require "../filters/instance_var_to_local"
require "../filters/rails_helpers"
require "../filters/link_to_path_helper"
require "../filters/button_to_path_helper"
require "../filters/render_to_partial"
require "../filters/form_to_html"
require "../filters/turbo_stream_connect"

module Railcar
  class TypeScriptViewGenerator
    getter app : AppModel
    getter rails_dir : String

    def initialize(@app, @rails_dir)
    end

    def generate(output_dir : String)
      views_dir = File.join(output_dir, "views")
      Dir.mkdir_p(views_dir)

      rails_views = File.join(rails_dir, "app/views")

      app.controllers.each do |info|
        controller_name = Inflector.underscore(info.name).chomp("_controller")
        template_dir = File.join(rails_views, Inflector.pluralize(controller_name))
        next unless Dir.exists?(template_dir)

        controller_views_dir = File.join(views_dir, Inflector.pluralize(controller_name))
        Dir.mkdir_p(controller_views_dir)

        Dir.glob(File.join(template_dir, "*.html.erb")).sort.each do |erb_path|
          filename = File.basename(erb_path)
          basename = filename.sub(/\.html\.erb$/, "")
          ejs_name = "#{basename}.ejs"

          resolver = TypeResolver.new(app)
          ejs_source = EjsConverter.convert_file(erb_path, basename, controller_name,
            view_filters: build_view_filters, known_fields: all_column_names,
            resolver: resolver)

          File.write(File.join(controller_views_dir, ejs_name), ejs_source)
          puts "  views/#{Inflector.pluralize(controller_name)}/#{ejs_name}"
        end
      end

      # Generate layout
      layout_dir = File.join(views_dir, "layouts")
      Dir.mkdir_p(layout_dir)
      File.write(File.join(layout_dir, "application.ejs"), generate_layout)
      puts "  views/layouts/application.ejs"
    end

    private def all_column_names : Set(String)
      fields = Set(String).new
      app.schemas.each do |schema|
        schema.columns.each { |c| fields << c.name }
      end
      fields
    end

    private def build_view_filters : Array(Crystal::Transformer)
      [
        InstanceVarToLocal.new,
        TurboStreamConnect.new,
        RailsHelpers.new,
        LinkToPathHelper.new,
        ButtonToPathHelper.new,
        RenderToPartial.new,
        FormToHTML.new,
      ] of Crystal::Transformer
    end

    private def generate_layout : String
      <<-EJS
      <!DOCTYPE html>
      <html>
      <head>
        <title><%= typeof title !== 'undefined' ? title : 'Blog' %></title>
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <meta name="action-cable-url" content="/cable">
        <link rel="stylesheet" href="/static/app.css">
        <script type="module" src="/static/turbo.min.js"></script>
      </head>
      <body>
        <main class="container mx-auto mt-28 px-5 flex flex-col">
          <%- content %>
        </main>
      </body>
      </html>
      EJS
    end
  end
end
