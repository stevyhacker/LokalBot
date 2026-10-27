// Contains code ported from Cotabby (https://github.com/FuJacob/cotabby),
// copyright the Cotabby authors, under the GNU AGPL v3.0
// (LICENSES/AGPL-3.0.txt). Modified for LokalBot since 18 October 2026.
// See THIRD_PARTY_NOTICES.md.

//! X11 for autocomplete: `XGrabKey` on Tab and Escape while ghost text shows
//! (`CotypingInputMonitor`'s consuming tap), the active window for matching a
//! focused field to its window, and moving LokalBot's ghost window.
//!
//! The grabs cover the Caps Lock and Num Lock variants, so the key is taken
//! whatever those locks say, and are released the moment the overlay hides.
//! While inactive the thread holds no grab and only waits for commands.

use std::sync::{Arc, LazyLock};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use anyhow::Context as _;
use crossbeam_channel::{Receiver, RecvTimeoutError, Sender, unbounded};
use parking_lot::{Condvar, Mutex};
use x11rb::connection::Connection;
use x11rb::protocol::Event;
use x11rb::protocol::randr::ConnectionExt as _;
use x11rb::protocol::shape::{self, ConnectionExt as _};
use x11rb::protocol::xproto::{
    AtomEnum, ClipOrdering, ConfigureWindowAux, ConnectionExt as _, GrabMode, ImageFormat, ModMask,
    StackMode, Window,
};
use x11rb::protocol::xtest::ConnectionExt as _;
use x11rb::rust_connection::RustConnection;
use x11rb::wrapper::ConnectionExt as _;

use super::geometry::Rect;
use super::{InterceptedKey, KeyHandler};

const XK_TAB: u32 = 0xff09;
const XK_ESCAPE: u32 = 0xff1b;
const XK_NUM_LOCK: u32 = 0xff7f;
pub(super) const XK_BACKSPACE: u32 = 0xff08;
pub(super) const XK_DELETE: u32 = 0xffff;

/// How often the grab thread looks for key events while it holds a grab.
const ACTIVE_POLL: Duration = Duration::from_millis(5);

enum Command {
    Active(bool),
    PassThrough(InterceptedKey),
    Stop,
}

/// Whether the grabbed Tab is still held. While it is, the keyboard is
/// grabbed by LokalBot, so XTest typing would come back to LokalBot instead
/// of reaching the app; the inserter waits for the release.
#[derive(Default)]
struct KeyHeld {
    down: Mutex<bool>,
    released: Condvar,
}

static HELD: LazyLock<Arc<KeyHeld>> = LazyLock::new(|| Arc::new(KeyHeld::default()));

/// Waits up to `timeout` for a grabbed key to come up.
pub(super) fn wait_for_grabbed_key_release(timeout: Duration) {
    let held = HELD.clone();
    let mut down = held.down.lock();
    let deadline = Instant::now() + timeout;
    while *down {
        if held.released.wait_until(&mut down, deadline).timed_out() {
            *down = false;
            break;
        }
    }
}

pub(super) struct Grabber {
    commands: Sender<Command>,
    thread: Option<JoinHandle<()>>,
}

impl Grabber {
    pub(super) fn start(handler: KeyHandler) -> anyhow::Result<Self> {
        let (conn, screen) = x11rb::connect(None).context("no X11 display")?;
        let root = conn
            .setup()
            .roots
            .get(screen)
            .context("the X server reported no screen")?
            .root;
        let keys = Keys::read(&conn)?;
        let (commands, receiver) = unbounded();
        let thread = std::thread::Builder::new()
            .name("lokalbot-autocomplete-keys".into())
            .spawn(move || run(conn, root, keys, receiver, handler))
            .context("could not start the key thread")?;
        Ok(Self {
            commands,
            thread: Some(thread),
        })
    }

    pub(super) fn set_active(&self, active: bool) {
        let _ = self.commands.send(Command::Active(active));
    }

    pub(super) fn pass_through(&self, key: InterceptedKey) {
        let _ = self.commands.send(Command::PassThrough(key));
    }
}

