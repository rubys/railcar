require "spec"
require "../src/prism/bindings"
require "../src/prism/deserializer"

describe Prism do
  it "reports version" do
    Prism.version.should match(/^\d+\.\d+\.\d+$/)
  end

  it "parses a simple Ruby expression" do
    ast = Prism.parse("1 + 2")
    ast.should be_a(Prism::ProgramNode)
  end

  it "parses a class definition" do
    source = <<-RUBY
    class Article < ApplicationRecord
      has_many :comments, dependent: :destroy
      validates :title, presence: true
    end
    RUBY

    ast = Prism.parse(source)
    stmts = ast.statements.as(Prism::StatementsNode)
    stmts.body.size.should eq 1

    klass = stmts.body[0].as(Prism::ClassNode)
    klass.name.should eq "Article"

    # Superclass
    superclass = klass.superclass.as(Prism::ConstantReadNode)
    superclass.name.should eq "ApplicationRecord"

    # Body should have two call nodes (has_many, validates)
    body = klass.body.as(Prism::StatementsNode)
    body.body.size.should eq 2

    has_many = body.body[0].as(Prism::CallNode)
    has_many.name.should eq "has_many"

    validates = body.body[1].as(Prism::CallNode)
    validates.name.should eq "validates"
  end

  it "extracts symbol arguments" do
    source = "has_many :comments, dependent: :destroy"
    ast = Prism.parse(source)
    stmts = ast.statements.as(Prism::StatementsNode)
    call = stmts.body[0].as(Prism::CallNode)

    call.name.should eq "has_many"
    args = call.arg_nodes
    args.size.should eq 2 # :comments and keyword hash

    sym = args[0].as(Prism::SymbolNode)
    sym.value.should eq "comments"
  end

  it "parses a migration create_table block" do
    source = <<-RUBY
    create_table :articles do |t|
      t.string :title
      t.text :body
      t.timestamps
    end
    RUBY

    ast = Prism.parse(source)
    stmts = ast.statements.as(Prism::StatementsNode)
    call = stmts.body[0].as(Prism::CallNode)
    call.name.should eq "create_table"

    # First arg is :articles
    sym = call.arg_nodes[0].as(Prism::SymbolNode)
    sym.value.should eq "articles"

    # Block body has 3 calls
    block = call.block.as(Prism::BlockNode)
    block_body = block.body.as(Prism::StatementsNode)
    block_body.body.size.should eq 3

    col1 = block_body.body[0].as(Prism::CallNode)
    col1.name.should eq "string"
    col1_arg = col1.arg_nodes[0].as(Prism::SymbolNode)
    col1_arg.value.should eq "title"

    col2 = block_body.body[1].as(Prism::CallNode)
    col2.name.should eq "text"

    col3 = block_body.body[2].as(Prism::CallNode)
    col3.name.should eq "timestamps"
  end

  it "parses validates with options" do
    source = "validates :body, presence: true, length: { minimum: 10 }"
    ast = Prism.parse(source)
    stmts = ast.statements.as(Prism::StatementsNode)
    call = stmts.body[0].as(Prism::CallNode)

    call.name.should eq "validates"
    args = call.arg_nodes

    # First arg: :body
    args[0].as(Prism::SymbolNode).value.should eq "body"

    # Second arg: keyword hash with presence and length
    kwargs = args[1].as(Prism::KeywordHashNode)
    kwargs.elements.size.should eq 2

    # presence: true
    assoc1 = kwargs.elements[0].as(Prism::AssocNode)
    assoc1.key.as(Prism::SymbolNode).value.should eq "presence"
    assoc1.value_node.should be_a(Prism::TrueNode)

    # length: { minimum: 10 }
    assoc2 = kwargs.elements[1].as(Prism::AssocNode)
    assoc2.key.as(Prism::SymbolNode).value.should eq "length"
    hash = assoc2.value_node.as(Prism::HashNode)
    min_assoc = hash.elements[0].as(Prism::AssocNode)
    min_assoc.key.as(Prism::SymbolNode).value.should eq "minimum"
    min_assoc.value_node.as(Prism::IntegerNode).value.should eq 10
  end
end
