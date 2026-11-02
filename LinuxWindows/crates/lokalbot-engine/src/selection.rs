//! Selection actions (`SelectionActionsController.swift`): a system-wide
//! shortcut reads the text selected in the frontmost app, the panel runs the
//! Think model on it (optionally with matching work memory), and the result
//! replaces the selection, goes in at the cursor, or is copied. Nothing here is
//! persisted or logged.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use anyhow::{Result, anyhow};
use parking_lot::Mutex;

use lokalbot_ai::selection::{self, Action, MemoryContext, MemorySource};
use lokalbot_ai::think::{ChatRequest, ThinkClient};
use lokalbot_platform::focus::{self, DeliveryCheck, FocusRead};
use lokalbot_platform::insert::paste_checked;
use lokalbot_platform::{FrontApp, PasteOutcome, SelectionCapture, SelectionIssue};

use crate::models::Models;
use crate::{EngineEvent, SelectionCommand, Shared};

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub enum SelectionPhase {
    #[default]
    Idle,
    /// Reading the selection before the panel opens.
    Capturing,
    Choosing,
    Generating,
    Finished,
    Failed(String),
}

/// Everything the panel shows. Lives in memory while the panel is open.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct SelectionView {
    pub phase: SelectionPhase,
    /// The app the text came from.
    pub source: Option<FrontApp>,
    pub text: String,
    pub issue: Option<SelectionIssue>,
    pub can_insert: bool,
    pub action: Option<Action>,
    pub output: String,
    pub memory_sources: Vec<MemorySource>,
    pub model_name: Option<String>,
    /// Why the last result could not be pasted back; shown above it.
    pub notice: Option<String>,
}

impl SelectionView {
    pub fn has_selection(&self) -> bool {
        !self.text.trim().is_empty()
    }

    pub fn is_choosing(&self) -> bool {
        matches!(
            self.phase,
            SelectionPhase::Idle | SelectionPhase::Capturing | SelectionPhase::Choosing
        )
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum DeliveryOutcome {
    Inserted,
    /// Not pasted, for this reason; the result is on the clipboard.
    Copied(String),
}

/// Streams one reply. Stops early when `cancel` is set.
pub trait Generator: Send {
    fn display_name(&self) -> String;
    fn generate(
        &self,
        request: &ChatRequest,
        cancel: &AtomicBool,
        on_delta: &mut dyn FnMut(&str),
    ) -> Result<String>;
}

/// What the controller needs from the rest of the app.
pub trait Host: Send + Sync + 'static {
    /// The setting is on. Off means nothing is read.
    fn enabled(&self) -> bool;
    fn is_lokalbot_frontmost(&self) -> bool;
    fn capture(&self) -> SelectionCapture;
    fn memory(&self, query: &str) -> MemoryContext;
    fn make_generator(&self) -> Result<Box<dyn Generator>>;
    fn deliver(&self, text: &str, capture: &SelectionCapture) -> DeliveryOutcome;
    fn copy(&self, text: &str);
    fn return_focus(&self, source: &FrontApp);
    fn publish(&self, view: &SelectionView, open_panel: bool);
    fn report(&self, message: String);
}

#[derive(Default)]
struct Inner {
    /// Bumped by every new request, so a superseded one never writes state.
    generation: u64,
    view: SelectionView,
    capture: SelectionCapture,
    cancel: Option<Arc<AtomicBool>>,
}

impl Inner {
    /// Cancels the running request and starts a new generation.
    fn begin(&mut self, keep_capture: bool) -> u64 {
        if let Some(cancel) = self.cancel.take() {
            cancel.store(true, Ordering::Relaxed);
        }
        self.generation += 1;
        if !keep_capture {
            self.capture = SelectionCapture::default();
        }
        let phase = std::mem::take(&mut self.view.phase);
        self.view = view_of(&self.capture);
        self.view.phase = phase;
        self.generation
    }

