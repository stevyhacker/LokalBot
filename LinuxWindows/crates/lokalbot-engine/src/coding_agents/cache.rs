//! What readers keep between scans (`CodingAgentParseCache.swift`). A summary
//! holds no window of its own, so a new day or a refresh reuses it and parses
//! only the lines agents appended since.

use std::any::Any;
use std::collections::{HashMap, HashSet};
use std::fs::File;
use std::io::{BufRead as _, BufReader, Read as _, Seek as _, SeekFrom};
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use chrono::{DateTime, Local, Utc};
use parking_lot::Mutex;

use super::builder::{EventKind, TimedEvent};
use super::text::Line;

/// The earliest time a summary can be asked for.
pub fn distant_past() -> DateTime<Utc> {
    DateTime::<Utc>::MIN_UTC
}

pub trait FileSummary: Clone + Send + 'static {
    /// Folds in one complete line, keeping timed records from `start` on.
    fn consume(&mut self, line: Line<'_>, start: DateTime<Utc>);
    /// Runs after a batch of lines.
    fn finish(&mut self) {}
    /// Drops timed records before `start`, which no later scan reads.
    fn trim(&mut self, start: DateTime<Utc>);
}

/// An event as a summary keeps it. Folder, branch and record id live on the
/// record it came from, so a busy record's events share them.
#[derive(Clone, Debug)]
pub struct StoredEvent {
    pub at: DateTime<Utc>,
    pub kind: EventKind,
    /// The source record's index in its summary, or `-1` for none.
    pub record: i32,
}

impl TimedEvent for StoredEvent {
    fn at(&self) -> DateTime<Utc> {
        self.at
    }

    fn kind(&self) -> &EventKind {
        &self.kind
    }
}

/// A transcript that may hold activity inside a window.
#[derive(Clone, Debug)]
pub struct CandidateFile {
    pub path: PathBuf,
    pub created: SystemTime,
    pub modified: SystemTime,
    pub size: u64,
}

/// Transcript files that may hold activity inside the window: written since it
/// began, and created before it ended. Skipping by metadata keeps
/// multi-gigabyte archives out of every scan.
pub fn candidate_files(
    paths: impl IntoIterator<Item = PathBuf>,
    start: DateTime<Utc>,
    end: DateTime<Utc>,
) -> Vec<CandidateFile> {
    paths
        .into_iter()
        .filter_map(|path| {
            if path
                .extension()
                .is_none_or(|extension| extension != "jsonl")
            {
                return None;
            }
            // `metadata` follows links; only a regular file itself counts.
            let metadata = std::fs::symlink_metadata(&path).ok()?;
            if !metadata.is_file() {
                return None;
            }
            let modified = metadata.modified().ok()?;
            if DateTime::<Utc>::from(modified) < start {
                return None;
            }
            let created = metadata.created().unwrap_or(modified);
            if DateTime::<Utc>::from(created) >= end {
                return None;
            }
            Some(CandidateFile {
                path,
                created,
                modified,
                size: metadata.len(),
            })
        })
        .collect()
}

/// Both agents only append to their transcripts; a file that shrank, was
/// replaced, or whose bytes before the resume point changed is parsed again from
/// the start.
#[derive(Clone)]
struct FileState<S> {
    created: SystemTime,
    modified: SystemTime,
    size: u64,
    /// Bytes folded into `summary`: every complete line. A line still being
    /// written is read again once its newline arrives.
    offset: u64,
    /// The bytes just before `offset`.
    boundary: Vec<u8>,
    /// Records from before this time were not kept, so a scan reaching further
    /// back parses the file again.
    retained_from: DateTime<Utc>,
    /// Activity is compacted by local day, so a time zone change reparses.
    utc_offset: i32,
    summary: S,
}

const BOUNDARY_BYTES: u64 = 64;

fn current_utc_offset() -> i32 {
    Local::now().offset().local_minus_utc()
}

#[derive(Default)]
pub struct ParseCache {
    states: Mutex<HashMap<PathBuf, Box<dyn Any + Send>>>,
}

impl ParseCache {
    fn state<S: FileSummary>(&self, path: &Path) -> Option<FileState<S>> {
        self.states
            .lock()
            .get(path)?
            .downcast_ref::<FileState<S>>()
            .cloned()
    }

