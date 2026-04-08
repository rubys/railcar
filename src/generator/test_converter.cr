# Converts Rails Minitest tests to Crystal spec format using Crystal AST.

require "compiler/crystal/syntax"
require "./crystal_expr"
require "./crystal_emitter"
require "./controller_extractor"

module Ruby2CR
  class TestConverter
    include CrystalExpr

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

    # --- CrystalExpr overrides ---

    def convert_call(call : Prism::CallNode) : String
      map_call(call).to_s
    end

    def map_call(call : Prism::CallNode) : Crystal::ASTNode
      receiver = call.receiver
      method = call.name
      args = call.arg_nodes

      case method
      when "new"
        recv = receiver ? map_node(receiver) : Crystal::Var.new("self")
        if args.size == 1 && args[0].is_a?(Prism::KeywordHashNode)
          kwargs = args[0].as(Prism::KeywordHashNode)
          entries = kwargs.elements.compact_map do |el|
            next nil unless el.is_a?(Prism::AssocNode) && el.key.is_a?(Prism::SymbolNode)
            Crystal::HashLiteral::Entry.new(
              Crystal::StringLiteral.new(el.key.as(Prism::SymbolNode).value),
              Crystal::Cast.new(map_node(el.value_node), Crystal::Path.new(["DB", "Any"]))
            )
          end
          hash_literal = Crystal::HashLiteral.new(entries,
            of: Crystal::HashLiteral::Entry.new(Crystal::Path.new("String"), Crystal::Path.new(["DB", "Any"])))
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
            Crystal::Call.new(nil, method.chomp("_url") + "_path", args.map { |a| map_node(a) })
          elsif args.size == 1 && args[0].is_a?(Prism::SymbolNode)
            Crystal::Call.new(nil, method, [Crystal::StringLiteral.new(args[0].as(Prism::SymbolNode).value)] of Crystal::ASTNode)
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

      describe_name = klass.name.chomp("Test")
      nodes = [
        Crystal::Require.new("spec"),
        Crystal::Require.new("../src/models/*"),
        Crystal::Require.new("./spec_helper"),
      ] of Crystal::ASTNode

      test_nodes = [] of Crystal::ASTNode
      test_nodes << build_before_each
      each_test_block(klass) { |stmt| test_nodes << build_test_block(stmt) }

      nodes << Crystal::Call.new(nil, "describe", [Crystal::Path.new(["Ruby2CR", describe_name])] of Crystal::ASTNode,
        block: Crystal::Block.new(body: Crystal::Expressions.new(test_nodes)))

      Crystal::Expressions.new(nodes).to_s + "\n"
    end

    # --- Controller tests ---

    private def convert_controller_test(stmts : Prism::StatementsNode) : String
      klass = find_class(stmts)
      return "" unless klass

      describe_name = klass.name.chomp("Test")
      nodes = [
        Crystal::Require.new("spec"),
        Crystal::Require.new("http/server"),
        Crystal::Require.new("ecr"),
        Crystal::Require.new("../src/routes"),
        Crystal::Require.new("../src/models/*"),
        Crystal::Require.new("./spec_helper"),
        Crystal::Include.new(Crystal::Path.new(["Ruby2CR", "RouteHelpers"])),
      ] of Crystal::ASTNode

      # record TestResponse
      nodes << build_test_response_record
      # def mock_request
      nodes << build_mock_request_def

      setup_vars = extract_setup_vars(klass)
      test_nodes = [] of Crystal::ASTNode
      test_nodes << build_before_each
      each_test_block(klass) { |stmt| test_nodes << build_controller_test_block(stmt, setup_vars) }

      nodes << Crystal::Call.new(nil, "describe", [Crystal::StringLiteral.new(describe_name)] of Crystal::ASTNode,
        block: Crystal::Block.new(body: Crystal::Expressions.new(test_nodes)))

      Crystal::Expressions.new(nodes).to_s + "\n"
    end

    # --- Shared structure builders ---

    private def build_before_each : Crystal::ASTNode
      body = Crystal::Expressions.new([
        Crystal::Assign.new(Crystal::Var.new("db"), Crystal::Call.new(nil, "setup_test_database")),
        Crystal::Call.new(nil, "setup_fixtures", [Crystal::Var.new("db")] of Crystal::ASTNode),
      ] of Crystal::ASTNode)
      Crystal::Call.new(nil, "before_each", block: Crystal::Block.new(body: body))
    end

    private def build_test_block(call : Prism::CallNode) : Crystal::ASTNode
      test_name = call.arg_nodes[0]?.is_a?(Prism::StringNode) ? call.arg_nodes[0].as(Prism::StringNode).value : "unnamed"
      body_nodes = [] of Crystal::ASTNode
      if block = call.block
        if block.is_a?(Prism::BlockNode) && (body = block.body)
          body_nodes = build_test_body(body)
        end
      end
      Crystal::Call.new(nil, "it", [Crystal::StringLiteral.new(test_name)] of Crystal::ASTNode,
        block: Crystal::Block.new(body: Crystal::Expressions.new(body_nodes)))
    end

    private def build_controller_test_block(call : Prism::CallNode, setup_vars : Hash(String, String)) : Crystal::ASTNode
      test_name = call.arg_nodes[0]?.is_a?(Prism::StringNode) ? call.arg_nodes[0].as(Prism::StringNode).value : "unnamed"
      body_nodes = [] of Crystal::ASTNode

      # Inject setup vars
      setup_vars.each do |var, value|
        # Parse the value string back since setup_vars stores strings
        body_nodes << Crystal::Assign.new(Crystal::Var.new(var), Crystal::MacroLiteral.new(value))
      end

      if block = call.block
        if block.is_a?(Prism::BlockNode) && (body = block.body)
          body_nodes.concat(build_controller_test_body(body))
        end
      end
      Crystal::Call.new(nil, "it", [Crystal::StringLiteral.new(test_name)] of Crystal::ASTNode,
        block: Crystal::Block.new(body: Crystal::Expressions.new(body_nodes)))
    end

    # --- Test body builders ---

    private def build_test_body(node : Prism::Node) : Array(Crystal::ASTNode)
      stmts = node.is_a?(Prism::StatementsNode) ? node.body : [node]
      stmts.flat_map do |stmt|
        case stmt
        when Prism::LocalVariableWriteNode
          [Crystal::Assign.new(Crystal::Var.new(stmt.name), map_node(stmt.value)).as(Crystal::ASTNode)]
        when Prism::InstanceVariableWriteNode
          [Crystal::Assign.new(Crystal::Var.new(stmt.name.lchop("@")), map_node(stmt.value)).as(Crystal::ASTNode)]
        when Prism::CallNode
          if stmt.name.starts_with?("assert")
            build_assertion(stmt)
          else
            [map_call(stmt).as(Crystal::ASTNode)]
          end
        when Prism::IfNode
          then_body = stmt.then_body ? Crystal::Expressions.new(build_test_body(stmt.then_body.not_nil!)) : Crystal::Nop.new
          [Crystal::If.new(map_node(stmt.condition), then_body).as(Crystal::ASTNode)]
        else
          [] of Crystal::ASTNode
        end
      end
    end

    private def build_controller_test_body(node : Prism::Node) : Array(Crystal::ASTNode)
      stmts = node.is_a?(Prism::StatementsNode) ? node.body : [node]
      stmts.flat_map do |stmt|
        case stmt
        when Prism::LocalVariableWriteNode
          [Crystal::Assign.new(Crystal::Var.new(stmt.name), map_node(stmt.value)).as(Crystal::ASTNode)]
        when Prism::CallNode
          case stmt.name
          when "get"    then build_http_call(stmt, "GET")
          when "post"   then build_http_call(stmt, "POST")
          when "patch"  then build_http_call(stmt, "PATCH")
          when "delete" then build_http_call(stmt, "DELETE")
          when "assert_response"      then build_response_assertion(stmt)
          when "assert_redirected_to" then wrap(build_should(Crystal::Var.new("response.status_code"), "eq", Crystal::NumberLiteral.new("302")))
          when "assert_select"        then build_assert_select(stmt)
          when "assert_difference"    then build_assert_difference(stmt, controller_test: true)
          when "assert_no_difference" then build_assert_no_difference(stmt, controller_test: true)
          else build_assertion(stmt)
          end
        else
          [] of Crystal::ASTNode
        end
      end
    end

    # --- Assertion builders ---

    private def build_assertion(call : Prism::CallNode) : Array(Crystal::ASTNode)
      args = call.arg_nodes
      case call.name
      when "assert_equal"
        wrap(build_should(map_node(args[1]), "eq", map_node(args[0])))
      when "assert_not_nil"
        wrap(build_should_not(map_node(args[0]), "be_nil"))
      when "assert_not"
        wrap(build_should(map_node(args[0]), "be_false"))
      when "assert"
        wrap(build_should(map_node(args[0]), "be_true"))
      when "assert_difference"
        build_assert_difference(call)
      when "assert_no_difference"
        build_assert_no_difference(call)
      else
        [Crystal::MacroLiteral.new("# #{call.name}(...)").as(Crystal::ASTNode)]
      end
    end

    private def build_should(actual : Crystal::ASTNode, matcher : String, expected : Crystal::ASTNode? = nil) : Crystal::ASTNode
      matcher_call = expected ? Crystal::Call.new(nil, matcher, [expected] of Crystal::ASTNode) : Crystal::Call.new(nil, matcher)
      Crystal::Call.new(actual, "should", [matcher_call] of Crystal::ASTNode)
    end

    private def build_should_not(actual : Crystal::ASTNode, matcher : String) : Crystal::ASTNode
      Crystal::Call.new(actual, "should_not", [Crystal::Call.new(nil, matcher)] of Crystal::ASTNode)
    end

    # Wrap a single ASTNode in a properly typed array
    private def wrap(node : Crystal::ASTNode) : Array(Crystal::ASTNode)
      [node] of Crystal::ASTNode
    end

    private def build_assert_difference(call : Prism::CallNode, controller_test : Bool = false) : Array(Crystal::ASTNode)
      args = call.arg_nodes
      count_expr = args[0]?.is_a?(Prism::StringNode) ? args[0].as(Prism::StringNode).value : "count"
      diff = args[1]?.is_a?(Prism::IntegerNode) ? args[1].as(Prism::IntegerNode).value : 1
      model_count = count_expr.gsub(/(\w+)\.count/) { |m| "Ruby2CR::#{m}" }

      stmts = [Crystal::Assign.new(Crystal::Var.new("before_count"), Crystal::MacroLiteral.new(model_count)).as(Crystal::ASTNode)]
      if block = call.block
        if block.is_a?(Prism::BlockNode) && (body = block.body)
          stmts.concat(controller_test ? build_controller_test_body(body) : build_test_body(body))
        end
      end
      stmts << build_should(
        Crystal::MacroLiteral.new("(#{model_count} - before_count)"),
        "eq",
        Crystal::NumberLiteral.new(diff.to_s)
      )
      stmts
    end

    private def build_assert_no_difference(call : Prism::CallNode, controller_test : Bool = false) : Array(Crystal::ASTNode)
      args = call.arg_nodes
      count_expr = args[0]?.is_a?(Prism::StringNode) ? args[0].as(Prism::StringNode).value : "count"
      model_count = count_expr.gsub(/(\w+)\.count/) { |m| "Ruby2CR::#{m}" }

      stmts = [Crystal::Assign.new(Crystal::Var.new("before_count"), Crystal::MacroLiteral.new(model_count)).as(Crystal::ASTNode)]
      if block = call.block
        if block.is_a?(Prism::BlockNode) && (body = block.body)
          stmts.concat(controller_test ? build_controller_test_body(body) : build_test_body(body))
        end
      end
      stmts << build_should(Crystal::MacroLiteral.new(model_count), "eq", Crystal::Var.new("before_count"))
      stmts
    end

    # --- HTTP call builders ---

    private def build_http_call(call : Prism::CallNode, method : String) : Array(Crystal::ASTNode)
      args = call.arg_nodes
      url = map_node(args[0])

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

      mock_args = [Crystal::StringLiteral.new(method == "GET" ? "GET" : "POST"), url] of Crystal::ASTNode

      case method
      when "GET"
        mock_args = [Crystal::StringLiteral.new("GET"), url] of Crystal::ASTNode
      when "POST"
        mock_args << (params_str ? Crystal::MacroLiteral.new(params_str) : Crystal::NilLiteral.new)
      when "PATCH"
        body = params_str ? Crystal::MacroLiteral.new("\"_method=patch&\" + #{params_str}") : Crystal::StringLiteral.new("_method=patch")
        mock_args << body
      when "DELETE"
        mock_args << Crystal::StringLiteral.new("_method=delete")
      end

      [Crystal::Assign.new(
        Crystal::Var.new("response"),
        Crystal::Call.new(nil, "mock_request", mock_args)
      ).as(Crystal::ASTNode)]
    end

    private def build_response_assertion(call : Prism::CallNode) : Array(Crystal::ASTNode)
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
      wrap(build_should(
        Crystal::Call.new(Crystal::Var.new("response"), "status_code"),
        "eq",
        Crystal::NumberLiteral.new(status.to_s)
      ))
    end

    private def build_assert_select(call : Prism::CallNode) : Array(Crystal::ASTNode)
      args = call.arg_nodes
      selector = args[0]?.is_a?(Prism::StringNode) ? args[0].as(Prism::StringNode).value : ""

      if args.size > 1 && args[1].is_a?(Prism::StringNode)
        expected = args[1].as(Prism::StringNode).value
        wrap(build_should(Crystal::Call.new(Crystal::Var.new("response"), "body"), "contain", Crystal::StringLiteral.new(expected)))
      else
        check = if selector.starts_with?("#")
                  "id=\"#{selector.lchop("#").split(" ").first.split(".").first}\""
                elsif selector.starts_with?(".")
                  selector.lchop(".")
                elsif selector.includes?("#") || selector.includes?(".")
                  selector.split(/[\s#.]/).reject(&.empty?).first
                else
                  "<#{selector}"
                end
        wrap(build_should(Crystal::Call.new(Crystal::Var.new("response"), "body"), "contain", Crystal::StringLiteral.new(check)))
      end
    end

    # --- Boilerplate builders ---

    private def build_test_response_record : Crystal::ASTNode
      Crystal::Call.new(nil, "record", [
        Crystal::Path.new("TestResponse"),
      ] of Crystal::ASTNode, named_args: [
        Crystal::NamedArgument.new("status_code", Crystal::Path.new("Int32")),
        Crystal::NamedArgument.new("headers", Crystal::Path.new(["HTTP", "Headers"])),
        Crystal::NamedArgument.new("body", Crystal::Path.new("String")),
      ])
    end

    private def build_mock_request_def : Crystal::Def
      # Build the mock_request method body as a MacroLiteral for complex logic
      body_source = <<-CR
      request = HTTP::Request.new(method, path)
      if body
        request.body = body
        request.headers["Content-Type"] = "application/x-www-form-urlencoded"
      end
      output = IO::Memory.new
      response = HTTP::Server::Response.new(output)
      context = HTTP::Server::Context.new(request, response)
      router = Ruby2CR::Router.new
      router.dispatch(context)
      response.close
      output.rewind
      TestResponse.new(response.status_code, response.headers, output.gets_to_end)
      CR

      Crystal::Def.new("mock_request", [
        Crystal::Arg.new("method", restriction: Crystal::Path.new("String")),
        Crystal::Arg.new("path", restriction: Crystal::Path.new("String")),
        Crystal::Arg.new("body", default_value: Crystal::NilLiteral.new, restriction: Crystal::Union.new([Crystal::Path.new("String"), Crystal::Path.new("Nil")] of Crystal::ASTNode)),
      ], body: Crystal::MacroLiteral.new(body_source),
        return_type: Crystal::Path.new("TestResponse"))
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
              vars[s.name.lchop("@")] = expr(s.value)
            end
          end
        end
      end
      vars
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
      end
    end
  end
end
