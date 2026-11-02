//! Who has focus, and whether it is still the field a dictation or a selection
//! action started in (`DictationFocusSnapshot`, `DictationDeliveryTarget`,
//! `DictationFocusSnapshotExecutor`).
//!
//! A snapshot holds only identity and privacy state: never field text. Reads
//! are serialized on one reader with a wall-clock deadline for each caller, so
//! a wedged app fails closed without piling up workers. Call from a background
//! thread.

use std::sync::LazyLock;
use std::time::Duration;

use parking_lot::Mutex;

use crate::activity::ActivitySource;
use crate::autocomplete::focused::{self, FieldRead};
use crate::screen::WindowCapture;

/// The shortcut's own read: the microphone opens alongside it.
pub const START_DEADLINE: Duration = Duration::from_millis(120);
/// Not on the shortcut's critical path, so slow apps get longer to answer.
pub const DELIVERY_DEADLINE: Duration = Duration::from_millis(600);

/// A non-empty selection in a field.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TextSelection {
    pub location: i32,
    pub length: i32,
}

impl TextSelection {
    fn from_offsets((start, end): (i32, i32)) -> Option<Self> {
        let (start, end) = (start.min(end), start.max(end));
        (start >= 0 && end > start).then_some(Self {
            location: start,
            length: end - start,
        })
    }
}

/// The app in front.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct FrontApp {
    pub pid: Option<u32>,
    pub app_name: String,
    /// Executable, `WM_CLASS`, or Wayland app id.
    pub app_id: String,
    /// The backend's window id: an X11 window, an `HWND`, or a compositor id.
    pub window: Option<u64>,
    pub title: String,
}

impl FrontApp {
    /// One of LokalBot's own windows.
    pub fn is_self(&self) -> bool {
        self.app_id == crate::privacy::SELF_APP_ID || self.pid == Some(std::process::id())
    }

    /// Whether this is still the same app.
    pub fn same_app(&self, other: &FrontApp) -> bool {
        if let (Some(a), Some(b)) = (self.pid, other.pid)
            && a != b
        {
            return false;
        }
        self.app_id == other.app_id
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Frontmost {
    /// This desktop does not say what is in front.
    Unknown,
    /// Nothing is in front: the desktop, a lock screen.
    Nothing,
    App(FrontApp),
}

/// The minimum state to bind and later validate a destination.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct FocusSnapshot {
    pub front: FrontApp,
    /// The focused element's process, when accessibility answered.
    pub field_pid: Option<u32>,
    /// Present only for an editable field.
    pub identity: Option<String>,
    pub secure: bool,
    pub selection: Option<TextSelection>,
    pub terminal: bool,
    /// Accessibility answered for this app, so "no selection" means something.
    pub accessible: bool,
}

impl FocusSnapshot {
    /// The process to act on: the field's, else the window's.
    pub fn pid(&self) -> Option<u32> {
        self.field_pid.or(self.front.pid)
    }

    /// Screen and nearby-text context are never read from a secure field or
    /// while text is selected.
    pub fn blocks_context_capture(&self) -> bool {
        self.secure || self.selection.is_some()
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum FocusRead {
    /// This desktop gives no information at all about focus.
    Unknown,
    /// Nothing has focus.
    Nothing,
    /// The app did not answer in time.
    TimedOut,
    Snapshot(FocusSnapshot),
}

/// Why a finished result may or may not be pasted where it began.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DeliveryCheck {
    Deliverable,
    FocusMoved,
    SelectionChanged,
    SecureField,
    /// The field could not be read, or the app did not answer in time.
    FieldUnreadable,
}

/// The app and field that owned focus when the shortcut was pressed.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct DeliveryTarget {
    pub pid: Option<u32>,
    pub app_id: String,
    pub identity: Option<String>,
    /// Text selected at the start. Pasting replaces exactly that selection,
    /// the way typing would; any other selection blocks the paste.
    pub selection: Option<TextSelection>,
}

impl DeliveryTarget {
    /// `None` for a secure field: a target must never become permission to
    /// paste into a password field later.
    pub fn captured(snapshot: &FocusSnapshot) -> Option<Self> {
        (!snapshot.secure).then(|| Self {
            pid: snapshot.pid(),
            app_id: snapshot.front.app_id.clone(),
            identity: snapshot.identity.clone(),
            selection: snapshot.selection,
        })
    }

