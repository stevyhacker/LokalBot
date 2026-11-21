//! Collects bursts from every enabled agent and applies the person's
//! project-folder exclusions before anything leaves the reader
//! (`CodingAgentSessionScanner.swift`).

use std::collections::{BTreeMap, HashSet};
use std::path::Path;

use chrono::{DateTime, Duration, NaiveDate, Utc};
use lokalbot_core::coding_agents::{CodingAgentBurst, CodingAgentKind};
use lokalbot_core::time::{local_day, local_day_bounds};

use super::antigravity::AntigravityReader;
use super::builder::{self, Transcript};
use super::cache::ParseCache;
use super::claude::ClaudeCodeReader;
use super::codex::CodexReader;
use super::t3code::T3CodeReader;
use super::text;

/// Identifies one agent session for cross-reader deduplication (for example,
/// when T3 Code owns an underlying Claude Code or Codex session).
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct SessionKey {
    pub agent: CodingAgentKind,
    pub session_id: String,
}

/// What one reader found. Unreadable files are reported, never fatal: an agent
/// update that changes its format must not stop the digest.
#[derive(Debug, Default)]
pub struct ReadResult {
    pub transcripts: Vec<Transcript>,
    /// Native sessions owned by this reader's sessions, so other enabled
    /// readers do not double-count the same work.
    pub claimed_sessions: HashSet<SessionKey>,
    pub files_read: usize,
    pub bytes_read: u64,
    pub unreadable_files: Vec<String>,
}

/// Coding-agent work for a run of local days.
#[derive(Debug)]
pub struct DayScan {
    pub start: DateTime<Utc>,
    pub end: DateTime<Utc>,
    pub bursts: Vec<CodingAgentBurst>,
    pub session_count: usize,
    pub files_read: usize,
    pub bytes_read: u64,
    pub unreadable_files: Vec<String>,
    pub excluded_sessions: usize,
}

enum Reader {
    ClaudeCode(ClaudeCodeReader),
    Codex(CodexReader),
    Antigravity(AntigravityReader),
    T3Code(T3CodeReader),
}

pub struct Scanner {
    readers: Vec<Reader>,
    /// Sessions whose working directory is inside one of these folders are
    /// dropped, for repositories whose work must never enter the library.
    excluded_folders: Vec<String>,
    home: Option<String>,
}

impl Scanner {
    pub fn standard(
        home: &Path,
        agents: &[CodingAgentKind],
        excluded_folders: Vec<String>,
    ) -> Self {
        let readers = CodingAgentKind::ALL
            .iter()
            .filter(|agent| agents.contains(agent))
            .map(|agent| match agent {
                CodingAgentKind::ClaudeCode => Reader::ClaudeCode(ClaudeCodeReader {
                    root: home.join(".claude").join("projects"),
                }),
                CodingAgentKind::Codex => Reader::Codex(CodexReader {
                    root: home.join(".codex"),
                }),
                CodingAgentKind::Antigravity => {
                    Reader::Antigravity(AntigravityReader::standard(home))
                }
                CodingAgentKind::T3Code => Reader::T3Code(T3CodeReader {
                    root: home.join(".t3").join("userdata"),
                }),
            })
            .collect();
        Self {
            readers,
            excluded_folders,
            home: home.to_str().map(str::to_string),
        }
    }

    /// Every local day from `first` through `last`, reading each transcript
    /// once. Bursts never cross midnight, so each belongs to exactly one day.
    pub fn scan(&self, first: NaiveDate, last: NaiveDate, cache: Option<&ParseCache>) -> DayScan {
        let (start, _) = local_day_bounds(first.min(last));
        let (last_start, end) = local_day_bounds(first.max(last));
        debug_assert!(end > last_start - Duration::days(1));
        let mut scan = DayScan {
            start,
            end,
            bursts: Vec::new(),
            session_count: 0,
            files_read: 0,
            bytes_read: 0,
            unreadable_files: Vec::new(),
            excluded_sessions: 0,
        };
        let results: Vec<ReadResult> = self
            .readers
            .iter()
            .map(|reader| match reader {
                Reader::ClaudeCode(reader) => reader.transcripts(start, end, cache),
                Reader::Codex(reader) => reader.transcripts(start, end, cache),
                Reader::Antigravity(reader) => reader.transcripts(start, end, cache),
                Reader::T3Code(reader) => reader.transcripts(start, end),
            })
            .collect();
        let mut claimed: HashSet<SessionKey> = HashSet::new();
        for result in &results {
            scan.files_read += result.files_read;
            scan.bytes_read += result.bytes_read;
            scan.unreadable_files
                .extend(result.unreadable_files.iter().cloned());
            claimed.extend(result.claimed_sessions.iter().cloned());
        }
        for result in results {
            for transcript in result.transcripts {
                if claimed.contains(&SessionKey {
                    agent: transcript.agent,
                    session_id: transcript.session_id.clone(),
                }) {
                    continue;
                }
                if self.is_excluded(transcript.working_directory.as_deref()) {
                    scan.excluded_sessions += 1;
                    continue;
                }
                let mut days: BTreeMap<NaiveDate, Vec<_>> = BTreeMap::new();
                for event in &transcript.events {
                    days.entry(local_day(event.at))
                        .or_default()
                        .push(event.clone());
                }
                let mut bursts = Vec::new();
                for events in days.into_values() {
                    let daily = Transcript {
                        events,
                        ..transcript.clone()
                    };
                    bursts.extend(builder::bursts(&daily));
                }
                if bursts.is_empty() {
                    continue;
                }
                scan.session_count += 1;
                scan.bursts.extend(bursts);
            }
        }
        scan.bursts
            .sort_by(|a, b| a.start.cmp(&b.start).then_with(|| a.id().cmp(&b.id())));
        scan
    }

    pub fn is_excluded(&self, working_directory: Option<&str>) -> bool {
        let Some(directory) = working_directory else {
            return false;
        };
        let home = self.home.as_deref();
        let path = text::standardized_path(directory, home);
        self.excluded_folders.iter().any(|rule| {
            let folder = text::standardized_path(rule.trim(), home);
            !folder.is_empty() && folder != "/" && text::is_inside(&path, &folder)
        })
    }
}
