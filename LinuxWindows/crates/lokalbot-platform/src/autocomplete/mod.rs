// Contains code ported from Cotabby (https://github.com/FuJacob/cotabby),
// copyright the Cotabby authors, under the GNU AGPL v3.0
// (LICENSES/AGPL-3.0.txt). Modified for LokalBot since 18 October 2026.
// See THIRD_PARTY_NOTICES.md.

//! Autocomplete's desktop side (`LokalBot/Cotyping`): reading the text field
//! the user types in, taking Tab and Esc while ghost text shows, and typing
//! an accepted suggestion into the field. Prediction lives in the engine.
//!
//! - [`FieldWatcher`] follows the focused field on its own thread: AT-SPI2
//!   events on Linux, UI Automation events on Windows, each with a polled
//!   fallback that backs off while nothing changes. Every snapshot holds the
//!   app, the window title, the bounded text around the caret, the caret on
//!   screen, and whether the field is secure or single-line.
//! - [`KeyInterceptor`] takes plain Tab and Esc only while it is active, which
//!   the app keeps true exactly while a suggestion is visible: `XGrabKey` on
//!   X11, a low-level keyboard hook on Windows.
//! - [`insert`] types an accepted chunk at the caret: AT-SPI `EditableText`
//!   when the field supports it, else XTest; `SendInput` Unicode keystrokes on
//!   Windows. Never through the clipboard.
//!
//! Privacy (`PRIVACY.md`): nothing is read while autocomplete is off, secure
//! fields and excluded apps are never read (the check runs before any text
//! is), LokalBot's own windows are skipped, and nothing is kept on disk.
//!
//! Wayland lets no app take a key from another app or place a window at
//! another app's caret, so [`support`] reports autocomplete in other apps as
//! unavailable there; LokalBot's own practice editor still works.

pub mod geometry;
pub mod policy;
pub mod session;
pub mod visible;

#[cfg(target_os = "linux")]
mod atspi;
#[cfg(windows)]
mod uia;
#[cfg(windows)]
mod win32;
#[cfg(target_os = "linux")]
mod x11;

use std::sync::Arc;

pub use geometry::{FieldStyle, Rect, Rgb};
pub use policy::ReadPolicy;

/// Whether the focused element can take a suggestion (`CotypingCapability`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Capability {
    /// An editable field with a collapsed caret.
    Supported,
    /// Editable, but withheld: a secure field or selected text.
    Blocked(&'static str),
    /// Not a text field autocomplete can drive.
    Unsupported(&'static str),
}

/// The focused field, read once (`CotypingField`). Never contains text from
/// a secure field or an excluded app.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct FieldSnapshot {
    /// The toolkit's identity for the element (bus name and object path, or
    /// UI Automation runtime id). Empty when it has none.
    pub focus_key: String,
    pub app_name: String,
    /// Desktop id, `WM_CLASS` or executable: "org.gnome.TextEditor", "notepad.exe".
    pub app_id: String,
    pub pid: u32,
    pub window_title: String,
    /// Text before the caret, at most [`policy::MAX_BEFORE_UTF16`] units.
    pub before: String,
    pub before_truncated: bool,
    /// Text after the caret, at most [`policy::MAX_AFTER_UTF16`] units.
    pub after: String,
    /// The caret in screen pixels (top-left origin). Zero width.
    pub caret: Rect,
    /// False when the caret was estimated from the field's frame.
    pub caret_exact: bool,
    pub field_frame: Option<Rect>,
    /// A one-line input, where Enter usually sends.
    pub single_line: bool,
    /// The page address when the app is a browser and it could be read.
    pub url: Option<String>,
    /// Text shown just above the field, read once per field when allowed.
    pub visible_text: Option<String>,
    pub style: Option<FieldStyle>,
    /// How [`insert`] reaches this field.
    pub target: InsertTarget,
}

/// What [`insert`] needs to type into a field.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct InsertTarget {
    /// AT-SPI bus name and object path, when the field supports `EditableText`.
    #[cfg(target_os = "linux")]
    pub(crate) editable: Option<(String, String)>,
    pub(crate) pid: u32,
}

/// The watcher's view of focus (`CotypingFocus`).
#[derive(Clone, Debug, PartialEq)]
pub struct FocusSnapshot {
    pub app_name: String,
    pub app_id: String,
    pub capability: Capability,
    /// Set only for [`Capability::Supported`].
    pub field: Option<FieldSnapshot>,
    /// The element's identity even when its text is withheld.
    pub focus_key: Option<String>,
}

impl FocusSnapshot {
    pub fn none() -> Self {
        Self {
            app_name: String::new(),
            app_id: String::new(),
            capability: Capability::Unsupported(policy::reasons::NO_FIELD),
            field: None,
            focus_key: None,
        }
    }

