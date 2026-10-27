//! App-wide state shared by every page: the library, settings, navigation,
//! recording and background-work status.
//!
//! Pages read it with `AppData::global(cx).read(cx)` and change it only through
//! the methods below, so the engine wiring stays in one place.

use std::collections::HashMap;
use std::time::Instant;

use chrono::{DateTime, Utc};
use gpui_kit::{App, AppContext as _, Context, Entity, Global, SharedString};
use lokalbot_core::{ActionStatus, Library, Meeting, Settings};
use uuid::Uuid;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Section {
    Today,
    Meetings,
    Timeline,
    People,
    Projects,
    Ask,
    Agent,
    Settings,
}

impl Section {
    pub fn title(self) -> &'static str {
        match self {
            Section::Today => lokalbot_i18n::tr("Today"),
            Section::Meetings => lokalbot_i18n::tr("Meetings"),
            Section::Timeline => lokalbot_i18n::tr("Timeline"),
            Section::People => lokalbot_i18n::tr("People"),
            Section::Projects => lokalbot_i18n::tr("Projects"),
            Section::Ask => lokalbot_i18n::tr("Ask"),
            Section::Agent => lokalbot_i18n::tr("Agent"),
            Section::Settings => lokalbot_i18n::tr("Settings"),
        }
    }
}

/// Tabs of the meeting workspace.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum MeetingTab {
    #[default]
    Summary,
    Transcript,
    Notes,
    Review,
}

/// Settings categories, in sidebar order.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub enum SettingsCategory {
    #[default]
    General,
    Meetings,
    DayMemory,
    Writing,
    Dictation,
    Models,
    Privacy,
    Advanced,
}

#[derive(Clone, Debug, PartialEq)]
#[allow(clippy::large_enum_variant)]
pub enum RecordingState {
    Idle,
    Recording {
        meeting: Meeting,
        started: Instant,
        /// False when system audio could not be captured.
        has_system_audio: bool,
        mic_level: f32,
        system_level: f32,
    },
}

impl RecordingState {
    pub fn is_active(&self) -> bool {
        !matches!(self, RecordingState::Idle)
    }

    pub fn meeting(&self) -> Option<&Meeting> {
        match self {
            RecordingState::Recording { meeting, .. } => Some(meeting),
            _ => None,
        }
    }
}

