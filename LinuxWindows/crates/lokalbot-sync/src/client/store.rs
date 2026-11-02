//! The phone's local copy: records, a full-text index, the pairing, the
//! cursor, queued ops and questions, and Ask history.

use std::collections::HashMap;
use std::path::Path;

use rusqlite::{Connection, OptionalExtension as _, Transaction, params};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::error::Result;
use crate::keys::KEY_LEN;
use crate::messages::Envelope;
use crate::records::{DAY, MEETING, TRANSCRIPT, str_field};

const SCHEMA: &str = "
CREATE TABLE IF NOT EXISTS records (
    kind TEXT NOT NULL,
    key TEXT NOT NULL,
    version INTEGER NOT NULL,
    seq INTEGER NOT NULL,
    deleted INTEGER NOT NULL DEFAULT 0,
    sort_key TEXT NOT NULL,
    body TEXT NOT NULL,
    PRIMARY KEY (kind, key)
);
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS ops (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    op_id TEXT NOT NULL UNIQUE,
    meeting_id TEXT NOT NULL,
    action_id TEXT NOT NULL,
    status TEXT NOT NULL,
    body TEXT NOT NULL,
    sent INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS action_overrides (
    meeting_id TEXT NOT NULL,
    action_id TEXT NOT NULL,
    status TEXT NOT NULL,
    op_id TEXT NOT NULL,
    PRIMARY KEY (meeting_id, action_id)
);
CREATE TABLE IF NOT EXISTS action_notes (
    meeting_id TEXT NOT NULL,
    action_id TEXT NOT NULL,
    requested_status TEXT NOT NULL,
    result TEXT NOT NULL,
    message TEXT,
    meeting_version INTEGER NOT NULL,
    at TEXT NOT NULL,
    PRIMARY KEY (meeting_id, action_id)
);
CREATE TABLE IF NOT EXISTS questions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    request_id TEXT NOT NULL UNIQUE,
    request TEXT NOT NULL,
    queued_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS ask_history (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    request_id TEXT NOT NULL,
    request TEXT NOT NULL,
    result TEXT NOT NULL,
    answered_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS doc_meta (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    record_kind TEXT NOT NULL,
    record_key TEXT NOT NULL,
    field TEXT NOT NULL,
    meeting_id TEXT,
    at REAL,
    date TEXT
);
CREATE INDEX IF NOT EXISTS doc_meta_record ON doc_meta(record_kind, record_key);
CREATE VIRTUAL TABLE IF NOT EXISTS docs USING fts5(text, tokenize = 'unicode61 remove_diacritics 2');
";

const CURSOR: &str = "cursor";
const SAMPLE: &str = "sample";
const PAIRING: &str = "pairing";
const LAST_SYNC_AT: &str = "last_sync_at";
const LAST_ADDRESS: &str = "last_address";

/// The paired Mac, as stored.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Pairing {
    pub mac_name: String,
    pub mac_key: String,
    pub addresses: Vec<String>,
    pub port: u16,
    pub paired_at: String,
}

impl Pairing {
    pub fn mac_key(&self) -> Result<[u8; KEY_LEN]> {
        crate::keys::key_array(&crate::keys::b64url_decode(&self.mac_key)?, "Mac key")
    }
}

/// A queued op waiting for the Mac.
pub(crate) struct QueuedOp {
    pub op_id: String,
    pub body: Value,
}

/// A local status change waiting for the Mac, or the note an op left.
#[derive(Clone, Debug, Default)]
pub(crate) struct ActionState {
    pub pending_status: Option<String>,
    pub note: Option<Value>,
}

/// What applying a batch changed.
#[derive(Default)]
pub(crate) struct Applied {
    pub received: u32,
    pub deleted: u32,
}

pub(crate) struct ClientStore {
    pub(super) db: Connection,
}

impl ClientStore {
    pub fn open(path: &Path) -> Result<Self> {
        if let Some(parent) = path.parent().filter(|p| !p.as_os_str().is_empty()) {
            std::fs::create_dir_all(parent)?;
        }
        let db = Connection::open(path)?;
        db.execute_batch(
            "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA secure_delete=ON;",
        )?;
        db.execute_batch(SCHEMA)?;
        Ok(Self { db })
    }

    fn meta(&self, key: &str) -> Result<Option<String>> {
        Ok(self
            .db
            .query_row("SELECT value FROM meta WHERE key = ?1", [key], |row| {
                row.get(0)
            })
            .optional()?)
    }

    fn set_meta(&self, key: &str, value: &str) -> Result<()> {
        self.db.execute(
            "INSERT INTO meta (key, value) VALUES (?1, ?2) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            params![key, value],
        )?;
        Ok(())
    }

    pub fn pairing(&self) -> Result<Option<Pairing>> {
        Ok(self
            .meta(PAIRING)?
            .and_then(|json| serde_json::from_str(&json).ok()))
    }

    pub fn set_pairing(&self, pairing: &Pairing) -> Result<()> {
        self.set_meta(
            PAIRING,
            &serde_json::to_string(pairing).expect("pairing serialises"),
        )
    }

    pub fn cursor(&self) -> Result<u64> {
        Ok(self.meta(CURSOR)?.and_then(|v| v.parse().ok()).unwrap_or(0))
    }

    pub fn set_cursor(&self, cursor: u64) -> Result<()> {
        self.set_meta(CURSOR, &cursor.to_string())
    }

    pub fn is_sample(&self) -> Result<bool> {
        Ok(self.meta(SAMPLE)?.as_deref() == Some("1"))
    }

    pub fn set_sample(&self) -> Result<()> {
        self.set_meta(SAMPLE, "1")
    }

    pub fn last_sync(&self) -> Result<(Option<String>, Option<String>)> {
        Ok((self.meta(LAST_SYNC_AT)?, self.meta(LAST_ADDRESS)?))
    }

    pub fn record_sync(&self, at: &str, address: &str) -> Result<()> {
        self.set_meta(LAST_SYNC_AT, at)?;
        self.set_meta(LAST_ADDRESS, address)
    }

    pub fn set_last_address(&self, address: &str) -> Result<()> {
        self.set_meta(LAST_ADDRESS, address)
    }

    /// Erases everything: records, index, pairing, queues and history.
    pub fn wipe(&self) -> Result<()> {
        self.db.execute_batch(
            "BEGIN;
             DELETE FROM records; DELETE FROM meta; DELETE FROM ops; DELETE FROM action_overrides;
             DELETE FROM action_notes; DELETE FROM questions; DELETE FROM ask_history;
             DELETE FROM doc_meta; DELETE FROM docs;
             COMMIT;",
        )?;
        // Rebuild the file without the freed pages, then move the result out
        // of the WAL into the main file and empty the WAL.
        self.db
            .execute_batch("VACUUM; PRAGMA wal_checkpoint(TRUNCATE);")?;
        Ok(())
    }

    // Records

    /// Upserts a batch, keeping the higher version of each record.
    pub fn apply(&mut self, items: &[Envelope]) -> Result<Applied> {
        let tx = self.db.transaction()?;
        let mut applied = Applied::default();
        for envelope in items {
            if upsert(&tx, envelope)? {
                if envelope.deleted {
                    applied.deleted += 1;
                } else {
                    applied.received += 1;
                }
            }
        }
        tx.commit()?;
        Ok(applied)
    }

    pub fn body(&self, kind: &str, key: &str) -> Result<Option<Value>> {
        let body: Option<String> = self
            .db
            .query_row(
                "SELECT body FROM records WHERE kind = ?1 AND key = ?2 AND deleted = 0",
                params![kind, key],
                |row| row.get(0),
            )
            .optional()?;
        Ok(body.and_then(|body| serde_json::from_str(&body).ok()))
    }

    pub fn version(&self, kind: &str, key: &str) -> Result<Option<u64>> {
        let version: Option<i64> = self
            .db
            .query_row(
                "SELECT version FROM records WHERE kind = ?1 AND key = ?2",
                params![kind, key],
                |row| row.get(0),
            )
            .optional()?;
        Ok(version.map(|v| v as u64))
    }

    /// Live bodies of one kind, in `ORDER BY` order.
    pub fn bodies(&self, kind: &str, order_by: &str) -> Result<Vec<(String, Value)>> {
        let mut statement = self.db.prepare(&format!(
            "SELECT key, body FROM records WHERE kind = ?1 AND deleted = 0 ORDER BY {order_by}"
        ))?;
        let rows = statement
            .query_map([kind], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        Ok(rows
            .into_iter()
            .filter_map(|(key, body)| serde_json::from_str(&body).ok().map(|body| (key, body)))
            .collect())
    }

    /// Writes a body in place (sample library edits only; no new version).
    pub fn replace_body(&self, kind: &str, key: &str, body: &Value) -> Result<()> {
        self.db.execute(
            "UPDATE records SET body = ?3 WHERE kind = ?1 AND key = ?2",
            params![kind, key, body.to_string()],
        )?;
        Ok(())
    }

    // Ops and pending action states

    /// Queues an op and shows its status locally until the Mac answers.
    /// Unsent ops for the same action are replaced.
    pub fn queue_op(
        &mut self,
        meeting_id: &str,
        action_id: &str,
        status: &str,
        op: &Value,
        now: &str,
    ) -> Result<()> {
        let op_id = str_field(op, "opId").unwrap_or_default();
        let tx = self.db.transaction()?;
        tx.execute(
            "DELETE FROM ops WHERE meeting_id = ?1 AND action_id = ?2 AND sent = 0",
            params![meeting_id, action_id],
        )?;
        tx.execute(
            "INSERT INTO ops (op_id, meeting_id, action_id, status, body, created_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            params![op_id, meeting_id, action_id, status, op.to_string(), now],
        )?;
        tx.execute(
            "INSERT INTO action_overrides (meeting_id, action_id, status, op_id) VALUES (?1, ?2, ?3, ?4) \
             ON CONFLICT(meeting_id, action_id) DO UPDATE SET status = excluded.status, op_id = excluded.op_id",
            params![meeting_id, action_id, status, op_id],
        )?;
        tx.execute(
            "DELETE FROM action_notes WHERE meeting_id = ?1 AND action_id = ?2",
            params![meeting_id, action_id],
        )?;
        tx.commit()?;
        Ok(())
    }

    /// Queued ops in the order they were made; marks them sent.
    pub fn take_ops_for_sending(&self) -> Result<Vec<QueuedOp>> {
        let mut statement = self.db.prepare("SELECT op_id, body FROM ops ORDER BY id")?;
        let ops = statement
            .query_map([], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        self.db.execute("UPDATE ops SET sent = 1", [])?;
        Ok(ops
            .into_iter()
            .filter_map(|(op_id, body)| {
                serde_json::from_str(&body)
                    .ok()
                    .map(|body| QueuedOp { op_id, body })
            })
            .collect())
    }

    pub fn pending_op_count(&self) -> Result<u32> {
        let count: i64 = self
            .db
            .query_row("SELECT COUNT(*) FROM ops", [], |row| row.get(0))?;
        Ok(count as u32)
    }

    /// Records the Mac's answer to an op. `applied` clears the pending
    /// status (the rebuilt meeting has already arrived); `unmatched` and
    /// `rejected` revert it and keep a note.
    pub fn finish_op(
        &mut self,
        op_id: &str,
        result: &str,
        message: Option<&str>,
        now: &str,
    ) -> Result<()> {
        let op: Option<(String, String, String)> = self
            .db
            .query_row(
                "SELECT meeting_id, action_id, status FROM ops WHERE op_id = ?1",
                [op_id],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .optional()?;
        let Some((meeting_id, action_id, requested)) = op else {
            return Ok(());
        };
        let meeting_version = self.version(MEETING, &meeting_id)?.unwrap_or(0) as i64;
        let tx = self.db.transaction()?;
        tx.execute("DELETE FROM ops WHERE op_id = ?1", [op_id])?;
        tx.execute(
            "DELETE FROM action_overrides WHERE meeting_id = ?1 AND action_id = ?2 AND op_id = ?3",
            params![meeting_id, action_id, op_id],
        )?;
        if result != "applied" {
            tx.execute(
                "INSERT OR REPLACE INTO action_notes \
                 (meeting_id, action_id, requested_status, result, message, meeting_version, at) \
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
                params![
                    meeting_id,
                    action_id,
                    requested,
                    result,
                    message,
                    meeting_version,
                    now
                ],
            )?;
        }
        tx.commit()?;
        Ok(())
    }

    /// Pending statuses and notes by `(meeting id, action id)`.
    pub fn action_states(&self) -> Result<HashMap<(String, String), ActionState>> {
        let mut states: HashMap<(String, String), ActionState> = HashMap::new();
        let mut statement = self
            .db
            .prepare("SELECT meeting_id, action_id, status FROM action_overrides")?;
        for row in statement.query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
            ))
        })? {
            let (meeting, action, status) = row?;
            states.entry((meeting, action)).or_default().pending_status = Some(status);
        }
        let mut statement = self.db.prepare(
            "SELECT meeting_id, action_id, requested_status, result, message, at FROM action_notes",
        )?;
        for row in statement.query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
                row.get::<_, String>(3)?,
                row.get::<_, Option<String>>(4)?,
                row.get::<_, String>(5)?,
            ))
        })? {
            let (meeting, action, requested, result, message, at) = row?;
            let mut note =
                serde_json::json!({ "status": result, "requestedStatus": requested, "at": at });
            if let Some(message) = message {
                note["message"] = Value::String(message);
            }
            states.entry((meeting, action)).or_default().note = Some(note);
        }
        Ok(states)
    }

    // Questions and answers

    pub fn queue_question(&self, request_id: &str, request: &Value, now: &str) -> Result<()> {
        self.db.execute(
            "INSERT INTO questions (request_id, request, queued_at) VALUES (?1, ?2, ?3) \
             ON CONFLICT(request_id) DO UPDATE SET request = excluded.request",
            params![request_id, request.to_string(), now],
        )?;
        Ok(())
    }

    pub fn queued_questions(&self) -> Result<Vec<String>> {
        let mut statement = self
            .db
            .prepare("SELECT request FROM questions ORDER BY id")?;
        let questions = statement
            .query_map([], |row| row.get(0))?
            .collect::<rusqlite::Result<Vec<String>>>()?;
        Ok(questions)
    }

    /// Saves an answer and drops the question from the queue.
    pub fn save_answer(
        &self,
        request_id: &str,
        request: &Value,
        result: &Value,
        now: &str,
    ) -> Result<()> {
        let tx = self.db.unchecked_transaction()?;
        tx.execute(
            "INSERT INTO ask_history (request_id, request, result, answered_at) VALUES (?1, ?2, ?3, ?4)",
            params![request_id, request.to_string(), result.to_string(), now],
        )?;
        tx.execute("DELETE FROM questions WHERE request_id = ?1", [request_id])?;
        tx.commit()?;
        Ok(())
    }

    pub fn ask_history(&self, limit: u32) -> Result<Vec<String>> {
        let limit = if limit == 0 { -1 } else { i64::from(limit) };
        let mut statement = self
            .db
            .prepare("SELECT request, result FROM ask_history ORDER BY id DESC LIMIT ?1")?;
        let rows = statement
            .query_map([limit], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        Ok(rows
            .into_iter()
            .map(|(request, result)| {
                let request: Value = serde_json::from_str(&request).unwrap_or(Value::Null);
                let result: Value = serde_json::from_str(&result).unwrap_or(Value::Null);
                serde_json::json!({ "request": request, "result": result }).to_string()
            })
            .collect())
    }
}

