//! Reads the text selected in the frontmost app, once, on an explicit shortcut
//! press (`SelectionCapture.swift`). Accessibility comes first. On X11 the
//! primary selection follows, only when its owner is the frontmost app. Apps
//! that share neither get a synthetic Ctrl+C whose result is read and the
//! previous clipboard put back, never in a terminal, where Ctrl+C is an
//! interrupt.
//!
//! The primary selection is not read on Wayland: its owner cannot be checked
//! there, so a stale one could come from an excluded app. The text lives only
//! in memory for the panel's lifetime.

use std::time::{Duration, Instant};

use crate::autocomplete::focused::{self, SelectionRead};
use crate::autocomplete::policy;
use crate::focus::{self, DeliveryTarget, FocusRead, FocusSnapshot, FrontApp, Frontmost};

/// Longest selection kept in memory; the prompt uses less.
pub const MAX_CHARACTERS: usize = 50_000;
const FOCUS_DEADLINE: Duration = Duration::from_millis(300);
const READ_DEADLINE: Duration = Duration::from_millis(400);
const COPY_TIMEOUT: Duration = Duration::from_millis(450);
const COPY_POLL: Duration = Duration::from_millis(15);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SelectionIssue {
    /// The app is on the exclusion list; nothing was read.
    ExcludedApp,
    /// A password or other secure field has focus; nothing was read.
    SecureField,
    /// Focus changed or could not be verified; no selection is accepted.
    FocusChanged,
}

/// What the shortcut found in the frontmost app.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct SelectionCapture {
    pub source: Option<FrontApp>,
    pub text: String,
    /// The editable field the selection sits in, where a result can replace
    /// it or go in at the caret. `None` for read-only text, or when the app
    /// shares no accessibility.
    pub target: Option<DeliveryTarget>,
    pub issue: Option<SelectionIssue>,
    /// LokalBot copied it with a keystroke and restored the clipboard.
    pub read_through_clipboard: bool,
}

impl SelectionCapture {
    pub fn has_selection(&self) -> bool {
        !self.text.trim().is_empty()
    }

    /// A result can go back into the source app's field.
    pub fn can_insert(&self) -> bool {
        self.target.is_some() && self.issue.is_none()
    }
}

/// What the capture needs from the desktop, so its order of checks can be
/// tested without one.
pub trait CaptureHost {
    fn source(&mut self) -> Option<FrontApp>;
    fn focus(&mut self) -> FocusRead;
    fn read(&mut self, source: &FrontApp) -> SelectionRead;
    /// The primary selection, when its owner is `source` (X11).
    fn primary(&mut self, source: &FrontApp) -> Option<String>;
    /// Copies with a keystroke and restores the clipboard.
    fn copy(&mut self, source: &FrontApp) -> Option<String>;
}

fn is_excluded(source: &FrontApp, excluded: &[String]) -> bool {
    policy::is_excluded(&source.app_name, &source.app_id, excluded)
        || crate::privacy::is_password_manager(&source.app_name, &source.app_id)
}

fn is_terminal(source: &FrontApp, snapshot: &FocusSnapshot) -> bool {
    snapshot.terminal || policy::is_terminal_app(&source.app_name, &source.app_id)
}

fn clipped(text: String) -> String {
    if text.chars().count() > MAX_CHARACTERS {
        text.chars().take(MAX_CHARACTERS).collect()
    } else {
        text
    }
}

