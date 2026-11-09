//! Withdrawing overnight memory when the meetings it came from change
//! (`DreamStore.swift`, `DreamEvidenceMutation.swift`, `DreamModels.swift`).
//!
//! `memory/evidence-revisions.json` holds a revision counter and the revision
//! at which each day and meeting last changed. Dream reports and work memory
//! record the revision they were built at, and both apps drop anything built
//! from a source that changed since when they read it. Under the shared
//! `.dream-store.lock`, a writer records the change, withdraws what depended on
//! it (`dream::store`), and only then changes the source.
//!
//! A person deleting a source also withdraws that day's unedited generated
//! journal (`DayDigestLifecycle.retractGeneratedJournals`). Scheduled retention
//! goes through none of this: long-term memory outlives the screen window.

use std::collections::{BTreeMap, BTreeSet};
use std::fs::{self, File, OpenOptions};
use std::path::Path;

use anyhow::{Context as _, Result};
use chrono::{DateTime, Duration, NaiveDate, Utc};
use serde::{Deserialize, Serialize};

use crate::dream::store::{DreamStore, Revocation};
use crate::dream::{COMPARISON_WINDOW_DAYS, report_day_keys};
use crate::ids;
use crate::model::Meeting;

pub const EVIDENCE_FILE: &str = "memory/evidence-revisions.json";
pub const LOCK_FILE: &str = ".dream-store.lock";
pub const MEMORY_FILE: &str = "memory/memory.json";
/// Present while a macOS revocation is unfinished; memory must not be used.
pub const PENDING_FILE: &str = ".dream-revocation-pending.json";

/// Swift's synthesized decoder needs `revision` and `invalidatedDays` present,
/// so both are always written.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EvidenceState {
    #[serde(default)]
    pub revision: u64,
    #[serde(default)]
    pub invalidated_days: BTreeMap<String, u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub invalidated_meetings: Option<BTreeMap<String, u64>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub invalidated_activity_days: Option<BTreeMap<String, u64>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub memory_cleared_revision: Option<u64>,
    #[serde(flatten)]
    pub extra: serde_json::Map<String, serde_json::Value>,
}

/// `DreamEvidenceProvenance`: what a memory item or report was built from.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Provenance {
    #[serde(default)]
    pub sources: Vec<Source>,
    #[serde(default)]
    pub revision: u64,
    #[serde(default)]
    pub includes_unattributed_context: bool,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Source {
    /// `meeting`, `screenDay` or `digest`.
    pub kind: String,
    /// The full meeting UUID, or the day key for day-level evidence.
    pub id: String,
    pub day_key: String,
}

impl EvidenceState {
    /// `DreamStore.isInvalidated`: without provenance an item cannot be traced
    /// to an unaffected source, so the first change withdraws it.
    pub fn invalidates(&self, provenance: Option<&Provenance>) -> bool {
        if self.revision == 0 {
            return false;
        }
        let Some(provenance) = provenance else {
            return true;
        };
        if provenance.includes_unattributed_context || provenance.sources.is_empty() {
            return provenance.revision < self.revision;
        }
        let meetings = self.invalidated_meetings.as_ref();
        let activity = self.invalidated_activity_days.as_ref();
        provenance.sources.iter().any(|source| {
            let mut day = self
                .invalidated_days
                .get(&source.day_key)
                .copied()
                .unwrap_or(0);
            if source.kind != "meeting" {
                day = day.max(
                    activity
                        .and_then(|a| a.get(&source.day_key))
                        .copied()
                        .unwrap_or(0),
                );
            }
            day > provenance.revision
                || (source.kind == "meeting"
                    && meetings
                        .and_then(|m| m.get(&source.id.to_uppercase()))
                        .copied()
                        .unwrap_or(0)
                        > provenance.revision)
        })
    }
}

/// The library's evidence state, or `None` while overnight memory must not be
/// read: a macOS revocation is unfinished, or the state is unreadable.
pub fn read_state(root: &Path) -> Option<EvidenceState> {
    if root.join(PENDING_FILE).exists() || crate::dream::store::is_blocked(root) {
        return None;
    }
    match fs::read(root.join(EVIDENCE_FILE)) {
        Ok(bytes) => serde_json::from_slice(&bytes).ok(),
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => Some(EvidenceState::default()),
        Err(_) => None,
    }
}