/// Stores one envelope unless an equal or newer version is present. Keeps the
/// search index and pending action states in step. Returns whether it
/// changed anything.
fn upsert(tx: &Transaction<'_>, envelope: &Envelope) -> Result<bool> {
    let stored: Option<i64> = tx
        .query_row(
            "SELECT version FROM records WHERE kind = ?1 AND key = ?2",
            params![envelope.kind, envelope.key],
            |row| row.get(0),
        )
        .optional()?;
    if stored.is_some_and(|version| version as u64 >= envelope.version) {
        return Ok(false);
    }
    let body = if envelope.deleted {
        Value::Object(Default::default())
    } else {
        envelope.body.clone()
    };
    tx.execute(
        "INSERT INTO records (kind, key, version, seq, deleted, sort_key, body) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7) \
         ON CONFLICT(kind, key) DO UPDATE SET version = excluded.version, seq = excluded.seq, \
         deleted = excluded.deleted, sort_key = excluded.sort_key, body = excluded.body",
        params![
            envelope.kind,
            envelope.key,
            envelope.version as i64,
            envelope.seq as i64,
            envelope.deleted,
            envelope.sort_key,
            body.to_string()
        ],
    )?;
    super::search::reindex(
        tx,
        &envelope.kind,
        &envelope.key,
        (!envelope.deleted).then_some(&body),
    )?;
    if envelope.kind == MEETING {
        settle_actions(
            tx,
            &envelope.key,
            envelope.version,
            (!envelope.deleted).then_some(&body),
        )?;
    }
    Ok(true)
}

