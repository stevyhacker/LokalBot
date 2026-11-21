use chrono::{DateTime, NaiveDate, Utc};
use lokalbot_core::{Meeting, Settings};
use uuid::Uuid;

#[derive(Clone, Debug)]
pub enum Command {
    ReviewNow,
    ClearWorkMemory,
    LearnSpeakerVoices,
    StartRecording {
        title: Option<String>,
        app_name: Option<String>,
    },
    StopRecording,
    PrepareForQuit(crossbeam_channel::Sender<bool>),
    ProcessMeeting {
        meeting_id: Uuid,
        transcribe: bool,
        summarize: bool,
    },
    RegenerateDigest(NaiveDate),
    Ask {
        conversation_id: Uuid,
        question: String,
        scope: AskScope,
        retry_of: Option<Uuid>,
    },
    StopAnswer,
    DownloadModel(String),
    CancelDownload(String),
    DeleteModel(String),
    PrepareModels,
    SetDayMemoryPaused(bool),
    WriteProjectNote(String),
    ProjectOpened(String),
    WriteFollowUp(Uuid),
    UpdateSettings(Box<Settings>),
    Dictation(DictationCommand),
    Selection(SelectionCommand),
    Autocomplete(AutocompleteCommand),
    LivePreview(LivePreviewCommand),
    CaptureScreenNow,
    RecordCalendarEvent(Box<lokalbot_core::calendar::CalendarEvent>),
    SetCalendarLinks(Vec<String>),
    RefreshCalendar,
    RunRoutine(lokalbot_core::settings::MemoryRoutineKind),
    RunRetentionNow,
    RestartMemoryCapture,
    Speech(SpeechCommand),
    CheckModels(Vec<ModelRole>),
    CancelModelChecks,
    CheckConnection(lokalbot_core::settings::SummarizerBackend),
    Companion(crate::companion::CompanionCommand),
    PrepareMeeting {
        event: Box<lokalbot_core::calendar::CalendarEvent>,
        generate: bool,
    },
    StartDetectedRecording {
        title: String,
        app_name: String,
        calendar: Option<Box<lokalbot_core::calendar::CalendarEvent>>,
    },
    CallEnded,
    SplitForCalendarHandoff {
        title: String,
        app_name: String,
        calendar: Box<lokalbot_core::calendar::CalendarEvent>,
    },
    Shutdown,
}