/// `memory/memory.json` without the items built from evidence that changed
/// since (`DreamMemory.retractingEvidence`), or `None` while overnight memory
/// must not be read.
pub fn read_work_memory(root: &Path) -> Option<Vec<u8>> {
    let state = read_state(root)?;
    let bytes = fs::read(root.join(MEMORY_FILE)).ok()?;
    if state.revision == 0 {
        return Some(bytes);
    }
    let mut memory: serde_json::Value = serde_json::from_slice(&bytes).ok()?;
    let keep = |provenance: Option<&serde_json::Value>| {
        let provenance = provenance.and_then(|p| Provenance::deserialize(p).ok());
        !state.invalidates(provenance.as_ref())
    };
    for key in ["activeProjects", "workGoals"] {
        if let Some(serde_json::Value::Array(items)) = memory.get_mut(key) {
            items.retain(|item| keep(item.get("provenance")));
        }
    }
    let provenance = memory.get("patternProvenance").cloned().unwrap_or_default();
    if let Some(serde_json::Value::Array(patterns)) = memory.get_mut("recurringPatterns") {
        patterns.retain(|pattern| keep(pattern.as_str().and_then(|p| provenance.get(p))));
        let remaining: BTreeSet<String> = patterns
            .iter()
            .filter_map(|p| p.as_str().map(str::to_string))
            .collect();
        if let Some(serde_json::Value::Object(map)) = memory.get_mut("patternProvenance") {
            map.retain(|pattern, _| remaining.contains(pattern));
        }
    }
    serde_json::to_vec(&memory).ok()
}

/// `DreamEvidenceInvalidation.sourceDayKeys`: each meeting's UTC day and the
/// two days either side, so a time-zone change can't hide a dependent report.
pub fn source_day_keys(dates: impl IntoIterator<Item = DateTime<Utc>>) -> BTreeSet<String> {
    dates
        .into_iter()
        .flat_map(|date| {
            (-2..=2).map(move |offset| {
                (date + Duration::days(offset))
                    .format("%Y-%m-%d")
                    .to_string()
            })
        })
        .collect()
}

/// What a source write means for that day's generated digest
/// (`AppState.EvidenceChange`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EvidenceChange {
    /// Reprocessing, corrections, outcome edits and saved moments. The digest
    /// stays, marked out of date, until it is regenerated.
    Revision,
    /// The person deleted the source: its unedited generated digest goes too.
    Removal,
}

/// Advances the evidence state for `meetings`, then runs `mutation` while still
/// holding the lock (`DreamStore.withMeetingEvidenceMutation`). If the state
/// can't be written, the meetings are left unchanged.
pub fn with_meeting_mutation<T>(
    root: &Path,
    meetings: &[&Meeting],
    mutation: impl FnOnce() -> Result<T>,
) -> Result<T> {
    meeting_change(root, meetings, EvidenceChange::Revision, mutation)
}

/// [`with_meeting_mutation`] for a meeting, or part of one, the person removed.
pub fn with_meeting_removal<T>(
    root: &Path,
    meetings: &[&Meeting],
    mutation: impl FnOnce() -> Result<T>,
) -> Result<T> {
    meeting_change(root, meetings, EvidenceChange::Removal, mutation)
}

fn meeting_change<T>(
    root: &Path,
    meetings: &[&Meeting],
    change: EvidenceChange,
    mutation: impl FnOnce() -> Result<T>,
) -> Result<T> {
    if meetings.is_empty() {
        return mutation();
    }
    let dates: Vec<DateTime<Utc>> = meetings.iter().map(|m| m.started_at).collect();
    let result = (|| {
        let _lock = StoreLock::acquire(root)?;
        DreamStore::new(root)
            .revoke_locked(
                &Revocation {
                    days: source_day_keys(dates.iter().copied()),
                    meetings: meetings
                        .iter()
                        .map(|meeting| ids::uuid_upper(&meeting.id))
                        .collect(),
                    reports: dependent_reports(&dates, COMPARISON_WINDOW_DAYS),
                    activity_only: false,
                },
                Utc::now(),
            )
            .map_err(anyhow::Error::from)?;
        if change == EvidenceChange::Removal {
            retract_generated_journals(root, dates.iter().map(|at| crate::time::local_day(*at)))?;
        }
        mutation()
    })();
    notify(root, &dates);
    result
}

