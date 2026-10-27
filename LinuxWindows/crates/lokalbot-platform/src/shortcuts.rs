//! System-wide shortcuts for dictation and Ask.
//!
//! [`Shortcut`] parses the strings stored in settings ("Ctrl+Shift+Space",
//! "Alt+Space") and validates them with the macOS rules
//! (`DictationShortcut.problem`, `QuickRecallHotKeyController.problem`).
//! [`GlobalShortcuts`] registers them: `global-hotkey` on Windows and X11
//! (press and release, for push to talk), and the XDG `GlobalShortcuts`
//! portal on Wayland. Desktops without the portal (Sway, GNOME before 48)
//! get a clear error; users there bind a desktop shortcut to the
//! `lokalbot dictate --toggle` / `lokalbot quick-recall` commands, which reach
//! the app through [`crate::instance`].
//!
//! Threading: create and use [`GlobalShortcuts`] from any one thread (the GPUI
//! main thread is fine); it runs its own worker thread. The handler is called
//! on a background thread (Windows: the worker for presses and a short-lived
//! thread for releases; X11: `global-hotkey`'s X11 thread; Wayland: the portal
//! thread), so it must not block: forward the event to the app.

use std::fmt;
use std::str::FromStr;
use std::sync::Arc;

use parking_lot::Mutex;

/// The physical key of a shortcut, independent of modifiers.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Key {
    /// `A`–`Z`, `0`–`9`, or one of `` -=[]\;',./` ``.
    Char(char),
    Space,
    Enter,
    Tab,
    Backspace,
    Delete,
    Insert,
    Escape,
    Up,
    Down,
    Left,
    Right,
    Home,
    End,
    PageUp,
    PageDown,
    /// F1–F24.
    Function(u8),
}

const PUNCTUATION: &str = "-=[]\\;',./`";

impl Key {
    fn parse(token: &str) -> Option<Key> {
        let lower = token.to_lowercase();
        let key = match lower.as_str() {
            "space" | "spacebar" => Key::Space,
            "enter" | "return" => Key::Enter,
            "tab" => Key::Tab,
            "backspace" => Key::Backspace,
            "delete" | "del" | "forward delete" => Key::Delete,
            "insert" | "ins" => Key::Insert,
            "esc" | "escape" => Key::Escape,
            "up" | "arrowup" | "↑" => Key::Up,
            "down" | "arrowdown" | "↓" => Key::Down,
            "left" | "arrowleft" | "←" => Key::Left,
            "right" | "arrowright" | "→" => Key::Right,
            "home" => Key::Home,
            "end" => Key::End,
            "pageup" | "pgup" => Key::PageUp,
            "pagedown" | "pgdn" => Key::PageDown,
            "minus" => Key::Char('-'),
            "equal" | "equals" => Key::Char('='),
            "bracketleft" | "leftbracket" => Key::Char('['),
            "bracketright" | "rightbracket" => Key::Char(']'),
            "backslash" => Key::Char('\\'),
            "semicolon" => Key::Char(';'),
            "quote" | "apostrophe" => Key::Char('\''),
            "comma" => Key::Char(','),
            "period" | "dot" => Key::Char('.'),
            "slash" => Key::Char('/'),
            "backquote" | "grave" | "backtick" => Key::Char('`'),
            _ => {
                if let Some(number) = lower.strip_prefix('f')
                    && let Ok(number) = number.parse::<u8>()
                    && (1..=24).contains(&number)
                {
                    return Some(Key::Function(number));
                }
                let mut chars = token.chars();
                let (Some(c), None) = (chars.next(), chars.next()) else {
                    return None;
                };
                if c.is_ascii_alphanumeric() {
                    Key::Char(c.to_ascii_uppercase())
                } else if PUNCTUATION.contains(c) {
                    Key::Char(c)
                } else {
                    return None;
                }
            }
        };
        Some(key)
    }

    fn label(self) -> String {
        match self {
            Key::Char(c) => c.to_string(),
            Key::Space => "Space".into(),
            Key::Enter => "Enter".into(),
            Key::Tab => "Tab".into(),
            Key::Backspace => "Backspace".into(),
            Key::Delete => "Delete".into(),
            Key::Insert => "Insert".into(),
            Key::Escape => "Esc".into(),
            Key::Up => "Up".into(),
            Key::Down => "Down".into(),
            Key::Left => "Left".into(),
            Key::Right => "Right".into(),
            Key::Home => "Home".into(),
            Key::End => "End".into(),
            Key::PageUp => "PageUp".into(),
            Key::PageDown => "PageDown".into(),
            Key::Function(n) => format!("F{n}"),
        }
    }

    /// Keys that do not type a character (`DictationShortcutKeyNames.isNamedKey`).
    pub fn is_named(self) -> bool {
        !matches!(self, Key::Char(_))
    }

    /// The xkb keysym name the shortcuts portal expects.
    fn keysym_name(self) -> String {
        match self {
            Key::Char(c) if c.is_ascii_alphanumeric() => c.to_ascii_lowercase().to_string(),
            Key::Char(c) => match c {
                '-' => "minus",
                '=' => "equal",
                '[' => "bracketleft",
                ']' => "bracketright",
                '\\' => "backslash",
                ';' => "semicolon",
                '\'' => "apostrophe",
                ',' => "comma",
                '.' => "period",
                '/' => "slash",
                _ => "grave",
            }
            .into(),
            Key::Space => "space".into(),
            Key::Enter => "Return".into(),
            Key::Tab => "Tab".into(),
            Key::Backspace => "BackSpace".into(),
            Key::Delete => "Delete".into(),
            Key::Insert => "Insert".into(),
            Key::Escape => "Escape".into(),
            Key::Up => "Up".into(),
            Key::Down => "Down".into(),
            Key::Left => "Left".into(),
            Key::Right => "Right".into(),
            Key::Home => "Home".into(),
            Key::End => "End".into(),
            Key::PageUp => "Page_Up".into(),
            Key::PageDown => "Page_Down".into(),
            Key::Function(n) => format!("F{n}"),
        }
    }
}