    fn blocked(app_name: &str, app_id: &str, reason: &'static str, key: Option<String>) -> Self {
        Self {
            app_name: app_name.into(),
            app_id: app_id.into(),
            capability: Capability::Blocked(reason),
            field: None,
            focus_key: key,
        }
    }

    fn unsupported(app_name: &str, app_id: &str, reason: &'static str) -> Self {
        Self {
            app_name: app_name.into(),
            app_id: app_id.into(),
            capability: Capability::Unsupported(reason),
            field: None,
            focus_key: None,
        }
    }
}

/// Whether autocomplete can work in other apps in this session.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Support {
    Available,
    /// Why not, worded for Settings.
    Unavailable(String),
}

/// What this desktop allows. Cheap; call it when Settings opens.
pub fn support() -> Support {
    #[cfg(target_os = "linux")]
    {
        if crate::session::is_wayland() {
            return Support::Unavailable(WAYLAND_LIMITATION.into());
        }
        if !crate::session::has_x11_display() {
            return Support::Unavailable(
                "No desktop session was found, so autocomplete cannot see other apps.".into(),
            );
        }
        Support::Available
    }
    #[cfg(windows)]
    {
        Support::Available
    }
    #[cfg(not(any(windows, target_os = "linux")))]
    {
        Support::Unavailable("Autocomplete is not available on this system.".into())
    }
}

/// The exact Wayland behavior, worded for Settings.
pub const WAYLAND_LIMITATION: &str = "Autocomplete in other apps needs an X11 session. Wayland does not let an app take the Tab key from other apps or show text at their cursor, so on this desktop suggestions appear only in the practice editor below.";

type FocusHandler = Arc<dyn Fn(FocusSnapshot) + Send + Sync>;
type KeyHandler = Arc<dyn Fn(InterceptedKey) + Send + Sync>;

/// Follows the focused field on a background thread until dropped. The
/// handler runs on that thread whenever the snapshot changes; forward it to
/// the UI thread.
pub struct FieldWatcher {
    #[cfg(target_os = "linux")]
    inner: atspi::Watcher,
    #[cfg(windows)]
    inner: uia::Watcher,
}

impl FieldWatcher {
    pub fn start(
        policy: ReadPolicy,
        handler: impl Fn(FocusSnapshot) + Send + Sync + 'static,
    ) -> anyhow::Result<Self> {
        let handler: FocusHandler = Arc::new(handler);
        #[cfg(target_os = "linux")]
        {
            if let Support::Unavailable(reason) = support() {
                anyhow::bail!(reason);
            }
            Ok(Self {
                inner: atspi::Watcher::start(policy, handler)?,
            })
        }
        #[cfg(windows)]
        {
            Ok(Self {
                inner: uia::Watcher::start(policy, handler)?,
            })
        }
        #[cfg(not(any(windows, target_os = "linux")))]
        {
            let _ = (policy, handler);
            anyhow::bail!("Autocomplete is not available on this system.")
        }
    }

    /// Applies new exclusions at once; the next snapshot follows them.
    pub fn set_policy(&self, policy: ReadPolicy) {
        #[cfg(any(windows, target_os = "linux"))]
        self.inner.set_policy(policy);
        #[cfg(not(any(windows, target_os = "linux")))]
        let _ = policy;
    }

    /// Reads the field again now instead of at the next event or poll.
    pub fn refresh_now(&self) {
        #[cfg(any(windows, target_os = "linux"))]
        self.inner.refresh_now();
    }

    /// What the backend cannot do on this desktop, worded for Settings.
    pub fn limitation(&self) -> Option<String> {
        #[cfg(any(windows, target_os = "linux"))]
        {
            self.inner.limitation()
        }
        #[cfg(not(any(windows, target_os = "linux")))]
        {
            None
        }
    }
}

/// A key taken while a suggestion shows.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum InterceptedKey {
    Tab,
    Escape,
}

/// Takes plain Tab and Esc away from the focused app while active. Inactive
/// it holds no grab or hook, so the keyboard is untouched.
pub struct KeyInterceptor {
    #[cfg(target_os = "linux")]
    inner: x11::Grabber,
    #[cfg(windows)]
    inner: win32::Hook,
}

impl KeyInterceptor {
    pub fn start(handler: impl Fn(InterceptedKey) + Send + Sync + 'static) -> anyhow::Result<Self> {
        let handler: KeyHandler = Arc::new(handler);
        #[cfg(target_os = "linux")]
        {
            if let Support::Unavailable(reason) = support() {
                anyhow::bail!(reason);
            }
            Ok(Self {
                inner: x11::Grabber::start(handler)?,
            })
        }
        #[cfg(windows)]
        {
            Ok(Self {
                inner: win32::Hook::start(handler)?,
            })
        }
        #[cfg(not(any(windows, target_os = "linux")))]
        {
            let _ = handler;
            anyhow::bail!("Autocomplete is not available on this system.")
        }
    }

