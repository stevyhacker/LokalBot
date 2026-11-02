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
//! without the Autocomplete model and the llama.cpp runtime, or a server the
//! user set up and approved, no suggestion is made. Suggestions pause while a
//! meeting records, and the excluded apps are checked again here. Typed text
//! stays in memory and is never logged. What stays on disk is counts (see
//! `autocomplete_measure`) and, when on, examples sealed under a key in the
//! credential store (`LearningStore`).

use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use crossbeam_channel::{Receiver, RecvTimeoutError, Sender, unbounded};
use parking_lot::Mutex;

use lokalbot_ai::autocomplete::learning::{self, AcceptedBatch, LearningStore, Place};
use lokalbot_ai::autocomplete::memory::{self, Lookup, MemoryGuard, Policy, Query, Selection};
use lokalbot_ai::autocomplete::server::{self, Route, ServerMemory, ServerProblem};
use lokalbot_ai::autocomplete::surface::SurfaceClass;
use lokalbot_ai::autocomplete::typo::{SpellSource, Speller, TypoDecision};
use lokalbot_ai::autocomplete::window_text::{self, Capture, Frame, Snapshot, Ticket};
use lokalbot_ai::autocomplete::{
    self as ac, Completer, Completion, Extras, Personalization, Reconciled, Request, Session,
    SuggestionKind, clipboard, debounce, emoji, macros, seam, session,
};
use lokalbot_ai::catalog::{self, ModelKind};
use lokalbot_core::cotyping_stats::{self, CotypingStats, UsageHistory};
use lokalbot_core::settings::CotypingBackend;
use lokalbot_core::{Library, Settings};
use lokalbot_platform::autocomplete::clipboard::ClipboardReader;
use lokalbot_platform::autocomplete::policy::ReadPolicy;
use lokalbot_platform::autocomplete::spell::SpellChecker;
use lokalbot_platform::privacy::SELF_APP_ID;

use crate::autocomplete_measure::Measures;
use crate::autocomplete_window_text::{WindowRead, WindowReader, WindowRequest};
use crate::models::{Models, RUNTIME_ID};
use crate::{
    AutocompleteCommand, AutocompleteLearning, AutocompleteMeasures, AutocompleteUpdate,
    EngineEvent, FieldContext, Shared,
};

/// A suggestion left alone this long is taken down, so a Tab pressed long
/// afterwards reaches the app (`idleSuggestionLifetimeMilliseconds`).
const IDLE_SUGGESTION_LIFETIME: Duration = Duration::from_secs(60);

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
    fn memory(&self, query: &Query, policy: Policy) -> Lookup;
    /// Whether a focused field's prompt can be read ahead: not on a server.
    fn prefills(&self, _settings: &Settings) -> bool {
        true
    }
    /// The clipboard now, unless concealed. Blocks only briefly.
    fn clipboard(&self) -> Option<clipboard::Snapshot> {
        None
    }
    /// The clipboard grant was withdrawn: let go of what is held.
    fn forget_clipboard(&self) {}
    /// The system's spell checker, once asked for.
    fn speller(&self) -> Option<Arc<Speller>> {
        None
    }
    /// The on-device text recognition model is installed.
    fn window_text_ready(&self) -> bool {
        false
    }
    /// Reads the focused window. Blocking; called on a thread of its own.
    fn read_window(&self, _request: &WindowRequest) -> Option<WindowRead> {
        None
    }
    /// Lets go of window text held for reuse, and with `unload` the model.
    fn forget_window(&self, _unload: bool) {}
    /// Opens the learned examples. Blocking; called on a thread of its own.
    fn open_learning(&self) -> LearningOpen {
        LearningOpen::Loaded(learning::Snapshot::default())
    }
    /// Queues a write of the learned examples.
    fn save_learning(&self, _snapshot: learning::Snapshot) {}
    /// Deletes the file after any queued writes, then reports whether it worked.
    fn forget_learning(&self, done: Box<dyn FnOnce(bool) + Send>) {
        done(true);
    }
    fn load_measures(&self) -> (CotypingStats, UsageHistory) {
        Default::default()
    }
    /// Queues a write of the counters.
    fn save_measures(&self, _stats: CotypingStats, _usage: Option<UsageHistory>) {}
    /// Queues the removal of the counters' files.
    fn remove_measures(&self, _stats: bool, _usage: bool) {}
    /// Waits for queued writes.
    fn flush(&self) {}
}

/// What opening the learned examples found. If they cannot be opened they are
/// left alone: nothing is written over them (the Mac reads them as empty and
/// later overwrites them).
#[derive(Clone, Debug, PartialEq)]
pub(crate) enum LearningOpen {
    Loaded(learning::Snapshot),
    /// Why not, worded for Settings.
    Blocked(String),
}

/// One queued write, in order.
enum Write {
    Stats(CotypingStats),
    Usage(UsageHistory),
    RemoveStats,
    RemoveUsage,
    Learning(learning::Snapshot),
    ForgetLearning(Box<dyn FnOnce(bool) + Send>),
    Flush(Sender<()>),
}

/// Writes off the worker, one at a time, so typing never waits on the disk or
/// the credential store.
fn start_writer(shared: Arc<Shared>) -> Option<Sender<Write>> {
    let (writes, receiver) = unbounded::<Write>();
    std::thread::Builder::new()
        .name("lokalbot-autocomplete-store".into())
        .spawn(move || {
            let root = shared.library.paths().root().to_path_buf();
            // A write that failed stays memory-only until "Forget learned text".
            let mut learning_failed = false;
            while let Ok(write) = receiver.recv() {
                let result = match write {
                    Write::Stats(stats) => cotyping_stats::save_stats(&root, &stats),
                    Write::Usage(usage) => cotyping_stats::save_usage(&root, &usage),
                    Write::RemoveStats => {
                        cotyping_stats::remove_stats(&root).map_err(anyhow::Error::from)
                    }
                    Write::RemoveUsage => {
                        cotyping_stats::remove_usage(&root).map_err(anyhow::Error::from)
                    }
                    Write::Learning(snapshot) => {
                        if learning_failed {
                            continue;
                        }
                        let saved = save_learning_file(&root, &snapshot);
                        if let Err(err) = &saved {
                            learning_failed = true;
                            log::warn!("autocomplete: could not save learned examples: {err:#}");
                            shared.emit(EngineEvent::Autocomplete(AutocompleteUpdate::Learning(
                                AutocompleteLearning {
                                    problem: Some(learning_blocked_message()),
                                    ..AutocompleteLearning::default()
                                },
                            )));
                        }
                        saved
                    }
                    Write::ForgetLearning(done) => {
                        let path = root.join(learning::FILE_NAME);
                        let removed = !matches!(
                            std::fs::remove_file(&path),
                            Err(err) if err.kind() != std::io::ErrorKind::NotFound
                        );
                        if removed {
                            learning_failed = false;
                        }
                        done(removed);
                        continue;
                    }
                    Write::Flush(done) => {
                        let _ = done.send(());
                        continue;
                    }
                };
                if let Err(err) = result {
                    log::warn!("autocomplete: could not save: {err:#}");
                }
            }
        })
        .map_err(|err| log::warn!("could not start autocomplete's store: {err}"))
        .ok()?;
    Some(writes)
}

fn save_learning_file(root: &std::path::Path, snapshot: &learning::Snapshot) -> anyhow::Result<()> {
    let key = crate::secrets::cotyping_learning_key(true)?;
    let sealed = lokalbot_core::screen::seal_image(&key, &serde_json::to_vec(snapshot)?)?;
    lokalbot_core::library::write_atomic(&root.join(learning::FILE_NAME), &sealed)?;
    Ok(())
}

fn learning_blocked_message() -> String {
    lokalbot_i18n::tr(
        "Learned text can't be opened here, so it is left as it is and new learning stays in memory until LokalBot quits.",
    )
    .to_string()
}

/// Opens `<root>/cotyping-learning.enc`. A missing file needs no key, so the
/// credential store is not touched until there is something to keep.
fn open_learning_file(root: &std::path::Path) -> LearningOpen {
    let path = root.join(learning::FILE_NAME);
    let sealed = match std::fs::read(&path) {
        Ok(sealed) => sealed,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => {
            return LearningOpen::Loaded(learning::Snapshot::default());
        }
        Err(_) => return LearningOpen::Blocked(learning_blocked_message()),
    };
    open_sealed_learning(&sealed, crate::secrets::cotyping_learning_key(false).ok())
}

/// A file this key cannot open, such as one a Mac sealed with its own
/// Keychain key, or that does not parse, is left alone rather than read as
/// empty and overwritten.
fn open_sealed_learning(sealed: &[u8], key: Option<[u8; 32]>) -> LearningOpen {
    let opened = key
        .and_then(|key| lokalbot_core::screen::open_image(&key, sealed).ok())
        .and_then(|plain| serde_json::from_slice::<learning::Snapshot>(&plain).ok());
    match opened {
        Some(snapshot) => LearningOpen::Loaded(snapshot),
        None => LearningOpen::Blocked(learning_blocked_message()),
    }
}

/// The platform's spell checker as the rules see it.
struct SystemSpelling(SpellChecker);

impl SpellSource for SystemSpelling {
    fn languages(&self) -> Vec<String> {
        self.0.languages()
    }

    fn is_typo(&self, word: &str) -> bool {
        self.0.is_typo(word)
    }

    fn guesses(&self, word: &str) -> Vec<String> {
        self.0.guesses(word)
    }

    fn is_completable_prefix(&self, word: &str) -> bool {
        self.0.is_completable_prefix(word)
    }
}

/// The engine side of [`Host`].
struct EngineHost {
    shared: Arc<Shared>,
    models: Models,
    /// Failures are logged once until a request succeeds again.
    failing: Mutex<bool>,
    writes: Option<Sender<Write>>,
    clipboard: Mutex<ClipboardReader>,
    speller: Mutex<Option<Arc<Speller>>>,
    window: Mutex<WindowReader>,
    server_memory: ServerMemory,
    server_problem: Mutex<Option<ServerProblem>>,
}

impl Host for EngineHost {
    fn settings(&self) -> Settings {
        self.shared.settings()
    }

