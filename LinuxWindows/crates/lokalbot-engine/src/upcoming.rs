//! Preparation for the next meeting on Today (`UpcomingMeetingPreparationModel`).
//!
//! The evidence is gathered on every request; a brief written by the local
//! Think model is cached in memory by the evidence's signature and never
//! saved. Automatic briefs never download a model: they run only when the
//! Think model is on this computer and already installed. "Generate brief"
//! may prepare it.

use std::collections::HashMap;
use std::sync::Arc;

use crossbeam_channel::{Receiver, Sender, unbounded};
use parking_lot::Mutex;

use lokalbot_ai::upcoming::{self, UpcomingEvidence};
use lokalbot_core::calendar::CalendarEvent;

use crate::models::Models;
use crate::{EngineEvent, MeetingPreparation, Shared};

const MAXIMUM_BRIEFS: usize = 24;

struct Job {
    event: CalendarEvent,
    generate: bool,
}

pub(crate) struct Preparation {
    jobs: Sender<Job>,
}

#[derive(Default)]
struct Briefs {
    written: HashMap<String, String>,
    /// Signatures whose automatic brief failed; only an explicit request retries.
    failed: std::collections::HashSet<String>,
}

impl Preparation {
    pub fn start(shared: Arc<Shared>, models: Models) -> Self {
        let (jobs, received) = unbounded();
        std::thread::Builder::new()
            .name("lokalbot-meeting-preparation".into())
            .spawn(move || run(shared, models, received))
            .expect("spawning the preparation thread");
        Self { jobs }
    }

    pub fn prepare(&self, event: CalendarEvent, generate: bool) {
        let _ = self.jobs.send(Job { event, generate });
    }
}

fn run(shared: Arc<Shared>, models: Models, jobs: Receiver<Job>) {
    let briefs = Mutex::new(Briefs::default());
    while let Ok(mut job) = jobs.recv() {
        // Only the newest request for the same event matters.
        while let Ok(next) = jobs.try_recv() {
            let generate = job.generate || next.generate;
            job = Job { generate, ..next };
        }
        if shared.is_shutting_down() {
            break;
        }
        let settings = shared.settings();
        let evidence = upcoming::compile(
            &job.event,
            &shared.library,
            chrono::Utc::now(),
            settings.use_calendar_agenda,
        );
        let signature = evidence.signature();
        let cached = briefs.lock().written.get(&signature).cloned();
        let automatic = cached.is_none()
            && evidence.has_preparation_context()
            && !briefs.lock().failed.contains(&signature)
            && models.missing(&models.think_requirements()).is_empty()
            && shared.think(&settings).is_ok_and(|think| think.is_local());
        let generate = evidence.has_preparation_context() && (job.generate || automatic);
        emit(&shared, &evidence, cached.clone(), generate, None);
        if !generate {
            continue;
        }
        let result = (|| -> anyhow::Result<String> {
            if job.generate {
                models.ensure(&models.think_requirements(), true)?;
            }
            let think = shared.think(&settings)?;
            upcoming::generate_brief(&think, &evidence)
        })();
        match result {
            Ok(brief) => {
                let mut briefs = briefs.lock();
                if briefs.written.len() >= MAXIMUM_BRIEFS
                    && let Some(oldest) = briefs.written.keys().next().cloned()
                {
                    briefs.written.remove(&oldest);
                }
                briefs.written.insert(signature.clone(), brief.clone());
                briefs.failed.remove(&signature);
                drop(briefs);
                emit(&shared, &evidence, Some(brief), false, None);
            }
            Err(err) => {
                log::warn!("pre-meeting brief fallback: {err:#}");
                briefs.lock().failed.insert(signature);
                let message =
                    if job.generate && !shared.think(&settings).is_ok_and(|t| t.is_local()) {
                        "Choose an on-device Think model to generate this brief."
                    } else {
                        "AI brief unavailable; showing saved context."
                    };
                emit(&shared, &evidence, cached, false, Some(message.to_string()));
            }
        }
    }
}

fn emit(
    shared: &Shared,
    evidence: &UpcomingEvidence,
    brief: Option<String>,
    generating: bool,
    error: Option<String>,
) {
    shared.emit(EngineEvent::MeetingPreparation(MeetingPreparation {
        event_id: evidence.event.external_id.clone(),
        evidence: evidence.clone(),
        brief,
        generating,
        error,
    }));
}