/// Where a meeting is in transcription and summarization.
#[derive(Clone, Debug, PartialEq)]
pub enum ProcessingStage {
    Queued,
    WaitingForModels,
    PreparingModel(SharedString),
    Transcribing,
    IdentifyingSpeakers,
    Summarizing,
    Failed(SharedString),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BackgroundKind {
    Meeting,
    Digest,
    Download,
    Reindex,
}

/// One row of the sidebar's "In progress" card.
#[derive(Clone, Debug, PartialEq)]
pub struct BackgroundItem {
    pub id: SharedString,
    pub kind: BackgroundKind,
    pub title: SharedString,
    pub detail: SharedString,
    /// 0.0–1.0 when known.
    pub progress: Option<f32>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Toast {
    pub message: SharedString,
    pub is_error: bool,
}

/// A question to put into Ask when navigating there.
#[derive(Clone, Debug, PartialEq)]
pub struct AskRequest {
    pub question: String,
    /// Limit sources to these meetings.
    pub meeting_ids: Vec<Uuid>,
    pub submit: bool,
}

/// A request to show a day on Timeline, optionally with a work session or
/// a screen moment open.
#[derive(Clone, Debug, PartialEq)]
pub struct TimelineFocus {
    pub day: chrono::NaiveDate,
    /// `WorkSession::id`.
    pub session_id: Option<String>,
    /// `ScreenMoment::id`.
    pub moment_id: Option<i64>,
}

/// A request to show a meeting, optionally at a moment of its transcript.
#[derive(Clone, Debug, PartialEq)]
pub struct MeetingFocus {
    pub meeting_id: Uuid,
    pub tab: MeetingTab,
    pub at: Option<f64>,
}

pub struct AppData {
    pub library: Library,
    pub settings: Settings,
    /// Visible meetings, newest first.
    pub meetings: Vec<Meeting>,
    pub meetings_loaded: bool,
    /// Bumped whenever library content changes, so pages can reload lazily.
    pub revision: u64,
    pub section: Section,
    pub settings_category: SettingsCategory,
    pub meeting_focus: Option<MeetingFocus>,
    pub ask_request: Option<AskRequest>,
    pub timeline_focus: Option<TimelineFocus>,
    /// Today should open its Actions workspace ("Review Actions…").
    pub actions_requested: bool,
    /// A person (`PersonProfile::id`) for People to select.
    pub person_focus: Option<String>,
    /// A project (`ProjectProfile::id`) for Projects to select.
    pub project_focus: Option<String>,
    pub recording: RecordingState,
    pub processing: HashMap<Uuid, ProcessingStage>,
    /// File names waiting to be imported, the one in progress first.
    pub importing: Vec<SharedString>,
    pub background: Vec<BackgroundItem>,
    pub toast: Option<Toast>,
    pub day_memory_paused: bool,
    pub inference_label: SharedString,
    pub remote_hosts: Vec<SharedString>,
    /// The answer being written right now, if any. The engine appends text
    /// as it streams and saves the finished turn into the conversation file.
    pub ask_stream: Option<AskStream>,
    /// Model downloads by catalog id.
    pub downloads: HashMap<String, DownloadProgress>,
    /// Which models are present and which runtime the Think role uses.
    pub models: ModelStatus,
    /// Day whose digest is being written.
    pub digest_running: Option<chrono::NaiveDate>,
    /// Project ids whose "Where it stands" note is being written.
    pub project_notes_running: Vec<String>,
    /// Text of the last dictation shown in LokalBot (output mode "Show in LokalBot").
    pub last_dictation: Option<SharedString>,
    /// The latest dictations, newest first, for copying one again.
    pub recent_dictations: Vec<lokalbot_core::dictation_history::Entry>,
    /// Microphone names for the device pickers in Settings, filled by the engine.
    pub audio_inputs: Vec<SharedString>,
    /// Settings is recording a new shortcut: global shortcuts should pause
    /// so the keystroke reaches the recorder.
    pub shortcut_recording: bool,
    /// The floating dictation status.
    pub dictation: DictationHud,
    /// "Mic · Receiving audio" / "System · Not attached" while recording.
    pub recording_statuses: Option<(SharedString, SharedString)>,
    /// The latest "Write with Think" for a meeting's follow-up.
    pub follow_up: Option<(Uuid, FollowUpWriting)>,
    /// The opt-in live transcript preview of the meeting being recorded.
    pub live_preview: lokalbot_engine::LivePreview,
    /// Screen context capture, as the engine reports it.
    pub screen: lokalbot_engine::ScreenStatus,
    /// The user's calendars, as the engine last read them.
    pub calendar: lokalbot_engine::CalendarSnapshot,
    /// Today's preparation for the next meeting (in memory only).
    pub meeting_preparation: Option<lokalbot_engine::MeetingPreparation>,
    /// "Try a sample meeting" waiting for its models (`sample.rs`).
    pub sample_setup: Option<crate::sample::SampleSetup>,
}

/// A follow-up being rewritten with Think (`FollowUpDraftSheet`).
#[derive(Clone, Debug, PartialEq)]
pub enum FollowUpWriting {
    Writing,
    Written {
        subject: SharedString,
        body: SharedString,
        /// "Qwen3.5 4B", for "Written on this PC by …".
        model: SharedString,
    },
    Failed(SharedString),
}

/// What the dictation overlay shows.
#[derive(Clone, Debug, Default, PartialEq)]
pub enum DictationHud {
    #[default]
    Idle,
    Starting,
    Listening {
        level: f32,
        elapsed: f64,
    },
    Transcribing,
    Composing,
    /// "Copied to the clipboard" and similar, shown briefly.
    Notice(SharedString),
    Failed(SharedString),
}

/// Progress of an answer in Ask.
#[derive(Clone, Debug, PartialEq)]
pub struct AskStream {
    pub conversation_id: Uuid,
    pub question: String,
    /// Assistant text so far, with `[meeting:…]` citations inline.
    pub text: String,
    /// Steps shown as "worked: searched meetings · read “Design review”".
    pub activity: Vec<String>,
    /// "Preparing Qwen3.5 4B" while the model loads.
    pub status: Option<SharedString>,
    pub error: Option<SharedString>,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct DownloadProgress {
    pub done_bytes: u64,
    pub total_bytes: u64,
    pub error: Option<SharedString>,
}

impl DownloadProgress {
    pub fn fraction(&self) -> f32 {
        if self.total_bytes == 0 {
            0.0
        } else {
            self.done_bytes as f32 / self.total_bytes as f32
        }
    }
}

/// Readiness of each model role, refreshed by the engine.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ModelStatus {
    /// Catalog ids that are fully downloaded.
    pub installed: Vec<String>,
    pub transcription_ready: bool,
    pub think_ready: bool,
    pub autocomplete_ready: bool,
    pub embeddings_ready: bool,
    /// The screen text recognition (OCR) models are downloaded.
    pub screen_text_ready: bool,
    /// "CUDA", "Vulkan" or "CPU" for the selected built-in runtime, once installed.
    pub runtime_backend: Option<SharedString>,
    /// CUDA is downloaded, but its setup GPU check has not passed.
    pub runtime_needs_check: bool,
    pub runtime_storage: Vec<lokalbot_ai::runtime::RuntimeStorage>,
}

/// Sources and date range for a question in Ask.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct AskScope {
    /// Empty means every meeting.
    pub meeting_ids: Vec<Uuid>,
    pub include_meetings: bool,
    pub include_activity: bool,
    pub include_screen: bool,
    pub since: Option<DateTime<Utc>>,
    pub until: Option<DateTime<Utc>>,
}

pub struct AppHandle(pub Entity<AppData>);

impl Global for AppHandle {}

impl AppData {
    pub fn global(cx: &App) -> Entity<AppData> {
        cx.global::<AppHandle>().0.clone()
    }

