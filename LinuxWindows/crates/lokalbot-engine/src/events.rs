//! Requests the app sends to the engine and the updates it gets back.

use chrono::{DateTime, NaiveDate, Utc};
use lokalbot_core::{Meeting, Settings};
use uuid::Uuid;

#[derive(Clone, Debug)]
pub enum Command {
    /// The overnight review, now, for the previous day.
    ReviewNow,
    /// Delete every overnight review and the work memory.
    ClearWorkMemory,
    /// A name was given or applied: remember the voice and suggest it elsewhere.
    LearnSpeakerVoices,
    StartRecording {
        title: Option<String>,
        app_name: Option<String>,
    },
    StopRecording,
    /// Quitting soon: stop any recording and save it, leaving its processing
    /// for the next launch. Answers false when something could not be saved,
    /// and then the app stays open so the person can fix it and quit again.
    PrepareForQuit(crossbeam_channel::Sender<bool>),
    /// Retry or redo processing. User-initiated jobs may download missing models.
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
        /// The failed turn this asks again; it and its question are replaced.
        retry_of: Option<Uuid>,
    },
    StopAnswer,
    DownloadModel(String),
    CancelDownload(String),
    DeleteModel(String),
    /// Downloads every model the current settings need.
    PrepareModels,
    SetDayMemoryPaused(bool),
    WriteProjectNote(String),
    /// A tracked project's page opened: write or refresh its note if it is due
    /// and the Think model may run unattended.
    ProjectOpened(String),
    /// Writes a meeting's follow-up with the local Think model. Nothing is
    /// sent or saved; the draft comes back for review.
    WriteFollowUp(Uuid),
    UpdateSettings(Box<Settings>),
    Dictation(DictationCommand),
    /// Selection actions: the shortcut and the panel's controls.
    Selection(SelectionCommand),
    Autocomplete(AutocompleteCommand),
    LivePreview(LivePreviewCommand),
    /// "Capture Screen Now": capture the window in front, or the next one
    /// to come to the front within a few seconds when LokalBot itself is.
    CaptureScreenNow,
    /// Today's Record on a calendar event: record now, stamped with it.
    RecordCalendarEvent(Box<lokalbot_core::calendar::CalendarEvent>),
    /// Saves the private calendar links in the credential store (replacing
    /// the saved ones) and reads them.
    SetCalendarLinks(Vec<String>),
    /// Reads every calendar again now.
    RefreshCalendar,
    /// "Run now" for a routine that isn't tied to a meeting.
    RunRoutine(lokalbot_core::settings::MemoryRoutineKind),
    /// "Run retention now": applies the current policy.
    RunRetentionNow,
    /// Stops activity and screen capture and starts them afresh, for a desktop
    /// that came back changed (`restartMemoryCapture`).
    RestartMemoryCapture,
    Speech(SpeechCommand),
    /// Checks each role's model with sample content, in order.
    CheckModels(Vec<ModelRole>),
    CancelModelChecks,
    /// Sends the connection check's sample prompt to one Think server.
    CheckConnection(lokalbot_core::settings::SummarizerBackend),
    /// Paired phones and tablets: pairing and removing devices.
    Companion(crate::companion::CompanionCommand),
    /// Gathers what LokalBot knows for an upcoming meeting; with `generate`,
    /// also writes the brief with the on-device Think model.
    PrepareMeeting {
        event: Box<lokalbot_core::calendar::CalendarEvent>,
        generate: bool,
    },
    /// The detector found a call to record (automatic mode). Unlike
    /// `StartRecording`, it is suppressed for an event the user just stopped.
    StartDetectedRecording {
        title: String,
        app_name: String,
        calendar: Option<Box<lokalbot_core::calendar::CalendarEvent>>,
    },
    /// The call the detector started recording ended on its own.
    CallEnded,
    /// The next calendar event began within the call the detector is
    /// recording: stop this recording and start one for the next event.
    SplitForCalendarHandoff {
        title: String,
        app_name: String,
        calendar: Box<lokalbot_core::calendar::CalendarEvent>,
    },
    Shutdown,
}

