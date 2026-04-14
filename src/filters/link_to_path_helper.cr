# Filter: Rewrite link_to model references to path helper calls.
#
# Input:  link_to("Show", @article, class: "btn")
# Output: link_to("Show", article_path(article), class: "btn")
#
# Handles instance variables, local variables, and bare method calls
# as the target argument, converting them to *_path helper calls.

require "compiler/crystal/syntax"
require "./path_helper_utils"

module Railcar
  class LinkToPathHelper < Crystal::Transformer
    include PathHelperUtils

    def transform(node : Crystal::Call) : Crystal::ASTNode
      if node.name == "link_to" && node.args.size >= 2
        args = node.args.dup
        args[1] = model_to_path(args[1])
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
  end
end
