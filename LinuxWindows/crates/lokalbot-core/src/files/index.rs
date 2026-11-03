//! The on-disk index (`IndexStore`): one SQLite file with files, their segments
//! (with float16 vectors) and an FTS5 table, in schema 5, the layout the Mac's
//! DigUpKit writes. Vectors live with everything else, so a crash can never
//! leave them out of step with the rows that describe them.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::time::Duration;

use anyhow::{Result, bail};
use rusqlite::{Connection, OpenFlags, OptionalExtension as _, Row, params, params_from_iter};

use super::{Candidate, FileKind, INDEXING_ORDER_SQL, Modality, SegmentKind, text, vector_blob};

pub const SCHEMA_VERSION: i64 = 5;
/// The main index's file in the index folder.
pub const MAIN_FILE: &str = "index.sqlite";

/// Keyword search's tokenizer. Marks count as letters, so Bengali vowel signs
/// and Arabic harakat stay inside their words.
const FTS_COLUMNS: &str = "name, body, original UNINDEXED, tokenize = \"porter unicode61 remove_diacritics 2 categories 'L* N* Co M*'\"";

/// A file as the index knows it.
#[derive(Clone, Debug, PartialEq)]
pub struct FileRecord {
    pub id: i64,
    pub path: String,
    pub kind: FileKind,
    pub size: i64,
    pub mtime: f64,
    pub inode: u64,
    pub device: u64,
    pub state: String,
    /// Why it was skipped or failed, or how far a long file has been read.
    pub detail: Option<String>,
}

const FILE_COLUMNS: &str = "id, path, kind, size, mtime, inode, device, state, detail";

fn record(row: &Row) -> rusqlite::Result<FileRecord> {
    let kind: String = row.get(2)?;
    Ok(FileRecord {
        id: row.get(0)?,
        path: row.get(1)?,
        kind: FileKind::parse(&kind).unwrap_or(FileKind::Doc),
        size: row.get(3)?,
        mtime: row.get(4)?,
        inode: row.get::<_, i64>(5)? as u64,
        device: row.get::<_, i64>(6)? as u64,
        state: row.get(7)?,
        detail: row.get(8)?,
    })
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Counts {
    pub by_kind_and_state: HashMap<String, HashMap<String, usize>>,
    pub vectors: usize,
    pub segments: usize,
    /// Long files still being read, and their pages and chunks left.
    pub unfinished: usize,
    pub left: usize,
}

/// What a sync did (`Indexer.SyncSummary`).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct SyncSummary {
    pub added: usize,
    pub changed: usize,
    pub moved: usize,
    pub removed: usize,
    pub unchanged: usize,
    /// Files this sync queued, so a watcher can index exactly those first.
    pub queued: Vec<i64>,
}

pub struct FileIndex {
    pub(crate) db: Connection,
    file: PathBuf,
    directory: PathBuf,
}

impl FileIndex {
    /// Opens the index in `directory`, creating it when there is none. An index
    /// a newer version made is refused; an older schema is rebuilt from the
    /// folders, since nothing in it isn't derived from them.
    pub fn open(directory: &Path) -> Result<Self> {
        std::fs::create_dir_all(directory)?;
        let file = directory.join(MAIN_FILE);
        let mut index = Self::open_file(directory, &file)?;
        let version = index.schema_version()?;
        if version > SCHEMA_VERSION {
            bail!("this index was made by a newer LokalBot (schema {version})");
        }
        if version != 0 && version < SCHEMA_VERSION {
            log::info!("file search: rebuilding an index of schema {version}");
            drop(index);
            for suffix in ["", "-wal", "-shm"] {
                let _ = std::fs::remove_file(format!("{}{suffix}", file.display()));
            }
            index = Self::open_file(directory, &file)?;
        }
        if index.schema_version()? == 0 {
            index.create()?;
        }
        Ok(index)
    }

    /// For agents: never creates, migrates or writes anything.
    pub fn open_read_only(directory: &Path) -> Result<Self> {
        let file = directory.join(MAIN_FILE);
        let db = Connection::open_with_flags(
            &file,
            OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
        )?;
        db.busy_timeout(Duration::from_secs(5))?;
        let index = Self {
            db,
            file,
            directory: directory.to_path_buf(),
        };
        let version = index.schema_version()?;
        if version != SCHEMA_VERSION {
            bail!("the file index has schema {version}, not {SCHEMA_VERSION}");
        }
        Ok(index)
    }