/// Read aloud. Voice and speed come from the settings.
#[derive(Clone, Debug, PartialEq)]
pub enum SpeechCommand {
    /// Reads `text` aloud, stopping whatever is being read. `key` names what
    /// it is, so the interface can offer Stop in the right place.
    Read {
        key: String,
        text: String,
    },
    Stop,
    /// Saves the spoken `text` as a WAV file.
    Export {
        text: String,
        path: std::path::PathBuf,
    },
}

/// What Read aloud is doing.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct SpeechStatus {
    /// The key of what is being read, if anything.
    pub reading: Option<String>,
    /// Still downloading or synthesizing; no sound yet.
    pub preparing: bool,
    /// A spoken summary is being written to a file.
    pub exporting: bool,
    /// The last failure and the key it belongs to (`SPEECH_EXPORT_KEY` for an export).
    pub error: Option<(String, String)>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DictationCommand {
    Start,
    Stop,
    /// The shortcut: never cancels speech already being prepared.
    Toggle,
    /// The menu, the palette and other on-screen controls: their Cancel row
    /// does cancel while the text is being prepared (`toggleAction`).
    ToggleFromMenu,
    Cancel,
    /// Puts a recent dictation, the newest by default, on the clipboard.
    CopyRecent(Option<Uuid>),
    /// Forgets the recent dictations and deletes their file.
    ClearRecent,
    /// "Try here": starts or finishes a dictation that only shows its result.
    ToggleRehearsal,
    /// Copies the text a field did not show after a paste.
    CopyNotice,
    DismissNotice,
    /// Tries the speech model again, keeping the audio.
    RetryPreparation,
    /// From the engine itself: the microphone of the dictation with this
    /// number stopped and could not be reopened.
    MicrophoneLost(u64),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SelectionCommand {
    /// The shortcut was pressed: read the selection, then open the panel.
    Invoke,
    Run(lokalbot_ai::selection::Action),
    Retry,
    /// Back to the list of actions, keeping the selection.
    ChooseAgain,
    /// Copy the result and return to the app.
    Copy,
    /// Replace the selection with the result, or insert it at the cursor.
    Insert,
    /// Close without using a result and return to the app.
    Dismiss,
    /// The panel closed: stop generating and forget the selection.
    PanelClosed,
}

/// Sources and date range for a question in Ask.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct AskScope {
    pub meeting_ids: Vec<Uuid>,
    pub include_meetings: bool,
    pub include_activity: bool,
    pub include_screen: bool,
    /// The folders chosen under Files. Only takes effect while Files is on.
    pub include_files: bool,
    /// Notes the person's coding agents saved. Only takes effect while Read
    /// coding agent notes is on.
    pub include_agent_notes: bool,
    /// Screens this question is bound to: the moments among asked-about results,
    /// or the ones attached.
    pub screen_ids: Vec<i64>,
    /// `screen_ids` were attached by the person: they are read as primary evidence.
    pub attached_screens: bool,
    /// Limit screen search to one app.
    pub screen_app: Option<String>,
    pub since: Option<DateTime<Utc>>,
    pub until: Option<DateTime<Utc>>,
    /// The boundary saved with the question's turns.
    pub saved: lokalbot_core::QuestionScope,
}

