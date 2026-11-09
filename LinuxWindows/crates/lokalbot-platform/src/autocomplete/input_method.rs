//! Autocomplete in other apps on Wayland, as the desktop's input method.
//!
//! Wayland lets no ordinary app take a key from another app, place a window
//! at its caret or type into it. An input method is the supported way in: the
//! desktop tells it when a text field has focus, what kind of field it is and
//! the text around the caret, shows its text inline in the field (preedit),
//! and commits text without the clipboard.
//!
//! The field's owner is asked for separately, because the protocol does not
//! say: the compositor names the window in front (see [`surface`]), and
//! accessibility adds what it knows about the field where the app publishes
//! it. Nothing is delivered until that answer is in, so an excluded app, a
//! terminal or a password field never reaches the engine.
//!
//! - [`wlroots`] is the route on Sway and Hyprland (`zwp_input_method_v2`). The
//!   keyboard is grabbed only while a suggestion shows, and every key but the
//!   accept keys and Esc goes straight back through a virtual keyboard.
//! - [`ibus`] is the route on GNOME: an IBus engine over D-Bus, which the user
//!   chooses as an input source. While it is chosen the desktop asks it about
//!   every key, and it answers without keeping them.
//! - [`kwin`] is the route on KDE Plasma (`zwp_input_method_v1`). Plasma talks
//!   to the input method it starts itself, so [`kwin_helper`] holds that
//!   connection for the session and passes the field to the app. As on Sway,
//!   the keyboard is grabbed only while a suggestion shows.
//!
//! [`Core`] is what the routes share: the field, the ghost and what may be read.
//!
//! What this route sees, what it keeps and how it treats other input methods
//! is written down in `PRIVACY.md`. Typed text is never logged here, and never
//! kept past the field's next state.

mod ibus;
mod kwin;
mod kwin_helper;
mod kwin_wire;
mod surface;
mod wlroots;

use std::os::unix::net::UnixStream;
use std::sync::{Arc, LazyLock};
use std::time::{Duration, Instant};

use crossbeam_channel::Sender;
use parking_lot::Mutex;

use super::policy::{self, ReadPolicy, reasons};
use super::{
    AcceptKeys, Capability, Edit, FieldSnapshot, FocusHandler, FocusSnapshot, InputSourceSteps,
    InsertTarget, InterceptedKey, KeyHandler, Rect, Support,
};
use crate::session::Desktop;

/// Prefix of [`FieldSnapshot::focus_key`] on this route; the rest is the
/// activation the field belongs to, so nothing lands in a later field.
const KEY_PREFIX: &str = "im:";

/// What `zwp_text_input_v3` calls a field: its content purpose and hints.
mod content {
    pub const PURPOSE_ALPHA: u32 = 1;
    pub const PURPOSE_NAME: u32 = 7;
    pub const PURPOSE_NORMAL: u32 = 0;
    pub const PURPOSE_PASSWORD: u32 = 8;
    pub const PURPOSE_PIN: u32 = 9;
    pub const PURPOSE_TERMINAL: u32 = 13;

    pub const HINT_HIDDEN_TEXT: u32 = 0x40;
    pub const HINT_SENSITIVE_DATA: u32 = 0x80;
    pub const HINT_MULTILINE: u32 = 0x200;
}

/// What an input method's content type says about a field. Only prose is
/// suggested in.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(super) struct Content {
    pub purpose: u32,
    pub hint: u32,
}

impl Content {
    /// Why this kind of field gets no suggestion, judged before any text.
    fn refusal(&self) -> Option<Capability> {
        use content::*;
        if self.purpose == PURPOSE_PASSWORD
            || self.purpose == PURPOSE_PIN
            || self.hint & (HINT_HIDDEN_TEXT | HINT_SENSITIVE_DATA) != 0
        {
            return Some(Capability::Blocked(reasons::SECURE));
        }
        match self.purpose {
            PURPOSE_NORMAL | PURPOSE_ALPHA | PURPOSE_NAME => None,
            PURPOSE_TERMINAL => Some(Capability::Unsupported(reasons::TERMINAL)),
            // Digits, numbers, phone numbers, addresses and dates, whose Tab
            // belongs to the field.
            _ => Some(Capability::Unsupported(reasons::NOT_PROSE)),
        }
    }

    fn multiline(&self) -> bool {
        self.hint & content::HINT_MULTILINE != 0
    }
}

/// The surrounding text as the desktop gave it; offsets are in bytes.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(super) struct Surrounding {
    pub text: String,
    pub cursor: u32,
    pub anchor: u32,
}

/// The longest surrounding text `zwp_input_method_v2` carries. An app clips
/// longer text to about this, so a window this full may have been clipped.
const SURROUNDING_LIMIT: usize = 4000;
/// Above this a window is treated as clipped.
const CLIPPED_AT: usize = SURROUNDING_LIMIT - 200;

impl Surrounding {
    /// The text on either side of the caret, or `None` when the offsets do
    /// not fall on character boundaries of this text.
    fn split(&self) -> Option<(&str, &str)> {
        let cursor = usize::try_from(self.cursor).ok()?;
        self.text.split_at_checked(cursor)
    }

    fn has_selection(&self) -> bool {
        self.cursor != self.anchor
    }

    /// This text without a ghost the app counted in it. Most apps leave
    /// preedit out of the surrounding text, as the protocol says; Firefox
    /// reports it, with the caret at or inside it. A ghost is not the user's
    /// text and must not read as what follows the caret.
    fn without_preedit(self, shown: &str) -> Self {
        if shown.is_empty() {
            return self;
        }
        let Ok(cursor) = usize::try_from(self.cursor) else {
            return self;
        };
        let found = self
            .text
            .match_indices(shown)
            .map(|(start, _)| start)
            .find(|start| *start <= cursor && cursor < start + shown.len());
        let Some(start) = found else {
            return self;
        };
        let mut text = self.text;
        text.replace_range(start..start + shown.len(), "");
        let start = start as u32;
        Self {
            text,
            cursor: start,
            anchor: start,
        }
    }

