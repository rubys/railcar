# SpecFilter — transforms Crystal spec DSL into pytest-style AST.
#
# Crystal spec pattern:
#   describe(Subject) do
#     before_each do ... end
#     it("test name") do ... end
#   end
#
# Pytest output:
#   import pytest
#   @pytest.fixture(autouse=True)
#   def setup(): ...
#   def test_<name>(): ...
#
# Assertion transforms:
#   x.should(eq(y))       → assert x == y
#   x.should_not(eq(y))   → assert x != y
#   x.should(be_nil)      → assert x is None
#   x.should_not(be_nil)  → assert x is not None
#   x.should(be_true)     → assert x is True / assert x
#   x.should(be_false)    → assert x is False / assert not x
#   x.should(contain(y))  → assert y in x

module Cr2Py
  class SpecFilter < Crystal::Transformer
    # Transform a describe block into a list of pytest functions
    def transform(node : Crystal::Call) : Crystal::ASTNode
      return super unless node.name == "describe" && node.block

      block = node.block.not_nil!
      body = block.body

      stmts = case body
              when Crystal::Expressions then body.expressions
              else [body]
              end

      result = [] of Crystal::ASTNode

      # Collect before_each body and it blocks
      setup_body = nil
      stmts.each do |stmt|
        next unless stmt.is_a?(Crystal::Call) && stmt.block

        case stmt.name
        when "before_each"
          setup_body = stmt.block.not_nil!.body
        when "it"
          test_name = build_test_name(stmt.args)
          test_body = transform_test_body(stmt.block.not_nil!.body)

          # If there's a setup, inline it at the top of each test
          if sb = setup_body
            test_body = merge_setup(sb, test_body)
          end

          # Build: def test_<name>():
          result << Crystal::Def.new(test_name, body: test_body)
        end
      end

      Crystal::Expressions.new(result)
    end

    def transform(node : Crystal::ASTNode) : Crystal::ASTNode
      super
    end

    # --- Test name ---

    private def build_test_name(args : Array(Crystal::ASTNode)) : String
      raw = if args.first?.is_a?(Crystal::StringLiteral)
              args.first.as(Crystal::StringLiteral).value
            else
              "unnamed"
            end

      "test_" + raw
        .downcase
        .gsub(/[^a-z0-9]+/, "_")
        .strip('_')
    end

    # --- Transform test body ---

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
        # Check for .should / .should_not chains
        if node.name == "should" && node.obj && node.args.size == 1
          return build_assert(node.obj.not_nil!, node.args[0], positive: true)
        end
        if node.name == "should_not" && node.obj && node.args.size == 1
          return build_assert(node.obj.not_nil!, node.args[0], positive: false)
        end
        node
      when Crystal::Assign
        # Transform the value side (might contain .should chains)
        Crystal::Assign.new(node.target, transform_stmt(node.value))
      else
        node
      end
    end

    # --- Assert builders ---

    # Build an assert statement from actual.should(matcher)
    private def build_assert(actual : Crystal::ASTNode, matcher : Crystal::ASTNode, positive : Bool) : Crystal::ASTNode
      case matcher
      when Crystal::Call
        case matcher.name
        when "eq"
          # assert actual == expected / assert actual != expected
          expected = matcher.args[0]
          op = positive ? "==" : "!="
          Crystal::Call.new(nil, "assert",
            [Crystal::Call.new(actual, op, [expected] of Crystal::ASTNode)] of Crystal::ASTNode)

        when "be_nil"
          # assert actual is None / assert actual is not None
          if positive
            Crystal::Call.new(nil, "assert",
              [Crystal::Call.new(actual, "is", [Crystal::NilLiteral.new] of Crystal::ASTNode)] of Crystal::ASTNode)
          else
            # Use "is not" as a single operator to avoid precedence issues
            Crystal::Call.new(nil, "assert",
              [Crystal::Call.new(actual, "is not", [Crystal::NilLiteral.new] of Crystal::ASTNode)] of Crystal::ASTNode)
          end

        when "be_true"
          if positive
            Crystal::Call.new(nil, "assert", [actual] of Crystal::ASTNode)
          else
            Crystal::Call.new(nil, "assert",
              [Crystal::Not.new(actual)] of Crystal::ASTNode)
          end

        when "be_false"
          if positive
            Crystal::Call.new(nil, "assert",
              [Crystal::Not.new(actual)] of Crystal::ASTNode)
          else
            Crystal::Call.new(nil, "assert", [actual] of Crystal::ASTNode)
          end

        when "contain"
          # assert expected in actual / assert expected not in actual
          expected = matcher.args[0]
          if positive
            Crystal::Call.new(nil, "assert",
              [Crystal::Call.new(expected, "in", [actual] of Crystal::ASTNode)] of Crystal::ASTNode)
          else
            Crystal::Call.new(nil, "assert",
              [Crystal::Call.new(expected, "not in", [actual] of Crystal::ASTNode)] of Crystal::ASTNode)
          end

        else
          # Unknown matcher — pass through as comment
          Crystal::MacroLiteral.new("# TODO: #{positive ? "should" : "should_not"}(#{matcher.name})\n")
        end
      else
        Crystal::MacroLiteral.new("# TODO: unknown matcher\n")
      end
    end

    # --- Merge setup into test body ---

    private def merge_setup(setup : Crystal::ASTNode, test_body : Crystal::ASTNode) : Crystal::ASTNode
      setup_stmts = case setup
                    when Crystal::Expressions then setup.expressions.dup
                    else [setup]
                    end
      test_stmts = case test_body
                   when Crystal::Expressions then test_body.expressions.dup
                   else [test_body]
                   end

      Crystal::Expressions.new(setup_stmts + test_stmts)
    end
  end
end
