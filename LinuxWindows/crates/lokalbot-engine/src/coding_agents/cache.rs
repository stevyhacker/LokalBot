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

pub fn distant_past() -> DateTime<Utc> {
    DateTime::<Utc>::MIN_UTC
}

pub trait FileSummary: Clone + Send + 'static {
    fn consume(&mut self, line: Line<'_>, start: DateTime<Utc>);
    fn finish(&mut self) {}
    fn trim(&mut self, start: DateTime<Utc>);
}

#[derive(Clone, Debug)]
pub struct StoredEvent {
    pub at: DateTime<Utc>,
    pub kind: EventKind,
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

#[derive(Clone, Debug)]
pub struct CandidateFile {
    pub path: PathBuf,
    pub created: SystemTime,
    pub modified: SystemTime,
    pub size: u64,
}

pub fn is_compressed(path: &Path) -> bool {
    path.extension().is_some_and(|extension| extension == "zst")
        && path.file_stem().is_some_and(|stem| {
            Path::new(stem)
                .extension()
                .is_some_and(|inner| inner == "jsonl")
        })
}

pub fn plain_path(path: &Path) -> PathBuf {
    if is_compressed(path) {
        path.with_extension("")
    } else {
        path.to_path_buf()
    }
}

pub fn start_bound(path: &Path) -> SystemTime {
    path.file_name()
        .and_then(|name| name.to_str())
        .and_then(|name| name.strip_prefix("rollout-"))
        .and_then(|rest| rest.get(..10))
        .and_then(|day| chrono::NaiveDate::parse_from_str(day, "%Y-%m-%d").ok())
        .and_then(|date| date.pred_opt())
        .and_then(|date| date.and_hms_opt(0, 0, 0))
        .map(|time| SystemTime::from(time.and_utc()))
        .unwrap_or(SystemTime::UNIX_EPOCH)
}

pub fn candidate_files(
    paths: impl IntoIterator<Item = PathBuf>,
    start: DateTime<Utc>,
    end: DateTime<Utc>,
    compressed_rollouts: bool,
) -> Vec<CandidateFile> {
    paths
        .into_iter()
        .filter_map(|path| {
            let compressed = compressed_rollouts && is_compressed(&path);
            if !compressed
                && path
                    .extension()
                    .is_none_or(|extension| extension != "jsonl")
            {
                return None;
            }
            let metadata = std::fs::symlink_metadata(&path).ok()?;
            if !metadata.is_file() {
                return None;
            }
            let modified = metadata.modified().ok()?;
            if DateTime::<Utc>::from(modified) < start {
                return None;
            }
            let created = if compressed {
                start_bound(&path).min(modified)
            } else {
                metadata.created().unwrap_or(modified)
            };
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

#[derive(Clone)]
struct FileState<S> {
    created: SystemTime,
    modified: SystemTime,
    size: u64,
    offset: u64,
    boundary: Vec<u8>,
    retained_from: DateTime<Utc>,
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

pub fn summary_of<S: FileSummary>(
    file: &CandidateFile,
    start: DateTime<Utc>,
    cache: Option<&ParseCache>,
    empty: impl FnOnce() -> S,
) -> std::io::Result<(S, Option<u64>)> {
    if is_compressed(&file.path) {
        return compressed_summary_of(file, start, cache, empty);
    }
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
        summary.consume(Line(&unfinished), current.retained_from);
        summary.finish();
    }
    Ok((summary, Some(bytes_read)))
}

fn compressed_summary_of<S: FileSummary>(
    file: &CandidateFile,
    start: DateTime<Utc>,
    cache: Option<&ParseCache>,
    empty: impl FnOnce() -> S,
) -> std::io::Result<(S, Option<u64>)> {
    let path = file.path.as_path();
    let cached = cache
        .and_then(|cache| cache.state(path))
        .filter(|cached: &FileState<S>| {
            cached.retained_from <= start
                && cached.created == file.created
                && cached.utc_offset == current_utc_offset()
                && cached.size == file.size
                && cached.modified == file.modified
        });
    if let Some(mut cached) = cached {
        if cached.retained_from < start {
            cached.summary.trim(start);
            cached.retained_from = start;
            if let Some(cache) = cache {
                cache.store(path, cached.clone());
            }
        }
        return Ok((cached.summary, None));
    }
    let decoder = zstd::stream::read::Decoder::new(File::open(path)?)?;
    let mut reader = BufReader::with_capacity(256 * 1024, decoder);
    let mut summary = empty();
    let mut line = Vec::new();
    let mut bytes_read = 0;
    let mut consumed = false;
    loop {
        line.clear();
        let count = reader.read_until(b'\n', &mut line)?;
        if count == 0 {
            break;
        }
        bytes_read += count as u64;
        let content = line.strip_suffix(b"\n").unwrap_or(&line);
        if !content.is_empty() {
            summary.consume(Line(content), start);
            consumed = true;
        }
    }
    if consumed {
        summary.finish();
    }
    if let Some(cache) = cache {
        cache.store(
            path,
            FileState {
                created: file.created,
                modified: file.modified,
                size: file.size,
                offset: file.size,
                boundary: Vec::new(),
                retained_from: start,
                utc_offset: current_utc_offset(),
                summary: summary.clone(),
            },
        );
    }
    Ok((summary, Some(bytes_read)))
}
