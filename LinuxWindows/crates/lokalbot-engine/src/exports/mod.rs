pub mod daily;
pub mod meeting_notes;
#[cfg(test)]
mod tests;

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant, SystemTime};

use chrono::{DateTime, Local, NaiveDate, Timelike as _};
use lokalbot_core::Settings;
use parking_lot::Mutex;
use uuid::Uuid;

use crate::Shared;

pub const CATCH_UP_DAYS: i64 = 7;
const TICK: Duration = Duration::from_secs(60);
const RETRY: Duration = Duration::from_secs(15 * 60);

pub(crate) fn single_line(value: &str) -> String {
    value.split_whitespace().collect::<Vec<_>>().join(" ")
}

pub(crate) fn inline(value: &str) -> String {
    single_line(value)
        .replace('\\', "\\\\")
        .replace('`', "\\`")
        .replace('*', "\\*")
        .replace('_', "\\_")
        .replace('[', "\\[")
        .replace(']', "\\]")
        .replace('|', "\\|")
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct NoteConfiguration {
    enabled: bool,
    destination: meeting_notes::Configuration,
}

impl NoteConfiguration {
    fn new(settings: &Settings) -> Self {
        Self {
            enabled: settings.meeting_note_export_enabled
                && !settings.meeting_note_export_folder.is_empty(),
            destination: meeting_notes::Configuration {
                destination: PathBuf::from(&settings.meeting_note_export_folder),
                format: settings.meeting_note_export_format,
                includes_transcript: settings.meeting_note_export_includes_transcript,
            },
        }
    }
}

#[derive(Default)]
struct NoteState {
    configuration: Option<NoteConfiguration>,
    fingerprints: HashMap<Uuid, String>,
    pending: bool,
    retry_after: Option<Instant>,
    curation_stamp: Option<(Option<SystemTime>, Option<SystemTime>)>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct DailyConfiguration {
    enabled: bool,
    hour: u32,
    folder: String,
    format: lokalbot_core::settings::DailyMemoryExportFormat,
}

impl DailyConfiguration {
    fn new(settings: &Settings) -> Self {
        Self {
            enabled: settings.daily_memory_export_enabled
                && !settings.daily_memory_export_folder.is_empty(),
            hour: settings.daily_memory_export_hour.min(23),
            folder: settings.daily_memory_export_folder.clone(),
            format: settings.daily_memory_export_format,
        }
    }
}

#[derive(Default)]
struct DailyState {
    configuration: Option<DailyConfiguration>,
    last_successful_day: Option<NaiveDate>,
    caught_up_days: HashSet<NaiveDate>,
    reopened_days: HashSet<NaiveDate>,
    last_attempt: Option<Instant>,
}

pub fn next_daily_export(
    at: DateTime<Local>,
    hour: u32,
    last_successful_day: Option<NaiveDate>,
    caught_up_days: &HashSet<NaiveDate>,
    reopened_days: &HashSet<NaiveDate>,
) -> Option<(NaiveDate, daily::Pass)> {
    let today = at.date_naive();
    let window_start = today - chrono::Duration::days(CATCH_UP_DAYS);
    if let Some(day) = reopened_days
        .iter()
        .filter(|day| **day >= window_start && **day < today)
        .min()
    {
        return Some((*day, daily::Pass::Refresh));
    }
    let mut cursor = window_start;
    while cursor < today {
        if !caught_up_days.contains(&cursor) {
            return Some((cursor, daily::Pass::CatchUp));
        }
        cursor = cursor.succ_opt()?;
    }
    (last_successful_day != Some(today) && at.hour() >= hour.min(23))
        .then_some((today, daily::Pass::Refresh))
}

#[derive(Default)]
pub struct Exports {
    notes: Mutex<NoteState>,
    daily: Mutex<DailyState>,
    wake_notes: AtomicBool,
    wake_daily: AtomicBool,
}

impl Exports {
    pub fn reconsider_notes(&self) {
        self.notes.lock().pending = true;
        self.wake_notes.store(true, Ordering::Relaxed);
    }

    pub fn reconsider_daily(&self, days: &[NaiveDate]) {
        if days.contains(&Local::now().date_naive()) {
            self.reopen_today();
        }
    }

    pub fn settings_changed(&self) {
        self.wake_notes.store(true, Ordering::Relaxed);
        self.wake_daily.store(true, Ordering::Relaxed);
    }

    fn reopen_today(&self) {
        let mut daily = self.daily.lock();
        daily.last_successful_day = None;
        daily.last_attempt = None;
        drop(daily);
        self.wake_daily.store(true, Ordering::Relaxed);
    }

    pub fn digest_did_change(&self, day: NaiveDate, retention_days: u32) {
        let today = Local::now().date_naive();
        if day >= today {
            self.reopen_today();
            return;
        }
        let retained_since = today - chrono::Duration::days(i64::from(retention_days));
        if day < retained_since || day < today - chrono::Duration::days(CATCH_UP_DAYS) {
            return;
        }
        let mut daily = self.daily.lock();
        daily.reopened_days.insert(day);
        daily.last_attempt = None;
        drop(daily);
        self.wake_daily.store(true, Ordering::Relaxed);
    }
}

fn wait(shared: &Shared, wake: &AtomicBool) {
    let until = Instant::now() + TICK;
    while Instant::now() < until && !shared.is_shutting_down() {
        if wake.swap(false, Ordering::Relaxed) {
            return;
        }
        std::thread::sleep(Duration::from_millis(500));
    }
}

fn curation_stamp(shared: &Shared) -> (Option<SystemTime>, Option<SystemTime>) {
    let modified = |path: PathBuf| std::fs::metadata(path).ok()?.modified().ok();
    let paths = shared.library.paths();
    (
        modified(paths.people_dir().join("curation.json")),
        modified(paths.projects_dir().join("tracked.json")),
    )
}

fn note_tick(shared: &Shared) {
    let settings = shared.settings();
    let configuration = NoteConfiguration::new(&settings);
    let stamp = curation_stamp(shared);
    let (previous, destination) = {
        let mut state = shared.exports.notes.lock();
        if state.configuration.as_ref() != Some(&configuration) {
            state.fingerprints.clear();
            state.retry_after = None;
            state.pending = true;
            state.configuration = Some(configuration.clone());
        }
        if state.curation_stamp.is_some_and(|known| known != stamp) {
            state.pending = true;
        }
        state.curation_stamp = Some(stamp);
        if !configuration.enabled
            || !state.pending
            || shared.pipeline_busy.load(Ordering::Relaxed)
            || state.retry_after.is_some_and(|at| Instant::now() < at)
        {
            return;
        }
        state.pending = false;
        (
            state.fingerprints.clone(),
            configuration.destination.clone(),
        )
    };
    let is_cancelled =
        || shared.is_shutting_down() || NoteConfiguration::new(&shared.settings()) != configuration;
    let result = meeting_notes::export(&shared.library, &destination, &previous, &is_cancelled);
    let mut state = shared.exports.notes.lock();
    if state.configuration.as_ref() != Some(&configuration) || is_cancelled() {
        state.pending = true;
        return;
    }
    let schedule_retry = |state: &mut NoteState| {
        state.pending = true;
        state.retry_after = Some(Instant::now() + RETRY);
    };
    match result {
        Ok(report) => {
            state.fingerprints = report.fingerprints;
            if let Some(failure) = report.failures.first() {
                schedule_retry(&mut state);
                shared.error(format!("Meeting note export failed for {failure}"));
            } else {
                state.retry_after = None;
                if !report.written.is_empty() {
                    log::info!("meeting note export wrote {} notes", report.written.len());
                }
            }
        }
        Err(err) => {
            schedule_retry(&mut state);
            shared.error(format!("Meeting note export failed: {err:#}"));
        }
    }
}

fn daily_tick(shared: &Shared) {
    let settings = shared.settings();
    let configuration = DailyConfiguration::new(&settings);
    let now = Local::now();
    let (day, pass) = {
        let mut state = shared.exports.daily.lock();
        if state.configuration.as_ref() != Some(&configuration) {
            state.last_attempt = None;
            state.last_successful_day = None;
            state.caught_up_days.clear();
            state.reopened_days.clear();
            state.configuration = Some(configuration.clone());
        }
        if !configuration.enabled {
            return;
        }
        let Some(next) = next_daily_export(
            now,
            configuration.hour,
            state.last_successful_day,
            &state.caught_up_days,
            &state.reopened_days,
        ) else {
            return;
        };
        if state.last_attempt.is_some_and(|at| at.elapsed() < RETRY) {
            return;
        }
        state.last_attempt = Some(Instant::now());
        next
    };
    let result = daily::export(
        &shared.library,
        day,
        std::path::Path::new(&configuration.folder),
        configuration.format,
        pass,
    );
    let is_past_day = day < now.date_naive();
    let mut state = shared.exports.daily.lock();
    if state.configuration.as_ref() != Some(&configuration) {
        return;
    }
    let finish = |state: &mut DailyState| {
        if is_past_day {
            state.caught_up_days.insert(day);
            state.reopened_days.remove(&day);
        } else {
            state.last_successful_day = Some(day);
        }
    };
    match result {
        Ok(_) => {
            finish(&mut state);
            state.last_attempt = None;
            shared.exports.wake_daily.store(true, Ordering::Relaxed);
        }
        Err(err) => {
            if is_past_day {
                finish(&mut state);
                state.last_attempt = None;
                log::info!("daily memory export left {day} as it is: {err}");
                if !matches!(
                    err,
                    daily::ExportError::DestinationCollision(_)
                        | daily::ExportError::GeneratedFileModified(_)
                ) {
                    shared.error(format!("Daily memory export failed: {err}"));
                }
            } else {
                shared.error(format!("Daily memory export failed: {err}"));
            }
        }
    }
}

pub(crate) fn start(shared: Arc<Shared>) {
    let notes = shared.clone();
    let spawned = std::thread::Builder::new()
        .name("lokalbot-note-export".into())
        .spawn(move || {
            while !notes.is_shutting_down() {
                note_tick(&notes);
                wait(&notes, &notes.exports.wake_notes);
            }
        });
    if let Err(err) = spawned {
        log::warn!("could not start the meeting note export: {err}");
    }
    let spawned = std::thread::Builder::new()
        .name("lokalbot-daily-export".into())
        .spawn(move || {
            while !shared.is_shutting_down() {
                daily_tick(&shared);
                wait(&shared, &shared.exports.wake_daily);
            }
        });
    if let Err(err) = spawned {
        log::warn!("could not start the daily memory export: {err}");
    }
}