/// What Windows and Linux desktops call the logo key.
#[cfg(windows)]
pub const SUPER_LABEL: &str = "Win";
#[cfg(not(windows))]
pub const SUPER_LABEL: &str = "Super";

/// A key with modifiers, or modifiers alone (`DictationShortcut`).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub struct Shortcut {
    pub ctrl: bool,
    pub alt: bool,
    pub shift: bool,
    /// The Windows / Super / Meta key.
    pub logo: bool,
    /// `None` for a modifier-only chord such as Ctrl+Alt.
    pub key: Option<Key>,
}

#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum ShortcutParseError {
    #[error("Choose a shortcut.")]
    Empty,
    #[error("“{0}” is not a key LokalBot knows.")]
    UnknownKey(String),
    #[error("Use one key with the modifiers, like Ctrl+Shift+Space.")]
    SeveralKeys,
}

impl Shortcut {
    /// Ctrl+Shift+Space opens Ask (`quickRecallShortcut`).
    pub const QUICK_RECALL_DEFAULT: Shortcut = Shortcut {
        ctrl: true,
        alt: false,
        shift: true,
        logo: false,
        key: Some(Key::Space),
    };
    /// Alt+Space starts dictation (`dictationShortcut`).
    pub const DICTATION_DEFAULT: Shortcut = Shortcut {
        ctrl: false,
        alt: true,
        shift: false,
        logo: false,
        key: Some(Key::Space),
    };

    /// Parses "Ctrl+Shift+Space", "alt+space", "Super+D", "F5", "Ctrl+Alt",
    /// and the macOS symbols ("⌃⇧ Space").
    pub fn parse(text: &str) -> Result<Shortcut, ShortcutParseError> {
        let mut shortcut = Shortcut::default();
        let mut any = false;
        for token in text
            .split(|c: char| c == '+' || c.is_whitespace())
            .filter(|t| !t.is_empty())
        {
            any = true;
            if shortcut.apply_modifier(token) {
                continue;
            }
            if token.chars().all(|c| "⌃⌥⇧⌘".contains(c)) {
                for symbol in token.chars() {
                    shortcut.apply_modifier(&symbol.to_string());
                }
                continue;
            }
            let key = Key::parse(token)
                .ok_or_else(|| ShortcutParseError::UnknownKey(token.to_string()))?;
            if shortcut.key.replace(key).is_some() {
                return Err(ShortcutParseError::SeveralKeys);
            }
        }
        if !any {
            return Err(ShortcutParseError::Empty);
        }
        Ok(shortcut)
    }

    fn apply_modifier(&mut self, token: &str) -> bool {
        match token.to_lowercase().as_str() {
            "ctrl" | "control" | "ctl" | "⌃" => self.ctrl = true,
            "alt" | "option" | "opt" | "altgr" | "⌥" => self.alt = true,
            "shift" | "⇧" => self.shift = true,
            "super" | "win" | "windows" | "meta" | "logo" | "cmd" | "command" | "⌘" => {
                self.logo = true
            }
            _ => return false,
        }
        true
    }

    pub fn is_modifier_only(&self) -> bool {
        self.key.is_none()
    }

    pub fn modifier_count(&self) -> usize {
        [self.ctrl, self.alt, self.shift, self.logo]
            .iter()
            .filter(|on| **on)
            .count()
    }

    /// "Ctrl+Shift+Space", "F5", "Ctrl+Alt".
    pub fn label(&self) -> String {
        let mut parts: Vec<String> = Vec::new();
        if self.ctrl {
            parts.push("Ctrl".into());
        }
        if self.alt {
            parts.push("Alt".into());
        }
        if self.shift {
            parts.push("Shift".into());
        }
        if self.logo {
            parts.push(SUPER_LABEL.into());
        }
        if let Some(key) = self.key {
            parts.push(key.label());
        }
        parts.join("+")
    }

    /// Why this cannot be the dictation shortcut, or `None`
    /// (`DictationShortcut.problem`). `ask` is the Ask shortcut, if enabled.
    pub fn dictation_problem(&self, ask: Option<&Shortcut>) -> Option<ShortcutProblem> {
        if let Some(problem) = self.typing_problem() {
            return Some(problem);
        }
        if ask.is_some_and(|ask| ask == self) {
            return Some(ShortcutProblem::UsedByAsk);
        }
        self.system_problem()
    }

    /// Why this cannot open Ask, or `None`
    /// (`QuickRecallHotKeyController.problem`). Ask always needs a key.
    pub fn quick_recall_problem(&self, dictation: Option<&Shortcut>) -> Option<ShortcutProblem> {
        if self.is_modifier_only() {
            return Some(ShortcutProblem::NeedsKey);
        }
        if let Some(problem) = self.typing_problem() {
            return Some(problem);
        }
        if dictation.is_some_and(|dictation| dictation == self) {
            return Some(ShortcutProblem::UsedByDictation);
        }
        self.system_problem()
    }

    fn typing_problem(&self) -> Option<ShortcutProblem> {
        let Some(key) = self.key else {
            // One modifier alone fires whenever it is used for anything else.
            return Some(if self.modifier_count() >= 2 {
                ShortcutProblem::ModifierOnlyUnsupported
            } else {
                ShortcutProblem::NeedsTwoModifiers
            });
        };
        if key == Key::Escape {
            return Some(ShortcutProblem::ReservedForCancel);
        }
        if matches!(key, Key::Function(_)) {
            return None;
        }
        if !(self.ctrl || self.alt || self.logo) {
            return Some(ShortcutProblem::NeedsModifier);
        }
        // Ctrl plus a character is how apps here spell Copy, Save, Undo….
        if self.ctrl && !self.alt && !self.shift && !self.logo && !key.is_named() {
            return Some(ShortcutProblem::CtrlOnly);
        }
        None
    }

