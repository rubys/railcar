require "spec"
require "./test_paths"
require "../src/generator/route_extractor"

describe Railcar::RouteExtractor do
  it "extracts root route" do
    route_set = Railcar::RouteExtractor.extract_file(
      File.join(BLOG_DIR, "config/routes.rb")
    )
    route_set.root_controller.should eq "articles"
    route_set.root_action.should eq "index"
  end

  it "extracts article resource routes" do
    route_set = Railcar::RouteExtractor.extract_file(
      File.join(BLOG_DIR, "config/routes.rb")
    )

    # Articles should have all 7 RESTful routes
    article_routes = route_set.routes.select { |r| r.controller == "articles" }
    article_routes.size.should eq 7

    methods = article_routes.map { |r| {r.method, r.action} }
    methods.should contain({"GET", "index"})
    methods.should contain({"GET", "show"})
    methods.should contain({"GET", "new"})
    methods.should contain({"GET", "edit"})
    methods.should contain({"POST", "create"})
    methods.should contain({"PATCH", "update"})
    methods.should contain({"DELETE", "destroy"})
  end

  it "extracts nested comment routes with only constraint" do
    route_set = Railcar::RouteExtractor.extract_file(
      File.join(BLOG_DIR, "config/routes.rb")
    )

    comment_routes = route_set.routes.select { |r| r.controller == "comments" }
    comment_routes.size.should eq 2

    methods = comment_routes.map { |r| {r.method, r.action} }
    methods.should contain({"POST", "create"})
    methods.should contain({"DELETE", "destroy"})
  end

  it "generates correct paths for articles" do
    route_set = Railcar::RouteExtractor.extract_file(
      File.join(BLOG_DIR, "config/routes.rb")
    )

    index = route_set.routes.find { |r| r.controller == "articles" && r.action == "index" }
    index.not_nil!.path.should eq "/articles"

    show = route_set.routes.find { |r| r.controller == "articles" && r.action == "show" }
    show.not_nil!.path.should eq "/articles/:id"

    new_route = route_set.routes.find { |r| r.controller == "articles" && r.action == "new" }
    new_route.not_nil!.path.should eq "/articles/new"

    edit = route_set.routes.find { |r| r.controller == "articles" && r.action == "edit" }
    edit.not_nil!.path.should eq "/articles/:id/edit"
  end

  it "generates correct paths for nested comments" do
    route_set = Railcar::RouteExtractor.extract_file(
      File.join(BLOG_DIR, "config/routes.rb")
    )

    create = route_set.routes.find { |r| r.controller == "comments" && r.action == "create" }
    create.not_nil!.path.should eq "/articles/:article_id/comments"

    destroy = route_set.routes.find { |r| r.controller == "comments" && r.action == "destroy" }
    destroy.not_nil!.path.should eq "/articles/:article_id/comments/:id"
  end

  it "generates correct helper names" do
    route_set = Railcar::RouteExtractor.extract_file(
      File.join(BLOG_DIR, "config/routes.rb")
    )

    # Article helpers
    index = route_set.routes.find { |r| r.controller == "articles" && r.action == "index" }
    index.not_nil!.name.should eq "articles"

    show = route_set.routes.find { |r| r.controller == "articles" && r.action == "show" }
    show.not_nil!.name.should eq "article"

    new_route = route_set.routes.find { |r| r.controller == "articles" && r.action == "new" }
    new_route.not_nil!.name.should eq "new_article"

    edit = route_set.routes.find { |r| r.controller == "articles" && r.action == "edit" }
    edit.not_nil!.name.should eq "edit_article"

    # Comment helpers (nested)
    create = route_set.routes.find { |r| r.controller == "comments" && r.action == "create" }
    create.not_nil!.name.should eq "article_comments"

    destroy = route_set.routes.find { |r| r.controller == "comments" && r.action == "destroy" }
    destroy.not_nil!.name.should eq "article_comment"
  end
end

describe Railcar::RouteGenerator do
  it "generates route helpers matching hand-written ones" do
    route_set = Railcar::RouteExtractor.extract_file(
      File.join(BLOG_DIR, "config/routes.rb")
    )
    source = Railcar::RouteGenerator.generate_helpers(route_set)

    # Should contain all the helper methods from our hand-written version
    source.should contain "def articles_path"
    source.should contain "def article_path("
    source.should contain "def new_article_path"
    source.should contain "def edit_article_path("
    source.should contain "def article_comments_path("
    source.should contain "def article_comment_path("

    # Should have correct return paths
    source.should contain "\"/articles\""
    source.should contain "\"/articles/new\""
  end
end