    pub fn new(library: Library, settings: Settings) -> Self {
        let (inference_label, remote_hosts) = inference_presentation(&settings);
        Self {
            library,
            settings,
            meetings: Vec::new(),
            meetings_loaded: false,
            revision: 0,
            section: Section::Today,
            settings_category: SettingsCategory::General,
            meeting_focus: None,
            ask_request: None,
            timeline_focus: None,
            actions_requested: false,
            person_focus: None,
            project_focus: None,
            recording: RecordingState::Idle,
            processing: HashMap::new(),
            background: Vec::new(),
            toast: None,
            day_memory_paused: false,
            inference_label,
            remote_hosts,
            ask_stream: None,
            downloads: HashMap::new(),
            models: ModelStatus::default(),
            digest_running: None,
            project_notes_running: Vec::new(),
            last_dictation: None,
            recent_dictations: Vec::new(),
            dictation: DictationHud::Idle,
            recording_statuses: None,
            follow_up: None,
            live_preview: Default::default(),
            audio_inputs: Vec::new(),
            shortcut_recording: false,
            screen: Default::default(),
            importing: Vec::new(),
            calendar: Default::default(),
            meeting_preparation: None,
            sample_setup: None,
        }
    }

    /// Asks the engine for work. Pages call this instead of emitting directly
    /// so every request goes through one place.
    pub fn request(&mut self, event: AppEvent, cx: &mut Context<Self>) {
        cx.emit(event);
    }

    // ------------------------------------------------------------ navigation

    pub fn navigate(&mut self, section: Section, cx: &mut Context<Self>) {
        self.section = section;
        cx.notify();
    }

    pub fn open_meeting(
        &mut self,
        meeting_id: Uuid,
        tab: MeetingTab,
        at: Option<f64>,
        cx: &mut Context<Self>,
    ) {
        self.meeting_focus = Some(MeetingFocus {
            meeting_id,
            tab,
            at,
        });
        self.section = Section::Meetings;
        cx.notify();
    }

    pub fn open_timeline(
        &mut self,
        day: chrono::NaiveDate,
        session_id: Option<String>,
        cx: &mut Context<Self>,
    ) {
        self.timeline_focus = Some(TimelineFocus {
            day,
            session_id,
            moment_id: None,
        });
        self.section = Section::Timeline;
        cx.notify();
    }

