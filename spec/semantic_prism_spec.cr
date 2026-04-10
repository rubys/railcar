require "./spec_helper"
require "../src/semantic"
require "../src/generator/prism_translator"

describe "Crystal semantic analysis - type inference" do
  it "infers return types from string source via Compiler" do
    compiler = Crystal::Compiler.new
    compiler.no_codegen = true
    source = Crystal::Compiler::Source.new("test.cr", <<-CRYSTAL)
      class Article
        property title : String = ""
        def self.find(id : Int32) : Article
          Article.new
        end
      end

      class ArticlesController
        def get_article
          Article.find(1)
        end

        def get_title
          Article.find(1).title
        end
      end

      x = ArticlesController.new.get_article
      y = ArticlesController.new.get_title
    CRYSTAL

    result = compiler.compile(source, "test_out")

    # Check types on the top-level assignments
    node = result.node
    if node.is_a?(Crystal::Expressions)
      types = {} of String => String
      node.expressions.each do |expr|
        if expr.is_a?(Crystal::Assign)
          if type = expr.value.type?
            types[expr.target.to_s] = type.to_s
          end
        end
      end

      types["x"].should eq "Article"
      types["y"].should eq "String"
    end
  end

  it "infers return types from Prism-translated AST" do
    ruby_controller = <<-RUBY
      class ArticlesController
        def get_article
          Article.find(1)
        end

        def get_title
          Article.find(1).title
        end
      end
    RUBY

    stub_source = <<-CRYSTAL
      class Article
        property title : String = ""
        def self.find(id : Int32) : Article
          Article.new
        end
      end
    CRYSTAL

    translated_ast = Railcar::PrismTranslator.translate(ruby_controller)
    stub_ast = Crystal::Parser.parse(stub_source)

    program = Crystal::Program.new

    # Top-level assignments to capture inferred types
    assign_x = Crystal::Assign.new(
      Crystal::Var.new("x"),
      Crystal::Call.new(
        Crystal::Call.new(Crystal::Path.new("ArticlesController"), "new"),
        "get_article"
      )
    )
    assign_y = Crystal::Assign.new(
      Crystal::Var.new("y"),
      Crystal::Call.new(
        Crystal::Call.new(Crystal::Path.new("ArticlesController"), "new"),
        "get_title"
      )
    )

    full_ast = Crystal::Expressions.new([
      Crystal::Require.new("prelude"),
      stub_ast,
      translated_ast,
      assign_x,
      assign_y,
    ] of Crystal::ASTNode)

    normalized = program.normalize(full_ast)
    typed = program.semantic(normalized)

    # Check the top-level assignments
    if typed.is_a?(Crystal::Expressions)
      types = {} of String => String
      typed.expressions.each do |expr|
        if expr.is_a?(Crystal::Assign)
          if type = expr.value.type?
            types[expr.target.to_s] = type.to_s
          end
        end
      end

      types["x"]?.should eq "Article"
      types["y"]?.should eq "String"
    end
  end
end