/// The order of checks in `SelectionCapture.capture`. The source is re-read
/// after every step that can take time.
pub fn capture_with(host: &mut dyn CaptureHost, excluded: &[String]) -> SelectionCapture {
    let Some(source) = host.source() else {
        return SelectionCapture::default();
    };
    let mut result = SelectionCapture {
        source: Some(source.clone()),
        ..SelectionCapture::default()
    };
    if is_excluded(&source, excluded) {
        result.issue = Some(SelectionIssue::ExcludedApp);
        return result;
    }
    let focus = host.focus();
    let same = |host: &mut dyn CaptureHost| {
        host.source()
            .is_some_and(|current| current.same_app(&source))
    };
    let snapshot = match focus {
        FocusRead::Snapshot(snapshot)
            if same(host)
                && snapshot.front.same_app(&source)
                && (source.pid.is_none()
                    || snapshot.pid().is_none()
                    || snapshot.pid() == source.pid) =>
        {
            snapshot
        }
        _ => {
            result.issue = Some(SelectionIssue::FocusChanged);
            return result;
        }
    };
    if snapshot.secure {
        result.issue = Some(SelectionIssue::SecureField);
        return result;
    }
    // Only an editable field has an identity; read-only text cannot take a
    // replacement.
    if snapshot.identity.as_deref().is_some_and(|k| !k.is_empty()) {
        result.target = DeliveryTarget::captured(&snapshot);
    }
    // A Wayland desktop may name the app but not its process; accessibility
    // knows which one has the field.
    let acting = FrontApp {
        pid: snapshot.pid(),
        ..source.clone()
    };
    let lost = |source: &FrontApp| SelectionCapture {
        source: Some(source.clone()),
        issue: Some(SelectionIssue::FocusChanged),
        ..SelectionCapture::default()
    };

    let accessible = host.read(&acting);
    if !same(host) {
        return lost(&source);
    }
    let mut stale_primary = false;
    match accessible {
        SelectionRead::Text(text) => {
            result.text = clipped(text);
            return result;
        }
        SelectionRead::Secure => {
            result.target = None;
            result.issue = Some(SelectionIssue::SecureField);
            return result;
        }
        // An editable field with nothing selected: an older selection in the
        // same app would be stale.
        SelectionRead::Empty => stale_primary = true,
        SelectionRead::Unavailable => {}
    }
    if !stale_primary {
        let primary = host.primary(&acting);
        if !same(host) {
            return lost(&source);
        }
        if let Some(text) = primary.filter(|t| !t.trim().is_empty()) {
            result.text = clipped(text);
            return result;
        }
    }
    if is_terminal(&source, &snapshot) {
        return result;
    }
    let copied = host.copy(&acting);
    if !same(host) {
        return lost(&source);
    }
    if let Some(text) = copied.filter(|t| !t.trim().is_empty()) {
        result.text = clipped(text);
        result.read_through_clipboard = true;
    }
    result
}

/// The capture on this desktop. Blocking: call from a background thread.
pub fn capture(excluded: &[String]) -> SelectionCapture {
    capture_with(&mut LiveHost, excluded)
}

struct LiveHost;

impl CaptureHost for LiveHost {
    fn source(&mut self) -> Option<FrontApp> {
        live_source()
    }

    fn focus(&mut self) -> FocusRead {
        focus::read_focus(FOCUS_DEADLINE)
    }

    fn read(&mut self, source: &FrontApp) -> SelectionRead {
        let Some(pid) = source.pid else {
            return SelectionRead::Unavailable;
        };
        focus::with_deadline(READ_DEADLINE, move || {
            focused::selected_text(pid, MAX_CHARACTERS)
        })
        .unwrap_or(SelectionRead::Unavailable)
    }

    fn primary(&mut self, source: &FrontApp) -> Option<String> {
        let pid = source.pid?;
        focus::with_deadline(READ_DEADLINE, move || primary_owned_by(pid)).flatten()
    }

    fn copy(&mut self, source: &FrontApp) -> Option<String> {
        let _turn = COPY_QUEUE.lock();
        copy_selection(source, &mut LiveCopy::default())
    }
}

/// The app in front, unless it is LokalBot.
fn live_source() -> Option<FrontApp> {
    match focus::frontmost(FOCUS_DEADLINE)? {
        Frontmost::App(app) if !app.is_self() => Some(app),
        _ => None,
    }
}

/// What this desktop cannot do, worded for Settings.
pub fn limitation() -> Option<&'static str> {
    #[cfg(target_os = "linux")]
    if crate::session::is_wayland() {
        return Some(
            "On Wayland, add a shortcut in your desktop's keyboard settings that runs “lokalbot selection-actions”. LokalBot reads the selection from apps that share it through accessibility, or with Ctrl+C when “wtype” or “ydotool” is installed. It does not read the primary selection there, so text selected in a terminal is not seen.",
        );
    }
    None
}

