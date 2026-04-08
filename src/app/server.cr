# Blog demo — hand-written Crystal web app using stdlib HTTP::Server.
# This represents what the generator would produce from the Rails
# controllers, routes, and views.

require "http/server"
require "ecr"
require "db"
require "sqlite3"
require "../runtime/application_record"
require "../runtime/relation"
require "../runtime/collection_proxy"
require "../models/article"
require "../models/comment"
require "../runtime/helpers/route_helpers"
require "../runtime/helpers/view_helpers"
require "../runtime/helpers/params_helpers"

include Ruby2CR::RouteHelpers
include Ruby2CR::ViewHelpers
include Ruby2CR::ParamsHelpers

# ----- Render helpers (partials) -----

def render_article_partial(article : Ruby2CR::Article) : String
  String.build do |__str__|
    ECR.embed("src/app/views/articles/_article.ecr", __str__)
  end
end

def render_comment_partial(article : Ruby2CR::Article, comment : Ruby2CR::Comment) : String
  String.build do |__str__|
    ECR.embed("src/app/views/comments/_comment.ecr", __str__)
  end
end

def render_form_partial(article : Ruby2CR::Article) : String
  String.build do |__str__|
    ECR.embed("src/app/views/articles/_form.ecr", __str__)
  end
end

def layout(title : String, &block) : String
  content = yield
  String.build do |__str__|
    ECR.embed("src/app/views/layouts/application.ecr", __str__)
  end
end

# ----- Flash messages -----

FLASH_STORE = {} of String => {notice: String?, alert: String?}

def set_flash(notice : String? = nil, alert : String? = nil)
  FLASH_STORE["default"] = {notice: notice, alert: alert}
end

def consume_flash : {notice: String?, alert: String?}
  flash = FLASH_STORE.delete("default") || {notice: nil, alert: nil}
  flash
end

# ----- Request routing -----

class BlogApp
  include Ruby2CR::RouteHelpers
  include Ruby2CR::ViewHelpers
  include Ruby2CR::ParamsHelpers

  def call(context : HTTP::Server::Context)
    request = context.request
    response = context.response
    path = request.path
    method = request.method

    # Parse form body for POST
    params = {} of String => String
    if method == "POST" && request.body
      body = request.body.not_nil!.gets_to_end
      HTTP::Params.parse(body) { |key, value| params[key] = value }

      # Method override
      if override = params["_method"]?
        method = override.upcase
      end
    end

    # Route matching
    case {method, path}
    when {"GET", "/"}
      response.status_code = 302
      response.headers["Location"] = "/articles"

    when {"GET", "/articles"}
      articles_index(response)

    when {"GET", "/articles/new"}
      articles_new(response)

    when {"POST", "/articles"}
      articles_create(response, params)

    else
      # Pattern matching for parameterized routes
      if match = path.match(%r{^/articles/(\d+)/comments/(\d+)$})
        article_id = match[1].to_i64
        comment_id = match[2].to_i64
        case method
        when "DELETE"
          comments_destroy(response, article_id, comment_id)
        else
          not_found(response)
        end
      elsif match = path.match(%r{^/articles/(\d+)/comments$})
        article_id = match[1].to_i64
        case method
        when "POST"
          comments_create(response, article_id, params)
        else
          not_found(response)
        end
      elsif match = path.match(%r{^/articles/(\d+)/edit$})
        id = match[1].to_i64
        case method
        when "GET"
          articles_edit(response, id)
        else
          not_found(response)
        end
      elsif match = path.match(%r{^/articles/(\d+)$})
        id = match[1].to_i64
        case method
        when "GET"
          articles_show(response, id)
        when "PATCH"
          articles_update(response, id, params)
        when "DELETE"
          articles_destroy(response, id)
        else
          not_found(response)
        end
      else
        not_found(response)
      end
    end

    response.headers["Content-Type"] ||= "text/html"
  end

  # ----- Articles controller -----

  def articles_index(response)
    articles = Ruby2CR::Article.includes(:comments).order(created_at: :desc).to_a
    flash = consume_flash
    notice = flash[:notice]
    response.print layout("Articles") {
      String.build do |__str__|
        ECR.embed("src/app/views/articles/index.ecr", __str__)
      end
    }
  end

  def articles_show(response, id : Int64)
    article = Ruby2CR::Article.find(id)
    flash = consume_flash
    notice = flash[:notice]
    response.print layout(article.title) {
      String.build do |__str__|
        ECR.embed("src/app/views/articles/show.ecr", __str__)
      end
    }
  end

  def articles_new(response)
    article = Ruby2CR::Article.new
    response.print layout("New Article") {
      String.build do |__str__|
        ECR.embed("src/app/views/articles/new.ecr", __str__)
      end
    }
  end

  def articles_edit(response, id : Int64)
    article = Ruby2CR::Article.find(id)
    response.print layout("Edit Article") {
      String.build do |__str__|
        ECR.embed("src/app/views/articles/edit.ecr", __str__)
      end
    }
  end

  def articles_create(response, params : Hash(String, String))
    hash = {} of String => DB::Any
    params.each do |k, v|
      if k.starts_with?("article[") && k.ends_with?("]")
        field = k[8..-2]
        hash[field] = v.as(DB::Any)
      end
    end

    article = Ruby2CR::Article.new(hash)
    if article.save
      set_flash(notice: "Article was successfully created.")
      response.status_code = 302
      response.headers["Location"] = article_path(article)
    else
      response.status_code = 422
      response.print layout("New Article") {
        String.build do |__str__|
          ECR.embed("src/app/views/articles/new.ecr", __str__)
        end
      }
    end
  end

  def articles_update(response, id : Int64, params : Hash(String, String))
    article = Ruby2CR::Article.find(id)
    hash = {} of String => DB::Any
    params.each do |k, v|
      next if k == "_method"
      if k.starts_with?("article[") && k.ends_with?("]")
        field = k[8..-2]
        hash[field] = v.as(DB::Any)
      end
    end

    if article.update(hash)
      set_flash(notice: "Article was successfully updated.")
      response.status_code = 302
      response.headers["Location"] = article_path(article)
    else
      response.status_code = 422
      response.print layout("Edit Article") {
        String.build do |__str__|
          ECR.embed("src/app/views/articles/edit.ecr", __str__)
        end
      }
    end
  end

  def articles_destroy(response, id : Int64)
    article = Ruby2CR::Article.find(id)
    article.destroy
    set_flash(notice: "Article was successfully destroyed.")
    response.status_code = 302
    response.headers["Location"] = articles_path
  end

  # ----- Comments controller -----

  def comments_create(response, article_id : Int64, params : Hash(String, String))
    article = Ruby2CR::Article.find(article_id)
    commenter = ""
    body = ""
    params.each do |k, v|
      if k == "comment[commenter]"
        commenter = v
      elsif k == "comment[body]"
        body = v
      end
    end

    comment = article.comments.build(commenter: commenter, body: body)
    if comment.save
      set_flash(notice: "Comment was successfully created.")
    else
      set_flash(alert: "Could not create comment.")
    end
    response.status_code = 302
    response.headers["Location"] = article_path(article)
  end

  def comments_destroy(response, article_id : Int64, comment_id : Int64)
    article = Ruby2CR::Article.find(article_id)
    comment = article.comments.find(comment_id)
    comment.destroy
    set_flash(notice: "Comment was successfully deleted.")
    response.status_code = 302
    response.headers["Location"] = article_path(article)
  end

  private def not_found(response)
    response.status_code = 404
    response.print "Not found"
  end