    /// Characters a toolkit draws in place of a password's. A field holding
    /// only these is a password field that gave no hint.
    fn is_masked(&self) -> bool {
        !self.text.is_empty()
            && self
                .text
                .chars()
                .all(|c| matches!(c, '•' | '●' | '∗' | '*' | '·' | '⚫' | '⦁'))
    }
}

/// Why a field's owner rules it out, decided before its text is used.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Refusal {
    Blocked(&'static str),
    Unsupported(&'static str),
}

/// Who owns the active field and what accessibility adds about it: everything
/// the input method's own events leave out. Holds no text of the field.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(super) struct Surface {
    /// The activation this answer belongs to.
    pub activation: u64,
    pub pid: u32,
    pub app_name: String,
    pub app_id: String,
    pub window_title: String,
    pub url: Option<String>,
    /// `None` when accessibility said nothing: the content hint decides.
    pub single_line: Option<bool>,
    pub is_integrated_terminal: bool,
    pub visible_text: Option<String>,
    pub refusal: Option<Refusal>,
}

/// The focus to report for one state of a field. The checks run in the
/// order of what they protect, and no text is read until they have passed.
pub(super) fn snapshot(
    policy: &ReadPolicy,
    surface: &Surface,
    content: Content,
    surrounding: Option<&Surrounding>,
) -> FocusSnapshot {
    if !policy.enabled {
        return FocusSnapshot::none();
    }
    let key = format!("{KEY_PREFIX}{}", surface.activation);
    let (name, id) = (surface.app_name.as_str(), surface.app_id.as_str());
    match surface.refusal {
        Some(Refusal::Blocked(reason)) => {
            return FocusSnapshot::blocked(name, id, reason, Some(key));
        }
        Some(Refusal::Unsupported(reason)) => return FocusSnapshot::unsupported(name, id, reason),
        None => {}
    }
    match content.refusal() {
        Some(Capability::Blocked(reason)) => {
            return FocusSnapshot::blocked(name, id, reason, Some(key));
        }
        Some(Capability::Unsupported(reason)) => {
            return FocusSnapshot::unsupported(name, id, reason);
        }
        _ => {}
    }
    let Some(surrounding) = surrounding else {
        return FocusSnapshot::unsupported(name, id, reasons::NO_SURROUNDING_TEXT);
    };
    if surrounding.is_masked() {
        return FocusSnapshot::blocked(name, id, reasons::SECURE, Some(key));
    }
    if surrounding.has_selection() {
        return FocusSnapshot::blocked(name, id, reasons::SELECTION, Some(key));
    }
    let Some((raw_before, raw_after)) = surrounding.split() else {
        return FocusSnapshot::unsupported(name, id, reasons::NO_CARET);
    };
    let clipped = surrounding.text.len() >= CLIPPED_AT;
    let (before, before_truncated) = policy::bounded_before(raw_before, clipped);
    let after = policy::bounded_after(raw_after, clipped);
    let field = FieldSnapshot {
        focus_key: key.clone(),
        app_name: name.to_string(),
        app_id: id.to_string(),
        pid: surface.pid,
        window_title: surface.window_title.clone(),
        before,
        before_truncated,
        after,
        // The field draws the ghost itself, so nothing needs the caret.
        caret: Rect::default(),
        caret_exact: false,
        field_frame: None,
        single_line: surface.single_line.unwrap_or(!content.multiline()),
        is_integrated_terminal: surface.is_integrated_terminal,
        url: surface.url.clone(),
        visible_text: surface.visible_text.clone(),
        style: None,
        target: InsertTarget {
            pid: surface.pid,
            input_method: true,
            ..InsertTarget::default()
        },
    };
    FocusSnapshot {
        app_name: name.to_string(),
        app_id: id.to_string(),
        capability: Capability::Supported,
        field: Some(field),
        focus_key: Some(key),
    }
}

/// The work a route's thread gets. Sending never blocks, so the app's threads
/// never wait on the desktop.
pub(super) enum Command {
    Policy(ReadPolicy),
    Refresh,
    Keys(AcceptKeys),
    Grab(bool),
    PassThrough(InterceptedKey),
    Ghost {
        field: String,
        text: String,
    },
    Accept {
        field: String,
        /// The text before the caret that goes, and after it.
        removed_before: String,
        removed_after: String,
        text: String,
        next: String,
    },
    Surface(Surface),
    Scanned(Option<String>),
    Engine(ibus::EngineEvent),
    Stop,
}

/// A handle to the running route.
#[derive(Clone)]
pub(super) struct Handle {
    commands: Sender<Command>,
    wake: Arc<UnixStream>,
    keys: Arc<Mutex<Option<KeyHandler>>>,
    limitation: Arc<Mutex<Option<String>>>,
}

impl Handle {
    fn send(&self, command: Command) {
        use std::io::Write as _;
        let _ = self.commands.send(command);
        let _ = (&*self.wake).write(&[1]);
    }

    pub(super) fn set_policy(&self, policy: ReadPolicy) {
        self.send(Command::Policy(policy));
    }

    pub(super) fn refresh_now(&self) {
        self.send(Command::Refresh);
    }

    pub(super) fn limitation(&self) -> Option<String> {
        self.limitation.lock().clone()
    }

    pub(super) fn set_keys(&self, keys: AcceptKeys) {
        self.send(Command::Keys(keys));
    }