    /// Timeline with one screen moment open (`ScreenMomentDetailView`).
    pub fn open_screen_moment(&mut self, id: i64, ts: DateTime<Utc>, cx: &mut Context<Self>) {
        self.timeline_focus = Some(TimelineFocus {
            day: lokalbot_core::time::local_day(ts),
            session_id: None,
            moment_id: Some(id),
        });
        self.section = Section::Timeline;
        cx.notify();
    }

    /// Today's Actions workspace (`openActions`).
    pub fn open_actions(&mut self, cx: &mut Context<Self>) {
        self.actions_requested = true;
        self.section = Section::Today;
        cx.notify();
    }

    pub fn open_person(&mut self, id: String, cx: &mut Context<Self>) {
        self.person_focus = Some(id);
        self.section = Section::People;
        cx.notify();
    }

    pub fn open_project(&mut self, id: String, cx: &mut Context<Self>) {
        self.project_focus = Some(id);
        self.section = Section::Projects;
        cx.notify();
    }

    pub fn open_settings(&mut self, category: SettingsCategory, cx: &mut Context<Self>) {
        self.settings_category = category;
        self.section = Section::Settings;
        cx.notify();
    }

    pub fn ask(&mut self, request: AskRequest, cx: &mut Context<Self>) {
        self.ask_request = Some(request);
        self.section = Section::Ask;
        cx.notify();
    }

    // --------------------------------------------------------------- library

    /// Reloads the meeting list on a background thread.
    pub fn reload(&mut self, cx: &mut Context<Self>) {
        let library = self.library.clone();
        cx.spawn(async move |this, cx| {
            let loaded = cx
                .background_spawn(async move { library.list_meetings() })
                .await;
            let _ = this.update(cx, |this, cx| {
                match loaded {
                    Ok(meetings) => this.meetings = meetings,
                    Err(err) => this.show_error(
                        lokalbot_i18n::format(
                            "Could not read the library: {err}",
                            &[("err", format!("{:#}", err))],
                        ),
                        cx,
                    ),
                }
                this.meetings_loaded = true;
                this.revision += 1;
                cx.notify();
            });
        })
        .detach();
    }

    pub fn meeting(&self, id: Uuid) -> Option<&Meeting> {
        self.meetings.iter().find(|m| m.id == id)
    }

    /// A page wrote meeting files itself (corrections, speaker names): pages
    /// that show them reload on the next `revision`.
    pub fn mark_library_changed(&mut self, cx: &mut Context<Self>) {
        self.revision += 1;
        cx.notify();
    }

    pub fn set_action_status(
        &mut self,
        meeting_id: Uuid,
        action_id: String,
        status: ActionStatus,
        cx: &mut Context<Self>,
    ) {
        let Some(meeting) = self.meeting(meeting_id).cloned() else {
            return;
        };
        let library = self.library.clone();
        cx.spawn(async move |this, cx| {
            let result = cx
                .background_spawn(
                    async move { library.set_action_status(&meeting, &action_id, status) },
                )
                .await;
            let _ = this.update(cx, |this, cx| {
                if let Err(err) = result {
                    this.show_error(
                        lokalbot_i18n::format(
                            "Could not update the action: {err}",
                            &[("err", format!("{:#}", err))],
                        ),
                        cx,
                    );
                }
                this.revision += 1;
                cx.notify();
            });
        })
        .detach();
    }

    /// Processing that blocks merging, undoing a merge or new boundaries:
    /// anything but a failed run.
    pub fn is_processing(&self, meeting_id: Uuid) -> bool {
        self.processing
            .get(&meeting_id)
            .is_some_and(|stage| !matches!(stage, ProcessingStage::Failed(_)))
    }

