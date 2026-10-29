//! One Agent Mode task (`AgentSessionController.swift`): starts pi through a
//! [`Launcher`], folds its events into the transcript, round-trips tool
//! approvals between pi's confirm dialogs and the UI, and keeps the host
//! queue of follow-ups.
//!
//! The macOS controller is a main-actor object whose `await`s let other
//! events through. Here it is a plain state machine owned by the UI thread:
//! every slow step (model warm-up, spawning, an RPC acknowledgement, a
//! process stop) runs elsewhere and comes back as a [`SessionInput`] through
//! the task's inbox, tagged with the lifecycle generation it belongs to, so a
//! stale completion can never revive a closed or restarted task.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use parking_lot::RwLock;
use uuid::Uuid;

use lokalbot_ai::plans::chatgpt::relay::Relay;
use lokalbot_core::settings::{ReasoningLevel, SubscriptionPlan};
use lokalbot_core::{Library, Settings};

use crate::archive;
use crate::context::{self, ContextResolver, MAX_ATTACHMENTS};
use crate::endpoint::{LlmEndpoint, ModelContext};
use crate::history::{self, SavedSession};
use crate::launch::SessionChoice;
use crate::layout::{AgentDirectories, RuntimeLayout};
use crate::messages::{PiCommand, PiEvent, PiResponse, PiUiRequest};
use crate::policy::{
    self, ApprovalMode, ApprovalPolicy, ApprovalScope, PRIVATE_WORKSPACE_NOTICE, Verdict,
    WorkspacePolicy,
};
use crate::process::PiProcess;
use crate::rpc::{ClientMessage, RpcClient, RpcError, Sink};
use crate::tasks::{Attachment, QueuedPrompt};
use crate::transcript::{ApprovalRequest, Edit, TranscriptFolder, TranscriptItem};

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SessionState {
    Idle,
    Starting,
    Ready,
    Running,
    Failed(String),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RecoveryAction {
    OpenModels,
    Restart,
}

#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub enum LaunchMode {
    #[default]
    Fresh,
    ContinueRecent,
    Saved(SavedSession),
}

impl LaunchMode {
    fn choice(&self) -> SessionChoice {
        match self {
            LaunchMode::Fresh => SessionChoice::Fresh,
            LaunchMode::ContinueRecent => SessionChoice::ContinueRecent,
            LaunchMode::Saved(session) => SessionChoice::Saved(session.file.clone()),
        }
    }
}

/// What an acknowledgement belongs to.
#[derive(Clone, Debug)]
pub enum RequestTag {
    Prompt {
        pending: QueuedPrompt,
        was_running: bool,
        from_queue: bool,
    },
    Abort,
    SessionFile,
    History {
        notice: String,
    },
}

/// Why a launch failed. Configuration problems send the user to Models.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum LaunchError {
    Configuration(String),
    Other(String),
}

impl LaunchError {
    pub fn message(&self) -> &str {
        match self {
            LaunchError::Configuration(message) | LaunchError::Other(message) => message,
        }
    }
}

/// A started pi, handed back by the launcher.
pub struct Launched {
    pub client: RpcClient<RequestTag>,
    pub process: Option<Arc<PiProcess>>,
    pub lease: Option<lokalbot_ai::Lease>,
    /// The ChatGPT plan relay pi talks to; it stops when dropped.
    pub relay: Option<Relay>,
    /// The scoped `lokalbot-cli` grant to revoke when the task stops.
    pub capability: Option<String>,
    pub endpoint: LlmEndpoint,
    /// Real pi reports its session file; test transports do not.
    pub reports_session_file: bool,
}

/// Everything a launch needs from the task.
#[derive(Clone, Debug)]
pub struct LaunchRequest {
    pub settings: Settings,
    pub workspace: PathBuf,
    pub session: SessionChoice,
    pub reasoning_level_file: PathBuf,
    pub private_roots: Vec<PathBuf>,
}

/// Starts pi off the UI thread. `done` runs exactly once.
pub trait Launcher: Send + Sync {
    fn launch(
        &self,
        request: LaunchRequest,
        sink: Sink<RequestTag>,
        done: Box<dyn FnOnce(Result<Launched, LaunchError>) + Send>,
    );
}

/// Completions and pi traffic for one task.
pub enum SessionInput {
    Client(ClientMessage<RequestTag>),
    Launched(Result<Launched, LaunchError>),
    /// A shutdown's process stop finished.
    Stopped,
    /// A failure's process stop finished.
    FailureTornDown {
        message: String,
        recovery: RecoveryAction,
    },
    Preview {
        session: SavedSession,
        result: Result<archive::Preview, archive::ArchiveError>,
    },
}

/// A [`SessionInput`] addressed to one task.
pub struct TaskInput {
    pub task: Uuid,
    pub generation: u64,
    pub input: SessionInput,
}

pub type Inbox = async_channel::Sender<TaskInput>;

/// What every task shares.
pub struct AgentEnvironment {
    pub library: Library,
    pub dirs: AgentDirectories,
    pub layout: RuntimeLayout,
    pub settings: Arc<RwLock<Settings>>,
    pub launcher: Arc<dyn Launcher>,
}

impl AgentEnvironment {
    pub fn settings(&self) -> Settings {
        self.settings.read().clone()
    }

    /// The library, its agent folders and the runtime: never an implicit
    /// working folder, and file-tool changes to them always ask.
    pub fn private_roots(&self) -> Vec<PathBuf> {
        vec![
            self.dirs.library_root().to_path_buf(),
            self.dirs.sessions(),
            self.layout.root().to_path_buf(),
        ]
    }
}

/// The reasoning levels the launched model accepts.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ReasoningChoices {
    pub levels: Vec<ReasoningLevel>,
    pub default_level: Option<ReasoningLevel>,
}

impl ReasoningChoices {
    pub fn for_settings(settings: &Settings) -> Self {
        let (levels, default_level) = lokalbot_ai::think::reasoning_choices(settings);
        Self {
            levels,
            default_level,
        }
    }

    pub fn is_adjustable(&self) -> bool {
        !self.levels.is_empty()
    }

    /// The supported level nearest below `level`, else the lowest one.
    pub fn clamp(&self, level: ReasoningLevel) -> Option<ReasoningLevel> {
        if level == ReasoningLevel::Automatic || self.levels.is_empty() {
            return None;
        }
        let rank = level_rank;
        self.levels
            .iter()
            .copied()
            .rfind(|candidate| rank(*candidate) <= rank(level))
            .or(self.levels.first().copied())
    }

    pub fn displayed(&self, level: ReasoningLevel) -> ReasoningLevel {
        self.clamp(level).unwrap_or(ReasoningLevel::Automatic)
    }

    pub fn automatic_title(&self) -> String {
        match self.default_level {
            Some(level) => format!("Automatic ({})", reasoning_name(level)),
            None => "Automatic".into(),
        }
    }
}

