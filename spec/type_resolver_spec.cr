require "spec"
require "compiler/crystal/syntax"
require "../src/generator/type_resolver"
require "../src/generator/prism_translator"

module Railcar
  # Build a small AppModel with an Article / Comment domain matching the blog demo.
  private def self.build_blog_app : AppModel
    articles_schema = TableSchema.new("articles", [
      Column.new("id", "integer"),
      Column.new("title", "string"),
      Column.new("body", "text"),
      Column.new("published_at", "datetime"),
      Column.new("view_count", "integer"),
    ])

    comments_schema = TableSchema.new("comments", [
      Column.new("id", "integer"),
      Column.new("article_id", "references"),
      Column.new("commenter", "string"),
      Column.new("body", "text"),
    ])

    article_model = ModelInfo.new(
      name: "Article",
      superclass: "ApplicationRecord",
      associations: [
        Association.new(:has_many, "comments"),
      ],
      validations: [] of Validation,
    )

    comment_model = ModelInfo.new(
      name: "Comment",
      superclass: "ApplicationRecord",
      associations: [
        Association.new(:belongs_to, "article"),
      ],
      validations: [] of Validation,
    )

    AppModel.new(
      "blog",
      [articles_schema, comments_schema],
      {"Article" => article_model, "Comment" => comment_model},
    )
  end

  def self.build_blog_app_for_spec
    build_blog_app
  end
end

