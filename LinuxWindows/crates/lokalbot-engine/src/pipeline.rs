//! The processing queue: transcribe, then write notes and actions, one meeting
//! at a time (`ProcessingPipeline.swift`, `PipelineJobStore.swift`).

use std::collections::VecDeque;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use anyhow::{Context as _, Result};
use parking_lot::{Condvar, Mutex};
use uuid::Uuid;

use lokalbot_ai::remote_gate::Priority;
use lokalbot_core::{Meeting, Transcript};

use crate::models::Models;
use crate::{BackgroundItem, BackgroundKind, EngineEvent, Shared, Stage};

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
    /// The meeting being worked on right now.
    active: Mutex<Option<Uuid>>,
    /// Automatic jobs parked because a model was missing. Their saved rows
    /// stay pending, and they go back into the queue once what they waited
    /// for is here (`waitingForModelsJobs`).
    waiting: Mutex<Vec<(Job, Need)>>,
}

/// How often the idle worker looks for a stop request and for parked jobs
/// whose models have arrived.
const IDLE_WAKE: Duration = if cfg!(test) {
    Duration::from_millis(50)
} else {
    Duration::from_secs(5)
};

#[derive(Clone, Debug)]
struct Job {
    meeting_id: Uuid,
    transcribe: bool,
    summarize: bool,
    /// The summary was asked for automatically, so it runs only while
    /// automatic summaries are on.
    summary_follows_setting: bool,
    user_initiated: bool,
    /// Picked up at launch, so it transcribes with the terms saved earlier.
    resumed: bool,
}

impl Job {
    /// A saved job picked up at launch (`ProcessingPipeline.resumedWork`).
    fn resumed(saved: &lokalbot_core::PipelineJob) -> Self {
        Self {
            meeting_id: saved.meeting_id,
            transcribe: saved.transcribe && !saved.transcription_completed,
            summarize: saved.summarize,
            summary_follows_setting: saved.summary_follows_setting,
            user_initiated: false,
            resumed: true,
        }
    }

    /// Whether to write notes now. An automatic summary follows the setting
    /// as it is at this point, so turning automatic summaries off also stops
    /// a job queued earlier, even one that waited through a restart.
    fn writes_notes(&self, auto_summarize: bool) -> bool {
        self.summarize && (!self.summary_follows_setting || auto_summarize)
    }

    /// Folds another request for the same meeting into this queued job. The
    /// user's request decides the summary and makes it explicit.
    fn merge(&mut self, transcribe: bool, summarize: bool, user_initiated: bool) {
        self.transcribe |= transcribe;
        self.summarize = if user_initiated {
            summarize
        } else {
            self.summarize || summarize
        };
        self.summary_follows_setting &= !user_initiated;
        self.user_initiated |= user_initiated;
    }
}

enum Outcome {
    Done,
    WaitingForModels(Need),
}

/// What a parked job is waiting for.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Need {
    /// The transcription models, or a transcription server's approval.
    Transcription,
    /// The Think model and its runtime.
    Think,
}

impl Pipeline {
    pub fn start(shared: Arc<Shared>, models: Models) -> Self {
        let inner = Arc::new(Inner {
            shared: shared.clone(),
            models,
            queue: Mutex::new(VecDeque::new()),
            signal: Condvar::new(),
            stop: AtomicBool::new(false),
            active: Mutex::new(None),
            waiting: Mutex::new(Vec::new()),
        });
        // Meetings deleted between the crash and this launch (`resumePending`).
        match shared.library.list_meetings().and_then(|meetings| {
            let existing: Vec<Uuid> = meetings.iter().map(|meeting| meeting.id).collect();
            shared.library.prune_jobs(&existing)
        }) {
            Ok(0) => {}
            Ok(removed) => log::info!("dropped {removed} processing job(s) for deleted meetings"),
            Err(err) => log::warn!("could not prune the processing queue: {err:#}"),
        }
        match shared.library.pending_jobs() {
            Ok(jobs) => {
                let mut queue = inner.queue.lock();
                for job in jobs {
                    shared.emit(EngineEvent::Processing {
                        meeting_id: job.meeting_id,
                        stage: Some(Stage::Queued),
                    });
                    queue.push_back(Job::resumed(&job));
                }
            }
            Err(err) => log::warn!("could not read pending jobs: {err:#}"),
        }
        // A job that used up its automatic attempts stays parked until the
        // user retries it; show why it stopped again (`parkedJobs`).
        match shared.library.parked_jobs() {
            Ok(jobs) => {
                for job in jobs {
                    let message = job
                        .last_error
                        .unwrap_or_else(|| "Processing stopped after repeated failures.".into());
                    shared.emit(EngineEvent::Processing {
                        meeting_id: job.meeting_id,
                        stage: Some(Stage::Failed(message)),
                    });
                }
            }
            Err(err) => log::warn!("could not read parked jobs: {err:#}"),
        }
        let worker = inner.clone();
        std::thread::Builder::new()
            .name("lokalbot-pipeline".into())
            .spawn(move || worker.run())
            .expect("spawning the pipeline thread");
        crate::speech::start_idle_release(shared.speech.clone(), shared.clone());
        let pipeline = Self { inner };
        // Finished recordings a run never transcribed, off the engine thread:
        // this reads every meeting folder (`enqueueMissingTranscriptions`).
        let settings = shared.settings();
        if settings.auto_transcribe {
            let repair = pipeline.clone();
            std::thread::Builder::new()
                .name("lokalbot-transcript-repair".into())
                .spawn(move || {
                    repair.enqueue_missing_transcriptions(settings.auto_summarize);
                })
                .expect("spawning the transcript repair");
        }
        pipeline
    }

