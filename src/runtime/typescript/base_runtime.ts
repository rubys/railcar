// TypeScript runtime for railcar-generated apps.
// Hand-written TypeScript (not transpiled from Crystal).
// Crystal base.cr is used only for program.semantic() type checking.

import Database from "better-sqlite3";

// --- Model Registry ---

export const MODEL_REGISTRY: Record<string, typeof ApplicationRecord> = {};

// --- Turbo Streams ---

function turboStreamHtml(action: string, target: string, content: string = ""): string {
  if (content) {
    return `<turbo-stream action="${action}" target="${target}"><template>${content}</template></turbo-stream>`;
  }
  return `<turbo-stream action="${action}" target="${target}"></turbo-stream>`;
}

// --- Validation ---

export class ValidationError {
  field: string;
  message: string;

  constructor(field: string, message: string) {
    this.field = field;
    this.message = message;
  }

  fullMessage(): string {
    const label = this.field.replace(/_/g, " ").replace(/^./, (c) => c.toUpperCase());
    return `${label} ${this.message}`;
  }

  toString(): string {
    return this.fullMessage();
  }
}

export class ValidationErrors {
  private _errors: Record<string, string[]> = {};

  add(field: string, message: string): void {
    if (!this._errors[field]) {
      this._errors[field] = [];
    }
    this._errors[field].push(message);
  }

  any(): boolean {
    return Object.keys(this._errors).length > 0;
  }

  empty(): boolean {
    return !this.any();
  }

  get length(): number {
    return Object.values(this._errors).reduce((sum, msgs) => sum + msgs.length, 0);
  }

  get(field: string): string[] {
    return this._errors[field] || [];
  }

  fullMessages(): string[] {
    const result: string[] = [];
    for (const [field, messages] of Object.entries(this._errors)) {
      const label = field.replace(/_/g, " ").replace(/^./, (c) => c.toUpperCase());
      for (const msg of messages) {
        result.push(`${label} ${msg}`);
      }
    }
    return result;
  }

  clear(): void {
    this._errors = {};
  }

  *[Symbol.iterator](): Iterator<ValidationError> {
    for (const [field, messages] of Object.entries(this._errors)) {
      for (const msg of messages) {
        yield new ValidationError(field, msg);
      }
    }
  }
}

// --- Collection Proxy ---

export class CollectionProxy {
  private owner: ApplicationRecord;
  private foreignKey: string;
  private modelName: string;

  constructor(owner: ApplicationRecord, foreignKey: string, modelName: string) {
    this.owner = owner;
    this.foreignKey = foreignKey;
    this.modelName = modelName;
  }

  modelClass(): typeof ApplicationRecord {
    return MODEL_REGISTRY[this.modelName];
  }

  build(attrs: Record<string, unknown> = {}): ApplicationRecord {
    attrs[this.foreignKey] = this.owner.id;
    return new (this.modelClass())(attrs);
  }

  create(attrs: Record<string, unknown> = {}): ApplicationRecord {
    const record = this.build(attrs);
    record.save();
    return record;
  }

  destroyAll(): void {
    const cls = this.modelClass();
    ApplicationRecord.db!.prepare(
      `DELETE FROM ${cls.TABLE} WHERE ${this.foreignKey} = ?`
    ).run(this.owner.id);
  }

  size(): number {
    return this.all().length;
  }

  get length(): number {
    return this.size();
  }

  find(id: number): ApplicationRecord {
    return this.modelClass().find(id);
  }

  all(): ApplicationRecord[] {
    return this.modelClass().where({ [this.foreignKey]: this.owner.id });
  }

  [Symbol.iterator](): Iterator<ApplicationRecord> {
    return this.all()[Symbol.iterator]();
  }
}

// --- Application Record ---

export type Broadcaster = {
  broadcast(channel: string, html: string): void;
};

export class ApplicationRecord {
  static db: Database.Database | null = null;
  static TABLE: string = "";
  static COLUMNS: string[] = [];
  static _broadcaster: Broadcaster | null = null;
  static renderPartial: ((record: ApplicationRecord) => string) | null = null;

  private static _afterSaveCallbacks: ((record: ApplicationRecord) => void)[] = [];
  private static _afterDestroyCallbacks: ((record: ApplicationRecord) => void)[] = [];