fn level_rank(level: ReasoningLevel) -> u8 {
    match level {
        ReasoningLevel::Automatic => 0,
        ReasoningLevel::Off => 1,
        ReasoningLevel::Minimal => 2,
        ReasoningLevel::Low => 3,
        ReasoningLevel::Medium => 4,
        ReasoningLevel::High => 5,
        ReasoningLevel::Xhigh => 6,
        ReasoningLevel::Max => 7,
    }
}

pub fn reasoning_name(level: ReasoningLevel) -> &'static str {
    match level {
        ReasoningLevel::Automatic => "Automatic",
        ReasoningLevel::Off => "Off",
        ReasoningLevel::Minimal => "Minimal",
        ReasoningLevel::Low => "Low",
        ReasoningLevel::Medium => "Medium",
        ReasoningLevel::High => "High",
        ReasoningLevel::Xhigh => "Extra high",
        ReasoningLevel::Max => "Max",
    }
}

fn reasoning_key(level: ReasoningLevel) -> &'static str {
    match level {
        ReasoningLevel::Automatic => "automatic",
        ReasoningLevel::Off => "off",
        ReasoningLevel::Minimal => "minimal",
        ReasoningLevel::Low => "low",
        ReasoningLevel::Medium => "medium",
        ReasoningLevel::High => "high",
        ReasoningLevel::Xhigh => "xhigh",
        ReasoningLevel::Max => "max",
    }
}

/// One task.
pub struct AgentSession {
    env: Arc<AgentEnvironment>,
    task: Uuid,
    inbox: Inbox,

    pub state: SessionState,
    pub recovery_action: Option<RecoveryAction>,
    pub session_title: Option<String>,
    pub active_session_file: Option<PathBuf>,
    /// Bound to the launched connection, even if Settings change later.
    pub model_context: Option<ModelContext>,
    /// The levels the launched model accepts; `None` until a launch.
    pub reasoning_choices: Option<ReasoningChoices>,
    pub workspace: PathBuf,
    pub draft: String,
    pub attachments: Vec<Attachment>,
    pub source_attachments: Vec<Attachment>,
    pub message_attachments: HashMap<String, Vec<Attachment>>,
    pub queued_prompts: Vec<QueuedPrompt>,
    pub queue_is_paused: bool,
    pub turn_error: Option<String>,
    pub is_sending: bool,
    pub is_stopping: bool,
    pub failed_prompt: Option<QueuedPrompt>,
    pub composer_error: Option<String>,
    approval_mode: ApprovalMode,

    last_submitted_prompt: Option<QueuedPrompt>,
    connected_endpoint: Option<String>,
    connected_plan: Option<SubscriptionPlan>,
    policy: ApprovalPolicy,
    folder: TranscriptFolder,
    client: Option<RpcClient<RequestTag>>,
    process: Option<Arc<PiProcess>>,
    lease: Option<lokalbot_ai::Lease>,
    /// Runs from launch until shutdown or failure, like the lease.
    relay: Option<Relay>,
    capability: Option<String>,
    next_request_id: u64,
    launch_mode: LaunchMode,
    generation: u64,
    /// A failure's process stop is still running; `Failed` is published, and
    /// a restart allowed, only after it finishes.
    failure_teardown_in_progress: bool,
    /// Shutdown stops still running; a start waits for them so two pi
    /// processes never share one session file.
    stops_pending: usize,
    start_after_stop: bool,
    /// A message submitted before the runtime was ready.
    pending_submission: Option<PendingSubmission>,
    reasoning_level_file: PathBuf,
    written_reasoning_level: Option<ReasoningLevel>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct PendingSubmission {
    text: String,
    attachments: Vec<Attachment>,
    steer: bool,
}

impl AgentSession {
    pub fn new(env: Arc<AgentEnvironment>, task: Uuid, inbox: Inbox) -> Self {
        let approval_mode = policy::load_mode(&env.dirs.approval_mode_file());
        let protected = env.private_roots();
        let workspace = env.dirs.default_workspace();
        Self {
            task,
            inbox,
            state: SessionState::Idle,
            recovery_action: None,
            session_title: None,
            active_session_file: None,
            model_context: None,
            reasoning_choices: None,
            workspace,
            draft: String::new(),
            attachments: Vec::new(),
            source_attachments: Vec::new(),
            message_attachments: HashMap::new(),
            queued_prompts: Vec::new(),
            queue_is_paused: false,
            turn_error: None,
            is_sending: false,
            is_stopping: false,
            failed_prompt: None,
            composer_error: None,
            approval_mode,
            last_submitted_prompt: None,
            connected_endpoint: None,
            connected_plan: None,
            policy: ApprovalPolicy::new(approval_mode, protected),
            folder: TranscriptFolder::default(),
            client: None,
            process: None,
            lease: None,
            relay: None,
            capability: None,
            next_request_id: 0,
            launch_mode: LaunchMode::Fresh,
            generation: 0,
            failure_teardown_in_progress: false,
            stops_pending: 0,
            start_after_stop: false,
            pending_submission: None,
            reasoning_level_file: std::env::temp_dir()
                .join(format!("lokalbot-agent-reasoning-{}.json", Uuid::new_v4())),
            written_reasoning_level: None,
            env,
        }
    }

    // ------------------------------------------------------------ queries

    pub fn task(&self) -> Uuid {
        self.task
    }

    pub fn generation(&self) -> u64 {
        self.generation
    }

    pub fn items(&self) -> &[TranscriptItem] {
        self.folder.items()
    }

    pub fn pending_approvals(&self) -> Vec<&ApprovalRequest> {
        self.folder.pending_approvals()
    }

    pub fn approval_mode(&self) -> ApprovalMode {
        self.approval_mode
    }

    pub fn has_live_runtime(&self) -> bool {
        matches!(
            self.state,
            SessionState::Starting | SessionState::Ready | SessionState::Running
        )
    }

    pub fn is_failed(&self) -> bool {
        matches!(self.state, SessionState::Failed(_))
    }

    pub fn is_waiting_to_send(&self) -> bool {
        self.pending_submission.is_some()
    }

    /// "Needs approval", "Working…", "Saved", …
    pub fn task_status(&self) -> &'static str {
        if !self.folder.pending_approval_ids().is_empty() {
            return "Needs approval";
        }
        if self.turn_error.is_some() {
            return "Needs attention";
        }
        match self.state {
            SessionState::Idle if self.folder.items().is_empty() => "Ready to start",
            SessionState::Idle => "Saved",
            SessionState::Starting => "Starting…",
            SessionState::Ready => "Ready",
            SessionState::Running => "Working…",
            SessionState::Failed(_) => "Needs attention",
        }
    }

    pub fn context_resolver(&self) -> ContextResolver {
        ContextResolver::new(self.env.library.clone())
    }

    pub fn sessions_directory(&self) -> PathBuf {
        self.env.dirs.sessions()
    }

    /// The model a new launch would use, or the launched one.
    pub fn presented_model(&self) -> ModelContext {
        self.model_context
            .clone()
            .unwrap_or_else(|| ModelContext::from_settings(&self.env.settings()))
    }

    pub fn workspace_display_name(&self) -> String {
        self.workspace_display_name_for(&self.workspace)
    }

