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

/// A destination in the main window's sidebar (`AppState.NavSection`).
/// Settings is not one: it has its own window ([`AppData::open_settings`]).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Section {
    Today,
    Actions,
    Meetings,
    Timeline,
    People,
    Projects,
    Ask,
    Agent,
}

impl Section {
    pub fn title(self) -> &'static str {
        match self {
            Section::Today => lokalbot_i18n::tr("Today"),
            Section::Actions => lokalbot_i18n::tr("Actions"),
            Section::Meetings => lokalbot_i18n::tr("Meetings"),
            Section::Timeline => lokalbot_i18n::tr("Timeline"),
            Section::People => lokalbot_i18n::tr("People"),
            Section::Projects => lokalbot_i18n::tr("Projects"),
            Section::Ask => lokalbot_i18n::tr("Ask"),
            Section::Agent => lokalbot_i18n::tr("Agent"),
        }
    }

    /// The icon beside the section in the sidebar. Panels that lead to a
    /// section show the same one (`NavSection.symbol`, as Lucide icons:
    /// sun.max, checkmark.circle, waveform.circle, calendar.day.timeline.left,
    /// person.2, folder, sparkle.magnifyingglass, wand.and.sparkles).
    pub fn icon(self) -> crate::ui::Ico {
        use crate::ui::Ico;
        match self {
            Section::Today => Ico::Sun,
            Section::Actions => Ico::CircleCheck,
            Section::Meetings => Ico::AudioLines,
            Section::Timeline => Ico::SquareChartGantt,
            Section::People => Ico::Users,
            Section::Projects => Ico::Folder,
            Section::Ask => Ico::Search,
            Section::Agent => Ico::WandSparkles,
        }
    }

    /// Section names accepted by `--page` and deep links. "capture" (the old
    /// merged section) lands on Timeline and "search"/"chat" on Ask, as on
    /// the Mac (`NavSection.init(captureName:)`). Settings pages have their
    /// own window: see `SettingsCategory::named`.
    pub fn named(name: &str) -> Option<Section> {
        Some(match name.to_ascii_lowercase().as_str() {
            "today" => Section::Today,
            "actions" => Section::Actions,
            "meetings" => Section::Meetings,
            "timeline" | "capture" => Section::Timeline,
            "people" => Section::People,
            "projects" => Section::Projects,
            "ask" | "search" | "chat" => Section::Ask,
            "agent" => Section::Agent,
            _ => return None,
        })
    }
}

/// Tabs of the meeting workspace.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum MeetingTab {
    #[default]
    Summary,
    Transcript,
    Notes,
}

/// Settings categories, in sidebar order.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub enum SettingsCategory {
    /// Where Settings opens: every feature and whether it is on.
    #[default]
    Overview,
    General,
    Meetings,
    DayMemory,
    PersonalContext,
    Writing,
    Dictation,
    Files,
    Models,
    Devices,
    Privacy,
    Advanced,
}

impl SettingsCategory {
    /// The Settings page a `--page` name opens: "settings" is Overview, and
    /// "settings-<page>" names one page.
    pub fn named(name: &str) -> Option<SettingsCategory> {
        Some(match name.to_ascii_lowercase().as_str() {
            "settings" | "settings-overview" => SettingsCategory::Overview,
            "settings-general" => SettingsCategory::General,
            "settings-meetings" => SettingsCategory::Meetings,
            "settings-day-memory" => SettingsCategory::DayMemory,
            "settings-personal-context" => SettingsCategory::PersonalContext,
            "settings-writing" => SettingsCategory::Writing,
            "settings-dictation" => SettingsCategory::Dictation,
            "settings-files" => SettingsCategory::Files,
            "settings-models" => SettingsCategory::Models,
            "settings-devices" => SettingsCategory::Devices,
            "settings-privacy" => SettingsCategory::Privacy,
            "settings-advanced" => SettingsCategory::Advanced,
            _ => return None,
        })
    }
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
    /// Limit sources to this day (Ask About Today, Ask About This Day).
    pub day: Option<chrono::NaiveDate>,
}

/// Where a meeting opened from evidence goes Back to (`evidenceReturnSection`).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct EvidenceReturn {
    pub section: Section,
}

