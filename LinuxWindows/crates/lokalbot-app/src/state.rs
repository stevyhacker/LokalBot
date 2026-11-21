use std::collections::HashMap;
use std::time::Instant;

use chrono::{DateTime, Utc};
use gpui_kit::{App, AppContext as _, Context, Entity, Global, SharedString};
use lokalbot_core::{ActionStatus, Library, Meeting, Settings};
use uuid::Uuid;

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

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum MeetingTab {
    #[default]
    Summary,
    Transcript,
    Notes,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub enum SettingsCategory {
    #[default]
    Overview,
    General,
    Models,
    Privacy,
    Meetings,
    DayMemory,
    Files,
    Ask,
    PersonalContext,
    DailyReview,
    Writing,
    Dictation,
    Agents,
    Devices,
    Advanced,
}

impl SettingsCategory {
    pub fn named(name: &str) -> Option<SettingsCategory> {
        let name = name.to_ascii_lowercase();
        if name == "settings" {
            return Some(SettingsCategory::Overview);
        }
        let page = name.strip_prefix("settings-")?;
        Some(match page {
            "overview" => SettingsCategory::Overview,
            "general" => SettingsCategory::General,
            "models" => SettingsCategory::Models,
            "privacy" | "permissions" => SettingsCategory::Privacy,
            "meetings" | "recording" => SettingsCategory::Meetings,
            "day-memory" | "screen" | "activity" => SettingsCategory::DayMemory,
            "files" => SettingsCategory::Files,
            "ask" => SettingsCategory::Ask,
            "personal-context" | "about-you" => SettingsCategory::PersonalContext,
            "daily" | "daily-review" | "overnight" | "routines" => SettingsCategory::DailyReview,
            "writing" | "autocomplete" => SettingsCategory::Writing,
            "dictation" => SettingsCategory::Dictation,
            "agents" | "ai-agents" | "external-agents" => SettingsCategory::Agents,
            "devices" | "phones" => SettingsCategory::Devices,
            "advanced" | "diagnostics" => SettingsCategory::Advanced,
            _ => return None,
        })
    }

    pub fn key(self) -> &'static str {
        match self {
            SettingsCategory::Overview => "overview",
            SettingsCategory::General => "general",
            SettingsCategory::Models => "models",
            SettingsCategory::Privacy => "privacy",
            SettingsCategory::Meetings => "recording",
            SettingsCategory::DayMemory => "dayMemory",
            SettingsCategory::Files => "files",
            SettingsCategory::Ask => "ask",
            SettingsCategory::PersonalContext => "personalContext",
            SettingsCategory::DailyReview => "daily",
            SettingsCategory::Writing => "writing",
            SettingsCategory::Dictation => "dictation",
            SettingsCategory::Agents => "agents",
            SettingsCategory::Devices => "devices",
            SettingsCategory::Advanced => "advanced",
        }
    }

    pub fn from_key(key: &str) -> SettingsCategory {
        crate::pages::settings::CATEGORIES
            .into_iter()
            .find(|category| category.key() == key)
            .unwrap_or_default()
    }
}

