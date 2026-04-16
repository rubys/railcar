// Package railcar provides an ActiveRecord-like ORM for railcar-generated Rust apps.
// Hand-written Rust (not transpiled from Crystal).
//
// The runtime is intentionally thin — models generate their own SQL for insert/update
// since Rust's type system makes generic column value passing complex. The runtime
// provides the database connection, validation types, broadcasting, and WebSocket.

use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::response::IntoResponse;
use futures_util::{SinkExt, StreamExt};
use rusqlite::{params, Connection, Row};
use serde_json::json;
use std::collections::HashMap;
use std::sync::{Arc, Mutex, RwLock};
use tokio::sync::mpsc;

// ── Logging ──

pub fn log_level() -> u8 {
    match std::env::var("LOG_LEVEL").unwrap_or_default().to_lowercase().as_str() {
        "debug" => 0,
        "info" => 1,
        "warn" => 2,
        "error" => 3,
        _ => 1,
    }
}

macro_rules! log_debug {
    ($($arg:tt)*) => { if $crate::railcar::log_level() <= 0 { eprintln!("[debug] {}", format!($($arg)*)); } };
}

macro_rules! log_info {
    ($($arg:tt)*) => { if $crate::railcar::log_level() <= 1 { eprintln!("[info]  {}", format!($($arg)*)); } };
}

pub(crate) use log_debug;
pub(crate) use log_info;

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

// ── Broadcasting ──

pub type RenderPartialFn = Box<dyn Fn(i64) -> String + Send + Sync>;

lazy_static::lazy_static! {
    static ref PARTIAL_RENDERERS: RwLock<HashMap<String, Arc<RenderPartialFn>>> =
        RwLock::new(HashMap::new());
}

pub fn register_partial(type_name: &str, f: impl Fn(i64) -> String + Send + Sync + 'static) {
    PARTIAL_RENDERERS
        .write()
        .unwrap()
        .insert(type_name.to_string(), Arc::new(Box::new(f)));
}

pub fn render_partial(type_name: &str, id: i64) -> String {
    if let Some(f) = PARTIAL_RENDERERS.read().unwrap().get(type_name) {
        f(id)
    } else {
        format!("<div>{} #{}</div>", type_name, id)
    }
}

pub fn turbo_stream_html(action: &str, target: &str, content: &str) -> String {
    if content.is_empty() {
        format!(
            r#"<turbo-stream action="{}" target="{}"></turbo-stream>"#,
            action, target
        )
    } else {
        format!(
            r#"<turbo-stream action="{}" target="{}"><template>{}</template></turbo-stream>"#,
            action, target, content
        )
    }
}

pub fn dom_id_for(table_name: &str, id: i64) -> String {
    // Simple singularize: strip trailing 's'
    let singular = if table_name.ends_with('s') {
        &table_name[..table_name.len() - 1]
    } else {
        table_name
    };
    format!("{}_{}", singular, id)
}

pub fn broadcast_replace_to(table_name: &str, id: i64, type_name: &str, channel: &str, target: &str) {
    let target = if target.is_empty() { dom_id_for(table_name, id) } else { target.to_string() };
    let html = render_partial(type_name, id);
    let stream = turbo_stream_html("replace", &target, &html);
    log_info!("Broadcast replace on {:?} → target={:?} ({} bytes)", channel, target, html.len());
    CABLE.broadcast(channel, &stream);
}

pub fn broadcast_prepend_to(table_name: &str, id: i64, type_name: &str, channel: &str, target: &str) {
    let target = if target.is_empty() { table_name.to_string() } else { target.to_string() };
    let html = render_partial(type_name, id);
    let stream = turbo_stream_html("prepend", &target, &html);
    log_info!("Broadcast prepend on {:?} → target={:?} ({} bytes)", channel, target, html.len());
    CABLE.broadcast(channel, &stream);
}

pub fn broadcast_remove_to(table_name: &str, id: i64, channel: &str, target: &str) {
    let target = if target.is_empty() { dom_id_for(table_name, id) } else { target.to_string() };
    let stream = turbo_stream_html("remove", &target, "");
    log_info!("Broadcast remove on {:?} → target={:?}", channel, target);
    CABLE.broadcast(channel, &stream);
}

// ── CableServer ──

struct Subscriber {
    tx: mpsc::UnboundedSender<String>,
    identifier: String,
}

pub struct CableServer {
    channels: RwLock<HashMap<String, Vec<Subscriber>>>,
}

lazy_static::lazy_static! {
    pub static ref CABLE: CableServer = CableServer {
        channels: RwLock::new(HashMap::new()),
    };
}

