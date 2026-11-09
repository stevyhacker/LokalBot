//! Applies the retention window from Privacy settings: at startup, then every
//! six hours (`ScreenshotService.performRetentionPrune`). Window titles older
//! than the window are cleared; meetings are never touched.
//!
//! A scheduled pass isn't a deletion: nobody deleted or corrected what expired,
//! so digests and overnight memory stay. Exports and routines still look again,
//! and answers reused from those days are forgotten
//! (`AppState.withScheduledRetention`).

use std::sync::Arc;
use std::time::{Duration, Instant};

use chrono::Utc;

use crate::{EngineEvent, RetentionStatus, Shared};

const FIRST_PASS_DELAY: Duration = Duration::from_secs(30);
const INTERVAL: Duration = Duration::from_secs(6 * 60 * 60);

fn run_pass(shared: &Shared) {
    let settings = shared.settings();
    let now = Utc::now();
    let error = match shared.library.apply_retention(&settings, now) {
        Ok(report) => {
            log::info!(
                "retention pass: {} images, {} texts, {} titles, {} agent sessions, {} orphans, {} failures",
                report.pixels_removed,
                report.texts_removed,
                report.activity_titles_cleared,
                report.agent_sessions_removed,
                report.orphans_removed,
                report.failures.len()
            );
            if !report.days.is_empty() {
                let mut days: Vec<_> = report
                    .days
                    .iter()
                    .map(|at| lokalbot_core::time::local_day(*at))
                    .collect();
                days.sort_unstable();
                days.dedup();
                lokalbot_ai::digest::purge_cache(&days);
                shared.exports.reconsider_daily(&days);
                shared.routines.reconsider_evidence();
                shared.emit(EngineEvent::LibraryChanged);
            }
            (!report.failures.is_empty()).then(|| report.failures.join("\n"))
        }
        Err(err) => {
            log::warn!("retention pass failed: {err:#}");
            Some(format!("{err:#}"))
        }
    };
    let status = RetentionStatus {
        last_run: Some(now),
        last_error: error,
    };
    *shared.retention.lock() = status.clone();
    shared.emit(EngineEvent::Retention(status));
}

/// "Run retention now".
pub fn run_now(shared: Arc<Shared>) {
    let spawned = std::thread::Builder::new()
        .name("lokalbot-retention-now".into())
        .spawn(move || run_pass(&shared));
    if let Err(err) = spawned {
        log::warn!("could not run retention: {err}");
    }
}

pub fn start(shared: Arc<Shared>) {
    let spawned = std::thread::Builder::new()
        .name("lokalbot-retention".into())
        .spawn(move || {
            // A pass from before this launch still counts for Settings.
            shared.emit(EngineEvent::Retention(RetentionStatus {
                last_run: shared.library.last_retention_pass(),
                last_error: None,
            }));
            let mut next = Instant::now() + FIRST_PASS_DELAY;
            while !shared.is_shutting_down() {
                std::thread::sleep(Duration::from_secs(1));
                if Instant::now() < next {
                    continue;
                }
                next = Instant::now() + INTERVAL;
                run_pass(&shared);
            }
        });
    if let Err(err) = spawned {
        log::warn!("could not start retention: {err}");
    }
}