/// The reports a change on `dates` withdraws: each day and, for meetings, the
/// comparison windows after it (`withSourceEvidenceMutation`).
fn dependent_reports(dates: &[DateTime<Utc>], window_days: i64) -> BTreeSet<String> {
    report_day_keys(
        dates.iter().map(|at| crate::time::local_day(*at)),
        crate::time::local_day(Utc::now()),
        window_days,
    )
}

/// Screen, activity and coding-agent evidence is read only for the day it
/// belongs to, so it withdraws what was built from those days and leaves
/// meeting-derived facts alone (`DreamStore.withScreenEvidenceMutation`).
pub fn with_screen_mutation<T>(
    root: &Path,
    dates: &[DateTime<Utc>],
    change: EvidenceChange,
    mutation: impl FnOnce() -> Result<T>,
) -> Result<T> {
    if dates.is_empty() {
        return mutation();
    }
    let result = (|| {
        let _lock = StoreLock::acquire(root)?;
        DreamStore::new(root)
            .revoke_locked(
                &Revocation {
                    days: source_day_keys(dates.iter().copied()),
                    meetings: BTreeSet::new(),
                    reports: dependent_reports(dates, 1),
                    activity_only: true,
                },
                Utc::now(),
            )
            .map_err(anyhow::Error::from)?;
        if change == EvidenceChange::Removal {
            retract_generated_journals(root, dates.iter().map(|at| crate::time::local_day(*at)))?;
        }
        mutation()
    })();
    notify(root, dates);
    result
}

// ------------------------------------------------------- generated journals

/// Removes each day's journal while it is still the generated copy of its
/// evidence, with its sidecars. Edited and unsigned journals are the person's
/// and stay (`DayDigestLifecycle.retractGeneratedJournals`).
pub fn retract_generated_journals(
    root: &Path,
    days: impl IntoIterator<Item = NaiveDate>,
) -> Result<()> {
    let days: BTreeSet<NaiveDate> = days.into_iter().collect();
    for day in days {
        let journal = root
            .join("journal")
            .join(format!("{}.md", day.format("%Y-%m-%d")));
        if !journal_is_generated(&journal) {
            continue;
        }
        fs::remove_file(&journal).with_context(|| format!("removing {}", journal.display()))?;
        for artifact in [
            journal.with_extension("meta.json"),
            journal.with_extension("write.json"),
        ] {
            match fs::remove_file(&artifact) {
                Err(err) if err.kind() != std::io::ErrorKind::NotFound => {
                    return Err(err).with_context(|| format!("removing {}", artifact.display()));
                }
                _ => {}
            }
        }
    }
    Ok(())
}

/// `DayDigestGenerationMetadataStore.load` and `journalMatches`, including an
/// interrupted Mac write, whose record still says who owns the journal.
pub fn journal_is_generated(journal: &Path) -> bool {
    let Ok(bytes) = fs::read(journal) else {
        return false;
    };
    let digest = crate::library::sha256_hex(&bytes);
    let transaction = journal.with_extension("write.json");
    let metadata_path = journal.with_extension("meta.json");
    let metadata: Option<serde_json::Value> = fs::read(&metadata_path)
        .ok()
        .and_then(|bytes| serde_json::from_slice(&bytes).ok());
    let pending: Option<serde_json::Value> = fs::read(&transaction)
        .ok()
        .and_then(|bytes| serde_json::from_slice(&bytes).ok())
        .filter(|pending: &serde_json::Value| pending["version"] == 1);
    if let Some(pending) = pending {
        let same = |key: &str| {
            metadata
                .as_ref()
                .is_some_and(|meta| meta.get(key) == pending.get(key))
        };
        if pending["journalDigest"].as_str() != Some(digest.as_str()) {
            let _ = fs::remove_file(&transaction);
        } else if [
            "quality",
            "generatedAt",
            "evidenceLatestAt",
            "evidenceSignature",
            "meetingEvidenceSignature",
            "journalDigest",
            "coverage",
        ]
        .iter()
        .all(|key| same(key))
        {
            let _ = fs::remove_file(&transaction);
            return true;
        } else if pending["expectedJournalDigest"] == pending["journalDigest"] {
            // A rewrite of byte-identical content that may never have landed:
            // the person's earlier ownership wins.
            let _ = fs::remove_file(&transaction);
        } else {
            return true;
        }
    } else if transaction.exists() {
        return false;
    }
    metadata.is_some_and(|meta| {
        (1..=2).contains(&meta["version"].as_i64().unwrap_or(0))
            && meta["journalDigest"].as_str() == Some(digest.as_str())
    })
}