    pub fn workspace_display_name_for(&self, workspace: &Path) -> String {
        if self
            .workspace_policy()
            .contains_private_workspace(workspace)
        {
            return "Private Library · read-only".into();
        }
        if policy::same_path(workspace, &self.env.dirs.default_workspace()) {
            return "Agent Workspace".into();
        }
        workspace
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_else(|| workspace.display().to_string())
    }

    fn workspace_policy(&self) -> WorkspacePolicy {
        WorkspacePolicy {
            private_roots: self.env.private_roots(),
        }
    }

    pub fn workspace_access_notice(&self) -> Option<&'static str> {
        self.workspace_access_notice_for(&self.workspace)
    }

    pub fn workspace_access_notice_for(&self, proposed: &Path) -> Option<&'static str> {
        self.workspace_policy()
            .contains_private_workspace(proposed)
            .then_some(PRIVATE_WORKSPACE_NOTICE)
    }

    pub fn requires_close_confirmation(&self) -> bool {
        self.state == SessionState::Running
            || !self.draft.trim().is_empty()
            || !self.folder.items().is_empty()
    }

    pub fn can_replace_with_saved_session(&self) -> bool {
        self.state == SessionState::Idle
            && self.session_title.is_none()
            && self.draft.trim().is_empty()
            && self.attachments.is_empty()
            && self.queued_prompts.is_empty()
            && self.folder.items().is_empty()
    }

    pub fn can_resume_previous_session(&self) -> bool {
        self.workspace_access_notice().is_none()
            && has_resumable_session(&self.env.dirs.sessions(), &self.workspace)
    }

    pub fn can_allow_for_session(&self, request: &ApprovalRequest) -> bool {
        request.can_approve()
            && ApprovalPolicy::can_persist_approval(
                &request.tool,
                request.path.as_deref(),
                request.workspace.as_deref(),
                &self.workspace,
                &self.policy.protected_write_roots,
            )
    }

    // ---------------------------------------------------------- lifecycle

    /// Prepares the working folder and asks the launcher for pi.
    pub fn start(&mut self) {
        if self.stops_pending > 0 {
            self.start_after_stop = true;
            return;
        }
        if self.failure_teardown_in_progress
            || !(self.state == SessionState::Idle || self.is_failed())
        {
            return;
        }
        if let Err(message) = self.prepare_workspace() {
            self.composer_error = Some(message);
            self.restore_pending_submission();
            return;
        }
        let settings = self.env.settings();
        self.model_context = Some(ModelContext::from_settings(&settings));
        self.generation += 1;
        let generation = self.generation;
        self.state = SessionState::Starting;
        self.recovery_action = None;
        self.reasoning_choices = Some(ReasoningChoices::for_settings(&settings));
        self.written_reasoning_level = None;
        self.write_reasoning_level();
        let request = LaunchRequest {
            settings,
            workspace: self.workspace.clone(),
            session: self.launch_mode.choice(),
            reasoning_level_file: self.reasoning_level_file.clone(),
            private_roots: self.env.private_roots(),
        };
        let inbox = self.inbox.clone();
        let task = self.task;
        self.env.launcher.launch(
            request,
            self.client_sink(generation),
            Box::new(move |result| {
                let _ = inbox.send_blocking(TaskInput {
                    task,
                    generation,
                    input: SessionInput::Launched(result),
                });
            }),
        );
    }

    /// pi traffic for this generation. Text deltas are the only messages
    /// dropped when the inbox is full; anything else waits, and pi honors the
    /// backpressure on its stdout.
    fn client_sink(&self, generation: u64) -> Sink<RequestTag> {
        let inbox = self.inbox.clone();
        let task = self.task;
        Arc::new(move |message: ClientMessage<RequestTag>| {
            let lossy =
                matches!(&message, ClientMessage::Event(event) if event.is_lossy_text_delta());
            let input = TaskInput {
                task,
                generation,
                input: SessionInput::Client(message),
            };
            match inbox.try_send(input) {
                Ok(()) => {}
                Err(async_channel::TrySendError::Full(input)) => {
                    if !lossy {
                        let _ = inbox.send_blocking(input);
                    }
                }
                Err(async_channel::TrySendError::Closed(_)) => {}
            }
        })
    }

    /// Stops this task's pi and returns to idle. The process stop finishes in
    /// the background; a later start waits for it.
    pub fn shutdown(&mut self) {
        self.generation += 1;
        self.queue_is_paused = true;
        self.is_sending = false;
        self.is_stopping = false;
        self.pending_submission = None;
        self.cancel_pending_approvals();
        // Revoke library access before the stop's grace period.
        self.revoke_capability();
        self.client = None;
        if let Some(process) = self.process.take() {
            self.stops_pending += 1;
            let inbox = self.inbox.clone();
            let task = self.task;
            let generation = self.generation;
            let spawned = std::thread::Builder::new()
                .name("lokalbot-pi-stop".into())
                .spawn(move || {
                    process.stop(crate::process::STOP_GRACE);
                    let _ = inbox.send_blocking(TaskInput {
                        task,
                        generation,
                        input: SessionInput::Stopped,
                    });
                });
            if spawned.is_err() {
                self.stops_pending -= 1;
            }
        }
        self.active_session_file = None;
        self.model_context = None;
        self.reset_approval_policy();
        self.release_model_connection();
        let _ = std::fs::remove_file(&self.reasoning_level_file);
        self.written_reasoning_level = None;
        self.reasoning_choices = None;
        self.state = SessionState::Idle;
    }

    /// App quit: asks pi to stop without waiting. The caller then waits once
    /// for every task and kills what is left.
    pub fn begin_quit(&mut self) -> Option<Arc<PiProcess>> {
        self.generation += 1;
        self.cancel_pending_approvals();
        self.revoke_capability();
        self.client = None;
        self.release_model_connection();
        let _ = std::fs::remove_file(&self.reasoning_level_file);
        let process = self.process.take();
        if let Some(process) = &process {
            process.begin_stop();
        }
        self.state = SessionState::Idle;
        process
    }

    /// Pauses an idle runtime without losing the saved task, draft or preview.
    pub fn park(&mut self) -> bool {
        if matches!(self.state, SessionState::Running | SessionState::Starting) || self.is_sending {
            return false;
        }
        let saved = self
            .active_session_file
            .as_deref()
            .and_then(|file| history::load_file(file, &self.env.dirs.sessions()));
        if self.has_live_runtime() && !self.folder.items().is_empty() && saved.is_none() {
            return false;
        }
        self.shutdown();
        if let Some(saved) = saved {
            self.active_session_file = Some(saved.file.clone());
            self.launch_mode = LaunchMode::Saved(saved);
        }
        true
    }

    /// Shows a saved conversation without starting anything (read off the UI thread).
    pub fn load_saved_preview(&mut self, session: SavedSession) {
        if self.has_live_runtime() {
            return;
        }
        let inbox = self.inbox.clone();
        let task = self.task;
        let generation = self.generation;
        let directory = self.env.dirs.sessions();
        let _ = std::thread::Builder::new()
            .name("lokalbot-agent-preview".into())
            .spawn(move || {
                let result = archive::preview(&session, &directory);
                let _ = inbox.send_blocking(TaskInput {
                    task,
                    generation,
                    input: SessionInput::Preview { session, result },
                });
            });
    }

    /// Applies a preview read on this thread (start needs it immediately).
    pub fn load_saved_preview_now(&mut self, session: &SavedSession) -> Result<(), String> {
        let preview =
            archive::preview(session, &self.env.dirs.sessions()).map_err(|e| e.to_string())?;
        self.apply_preview(session.clone(), preview);
        Ok(())
    }

    fn apply_preview(&mut self, session: SavedSession, preview: archive::Preview) {
        self.folder = preview.folder;
        self.message_attachments = preview.attachments;
        let sources: Vec<Attachment> = self
            .message_attachments
            .values()
            .flatten()
            .cloned()
            .collect();
        for source in sources {
            if !self.source_attachments.iter().any(|s| s.id == source.id) {
                self.source_attachments.push(source);
            }
        }
        self.workspace = session.workspace.clone();
        self.session_title = Some(session.title.clone());
        self.active_session_file = Some(session.file.clone());
        self.launch_mode = LaunchMode::Saved(session);
        self.publish();
    }

    pub fn resume_previous_session(&mut self) {
        if !self.can_resume_previous_session() {
            return;
        }
        self.shutdown();
        self.folder = TranscriptFolder::default();
        self.reset_approval_policy();
        self.session_title = None;
        self.draft.clear();
        self.launch_mode = LaunchMode::ContinueRecent;
        self.start();
    }

    pub fn resume_saved_session(&mut self, session: SavedSession) {
        self.shutdown();
        self.folder = TranscriptFolder::default();
        self.reset_approval_policy();
        self.workspace = session.workspace.clone();
        self.session_title = Some(session.title.clone());
        self.active_session_file = Some(session.file.clone());
        self.draft.clear();
        self.launch_mode = LaunchMode::Saved(session);
        self.start();
    }

    // ---------------------------------------------------------- prompting

    /// Composer submission: queues a follow-up while running, sends when
    /// ready, or starts the task and sends once it is ready.
    pub fn submit(&mut self, steer: bool) {
        let text = self.draft.trim().to_string();
        if text.is_empty() || self.is_stopping || self.state == SessionState::Starting {
            return;
        }
        if self.state == SessionState::Running && !steer {
            self.queue_draft();
            return;
        }
        let attachments = std::mem::take(&mut self.attachments);
        let original = std::mem::take(&mut self.draft);
        if matches!(self.state, SessionState::Ready | SessionState::Running) {
            if !self.send(&text, attachments.clone(), steer, false)
                && self.draft.is_empty()
                && self.attachments.is_empty()
            {
                self.draft = original;
                self.attachments = attachments;
            }
            return;
        }
        self.pending_submission = Some(PendingSubmission {
            text: original,
            attachments,
            steer,
        });
        self.start();
    }

    fn restore_pending_submission(&mut self) {
        if let Some(pending) = self.pending_submission.take()
            && self.draft.is_empty()
            && self.attachments.is_empty()
        {
            self.draft = pending.text;
            self.attachments = pending.attachments;
        }
    }

    fn deliver_pending_submission(&mut self) {
        let Some(pending) = self.pending_submission.take() else {
            return;
        };
        let text = pending.text.trim().to_string();
        if !self.send(&text, pending.attachments.clone(), pending.steer, false)
            && self.draft.is_empty()
            && self.attachments.is_empty()
        {
            self.draft = pending.text;
            self.attachments = pending.attachments;
        }
    }

    /// Sends one prompt. False when it could not be sent (nothing was sent).
    pub fn send(
        &mut self,
        prompt: &str,
        sources: Vec<Attachment>,
        steer: bool,
        from_queue: bool,
    ) -> bool {
        let Some(client) = self.client.clone() else {
            return false;
        };
        if self.is_sending
            || self.is_stopping
            || !matches!(self.state, SessionState::Ready | SessionState::Running)
        {
            return false;
        }
        let was_running = self.state == SessionState::Running;
        let pending = QueuedPrompt::new(prompt, sources.clone());
        if let Some(base) = &self.connected_endpoint {
            let settings = self.env.settings();
            if let Some(reason) = remote_block(base, &settings) {
                self.composer_error = Some(reason);
                return false;
            }
            // The relay's loopback URL passes the origin check; the plan has
            // its own approval.
            if let Some(plan) = self.connected_plan
                && !plan.is_approved(&settings)
            {
                self.composer_error = Some(plan.approval_required_message());
                return false;
            }
        }
        let wire_prompt = match self.context_resolver().prompt(prompt, &sources) {
            Ok(wire) => wire,
            Err(error) => {
                self.composer_error = Some(error.to_string());
                return false;
            }
        };
        self.is_sending = true;
        self.last_submitted_prompt = Some(pending.clone());
        self.composer_error = None;
        self.turn_error = None;
        self.queue_is_paused = false;
        if self.session_title.is_none() {
            self.session_title = Some(make_session_title(prompt));
        }
        self.folder.note_user_prompt(prompt);
        if let Some(item) = self.folder.items().last() {
            self.message_attachments
                .insert(item.id().to_string(), sources.clone());
        }
        self.publish();
        for source in sources {
            if !self.source_attachments.iter().any(|s| s.id == source.id) {
                self.source_attachments.push(source);
            }
        }
        self.state = SessionState::Running;
        self.write_reasoning_level();
        let command = if steer && was_running {
            PiCommand::Steer {
                id: self.fresh_id("steer"),
                message: wire_prompt,
            }
        } else {
            PiCommand::Prompt {
                id: self.fresh_id("p"),
                message: wire_prompt,
                streaming_behavior: was_running.then(|| "followUp".to_string()),
            }
        };
        client.request(
            command,
            RequestTag::Prompt {
                pending,
                was_running,
                from_queue,
            },
        );
        true
    }

    /// Follow-ups stay in the host queue until delivery, so cancelling and
    /// editing them are real operations.
    pub fn queue_draft(&mut self) {
        let text = self.draft.trim().to_string();
        if text.is_empty() || self.queued_prompts.len() >= 20 {
            self.composer_error = Some("Keep up to 20 follow-ups in the queue.".into());
            return;
        }
        let attachments = std::mem::take(&mut self.attachments);
        self.queued_prompts
            .push(QueuedPrompt::new(text, attachments));
        self.draft.clear();
        self.queue_is_paused =
            self.queue_is_paused || self.is_stopping || self.turn_error.is_some();
    }

    pub fn restore_sources(&mut self, sources: Vec<Attachment>) {
        self.source_attachments = sources;
    }

    pub fn restore_queue(&mut self, prompts: Vec<QueuedPrompt>) {
        self.queued_prompts = prompts;
        self.queue_is_paused = true;
    }

    pub fn cancel_queued(&mut self, id: Uuid) {
        self.queued_prompts.retain(|p| p.id != id);
    }

    pub fn edit_queued(&mut self, id: Uuid) {
        if !self.draft.trim().is_empty() || !self.attachments.is_empty() {
            self.composer_error =
                Some("Send or clear the current draft before editing a queued message.".into());
            return;
        }
        let Some(queued) = self.queued_prompts.iter().find(|p| p.id == id).cloned() else {
            return;
        };
        self.draft = queued.text;
        self.attachments = queued.attachments;
        self.cancel_queued(id);
    }

    pub fn add_attachment(&mut self, attachment: Attachment) {
        if self.attachments.iter().any(|a| a.id == attachment.id) {
            return;
        }
        if self.attachments.len() >= MAX_ATTACHMENTS {
            self.composer_error = Some(context::ContextError::TooMany.to_string());
            return;
        }
        self.attachments.push(attachment);
    }

    pub fn remove_attachment(&mut self, id: &str) {
        self.attachments.retain(|a| a.id != id);
    }

    pub fn review_retry(&mut self) {
        let Some(failed) = self.failed_prompt.clone() else {
            return;
        };
        if !self.draft.is_empty() || !self.attachments.is_empty() {
            self.composer_error =
                Some("Send or clear the current draft before restoring the failed prompt.".into());
            return;
        }
        self.draft = failed.text;
        self.attachments = failed.attachments;
        self.composer_error = Some(
            "Review before sending again. Earlier completed actions are not undone and may be repeated."
                .into(),
        );
    }

    pub fn edit_as_follow_up(&mut self, item_id: &str) {
        let Some(TranscriptItem::User { text, .. }) = self
            .folder
            .items()
            .iter()
            .find(|i| i.id() == item_id)
            .cloned()
        else {
            return;
        };
        if !self.draft.is_empty() || !self.attachments.is_empty() {
            self.composer_error = Some("Send or clear the current draft first.".into());
            return;
        }
        self.draft = text;
        self.attachments = self
            .message_attachments
            .get(item_id)
            .cloned()
            .unwrap_or_default();
    }

    pub fn review_response_retry(&mut self, item_id: &str) {
        let items = self.folder.items();
        let Some(index) = items.iter().position(|i| i.id() == item_id) else {
            return;
        };
        let Some(prompt) = items[..index]
            .iter()
            .rev()
            .find(|i| matches!(i, TranscriptItem::User { .. }))
            .cloned()
        else {
            return;
        };
        self.edit_as_follow_up(prompt.id());
        if self.draft == prompt.searchable_text() {
            self.composer_error = Some("Review before sending again. Earlier completed actions are not undone and may be repeated.".into());
        }
    }

    pub fn deliver_next_queued(&mut self) {
        if self.state != SessionState::Ready || self.is_sending || self.queued_prompts.is_empty() {
            return;
        }
        let next = self.queued_prompts.remove(0);
        if !self.send(&next.text, next.attachments.clone(), false, true) {
            self.queued_prompts.insert(0, next);
            self.queue_is_paused = true;
        }
    }

    /// "Send next": resumes the queue, starting the task when it is idle.
    pub fn send_next_queued(&mut self) {
        if self.queued_prompts.is_empty() {
            return;
        }
        self.queue_is_paused = false;
        match self.state {
            SessionState::Ready => self.deliver_next_queued(),
            SessionState::Idle | SessionState::Failed(_) => self.start(),
            SessionState::Starting | SessionState::Running => {}
        }
    }

    fn maybe_deliver_queued(&mut self) {
        if !self.queue_is_paused && !self.queued_prompts.is_empty() {
            self.deliver_next_queued();
        }
    }

    /// Stops the current turn. pi's confirmation promise has no abort signal,
    /// so waiting approvals are cancelled first or the abort waits forever.
    pub fn abort(&mut self) {
        self.queue_is_paused = true;
        let Some(client) = self.client.clone() else {
            return;
        };
        if self.is_stopping {
            return;
        }
        self.is_stopping = true;
        self.cancel_pending_approvals();
        let id = self.fresh_id("a");
        client.request(PiCommand::Abort { id }, RequestTag::Abort);
    }

    // ---------------------------------------------------------- approvals

    /// Remembers the mode app-wide and answers waiting cards it now allows.
    /// Changing modes clears per-tool session exceptions so a downgrade
    /// takes effect.
    pub fn set_approval_mode(&mut self, mode: ApprovalMode) {
        if self.approval_mode == mode {
            return;
        }
        self.policy.reset_session();
        self.approval_mode = mode;
        self.policy.mode = mode;
        if let Err(err) = policy::save_mode(&self.env.dirs.approval_mode_file(), mode) {
            log::warn!("saving the agent approval mode failed: {err}");
        }
        let allowed: Vec<String> = self
            .folder
            .pending_approvals()
            .into_iter()
            .filter(|request| {
                self.policy.verdict(
                    &request.tool,
                    request.path.as_deref(),
                    request.workspace.as_deref(),
                    &self.workspace,
                ) == Verdict::Allow
            })
            .map(|request| request.id.clone())
            .collect();
        for id in allowed {
            self.respond_to_approval(&id, true, ApprovalScope::Once);
        }
    }

    /// The unattended harness may approve workspace file changes only.
    pub fn approve_workspace_file_changes_for_automation(&mut self) {
        self.policy.approve_workspace_file_changes_for_automation();
    }

    pub fn respond_to_approval(&mut self, id: &str, approved: bool, scope: ApprovalScope) {
        let Some(client) = self.client.clone() else {
            return;
        };
        let Some(request) = self.folder.approval(id).cloned() else {
            return;
        };
        let approved = approved && request.can_approve();
        if approved && scope == ApprovalScope::Session {
            self.policy.allow_for_session(
                &request.tool,
                request.path.as_deref(),
                request.workspace.as_deref(),
                &self.workspace,
            );
        }
        self.folder.resolve_approval(id);
        if !approved {
            self.folder.append_notice(
                &format!("You denied this {} request. Nothing changed.", request.tool),
                false,
            );
        }
        self.publish();
        let _ = client.send(&PiCommand::UiConfirmResponse {
            request_id: id.to_string(),
            confirmed: approved,
        });
    }

    /// Unattended callers resolve every card as a one-time denial.
    pub fn deny_all_pending_approvals(&mut self) {
        for id in self.folder.pending_approval_ids() {
            self.respond_to_approval(&id, false, ApprovalScope::Once);
        }
    }

    fn cancel_pending_approvals(&mut self) {
        let ids = self.folder.pending_approval_ids();
        if let Some(client) = &self.client {
            for id in ids {
                let _ = client.send(&PiCommand::UiCancelResponse { request_id: id });
            }
        }
        self.folder.resolve_all_approvals();
        self.publish();
    }

    // ------------------------------------------------------------- inputs

    /// Applies one completion. Returns true when anything visible changed.
    pub fn handle(&mut self, generation: u64, input: SessionInput) -> bool {
        match input {
            SessionInput::Stopped => {
                self.stops_pending = self.stops_pending.saturating_sub(1);
                if self.stops_pending == 0 && std::mem::take(&mut self.start_after_stop) {
                    self.start();
                }
                true
            }
            SessionInput::FailureTornDown { message, recovery } => {
                self.failure_teardown_in_progress = false;
                if generation == self.generation {
                    self.state = SessionState::Failed(message);
                    self.recovery_action = Some(recovery);
                }
                if std::mem::take(&mut self.start_after_stop) {
                    self.start();
                }
                true
            }
            SessionInput::Launched(result) => {
                if generation != self.generation {
                    if let Ok(launched) = result {
                        discard(launched, &self.env);
                    }
                    return false;
                }
                self.on_launched(result);
                true
            }
            SessionInput::Preview { session, result } => {
                if generation != self.generation || self.has_live_runtime() {
                    return false;
                }
                match result {
                    Ok(preview) => self.apply_preview(session, preview),
                    Err(error) => self.composer_error = Some(error.to_string()),
                }
                true
            }
            SessionInput::Client(message) => {
                if generation != self.generation {
                    return false;
                }
                match message {
                    ClientMessage::Event(event) => self.handle_event(event),
                    ClientMessage::Response { tag, result } => self.handle_response(tag, result),
                    ClientMessage::Closed { stderr_tail } => self.handle_stream_end(stderr_tail),
                }
                true
            }
        }
    }

    fn on_launched(&mut self, result: Result<Launched, LaunchError>) {
        let launched = match result {
            Ok(launched) => launched,
            Err(error) => {
                self.set_failure(error);
                self.restore_pending_submission();
                return;
            }
        };
        let settings = self.env.settings();
        self.model_context = Some(ModelContext::from_endpoint(&launched.endpoint, &settings));
        self.connected_endpoint = Some(launched.endpoint.base_url.clone());
        self.connected_plan = launched.endpoint.plan;
        self.client = Some(launched.client.clone());
        self.process = launched.process;
        self.lease = launched.lease;
        self.relay = launched.relay;
        self.capability = launched.capability;
        self.recovery_action = None;
        if launched.reports_session_file {
            let id = self.fresh_id("session-file");
            launched
                .client
                .request(PiCommand::GetSessionStats { id }, RequestTag::SessionFile);
        }
        let notice = match &self.launch_mode {
            LaunchMode::Fresh => None,
            LaunchMode::ContinueRecent => {
                Some("Resumed the most recent session for this working folder.".to_string())
            }
            LaunchMode::Saved(session) if self.folder.items().is_empty() => {
                Some(format!("Resumed \u{201c}{}\u{201d}.", session.title))
            }
            LaunchMode::Saved(_) => None,
        };
        match notice {
            Some(notice) => {
                let id = self.fresh_id("history");
                launched.client.request(
                    PiCommand::GetMessages { id },
                    RequestTag::History { notice },
                );
            }
            None => self.become_ready(),
        }
    }

    fn become_ready(&mut self) {
        if self.state == SessionState::Starting {
            self.state = SessionState::Ready;
        }
        self.deliver_pending_submission();
        if self.state == SessionState::Ready {
            self.maybe_deliver_queued();
        }
    }

    fn handle_event(&mut self, event: PiEvent) {
        if self.state == SessionState::Idle || self.is_failed() {
            return;
        }
        match &event {
            PiEvent::AgentStart => {
                self.state = SessionState::Running;
                self.turn_error = None;
            }
            PiEvent::AgentSettled => self.state = SessionState::Ready,
            PiEvent::ExtensionUiRequest(request) => self.handle_ui_request(request.clone()),
            _ => {}
        }
        self.folder.fold(&event);
        if event == PiEvent::AgentSettled
            && let Some(failure) = self.folder.terminal_failure()
        {
            self.turn_error = Some(failure.to_string());
            self.queue_is_paused = true;
            self.failed_prompt = self.last_submitted_prompt.clone();
        }
        self.publish();
        // agent_end can precede automatic retry or compaction; pi emits
        // agent_settled only once the whole run is idle.
        if event == PiEvent::AgentSettled {
            self.maybe_deliver_queued();
        }
    }

    fn handle_ui_request(&mut self, request: PiUiRequest) {
        let Some(client) = self.client.clone() else {
            return;
        };
        let cancel = |client: &RpcClient<RequestTag>, id: &str| {
            let _ = client.send(&PiCommand::UiCancelResponse {
                request_id: id.to_string(),
            });
        };
        if self.is_stopping {
            cancel(&client, &request.id);
            return;
        }
        if request.method != "confirm" {
            self.folder.append_notice(
                &format!(
                    "The agent asked for an unsupported interaction ({}); declined.",
                    request.method
                ),
                false,
            );
            cancel(&client, &request.id);
            return;
        }
        let approval = parse_approval_payload(&request);
        if !approval.can_approve() {
            let subject = if approval.arguments.is_none() {
                "The shell command".to_string()
            } else {
                format!("The {} request", approval.tool)
            };
            self.folder.append_notice(
                &format!("{subject} could not be reviewed in full and was declined. Nothing ran."),
                true,
            );
            let _ = client.send(&PiCommand::UiConfirmResponse {
                request_id: request.id,
                confirmed: false,
            });
            return;
        }
        match self.policy.verdict(
            &approval.tool,
            approval.path.as_deref(),
            approval.workspace.as_deref(),
            &self.workspace,
        ) {
            Verdict::Allow => {
                let _ = client.send(&PiCommand::UiConfirmResponse {
                    request_id: request.id,
                    confirmed: true,
                });
            }
            Verdict::Ask => {
                if !self.folder.add_approval(approval) {
                    self.folder.append_notice(
                        "The newest tool approval exceeded safety limits or too many are already waiting; it was declined.",
                        true,
                    );
                    cancel(&client, &request.id);
                }
            }
        }
    }

    fn handle_response(&mut self, tag: RequestTag, result: Result<PiResponse, RpcError>) {
        match tag {
            RequestTag::Prompt {
                pending,
                was_running,
                from_queue,
            } => {
                self.is_sending = false;
                match result {
                    Ok(response) if !response.success => {
                        self.failed_prompt = Some(pending.clone());
                        self.queue_is_paused = true;
                        if !was_running {
                            self.state = SessionState::Ready;
                        }
                        let message = response.error.unwrap_or_else(|| {
                            "The agent rejected this message. Review it before retrying.".into()
                        });
                        self.composer_error = Some(message.clone());
                        self.folder.append_notice(&message, true);
                        self.publish();
                        self.requeue_or_restore(pending, from_queue);
                    }
                    Ok(_) => {
                        if self.turn_error.is_none() {
                            self.failed_prompt = None;
                        }
                        // The acknowledgement can arrive after agent_settled.
                        if self.state == SessionState::Ready {
                            self.maybe_deliver_queued();
                        }
                    }
                    Err(error) => {
                        self.failed_prompt = Some(pending.clone());
                        self.queue_is_paused = true;
                        self.requeue_or_restore(pending, from_queue);
                        self.transition_to_failure(error.to_string(), RecoveryAction::Restart);
                    }
                }
            }
            RequestTag::Abort => self.is_stopping = false,
            RequestTag::SessionFile => {
                let Ok(response) = result else { return };
                if !response.success {
                    return;
                }
                let file = response
                    .data()
                    .and_then(|data| data.get("sessionFile")?.as_str().map(PathBuf::from))
                    .filter(|file| !file.as_os_str().is_empty());
                let Some(file) = file else { return };
                let expected = dunce::canonicalize(self.env.dirs.sessions()).ok();
                let actual = file.parent().and_then(|p| dunce::canonicalize(p).ok());
                if let (Some(expected), Some(actual)) = (expected, actual)
                    && policy::same_path(&expected, &actual)
                {
                    self.active_session_file = Some(file);
                }
            }
            RequestTag::History { notice } => {
                self.restore_previous_messages(result, &notice);
                self.become_ready();
            }
        }
    }

    fn requeue_or_restore(&mut self, pending: QueuedPrompt, from_queue: bool) {
        if from_queue {
            self.queued_prompts.insert(0, pending);
            self.queue_is_paused = true;
        } else if self.draft.is_empty() && self.attachments.is_empty() {
            self.draft = pending.text;
            self.attachments = pending.attachments;
        }
    }

    fn handle_stream_end(&mut self, stderr_tail: Vec<String>) {
        if self.state == SessionState::Idle || self.is_failed() {
            return;
        }
        let mut detail = "The agent process exited unexpectedly.".to_string();
        let tail: Vec<&String> = stderr_tail.iter().rev().take(5).collect();
        if !tail.is_empty() {
            for line in tail.into_iter().rev() {
                detail.push('\n');
                detail.push_str(line);
            }
        }
        self.transition_to_failure(detail, RecoveryAction::Restart);
    }

    fn restore_previous_messages(
        &mut self,
        result: Result<PiResponse, RpcError>,
        resumed_notice: &str,
    ) {
        let response = match result {
            Ok(response) => response,
            Err(error) => {
                self.folder.append_notice(
                    &format!("Couldn't restore the previous session: {error}"),
                    true,
                );
                self.publish();
                return;
            }
        };
        if !response.success {
            self.folder.append_notice(
                response
                    .error
                    .as_deref()
                    .unwrap_or("Couldn't restore the previous session."),
                true,
            );
            self.publish();
            return;
        }
        let messages = history_messages(response.data());
        if messages.is_empty() {
            self.folder.append_notice(
                "No previous conversation was found for this working folder.",
                false,
            );
            self.publish();
            return;
        }
        self.folder = TranscriptFolder::default();
        for (role, text, failure) in messages {
            match role.as_str() {
                "user" => {
                    if self.session_title.is_none() {
                        self.session_title = Some(make_session_title(&text));
                    }
                    self.folder.note_user_prompt(context::display_prompt(&text));
                }
                "assistant" => {
                    if !text.is_empty() {
                        self.folder.append_assistant_message(&text);
                    }
                    if let Some(failure) = failure {
                        self.folder.append_notice(&failure, true);
                    }
                }
                _ => {}
            }
        }
        self.folder.append_notice(resumed_notice, false);
        self.publish();
    }

    // --------------------------------------------------------- reasoning

    /// After the Agent or Think reasoning setting changed: a running agent
    /// uses the new level from its next model call.
    pub fn reasoning_level_did_change(&mut self) {
        if self.reasoning_choices.is_some() {
            self.write_reasoning_level();
        }
    }

    fn write_reasoning_level(&mut self) {
        let Some(choices) = &self.reasoning_choices else {
            return;
        };
        let settings = self.env.settings();
        let level = choices
            .clamp(settings.effective_agent_reasoning_level())
            .unwrap_or(ReasoningLevel::Automatic);
        if self.written_reasoning_level == Some(level) {
            return;
        }
        let body = serde_json::json!({ "level": reasoning_key(level) }).to_string();
        match lokalbot_core::library::write_atomic(&self.reasoning_level_file, body.as_bytes()) {
            Ok(()) => self.written_reasoning_level = Some(level),
            Err(err) => log::warn!("agent reasoning level write failed: {err}"),
        }
    }

    pub fn reasoning_level_file(&self) -> &Path {
        &self.reasoning_level_file
    }

    // ------------------------------------------------------------ helpers

    fn publish(&mut self) {
        self.folder.enforce_resource_limits();
    }

    fn fresh_id(&mut self, prefix: &str) -> String {
        self.next_request_id += 1;
        format!("{prefix}{}", self.next_request_id)
    }

    fn revoke_capability(&mut self) {
        if let Some(token) = self.capability.take()
            && let Err(err) =
                lokalbot_core::access::revoke_agent_capability(self.env.library.paths(), &token)
        {
            log::warn!("revoking the agent capability failed: {err}");
        }
    }

    /// Releases the built-in model's lease and stops the plan relay.
    fn release_model_connection(&mut self) {
        self.lease = None;
        self.relay = None;
    }

    fn reset_approval_policy(&mut self) {
        // Session allowances end at lifecycle boundaries; the mode is an app
        // preference and survives closing or resuming a task.
        self.policy.reset_session();
        self.policy.mode = self.approval_mode;
    }

    /// Invalidates the generation before the process stop, so frames already
    /// buffered cannot revive the task, and keeps restart disabled until the
    /// old process has actually ended.
    fn transition_to_failure(&mut self, message: String, recovery: RecoveryAction) {
        if self.failure_teardown_in_progress || self.state == SessionState::Idle || self.is_failed()
        {
            return;
        }
        self.failure_teardown_in_progress = true;
        self.generation += 1;
        self.recovery_action = None;
        let old_process = self.process.take();
        self.client = None;
        if let Some(saved) = self
            .active_session_file
            .as_deref()
            .and_then(|file| history::load_file(file, &self.env.dirs.sessions()))
        {
            self.launch_mode = LaunchMode::Saved(saved);
        }
        self.model_context = None;
        self.queue_is_paused = true;
        self.is_sending = false;
        self.is_stopping = false;
        self.pending_submission = None;
        self.folder.resolve_all_approvals();
        self.reset_approval_policy();
        self.revoke_capability();
        if self.failed_prompt.is_none() {
            self.failed_prompt = self.last_submitted_prompt.clone();
        }
        self.folder.append_notice(&message, true);
        self.publish();
        self.release_model_connection();
        match old_process {
            Some(process) => {
                let inbox = self.inbox.clone();
                let task = self.task;
                let generation = self.generation;
                let spawned = std::thread::Builder::new()
                    .name("lokalbot-pi-stop".into())
                    .spawn(move || {
                        process.stop(crate::process::STOP_GRACE);
                        let _ = inbox.send_blocking(TaskInput {
                            task,
                            generation,
                            input: SessionInput::FailureTornDown { message, recovery },
                        });
                    });
                if spawned.is_err() {
                    self.failure_teardown_in_progress = false;
                }
            }
            None => {
                self.failure_teardown_in_progress = false;
                self.state = SessionState::Failed(message);
                self.recovery_action = Some(recovery);
            }
        }
    }

    fn set_failure(&mut self, error: LaunchError) {
        self.is_stopping = false;
        self.folder.resolve_all_approvals();
        self.active_session_file = None;
        self.model_context = None;
        self.reset_approval_policy();
        self.revoke_capability();
        self.release_model_connection();
        self.state = SessionState::Failed(error.message().to_string());
        self.recovery_action = Some(match error {
            LaunchError::Configuration(_) => RecoveryAction::OpenModels,
            LaunchError::Other(_) => RecoveryAction::Restart,
        });
    }

    /// Before model loading or capability issuance, including resumed tasks.
    /// An old working folder is never migrated silently.
    pub fn prepare_workspace(&self) -> Result<(), String> {
        if let Some(notice) = self.workspace_access_notice() {
            return Err(notice.into());
        }
        if policy::same_path(&self.workspace, &self.env.dirs.default_workspace()) {
            crate::fsutil::create_private_dir(&self.workspace)
                .map_err(|err| format!("Couldn't create the Agent Workspace: {err}"))?;
        }
        if let Some(notice) = self.workspace_access_notice() {
            return Err(notice.into());
        }
        if !self.workspace.is_dir() {
            return Err(
                "The task’s working folder no longer exists. Choose a new folder before sending."
                    .into(),
            );
        }
        Ok(())
    }
}

