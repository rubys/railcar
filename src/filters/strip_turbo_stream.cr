# Filter: Strip turbo_stream_from and content_for calls.
#
# These are placeholders — turbo_stream_from will be replaced with a real
# TurboStream filter once WebSocket support is implemented.
#
# Input:  turbo_stream_from("articles")
# Output: (removed)

require "compiler/crystal/syntax"

module Railcar
  class StripTurboStream < Crystal::Transformer
    def transform(node : Crystal::Call) : Crystal::ASTNode
      case node.name
      when "turbo_stream_from", "content_for"
        Crystal::Nop.new
      else
        node.obj = node.obj.try(&.transform(self))
        node.args = node.args.map(&.transform(self).as(Crystal::ASTNode))
        node.block = node.block.try(&.transform(self).as(Crystal::Block))
        node
      end
    end
  end
end