    /// Imports files as meetings one at a time, then queues each for
    /// transcription and, when on, notes (`AppState.importRecordings`).
    /// Failures are reported together once the batch ends.
    pub fn import_recordings(&mut self, paths: Vec<std::path::PathBuf>, cx: &mut Context<Self>) {
        let files: Vec<_> = paths.into_iter().filter(|p| p.is_file()).collect();
        if files.is_empty() {
            return;
        }
        self.section = Section::Meetings;
        let name = |path: &std::path::Path| -> SharedString {
            path.file_name()
                .map(|n| n.to_string_lossy().into_owned())
                .unwrap_or_default()
                .into()
        };
        self.importing.extend(files.iter().map(|p| name(p)));
        cx.notify();
        let library = self.library.clone();
        cx.spawn(async move |this, cx| {
            let mut failures = Vec::new();
            for path in files {
                let label = name(&path);
                let library = library.clone();
                let source = path.clone();
                let result = cx
                    .background_spawn(async move {
                        lokalbot_engine::library_ops::import_recording(
                            &library,
                            &source,
                            chrono::Utc::now(),
                        )
                    })
                    .await;
                let extension = path
                    .extension()
                    .map(|e| e.to_string_lossy().to_lowercase())
                    .unwrap_or_default();
                let _ = this.update(cx, |this, cx| {
                    if let Some(at) = this.importing.iter().position(|n| *n == label) {
                        this.importing.remove(at);
                    }
                    match result {
                        Ok(meeting) => {
                            log::info!(
                                "recording imported meeting={} extension={extension}",
                                meeting.id
                            );
                            let summarize = this.settings.auto_summarize;
                            this.request(
                                AppEvent::ProcessMeeting {
                                    meeting_id: meeting.id,
                                    transcribe: true,
                                    summarize,
                                },
                                cx,
                            );
                            this.reload(cx);
                            this.open_meeting(meeting.id, MeetingTab::Summary, None, cx);
                        }
                        Err(failure) => {
                            // The message names the file; keep file names out of the log.
                            log::warn!("recording import failed extension={extension}");
                            failures.push(failure.localized(&label));
                        }
                    }
                    cx.notify();
                });
            }
            if !failures.is_empty() {
                let _ = this.update(cx, |this, cx| this.show_error(failures.join("\n"), cx));
            }
        })
        .detach();
    }

    /// Removes a merged meeting and restores its sources (`AppState.undoMerge`).
    pub fn undo_merge(&mut self, meeting_id: Uuid, cx: &mut Context<Self>) {
        let Some(merged) = self.meeting(meeting_id).cloned() else {
            return;
        };
        if self.is_processing(meeting_id) {
            self.show_error(
                lokalbot_i18n::tr(
                    "Wait for the merged summary to finish before undoing the merge.",
                ),
                cx,
            );
            return;
        }
        let library = self.library.clone();
        cx.spawn(async move |this, cx| {
            let result = cx
                .background_spawn(async move {
                    lokalbot_engine::library_ops::undo_merge(&library, &merged)
                })
                .await;
            let _ = this.update(cx, |this, cx| {
                match result {
                    Ok(restored) => {
                        if let Some(first) = restored.first() {
                            this.open_meeting(first.id, MeetingTab::Summary, None, cx);
                        }
                    }
                    Err(err) => this.show_error(err.localized(), cx),
                }
                this.reload(cx);
            });
        })
        .detach();
    }

    pub fn delete_meeting(&mut self, meeting_id: Uuid, cx: &mut Context<Self>) {
        let Some(meeting) = self.meeting(meeting_id).cloned() else {
            return;
        };
        let library = self.library.clone();
        cx.spawn(async move |this, cx| {
            let result = cx
                .background_spawn(async move { library.delete_meeting(&meeting) })
                .await;
            let _ = this.update(cx, |this, cx| {
                if let Err(err) = result {
                    this.show_error(
                        lokalbot_i18n::format(
                            "Could not delete the meeting: {err}",
                            &[("err", format!("{:#}", err))],
                        ),
                        cx,
                    );
                }
                if this
                    .meeting_focus
                    .as_ref()
                    .is_some_and(|f| f.meeting_id == meeting_id)
                {
                    this.meeting_focus = None;
                }
                this.reload(cx);
            });
        })
        .detach();
    }

