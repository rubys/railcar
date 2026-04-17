require "spec"
require "../src/generator/view_semantic_analyzer"
require "../src/generator/prism_translator"
require "../src/generator/ast_dump"

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

    AppModel.new("blog", [articles, comments],
      {"Article" => article, "Comment" => comment})
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
    article_arg = Crystal::Arg.new("article", nil, Crystal::Path.new("Article"))
    article_var = Crystal::Var.new("article")
    title_call = Crystal::Call.new(article_var, "title")

    body = Crystal::Expressions.new([
      Crystal::Assign.new(Crystal::Var.new("_buf"), Crystal::StringLiteral.new("")).as(Crystal::ASTNode),
      Crystal::OpAssign.new(Crystal::Var.new("_buf"), "+", title_call).as(Crystal::ASTNode),
      Crystal::Var.new("_buf").as(Crystal::ASTNode),
    ])
    view_def = Crystal::Def.new("render", [article_arg], body,
      return_type: Crystal::Path.new("String"))

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
    article_arg = Crystal::Arg.new("article", nil, Crystal::Path.new("Article"))

    c_var = Crystal::Var.new("c")
    commenter_call = Crystal::Call.new(c_var, "commenter")
    block_body = Crystal::OpAssign.new(Crystal::Var.new("_buf"), "+", commenter_call)
    block = Crystal::Block.new([c_var] of Crystal::Var, block_body)
    comments_call = Crystal::Call.new(Crystal::Var.new("article"), "comments")
    each_call = Crystal::Call.new(comments_call, "each", block: block)

    body = Crystal::Expressions.new([
      Crystal::Assign.new(Crystal::Var.new("_buf"), Crystal::StringLiteral.new("")).as(Crystal::ASTNode),
      each_call.as(Crystal::ASTNode),
      Crystal::Var.new("_buf").as(Crystal::ASTNode),
    ])
    view_def = Crystal::Def.new("render", [article_arg], body,
      return_type: Crystal::Path.new("String"))

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
    article_arg = Crystal::Arg.new("article", nil, Crystal::Path.new("Article"))
    comment_arg = Crystal::Arg.new("comment", nil, Crystal::Path.new("Comment"))

    show_body = Crystal::Expressions.new([
      Crystal::Assign.new(Crystal::Var.new("_buf"), Crystal::StringLiteral.new("")).as(Crystal::ASTNode),
      Crystal::OpAssign.new(Crystal::Var.new("_buf"), "+",
        Crystal::Call.new(Crystal::Var.new("article"), "title")).as(Crystal::ASTNode),
      Crystal::Var.new("_buf").as(Crystal::ASTNode),
    ])
    show_def = Crystal::Def.new("render", [article_arg], show_body,
      return_type: Crystal::Path.new("String"))

    partial_body = Crystal::Expressions.new([
      Crystal::Assign.new(Crystal::Var.new("_buf"), Crystal::StringLiteral.new("")).as(Crystal::ASTNode),
      Crystal::OpAssign.new(Crystal::Var.new("_buf"), "+",
        Crystal::Call.new(Crystal::Var.new("comment"), "body")).as(Crystal::ASTNode),
      Crystal::Var.new("_buf").as(Crystal::ASTNode),
    ])
    partial_def = Crystal::Def.new("render", [comment_arg], partial_body,
      return_type: Crystal::Path.new("String"))

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
