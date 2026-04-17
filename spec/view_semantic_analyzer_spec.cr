require "spec"
require "ast-builder"
require "../src/generator/view_semantic_analyzer"
require "../src/generator/prism_translator"
require "../src/generator/ast_dump"

# Builder helper for concise AST construction in specs. Crystal's spec DSL
# uses top-level blocks rather than classes, so we expose the builder's
# methods via a module extended onto itself and reference them as `B.foo`.
module B
  extend self
  include CrystalAST::Builder
end

module Railcar
  def self.app_for_analyzer_spec : AppModel
    articles = TableSchema.new("articles", [
      Column.new("id", "integer"),
      Column.new("title", "string"),
      Column.new("body", "text"),
      Column.new("view_count", "integer"),
    ])
    comments = TableSchema.new("comments", [
      Column.new("id", "integer"),
      Column.new("article_id", "references"),
      Column.new("commenter", "string"),
      Column.new("body", "text"),
    ])

    article = ModelInfo.new(
      name: "Article",
      superclass: "ApplicationRecord",
      associations: [Association.new(:has_many, "comments")],
      validations: [] of Validation,
    )
    comment = ModelInfo.new(
      name: "Comment",
      superclass: "ApplicationRecord",
      associations: [Association.new(:belongs_to, "article")],
      validations: [] of Validation,
    )

    # Mirror the blog routes: resources :articles with nested :comments.
    routes = RouteSet.new
    routes.add(Route.new("GET", "/articles", "articles", "index", "articles"))
    routes.add(Route.new("POST", "/articles", "articles", "create", nil))
    routes.add(Route.new("GET", "/articles/new", "articles", "new", "new_article"))
    routes.add(Route.new("GET", "/articles/:id/edit", "articles", "edit", "edit_article"))
    routes.add(Route.new("GET", "/articles/:id", "articles", "show", "article"))
    routes.add(Route.new("PATCH", "/articles/:id", "articles", "update", nil))
    routes.add(Route.new("DELETE", "/articles/:id", "articles", "destroy", nil))
    routes.add(Route.new("POST", "/articles/:article_id/comments", "comments",
      "create", "article_comments"))
    routes.add(Route.new("DELETE", "/articles/:article_id/comments/:id", "comments",
      "destroy", "article_comment"))

    AppModel.new("blog", [articles, comments],
      {"Article" => article, "Comment" => comment},
      [] of ControllerInfo, routes)
  end

  # Recursively find a Call node whose name matches.
  def self.find_call(node : Crystal::ASTNode?, name : String) : Crystal::Call?
    return nil if node.nil?
    case node
    when Crystal::Call
      return node if node.name == name
      find_call(node.obj, name) ||
        node.args.each_with_object(nil) { |a, acc| break acc if acc; break find_call(a, name) }.as(Crystal::Call?) ||
        (blk = node.block; blk ? find_call(blk.body, name) : nil)
    when Crystal::Expressions
      node.expressions.each do |e|
        if found = find_call(e, name)
          return found
        end
      end
      nil
    when Crystal::Assign
      find_call(node.value, name)
    when Crystal::OpAssign
      find_call(node.value, name)
    when Crystal::If
      find_call(node.cond, name) || find_call(node.then, name) || find_call(node.else, name)
    else
      nil
    end
  end
end

