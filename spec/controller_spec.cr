require "spec"
require "./test_paths"
require "../src/generator/controller_extractor"
require "../src/generator/controller_generator"

describe Ruby2CR::ControllerExtractor do
  it "extracts CommentsController structure" do
    info = Ruby2CR::ControllerExtractor.extract_file(
      File.join(BLOG_DIR, "app/controllers/comments_controller.rb")
    )
    info.should_not be_nil
    info = info.not_nil!

    info.name.should eq "CommentsController"
    info.superclass.should eq "ApplicationController"

    # before_action
    info.before_actions.size.should eq 1
    info.before_actions[0].method_name.should eq "set_article"
    info.before_actions[0].only.should be_nil # applies to all actions

    # Actions
    action_names = info.actions.map(&.name)
    action_names.should contain "create"
    action_names.should contain "destroy"
    action_names.should contain "set_article"
    action_names.should contain "comment_params"

    # Private detection
    create = info.actions.find { |a| a.name == "create" }.not_nil!
    create.is_private.should be_false

    set_article = info.actions.find { |a| a.name == "set_article" }.not_nil!
    set_article.is_private.should be_true
  end

  it "extracts ArticlesController structure" do
    info = Ruby2CR::ControllerExtractor.extract_file(
      File.join(BLOG_DIR, "app/controllers/articles_controller.rb")
    )
    info.should_not be_nil
    info = info.not_nil!

    info.name.should eq "ArticlesController"

    # before_action with :only
    info.before_actions.size.should eq 1
    info.before_actions[0].method_name.should eq "set_article"
    info.before_actions[0].only.should eq ["show", "edit", "update", "destroy"]

    # All 7 CRUD actions + 2 private
    action_names = info.actions.map(&.name)
    action_names.should contain "index"
    action_names.should contain "show"
    action_names.should contain "new"
    action_names.should contain "edit"
    action_names.should contain "create"
    action_names.should contain "update"
    action_names.should contain "destroy"
    action_names.should contain "set_article"
    action_names.should contain "article_params"
  end
end

describe Ruby2CR::ControllerGenerator do
  it "generates comments#create action" do
    info = Ruby2CR::ControllerExtractor.extract_file(
      File.join(BLOG_DIR, "app/controllers/comments_controller.rb")
    ).not_nil!

    create = info.actions.find { |a| a.name == "create" }.not_nil!
    source = Ruby2CR::ControllerGenerator.generate_action(create, "comments")

    source.should contain "def create(response, params"
    source.should contain "article.comments.build"
    source.should contain "save"
    source.should contain "set_flash"
    source.should contain "302"
  end

  it "generates comments#destroy action" do
    info = Ruby2CR::ControllerExtractor.extract_file(
      File.join(BLOG_DIR, "app/controllers/comments_controller.rb")
    ).not_nil!

    destroy = info.actions.find { |a| a.name == "destroy" }.not_nil!
    source = Ruby2CR::ControllerGenerator.generate_action(destroy, "comments")

    source.should contain "def destroy(response, id"
    source.should contain "destroy"
    source.should contain "set_flash"
    source.should contain "302"
  end

  it "generates articles#index action" do
    info = Ruby2CR::ControllerExtractor.extract_file(
      File.join(BLOG_DIR, "app/controllers/articles_controller.rb")
    ).not_nil!

    index = info.actions.find { |a| a.name == "index" }.not_nil!
    source = Ruby2CR::ControllerGenerator.generate_action(index, "articles")

    source.should contain "def index(response)"
    source.should contain "includes"
    source.should contain "order"
  end

  it "generates articles#create with respond_to" do
    info = Ruby2CR::ControllerExtractor.extract_file(
      File.join(BLOG_DIR, "app/controllers/articles_controller.rb")
    ).not_nil!

    create = info.actions.find { |a| a.name == "create" }.not_nil!
    source = Ruby2CR::ControllerGenerator.generate_action(create, "articles")

    source.should contain "def create(response, params"
    source.should contain "Article.new"
    source.should contain "save"
    source.should contain "set_flash"
  end

  it "generates articles#destroy with respond_to" do
    info = Ruby2CR::ControllerExtractor.extract_file(
      File.join(BLOG_DIR, "app/controllers/articles_controller.rb")
    ).not_nil!

    destroy = info.actions.find { |a| a.name == "destroy" }.not_nil!
    source = Ruby2CR::ControllerGenerator.generate_action(destroy, "articles")

    source.should contain "def destroy(response, id"
    source.should contain "destroy"
    source.should contain "articles_path"
  end
end