    fn open_file(directory: &Path, file: &Path) -> Result<Self> {
        let db = Connection::open(file)?;
        db.busy_timeout(Duration::from_secs(5))?;
        db.execute_batch(
            "PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL; PRAGMA foreign_keys = ON;",
        )?;
        Ok(Self {
            db,
            file: file.to_path_buf(),
            directory: directory.to_path_buf(),
        })
    }

    fn schema_version(&self) -> Result<i64> {
        Ok(self
            .db
            .query_row("PRAGMA user_version", [], |row| row.get(0))?)
    }

    fn create(&self) -> Result<()> {
        self.db.execute_batch(&format!(
            "BEGIN;
             CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
             CREATE TABLE files(
                 id INTEGER PRIMARY KEY,
                 path TEXT NOT NULL UNIQUE,
                 kind TEXT NOT NULL,
                 size INTEGER NOT NULL,
                 mtime REAL NOT NULL,
                 inode INTEGER NOT NULL,
                 device INTEGER NOT NULL,
                 state TEXT NOT NULL DEFAULT 'pending',
                 detail TEXT,
                 info TEXT,
                 indexed_at REAL
             );
             CREATE INDEX files_inode ON files(device, inode);
             CREATE INDEX files_state ON files(state, kind);
             CREATE TABLE segments(
                 id INTEGER PRIMARY KEY,
                 file INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
                 kind TEXT NOT NULL,
                 modality TEXT NOT NULL,
                 loc REAL,
                 loc_end REAL,
                 excerpt TEXT,
                 vec BLOB
             );
             CREATE INDEX segments_file ON segments(file);
             CREATE VIRTUAL TABLE fts USING fts5({FTS_COLUMNS});
             PRAGMA user_version = {SCHEMA_VERSION};
             COMMIT;"
        ))?;
        Ok(())
    }

    pub fn file(&self) -> &Path {
        &self.file
    }

    pub fn directory(&self) -> &Path {
        &self.directory
    }

    /// Bytes on disk: the database and its write-ahead log.
    pub fn size_on_disk(&self) -> u64 {
        ["", "-wal"]
            .iter()
            .filter_map(|suffix| {
                std::fs::metadata(format!("{}{suffix}", self.file.display()))
                    .map(|m| m.len())
                    .ok()
            })
            .sum()
    }

    /// Runs `body` in a transaction, or in the one already open.
    pub fn transaction<T>(&self, body: impl FnOnce() -> Result<T>) -> Result<T> {
        if !self.db.is_autocommit() {
            return body();
        }
        self.db.execute_batch("BEGIN IMMEDIATE")?;
        match body() {
            Ok(value) => {
                self.db.execute_batch("COMMIT")?;
                Ok(value)
            }
            Err(err) => {
                let _ = self.db.execute_batch("ROLLBACK");
                Err(err)
            }
        }
    }

    // ------------------------------------------------------------------ meta

    pub fn meta(&self, key: &str) -> Result<Option<String>> {
        Ok(self
            .db
            .query_row("SELECT value FROM meta WHERE key = ?1", [key], |row| {
                row.get(0)
            })
            .optional()?)
    }

    pub fn set_meta(&self, key: &str, value: Option<&str>) -> Result<()> {
        match value {
            Some(value) => self.db.execute(
                "INSERT INTO meta(key, value) VALUES(?1, ?2) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                params![key, value],
            )?,
            None => self.db.execute("DELETE FROM meta WHERE key = ?1", [key])?,
        };
        Ok(())
    }

    // ----------------------------------------------------------------- files

    /// The ranges of the UNIQUE path index that hold the files under `folder`,
    /// for the folder as given and for its real path when that's spelled
    /// differently.
    fn path_ranges(folder: &str) -> Vec<(String, String)> {
        let mut spellings = vec![folder.to_string()];
        let real = super::real_path(folder);
        if real != folder {
            spellings.push(real);
        }
        spellings
            .into_iter()
            .map(|path| {
                let prefix = if path.ends_with(std::path::is_separator) {
                    path
                } else {
                    format!("{path}{}", std::path::MAIN_SEPARATOR)
                };
                let end = format!("{prefix}\u{10FFFF}");
                (prefix, end)
            })
            .collect()
    }