    fn matches(&self, snapshot: &FocusSnapshot) -> bool {
        if let (Some(a), Some(b)) = (self.pid, snapshot.pid())
            && a != b
        {
            return false;
        }
        if !self.app_id.is_empty()
            && !snapshot.front.app_id.is_empty()
            && self.app_id != snapshot.front.app_id
        {
            return false;
        }
        match self.identity.as_deref().filter(|key| !key.is_empty()) {
            Some(key) => snapshot.identity.as_deref() == Some(key),
            None => true,
        }
    }

    /// A blocked snapshot always wins over the app-only fallback.
    pub fn check(&self, snapshot: &FocusSnapshot) -> DeliveryCheck {
        if snapshot.secure {
            return DeliveryCheck::SecureField;
        }
        if !self.matches(snapshot) {
            return DeliveryCheck::FocusMoved;
        }
        if let Some(current) = snapshot.selection
            && Some(current) != self.selection
        {
            return DeliveryCheck::SelectionChanged;
        }
        DeliveryCheck::Deliverable
    }

    /// For replacing a selection: the exact selection, including a range
    /// having been cleared to a caret.
    pub fn strict_check(&self, snapshot: &FocusSnapshot) -> DeliveryCheck {
        match self.check(snapshot) {
            DeliveryCheck::Deliverable if self.selection != snapshot.selection => {
                DeliveryCheck::SelectionChanged
            }
            check => check,
        }
    }

    pub fn has_field(&self) -> bool {
        self.identity.as_deref().is_some_and(|key| !key.is_empty())
    }
}

/// Reads what is in front. Keeps its desktop connections between reads.
struct FrontReader {
    activity: Box<dyn ActivitySource>,
    capture: Box<dyn WindowCapture>,
}

impl FrontReader {
    fn new() -> Self {
        Self {
            activity: crate::activity::activity_source(),
            capture: crate::screen::window_capture(),
        }
    }

    fn read(&mut self) -> Frontmost {
        let sample = match self.activity.sample() {
            Ok(Some(sample)) => sample,
            Ok(None) if self.activity.backend_name() != "unavailable" => {
                return Frontmost::Nothing;
            }
            _ => return Self::from_accessibility(),
        };
        let window = self.capture.focused().ok().flatten();
        #[cfg_attr(not(windows), allow(unused_mut))]
        let mut pid = window.as_ref().and_then(|w| w.pid);
        // A store app's window belongs to its frame host; its fields do not.
        #[cfg(windows)]
        {
            pid = crate::activity::foreground_pid().or(pid);
        }
        Frontmost::App(FrontApp {
            pid,
            app_name: sample.app,
            app_id: sample.app_id,
            window: window.map(|w| w.id),
            title: sample.title,
        })
    }

