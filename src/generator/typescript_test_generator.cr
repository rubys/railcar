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
      emit_controller_tests(tests_dir)
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

      # Export fixture variables — typed to specific model classes
      sorted_fixtures.each do |table|
        singular = Inflector.singularize(table.name)
        model_name = Inflector.classify(singular)
        type = app.models.has_key?(model_name) ? model_name : "ApplicationRecord"
        table.records.each do |record|
          io << "export let #{table.name}_#{record.label}: #{type};\n"
        end
      end
      io << "\n"

      # Fixture accessor functions — return specific model types
      app.models.each_key do |name|
        table_name = Inflector.pluralize(Inflector.underscore(name))
        fixture_table = app.fixtures.find { |t| t.name == table_name }
        next unless fixture_table

        io << "export function #{table_name}(name: string): #{name} {\n"
        fixture_table.records.each_with_index do |record, i|
          keyword = i == 0 ? "if" : "} else if"
          io << "  #{keyword} (name === #{record.label.inspect}) {\n"
          io << "    return #{name}.find(#{table_name}_#{record.label}.id!);\n"
        end
        io << "  }\n"
        io << "  throw new Error(`Unknown fixture: ${name}`);\n"
        io << "}\n\n"
      end

      # Re-export encodeParams for controller tests
      io << "export { encodeParams } from \"../helpers.js\";\n\n"

      # createTestApp — builds Express app for supertest
      io << "import express from \"express\";\n"
      io << "import ejs from \"ejs\";\n"
      io << "import fs from \"fs\";\n"
      io << "import path from \"path\";\n"
      io << "import { fileURLToPath } from \"url\";\n"
      io << "import * as helpers from \"../helpers.js\";\n"
      io << "const __dirname = path.dirname(fileURLToPath(import.meta.url));\n"
      app.controllers.each do |info|
        name = Inflector.underscore(info.name).chomp("_controller")
        io << "import * as #{name}Controller from \"../controllers/#{name}.js\";\n"
      end
      io << "\n"

      io << "export function createTestApp(): express.Application {\n"
      # Wire broadcast partials
      io << "  // Wire broadcast partials (using EJS)\n"
      io << "  const viewsDir = path.join(__dirname, \"..\", \"views\");\n"
      app.models.each_key do |name|
        singular = Inflector.underscore(name)
        plural = Inflector.pluralize(singular)
        io << "  #{name}.renderPartial = (record: any) => {\n"
        io << "    const tmpl = fs.readFileSync(path.join(viewsDir, \"#{plural}/_#{singular}.ejs\"), \"utf-8\");\n"
        io << "    return ejs.render(tmpl, { #{singular}: record, helpers }, { filename: path.join(viewsDir, \"#{plural}/_#{singular}.ejs\") });\n"
        io << "  };\n"
      end
      io << "  const app = express();\n"
      io << "  app.use(express.urlencoded({ extended: true }));\n\n"

      # Routes — same as app.ts
      routes_by_path = {} of String => Hash(String, {String, String})
      app.routes.routes.each do |route|
        routes_by_path[route.path] ||= {} of String => {String, String}
        routes_by_path[route.path][route.method.upcase] = {route.controller, route.action}
      end

      routes_by_path.each do |route_path, methods|
        if get = methods["GET"]?
          action = get[1] == "new" ? "newAction" : get[1]
          io << "  app.get(\"#{route_path}\", #{get[0]}Controller.#{action});\n"
        end

        has_dispatch = methods.has_key?("PATCH") || methods.has_key?("PUT") || methods.has_key?("DELETE")
        if post = methods["POST"]?
          if has_dispatch
            io << "  app.post(\"#{route_path}\", (req, res) => {\n"
            io << "    const data = req.body ?? {};\n"
            io << "    const method = (data._method ?? \"POST\").toString().toUpperCase();\n"
            if del = methods["DELETE"]?
              io << "    if (method === \"DELETE\") return #{del[0]}Controller.destroy(req, res, data);\n"
            end
            if patch = (methods["PATCH"]? || methods["PUT"]?)
              io << "    if (method === \"PATCH\" || method === \"PUT\") return #{patch[0]}Controller.update(req, res, data);\n"
            end
            io << "    #{post[0]}Controller.#{post[1]}(req, res, data);\n"
            io << "  });\n"
          else
            io << "  app.post(\"#{route_path}\", (req, res) => #{post[0]}Controller.#{post[1]}(req, res));\n"
          end
        elsif has_dispatch
          io << "  app.post(\"#{route_path}\", (req, res) => {\n"
          io << "    const data = req.body ?? {};\n"
          io << "    const method = (data._method ?? \"POST\").toString().toUpperCase();\n"
          if del = methods["DELETE"]?
            io << "    if (method === \"DELETE\") return #{del[0]}Controller.destroy(req, res, data);\n"
          end
          if patch = (methods["PATCH"]? || methods["PUT"]?)
            io << "    if (method === \"PATCH\" || method === \"PUT\") return #{patch[0]}Controller.update(req, res, data);\n"
          end
          io << "    res.status(404).send(\"Not found\");\n"
          io << "  });\n"
        end
      end

      if root_ctrl = app.routes.root_controller
        root_action = app.routes.root_action || "index"
        io << "  app.get(\"/\", #{root_ctrl}Controller.#{root_action});\n"
      end

      # Error handler — surfaces EJS/controller errors in test output
      io << "  app.use((err: Error, _req: express.Request, res: express.Response, _next: express.NextFunction) => {\n"
      io << "    console.error(err.message);\n"
      io << "    res.status(500).send(err.message);\n"
      io << "  });\n"
      io << "  return app;\n"
      io << "}\n"

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
          io << "    assert.strictEqual(#{$2}.#{$3}, #{$1.inspect});\n"
        when /^assert_equal\s+(\w+)\(:(\w+)\)\.(\w+),\s*(\w+)\.(\w+)$/
          io << "    assert.strictEqual(#{$4}.#{$5}, #{$1}(#{$2.inspect}).#{$3});\n"
        when /^(\w+)\s*=\s*(\w+)\.new\((.+)\)$/
          attrs = convert_ruby_hash($3)
          io << "    const #{$1} = new #{$2}({ #{attrs} });\n"
        when /^assert_not\s+(\w+)\.(\w+)$/
          ts_method = ts_method_name($2)
          io << "    assert.strictEqual(#{$1}.#{ts_method}(), false);\n"
        when /^assert_equal\s+(\w+)\.(\w+),\s*(\w+)\.(\w+)$/
          io << "    assert.strictEqual(#{$3}.#{$4}, #{$1}.#{$2});\n"
        when /^(\w+)\s*=\s*(\w+)\.(\w+)\.create\((.+)\)$/
          attrs = convert_ruby_hash($4)
          ts_assoc = ts_method_name($3)
          io << "    const #{$1} = #{$2}.#{ts_assoc}().create({ #{attrs} });\n"
        when /^(\w+)\s*=\s*(\w+)\.(\w+)\.build\((.+)\)$/
          attrs = convert_ruby_hash($4)
          ts_assoc = ts_method_name($3)
          io << "    const #{$1} = #{$2}.#{ts_assoc}().build({ #{attrs} });\n"
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

    private def emit_controller_tests(tests_dir : String)
      test_dir = File.join(rails_dir, "test/controllers")
      return unless Dir.exists?(test_dir)

      Dir.glob(File.join(test_dir, "*_test.rb")).sort.each do |path|
        basename = File.basename(path, "_test.rb")
        controller_name = basename.chomp("_controller")
        model_name = Inflector.classify(Inflector.singularize(controller_name))

        ts_source = convert_controller_test(path, controller_name, model_name)
        next if ts_source.empty?

        out_path = File.join(tests_dir, "#{controller_name}.test.ts")
        File.write(out_path, ts_source)
        puts "  tests/#{controller_name}.test.ts"
      end
    end

    private def convert_controller_test(path : String, controller_name : String, model_name : String) : String
      singular = Inflector.singularize(controller_name)
      plural = Inflector.pluralize(controller_name)
      source = File.read(path)

      # Parse through Prism for proper AST handling of nested blocks
      ast = SourceParser.parse(path)

      io = IO::Memory.new
      io << "import { describe, it, beforeEach, afterEach } from \"node:test\";\n"
      io << "import assert from \"node:assert/strict\";\n"
      io << "import request from \"supertest\";\n"
      io << "import { setupDb, setupFixtures, createTestApp, encodeParams"

      fixture_funcs = Set(String).new
      app.fixtures.each do |ft|
        fixture_funcs << ft.name if source.includes?("#{ft.name}(:")
      end
      fixture_funcs.each { |f| io << ", #{f}" }
      io << " } from \"./setup.js\";\n"

      io << "import { #{model_name} } from \"../models/#{Inflector.underscore(model_name)}.js\";\n"
      app.models.each_key do |name|
        next if name == model_name
        io << "import { #{name} } from \"../models/#{Inflector.underscore(name)}.js\";\n" if source.includes?(name)
      end
      io << "import * as helpers from \"../helpers.js\";\n"
      io << "import type Database from \"better-sqlite3\";\n"
      io << "import type express from \"express\";\n\n"

      io << "let db: Database.Database;\n"
      io << "let app: express.Application;\n\n"

      io << "beforeEach(() => {\n"
      io << "  db = setupDb();\n"
      io << "  setupFixtures();\n"
      io << "  app = createTestApp();\n"
      io << "});\n\n"
      io << "afterEach(() => {\n"
      io << "  db.close();\n"
      io << "});\n\n"

      io << "describe(\"#{model_name}Controller\", () => {\n"

      # Walk AST to find test method calls with blocks
      class_body = find_class_body(ast)
      if class_body
        emit_test_methods(class_body, io, singular, plural, model_name)
      end

      io << "});\n"
      io.to_s
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

    private def emit_test_methods(body : Crystal::ASTNode, io : IO, singular : String, plural : String, model_name : String)
      exprs = case body
              when Crystal::Expressions then body.expressions
              else [body]
              end

      # Find setup block and extract its body as preamble for each test
      setup_stmts = IO::Memory.new
      exprs.each do |expr|
        if expr.is_a?(Crystal::Call) && expr.as(Crystal::Call).name == "setup" && expr.as(Crystal::Call).block
          emit_test_body(expr.as(Crystal::Call).block.not_nil!.body, setup_stmts, singular, plural, model_name)
        end
      end
      setup_code = setup_stmts.to_s

      exprs.each do |expr|
        next unless expr.is_a?(Crystal::Call)
        call = expr.as(Crystal::Call)
        next unless call.name == "test" && call.args.size == 1 && call.block
        test_name = call.args[0].to_s.strip('"')
        block_body = call.block.not_nil!.body

        io << "  it(#{test_name.inspect}, async () => {\n"
        io << setup_code unless setup_code.empty?
        begin
          emit_test_body(block_body, io, singular, plural, model_name)
        rescue ex
          STDERR.puts "  WARN: test #{test_name.inspect}: #{ex.message}"
          io << "    // ERROR: #{ex.message}\n"
        end
        io << "  });\n\n"
      end
    end

    private def emit_test_body(node : Crystal::ASTNode, io : IO, singular : String, plural : String, model_name : String)
      exprs = case node
              when Crystal::Expressions then node.expressions
              else [node]
              end

      exprs.each do |expr|
        emit_test_stmt(expr, io, singular, plural, model_name)
      end
    end

    private def emit_test_stmt(node : Crystal::ASTNode, io : IO, singular : String, plural : String, model_name : String)
      case node
      when Crystal::Assign
        emit_test_assign(node, io, singular, plural)

      when Crystal::Call
        emit_test_call(node, io, singular, plural, model_name)

      when Crystal::Nop
        # skip

      else
        io << "    // TODO: #{node.class.name}\n"
      end
    end

    private def emit_test_assign(node : Crystal::Assign, io : IO, singular : String, plural : String)
      target = node.target
      value = node.value
      var_name = case target
                 when Crystal::InstanceVar then target.name.lchop("@")
                 when Crystal::Var then target.name
                 else target.to_s
                 end

      if value.is_a?(Crystal::Call) && value.args.size == 1 && value.args[0].is_a?(Crystal::SymbolLiteral)
        # @article = articles(:one) → let article = articles("one") (let for potential reload)
        func = value.name
        label = value.args[0].as(Crystal::SymbolLiteral).value
        io << "    let #{var_name} = #{func}(#{label.inspect});\n"
      else
        io << "    const #{var_name} = #{test_expr(value, singular, plural)};\n"
      end
    end

    private def emit_test_call(node : Crystal::Call, io : IO, singular : String, plural : String, model_name : String)
      name = node.name
      args = node.args

      case name
      when "get"
        path = url_expr(args[0], singular, plural)
        io << "    const response = await request(app).get(#{path});\n"

      when "post"
        path = url_expr(args[0], singular, plural)
        params = extract_params(node, singular)
        io << "    const response = await request(app).post(#{path})\n"
        io << "      .type(\"form\")\n"
        io << "      .send(#{params})\n"
        io << "      .redirects(0);\n"

      when "patch"
        path = url_expr(args[0], singular, plural)
        params = extract_params(node, singular)
        io << "    const response = await request(app).post(#{path})\n"
        io << "      .type(\"form\")\n"
        io << "      .send(#{params} + \"&_method=patch\")\n"
        io << "      .redirects(0);\n"

      when "delete"
        path = url_expr(args[0], singular, plural)
        io << "    const response = await request(app).post(#{path})\n"
        io << "      .type(\"form\")\n"
        io << "      .send(\"_method=delete\")\n"
        io << "      .redirects(0);\n"

      when "assert_response"
        status = args[0].to_s.strip(':')
        case status
        when "success"           then io << "    assert.strictEqual(response.status, 200);\n"
        when "unprocessable_entity" then io << "    assert.strictEqual(response.status, 422);\n"
        else io << "    // TODO: assert_response #{status}\n"
        end

      when "assert_redirected_to"
        io << "    assert.ok([301, 302, 303].includes(response.status));\n"

      when "assert_select"
        emit_assert_select(node, io)

      when "assert_equal"
        emit_assert_equal(node, io, singular, plural, model_name)

      when "assert_difference", "assert_no_difference"
        emit_assert_difference(node, io, singular, plural, model_name, positive: name == "assert_difference")

      when "reload"
        if obj = node.obj
          var = obj.to_s.lchop("@")
          cls = Inflector.classify(var)
          io << "    #{var} = #{cls}.find(#{var}.id!);\n"
        end

      else
        # Instance method calls like @article.reload
        if node.obj
          obj_str = node.obj.not_nil!.to_s
          if obj_str.starts_with?("@") && name == "reload"
            var = obj_str.lchop("@")
            cls = Inflector.classify(var)
            io << "    #{var} = #{cls}.find(#{var}.id!);\n"
            return
          end
        end
        io << "    // TODO: #{name}\n"
      end
    end

    private def emit_assert_select(node : Crystal::Call, io : IO)
      args = node.args
      if args.size >= 2 && args[1].is_a?(Crystal::StringLiteral)
        text = args[1].as(Crystal::StringLiteral).value
        io << "    assert.ok(response.text.includes(#{text.inspect}));\n"
      elsif args.size >= 1
        selector = args[0].to_s.strip('"')
        if selector.starts_with?("#")
          # Extract just the id part (before any space/descendant selector)
          id = selector.lchop("#").split(" ").first
          io << "    assert.ok(response.text.includes('id=\"#{id}\"'));\n"
        else
          io << "    assert.ok(response.text.includes(\"<#{selector}\"));\n"
        end
      end

      # Handle block (assert_select "#articles" do ... end)
      if node.block
        # Just emit the outer assertion, skip inner assertions
      end
    end

    private def emit_assert_equal(node : Crystal::Call, io : IO, singular : String, plural : String, model_name : String)
      args = node.args
      return if args.size < 2

      expected = test_expr(args[0], singular, plural)
      actual = test_expr(args[1], singular, plural)
      io << "    assert.strictEqual(#{actual}, #{expected});\n"
    end

    private def emit_assert_difference(node : Crystal::Call, io : IO, singular : String, plural : String,
                                        model_name : String, positive : Bool)
      args = node.args
      # Extract model.count expression
      count_expr = args[0].to_s.strip('"')  # "Article.count"
      model = count_expr.split(".").first

      diff = if args.size > 1
               args[1].to_s.to_i
             elsif positive
               1
             else
               0
             end

      io << "    const _before = #{model}.count();\n"

      # Emit block body
      if block = node.block
        emit_test_body(block.body, io, singular, plural, model_name)
      end

      if positive
        io << "    assert.strictEqual(#{model}.count() - _before, #{diff});\n"
      else
        io << "    assert.strictEqual(#{model}.count(), _before);\n"
      end
    end

    private def url_expr(node : Crystal::ASTNode, singular : String, plural : String) : String
      case node
      when Crystal::Call
        # articles_url → helpers.articlesPath()
        # article_url(@article) → helpers.articlePath(article)
        url_name = node.name.chomp("_url")
        ts_name = url_name.gsub(/_([a-z])/) { |_, m| m[1].upcase }
        if node.args.empty?
          "helpers.#{ts_name}Path()"
        else
          args = node.args.map { |a|
            case a
            when Crystal::InstanceVar then a.name.lchop("@")
            when Crystal::Var then a.name
            else a.to_s.lchop("@")
            end
          }
          "helpers.#{ts_name}Path(#{args.join(", ")})"
        end
      else
        node.to_s.inspect
      end
    end

    private def extract_params(node : Crystal::Call, singular : String) : String
      if named = node.named_args
        params_arg = named.find { |na| na.name == "params" }
        if params_arg
          return "encodeParams(#{hash_to_js(params_arg.value, singular)})"
        end
      end
      "\"\""
    end

    private def hash_to_js(node : Crystal::ASTNode, singular : String) : String
      case node
      when Crystal::HashLiteral
        entries = node.entries.map do |entry|
          key = case entry.key
                when Crystal::SymbolLiteral then entry.key.as(Crystal::SymbolLiteral).value
                when Crystal::StringLiteral then entry.key.as(Crystal::StringLiteral).value
                else entry.key.to_s
                end
          "#{key}: #{hash_to_js(entry.value, singular)}"
        end
        "{ #{entries.join(", ")} }"
      when Crystal::NamedTupleLiteral
        entries = node.entries.map { |e| "#{e.key}: #{hash_to_js(e.value, singular)}" }
        "{ #{entries.join(", ")} }"
      when Crystal::StringLiteral
        node.value.inspect
      when Crystal::NumberLiteral
        node.value.to_s
      when Crystal::Call
        # @article.body → article.body
        if obj = node.obj
          "#{test_expr(obj, singular, "")}.#{node.name}"
        else
          node.name
        end
      when Crystal::InstanceVar
        node.name.lchop("@") + "." + node.name.lchop("@")  # shouldn't happen standalone
      else
        node.to_s.gsub("@", "")
      end
    end

    private def test_expr(node : Crystal::ASTNode, singular : String, plural : String) : String
      case node
      when Crystal::StringLiteral then node.value.inspect
      when Crystal::NumberLiteral then node.value.to_s.gsub(/_i64|_i32/, "")
      when Crystal::SymbolLiteral then node.value.inspect
      when Crystal::NilLiteral then "null"
      when Crystal::BoolLiteral then node.value.to_s
      when Crystal::InstanceVar then node.name.lchop("@")
      when Crystal::Var then node.name
      when Crystal::Call
        obj = node.obj
        if obj
          obj_str = test_expr(obj, singular, plural)
          if node.name == "last"
            "#{obj_str}.last()!"
          else
            "#{obj_str}.#{node.name}"
          end
        else
          if node.args.size == 1 && node.args[0].is_a?(Crystal::SymbolLiteral)
            label = node.args[0].as(Crystal::SymbolLiteral).value
            "#{node.name}(#{label.inspect})"
          else
            node.name
          end
        end
      else
        node.to_s.gsub("@", "")
      end
    end

    private def convert_ruby_hash(ruby : String) : String
      ruby.gsub(/(\w+):\s*/, "\\1: ")
        .gsub(/@(\w+)\.(\w+)/, "\\1.\\2")
        .gsub(/article_id:\s*(\d+)/, "article_id: \\1")
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