/// What the palette asks of the Agent page.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum AgentRequest {
    NewTask,
    SearchTasks,
    FindInTask,
    ToggleResults,
    SelectTask(Uuid),
    /// A prompt from another page, for the selected task's draft. Never sent.
    Prompt(String),
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
    /// How many [`Self::reload`]s have started, and the latest whose list was
    /// taken: one that started earlier and finished later is out of date.
    reloads_started: u64,
    reload_applied: u64,
    /// Bumped whenever library content changes, so pages can reload lazily.
    pub revision: u64,
    pub section: Section,
    /// The page the Settings window shows, or opens on.
    pub settings_category: SettingsCategory,
    /// The Settings window is open (`windows::settings`).
    pub settings_window_open: bool,
    /// A setting for Settings to scroll to and highlight (`focusedSettingID`).
    pub settings_focus: Option<String>,
    pub meeting_focus: Option<MeetingFocus>,
    /// Where evidence was opened from, for the Back button (`evidenceReturnSection`).
    pub evidence_return: Option<EvidenceReturn>,
    /// Warnings of the recording in progress.
    pub capture_warnings: Vec<SharedString>,
    pub ask_request: Option<AskRequest>,
    /// For the Agent page to act on when it next draws.
    pub agent_request: Option<AgentRequest>,
    /// Ctrl+F on the meeting page, waiting for the page to open Find.
    pub meeting_find_requested: bool,
    /// A meeting whose follow-up draft should open.
    pub follow_up_request: Option<Uuid>,
    /// A screen moment to attach to the next question ("Ask About This…").
    pub ask_screen: Option<lokalbot_core::ScreenMoment>,
    /// A work session's moments, as the next question's boundary.
    pub ask_screens: Option<Vec<i64>>,
    /// A conversation for Ask to open (Quick Recall's Open full Ask).
    pub ask_open_conversation: Option<Uuid>,
    /// The latest question of each conversation that attached screens. Their
    /// ids stay in memory for a retry; only their days reach the conversation.
    pub attached_asks: std::collections::HashMap<Uuid, AskScope>,
    /// What Files is doing now.
    pub files: lokalbot_engine::files::FileSearchStatus,
    /// How many coding-agent notes are saved, or why none could be.
    pub agent_notes: lokalbot_engine::agent_notes::AgentNotesStatus,
    pub timeline_focus: Option<TimelineFocus>,
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
    /// What Settings says about Think and its hosts ([`inference_presentation`]).
    pub inference_label: SharedString,
    pub remote_hosts: Vec<SharedString>,
    /// The sidebar's line about where the library and the AI are.
    pub privacy: PrivacyLine,
    /// How many open action threads are the user's: the Actions row's count
    /// (`OutcomeIndex.openUserActionThreads`). `None` until first counted.
    pub open_action_count: Option<usize>,
    /// The library revision `open_action_count` was counted at.
    open_actions_counted: Option<u64>,
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
    /// How the last dictation came about, for Last result.
    pub last_dictation_details: Option<LastDictationDetails>,
    /// The latest dictations, newest first, for copying one again.
    pub recent_dictations: Vec<lokalbot_core::dictation_history::Entry>,
    /// Settings and Today read this for the overnight review.
    pub dream: lokalbot_engine::dreaming::DreamStatus,
    /// Microphone names for the device pickers in Settings, filled by the engine.
    pub audio_inputs: Vec<SharedString>,
    /// Settings is recording a new shortcut: global shortcuts should pause
    /// so the keystroke reaches the recorder.
    pub shortcut_recording: bool,
    /// Dictation's shortcut is on but didn't register.
    pub dictation_shortcut_inactive: bool,
    /// The floating dictation status.
    pub dictation: DictationHud,
    /// The rolling transcript the overlay shows while dictating.
    pub dictation_transcript: lokalbot_ai::dictation_preview::LiveTranscript,
    /// Tells a timed dismissal whether its notice is still the one showing.
    pub dictation_notice_serial: u64,
    /// Selection actions' panel, as the engine last reported it.
    pub selection_actions: lokalbot_engine::SelectionView,
    /// "Mic · Receiving audio" / "System · Not attached" while recording.
    pub recording_statuses: Option<(SharedString, SharedString)>,
    /// When a lost track last came back; kept until the next recording starts.
    pub last_audio_recovery: Option<DateTime<Utc>>,
    /// The latest "Write with Think" for a meeting's follow-up.
    pub follow_up: Option<(Uuid, FollowUpWriting)>,
    /// The opt-in live transcript preview of the meeting being recorded.
    pub live_preview: lokalbot_engine::LivePreview,
    /// Read aloud: what is being read, and its last failure.
    pub speech: lokalbot_engine::SpeechStatus,
    /// Check model setup: the role being checked and the results so far.
    pub model_checks: lokalbot_engine::ModelCheckStatus,
    /// The last "Check connection".
    pub connection_check: lokalbot_engine::ConnectionCheck,
    /// Downloads cancelled since a model switch last started, so it can stop.
    pub cancelled_downloads: Vec<String>,
    /// Screen context capture, as the engine reports it.
    pub screen: lokalbot_engine::ScreenStatus,
    /// The user's calendars, as the engine last read them.
    pub calendar: lokalbot_engine::CalendarSnapshot,
    /// Paired phones and tablets, as the engine last reported them.
    pub companion: lokalbot_engine::CompanionSnapshot,
    /// The pairing request whose question is on screen.
    pub pairing_prompt: Option<u64>,
    /// Today's preparation for the next meeting (in memory only).
    pub meeting_preparation: Option<lokalbot_engine::MeetingPreparation>,
    /// "Try a sample meeting" waiting for its models (`sample.rs`).
    pub sample_setup: Option<crate::sample::SampleSetup>,
    /// What the routines are doing, and their recent runs.
    pub routines: lokalbot_engine::routines::RoutineStatus,
    /// The last retention pass.
    pub retention: lokalbot_engine::RetentionStatus,
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
        /// Until the microphone delivers audio the overlay says it is starting.
        microphone_live: bool,
        /// A microphone problem, in place of the level bars.
        capture_status: SharedString,
    },
    Transcribing,
    /// The speech model is loading, or downloading (how far, 0–1).
    Preparing(Option<f32>),
    /// The speech model did not load; Retry keeps the audio.
    PreparationFailed(SharedString),
    Composing,
    /// "Copied to the clipboard" and similar, shown briefly.
    Notice(SharedString),
    /// Pasted text the field did not show, with Copy.
    Undelivered {
        copied: bool,
    },
    Failed(SharedString),
}