    /// Saves a screen moment (or changes its note); saved moments are kept
    /// past the retention window.
    pub fn save_screen_moment(&mut self, id: i64, note: String, cx: &mut Context<Self>) {
        let library = self.library.clone();
        self.run_library_change(
            lokalbot_i18n::tr("Could not update the saved moment"),
            move || library.save_moment(id, &note),
            cx,
        );
    }

    pub fn unsave_screen_moment(&mut self, id: i64, cx: &mut Context<Self>) {
        let library = self.library.clone();
        self.run_library_change(
            lokalbot_i18n::tr("Could not update the saved moment"),
            move || library.unsave_moment(id),
            cx,
        );
    }

    /// Deletes a moment's image, text and metadata.
    pub fn delete_screen_moment(&mut self, id: i64, cx: &mut Context<Self>) {
        let library = self.library.clone();
        self.run_library_change(
            lokalbot_i18n::tr("Could not delete the captured screen"),
            move || library.delete_screen_moments(&[id]).map(|_| ()),
            cx,
        );
    }

    fn run_library_change(
        &mut self,
        failure: &'static str,
        change: impl FnOnce() -> anyhow::Result<()> + Send + 'static,
        cx: &mut Context<Self>,
    ) {
        cx.spawn(async move |this, cx| {
            let result = cx.background_spawn(async move { change() }).await;
            let _ = this.update(cx, |this, cx| {
                if let Err(err) = result {
                    this.show_error(
                        lokalbot_i18n::format(
                            "{failure}: {err}",
                            &[
                                ("failure", failure.to_string()),
                                ("err", format!("{:#}", err)),
                            ],
                        ),
                        cx,
                    );
                }
                this.revision += 1;
                cx.notify();
            });
        })
        .detach();
    }

    // -------------------------------------------------------------- settings

    /// Applies a settings change and saves it in the background.
    pub fn update_settings(&mut self, change: impl FnOnce(&mut Settings), cx: &mut Context<Self>) {
        let before = self.settings.clone();
        change(&mut self.settings);
        if self.settings == before {
            return;
        }
        if before.app_language != self.settings.app_language {
            crate::i18n::apply(&self.settings.app_language, cx);
        }
        let (label, hosts) = inference_presentation(&self.settings);
        self.inference_label = label;
        self.remote_hosts = hosts;
        let path = self.library.paths().settings_file();
        let settings = self.settings.clone();
        cx.background_spawn(async move {
            if let Err(err) = settings.save(&path) {
                log::error!("saving settings failed: {err}");
            }
        })
        .detach();
        if before.app_theme != self.settings.app_theme
            || before.text_size != self.settings.text_size
        {
            cx.emit(AppEvent::AppearanceChanged);
        }
        cx.emit(AppEvent::SettingsChanged);
        cx.notify();
    }

    // ------------------------------------------------------------- recording

    pub fn toggle_recording(&mut self, cx: &mut Context<Self>) {
        if self.recording.is_active() {
            self.stop_recording(cx);
        } else {
            self.start_recording(cx);
        }
    }

    pub fn start_recording(&mut self, cx: &mut Context<Self>) {
        cx.emit(AppEvent::StartRecording);
    }

    pub fn stop_recording(&mut self, cx: &mut Context<Self>) {
        cx.emit(AppEvent::StopRecording);
    }

    // ---------------------------------------------------------------- toasts

    pub fn show_message(&mut self, message: impl Into<SharedString>, cx: &mut Context<Self>) {
        self.toast = Some(Toast {
            message: message.into(),
            is_error: false,
        });
        cx.notify();
    }

    pub fn show_error(&mut self, message: impl Into<SharedString>, cx: &mut Context<Self>) {
        self.toast = Some(Toast {
            message: message.into(),
            is_error: true,
        });
        cx.notify();
    }

