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

  LAYOUT_HEAD = "<!DOCTYPE html>\n<html>\n<head>\n  <meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">\n  <link rel=\"stylesheet\" href=\"/static/app.css\">\n  <script type=\"module\" src=\"/static/turbo.min.js\"></script>\n</head>\n<body>\n  <main class=\"container mx-auto mt-28 px-5 flex flex-col\">"
  LAYOUT_TAIL = "  </main>\n</body>\n</html>"

  def self.layout(content : String, title : String = "Blog") : String
    head = LAYOUT_HEAD.gsub("<head>", "<head>\n  <title>#{title}</title>")
    head + content + LAYOUT_TAIL
  end

  def self.link_to(text : String, url : String, css : String = "") : String
    if css.empty?
      "<a href=\"#{url}\">#{text}</a>"
    else
      "<a href=\"#{url}\" class=\"#{css}\">#{text}</a>"
    end
  end

  def self.button_to(text : String, url : String, method : String = "post", css : String = "", confirm : String = "") : String
    confirm_attr = confirm.empty? ? "" : " data-turbo-confirm=\"#{confirm}\""
    cls_attr = css.empty? ? "" : " class=\"#{css}\""
    "<form method=\"post\" action=\"#{url}\"#{confirm_attr}>" \
    "<input type=\"hidden\" name=\"_method\" value=\"#{method}\">" \
    "<button type=\"submit\"#{cls_attr}>#{text}</button>" \
    "</form>"
  end

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

  def self.truncate(text : String, length : Int32 = 30) : String
    if text.size <= length
      text
    else
      text[0, length - 3] + "..."
    end
  end
end
