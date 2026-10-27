//! Day memory: samples the focused app and window every five seconds and
//! stores contiguous stretches as activity blocks (`ActivityTracker.swift`).

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use chrono::{DateTime, Utc};
use parking_lot::Mutex;

use lokalbot_platform::{MeetingDetector, SampleDisposition};

use crate::{EngineEvent, Shared};

const SAMPLE_INTERVAL: Duration = Duration::from_secs(5);
/// Inactivity that closes the current block.
const IDLE_SECONDS: f64 = 180.0;
/// Blocks shorter than this are never stored.
const MIN_BLOCK_SECONDS: i64 = 5;

pub struct DayMemory {
    shared: Arc<Shared>,
    paused: Arc<AtomicBool>,
    stop: Arc<AtomicBool>,
}

struct Current {
    app: String,
    title: String,
    start: DateTime<Utc>,
    last_seen: DateTime<Utc>,
    id: Option<i64>,
}

impl DayMemory {
    /// `on_boundary(app_changed)` runs when a new activity block begins
    /// (`ActivitySampler.onActivityBoundary`); screen context captures there.
    pub fn start(
        shared: Arc<Shared>,
        detector: Arc<Mutex<MeetingDetector>>,
        on_boundary: impl Fn(bool) + Send + 'static,
    ) -> Self {
        let memory = Self {
            shared,
            paused: Arc::new(AtomicBool::new(false)),
            stop: Arc::new(AtomicBool::new(false)),
        };
        let shared = memory.shared.clone();
        let paused = memory.paused.clone();
        let stop = memory.stop.clone();
        std::thread::Builder::new()
            .name("lokalbot-day-memory".into())
            .spawn(move || run(shared, paused, stop, detector, on_boundary))
            .expect("spawning the day memory thread");
        memory
    }

    /// The pause switch, shared with screen context.
    pub fn paused_flag(&self) -> Arc<AtomicBool> {
        self.paused.clone()
    }

    pub fn set_paused(&self, paused: bool) {
        self.paused.store(paused, Ordering::Relaxed);
        self.shared.message(if paused {
            "Day memory is paused."
        } else {
            "Day memory resumed."
        });
    }

    pub fn stop(&self) {
        self.stop.store(true, Ordering::Relaxed);
    }
}

fn run(
    shared: Arc<Shared>,
    paused: Arc<AtomicBool>,
    stop: Arc<AtomicBool>,
    detector: Arc<Mutex<MeetingDetector>>,
    on_boundary: impl Fn(bool),
) {
    let mut source = lokalbot_platform::activity_source();
    if let Some(limitation) = source.limitation() {
        log::warn!("day memory: {limitation}");
    }
    let mut current: Option<Current> = None;
    while !stop.load(Ordering::Relaxed) {
        std::thread::sleep(SAMPLE_INTERVAL);
        let settings = shared.settings();
        if !settings.tracking_enabled || paused.load(Ordering::Relaxed) {
            close(&shared, &mut current);
            continue;
        }
        if source
            .idle_seconds()
            .is_some_and(|idle| idle >= IDLE_SECONDS)
        {
            close(&shared, &mut current);
            continue;
        }
        let sample = match source.sample() {
            Ok(Some(sample)) => sample,
            Ok(None) => continue,
            Err(err) => {
                log::debug!("activity sample failed: {err:#}");
                continue;
            }
        };
        // Browser meeting detection needs window titles (Google Meet tabs).
        detector
            .lock()
            .observe_window(&sample.app_id, &sample.title);
        let (app, title) = match lokalbot_platform::disposition(&sample, &settings) {
            SampleDisposition::Keep(sample) => (sample.app, sample.title),
            SampleDisposition::Private => ("Private".to_string(), String::new()),
            SampleDisposition::Skip => continue,
        };
        let now = sample.at;
        match current.as_mut() {
            Some(block) if block.app == app && block.title == title => {
                block.last_seen = now;
                persist(&shared, block);
            }
            _ => {
                let app_changed = current.as_ref().is_none_or(|block| block.app != app);
                close(&shared, &mut current);
                on_boundary(app_changed);
                current = Some(Current {
                    app,
                    title,
                    start: now,
                    last_seen: now,
                    id: None,
                });
            }
        }
    }
    close(&shared, &mut current);
}

/// Writes the block once it is long enough, then keeps extending it.
fn persist(shared: &Shared, block: &mut Current) {
    let library = &shared.library;
    match block.id {
        Some(id) => {
            if let Err(err) = library.extend_activity(id, block.last_seen) {
                log::debug!("extending activity failed: {err:#}");
            }
        }
        None if (block.last_seen - block.start).num_seconds() >= MIN_BLOCK_SECONDS => {
            match library.append_activity(&block.app, &block.title, block.start, block.last_seen) {
                Ok(id) => {
                    block.id = Some(id);
                    shared.emit(EngineEvent::LibraryChanged);
                }
                Err(err) => log::debug!("storing activity failed: {err:#}"),
            }
        }
        None => {}
    }
}

fn close(shared: &Shared, current: &mut Option<Current>) {
    if let Some(mut block) = current.take() {
        persist(shared, &mut block);
    }
}
