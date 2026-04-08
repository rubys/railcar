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

require "../prism/bindings"
require "../prism/deserializer"
require "./crystal_emitter"
require "./controller_extractor"

module Ruby2CR
  class TestConverter
    # Convert a Rails test file to Crystal spec
    def self.convert(source : String, test_type : String) : String
      ast = Prism.parse(source)
      stmts = ast.statements
      return "" unless stmts.is_a?(Prism::StatementsNode)

      case test_type
      when "model"
        convert_model_test(stmts)
      when "controller"
        convert_controller_test(stmts)
      else
        ""
      end
    end

    def self.convert_file(path : String, test_type : String) : String
      convert(File.read(path), test_type)
    end

    # Convert model test class
    private def self.convert_model_test(stmts : Prism::StatementsNode) : String
      klass = find_class(stmts)
      return "" unless klass

      io = IO::Memory.new
      io << "require \"spec\"\n"
      io << "require \"../src/models/*\"\n"
      io << "require \"./spec_helper\"\n\n"

      # Extract class name for describe
      describe_name = klass.name.chomp("Test")
      io << "describe Ruby2CR::#{describe_name} do\n"

      # Setup/teardown
      io << "  before_each do\n"
      io << "    db = setup_test_database\n"
      io << "    setup_fixtures(db)\n"
      io << "  end\n\n"

      # Convert each test method
      if body = klass.body
        stmts = body.is_a?(Prism::StatementsNode) ? body.body : [body]
        stmts.each do |stmt|
          case stmt
          when Prism::CallNode
            if stmt.name == "test" && stmt.block
              convert_test_block(stmt, io, "  ")
            end
          end
        end
      end

      io << "end\n"
      io.to_s
    end

    # Convert controller test class
    private def self.convert_controller_test(stmts : Prism::StatementsNode) : String
      klass = find_class(stmts)
      return "" unless klass

      io = IO::Memory.new
      io << "require \"spec\"\n"
      io << "require \"http/server\"\n"
      io << "require \"ecr\"\n"
      io << "require \"../src/routes\"\n"
      io << "require \"../src/models/*\"\n"
      io << "require \"./spec_helper\"\n\n"

      # Test helper for mock requests
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

      if body = klass.body
        stmts = body.is_a?(Prism::StatementsNode) ? body.body : [body]
        stmts.each do |stmt|
          case stmt
          when Prism::CallNode
            if stmt.name == "test" && stmt.block
              convert_controller_test_block(stmt, io, "  ", setup_vars)
            end
          end
        end
      end

      io << "end\n"
      io.to_s
    end

    private def self.find_class(node : Prism::Node) : Prism::ClassNode?
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

    # Extract setup block variables: setup do @article = articles(:one) end
    private def self.extract_setup_vars(klass : Prism::ClassNode) : Hash(String, String)
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
              vars[var] = expr_to_crystal(s.value)
            end
          end
        end
      end
      vars
    end

    # Convert a test "name" do ... end block to it "name" do ... end
    private def self.convert_test_block(call : Prism::CallNode, io : IO, indent : String)
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

    private def self.convert_controller_test_block(call : Prism::CallNode, io : IO, indent : String, setup_vars : Hash(String, String))
      args = call.arg_nodes
      test_name = args[0]?.is_a?(Prism::StringNode) ? args[0].as(Prism::StringNode).value : "unnamed"

      io << indent << "it #{test_name.inspect} do\n"

      # Inject setup vars
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

    private def self.emit_test_body(node : Prism::Node, io : IO, indent : String)
      stmts = node.is_a?(Prism::StatementsNode) ? node.body : [node]

      stmts.each do |stmt|
        case stmt
        when Prism::LocalVariableWriteNode
          io << indent << stmt.name << " = " << expr_to_crystal(stmt.value) << "\n"
        when Prism::InstanceVariableWriteNode
          io << indent << stmt.name.lchop("@") << " = " << expr_to_crystal(stmt.value) << "\n"
        when Prism::CallNode
          if stmt.name.starts_with?("assert")
            emit_assertion(stmt, io, indent)
          else
            # Regular method call (e.g., article.destroy)
            io << indent << expr_to_crystal(stmt) << "\n"
          end
        when Prism::IfNode
          io << indent << "if " << expr_to_crystal(stmt.condition) << "\n"
          emit_test_body(stmt.then_body.not_nil!, io, indent + "  ") if stmt.then_body
          io << indent << "end\n"
        end
      end
    end

    private def self.emit_controller_test_body(node : Prism::Node, io : IO, indent : String)
      stmts = node.is_a?(Prism::StatementsNode) ? node.body : [node]

      stmts.each do |stmt|
        case stmt
        when Prism::LocalVariableWriteNode
          io << indent << stmt.name << " = " << expr_to_crystal(stmt.value) << "\n"
        when Prism::CallNode
          case stmt.name
          when "get"
            emit_http_call(stmt, "GET", io, indent)
          when "post"
            emit_http_call(stmt, "POST", io, indent)
          when "patch"
            emit_http_call(stmt, "PATCH", io, indent)
          when "delete"
            emit_http_call(stmt, "DELETE", io, indent)
          when "assert_response"
            emit_response_assertion(stmt, io, indent)
          when "assert_redirected_to"
            io << indent << "response.status_code.should eq 302\n"
          when "assert_select"
            emit_assert_select(stmt, io, indent)
          when "assert_difference"
            emit_assert_difference(stmt, io, indent, controller_test: true)
          when "assert_no_difference"
            emit_assert_no_difference(stmt, io, indent, controller_test: true)
          else
            emit_assertion(stmt, io, indent)
          end
        end
      end
    end

    # Convert Minitest assertions to Crystal spec
    private def self.emit_assertion(call : Prism::CallNode, io : IO, indent : String)
      args = call.arg_nodes
      case call.name
      when "assert_equal"
        expected = expr_to_crystal(args[0])
        actual = expr_to_crystal(args[1])
        io << indent << actual << ".should eq " << expected << "\n"
      when "assert_not_nil"
        expr = expr_to_crystal(args[0])
        io << indent << expr << ".should_not be_nil\n"
      when "assert_not"
        expr = expr_to_crystal(args[0])
        io << indent << expr << ".should be_false\n"
      when "assert"
        expr = expr_to_crystal(args[0])
        io << indent << expr << ".should be_true\n"
      when "assert_difference"
        emit_assert_difference(call, io, indent)
      when "assert_no_difference"
        emit_assert_no_difference(call, io, indent)
      else
        io << indent << "# #{call.name}(...)\n"
      end
    end

    private def self.emit_assert_difference(call : Prism::CallNode, io : IO, indent : String, controller_test : Bool = false)
      args = call.arg_nodes
      expr = args[0]?.is_a?(Prism::StringNode) ? args[0].as(Prism::StringNode).value : "count"
      diff = args[1]?.is_a?(Prism::IntegerNode) ? args[1].as(Prism::IntegerNode).value : 1

      model_count = expr.gsub(/(\w+)\.count/) { |m| "Ruby2CR::#{m}" }

      io << indent << "before_count = #{model_count}\n"
      if block = call.block
        if block.is_a?(Prism::BlockNode) && (body = block.body)
          if controller_test
            emit_controller_test_body(body, io, indent)
          else
            emit_test_body(body, io, indent)
          end
        end
      end
      io << indent << "(#{model_count} - before_count).should eq #{diff}\n"
    end

    private def self.emit_assert_no_difference(call : Prism::CallNode, io : IO, indent : String, controller_test : Bool = false)
      args = call.arg_nodes
      expr = args[0]?.is_a?(Prism::StringNode) ? args[0].as(Prism::StringNode).value : "count"
      model_count = expr.gsub(/(\w+)\.count/) { |m| "Ruby2CR::#{m}" }

      io << indent << "before_count = #{model_count}\n"
      if block = call.block
        if block.is_a?(Prism::BlockNode) && (body = block.body)
          if controller_test
            emit_controller_test_body(body, io, indent)
          else
            emit_test_body(body, io, indent)
          end
        end
      end
      io << indent << "#{model_count}.should eq before_count\n"
    end

    # HTTP request helpers — uses mock_request instead of HTTP::Client
    private def self.emit_http_call(call : Prism::CallNode, method : String, io : IO, indent : String)
      args = call.arg_nodes
      url = expr_to_crystal(args[0])

      # Extract params from kwargs
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
        body = params_str || "nil"
        io << indent << "response = mock_request(\"POST\", #{url}, #{body})\n"
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

    private def self.emit_response_assertion(call : Prism::CallNode, io : IO, indent : String)
      args = call.arg_nodes
      status = case args[0]?
               when Prism::SymbolNode
                 case args[0].as(Prism::SymbolNode).value
                 when "success"            then 200
                 when "unprocessable_entity" then 422
                 when "redirect"           then 302
                 else 200
                 end
               else 200
               end
      io << indent << "response.status_code.should eq #{status}\n"
    end

    private def self.emit_assert_select(call : Prism::CallNode, io : IO, indent : String)
      args = call.arg_nodes
      selector = args[0]?.is_a?(Prism::StringNode) ? args[0].as(Prism::StringNode).value : ""

      if args.size > 1 && args[1].is_a?(Prism::StringNode)
        # assert_select "h1", "Articles" → body contains "Articles"
        expected = args[1].as(Prism::StringNode).value
        io << indent << "response.body.should contain #{expected.inspect}\n"
      else
        # Convert CSS selectors to string presence checks
        # #id → id="id"
        # .class → class="...class..."
        # tag → <tag
        check = if selector.starts_with?("#")
                   id = selector.lchop("#").split(" ").first.split(".").first
                   "id=\"#{id}\""
                 elsif selector.starts_with?(".")
                   cls = selector.lchop(".")
                   cls
                 elsif selector.includes?("#") || selector.includes?(".")
                   # Complex selector — just check for key parts
                   parts = selector.split(/[\s#.]/).reject(&.empty?)
                   parts.first
                 else
                   "<#{selector}"
                 end
        io << indent << "response.body.should contain #{check.inspect}\n"
      end
    end

    private def self.extract_form_params(node : Prism::Node) : String?
      # { article: { title: "...", body: "..." } } → "article[title]=...&article[body]=..."
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
              value = expr_to_crystal(nel.value_node)
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

    # Convert expression to Crystal
    private def self.expr_to_crystal(node : Prism::Node) : String
      case node
      when Prism::CallNode
        receiver = node.receiver
        method = node.name
        args = node.arg_nodes

        case method
        when "new"
          recv = receiver ? expr_to_crystal(receiver) : "self"
          if args.size == 1 && args[0].is_a?(Prism::KeywordHashNode)
            # Model.new(title: "...", body: "...") → Model.new({"title" => "...", "body" => "..."})
            kwargs = args[0].as(Prism::KeywordHashNode)
            pairs = kwargs.elements.compact_map do |el|
              next nil unless el.is_a?(Prism::AssocNode) && el.key.is_a?(Prism::SymbolNode)
              "\"#{el.key.as(Prism::SymbolNode).value}\" => #{expr_to_crystal(el.value_node)}.as(DB::Any)"
            end
            "#{recv}.new({#{pairs.join(", ")}} of String => DB::Any)"
          elsif args.empty?
            "#{recv}.new"
          else
            "#{recv}.new(#{args.map { |a| expr_to_crystal(a) }.join(", ")})"
          end
        when "create"
          recv = receiver ? expr_to_crystal(receiver) : "self"
          if args.size == 1 && args[0].is_a?(Prism::KeywordHashNode)
            kwargs = args[0].as(Prism::KeywordHashNode)
            pairs = kwargs.elements.compact_map do |el|
              next nil unless el.is_a?(Prism::AssocNode) && el.key.is_a?(Prism::SymbolNode)
              "#{el.key.as(Prism::SymbolNode).value}: #{expr_to_crystal(el.value_node)}"
            end
            "#{recv}.create(#{pairs.join(", ")})"
          else
            "#{recv}.create(#{args.map { |a| expr_to_crystal(a) }.join(", ")})"
          end
        when "build"
          recv = receiver ? expr_to_crystal(receiver) : "self"
          if args.size == 1 && args[0].is_a?(Prism::KeywordHashNode)
            kwargs = args[0].as(Prism::KeywordHashNode)
            pairs = kwargs.elements.compact_map do |el|
              next nil unless el.is_a?(Prism::AssocNode) && el.key.is_a?(Prism::SymbolNode)
              "#{el.key.as(Prism::SymbolNode).value}: #{expr_to_crystal(el.value_node)}"
            end
            "#{recv}.build(#{pairs.join(", ")})"
          else
            "#{recv}.build(#{args.map { |a| expr_to_crystal(a) }.join(", ")})"
          end
        when "articles", "comments"
          if args.size == 1 && args[0].is_a?(Prism::SymbolNode)
            label = args[0].as(Prism::SymbolNode).value
            "#{method}(\"#{label}\")"
          elsif receiver
            "#{expr_to_crystal(receiver)}.#{method}"
          else
            method
          end
        else
          if receiver
            recv = expr_to_crystal(receiver)
            if args.empty?
              "#{recv}.#{method}"
            else
              arg_strs = args.map { |a| expr_to_crystal(a) }
              "#{recv}.#{method}(#{arg_strs.join(", ")})"
            end
          else
            if method.ends_with?("_url")
              # Convert _url helpers to paths, keeping args
              path_method = method.chomp("_url") + "_path"
              if args.empty?
                path_method
              else
                arg_strs = args.map { |a| expr_to_crystal(a) }
                "#{path_method}(#{arg_strs.join(", ")})"
              end
            elsif args.empty?
              method
            else
              arg_strs = args.map { |a| expr_to_crystal(a) }
              "#{method}(#{arg_strs.join(", ")})"
            end
          end
        end
      when Prism::InstanceVariableReadNode
        node.name.lchop("@")
      when Prism::LocalVariableReadNode
        node.name
      when Prism::StringNode
        node.value.inspect
      when Prism::SymbolNode
        ":#{node.value}"
      when Prism::IntegerNode
        node.value.to_s
      when Prism::TrueNode
        "true"
      when Prism::FalseNode
        "false"
      when Prism::NilNode
        "nil"
      when Prism::ConstantReadNode
        "Ruby2CR::#{node.name}"
      when Prism::KeywordHashNode
        node.elements.map do |el|
          if el.is_a?(Prism::AssocNode) && el.key.is_a?(Prism::SymbolNode)
            "#{el.key.as(Prism::SymbolNode).value}: #{expr_to_crystal(el.value_node)}"
          else
            ""
          end
        end.reject(&.empty?).join(", ")
      else
        "nil"
      end
    end
  end
end
