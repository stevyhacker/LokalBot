//! The input method on Sway and Hyprland: `zwp_input_method_v2`, plus
//! `zwp_virtual_keyboard_v1` for giving keys back.
//!
//! The keyboard is grabbed only while a suggestion shows. While it is, every
//! key but the accept keys and Esc goes straight on through the virtual
//! keyboard and nothing keeps it.
//!
//! A known input method starting later makes this route let go of the seat at
//! once and say why, as does the compositor reporting that someone else holds
//! it. It takes the seat again only when that other one has been gone for a
//! while. A session that has only just started gets a moment first, so that one
//! starting alongside LokalBot does not lose the seat to it.
//!
//! This thread does no blocking work: while the keyboard is grabbed, the
//! user's typing goes through it.

use std::collections::HashSet;
use std::fs::File;
use std::os::fd::{AsFd as _, AsRawFd as _, OwnedFd};
use std::os::unix::fs::FileExt as _;
use std::os::unix::net::UnixStream;
use std::sync::OnceLock;
use std::time::{Duration, Instant};

use anyhow::Context as _;
use crossbeam_channel::{Receiver, Sender};
use wayland_client::backend::WaylandError;
use wayland_client::globals::{GlobalList, GlobalListContents, registry_queue_init};
use wayland_client::protocol::{wl_keyboard, wl_registry, wl_seat};
use wayland_client::{Connection, Dispatch, EventQueue, QueueHandle, WEnum, delegate_noop};
use wayland_protocols_misc::zwp_input_method_v2::client::{
    zwp_input_method_keyboard_grab_v2::{self, ZwpInputMethodKeyboardGrabV2},
    zwp_input_method_manager_v2::ZwpInputMethodManagerV2,
    zwp_input_method_v2::{self, ZwpInputMethodV2},
};
use wayland_protocols_misc::zwp_virtual_keyboard_v1::client::{
    zwp_virtual_keyboard_manager_v1::ZwpVirtualKeyboardManagerV1,
    zwp_virtual_keyboard_v1::ZwpVirtualKeyboardV1,
};
use xkbcommon::xkb;

use super::super::policy::ReadPolicy;
use super::super::{AcceptKeys, FocusHandler, InterceptedKey};
use super::surface::{self, Request};
use super::{Command, Content, Core, Handle, Output, Surrounding};

/// How long the grab waits for keys still down once the ghost has gone.
const GRAB_RELEASE_LIMIT: Duration = Duration::from_secs(3);
/// Measured from the compositor's socket.
const SESSION_SETTLE: Duration = Duration::from_secs(20);
/// Scans with no other input method before taking the seat back.
const QUIET_SCANS_BEFORE_RETAKING: u32 = 3;
/// How long before asking again after the compositor said someone else holds
/// the seat, without knowing who.
const UNAVAILABLE_RETRY: Duration = Duration::from_secs(30);
/// `zwp_input_method_v2` carries strings below 4000 bytes.
const MAX_STRING: usize = 3990;
/// Keymaps larger than this are not keymaps.
const MAX_KEYMAP: usize = 8 * 1024 * 1024;

const KEY_RELEASED: u32 = 0;
const KEY_PRESSED: u32 = 1;

/// XKB keycodes are evdev scancodes plus this.
const XKB_OFFSET: u32 = 8;
/// `KEY_GRAVE`, the physical key left of 1.
pub(super) const EVDEV_GRAVE: u32 = 41;

/// Whether this compositor offers what the route needs. It cannot change
/// within a session, so it is asked once.
pub(super) fn offered_by_compositor() -> bool {
    static OFFERED: OnceLock<bool> = OnceLock::new();
    *OFFERED.get_or_init(|| {
        let offered = (|| -> anyhow::Result<bool> {
            let conn = Connection::connect_to_env()?;
            let (globals, _queue) = registry_queue_init::<Registry>(&conn)?;
            Ok(has_global::<ZwpInputMethodManagerV2>(&globals)
                && has_global::<ZwpVirtualKeyboardManagerV1>(&globals))
        })();
        offered.unwrap_or_else(|err| {
            log::debug!("autocomplete: could not ask the compositor: {err:#}");
            false
        })
    })
}

