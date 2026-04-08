# Top-level orchestrator: reads a Rails app and generates a complete Crystal app.
#
# Usage:
#   generator = AppGenerator.new("/path/to/rails/app", "/path/to/output")
#   generator.generate

require "./app_model"
require "./crystal_emitter"
require "./erb_converter"
require "./controller_generator"
require "./prism_translator"
require "../filters/instance_var_to_local"
require "../filters/params_expect"
require "../filters/respond_to_html"
require "../filters/strong_params"
require "../filters/redirect_to_response"
require "../filters/render_to_ecr"
require "../filters/strip_callbacks"
require "../filters/model_boilerplate"
require "../filters/model_namespace"
require "../filters/controller_signature"
require "../filters/controller_boilerplate"
require "./source_parser"
require "./ddl_generator"
require "./seed_extractor"
require "./test_converter"

module Ruby2CR
  class AppGenerator
    getter rails_dir : String
    getter output_dir : String
    getter app : AppModel

    def initialize(@rails_dir, @output_dir)
      @app = AppModel.extract(rails_dir)
    end

    # Convenience accessors
    private def schemas; app.schemas; end
    private def models; app.models; end
    private def route_set; app.routes; end

    def generate
      app_name = app.name
      puts "Generating Crystal app from #{rails_dir}..."

      copy_runtime
      generate_shard_yml(app_name)
      generate_models
      generate_route_helpers
      generate_views
      generate_controllers
      generate_routes
      generate_app_entry(app_name)
      generate_tests

      puts "Done! Output in #{output_dir}/"
      puts "  cd #{output_dir} && shards install && crystal build src/app.cr -o #{app_name}"
    end

    # Copy runtime files
    private def copy_runtime
      runtime_src = File.expand_path("../runtime", __DIR__)
      runtime_dst = File.join(output_dir, "src/runtime")
      mkdir(runtime_dst)
      mkdir(File.join(runtime_dst, "helpers"))

      %w[application_record.cr relation.cr collection_proxy.cr].each do |f|
        src_path = File.join(runtime_src, f)
        copy_file(src_path, File.join(runtime_dst, f)) if File.exists?(src_path)
      end
    end

    # Generate shard.yml
    private def generate_shard_yml(app_name : String)
      write_file(File.join(output_dir, "shard.yml"), <<-YAML
      name: #{app_name}
      version: 0.1.0

      dependencies:
        db:
          github: crystal-lang/crystal-db
        sqlite3:
          github: crystal-lang/crystal-sqlite3

      crystal: ">= 1.10.0"
      YAML
      )
    end

    # Generate models from migrations + model files
    private def generate_models
      models_dir = File.join(output_dir, "src/models")
      mkdir(models_dir)

      schema_map = {} of String => TableSchema
      schemas.each { |s| schema_map[s.name] = s }

      model_files = Dir.glob(File.join(rails_dir, "app/models/*.rb")).sort
      model_files.each do |path|
        basename = File.basename(path, ".rb")
        next if basename == "application_record"

        model = models[Inflector.classify(basename)]?
        next unless model

        table_name = Inflector.pluralize(basename)
        schema = schema_map[table_name]?
        next unless schema

        # Filter chain for models:
        # 1. StripCallbacks    — remove broadcasts_to, after_*_commit, etc.
        # 2. ModelBoilerplate  — wrap in model("table") {}, add columns, validations, destroy
        ast = SourceParser.parse(path)
        ast = ast.transform(StripCallbacks.new)
        ast = ast.transform(ModelBoilerplate.new(schema, model))

        # Wrap in requires + module
        requires = [
          Crystal::Require.new("../runtime/application_record"),
          Crystal::Require.new("../runtime/relation"),
          Crystal::Require.new("../runtime/collection_proxy"),
        ] of Crystal::ASTNode
        mod = Crystal::ModuleDef.new(Crystal::Path.new("Ruby2CR"), body: ast)
        nodes = requires + [mod] of Crystal::ASTNode
        source = Crystal::Expressions.new(nodes).to_s + "\n"

        write_file(File.join(models_dir, "#{basename}.cr"), source)
        puts "  models/#{basename}.cr"
      end
    end

    # Generate route helpers
    private def generate_route_helpers
      helpers_dir = File.join(output_dir, "src/helpers")
      mkdir(helpers_dir)

      source = RouteGenerator.generate_helpers(route_set)
      write_file(File.join(helpers_dir, "route_helpers.cr"), source)
      puts "  helpers/route_helpers.cr"

      # Copy view helpers from runtime
      runtime_helpers_dir = File.expand_path("../runtime/helpers", __DIR__)
      %w[view_helpers.cr params_helpers.cr].each do |f|
        src_path = File.join(runtime_helpers_dir, f)
        if File.exists?(src_path)
          copy_file(src_path, File.join(helpers_dir, f))
          puts "  helpers/#{f}"
        end
      end
    end

    # Generate views from ERB templates
    private def generate_views
      views_src = File.join(rails_dir, "app/views")
      return unless Dir.exists?(views_src)

      Dir.each_child(views_src) do |controller_dir|
        full_path = File.join(views_src, controller_dir)
        next unless File.directory?(full_path)
        next if controller_dir == "layouts"

        views_dst = File.join(output_dir, "src/views/#{controller_dir}")
        mkdir(views_dst)

        Dir.glob(File.join(full_path, "*.html.erb")).each do |erb_path|
          basename = File.basename(erb_path, ".html.erb")
          ecr_name = "#{basename}.ecr"
          ecr_source = ERBConverter.convert_file(erb_path, basename, controller_dir)
          write_file(File.join(views_dst, ecr_name), ecr_source)
          puts "  views/#{controller_dir}/#{ecr_name}"
        end
      end

      # Generate layout
      layout_dir = File.join(output_dir, "src/views/layouts")
      mkdir(layout_dir)
      write_file(File.join(layout_dir, "application.ecr"), generate_layout)
      puts "  views/layouts/application.ecr"
    end

    # Generate controller files
    private def generate_controllers
      controllers_dir = File.join(output_dir, "src/controllers")
      mkdir(controllers_dir)

      Dir.glob(File.join(rails_dir, "app/controllers/*_controller.rb")).each do |path|
        basename = File.basename(path, ".rb")
        next if basename == "application_controller"

        info = ControllerExtractor.extract_file(path)
        next unless info

        controller_name = basename.chomp("_controller")
        source = generate_controller_file(info, controller_name)
        write_file(File.join(controllers_dir, "#{basename}.cr"), source)
        puts "  controllers/#{basename}.cr"
      end
    end

    private def generate_controller_file(info : ControllerInfo, controller_name : String) : String
      singular = CrystalEmitter.singularize(controller_name)
      nested_parent = find_nested_parent(controller_name)
      model_names = models.keys.to_a
      views_dir = File.join(rails_dir, "app/views")

      # Parse source (works for both .rb and .cr)
      source_path = File.join(rails_dir, "app/controllers/#{controller_name}_controller.rb")
      ast = SourceParser.parse(source_path)

      # Filter chain — order matters, each filter depends on previous transformations:
      #
      # 1. InstanceVarToLocal   — @vars → locals (downstream filters see local vars)
      # 2. ParamsExpect         — params.expect(:id) → id (simplifies param refs)
      # 3. RespondToHTML        — unwrap respond_to { format.html { ... } } blocks
      # 4. StrongParams         — article_params → extract_model_params(params, "article")
      # 5. RedirectToResponse   — redirect_to → status + headers + flash
      # 6. RenderToECR          — render :template → response.print(layout { ECR.embed })
      # 7. ControllerSignature  — add typed params, inline before_actions, view rendering
      # 8. ControllerBoilerplate — inject includes, helpers, partial renderers
      # 9. ModelNamespace       — Article → Ruby2CR::Article (must be last)
      ast = ast.transform(InstanceVarToLocal.new)
      ast = ast.transform(ParamsExpect.new)
      ast = ast.transform(RespondToHTML.new)
      ast = ast.transform(StrongParams.new)
      ast = ast.transform(RedirectToResponse.new)
      ast = ast.transform(RenderToECR.new(controller_name))
      ast = ast.transform(ControllerSignature.new(controller_name, nested_parent, info.before_actions, model_names))
      ast = ast.transform(ControllerBoilerplate.new(controller_name, views_dir, nested_parent))
      ast = ast.transform(ModelNamespace.new(model_names))

      # Build requires + module wrapper
      requires = [
        Crystal::Require.new("../models/#{singular}"),
      ] of Crystal::ASTNode
      if nested_parent
        requires << Crystal::Require.new("../models/#{nested_parent}")
      end
      requires << Crystal::Require.new("../helpers/route_helpers")
      requires << Crystal::Require.new("../helpers/view_helpers")

      # Wrap in Ruby2CR module
      mod = Crystal::ModuleDef.new(Crystal::Path.new("Ruby2CR"), body: ast)
      nodes = requires + [mod] of Crystal::ASTNode

      # Serialize once
      Crystal::Expressions.new(nodes).to_s + "\n"
    end

    # Find nested parent from route structure
    private def find_nested_parent(controller_name : String) : String?
      route_set.routes.each do |route|
        if route.controller == controller_name && route.path.includes?("_id")
          # Extract parent from path like /articles/:article_id/comments
          if match = route.path.match(/:(\w+)_id/)
            return match[1]
          end
        end
      end
      nil
    end

    # Generate the route matching file
    private def generate_routes
      source = RouteGenerator.generate_router(route_set)
      write_file(File.join(output_dir, "src/routes.cr"), source)
      puts "  routes.cr"
    end

    # Generate the app entry point with DB setup from schemas
    private def generate_app_entry(app_name : String)
      io = IO::Memory.new
      io << "require \"http/server\"\n"
      io << "require \"ecr\"\n"
      io << "require \"db\"\n"
      io << "require \"sqlite3\"\n"
      io << "require \"./routes\"\n"
      io << "require \"./models/*\"\n\n"
      io << "# Flash message store\n"
      io << "FLASH_STORE = {} of String => {notice: String?, alert: String?}\n\n"
      io << "# Database setup\n"
      io << "db = DB.open(\"sqlite3:./#{app_name}.db\")\n"
      io << "db.exec(\"PRAGMA foreign_keys = ON\")\n"

      # Set db on all models
      models.each_key do |name|
        io << "Ruby2CR::#{name}.db = db\n"
      end
      io << "\n"

      # Generate DDL from schemas
      DDLGenerator.generate(schemas, io, if_not_exists: true)
      io << "\n"

      # Seed data from db/seeds.rb if it exists
      seeds_path = File.join(rails_dir, "db/seeds.rb")
      if File.exists?(seeds_path)
        io << "# Seed data\n"
        first_model = models.keys.first? || "Model"
        io << SeedExtractor.generate(seeds_path, first_model)
        io << "\n"
      end

      # Start server
      io << "# Start server\n"
      io << "router = Ruby2CR::Router.new\n"
      io << "server = HTTP::Server.new do |context|\n"
      io << "  router.dispatch(context)\n"
      io << "end\n\n"
      io << "address = server.bind_tcp(\"0.0.0.0\", 3000)\n"
      io << "puts \"#{app_name} running at http://\#" << "{address}\"\n"
      io << "server.listen\n"

      write_file(File.join(output_dir, "src/app.cr"), io.to_s)
      puts "  app.cr"
    end

    # Generate test files
    private def generate_tests
      spec_dir = File.join(output_dir, "spec")
      mkdir(spec_dir)

      # Generate spec_helper with fixture loading
      unless app.fixtures.empty?
        fixture_code = FixtureLoader.generate_fixture_helper(app.fixtures, models)

        spec_helper = String.build do |io|
          io << "require \"spec\"\n"
          io << "require \"db\"\n"
          io << "require \"sqlite3\"\n"
          io << "require \"../src/models/*\"\n\n"
          io << "# Flash store for controller tests\n"
          io << "FLASH_STORE = {} of String => {notice: String?, alert: String?}\n\n"

          # DB setup function
          io << "def setup_test_database : DB::Database\n"
          io << "  db = DB.open(\"sqlite3::memory:\")\n"
          io << "  db.exec(\"PRAGMA foreign_keys = ON\")\n"
          DDLGenerator.generate(schemas, io, indent: "  ")

          # Set db on models
          models.each_key do |name|
            io << "  Ruby2CR::#{name}.db = db\n"
          end
          io << "  db\n"
          io << "end\n\n"

          io << fixture_code
        end

        write_file(File.join(spec_dir, "spec_helper.cr"), spec_helper)
        puts "  spec/spec_helper.cr"
      end

      # Convert model tests
      model_tests_dir = File.join(rails_dir, "test/models")
      if Dir.exists?(model_tests_dir)
        Dir.glob(File.join(model_tests_dir, "*_test.rb")).each do |path|
          basename = File.basename(path, ".rb")
          source = TestConverter.convert_file(path, "model")
          next if source.empty?
          write_file(File.join(spec_dir, "#{basename.chomp("_test")}_spec.cr"), source)
          puts "  spec/#{basename.chomp("_test")}_spec.cr"
        end
      end

      # Convert controller tests
      controller_tests_dir = File.join(rails_dir, "test/controllers")
      if Dir.exists?(controller_tests_dir)
        Dir.glob(File.join(controller_tests_dir, "*_test.rb")).each do |path|
          basename = File.basename(path, ".rb")
          source = TestConverter.convert_file(path, "controller")
          next if source.empty?
          write_file(File.join(spec_dir, "#{basename.chomp("_test")}_spec.cr"), source)
          puts "  spec/#{basename.chomp("_test")}_spec.cr"
        end
      end
    end

    private def generate_layout : String
      <<-ECR
      <!DOCTYPE html>
      <html>
      <head>
        <title><%= title %></title>
        <style>
          body { font-family: system-ui, sans-serif; max-width: 800px; margin: 2rem auto; padding: 0 1rem; }
          .notice { background: #f0fdf4; color: #16a34a; padding: 0.5rem 1rem; border-radius: 0.375rem; margin-bottom: 1rem; }
          .alert { background: #fef2f2; color: #dc2626; padding: 0.5rem 1rem; border-radius: 0.375rem; margin-bottom: 1rem; }
          .btn { display: inline-block; padding: 0.5rem 1rem; border-radius: 0.375rem; text-decoration: none; font-weight: 500; }
          .btn-primary { background: #2563eb; color: white; }
          .btn-default { background: #f3f4f6; }
          .btn-danger { background: #dc2626; color: white; border: none; cursor: pointer; }
          form.inline { display: inline-block; }
          input[type=text], textarea { display: block; width: 100%; border: 1px solid #d1d5db; border-radius: 0.25rem; padding: 0.5rem; }
          label { display: block; font-weight: 500; margin-top: 1rem; }
        </style>
      </head>
      <body>
        <div class="container">
          <%= content %>
        </div>
      </body>
      </html>
      ECR
    end

    # File utilities
    private def mkdir(path : String)
      Dir.mkdir_p(path) unless Dir.exists?(path)
    end

    private def write_file(path : String, content : String)
      lines = content.lines
      if lines.size > 1
        min_indent = lines.reject(&.blank?).map { |l| l.size - l.lstrip.size }.min? || 0
        if min_indent > 0
          content = lines.map { |l| l.blank? ? l : l[min_indent..] }.join("\n")
        end
      end

      # Format Crystal source files for idiomatic output
      if path.ends_with?(".cr")
        content = Crystal.format(content) rescue content
      end

      File.write(path, content)
    end

    private def copy_file(src : String, dst : String)
      File.write(dst, File.read(src))
    end
  end
end
