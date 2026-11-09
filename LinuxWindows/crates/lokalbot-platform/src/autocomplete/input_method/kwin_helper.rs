//! The input method KWin starts for LokalBot (`lokalbot --kwin-input-method`),
//! once the user chooses LokalBot under System Settings → Keyboard → Virtual
//! Keyboard.
//!
//! KWin offers `zwp_input_method_v1` only to the program it started, over the
//! connection it handed it, and starts it again only if it crashes. So this
//! small process holds that connection for the whole session and passes the
//! active field to the app over the socket in [`super::kwin_wire`]. The app's
//! route ([`super::kwin`]) does everything else.
//!
//! The keyboard is taken only while the app shows a suggestion. Then every key
//! but the accept keys and Esc goes straight back to KWin, and nothing keeps
//! it. With no app connected this holds no text, takes no keys and shows
//! nothing, so typing is as it is without an input method. Typed text is never
//! logged.

use std::collections::HashSet;
use std::os::fd::{AsRawFd as _, RawFd};
use std::os::unix::fs::{FileTypeExt as _, PermissionsExt as _};
use std::os::unix::net::{UnixListener, UnixStream};

use anyhow::{Context as _, bail};
use wayland_client::backend::WaylandError;
use wayland_client::globals::{GlobalListContents, registry_queue_init};
use wayland_client::protocol::{wl_keyboard, wl_registry};
use wayland_client::{Connection, Dispatch, QueueHandle, WEnum, event_created_child};
use wayland_protocols::wp::input_method::zv1::client::{
    zwp_input_method_context_v1::{self, ZwpInputMethodContextV1},
    zwp_input_method_v1::{self, ZwpInputMethodV1},
};

use super::super::AcceptKeys;
use super::kwin_wire::{self, Event, Inbox, Outbox, Request, Surrounding, VERSION};
use super::wlroots::{Keymap, Modifiers, clipped};

const KEY_RELEASED: u32 = 0;
const KEY_PRESSED: u32 = 1;
const KEY_REPEATED: u32 = 2;

/// Runs the helper until KWin closes its connection. The exit code is never
/// a crash's, so KWin does not start it again in a loop.
pub(crate) fn run() -> i32 {
    if std::env::var_os("WAYLAND_SOCKET").is_none() {
        eprintln!(
            "lokalbot: --kwin-input-method is started by KDE Plasma. To use it, choose LokalBot in System Settings, Keyboard, Virtual Keyboard."
        );
        return 2;
    }
    match serve() {
        Ok(()) => 0,
        Err(err) => {
            log::warn!("kwin input method: {err:#}");
            1
        }
    }
}

fn serve() -> anyhow::Result<()> {
    let conn = Connection::connect_to_env().context("KWin gave no connection")?;
    let (globals, mut queue) = registry_queue_init::<Helper>(&conn)?;
    let qh = queue.handle();
    let input_method: ZwpInputMethodV1 = globals
        .bind(&qh, 1..=1, ())
        .context("KWin offered no input method protocol")?;
    let path = kwin_wire::socket_path()?;
    let listener = listen(&path)?;
    log::info!("kwin input method: ready");
    let mut helper = Helper {
        qh,
        _input_method: input_method,
        context: None,
        serial: 0,
        content: None,
        pending: Pending::default(),
        keyboard: None,
        wants_grab: false,
        keymap: None,
        modifiers: Modifiers::default(),
        taken: HashSet::new(),
        last_key: (0, 0),
        accept: AcceptKeys::default(),
        shown: false,
        app: None,
    };
    let result = (|| -> anyhow::Result<()> {
        loop {
            helper.accept(&listener);
            helper.read_app();
            queue
                .dispatch_pending(&mut helper)
                .context("the input method connection failed")?;
            helper.deliver_pending();
            match conn.flush() {
                Ok(()) | Err(WaylandError::Io(_)) => {}
                Err(err) => bail!("lost the connection to KWin: {err}"),
            }
            helper.flush_app();
            let Some(guard) = queue.prepare_read() else {
                continue;
            };
            let app_fd = helper.app.as_ref().map(|app| app.stream.as_raw_fd());
            let app_writes = helper
                .app
                .as_ref()
                .is_some_and(|app| !app.outbox.is_empty());
            let mut fds = vec![
                pollfd(guard.connection_fd().as_raw_fd(), libc::POLLIN),
                pollfd(listener.as_raw_fd(), libc::POLLIN),
            ];
            if let Some(fd) = app_fd {
                let mut events = libc::POLLIN;
                if app_writes {
                    events |= libc::POLLOUT;
                }
                fds.push(pollfd(fd, events));
            }
            // SAFETY: `fds` is a valid array for its length, for the whole call.
            let ready = unsafe { libc::poll(fds.as_mut_ptr(), fds.len() as libc::nfds_t, -1) };
            if ready < 0
                && std::io::Error::last_os_error().kind() != std::io::ErrorKind::Interrupted
            {
                bail!("could not wait for KWin");
            }
            if fds[0].revents != 0 {
                match guard.read() {
                    Ok(_) => {}
                    Err(WaylandError::Io(err)) if err.kind() == std::io::ErrorKind::WouldBlock => {}
                    Err(err) => bail!("lost the connection to KWin: {err}"),
                }
            } else {
                drop(guard);
            }
        }
    })();
    helper.drop_app();
    let _ = std::fs::remove_file(&path);
    result
}

