require "spec"
require "compiler/crystal/syntax"
require "../src/generator/app_model"
require "../src/generator/type_resolver"
require "../src/generator/rust_view_emitter"

module Railcar
  private def self.blog_app_for_rust_spec : AppModel
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

  def self.make_rust_emitter : {RustViewEmitter, TypeResolver}
    app = blog_app_for_rust_spec
    resolver = TypeResolver.new(app)
    emitter = RustViewEmitter.new(app, "article", resolver)
    {emitter, resolver}
  end
end

describe Railcar::RustViewEmitter do
  describe "literal/simple expressions" do
    it "emits a string literal with .to_string()" do
      emitter, _ = Railcar.make_rust_emitter
      emitter.to_rust(Crystal::StringLiteral.new("hello")).should eq %("hello".to_string())
    end

    it "emits a number literal" do
      emitter, _ = Railcar.make_rust_emitter
      emitter.to_rust(Crystal::NumberLiteral.new("42", :i64)).should eq "42"
    end

    it "emits a variable by name" do
      emitter, _ = Railcar.make_rust_emitter
      emitter.to_rust(Crystal::Var.new("article")).should eq "article"
    end
  end

  describe "schema field access" do
    it "emits column access as a field (no parens)" do
      emitter, _ = Railcar.make_rust_emitter
      call = Crystal::Call.new(Crystal::Var.new("article"), "title")
      emitter.to_rust(call).should eq "article.title"
    end

    it "emits id as a field" do
      emitter, _ = Railcar.make_rust_emitter
      call = Crystal::Call.new(Crystal::Var.new("article"), "id")
      emitter.to_rust(call).should eq "article.id"
    end

    it "unwraps has_many associations to Vec via unwrap_or_default" do
      emitter, _ = Railcar.make_rust_emitter
      call = Crystal::Call.new(Crystal::Var.new("article"), "comments")
      emitter.to_rust(call).should eq "article.comments().unwrap_or_default()"
    end
  end

  describe "MethodMap lookups driven by TypeResolver" do
    it "resolves String#empty? via MethodMap" do
      # article.title.empty? — title is String column → .is_empty()
      # Critically: before TypeResolver, the Rust emitter used lookup_method(:rust, "Any", ...)
      # and the "Any" fallback for empty? was ".is_empty()" — same result here,
      # but the resolver ensures we're reading the right row in the table.
      emitter, _ = Railcar.make_rust_emitter
      title = Crystal::Call.new(Crystal::Var.new("article"), "title")
      empty = Crystal::Call.new(title, "empty?")
      emitter.to_rust(empty).should eq "article.title.is_empty()"
    end

    it "resolves String#downcase to .to_lowercase() on a String column" do
      emitter, _ = Railcar.make_rust_emitter
      title = Crystal::Call.new(Crystal::Var.new("article"), "title")
      down = Crystal::Call.new(title, "downcase")
      emitter.to_rust(down).should eq "article.title.to_lowercase()"
    end

    it "resolves String#include? to .contains(ARG0)" do
      emitter, _ = Railcar.make_rust_emitter
      title = Crystal::Call.new(Crystal::Var.new("article"), "title")
      inc = Crystal::Call.new(title, "include?", [Crystal::StringLiteral.new("foo")] of Crystal::ASTNode)
      emitter.to_rust(inc).should eq %(article.title.contains("foo".to_string()))
    end

    it "resolves nil? via the Any mapping" do
      emitter, _ = Railcar.make_rust_emitter
      # article is a bound model; nil? falls through to MethodMap "Any" row.
      # Rust mapping is "RECV.is_none()" under the assumption of Option types.
      call = Crystal::Call.new(Crystal::Var.new("article"), "nil?")
      emitter.to_rust(call).should eq "article.is_none()"
    end

    it "uses Array#first mapping for a bound Array local" do
      # Demonstrates TypeResolver improving over the old hardcoded "Any":
      # Array#first maps to .first() (not the generic "Any" lookup which has
      # no first entry).
      emitter, resolver = Railcar.make_rust_emitter
      resolver.bind("xs", "Array")
      call = Crystal::Call.new(Crystal::Var.new("xs"), "first")
      emitter.to_rust(call).should eq "xs.first()"
    end

    it "uses Array#join mapping for a bound Array local" do
      emitter, resolver = Railcar.make_rust_emitter
      resolver.bind("xs", "Array")
      call = Crystal::Call.new(Crystal::Var.new("xs"), "join",
        [Crystal::StringLiteral.new(", ")] of Crystal::ASTNode)
      emitter.to_rust(call).should eq %(xs.join(", ".to_string()))
    end
  end

  describe "loop body emission" do
    it "emits a for loop over a bare collection" do
      emitter, _ = Railcar.make_rust_emitter
      block = Crystal::Block.new(
        [Crystal::Var.new("c")] of Crystal::Var,
        Crystal::Nop.new,
      )
      each_call = Crystal::Call.new(Crystal::Var.new("comments"), "each", block: block)
      io = IO::Memory.new
      emitter.emit_body(each_call, io, "")
      io.to_s.should contain "for c in comments"
    end
  end
end
