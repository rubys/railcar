# View helpers used in ECR templates — mirrors a subset of Rails
# ActionView helpers needed by the blog demo.

require "html"
require "base64"
require "json"

module Railcar::ViewHelpers
  def link_to(text : String, path : String, **opts) : String
    cls = opts[:class]?
    if cls
      %(<a class="#{HTML.escape(cls)}" href="#{HTML.escape(path)}">#{HTML.escape(text)}</a>)
    else
      %(<a href="#{HTML.escape(path)}">#{HTML.escape(text)}</a>)
    end
  end

  def button_to(text : String, path : String, method : String = "post", **opts) : String
    cls = opts[:class]?
    confirm = opts[:data_turbo_confirm]?
    form_class = opts[:form_class]?

    html = String.build do |io|
      fc = form_class || "button_to"
      io << %(<form class="#{HTML.escape(fc)}" method="post" action="#{HTML.escape(path)}">)
      if method != "post"
        io << %(<input type="hidden" name="_method" value="#{HTML.escape(method)}">)
      end
      io << %(<button)
      io << %( class="#{HTML.escape(cls)}") if cls
      if confirm
        io << %( data-turbo-confirm="#{HTML.escape(confirm)}")
      end
      io << %( type="submit">#{HTML.escape(text)}</button>)
      io << "</form>"
    end
    html
  end

  def form_tag(path : String, method : String = "post", **opts, &block : IO -> _) : String
    String.build do |io|
      io << %(<form action="#{HTML.escape(path)}" method="post")
      io << %( class="#{opts[:class]?}") if opts[:class]?
      io << ">"
      if method != "post"
        io << %(<input type="hidden" name="_method" value="#{HTML.escape(method)}">)
      end
      yield io
      io << "</form>"
    end
  end

  def pluralize(count : Int, singular : String, plural : String? = nil) : String
    word = count == 1 ? singular : (plural || singular + "s")
    "#{count} #{word}"
  end

  def truncate(text : String, length : Int32 = 30, omission : String = "...") : String
    if text.size <= length
      text
    else
      text[0, length - omission.size] + omission
    end
  end

  def dom_id(record, prefix : String? = nil) : String
    model_name = record.class.name.split("::").last.underscore
    id = record.id
    if prefix
      "#{prefix}_#{model_name}_#{id}"
    else
      "#{model_name}_#{id}"
    end
  end

  def content_tag(tag : String, content : String = "", **opts) : String
    attrs = opts.map { |k, v| %( #{k.to_s.gsub('_', '-')}="#{HTML.escape(v.to_s)}") }.join
    "<#{tag}#{attrs}>#{content}</#{tag}>"
  end

  def text_field_tag(name : String, value : String = "", **opts) : String
    cls = opts[:class]?
    id = opts[:id]?
    html = %(<input)
    html += %( class="#{HTML.escape(cls)}") if cls
    html += %( type="text" name="#{HTML.escape(name)}")
    html += %( id="#{HTML.escape(id)}") if id
    html += %( value="#{HTML.escape(value)}") unless value.empty?
    html += ">"
    html
  end

  def text_area_tag(name : String, value : String = "", **opts) : String
    cls = opts[:class]?
    rows = opts[:rows]?
    id = opts[:id]?
    html = %(<textarea)
    html += %( rows="#{rows}") if rows
    html += %( class="#{HTML.escape(cls)}") if cls
    html += %( name="#{HTML.escape(name)}")
    html += %( id="#{HTML.escape(id)}") if id
    html += ">#{HTML.escape(value)}</textarea>"
    html
  end

  def label_tag(name : String, text : String? = nil, **opts) : String
    cls = opts[:class]?
    label_text = text || name.capitalize
    if cls
      %(<label class="#{HTML.escape(cls)}" for="#{HTML.escape(name)}">#{HTML.escape(label_text)}</label>)
    else
      %(<label for="#{HTML.escape(name)}">#{HTML.escape(label_text)}</label>)
    end
  end

  def submit_tag(text : String = "Submit", **opts) : String
    cls = opts[:class]?
    html = %(<input type="submit" name="commit" value="#{HTML.escape(text)}")
    html += %( class="#{HTML.escape(cls)}") if cls
    html += ">"
    html
  end

  # Generate a turbo-cable-stream-source element for WebSocket subscription.
  # Turbo's JavaScript automatically connects when it sees this element.
  def turbo_cable_stream_tag(channel : String) : String
    signed = Base64.strict_encode(channel.to_json)
    %(<turbo-cable-stream-source channel="Turbo::StreamsChannel" signed-stream-name="#{HTML.escape(signed)}"></turbo-cable-stream-source>)
  end
end
