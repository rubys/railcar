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
      emit_router(output_dir)
      emit_repo(output_dir)

      puts "Done! Output in #{output_dir}/"
      puts "  cd #{output_dir} && mix deps.get && mix run --no-halt"
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
            {:jason, "~> 1.4"}
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

      File.write(File.join(lib_dir, "application.ex"), <<-EX)
      defmodule #{app_module}.Application do
        use Application

        @impl true
        def start(_type, _args) do
          children = [
            {Bandit, plug: #{app_module}.Router, port: 3000}
          ]

          opts = [strategy: :one_for_one, name: #{app_module}.Supervisor]
          IO.puts("#{app_name} running at http://localhost:3000")
          Supervisor.start_link(children, opts)
        end
      end
      EX
      puts "  lib/#{app_name}/application.ex"
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

      io << "  match _ do\n"
      io << "    send_resp(conn, 404, \"Not found\")\n"
      io << "  end\n"
      io << "end\n"

      File.write(File.join(lib_dir, "router.ex"), io.to_s)
      puts "  lib/#{app_name}/router.ex"
    end

    # ── Repo (SQLite) ──

    private def emit_repo(output_dir : String)
      app_name = app.name.downcase.gsub("-", "_")
      app_module = Inflector.classify(app_name)
      lib_dir = File.join(output_dir, "lib/#{app_name}")

      File.write(File.join(lib_dir, "repo.ex"), <<-EX)
      defmodule #{app_module}.Repo do
        @db_path Path.join(:code.priv_dir(:#{app_name}) |> to_string(), "#{app_name}.db")

        def start_link do
          File.mkdir_p!(Path.dirname(@db_path))
          {:ok, db} = Exqlite.Sqlite3.open(@db_path)
          Exqlite.Sqlite3.execute(db, "PRAGMA foreign_keys = ON")
          Process.put(:railcar_db, db)
          {:ok, db}
        end

        def db do
          Process.get(:railcar_db) || raise "Database not started"
        end
      end
      EX
      puts "  lib/#{app_name}/repo.ex"
    end
  end
end