// ------------------------------------------------------------- change hooks

type Observer = Box<dyn Fn(&Path, &[DateTime<Utc>]) + Send + Sync>;

static OBSERVERS: parking_lot::RwLock<Vec<Observer>> = parking_lot::RwLock::new(Vec::new());

/// Runs `observer` after every source change in this process, with the
/// library's root and the changed dates (`AppState.primaryEvidenceDidChange`):
/// exports, routines and cached digest answers follow what changed.
pub fn observe(observer: impl Fn(&Path, &[DateTime<Utc>]) + Send + Sync + 'static) {
    OBSERVERS.write().push(Box::new(observer));
}

fn notify(root: &Path, dates: &[DateTime<Utc>]) {
    for observer in OBSERVERS.read().iter() {
        observer(root, dates);
    }
}

/// The advisory lock macOS takes around every revision check and commit.
/// `File::lock` is `flock` on Unix, so it excludes the Mac app on a shared
/// folder as well as other processes here. `flock` doesn't exclude a second
/// handle in this process, hence the mutex too.
pub(crate) struct StoreLock {
    file: File,
    _process: parking_lot::MutexGuard<'static, ()>,
}

static PROCESS_LOCK: parking_lot::Mutex<()> = parking_lot::Mutex::new(());

impl StoreLock {
    pub(crate) fn acquire(root: &Path) -> Result<Self> {
        let process = PROCESS_LOCK.lock();
        fs::create_dir_all(root)?;
        let mut options = OpenOptions::new();
        options.read(true).write(true).create(true).truncate(false);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt as _;
            options.mode(0o600);
        }
        let path = root.join(LOCK_FILE);
        let file = options
            .open(&path)
            .with_context(|| format!("opening {}", path.display()))?;
        file.lock()
            .with_context(|| format!("locking {}", path.display()))?;
        Ok(Self {
            file,
            _process: process,
        })
    }
}

