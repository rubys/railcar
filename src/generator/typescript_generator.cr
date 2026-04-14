# TypeScriptGenerator — generates TypeScript from Rails app via Crystal AST.
#
# Pipeline:
#   1. Build Crystal AST: runtime source + model ASTs (via filter chain)
#   2. program.semantic() → types on all nodes
#   3. Extract model nodes, emit TypeScript via Cr2Ts
#
# Currently handles: models only (controllers, views, tests coming later)

require "./app_model"
require "./schema_extractor"
require "./inflector"
require "./source_parser"
require "../semantic"
require "../filters/model_boilerplate_python"
require "../filters/broadcasts_to"
require "../emitter/typescript/cr2ts"
require "./fixture_loader"

module Railcar
  class TypeScriptGenerator
    getter app : AppModel
    getter rails_dir : String

    def initialize(@app, @rails_dir)
    end

    def generate(output_dir : String)
      puts "Generating TypeScript from #{rails_dir}..."
      Dir.mkdir_p(output_dir)

      # Build model ASTs from Rails source
      model_asts = build_model_asts

      # Compile runtime + models together for type inference
      program, typed_ast = compile(model_asts)
      unless program && typed_ast
        STDERR.puts "Cannot generate TypeScript without typed AST"
        return
      end

      # Emit
      emit_runtime(output_dir)
      emit_models(typed_ast, output_dir)
      emit_broadcast_callbacks(output_dir)
      emit_tests(output_dir)
      emit_package_json(output_dir)

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

        # Parse Rails model → Crystal AST → filter chain
        # Reuse ModelBoilerplatePython — it produces macro-free Crystal that works
        # for any target language. The key output: TABLE, COLUMNS, property decls,
        # association methods, run_validations, destroy override.
        ast = SourceParser.parse(source_path)
        ast = ast.transform(BroadcastsTo.new)
        ast = ast.transform(ModelBoilerplatePython.new(schema, model))

        asts << ast
      end
      asts
    end

    # ── Compile runtime + models for type inference ──

    private def compile(model_asts : Array(Crystal::ASTNode)) : {Crystal::Program?, Crystal::ASTNode?}
      location = Crystal::Location.new("src/app.cr", 1, 1)

      runtime_dir = File.join(File.dirname(__FILE__), "..", "runtime", "typescript")
      runtime_source = File.read(File.join(runtime_dir, "base.cr"))

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
        runtime_source.lines.each do |line|
          next if line.strip.starts_with?("require ")
          io << line << "\n"
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
      STDERR.puts "  semantic analysis failed: #{ex.message}"
      STDERR.puts ex.backtrace.first(15).join("\n")
      {nil, nil}
    end

    private def build_synthetic_calls(model_asts : Array(Crystal::ASTNode)) : Array(Crystal::ASTNode)
      calls = [] of Crystal::ASTNode

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

    private def emit_runtime(output_dir : String)
      runtime_dir = File.join(output_dir, "runtime")
      Dir.mkdir_p(runtime_dir)

      runtime_source = File.join(File.dirname(__FILE__), "..", "runtime", "typescript", "base_runtime.ts")
      File.copy(runtime_source, File.join(runtime_dir, "base.ts"))
      puts "  runtime/base.ts"
    end

    # ── Emit models ──

    private def emit_models(typed_ast : Crystal::ASTNode, output_dir : String)
      models_dir = File.join(output_dir, "models")
      Dir.mkdir_p(models_dir)

      emitter = Cr2Ts::Emitter.new

      # Extract Railcar module nodes from typed AST
      nodes = extract_railcar_nodes(typed_ast)

      skip = %w[ValidationErrors ApplicationRecord CollectionProxy]
      nodes.each do |node|
        next unless node.is_a?(Crystal::ClassDef)
        class_name = node.name.names.last
        next if skip.includes?(class_name)

        ts_source = emitter.emit_model(node, class_name)

        # Add imports
        imports = String.build do |io|
          io << "import { ApplicationRecord, CollectionProxy, MODEL_REGISTRY } from \"../runtime/base.js\";\n\n"
        end

        out_path = File.join(models_dir, "#{Inflector.underscore(class_name)}.ts")
        File.write(out_path, imports + ts_source)
        puts "  models/#{Inflector.underscore(class_name)}.ts"
      end
    end

    # ── Emit broadcast callbacks ──

    private def emit_broadcast_callbacks(output_dir : String)
      app.models.each_key do |name|
        source_path = File.join(rails_dir, "app/models/#{Inflector.underscore(name)}.rb")
        next unless File.exists?(source_path)

        ast = SourceParser.parse(source_path)
        ast = ast.transform(BroadcastsTo.new)

        callbacks = [] of String
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

          broadcast_call = extract_broadcast_expr(block.body)
          next unless broadcast_call

          ts_callback = call.name == "after_save" ? "afterSave" : "afterDestroy"
          callbacks << "#{name}.#{ts_callback}((record) => (record as #{name}).#{broadcast_call});"
        end

        next if callbacks.empty?

        out_path = File.join(output_dir, "models/#{Inflector.underscore(name)}.ts")
        next unless File.exists?(out_path)

        File.open(out_path, "a") do |f|
          f << "\n// Turbo Streams broadcast callbacks\n"
          callbacks.each { |cb| f << cb << "\n" }
        end
      end
    end

    private def extract_broadcast_expr(body : Crystal::ASTNode) : String?
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
               when "broadcast_replace_to" then "broadcastReplaceTo"
               when "broadcast_append_to"  then "broadcastAppendTo"
               when "broadcast_prepend_to" then "broadcastPrependTo"
               when "broadcast_remove_to"  then "broadcastRemoveTo"
               else call.name
               end

      args = call.args.map do |a|
        case a
        when Crystal::StringLiteral
          a.value.inspect
        when Crystal::StringInterpolation
          parts = a.expressions.map do |part|
            case part
            when Crystal::StringLiteral then part.value
            when Crystal::Call
              "${record.#{part.name}}"
            else "${#{part}}"
            end
          end
          "`#{parts.join}`"
        else
          a.to_s.inspect
        end
      end

      "#{method}(#{args.join(", ")})"
    end

    # ── Emit tests ──

    private def emit_tests(output_dir : String)
      tests_dir = File.join(output_dir, "tests")
      Dir.mkdir_p(tests_dir)

      emit_test_setup(tests_dir)
      emit_model_tests(tests_dir)
    end

    private def emit_test_setup(tests_dir : String)
      schema_map = {} of String => TableSchema
      app.schemas.each { |s| schema_map[s.name] = s }

      io = IO::Memory.new
      io << "import Database from \"better-sqlite3\";\n"
      io << "import { ApplicationRecord } from \"../runtime/base.js\";\n"

      # Import all models
      app.models.each_key do |name|
        io << "import { #{name} } from \"../models/#{Inflector.underscore(name)}.js\";\n"
      end
      io << "\n"

      # Setup function: create in-memory DB + tables
      io << "export function setupDb(): Database.Database {\n"
      io << "  const db = new Database(\":memory:\");\n"
      io << "  db.exec(\"PRAGMA foreign_keys = ON\");\n"

      app.schemas.each do |schema|
        all_cols = [{name: "id", type: "INTEGER"}]
        schema.columns.each { |c| all_cols << {name: c.name, type: c.type} }
        col_defs = all_cols.map do |c|
          parts = "#{c[:name]} #{c[:type]}"
          parts += " PRIMARY KEY AUTOINCREMENT" if c[:name] == "id"
          parts += " NOT NULL" unless c[:name] == "id"
          parts
        end
        io << "  db.exec(`CREATE TABLE #{schema.name} (\n"
        io << "    #{col_defs.join(",\n    ")}\n"
        io << "  )`);\n"
      end

      io << "  ApplicationRecord.db = db;\n"
      io << "  return db;\n"
      io << "}\n\n"

      # Fixture creation
      sorted_fixtures = FixtureLoader.sort_by_dependency(app.fixtures, app.models)

      io << "export function setupFixtures(): void {\n"
      sorted_fixtures.each do |table|
        singular = Inflector.singularize(table.name)
        model_name = Inflector.classify(singular)
        next unless app.models.has_key?(model_name)

        table.records.each do |record|
          # Resolve fixture references (e.g., article: one → article_id: articles_one.id)
          attrs = [] of String
          record.fields.each do |field, value|
            # Check if this field is a fixture reference
            model_info = app.models[model_name]?
            assoc = model_info.try(&.associations.find { |a| a.name == field })
            if assoc && assoc.kind == :belongs_to
              # Reference to another fixture: article: one → article_id: articles_one.id
              ref_table = Inflector.pluralize(field)
              attrs << "#{field}_id: #{ref_table}_#{value}.id!"
            else
              # Regular value
              if value.match(/^\d+$/)
                attrs << "#{field}: #{value}"
              else
                attrs << "#{field}: #{value.inspect}"
              end
            end
          end
          var_name = "#{table.name}_#{record.label}"
          io << "  #{var_name} = #{model_name}.create({ #{attrs.join(", ")} });\n"
        end
      end
      io << "}\n\n"

      # Export fixture variables
      sorted_fixtures.each do |table|
        table.records.each do |record|
          var_name = "#{table.name}_#{record.label}"
          io << "export let #{var_name}: ApplicationRecord;\n"
        end
      end
      io << "\n"

      # Fixture accessor functions (like Python's articles("one"))
      app.models.each_key do |name|
        table_name = Inflector.pluralize(Inflector.underscore(name))
        fixture_table = app.fixtures.find { |t| t.name == table_name }
        next unless fixture_table

        io << "export function #{table_name}(name: string): ApplicationRecord {\n"
        fixture_table.records.each_with_index do |record, i|
          keyword = i == 0 ? "if" : "} else if"
          io << "  #{keyword} (name === #{record.label.inspect}) {\n"
          io << "    return #{name}.find(#{table_name}_#{record.label}.id!);\n"
        end
        io << "  }\n"
        io << "  throw new Error(`Unknown fixture: ${name}`);\n"
        io << "}\n\n"
      end

      File.write(File.join(tests_dir, "setup.ts"), io.to_s)
      puts "  tests/setup.ts"
    end

    private def emit_model_tests(tests_dir : String)
      test_dir = File.join(rails_dir, "test/models")
      return unless Dir.exists?(test_dir)

      Dir.glob(File.join(test_dir, "*_test.rb")).sort.each do |path|
        basename = File.basename(path, "_test.rb")
        model_name = Inflector.classify(basename)

        ts_source = convert_model_test(path, model_name, basename)
        next if ts_source.empty?

        out_path = File.join(tests_dir, "#{basename}.test.ts")
        File.write(out_path, ts_source)
        puts "  tests/#{basename}.test.ts"
      end
    end

    private def convert_model_test(path : String, model_name : String, basename : String) : String
      source = File.read(path)
      table_name = Inflector.pluralize(basename)

      io = IO::Memory.new
      io << "import { describe, it, beforeEach, afterEach } from \"node:test\";\n"
      io << "import assert from \"node:assert/strict\";\n"
      # Detect all fixture accessor functions referenced in the test
      fixture_funcs = Set(String).new
      fixture_funcs << table_name  # always include own fixtures
      app.fixtures.each do |ft|
        if source.includes?("#{ft.name}(:")
          fixture_funcs << ft.name
        end
      end
      io << "import { setupDb, setupFixtures, #{fixture_funcs.join(", ")} } from \"./setup.js\";\n"

      # Import models used in this test
      io << "import { #{model_name} } from \"../models/#{basename}.js\";\n"
      # Also import related models if referenced
      app.models.each_key do |name|
        next if name == model_name
        if source.includes?(name)
          io << "import { #{name} } from \"../models/#{Inflector.underscore(name)}.js\";\n"
        end
      end
      io << "import type Database from \"better-sqlite3\";\n"
      io << "\n"

      io << "let db: Database.Database;\n\n"
      io << "beforeEach(() => {\n"
      io << "  db = setupDb();\n"
      io << "  setupFixtures();\n"
      io << "});\n\n"
      io << "afterEach(() => {\n"
      io << "  db.close();\n"
      io << "});\n\n"

      # Parse test blocks from Ruby source
      io << "describe(\"#{model_name}\", () => {\n"

      # Extract test blocks using simple regex
      source.scan(/test\s+"([^"]+)"\s+do\n(.*?)end/m).each do |match|
        test_name = match[1]
        test_body = match[2]
        ts_body = convert_test_body(test_body, model_name, basename)
        io << "  it(#{test_name.inspect}, () => {\n"
        io << ts_body
        io << "  });\n\n"
      end

      io << "});\n"
      io.to_s
    end

    private def convert_test_body(body : String, model_name : String, basename : String) : String
      table_name = Inflector.pluralize(basename)
      lines = body.strip.lines
      io = IO::Memory.new

      lines.each do |line|
        stripped = line.strip
        next if stripped.empty?

        case stripped
        when /^(\w+)\s*=\s*(\w+)\(:(\w+)\)$/
          # article = articles(:one) → fixture accessor
          var = $1
          func = $2
          label = $3
          io << "    const #{var} = #{func}(#{label.inspect});\n"

        when /^assert_not_nil\s+(\w+)\.(\w+)$/
          io << "    assert.notStrictEqual(#{$1}.#{$2}, null);\n"

        when /^assert_equal\s+"([^"]+)",\s*(\w+)\.(\w+)$/
          io << "    assert.strictEqual((#{$2} as any).#{$3}, #{$1.inspect});\n"

        when /^assert_equal\s+(\w+)\(:(\w+)\)\.(\w+),\s*(\w+)\.(\w+)$/
          # assert_equal articles(:one).id, comment.article_id
          io << "    assert.strictEqual((#{$4} as any).#{$5}, #{$1}(#{$2.inspect}).#{$3});\n"

        when /^(\w+)\s*=\s*(\w+)\.new\((.+)\)$/
          # article = Article.new(title: "", body: "...")
          attrs = convert_ruby_hash($3)
          io << "    const #{$1} = new #{$2}({ #{attrs} });\n"

        when /^assert_not\s+(\w+)\.(\w+)$/
          ts_method = ts_method_name($2)
          io << "    assert.strictEqual(#{$1}.#{ts_method}(), false);\n"

        when /^assert_equal\s+(\w+)\.(\w+),\s*(\w+)\.(\w+)$/
          # assert_equal article.id, comment.article_id
          io << "    assert.strictEqual((#{$3} as any).#{$4}, (#{$1} as any).#{$2});\n"

        when /^(\w+)\s*=\s*(\w+)\.(\w+)\.create\((.+)\)$/
          # comment = article.comments.create(...)
          attrs = convert_ruby_hash($4)
          ts_assoc = ts_method_name($3)
          io << "    const #{$1} = (#{$2} as any).#{ts_assoc}().create({ #{attrs} });\n"

        when /^(\w+)\s*=\s*(\w+)\.(\w+)\.build\((.+)\)$/
          attrs = convert_ruby_hash($4)
          ts_assoc = ts_method_name($3)
          io << "    const #{$1} = (#{$2} as any).#{ts_assoc}().build({ #{attrs} });\n"

        when /^assert_difference\("(\w+)\.count",\s*(-?\d+)\)\s+do$/
          model = $1
          diff = $2
          io << "    const _before = #{model}.count();\n"

        when /^(\w+)\.destroy$/
          io << "    #{$1}.destroy();\n"

        when /^end$/
          # Check if we're closing an assert_difference block
          if io.to_s.includes?("_before = ")
            # Find the last assert_difference to get the expected diff and model
            # We already emitted _before, just need the assertion
          end

        else
          io << "    // TODO: #{stripped}\n"
        end
      end

      # Handle assert_difference pattern: check if _before was set
      result = io.to_s
      if result.includes?("_before = ")
        # Find the model from the _before line
        if result =~ /const _before = (\w+)\.count\(\);/
          model = $1
          # Add assertion after the last line before closing
          result = result.rstrip
          result += "\n    assert.strictEqual(#{model}.count() - _before, "
          # Find the diff value - scan the original body
          if body =~ /assert_difference\("\w+\.count",\s*(-?\d+)\)/
            result += "#{$1}"
          else
            result += "-1"
          end
          result += ");\n"
        end
      end

      result
    end

    private def convert_ruby_hash(ruby : String) : String
      # Convert "title: \"foo\", body: \"bar\"" → "title: \"foo\", body: \"bar\""
      # Convert "commenter: \"Alice\"" → "commenter: \"Alice\""
      # Already mostly valid TS/JS syntax, just need to handle symbol keys
      ruby.gsub(/(\w+):\s*/, "\\1: ").gsub(/article_id:\s*(\d+)/, "article_id: \\1")
    end

    private def ts_method_name(name : String) : String
      case name
      when "save" then "save"
      when "destroy" then "destroy"
      when "comments" then "comments"
      when "valid?" then "valid"
      else name.gsub(/_([a-z])/) { |_, m| m[1].upcase }
      end
    end

    # ── Emit package.json ──

    private def emit_package_json(output_dir : String)
      File.write(File.join(output_dir, "package.json"), <<-JSON)
      {
        "name": "#{app.name}",
        "private": true,
        "type": "module",
        "dependencies": {
          "better-sqlite3": "^11.0.0"
        },
        "devDependencies": {
          "@types/better-sqlite3": "^7.6.0",
          "tsx": "^4.0.0",
          "typescript": "^5.0.0"
        }
      }
      JSON
      puts "  package.json"
    end

    # ── Helpers ──

    private def extract_railcar_nodes(typed_ast : Crystal::ASTNode) : Array(Crystal::ASTNode)
      nodes = [] of Crystal::ASTNode
      case typed_ast
      when Crystal::Expressions
        typed_ast.expressions.each do |expr|
          case expr
          when Crystal::ModuleDef
            if expr.name.names.includes?("Railcar")
              case expr.body
              when Crystal::Expressions
                nodes.concat(expr.body.as(Crystal::Expressions).expressions)
              else
                nodes << expr.body
              end
            end
          end
        end
      end
      nodes
    end
  end
end
