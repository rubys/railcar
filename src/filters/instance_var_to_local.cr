# Filter: Convert @instance_variables to local variables.
#
# In Rails controllers, @article is set for the view. In Crystal,
# ECR templates access local variables from the embedding scope.
# This filter strips the @ prefix.
#
# Input:  @article = Article.find(id)
# Output: article = Article.find(id)

require "compiler/crystal/syntax"

module Railcar
  class InstanceVarToLocal < Crystal::Transformer
    def transform(node : Crystal::InstanceVar) : Crystal::ASTNode
      Crystal::Var.new(node.name.lchop("@"))
    end

    def transform(node : Crystal::Assign) : Crystal::ASTNode
      target = node.target
      value = node.value.transform(self)

      if target.is_a?(Crystal::InstanceVar)
        Crystal::Assign.new(
          Crystal::Var.new(target.name.lchop("@")),
          value
        )
      else
        node.value = value
        node
      end
    end
  end
end
