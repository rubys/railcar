require "spec"
require "../src/generator/prism_translator"

def translate(ruby : String) : String
  Ruby2CR::PrismTranslator.translate(ruby).to_s
end

describe Ruby2CR::PrismTranslator do
  describe "literals" do
    it "translates strings" do
      translate(%("hello")).should eq %("hello")
    end

    it "translates symbols" do
      translate(":foo").should eq ":foo"
    end

    it "translates integers" do
      translate("42").should eq "42"
    end

    it "translates booleans" do
      translate("true").should eq "true"
      translate("false").should eq "false"
    end

    it "translates nil" do
      translate("nil").should eq "nil"
    end

    it "translates arrays" do
      translate("[1, 2, 3]").should eq "[1, 2, 3]"
    end

    it "translates hashes" do
      result = translate("{a: 1, b: 2}")
      # Ruby {a: 1} → symbol keys: {:a => 1} or {a: 1}
      (result.includes?(":a") && result.includes?(":b")).should be_true
    end
  end

  describe "variables" do
    it "translates local variables" do
      translate("x = 1").should eq "x = 1"
    end

    it "translates instance variables" do
      translate("@foo").should eq "@foo"
    end

    it "translates instance variable assignment" do
      translate("@foo = 1").should eq "@foo = 1"
    end

    it "translates operator assignment" do
      translate("x += 1").should eq "x += 1"
    end
  end

  describe "method calls" do
    it "translates simple method call" do
      translate("foo").should eq "foo"
    end

    it "translates method with arguments" do
      translate("foo(1, 2)").should eq "foo(1, 2)"
    end

    it "translates method on receiver" do
      translate("obj.method").should eq "obj.method"
    end

    it "translates chained calls" do
      translate("a.b.c").should eq "a.b.c"
    end

    it "translates keyword arguments" do
      result = translate("foo(bar: 1, baz: 2)")
      result.should contain "foo"
      result.should contain "bar:"
      result.should contain "baz:"
    end

    it "translates method with block" do
      result = translate("items.each do |item|\n  puts item\nend")
      result.should contain "items.each"
      result.should contain "item"
    end
  end

  describe "constants" do
    it "translates constant read" do
      translate("Foo").should eq "Foo"
    end

    it "translates constant path" do
      translate("Foo::Bar").should eq "Foo::Bar"
    end
  end

  describe "class definitions" do
    it "translates simple class" do
      result = translate("class Foo\nend")
      result.should contain "class Foo"
      result.should contain "end"
    end

    it "translates class with superclass" do
      result = translate("class Foo < Bar\nend")
      result.should contain "class Foo < Bar"
    end

    it "translates class with body" do
      result = translate("class Foo\n  def bar\n    1\n  end\nend")
      result.should contain "class Foo"
      result.should contain "def bar"
    end
  end

  describe "method definitions" do
    it "translates simple method" do
      result = translate("def foo\n  1\nend")
      result.should contain "def foo"
      result.should contain "1"
    end

    it "translates method with parameters" do
      result = translate("def foo(x, y)\n  x + y\nend")
      result.should contain "def foo(x, y)"
    end

    it "translates empty method" do
      result = translate("def foo\nend")
      result.should contain "def foo"
    end
  end

  describe "control flow" do
    it "translates if" do
      result = translate("if x\n  1\nend")
      result.should contain "if x"
      result.should contain "1"
      result.should contain "end"
    end

    it "translates if/else" do
      result = translate("if x\n  1\nelse\n  2\nend")
      result.should contain "if x"
      result.should contain "else"
      result.should contain "2"
    end
  end

  describe "Rails model source" do
    it "translates a model file structurally" do
      ruby = <<-RUBY
      class Article < ApplicationRecord
        has_many :comments, dependent: :destroy
        validates :title, presence: true
      end
      RUBY
      result = translate(ruby)

      # Structural elements preserved
      result.should contain "class Article < ApplicationRecord"
      result.should contain "has_many"
      result.should contain ":comments"
      result.should contain "dependent: :destroy"
      result.should contain "validates"
      result.should contain ":title"
      result.should contain "presence: true"
    end

    it "translates a controller file structurally" do
      ruby = <<-RUBY
      class CommentsController < ApplicationController
        before_action :set_article

        def create
          @comment = @article.comments.build(comment_params)
          if @comment.save
            redirect_to @article, notice: "Created."
          else
            redirect_to @article, alert: "Failed."
          end
        end

        private

        def set_article
          @article = Article.find(params.expect(:article_id))
        end
      end
      RUBY
      result = translate(ruby)

      result.should contain "class CommentsController < ApplicationController"
      result.should contain "before_action"
      result.should contain "def create"
      result.should contain "@article.comments.build"
      result.should contain "@comment.save"
      result.should contain "redirect_to"
      result.should contain "if"
      result.should contain "else"
      result.should contain "def set_article"
    end
  end
end