#[derive(Clone, Debug, PartialEq)]
#[allow(clippy::large_enum_variant)]
pub enum RecordingState {
    Idle,
    Recording {
        meeting: Meeting,
        started: Instant,
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

#[derive(Clone, Debug, PartialEq)]
pub struct BackgroundItem {
    pub id: SharedString,
    pub kind: BackgroundKind,
    pub title: SharedString,
    pub detail: SharedString,
    pub progress: Option<f32>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Toast {
    pub message: SharedString,
    pub is_error: bool,
}

#[derive(Clone, Debug, PartialEq)]
pub struct AskRequest {
    pub question: String,
    pub meeting_ids: Vec<Uuid>,
    pub submit: bool,
    pub day: Option<chrono::NaiveDate>,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct EvidenceReturn {
    pub section: Section,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum AgentRequest {
    NewTask,
    SearchTasks,
    FindInTask,
    ToggleResults,
    SelectTask(Uuid),
    Prompt(String),
}

#[derive(Clone, Debug, PartialEq)]
pub struct TimelineFocus {
    pub day: chrono::NaiveDate,
    pub session_id: Option<String>,
    pub moment_id: Option<i64>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct MeetingFocus {
    pub meeting_id: Uuid,
    pub tab: MeetingTab,
    pub at: Option<f64>,
}

pub struct AppData {
    pub library: Library,
    pub settings: Settings,
    pub meetings: Vec<Meeting>,
    pub meetings_loaded: bool,
    reloads_started: u64,
    reload_applied: u64,
    pub revision: u64,
    pub section: Section,
    pub settings_category: SettingsCategory,
    pub settings_window_open: bool,
    pub settings_focus: Option<String>,
    pub meeting_focus: Option<MeetingFocus>,
    pub evidence_return: Option<EvidenceReturn>,
    pub capture_warnings: Vec<SharedString>,
    pub ask_request: Option<AskRequest>,
    pub agent_request: Option<AgentRequest>,
    pub meeting_find_requested: bool,
    pub follow_up_request: Option<Uuid>,
    pub ask_screen: Option<lokalbot_core::ScreenMoment>,
    pub ask_screens: Option<Vec<i64>>,
    pub ask_sources: Option<Vec<lokalbot_core::AskSourceScope>>,
    pub ask_open_conversation: Option<Uuid>,
    pub attached_asks: std::collections::HashMap<Uuid, AskScope>,
    pub files: lokalbot_engine::files::FileSearchStatus,
    pub agent_notes: lokalbot_engine::agent_notes::AgentNotesStatus,
    pub timeline_focus: Option<TimelineFocus>,
    pub person_focus: Option<String>,
    pub project_focus: Option<String>,
    pub recording: RecordingState,
    pub processing: HashMap<Uuid, ProcessingStage>,
    pub importing: Vec<SharedString>,
    pub background: Vec<BackgroundItem>,
    pub toast: Option<Toast>,
    pub day_memory_paused: bool,
    pub inference_label: SharedString,
    pub remote_hosts: Vec<SharedString>,
    pub privacy: PrivacyLine,
    pub open_action_count: Option<usize>,
    open_actions_counted: Option<u64>,
    pub ask_stream: Option<AskStream>,
    pub downloads: HashMap<String, DownloadProgress>,
    pub models: ModelStatus,
    pub digest_running: Option<chrono::NaiveDate>,
    pub project_notes_running: Vec<String>,
    pub last_dictation: Option<SharedString>,
    pub last_dictation_details: Option<LastDictationDetails>,
    pub recent_dictations: Vec<lokalbot_core::dictation_history::Entry>,
    pub dream: lokalbot_engine::dreaming::DreamStatus,
    pub audio_inputs: Vec<SharedString>,
    pub access: crate::access::Probe,
    access_read_at: Option<std::time::Instant>,
    access_reading: bool,
    pub shortcut_recording: bool,
    pub dictation_shortcut_inactive: bool,
    pub dictation: DictationHud,
    pub dictation_transcript: lokalbot_ai::dictation_preview::LiveTranscript,
    pub dictation_notice_serial: u64,
    pub selection_actions: lokalbot_engine::SelectionView,
    pub recording_statuses: Option<(SharedString, SharedString)>,
    pub last_audio_recovery: Option<DateTime<Utc>>,
    pub follow_up: Option<(Uuid, FollowUpWriting)>,
    pub live_preview: lokalbot_engine::LivePreview,
    pub speech: lokalbot_engine::SpeechStatus,
    pub model_checks: lokalbot_engine::ModelCheckStatus,
    pub connection_check: lokalbot_engine::ConnectionCheck,
    pub cancelled_downloads: Vec<String>,
    pub screen: lokalbot_engine::ScreenStatus,
    pub calendar: lokalbot_engine::CalendarSnapshot,
    pub companion: lokalbot_engine::CompanionSnapshot,
    pub pairing_prompt: Option<u64>,
    pub meeting_preparation: Option<lokalbot_engine::MeetingPreparation>,
    pub sample_setup: Option<crate::sample::SampleSetup>,
    pub routines: lokalbot_engine::routines::RoutineStatus,
    pub retention: lokalbot_engine::RetentionStatus,
}

#[derive(Clone, Debug, PartialEq)]
pub enum FollowUpWriting {
    Writing,
    Written {
        subject: SharedString,
        body: SharedString,
        model: SharedString,
    },
    Failed(SharedString),
}

#[derive(Clone, Debug, Default, PartialEq)]
pub enum DictationHud {
    #[default]
    Idle,
    Starting,
    Listening {
        level: f32,
        elapsed: f64,
        microphone_live: bool,
        capture_status: SharedString,
    },
    Transcribing,
    Preparing(Option<f32>),
    PreparationFailed(SharedString),
    Composing,
    Notice(SharedString),
    Undelivered {
        copied: bool,
    },
    Failed(SharedString),
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct LastDictationDetails {
    pub spoken: Option<SharedString>,
    pub context: Option<SharedString>,
    pub engine: Option<SharedString>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct AskStream {
    pub conversation_id: Uuid,
    pub question: String,
    pub text: String,
    pub activity: Vec<String>,
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

#[derive(Clone, Debug, Default, PartialEq)]
pub struct ModelStatus {
    pub installed: Vec<String>,
    pub transcription_ready: bool,
    pub think_ready: bool,
    pub autocomplete_ready: bool,
    pub embeddings_ready: bool,
    pub screen_text_ready: bool,
    pub screen_text: lokalbot_ai::ocr::OcrStatus,
    pub runtime_backend: Option<SharedString>,
    pub runtime_needs_check: bool,
    pub runtime_storage: Vec<lokalbot_ai::runtime::RuntimeStorage>,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct AskScope {
    pub meeting_ids: Vec<Uuid>,
    pub include_meetings: bool,
    pub include_activity: bool,
    pub include_screen: bool,
    pub include_files: bool,
    pub include_agent_notes: bool,
    pub screen_ids: Vec<i64>,
    pub attached_screens: bool,
    pub screen_app: Option<String>,
    pub since: Option<DateTime<Utc>>,
    pub until: Option<DateTime<Utc>>,
    pub saved: lokalbot_core::QuestionScope,
}

pub struct AppHandle(pub Entity<AppData>);

impl Global for AppHandle {}

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
        let settings_category = SettingsCategory::from_key(&settings.settings_page);
        Self {
            library,
            settings,
            meetings: Vec::new(),
            meetings_loaded: false,
            reloads_started: 0,
            reload_applied: 0,
            revision: 0,
            section: Section::Today,
            settings_category,
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
            access: Default::default(),
            access_read_at: None,
            access_reading: false,
            shortcut_recording: false,
            dictation_shortcut_inactive: false,
            screen: Default::default(),
            importing: Vec::new(),
            calendar: Default::default(),
            companion: Default::default(),
            pairing_prompt: None,
            ask_screen: None,
            ask_screens: None,
            ask_sources: None,
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

    pub fn request(&mut self, event: AppEvent, cx: &mut Context<Self>) {
        cx.emit(event);
    }

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

    pub fn refresh_access(&mut self, cx: &mut Context<Self>) {
        if self.access_reading {
            return;
        }
        self.access_reading = true;
        cx.spawn(async move |this, cx| {
            let probe = cx
                .background_spawn(async { crate::access::Probe::read() })
                .await;
            this.update(cx, |this, cx| {
                this.access_reading = false;
                this.access_read_at = Some(std::time::Instant::now());
                if this.access != probe {
                    this.access = probe;
                    cx.notify();
                }
            })
            .ok();
        })
        .detach();
    }

    pub fn refresh_access_if_stale(&mut self, cx: &mut Context<Self>) {
        if self
            .access_read_at
            .is_none_or(|at| at.elapsed() >= std::time::Duration::from_secs(10))
        {
            self.refresh_access(cx);
        }
    }

    pub fn access_observed(&self) -> crate::access::Observed {
        crate::access::Observed {
            microphone_found: !self.audio_inputs.is_empty(),
            capture_failed: self.screen.capture_limitation.is_some(),
            key_failed: self.screen.images_unavailable.is_some(),
        }
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

    pub fn return_from_evidence(&mut self, cx: &mut Context<Self>) {
        if let Some(back) = self.evidence_return.take() {
            self.section = back.section;
            cx.notify();
        }
    }

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

    pub fn open_settings(&mut self, category: SettingsCategory, cx: &mut Context<Self>) {
        self.refresh_audio_inputs(cx);
        self.refresh_access(cx);
        self.select_settings_category(category, cx);
        cx.defer(crate::windows::settings::open);
        cx.notify();
    }

    pub fn select_settings_category(&mut self, category: SettingsCategory, cx: &mut Context<Self>) {
        if self.settings_category == category {
            return;
        }
        self.settings_category = category;
        self.remember_settings_page(cx);
        cx.notify();
    }

    fn remember_settings_page(&mut self, cx: &mut Context<Self>) {
        let key = self.settings_category.key();
        if self.settings.settings_page == key {
            return;
        }
        self.settings.settings_page = key.to_string();
        let path = self.library.paths().settings_file();
        let settings = self.settings.clone();
        cx.background_spawn(async move {
            if let Err(err) = settings.save(&path) {
                log::error!("saving settings failed: {err}");
            }
        })
        .detach();
    }

    pub fn settings_showing(&self, category: SettingsCategory) -> bool {
        self.settings_window_open && self.settings_category == category
    }

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

    pub fn open_agent(&mut self, prompt: String, cx: &mut Context<Self>) {
        self.agent_request = Some(AgentRequest::Prompt(prompt));
        self.section = Section::Agent;
        cx.notify();
    }

    pub fn reload(&mut self, cx: &mut Context<Self>) {
        let library = self.library.clone();
        self.reloads_started += 1;
        let reload = self.reloads_started;
        cx.spawn(async move |this, cx| {
            let loaded = cx
                .background_spawn(async move { library.list_meetings() })
                .await;
            let _ = this.update(cx, |this, cx| {
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

    pub fn is_processing(&self, meeting_id: Uuid) -> bool {
        self.processing
            .get(&meeting_id)
            .is_some_and(|stage| !matches!(stage, ProcessingStage::Failed(_)))
    }

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

    pub fn delete_screen_moment(&mut self, id: i64, cx: &mut Context<Self>) {
        let library = self.library.clone();
        self.run_library_change(
            lokalbot_i18n::tr("Could not delete the captured screen"),
            move || library.delete_screen_moments(&[id]).map(|_| ()),
            cx,
        );
    }

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

#[derive(Clone, Debug, PartialEq)]
pub enum AppEvent {
    LearnSpeakerVoices,
    StartRecording,
    StopRecording,
    SettingsChanged,
    AppearanceChanged,
    ReviewNow,
    ClearWorkMemory,
    ProcessMeeting {
        meeting_id: Uuid,
        transcribe: bool,
        summarize: bool,
    },
    RegenerateDigest(chrono::NaiveDate),
    AskQuestion {
        conversation_id: Uuid,
        question: String,
        scope: Box<AskScope>,
        retry_of: Option<Uuid>,
    },
    StopAnswer,
    DownloadModel(String),
    CancelDownload(String),
    DeleteModel(String),
    PrepareModels,
    SetDayMemoryPaused(bool),
    WriteProjectNote(String),
    WriteFollowUp(Uuid),
    LivePreview(lokalbot_engine::LivePreviewCommand),
    OpenOnboarding,
    ToggleDictation,
    CancelDictation,
    MeetingDetected {
        app_name: String,
        title: String,
    },
    SaveApiKey(String),
    SaveAutocompleteServerKey(String),
    CaptureScreenNow,
    RecordCalendarEvent(Box<lokalbot_core::calendar::CalendarEvent>),
    SetCalendarLinks(Vec<String>),
    RefreshCalendar,
    PrepareMeeting {
        event: Box<lokalbot_core::calendar::CalendarEvent>,
        generate: bool,
    },
    RunRoutine(lokalbot_core::settings::MemoryRoutineKind),
    RunRetentionNow,
    RestartMemoryCapture,
}

impl gpui_kit::EventEmitter<AppEvent> for AppData {}

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
        | SummarizerBackend::ClaudePlan
        | SummarizerBackend::AntigravityPlan
        | SummarizerBackend::GeminiPlan => None,
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

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PrivacyLine {
    Local,
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

    pub fn ai_label(blocked: bool) -> &'static str {
        if blocked {
            lokalbot_i18n::tr("AI: connection blocked")
        } else {
            lokalbot_i18n::tr("AI: local + remote")
        }
    }
}

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
                | SummarizerBackend::ClaudePlan
                | SummarizerBackend::AntigravityPlan
                | SummarizerBackend::GeminiPlan => None,
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

pub fn open_user_action_count(threads: &[lokalbot_core::ActionThread]) -> usize {
    threads
        .iter()
        .filter(|thread| thread.is_for_user() && thread.status() == ActionStatus::Open)
        .count()
}

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
        let mut think = openai("https://api.openai.com/v1", &["https://api.openai.com"]);
        think.cotyping_enabled = true;
        think.cotyping_backend = CotypingBackend::ThinkServer;
        assert_eq!(remote_ai_hosts(&think), vec!["api.openai.com".to_string()]);
        think.cotyping_backend = CotypingBackend::OnDevice;
        assert_eq!(remote_ai_hosts(&think), vec!["api.openai.com".to_string()]);
    }

    #[test]
    fn the_actions_count_is_open_threads_that_are_yours() {
        let threads = vec![
            thread(vec![reference("a", ActionStatus::Open, true, None, 2)]),
            thread(vec![reference("b", ActionStatus::Done, true, None, 3)]),
            thread(vec![reference("c", ActionStatus::Deferred, true, None, 4)]),
            thread(vec![reference("d", ActionStatus::Open, false, None, 5)]),
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
        assert_eq!(
            SettingsCategory::named("settings-diagnostics"),
            Some(SettingsCategory::Advanced)
        );
        assert_eq!(
            SettingsCategory::named("settings-ai-agents"),
            Some(SettingsCategory::Agents)
        );
        assert_eq!(
            SettingsCategory::named("settings-daily-review"),
            Some(SettingsCategory::DailyReview)
        );
        assert_eq!(SettingsCategory::named("settings-nope"), None);
    }

    #[test]
    fn the_saved_settings_page_round_trips() {
        for category in crate::pages::settings::CATEGORIES {
            assert_eq!(SettingsCategory::from_key(category.key()), category);
        }
        assert_eq!(SettingsCategory::from_key(""), SettingsCategory::Overview);
        assert_eq!(
            SettingsCategory::from_key("tabThatIsGone"),
            SettingsCategory::Overview
        );
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
