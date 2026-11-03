//! Runs the library health check (`AppState.runHealthCheckNow`,
//! `LibraryHealthScheduler`). Released builds check only on request; development
//! builds check the previous day each morning and catch up at launch when the
//! last run is over a day old.

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use anyhow::Result;
use chrono::{DateTime, Local, NaiveDate, TimeZone as _, Utc};
use lokalbot_core::health::{self, HealthReport};
use lokalbot_core::time::local_day;
use lokalbot_core::{Library, Settings};

use crate::Shared;

const DEFAULT_HOUR: u32 = 9;
const CATCH_UP_SECONDS: i64 = 24 * 60 * 60;

/// The report for `day` without writing anything.
pub fn report(
    library: &Library,
    settings: &Settings,
    day: NaiveDate,
    now: DateTime<Utc>,
) -> Result<HealthReport> {
    let input = library.health_input(
        day,
        now,
        settings,
        lokalbot_ai::think::allows_automatic_main_inference(settings),
    )?;
    Ok(health::evaluate(
        &input,
        &day.format("%Y-%m-%d").to_string(),
    ))
}

/// Checks the previous day and writes the report; returns its Markdown path.
pub fn run_now(library: &Library, settings: &Settings) -> Result<PathBuf> {
    let now = Utc::now();
    let yesterday = local_day(now) - chrono::Duration::days(1);
    library.write_health_report(&report(library, settings, yesterday, now)?)
}

/// `LibraryHealthScheduler.shouldRun`.
pub fn should_run(at: DateTime<Utc>, last_run: Option<DateTime<Utc>>, hour: u32) -> bool {
    let Some(last_run) = last_run else {
        return true;
    };
    if (at - last_run).num_seconds() >= CATCH_UP_SECONDS {
        return true;
    }
    let day = local_day(at);
    let target = day
        .and_hms_opt(hour.min(23), 0, 0)
        .and_then(|local| Local.from_local_datetime(&local).earliest())
        .map(|local| local.with_timezone(&Utc));
    target.is_some_and(|target| at >= target && last_run < target)
}

/// Development builds only: PRIVACY.md promises released builds check on request.
pub(crate) fn start(shared: Arc<Shared>) {
    if !cfg!(debug_assertions) {
        return;
    }
    let spawned = std::thread::Builder::new()
        .name("lokalbot-health".into())
        .spawn(move || {
            while !shared.is_shutting_down() {
                let now = Utc::now();
                if should_run(now, shared.library.latest_health_run(), DEFAULT_HOUR) {
                    let settings = shared.settings();
                    if let Err(err) = run_now(&shared.library, &settings) {
                        log::warn!("health report write failed: {err:#}");
                    }
                }
                for _ in 0..60 {
                    if shared.is_shutting_down() {
                        return;
                    }
                    std::thread::sleep(Duration::from_secs(1));
                }
            }
        });
    if let Err(err) = spawned {
        log::warn!("could not start the health check: {err}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Duration as Span;

    #[test]
    fn it_runs_first_then_after_a_day_or_when_the_hour_passes() {
        let at = Utc::now();
        assert!(should_run(at, None, 9));
        assert!(should_run(at, Some(at - Span::hours(25)), 9));
        assert!(!should_run(at, Some(at), 9));
        let day = local_day(at);
        let local = |hour| {
            Local
                .from_local_datetime(&day.and_hms_opt(hour, 0, 0).unwrap())
                .earliest()
                .unwrap()
                .with_timezone(&Utc)
        };
        assert!(should_run(local(10), Some(local(8)), 9));
        assert!(!should_run(local(10), Some(local(9)), 9));
        assert!(!should_run(local(8), Some(local(7)), 9));
    }

    #[test]
    fn a_check_writes_yesterdays_report() {
        let dir = tempfile::tempdir().unwrap();
        let library = Library::open(lokalbot_core::LibraryPaths::new(dir.path())).unwrap();
        let path = run_now(&library, &Settings::default()).unwrap();
        let yesterday = local_day(Utc::now()) - Span::days(1);
        assert_eq!(
            path,
            dir.path()
                .join("diagnostics/health")
                .join(format!("{}.md", yesterday.format("%Y-%m-%d")))
        );
        assert!(path.with_extension("json").is_file());
        assert!(library.latest_health_run().is_some());
    }
}