    fn system_problem(&self) -> Option<ShortcutProblem> {
        RESERVED
            .iter()
            .filter_map(|text| Shortcut::parse(text).ok())
            .any(|reserved| reserved == *self)
            .then_some(ShortcutProblem::UsedBySystem)
    }

    /// The XDG shortcuts trigger ("CTRL+SHIFT+space") for the portal.
    pub fn portal_trigger(&self) -> Option<String> {
        let key = self.key?;
        let mut parts: Vec<String> = Vec::new();
        if self.ctrl {
            parts.push("CTRL".into());
        }
        if self.alt {
            parts.push("ALT".into());
        }
        if self.shift {
            parts.push("SHIFT".into());
        }
        if self.logo {
            parts.push("LOGO".into());
        }
        parts.push(key.keysym_name());
        Some(parts.join("+"))
    }
}

/// Combinations the system takes before any app sees them.
#[cfg(windows)]
const RESERVED: &[&str] = &[
    "Ctrl+Alt+Delete",
    "Ctrl+Shift+Esc",
    "Ctrl+Esc",
    "Alt+Tab",
    "Alt+Esc",
    "Alt+F4",
    "Win+L",
    "Win+D",
    "Win+E",
    "Win+R",
    "Win+I",
    "Win+A",
    "Win+S",
    "Win+X",
    "Win+V",
    "Win+H",
    "Win+G",
    "Win+K",
    "Win+P",
    "Win+U",
    "Win+M",
    "Win+Tab",
    "Win+Space",
    "Win+Period",
    "Win+Comma",
    "Win+Shift+S",
    "Win+Up",
    "Win+Down",
    "Win+Left",
    "Win+Right",
    "Win+1",
    "Win+2",
    "Win+3",
    "Win+4",
    "Win+5",
    "Win+6",
    "Win+7",
    "Win+8",
    "Win+9",
    "Win+0",
];
#[cfg(not(windows))]
const RESERVED: &[&str] = &[
    "Ctrl+Alt+Delete",
    "Alt+Tab",
    "Alt+Shift+Tab",
    "Alt+F2",
    "Alt+F4",
    "Super+L",
    "Super+Tab",
    "Super+Space",
];

/// Why a combination cannot be used (`DictationShortcut.Problem`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ShortcutProblem {
    ReservedForCancel,
    NeedsModifier,
    CtrlOnly,
    NeedsTwoModifiers,
    /// Modifier chords (Ctrl+Alt alone) need a keyboard hook that Linux and
    /// Windows builds do not install.
    ModifierOnlyUnsupported,
    NeedsKey,
    UsedByDictation,
    UsedByAsk,
    UsedBySystem,
    Unavailable,
}

impl ShortcutProblem {
    pub fn message(self) -> String {
        match self {
            Self::ReservedForCancel => "Esc cancels recording a shortcut. Choose another key.".into(),
            Self::NeedsModifier => format!(
                "Add Ctrl, Alt or {SUPER_LABEL} so the shortcut does not block typing, or use a function key."
            ),
            Self::CtrlOnly => {
                format!("Apps use Ctrl with a single key. Add Alt, Shift or {SUPER_LABEL}.")
            }
            Self::NeedsTwoModifiers => {
                "Hold at least two modifier keys, like Ctrl+Alt, or add a key.".into()
            }
            Self::ModifierOnlyUnsupported => {
                "Add a key, like Alt+Space. Shortcuts made only of modifier keys are not available on this computer yet."
                    .into()
            }
            Self::NeedsKey => "Hold the modifiers and press a key, like Ctrl+Shift+Space.".into(),
            Self::UsedByDictation => "Dictation already uses this shortcut. Choose another.".into(),
            Self::UsedByAsk => "Ask already uses this shortcut. Choose another.".into(),
            Self::UsedBySystem => {
                if cfg!(windows) {
                    "Windows already uses this shortcut. Choose another.".into()
                } else {
                    "Your desktop already uses this shortcut. Choose another.".into()
                }
            }
            Self::Unavailable => {
                "This shortcut could not be registered. Another app may already use it.".into()
            }
        }
    }
}

impl fmt::Display for ShortcutProblem {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.message())
    }
}

/// Shown when Ask's shortcut fails to register (`QuickRecallHotKeyController`).
pub fn ask_registration_failed_message(shortcut: &Shortcut) -> String {
    format!(
        "The Ask shortcut could not register {}. Another app may already use it.",
        shortcut.label()
    )
}

impl fmt::Display for Shortcut {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.label())
    }
}

impl FromStr for Shortcut {
    type Err = ShortcutParseError;

    fn from_str(text: &str) -> Result<Self, Self::Err> {
        Shortcut::parse(text)
    }
}

/// A registered shortcut went down (`pressed`) or up.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ShortcutEvent {
    pub id: String,
    pub pressed: bool,
}

#[derive(Debug, thiserror::Error)]
pub enum ShortcutError {
    #[error("{0}")]
    Invalid(ShortcutProblem),
    /// Another app or the desktop holds the combination.
    #[error("{}", ShortcutProblem::Unavailable.message())]
    InUse,
    /// This desktop cannot register global shortcuts for apps.
    #[error("{0}")]
    Unsupported(String),
    #[error("The shortcut could not be registered: {0}")]
    Failed(String),
}

/// Suggested when a desktop has no way to register shortcuts for apps.
pub const BIND_COMMAND_HINT: &str = "Add a shortcut in your desktop's keyboard settings that runs “lokalbot dictate --toggle” for dictation or “lokalbot quick-recall” for Ask.";

type Handler = Arc<dyn Fn(ShortcutEvent) + Send + Sync>;

fn shared_handler(handler: impl Fn(ShortcutEvent) + Send + 'static) -> Handler {
    let handler = Mutex::new(handler);
    Arc::new(move |event| (handler.lock())(event))
}

/// Registers global shortcuts until dropped. Create one per process.
pub struct GlobalShortcuts {
    backend: Backend,
}

enum Backend {
    #[cfg(any(windows, target_os = "linux"))]
    HotKey(hotkey::Worker),
    #[cfg(target_os = "linux")]
    Portal(portal::Worker),
    #[cfg(not(any(windows, target_os = "linux")))]
    None,
}

