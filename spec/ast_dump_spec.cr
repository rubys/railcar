require "spec"
require "compiler/crystal/syntax"
require "../src/generator/ast_dump"
require "../src/generator/prism_translator"
require "../src/generator/source_parser"
require "../src/filters/instance_var_to_local"
require "../src/filters/rails_helpers"

describe Railcar::AstDump do
  describe "literal nodes" do
    it "dumps StringLiteral" do
      Railcar::AstDump.dump(Crystal::StringLiteral.new("hi"))
        .should eq %((StringLiteral "hi"))
    end

    it "dumps NumberLiteral with kind" do
      Railcar::AstDump.dump(Crystal::NumberLiteral.new("42", :i64))
        .should contain "NumberLiteral 42"
    end

    it "dumps BoolLiteral" do
      Railcar::AstDump.dump(Crystal::BoolLiteral.new(true))
        .should eq "(BoolLiteral true)"
    end

    it "dumps SymbolLiteral" do
      Railcar::AstDump.dump(Crystal::SymbolLiteral.new("foo"))
        .should eq "(SymbolLiteral :foo)"
    end

    it "dumps NilLiteral" do
      Railcar::AstDump.dump(Crystal::NilLiteral.new).should eq "(NilLiteral)"
    end
  end

  describe "identifier nodes" do
    it "dumps Var" do
      Railcar::AstDump.dump(Crystal::Var.new("x")).should eq "(Var x)"
    end

    it "dumps InstanceVar" do
      Railcar::AstDump.dump(Crystal::InstanceVar.new("@x")).should eq "(InstanceVar @x)"
    end

    it "dumps Path" do
      Railcar::AstDump.dump(Crystal::Path.new(["Foo", "Bar"]))
        .should eq "(Path Foo::Bar)"
    end
  end

  describe "compound nodes" do
    it "dumps Call with no obj and no args" do
      node = Crystal::Call.new(nil.as(Crystal::ASTNode?), "foo")
      Railcar::AstDump.dump(node).should eq "(Call \"foo\")"
    end

    it "dumps Call with obj and args" do
      node = Crystal::Call.new(Crystal::Var.new("x"), "plus",
        [Crystal::NumberLiteral.new("1", :i32)] of Crystal::ASTNode)
      dumped = Railcar::AstDump.dump(node)
      dumped.should contain "(Call \"plus\""
      dumped.should contain "obj:"
      dumped.should contain "(Var x)"
      dumped.should contain "args:"
      dumped.should contain "NumberLiteral 1"
    end

    it "dumps Call with named_args" do
      named = [Crystal::NamedArgument.new("class", Crystal::StringLiteral.new("btn"))]
      node = Crystal::Call.new(nil.as(Crystal::ASTNode?), "link_to",
        [Crystal::StringLiteral.new("Edit")] of Crystal::ASTNode, named_args: named)
      dumped = Railcar::AstDump.dump(node)
      dumped.should contain "named_args:"
      dumped.should contain "(NamedArg class"
    end

    it "dumps Assign" do
      node = Crystal::Assign.new(Crystal::Var.new("x"),
        Crystal::NumberLiteral.new("1", :i32))
      dumped = Railcar::AstDump.dump(node)
      dumped.should contain "(Assign"
      dumped.should contain "target:"
      dumped.should contain "value:"
    end

    it "dumps OpAssign with the operator" do
      node = Crystal::OpAssign.new(Crystal::Var.new("_buf"), "+",
        Crystal::StringLiteral.new("x"))
      dumped = Railcar::AstDump.dump(node)
      dumped.should contain "(OpAssign op=+"
      dumped.should contain "(Var _buf)"
    end

    it "dumps an If with then and else branches" do
      cond = Crystal::Call.new(Crystal::Var.new("x"), "nil?")
      node = Crystal::If.new(cond,
        Crystal::NumberLiteral.new("1", :i32),
        Crystal::NumberLiteral.new("2", :i32))
      dumped = Railcar::AstDump.dump(node)
      dumped.should contain "(If"
      dumped.should contain "cond:"
      dumped.should contain "then:"
      dumped.should contain "else:"
    end

    it "dumps a Def with args, return type, and body" do
      arg = Crystal::Arg.new("article", nil, Crystal::Path.new("Article"))
      body = Crystal::Call.new(Crystal::Var.new("article"), "title")
      node = Crystal::Def.new("show", [arg], body, return_type: Crystal::Path.new("String"))
      dumped = Railcar::AstDump.dump(node)
      dumped.should contain "(Def show"
      dumped.should contain "args:"
      dumped.should contain "(Arg article"
      dumped.should contain "restriction:"
      dumped.should contain "return_type:"
      dumped.should contain "body:"
    end

    it "dumps a Block with args and body" do
      block = Crystal::Block.new([Crystal::Var.new("c")] of Crystal::Var,
        Crystal::Call.new(Crystal::Var.new("c"), "body"))
      dumped = Railcar::AstDump.dump(block)
      dumped.should contain "(Block"
      dumped.should contain "args: [c]"
    end
  end

  describe "round-trip from Prism translator" do
    it "dumps a simple Ruby expression through PrismTranslator" do
      ast = Railcar::PrismTranslator.translate(%q(x = 1 + 2))
      dumped = Railcar::AstDump.dump(ast)
      dumped.should contain "Assign"
      dumped.should contain "NumberLiteral 1"
      dumped.should contain "NumberLiteral 2"
    end

    it "dumps the _buf-based view pattern" do
      # Approximates what ErbCompiler produces for a view template.
      src = "_buf = \"\"\n_buf += str(comment.commenter)\n_buf"
      ast = Crystal::Parser.parse(src)
      dumped = Railcar::AstDump.dump(ast)
      dumped.should contain "(Expressions"
      dumped.should contain "(Assign"
      dumped.should contain "(OpAssign"
      dumped.should contain "(Call \"str\""
      dumped.should contain "(Call \"commenter\""
    end
  end

  describe "options" do
    it "appends type annotation when with_types and node has .type?" do
      # Build a typed node via program.semantic
      compiler = Crystal::Compiler.new
      compiler.no_codegen = true
      result = compiler.compile(
        Crystal::Compiler::Source.new("t.cr", "x = \"hello\""),
        "out")
      typed = result.node
      typed.should_not be_nil
      dumped = Railcar::AstDump.dump(typed, with_types: true)
      # Types can render as String (single) or String | Nil on some nodes
      dumped.should contain "::"
    end

    it "appends location when with_locations" do
      ast = Crystal::Parser.parse("x")
      dumped = Railcar::AstDump.dump(ast, with_locations: true)
      # Crystal parses a bare identifier as a Call (no-arg method lookup).
      # Verify we got a location annotation on the top-level node.
      dumped.should match /@\d+:\d+/
    end
  end

  describe "unknown node fallback" do
    it "emits class name + abbreviated to_s for unrecognized nodes" do
      # A Crystal::Annotation or similar we don't handle explicitly would
      # hit the fallback. Here we use one we know isn't in the explicit
      # list (e.g., Crystal::Global works since it's in the list; pick
      # something more obscure by constructing directly).
      # LibDef is an example of a rarely-used node.
      node = Crystal::LibDef.new(Crystal::Path.new("Foo"), Crystal::Nop.new)
      dumped = Railcar::AstDump.dump(node)
      dumped.should contain "LibDef"
      dumped.should contain "«"
    end
  end
end