impl CableServer {
    pub fn subscribe(&self, channel: &str, tx: mpsc::UnboundedSender<String>, identifier: &str) {
        let mut channels = self.channels.write().unwrap();
        channels
            .entry(channel.to_string())
            .or_default()
            .push(Subscriber {
                tx,
                identifier: identifier.to_string(),
            });
        log_info!("ActionCable: subscribed to {:?} ({} subscribers)",
            channel,
            channels.get(channel).map_or(0, |v| v.len()));
    }

    pub fn unsubscribe(&self, tx_ptr: usize) {
        let mut channels = self.channels.write().unwrap();
        for subs in channels.values_mut() {
            subs.retain(|s| &s.tx as *const _ as usize != tx_ptr);
        }
        channels.retain(|_, subs| !subs.is_empty());
    }

    pub fn broadcast(&self, channel: &str, html: &str) {
        let channels = self.channels.read().unwrap();
        if let Some(subs) = channels.get(channel) {
            log_debug!("Broadcast to {:?} ({} subscribers)", channel, subs.len());
            for sub in subs {
                let msg = json!({
                    "type": "message",
                    "identifier": sub.identifier,
                    "message": html
                })
                .to_string();
                let _ = sub.tx.send(msg);
            }
        }
    }
}

// ── WebSocket handler ──

pub async fn cable_handler(ws: WebSocketUpgrade) -> impl IntoResponse {
    ws.protocols(["actioncable-v1-json"])
        .on_upgrade(handle_cable_socket)
}

async fn handle_cable_socket(mut socket: WebSocket) {
    log_info!("ActionCable: client connected");

    // Send welcome
    let _ = socket
        .send(Message::Text(json!({"type": "welcome"}).to_string().into()))
        .await;

    // Channel for outbound messages (broadcasts + pings)
    let (tx, mut rx) = mpsc::unbounded_channel::<String>();
    let tx_ptr = &tx as *const _ as usize;

    // Ping task
    let ping_tx = tx.clone();
    let ping_task = tokio::spawn(async move {
        let mut interval = tokio::time::interval(std::time::Duration::from_secs(3));
        loop {
            interval.tick().await;
            let msg = json!({
                "type": "ping",
                "message": chrono::Utc::now().timestamp()
            })
            .to_string();
            if ping_tx.send(msg).is_err() {
                break;
            }
        }
    });

    // Split socket: outbound via channel, inbound in this task
    let (mut sender, mut receiver) = socket.split();

    let send_task = tokio::spawn(async move {
        while let Some(msg) = rx.recv().await {
            if sender.send(Message::Text(msg.into())).await.is_err() {
                break;
            }
        }
    });

    // Inbound receiver
    while let Some(Ok(msg)) = receiver.next().await {
        if let Message::Text(text) = msg {
            log_debug!("ActionCable: received {}", text);
            if let Ok(data) = serde_json::from_str::<serde_json::Value>(&text) {
                if data["command"] == "subscribe" {
                    if let Some(identifier) = data["identifier"].as_str() {
                        // Decode channel from signed_stream_name
                        if let Ok(id_data) = serde_json::from_str::<serde_json::Value>(identifier) {
                            if let Some(signed) = id_data["signed_stream_name"].as_str() {
                                log_debug!("ActionCable: signed_stream_name={:?}", signed);
                                let base64_part = signed.split("--").next().unwrap_or("");
                                if let Ok(decoded) =
                                    base64_decode(base64_part)
                                {
                                    log_debug!("ActionCable: decoded={}", decoded);
                                    let channel: String =
                                        serde_json::from_str(&decoded).unwrap_or_default();
                                    CABLE.subscribe(&channel, tx.clone(), identifier);

                                    let confirm = json!({
                                        "type": "confirm_subscription",
                                        "identifier": identifier
                                    })
                                    .to_string();
                                    let _ = tx.send(confirm);
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // Cleanup
    log_info!("ActionCable: client disconnected");
    ping_task.abort();
    send_task.abort();
    CABLE.unsubscribe(tx_ptr);
}

fn base64_decode(input: &str) -> Result<String, String> {
    const CHARS: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut table = [255u8; 256];
    for (i, &c) in CHARS.iter().enumerate() {
        table[c as usize] = i as u8;
    }

    let input = input.trim_end_matches('=');
    let mut result = Vec::new();
    let bytes = input.as_bytes();

    for chunk in bytes.chunks(4) {
        let mut buf = [0u8; 4];
        for (i, &b) in chunk.iter().enumerate() {
            buf[i] = table[b as usize];
            if buf[i] == 255 {
                return Err("invalid base64".to_string());
            }
        }
        result.push(buf[0] << 2 | buf[1] >> 4);
        if chunk.len() > 2 {
            result.push((buf[1] & 0xf) << 4 | buf[2] >> 2);
        }
        if chunk.len() > 3 {
            result.push((buf[2] & 3) << 6 | buf[3]);
        }
    }

    String::from_utf8(result).map_err(|e| e.to_string())
}
