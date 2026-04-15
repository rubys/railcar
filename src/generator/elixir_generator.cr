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
      emit_models(output_dir)
      emit_router(output_dir)
      emit_tests(output_dir)

      puts "Done! Output in #{output_dir}/"
      puts "  cd #{output_dir} && mix deps.get && mix test"
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
          if Application.get_env(:#{app_name}, :skip_start) do
            Supervisor.start_link([], strategy: :one_for_one, name: #{app_module}.Supervisor)
          else
            children = [
              {Bandit, plug: #{app_module}.Router, port: 3000}
            ]

            opts = [strategy: :one_for_one, name: #{app_module}.Supervisor]
            IO.puts("#{app_name} running at http://localhost:3000")
            Supervisor.start_link(children, opts)
          end
        end
      end
      EX
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

    # ── Models ──

    private def emit_models(output_dir : String)
      app_name = app.name.downcase.gsub("-", "_")
      app_module = Inflector.classify(app_name)
      lib_dir = File.join(output_dir, "lib/#{app_name}")

      schema_map = {} of String => TableSchema
      app.schemas.each { |s| schema_map[s.name] = s }

      app.models.each do |name, model|
        table_name = Inflector.pluralize(Inflector.underscore(name))
        schema = schema_map[table_name]?
        next unless schema

        io = IO::Memory.new
        columns = schema.columns.reject { |c| c.name == "id" }.map { |c| ":#{c.name}" }

        io << "defmodule #{app_module}.#{name} do\n"
        io << "  use Railcar.Record, table: \"#{table_name}\", columns: [#{columns.join(", ")}]\n\n"

        # Associations
        model.associations.each do |assoc|
          case assoc.kind
          when :has_many
            target = Inflector.classify(Inflector.singularize(assoc.name))
            fk = assoc.options["foreign_key"]? || "#{Inflector.underscore(name)}_id"
            io << "  def #{assoc.name}(record) do\n"
            io << "    #{app_module}.#{target}.where(%{#{fk}: record.id})\n"
            io << "  end\n\n"

            # dependent: :destroy
            if assoc.options["dependent"]? == "destroy"
              # Will be handled in delete override
            end
          when :belongs_to
            target = Inflector.classify(assoc.name)
            fk = assoc.options["foreign_key"]? || "#{assoc.name}_id"
            io << "  def #{assoc.name}(record) do\n"
            io << "    #{app_module}.#{target}.find(record.#{fk})\n"
            io << "  end\n\n"
          end
        end

        # Validations
        presence_validations = model.validations.select { |v| v.kind == "presence" }
        length_validations = model.validations.select { |v| v.kind == "length" }
        belongs_to_assocs = model.associations.select { |a| a.kind == :belongs_to }

        unless presence_validations.empty? && length_validations.empty? && belongs_to_assocs.empty?
          io << "  def run_validations(record) do\n"
          io << "    errors = []\n"

          belongs_to_assocs.each do |a|
            target = Inflector.classify(a.name)
            io << "    errors = errors ++ Railcar.Validation.validate_belongs_to(record, :#{a.name}, #{app_module}.#{target})\n"
          end

          presence_validations.each do |v|
            io << "    errors = errors ++ Railcar.Validation.validate_presence(record, :#{v.field})\n"
          end

          length_validations.each do |v|
            if min = v.options["minimum"]?
              io << "    errors = errors ++ Railcar.Validation.validate_length(record, :#{v.field}, minimum: #{min})\n"
            end
          end

          io << "    errors\n"
          io << "  end\n\n"
        end

        # Destroy override for dependent: :destroy
        destroy_assocs = model.associations.select { |a| a.options["dependent"]? == "destroy" }
        unless destroy_assocs.empty?
          io << "  def delete(record) do\n"
          destroy_assocs.each do |a|
            target = Inflector.classify(Inflector.singularize(a.name))
            fk = a.options["foreign_key"]? || "#{Inflector.underscore(name)}_id"
            io << "    #{assoc_name = a.name}(record) |> Enum.each(&#{app_module}.#{target}.delete/1)\n"
          end
          io << "    super(record)\n"
          io << "  end\n\n"
        end

        io << "end\n"

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

      io << "  match _ do\n"
      io << "    send_resp(conn, 404, \"Not found\")\n"
      io << "  end\n"
      io << "end\n"

      File.write(File.join(lib_dir, "router.ex"), io.to_s)
      puts "  lib/#{app_name}/router.ex"
    end

    # ── Tests ──

    private def emit_tests(output_dir : String)
      app_name = app.name.downcase.gsub("-", "_")
      app_module = Inflector.classify(app_name)
      test_dir = File.join(output_dir, "test")
      Dir.mkdir_p(test_dir)

      emit_test_helper(test_dir, app_name, app_module)
      emit_model_tests(test_dir, app_name, app_module)
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
          if node.name == "id"
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
