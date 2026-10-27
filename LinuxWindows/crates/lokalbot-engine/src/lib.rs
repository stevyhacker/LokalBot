//! LokalBot's background engine for Linux and Windows.
//!
//! The app sends [`Command`]s; the engine does the work on its own threads and
//! reports back through [`EngineEvent`]s. Nothing here touches the UI.

mod ask;
mod autocomplete;
mod calendar;
mod daymemory;
mod detector;
mod dictation;
mod digest;
pub mod events;
mod indexing;
pub mod library_ops;
mod live;
mod models;
mod pipeline;
mod recording;
mod retention;
pub mod sample;
mod screen;
pub mod secrets;
mod speech;
mod upcoming;

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
pub use events::*;
pub use recording::recover_unfinished_recordings;

/// State every subsystem shares.
pub(crate) struct Shared {
    pub library: Library,
    settings: RwLock<Settings>,
    emit: Box<dyn Fn(EngineEvent) + Send + Sync>,
    /// True while a meeting or dictation is capturing audio; heavy work waits.
    pub capture_active: AtomicBool,
    /// True while a meeting is being recorded.
    pub recording_active: AtomicBool,
    /// An autocomplete suggestion is on screen.
    pub autocomplete_visible: AtomicBool,
    pub speech: Arc<speech::SpeechCache>,
    pub runtime: lokalbot_ai::runtime::RuntimeManager,
    background: Mutex<Vec<BackgroundItem>>,
    pub shutting_down: AtomicBool,
    /// The user's calendars, cached by the calendar thread.
    pub calendar: calendar::Calendar,
    /// The app of the call the detector is following, if any, so a recording
    /// the user starts during it carries the calendar event too.
    pub detected_call: Mutex<Option<String>>,
}

impl Shared {
    pub fn emit(&self, event: EngineEvent) {
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

    pub fn is_shutting_down(&self) -> bool {
        self.shutting_down.load(Ordering::Relaxed)
    }
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
        let shared = Arc::new(Shared {
            library,
            settings: RwLock::new(settings),
            emit: Box::new(on_event),
            capture_active: AtomicBool::new(false),
            recording_active: AtomicBool::new(false),
            autocomplete_visible: AtomicBool::new(false),
            speech: Arc::new(speech::SpeechCache::default()),
            runtime,
            background: Mutex::new(Vec::new()),
            shutting_down: AtomicBool::new(false),
            calendar: calendar::Calendar::default(),
            detected_call: Mutex::new(None),
        });
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
    let live = live::LiveTranscriber::new(shared.clone(), models.clone());
    let mut autocomplete = autocomplete::Autocomplete::start(shared.clone(), models.clone());
    models.publish_status();
    indexing::start(shared.clone(), models.clone());
    retention::start(shared.clone());

    while let Ok(command) = receiver.recv() {
        log::debug!("engine command: {command:?}");
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
            Command::ProcessMeeting {
                meeting_id,
                transcribe,
                summarize,
            } => pipeline.enqueue(meeting_id, transcribe, summarize, true),
            Command::RegenerateDigest(day) => digest.regenerate(day),
            Command::Ask {
                conversation_id,
                question,
                scope,
            } => ask.ask(conversation_id, question, scope),
            Command::StopAnswer => ask.stop(),
            Command::DownloadModel(id) => models.download(&id),
            Command::CancelDownload(id) => models.cancel(&id),
            Command::DeleteModel(id) => models.delete(&id),
            Command::PrepareModels => models.prepare_for_settings(),
            Command::SetDayMemoryPaused(paused) => day_memory.set_paused(paused),
            Command::WriteProjectNote(project_id) => ask.write_project_note(project_id),
            Command::WriteFollowUp(meeting_id) => ask.write_follow_up(meeting_id),
            Command::UpdateSettings(settings) => {
                let before = shared.settings();
                let calendar_changed = calendar_settings_changed(&before, &settings);
                let calendar_turned_on =
                    settings.calendar_detection_enabled && !before.calendar_detection_enabled;
                shared
                    .runtime
                    .set_backend_preference(&settings.llama_backend);
                *shared.settings.write() = *settings;
                if calendar_turned_on {
                    shared.calendar.reload();
                } else if calendar_changed {
                    shared.calendar.refresh();
                }
                models.publish_status();
                autocomplete.settings_changed();
            }
            Command::Dictation(command) => dictation.handle(command),
            Command::Autocomplete(command) => autocomplete.handle(command),
            Command::LivePreview(command) => match command {
                LivePreviewCommand::Start { from_beginning } => live.start(from_beginning),
                LivePreviewCommand::Pause => live.pause(),
            },
            Command::CaptureScreenNow => screen.capture_now(),
            Command::Shutdown => break,
        }
    }

    shared.shutting_down.store(true, Ordering::Relaxed);
    live.stop();
    autocomplete.stop();
    recording.stop_for_shutdown();
    detector.stop();
    calendar.stop();
    day_memory.stop();
    screen.stop();
    digest.stop();
    pipeline.stop();
    shared.runtime.shutdown();
}
