//! Recent dictations (`DictationHistory.swift`): the latest results, so a
//! dictation left on the clipboard can be copied again after the next copy
//! replaced it, even after a crash, a power cut or a restart.
//!
//! # File
//!
//! `<root>/recent-dictations.json.enc` is JSON sealed with AES-256-GCM as
//! `nonce (12 bytes) ‖ ciphertext ‖ tag (16 bytes)`, like screen images. The
//! key is created per install and kept in the system credential store. A Mac
//! seals the same file name with its own Keychain key, so neither app reads
//! the other's: it reads as empty and the next save replaces it. Writes are
//! owner-only on Unix and reach the drive before they replace the old file.

use std::fs;
use std::io::Write as _;
use std::path::{Path, PathBuf};

use aes_gcm::aead::{Aead as _, AeadCore as _, KeyInit as _, OsRng};
use aes_gcm::{Aes256Gcm, Key, Nonce};
use anyhow::{Context as _, Result};
use chrono::{DateTime, Duration, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

pub const FILE_NAME: &str = "recent-dictations.json.enc";
/// How many results are kept.
pub const LIMIT: usize = 10;
/// How long a result is kept.
pub const MAXIMUM_AGE_DAYS: i64 = 7;
pub const KEY_BYTES: usize = 32;
const NONCE_BYTES: usize = 12;

/// Where a dictation's text went.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Outcome {
    /// Typed or pasted into the focused app.
    Inserted,
    /// Left on the clipboard instead.
    Copied,
    /// Shown in LokalBot only.
    Shown,
    /// Transcribed, but Compose failed, so nothing was delivered.
    NotInserted,
}

impl Outcome {
    /// The catalog key for the outcome's label.
    pub fn label(self) -> &'static str {
        match self {
            Self::Inserted => "Pasted",
            Self::Copied => "Copied to the clipboard",
            Self::Shown => "Shown in LokalBot",
            Self::NotInserted => "Not inserted",
        }
    }
}

/// One finished dictation.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Entry {
    pub id: Uuid,
    pub text: String,
    pub date: DateTime<Utc>,
    pub outcome: Outcome,
    /// The app dictation started in, when known.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub app_name: Option<String>,
}

impl Entry {
    /// The text on one line.
    pub fn preview(&self) -> String {
        self.text
            .lines()
            .map(str::trim)
            .filter(|line| !line.is_empty())
            .collect::<Vec<_>>()
            .join(" ")
    }
}

/// The latest dictations, newest first: at most [`LIMIT`], none older than
/// [`MAXIMUM_AGE_DAYS`].
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct DictationHistory {
    entries: Vec<Entry>,
}

impl DictationHistory {
    pub fn new(mut entries: Vec<Entry>, now: DateTime<Utc>) -> Self {
        entries.retain(|entry| is_fresh(entry, now));
        entries.sort_by_key(|entry| std::cmp::Reverse(entry.date));
        entries.truncate(LIMIT);
        Self { entries }
    }

    pub fn entries(&self) -> &[Entry] {
        &self.entries
    }

    /// The newest one, or the one with `id`.
    pub fn find(&self, id: Option<Uuid>) -> Option<&Entry> {
        match id {
            Some(id) => self.entries.iter().find(|entry| entry.id == id),
            None => self.entries.first(),
        }
    }

    /// Adds a result at the top. The same words again (a retry) move to the
    /// top instead of repeating; blank text is not kept.
    pub fn record(
        &mut self,
        text: &str,
        outcome: Outcome,
        app_name: Option<String>,
        now: DateTime<Utc>,
    ) -> bool {
        if text.trim().is_empty() {
            return false;
        }
        self.entries
            .retain(|entry| entry.text != text && is_fresh(entry, now));
        self.entries.insert(
            0,
            Entry {
                id: Uuid::new_v4(),
                text: text.to_string(),
                date: now,
                outcome,
                app_name,
            },
        );
        self.entries.truncate(LIMIT);
        true
    }

    pub fn clear(&mut self) {
        self.entries.clear();
    }
}

fn is_fresh(entry: &Entry, now: DateTime<Utc>) -> bool {
    now.signed_duration_since(entry.date) < Duration::days(MAXIMUM_AGE_DAYS)
}