impl GlobalShortcuts {
    pub fn new(handler: impl Fn(ShortcutEvent) + Send + 'static) -> Result<Self, ShortcutError> {
        let handler = shared_handler(handler);
        #[cfg(target_os = "linux")]
        {
            if crate::session::is_wayland() {
                return portal::Worker::start(handler).map(|worker| Self {
                    backend: Backend::Portal(worker),
                });
            }
            if !crate::session::has_x11_display() {
                return Err(ShortcutError::Unsupported(format!(
                    "No desktop session was found for global shortcuts. {BIND_COMMAND_HINT}"
                )));
            }
        }
        #[cfg(any(windows, target_os = "linux"))]
        {
            hotkey::Worker::start(handler).map(|worker| Self {
                backend: Backend::HotKey(worker),
            })
        }
        #[cfg(not(any(windows, target_os = "linux")))]
        {
            let _ = handler;
            Err(ShortcutError::Unsupported(BIND_COMMAND_HINT.into()))
        }
    }

    /// Which mechanism delivers the shortcuts: `win32`, `x11` or `portal`.
    pub fn backend_name(&self) -> &'static str {
        match &self.backend {
            #[cfg(windows)]
            Backend::HotKey(_) => "win32",
            #[cfg(target_os = "linux")]
            Backend::HotKey(_) => "x11",
            #[cfg(target_os = "linux")]
            Backend::Portal(_) => "portal",
            #[cfg(not(any(windows, target_os = "linux")))]
            Backend::None => "none",
        }
    }

    /// Registers `shortcut` under `id`, replacing what `id` had. On Wayland
    /// the desktop may ask the user to confirm the shortcut; the call returns
    /// once the request is sent (or after a few seconds) and the binding then
    /// completes in the background.
    pub fn register(&mut self, id: &str, shortcut: &Shortcut) -> Result<(), ShortcutError> {
        if shortcut.is_modifier_only() {
            return Err(ShortcutError::Invalid(
                shortcut
                    .dictation_problem(None)
                    .unwrap_or(ShortcutProblem::NeedsKey),
            ));
        }
        match &mut self.backend {
            #[cfg(any(windows, target_os = "linux"))]
            Backend::HotKey(worker) => worker.register(id, shortcut),
            #[cfg(target_os = "linux")]
            Backend::Portal(worker) => worker.register(id, shortcut),
            #[cfg(not(any(windows, target_os = "linux")))]
            Backend::None => Err(ShortcutError::Unsupported(BIND_COMMAND_HINT.into())),
        }
    }

    pub fn unregister(&mut self, id: &str) -> Result<(), ShortcutError> {
        match &mut self.backend {
            #[cfg(any(windows, target_os = "linux"))]
            Backend::HotKey(worker) => worker.unregister(id),
            #[cfg(target_os = "linux")]
            Backend::Portal(worker) => worker.unregister(id),
            #[cfg(not(any(windows, target_os = "linux")))]
            Backend::None => Ok(()),
        }
    }
}

#[cfg(any(windows, target_os = "linux"))]
mod hotkey {
    //! `global-hotkey` behind a worker thread. On Windows its hidden window
    //! needs a message loop on the thread that created it, so the worker runs
    //! one; GPUI's main-thread loop is never involved.

    use std::collections::HashMap;
    use std::sync::{LazyLock, Once};
    use std::thread::JoinHandle;

    use crossbeam_channel::{Receiver, Sender, bounded, unbounded};
    use global_hotkey::hotkey::{Code, HotKey, Modifiers};
    use global_hotkey::{GlobalHotKeyEvent, GlobalHotKeyManager, HotKeyState};
    use parking_lot::Mutex;

    use super::{Handler, Key, Shortcut, ShortcutError, ShortcutEvent};

    /// `global-hotkey` allows one event handler per process; it forwards
    /// here, to whichever [`Worker`] is current.
    struct Dispatch {
        handler: Option<Handler>,
        ids: HashMap<u32, String>,
    }

    static DISPATCH: LazyLock<Mutex<Dispatch>> = LazyLock::new(|| {
        Mutex::new(Dispatch {
            handler: None,
            ids: HashMap::new(),
        })
    });

    fn install_dispatch() {
        static ONCE: Once = Once::new();
        ONCE.call_once(|| {
            GlobalHotKeyEvent::set_event_handler(Some(|event: GlobalHotKeyEvent| {
                let target = {
                    let dispatch = DISPATCH.lock();
                    dispatch
                        .handler
                        .clone()
                        .zip(dispatch.ids.get(&event.id).cloned())
                };
                if let Some((handler, id)) = target {
                    handler(ShortcutEvent {
                        id,
                        pressed: event.state == HotKeyState::Pressed,
                    });
                }
            }));
        });
    }

    enum Command {
        Register(HotKey, Sender<Result<(), ShortcutError>>),
        Unregister(HotKey, Sender<Result<(), ShortcutError>>),
        Stop,
    }

    pub(super) struct Worker {
        commands: Sender<Command>,
        registered: HashMap<String, HotKey>,
        thread: Option<JoinHandle<()>>,
        #[cfg(windows)]
        thread_id: u32,
    }

    impl Worker {
        pub(super) fn start(handler: Handler) -> Result<Self, ShortcutError> {
            install_dispatch();
            {
                let mut dispatch = DISPATCH.lock();
                dispatch.handler = Some(handler);
                dispatch.ids.clear();
            }
            let (commands, receiver) = unbounded();
            let (ready_tx, ready_rx) = bounded(1);
            let thread = std::thread::Builder::new()
                .name("lokalbot-shortcuts".into())
                .spawn(move || run(receiver, ready_tx))
                .map_err(|err| ShortcutError::Failed(err.to_string()))?;
            let ready = ready_rx
                .recv()
                .map_err(|_| ShortcutError::Failed("the shortcut thread stopped".into()))?;
            let _thread_id = ready.map_err(ShortcutError::Failed)?;
            Ok(Self {
                commands,
                registered: HashMap::new(),
                thread: Some(thread),
                #[cfg(windows)]
                thread_id: _thread_id,
            })
        }