/// How the last dictation came about (`DictationView.lastResultSection`).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct LastDictationDetails {
    /// What was said, when Compose wrote something else from it.
    pub spoken: Option<SharedString>,
    /// "Used: focused window; visible text".
    pub context: Option<SharedString>,
    /// "Parakeet v3 → Qwen3.5 4B · on this PC".
    pub engine: Option<SharedString>,
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
    /// Some screen text recognition engine can read now.
    pub screen_text_ready: bool,
    /// Which one, in which languages, and what download would help.
    pub screen_text: lokalbot_ai::ocr::OcrStatus,
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
    /// The folders chosen under Files; the engine honours it only while Files is on.
    pub include_files: bool,
    /// Saved coding-agent notes; the engine honours it only while they are read.
    pub include_agent_notes: bool,
    /// Screens this question is bound to or attaches.
    pub screen_ids: Vec<i64>,
    /// `screen_ids` were attached by the person, as primary evidence.
    pub attached_screens: bool,
    pub screen_app: Option<String>,
    pub since: Option<DateTime<Utc>>,
    pub until: Option<DateTime<Utc>>,
    /// The boundary saved with the question's turns.
    pub saved: lokalbot_core::QuestionScope,
}

pub struct AppHandle(pub Entity<AppData>);

impl Global for AppHandle {}

/// What the microphone pickers offer. A device with no name can't be chosen,
/// because the setting stores the name.
fn microphone_names(devices: &[lokalbot_audio::AudioDevice]) -> Vec<SharedString> {
    devices
        .iter()
        .filter(|device| !device.name.trim().is_empty())
        .map(|device| device.name.clone().into())
        .collect()
}

impl AppData {
    pub fn global(cx: &App) -> Entity<AppData> {
        cx.global::<AppHandle>().0.clone()
    }

