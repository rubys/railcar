require "./spec_helper"

# These tests mirror demo/blog/test/models/article_test.rb and comment_test.rb

describe Ruby2CR::Article do
  before_each do
    db = setup_database
    seed_fixtures(db)
    Ruby2CR::Article.db = db
    Ruby2CR::Comment.db = db
  end

  it "finds an article with valid attributes" do
    article = Ruby2CR::Article.find(1_i64)
    article.id.should eq 1_i64
    article.title.should eq "Getting Started with Rails"
  end

  it "validates title presence" do
    article = Ruby2CR::Article.new({"title" => "".as(DB::Any), "body" => "Valid body content here.".as(DB::Any)})
    article.valid?.should be_false
    article.errors.has_key?("title").should be_true
  end

  it "validates body minimum length" do
    article = Ruby2CR::Article.new({"title" => "Valid Title".as(DB::Any), "body" => "Short".as(DB::Any)})
    article.valid?.should be_false
    article.errors.has_key?("body").should be_true
  end

  it "destroys comments when article is destroyed" do
    article = Ruby2CR::Article.find(1_i64)
    initial_count = Ruby2CR::Comment.count
    article.destroy
    Ruby2CR::Comment.count.should eq(initial_count - 1)
  end

  it "creates an article with valid attributes" do
    article = Ruby2CR::Article.create!(
      title: "New Article",
      body: "This is a new article with enough body text."
    )
    article.persisted?.should be_true
    article.id.should_not be_nil
  end

  it "rejects creation with invalid attributes" do
    article = Ruby2CR::Article.new({"title" => "".as(DB::Any), "body" => "".as(DB::Any)})
    article.save.should be_false
    article.persisted?.should be_false
  end

  it "updates an article" do
    article = Ruby2CR::Article.find(1_i64)
    article.update(title: "Updated Title")
    article.title.should eq "Updated Title"

    reloaded = Ruby2CR::Article.find(1_i64)
    reloaded.title.should eq "Updated Title"
  end

  it "lists all articles" do
    articles = Ruby2CR::Article.all.to_a
    articles.size.should eq 2
  end

  it "orders articles" do
    articles = Ruby2CR::Article.order(created_at: :desc).to_a
    articles.size.should eq 2
  end

  it "counts articles" do
    Ruby2CR::Article.count.should eq 2_i64
  end

  it "finds first and last" do
    first = Ruby2CR::Article.first
    first.should_not be_nil
    first.not_nil!.id.should eq 1_i64

    last = Ruby2CR::Article.last
    last.should_not be_nil
    last.not_nil!.id.should eq 2_i64
  end
end

describe Ruby2CR::Comment do
  before_each do
    db = setup_database
    seed_fixtures(db)
    Ruby2CR::Article.db = db
    Ruby2CR::Comment.db = db
  end

  it "finds a comment on an article" do
    comment = Ruby2CR::Comment.find(1_i64)
    comment.id.should eq 1_i64
    comment.article_id.should eq 1_i64
  end

  it "accesses belongs_to association" do
    comment = Ruby2CR::Comment.find(1_i64)
    article = comment.article
    article.id.should eq 1_i64
    article.title.should eq "Getting Started with Rails"
  end

  it "accesses has_many association" do
    article = Ruby2CR::Article.find(1_i64)
    comments = article.comments.to_a
    comments.size.should eq 1
    comments.first.commenter.should eq "Alice"
  end

  it "creates a comment via association" do
    article = Ruby2CR::Article.find(1_i64)
    comment = article.comments.create!(
      commenter: "Carol",
      body: "A new comment on this article."
    )
    comment.persisted?.should be_true
    comment.article_id.should eq 1_i64

    article.comments.reload
    article.comments.size.should eq 2
  end

  it "builds a comment via association" do
    article = Ruby2CR::Article.find(1_i64)
    comment = article.comments.build(commenter: "Dave", body: "Built not saved")
    comment.article_id.should eq 1_i64
    comment.persisted?.should be_false
  end

  it "requires commenter" do
    comment = Ruby2CR::Comment.new({
      "article_id" => 1_i64.as(DB::Any),
      "body"       => "Comment without commenter".as(DB::Any),
    })
    comment.valid?.should be_false
    comment.errors.has_key?("commenter").should be_true
  end

  it "requires body" do
    comment = Ruby2CR::Comment.new({
      "article_id" => 1_i64.as(DB::Any),
      "commenter"  => "Someone".as(DB::Any),
    })
    comment.valid?.should be_false
    comment.errors.has_key?("body").should be_true
  end
end
