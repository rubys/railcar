require "spec"
require "../src/generator/python_emitter"
require "../src/generator/source_parser"
require "../src/generator/erb_compiler"
require "../src/generator/inflector"
require "../src/filters/instance_var_to_local"
require "../src/filters/params_expect"
require "../src/filters/respond_to_html"
require "../src/filters/strong_params"
require "../src/filters/rails_helpers"
require "../src/filters/link_to_path_helper"
require "../src/filters/button_to_path_helper"
require "../src/filters/render_to_partial"
require "../src/filters/form_to_html"
require "../src/filters/python_constructor"
require "../src/filters/python_redirect"
require "../src/filters/python_render"
require "../src/filters/python_view"

# Helper: parse Ruby source, apply filters, emit Python
private def ruby_to_python(source : String, filters : Array(Crystal::Transformer),
                            properties = {} of String => Set(String)) : String
  ast = Railcar::PrismTranslator.translate(source)
  filtered = ast.as(Crystal::ASTNode)
  filters.each { |f| filtered = filtered.transform(f) }
  emitter = Railcar::PythonEmitter.new(properties: properties)
  emitter.emit(filtered)
end

# Helper: parse ERB, apply filters, emit Python
private def erb_to_python(source : String, filters : Array(Crystal::Transformer),
                           properties = {} of String => Set(String)) : String
  compiler = Railcar::ErbCompiler.new(source)
  ast = Railcar::PrismTranslator.translate(compiler.src)
  filtered = ast.as(Crystal::ASTNode)
  filters.each { |f| filtered = filtered.transform(f) }
  emitter = Railcar::PythonEmitter.new(properties: properties)
  emitter.emit(filtered)
end

describe "PythonConstructor" do
  it "converts Article.new() to Article()" do
    result = ruby_to_python("Article.new", [Railcar::PythonConstructor.new] of Crystal::Transformer)
    result.strip.should eq "Article()"
  end

  it "converts Article.new(title: 'x', body: 'y') to Article(title='x', body='y')" do
    result = ruby_to_python(
      "Article.new(title: 'hello', body: 'world')",
      [Railcar::PythonConstructor.new] of Crystal::Transformer
    )
    result.strip.should eq "Article(title=\"hello\", body=\"world\")"
  end

  it "leaves non-new calls unchanged" do
    result = ruby_to_python("Article.find(1)", [Railcar::PythonConstructor.new] of Crystal::Transformer)
    result.strip.should eq "Article.find(1)"
  end
end

describe "PythonRedirect" do
  it "converts redirect_to with model variable to raise HTTPFound" do
    # Use @article so InstanceVarToLocal produces a Var node (as in real controllers)
    result = ruby_to_python(
      "@article = Article.find(1)\nredirect_to @article",
      [Railcar::InstanceVarToLocal.new, Railcar::PythonRedirect.new] of Crystal::Transformer
    )
    result.should contain "raise web.HTTPFound(article_path(article))"
  end

  it "converts redirect_to with status :see_other to HTTPSeeOther" do
    result = ruby_to_python(
      "redirect_to articles_path, status: :see_other",
      [Railcar::PythonRedirect.new] of Crystal::Transformer
    )
    result.strip.should eq "raise web.HTTPSeeOther(articles_path())"
  end

  it "converts redirect_to path helper" do
    result = ruby_to_python(
      "redirect_to articles_path",
      [Railcar::PythonRedirect.new] of Crystal::Transformer
    )
    result.strip.should eq "raise web.HTTPFound(articles_path())"
  end

  it "leaves non-redirect calls unchanged" do
    result = ruby_to_python("render :new", [Railcar::PythonRedirect.new] of Crystal::Transformer)
    result.strip.should eq "render(\"new\")"
  end
end

describe "PythonRender" do
  it "converts render :new to web.Response with view function" do
    result = ruby_to_python(
      "render :new",
      [Railcar::PythonRender.new("articles", "article")] of Crystal::Transformer
    )
    result.strip.should contain "render_new"
    result.strip.should contain "web.Response"
    result.strip.should contain "layout"
  end

  it "converts render :edit with unprocessable_entity to status 422" do
    result = ruby_to_python(
      "render :edit, status: :unprocessable_entity",
      [Railcar::PythonRender.new("articles", "article")] of Crystal::Transformer
    )
    result.strip.should contain "status=422"
    result.strip.should contain "render_edit"
  end

  it "leaves non-render calls unchanged" do
    result = ruby_to_python(
      "redirect_to article",
      [Railcar::PythonRender.new("articles", "article")] of Crystal::Transformer
    )
    result.strip.should_not contain "render_"
  end
end

