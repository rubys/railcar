# Generates TypeScript test files from Rails Minitest source.
#
# Produces:
#   tests/setup.ts — DB setup, fixtures, cleanup
#   tests/*.test.ts — Model tests using node:test + node:assert

require "./inflector"
require "./fixture_loader"

module Railcar
  class TypeScriptTestGenerator
    getter app : AppModel
    getter rails_dir : String

    def initialize(@app, @rails_dir)
    end

    def generate(output_dir : String)
      tests_dir = File.join(output_dir, "tests")
      Dir.mkdir_p(tests_dir)

      emit_test_setup(tests_dir)
      emit_model_tests(tests_dir)
    end

    private def emit_test_setup(tests_dir : String)
      io = IO::Memory.new
      io << "import Database from \"better-sqlite3\";\n"
      io << "import { ApplicationRecord } from \"../runtime/base.js\";\n"

      app.models.each_key do |name|
        io << "import { #{name} } from \"../models/#{Inflector.underscore(name)}.js\";\n"
      end
      io << "\n"

      # Setup function
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
          attrs = [] of String
          record.fields.each do |field, value|
            model_info = app.models[model_name]?
            assoc = model_info.try(&.associations.find { |a| a.name == field })
            if assoc && assoc.kind == :belongs_to
              ref_table = Inflector.pluralize(field)
              attrs << "#{field}_id: #{ref_table}_#{value}.id!"
            else
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
          io << "export let #{table.name}_#{record.label}: ApplicationRecord;\n"
        end
      end
      io << "\n"

      # Fixture accessor functions
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

      fixture_funcs = Set(String).new
      fixture_funcs << table_name
      app.fixtures.each do |ft|
        fixture_funcs << ft.name if source.includes?("#{ft.name}(:")
      end
      io << "import { setupDb, setupFixtures, #{fixture_funcs.join(", ")} } from \"./setup.js\";\n"

      io << "import { #{model_name} } from \"../models/#{basename}.js\";\n"
      app.models.each_key do |name|
        next if name == model_name
        io << "import { #{name} } from \"../models/#{Inflector.underscore(name)}.js\";\n" if source.includes?(name)
      end
      io << "import type Database from \"better-sqlite3\";\n\n"

      io << "let db: Database.Database;\n\n"
      io << "beforeEach(() => {\n"
      io << "  db = setupDb();\n"
      io << "  setupFixtures();\n"
      io << "});\n\n"
      io << "afterEach(() => {\n"
      io << "  db.close();\n"
      io << "});\n\n"

      io << "describe(\"#{model_name}\", () => {\n"

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
          io << "    const #{$1} = #{$2}(#{$3.inspect});\n"
        when /^assert_not_nil\s+(\w+)\.(\w+)$/
          io << "    assert.notStrictEqual(#{$1}.#{$2}, null);\n"
        when /^assert_equal\s+"([^"]+)",\s*(\w+)\.(\w+)$/
          io << "    assert.strictEqual((#{$2} as any).#{$3}, #{$1.inspect});\n"
        when /^assert_equal\s+(\w+)\(:(\w+)\)\.(\w+),\s*(\w+)\.(\w+)$/
          io << "    assert.strictEqual((#{$4} as any).#{$5}, #{$1}(#{$2.inspect}).#{$3});\n"
        when /^(\w+)\s*=\s*(\w+)\.new\((.+)\)$/
          attrs = convert_ruby_hash($3)
          io << "    const #{$1} = new #{$2}({ #{attrs} });\n"
        when /^assert_not\s+(\w+)\.(\w+)$/
          ts_method = ts_method_name($2)
          io << "    assert.strictEqual(#{$1}.#{ts_method}(), false);\n"
        when /^assert_equal\s+(\w+)\.(\w+),\s*(\w+)\.(\w+)$/
          io << "    assert.strictEqual((#{$3} as any).#{$4}, (#{$1} as any).#{$2});\n"
        when /^(\w+)\s*=\s*(\w+)\.(\w+)\.create\((.+)\)$/
          attrs = convert_ruby_hash($4)
          ts_assoc = ts_method_name($3)
          io << "    const #{$1} = (#{$2} as any).#{ts_assoc}().create({ #{attrs} });\n"
        when /^(\w+)\s*=\s*(\w+)\.(\w+)\.build\((.+)\)$/
          attrs = convert_ruby_hash($4)
          ts_assoc = ts_method_name($3)
          io << "    const #{$1} = (#{$2} as any).#{ts_assoc}().build({ #{attrs} });\n"
        when /^assert_difference\("(\w+)\.count",\s*(-?\d+)\)\s+do$/
          io << "    const _before = #{$1}.count();\n"
        when /^(\w+)\.destroy$/
          io << "    #{$1}.destroy();\n"
        when /^end$/
          # closing assert_difference block — handled in post-processing
        else
          io << "    // TODO: #{stripped}\n"
        end
      end

      result = io.to_s
      if result.includes?("_before = ")
        if result =~ /const _before = (\w+)\.count\(\);/
          model = $1
          result = result.rstrip
          if body =~ /assert_difference\("\w+\.count",\s*(-?\d+)\)/
            result += "\n    assert.strictEqual(#{model}.count() - _before, #{$1});\n"
          else
            result += "\n    assert.strictEqual(#{model}.count() - _before, -1);\n"
          end
        end
      end

      result
    end

    private def convert_ruby_hash(ruby : String) : String
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
  end
end