/// True when LokalBot itself is the frontmost app, so a press keeps its panel.
pub fn lokalbot_is_frontmost() -> bool {
    matches!(
        focus::frontmost(FOCUS_DEADLINE),
        Some(Frontmost::App(app)) if app.is_self()
    )
}

/// What the keystroke copy needs, so it can be tested without a clipboard.
pub trait CopyHost {
    /// The app is in front and its focused field is not a secure one.
    fn is_allowed(&mut self, source: &FrontApp) -> bool;
    /// Saves the clipboard and starts watching it.
    fn begin(&mut self);
    /// `Ok(false)`: the keystroke could not be sent.
    fn post_copy(&mut self, source: &FrontApp) -> bool;
    fn changed(&mut self) -> bool;
    /// The clipboard's text, unless it is marked concealed.
    fn read_text(&mut self) -> Option<String>;
    /// Puts back what `begin` saved.
    fn restore(&mut self);
    fn wait(&mut self, duration: Duration);
    fn now(&mut self) -> Instant {
        Instant::now()
    }
}

/// The copy from `SelectionClipboardCopy`. The app's own copy may be recorded
/// by a clipboard manager, as any copy the person makes would be. A newer
/// clipboard change is not ours to restore.
pub fn copy_selection(source: &FrontApp, host: &mut dyn CopyHost) -> Option<String> {
    if !host.is_allowed(source) {
        return None;
    }
    host.begin();
    if !host.is_allowed(source) || !host.post_copy(source) {
        return None;
    }
    let deadline = host.now() + COPY_TIMEOUT;
    let mut changed = false;
    while host.now() < deadline {
        if host.changed() {
            changed = true;
            break;
        }
        host.wait(COPY_POLL);
    }
    // Nothing selected: the app copied nothing and the clipboard is untouched.
    if !changed {
        return None;
    }
    // Re-checked after the app handled Copy: a changed app or secure field is
    // never read.
    let text = if host.is_allowed(source) {
        host.read_text()
    } else {
        None
    };
    if !host.changed() {
        host.restore();
    }
    text
}

/// One copy at a time: a second press waits for the first to restore.
static COPY_QUEUE: parking_lot::Mutex<()> = parking_lot::Mutex::new(());

#[derive(Default)]
struct LiveCopy {
    saved: Option<crate::insert::ClipboardSnapshot>,
    watch: Option<crate::screen::ClipboardWatch>,
    /// Without a watch (Wayland): the text the clipboard held before.
    before: Option<String>,
}

impl CopyHost for LiveCopy {
    fn is_allowed(&mut self, source: &FrontApp) -> bool {
        matches!(
            focus::read_focus(FOCUS_DEADLINE),
            FocusRead::Snapshot(snapshot)
                if snapshot.front.same_app(source) && !snapshot.secure && !snapshot.front.is_self()
        )
    }

    fn begin(&mut self) {
        let saved = crate::insert::snapshot_clipboard();
        self.watch = crate::screen::ClipboardWatch::new();
        self.before = self.watch.is_none().then(|| saved.text()).flatten();
        self.saved = Some(saved);
    }

    fn post_copy(&mut self, source: &FrontApp) -> bool {
        crate::insert::send_copy(&source.app_name, &source.app_id).unwrap_or_else(|err| {
            log::debug!("copy keystroke failed: {err:#}");
            false
        })
    }

    fn changed(&mut self) -> bool {
        match self.watch.as_mut() {
            Some(watch) => watch.changed(),
            None => crate::insert::clipboard_text().is_some_and(|now| {
                let changed = self.before.as_deref() != Some(now.as_str());
                if changed {
                    self.before = Some(now);
                }
                changed
            }),
        }
    }

    fn read_text(&mut self) -> Option<String> {
        if clipboard_is_concealed() {
            return None;
        }
        crate::insert::clipboard_text()
    }

    fn restore(&mut self) {
        if let Some(saved) = self.saved.take() {
            crate::insert::restore_clipboard(saved);
        }
    }

