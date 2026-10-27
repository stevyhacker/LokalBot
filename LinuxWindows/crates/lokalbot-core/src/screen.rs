//! Writing screen context: capture rows (`ActivityStore.insertScreenshot`,
//! `deleteScreenshots`), the perceptual hash that groups near-identical
//! frames (`ScreenPerceptualHash`), and the encrypted image files
//! (`ScreenshotService.captureFileURL`, `encryptionKey`).
//!
//! # Image files
//!
//! Each kept frame is `activity/<YYYY-MM-DD>/shots/<epoch ms>-<uuid>.jpg.enc`
//! under the library root, with the day in UTC as on macOS. The file is a
//! JPEG sealed with AES-256-GCM and no associated data, laid out as
//! `nonce (12 bytes) ‖ ciphertext ‖ tag (16 bytes)`: the layout of CryptoKit's
//! `AES.GCM.SealedBox.combined`, which the Mac app uses for its `.heic.enc`
//! files. The 32-byte key is created once per install and kept in the system
//! credential store (account `screenshot-key`), never in the library. A Mac
//! keeps its own key in its Keychain, so frames captured there cannot be
//! opened here (and the other way round); their text is unaffected.
//!
//! The `screenshots.path` column holds the file's absolute path, as macOS
//! writes it, or is empty for text-only moments and after the pixels expire.

use std::path::{Component, Path, PathBuf};

use aes_gcm::aead::{Aead as _, AeadCore as _, KeyInit as _, OsRng};
use aes_gcm::{Aes256Gcm, Key, Nonce};
use anyhow::{Context as _, Result, bail};
use chrono::{DateTime, Utc};
use rusqlite::{OptionalExtension as _, params};
use uuid::Uuid;

use crate::library::Library;
use crate::time::to_epoch;
use crate::timeline::table_exists;

/// Length of the per-install image key.
pub const IMAGE_KEY_BYTES: usize = 32;
const NONCE_BYTES: usize = 12;
const TAG_BYTES: usize = 16;
/// File suffix of frames written here (`.heic.enc` on macOS).
pub const IMAGE_FILE_SUFFIX: &str = ".jpg.enc";

/// Automatic captures whose perceptual hashes differ in at most this many
/// bits belong to one scene (`ScreenPerceptualHash.defaultDistanceThreshold`).
pub const NEAR_DUPLICATE_DISTANCE: u32 = 6;