/// The file under the library root.
pub fn path(root: &Path) -> PathBuf {
    root.join(FILE_NAME)
}

#[derive(Serialize)]
struct Saving<'a> {
    version: u32,
    entries: &'a [Entry],
}

#[derive(Deserialize)]
struct Saved {
    entries: Vec<Entry>,
}

pub fn seal(key: &[u8; KEY_BYTES], entries: &[Entry]) -> Result<Vec<u8>> {
    let json = serde_json::to_vec(&Saving {
        version: 1,
        entries,
    })?;
    let cipher = Aes256Gcm::new(Key::<Aes256Gcm>::from_slice(key));
    let nonce = Aes256Gcm::generate_nonce(&mut OsRng);
    let sealed = cipher
        .encrypt(&nonce, json.as_slice())
        .map_err(|_| anyhow::anyhow!("could not encrypt the recent dictations"))?;
    let mut out = Vec::with_capacity(NONCE_BYTES + sealed.len());
    out.extend_from_slice(&nonce);
    out.extend_from_slice(&sealed);
    Ok(out)
}

/// `None` for another key, a damaged file or one this version can't read.
pub fn open(key: &[u8; KEY_BYTES], sealed: &[u8]) -> Option<Vec<Entry>> {
    if sealed.len() < NONCE_BYTES {
        return None;
    }
    let (nonce, body) = sealed.split_at(NONCE_BYTES);
    let cipher = Aes256Gcm::new(Key::<Aes256Gcm>::from_slice(key));
    let json = cipher.decrypt(Nonce::from_slice(nonce), body).ok()?;
    Some(serde_json::from_slice::<Saved>(&json).ok()?.entries)
}

/// What was saved. A missing, damaged or foreign file reads as empty, and
/// expired results leave the file too, not just the list.
pub fn load(path: &Path, key: &[u8; KEY_BYTES], now: DateTime<Utc>) -> DictationHistory {
    let saved = fs::read(path)
        .ok()
        .and_then(|sealed| open(key, &sealed))
        .unwrap_or_default();
    let count = saved.len();
    let history = DictationHistory::new(saved, now);
    if history.entries.len() != count
        && let Err(err) = save(path, key, history.entries())
    {
        log::warn!("could not drop expired recent dictations: {err:#}");
    }
    history
}

/// Replaces the file with `entries`; none deletes it. The new version is
/// written to a temporary file, flushed to the drive and renamed over the old
/// one, so a power cut leaves one whole version.
pub fn save(path: &Path, key: &[u8; KEY_BYTES], entries: &[Entry]) -> Result<()> {
    if entries.is_empty() {
        return delete(path);
    }
    let sealed = seal(key, entries)?;
    write_private(path, &sealed).with_context(|| format!("writing {}", path.display()))
}

pub fn delete(path: &Path) -> Result<()> {
    match fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(err) => Err(err).with_context(|| format!("deleting {}", path.display())),
    }
}

fn write_private(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    let dir = path.parent().unwrap_or_else(|| Path::new("."));
    fs::create_dir_all(dir)?;
    let tmp = dir.join(format!(".{FILE_NAME}.{}.tmp", Uuid::new_v4().simple()));
    let result = replace_with(&tmp, path, bytes);
    if result.is_err() {
        let _ = fs::remove_file(&tmp);
    }
    result
}