    fn wait(&mut self, duration: Duration) {
        std::thread::sleep(duration);
    }
}

/// A password manager's copy carries a marker; such an item is never read.
fn clipboard_is_concealed() -> bool {
    #[cfg(windows)]
    {
        use windows::Win32::System::DataExchange::{
            IsClipboardFormatAvailable, RegisterClipboardFormatW,
        };
        use windows::core::w;
        // SAFETY: a constant, NUL-terminated format name; no clipboard is opened.
        unsafe {
            let format =
                RegisterClipboardFormatW(w!("ExcludeClipboardContentFromMonitorProcessing"));
            format != 0 && IsClipboardFormatAvailable(format).is_ok()
        }
    }
    #[cfg(target_os = "linux")]
    {
        linux::clipboard_is_concealed()
    }
    #[cfg(not(any(windows, target_os = "linux")))]
    {
        false
    }
}

/// The primary selection, when `pid` owns it. X11 only.
fn primary_owned_by(pid: u32) -> Option<String> {
    #[cfg(target_os = "linux")]
    {
        linux::primary_owned_by(pid)
    }
    #[cfg(not(target_os = "linux"))]
    {
        let _ = pid;
        None
    }
}

#[cfg(target_os = "linux")]
mod linux {
    use std::time::{Duration, Instant};

    use x11rb::connection::Connection;
    use x11rb::protocol::Event;
    use x11rb::protocol::res::{ClientIdMask, ClientIdSpec, ConnectionExt as _};
    use x11rb::protocol::xproto::{
        Atom, AtomEnum, ConnectionExt as _, CreateWindowAux, WindowClass,
    };
    use x11rb::rust_connection::RustConnection;

    /// KeePassXC and others mark what they copy with this target.
    const CONCEALED: &[u8] = b"x-kde-passwordManagerHint";
    const TARGETS_WAIT: Duration = Duration::from_millis(150);

    fn connect() -> Option<(RustConnection, u32)> {
        if crate::session::desktop() != crate::session::Desktop::X11 {
            return None;
        }
        let (conn, screen) = x11rb::connect(None).ok()?;
        let root = conn.setup().roots.get(screen)?.root;
        Some((conn, root))
    }

    fn owner_pid(conn: &RustConnection, selection: Atom) -> Option<u32> {
        let owner = conn
            .get_selection_owner(selection)
            .ok()?
            .reply()
            .ok()?
            .owner;
        if owner == x11rb::NONE {
            return None;
        }
        let spec = ClientIdSpec {
            client: owner,
            mask: ClientIdMask::LOCAL_CLIENT_PID,
        };
        conn.res_query_client_ids(&[spec])
            .ok()?
            .reply()
            .ok()?
            .ids
            .iter()
            .find(|id| id.spec.mask.contains(ClientIdMask::LOCAL_CLIENT_PID))
            .and_then(|id| id.value.first().copied())
    }

    /// Whether a selection's owner offers the concealed target. An owner that
    /// does not answer in time offers nothing we know of.
    fn offers_concealed(conn: &RustConnection, root: u32, selection: Atom) -> Option<bool> {
        let concealed = conn.intern_atom(true, CONCEALED).ok()?.reply().ok()?.atom;
        if concealed == x11rb::NONE {
            return Some(false);
        }
        let targets = conn.intern_atom(false, b"TARGETS").ok()?.reply().ok()?.atom;
        let property = conn
            .intern_atom(false, b"LOKALBOT_TARGETS")
            .ok()?
            .reply()
            .ok()?
            .atom;
        let window = conn.generate_id().ok()?;
        conn.create_window(
            0,
            window,
            root,
            0,
            0,
            1,
            1,
            0,
            WindowClass::INPUT_ONLY,
            0,
            &CreateWindowAux::new(),
        )
        .ok()?;
        conn.convert_selection(window, selection, targets, property, x11rb::CURRENT_TIME)
            .ok()?;
        conn.flush().ok()?;
        let deadline = Instant::now() + TARGETS_WAIT;
        while Instant::now() < deadline {
            match conn.poll_for_event().ok()? {
                Some(Event::SelectionNotify(notify)) if notify.requestor == window => {
                    if notify.property == x11rb::NONE {
                        return Some(false);
                    }
                    let reply = conn
                        .get_property(false, window, property, AtomEnum::ATOM, 0, 1_024)
                        .ok()?
                        .reply()
                        .ok()?;
                    return Some(
                        reply
                            .value32()
                            .is_some_and(|mut atoms| atoms.any(|atom| atom == concealed)),
                    );
                }
                Some(_) => {}
                None => std::thread::sleep(Duration::from_millis(5)),
            }
        }
        Some(false)
    }