fn pollfd(fd: RawFd, events: libc::c_short) -> libc::pollfd {
    libc::pollfd {
        fd,
        events,
        revents: 0,
    }
}

/// Listens where the app looks. A socket left by a helper that is gone is
/// replaced; anything else in the way is not touched.
fn listen(path: &std::path::Path) -> anyhow::Result<UnixListener> {
    match std::fs::symlink_metadata(path) {
        Ok(meta) if meta.file_type().is_socket() => {
            let _ = std::fs::remove_file(path);
        }
        Ok(_) => bail!("{} is in the way", path.display()),
        Err(_) => {}
    }
    let listener = UnixListener::bind(path)
        .with_context(|| format!("could not listen at {}", path.display()))?;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
    listener.set_nonblocking(true)?;
    Ok(listener)
}

/// Whether the other end of `stream` runs as this user.
fn same_user(stream: &UnixStream) -> bool {
    let mut cred = libc::ucred {
        pid: 0,
        uid: u32::MAX,
        gid: u32::MAX,
    };
    let mut len = std::mem::size_of::<libc::ucred>() as libc::socklen_t;
    // SAFETY: `cred` and `len` are valid for writes of the sizes given.
    let got = unsafe {
        libc::getsockopt(
            stream.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            (&mut cred as *mut libc::ucred).cast(),
            &mut len,
        )
    };
    // SAFETY: getuid cannot fail.
    got == 0 && cred.uid == unsafe { libc::getuid() }
}

/// `zwp_text_input_v1`'s content purpose, as KWin sends it to an input
/// method, in `zwp_text_input_v3`'s numbering, which the rest of the route
/// uses. The hint bits are the same in both.
pub(super) fn content_v3(purpose: u32, hint: u32) -> (u32, u32) {
    let purpose = match purpose {
        // normal, alpha, digits, number, phone, url, email, name, password
        0..=8 => purpose,
        // date, time, datetime, terminal: v3 has `pin` at 9
        9..=12 => purpose + 1,
        // Unknown: never prose.
        _ => u32::MAX,
    };
    (purpose, hint)
}

/// Field state seen since it was last passed on.
#[derive(Default)]
struct Pending {
    /// The field went away.
    left: bool,
    /// A field has focus, or the one in focus may be another now.
    field: bool,
    content: Option<(u32, u32)>,
    surrounding: Option<Surrounding>,
}

struct App {
    stream: UnixStream,
    inbox: Inbox,
    outbox: Outbox,
    /// The app wants text from around the caret.
    reading: bool,
}

struct Helper {
    qh: QueueHandle<Helper>,
    _input_method: ZwpInputMethodV1,
    context: Option<ZwpInputMethodContextV1>,
    /// The serial of the field's last committed state, which requests quote.
    serial: u32,
    /// The active field's content type, for an app that connects later.
    content: Option<(u32, u32)>,
    pending: Pending,
    keyboard: Option<wl_keyboard::WlKeyboard>,
    wants_grab: bool,
    keymap: Option<Keymap>,
    modifiers: Modifiers,
    /// Keys taken and still down: their release and repeats go nowhere.
    taken: HashSet<u32>,
    /// The serial and time of the last key, for keys typed on the app's behalf.
    last_key: (u32, u32),
    accept: AcceptKeys,
    /// A suggestion is in the field.
    shown: bool,
    app: Option<App>,
}