        fn request(
            &self,
            make: impl FnOnce(Sender<Result<(), ShortcutError>>) -> Command,
        ) -> Result<(), ShortcutError> {
            let (tx, rx) = bounded(1);
            self.commands
                .send(make(tx))
                .map_err(|_| ShortcutError::Failed("the shortcut thread stopped".into()))?;
            self.wake();
            rx.recv()
                .map_err(|_| ShortcutError::Failed("the shortcut thread stopped".into()))?
        }

        #[cfg(windows)]
        fn wake(&self) {
            crate::win32_loop::wake(self.thread_id);
        }

        #[cfg(not(windows))]
        fn wake(&self) {}

        pub(super) fn register(
            &mut self,
            id: &str,
            shortcut: &Shortcut,
        ) -> Result<(), ShortcutError> {
            let hotkey = to_hotkey(shortcut)?;
            if self.registered.get(id) == Some(&hotkey) {
                return Ok(());
            }
            if DISPATCH
                .lock()
                .ids
                .get(&hotkey.id())
                .is_some_and(|owner| owner != id)
            {
                return Err(ShortcutError::InUse);
            }
            self.unregister(id)?;
            self.request(|tx| Command::Register(hotkey, tx))?;
            DISPATCH.lock().ids.insert(hotkey.id(), id.to_string());
            self.registered.insert(id.to_string(), hotkey);
            Ok(())
        }

        pub(super) fn unregister(&mut self, id: &str) -> Result<(), ShortcutError> {
            let Some(hotkey) = self.registered.remove(id) else {
                return Ok(());
            };
            DISPATCH.lock().ids.remove(&hotkey.id());
            self.request(|tx| Command::Unregister(hotkey, tx))
        }
    }

    impl Drop for Worker {
        fn drop(&mut self) {
            let _ = self.commands.send(Command::Stop);
            self.wake();
            if let Some(thread) = self.thread.take() {
                let _ = thread.join();
            }
            let mut dispatch = DISPATCH.lock();
            dispatch.handler = None;
            dispatch.ids.clear();
        }
    }

    /// `ERROR_REQUIRES_INTERACTIVE_WINDOWSTATION`: a service or SSH session.
    const NO_INTERACTIVE_DESKTOP: i32 = 1459;

    fn map_error(err: global_hotkey::Error) -> ShortcutError {
        match err {
            global_hotkey::Error::AlreadyRegistered(_) => ShortcutError::InUse,
            global_hotkey::Error::OsError(err)
                if err.raw_os_error() == Some(NO_INTERACTIVE_DESKTOP) =>
            {
                ShortcutError::Unsupported(
                    "Global shortcuts need the signed-in desktop; this LokalBot runs without one."
                        .into(),
                )
            }
            other => ShortcutError::Failed(other.to_string()),
        }
    }

    /// Handles one command; false once the worker should stop.
    fn handle(manager: &GlobalHotKeyManager, command: Command) -> bool {
        match command {
            Command::Register(hotkey, reply) => {
                let _ = reply.send(manager.register(hotkey).map_err(map_error));
            }
            Command::Unregister(hotkey, reply) => {
                let _ = reply.send(manager.unregister(hotkey).map_err(map_error));
            }
            Command::Stop => return false,
        }
        true
    }

    #[cfg(not(windows))]
    fn run(commands: Receiver<Command>, ready: Sender<Result<u32, String>>) {
        let manager = match GlobalHotKeyManager::new() {
            Ok(manager) => manager,
            Err(err) => {
                let _ = ready.send(Err(err.to_string()));
                return;
            }
        };
        let _ = ready.send(Ok(0));
        while let Ok(command) = commands.recv() {
            if !handle(&manager, command) {
                break;
            }
        }
    }

    #[cfg(windows)]
    fn run(commands: Receiver<Command>, ready: Sender<Result<u32, String>>) {
        let manager = match GlobalHotKeyManager::new() {
            Ok(manager) => manager,
            Err(err) => {
                let _ = ready.send(Err(err.to_string()));
                return;
            }
        };
        crate::win32_loop::run(
            |thread_id| {
                let _ = ready.send(Ok(thread_id));
            },
            || {
                while let Ok(command) = commands.try_recv() {
                    if !handle(&manager, command) {
                        return false;
                    }
                }
                true
            },
        );
    }

    pub(super) fn to_hotkey(shortcut: &Shortcut) -> Result<HotKey, ShortcutError> {
        let mut modifiers = Modifiers::empty();
        if shortcut.ctrl {
            modifiers |= Modifiers::CONTROL;
        }
        if shortcut.alt {
            modifiers |= Modifiers::ALT;
        }
        if shortcut.shift {
            modifiers |= Modifiers::SHIFT;
        }
        if shortcut.logo {
            modifiers |= Modifiers::META;
        }
        let key = shortcut
            .key
            .ok_or(ShortcutError::Invalid(super::ShortcutProblem::NeedsKey))?;
        let code = code(key).ok_or_else(|| {
            ShortcutError::Failed(format!("{} cannot be registered", shortcut.label()))
        })?;
        Ok(HotKey::new(
            (!modifiers.is_empty()).then_some(modifiers),
            code,
        ))
    }

