// Contains code ported from Cotabby (https://github.com/FuJacob/cotabby),
// copyright the Cotabby authors, under the GNU AGPL v3.0
// (LICENSES/AGPL-3.0.txt). Modified for LokalBot since 18 October 2026.
// See THIRD_PARTY_NOTICES.md.

mod layout;
pub mod overlay;

use std::sync::Arc;
use std::time::{Duration, Instant};

use gpui_kit::{App, AppContext as _, Context, Entity, Global, Task};
use lokalbot_ai::autocomplete::memory::{MemoryGuard, Policy};
use lokalbot_ai::autocomplete::server::ServerProblem;
use lokalbot_ai::autocomplete::surface::SurfaceClass;
use lokalbot_ai::autocomplete::{AcceptOptions, AcceptScope, SuggestionKind};
use lokalbot_core::Settings;
use lokalbot_core::settings::{CotypingAcceptKey, CotypingEscapeBehavior, CotypingFullAcceptKey};
use lokalbot_engine::{
    AutocompleteCommand, AutocompleteLearning, AutocompleteMeasures, AutocompleteUpdate, Command,
    FieldContext,
};
use lokalbot_platform::autocomplete::geometry::RenderMode;
use lokalbot_platform::autocomplete::policy::{self, EscapePause, ReadPolicy};
use lokalbot_platform::autocomplete::session::{
    GhostSession, InsertProgress, Reconcile, SentContexts, drop_graphemes, inline_text,
    progression_between, typed_since,
};
use lokalbot_platform::autocomplete::{
    self as platform, AcceptKeys, Capability, Edit, FieldSnapshot, FieldWatcher, FocusSnapshot,
    InlineGhost, InterceptedKey, KeyInterceptor, Rect, Support,
};

use crate::state::{AppData, DictationHud};

pub const PRACTICE_FIELD_ID: u64 = u64::MAX;

const KEY_FOCUS_GRACE: Duration = Duration::from_millis(500);
const AWAITING_INSERT_TIMEOUT: Duration = Duration::from_millis(500);
const DOUBLE_TAP_WINDOW: Duration = Duration::from_millis(300);

#[derive(Clone, Debug, Default)]
struct DoubleTapAcceptance {
    last: Option<(String, Instant)>,
}

impl DoubleTapAcceptance {
    fn reset(&mut self) {
        self.last = None;
    }

    fn resolve(
        &mut self,
        whole: bool,
        full_accept_key: CotypingFullAcceptKey,
        suggestion_key: &str,
        now: Instant,
    ) -> bool {
        if whole || full_accept_key != CotypingFullAcceptKey::DoubleTap {
            self.reset();
            return whole;
        }
        if let Some((previous_key, previous_at)) = &self.last
            && previous_key == suggestion_key
            && now.saturating_duration_since(*previous_at) <= DOUBLE_TAP_WINDOW
        {
            self.reset();
            return true;
        }
        self.last = Some((suggestion_key.to_string(), now));
        false
    }
}

fn should_pass_tab_to_host(settings: &Settings, whole: bool, field: &FieldSnapshot) -> bool {
    settings.cotyping_tab_moves_to_next_field
        && settings.cotyping_accept_key == CotypingAcceptKey::Tab
        && !whole
        && field.single_line
        && !matches!(
            SurfaceClass::of(&field.app_id, &field.app_name),
            SurfaceClass::Chat | SurfaceClass::CodeEditor
        )
}

struct PendingInsert {
    field_id: u64,
    floor: String,
    target: String,
    truncated: bool,
    at: Instant,
}

impl PendingInsert {
    fn record(
        slot: &mut Option<Self>,
        field_id: u64,
        candidate_floor: &str,
        target: String,
        truncated: bool,
        now: Instant,
    ) {
        let (floor, truncated) = match slot {
            Some(prev)
                if prev.field_id == field_id
                    && now.duration_since(prev.at) < AWAITING_INSERT_TIMEOUT =>
            {
                let combined_truncated = prev.truncated || truncated;
                let kept = if target.starts_with(prev.floor.as_str())
                    || (combined_truncated
                        && typed_since(prev.floor.as_str(), &target, true).is_some())
                {
                    prev.floor.clone()
                } else {
                    let len = prev
                        .floor
                        .char_indices()
                        .zip(candidate_floor.chars())
                        .take_while(|((_, a), b)| *a == *b)
                        .last()
                        .map_or(0, |((idx, ch), _)| idx + ch.len_utf8());
                    prev.floor[..len].to_string()
                };
                (kept, combined_truncated)
            }
            _ => (candidate_floor.to_string(), truncated),
        };
        *slot = Some(Self {
            field_id,
            floor,
            target,
            truncated,
            at: now,
        });
    }

    fn holds_context(
        slot: &mut Option<Self>,
        field_id: u64,
        before: &str,
        before_truncated: bool,
        now: Instant,
    ) -> bool {
        let Some(pending) = slot.as_ref() else {
            return false;
        };
        if pending.field_id != field_id || now.duration_since(pending.at) >= AWAITING_INSERT_TIMEOUT
        {
            *slot = None;
            return false;
        }
        match progression_between(
            &pending.floor,
            &pending.target,
            before,
            pending.truncated || before_truncated,
        ) {
            InsertProgress::InFlight => true,
            InsertProgress::Settled | InsertProgress::Diverged => {
                *slot = None;
                false
            }
        }
    }
}

pub const PRACTICE_CONVERSATION: [(&str, &str); 2] = [
    (
        "Sarah",
        "The migration timeline we scoped yesterday still works for my team.",
    ),
    (
        "Sarah",
        "Daniel can start the database cutover on Thursday if you confirm today.",
    ),
];

struct Acceptance {
    chunk: String,
    edit: Edit,
}

fn plan_acceptance(
    remaining: &str,
    kind: &SuggestionKind,
    before: &str,
    after: &str,
    settings: &Settings,
    whole: bool,
) -> Option<Acceptance> {
    let scope = if whole {
        AcceptScope::Whole
    } else {
        AcceptScope::Chunk
    };
    let plan = lokalbot_ai::autocomplete::plan_acceptance(
        remaining,
        kind,
        scope,
        before,
        after,
        AcceptOptions::from_settings(settings),
    )?;
    if plan.chunk.is_empty() || !remaining.starts_with(&plan.chunk) {
        return None;
    }
    Some(Acceptance {
        edit: Edit {
            text: plan.insertion,
            backward: plan.backward_delete,
            forward: plan.forward_delete,
        },
        chunk: plan.chunk,
    })
}

fn drawn_ghost(
    session: &GhostSession,
    kind: &SuggestionKind,
    settings: &Settings,
) -> (String, String) {
    match kind {
        SuggestionKind::Macro { preview, .. } => (preview.clone(), preview.clone()),
        SuggestionKind::Correction { .. } => (session.remaining.clone(), session.remaining.clone()),
        SuggestionKind::Emoji | SuggestionKind::Continuation => {
            match lokalbot_ai::autocomplete::emoji_ghost(&session.anchor, &session.remaining) {
                Some(ghost) if *kind == SuggestionKind::Emoji => (ghost, session.remaining.clone()),
                _ => (
                    session.remaining.clone(),
                    lokalbot_ai::autocomplete::accept_chunk(
                        &session.remaining,
                        AcceptOptions::from_settings(settings),
                    ),
                ),
            }
        }
    }
}