impl Drop for AgentSession {
    fn drop(&mut self) {
        self.revoke_capability();
        let _ = std::fs::remove_file(&self.reasoning_level_file);
    }
}

/// Stops a launch that finished after its task moved on.
fn discard(launched: Launched, env: &AgentEnvironment) {
    if let Some(token) = &launched.capability {
        let _ = lokalbot_core::access::revoke_agent_capability(env.library.paths(), token);
    }
    let process = launched.process;
    drop(launched.lease);
    drop(launched.relay);
    if let Some(process) = process {
        let _ = std::thread::Builder::new()
            .name("lokalbot-pi-stop".into())
            .spawn(move || process.stop(crate::process::STOP_GRACE));
    }
}

/// Why a launched remote endpoint may no longer receive context.
fn remote_block(base: &str, settings: &Settings) -> Option<String> {
    if lokalbot_core::access::is_loopback_url(base) {
        return None;
    }
    let Some(origin) = lokalbot_core::access::origin_of(base) else {
        return Some("The server URL is not valid.".into());
    };
    if settings
        .approved_remote_inference_origins
        .iter()
        .any(|approved| approved.eq_ignore_ascii_case(&origin))
    {
        None
    } else {
        Some(format!(
            "Allow sending context to {origin} in Settings → Models first."
        ))
    }
}

