require "spec"
require "compiler/crystal/syntax"
require "../src/filters/strip_turbo_stream"
require "../src/filters/link_to_path_helper"
require "../src/filters/button_to_path_helper"
require "../src/filters/render_to_partial"
require "../src/filters/instance_var_to_local"
require "../src/generator/prism_translator"

describe Railcar::StripTurboStream do
  filter = Railcar::StripTurboStream.new

  it "strips turbo_stream_from" do
    ast = Railcar::PrismTranslator.translate(%q(turbo_stream_from "articles"))
    result = ast.transform(filter)
    result.to_s.strip.should eq ""
  end

  it "strips content_for" do
    ast = Railcar::PrismTranslator.translate(%q(content_for :head, "title"))
    result = ast.transform(filter)
    result.to_s.strip.should eq ""
  end

  it "preserves other calls" do
    ast = Railcar::PrismTranslator.translate(%q(link_to "Show", article))
    result = ast.transform(filter)
    result.to_s.should contain "link_to"
  end
end

describe Railcar::LinkToPathHelper do
  filter = Railcar::LinkToPathHelper.new

  it "converts instance variable to path helper" do
    ast = Railcar::PrismTranslator.translate(%q(link_to "Show", @article))
    result = ast.transform(filter)
    output = result.to_s
    output.should contain "article_path(article)"
    output.should_not contain "@"
  end

  it "converts local variable to path helper" do
    ast = Crystal::Parser.parse(%q(link_to("Show", article)))
    result = ast.transform(filter)
    result.to_s.should contain "article_path(article)"
  end

  it "preserves existing path helpers" do
    ast = Crystal::Parser.parse(%q(link_to("Articles", articles_path)))
    result = ast.transform(filter)
    result.to_s.should contain "articles_path"
    result.to_s.should_not contain "articles_path_path"
  end

  it "preserves class keyword argument" do
    ast = Railcar::PrismTranslator.translate(%q(link_to "Show", @article, class: "btn"))
    result = ast.transform(filter)
    output = result.to_s
    output.should contain "article_path(article)"
    output.should contain "class"
  end
end

describe Railcar::ButtonToPathHelper do
  filter = Railcar::ButtonToPathHelper.new

  it "converts instance variable to path helper" do
    ast = Railcar::PrismTranslator.translate(%q(button_to "Delete", @article, method: :delete))
    result = ast.transform(filter)
    output = result.to_s
    output.should contain "article_path(article)"
  end

  it "converts array target to nested path helper" do
    ast = Crystal::Parser.parse(%q(button_to("Delete", [comment.article, comment], method: :delete)))
    result = ast.transform(filter)
    output = result.to_s
    output.should contain "article_comment_path"
  end
end

describe Railcar::RenderToPartial do
  filter = Railcar::RenderToPartial.new

  it "converts render @collection to loop" do
    ast = Railcar::PrismTranslator.translate(%q(render @articles))
    result = ast.transform(filter)
    output = result.to_s
    output.should contain "articles.each"
    output.should contain "render_article_partial(article)"
  end

  it "converts render association to loop" do
    ast = Crystal::Parser.parse(%q(render(article.comments)))
    result = ast.transform(filter)
    output = result.to_s
    output.should contain "each"
    output.should contain "render_comment_partial"
  end

  it "converts render partial with locals" do
    ast = Railcar::PrismTranslator.translate(%q(render "form", article: @article))
    result = ast.transform(filter)
    output = result.to_s
    output.should contain "render_form_partial"
    output.should contain "article"
    output.should_not contain "@"
  end

  it "preserves non-render calls" do
    ast = Crystal::Parser.parse(%q(link_to("Show", article)))
    result = ast.transform(filter)
    result.to_s.should contain "link_to"
  end
end

describe "View filter pipeline" do
  it "applies all view filters in sequence" do
    ruby = %q(link_to "Show", @article; render @articles; turbo_stream_from "articles")
    ast = Railcar::PrismTranslator.translate(ruby)
    ast = ast.transform(Railcar::InstanceVarToLocal.new)
    ast = ast.transform(Railcar::StripTurboStream.new)
    ast = ast.transform(Railcar::LinkToPathHelper.new)
    ast = ast.transform(Railcar::RenderToPartial.new)

    output = ast.to_s
    output.should contain "article_path(article)"
    output.should contain "articles.each"
    output.should contain "render_article_partial"
    output.should_not contain "turbo_stream"
    output.should_not contain "@"
  end
end
