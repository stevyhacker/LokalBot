//! The processing queue: transcribe, then write notes and actions, one meeting
//! at a time (`ProcessingPipeline.swift`, `PipelineJobStore.swift`).

use std::collections::VecDeque;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use anyhow::{Context as _, Result};
use parking_lot::{Condvar, Mutex};
use uuid::Uuid;

use lokalbot_core::Meeting;

use crate::models::Models;
use crate::{BackgroundItem, BackgroundKind, EngineEvent, Shared, Stage};

/// Launch resume stops retrying a job after this many starts.
const MAX_AUTO_ATTEMPTS: u32 = 3;

#[derive(Clone)]
pub struct Pipeline {
    inner: Arc<Inner>,
}

struct Inner {
    shared: Arc<Shared>,
    models: Models,
    queue: Mutex<VecDeque<Job>>,
    signal: Condvar,
    stop: AtomicBool,
}

#[derive(Clone, Debug)]
struct Job {
    meeting_id: Uuid,
    transcribe: bool,
    summarize: bool,
    user_initiated: bool,
}

enum Outcome {
    Done,
    WaitingForModels,
}

impl Pipeline {
    pub fn start(shared: Arc<Shared>, models: Models) -> Self {
        let inner = Arc::new(Inner {
            shared: shared.clone(),
            models,
            queue: Mutex::new(VecDeque::new()),
            signal: Condvar::new(),
            stop: AtomicBool::new(false),
        });
        match shared.library.pending_jobs() {
            Ok(jobs) => {
                let mut queue = inner.queue.lock();
                for job in jobs {
                    if job.attempts >= MAX_AUTO_ATTEMPTS {
                        let message = job.last_error.clone().unwrap_or_else(|| {
                            "Processing stopped after repeated failures.".into()
                        });
                        shared.emit(EngineEvent::Processing {
                            meeting_id: job.meeting_id,
                            stage: Some(Stage::Failed(message)),
                        });
                        continue;
                    }
                    shared.emit(EngineEvent::Processing {
                        meeting_id: job.meeting_id,
                        stage: Some(Stage::Queued),
                    });
                    queue.push_back(Job {
                        meeting_id: job.meeting_id,
                        transcribe: job.transcribe && !job.transcription_completed,
                        summarize: job.summarize,
                        user_initiated: false,
                    });
                }
            }
            Err(err) => log::warn!("could not read pending jobs: {err:#}"),
        }
        let worker = inner.clone();
        std::thread::Builder::new()
            .name("lokalbot-pipeline".into())
            .spawn(move || worker.run())
            .expect("spawning the pipeline thread");
        crate::speech::start_idle_release(shared.speech.clone(), shared);
        Self { inner }
    }

    pub fn enqueue(
        &self,
        meeting_id: Uuid,
        transcribe: bool,
        summarize: bool,
        user_initiated: bool,
    ) {
        let shared = &self.inner.shared;
        if let Err(err) =
            shared
                .library
                .enqueue_job(meeting_id, transcribe, summarize, user_initiated)
        {
            log::warn!("could not persist the processing job: {err:#}");
        }
        {
            let mut queue = self.inner.queue.lock();
            if let Some(existing) = queue.iter_mut().find(|job| job.meeting_id == meeting_id) {
                existing.transcribe |= transcribe;
                existing.summarize = if user_initiated {
                    summarize
                } else {
                    existing.summarize || summarize
                };
                existing.user_initiated |= user_initiated;
            } else {
                queue.push_back(Job {
                    meeting_id,
                    transcribe,
                    summarize,
                    user_initiated,
                });
            }
        }
        shared.emit(EngineEvent::Processing {
            meeting_id,
            stage: Some(Stage::Queued),
        });
        self.inner.signal.notify_one();
    }

    pub fn stop(&self) {
        self.inner.stop.store(true, Ordering::Relaxed);
        self.inner.signal.notify_all();
    }
}

impl Inner {
    fn run(self: Arc<Self>) {
        loop {
            let job = {
                let mut queue = self.queue.lock();
                loop {
                    if self.stop.load(Ordering::Relaxed) {
                        return;
                    }
                    if let Some(job) = queue.pop_front() {
                        break job;
                    }
                    self.signal.wait_for(&mut queue, Duration::from_secs(5));
                }
            };
            self.publish_queue_length();
            let meeting_id = job.meeting_id;
            match self.process(&job) {
                Ok(Outcome::Done) => {
                    let _ = self.shared.library.mark_job_completed(meeting_id);
                    self.shared.emit(EngineEvent::Processing {
                        meeting_id,
                        stage: None,
                    });
                }
                Ok(Outcome::WaitingForModels) => {
                    self.shared.emit(EngineEvent::Processing {
                        meeting_id,
                        stage: Some(Stage::WaitingForModels),
                    });
                }
                Err(err) => {
                    let message = format!("{err:#}");
                    log::error!("processing {meeting_id} failed: {message}");
                    let _ = self.shared.library.mark_job_failed(meeting_id, &message);
                    self.shared.emit(EngineEvent::Processing {
                        meeting_id,
                        stage: Some(Stage::Failed(message)),
                    });
                }
            }
            self.shared
                .clear_background(&format!("meeting:{meeting_id}"));
            self.shared.emit(EngineEvent::LibraryChanged);
        }
    }

    fn publish_queue_length(&self) {
        let queued = self.queue.lock().len();
        if queued == 0 {
            self.shared.clear_background("meeting-queue");
        }
    }