/// Why an image file could not be opened.
#[derive(Debug, thiserror::Error)]
pub enum ImageError {
    #[error("the image file is missing")]
    Missing,
    #[error("the image was sealed with another key, such as a Mac's Keychain key")]
    OtherKey,
    #[error("could not read the image file: {0}")]
    Io(#[from] std::io::Error),
}

/// A new random image key.
pub fn new_image_key() -> [u8; IMAGE_KEY_BYTES] {
    Aes256Gcm::generate_key(OsRng).into()
}

/// Seals `plaintext` as `nonce ‖ ciphertext ‖ tag` with a fresh random nonce.
pub fn seal_image(key: &[u8; IMAGE_KEY_BYTES], plaintext: &[u8]) -> Result<Vec<u8>> {
    let cipher = Aes256Gcm::new(Key::<Aes256Gcm>::from_slice(key));
    let nonce = Aes256Gcm::generate_nonce(&mut OsRng);
    let sealed = cipher
        .encrypt(&nonce, plaintext)
        .map_err(|_| anyhow::anyhow!("could not encrypt the screen image"))?;
    let mut out = Vec::with_capacity(NONCE_BYTES + sealed.len());
    out.extend_from_slice(&nonce);
    out.extend_from_slice(&sealed);
    Ok(out)
}

/// Opens bytes written by [`seal_image`]. Any other key, a truncated file
/// or a changed byte fails authentication.
pub fn open_image(key: &[u8; IMAGE_KEY_BYTES], sealed: &[u8]) -> Result<Vec<u8>, ImageError> {
    if sealed.len() < NONCE_BYTES + TAG_BYTES {
        return Err(ImageError::OtherKey);
    }
    let (nonce, body) = sealed.split_at(NONCE_BYTES);
    let cipher = Aes256Gcm::new(Key::<Aes256Gcm>::from_slice(key));
    cipher
        .decrypt(Nonce::from_slice(nonce), body)
        .map_err(|_| ImageError::OtherKey)
}

/// Reads and opens one image file.
pub fn read_image(key: &[u8; IMAGE_KEY_BYTES], path: &Path) -> Result<Vec<u8>, ImageError> {
    let sealed = match std::fs::read(path) {
        Ok(bytes) => bytes,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Err(ImageError::Missing),
        Err(err) => return Err(err.into()),
    };
    open_image(key, &sealed)
}

/// Where a frame taken at `ts` is stored (`ScreenshotService.captureFileURL`).
pub fn capture_file_path(root: &Path, ts: DateTime<Utc>, id: Uuid) -> PathBuf {
    root.join("activity")
        .join(ts.format("%Y-%m-%d").to_string())
        .join("shots")
        .join(format!(
            "{}-{}{IMAGE_FILE_SUFFIX}",
            ts.timestamp_millis(),
            id.hyphenated()
        ))
}

/// The file behind a stored `screenshots.path`, inside `root`. Paths written
/// on another computer (an absolute Mac or Windows path) are found again
/// under this library's own `activity` folder. `None` for text-only moments
/// and for anything that would leave the library.
pub fn resolve_capture_path(root: &Path, stored: &str) -> Option<PathBuf> {
    let stored = stored.trim();
    if stored.is_empty() {
        return None;
    }
    let path = Path::new(stored);
    if path.is_absolute() && path.starts_with(root) {
        let inside = path.strip_prefix(root).ok()?;
        return only_normal(inside).then(|| path.to_path_buf());
    }
    let normalized = stored.replace('\\', "/");
    let relative = if let Some(start) = normalized.rfind("/activity/") {
        &normalized[start + 1..]
    } else if normalized.starts_with("activity/") {
        normalized.as_str()
    } else {
        return None;
    };
    let relative = Path::new(relative);
    only_normal(relative).then(|| {
        let mut resolved = root.to_path_buf();
        resolved.extend(relative.components());
        resolved
    })
}

fn only_normal(path: &Path) -> bool {
    path.components().count() > 0
        && path
            .components()
            .all(|component| matches!(component, Component::Normal(_)))
}

// ------------------------------------------------------------ perceptual hash

/// 64-bit difference hash of a 9×8 grayscale reduction (`ScreenPerceptualHash`).
/// It stays stable across cursor blinks and small animations, so frames of
/// one scene share a similarity group. `rgba` holds `width × height` pixels.
pub fn perceptual_hash(rgba: &[u8], width: u32, height: u32) -> u64 {
    const COLUMNS: usize = 9;
    const ROWS: usize = 8;
    let (width, height) = (width as usize, height as usize);
    if width == 0 || height == 0 || rgba.len() < width * height * 4 {
        return 0;
    }
    // Box-filter each cell, like drawing into a 9×8 context.
    let mut cells = [0f64; COLUMNS * ROWS];
    for (row, cell_row) in cells.chunks_mut(COLUMNS).enumerate() {
        let y0 = row * height / ROWS;
        let y1 = ((row + 1) * height / ROWS).max(y0 + 1).min(height);
        for (column, cell) in cell_row.iter_mut().enumerate() {
            let x0 = column * width / COLUMNS;
            let x1 = ((column + 1) * width / COLUMNS).max(x0 + 1).min(width);
            let mut sum = 0u64;
            let mut count = 0u64;
            // Sample at most 16×16 points per cell: plenty for a 72-cell hash.
            let y_step = ((y1 - y0) / 16).max(1);
            let x_step = ((x1 - x0) / 16).max(1);
            for y in (y0..y1).step_by(y_step) {
                for x in (x0..x1).step_by(x_step) {
                    let i = (y * width + x) * 4;
                    let (r, g, b) = (
                        u64::from(rgba[i]),
                        u64::from(rgba[i + 1]),
                        u64::from(rgba[i + 2]),
                    );
                    sum += (299 * r + 587 * g + 114 * b) / 1000;
                    count += 1;
                }
            }
            *cell = sum as f64 / count.max(1) as f64;
        }
    }
    let mut hash = 0u64;
    let mut bit = 1u64;
    for row in 0..ROWS {
        for column in 0..COLUMNS - 1 {
            if cells[row * COLUMNS + column] > cells[row * COLUMNS + column + 1] {
                hash |= bit;
            }
            bit <<= 1;
        }
    }
    hash
}

pub fn hamming_distance(a: u64, b: u64) -> u32 {
    (a ^ b).count_ones()
}

pub fn is_near_duplicate(a: u64, b: u64) -> bool {
    hamming_distance(a, b) <= NEAR_DUPLICATE_DISTANCE
}

/// `%016llx`, the stored form.
pub fn encode_perceptual_hash(hash: u64) -> String {
    format!("{hash:016x}")
}

pub fn decode_perceptual_hash(value: &str) -> Option<u64> {
    u64::from_str_radix(value, 16).ok()
}

// ------------------------------------------------------------------ writing

/// One capture to store. `path` is the sealed image file, empty when only
/// text was kept; `text` is already redacted and empty when none was read.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ScreenCapture {
    pub ts: DateTime<Utc>,
    pub app: String,
    pub window_title: String,
    /// `app_switch`, `window_change`, `click`, `typing_pause`, `scroll_settled`,
    /// `clipboard_change`, `interval` or `manual` (`ScreenCaptureTrigger`).
    pub trigger: String,
    pub path: String,
    pub text: String,
    /// `accessibility`, `ocr` or `hybrid`, with `_redacted` when something was redacted.
    pub text_source: String,
    /// Set for frames, so near-identical ones share a similarity group.
    pub perceptual_hash: Option<u64>,
    pub source_url: String,
    pub document_name: String,
    pub meeting_id: Option<Uuid>,
    pub privacy_redactions: i64,
}

