# Converts Rails Minitest tests to Crystal spec format.
#
# Model tests: test "name" do ... end → it "name" do ... end
# Controller tests: integration tests → HTTP::Client tests
#
# Assertion mappings:
#   assert_equal expected, actual → actual.should eq expected
#   assert_not_nil expr → expr.should_not be_nil
#   assert_not expr → expr.should be_false
#   assert expr → expr.should be_true / be_truthy
#   assert_difference("Model.count", n) { } → count check
#   assert_no_difference("Model.count") { } → count check
#   assert_response :success → response.status_code.should eq 200
#   assert_redirected_to url → response.status_code.should eq 302

require "./crystal_expr"
require "./crystal_emitter"
require "./controller_extractor"

module Ruby2CR
  class TestConverter
    include CrystalExpr

    # Public class API delegates to instance
    def self.convert(source : String, test_type : String) : String
      new.convert(source, test_type)
    end

    def self.convert_file(path : String, test_type : String) : String
      new.convert(File.read(path), test_type)
    end

    def convert(source : String, test_type : String) : String
      ast = Prism.parse(source)
      stmts = ast.statements
      return "" unless stmts.is_a?(Prism::StatementsNode)

      case test_type
      when "model"      then convert_model_test(stmts)
      when "controller" then convert_controller_test(stmts)
      else ""
      end
    end

    # Override CrystalExpr#convert_call for test-specific patterns
    # String-level override delegates to AST-level map_call
    def convert_call(call : Prism::CallNode) : String
      map_call(call).to_s
    end

    # Override CrystalExpr#map_call for test-specific AST transformations
    def map_call(call : Prism::CallNode) : Crystal::ASTNode
      receiver = call.receiver
      method = call.name
      args = call.arg_nodes

      case method
      when "new"
        recv = receiver ? map_node(receiver) : Crystal::Var.new("self")
        if args.size == 1 && args[0].is_a?(Prism::KeywordHashNode)
          # Model.new(title: "...", body: "...") → Model.new({"title" => "...", "body" => "..."} of String => DB::Any)
          kwargs = args[0].as(Prism::KeywordHashNode)
          entries = kwargs.elements.compact_map do |el|
            next nil unless el.is_a?(Prism::AssocNode) && el.key.is_a?(Prism::SymbolNode)
            Crystal::HashLiteral::Entry.new(
              Crystal::StringLiteral.new(el.key.as(Prism::SymbolNode).value),
              Crystal::Cast.new(map_node(el.value_node), Crystal::Path.new(["DB", "Any"]))
            )
          end
          hash_literal = Crystal::HashLiteral.new(entries,
            of: Crystal::HashLiteral::Entry.new(
              Crystal::Path.new("String"),
              Crystal::Path.new(["DB", "Any"])
            ))
          Crystal::Call.new(recv, "new", [hash_literal] of Crystal::ASTNode)
        elsif args.empty?
          Crystal::Call.new(recv, "new")
        else
          Crystal::Call.new(recv, "new", args.map { |a| map_node(a) })
        end
      when "create", "build"
        recv = receiver ? map_node(receiver) : Crystal::Var.new("self")
        if args.size == 1 && args[0].is_a?(Prism::KeywordHashNode)
          kwargs = args[0].as(Prism::KeywordHashNode)
          named_args = kwargs.elements.compact_map do |el|
            next nil unless el.is_a?(Prism::AssocNode) && el.key.is_a?(Prism::SymbolNode)
            Crystal::NamedArgument.new(el.key.as(Prism::SymbolNode).value, map_node(el.value_node))
          end
          Crystal::Call.new(recv, method, named_args: named_args)
        else
          Crystal::Call.new(recv, method, args.map { |a| map_node(a) })
        end
      else
        if receiver
          generic_call_node(call)
        else
          if method.ends_with?("_url")
            # Convert _url helpers to _path
            path_method = method.chomp("_url") + "_path"
            Crystal::Call.new(nil, path_method, args.map { |a| map_node(a) })
          elsif args.size == 1 && args[0].is_a?(Prism::SymbolNode)
            # Fixture accessor: articles(:one) → articles("one")
            label = args[0].as(Prism::SymbolNode).value
            Crystal::Call.new(nil, method, [Crystal::StringLiteral.new(label)] of Crystal::ASTNode)
          else
            generic_call_node(call)
          end
        end
      end
    end

    # --- Model tests ---

    private def convert_model_test(stmts : Prism::StatementsNode) : String
      klass = find_class(stmts)
      return "" unless klass

      io = IO::Memory.new
      io << "require \"spec\"\n"
      io << "require \"../src/models/*\"\n"
      io << "require \"./spec_helper\"\n\n"

      describe_name = klass.name.chomp("Test")
      io << "describe Ruby2CR::#{describe_name} do\n"

      io << "  before_each do\n"
      io << "    db = setup_test_database\n"
      io << "    setup_fixtures(db)\n"
      io << "  end\n\n"

      each_test_block(klass) do |stmt|
        convert_test_block(stmt, io, "  ")
      end

      io << "end\n"
      io.to_s
    end

    # --- Controller tests ---

    private def convert_controller_test(stmts : Prism::StatementsNode) : String
      klass = find_class(stmts)
      return "" unless klass

      io = IO::Memory.new
      io << "require \"spec\"\n"
      io << "require \"http/server\"\n"
      io << "require \"ecr\"\n"
      io << "require \"../src/routes\"\n"
      io << "require \"../src/models/*\"\n"
      io << "require \"./spec_helper\"\n\n"

      io << "include Ruby2CR::RouteHelpers\n\n"
      io << "record TestResponse, status_code : Int32, headers : HTTP::Headers, body : String\n\n"

      io << "def mock_request(method : String, path : String, body : String? = nil) : TestResponse\n"
      io << "  request = HTTP::Request.new(method, path)\n"
      io << "  if body\n"
      io << "    request.body = body\n"
      io << "    request.headers[\"Content-Type\"] = \"application/x-www-form-urlencoded\"\n"
      io << "  end\n"
      io << "  output = IO::Memory.new\n"
      io << "  response = HTTP::Server::Response.new(output)\n"
      io << "  context = HTTP::Server::Context.new(request, response)\n"
      io << "  router = Ruby2CR::Router.new\n"
      io << "  router.dispatch(context)\n"
      io << "  response.close\n"
      io << "  output.rewind\n"
      io << "  TestResponse.new(response.status_code, response.headers, output.gets_to_end)\n"
      io << "end\n\n"

      describe_name = klass.name.chomp("Test")
      io << "describe \"#{describe_name}\" do\n"

      io << "  before_each do\n"
      io << "    db = setup_test_database\n"
      io << "    setup_fixtures(db)\n"
      io << "  end\n\n"

      setup_vars = extract_setup_vars(klass)

      each_test_block(klass) do |stmt|
        convert_controller_test_block(stmt, io, "  ", setup_vars)
      end

      io << "end\n"
      io.to_s
    end

    # --- Helpers ---

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
          if stmt.is_a?(Prism::CallNode) && stmt.name == "test" && stmt.block
            yield stmt
          end
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
              var = s.name.lchop("@")
              vars[var] = expr(s.value)
            end
          end
        end
      end
      vars
    end

    # --- Test block conversion ---

    private def convert_test_block(call : Prism::CallNode, io : IO, indent : String)
      args = call.arg_nodes
      test_name = args[0]?.is_a?(Prism::StringNode) ? args[0].as(Prism::StringNode).value : "unnamed"

      io << indent << "it #{test_name.inspect} do\n"
      if block = call.block
        if block.is_a?(Prism::BlockNode) && (body = block.body)
          emit_test_body(body, io, indent + "  ")
        end
      end
      io << indent << "end\n\n"
    end

    private def convert_controller_test_block(call : Prism::CallNode, io : IO, indent : String, setup_vars : Hash(String, String))
      args = call.arg_nodes
      test_name = args[0]?.is_a?(Prism::StringNode) ? args[0].as(Prism::StringNode).value : "unnamed"

      io << indent << "it #{test_name.inspect} do\n"
      setup_vars.each do |var, value|
        io << indent << "  " << var << " = " << value << "\n"
      end
      if block = call.block
        if block.is_a?(Prism::BlockNode) && (body = block.body)
          emit_controller_test_body(body, io, indent + "  ")
        end
      end
      io << indent << "end\n\n"
    end

    # --- Body emission ---

    private def emit_test_body(node : Prism::Node, io : IO, indent : String)
      stmts = node.is_a?(Prism::StatementsNode) ? node.body : [node]
      stmts.each do |stmt|
        case stmt
        when Prism::LocalVariableWriteNode
          io << indent << stmt.name << " = " << expr(stmt.value) << "\n"
        when Prism::InstanceVariableWriteNode
          io << indent << stmt.name.lchop("@") << " = " << expr(stmt.value) << "\n"
        when Prism::CallNode
          if stmt.name.starts_with?("assert")
            emit_assertion(stmt, io, indent)
          else
            io << indent << expr(stmt) << "\n"
          end
        when Prism::IfNode
          io << indent << "if " << expr(stmt.condition) << "\n"
          emit_test_body(stmt.then_body.not_nil!, io, indent + "  ") if stmt.then_body
          io << indent << "end\n"
        end
      end
    end

    private def emit_controller_test_body(node : Prism::Node, io : IO, indent : String)
      stmts = node.is_a?(Prism::StatementsNode) ? node.body : [node]
      stmts.each do |stmt|
        case stmt
        when Prism::LocalVariableWriteNode
          io << indent << stmt.name << " = " << expr(stmt.value) << "\n"
        when Prism::CallNode
          case stmt.name
          when "get"    then emit_http_call(stmt, "GET", io, indent)
          when "post"   then emit_http_call(stmt, "POST", io, indent)
          when "patch"  then emit_http_call(stmt, "PATCH", io, indent)
          when "delete" then emit_http_call(stmt, "DELETE", io, indent)
          when "assert_response"      then emit_response_assertion(stmt, io, indent)
          when "assert_redirected_to" then io << indent << "response.status_code.should eq 302\n"
          when "assert_select"        then emit_assert_select(stmt, io, indent)
          when "assert_difference"    then emit_assert_difference(stmt, io, indent, controller_test: true)
          when "assert_no_difference" then emit_assert_no_difference(stmt, io, indent, controller_test: true)
          else emit_assertion(stmt, io, indent)
          end
        end
      end
    end

    # --- Assertions ---

    private def emit_assertion(call : Prism::CallNode, io : IO, indent : String)
      args = call.arg_nodes
      case call.name
      when "assert_equal"
        io << indent << expr(args[1]) << ".should eq " << expr(args[0]) << "\n"
      when "assert_not_nil"
        io << indent << expr(args[0]) << ".should_not be_nil\n"
      when "assert_not"
        io << indent << expr(args[0]) << ".should be_false\n"
      when "assert"
        io << indent << expr(args[0]) << ".should be_true\n"
      when "assert_difference"
        emit_assert_difference(call, io, indent)
      when "assert_no_difference"
        emit_assert_no_difference(call, io, indent)
      else
        io << indent << "# #{call.name}(...)\n"
      end
    end

    private def emit_assert_difference(call : Prism::CallNode, io : IO, indent : String, controller_test : Bool = false)
      args = call.arg_nodes
      count_expr = args[0]?.is_a?(Prism::StringNode) ? args[0].as(Prism::StringNode).value : "count"
      diff = args[1]?.is_a?(Prism::IntegerNode) ? args[1].as(Prism::IntegerNode).value : 1
      model_count = count_expr.gsub(/(\w+)\.count/) { |m| "Ruby2CR::#{m}" }

      io << indent << "before_count = #{model_count}\n"
      if block = call.block
        if block.is_a?(Prism::BlockNode) && (body = block.body)
          controller_test ? emit_controller_test_body(body, io, indent) : emit_test_body(body, io, indent)
        end
      end
      io << indent << "(#{model_count} - before_count).should eq #{diff}\n"
    end

    private def emit_assert_no_difference(call : Prism::CallNode, io : IO, indent : String, controller_test : Bool = false)
      args = call.arg_nodes
      count_expr = args[0]?.is_a?(Prism::StringNode) ? args[0].as(Prism::StringNode).value : "count"
      model_count = count_expr.gsub(/(\w+)\.count/) { |m| "Ruby2CR::#{m}" }

      io << indent << "before_count = #{model_count}\n"
      if block = call.block
        if block.is_a?(Prism::BlockNode) && (body = block.body)
          controller_test ? emit_controller_test_body(body, io, indent) : emit_test_body(body, io, indent)
        end
      end
      io << indent << "#{model_count}.should eq before_count\n"
    end

    # --- HTTP helpers ---

    private def emit_http_call(call : Prism::CallNode, method : String, io : IO, indent : String)
      args = call.arg_nodes
      url = expr(args[0])

      params_str = nil
      args.each do |arg|
        next unless arg.is_a?(Prism::KeywordHashNode)
        arg.elements.each do |el|
          next unless el.is_a?(Prism::AssocNode)
          key = el.key
          next unless key.is_a?(Prism::SymbolNode) && key.value == "params"
          params_str = extract_form_params(el.value_node)
        end
      end

      case method
      when "GET"
        io << indent << "response = mock_request(\"GET\", #{url})\n"
      when "POST"
        io << indent << "response = mock_request(\"POST\", #{url}, #{params_str || "nil"})\n"
      when "PATCH"
        if params_str
          io << indent << "response = mock_request(\"POST\", #{url}, \"_method=patch&\" + #{params_str})\n"
        else
          io << indent << "response = mock_request(\"POST\", #{url}, \"_method=patch\")\n"
        end
      when "DELETE"
        io << indent << "response = mock_request(\"POST\", #{url}, \"_method=delete\")\n"
      end
    end

    private def emit_response_assertion(call : Prism::CallNode, io : IO, indent : String)
      args = call.arg_nodes
      status = case args[0]?
               when Prism::SymbolNode
                 case args[0].as(Prism::SymbolNode).value
                 when "success"              then 200
                 when "unprocessable_entity" then 422
                 when "redirect"             then 302
                 else 200
                 end
               else 200
               end
      io << indent << "response.status_code.should eq #{status}\n"
    end

    private def emit_assert_select(call : Prism::CallNode, io : IO, indent : String)
      args = call.arg_nodes
      selector = args[0]?.is_a?(Prism::StringNode) ? args[0].as(Prism::StringNode).value : ""

      if args.size > 1 && args[1].is_a?(Prism::StringNode)
        expected = args[1].as(Prism::StringNode).value
        io << indent << "response.body.should contain #{expected.inspect}\n"
      else
        check = if selector.starts_with?("#")
                   id = selector.lchop("#").split(" ").first.split(".").first
                   "id=\"#{id}\""
                 elsif selector.starts_with?(".")
                   selector.lchop(".")
                 elsif selector.includes?("#") || selector.includes?(".")
                   selector.split(/[\s#.]/).reject(&.empty?).first
                 else
                   "<#{selector}"
                 end
        io << indent << "response.body.should contain #{check.inspect}\n"
      end
    end

    private def extract_form_params(node : Prism::Node) : String?
      if node.is_a?(Prism::HashNode)
        parts = [] of String
        node.elements.each do |el|
          next unless el.is_a?(Prism::AssocNode)
          model = el.key.is_a?(Prism::SymbolNode) ? el.key.as(Prism::SymbolNode).value : next
          nested = el.value_node
          if nested.is_a?(Prism::HashNode)
            nested.elements.each do |nel|
              next unless nel.is_a?(Prism::AssocNode)
              field = nel.key.is_a?(Prism::SymbolNode) ? nel.key.as(Prism::SymbolNode).value : next
              value = expr(nel.value_node)
              parts << "#{model}[#{field}]=\#{#{value}}"
            end
          end
        end
        return nil if parts.empty?
        "\"#{parts.join("&")}\""
      else
        nil
      end
    end
  end
end