impl Helper {
    fn send(&mut self, event: &Event) {
        if let Some(app) = &mut self.app {
            app.outbox.push(event);
        }
    }

    fn accept(&mut self, listener: &UnixListener) {
        loop {
            match listener.accept() {
                Ok((stream, _)) => {
                    if !same_user(&stream) || stream.set_nonblocking(true).is_err() {
                        continue;
                    }
                    // One app at a time: the newest is the one still running.
                    self.drop_app();
                    log::info!("kwin input method: LokalBot connected");
                    self.app = Some(App {
                        stream,
                        inbox: Inbox::default(),
                        outbox: Outbox::default(),
                        reading: false,
                    });
                    self.send(&Event::Hello { version: VERSION });
                    if self.context.is_some() {
                        self.send(&Event::Field);
                        let content = self.content;
                        self.send(&Event::State {
                            content,
                            surrounding: None,
                        });
                    }
                }
                Err(err) if err.kind() == std::io::ErrorKind::Interrupted => {}
                Err(_) => break,
            }
        }
    }

    /// Back to typing as if there were no input method.
    fn drop_app(&mut self) {
        let Some(mut app) = self.app.take() else {
            return;
        };
        app.inbox.clear();
        app.outbox.clear();
        log::info!("kwin input method: LokalBot disconnected");
        self.set_grab(false);
        if self.shown {
            self.show("");
        }
        self.accept = AcceptKeys::default();
        self.pending.surrounding = None;
    }

    fn read_app(&mut self) {
        let Some(app) = &mut self.app else {
            return;
        };
        if !matches!(app.inbox.fill(&mut app.stream), Ok(true)) {
            self.drop_app();
            return;
        }
        loop {
            let Some(app) = &mut self.app else {
                return;
            };
            match app.inbox.next::<Request>() {
                None => return,
                Some(Ok(request)) => self.request(request),
                Some(Err(err)) => {
                    log::warn!("kwin input method: unreadable request: {err}");
                    self.drop_app();
                    return;
                }
            }
        }
    }

    fn flush_app(&mut self) {
        let Some(app) = &mut self.app else {
            return;
        };
        if app.outbox.flush(&mut app.stream).is_err() {
            self.drop_app();
        }
    }

    fn request(&mut self, request: Request) {
        match request {
            Request::Hello { version } => {
                if version != VERSION {
                    log::warn!(
                        "kwin input method: LokalBot speaks version {version}, this helper {VERSION}"
                    );
                    self.drop_app();
                }
            }
            Request::Reading { on } => {
                if let Some(app) = &mut self.app {
                    app.reading = on;
                }
                if !on {
                    self.pending.surrounding = None;
                }
            }
            Request::Keys { accept, full } => self.accept = kwin_wire::accept_keys(accept, full),
            Request::Grab { on } => self.set_grab(on),
            Request::Preedit { text } => self.show(&text),
            Request::Commit {
                delete_before,
                delete_after,
                text,
                preedit,
            } => {
                let Some(context) = &self.context else {
                    return;
                };
                if delete_before > 0 || delete_after > 0 {
                    // KWin applies a deletion of [index, index + length]
                    // around the caret at once.
                    let index = -i32::try_from(delete_before).unwrap_or(i32::MAX);
                    context.delete_surrounding_text(index, delete_before + delete_after);
                }
                if !text.is_empty() {
                    context.commit_string(self.serial, clipped(&text).to_string());
                }
                self.show(&preedit);
            }
            Request::PassThrough { key } => {
                let scancode = self
                    .keymap
                    .as_ref()
                    .and_then(|keymap| keymap.scancode(key.into()));
                if let (Some(context), Some(scancode)) = (&self.context, scancode) {
                    let (serial, time) = self.last_key;
                    context.key(serial, time, scancode, KEY_PRESSED);
                    context.key(serial, time, scancode, KEY_RELEASED);
                }
            }
        }
    }