    fn finish(&mut self) {
        self.begin(false);
        self.view.phase = SelectionPhase::Idle;
    }
}

fn view_of(capture: &SelectionCapture) -> SelectionView {
    SelectionView {
        source: capture.source.clone(),
        text: capture.text.clone(),
        issue: capture.issue,
        can_insert: capture.can_insert(),
        ..SelectionView::default()
    }
}

pub struct Controller<H: Host> {
    host: Arc<H>,
    inner: Arc<Mutex<Inner>>,
}

impl<H: Host> Controller<H> {
    pub fn new(host: H) -> Self {
        Self {
            host: Arc::new(host),
            inner: Arc::new(Mutex::new(Inner::default())),
        }
    }

    pub fn handle(&self, command: SelectionCommand) {
        match command {
            SelectionCommand::Invoke => self.invoke(),
            SelectionCommand::Run(action) => self.run(action),
            SelectionCommand::Retry => {
                let action = self.inner.lock().view.action.clone();
                if let Some(action) = action {
                    self.run(action);
                }
            }
            SelectionCommand::ChooseAgain => {
                let mut inner = self.inner.lock();
                inner.begin(true);
                inner.view.phase = SelectionPhase::Choosing;
                self.host.publish(&inner.view, false);
            }
            SelectionCommand::Copy => self.copy_output(),
            SelectionCommand::Insert => self.insert_output(),
            SelectionCommand::Dismiss => self.dismiss(),
            SelectionCommand::PanelClosed => {
                let mut inner = self.inner.lock();
                if inner.view.phase != SelectionPhase::Idle {
                    inner.finish();
                    self.host.publish(&inner.view, false);
                }
            }
        }
    }

    /// The shortcut was pressed. Reads the selection first, because opening
    /// the panel moves focus away from it.
    fn invoke(&self) {
        if !self.host.enabled() {
            return;
        }
        let (host, inner) = (self.host.clone(), self.inner.clone());
        std::thread::spawn(move || {
            if host.is_lokalbot_frontmost() {
                // Pressed while LokalBot is in front: keep any open panel's state.
                let mut inner = inner.lock();
                if inner.view.phase == SelectionPhase::Idle {
                    inner.view.phase = SelectionPhase::Choosing;
                }
                host.publish(&inner.view, true);
                return;
            }
            let current = {
                let mut inner = inner.lock();
                let current = inner.begin(false);
                inner.view.phase = SelectionPhase::Capturing;
                host.publish(&inner.view, false);
                current
            };
            let capture = host.capture();
            let mut inner = inner.lock();
            if current != inner.generation {
                return;
            }
            inner.view = view_of(&capture);
            inner.capture = capture;
            inner.view.phase = SelectionPhase::Choosing;
            host.publish(&inner.view, true);
        });
    }

    fn run(&self, action: Action) {
        let (current, cancel, selection) = {
            let mut inner = self.inner.lock();
            if inner.capture.issue.is_some()
                || !(inner.capture.has_selection() || action.works_without_selection)
            {
                return;
            }
            let current = inner.begin(true);
            let cancel = Arc::new(AtomicBool::new(false));
            inner.cancel = Some(cancel.clone());
            inner.view.action = Some(action.clone());
            inner.view.phase = SelectionPhase::Generating;
            self.host.publish(&inner.view, false);
            (current, cancel, inner.capture.text.clone())
        };
        let (host, inner) = (self.host.clone(), self.inner.clone());
        std::thread::spawn(move || {
            let update = |change: &dyn Fn(&mut SelectionView)| -> bool {
                let mut inner = inner.lock();
                if inner.generation != current {
                    return false;
                }
                change(&mut inner.view);
                host.publish(&inner.view, false);
                true
            };
            let result = (|| -> Result<Option<String>> {
                let memory = if action.uses_memory {
                    let memory = host.memory(&selection::memory_query(&action, &selection));
                    let sources = memory.sources.clone();
                    if !update(&|view| view.memory_sources = sources.clone()) {
                        return Ok(None);
                    }
                    memory
                } else {
                    MemoryContext::default()
                };
                let generator = host.make_generator()?;
                let name = generator.display_name();
                if !update(&|view| view.model_name = Some(name.clone())) {
                    return Ok(None);
                }
                let request = selection::request(&action, &selection, &memory);
                let mut raw = String::new();
                let reply = generator.generate(&request, &cancel, &mut |delta| {
                    raw.push_str(delta);
                    let partial = selection::normalized_output(&raw, &selection);
                    update(&|view| view.output = partial.clone());
                })?;
                Ok(Some(reply))
            })();
            let phase_after = match result {
                Ok(None) => return,
                Ok(Some(reply)) => {
                    let text = selection::normalized_output(&reply, &selection);
                    let phase = if text.is_empty() {
                        SelectionPhase::Failed(
                            lokalbot_i18n::tr(
                                "The model returned no text. Try again or reword the instruction.",
                            )
                            .to_string(),
                        )
                    } else {
                        SelectionPhase::Finished
                    };
                    (phase, Some(text))
                }
                Err(err) => {
                    // The error can quote the prompt, which holds the selection.
                    log::warn!("selection action failed");
                    (SelectionPhase::Failed(format!("{err:#}")), None)
                }
            };
            let mut inner = inner.lock();
            if inner.generation != current {
                return;
            }
            if let Some(text) = phase_after.1 {
                inner.view.output = text;
            }
            inner.view.phase = phase_after.0;
            inner.cancel = None;
            host.publish(&inner.view, false);
        });
    }

