# Turbo Streams broadcasting over Action Cable WebSocket protocol.
#
# Manages WebSocket subscriptions and broadcasts turbo-stream HTML
# to all subscribers of a channel.
#
# Action Cable protocol:
#   Server → Client: {"type":"welcome"}
#   Client → Server: {"command":"subscribe","identifier":"{\"channel\":\"Turbo::StreamsChannel\",\"signed_stream_name\":\"base64(name)\"}"}
#   Server → Client: {"type":"confirm_subscription","identifier":"..."}
#   Server → Client: {"identifier":"...","message":"<turbo-stream>...</turbo-stream>"}
#   Server → Client: {"type":"ping","message":timestamp}

require "http/web_socket"
require "json"
require "base64"

module Ruby2CR
  class TurboBroadcast
    # Channel name → set of subscribed WebSockets
    @@channels = {} of String => Array(HTTP::WebSocket)

    # WebSocket → set of channel names (for cleanup on disconnect)
    @@subscriptions = {} of HTTP::WebSocket => Array(String)

    # WebSocket → channel → Action Cable identifier string
    @@identifiers = {} of HTTP::WebSocket => Hash(String, String)

    # Broadcast turbo-stream HTML to all subscribers of a channel
    def self.broadcast(channel : String, html : String)
      sockets = @@channels[channel]?
      return unless sockets

      sockets.each do |ws|
        identifier = @@identifiers[ws]?.try(&.[channel]?)
        next unless identifier

        message = {
          "identifier" => identifier,
          "message"    => html,
        }.to_json

        begin
          ws.send(message)
        rescue
          # Socket closed — will be cleaned up on disconnect
        end
      end
    end

    # Generate turbo-stream HTML for an action
    def self.turbo_stream_html(action : String, target : String, content : String = "") : String
      if content.empty?
        "<turbo-stream action=\"#{action}\" target=\"#{target}\"></turbo-stream>"
      else
        "<turbo-stream action=\"#{action}\" target=\"#{target}\"><template>#{content}</template></turbo-stream>"
      end
    end

    # Handle a new WebSocket connection on /cable
    def self.handle_connection(ws : HTTP::WebSocket)
      # Send welcome
      ws.send({"type" => "welcome"}.to_json)

      # Start ping timer
      ping_fiber = spawn do
        loop do
          sleep 3.seconds
          begin
            ws.send({"type" => "ping", "message" => Time.utc.to_unix}.to_json)
          rescue
            break
          end
        end
      end

      ws.on_message do |message|
        handle_message(ws, message)
      end

      ws.on_close do |_code, _reason|
        cleanup(ws)
      end
    end

    # Handle incoming Action Cable protocol message
    def self.handle_message(ws : HTTP::WebSocket, raw : String)
      data = JSON.parse(raw)

      command = data["command"]?.try(&.as_s)
      case command
      when "subscribe"
        identifier = data["identifier"]?.try(&.as_s)
        return unless identifier

        # Parse the identifier to extract the stream name
        id_data = JSON.parse(identifier)
        signed = id_data["signed_stream_name"]?.try(&.as_s)
        return unless signed

        # Decode the stream name (base64-encoded JSON string)
        channel_name = begin
          decoded = Base64.decode_string(signed)
          JSON.parse(decoded).as_s
        rescue
          signed  # Fall back to using it directly
        end

        subscribe(ws, channel_name, identifier)
      when "unsubscribe"
        identifier = data["identifier"]?.try(&.as_s)
        return unless identifier
        id_data = JSON.parse(identifier)
        signed = id_data["signed_stream_name"]?.try(&.as_s)
        return unless signed
        channel_name = begin
          decoded = Base64.decode_string(signed)
          JSON.parse(decoded).as_s
        rescue
          signed
        end
        unsubscribe(ws, channel_name)
      end
    end

    private def self.subscribe(ws : HTTP::WebSocket, channel : String, identifier : String)
      @@channels[channel] ||= [] of HTTP::WebSocket
      @@channels[channel] << ws unless @@channels[channel].includes?(ws)

      @@subscriptions[ws] ||= [] of String
      @@subscriptions[ws] << channel unless @@subscriptions[ws].includes?(channel)

      @@identifiers[ws] ||= {} of String => String
      @@identifiers[ws][channel] = identifier

      # Confirm subscription
      ws.send({
        "type"       => "confirm_subscription",
        "identifier" => identifier,
      }.to_json)
    end

    private def self.unsubscribe(ws : HTTP::WebSocket, channel : String)
      @@channels[channel]?.try(&.delete(ws))
      @@subscriptions[ws]?.try(&.delete(channel))
      @@identifiers[ws]?.try(&.delete(channel))
    end

    private def self.cleanup(ws : HTTP::WebSocket)
      channels = @@subscriptions.delete(ws)
      channels.try(&.each { |ch| @@channels[ch]?.try(&.delete(ws)) })
      @@identifiers.delete(ws)
    end
  end
end