    fn emit(&self, update: AutocompleteUpdate) {
        match update {
            AutocompleteUpdate::Suggestion { .. } => self
                .shared
                .autocomplete_visible
                .store(true, Ordering::Relaxed),
            AutocompleteUpdate::Clear => self
                .shared
                .autocomplete_visible
                .store(false, Ordering::Relaxed),
            _ => {}
        }
        self.shared.emit(EngineEvent::Autocomplete(update));
    }

    fn recording(&self) -> bool {
        self.shared.recording_active.load(Ordering::Relaxed)
    }

    fn ready(&self, settings: &Settings) -> bool {
        match server::route(settings, None) {
            Route::Server(_) => true,
            Route::Unavailable(_) => false,
            Route::OnDevice => model_entry(settings).is_some_and(|entry| {
                self.models.is_installed(entry.id) && self.models.is_installed(RUNTIME_ID)
            }),
        }
    }

    fn server_running(&self) -> bool {
        // A chosen server is up as far as anyone here can tell: nothing waits
        // for it to start.
        if self.shared.settings().cotyping_backend != CotypingBackend::OnDevice {
            return true;
        }
        self.shared
            .runtime
            .server(lokalbot_ai::runtime::Role::Autocomplete)
            .status()
            .running
    }

    fn prefills(&self, settings: &Settings) -> bool {
        settings.cotyping_backend == CotypingBackend::OnDevice
    }

    fn clipboard(&self) -> Option<clipboard::Snapshot> {
        let read = self.clipboard.lock().read()?;
        Some(clipboard::Snapshot {
            count: read.change_count,
            text: read.text,
        })
    }

    fn forget_clipboard(&self) {
        self.clipboard.lock().forget();
    }

    fn speller(&self) -> Option<Arc<Speller>> {
        let mut speller = self.speller.lock();
        Some(
            speller
                .get_or_insert_with(|| {
                    Arc::new(Speller::new(Arc::new(
                        SystemSpelling(SpellChecker::start()),
                    )))
                })
                .clone(),
        )
    }

    fn window_text_ready(&self) -> bool {
        lokalbot_ai::ocr::is_ready(self.shared.library.paths())
    }

    fn read_window(&self, request: &WindowRequest) -> Option<WindowRead> {
        self.window
            .lock()
            .read(self.shared.library.paths(), request)
    }

    fn forget_window(&self, unload: bool) {
        let mut window = self.window.lock();
        if unload {
            window.unload();
            // Autocomplete stopped: the dictionaries need not stay in memory.
            *self.speller.lock() = None;
        } else {
            window.forget();
        }
    }

    fn open_learning(&self) -> LearningOpen {
        open_learning_file(self.shared.library.paths().root())
    }

    fn save_learning(&self, snapshot: learning::Snapshot) {
        self.write(Write::Learning(snapshot));
    }

    fn forget_learning(&self, done: Box<dyn FnOnce(bool) + Send>) {
        match &self.writes {
            Some(writes) => {
                if let Err(err) = writes.send(Write::ForgetLearning(done))
                    && let Write::ForgetLearning(done) = err.0
                {
                    done(false);
                }
            }
            None => done(false),
        }
    }

    fn load_measures(&self) -> (CotypingStats, UsageHistory) {
        cotyping_stats::load(self.shared.library.paths().root())
    }

    fn save_measures(&self, stats: CotypingStats, usage: Option<UsageHistory>) {
        self.write(Write::Stats(stats));
        if let Some(usage) = usage {
            self.write(Write::Usage(usage));
        }
    }

    fn remove_measures(&self, stats: bool, usage: bool) {
        if stats {
            self.write(Write::RemoveStats);
        }
        if usage {
            self.write(Write::RemoveUsage);
        }
    }

    fn flush(&self) {
        let (done, finished) = crossbeam_channel::bounded(1);
        self.write(Write::Flush(done));
        let _ = finished.recv_timeout(Duration::from_secs(2));
    }

