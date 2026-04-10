# Filter: Convert Ruby .new() constructor calls to Python-style direct calls.
#
# Input:  Article.new(title: "Hello")
# Output: Article(title: "Hello")
#
# Ruby uses ClassName.new(...) while Python uses ClassName(...).

require "compiler/crystal/syntax"

module Railcar
  class PythonConstructor < Crystal::Transformer
    def transform(node : Crystal::Call) : Crystal::ASTNode
      if node.name == "new"
        receiver = node.obj
        if receiver.is_a?(Crystal::Path)
          # Article.new(args) → Article(args)
          # Transform args first
          args = node.args.map { |a| a.transform(self) }
          named = node.named_args.try(&.map { |na|
            Crystal::NamedArgument.new(na.name, na.value.transform(self))
          })
          return Crystal::Call.new(nil, receiver.names.join("."), args,
            named_args: named, block: node.block)
        end
      end

      node.obj = node.obj.try(&.transform(self))
      node.args = node.args.map { |a| a.transform(self) }
      if named = node.named_args
        node.named_args = named.map { |na|
          Crystal::NamedArgument.new(na.name, na.value.transform(self))
        }
      end
      if block = node.block
        node.block = block.transform(self).as(Crystal::Block)
      end
      node
    end
  end
end