    fn code(key: Key) -> Option<Code> {
        Some(match key {
            Key::Char(c) => match c {
                'A' => Code::KeyA,
                'B' => Code::KeyB,
                'C' => Code::KeyC,
                'D' => Code::KeyD,
                'E' => Code::KeyE,
                'F' => Code::KeyF,
                'G' => Code::KeyG,
                'H' => Code::KeyH,
                'I' => Code::KeyI,
                'J' => Code::KeyJ,
                'K' => Code::KeyK,
                'L' => Code::KeyL,
                'M' => Code::KeyM,
                'N' => Code::KeyN,
                'O' => Code::KeyO,
                'P' => Code::KeyP,
                'Q' => Code::KeyQ,
                'R' => Code::KeyR,
                'S' => Code::KeyS,
                'T' => Code::KeyT,
                'U' => Code::KeyU,
                'V' => Code::KeyV,
                'W' => Code::KeyW,
                'X' => Code::KeyX,
                'Y' => Code::KeyY,
                'Z' => Code::KeyZ,
                '0' => Code::Digit0,
                '1' => Code::Digit1,
                '2' => Code::Digit2,
                '3' => Code::Digit3,
                '4' => Code::Digit4,
                '5' => Code::Digit5,
                '6' => Code::Digit6,
                '7' => Code::Digit7,
                '8' => Code::Digit8,
                '9' => Code::Digit9,
                '-' => Code::Minus,
                '=' => Code::Equal,
                '[' => Code::BracketLeft,
                ']' => Code::BracketRight,
                '\\' => Code::Backslash,
                ';' => Code::Semicolon,
                '\'' => Code::Quote,
                ',' => Code::Comma,
                '.' => Code::Period,
                '/' => Code::Slash,
                '`' => Code::Backquote,
                _ => return None,
            },
            Key::Space => Code::Space,
            Key::Enter => Code::Enter,
            Key::Tab => Code::Tab,
            Key::Backspace => Code::Backspace,
            Key::Delete => Code::Delete,
            Key::Insert => Code::Insert,
            Key::Escape => Code::Escape,
            Key::Up => Code::ArrowUp,
            Key::Down => Code::ArrowDown,
            Key::Left => Code::ArrowLeft,
            Key::Right => Code::ArrowRight,
            Key::Home => Code::Home,
            Key::End => Code::End,
            Key::PageUp => Code::PageUp,
            Key::PageDown => Code::PageDown,
            Key::Function(n) => [
                Code::F1,
                Code::F2,
                Code::F3,
                Code::F4,
                Code::F5,
                Code::F6,
                Code::F7,
                Code::F8,
                Code::F9,
                Code::F10,
                Code::F11,
                Code::F12,
                Code::F13,
                Code::F14,
                Code::F15,
                Code::F16,
                Code::F17,
                Code::F18,
                Code::F19,
                Code::F20,
                Code::F21,
                Code::F22,
                Code::F23,
                Code::F24,
            ]
            .get(usize::from(n).checked_sub(1)?)
            .copied()?,
        })
    }
}

#[cfg(target_os = "linux")]
mod portal {
    //! The XDG `GlobalShortcuts` portal (KDE Plasma, Hyprland, GNOME 48+).
    //! Runs on its own thread and D-Bus connection, registered under the
    //! app id so the desktop can remember the user's choices.

    use std::collections::BTreeMap;
    use std::thread::JoinHandle;
    use std::time::Duration;

    use ashpd::desktop::Session;
    use ashpd::desktop::global_shortcuts::{
        BindShortcutsOptions, GlobalShortcuts as Portal, NewShortcut,
    };
    use crossbeam_channel::{Sender, bounded};
    use futures_lite::StreamExt;

    use super::{BIND_COMMAND_HINT, Handler, Shortcut, ShortcutError, ShortcutEvent};

    enum Command {
        Set(
            BTreeMap<String, Shortcut>,
            Sender<Result<(), ShortcutError>>,
        ),
        Stop,
    }

    pub(super) struct Worker {
        commands: async_channel::Sender<Command>,
        shortcuts: BTreeMap<String, Shortcut>,
        thread: Option<JoinHandle<()>>,
    }

    /// How long `register` waits for the desktop before returning.
    const REPLY_WAIT: Duration = Duration::from_secs(3);

    impl Worker {
        pub(super) fn start(handler: Handler) -> Result<Self, ShortcutError> {
            let (commands, receiver) = async_channel::unbounded();
            let (ready_tx, ready_rx) = bounded(1);
            let thread = std::thread::Builder::new()
                .name("lokalbot-shortcuts".into())
                .spawn(move || {
                    futures_lite::future::block_on(run(handler, receiver, ready_tx));
                })
                .map_err(|err| ShortcutError::Failed(err.to_string()))?;
            match ready_rx.recv_timeout(Duration::from_secs(5)) {
                Ok(Ok(())) => Ok(Self {
                    commands,
                    shortcuts: BTreeMap::new(),
                    thread: Some(thread),
                }),
                Ok(Err(err)) => Err(err),
                Err(_) => Err(ShortcutError::Unsupported(format!(
                    "The desktop did not answer the shortcut request. {BIND_COMMAND_HINT}"
                ))),
            }
        }

        fn sync(&mut self) -> Result<(), ShortcutError> {
            let (tx, rx) = bounded(1);
            self.commands
                .send_blocking(Command::Set(self.shortcuts.clone(), tx))
                .map_err(|_| ShortcutError::Failed("the shortcut thread stopped".into()))?;
            match rx.recv_timeout(REPLY_WAIT) {
                Ok(result) => result,
                // The desktop is probably showing its confirmation dialog.
                Err(_) => Ok(()),
            }
        }

        pub(super) fn register(
            &mut self,
            id: &str,
            shortcut: &Shortcut,
        ) -> Result<(), ShortcutError> {
            if self.shortcuts.get(id) == Some(shortcut) {
                return Ok(());
            }
            self.shortcuts.insert(id.to_string(), *shortcut);
            self.sync()
        }

        pub(super) fn unregister(&mut self, id: &str) -> Result<(), ShortcutError> {
            if self.shortcuts.remove(id).is_none() {
                return Ok(());
            }
            self.sync()
        }
    }

    impl Drop for Worker {
        fn drop(&mut self) {
            let _ = self.commands.send_blocking(Command::Stop);
            if let Some(thread) = self.thread.take() {
                let _ = thread.join();
            }
        }
    }

    fn description(id: &str) -> String {
        match id {
            "dictation" => "Start or stop dictation".into(),
            "quick-recall" | "ask" => "Open Ask".into(),
            other => other.replace(['-', '_'], " "),
        }
    }

