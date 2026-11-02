//! The Mac's companion database: published records, the change counter and
//! paired devices. Derived data plus device keys; deleting it means
//! re-pairing and a full re-sync.

use std::path::Path;

use rusqlite::{Connection, OptionalExtension as _, params};
use serde_json::Value;

use super::PairedDevice;
use crate::error::Result;
use crate::messages::Envelope;
use crate::records::{
    self, DAY, MANIFEST, MANIFEST_KEY, MEETING, TRANSCRIPT, canonical_json, content_hash, str_field,
};

const SCHEMA: &str = "
CREATE TABLE IF NOT EXISTS records (
    kind TEXT NOT NULL,
    key TEXT NOT NULL,
    version INTEGER NOT NULL,
    seq INTEGER NOT NULL,
    deleted INTEGER NOT NULL DEFAULT 0,
    sort_key TEXT NOT NULL,
    body TEXT NOT NULL,
    body_hash TEXT NOT NULL,
    PRIMARY KEY (kind, key)
);
CREATE INDEX IF NOT EXISTS records_seq ON records(seq);
CREATE TABLE IF NOT EXISTS counters (name TEXT PRIMARY KEY, value INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS devices (
    device_id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    platform TEXT NOT NULL,
    public_key BLOB NOT NULL UNIQUE,
    paired_at TEXT NOT NULL,
    last_seen_at TEXT,
    last_address TEXT
);
CREATE TABLE IF NOT EXISTS revoked_keys (
    public_key BLOB PRIMARY KEY,
    device_id TEXT NOT NULL,
    revoked_at TEXT NOT NULL
);
";

/// A paired device as the session code needs it.
#[derive(Clone, Debug)]
pub(crate) struct DeviceRow {
    pub device_id: String,
}

pub(crate) struct HostStore {
    db: Connection,
}

impl HostStore {
    pub fn open(path: &Path) -> Result<Self> {
        if let Some(parent) = path.parent().filter(|p| !p.as_os_str().is_empty()) {
            std::fs::create_dir_all(parent)?;
        }
        let db = Connection::open(path)?;
        db.execute_batch("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;")?;
        db.execute_batch(SCHEMA)?;
        Ok(Self { db })
    }

    pub fn current_seq(&self) -> Result<u64> {
        let seq: Option<i64> = self
            .db
            .query_row("SELECT value FROM counters WHERE name = 'seq'", [], |row| {
                row.get(0)
            })
            .optional()?;
        Ok(seq.unwrap_or(0) as u64)
    }

    fn next_seq(&self) -> Result<u64> {
        let seq = self.current_seq()? + 1;
        self.db.execute(
            "INSERT INTO counters (name, value) VALUES ('seq', ?1) \
             ON CONFLICT(name) DO UPDATE SET value = excluded.value",
            [seq as i64],
        )?;
        Ok(seq)
    }

    /// Stores a new version unless the canonical body is unchanged. Returns
    /// the new seq, or `None` for a no-op.
    pub fn publish(
        &mut self,
        kind: &str,
        key: &str,
        body: &Value,
        now: &str,
    ) -> Result<Option<u64>> {
        let canonical = canonical_json(body);
        let hash = content_hash(&canonical);
        let existing: Option<(i64, bool, String)> = self
            .db
            .query_row(
                "SELECT version, deleted, body_hash FROM records WHERE kind = ?1 AND key = ?2",
                params![kind, key],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .optional()?;
        if let Some((_, false, ref stored)) = existing
            && *stored == hash
        {
            return Ok(None);
        }
        let version = existing.map_or(1, |(version, ..)| version + 1);
        let sort_key = self.sort_key(kind, key, body, now)?;
        let tx = self.db.unchecked_transaction()?;
        let seq = self.next_seq()?;
        tx.execute(
            "INSERT INTO records (kind, key, version, seq, deleted, sort_key, body, body_hash) \
             VALUES (?1, ?2, ?3, ?4, 0, ?5, ?6, ?7) \
             ON CONFLICT(kind, key) DO UPDATE SET version = excluded.version, seq = excluded.seq, \
             deleted = 0, sort_key = excluded.sort_key, body = excluded.body, body_hash = excluded.body_hash",
            params![kind, key, version, seq as i64, sort_key, canonical, hash],
        )?;
        tx.commit()?;
        Ok(Some(seq))
    }

    /// `sortKey` (records.md): a meeting's `startedAt`, a day's date, a
    /// transcript its meeting's `startedAt`, everything else the publish time.
    fn sort_key(&self, kind: &str, key: &str, body: &Value, now: &str) -> Result<String> {
        let derived = match kind {
            MEETING => str_field(body, "startedAt").map(str::to_owned),
            DAY => Some(str_field(body, "date").unwrap_or(key).to_owned()),
            TRANSCRIPT => {
                let meeting_id = str_field(body, "meetingId").unwrap_or(key);
                let meeting: Option<String> = self
                    .db
                    .query_row(
                        "SELECT body FROM records WHERE kind = ?1 AND key = ?2 AND deleted = 0",
                        params![MEETING, meeting_id],
                        |row| row.get(0),
                    )
                    .optional()?;
                meeting
                    .and_then(|body| serde_json::from_str::<Value>(&body).ok())
                    .and_then(|body| str_field(&body, "startedAt").map(str::to_owned))
            }
            _ => None,
        };
        Ok(derived.unwrap_or_else(|| now.to_owned()))
    }

    /// Replaces a live record with a tombstone. Returns the new seq, or
    /// `None` when there was nothing to remove.
    pub fn remove(&mut self, kind: &str, key: &str) -> Result<Option<u64>> {
        let version: Option<i64> = self
            .db
            .query_row(
                "SELECT version FROM records WHERE kind = ?1 AND key = ?2 AND deleted = 0",
                params![kind, key],
                |row| row.get(0),
            )
            .optional()?;
        let Some(version) = version else {
            return Ok(None);
        };
        let empty = canonical_json(&Value::Object(Default::default()));
        let tx = self.db.unchecked_transaction()?;
        let seq = self.next_seq()?;
        tx.execute(
            "UPDATE records SET version = ?3, seq = ?4, deleted = 1, body = ?5, body_hash = ?6 \
             WHERE kind = ?1 AND key = ?2",
            params![
                kind,
                key,
                version + 1,
                seq as i64,
                empty,
                content_hash(&empty)
            ],
        )?;
        tx.commit()?;
        Ok(Some(seq))
    }

    pub fn record_keys(&self, kind: &str) -> Result<Vec<String>> {
        let mut statement = self
            .db
            .prepare("SELECT key FROM records WHERE kind = ?1 AND deleted = 0 ORDER BY key")?;
        let keys = statement
            .query_map([kind], |row| row.get(0))?
            .collect::<rusqlite::Result<Vec<String>>>()?;
        Ok(keys)
    }

    pub fn manifest(&self) -> Result<Option<Value>> {
        Ok(self
            .envelope(MANIFEST, MANIFEST_KEY)?
            .filter(|envelope| !envelope.deleted)
            .map(|envelope| envelope.body))
    }

    /// Records with `after < seq <= upto`, newest first by `sortKey`; a
    /// meeting before its transcript on equal keys.
    pub fn changed_keys(&self, after: u64, upto: u64) -> Result<Vec<(String, String)>> {
        let mut statement = self
            .db
            .prepare("SELECT kind, key, sort_key, seq FROM records WHERE seq > ?1 AND seq <= ?2")?;
        let mut rows = statement
            .query_map(params![after as i64, upto as i64], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, i64>(3)?,
                ))
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        rows.sort_by(|a, b| {
            b.2.cmp(&a.2)
                .then_with(|| records::kind_rank(&a.0).cmp(&records::kind_rank(&b.0)))
                .then_with(|| b.3.cmp(&a.3))
        });
        Ok(rows
            .into_iter()
            .map(|(kind, key, ..)| (kind, key))
            .collect())
    }

    pub fn envelope(&self, kind: &str, key: &str) -> Result<Option<Envelope>> {
        let row: Option<(i64, i64, bool, String, String)> = self
            .db
            .query_row(
                "SELECT version, seq, deleted, sort_key, body FROM records WHERE kind = ?1 AND key = ?2",
                params![kind, key],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?, row.get(4)?)),
            )
            .optional()?;
        Ok(row.map(|(version, seq, deleted, sort_key, body)| Envelope {
            kind: kind.to_owned(),
            key: key.to_owned(),
            version: version as u64,
            seq: seq as u64,
            deleted,
            sort_key,
            body: serde_json::from_str(&body).unwrap_or_else(|_| Value::Object(Default::default())),
        }))
    }

    pub fn devices(&self) -> Result<Vec<PairedDevice>> {
        let mut statement = self.db.prepare(
            "SELECT device_id, name, platform, paired_at, last_seen_at, last_address FROM devices \
             ORDER BY paired_at, device_id",
        )?;
        let devices = statement
            .query_map([], |row| {
                Ok(PairedDevice {
                    device_id: row.get(0)?,
                    name: row.get(1)?,
                    platform: row.get(2)?,
                    paired_at: row.get(3)?,
                    last_seen_at: row.get(4)?,
                    last_address: row.get(5)?,
                })
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        Ok(devices)
    }

    pub fn device_by_key(&self, public_key: &[u8]) -> Result<Option<DeviceRow>> {
        Ok(self
            .db
            .query_row(
                "SELECT device_id FROM devices WHERE public_key = ?1",
                [public_key],
                |row| {
                    Ok(DeviceRow {
                        device_id: row.get(0)?,
                    })
                },
            )
            .optional()?)
    }

    pub fn is_revoked(&self, public_key: &[u8]) -> Result<bool> {
        Ok(self
            .db
            .query_row(
                "SELECT 1 FROM revoked_keys WHERE public_key = ?1",
                [public_key],
                |_| Ok(()),
            )
            .optional()?
            .is_some())
    }

    /// Stores a newly paired device. A device that pairs again replaces its
    /// old entry, and its key is no longer revoked.
    pub fn add_device(
        &mut self,
        device_id: &str,
        name: &str,
        platform: &str,
        public_key: &[u8],
        now: &str,
    ) -> Result<()> {
        let tx = self.db.unchecked_transaction()?;
        tx.execute(
            "DELETE FROM devices WHERE device_id = ?1 OR public_key = ?2",
            params![device_id, public_key],
        )?;
        tx.execute(
            "INSERT INTO devices (device_id, name, platform, public_key, paired_at) VALUES (?1, ?2, ?3, ?4, ?5)",
            params![device_id, name, platform, public_key, now],
        )?;
        tx.execute(
            "DELETE FROM revoked_keys WHERE public_key = ?1",
            [public_key],
        )?;
        tx.commit()?;
        Ok(())
    }

    /// Forgets a device and remembers its key as revoked, so a later session
    /// from it is told to erase its copy. Returns whether it existed.
    pub fn remove_device(&mut self, device_id: &str, now: &str) -> Result<bool> {
        let key: Option<Vec<u8>> = self
            .db
            .query_row(
                "SELECT public_key FROM devices WHERE device_id = ?1",
                [device_id],
                |row| row.get(0),
            )
            .optional()?;
        let Some(key) = key else {
            return Ok(false);
        };
        let tx = self.db.unchecked_transaction()?;
        tx.execute("DELETE FROM devices WHERE device_id = ?1", [device_id])?;
        tx.execute(
            "INSERT OR REPLACE INTO revoked_keys (public_key, device_id, revoked_at) VALUES (?1, ?2, ?3)",
            params![key, device_id, now],
        )?;
        tx.commit()?;
        Ok(true)
    }

    pub fn touch_device(&self, device_id: &str, now: &str, address: Option<&str>) -> Result<()> {
        self.db.execute(
            "UPDATE devices SET last_seen_at = ?2, last_address = COALESCE(?3, last_address) WHERE device_id = ?1",
            params![device_id, now, address],
        )?;
        Ok(())
    }
}
