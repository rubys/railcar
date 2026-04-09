# Filter: Strip Rails-specific callbacks and declarations not needed in Crystal.
#
# Removes:
#   - broadcasts_to (Turbo Streams — deferred)
#   - after_create_commit, after_destroy_commit, etc. (callback hooks — deferred)
#   - rescue nil patterns in callbacks

require "compiler/crystal/syntax"

module Railcar
  class StripCallbacks < Crystal::Transformer
    STRIP_METHODS = {
      "broadcasts_to",
      "after_create_commit", "after_update_commit", "after_destroy_commit",
      "after_save_commit", "after_commit",
      "before_create", "before_update", "before_save", "before_destroy",
      "after_create", "after_update", "after_save", "after_destroy",
    }

    def transform(node : Crystal::Call) : Crystal::ASTNode
      if node.obj.nil? && STRIP_METHODS.includes?(node.name)
        Crystal::Nop.new
      else
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
end