    /// Copies the result and hands focus back to the app it came from, ready
    /// for Ctrl+V. The panel closes.
    fn copy_output(&self) {
        let mut inner = self.inner.lock();
        if inner.view.output.is_empty() {
            return;
        }
        self.host.copy(&inner.view.output);
        let source = inner.capture.source.clone();
        inner.finish();
        self.host.publish(&inner.view, false);
        drop(inner);
        if let Some(source) = source {
            self.host.return_focus(&source);
        }
    }

    /// Replaces the selection with the result, or inserts it at the cursor
    /// when nothing was selected. The panel closes; if the field changed
    /// meanwhile, the panel comes back with the result already copied.
    fn insert_output(&self) {
        let (text, captured, chosen, sources, model) = {
            let mut inner = self.inner.lock();
            if inner.view.phase != SelectionPhase::Finished
                || inner.view.output.is_empty()
                || !inner.capture.can_insert()
            {
                return;
            }
            let kept = (
                inner.view.output.clone(),
                inner.capture.clone(),
                inner.view.action.clone(),
                inner.view.memory_sources.clone(),
                inner.view.model_name.clone(),
            );
            inner.finish();
            self.host.publish(&inner.view, false);
            kept
        };
        let (host, inner) = (self.host.clone(), self.inner.clone());
        std::thread::spawn(move || match host.deliver(&text, &captured) {
            DeliveryOutcome::Inserted => {}
            DeliveryOutcome::Copied(reason) => {
                let mut inner = inner.lock();
                // Nothing newer took the panel meanwhile.
                if inner.view.phase != SelectionPhase::Idle {
                    drop(inner);
                    host.report(reason);
                    return;
                }
                inner.view = view_of(&captured);
                inner.capture = captured;
                inner.view.action = chosen;
                inner.view.output = text;
                inner.view.memory_sources = sources;
                inner.view.model_name = model;
                inner.view.notice = Some(reason);
                inner.view.phase = SelectionPhase::Finished;
                host.publish(&inner.view, true);
            }
        });
    }

    /// Closes without using a result and returns to the source app.
    fn dismiss(&self) {
        let mut inner = self.inner.lock();
        let source = inner.capture.source.clone();
        inner.finish();
        self.host.publish(&inner.view, false);
        drop(inner);
        if let Some(source) = source {
            self.host.return_focus(&source);
        }
    }
}

/// The running engine's host.
pub(crate) struct LiveHost {
    shared: Arc<Shared>,
    models: Models,
}

impl LiveHost {
    pub(crate) fn new(shared: Arc<Shared>, models: Models) -> Self {
        Self { shared, models }
    }
}

struct ThinkGenerator(ThinkClient);

impl Generator for ThinkGenerator {
    fn display_name(&self) -> String {
        self.0.display_name()
    }

    fn generate(
        &self,
        request: &ChatRequest,
        cancel: &AtomicBool,
        on_delta: &mut dyn FnMut(&str),
    ) -> Result<String> {
        Ok(self.0.stream_full(request, Some(cancel), on_delta)?.text)
    }
}

impl Host for LiveHost {
    fn enabled(&self) -> bool {
        self.shared.settings().selection_actions_enabled
    }

