//! The day digest: written automatically after `dayDigestHour`, or on request
//! (`DayDigestScheduler.swift`).

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use anyhow::{Result, anyhow};
use chrono::{Local, NaiveDate, Timelike as _};
use parking_lot::Mutex;

use crate::models::Models;
use crate::{BackgroundItem, BackgroundKind, EngineEvent, Shared};

/// Wait this long after a failed automatic run before trying again.
const FAILURE_BACKOFF: Duration = Duration::from_secs(15 * 60);

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
                while !stop.load(Ordering::Relaxed) {
                    std::thread::sleep(Duration::from_secs(60));
                    let settings = shared.settings();
                    if !settings.day_digest_auto_enabled
                        || Local::now().hour() < settings.day_digest_hour
                    {
                        continue;
                    }
                    if last_failure
                        .lock()
                        .is_some_and(|at| at.elapsed() < FAILURE_BACKOFF)
                    {
                        continue;
                    }
                    if shared.capture_active.load(Ordering::Relaxed)
                        || running.load(Ordering::Relaxed)
                    {
                        continue;
                    }
                    if !models.missing(&models.think_requirements()).is_empty() {
                        continue;
                    }
                    let today = Local::now().date_naive();
                    let needs = match shared.library.day_digest(today) {
                        Ok(None) => true,
                        Ok(Some(digest)) => digest.is_stale && digest.meta.is_some(),
                        Err(_) => false,
                    };
                    if needs && generate(&shared, &running, today).is_err() {
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
            if let Err(err) = generate(&shared, &running, day) {
                shared.error(format!("The digest could not be written: {err:#}"));
            }
        });
    }

    pub fn stop(&self) {
        self.stop.store(true, Ordering::Relaxed);
    }
}

fn generate(shared: &Arc<Shared>, running: &AtomicBool, day: NaiveDate) -> Result<()> {
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
    let result = (|| -> Result<()> {
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
        Ok(())
    })();
    running.store(false, Ordering::SeqCst);
    shared.clear_background(&background_id);
    shared.emit(EngineEvent::Digest { running: None });
    shared.emit(EngineEvent::LibraryChanged);
    result
}
