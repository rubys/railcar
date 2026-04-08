require "spec"
require "./test_paths"
require "../src/generator/schema_extractor"
require "../src/generator/model_extractor"
require "../src/generator/crystal_emitter"

describe Ruby2CR::SchemaExtractor do
  it "extracts articles table from migration" do
    source = File.read(Dir.glob(File.join(BLOG_DIR, "db/migrate/*_create_articles.rb")).first)
    schema = Ruby2CR::SchemaExtractor.extract(source)
    schema.should_not be_nil
    schema = schema.not_nil!

    schema.name.should eq "articles"
    col_names = schema.columns.map(&.name)
    col_names.should contain "title"
    col_names.should contain "body"
    col_names.should contain "created_at"
    col_names.should contain "updated_at"

    title_col = schema.columns.find { |c| c.name == "title" }.not_nil!
    title_col.type.should eq "string"
  end

  it "extracts comments table with references" do
    source = File.read(Dir.glob(File.join(BLOG_DIR, "db/migrate/*_create_comments.rb")).first)
    schema = Ruby2CR::SchemaExtractor.extract(source)
    schema.should_not be_nil
    schema = schema.not_nil!

    schema.name.should eq "comments"
    col_names = schema.columns.map(&.name)
    col_names.should contain "article_id"
    col_names.should contain "commenter"
    col_names.should contain "body"

    article_col = schema.columns.find { |c| c.name == "article_id" }.not_nil!
    article_col.type.should eq "integer"
  end

  it "extracts all migrations from directory" do
    schemas = Ruby2CR::SchemaExtractor.extract_all(File.join(BLOG_DIR, "db/migrate"))
    schemas.size.should eq 2
    schemas.map(&.name).should contain "articles"
    schemas.map(&.name).should contain "comments"
  end

  it "maps Rails types to Crystal types" do
    Ruby2CR::SchemaExtractor.crystal_type("string").should eq "String"
    Ruby2CR::SchemaExtractor.crystal_type("text").should eq "String"
    Ruby2CR::SchemaExtractor.crystal_type("integer").should eq "Int64"
    Ruby2CR::SchemaExtractor.crystal_type("boolean").should eq "Bool"
    Ruby2CR::SchemaExtractor.crystal_type("datetime").should eq "Time"
    Ruby2CR::SchemaExtractor.crystal_type("float").should eq "Float64"
  end
end

describe Ruby2CR::ModelExtractor do
  it "extracts Article model info" do
    source = File.read(File.join(BLOG_DIR, "app/models/article.rb"))
    model = Ruby2CR::ModelExtractor.extract(source)
    model.should_not be_nil
    model = model.not_nil!

    model.name.should eq "Article"
    model.superclass.should eq "ApplicationRecord"

    # Associations
    model.associations.size.should eq 1
    has_many = model.associations[0]
    has_many.kind.should eq :has_many
    has_many.name.should eq "comments"
    has_many.options["dependent"]?.should eq "destroy"

    # Validations
    model.validations.size.should eq 3
    presence_fields = model.validations.select { |v| v.kind == "presence" }.map(&.field)
    presence_fields.should contain "title"
    presence_fields.should contain "body"

    length_val = model.validations.find { |v| v.kind == "length" }
    length_val.should_not be_nil
    length_val.not_nil!.field.should eq "body"
    length_val.not_nil!.options["minimum"]?.should eq "10"
  end

  it "extracts Comment model info" do
    source = File.read(File.join(BLOG_DIR, "app/models/comment.rb"))
    model = Ruby2CR::ModelExtractor.extract(source)
    model.should_not be_nil
    model = model.not_nil!

    model.name.should eq "Comment"

    # Associations
    belongs_to = model.associations.find { |a| a.kind == :belongs_to }
    belongs_to.should_not be_nil
    belongs_to.not_nil!.name.should eq "article"

    # Validations
    presence_fields = model.validations.select { |v| v.kind == "presence" }.map(&.field)
    presence_fields.should contain "commenter"
    presence_fields.should contain "body"
  end
end

describe Ruby2CR::CrystalEmitter do
  it "generates Article model source" do
    schema = Ruby2CR::SchemaExtractor.extract_file(
      Dir.glob(File.join(BLOG_DIR, "db/migrate/*_create_articles.rb")).first
    ).not_nil!
    model = Ruby2CR::ModelExtractor.extract_file(
      File.join(BLOG_DIR, "app/models/article.rb")
    ).not_nil!

    source = Ruby2CR::CrystalEmitter.generate(schema, model)

    # Should contain key elements
    source.should contain "class Article < ApplicationRecord"
    source.should contain "model \"articles\""
    source.should contain "column title, String"
    source.should contain "column body, String"
    source.should contain "column created_at, Time"
    source.should contain "has_many comments, Comment"
    source.should contain "dependent: :destroy"
    source.should contain "validates title, presence: true"
    source.should contain "validates body, presence: true"
    source.should contain "validates body, length: {minimum: 10}"
    source.should contain "validate_presence_title"
    source.should contain "validate_length_body"
    source.should contain "comments.destroy_all"
  end

  it "generates Comment model source" do
    schema = Ruby2CR::SchemaExtractor.extract_file(
      Dir.glob(File.join(BLOG_DIR, "db/migrate/*_create_comments.rb")).first
    ).not_nil!
    model = Ruby2CR::ModelExtractor.extract_file(
      File.join(BLOG_DIR, "app/models/comment.rb")
    ).not_nil!

    source = Ruby2CR::CrystalEmitter.generate(schema, model)

    source.should contain "class Comment < ApplicationRecord"
    source.should contain "model \"comments\""
    source.should contain "column article_id, Int64"
    source.should contain "column commenter, String"
    source.should contain "belongs_to article, Article"
    source.should contain "validates commenter, presence: true"
    source.should contain "validates body, presence: true"
  end

  it "generates all models from blog demo" do
    results = Ruby2CR::CrystalEmitter.generate_all(
      File.join(BLOG_DIR, "db/migrate"),
      File.join(BLOG_DIR, "app/models")
    )

    results.size.should eq 2
    results.has_key?("article.cr").should be_true
    results.has_key?("comment.cr").should be_true
  end

  it "inflects correctly" do
    Ruby2CR::CrystalEmitter.classify("articles").should eq "Article"
    Ruby2CR::CrystalEmitter.classify("comments").should eq "Comment"
    Ruby2CR::CrystalEmitter.singularize("articles").should eq "article"
    Ruby2CR::CrystalEmitter.singularize("comments").should eq "comment"
  end
end
