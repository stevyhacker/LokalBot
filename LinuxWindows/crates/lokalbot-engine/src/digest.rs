//! The day digest: written automatically after `dayDigestHour`, or on request
//! (`DayDigestScheduler.swift`). Past days are finalized once after the local date
//! changes, oldest first and at most seven days back: rewriting a journal after
//! its day ended is a durable marker, so late work after the evening preview is
//! included, and a past day's new digest reopens that day's overnight review.

use std::collections::{HashMap, HashSet};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use anyhow::{Result, anyhow};
use chrono::{Local, NaiveDate, Timelike as _};
use lokalbot_core::health::PastDay;
use lokalbot_core::model::DigestQuality;
use parking_lot::Mutex;

use crate::models::Models;
use crate::{BackgroundItem, BackgroundKind, EngineEvent, Shared};

/// Wait this long after a failed automatic run before trying again.
const FAILURE_BACKOFF: Duration = Duration::from_secs(15 * 60);
/// Yesterday plus the six days before it.
const CATCH_UP_DAYS: i64 = 7;

/// Oldest past day still needing its final digest (`generationDay`).
fn pending_past_day(
    days: &[PastDay],
    skipped: &HashSet<NaiveDate>,
    cooling_down: &dyn Fn(NaiveDate) -> bool,
) -> Option<NaiveDate> {
    days.iter()
        .filter(|past| past.needs_finalization())
        .map(|past| past.day)
        .filter(|day| !skipped.contains(day) && !cooling_down(*day))
        .min()
}

pub struct DigestScheduler {
    shared: Arc<Shared>,
    models: Models,
    running: Arc<AtomicBool>,
    stop: Arc<AtomicBool>,
}

impl DigestScheduler {
    pub fn start(shared: Arc<Shared>, models: Models) -> Self {
        let scheduler = Self {
            shared,
            models,
            running: Arc::new(AtomicBool::new(false)),
            stop: Arc::new(AtomicBool::new(false)),
        };
        let shared = scheduler.shared.clone();
        let models = scheduler.models.clone();
        let running = scheduler.running.clone();
        let stop = scheduler.stop.clone();
        std::thread::Builder::new()
            .name("lokalbot-digest".into())
            .spawn(move || {
                let last_failure: Mutex<Option<Instant>> = Mutex::new(None);
                // Past days with nothing to digest, skipped until evidence changes.
                let mut deferred: HashSet<NaiveDate> = HashSet::new();
                // A degraded past day backs off alone, so later days still run.
                let mut repair_after: HashMap<NaiveDate, Instant> = HashMap::new();
                // Days before yesterday proven final, so ticks don't re-read them.
                let mut settled: HashSet<NaiveDate> = HashSet::new();
                let mut scan_today: Option<NaiveDate> = None;
                while !stop.load(Ordering::Relaxed) {
                    std::thread::sleep(Duration::from_secs(60));
                    let settings = shared.settings();
                    if !settings.day_digest_auto_enabled {
                        continue;
                    }
                    if last_failure
                        .lock()
                        .is_some_and(|at| at.elapsed() < FAILURE_BACKOFF)
                    {
                        continue;
                    }
                    // Not downtime yet: don't burn the backoff.
                    if !lokalbot_ai::think::allows_automatic_main_inference(&settings)
                        || shared.capture_active.load(Ordering::Relaxed)
                        || shared.dictation_working.load(Ordering::Relaxed)
                        || shared.autocomplete_generating.load(Ordering::Relaxed)
                        || shared.pipeline_busy.load(Ordering::Relaxed)
                        || running.load(Ordering::Relaxed)
                    {
                        continue;
                    }
                    if !models.missing(&models.think_requirements()).is_empty() {
                        continue;
                    }
                    let today = Local::now().date_naive();
                    if scan_today != Some(today) {
                        scan_today = Some(today);
                        deferred.clear();
                        repair_after.clear();
                        settled.clear();
                    }
                    let changed: Vec<NaiveDate> =
                        shared.digest_invalidated.lock().iter().copied().collect();
                    if !changed.is_empty() {
                        deferred.clear();
                        repair_after.clear();
                        settled.retain(|day| !changed.contains(day));
                    }
                    // Past days take priority until each is final.
                    let past_days: Vec<PastDay> = (1..=CATCH_UP_DAYS)
                        .map(|back| today - chrono::Duration::days(back))
                        .filter(|day| !settled.contains(day))
                        .map(|day| past_day(&shared.library, day, changed.contains(&day)))
                        .collect();
                    let yesterday = today - chrono::Duration::days(1);
                    settled.extend(
                        past_days
                            .iter()
                            .filter(|past| past.day < yesterday && !past.needs_finalization())
                            .map(|past| past.day),
                    );
                    let cooling = |day: NaiveDate| {
                        repair_after
                            .get(&day)
                            .is_some_and(|at| Instant::now() < *at)
                    };
                    if let Some(day) = pending_past_day(&past_days, &deferred, &cooling) {
                        match generate(&shared, &running, day, true) {
                            Ok(Outcome::Completed) => {
                                shared.digest_invalidated.lock().remove(&day);
                            }
                            Ok(Outcome::Deferred) => {
                                deferred.insert(day);
                            }
                            Ok(Outcome::NeedsRepair) => {
                                repair_after.insert(day, Instant::now() + FAILURE_BACKOFF);
                            }
                            Err(_) => *last_failure.lock() = Some(Instant::now()),
                        }
                        continue;
                    }
                    if Local::now().hour() < settings.day_digest_hour {
                        continue;
                    }
                    let needs = match shared.library.day_digest(today) {
                        Ok(None) => true,
                        Ok(Some(digest)) => digest.is_stale && digest.meta.is_some(),
                        Err(_) => false,
                    };
                    if needs && generate(&shared, &running, today, true).is_err() {
                        *last_failure.lock() = Some(Instant::now());
                    }
                }
            })
            .expect("spawning the digest thread");
        scheduler
    }