#[derive(Clone, Debug, PartialEq)]
pub enum SpeechCommand {
    Read {
        key: String,
        text: String,
    },
    Stop,
    Export {
        text: String,
        path: std::path::PathBuf,
    },
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct SpeechStatus {
    pub reading: Option<String>,
    pub preparing: bool,
    pub exporting: bool,
    pub error: Option<(String, String)>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DictationCommand {
    Start,
    Stop,
    Toggle,
    ToggleFromMenu,
    Cancel,
    CopyRecent(Option<Uuid>),
    ClearRecent,
    ToggleRehearsal,
    CopyNotice,
    DismissNotice,
    RetryPreparation,
    MicrophoneLost(u64),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SelectionCommand {
    Invoke,
    Run(lokalbot_ai::selection::Action),
    Retry,
    ChooseAgain,
    Copy,
    Insert,
    Dismiss,
    PanelClosed,
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

#[derive(Clone, Debug)]
#[allow(clippy::large_enum_variant)]
pub enum EngineEvent {
    Recording(RecordingUpdate),
    ScreenText(lokalbot_ai::ocr::OcrStatus),
    Processing {
        meeting_id: Uuid,
        stage: Option<Stage>,
    },
    LibraryChanged,
    Ask(AskUpdate),
    Files(crate::files::FileSearchStatus),
    AgentNotes(crate::agent_notes::AgentNotesStatus),
    Download(DownloadUpdate),
    Models(ModelStatus),
    Digest {
        running: Option<NaiveDate>,
    },
    ProjectNote {
        project_id: String,
        running: bool,
    },
    Background(Vec<BackgroundItem>),
    Message {
        text: String,
        is_error: bool,
    },
    MeetingDetected {
        app_name: String,
        title: String,
    },
    Dictation(DictationUpdate),
    Selection {
        view: crate::selection::SelectionView,
        open_panel: bool,
    },
    RecentDictations(Vec<lokalbot_core::dictation_history::Entry>),
    FollowUp(FollowUpUpdate),
    Autocomplete(AutocompleteUpdate),
    LivePreview(LivePreview),
    Screen(ScreenStatus),
    Calendar(crate::calendar::CalendarSnapshot),
    MeetingPreparation(MeetingPreparation),
    Routines(Box<crate::routines::RoutineStatus>),
    Dream(Box<crate::dreaming::DreamStatus>),
    Retention(RetentionStatus),
    Speech(SpeechStatus),
    ModelChecks(ModelCheckStatus),
    ConnectionCheck(ConnectionCheck),
    Companion(Box<crate::companion::CompanionSnapshot>),
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct RetentionStatus {
    pub last_run: Option<DateTime<Utc>>,
    pub last_error: Option<String>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ModelRole {
    Transcribe,
    Think,
    Autocomplete,
}

impl ModelRole {
    pub const ALL: [ModelRole; 3] = [Self::Transcribe, Self::Think, Self::Autocomplete];
}

#[derive(Clone, Debug, PartialEq)]
pub struct ModelCheckResult {
    pub role: ModelRole,
    pub checked_at: chrono::DateTime<chrono::Local>,
    pub elapsed_seconds: f64,
    pub failure: Option<String>,
    pub identity: Vec<String>,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct ModelCheckStatus {
    pub testing: Option<ModelRole>,
    pub running: bool,
    pub results: Vec<ModelCheckResult>,
}

impl ModelCheckStatus {
    pub fn result(&self, role: ModelRole) -> Option<&ModelCheckResult> {
        self.results.iter().find(|result| result.role == role)
    }
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct ConnectionCheck {
    pub running: bool,
    pub backend: Option<lokalbot_core::settings::SummarizerBackend>,
    pub reply: Option<String>,
    pub error: Option<String>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct MeetingPreparation {
    pub event_id: String,
    pub evidence: lokalbot_ai::upcoming::UpcomingEvidence,
    pub brief: Option<String>,
    pub generating: bool,
    pub error: Option<String>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LivePreviewCommand {
    Start { from_beginning: bool },
    Pause,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub enum LivePreviewState {
    #[default]
    Off,
    Running,
    Paused,
    Failed(String),
}

#[derive(Clone, Debug, PartialEq)]
pub struct LiveLine {
    pub time: f64,
    pub mine: bool,
    pub text: String,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct LivePreview {
    pub state: LivePreviewState,
    pub status: Option<String>,
    pub start: Option<f64>,
    pub working: bool,
    pub lines: Vec<LiveLine>,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct ScreenStatus {
    pub active: bool,
    pub capture_limitation: Option<String>,
    pub text_limitation: Option<String>,
    pub images_unavailable: Option<String>,
    pub ocr_installed: bool,
    pub last_capture: Option<DateTime<Utc>>,
    pub last_text_source: Option<String>,
    pub last_error: Option<String>,
    pub waiting_for_window: bool,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct FieldContext {
    pub field_id: u64,
    pub app_name: String,
    pub app_id: String,
    pub window_title: String,
    pub before: String,
    pub after: String,
    pub visible_text: Option<String>,
    pub url: Option<String>,
    pub single_line: bool,
    pub integrated_terminal: bool,
    pub field_frame: Option<lokalbot_platform::autocomplete::Rect>,
    pub pid: u32,
}

#[derive(Clone, Debug, PartialEq)]
pub enum AutocompleteCommand {
    Context(FieldContext),
    Accepted {
        field_id: u64,
        text: String,
        inserted: String,
    },
    Dismiss,
    LeftField,
    ClearUsage,
    ResetMeasures,
    ForgetLearned,
    RequestStatus,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct AutocompleteMeasures {
    pub stats: lokalbot_core::cotyping_stats::CotypingStats,
    pub usage: lokalbot_core::cotyping_stats::UsageHistory,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct AutocompleteLearning {
    pub problem: Option<String>,
    pub forgetting: bool,
    pub forgotten: Option<bool>,
}

#[derive(Clone, Debug, PartialEq)]
pub enum AutocompleteUpdate {
    Suggestion {
        field_id: u64,
        text: String,
        kind: lokalbot_ai::autocomplete::SuggestionKind,
        guard: Option<std::sync::Arc<lokalbot_ai::autocomplete::memory::MemoryGuard>>,
    },
    Clear,
    Measures(Box<AutocompleteMeasures>),
    Learning(AutocompleteLearning),
    MemoryUse {
        sources: Vec<String>,
        searched: bool,
    },
    ServerProblem(Option<lokalbot_ai::autocomplete::server::ServerProblem>),
    Rehearsal(AutocompleteRehearsal),
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct AutocompleteRehearsal {
    pub suppression: Option<lokalbot_ai::autocomplete::Suppression>,
    pub visible_text: bool,
    pub meeting_sources: Vec<String>,
    pub screen_sources: Vec<String>,
    pub searched_memory: bool,
}

#[derive(Clone, Debug)]
pub enum FollowUpUpdate {
    Writing {
        meeting_id: Uuid,
    },
    Written {
        meeting_id: Uuid,
        subject: String,
        body: String,
        model: String,
    },
    Failed {
        meeting_id: Uuid,
        message: String,
    },
}

#[derive(Clone, Debug)]
#[allow(clippy::large_enum_variant)]
pub enum RecordingUpdate {
    Started {
        meeting: Meeting,
        has_system_audio: bool,
    },
    Levels {
        mic: f32,
        system: f32,
        mic_status: String,
        system_status: String,
        elapsed_seconds: f64,
        last_recovery: Option<chrono::DateTime<chrono::Utc>>,
    },
    Stopped {
        meeting_id: Uuid,
        warnings: Vec<String>,
        saved: Option<RecordingSaved>,
    },
    CaptureWarnings {
        warnings: Vec<String>,
        notify: Vec<String>,
    },
    Failed {
        message: String,
    },
}

#[derive(Clone, Debug, PartialEq)]
pub struct RecordingSaved {
    pub title: String,
    pub duration_seconds: f64,
    pub will_transcribe: bool,
    pub waiting_for_models: bool,
}

impl RecordingSaved {
    pub fn body(&self) -> String {
        let arguments = [
            ("title", self.title.clone()),
            (
                "minutes",
                ((self.duration_seconds / 60.0) as u64).max(1).to_string(),
            ),
        ];
        let key = match (self.will_transcribe, self.waiting_for_models) {
            (true, _) => "{title} · {minutes} min · transcribing…",
            (false, true) => "{title} · {minutes} min · processes after models download",
            (false, false) => "{title} · {minutes} min",
        };
        lokalbot_i18n::format(key, &arguments)
    }
}

#[derive(Clone, Debug, PartialEq)]
pub enum Stage {
    Queued,
    WaitingForModels,
    PreparingModel(String),
    Transcribing,
    IdentifyingSpeakers,
    Summarizing,
    Failed(String),
}

#[derive(Clone, Debug)]
pub enum AskUpdate {
    Progress {
        conversation_id: Uuid,
        question: String,
        text: String,
        activity: Vec<String>,
        status: Option<String>,
    },
    Finished {
        conversation_id: Uuid,
    },
    Failed {
        conversation_id: Uuid,
        message: String,
    },
}

#[derive(Clone, Debug)]
pub struct DownloadUpdate {
    pub id: String,
    pub done_bytes: u64,
    pub total_bytes: u64,
    pub finished: bool,
    pub error: Option<String>,
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
    pub runtime_backend: Option<String>,
    pub runtime_needs_check: bool,
    pub runtime_storage: Vec<lokalbot_ai::runtime::RuntimeStorage>,
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
    pub id: String,
    pub kind: BackgroundKind,
    pub title: String,
    pub detail: String,
    pub progress: Option<f32>,
}

#[derive(Clone, Debug)]
pub enum DictationUpdate {
    Starting,
    Listening {
        level: f32,
        elapsed_seconds: f64,
        preview: String,
        microphone_live: bool,
        capture_status: String,
    },
    Transcribing,
    Preparing {
        progress: Option<f32>,
    },
    PreparationFailed {
        message: String,
    },
    Spoken {
        text: String,
    },
    Composing,
    Finished {
        text: String,
        inserted: bool,
        notice: Option<String>,
        spoken: String,
        engine: String,
        context: Option<String>,
    },
    DeliveryNotice {
        copied: bool,
    },
    Failed {
        message: String,
    },
    Cancelled,
}