    /// A Wayland desktop with no window information can still say which
    /// app's window is active, when that app publishes accessibility.
    fn from_accessibility() -> Frontmost {
        #[cfg(target_os = "linux")]
        if crate::session::is_wayland()
            && let Some(pid) = focused::active_pid()
        {
            let (app_name, app_id) = crate::activity::AppResolver::new().resolve(pid, None, None);
            return Frontmost::App(FrontApp {
                pid: Some(pid),
                app_name,
                app_id,
                window: None,
                title: String::new(),
            });
        }
        Frontmost::Unknown
    }
}

/// One reader for the process: reads queue behind each other.
static READER: LazyLock<Mutex<Option<FrontReader>>> = LazyLock::new(|| Mutex::new(None));

fn read_frontmost() -> Frontmost {
    let mut guard = READER.lock();
    let reader = guard.get_or_insert_with(FrontReader::new);
    reader.read()
}

/// Runs `work` off this thread and gives up waiting after `deadline`; the
/// work itself is bounded by each backend's call timeouts.
pub fn with_deadline<T: Send + 'static>(
    deadline: Duration,
    work: impl FnOnce() -> T + Send + 'static,
) -> Option<T> {
    let (tx, rx) = crossbeam_channel::bounded(1);
    std::thread::Builder::new()
        .name("lokalbot-focus-read".into())
        .spawn(move || {
            let _ = tx.send(work());
        })
        .ok()?;
    rx.recv_timeout(deadline).ok()
}

/// The app in front now.
pub fn frontmost(deadline: Duration) -> Option<Frontmost> {
    with_deadline(deadline, read_frontmost)
}

fn snapshot_now() -> FocusRead {
    let front = match read_frontmost() {
        Frontmost::Unknown => return FocusRead::Unknown,
        Frontmost::Nothing => return FocusRead::Nothing,
        Frontmost::App(front) => front,
    };
    if front.is_self() {
        return FocusRead::Snapshot(FocusSnapshot {
            front,
            ..FocusSnapshot::default()
        });
    }
    let mut snapshot = FocusSnapshot {
        front,
        ..FocusSnapshot::default()
    };
    match focused::read_field(snapshot.front.pid) {
        FieldRead::Silent => {}
        FieldRead::NoFocus => snapshot.accessible = true,
        FieldRead::Field(field) => {
            snapshot.accessible = true;
            snapshot.field_pid = Some(field.pid);
            snapshot.secure = field.secure;
            snapshot.terminal = field.terminal;
            if field.editable && !field.secure && !field.key.is_empty() {
                snapshot.identity = Some(field.key);
                snapshot.selection = field.selection.and_then(TextSelection::from_offsets);
            }
        }
    }
    FocusRead::Snapshot(snapshot)
}

/// Reads who has focus, within `deadline`.
pub fn read_focus(deadline: Duration) -> FocusRead {
    with_deadline(deadline, snapshot_now).unwrap_or(FocusRead::TimedOut)
}

/// Brings a window forward. Wayland lets no app do this: there the desktop
/// returns focus by itself when LokalBot's panel closes, and the check that
/// follows confirms it.
pub fn activate_window(front: &FrontApp) -> bool {
    #[cfg(target_os = "linux")]
    {
        if crate::session::is_wayland() {
            return true;
        }
        let Some(window) = front.window else {
            return false;
        };
        x11_activate(window as u32).is_ok()
    }
    #[cfg(windows)]
    {
        use windows::Win32::Foundation::HWND;
        use windows::Win32::UI::WindowsAndMessaging::SetForegroundWindow;
        let Some(window) = front.window else {
            return false;
        };
        // SAFETY: an invalid handle makes the call fail; nothing is dereferenced.
        unsafe { SetForegroundWindow(HWND(window as usize as *mut _)) }.as_bool()
    }
    #[cfg(not(any(windows, target_os = "linux")))]
    {
        let _ = front;
        false
    }
}

