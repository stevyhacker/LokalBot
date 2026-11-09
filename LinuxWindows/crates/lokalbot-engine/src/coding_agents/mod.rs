//! Keeps stored coding-agent evidence in step with the agents' transcripts
//! (`CodingAgentEvidenceIngestor.swift`).
//!
//! Scans run on a background thread over a recent window. Only settled bursts
//! are stored, so a digest's inputs cannot change while it is written. New
//! bursts are plain additions. Removing or correcting a stored burst (a deleted
//! session, a new folder exclusion) withdraws dependent products through the
//! same path as deleting screen evidence. A read failure is never taken as a
//! deletion.
//!
//! Nothing under `~/.claude` or `~/.codex` is opened until the person has chosen
//! to allow it: [`Settings::enabled_coding_agents`] is empty before that.

mod builder;
mod cache;
mod claude;
mod codex;
mod scanner;
#[cfg(test)]
mod tests;
pub mod text;

use std::collections::{BTreeSet, HashMap, HashSet};
use std::sync::Arc;
use std::time::{Duration, Instant};

use anyhow::Result;
use chrono::{DateTime, Local, NaiveDate, Utc};
use lokalbot_core::coding_agents::{CodingAgentBurst, CodingAgentKind};
use lokalbot_core::evidence::{self, EvidenceChange};
use lokalbot_core::time::{local_day, local_day_bounds};
use lokalbot_core::{Library, Settings};
use parking_lot::Mutex;

use crate::{EngineEvent, Shared};
use cache::ParseCache;
use scanner::{DayScan, Scanner};

/// Matches the digest scheduler's catch-up window (`DayDigestScheduler.catchUpDays`).
pub const WINDOW_DAYS: i64 = 7;
const REFRESH_INTERVAL: Duration = Duration::from_secs(10 * 60);
/// The first refresh parses every transcript in the window, so it waits for the
/// app to finish starting.
const FIRST_REFRESH_DELAY: Duration = Duration::from_secs(30);

/// What a scan reads and keeps.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Configuration {
    pub agents: Vec<CodingAgentKind>,
    pub excluded_folders: Vec<String>,
    /// Agent text expires with screen text; `None` keeps it indefinitely.
    pub retention_days: Option<u32>,
}

impl Configuration {
    pub fn new(settings: &Settings) -> Self {
        Self {
            agents: settings.enabled_coding_agents(),
            excluded_folders: settings.coding_agent_excluded_folder_list(),
            retention_days: (!settings.keep_ocr_text_forever).then_some(settings.retention_days),
        }
    }
}

fn start_of_day(at: DateTime<Utc>) -> DateTime<Utc> {
    local_day_bounds(local_day(at)).0
}

fn session_day(burst: &CodingAgentBurst) -> (String, NaiveDate) {
    (burst.session_key(), local_day(burst.start))
}

/// Sessions on days before `today` whose stored bursts hold the same work, in
/// order, as the scan's. Ids follow a burst's first event, so a moved edge reads
/// as a different burst; the work does not.
fn session_days_with_unchanged_work(
    existing: &[CodingAgentBurst],
    fresh: &[CodingAgentBurst],
    today: DateTime<Utc>,
) -> HashSet<(String, NaiveDate)> {
    fn by_session_day(
        bursts: &[CodingAgentBurst],
        today: DateTime<Utc>,
    ) -> HashMap<(String, NaiveDate), Vec<&CodingAgentBurst>> {
        let mut ordered: Vec<&CodingAgentBurst> =
            bursts.iter().filter(|burst| burst.start < today).collect();
        ordered.sort_by_key(|burst| burst.start);
        let mut groups: HashMap<_, Vec<&CodingAgentBurst>> = HashMap::new();
        for burst in ordered {
            groups.entry(session_day(burst)).or_default().push(burst);
        }
        groups
    }
    let rescanned = by_session_day(fresh, today);
    by_session_day(existing, today)
        .into_iter()
        .filter(|(key, stored)| {
            rescanned.get(key).is_some_and(|scanned| {
                scanned.len() == stored.len()
                    && stored.iter().zip(scanned).all(|(a, b)| a.has_same_work(b))
            })
        })
        .map(|(key, _)| key)
        .collect()
}

