# Generated route helpers — mirrors Rails URL helpers.
# For the blog demo these are hand-written; the generator
# would produce these from config/routes.rb.

module Railcar::RouteHelpers
  def articles_path : String
    "/articles"
  end

  def article_path(article) : String
    "/articles/#{article.id}"
  end

  def new_article_path : String
    "/articles/new"
  end

  def edit_article_path(article) : String
    "/articles/#{article.id}/edit"
  end

  def article_comments_path(article) : String
    "/articles/#{article.id}/comments"
  end

  def article_comment_path(article, comment) : String
    "/articles/#{article.id}/comments/#{comment.id}"
  end
end