    pub fn regenerate(&self, day: NaiveDate) {
        if self.running.load(Ordering::Relaxed) {
            self.shared.message("The digest is already being written.");
            return;
        }
        if !self
            .models
            .missing(&self.models.think_requirements())
            .is_empty()
        {
            self.shared.error(
                "Writing the digest needs the Think model. Download it in Settings → Models.",
            );
            return;
        }
        let shared = self.shared.clone();
        let running = self.running.clone();
        std::thread::spawn(move || {
            if let Err(err) = generate(&shared, &running, day, false) {
                shared.error(format!("The digest could not be written: {err:#}"));
            }
        });
    }

    pub fn stop(&self) {
        self.stop.store(true, Ordering::Relaxed);
    }
}

/// `DayDigestScheduler.GenerationOutcome`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Outcome {
    Completed,
    /// Nothing to digest yet.
    Deferred,
    /// A degraded journal stays readable and is quietly repaired later.
    NeedsRepair,
}

/// `automaticCompletionAt` and the day's evidence, for `needs_finalization`. An
/// edited journal is the person's, so it is never replaced; a degraded one isn't
/// final; a changed source reopens the day when its signature no longer matches.
fn past_day(library: &lokalbot_core::Library, day: NaiveDate, changed: bool) -> PastDay {
    let digest = library.day_digest(day).ok().flatten();
    let meta = digest.as_ref().and_then(|d| d.meta.as_ref());
    let latest_evidence_at = library
        .latest_evidence_at(day)
        .ok()
        .flatten()
        // A deleted last meeting still leaves an owned journal to repair.
        .or(meta.map(|m| m.generated_at));
    let journal = library.journal_path(day);
    let owned = lokalbot_core::evidence::journal_is_generated(&journal);
    let completed = match (&digest, meta) {
        (None, _) => None,
        (Some(digest), None) => digest.modified_at,
        (Some(_), Some(_)) if !owned => {
            // Far in the future: past any midnight.
            Some(chrono::DateTime::<chrono::Utc>::MAX_UTC)
        }
        (Some(digest), Some(meta)) => {
            let matches = !changed
                || lokalbot_ai::digest::evidence_signatures(library, day)
                    .is_ok_and(|(content, _)| meta.evidence_signature.as_deref() == Some(&content));
            (meta.quality == DigestQuality::Complete && matches)
                .then_some(digest.modified_at)
                .flatten()
        }
    };
    PastDay {
        day,
        latest_evidence_at,
        digest_modified_at: completed,
    }
}

