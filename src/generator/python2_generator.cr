# Python2Generator — generates Python from typed Crystal AST via PyAST.
#
# Pipeline:
#   1. Build Crystal AST: runtime source + model ASTs (via filter chain)
#   2. program.semantic() with synthetic calls → types on all nodes
#   3. Extract Railcar nodes, apply filters, emit Python via PyAST
#
# Built layer by layer:
#   Layer 1: Runtime (ApplicationRecord, ValidationErrors)
#   Layer 2: Models (Article, Comment — from Rails metadata + filters)
#   Layer 3: Tests
#   Layer 4: Controllers
#   Layer 5: Views
#   Layer 6: App (server, routing, static files)

require "./app_model"
require "./schema_extractor"
require "./inflector"
require "./source_parser"
require "../semantic"
require "../filters/model_boilerplate_python"
require "../filters/broadcasts_to"
require "../filters/controller_boilerplate_python"
require "../filters/instance_var_to_local"
require "../filters/params_expect"
require "../filters/respond_to_html"
require "../filters/strong_params"
require "../filters/minitest_to_pytest"
require "../../tools/cr2py/src/py_ast"
require "../../tools/cr2py/src/cr2py"
require "../../tools/cr2py/src/filters/db_filter"
require "../../tools/cr2py/src/filters/pyast_dunder_filter"
require "../../tools/cr2py/src/filters/pyast_return_filter"