    /// Shows `text` in the field, in front of the caret's way. Empty clears it,
    /// which also prompts a quiet field to report its text.
    fn show(&mut self, text: &str) {
        let Some(context) = &self.context else {
            return;
        };
        // The caret stays where the user is typing, before the suggestion.
        context.preedit_cursor(0);
        // Nothing to commit if the field loses focus: a suggestion is not text.
        context.preedit_string(self.serial, clipped(text).to_string(), String::new());
        self.shown = !text.is_empty();
    }

    fn set_grab(&mut self, on: bool) {
        self.wants_grab = on;
        if !on {
            self.end_grab();
        } else if self.keyboard.is_none()
            && let Some(context) = &self.context
        {
            self.keyboard = Some(context.grab_keyboard(&self.qh, ()));
        }
    }

    fn end_grab(&mut self) {
        self.taken.clear();
        if let Some(keyboard) = self.keyboard.take() {
            keyboard.release();
        }
    }

    fn deliver_pending(&mut self) {
        let pending = std::mem::take(&mut self.pending);
        let Some(app) = &self.app else {
            return;
        };
        let surrounding = pending.surrounding.filter(|_| app.reading);
        if pending.left {
            self.send(&Event::NoField);
        }
        if pending.field {
            self.send(&Event::Field);
        }
        if pending.content.is_some() || surrounding.is_some() {
            self.send(&Event::State {
                content: pending.content,
                surrounding,
            });
        }
    }

    fn on_key(&mut self, serial: u32, time: u32, scancode: u32, state: u32) {
        self.last_key = (serial, time);
        let Some(context) = self.context.clone() else {
            return;
        };
        match state {
            KEY_PRESSED => {
                let bound = self
                    .keymap
                    .as_ref()
                    .and_then(|keymap| keymap.key(scancode))
                    .filter(|key| self.accept.takes(*key));
                if self.wants_grab
                    && self.app.is_some()
                    && self.modifiers.plain()
                    && let Some(key) = bound
                {
                    self.taken.insert(scancode);
                    self.send(&Event::Key { key: key.into() });
                    return;
                }
                let is_modifier = self
                    .keymap
                    .as_ref()
                    .is_some_and(|keymap| keymap.modifiers.contains(&scancode));
                if !is_modifier && self.shown {
                    // Toolkits may commit preedit when a key arrives, so the
                    // suggestion leaves first. The app puts it back if it
                    // still applies.
                    self.show("");
                    self.send(&Event::Passed);
                }
                context.key(serial, time, scancode, KEY_PRESSED);
            }
            KEY_RELEASED => {
                if !self.taken.remove(&scancode) {
                    context.key(serial, time, scancode, KEY_RELEASED);
                }
            }
            KEY_REPEATED if !self.taken.contains(&scancode) => {
                context.key(serial, time, scancode, KEY_REPEATED);
            }
            _ => {}
        }
    }
}

impl Dispatch<wl_registry::WlRegistry, GlobalListContents> for Helper {
    fn event(
        _: &mut Self,
        _: &wl_registry::WlRegistry,
        _: wl_registry::Event,
        _: &GlobalListContents,
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
    }
}

impl Dispatch<ZwpInputMethodV1, ()> for Helper {
    fn event(
        state: &mut Self,
        _: &ZwpInputMethodV1,
        event: zwp_input_method_v1::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        log::debug!(
            "kwin input method: {}",
            match &event {
                zwp_input_method_v1::Event::Activate { .. } => "activate",
                zwp_input_method_v1::Event::Deactivate { .. } => "deactivate",
                _ => "other",
            }
        );
        match event {
            zwp_input_method_v1::Event::Activate { id } => {
                if let Some(old) = state.context.replace(id) {
                    old.destroy();
                }
                state.content = None;
                state.shown = false;
                state.pending.field = true;
            }
            zwp_input_method_v1::Event::Deactivate { context } => {
                if state.context.as_ref() != Some(&context) {
                    context.destroy();
                    return;
                }
                state.end_grab();
                state.context = None;
                context.destroy();
                state.content = None;
                state.shown = false;
                // A field that came and went before it was passed on never was.
                state.pending = Pending {
                    left: true,
                    ..Pending::default()
                };
            }
            _ => {}
        }
    }

    event_created_child!(Helper, ZwpInputMethodV1, [
        zwp_input_method_v1::EVT_ACTIVATE_OPCODE => (ZwpInputMethodContextV1, ()),
    ]);
}