  id: number | null = null;
  private _persisted: boolean = false;
  private _errors: ValidationErrors = new ValidationErrors();

  // Dynamic column attributes
  [key: string]: unknown;

  constructor(attrs: Record<string, unknown> = {}) {
    this.id = (attrs.id as number | null) ?? null;
    for (const col of (this.constructor as typeof ApplicationRecord).COLUMNS) {
      (this as Record<string, unknown>)[col] = attrs[col] ?? this._defaultFor(col);
    }
    this._persisted = (attrs._persisted as boolean) ?? false;
    this._errors = new ValidationErrors();
  }

  private _defaultFor(col: string): unknown {
    if (col.endsWith("_id")) return null;
    if (col === "created_at" || col === "updated_at") return null;
    return "";
  }

  get errors(): ValidationErrors {
    return this._errors;
  }

  get persisted(): boolean {
    return this._persisted;
  }

  newRecord(): boolean {
    return !this._persisted;
  }

  valid(): boolean {
    this._errors = new ValidationErrors();
    this.runValidations();
    return !this._errors.any();
  }

  runValidations(): void {
    // Overridden by subclasses
  }

  update(attrs: Record<string, unknown>): boolean {
    for (const [k, v] of Object.entries(attrs)) {
      (this as Record<string, unknown>)[k] = v;
    }
    return this.save();
  }

  save(): boolean {
    this._errors = new ValidationErrors();
    this.runValidations();
    if (this._errors.any()) {
      return false;
    }
    const cls = this.constructor as typeof ApplicationRecord;
    const db = cls.db!;
    const now = new Date().toISOString().replace("T", " ").replace("Z", "");
    const cols = cls.COLUMNS.filter((c) => c !== "created_at" && c !== "updated_at");

    if (this.id === null) {
      // INSERT
      if (cls.COLUMNS.includes("created_at")) {
        (this as Record<string, unknown>).created_at = now;
        (this as Record<string, unknown>).updated_at = now;
      }
      const allCols = [
        ...cols,
        ...(cls.COLUMNS.includes("created_at") ? ["created_at"] : []),
        ...(cls.COLUMNS.includes("updated_at") ? ["updated_at"] : []),
      ];
      const placeholders = allCols.map(() => "?").join(", ");
      const colStr = allCols.join(", ");
      const values = allCols.map((c) => (this as Record<string, unknown>)[c]);
      const result = db.prepare(
        `INSERT INTO ${cls.TABLE} (${colStr}) VALUES (${placeholders})`
      ).run(...values);
      this.id = Number(result.lastInsertRowid);
      this._persisted = true;
    } else {
      // UPDATE
      if (cls.COLUMNS.includes("updated_at")) {
        (this as Record<string, unknown>).updated_at = now;
      }
      const updateCols = cols.filter((c) => c !== "created_at");
      if (cls.COLUMNS.includes("updated_at")) {
        updateCols.push("updated_at");
      }
      const sets = updateCols.map((c) => `${c} = ?`).join(", ");
      const values = [...updateCols.map((c) => (this as Record<string, unknown>)[c]), this.id];
      db.prepare(`UPDATE ${cls.TABLE} SET ${sets} WHERE id = ?`).run(...values);
    }
    this._runCallbacks("afterSave");
    return true;
  }

  destroy(): boolean {
    if (!this._persisted) {
      return false;
    }
    const cls = this.constructor as typeof ApplicationRecord;
    cls.db!.prepare(`DELETE FROM ${cls.TABLE} WHERE id = ?`).run(this.id);
    this._persisted = false;
    this._runCallbacks("afterDestroy");
    return true;
  }

  reload(): this {
    const cls = this.constructor as typeof ApplicationRecord;
    const fresh = cls.find(this.id!);
    for (const col of cls.COLUMNS) {
      (this as Record<string, unknown>)[col] = (fresh as Record<string, unknown>)[col];
    }
    return this;
  }

  // --- Callbacks ---

  static afterSave(callback: (record: ApplicationRecord) => void): void {
    // Each subclass needs its own callback array
    if (!Object.prototype.hasOwnProperty.call(this, "_afterSaveCallbacks")) {
      this._afterSaveCallbacks = [];
    }
    this._afterSaveCallbacks.push(callback);
  }

