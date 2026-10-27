// Contains code ported from Cotabby (https://github.com/FuJacob/cotabby),
// copyright the Cotabby authors, under the GNU AGPL v3.0
// (LICENSES/AGPL-3.0.txt). Modified for LokalBot since 23 June 2026.
// See THIRD_PARTY_NOTICES.md.

//! Autocomplete (`CotypingCoordinator`): turns the desktop's reads of the
//! focused field into suggestions.
//!
//! The desktop sends a [`FieldContext`] on every change. A text change asks
//! for a suggestion after the debounce; a caret move only drops the one on
//! screen. Typing a suggestion's next characters, or accepting part of it,
//! keeps it (shortened) and may top it up with a few more words. One request
//! is in flight at a time; a newer field read supersedes it, and a result
//! that arrives late is shown only if the field still continues it. A newly
//! focused field has its prompt read ahead, so the first keystroke only adds
//! what was typed. A field read that arrives while the server is still
//! starting is answered once it is up, unless it was dismissed or answered
//! some other way meanwhile.
//!
//! Nothing runs unless Autocomplete is on, and nothing is ever downloaded:
//! without the Autocomplete model and the llama.cpp runtime no suggestion is
//! made. Suggestions pause while a meeting records, and the excluded apps are
//! checked again here. Typed text stays in memory and is never logged.

use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use crossbeam_channel::{Receiver, RecvTimeoutError, Sender, unbounded};
use parking_lot::Mutex;

use lokalbot_ai::autocomplete::learning::{AcceptedBatch, LearningStore, Place};
use lokalbot_ai::autocomplete::memory::{self, Policy, Query, Selection};
use lokalbot_ai::autocomplete::{
    self as ac, Completer, Completion, Extras, Personalization, Reconciled, Request, Session,
    SuggestionKind, debounce, emoji, seam, session,
};
use lokalbot_ai::catalog::{self, ModelKind};
use lokalbot_core::{Library, Settings};

use crate::models::{Models, RUNTIME_ID};
use crate::{AutocompleteCommand, AutocompleteUpdate, EngineEvent, FieldContext, Shared};

/// A suggestion left alone this long is taken down, so a Tab pressed long
/// afterwards reaches the app (`idleSuggestionLifetimeMilliseconds`).
const IDLE_SUGGESTION_LIFETIME: Duration = Duration::from_secs(60);
/// Learned examples folded into a prompt (`cotypingLearningExamplesInPrompt`).
const LEARNED_EXAMPLES_IN_PROMPT: usize = 3;

/// The worker's view of the engine, so its rules run in tests without a
/// model server.
pub(crate) trait Host: Send + Sync + 'static {
    fn settings(&self) -> Settings;
    fn emit(&self, update: AutocompleteUpdate);
    /// A meeting is recording: suggestions pause (`CotypingMeetingPause`).
    fn recording(&self) -> bool;
    /// The Autocomplete model and the runtime are installed.
    fn ready(&self, settings: &Settings) -> bool;
    /// The Autocomplete server is up: not stopped, and not still starting.
    fn server_running(&self) -> bool;
    /// Runs one request against the Autocomplete server. Blocking; called on
    /// the request's own thread.
    fn run(&self, job: &JobKind, settings: &Settings, cancel: &AtomicBool) -> Outcome;
    /// Autocomplete was turned off: stop its server now.
    fn stop_server(&self);
    /// Saved facts for `query` the grants allow. Reads the library; called
    /// on a thread of its own.
    fn memory(&self, query: &Query, policy: Policy) -> Selection;
}

/// The engine side of [`Host`].
struct EngineHost {
    shared: Arc<Shared>,
    models: Models,
    /// Failures are logged once until a request succeeds again.
    failing: Mutex<bool>,
}

impl Host for EngineHost {
    fn settings(&self) -> Settings {
        self.shared.settings()
    }

    fn emit(&self, update: AutocompleteUpdate) {
        let visible = matches!(update, AutocompleteUpdate::Suggestion { .. });
        self.shared
            .autocomplete_visible
            .store(visible, Ordering::Relaxed);
        self.shared.emit(EngineEvent::Autocomplete(update));
    }

    fn recording(&self) -> bool {
        self.shared.recording_active.load(Ordering::Relaxed)
    }

    fn ready(&self, settings: &Settings) -> bool {
        model_entry(settings).is_some_and(|entry| {
            self.models.is_installed(entry.id) && self.models.is_installed(RUNTIME_ID)
        })
    }

    fn server_running(&self) -> bool {
        self.shared
            .runtime
            .server(lokalbot_ai::runtime::Role::Autocomplete)
            .status()
            .running
    }

    fn run(&self, job: &JobKind, settings: &Settings, cancel: &AtomicBool) -> Outcome {
        let Some(entry) = model_entry(settings) else {
            return Outcome::NotReady;
        };
        // Starts the server on first use; the runtime never downloads for
        // this role, and an unverified model is refused.
        let lease = match self.shared.runtime.autocomplete_server(entry) {
            Ok(lease) => lease,
            Err(err) => {
                return match err.downcast_ref::<lokalbot_ai::AiError>() {
                    Some(lokalbot_ai::AiError::ModelMissing(_))
                    | Some(lokalbot_ai::AiError::Unavailable(_))
                    | Some(lokalbot_ai::AiError::NoModel) => Outcome::NotReady,
                    _ => self.failed(&err),
                };
            }
        };
        if cancel.load(Ordering::Relaxed) {
            return Outcome::Cancelled;
        }
        let completer = Completer::new(&lease.root_url(), lease.token());
        let outcome = match job {
            JobKind::Prefill { request, .. } => match completer.prefill(request) {
                Ok(()) => Outcome::Prefilled,
                Err(err) => self.failed(&err),
            },
            JobKind::Fresh { request, .. } | JobKind::TopUp { request, .. } => {
                match completer.complete(request, &|| cancel.load(Ordering::Relaxed)) {
                    Ok(completion) => Outcome::Completion(Box::new(completion)),
                    Err(err) if err.downcast_ref::<ac::Cancelled>().is_some() => Outcome::Cancelled,
                    Err(err) => {
                        lease.mark_unreachable();
                        self.failed(&err)
                    }
                }
            }
        };
        if !matches!(outcome, Outcome::Failed) {
            *self.failing.lock() = false;
        }
        outcome
    }

    fn stop_server(&self) {
        self.shared
            .runtime
            .server(lokalbot_ai::runtime::Role::Autocomplete)
            .stop();
    }

    fn memory(&self, query: &Query, policy: Policy) -> Selection {
        look_up(&self.shared.library, query, policy)
    }
}

/// `CotypingMemoryContextProvider.load`: the facts the grants allow,
/// selected for `query`.
fn look_up(library: &Library, query: &Query, policy: Policy) -> Selection {
    if !policy.enabled() || query.all.is_empty() {
        return Selection::default();
    }
    let now = chrono::Utc::now();
    let mut items = work_memory_items(library.paths().root());
    if policy.meetings {
        items.extend(meeting_items(library, query, now));
    }
    memory::select(&items, query, policy, now, true)
}

/// The saved facts a suggestion in `field` would use now, as (source title,
/// fact): for diagnostics and the practice editor's "what shaped this"
/// (`memoryContextSources`). Reads the library; empty without the grant.
pub fn saved_facts(
    library: &Library,
    field: &FieldContext,
    settings: &Settings,
) -> Vec<(String, String)> {
    let policy = Policy {
        meetings: settings.cotyping_use_meeting_memory,
        screen_derived: false,
    };
    let query = Query::for_field(
        memory::finished_words(&field.before),
        &field.window_title,
        field.visible_text.as_deref().unwrap_or(""),
        &field.app_name,
        &field.app_id,
    );
    look_up(library, &query, policy)
        .items
        .into_iter()
        .map(|item| (item.title, item.text))
        .collect()
}