#[derive(Clone, Debug)]
#[allow(clippy::large_enum_variant)]
pub enum EngineEvent {
    Recording(RecordingUpdate),
    /// What screen text recognition can do changed: something was installed or
    /// removed outside the app's own downloads.
    ScreenText(lokalbot_ai::ocr::OcrStatus),
    /// `None` when the meeting is no longer being processed.
    Processing {
        meeting_id: Uuid,
        stage: Option<Stage>,
    },
    /// Files in the library changed; reload lists.
    LibraryChanged,
    Ask(AskUpdate),
    /// What Files is doing now.
    Files(crate::files::FileSearchStatus),
    /// How many coding-agent notes are saved, or why none could be.
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
    /// A meeting app started a call while recording mode is "Ask via notification".
    MeetingDetected {
        app_name: String,
        title: String,
    },
    Dictation(DictationUpdate),
    /// Selection actions' state, whole. `open_panel` asks for the panel.
    Selection {
        view: crate::selection::SelectionView,
        open_panel: bool,
    },
    /// The recent dictations, newest first, after each change.
    RecentDictations(Vec<lokalbot_core::dictation_history::Entry>),
    FollowUp(FollowUpUpdate),
    Autocomplete(AutocompleteUpdate),
    /// The whole live transcript preview, sent on every change.
    LivePreview(LivePreview),
    Screen(ScreenStatus),
    /// The cached calendar after a refresh.
    Calendar(crate::calendar::CalendarSnapshot),
    /// Preparation for an upcoming meeting (`UpcomingMeetingPreparationModel`).
    MeetingPreparation(MeetingPreparation),
    /// What Settings shows about routines, after each change.
    Routines(Box<crate::routines::RoutineStatus>),
    /// What Settings and Today show about the overnight review.
    Dream(Box<crate::dreaming::DreamStatus>),
    /// The last retention pass.
    Retention(RetentionStatus),
    Speech(SpeechStatus),
    ModelChecks(ModelCheckStatus),
    ConnectionCheck(ConnectionCheck),
    /// What Settings shows about paired devices, after each change.
    Companion(Box<crate::companion::CompanionSnapshot>),
}

/// When retention last ran and what it couldn't clean up.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct RetentionStatus {
    pub last_run: Option<DateTime<Utc>>,
    pub last_error: Option<String>,
}

/// A role with a model to check (`ModelRole`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ModelRole {
    Transcribe,
    Think,
    Autocomplete,
}

impl ModelRole {
    pub const ALL: [ModelRole; 3] = [Self::Transcribe, Self::Think, Self::Autocomplete];
}

/// One finished check (`ModelCheckResult`).
#[derive(Clone, Debug, PartialEq)]
pub struct ModelCheckResult {
    pub role: ModelRole,
    pub checked_at: chrono::DateTime<chrono::Local>,
    pub elapsed_seconds: f64,
    pub failure: Option<String>,
    /// The configuration it exercised; a result lasts as long as this does.
    pub identity: Vec<String>,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct ModelCheckStatus {
    pub testing: Option<ModelRole>,
    /// More roles may follow `testing`.
    pub running: bool,
    pub results: Vec<ModelCheckResult>,
}

impl ModelCheckStatus {
    pub fn result(&self, role: ModelRole) -> Option<&ModelCheckResult> {
        self.results.iter().find(|result| result.role == role)
    }
}

/// The last "Check connection".
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ConnectionCheck {
    pub running: bool,
    pub backend: Option<lokalbot_core::settings::SummarizerBackend>,
    pub reply: Option<String>,
    pub error: Option<String>,
}

/// What Today shows under the next meeting. The brief stays in memory only.
#[derive(Clone, Debug, PartialEq)]
pub struct MeetingPreparation {
    pub event_id: String,
    pub evidence: lokalbot_ai::upcoming::UpcomingEvidence,
    /// The model's brief, when one was written for this evidence.
    pub brief: Option<String>,
    pub generating: bool,
    pub error: Option<String>,
}

/// The opt-in live transcript preview while recording (`LiveMeetingTranscriber`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LivePreviewCommand {
    /// Start, resume or retry. The start position applies to the first start only.
    Start {
        from_beginning: bool,
    },
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
    /// Seconds from the start of the recording.
    pub time: f64,
    /// From the microphone ("Me") rather than system audio.
    pub mine: bool,
    pub text: String,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct LivePreview {
    pub state: LivePreviewState,
    /// "Preparing the transcription model…", "Retrying live preview… (1/3)".
    pub status: Option<String>,
    /// Where the preview starts, in seconds from the start of the recording.
    pub start: Option<f64>,
    /// A chunk is being transcribed.
    pub working: bool,
    pub lines: Vec<LiveLine>,
}

/// Screen context capture as Settings shows it (`ScreenshotService`'s
/// published state and `MemoryHealthSection`).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ScreenStatus {
    /// Text and images are being captured (screen context on, tracking on,
    /// day memory not paused).
    pub active: bool,
    /// Why this desktop cannot capture window pixels (and so cannot OCR), if so.
    pub capture_limitation: Option<String>,
    /// Why visible text cannot be read through accessibility, if so.
    pub text_limitation: Option<String>,
    /// Why images cannot be kept (no system credential store), if so.
    pub images_unavailable: Option<String>,
    pub ocr_installed: bool,
    pub last_capture: Option<DateTime<Utc>>,
    /// `accessibility`, `ocr`, `hybrid` (with `_redacted`) of the last capture.
    pub last_text_source: Option<String>,
    pub last_error: Option<String>,
    /// "Capture Screen Now" is waiting for another window to come to the front.
    pub waiting_for_window: bool,
}

