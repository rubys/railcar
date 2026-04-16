# RustGenerator — orchestrates Rust generation from Rails app via Crystal AST.
#
# Pipeline:
#   1. Build Crystal AST: runtime source + model ASTs (via filter chain)
#   2. Emit models via Cr2Rs emitter
#
# Target: axum + rusqlite + tokio.

require "./app_model"
require "./schema_extractor"
require "./inflector"
require "./source_parser"
require "./fixture_loader"
require "../semantic"
require "../filters/model_boilerplate_python"
require "../filters/broadcasts_to"
require "../emitter/rust/cr2rs"

module Railcar
  class RustGenerator
    getter app : AppModel
    getter rails_dir : String
    getter broadcast_asts : Hash(String, Crystal::ASTNode) = {} of String => Crystal::ASTNode

    def initialize(@app, @rails_dir)
    end

    def generate(output_dir : String)
      puts "Generating Rust from #{rails_dir}..."
      Dir.mkdir_p(output_dir)

      app_name = app.name.downcase.gsub("-", "_")

      model_asts = build_model_asts

      emit_cargo_toml(output_dir, app_name)
      emit_runtime(output_dir)
      emit_models(output_dir, app_name, model_asts)

      puts "Done! Output in #{output_dir}/"
      puts "  cd #{output_dir} && cargo test"
    end

    # ── Build model ASTs from Rails source ──

    private def build_model_asts : Hash(String, Crystal::ASTNode)
      schema_map = {} of String => TableSchema
      app.schemas.each { |s| schema_map[s.name] = s }

      asts = {} of String => Crystal::ASTNode
      app.models.each do |name, model|
        source_path = File.join(rails_dir, "app/models/#{Inflector.underscore(name)}.rb")
        next unless File.exists?(source_path)

        schema = schema_map[Inflector.pluralize(Inflector.underscore(name))]?
        next unless schema

        ast = SourceParser.parse(source_path)
        ast = ast.transform(BroadcastsTo.new)
        @broadcast_asts[name] = ast.clone
        ast = ast.transform(ModelBoilerplatePython.new(schema, model))

        asts[name] = ast
      end
      asts
    end

    # ── Cargo.toml ──

    private def emit_cargo_toml(output_dir : String, app_name : String)
      File.write(File.join(output_dir, "Cargo.toml"), <<-TOML)
      [package]
      name = "#{app_name}"
      version = "0.1.0"
      edition = "2021"

      [dependencies]
      rusqlite = { version = "0.32", features = ["bundled"] }
      chrono = "0.4"
      lazy_static = "1.5"
      TOML
      puts "  Cargo.toml"
    end

    # ── Runtime ──

    private def emit_runtime(output_dir : String)
      src_dir = File.join(output_dir, "src")
      Dir.mkdir_p(src_dir)

      runtime_src = File.join(File.dirname(__FILE__), "..", "runtime", "rust", "railcar.rs")
      File.copy(runtime_src, File.join(src_dir, "railcar.rs"))
      puts "  src/railcar.rs"
    end

    # ── Models ──

    private def emit_models(output_dir : String, app_name : String, model_asts : Hash(String, Crystal::ASTNode))
      src_dir = File.join(output_dir, "src")
      Dir.mkdir_p(src_dir)

      schema_map = {} of String => TableSchema
      app.schemas.each { |s| schema_map[s.name] = s }

      emitter = Cr2Rs::Emitter.new

      # Collect model names for mod declarations
      model_names = [] of String

      model_asts.each do |name, ast|
        next unless ast.is_a?(Crystal::ClassDef)
        table_name = Inflector.pluralize(Inflector.underscore(name))
        schema = schema_map[table_name]?
        next unless schema

        broadcast_ast = broadcast_asts[name]?
        source = emitter.emit_model(ast.as(Crystal::ClassDef), name, schema, app_name, broadcast_ast)
        singular = Inflector.underscore(name)

        File.write(File.join(src_dir, "#{singular}.rs"), source)
        puts "  src/#{singular}.rs"
        model_names << singular
      end

      # Generate lib.rs with mod declarations
      io = IO::Memory.new
      io << "pub mod railcar;\n"
      model_names.each do |name|
        io << "pub mod #{name};\n"
      end
      File.write(File.join(src_dir, "lib.rs"), io.to_s)
      puts "  src/lib.rs"
    end
  end
end