impl Drop for StoreLock {
    fn drop(&mut self) {
        let _ = self.file.unlock();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone as _;

    fn meeting(started: DateTime<Utc>) -> Meeting {
        serde_json::from_value(serde_json::json!({
            "id": "4E1C1B59-6E0B-4F38-9E57-3C1B1F0A2D11",
            "title": "Design review",
            "appName": "Zoom",
            "startedAt": started.to_rfc3339_opts(chrono::SecondsFormat::Secs, true),
            "relativePath": "meetings/2026/10/15-design-review",
        }))
        .unwrap()
    }

    #[test]
    fn a_change_advances_the_revision_for_the_meeting_and_nearby_days() {
        let dir = tempfile::tempdir().unwrap();
        let started = Utc.with_ymd_and_hms(2026, 10, 15, 23, 30, 0).unwrap();
        let meeting = meeting(started);
        let ran = with_meeting_mutation(dir.path(), &[&meeting], || Ok(true)).unwrap();
        assert!(ran);
        with_meeting_mutation(dir.path(), &[&meeting], || Ok(())).unwrap();

        let state = read_state(dir.path()).unwrap();
        assert_eq!(state.revision, 2);
        let days: Vec<_> = state.invalidated_days.keys().cloned().collect();
        assert_eq!(
            days,
            [
                "2026-10-13",
                "2026-10-14",
                "2026-10-15",
                "2026-10-16",
                "2026-10-17"
            ]
        );
        assert!(state.invalidated_days.values().all(|r| *r == 2));
        assert_eq!(
            state.invalidated_meetings.unwrap()["4E1C1B59-6E0B-4F38-9E57-3C1B1F0A2D11"],
            2
        );
        let json: serde_json::Value =
            serde_json::from_slice(&fs::read(dir.path().join(EVIDENCE_FILE)).unwrap()).unwrap();
        assert!(json.get("revision").is_some() && json.get("invalidatedDays").is_some());
    }

    #[test]
    fn keeps_keys_written_by_macos() {
        let dir = tempfile::tempdir().unwrap();
        fs::create_dir_all(dir.path().join("memory")).unwrap();
        fs::write(
            dir.path().join(EVIDENCE_FILE),
            r#"{"revision":4,"invalidatedDays":{"2026-01-01":3},"invalidatedActivityDays":{"2026-01-02":4},"memoryClearedRevision":2,"futureKey":true}"#,
        )
        .unwrap();
        let meeting = meeting(Utc.with_ymd_and_hms(2026, 10, 15, 9, 0, 0).unwrap());
        with_meeting_mutation(dir.path(), &[&meeting], || Ok(())).unwrap();
        let state = read_state(dir.path()).unwrap();
        assert_eq!(state.revision, 5);
        assert_eq!(state.invalidated_days["2026-01-01"], 3);
        assert_eq!(state.invalidated_activity_days.unwrap()["2026-01-02"], 4);
        assert_eq!(state.memory_cleared_revision, Some(2));
        assert_eq!(state.extra["futureKey"], serde_json::json!(true));
    }

    #[test]
    fn an_unreadable_state_blocks_the_change() {
        let dir = tempfile::tempdir().unwrap();
        fs::create_dir_all(dir.path().join("memory")).unwrap();
        fs::write(dir.path().join(EVIDENCE_FILE), "not json").unwrap();
        let meeting = meeting(Utc::now());
        let mut ran = false;
        assert!(
            with_meeting_mutation(dir.path(), &[&meeting], || {
                ran = true;
                Ok(())
            })
            .is_err()
        );
        assert!(!ran);
        assert!(read_state(dir.path()).is_none());
    }

    #[test]
    fn invalidation_follows_dream_models() {
        let mut state = EvidenceState {
            revision: 5,
            ..Default::default()
        };
        state.invalidated_days.insert("2026-10-15".into(), 5);
        state.invalidated_meetings = Some(BTreeMap::from([("ABC".to_string(), 4)]));
        state.invalidated_activity_days = Some(BTreeMap::from([("2026-10-20".to_string(), 5)]));
        let source = |kind: &str, id: &str, day: &str| Source {
            kind: kind.into(),
            id: id.into(),
            day_key: day.into(),
        };
        let built = |revision, sources| Provenance {
            sources,
            revision,
            includes_unattributed_context: false,
        };

        assert!(state.invalidates(None));
        assert!(state.invalidates(Some(&built(4, vec![source("meeting", "x", "2026-10-15")]))));
        assert!(!state.invalidates(Some(&built(5, vec![source("meeting", "x", "2026-10-15")]))));
        assert!(state.invalidates(Some(&built(
            3,
            vec![source("meeting", "abc", "2026-09-01")]
        ))));
        assert!(!state.invalidates(Some(&built(
            4,
            vec![source("meeting", "abc", "2026-09-01")]
        ))));
        // Activity-only changes leave meeting sources alone.
        assert!(!state.invalidates(Some(&built(4, vec![source("meeting", "y", "2026-10-20")]))));
        assert!(state.invalidates(Some(&built(
            4,
            vec![source("screenDay", "2026-10-20", "2026-10-20")]
        ))));
        assert!(state.invalidates(Some(&built(4, vec![]))));
        assert!(!EvidenceState::default().invalidates(None));
    }

    #[test]
    fn work_memory_leaves_out_what_a_changed_meeting_built() {
        let dir = tempfile::tempdir().unwrap();
        let started = Utc.with_ymd_and_hms(2026, 10, 15, 9, 0, 0).unwrap();
        let meeting = meeting(started);
        let built = |id: &str, day: &str| serde_json::json!({"sources": [{"kind": "meeting", "id": id, "dayKey": day}], "revision": 0});
        fs::create_dir_all(dir.path().join("memory")).unwrap();
        let memory = serde_json::json!({
            "version": 3,
            "activeProjects": [
                {"name": "Orion", "provenance": built("4e1c1b59-6e0b-4f38-9e57-3c1b1f0a2d11", "2026-10-15")},
                {"name": "Atlas", "provenance": built("0D0F7C2E-0000-4000-8000-000000000000", "2026-09-01")},
                {"name": "Legacy"}
            ],
            "workGoals": [],
            "recurringPatterns": ["Standups run long", "Fridays are quiet"],
            "patternProvenance": {
                "Standups run long": built("4E1C1B59-6E0B-4F38-9E57-3C1B1F0A2D11", "2026-10-15"),
                "Fridays are quiet": built("0D0F7C2E-0000-4000-8000-000000000000", "2026-09-01")
            }
        });
        fs::write(dir.path().join(MEMORY_FILE), memory.to_string()).unwrap();
        assert_eq!(
            read_work_memory(dir.path()).unwrap(),
            fs::read(dir.path().join(MEMORY_FILE)).unwrap()
        );

        with_meeting_mutation(dir.path(), &[&meeting], || Ok(())).unwrap();
        let read: serde_json::Value =
            serde_json::from_slice(&read_work_memory(dir.path()).unwrap()).unwrap();
        let names: Vec<_> = read["activeProjects"]
            .as_array()
            .unwrap()
            .iter()
            .map(|p| p["name"].as_str().unwrap())
            .collect();
        assert_eq!(names, ["Atlas"]);
        assert_eq!(
            read["recurringPatterns"],
            serde_json::json!(["Fridays are quiet"])
        );
        assert_eq!(
            read["patternProvenance"]
                .as_object()
                .unwrap()
                .keys()
                .collect::<Vec<_>>(),
            ["Fridays are quiet"]
        );
        assert_eq!(read["version"], 3);
    }

    fn day(text: &str) -> NaiveDate {
        NaiveDate::parse_from_str(text, "%Y-%m-%d").unwrap()
    }

    fn write_journal(root: &Path, key: &str, body: &str, digest: Option<&str>) {
        fs::create_dir_all(root.join("journal")).unwrap();
        fs::write(root.join("journal").join(format!("{key}.md")), body).unwrap();
        if let Some(digest) = digest {
            let meta = serde_json::json!({
                "version": 2,
                "quality": "complete",
                "generatedAt": 800_000_000.0,
                "journalModifiedAt": 800_000_000.0,
                "degradedAttemptCount": 0,
                "journalDigest": digest,
            });
            fs::write(
                root.join("journal").join(format!("{key}.meta.json")),
                meta.to_string(),
            )
            .unwrap();
        }
    }

    #[test]
    fn a_removal_retracts_only_the_unedited_generated_journal() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        let generated = crate::library::sha256_hex(b"generated");
        write_journal(root, "2026-10-01", "generated", Some(&generated));
        write_journal(root, "2026-10-02", "edited by hand", Some(&generated));
        write_journal(root, "2026-10-03", "written long ago", None);
        retract_generated_journals(
            root,
            [day("2026-10-01"), day("2026-10-02"), day("2026-10-03")],
        )
        .unwrap();
        assert!(!root.join("journal/2026-10-01.md").exists());
        assert!(!root.join("journal/2026-10-01.meta.json").exists());
        assert!(root.join("journal/2026-10-02.md").exists());
        assert!(root.join("journal/2026-10-02.meta.json").exists());
        assert!(root.join("journal/2026-10-03.md").exists());
    }