pub struct AutocompleteHandle(pub Entity<Autocomplete>);

impl Global for AutocompleteHandle {}

pub fn global(cx: &App) -> Option<Entity<Autocomplete>> {
    cx.try_global::<AutocompleteHandle>().map(|h| h.0.clone())
}

enum Event {
    Focus(Box<FocusSnapshot>),
    Key(InterceptedKey),
    Inserted { field_id: u64, ok: bool },
}

struct Current {
    id: u64,
    identity: String,
    field: FieldSnapshot,
}

#[derive(Default)]
pub struct Practice {
    pub session: Option<GhostSession>,
    kind: Option<SuggestionKind>,
    before: String,
    after: String,
    escape_until: Option<Instant>,
}

impl Practice {
    pub fn ghost(&self, settings: &Settings) -> Option<(String, usize)> {
        let session = self.session.as_ref()?;
        if session.remaining.is_empty() {
            return None;
        }
        let kind = self.kind.clone().unwrap_or(SuggestionKind::Continuation);
        let (drawn, emphasis) = drawn_ghost(session, &kind, settings);
        Some((drawn, emphasis.chars().count()))
    }
}

enum InsertJob {
    Type {
        field_id: u64,
        field: Box<FieldSnapshot>,
        edit: Edit,
    },
    PassThrough {
        keys: Arc<KeyInterceptor>,
        key: InterceptedKey,
    },
}

struct Inserter {
    jobs: crossbeam_channel::Sender<InsertJob>,
}

impl Inserter {
    fn start(events: smol::channel::Sender<Event>) -> Option<Self> {
        let (jobs, receiver) = crossbeam_channel::unbounded::<InsertJob>();
        std::thread::Builder::new()
            .name("lokalbot-autocomplete-insert".into())
            .spawn(move || {
                while let Ok(job) = receiver.recv() {
                    match job {
                        InsertJob::Type {
                            field_id,
                            field,
                            edit,
                        } => {
                            let ok = match platform::insert(&field, &edit) {
                                Ok(()) => true,
                                Err(err) => {
                                    log::warn!(
                                        "autocomplete: could not type the suggestion: {err:#}"
                                    );
                                    false
                                }
                            };
                            let _ = events.send_blocking(Event::Inserted { field_id, ok });
                        }
                        InsertJob::PassThrough { keys, key } => {
                            keys.pass_through(key);
                        }
                    }
                }
            })
            .ok()?;
        Some(Self { jobs })
    }
}

pub struct Autocomplete {
    data: Entity<AppData>,
    events: smol::channel::Sender<Event>,
    support: Support,
    watcher: Option<FieldWatcher>,
    keys: Option<Arc<KeyInterceptor>>,
    inserter: Option<Inserter>,
    inline: Option<InlineGhost>,
    inline_shown: bool,
    running: bool,
    paused: bool,
    policy: ReadPolicy,
    current: Option<Current>,
    next_id: u64,
    session: Option<GhostSession>,
    session_kind: SuggestionKind,
    session_guard: Option<Arc<MemoryGuard>>,
    session_after: String,
    predicted_caret: Option<Rect>,
    held_inline_caret: Option<(u64, Rect)>,
    last_accept_at: Option<Instant>,
    double_tap: DoubleTapAcceptance,
    practice_double_tap: DoubleTapAcceptance,
    sent: SentContexts,
    last_context: Option<FieldContext>,
    escape: EscapePause,
    overlay: overlay::Overlay,
    keys_active: bool,
    accept_keys: AcceptKeys,
    last_key: Option<Instant>,
    pending_insert: Option<PendingInsert>,
    focus_generation: u64,
    luminance: std::collections::HashMap<String, f32>,
    fake: Option<String>,
    fake_task: Option<Task<()>>,
    power_task: Option<Task<()>>,
    low_power_paused: bool,
    pub practice: Practice,
    pub measures: AutocompleteMeasures,
    pub learning: AutocompleteLearning,
    pub memory_use: (Vec<String>, bool),
    pub server_problem: Option<ServerProblem>,
    pub rehearsal: Option<lokalbot_engine::AutocompleteRehearsal>,
}

#[cfg_attr(not(all(windows, debug_assertions)), allow(dead_code))]
const FILM_GHOST_ARG: &str = "--lokalbot-film-ghost";
#[cfg_attr(not(all(windows, debug_assertions)), allow(dead_code))]
const FILM_GHOST_ENV: &str = "LOKALBOT_TEST_FILM_GHOST";

#[cfg_attr(not(all(windows, debug_assertions)), allow(dead_code))]
fn film_ghost_requested(env: Option<&str>, args: &[String]) -> bool {
    env == Some("1") || args.iter().any(|arg| arg == FILM_GHOST_ARG)
}

fn film_ghost_enabled() -> bool {
    #[cfg(all(windows, debug_assertions))]
    {
        let args: Vec<String> = std::env::args().collect();
        film_ghost_requested(std::env::var(FILM_GHOST_ENV).ok().as_deref(), &args)
    }
    #[cfg(not(all(windows, debug_assertions)))]
    {
        false
    }
}

pub fn start(data: &Entity<AppData>, cx: &mut App) {
    let (events, receiver) = smol::channel::unbounded::<Event>();
    let fake = std::env::var("LOKALBOT_FAKE_AUTOCOMPLETE")
        .ok()
        .filter(|text| !text.is_empty());
    if fake.is_some() {
        log::warn!(
            "autocomplete: LOKALBOT_FAKE_AUTOCOMPLETE is set; suggestions come from it, not the engine"
        );
    }
    let film_ghost = film_ghost_enabled();
    if film_ghost {
        log::warn!(
            "autocomplete: {FILM_GHOST_ARG} / {FILM_GHOST_ENV}=1 is set; screen recordings include the autocomplete overlay"
        );
    }
    let data = data.clone();
    let entity = cx.new(|cx: &mut Context<Autocomplete>| {
        cx.observe(&data, |this, _, cx| this.sync(cx)).detach();
        Autocomplete {
            data: data.clone(),
            events,
            support: platform::support(),
            watcher: None,
            keys: None,
            inserter: None,
            inline: None,
            inline_shown: false,
            running: false,
            paused: false,
            policy: ReadPolicy::default(),
            current: None,
            next_id: 0,
            session: None,
            session_kind: SuggestionKind::Continuation,
            session_guard: None,
            session_after: String::new(),
            predicted_caret: None,
            held_inline_caret: None,
            last_accept_at: None,
            double_tap: DoubleTapAcceptance::default(),
            practice_double_tap: DoubleTapAcceptance::default(),
            sent: SentContexts::default(),
            last_context: None,
            escape: EscapePause::default(),
            overlay: overlay::Overlay::new(!film_ghost),
            keys_active: false,
            accept_keys: AcceptKeys::default(),
            last_key: None,
            pending_insert: None,
            focus_generation: 0,
            luminance: Default::default(),
            fake,
            fake_task: None,
            power_task: None,
            low_power_paused: false,
            practice: Practice::default(),
            measures: AutocompleteMeasures::default(),
            learning: AutocompleteLearning::default(),
            memory_use: (Vec::new(), false),
            rehearsal: None,
            server_problem: None,
        }
    });
    cx.set_global(AutocompleteHandle(entity.clone()));
    let handle = entity.clone();
    cx.spawn(async move |cx| {
        while let Ok(event) = receiver.recv().await {
            cx.update(|cx| handle.update(cx, |this, cx| this.handle(event, cx)));
        }
    })
    .detach();
    entity.update(cx, |this, cx| this.sync(cx));
    crate::bridge::send(
        Command::Autocomplete(AutocompleteCommand::RequestStatus),
        cx,
    );
}