    fn is_lokalbot_frontmost(&self) -> bool {
        lokalbot_platform::selection::lokalbot_is_frontmost()
    }

    fn capture(&self) -> SelectionCapture {
        let excluded = self.shared.settings().excluded_app_list();
        lokalbot_platform::selection::capture(&excluded)
    }

    fn memory(&self, query: &str) -> MemoryContext {
        let settings = self.shared.settings();
        let embedder = self.shared.think(&settings).ok().and_then(|t| t.embedder());
        selection::memory_context(
            &self.shared.library,
            embedder,
            query,
            settings.dreaming_enabled,
        )
        .unwrap_or_else(|_| {
            log::warn!("selection action memory lookup failed");
            MemoryContext::default()
        })
    }

    fn make_generator(&self) -> Result<Box<dyn Generator>> {
        if !self
            .models
            .missing(&self.models.think_requirements())
            .is_empty()
        {
            return Err(anyhow!(
                "{}",
                lokalbot_i18n::tr(
                    "Selection actions need the Think model. Download it in Settings → Models, then try again."
                )
            ));
        }
        let settings = self.shared.settings();
        Ok(Box::new(ThinkGenerator(
            self.shared.think(&settings)?.with_priority(
                lokalbot_ai::remote_gate::Priority::Interactive,
                "selection action",
            ),
        )))
    }

    fn deliver(&self, text: &str, capture: &SelectionCapture) -> DeliveryOutcome {
        deliver(text, capture)
    }

    fn copy(&self, text: &str) {
        if let Err(err) = lokalbot_platform::copy_to_clipboard(text) {
            self.shared.error(format!("{err:#}"));
        }
    }

    fn return_focus(&self, source: &FrontApp) {
        let source = source.clone();
        std::thread::spawn(move || {
            lokalbot_platform::focus::activate_window(&source);
        });
    }

    fn publish(&self, view: &SelectionView, open_panel: bool) {
        self.shared.emit(EngineEvent::Selection {
            view: view.clone(),
            open_panel,
        });
    }

    fn report(&self, message: String) {
        self.shared.error(message);
    }
}

/// Lets the app give keyboard focus back to its field before checking it.
const FOCUS_SETTLE: Duration = Duration::from_millis(120);
const FOCUS_DEADLINE: Duration = Duration::from_millis(400);

fn copied(text: &str, reason: &str) -> DeliveryOutcome {
    if let Err(err) = lokalbot_platform::copy_to_clipboard(text) {
        return DeliveryOutcome::Copied(format!("{err:#}"));
    }
    DeliveryOutcome::Copied(lokalbot_i18n::tr(reason).to_string())
}

/// `SelectionDelivery.message(for:)`.
fn check_message(check: DeliveryCheck) -> &'static str {
    match check {
        DeliveryCheck::Deliverable | DeliveryCheck::FieldUnreadable => {
            "LokalBot could not confirm which field to paste into, so the result was copied to the clipboard."
        }
        DeliveryCheck::FocusMoved => {
            "Focus moved to another field, so the result was copied to the clipboard instead."
        }
        DeliveryCheck::SelectionChanged => {
            "The selection changed, so the result was copied to the clipboard instead of replacing it."
        }
        DeliveryCheck::SecureField => {
            "LokalBot does not paste into password fields, so the result was copied to the clipboard."
        }
    }
}

/// Replacement requires the exact selection, including a range having been
/// cleared to a caret. Dictation's app-only fallback is less strict.
fn field_check(capture: &SelectionCapture) -> DeliveryCheck {
    let Some(target) = capture.target.as_ref() else {
        return DeliveryCheck::FieldUnreadable;
    };
    match focus::read_focus(FOCUS_DEADLINE) {
        FocusRead::Snapshot(snapshot) => target.strict_check(&snapshot),
        _ => DeliveryCheck::FieldUnreadable,
    }
}

