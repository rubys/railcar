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

describe Railcar::InstanceVarToLocal do
  filter = Railcar::InstanceVarToLocal.new

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
    ast = Railcar::PrismTranslator.translate("@article = Article.find(1)")
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
    ast = Railcar::PrismTranslator.translate(ruby)
    result = ast.transform(filter)
    output = result.to_s

    output.should contain "comment = article.comments.build"
    output.should contain "comment.save"
    output.should contain "redirect_to(article)"
    output.should_not contain "@"
  end
end

describe Railcar::ParamsExpect do
  filter = Railcar::ParamsExpect.new

  it "converts params.expect(:id) to id" do
    ast = Railcar::PrismTranslator.translate("params.expect(:id)")
    result = ast.transform(filter)
    result.to_s.should eq "id"
  end

  it "converts params.expect(:article_id) to article_id" do
    ast = Railcar::PrismTranslator.translate("params.expect(:article_id)")
    result = ast.transform(filter)
    result.to_s.should eq "article_id"
  end

  it "leaves non-symbol expect unchanged" do
    ast = Railcar::PrismTranslator.translate("params.expect(article: [:title, :body])")
    result = ast.transform(filter)
    result.to_s.should contain "expect"
  end

  it "transforms within larger expression" do
    ast = Railcar::PrismTranslator.translate("Article.find(params.expect(:id))")
    result = ast.transform(filter)
    result.to_s.should eq "Article.find(id)"
  end
end

describe Railcar::ModelNamespace do
  filter = Railcar::ModelNamespace.new(["Article", "Comment"])

  it "namespaces known model constants" do
    node = Crystal::Path.new("Article")
    result = filter.transform(node)
    result.to_s.should eq "Railcar::Article"
  end

  it "leaves unknown constants unchanged" do
    node = Crystal::Path.new("String")
    result = filter.transform(node)
    result.to_s.should eq "String"
  end

  it "leaves already-namespaced paths unchanged" do
    node = Crystal::Path.new(["Railcar", "Article"])
    result = filter.transform(node)
    result.to_s.should eq "Railcar::Article"
  end

  it "transforms in translated source" do
    ast = Railcar::PrismTranslator.translate("Article.find(1)")
    result = ast.transform(filter)
    result.to_s.should eq "Railcar::Article.find(1)"
  end
end

describe Railcar::RedirectToResponse do
  filter = Railcar::RedirectToResponse.new

  it "converts redirect_to with notice" do
    ast = Railcar::PrismTranslator.translate("redirect_to article, notice: \"Created.\"")
    result = ast.transform(filter)
    output = result.to_s
    output.should contain "FLASH_STORE"
    output.should contain "Created."
    output.should contain "302"
    output.should contain "article_path(article)"
  end

  it "converts redirect_to path helper" do
    ast = Railcar::PrismTranslator.translate("redirect_to articles_path")
    result = ast.transform(filter)
    output = result.to_s
    output.should contain "302"
    output.should contain "articles_path"
  end

  it "leaves non-redirect calls unchanged" do
    ast = Railcar::PrismTranslator.translate("puts \"hello\"")
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

    ast = Railcar::PrismTranslator.translate(ruby)

    # Apply filters in order
    ast = ast.transform(Railcar::InstanceVarToLocal.new)
    ast = ast.transform(Railcar::ParamsExpect.new)
    ast = ast.transform(Railcar::RedirectToResponse.new)
    ast = ast.transform(Railcar::ModelNamespace.new(["Article", "Comment"]))

    output = ast.to_s
    output.should contain "comment = article.comments.build"
    output.should contain "comment.save"
    output.should contain "FLASH_STORE"
    output.should contain "article_path(article)"
    output.should contain "302"
    output.should_not contain "@"
  end
end