impl Library {
    /// Stores one capture row and its searchable text in one transaction and
    /// returns its id (`ActivityStore.insertScreenshot`): a `screenshots` row,
    /// an `ocr_fts` row and its `ocr_metadata` index entry when there is text,
    /// and the similarity group from the previous frame's perceptual hash.
    pub fn insert_screen_capture(&self, capture: &ScreenCapture) -> Result<i64> {
        if self.is_read_only() {
            bail!("the library is open read-only");
        }
        let ts = to_epoch(capture.ts);
        let trigger = if capture.trigger.is_empty() {
            "interval"
        } else {
            capture.trigger.as_str()
        };
        let text_source = if capture.text_source.is_empty() {
            "ocr"
        } else {
            capture.text_source.as_str()
        };
        self.with_db(|db| {
            let tx = db.unchecked_transaction()?;
            tx.execute(
                "INSERT INTO screenshots (ts, path, app, window_title, capture_trigger, perceptual_hash, \
                 source_url, document_name, meeting_id, privacy_redactions) \
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
                params![
                    ts,
                    capture.path,
                    capture.app,
                    capture.window_title,
                    trigger,
                    capture.perceptual_hash.map(encode_perceptual_hash).unwrap_or_default(),
                    capture.source_url,
                    capture.document_name,
                    capture.meeting_id.map(|id| crate::ids::uuid_upper(&id)).unwrap_or_default(),
                    capture.privacy_redactions.max(0),
                ],
            )?;
            let id = tx.last_insert_rowid();
            if id <= 0 {
                bail!("the screenshot insert did not produce a row id");
            }
            if !capture.text.is_empty() {
                tx.execute(
                    "INSERT INTO ocr_fts (text, window_title, ts, app, text_source, snapshot_id) \
                     VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                    params![capture.text, capture.window_title, ts, capture.app, text_source, id],
                )?;
                tx.execute(
                    "INSERT OR REPLACE INTO ocr_metadata (rowid, snapshot_id, ts) VALUES (?1, ?2, ?3)",
                    params![tx.last_insert_rowid(), id, ts],
                )?;
            }
            if let Some(hash) = capture.perceptual_hash {
                let group = similarity_group(&tx, id, ts, hash)?;
                tx.execute(
                    "UPDATE screenshots SET similarity_group = ?1 WHERE id = ?2",
                    params![group, id],
                )?;
            }
            tx.commit()?;
            Ok(id)
        })
    }