    /// Takes Tab and Esc while `true`; releases them at once when `false`.
    pub fn set_active(&self, active: bool) {
        #[cfg(any(windows, target_os = "linux"))]
        self.inner.set_active(active);
        #[cfg(not(any(windows, target_os = "linux")))]
        let _ = active;
    }

    /// Sends a key that was taken but not used on to the focused app, so a
    /// Tab pressed as a suggestion went away still moves focus (macOS fails
    /// open the same way).
    pub fn pass_through(&self, key: InterceptedKey) {
        #[cfg(any(windows, target_os = "linux"))]
        self.inner.pass_through(key);
        #[cfg(not(any(windows, target_os = "linux")))]
        let _ = key;
    }
}

/// One edit at the caret: delete `backward` characters (grapheme clusters)
/// before it and `forward` after it, then type `text`.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Edit {
    pub text: String,
    pub backward: usize,
    pub forward: usize,
}

/// Applies `edit` to `field`, which must still have focus. Blocks for the
/// few milliseconds the app takes; call from a background thread. Refuses
/// rather than typing into another app.
pub fn insert(field: &FieldSnapshot, edit: &Edit) -> anyhow::Result<()> {
    let text = edit.text.replace('\r', "");
    if text.is_empty() && edit.backward == 0 && edit.forward == 0 {
        return Ok(());
    }
    // A burst of deletions from one accept stays small, as on macOS
    // (`CotypingSyntheticEditPolicy`).
    anyhow::ensure!(
        edit.backward <= 64 && edit.forward <= 64,
        "an accept never deletes more than 64 characters"
    );
    let edit = Edit {
        text,
        backward: edit.backward,
        forward: edit.forward,
    };
    #[cfg(target_os = "linux")]
    {
        atspi::insert(field, &edit)
    }
    #[cfg(windows)]
    {
        win32::insert(field, &edit)
    }
    #[cfg(not(any(windows, target_os = "linux")))]
    {
        let _ = (field, edit);
        anyhow::bail!("Typing into other apps is not available on this system.")
    }
}

/// A window of LokalBot's own, for the overlay helpers below.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum NativeWindow {
    /// An X11 window id.
    X11(u32),
    /// A Win32 `HWND`.
    Win32(isize),
}

/// Makes the ghost window click-through, never activated by a click, and
/// (on Windows, when `exclude_from_capture`) left out of screenshots and
/// recordings, as macOS does with `sharingType = .none`.
pub fn prepare_overlay(window: NativeWindow, exclude_from_capture: bool) -> anyhow::Result<()> {
    match window {
        #[cfg(target_os = "linux")]
        NativeWindow::X11(id) => {
            let _ = exclude_from_capture;
            x11::prepare_overlay(id)
        }
        #[cfg(windows)]
        NativeWindow::Win32(hwnd) => win32::prepare_overlay(hwnd, exclude_from_capture),
        _ => {
            let _ = exclude_from_capture;
            Ok(())
        }
    }
}

/// Moves and sizes the ghost window to `frame` (screen pixels) and shows or
/// hides it, without activating it.
pub fn place_overlay(window: NativeWindow, frame: Option<Rect>) -> anyhow::Result<()> {
    match window {
        #[cfg(target_os = "linux")]
        NativeWindow::X11(id) => x11::place_overlay(id, frame),
        #[cfg(windows)]
        NativeWindow::Win32(hwnd) => win32::place_overlay(hwnd, frame),
        _ => {
            let _ = frame;
            Ok(())
        }
    }
}

/// Device pixels per logical pixel on the monitor showing `rect`, where the
/// system keeps a scale per monitor (Windows). `None` elsewhere: X11 has one
/// scale for the whole screen, which the ghost window already reports.
pub fn scale_at(rect: &Rect) -> Option<f32> {
    #[cfg(windows)]
    {
        win32::scale_at(rect)
    }
    #[cfg(not(windows))]
    {
        let _ = rect;
        None
    }
}

/// The work area of the monitor showing `rect`, in screen pixels, so ghost
/// text and pills stay on screen.
pub fn screen_containing(rect: &Rect) -> Option<Rect> {
    #[cfg(target_os = "linux")]
    {
        x11::screen_containing(rect)
    }
    #[cfg(windows)]
    {
        win32::screen_containing(rect)
    }
    #[cfg(not(any(windows, target_os = "linux")))]
    {
        let _ = rect;
        None
    }
}

/// The luminance (0–1) of the screen just behind where ghost text would go,
/// to keep it legible on fields whose colors the toolkit does not report.
/// `None` when the screen cannot be read.
pub fn sample_luminance(rect: &Rect) -> Option<f32> {
    #[cfg(target_os = "linux")]
    {
        x11::sample_luminance(rect)
    }
    #[cfg(windows)]
    {
        win32::sample_luminance(rect)
    }
    #[cfg(not(any(windows, target_os = "linux")))]
    {
        let _ = rect;
        None
    }
}
