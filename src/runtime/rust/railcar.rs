// Package railcar provides an ActiveRecord-like ORM for railcar-generated Rust apps.
// Hand-written Rust (not transpiled from Crystal).
//
// The runtime is intentionally thin — models generate their own SQL for insert/update
// since Rust's type system makes generic column value passing complex. The runtime
// provides the database connection, validation types, and shared utilities.

use rusqlite::{params, Connection, Row};
use std::sync::Mutex;

// ── Database ──

lazy_static::lazy_static! {
    pub static ref DB: Mutex<Option<Connection>> = Mutex::new(None);
}

pub fn with_db<F, T>(f: F) -> Result<T, String>
where
    F: FnOnce(&Connection) -> Result<T, rusqlite::Error>,
{
    let guard = DB.lock().map_err(|e| e.to_string())?;
    let conn = guard.as_ref().ok_or("database not initialized")?;
    f(conn).map_err(|e| e.to_string())
}

pub fn now() -> String {
    chrono::Utc::now()
        .format("%Y-%m-%d %H:%M:%S%.6f")
        .to_string()
}

// ── Validation ──

#[derive(Debug, Clone)]
pub struct ValidationError {
    pub field: String,
    pub message: String,
}

impl ValidationError {
    pub fn new(field: &str, message: &str) -> Self {
        Self {
            field: field.to_string(),
            message: message.to_string(),
        }
    }

    pub fn full_message(&self) -> String {
        let mut field = self.field.replace('_', " ");
        if let Some(first) = field.get_mut(0..1) {
            first.make_ascii_uppercase();
        }
        format!("{} {}", field, self.message)
    }
}

// ── Model trait ──
// Models implement this for shared operations (find, count, from_row).
// Insert/update/delete are generated as methods on each model struct
// since they need concrete column types.

pub trait Model: Sized {
    fn table_name() -> &'static str;
    fn id(&self) -> i64;
    fn set_id(&mut self, id: i64);
    fn persisted(&self) -> bool;
    fn set_persisted(&mut self, persisted: bool);
    fn errors(&self) -> &[ValidationError];
    fn set_errors(&mut self, errors: Vec<ValidationError>);
    fn run_validations(&self) -> Vec<ValidationError>;
    fn from_row(row: &Row) -> Result<Self, rusqlite::Error>;
}

// ── Broadcaster trait ──

pub trait Broadcaster {
    fn after_save(&self);
    fn after_delete(&self);
}

// ── Generic queries ──

pub fn find<T: Model>(id: i64) -> Result<T, String> {
    with_db(|conn| {
        conn.query_row(
            &format!("SELECT * FROM {} WHERE id = ?", T::table_name()),
            params![id],
            |row| T::from_row(row),
        )
    })
    .map(|mut record| {
        record.set_persisted(true);
        record
    })
    .map_err(|_| format!("{} not found: {}", T::table_name(), id))
}

pub fn all<T: Model>(order_by: &str) -> Result<Vec<T>, String> {
    with_db(|conn| {
        let mut stmt = conn.prepare(&format!(
            "SELECT * FROM {} ORDER BY {}",
            T::table_name(),
            order_by
        ))?;
        let rows = stmt.query_map([], |row| T::from_row(row))?;
        let mut results = Vec::new();
        for row in rows {
            let mut record = row?;
            record.set_persisted(true);
            results.push(record);
        }
        Ok(results)
    })
}

pub fn where_eq<T: Model>(column: &str, value: i64) -> Result<Vec<T>, String> {
    with_db(|conn| {
        let mut stmt = conn.prepare(&format!(
            "SELECT * FROM {} WHERE {} = ?",
            T::table_name(),
            column
        ))?;
        let rows = stmt.query_map(params![value], |row| T::from_row(row))?;
        let mut results = Vec::new();
        for row in rows {
            let mut record = row?;
            record.set_persisted(true);
            results.push(record);
        }
        Ok(results)
    })
}

pub fn count(table_name: &str) -> Result<i64, String> {
    with_db(|conn| {
        conn.query_row(
            &format!("SELECT COUNT(*) FROM {}", table_name),
            [],
            |row| row.get(0),
        )
    })
}

pub fn delete_by_id(table_name: &str, id: i64) -> Result<(), String> {
    with_db(|conn| {
        conn.execute(
            &format!("DELETE FROM {} WHERE id = ?", table_name),
            params![id],
        )
        .map(|_| ())
    })
}

pub fn last_insert_rowid() -> Result<i64, String> {
    with_db(|conn| Ok(conn.last_insert_rowid()))
}
