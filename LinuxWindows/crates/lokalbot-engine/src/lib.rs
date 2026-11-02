//! LokalBot's background engine for Linux and Windows.
//!
//! The app sends [`Command`]s; the engine does the work on its own threads and
//! reports back through [`EngineEvent`]s. Nothing here touches the UI.

mod ask;
mod autocomplete;
mod autocomplete_measure;
mod autocomplete_window_text;
mod calendar;
mod capture_health;
pub mod coding_agents;
pub mod companion;
mod daymemory;
mod detector;
pub mod diagnostics;
mod dictation;
mod dictation_context;
mod digest;
pub mod dreaming;
pub mod events;
pub mod exports;
pub mod files;
pub mod health_check;
mod indexing;
pub mod library_ops;
mod live;
mod model_checks;
mod models;
mod pipeline;
mod project_notes;
mod recording;
mod resources;
mod retention;
pub mod routines;
pub mod sample;
mod screen;
pub mod screen_vectors;
pub mod secrets;
mod selection;
mod speak;
mod speech;
mod upcoming;
pub mod voice;

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread::JoinHandle;

use anyhow::Result;
use crossbeam_channel::{Receiver, Sender, unbounded};
use parking_lot::{Mutex, RwLock};

use chrono::Utc;
use lokalbot_core::{Library, Settings};
use recording::{RecordingStart, StartSource};

pub use autocomplete::saved_facts as autocomplete_saved_facts;
pub use calendar::{CalendarSnapshot, CalendarStatus};
pub use companion::{
    CompanionCommand, CompanionDevice, CompanionNetwork, CompanionPairing, CompanionSnapshot,
    CompanionStatus, PairingRequest,
};
pub use events::*;
pub use recording::recover_unfinished_recordings;
pub use resources::{GenerationMetric, LoadedModel, ResourceSampler, ResourceSnapshot};
pub use selection::{SelectionPhase, SelectionView};
pub use speak::EXPORT_KEY as SPEECH_EXPORT_KEY;

/// State every subsystem shares.
pub(crate) struct Shared {
    pub library: Library,
    settings: RwLock<Settings>,
    emit: Box<dyn Fn(EngineEvent) + Send + Sync>,
    /// True while a meeting or dictation is capturing audio; heavy work waits.
    pub capture_active: AtomicBool,
    /// True while a meeting is being recorded.
    pub recording_active: AtomicBool,
    /// The meeting being recorded, which screen captures are linked to.
    pub recording_meeting: Mutex<Option<uuid::Uuid>>,
    /// An autocomplete suggestion is on screen.
    pub autocomplete_visible: AtomicBool,
    /// Autocomplete is asking its model for a suggestion.
    pub autocomplete_generating: AtomicBool,
    /// A dictation is being transcribed or composed.
    pub dictation_working: AtomicBool,
    /// Where the dictation in progress is, which a recording may not start over.
    pub dictation_state: Arc<Mutex<dictation::State>>,
    pub speech: Arc<speech::SpeechCache>,
    pub generation_metrics: resources::GenerationMetrics,
    pub runtime: lokalbot_ai::runtime::RuntimeManager,
    background: Mutex<Vec<BackgroundItem>>,
    pub shutting_down: AtomicBool,
    /// The user's calendars, cached by the calendar thread.
    pub calendar: calendar::Calendar,
    /// The app of the call the detector is following, if any, so a recording
    /// the user starts during it carries the calendar event too.
    pub detected_call: Mutex<Option<String>>,
    /// That call in full: whose sound to record, and its room when known.
    pub detected_meeting: Mutex<Option<lokalbot_platform::DetectedMeeting>>,
    pub coding_agents: coding_agents::Ingestor,
    pub exports: exports::Exports,
    pub routines: routines::Routines,
    pub dreams: dreaming::Dreams,
    /// Days whose evidence changed, for the digest scheduler.
    pub digest_invalidated: Mutex<std::collections::HashSet<chrono::NaiveDate>>,
    /// The processing queue has work, so meeting notes wait for it to finish.
    pub pipeline_busy: AtomicBool,
    pub retention: Mutex<RetentionStatus>,
    /// Paired phones and tablets, while sharing is on.
    pub companion: companion::Companion,
    /// Files' control thread, once the dispatcher has started it.
    pub files: Mutex<Option<files::FileSearch>>,
    /// The words at a file's matched moment, for the assistant.
    pub moments: Mutex<Option<Arc<files::moments::MomentTranscriber>>>,
    /// Vectors of saved screens' text and pictures.
    pub screen_vectors: Mutex<Option<screen_vectors::ScreenVectors>>,
}

