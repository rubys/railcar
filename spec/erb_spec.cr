require "spec"
require "./test_paths"
require "../src/generator/erb_converter"
require "../src/filters/instance_var_to_local"
require "../src/filters/strip_turbo_stream"
require "../src/filters/link_to_path_helper"
require "../src/filters/button_to_path_helper"
require "../src/filters/render_to_partial"

VIEW_FILTERS = [
  Ruby2CR::InstanceVarToLocal.new,
  Ruby2CR::StripTurboStream.new,
  Ruby2CR::LinkToPathHelper.new,
  Ruby2CR::ButtonToPathHelper.new,
  Ruby2CR::RenderToPartial.new,
] of Crystal::Transformer

describe Ruby2CR::ErbCompiler do
  it "converts simple ERB to Ruby source" do
    erb = "<h1><%= title %></h1>"
    compiler = Ruby2CR::ErbCompiler.new(erb)
    src = compiler.src
    src.should contain "_buf"
    src.should contain "title"
  end

  it "handles code blocks" do
    erb = "<% items.each do |item| %>\n  <p><%= item.name %></p>\n<% end %>\n"
    compiler = Ruby2CR::ErbCompiler.new(erb)
    src = compiler.src
    src.should contain "items.each"
    src.should contain "item.name"
  end

  it "handles if/else" do
    erb = "<% if show %>\n  <p>visible</p>\n<% else %>\n  <p>hidden</p>\n<% end %>\n"
    compiler = Ruby2CR::ErbCompiler.new(erb)
    src = compiler.src
    src.should contain "if show"
    src.should contain "visible"
    src.should contain "hidden"
  end
end

describe Ruby2CR::ERBConverter do
  it "converts simple output expressions" do
    erb = "<h1><%= @article.title %></h1>"
    ecr = Ruby2CR::ERBConverter.convert(erb, "show", "articles", view_filters: VIEW_FILTERS)
    ecr.should contain "article.title"
    ecr.should contain "<h1>"
    ecr.should_not contain "@article"
  end

  it "converts link_to with model to path helper" do
    erb = %(<%= link_to "Show", @article, class: "btn" %>)
    ecr = Ruby2CR::ERBConverter.convert(erb, "index", "articles", view_filters: VIEW_FILTERS)
    ecr.should contain "article_path(article)"
    ecr.should contain "link_to"
  end

  it "converts link_to with path helper" do
    erb = %(<%= link_to "Back", articles_path, class: "btn" %>)
    ecr = Ruby2CR::ERBConverter.convert(erb, "show", "articles", view_filters: VIEW_FILTERS)
    ecr.should contain "articles_path"
    ecr.should_not contain "articles_path_path"
  end

  it "converts render @collection to loop" do
    erb = %(<%= render @articles %>)
    ecr = Ruby2CR::ERBConverter.convert(erb, "index", "articles", view_filters: VIEW_FILTERS)
    ecr.should contain "articles.each"
    ecr.should contain "render_article_partial"
  end

  it "converts render partial with locals" do
    erb = %(<%= render "form", article: @article %>)
    ecr = Ruby2CR::ERBConverter.convert(erb, "new", "articles", view_filters: VIEW_FILTERS)
    ecr.should contain "render_form_partial(article)"
  end

  it "strips turbo_stream_from" do
    erb = %(<%= turbo_stream_from "articles" %>\n<h1>Articles</h1>)
    ecr = Ruby2CR::ERBConverter.convert(erb, "index", "articles", view_filters: VIEW_FILTERS)
    ecr.should_not contain "turbo_stream"
    ecr.should contain "Articles"
  end

  it "converts if/else blocks" do
    erb = "<% if notice.present? %>\n  <p><%= notice %></p>\n<% end %>\n"
    ecr = Ruby2CR::ERBConverter.convert(erb, "index", "articles", view_filters: VIEW_FILTERS)
    ecr.should contain "<% if"
    ecr.should contain "notice"
    ecr.should contain "<% end %>"
  end

  it "converts the blog index template" do
    erb = File.read(File.join(BLOG_DIR, "app/views/articles/index.html.erb"))
    ecr = Ruby2CR::ERBConverter.convert(erb, "index", "articles", view_filters: VIEW_FILTERS)

    ecr.should contain "articles.each"
    ecr.should contain "render_article_partial"
    ecr.should_not contain "turbo_stream_from"
    ecr.should contain "new_article_path"
  end

  it "converts the blog show template" do
    erb = File.read(File.join(BLOG_DIR, "app/views/articles/show.html.erb"))
    ecr = Ruby2CR::ERBConverter.convert(erb, "show", "articles", view_filters: VIEW_FILTERS)

    ecr.should contain "article.title"
    ecr.should contain "article.body"
    ecr.should contain "render_comment_partial"
    ecr.should contain "<form"
    ecr.should contain "comment"
  end

  it "converts form_with for comments" do
    erb = <<-ERB
    <%= form_with model: [@article, Comment.new], class: "space-y-4" do |form| %>
      <%= form.label :commenter, class: "block font-medium" %>
      <%= form.text_field :commenter, class: "block w-full border rounded p-2" %>
      <%= form.submit "Add Comment", class: "bg-blue-600 text-white px-4 py-2 rounded" %>
    <% end %>
    ERB
    ecr = Ruby2CR::ERBConverter.convert(erb, "show", "articles", view_filters: VIEW_FILTERS)

    ecr.should contain "<form"
    ecr.should contain "article_comments_path"
    ecr.should contain "label_tag"
    ecr.should contain "text_field_tag"
    ecr.should contain "submit_tag"
  end
end
