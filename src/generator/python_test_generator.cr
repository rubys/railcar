# Generates Python pytest test files from Rails Minitest tests.
#
# Converts Rails test patterns to pytest equivalents:
#   test "name" do ... end  →  def test_name():
#   assert_equal a, b       →  assert b == a
#   assert_not x            →  assert not x
#   assert_difference        →  count before/after
#   get/post/patch/delete    →  aiohttp test client calls
#   articles(:one)           →  fixture functions

require "../prism/bindings"
require "../prism/deserializer"
require "./inflector"

module Railcar
  class PythonTestGenerator
    getter app : AppModel
    getter rails_dir : String

    def initialize(@app, @rails_dir)
    end

    def generate(output_dir : String)
      tests_dir = File.join(output_dir, "tests")
      Dir.mkdir_p(tests_dir) unless Dir.exists?(tests_dir)

      File.write(File.join(tests_dir, "__init__.py"), "")
      generate_conftest(tests_dir, output_dir)

      # Convert model tests
      model_tests_dir = File.join(rails_dir, "test/models")
      if Dir.exists?(model_tests_dir)
        Dir.glob(File.join(model_tests_dir, "*_test.rb")).each do |path|
          basename = File.basename(path, ".rb")
          py_name = "test_#{basename.chomp("_test")}.py"
          source = convert_model_test(File.read(path))
          next if source.empty?
          File.write(File.join(tests_dir, py_name), source)
          puts "  tests/#{py_name}"
        end
      end

      # Convert controller tests
      controller_tests_dir = File.join(rails_dir, "test/controllers")
      if Dir.exists?(controller_tests_dir)
        Dir.glob(File.join(controller_tests_dir, "*_test.rb")).each do |path|
          basename = File.basename(path, ".rb")
          py_name = "test_#{basename.chomp("_test")}.py"
          source = convert_controller_test(File.read(path))
          next if source.empty?
          File.write(File.join(tests_dir, py_name), source)
          puts "  tests/#{py_name}"
        end
      end
    end

    private def generate_conftest(tests_dir : String, output_dir : String)
      schema_map = {} of String => TableSchema
      app.schemas.each { |s| schema_map[s.name] = s }

      io = IO::Memory.new
      io << "import pytest\n"
      io << "import sys\n"
      io << "import os\n"
      io << "sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))\n\n"
      io << "from models import *\n"
      io << "from helpers import *\n\n"

      # DB setup fixture
      io << "@pytest.fixture(autouse=True)\n"
      io << "def setup_db(tmp_path):\n"
      io << "    import models\n"
      io << "    db_path = str(tmp_path / 'test.db')\n"
      io << "    models.DB_PATH = db_path\n"
      io << "    init_db()\n"
      io << "    setup_fixtures()\n"
      io << "    yield\n"
      io << "    if os.path.exists(db_path):\n"
      io << "        os.remove(db_path)\n\n"

      # Fixture data
      # Collect known fixture table names for association detection
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
          io << "    #{fixture.name}_#{record.label} = #{model_name}("
          fields = record.fields.reject { |k, _| k == "id" }
          field_strs = fields.map do |k, v|
            if association_fields.includes?(k) && fixture_table_names.includes?(Inflector.pluralize(k))
              # Association reference: article: one → article_id=articles_one.id
              ref_fixture = Inflector.pluralize(k)
              "#{k}_id=#{ref_fixture}_#{v}.id"
            else
              "#{k}=#{v.inspect}"
            end
          end
          io << field_strs.join(", ")
          io << ")\n"
          io << "    #{fixture.name}_#{record.label}.save()\n"
        end
      end
      io << "\n"

      # Fixture accessor functions
      io << "# Fixture accessors\n"
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

    # --- Model tests ---

    private def convert_model_test(source : String) : String
      ast = Prism.parse(source)
      stmts = ast.statements
      return "" unless stmts.is_a?(Prism::StatementsNode)

      klass = find_class(stmts)
      return "" unless klass

      io = IO::Memory.new
      io << "from models import *\n"
      io << "from tests.conftest import *\n\n"

      each_test_block(klass) do |call|
        test_name = call.arg_nodes[0]?.is_a?(Prism::StringNode) ? call.arg_nodes[0].as(Prism::StringNode).value : "unnamed"
        func_name = "test_" + test_name.downcase.gsub(/[^a-z0-9]+/, "_").strip('_')

        io << "def #{func_name}():\n"
        if block = call.block
          if block.is_a?(Prism::BlockNode) && (body = block.body)
            emit_test_body(body, io, "    ")
          end
        end
        io << "\n"
      end

      io.to_s
    end

    # --- Controller tests ---

    private def convert_controller_test(source : String) : String
      ast = Prism.parse(source)
      stmts = ast.statements
      return "" unless stmts.is_a?(Prism::StatementsNode)

      klass = find_class(stmts)
      return "" unless klass

      setup_vars = extract_setup_vars(klass)

      io = IO::Memory.new
      io << "import pytest\n"
      io << "from aiohttp import web\n"
      io << "from models import *\n"
      io << "from helpers import *\n"
      io << "from tests.conftest import *\n\n"

      io << "# Import app for test client\n"
      io << "import app as app_module\n\n"

      each_test_block(klass) do |call|
        test_name = call.arg_nodes[0]?.is_a?(Prism::StringNode) ? call.arg_nodes[0].as(Prism::StringNode).value : "unnamed"
        func_name = "test_" + test_name.downcase.gsub(/[^a-z0-9]+/, "_").strip('_')

        io << "async def #{func_name}(aiohttp_client):\n"
        io << "    client = await aiohttp_client(app_module.create_app())\n"

        # Inject setup vars
        setup_vars.each do |var, value|
          io << "    #{var} = #{value}\n"
        end

        if block = call.block
          if block.is_a?(Prism::BlockNode) && (body = block.body)
            emit_controller_test_body(body, io, "    ")
          end
        end
        io << "\n"
      end

      io.to_s
    end

    # --- Body emission ---

    private def emit_test_body(node : Prism::Node, io : IO, indent : String)
      stmts = node.is_a?(Prism::StatementsNode) ? node.body : [node]
      stmts.each do |stmt|
        case stmt
        when Prism::LocalVariableWriteNode
          io << indent << stmt.name << " = " << py_expr(stmt.value) << "\n"
        when Prism::CallNode
          emit_test_call(stmt, io, indent)
        end
      end
    end

    private def emit_controller_test_body(node : Prism::Node, io : IO, indent : String)
      stmts = node.is_a?(Prism::StatementsNode) ? node.body : [node]
      stmts.each do |stmt|
        case stmt
        when Prism::LocalVariableWriteNode
          io << indent << stmt.name << " = " << py_expr(stmt.value) << "\n"
        when Prism::CallNode
          emit_controller_test_call(stmt, io, indent)
        end
      end
    end

    private def emit_test_call(call : Prism::CallNode, io : IO, indent : String)
      case call.name
      when "assert_equal"
        args = call.arg_nodes
        io << indent << "assert " << py_expr(args[1]) << " == " << py_expr(args[0]) << "\n"
      when "assert_not_nil"
        io << indent << "assert " << py_expr(call.arg_nodes[0]) << " is not None\n"
      when "assert_not"
        io << indent << "assert not " << py_expr(call.arg_nodes[0]) << "\n"
      when "assert"
        io << indent << "assert " << py_expr(call.arg_nodes[0]) << "\n"
      when "assert_difference"
        emit_assert_difference(call, io, indent)
      when "assert_no_difference"
        emit_assert_no_difference(call, io, indent)
      else
        io << indent << py_expr_call(call) << "\n"
      end
    end

    private def emit_controller_test_call(call : Prism::CallNode, io : IO, indent : String)
      case call.name
      when "get"
        url = py_expr(call.arg_nodes[0])
        io << indent << "response = await client.get(#{url})\n"
      when "post"
        url = py_expr(call.arg_nodes[0])
        params = extract_form_params_py(call)
        if params
          io << indent << "response = await client.post(#{url}, data=#{params})\n"
        else
          io << indent << "response = await client.post(#{url})\n"
        end
      when "patch"
        url = py_expr(call.arg_nodes[0])
        params = extract_form_params_py(call)
        base = params ? "{'_method': 'patch', **#{params}}" : "{'_method': 'patch'}"
        io << indent << "response = await client.post(#{url}, data=#{base})\n"
      when "delete"
        url = py_expr(call.arg_nodes[0])
        io << indent << "response = await client.post(#{url}, data={'_method': 'delete'})\n"
      when "assert_response"
        status = call.arg_nodes[0]?
        code = case status
               when Prism::SymbolNode
                 case status.value
                 when "success"              then "200"
                 when "unprocessable_entity" then "422"
                 when "redirect"             then "302"
                 else "200"
                 end
               else "200"
               end
        io << indent << "assert response.status == #{code}\n"
      when "assert_redirected_to"
        url = py_expr(call.arg_nodes[0])
        io << indent << "assert response.status in (301, 302, 303)\n"
        io << indent << "assert #{url} in response.headers.get('Location', '')\n"
      when "assert_select"
        selector = call.arg_nodes[0]?.is_a?(Prism::StringNode) ? call.arg_nodes[0].as(Prism::StringNode).value : ""
        if call.arg_nodes.size > 1 && call.arg_nodes[1].is_a?(Prism::StringNode)
          expected = call.arg_nodes[1].as(Prism::StringNode).value
          io << indent << "body = await response.text()\n"
          io << indent << "assert #{expected.inspect} in body\n"
        else
          check = if selector.starts_with?("#")
                    "id=\\\"#{selector.lchop("#")}\\\""
                  else
                    "<#{selector}"
                  end
          io << indent << "body = await response.text()\n"
          io << indent << "assert #{check.inspect} in body\n"
        end
        # Handle nested assert_select blocks
        if block = call.block
          if block.is_a?(Prism::BlockNode) && (body = block.body)
            emit_controller_test_body(body, io, indent)
          end
        end
      when "assert_difference"
        emit_assert_difference_controller(call, io, indent)
      when "assert_no_difference"
        emit_assert_no_difference_controller(call, io, indent)
      else
        emit_test_call(call, io, indent)
      end
    end

    # --- Difference assertions ---

    private def emit_assert_difference(call : Prism::CallNode, io : IO, indent : String)
      count_expr = call.arg_nodes[0]?.is_a?(Prism::StringNode) ? call.arg_nodes[0].as(Prism::StringNode).value : ""
      diff = call.arg_nodes[1]?.is_a?(Prism::IntegerNode) ? call.arg_nodes[1].as(Prism::IntegerNode).value : 1
      py_count = count_expr.gsub(/(\w+)\.count/) { "len(#{$1}.all())" }

      io << indent << "before_count = #{py_count}\n"
      if block = call.block
        if block.is_a?(Prism::BlockNode) && (body = block.body)
          emit_test_body(body, io, indent)
        end
      end
      io << indent << "assert #{py_count} - before_count == #{diff}\n"
    end

    private def emit_assert_no_difference(call : Prism::CallNode, io : IO, indent : String)
      count_expr = call.arg_nodes[0]?.is_a?(Prism::StringNode) ? call.arg_nodes[0].as(Prism::StringNode).value : ""
      py_count = count_expr.gsub(/(\w+)\.count/) { "len(#{$1}.all())" }

      io << indent << "before_count = #{py_count}\n"
      if block = call.block
        if block.is_a?(Prism::BlockNode) && (body = block.body)
          emit_test_body(body, io, indent)
        end
      end
      io << indent << "assert #{py_count} == before_count\n"
    end

    private def emit_assert_difference_controller(call : Prism::CallNode, io : IO, indent : String)
      count_expr = call.arg_nodes[0]?.is_a?(Prism::StringNode) ? call.arg_nodes[0].as(Prism::StringNode).value : ""
      diff = call.arg_nodes[1]?.is_a?(Prism::IntegerNode) ? call.arg_nodes[1].as(Prism::IntegerNode).value : 1
      py_count = count_expr.gsub(/(\w+)\.count/) { "len(#{$1}.all())" }

      io << indent << "before_count = #{py_count}\n"
      if block = call.block
        if block.is_a?(Prism::BlockNode) && (body = block.body)
          emit_controller_test_body(body, io, indent)
        end
      end
      io << indent << "assert #{py_count} - before_count == #{diff}\n"
    end

    private def emit_assert_no_difference_controller(call : Prism::CallNode, io : IO, indent : String)
      count_expr = call.arg_nodes[0]?.is_a?(Prism::StringNode) ? call.arg_nodes[0].as(Prism::StringNode).value : ""
      py_count = count_expr.gsub(/(\w+)\.count/) { "len(#{$1}.all())" }

      io << indent << "before_count = #{py_count}\n"
      if block = call.block
        if block.is_a?(Prism::BlockNode) && (body = block.body)
          emit_controller_test_body(body, io, indent)
        end
      end
      io << indent << "assert #{py_count} == before_count\n"
    end

    # --- Expression conversion ---

    private def py_expr(node : Prism::Node) : String
      case node
      when Prism::StringNode
        node.value.inspect
      when Prism::SymbolNode
        node.value.inspect
      when Prism::IntegerNode
        node.value.to_s
      when Prism::TrueNode
        "True"
      when Prism::FalseNode
        "False"
      when Prism::NilNode
        "None"
      when Prism::LocalVariableReadNode
        node.name
      when Prism::InstanceVariableReadNode
        node.name.lchop("@")
      when Prism::ConstantReadNode
        node.name
      when Prism::CallNode
        py_expr_call(node)
      when Prism::InterpolatedStringNode
        parts = node.parts.map do |part|
          case part
          when Prism::StringNode
            part.value.gsub('"', "\\\"")
          when Prism::EmbeddedStatementsNode
            if stmts = part.statements
              body = stmts.is_a?(Prism::StatementsNode) ? stmts.body : [stmts]
              "{#{body.map { |s| py_expr(s) }.join}}"
            else
              ""
            end
          else
            py_expr(part)
          end
        end
        "f\"#{parts.join}\""
      else
        "None  # TODO: #{node.class.name}"
      end
    end

    # Build set of property names from schema (all columns are properties in Python)
    private def property_names : Set(String)
      @property_names ||= begin
        names = Set{"id", "created_at", "updated_at"}
        app.schemas.each do |schema|
          schema.columns.each { |col| names << col.name }
        end
        names
      end
    end

    private def py_expr_call(call : Prism::CallNode) : String
      receiver = call.receiver
      method = call.name
      args = call.arg_nodes

      # Fixture accessors: articles(:one) → articles('one')
      if receiver.nil? && args.size == 1 && args[0].is_a?(Prism::SymbolNode)
        fixture_name = method
        record_name = args[0].as(Prism::SymbolNode).value
        if app.fixtures.any? { |f| f.name == fixture_name }
          return "#{fixture_name}('#{record_name}')"
        end
      end

      # URL helpers: articles_url → articles_path()
      if receiver.nil? && method.ends_with?("_url")
        path_method = method.chomp("_url") + "_path"
        if args.empty?
          return "#{path_method}()"
        else
          return "#{path_method}(#{args.map { |a| py_expr(a) }.join(", ")})"
        end
      end

      # Constructor: Article.new(title: "x", body: "y") → Article(title="x", body="y")
      if method == "new" && receiver.is_a?(Prism::ConstantReadNode)
        model = receiver.name
        if args.size == 1 && args[0].is_a?(Prism::KeywordHashNode)
          kwargs = build_kwargs(args[0].as(Prism::KeywordHashNode))
          return "#{model}(#{kwargs})"
        elsif args.empty?
          return "#{model}()"
        end
      end

      # Association .create(kwargs) and .build(kwargs) → Model(fk=parent.id, kwargs)
      if (method == "create" || method == "build") && receiver && args.size == 1 && args[0].is_a?(Prism::KeywordHashNode)
        kwargs = build_kwargs(args[0].as(Prism::KeywordHashNode))
        recv = py_expr(receiver)
        # For article.comments.create → Comment(article_id=article.id, kwargs)
        # This is complex; for now emit as a method call
        return "#{recv}.#{method}(#{kwargs})"
      end

      if receiver
        recv = py_expr(receiver)

        # Property access: article.title, article.id, etc.
        if args.empty? && property_names.includes?(method)
          return "#{recv}.#{method}"
        end

        # .last → .all()[-1] (no .last on Python model)
        if method == "last" && args.empty?
          return "#{recv}.all()[-1]"
        end

        # Regular method call
        if args.empty?
          "#{recv}.#{method}()"
        else
          "#{recv}.#{method}(#{args.map { |a| py_expr(a) }.join(", ")})"
        end
      else
        if args.empty?
          "#{method}()"
        else
          "#{method}(#{args.map { |a| py_expr(a) }.join(", ")})"
        end
      end
    end

    private def extract_form_params_py(call : Prism::CallNode) : String?
      call.arg_nodes.each do |arg|
        next unless arg.is_a?(Prism::KeywordHashNode)
        arg.elements.each do |el|
          next unless el.is_a?(Prism::AssocNode)
          key = el.key
          next unless key.is_a?(Prism::SymbolNode) && key.value == "params"
          return build_form_data(el.value_node)
        end
      end
      nil
    end

    private def build_form_data(node : Prism::Node) : String?
      return nil unless node.is_a?(Prism::HashNode)
      parts = [] of String
      node.elements.each do |el|
        next unless el.is_a?(Prism::AssocNode)
        model = el.key.is_a?(Prism::SymbolNode) ? el.key.as(Prism::SymbolNode).value : next
        nested = el.value_node
        if nested.is_a?(Prism::HashNode)
          nested.elements.each do |nel|
            next unless nel.is_a?(Prism::AssocNode)
            field = nel.key.is_a?(Prism::SymbolNode) ? nel.key.as(Prism::SymbolNode).value : next
            value = py_expr(nel.value_node)
            parts << "'#{model}[#{field}]': #{value}"
          end
        end
      end
      return nil if parts.empty?
      "{#{parts.join(", ")}}"
    end

    # --- Helpers ---

    @property_names : Set(String)?

    private def build_kwargs(hash : Prism::KeywordHashNode) : String
      hash.elements.compact_map do |el|
        next nil unless el.is_a?(Prism::AssocNode) && el.key.is_a?(Prism::SymbolNode)
        "#{el.key.as(Prism::SymbolNode).value}=#{py_expr(el.value_node)}"
      end.join(", ")
    end

    private def find_class(node : Prism::Node) : Prism::ClassNode?
      case node
      when Prism::StatementsNode
        node.body.each do |child|
          result = find_class(child)
          return result if result
        end
      when Prism::ClassNode
        return node
      end
      nil
    end

    private def each_test_block(klass : Prism::ClassNode, &)
      if body = klass.body
        stmts = body.is_a?(Prism::StatementsNode) ? body.body : [body]
        stmts.each do |stmt|
          yield stmt if stmt.is_a?(Prism::CallNode) && stmt.name == "test" && stmt.block
        end
      end
    end

    private def extract_setup_vars(klass : Prism::ClassNode) : Hash(String, String)
      vars = {} of String => String
      if body = klass.body
        stmts = body.is_a?(Prism::StatementsNode) ? body.body : [body]
        stmts.each do |stmt|
          next unless stmt.is_a?(Prism::CallNode) && stmt.name == "setup"
          next unless block = stmt.block
          next unless block.is_a?(Prism::BlockNode)
          next unless block_body = block.body
          block_stmts = block_body.is_a?(Prism::StatementsNode) ? block_body.body : [block_body]
          block_stmts.each do |s|
            if s.is_a?(Prism::InstanceVariableWriteNode)
              vars[s.name.lchop("@")] = py_expr(s.value)
            end
          end
        end
      end
      vars
    end
  end
end