end

# ----- Database setup -----

def setup_blog_db
  db = DB.open("sqlite3:./blog.db")
  Ruby2CR::Article.db = db
  Ruby2CR::Comment.db = db

  db.exec <<-SQL
    CREATE TABLE IF NOT EXISTS articles (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      title TEXT NOT NULL,
      body TEXT NOT NULL,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
  SQL

  db.exec <<-SQL
    CREATE TABLE IF NOT EXISTS comments (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      article_id INTEGER NOT NULL REFERENCES articles(id),
      commenter TEXT NOT NULL,
      body TEXT NOT NULL,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
  SQL

  if Ruby2CR::Article.count == 0
    a1 = Ruby2CR::Article.create!(
      title: "Getting Started with Rails",
      body: "Rails is a web application framework running on the Ruby programming language. It makes building web apps faster and easier with conventions over configuration."
    )
    a1.comments.create!(commenter: "Alice", body: "Great introduction! Rails really does make development faster.")
    a1.comments.create!(commenter: "Bob", body: "I love how Rails handles database migrations automatically.")

    a2 = Ruby2CR::Article.create!(
      title: "Understanding MVC Architecture",
      body: "MVC stands for Model-View-Controller. Models handle data and business logic, Views display information to users, and Controllers coordinate between them."
    )
    a2.comments.create!(commenter: "Carol", body: "This pattern really helps keep code organized!")

    Ruby2CR::Article.create!(
      title: "Ruby2JS: Rails Everywhere",
      body: "Ruby2JS transpiles Ruby to JavaScript, enabling Rails applications to run in browsers, on Node.js, and at the edge. Same code, different runtimes."
    )
  end

  db
end

setup_blog_db

app = BlogApp.new
server = HTTP::Server.new do |context|
  app.call(context)
end

address = server.bind_tcp("0.0.0.0", 3000)
puts "Blog running at http://#{address}"
server.listen