/// Our extension sends title `lokalbot_tool_approval` with structured
/// fields; older payloads with only a summary stay readable.
pub fn parse_approval_payload(request: &PiUiRequest) -> ApprovalRequest {
    if request.title.as_deref() == Some("lokalbot_tool_approval")
        && let Some(payload) = request
            .message
            .as_deref()
            .and_then(|m| serde_json::from_str::<serde_json::Value>(m).ok())
        && let Some(tool) = payload.get("tool").and_then(|v| v.as_str())
    {
        let text = |key: &str| {
            payload
                .get(key)
                .and_then(|v| v.as_str())
                .map(str::to_string)
        };
        let edits = payload
            .get("edits")
            .and_then(|v| v.as_array())
            .map(|edits| {
                edits
                    .iter()
                    .filter_map(|edit| {
                        Some(Edit {
                            old_text: edit.get("oldText")?.as_str()?.to_string(),
                            new_text: edit.get("newText")?.as_str()?.to_string(),
                        })
                    })
                    .collect()
            })
            .unwrap_or_default();
        return ApprovalRequest {
            id: request.id.clone(),
            tool: tool.to_string(),
            workspace: text("workspace"),
            path: text("path"),
            command: text("command"),
            content: text("content"),
            edits,
            summary: text("summary"),
            is_truncated: payload
                .get("truncated")
                .and_then(|v| v.as_bool())
                .unwrap_or(false),
            arguments: text("arguments"),
        };
    }
    ApprovalRequest {
        id: request.id.clone(),
        tool: request.title.clone().unwrap_or_else(|| "action".into()),
        workspace: None,
        path: None,
        command: None,
        content: None,
        edits: Vec::new(),
        summary: request.message.clone(),
        is_truncated: false,
        arguments: None,
    }
}