impl Drop for Grabber {
    fn drop(&mut self) {
        let _ = self.commands.send(Command::Stop);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

/// Keycodes and lock masks of this keyboard.
#[derive(Clone, Copy)]
struct Keys {
    tab: u8,
    escape: u8,
    num_lock: ModMask,
}

impl Keys {
    fn read(conn: &impl Connection) -> anyhow::Result<Self> {
        let tab = keycode(conn, XK_TAB)?.context("this keyboard has no Tab key")?;
        let escape = keycode(conn, XK_ESCAPE)?.context("this keyboard has no Escape key")?;
        Ok(Self {
            tab,
            escape,
            num_lock: num_lock_mask(conn)?,
        })
    }

    /// The modifier states a plain key press can come with: none, Caps Lock,
    /// Num Lock, or both.
    fn lock_variants(&self) -> [ModMask; 4] {
        [
            ModMask::from(0u16),
            ModMask::LOCK,
            self.num_lock,
            ModMask::LOCK | self.num_lock,
        ]
    }

    fn code(&self, key: InterceptedKey) -> u8 {
        match key {
            InterceptedKey::Tab => self.tab,
            InterceptedKey::Escape => self.escape,
        }
    }
}

pub(super) fn keycode(conn: &impl Connection, keysym: u32) -> anyhow::Result<Option<u8>> {
    let setup = conn.setup();
    let (min, max) = (setup.min_keycode, setup.max_keycode);
    let mapping = conn.get_keyboard_mapping(min, max - min + 1)?.reply()?;
    let per = usize::from(mapping.keysyms_per_keycode).max(1);
    Ok(mapping
        .keysyms
        .chunks(per)
        .position(|syms| syms.contains(&keysym))
        .and_then(|index| u8::try_from(usize::from(min) + index).ok()))
}

/// The modifier bit Num Lock is mapped to (usually Mod2).
fn num_lock_mask(conn: &impl Connection) -> anyhow::Result<ModMask> {
    let Some(num_lock) = keycode(conn, XK_NUM_LOCK)? else {
        return Ok(ModMask::M2);
    };
    let mapping = conn.get_modifier_mapping()?.reply()?;
    let per = usize::from(mapping.keycodes_per_modifier()).max(1);
    for (index, codes) in mapping.keycodes.chunks(per).enumerate() {
        if codes.contains(&num_lock) {
            return Ok(ModMask::from(1u16 << index));
        }
    }
    Ok(ModMask::M2)
}

fn grab(conn: &RustConnection, root: Window, keys: &Keys, code: u8) -> bool {
    let mut all = true;
    for modifiers in keys.lock_variants() {
        let result = conn
            .grab_key(
                false,
                root,
                modifiers,
                code,
                GrabMode::ASYNC,
                GrabMode::ASYNC,
            )
            .map_err(anyhow::Error::from)
            .and_then(|cookie| cookie.check().map_err(anyhow::Error::from));
        if let Err(err) = result {
            log::debug!("autocomplete: grabbing key {code} failed: {err}");
            all = false;
        }
    }
    all
}

fn ungrab(conn: &RustConnection, root: Window, keys: &Keys, code: u8) {
    for modifiers in keys.lock_variants() {
        let _ = conn.ungrab_key(code, root, modifiers);
    }
}

fn run(
    conn: RustConnection,
    root: Window,
    keys: Keys,
    commands: Receiver<Command>,
    handler: KeyHandler,
) {
    let mut active = false;
    loop {
        let command = if active {
            match commands.recv_timeout(ACTIVE_POLL) {
                Ok(command) => Some(command),
                Err(RecvTimeoutError::Timeout) => None,
                Err(RecvTimeoutError::Disconnected) => break,
            }
        } else {
            match commands.recv() {
                Ok(command) => Some(command),
                Err(_) => break,
            }
        };
        match command {
            Some(Command::Stop) => break,
            Some(Command::Active(on)) if on != active => {
                if on {
                    let taken =
                        grab(&conn, root, &keys, keys.tab) & grab(&conn, root, &keys, keys.escape);
                    if !taken {
                        log::warn!(
                            "autocomplete: another app holds Tab or Esc; accepting may not work"
                        );
                    }
                } else {
                    ungrab(&conn, root, &keys, keys.tab);
                    ungrab(&conn, root, &keys, keys.escape);
                    let _ = conn.ungrab_keyboard(x11rb::CURRENT_TIME);
                    release_held();
                }
                let _ = conn.flush();
                active = on;
            }
            Some(Command::Active(_)) => {}
            Some(Command::PassThrough(key)) => {
                let code = keys.code(key);
                // Out of the way first, or the replayed key would come back here.
                ungrab(&conn, root, &keys, code);
                let _ = conn.ungrab_keyboard(x11rb::CURRENT_TIME);
                release_held();
                let _ = conn.sync();
                const PRESS: u8 = x11rb::protocol::xproto::KEY_PRESS_EVENT;
                const RELEASE: u8 = x11rb::protocol::xproto::KEY_RELEASE_EVENT;
                for kind in [PRESS, RELEASE] {
                    let _ = conn.xtest_fake_input(kind, code, x11rb::CURRENT_TIME, root, 0, 0, 0);
                }
                let _ = conn.sync();
                if active {
                    grab(&conn, root, &keys, code);
                }
                let _ = conn.flush();
            }
            None => {}
        }
        if !active {
            continue;
        }
        loop {
            match conn.poll_for_event() {
                Ok(Some(Event::KeyPress(event))) => {
                    let key = if event.detail == keys.tab {
                        Some(InterceptedKey::Tab)
                    } else if event.detail == keys.escape {
                        Some(InterceptedKey::Escape)
                    } else {
                        None
                    };
                    if let Some(key) = key {
                        log::debug!("autocomplete: {key:?} held for the ghost");
                        *HELD.down.lock() = true;
                        handler(key);
                    }
                }
                Ok(Some(Event::KeyRelease(_))) => release_held(),
                Ok(Some(_)) => {}
                Ok(None) => break,
                Err(err) => {
                    log::warn!("autocomplete: lost the X connection for keys: {err}");
                    return;
                }
            }
        }
    }
    ungrab(&conn, root, &keys, keys.tab);
    ungrab(&conn, root, &keys, keys.escape);
    let _ = conn.flush();
}

fn release_held() {
    let mut down = HELD.down.lock();
    if *down {
        *down = false;
        HELD.released.notify_all();
    }
}

/// Sends `keysym` presses through XTest, for deleting around the caret
/// where the field cannot edit through AT-SPI.
pub(super) fn tap_keys(keysym: u32, count: usize) -> anyhow::Result<()> {
    if count == 0 {
        return Ok(());
    }
    let (conn, screen) = x11rb::connect(None).context("no X11 display")?;
    let root = conn
        .setup()
        .roots
        .get(screen)
        .context("no X11 screen")?
        .root;
    let code = keycode(&conn, keysym)?.context("the key is not on this keyboard")?;
    const PRESS: u8 = x11rb::protocol::xproto::KEY_PRESS_EVENT;
    const RELEASE: u8 = x11rb::protocol::xproto::KEY_RELEASE_EVENT;
    for _ in 0..count {
        conn.xtest_fake_input(PRESS, code, x11rb::CURRENT_TIME, root, 0, 0, 0)?;
        conn.xtest_fake_input(RELEASE, code, x11rb::CURRENT_TIME, root, 0, 0, 0)?;
    }
    conn.sync()?;
    Ok(())
}

/// The active window (`_NET_ACTIVE_WINDOW`) and what autocomplete needs of it.
#[derive(Clone, Debug, Default, PartialEq)]
pub(super) struct ActiveWindow {
    pub id: u32,
    pub pid: Option<u32>,
    pub class: Option<String>,
    pub instance: Option<String>,
    /// Its content in root coordinates, without the shadow a client-side
    /// decorated window (GTK) draws around itself (`_GTK_FRAME_EXTENTS`).
    pub frame: Option<Rect>,
}

/// One X connection for the watcher's reads, reopened after errors.
pub(super) struct Display {
    conn: Option<(RustConnection, Window)>,
    net_active_window: u32,
    net_wm_pid: u32,
    gtk_frame_extents: u32,
}

impl Display {
    pub(super) fn new() -> Self {
        Self {
            conn: None,
            net_active_window: 0,
            net_wm_pid: 0,
            gtk_frame_extents: 0,
        }
    }

    fn connection(&mut self) -> Option<&(RustConnection, Window)> {
        if self.conn.is_none() {
            let (conn, screen) = x11rb::connect(None).ok()?;
            let root = conn.setup().roots.get(screen)?.root;
            let intern = |name: &[u8]| -> Option<u32> {
                Some(conn.intern_atom(false, name).ok()?.reply().ok()?.atom)
            };
            self.net_active_window = intern(b"_NET_ACTIVE_WINDOW")?;
            self.net_wm_pid = intern(b"_NET_WM_PID")?;
            self.gtk_frame_extents = intern(b"_GTK_FRAME_EXTENTS")?;
            self.conn = Some((conn, root));
        }
        self.conn.as_ref()
    }

    pub(super) fn active_window(&mut self) -> Option<ActiveWindow> {
        // Interns the atoms on first use.
        self.connection()?;
        let net_active = self.net_active_window;
        let net_pid = self.net_wm_pid;
        let gtk_frame = self.gtk_frame_extents;
        let result = (|| -> anyhow::Result<Option<ActiveWindow>> {
            let Some((conn, root)) = self.connection() else {
                return Ok(None);
            };
            let reply = conn
                .get_property(false, *root, net_active, AtomEnum::WINDOW, 0, 1)?
                .reply()?;
            let Some(id) = reply
                .value32()
                .and_then(|mut v| v.next())
                .filter(|w| *w != 0)
            else {
                return Ok(None);
            };
            let pid = conn
                .get_property(false, id, net_pid, AtomEnum::CARDINAL, 0, 1)?
                .reply()
                .ok()
                .and_then(|r| r.value32().and_then(|mut v| v.next()))
                .filter(|pid| *pid != 0);
            let class = conn
                .get_property(false, id, AtomEnum::WM_CLASS, AtomEnum::STRING, 0, 256)?
                .reply()
                .ok();
            let (instance, class) = class
                .map(|reply| {
                    let mut parts = reply
                        .value
                        .split(|&b| b == 0)
                        .map(|p| String::from_utf8_lossy(p).into_owned());
                    let instance = parts.next().filter(|s| !s.is_empty());
                    (instance, parts.next().filter(|s| !s.is_empty()))
                })
                .unwrap_or((None, None));
            // Left, right, top, bottom.
            let shadow: Vec<u32> = conn
                .get_property(false, id, gtk_frame, AtomEnum::CARDINAL, 0, 4)?
                .reply()
                .ok()
                .and_then(|r| r.value32().map(Iterator::collect))
                .filter(|v: &Vec<u32>| v.len() == 4)
                .unwrap_or_else(|| vec![0; 4]);
            let frame = conn.get_geometry(id)?.reply().ok().and_then(|geometry| {
                let origin = conn
                    .translate_coordinates(id, *root, 0, 0)
                    .ok()?
                    .reply()
                    .ok()?;
                let inset = |v: u32| v.min(512) as f32;
                Some(Rect::new(
                    f32::from(origin.dst_x) + inset(shadow[0]),
                    f32::from(origin.dst_y) + inset(shadow[2]),
                    (f32::from(geometry.width) - inset(shadow[0]) - inset(shadow[1])).max(1.0),
                    (f32::from(geometry.height) - inset(shadow[2]) - inset(shadow[3])).max(1.0),
                ))
            });
            Ok(Some(ActiveWindow {
                id,
                pid,
                class,
                instance,
                frame,
            }))
        })();
        match result {
            Ok(window) => window,
            Err(err) => {
                log::debug!("autocomplete: active window: {err:#}");
                self.conn = None;
                None
            }
        }
    }
}

/// A connection for moving the ghost window, opened on first use.
static OVERLAY: LazyLock<Mutex<Option<RustConnection>>> = LazyLock::new(|| Mutex::new(None));

fn with_overlay_connection<T>(
    action: impl FnOnce(&RustConnection) -> anyhow::Result<T>,
) -> anyhow::Result<T> {
    let mut guard = OVERLAY.lock();
    if guard.is_none() {
        let (conn, _) = x11rb::connect(None).context("no X11 display")?;
        *guard = Some(conn);
    }
    let Some(conn) = guard.as_ref() else {
        anyhow::bail!("no X11 display");
    };
    let result = action(conn);
    if result.is_err() {
        *guard = None;
    }
    result
}

/// An empty input shape: clicks go to whatever is under the ghost.
pub(super) fn prepare_overlay(window: u32) -> anyhow::Result<()> {
    with_overlay_connection(|conn| {
        conn.shape_rectangles(
            shape::SO::SET,
            shape::SK::INPUT,
            ClipOrdering::UNSORTED,
            window,
            0,
            0,
            &[],
        )?;
        conn.flush()?;
        Ok(())
    })
}

pub(super) fn place_overlay(window: u32, frame: Option<Rect>) -> anyhow::Result<()> {
    with_overlay_connection(|conn| {
        match frame {
            Some(frame) => {
                let frame = frame.integral();
                conn.configure_window(
                    window,
                    &ConfigureWindowAux::new()
                        .x(frame.x as i32)
                        .y(frame.y as i32)
                        .width(frame.width.max(1.0) as u32)
                        .height(frame.height.max(1.0) as u32)
                        .stack_mode(StackMode::ABOVE),
                )?;
                conn.map_window(window)?;
            }
            None => {
                conn.unmap_window(window)?;
            }
        }
        conn.flush()?;
        Ok(())
    })
}

/// The monitor holding `rect` (RandR), else the whole screen.
pub(super) fn screen_containing(rect: &Rect) -> Option<Rect> {
    with_overlay_connection(|conn| {
        let root = &conn.setup().roots[0];
        let whole = Rect::new(
            0.0,
            0.0,
            f32::from(root.width_in_pixels),
            f32::from(root.height_in_pixels),
        );
        let x = rect.x;
        let y = rect.mid_y();
        let monitors = conn
            .randr_get_monitors(root.root, true)
            .ok()
            .and_then(|cookie| cookie.reply().ok());
        let found = monitors.and_then(|reply| {
            reply.monitors.iter().find_map(|m| {
                let frame = Rect::new(
                    f32::from(m.x),
                    f32::from(m.y),
                    f32::from(m.width),
                    f32::from(m.height),
                );
                frame.contains_point(x, y).then_some(frame)
            })
        });
        Ok(found.unwrap_or(whole))
    })
    .ok()
}

/// Mean luminance of a few pixels just right of `rect`.
pub(super) fn sample_luminance(rect: &Rect) -> Option<f32> {
    with_overlay_connection(|conn| {
        let root = conn.setup().roots[0].root;
        let x = (rect.right() + 2.0).max(0.0) as i16;
        let y = rect.mid_y().max(0.0) as i16;
        let image = conn
            .get_image(ImageFormat::Z_PIXMAP, root, x, y, 6, 2, !0)?
            .reply()?;
        anyhow::ensure!(image.depth >= 24, "unexpected screen depth {}", image.depth);
        // 32 bits per pixel, blue first.
        let pixels: Vec<f32> = image
            .data
            .as_chunks::<4>()
            .0
            .iter()
            .map(|[b, g, r, _]| {
                (0.114 * f32::from(*b) + 0.587 * f32::from(*g) + 0.299 * f32::from(*r)) / 255.0
            })
            .collect();
        anyhow::ensure!(!pixels.is_empty(), "no pixels");
        Ok(pixels.iter().sum::<f32>() / pixels.len() as f32)
    })
    .ok()
}