impl Shared {
    fn new(
        library: Library,
        settings: Settings,
        runtime: lokalbot_ai::runtime::RuntimeManager,
        emit: Box<dyn Fn(EngineEvent) + Send + Sync>,
    ) -> Arc<Self> {
        Arc::new(Shared {
            library,
            settings: RwLock::new(settings),
            emit,
            capture_active: AtomicBool::new(false),
            recording_active: AtomicBool::new(false),
            recording_meeting: Mutex::new(None),
            autocomplete_visible: AtomicBool::new(false),
            autocomplete_generating: AtomicBool::new(false),
            dictation_working: AtomicBool::new(false),
            dictation_state: Default::default(),
            speech: Arc::new(speech::SpeechCache::default()),
            generation_metrics: Default::default(),
            runtime,
            background: Mutex::new(Vec::new()),
            shutting_down: AtomicBool::new(false),
            calendar: calendar::Calendar::default(),
            detected_call: Mutex::new(None),
            detected_meeting: Mutex::new(None),
            coding_agents: coding_agents::Ingestor::default(),
            exports: exports::Exports::default(),
            routines: routines::Routines::default(),
            dreams: dreaming::Dreams::default(),
            digest_invalidated: Default::default(),
            pipeline_busy: AtomicBool::new(false),
            retention: Mutex::new(RetentionStatus::default()),
            companion: companion::Companion::default(),
            files: Mutex::new(None),
            moments: Mutex::new(None),
            screen_vectors: Mutex::new(None),
        })
    }

    /// A shared state for tests, reporting events to `emit`.
    #[cfg(test)]
    pub(crate) fn for_tests(
        library: Library,
        settings: Settings,
        emit: impl Fn(EngineEvent) + Send + Sync + 'static,
    ) -> Arc<Self> {
        let runtime = lokalbot_ai::runtime::RuntimeManager::new(library.paths().clone(), &settings);
        Self::new(library, settings, runtime, Box::new(emit))
    }

    pub fn emit(&self, event: EngineEvent) {
        if matches!(event, EngineEvent::LibraryChanged) {
            self.companion.library_changed();
        }
        (self.emit)(event);
    }

    pub fn settings(&self) -> Settings {
        self.settings.read().clone()
    }

    pub fn message(&self, text: impl Into<String>) {
        self.emit(EngineEvent::Message {
            text: text.into(),
            is_error: false,
        });
    }

    pub fn error(&self, text: impl Into<String>) {
        self.emit(EngineEvent::Message {
            text: text.into(),
            is_error: true,
        });
    }

    /// Adds or replaces one row of the sidebar's "In progress" card.
    pub fn set_background(&self, item: BackgroundItem) {
        let snapshot = {
            let mut items = self.background.lock();
            match items.iter_mut().find(|existing| existing.id == item.id) {
                Some(existing) => *existing = item,
                None => items.push(item),
            }
            items.clone()
        };
        self.emit(EngineEvent::Background(snapshot));
    }

    pub fn clear_background(&self, id: &str) {
        let snapshot = {
            let mut items = self.background.lock();
            items.retain(|item| item.id != id);
            items.clone()
        };
        self.emit(EngineEvent::Background(snapshot));
    }

    /// The Think client for the current settings, with the stored API key.
    pub fn think(&self, settings: &Settings) -> Result<lokalbot_ai::think::ThinkClient> {
        let client = lokalbot_ai::think::ThinkClient::new(&self.runtime, settings)?;
        Ok(match settings.summarizer_backend {
            lokalbot_core::settings::SummarizerBackend::OpenAICompatible => {
                client.with_api_key(secrets::openai_api_key())
            }
            _ => client,
        })
    }

