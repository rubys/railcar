# Filter: Clean up ErbCompiler Crystal AST output for Python emission.
#
# ErbCompiler produces Ruby-style _buf code:
#   def render
#     _buf = ::String.new
#     _buf.append= (expr).to_s
#     _buf += "literal"
#     _buf.to_s
#   end
#
# This filter transforms it to clean Crystal that emits well:
#   _buf = ""
#   _buf << str(expr)
#   _buf += "literal"
#   return _buf

require "compiler/crystal/syntax"

module Railcar
  class ViewCleanup < Crystal::Transformer
    # Transform def render body but keep the wrapper (for BufToInterpolation)
    def transform(node : Crystal::Def) : Crystal::ASTNode
      if node.name == "render"
        node.body = transform(node.body)
        node
      else
        super
      end
    end

    # Transform _buf operations
    def transform(node : Crystal::Assign) : Crystal::ASTNode
      target = node.target
      value = node.value

      # _buf = ::String.new → _buf = ""
      if target.is_a?(Crystal::Var) && target.name == "_buf"
        if value.is_a?(Crystal::Call) && value.name == "new"
          return Crystal::Assign.new(target, Crystal::StringLiteral.new(""))
        end
      end

      # _buf.append= (expr).to_s → _buf += str(expr)
      if target.is_a?(Crystal::Call) && target.name == "append=" &&
         target.obj.is_a?(Crystal::Var) && target.obj.as(Crystal::Var).name == "_buf"
        expr = strip_to_s(value)
        return Crystal::OpAssign.new(
          Crystal::Var.new("_buf"), "+",
          Crystal::Call.new(nil, "str", [expr.transform(self)] of Crystal::ASTNode)
        )
      end

      super
    end

    # _buf.append= expr → _buf += str(expr)
    def transform(node : Crystal::Call) : Crystal::ASTNode
      if node.name == "append=" && node.obj.is_a?(Crystal::Var) &&
         node.obj.as(Crystal::Var).name == "_buf" && node.args.size == 1
        expr = strip_to_s(node.args[0])
        return Crystal::OpAssign.new(
          Crystal::Var.new("_buf"), "+",
          Crystal::Call.new(nil, "str", [expr.transform(self)] of Crystal::ASTNode)
        )
      end
      if node.name == "to_s" && node.obj.is_a?(Crystal::Var) &&
         node.obj.as(Crystal::Var).name == "_buf" && node.args.empty?
        return Crystal::Var.new("_buf")
      end

      # str(_buf) → _buf
      if node.name == "to_s" && node.args.empty? && node.obj.is_a?(Crystal::Var)
        return node.obj.not_nil!
      end

      super
    end

    def transform(node : Crystal::ASTNode) : Crystal::ASTNode
      super
    end

    # Convert bare Call nodes matching known variable names to Var nodes
    def self.calls_to_vars(node : Crystal::ASTNode, var_names : Array(String)) : Crystal::ASTNode
      transformer = CallToVar.new(var_names)
      node.transform(transformer)
    end

    private class CallToVar < Crystal::Transformer
      def initialize(@var_names : Array(String))
      end

      def transform(node : Crystal::Call) : Crystal::ASTNode
        # Bare call (no obj, no args) matching a known variable name → Var
        if !node.obj && node.args.empty? && !node.block && @var_names.includes?(node.name)
          return Crystal::Var.new(node.name)
        end
        super
      end

      def transform(node : Crystal::ASTNode) : Crystal::ASTNode
        super
      end
    end

    private def strip_to_s(node : Crystal::ASTNode) : Crystal::ASTNode
      if node.is_a?(Crystal::Call) && node.name == "to_s" && node.obj && node.args.empty?
        node.obj.not_nil!
      else
        node
      end
    end
  end
end
