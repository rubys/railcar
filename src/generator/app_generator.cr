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

module Ruby2CR
  class AppGenerator
    getter rails_dir : String
    getter output_dir : String

    def initialize(@rails_dir, @output_dir)
    end

    def generate
      puts "Generating Crystal app from #{rails_dir}..."

      copy_runtime
      generate_shard_yml
      generate_models
      generate_route_helpers
      generate_views
      generate_controllers
      generate_routes
      generate_app_entry

      puts "Done! Output in #{output_dir}/"
      puts "  crystal build src/app.cr -o blog"
    end

    # Copy runtime files
    private def copy_runtime
      # Try multiple paths to find the runtime source
      candidates = [
        File.expand_path("../runtime", __DIR__),
        File.expand_path("../../src/runtime", __DIR__),
      ]
      runtime_src = candidates.find { |p| Dir.exists?(p) }
      unless runtime_src
        puts "  Warning: runtime source not found, skipping copy"
        return
      end

      runtime_dst = File.join(output_dir, "src/runtime")
      mkdir(runtime_dst)
      mkdir(File.join(runtime_dst, "helpers"))

      %w[application_record.cr relation.cr collection_proxy.cr].each do |f|
        src_path = File.join(runtime_src, f)
        copy_file(src_path, File.join(runtime_dst, f)) if File.exists?(src_path)
      end
    end

    # Generate shard.yml
    private def generate_shard_yml
      write_file(File.join(output_dir, "shard.yml"), <<-YAML
      name: blog
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

      schemas = SchemaExtractor.extract_all(File.join(rails_dir, "db/migrate"))
      schema_map = {} of String => TableSchema
      schemas.each { |s| schema_map[s.name] = s }

      model_files = Dir.glob(File.join(rails_dir, "app/models/*.rb")).sort
      model_files.each do |path|
        model = ModelExtractor.extract_file(path)
        next unless model
        next if model.name == "ApplicationRecord"

        table_name = CrystalEmitter.pluralize(
          model.name.gsub(/([A-Z])/) { |m| "_#{m.downcase}" }.lstrip('_')
        )
        schema = schema_map[table_name]?
        next unless schema

        source = CrystalEmitter.generate(schema, model)
        # Fix requires for the output directory structure
        source = source.gsub("../runtime/", "../runtime/")
        filename = File.basename(path, ".rb") + ".cr"
        write_file(File.join(models_dir, filename), source)
        puts "  models/#{filename}"
      end
    end

    # Generate route helpers
    private def generate_route_helpers
      helpers_dir = File.join(output_dir, "src/helpers")
      mkdir(helpers_dir)

      routes_path = File.join(rails_dir, "config/routes.rb")
      return unless File.exists?(routes_path)

      route_set = RouteExtractor.extract_file(routes_path)
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

      # Process each controller's views
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
      model_class = CrystalEmitter.classify(controller_name)

      # Check which before_actions set which variables
      set_actions = info.before_actions.select { |ba| ba.method_name.starts_with?("set_") }
      has_set_model = !set_actions.empty?

      io = IO::Memory.new
      io << "require \"../models/#{singular}\"\n"
      if controller_name == "comments"
        io << "require \"../models/article\"\n"
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

      # Partial helpers
      io << generate_partial_helpers(controller_name)

      # Public actions with full rendering
      info.actions.reject(&.is_private).each do |action|
        io << generate_full_action(action, info, controller_name, singular, model_class, has_set_model, nil)
        io << "\n"
      end

      io << "  end\n"
      io << "end\n"
      io.to_s
    end

    private def generate_partial_helpers(controller_name : String) : String
      io = IO::Memory.new
      case controller_name
      when "articles"
        io << "    private def render_article_partial(article : Article) : String\n"
        io << "      String.build do |__str__|\n"
        io << "        ECR.embed(\"src/views/articles/_article.ecr\", __str__)\n"
        io << "      end\n"
        io << "    end\n\n"
        io << "    private def render_form_partial(article : Article) : String\n"
        io << "      String.build do |__str__|\n"
        io << "        ECR.embed(\"src/views/articles/_form.ecr\", __str__)\n"
        io << "      end\n"
        io << "    end\n\n"
        io << "    private def render_comment_partial(article : Article, comment : Comment) : String\n"
        io << "      String.build do |__str__|\n"
        io << "        ECR.embed(\"src/views/comments/_comment.ecr\", __str__)\n"
        io << "      end\n"
        io << "    end\n\n"
      end
      io.to_s
    end

    private def generate_full_action(action : ControllerAction, info : ControllerInfo, controller_name : String, singular : String, model_class : String, has_set_model : Bool, set_only_unused : Nil) : String
      io = IO::Memory.new
      name = action.name
      needs_id = {"show", "edit", "update", "destroy"}.includes?(name)
      needs_params = {"create", "update"}.includes?(name)

      # Check if any before_action applies to this action
      needs_before = info.before_actions.any? do |ba|
        ba.only.nil? || ba.only.not_nil!.includes?(name)
      end

      io << "    def #{name}(response : HTTP::Server::Response"
      io << ", id : Int64" if needs_id
      io << ", params : Hash(String, String)" if needs_params
      # Nested controllers need parent id
      if controller_name == "comments"
        io << ", article_id : Int64" if {"create"}.includes?(name)
        io << ", article_id : Int64" if name == "destroy"
      end
      io << ")\n"

      indent = "      "

      # Before action: set model
      if needs_before
        if controller_name == "comments"
          io << indent << "article = Article.find(article_id)\n"
        elsif needs_id
          io << indent << "#{singular} = #{model_class}.find(id)\n"
        end
      end

      # Action body — use hand-crafted patterns for the blog demo
      case "#{controller_name}##{name}"
      when "articles#index"
        io << indent << "articles = Article.includes(:comments).order(created_at: :desc).to_a\n"
        io << indent << "flash = FLASH_STORE.delete(\"default\") || {notice: nil, alert: nil}\n"
        io << indent << "notice = flash[:notice]\n"
        io << indent << "response.print layout(\"Articles\") {\n"
        io << indent << "  String.build do |__str__|\n"
        io << indent << "    ECR.embed(\"src/views/articles/index.ecr\", __str__)\n"
        io << indent << "  end\n"
        io << indent << "}\n"
      when "articles#show"
        io << indent << "flash = FLASH_STORE.delete(\"default\") || {notice: nil, alert: nil}\n"
        io << indent << "notice = flash[:notice]\n"
        io << indent << "response.print layout(article.title) {\n"
        io << indent << "  String.build do |__str__|\n"
        io << indent << "    ECR.embed(\"src/views/articles/show.ecr\", __str__)\n"
        io << indent << "  end\n"
        io << indent << "}\n"
      when "articles#new"
        io << indent << "article = Article.new\n"
        io << indent << "response.print layout(\"New Article\") {\n"
        io << indent << "  String.build do |__str__|\n"
        io << indent << "    ECR.embed(\"src/views/articles/new.ecr\", __str__)\n"
        io << indent << "  end\n"
        io << indent << "}\n"
      when "articles#edit"
        io << indent << "response.print layout(\"Edit Article\") {\n"
        io << indent << "  String.build do |__str__|\n"
        io << indent << "    ECR.embed(\"src/views/articles/edit.ecr\", __str__)\n"
        io << indent << "  end\n"
        io << indent << "}\n"
      when "articles#create"
        io << indent << "article = Article.new(extract_model_params(params, \"article\"))\n"
        io << indent << "if article.save\n"
        io << indent << "  FLASH_STORE[\"default\"] = {notice: \"Article was successfully created.\", alert: nil}\n"
        io << indent << "  response.status_code = 302\n"
        io << indent << "  response.headers[\"Location\"] = article_path(article)\n"
        io << indent << "else\n"
        io << indent << "  response.status_code = 422\n"
        io << indent << "  response.print layout(\"New Article\") {\n"
        io << indent << "    String.build do |__str__|\n"
        io << indent << "      ECR.embed(\"src/views/articles/new.ecr\", __str__)\n"
        io << indent << "    end\n"
        io << indent << "  }\n"
        io << indent << "end\n"
      when "articles#update"
        io << indent << "if article.update(extract_model_params(params, \"article\"))\n"
        io << indent << "  FLASH_STORE[\"default\"] = {notice: \"Article was successfully updated.\", alert: nil}\n"
        io << indent << "  response.status_code = 302\n"
        io << indent << "  response.headers[\"Location\"] = article_path(article)\n"
        io << indent << "else\n"
        io << indent << "  response.status_code = 422\n"
        io << indent << "  response.print layout(\"Edit Article\") {\n"
        io << indent << "    String.build do |__str__|\n"
        io << indent << "      ECR.embed(\"src/views/articles/edit.ecr\", __str__)\n"
        io << indent << "    end\n"
        io << indent << "  }\n"
        io << indent << "end\n"
      when "articles#destroy"
        io << indent << "article.destroy\n"
        io << indent << "FLASH_STORE[\"default\"] = {notice: \"Article was successfully destroyed.\", alert: nil}\n"
        io << indent << "response.status_code = 302\n"
        io << indent << "response.headers[\"Location\"] = articles_path\n"
      when "comments#create"
        io << indent << "comment = article.comments.build(extract_model_params(params, \"comment\"))\n"
        io << indent << "if comment.save\n"
        io << indent << "  FLASH_STORE[\"default\"] = {notice: \"Comment was successfully created.\", alert: nil}\n"
        io << indent << "else\n"
        io << indent << "  FLASH_STORE[\"default\"] = {notice: nil, alert: \"Could not create comment.\"}\n"
        io << indent << "end\n"
        io << indent << "response.status_code = 302\n"
        io << indent << "response.headers[\"Location\"] = article_path(article)\n"
      when "comments#destroy"
        io << indent << "comment = article.comments.find(id)\n"
        io << indent << "comment.destroy\n"
        io << indent << "FLASH_STORE[\"default\"] = {notice: \"Comment was successfully deleted.\", alert: nil}\n"
        io << indent << "response.status_code = 302\n"
        io << indent << "response.headers[\"Location\"] = article_path(article)\n"
      else
        # Generic: use the AST-based generator
        if body = action.body
          io << ControllerGenerator.generate_action(action, controller_name).lines[1..-2].join("\n") << "\n"
        end
      end

      io << "    end\n"
      io.to_s
    end

    # Generate the route matching file
    private def generate_routes
      routes_path = File.join(rails_dir, "config/routes.rb")
      return unless File.exists?(routes_path)

      route_set = RouteExtractor.extract_file(routes_path)
      source = generate_routes_file(route_set)
      write_file(File.join(output_dir, "src/routes.cr"), source)
      puts "  routes.cr"
    end

    private def generate_routes_file(route_set : RouteSet) : String
      io = IO::Memory.new
      io << "# Generated route matching from config/routes.rb\n\n"
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
        # Capitalize each word: "articles" → "Articles"
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
        io << "        #{route.controller}_controller.#{route.action}(response"
        io << ", params" if {"create"}.includes?(route.action)
        io << ")\n"
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
          # For nested, pass parent id
          if r.path.includes?("_id")
            parent_params = param_names.select { |n| n.ends_with?("_id") }
            parent_params.each { |p| args << p unless args.includes?(p) }
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

    # Generate the app entry point
    private def generate_app_entry
      write_file(File.join(output_dir, "src/app.cr"), <<-CR
      require "http/server"
      require "ecr"
      require "db"
      require "sqlite3"
      require "./routes"
      require "./models/*"

      # Flash message store
      FLASH_STORE = {} of String => {notice: String?, alert: String?}

      # Database setup
      db = DB.open("sqlite3:./blog.db")
      Ruby2CR::Article.db = db
      Ruby2CR::Comment.db = db

      db.exec <<-SQL
        CREATE TABLE IF NOT EXISTS articles (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          title TEXT NOT NULL,
          body TEXT NOT NULL,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
        )
      SQL

      db.exec <<-SQL
        CREATE TABLE IF NOT EXISTS comments (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          article_id INTEGER NOT NULL REFERENCES articles(id),
          commenter TEXT NOT NULL,
          body TEXT NOT NULL,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
        )
      SQL

      # Seed if empty
      if Ruby2CR::Article.count == 0
        a1 = Ruby2CR::Article.create!(
          title: "Getting Started with Rails",
          body: "Rails is a web application framework running on the Ruby programming language. It makes building web apps faster and easier with conventions over configuration."
        )
        a1.comments.create!(commenter: "Alice", body: "Great introduction! Rails really does make development faster.")
        a1.comments.create!(commenter: "Bob", body: "I love how Rails handles database migrations automatically.")

        a2 = Ruby2CR::Article.create!(
          title: "Understanding MVC Architecture",
          body: "MVC stands for Model-View-Controller. Models handle data and business logic, Views display information to users, and Controllers coordinate between them."
        )
        a2.comments.create!(commenter: "Carol", body: "This pattern really helps keep code organized!")

        Ruby2CR::Article.create!(
          title: "Ruby2JS: Rails Everywhere",
          body: "Ruby2JS transpiles Ruby to JavaScript, enabling Rails applications to run in browsers, on Node.js, and at the edge. Same code, different runtimes."
        )
      end

      # Start server
      router = Ruby2CR::Router.new
      server = HTTP::Server.new do |context|
        router.dispatch(context)
      end

      address = server.bind_tcp("0.0.0.0", 3000)
      puts "Blog running at http://\#{address}"
      server.listen
      CR
      )
      puts "  app.cr"
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
      # Dedent heredoc-style content
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
