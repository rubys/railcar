require "spec"
require "../src/semantic"
require "../src/generator/ast_dump"
require "../src/generator/prism_translator"

# Step 2 POC: run a minimal view-shaped Def through program.semantic() and
# verify that the body's expressions get types populated.
#
# Key finding: Crystal's semantic pass types methods lazily at call sites.
# The original Def in the top-level AST does NOT have types on its body
# nodes — types live on the typed copy at `call.target_defs.first` for
# each call site that reached the method. Consumers that want a typed
# view body must read `target_defs` from an invocation, not the original.

describe "view semantic analysis (Step 2 POC)" do
  it "types a minimal view body through call.target_defs after semantic" do
    # Synthetic equivalent of what a filtered view AST would look like:
    #
    #   def render(comment : Comment) : String
    #     _buf = ""
    #     _buf += comment.commenter
    #     _buf
    #   end
    #
    # The body deliberately uses bare String concatenation rather than the
    # `_buf += str(...)` shape ErbCompiler produces, because `str` isn't a
    # stdlib method and would require its own stub.
    source = <<-CRYSTAL
      class Comment
        property commenter : String = ""
      end

      def render(comment : Comment) : String
        _buf = ""
        _buf += comment.commenter
        _buf
      end

      render(Comment.new)
    CRYSTAL

    ast = Crystal::Parser.parse(source)
    program = Crystal::Program.new
    compiler = Crystal::Compiler.new
    compiler.no_codegen = true
    program.compiler = compiler

    full = Crystal::Expressions.new([
      Crystal::Require.new("prelude").at(Crystal::Location.new("t.cr", 1, 1)).as(Crystal::ASTNode),
      ast,
    ])

    typed = program.semantic(program.normalize(full))

    # Find the invocation: render(Comment.new)
    render_call = find_call_by_name(typed, "render")
    render_call.should_not be_nil
    render_call = render_call.not_nil!

    # The call site should be typed as String (the Def's return type)
    render_call.type?.to_s.should eq "String"

    # The call's target_defs should point to the typed version of the Def
    targets = render_call.target_defs
    targets.should_not be_nil
    targets = targets.not_nil!
    targets.size.should eq 1

    typed_def = targets.first

    # Walk the typed body and find comment.commenter; it should be String
    commenter_call = find_call_by_name(typed_def.body, "commenter")
    commenter_call.should_not be_nil
    commenter_call.not_nil!.type?.to_s.should eq "String"
    # And the receiver resolves to Comment
    recv = commenter_call.not_nil!.obj.not_nil!
    recv.type?.to_s.should eq "Comment"
  end

  it "exposes the typed body via target_defs for multi-argument views" do
    # Now with a has_many-style model (comments returns Array(Comment))
    # and a loop — verifies block args get typed too.
    source = <<-CRYSTAL
      class Comment
        property commenter : String = ""
      end

      class Article
        property title : String = ""
        def comments : Array(Comment)
          [] of Comment
        end
      end

      def render(article : Article) : String
        _buf = ""
        _buf += article.title
        article.comments.each do |c|
          _buf += c.commenter
        end
        _buf
      end

      render(Article.new)
    CRYSTAL

    ast = Crystal::Parser.parse(source)
    program = Crystal::Program.new
    compiler = Crystal::Compiler.new
    compiler.no_codegen = true
    program.compiler = compiler

    full = Crystal::Expressions.new([
      Crystal::Require.new("prelude").at(Crystal::Location.new("t.cr", 1, 1)).as(Crystal::ASTNode),
      ast,
    ])

    typed = program.semantic(program.normalize(full))
    render_call = find_call_by_name(typed, "render").not_nil!

    typed_def = render_call.target_defs.not_nil!.first

    # article.title → String
    title_call = find_call_by_name(typed_def.body, "title").not_nil!
    title_call.type?.to_s.should eq "String"

    # article.comments → Array(Comment)
    comments_call = find_call_by_name(typed_def.body, "comments").not_nil!
    comments_call.type?.to_s.should eq "Array(Comment)"

    # c.commenter inside the each block — c is Comment, commenter returns String
    commenter_call = find_call_by_name(typed_def.body, "commenter").not_nil!
    commenter_call.type?.to_s.should eq "String"
  end
end

# Recursively find the first Call node with the given name. Handles the
# well-known container types; extend as needed.
def find_call_by_name(node : Crystal::ASTNode?, name : String) : Crystal::Call?
  return nil if node.nil?
  case node
  when Crystal::Call
    return node if node.name == name
    if found = find_call_by_name(node.obj, name)
      return found
    end
    node.args.each do |arg|
      if found = find_call_by_name(arg, name)
        return found
      end
    end
    if block = node.block
      if found = find_call_by_name(block.body, name)
        return found
      end
    end
    nil
  when Crystal::Expressions
    node.expressions.each do |e|
      if found = find_call_by_name(e, name)
        return found
      end
    end
    nil
  when Crystal::Assign
    find_call_by_name(node.value, name)
  when Crystal::OpAssign
    find_call_by_name(node.value, name)
  when Crystal::If
    find_call_by_name(node.cond, name) ||
      find_call_by_name(node.then, name) ||
      find_call_by_name(node.else, name)
  when Crystal::Def
    find_call_by_name(node.body, name)
  when Crystal::ClassDef, Crystal::ModuleDef
    find_call_by_name(node.body, name)
  else
    nil
  end
end
