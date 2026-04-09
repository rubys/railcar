# Turbo Streams model broadcasting mixin.
#
# Provides broadcast_* methods that models call from after_commit
# callbacks. Each method renders the model as a partial and sends
# the turbo-stream HTML to all subscribers.
#
# Usage in generated models:
#   after_save { broadcast_replace_to("articles") }
#   after_destroy { broadcast_remove_to("articles") }

require "./turbo_broadcast"

module Railcar
  module Broadcasts
    # Broadcast a replace action for this record
    def broadcast_replace_to(channel : String, target : String? = nil)
      target ||= dom_id_for(self)
      html = render_broadcast_partial
      stream = TurboBroadcast.turbo_stream_html("replace", target, html)
      TurboBroadcast.broadcast(channel, stream)
    end

    # Broadcast an append action
    def broadcast_append_to(channel : String, target : String? = nil)
      target ||= self.class.table_name
      html = render_broadcast_partial
      stream = TurboBroadcast.turbo_stream_html("append", target, html)
      TurboBroadcast.broadcast(channel, stream)
    end

    # Broadcast a prepend action
    def broadcast_prepend_to(channel : String, target : String? = nil)
      target ||= self.class.table_name
      html = render_broadcast_partial
      stream = TurboBroadcast.turbo_stream_html("prepend", target, html)
      TurboBroadcast.broadcast(channel, stream)
    end

    # Broadcast a remove action (no partial needed)
    def broadcast_remove_to(channel : String, target : String? = nil)
      target ||= dom_id_for(self)
      stream = TurboBroadcast.turbo_stream_html("remove", target)
      TurboBroadcast.broadcast(channel, stream)
    end

    # Generate a dom_id like "article_1"
    private def dom_id_for(record) : String
      model_name = record.class.name.split("::").last.underscore
      "#{model_name}_#{record.id}"
    end

    # Render this record's partial. Override in generated models
    # with the actual ECR embed.
    def render_broadcast_partial : String
      ""  # Base implementation — generated models override this
    end
  end
end