    /// Deletes moments with their pixels, text, bookmark and vectors
    /// (`ScreenshotService.deleteCapture`, `ActivityStore.deleteScreenshots`).
    /// Files go first: a file that cannot be removed keeps its row, so the
    /// deletion can be retried. Returns how many moments were removed.
    pub fn delete_screen_moments(&self, ids: &[i64]) -> Result<usize> {
        if self.is_read_only() {
            bail!("the library is open read-only");
        }
        let root = self.paths().root().to_path_buf();
        let mut removable = Vec::new();
        for &id in ids.iter().filter(|id| **id > 0) {
            let stored: Option<String> = self.with_db(|db| {
                if !table_exists(db, "screenshots")? {
                    return Ok(None);
                }
                Ok(db
                    .query_row("SELECT path FROM screenshots WHERE id = ?1", [id], |row| {
                        row.get(0)
                    })
                    .optional()?)
            })?;
            let Some(stored) = stored else { continue };
            if let Some(file) = resolve_capture_path(&root, &stored) {
                match std::fs::remove_file(&file) {
                    Ok(()) => {}
                    Err(err) if err.kind() == std::io::ErrorKind::NotFound => {}
                    Err(err) => {
                        return Err(err).with_context(|| {
                            format!("could not delete the screen image of moment {id}")
                        });
                    }
                }
            }
            removable.push(id);
        }
        if removable.is_empty() {
            return Ok(0);
        }
        self.with_db(|db| {
            let tx = db.unchecked_transaction()?;
            let has_metadata = table_exists(&tx, "ocr_metadata")?;
            let has_vectors = table_exists(&tx, "screen_embeddings")?;
            for &id in &removable {
                if has_metadata {
                    tx.execute(
                        "DELETE FROM ocr_fts WHERE rowid IN (SELECT rowid FROM ocr_metadata WHERE snapshot_id = ?1)",
                        [id],
                    )?;
                } else {
                    tx.execute(
                        "DELETE FROM ocr_fts WHERE CAST(snapshot_id AS INTEGER) = ?1",
                        [id],
                    )?;
                }
                tx.execute("DELETE FROM screen_bookmarks WHERE snapshot_id = ?1", [id])?;
                if has_vectors {
                    tx.execute("DELETE FROM screen_embeddings WHERE snapshot_id = ?1", [id])?;
                }
                tx.execute("DELETE FROM screenshots WHERE id = ?1", [id])?;
            }
            if has_metadata {
                tx.execute(
                    "DELETE FROM ocr_metadata WHERE rowid NOT IN (SELECT rowid FROM ocr_fts)",
                    [],
                )?;
            }
            tx.commit()?;
            Ok(removable.len())
        })
    }

    /// The image file of a stored moment, when it has one inside this library.
    pub fn screen_image_file(&self, stored_path: &str) -> Option<PathBuf> {
        resolve_capture_path(self.paths().root(), stored_path)
    }
}