  static afterDestroy(callback: (record: ApplicationRecord) => void): void {
    if (!Object.prototype.hasOwnProperty.call(this, "_afterDestroyCallbacks")) {
      this._afterDestroyCallbacks = [];
    }
    this._afterDestroyCallbacks.push(callback);
  }

  private _runCallbacks(name: string): void {
    const cls = this.constructor as typeof ApplicationRecord;
    const callbacks = (cls as unknown as Record<string, unknown>)[`_${name}Callbacks`] as
      | ((record: ApplicationRecord) => void)[]
      | undefined;
    if (callbacks) {
      for (const cb of callbacks) {
        cb(this);
      }
    }
  }

  // --- Broadcasting ---

  private _domId(): string {
    const name = this.constructor.name.toLowerCase();
    return `${name}_${this.id}`;
  }

  private _broadcast(action: string, channel: string, target?: string): void {
    if (!ApplicationRecord._broadcaster) return;
    if (target === undefined) {
      target = (action === "replace" || action === "remove")
        ? this._domId()
        : (this.constructor as typeof ApplicationRecord).TABLE;
    }
    let html = "";
    if (action !== "remove") {
      const cls = this.constructor as typeof ApplicationRecord;
      if (cls.renderPartial) {
        html = cls.renderPartial(this);
      } else {
        html = this._toHtml();
      }
    }
    const stream = turboStreamHtml(action, target, html);
    ApplicationRecord._broadcaster.broadcast(channel, stream);
  }

  private _toHtml(): string {
    const domId = this._domId();
    const cls = this.constructor as typeof ApplicationRecord;
    const attrs = cls.COLUMNS
      .filter((k) => k !== "created_at" && k !== "updated_at")
      .map((k) => `<span class="${k}">${(this as Record<string, unknown>)[k] ?? ""}</span>`)
      .join("");
    return `<div id="${domId}">${attrs}</div>`;
  }

  broadcastReplaceTo(channel: string, target?: string): void {
    this._broadcast("replace", channel, target);
  }

  broadcastAppendTo(channel: string, target?: string): void {
    this._broadcast("append", channel, target);
  }

  broadcastPrependTo(channel: string, target?: string): void {
    this._broadcast("prepend", channel, target);
  }

  broadcastRemoveTo(channel: string, target?: string): void {
    this._broadcast("remove", channel, target);
  }

  // --- Class methods (query interface) ---

  static tableName(): string {
    return this.TABLE;
  }

  static find(id: number): ApplicationRecord {
    const row = this.db!.prepare(
      `SELECT * FROM ${this.TABLE} WHERE id = ?`
    ).get(id) as Record<string, unknown> | undefined;
    if (!row) {
      throw new Error(`${this.name} not found: ${id}`);
    }
    return this.fromRow(row);
  }

  static all(orderBy: string = "id"): ApplicationRecord[] {
    const rows = this.db!.prepare(
      `SELECT * FROM ${this.TABLE} ORDER BY ${orderBy}`
    ).all() as Record<string, unknown>[];
    return rows.map((r) => this.fromRow(r));
  }

  static where(conditions: Record<string, unknown>): ApplicationRecord[] {
    const keys = Object.keys(conditions);
    const clauses = keys.map((k) => `${k} = ?`).join(" AND ");
    const values = keys.map((k) => conditions[k]);
    const rows = this.db!.prepare(
      `SELECT * FROM ${this.TABLE} WHERE ${clauses}`
    ).all(...values) as Record<string, unknown>[];
    return rows.map((r) => this.fromRow(r));
  }

  static count(): number {
    const row = this.db!.prepare(
      `SELECT COUNT(*) as cnt FROM ${this.TABLE}`
    ).get() as { cnt: number };
    return row.cnt;
  }

  static last(): ApplicationRecord | null {
    const rows = this.all();
    return rows.length > 0 ? rows[rows.length - 1] : null;
  }

  static create(attrs: Record<string, unknown> = {}): ApplicationRecord {
    const record = new this(attrs);
    record.save();
    return record;
  }

  static fromRow(row: Record<string, unknown>): ApplicationRecord {
    return new this({ ...row, _persisted: true });
  }
}
