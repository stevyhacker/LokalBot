//! Runs the optional exports (`MeetingNoteExportScheduler`,
//! `DailyMemoryExportScheduler`). Each has a one-minute tick, stays correct
//! across sleep and daylight-saving changes, and waits fifteen minutes after a
//! failed write so a removable or network volume has time to return.

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

/// Yesterday plus the six days before it, as for the digest.
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

// ------------------------------------------------------------ meeting notes

#[derive(Clone, Debug, PartialEq, Eq)]
struct NoteConfiguration {
    enabled: bool,
    /// Folder, format and transcript choice. Changing any of them exports every
    /// meeting again into the chosen folder.
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
    /// Source fingerprints from the last pass, by meeting.
    fingerprints: HashMap<Uuid, String>,
    pending: bool,
    retry_after: Option<Instant>,
    /// When People and Projects choices last changed: names notes link to.
    curation_stamp: Option<(Option<SystemTime>, Option<SystemTime>)>,
}

// --------------------------------------------------------------- daily note

#[derive(Clone, Debug, PartialEq, Eq)]
struct DailyConfiguration {
    enabled: bool,
    hour: u32,
    /// Changing the folder or format exports to the new destination even when
    /// today's prior destination already succeeded.
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
    /// Past days already checked for a missing note in this session.
    caught_up_days: HashSet<NaiveDate>,
    /// Past days whose digest changed after their note was written.
    reopened_days: HashSet<NaiveDate>,
    last_attempt: Option<Instant>,
}

/// Reopened past days first, then past days not yet checked for a missing note
/// (oldest first), then today once its hour arrives.
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

// ------------------------------------------------------------------- shared

/// What the rest of the engine tells the export threads.
#[derive(Default)]
pub struct Exports {
    notes: Mutex<NoteState>,
    daily: Mutex<DailyState>,
    /// A change the next short wait should act on.
    wake_notes: AtomicBool,
    wake_daily: AtomicBool,
}

impl Exports {
    /// Something a meeting note shows may have changed. The next tick looks.
    pub fn reconsider_notes(&self) {
        self.notes.lock().pending = true;
        self.wake_notes.store(true, Ordering::Relaxed);
    }

    /// An action correction or late meeting artifact can change today's export
    /// after its scheduled run. Only the affected current day reopens; historical
    /// exports stay as they are.
    pub fn reconsider_daily(&self, days: &[NaiveDate]) {
        if days.contains(&Local::now().date_naive()) {
            self.reopen_today();
        }
    }

    /// Folders, formats and hours are read each tick; this starts it now.
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

    /// A digest finished or rebuilt after its note was written. Today's note
    /// refreshes as for any evidence change; a past day's note within the
    /// catch-up window is rewritten with the finished digest, while all of that
    /// day is still retained: a digest rebuilt from what retention left would
    /// replace a fuller note.
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

/// Sleeps out one tick, returning early when `wake` is raised or on shutdown.
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
        // People and Projects choices change the names notes link to.
        if state.curation_stamp.is_some_and(|known| known != stamp) {
            state.pending = true;
        }
        state.curation_stamp = Some(stamp);
        if !configuration.enabled
            || !state.pending
            // Notes are written while processing is idle, so a meeting's note is
            // not written half-finished and rewritten moments later.
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
    // A folder changed mid-pass: the next tick starts over with the new one.
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
        // A failed filesystem write is visible but not retried every minute.
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
            // The retry wait is for failures; the next export runs now.
            state.last_attempt = None;
            shared.exports.wake_daily.store(true, Ordering::Relaxed);
        }
        Err(err) => {
            // A past day is tried once per session, so a note that can't be
            // written never holds back today's. A past day's file is the
            // person's: their own note in that folder, or one they edited. It
            // stays as it is, so there is nothing to report.
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
