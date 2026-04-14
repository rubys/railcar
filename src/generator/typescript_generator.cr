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
