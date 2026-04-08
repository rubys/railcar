require "spec"
require "compiler/crystal/syntax"
require "../src/filters/instance_var_to_local"
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