    pub(super) fn set_active(&self, active: bool) {
        self.send(Command::Grab(active));
    }

    pub(super) fn pass_through(&self, key: InterceptedKey) {
        self.send(Command::PassThrough(key));
    }

    /// Shows `text` in `field` as the suggestion, or nothing when it's empty.
    pub(super) fn show(&self, field: &FieldSnapshot, text: &str) {
        self.send(Command::Ghost {
            field: field.focus_key.clone(),
            text: text.to_string(),
        });
    }

    /// One accept, in a single commit: makes `edit` at the caret and shows
    /// `next` as what is left. `before` and `after` are the text around the
    /// caret it applies to.
    pub(super) fn accept(
        &self,
        field: &FieldSnapshot,
        before: &str,
        after: &str,
        edit: &Edit,
        next: &str,
    ) {
        let (back, ahead) =
            super::session::replaced_bytes(before, after, edit.backward, edit.forward);
        self.send(Command::Accept {
            field: field.focus_key.clone(),
            removed_before: before[before.len() - back..].to_string(),
            removed_after: after[..ahead].to_string(),
            text: edit.text.clone(),
            next: next.to_string(),
        });
    }
}

/// The running route, for the parts of the app that attach after the watcher.
static CURRENT: LazyLock<Mutex<Option<Handle>>> = LazyLock::new(|| Mutex::new(None));

/// Follows the active field until dropped.
pub(super) struct Watcher {
    handle: Handle,
    thread: Option<std::thread::JoinHandle<()>>,
}

impl Watcher {
    pub(super) fn start(policy: ReadPolicy, handler: FocusHandler) -> anyhow::Result<Self> {
        let (wake_write, wake_read) = UnixStream::pair()?;
        wake_read.set_nonblocking(true)?;
        wake_write.set_nonblocking(true)?;
        let (commands, receiver) = crossbeam_channel::unbounded();
        let handle = Handle {
            commands,
            wake: Arc::new(wake_write),
            keys: Arc::new(Mutex::new(None)),
            limitation: Arc::new(Mutex::new(None)),
        };
        let thread = match crate::session::desktop() {
            Desktop::Gnome => ibus::start(policy, handler, handle.clone(), receiver)?,
            Desktop::Kde => kwin::start(policy, handler, handle.clone(), receiver, wake_read)?,
            _ => wlroots::start(policy, handler, handle.clone(), receiver, wake_read)?,
        };
        *CURRENT.lock() = Some(handle.clone());
        Ok(Self {
            handle,
            thread: Some(thread),
        })
    }

    pub(super) fn handle(&self) -> Handle {
        self.handle.clone()
    }
}

