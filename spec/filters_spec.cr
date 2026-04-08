require "spec"
require "compiler/crystal/syntax"
require "../src/filters/instance_var_to_local"
require "../src/filters/params_expect"
require "../src/filters/model_namespace"
require "../src/filters/redirect_to_response"
require "../src/filters/respond_to_html"
require "../src/filters/strong_params"
require "../src/filters/render_to_ecr"
require "../src/filters/strip_callbacks"
require "../src/filters/controller_signature"
require "../src/filters/controller_boilerplate"
require "../src/filters/model_boilerplate"
require "../src/generator/prism_translator"
require "../src/generator/schema_extractor"
require "../src/generator/model_extractor"
require "../src/generator/controller_extractor"

describe Ruby2CR::InstanceVarToLocal do
  filter = Ruby2CR::InstanceVarToLocal.new

  it "converts @var read to local var" do
    node = Crystal::InstanceVar.new("@article")
    result = filter.transform(node)
    result.to_s.should eq "article"
  end

  it "converts @var assignment to local assignment" do
    node = Crystal::Assign.new(
      Crystal::InstanceVar.new("@article"),
      Crystal::Call.new(Crystal::Path.new("Article"), "find", [Crystal::Var.new("id")] of Crystal::ASTNode)
    )
    result = filter.transform(node)
    result.to_s.should eq "article = Article.find(id)"
  end

  it "leaves local variables unchanged" do
    node = Crystal::Var.new("article")
    result = filter.transform(node)
    result.to_s.should eq "article"
  end

  it "transforms nested instance vars in expressions" do
    # @article.comments → article.comments
    node = Crystal::Call.new(
      Crystal::InstanceVar.new("@article"),
      "comments"
    )
    result = node.transform(filter)
    result.to_s.should eq "article.comments"
  end

  it "works on translated Ruby source" do
    ast = Ruby2CR::PrismTranslator.translate("@article = Article.find(1)")
    result = ast.transform(filter)
    result.to_s.should eq "article = Article.find(1)"
  end

  it "transforms controller method body" do
    ruby = <<-RUBY
    def create
      @comment = @article.comments.build(comment_params)
      if @comment.save
        redirect_to @article
      end
    end
    RUBY
    ast = Ruby2CR::PrismTranslator.translate(ruby)
    result = ast.transform(filter)
    output = result.to_s

    output.should contain "comment = article.comments.build"
    output.should contain "comment.save"
    output.should contain "redirect_to(article)"
    output.should_not contain "@"
  end
end

describe Ruby2CR::ParamsExpect do
  filter = Ruby2CR::ParamsExpect.new

  it "converts params.expect(:id) to id" do
    ast = Ruby2CR::PrismTranslator.translate("params.expect(:id)")
    result = ast.transform(filter)
    result.to_s.should eq "id"
  end

  it "converts params.expect(:article_id) to article_id" do
    ast = Ruby2CR::PrismTranslator.translate("params.expect(:article_id)")
    result = ast.transform(filter)
    result.to_s.should eq "article_id"
  end

  it "leaves non-symbol expect unchanged" do
    ast = Ruby2CR::PrismTranslator.translate("params.expect(article: [:title, :body])")
    result = ast.transform(filter)
    result.to_s.should contain "expect"
  end

  it "transforms within larger expression" do
    ast = Ruby2CR::PrismTranslator.translate("Article.find(params.expect(:id))")
    result = ast.transform(filter)
    result.to_s.should eq "Article.find(id)"
  end
end

describe Ruby2CR::ModelNamespace do
  filter = Ruby2CR::ModelNamespace.new(["Article", "Comment"])

  it "namespaces known model constants" do
    node = Crystal::Path.new("Article")
    result = filter.transform(node)
    result.to_s.should eq "Ruby2CR::Article"
  end

  it "leaves unknown constants unchanged" do
    node = Crystal::Path.new("String")
    result = filter.transform(node)
    result.to_s.should eq "String"
  end

  it "leaves already-namespaced paths unchanged" do
    node = Crystal::Path.new(["Ruby2CR", "Article"])
    result = filter.transform(node)
    result.to_s.should eq "Ruby2CR::Article"
  end

  it "transforms in translated source" do
    ast = Ruby2CR::PrismTranslator.translate("Article.find(1)")
    result = ast.transform(filter)
    result.to_s.should eq "Ruby2CR::Article.find(1)"
  end
end

