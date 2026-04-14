# Filter: Rewrite button_to model references to path helper calls.
#
# Input:  button_to("Delete", @article, method: :delete)
# Output: button_to("Delete", article_path(article), method: :delete)
#
# Also handles array targets for nested resources:
# Input:  button_to("Delete", [comment.article, comment], method: :delete)
# Output: button_to("Delete", article_comment_path(comment.article, comment), method: :delete)

require "compiler/crystal/syntax"
require "./path_helper_utils"

module Railcar
  class ButtonToPathHelper < Crystal::Transformer
    include PathHelperUtils

    def transform(node : Crystal::Call) : Crystal::ASTNode
      if node.name == "button_to" && node.args.size >= 2
        args = node.args.dup
        target = args[1]

        args[1] = if target.is_a?(Crystal::ArrayLiteral) && target.elements.size == 2
                    parent = target.elements[0]
                    child = target.elements[1]
                    parent_name = extract_resource_name(parent)
                    child_name = extract_resource_name(child)
                    Crystal::Call.new(nil, "#{parent_name}_#{child_name}_path",
                      [parent, child] of Crystal::ASTNode)
                  else
                    model_to_path(target)
                  end
        node.args = args

        # Convert symbol values to strings and flatten data: hash
        if named = node.named_args
          new_named = [] of Crystal::NamedArgument
          named.each do |na|
            if na.name == "data" && na.value.is_a?(Crystal::HashLiteral)
              # Flatten data: {turbo_confirm: "..."} → data_turbo_confirm: "..."
              na.value.as(Crystal::HashLiteral).entries.each do |entry|
                key_name = case entry.key
                           when Crystal::SymbolLiteral then entry.key.as(Crystal::SymbolLiteral).value
                           when Crystal::StringLiteral then entry.key.as(Crystal::StringLiteral).value
                           else entry.key.to_s
                           end
                new_named << Crystal::NamedArgument.new("data_#{key_name}", entry.value).as(Crystal::NamedArgument)
              end
            else
              value = na.value.is_a?(Crystal::SymbolLiteral) ? Crystal::StringLiteral.new(na.value.as(Crystal::SymbolLiteral).value).as(Crystal::ASTNode) : na.value
              new_named << Crystal::NamedArgument.new(na.name, value).as(Crystal::NamedArgument)
            end
          end
          node.named_args = new_named
        end
      end
      node.obj = node.obj.try(&.transform(self))
      node.args = node.args.map(&.transform(self).as(Crystal::ASTNode))
      node.named_args = node.named_args.try(&.map { |na|
        Crystal::NamedArgument.new(na.name, na.value.transform(self)).as(Crystal::NamedArgument)
      })
      node.block = node.block.try(&.transform(self).as(Crystal::Block))
      node
    end
  end
end
