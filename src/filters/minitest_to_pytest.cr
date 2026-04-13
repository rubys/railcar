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

      exprs.each do |expr|
        if expr.is_a?(Crystal::Call) && expr.name == "test" && expr.block
          stmts << transform_test_block(expr)
        end
        # Skip setup/teardown for now — fixtures handled by conftest
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

    # Transform: test("name") do ... end → def test_name(): ...
    private def transform_test_block(call : Crystal::Call) : Crystal::Def
      # Extract test name
      raw_name = if call.args.first?.is_a?(Crystal::StringLiteral)
                   call.args.first.as(Crystal::StringLiteral).value
                 else
                   "unnamed"
                 end
      func_name = "test_" + raw_name.downcase.gsub(/[^a-z0-9]+/, "_").strip('_')

      # Transform block body
      block = call.block.not_nil!
      body = transform_test_body(block.body)

      Crystal::Def.new(func_name, body: body)
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
        # assert_no_difference("Model.count") { ... } →
        #   before = Model.count(); ...; assert Model.count() == before
        transform_assert_no_difference(node)

      else
        # Transform fixture references: articles(:one) → articles("one")
        new_args = args.map { |a| transform_fixture_arg(a) }
        new_obj = obj ? transform_stmt(obj).as(Crystal::ASTNode) : nil

        # Transform named args (keyword args like title: "x")
        named = node.named_args

        if new_obj || new_args != args || named
          Crystal::Call.new(new_obj, name, new_args, named_args: named, block: node.block)
        else
          node
        end
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