fn replace_with(tmp: &Path, path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    let mut options = fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt as _;
        options.mode(0o600);
    }
    let mut file = options.open(tmp)?;
    file.write_all(bytes)?;
    file.sync_all()?;
    drop(file);
    fs::rename(tmp, path)?;
    // The rename reaches the drive once the folder is flushed too.
    #[cfg(unix)]
    {
        if let Some(dir) = path.parent()
            && let Ok(dir) = fs::File::open(dir)
        {
            let _ = dir.sync_all();
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    const KEY: [u8; KEY_BYTES] = [7; KEY_BYTES];

    fn entry(text: &str, date: DateTime<Utc>) -> Entry {
        Entry {
            id: Uuid::new_v4(),
            text: text.into(),
            date,
            outcome: Outcome::Copied,
            app_name: None,
        }
    }

    #[test]
    fn keeps_the_newest_first_up_to_the_limit() {
        let now = Utc::now();
        let mut history = DictationHistory::default();
        for index in 1..=LIMIT + 3 {
            history.record(&format!("Dictation {index}"), Outcome::Copied, None, now);
        }
        assert_eq!(history.entries().len(), LIMIT);
        assert_eq!(
            history.entries()[0].text,
            format!("Dictation {}", LIMIT + 3)
        );
        assert_eq!(history.entries()[LIMIT - 1].text, "Dictation 4");
    }

    #[test]
    fn repeated_text_moves_up_and_blank_text_is_not_kept() {
        let now = Utc::now();
        let mut history = DictationHistory::default();
        history.record("First", Outcome::NotInserted, None, now);
        history.record("Second", Outcome::Inserted, None, now);
        history.record("First", Outcome::Copied, Some("Terminal".into()), now);
        assert!(!history.record(" \n ", Outcome::Copied, None, now));
        let texts: Vec<_> = history.entries().iter().map(|e| e.text.as_str()).collect();
        assert_eq!(texts, ["First", "Second"]);
        assert_eq!(history.entries()[0].outcome, Outcome::Copied);
        assert_eq!(history.entries()[0].app_name.as_deref(), Some("Terminal"));
        assert_eq!(history.find(None).map(|e| e.text.as_str()), Some("First"));
        let second = history.entries()[1].id;
        assert_eq!(
            history.find(Some(second)).map(|e| e.text.as_str()),
            Some("Second")
        );
    }

    #[test]
    fn preview_is_one_line() {
        let now = Utc::now();
        assert_eq!(
            entry("Line one\n\n  line two ", now).preview(),
            "Line one line two"
        );
    }

    #[test]
    fn saved_dictations_survive_a_restart_sealed_and_private() {
        let dir = tempfile::tempdir().unwrap();
        let path = path(dir.path());
        let now = Utc::now();
        let mut history = DictationHistory::default();
        history.record("Check why the sync job retries", Outcome::Copied, None, now);
        history.record(
            "Thanks, I'll send it",
            Outcome::Inserted,
            Some("Slack".into()),
            now,
        );
        save(&path, &KEY, history.entries()).unwrap();

        let bytes = fs::read(&path).unwrap();
        assert!(
            !bytes.windows(8).any(|w| w == b"sync job"),
            "saved in plain text"
        );
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt as _;
            assert_eq!(
                fs::metadata(&path).unwrap().permissions().mode() & 0o777,
                0o600
            );
        }
        let files: Vec<_> = fs::read_dir(dir.path())
            .unwrap()
            .map(|e| e.unwrap().file_name())
            .collect();
        assert_eq!(files, [FILE_NAME]);
        assert_eq!(load(&path, &KEY, now), history);
    }

    #[test]
    fn another_key_or_a_damaged_file_reads_as_empty() {
        let dir = tempfile::tempdir().unwrap();
        let path = path(dir.path());
        let now = Utc::now();
        save(&path, &KEY, &[entry("Kept", now)]).unwrap();
        assert!(load(&path, &[8; KEY_BYTES], now).entries().is_empty());
        fs::write(&path, b"not sealed").unwrap();
        assert!(load(&path, &KEY, now).entries().is_empty());
        assert!(
            load(&dir.path().join("missing"), &KEY, now)
                .entries()
                .is_empty()
        );
    }

    #[test]
    fn expired_results_leave_the_file_and_an_empty_list_deletes_it() {
        let dir = tempfile::tempdir().unwrap();
        let path = path(dir.path());
        let now = Utc::now();
        let old = entry(
            "Old",
            now - Duration::days(MAXIMUM_AGE_DAYS) - Duration::minutes(1),
        );
        let recent = entry("Recent", now - Duration::minutes(1));
        save(&path, &KEY, &[recent.clone(), old.clone()]).unwrap();

        assert_eq!(
            load(&path, &KEY, now).entries(),
            std::slice::from_ref(&recent)
        );
        // Read as of a time when the old one was still fresh: it is gone from the file.
        assert_eq!(load(&path, &KEY, old.date).entries(), [recent]);

        assert!(
            load(&path, &KEY, now + Duration::days(MAXIMUM_AGE_DAYS))
                .entries()
                .is_empty()
        );
        assert!(!path.exists());
        delete(&path).unwrap();
    }
}