describe Railcar::RespondToHTML do
  filter = Railcar::RespondToHTML.new

  it "extracts html body from respond_to" do
    ruby = <<-RUBY
    respond_to do |format|
      format.html { redirect_to articles_path }
      format.json { render json: articles }
    end
    RUBY
    ast = Railcar::PrismTranslator.translate(ruby)
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
    ast = Railcar::PrismTranslator.translate(ruby)
    result = ast.transform(filter)
    output = result.to_s
    output.should contain "redirect_to"
    output.should_not contain "respond_to"
    output.should_not contain "format"
  end

  it "leaves non-respond_to calls unchanged" do
    ast = Railcar::PrismTranslator.translate("foo(1)")
    result = ast.transform(filter)
    result.to_s.should eq "foo(1)"
  end
end

describe Railcar::StrongParams do
  filter = Railcar::StrongParams.new

  it "converts Model.new(article_params)" do
    ast = Railcar::PrismTranslator.translate("Article.new(article_params)")
    result = ast.transform(filter)
    output = result.to_s
    output.should contain "extract_model_params"
    output.should contain "\"article\""
  end

  it "converts article.update(article_params)" do
    ast = Railcar::PrismTranslator.translate("article.update(article_params)")
    result = ast.transform(filter)
    output = result.to_s
    output.should contain "extract_model_params"
    output.should contain "\"article\""
  end

  it "converts comments.build(comment_params)" do
    ast = Railcar::PrismTranslator.translate("article.comments.build(comment_params)")
    result = ast.transform(filter)
    output = result.to_s
    output.should contain "extract_model_params"
    output.should contain "\"comment\""
  end

  it "leaves non-params arguments unchanged" do
    ast = Railcar::PrismTranslator.translate("Article.new(attrs)")
    result = ast.transform(filter)
    result.to_s.should eq "Article.new(attrs)"
  end
end

describe Railcar::RenderToECR do
  filter = Railcar::RenderToECR.new("articles")

  it "converts render :new" do
    ast = Railcar::PrismTranslator.translate("render :new")
    result = ast.transform(filter)
    output = result.to_s
    output.should contain "response.print"
    output.should contain "layout"
    output.should contain "ECR.embed"
    output.should contain "articles/new.ecr"
  end

  it "converts render :edit with status" do
    ast = Railcar::PrismTranslator.translate("render :edit, status: :unprocessable_entity")
    result = ast.transform(filter)
    output = result.to_s
    output.should contain "422"
    output.should contain "ECR.embed"
    output.should contain "articles/edit.ecr"
  end

  it "leaves non-render calls unchanged" do
    ast = Railcar::PrismTranslator.translate("redirect_to articles_path")
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

    ast = Railcar::PrismTranslator.translate(ruby)
    ast = ast.transform(Railcar::InstanceVarToLocal.new)
    ast = ast.transform(Railcar::ParamsExpect.new)
    ast = ast.transform(Railcar::RespondToHTML.new)
    ast = ast.transform(Railcar::StrongParams.new)
    ast = ast.transform(Railcar::RedirectToResponse.new)
    ast = ast.transform(Railcar::RenderToECR.new("articles"))
    ast = ast.transform(Railcar::ModelNamespace.new(["Article", "Comment"]))

    output = ast.to_s
    output.should contain "Railcar::Article.new(extract_model_params(params, \"article\"))"
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

describe Railcar::StripCallbacks do
  filter = Railcar::StripCallbacks.new

  it "strips broadcasts_to" do
    ast = Railcar::PrismTranslator.translate("broadcasts_to :articles")
    result = ast.transform(filter)
    result.to_s.strip.should eq ""
  end

  it "strips after_create_commit" do
    ast = Railcar::PrismTranslator.translate("after_create_commit { do_something }")
    result = ast.transform(filter)
    result.to_s.strip.should eq ""
  end

  it "leaves model declarations unchanged" do
    ast = Railcar::PrismTranslator.translate("has_many :comments, dependent: :destroy")
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

    schema = Railcar::TableSchema.new("articles", [
      Railcar::Column.new("title", "string"),
      Railcar::Column.new("body", "text"),
      Railcar::Column.new("created_at", "datetime"),
      Railcar::Column.new("updated_at", "datetime"),
    ])
    model_info = Railcar::ModelInfo.new("Article", "ApplicationRecord", [
      Railcar::Association.new(:has_many, "comments", {"dependent" => "destroy"}),
    ], [
      Railcar::Validation.new("title", "presence"),
      Railcar::Validation.new("body", "presence"),
      Railcar::Validation.new("body", "length", {"minimum" => "10"}),
    ])

    ast = Railcar::PrismTranslator.translate(ruby)
    ast = ast.transform(Railcar::StripCallbacks.new)
    ast = ast.transform(Railcar::ModelBoilerplate.new(schema, model_info))

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

