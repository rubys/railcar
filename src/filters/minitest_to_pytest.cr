# Filter: Transform Rails Minitest AST to pytest-shaped Crystal AST.
#
# Input (Crystal AST translated from Ruby via Prism):
#   class ArticleTest < ActiveSupport::TestCase
#     test("creates an article") do
#       article = articles(:one)
#       assert_not_nil(article.id)
#       assert_equal("expected", article.title)
#     end
#   end
#
# Output (Crystal AST that cr2py emits as pytest):
#   def test_creates_an_article():
#     article = articles("one")
#     assert article.id is not None
#     assert article.title == "expected"

require "compiler/crystal/syntax"
require "../generator/inflector"

module Railcar
  class MinitestToPytest < Crystal::Transformer
    # Transform the test class into top-level test functions
    def transform(node : Crystal::ClassDef) : Crystal::ASTNode
      # Only transform test classes
      return super unless test_class?(node)

      stmts = [] of Crystal::ASTNode

      body = node.body
      exprs = case body
              when Crystal::Expressions then body.expressions
              else [body]
              end

      # Collect setup block body
      setup_stmts = [] of Crystal::ASTNode
      exprs.each do |expr|
        if expr.is_a?(Crystal::Call) && expr.name == "setup" && expr.block
          setup_body = expr.block.not_nil!.body
          case setup_body
          when Crystal::Expressions
            setup_body.expressions.each { |e| setup_stmts << transform_stmt(e) unless e.is_a?(Crystal::Nop) }
          when Crystal::Nop
          else
            setup_stmts << transform_stmt(setup_body)
          end
        end
      end

      # Check if this is an integration test
      is_integration = node.superclass.to_s.includes?("IntegrationTest")

      exprs.each do |expr|
        if expr.is_a?(Crystal::Call) && expr.name == "test" && expr.block
          stmts << transform_test_block(expr, setup_stmts, is_integration)
        end
      end

      Crystal::Expressions.new(stmts)
    end

    # Strip require("test_helper")
    def transform(node : Crystal::Call) : Crystal::ASTNode
      if node.name == "require" && !node.obj
        if arg = node.args.first?
          if arg.is_a?(Crystal::StringLiteral) && arg.value == "test_helper"
            return Crystal::Nop.new
          end
        end
      end
      super
    end

    def transform(node : Crystal::ASTNode) : Crystal::ASTNode
      super
    end

    private def test_class?(node : Crystal::ClassDef) : Bool
      sc = node.superclass
      return false unless sc
      sc.to_s.includes?("TestCase") || sc.to_s.includes?("IntegrationTest")
    end

    private def transform_test_block(call : Crystal::Call,
                                      setup_stmts : Array(Crystal::ASTNode),
                                      is_integration : Bool) : Crystal::Def
      raw_name = if call.args.first?.is_a?(Crystal::StringLiteral)
                   call.args.first.as(Crystal::StringLiteral).value
                 else
                   "unnamed"
                 end
      func_name = "test_" + raw_name.downcase.gsub(/[^a-z0-9]+/, "_").strip('_')

      block = call.block.not_nil!
      body = transform_test_body(block.body)

      # Build function body: setup + test body
      all_stmts = [] of Crystal::ASTNode

      # For integration tests, create test client from app
      if is_integration
        all_stmts << Crystal::Assign.new(
          Crystal::Var.new("client"),
          Crystal::Call.new(nil, "aiohttp_client",
            [Crystal::Call.new(Crystal::Var.new("app_module"), "create_app")] of Crystal::ASTNode))
      end

      # Inline setup block
      setup_stmts.each { |s| all_stmts << s }

      # Add test body
      case body
      when Crystal::Expressions
        body.as(Crystal::Expressions).expressions.each { |e| all_stmts << e unless e.is_a?(Crystal::Nop) }
      when Crystal::Nop
      else
        all_stmts << body
      end

      # For integration tests, add body extraction after response
      if is_integration
        # Find first assert after a get/post and add body = response.text
        needs_body = all_stmts.any? { |s| s.to_s.includes?("body") }
        if needs_body
          # Insert body extraction after the first response assignment
          idx = all_stmts.index { |s| s.is_a?(Crystal::Assign) && s.target.to_s == "response" }
          if idx
            all_stmts.insert(idx + 1, Crystal::Assign.new(
              Crystal::Var.new("body"),
              Crystal::Call.new(Crystal::Var.new("response"), "text")
            ))
          end
        end
      end

      args = is_integration ? [Crystal::Arg.new("aiohttp_client")] : [] of Crystal::Arg
      Crystal::Def.new(func_name, args, Crystal::Expressions.new(all_stmts))
    end

    # Transform test body expressions
    private def transform_test_body(node : Crystal::ASTNode) : Crystal::ASTNode
      case node
      when Crystal::Expressions
        Crystal::Expressions.new(node.expressions.map { |e| transform_stmt(e) })
      else
        transform_stmt(node)
      end
    end

    private def transform_stmt(node : Crystal::ASTNode) : Crystal::ASTNode
      case node
      when Crystal::Call
        transform_call(node)
      when Crystal::Assign
        # Transform value side (might contain fixture references)
        Crystal::Assign.new(node.target, transform_stmt(node.value))
      else
        node
      end
    end

    private def transform_call(node : Crystal::Call) : Crystal::ASTNode
      name = node.name
      args = node.args
      obj = node.obj

      case name
      when "assert_equal"
        # assert_equal(expected, actual) → assert actual == expected
        expected = transform_stmt(args[0])
        actual = transform_stmt(args[1])
        Crystal::Call.new(nil, "assert",
          [Crystal::Call.new(actual, "==", [expected] of Crystal::ASTNode)] of Crystal::ASTNode)

      when "assert_not_nil"
        # assert_not_nil(x) → assert x is not None
        actual = transform_stmt(args[0])
        Crystal::Call.new(nil, "assert",
          [Crystal::Call.new(actual, "is not", [Crystal::NilLiteral.new] of Crystal::ASTNode)] of Crystal::ASTNode)

      when "assert_not", "assert_false"
        # assert_not(x) → assert not x
        actual = transform_stmt(args[0])
        Crystal::Call.new(nil, "assert",
          [Crystal::Not.new(actual)] of Crystal::ASTNode)

      when "assert"
        # assert(x) → assert x
        actual = transform_stmt(args[0])
        Crystal::Call.new(nil, "assert", [actual] of Crystal::ASTNode)

      when "assert_difference"
        # assert_difference("Model.count", n) { ... } →
        #   before = Model.count(); ...; assert Model.count() - before == n
        transform_assert_difference(node)

      when "assert_no_difference"
        transform_assert_no_difference(node)

      # --- Integration test patterns ---

      when "get"
        # get(url) → response = await client.get(url)
        url = transform_stmt(args[0])
        Crystal::Assign.new(Crystal::Var.new("response"),
          Crystal::Call.new(Crystal::Var.new("client"), "get", [url] of Crystal::ASTNode))

      when "post"
        # post(url, params: {article: {title: "x"}}) → response = await client.post(url, data=...)
        url = transform_stmt(args[0])
        post_args = [url] of Crystal::ASTNode
        if named = node.named_args
          named.each do |na|
            if na.name == "params"
              post_args << Crystal::Call.new(nil, "encode_params", [na.value] of Crystal::ASTNode)
            end
          end
        end
        Crystal::Assign.new(Crystal::Var.new("response"),
          Crystal::Call.new(Crystal::Var.new("client"), "post", post_args))

      when "patch"
        url = transform_stmt(args[0])
        patch_args = [url] of Crystal::ASTNode
        if named = node.named_args
          named.each do |na|
            if na.name == "params"
              patch_args << Crystal::Call.new(nil, "encode_params", [na.value] of Crystal::ASTNode)
            end
          end
        end
        Crystal::Assign.new(Crystal::Var.new("response"),
          Crystal::Call.new(Crystal::Var.new("client"), "patch", patch_args))

      when "delete"
        url = transform_stmt(args[0])
        Crystal::Assign.new(Crystal::Var.new("response"),
          Crystal::Call.new(Crystal::Var.new("client"), "delete", [url] of Crystal::ASTNode))

      when "assert_response"
        # assert_response(:success) → assert response.status == 200
        status = case args[0].to_s.strip(':').strip('"')
                 when "success"              then "200"
                 when "unprocessable_entity" then "422"
                 when "redirect"             then "302"
                 else "200"
                 end
        Crystal::Call.new(nil, "assert",
          [Crystal::Call.new(
            Crystal::Call.new(Crystal::Var.new("response"), "status"),
            "==",
            [Crystal::NumberLiteral.new(status)] of Crystal::ASTNode
          )] of Crystal::ASTNode)

      when "assert_redirected_to"
        # assert_redirected_to(url) → assert response.status in [301, 302, 303]
        Crystal::Call.new(nil, "assert",
          [Crystal::Call.new(
            Crystal::Call.new(Crystal::Var.new("response"), "status"),
            "in",
            [Crystal::ArrayLiteral.new([
              Crystal::NumberLiteral.new("301"),
              Crystal::NumberLiteral.new("302"),
              Crystal::NumberLiteral.new("303"),
            ] of Crystal::ASTNode)] of Crystal::ASTNode
          )] of Crystal::ASTNode)

      when "assert_select"
        # assert_select("selector", "text") → assert "text" in body
        if args.size >= 2 && args[1].is_a?(Crystal::StringLiteral)
          text = args[1].as(Crystal::StringLiteral).value
          Crystal::Call.new(nil, "assert",
            [Crystal::Call.new(
              Crystal::StringLiteral.new(text), "in",
              [Crystal::Var.new("body")] of Crystal::ASTNode
            )] of Crystal::ASTNode)
        elsif args.size == 1
          # assert_select("selector") → assert "selector-fragment" in body
          selector = args[0].to_s.strip('"')
          # Convert CSS selector to a string fragment to search for
          fragment = if selector.starts_with?("#")
                       "id=\"#{selector.lstrip('#')}\""
                     elsif selector.starts_with?(".")
                       "class=\"#{selector.lstrip('.')}"
                     else
                       "<#{selector}"
                     end
          Crystal::Call.new(nil, "assert",
            [Crystal::Call.new(
              Crystal::StringLiteral.new(fragment), "in",
              [Crystal::Var.new("body")] of Crystal::ASTNode
            )] of Crystal::ASTNode)
        else
          node  # pass through
        end

      else
        # Transform _url to _path
        call_name = name.ends_with?("_url") ? name.chomp("_url") + "_path" : name

        # Transform fixture references: articles(:one) → articles("one")
        new_args = args.map { |a| transform_fixture_arg(a) }
        new_obj = obj ? transform_stmt(obj).as(Crystal::ASTNode) : nil

        named = node.named_args

        Crystal::Call.new(new_obj, call_name, new_args, named_args: named, block: node.block)
      end
    end

    # Convert symbol args to string args (fixture references)
    private def transform_fixture_arg(node : Crystal::ASTNode) : Crystal::ASTNode
      if node.is_a?(Crystal::SymbolLiteral)
        Crystal::StringLiteral.new(node.value)
      else
        transform_stmt(node)
      end
    end

    # assert_difference("Model.count", -1) { article.destroy }
    # →
    # before_count = Model.count()
    # article.destroy
    # assert Model.count() - before_count == -1
    private def transform_assert_difference(node : Crystal::Call) : Crystal::ASTNode
      args = node.args
      expr_str = args[0].is_a?(Crystal::StringLiteral) ? args[0].as(Crystal::StringLiteral).value : "count"
      diff = args[1]? || Crystal::NumberLiteral.new("1")

      # Parse the expression string as a Crystal call
      count_call = Crystal::Parser.parse(expr_str)

      stmts = [] of Crystal::ASTNode
      stmts << Crystal::Assign.new(Crystal::Var.new("_before_count"), count_call)

      # Emit block body
      if block = node.block
        case block.body
        when Crystal::Expressions
          block.body.as(Crystal::Expressions).expressions.each { |e| stmts << transform_stmt(e) }
        else
          stmts << transform_stmt(block.body)
        end
      end

      # assert count() - before == diff
      stmts << Crystal::Call.new(nil, "assert",
        [Crystal::Call.new(
          Crystal::Call.new(count_call.clone, "-", [Crystal::Var.new("_before_count")] of Crystal::ASTNode),
          "==",
          [diff] of Crystal::ASTNode
        )] of Crystal::ASTNode)

      Crystal::Expressions.new(stmts)
    end

    private def transform_assert_no_difference(node : Crystal::Call) : Crystal::ASTNode
      args = node.args
      expr_str = args[0].is_a?(Crystal::StringLiteral) ? args[0].as(Crystal::StringLiteral).value : "count"
      count_call = Crystal::Parser.parse(expr_str)

      stmts = [] of Crystal::ASTNode
      stmts << Crystal::Assign.new(Crystal::Var.new("_before_count"), count_call)

      if block = node.block
        case block.body
        when Crystal::Expressions
          block.body.as(Crystal::Expressions).expressions.each { |e| stmts << transform_stmt(e) }
        else
          stmts << transform_stmt(block.body)
        end
      end

      stmts << Crystal::Call.new(nil, "assert",
        [Crystal::Call.new(count_call.clone, "==", [Crystal::Var.new("_before_count")] of Crystal::ASTNode)] of Crystal::ASTNode)

      Crystal::Expressions.new(stmts)
    end
  end
end