    /// Every file under one of `roots`, each once.
    pub fn files_under(&self, roots: &[String]) -> Result<Vec<FileRecord>> {
        let mut out = Vec::new();
        let mut seen = HashSet::new();
        let mut statement = self.db.prepare_cached(&format!(
            "SELECT {FILE_COLUMNS} FROM files WHERE path >= ?1 AND path < ?2"
        ))?;
        for root in roots {
            // A folder inside another one listed is already covered.
            if roots.iter().any(|other| super::is_inside(root, other)) {
                continue;
            }
            for (from, to) in Self::path_ranges(root) {
                for row in statement.query_map(params![from, to], record)? {
                    let file = row?;
                    if seen.insert(file.id) {
                        out.push(file);
                    }
                }
            }
        }
        Ok(out)
    }

    /// Adds a file (pending) and returns its id.
    pub fn insert(&self, file: &Candidate) -> Result<i64> {
        self.transaction(|| {
            self.db.execute(
                "INSERT INTO files(path, kind, size, mtime, inode, device) VALUES(?1, ?2, ?3, ?4, ?5, ?6)",
                params![
                    file.path,
                    file.kind.as_str(),
                    file.size,
                    file.mtime,
                    file.inode as i64,
                    file.device as i64
                ],
            )?;
            let id = self.db.last_insert_rowid();
            self.add_name_row(id, &file.path)?;
            Ok(id)
        })
    }

    /// The file changed on disk: drop what was extracted and queue it again.
    pub fn requeue_as(&self, id: i64, file: &Candidate) -> Result<()> {
        self.transaction(|| {
            self.delete_segments(id, true)?;
            self.db.execute(
                "UPDATE files SET kind = ?1, size = ?2, mtime = ?3, inode = ?4, device = ?5, \
                 state = 'pending', detail = NULL, info = NULL, indexed_at = NULL WHERE id = ?6",
                params![
                    file.kind.as_str(),
                    file.size,
                    file.mtime,
                    file.inode as i64,
                    file.device as i64,
                    id
                ],
            )?;
            Ok(())
        })
    }

    /// Same inode, size and date at a new path: a move. Only the path changes;
    /// nothing is embedded again.
    pub fn move_to(&self, id: i64, path: &str) -> Result<()> {
        self.transaction(|| {
            self.db.execute(
                "UPDATE files SET path = ?1 WHERE id = ?2",
                params![path, id],
            )?;
            self.db.execute(
                "UPDATE fts SET name = ?1, body = ?2 WHERE rowid IN \
                 (SELECT id FROM segments WHERE file = ?3 AND kind = 'name')",
                params![
                    text::normalized(&name_text(path)),
                    text::normalized(&folder_text(path)),
                    id
                ],
            )?;
            Ok(())
        })
    }

    pub fn delete(&self, id: i64) -> Result<()> {
        self.db.execute(
            "DELETE FROM fts WHERE rowid IN (SELECT id FROM segments WHERE file = ?1)",
            [id],
        )?;
        self.db.execute("DELETE FROM files WHERE id = ?1", [id])?;
        Ok(())
    }

    /// Removes every file that isn't under one of `roots`. Returns how many went.
    pub fn prune(&self, keeping_under: &[String]) -> Result<usize> {
        let prefixes: Vec<String> = keeping_under
            .iter()
            .flat_map(|root| Self::path_ranges(root).into_iter().map(|(from, _)| from))
            .collect();
        let mut gone: Vec<i64> = Vec::new();
        {
            let mut statement = self.db.prepare("SELECT id, path FROM files")?;
            let mut rows = statement.query([])?;
            while let Some(row) = rows.next()? {
                let path: String = row.get(1)?;
                if !prefixes.iter().any(|prefix| path.starts_with(prefix)) {
                    gone.push(row.get(0)?);
                }
            }
        }
        if gone.is_empty() {
            return Ok(0);
        }
        self.transaction(|| {
            for id in &gone {
                self.delete(*id)?;
            }
            Ok(())
        })?;
        Ok(gone.len())
    }