    /// A recording started or stopped: Files and picture vectors wait or go on.
    pub fn background_conditions_changed(&self) {
        if let Some(files) = self.files.lock().as_ref() {
            files.conditions_changed();
        }
        if let Some(vectors) = self.screen_vectors.lock().as_ref() {
            vectors.conditions_changed();
        }
    }

    pub fn is_shutting_down(&self) -> bool {
        self.shutting_down.load(Ordering::Relaxed)
    }

    /// One route for every source change, so exports, routines and reused digest
    /// answers can't diverge from what changed (`primaryEvidenceDidChange`).
    fn evidence_changed(&self, dates: &[chrono::DateTime<Utc>]) {
        let mut days: Vec<chrono::NaiveDate> = dates
            .iter()
            .map(|at| lokalbot_core::time::local_day(*at))
            .collect();
        days.sort_unstable();
        days.dedup();
        // Deleted or corrected evidence must not survive in reused answers.
        lokalbot_ai::digest::purge_cache(&days);
        self.digest_invalidated.lock().extend(days.iter().copied());
        self.exports.reconsider_daily(&days);
        self.exports.reconsider_notes();
        self.routines.reconsider_evidence();
        self.companion.evidence_changed(&days);
        // Learned items go with the source they came from.
        self.library.personal().retract_if_loaded();
        self.dreams.reconsider(&days);
    }
}

/// The running engine, for searches that embed their words.
static RUNNING: std::sync::RwLock<std::sync::Weak<Shared>> =
    std::sync::RwLock::new(std::sync::Weak::new());

/// A search's words as a vector, on the small text embedder: `None` while search
/// by meaning is off or its model isn't downloaded. Never downloads anything.
pub fn query_vector(text: &str) -> Option<Vec<f32>> {
    let shared = RUNNING.read().ok()?.upgrade()?;
    if !shared.settings().semantic_search_enabled
        || !lokalbot_ai::catalog::is_downloaded(
            shared.library.paths(),
            lokalbot_ai::catalog::embedding_entry(),
        )
    {
        return None;
    }
    lokalbot_ai::think::EmbeddingClient::new(&shared.runtime)
        .embed_query(text)
        .map_err(|err| log::debug!("no query vector: {err:#}"))
        .ok()
}

/// Handle to the running engine. Dropping it shuts the engine down.
pub struct Engine {
    commands: Sender<Command>,
    shared: Arc<Shared>,
    dispatcher: Option<JoinHandle<()>>,
}

impl Engine {
    /// Starts every background service. `on_event` is called from engine
    /// threads; it must be cheap (forward into a channel).
    pub fn start(
        library: Library,
        settings: Settings,
        on_event: impl Fn(EngineEvent) + Send + Sync + 'static,
    ) -> Result<Engine> {
        let runtime = lokalbot_ai::runtime::RuntimeManager::new(library.paths().clone(), &settings);
        secrets::install_plan_store();
        library.set_chat_key_source(Arc::new(secrets::chat_key));
        lokalbot_core::SpeakerAttribution::set_microphone_is_user(settings.microphone_is_user);
        lokalbot_ai::download_source::set_source(settings.model_download_source);
        lokalbot_ai::catalog::set_custom(&settings.custom_built_in_models);
        let shared = Shared::new(library, settings, runtime, Box::new(on_event));
        // Library writes anywhere in this process report here. The observer can
        // outlive this engine, so it holds a weak handle.
        let observed = Arc::downgrade(&shared);
        lokalbot_core::evidence::observe(move |root, dates| {
            if let Some(shared) = observed.upgrade()
                && shared.library.paths().root() == root
            {
                shared.evidence_changed(dates);
            }
        });
        if let Ok(mut running) = RUNNING.write() {
            *running = Arc::downgrade(&shared);
        }
        let (commands, receiver) = unbounded();
        let dispatcher = {
            let shared = shared.clone();
            let commands = commands.clone();
            std::thread::Builder::new()
                .name("lokalbot-engine".into())
                .spawn(move || dispatch(shared, commands, receiver))?
        };
        Ok(Engine {
            commands,
            shared,
            dispatcher: Some(dispatcher),
        })
    }

    pub fn send(&self, command: Command) {
        if self.commands.send(command).is_err() {
            log::warn!("engine is not running");
        }
    }

