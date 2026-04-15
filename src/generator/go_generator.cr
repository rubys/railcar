# GoGenerator — orchestrates Go generation from Rails app via Crystal AST.
#
# Pipeline:
#   1. Build Crystal AST: runtime source + model ASTs (via filter chain)
#   2. program.semantic() → types on all nodes
#   3. Emit models via Cr2Go emitter, tests via Prism AST walking
#
# Target: net/http + database/sql + modernc.org/sqlite + html/template.

require "./app_model"
require "./schema_extractor"
require "./inflector"
require "./source_parser"
require "./fixture_loader"
require "../semantic"
require "../filters/model_boilerplate_python"
require "../filters/broadcasts_to"
require "../emitter/go/cr2go"

module Railcar
  class GoGenerator
    getter app : AppModel
    getter rails_dir : String

    def initialize(@app, @rails_dir)
    end

    def generate(output_dir : String)
      puts "Generating Go from #{rails_dir}..."
      Dir.mkdir_p(output_dir)

      app_name = app.name.downcase.gsub("-", "_")

      # Build model ASTs through shared filter chain
      model_asts = build_model_asts

      emit_go_mod(output_dir, app_name)
      emit_runtime(output_dir)
      emit_models(output_dir, app_name, model_asts)
      emit_model_tests(output_dir, app_name)

      puts "Done! Output in #{output_dir}/"
      puts "  cd #{output_dir} && go mod tidy && go test ./models/"
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

        # Same filter chain as Python/TypeScript
        ast = SourceParser.parse(source_path)
        ast = ast.transform(BroadcastsTo.new)
        ast = ast.transform(ModelBoilerplatePython.new(schema, model))

        asts[name] = ast
      end
      asts
    end

    # ── go.mod ──

    private def emit_go_mod(output_dir : String, app_name : String)
      File.write(File.join(output_dir, "go.mod"), <<-MOD)
      module #{app_name}

      go 1.21

      require modernc.org/sqlite v1.37.1
      MOD
      puts "  go.mod"
    end

    # ── Runtime ──

    private def emit_runtime(output_dir : String)
      runtime_src = File.join(File.dirname(__FILE__), "..", "runtime", "go", "railcar.go")
      Dir.mkdir_p(File.join(output_dir, "railcar"))
      File.copy(runtime_src, File.join(output_dir, "railcar", "railcar.go"))
      puts "  railcar/railcar.go"
    end

    # ── Models (AST-based) ──

    private def emit_models(output_dir : String, app_name : String, model_asts : Hash(String, Crystal::ASTNode))
      models_dir = File.join(output_dir, "models")
      Dir.mkdir_p(models_dir)

      schema_map = {} of String => TableSchema
      app.schemas.each { |s| schema_map[s.name] = s }

      emitter = Cr2Go::Emitter.new

      model_asts.each do |name, ast|
        next unless ast.is_a?(Crystal::ClassDef)
        table_name = Inflector.pluralize(Inflector.underscore(name))
        schema = schema_map[table_name]?
        next unless schema

        source = emitter.emit_model(ast.as(Crystal::ClassDef), name, schema, app_name)
        singular = Inflector.underscore(name)

        File.write(File.join(models_dir, "#{singular}.go"), source)
        puts "  models/#{singular}.go"
      end
    end

    # ── Model tests ──

    private def emit_model_tests(output_dir : String, app_name : String)
      rails_test_dir = File.join(rails_dir, "test/models")
      return unless Dir.exists?(rails_test_dir)

      models_dir = File.join(output_dir, "models")
      Dir.mkdir_p(models_dir)

      emit_test_helper(models_dir, app_name)

      Dir.glob(File.join(rails_test_dir, "*_test.rb")).sort.each do |path|
        basename = File.basename(path, "_test.rb")
        model_name = Inflector.classify(basename)

        ast = SourceParser.parse(path)
        emit_model_test_file(models_dir, app_name, model_name, basename, ast)
      end
    end

    private def emit_test_helper(models_dir : String, app_name : String)
      io = IO::Memory.new
      io << "package models\n\n"
      io << "import (\n"
      io << "\t\"database/sql\"\n"
      io << "\t\"testing\"\n"
      io << "\t\"#{app_name}/railcar\"\n"
      io << "\t_ \"modernc.org/sqlite\"\n"
      io << ")\n\n"

      io << "func setupTestDB(t *testing.T) *sql.DB {\n"
      io << "\tt.Helper()\n"
      io << "\tdb, err := sql.Open(\"sqlite\", \":memory:\")\n"
      io << "\tif err != nil { t.Fatal(err) }\n"
      io << "\tdb.Exec(\"PRAGMA foreign_keys = ON\")\n"

      app.schemas.each do |schema|
        all_cols = [{name: "id", type: "INTEGER"}]
        schema.columns.each { |c| all_cols << {name: c.name, type: c.type} }
        col_defs = all_cols.map do |c|
          parts = "#{c[:name]} #{c[:type]}"
          parts += " PRIMARY KEY AUTOINCREMENT" if c[:name] == "id"
          parts += " NOT NULL" unless c[:name] == "id"
          parts
        end
        io << "\tdb.Exec(`CREATE TABLE #{schema.name} (\n"
        io << "\t\t#{col_defs.join(",\n\t\t")}\n"
        io << "\t)`)\n"
      end

      io << "\trailcar.DB = db\n"
      io << "\treturn db\n"
      io << "}\n\n"

      # Fixtures struct and setup
      sorted_fixtures = FixtureLoader.sort_by_dependency(app.fixtures, app.models)

      io << "type fixtures struct {\n"
      sorted_fixtures.each do |table|
        singular = Inflector.singularize(table.name)
        model_name = Inflector.classify(singular)
        next unless app.models.has_key?(model_name)
        table.records.each do |record|
          io << "\t#{table.name}_#{record.label} *#{model_name}\n"
        end
      end
      io << "}\n\n"

      io << "func setupFixtures(t *testing.T) *fixtures {\n"
      io << "\tt.Helper()\n"
      io << "\tf := &fixtures{}\n"

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
              attrs << "\"#{field}_id\": f.#{ref_table}_#{value}.Id"
            else
              if value.match(/^\d+$/)
                attrs << "\"#{field}\": int64(#{value})"
              else
                attrs << "\"#{field}\": #{value.inspect}"
              end
            end
          end

          var_name = "#{table.name}_#{record.label}"
          io << "\tf.#{var_name}, _ = Create#{model_name}(map[string]any{#{attrs.join(", ")}})\n"
        end
      end

      io << "\treturn f\n"
      io << "}\n"

      File.write(File.join(models_dir, "test_helper_test.go"), io.to_s)
      puts "  models/test_helper_test.go"
    end

    private def emit_model_test_file(models_dir : String, app_name : String, model_name : String,
                                      basename : String, ast : Crystal::ASTNode)
      io = IO::Memory.new
      io << "package models\n\n"
      io << "import \"testing\"\n\n"

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
        go_name = "Test" + test_name.split(" ").map(&.capitalize).join("")

        io << "func #{go_name}(t *testing.T) {\n"
        io << "\tdb := setupTestDB(t)\n"
        io << "\tdefer db.Close()\n"
        io << "\tf := setupFixtures(t)\n"
        io << "\t_ = f\n\n"

        emit_go_test_body(call.block.not_nil!.body, io, model_name, basename)

        io << "}\n\n"
      end

      out_path = File.join(models_dir, "#{basename}_test.go")
      File.write(out_path, io.to_s)
      puts "  models/#{basename}_test.go"
    end

    private def emit_go_test_body(node : Crystal::ASTNode, io : IO, model_name : String, basename : String)
      singular = Inflector.underscore(model_name)
      plural = Inflector.pluralize(singular)

      exprs = case node
              when Crystal::Expressions then node.expressions
              else [node]
              end

      exprs.each do |expr|
        case expr
        when Crystal::Assign
          emit_go_test_assign(expr, io, model_name, singular, plural)
        when Crystal::Call
          emit_go_test_call(expr, io, model_name, singular, plural)
        end
      end
    end

    private def emit_go_test_assign(node : Crystal::Assign, io : IO, model_name : String,
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
        io << "\t#{var_name} := f.#{func}_#{label}\n"
      elsif value.is_a?(Crystal::Call) && value.name == "new" && value.obj
        obj_name = value.obj.not_nil!.to_s
        attrs = go_struct_attrs(value)
        io << "\t#{var_name} := &#{obj_name}{#{attrs}}\n"
      elsif value.is_a?(Crystal::Call) && value.name == "create" && value.obj.is_a?(Crystal::Call)
        parent_call = value.obj.as(Crystal::Call)
        if parent_call.obj
          parent_var = go_expr(parent_call.obj.not_nil!)
          child_model = Inflector.classify(Inflector.singularize(parent_call.name))
          parent_singular = Inflector.underscore(parent_var)
          fk = "#{parent_singular}_id"
          attrs = go_map_attrs(value)
          io << "\t#{var_name}, _ := Create#{child_model}(map[string]any{#{attrs}, #{fk.inspect}: #{parent_var}.Id})\n"
        end
      elsif value.is_a?(Crystal::Call) && value.name == "build" && value.obj.is_a?(Crystal::Call)
        parent_call = value.obj.as(Crystal::Call)
        if parent_call.obj
          parent_var = go_expr(parent_call.obj.not_nil!)
          child_model = Inflector.classify(Inflector.singularize(parent_call.name))
          parent_singular = Inflector.underscore(parent_var)
          fk = go_field_name("#{parent_singular}_id")
          attrs = go_struct_attrs(value)
          attrs_with_fk = attrs.empty? ? "#{fk}: #{parent_var}.Id" : "#{attrs}, #{fk}: #{parent_var}.Id"
          io << "\t#{var_name} := &#{child_model}{#{attrs_with_fk}}\n"
        end
      else
        io << "\t// TODO: #{node}\n"
      end
    end

    private def emit_go_test_call(node : Crystal::Call, io : IO, model_name : String,
                                   singular : String, plural : String)
      name = node.name
      args = node.args

      case name
      when "assert_not_nil"
        if args.size == 1
          io << "\tif #{go_expr(args[0])} == 0 { t.Error(\"expected non-zero ID\") }\n"
        end
      when "assert_equal"
        if args.size == 2
          expected = go_expr(args[0])
          actual = go_expr(args[1])
          io << "\tif #{actual} != #{expected} { t.Errorf(\"expected %v, got %v\", #{expected}, #{actual}) }\n"
        end
      when "assert_not"
        if args.size == 1 && args[0].is_a?(Crystal::Call) && args[0].as(Crystal::Call).name == "save"
          obj = args[0].as(Crystal::Call).obj
          obj_str = obj ? go_expr(obj) : singular
          io << "\tif err := #{obj_str}.Save(); err == nil { t.Error(\"expected save to fail\") }\n"
        end
      when "assert_difference"
        if args.size >= 1 && node.block
          count_expr = args[0].to_s.strip('"')
          model = count_expr.split(".").first
          diff = args.size > 1 ? args[1].to_s.to_i : 1
          io << "\tbeforeCount, _ := #{model}Count()\n"
          emit_go_test_body(node.block.not_nil!.body, io, model_name, singular)
          io << "\tafterCount, _ := #{model}Count()\n"
          io << "\tif afterCount - beforeCount != #{diff} { t.Errorf(\"expected count diff %d, got %d\", #{diff}, afterCount - beforeCount) }\n"
        end
      else
        if obj = node.obj
          obj_str = obj.to_s.lchop("@")
          if name == "destroy"
            io << "\t#{obj_str}.Delete()\n"
          end
        end
      end
    end

    # ── Helpers ──

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

    private def go_field_name(name : String) : String
      name.split("_").map(&.capitalize).join("")
    end

    private def go_expr(node : Crystal::ASTNode) : String
      case node
      when Crystal::StringLiteral then node.value.inspect
      when Crystal::NumberLiteral then "int64(#{node.value.to_s.gsub(/_i64|_i32/, "")})"
      when Crystal::InstanceVar then node.name.lchop("@")
      when Crystal::Var then node.name
      when Crystal::Call
        obj = node.obj
        if obj
          obj_str = go_expr(obj)
          field = go_field_name(node.name)
          if node.args.empty? && !node.block
            "#{obj_str}.#{field}"
          elsif node.args.size == 1 && node.args[0].is_a?(Crystal::SymbolLiteral)
            label = node.args[0].as(Crystal::SymbolLiteral).value
            "f.#{node.name}_#{label}"
          else
            "#{obj_str}.#{field}"
          end
        else
          if node.args.size == 1 && node.args[0].is_a?(Crystal::SymbolLiteral)
            label = node.args[0].as(Crystal::SymbolLiteral).value
            "f.#{node.name}_#{label}"
          else
            node.name
          end
        end
      when Crystal::NilLiteral then "nil"
      else node.to_s.gsub("@", "")
      end
    end

    private def go_struct_attrs(call : Crystal::Call) : String
      if named = call.named_args
        return named.map { |na| "#{go_field_name(na.name)}: #{go_value(na.value)}" }.join(", ")
      end
      call.args.each do |arg|
        case arg
        when Crystal::NamedTupleLiteral
          return arg.entries.map { |e| "#{go_field_name(e.key)}: #{go_value(e.value)}" }.join(", ")
        when Crystal::HashLiteral
          return arg.entries.map do |e|
            key = case e.key
                  when Crystal::SymbolLiteral then e.key.as(Crystal::SymbolLiteral).value
                  when Crystal::StringLiteral then e.key.as(Crystal::StringLiteral).value
                  else e.key.to_s
                  end
            "#{go_field_name(key)}: #{go_value(e.value)}"
          end.join(", ")
        end
      end
      ""
    end

    private def go_map_attrs(call : Crystal::Call) : String
      if named = call.named_args
        return named.map { |na| "#{na.name.inspect}: #{go_value(na.value)}" }.join(", ")
      end
      call.args.each do |arg|
        case arg
        when Crystal::NamedTupleLiteral
          return arg.entries.map { |e| "#{e.key.inspect}: #{go_value(e.value)}" }.join(", ")
        when Crystal::HashLiteral
          return arg.entries.map do |e|
            key = case e.key
                  when Crystal::SymbolLiteral then e.key.as(Crystal::SymbolLiteral).value
                  when Crystal::StringLiteral then e.key.as(Crystal::StringLiteral).value
                  else e.key.to_s
                  end
            "#{key.inspect}: #{go_value(e.value)}"
          end.join(", ")
        end
      end
      ""
    end

    private def go_value(node : Crystal::ASTNode) : String
      case node
      when Crystal::StringLiteral then node.value.inspect
      when Crystal::NumberLiteral then "int64(#{node.value.to_s.gsub(/_i64|_i32/, "")})"
      when Crystal::BoolLiteral then node.value.to_s
      when Crystal::NilLiteral then "nil"
      else node.to_s
      end
    end
  end
end
