//! What the person dictated into other apps, kept only for the overnight learning
//! pass (Learn from my dictation, off by default). Raw spoken words only, never
//! Compose's drafts, with card numbers and IBANs redacted. Sealed with the
//! `chat-key` in `memory/dictation-for-learning.json.enc`. Each entry goes once
//! the pass has read its day and never lasts more than two days; turning the
//! setting off deletes the file (`DictationLearningLog`).

use std::fs;
use std::path::PathBuf;

use anyhow::Result;
use chrono::{DateTime, Duration, NaiveDate, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::ids::uuid_upper_serde;
use crate::library::{Library, write_atomic};
use crate::sealed;
use crate::text::{redact, sanitize};
use crate::time::{iso_seconds, local_day, local_day_bounds};

pub const FILE_NAME: &str = "dictation-for-learning.json.enc";
const MAXIMUM_AGE_DAYS: i64 = 2;
const MAXIMUM_ENTRIES: usize = 200;
const MAXIMUM_ENTRY_CHARACTERS: usize = 1_000;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Entry {
    #[serde(with = "uuid_upper_serde")]
    pub id: Uuid,
    pub text: String,
    pub app_name: String,
    #[serde(with = "iso_seconds")]
    pub dictated_at: DateTime<Utc>,
}

#[derive(Serialize, Deserialize)]
struct Contents {
    #[serde(default = "one")]
    version: u32,
    #[serde(default)]
    entries: Vec<Entry>,
}

fn one() -> u32 {
    1
}

pub struct DictationLog<'a> {
    library: &'a Library,
    now: DateTime<Utc>,
}

impl Library {
    pub fn dictation_log(&self) -> DictationLog<'_> {
        DictationLog {
            library: self,
            now: Utc::now(),
        }
    }
}

impl DictationLog<'_> {
    #[cfg(test)]
    pub(crate) fn at(mut self, now: DateTime<Utc>) -> Self {
        self.now = now;
        self
    }

    fn path(&self) -> PathBuf {
        self.library.paths().root().join("memory").join(FILE_NAME)
    }

    /// Adds one dictation, dropping expired entries and the oldest past the cap.
    pub fn append(&self, text: &str, app_name: &str) -> Result<()> {
        let clean = sanitize(&redact(text), Some(MAXIMUM_ENTRY_CHARACTERS));
        if clean.is_empty() {
            return Ok(());
        }
        let mut entries = self.current();
        entries.push(Entry {
            id: Uuid::new_v4(),
            text: clean,
            app_name: app_name.to_string(),
            dictated_at: self.now,
        });
        let start = entries.len().saturating_sub(MAXIMUM_ENTRIES);
        self.save(&entries[start..])
    }

    /// Unexpired entries dictated on `day`, oldest first.
    pub fn entries_on(&self, day: NaiveDate) -> Vec<Entry> {
        self.current()
            .into_iter()
            .filter(|entry| local_day(entry.dictated_at) == day)
            .collect()
    }

    /// After the learning pass for `day`: drops that day and everything before.
    pub fn remove_through(&self, day: NaiveDate) -> Result<()> {
        let (_, end) = local_day_bounds(day);
        let kept: Vec<Entry> = self
            .current()
            .into_iter()
            .filter(|entry| entry.dictated_at >= end)
            .collect();
        self.save(&kept)
    }

    /// Drops expired entries; deletes the file when none remain.
    pub fn prune(&self) -> Result<()> {
        if !self.path().exists() {
            return Ok(());
        }
        let current = self.current();
        self.save(&current)
    }

    pub fn delete_all(&self) -> Result<()> {
        match fs::remove_file(self.path()) {
            Err(err) if err.kind() != std::io::ErrorKind::NotFound => Err(err.into()),
            _ => Ok(()),
        }
    }

    /// Unexpired entries. An unreadable file reads as empty: it is a short-lived
    /// buffer, and the next save replaces it.
    fn current(&self) -> Vec<Entry> {
        let Some(contents) = fs::read(self.path()).ok().and_then(|bytes| {
            let key = self.library.chat_key(false).ok()?;
            let clear = sealed::open(&key, &bytes)?;
            serde_json::from_slice::<Contents>(&clear).ok()
        }) else {
            return Vec::new();
        };
        let oldest = self.now - Duration::days(MAXIMUM_AGE_DAYS);
        let mut entries: Vec<Entry> = contents
            .entries
            .into_iter()
            .filter(|entry| entry.dictated_at >= oldest)
            .collect();
        entries.sort_by_key(|entry| entry.dictated_at);
        entries
    }

    fn save(&self, entries: &[Entry]) -> Result<()> {
        if entries.is_empty() {
            return self.delete_all();
        }
        let key = self.library.chat_key(true)?;
        let bytes = serde_json::to_vec(&Contents {
            version: 1,
            entries: entries.to_vec(),
        })?;
        write_atomic(&self.path(), &sealed::seal(&key, &bytes)?)?;
        Ok(())
    }
}
