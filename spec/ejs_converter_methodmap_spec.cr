require "spec"
require "compiler/crystal/syntax"
require "../src/generator/app_model"
require "../src/generator/type_resolver"
require "../src/generator/ejs_converter"

module Railcar
  private def self.blog_app_for_ejs_spec : AppModel
    schema = TableSchema.new("articles", [
      Column.new("id", "integer"),
      Column.new("title", "string"),
    ])
    model = ModelInfo.new(
      name: "Article",
      superclass: "ApplicationRecord",
      associations: [Association.new(:has_many, "comments")],
      validations: [] of Validation,
    )
    AppModel.new("blog", [schema], {"Article" => model})
  end

  # Convert a small ERB snippet through EjsConverter and return the output.
  def self.run_ejs(erb_source : String, with_resolver : Bool = true) : String
    app = blog_app_for_ejs_spec
    resolver = with_resolver ? TypeResolver.new(app) : nil
    EjsConverter.new("show", "articles", Set(String).new, resolver)
      .convert(erb_source, "test.erb",
        view_filters: [InstanceVarToLocal.new] of Crystal::Transformer)
  end
end

require "../src/filters/instance_var_to_local"

describe Railcar::EjsConverter do
  describe "MethodMap fallback for string methods" do
    it "translates title.downcase to title.toLowerCase() via MethodMap" do
      # title is resolved to "String" via the model column schema, which
      # picks the String row in the TypeScript MethodMap.
      result = Railcar.run_ejs("<%= @article.title.downcase %>")
      result.should contain ".toLowerCase()"
    end

    it "translates start_with? to startsWith" do
      result = Railcar.run_ejs(%q(<%= @article.title.start_with?("foo") %>))
      result.should contain ".startsWith("
    end

    it "translates include? to includes" do
      result = Railcar.run_ejs(%q(<%= @article.title.include?("x") %>))
      result.should contain ".includes("
    end
  end

  describe "fallback behavior without a resolver" do
    it "emits the raw method name when no resolver is provided" do
      # Without a resolver, MethodMap is skipped and EJS emits the ts-cased
      # method name. downcase stays as downcase (no camelcase change since
      # there's no underscore). This documents the pre-existing behavior.
      result = Railcar.run_ejs("<%= @article.title.downcase %>", with_resolver: false)
      result.should contain ".downcase("
    end
  end
end