describe Railcar::TypeResolver do
  app = Railcar.build_blog_app_for_spec

  describe "#resolve on literals" do
    it "classifies StringLiteral as String" do
      r = Railcar::TypeResolver.new(app)
      r.resolve(Crystal::StringLiteral.new("hi")).should eq "String"
    end

    it "classifies NumberLiteral as Numeric" do
      r = Railcar::TypeResolver.new(app)
      r.resolve(Crystal::NumberLiteral.new("42", :i32)).should eq "Numeric"
    end

    it "classifies ArrayLiteral as Array" do
      r = Railcar::TypeResolver.new(app)
      r.resolve(Crystal::ArrayLiteral.new([Crystal::NumberLiteral.new("1", :i32)] of Crystal::ASTNode)).should eq "Array"
    end

    it "classifies HashLiteral as Hash" do
      r = Railcar::TypeResolver.new(app)
      r.resolve(Crystal::HashLiteral.new([] of Crystal::HashLiteral::Entry)).should eq "Hash"
    end

    it "classifies BoolLiteral as Bool" do
      r = Railcar::TypeResolver.new(app)
      r.resolve(Crystal::BoolLiteral.new(true)).should eq "Bool"
    end

    it "classifies StringInterpolation as String" do
      r = Railcar::TypeResolver.new(app)
      node = Crystal::StringInterpolation.new([Crystal::StringLiteral.new("x")] of Crystal::ASTNode)
      r.resolve(node).should eq "String"
    end
  end

  describe "#resolve on bare identifiers" do
    it "returns the bound type for a local variable" do
      r = Railcar::TypeResolver.new(app)
      r.bind("foo", "String")
      r.resolve(Crystal::Var.new("foo")).should eq "String"
    end

    it "infers a model name from a model-singular identifier" do
      r = Railcar::TypeResolver.new(app)
      r.resolve(Crystal::Var.new("article")).should eq "Article"
    end

    it "infers Array from a model-plural identifier" do
      r = Railcar::TypeResolver.new(app)
      r.resolve(Crystal::Var.new("articles")).should eq "Array"
    end

    it "falls back to Any for unknown identifiers" do
      r = Railcar::TypeResolver.new(app)
      r.resolve(Crystal::Var.new("widget_flob")).should eq "Any"
    end

    it "treats an InstanceVar as the stripped name" do
      r = Railcar::TypeResolver.new(app)
      r.resolve(Crystal::InstanceVar.new("@article")).should eq "Article"
    end
  end

  describe "#resolve on method calls" do
    it "resolves model column access to the column's crystal type" do
      r = Railcar::TypeResolver.new(app)
      call = Crystal::Call.new(Crystal::Var.new("article"), "title")
      r.resolve(call).should eq "String"
    end

    it "resolves integer column to Numeric" do
      r = Railcar::TypeResolver.new(app)
      call = Crystal::Call.new(Crystal::Var.new("article"), "view_count")
      r.resolve(call).should eq "Numeric"
    end

    it "resolves id access to Numeric" do
      r = Railcar::TypeResolver.new(app)
      call = Crystal::Call.new(Crystal::Var.new("article"), "id")
      r.resolve(call).should eq "Numeric"
    end

    it "resolves has_many association access to Array" do
      r = Railcar::TypeResolver.new(app)
      call = Crystal::Call.new(Crystal::Var.new("article"), "comments")
      r.resolve(call).should eq "Array"
    end

    it "resolves belongs_to association access to the target model" do
      r = Railcar::TypeResolver.new(app)
      call = Crystal::Call.new(Crystal::Var.new("comment"), "article")
      r.resolve(call).should eq "Article"
    end
  end

  describe "#resolve on chained calls (the motivating case)" do
    it "resolves article.title.size → String method (String#size)" do
      # title is String; size on String means String type got size called on it
      r = Railcar::TypeResolver.new(app)
      title = Crystal::Call.new(Crystal::Var.new("article"), "title")
      r.resolve(title).should eq "String"
    end

    it "resolves article.comments.size → Array method (Array#size)" do
      r = Railcar::TypeResolver.new(app)
      comments = Crystal::Call.new(Crystal::Var.new("article"), "comments")
      r.resolve(comments).should eq "Array"
    end

    it "knows String#upcase returns String" do
      r = Railcar::TypeResolver.new(app)
      title = Crystal::Call.new(Crystal::Var.new("article"), "title")
      upcased = Crystal::Call.new(title, "upcase")
      r.resolve(upcased).should eq "String"
    end

    it "knows Array#size returns Numeric" do
      r = Railcar::TypeResolver.new(app)
      comments = Crystal::Call.new(Crystal::Var.new("article"), "comments")
      size = Crystal::Call.new(comments, "size")
      r.resolve(size).should eq "Numeric"
    end

    it "knows String#chars returns Array" do
      r = Railcar::TypeResolver.new(app)
      title = Crystal::Call.new(Crystal::Var.new("article"), "title")
      chars = Crystal::Call.new(title, "chars")
      r.resolve(chars).should eq "Array"
    end
  end

  describe "#with_binding" do
    it "returns a resolver with the extra binding" do
      r = Railcar::TypeResolver.new(app)
      r2 = r.with_binding("comment", "Comment")
      r2.resolve(Crystal::Var.new("comment")).should eq "Comment"
      # Original untouched
      r.locals.has_key?("comment").should be_false
    end

    it "preserves prior bindings" do
      r = Railcar::TypeResolver.new(app)
      r.bind("flash", "Hash")
      r2 = r.with_binding("comment", "Comment")
      r2.resolve(Crystal::Var.new("flash")).should eq "Hash"
    end
  end

  describe "edge cases" do
    it "returns Any for an unknown association chain" do
      r = Railcar::TypeResolver.new(app)
      # `article.something_not_in_schema` → Any
      call = Crystal::Call.new(Crystal::Var.new("article"), "something_not_in_schema")
      r.resolve(call).should eq "Any"
    end

    it "handles nested ivars from parsed Ruby source" do
      ast = Railcar::PrismTranslator.translate("@article.title")
      # Extract the expression — PrismTranslator wraps things in Expressions
      call = ast
      call = call.as(Crystal::Expressions).expressions.first if call.is_a?(Crystal::Expressions)
      r = Railcar::TypeResolver.new(app)
      r.resolve(call).should eq "String"
    end
  end
end