    /// Queues finished recordings whose transcript is missing or incomplete and
    /// that have no queued, parked or running job. A merged gap is marked first,
    /// so it is repaired at most once. Returns what it queued.
    pub fn enqueue_missing_transcriptions(&self, summarize: bool) -> Vec<Uuid> {
        let shared = &self.inner.shared;
        let library = &shared.library;
        if library.is_read_only() {
            return Vec::new();
        }
        let meetings = match library.list_meetings() {
            Ok(meetings) => meetings,
            Err(err) => {
                log::warn!("could not look for missing transcripts: {err:#}");
                return Vec::new();
            }
        };
        let mut queued = Vec::new();
        for meeting in meetings {
            if self.is_processing(meeting.id) || library.job(meeting.id).ok().flatten().is_some() {
                continue;
            }
            let Some(reason) = lokalbot_core::health::missing_transcript(library, &meeting) else {
                continue;
            };
            if reason == lokalbot_core::health::MissingTranscript::MergedGap
                && let Err(err) = lokalbot_core::health::mark_gap_repair_requested(
                    &library.meeting_dir(&meeting),
                    chrono::Utc::now(),
                )
            {
                log::warn!("transcript repair skipped for {}: {err:#}", meeting.id);
                continue;
            }
            if self.enqueue(meeting.id, true, summarize, false) {
                log::info!("queued missing transcript for {} ({reason:?})", meeting.id);
                queued.push(meeting.id);
            }
        }
        queued
    }

    /// Whether the transcription models are here, so a job would start now
    /// rather than park (`ModelReadinessSnapshot.transcriptionReady`).
    pub fn transcription_ready(&self) -> bool {
        let models = &self.inner.models;
        models
            .missing(&models.meeting_requirements(false))
            .is_empty()
            && !models.transcription_server_blocked()
    }

    /// Saves a job for the next launch and leaves this run's queue alone. A
    /// request already saved stays as it is (`deferUntilNextLaunch`).
    pub fn defer_until_next_launch(&self, meeting_id: Uuid, summarize: bool) -> Result<()> {
        let library = &self.inner.shared.library;
        if library.job(meeting_id)?.is_none() {
            library.enqueue_job(meeting_id, true, summarize, false)?;
        }
        Ok(())
    }

    /// Queues a meeting. False when the job could not be saved: it is not
    /// queued, since a job that isn't saved would be lost on quit.
    pub fn enqueue(
        &self,
        meeting_id: Uuid,
        transcribe: bool,
        summarize: bool,
        user_initiated: bool,
    ) -> bool {
        let shared = &self.inner.shared;
        if let Err(err) =
            shared
                .library
                .enqueue_job(meeting_id, transcribe, summarize, user_initiated)
        {
            log::warn!("could not persist the processing job: {err:#}");
            shared.emit(EngineEvent::Processing {
                meeting_id,
                stage: Some(Stage::Failed(
                    "Could not persist the processing job.".into(),
                )),
            });
            return false;
        }
        // A new request takes over a job parked for models and keeps its work.
        let parked = {
            let mut waiting = self.inner.waiting.lock();
            waiting
                .iter()
                .position(|(job, _)| job.meeting_id == meeting_id)
                .map(|index| waiting.remove(index).0)
        };
        {
            let mut queue = self.inner.queue.lock();
            if let Some(existing) = queue.iter_mut().find(|job| job.meeting_id == meeting_id) {
                existing.merge(transcribe, summarize, user_initiated);
            } else if let Some(mut parked) = parked {
                parked.merge(transcribe, summarize, user_initiated);
                queue.push_back(parked);
            } else {
                queue.push_back(Job {
                    meeting_id,
                    transcribe,
                    summarize,
                    summary_follows_setting: !user_initiated,
                    user_initiated,
                    resumed: false,
                });
            }
        }
        shared.emit(EngineEvent::Processing {
            meeting_id,
            stage: Some(Stage::Queued),
        });
        self.inner.signal.notify_one();
        true
    }

    /// Nothing is queued or being processed.
    pub fn is_idle(&self) -> bool {
        self.inner.active.lock().is_none() && self.inner.queue.lock().is_empty()
    }

    pub fn is_processing(&self, meeting_id: Uuid) -> bool {
        *self.inner.active.lock() == Some(meeting_id)
            || self
                .inner
                .queue
                .lock()
                .iter()
                .any(|job| job.meeting_id == meeting_id)
    }

    pub fn stop(&self) {
        self.inner.stop.store(true, Ordering::Relaxed);
        self.inner.signal.notify_all();
    }
}