/// `get_messages` data as (role, text, terminal failure).
fn history_messages(data: Option<serde_json::Value>) -> Vec<(String, String, Option<String>)> {
    let Some(messages) = data
        .as_ref()
        .and_then(|d| d.get("messages"))
        .and_then(|m| m.as_array())
    else {
        return Vec::new();
    };
    messages
        .iter()
        .filter_map(|message| {
            let role = message.get("role")?.as_str()?;
            if role != "user" && role != "assistant" {
                return None;
            }
            let content = message.get("content")?;
            if !content.is_string() && !content.is_array() {
                return None;
            }
            let text = crate::messages::content_text(Some(content), "");
            let failure = (role == "assistant")
                .then(|| {
                    crate::messages::terminal_failure(
                        message.get("stopReason").and_then(|v| v.as_str()),
                        message.get("errorMessage").and_then(|v| v.as_str()),
                    )
                })
                .flatten();
            (!text.is_empty() || failure.is_some()).then(|| (role.to_string(), text, failure))
        })
        .collect()
}

/// The first line, cut at a word near 36 characters.
pub fn make_session_title(prompt: &str) -> String {
    let first = prompt.lines().next().unwrap_or(prompt).trim();
    if first.chars().count() <= 36 {
        return first.to_string();
    }
    let prefix: String = first.chars().take(35).collect();
    let cut = prefix.rfind(' ').map(|at| &prefix[..at]).unwrap_or(&prefix);
    format!("{}…", cut.trim_end())
}

/// Whether pi has a session whose working folder is `workspace`.
pub fn has_resumable_session(directory: &Path, workspace: &Path) -> bool {
    let Ok(entries) = std::fs::read_dir(directory) else {
        return false;
    };
    entries.flatten().any(|entry| {
        let path = entry.path();
        if !path
            .extension()
            .is_some_and(|e| e.eq_ignore_ascii_case("jsonl"))
        {
            return false;
        }
        let Ok(mut file) = std::fs::File::open(&path) else {
            return false;
        };
        let mut head = vec![0u8; 16 * 1024];
        let read = std::io::Read::read(&mut file, &mut head).unwrap_or(0);
        let first = head[..read]
            .split(|b| *b == b'\n')
            .next()
            .unwrap_or_default();
        serde_json::from_slice::<serde_json::Value>(first)
            .ok()
            .filter(|h| h.get("type").and_then(|t| t.as_str()) == Some("session"))
            .and_then(|h| h.get("cwd").and_then(|c| c.as_str()).map(PathBuf::from))
            .is_some_and(|cwd| policy::same_path(&cwd, workspace))
    })
}

#[cfg(test)]
#[path = "session_tests.rs"]
mod tests;