    /// Stops any recording and saves it, leaving its processing for the next
    /// launch. Blocks until that is done, and false means something could not
    /// be saved: stay open, as the macOS app does, so a later quit can retry.
    pub fn prepare_for_quit(&self) -> bool {
        let (reply, answer) = crossbeam_channel::bounded(1);
        if self.commands.send(Command::PrepareForQuit(reply)).is_err() {
            return true;
        }
        answer.recv().unwrap_or(true)
    }

    /// [`Self::prepare_for_quit`] that gives up after `wait`, when the app is
    /// going regardless. An engine that took longer answers false.
    pub fn prepare_for_quit_within(&self, wait: std::time::Duration) -> bool {
        let (reply, answer) = crossbeam_channel::bounded(1);
        if self.commands.send(Command::PrepareForQuit(reply)).is_err() {
            return true;
        }
        answer.recv_timeout(wait).unwrap_or(false)
    }

    /// A clone of the command channel, for platform callbacks (tray, shortcuts).
    pub fn sender(&self) -> Sender<Command> {
        self.commands.clone()
    }

    pub fn library(&self) -> &Library {
        &self.shared.library
    }

    /// The llama.cpp runtime the engine's model roles share. Agent Mode leases
    /// the Think server from it so both use one process on port 17872.
    pub fn runtime(&self) -> &lokalbot_ai::runtime::RuntimeManager {
        &self.shared.runtime
    }

    /// Speech models in this process, for the resource readout.
    pub fn loaded_speech_models(&self) -> Vec<(&'static str, String)> {
        self.shared.speech.loaded_models()
    }

    /// The last generations, newest first.
    pub fn recent_generations(&self) -> Vec<GenerationMetric> {
        self.shared.generation_metrics.recent()
    }
}

impl Drop for Engine {
    fn drop(&mut self) {
        let _ = self.commands.send(Command::Shutdown);
        if let Some(dispatcher) = self.dispatcher.take() {
            let _ = dispatcher.join();
        }
    }
}

/// Calendar settings that change what the calendar thread reads.
fn calendar_settings_changed(old: &Settings, new: &Settings) -> bool {
    old.calendar_detection_enabled != new.calendar_detection_enabled
        || old.calendar_evolution_enabled != new.calendar_evolution_enabled
        || old.calendar_my_email_addresses != new.calendar_my_email_addresses
}