pub fn engine_update(update: AutocompleteUpdate, cx: &mut App) {
    cx.defer(move |cx| {
        if let Some(entity) = global(cx) {
            entity.update(cx, |this, cx| this.on_engine(update, cx));
        }
    });
}

impl Autocomplete {
    pub fn support(&self) -> &Support {
        &self.support
    }

    pub fn limitation(&self) -> Option<String> {
        self.watcher.as_ref().and_then(FieldWatcher::limitation)
    }

    fn settings<'a>(&self, cx: &'a App) -> &'a Settings {
        &self.data.read(cx).settings
    }

    fn sync(&mut self, cx: &mut Context<Self>) {
        let (enabled, pause_in_low_power, low_power, paused, policy, accept_keys) = {
            let data = self.data.read(cx);
            let settings = &data.settings;
            let enabled = settings.cotyping_enabled;
            let pause_in_low_power = settings.cotyping_pause_in_low_power_mode;
            let low_power = pause_in_low_power && lokalbot_platform::power::current().saving_power;
            let paused =
                data.dictation != DictationHud::Idle || data.recording.is_active() || low_power;
            let policy = ReadPolicy::from_settings(settings, enabled && !paused);
            (
                enabled,
                pause_in_low_power,
                low_power,
                paused,
                policy,
                AcceptKeys::from_settings(settings),
            )
        };
        self.low_power_paused = low_power;
        if accept_keys != self.accept_keys {
            self.accept_keys = accept_keys;
            if let Some(keys) = &self.keys {
                keys.set_keys(accept_keys);
            }
        }
        if paused != self.paused {
            self.paused = paused;
            if paused {
                self.dismiss_everything(cx);
            }
        }
        let wants = enabled && self.support == Support::Available;
        if wants && !self.running {
            self.start_watching(policy.clone(), cx);
        } else if !wants && self.running {
            self.stop_watching(cx);
        }
        if wants && pause_in_low_power {
            self.ensure_power_polling(cx);
        } else {
            self.power_task = None;
        }
        if !enabled && (self.practice.session.is_some() || self.last_context.is_some()) {
            self.dismiss_everything(cx);
        }
        if policy != self.policy {
            let exclusions_changed = policy.excluded_apps != self.policy.excluded_apps
                || policy.excluded_domains != self.policy.excluded_domains
                || policy.capture_excluded_apps != self.policy.capture_excluded_apps
                || policy.capture_excluded_domains != self.policy.capture_excluded_domains
                || policy.visible_text != self.policy.visible_text
                || policy.window_text != self.policy.window_text
                || policy.match_host_style != self.policy.match_host_style
                || policy.suggest_in_integrated_terminals
                    != self.policy.suggest_in_integrated_terminals;
            self.policy = policy.clone();
            if let Some(watcher) = &self.watcher {
                watcher.set_policy(policy);
            }
            if exclusions_changed {
                self.leave_field(cx);
            }
        }
    }

    fn ensure_power_polling(&mut self, cx: &mut Context<Self>) {
        if self.power_task.is_some() {
            return;
        }
        self.power_task = Some(cx.spawn(async move |this, cx| {
            loop {
                smol::Timer::after(Duration::from_secs(5)).await;
                let saving = lokalbot_platform::power::current().saving_power;
                let ok = this.update(cx, |this, cx| {
                    let wants_pause = this.settings(cx).cotyping_pause_in_low_power_mode && saving;
                    if wants_pause != this.low_power_paused {
                        this.sync(cx);
                    }
                });
                if ok.is_err() {
                    break;
                }
            }
        }));
    }

    fn start_watching(&mut self, policy: ReadPolicy, cx: &mut Context<Self>) {
        let events = self.events.clone();
        let watcher = FieldWatcher::start(policy.clone(), move |focus| {
            let _ = events.send_blocking(Event::Focus(Box::new(focus)));
        });
        let events = self.events.clone();
        let keys = KeyInterceptor::start(move |key| {
            let _ = events.send_blocking(Event::Key(key));
        });
        match (watcher, keys) {
            (Ok(watcher), Ok(keys)) => {
                self.inline = watcher.inline_ghost();
                self.watcher = Some(watcher);
                keys.set_keys(self.accept_keys);
                self.keys = Some(Arc::new(keys));
                self.inserter = Inserter::start(self.events.clone());
                self.policy = policy;
                self.running = true;
                log::info!("autocomplete: watching the focused field");
            }
            (watcher, keys) => {
                let reason = watcher
                    .err()
                    .or(keys.err())
                    .map(|err| format!("{err:#}"))
                    .unwrap_or_default();
                log::warn!("autocomplete: unavailable: {reason}");
                self.support = Support::Unavailable(lokalbot_i18n::format(
                    "Autocomplete could not start: {reason}",
                    &[("reason", reason.to_string())],
                ));
            }
        }
        cx.notify();
    }

    fn stop_watching(&mut self, cx: &mut Context<Self>) {
        self.dismiss_everything(cx);
        self.power_task = None;
        self.watcher = None;
        if let Some(keys) = self.keys.take() {
            keys.set_active(false);
        }
        self.inline = None;
        self.inline_shown = false;
        self.inserter = None;
        self.keys_active = false;
        self.running = false;
        self.overlay.close(cx);
        log::info!("autocomplete: stopped");
        cx.notify();
    }

    fn dismiss_everything(&mut self, cx: &mut Context<Self>) {
        self.leave_field(cx);
        self.practice.session = None;
        self.practice.kind = None;
        self.fake_task = None;
        self.last_context = None;
        crate::bridge::send(Command::Autocomplete(AutocompleteCommand::Dismiss), cx);
        cx.notify();
    }

    fn handle(&mut self, event: Event, cx: &mut Context<Self>) {
        match event {
            Event::Focus(focus) => self.on_focus(*focus, cx),
            Event::Key(InterceptedKey::Escape) => self.on_escape(cx),
            Event::Key(key) => self.on_accept_key(key, cx),
            Event::Inserted { field_id, ok } => {
                if !ok {
                    if self
                        .pending_insert
                        .as_ref()
                        .is_some_and(|p| p.field_id == field_id)
                    {
                        self.pending_insert = None;
                    }
                    if self
                        .session
                        .as_ref()
                        .is_some_and(|s| s.field_id == field_id)
                    {
                        self.clear_session(cx);
                        crate::bridge::send(
                            Command::Autocomplete(AutocompleteCommand::Dismiss),
                            cx,
                        );
                    }
                }
            }
        }
    }

    fn on_focus(&mut self, focus: FocusSnapshot, cx: &mut Context<Self>) {
        if !self.running {
            return;
        }
        let low_power = self.settings(cx).cotyping_pause_in_low_power_mode
            && lokalbot_platform::power::current().saving_power;
        let paused = {
            let data = self.data.read(cx);
            data.dictation != DictationHud::Idle || data.recording.is_active() || low_power
        };
        if paused != self.paused {
            self.sync(cx);
        }
        if self.paused {
            return;
        }
        self.focus_generation += 1;
        log::debug!(
            "autocomplete: focus in {} ({:?}), {} characters before the caret",
            focus.app_name,
            focus.capability,
            focus.field.as_ref().map_or(0, |f| f.before.chars().count())
        );
        let field = match focus.field.clone() {
            Some(field)
                if focus.capability == Capability::Supported
                    && policy::disabled_reason(&self.policy, &focus).is_none() =>
            {
                field
            }
            _ => {
                if focus.field.is_none()
                    && focus.app_id.is_empty()
                    && self.session.is_some()
                    && self
                        .last_key
                        .is_some_and(|at| at.elapsed() < KEY_FOCUS_GRACE)
                {
                    log::debug!("autocomplete: focus left right after a taken key; waiting");
                    let generation = self.focus_generation;
                    cx.spawn(async move |this, cx| {
                        smol::Timer::after(KEY_FOCUS_GRACE).await;
                        let _ = this.update(cx, |this, cx| {
                            if this.focus_generation == generation {
                                this.leave_field(cx);
                            }
                        });
                    })
                    .detach();
                    return;
                }
                if let Capability::Blocked(reason) | Capability::Unsupported(reason) =
                    &focus.capability
                {
                    log::debug!(
                        "autocomplete: no suggestions in {}: {reason}",
                        focus.app_name
                    );
                }
                self.leave_field(cx);
                return;
            }
        };
        let identity = policy::field_identity(&field);
        let same = self
            .current
            .as_ref()
            .is_some_and(|current| current.identity == identity);
        let id = if same {
            self.current.as_ref().map_or(self.next_id, |c| c.id)
        } else {
            self.leave_field(cx);
            self.next_id += 1;
            self.sent.clear();
            self.next_id
        };
        self.current = Some(Current {
            id,
            identity: identity.clone(),
            field: field.clone(),
        });
        if self.escape.is_paused(&identity, Instant::now()) {
            self.pending_insert = None;
            self.clear_session(cx);
            return;
        }
        if self
            .pending_insert
            .as_ref()
            .is_some_and(|p| p.at.elapsed() >= AWAITING_INSERT_TIMEOUT)
        {
            self.pending_insert = None;
            if let Some(session) = self.session.as_mut() {
                session.stop_awaiting();
            }
        }
        self.reconcile_session(&field, cx);
        if self.is_awaiting_insert(id, &field.before, field.before_truncated) {
            return;
        }
        self.send_context(id, &field, cx);
    }

    fn reconcile_session(&mut self, field: &FieldSnapshot, cx: &mut Context<Self>) {
        let pending_active = self
            .pending_insert
            .as_ref()
            .is_some_and(|p| p.at.elapsed() < AWAITING_INSERT_TIMEOUT);
        let Some(session) = self.session.as_mut() else {
            return;
        };
        let awaiting = session.awaiting.is_some() || pending_active;
        let after_changed = lokalbot_ai::autocomplete::inline_after(&field.after)
            != lokalbot_ai::autocomplete::inline_after(&self.session_after)
            && !awaiting;
        if self.session_kind == SuggestionKind::Emoji
            && !after_changed
            && !awaiting
            && lokalbot_ai::autocomplete::emoji_ghost(&field.before, &session.remaining).is_some()
        {
            session.anchor = field.before.clone();
            session.anchor_truncated = field.before_truncated;
            self.predicted_caret = None;
            self.session_after = field.after.clone();
            self.present(cx);
            return;
        }
        let outcome = session.reconcile(&field.before, field.before_truncated);
        let replacement = self.session_kind != SuggestionKind::Continuation
            && !matches!(outcome, Reconcile::Unchanged);
        match outcome {
            _ if after_changed || replacement => {
                self.pending_insert = None;
                self.clear_session(cx);
            }
            Reconcile::Stale => {
                self.pending_insert = None;
                self.clear_session(cx);
            }
            Reconcile::Exhausted => self.clear_session(cx),
            Reconcile::Advanced { .. } => {
                self.double_tap.reset();
                self.predicted_caret = None;
                self.session_after = field.after.clone();
                self.present(cx);
            }
            Reconcile::Unchanged => {
                if self.session.as_ref().is_some_and(|s| s.awaiting.is_some()) {
                    return;
                }
                self.predicted_caret = None;
                self.session_after = field.after.clone();
                self.present(cx);
            }
        }
    }

    fn send_context(&mut self, id: u64, field: &FieldSnapshot, cx: &mut Context<Self>) {
        let context = FieldContext {
            field_id: id,
            app_name: field.app_name.clone(),
            app_id: field.app_id.clone(),
            window_title: field.window_title.clone(),
            before: field.before.clone(),
            after: field.after.clone(),
            visible_text: field.visible_text.clone(),
            url: lokalbot_platform::privacy::sanitized_url(field.url.as_deref()),
            single_line: field.single_line,
            integrated_terminal: field.is_integrated_terminal,
            field_frame: field.field_frame,
            pid: field.pid,
        };
        self.send(context, field.before_truncated, cx);
    }

    fn send(&mut self, context: FieldContext, before_truncated: bool, cx: &mut Context<Self>) {
        if self.last_context.as_ref() == Some(&context) {
            return;
        }
        self.sent.record(
            context.field_id,
            &context.before,
            before_truncated,
            Instant::now(),
        );
        self.last_context = Some(context.clone());
        if self.fake.is_some() {
            self.fake_suggestion(&context, cx);
            return;
        }
        crate::bridge::send(
            Command::Autocomplete(AutocompleteCommand::Context(context)),
            cx,
        );
    }

    fn fake_suggestion(&mut self, context: &FieldContext, cx: &mut Context<Self>) {
        let Some(text) = self.fake.clone() else {
            return;
        };
        let showing = if context.field_id == PRACTICE_FIELD_ID {
            self.practice.session.is_some()
        } else {
            self.session.is_some()
        };
        if showing || context.before.trim().is_empty() {
            return;
        }
        let text = if context.before.ends_with(char::is_whitespace) {
            text.trim_start().to_string()
        } else {
            text
        };
        let field_id = context.field_id;
        let pause = Duration::from_millis(u64::from(self.settings(cx).cotyping_debounce_ms));
        self.fake_task = Some(cx.spawn(async move |this, cx| {
            smol::Timer::after(pause).await;
            let _ = this.update(cx, |this, cx| {
                this.on_engine(
                    AutocompleteUpdate::Suggestion {
                        field_id,
                        text,
                        kind: SuggestionKind::Continuation,
                        guard: None,
                    },
                    cx,
                )
            });
        }));
    }

    fn on_engine(&mut self, update: AutocompleteUpdate, cx: &mut Context<Self>) {
        match update {
            AutocompleteUpdate::Suggestion {
                field_id,
                text,
                kind,
                ..
            } if field_id == PRACTICE_FIELD_ID => {
                if self.paused || !self.settings(cx).cotyping_enabled {
                    return;
                }
                let before = self.practice.before.clone();
                let fitted = self.fitted(field_id, &before, false, &text, &kind);
                log::debug!(
                    "autocomplete: practice suggestion of {} characters",
                    fitted.chars().count()
                );
                self.practice.session = (!fitted.is_empty())
                    .then(|| GhostSession::new(field_id, before, fitted, false));
                self.practice.kind = Some(kind);
                cx.notify();
            }
            AutocompleteUpdate::Suggestion {
                field_id,
                text,
                kind,
                guard,
            } => {
                if self.paused || !self.running {
                    return;
                }
                let Some(current) = self.current.as_ref().filter(|c| c.id == field_id) else {
                    return;
                };
                let field = current.field.clone();
                let pending = self
                    .pending_insert
                    .as_ref()
                    .filter(|p| p.field_id == field_id && p.at.elapsed() < AWAITING_INSERT_TIMEOUT);
                let effective_before = self
                    .session
                    .as_ref()
                    .filter(|s| s.field_id == field_id && s.awaiting.is_some())
                    .map(|s| s.anchor.as_str())
                    .or_else(|| pending.map(|p| p.target.as_str()))
                    .unwrap_or(field.before.as_str());
                let effective_truncated = self
                    .session
                    .as_ref()
                    .filter(|s| s.field_id == field_id && s.awaiting.is_some())
                    .map(|s| s.anchor_truncated)
                    .or_else(|| pending.map(|p| p.truncated))
                    .unwrap_or(field.before_truncated);
                let fitted = self.fitted(
                    field_id,
                    effective_before,
                    effective_truncated,
                    &text,
                    &kind,
                );
                if fitted.is_empty() {
                    if self
                        .session
                        .as_ref()
                        .is_none_or(|s| s.field_id != field_id || s.awaiting.is_none())
                    {
                        self.clear_session(cx);
                    }
                    return;
                }
                if let Some(session) = &self.session
                    && session.field_id == field_id
                    && session.remaining == fitted
                    && self.session_kind == kind
                {
                    self.session_guard = guard;
                    return;
                }
                let same_kind = self.session_kind == kind;
                let pending_pair =
                    pending.map(|p| (p.floor.clone(), p.target.clone(), p.truncated));
                let session = match self.session.take() {
                    Some(mut session)
                        if session.field_id == field_id
                            && same_kind
                            && fitted.starts_with(&session.remaining) =>
                    {
                        session.remaining = fitted;
                        session
                    }
                    Some(session)
                        if session.field_id == field_id
                            && session.awaiting.is_some()
                            && !session.remaining.is_empty() =>
                    {
                        self.session = Some(session);
                        return;
                    }
                    _ => {
                        self.predicted_caret = None;
                        self.session_after = field.after.clone();
                        if let Some((floor, target, truncated)) = pending_pair {
                            let mut next = GhostSession::new(
                                field_id,
                                target,
                                fitted,
                                truncated || field.before_truncated,
                            );
                            next.awaiting = Some(floor);
                            next
                        } else {
                            GhostSession::new(
                                field_id,
                                field.before.clone(),
                                fitted,
                                field.before_truncated,
                            )
                        }
                    }
                };
                self.session = Some(session);
                self.session_kind = kind;
                self.session_guard = guard;
                self.present(cx);
            }
            AutocompleteUpdate::Clear => {
                self.clear_session(cx);
                self.practice.kind = None;
                if self.practice.session.take().is_some() {
                    cx.notify();
                }
            }
            AutocompleteUpdate::Measures(measures) => {
                self.measures = *measures;
                cx.notify();
            }
            AutocompleteUpdate::Learning(learning) => {
                self.learning = learning;
                cx.notify();
            }
            AutocompleteUpdate::MemoryUse { sources, searched } => {
                self.memory_use = (sources, searched);
                cx.notify();
            }
            AutocompleteUpdate::ServerProblem(problem) => {
                self.server_problem = problem;
                cx.notify();
            }
            AutocompleteUpdate::Rehearsal(rehearsal) => {
                self.rehearsal = Some(rehearsal);
                cx.notify();
            }
        }
    }

    fn fitted(
        &self,
        field_id: u64,
        before: &str,
        before_truncated: bool,
        text: &str,
        kind: &SuggestionKind,
    ) -> String {
        match kind {
            SuggestionKind::Continuation | SuggestionKind::Emoji => self
                .sent
                .fit(field_id, before, before_truncated, text, Instant::now())
                .to_string(),
            SuggestionKind::Macro { .. } | SuggestionKind::Correction { .. } => text.to_string(),
        }
    }

    fn present(&mut self, cx: &mut Context<Self>) {
        let settings = self.settings(cx).clone();
        let target = match (&self.session, &self.current) {
            (Some(session), Some(current))
                if session.field_id == current.id && !session.remaining.is_empty() =>
            {
                let (drawn, emphasis) = drawn_ghost(session, &self.session_kind, &settings);
                let whole = self.session_kind != SuggestionKind::Continuation;
                let mut field = current.field.clone();
                let awaiting = session.awaiting.is_some()
                    || self.pending_insert.as_ref().is_some_and(|p| {
                        p.field_id == session.field_id && p.at.elapsed() < AWAITING_INSERT_TIMEOUT
                    });
                if awaiting {
                    field.after = self.session_after.clone();
                }
                Some((session.field_id, field, drawn, emphasis, whole))
            }
            _ => None,
        };
        let Some((field_id, field, remaining, emphasis, whole)) = target else {
            self.clear_session(cx);
            return;
        };
        if let Some(inline) = self.inline.clone() {
            let Some(shown) = inline_text(&remaining, whole) else {
                self.clear_session(cx);
                return;
            };
            if !whole
                && shown.len() < remaining.len()
                && let Some(session) = self.session.as_mut()
            {
                session.remaining = shown.clone();
            }
            let dark = self.appearance(cx).dark;
            log::debug!(
                "autocomplete: showing {} characters in the field",
                shown.chars().count()
            );
            inline.show_styled(&field, &shown, emphasis.chars().count(), dark);
            self.inline_shown = true;
            self.set_keys_active(true);
            return;
        }
        let raw_caret = self.predicted_caret.unwrap_or(field.caret);
        let mut scale = platform::scale_at(&raw_caret).unwrap_or_else(|| self.overlay.scale());
        let caret = if self.predicted_caret.is_none()
            && field.caret_exact
            && policy::caret_at_end_of_line(&field.after)
            && let Some((prev_id, prev_caret)) = self.held_inline_caret
            && prev_id == field_id
        {
            let s = scale.max(0.5);
            let rtl = lokalbot_ai::autocomplete::is_right_to_left(&field.before);
            let anchor_of = |r: Rect| (if rtl { r.x / s } else { r.right() / s }, r.y / s);
            let ms_since_accept = self
                .last_accept_at
                .map(|at| u64::try_from(at.elapsed().as_millis()).unwrap_or(u64::MAX));
            if (raw_caret.height - prev_caret.height).abs() / s <= 8.0
                && platform::geometry::should_hold_reanchor(
                    anchor_of(prev_caret),
                    anchor_of(raw_caret),
                    ms_since_accept,
                    rtl,
                )
            {
                prev_caret
            } else {
                raw_caret
            }
        } else {
            raw_caret
        };
        let screen = platform::screen_containing(&caret);
        let appearance = self.appearance(cx);
        let sampled = self.background_luminance(&field, caret, appearance.dark);
        let mut final_mode = RenderMode::Pill;
        for _ in 0..2 {
            let Some(placement) = layout::place(
                &remaining,
                &emphasis,
                !whole,
                &field,
                caret,
                screen,
                scale,
                sampled,
                &appearance,
                cx,
            ) else {
                log::debug!("autocomplete: no room for the suggestion at {caret:?}");
                self.clear_session(cx);
                return;
            };
            log::debug!(
                "autocomplete: showing {:?} (exact={}, lum={:?}), {} characters, at {:?}",
                placement.mode,
                field.caret_exact,
                sampled,
                placement.shown.chars().count(),
                placement.frame
            );
            final_mode = placement.mode;
            if placement.mode == RenderMode::Inline && placement.shown.len() < remaining.len() {
                if whole {
                    self.clear_session(cx);
                    return;
                }
                if let Some(session) = self.session.as_mut() {
                    session.remaining = placement.shown.clone();
                }
            }
            let now = self.overlay.show(placement.frame, placement.content, cx);
            if (now - scale).abs() < 0.01 {
                break;
            }
            scale = now;
        }
        if final_mode == RenderMode::Inline {
            self.held_inline_caret = Some((field_id, caret));
        } else {
            self.held_inline_caret = None;
        }
        self.set_keys_active(true);
    }

    fn appearance(&self, cx: &App) -> layout::Appearance {
        let fallback;
        let lb = match cx.try_global::<crate::theme::LbTheme>() {
            Some(theme) => &theme.0,
            None => {
                let dark =
                    crate::theme::is_dark(self.settings(cx).app_theme, cx.window_appearance());
                fallback = if dark {
                    crate::theme::Palette::dark()
                } else {
                    crate::theme::Palette::light()
                };
                &fallback
            }
        };
        layout::Appearance {
            dark: lb.dark,
            ui_font: crate::theme::font_family().into(),
            pill_background: lb.elevated,
            pill_border: lb.separator,
            pill_text: lb.text_secondary,
            pill_emphasis: lb.text,
        }
    }

    fn background_luminance(
        &mut self,
        field: &FieldSnapshot,
        caret: Rect,
        dark_theme: bool,
    ) -> Option<f32> {
        let key = policy::background_cache_key(field, dark_theme);
        if let Some(luminance) = self.luminance.get(&key) {
            return Some(*luminance);
        }
        if self.overlay.is_visible() {
            return None;
        }
        let luminance = platform::sample_luminance(&caret, field.field_frame)?;
        if self.luminance.len() >= 128 {
            self.luminance.clear();
        }
        self.luminance.insert(key, luminance);
        Some(luminance)
    }

    fn on_accept_key(&mut self, key: InterceptedKey, cx: &mut Context<Self>) {
        log::debug!("autocomplete: {key:?} taken from the focused app");
        self.last_key = Some(Instant::now());
        let Some(keys) = self.keys.clone() else {
            return;
        };
        let settings = self.settings(cx).clone();
        let revoked = self
            .session_guard
            .as_ref()
            .is_some_and(|guard| !guard.is_current(Policy::from_settings(&settings)));
        let now = Instant::now();
        let plan = (|| {
            let whole = self.accept_keys.is_full(key)?;
            if revoked {
                return None;
            }
            let session = self.session.as_ref()?;
            let current = self.current.as_ref()?;
            if session.field_id != current.id || !self.ghost_visible() {
                return None;
            }
            if should_pass_tab_to_host(&settings, whole, &current.field) {
                return None;
            }
            let synced = current.field.before == session.anchor
                || session.awaiting.is_some()
                || ((current.field.before_truncated || session.anchor_truncated)
                    && typed_since(&session.anchor, &current.field.before, true) == Some(""));
            if !synced {
                return None;
            }
            let suggestion_key = format!(
                "{}\u{1f}{}{}",
                session.field_id, session.anchor, session.remaining
            );
            let effective_whole = self.double_tap.resolve(
                whole,
                settings.cotyping_full_accept_key,
                &suggestion_key,
                now,
            );
            plan_acceptance(
                &session.remaining,
                &self.session_kind,
                &session.anchor,
                &self.session_after,
                &settings,
                effective_whole,
            )
        })();
        let Some(plan) = plan else {
            self.pending_insert = None;
            self.pass_through(&keys, key);
            self.clear_session(cx);
            if revoked {
                crate::bridge::send(Command::Autocomplete(AutocompleteCommand::Dismiss), cx);
            }
            return;
        };
        let dark = self.appearance(cx).dark;
        let (Some(session), Some(current)) = (self.session.as_mut(), self.current.as_ref()) else {
            return;
        };
        let field_id = session.field_id;
        let truncated = session.anchor_truncated || current.field.before_truncated;
        let around = (session.anchor.clone(), self.session_after.clone());
        if self.inline.is_none()
            && let Some(inserter) = &self.inserter
        {
            let _ = inserter.jobs.send(InsertJob::Type {
                field_id,
                field: Box::new(current.field.clone()),
                edit: plan.edit.clone(),
            });
        }
        session.accept(&plan.chunk, &plan.edit.text, plan.edit.backward);
        let accepted_anchor = session.anchor.clone();
        let floor = session.awaiting.clone().unwrap_or_else(|| around.0.clone());
        if let Some(inline) = &self.inline {
            let (drawn, next_emphasis) = drawn_ghost(session, &self.session_kind, &settings);
            let next = inline_text(&drawn, false).unwrap_or_default();
            inline.accept_styled(
                &current.field,
                &around.0,
                &around.1,
                &plan.edit,
                &next,
                next_emphasis.chars().count(),
                dark,
            );
        }
        let exhausted = session.is_exhausted();
        let now = Instant::now();
        self.last_accept_at = Some(now);
        self.sent.record(field_id, &accepted_anchor, truncated, now);
        if self.inline.is_none() {
            PendingInsert::record(
                &mut self.pending_insert,
                field_id,
                &floor,
                accepted_anchor,
                truncated,
                now,
            );
        }
        self.session_after = drop_graphemes(&self.session_after, plan.edit.forward);
        crate::bridge::send(
            Command::Autocomplete(AutocompleteCommand::Accepted {
                field_id,
                text: plan.chunk.clone(),
                inserted: plan.edit.text.clone(),
            }),
            cx,
        );
        if exhausted {
            self.clear_session(cx);
            return;
        }
        self.predicted_caret = self.caret_after(&plan.edit.text, cx);
        self.present(cx);
    }

    fn caret_after(&self, typed: &str, cx: &App) -> Option<Rect> {
        let current = self.current.as_ref()?;
        let field = &current.field;
        let caret = self.predicted_caret.unwrap_or(field.caret);
        let scale = self.overlay.scale().max(0.5);
        let style = field.style.as_ref();
        let size = platform::geometry::ghost_font_px(
            style
                .and_then(|s| s.font_points)
                .map(platform::geometry::points_to_px),
            caret.height / scale,
            field.caret_exact,
        );
        let family: gpui_kit::SharedString = style
            .and_then(|s| s.font_family.clone())
            .map(Into::into)
            .unwrap_or_else(|| crate::theme::font_family().into());
        let measure = layout::measurer(cx, &family, size);
        let logical =
            |r: Rect| Rect::new(r.x / scale, r.y / scale, r.width / scale, r.height / scale);
        let anchor = self.session.as_ref().map_or("", |s| s.anchor.as_str());
        let preceding = anchor
            .strip_suffix(typed)
            .unwrap_or(anchor)
            .rsplit('\n')
            .next()
            .unwrap_or("");
        let input = platform::geometry::InlineInput {
            caret: platform::geometry::inline_caret_box(logical(caret), size),
            field: field.field_frame.map(logical),
            preceding_line: preceding,
            screen: platform::screen_containing(&caret).map(logical),
            right_to_left: lokalbot_ai::autocomplete::is_right_to_left(anchor),
            lines_below_free: field.after.trim().is_empty(),
            metrics: platform::geometry::FontMetrics {
                line_height: size * 1.25,
            },
        };
        let moved =
            platform::geometry::InlineLayout::caret_after_typing(typed, &input, None, &measure)?;
        Some(Rect::new(
            moved.x * scale,
            moved.y * scale,
            moved.width * scale,
            moved.height * scale,
        ))
    }

    fn on_escape(&mut self, cx: &mut Context<Self>) {
        self.last_key = Some(Instant::now());
        let Some(keys) = self.keys.clone() else {
            return;
        };
        if self.session.is_none() || !self.ghost_visible() {
            self.pass_through(&keys, InterceptedKey::Escape);
            return;
        }
        match self.settings(cx).cotyping_escape_behavior {
            CotypingEscapeBehavior::Pause => {
                if let Some(current) = &self.current {
                    self.escape.pause(current.identity.clone(), Instant::now());
                }
            }
            CotypingEscapeBehavior::PassThrough => {
                self.pass_through(&keys, InterceptedKey::Escape);
            }
        }
        self.pending_insert = None;
        self.clear_session(cx);
        crate::bridge::send(Command::Autocomplete(AutocompleteCommand::Dismiss), cx);
    }

    fn pass_through(&self, keys: &Arc<KeyInterceptor>, key: InterceptedKey) {
        if let Some(inserter) = &self.inserter {
            let _ = inserter.jobs.send(InsertJob::PassThrough {
                keys: keys.clone(),
                key,
            });
        } else {
            keys.pass_through(key);
        }
    }

    fn leave_field(&mut self, cx: &mut Context<Self>) {
        let had = self.session.is_some() || self.current.is_some();
        self.pending_insert = None;
        self.clear_session(cx);
        self.current = None;
        self.sent.clear();
        if had && self.last_context.take().is_some() {
            crate::bridge::send(Command::Autocomplete(AutocompleteCommand::LeftField), cx);
        }
    }

    fn clear_session(&mut self, cx: &mut Context<Self>) {
        self.session = None;
        self.session_guard = None;
        self.predicted_caret = None;
        self.held_inline_caret = None;
        self.last_accept_at = None;
        self.double_tap.reset();
        self.overlay.hide(cx);
        if self.inline_shown {
            self.inline_shown = false;
            if let (Some(inline), Some(current)) = (&self.inline, &self.current) {
                inline.show(&current.field, "");
            }
        }
        self.set_keys_active(false);
    }

    fn is_awaiting_insert(&mut self, field_id: u64, before: &str, before_truncated: bool) -> bool {
        PendingInsert::holds_context(
            &mut self.pending_insert,
            field_id,
            before,
            before_truncated,
            Instant::now(),
        )
    }

    fn ghost_visible(&self) -> bool {
        self.inline_shown || self.overlay.is_visible()
    }

    fn set_keys_active(&mut self, active: bool) {
        if active == self.keys_active {
            return;
        }
        log::debug!("autocomplete: taking the accept keys and Esc: {active}");
        self.keys_active = active;
        if let Some(keys) = &self.keys {
            keys.set_active(active);
        }
    }

    pub fn practice_changed(&mut self, before: String, after: String, cx: &mut Context<Self>) {
        let unchanged = self.practice.before == before && self.practice.after == after;
        let after_changed = lokalbot_ai::autocomplete::inline_after(&self.practice.after)
            != lokalbot_ai::autocomplete::inline_after(&after);
        self.practice.before = before.clone();
        self.practice.after = after.clone();
        if unchanged {
            return;
        }
        self.rehearsal = None;
        if let Some(session) = self.practice.session.as_mut() {
            let kind = self
                .practice
                .kind
                .clone()
                .unwrap_or(SuggestionKind::Continuation);
            if kind == SuggestionKind::Emoji
                && !after_changed
                && lokalbot_ai::autocomplete::emoji_ghost(&before, &session.remaining).is_some()
            {
                session.anchor = before.clone();
            } else {
                let continuation = kind == SuggestionKind::Continuation;
                match session.reconcile(&before, false) {
                    Reconcile::Unchanged if !after_changed => {}
                    Reconcile::Advanced { .. } if !after_changed && continuation => {}
                    _ => self.practice.session = None,
                }
            }
            cx.notify();
        }
        if self.paused || !self.settings(cx).cotyping_enabled {
            return;
        }
        if self
            .practice
            .escape_until
            .is_some_and(|until| Instant::now() < until)
        {
            return;
        }
        let use_visible = self.settings(cx).cotyping_use_visible_context;
        let visible = use_visible.then(|| {
            PRACTICE_CONVERSATION
                .iter()
                .map(|(sender, text)| format!("{sender}: {text}"))
                .collect::<Vec<_>>()
                .join(" | ")
        });
        self.send(
            FieldContext {
                field_id: PRACTICE_FIELD_ID,
                app_name: "LokalBot".into(),
                app_id: lokalbot_platform::privacy::SELF_APP_ID.into(),
                window_title: String::new(),
                before,
                after,
                visible_text: visible,
                url: None,
                single_line: false,
                integrated_terminal: false,
                field_frame: None,
                pid: 0,
            },
            false,
            cx,
        );
    }

    pub fn practice_accept(&mut self, whole: bool, cx: &mut Context<Self>) -> Option<Edit> {
        let settings = self.settings(cx).clone();
        let kind = self
            .practice
            .kind
            .clone()
            .unwrap_or(SuggestionKind::Continuation);
        let session = self.practice.session.as_mut()?;
        if session.anchor != self.practice.before {
            self.practice_double_tap.reset();
            return None;
        }
        let suggestion_key = format!("{}{}", session.anchor, session.remaining);
        let effective_whole = self.practice_double_tap.resolve(
            whole,
            settings.cotyping_full_accept_key,
            &suggestion_key,
            Instant::now(),
        );
        let plan = plan_acceptance(
            &session.remaining,
            &kind,
            &self.practice.before,
            &self.practice.after,
            &settings,
            effective_whole,
        )?;
        session.accept(&plan.chunk, &plan.edit.text, plan.edit.backward);
        if session.is_exhausted() {
            self.practice.session = None;
            self.practice_double_tap.reset();
        }
        crate::bridge::send(
            Command::Autocomplete(AutocompleteCommand::Accepted {
                field_id: PRACTICE_FIELD_ID,
                text: plan.chunk.clone(),
                inserted: plan.edit.text.clone(),
            }),
            cx,
        );
        cx.notify();
        Some(plan.edit)
    }

    pub fn practice_drop(&mut self, cx: &mut Context<Self>) {
        self.practice_double_tap.reset();
        if self.practice.session.take().is_some() {
            crate::bridge::send(Command::Autocomplete(AutocompleteCommand::Dismiss), cx);
            cx.notify();
        }
    }

    pub fn practice_dismiss(&mut self, cx: &mut Context<Self>) -> bool {
        self.practice_double_tap.reset();
        if self.practice.session.take().is_none() {
            return false;
        }
        self.practice.escape_until = Some(Instant::now() + policy::ESCAPE_PAUSE);
        crate::bridge::send(Command::Autocomplete(AutocompleteCommand::Dismiss), cx);
        cx.notify();
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use lokalbot_core::settings::AcceptGranularity;

    #[test]
    fn one_tab_takes_the_next_word_with_its_space() {
        let settings = Settings {
            cotyping_accept_granularity: AcceptGranularity::Word,
            ..Default::default()
        };
        let kind = SuggestionKind::Continuation;
        let plan =
            plan_acceptance(" up on the plan", &kind, "follow", "", &settings, false).unwrap();
        assert_eq!(plan.chunk, " up");
        assert_eq!(plan.edit.text, " up");
        let whole =
            plan_acceptance(" up on the plan", &kind, "follow", "", &settings, true).unwrap();
        assert_eq!(whole.chunk, " up on the plan");
        assert!(plan_acceptance("", &kind, "follow", "", &settings, false).is_none());
    }

    #[test]
    fn replacements_take_their_token_and_draw_their_preview() {
        let settings = Settings::default();
        let kind = SuggestionKind::Macro {
            query: "5+5".into(),
            preview: "= 10".into(),
        };
        let plan = plan_acceptance("10", &kind, "Total /5+5", "", &settings, false).unwrap();
        assert_eq!(plan.edit.text, "10");
        assert_eq!(plan.edit.backward, 4);
        let session = GhostSession::new(1, "Total /5+5".into(), "10".into(), false);
        assert_eq!(
            drawn_ghost(&session, &kind, &settings),
            ("= 10".to_string(), "= 10".to_string())
        );
        let fix = SuggestionKind::Correction {
            typo: "wrld".into(),
        };
        let fixed = plan_acceptance("world", &fix, "a wrld ", "", &settings, false).unwrap();
        assert_eq!(fixed.edit.text, "world ");
        assert_eq!(fixed.edit.backward, 5);
    }

    #[test]
    fn double_tap_promotes_second_accept_within_window() {
        let mut state = DoubleTapAcceptance::default();
        let start = Instant::now();
        assert!(!state.resolve(false, CotypingFullAcceptKey::DoubleTap, "s1", start));
        assert!(state.resolve(
            false,
            CotypingFullAcceptKey::DoubleTap,
            "s1",
            start + Duration::from_millis(200),
        ));
        assert!(!state.resolve(
            false,
            CotypingFullAcceptKey::DoubleTap,
            "s1",
            start + Duration::from_millis(250),
        ));
        assert!(!state.resolve(
            false,
            CotypingFullAcceptKey::DoubleTap,
            "s1",
            start + Duration::from_millis(600),
        ));
    }

    #[test]
    fn tab_form_navigation_applies_only_to_single_line_non_chat_non_editor_fields() {
        let mut settings = Settings {
            cotyping_tab_moves_to_next_field: true,
            cotyping_accept_key: CotypingAcceptKey::Tab,
            ..Default::default()
        };
        let mut field = FieldSnapshot {
            app_name: "Firefox".into(),
            app_id: "firefox".into(),
            single_line: true,
            ..Default::default()
        };
        assert!(should_pass_tab_to_host(&settings, false, &field));
        assert!(!should_pass_tab_to_host(&settings, true, &field));
        field.single_line = false;
        assert!(!should_pass_tab_to_host(&settings, false, &field));
        field.single_line = true;
        field.app_id = "slack".into();
        field.app_name = "Slack".into();
        assert!(!should_pass_tab_to_host(&settings, false, &field));
        field.app_id = "code".into();
        field.app_name = "Visual Studio Code".into();
        assert!(!should_pass_tab_to_host(&settings, false, &field));
        field.app_id = "firefox".into();
        field.app_name = "Firefox".into();
        settings.cotyping_accept_key = CotypingAcceptKey::RightArrow;
        assert!(!should_pass_tab_to_host(&settings, false, &field));
    }

    #[test]
    fn settings_shape_what_a_press_takes() {
        let punctuation = Settings {
            cotyping_auto_accept_trailing_punctuation: true,
            ..Default::default()
        };
        let plan = plan_acceptance(
            " yes, please",
            &SuggestionKind::Continuation,
            "oh",
            "",
            &punctuation,
            false,
        )
        .unwrap();
        assert_eq!(plan.chunk, " yes,");
    }

    #[test]
    fn an_emoji_replaces_its_shortcode() {
        let settings = Settings::default();
        let plan = plan_acceptance(
            "🚀",
            &SuggestionKind::Emoji,
            "Launch :rocket",
            "",
            &settings,
            false,
        )
        .unwrap();
        assert_eq!(plan.chunk, "🚀");
        assert_eq!(plan.edit.text, "🚀");
        assert_eq!(plan.edit.backward, ":rocket".chars().count());
    }

    #[test]
    fn pending_insert_holds_intermediate_echoes_until_settled_or_diverged() {
        let t0 = Instant::now();
        let mut slot = None;
        PendingInsert::record(&mut slot, 7, "Hello", "Hello world".into(), false, t0);
        assert!(PendingInsert::holds_context(
            &mut slot, 7, "Hello ", false, t0
        ));
        assert!(PendingInsert::holds_context(
            &mut slot, 7, "Hello wo", false, t0
        ));
        PendingInsert::record(
            &mut slot,
            7,
            "Hello world",
            "Hello world friend".into(),
            false,
            t0,
        );
        assert!(PendingInsert::holds_context(
            &mut slot,
            7,
            "Hello wor",
            false,
            t0
        ));
        assert!(PendingInsert::holds_context(
            &mut slot,
            7,
            "Hello world fri",
            false,
            t0
        ));
        assert!(!PendingInsert::holds_context(
            &mut slot,
            7,
            "Hello world friend",
            false,
            t0
        ));
        assert!(slot.is_none());

        let base: String = (0..1000).map(|i| format!("w{i:03} ")).collect();
        let floor = base[base.len() - 4090..].to_string();
        let target = format!("{floor} alpha beta");
        PendingInsert::record(&mut slot, 9, &floor, target, true, t0);
        let mid = format!("{} alpha", &floor[6..]);
        assert!(PendingInsert::holds_context(&mut slot, 9, &mid, true, t0));
        let done = format!("{} alpha beta", &floor[11..]);
        assert!(!PendingInsert::holds_context(&mut slot, 9, &done, true, t0));
        assert!(slot.is_none());

        PendingInsert::record(&mut slot, 7, "Hello", "Hello world".into(), false, t0);
        assert!(!PendingInsert::holds_context(
            &mut slot,
            7,
            "Hello wox",
            false,
            t0
        ));
        assert!(slot.is_none());

        PendingInsert::record(&mut slot, 7, "Hello", "Hello world".into(), false, t0);
        assert!(!PendingInsert::holds_context(
            &mut slot,
            7,
            "Hello wo",
            false,
            t0 + AWAITING_INSERT_TIMEOUT
        ));
        assert!(slot.is_none());
    }

    #[test]
    fn film_ghost_matches_flag_or_env_one() {
        let none: Vec<String> = vec!["lokalbot".into()];
        let flag: Vec<String> = vec!["lokalbot".into(), FILM_GHOST_ARG.into()];
        assert!(!film_ghost_requested(None, &none));
        assert!(!film_ghost_requested(Some(""), &none));
        assert!(!film_ghost_requested(Some("0"), &none));
        assert!(!film_ghost_requested(Some("true"), &none));
        assert!(!film_ghost_requested(Some(" 1"), &none));
        assert!(film_ghost_requested(Some("1"), &none));
        assert!(film_ghost_requested(None, &flag));
    }
}