impl EngineHost {
    /// Logs a failure once per episode, without the server's own message:
    /// a request error can quote the prompt, and typed text is never logged.
    fn failed(&self, err: &anyhow::Error) -> Outcome {
        let mut failing = self.failing.lock();
        if !*failing {
            let reason = match err.downcast_ref::<lokalbot_ai::AiError>() {
                Some(lokalbot_ai::AiError::HttpStatus { code, .. }) => format!("HTTP {code}"),
                Some(lokalbot_ai::AiError::ServerUnreachable(_)) => "server unreachable".into(),
                Some(lokalbot_ai::AiError::BadResponse(_)) => "unreadable response".into(),
                Some(lokalbot_ai::AiError::ServerStart(_)) => "server did not start".into(),
                _ => "error".into(),
            };
            log::warn!("autocomplete: request failed ({reason})");
            *failing = true;
        }
        Outcome::Failed
    }
}

/// The catalog entry Settings → Models chose for Autocomplete.
fn model_entry(settings: &Settings) -> Option<&'static catalog::ModelEntry> {
    catalog::entry(&settings.cotyping_built_in_model_id).filter(|e| e.kind == ModelKind::Text)
}

/// One request to the Autocomplete server.
#[derive(Clone, Debug)]
pub(crate) enum JobKind {
    /// A suggestion for `field` as it was read.
    Fresh {
        field: FieldContext,
        request: Request,
        fingerprint: String,
        /// Saved facts or the text above the field shaped it: not learned.
        used_context: bool,
    },
    /// More words for the suggestion on screen (`CotypingSuggestionExtension`).
    TopUp {
        field_id: u64,
        full_text: String,
        prefix: String,
        request: Request,
    },
    /// Reads a newly focused field's prompt into the server's cache.
    Prefill { request: Request },
}

pub(crate) enum Outcome {
    Completion(Box<Completion>),
    Prefilled,
    NotReady,
    Failed,
    Cancelled,
}

enum Message {
    Command(AutocompleteCommand),
    SettingsChanged,
    Finished {
        job: u64,
        kind: JobKind,
        outcome: Outcome,
        elapsed: Duration,
    },
    Memory {
        anchor: String,
        query: Query,
        selection: Selection,
    },
    Stop,
}

/// Handle to the autocomplete worker thread.
pub struct Autocomplete {
    sender: Sender<Message>,
    thread: Option<JoinHandle<()>>,
}

impl Autocomplete {
    pub(crate) fn start(shared: Arc<Shared>, models: Models) -> Self {
        Self::with_host(Arc::new(EngineHost {
            shared,
            models,
            failing: Mutex::new(false),
        }))
    }

    pub(crate) fn with_host(host: Arc<dyn Host>) -> Self {
        let (sender, receiver) = unbounded();
        let worker = Worker::new(host, sender.clone());
        let thread = std::thread::Builder::new()
            .name("lokalbot-autocomplete".into())
            .spawn(move || worker.run(receiver))
            .map_err(|err| log::warn!("could not start autocomplete: {err}"))
            .ok();
        Self { sender, thread }
    }

    pub fn handle(&self, command: AutocompleteCommand) {
        let _ = self.sender.send(Message::Command(command));
    }

    /// Settings changed: Autocomplete may have been turned off or an app
    /// excluded.
    pub fn settings_changed(&self) {
        let _ = self.sender.send(Message::SettingsChanged);
    }