    pub fn new(library: Library, mut settings: Settings) -> Self {
        // Each enabled period of the overnight review has a start, so an update
        // to a version that has it doesn't review older days.
        let normalized = settings.normalize_dreaming_boundary(chrono::Local::now().date_naive());
        let autocomplete = settings.cotyping_built_in_model_id.clone();
        let adopted = lokalbot_ai::catalog::adopt_default_autocomplete(&mut settings);
        if settings.cotyping_built_in_model_id != autocomplete {
            log::info!("autocomplete: the unused LFM2.5 default is now Gemma 4 E2B");
        }
        if (normalized || adopted)
            && let Err(err) = settings.save(&library.paths().settings_file())
        {
            log::error!("saving settings failed: {err}");
        }
        let (inference_label, remote_hosts) = inference_presentation(&settings);
        let privacy = PrivacyLine::new(&settings);
        Self {
            library,
            settings,
            meetings: Vec::new(),
            meetings_loaded: false,
            reloads_started: 0,
            reload_applied: 0,
            revision: 0,
            section: Section::Today,
            settings_category: SettingsCategory::Overview,
            settings_window_open: false,
            settings_focus: None,
            meeting_focus: None,
            evidence_return: None,
            capture_warnings: Vec::new(),
            ask_request: None,
            agent_request: None,
            meeting_find_requested: false,
            follow_up_request: None,
            timeline_focus: None,
            person_focus: None,
            project_focus: None,
            recording: RecordingState::Idle,
            processing: HashMap::new(),
            background: Vec::new(),
            toast: None,
            day_memory_paused: false,
            inference_label,
            remote_hosts,
            privacy,
            open_action_count: None,
            open_actions_counted: None,
            ask_stream: None,
            downloads: HashMap::new(),
            models: ModelStatus::default(),
            digest_running: None,
            speech: Default::default(),
            model_checks: Default::default(),
            connection_check: Default::default(),
            cancelled_downloads: Vec::new(),
            project_notes_running: Vec::new(),
            last_dictation: None,
            last_dictation_details: None,
            recent_dictations: Vec::new(),
            dream: Default::default(),
            dictation: DictationHud::Idle,
            dictation_transcript: Default::default(),
            dictation_notice_serial: 0,
            selection_actions: Default::default(),
            recording_statuses: None,
            last_audio_recovery: None,
            follow_up: None,
            live_preview: Default::default(),
            audio_inputs: Vec::new(),
            shortcut_recording: false,
            dictation_shortcut_inactive: false,
            screen: Default::default(),
            importing: Vec::new(),
            calendar: Default::default(),
            companion: Default::default(),
            pairing_prompt: None,
            ask_screen: None,
            ask_screens: None,
            ask_open_conversation: None,
            attached_asks: Default::default(),
            files: Default::default(),
            agent_notes: Default::default(),
            meeting_preparation: None,
            sample_setup: None,
            routines: Default::default(),
            retention: Default::default(),
        }
    }

    /// Asks the engine for work. Pages call this instead of emitting directly
    /// so every request goes through one place.
    pub fn request(&mut self, event: AppEvent, cx: &mut Context<Self>) {
        cx.emit(event);
    }

    // ------------------------------------------------------------ navigation

    /// Lists microphones away from the UI thread: audio backends can be slow.
    pub fn refresh_audio_inputs(&mut self, cx: &mut Context<Self>) {
        cx.spawn(async move |this, cx| {
            let devices = cx
                .background_spawn(async { lokalbot_audio::input_devices() })
                .await;
            this.update(cx, |this, cx| {
                this.audio_inputs = microphone_names(&devices);
                cx.notify();
            })
            .ok();
        })
        .detach();
    }

    pub fn navigate(&mut self, section: Section, cx: &mut Context<Self>) {
        self.section = section;
        self.evidence_return = None;
        cx.notify();
    }

    pub fn open_meeting(
        &mut self,
        meeting_id: Uuid,
        tab: MeetingTab,
        at: Option<f64>,
        cx: &mut Context<Self>,
    ) {
        if self.section != Section::Meetings {
            self.evidence_return = Some(EvidenceReturn {
                section: self.section,
            });
        }
        self.meeting_focus = Some(MeetingFocus {
            meeting_id,
            tab,
            at,
        });
        self.section = Section::Meetings;
        cx.notify();
    }

    /// Back to where evidence was opened from (`returnFromEvidence`).
    pub fn return_from_evidence(&mut self, cx: &mut Context<Self>) {
        if let Some(back) = self.evidence_return.take() {
            self.section = back.section;
            cx.notify();
        }
    }

    /// Repeats only what failed (`AppState.retryProcessing`). A person's retry
    /// may download what it needs.
    pub fn retry_processing(&mut self, meeting_id: Uuid, cx: &mut Context<Self>) {
        let Some(meeting) = self.meeting(meeting_id).cloned() else {
            return;
        };
        let (transcribe, summarize) = self
            .library
            .retry_work(&meeting, self.settings.auto_summarize)
            .unwrap_or((true, true));
        self.request(
            AppEvent::ProcessMeeting {
                meeting_id,
                transcribe,
                summarize,
            },
            cx,
        );
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
        if self.section != Section::Timeline {
            self.evidence_return = Some(EvidenceReturn {
                section: self.section,
            });
        }
        self.timeline_focus = Some(TimelineFocus {
            day: lokalbot_core::time::local_day(ts),
            session_id: None,
            moment_id: Some(id),
        });
        self.section = Section::Timeline;
        cx.notify();
    }