    pub(super) fn primary_owned_by(pid: u32) -> Option<String> {
        let (conn, root) = connect()?;
        let primary: Atom = AtomEnum::PRIMARY.into();
        if owner_pid(&conn, primary) != Some(pid) {
            return None;
        }
        if offers_concealed(&conn, root, primary).unwrap_or(false) {
            return None;
        }
        let text = crate::insert::primary_text()?;
        // It must still be that app's selection once the text is in hand.
        (owner_pid(&conn, primary) == Some(pid)).then_some(text)
    }

    pub(super) fn clipboard_is_concealed() -> bool {
        if let Some((conn, root)) = connect() {
            let Some(clipboard) = conn
                .intern_atom(false, b"CLIPBOARD")
                .ok()
                .and_then(|cookie| cookie.reply().ok())
                .map(|reply| reply.atom)
            else {
                return false;
            };
            return offers_concealed(&conn, root, clipboard).unwrap_or(false);
        }
        // Wayland: wl-clipboard can list what the source offers.
        let Some(program) = crate::process::find_program("wl-paste") else {
            return false;
        };
        let mut command = std::process::Command::new(program);
        command.arg("--list-types");
        crate::process::output_with_timeout(command, Duration::from_millis(300)).is_ok_and(
            |output| {
                String::from_utf8_lossy(&output.stdout)
                    .lines()
                    .any(|line| line.trim().as_bytes() == CONCEALED)
            },
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn app(id: &str) -> FrontApp {
        FrontApp {
            pid: Some(7),
            app_name: id.into(),
            app_id: id.into(),
            window: Some(1),
            title: String::new(),
        }
    }

    fn field(front: &FrontApp, identity: Option<&str>) -> FocusSnapshot {
        FocusSnapshot {
            front: front.clone(),
            field_pid: front.pid,
            identity: identity.map(str::to_string),
            accessible: true,
            ..FocusSnapshot::default()
        }
    }

    struct Fake {
        source: Option<FrontApp>,
        moved_after: Option<usize>,
        checks: usize,
        focus: FocusRead,
        read: SelectionRead,
        primary: Option<String>,
        copy: Option<String>,
        calls: Vec<&'static str>,
    }

    impl Fake {
        fn new(front: &FrontApp, identity: Option<&str>) -> Self {
            Self {
                source: Some(front.clone()),
                moved_after: None,
                checks: 0,
                focus: FocusRead::Snapshot(field(front, identity)),
                read: SelectionRead::Unavailable,
                primary: None,
                copy: None,
                calls: Vec::new(),
            }
        }
    }

    impl CaptureHost for Fake {
        fn source(&mut self) -> Option<FrontApp> {
            self.checks += 1;
            if self.moved_after.is_some_and(|limit| self.checks > limit) {
                return Some(app("other"));
            }
            self.source.clone()
        }
        fn focus(&mut self) -> FocusRead {
            self.calls.push("focus");
            self.focus.clone()
        }
        fn read(&mut self, _: &FrontApp) -> SelectionRead {
            self.calls.push("read");
            self.read.clone()
        }
        fn primary(&mut self, _: &FrontApp) -> Option<String> {
            self.calls.push("primary");
            self.primary.clone()
        }
        fn copy(&mut self, _: &FrontApp) -> Option<String> {
            self.calls.push("copy");
            self.copy.clone()
        }
    }

    #[test]
    fn nothing_in_front_reads_nothing() {
        let mut host = Fake::new(&app("editor"), None);
        host.source = None;
        assert_eq!(capture_with(&mut host, &[]), SelectionCapture::default());
        assert!(host.calls.is_empty());
    }

    #[test]
    fn excluded_apps_and_password_managers_are_never_read() {
        let mut host = Fake::new(&app("Slack"), Some("a"));
        let result = capture_with(&mut host, &["slack".to_string()]);
        assert_eq!(result.issue, Some(SelectionIssue::ExcludedApp));
        assert!(host.calls.is_empty());
        let mut host = Fake::new(&app("KeePassXC"), Some("a"));
        let result = capture_with(&mut host, &[]);
        assert_eq!(result.issue, Some(SelectionIssue::ExcludedApp));
        assert!(host.calls.is_empty());
    }

    #[test]
    fn a_secure_field_stops_before_any_read() {
        let front = app("editor");
        let mut host = Fake::new(&front, None);
        let mut snapshot = field(&front, None);
        snapshot.secure = true;
        host.focus = FocusRead::Snapshot(snapshot);
        let result = capture_with(&mut host, &[]);
        assert_eq!(result.issue, Some(SelectionIssue::SecureField));
        assert_eq!(host.calls, ["focus"]);
        assert_eq!(result.target, None);
    }

    #[test]
    fn a_timed_out_or_moved_focus_is_refused() {
        let front = app("editor");
        let mut host = Fake::new(&front, Some("a"));
        host.focus = FocusRead::TimedOut;
        assert_eq!(
            capture_with(&mut host, &[]).issue,
            Some(SelectionIssue::FocusChanged)
        );
        let mut host = Fake::new(&front, Some("a"));
        host.focus = FocusRead::Snapshot(field(&app("other"), Some("a")));
        assert_eq!(
            capture_with(&mut host, &[]).issue,
            Some(SelectionIssue::FocusChanged)
        );
        let mut host = Fake::new(&front, Some("a"));
        host.moved_after = Some(2);
        let result = capture_with(&mut host, &[]);
        assert_eq!(result.issue, Some(SelectionIssue::FocusChanged));
        assert_eq!(result.text, "");
    }

    #[test]
    fn accessibility_comes_first_and_binds_the_field() {
        let front = app("editor");
        let mut host = Fake::new(&front, Some("a"));
        host.read = SelectionRead::Text("hello".into());
        host.primary = Some("stale".into());
        let result = capture_with(&mut host, &[]);
        assert_eq!(result.text, "hello");
        assert!(result.can_insert() && !result.read_through_clipboard);
        assert_eq!(host.calls, ["focus", "read"]);
    }

    #[test]
    fn an_empty_field_skips_the_primary_selection() {
        let front = app("editor");
        let mut host = Fake::new(&front, Some("a"));
        host.read = SelectionRead::Empty;
        host.primary = Some("stale".into());
        host.copy = Some("copied".into());
        let result = capture_with(&mut host, &[]);
        assert_eq!(result.text, "copied");
        assert!(result.read_through_clipboard);
        assert_eq!(host.calls, ["focus", "read", "copy"]);
    }

    #[test]
    fn apps_without_accessibility_use_primary_then_copy_and_stay_copy_only() {
        let front = app("electron-app");
        let mut host = Fake::new(&front, None);
        host.primary = Some("from primary".into());
        host.copy = Some("copied".into());
        let result = capture_with(&mut host, &[]);
        assert_eq!(result.text, "from primary");
        assert!(!result.can_insert(), "no field identity, so copy only");
        assert_eq!(host.calls, ["focus", "read", "primary"]);
        let mut host = Fake::new(&front, None);
        host.copy = Some("copied".into());
        let result = capture_with(&mut host, &[]);
        assert_eq!(result.text, "copied");
        assert!(result.read_through_clipboard);
    }

    #[test]
    fn terminals_never_get_a_copy_keystroke() {
        let front = app("gnome-terminal-server");
        let mut host = Fake::new(&front, None);
        host.copy = Some("must not happen".into());
        host.primary = Some("selected in the terminal".into());
        let result = capture_with(&mut host, &[]);
        assert_eq!(result.text, "selected in the terminal");
        assert!(!host.calls.contains(&"copy"));

        let mut host = Fake::new(&front, None);
        host.copy = Some("must not happen".into());
        let result = capture_with(&mut host, &[]);
        assert_eq!(result.text, "");
        assert!(!host.calls.contains(&"copy"));

        // A terminal widget in an app that is not itself a terminal.
        let front = app("ide");
        let mut host = Fake::new(&front, None);
        let mut snapshot = field(&front, None);
        snapshot.terminal = true;
        host.focus = FocusRead::Snapshot(snapshot);
        host.copy = Some("must not happen".into());
        capture_with(&mut host, &[]);
        assert!(!host.calls.contains(&"copy"));
    }

    #[test]
    fn long_selections_are_kept_up_to_the_limit() {
        let front = app("editor");
        let mut host = Fake::new(&front, Some("a"));
        host.read = SelectionRead::Text("a".repeat(MAX_CHARACTERS + 10));
        let result = capture_with(&mut host, &[]);
        assert_eq!(result.text.chars().count(), MAX_CHARACTERS);
    }

    struct FakeCopy {
        front: bool,
        moves_after_copy: bool,
        changes_after: Option<usize>,
        polls: usize,
        second_change: bool,
        text: Option<String>,
        calls: Vec<&'static str>,
        now: Instant,
    }

    impl FakeCopy {
        fn new() -> Self {
            Self {
                front: true,
                moves_after_copy: false,
                changes_after: Some(2),
                polls: 0,
                second_change: false,
                text: Some("copied".into()),
                calls: Vec::new(),
                now: Instant::now(),
            }
        }
    }

    impl CopyHost for FakeCopy {
        fn is_allowed(&mut self, _: &FrontApp) -> bool {
            self.front
        }
        fn begin(&mut self) {
            self.calls.push("begin");
        }
        fn post_copy(&mut self, _: &FrontApp) -> bool {
            self.calls.push("post");
            if self.moves_after_copy {
                self.front = false;
            }
            true
        }
        fn changed(&mut self) -> bool {
            self.polls += 1;
            match self.changes_after {
                Some(after) if self.polls == after + 1 => true,
                Some(after) if self.polls > after + 1 => self.second_change,
                _ => false,
            }
        }
        fn read_text(&mut self) -> Option<String> {
            self.calls.push("read");
            self.text.clone()
        }
        fn restore(&mut self) {
            self.calls.push("restore");
        }
        fn wait(&mut self, duration: Duration) {
            self.now += duration;
        }
        fn now(&mut self) -> Instant {
            self.now
        }
    }

    #[test]
    fn the_copy_reads_then_restores() {
        let mut host = FakeCopy::new();
        assert_eq!(
            copy_selection(&app("editor"), &mut host).as_deref(),
            Some("copied")
        );
        assert_eq!(host.calls, ["begin", "post", "read", "restore"]);
    }

    #[test]
    fn nothing_copied_leaves_the_clipboard_untouched() {
        let mut host = FakeCopy::new();
        host.changes_after = None;
        assert_eq!(copy_selection(&app("editor"), &mut host), None);
        assert_eq!(host.calls, ["begin", "post"]);
    }

    #[test]
    fn focus_moving_during_the_copy_reads_nothing_but_still_restores() {
        let mut host = FakeCopy::new();
        host.moves_after_copy = true;
        assert_eq!(copy_selection(&app("editor"), &mut host), None);
        assert_eq!(host.calls, ["begin", "post", "restore"]);
    }

    #[test]
    fn a_newer_clipboard_change_is_not_ours_to_restore() {
        let mut host = FakeCopy::new();
        host.second_change = true;
        assert!(copy_selection(&app("editor"), &mut host).is_some());
        assert_eq!(host.calls, ["begin", "post", "read"]);
    }

    #[test]
    fn no_copy_without_the_app_in_front() {
        let mut host = FakeCopy::new();
        host.front = false;
        assert_eq!(copy_selection(&app("editor"), &mut host), None);
        assert!(host.calls.is_empty());
    }
}
