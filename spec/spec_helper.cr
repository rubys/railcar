require "spec"
require "../src/models/article"
require "../src/models/comment"

# Set up an in-memory SQLite database with the blog schema
def setup_database : DB::Database
  db = DB.open("sqlite3::memory:")

  db.exec <<-SQL
    CREATE TABLE articles (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      title TEXT NOT NULL,
      body TEXT NOT NULL,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
  SQL

  db.exec <<-SQL
    CREATE TABLE comments (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      article_id INTEGER NOT NULL REFERENCES articles(id),
      commenter TEXT NOT NULL,
      body TEXT NOT NULL,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
  SQL

  db
end

def seed_fixtures(db : DB::Database)
  # Mirrors test/fixtures/articles.yml and test/fixtures/comments.yml
  db.exec(
    "INSERT INTO articles (id, title, body, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
    1_i64,
    "Getting Started with Rails",
    "Rails is a web application framework running on the Ruby programming language.",
    "2026-01-01 00:00:00",
    "2026-01-01 00:00:00"
  )

  db.exec(
    "INSERT INTO articles (id, title, body, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
    2_i64,
    "Understanding MVC Architecture",
    "MVC stands for Model-View-Controller. Models handle data and business logic.",
    "2026-01-01 00:00:00",
    "2026-01-01 00:00:00"
  )

  db.exec(
    "INSERT INTO comments (id, article_id, commenter, body, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)",
    1_i64, 1_i64,
    "Alice",
    "Great introduction! Rails really does make development faster.",
    "2026-01-01 00:00:00",
    "2026-01-01 00:00:00"
  )

  db.exec(
    "INSERT INTO comments (id, article_id, commenter, body, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)",
    2_i64, 2_i64,
    "Bob",
    "This pattern really helps keep code organized!",
    "2026-01-01 00:00:00",
    "2026-01-01 00:00:00"
  )
end