/// Stores settled bursts from `scan`, replacing what the store holds for the
/// scanned agents and days. Returns the days that changed.
pub fn apply_scan(
    library: &Library,
    scan: &DayScan,
    configuration: &Configuration,
    scanned_at: DateTime<Utc>,
) -> Result<Vec<NaiveDate>> {
    let cutoff = configuration
        .retention_days
        .map(|days| scanned_at - chrono::Duration::days(i64::from(days)));
    let mut fresh: Vec<CodingAgentBurst> = scan
        .bursts
        .iter()
        .filter(|burst| {
            burst.is_settled(scanned_at)
                && configuration.agents.contains(&burst.agent)
                && cutoff.is_none_or(|cutoff| burst.end >= cutoff)
        })
        .cloned()
        .collect();
    let mut existing: Vec<CodingAgentBurst> = library
        .coding_agent_bursts(scan.start, scan.end)?
        .into_iter()
        .filter(|burst| configuration.agents.contains(&burst.agent))
        .collect();
    // A finished day keeps the bursts its digest and overnight review were
    // written with until a session's work there changes or the session is gone.
    // Sessions that moved to another branch would otherwise relabel earlier
    // days' bursts, and each relabel would rebuild those days' digests.
    let today = start_of_day(scanned_at);
    let unchanged = session_days_with_unchanged_work(&existing, &fresh, today);
    fresh.retain(|burst| !unchanged.contains(&session_day(burst)));
    existing.retain(|burst| !unchanged.contains(&session_day(burst)));
    let fresh_ids: HashSet<String> = fresh.iter().map(CodingAgentBurst::id).collect();
    let existing_by_id: HashMap<String, &CodingAgentBurst> =
        existing.iter().map(|burst| (burst.id(), burst)).collect();

    let added: Vec<CodingAgentBurst> = fresh
        .iter()
        .filter(|burst| !existing_by_id.contains_key(&burst.id()))
        .cloned()
        .collect();
    let corrected: Vec<CodingAgentBurst> = fresh
        .iter()
        .filter(|burst| {
            existing_by_id.get(&burst.id()).is_some_and(|stored| {
                !stored.is_same_as_stored(burst)
                    && (burst.start >= today || !stored.has_same_work(burst))
            })
        })
        .cloned()
        .collect();
    // An unreadable transcript is not a deleted one.
    let removed: Vec<&CodingAgentBurst> = if scan.unreadable_files.is_empty() {
        existing
            .iter()
            .filter(|burst| !fresh_ids.contains(&burst.id()))
            .collect()
    } else {
        Vec::new()
    };

    let revoked: Vec<DateTime<Utc>> = removed
        .iter()
        .copied()
        .chain(corrected.iter())
        .map(|burst| burst.start)
        .collect();
    if !revoked.is_empty() {
        let removed_ids: Vec<String> = removed.iter().map(|burst| burst.id()).collect();
        evidence::with_screen_mutation(
            library.paths().root(),
            &revoked,
            EvidenceChange::Revision,
            || {
                library.delete_coding_agent_bursts(&removed_ids)?;
                library.upsert_coding_agent_bursts(&corrected)
            },
        )?;
    }
    library.upsert_coding_agent_bursts(&added)?;
    let days: BTreeSet<NaiveDate> = added
        .iter()
        .chain(corrected.iter())
        .chain(removed.iter().copied())
        .map(|burst| local_day(burst.start))
        .collect();
    Ok(days.into_iter().collect())
}