    fn stage(&self, meeting: &Meeting, stage: Stage, detail: &str, progress: Option<f32>) {
        let queued = self.queue.lock().len();
        let detail = if queued > 0 {
            format!("{detail} · {queued} queued")
        } else {
            detail.to_string()
        };
        self.shared.set_background(BackgroundItem {
            id: format!("meeting:{}", meeting.id),
            kind: BackgroundKind::Meeting,
            title: meeting.display_title(),
            detail,
            progress,
        });
        self.shared.emit(EngineEvent::Processing {
            meeting_id: meeting.id,
            stage: Some(stage),
        });
    }

    /// Heavy work never runs while a meeting or dictation is capturing.
    fn yield_to_capture(&self) {
        while self.shared.capture_active.load(Ordering::Relaxed)
            && !self.stop.load(Ordering::Relaxed)
        {
            std::thread::sleep(Duration::from_millis(250));
        }
    }

    fn process(&self, job: &Job) -> Result<Outcome> {
        let library = &self.shared.library;
        let Some(meeting) = library.meeting(job.meeting_id)? else {
            return Ok(Outcome::Done);
        };
        if meeting.is_live() {
            return Ok(Outcome::Done);
        }
        self.yield_to_capture();
        let settings = self.shared.settings();

        let has_transcript = library.transcript(&meeting)?.is_some();
        if job.transcribe || !has_transcript {
            let requirements = self.models.meeting_requirements(false);
            if !self.models.ensure(&requirements, job.user_initiated)? {
                return Ok(Outcome::WaitingForModels);
            }
            library.mark_job_started(meeting.id)?;
            self.stage(
                &meeting,
                Stage::PreparingModel("speech model".into()),
                "Preparing transcription model",
                None,
            );
            let audio = library.audio(&meeting);
            if audio.mic.is_none() && audio.system.is_none() {
                anyhow::bail!("No recording available.");
            }
            let options = lokalbot_speech::TranscribeOptions {
                language: Some(settings.transcription_language.clone())
                    .filter(|l| l != "auto" && !l.is_empty()),
                diarize: settings.multi_speaker_diarization,
                microphone_is_user: settings.microphone_is_user,
                vocabulary_prompt: Some(settings.transcription_prompt.clone())
                    .filter(|p| !p.trim().is_empty()),
                content_range: meeting.valid_content_range().map(|r| (r.start, r.end)),
            };
            self.stage(&meeting, Stage::Transcribing, "Transcribing", None);
            let transcript = self
                .shared
                .speech
                .with(&self.shared, &settings.transcription_model, |transcriber| {
                    transcriber.transcribe_meeting(
                        audio.mic.as_deref(),
                        audio.system.as_deref(),
                        &options,
                        &mut |progress| match progress {
                            lokalbot_speech::TranscribeProgress::Transcribing { fraction } => self
                                .stage(
                                    &meeting,
                                    Stage::Transcribing,
                                    "Transcribing",
                                    Some(fraction),
                                ),
                            lokalbot_speech::TranscribeProgress::IdentifyingSpeakers => self.stage(
                                &meeting,
                                Stage::IdentifyingSpeakers,
                                "Separating speakers",
                                None,
                            ),
                            _ => {}
                        },
                    )
                })
                .context("transcription")?;
            let mut transcript = transcript;
            if let Some(range) = meeting.valid_content_range() {
                range.apply(&mut transcript);
            }
            if meeting.is_merged_meeting() {
                transcript = lokalbot_core::merge::preserve_transcript_only_sources(
                    library.transcript(&meeting)?.as_ref(),
                    &library.meeting_dir(&meeting),
                    transcript,
                )?;
            }
            library.save_transcript(&meeting, &transcript)?;
            library.mark_transcription_completed(meeting.id)?;
            library.reindex_meeting(&meeting)?;
            self.shared.emit(EngineEvent::LibraryChanged);
            if transcript.segments.is_empty() {
                return Ok(Outcome::Done);
            }
        }

        if job.summarize {
            let Some(transcript) = library.transcript(&meeting)? else {
                return Ok(Outcome::Done);
            };
            if transcript.segments.is_empty() {
                return Ok(Outcome::Done);
            }
            let requirements = self.models.think_requirements();
            if !self.models.ensure(&requirements, job.user_initiated)? {
                return Ok(Outcome::WaitingForModels);
            }
            library.mark_job_started(meeting.id)?;
            self.yield_to_capture();
            self.stage(
                &meeting,
                Stage::PreparingModel("summary model".into()),
                "Preparing Think model",
                None,
            );
            let think = self.shared.think(&settings)?;
            self.stage(&meeting, Stage::Summarizing, "Writing notes", None);
            let user_notes = library.notes(&meeting)?;
            let notes = lokalbot_ai::notes::generate_meeting_notes(
                &think,
                &meeting,
                &transcript,
                &user_notes,
                &settings,
                &mut |detail: &str| self.stage(&meeting, Stage::Summarizing, detail, None),
            )?;
            library.save_summary(&meeting, &notes.summary_markdown)?;
            library.save_outcomes(&meeting, &notes.outcomes)?;
            lokalbot_core::library::write_json(
                &library.meeting_dir(&meeting).join("summary-claims.json"),
                &notes.claims,
            )?;
            // Notes match the transcript again (`MeetingAttributionArtifacts`).
            let _ = std::fs::remove_file(
                library
                    .meeting_dir(&meeting)
                    .join(lokalbot_core::library::REFRESH_MARKER),
            );
            library.reindex_meeting(&meeting)?;
            if settings.semantic_search_enabled
                && self
                    .models
                    .missing(&self.models.embedding_requirements())
                    .is_empty()
                && let Err(err) =
                    lokalbot_ai::embeddings::index_meeting(&self.shared.runtime, library, &meeting)
            {
                log::warn!("updating meaning search failed: {err:#}");
            }
        }
        Ok(Outcome::Done)
    }
}