describe "PythonView" do
  it "converts bare call to local variable for known locals" do
    result = ruby_to_python(
      "article",
      [Railcar::PythonView.new(["article"])] of Crystal::Transformer
    )
    result.strip.should eq "article"
  end

  it "strips .to_s calls" do
    result = ruby_to_python(
      "article.title.to_s",
      [Railcar::PythonView.new(["article"])] of Crystal::Transformer
    )
    result.strip.should_not contain "to_s"
  end

  it "converts .size to len()" do
    result = ruby_to_python(
      "article.comments.size",
      [Railcar::PythonView.new(["article"])] of Crystal::Transformer
    )
    result.strip.should contain "len("
  end

  it "strips .any? for truthy check" do
    result = ruby_to_python(
      "articles.any?",
      [Railcar::PythonView.new(["articles"])] of Crystal::Transformer
    )
    result.strip.should eq "articles"
    result.strip.should_not contain "any"
  end

  it "strips .present? for truthy check" do
    result = ruby_to_python(
      "notice.present?",
      [Railcar::PythonView.new(["notice"])] of Crystal::Transformer
    )
    result.strip.should eq "notice"
  end

  it "converts content_for to assignment" do
    result = ruby_to_python(
      "content_for :title, \"Articles\"",
      [Railcar::PythonView.new([] of String)] of Crystal::Transformer
    )
    result.strip.should eq "title = \"Articles\""
  end

  it "flattens button_to data hash" do
    result = ruby_to_python(
      "button_to \"Delete\", article, method: :delete, data: { turbo_confirm: \"Sure?\" }",
      [Railcar::PythonView.new(["article"])] of Crystal::Transformer
    )
    result.strip.should contain "data_turbo_confirm"
    result.strip.should_not contain "data="
  end
end

describe "FormToHTML" do
  it "expands form.label to HTML label tag" do
    erb = "<%= form_with(model: article, class: 'contents') do |form| %>\n<%= form.label :title %>\n<% end %>"
    result = erb_to_python(erb, [Railcar::FormToHTML.new] of Crystal::Transformer)
    result.should contain "article_title"
    result.should contain "Title</label>"
  end

  it "expands form.text_field to HTML input tag" do
    erb = "<%= form_with(model: article, class: 'contents') do |form| %>\n<%= form.text_field :title, class: 'border' %>\n<% end %>"
    result = erb_to_python(erb, [Railcar::FormToHTML.new] of Crystal::Transformer)
    result.should contain "input type"
    result.should contain "article[title]"
    result.should contain "border"
  end

  it "extracts default classes from conditional class array" do
    erb = %(<%= form_with(model: article) do |form| %>\n<%= form.text_field :title, class: ["base-class", {"border-gray": article.errors[:title].none?, "border-red": article.errors[:title].any?}] %>\n<% end %>)
    result = erb_to_python(erb, [Railcar::FormToHTML.new] of Crystal::Transformer)
    result.should contain "base-class"
    result.should contain "border-gray"
  end

  it "expands form.textarea to HTML textarea tag" do
    erb = "<%= form_with(model: article, class: 'contents') do |form| %>\n<%= form.textarea :body, rows: 4 %>\n<% end %>"
    result = erb_to_python(erb, [Railcar::FormToHTML.new] of Crystal::Transformer)
    result.should contain "textarea"
    result.should contain "article[body]"
  end

  it "expands form.submit with explicit text to button" do
    erb = "<%= form_with(model: article, class: 'contents') do |form| %>\n<%= form.submit \"Save\", class: 'btn' %>\n<% end %>"
    result = erb_to_python(erb, [Railcar::FormToHTML.new] of Crystal::Transformer)
    result.should contain "submit"
    result.should contain "Save</button>"
  end

  it "includes </form> closing tag" do
    erb = "<%= form_with(model: article, class: 'contents') do |form| %>\n<%= form.label :title %>\n<% end %>"
    result = erb_to_python(erb, [Railcar::FormToHTML.new] of Crystal::Transformer)
    result.should contain "</form>"
  end
end