/// Brings screen tables written by older Mac builds to the current shape
/// before anything is stored (`ActivityStore.migrateScreenshotColumns`,
/// `migrateOCRTable`, `backfillUnlinkedOCRRows`).
pub(crate) fn migrate(db: &rusqlite::Connection) -> Result<()> {
    if table_exists(db, "screenshots")? {
        let columns = column_names(db, "screenshots")?;
        for (name, definition) in [
            ("window_title", "TEXT NOT NULL DEFAULT ''"),
            ("capture_trigger", "TEXT NOT NULL DEFAULT 'interval'"),
            ("perceptual_hash", "TEXT NOT NULL DEFAULT ''"),
            ("similarity_group", "INTEGER NOT NULL DEFAULT 0"),
            ("source_url", "TEXT NOT NULL DEFAULT ''"),
            ("document_name", "TEXT NOT NULL DEFAULT ''"),
            ("meeting_id", "TEXT NOT NULL DEFAULT ''"),
            ("privacy_redactions", "INTEGER NOT NULL DEFAULT 0"),
        ] {
            if !columns.iter().any(|column| column == name) {
                db.execute_batch(&format!(
                    "ALTER TABLE screenshots ADD COLUMN {name} {definition}"
                ))?;
            }
        }
    }
    if !table_exists(db, "ocr_fts")? {
        return Ok(());
    }
    let columns = column_names(db, "ocr_fts")?;
    if columns.iter().any(|column| column == "snapshot_id") {
        return backfill_unlinked_text(db);
    }
    // FTS5 tables cannot add columns: rebuild a legacy (text, ts, app) table,
    // linking each row to the capture taken within a second of it.
    let tx = db.unchecked_transaction()?;
    tx.execute_batch(
        "CREATE VIRTUAL TABLE IF NOT EXISTS ocr_fts_v2 USING fts5(
            text, window_title, ts UNINDEXED, app UNINDEXED,
            text_source UNINDEXED, snapshot_id UNINDEXED,
            tokenize='unicode61 remove_diacritics 2');
         WITH ranked_candidates AS (
            SELECT legacy.rowid AS ocr_rowid, shot.id AS snapshot_id,
                   ROW_NUMBER() OVER (PARTITION BY legacy.rowid
                                      ORDER BY ABS(shot.ts - CAST(legacy.ts AS REAL)), shot.id) AS candidate_rank
            FROM ocr_fts AS legacy
            JOIN screenshots AS shot ON shot.app = legacy.app COLLATE NOCASE
             AND ABS(shot.ts - CAST(legacy.ts AS REAL)) <= 1.0)
         INSERT INTO ocr_fts_v2 (text, window_title, ts, app, text_source, snapshot_id)
            SELECT legacy.text, '', legacy.ts, legacy.app, 'ocr', COALESCE(candidate.snapshot_id, 0)
            FROM ocr_fts AS legacy
            LEFT JOIN ranked_candidates AS candidate
              ON candidate.ocr_rowid = legacy.rowid AND candidate.candidate_rank = 1;
         DROP TABLE ocr_fts;
         ALTER TABLE ocr_fts_v2 RENAME TO ocr_fts;",
    )?;
    tx.commit()?;
    Ok(())
}

/// Links text rows an earlier migration left with `snapshot_id = 0` to the
/// capture taken within a second of them.
fn backfill_unlinked_text(db: &rusqlite::Connection) -> Result<()> {
    let rows: Vec<(i64, f64, String)> = {
        let mut statement = db.prepare(
            "SELECT rowid, CAST(ts AS REAL), app FROM ocr_fts \
             WHERE CAST(snapshot_id AS INTEGER) <= 0 ORDER BY rowid",
        )?;
        statement
            .query_map([], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)))?
            .collect::<rusqlite::Result<_>>()?
    };
    if rows.is_empty() || !table_exists(db, "screenshots")? {
        return Ok(());
    }
    let has_metadata = table_exists(db, "ocr_metadata")?;
    let tx = db.unchecked_transaction()?;
    for (rowid, ts, app) in rows {
        let snapshot: Option<i64> = tx
            .query_row(
                "SELECT id FROM screenshots WHERE app = ?1 COLLATE NOCASE AND ABS(ts - ?2) <= 1.0 \
                 ORDER BY ABS(ts - ?2), id LIMIT 1",
                params![app, ts],
                |row| row.get(0),
            )
            .optional()?;
        let Some(snapshot) = snapshot else { continue };
        tx.execute(
            "UPDATE ocr_fts SET snapshot_id = ?1 WHERE rowid = ?2",
            params![snapshot, rowid],
        )?;
        if has_metadata {
            tx.execute(
                "UPDATE ocr_metadata SET snapshot_id = ?1 WHERE rowid = ?2",
                params![snapshot, rowid],
            )?;
        }
    }
    tx.commit()?;
    Ok(())
}

fn column_names(db: &rusqlite::Connection, table: &str) -> Result<Vec<String>> {
    let mut statement = db.prepare(&format!("PRAGMA table_info({table})"))?;
    let names = statement
        .query_map([], |row| row.get::<_, String>(1))?
        .collect::<rusqlite::Result<_>>()?;
    Ok(names)
}

