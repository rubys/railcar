require "spec"
require "compiler/crystal/syntax"
require "../src/filters/instance_var_to_local"
require "../src/filters/params_expect"
require "../src/filters/model_namespace"
require "../src/filters/redirect_to_response"
require "../src/generator/prism_translator"

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