impl Dispatch<ZwpInputMethodContextV1, ()> for Helper {
    fn event(
        state: &mut Self,
        context: &ZwpInputMethodContextV1,
        event: zwp_input_method_context_v1::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        if state.context.as_ref() != Some(context) {
            return;
        }
        use zwp_input_method_context_v1::Event as E;
        // The kind of event only: never the text.
        log::debug!(
            "kwin input method: {}",
            match &event {
                E::SurroundingText { .. } => "surrounding text",
                E::Reset => "reset",
                E::ContentType { .. } => "content type",
                E::CommitState { .. } => "commit state",
                E::InvokeAction { .. } => "invoke action",
                E::PreferredLanguage { .. } => "preferred language",
                _ => "other",
            }
        );
        match event {
            E::SurroundingText {
                text,
                cursor,
                anchor,
            } => {
                // Held only until passed on, and only for an app that reads.
                if state.app.as_ref().is_some_and(|app| app.reading) {
                    state.pending.surrounding = Some(Surrounding {
                        text,
                        cursor,
                        anchor,
                    });
                }
            }
            // Moving to another field or window deactivates and activates the
            // context. A text input enabled again resets it, which may also be
            // another field, so the app asks again whose it is. The content
            // type comes with most keystrokes and says nothing about that.
            E::Reset => {
                state.shown = false;
                state.pending.field = true;
            }
            E::ContentType { hint, purpose } => {
                let content = content_v3(purpose, hint);
                state.content = Some(content);
                state.pending.content = Some(content);
            }
            E::CommitState { serial } => state.serial = serial,
            _ => {}
        }
    }
}

impl Dispatch<wl_keyboard::WlKeyboard, ()> for Helper {
    fn event(
        state: &mut Self,
        keyboard: &wl_keyboard::WlKeyboard,
        event: wl_keyboard::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        if state.keyboard.as_ref() != Some(keyboard) {
            return;
        }
        match event {
            wl_keyboard::Event::Keymap { format, fd, size } => {
                if format == WEnum::Value(wl_keyboard::KeymapFormat::XkbV1) {
                    match Keymap::read(&fd, size as usize) {
                        Ok(keymap) => state.keymap = Some(keymap),
                        Err(err) => {
                            log::warn!("kwin input method: {err:#}");
                            state.keymap = None;
                        }
                    }
                }
            }
            wl_keyboard::Event::Key {
                serial,
                time,
                key,
                state: pressed,
            } => {
                let pressed = match pressed {
                    WEnum::Value(value) => value.into(),
                    WEnum::Unknown(raw) => raw,
                };
                state.on_key(serial, time, key, pressed);
            }
            wl_keyboard::Event::Modifiers {
                serial,
                mods_depressed,
                mods_latched,
                mods_locked,
                group,
            } => {
                state.modifiers = Modifiers {
                    depressed: mods_depressed,
                    latched: mods_latched,
                    locked: mods_locked,
                    group,
                };
                if let Some(context) = &state.context {
                    context.modifiers(serial, mods_depressed, mods_latched, mods_locked, group);
                }
            }
            _ => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn content_purposes_from_text_input_v1_land_on_v3s_numbers() {
        // v1 password (8) is v3 password (8); v3 inserted `pin` at 9.
        assert_eq!(content_v3(8, 0xc0), (8, 0xc0));
        assert_eq!(content_v3(0, 0x200), (0, 0x200));
        assert_eq!(content_v3(9, 0), (10, 0), "date");
        assert_eq!(content_v3(12, 0), (13, 0), "terminal");
        assert_eq!(content_v3(40, 0).0, u32::MAX, "unknown is not prose");
    }

    #[test]
    fn a_stale_socket_is_replaced_and_anything_else_is_left_alone() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join(kwin_wire::SOCKET_NAME);
        let first = listen(&path).unwrap();
        drop(first);
        // The socket file outlives the helper that made it.
        assert!(path.exists());
        let _second = listen(&path).unwrap();
        let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);

        let other = dir.path().join("plain-file");
        std::fs::write(&other, "keep me").unwrap();
        assert!(listen(&other).is_err());
        assert_eq!(std::fs::read_to_string(&other).unwrap(), "keep me");
    }

    #[test]
    fn this_users_own_connection_counts_as_the_same_user() {
        let (a, _b) = UnixStream::pair().unwrap();
        assert!(same_user(&a));
    }
}