/// A newer meeting record settles local action states: a pending status the
/// Mac now shows is no longer pending, and notes from older versions go.
fn settle_actions(
    tx: &Transaction<'_>,
    meeting_id: &str,
    version: u64,
    body: Option<&Value>,
) -> Result<()> {
    tx.execute(
        "DELETE FROM action_notes WHERE meeting_id = ?1 AND meeting_version < ?2",
        params![meeting_id, version as i64],
    )?;
    let Some(body) = body else {
        tx.execute(
            "DELETE FROM action_overrides WHERE meeting_id = ?1",
            [meeting_id],
        )?;
        return Ok(());
    };
    let statuses: HashMap<&str, &str> = body
        .get("actions")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|action| Some((str_field(action, "id")?, str_field(action, "status")?)))
        .collect();
    let mut statement =
        tx.prepare("SELECT action_id, status FROM action_overrides WHERE meeting_id = ?1")?;
    let overrides = statement
        .query_map([meeting_id], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    for (action_id, status) in overrides {
        if statuses.get(action_id.as_str()) == Some(&status.as_str()) {
            tx.execute(
                "DELETE FROM action_overrides WHERE meeting_id = ?1 AND action_id = ?2",
                params![meeting_id, action_id],
            )?;
        }
    }
    Ok(())
}

/// Record kinds the search index covers.
pub(crate) fn is_indexed(kind: &str) -> bool {
    matches!(kind, MEETING | TRANSCRIPT | DAY)
}