# --- Isolated filter tests for boilerplate filters ---

describe Railcar::ControllerSignature do
  it "adds response parameter to actions" do
    ast = Railcar::PrismTranslator.translate("def index\nend")
    result = ast.transform(Railcar::ControllerSignature.new("articles", nil, [] of Railcar::BeforeAction))
    output = result.to_s
    output.should contain "response"
    output.should contain "HTTP::Server::Response"
  end

  it "adds id parameter to show/edit/update/destroy" do
    ast = Railcar::PrismTranslator.translate("def show\nend")
    result = ast.transform(Railcar::ControllerSignature.new("articles", nil, [] of Railcar::BeforeAction))
    output = result.to_s
    output.should contain "id : Int64"
  end

  it "adds params parameter to create/update" do
    ast = Railcar::PrismTranslator.translate("def create\nend")
    result = ast.transform(Railcar::ControllerSignature.new("articles", nil, [] of Railcar::BeforeAction))
    output = result.to_s
    output.should contain "params : Hash(String, String)"
  end

  it "adds flash consumption for render actions" do
    ast = Railcar::PrismTranslator.translate("def index\nend")
    result = ast.transform(Railcar::ControllerSignature.new("articles", nil, [] of Railcar::BeforeAction))
    output = result.to_s
    output.should contain "FLASH_STORE"
    output.should contain "notice"
  end

  it "inlines before_action model loading" do
    before = [Railcar::BeforeAction.new("set_article", ["show", "edit", "update", "destroy"])]
    ast = Railcar::PrismTranslator.translate("def show\nend")
    result = ast.transform(Railcar::ControllerSignature.new("articles", nil, before))
    output = result.to_s
    output.should contain "Article.find(id)"
  end

  it "strips set_ and _params methods" do
    ruby = "def set_article\nend\ndef article_params\nend\ndef index\nend"
    ast = Railcar::PrismTranslator.translate(ruby)
    result = ast.transform(Railcar::ControllerSignature.new("articles", nil, [] of Railcar::BeforeAction))
    output = result.to_s
    output.should_not contain "set_article"
    output.should_not contain "article_params"
    output.should contain "index"
  end

  it "adds view rendering for display actions" do
    ast = Railcar::PrismTranslator.translate("def index\nend")
    result = ast.transform(Railcar::ControllerSignature.new("articles", nil, [] of Railcar::BeforeAction))
    output = result.to_s
    output.should contain "ECR.embed"
    output.should contain "articles/index.ecr"
  end

  it "adds nested parent id parameter" do
    ast = Railcar::PrismTranslator.translate("def create\nend")
    result = ast.transform(Railcar::ControllerSignature.new("comments", "article", [] of Railcar::BeforeAction))
    output = result.to_s
    output.should contain "article_id"
  end
end

