# Filter: Convert params.expect(:id) → id
#
# Rails' params.expect extracts and validates parameters.
# In Crystal, the router already extracts params by name,
# so params.expect(:id) simply becomes the local variable `id`.
#
# Also handles params.expect(article: [:title, :body]) → params
# (strong params pattern, handled at the controller level)

require "compiler/crystal/syntax"

module Railcar
  class ParamsExpect < Crystal::Transformer
    def transform(node : Crystal::Call) : Crystal::ASTNode
      if node.name == "expect" && is_params_receiver?(node.obj)
        args = node.args
        if args.size == 1
          arg = args[0]
          case arg
          when Crystal::SymbolLiteral
            # params.expect(:id) → id
            return Crystal::Var.new(arg.value)
          end
        end
      end

      # Transform children
      node.obj = node.obj.try(&.transform(self))
      node.args = node.args.map(&.transform(self).as(Crystal::ASTNode))
      node.named_args = node.named_args.try(&.map { |na|
        Crystal::NamedArgument.new(na.name, na.value.transform(self)).as(Crystal::NamedArgument)
      })
      node.block = node.block.try(&.transform(self).as(Crystal::Block))
      node
    end

    private def is_params_receiver?(obj : Crystal::ASTNode?) : Bool
      case obj
      when Crystal::Call
        obj.name == "params" && obj.obj.nil?
      when Crystal::Var
        obj.name == "params"
      else
        false
      end
    end
  end
end
