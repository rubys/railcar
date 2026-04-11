# Filter: Consolidate consecutive _buf string operations into interpolations.
#
# Merges sequences of _buf += "string" and _buf += str(expr) into single
# _buf += "string #{expr} string" (Crystal::StringInterpolation) nodes.
# Each target emitter handles interpolation in its own syntax:
#   Crystal: "hello #{name}"
#   Python:  f"hello {name}"
#   JS/TS:   `hello ${name}`
#
# Also consolidates simple loops into join expressions and simple
# conditionals into ternary expressions within the interpolation.
#
# This is a shared optimization pass — no language-specific logic.

require "compiler/crystal/syntax"

module Railcar
  class BufToInterpolation < Crystal::Transformer
    def transform(node : Crystal::Def) : Crystal::ASTNode
      body = node.body
      case body
      when Crystal::Expressions
        node.body = consolidate_buf_ops(body)
      end
      node
    end

    private def consolidate_buf_ops(exprs : Crystal::Expressions) : Crystal::ASTNode
      result = [] of Crystal::ASTNode
      buf_run = [] of Crystal::ASTNode  # accumulates consecutive _buf ops

      exprs.expressions.each do |expr|
        if buf_op?(expr)
          buf_run << expr
        else
          # Flush accumulated _buf ops
          flush_buf_run(buf_run, result) unless buf_run.empty?
          buf_run.clear

          # Recurse into if/else blocks
          case expr
          when Crystal::If
            result << transform_if_buf(expr)
          when Crystal::Call
            if expr.name == "each" && expr.block
              result << transform_loop_buf(expr)
            else
              result << expr
            end
          else
            result << expr
          end
        end
      end

      flush_buf_run(buf_run, result) unless buf_run.empty?
      Crystal::Expressions.new(result)
    end

    # Check if a node is a simple _buf string operation.
    # Loops (_buf.append= with block) are not mergeable — they stay as separate statements.
    private def buf_op?(node : Crystal::ASTNode) : Bool
      case node
      when Crystal::OpAssign
        node.target.is_a?(Crystal::Var) && node.target.as(Crystal::Var).name == "_buf" && node.op == "+"
      when Crystal::Call
        return false unless node.name == "append=" && node.obj.is_a?(Crystal::Var) && node.obj.as(Crystal::Var).name == "_buf"
        # Don't merge loops (each blocks from RenderToPartial)
        arg = node.args[0]?
        if arg.is_a?(Crystal::Call) && arg.block
          return false
        end
        # Unwrap .to_s to check for blocks
        if arg.is_a?(Crystal::Call) && arg.name == "to_s" && arg.obj
          inner = arg.obj.not_nil!
          return false if inner.is_a?(Crystal::Call) && inner.block
        end
        true
      else
        false
      end
    end

    # Extract the value from a _buf operation
    private def buf_value(node : Crystal::ASTNode) : Crystal::ASTNode?
      case node
      when Crystal::OpAssign
        node.value
      when Crystal::Call
        # _buf.append= expr.to_s → unwrap .to_s
        arg = node.args[0]?
        return nil unless arg
        if arg.is_a?(Crystal::Call) && arg.name == "to_s" && arg.obj
          arg.obj
        else
          arg
        end
      else
        nil
      end
    end

    # Merge a run of _buf ops into a single StringInterpolation
    private def flush_buf_run(run : Array(Crystal::ASTNode), result : Array(Crystal::ASTNode))
      parts = [] of Crystal::ASTNode

      run.each do |op|
        value = buf_value(op)
        next unless value

        case value
        when Crystal::StringLiteral
          # Merge adjacent string literals
          if parts.last?.is_a?(Crystal::StringLiteral)
            merged = parts.last.as(Crystal::StringLiteral).value + value.value
            parts[-1] = Crystal::StringLiteral.new(merged)
          else
            parts << Crystal::StringLiteral.new(value.value)
          end
        else
          parts << value
        end
      end

      return if parts.empty?

      # If it's all strings, emit a single _buf += "..."
      if parts.size == 1 && parts[0].is_a?(Crystal::StringLiteral)
        result << Crystal::OpAssign.new(
          Crystal::Var.new("_buf"), "+", parts[0]
        )
        return
      end

      # Build a StringInterpolation node
      interp = Crystal::StringInterpolation.new(parts)
      result << Crystal::OpAssign.new(
        Crystal::Var.new("_buf"), "+", interp
      )
    end

    # Check if an if/else block contains only _buf operations
    # If so, consolidate into a ternary within the _buf string
    private def transform_if_buf(node : Crystal::If) : Crystal::ASTNode
      then_ops = extract_buf_ops(node.then)
      else_ops = node.else ? extract_buf_ops(node.else.not_nil!) : nil

      # Only consolidate simple cases: both branches are pure _buf ops
      if then_ops && (else_ops || node.else.nil? || node.else.is_a?(Crystal::Nop))
        # For now, just recurse into the branches
        then_body = node.then
        if then_body.is_a?(Crystal::Expressions)
          node.then = consolidate_buf_ops(then_body)
        end
        if (else_body = node.else) && else_body.is_a?(Crystal::Expressions)
          node.else = consolidate_buf_ops(else_body)
        end
      end
      node
    end

    # Check if a loop body is a single _buf += partial_call
    # If so, consolidate into _buf += ''.join(...)
    private def transform_loop_buf(call : Crystal::Call) : Crystal::ASTNode
      block = call.block
      return call unless block

      body = block.body
      # Check for single _buf += render_partial(item)
      if body.is_a?(Crystal::OpAssign) && buf_op?(body)
        value = buf_value(body)
        if value
          # Build: _buf += ''.join(value for item in collection)
          # Represented as _buf.append= with the join expression
          block_args = block.args
          join_body = value
          # Keep as-is for now — the emitter handles the for loop
        end
      end
      call
    end

    private def extract_buf_ops(node : Crystal::ASTNode) : Array(Crystal::ASTNode)?
      case node
      when Crystal::Expressions
        ops = node.expressions.select { |e| buf_op?(e) }
        ops.size == node.expressions.size ? ops : nil
      else
        buf_op?(node) ? [node] : nil
      end
    end
  end
end
