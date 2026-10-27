// Contains code ported from Cotabby (https://github.com/FuJacob/cotabby),
// copyright the Cotabby authors, under the GNU AGPL v3.0
// (LICENSES/AGPL-3.0.txt). Modified for LokalBot since 18 October 2026.
// See THIRD_PARTY_NOTICES.md.

//! Autocomplete in other apps (`CotypingCoordinator*.swift`): the field
//! watcher's snapshots go to the engine as [`FieldContext`]s, the engine's
//! suggestions come back as ghost text after the caret, Tab types the next
//! word or phrase, and Esc dismisses.
//!
//! Invariant, as on macOS: a session exists exactly while ghost text is on
//! screen, and only then are Tab and Esc taken from other apps. Typing the
//! ghost's next characters, or the app showing what an accept typed, shortens
//! it at once; anything else leaves it behind.
//!
//! Autocomplete stays quiet while dictation runs or a meeting records, in a
//! field for ten seconds after Esc, in LokalBot's own windows (the practice
//! editor in Settings → Writing feeds the engine itself), and whenever
//! `cotyping_enabled` is off. `LOKALBOT_FAKE_AUTOCOMPLETE=<text>` makes the
//! app suggest `<text>` itself instead of asking the engine, for checking the
//! desktop side without a model; it is a development switch, off unless set.

mod layout;
pub mod overlay;

use std::sync::Arc;
use std::time::{Duration, Instant};

use gpui_kit::{App, AppContext as _, Context, Entity, Global, Task};
use lokalbot_core::Settings;
use lokalbot_engine::{AutocompleteCommand, AutocompleteUpdate, Command, FieldContext};
use lokalbot_platform::autocomplete::geometry::RenderMode;
use lokalbot_platform::autocomplete::policy::{self, EscapePause, ReadPolicy};
use lokalbot_platform::autocomplete::session::{
    GhostSession, Reconcile, SentContexts, drop_graphemes,
};
use lokalbot_platform::autocomplete::{
    self as platform, Capability, Edit, FieldSnapshot, FieldWatcher, FocusSnapshot, InterceptedKey,
    KeyInterceptor, Rect, Support,
};

use crate::state::{AppData, DictationHud};

/// The practice editor's field id. Real fields count up from 1.
pub const PRACTICE_FIELD_ID: u64 = u64::MAX;

/// How long after a taken key a loss of focus waits before the ghost goes.
/// An X11 key grab gives the focused app a short focus loss, which GTK 4
/// reports as no focused field until the key is released.
const KEY_FOCUS_GRACE: Duration = Duration::from_millis(500);

/// The sample exchange above the practice editor
/// (`CotypingRehearsalConversation.sample`), offered as the text above the
/// field.
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

/// What one Tab does: the chunk the suggestion gives up, what is typed, and
/// what is deleted around the caret first (the engine's `plan_acceptance`,
/// `CotypingContinuationAcceptance`): a space the field already has is not
/// typed twice, a new sentence gets its space, the rest of a word the caret
/// is inside of is replaced, and an emoji replaces its `:shortcode`.
struct Acceptance {
    chunk: String,
    edit: Edit,
}

