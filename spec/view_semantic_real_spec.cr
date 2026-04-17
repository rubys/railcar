require "spec"
require "../src/generator/view_semantic_analyzer"
require "../src/generator/erb_compiler"
require "../src/generator/source_parser"
require "../src/generator/prism_translator"
require "../src/generator/inflector"
require "../src/generator/ast_dump"
require "../src/filters/instance_var_to_local"
require "../src/filters/rails_helpers"
require "../src/filters/view_cleanup"
require "../src/filters/buf_to_interpolation"
require "../src/filters/link_to_path_helper"
require "../src/filters/button_to_path_helper"
require "../src/filters/render_to_partial"
require "../src/filters/form_to_html"
require "../src/filters/turbo_stream_connect"
require "./view_semantic_analyzer_spec"

# Iteratively: feed real blog views through ViewSemanticAnalyzer. When
# they fail to type, note what's missing and add stubs / narrow the
# surface. This spec documents progress.
#
# As stubs are added to ViewSemanticAnalyzer, more views should start
# typing successfully. Expected to be expanded over multiple passes.

BLOG_VIEWS_ROOT = File.expand_path("../build/demo/blog/app/views", __DIR__)

module SpecHelpers
  # Apply the shared view filter chain to an ERB string, returning a
  # filtered AST (Expressions containing the render def). `locals` are
  # the parameter names of the target render function — bare Call nodes
  # matching these get rewritten to Var so semantic resolves them as args.
  def self.filter_view(erb : String, locals : Array(String)) : Crystal::ASTNode
    ruby_src = Railcar::ErbCompiler.new(erb).src
    ast = Railcar::SourceParser.parse_source(ruby_src, "view.rb")
    ast = ast.transform(Railcar::InstanceVarToLocal.new)
    ast = ast.transform(Railcar::RailsHelpers.new)
    ast = ast.transform(Railcar::LinkToPathHelper.new)
    ast = ast.transform(Railcar::ButtonToPathHelper.new)
    ast = ast.transform(Railcar::RenderToPartial.new)
    ast = ast.transform(Railcar::FormToHTML.new)
    ast = ast.transform(Railcar::TurboStreamConnect.new)
    ast = ast.transform(Railcar::ViewCleanup.new)
    ast = Railcar::ViewCleanup.calls_to_vars(ast, locals + ["_buf"])
    ast
  end

  # Find the `def render` inside the filtered AST and return its body.
  def self.extract_render_body(ast : Crystal::ASTNode) : Crystal::ASTNode?
    case ast
    when Crystal::Def
      return ast.body if ast.name == "render"
    when Crystal::Expressions
      ast.expressions.each do |e|
        if found = extract_render_body(e)
          return found
        end
      end
    end
    nil
  end
end

describe "ViewSemanticAnalyzer on real blog views" do
  # Skip if the demo blog isn't present (developer hasn't run make test)
  pending "typing" if !Dir.exists?(BLOG_VIEWS_ROOT)

  it "types comments/_comment.html.erb end-to-end" do
    # This partial references: comment.commenter, comment.body,
    # dom_id(comment), button_to(..., [comment.article, comment], method:,
    # data:). All should type with the current helper stub set.
    next unless Dir.exists?(BLOG_VIEWS_ROOT)

    erb = File.read(File.join(BLOG_VIEWS_ROOT, "comments/_comment.html.erb"))
    filtered = SpecHelpers.filter_view(erb, ["comment"])
    body = SpecHelpers.extract_render_body(filtered).not_nil!

    comment_arg = Crystal::Arg.new("comment", nil, Crystal::Path.new("Comment"))
    view_def = Crystal::Def.new("render", [comment_arg], body,
      return_type: Crystal::Path.new("String"))

    analyzer = Railcar::ViewSemanticAnalyzer.new(Railcar.app_for_analyzer_spec)
    analyzer.add_view("comments/_comment", view_def)
    analyzer.analyze.should be_true

    typed = analyzer.typed_body_for("comments/_comment").not_nil!

    # comment.commenter should be String
    commenter = Railcar.find_call(typed, "commenter").not_nil!
    commenter.type?.to_s.should eq "String"
    commenter.obj.not_nil!.type?.to_s.should eq "Comment"
  end

  it "types articles/show.html.erb (includes render @article.comments, form_with, notice)" do
    next unless Dir.exists?(BLOG_VIEWS_ROOT)

    erb = File.read(File.join(BLOG_VIEWS_ROOT, "articles/show.html.erb"))
    filtered = SpecHelpers.filter_view(erb, ["article", "notice", "form"])
    body = SpecHelpers.extract_render_body(filtered).not_nil!

    article_arg = Crystal::Arg.new("article", nil, Crystal::Path.new("Article"))
    # notice is an implicit flash-style param supplied by the controller; default
    # value so it's always bound for type-checking, even if the view reads it.
    notice_arg = Crystal::Arg.new("notice", Crystal::StringLiteral.new(""),
      Crystal::Path.new("String"))
    view_def = Crystal::Def.new("render", [article_arg, notice_arg], body,
      return_type: Crystal::Path.new("String"))

    analyzer = Railcar::ViewSemanticAnalyzer.new(Railcar.app_for_analyzer_spec)
    # The show view does `render @article.comments` which expands to
    # render_comment_partial — needs to be declared for stubs.
    analyzer.partial_names = ["comment", "form"]
    analyzer.add_view("articles/show", view_def)
    analyzer.analyze.should be_true

    typed = analyzer.typed_body_for("articles/show").not_nil!
    # article.title → String; article.comments → Array(Comment)
    Railcar.find_call(typed, "title").not_nil!.type?.to_s.should eq "String"
  end

  it "types articles/index.html.erb with a plural Array param" do
    next unless Dir.exists?(BLOG_VIEWS_ROOT)

    erb = File.read(File.join(BLOG_VIEWS_ROOT, "articles/index.html.erb"))
    filtered = SpecHelpers.filter_view(erb, ["articles", "notice"])
    body = SpecHelpers.extract_render_body(filtered).not_nil!

    # Parse `Array(Article)` via Crystal's parser — constructing it as a
    # Generic node by hand produces a shape semantic doesn't always resolve.
    array_restriction = Crystal::Parser.parse("x : Array(Article)").as(Crystal::TypeDeclaration).declared_type
    articles_arg = Crystal::Arg.new("articles", nil, array_restriction)
    notice_arg = Crystal::Arg.new("notice", Crystal::StringLiteral.new(""),
      Crystal::Path.new("String"))
    view_def = Crystal::Def.new("render", [articles_arg, notice_arg], body,
      return_type: Crystal::Path.new("String"))

    analyzer = Railcar::ViewSemanticAnalyzer.new(Railcar.app_for_analyzer_spec)
    analyzer.partial_names = ["article"]  # render @articles → render_article_partial
    analyzer.add_view("articles/index", view_def)
    analyzer.analyze.should be_true
  end
end