    fn unsupported(err: impl std::fmt::Display) -> ShortcutError {
        log::info!("shortcuts portal unavailable: {err}");
        ShortcutError::Unsupported(format!(
            "This desktop does not let apps register global shortcuts. {BIND_COMMAND_HINT}"
        ))
    }

    enum Next {
        Event(Option<(String, String, bool)>),
        Command(Option<Command>),
    }

    async fn run(
        handler: Handler,
        commands: async_channel::Receiver<Command>,
        ready: Sender<Result<(), ShortcutError>>,
    ) {
        let connection = match zbus::Connection::session().await {
            Ok(connection) => connection,
            Err(err) => {
                let _ = ready.send(Err(unsupported(err)));
                return;
            }
        };
        if let Ok(app_id) = crate::APP_ID.parse() {
            // Older portals have no registry; they identify the app themselves.
            if let Err(err) =
                ashpd::register_host_app_with_connection(connection.clone(), app_id).await
            {
                log::debug!("portal registry: {err}");
            }
        }
        let portal = match Portal::with_connection(connection).await {
            Ok(portal) => portal,
            Err(err) => {
                let _ = ready.send(Err(unsupported(err)));
                return;
            }
        };
        let streams = async {
            let activated = portal.receive_activated().await?;
            let deactivated = portal.receive_deactivated().await?;
            Ok::<_, ashpd::Error>((activated, deactivated))
        };
        let (activated, deactivated) = match streams.await {
            Ok(streams) => streams,
            Err(err) => {
                let _ = ready.send(Err(unsupported(err)));
                return;
            }
        };
        let mut events = activated
            .map(|event| {
                (
                    event.session_handle().to_string(),
                    event.shortcut_id().to_string(),
                    true,
                )
            })
            .or(deactivated.map(|event| {
                (
                    event.session_handle().to_string(),
                    event.shortcut_id().to_string(),
                    false,
                )
            }));
        let _ = ready.send(Ok(()));

        let mut session: Option<Session<Portal>> = None;
        loop {
            let next =
                futures_lite::future::or(async { Next::Event(events.next().await) }, async {
                    Next::Command(commands.recv().await.ok())
                })
                .await;
            match next {
                Next::Event(Some((handle, id, pressed))) => {
                    if session.as_ref().and_then(session_path).as_deref() == Some(handle.as_str()) {
                        handler(ShortcutEvent { id, pressed });
                    }
                }
                Next::Event(None) => break,
                Next::Command(Some(Command::Set(shortcuts, reply))) => {
                    if let Some(old) = session.take() {
                        let _ = old.close().await;
                    }
                    let result = bind(&portal, &shortcuts).await;
                    let result = match result {
                        Ok(bound) => {
                            session = bound;
                            Ok(())
                        }
                        Err(err) => Err(err),
                    };
                    let _ = reply.send(result);
                }
                Next::Command(Some(Command::Stop)) | Next::Command(None) => break,
            }
        }
        if let Some(old) = session.take() {
            let _ = old.close().await;
        }
    }

    /// A session serializes as its object path.
    fn session_path(session: &Session<Portal>) -> Option<String> {
        serde_json::to_value(session)
            .ok()
            .and_then(|value| value.as_str().map(str::to_string))
    }