module Railcar
  class Python2Generator
    getter app : AppModel
    getter rails_dir : String

    def initialize(@app, @rails_dir)
    end

    def generate(output_dir : String)
      puts "Generating Python (v2) from #{rails_dir}..."
      Dir.mkdir_p(output_dir)

      # Build model ASTs from Rails source
      model_asts = build_model_asts

      # Compile runtime + models together
      program, typed_ast = compile(model_asts)
      unless program && typed_ast
        STDERR.puts "Cannot generate Python without typed AST"
        return
      end

      # Set up filters
      emitter = Cr2Py::Emitter.new(program)
      serializer = PyAST::Serializer.new
      db_filter = Cr2Py::DbFilter.new
      dunder_filter = Cr2Py::PyAstDunderFilter.new
      return_filter = Cr2Py::PyAstReturnFilter.new
      filters = {db_filter, dunder_filter, return_filter}

      # Emit
      nodes = extract_railcar_nodes(typed_ast)
      emit_runtime(nodes, output_dir, emitter, serializer, filters)
      emit_helpers(nodes, output_dir, emitter, serializer, filters)
      emit_models(nodes, output_dir, emitter, serializer, filters)
      emit_controllers(output_dir, emitter, serializer, filters)
      emit_tests(output_dir, emitter, serializer, filters)

      # __init__.py files
      Dir.glob(File.join(output_dir, "**/*")).each do |path|
        next unless File.directory?(path)
        init = File.join(path, "__init__.py")
        File.write(init, "") unless File.exists?(init)
      end

      puts "Done! Output in #{output_dir}/"
    end

    # ── Build model ASTs from Rails source ──

    private def build_model_asts : Array(Crystal::ASTNode)
      schema_map = {} of String => TableSchema
      app.schemas.each { |s| schema_map[s.name] = s }

      asts = [] of Crystal::ASTNode
      app.models.each do |name, model|
        source_path = File.join(rails_dir, "app/models/#{Inflector.underscore(name)}.rb")
        next unless File.exists?(source_path)

        schema = schema_map[Inflector.pluralize(Inflector.underscore(name))]?
        next unless schema

        # Parse Rails model → Crystal AST → filter chain (no macros)
        ast = SourceParser.parse(source_path)
        ast = ast.transform(ModelBoilerplatePython.new(schema, model))

        asts << ast
      end
      asts
    end

    # ── Compile runtime + models ──

    private def compile(model_asts : Array(Crystal::ASTNode)) : {Crystal::Program?, Crystal::ASTNode?}
      location = Crystal::Location.new("src/app.cr", 1, 1)

      runtime_dir = File.join(File.dirname(__FILE__), "..", "runtime", "python")
      runtime_source = File.read(File.join(runtime_dir, "base.cr"))
      helpers_source = File.read(File.join(runtime_dir, "helpers.cr"))

      source = String.build do |io|
        # DB shard stub
        io << "module DB\n"
        io << "  alias Any = Bool | Float32 | Float64 | Int32 | Int64 | String | Nil\n"
        io << "  class Database\n"
        io << "    def exec(sql : String, *args) end\n"
        io << "    def exec(sql : String, args : Array) end\n"
        io << "    def scalar(sql : String, *args) : Int64; 0_i64; end\n"
        io << "    def query_one(sql : String, *args); nil; end\n"
        io << "    def query_all(sql : String, *args) : Array(Hash(String, DB::Any)); [] of Hash(String, DB::Any); end\n"
        io << "  end\n"
        io << "end\n\n"
        # Runtime source (strip requires)
        [runtime_source, helpers_source].each do |src|
          src.lines.each do |line|
            next if line.strip.starts_with?("require ")
            io << line << "\n"
          end
        end
      end

      all_nodes = [
        Crystal::Require.new("prelude").at(location),
        Crystal::Parser.parse(source),
      ] of Crystal::ASTNode

      # Add models wrapped in module Railcar
      if model_asts.size > 0
        all_nodes << Crystal::ModuleDef.new(
          Crystal::Path.new("Railcar"),
          body: Crystal::Expressions.new(model_asts.map(&.as(Crystal::ASTNode)))
        )
      end

      # Synthetic calls to force typing
      all_nodes.concat(build_synthetic_calls(model_asts))

      nodes = Crystal::Expressions.new(all_nodes)

      program = Crystal::Program.new
      compiler = Crystal::Compiler.new
      compiler.no_codegen = true
      program.compiler = compiler

      normalized = program.normalize(nodes)
      typed = program.semantic(normalized)

      puts "  semantic analysis: OK"
      {program, typed}
    rescue ex
      STDERR.puts "  semantic analysis failed:"
      STDERR.puts ex.message
      {nil, nil}
    end

    private def build_synthetic_calls(model_asts : Array(Crystal::ASTNode)) : Array(Crystal::ASTNode)
      calls = [] of Crystal::ASTNode

      # Runtime methods
      calls << Crystal::Parser.parse(<<-CR)
        _ve = Railcar::ValidationErrors.new
        _ve.add("field", "message")
        _ve.any?
        _ve.empty?
        _ve.full_messages
        _ve["field"]
        _ve.clear
        _ar = Railcar::ApplicationRecord.new
        _ar.id
        _ar.persisted?
        _ar.new_record?
        _ar.attributes
        _ar.errors
        _ar.valid?
        _ar.save
        _ar.run_validations
        Railcar::ApplicationRecord.table_name
        Railcar::ApplicationRecord.count
        Railcar::ApplicationRecord.all
        Railcar::ApplicationRecord.find(1_i64)
        _cp = Railcar::CollectionProxy.new(_ar, "fk", "Test")
        _cp.model_class
        _cp.destroy_all
        _cp.size
      CR

      # Model methods — call create, save, find, count on each model
      model_asts.each do |ast|
        if ast.is_a?(Crystal::ClassDef)
          name = ast.name.names.last
          calls << Crystal::Parser.parse(<<-CR)
            _m_#{name.downcase} = Railcar::#{name}.new
            _m_#{name.downcase}.save
            _m_#{name.downcase}.valid?
            _m_#{name.downcase}.run_validations
            Railcar::#{name}.table_name
          CR
        end
      end

      calls
    end

    # ── Emit runtime ──

    private def emit_runtime(nodes : Array(Crystal::ASTNode), output_dir : String,
                             emitter : Cr2Py::Emitter,
                             serializer : PyAST::Serializer,
                             filters : Tuple)
      runtime_dir = File.join(output_dir, "runtime")
      Dir.mkdir_p(runtime_dir)

      runtime_classes = %w[ValidationErrors ApplicationRecord CollectionProxy]
      runtime_nodes = nodes.select { |n|
        case n
        when Crystal::ClassDef
          runtime_classes.includes?(n.name.names.last)
        when Crystal::Assign
          # Module-level constants like MODEL_REGISTRY
          true
        else
          false
        end
      }

      emit_file(runtime_nodes, "runtime/base.py", output_dir, emitter, serializer, filters)
      File.write(File.join(runtime_dir, "__init__.py"), "")
    end

    # ── Emit models ──

    # ── Emit helpers ──

    private def emit_helpers(nodes : Array(Crystal::ASTNode), output_dir : String,
                             emitter : Cr2Py::Emitter,
                             serializer : PyAST::Serializer,
                             filters : Tuple)
      # Collect module-level Defs and Assigns (helpers, constants)
      helper_nodes = nodes.select { |n| n.is_a?(Crystal::Def) || n.is_a?(Crystal::Assign) }

      # Add route helpers (generated from app metadata)
      route_helpers = build_route_helpers
      helper_nodes.concat(route_helpers)

      return if helper_nodes.empty?
      emit_file(helper_nodes, "helpers.py", output_dir, emitter, serializer, filters)
    end

    private def build_route_helpers : Array(Crystal::ASTNode)
      helpers = [] of Crystal::ASTNode
      app.models.each_key do |name|
        singular = Inflector.underscore(name)
        plural = Inflector.pluralize(singular)

        helpers << Crystal::Parser.parse(
          "def #{singular}_path(model) : String\n  \"/#{plural}/\#{model.id}\"\nend"
        )
        helpers << Crystal::Parser.parse(
          "def edit_#{singular}_path(model) : String\n  \"/#{plural}/\#{model.id}/edit\"\nend"
        )
        helpers << Crystal::Parser.parse(
          "def #{plural}_path : String\n  \"/#{plural}\"\nend"
        )
        helpers << Crystal::Parser.parse(
          "def new_#{singular}_path : String\n  \"/#{plural}/new\"\nend"
        )
      end

      # Nested resource helpers
      app.models.each do |name, model|
        model.associations.each do |assoc|
          if assoc.kind == :has_many
            child = Inflector.singularize(assoc.name)
            child_plural = assoc.name
            parent = Inflector.underscore(name)
            parent_plural = Inflector.pluralize(parent)

            helpers << Crystal::Parser.parse(
              "def #{parent}_#{child_plural}_path(parent) : String\n  \"/#{parent_plural}/\#{parent.id}/#{child_plural}\"\nend"
            )
            helpers << Crystal::Parser.parse(
              "def #{parent}_#{child}_path(parent, child) : String\n  \"/#{parent_plural}/\#{parent.id}/#{child_plural}/\#{child.id}\"\nend"
            )
          end
        end
      end

      helpers
    end

    # ── Emit models ──

    private def emit_models(nodes : Array(Crystal::ASTNode), output_dir : String,
                            emitter : Cr2Py::Emitter,
                            serializer : PyAST::Serializer,
                            filters : Tuple)
      models_dir = File.join(output_dir, "models")
      Dir.mkdir_p(models_dir)

      skip = %w[ValidationErrors ApplicationRecord CollectionProxy]
      nodes.each do |node|
        next unless node.is_a?(Crystal::ClassDef)
        class_name = node.name.names.last
        next if skip.includes?(class_name)

        py_path = "models/#{Inflector.underscore(class_name)}.py"
        emit_file([node], py_path, output_dir, emitter, serializer, filters)
      end

      File.write(File.join(models_dir, "__init__.py"), "")
    end

    # ── Emit controllers ──

    private def emit_controllers(output_dir : String,
                                 emitter : Cr2Py::Emitter,
                                 serializer : PyAST::Serializer,
                                 filters : Tuple)
      controllers_dir = File.join(output_dir, "controllers")
      Dir.mkdir_p(controllers_dir)

      app.controllers.each do |info|
        controller_name = Inflector.underscore(info.name).chomp("_controller")
        source_path = File.join(rails_dir, "app/controllers/#{controller_name}_controller.rb")
        next unless File.exists?(source_path)

        model_name = Inflector.classify(Inflector.singularize(controller_name))
        nested_parent = find_nested_parent(controller_name)

        # Parse and filter
        ast = SourceParser.parse(source_path)
        ast = ast.transform(InstanceVarToLocal.new)
        ast = ast.transform(ParamsExpect.new)
        ast = ast.transform(RespondToHTML.new)
        ast = ast.transform(StrongParams.new)
        ast = ast.transform(ControllerBoilerplatePython.new(controller_name, model_name, nested_parent))

        # Emit
        py_nodes = emitter.to_nodes(ast)
        db_filter, dunder_filter, return_filter = filters
        py_nodes = return_filter.transform(py_nodes)

        mod = PyAST::Module.new(py_nodes)
        content = serializer.serialize(mod)

        # Add imports
        imports = String.build do |io|
          io << "from aiohttp import web\n"
          io << "from models.#{Inflector.underscore(model_name)} import #{model_name}\n"
          io << "from helpers import *\n"
          # Add nested model imports
          if nested_parent
            parent_model = Inflector.classify(nested_parent)
            io << "from models.#{Inflector.underscore(parent_model)} import #{parent_model}\n"
          end
          info.actions.each do |action|
            # Check if action references other models
          end
          io << "\n"
        end

        out_path = File.join(controllers_dir, "#{controller_name}.py")
        File.write(out_path, imports + content)
        puts "  controllers/#{controller_name}.py"
      end

      File.write(File.join(controllers_dir, "__init__.py"), "")
    end

    private def find_nested_parent(controller_name : String) : String?
      app.routes.routes.each do |route|
        if route.controller == Inflector.pluralize(controller_name) && route.path.includes?(":")
          parts = route.path.split("/").reject(&.empty?)
          parts.each_with_index do |part, i|
            if part.starts_with?(":") && i > 0
              parent = Inflector.singularize(parts[i - 1])
              return parent if parent != controller_name
            end
          end
        end
      end
      nil
    end

    # ── Layer 3: Tests ──

    private def emit_tests(output_dir : String,
                           emitter : Cr2Py::Emitter,
                           serializer : PyAST::Serializer,
                           filters : Tuple)
      tests_dir = File.join(output_dir, "tests")
      Dir.mkdir_p(tests_dir)

      # Generate conftest.py (db setup + fixtures)
      generate_conftest(tests_dir)

      # Convert model tests
      test_filter = MinitestToPytest.new
      model_tests_dir = File.join(rails_dir, "test/models")
      if Dir.exists?(model_tests_dir)
        Dir.glob(File.join(model_tests_dir, "*_test.rb")).each do |path|
          basename = File.basename(path, ".rb")
          py_name = "test_#{basename.chomp("_test")}.py"

          ast = SourceParser.parse(path)
          ast = ast.transform(test_filter)

          py_nodes = emitter.to_nodes(ast)
          db_filter, dunder_filter, return_filter = filters
          py_nodes = return_filter.transform(py_nodes)

          mod = PyAST::Module.new(py_nodes)
          content = serializer.serialize(mod)

          # Add test imports
          imports = String.build do |io|
            io << "import sys\nimport os\n"
            io << "sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))\n\n"
            app.models.each_key do |name|
              io << "from models.#{Inflector.underscore(name)} import #{name}\n"
            end
            io << "from tests.conftest import *\n\n"
          end

          out_path = File.join(tests_dir, py_name)
          File.write(out_path, imports + content)
          puts "  tests/#{py_name}"
        end
      end

      File.write(File.join(tests_dir, "__init__.py"), "")
    end

    private def generate_conftest(tests_dir : String)
      schema_map = {} of String => TableSchema
      app.schemas.each { |s| schema_map[s.name] = s }

      io = IO::Memory.new
      io << "import sqlite3\n"
      io << "import sys\nimport os\n"
      io << "sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))\n\n"
      io << "from runtime.base import ApplicationRecord\n"
      app.models.each_key do |name|
        io << "from models.#{Inflector.underscore(name)} import #{name}\n"
      end
      io << "\n"

      # setup_db function
      io << "def setup_db():\n"
      io << "    db = sqlite3.connect(':memory:')\n"
      io << "    db.row_factory = sqlite3.Row\n"
      io << "    db.execute('PRAGMA foreign_keys = ON')\n"
      app.schemas.each do |schema|
        cols = schema.columns.map { |c| "#{c.name} #{c.type}" }
        # Add constraints
        # Always add id column (Rails makes it implicit)
        all_cols = [Column.new("id", "INTEGER")] + schema.columns
        col_defs = all_cols.map do |c|
          parts = "#{c.name} #{c.type}"
          parts += " PRIMARY KEY AUTOINCREMENT" if c.name == "id"
          parts += " NOT NULL" unless c.name == "id"
          parts
        end
        io << "    db.execute('''CREATE TABLE IF NOT EXISTS #{schema.name} (\n"
        io << "        #{col_defs.join(",\n        ")}\n"
        io << "    )''')\n"
      end
      io << "    ApplicationRecord.db = db\n"
      io << "    return db\n\n"

      # Pytest fixture that auto-runs setup for every test
      io << "import pytest\n\n"
      io << "@pytest.fixture(autouse=True)\n"
      io << "def _setup_test_db():\n"
      io << "    db = setup_db()\n"
      io << "    setup_fixtures()\n"
      io << "    yield\n"
      io << "    db.close()\n\n"

      # Fixture setup
      fixture_table_names = app.fixtures.map(&.name).to_set
      association_fields = Set(String).new
      app.models.each do |_, model|
        model.associations.each do |assoc|
          association_fields << Inflector.singularize(assoc.name) if assoc.kind == :belongs_to
        end
      end

      io << "def setup_fixtures():\n"
      app.fixtures.each do |fixture|
        model_name = Inflector.classify(Inflector.singularize(fixture.name))
        fixture.records.each do |record|
          fields = record.fields.reject { |k, _| k == "id" }
          field_strs = fields.map do |k, v|
            if association_fields.includes?(k) && fixture_table_names.includes?(Inflector.pluralize(k))
              ref_fixture = Inflector.pluralize(k)
              "#{k}_id=#{ref_fixture}_#{v}.id()"
            else
              "#{k}=#{v.inspect}"
            end
          end
          io << "    global #{fixture.name}_#{record.label}\n"
          io << "    #{fixture.name}_#{record.label} = #{model_name}.create(#{field_strs.join(", ")})\n"
        end
      end
      io << "\n"

      # Fixture accessor functions
      app.fixtures.each do |fixture|
        model_name = Inflector.classify(Inflector.singularize(fixture.name))
        io << "def #{fixture.name}(name):\n"
        io << "    all_records = #{model_name}.all()\n"
        fixture.records.each_with_index do |record, i|
          io << "    if name == '#{record.label}':\n"
          io << "        return all_records[#{i}]\n"
        end
        io << "    raise ValueError(f'Unknown fixture: {name}')\n\n"
      end

      File.write(File.join(tests_dir, "conftest.py"), io.to_s)
      puts "  tests/conftest.py"
    end

    # ── Shared ──

    private def extract_railcar_nodes(ast : Crystal::ASTNode) : Array(Crystal::ASTNode)
      nodes = [] of Crystal::ASTNode
      case ast
      when Crystal::Expressions
        ast.expressions.each do |expr|
          if expr.is_a?(Crystal::ModuleDef) && expr.name.names.includes?("Railcar")
            case expr.body
            when Crystal::Expressions
              nodes.concat(expr.body.as(Crystal::Expressions).expressions)
            else
              nodes << expr.body
            end
          end
        end
      end
      nodes
    end

    private def emit_file(nodes : Array(Crystal::ASTNode), py_path : String,
                          output_dir : String,
                          emitter : Cr2Py::Emitter,
                          serializer : PyAST::Serializer,
                          filters : Tuple)
      db_filter, dunder_filter, return_filter = filters

      py_nodes = [] of PyAST::Node
      nodes.each do |node|
        transformed = node.transform(db_filter)
        py_nodes.concat(emitter.to_nodes(transformed))
      end
      py_nodes = dunder_filter.transform(py_nodes)
      py_nodes = return_filter.transform(py_nodes)

      mod = PyAST::Module.new(py_nodes)
      content = serializer.serialize(mod)
      imports = generate_imports(content, py_path)

      out_path = File.join(output_dir, py_path)
      Dir.mkdir_p(File.dirname(out_path))
      File.write(out_path, imports + content)
      puts "  #{py_path}"
    end

    private def generate_imports(content : String, py_path : String = "") : String
      imports = [] of String
      imports << "from __future__ import annotations" if content.includes?("->") || content.includes?(": ")
      imports << "from typing import Any" if content.includes?("Any")
      imports << "import sqlite3" if content.includes?("sqlite3.")
      imports << "import logging" if content.includes?("logging.")
      imports << "from datetime import datetime" if content.includes?("datetime.")

      # Cross-file imports based on content scanning
      code = content.lines.reject(&.strip.starts_with?("#")).join("\n")

      if py_path.starts_with?("models/") && !py_path.includes?("__init__")
        imports << "from runtime.base import ApplicationRecord" if code.includes?("ApplicationRecord")
        imports << "from runtime.base import CollectionProxy" if code.includes?("CollectionProxy")
        imports << "from runtime.base import MODEL_REGISTRY" if code.includes?("MODEL_REGISTRY")
        # No cross-model imports — models use MODEL_REGISTRY for lazy resolution
      end

      imports.empty? ? "" : imports.join("\n") + "\n\n"
    end
  end
end