fn plan_acceptance(
    remaining: &str,
    before: &str,
    after: &str,
    settings: &Settings,
    whole: bool,
) -> Option<Acceptance> {
    let plan = if whole {
        lokalbot_ai::autocomplete::plan_full_acceptance(remaining, before, after)
    } else {
        lokalbot_ai::autocomplete::plan_acceptance(
            remaining,
            settings.cotyping_accept_granularity,
            before,
            after,
        )
    }?;
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

/// The text to draw for a session and the part of it the next Tab takes:
/// an emoji shows with its shortcode ("🚀 :rocket:") and goes in one press.
fn drawn_ghost(session: &GhostSession, settings: &Settings) -> (String, String) {
    match lokalbot_ai::autocomplete::emoji_ghost(&session.anchor, &session.remaining) {
        Some(ghost) => (ghost, session.remaining.clone()),
        None => (
            session.remaining.clone(),
            lokalbot_ai::autocomplete::accept_chunk(
                &session.remaining,
                settings.cotyping_accept_granularity,
            ),
        ),
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

/// The field the user is typing in.
struct Current {
    id: u64,
    identity: String,
    field: FieldSnapshot,
}

/// The practice editor's suggestion (`CotypingRehearsal`).
#[derive(Default)]
pub struct Practice {
    pub session: Option<GhostSession>,
    before: String,
    after: String,
    escape_until: Option<Instant>,
}

impl Practice {
    /// The ghost to draw after the practice caret and how many characters
    /// the next Tab takes.
    pub fn ghost(&self, settings: &Settings) -> Option<(String, usize)> {
        let session = self.session.as_ref()?;
        if session.remaining.is_empty() {
            return None;
        }
        let (drawn, emphasis) = drawn_ghost(session, settings);
        Some((drawn, emphasis.chars().count()))
    }
}

/// Inserts accepted chunks one after another on a thread of their own, so
/// two quick Tabs land in order and the UI never waits on the other app.
struct Inserter {
    jobs: crossbeam_channel::Sender<(u64, FieldSnapshot, Edit)>,
}

impl Inserter {
    fn start(events: smol::channel::Sender<Event>) -> Option<Self> {
        let (jobs, receiver) = crossbeam_channel::unbounded::<(u64, FieldSnapshot, Edit)>();
        std::thread::Builder::new()
            .name("lokalbot-autocomplete-insert".into())
            .spawn(move || {
                while let Ok((field_id, field, edit)) = receiver.recv() {
                    let ok = match platform::insert(&field, &edit) {
                        Ok(()) => true,
                        Err(err) => {
                            log::warn!("autocomplete: could not type the suggestion: {err:#}");
                            false
                        }
                    };
                    let _ = events.send_blocking(Event::Inserted { field_id, ok });
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
    running: bool,
    paused: bool,
    policy: ReadPolicy,
    current: Option<Current>,
    next_id: u64,
    session: Option<GhostSession>,
    /// The text after the caret when the suggestion was shown; a change
    /// there leaves the suggestion behind.
    session_after: String,
    /// Where the caret will be once the app shows an accept.
    predicted_caret: Option<Rect>,
    sent: SentContexts,
    last_context: Option<FieldContext>,
    escape: EscapePause,
    overlay: overlay::Overlay,
    keys_active: bool,
    /// When Tab or Esc was last taken from the focused app.
    last_key: Option<Instant>,
    /// Bumped by every focus report, so a deferred leave knows it is stale.
    focus_generation: u64,
    /// Pixels behind the ghost, sampled once per app with no colors reported.
    luminance: std::collections::HashMap<String, f32>,
    fake: Option<String>,
    fake_task: Option<Task<()>>,
    pub practice: Practice,
}

/// Starts autocomplete's desktop side; it follows the settings from then on.
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
            running: false,
            paused: false,
            policy: ReadPolicy::default(),
            current: None,
            next_id: 0,
            session: None,
            session_after: String::new(),
            predicted_caret: None,
            sent: SentContexts::default(),
            last_context: None,
            escape: EscapePause::default(),
            overlay: overlay::Overlay::new(true),
            keys_active: false,
            last_key: None,
            focus_generation: 0,
            luminance: Default::default(),
            fake,
            fake_task: None,
            practice: Practice::default(),
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
}

/// An engine update, from `bridge.rs`. Applied after the current update so
/// the app state can be read.
pub fn engine_update(update: AutocompleteUpdate, cx: &mut App) {
    cx.defer(move |cx| {
        if let Some(entity) = global(cx) {
            entity.update(cx, |this, cx| this.on_engine(update, cx));
        }
    });
}

impl Autocomplete {
    /// Whether autocomplete can work in other apps here, worded for Settings.
    pub fn support(&self) -> &Support {
        &self.support
    }

    /// What the field watcher cannot read on this desktop, if anything.
    pub fn limitation(&self) -> Option<String> {
        self.watcher.as_ref().and_then(FieldWatcher::limitation)
    }

    fn settings<'a>(&self, cx: &'a App) -> &'a Settings {
        &self.data.read(cx).settings
    }

    /// Follows settings, dictation and recording: starts or stops the
    /// watcher, applies exclusions, pauses and resumes.
    fn sync(&mut self, cx: &mut Context<Self>) {
        let (enabled, paused, policy) = {
            let data = self.data.read(cx);
            let settings = &data.settings;
            let enabled = settings.cotyping_enabled;
            let paused = data.dictation != DictationHud::Idle || data.recording.is_active();
            let policy = ReadPolicy {
                enabled: enabled && !paused,
                excluded_apps: settings.cotyping_excluded_app_list(),
                excluded_domains: settings.cotyping_excluded_domain_list(),
                capture_excluded_apps: settings.excluded_app_list(),
                capture_excluded_domains: settings.excluded_domain_list(),
                visible_text: settings.cotyping_use_visible_context,
            };
            (enabled, paused, policy)
        };
        if paused != self.paused {
            self.paused = paused;
            if paused {
                // No ghost appears while dictation runs or a meeting records.
                self.dismiss_everything(cx);
            }
        }
        let wants = enabled && self.support == Support::Available;
        if wants && !self.running {
            self.start_watching(policy.clone(), cx);
        } else if !wants && self.running {
            self.stop_watching(cx);
        }
        if !enabled && (self.practice.session.is_some() || self.last_context.is_some()) {
            // Turned off: no ghost lingers anywhere.
            self.dismiss_everything(cx);
        }
        if policy != self.policy {
            let exclusions_changed = policy.excluded_apps != self.policy.excluded_apps
                || policy.excluded_domains != self.policy.excluded_domains
                || policy.visible_text != self.policy.visible_text;
            self.policy = policy.clone();
            if let Some(watcher) = &self.watcher {
                watcher.set_policy(policy);
            }
            if exclusions_changed {
                self.leave_field(cx);
            }
        }
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
                self.watcher = Some(watcher);
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
        self.watcher = None;
        if let Some(keys) = self.keys.take() {
            keys.set_active(false);
        }
        self.inserter = None;
        self.keys_active = false;
        self.running = false;
        self.overlay.close(cx);
        log::info!("autocomplete: stopped");
        cx.notify();
    }

    /// Hides every ghost and tells the engine to drop its work.
    fn dismiss_everything(&mut self, cx: &mut Context<Self>) {
        self.leave_field(cx);
        self.practice.session = None;
        self.fake_task = None;
        self.last_context = None;
        crate::bridge::send(Command::Autocomplete(AutocompleteCommand::Dismiss), cx);
        cx.notify();
    }

    fn handle(&mut self, event: Event, cx: &mut Context<Self>) {
        match event {
            Event::Focus(focus) => self.on_focus(*focus, cx),
            Event::Key(InterceptedKey::Tab) => self.on_tab(cx),
            Event::Key(InterceptedKey::Escape) => self.on_escape(cx),
            Event::Inserted { field_id, ok } => {
                if !ok
                    && self
                        .session
                        .as_ref()
                        .is_some_and(|s| s.field_id == field_id)
                {
                    self.clear_session(cx);
                    crate::bridge::send(Command::Autocomplete(AutocompleteCommand::Dismiss), cx);
                }
            }
        }
    }

    fn on_focus(&mut self, focus: FocusSnapshot, cx: &mut Context<Self>) {
        if !self.running || self.paused {
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
                    // Probably the grab of the key just taken: the ghost
                    // stays unless the field is still gone after a moment.
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
        if !same {
            self.leave_field(cx);
            self.next_id += 1;
            self.sent.clear();
        }
        let id = if same {
            self.current.as_ref().map_or(self.next_id, |c| c.id)
        } else {
            self.next_id
        };
        self.current = Some(Current {
            id,
            identity: identity.clone(),
            field: field.clone(),
        });
        if self.escape.is_paused(&identity, Instant::now()) {
            self.clear_session(cx);
            return;
        }
        self.reconcile_session(&field, cx);
        self.send_context(id, &field, cx);
    }

    /// Moves or shortens the visible ghost for the field's new state.
    fn reconcile_session(&mut self, field: &FieldSnapshot, cx: &mut Context<Self>) {
        let Some(session) = self.session.as_mut() else {
            return;
        };
        let awaiting = session.awaiting.is_some();
        let outcome = session.reconcile(&field.before, field.before_truncated);
        let after_changed = field.after != self.session_after && !awaiting;
        match outcome {
            _ if after_changed => self.clear_session(cx),
            Reconcile::Stale | Reconcile::Exhausted => self.clear_session(cx),
            Reconcile::Advanced { .. } => {
                self.predicted_caret = None;
                self.present(cx);
            }
            Reconcile::Unchanged => {
                if self.session.as_ref().is_some_and(|s| s.awaiting.is_some()) {
                    return;
                }
                // Every accept is in the field: follow the app's own caret.
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
        };
        self.send(context, cx);
    }

    fn send(&mut self, context: FieldContext, cx: &mut Context<Self>) {
        if self.last_context.as_ref() == Some(&context) {
            return;
        }
        self.sent
            .record(context.field_id, &context.before, Instant::now());
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

    /// The development stand-in for the engine: after the pause before
    /// suggesting, the configured text, unless a ghost already shows.
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
                this.on_engine(AutocompleteUpdate::Suggestion { field_id, text }, cx)
            });
        }));
    }

    fn on_engine(&mut self, update: AutocompleteUpdate, cx: &mut Context<Self>) {
        match update {
            AutocompleteUpdate::Suggestion { field_id, text } if field_id == PRACTICE_FIELD_ID => {
                if self.paused || !self.settings(cx).cotyping_enabled {
                    return;
                }
                let before = self.practice.before.clone();
                let fitted = self
                    .sent
                    .fit(field_id, &before, &text, Instant::now())
                    .to_string();
                log::debug!("autocomplete: practice suggestion {fitted:?}");
                self.practice.session = (!fitted.is_empty())
                    .then(|| GhostSession::new(field_id, before, fitted, false));
                cx.notify();
            }
            AutocompleteUpdate::Suggestion { field_id, text } => {
                if self.paused || !self.running {
                    return;
                }
                let Some(current) = self.current.as_ref().filter(|c| c.id == field_id) else {
                    return;
                };
                let field = current.field.clone();
                let fitted = self
                    .sent
                    .fit(field_id, &field.before, &text, Instant::now())
                    .to_string();
                if fitted.is_empty() {
                    self.clear_session(cx);
                    return;
                }
                if let Some(session) = &self.session
                    && session.field_id == field_id
                    && session.remaining == fitted
                {
                    return;
                }
                // A suggestion that grows the visible one keeps its anchor;
                // anything else starts from the field as it is now.
                let session = match self.session.take() {
                    Some(mut session)
                        if session.field_id == field_id
                            && fitted.starts_with(&session.remaining) =>
                    {
                        session.remaining = fitted;
                        session
                    }
                    _ => {
                        self.predicted_caret = None;
                        self.session_after = field.after.clone();
                        GhostSession::new(
                            field_id,
                            field.before.clone(),
                            fitted,
                            field.before_truncated,
                        )
                    }
                };
                self.session = Some(session);
                self.present(cx);
            }
            AutocompleteUpdate::Clear => {
                self.clear_session(cx);
                if self.practice.session.take().is_some() {
                    cx.notify();
                }
            }
        }
    }

    /// Draws the session's ghost at the field's caret, or drops it when it
    /// has nowhere to go.
    fn present(&mut self, cx: &mut Context<Self>) {
        let settings = self.settings(cx).clone();
        let target = match (&self.session, &self.current) {
            (Some(session), Some(current))
                if session.field_id == current.id && !session.remaining.is_empty() =>
            {
                let (drawn, emphasis) = drawn_ghost(session, &settings);
                let emoji = drawn != session.remaining;
                Some((current.field.clone(), drawn, emphasis, emoji))
            }
            _ => None,
        };
        let Some((field, remaining, emphasis, emoji)) = target else {
            self.clear_session(cx);
            return;
        };
        let caret = self.predicted_caret.unwrap_or(field.caret);
        let screen = platform::screen_containing(&caret);
        let sampled = self.background_luminance(&field, caret);
        let appearance = self.appearance(cx);
        let mut scale = self.overlay.scale();
        for _ in 0..2 {
            let Some(placement) = layout::place(
                &remaining,
                &emphasis,
                &field,
                caret,
                screen,
                scale,
                sampled,
                &appearance,
                cx,
            ) else {
                // No place on screen that covers no text.
                log::debug!("autocomplete: no room for the suggestion at {caret:?}");
                self.clear_session(cx);
                return;
            };
            log::debug!(
                "autocomplete: showing {:?} {:?} at {:?}",
                placement.mode,
                placement.shown,
                placement.frame
            );
            if placement.mode == RenderMode::Inline
                && !emoji
                && placement.shown.len() < remaining.len()
                && let Some(session) = self.session.as_mut()
            {
                // Accept never takes words the user could not see.
                session.remaining = placement.shown.clone();
            }
            let now = self.overlay.show(placement.frame, placement.content, cx);
            if (now - scale).abs() < 0.01 {
                break;
            }
            // The window landed on a monitor with another scale.
            scale = now;
        }
        self.set_keys_active(true);
    }

    fn appearance(&self, cx: &App) -> layout::Appearance {
        // Running in the tray, no window has set the theme yet.
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
            ui_font: crate::theme::FONT_FAMILY.into(),
            pill_background: lb.elevated,
            pill_border: lb.separator,
            pill_text: lb.text_secondary,
            pill_emphasis: lb.text,
        }
    }

    /// Fields that report no colors are read from the screen once per app,
    /// before the ghost covers the spot (`CotypingBackgroundSampler`).
    fn background_luminance(&mut self, field: &FieldSnapshot, caret: Rect) -> Option<f32> {
        let reported = field
            .style
            .as_ref()
            .is_some_and(|s| s.color.is_some() && s.background.is_some());
        if reported {
            return None;
        }
        if let Some(luminance) = self.luminance.get(&field.app_id) {
            return Some(*luminance);
        }
        if self.overlay.is_visible() {
            return None;
        }
        let luminance = platform::sample_luminance(&caret)?;
        self.luminance.insert(field.app_id.clone(), luminance);
        Some(luminance)
    }

    fn on_tab(&mut self, cx: &mut Context<Self>) {
        log::debug!("autocomplete: Tab taken from the focused app");
        self.last_key = Some(Instant::now());
        let Some(keys) = self.keys.clone() else {
            return;
        };
        let settings = self.settings(cx).clone();
        let plan = (|| {
            let session = self.session.as_ref()?;
            let current = self.current.as_ref()?;
            if session.field_id != current.id || !self.overlay.is_visible() {
                return None;
            }
            // The field must read as the ghost expects, or an accept is on its way.
            if current.field.before != session.anchor && session.awaiting.is_none() {
                return None;
            }
            plan_acceptance(
                &session.remaining,
                &session.anchor,
                &self.session_after,
                &settings,
                false,
            )
        })();
        let Some(plan) = plan else {
            // Fail open: the app gets its Tab.
            keys.pass_through(InterceptedKey::Tab);
            self.clear_session(cx);
            return;
        };
        let (Some(session), Some(current)) = (self.session.as_mut(), self.current.as_ref()) else {
            return;
        };
        let field_id = session.field_id;
        if let Some(inserter) = &self.inserter {
            let _ = inserter
                .jobs
                .send((field_id, current.field.clone(), plan.edit.clone()));
        }
        session.accept(&plan.chunk, &plan.edit.text, plan.edit.backward);
        // The rest of a word the caret was inside of goes with the insert.
        self.session_after = drop_graphemes(&self.session_after, plan.edit.forward);
        crate::bridge::send(
            Command::Autocomplete(AutocompleteCommand::Accepted {
                field_id,
                text: plan.chunk.clone(),
            }),
            cx,
        );
        if session.is_exhausted() {
            self.clear_session(cx);
            return;
        }
        // Move the ghost past the accepted text before the app shows it.
        self.predicted_caret = self.caret_after(&plan.edit.text, cx);
        self.present(cx);
    }

    /// Where the caret will be once `typed` is in the field, measured in the
    /// ghost's font, or `None` when only the app can tell.
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
            .unwrap_or_else(|| crate::theme::FONT_FAMILY.into());
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
            caret: logical(caret),
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
        if self.session.is_none() || !self.overlay.is_visible() {
            keys.pass_through(InterceptedKey::Escape);
            return;
        }
        // Esc stops here, so it does not also close a dialog in the app, and
        // the field stays quiet for a while (`CotypingEscapeBehavior.pause`).
        if let Some(current) = &self.current {
            self.escape.pause(current.identity.clone(), Instant::now());
        }
        self.clear_session(cx);
        crate::bridge::send(Command::Autocomplete(AutocompleteCommand::Dismiss), cx);
    }

    /// Focus left the field: its ghost and context go.
    fn leave_field(&mut self, cx: &mut Context<Self>) {
        let had = self.session.is_some() || self.current.is_some();
        self.clear_session(cx);
        self.current = None;
        self.sent.clear();
        if had && self.last_context.take().is_some() {
            crate::bridge::send(Command::Autocomplete(AutocompleteCommand::Dismiss), cx);
        }
    }

    fn clear_session(&mut self, cx: &mut Context<Self>) {
        self.session = None;
        self.predicted_caret = None;
        self.overlay.hide(cx);
        self.set_keys_active(false);
    }

    fn set_keys_active(&mut self, active: bool) {
        if active == self.keys_active {
            return;
        }
        log::debug!("autocomplete: taking Tab and Esc: {active}");
        self.keys_active = active;
        if let Some(keys) = &self.keys {
            keys.set_active(active);
        }
    }

    // ----------------------------------------------------------- practice

    /// The practice editor's text changed; `before` and `after` are the text
    /// on either side of its caret.
    pub fn practice_changed(&mut self, before: String, after: String, cx: &mut Context<Self>) {
        let unchanged = self.practice.before == before && self.practice.after == after;
        let after_changed = self.practice.after != after;
        self.practice.before = before.clone();
        self.practice.after = after.clone();
        if unchanged {
            return;
        }
        if let Some(session) = self.practice.session.as_mut() {
            match session.reconcile(&before, false) {
                Reconcile::Advanced { .. } | Reconcile::Unchanged if !after_changed => {}
                _ => self.practice.session = None,
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
                // No window title, as on macOS: "Settings" would steer the
                // model toward settings talk.
                window_title: String::new(),
                before,
                after,
                visible_text: visible,
                url: None,
                single_line: false,
            },
            cx,
        );
    }

    /// One accept in the practice editor: returns the edit to make at its
    /// caret.
    pub fn practice_accept(&mut self, whole: bool, cx: &mut Context<Self>) -> Option<Edit> {
        let settings = self.settings(cx).clone();
        let session = self.practice.session.as_mut()?;
        if session.anchor != self.practice.before {
            return None;
        }
        let plan = plan_acceptance(
            &session.remaining,
            &self.practice.before,
            &self.practice.after,
            &settings,
            whole,
        )?;
        session.accept(&plan.chunk, &plan.edit.text, plan.edit.backward);
        if session.is_exhausted() {
            self.practice.session = None;
        }
        crate::bridge::send(
            Command::Autocomplete(AutocompleteCommand::Accepted {
                field_id: PRACTICE_FIELD_ID,
                text: plan.chunk.clone(),
            }),
            cx,
        );
        cx.notify();
        Some(plan.edit)
    }

    /// Esc in the practice editor.
    pub fn practice_dismiss(&mut self, cx: &mut Context<Self>) -> bool {
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
        let plan = plan_acceptance(" up on the plan", "follow", "", &settings, false).unwrap();
        assert_eq!(plan.chunk, " up");
        assert_eq!(plan.edit.text, " up");
        let whole = plan_acceptance(" up on the plan", "follow", "", &settings, true).unwrap();
        assert_eq!(whole.chunk, " up on the plan");
        assert!(plan_acceptance("", "follow", "", &settings, false).is_none());
    }

    #[test]
    fn an_emoji_replaces_its_shortcode() {
        let settings = Settings::default();
        let plan = plan_acceptance("🚀", "Launch :rocket", "", &settings, false).unwrap();
        assert_eq!(plan.chunk, "🚀");
        assert_eq!(plan.edit.text, "🚀");
        assert_eq!(plan.edit.backward, ":rocket".chars().count());
    }
}