    /// The Actions page (`openActions`).
    pub fn open_actions(&mut self, cx: &mut Context<Self>) {
        self.navigate(Section::Actions, cx);
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

    /// Opens the Settings window on `category`, or brings it forward there
    /// (`AppState.openSettings(tab:)`). The main window stays where it was.
    /// Every link, menu, command and notification that leads to Settings
    /// comes through here.
    pub fn open_settings(&mut self, category: SettingsCategory, cx: &mut Context<Self>) {
        self.refresh_audio_inputs(cx);
        self.settings_category = category;
        cx.defer(crate::windows::settings::open);
        cx.notify();
    }

    /// A category picked inside the Settings window, which is already open.
    pub fn select_settings_category(&mut self, category: SettingsCategory, cx: &mut Context<Self>) {
        if self.settings_category != category {
            self.settings_category = category;
            cx.notify();
        }
    }

    /// The Settings window shows `category` right now.
    pub fn settings_showing(&self, category: SettingsCategory) -> bool {
        self.settings_window_open && self.settings_category == category
    }

    /// Counts the user's open action threads again when the library changed
    /// since the last count. The count runs off the UI thread.
    pub fn refresh_open_action_count(&mut self, cx: &mut Context<Self>) {
        if !self.meetings_loaded || self.open_actions_counted == Some(self.revision) {
            return;
        }
        let revision = self.revision;
        self.open_actions_counted = Some(revision);
        let library = self.library.clone();
        cx.spawn(async move |this, cx| {
            let count = cx
                .background_spawn(async move {
                    library
                        .action_threads(None)
                        .map(|threads| open_user_action_count(&threads))
                })
                .await;
            let _ = this.update(cx, |this, cx| {
                // A newer count has started; it will report.
                if this.open_actions_counted != Some(revision) {
                    return;
                }
                match count {
                    Ok(count) if this.open_action_count != Some(count) => {
                        this.open_action_count = Some(count);
                        cx.notify();
                    }
                    Ok(_) => {}
                    Err(err) => log::warn!("counting open actions: {err:#}"),
                }
            });
        })
        .detach();
    }

    pub fn ask(&mut self, request: AskRequest, cx: &mut Context<Self>) {
        self.ask_request = Some(request);
        self.section = Section::Ask;
        cx.notify();
    }

    /// Sends a question, keeping what a retry of it would need.
    pub fn ask_question(
        &mut self,
        conversation_id: Uuid,
        question: String,
        scope: AskScope,
        retry_of: Option<Uuid>,
        cx: &mut Context<Self>,
    ) {
        if scope.attached_screens {
            self.attached_asks.insert(conversation_id, scope.clone());
        } else {
            self.attached_asks.remove(&conversation_id);
        }
        self.request(
            AppEvent::AskQuestion {
                conversation_id,
                question,
                scope: Box::new(scope),
                retry_of,
            },
            cx,
        );
    }

    /// Agent with `prompt` in its composer, unsent (`AppState.openAgent`).
    pub fn open_agent(&mut self, prompt: String, cx: &mut Context<Self>) {
        self.agent_request = Some(AgentRequest::Prompt(prompt));
        self.section = Section::Agent;
        cx.notify();
    }

    // --------------------------------------------------------------- library

    /// Reloads the meeting list on a background thread.
    pub fn reload(&mut self, cx: &mut Context<Self>) {
        let library = self.library.clone();
        self.reloads_started += 1;
        let reload = self.reloads_started;
        cx.spawn(async move |this, cx| {
            let loaded = cx
                .background_spawn(async move { library.list_meetings() })
                .await;
            let _ = this.update(cx, |this, cx| {
                // Reads overlap; a slower, older one would bring back a
                // meeting that a newer one no longer lists.
                if reload <= this.reload_applied {
                    return;
                }
                this.reload_applied = reload;
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
                    // The merged meeting's own contributions leave remembered voices.
                    if let Err(err) =
                        lokalbot_engine::voice::memory(&library).prepare_deletion(&merged)
                    {
                        log::warn!("speaker voice not forgotten meeting={}: {err}", merged.id);
                    }
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
        // The recorder is still writing into the folder of the meeting being
        // recorded; it can be deleted once the recording has stopped.
        if self
            .recording
            .meeting()
            .is_some_and(|live| live.id == meeting_id)
        {
            return;
        }
        let Some(meeting) = self.meeting(meeting_id).cloned() else {
            return;
        };
        let library = self.library.clone();
        cx.spawn(async move |this, cx| {
            let result = cx
                .background_spawn(async move {
                    lokalbot_engine::voice::delete_meeting(&library, &meeting)
                })
                .await;
            let _ = this.update(cx, |this, cx| {
                match result {
                    Ok(Some(pending)) => this.show_error(pending, cx),
                    Ok(None) => {}
                    Err(err) => this.show_error(
                        lokalbot_i18n::format(
                            "Could not delete the meeting: {err}",
                            &[("err", format!("{:#}", err))],
                        ),
                        cx,
                    ),
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

    /// Deletes every saved agent session, withdrawing the generated journals that
    /// used them. The agents' own files stay.
    pub fn delete_coding_agent_evidence(&mut self, cx: &mut Context<Self>) {
        let library = self.library.clone();
        self.run_library_change(
            lokalbot_i18n::tr("Could not delete saved agent sessions"),
            move || library.delete_coding_agent_evidence().map(|_| ()),
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
        self.settings
            .normalize_dreaming_boundary(chrono::Local::now().date_naive());
        if self.settings == before {
            return;
        }
        if before.app_language != self.settings.app_language {
            crate::i18n::apply(&self.settings.app_language, cx);
        }
        // The engine applies it too, but the meeting view redraws first.
        lokalbot_core::SpeakerAttribution::set_microphone_is_user(self.settings.microphone_is_user);
        let (label, hosts) = inference_presentation(&self.settings);
        self.inference_label = label;
        self.remote_hosts = hosts;
        self.privacy = PrivacyLine::new(&self.settings);
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
    /// A name was given or applied: remember the voice and suggest it elsewhere.
    LearnSpeakerVoices,
    StartRecording,
    StopRecording,
    SettingsChanged,
    AppearanceChanged,
    /// The overnight review, now.
    ReviewNow,
    /// Delete every overnight review and the work memory.
    ClearWorkMemory,
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
        scope: Box<AskScope>,
        /// The failed turn this asks again.
        retry_of: Option<Uuid>,
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
    /// Saves, or when blank removes, autocomplete's own server key.
    SaveAutocompleteServerKey(String),
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
    /// "Run now" for a routine.
    RunRoutine(lokalbot_core::settings::MemoryRoutineKind),
    /// "Run retention now".
    RunRetentionNow,
    RestartMemoryCapture,
}

impl gpui_kit::EventEmitter<AppEvent> for AppData {}

/// Think's line and the hosts Settings names in its disclosures (Overview's
/// Models status, Compose dictation, phones' questions). The sidebar's own
/// line is [`PrivacyLine`].
pub fn inference_presentation(settings: &Settings) -> (SharedString, Vec<SharedString>) {
    use lokalbot_core::settings::SummarizerBackend;
    if let Some(plan) = settings.think_plan() {
        let mut hosts: Vec<SharedString> = vec![plan.destination_host().into()];
        hosts.extend(
            lokalbot_core::remote_transcription::audio_destination(settings)
                .map(SharedString::from),
        );
        return (lokalbot_i18n::tr("AI: local + remote").into(), hosts);
    }
    let url = match settings.summarizer_backend {
        SummarizerBackend::Ollama => Some(settings.ollama_base_url.as_str()),
        SummarizerBackend::OpenAICompatible => Some(settings.openai_base_url.as_str()),
        SummarizerBackend::BuiltIn
        | SummarizerBackend::ChatGptPlan
        | SummarizerBackend::ClaudePlan => None,
    };
    let mut hosts: Vec<SharedString> = Vec::new();
    if let Some(url) = url.filter(|url| !lokalbot_core::access::is_loopback_url(url)) {
        let host = lokalbot_core::access::origin_of(url)
            .map(|o| o.split_once("://").map(|(_, h)| h.to_string()).unwrap_or(o))
            .unwrap_or_else(|| url.to_string());
        hosts.push(host.into());
    }
    if let Some(host) = lokalbot_core::remote_transcription::audio_destination(settings)
        && !hosts.iter().any(|known| known.as_ref() == host)
    {
        hosts.push(host.into());
    }
    if hosts.is_empty() {
        (lokalbot_i18n::tr("AI: on this PC").into(), hosts)
    } else {
        (lokalbot_i18n::tr("AI: local + remote").into(), hosts)
    }
}

/// The sidebar's line about where the library and the AI are
/// (`SidebarPrivacyLine`). It reflects the actual setup instead of a fixed
/// claim: with everything on this computer it is one line; a remote Think,
/// transcription or autocomplete server, or a Think connection that is
/// blocked, splits storage from AI and names each host once, because
/// meeting and workday text goes to those hosts.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PrivacyLine {
    /// "On this PC".
    Local,
    /// "Storage: this PC", the AI line, then each host.
    Split { blocked: bool, hosts: Vec<String> },
}

impl PrivacyLine {
    pub fn new(settings: &Settings) -> Self {
        let blocked = !lokalbot_ai::think::allows_automatic_main_inference(settings);
        let hosts = remote_ai_hosts(settings);
        if hosts.is_empty() && !blocked {
            PrivacyLine::Local
        } else {
            PrivacyLine::Split { blocked, hosts }
        }
    }

    /// The AI line under "Storage: this PC": what the Mac's sidebar says for
    /// a split setup.
    pub fn ai_label(blocked: bool) -> &'static str {
        if blocked {
            lokalbot_i18n::tr("AI: connection blocked")
        } else {
            lokalbot_i18n::tr("AI: local + remote")
        }
    }
}

/// Every server that receives what this computer's AI features send, each
/// named once: Think's (while its connection is allowed), the transcription
/// server and, while autocomplete is on, the server it sends typing to
/// (`AppSettings.remoteAIHosts`). Leaving autocomplete out once read "on this
/// computer" while every suggestion request went to a server.
pub fn remote_ai_hosts(settings: &Settings) -> Vec<String> {
    use lokalbot_core::settings::SummarizerBackend;
    let mut hosts: Vec<String> = Vec::new();
    let mut add = |host: String| {
        if !host.is_empty() && !hosts.contains(&host) {
            hosts.push(host);
        }
    };
    if lokalbot_ai::think::allows_automatic_main_inference(settings) {
        if let Some(plan) = settings.think_plan() {
            add(plan.destination_host().to_string());
        } else {
            let url = match settings.summarizer_backend {
                SummarizerBackend::Ollama => Some(settings.ollama_base_url.as_str()),
                SummarizerBackend::OpenAICompatible => Some(settings.openai_base_url.as_str()),
                SummarizerBackend::BuiltIn
                | SummarizerBackend::ChatGptPlan
                | SummarizerBackend::ClaudePlan => None,
            };
            if let Some(host) = url
                .map(str::trim)
                .filter(|url| !lokalbot_core::access::is_loopback_url(url))
                .and_then(lokalbot_core::access::host_of)
            {
                add(host);
            }
        }
    }
    if let Some(host) = lokalbot_core::remote_transcription::audio_destination(settings) {
        add(host);
    }
    if settings.cotyping_enabled
        && lokalbot_ai::autocomplete::server::leaves_this_computer(settings)
        && let Some(host) = lokalbot_ai::autocomplete::server::configured_host(settings)
    {
        add(host);
    }
    hosts
}

/// How many action threads are open and the user's: the number beside
/// Actions in the sidebar (`OutcomeIndex.openUserActionThreads.count`).
pub fn open_user_action_count(threads: &[lokalbot_core::ActionThread]) -> usize {
    threads
        .iter()
        .filter(|thread| thread.is_for_user() && thread.status() == ActionStatus::Open)
        .count()
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::{reference, thread};
    use lokalbot_core::settings::{CotypingBackend, SubscriptionPlan, SummarizerBackend};

    #[test]
    fn everything_on_this_computer_is_one_line() {
        assert_eq!(PrivacyLine::new(&Settings::default()), PrivacyLine::Local);
        // A model server on this computer is still this computer.
        let ollama = Settings {
            summarizer_backend: SummarizerBackend::Ollama,
            ollama_base_url: "http://127.0.0.1:11434".into(),
            ..Default::default()
        };
        assert_eq!(PrivacyLine::new(&ollama), PrivacyLine::Local);
    }

    fn openai(url: &str, approved: &[&str]) -> Settings {
        Settings {
            summarizer_backend: SummarizerBackend::OpenAICompatible,
            openai_base_url: url.into(),
            approved_remote_inference_origins: approved.iter().map(|o| o.to_string()).collect(),
            ..Default::default()
        }
    }

    fn backend(backend: SummarizerBackend) -> Settings {
        Settings {
            summarizer_backend: backend,
            ..Default::default()
        }
    }

    #[test]
    fn a_remote_think_server_splits_storage_and_names_its_host() {
        let settings = openai("https://api.openai.com/v1", &["https://api.openai.com"]);
        assert_eq!(
            PrivacyLine::new(&settings),
            PrivacyLine::Split {
                blocked: false,
                hosts: vec!["api.openai.com".into()]
            }
        );
        // A subscription plan names the host it sends to once approved.
        let mut plan = backend(SummarizerBackend::ChatGptPlan);
        SubscriptionPlan::ChatGpt.set_approved(&mut plan, true);
        assert_eq!(
            PrivacyLine::new(&plan),
            PrivacyLine::Split {
                blocked: false,
                hosts: vec!["api.openai.com".into()]
            }
        );
    }

    #[test]
    fn a_blocked_think_connection_says_so_and_names_no_host() {
        let blocked = PrivacyLine::Split {
            blocked: true,
            hosts: Vec::new(),
        };
        let unapproved = openai("https://gpu.example/v1", &[]);
        assert_eq!(PrivacyLine::new(&unapproved), blocked);
        let plan = backend(SummarizerBackend::ClaudePlan);
        assert_eq!(PrivacyLine::new(&plan), blocked);
        assert_eq!(PrivacyLine::ai_label(true), "AI: connection blocked");
        assert_eq!(PrivacyLine::ai_label(false), "AI: local + remote");
    }

    #[test]
    fn autocomplete_names_its_server_only_while_on_and_each_host_once() {
        let mut settings = Settings {
            cotyping_backend: CotypingBackend::Server,
            cotyping_server_base_url: "https://complete.example/v1".into(),
            ..Default::default()
        };
        assert_eq!(
            PrivacyLine::new(&settings),
            PrivacyLine::Local,
            "autocomplete off"
        );
        settings.cotyping_enabled = true;
        assert_eq!(
            PrivacyLine::new(&settings),
            PrivacyLine::Split {
                blocked: false,
                hosts: vec!["complete.example".into()]
            }
        );
        // Autocomplete on Think's own server lists that server once.
        let mut think = openai("https://api.openai.com/v1", &["https://api.openai.com"]);
        think.cotyping_enabled = true;
        think.cotyping_backend = CotypingBackend::ThinkServer;
        assert_eq!(remote_ai_hosts(&think), vec!["api.openai.com".to_string()]);
        // On this computer it sends nothing anywhere.
        think.cotyping_backend = CotypingBackend::OnDevice;
        assert_eq!(remote_ai_hosts(&think), vec!["api.openai.com".to_string()]);
    }

    #[test]
    fn the_actions_count_is_open_threads_that_are_yours() {
        let threads = vec![
            thread(vec![reference("a", ActionStatus::Open, true, None, 2)]),
            thread(vec![reference("b", ActionStatus::Done, true, None, 3)]),
            thread(vec![reference("c", ActionStatus::Deferred, true, None, 4)]),
            // Someone else's work is theirs to count.
            thread(vec![reference("d", ActionStatus::Open, false, None, 5)]),
            // Done in one meeting, still open in another: open.
            thread(vec![
                reference("e", ActionStatus::Done, true, None, 7),
                reference("e", ActionStatus::Open, true, None, 6),
            ]),
        ];
        assert_eq!(open_user_action_count(&threads), 2);
        assert_eq!(open_user_action_count(&[]), 0);
    }

    #[test]
    fn page_names_reach_their_section_or_settings_page() {
        assert_eq!(Section::named("actions"), Some(Section::Actions));
        assert_eq!(Section::named("Timeline"), Some(Section::Timeline));
        assert_eq!(Section::named("capture"), Some(Section::Timeline));
        assert_eq!(Section::named("search"), Some(Section::Ask));
        // Settings is a window, not a section.
        assert_eq!(Section::named("settings"), None);
        assert_eq!(
            SettingsCategory::named("settings"),
            Some(SettingsCategory::Overview)
        );
        assert_eq!(
            SettingsCategory::named("settings-models"),
            Some(SettingsCategory::Models)
        );
        assert_eq!(SettingsCategory::named("today"), None);
    }

    #[test]
    fn pickers_offer_named_microphones_only() {
        let device = |name: &str| lokalbot_audio::AudioDevice {
            id: format!("id-{name}"),
            name: name.to_string(),
            is_default: false,
        };
        assert_eq!(
            microphone_names(&[device("Desk mic"), device("  "), device("Headset")]),
            vec![
                SharedString::from("Desk mic"),
                SharedString::from("Headset")
            ]
        );
    }
}