    #[test]
    fn deleting_a_meeting_withdraws_that_days_generated_journal_and_reprocessing_keeps_it() {
        let dir = tempfile::tempdir().unwrap();
        let library = crate::Library::open(crate::LibraryPaths::new(dir.path())).unwrap();
        let at = Utc.with_ymd_and_hms(2026, 10, 15, 12, 0, 0).unwrap();
        let meeting = library.create_meeting("Sync", "Zoom", at).unwrap();
        let meta = serde_json::from_value(serde_json::json!({
            "version": 2,
            "quality": "complete",
            "generatedAt": 800_000_000.0,
        }))
        .unwrap();
        let day = crate::time::local_day(at);
        library.save_digest(day, "the digest", &meta).unwrap();

        // Reprocessing revises the source: the digest stays, marked out of date.
        with_meeting_mutation(dir.path(), &[&meeting], || Ok(())).unwrap();
        assert!(library.journal_path(day).exists());

        library.delete_meeting(&meeting).unwrap();
        assert!(!library.journal_path(day).exists());

        // A journal the person edited is theirs and stays.
        library.save_digest(day, "the digest", &meta).unwrap();
        fs::write(library.journal_path(day), "my own words").unwrap();
        let other = library.create_meeting("Other", "Zoom", at).unwrap();
        library.delete_meeting(&other).unwrap();
        assert_eq!(
            fs::read_to_string(library.journal_path(day)).unwrap(),
            "my own words"
        );
    }