describe Railcar::ControllerBoilerplate do
  it "injects include statements" do
    ruby = "class ArticlesController\ndef index\nend\nend"
    ast = Railcar::PrismTranslator.translate(ruby)
    result = ast.transform(Railcar::ControllerBoilerplate.new("articles", "/tmp/nonexistent"))
    output = result.to_s
    output.should contain "include RouteHelpers"
    output.should contain "include ViewHelpers"
  end

  it "injects extract_model_params helper" do
    ruby = "class ArticlesController\ndef index\nend\nend"
    ast = Railcar::PrismTranslator.translate(ruby)
    result = ast.transform(Railcar::ControllerBoilerplate.new("articles", "/tmp/nonexistent"))
    output = result.to_s
    output.should contain "extract_model_params"
    output.should contain "Hash(String, DB::Any)"
  end

  it "injects layout helper" do
    ruby = "class ArticlesController\ndef index\nend\nend"
    ast = Railcar::PrismTranslator.translate(ruby)
    result = ast.transform(Railcar::ControllerBoilerplate.new("articles", "/tmp/nonexistent"))
    output = result.to_s
    output.should contain "def layout(title : String, &)"
    output.should contain "yield"
    output.should contain "ECR.embed"
    output.should contain "application.ecr"
  end

  it "preserves existing class body" do
    ruby = "class ArticlesController\ndef index\nend\nend"
    ast = Railcar::PrismTranslator.translate(ruby)
    result = ast.transform(Railcar::ControllerBoilerplate.new("articles", "/tmp/nonexistent"))
    output = result.to_s
    output.should contain "def index"
  end

  it "skips non-controller classes" do
    ruby = "class Article\nend"
    ast = Railcar::PrismTranslator.translate(ruby)
    result = ast.transform(Railcar::ControllerBoilerplate.new("articles", "/tmp/nonexistent"))
    output = result.to_s
    output.should_not contain "RouteHelpers"
  end
end

describe Railcar::ModelBoilerplate do
  schema = Railcar::TableSchema.new("articles", [
    Railcar::Column.new("title", "string"),
    Railcar::Column.new("body", "text"),
  ])
  model = Railcar::ModelInfo.new("Article", "ApplicationRecord",
    [] of Railcar::Association,
    [Railcar::Validation.new("title", "presence")])

  it "wraps body in model block with columns" do
    ruby = "class Article < ApplicationRecord\nvalidates :title, presence: true\nend"
    ast = Railcar::PrismTranslator.translate(ruby)
    result = ast.transform(Railcar::ModelBoilerplate.new(schema, model))
    output = result.to_s
    output.should contain "model(\"articles\")"
    output.should contain "column(title, String)"
    output.should contain "column(body, String)"
  end

  it "generates run_validations for presence validations" do
    ruby = "class Article < ApplicationRecord\nvalidates :title, presence: true\nend"
    ast = Railcar::PrismTranslator.translate(ruby)
    result = ast.transform(Railcar::ModelBoilerplate.new(schema, model))
    output = result.to_s
    output.should contain "run_validations"
    output.should contain "validate_presence_title"
  end

  it "generates destroy override for dependent associations" do
    schema_with_fk = Railcar::TableSchema.new("articles", [Railcar::Column.new("title", "string")])
    model_with_dep = Railcar::ModelInfo.new("Article", "ApplicationRecord",
      [Railcar::Association.new(:has_many, "comments", {"dependent" => "destroy"})],
      [] of Railcar::Validation)

    ruby = "class Article < ApplicationRecord\nhas_many :comments, dependent: :destroy\nend"
    ast = Railcar::PrismTranslator.translate(ruby)
    result = ast.transform(Railcar::ModelBoilerplate.new(schema_with_fk, model_with_dep))
    output = result.to_s
    output.should contain "def destroy"
    output.should contain "comments.destroy_all"
    output.should contain "super"
  end

  it "skips run_validations when no validations" do
    empty_model = Railcar::ModelInfo.new("Article", "ApplicationRecord",
      [] of Railcar::Association, [] of Railcar::Validation)

    ruby = "class Article < ApplicationRecord\nend"
    ast = Railcar::PrismTranslator.translate(ruby)
    result = ast.transform(Railcar::ModelBoilerplate.new(schema, empty_model))
    output = result.to_s
    output.should_not contain "run_validations"
  end
end