impl Drop for Watcher {
    fn drop(&mut self) {
        *CURRENT.lock() = None;
        self.handle.send(Command::Stop);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

/// Connects the accept keys to the running route; the watcher starts first.
pub(super) fn attach_keys(handler: KeyHandler) -> anyhow::Result<Handle> {
    let handle = CURRENT
        .lock()
        .clone()
        .ok_or_else(|| anyhow::anyhow!("autocomplete's input method is not running"))?;
    *handle.keys.lock() = Some(handler);
    Ok(handle)
}

/// Types into a field through the running route, for callers with no ghost.
pub(super) fn insert(field: &FieldSnapshot, edit: &Edit) -> anyhow::Result<()> {
    let handle = CURRENT
        .lock()
        .clone()
        .ok_or_else(|| anyhow::anyhow!("autocomplete's input method is not running"))?;
    handle.accept(field, &field.before, &field.after, edit, "");
    Ok(())
}

/// Whether this desktop has a route for autocomplete in other apps, and why
/// not when it has none. Whether another input method is in the way can change
/// at any moment, so the running route watches for that and says so itself.
pub(super) fn support() -> Support {
    let desktop = crate::session::desktop();
    match desktop {
        Desktop::Sway | Desktop::Hyprland => {
            if wlroots::offered_by_compositor() {
                Support::Available
            } else {
                Support::Unavailable(
                    lokalbot_i18n::tr(
                        "This compositor does not offer input methods to apps, so suggestions appear only in the practice editor below.",
                    )
                    .into(),
                )
            }
        }
        // Whether LokalBot is the chosen input method can change while
        // Settings is open, so the route says that itself.
        Desktop::Gnome | Desktop::Kde => Support::Available,
        _ => Support::Unavailable(lokalbot_i18n::format(
            "Autocomplete in other apps is not available on {desktop} yet, because LokalBot cannot take part as an input method there. It works on X11, GNOME, KDE Plasma, Sway and Hyprland. On this desktop suggestions appear only in the practice editor below.",
            &[("desktop", desktop.label())],
        )),
    }
}

/// What the user does to use autocomplete on this desktop, worded for the
/// Settings row. `None` outside a route.
pub(super) fn input_source_steps() -> Option<InputSourceSteps> {
    match crate::session::desktop() {
        Desktop::Sway | Desktop::Hyprland => Some(InputSourceSteps {
            text: lokalbot_i18n::tr(
                "On this desktop LokalBot reaches your text fields as an input method, the way language input tools do. There is nothing to select: turning on autocomplete makes LokalBot the input method, and turning it off gives that back. A desktop runs one input method at a time, so if Fcitx or IBus is running, LokalBot stays out of its way and tells you here.",
            )
            .into(),
            command: None,
        }),
        Desktop::Gnome => Some(ibus::steps()),
        Desktop::Kde => Some(kwin::steps()),
        _ => None,
    }
}

/// Runs the input method KDE Plasma starts for LokalBot once it is chosen
/// under Virtual Keyboard (`lokalbot --kwin-input-method`), until Plasma stops
/// it. Returns the process's exit code.
pub fn run_kwin_helper() -> i32 {
    kwin_helper::run()
}

/// The desktop entry that lists LokalBot under Plasma's Virtual Keyboard, with
/// this copy's path in it. Packages install the same file.
pub fn kwin_desktop_entry() -> String {
    kwin::desktop_entry(
        &std::env::current_exe()
            .map(|path| path.display().to_string())
            .unwrap_or_else(|_| "lokalbot".into()),
    )
}

/// The IBus component file, which makes LokalBot one of the desktop's input
/// sources, with this copy's path in it. Packages install the same file.
pub fn ibus_component() -> String {
    ibus::component_xml(
        &std::env::current_exe()
            .map(|path| path.display().to_string())
            .unwrap_or_else(|_| "lokalbot".into()),
    )
}

/// How long a ghost taken out of the field for a key waits for the field's
/// next state. If the key changed nothing, the suggestion still stands.
const GHOST_BACK_AFTER: Duration = Duration::from_millis(150);
/// How often the owner is read again while typing, for a title or page that
/// changed within the same field.
const SURFACE_REFRESH: Duration = Duration::from_secs(2);

/// Chromium and Electron report the text around the caret only in answer to an
/// input method's commit, not as the user types, so a field that has gone quiet
/// is sent an empty one now and then. Their first report after a pause comes
/// within [`ASK_WHEN_IDLE`], and within [`ASK_WHILE_TYPING`] from then on.
const ASK_WHILE_TYPING: Duration = Duration::from_millis(200);
const ASK_WHEN_IDLE: Duration = Duration::from_secs(1);
/// How long after the text last changed the user counts as typing.
const TYPING_LASTS: Duration = Duration::from_secs(5);
/// A change this long after the last asking was not an answer to it. A few of
/// those mean the field reports by itself, as GTK and Firefox do, and needs no asking.
const UNPROMPTED_AFTER: Duration = Duration::from_millis(120);
const UNPROMPTED_CHANGES: u8 = 3;

/// What a route can do to the field.
trait Output {
    /// Shows `text` as preedit, in front of the caret's way. Empty shows nothing.
    fn preedit(&mut self, text: &str);
    /// One edit and the preedit that follows it, as one step.
    fn commit(&mut self, removed_before: &str, removed_after: &str, text: &str, preedit: &str);
    /// The field is gone or nothing is on show: stop taking keys.
    fn release_keys(&mut self);
}

/// The active field and the ghost in it, the same for both routes.
struct Core {
    policy: ReadPolicy,
    handler: FocusHandler,
    questions: Sender<surface::Request>,
    limitation: Arc<Mutex<Option<String>>>,
    active: bool,
    activation: u64,
    content: Content,
    /// Dropped as soon as a field turns out not to be ours to read.
    surrounding: Option<Surrounding>,
    surface: Option<Surface>,
    asked_at: Option<Instant>,
    last: FocusSnapshot,
    /// The suggestion on show. Empty when none.
    ghost: String,
    /// The one before it, which an app's next report may still count.
    previous_ghost: String,
    /// When a key given back took the ghost out of the field for now.
    blanked_at: Option<Instant>,
    /// When the text around the caret last changed, and the field was last asked.
    changed_at: Instant,
    asked_field_at: Instant,
    unprompted_changes: u8,
}

impl Core {
    fn new(
        policy: ReadPolicy,
        handler: FocusHandler,
        questions: Sender<surface::Request>,
        limitation: Arc<Mutex<Option<String>>>,
    ) -> Self {
        Self {
            policy,
            handler,
            questions,
            limitation,
            active: false,
            activation: 0,
            content: Content::default(),
            surrounding: None,
            surface: None,
            asked_at: None,
            last: FocusSnapshot::none(),
            ghost: String::new(),
            previous_ghost: String::new(),
            blanked_at: None,
            changed_at: Instant::now(),
            asked_field_at: Instant::now(),
            unprompted_changes: 0,
        }
    }

    fn set_limitation(&self, text: Option<String>) {
        *self.limitation.lock() = text;
    }

    fn ask_for_surface(&mut self) {
        self.asked_at = Some(Instant::now());
        let _ = self.questions.send(surface::Request::Read {
            activation: self.activation,
            policy: self.policy.clone(),
        });
    }

    /// Text read from around a field is forgotten when focus leaves it.
    fn forget_surroundings(&self) {
        let _ = self.questions.send(surface::Request::Forget);
    }

    /// Whether a field's text must not even be held.
    fn refuses_text(&self) -> bool {
        !self.policy.enabled
            || self
                .surface
                .as_ref()
                .is_some_and(|surface| surface.refusal.is_some())
    }

    /// A text field has focus: whatever was known before is about another one.
    fn activate(&mut self, output: &mut impl Output) {
        log::debug!("autocomplete: a text field has focus");
        self.activation += 1;
        self.active = true;
        self.surrounding = None;
        self.content = Content::default();
        self.surface = None;
        self.drop_ghost(output);
        self.previous_ghost.clear();
        self.unprompted_changes = 0;
        self.ask_for_surface();
    }

    fn deactivate(&mut self, output: &mut impl Output) {
        log::debug!("autocomplete: no text field has focus");
        self.active = false;
        self.surrounding = None;
        self.surface = None;
        self.drop_ghost(output);
        self.previous_ghost.clear();
        self.forget_surroundings();
        self.deliver_none();
    }

    /// The field's next state.
    fn update(
        &mut self,
        content: Option<Content>,
        surrounding: Option<Surrounding>,
        output: &mut impl Output,
    ) {
        if !self.active {
            return;
        }
        if let Some(content) = content {
            if content != self.content {
                log::debug!("autocomplete: field kind {content:?}");
            }
            self.content = content;
        }
        if let Some(surrounding) = surrounding {
            let surrounding = surrounding
                .without_preedit(&self.ghost)
                .without_preedit(&self.previous_ghost);
            if self.surrounding.as_ref() != Some(&surrounding) {
                self.changed_at = Instant::now();
                if self.ghost.is_empty() && self.asked_field_at.elapsed() >= UNPROMPTED_AFTER {
                    self.unprompted_changes = self.unprompted_changes.saturating_add(1);
                }
            }
            self.surrounding = Some(surrounding);
        }
        if self.policy.enabled
            && self.surface.is_some()
            && self
                .asked_at
                .is_none_or(|at| at.elapsed() >= SURFACE_REFRESH)
        {
            self.ask_for_surface();
        }
        self.deliver(output);
    }

    fn deliver(&mut self, output: &mut impl Output) {
        let Some(surface) = self.surface.as_ref().filter(|_| self.active) else {
            return;
        };
        let focus = snapshot(
            &self.policy,
            surface,
            self.content,
            self.surrounding.as_ref(),
        );
        if focus.capability == Capability::Unsupported(reasons::NO_SURROUNDING_TEXT) {
            self.set_limitation(Some(no_surrounding_text(&surface.app_name)));
        } else if focus.capability == Capability::Unsupported(reasons::UNKNOWN_APP) {
            self.set_limitation(Some(
                lokalbot_i18n::tr(
                    "LokalBot cannot tell which app this text field belongs to, so it stays quiet there. On GNOME it needs the Window Calls extension, or the app to share its accessibility information.",
                )
                .into(),
            ));
        }
        if focus.field.is_none() {
            // Not ours to read: nothing of its text stays.
            self.surrounding = None;
            self.drop_ghost(output);
        }
        if focus != self.last {
            self.last = focus.clone();
            (self.handler)(focus);
        }
    }

    fn deliver_none(&mut self) {
        let none = FocusSnapshot::none();
        if self.last != none {
            self.last = none.clone();
            (self.handler)(none);
        }
    }

    /// Applies a command both routes treat alike. The others come back.
    fn command(&mut self, command: Command, output: &mut impl Output) -> Option<Command> {
        match command {
            Command::Policy(policy) => {
                self.policy = policy;
                self.surface = None;
                if !self.policy.enabled {
                    self.surrounding = None;
                    self.drop_ghost(output);
                    self.forget_surroundings();
                    self.deliver_none();
                } else if self.active {
                    self.ask_for_surface();
                }
            }
            Command::Refresh => self.deliver(output),
            Command::Ghost { field, text } => {
                if self.is_current(&field) {
                    self.show_ghost(text, output);
                }
            }
            Command::Accept {
                field,
                removed_before,
                removed_after,
                text,
                next,
            } => {
                if self.is_current(&field) {
                    self.replace_ghost(next);
                    self.blanked_at = None;
                    output.commit(&removed_before, &removed_after, &text, &self.ghost);
                }
            }
            Command::Surface(surface) => {
                if self.active && surface.activation == self.activation {
                    self.surface = Some(surface);
                    self.deliver(output);
                }
            }
            other => return Some(other),
        }
        None
    }

    /// The field a command names is the active one, and text may go to it.
    fn is_current(&self, field: &str) -> bool {
        self.active
            && field == format!("{KEY_PREFIX}{}", self.activation)
            && self
                .last
                .field
                .as_ref()
                .is_some_and(|last| last.focus_key == field)
    }

    fn show_ghost(&mut self, text: String, output: &mut impl Output) {
        if text == self.ghost && self.blanked_at.is_none() {
            return;
        }
        self.replace_ghost(text);
        self.blanked_at = None;
        output.preedit(&self.ghost);
    }

    fn replace_ghost(&mut self, text: String) {
        if text != self.ghost {
            self.previous_ghost = std::mem::replace(&mut self.ghost, text);
        }
    }

    fn drop_ghost(&mut self, output: &mut impl Output) {
        if !self.ghost.is_empty() {
            self.replace_ghost(String::new());
            self.blanked_at = None;
            if self.active {
                output.preedit("");
            }
        }
        output.release_keys();
    }

    /// A key is going to the field. Toolkits may commit preedit when one
    /// arrives, so the ghost leaves first and comes back if it still applies.
    fn blank_for_key(&mut self, output: &mut impl Output) {
        if !self.ghost.is_empty() && self.blanked_at.is_none() {
            self.blanked_at = Some(Instant::now());
            output.preedit("");
        }
    }

    /// When to ask a quiet field for its text next. Only a field that may be
    /// read gets asked, and only while no ghost shows: a ghost's commits ask too.
    fn next_ask(&self) -> Option<Instant> {
        let readable = self.active
            && self.last.field.is_some()
            && self.ghost.is_empty()
            && self.unprompted_changes < UNPROMPTED_CHANGES;
        readable.then(|| {
            let typing = self.changed_at.elapsed() < TYPING_LASTS;
            self.asked_field_at
                + if typing {
                    ASK_WHILE_TYPING
                } else {
                    ASK_WHEN_IDLE
                }
        })
    }

    fn next_deadline(&self) -> Option<Instant> {
        [
            self.blanked_at.map(|at| at + GHOST_BACK_AFTER),
            self.next_ask(),
        ]
        .into_iter()
        .flatten()
        .min()
    }

    fn tick(&mut self, now: Instant, output: &mut impl Output) {
        if self
            .blanked_at
            .is_some_and(|at| now.duration_since(at) >= GHOST_BACK_AFTER)
        {
            self.blanked_at = None;
            output.preedit(&self.ghost);
        }
        if self.next_ask().is_some_and(|at| now >= at) {
            self.asked_field_at = now;
            output.preedit("");
        }
    }
}

/// The session's own settings that send apps around the desktop's input
/// method, worded for Settings. Toolkits read these when they start.
fn module_override(read: impl Fn(&str) -> Option<String>) -> Option<String> {
    ["GTK_IM_MODULE", "QT_IM_MODULE"].iter().find_map(|name| {
        read(name)
            .map(|value| value.trim().to_lowercase())
            .filter(|value| !value.is_empty() && value != "wayland")
            .map(|_| {
                lokalbot_i18n::format(
                    "This session's {variable} setting sends some apps to another input method, so they will not get suggestions. Remove it from your session's environment to get suggestions in them.",
                    &[("variable", (*name).to_string())],
                )
            })
    })
}

fn other_input_method_text(name: Option<&str>) -> String {
    match name {
        Some(name) => lokalbot_i18n::format(
            "{name} is running, and a desktop runs one input method at a time. LokalBot stays out of its way, so autocomplete cannot suggest in other apps. If you do not use {name}, quit it and remove it from what your desktop starts, and autocomplete begins by itself. If {name} has stopped responding, restart it.",
            &[("name", name.to_string())],
        ),
        None => lokalbot_i18n::tr(
            "Another input method is running, and a desktop runs one at a time. LokalBot stays out of its way, so autocomplete cannot suggest in other apps. If you do not need it, quit it and remove it from what your desktop starts, and autocomplete begins by itself.",
        )
        .into(),
    }
}

fn no_surrounding_text(app: &str) -> String {
    lokalbot_i18n::format(
        "{app} does not share the text around the cursor with input methods, so autocomplete cannot suggest there.",
        &[("app", app.to_string())],
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn policy() -> ReadPolicy {
        ReadPolicy {
            enabled: true,
            ..ReadPolicy::default()
        }
    }

    fn surface() -> Surface {
        Surface {
            activation: 3,
            pid: 42,
            app_name: "Text Editor".into(),
            app_id: "org.gnome.TextEditor".into(),
            ..Surface::default()
        }
    }

    fn around(before: &str, after: &str) -> Surrounding {
        let cursor = before.len() as u32;
        Surrounding {
            text: format!("{before}{after}"),
            cursor,
            anchor: cursor,
        }
    }

    fn prose() -> Content {
        Content::default()
    }

    #[test]
    fn a_plain_field_gets_its_text_around_the_caret() {
        let text = around("Thanks, I wanted", " to");
        let focus = snapshot(&policy(), &surface(), prose(), Some(&text));
        assert_eq!(focus.capability, Capability::Supported);
        let field = focus.field.unwrap();
        assert_eq!(field.before, "Thanks, I wanted");
        assert_eq!(field.after, " to");
        assert_eq!(field.focus_key, "im:3");
        assert!(field.target.input_method);
        assert!(field.single_line, "no multiline hint");
        let multi = Content {
            hint: content::HINT_MULTILINE,
            ..prose()
        };
        let field = snapshot(&policy(), &surface(), multi, Some(&text))
            .field
            .unwrap();
        assert!(!field.single_line);
    }

    #[test]
    fn secure_fields_are_refused_on_every_signal_and_carry_no_text() {
        let secret = around("hunter", "2");
        for content in [
            Content {
                purpose: content::PURPOSE_PASSWORD,
                hint: 0,
            },
            Content {
                purpose: content::PURPOSE_PIN,
                hint: 0,
            },
            Content {
                purpose: 0,
                hint: content::HINT_HIDDEN_TEXT,
            },
            Content {
                purpose: 0,
                hint: content::HINT_SENSITIVE_DATA,
            },
        ] {
            let focus = snapshot(&policy(), &surface(), content, Some(&secret));
            assert_eq!(focus.capability, Capability::Blocked(reasons::SECURE));
            assert!(focus.field.is_none());
        }
        // No hint at all, but the toolkit gave us its mask.
        let masked = around("••••", "");
        let focus = snapshot(&policy(), &surface(), prose(), Some(&masked));
        assert_eq!(focus.capability, Capability::Blocked(reasons::SECURE));
        assert!(focus.field.is_none());
        // Accessibility said so where the hints did not.
        let refused = Surface {
            refusal: Some(Refusal::Blocked(reasons::SECURE)),
            ..surface()
        };
        let focus = snapshot(&policy(), &refused, prose(), Some(&secret));
        assert_eq!(focus.capability, Capability::Blocked(reasons::SECURE));
        assert!(focus.field.is_none());
    }

    #[test]
    fn terminals_numbers_and_addresses_get_no_suggestion() {
        let text = around("ls", "");
        let terminal = Content {
            purpose: content::PURPOSE_TERMINAL,
            hint: 0,
        };
        let focus = snapshot(&policy(), &surface(), terminal, Some(&text));
        assert_eq!(focus.capability, Capability::Unsupported(reasons::TERMINAL));
        assert!(focus.field.is_none());
        // Digits, number, phone, url, email, date, time, date and time.
        for purpose in [2, 3, 4, 5, 6, 10, 11, 12] {
            let content = Content { purpose, hint: 0 };
            let focus = snapshot(&policy(), &surface(), content, Some(&text));
            assert_eq!(
                focus.capability,
                Capability::Unsupported(reasons::NOT_PROSE),
                "purpose {purpose}"
            );
        }
    }

    #[test]
    fn an_owner_that_rules_itself_out_wins_over_a_plain_field() {
        let refused = Surface {
            refusal: Some(Refusal::Unsupported(reasons::EXCLUDED_APP)),
            ..surface()
        };
        let text = around("private", "");
        let focus = snapshot(&policy(), &refused, prose(), Some(&text));
        assert_eq!(
            focus.capability,
            Capability::Unsupported(reasons::EXCLUDED_APP)
        );
        assert!(focus.field.is_none());
    }

    #[test]
    fn off_means_nothing_is_reported() {
        let off = ReadPolicy::default();
        let text = around("anything", "");
        assert_eq!(
            snapshot(&off, &surface(), prose(), Some(&text)),
            FocusSnapshot::none()
        );
    }

    #[test]
    fn a_selection_or_missing_text_withholds_the_field() {
        let mut text = around("some text", "");
        text.anchor = 0;
        let focus = snapshot(&policy(), &surface(), prose(), Some(&text));
        assert_eq!(focus.capability, Capability::Blocked(reasons::SELECTION));
        assert!(focus.field.is_none());
        let focus = snapshot(&policy(), &surface(), prose(), None);
        assert_eq!(
            focus.capability,
            Capability::Unsupported(reasons::NO_SURROUNDING_TEXT)
        );
    }

    #[test]
    fn offsets_inside_a_character_are_refused_not_panicked_on() {
        let text = Surrounding {
            text: "é".into(),
            cursor: 1,
            anchor: 1,
        };
        let focus = snapshot(&policy(), &surface(), prose(), Some(&text));
        assert_eq!(focus.capability, Capability::Unsupported(reasons::NO_CARET));
        let past_end = Surrounding {
            text: "ab".into(),
            cursor: 9,
            anchor: 9,
        };
        let focus = snapshot(&policy(), &surface(), prose(), Some(&past_end));
        assert_eq!(focus.capability, Capability::Unsupported(reasons::NO_CARET));
    }

    #[test]
    fn a_full_window_counts_as_clipped() {
        let long = "x".repeat(SURROUNDING_LIMIT);
        let text = around(&long, "");
        let field = snapshot(&policy(), &surface(), prose(), Some(&text))
            .field
            .unwrap();
        assert!(field.before_truncated);
        let short = around("short", "");
        let field = snapshot(&policy(), &surface(), prose(), Some(&short))
            .field
            .unwrap();
        assert!(!field.before_truncated);
    }

    /// Records what a route would do to the field.
    #[derive(Default)]
    struct Recorder {
        calls: Vec<String>,
    }

    impl Output for Recorder {
        fn preedit(&mut self, text: &str) {
            self.calls.push(format!("preedit {text}"));
        }

        fn commit(&mut self, before: &str, after: &str, text: &str, preedit: &str) {
            self.calls
                .push(format!("commit -{before} -{after} +{text} then {preedit}"));
        }

        fn release_keys(&mut self) {
            self.calls.push("release".into());
        }
    }

    fn core() -> (Core, Arc<Mutex<Vec<FocusSnapshot>>>, Recorder) {
        let seen = Arc::new(Mutex::new(Vec::new()));
        let sink = seen.clone();
        let (questions, _unanswered) = crossbeam_channel::unbounded();
        let core = Core::new(
            policy(),
            Arc::new(move |focus| sink.lock().push(focus)),
            questions,
            Arc::new(Mutex::new(None)),
        );
        (core, seen, Recorder::default())
    }

    fn answered(core: &mut Core, output: &mut Recorder) {
        let surface = Surface {
            activation: core.activation,
            ..surface()
        };
        assert!(core.command(Command::Surface(surface), output).is_none());
    }

    #[test]
    fn nothing_is_delivered_until_the_owner_is_known() {
        let (mut core, seen, mut output) = core();
        core.activate(&mut output);
        core.update(None, Some(around("draft", "")), &mut output);
        assert!(seen.lock().is_empty());
        answered(&mut core, &mut output);
        let focus = seen.lock().last().cloned().unwrap();
        assert_eq!(focus.field.unwrap().before, "draft");
    }

    #[test]
    fn a_refused_owner_or_a_secure_field_leaves_no_text_behind() {
        let (mut core, seen, mut output) = core();
        core.activate(&mut output);
        core.update(None, Some(around("draft", "")), &mut output);
        let refused = Surface {
            activation: core.activation,
            refusal: Some(Refusal::Unsupported(reasons::EXCLUDED_APP)),
            ..surface()
        };
        core.command(Command::Surface(refused), &mut output);
        assert_eq!(core.surrounding, None);
        assert!(core.refuses_text());
        assert!(seen.lock().last().unwrap().field.is_none());

        let (mut core, seen, mut output) = self::core();
        core.activate(&mut output);
        answered(&mut core, &mut output);
        let secure = Content {
            purpose: content::PURPOSE_PASSWORD,
            hint: 0,
        };
        core.update(Some(secure), Some(around("hunter2", "")), &mut output);
        assert_eq!(core.surrounding, None);
        let focus = seen.lock().last().cloned().unwrap();
        assert_eq!(focus.capability, Capability::Blocked(reasons::SECURE));
    }

    #[test]
    fn a_ghost_goes_only_to_the_field_it_was_made_for() {
        let (mut core, seen, mut output) = core();
        core.activate(&mut output);
        core.update(None, Some(around("draft", "")), &mut output);
        answered(&mut core, &mut output);
        let key = seen.lock().last().unwrap().focus_key.clone().unwrap();
        // Focus moves on before the ghost arrives.
        core.activate(&mut output);
        core.update(None, Some(around("other", "")), &mut output);
        answered(&mut core, &mut output);
        output.calls.clear();
        let ghost = Command::Ghost {
            field: key.clone(),
            text: " up".into(),
        };
        assert!(core.command(ghost, &mut output).is_none());
        let accept = Command::Accept {
            field: key,
            removed_before: String::new(),
            removed_after: String::new(),
            text: " up".into(),
            next: String::new(),
        };
        assert!(core.command(accept, &mut output).is_none());
        assert_eq!(output.calls, Vec::<String>::new());
    }

    #[test]
    fn an_accept_commits_with_what_is_left_and_a_key_blanks_the_ghost_for_a_moment() {
        let (mut core, seen, mut output) = core();
        core.activate(&mut output);
        core.update(None, Some(around("hello", "")), &mut output);
        answered(&mut core, &mut output);
        let key = seen.lock().last().unwrap().focus_key.clone().unwrap();
        output.calls.clear();
        core.command(
            Command::Ghost {
                field: key.clone(),
                text: " up on it".into(),
            },
            &mut output,
        );
        core.command(
            Command::Accept {
                field: key.clone(),
                removed_before: String::new(),
                removed_after: String::new(),
                text: " up".into(),
                next: " on it".into(),
            },
            &mut output,
        );
        // Showing what is already on show does nothing.
        core.command(
            Command::Ghost {
                field: key,
                text: " on it".into(),
            },
            &mut output,
        );
        assert_eq!(
            output.calls,
            ["preedit  up on it", "commit - - + up then  on it"]
        );
        output.calls.clear();
        let now = Instant::now();
        core.blank_for_key(&mut output);
        core.blank_for_key(&mut output);
        assert_eq!(output.calls, ["preedit "]);
        core.tick(now, &mut output);
        assert_eq!(output.calls.len(), 1, "too soon");
        core.tick(now + GHOST_BACK_AFTER * 2, &mut output);
        assert_eq!(output.calls, ["preedit ", "preedit  on it"]);
    }

    #[test]
    fn a_quiet_field_is_asked_for_its_text_only_while_it_may_be_read() {
        let (mut core, seen, mut output) = core();
        core.activate(&mut output);
        core.update(None, Some(around("hello", "")), &mut output);
        assert_eq!(core.next_ask(), None, "the owner is not known yet");
        answered(&mut core, &mut output);
        let key = seen.lock().last().unwrap().focus_key.clone().unwrap();
        output.calls.clear();
        let later = Instant::now() + ASK_WHEN_IDLE * 2;
        core.tick(later, &mut output);
        assert_eq!(output.calls, ["preedit "]);
        // A ghost's own commits ask too.
        core.command(
            Command::Ghost {
                field: key,
                text: " up".into(),
            },
            &mut output,
        );
        assert_eq!(core.next_ask(), None);
        // A secure field is never asked.
        let secure = Content {
            purpose: content::PURPOSE_PASSWORD,
            hint: 0,
        };
        core.update(Some(secure), None, &mut output);
        assert_eq!(core.next_ask(), None);
        // Nor is anything once focus has gone.
        core.deactivate(&mut output);
        assert_eq!(core.next_ask(), None);
    }

    #[test]
    fn a_field_that_reports_by_itself_stops_being_asked() {
        let (mut core, _seen, mut output) = core();
        core.activate(&mut output);
        core.update(None, Some(around("", "")), &mut output);
        answered(&mut core, &mut output);
        assert!(core.next_ask().is_some());
        // Answers to asking don't count.
        core.asked_field_at = Instant::now();
        core.update(None, Some(around("a", "")), &mut output);
        assert!(core.next_ask().is_some());
        // Changes long after asking do.
        for text in ["ab", "abc", "abcd"] {
            core.asked_field_at = Instant::now() - UNPROMPTED_AFTER * 2;
            core.update(None, Some(around(text, "")), &mut output);
        }
        assert_eq!(core.next_ask(), None);
        // The next field starts over.
        core.activate(&mut output);
        core.update(None, Some(around("", "")), &mut output);
        answered(&mut core, &mut output);
        assert!(core.next_ask().is_some());
    }

    #[test]
    fn turning_off_or_losing_focus_clears_the_ghost_and_the_keys() {
        let (mut core, seen, mut output) = core();
        core.activate(&mut output);
        core.update(None, Some(around("hello", "")), &mut output);
        answered(&mut core, &mut output);
        let key = seen.lock().last().unwrap().focus_key.clone().unwrap();
        core.command(
            Command::Ghost {
                field: key,
                text: " up".into(),
            },
            &mut output,
        );
        output.calls.clear();
        core.command(Command::Policy(ReadPolicy::default()), &mut output);
        assert_eq!(output.calls, ["preedit ", "release"]);
        assert_eq!(core.surrounding, None);
        assert_eq!(seen.lock().last().cloned().unwrap(), FocusSnapshot::none());
    }

    #[test]
    fn a_ghost_counted_in_the_text_is_taken_out_and_real_text_is_not() {
        let ghost = " on the plan";
        // Firefox: the ghost after the caret, then with the caret inside it.
        let counted = around("hello up", ghost).without_preedit(ghost);
        assert_eq!(counted, around("hello up", ""));
        let inside = around("hello up ", "on the plan").without_preedit(ghost);
        assert_eq!(inside, around("hello up", ""));
        // The user's own text before the caret stays, however alike.
        let typed = around("hello up on the plan", "");
        assert_eq!(typed.clone().without_preedit(ghost), typed);
        // No ghost, or a text without it: nothing changes.
        let plain = around("hello", " there");
        assert_eq!(plain.clone().without_preedit(""), plain);
        assert_eq!(plain.clone().without_preedit(ghost), plain);
    }

    #[test]
    fn a_session_module_setting_is_called_out_only_when_it_routes_around_us() {
        let unset = |_: &str| None;
        assert_eq!(module_override(unset), None);
        let wayland = |name: &str| (name == "GTK_IM_MODULE").then(|| "wayland".to_string());
        assert_eq!(module_override(wayland), None);
        let fcitx = |name: &str| (name == "QT_IM_MODULE").then(|| "fcitx".to_string());
        assert!(module_override(fcitx).unwrap().contains("QT_IM_MODULE"));
    }
}