    fn run(&self, job: &JobKind, settings: &Settings, cancel: &AtomicBool) -> Outcome {
        let keys = server::Keys {
            think: &crate::secrets::openai_api_key,
            server: &crate::secrets::autocomplete_server_api_key,
        };
        match server::route(settings, Some(&keys)) {
            Route::OnDevice => {}
            Route::Unavailable(_) => return Outcome::NotReady,
            Route::Server(endpoint) => return self.run_on_server(&endpoint, job, cancel),
        }
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
                let generating = &self.shared.autocomplete_generating;
                generating.store(true, Ordering::Relaxed);
                let completed = completer.complete(request, &|| cancel.load(Ordering::Relaxed));
                generating.store(false, Ordering::Relaxed);
                match completed {
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

    fn memory(&self, query: &Query, policy: Policy) -> Lookup {
        look_up_guarded(&self.shared.library, query, policy)
    }
}

impl EngineHost {
    fn write(&self, write: Write) {
        if let Some(writes) = &self.writes {
            let _ = writes.send(write);
        }
    }

    /// Autocomplete on a chosen server. Nothing is read ahead: a server keeps
    /// its own cache.
    fn run_on_server(
        &self,
        endpoint: &server::Endpoint,
        job: &JobKind,
        cancel: &AtomicBool,
    ) -> Outcome {
        let request = match job {
            JobKind::Prefill { .. } => return Outcome::Prefilled,
            JobKind::Fresh { request, .. } | JobKind::TopUp { request, .. } => request,
        };
        match server::complete(endpoint, request, cancel, &self.server_memory) {
            Ok((completion, failure)) => {
                self.report_problem(endpoint, failure);
                *self.failing.lock() = false;
                Outcome::Completion(Box::new(completion))
            }
            Err(err) if err.downcast_ref::<ac::Cancelled>().is_some() => Outcome::Cancelled,
            Err(err) => {
                self.report_problem(endpoint, server::failure_of(&err));
                self.failed(&err)
            }
        }
    }

    /// Publishes only a change, so a working server does not redraw Settings
    /// on every suggestion.
    fn report_problem(&self, endpoint: &server::Endpoint, failure: Option<server::Failure>) {
        let problem = failure.map(|failure| ServerProblem {
            identity: endpoint.identity(),
            model: endpoint.model.clone(),
            failure,
        });
        let mut last = self.server_problem.lock();
        if *last != problem {
            last.clone_from(&problem);
            self.emit(AutocompleteUpdate::ServerProblem(problem));
        }
    }
}

/// `CotypingMemoryContextProvider.load`: the facts the grants allow,
/// selected for `query`.
pub(crate) fn look_up(library: &Library, query: &Query, policy: Policy) -> Selection {
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

/// `CotypingMemoryContextProvider.load` with the stamps that later tell
/// whether its facts still hold. Sources are stamped before they are read, so
/// an edit made while reading still shows.
fn look_up_guarded(library: &Library, query: &Query, policy: Policy) -> Lookup {
    if !policy.enabled() || query.all.is_empty() {
        return Lookup::default();
    }
    let root = library.paths().root();
    let now = chrono::Utc::now();
    let mut paths: Vec<std::path::PathBuf> = [
        lokalbot_core::evidence::EVIDENCE_FILE,
        lokalbot_core::evidence::MEMORY_FILE,
        lokalbot_core::evidence::PENDING_FILE,
    ]
    .iter()
    .map(|file| root.join(file))
    .collect();
    let meetings = if policy.meetings {
        meeting_candidates(library, query, now)
    } else {
        Vec::new()
    };
    for meeting in &meetings {
        let folder = library.meeting_dir(meeting);
        for file in MEETING_SOURCE_FILES {
            paths.push(folder.join(file));
        }
    }
    let guard = MemoryGuard::stamp(policy, root, paths);
    // Unattributed memory never reaches here; an unfinished revocation reads
    // as nothing at all.
    let mut items = work_memory_items(root);
    items.extend(items_from_meetings(library, &meetings, query));
    let lookup = Lookup {
        selection: memory::select(&items, query, policy, now, true),
        guard,
    };
    if lookup.is_current(policy) {
        lookup
    } else {
        Lookup::default()
    }
}

/// The files a meeting's facts depend on (`meetingItems`).
const MEETING_SOURCE_FILES: [&str; 7] = [
    "meta.json",
    "summary.md",
    "notes.md",
    "outcomes.json",
    "outcome-state.json",
    "transcript.json",
    "follow-up-draft.json",
];

/// The memory search for `field` as autocomplete makes it: only the grants'
/// words, nothing for integrated terminals, no title without the app context
/// grant.
fn query_for(field: &FieldContext, settings: &Settings, visible: &str) -> Query {
    if field.integrated_terminal {
        return Query::default();
    }
    let title = if settings.cotyping_use_app_context {
        field.window_title.as_str()
    } else {
        ""
    };
    Query::for_field(
        memory::finished_words(&field.before),
        title,
        visible,
        &field.app_name,
        &field.app_id,
    )
}

/// The saved facts a suggestion in `field` would use now, as (source title,
/// fact): for diagnostics and the practice editor's "what shaped this"
/// (`memoryContextSources`). Reads the library; empty without the grant.
pub fn saved_facts(
    library: &Library,
    field: &FieldContext,
    settings: &Settings,
) -> Vec<(String, String)> {
    let policy = Policy::from_settings(settings);
    let query = query_for(field, settings, field.visible_text.as_deref().unwrap_or(""));
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
        guard: Option<Arc<MemoryGuard>>,
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
        lookup: Lookup,
    },
    WindowText {
        ticket: Ticket,
        key: String,
        snapshot: Option<Snapshot>,
    },
    LearningOpened {
        generation: u64,
        open: LearningOpen,
    },
    LearningForgotten(bool),
    Stop,
}

/// Handle to the autocomplete worker thread.
pub struct Autocomplete {
    sender: Sender<Message>,
    thread: Option<JoinHandle<()>>,
}

impl Autocomplete {
    pub(crate) fn start(shared: Arc<Shared>, models: Models) -> Self {
        let writes = start_writer(shared.clone());
        Self::with_host(Arc::new(EngineHost {
            shared,
            models,
            failing: Mutex::new(false),
            writes,
            clipboard: Mutex::new(ClipboardReader::new()),
            speller: Mutex::new(None),
            window: Mutex::new(WindowReader::default()),
            server_memory: ServerMemory::default(),
            server_problem: Mutex::new(None),
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
    /// The saved facts it was made with, when any.
    guard: Option<Arc<MemoryGuard>>,
}

/// Whether the learned examples are usable.
#[derive(Clone, Debug, PartialEq, Eq)]
enum LearningState {
    /// Nothing has needed them yet.
    Closed,
    Opening,
    Ready,
    /// They could not be opened: stays in memory and never writes.
    Blocked(String),
}

/// The newest saved-memory lookup for the focused field
/// (`CotypingMemoryLookup`): a keystroke never waits for one; it takes the
/// newest finished one, and a new lookup runs when the finished words
/// before the caret could name something new.
#[derive(Default)]
struct MemoryLookup {
    anchor: Option<String>,
    requested: Option<Query>,
    lookup: Lookup,
}

impl MemoryLookup {
    fn needs_lookup(&self, anchor: &str, query: &Query) -> bool {
        self.anchor.as_deref() != Some(anchor) || self.requested.as_ref() != Some(query)
    }

    /// A different field forgets the previous field's facts at once.
    fn begin(&mut self, anchor: &str, query: &Query) {
        if self.anchor.as_deref() != Some(anchor) {
            self.lookup = Lookup::default();
        }
        self.anchor = Some(anchor.to_string());
        self.requested = Some(query.clone());
    }

    /// Keeps a finished lookup only if it is still the one asked for last.
    fn finish(&mut self, anchor: &str, query: &Query, lookup: Lookup) -> bool {
        if self.anchor.as_deref() != Some(anchor) || self.requested.as_ref() != Some(query) {
            return false;
        }
        let changed = self.lookup.selection != lookup.selection;
        self.lookup = lookup;
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
    learning_state: LearningState,
    /// Bumped when the examples in memory are dropped, so an open still
    /// running cannot bring them back.
    learning_generation: u64,
    forgetting: bool,
    forgotten: Option<bool>,
    /// What has been accepted of the suggestion on screen.
    batch: AcceptedBatch,
    /// Something was accepted since the suggestion went up.
    accepted_any: bool,
    /// Autocomplete was on at the last settings change.
    enabled: bool,
    /// The settings that say what may be read and used, as last applied.
    privacy: Option<PrivacySettings>,
    measures: Measures,
    clipboard: clipboard::Preface,
    window_text: Capture,
    /// The saved facts the suggestion in the works or on screen uses.
    active_memory: Option<Arc<MemoryGuard>>,
    /// The text around the field shaped it.
    active_visible: bool,
    /// The last memory use told to Settings.
    memory_use: (Vec<String>, bool),
}

/// `CotypingPrivacySettings`: a change here cancels work and drops what was
/// read or shaped under the old settings.
#[derive(Clone, Debug, PartialEq, Eq)]
struct PrivacySettings {
    read: ReadPolicy,
    memory: Policy,
}

impl PrivacySettings {
    fn of(settings: &Settings) -> Self {
        Self {
            read: ReadPolicy::from_settings(settings, settings.cotyping_enabled),
            memory: Policy::from_settings(settings),
        }
    }
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
            learning_state: LearningState::Closed,
            learning_generation: 0,
            forgetting: false,
            forgotten: None,
            batch: AcceptedBatch::default(),
            accepted_any: false,
            enabled: false,
            privacy: None,
            measures: Measures::new(CotypingStats::default(), UsageHistory::default()),
            clipboard: clipboard::Preface::default(),
            window_text: Capture::default(),
            active_memory: None,
            active_visible: false,
            memory_use: (Vec::new(), false),
        }
    }

    fn run(mut self, receiver: Receiver<Message>) {
        let settings = self.host.settings();
        self.enabled = settings.cotyping_enabled;
        self.privacy = Some(PrivacySettings::of(&settings));
        let (stats, usage) = self.host.load_measures();
        self.measures = Measures::new(stats, usage);
        self.emit_measures();
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
                        lookup,
                    } => self.on_memory(&anchor, &query, lookup),
                    Message::WindowText {
                        ticket,
                        key,
                        snapshot,
                    } => self.on_window_text(ticket, &key, snapshot),
                    Message::LearningOpened { generation, open } => {
                        self.on_learning_opened(generation, open)
                    }
                    Message::LearningForgotten(ok) => self.on_learning_forgotten(ok),
                    Message::Stop => {
                        self.shut_down();
                        return;
                    }
                }
            }
            self.on_tick(Instant::now());
        }
        self.shut_down();
    }

    /// The last writes, and nothing left waiting.
    fn shut_down(&mut self) {
        self.cancel_all();
        self.persist();
        self.host.flush();
    }

    fn deadline(&self) -> Option<Instant> {
        let expiry = self
            .visible
            .then_some(self.last_activity)
            .flatten()
            .map(|at| at + IDLE_SUGGESTION_LIFETIME);
        [
            self.due.map(|(_, at)| at),
            expiry,
            self.measures.check_due(),
            self.window_text.adoption_due(),
        ]
        .into_iter()
        .flatten()
        .min()
    }

    // ----------------------------------------------------------- commands

    fn on_command(&mut self, command: AutocompleteCommand) {
        match command {
            AutocompleteCommand::Context(context) => self.on_context(context),
            AutocompleteCommand::Accepted {
                field_id,
                text,
                inserted,
            } => self.on_accepted(field_id, &text, &inserted),
            AutocompleteCommand::Dismiss => {
                self.cancel_all();
                self.clear_suggestion();
            }
            AutocompleteCommand::LeftField => self.on_left_field(),
            AutocompleteCommand::ClearUsage => {
                self.measures.clear_usage();
                self.host.remove_measures(false, true);
                self.emit_measures();
            }
            AutocompleteCommand::ResetMeasures => {
                self.measures.reset_stats();
                self.host.remove_measures(true, false);
                self.emit_measures();
            }
            AutocompleteCommand::ForgetLearned => self.forget_learned(),
            AutocompleteCommand::RequestStatus => {
                self.emit_measures();
                self.emit_learning();
            }
        }
    }

    /// Text read from the screen is forgotten as soon as focus leaves the
    /// field it was read for (`handleFocusChange`).
    fn on_left_field(&mut self) {
        self.cancel_all();
        if self.active_visible {
            self.batch.discard();
            self.anchors.clear();
            self.active_visible = false;
        }
        self.clear_suggestion();
        self.field = None;
        self.window_text.remove_all();
        self.host.forget_window(false);
        self.measures.note_left_field(Instant::now());
        self.persist();
    }

    /// `forgetLearnedText`: cancels what could bring the text back, clears
    /// memory at once, then deletes after any queued writes. New learning
    /// waits until that is done.
    fn forget_learned(&mut self) {
        self.cancel_all();
        self.batch.discard();
        self.clear_suggestion();
        self.anchors.clear();
        self.accepted_tail = None;
        self.learning.clear();
        self.learning_generation += 1;
        self.forgetting = true;
        self.forgotten = None;
        self.emit_learning();
        let sender = self.sender.clone();
        self.host.forget_learning(Box::new(move |ok| {
            let _ = sender.send(Message::LearningForgotten(ok));
        }));
    }

    fn on_learning_forgotten(&mut self, ok: bool) {
        self.forgetting = false;
        self.forgotten = Some(ok);
        if ok {
            // Nothing is left to protect from being overwritten.
            self.learning_state = LearningState::Ready;
        }
        self.emit_learning();
    }

    fn on_learning_opened(&mut self, generation: u64, open: LearningOpen) {
        if generation != self.learning_generation {
            return;
        }
        match open {
            LearningOpen::Loaded(snapshot) => {
                let had_new = !self.learning.is_empty();
                let loaded = snapshot.examples.len();
                self.learning.merge_loaded(snapshot, chrono::Utc::now());
                self.learning_state = LearningState::Ready;
                // Expired examples went, or something was learned meanwhile.
                if had_new || self.learning.len() != loaded {
                    self.save_learning();
                }
            }
            LearningOpen::Blocked(reason) => {
                self.learning_state = LearningState::Blocked(reason);
            }
        }
        self.emit_learning();
    }

    fn save_learning(&self) {
        if self.learning_state == LearningState::Ready {
            self.host.save_learning(self.learning.snapshot());
        }
    }

    /// Opens the learned examples the first time an identified document
    /// needs them, so the credential store is never asked otherwise.
    fn open_learning_if_needed(&mut self, settings: &Settings, place: &Place) {
        if self.learning_state != LearningState::Closed
            || self.forgetting
            || !settings.cotyping_enabled
            || !settings.cotyping_use_local_learning
            || place.scope_key().is_none()
        {
            return;
        }
        self.learning_state = LearningState::Opening;
        let host = self.host.clone();
        let sender = self.sender.clone();
        let generation = self.learning_generation;
        let spawned = std::thread::Builder::new()
            .name("lokalbot-autocomplete-learning".into())
            .spawn(move || {
                let open = host.open_learning();
                let _ = sender.send(Message::LearningOpened { generation, open });
            });
        if let Err(err) = spawned {
            log::warn!("autocomplete: could not open learned examples: {err}");
            self.learning_state = LearningState::Closed;
        }
    }

    fn emit_learning(&self) {
        let problem = match &self.learning_state {
            LearningState::Blocked(reason) => Some(reason.clone()),
            _ => None,
        };
        self.host
            .emit(AutocompleteUpdate::Learning(AutocompleteLearning {
                problem,
                forgetting: self.forgetting,
                forgotten: self.forgotten,
            }));
    }

    fn emit_measures(&self) {
        self.host.emit(AutocompleteUpdate::Measures(Box::new(
            AutocompleteMeasures {
                stats: self.measures.stats.clone(),
                usage: self.measures.usage.clone(),
            },
        )));
    }

    fn persist(&mut self) {
        if let Some((stats, usage)) = self.measures.take_unsaved() {
            self.host.save_measures(stats, usage);
        }
    }

    /// Editing or deleting a source, or withdrawing a grant, cancels what its
    /// facts shaped (`discardRevokedMemoryContext`).
    fn discard_revoked_memory(&mut self, settings: &Settings) -> bool {
        let policy = Policy::from_settings(settings);
        let current = self
            .active_memory
            .as_ref()
            .is_none_or(|guard| guard.is_current(policy));
        if current {
            return false;
        }
        self.memory.reset();
        self.cancel_all();
        self.batch.discard();
        self.clear_suggestion();
        self.anchors.clear();
        self.accepted_tail = None;
        self.active_memory = None;
        self.active_visible = false;
        self.emit_memory_use(Vec::new(), false);
        true
    }

    fn emit_memory_use(&mut self, sources: Vec<String>, searched: bool) {
        if self.memory_use != (sources.clone(), searched) {
            self.memory_use = (sources.clone(), searched);
            self.host
                .emit(AutocompleteUpdate::MemoryUse { sources, searched });
        }
    }

    /// Whether statistics count this field: never LokalBot's own editor.
    fn measured(field: &FieldContext) -> bool {
        field.app_id != SELF_APP_ID
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
        self.discard_revoked_memory(&settings);
        if !self.allowed(&settings, &context) {
            self.cancel_all();
            self.clear_suggestion();
            self.field = None;
            self.measures.note_left_field(Instant::now());
            return;
        }
        let previous = self.field.replace(context.clone());
        if let Some(previous) = previous.as_ref().filter(|p| p.field_id == context.field_id) {
            let now = Instant::now();
            self.measures.note_read(
                (&previous.before, &previous.after),
                (&context.before, &context.after),
                context.pid,
                context.field_id,
                Self::measured(&context),
                now,
            );
            if previous.before != context.before {
                self.window_text.note_typing(now);
            }
        } else {
            self.measures.note_left_field(Instant::now());
        }
        let Some(previous) = previous.filter(|p| p.field_id == context.field_id) else {
            // A newly focused field: nothing is suggested until the user
            // types, but its prompt is read now.
            self.cancel_all();
            self.clear_suggestion();
            self.accepted_tail = None;
            // The saved facts for this field are looked up now, so the first
            // suggestion can use them.
            let window = self.window_context(&context, &settings);
            let visible = surrounding_text(&context, &settings, window.as_deref());
            let _ = self.memory_text(&context, &settings, &visible);
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

    fn on_accepted(&mut self, field_id: u64, text: &str, inserted: &str) {
        let settings = self.host.settings();
        if self.discard_revoked_memory(&settings) {
            return;
        }
        let Some(shown) = self.shown.as_ref().filter(|s| s.field_id == field_id) else {
            return;
        };
        if text.is_empty() {
            return;
        }
        let current = &shown.session;
        let advanced = match &current.kind {
            SuggestionKind::Emoji
            | SuggestionKind::Macro { .. }
            | SuggestionKind::Correction { .. } => {
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
        let continuation = current.kind == SuggestionKind::Continuation;
        if let (Some(next), Some(field)) = (&advanced, self.field.clone())
            && continuation
        {
            let accepted = next.full_text[current.consumed..next.consumed].to_string();
            let where_accepted = place(&field, &before_accept, &settings);
            let learn = settings.cotyping_use_local_learning && !shown.used_context;
            self.batch.append(&where_accepted, &accepted, learn);
            self.accepted_any = true;
            self.open_learning_if_needed(&settings, &where_accepted);
            if Self::measured(&field) {
                self.measures.note_accept(
                    surface_key(&field),
                    &server::statistics_model_id(&settings),
                    &field.before,
                    inserted,
                    accepted.chars().count() as i64,
                    ac::accept::accepted_word_count(&accepted) as i64,
                    field.pid,
                    field.field_id,
                    Instant::now(),
                );
                self.emit_measures();
            }
            self.window_text.note_typing(Instant::now());
        } else if advanced.is_some() && matches!(current.kind, SuggestionKind::Correction { .. }) {
            // Not a shown or accepted suggestion: only the fix is counted.
            self.measures.note_typo_fixed();
            self.persist();
            self.emit_measures();
        }
        let current_kind_continues = continuation;
        match advanced {
            None => self.clear_suggestion(),
            Some(next) if next.is_exhausted() => {
                // The next field read, with the accepted text, asks for more.
                if current_kind_continues {
                    self.accepted_tail = Some((text.to_string(), before_accept));
                }
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
        let privacy = PrivacySettings::of(&settings);
        if self.privacy.as_ref() != Some(&privacy) {
            // Nothing read or shaped under the old settings stays
            // (`applySettings`).
            self.privacy = Some(privacy);
            self.cancel_all();
            self.batch.discard();
            self.clear_suggestion();
            self.memory.reset();
            self.anchors.clear();
            self.active_memory = None;
            self.active_visible = false;
            self.window_text.remove_all();
            self.host.forget_window(false);
            self.emit_memory_use(Vec::new(), false);
        }
        if !settings.cotyping_enabled {
            self.cancel_all();
            self.clear_suggestion();
            self.field = None;
            self.anchors.clear();
            self.memory.reset();
            // In memory only: what is on disk stays until "Forget learned text".
            self.learning.clear();
            self.learning_generation += 1;
            if !matches!(self.learning_state, LearningState::Blocked(_)) {
                self.learning_state = LearningState::Closed;
            }
            self.clipboard.clear();
            self.host.forget_clipboard();
            self.window_text.remove_all();
            self.host.forget_window(true);
            self.measures.reset_pending();
            self.persist();
            // Turned off: the model does not stay loaded for the idle time.
            if was_enabled {
                self.host.stop_server();
            }
            return;
        }
        if !settings.cotyping_use_clipboard {
            self.clipboard.clear();
            self.host.forget_clipboard();
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
        if self.measures.check_due().is_some_and(|due| now >= due) {
            let field = self.field.clone();
            let live = field
                .as_ref()
                .map(|f| (f.pid, f.field_id, f.before.as_str()));
            self.measures.resolve(live, now, true);
            self.persist();
        }
        if self
            .window_text
            .adoption_due()
            .is_some_and(|due| now >= due)
            && self.window_text.adopt_pending_if_quiet(now) == window_text::Finished::Changed
        {
            self.window_text_changed();
        }
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
            && SurfaceClass::of(&field.app_id, &field.app_name) != SurfaceClass::Terminal
            && (!field.integrated_terminal || settings.cotyping_suggest_in_integrated_terminals)
            && !self.host.recording()
    }

    /// A text change: the suggestion goes, and one is asked for after the
    /// debounce (`scheduleGeneration`).
    fn schedule(&mut self, settings: &Settings, before: &str) {
        self.clear_suggestion();
        self.cancel_generation(Some(before));
        self.work += 1;
        self.active_memory = None;
        self.active_visible = false;
        if self.field.as_ref().is_some_and(Self::measured) {
            self.measures.note_asked(Instant::now());
        }
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
        // An explicit `:shortcode` wins over autocorrect and the model.
        if settings.cotyping_emoji
            && let Some(hit) = emoji::match_trailing(&field.before)
        {
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
                None,
            );
            return;
        }
        // An explicit `/expr` wins too. The result is computed once, here: a
        // random macro is not rolled again at the accept.
        if settings.cotyping_macros
            && let Some(hit) = macros::match_trailing(&field.before)
        {
            self.present(
                field.field_id,
                Session::new(
                    &field.before,
                    &field.after,
                    &hit.result.insertion,
                    SuggestionKind::Macro {
                        query: hit.query,
                        preview: hit.result.preview,
                    },
                ),
                String::new(),
                true,
                None,
            );
            return;
        }
        // Autocorrect: offer to fix the trailing word before spending a model call.
        let speller = self.host.speller();
        if let Some(speller) = &speller {
            match speller.typo_decision(&field.before, settings.cotyping_autocorrect) {
                TypoDecision::Offer { word, corrected } => {
                    self.present(
                        field.field_id,
                        Session::new(
                            &field.before,
                            &field.after,
                            &corrected,
                            SuggestionKind::Correction { typo: word },
                        ),
                        String::new(),
                        true,
                        None,
                    );
                    return;
                }
                TypoDecision::Suppress => {
                    self.clear_suggestion();
                    return;
                }
                TypoDecision::Proceed => {}
            }
        }
        if !self.host.ready(&settings) {
            return;
        }
        let window = self.window_context(&field, &settings);
        let visible = surrounding_text(&field, &settings, window.as_deref());
        let memory = self.memory_text(&field, &settings, &visible);
        let policy = Policy::from_settings(&settings);
        let guard = (!self.memory.lookup.selection.items.is_empty() && memory.is_some())
            .then(|| Arc::new(self.memory.lookup.guard.clone()));
        self.active_memory.clone_from(&guard);
        self.active_visible = window.is_some() || !visible.is_empty();
        let sources = if memory.is_some() {
            self.memory.lookup.selection.source_titles()
        } else {
            Vec::new()
        };
        self.emit_memory_use(sources, policy.enabled());
        let used_context = memory.is_some() || self.active_visible;
        let extras = self.extras(&field, &settings, memory, window, false);
        let Some(request) = build(&field, &settings, settings.cotyping_max_words, extras) else {
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
            .filter(|r| self.seam_allows(speller.as_deref(), &field.before, &r.text))
        {
            let mut restored_session = Session::new(
                &field.before,
                &field.after,
                &restored.text,
                SuggestionKind::Continuation,
            );
            restored_session.open_ended = restored.open_ended;
            self.accepted_tail = None;
            self.present(
                field.field_id,
                restored_session,
                fingerprint,
                used_context,
                guard,
            );
            return;
        }
        self.launch(JobKind::Fresh {
            field,
            request,
            fingerprint,
            used_context,
            guard,
        });
    }

    /// `seamVerdict`: a splice that would misspell the word being typed, or a
    /// junk run, is not shown. Spell verdicts stand down where they don't apply.
    fn seam_allows(&self, speller: Option<&Speller>, before: &str, text: &str) -> bool {
        seam::verdict(before, text, |word| {
            speller.is_none_or(|speller| speller.is_known_word(before, word))
        }) == seam::SeamVerdict::Allow
    }

    /// What a request is built with besides the field. The clipboard is
    /// resolved here for every kind of request, as on macOS; LokalBot's own
    /// practice editor never uses it.
    fn extras(
        &mut self,
        field: &FieldContext,
        settings: &Settings,
        memory: Option<String>,
        window: Option<String>,
        allows_blank_prefix: bool,
    ) -> Extras {
        let learned = self.learned_examples(field, settings);
        let clipboard = self.pinned_clipboard(field, settings);
        let word_prefix_is_valid_word = self
            .host
            .speller()
            .is_none_or(|speller| speller.word_prefix_is_valid_word(&field.before));
        Extras {
            memory,
            learned_examples: learned,
            clipboard,
            window,
            word_prefix_is_valid_word,
            allows_blank_prefix,
        }
    }

    /// `pinnedClipboardContext`.
    fn pinned_clipboard(&mut self, field: &FieldContext, settings: &Settings) -> Option<String> {
        if !settings.cotyping_use_clipboard {
            self.clipboard.clear();
            return None;
        }
        if field.app_id == SELF_APP_ID {
            return None;
        }
        let snapshot = self.host.clipboard();
        let prefix = ac::window::truncated_prefix(
            &field.before,
            ac::prompt::MAX_PREFIX_CHARACTERS,
            ac::prompt::MAX_PREFIX_WORDS,
        );
        self.clipboard
            .resolve(snapshot.as_ref(), &prefix, &identity(field), Instant::now())
    }

    /// The focused window's text once a background read of it exists. A
    /// keystroke never waits for one; a missing or old read starts here. The
    /// model is never downloaded for this: without it there is no window text.
    fn window_context(&mut self, field: &FieldContext, settings: &Settings) -> Option<String> {
        let policy = ReadPolicy::from_settings(settings, settings.cotyping_enabled);
        if field.app_id == SELF_APP_ID
            || !policy.allows_window_text(
                &field.app_name,
                &field.app_id,
                &field.window_title,
                field.url.as_deref(),
                field.integrated_terminal,
            )
            || !self.host.window_text_ready()
        {
            return None;
        }
        let rect = field.field_frame?;
        let frame = Frame::new(
            f64::from(rect.x),
            f64::from(rect.y),
            f64::from(rect.width),
            f64::from(rect.height),
        );
        let key = window_text::key(field.pid, "text", &field.window_title, frame);
        let (snapshot, ticket) = self.window_text.snapshot(&key, Instant::now());
        // Checked again for every use: `allows_window_text` ran above.
        let text = snapshot.and_then(Snapshot::text);
        if let Some(ticket) = ticket {
            let request = WindowRequest {
                key,
                pid: field.pid,
                title: field.window_title.clone(),
                url: field.url.clone(),
                field: frame,
            };
            self.start_window_read(ticket, request);
        }
        text
    }

    fn start_window_read(&mut self, ticket: Ticket, request: WindowRequest) {
        let host = self.host.clone();
        let sender = self.sender.clone();
        let spawned = std::thread::Builder::new()
            .name("lokalbot-autocomplete-window".into())
            .spawn(move || {
                let read = host.read_window(&request);
                let snapshot = read.map(|read| Snapshot {
                    title: request.title.clone(),
                    url: request.url.clone(),
                    excerpts: window_text::excerpts(
                        &read.lines,
                        request.field,
                        read.window,
                        window_text::MAXIMUM_CHARACTERS,
                    ),
                });
                let _ = sender.send(Message::WindowText {
                    ticket,
                    key: request.key,
                    snapshot,
                });
            });
        if let Err(err) = spawned {
            log::warn!("autocomplete: could not read the window: {err}");
        }
    }

    fn on_window_text(&mut self, ticket: Ticket, key: &str, snapshot: Option<Snapshot>) {
        if self
            .window_text
            .finish(ticket, key, snapshot, Instant::now())
            == window_text::Finished::Changed
        {
            self.window_text_changed();
        }
    }

    /// New window text changes the prompt's start: with nothing being
    /// generated, the model reads it now, so the next keystroke need not
    /// (`windowTextDidChange`).
    fn window_text_changed(&mut self) {
        let settings = self.host.settings();
        if self.running.is_none() && self.due.is_none() {
            self.prefill(&settings);
        }
    }

    /// The newest saved facts for `field`, starting a lookup when the
    /// finished words could name something new.
    fn memory_text(
        &mut self,
        field: &FieldContext,
        settings: &Settings,
        visible: &str,
    ) -> Option<String> {
        let policy = Policy::from_settings(settings);
        if !policy.enabled() {
            self.memory.reset();
            return None;
        }
        // A source changed or was withdrawn since the lookup: look again.
        if !self.memory.lookup.is_current(policy) {
            self.memory.reset();
        }
        let anchor = identity(field);
        let query = query_for(field, settings, visible);
        if self.memory.needs_lookup(&anchor, &query) {
            self.memory.begin(&anchor, &query);
            if !query.all.is_empty() {
                let host = self.host.clone();
                let sender = self.sender.clone();
                let spawned = std::thread::Builder::new()
                    .name("lokalbot-autocomplete-memory".into())
                    .spawn(move || {
                        let lookup = host.memory(&query, policy);
                        let _ = sender.send(Message::Memory {
                            anchor,
                            query,
                            lookup,
                        });
                    });
                if let Err(err) = spawned {
                    log::warn!("autocomplete: could not look up saved facts: {err}");
                }
            }
        }
        self.memory.lookup.selection.text()
    }

    fn on_memory(&mut self, anchor: &str, query: &Query, lookup: Lookup) {
        let settings = self.host.settings();
        if !Policy::from_settings(&settings).enabled() {
            return;
        }
        let changed = self.memory.finish(anchor, query, lookup);
        // New facts change the prompt's start: read it ahead while nothing
        // else is asked for (after a prefill already running, if need be).
        let fresh_running = self.running.as_ref().is_some_and(|r| !r.prefill);
        if changed && self.shown.is_none() && !fresh_running && self.due.is_none() {
            self.prefill(&settings);
        }
    }

    /// Accepted completions from the same document, ranked on the finished
    /// words so a half-typed word does not reorder them.
    fn learned_examples(&mut self, field: &FieldContext, settings: &Settings) -> Vec<String> {
        if !settings.cotyping_use_local_learning {
            return Vec::new();
        }
        let finished = memory::finished_words(&field.before).to_string();
        let where_typed = place(field, &finished, settings);
        self.open_learning_if_needed(settings, &where_typed);
        let now = chrono::Utc::now();
        if self.learning.prune(now) {
            self.save_learning();
        }
        let limit = settings.cotyping_learning_examples_in_prompt.clamp(1, 5) as usize;
        self.learning.examples(&where_typed, limit, now)
    }

    /// Reads a field's prompt ahead of the first keystroke
    /// (`scheduleFocusPrewarm`), unless a request is already going to.
    fn prefill(&mut self, settings: &Settings) {
        if self.queued.is_some() || !self.host.ready(settings) || !self.host.prefills(settings) {
            return;
        }
        let Some(field) = self.field.clone() else {
            return;
        };
        let memory = self.memory.lookup.selection.text();
        let window = self.window_context(&field, settings);
        let extras = self.extras(&field, settings, memory, window, true);
        if let Some(request) = build(&field, settings, settings.cotyping_max_words, extras) {
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
        let memory = self.memory.lookup.selection.text();
        let window = self.window_context(&continued, settings);
        let extras = self.extras(&continued, settings, memory, window, false);
        let Some(request) = build(&continued, settings, limit, extras) else {
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
        if let Outcome::Completion(completion) = &outcome {
            let settings = self.host.settings();
            match kind.clone() {
                JobKind::Fresh {
                    field,
                    request: _,
                    fingerprint,
                    used_context,
                    guard,
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
                    if !Self::measured(&field) {
                        let rehearsal = self.rehearsal_report(&field, &settings, completion);
                        self.host.emit(AutocompleteUpdate::Rehearsal(rehearsal));
                    }
                    self.on_suggestion(
                        &settings,
                        field,
                        completion,
                        fingerprint,
                        used_context,
                        guard,
                        elapsed,
                    );
                }
                JobKind::TopUp {
                    field_id,
                    full_text,
                    prefix,
                    ..
                } => self.on_top_up(&settings, field_id, &full_text, &prefix, completion),
                JobKind::Prefill { .. } => {}
            }
        } else if let (Outcome::Failed, JobKind::Fresh { field, .. }) = (&outcome, &kind)
            && Self::measured(field)
        {
            self.measures.note_error();
            self.persist();
            self.emit_measures();
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

    /// What the practice editor's request drew on, for Settings.
    fn rehearsal_report(
        &self,
        field: &FieldContext,
        settings: &Settings,
        completion: &Completion,
    ) -> crate::events::AutocompleteRehearsal {
        let titles = |admitted: fn(&lokalbot_ai::autocomplete::memory::Item) -> bool| {
            let mut titles: Vec<String> = self
                .memory
                .lookup
                .selection
                .items
                .iter()
                .filter(|item| admitted(item))
                .map(|item| item.title.clone())
                .collect();
            titles.sort();
            titles.dedup();
            titles
        };
        // Sources count only if the request carried them.
        let used_memory = !self.memory_use.0.is_empty();
        crate::events::AutocompleteRehearsal {
            suppression: completion.result.suppression,
            visible_text: !surrounding_text(field, settings, None).is_empty(),
            meeting_sources: if used_memory {
                titles(|item| item.requires_meetings)
            } else {
                Vec::new()
            },
            screen_sources: if used_memory {
                titles(|item| item.requires_screen_memory)
            } else {
                Vec::new()
            },
            searched_memory: self.memory_use.1,
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
    #[allow(clippy::too_many_arguments)]
    fn on_suggestion(
        &mut self,
        settings: &Settings,
        asked: FieldContext,
        completion: &Completion,
        fingerprint: String,
        used_context: bool,
        guard: Option<Arc<MemoryGuard>>,
        elapsed: Duration,
    ) {
        let text = &completion.result.text;
        if let Some(reason) = completion.result.suppression {
            log::debug!("autocomplete: no suggestion ({reason:?})");
        }
        if self.discard_revoked_memory(settings) {
            return;
        }
        let Some(live) = self.field.clone().filter(|f| f.field_id == asked.field_id) else {
            return;
        };
        if !self.allowed(settings, &live) {
            return;
        }
        if Self::measured(&asked) {
            self.measures.note_generation(elapsed.as_millis() as i64);
            self.persist();
            self.emit_measures();
        }
        if text.is_empty() {
            return;
        }
        let speller = self.host.speller();
        if self.is_acceptance_echo(text, &asked.before)
            || !self.seam_allows(speller.as_deref(), &asked.before, text)
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
        self.present(asked.field_id, current, fingerprint, used_context, guard);
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
        let speller = self.host.speller();
        let known = |word: &str| {
            speller
                .as_ref()
                .is_none_or(|speller| speller.is_known_word(prefix, word))
        };
        if seam::verdict(prefix, &addition, known) != seam::SeamVerdict::Allow {
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
        guard: Option<Arc<MemoryGuard>>,
    ) {
        let continuation = session.kind == SuggestionKind::Continuation;
        self.shown = Some(Shown {
            field_id,
            session,
            fingerprint,
            used_context,
            guard,
        });
        self.emit_suggestion();
        self.note_activity();
        if continuation && let Some(field) = self.field.clone().filter(Self::measured) {
            let settings = self.host.settings();
            self.measures.note_shown(
                surface_key(&field),
                &server::statistics_model_id(&settings),
                Instant::now(),
            );
            self.emit_measures();
        }
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
            kind: shown.session.kind.clone(),
            guard: shown.guard.clone(),
        });
        self.visible = true;
    }

    fn clear_suggestion(&mut self) {
        // What was accepted of the suggestion becomes one learned example.
        if let Some((place, text)) = self.batch.complete()
            && !self.forgetting
            && self.learning.record(&place, &text, chrono::Utc::now())
        {
            self.save_learning();
        }
        // All chunks from one suggestion are one write.
        if std::mem::take(&mut self.accepted_any) {
            self.persist();
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
    extras: Extras,
) -> Option<Request> {
    let visible_text = if settings.cotyping_use_visible_context && !field.integrated_terminal {
        field.visible_text.clone()
    } else {
        None
    };
    let field = ac::Field {
        app_name: field.app_name.clone(),
        app_id: field.app_id.clone(),
        window_title: field.window_title.clone(),
        before: field.before.clone(),
        after: field.after.clone(),
        visible_text,
        single_line: field.single_line,
        integrated_terminal: field.integrated_terminal,
    };
    ac::build_request(
        &field,
        max_words.max(1),
        &Personalization::from_settings(settings),
        &extras,
    )
}

/// Where an accepted suggestion was written, for learning. No window title
/// without the app context grant.
fn place(field: &FieldContext, before: &str, settings: &Settings) -> Place {
    Place {
        app_name: field.app_name.clone(),
        app_id: field.app_id.clone(),
        window_title: if settings.cotyping_use_app_context {
            field.window_title.clone()
        } else {
            String::new()
        },
        url: field.url.clone(),
        before: before.to_string(),
    }
}

/// The surface raw value statistics are kept under.
fn surface_key(field: &FieldContext) -> &'static str {
    SurfaceClass::of_field(&field.app_id, &field.app_name, field.integrated_terminal).raw_name()
}

/// The selected text around the field, for saved-memory queries.
fn surrounding_text(field: &FieldContext, settings: &Settings, window: Option<&str>) -> String {
    if field.integrated_terminal {
        return String::new();
    }
    match window {
        Some(window) => window.to_string(),
        None if settings.cotyping_use_visible_context => {
            field.visible_text.clone().unwrap_or_default()
        }
        None => String::new(),
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
    items_from_meetings(library, &meeting_candidates(library, query, now), query)
}

/// The meetings a lookup reads.
fn meeting_candidates(
    library: &Library,
    query: &Query,
    now: chrono::DateTime<chrono::Utc>,
) -> Vec<lokalbot_core::Meeting> {
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
    eligible
        .into_iter()
        .filter(|m| hits.contains(&m.id) || memory::names(&m.title, query).is_some())
        .take(4)
        .collect()
}

/// Notes, summary and outcomes of `meetings`, read fresh from the files.
fn items_from_meetings(
    library: &Library,
    meetings: &[lokalbot_core::Meeting],
    query: &Query,
) -> Vec<memory::Item> {
    let mut items = Vec::new();
    for meeting in meetings {
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
    let personalization = Personalization::from_settings(settings);
    let mut hasher = DefaultHasher::new();
    settings.cotyping_built_in_model_id.hash(&mut hasher);
    server::fingerprint(settings).hash(&mut hasher);
    settings.cotyping_use_clipboard.hash(&mut hasher);
    settings.cotyping_use_local_learning.hash(&mut hasher);
    settings.cotyping_use_meeting_memory.hash(&mut hasher);
    settings.cotyping_use_screen_memory.hash(&mut hasher);
    settings
        .cotyping_learning_examples_in_prompt
        .hash(&mut hasher);
    personalization.user_name.hash(&mut hasher);
    personalization.style_note.hash(&mut hasher);
    personalization.language_hint.hash(&mut hasher);
    personalization.multi_line.hash(&mut hasher);
    personalization.app_context.hash(&mut hasher);
    personalization.extended_context.hash(&mut hasher);
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
        others: Mutex<Vec<AutocompleteUpdate>>,
        fact_guard: Mutex<Option<MemoryGuard>>,
        clipboard_now: Mutex<Option<clipboard::Snapshot>>,
        spelling: Mutex<Option<Arc<Speller>>>,
        window_ready: AtomicBool,
        window_reads: AtomicU64,
        window_lines: Mutex<Option<WindowRead>>,
        learning_file: Mutex<LearningOpen>,
        learning_saves: Mutex<Vec<learning::Snapshot>>,
        forget_calls: AtomicU64,
        measures_file: Mutex<(CotypingStats, UsageHistory)>,
        saved_measures: Mutex<Vec<(CotypingStats, Option<UsageHistory>)>>,
    }

    impl Host for FakeHost {
        fn settings(&self) -> Settings {
            self.settings.lock().clone()
        }
        fn emit(&self, update: AutocompleteUpdate) {
            // The tests below watch the ghost; counters are checked on their own.
            match update {
                AutocompleteUpdate::Suggestion { .. } | AutocompleteUpdate::Clear => {
                    let _ = self.events.send(update);
                }
                other => self.others.lock().push(other),
            }
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
        fn memory(&self, query: &Query, policy: Policy) -> Lookup {
            Lookup {
                selection: memory::select(
                    &self.facts.lock(),
                    query,
                    policy,
                    chrono::Utc::now(),
                    true,
                ),
                guard: self.fact_guard.lock().clone().unwrap_or(MemoryGuard {
                    policy,
                    ..MemoryGuard::default()
                }),
            }
        }
        fn clipboard(&self) -> Option<clipboard::Snapshot> {
            self.clipboard_now.lock().clone()
        }
        fn speller(&self) -> Option<Arc<Speller>> {
            self.spelling.lock().clone()
        }
        fn window_text_ready(&self) -> bool {
            self.window_ready.load(Ordering::Relaxed)
        }
        fn read_window(&self, _: &WindowRequest) -> Option<WindowRead> {
            self.window_reads.fetch_add(1, Ordering::Relaxed);
            self.window_lines.lock().clone()
        }
        fn open_learning(&self) -> LearningOpen {
            self.learning_file.lock().clone()
        }
        fn save_learning(&self, snapshot: learning::Snapshot) {
            self.learning_saves.lock().push(snapshot);
        }
        fn forget_learning(&self, done: Box<dyn FnOnce(bool) + Send>) {
            self.forget_calls.fetch_add(1, Ordering::Relaxed);
            done(true);
        }
        fn load_measures(&self) -> (CotypingStats, UsageHistory) {
            self.measures_file.lock().clone()
        }
        fn save_measures(&self, stats: CotypingStats, usage: Option<UsageHistory>) {
            self.saved_measures.lock().push((stats, usage));
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
            others: Mutex::new(Vec::new()),
            fact_guard: Mutex::new(None),
            clipboard_now: Mutex::new(None),
            spelling: Mutex::new(None),
            window_ready: AtomicBool::new(false),
            window_reads: AtomicU64::new(0),
            window_lines: Mutex::new(None),
            learning_file: Mutex::new(LearningOpen::Loaded(learning::Snapshot::default())),
            learning_saves: Mutex::new(Vec::new()),
            forget_calls: AtomicU64::new(0),
            measures_file: Mutex::new(Default::default()),
            saved_measures: Mutex::new(Vec::new()),
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
                    Some(_) => continue,
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
            kind: SuggestionKind::Continuation,
            guard: None,
        }
    }

    fn accepted(field_id: u64, text: &str) -> AutocompleteCommand {
        AutocompleteCommand::Accepted {
            field_id,
            text: text.into(),
            inserted: text.into(),
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
        h.autocomplete.handle(accepted(1, " on"));
        assert_eq!(h.next(), Some(shown(" the timeline", 1)));
        // The field shows the accepted word: the same suggestion stays.
        h.type_text(1, "I wanted to follow up on");
        assert_eq!(h.next(), Some(shown(" the timeline", 1)));
        h.autocomplete.handle(accepted(1, " the timeline"));
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
        h.autocomplete.handle(accepted(1, "🚀"));
        assert_eq!(h.next(), Some(AutocompleteUpdate::Clear));
    }

    #[test]
    fn accepting_tops_the_suggestion_up_once_two_words_are_left() {
        let h = harness(&[" between the number", " of menu items"], 0);
        h.host.settings.lock().cotyping_max_words = 3;
        h.type_text(1, "The main tradeoff");
        h.type_text(1, "The main tradeoff is");
        assert_eq!(h.suggestion(), " between the number");
        h.autocomplete.handle(accepted(1, " between"));
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
        h.autocomplete
            .handle(accepted(7, " the retention playbook first"));
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

    /// `window_text_ready` and a read's lines for a field with a frame.
    fn window_field(field_id: u64, before: &str) -> FieldContext {
        FieldContext {
            field_id,
            pid: 7,
            window_title: "Chat with Ana".into(),
            field_frame: Some(lokalbot_platform::autocomplete::Rect::new(
                100.0, 500.0, 400.0, 40.0,
            )),
            ..context(field_id, before)
        }
    }

    fn window_read(text: &str) -> WindowRead {
        WindowRead {
            lines: vec![window_text::Line {
                text: text.to_string(),
                frame: Frame::new(100.0, 400.0, 300.0, 20.0),
            }],
            window: Frame::new(0.0, 0.0, 800.0, 600.0),
        }
    }

    #[test]
    fn window_text_is_read_in_the_background_and_starts_the_next_prompt() {
        let h = harness(&[" soon", " later"], 0);
        h.host.window_ready.store(true, Ordering::Relaxed);
        *h.host.window_lines.lock() = Some(window_read("Ana: the cutover plan is ready"));
        h.send(window_field(1, "I will read"));
        std::thread::sleep(Duration::from_millis(60));
        h.send(window_field(1, "I will read it"));
        let _ = h.suggestion();
        let prompts = h.host.prompts.lock().clone();
        assert!(
            prompts
                .last()
                .unwrap()
                .starts_with("Visible in this window:\nAna: the cutover plan is ready"),
            "{:?}",
            prompts.last()
        );
        assert_eq!(h.host.window_reads.load(Ordering::Relaxed), 1);
    }

    #[test]
    fn window_text_needs_its_grant_and_the_model_and_never_downloads() {
        // No model: nothing is read.
        let h = harness(&[" soon"], 0);
        *h.host.window_lines.lock() = Some(window_read("Ana: the cutover plan"));
        h.send(window_field(1, "I will read"));
        h.send(window_field(1, "I will read it"));
        let _ = h.suggestion();
        assert_eq!(h.host.window_reads.load(Ordering::Relaxed), 0);
        // The grant off: nothing is read either.
        let h = harness(&[" soon"], 0);
        h.host.window_ready.store(true, Ordering::Relaxed);
        h.host.settings.lock().cotyping_use_window_text = false;
        h.send(window_field(1, "I will read"));
        h.send(window_field(1, "I will read it"));
        let _ = h.suggestion();
        assert_eq!(h.host.window_reads.load(Ordering::Relaxed), 0);
        // Excluded app, private window and an unknown browser page abstain.
        let h = harness(&[" soon", " soon", " soon"], 0);
        h.host.window_ready.store(true, Ordering::Relaxed);
        let private = FieldContext {
            window_title: "Inbox - Private Browsing".into(),
            ..window_field(2, "I will read")
        };
        h.send(private.clone());
        h.send(FieldContext {
            before: "I will read it".into(),
            ..private
        });
        let browser = FieldContext {
            app_name: "Firefox".into(),
            app_id: "firefox".into(),
            ..window_field(3, "I will read")
        };
        h.send(browser.clone());
        h.send(FieldContext {
            before: "I will read it".into(),
            ..browser
        });
        std::thread::sleep(Duration::from_millis(80));
        assert_eq!(h.host.window_reads.load(Ordering::Relaxed), 0);
        // LokalBot's own editor never reads the screen.
        let own = FieldContext {
            app_id: SELF_APP_ID.into(),
            ..window_field(4, "I will read")
        };
        h.send(own);
        std::thread::sleep(Duration::from_millis(40));
        assert_eq!(h.host.window_reads.load(Ordering::Relaxed), 0);
    }

    #[test]
    fn revoking_the_window_grant_forgets_the_text() {
        let h = harness(&[" soon", " later"], 0);
        h.host.window_ready.store(true, Ordering::Relaxed);
        *h.host.window_lines.lock() = Some(window_read("Ana: the cutover plan is ready"));
        h.send(window_field(1, "I will read"));
        std::thread::sleep(Duration::from_millis(60));
        h.host.settings.lock().cotyping_use_window_text = false;
        h.autocomplete.settings_changed();
        std::thread::sleep(Duration::from_millis(20));
        h.send(window_field(1, "I will read it"));
        let _ = h.suggestion();
        assert!(
            h.host
                .prompts
                .lock()
                .iter()
                .last()
                .is_none_or(|p| !p.contains("cutover"))
        );
    }

    #[test]
    fn a_fresh_related_copy_joins_the_prompt_only_with_its_grant() {
        let h = harness(&[" soon", " later", " again"], 0);
        let copied = |count: u64| clipboard::Snapshot {
            count,
            text: "The cutover moved to Thursday".to_string(),
        };
        // The first look is a baseline, whatever it holds.
        *h.host.clipboard_now.lock() = Some(copied(1));
        h.type_text(1, "About the cutover");
        h.type_text(1, "About the cutover ");
        assert_eq!(h.suggestion(), "soon");
        assert!(
            h.host
                .prompts
                .lock()
                .iter()
                .all(|p| !p.contains("clipboard"))
        );
        *h.host.clipboard_now.lock() = Some(copied(2));
        h.type_text(1, "About the cutover t");
        let _ = h.suggestion();
        assert!(
            h.host
                .prompts
                .lock()
                .last()
                .unwrap()
                .contains("On the clipboard: The cutover moved to Thursday"),
            "{:?}",
            h.host.prompts.lock().last()
        );
        h.host.settings.lock().cotyping_use_clipboard = false;
        h.autocomplete.settings_changed();
        std::thread::sleep(Duration::from_millis(20));
        h.type_text(1, "About the cutover tt");
        let _ = h.suggestion();
        assert!(!h.host.prompts.lock().last().unwrap().contains("clipboard"));
    }

    #[test]
    fn emoji_and_macros_follow_their_settings() {
        let h = harness(&[" reply"], 0);
        h.host.settings.lock().cotyping_emoji = false;
        h.type_text(1, "Ship it");
        h.type_text(1, "Ship it :roc");
        assert_eq!(h.suggestion(), " reply");

        let h = harness(&[], 0);
        h.type_text(1, "Total");
        h.type_text(1, "Total /5+5");
        let Some(AutocompleteUpdate::Suggestion { text, kind, .. }) = h.next() else {
            panic!("no suggestion");
        };
        assert_eq!(text, "10");
        assert_eq!(
            kind,
            SuggestionKind::Macro {
                query: "5+5".into(),
                preview: "= 10".into()
            }
        );
        assert_eq!(h.kinds(), ["prefill"]);
        h.autocomplete.handle(accepted(1, "10"));
        assert_eq!(h.next(), Some(AutocompleteUpdate::Clear));

        let h = harness(&[" and more"], 0);
        h.host.settings.lock().cotyping_macros = false;
        h.type_text(1, "Total");
        h.type_text(1, "Total /5+5");
        assert_eq!(h.suggestion(), " and more");
    }

    /// A dictionary of two words that knows nothing else.
    struct TwoWords;
    impl SpellSource for TwoWords {
        fn languages(&self) -> Vec<String> {
            vec!["en_US".into()]
        }
        fn is_typo(&self, word: &str) -> bool {
            !matches!(word, "follow" | "hello")
        }
        fn guesses(&self, word: &str) -> Vec<String> {
            if word == "folow" {
                vec!["follow".into()]
            } else {
                Vec::new()
            }
        }
        fn is_completable_prefix(&self, word: &str) -> bool {
            "follow".starts_with(word) && word.len() < 6
        }
    }

    #[test]
    fn a_typo_is_offered_before_the_model_and_counts_when_fixed() {
        let h = harness(&[" up", " up"], 0);
        *h.host.spelling.lock() = Some(Arc::new(Speller::new(Arc::new(TwoWords))));
        h.type_text(1, "I");
        h.type_text(1, "I folow");
        let Some(AutocompleteUpdate::Suggestion { text, kind, .. }) = h.next() else {
            panic!("no suggestion");
        };
        assert_eq!(text, "follow");
        assert_eq!(
            kind,
            SuggestionKind::Correction {
                typo: "folow".into()
            }
        );
        assert_eq!(h.kinds(), ["prefill"]);
        h.autocomplete.handle(accepted(1, "follow"));
        assert_eq!(h.next(), Some(AutocompleteUpdate::Clear));
        std::thread::sleep(Duration::from_millis(20));
        assert_eq!(
            h.host
                .saved_measures
                .lock()
                .last()
                .and_then(|(_, usage)| usage.clone())
                .and_then(|usage| usage.days.values().next().map(|d| d.typos_fixed)),
            Some(1)
        );

        // A word still being typed goes to the model; no correction means
        // nothing at all.
        let h = harness(&["w up"], 0);
        *h.host.spelling.lock() = Some(Arc::new(Speller::new(Arc::new(TwoWords))));
        h.type_text(1, "I");
        h.type_text(1, "I follo");
        assert_eq!(h.suggestion(), "w up");
        let h = harness(&[" up"], 0);
        *h.host.spelling.lock() = Some(Arc::new(Speller::new(Arc::new(TwoWords))));
        h.type_text(1, "I");
        h.type_text(1, "I qqq");
        assert_eq!(h.quiet(80), vec![]);
        assert_eq!(h.kinds(), ["prefill"]);
    }

    #[test]
    fn the_seam_guard_uses_the_dictionary() {
        let h = harness(&["w up"], 0);
        *h.host.spelling.lock() = Some(Arc::new(Speller::new(Arc::new(TwoWords))));
        h.type_text(1, "I");
        h.type_text(1, "I follo");
        // "follow" is known, so the splice is shown.
        assert_eq!(h.suggestion(), "w up");
        let h = harness(&["xx up"], 0);
        *h.host.spelling.lock() = Some(Arc::new(Speller::new(Arc::new(TwoWords))));
        h.type_text(1, "I");
        h.type_text(1, "I follo");
        assert_eq!(h.quiet(80), vec![]);
    }

    #[test]
    fn an_integrated_terminal_gets_nothing_unless_allowed() {
        let h = harness(&[" up"], 0);
        let terminal = |before: &str| FieldContext {
            integrated_terminal: true,
            ..context(1, before)
        };
        h.send(terminal("cargo"));
        h.send(terminal("cargo b"));
        assert_eq!(h.quiet(80), vec![]);
        assert!(h.kinds().is_empty());
        h.host
            .settings
            .lock()
            .cotyping_suggest_in_integrated_terminals = true;
        h.send(terminal("cargo bu"));
        h.send(terminal("cargo bui"));
        assert_eq!(h.suggestion(), " up");
    }

    #[test]
    fn languages_notes_and_app_context_reach_the_prompt() {
        let h = harness(&[" soon"], 0);
        {
            let mut settings = h.host.settings.lock();
            settings.cotyping_languages = "English, German".into();
            settings.cotyping_extended_context = "Atlas is our CRM.".into();
            settings.cotyping_use_app_context = false;
        }
        let titled = |before: &str| FieldContext {
            app_name: "Firefox".into(),
            app_id: "firefox".into(),
            url: Some("https://example.com/".into()),
            window_title: "Quarterly plan - Mozilla Firefox".into(),
            ..context(1, before)
        };
        h.send(titled("About the plan"));
        h.send(titled("About the plan,"));
        let _ = h.suggestion();
        let prompts = h.host.prompts.lock().clone();
        let prompt = prompts.last().unwrap();
        assert!(prompt.contains("The text is usually written in English, German."));
        assert!(prompt.contains("Notes the writer keeps in mind: Atlas is our CRM."));
        assert!(!prompt.contains("Quarterly plan"), "{prompt}");
    }

    #[test]
    fn a_source_edited_after_the_lookup_takes_the_suggestion_down() {
        let dir = tempfile::tempdir().unwrap();
        let source = dir.path().join("notes.md");
        std::fs::write(&source, "A business quote is due by Thursday.").unwrap();
        let policy = Policy {
            meetings: true,
            screen_derived: false,
        };
        let h = harness(&[" is due by Thursday", " zzz"], 0);
        h.host.settings.lock().cotyping_use_meeting_memory = true;
        *h.host.fact_guard.lock() = Some(MemoryGuard::stamp(policy, dir.path(), [source.clone()]));
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
        std::thread::sleep(Duration::from_millis(60));
        h.type_text(1, "Status on the Laptop refresh: the business quote ");
        let Some(AutocompleteUpdate::Suggestion { guard, .. }) = h.next() else {
            panic!("no suggestion");
        };
        assert!(guard.is_some(), "the desktop can check it again at accept");
        // Withdrawing the grant, or editing the file, ends it at the next read.
        std::fs::write(&source, "It moved.").unwrap();
        h.type_text(1, "Status on the Laptop refresh: the business quote is");
        assert_eq!(h.next(), Some(AutocompleteUpdate::Clear));
    }

    fn google_doc(before: &str) -> FieldContext {
        FieldContext {
            field_id: 7,
            app_name: "Firefox".into(),
            app_id: "firefox".into(),
            window_title: "Q3 plan - Google Docs — Mozilla Firefox".into(),
            url: Some("https://docs.google.com/document/d/abc123/edit".into()),
            before: before.into(),
            ..FieldContext::default()
        }
    }

    #[test]
    fn accepted_text_is_saved_only_with_the_store_open_and_learning_on() {
        let first = "Churn in the enterprise segment grew, so we should prioritize";
        let h = harness(&[" the retention playbook first"], 0);
        h.send(google_doc(
            "Churn in the enterprise segment grew, so we should",
        ));
        h.send(google_doc(first));
        assert_eq!(h.suggestion(), " the retention playbook first");
        h.autocomplete
            .handle(accepted(7, " the retention playbook first"));
        assert_eq!(h.next(), Some(AutocompleteUpdate::Clear));
        std::thread::sleep(Duration::from_millis(40));
        let saves = h.host.learning_saves.lock().clone();
        assert_eq!(
            saves.last().map(|s| s.examples[0].accepted_text.as_str()),
            Some("the retention playbook first")
        );

        // Learning off: nothing recorded, nothing saved.
        let h = harness(&[" the retention playbook first"], 0);
        h.host.settings.lock().cotyping_use_local_learning = false;
        h.send(google_doc(
            "Churn in the enterprise segment grew, so we should",
        ));
        h.send(google_doc(first));
        let _ = h.suggestion();
        h.autocomplete
            .handle(accepted(7, " the retention playbook first"));
        assert_eq!(h.next(), Some(AutocompleteUpdate::Clear));
        std::thread::sleep(Duration::from_millis(40));
        assert!(h.host.learning_saves.lock().is_empty());
    }

    #[test]
    fn a_store_that_cannot_open_says_so_and_is_never_written_over() {
        let first = "Churn in the enterprise segment grew, so we should prioritize";
        let h = harness(&[" the retention playbook first"], 0);
        *h.host.learning_file.lock() = LearningOpen::Blocked("cannot open".into());
        h.send(google_doc(
            "Churn in the enterprise segment grew, so we should",
        ));
        std::thread::sleep(Duration::from_millis(30));
        h.send(google_doc(first));
        let _ = h.suggestion();
        h.autocomplete
            .handle(accepted(7, " the retention playbook first"));
        assert_eq!(h.next(), Some(AutocompleteUpdate::Clear));
        std::thread::sleep(Duration::from_millis(40));
        assert!(h.host.learning_saves.lock().is_empty());
        assert!(h.host.others.lock().iter().any(|update| matches!(
            update,
            AutocompleteUpdate::Learning(AutocompleteLearning {
                problem: Some(_),
                ..
            })
        )));
        // Forgetting is the user's choice, and clears the way.
        h.autocomplete.handle(AutocompleteCommand::ForgetLearned);
        std::thread::sleep(Duration::from_millis(30));
        assert_eq!(h.host.forget_calls.load(Ordering::Relaxed), 1);
        assert!(h.host.others.lock().iter().any(|update| matches!(
            update,
            AutocompleteUpdate::Learning(AutocompleteLearning {
                problem: None,
                forgetting: false,
                forgotten: Some(true)
            })
        )));
    }

    #[test]
    fn a_sealed_file_opens_only_with_its_key_and_is_otherwise_left_alone() {
        let key = [7u8; 32];
        let other = [8u8; 32];
        let snapshot = learning::Snapshot {
            examples: vec![learning::Example {
                id: uuid::Uuid::new_v4(),
                created_at: chrono::DateTime::from_timestamp(1_793_307_200, 0).unwrap(),
                app_name: "Firefox".into(),
                bundle_id: Some("firefox".into()),
                surface_class: "browser".into(),
                context_hint: None,
                prefix_tail: "we should".into(),
                accepted_text: "prioritize retention".into(),
                scope_key: Some("abc".into()),
            }],
        };
        let sealed = lokalbot_core::screen::seal_image(
            &key,
            serde_json::to_string(&snapshot).unwrap().as_bytes(),
        )
        .unwrap();
        // nonce, ciphertext, tag: the Mac's `AES.GCM.SealedBox.combined`.
        assert_eq!(
            sealed.len(),
            12 + serde_json::to_vec(&snapshot).unwrap().len() + 16
        );
        assert_eq!(
            open_sealed_learning(&sealed, Some(key)),
            LearningOpen::Loaded(snapshot)
        );
        let blocked = LearningOpen::Blocked(learning_blocked_message());
        // Another key (a Mac's), no reachable store, or damage: never empty.
        assert_eq!(open_sealed_learning(&sealed, Some(other)), blocked);
        assert_eq!(open_sealed_learning(&sealed, None), blocked);
        assert_eq!(open_sealed_learning(b"junk", Some(key)), blocked);
        let not_json = lokalbot_core::screen::seal_image(&key, b"not json").unwrap();
        assert_eq!(open_sealed_learning(&not_json, Some(key)), blocked);
        // No file needs no key at all.
        let dir = tempfile::tempdir().unwrap();
        assert_eq!(
            open_learning_file(dir.path()),
            LearningOpen::Loaded(learning::Snapshot::default())
        );
    }

    #[test]
    fn the_store_is_not_opened_outside_an_identified_document() {
        let h = harness(&[" up"], 0);
        *h.host.learning_file.lock() = LearningOpen::Blocked("cannot open".into());
        h.type_text(1, "I wanted to");
        h.type_text(1, "I wanted to follow");
        let _ = h.suggestion();
        assert!(!h.host.others.lock().iter().any(|update| matches!(
            update,
            AutocompleteUpdate::Learning(AutocompleteLearning {
                problem: Some(_),
                ..
            })
        )));
    }

    #[test]
    fn statistics_count_other_apps_and_never_the_practice_editor() {
        let h = harness(&[" up on the plan"], 0);
        h.type_text(1, "I wanted to");
        h.type_text(1, "I wanted to follow");
        let _ = h.suggestion();
        h.autocomplete.handle(AutocompleteCommand::Accepted {
            field_id: 1,
            text: " up".into(),
            inserted: " up".into(),
        });
        std::thread::sleep(Duration::from_millis(30));
        let measures = |h: &Harness| {
            h.host
                .others
                .lock()
                .iter()
                .rev()
                .find_map(|update| match update {
                    AutocompleteUpdate::Measures(measures) => Some(measures.clone()),
                    _ => None,
                })
                .unwrap()
        };
        let counted = measures(&h);
        assert_eq!(counted.stats.generations, 1);
        assert_eq!(counted.stats.accepts, 1);
        assert_eq!(counted.stats.chars_accepted, 3);
        let day = counted.usage.days.values().next().unwrap();
        assert_eq!(day.suggestions.shown, 1);
        assert_eq!(day.suggestions.used, 1);
        assert_eq!(day.suggestions.words, 1);
        assert_eq!(day.surfaces["other"].shown, 1);
        assert_eq!(
            day.models.keys().next().map(String::as_str),
            Some("lfm2.5-1.2b-instruct")
        );

        let h = harness(&[" up on the plan"], 0);
        let own = |before: &str| FieldContext {
            app_id: SELF_APP_ID.into(),
            ..context(1, before)
        };
        h.send(own("I wanted to"));
        h.send(own("I wanted to follow"));
        let _ = h.suggestion();
        h.autocomplete.handle(accepted(1, " up"));
        std::thread::sleep(Duration::from_millis(30));
        let practiced = measures(&h);
        assert_eq!(practiced.stats, CotypingStats::default());
        assert!(practiced.usage.is_empty());
    }

    #[test]
    fn a_failed_request_counts_as_an_error_and_clearing_leaves_the_other_counters() {
        let h = harness(&[], 0);
        *h.host.measures_file.lock() = {
            let mut stats = CotypingStats::default();
            stats.record_generation(5);
            let mut usage = UsageHistory::default();
            usage.record_typo_fixed(chrono::NaiveDate::from_ymd_opt(2026, 1, 1).unwrap());
            (stats, usage)
        };
        // Loaded before the first command.
        let fresh = Autocomplete::with_host(h.host.clone());
        std::thread::sleep(Duration::from_millis(20));
        let last = |h: &Harness| {
            h.host
                .others
                .lock()
                .iter()
                .rev()
                .find_map(|update| match update {
                    AutocompleteUpdate::Measures(measures) => Some(measures.clone()),
                    _ => None,
                })
                .unwrap()
        };
        assert_eq!(last(&h).stats.generations, 1);
        fresh.handle(AutocompleteCommand::ClearUsage);
        std::thread::sleep(Duration::from_millis(20));
        assert!(last(&h).usage.is_empty());
        assert_eq!(last(&h).stats.generations, 1);
        fresh.handle(AutocompleteCommand::ResetMeasures);
        std::thread::sleep(Duration::from_millis(20));
        assert_eq!(last(&h).stats, CotypingStats::default());
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
