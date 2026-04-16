require "spec"
require "compiler/crystal/syntax"
require "../src/generator/app_model"
require "../src/generator/type_resolver"
require "../src/generator/eex_converter"
require "../src/filters/instance_var_to_local"

module Railcar
  private def self.blog_app_for_eex_spec : AppModel
    schema = TableSchema.new("articles", [
      Column.new("id", "integer"),
      Column.new("title", "string"),
    ])
    model = ModelInfo.new(
      name: "Article",
      superclass: "ApplicationRecord",
      associations: [] of Association,
      validations: [] of Validation,
    )
    AppModel.new("blog", [schema], {"Article" => model})
  end

  def self.run_eex(erb_source : String, with_resolver : Bool = true) : String
    app = blog_app_for_eex_spec
    resolver = with_resolver ? TypeResolver.new(app) : nil
    EexConverter.new("show", "articles", "Blog", Set(String).new, resolver)
      .convert(erb_source, "test.erb",
        view_filters: [InstanceVarToLocal.new] of Crystal::Transformer)
  end
end

describe Railcar::EexConverter do
  describe "MethodMap fallback for string methods" do
    it "translates title.downcase to String.downcase(title) via MethodMap" do
      result = Railcar.run_eex("<%= @article.title.downcase %>")
      result.should contain "String.downcase("
    end

    it "translates title.upcase to String.upcase" do
      result = Railcar.run_eex("<%= @article.title.upcase %>")
      result.should contain "String.upcase("
    end

    it "translates title.start_with?(s) to String.starts_with?" do
      result = Railcar.run_eex(%q(<%= @article.title.start_with?("foo") %>))
      result.should contain "String.starts_with?("
    end
  end

  describe "fallback behavior without a resolver" do
    it "falls back to Module.function pattern when no resolver" do
      # Without resolver, the generic Elixir pattern emits Blog.Title.downcase(title)
      # — not what we want, but this test documents the pre-existing fallback
      # so a future change to that fallback path is visible.
      result = Railcar.run_eex("<%= @article.title.downcase %>", with_resolver: false)
      result.should contain "downcase"
      result.should_not contain "String.downcase("
    end
  end
end