/// Puts a result back into the field it came from.
fn deliver(text: &str, capture: &SelectionCapture) -> DeliveryOutcome {
    const NO_RETURN: &str =
        "LokalBot could not return to the app, so the result was copied to the clipboard.";
    let (Some(_), Some(source)) = (capture.target.as_ref(), capture.source.as_ref()) else {
        return copied(text, NO_RETURN);
    };
    if !focus::activate_window(source) {
        return copied(text, NO_RETURN);
    }
    // The panel is still closing for a moment after the click that got here.
    let mut check = DeliveryCheck::FieldUnreadable;
    for _ in 0..4 {
        std::thread::sleep(FOCUS_SETTLE);
        check = field_check(capture);
        if check == DeliveryCheck::Deliverable {
            break;
        }
    }
    if check != DeliveryCheck::Deliverable {
        return copied(text, check_message(check));
    }
    match paste_checked(text, || field_check(capture) == DeliveryCheck::Deliverable) {
        Ok(PasteOutcome::Pasted) => DeliveryOutcome::Inserted,
        Ok(PasteOutcome::LeftOnClipboard) => DeliveryOutcome::Copied(
            lokalbot_i18n::tr(
                "LokalBot could not paste the result, so it was copied to the clipboard.",
            )
            .to_string(),
        ),
        Ok(PasteOutcome::Skipped) | Err(_) => copied(
            text,
            "LokalBot could not paste the result, so it was copied to the clipboard.",
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crossbeam_channel::{Receiver, Sender, unbounded};
    use lokalbot_platform::DeliveryTarget;

    #[derive(Clone, Debug, PartialEq)]
    enum Note {
        Published(SelectionPhase, bool),
        Copied(String),
        Focus,
        Reported(String),
    }

    struct FakeGenerator {
        reply: Result<String, String>,
        deltas: Vec<String>,
    }

    impl Generator for FakeGenerator {
        fn display_name(&self) -> String {
            "Test model".into()
        }
        fn generate(
            &self,
            request: &ChatRequest,
            _: &AtomicBool,
            on_delta: &mut dyn FnMut(&str),
        ) -> Result<String> {
            assert!(!request.user_text().is_empty());
            for delta in &self.deltas {
                on_delta(delta);
            }
            self.reply.clone().map_err(|err| anyhow!(err))
        }
    }

    struct FakeHost {
        enabled: bool,
        frontmost: bool,
        capture: SelectionCapture,
        memory: MemoryContext,
        reply: Result<String, String>,
        deltas: Vec<String>,
        delivery: DeliveryOutcome,
        notes: Sender<Note>,
        views: Arc<Mutex<Vec<SelectionView>>>,
        memory_queries: Arc<Mutex<Vec<String>>>,
    }

    impl Host for FakeHost {
        fn enabled(&self) -> bool {
            self.enabled
        }
        fn is_lokalbot_frontmost(&self) -> bool {
            self.frontmost
        }
        fn capture(&self) -> SelectionCapture {
            self.capture.clone()
        }
        fn memory(&self, query: &str) -> MemoryContext {
            self.memory_queries.lock().push(query.to_string());
            self.memory.clone()
        }
        fn make_generator(&self) -> Result<Box<dyn Generator>> {
            Ok(Box::new(FakeGenerator {
                reply: self.reply.clone(),
                deltas: self.deltas.clone(),
            }))
        }
        fn deliver(&self, _: &str, _: &SelectionCapture) -> DeliveryOutcome {
            self.delivery.clone()
        }
        fn copy(&self, text: &str) {
            let _ = self.notes.send(Note::Copied(text.to_string()));
        }
        fn return_focus(&self, _: &FrontApp) {
            let _ = self.notes.send(Note::Focus);
        }
        fn publish(&self, view: &SelectionView, open_panel: bool) {
            self.views.lock().push(view.clone());
            let _ = self
                .notes
                .send(Note::Published(view.phase.clone(), open_panel));
        }
        fn report(&self, message: String) {
            let _ = self.notes.send(Note::Reported(message));
        }
    }

    struct Harness {
        controller: Controller<FakeHost>,
        notes: Receiver<Note>,
        views: Arc<Mutex<Vec<SelectionView>>>,
        queries: Arc<Mutex<Vec<String>>>,
    }

    fn capture_with_selection() -> SelectionCapture {
        SelectionCapture {
            source: Some(FrontApp {
                pid: Some(7),
                app_name: "Editor".into(),
                app_id: "editor".into(),
                window: Some(1),
                title: String::new(),
            }),
            text: "helo wrld".into(),
            target: Some(DeliveryTarget {
                pid: Some(7),
                app_id: "editor".into(),
                identity: Some("field".into()),
                selection: None,
            }),
            issue: None,
            read_through_clipboard: false,
        }
    }

    fn harness(adjust: impl FnOnce(&mut FakeHost)) -> Harness {
        let (tx, notes) = unbounded();
        let views = Arc::new(Mutex::new(Vec::new()));
        let queries = Arc::new(Mutex::new(Vec::new()));
        let mut host = FakeHost {
            enabled: true,
            frontmost: false,
            capture: capture_with_selection(),
            memory: MemoryContext::default(),
            reply: Ok("hello world".into()),
            deltas: Vec::new(),
            delivery: DeliveryOutcome::Inserted,
            notes: tx,
            views: views.clone(),
            memory_queries: queries.clone(),
        };
        adjust(&mut host);
        Harness {
            controller: Controller::new(host),
            notes,
            views,
            queries,
        }
    }

    impl Harness {
        /// Waits for a publish in this phase.
        fn wait_for(&self, phase: SelectionPhase) -> bool {
            let deadline = std::time::Instant::now() + Duration::from_secs(5);
            while let Some(left) = deadline.checked_duration_since(std::time::Instant::now()) {
                match self.notes.recv_timeout(left) {
                    Ok(Note::Published(found, open)) if found == phase => return open,
                    Ok(_) => {}
                    Err(_) => break,
                }
            }
            panic!("never reached {phase:?}");
        }

        fn view(&self) -> SelectionView {
            self.views.lock().last().cloned().unwrap_or_default()
        }

        fn choosing(&self) {
            self.controller.handle(SelectionCommand::Invoke);
            assert!(self.wait_for(SelectionPhase::Choosing), "the panel opens");
        }

        fn finished(&self) {
            self.choosing();
            self.controller
                .handle(SelectionCommand::Run(Action::built_in().remove(0)));
            self.wait_for(SelectionPhase::Finished);
        }
    }

    #[test]
    fn nothing_is_read_while_the_setting_is_off() {
        let h = harness(|host| host.enabled = false);
        h.controller.handle(SelectionCommand::Invoke);
        std::thread::sleep(Duration::from_millis(50));
        assert!(h.views.lock().is_empty());
    }

    #[test]
    fn invoke_reads_before_the_panel_opens() {
        let h = harness(|_| {});
        h.controller.handle(SelectionCommand::Invoke);
        assert!(!h.wait_for(SelectionPhase::Capturing), "not open yet");
        assert!(h.wait_for(SelectionPhase::Choosing));
        let view = h.view();
        assert_eq!(view.text, "helo wrld");
        assert!(view.can_insert && view.has_selection());
    }

    #[test]
    fn pressed_while_lokalbot_is_in_front_keeps_the_panel_state() {
        let h = harness(|host| host.frontmost = true);
        h.controller.handle(SelectionCommand::Invoke);
        assert!(h.wait_for(SelectionPhase::Choosing));
        assert_eq!(h.view().text, "", "nothing is read from LokalBot");
    }

    #[test]
    fn running_streams_and_finishes() {
        let h = harness(|host| host.deltas = vec!["\"hello".into(), " world\"".into()]);
        h.finished();
        let view = h.view();
        assert_eq!(view.output, "hello world");
        assert_eq!(view.model_name.as_deref(), Some("Test model"));
        assert!(
            h.views.lock().iter().any(|v| v.output == "\"hello"),
            "partial output is shown"
        );
    }

    #[test]
    fn actions_need_a_selection_and_no_issue() {
        let h = harness(|host| host.capture.text = String::new());
        h.choosing();
        let published = h.views.lock().len();
        h.controller
            .handle(SelectionCommand::Run(Action::built_in().remove(0)));
        std::thread::sleep(Duration::from_millis(30));
        assert_eq!(h.views.lock().len(), published, "a rewrite needs text");
        h.controller
            .handle(SelectionCommand::Run(Action::custom("write", false)));
        h.wait_for(SelectionPhase::Finished);

        let h = harness(|host| host.capture.issue = Some(SelectionIssue::ExcludedApp));
        h.choosing();
        let published = h.views.lock().len();
        h.controller
            .handle(SelectionCommand::Run(Action::custom("write", false)));
        std::thread::sleep(Duration::from_millis(30));
        assert_eq!(h.views.lock().len(), published, "an issue blocks every run");
    }

    #[test]
    fn memory_is_read_only_for_actions_that_use_it() {
        let h = harness(|host| {
            host.memory = MemoryContext {
                excerpts: "the beta ships Friday".into(),
                sources: vec![MemorySource {
                    id: uuid::Uuid::new_v4(),
                    title: "Beta".into(),
                    date: None,
                }],
            };
        });
        h.finished();
        assert!(h.queries.lock().is_empty(), "built-in rewrites never read");
        let explain = Action::built_in()
            .into_iter()
            .find(|a| a.id == "explain")
            .unwrap();
        h.controller.handle(SelectionCommand::Run(explain));
        h.wait_for(SelectionPhase::Finished);
        assert_eq!(*h.queries.lock(), ["helo wrld"]);
        assert_eq!(h.view().memory_sources.len(), 1);
    }

    #[test]
    fn an_empty_reply_and_a_failure_fail_the_run() {
        let h = harness(|host| host.reply = Ok("  ".into()));
        h.choosing();
        h.controller
            .handle(SelectionCommand::Run(Action::built_in().remove(0)));
        h.wait_for(SelectionPhase::Failed(
            "The model returned no text. Try again or reword the instruction.".into(),
        ));
        let h = harness(|host| host.reply = Err("server down".into()));
        h.choosing();
        h.controller
            .handle(SelectionCommand::Run(Action::built_in().remove(0)));
        h.wait_for(SelectionPhase::Failed("server down".into()));
    }

    #[test]
    fn copy_closes_and_returns_focus() {
        let h = harness(|_| {});
        h.finished();
        h.controller.handle(SelectionCommand::Copy);
        let mut seen = Vec::new();
        while let Ok(note) = h.notes.recv_timeout(Duration::from_millis(100)) {
            seen.push(note);
        }
        assert!(
            seen.contains(&Note::Copied("hello world".into())),
            "{seen:?}"
        );
        assert!(seen.contains(&Note::Focus), "{seen:?}");
        assert_eq!(h.view().phase, SelectionPhase::Idle);
        assert_eq!(h.view().text, "", "the selection is forgotten");
    }

    #[test]
    fn a_rejected_insert_reopens_with_the_reason() {
        let reason = "The selection changed, so the result was copied to the clipboard instead of replacing it.";
        let h = harness(|host| host.delivery = DeliveryOutcome::Copied(reason.into()));
        h.finished();
        h.controller.handle(SelectionCommand::Insert);
        assert!(!h.wait_for(SelectionPhase::Idle), "the panel closes");
        assert!(h.wait_for(SelectionPhase::Finished), "and comes back");
        let view = h.view();
        assert_eq!(view.notice.as_deref(), Some(reason));
        assert_eq!(view.output, "hello world");
    }

    #[test]
    fn insert_needs_a_field_to_go_back_to() {
        let h = harness(|host| host.capture.target = None);
        h.finished();
        assert!(!h.view().can_insert);
        let published = h.views.lock().len();
        h.controller.handle(SelectionCommand::Insert);
        std::thread::sleep(Duration::from_millis(30));
        assert_eq!(h.views.lock().len(), published);
    }

    #[test]
    fn closing_the_panel_forgets_everything() {
        let h = harness(|_| {});
        h.finished();
        h.controller.handle(SelectionCommand::PanelClosed);
        h.wait_for(SelectionPhase::Idle);
        let view = h.view();
        assert_eq!(view.text, "");
        assert_eq!(view.output, "");
        assert_eq!(view.action, None);
    }

    #[test]
    fn choosing_again_keeps_the_selection() {
        let h = harness(|_| {});
        h.finished();
        h.controller.handle(SelectionCommand::ChooseAgain);
        h.wait_for(SelectionPhase::Choosing);
        let view = h.view();
        assert_eq!(view.text, "helo wrld");
        assert_eq!(view.output, "");
    }
}