    /// Queues every file again and forgets the fingerprint.
    pub fn reset_all(&self) -> Result<()> {
        self.transaction(|| {
            self.db.execute(
                "DELETE FROM fts WHERE rowid IN (SELECT id FROM segments WHERE kind != 'name')",
                [],
            )?;
            self.db
                .execute("DELETE FROM segments WHERE kind != 'name'", [])?;
            self.db.execute(
                "UPDATE files SET state = 'pending', detail = NULL, info = NULL, indexed_at = NULL",
                [],
            )?;
            self.set_meta("fingerprint", None)
        })
    }

    /// Files waiting to be read, in indexing order; `only` narrows it.
    pub fn pending(&self, only: Option<&HashSet<i64>>) -> Result<Vec<FileRecord>> {
        if only.is_some_and(HashSet::is_empty) {
            return Ok(Vec::new());
        }
        let filter = only
            .map(|ids| {
                let list: Vec<String> = ids.iter().map(i64::to_string).collect();
                format!(" AND id IN ({})", list.join(","))
            })
            .unwrap_or_default();
        let mut statement = self.db.prepare(&format!(
            "SELECT {FILE_COLUMNS} FROM files WHERE state = 'pending'{filter} \
             ORDER BY {INDEXING_ORDER_SQL}, mtime DESC"
        ))?;
        let rows = statement.query_map([], record)?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    pub fn pending_count(&self) -> Result<usize> {
        Ok(self.db.query_row(
            "SELECT COUNT(*) FROM files WHERE state = 'pending'",
            [],
            |row| row.get::<_, i64>(0).map(|n| n as usize),
        )?)
    }

    /// Long files with pages or chunks still to read after their first step.
    pub fn unfinished(&self) -> Result<Vec<FileRecord>> {
        let mut statement = self.db.prepare(&format!(
            "SELECT {FILE_COLUMNS} FROM files WHERE state = 'partial' \
             ORDER BY {INDEXING_ORDER_SQL}, mtime DESC"
        ))?;
        let rows = statement.query_map([], record)?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    /// How many long files are unfinished, and how many pages and chunks are left.
    pub fn unfinished_count(&self) -> Result<(usize, usize)> {
        Ok(self.db.query_row(
            "SELECT COUNT(*), COALESCE(SUM(MAX(0, CAST(json_extract(info, '$.read_end') AS INTEGER) \
             - CAST(json_extract(info, '$.read_to') AS INTEGER))), 0) \
             FROM files WHERE state = 'partial'",
            [],
            |row| Ok((row.get::<_, i64>(0)? as usize, row.get::<_, i64>(1)? as usize)),
        )?)
    }

    /// What indexing learned about a file (`finish`'s `info`).
    pub fn info(&self, id: i64) -> Result<BTreeMap<String, String>> {
        let json: Option<String> = self
            .db
            .query_row("SELECT info FROM files WHERE id = ?1", [id], |row| {
                row.get(0)
            })
            .optional()?
            .flatten();
        Ok(json
            .and_then(|json| serde_json::from_str(&json).ok())
            .unwrap_or_default())
    }

    /// The last page or chunk stored for a file.
    pub fn last_place(&self, id: i64) -> Result<Option<usize>> {
        let last: Option<f64> = self.db.query_row(
            "SELECT MAX(loc) FROM segments WHERE file = ?1 AND kind IN ('page', 'page_image', 'chunk')",
            [id],
            |row| row.get(0),
        )?;
        Ok(last.map(|place| place as usize))
    }

    pub fn finish(
        &self,
        id: i64,
        state: &str,
        detail: Option<&str>,
        info: &BTreeMap<String, String>,
    ) -> Result<()> {
        let json = (!info.is_empty())
            .then(|| serde_json::to_string(info))
            .transpose()?;
        self.db.execute(
            "UPDATE files SET state = ?1, detail = ?2, info = ?3, indexed_at = ?4 WHERE id = ?5",
            params![
                state,
                detail,
                json,
                crate::time::to_epoch(chrono::Utc::now()),
                id
            ],
        )?;
        Ok(())
    }

    // -------------------------------------------------------------- segments

    /// Adds a segment; `text` goes into keyword search (normalized), `vector`
    /// into meaning search.
    #[allow(clippy::too_many_arguments)]
    pub fn add_segment(
        &self,
        file: i64,
        kind: SegmentKind,
        modality: Modality,
        loc: Option<f64>,
        loc_end: Option<f64>,
        excerpt: Option<&str>,
        body: Option<&str>,
        vector: Option<&[f32]>,
    ) -> Result<()> {
        self.transaction(|| {
            let modality = if vector.is_none() {
                Modality::None
            } else {
                modality
            };
            self.db.execute(
                "INSERT INTO segments(file, kind, modality, loc, loc_end, excerpt, vec) VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7)",
                params![
                    file,
                    kind.as_str(),
                    modality.as_str(),
                    loc,
                    loc_end,
                    excerpt,
                    vector.map(vector_blob)
                ],
            )?;
            if let Some(body) = body.filter(|b| !b.is_empty()) {
                let normalized = text::normalized(body);
                let original = (normalized != body).then_some(body);
                self.db.execute(
                    "INSERT INTO fts(rowid, name, body, original) VALUES(?1, '', ?2, ?3)",
                    params![self.db.last_insert_rowid(), normalized, original],
                )?;
            }
            Ok(())
        })
    }

    fn add_name_row(&self, file: i64, path: &str) -> Result<()> {
        self.db.execute(
            "INSERT INTO segments(file, kind, modality) VALUES(?1, 'name', 'none')",
            [file],
        )?;
        self.db.execute(
            "INSERT INTO fts(rowid, name, body) VALUES(?1, ?2, ?3)",
            params![
                self.db.last_insert_rowid(),
                text::normalized(&name_text(path)),
                text::normalized(&folder_text(path))
            ],
        )?;
        Ok(())
    }

    fn delete_segments(&self, file: i64, keeping_name: bool) -> Result<()> {
        let filter = if keeping_name {
            "AND kind != 'name'"
        } else {
            ""
        };
        self.db.execute(
            &format!(
                "DELETE FROM fts WHERE rowid IN (SELECT id FROM segments WHERE file = ?1 {filter})"
            ),
            [file],
        )?;
        self.db.execute(
            &format!("DELETE FROM segments WHERE file = ?1 {filter}"),
            [file],
        )?;
        Ok(())
    }

    // ----------------------------------------------------------------- stats

    pub fn counts(&self) -> Result<Counts> {
        let mut counts = Counts::default();
        let mut statement = self
            .db
            .prepare("SELECT kind, state, COUNT(*) FROM files GROUP BY kind, state")?;
        let rows = statement.query_map(params_from_iter::<[i64; 0]>([]), |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, i64>(2)? as usize,
            ))
        })?;
        for row in rows {
            let (kind, state, count) = row?;
            counts
                .by_kind_and_state
                .entry(kind)
                .or_default()
                .insert(state, count);
        }
        (counts.unfinished, counts.left) = self.unfinished_count()?;
        (counts.segments, counts.vectors) = self.db.query_row(
            "SELECT COUNT(*), COUNT(vec) FROM segments WHERE kind != 'name'",
            [],
            |row| {
                Ok((
                    row.get::<_, i64>(0)? as usize,
                    row.get::<_, i64>(1)? as usize,
                ))
            },
        )?;
        Ok(counts)
    }

    // ------------------------------------------------------------------ sync

    /// Reconciles the index with what the walk found: new files are queued,
    /// changed ones queued again, moved ones re-pathed, and files that are gone
    /// or newly excluded removed (`Indexer.sync`).
    pub fn sync(&self, roots: &[String], candidates: &[Candidate]) -> Result<SyncSummary> {
        let existing = self.files_under(roots)?;
        let mut by_path: HashMap<&str, &FileRecord> = HashMap::new();
        let mut by_inode: HashMap<(u64, u64), &FileRecord> = HashMap::new();
        for file in &existing {
            by_path.insert(&file.path, file);
            by_inode.insert((file.device, file.inode), file);
        }
        let seen: HashSet<&str> = candidates.iter().map(|c| c.path.as_str()).collect();
        let mut moved_from: HashSet<&str> = HashSet::new();
        let mut summary = SyncSummary::default();
        self.transaction(|| {
            for file in candidates {
                if let Some(row) = by_path.get(file.path.as_str()) {
                    if row.size != file.size
                        || (row.mtime - file.mtime).abs() > 0.001
                        || row.kind != file.kind
                    {
                        self.requeue_as(row.id, file)?;
                        summary.changed += 1;
                        summary.queued.push(row.id);
                    } else {
                        summary.unchanged += 1;
                    }
                } else if let Some(row) = by_inode.get(&(file.device, file.inode)).filter(|row| {
                    file.inode != 0
                        && !seen.contains(row.path.as_str())
                        && !moved_from.contains(row.path.as_str())
                        && row.size == file.size
                        && (row.mtime - file.mtime).abs() < 0.001
                }) {
                    self.move_to(row.id, &file.path)?;
                    moved_from.insert(&row.path);
                    summary.moved += 1;
                } else {
                    summary.queued.push(self.insert(file)?);
                    summary.added += 1;
                }
            }
            // A root that went away while it was being walked looked emptier
            // than it is: keep its rows rather than take that for "deleted".
            let vanished: Vec<&String> = roots.iter().filter(|r| !Path::new(r).exists()).collect();
            for row in &existing {
                if !seen.contains(row.path.as_str())
                    && !moved_from.contains(row.path.as_str())
                    && !vanished
                        .iter()
                        .any(|root| super::is_inside(&row.path, root))
                {
                    self.delete(row.id)?;
                    summary.removed += 1;
                }
            }
            Ok(())
        })?;
        Ok(summary)
    }
}