    async fn bind(
        portal: &Portal,
        shortcuts: &BTreeMap<String, Shortcut>,
    ) -> Result<Option<Session<Portal>>, ShortcutError> {
        if shortcuts.is_empty() {
            return Ok(None);
        }
        let session = portal
            .create_session(Default::default())
            .await
            .map_err(|err| ShortcutError::Failed(err.to_string()))?;
        let requested: Vec<NewShortcut> = shortcuts
            .iter()
            .map(|(id, shortcut)| {
                NewShortcut::new(id.clone(), description(id))
                    .preferred_trigger(shortcut.portal_trigger().as_deref())
            })
            .collect();
        let request = portal
            .bind_shortcuts(&session, &requested, None, BindShortcutsOptions::default())
            .await
            .map_err(|err| ShortcutError::Failed(err.to_string()))?;
        match request.response() {
            Ok(bound) => {
                for shortcut in bound.shortcuts() {
                    log::info!(
                        "shortcut {} bound to {}",
                        shortcut.id(),
                        shortcut.trigger_description()
                    );
                }
                Ok(Some(session))
            }
            Err(err) => Err(ShortcutError::Failed(err.to_string())),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn s(text: &str) -> Shortcut {
        Shortcut::parse(text).unwrap()
    }

    #[test]
    fn parses_settings_strings_and_symbols() {
        assert_eq!(s("Ctrl+Shift+Space"), Shortcut::QUICK_RECALL_DEFAULT);
        assert_eq!(s("alt+space"), Shortcut::DICTATION_DEFAULT);
        assert_eq!(s("⌥ Space"), Shortcut::DICTATION_DEFAULT);
        assert_eq!(s("⌃⇧ Space"), Shortcut::QUICK_RECALL_DEFAULT);
        assert_eq!(s("F5").key, Some(Key::Function(5)));
        assert_eq!(s("Super+d").key, Some(Key::Char('D')));
        assert!(s("Win+D").logo);
        assert_eq!(s("Ctrl+Alt").key, None);
        assert_eq!(s("Ctrl+/").key, Some(Key::Char('/')));
        assert_eq!(s("Control + Option + Comma").key, Some(Key::Char(',')));
        assert_eq!(Shortcut::parse(""), Err(ShortcutParseError::Empty));
        assert_eq!(
            Shortcut::parse("Ctrl+A+B"),
            Err(ShortcutParseError::SeveralKeys)
        );
        assert!(matches!(
            Shortcut::parse("Ctrl+Hyper"),
            Err(ShortcutParseError::UnknownKey(_))
        ));
        assert!(Shortcut::parse("F25").is_err());
    }

    #[test]
    fn labels_round_trip() {
        for text in [
            "Ctrl+Shift+Space",
            "Alt+Space",
            "F5",
            "Ctrl+Alt+K",
            "Ctrl+Alt",
        ] {
            assert_eq!(s(text).label(), text);
            assert_eq!(s(&s(text).label()), s(text));
        }
        assert_eq!(s("shift+ctrl+space").label(), "Ctrl+Shift+Space");
        assert_eq!(s("Super+Shift+D").label(), format!("Shift+{SUPER_LABEL}+D"));
    }

    #[test]
    fn dictation_rules() {
        use ShortcutProblem::*;
        assert_eq!(s("Alt+Space").dictation_problem(None), None);
        assert_eq!(s("F8").dictation_problem(None), None);
        assert_eq!(
            s("Ctrl+Alt+Esc").dictation_problem(None),
            Some(ReservedForCancel)
        );
        assert_eq!(s("Shift+A").dictation_problem(None), Some(NeedsModifier));
        assert_eq!(s("Space").dictation_problem(None), Some(NeedsModifier));
        assert_eq!(s("Ctrl+S").dictation_problem(None), Some(CtrlOnly));
        assert_eq!(s("Ctrl+Space").dictation_problem(None), None);
        assert_eq!(s("Ctrl+Shift+S").dictation_problem(None), None);
        assert_eq!(s("Ctrl").dictation_problem(None), Some(NeedsTwoModifiers));
        assert_eq!(
            s("Ctrl+Alt").dictation_problem(None),
            Some(ModifierOnlyUnsupported)
        );
        assert_eq!(
            s("Ctrl+Shift+Space").dictation_problem(Some(&Shortcut::QUICK_RECALL_DEFAULT)),
            Some(UsedByAsk)
        );
        assert_eq!(s("Alt+Tab").dictation_problem(None), Some(UsedBySystem));
    }

    #[test]
    fn ask_rules() {
        use ShortcutProblem::*;
        let dictation = Shortcut::DICTATION_DEFAULT;
        assert_eq!(
            Shortcut::QUICK_RECALL_DEFAULT.quick_recall_problem(Some(&dictation)),
            None
        );
        assert_eq!(s("Ctrl+Alt").quick_recall_problem(None), Some(NeedsKey));
        assert_eq!(
            s("Alt+Space").quick_recall_problem(Some(&dictation)),
            Some(UsedByDictation)
        );
        assert_eq!(s("Alt+F4").quick_recall_problem(None), Some(UsedBySystem));
        assert_eq!(
            ask_registration_failed_message(&Shortcut::QUICK_RECALL_DEFAULT),
            "The Ask shortcut could not register Ctrl+Shift+Space. Another app may already use it."
        );
    }

    #[test]
    fn messages_follow_the_mac_copy() {
        assert_eq!(
            ShortcutProblem::NeedsKey.message(),
            "Hold the modifiers and press a key, like Ctrl+Shift+Space."
        );
        assert_eq!(
            ShortcutProblem::ReservedForCancel.message(),
            "Esc cancels recording a shortcut. Choose another key."
        );
        assert!(
            ShortcutProblem::NeedsModifier
                .message()
                .starts_with("Add Ctrl, Alt or ")
        );
    }

    #[test]
    fn portal_triggers() {
        assert_eq!(
            s("Ctrl+Shift+Space").portal_trigger().as_deref(),
            Some("CTRL+SHIFT+space")
        );
        assert_eq!(s("Super+D").portal_trigger().as_deref(), Some("LOGO+d"));
        assert_eq!(s("Alt+F5").portal_trigger().as_deref(), Some("ALT+F5"));
        assert_eq!(s("Ctrl+Alt").portal_trigger(), None);
    }

    /// Exercises the worker thread and its message loop. Over SSH (session 0)
    /// the keys can never be pressed, but registration must still work.
    #[cfg(windows)]
    #[test]
    fn windows_registration_round_trip() {
        let mut shortcuts = match GlobalShortcuts::new(|_| {}) {
            Ok(shortcuts) => shortcuts,
            Err(err) => panic!("worker failed to start: {err}"),
        };
        assert_eq!(shortcuts.backend_name(), "win32");
        let chord = s("Ctrl+Alt+Shift+F12");
        match shortcuts.register("dictation", &chord) {
            Ok(()) => {}
            Err(ShortcutError::Unsupported(reason)) => {
                // SSH runs in session 0, which has no interactive desktop.
                eprintln!("registration unsupported here: {reason}");
                return;
            }
            Err(err) => panic!("{err}"),
        }
        // The same combination twice is refused before reaching Windows.
        assert!(matches!(
            shortcuts.register("ask", &chord),
            Err(ShortcutError::InUse)
        ));
        shortcuts.register("ask", &s("Ctrl+Alt+Shift+F11")).unwrap();
        shortcuts.unregister("dictation").unwrap();
        shortcuts.unregister("ask").unwrap();
        drop(shortcuts);
        // A new instance after the first is gone.
        let mut again = GlobalShortcuts::new(|_| {}).unwrap();
        again.register("dictation", &chord).unwrap();
    }

    #[cfg(any(windows, target_os = "linux"))]
    #[test]
    fn every_key_maps_to_a_hotkey() {
        let mut keys: Vec<Key> = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-=[]\\;',./`"
            .chars()
            .map(Key::Char)
            .collect();
        keys.extend([
            Key::Space,
            Key::Enter,
            Key::Tab,
            Key::Backspace,
            Key::Delete,
            Key::Insert,
            Key::Escape,
            Key::Up,
            Key::Down,
            Key::Left,
            Key::Right,
            Key::Home,
            Key::End,
            Key::PageUp,
            Key::PageDown,
        ]);
        keys.extend((1..=24).map(Key::Function));
        for key in keys {
            let shortcut = Shortcut {
                ctrl: true,
                alt: true,
                key: Some(key),
                ..Default::default()
            };
            assert!(hotkey::to_hotkey(&shortcut).is_ok(), "{key:?}");
        }
    }
}