fn dispatch(shared: Arc<Shared>, commands: Sender<Command>, receiver: Receiver<Command>) {
    let models = models::Models::new(shared.clone());
    let pipeline = pipeline::Pipeline::start(shared.clone(), models.clone());
    let recording = recording::Recording::new(shared.clone(), pipeline.clone());
    let ask = ask::AskWorker::new(shared.clone(), models.clone());
    let project_notes = project_notes::ProjectNotes::new(shared.clone(), models.clone());
    let digest = digest::DigestScheduler::start(shared.clone(), models.clone());
    let meeting_detector = Arc::new(Mutex::new(lokalbot_platform::MeetingDetector::new()));
    let screen = screen::ScreenContext::new(shared.clone());
    let day_memory = daymemory::DayMemory::start(
        shared.clone(),
        meeting_detector.clone(),
        screen.boundary_hook(),
    );
    screen.start(day_memory.paused_flag());
    let calendar = calendar::start(shared.clone());
    let preparation = upcoming::Preparation::start(shared.clone(), models.clone());
    let detector = detector::Detector::start(shared.clone(), commands.clone(), meeting_detector);
    let dictation = dictation::Dictation::new(shared.clone(), models.clone());
    let selection_actions =
        selection::Controller::new(selection::LiveHost::new(shared.clone(), models.clone()));
    let live = live::LiveTranscriber::new(shared.clone(), models.clone());
    let speaker = speak::Speaker::new(shared.clone(), models.clone());
    let model_checks = model_checks::ModelChecks::new(shared.clone(), models.clone());
    let mut autocomplete = autocomplete::Autocomplete::start(shared.clone(), models.clone());
    models.publish_status();
    indexing::start(shared.clone(), models.clone());
    *shared.moments.lock() = Some(Arc::new(files::moments::MomentTranscriber::new(
        shared.clone(),
        models.clone(),
    )));
    let file_search = files::FileSearch::start(shared.clone(), models.clone());
    *shared.files.lock() = Some(file_search.clone());
    let screen_vectors = screen_vectors::ScreenVectors::start(shared.clone(), models.clone());
    *shared.screen_vectors.lock() = Some(screen_vectors.clone());
    retention::start(shared.clone());
    coding_agents::start(shared.clone());
    exports::start(shared.clone());
    routines::start(shared.clone());
    dreaming::start(shared.clone(), models.clone());
    health_check::start(shared.clone());
    let voices = voice::VoiceWorker::start(shared.clone(), pipeline.clone());
    companion::start(shared.clone(), models.clone());

    while let Ok(command) = receiver.recv() {
        // Autocomplete's commands carry typed text, which is never logged.
        if !matches!(command, Command::Autocomplete(_)) {
            log::debug!("engine command: {command:?}");
        }
        match command {
            Command::StartRecording { title, app_name } => {
                // A recording the user starts during a detected call is for
                // that call and its calendar event (`recordingContext(for:)`).
                let app_name = app_name.or_else(|| shared.detected_call.lock().clone());
                let calendar = app_name
                    .as_ref()
                    .and_then(|_| shared.calendar.active_event(&shared.settings(), Utc::now()));
                recording.start(RecordingStart {
                    title,
                    app_name,
                    calendar,
                    source: StartSource::User,
                });
                if let Some(folder) = recording.active_folder() {
                    live.prepare(folder);
                }
            }
            Command::RecordCalendarEvent(event) => {
                recording.start(RecordingStart {
                    title: None,
                    app_name: shared.detected_call.lock().clone(),
                    calendar: Some(*event),
                    source: StartSource::User,
                });
                if let Some(folder) = recording.active_folder() {
                    live.prepare(folder);
                }
            }
            Command::StartDetectedRecording {
                title,
                app_name,
                calendar,
            } => {
                recording.start(RecordingStart {
                    title: Some(title),
                    app_name: Some(app_name),
                    calendar: calendar.map(|event| *event),
                    source: StartSource::Detector,
                });
                if let Some(folder) = recording.active_folder() {
                    live.prepare(folder);
                }
            }
            Command::CallEnded => {
                if recording.is_automatic() {
                    live.stop();
                }
                recording.call_ended();
            }
            Command::SplitForCalendarHandoff {
                title,
                app_name,
                calendar,
            } => {
                if recording.is_automatic() {
                    live.stop();
                    recording.split_for_calendar_handoff(RecordingStart {
                        title: Some(title),
                        app_name: Some(app_name),
                        calendar: Some(*calendar),
                        source: StartSource::CalendarHandoff,
                    });
                    if let Some(folder) = recording.active_folder() {
                        live.prepare(folder);
                    }
                }
            }
            Command::SetCalendarLinks(links) => match shared.calendar.set_links(links) {
                Ok(()) => {}
                Err(err) => shared.error(format!("The calendar links were not saved: {err:#}")),
            },
            Command::RefreshCalendar => shared.calendar.reload(),
            Command::PrepareMeeting { event, generate } => preparation.prepare(*event, generate),
            Command::StopRecording => {
                live.stop();
                recording.stop();
            }
            Command::PrepareForQuit(reply) => {
                live.stop();
                let _ = reply.send(recording.prepare_for_quit());
            }
            Command::ProcessMeeting {
                meeting_id,
                transcribe,
                summarize,
            } => {
                pipeline.enqueue(meeting_id, transcribe, summarize, true);
            }
            Command::RegenerateDigest(day) => digest.regenerate(day),
            Command::Ask {
                conversation_id,
                question,
                scope,
                retry_of,
            } => ask.ask(conversation_id, question, scope, retry_of),
            Command::StopAnswer => ask.stop(),
            Command::DownloadModel(id) => models.download(&id),
            Command::CancelDownload(id) => models.cancel(&id),
            Command::DeleteModel(id) => models.delete(&id),
            Command::PrepareModels => models.prepare_for_settings(),
            Command::SetDayMemoryPaused(paused) => day_memory.set_paused(paused),
            Command::WriteProjectNote(project_id) => project_notes.write(project_id),
            Command::ProjectOpened(project_id) => project_notes.opened(project_id),
            Command::WriteFollowUp(meeting_id) => ask.write_follow_up(meeting_id),
            Command::UpdateSettings(settings) => {
                let before = shared.settings();
                let calendar_changed = calendar_settings_changed(&before, &settings);
                let calendar_turned_on =
                    settings.calendar_detection_enabled && !before.calendar_detection_enabled;
                // Reading starts as soon as the person allows it, and a new
                // exclusion takes effect without waiting for the next refresh.
                let read_sessions = !settings.enabled_coding_agents().is_empty()
                    && (before.enabled_coding_agents() != settings.enabled_coding_agents()
                        || before.coding_agent_excluded_folders
                            != settings.coding_agent_excluded_folders);
                let reviews_changed = before.dreaming_enabled != settings.dreaming_enabled
                    || before.dreaming_hour != settings.dreaming_hour
                    || before.dreaming_first_eligible_day_key()
                        != settings.dreaming_first_eligible_day_key();
                let dictation_learning = settings.learns_from_dictation();
                let dictation_learning_changed =
                    before.learns_from_dictation() != dictation_learning;
                shared
                    .runtime
                    .set_backend_preference(&settings.llama_backend);
                lokalbot_core::SpeakerAttribution::set_microphone_is_user(
                    settings.microphone_is_user,
                );
                lokalbot_ai::download_source::set_source(settings.model_download_source);
                lokalbot_ai::catalog::set_custom(&settings.custom_built_in_models);
                *shared.settings.write() = *settings;
                file_search.settings_changed(&shared.settings());
                screen_vectors.conditions_changed();
                model_checks.settings_changed();
                if calendar_turned_on {
                    shared.calendar.reload();
                } else if calendar_changed {
                    shared.calendar.refresh();
                }
                models.publish_status();
                autocomplete.settings_changed();
                shared.companion.settings_changed(&shared.settings());
                shared.exports.settings_changed();
                shared.routines.reconsider_evidence();
                if reviews_changed {
                    shared.dreams.settings_changed();
                }
                // Off deletes every kept dictation at once; on drops expired ones.
                if dictation_learning_changed {
                    let log = shared.library.dictation_log();
                    let cleaned = if dictation_learning {
                        log.prune()
                    } else {
                        log.delete_all()
                    };
                    if let Err(err) = cleaned {
                        log::warn!("dictation learning log cleanup failed: {err:#}");
                    }
                }
                if read_sessions {
                    let shared = shared.clone();
                    std::thread::spawn(move || coding_agents::refresh(&shared, None));
                }
            }
            Command::Dictation(command) => dictation.handle(command),
            Command::Selection(command) => selection_actions.handle(command),
            Command::Autocomplete(command) => autocomplete.handle(command),
            Command::LivePreview(command) => match command {
                LivePreviewCommand::Start { from_beginning } => live.start(from_beginning),
                LivePreviewCommand::Pause => live.pause(),
            },
            Command::CaptureScreenNow => screen.capture_now(),
            Command::RunRoutine(kind) => shared.routines.run_now(kind),
            Command::ReviewNow => shared.dreams.review_now(),
            Command::ClearWorkMemory => {
                let shared = shared.clone();
                std::thread::spawn(move || dreaming::clear_work_memory(&shared));
            }
            Command::RunRetentionNow => retention::run_now(shared.clone()),
            Command::RestartMemoryCapture => {
                day_memory.restart();
                screen.restart();
            }
            Command::LearnSpeakerVoices => voices.learn_soon(),
            Command::Speech(command) => speaker.handle(command),
            Command::CheckModels(roles) => model_checks.run(roles),
            Command::CancelModelChecks => model_checks.cancel(),
            Command::CheckConnection(backend) => model_checks.check_connection(backend),
            Command::Companion(command) => shared.companion.command(command, &shared.settings()),
            Command::Shutdown => break,
        }
    }

    shared.shutting_down.store(true, Ordering::Relaxed);
    shared.companion.stop();
    file_search.shutdown();
    speaker.stop();
    live.stop();
    autocomplete.stop();
    recording.prepare_for_quit();
    detector.stop();
    calendar.stop();
    day_memory.stop();
    screen.stop();
    digest.stop();
    dreaming::stop(&shared);
    pipeline.stop();
    shared.runtime.shutdown();
}