    fn store<S: FileSummary>(&self, path: &Path, state: FileState<S>) {
        self.states
            .lock()
            .insert(path.to_path_buf(), Box::new(state));
    }

    #[cfg(test)]
    pub fn state_count(&self) -> usize {
        self.states.lock().len()
    }

    /// Forgets files under `root` that a scan no longer selected.
    pub fn prune(&self, keeping: &HashSet<PathBuf>, root: &Path) {
        self.states
            .lock()
            .retain(|path, _| !path.starts_with(root) || keeping.contains(path));
    }
}

fn read_boundary(file: &mut File, offset: u64) -> std::io::Result<Vec<u8>> {
    let length = offset.min(BOUNDARY_BYTES);
    file.seek(SeekFrom::Start(offset - length))?;
    let mut bytes = vec![0; length as usize];
    file.read_exact(&mut bytes)?;
    Ok(bytes)
}

/// `file`'s summary for a scan whose window starts at `start`: the cached one
/// while the file is unchanged, extended by the lines appended since otherwise.
/// Without a cache the whole file is parsed. The count is `None` when the file
/// was not opened.
pub fn summary_of<S: FileSummary>(
    file: &CandidateFile,
    start: DateTime<Utc>,
    cache: Option<&ParseCache>,
    empty: impl FnOnce() -> S,
) -> std::io::Result<(S, Option<u64>)> {
    let path = file.path.as_path();
    let mut state: Option<FileState<S>> =
        cache
            .and_then(|cache| cache.state(path))
            .filter(|cached: &FileState<S>| {
                cached.retained_from <= start
                    && cached.created == file.created
                    && cached.utc_offset == current_utc_offset()
            });
    if let Some(cached) = state.as_mut()
        && cached.size == file.size
        && cached.modified == file.modified
        && cached.offset == cached.size
    {
        if cached.retained_from < start {
            cached.summary.trim(start);
            cached.retained_from = start;
            if let Some(cache) = cache {
                cache.store(path, cached.clone());
            }
        }
        return Ok((cached.summary.clone(), None));
    }

    let mut opened = File::open(path)?;
    let length = opened.metadata()?.len();
    if let Some(cached) = state.as_ref()
        && (cached.offset > length || read_boundary(&mut opened, cached.offset)? != cached.boundary)
    {
        state = None;
    }
    let mut current = state.unwrap_or_else(|| FileState {
        created: file.created,
        modified: file.modified,
        size: 0,
        offset: 0,
        boundary: Vec::new(),
        retained_from: start,
        utc_offset: current_utc_offset(),
        summary: empty(),
    });
    if current.retained_from < start {
        current.summary.trim(start);
        current.retained_from = start;
    }
    let resume_at = current.offset;
    opened.seek(SeekFrom::Start(resume_at))?;
    let mut reader = BufReader::with_capacity(256 * 1024, opened);
    let mut line = Vec::new();
    let mut bytes_read = 0;
    let mut unfinished = Vec::new();
    let mut consumed = false;
    loop {
        line.clear();
        let count = reader.read_until(b'\n', &mut line)?;
        if count == 0 {
            break;
        }
        bytes_read += count as u64;
        if line.last() == Some(&b'\n') {
            current.offset += count as u64;
            let content = &line[..line.len() - 1];
            if !content.is_empty() {
                current
                    .summary
                    .consume(Line(content), current.retained_from);
                consumed = true;
            }
        } else {
            std::mem::swap(&mut unfinished, &mut line);
        }
    }
    if consumed {
        current.summary.finish();
    }
    let mut reopened = reader.into_inner();
    current.created = file.created;
    current.modified = file.modified;
    current.size = current.offset + unfinished.len() as u64;
    current.boundary = read_boundary(&mut reopened, current.offset)?;
    if let Some(cache) = cache {
        cache.store(path, current.clone());
    }
    let mut summary = current.summary;
    if !unfinished.is_empty() {
        // The last line has no newline yet: read it for this scan only.
        summary.consume(Line(&unfinished), current.retained_from);
        summary.finish();
    }
    Ok((summary, Some(bytes_read)))
}
