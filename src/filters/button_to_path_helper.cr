# Filter: Rewrite button_to model references to path helper calls.
#
# Input:  button_to("Delete", @article, method: :delete)
# Output: button_to("Delete", article_path(article), method: :delete)
#
# Also handles array targets for nested resources:
# Input:  button_to("Delete", [comment.article, comment], method: :delete)
# Output: button_to("Delete", article_comment_path(comment.article, comment), method: :delete)

require "compiler/crystal/syntax"

module Ruby2CR
  class ButtonToPathHelper < Crystal::Transformer
    def transform(node : Crystal::Call) : Crystal::ASTNode
      if node.name == "button_to" && node.args.size >= 2
        args = node.args.dup
        target = args[1]

        args[1] = if target.is_a?(Crystal::ArrayLiteral) && target.elements.size == 2
                    parent = target.elements[0]
                    child = target.elements[1]
                    parent_name = extract_name(parent)
                    child_name = extract_name(child)
                    Crystal::Call.new(nil, "#{parent_name}_#{child_name}_path",
                      [parent, child] of Crystal::ASTNode)
                  else
                    model_to_path(target)
                  end
        node.args = args
      end
      node.obj = node.obj.try(&.transform(self))
      node.args = node.args.map(&.transform(self).as(Crystal::ASTNode))
      node.named_args = node.named_args.try(&.map { |na|
        Crystal::NamedArgument.new(na.name, na.value.transform(self)).as(Crystal::NamedArgument)
      })
      node.block = node.block.try(&.transform(self).as(Crystal::Block))
      node
    end

    private def model_to_path(node : Crystal::ASTNode) : Crystal::ASTNode
      case node
      when Crystal::InstanceVar
        name = node.name.lchop("@")
        Crystal::Call.new(nil, "#{name}_path", [Crystal::Var.new(name)] of Crystal::ASTNode)
      when Crystal::Var
        name = node.name
        return node if name.ends_with?("_path")
        Crystal::Call.new(nil, "#{name}_path", [node] of Crystal::ASTNode)
      when Crystal::Call
        if node.obj.nil? && node.args.empty?
          name = node.name
          return node if name.ends_with?("_path")
          Crystal::Call.new(nil, "#{name}_path", [node] of Crystal::ASTNode)
        else
          node
        end
      else
        node
      end
    end

    private def extract_name(node : Crystal::ASTNode) : String
      case node
      when Crystal::InstanceVar then node.name.lchop("@")
      when Crystal::Var then node.name
      when Crystal::Call
        if node.obj
          # comment.article → "article"
          node.name
        else
          node.name
        end
      else
        node.to_s
      end
    end
  end
end
