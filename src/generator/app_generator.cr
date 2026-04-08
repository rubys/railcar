# Top-level orchestrator: reads a Rails app and generates a complete Crystal app.
#
# Usage:
#   generator = AppGenerator.new("/path/to/rails/app", "/path/to/output")
#   generator.generate

require "./schema_extractor"
require "./model_extractor"
require "./crystal_emitter"
require "./route_extractor"
require "./erb_converter"
require "./controller_extractor"
require "./controller_generator"
require "./fixture_loader"
require "./test_converter"

module Ruby2CR
  class AppGenerator
    getter rails_dir : String
    getter output_dir : String
    getter schemas : Array(TableSchema) = [] of TableSchema
    getter route_set : RouteSet = RouteSet.new
    getter models : Hash(String, ModelInfo) = {} of String => ModelInfo

    def initialize(@rails_dir, @output_dir)
    end

    def generate
      app_name = File.basename(rails_dir)
      puts "Generating Crystal app from #{rails_dir}..."

      # Extract metadata first (used by multiple generators)
      @schemas = SchemaExtractor.extract_all(File.join(rails_dir, "db/migrate"))
      routes_path = File.join(rails_dir, "config/routes.rb")
      @route_set = RouteExtractor.extract_file(routes_path) if File.exists?(routes_path)
      load_models

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

    private def load_models
      Dir.glob(File.join(rails_dir, "app/models/*.rb")).each do |path|
        model = ModelExtractor.extract_file(path)
        next unless model
        next if model.name == "ApplicationRecord"
        @models[model.name] = model
      end
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

      models.each do |name, model|
        table_name = CrystalEmitter.pluralize(
          name.gsub(/([A-Z])/) { |m| "_#{m.downcase}" }.lstrip('_')
        )
        schema = schema_map[table_name]?
        next unless schema

        source = CrystalEmitter.generate(schema, model)
        filename = table_name.gsub(/s$/, "") + ".cr"
        write_file(File.join(models_dir, filename), source)
        puts "  models/#{filename}"
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
      model_class = CrystalEmitter.classify(singular)

      # Determine nested resource parent from routes
      nested_parent = find_nested_parent(controller_name)

      io = IO::Memory.new

      # Requires — derive from associations and route structure
      io << "require \"../models/#{singular}\"\n"
      if nested_parent
        io << "require \"../models/#{nested_parent}\"\n"
      end
      io << "require \"../helpers/route_helpers\"\n"
      io << "require \"../helpers/view_helpers\"\n\n"
      io << "module Ruby2CR\n"
      io << "  class #{info.name}\n"
      io << "    include RouteHelpers\n"
      io << "    include ViewHelpers\n\n"

      # Extract model params helper
      io << "    private def extract_model_params(params : Hash(String, String), model : String) : Hash(String, DB::Any)\n"
      io << "      hash = {} of String => DB::Any\n"
      io << "      prefix = \"\#" << "{model}[\"\n"
      io << "      params.each do |k, v|\n"
      io << "        if k.starts_with?(prefix) && k.ends_with?(\"]\")\n"
      io << "          field = k[prefix.size..-2]\n"
      io << "          hash[field] = v.as(DB::Any)\n"
      io << "        end\n"
      io << "      end\n"
      io << "      hash\n"
      io << "    end\n\n"

      # Layout helper
      io << "    private def layout(title : String, &block) : String\n"
      io << "      content = yield\n"
      io << "      String.build do |__str__|\n"
      io << "        ECR.embed(\"src/views/layouts/application.ecr\", __str__)\n"
      io << "      end\n"
      io << "    end\n\n"

      # Partial helpers — scan for partials in this controller's views
      io << generate_partial_helpers(controller_name)

      # Public actions
      info.actions.reject(&.is_private).each do |action|
        io << generate_action_with_wiring(action, info, controller_name, singular, model_class, nested_parent)
        io << "\n"
      end

      io << "  end\n"
      io << "end\n"
      io.to_s
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

    # Generate partial helpers by scanning view files
    private def generate_partial_helpers(controller_name : String) : String
      io = IO::Memory.new

      # Scan for partial templates in this controller's views
      views_dir = File.join(rails_dir, "app/views/#{controller_name}")
      if Dir.exists?(views_dir)
        Dir.glob(File.join(views_dir, "_*.html.erb")).each do |path|
          partial_name = File.basename(path, ".html.erb").lchop("_")
          singular = CrystalEmitter.singularize(controller_name)
          model_class = CrystalEmitter.classify(singular)

          # Determine params: the partial variable is the singular model name
          io << "    private def render_#{partial_name}_partial(#{singular} : #{model_class}) : String\n"
          io << "      String.build do |__str__|\n"
          io << "        ECR.embed(\"src/views/#{controller_name}/_#{partial_name}.ecr\", __str__)\n"
          io << "      end\n"
          io << "    end\n\n"
        end
      end

      # Also scan other controllers' views for partials this controller might render
      views_root = File.join(rails_dir, "app/views")
      if Dir.exists?(views_root)
        Dir.each_child(views_root) do |other_dir|
          next if other_dir == controller_name || other_dir == "layouts"
          other_path = File.join(views_root, other_dir)
          next unless File.directory?(other_path)

          Dir.glob(File.join(other_path, "_*.html.erb")).each do |path|
            partial_name = File.basename(path, ".html.erb").lchop("_")
            other_singular = CrystalEmitter.singularize(other_dir)
            other_model = CrystalEmitter.classify(other_singular)

            # Check if this controller's views reference this partial
            # For now, generate it if this is a nested resource relationship
            parent = find_nested_parent(other_dir)
            if parent && CrystalEmitter.pluralize(parent) == controller_name
              singular = CrystalEmitter.singularize(controller_name)
              model_class = CrystalEmitter.classify(singular)
              io << "    private def render_#{partial_name}_partial(#{singular} : #{model_class}, #{other_singular} : #{other_model}) : String\n"
              io << "      String.build do |__str__|\n"
              io << "        ECR.embed(\"src/views/#{other_dir}/_#{partial_name}.ecr\", __str__)\n"
              io << "      end\n"
              io << "    end\n\n"
            end
          end
        end
      end

      io.to_s
    end

    # Generate a controller action with full wiring (before_action, view rendering)
    private def generate_action_with_wiring(action : ControllerAction, info : ControllerInfo, controller_name : String, singular : String, model_class : String, nested_parent : String?) : String
      io = IO::Memory.new
      name = action.name
      needs_id = {"show", "edit", "update", "destroy"}.includes?(name)
      needs_params = {"create", "update"}.includes?(name)

      needs_before = info.before_actions.any? do |ba|
        ba.only.nil? || ba.only.not_nil!.includes?(name)
      end

      # Method signature
      io << "    def #{name}(response : HTTP::Server::Response"
      io << ", id : Int64" if needs_id
      io << ", params : Hash(String, String)" if needs_params
      if nested_parent
        io << ", #{nested_parent}_id : Int64" if needs_params || needs_id
      end
      io << ")\n"

      indent = "      "

      # Before action: set parent and/or model
      if needs_before
        if nested_parent
          parent_model = CrystalEmitter.classify(nested_parent)
          io << indent << "#{nested_parent} = #{parent_model}.find(#{nested_parent}_id)\n"
        end
        if needs_id && !nested_parent
          io << indent << "#{singular} = #{model_class}.find(id)\n"
        end
      end

      # Use the AST-based generator for the action body
      io << ControllerGenerator.generate_action(action, controller_name, render_view: true).lines[1..-2].join("\n") << "\n"

      io << "    end\n"
      io.to_s
    end

    # Generate the route matching file
    private def generate_routes
      source = generate_routes_file
      write_file(File.join(output_dir, "src/routes.cr"), source)
      puts "  routes.cr"
    end

    private def generate_routes_file : String
      io = IO::Memory.new
      io << "# Generated route matching\n\n"
      io << "require \"./controllers/*\"\n"
      io << "require \"./helpers/route_helpers\"\n"
      io << "require \"./helpers/view_helpers\"\n\n"
      io << "module Ruby2CR\n"
      io << "  class Router\n"
      io << "    include RouteHelpers\n"
      io << "    include ViewHelpers\n\n"

      # Controller instances
      controllers = Set(String).new
      route_set.routes.each { |r| controllers << r.controller }
      controllers.each do |ctrl|
        class_name = ctrl.split("_").map(&.capitalize).join + "Controller"
        io << "    getter #{ctrl}_controller = #{class_name}.new\n"
      end
      io << "\n"

      io << "    def dispatch(context : HTTP::Server::Context)\n"
      io << "      request = context.request\n"
      io << "      response = context.response\n"
      io << "      path = request.path\n"
      io << "      method = request.method\n\n"
      io << "      # Parse form body for POST\n"
      io << "      params = {} of String => String\n"
      io << "      if method == \"POST\" && request.body\n"
      io << "        body = request.body.not_nil!.gets_to_end\n"
      io << "        HTTP::Params.parse(body) { |key, value| params[key] = value }\n"
      io << "        if override = params[\"_method\"]?\n"
      io << "          method = override.upcase\n"
      io << "        end\n"
      io << "      end\n\n"

      io << "      case {method, path}\n"

      # Root route
      if route_set.root_controller
        io << "      when {\"GET\", \"/\"}\n"
        io << "        response.status_code = 302\n"
        io << "        response.headers[\"Location\"] = \"/#{route_set.root_controller}\"\n"
      end

      # Static routes (no params)
      route_set.routes.each do |route|
        next if route.path.includes?(":")
        io << "      when {\"#{route.method}\", \"#{route.path}\"}\n"
        args = ["response"]
        args << "params" if {"create"}.includes?(route.action)
        io << "        #{route.controller}_controller.#{route.action}(#{args.join(", ")})\n"
      end

      io << "      else\n"
      io << "        # Parameterized routes\n"

      param_routes = route_set.routes.select { |r| r.path.includes?(":") }
      param_routes = param_routes.sort_by { |r| -r.path.count("/") }

      emitted_patterns = Set(String).new
      first = true
      param_routes.each do |route|
        pattern = route.path.gsub(/:(\w+)/, "(\\\\d+)")
        regex = "^#{pattern}$"
        next if emitted_patterns.includes?(regex)
        emitted_patterns << regex

        matching = param_routes.select { |r| r.path.gsub(/:(\w+)/, "(\\\\d+)") == route.path.gsub(/:(\w+)/, "(\\\\d+)") }
        param_names = route.path.scan(/:(\w+)/).map { |m| m[1] }

        keyword = first ? "if" : "elsif"
        first = false

        io << "        #{keyword} match = path.match(%r{#{regex}})\n"
        param_names.each_with_index do |name, i|
          io << "          #{name} = match[#{i + 1}].to_i64\n"
        end
        io << "          case method\n"
        matching.each do |r|
          io << "          when \"#{r.method}\"\n"
          args = ["response"]
          args << "id" if {"show", "edit", "update", "destroy"}.includes?(r.action)
          args << "params" if {"create", "update"}.includes?(r.action)
          # Pass parent IDs for nested resources
          if r.path.includes?("_id")
            param_names.select { |n| n.ends_with?("_id") }.each do |p|
              args << p unless args.includes?(p)
            end
          end
          io << "            #{r.controller}_controller.#{r.action}(#{args.join(", ")})\n"
        end
        io << "          else\n"
        io << "            response.status_code = 404\n"
        io << "            response.print \"Not found\"\n"
        io << "          end\n"
      end

      io << "        else\n"
      io << "          response.status_code = 404\n"
      io << "          response.print \"Not found\"\n"
      io << "        end\n"
      io << "      end\n"
      io << "      response.headers[\"Content-Type\"] ||= \"text/html\"\n"
      io << "    end\n"
      io << "  end\n"
      io << "end\n"
      io.to_s
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
      schemas.each do |schema|
        io << "db.exec <<-SQL\n"
        io << "  CREATE TABLE IF NOT EXISTS #{schema.name} (\n"
        io << "    id INTEGER PRIMARY KEY AUTOINCREMENT"
        schema.columns.each do |col|
          not_null = col.type == "datetime" || col.options["null"]? != "true" ? " NOT NULL" : ""
          sql_type = case col.type
                     when "string", "text" then "TEXT"
                     when "integer"        then "INTEGER"
                     when "float"          then "REAL"
                     when "boolean"        then "INTEGER"
                     when "datetime"       then "TEXT"
                     else                       "TEXT"
                     end
          refs = ""
          if col.name.ends_with?("_id")
            ref_table = CrystalEmitter.pluralize(col.name.chomp("_id"))
            refs = " REFERENCES #{ref_table}(id)"
          end
          io << ",\n    #{col.name} #{sql_type}#{not_null}#{refs}"
        end
        io << "\n  )\nSQL\n\n"
      end

      # Seed data from db/seeds.rb if it exists
      seeds_path = File.join(rails_dir, "db/seeds.rb")
      if File.exists?(seeds_path)
        io << "# Seed data\n"
        io << generate_seeds(seeds_path)
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

    # Generate seed code from db/seeds.rb
    private def generate_seeds(seeds_path : String) : String
      source = File.read(seeds_path)
      ast = Prism.parse(source)
      io = IO::Memory.new

      stmts = ast.statements
      return "" unless stmts.is_a?(Prism::StatementsNode)

      # Find the guard clause and first model name
      first_model = models.keys.first? || "Model"
      io << "if Ruby2CR::#{first_model}.count == 0\n"

      stmts.body.each do |stmt|
        case stmt
        when Prism::CallNode
          if stmt.name == "return"
            next # Skip the guard clause
          end
          # puts statement at end
          if stmt.name == "puts"
            next
          end
        when Prism::IfNode, Prism::GenericNode
          next # Skip guard clause
        end

        emit_seed_statement(stmt, io, "  ")
      end

      io << "end\n"
      io.to_s
    end

    private def emit_seed_statement(node : Prism::Node, io : IO, indent : String)
      case node
      when Prism::LocalVariableWriteNode
        var = node.name
        value = seed_expr(node.value)
        io << indent << var << " = " << value << "\n"
      when Prism::CallNode
        io << indent << seed_expr(node) << "\n"
      end
    end

    private def seed_expr(node : Prism::Node) : String
      case node
      when Prism::CallNode
        receiver = node.receiver
        method = node.name
        args = node.arg_nodes

        recv_str = receiver ? seed_expr(receiver) : nil

        case method
        when "create!", "create"
          kwargs = args.map { |a| seed_kwargs(a) }.join(", ")
          if recv_str
            "#{recv_str}.create!(#{kwargs})"
          else
            "create!(#{kwargs})"
          end
        when "comments"
          "#{recv_str}.comments" if recv_str
        else
          if recv_str
            arg_strs = args.map { |a| seed_expr(a) }
            if arg_strs.empty?
              "#{recv_str}.#{method}"
            else
              "#{recv_str}.#{method}(#{arg_strs.join(", ")})"
            end
          else
            arg_strs = args.map { |a| seed_expr(a) }
            "#{method}(#{arg_strs.join(", ")})"
          end
        end || "nil"
      when Prism::ConstantReadNode
        "Ruby2CR::#{node.name}"
      when Prism::LocalVariableReadNode
        node.name
      when Prism::StringNode
        node.value.inspect
      when Prism::IntegerNode
        node.value.to_s
      when Prism::SymbolNode
        ":#{node.value}"
      else
        "nil"
      end
    end

    private def seed_kwargs(node : Prism::Node) : String
      case node
      when Prism::KeywordHashNode
        node.elements.map do |el|
          if el.is_a?(Prism::AssocNode) && el.key.is_a?(Prism::SymbolNode)
            "#{el.key.as(Prism::SymbolNode).value}: #{seed_expr(el.value_node)}"
          else
            ""
          end
        end.reject(&.empty?).join(", ")
      else
        seed_expr(node)
      end
    end

    # Generate test files
    private def generate_tests
      spec_dir = File.join(output_dir, "spec")
      mkdir(spec_dir)

      # Generate spec_helper with fixture loading
      fixtures_dir = File.join(rails_dir, "test/fixtures")
      if Dir.exists?(fixtures_dir)
        tables = FixtureLoader.load_all(fixtures_dir)
        fixture_code = FixtureLoader.generate_fixture_helper(tables, models)

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
          schemas.each do |schema|
            io << "  db.exec <<-SQL\n"
            io << "    CREATE TABLE #{schema.name} (\n"
            io << "      id INTEGER PRIMARY KEY AUTOINCREMENT"
            schema.columns.each do |col|
              sql_type = case col.type
                         when "string", "text" then "TEXT"
                         when "integer"        then "INTEGER"
                         when "float"          then "REAL"
                         when "boolean"        then "INTEGER"
                         when "datetime"       then "TEXT"
                         else                       "TEXT"
                         end
              not_null = " NOT NULL"
              refs = ""
              if col.name.ends_with?("_id")
                ref_table = CrystalEmitter.pluralize(col.name.chomp("_id"))
                refs = " REFERENCES #{ref_table}(id)"
              end
              io << ",\n      #{col.name} #{sql_type}#{not_null}#{refs}"
            end
            io << "\n    )\n  SQL\n"
          end

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
      File.write(path, content)
    end

    private def copy_file(src : String, dst : String)
      File.write(dst, File.read(src))
    end
  end
end