describe Railcar::ViewSemanticAnalyzer do
  app = Railcar.app_for_analyzer_spec

  it "types a simple show view body" do
    # def render(article : Article) : String
    #   _buf = ""
    #   _buf += article.title
    #   _buf
    # end
    body = B.exprs([
      B.assign("_buf", B.str("")).as(Crystal::ASTNode),
      B.op_assign(B.var("_buf"), "+", B.call(B.var("article"), "title")).as(Crystal::ASTNode),
      B.var("_buf").as(Crystal::ASTNode),
    ])
    view_def = B.def_("render", [B.arg("article", restriction: B.path("Article"))],
      body, return_type: B.path("String"))

    analyzer = Railcar::ViewSemanticAnalyzer.new(app)
    analyzer.add_view("articles/show", view_def)
    analyzer.analyze.should be_true

    typed = analyzer.typed_body_for("articles/show")
    typed.should_not be_nil

    # Find article.title inside the typed body; verify it's String on Article
    t = Railcar.find_call(typed, "title").not_nil!
    t.type?.to_s.should eq "String"
    t.obj.not_nil!.type?.to_s.should eq "Article"
  end

  it "types an each-block's implicit block arg from has_many associations" do
    # def render(article : Article) : String
    #   _buf = ""
    #   article.comments.each do |c|
    #     _buf += c.commenter
    #   end
    #   _buf
    # end
    each_call = B.call(
      B.call(B.var("article"), "comments"),
      "each",
      block: B.block(["c"], B.op_assign(B.var("_buf"), "+", B.call(B.var("c"), "commenter")))
    )

    body = B.exprs([
      B.assign("_buf", B.str("")).as(Crystal::ASTNode),
      each_call.as(Crystal::ASTNode),
      B.var("_buf").as(Crystal::ASTNode),
    ])
    view_def = B.def_("render", [B.arg("article", restriction: B.path("Article"))],
      body, return_type: B.path("String"))

    analyzer = Railcar::ViewSemanticAnalyzer.new(app)
    analyzer.add_view("articles/show", view_def)
    analyzer.analyze.should be_true

    typed = analyzer.typed_body_for("articles/show")
    typed.should_not be_nil

    # article.comments → Array(Comment)
    comments = Railcar.find_call(typed, "comments").not_nil!
    comments.type?.to_s.should eq "Array(Comment)"

    # c.commenter → String (inside the block, c bound to Comment via the iteration)
    commenter = Railcar.find_call(typed, "commenter").not_nil!
    commenter.type?.to_s.should eq "String"
    commenter.obj.not_nil!.type?.to_s.should eq "Comment"
  end

  it "handles multiple views in one analyzer pass" do
    # Two views share an analyzer; both should be typed in the same semantic run.
    show_body = B.exprs([
      B.assign("_buf", B.str("")).as(Crystal::ASTNode),
      B.op_assign(B.var("_buf"), "+",
        B.call(B.var("article"), "title")).as(Crystal::ASTNode),
      B.var("_buf").as(Crystal::ASTNode),
    ])
    show_def = B.def_("render", [B.arg("article", restriction: B.path("Article"))],
      show_body, return_type: B.path("String"))

    partial_body = B.exprs([
      B.assign("_buf", B.str("")).as(Crystal::ASTNode),
      B.op_assign(B.var("_buf"), "+",
        B.call(B.var("comment"), "body")).as(Crystal::ASTNode),
      B.var("_buf").as(Crystal::ASTNode),
    ])
    partial_def = B.def_("render", [B.arg("comment", restriction: B.path("Comment"))],
      partial_body, return_type: B.path("String"))

    analyzer = Railcar::ViewSemanticAnalyzer.new(app)
    analyzer.add_view("articles/show", show_def)
    analyzer.add_view("comments/_comment", partial_def)
    analyzer.analyze.should be_true

    show_typed = analyzer.typed_body_for("articles/show").not_nil!
    Railcar.find_call(show_typed, "title").not_nil!.type?.to_s.should eq "String"

    partial_typed = analyzer.typed_body_for("comments/_comment").not_nil!
    Railcar.find_call(partial_typed, "body").not_nil!.type?.to_s.should eq "String"
  end

  it "returns nil for an unknown view id" do
    analyzer = Railcar::ViewSemanticAnalyzer.new(app)
    analyzer.typed_body_for("does/not/exist").should be_nil
  end

  it "returns true without running anything when there are no views" do
    analyzer = Railcar::ViewSemanticAnalyzer.new(app)
    analyzer.analyze.should be_true
  end
end