fn generate(
    shared: &Arc<Shared>,
    running: &AtomicBool,
    day: NaiveDate,
    automatic: bool,
) -> Result<Outcome> {
    if running.swap(true, Ordering::SeqCst) {
        return Err(anyhow!("already running"));
    }
    shared.emit(EngineEvent::Digest { running: Some(day) });
    let label = if day == Local::now().date_naive() {
        "Today".to_string()
    } else {
        day.format("%b %-d").to_string()
    };
    let background_id = format!("digest:{day}");
    shared.set_background(BackgroundItem {
        id: background_id.clone(),
        kind: BackgroundKind::Digest,
        title: format!("Day digest · {label}"),
        detail: "Preparing".into(),
        progress: None,
    });
    let result = (|| -> Result<Outcome> {
        // Sessions that settled since the last refresh belong in this digest.
        crate::coding_agents::refresh(shared, Some(day));
        if automatic
            && lokalbot_ai::digest::DayEvidence::load(&shared.library, day)?.is_empty()
            && !lokalbot_core::evidence::journal_is_generated(&shared.library.journal_path(day))
        {
            return Ok(Outcome::Deferred);
        }
        let settings = shared.settings();
        let think = shared.think(&settings)?;
        let (markdown, meta) = lokalbot_ai::digest::generate_day_digest(
            &think,
            &shared.library,
            day,
            &settings,
            &mut |detail: &str| {
                shared.set_background(BackgroundItem {
                    id: background_id.clone(),
                    kind: BackgroundKind::Digest,
                    title: format!("Day digest · {label}"),
                    detail: detail.to_string(),
                    progress: None,
                });
            },
        )?;
        shared.library.save_digest(day, &markdown, &meta)?;
        shared.companion.day_digest_changed(day);
        // Export may have run while the replacement digest was awaiting a model.
        shared
            .exports
            .digest_did_change(day, settings.retention_days);
        shared.routines.reconsider_evidence();
        crate::dreaming::digest_changed(shared, day);
        Ok(match meta.quality {
            DigestQuality::Complete => Outcome::Completed,
            DigestQuality::Partial | DigestQuality::Fallback => Outcome::NeedsRepair,
        })
    })();
    running.store(false, Ordering::SeqCst);
    shared.clear_background(&background_id);
    shared.emit(EngineEvent::Digest { running: None });
    shared.emit(EngineEvent::LibraryChanged);
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::{TimeZone as _, Utc};

    fn day(text: &str) -> NaiveDate {
        NaiveDate::parse_from_str(text, "%Y-%m-%d").unwrap()
    }

    fn at(text: &str) -> chrono::DateTime<Utc> {
        Utc.from_utc_datetime(
            &chrono::NaiveDateTime::parse_from_str(text, "%Y-%m-%d %H:%M").unwrap(),
        )
    }

    fn past(key: &str, evidence: Option<&str>, written: Option<&str>) -> PastDay {
        PastDay {
            day: day(key),
            latest_evidence_at: evidence.map(at),
            digest_modified_at: written.map(at),
        }
    }

    #[test]
    fn late_work_reopens_a_day_until_its_digest_is_written_after_it_ended() {
        let none = |_: NaiveDate| false;
        let days = [
            // Previewed that evening, then more work: not final yet.
            past(
                "2026-10-19",
                Some("2026-10-19 20:00"),
                Some("2026-10-19 18:00"),
            ),
            // Written the next morning: final.
            past(
                "2026-10-18",
                Some("2026-10-18 20:00"),
                Some("2026-10-20 01:00"),
            ),
            // Nothing happened that day.
            past("2026-10-17", None, None),
        ];
        assert_eq!(
            pending_past_day(&days, &HashSet::new(), &none),
            Some(day("2026-10-19"))
        );
    }

    #[test]
    fn the_oldest_goes_first_and_a_skipped_day_doesnt_block_later_ones() {
        let none = |_: NaiveDate| false;
        let days = [
            past("2026-10-19", Some("2026-10-19 20:00"), None),
            past("2026-10-15", Some("2026-10-15 20:00"), None),
        ];
        assert_eq!(
            pending_past_day(&days, &HashSet::new(), &none),
            Some(day("2026-10-15"))
        );
        assert_eq!(
            pending_past_day(&days, &HashSet::from([day("2026-10-15")]), &none),
            Some(day("2026-10-19"))
        );
        let cooling = |d: NaiveDate| d == day("2026-10-15");
        assert_eq!(
            pending_past_day(&days, &HashSet::new(), &cooling),
            Some(day("2026-10-19"))
        );
    }
}