/// The text field the user is typing in, as the desktop integration reads
/// it (`CotypingSurfaceContext`). Sent on edits and caret moves while
/// autocomplete is on; never for secure fields or excluded apps.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct FieldContext {
    /// Changes when focus moves to another field; updates for an old id are stale.
    pub field_id: u64,
    pub app_name: String,
    /// Executable or desktop id: "firefox", "code.exe".
    pub app_id: String,
    pub window_title: String,
    /// Text before the caret (bounded by the reader).
    pub before: String,
    /// Text after the caret in the same paragraph.
    pub after: String,
    /// Text visible above the field, such as the conversation being answered.
    pub visible_text: Option<String>,
    /// The page address when the app is a browser and it could be read.
    pub url: Option<String>,
    /// Inputs where Enter sends (search boxes, chat inputs).
    pub single_line: bool,
    /// An xterm.js surface in an editor or a browser.
    pub integrated_terminal: bool,
    /// The field on screen, in pixels, when known.
    pub field_frame: Option<lokalbot_platform::autocomplete::Rect>,
    pub pid: u32,
}

#[derive(Clone, Debug, PartialEq)]
pub enum AutocompleteCommand {
    /// The field changed: typing, a caret move, or new focus.
    Context(FieldContext),
    /// The user accepted `text`, the start of the shown suggestion, and
    /// `inserted` was typed for it.
    Accepted {
        field_id: u64,
        text: String,
        inserted: String,
    },
    /// Escape or a secure field: drop any suggestion.
    Dismiss,
    /// Focus left every field the suggestion could belong to: its context
    /// goes too.
    LeftField,
    /// Clear statistics: the daily and monthly counts.
    ClearUsage,
    /// Reset under Usage and timing: the counters.
    ResetMeasures,
    /// "Forget learned text".
    ForgetLearned,
    /// Settings opened: send the current counters and state.
    RequestStatus,
}

/// Counters for Settings → Writing.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct AutocompleteMeasures {
    pub stats: lokalbot_core::cotyping_stats::CotypingStats,
    pub usage: lokalbot_core::cotyping_stats::UsageHistory,
}

/// The learned examples' state, for Settings → Writing.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct AutocompleteLearning {
    /// Why the store cannot be used, worded for Settings. Learning then stays
    /// in memory and nothing is written.
    pub problem: Option<String>,
    pub forgetting: bool,
    /// The last "Forget learned text" worked, or failed.
    pub forgotten: Option<bool>,
}

