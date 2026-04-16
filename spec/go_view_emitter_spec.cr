require "spec"
require "compiler/crystal/syntax"
require "../src/generator/app_model"
require "../src/generator/type_resolver"
require "../src/generator/go_view_emitter"

module Railcar
  private def self.blog_app_for_go_spec : AppModel
    articles_schema = TableSchema.new("articles", [
      Column.new("id", "integer"),
      Column.new("title", "string"),
      Column.new("body", "text"),
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
      associations: [Association.new(:has_many, "comments")],
      validations: [] of Validation,
    )

    comment_model = ModelInfo.new(
      name: "Comment",
      superclass: "ApplicationRecord",
      associations: [Association.new(:belongs_to, "article")],
      validations: [] of Validation,
    )

    AppModel.new(
      "blog",
      [articles_schema, comments_schema],
      {"Article" => article_model, "Comment" => comment_model},
    )
  end

  def self.make_go_emitter : {GoViewEmitter, TypeResolver}
    app = blog_app_for_go_spec
    resolver = TypeResolver.new(app)
    fields = Set(String).new
    app.schemas.each { |s| s.columns.each { |c| fields << c.name } }
    emitter = GoViewEmitter.new("articles", fields, resolver)
    {emitter, resolver}
  end
end

describe Railcar::GoViewEmitter do
  describe "literal/simple expressions" do
    it "emits a string literal" do
      emitter, _ = Railcar.make_go_emitter
      emitter.to_go(Crystal::StringLiteral.new("hello")).should eq %("hello")
    end

    it "emits a number literal" do
      emitter, _ = Railcar.make_go_emitter
      emitter.to_go(Crystal::NumberLiteral.new("42", :i64)).should eq "42"
    end

    it "emits a bare variable reference" do
      emitter, _ = Railcar.make_go_emitter
      emitter.to_go(Crystal::Var.new("article")).should eq "article"
    end
  end

  describe "schema field access" do
    it "emits column access as a Go struct field (Title)" do
      emitter, _ = Railcar.make_go_emitter
      call = Crystal::Call.new(Crystal::Var.new("article"), "title")
      emitter.to_go(call).should eq "article.Title"
    end

    it "emits id access as .Id" do
      emitter, _ = Railcar.make_go_emitter
      call = Crystal::Call.new(Crystal::Var.new("article"), "id")
      emitter.to_go(call).should eq "article.Id"
    end
  end

  describe "MethodMap lookups driven by TypeResolver (ambiguous cases)" do
    it "resolves String#size to len(string) on a String column" do
      # @article.title.size — title is a String column, size → len(title)
      emitter, _ = Railcar.make_go_emitter
      title = Crystal::Call.new(Crystal::Var.new("article"), "title")
      size_call = Crystal::Call.new(title, "size")
      # Wraps len() around the string field — either way, the result is numeric.
      emitter.to_go(size_call).should eq "len(article.Title)"
    end

    it "wraps has_many .size in helpers.SafeLen (association returns (slice, error))" do
      # This is a Go-specific emitter path that short-circuits before MethodMap:
      # associations return (value, error), so plain len() won't work and we
      # route through a helper. Independent of TypeResolver, but pinned here
      # so a refactor doesn't regress the wrapping.
      emitter, _ = Railcar.make_go_emitter
      comments = Crystal::Call.new(Crystal::Var.new("article"), "comments")
      size_call = Crystal::Call.new(comments, "size")
      emitter.to_go(size_call).should eq "helpers.SafeLen(article.Comments())"
    end

    it "uses String#empty? mapping for a bound local String" do
      # Resolver-only improvement: a bare Var has no known shape to the
      # heuristic ("Any" → len(s) == 0), but with a binding the resolver
      # returns "String" and MethodMap emits the idiomatic s == "".
      emitter, resolver = Railcar.make_go_emitter
      resolver.bind("s", "String")
      call = Crystal::Call.new(Crystal::Var.new("s"), "empty?")
      emitter.to_go(call).should eq %(s == "")
    end

    it "uses Array#any? mapping for a bound local Array" do
      emitter, resolver = Railcar.make_go_emitter
      resolver.bind("xs", "Array")
      call = Crystal::Call.new(Crystal::Var.new("xs"), "any?")
      emitter.to_go(call).should eq "len(xs) > 0"
    end

    it "resolves String#empty? via MethodMap" do
      emitter, _ = Railcar.make_go_emitter
      title = Crystal::Call.new(Crystal::Var.new("article"), "title")
      empty = Crystal::Call.new(title, "empty?")
      emitter.to_go(empty).should eq %(article.Title == "")
    end

    it "resolves String#downcase via MethodMap" do
      emitter, _ = Railcar.make_go_emitter
      title = Crystal::Call.new(Crystal::Var.new("article"), "title")
      down = Crystal::Call.new(title, "downcase")
      emitter.to_go(down).should eq "strings.ToLower(article.Title)"
    end

    it "resolves String#include? via MethodMap" do
      emitter, _ = Railcar.make_go_emitter
      title = Crystal::Call.new(Crystal::Var.new("article"), "title")
      inc = Crystal::Call.new(title, "include?", [Crystal::StringLiteral.new("foo")] of Crystal::ASTNode)
      emitter.to_go(inc).should eq %(strings.Contains(article.Title, "foo"))
    end

    it "resolves Any#nil? to RECV == nil" do
      emitter, _ = Railcar.make_go_emitter
      # nil? on an instance var (pre InstanceVarToLocal treatment)
      nil_call = Crystal::Call.new(Crystal::Var.new("article"), "nil?")
      emitter.to_go(nil_call).should eq "article == nil"
    end
  end

  describe "legacy heuristic (fallback when no resolver)" do
    it "uses AST-shape heuristic when no resolver is attached" do
      emitter = Railcar::GoViewEmitter.new("articles", Set(String).new)
      # Literal string is obviously String
      call = Crystal::Call.new(Crystal::StringLiteral.new("hello"), "downcase")
      emitter.to_go(call).should eq %(strings.ToLower("hello"))
    end
  end
end
