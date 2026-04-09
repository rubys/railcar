# Filter: Convert turbo_stream_from to turbo-cable-stream-source elements.
#
# Input (Crystal AST from ERB):
#   turbo_stream_from("articles")
#   turbo_stream_from("article_#{article.id}_comments")
#
# Output (Crystal AST that emits HTML):
#   <turbo-cable-stream-source channel="Turbo::StreamsChannel"
#     signed-stream-name="base64(channel_name)">
#   </turbo-cable-stream-source>
#
# Turbo's JavaScript handles the WebSocket connection automatically
# when it sees this element in the DOM.

require "compiler/crystal/syntax"

module Railcar
  class TurboStreamConnect < Crystal::Transformer
    def transform(node : Crystal::Call) : Crystal::ASTNode
      if node.name == "turbo_stream_from" && node.obj.nil?
        convert_to_element(node)
      elsif node.name == "content_for" && node.obj.nil?
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

    private def convert_to_element(node : Crystal::Call) : Crystal::ASTNode
      args = node.args
      return Crystal::Nop.new if args.empty?

      channel_arg = args[0]

      # Build: turbo_cable_stream_tag(channel_name)
      # This helper will be in the view helpers module
      Crystal::Call.new(nil, "turbo_cable_stream_tag", [channel_arg] of Crystal::ASTNode)
    end
  end
end