#[derive(Clone, Debug, PartialEq)]
pub enum AutocompleteUpdate {
    /// Ghost text to show after the caret of `field_id`.
    Suggestion {
        field_id: u64,
        text: String,
        kind: lokalbot_ai::autocomplete::SuggestionKind,
        /// The saved facts behind it, checked again before an accept.
        guard: Option<std::sync::Arc<lokalbot_ai::autocomplete::memory::MemoryGuard>>,
    },
    /// Hide any ghost text.
    Clear,
    Measures(Box<AutocompleteMeasures>),
    Learning(AutocompleteLearning),
    /// What the last suggestion's saved-memory lookup found.
    MemoryUse {
        sources: Vec<String>,
        searched: bool,
    },
    /// Why the selected server's last request brought no suggestion.
    ServerProblem(Option<lokalbot_ai::autocomplete::server::ServerProblem>),
    /// What the practice editor's last request drew on.
    Rehearsal(AutocompleteRehearsal),
}

/// A practice suggestion and the optional sources behind it (`CotypingPreview`,
/// `CotypingContextUse`).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct AutocompleteRehearsal {
    /// Why the model's answer became no suggestion.
    pub suppression: Option<lokalbot_ai::autocomplete::Suppression>,
    /// Nearby text was part of the prompt.
    pub visible_text: bool,
    /// Titles of the saved sources used, by the grant that admitted them.
    pub meeting_sources: Vec<String>,
    pub screen_sources: Vec<String>,
    /// A saved-memory lookup ran, whether or not it found anything.
    pub searched_memory: bool,
}

/// Progress of one follow-up written with Think (`FollowUpDraftSheet`).
#[derive(Clone, Debug)]
pub enum FollowUpUpdate {
    Writing {
        meeting_id: Uuid,
    },
    Written {
        meeting_id: Uuid,
        subject: String,
        body: String,
        /// "Qwen3.5 4B" for "Written on this PC by …".
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
        /// When a lost track last came back during this recording.
        last_recovery: Option<chrono::DateTime<chrono::Utc>>,
    },
    Stopped {
        meeting_id: Uuid,
        warnings: Vec<String>,
        /// The "Recording saved" notification. Absent on quit, as on macOS.
        saved: Option<RecordingSaved>,
    },
    /// The warnings to show now, and any that also deserve a notification.
    CaptureWarnings {
        warnings: Vec<String>,
        notify: Vec<String>,
    },
    Failed {
        message: String,
    },
}

/// What the "Recording saved" notification says (`recordingStopped`).
#[derive(Clone, Debug, PartialEq)]
pub struct RecordingSaved {
    pub title: String,
    pub duration_seconds: f64,
    pub will_transcribe: bool,
    pub waiting_for_models: bool,
}

impl RecordingSaved {
    /// "Standup · 12 min · transcribing…"
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
    /// Some screen text recognition engine can read now.
    pub screen_text_ready: bool,
    /// Which one, in which languages, and what download would help.
    pub screen_text: lokalbot_ai::ocr::OcrStatus,
    pub runtime_backend: Option<String>,
    /// CUDA is downloaded, but its setup GPU check has not passed.
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
        /// The rolling transcript so far.
        preview: String,
        /// The microphone has delivered audio.
        microphone_live: bool,
        /// What is wrong with a running microphone, worded for the overlay.
        capture_status: String,
    },
    Transcribing,
    /// The speech model is taking a moment to load, or downloading while the
    /// recording goes on. `progress` is how far a download is, 0–1.
    Preparing {
        progress: Option<f32>,
    },
    /// The speech model did not load; the audio waits for Retry.
    PreparationFailed {
        message: String,
    },
    /// The final transcript, while Compose works on it.
    Spoken {
        text: String,
    },
    Composing,
    /// `inserted` is false when the text went to the clipboard instead.
    Finished {
        text: String,
        inserted: bool,
        notice: Option<String>,
        /// What was said, when Compose wrote something else from it.
        spoken: String,
        /// "Parakeet v3 → Qwen3.5 4B · on this PC".
        engine: String,
        /// What Compose read for this request.
        context: Option<String>,
    },
    /// Pasted text the field did not show afterwards.
    DeliveryNotice {
        copied: bool,
    },
    Failed {
        message: String,
    },
    Cancelled,
}