describe "PythonEmitter" do
  it "emits property access without parens when type info available" do
    properties = {"Article" => Set{"id", "title", "body"}}
    # InstanceVarToLocal produces a Var node which the emitter can look up in properties
    result = ruby_to_python("@article.title",
      [Railcar::InstanceVarToLocal.new] of Crystal::Transformer, properties)
    result.strip.should eq "article.title"
  end

  it "emits method calls with parens" do
    properties = {"Article" => Set{"id", "title", "body"}}
    result = ruby_to_python("@article.comments",
      [Railcar::InstanceVarToLocal.new] of Crystal::Transformer, properties)
    result.strip.should eq "article.comments()"
  end

  it "emits _buf.append= as _buf += str() in ERB context" do
    # _buf must be assigned first for Prism to treat it as a variable
    erb = "<%= \"hello\" %>"
    result = erb_to_python(erb, [] of Crystal::Transformer)
    result.should contain "_buf += str("
  end

  it "emits _buf.to_s as return _buf in ERB context" do
    erb = "text"
    result = erb_to_python(erb, [] of Crystal::Transformer)
    result.should contain "return _buf"
  end

  it "emits raise as statement not function" do
    # Use redirect_to which produces a raise after PythonRedirect
    result = ruby_to_python(
      "@article = Article.find(1)\nredirect_to @article",
      [Railcar::InstanceVarToLocal.new, Railcar::PythonRedirect.new] of Crystal::Transformer
    )
    result.should contain "raise web.HTTPFound("
    result.should_not contain "raise("
  end

  it "renames class keyword arg to class_" do
    result = ruby_to_python(
      "link_to \"Show\", article, class: \"btn\"",
      [] of Crystal::Transformer
    )
    result.strip.should contain "class_="
    result.strip.should_not contain ", class="
  end

  it "converts string interpolation to f-string" do
    result = ruby_to_python(
      "\"hello \#{name}\"",
      [] of Crystal::Transformer
    )
    result.strip.should contain "f\""
    result.strip.should contain "{name()}"
  end

  it "emits for loop from each block" do
    result = ruby_to_python(
      "items.each do |item|\n  puts item\nend",
      [] of Crystal::Transformer
    )
    result.should contain "for item in items()"
  end

  it "emits if/else with proper indentation" do
    result = ruby_to_python(
      "if x\n  a\nelse\n  b\nend",
      [] of Crystal::Transformer
    )
    result.should contain "if x():"
    result.should contain "else:"
  end

  it "converts nil to None" do
    result = ruby_to_python("nil", [] of Crystal::Transformer)
    result.strip.should eq "None"
  end

  it "converts true/false to True/False" do
    result = ruby_to_python("true", [] of Crystal::Transformer)
    result.strip.should eq "True"
    result2 = ruby_to_python("false", [] of Crystal::Transformer)
    result2.strip.should eq "False"
  end

  it "converts symbols to strings" do
    result = ruby_to_python(":hello", [] of Crystal::Transformer)
    result.strip.should eq "\"hello\""
  end
end

describe "Full pipeline: shared + Python filters" do
  filters = [
    Railcar::InstanceVarToLocal.new,
    Railcar::ParamsExpect.new,
    Railcar::RespondToHTML.new,
    Railcar::StrongParams.new,
    Railcar::PythonConstructor.new,
    Railcar::PythonRedirect.new,
    Railcar::PythonRender.new("articles", "article"),
  ] of Crystal::Transformer

  it "transforms create action" do
    source = <<-RUBY
    def create
      @article = Article.new(article_params)
      respond_to do |format|
        if @article.save
          format.html { redirect_to @article, notice: "Created." }
          format.json { render :show, status: :created }
        else
          format.html { render :new, status: :unprocessable_entity }
          format.json { render json: @article.errors }
        end
      end
    end
    RUBY

    result = ruby_to_python(source, filters)
    result.should contain "Article("
    result.should contain "extract_model_params"
    result.should contain "article.save()"
    result.should contain "raise web.HTTPFound(article_path(article))"
    result.should contain "render_new"
    result.should contain "status=422"
  end

  it "transforms destroy action" do
    source = <<-RUBY
    def destroy
      @article.destroy!
      respond_to do |format|
        format.html { redirect_to articles_path, status: :see_other }
        format.json { head :no_content }
      end
    end
    RUBY

    result = ruby_to_python(source, filters)
    result.should contain "article.destroy()"
    result.should contain "raise web.HTTPSeeOther(articles_path())"
  end

  it "transforms index with view filter" do
    erb = <<-ERB
    <%= turbo_stream_from "articles" %>
    <% content_for :title, "Articles" %>
    <h1>Articles</h1>
    <% if @articles.any? %>
      <%= render @articles %>
    <% else %>
      <p>No articles.</p>
    <% end %>
    ERB

    view_filters = [
      Railcar::InstanceVarToLocal.new,
      Railcar::RailsHelpers.new,
      Railcar::RenderToPartial.new,
      Railcar::PythonConstructor.new,
      Railcar::PythonView.new(["articles"]),
    ] of Crystal::Transformer

    result = erb_to_python(erb, view_filters)
    result.should contain "turbo_stream_from"
    result.should contain "title = \"Articles\""
    result.should contain "if articles:"
    result.should contain "for article in articles:"
    result.should contain "render_article_partial"
  end
end
