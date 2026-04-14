# Crystal source for Python helper functions.
#
# Route helpers, view helpers, form helpers, layout.
# Emitted as Python via cr2py.

module Railcar
  # parse_form and encode_params are Python-specific — emitted as raw Python
  # by the generator, not transpiled from Crystal.

  def self.form_value(data : Hash(String, Array(String)), key : String) : String
    arr = data[key]?
    if arr
      arr[0]
    else
      ""
    end
  end

  LAYOUT_HEAD = "<!DOCTYPE html>\n<html>\n<head>\n  <meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">\n  <meta name=\"action-cable-url\" content=\"/cable\">\n  <link rel=\"stylesheet\" href=\"/static/app.css\">\n  <script type=\"module\" src=\"/static/turbo.min.js\"></script>\n</head>\n<body>\n  <main class=\"container mx-auto mt-28 px-5 flex flex-col\">"
  LAYOUT_TAIL = "  </main>\n</body>\n</html>"

  def self.layout(content : String, title : String = "Blog") : String
    head = LAYOUT_HEAD.gsub("<head>", "<head>\n  <title>#{title}</title>")
    head + content + LAYOUT_TAIL
  end

  # link_to and button_to are emitted as hand-written Python by the generator
  # (need to handle form_class, data dict, and other kwargs cleanly)

  def self.dom_id(obj, prefix : String = "") : String
    name = obj.class.name.downcase
    if prefix.empty?
      "#{name}_#{obj.id}"
    else
      "#{prefix}_#{name}_#{obj.id}"
    end
  end

  def self.pluralize(count : Int64, singular : String) : String
    if count == 1
      "#{count} #{singular}"
    else
      "#{count} #{singular}s"
    end
  end

  # turbo_stream_from is emitted as hand-written Python by the generator
  # (requires base64/json which don't transpile from Crystal)

  def self.content_for(name : String, value : String)
  end

  def self.form_with(**kwargs) : String
    ""
  end

  def self.render(partial, **kwargs) : String
    ""
  end

  # truncate is emitted as hand-written Python by the generator
  # (Crystal's text[0, n] slice syntax doesn't transpile to Python)
end