describe Ruby2CR::RedirectToResponse do
  filter = Ruby2CR::RedirectToResponse.new

  it "converts redirect_to with notice" do
    ast = Ruby2CR::PrismTranslator.translate("redirect_to article, notice: \"Created.\"")
    result = ast.transform(filter)
    output = result.to_s
    output.should contain "FLASH_STORE"
    output.should contain "Created."
    output.should contain "302"
    output.should contain "article_path(article)"
  end

  it "converts redirect_to path helper" do
    ast = Ruby2CR::PrismTranslator.translate("redirect_to articles_path")
    result = ast.transform(filter)
    output = result.to_s
    output.should contain "302"
    output.should contain "articles_path"
  end

  it "leaves non-redirect calls unchanged" do
    ast = Ruby2CR::PrismTranslator.translate("puts \"hello\"")
    result = ast.transform(filter)
    result.to_s.should eq "puts(\"hello\")"
  end
end

describe "Filter pipeline" do
  it "chains multiple filters on controller source" do
    ruby = <<-RUBY
    def create
      @comment = @article.comments.build(comment_params)
      if @comment.save
        redirect_to @article, notice: "Created."
      end
    end
    RUBY

    ast = Ruby2CR::PrismTranslator.translate(ruby)

    # Apply filters in order
    ast = ast.transform(Ruby2CR::InstanceVarToLocal.new)
    ast = ast.transform(Ruby2CR::ParamsExpect.new)
    ast = ast.transform(Ruby2CR::RedirectToResponse.new)
    ast = ast.transform(Ruby2CR::ModelNamespace.new(["Article", "Comment"]))

    output = ast.to_s
    output.should contain "comment = article.comments.build"
    output.should contain "comment.save"
    output.should contain "FLASH_STORE"
    output.should contain "article_path(article)"
    output.should contain "302"
    output.should_not contain "@"
  end
end

describe Ruby2CR::RespondToHTML do
  filter = Ruby2CR::RespondToHTML.new

  it "extracts html body from respond_to" do
    ruby = <<-RUBY
    respond_to do |format|
      format.html { redirect_to articles_path }
      format.json { render json: articles }
    end
    RUBY
    ast = Ruby2CR::PrismTranslator.translate(ruby)
    result = ast.transform(filter)
    output = result.to_s
    output.should contain "redirect_to"
    output.should contain "articles_path"
    output.should_not contain "respond_to"
    output.should_not contain "json"
  end

  it "extracts html from respond_to inside if/else" do
    ruby = <<-RUBY
    respond_to do |format|
      if @article.save
        format.html { redirect_to @article }
      else
        format.html { render :new }
      end
    end
    RUBY
    ast = Ruby2CR::PrismTranslator.translate(ruby)
    result = ast.transform(filter)
    output = result.to_s
    output.should contain "redirect_to"
    output.should_not contain "respond_to"
    output.should_not contain "format"
  end

  it "leaves non-respond_to calls unchanged" do
    ast = Ruby2CR::PrismTranslator.translate("foo(1)")
    result = ast.transform(filter)
    result.to_s.should eq "foo(1)"
  end
end

describe Ruby2CR::StrongParams do
  filter = Ruby2CR::StrongParams.new

  it "converts Model.new(article_params)" do
    ast = Ruby2CR::PrismTranslator.translate("Article.new(article_params)")
    result = ast.transform(filter)
    output = result.to_s
    output.should contain "extract_model_params"
    output.should contain "\"article\""
  end

  it "converts article.update(article_params)" do
    ast = Ruby2CR::PrismTranslator.translate("article.update(article_params)")
    result = ast.transform(filter)
    output = result.to_s
    output.should contain "extract_model_params"
    output.should contain "\"article\""
  end

  it "converts comments.build(comment_params)" do
    ast = Ruby2CR::PrismTranslator.translate("article.comments.build(comment_params)")
    result = ast.transform(filter)
    output = result.to_s
    output.should contain "extract_model_params"
    output.should contain "\"comment\""
  end

  it "leaves non-params arguments unchanged" do
    ast = Ruby2CR::PrismTranslator.translate("Article.new(attrs)")
    result = ast.transform(filter)
    result.to_s.should eq "Article.new(attrs)"
  end
end

describe Ruby2CR::RenderToECR do
  filter = Ruby2CR::RenderToECR.new("articles")

  it "converts render :new" do
    ast = Ruby2CR::PrismTranslator.translate("render :new")
    result = ast.transform(filter)
    output = result.to_s
    output.should contain "response.print"
    output.should contain "layout"
    output.should contain "ECR.embed"
    output.should contain "articles/new.ecr"
  end

  it "converts render :edit with status" do
    ast = Ruby2CR::PrismTranslator.translate("render :edit, status: :unprocessable_entity")
    result = ast.transform(filter)
    output = result.to_s
    output.should contain "422"
    output.should contain "ECR.embed"
    output.should contain "articles/edit.ecr"
  end

  it "leaves non-render calls unchanged" do
    ast = Ruby2CR::PrismTranslator.translate("redirect_to articles_path")
    result = ast.transform(filter)
    result.to_s.should contain "redirect_to"
  end
