# ElixirGenerator — orchestrates Elixir generation from Rails app.
#
# Pipeline:
#   1. Extract AppModel metadata (schemas, models, controllers, routes, fixtures)
#   2. Generate Mix project skeleton (mix.exs, application.ex)
#   3. Generate models, views, controllers, tests
#
# Target: Plug + Bandit + Ecto-like hand-written ORM + EEx templates.

require "./app_model"
require "./schema_extractor"
require "./inflector"
require "./source_parser"
require "./fixture_loader"
require "./eex_converter"
require "../filters/instance_var_to_local"
require "../filters/rails_helpers"
require "../filters/link_to_path_helper"
require "../filters/button_to_path_helper"
require "../filters/render_to_partial"
require "../filters/form_to_html"
require "../filters/turbo_stream_connect"
require "../filters/shared_controller_filters"
require "../filters/broadcasts_to"
require "../filters/model_boilerplate_elixir"
require "../filters/controller_boilerplate_elixir"
require "../emitter/elixir/cr2ex"

module Railcar
  class ElixirGenerator
    getter app : AppModel
    getter rails_dir : String

    def initialize(@app, @rails_dir)
    end

    def generate(output_dir : String)
      puts "Generating Elixir from #{rails_dir}..."
      Dir.mkdir_p(output_dir)

      emit_mix_exs(output_dir)
      emit_application(output_dir)
      emit_runtime(output_dir)
      emit_helpers(output_dir)
      emit_models(output_dir)
      emit_views(output_dir)
      emit_controllers(output_dir)
      emit_router(output_dir)
      emit_database_init(output_dir)
      emit_seeds(output_dir)
      copy_static_assets(output_dir)
      emit_tests(output_dir)

      puts "Done! Output in #{output_dir}/"
      puts "  cd #{output_dir} && mix deps.get && mix test --no-start"
    end

    # ── mix.exs ──

    private def emit_mix_exs(output_dir : String)
      app_name = app.name.downcase.gsub("-", "_")
      app_module = Inflector.classify(app_name)

      File.write(File.join(output_dir, "mix.exs"), <<-EX)
      defmodule #{app_module}.MixProject do
        use Mix.Project

        def project do
          [
            app: :#{app_name},
            version: "0.1.0",
            elixir: "~> 1.17",
            start_permanent: Mix.env() == :prod,
            deps: deps()
          ]
        end

        def application do
          [
            extra_applications: [:logger],
            mod: {#{app_module}.Application, []}
          ]
        end

        defp deps do
          [
            {:bandit, "~> 1.6"},
            {:plug, "~> 1.16"},
            {:exqlite, "~> 0.27"},
            {:jason, "~> 1.4"},
            {:websock_adapter, "~> 0.5"}
          ]
        end
      end
      EX
      puts "  mix.exs"
    end

    # ── Application supervisor ──

    private def emit_application(output_dir : String)
      app_name = app.name.downcase.gsub("-", "_")
      app_module = Inflector.classify(app_name)
      lib_dir = File.join(output_dir, "lib/#{app_name}")
      Dir.mkdir_p(lib_dir)

      io = IO::Memory.new
      io << "defmodule #{app_module}.Application do\n"
      io << "  use Application\n\n"
      io << "  @impl true\n"
      io << "  def start(_type, _args) do\n"
      io << "    if Application.get_env(:#{app_name}, :skip_start) do\n"
      io << "      Supervisor.start_link([], strategy: :one_for_one, name: #{app_module}.Supervisor)\n"
      io << "    else\n"
      io << "      children = [\n"
      io << "        Railcar.CableServer,\n"
      io << "        {Bandit, plug: #{app_module}.Router, port: 3000}\n"
      io << "      ]\n\n"
      io << "      opts = [strategy: :one_for_one, name: #{app_module}.Supervisor]\n"
      io << "      result = Supervisor.start_link(children, opts)\n\n"
      io << "      # Initialize database, wire broadcast partials, seed data\n"
      io << "      #{app_module}.Database.init()\n"

      # Register render_partial for each model
      app.models.each_key do |name|
        singular = Inflector.underscore(name)
        plural = Inflector.pluralize(singular)
        io << "      Railcar.Broadcast.register_partial(#{app_module}.#{name}, fn record ->\n"
        io << "        #{app_module}.Helpers.render_partial(\"#{plural}/_#{singular}\", [{:#{singular}, record}])\n"
        io << "      end)\n"
      end

      io << "      #{app_module}.Seeds.run()\n\n"
      io << "      IO.puts(\"#{app_name} running at http://localhost:3000\")\n"
      io << "      result\n"
      io << "    end\n"
      io << "  end\n"
      io << "end\n"

      File.write(File.join(lib_dir, "application.ex"), io.to_s)
      puts "  lib/#{app_name}/application.ex"
    end

    # ── Runtime ──

    private def emit_runtime(output_dir : String)
      app_name = app.name.downcase.gsub("-", "_")
      lib_dir = File.join(output_dir, "lib/#{app_name}")
      Dir.mkdir_p(lib_dir)

      runtime_source = File.join(File.dirname(__FILE__), "..", "runtime", "elixir", "base_runtime.ex")
      File.copy(runtime_source, File.join(lib_dir, "railcar.ex"))
      puts "  lib/#{app_name}/railcar.ex"
    end

    # ── Models (AST-based) ──

    private def emit_models(output_dir : String)
      app_name = app.name.downcase.gsub("-", "_")
      app_module = Inflector.classify(app_name)
      lib_dir = File.join(output_dir, "lib/#{app_name}")

      schema_map = {} of String => TableSchema
      app.schemas.each { |s| schema_map[s.name] = s }

      emitter = Cr2Ex::Emitter.new(app_module)

      app.models.each do |name, model|
        table_name = Inflector.pluralize(Inflector.underscore(name))
        schema = schema_map[table_name]?
        next unless schema

        source_path = File.join(rails_dir, "app/models/#{Inflector.underscore(name)}.rb")
        next unless File.exists?(source_path)

        # Parse Rails model → Crystal AST → filter chain
        ast = SourceParser.parse(source_path)
        ast = ast.transform(BroadcastsTo.new)
        ast = ast.transform(ModelBoilerplateElixir.new(schema, model, app_module))

        # Emit via Cr2Ex
        next unless ast.is_a?(Crystal::ClassDef)
        source = emitter.emit_model(ast.as(Crystal::ClassDef), name, schema)

        # Append broadcast callbacks (still structural — uses extracted metadata)
        io = IO::Memory.new
        # Insert broadcast callbacks before the closing "end"
        if source.ends_with?("\nend\n")
          io << source.rchop("end\n")
          emit_broadcast_callbacks(name, io, app_module)
          io << "end\n"
        else
          io << source
        end

        out_path = File.join(lib_dir, "#{Inflector.underscore(name)}.ex")
        File.write(out_path, io.to_s)
        puts "  lib/#{app_name}/#{Inflector.underscore(name)}.ex"
      end
    end

    # ── Plug Router ──

    private def emit_router(output_dir : String)
      app_name = app.name.downcase.gsub("-", "_")
      app_module = Inflector.classify(app_name)
      lib_dir = File.join(output_dir, "lib/#{app_name}")
      Dir.mkdir_p(lib_dir)

      io = IO::Memory.new
      io << "defmodule #{app_module}.Router do\n"
      io << "  use Plug.Router\n\n"
      io << "  plug Plug.Logger\n"
      io << "  plug Plug.Parsers, parsers: [:urlencoded]\n"
      io << "  plug Plug.Static, at: \"/static\", from: {:#{app_name}, \"priv/static\"}\n"
      io << "  plug :match\n"
      io << "  plug :dispatch\n\n"

      # Routes — group by path, emit GET routes and POST dispatch
      routes_by_path = {} of String => Hash(String, {String, String})
      app.routes.routes.each do |route|
        routes_by_path[route.path] ||= {} of String => {String, String}
        routes_by_path[route.path][route.method.upcase] = {route.controller, route.action}
      end

      if root_ctrl = app.routes.root_controller
        root_action = app.routes.root_action || "index"
        io << "  get \"/\" do\n"
        io << "    #{app_module}.#{Inflector.classify(root_ctrl)}Controller.#{root_action}(conn)\n"
        io << "  end\n\n"
      end

      routes_by_path.each do |route_path, methods|
        plug_path = route_path.gsub(/:(\w+)/, ":\\1")

        # GET routes
        if get = methods["GET"]?
          ctrl = "#{app_module}.#{Inflector.classify(get[0])}Controller"
          io << "  get \"#{plug_path}\" do\n"
          io << "    #{ctrl}.#{get[1]}(conn)\n"
          io << "  end\n\n"
        end

        # POST routes — with _method dispatch if PATCH/DELETE also exist
        has_dispatch = methods.has_key?("PATCH") || methods.has_key?("PUT") || methods.has_key?("DELETE")

        if has_dispatch
          io << "  post \"#{plug_path}\" do\n"
          io << "    method = (conn.body_params[\"_method\"] || \"POST\") |> String.upcase()\n"
          io << "    case method do\n"
          if del = methods["DELETE"]?
            ctrl = "#{app_module}.#{Inflector.classify(del[0])}Controller"
            io << "      \"DELETE\" -> #{ctrl}.#{del[1]}(conn)\n"
          end
          if patch = (methods["PATCH"]? || methods["PUT"]?)
            ctrl = "#{app_module}.#{Inflector.classify(patch[0])}Controller"
            io << "      \"PATCH\" -> #{ctrl}.#{patch[1]}(conn)\n"
            io << "      \"PUT\" -> #{ctrl}.#{patch[1]}(conn)\n"
          end
          if post = methods["POST"]?
            ctrl = "#{app_module}.#{Inflector.classify(post[0])}Controller"
            io << "      _ -> #{ctrl}.#{post[1]}(conn)\n"
          else
            io << "      _ -> send_resp(conn, 404, \"Not found\")\n"
          end
          io << "    end\n"
          io << "  end\n\n"
        elsif post = methods["POST"]?
          ctrl = "#{app_module}.#{Inflector.classify(post[0])}Controller"
          io << "  post \"#{plug_path}\" do\n"
          io << "    #{ctrl}.#{post[1]}(conn)\n"
          io << "  end\n\n"
        end
      end

      # WebSocket for ActionCable/Turbo Streams
      io << "  get \"/cable\" do\n"
      io << "    # Echo the Action Cable subprotocol for turbo-rails client\n"
      io << "    conn = case Plug.Conn.get_req_header(conn, \"sec-websocket-protocol\") do\n"
      io << "      [protocols | _] ->\n"
      io << "        protocol = protocols |> String.split(\",\") |> List.first() |> String.trim()\n"
      io << "        Plug.Conn.put_resp_header(conn, \"sec-websocket-protocol\", protocol)\n"
      io << "      _ -> conn\n"
      io << "    end\n"
      io << "    conn\n"
      io << "    |> WebSockAdapter.upgrade(Railcar.CableHandler, [], timeout: 60_000)\n"
      io << "    |> halt()\n"
      io << "  end\n\n"

      io << "  match _ do\n"
      io << "    send_resp(conn, 404, \"Not found\")\n"
      io << "  end\n"
      io << "end\n"

      File.write(File.join(lib_dir, "router.ex"), io.to_s)
      puts "  lib/#{app_name}/router.ex"
    end

    # ── Broadcast callbacks ──

    private def emit_broadcast_callbacks(name : String, io : IO, app_module : String)
      source_path = File.join(rails_dir, "app/models/#{Inflector.underscore(name)}.rb")
      return unless File.exists?(source_path)

      ast = SourceParser.parse(source_path)
      ast = ast.transform(BroadcastsTo.new)

      save_callbacks = [] of String
      delete_callbacks = [] of String

      exprs = case ast
              when Crystal::ClassDef
                case ast.body
                when Crystal::Expressions then ast.body.as(Crystal::Expressions).expressions
                else [ast.body]
                end
              else [] of Crystal::ASTNode
              end

      exprs.each do |expr|
        next unless expr.is_a?(Crystal::Call)
        call = expr.as(Crystal::Call)
        next unless {"after_save", "after_destroy"}.includes?(call.name)
        next unless block = call.block

        broadcast_expr = extract_elixir_broadcast(block.body, name, app_module)
        next unless broadcast_expr

        if call.name == "after_save"
          save_callbacks << broadcast_expr
        else
          delete_callbacks << broadcast_expr
        end
      end

      unless save_callbacks.empty?
        io << "  def after_save(record) do\n"
        save_callbacks.each { |cb| io << "    #{cb}\n" }
        io << "    :ok\n"
        io << "  end\n\n"
      end

      unless delete_callbacks.empty?
        io << "  def after_delete(record) do\n"
        delete_callbacks.each { |cb| io << "    #{cb}\n" }
        io << "    :ok\n"
        io << "  end\n\n"
      end
    end

    private def extract_elixir_broadcast(body : Crystal::ASTNode, model_name : String, app_module : String) : String?
      call = case body
             when Crystal::Call then body
             when Crystal::ExceptionHandler
               body.body.is_a?(Crystal::Call) ? body.body.as(Crystal::Call) : nil
             when Crystal::Expressions
               first = body.as(Crystal::Expressions).expressions.first?
               first.is_a?(Crystal::Call) ? first.as(Crystal::Call) : nil
             else nil
             end
      return nil unless call
      return nil unless call.name.starts_with?("broadcast_")

      method = case call.name
               when "broadcast_replace_to" then "broadcast_replace_to"
               when "broadcast_append_to"  then "broadcast_append_to"
               when "broadcast_prepend_to" then "broadcast_prepend_to"
               when "broadcast_remove_to"  then "broadcast_remove_to"
               else call.name
               end

      args = call.args.map do |a|
        case a
        when Crystal::StringLiteral then a.value.inspect
        when Crystal::StringInterpolation
          parts = a.expressions.map do |part|
            case part
            when Crystal::StringLiteral then part.value
            when Crystal::Call then "\#{record.#{part.name}}"
            else "\#{#{part}}"
            end
          end
          "\"#{parts.join}\""
        else a.to_s.inspect
        end
      end

      # Check if call has a receiver (e.g., article.broadcast_replace_to)
      if obj = call.obj
        # article.broadcast_replace_to("articles") → get parent via current model's association
        obj_name = obj.to_s.lchop("@")
        "#{app_module}.#{model_name}.#{obj_name}(record) |> Railcar.Broadcast.#{method}(#{args.join(", ")})"
      else
        "Railcar.Broadcast.#{method}(record, #{args.join(", ")})"
      end
    end

    # ── Helpers ──

    private def emit_helpers(output_dir : String)
      app_name = app.name.downcase.gsub("-", "_")
      app_module = Inflector.classify(app_name)
      lib_dir = File.join(output_dir, "lib/#{app_name}")

      io = IO::Memory.new
      io << "defmodule #{app_module}.Helpers do\n\n"

      # Route helpers
      app.routes.helpers.each do |helper|
        if helper.params.empty?
          io << "  def #{helper.name}_path, do: #{helper.path.inspect}\n\n"
        else
          param_names = helper.params.map_with_index do |p, i|
            p == "id" ? (i == 0 ? "model" : "child") : p.chomp("_id")
          end
          io << "  def #{helper.name}_path(#{param_names.join(", ")}) do\n"
          path_parts = helper.path.split("/").map do |part|
            if part.starts_with?(":")
              param_idx = helper.params.index(part.lchop(":"))
              param_idx ? "\#{#{param_names[param_idx]}.id}" : part
            else
              part
            end
          end
          io << "    \"/#{path_parts.reject(&.empty?).join("/")}\"\n"
          io << "  end\n\n"
        end
      end

      # View helpers
      io << "  def link_to(text, url, opts \\\\ []) do\n"
      io << "    cls = if opts[:class], do: ~s( class=\"\#{opts[:class]}\"), else: \"\"\n"
      io << "    ~s(<a href=\"\#{url}\"\#{cls}>\#{text}</a>)\n"
      io << "  end\n\n"

      io << "  def button_to(text, url, opts \\\\ []) do\n"
      io << "    method = opts[:method] || \"post\"\n"
      io << "    cls = if opts[:class], do: ~s( class=\"\#{opts[:class]}\"), else: \"\"\n"
      io << "    form_cls = if opts[:form_class], do: ~s( class=\"\#{opts[:form_class]}\"), else: \"\"\n"
      io << "    confirm = opts[:data_turbo_confirm] || \"\"\n"
      io << "    confirm_attr = if confirm != \"\", do: ~s( data-turbo-confirm=\"\#{confirm}\"), else: \"\"\n"
      io << "    ~s(<form method=\"post\" action=\"\#{url}\"\#{form_cls}\#{confirm_attr}>) <>\n"
      io << "    ~s(<input type=\"hidden\" name=\"_method\" value=\"\#{method}\">) <>\n"
      io << "    ~s(<button type=\"submit\"\#{cls}>\#{text}</button></form>)\n"
      io << "  end\n\n"

      io << "  def turbo_stream_from(channel) do\n"
      io << "    signed = Base.encode64(Jason.encode!(channel))\n"
      io << "    ~s(<turbo-cable-stream-source channel=\"Turbo::StreamsChannel\" signed-stream-name=\"\#{signed}\"></turbo-cable-stream-source>)\n"
      io << "  end\n\n"

      io << "  def truncate(text, opts \\\\ [])\n"
      io << "  def truncate(nil, _opts), do: \"\"\n"
      io << "  def truncate(text, opts) do\n"
      io << "    length = opts[:length] || 30\n"
      io << "    if String.length(text) <= length, do: text, else: String.slice(text, 0, length - 3) <> \"...\"\n"
      io << "  end\n\n"

      io << "  def dom_id(obj, prefix \\\\ nil) do\n"
      io << "    name = obj.__struct__ |> Module.split() |> List.last() |> String.downcase()\n"
      io << "    if prefix, do: \"\#{prefix}_\#{name}_\#{obj.id}\", else: \"\#{name}_\#{obj.id}\"\n"
      io << "  end\n\n"

      io << "  def pluralize(1, singular), do: \"1 \#{singular}\"\n"
      io << "  def pluralize(count, singular), do: \"\#{count} \#{singular}s\"\n\n"

      io << "  def error_full_message({field, message}) do\n"
      io << "    \"\#{field |> to_string() |> String.replace(\"_\", \" \") |> String.capitalize()} \#{message}\"\n"
      io << "  end\n\n"

      io << "  def form_with_open_tag(model, opts \\\\ []) do\n"
      io << "    name = model.__struct__ |> Module.split() |> List.last() |> String.downcase()\n"
      io << "    plural = name <> \"s\"\n"
      io << "    cls = if opts[:class], do: ~s( class=\"\#{opts[:class]}\"), else: \"\"\n"
      io << "    if model.id do\n"
      io << "      ~s(<form action=\"/\#{plural}/\#{model.id}\" method=\"post\"\#{cls}>) <>\n"
      io << "      ~s(<input type=\"hidden\" name=\"_method\" value=\"patch\">)\n"
      io << "    else\n"
      io << "      ~s(<form action=\"/\#{plural}\" method=\"post\"\#{cls}>)\n"
      io << "    end\n"
      io << "  end\n\n"

      io << "  def form_submit_tag(model, opts \\\\ []) do\n"
      io << "    name = model.__struct__ |> Module.split() |> List.last()\n"
      io << "    cls = if opts[:class], do: ~s( class=\"\#{opts[:class]}\"), else: \"\"\n"
      io << "    action = if model.id, do: \"Update\", else: \"Create\"\n"
      io << "    ~s(<input type=\"submit\" value=\"\#{action} \#{name}\"\#{cls}>)\n"
      io << "  end\n\n"

      io << "  def layout(content, title \\\\ \"Blog\") do\n"
      io << "    \"\"\"\n"
      io << "    <!DOCTYPE html>\n"
      io << "    <html>\n"
      io << "    <head>\n"
      io << "      <title>\#{title}</title>\n"
      io << "      <meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">\n"
      io << "      <meta name=\"action-cable-url\" content=\"/cable\">\n"
      io << "      <link rel=\"stylesheet\" href=\"/static/app.css\">\n"
      io << "      <script type=\"module\" src=\"/static/turbo.min.js\"></script>\n"
      io << "    </head>\n"
      io << "    <body>\n"
      io << "      <main class=\"container mx-auto mt-28 px-5 flex flex-col\">\n"
      io << "        \#{content}\n"
      io << "      </main>\n"
      io << "    </body>\n"
      io << "    </html>\n"
      io << "    \"\"\"\n"
      io << "  end\n\n"

      # Render view function
      io << "  def render_view(conn, template, assigns) do\n"
      io << "    views_dir = Path.join(:code.priv_dir(:#{app_name}) |> to_string(), \"views\")\n"
      io << "    template_path = Path.join(views_dir, template <> \".eex\")\n"
      io << "    all_assigns = Keyword.merge([notice: nil], assigns)\n"
      io << "    content = EEx.eval_file(template_path, all_assigns)\n"
      io << "    html = layout(content)\n"
      io << "    conn |> Plug.Conn.put_resp_content_type(\"text/html\") |> Plug.Conn.send_resp(200, html)\n"
      io << "  end\n\n"

      io << "  def render_view(conn, template, assigns, status) do\n"
      io << "    views_dir = Path.join(:code.priv_dir(:#{app_name}) |> to_string(), \"views\")\n"
      io << "    template_path = Path.join(views_dir, template <> \".eex\")\n"
      io << "    all_assigns = Keyword.merge([notice: nil], assigns)\n"
      io << "    content = EEx.eval_file(template_path, all_assigns)\n"
      io << "    html = layout(content)\n"
      io << "    conn |> Plug.Conn.put_resp_content_type(\"text/html\") |> Plug.Conn.send_resp(status, html)\n"
      io << "  end\n\n"

      io << "  def render_partial(template, assigns) do\n"
      io << "    views_dir = Path.join(:code.priv_dir(:#{app_name}) |> to_string(), \"views\")\n"
      io << "    template_path = Path.join(views_dir, template <> \".eex\")\n"
      io << "    all_assigns = assigns\n"
      io << "    EEx.eval_file(template_path, all_assigns)\n"
      io << "  end\n"

      io << "end\n"

      File.write(File.join(lib_dir, "helpers.ex"), io.to_s)
      puts "  lib/#{app_name}/helpers.ex"
    end

    # ── Views ──

    private def emit_views(output_dir : String)
      app_name = app.name.downcase.gsub("-", "_")
      app_module = Inflector.classify(app_name)
      priv_dir = File.join(output_dir, "priv/views")

      rails_views = File.join(rails_dir, "app/views")

      app.controllers.each do |info|
        controller_name = Inflector.underscore(info.name).chomp("_controller")
        template_dir = File.join(rails_views, Inflector.pluralize(controller_name))
        next unless Dir.exists?(template_dir)

        views_dir = File.join(priv_dir, Inflector.pluralize(controller_name))
        Dir.mkdir_p(views_dir)

        Dir.glob(File.join(template_dir, "*.html.erb")).sort.each do |erb_path|
          filename = File.basename(erb_path)
          basename = filename.sub(/\.html\.erb$/, "")
          eex_name = "#{basename}.eex"

          eex_source = EexConverter.convert_file(erb_path, basename, controller_name,
            view_filters: build_view_filters, app_module: app_module, known_fields: all_column_names)

          File.write(File.join(views_dir, eex_name), eex_source)
          puts "  priv/views/#{Inflector.pluralize(controller_name)}/#{eex_name}"
        end
      end
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

    # ── Controllers ──

    private def emit_controllers(output_dir : String)
      app_name = app.name.downcase.gsub("-", "_")
      app_module = Inflector.classify(app_name)
      lib_dir = File.join(output_dir, "lib/#{app_name}")

      emitter = Cr2Ex::Emitter.new(app_module)

      app.controllers.each do |info|
        controller_name = Inflector.underscore(info.name).chomp("_controller")
        singular = Inflector.singularize(controller_name)
        plural = Inflector.pluralize(controller_name)
        model_name = Inflector.classify(singular)
        nested_parent = app.routes.nested_parent_for(plural)

        source_path = File.join(rails_dir, "app/controllers/#{controller_name}_controller.rb")
        next unless File.exists?(source_path)

        # Parse and filter through AST pipeline
        ast = SourceParser.parse(source_path)
        ast = SharedControllerFilters.apply(ast)
        ast = ast.transform(ControllerBoilerplateElixir.new(
          controller_name, model_name, app_module, nested_parent, info.before_actions))

        io = IO::Memory.new
        io << "defmodule #{app_module}.#{Inflector.classify(controller_name)}Controller do\n"
        io << "  import Plug.Conn\n"
        io << "  alias #{app_module}.Helpers\n\n"

        # Emit each function from the filtered AST
        defs = case ast
               when Crystal::Expressions then ast.as(Crystal::Expressions).expressions
               else [ast]
               end

        defs.each do |node|
          next unless node.is_a?(Crystal::Def)
          emitter.emit_controller_function(node.as(Crystal::Def), io)
        end

        # Private helper for extracting model params from form data
        extract_model_params_helper(io)
        io << "end\n"

        out_path = File.join(lib_dir, "#{controller_name}_controller.ex")
        File.write(out_path, io.to_s)
        puts "  lib/#{app_name}/#{controller_name}_controller.ex"
      end
    end



    private def extract_model_params_helper(io : IO)
      io << "  defp extract_model_params(body_params, model_name) do\n"
      io << "    # Plug.Parsers may produce nested maps or flat keys\n"
      io << "    case Map.get(body_params, model_name) do\n"
      io << "      %{} = nested ->\n"
      io << "        Enum.reduce(nested, %{}, fn {k, v}, acc -> Map.put(acc, String.to_atom(k), v) end)\n"
      io << "      _ ->\n"
      io << "        prefix = model_name <> \"[\"\n"
      io << "        Enum.reduce(body_params, %{}, fn {key, value}, acc ->\n"
      io << "          if String.starts_with?(key, prefix) && String.ends_with?(key, \"]\") do\n"
      io << "            field = key |> String.trim_leading(prefix) |> String.trim_trailing(\"]\")\n"
      io << "            Map.put(acc, String.to_atom(field), value)\n"
      io << "          else\n"
      io << "            acc\n"
      io << "          end\n"
      io << "        end)\n"
      io << "    end\n"
      io << "  end\n"
    end

    # ── Database init ──

    private def emit_database_init(output_dir : String)
      app_name = app.name.downcase.gsub("-", "_")
      app_module = Inflector.classify(app_name)
      lib_dir = File.join(output_dir, "lib/#{app_name}")

      io = IO::Memory.new
      io << "defmodule #{app_module}.Database do\n"
      io << "  def init do\n"
      io << "    db_path = Path.join(File.cwd!(), \"#{app_name}.db\")\n"
      io << "    Railcar.Repo.start(db_path)\n"

      app.schemas.each do |schema|
        all_cols = [{name: "id", type: "INTEGER"}]
        schema.columns.each { |c| all_cols << {name: c.name, type: c.type} }
        col_defs = all_cols.map do |c|
          parts = "#{c[:name]} #{c[:type]}"
          parts += " PRIMARY KEY AUTOINCREMENT" if c[:name] == "id"
          parts += " NOT NULL" unless c[:name] == "id"
          parts
        end
        io << "    Railcar.Repo.execute(\"\"\"\n"
        io << "      CREATE TABLE IF NOT EXISTS #{schema.name} (\n"
        io << "        #{col_defs.join(",\n        ")}\n"
        io << "      )\n"
        io << "    \"\"\")\n"
      end

      io << "  end\n"
      io << "end\n"

      File.write(File.join(lib_dir, "database.ex"), io.to_s)
      puts "  lib/#{app_name}/database.ex"
    end

    # ── Seeds ──

    private def emit_seeds(output_dir : String)
      app_name = app.name.downcase.gsub("-", "_")
      app_module = Inflector.classify(app_name)
      lib_dir = File.join(output_dir, "lib/#{app_name}")

      # Generate seed script
      seeds_path = File.join(rails_dir, "db/seeds.rb")
      return unless File.exists?(seeds_path)

      io = IO::Memory.new
      io << "defmodule #{app_module}.Seeds do\n"
      io << "  def run do\n"
      io << "    if #{app_module}.Article.count() > 0, do: :ok, else: seed()\n"
      io << "  end\n\n"
      io << "  defp seed do\n"

      source = File.read(seeds_path)
      # Join multi-line statements
      joined = [] of String
      current = ""
      depth = 0
      source.lines.each do |line|
        stripped = line.strip
        next if stripped.empty? || stripped.starts_with?("#") || stripped.starts_with?("return") || stripped.starts_with?("puts")
        current += " " unless current.empty?
        current += stripped
        depth += stripped.count('(') - stripped.count(')')
        if depth <= 0
          joined << current
          current = ""
          depth = 0
        end
      end
      joined << current unless current.empty?

      joined.each_with_index do |stmt, idx|
        case stmt
        when /^(\w+)\s*=\s*(\w+)\.create!\(\s*(.+)\s*\)$/m
          var_name = $1
          attrs = $3.gsub(/\s+/, " ").gsub(/(\w+):\s*/, "\\1: ")
          # Check if variable is used in subsequent statements
          used = joined[(idx + 1)..].any? { |s| s.includes?(var_name) }
          prefix = used ? "" : "_"
          io << "    {:ok, #{prefix}#{var_name}} = #{app_module}.#{$2}.create(%{#{attrs}})\n"
        when /^(\w+)\.(\w+)\.create!\(\s*(.+)\s*\)$/m
          attrs = $3.gsub(/\s+/, " ").gsub(/(\w+):\s*/, "\\1: ")
          singular = Inflector.singularize($2)
          parent_singular = Inflector.underscore($1)
          fk = "#{parent_singular}_id"
          io << "    #{app_module}.#{Inflector.classify(singular)}.create(Map.put(%{#{attrs}}, :#{fk}, #{$1}.id))\n"
        end
      end

      io << "  end\n"
      io << "end\n"

      File.write(File.join(lib_dir, "seeds.ex"), io.to_s)
      puts "  lib/#{app_name}/seeds.ex"
    end

    # ── Static assets ──

    private def copy_static_assets(output_dir : String)
      app_name = app.name.downcase.gsub("-", "_")
      static_dir = File.join(output_dir, "priv/static")
      Dir.mkdir_p(static_dir)

      # Tailwind CSS
      tailwind = find_tailwind
      if tailwind
        input_css = File.join(output_dir, "input.css")
        File.write(input_css, "@import \"tailwindcss\";\n")
        err_io = IO::Memory.new
        result = Process.run(tailwind,
          ["--input", "input.css", "--output", "priv/static/app.css", "--minify"],
          chdir: output_dir, output: Process::Redirect::Close, error: err_io)
        if result.success?
          size = File.size(File.join(static_dir, "app.css"))
          puts "  priv/static/app.css (#{size} bytes)"
        end
        File.delete(input_css) if File.exists?(input_css)
      end

      # Turbo JS
      turbo_js = find_turbo_js
      if turbo_js
        File.copy(turbo_js, File.join(static_dir, "turbo.min.js"))
        size = File.size(File.join(static_dir, "turbo.min.js"))
        puts "  priv/static/turbo.min.js (#{size} bytes)"
      end
    end

    private def find_tailwind : String?
      path = Process.find_executable("tailwindcss")
      return path if path
      begin
        output = IO::Memory.new
        result = Process.run("ruby",
          ["-e", "puts Gem::Specification.find_by_name('tailwindcss-rails').bin_dir + '/tailwindcss'"],
          output: output, error: Process::Redirect::Close)
        return output.to_s.strip if result.success? && File.exists?(output.to_s.strip)
      rescue
      end
      nil
    end

    private def find_turbo_js : String?
      begin
        output = IO::Memory.new
        result = Process.run("ruby",
          ["-e", "puts Gem::Specification.find_by_name('turbo-rails').gem_dir + '/app/assets/javascripts/turbo.min.js'"],
          output: output, error: Process::Redirect::Close)
        return output.to_s.strip if result.success? && File.exists?(output.to_s.strip)
      rescue
      end
      nil
    end

    # ── Tests ──

    private def emit_tests(output_dir : String)
      app_name = app.name.downcase.gsub("-", "_")
      app_module = Inflector.classify(app_name)
      test_dir = File.join(output_dir, "test")
      Dir.mkdir_p(test_dir)

      emit_test_helper(test_dir, app_name, app_module)
      emit_model_tests(test_dir, app_name, app_module)
      emit_controller_tests(test_dir, app_name, app_module)
    end

    private def emit_test_helper(test_dir : String, app_name : String, app_module : String)
      io = IO::Memory.new
      # Don't start the application (Bandit) during tests
      io << "Application.put_env(:#{app_name}, :skip_start, true)\n"
      io << "ExUnit.start()\n\n"
      io << "defmodule #{app_module}.TestHelper do\n"
      io << "  def setup_db do\n"
      io << "    db = Railcar.Repo.start(\":memory:\")\n"
      io << "    Exqlite.Sqlite3.execute(db, \"PRAGMA foreign_keys = ON\")\n"

      # Create tables
      app.schemas.each do |schema|
        all_cols = [{name: "id", type: "INTEGER"}]
        schema.columns.each { |c| all_cols << {name: c.name, type: c.type} }
        col_defs = all_cols.map do |c|
          parts = "#{c[:name]} #{c[:type]}"
          parts += " PRIMARY KEY AUTOINCREMENT" if c[:name] == "id"
          parts += " NOT NULL" unless c[:name] == "id"
          parts
        end
        io << "    Exqlite.Sqlite3.execute(db, \"\"\"\n"
        io << "      CREATE TABLE #{schema.name} (\n"
        io << "        #{col_defs.join(",\n        ")}\n"
        io << "      )\n"
        io << "    \"\"\")\n"
      end

      io << "    db\n"
      io << "  end\n\n"

      # Fixtures
      sorted_fixtures = FixtureLoader.sort_by_dependency(app.fixtures, app.models)

      io << "  def setup_fixtures do\n"
      sorted_fixtures.each do |table|
        singular = Inflector.singularize(table.name)
        model_name = Inflector.classify(singular)
        next unless app.models.has_key?(model_name)

        table.records.each do |record|
          attrs = [] of String
          record.fields.each do |field, value|
            model_info = app.models[model_name]?
            assoc = model_info.try(&.associations.find { |a| a.name == field })
            if assoc && assoc.kind == :belongs_to
              ref_table = Inflector.pluralize(field)
              attrs << "#{field}_id: #{ref_table}_#{value}.id"
            else
              if value.match(/^\d+$/)
                attrs << "#{field}: #{value}"
              else
                attrs << "#{field}: #{value.inspect}"
              end
            end
          end
          var_name = "#{table.name}_#{record.label}"
          io << "    {:ok, #{var_name}} = #{app_module}.#{model_name}.create(%{#{attrs.join(", ")}})\n"
        end
      end

      # Return fixtures as a map
      io << "    %{\n"
      sorted_fixtures.each do |table|
        singular = Inflector.singularize(table.name)
        model_name = Inflector.classify(singular)
        next unless app.models.has_key?(model_name)
        table.records.each do |record|
          var_name = "#{table.name}_#{record.label}"
          io << "      #{var_name}: #{var_name},\n"
        end
      end
      io << "    }\n"
      io << "  end\n"
      io << "end\n"

      File.write(File.join(test_dir, "test_helper.exs"), io.to_s)
      puts "  test/test_helper.exs"
    end

    private def emit_model_tests(test_dir : String, app_name : String, app_module : String)
      rails_test_dir = File.join(rails_dir, "test/models")
      return unless Dir.exists?(rails_test_dir)

      Dir.glob(File.join(rails_test_dir, "*_test.rb")).sort.each do |path|
        basename = File.basename(path, "_test.rb")
        model_name = Inflector.classify(basename)

        # Parse test through Prism AST
        ast = SourceParser.parse(path)
        source = File.read(path)

        io = IO::Memory.new
        io << "defmodule #{app_module}.#{model_name}Test do\n"
        io << "  use ExUnit.Case\n\n"
        io << "  setup do\n"
        io << "    #{app_module}.TestHelper.setup_db()\n"
        io << "    fixtures = #{app_module}.TestHelper.setup_fixtures()\n"
        io << "    fixtures\n"
        io << "  end\n\n"

        # Walk AST to find test blocks
        class_body = find_class_body(ast)
        if class_body
          emit_test_methods(class_body, io, app_module, model_name, basename)
        end

        io << "end\n"

        out_path = File.join(test_dir, "#{basename}_test.exs")
        File.write(out_path, io.to_s)
        puts "  test/#{basename}_test.exs"
      end
    end

    private def find_class_body(ast : Crystal::ASTNode) : Crystal::ASTNode?
      case ast
      when Crystal::ClassDef then ast.body
      when Crystal::Expressions
        ast.expressions.each do |expr|
          result = find_class_body(expr)
          return result if result
        end
        nil
      else nil
      end
    end

    private def emit_test_methods(body : Crystal::ASTNode, io : IO, app_module : String,
                                   model_name : String, basename : String)
      exprs = case body
              when Crystal::Expressions then body.expressions
              else [body]
              end

      singular = Inflector.underscore(model_name)
      plural = Inflector.pluralize(singular)

      exprs.each do |expr|
        next unless expr.is_a?(Crystal::Call)
        call = expr.as(Crystal::Call)
        next unless call.name == "test" && call.args.size == 1 && call.block
        test_name = call.args[0].to_s.strip('"')
        block_body = call.block.not_nil!.body

        io << "  test #{test_name.inspect}, fixtures do\n"
        emit_test_body(block_body, io, app_module, model_name, basename)
        io << "  end\n\n"
      end
    end

    private def emit_test_body(node : Crystal::ASTNode, io : IO, app_module : String,
                                model_name : String, basename : String)
      singular = Inflector.underscore(model_name)
      plural = Inflector.pluralize(singular)

      exprs = case node
              when Crystal::Expressions then node.expressions
              else [node]
              end

      exprs.each do |expr|
        emit_test_stmt(expr, io, app_module, model_name, singular, plural)
      end
    end

    private def emit_test_stmt(node : Crystal::ASTNode, io : IO, app_module : String,
                                model_name : String, singular : String, plural : String)
      case node
      when Crystal::Assign
        emit_test_assign(node, io, app_module, model_name, singular, plural)
      when Crystal::Call
        emit_test_call(node, io, app_module, model_name, singular, plural)
      when Crystal::Nop
        # skip
      end
    end

    private def emit_test_assign(node : Crystal::Assign, io : IO, app_module : String,
                                  model_name : String, singular : String, plural : String)
      target = node.target
      value = node.value
      var_name = case target
                 when Crystal::InstanceVar then target.name.lchop("@")
                 when Crystal::Var then target.name
                 else target.to_s
                 end

      if value.is_a?(Crystal::Call) && value.args.size == 1 && value.args[0].is_a?(Crystal::SymbolLiteral)
        # @article = articles(:one) → article = fixtures.articles_one
        func = value.name
        label = value.args[0].as(Crystal::SymbolLiteral).value
        io << "    #{var_name} = fixtures.#{func}_#{label}\n"
      elsif value.is_a?(Crystal::Call) && value.name == "new" && value.obj
        # Article.new(title: "...", body: "...") → struct(Blog.Article, %{...})
        obj_name = value.obj.not_nil!.to_s
        attrs = hash_to_elixir(value, singular)
        io << "    #{var_name} = struct(#{app_module}.#{obj_name}, #{attrs})\n"
      elsif value.is_a?(Crystal::Call) && value.name == "create" && value.obj.is_a?(Crystal::Call)
        # article.comments.create(attrs) → Blog.Comment.create(%{article_id: article.id, ...})
        parent_call = value.obj.as(Crystal::Call)
        if parent_call.obj
          parent_var = elixir_expr(parent_call.obj.not_nil!, app_module, singular)
          assoc_name = parent_call.name
          child_model = Inflector.classify(Inflector.singularize(assoc_name))
          parent_singular = Inflector.underscore(Inflector.classify(parent_var.split(".").last))
          fk = "#{parent_singular}_id"
          attrs = hash_to_elixir(value, singular)
          # Merge FK into attrs
          io << "    {:ok, #{var_name}} = #{app_module}.#{child_model}.create(Map.put(#{attrs}, :#{fk}, #{parent_var}.id))\n"
        else
          io << "    # TODO: #{node}\n"
        end
      elsif value.is_a?(Crystal::Call) && value.name == "build" && value.obj.is_a?(Crystal::Call)
        # article.comments.build(attrs) → struct(Blog.Comment, %{article_id: article.id, ...})
        parent_call = value.obj.as(Crystal::Call)
        if parent_call.obj
          parent_var = elixir_expr(parent_call.obj.not_nil!, app_module, singular)
          assoc_name = parent_call.name
          child_model = Inflector.classify(Inflector.singularize(assoc_name))
          parent_singular = Inflector.underscore(Inflector.classify(parent_var.split(".").last))
          fk = "#{parent_singular}_id"
          attrs = hash_to_elixir(value, singular)
          io << "    #{var_name} = struct(#{app_module}.#{child_model}, Map.put(#{attrs}, :#{fk}, #{parent_var}.id))\n"
        else
          io << "    # TODO: #{node}\n"
        end
      else
        io << "    # TODO: #{node}\n"
      end
    end

    private def emit_test_call(node : Crystal::Call, io : IO, app_module : String,
                                model_name : String, singular : String, plural : String)
      name = node.name
      args = node.args

      case name
      when "assert_not_nil"
        if args.size == 1
          io << "    assert #{elixir_expr(args[0], app_module, singular)} != nil\n"
        end
      when "assert_equal"
        if args.size == 2
          expected = elixir_expr(args[0], app_module, singular)
          actual = elixir_expr(args[1], app_module, singular)
          io << "    assert #{actual} == #{expected}\n"
        end
      when "assert_not"
        if args.size == 1
          expr = args[0]
          if expr.is_a?(Crystal::Call) && expr.name == "save"
            obj = expr.obj ? elixir_expr(expr.obj.not_nil!, app_module, singular) : singular
            io << "    assert {:error, _} = #{app_module}.#{model_name}.save(#{obj})\n"
          else
            io << "    refute #{elixir_expr(expr, app_module, singular)}\n"
          end
        end
      when "assert_difference"
        if args.size >= 1 && node.block
          count_expr = args[0].to_s.strip('"')
          model = count_expr.split(".").first
          diff = args.size > 1 ? args[1].to_s.to_i : 1
          io << "    before_count = #{app_module}.#{model}.count()\n"
          emit_test_body(node.block.not_nil!.body, io, app_module, model_name, singular)
          io << "    assert #{app_module}.#{model}.count() - before_count == #{diff}\n"
        end
      else
        # Instance method calls
        if obj = node.obj
          obj_str = obj.to_s.lchop("@")
          if name == "destroy"
            io << "    #{app_module}.#{Inflector.classify(obj_str)}.delete(#{obj_str})\n"
          elsif name == "save"
            io << "    #{app_module}.#{Inflector.classify(obj_str)}.save(#{obj_str})\n"
          else
            io << "    # TODO: #{node}\n"
          end
        else
          io << "    # TODO: #{name}\n"
        end
      end
    end

    private def elixir_expr(node : Crystal::ASTNode, app_module : String, singular : String) : String
      case node
      when Crystal::StringLiteral then node.value.inspect
      when Crystal::NumberLiteral then node.value.to_s.gsub(/_i64|_i32/, "")
      when Crystal::InstanceVar then node.name.lchop("@")
      when Crystal::Var then node.name
      when Crystal::Call
        obj = node.obj
        if obj
          obj_str = elixir_expr(obj, app_module, singular)
          # Calls on model classes need module prefix
          if obj.is_a?(Crystal::Path) && {"last", "find", "count", "all"}.includes?(node.name)
            args = node.args.map { |a| elixir_expr(a, app_module, singular) }
            "#{app_module}.#{obj_str}.#{node.name}(#{args.join(", ")})"
          elsif node.name == "id"
            "#{obj_str}.id"
          elsif node.name == "save"
            "#{app_module}.#{Inflector.classify(obj_str)}.save(#{obj_str})"
          else
            "#{obj_str}.#{node.name}"
          end
        else
          if node.args.size == 1 && node.args[0].is_a?(Crystal::SymbolLiteral)
            # articles(:one) → fixture access
            label = node.args[0].as(Crystal::SymbolLiteral).value
            "fixtures.#{node.name}_#{label}"
          else
            node.name
          end
        end
      when Crystal::NilLiteral then "nil"
      else node.to_s.gsub("@", "")
      end
    end

    private def hash_to_elixir(call : Crystal::Call, singular : String) : String
      if named = call.named_args
        attrs = named.map { |na| "#{na.name}: #{elixir_value(na.value)}" }
        return "%{#{attrs.join(", ")}}"
      end

      # Prism parses keyword args as a NamedTupleLiteral or HashLiteral positional arg
      call.args.each do |arg|
        case arg
        when Crystal::NamedTupleLiteral
          attrs = arg.entries.map { |e| "#{e.key}: #{elixir_value(e.value)}" }
          return "%{#{attrs.join(", ")}}"
        when Crystal::HashLiteral
          attrs = arg.entries.map do |e|
            key = case e.key
                  when Crystal::SymbolLiteral then e.key.as(Crystal::SymbolLiteral).value
                  when Crystal::StringLiteral then e.key.as(Crystal::StringLiteral).value
                  else e.key.to_s
                  end
            "#{key}: #{elixir_value(e.value)}"
          end
          return "%{#{attrs.join(", ")}}"
        end
      end

      "%{}"
    end

    # ── Controller tests ──

    private def emit_controller_tests(test_dir : String, app_name : String, app_module : String)
      rails_test_dir = File.join(rails_dir, "test/controllers")
      return unless Dir.exists?(rails_test_dir)

      Dir.glob(File.join(rails_test_dir, "*_test.rb")).sort.each do |path|
        basename = File.basename(path, "_test.rb")
        controller_name = basename.chomp("_controller")
        singular = Inflector.singularize(controller_name)
        plural = Inflector.pluralize(controller_name)
        model_name = Inflector.classify(singular)

        ast = SourceParser.parse(path)

        io = IO::Memory.new
        io << "defmodule #{app_module}.#{model_name}ControllerTest do\n"
        io << "  use ExUnit.Case\n"
        io << "  use Plug.Test\n\n"

        io << "  setup do\n"
        io << "    #{app_module}.TestHelper.setup_db()\n"
        io << "    fixtures = #{app_module}.TestHelper.setup_fixtures()\n"
        io << "    fixtures\n"
        io << "  end\n\n"

        io << "  defp dispatch(conn) do\n"
        io << "    conn\n"
        io << "    |> Plug.Conn.put_req_header(\"content-type\", \"application/x-www-form-urlencoded\")\n"
        io << "    |> #{app_module}.Router.call(#{app_module}.Router.init([]))\n"
        io << "  end\n\n"

        io << "  defp encode_params(params) do\n"
        io << "    Enum.flat_map(params, fn {outer_key, inner} ->\n"
        io << "      if is_map(inner) do\n"
        io << "        Enum.map(inner, fn {k, v} -> {\"\#{outer_key}[\#{k}]\", v} end)\n"
        io << "      else\n"
        io << "        [{\"\#{outer_key}\", inner}]\n"
        io << "      end\n"
        io << "    end)\n"
        io << "    |> URI.encode_query()\n"
        io << "  end\n\n"

        class_body = find_class_body(ast)
        if class_body
          emit_controller_test_methods(class_body, io, app_module, model_name, singular, plural)
        end

        io << "end\n"

        out_path = File.join(test_dir, "#{controller_name}_controller_test.exs")
        File.write(out_path, io.to_s)
        puts "  test/#{controller_name}_controller_test.exs"
      end
    end

    private def emit_controller_test_methods(body : Crystal::ASTNode, io : IO, app_module : String,
                                              model_name : String, singular : String, plural : String)
      exprs = case body
              when Crystal::Expressions then body.expressions
              else [body]
              end

      # Find setup block for preamble
      setup_stmts = IO::Memory.new
      exprs.each do |expr|
        if expr.is_a?(Crystal::Call) && expr.as(Crystal::Call).name == "setup" && expr.as(Crystal::Call).block
          emit_test_body(expr.as(Crystal::Call).block.not_nil!.body, setup_stmts, app_module, model_name, singular)
        end
      end
      setup_code = setup_stmts.to_s

      exprs.each do |expr|
        next unless expr.is_a?(Crystal::Call)
        call = expr.as(Crystal::Call)
        next unless call.name == "test" && call.args.size == 1 && call.block
        test_name = call.args[0].to_s.strip('"')

        io << "  test #{test_name.inspect}, fixtures do\n"
        io << setup_code unless setup_code.empty?
        begin
          emit_controller_test_body(call.block.not_nil!.body, io, app_module, model_name, singular, plural)
        rescue ex
          STDERR.puts "  WARN: test #{test_name.inspect}: #{ex.message}"
          io << "    # ERROR: #{ex.message}\n"
        end
        io << "  end\n\n"
      end
    end

    private def emit_controller_test_body(node : Crystal::ASTNode, io : IO, app_module : String,
                                           model_name : String, singular : String, plural : String)
      exprs = case node
              when Crystal::Expressions then node.expressions
              else [node]
              end

      exprs.each do |expr|
        emit_controller_test_stmt(expr, io, app_module, model_name, singular, plural)
      end
    end

    private def emit_controller_test_stmt(node : Crystal::ASTNode, io : IO, app_module : String,
                                           model_name : String, singular : String, plural : String)
      case node
      when Crystal::Assign
        target = node.target
        value = node.value
        var_name = case target
                   when Crystal::InstanceVar then target.name.lchop("@")
                   when Crystal::Var then target.name
                   else target.to_s
                   end

        if value.is_a?(Crystal::Call) && value.args.size == 1 && value.args[0].is_a?(Crystal::SymbolLiteral)
          func = value.name
          label = value.args[0].as(Crystal::SymbolLiteral).value
          io << "    #{var_name} = fixtures.#{func}_#{label}\n"
        else
          io << "    # TODO: assign #{node}\n"
        end

      when Crystal::Call
        name = node.name
        args = node.args

        case name
        when "get"
          path = url_to_elixir_path(args[0], app_module, singular, plural)
          io << "    conn = conn(:get, #{path}) |> dispatch()\n"
        when "post"
          path = url_to_elixir_path(args[0], app_module, singular, plural)
          params = extract_elixir_params(node, singular)
          io << "    conn = conn(:post, #{path}, #{params}) |> dispatch()\n"
        when "patch"
          path = url_to_elixir_path(args[0], app_module, singular, plural)
          params = extract_elixir_params(node, singular)
          io << "    conn = conn(:post, #{path}, #{params} <> \"&_method=patch\") |> dispatch()\n"
        when "delete"
          path = url_to_elixir_path(args[0], app_module, singular, plural)
          io << "    conn = conn(:post, #{path}, \"_method=delete\") |> dispatch()\n"
        when "assert_response"
          status = args[0].to_s.strip(':')
          case status
          when "success" then io << "    assert conn.status == 200\n"
          when "unprocessable_entity" then io << "    assert conn.status == 422\n"
          end
        when "assert_redirected_to"
          io << "    assert conn.status in [301, 302, 303]\n"
        when "assert_select"
          if args.size >= 2 && args[1].is_a?(Crystal::StringLiteral)
            text = args[1].as(Crystal::StringLiteral).value
            io << "    assert conn.resp_body =~ #{text.inspect}\n"
          elsif args.size >= 1
            selector = args[0].to_s.strip('"')
            if selector.starts_with?("#")
              id = selector.lchop("#").split(" ").first
              io << "    assert conn.resp_body =~ \"id=\\\"#{id}\\\"\"\n"
            else
              io << "    assert conn.resp_body =~ \"<#{selector}\"\n"
            end
          end
          # Skip nested assert_select blocks
        when "assert_equal"
          if args.size == 2
            expected = elixir_expr(args[0], app_module, singular)
            actual = elixir_expr(args[1], app_module, singular)
            io << "    assert #{actual} == #{expected}\n"
          end
        when "assert_difference", "assert_no_difference"
          if args.size >= 1 && node.block
            count_expr = args[0].to_s.strip('"')
            model = count_expr.split(".").first
            diff = args.size > 1 ? args[1].to_s.to_i : (name == "assert_difference" ? 1 : 0)
            io << "    before_count = #{app_module}.#{model}.count()\n"
            emit_controller_test_body(node.block.not_nil!.body, io, app_module, model_name, singular, plural)
            if name == "assert_difference"
              io << "    assert #{app_module}.#{model}.count() - before_count == #{diff}\n"
            else
              io << "    assert #{app_module}.#{model}.count() == before_count\n"
            end
          end
        else
          if obj = node.obj
            obj_str = obj.to_s.lchop("@")
            if name == "reload"
              cls = Inflector.classify(obj_str)
              io << "    #{obj_str} = #{app_module}.#{cls}.find(#{obj_str}.id)\n"
            end
          end
        end
      when Crystal::Nop
        # skip
      end
    end

    private def url_to_elixir_path(node : Crystal::ASTNode, app_module : String, singular : String, plural : String) : String
      case node
      when Crystal::Call
        url_name = node.name.chomp("_url")
        if node.args.empty?
          "#{app_module}.Helpers.#{url_name}_path()"
        else
          args = node.args.map do |a|
            case a
            when Crystal::InstanceVar then a.name.lchop("@")
            when Crystal::Var then a.name
            else a.to_s.lchop("@")
            end
          end
          "#{app_module}.Helpers.#{url_name}_path(#{args.join(", ")})"
        end
      else
        node.to_s.inspect
      end
    end

    private def extract_elixir_params(node : Crystal::Call, singular : String) : String
      if named = node.named_args
        params_arg = named.find { |na| na.name == "params" }
        if params_arg
          return "encode_params(#{hash_to_elixir_map(params_arg.value)})"
        end
      end
      "\"\""
    end

    private def hash_to_elixir_map(node : Crystal::ASTNode) : String
      case node
      when Crystal::HashLiteral
        entries = node.entries.map do |entry|
          key = case entry.key
                when Crystal::SymbolLiteral then "\"#{entry.key.as(Crystal::SymbolLiteral).value}\""
                when Crystal::StringLiteral then entry.key.as(Crystal::StringLiteral).value.inspect
                else entry.key.to_s.inspect
                end
          "#{key} => #{hash_to_elixir_map(entry.value)}"
        end
        "%{#{entries.join(", ")}}"
      when Crystal::NamedTupleLiteral
        entries = node.entries.map { |e| "\"#{e.key}\" => #{hash_to_elixir_map(e.value)}" }
        "%{#{entries.join(", ")}}"
      when Crystal::StringLiteral then node.value.inspect
      when Crystal::NumberLiteral then node.value.to_s
      when Crystal::Call
        if obj = node.obj
          obj_str = case obj
                    when Crystal::InstanceVar then obj.as(Crystal::InstanceVar).name.lchop("@")
                    when Crystal::Var then obj.as(Crystal::Var).name
                    else obj.to_s.lchop("@")
                    end
          "#{obj_str}.#{node.name}"
        else
          node.name
        end
      when Crystal::InstanceVar then node.name.lchop("@")
      else node.to_s.gsub("@", "")
      end
    end

    private def elixir_value(node : Crystal::ASTNode) : String
      case node
      when Crystal::StringLiteral then node.value.inspect
      when Crystal::NumberLiteral then node.value.to_s.gsub(/_i64|_i32/, "")
      when Crystal::NilLiteral then "nil"
      when Crystal::BoolLiteral then node.value.to_s
      else node.to_s
      end
    end

  end
end
