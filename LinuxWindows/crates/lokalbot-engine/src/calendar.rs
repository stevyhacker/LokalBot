//! The user's calendars, kept fresh in the background
//! (`EventKitCalendarEventProvider` on macOS).
//!
//! Detection and recording read the cached events and never wait on the
//! network: a refresh thread reads Evolution every minute and private links
//! every five minutes, over yesterday to tomorrow (so the detector's −15/+90
//! minute window works across midnight and Today sees the whole day). Nothing
//! is read while calendar detection is off.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use chrono::{DateTime, Local, Utc};
use crossbeam_channel::{Receiver, RecvTimeoutError, Sender, bounded};
use parking_lot::Mutex;

use lokalbot_core::Settings;
use lokalbot_core::calendar::{self as policy, CalendarEvent};
use lokalbot_platform::calendar::{CalendarSources, ParseOptions};

use crate::{EngineEvent, Shared};

const EVOLUTION_INTERVAL: Duration = Duration::from_secs(60);
const LINK_INTERVAL: Duration = Duration::from_secs(5 * 60);

/// What Today and Settings show about the calendar.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct CalendarSnapshot {
    pub status: CalendarStatus,
    /// Recordable meetings from yesterday to tomorrow, by start.
    pub events: Vec<CalendarEvent>,
    pub refreshed_at: Option<DateTime<Utc>>,
    /// Private links saved in the credential store.
    pub link_count: usize,
    /// One line per source that could not be read (links redacted).
    pub problems: Vec<String>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub enum CalendarStatus {
    /// Calendar detection is off.
    #[default]
    Off,
    /// On, but no link is saved and Evolution is not used or not installed.
    NoSources,
    Loading,
    Ready,
    /// Every source failed.
    Failed,
}

/// The cached calendar, shared by the detector, recording and the app.
#[derive(Default)]
pub(crate) struct Calendar {
    state: Mutex<CalendarSnapshot>,
    /// Links from the credential store; `None` until first read.
    links: Mutex<Option<Vec<String>>>,
    wake: Mutex<Option<Sender<Wake>>>,
}

enum Wake {
    /// Settings or links changed: read every source now.
    Refresh,
    Stop,
}

impl Calendar {
    /// The event happening now (`activeCandidate`), when calendar detection is on.
    pub fn active_event(&self, settings: &Settings, now: DateTime<Utc>) -> Option<CalendarEvent> {
        if !settings.calendar_detection_enabled {
            return None;
        }
        let state = self.state.lock();
        policy::active_event(&policy::detection_window(&state.events, now), now).cloned()
    }

    pub fn snapshot(&self) -> CalendarSnapshot {
        self.state.lock().clone()
    }

    /// Reads the links from the credential store again, then every source
    /// (Refresh in Settings, or calendar use turned back on).
    pub fn reload(&self) {
        *self.links.lock() = None;
        self.refresh();
    }

    /// Reads every source again soon (settings or links changed).
    pub fn refresh(&self) {
        if let Some(wake) = self.wake.lock().as_ref() {
            let _ = wake.try_send(Wake::Refresh);
        }
    }

    /// Replaces the saved links (credential store first) and refreshes.
    pub fn set_links(&self, links: Vec<String>) -> anyhow::Result<()> {
        crate::secrets::save_calendar_links(&links)?;
        *self.links.lock() = Some(links);
        self.refresh();
        Ok(())
    }

    fn links(&self) -> Vec<String> {
        let mut cached = self.links.lock();
        if let Some(links) = cached.as_ref() {
            return links.clone();
        }
        match crate::secrets::calendar_links() {
            Ok(links) => {
                *cached = Some(links.clone());
                links
            }
            Err(err) => {
                // Not retried every minute: a locked store would ask each time.
                log::warn!("calendar: links could not be read from the credential store: {err:#}");
                *cached = Some(Vec::new());
                Vec::new()
            }
        }
    }
}

/// Starts the refresh thread.
pub(crate) fn start(shared: Arc<Shared>) -> CalendarThread {
    let (wake, woken) = bounded(4);
    *shared.calendar.wake.lock() = Some(wake.clone());
    let stopped = Arc::new(AtomicBool::new(false));
    let flag = stopped.clone();
    std::thread::Builder::new()
        .name("lokalbot-calendar".into())
        .spawn(move || run(shared, woken, flag))
        .expect("spawning the calendar thread");
    CalendarThread { wake, stopped }
}

pub(crate) struct CalendarThread {
    wake: Sender<Wake>,
    stopped: Arc<AtomicBool>,
}

impl CalendarThread {
    pub fn stop(&self) {
        self.stopped.store(true, Ordering::Relaxed);
        let _ = self.wake.try_send(Wake::Stop);
    }
}

#[derive(Default)]
struct Cache {
    links: Option<(Instant, SourceResult)>,
    evolution: Option<(Instant, SourceResult)>,
    window_day: Option<chrono::NaiveDate>,
}

#[derive(Clone, Default)]
struct SourceResult {
    events: Vec<CalendarEvent>,
    read: usize,
    problems: Vec<String>,
}

