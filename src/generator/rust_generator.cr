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
      emit_model_tests(output_dir, app_name)

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

    # ── Model tests ──

    private def emit_model_tests(output_dir : String, app_name : String)
      rails_test_dir = File.join(rails_dir, "test/models")
      return unless Dir.exists?(rails_test_dir)

      tests_dir = File.join(output_dir, "tests")
      Dir.mkdir_p(tests_dir)

      io = IO::Memory.new
      io << "use #{app_name}::railcar;\n"
      io << "use #{app_name}::article::*;\n"
      io << "use #{app_name}::comment::*;\n"
      io << "use rusqlite::Connection;\n"
      io << "use std::collections::HashMap;\n\n"

      # Setup helper
      io << "fn setup_db() {\n"
      io << "    let conn = Connection::open_in_memory().unwrap();\n"
      io << "    conn.execute_batch(\"PRAGMA foreign_keys = ON;\").unwrap();\n"
      app.schemas.each do |schema|
        all_cols = [{name: "id", type: "INTEGER"}]
        schema.columns.each { |c| all_cols << {name: c.name, type: c.type} }
        col_defs = all_cols.map do |c|
          parts = "#{c[:name]} #{c[:type]}"
          parts += " PRIMARY KEY AUTOINCREMENT" if c[:name] == "id"
          parts += " NOT NULL" unless c[:name] == "id"
          parts
        end
        io << "    conn.execute_batch(\"CREATE TABLE #{schema.name} (\n"
        io << "        #{col_defs.join(",\n        ")}\n"
        io << "    );\").unwrap();\n"
      end
      io << "    *railcar::DB.lock().unwrap() = Some(conn);\n"
      io << "}\n\n"

      # Fixtures struct
      io << "struct Fixtures {\n"
      sorted_fixtures = FixtureLoader.sort_by_dependency(app.fixtures, app.models)
      sorted_fixtures.each do |table|
        singular = Inflector.singularize(table.name)
        model_name = Inflector.classify(singular)
        next unless app.models.has_key?(model_name)
        table.records.each do |record|
          io << "    #{table.name}_#{record.label}: #{model_name},\n"
        end
      end
      io << "}\n\n"

      io << "fn setup_fixtures() -> Fixtures {\n"
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
              attrs << "(\"#{field}_id\".to_string(), format!(\"{}\", #{ref_table}_#{value}.id))"
            else
              attrs << "(\"#{field}\".to_string(), \"#{value}\".to_string())"
            end
          end

          var_name = "#{table.name}_#{record.label}"
          io << "    let #{var_name} = create_#{singular}(&HashMap::from([#{attrs.join(", ")}])).unwrap();\n"
        end
      end
      io << "    Fixtures {\n"
      sorted_fixtures.each do |table|
        singular = Inflector.singularize(table.name)
        model_name = Inflector.classify(singular)
        next unless app.models.has_key?(model_name)
        table.records.each do |record|
          io << "        #{table.name}_#{record.label},\n"
        end
      end
      io << "    }\n"
      io << "}\n\n"

      # Generate test functions from Rails test files
      Dir.glob(File.join(rails_test_dir, "*_test.rb")).sort.each do |path|
        basename = File.basename(path, "_test.rb")
        model_name = Inflector.classify(basename)
        ast = SourceParser.parse(path)
        emit_rust_test_functions(io, model_name, basename, ast)
      end

      File.write(File.join(tests_dir, "model_tests.rs"), io.to_s)
      puts "  tests/model_tests.rs"
    end

    private def emit_rust_test_functions(io : IO, model_name : String, basename : String,
                                          ast : Crystal::ASTNode)
      class_body = find_class_body(ast)
      return unless class_body

      exprs = case class_body
              when Crystal::Expressions then class_body.expressions
              else [class_body]
              end

      exprs.each do |expr|
        next unless expr.is_a?(Crystal::Call)
        call = expr.as(Crystal::Call)
        next unless call.name == "test" && call.args.size == 1 && call.block
        test_name = call.args[0].to_s.strip('"')
        rust_name = "test_" + test_name.downcase.gsub(" ", "_").gsub(/[^a-z0-9_]/, "")

        io << "#[test]\n"
        io << "fn #{rust_name}() {\n"
        io << "    setup_db();\n"
        io << "    let f = setup_fixtures();\n"
        io << "    let _ = &f;\n\n"

        emit_rust_test_body(call.block.not_nil!.body, io, model_name, basename)

        io << "}\n\n"
      end
    end

    private def emit_rust_test_body(node : Crystal::ASTNode, io : IO, model_name : String, basename : String)
      singular = Inflector.underscore(model_name)
      plural = Inflector.pluralize(singular)

      exprs = case node
              when Crystal::Expressions then node.expressions
              else [node]
              end

      exprs.each do |expr|
        case expr
        when Crystal::Assign
          emit_rust_test_assign(expr, io, model_name, singular, plural)
        when Crystal::Call
          emit_rust_test_call(expr, io, model_name, singular, plural)
        end
      end
    end

    private def emit_rust_test_assign(node : Crystal::Assign, io : IO, model_name : String,
                                       singular : String, plural : String)
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
        io << "    let #{var_name} = &f.#{func}_#{label};\n"
      elsif value.is_a?(Crystal::Call) && value.name == "new" && value.obj
        obj_name = value.obj.not_nil!.to_s
        attrs = rust_struct_attrs(value)
        io << "    let mut #{var_name} = #{obj_name} { #{attrs}, ..#{obj_name}::new() };\n"
      elsif value.is_a?(Crystal::Call) && value.name == "create" && value.obj.is_a?(Crystal::Call)
        parent_call = value.obj.as(Crystal::Call)
        if parent_call.obj
          parent_var = rust_expr(parent_call.obj.not_nil!)
          child_model = Inflector.classify(Inflector.singularize(parent_call.name))
          child_singular = Inflector.underscore(child_model)
          parent_singular = Inflector.underscore(parent_var)
          fk = "#{parent_singular}_id"
          attrs = rust_map_attrs(value)
          io << "    let #{var_name} = create_#{child_singular}(&HashMap::from([#{attrs}, (\"#{fk}\".to_string(), format!(\"{}\", #{parent_var}.id))])).unwrap();\n"
        end
      elsif value.is_a?(Crystal::Call) && value.name == "build" && value.obj.is_a?(Crystal::Call)
        parent_call = value.obj.as(Crystal::Call)
        if parent_call.obj
          parent_var = rust_expr(parent_call.obj.not_nil!)
          child_model = Inflector.classify(Inflector.singularize(parent_call.name))
          attrs = rust_struct_attrs(value)
          io << "    let mut #{var_name} = #{child_model} { #{attrs}, article_id: #{parent_var}.id, ..#{child_model}::new() };\n"
        end
      else
        io << "    // TODO: #{node}\n"
      end
    end

    private def emit_rust_test_call(node : Crystal::Call, io : IO, model_name : String,
                                     singular : String, plural : String)
      name = node.name
      args = node.args

      case name
      when "assert_not_nil"
        if args.size == 1
          io << "    assert!(#{rust_expr(args[0])} != 0, \"expected non-zero ID\");\n"
        end
      when "assert_equal"
        if args.size == 2
          expected = rust_expr(args[0])
          actual = rust_expr(args[1])
          io << "    assert_eq!(#{actual}, #{expected});\n"
        end
      when "assert_not"
        if args.size == 1 && args[0].is_a?(Crystal::Call) && args[0].as(Crystal::Call).name == "save"
          obj = args[0].as(Crystal::Call).obj
          obj_str = obj ? rust_expr(obj) : singular
          io << "    assert!(#{obj_str}.save().is_err(), \"expected save to fail\");\n"
        end
      when "assert_difference"
        if args.size >= 1 && node.block
          count_expr = args[0].to_s.strip('"')
          model = count_expr.split(".").first
          model_singular = Inflector.underscore(model)
          diff = args.size > 1 ? args[1].to_s.to_i : 1
          io << "    let before_count = #{model_singular}_count().unwrap();\n"
          emit_rust_test_body(node.block.not_nil!.body, io, model_name, singular)
          io << "    let after_count = #{model_singular}_count().unwrap();\n"
          if diff >= 0
            io << "    assert_eq!(after_count - before_count, #{diff}, \"expected count diff #{diff}\");\n"
          else
            io << "    assert_eq!(before_count - after_count, #{-diff}, \"expected count diff #{diff}\");\n"
          end
        end
      else
        if obj = node.obj
          obj_str = rust_expr(obj)
          if name == "destroy"
            io << "    #{obj_str}.destroy().unwrap();\n"
          end
        end
      end
    end

    private def rust_expr(node : Crystal::ASTNode) : String
      case node
      when Crystal::Var then node.name
      when Crystal::InstanceVar then node.name.lchop("@")
      when Crystal::Call
        # Fixture reference: articles(:one) → f.articles_one
        if !node.obj && node.args.size == 1 && node.args[0].is_a?(Crystal::SymbolLiteral)
          label = node.args[0].as(Crystal::SymbolLiteral).value
          return "f.#{node.name}_#{label}"
        end
        if node.obj
          obj_str = rust_expr(node.obj.not_nil!)
          "#{obj_str}.#{node.name}"
        else
          node.name
        end
      when Crystal::StringLiteral then "\"#{node.value}\""
      when Crystal::NumberLiteral then node.value.to_s.gsub(/_i64|_i32/, "")
      when Crystal::SymbolLiteral then "\"#{node.value}\""
      else node.to_s
      end
    end

    private def rust_struct_attrs(call : Crystal::Call) : String
      if named = call.named_args
        named.map do |na|
          value = case na.value
                  when Crystal::StringLiteral then "\"#{na.value.as(Crystal::StringLiteral).value}\".to_string()"
                  when Crystal::NumberLiteral then na.value.to_s.gsub(/_i64|_i32/, "")
                  else "\"#{na.value}\".to_string()"
                  end
          "#{na.name}: #{value}"
        end.join(", ")
      else
        ""
      end
    end

    private def rust_map_attrs(call : Crystal::Call) : String
      if named = call.named_args
        named.map do |na|
          value = case na.value
                  when Crystal::StringLiteral then "\"#{na.value.as(Crystal::StringLiteral).value}\".to_string()"
                  when Crystal::NumberLiteral then na.value.to_s + ".to_string()"
                  else "\"#{na.value}\".to_string()"
                  end
          "(\"#{na.name}\".to_string(), #{value})"
        end.join(", ")
      else
        ""
      end
    end

    private def find_class_body(ast : Crystal::ASTNode) : Crystal::ASTNode?
      case ast
      when Crystal::ClassDef
        return ast.body
      when Crystal::Expressions
        ast.expressions.each do |expr|
          result = find_class_body(expr)
          return result if result
        end
      end
      nil
    end
  end
end