    #[test]
    fn an_interrupted_mac_write_still_counts_as_generated() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        let digest = crate::library::sha256_hex(b"generated");
        write_journal(root, "2026-10-01", "generated", None);
        let pending = serde_json::json!({
            "version": 1,
            "journalDigest": digest,
            "quality": "complete",
            "generatedAt": 800_000_000.0,
        });
        fs::write(
            root.join("journal/2026-10-01.write.json"),
            pending.to_string(),
        )
        .unwrap();
        retract_generated_journals(root, [day("2026-10-01")]).unwrap();
        assert!(!root.join("journal/2026-10-01.md").exists());
        assert!(!root.join("journal/2026-10-01.write.json").exists());

        // Rewriting identical bytes that may never have landed stays the person's.
        write_journal(root, "2026-10-02", "generated", None);
        let pending = serde_json::json!({
            "version": 1,
            "expectedJournalDigest": digest,
            "journalDigest": digest,
            "quality": "complete",
            "generatedAt": 800_000_000.0,
        });
        fs::write(
            root.join("journal/2026-10-02.write.json"),
            pending.to_string(),
        )
        .unwrap();
        retract_generated_journals(root, [day("2026-10-02")]).unwrap();
        assert!(root.join("journal/2026-10-02.md").exists());
    }

    #[test]
    fn a_screen_change_withdraws_screen_days_and_keeps_meeting_facts() {
        let dir = tempfile::tempdir().unwrap();
        let at = Utc.with_ymd_and_hms(2026, 10, 15, 12, 0, 0).unwrap();
        let mut ran = false;
        with_screen_mutation(dir.path(), &[at], EvidenceChange::Revision, || {
            ran = true;
            Ok(())
        })
        .unwrap();
        assert!(ran);
        let state = read_state(dir.path()).unwrap();
        assert_eq!(state.revision, 1);
        assert!(state.invalidated_days.is_empty());
        let activity = state.invalidated_activity_days.as_ref().unwrap();
        assert_eq!(activity.len(), 5);
        assert_eq!(activity["2026-10-15"], 1);
        let source = |kind: &str| Source {
            kind: kind.into(),
            id: "2026-10-15".into(),
            day_key: "2026-10-15".into(),
        };
        let built = |source| Provenance {
            sources: vec![source],
            revision: 0,
            includes_unattributed_context: false,
        };
        assert!(state.invalidates(Some(&built(source("screenDay")))));
        assert!(!state.invalidates(Some(&built(source("meeting")))));
    }

    #[test]
    fn a_screen_change_blocked_by_unreadable_state_leaves_the_source() {
        let dir = tempfile::tempdir().unwrap();
        fs::create_dir_all(dir.path().join("memory")).unwrap();
        fs::write(dir.path().join(EVIDENCE_FILE), "not json").unwrap();
        let mut ran = false;
        assert!(
            with_screen_mutation(dir.path(), &[Utc::now()], EvidenceChange::Removal, || {
                ran = true;
                Ok(())
            })
            .is_err()
        );
        assert!(!ran);
    }

    #[test]
    fn a_pending_macos_revocation_makes_memory_unavailable() {
        let dir = tempfile::tempdir().unwrap();
        assert_eq!(read_state(dir.path()), Some(EvidenceState::default()));
        fs::write(dir.path().join(PENDING_FILE), "[]").unwrap();
        assert!(read_state(dir.path()).is_none());
    }
}