impl Inner {
    fn run(self: Arc<Self>) {
        loop {
            let job = loop {
                if self.stop.load(Ordering::Relaxed) {
                    return;
                }
                self.requeue_ready();
                let mut queue = self.queue.lock();
                if let Some(job) = queue.pop_front() {
                    *self.active.lock() = Some(job.meeting_id);
                    break job;
                }
                self.signal.wait_for(&mut queue, IDLE_WAKE);
            };
            self.publish_queue_length();
            let meeting_id = job.meeting_id;
            self.shared.pipeline_busy.store(true, Ordering::Relaxed);
            match self.process(&job) {
                Ok(Outcome::Done) => {
                    let _ = self.shared.library.mark_job_completed(meeting_id);
                    self.shared.emit(EngineEvent::Processing {
                        meeting_id,
                        stage: None,
                    });
                }
                Ok(Outcome::WaitingForModels(need)) => {
                    self.park(job, need);
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
            *self.active.lock() = None;
            self.shared
                .clear_background(&format!("meeting:{meeting_id}"));
            let more = !self.queue.lock().is_empty();
            self.shared.pipeline_busy.store(more, Ordering::Relaxed);
            // A finished meeting has a note and a follow-up due.
            self.shared.exports.reconsider_notes();
            self.shared.routines.reconsider_evidence();
            self.shared.emit(EngineEvent::LibraryChanged);
        }
    }

    /// Sets a job aside until what it waits for is here. A job that got as
    /// far as its notes has committed its transcript, so it goes on without
    /// asking for one: transcribing the meeting a second time would cost as
    /// long as the first and replace a transcript people may have corrected.
    /// `Job::resumed` drops a finished transcription the same way at launch.
    fn park(&self, mut job: Job, need: Need) {
        if need == Need::Think {
            job.transcribe = false;
        }
        self.waiting.lock().push((job, need));
    }

    /// Whether the models for `need` are here, so a job parked for them
    /// would get past that point now. Nothing downloads from here.
    fn ready(&self, need: Need) -> bool {
        match need {
            Need::Transcription => {
                self.models
                    .missing(&self.models.meeting_requirements(false))
                    .is_empty()
                    && !self.models.transcription_server_blocked()
            }
            Need::Think => self
                .models
                .missing(&self.models.think_requirements())
                .is_empty(),
        }
    }

    /// Puts parked jobs back in the queue once their models are installed,
    /// the selection changed to ones that are, the server was approved, or
    /// the job no longer needs what it waited for.
    fn requeue_ready(&self) {
        let needs: Vec<Need> = {
            let waiting = self.waiting.lock();
            if waiting.is_empty() {
                return;
            }
            [Need::Transcription, Need::Think]
                .into_iter()
                .filter(|need| waiting.iter().any(|(_, parked)| parked == need))
                .collect()
        };
        // Looks at files, so no lock is held meanwhile.
        let ready: Vec<Need> = needs.into_iter().filter(|need| self.ready(*need)).collect();
        // With automatic summaries turned off, a job that waited for the
        // Think model only to write one has nothing left to wait for.
        let auto_summarize = self.shared.settings().auto_summarize;
        let jobs: Vec<Job> = {
            let mut waiting = self.waiting.lock();
            let (ready, parked) =
                std::mem::take(&mut *waiting)
                    .into_iter()
                    .partition(|(job, need)| {
                        ready.contains(need)
                            || (*need == Need::Think && !job.writes_notes(auto_summarize))
                    });
            *waiting = parked;
            ready.into_iter().map(|(job, _)| job).collect()
        };
        if jobs.is_empty() {
            return;
        }
        log::info!(
            "pipeline rechecking {} job(s) that waited for models",
            jobs.len()
        );
        for job in jobs {
            let meeting_id = job.meeting_id;
            {
                let mut queue = self.queue.lock();
                // A request made meanwhile is already queued and covers it.
                if queue.iter().all(|queued| queued.meeting_id != meeting_id) {
                    queue.push_back(job);
                }
            }
            self.shared.emit(EngineEvent::Processing {
                meeting_id,
                stage: Some(Stage::Queued),
            });
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

    /// A summary-only retry still gets the names an interrupted run decided.
    /// Speaker identity is optional: it must not block notes from a saved
    /// transcript or use up an automatic retry.
    fn recover_speakers(&self, meeting: &Meeting, transcript: Transcript) -> Result<Transcript> {
        let library = &self.shared.library;
        let sealed = library
            .meeting_dir(meeting)
            .join(lokalbot_core::voice::EVIDENCE_FOLDER)
            .join(lokalbot_core::voice::IDENTITY_FILE);
        if !sealed.is_file() {
            return Ok(transcript);
        }
        let memory = crate::voice::memory(library);
        let recovered = memory.recover(meeting, &transcript).unwrap_or_else(|err| {
            log::info!(
                "speaker identity recovery skipped meeting={}: {err}",
                meeting.id
            );
            transcript
        });
        let recovered = memory.applying_latest_decision(&recovered, meeting.id);
        library.save_new_transcript(meeting, &recovered)?;
        Ok(recovered)
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
                return Ok(Outcome::WaitingForModels(Need::Transcription));
            }
            // Audio waits for an approval; asking directly says what's missing.
            if !job.user_initiated && self.models.transcription_server_blocked() {
                return Ok(Outcome::WaitingForModels(Need::Transcription));
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
                vocabulary_prompt: Some(lokalbot_core::vocabulary::transcription_prompt(
                    &meeting,
                    library,
                    &settings,
                    lokalbot_speech::models::accepts_vocabulary(&settings.transcription_model),
                    job.resumed,
                ))
                .filter(|p| !p.trim().is_empty()),
                content_range: meeting.valid_content_range().map(|r| (r.start, r.end)),
                collect_voice_samples: !meeting.is_sample(),
                echo: settings
                    .echo_cancellation
                    .then(|| lokalbot_core::voice::reference_clock(&library.meeting_dir(&meeting))),
                clock: Some(lokalbot_core::voice::reference_clock(
                    &library.meeting_dir(&meeting),
                )),
            };
            self.stage(&meeting, Stage::Transcribing, "Transcribing", None);
            let detailed = self
                .shared
                .speech
                .with_in_background(&self.shared, &settings.transcription_model, |transcriber| {
                    transcriber.transcribe_meeting_detailed(
                        audio.mic.as_deref(),
                        audio.system.as_deref(),
                        &options,
                        &mut |progress| match progress {
                            lokalbot_speech::TranscribeProgress::Transcribing { fraction } => {
                                // Reported after each span: a dictation or a
                                // preview waiting for the model goes first.
                                self.shared.speech.stand_aside();
                                self.stage(
                                    &meeting,
                                    Stage::Transcribing,
                                    "Transcribing",
                                    Some(fraction),
                                )
                            }
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
            let mut transcript = detailed.transcript;
            if let Some(range) = meeting.valid_content_range() {
                range.apply(&mut transcript);
            }
            let previous = library.transcript(&meeting)?;
            // Names remembered voices and carries over what people decided.
            // Identity errors never fail audio transcription.
            let memory = crate::voice::memory(library);
            let evidence = crate::voice::microphone_evidence(
                library,
                &meeting,
                &transcript,
                &detailed.turns,
                &detailed.samples,
            );
            let identified = memory.process(lokalbot_core::voice::ProcessRequest {
                transcript: &transcript,
                meeting: &meeting,
                turns: &detailed.turns,
                evidence,
                mic: audio.mic.as_deref(),
                system: audio.system.as_deref(),
                previous: previous.as_ref(),
                name_automatically: crate::voice::NAME_SPEAKERS_AUTOMATICALLY,
            });
            transcript = match identified {
                Ok(named) => named,
                Err(err) => {
                    log::warn!("speaker identity skipped meeting={}: {err}", meeting.id);
                    memory.note_unavailable(meeting.id, &err);
                    // Names the user gave speakers survive a new transcription.
                    if let Some(previous) = &previous {
                        transcript.carry_speaker_names_from(previous);
                    }
                    transcript
                }
            };
            let transcript = finished_transcript(
                &meeting,
                &library.meeting_dir(&meeting),
                previous.as_ref(),
                transcript,
                options.vocabulary_prompt.as_deref(),
            )?;
            let transcript = memory.applying_latest_decision(&transcript, meeting.id);
            library.save_new_transcript(&meeting, &transcript)?;
            library.mark_transcription_completed(meeting.id)?;
            library.reindex_meeting(&meeting)?;
            self.shared.emit(EngineEvent::LibraryChanged);
            if transcript.segments.is_empty() {
                return Ok(Outcome::Done);
            }
        }

        if job.writes_notes(self.shared.settings().auto_summarize) {
            let Some(mut transcript) = library.transcript(&meeting)? else {
                return Ok(Outcome::Done);
            };
            // The vocabulary this meeting was transcribed with, so rows that
            // only repeat it never become notes evidence.
            let saved_prompt = lokalbot_core::vocabulary::saved_prompt(
                &settings.transcription_prompt,
                &library.meeting_dir(&meeting),
            );
            if lokalbot_speech::sanitize(&mut transcript, Some(&saved_prompt)).changed() {
                library.save_transcript(&meeting, &transcript)?;
            }
            if transcript.segments.is_empty() {
                return Ok(Outcome::Done);
            }
            let transcript = self.recover_speakers(&meeting, transcript)?;
            let requirements = self.models.think_requirements();
            if !self.models.ensure(&requirements, job.user_initiated)? {
                return Ok(Outcome::WaitingForModels(Need::Think));
            }
            library.mark_job_started(meeting.id)?;
            self.yield_to_capture();
            self.stage(
                &meeting,
                Stage::PreparingModel("summary model".into()),
                "Preparing Think model",
                None,
            );
            let think = self
                .shared
                .think(&settings)?
                .with_priority(Priority::Pipeline, "meeting notes");
            self.stage(&meeting, Stage::Summarizing, "Writing notes", None);
            let user_notes = library.notes(&meeting)?;
            let started = std::time::Instant::now();
            let folder = library.meeting_dir(&meeting);
            let options = lokalbot_ai::notes::NotesOptions {
                checkpoint_dir: Some(folder.clone()),
                retrying_stopped_parts: job.user_initiated,
                cancel: None,
                // On-screen titles as secondary, source-labeled context.
                screen_titles: if settings.meeting_notes_use_screen_titles && !meeting.is_imported()
                {
                    library.meeting_screen_context(&meeting).material_titles()
                } else {
                    Vec::new()
                },
            };
            let notes = lokalbot_ai::notes::generate_meeting_notes_with(
                &think,
                &meeting,
                &transcript,
                &user_notes,
                &settings,
                &options,
                &mut |detail: &str| self.stage(&meeting, Stage::Summarizing, detail, None),
            )?;
            self.shared.generation_metrics.record(
                format!("Summary · {}", think.display_name()),
                started.elapsed().as_secs_f64(),
                &notes.summary_markdown,
            );
            // Notes for a transcript that changed meanwhile would be wrong.
            if library.transcript(&meeting)?.as_ref() != Some(&transcript) {
                anyhow::bail!(
                    "Speaker attribution changed during generation. Refresh the meeting notes."
                );
            }
            let previous = match library.outcomes(&meeting)? {
                Some(outcomes) => Some(outcomes),
                None => library.previous_outcomes(&meeting)?,
            };
            let state = library.outcome_state(&meeting)?;
            library.save_outcomes(&meeting, &notes.outcomes)?;
            if let Some(previous) = &previous {
                let reconciled = lokalbot_core::meeting_review::reconcile_state(
                    &state,
                    previous,
                    &notes.outcomes,
                );
                library.save_outcome_state(&meeting, &reconciled)?;
            }
            // Explicit user edits stay the authority for the sections beside them.
            let authoritative = library
                .outcome_projection(&meeting)?
                .map(|projection| projection.corrected_outcomes())
                .unwrap_or_else(|| notes.outcomes.clone());
            let summary = lokalbot_ai::notes::render::synchronize(
                &notes.summary_markdown,
                &authoritative,
                settings.note_template,
            );
            lokalbot_core::library::write_json(&folder.join("summary-claims.json"), &notes.claims)?;
            library.save_summary(&meeting, &summary)?;
            lokalbot_ai::notes::remove_checkpoint(&folder);
            // Notes match the transcript again (`MeetingAttributionArtifacts`).
            let _ = std::fs::remove_file(folder.join(lokalbot_core::library::REFRESH_MARKER));
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

/// The transcript to commit: rows a merged meeting's transcript-only sources
/// keep, then the cleanup every source of rows must pass, kept or new
/// (`transcript cleanup after merge`).
fn finished_transcript(
    meeting: &Meeting,
    folder: &std::path::Path,
    previous: Option<&lokalbot_core::Transcript>,
    regenerated: lokalbot_core::Transcript,
    prompt: Option<&str>,
) -> Result<lokalbot_core::Transcript> {
    let mut transcript = if meeting.is_merged_meeting() {
        lokalbot_core::merge::preserve_transcript_only_sources(previous, folder, regenerated)?
    } else {
        regenerated
    };
    let report = lokalbot_speech::sanitize(&mut transcript, prompt);
    if report.changed() {
        log::info!(
            "transcript cleanup after merge changed={} removed={} removed_words={}",
            report.changed_segments,
            report.removed_segments,
            report.removed_words
        );
    }
    Ok(transcript)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A finished recording with audio on disk and no transcript.
    fn finished_recording(library: &lokalbot_core::Library, title: &str) -> Meeting {
        let started = chrono::Utc::now() - chrono::Duration::hours(2);
        let mut meeting = library.create_meeting(title, "Zoom", started).unwrap();
        lokalbot_audio::write_wav_16k(
            &library.meeting_dir(&meeting).join(lokalbot_audio::MIC_FILE),
            &vec![0.25f32; 16_000 * 6],
        )
        .unwrap();
        meeting.ended_at = Some(started + chrono::Duration::minutes(5));
        meeting.recorded_duration = Some(6.0);
        library.save_meeting(&meeting).unwrap();
        meeting
    }

    fn library() -> (tempfile::TempDir, lokalbot_core::Library) {
        let dir = tempfile::tempdir().unwrap();
        let library =
            lokalbot_core::Library::open(lokalbot_core::LibraryPaths::new(dir.path())).unwrap();
        (dir, library)
    }

    fn pipeline(library: lokalbot_core::Library, settings: lokalbot_core::Settings) -> Pipeline {
        let shared = Shared::for_tests(library, settings, |_| {});
        let models = crate::models::Models::new(shared.clone());
        Pipeline::start(shared, models)
    }

    /// Waits for the launch repair, which runs on a thread of its own.
    fn wait_for_jobs(library: &lokalbot_core::Library, count: usize) {
        let deadline = std::time::Instant::now() + Duration::from_secs(10);
        while library.pending_jobs().unwrap().len() < count {
            assert!(std::time::Instant::now() < deadline, "no job was queued");
            std::thread::sleep(Duration::from_millis(20));
        }
    }

    #[test]
    fn launch_queues_finished_recordings_that_never_got_a_transcript() {
        let (_dir, library) = library();
        let missing = finished_recording(&library, "Never transcribed");
        let settings = lokalbot_core::Settings {
            auto_transcribe: true,
            auto_summarize: false,
            ..Default::default()
        };
        let pipeline = pipeline(library.clone(), settings);
        pipeline.stop();
        wait_for_jobs(&library, 1);
        let job = library.job(missing.id).unwrap().unwrap();
        assert!(job.transcribe && !job.summarize);
        assert!(job.summary_follows_setting);
    }

    #[test]
    fn launch_leaves_recordings_alone_while_automatic_transcription_is_off() {
        let (_dir, library) = library();
        finished_recording(&library, "Kept as audio");
        let settings = lokalbot_core::Settings {
            auto_transcribe: false,
            ..Default::default()
        };
        let pipeline = pipeline(library.clone(), settings);
        pipeline.stop();
        std::thread::sleep(Duration::from_millis(200));
        assert!(library.pending_jobs().unwrap().is_empty());
    }

    #[test]
    fn a_repair_skips_parked_and_transcribed_meetings() {
        let (_dir, library) = library();
        let parked = finished_recording(&library, "Failed three times");
        library.enqueue_job(parked.id, true, true, false).unwrap();
        for _ in 0..lokalbot_core::jobs::MAX_AUTO_RESUME_ATTEMPTS {
            library.mark_job_started(parked.id).unwrap();
        }
        let done = finished_recording(&library, "Transcribed");
        std::fs::write(library.meeting_dir(&done).join("transcript.json"), "{}").unwrap();
        let settings = lokalbot_core::Settings {
            auto_transcribe: false,
            ..Default::default()
        };
        let pipeline = pipeline(library.clone(), settings);
        pipeline.stop();
        assert!(pipeline.enqueue_missing_transcriptions(false).is_empty());
        assert!(library.pending_jobs().unwrap().is_empty());
    }

    #[test]
    fn a_merged_gap_is_repaired_at_most_once() {
        let (_dir, library) = library();
        let mut meeting = finished_recording(&library, "Merged");
        meeting.recorded_duration = Some(200.0);
        meeting.merged_source_meeting_ids = Some(vec![Uuid::new_v4(), Uuid::new_v4()]);
        library.save_meeting(&meeting).unwrap();
        let folder = library.meeting_dir(&meeting);
        let started = meeting.started_at;
        let source = |duration: f64| lokalbot_core::merge::ManifestSource {
            id: Uuid::new_v4(),
            title: "Source".into(),
            started_at: started,
            duration,
            has_audio: Some(true),
            has_transcript: Some(true),
        };
        std::fs::write(
            folder.join(lokalbot_core::merge::MANIFEST_FILE),
            serde_json::to_vec(&lokalbot_core::merge::Manifest {
                version: 2,
                sources: vec![source(100.0), source(100.0)],
            })
            .unwrap(),
        )
        .unwrap();
        // The transcript has nothing at all in the second source's span.
        let transcript = lokalbot_core::Transcript {
            segments: vec![lokalbot_core::Segment {
                start: 1.0,
                end: 5.0,
                speaker: "source1:them".into(),
                text: "Only the first half.".into(),
                confidence: None,
                timing_precision: None,
                attribution: None,
            }],
            ..Default::default()
        };
        library.save_new_transcript(&meeting, &transcript).unwrap();
        let settings = lokalbot_core::Settings {
            auto_transcribe: false,
            ..Default::default()
        };
        let pipeline = pipeline(library.clone(), settings);
        pipeline.stop();

        assert_eq!(
            pipeline.enqueue_missing_transcriptions(true),
            vec![meeting.id]
        );
        let marker: serde_json::Value = serde_json::from_slice(
            &std::fs::read(folder.join("transcript-gap-repair.json")).unwrap(),
        )
        .unwrap();
        assert!(marker["requestedAt"].as_str().unwrap().ends_with('Z'));

        library.mark_job_completed(meeting.id).unwrap();
        assert!(pipeline.enqueue_missing_transcriptions(true).is_empty());
    }

    #[test]
    fn jobs_for_deleted_meetings_go_at_launch() {
        let (_dir, library) = library();
        let kept = finished_recording(&library, "Kept");
        library.enqueue_job(kept.id, true, false, false).unwrap();
        let gone = Uuid::new_v4();
        library.enqueue_job(gone, true, false, false).unwrap();
        let pipeline = pipeline(library.clone(), lokalbot_core::Settings::default());
        pipeline.stop();
        assert!(library.job(gone).unwrap().is_none());
        assert!(library.job(kept.id).unwrap().is_some());
    }

    /// A merged meeting whose first source had a transcript and no audio.
    fn merged_with_transcript_only_source(folder: &std::path::Path) -> Meeting {
        let started = chrono::Utc::now();
        let mut meeting = Meeting::new("Both", "Merged meetings", started, "both");
        meeting.merged_source_meeting_ids = Some(vec![Uuid::new_v4(), Uuid::new_v4()]);
        let source = |has_audio, has_transcript| lokalbot_core::merge::ManifestSource {
            id: Uuid::new_v4(),
            title: "Source".into(),
            started_at: started,
            duration: 100.0,
            has_audio: Some(has_audio),
            has_transcript: Some(has_transcript),
        };
        let manifest = lokalbot_core::merge::Manifest {
            version: 2,
            sources: vec![source(false, true), source(true, true)],
        };
        std::fs::write(
            folder.join(lokalbot_core::merge::MANIFEST_FILE),
            serde_json::to_vec(&manifest).unwrap(),
        )
        .unwrap();
        meeting
    }

    fn row(start: f64, end: f64, text: &str) -> lokalbot_core::Segment {
        lokalbot_core::Segment {
            start,
            end,
            speaker: "source1:them".into(),
            text: text.into(),
            confidence: None,
            timing_precision: None,
            attribution: None,
        }
    }

    #[test]
    fn rows_kept_from_a_transcript_only_source_are_cleaned_too() {
        let dir = tempfile::tempdir().unwrap();
        let meeting = merged_with_transcript_only_source(dir.path());
        let previous = lokalbot_core::Transcript {
            segments: vec![row(3.0, 13.0, &vec!["thank you"; 40].join(" "))],
            ..Default::default()
        };
        let regenerated = lokalbot_core::Transcript {
            segments: vec![row(120.0, 125.0, "Recorded speech")],
            ..Default::default()
        };
        let finished =
            finished_transcript(&meeting, dir.path(), Some(&previous), regenerated, None).unwrap();
        let texts: Vec<_> = finished.segments.iter().map(|s| s.text.as_str()).collect();
        assert_eq!(texts, ["thank you thank you", "Recorded speech"]);
    }

    #[test]
    fn rows_that_only_repeat_the_vocabulary_are_removed_after_the_merge() {
        let dir = tempfile::tempdir().unwrap();
        let meeting = merged_with_transcript_only_source(dir.path());
        let prompt = "Vocabulary: LokalBot, Zagreb, Qwen, Parakeet.";
        let previous = lokalbot_core::Transcript {
            segments: vec![
                row(3.0, 13.0, prompt),
                row(20.0, 25.0, "Notes from the first call"),
            ],
            ..Default::default()
        };
        let finished = finished_transcript(
            &meeting,
            dir.path(),
            Some(&previous),
            lokalbot_core::Transcript::default(),
            Some(prompt),
        )
        .unwrap();
        let texts: Vec<_> = finished.segments.iter().map(|s| s.text.as_str()).collect();
        assert_eq!(texts, ["Notes from the first call"]);
    }

    fn saved(summary_follows_setting: bool) -> lokalbot_core::PipelineJob {
        lokalbot_core::PipelineJob {
            meeting_id: Uuid::new_v4(),
            transcribe: true,
            transcription_completed: true,
            summarize: true,
            summary_follows_setting,
            attempts: 1,
            last_error: None,
        }
    }

    #[test]
    fn a_resumed_automatic_summary_follows_the_current_setting() {
        let automatic = Job::resumed(&saved(true));
        assert!(
            !automatic.transcribe,
            "its transcript was already committed"
        );
        assert!(automatic.writes_notes(true));
        assert!(!automatic.writes_notes(false));

        let explicit = Job::resumed(&saved(false));
        assert!(
            explicit.writes_notes(false),
            "an explicit request still runs"
        );
    }

    #[test]
    fn an_explicit_request_overrides_a_queued_automatic_one() {
        let mut job = Job::resumed(&saved(true));
        job.merge(false, true, true);
        assert!(job.writes_notes(false));
        let mut job = Job::resumed(&saved(false));
        job.merge(true, true, false);
        assert!(
            job.writes_notes(false),
            "an automatic enqueue keeps it explicit"
        );
    }

    /// A finished meeting whose audio is gone, so a job that gets past the
    /// model check stops at "No recording available." and loads nothing.
    fn finished_without_audio(library: &lokalbot_core::Library) -> Meeting {
        let started = chrono::Utc::now() - chrono::Duration::hours(2);
        let mut meeting = library
            .create_meeting("Recorded before the download", "Zoom", started)
            .unwrap();
        meeting.ended_at = Some(started + chrono::Duration::minutes(5));
        library.save_meeting(&meeting).unwrap();
        meeting
    }

    /// Makes a speech model count as installed without real model files.
    fn pretend_installed(library: &lokalbot_core::Library, id: &str) {
        let model = lokalbot_speech::models::find(id).unwrap();
        for file in model.files {
            let path = lokalbot_speech::models::model_file(library.paths(), model, file);
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(path, b"not a model").unwrap();
        }
        lokalbot_speech::models::finish_install(library.paths(), model).unwrap();
    }

    type Stages = Arc<Mutex<Vec<Option<Stage>>>>;

    fn wait_for_stage(stages: &Stages, wanted: impl Fn(&Option<Stage>) -> bool) {
        let deadline = std::time::Instant::now() + Duration::from_secs(10);
        while !stages.lock().iter().any(&wanted) {
            assert!(
                std::time::Instant::now() < deadline,
                "stages so far: {:?}",
                stages.lock()
            );
            std::thread::sleep(Duration::from_millis(10));
        }
    }

    #[test]
    fn a_recording_that_waited_for_models_is_processed_once_they_are_installed() {
        let (_dir, library) = library();
        let meeting = finished_without_audio(&library);
        let settings = lokalbot_core::Settings {
            auto_transcribe: false,
            auto_summarize: false,
            ..Default::default()
        };
        let stages = Stages::default();
        let seen = stages.clone();
        let shared = Shared::for_tests(library.clone(), settings, move |event| {
            if let EngineEvent::Processing { stage, .. } = event {
                seen.lock().push(stage);
            }
        });
        let models = crate::models::Models::new(shared.clone());
        let needed = models.meeting_requirements(false);
        assert!(!needed.is_empty());
        let pipeline = Pipeline::start(shared, models);

        assert!(pipeline.enqueue(meeting.id, true, false, false));
        wait_for_stage(&stages, |stage| *stage == Some(Stage::WaitingForModels));
        // Several idle wakes later it is still parked and has used no attempt.
        std::thread::sleep(IDLE_WAKE * 4);
        assert_eq!(
            *stages.lock(),
            [Some(Stage::Queued), Some(Stage::WaitingForModels)]
        );
        assert_eq!(library.job(meeting.id).unwrap().unwrap().attempts, 0);

        for id in &needed {
            pretend_installed(&library, id);
        }
        wait_for_stage(&stages, |stage| matches!(stage, Some(Stage::Failed(_))));
        pipeline.stop();
        let stages = stages.lock();
        assert_eq!(
            stages[..3],
            [
                Some(Stage::Queued),
                Some(Stage::WaitingForModels),
                Some(Stage::Queued)
            ]
        );
        assert_eq!(
            stages.last().unwrap(),
            &Some(Stage::Failed("No recording available.".into()))
        );
        assert_eq!(library.job(meeting.id).unwrap().unwrap().attempts, 1);
    }

    /// A pipeline whose worker has stopped, so a test can look at what a
    /// request left in the queue.
    fn stopped(settings: lokalbot_core::Settings) -> (tempfile::TempDir, Pipeline, Meeting) {
        let (dir, library) = library();
        let meeting = finished_without_audio(&library);
        let pipeline = pipeline(library, settings);
        pipeline.stop();
        // Past its last wake, so nothing takes a job out of the queue.
        std::thread::sleep(IDLE_WAKE * 4);
        (dir, pipeline, meeting)
    }

    /// An automatic job as it is when its transcription has just finished.
    fn transcribed(meeting: &Meeting) -> Job {
        Job {
            meeting_id: meeting.id,
            transcribe: true,
            summarize: true,
            summary_follows_setting: true,
            user_initiated: false,
            resumed: false,
        }
    }

    /// Transcription models here, the Think model still downloading: the
    /// meeting was transcribed and waits for its notes. It must not be
    /// transcribed again, by the model arriving or by a request for notes.
    #[test]
    fn a_job_that_waits_for_its_notes_never_transcribes_again() {
        let settings = lokalbot_core::Settings {
            auto_transcribe: false,
            // A server needs no download, so Think counts as ready.
            summarizer_backend: lokalbot_core::settings::SummarizerBackend::Ollama,
            ..Default::default()
        };
        let (_dir, pipeline, meeting) = stopped(settings);
        let inner = &pipeline.inner;

        inner.park(transcribed(&meeting), Need::Think);
        inner.requeue_ready();
        {
            let mut queue = inner.queue.lock();
            assert_eq!(queue.len(), 1, "Think is ready, so the job goes on");
            assert!(!queue[0].transcribe, "it would transcribe a second time");
            assert!(queue[0].summarize);
            queue.clear();
        }

        // Asking for notes while it waits takes the job over.
        inner.park(transcribed(&meeting), Need::Think);
        assert!(pipeline.enqueue(meeting.id, false, true, true));
        {
            let mut queue = inner.queue.lock();
            assert_eq!(queue.len(), 1);
            assert!(
                !queue[0].transcribe,
                "notes were asked for, not a transcript"
            );
            queue.clear();
        }

        // Asking for a new transcript is still honoured.
        inner.park(transcribed(&meeting), Need::Think);
        assert!(pipeline.enqueue(meeting.id, true, true, true));
        assert!(inner.queue.lock()[0].transcribe);

        // A job that never got to transcribe keeps that work.
        inner.park(transcribed(&meeting), Need::Transcription);
        assert!(inner.waiting.lock()[0].0.transcribe);
    }

    #[test]
    fn a_job_waiting_for_think_goes_on_when_automatic_summaries_are_turned_off() {
        // The built-in Think model is not installed in this library.
        let settings = lokalbot_core::Settings {
            auto_transcribe: false,
            auto_summarize: true,
            ..Default::default()
        };
        let (_dir, pipeline, meeting) = stopped(settings.clone());
        let inner = &pipeline.inner;
        // One summary follows the setting, the other was asked for.
        let other = Uuid::new_v4();
        inner.park(transcribed(&meeting), Need::Think);
        inner.park(
            Job {
                meeting_id: other,
                summary_follows_setting: false,
                ..transcribed(&meeting)
            },
            Need::Think,
        );

        inner.requeue_ready();
        assert!(inner.queue.lock().is_empty(), "the model is still missing");
        assert_eq!(inner.waiting.lock().len(), 2);

        *inner.shared.settings.write() = lokalbot_core::Settings {
            auto_summarize: false,
            ..settings
        };
        inner.requeue_ready();
        let queued: Vec<Uuid> = inner
            .queue
            .lock()
            .iter()
            .map(|job| job.meeting_id)
            .collect();
        assert_eq!(queued, [meeting.id], "it has nothing left to wait for");
        let waiting: Vec<Uuid> = inner
            .waiting
            .lock()
            .iter()
            .map(|(job, _)| job.meeting_id)
            .collect();
        assert_eq!(waiting, [other], "a summary someone asked for still waits");
    }

    #[test]
    fn a_new_request_takes_over_a_job_parked_for_models() {
        let (_dir, library) = library();
        let meeting = finished_without_audio(&library);
        let settings = lokalbot_core::Settings {
            auto_transcribe: false,
            ..Default::default()
        };
        let pipeline = pipeline(library, settings);
        pipeline.stop();
        // Past its last wake, so nothing takes the job out of the queue.
        std::thread::sleep(IDLE_WAKE * 4);
        let parked = Job {
            meeting_id: meeting.id,
            transcribe: true,
            summarize: false,
            summary_follows_setting: true,
            user_initiated: false,
            resumed: true,
        };
        pipeline
            .inner
            .waiting
            .lock()
            .push((parked, Need::Transcription));

        assert!(pipeline.enqueue(meeting.id, false, true, true));
        assert!(pipeline.inner.waiting.lock().is_empty());
        let queue = pipeline.inner.queue.lock();
        assert_eq!(queue.len(), 1);
        let job = &queue[0];
        assert!(job.transcribe, "the parked work is kept");
        assert!(job.summarize && job.user_initiated && !job.summary_follows_setting);
    }
}
