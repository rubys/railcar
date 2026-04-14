// Smoke tests for the TypeScript runtime.
// Run: npx tsx src/runtime/typescript/base_runtime_test.ts

import Database from "better-sqlite3";
import { ApplicationRecord, ValidationErrors, CollectionProxy, MODEL_REGISTRY } from "./base_runtime.js";

// --- Define models (mirrors the blog demo) ---

class Article extends ApplicationRecord {
  static override TABLE = "articles";
  static override COLUMNS = ["title", "body", "created_at", "updated_at"];

  declare title: string;
  declare body: string;

  comments(): CollectionProxy {
    return new CollectionProxy(this, "article_id", "Comment");
  }

  override runValidations(): void {
    if (!this.title) this.errors.add("title", "can't be blank");
    if (!this.body) this.errors.add("body", "can't be blank");
    if (typeof this.body === "string" && this.body.length < 10) {
      this.errors.add("body", "is too short (minimum is 10 characters)");
    }
  }

  override destroy(): boolean {
    this.comments().destroyAll();
    return super.destroy();
  }
}
MODEL_REGISTRY["Article"] = Article;

class Comment extends ApplicationRecord {
  static override TABLE = "comments";
  static override COLUMNS = ["article_id", "commenter", "body", "created_at", "updated_at"];

  declare article_id: number | null;
  declare commenter: string;
  declare body: string;

  article(): ApplicationRecord {
    return MODEL_REGISTRY["Article"].find(this.article_id!);
  }

  override runValidations(): void {
    if (!this.commenter) this.errors.add("commenter", "can't be blank");
    if (!this.body) this.errors.add("body", "can't be blank");
  }
}
MODEL_REGISTRY["Comment"] = Comment;

// --- Setup in-memory DB ---

const db = new Database(":memory:");
db.exec("PRAGMA foreign_keys = ON");
db.exec(`CREATE TABLE articles (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  title TEXT NOT NULL,
  body TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
)`);
db.exec(`CREATE TABLE comments (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  article_id INTEGER NOT NULL,
  commenter TEXT NOT NULL,
  body TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
)`);
ApplicationRecord.db = db;

// --- Test runner ---

let passed = 0;
let failed = 0;

function assert(condition: boolean, msg: string) {
  if (condition) {
    passed++;
  } else {
    failed++;
    console.error(`FAIL: ${msg}`);
  }
}

// --- CRUD ---

const article = Article.create({ title: "Hello", body: "This is a sufficiently long body." });
assert(article.id !== null, "create: article has id");
assert(article.persisted, "create: article is persisted");
assert((article as Article).title === "Hello", "create: title is set");

const found = Article.find(article.id!);
assert(found.id === article.id, "find: returns same article");

assert(Article.all().length === 1, "all: returns one article");
assert(Article.count() === 1, "count: returns 1");

article.update({ title: "Updated" });
const reloaded = Article.find(article.id!);
assert((reloaded as Article).title === "Updated", "update: title changed");

// --- Validations ---

const bad = new Article({ title: "", body: "" });
assert(!bad.save(), "validation: save returns false for invalid");
assert(bad.errors.any(), "validation: errors present");
assert(bad.errors.fullMessages().length > 0, "validation: full messages present");

const tooShort = new Article({ title: "OK", body: "Short" });
assert(!tooShort.save(), "validation: body too short rejected");

// --- Associations ---

const comment = (article as Article).comments().create({ commenter: "Alice", body: "Nice!" });
assert(comment.id !== null, "association: comment has id");
assert((comment as Comment).article_id === article.id, "association: foreign key set");
assert((article as Article).comments().size() === 1, "association: one comment");

const foundComments = Comment.where({ article_id: article.id });
assert(foundComments.length === 1, "where: finds comment");

// --- Dependent destroy ---

article.destroy();
assert(Comment.count() === 0, "dependent destroy: comments removed");
assert(Article.count() === 0, "dependent destroy: article removed");

// --- ValidationErrors API ---

const errors = new ValidationErrors();
errors.add("title", "can't be blank");
errors.add("body", "is too short");
assert(errors.any(), "errors: any() is true");
assert(errors.length === 2, "errors: length is 2");
assert(errors.fullMessages().length === 2, "errors: two full messages");
assert(errors.get("title").length === 1, "errors: get returns field errors");
assert(errors.get("missing").length === 0, "errors: get returns empty for missing field");
errors.clear();
assert(!errors.any(), "errors: cleared");
assert(errors.empty(), "errors: empty after clear");

// --- Result ---

console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed > 0 ? 1 : 0);