/// "Screenshot 2026-10-01 at 9.41.07 PM.png" → searchable words.
fn name_text(path: &str) -> String {
    Path::new(path)
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default()
}

/// The folders a file sits in, relative to the home folder, as low-weight
/// keywords ("Downloads Invoices").
fn folder_text(path: &str) -> String {
    let folder = Path::new(path).parent().unwrap_or(Path::new(""));
    let relative = super::home_dir()
        .and_then(|home| folder.strip_prefix(home).ok().map(Path::to_path_buf))
        .unwrap_or_else(|| folder.to_path_buf());
    relative
        .components()
        .filter_map(|part| match part {
            std::path::Component::Normal(name) => Some(name.to_string_lossy().into_owned()),
            _ => None,
        })
        .collect::<Vec<_>>()
        .join(" ")
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    pub(crate) fn candidate(path: &str, kind: FileKind) -> Candidate {
        Candidate {
            path: path.into(),
            kind,
            size: 10,
            mtime: 100.0,
            inode: 7,
            device: 1,
        }
    }

    fn open() -> (tempfile::TempDir, FileIndex) {
        let dir = tempfile::tempdir().unwrap();
        let index = FileIndex::open(dir.path()).unwrap();
        (dir, index)
    }

    #[test]
    fn creates_the_macs_schema() {
        let (_dir, index) = open();
        assert_eq!(index.schema_version().unwrap(), 5);
        let sql: String = index
            .db
            .query_row(
                "SELECT sql FROM sqlite_master WHERE name = 'fts'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert!(
            sql.contains("porter unicode61 remove_diacritics 2 categories 'L* N* Co M*'"),
            "{sql}"
        );
        // Every column the Mac reads.
        index
            .db
            .execute_batch(
                "SELECT id, path, kind, size, mtime, inode, device, state, detail, info, indexed_at FROM files;
                 SELECT id, file, kind, modality, loc, loc_end, excerpt, vec FROM segments;
                 SELECT rowid, name, body, original FROM fts;
                 SELECT key, value FROM meta;",
            )
            .unwrap();
    }

    #[test]
    fn inserting_adds_a_name_row_and_deleting_cleans_up() {
        let (_dir, index) = open();
        let id = index
            .insert(&candidate("/x/Invoices/report 2026.pdf", FileKind::Pdf))
            .unwrap();
        let (name, body): (String, String) = index
            .db
            .query_row(
                "SELECT name, body FROM fts JOIN segments s ON s.id = fts.rowid WHERE s.file = ?1",
                [id],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();
        assert_eq!(name, "report 2026.pdf");
        assert!(body.contains("Invoices"));
        assert_eq!(index.pending_count().unwrap(), 1);
        index.delete(id).unwrap();
        let left: i64 = index
            .db
            .query_row("SELECT COUNT(*) FROM segments", [], |row| row.get(0))
            .unwrap();
        assert_eq!(left, 0, "segments follow their file");
        let words: i64 = index
            .db
            .query_row("SELECT COUNT(*) FROM fts", [], |row| row.get(0))
            .unwrap();
        assert_eq!(words, 0);
    }

    #[test]
    fn syncing_queues_requeues_moves_and_removes() {
        let (_dir, index) = open();
        let root = "/lokalbot-test-root".to_string();
        let roots = std::slice::from_ref(&root);
        let first = candidate("/lokalbot-test-root/a.txt", FileKind::Doc);
        let mut other = candidate("/lokalbot-test-root/b.txt", FileKind::Doc);
        other.inode = 8;
        let summary = index.sync(roots, &[first.clone(), other.clone()]).unwrap();
        assert_eq!(summary.added, 2);
        assert_eq!(summary.queued.len(), 2);
        // A root that doesn't exist keeps its rows.
        let summary = index.sync(roots, &[]).unwrap();
        assert_eq!(summary.removed, 0);

        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().to_string_lossy().into_owned();
        let roots = std::slice::from_ref(&root);
        let (_keep, index) = open();
        let separator = std::path::MAIN_SEPARATOR;
        let mut first = candidate(&format!("{root}{separator}a.txt"), FileKind::Doc);
        first.inode = 7;
        let mut other = candidate(&format!("{root}{separator}b.txt"), FileKind::Doc);
        other.inode = 8;
        index.sync(roots, &[first.clone(), other.clone()]).unwrap();
        let summary = index.sync(roots, &[first.clone(), other.clone()]).unwrap();
        assert_eq!(summary.unchanged, 2);

        let mut changed = first.clone();
        changed.size = 99;
        let summary = index
            .sync(roots, &[changed.clone(), other.clone()])
            .unwrap();
        assert_eq!((summary.changed, summary.queued.len()), (1, 1));

        let mut moved = other.clone();
        moved.path = format!("{root}{separator}renamed.txt");
        let summary = index
            .sync(roots, &[changed.clone(), moved.clone()])
            .unwrap();
        assert_eq!((summary.moved, summary.added, summary.removed), (1, 0, 0));

        let summary = index.sync(roots, &[moved]).unwrap();
        assert_eq!(summary.removed, 1);
    }

    #[test]
    fn pruning_drops_folders_taken_off_the_list() {
        let dir = tempfile::tempdir().unwrap();
        let keep = dir.path().join("keep").to_string_lossy().into_owned();
        let (_index_dir, index) = open();
        let separator = std::path::MAIN_SEPARATOR;
        index
            .insert(&candidate(
                &format!("{keep}{separator}a.txt"),
                FileKind::Doc,
            ))
            .unwrap();
        index
            .insert(&candidate("/somewhere/else/b.txt", FileKind::Doc))
            .unwrap();
        assert_eq!(index.prune(&[keep]).unwrap(), 1);
        assert_eq!(index.pending_count().unwrap(), 1);
    }

    #[test]
    fn finishing_records_info_as_sorted_json() {
        let (_dir, index) = open();
        let id = index.insert(&candidate("/x/a.txt", FileKind::Doc)).unwrap();
        let info = BTreeMap::from([
            ("chunks".to_string(), "2".to_string()),
            ("chars".to_string(), "10".to_string()),
        ]);
        index
            .finish(id, "partial", Some("read to chunk 1"), &info)
            .unwrap();
        let json: String = index
            .db
            .query_row("SELECT info FROM files WHERE id = ?1", [id], |row| {
                row.get(0)
            })
            .unwrap();
        assert_eq!(json, r#"{"chars":"10","chunks":"2"}"#);
        assert_eq!(index.info(id).unwrap(), info);
        assert_eq!(index.unfinished().unwrap().len(), 1);
    }

    #[test]
    fn an_older_index_is_rebuilt_and_a_newer_one_refused() {
        let dir = tempfile::tempdir().unwrap();
        {
            let db = Connection::open(dir.path().join(MAIN_FILE)).unwrap();
            db.execute_batch("CREATE TABLE old(x); PRAGMA user_version = 3;")
                .unwrap();
        }
        let index = FileIndex::open(dir.path()).unwrap();
        assert_eq!(index.schema_version().unwrap(), 5);
        drop(index);
        {
            let db = Connection::open(dir.path().join(MAIN_FILE)).unwrap();
            db.execute_batch("PRAGMA user_version = 6;").unwrap();
        }
        assert!(FileIndex::open(dir.path()).is_err());
        assert!(FileIndex::open_read_only(dir.path()).is_err());
    }
}