/// The group of a new frame: the previous frame's group when its group's
/// representative is a near duplicate, else a group of its own.
fn similarity_group(db: &rusqlite::Connection, id: i64, ts: f64, hash: u64) -> Result<i64> {
    let previous: Option<(i64, String, i64)> = db
        .query_row(
            "SELECT id, perceptual_hash, similarity_group FROM screenshots \
             WHERE id != ?1 AND ts <= ?2 AND perceptual_hash != '' \
             ORDER BY ts DESC, id DESC LIMIT 1",
            params![id, ts],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .optional()?;
    let Some((previous_id, previous_hash, previous_group)) = previous else {
        return Ok(id);
    };
    let Some(previous_hash) = decode_perceptual_hash(&previous_hash) else {
        return Ok(id);
    };
    let candidate = if previous_group > 0 {
        previous_group
    } else {
        previous_id
    };
    let representative = if candidate == previous_id {
        previous_hash
    } else {
        db.query_row(
            "SELECT perceptual_hash FROM screenshots WHERE id = ?1 LIMIT 1",
            [candidate],
            |row| row.get::<_, String>(0),
        )
        .optional()?
        .and_then(|raw| decode_perceptual_hash(&raw))
        .unwrap_or(previous_hash)
    };
    Ok(if is_near_duplicate(representative, hash) {
        candidate
    } else {
        id
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::LibraryPaths;
    use crate::settings::Settings;

    fn library() -> (tempfile::TempDir, Library) {
        let dir = tempfile::tempdir().unwrap();
        let library = Library::open(LibraryPaths::new(dir.path())).unwrap();
        (dir, library)
    }

    fn capture(ts: DateTime<Utc>, text: &str, hash: Option<u64>) -> ScreenCapture {
        ScreenCapture {
            ts,
            app: "Text Editor".into(),
            window_title: "notes.txt".into(),
            trigger: "app_switch".into(),
            text: text.into(),
            text_source: "ocr".into(),
            perceptual_hash: hash,
            ..Default::default()
        }
    }

    #[test]
    fn sealed_images_open_only_with_their_key() {
        let key = new_image_key();
        let sealed = seal_image(&key, b"jpeg bytes").unwrap();
        assert_eq!(sealed.len(), NONCE_BYTES + b"jpeg bytes".len() + TAG_BYTES);
        assert_eq!(open_image(&key, &sealed).unwrap(), b"jpeg bytes");
        // Fresh nonces: the same image never seals to the same bytes.
        assert_ne!(seal_image(&key, b"jpeg bytes").unwrap(), sealed);
        assert!(matches!(
            open_image(&new_image_key(), &sealed),
            Err(ImageError::OtherKey)
        ));
        let mut tampered = sealed.clone();
        tampered[NONCE_BYTES + 2] ^= 1;
        assert!(open_image(&key, &tampered).is_err());
        assert!(open_image(&key, &sealed[..20]).is_err());
    }

    #[test]
    fn opens_a_cryptokit_style_combined_box() {
        // nonce ‖ ciphertext ‖ tag, as `AES.GCM.SealedBox.combined` lays it out.
        let key = [7u8; IMAGE_KEY_BYTES];
        let cipher = Aes256Gcm::new(Key::<Aes256Gcm>::from_slice(&key));
        let nonce = [3u8; NONCE_BYTES];
        let body = cipher
            .encrypt(Nonce::from_slice(&nonce), b"heic".as_slice())
            .unwrap();
        let combined = [nonce.as_slice(), body.as_slice()].concat();
        assert_eq!(open_image(&key, &combined).unwrap(), b"heic");
    }

    #[test]
    fn file_paths_follow_the_mac_layout() {
        let ts = DateTime::parse_from_rfc3339("2026-10-17T23:30:00.250Z")
            .unwrap()
            .with_timezone(&Utc);
        let id = Uuid::parse_str("6f9619ff-8b86-d011-b42d-00cf4fc964ff").unwrap();
        let path = capture_file_path(Path::new("/lib"), ts, id);
        assert_eq!(
            path,
            Path::new(
                "/lib/activity/2026-10-17/shots/1792279800250-6f9619ff-8b86-d011-b42d-00cf4fc964ff.jpg.enc"
            )
        );
    }

    #[test]
    fn stored_paths_resolve_inside_the_library_only() {
        let root = Path::new("/home/u/.local/share/LokalBot");
        let own = "/home/u/.local/share/LokalBot/activity/2026-10-17/shots/1-a.jpg.enc";
        assert_eq!(resolve_capture_path(root, own), Some(PathBuf::from(own)));
        // Written on a Mac: found again under this library's activity folder.
        assert_eq!(
            resolve_capture_path(
                root,
                "/Users/me/Library/Application Support/LokalBot/activity/2026-10-17/shots/2-b.heic.enc"
            ),
            Some(root.join("activity/2026-10-17/shots/2-b.heic.enc"))
        );
        assert_eq!(
            resolve_capture_path(
                root,
                r"C:\Users\me\AppData\Local\LokalBot\activity\d\shots\3.jpg.enc"
            ),
            Some(root.join("activity/d/shots/3.jpg.enc"))
        );
        assert_eq!(resolve_capture_path(root, ""), None);
        assert_eq!(resolve_capture_path(root, "/etc/passwd"), None);
        assert_eq!(
            resolve_capture_path(root, "/x/activity/../../etc/passwd"),
            None
        );
        assert_eq!(
            resolve_capture_path(root, "/home/u/.local/share/LokalBot/../secret"),
            None
        );
    }

    #[test]
    fn perceptual_hashes_group_near_identical_frames() {
        let (w, h) = (90u32, 80u32);
        let gradient = |shift: u8| -> Vec<u8> {
            (0..h)
                .flat_map(|y| {
                    (0..w).flat_map(move |x| {
                        let v = ((x * 255 / w) as u8).wrapping_add(shift) ^ ((y % 7) as u8);
                        [v, v, v, 255]
                    })
                })
                .collect()
        };
        let a = perceptual_hash(&gradient(0), w, h);
        let mut nudged = gradient(0);
        nudged[0..4].copy_from_slice(&[255, 255, 255, 255]);
        assert!(is_near_duplicate(a, perceptual_hash(&nudged, w, h)));
        let inverted: Vec<u8> = gradient(0)
            .chunks(4)
            .flat_map(|p| [255 - p[0], 255 - p[1], 255 - p[2], 255])
            .collect();
        assert!(!is_near_duplicate(a, perceptual_hash(&inverted, w, h)));
        assert_eq!(decode_perceptual_hash(&encode_perceptual_hash(a)), Some(a));
        assert_eq!(encode_perceptual_hash(0xab), "00000000000000ab");
        assert_eq!(perceptual_hash(&[], 0, 0), 0);
    }

    #[test]
    fn captures_round_trip_with_text_and_scene_groups() {
        let (_dir, library) = library();
        let now = Utc::now();
        let first = library
            .insert_screen_capture(&capture(now, "Quarterly plan draft", Some(0b1010)))
            .unwrap();
        let second = library
            .insert_screen_capture(&capture(
                now + chrono::Duration::seconds(30),
                "Quarterly plan draft v2",
                Some(0b1011),
            ))
            .unwrap();
        let third = library
            .insert_screen_capture(&capture(
                now + chrono::Duration::seconds(60),
                "Something else",
                Some(!0),
            ))
            .unwrap();
        let text_only = library
            .insert_screen_capture(&ScreenCapture {
                text_source: "accessibility_redacted".into(),
                privacy_redactions: 1,
                meeting_id: Some(Uuid::nil()),
                ..capture(
                    now + chrono::Duration::seconds(90),
                    "token=[REDACTED]",
                    None,
                )
            })
            .unwrap();

        let moment = library.screen_moment(first).unwrap().unwrap();
        assert_eq!(moment.text.as_deref(), Some("Quarterly plan draft"));
        assert_eq!(moment.capture_trigger, "app_switch");
        let groups: Vec<(i64, String, String)> = library
            .with_db(|db| {
                let mut statement = db.prepare(
                    "SELECT similarity_group, perceptual_hash, meeting_id FROM screenshots ORDER BY id",
                )?;
                let rows = statement
                    .query_map([], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)))?
                    .collect::<rusqlite::Result<Vec<_>>>()?;
                Ok(rows)
            })
            .unwrap();
        assert_eq!(groups[0].0, first);
        assert_eq!(groups[1].0, first, "a near-identical frame joins the scene");
        assert_eq!(groups[2].0, third, "a different frame starts a scene");
        assert_eq!(groups[3].0, 0, "text-only moments have no scene");
        assert_eq!(groups[0].1, "000000000000000a");
        assert_eq!(groups[3].2, "00000000-0000-0000-0000-000000000000");
        let source: String = library
            .with_db(|db| {
                Ok(db.query_row(
                    "SELECT text_source FROM ocr_fts WHERE CAST(snapshot_id AS INTEGER) = ?1",
                    [text_only],
                    |row| row.get(0),
                )?)
            })
            .unwrap();
        assert_eq!(source, "accessibility_redacted");

        let hits = library
            .search_screen_hits("quarterly", None, None, 10)
            .unwrap();
        assert_eq!(hits.len(), 1, "one result per scene");
        assert_eq!(hits[0].capture_count, 2);
        assert!(hits[0].moment.id == first || hits[0].moment.id == second);
    }

    #[test]
    fn deleting_a_moment_removes_its_file_and_rows() {
        let (dir, library) = library();
        let now = Utc::now();
        let file = capture_file_path(dir.path(), now, Uuid::new_v4());
        std::fs::create_dir_all(file.parent().unwrap()).unwrap();
        std::fs::write(&file, b"sealed").unwrap();
        let id = library
            .insert_screen_capture(&ScreenCapture {
                path: file.to_string_lossy().into_owned(),
                ..capture(now, "Launch checklist", Some(1))
            })
            .unwrap();
        library.save_moment(id, "keep").unwrap();
        assert_eq!(library.delete_screen_moments(&[id, 999]).unwrap(), 1);
        assert!(!file.exists());
        assert!(library.screen_moment(id).unwrap().is_none());
        assert!(
            library
                .search_screen("launch", None, None, 5)
                .unwrap()
                .is_empty()
        );
        let leftovers: i64 = library
            .with_db(|db| {
                Ok(db.query_row(
                    "SELECT (SELECT COUNT(*) FROM ocr_fts) + (SELECT COUNT(*) FROM ocr_metadata) \
                     + (SELECT COUNT(*) FROM screen_bookmarks)",
                    [],
                    |row| row.get(0),
                )?)
            })
            .unwrap();
        assert_eq!(leftovers, 0);
    }

    #[test]
    fn libraries_from_older_mac_builds_are_migrated_before_writing() {
        let dir = tempfile::tempdir().unwrap();
        let paths = LibraryPaths::new(dir.path());
        {
            let db = rusqlite::Connection::open(paths.database()).unwrap();
            db.execute_batch(
                "CREATE TABLE screenshots (id INTEGER PRIMARY KEY AUTOINCREMENT,
                    ts REAL NOT NULL, path TEXT NOT NULL, app TEXT NOT NULL);
                 CREATE VIRTUAL TABLE ocr_fts USING fts5(text, ts UNINDEXED, app UNINDEXED);
                 INSERT INTO screenshots (ts, path, app) VALUES (1000.0, '', 'Safari');
                 INSERT INTO ocr_fts (text, ts, app) VALUES ('legacy invoice text', 1000.4, 'safari');",
            )
            .unwrap();
        }
        let library = Library::open(paths).unwrap();
        let moment = library.screen_moment(1).unwrap().unwrap();
        assert_eq!(moment.capture_trigger, "interval");
        assert_eq!(moment.text.as_deref(), Some("legacy invoice text"));
        let id = library
            .insert_screen_capture(&capture(Utc::now(), "fresh text", Some(5)))
            .unwrap();
        assert_eq!(
            library.screen_moment(id).unwrap().unwrap().text.as_deref(),
            Some("fresh text")
        );
        assert_eq!(
            library
                .search_screen("invoice", None, None, 5)
                .unwrap()
                .len(),
            1
        );
    }

    #[test]
    fn retention_removes_the_files_this_app_writes() {
        let (dir, library) = library();
        let now = Utc::now();
        let old = now - chrono::Duration::days(30);
        let file = capture_file_path(dir.path(), old, Uuid::new_v4());
        std::fs::create_dir_all(file.parent().unwrap()).unwrap();
        std::fs::write(&file, b"sealed").unwrap();
        let id = library
            .insert_screen_capture(&ScreenCapture {
                path: file.to_string_lossy().into_owned(),
                source_url: "https://docs.example/plan".into(),
                ..capture(old, "Old roadmap", Some(1))
            })
            .unwrap();
        let report = library.apply_retention(&Settings::default(), now).unwrap();
        assert_eq!(report.pixels_removed, 1);
        assert_eq!(report.texts_removed, 1);
        assert!(!file.exists());
        let moment = library.screen_moment(id).unwrap().unwrap();
        assert_eq!(moment.path, "");
        assert_eq!(moment.text, None);
        assert_eq!(moment.source_url, "");
    }
}