    pub fn stop(&mut self) {
        let _ = self.sender.send(Message::Stop);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

impl Drop for Autocomplete {
    fn drop(&mut self) {
        self.stop();
    }
}

/// The suggestion on screen.
struct Shown {
    field_id: u64,
    session: Session,
    fingerprint: String,
    used_context: bool,
}

/// The newest saved-memory lookup for the focused field
/// (`CotypingMemoryLookup`): a keystroke never waits for one; it takes the
/// newest finished one, and a new lookup runs when the finished words
/// before the caret could name something new.
#[derive(Default)]
struct MemoryLookup {
    anchor: Option<String>,
    requested: Option<Query>,
    selection: Selection,
}

impl MemoryLookup {
    fn needs_lookup(&self, anchor: &str, query: &Query) -> bool {
        self.anchor.as_deref() != Some(anchor) || self.requested.as_ref() != Some(query)
    }

    /// A different field forgets the previous field's facts at once.
    fn begin(&mut self, anchor: &str, query: &Query) {
        if self.anchor.as_deref() != Some(anchor) {
            self.selection = Selection::default();
        }
        self.anchor = Some(anchor.to_string());
        self.requested = Some(query.clone());
    }

    /// Keeps a finished lookup only if it is still the one asked for last.
    fn finish(&mut self, anchor: &str, query: &Query, selection: Selection) -> bool {
        if self.anchor.as_deref() != Some(anchor) || self.requested.as_ref() != Some(query) {
            return false;
        }
        let changed = self.selection != selection;
        self.selection = selection;
        changed
    }

    fn reset(&mut self) {
        *self = Self::default();
    }
}

struct Running {
    id: u64,
    cancel: Arc<AtomicBool>,
    /// A prefill cannot be stopped once sent, but what follows reuses it.
    prefill: bool,
    /// For a suggestion request, the text before the caret it was made for.
    before: Option<String>,
}

impl Running {
    /// Whether a request for `before` makes this one useless. Typing on from
    /// where it was asked keeps it: its suggestion may still be continued.
    fn superseded_by(&self, before: Option<&str>) -> bool {
        if self.prefill {
            return false;
        }
        match (&self.before, before) {
            (Some(asked), Some(now)) => !now.starts_with(asked.as_str()),
            _ => true,
        }
    }
}

struct Worker {
    host: Arc<dyn Host>,
    sender: Sender<Message>,
    /// The newest read of the focused field.
    field: Option<FieldContext>,
    shown: Option<Shown>,
    /// Whether the desktop was last told to show something.
    visible: bool,
    /// Bumped by every field change; a debounce for an older one is dropped.
    work: u64,
    /// When the debounced request for `work` is due.
    due: Option<(u64, Instant)>,
    running: Option<Running>,
    /// Starts once `running` has finished: one request at a time.
    queued: Option<JobKind>,
    /// The field whose newest read arrived while the server was starting:
    /// that read is answered once the server is up.
    pending: Option<u64>,
    jobs: u64,
    last_latency_ms: Option<u64>,
    last_activity: Option<Instant>,
    anchors: session::AnchorCache,
    /// The last accept that used up a suggestion, and the text before it.
    accepted_tail: Option<(String, String)>,
    memory: MemoryLookup,
    learning: LearningStore,
    /// What has been accepted of the suggestion on screen.
    batch: AcceptedBatch,
    /// Autocomplete was on at the last settings change.
    enabled: bool,
}

impl Worker {
    fn new(host: Arc<dyn Host>, sender: Sender<Message>) -> Self {
        Self {
            host,
            sender,
            field: None,
            shown: None,
            visible: false,
            work: 0,
            due: None,
            running: None,
            queued: None,
            pending: None,
            jobs: 0,
            last_latency_ms: None,
            last_activity: None,
            anchors: session::AnchorCache::new(),
            accepted_tail: None,
            memory: MemoryLookup::default(),
            learning: LearningStore::new(),
            batch: AcceptedBatch::default(),
            enabled: false,
        }
    }

    fn run(mut self, receiver: Receiver<Message>) {
        self.enabled = self.host.settings().cotyping_enabled;
        loop {
            let first = match self.deadline() {
                Some(deadline) => match receiver.recv_deadline(deadline) {
                    Ok(message) => Some(message),
                    Err(RecvTimeoutError::Timeout) => None,
                    Err(RecvTimeoutError::Disconnected) => break,
                },
                None => match receiver.recv() {
                    Ok(message) => Some(message),
                    Err(_) => break,
                },
            };
            // Field reads first, so a finished request is checked against
            // the newest one.
            let mut batch: Vec<Message> = first.into_iter().collect();
            batch.extend(receiver.try_iter());
            let (finished, others): (Vec<Message>, Vec<Message>) = batch
                .into_iter()
                .partition(|m| matches!(m, Message::Finished { .. }));
            for message in others.into_iter().chain(finished) {
                match message {
                    Message::Command(command) => self.on_command(command),
                    Message::SettingsChanged => self.on_settings_changed(),
                    Message::Finished {
                        job,
                        kind,
                        outcome,
                        elapsed,
                    } => self.on_finished(job, kind, outcome, elapsed),
                    Message::Memory {
                        anchor,
                        query,
                        selection,
                    } => self.on_memory(&anchor, &query, selection),
                    Message::Stop => {
                        self.cancel_all();
                        return;
                    }
                }
            }
            self.on_tick(Instant::now());
        }
        self.cancel_all();
    }

    fn deadline(&self) -> Option<Instant> {
        let expiry = self
            .visible
            .then_some(self.last_activity)
            .flatten()
            .map(|at| at + IDLE_SUGGESTION_LIFETIME);
        [self.due.map(|(_, at)| at), expiry]
            .into_iter()
            .flatten()
            .min()
    }

    // ----------------------------------------------------------- commands

    fn on_command(&mut self, command: AutocompleteCommand) {
        match command {
            AutocompleteCommand::Context(context) => self.on_context(context),
            AutocompleteCommand::Accepted { field_id, text } => self.on_accepted(field_id, &text),
            AutocompleteCommand::Dismiss => {
                self.cancel_all();
                self.clear_suggestion();
            }
        }
    }

    fn on_context(&mut self, context: FieldContext) {
        let field_id = context.field_id;
        self.read_field(context);
        // A read that arrives while the server is still starting cannot be
        // answered yet: the newest one is, once it is up (`serve_pending`).
        if self.field.as_ref().is_some_and(|f| f.field_id == field_id) && self.server_starting() {
            self.pending = Some(field_id);
        }
    }

    fn read_field(&mut self, context: FieldContext) {
        let settings = self.host.settings();
        if !self.allowed(&settings, &context) {
            self.cancel_all();
            self.clear_suggestion();
            self.field = None;
            return;
        }
        let previous = self.field.replace(context.clone());
        let Some(previous) = previous.filter(|p| p.field_id == context.field_id) else {
            // A newly focused field: nothing is suggested until the user
            // types, but its prompt is read now.
            self.cancel_all();
            self.clear_suggestion();
            self.accepted_tail = None;
            // The saved facts for this field are looked up now, so the first
            // suggestion can use them.
            let _ = self.memory_text(&context, &settings);
            self.prefill(&settings);
            return;
        };
        if previous.before == context.before && previous.after == context.after {
            if self.shown.is_some() {
                self.emit_suggestion();
            } else if (previous.visible_text != context.visible_text
                || previous.window_title != context.window_title)
                && self.running.is_none()
                && self.due.is_none()
            {
                // The text the prompt starts with changed: read it again now.
                self.prefill(&settings);
            }
            return;
        }
        if let Some(shown) = self.shown.as_mut() {
            match session::reconcile(&shown.session, &context.before, &context.after) {
                Reconciled::Unchanged => {
                    self.emit_suggestion();
                    return;
                }
                Reconciled::Advanced(next) if !next.is_exhausted() => {
                    shown.session = next;
                    self.cancel_pending();
                    self.emit_suggestion();
                    self.note_activity();
                    self.maybe_extend(&settings);
                    return;
                }
                Reconciled::Advanced(_) | Reconciled::Stale => self.clear_suggestion(),
            }
        }
        let caret_moved = previous.before.len() + previous.after.len()
            == context.before.len() + context.after.len()
            && format!("{}{}", previous.before, previous.after)
                == format!("{}{}", context.before, context.after);
        if caret_moved {
            // Arrow keys or a click: the suggestion goes and nothing is asked.
            self.cancel_generation(None);
            return;
        }
        self.schedule(&settings, &context.before);
    }

    fn on_accepted(&mut self, field_id: u64, text: &str) {
        let settings = self.host.settings();
        let Some(shown) = self.shown.as_ref().filter(|s| s.field_id == field_id) else {
            return;
        };
        if text.is_empty() {
            return;
        }
        let current = &shown.session;
        let advanced = match current.kind {
            SuggestionKind::Emoji => {
                (text == current.full_text).then(|| current.advanced(current.full_text.len()))
            }
            SuggestionKind::Continuation => {
                let remaining = current.remaining();
                if remaining.starts_with(text) {
                    Some(current.advanced(text.len()))
                } else {
                    // The accepted text left out a space the field already had.
                    let spaces = remaining.len() - remaining.trim_start().len();
                    remaining[spaces..]
                        .starts_with(text.trim_start())
                        .then(|| current.advanced(spaces + text.trim_start().len()))
                }
            }
        };
        let before_accept = current.expected_before();
        if let (Some(next), Some(field)) = (&advanced, &self.field)
            && current.kind == SuggestionKind::Continuation
        {
            let accepted = &next.full_text[current.consumed..next.consumed];
            self.batch
                .append(&place(field, &before_accept), accepted, !shown.used_context);
        }
        match advanced {
            None => self.clear_suggestion(),
            Some(next) if next.is_exhausted() => {
                // The next field read, with the accepted text, asks for more.
                self.accepted_tail = Some((text.to_string(), before_accept));
                self.clear_suggestion();
            }
            Some(next) => {
                if let Some(shown) = self.shown.as_mut() {
                    shown.session = next;
                }
                self.emit_suggestion();
                self.note_activity();
                self.maybe_extend(&settings);
            }
        }
    }

    fn on_settings_changed(&mut self) {
        let settings = self.host.settings();
        let was_enabled = std::mem::replace(&mut self.enabled, settings.cotyping_enabled);
        if !settings.cotyping_enabled {
            self.cancel_all();
            self.clear_suggestion();
            self.field = None;
            self.anchors.clear();
            self.memory.reset();
            self.learning.clear();
            // Turned off: the model does not stay loaded for the idle time.
            if was_enabled {
                self.host.stop_server();
            }
            return;
        }
        if !settings.cotyping_use_meeting_memory {
            self.memory.reset();
        }
        if let Some(field) = self.field.clone()
            && !self.allowed(&settings, &field)
        {
            self.cancel_all();
            self.clear_suggestion();
            self.field = None;
        }
    }

    fn on_tick(&mut self, now: Instant) {
        if let Some((work, at)) = self.due
            && at <= now
        {
            self.due = None;
            if work == self.work {
                self.request_suggestion();
            }
        }
        if self.visible
            && self
                .last_activity
                .is_some_and(|at| now >= at + IDLE_SUGGESTION_LIFETIME)
        {
            self.clear_suggestion();
        }
    }

    // ----------------------------------------------------------- requests

    /// `CotypingAvailability.disabledReason`, checked again here: on, not an
    /// excluded app, not a terminal, and no meeting recording.
    fn allowed(&self, settings: &Settings, field: &FieldContext) -> bool {
        settings.cotyping_enabled
            && !is_excluded(
                &settings.cotyping_excluded_apps,
                &field.app_name,
                &field.app_id,
            )
            && ac::surface::SurfaceClass::of(&field.app_id, &field.app_name)
                != ac::surface::SurfaceClass::Terminal
            && !self.host.recording()
    }

    /// A text change: the suggestion goes, and one is asked for after the
    /// debounce (`scheduleGeneration`).
    fn schedule(&mut self, settings: &Settings, before: &str) {
        self.clear_suggestion();
        self.cancel_generation(Some(before));
        self.work += 1;
        let delay = debounce::milliseconds(
            self.last_latency_ms,
            u64::from(settings.cotyping_debounce_ms),
            0,
        );
        self.due = Some((self.work, Instant::now() + Duration::from_millis(delay)));
    }

    fn request_suggestion(&mut self) {
        // This answers the newest read, including one that waited for the
        // server to start.
        self.pending = None;
        let settings = self.host.settings();
        let Some(field) = self.field.clone() else {
            return;
        };
        if !self.allowed(&settings, &field) {
            return;
        }
        // An explicit `:shortcode` wins over the model.
        if let Some(hit) = emoji::match_trailing(&field.before) {
            self.present(
                field.field_id,
                Session::new(
                    &field.before,
                    &field.after,
                    hit.glyph,
                    SuggestionKind::Emoji,
                ),
                String::new(),
                true,
            );
            return;
        }
        if !self.host.ready(&settings) {
            return;
        }
        let memory = self.memory_text(&field, &settings);
        let learned = self.learned_examples(&field);
        let used_context = memory.is_some() || field.visible_text.is_some();
        let Some(request) = build(
            &field,
            &settings,
            settings.cotyping_max_words,
            false,
            memory,
            learned,
        ) else {
            return;
        };
        let fingerprint = fingerprint(&request, &settings);
        let identity = identity(&field);
        let now = Instant::now();
        if let Some(restored) = self
            .anchors
            .restoration(&identity, &fingerprint, &field.before, now)
            .filter(|r| !ac::normalize::duplicates_trailing_text(&r.text, &field.after))
            .filter(|r| !self.is_acceptance_echo(&r.text, &field.before))
            .filter(|r| seam::verdict(&field.before, &r.text, |_| true) == seam::SeamVerdict::Allow)
        {
            let mut restored_session = Session::new(
                &field.before,
                &field.after,
                &restored.text,
                SuggestionKind::Continuation,
            );
            restored_session.open_ended = restored.open_ended;
            self.accepted_tail = None;
            self.present(field.field_id, restored_session, fingerprint, used_context);
            return;
        }
        self.launch(JobKind::Fresh {
            field,
            request,
            fingerprint,
            used_context,
        });
    }

    /// The newest saved facts for `field`, starting a lookup when the
    /// finished words could name something new.
    fn memory_text(&mut self, field: &FieldContext, settings: &Settings) -> Option<String> {
        let policy = Policy {
            meetings: settings.cotyping_use_meeting_memory,
            screen_derived: false,
        };
        if !policy.enabled() {
            self.memory.reset();
            return None;
        }
        let anchor = identity(field);
        let query = Query::for_field(
            memory::finished_words(&field.before),
            &field.window_title,
            field.visible_text.as_deref().unwrap_or(""),
            &field.app_name,
            &field.app_id,
        );
        if self.memory.needs_lookup(&anchor, &query) {
            self.memory.begin(&anchor, &query);
            if !query.all.is_empty() {
                let host = self.host.clone();
                let sender = self.sender.clone();
                let spawned = std::thread::Builder::new()
                    .name("lokalbot-autocomplete-memory".into())
                    .spawn(move || {
                        let selection = host.memory(&query, policy);
                        let _ = sender.send(Message::Memory {
                            anchor,
                            query,
                            selection,
                        });
                    });
                if let Err(err) = spawned {
                    log::warn!("autocomplete: could not look up saved facts: {err}");
                }
            }
        }
        self.memory.selection.text()
    }

    fn on_memory(&mut self, anchor: &str, query: &Query, selection: Selection) {
        let settings = self.host.settings();
        if !settings.cotyping_use_meeting_memory {
            return;
        }
        let changed = self.memory.finish(anchor, query, selection);
        // New facts change the prompt's start: read it ahead while nothing
        // else is asked for (after a prefill already running, if need be).
        let fresh_running = self.running.as_ref().is_some_and(|r| !r.prefill);
        if changed && self.shown.is_none() && !fresh_running && self.due.is_none() {
            self.prefill(&settings);
        }
    }

    /// Accepted completions from the same document, ranked on the finished
    /// words so a half-typed word does not reorder them.
    fn learned_examples(&mut self, field: &FieldContext) -> Vec<String> {
        let finished = memory::finished_words(&field.before).to_string();
        self.learning.examples(
            &place(field, &finished),
            LEARNED_EXAMPLES_IN_PROMPT,
            Instant::now(),
        )
    }

    /// Reads a field's prompt ahead of the first keystroke
    /// (`scheduleFocusPrewarm`), unless a request is already going to.
    fn prefill(&mut self, settings: &Settings) {
        if self.queued.is_some() || !self.host.ready(settings) {
            return;
        }
        let Some(field) = self.field.clone() else {
            return;
        };
        let memory = self.memory.selection.text();
        let learned = self.learned_examples(&field);
        if let Some(request) = build(
            &field,
            settings,
            settings.cotyping_max_words,
            true,
            memory,
            learned,
        ) {
            self.launch(JobKind::Prefill { request });
        }
    }

    /// Tops up the suggestion on screen when it is running short and was cut
    /// by the length limit (`extendSuggestionIfNeeded`).
    fn maybe_extend(&mut self, settings: &Settings) {
        if self.running.is_some() || self.queued.is_some() || self.due.is_some() {
            return;
        }
        let word_limit = settings.cotyping_max_words.max(1) as usize;
        let (Some(shown), Some(field)) = (self.shown.as_ref(), self.field.as_ref()) else {
            return;
        };
        if !session::should_extend(&shown.session, word_limit) || !self.host.ready(settings) {
            return;
        }
        let prefix = session::continuation_prefix(&shown.session);
        let mut continued = field.clone();
        continued.before = prefix.clone();
        continued.after = shown.session.after.clone();
        let (field_id, full_text) = (shown.field_id, shown.session.full_text.clone());
        let limit = session::top_up_word_limit(word_limit) as u32;
        // The same saved facts the suggestion was made with.
        let memory = self.memory.selection.text();
        let learned = self.learned_examples(&continued);
        let Some(request) = build(&continued, settings, limit, false, memory, learned) else {
            return;
        };
        self.launch(JobKind::TopUp {
            field_id,
            full_text,
            prefix,
            request,
        });
    }

    fn launch(&mut self, kind: JobKind) {
        if let Some(running) = &self.running {
            let before = match &kind {
                JobKind::Fresh { field, .. } => Some(field.before.as_str()),
                _ => None,
            };
            if running.superseded_by(before) {
                running.cancel.store(true, Ordering::Relaxed);
            }
            self.queued = Some(kind);
            return;
        }
        self.start(kind);
    }

    fn start(&mut self, kind: JobKind) {
        self.jobs += 1;
        let id = self.jobs;
        let cancel = Arc::new(AtomicBool::new(false));
        let prefill = matches!(kind, JobKind::Prefill { .. });
        let before = match &kind {
            JobKind::Fresh { field, .. } => Some(field.before.clone()),
            _ => None,
        };
        let host = self.host.clone();
        let sender = self.sender.clone();
        let flag = cancel.clone();
        let settings = self.host.settings();
        let spawned = std::thread::Builder::new()
            .name("lokalbot-autocomplete-request".into())
            .spawn(move || {
                let started = Instant::now();
                let outcome = host.run(&kind, &settings, &flag);
                let _ = sender.send(Message::Finished {
                    job: id,
                    kind,
                    outcome,
                    elapsed: started.elapsed(),
                });
            });
        match spawned {
            Ok(_) => {
                self.running = Some(Running {
                    id,
                    cancel,
                    prefill,
                    before,
                })
            }
            Err(err) => log::warn!("autocomplete: could not start a request: {err}"),
        }
    }

    fn on_finished(&mut self, job: u64, kind: JobKind, outcome: Outcome, elapsed: Duration) {
        if self.running.as_ref().is_some_and(|r| r.id == job) {
            self.running = None;
        }
        if let Outcome::Completion(completion) = outcome {
            let settings = self.host.settings();
            match kind {
                JobKind::Fresh {
                    field,
                    request: _,
                    fingerprint,
                    used_context,
                } => {
                    self.last_latency_ms = Some(elapsed.as_millis() as u64);
                    let timings = &completion.timings;
                    log::debug!(
                        "autocomplete: request took {:.0} ms (first token {:.0} ms, {} prompt tokens read, {} reused, {} generated{}){}",
                        elapsed.as_secs_f64() * 1000.0,
                        timings.first_token_ms.unwrap_or(f64::NAN),
                        timings.prompt_tokens.unwrap_or(0),
                        timings.cached_tokens.unwrap_or(0),
                        timings.predicted_tokens.unwrap_or(0),
                        if used_context { ", with context" } else { "" },
                        completion
                            .result
                            .suppression
                            .map(|r| format!(", no suggestion: {r:?}"))
                            .unwrap_or_default()
                    );
                    self.on_suggestion(&settings, field, &completion, fingerprint, used_context);
                }
                JobKind::TopUp {
                    field_id,
                    full_text,
                    prefix,
                    ..
                } => self.on_top_up(&settings, field_id, &full_text, &prefix, &completion),
                JobKind::Prefill { .. } => {}
            }
        }
        if self.running.is_none()
            && let Some(next) = self.queued.take()
        {
            self.start(next);
        }
        if self.running.is_none() {
            self.serve_pending();
        }
    }

    /// A request is on its way to a server that is not up yet: the server
    /// is starting, the first time or again after being unloaded.
    fn server_starting(&self) -> bool {
        (self.running.is_some() || self.queued.is_some()) && !self.host.server_running()
    }

    /// With nothing else in flight, answers the field read that arrived
    /// while the server was starting, now that it is up. Not if the field
    /// lost focus or the read was dismissed (both drop it), or a suggestion
    /// is on screen or due after the debounce.
    fn serve_pending(&mut self) {
        let Some(field_id) = self.pending.take() else {
            return;
        };
        let current = self.field.as_ref().is_some_and(|f| f.field_id == field_id);
        if current && self.shown.is_none() && self.due.is_none() && self.host.server_running() {
            self.request_suggestion();
        }
    }

    /// Validates a finished suggestion against the newest field read and
    /// shows it, or what is left of it when the user typed on.
    fn on_suggestion(
        &mut self,
        settings: &Settings,
        asked: FieldContext,
        completion: &Completion,
        fingerprint: String,
        used_context: bool,
    ) {
        let text = &completion.result.text;
        if let Some(reason) = completion.result.suppression {
            log::debug!("autocomplete: no suggestion ({reason:?})");
        }
        if text.is_empty() {
            return;
        }
        let Some(live) = self.field.clone().filter(|f| f.field_id == asked.field_id) else {
            return;
        };
        if !self.allowed(settings, &live)
            || self.is_acceptance_echo(text, &asked.before)
            || seam::verdict(&asked.before, text, |_| true) != seam::SeamVerdict::Allow
        {
            return;
        }
        let word_limit = settings.cotyping_max_words.max(1) as usize;
        let mut fresh = Session::new(
            &asked.before,
            &asked.after,
            text,
            SuggestionKind::Continuation,
        );
        fresh.open_ended = session::is_open_ended(text, word_limit);
        self.anchors.record(
            &identity(&asked),
            &fingerprint,
            &asked.before,
            text,
            fresh.open_ended,
            Instant::now(),
        );
        let current = match session::reconcile(&fresh, &live.before, &live.after) {
            Reconciled::Unchanged => fresh,
            Reconciled::Advanced(next) if !next.is_exhausted() => next,
            _ => return,
        };
        // A suggestion for the field as it is now: the pending request for
        // the keys typed meanwhile is not needed.
        self.cancel_pending();
        self.accepted_tail = None;
        self.present(asked.field_id, current, fingerprint, used_context);
    }

    fn on_top_up(
        &mut self,
        settings: &Settings,
        field_id: u64,
        full_text: &str,
        prefix: &str,
        completion: &Completion,
    ) {
        let word_limit = settings.cotyping_max_words.max(1) as usize;
        let Some(shown) = self.shown.as_mut() else {
            return;
        };
        if shown.field_id != field_id
            || shown.session.full_text != full_text
            || shown.session.kind != SuggestionKind::Continuation
            || shown.session.is_exhausted()
        {
            return;
        }
        let Some(addition) = session::addition(&completion.result.text, full_text) else {
            return;
        };
        if seam::verdict(prefix, &addition, |_| true) != seam::SeamVerdict::Allow {
            return;
        }
        shown.session.full_text.push_str(&addition);
        shown.session.open_ended =
            session::is_open_ended(&addition, session::top_up_word_limit(word_limit));
        let (identity_key, fingerprint) = (
            self.field.as_ref().map(identity).unwrap_or_default(),
            shown.fingerprint.clone(),
        );
        let (before, text, open_ended) = (
            shown.session.before.clone(),
            shown.session.full_text.clone(),
            shown.session.open_ended,
        );
        self.anchors.record(
            &identity_key,
            &fingerprint,
            &before,
            &text,
            open_ended,
            Instant::now(),
        );
        self.emit_suggestion();
        // Only a top-up that landed is followed up, so a refused one cannot loop.
        self.maybe_extend(settings);
    }

    fn is_acceptance_echo(&self, text: &str, before: &str) -> bool {
        self.accepted_tail
            .as_ref()
            .is_some_and(|(chunk, accepted_before)| {
                session::is_stale_acceptance_echo(text, chunk, before, accepted_before)
            })
    }

    // ----------------------------------------------------------- display

    fn present(
        &mut self,
        field_id: u64,
        session: Session,
        fingerprint: String,
        used_context: bool,
    ) {
        self.shown = Some(Shown {
            field_id,
            session,
            fingerprint,
            used_context,
        });
        self.emit_suggestion();
        self.note_activity();
    }

    fn emit_suggestion(&mut self) {
        let Some(shown) = &self.shown else {
            return;
        };
        let text = shown.session.remaining();
        if text.is_empty() {
            return;
        }
        self.host.emit(AutocompleteUpdate::Suggestion {
            field_id: shown.field_id,
            text: text.to_string(),
        });
        self.visible = true;
    }

    fn clear_suggestion(&mut self) {
        // What was accepted of the suggestion becomes one learned example.
        if let Some((place, text)) = self.batch.complete() {
            self.learning.record(&place, &text, Instant::now());
        }
        self.shown = None;
        self.last_activity = None;
        if self.visible {
            self.visible = false;
            self.host.emit(AutocompleteUpdate::Clear);
        }
    }

    fn note_activity(&mut self) {
        self.last_activity = Some(Instant::now());
    }

    /// A suggestion for the field as it is now is on screen: the pending
    /// request for the keys typed meanwhile is not needed.
    fn cancel_pending(&mut self) {
        self.due = None;
        if matches!(self.queued, Some(JobKind::Fresh { .. })) {
            self.queued = None;
        }
    }

    /// Drops the pending and in-flight suggestion requests that a field now
    /// reading `before` makes useless (all of them for `None`); a prefill
    /// goes on.
    fn cancel_generation(&mut self, before: Option<&str>) {
        self.due = None;
        if let Some(running) = &self.running
            && running.superseded_by(before)
        {
            running.cancel.store(true, Ordering::Relaxed);
        }
        if !matches!(self.queued, Some(JobKind::Prefill { .. })) {
            self.queued = None;
        }
    }

    fn cancel_all(&mut self) {
        self.due = None;
        self.queued = None;
        self.pending = None;
        if let Some(running) = &self.running {
            running.cancel.store(true, Ordering::Relaxed);
        }
    }
}

/// `CotypingAvailability.isExcluded`: a case-insensitive part of the app's
/// name or id.
fn is_excluded(list: &str, app_name: &str, app_id: &str) -> bool {
    let haystacks = [app_name.to_lowercase(), app_id.to_lowercase()];
    list.split(',')
        .map(|n| n.trim().to_lowercase())
        .filter(|n| !n.is_empty())
        .any(|needle| {
            haystacks
                .iter()
                .any(|h| !h.is_empty() && h.contains(&needle))
        })
}

fn build(
    field: &FieldContext,
    settings: &Settings,
    max_words: u32,
    prefill: bool,
    memory: Option<String>,
    learned_examples: Vec<String>,
) -> Option<Request> {
    let field = ac::Field {
        app_name: field.app_name.clone(),
        app_id: field.app_id.clone(),
        window_title: field.window_title.clone(),
        before: field.before.clone(),
        after: field.after.clone(),
        visible_text: field.visible_text.clone(),
        single_line: field.single_line,
    };
    let extras = Extras {
        memory,
        learned_examples,
        word_prefix_is_valid_word: true,
        allows_blank_prefix: prefill,
    };
    ac::build_request(
        &field,
        max_words.max(1),
        &Personalization::from_settings(settings),
        &extras,
    )
}

/// Where an accepted suggestion was written, for learning.
fn place(field: &FieldContext, before: &str) -> Place {
    Place {
        app_name: field.app_name.clone(),
        app_id: field.app_id.clone(),
        window_title: field.window_title.clone(),
        url: field.url.clone(),
        before: before.to_string(),
    }
}

/// Lines from recent meetings that a lookup may offer
/// (`CotypingMemoryContextProvider.meetingItems`): meetings the index finds
/// for the query's words or whose title the query names, newest first, at
/// most four. Notes, summary and outcomes are read fresh from the files.
fn meeting_items(
    library: &Library,
    query: &Query,
    now: chrono::DateTime<chrono::Utc>,
) -> Vec<memory::Item> {
    let Ok(meetings) = library.list_meetings() else {
        return Vec::new();
    };
    let mut eligible: Vec<_> = meetings
        .into_iter()
        .filter(|m| {
            m.is_own_work() && m.ended_at.is_some() && now - m.started_at <= memory::max_age()
        })
        .collect();
    eligible.sort_by_key(|m| std::cmp::Reverse(m.started_at));
    let hits: std::collections::HashSet<uuid::Uuid> =
        if query.search.is_empty() || eligible.is_empty() {
            Default::default()
        } else {
            let search = lokalbot_core::search::SearchQuery {
                text: query.search.join(" "),
                meeting_ids: Some(eligible.iter().map(|m| m.id).collect()),
                limit: 12,
                ..Default::default()
            };
            library
                .search_with_mode(&search, lokalbot_core::search::MatchMode::Any)
                .unwrap_or_default()
                .into_iter()
                .map(|hit| hit.meeting_id)
                .collect()
        };
    let mut items = Vec::new();
    let candidates = eligible
        .iter()
        .filter(|m| hits.contains(&m.id) || memory::names(&m.title, query).is_some())
        .take(4);
    for meeting in candidates {
        let folder = library.meeting_dir(meeting);
        let modified = |file: &str| {
            std::fs::metadata(folder.join(file))
                .and_then(|m| m.modified())
                .map(chrono::DateTime::<chrono::Utc>::from)
                .unwrap_or(meeting.started_at)
        };
        let mut sources: Vec<(String, chrono::DateTime<chrono::Utc>)> = Vec::new();
        if let Ok(notes) = library.notes(meeting)
            && !notes.trim().is_empty()
        {
            sources.push((bounded(notes), modified("notes.md")));
        }
        if let Ok(Some(summary)) = library.summary(meeting) {
            sources.push((bounded(summary), modified("summary.md")));
        }
        let outcomes_date = modified("outcomes.json");
        for text in library.outcome_search_texts(meeting).unwrap_or_default() {
            sources.push((text, outcomes_date));
        }
        for (index, (text, updated_at)) in sources.iter().enumerate() {
            for (line_number, line) in text.lines().enumerate() {
                let Some(fact) = memory::fact_line(line) else {
                    continue;
                };
                if memory::relevance(&fact, &meeting.title, query, true, false).is_none() {
                    continue;
                }
                items.push(memory::Item {
                    id: format!("{}:{index}:{line_number}", meeting.id),
                    title: meeting.title.clone(),
                    text: fact,
                    updated_at: *updated_at,
                    requires_meetings: true,
                    requires_screen_memory: false,
                    is_work_memory: false,
                });
            }
        }
    }
    items
}

/// Files are read up to 32 KB, as on macOS.
fn bounded(mut text: String) -> String {
    const LIMIT: usize = 32_768;
    if text.len() > LIMIT {
        let mut end = LIMIT;
        while !text.is_char_boundary(end) {
            end -= 1;
        }
        text.truncate(end);
    }
    text
}

/// Projects and goals from the overnight reviews a macOS library carries,
/// without those built from meetings that changed since.
fn work_memory_items(root: &std::path::Path) -> Vec<memory::Item> {
    lokalbot_core::evidence::read_work_memory(root)
        .map(|bytes| memory::work_memory_items(&bytes))
        .unwrap_or_default()
}

/// The field a cached suggestion belongs to (`suggestionAnchor`).
fn identity(field: &FieldContext) -> String {
    format!("{}\u{1f}{}", field.field_id, field.app_id)
}

/// What besides the text before the caret shaped a request
/// (`CotypingSuggestionCacheFingerprint`).
fn fingerprint(request: &Request, settings: &Settings) -> String {
    let mut hasher = DefaultHasher::new();
    settings.cotyping_built_in_model_id.hash(&mut hasher);
    request.conditioning_preface.hash(&mut hasher);
    request.after.hash(&mut hasher);
    request.multi_line.hash(&mut hasher);
    request.max_tokens.hash(&mut hasher);
    request.max_words.hash(&mut hasher);
    format!("{:016x}", hasher.finish())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::VecDeque;
    use std::sync::atomic::AtomicU64;

    use crossbeam_channel::Receiver;
    use lokalbot_ai::autocomplete::{Normalized, Timings, normalize};

    /// Answers each request with a canned model output, after `delay`.
    struct FakeHost {
        settings: Mutex<Settings>,
        events: Sender<AutocompleteUpdate>,
        recording: AtomicBool,
        ready: AtomicBool,
        replies: Mutex<VecDeque<String>>,
        delay: Duration,
        requests: Mutex<Vec<(String, String)>>,
        prompts: Mutex<Vec<String>>,
        stopped: AtomicBool,
        facts: Mutex<Vec<memory::Item>>,
        /// Whether the server is up; the first request waits `start_ms` for
        /// it to start.
        server_up: AtomicBool,
        start_ms: AtomicU64,
    }

    impl Host for FakeHost {
        fn settings(&self) -> Settings {
            self.settings.lock().clone()
        }
        fn emit(&self, update: AutocompleteUpdate) {
            let _ = self.events.send(update);
        }
        fn recording(&self) -> bool {
            self.recording.load(Ordering::Relaxed)
        }
        fn ready(&self, _: &Settings) -> bool {
            self.ready.load(Ordering::Relaxed)
        }
        fn server_running(&self) -> bool {
            self.server_up.load(Ordering::Relaxed)
        }
        fn run(&self, job: &JobKind, _: &Settings, cancel: &AtomicBool) -> Outcome {
            let (kind, request) = match job {
                JobKind::Fresh { request, .. } => ("fresh", request),
                JobKind::TopUp { request, .. } => ("top-up", request),
                JobKind::Prefill { request, .. } => ("prefill", request),
            };
            self.requests
                .lock()
                .push((kind.to_string(), request.prefix.clone()));
            self.prompts.lock().push(request.prompt.clone());
            if !self.server_up.load(Ordering::Relaxed) {
                let start = self.start_ms.load(Ordering::Relaxed);
                std::thread::sleep(Duration::from_millis(start));
                self.server_up.store(true, Ordering::Relaxed);
            }
            if kind == "prefill" {
                return Outcome::Prefilled;
            }
            std::thread::sleep(self.delay);
            if cancel.load(Ordering::Relaxed) {
                return Outcome::Cancelled;
            }
            let raw = self.replies.lock().pop_front().unwrap_or_default();
            Outcome::Completion(Box::new(Completion {
                result: normalize::normalize_detailed(&raw, request),
                raw,
                hit_limit: true,
                timings: Timings::default(),
            }))
        }
        fn stop_server(&self) {
            self.stopped.store(true, Ordering::Relaxed);
        }
        fn memory(&self, query: &Query, policy: Policy) -> Selection {
            memory::select(&self.facts.lock(), query, policy, chrono::Utc::now(), true)
        }
    }

    struct Harness {
        host: Arc<FakeHost>,
        events: Receiver<AutocompleteUpdate>,
        autocomplete: Autocomplete,
    }

    fn harness(replies: &[&str], delay_ms: u64) -> Harness {
        let (events_tx, events) = unbounded();
        let host = Arc::new(FakeHost {
            settings: Mutex::new(Settings {
                cotyping_enabled: true,
                cotyping_debounce_ms: 20,
                ..Settings::default()
            }),
            events: events_tx,
            recording: AtomicBool::new(false),
            ready: AtomicBool::new(true),
            replies: Mutex::new(replies.iter().map(|r| r.to_string()).collect()),
            delay: Duration::from_millis(delay_ms),
            requests: Mutex::new(Vec::new()),
            prompts: Mutex::new(Vec::new()),
            stopped: AtomicBool::new(false),
            facts: Mutex::new(Vec::new()),
            server_up: AtomicBool::new(true),
            start_ms: AtomicU64::new(0),
        });
        let autocomplete = Autocomplete::with_host(host.clone());
        Harness {
            host,
            events,
            autocomplete,
        }
    }

    fn context(field_id: u64, before: &str) -> FieldContext {
        FieldContext {
            field_id,
            app_name: "Text Editor".into(),
            app_id: "org.gnome.TextEditor".into(),
            before: before.into(),
            ..FieldContext::default()
        }
    }

    impl Harness {
        fn send(&self, context: FieldContext) {
            self.autocomplete
                .handle(AutocompleteCommand::Context(context));
        }

        fn type_text(&self, field_id: u64, before: &str) {
            self.send(context(field_id, before));
        }

        fn next(&self) -> Option<AutocompleteUpdate> {
            self.events.recv_timeout(Duration::from_millis(600)).ok()
        }

        fn quiet(&self, ms: u64) -> Vec<AutocompleteUpdate> {
            std::thread::sleep(Duration::from_millis(ms));
            self.events.try_iter().collect()
        }

        fn suggestion(&self) -> String {
            loop {
                match self.next() {
                    Some(AutocompleteUpdate::Suggestion { text, .. }) => return text,
                    Some(AutocompleteUpdate::Clear) => continue,
                    None => panic!("no suggestion"),
                }
            }
        }

        /// The server is not up: the next request takes `ms` to start it.
        fn server_down(&self, ms: u64) {
            self.host.start_ms.store(ms, Ordering::Relaxed);
            self.host.server_up.store(false, Ordering::Relaxed);
        }

        fn kinds(&self) -> Vec<String> {
            self.host
                .requests
                .lock()
                .iter()
                .map(|(k, _)| k.clone())
                .collect()
        }
    }

    fn shown(text: &str, field_id: u64) -> AutocompleteUpdate {
        AutocompleteUpdate::Suggestion {
            field_id,
            text: text.into(),
        }
    }

    #[test]
    fn typing_asks_for_a_suggestion_after_the_debounce() {
        let h = harness(&[" up on the timeline"], 0);
        h.type_text(1, "Hi Ana, I wanted to follow");
        // The first read of a field only prefills.
        assert_eq!(h.quiet(80), vec![]);
        h.type_text(1, "Hi Ana, I wanted to follow ");
        assert_eq!(h.suggestion(), "up on the timeline");
        assert_eq!(h.kinds(), ["prefill", "fresh"]);
    }

    #[test]
    fn typing_through_and_accepting_walk_the_suggestion() {
        let h = harness(&[" up on the timeline"], 0);
        h.type_text(1, "I wanted to");
        h.type_text(1, "I wanted to follow");
        assert_eq!(h.suggestion(), " up on the timeline");
        h.type_text(1, "I wanted to follow up");
        assert_eq!(h.next(), Some(shown(" on the timeline", 1)));
        h.autocomplete.handle(AutocompleteCommand::Accepted {
            field_id: 1,
            text: " on".into(),
        });
        assert_eq!(h.next(), Some(shown(" the timeline", 1)));
        // The field shows the accepted word: the same suggestion stays.
        h.type_text(1, "I wanted to follow up on");
        assert_eq!(h.next(), Some(shown(" the timeline", 1)));
        h.autocomplete.handle(AutocompleteCommand::Accepted {
            field_id: 1,
            text: " the timeline".into(),
        });
        assert_eq!(h.next(), Some(AutocompleteUpdate::Clear));
    }

    #[test]
    fn a_key_that_leaves_the_suggestion_takes_it_down() {
        let h = harness(&[" up on the timeline", " meeting"], 0);
        h.type_text(1, "I wanted to");
        h.type_text(1, "I wanted to follow");
        assert_eq!(h.suggestion(), " up on the timeline");
        h.type_text(1, "I wanted to follow t");
        assert_eq!(h.next(), Some(AutocompleteUpdate::Clear));
        assert_eq!(h.suggestion(), " meeting");
    }

    #[test]
    fn a_late_result_is_shown_only_if_the_field_still_continues_it() {
        let h = harness(&[" up on the timeline"], 150);
        h.type_text(1, "I wanted to");
        h.type_text(1, "I wanted to follow");
        std::thread::sleep(Duration::from_millis(60));
        // Typed the suggestion's first word while the model was busy.
        h.type_text(1, "I wanted to follow up");
        assert_eq!(h.suggestion(), " on the timeline");
        let h = harness(&[" up on the timeline", " soon"], 150);
        h.type_text(1, "I wanted to");
        h.type_text(1, "I wanted to follow");
        std::thread::sleep(Duration::from_millis(60));
        h.type_text(1, "I wanted to follow x");
        assert_eq!(h.suggestion(), " soon", "the stale result was dropped");
    }

    #[test]
    fn a_caret_move_clears_without_asking() {
        let h = harness(&[" up"], 0);
        h.type_text(1, "I wanted to");
        h.type_text(1, "I wanted to follow");
        assert_eq!(h.suggestion(), " up");
        let mut moved = context(1, "I wanted to fol");
        moved.after = "low".into();
        h.send(moved);
        assert_eq!(h.next(), Some(AutocompleteUpdate::Clear));
        assert_eq!(h.quiet(100), vec![]);
        assert_eq!(h.kinds(), ["prefill", "fresh"]);
    }

    #[test]
    fn a_read_while_the_server_starts_is_answered_once_it_is_up() {
        let h = harness(&[" up on the timeline"], 0);
        h.server_down(200);
        // A click into the text, then End, while the server starts.
        let mut clicked = context(1, "Hi Sarah, I wanted to");
        clicked.after = " follow".into();
        h.send(clicked);
        h.type_text(1, "Hi Sarah, I wanted to follow");
        assert_eq!(h.quiet(100), vec![]);
        assert_eq!(h.next(), Some(shown(" up on the timeline", 1)));
        assert_eq!(h.kinds(), ["prefill", "fresh"]);
        assert_eq!(h.host.requests.lock()[1].1, "Hi Sarah, I wanted to follow");
    }

    #[test]
    fn a_read_dismissed_while_the_server_starts_is_not_answered() {
        let h = harness(&[" up on the timeline"], 0);
        h.server_down(150);
        h.type_text(1, "Hi Sarah, I wanted to follow");
        h.autocomplete.handle(AutocompleteCommand::Dismiss);
        assert_eq!(h.quiet(300), vec![]);
        assert_eq!(h.kinds(), ["prefill"]);
    }

    #[test]
    fn only_the_field_focused_last_is_answered_once_the_server_is_up() {
        let h = harness(&[" up on the timeline"], 0);
        h.server_down(150);
        h.type_text(1, "Notes from the review");
        h.type_text(2, "Hi Sarah, I wanted to follow");
        assert_eq!(h.next(), Some(shown(" up on the timeline", 2)));
        assert_eq!(h.quiet(100), vec![]);
        assert_eq!(h.kinds(), ["prefill", "prefill", "fresh"]);
        assert_eq!(h.host.requests.lock()[2].1, "Hi Sarah, I wanted to follow");
    }

    #[test]
    fn typing_while_the_server_starts_asks_only_once() {
        let h = harness(&[" up on the timeline", " soon"], 0);
        h.server_down(150);
        h.type_text(1, "I wanted to");
        h.type_text(1, "I wanted to follow");
        assert_eq!(h.next(), Some(shown(" up on the timeline", 1)));
        assert_eq!(h.quiet(150), vec![]);
        assert_eq!(h.kinds(), ["prefill", "fresh"]);
    }

    #[test]
    fn dismiss_takes_the_suggestion_down() {
        let h = harness(&[" up"], 0);
        h.type_text(1, "I wanted to");
        h.type_text(1, "I wanted to follow");
        assert_eq!(h.suggestion(), " up");
        h.autocomplete.handle(AutocompleteCommand::Dismiss);
        assert_eq!(h.next(), Some(AutocompleteUpdate::Clear));
        assert_eq!(h.quiet(60), vec![]);
    }

    #[test]
    fn nothing_runs_when_off_excluded_recording_or_without_the_model() {
        let h = harness(&[" up"], 0);
        h.host.settings.lock().cotyping_enabled = false;
        h.type_text(1, "I wanted to");
        h.type_text(1, "I wanted to follow");
        h.host.settings.lock().cotyping_enabled = true;
        let mut excluded = context(2, "secret");
        excluded.app_name = "KeePassXC".into();
        h.send(excluded.clone());
        excluded.before = "secret t".into();
        h.send(excluded);
        let mut terminal = context(5, "cargo bui");
        terminal.app_id = "org.gnome.Console".into();
        terminal.app_name = "Console".into();
        h.send(terminal.clone());
        terminal.before = "cargo buil".into();
        h.send(terminal);
        h.host.recording.store(true, Ordering::Relaxed);
        h.type_text(3, "I wanted to");
        h.type_text(3, "I wanted to follow");
        h.host.recording.store(false, Ordering::Relaxed);
        h.host.ready.store(false, Ordering::Relaxed);
        h.type_text(4, "I wanted to");
        h.type_text(4, "I wanted to follow");
        assert_eq!(h.quiet(120), vec![]);
        assert!(h.kinds().is_empty());
    }

    #[test]
    fn an_emoji_shortcode_wins_over_the_model() {
        let h = harness(&[], 0);
        h.type_text(1, "Ship it");
        h.type_text(1, "Ship it :roc");
        assert_eq!(h.suggestion(), "🚀");
        assert_eq!(h.kinds(), ["prefill"]);
        h.autocomplete.handle(AutocompleteCommand::Accepted {
            field_id: 1,
            text: "🚀".into(),
        });
        assert_eq!(h.next(), Some(AutocompleteUpdate::Clear));
    }

    #[test]
    fn accepting_tops_the_suggestion_up_once_two_words_are_left() {
        let h = harness(&[" between the number", " of menu items"], 0);
        h.host.settings.lock().cotyping_max_words = 3;
        h.type_text(1, "The main tradeoff");
        h.type_text(1, "The main tradeoff is");
        assert_eq!(h.suggestion(), " between the number");
        h.autocomplete.handle(AutocompleteCommand::Accepted {
            field_id: 1,
            text: " between".into(),
        });
        assert_eq!(h.next(), Some(shown(" the number", 1)));
        // A top-up asks for one word fewer than a fresh suggestion.
        assert_eq!(h.next(), Some(shown(" the number of menu", 1)));
        let requests = h.host.requests.lock().clone();
        assert_eq!(
            requests.last().map(|(k, p)| (k.as_str(), p.as_str())),
            Some(("top-up", "The main tradeoff is between the number"))
        );
    }

    #[test]
    fn backspace_brings_back_the_earlier_suggestion_without_the_model() {
        let h = harness(&[" up on the timeline", " zzz"], 0);
        h.type_text(1, "I wanted to");
        h.type_text(1, "I wanted to follow");
        assert_eq!(h.suggestion(), " up on the timeline");
        h.type_text(1, "I wanted to followx");
        assert_eq!(h.next(), Some(AutocompleteUpdate::Clear));
        let _ = h.suggestion();
        h.type_text(1, "I wanted to follow");
        assert_eq!(h.suggestion(), " up on the timeline");
        assert_eq!(h.kinds(), ["prefill", "fresh", "fresh"]);
    }

    #[test]
    fn turning_autocomplete_off_clears_and_stops_the_server() {
        let h = harness(&[" up"], 0);
        h.type_text(1, "I wanted to");
        h.type_text(1, "I wanted to follow");
        assert_eq!(h.suggestion(), " up");
        h.host.settings.lock().cotyping_enabled = false;
        h.autocomplete.settings_changed();
        assert_eq!(h.next(), Some(AutocompleteUpdate::Clear));
        std::thread::sleep(Duration::from_millis(20));
        assert!(h.host.stopped.load(Ordering::Relaxed));
    }

    #[test]
    fn saved_facts_join_the_prompt_only_with_their_grant() {
        let h = harness(&[" is due by Thursday", " is due by Thursday"], 0);
        *h.host.facts.lock() = vec![memory::Item {
            id: "m:1".into(),
            title: "Laptop refresh planning".into(),
            text: "A business quote is due by Thursday.".into(),
            updated_at: chrono::Utc::now(),
            requires_meetings: true,
            requires_screen_memory: false,
            is_work_memory: false,
        }];
        h.type_text(1, "Status on the Laptop refresh: the business quote");
        h.type_text(1, "Status on the Laptop refresh: the business quote ");
        assert_eq!(h.suggestion(), "is due by Thursday");
        assert!(
            h.host
                .prompts
                .lock()
                .iter()
                .all(|p| !p.contains("saved facts"))
        );

        h.host.settings.lock().cotyping_use_meeting_memory = true;
        h.type_text(2, "Status on the Laptop refresh: the business quote");
        std::thread::sleep(Duration::from_millis(60));
        h.type_text(2, "Status on the Laptop refresh: the business quote ");
        assert_eq!(h.suggestion(), "is due by Thursday");
        let prompts = h.host.prompts.lock().clone();
        assert!(
            prompts.last().unwrap().starts_with(
                "Topic: Laptop refresh\nRelevant saved facts: A business quote is due by Thursday."
            ) || prompts
                .last()
                .unwrap()
                .starts_with("Relevant saved facts: A business quote is due by Thursday."),
            "{:?}",
            prompts.last()
        );
    }

    #[test]
    fn accepted_text_in_an_identified_document_is_learned_in_memory() {
        let h = harness(&[" the retention playbook first", " soon"], 0);
        let doc = |before: &str| FieldContext {
            field_id: 7,
            app_name: "Firefox".into(),
            app_id: "firefox".into(),
            window_title: "Q3 plan - Google Docs — Mozilla Firefox".into(),
            url: Some("https://docs.google.com/document/d/abc123/edit".into()),
            before: before.into(),
            ..FieldContext::default()
        };
        let first = "Churn in the enterprise segment grew, so we should prioritize";
        h.send(doc("Churn in the enterprise segment grew, so we should"));
        h.send(doc(first));
        assert_eq!(h.suggestion(), " the retention playbook first");
        h.autocomplete.handle(AutocompleteCommand::Accepted {
            field_id: 7,
            text: " the retention playbook first".into(),
        });
        assert_eq!(h.next(), Some(AutocompleteUpdate::Clear));
        h.send(doc(&format!(
            "{first} the retention playbook first.\n\nFor the enterprise segment churn"
        )));
        let _ = h.suggestion();
        let prompts = h.host.prompts.lock().clone();
        assert!(
            prompts
                .last()
                .unwrap()
                .contains("Previously accepted completion: the retention playbook first"),
            "{:?}",
            prompts.last()
        );
    }

    #[test]
    fn excluded_apps_match_names_and_ids() {
        assert!(is_excluded(
            "1Password, KeePassXC",
            "KeePassXC",
            "keepassxc"
        ));
        assert!(is_excluded("bitwarden", "", "com.bitwarden.desktop"));
        assert!(!is_excluded("1Password", "LokalBot", "lokalbot"));
        assert!(!is_excluded(" , ", "Anything", "x"));
        let _ = Normalized::shown("");
    }
}