fn run(shared: Arc<Shared>, woken: Receiver<Wake>, stopped: Arc<AtomicBool>) {
    let mut cache = Cache::default();
    let mut force = true;
    while !stopped.load(Ordering::Relaxed) {
        refresh(&shared, &mut cache, force);
        force = false;
        match woken.recv_timeout(EVOLUTION_INTERVAL) {
            Ok(Wake::Refresh) => force = true,
            Ok(Wake::Stop) | Err(RecvTimeoutError::Disconnected) => break,
            Err(RecvTimeoutError::Timeout) => {}
        }
    }
}

fn refresh(shared: &Shared, cache: &mut Cache, force: bool) {
    let settings = shared.settings();
    let calendar = &shared.calendar;
    if !settings.calendar_detection_enabled {
        *cache = Cache::default();
        publish(shared, CalendarSnapshot::default());
        return;
    }
    let links = calendar.links();
    let evolution = settings.calendar_evolution_enabled && cfg!(target_os = "linux");
    if links.is_empty() && !evolution {
        *cache = Cache::default();
        publish(
            shared,
            CalendarSnapshot {
                status: CalendarStatus::NoSources,
                ..Default::default()
            },
        );
        return;
    }
    let today = Local::now().date_naive();
    let force = force || cache.window_day != Some(today);
    cache.window_day = Some(today);
    if calendar.snapshot().status == CalendarStatus::Off
        || calendar.snapshot().status == CalendarStatus::NoSources
    {
        let mut loading = calendar.snapshot();
        loading.status = CalendarStatus::Loading;
        loading.link_count = links.len();
        publish(shared, loading);
    }

    let options = window(&settings, today);
    let stale = |entry: &Option<(Instant, SourceResult)>, interval: Duration| {
        force
            || entry
                .as_ref()
                .is_none_or(|(at, _)| at.elapsed() >= interval)
    };
    if links.is_empty() {
        cache.links = None;
    } else if stale(&cache.links, LINK_INTERVAL) {
        let report = lokalbot_platform::calendar::fetch(
            &CalendarSources {
                links: links.clone(),
                evolution: false,
            },
            &options,
        );
        cache.links = Some((Instant::now(), report.into()));
    }
    if !evolution {
        cache.evolution = None;
    } else if stale(&cache.evolution, EVOLUTION_INTERVAL) {
        let report = lokalbot_platform::calendar::fetch(
            &CalendarSources {
                links: Vec::new(),
                evolution: true,
            },
            &options,
        );
        cache.evolution = Some((Instant::now(), report.into()));
    }

    let mut events = Vec::new();
    let mut read = 0;
    let mut problems = Vec::new();
    for (_, result) in cache.links.iter().chain(cache.evolution.iter()) {
        events.extend(result.events.iter().cloned());
        read += result.read;
        problems.extend(result.problems.iter().cloned());
    }
    events.sort_by(|a, b| a.start.cmp(&b.start).then(a.end.cmp(&b.end)));
    let mut seen = std::collections::HashSet::new();
    events.retain(|event| seen.insert(event.external_id.clone()));
    let status = if read == 0 && !problems.is_empty() {
        CalendarStatus::Failed
    } else if read == 0 {
        CalendarStatus::NoSources
    } else {
        CalendarStatus::Ready
    };
    log::debug!(
        "calendar: {} meetings from {read} source(s), {} problem(s)",
        events.len(),
        problems.len()
    );
    publish(
        shared,
        CalendarSnapshot {
            status,
            events,
            refreshed_at: Some(Utc::now()),
            link_count: links.len(),
            problems,
        },
    );
}

impl From<lokalbot_platform::calendar::FetchReport> for SourceResult {
    fn from(report: lokalbot_platform::calendar::FetchReport) -> Self {
        Self {
            events: report.events,
            read: report.sources_read,
            problems: report.problems,
        }
    }
}

/// Yesterday 00:00 to the end of tomorrow, local time.
fn window(settings: &Settings, today: chrono::NaiveDate) -> ParseOptions {
    let (from, _) = lokalbot_core::time::local_day_bounds(today.pred_opt().unwrap_or(today));
    let (_, to) = lokalbot_core::time::local_day_bounds(today.succ_opt().unwrap_or(today));
    ParseOptions {
        provider: String::new(),
        from,
        to,
        my_addresses: my_addresses(settings),
        calendar_title: None,
        default_zone: None,
    }
}

/// `calendarMyEmailAddresses`, normalized.
pub(crate) fn my_addresses(settings: &Settings) -> Vec<String> {
    settings
        .calendar_my_email_addresses
        .split([',', ';', ' ', '\n'])
        .filter_map(lokalbot_core::model::CalendarParticipantIdentity::normalized_email_address)
        .collect()
}

fn publish(shared: &Shared, snapshot: CalendarSnapshot) {
    let changed = {
        let mut state = shared.calendar.state.lock();
        let changed = *state != snapshot;
        *state = snapshot.clone();
        changed
    };
    if changed {
        shared.emit(EngineEvent::Calendar(snapshot));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn my_addresses_are_split_and_normalized() {
        let settings = Settings {
            calendar_my_email_addresses: " Ana@Example.com, ana.work@example.org;\nnot-an-address"
                .into(),
            ..Settings::default()
        };
        assert_eq!(
            my_addresses(&settings),
            ["ana@example.com", "ana.work@example.org"]
        );
    }
}