fn has_global<I: wayland_client::Proxy>(globals: &GlobalList) -> bool {
    let name = I::interface().name;
    globals
        .contents()
        .with_list(|list| list.iter().any(|global| global.interface == name))
}

struct Registry;

impl Dispatch<wl_registry::WlRegistry, GlobalListContents> for Registry {
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

pub(super) fn start(
    policy: ReadPolicy,
    handler: FocusHandler,
    handle: Handle,
    commands: Receiver<Command>,
    wake: UnixStream,
) -> anyhow::Result<std::thread::JoinHandle<()>> {
    let conn = Connection::connect_to_env().context("no Wayland display")?;
    let (globals, queue) = registry_queue_init::<State>(&conn)?;
    let qh = queue.handle();
    let seat: wl_seat::WlSeat = globals.bind(&qh, 1..=1, ()).context("no seat")?;
    let manager: ZwpInputMethodManagerV2 = globals
        .bind(&qh, 1..=1, ())
        .context("this compositor offers no input methods")?;
    let keyboards: ZwpVirtualKeyboardManagerV1 = globals
        .bind(&qh, 1..=1, ())
        .context("this compositor offers no virtual keyboards")?;
    let (requests, questions) = crossbeam_channel::unbounded();
    let answers = handle.clone();
    std::thread::Builder::new()
        .name("lokalbot-input-method-surface".into())
        .spawn(move || surface::run(questions, answers, true))
        .context("could not start the input method's reader")?;
    let core = Core::new(policy, handler, requests.clone(), handle.limitation.clone());
    let state = State {
        core,
        wayland: Wayland {
            qh: qh.clone(),
            seat,
            keyboards,
            input_method: None,
            virtual_keyboard: None,
            keyboard_has_keymap: false,
            grab: None,
            wants_grab: false,
            keymap: None,
            down: HashSet::new(),
            taken: HashSet::new(),
            modifiers: Modifiers::default(),
            last_time: 0,
            release_by: None,
            serial: 0,
            active: false,
        },
        manager,
        handle,
        requests,
        accept_keys: AcceptKeys::default(),
        pending: Pending::default(),
        seat_held: false,
        quiet_scans: QUIET_SCANS_BEFORE_RETAKING,
        retry_at: None,
        other: None,
    };
    std::thread::Builder::new()
        .name("lokalbot-input-method".into())
        .spawn(move || run(conn, queue, state, commands, wake))
        .context("could not start the input method")
}

fn run(
    conn: Connection,
    mut queue: EventQueue<State>,
    mut state: State,
    commands: Receiver<Command>,
    mut wake: UnixStream,
) {
    loop {
        while let Ok(command) = commands.try_recv() {
            if !state.command(command) {
                state.let_go_of_seat();
                let _ = state.requests.send(Request::Stop);
                let _ = conn.flush();
                return;
            }
        }
        state.tick(Instant::now());
        if let Err(err) = queue.dispatch_pending(&mut state) {
            log::warn!("autocomplete: the input method stopped: {err}");
            break;
        }
        match conn.flush() {
            Ok(()) | Err(WaylandError::Io(_)) => {}
            Err(err) => {
                log::warn!("autocomplete: lost the Wayland connection: {err}");
                break;
            }
        }
        let Some(guard) = queue.prepare_read() else {
            continue;
        };
        let timeout = state.poll_timeout(Instant::now());
        let mut fds = [
            libc::pollfd {
                fd: guard.connection_fd().as_raw_fd(),
                events: libc::POLLIN,
                revents: 0,
            },
            libc::pollfd {
                fd: wake.as_raw_fd(),
                events: libc::POLLIN,
                revents: 0,
            },
        ];
        // SAFETY: `fds` is a valid array for its length, for the whole call.
        let ready = unsafe { libc::poll(fds.as_mut_ptr(), fds.len() as libc::nfds_t, timeout) };
        if ready < 0 && std::io::Error::last_os_error().kind() != std::io::ErrorKind::Interrupted {
            log::warn!("autocomplete: could not wait for the desktop");
            break;
        }
        if fds[0].revents != 0 {
            match guard.read() {
                Ok(_) => {}
                Err(WaylandError::Io(err)) if err.kind() == std::io::ErrorKind::WouldBlock => {}
                Err(err) => {
                    log::warn!("autocomplete: lost the Wayland connection: {err}");
                    break;
                }
            }
        } else {
            drop(guard);
        }
        if fds[1].revents != 0 {
            use std::io::Read as _;
            let mut drain = [0u8; 64];
            while matches!(wake.read(&mut drain), Ok(n) if n > 0) {}
        }
    }
    let _ = state.requests.send(Request::Stop);
    state.core.set_limitation(Some(
        lokalbot_i18n::tr(
            "LokalBot lost its connection to the desktop, so autocomplete has stopped. Restart LokalBot to use it again.",
        )
        .into(),
    ));
    state.core.deliver_none();
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
struct Modifiers {
    depressed: u32,
    latched: u32,
    locked: u32,
    group: u32,
}

impl Modifiers {
    /// Caps Lock and Num Lock are locks, not held: a plain key stays plain.
    fn plain(&self) -> bool {
        self.depressed == 0 && self.latched == 0
    }
}

/// What the current keymap's keys mean to this route.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
struct Keymap {
    /// Scancodes for the keys that can be taken.
    tab: Option<u32>,
    escape: Option<u32>,
    right: Option<u32>,
    backtick: Option<u32>,
    modifiers: HashSet<u32>,
}

impl Keymap {
    /// Reads a keymap the compositor shared. Which keys are which depends on
    /// it (Caps Lock can be Escape), except the full-accept key, which is the
    /// physical key left of 1 whatever it types, like the Mac's key code 50.
    fn read(fd: &OwnedFd, size: usize) -> anyhow::Result<Self> {
        anyhow::ensure!(size <= MAX_KEYMAP, "implausibly large keymap");
        let file = File::from(fd.try_clone()?);
        let mut bytes = vec![0; size];
        file.read_exact_at(&mut bytes, 0)?;
        let end = bytes.iter().position(|b| *b == 0).unwrap_or(bytes.len());
        Self::parse(std::str::from_utf8(&bytes[..end])?)
    }

    fn parse(text: &str) -> anyhow::Result<Self> {
        let context = xkb::Context::new(xkb::CONTEXT_NO_FLAGS);
        let keymap = xkb::Keymap::new_from_string(
            &context,
            text.to_string(),
            xkb::KEYMAP_FORMAT_TEXT_V1,
            xkb::KEYMAP_COMPILE_NO_FLAGS,
        )
        .context("the compositor's keymap could not be read")?;
        let mut found = Self::default();
        let mut grave = None;
        let mut left_of_one_exists = false;
        keymap.key_for_each(|keymap, code| {
            let Some(sym) = keymap.key_get_syms_by_level(code, 0, 0).first().copied() else {
                return;
            };
            let Some(scancode) = code.raw().checked_sub(XKB_OFFSET) else {
                return;
            };
            if sym.is_modifier_key() {
                found.modifiers.insert(scancode);
            }
            match sym {
                xkb::Keysym::Tab => {
                    found.tab.get_or_insert(scancode);
                }
                xkb::Keysym::Escape => {
                    found.escape.get_or_insert(scancode);
                }
                xkb::Keysym::Right => {
                    found.right.get_or_insert(scancode);
                }
                xkb::Keysym::grave => {
                    grave.get_or_insert(scancode);
                }
                _ => {}
            }
            if scancode == EVDEV_GRAVE {
                left_of_one_exists = true;
            }
        });
        found.backtick = if left_of_one_exists {
            Some(EVDEV_GRAVE)
        } else {
            grave
        };
        Ok(found)
    }

    fn key(&self, scancode: u32) -> Option<InterceptedKey> {
        let scancode = Some(scancode);
        if scancode == self.tab {
            Some(InterceptedKey::Tab)
        } else if scancode == self.escape {
            Some(InterceptedKey::Escape)
        } else if scancode == self.right {
            Some(InterceptedKey::RightArrow)
        } else if scancode == self.backtick {
            Some(InterceptedKey::Backtick)
        } else {
            None
        }
    }

    fn scancode(&self, key: InterceptedKey) -> Option<u32> {
        match key {
            InterceptedKey::Tab => self.tab,
            InterceptedKey::Escape => self.escape,
            InterceptedKey::RightArrow => self.right,
            InterceptedKey::Backtick => self.backtick,
        }
    }
}

/// State set by events until the next `done`.
#[derive(Default)]
struct Pending {
    activated: Option<bool>,
    surrounding: Option<Surrounding>,
    content: Option<Content>,
}

/// The protocol objects and the keyboard they hand us.
struct Wayland {
    qh: QueueHandle<State>,
    seat: wl_seat::WlSeat,
    keyboards: ZwpVirtualKeyboardManagerV1,
    input_method: Option<ZwpInputMethodV2>,
    virtual_keyboard: Option<ZwpVirtualKeyboardV1>,
    keyboard_has_keymap: bool,
    grab: Option<ZwpInputMethodKeyboardGrabV2>,
    /// The app wants the keys, so a suggestion is on show.
    wants_grab: bool,
    keymap: Option<Keymap>,
    /// Keys given back and still down, by scancode.
    down: HashSet<u32>,
    /// Keys taken and still down: their release goes nowhere.
    taken: HashSet<u32>,
    modifiers: Modifiers,
    last_time: u32,
    release_by: Option<Instant>,
    /// Count of `done` events, which each commit quotes.
    serial: u32,
    active: bool,
}

impl Output for Wayland {
    fn preedit(&mut self, text: &str) {
        let Some(input_method) = &self.input_method else {
            return;
        };
        // The caret stays where the user is typing, in front of the ghost.
        input_method.set_preedit_string(clipped(text).to_string(), 0, 0);
        input_method.commit(self.serial);
    }

    fn commit(&mut self, removed_before: &str, removed_after: &str, text: &str, preedit: &str) {
        let Some(input_method) = &self.input_method else {
            return;
        };
        if !removed_before.is_empty() || !removed_after.is_empty() {
            input_method
                .delete_surrounding_text(removed_before.len() as u32, removed_after.len() as u32);
        }
        if !text.is_empty() {
            input_method.commit_string(clipped(text).to_string());
        }
        // Preedit does not last from one commit to the next.
        input_method.set_preedit_string(clipped(preedit).to_string(), 0, 0);
        input_method.commit(self.serial);
    }

    fn release_keys(&mut self) {
        self.wants_grab = false;
        self.end_grab();
    }
}

impl Wayland {
    fn set_grab(&mut self, wanted: bool) {
        self.wants_grab = wanted;
        if wanted {
            self.release_by = None;
            if self.grab.is_none()
                && self.active
                && let Some(input_method) = &self.input_method
            {
                if self.virtual_keyboard.is_none() {
                    self.virtual_keyboard = Some(self.keyboards.create_virtual_keyboard(
                        &self.seat,
                        &self.qh,
                        (),
                    ));
                    self.keyboard_has_keymap = false;
                }
                self.grab = Some(input_method.grab_keyboard(&self.qh, ()));
            }
        } else if self.down.is_empty() {
            self.end_grab();
        } else {
            // Keys still down keep repeating until they come up.
            self.release_by = Some(Instant::now() + GRAB_RELEASE_LIMIT);
        }
    }

    fn end_grab(&mut self) {
        self.release_by = None;
        self.taken.clear();
        let Some(grab) = self.grab.take() else {
            return;
        };
        if let Some(keyboard) = &self.virtual_keyboard
            && self.keyboard_has_keymap
        {
            for key in self.down.drain() {
                keyboard.key(self.last_time, key, KEY_RELEASED);
            }
            keyboard.modifiers(0, 0, self.modifiers.locked, self.modifiers.group);
        }
        self.down.clear();
        grab.release();
    }

    fn forward(&self, scancode: u32, state: u32) {
        if let Some(keyboard) = &self.virtual_keyboard
            && self.keyboard_has_keymap
        {
            keyboard.key(self.last_time, scancode, state);
        }
    }
}

struct State {
    core: Core,
    wayland: Wayland,
    manager: ZwpInputMethodManagerV2,
    handle: Handle,
    requests: Sender<Request>,
    accept_keys: AcceptKeys,
    pending: Pending,
    seat_held: bool,
    quiet_scans: u32,
    retry_at: Option<Instant>,
    /// The input method in the way, once known by name.
    other: Option<String>,
}

impl State {
    /// False to stop.
    fn command(&mut self, command: Command) -> bool {
        match self.core.command(command, &mut self.wayland) {
            None => {}
            Some(Command::Stop) => return false,
            Some(Command::Keys(keys)) => self.accept_keys = keys,
            Some(Command::Grab(wanted)) => self.wayland.set_grab(wanted),
            Some(Command::PassThrough(key)) => {
                if let Some(scancode) = self
                    .wayland
                    .keymap
                    .as_ref()
                    .and_then(|keymap| keymap.scancode(key))
                {
                    self.wayland.forward(scancode, KEY_PRESSED);
                    self.wayland.forward(scancode, KEY_RELEASED);
                }
            }
            Some(Command::Scanned(other)) => self.on_scanned(other),
            Some(_) => {}
        }
        true
    }

    fn tick(&mut self, now: Instant) {
        self.core.tick(now, &mut self.wayland);
        if self.wayland.release_by.is_some_and(|by| now >= by) {
            self.wayland.end_grab();
        }
        if self.retry_at.is_some_and(|at| now >= at) {
            self.retry_at = None;
            self.maybe_take_seat();
        }
    }

    /// Milliseconds until `tick` has work, or -1 for none.
    fn poll_timeout(&self, now: Instant) -> i32 {
        [
            self.core.next_deadline(),
            self.wayland.release_by,
            self.retry_at,
        ]
        .into_iter()
        .flatten()
        .min()
        .map_or(-1, |at| {
            i32::try_from(
                at.saturating_duration_since(now)
                    .as_millis()
                    .saturating_add(1),
            )
            .unwrap_or(i32::MAX)
        })
    }

    /// A scan found `other` running, or nothing.
    fn on_scanned(&mut self, other: Option<String>) {
        match other {
            Some(name) => {
                self.quiet_scans = 0;
                if self.seat_held {
                    log::info!(
                        "autocomplete: another input method started; letting go of the seat"
                    );
                    self.let_go_of_seat();
                }
                self.core
                    .set_limitation(Some(super::other_input_method_text(Some(&name))));
                self.other = Some(name);
            }
            None => {
                self.quiet_scans = self.quiet_scans.saturating_add(1);
                if self.other.take().is_some() {
                    self.core.set_limitation(None);
                }
                self.maybe_take_seat();
            }
        }
    }

    fn maybe_take_seat(&mut self) {
        if self.seat_held
            || self.quiet_scans < QUIET_SCANS_BEFORE_RETAKING
            || self.retry_at.is_some()
        {
            return;
        }
        if let Some(wait) = session_settle_left() {
            self.retry_at = Some(Instant::now() + wait);
            return;
        }
        log::debug!("autocomplete: taking the input method seat");
        self.wayland.input_method = Some(self.manager.get_input_method(
            &self.wayland.seat,
            &self.wayland.qh,
            (),
        ));
        self.seat_held = true;
        self.core.set_limitation(session_module_text());
    }

    /// Someone else holds the seat, or will: nothing of ours stays on it.
    fn let_go_of_seat(&mut self) {
        self.core.deactivate(&mut self.wayland);
        self.wayland.active = false;
        if let Some(keyboard) = self.wayland.virtual_keyboard.take() {
            keyboard.destroy();
        }
        self.wayland.keyboard_has_keymap = false;
        if let Some(input_method) = self.wayland.input_method.take() {
            input_method.destroy();
        }
        self.seat_held = false;
        self.pending = Pending::default();
    }

    fn apply_done(&mut self) {
        self.wayland.serial = self.wayland.serial.wrapping_add(1);
        let pending = std::mem::take(&mut self.pending);
        match pending.activated {
            Some(true) => {
                self.wayland.active = true;
                self.core.activate(&mut self.wayland);
                self.core.set_limitation(session_module_text());
            }
            Some(false) => {
                self.wayland.active = false;
                self.core.deactivate(&mut self.wayland);
                return;
            }
            None => {}
        }
        self.core
            .update(pending.content, pending.surrounding, &mut self.wayland);
    }

    fn on_key(&mut self, time: u32, scancode: u32, pressed: bool) {
        let wayland = &mut self.wayland;
        wayland.last_time = time;
        if !pressed {
            if wayland.taken.remove(&scancode) {
                return;
            }
            wayland.down.remove(&scancode);
            wayland.forward(scancode, KEY_RELEASED);
            if !wayland.wants_grab && wayland.down.is_empty() {
                wayland.end_grab();
            }
            return;
        }
        let bound = wayland
            .keymap
            .as_ref()
            .and_then(|keymap| keymap.key(scancode))
            .filter(|key| self.accept_keys.takes(*key));
        if wayland.wants_grab
            && wayland.modifiers.plain()
            && let Some(key) = bound
        {
            let handler = self.handle.keys.lock().clone();
            if let Some(handler) = handler {
                wayland.taken.insert(scancode);
                handler(key);
                return;
            }
        }
        let is_modifier = wayland
            .keymap
            .as_ref()
            .is_some_and(|keymap| keymap.modifiers.contains(&scancode));
        if !is_modifier {
            self.core.blank_for_key(wayland);
        }
        wayland.down.insert(scancode);
        wayland.forward(scancode, KEY_PRESSED);
    }
}

/// `text` cut to what the protocol carries.
fn clipped(text: &str) -> &str {
    if text.len() <= MAX_STRING {
        return text;
    }
    let mut end = MAX_STRING;
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    &text[..end]
}

/// How much longer to wait before taking the seat, while the session is new.
fn session_settle_left() -> Option<Duration> {
    let runtime = std::env::var_os("XDG_RUNTIME_DIR")?;
    let display = std::env::var_os("WAYLAND_DISPLAY")?;
    let socket = std::path::Path::new(&runtime).join(display);
    let age = std::fs::metadata(socket)
        .ok()?
        .modified()
        .ok()?
        .elapsed()
        .ok()?;
    SESSION_SETTLE.checked_sub(age)
}

fn session_module_text() -> Option<String> {
    super::module_override(|name| std::env::var(name).ok())
}

delegate_noop!(State: ignore wl_seat::WlSeat);
delegate_noop!(State: ZwpInputMethodManagerV2);
delegate_noop!(State: ZwpVirtualKeyboardManagerV1);
delegate_noop!(State: ZwpVirtualKeyboardV1);

impl Dispatch<wl_registry::WlRegistry, GlobalListContents> for State {
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

impl Dispatch<ZwpInputMethodV2, ()> for State {
    fn event(
        state: &mut Self,
        _: &ZwpInputMethodV2,
        event: zwp_input_method_v2::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        use zwp_input_method_v2::Event;
        match event {
            Event::Activate => {
                state.pending = Pending {
                    activated: Some(true),
                    ..Pending::default()
                };
            }
            Event::Deactivate => state.pending.activated = Some(false),
            Event::SurroundingText {
                text,
                cursor,
                anchor,
            } => {
                // A field already ruled out: its text is not even held.
                if !state.core.refuses_text() || state.pending.activated == Some(true) {
                    state.pending.surrounding = Some(Surrounding {
                        text,
                        cursor,
                        anchor,
                    });
                }
            }
            Event::ContentType { hint, purpose } => {
                state.pending.content = Some(Content {
                    purpose: u32::from(purpose),
                    hint: u32::from(hint),
                });
            }
            Event::Done => state.apply_done(),
            Event::Unavailable => {
                log::debug!("autocomplete: the compositor says another input method is running");
                state.let_go_of_seat();
                state.retry_at = Some(Instant::now() + UNAVAILABLE_RETRY);
                state
                    .core
                    .set_limitation(Some(super::other_input_method_text(state.other.as_deref())));
            }
            _ => {}
        }
    }
}

impl Dispatch<ZwpInputMethodKeyboardGrabV2, ()> for State {
    fn event(
        state: &mut Self,
        _: &ZwpInputMethodKeyboardGrabV2,
        event: zwp_input_method_keyboard_grab_v2::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        use zwp_input_method_keyboard_grab_v2::Event;
        match event {
            Event::Keymap { format, fd, size } => {
                if let Some(keyboard) = &state.wayland.virtual_keyboard {
                    keyboard.keymap(u32::from(format), fd.as_fd(), size);
                    state.wayland.keyboard_has_keymap = true;
                }
                if format == WEnum::Value(wl_keyboard::KeymapFormat::XkbV1) {
                    match Keymap::read(&fd, size as usize) {
                        Ok(keymap) => state.wayland.keymap = Some(keymap),
                        Err(err) => {
                            log::warn!("autocomplete: {err:#}");
                            state.wayland.keymap = None;
                        }
                    }
                }
            }
            Event::Key {
                time,
                key,
                state: pressed,
                ..
            } => {
                state.on_key(
                    time,
                    key,
                    pressed == WEnum::Value(wl_keyboard::KeyState::Pressed),
                );
            }
            Event::Modifiers {
                mods_depressed,
                mods_latched,
                mods_locked,
                group,
                ..
            } => {
                state.wayland.modifiers = Modifiers {
                    depressed: mods_depressed,
                    latched: mods_latched,
                    locked: mods_locked,
                    group,
                };
                if let Some(keyboard) = &state.wayland.virtual_keyboard
                    && state.wayland.keyboard_has_keymap
                {
                    keyboard.modifiers(mods_depressed, mods_latched, mods_locked, group);
                }
            }
            _ => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The core of what `xkbcomp` writes for a US layout, with Caps Lock as
    /// Escape, as `caps:escape` does.
    const KEYMAP: &str = r#"xkb_keymap {
xkb_keycodes "t" {
  minimum = 8; maximum = 255;
  <ESC> = 9; <TLDE> = 49; <TAB> = 23; <AD01> = 24; <LFSH> = 50; <CAPS> = 66; <RGHT> = 114;
};
xkb_types "t" {
  virtual_modifiers NumLock;
  type "ONE_LEVEL" { modifiers = none; level_name[Level1] = "Any"; };
  type "TWO_LEVEL" { modifiers = Shift; map[Shift] = Level2; level_name[Level1] = "Base"; level_name[Level2] = "Shift"; };
  type "ALPHABETIC" { modifiers = Shift+Lock; map[Shift] = Level2; map[Lock] = Level2; level_name[Level1] = "Base"; level_name[Level2] = "Caps"; };
};
xkb_compatibility "t" {
  interpret.useModMapMods = AnyLevel;
  interpret Any + Any { action = SetMods(modifiers=modMapMods); };
};
xkb_symbols "t" {
  key <ESC> { [ Escape ] };
  key <TLDE> { [ dead_circumflex ] };
  key <TAB> { [ Tab, ISO_Left_Tab ] };
  key <AD01> { [ q, Q ] };
  key <LFSH> { [ Shift_L ] };
  key <CAPS> { [ Escape ] };
  key <RGHT> { [ Right ] };
  modifier_map Shift { <LFSH> };
};
};"#;

    #[test]
    fn keys_are_read_from_the_keymap() {
        let keymap = Keymap::parse(KEYMAP).unwrap();
        // Scancodes are the keycodes above minus eight.
        assert_eq!(keymap.key(15), Some(InterceptedKey::Tab));
        assert_eq!(keymap.key(106), Some(InterceptedKey::RightArrow));
        assert_eq!(keymap.key(16), None, "q");
        assert_eq!(keymap.scancode(InterceptedKey::Tab), Some(15));
        // The physical key left of 1, though it types no backtick here.
        assert_eq!(keymap.key(41), Some(InterceptedKey::Backtick));
        assert!(keymap.modifiers.contains(&42), "Left Shift");
        assert!(!keymap.modifiers.contains(&16));
    }

    #[test]
    fn a_keymap_without_that_key_falls_back_to_the_backtick() {
        let moved = KEYMAP
            .replace("<TLDE> = 49;", "<TLDE> = 60;")
            .replace("[ dead_circumflex ]", "[ grave ]");
        let keymap = Keymap::parse(&moved).unwrap();
        assert_eq!(keymap.backtick, Some(52));
    }

    #[test]
    fn locks_leave_a_key_plain_and_held_modifiers_do_not() {
        let locked = Modifiers {
            locked: 0x12,
            ..Modifiers::default()
        };
        assert!(locked.plain());
        let shift = Modifiers {
            depressed: 1,
            ..Modifiers::default()
        };
        assert!(!shift.plain());
        let latched = Modifiers {
            latched: 1,
            ..Modifiers::default()
        };
        assert!(!latched.plain());
    }

    #[test]
    fn long_strings_are_cut_on_a_character_boundary() {
        assert_eq!(clipped("short"), "short");
        let long = "é".repeat(MAX_STRING);
        let cut = clipped(&long);
        assert!(cut.len() <= MAX_STRING);
        assert!(cut.chars().all(|c| c == 'é'));
    }
}
