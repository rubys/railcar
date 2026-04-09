require "spec"
require "../src/generator/source_parser"

describe Railcar::SourceParser do
  describe ".parse_source" do
    it "parses Ruby source via PrismTranslator" do
      ast = Railcar::SourceParser.parse_source("x = 1", "test.rb")
      ast.to_s.should contain "x = 1"
    end

    it "parses Crystal source via Crystal parser" do
      ast = Railcar::SourceParser.parse_source("x = 1", "test.cr")
      ast.to_s.should contain "x = 1"
    end

    it "routes .rb through PrismTranslator" do
      # Ruby syntax with @ivar — PrismTranslator preserves as InstanceVar
      ast = Railcar::SourceParser.parse_source("@x", "test.rb")
      ast.should be_a(Crystal::InstanceVar)
    end

    it "routes .cr through Crystal parser" do
      ast = Railcar::SourceParser.parse_source("x = 1\nx + 2", "test.cr")
      ast.should be_a(Crystal::Expressions)
    end

    it "produces equivalent output for shared syntax" do
      code = "def hello\n  puts(\"world\")\nend"
      rb_ast = Railcar::SourceParser.parse_source(code, "test.rb")
      cr_ast = Railcar::SourceParser.parse_source(code, "test.cr")

      # Both should produce a Def node with the same structure
      rb_ast.to_s.should contain "def hello"
      cr_ast.to_s.should contain "def hello"
      rb_ast.to_s.should contain "puts"
      cr_ast.to_s.should contain "puts"
    end

    it "defaults to Ruby parsing for unknown extensions" do
      ast = Railcar::SourceParser.parse_source("x = 1", "test.txt")
      ast.to_s.should contain "x = 1"
    end
  end
end