/// The refresh state: one scan runs at a time, and each reuses what the last
/// one parsed, so a refresh parses only the lines agents appended since.
#[derive(Default)]
pub struct Ingestor {
    cache: ParseCache,
    running: Mutex<()>,
    last_error: Mutex<Option<String>>,
}

impl Ingestor {
    pub fn last_error(&self) -> Option<String> {
        self.last_error.lock().clone()
    }

    /// Scans the recent window, plus `day` when it is older, and stores what
    /// changed. Does nothing until the person has allowed reading.
    pub fn refresh(
        &self,
        library: &Library,
        settings: impl Fn() -> Settings,
        day: Option<NaiveDate>,
    ) -> Vec<NaiveDate> {
        let Some(home) = std::env::home_dir() else {
            return Vec::new();
        };
        self.refresh_from(library, &home, settings, day, Utc::now())
    }

    fn refresh_from(
        &self,
        library: &Library,
        home: &std::path::Path,
        settings: impl Fn() -> Settings,
        day: Option<NaiveDate>,
        now: DateTime<Utc>,
    ) -> Vec<NaiveDate> {
        let configuration = Configuration::new(&settings());
        // Before anything opens a file: this is the consent gate.
        if configuration.agents.is_empty() || library.is_read_only() {
            return Vec::new();
        }
        let _running = self.running.lock();
        let scanner = Scanner::standard(
            home,
            &configuration.agents,
            configuration.excluded_folders.clone(),
        );
        let today = local_day(now);
        let window_start = today - chrono::Duration::days(WINDOW_DAYS - 1);
        let mut ranges = vec![(window_start, today, true)];
        if let Some(day) = day.filter(|day| *day < window_start) {
            // An older day reaches past what the cache keeps: reading it there
            // would reparse the window's files and drop the rest.
            ranges.push((day, day, false));
        }
        let mut changed = BTreeSet::new();
        for (first, last, cached) in ranges {
            let scan = scanner.scan(first, last, cached.then_some(&self.cache));
            log::debug!(
                "coding-agent scan: {} sessions, {} files, {} bytes, {} unreadable, {} excluded",
                scan.session_count,
                scan.files_read,
                scan.bytes_read,
                scan.unreadable_files.len(),
                scan.excluded_sessions
            );
            // Turning the feature off, deleting saved sessions or adding an
            // exclusion during the scan must not be undone by its result.
            if Configuration::new(&settings()) != configuration {
                break;
            }
            match apply_scan(library, &scan, &configuration, now) {
                Ok(days) => {
                    changed.extend(days);
                    *self.last_error.lock() = None;
                }
                Err(err) => {
                    log::warn!("coding-agent evidence update failed: {err:#}");
                    *self.last_error.lock() = Some(format!("{err:#}"));
                }
            }
        }
        changed.into_iter().collect()
    }
}

/// Refreshes every ten minutes while reading is allowed.
pub(crate) fn start(shared: Arc<Shared>) {
    let spawned = std::thread::Builder::new()
        .name("lokalbot-coding-agents".into())
        .spawn(move || {
            let mut next = Instant::now() + FIRST_REFRESH_DELAY;
            while !shared.is_shutting_down() {
                std::thread::sleep(Duration::from_secs(1));
                if Instant::now() < next {
                    continue;
                }
                next = Instant::now() + REFRESH_INTERVAL;
                refresh(&shared, None);
            }
        });
    if let Err(err) = spawned {
        log::warn!("could not start reading coding-agent sessions: {err}");
    }
}

/// One refresh, reporting what changed.
pub(crate) fn refresh(shared: &Arc<Shared>, day: Option<NaiveDate>) {
    let changed = shared
        .coding_agents
        .refresh(&shared.library, || shared.settings(), day);
    if !changed.is_empty() {
        let today = Local::now().date_naive();
        log::info!(
            "coding-agent evidence changed on {} day(s), today: {}",
            changed.len(),
            changed.contains(&today)
        );
        shared.emit(EngineEvent::LibraryChanged);
    }
}