/// `_NET_ACTIVE_WINDOW`, marked as a request from a pager so window managers
/// honor it.
#[cfg(target_os = "linux")]
fn x11_activate(window: u32) -> anyhow::Result<()> {
    use anyhow::Context as _;
    use x11rb::connection::Connection as _;
    use x11rb::protocol::xproto::{ClientMessageEvent, ConnectionExt as _, EventMask};

    let (conn, screen) = x11rb::connect(None).context("no X11 display")?;
    let root = conn
        .setup()
        .roots
        .get(screen)
        .context("no X11 screen")?
        .root;
    let atom = conn
        .intern_atom(false, b"_NET_ACTIVE_WINDOW")?
        .reply()?
        .atom;
    let event = ClientMessageEvent::new(32, window, atom, [2u32, x11rb::CURRENT_TIME, 0, 0, 0]);
    conn.send_event(
        false,
        root,
        EventMask::SUBSTRUCTURE_NOTIFY | EventMask::SUBSTRUCTURE_REDIRECT,
        event,
    )?;
    conn.flush()?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn snapshot(pid: u32, app: &str, identity: Option<&str>) -> FocusSnapshot {
        FocusSnapshot {
            front: FrontApp {
                pid: Some(pid),
                app_id: app.into(),
                ..FrontApp::default()
            },
            field_pid: Some(pid),
            identity: identity.map(str::to_string),
            ..FocusSnapshot::default()
        }
    }

    #[test]
    fn a_target_follows_its_field() {
        let start = snapshot(7, "editor", Some("a"));
        let target = DeliveryTarget::captured(&start).unwrap();
        assert_eq!(target.check(&start), DeliveryCheck::Deliverable);
        assert_eq!(
            target.check(&snapshot(7, "editor", Some("b"))),
            DeliveryCheck::FocusMoved
        );
        assert_eq!(
            target.check(&snapshot(7, "editor", None)),
            DeliveryCheck::FocusMoved
        );
        assert_eq!(
            target.check(&snapshot(8, "editor", Some("a"))),
            DeliveryCheck::FocusMoved
        );
        assert_eq!(
            target.check(&snapshot(7, "other", Some("a"))),
            DeliveryCheck::FocusMoved
        );
    }

    #[test]
    fn an_app_only_target_never_permits_a_password_field() {
        let target = DeliveryTarget::captured(&snapshot(7, "editor", None)).unwrap();
        assert_eq!(
            target.check(&snapshot(7, "editor", Some("later"))),
            DeliveryCheck::Deliverable
        );
        let mut password = snapshot(7, "editor", None);
        password.secure = true;
        assert_eq!(target.check(&password), DeliveryCheck::SecureField);
        assert_eq!(
            DeliveryTarget::captured(&password),
            None,
            "a secure field binds no target"
        );
    }

    #[test]
    fn selections_must_stay_as_they_were() {
        let range = TextSelection {
            location: 2,
            length: 3,
        };
        let mut start = snapshot(7, "editor", Some("a"));
        start.selection = Some(range);
        let target = DeliveryTarget::captured(&start).unwrap();
        assert_eq!(target.check(&start), DeliveryCheck::Deliverable);
        let mut other = start.clone();
        other.selection = Some(TextSelection {
            location: 2,
            length: 4,
        });
        assert_eq!(target.check(&other), DeliveryCheck::SelectionChanged);
        // Cleared to a caret: dictation may still paste there, a replacement may not.
        let mut cleared = start.clone();
        cleared.selection = None;
        assert_eq!(target.check(&cleared), DeliveryCheck::Deliverable);
        assert_eq!(
            target.strict_check(&cleared),
            DeliveryCheck::SelectionChanged
        );
        let plain = DeliveryTarget::captured(&snapshot(7, "editor", Some("a"))).unwrap();
        assert_eq!(plain.check(&other), DeliveryCheck::SelectionChanged);
    }

    #[test]
    fn wayland_without_a_pid_compares_the_app() {
        let mut start = snapshot(7, "editor", None);
        start.front.pid = None;
        start.field_pid = None;
        let target = DeliveryTarget::captured(&start).unwrap();
        assert_eq!(target.check(&start), DeliveryCheck::Deliverable);
        let mut other = start.clone();
        other.front.app_id = "browser".into();
        assert_eq!(target.check(&other), DeliveryCheck::FocusMoved);
    }

    #[test]
    fn selections_come_from_ordered_offsets() {
        assert_eq!(TextSelection::from_offsets((3, 3)), None);
        assert_eq!(
            TextSelection::from_offsets((5, 2)),
            Some(TextSelection {
                location: 2,
                length: 3
            })
        );
    }
}