end

describe "Full controller pipeline" do
  it "transforms ArticlesController#create through all filters" do
    ruby = <<-RUBY
    def create
      @article = Article.new(article_params)
      respond_to do |format|
        if @article.save
          format.html { redirect_to @article, notice: "Article was successfully created." }
          format.json { render :show, status: :created, location: @article }
        else
          format.html { render :new, status: :unprocessable_entity }
          format.json { render json: @article.errors, status: :unprocessable_entity }
        end
      end
    end
    RUBY

    ast = Ruby2CR::PrismTranslator.translate(ruby)
    ast = ast.transform(Ruby2CR::InstanceVarToLocal.new)
    ast = ast.transform(Ruby2CR::ParamsExpect.new)
    ast = ast.transform(Ruby2CR::RespondToHTML.new)
    ast = ast.transform(Ruby2CR::StrongParams.new)
    ast = ast.transform(Ruby2CR::RedirectToResponse.new)
    ast = ast.transform(Ruby2CR::RenderToECR.new("articles"))
    ast = ast.transform(Ruby2CR::ModelNamespace.new(["Article", "Comment"]))

    output = ast.to_s
    output.should contain "Ruby2CR::Article.new(extract_model_params(params, \"article\"))"
    output.should contain "article.save"
    output.should contain "FLASH_STORE"
    output.should contain "article_path(article)"
    output.should contain "302"
    output.should contain "ECR.embed"
    output.should contain "articles/new.ecr"
    output.should contain "422"
    output.should_not contain "@"
    output.should_not contain "respond_to"
    output.should_not contain "format.html"
    output.should_not contain "format.json"
  end
end

describe Ruby2CR::StripCallbacks do
  filter = Ruby2CR::StripCallbacks.new

  it "strips broadcasts_to" do
    ast = Ruby2CR::PrismTranslator.translate("broadcasts_to :articles")
    result = ast.transform(filter)
    result.to_s.strip.should eq ""
  end

  it "strips after_create_commit" do
    ast = Ruby2CR::PrismTranslator.translate("after_create_commit { do_something }")
    result = ast.transform(filter)
    result.to_s.strip.should eq ""
  end

  it "leaves model declarations unchanged" do
    ast = Ruby2CR::PrismTranslator.translate("has_many :comments, dependent: :destroy")
    result = ast.transform(filter)
    result.to_s.should contain "has_many"
  end
end

describe "Full model pipeline" do
  it "transforms Article model through filters" do
    ruby = <<-RUBY
    class Article < ApplicationRecord
      has_many :comments, dependent: :destroy
      broadcasts_to ->(_article) { "articles" }, inserts_by: :prepend
      validates :title, presence: true
      validates :body, presence: true, length: { minimum: 10 }
    end
    RUBY

    schema = Ruby2CR::TableSchema.new("articles", [
      Ruby2CR::Column.new("title", "string"),
      Ruby2CR::Column.new("body", "text"),
      Ruby2CR::Column.new("created_at", "datetime"),
      Ruby2CR::Column.new("updated_at", "datetime"),
    ])
    model_info = Ruby2CR::ModelInfo.new("Article", "ApplicationRecord", [
      Ruby2CR::Association.new(:has_many, "comments", {"dependent" => "destroy"}),
    ], [
      Ruby2CR::Validation.new("title", "presence"),
      Ruby2CR::Validation.new("body", "presence"),
      Ruby2CR::Validation.new("body", "length", {"minimum" => "10"}),
    ])

    ast = Ruby2CR::PrismTranslator.translate(ruby)
    ast = ast.transform(Ruby2CR::StripCallbacks.new)
    ast = ast.transform(Ruby2CR::ModelBoilerplate.new(schema, model_info))

    output = ast.to_s
    output.should contain "class Article < ApplicationRecord"
    output.should contain "model"
    output.should contain "\"articles\""
    output.should contain "column(title, String)"
    output.should contain "column(body, String)"
    output.should contain "has_many"
    output.should contain "validates"
    output.should contain "run_validations"
    output.should contain "validate_presence_title"
    output.should contain "validate_length_body"
    output.should contain "destroy"
    output.should contain "comments.destroy_all"
    output.should_not contain "broadcasts_to"
  end
end