    pub fn dismiss_toast(&mut self, cx: &mut Context<Self>) {
        self.toast = None;
        cx.notify();
    }
}

/// Requests that the engine bridge (in `main.rs`) handles. Results come back
/// as changes to `AppData` fields (`processing`, `ask_stream`, `downloads`,
/// `digest_running`, …) followed by `revision` bumps when files changed.
#[derive(Clone, Debug, PartialEq)]
pub enum AppEvent {
    StartRecording,
    StopRecording,
    SettingsChanged,
    AppearanceChanged,
    /// Transcribe and/or summarize a meeting again (Retry, "Transcribe & Summarize", "Summarize again").
    ProcessMeeting {
        meeting_id: Uuid,
        transcribe: bool,
        summarize: bool,
    },
    /// Write or rewrite the day digest.
    RegenerateDigest(chrono::NaiveDate),
    /// Ask a question in a conversation (a new id starts a new conversation).
    AskQuestion {
        conversation_id: Uuid,
        question: String,
        scope: AskScope,
    },
    StopAnswer,
    /// Download a model by catalog id (Think, Autocomplete, embeddings or speech).
    DownloadModel(String),
    CancelDownload(String),
    DeleteModel(String),
    /// Download every model the current settings need.
    PrepareModels,
    SetDayMemoryPaused(bool),
    /// Write the "Where it stands" note for a project id.
    WriteProjectNote(String),
    /// Rewrite a meeting's follow-up outline with the local Think model.
    WriteFollowUp(Uuid),
    /// Start, pause, resume or retry the live transcript preview.
    LivePreview(lokalbot_engine::LivePreviewCommand),
    OpenOnboarding,
    /// Start or stop dictation from the UI ("Try here").
    ToggleDictation,
    CancelDictation,
    /// A meeting app started a call while recording asks first.
    MeetingDetected {
        app_name: String,
        title: String,
    },
    /// Store the API key for the OpenAI-compatible server in the system
    /// credential store (never in settings.json).
    SaveApiKey(String),
    /// "Capture Screen Now" (tray and Timeline).
    CaptureScreenNow,
    /// Today's Record on a calendar event.
    RecordCalendarEvent(Box<lokalbot_core::calendar::CalendarEvent>),
    /// Replace the private calendar links kept in the credential store.
    SetCalendarLinks(Vec<String>),
    RefreshCalendar,
    /// Gather (and with `generate`, write a brief for) an upcoming meeting.
    PrepareMeeting {
        event: Box<lokalbot_core::calendar::CalendarEvent>,
        generate: bool,
    },
}

impl gpui_kit::EventEmitter<AppEvent> for AppData {}

/// The sidebar storage card's AI line and remote hosts.
pub fn inference_presentation(settings: &Settings) -> (SharedString, Vec<SharedString>) {
    use lokalbot_core::settings::SummarizerBackend;
    if let Some(plan) = settings.think_plan() {
        return (
            lokalbot_i18n::tr("AI: local + remote").into(),
            vec![plan.destination_host().into()],
        );
    }
    let url = match settings.summarizer_backend {
        SummarizerBackend::Ollama => Some(settings.ollama_base_url.as_str()),
        SummarizerBackend::OpenAICompatible => Some(settings.openai_base_url.as_str()),
        SummarizerBackend::BuiltIn
        | SummarizerBackend::ChatGptPlan
        | SummarizerBackend::ClaudePlan => None,
    };
    match url {
        Some(url) if !lokalbot_core::access::is_loopback_url(url) => {
            let host = lokalbot_core::access::origin_of(url)
                .map(|o| o.split_once("://").map(|(_, h)| h.to_string()).unwrap_or(o))
                .unwrap_or_else(|| url.to_string());
            (
                lokalbot_i18n::tr("AI: local + remote").into(),
                vec![host.into()],
            )
        }
        _ => (lokalbot_i18n::tr("AI: on this PC").into(), Vec::new()),
    }
}

/// Friendly day label for list groups: "Today", "Yesterday", "Wednesday, October 7".
pub fn day_label(at: DateTime<Utc>) -> String {
    let day = lokalbot_core::time::local_day(at);
    let today = chrono::Local::now().date_naive();
    if day == today {
        lokalbot_i18n::tr("Today").into()
    } else if Some(day) == today.pred_opt() {
        lokalbot_i18n::tr("Yesterday").into()
    } else {
        day.format_localized(
            lokalbot_i18n::date_pattern("%A, %B %-d"),
            lokalbot_i18n::date_locale(),
        )
        .to_string()
    }
}
