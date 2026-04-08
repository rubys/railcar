# View helpers used in ECR templates — mirrors a subset of Rails
# ActionView helpers needed by the blog demo.

require "html"

module Ruby2CR::ViewHelpers
  def link_to(text : String, path : String, **opts) : String
    cls = opts[:class]?
    if cls
      %(<a href="#{HTML.escape(path)}" class="#{HTML.escape(cls)}">#{HTML.escape(text)}</a>)
    else
      %(<a href="#{HTML.escape(path)}">#{HTML.escape(text)}</a>)
    end
  end

  def button_to(text : String, path : String, method : String = "post", **opts) : String
    cls = opts[:class]?
    confirm = opts[:data_turbo_confirm]?
    form_class = opts[:form_class]?

    html = String.build do |io|
      io << %(<form action="#{HTML.escape(path)}" method="post")
      io << %( class="#{HTML.escape(form_class)}") if form_class
      io << ">"
      if method != "post"
        io << %(<input type="hidden" name="_method" value="#{HTML.escape(method)}">)
      end
      io << %(<button type="submit")
      io << %( class="#{HTML.escape(cls)}") if cls
      if confirm
        io << %( onclick="return confirm('#{HTML.escape(confirm)}')")
      end
      io << ">#{HTML.escape(text)}</button>"
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
    html = %(<input type="text" name="#{HTML.escape(name)}" value="#{HTML.escape(value)}")
    html += %( class="#{HTML.escape(cls)}") if cls
    html += ">"
    html
  end

  def text_area_tag(name : String, value : String = "", **opts) : String
    cls = opts[:class]?
    rows = opts[:rows]?
    html = %(<textarea name="#{HTML.escape(name)}")
    html += %( class="#{HTML.escape(cls)}") if cls
    html += %( rows="#{rows}") if rows
    html += ">#{HTML.escape(value)}</textarea>"
    html
  end

  def label_tag(name : String, text : String? = nil, **opts) : String
    cls = opts[:class]?
    label_text = text || name.capitalize
    html = %(<label for="#{HTML.escape(name)}")
    html += %( class="#{HTML.escape(cls)}") if cls
    html += ">#{HTML.escape(label_text)}</label>"
    html
  end

  def submit_tag(text : String = "Submit", **opts) : String
    cls = opts[:class]?
    html = %(<input type="submit" value="#{HTML.escape(text)}")
    html += %( class="#{HTML.escape(cls)}") if cls
    html += ">"
    html
  end
end
