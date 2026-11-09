//! Autocomplete's input method against a real compositor and real GTK fields,
//! ignored by default. Run it with `crates/lokalbot-platform/scripts/live-sway.sh`,
//! which also needs Python with GTK 3 (`gi`).
//!
//! The keyboard here is one virtual keyboard with a US keymap for the whole
//! run, so keys arrive with a physical keyboard's scancodes and without the new
//! device, and the focus events that go with it, that each `wtype` run makes.

#![cfg(target_os = "linux")]

use std::io::{BufRead as _, BufReader, Seek as _, Write as _};
use std::os::fd::AsFd as _;
use std::process::{Child, Command, Stdio};
use std::sync::mpsc::{Receiver, channel};
use std::time::{Duration, Instant};

use lokalbot_platform::autocomplete::{
    AcceptKeys, Capability, Edit, FieldSnapshot, FieldWatcher, FocusSnapshot, InterceptedKey,
    KeyInterceptor, ReadPolicy,
};
use wayland_client::globals::{GlobalListContents, registry_queue_init};
use wayland_client::protocol::{wl_registry, wl_seat};
use wayland_client::{Connection, Dispatch, EventQueue, QueueHandle, delegate_noop};
use wayland_protocols_misc::zwp_virtual_keyboard_v1::client::{
    zwp_virtual_keyboard_manager_v1::ZwpVirtualKeyboardManagerV1,
    zwp_virtual_keyboard_v1::ZwpVirtualKeyboardV1,
};
use xkbcommon::xkb;

const KEY_TAB: u32 = 15;
const KEY_ESC: u32 = 1;
const KEY_GRAVE: u32 = 41;

struct Keyboard {
    conn: Connection,
    queue: EventQueue<KeyboardState>,
    keyboard: ZwpVirtualKeyboardV1,
    time: u32,
}

struct KeyboardState;

impl Dispatch<wl_registry::WlRegistry, GlobalListContents> for KeyboardState {
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
delegate_noop!(KeyboardState: ignore wl_seat::WlSeat);
delegate_noop!(KeyboardState: ZwpVirtualKeyboardManagerV1);
delegate_noop!(KeyboardState: ZwpVirtualKeyboardV1);

impl Keyboard {
    fn new() -> Self {
        let conn = Connection::connect_to_env().unwrap();
        let (globals, mut queue) = registry_queue_init::<KeyboardState>(&conn).unwrap();
        let qh = queue.handle();
        let seat: wl_seat::WlSeat = globals.bind(&qh, 1..=1, ()).unwrap();
        let manager: ZwpVirtualKeyboardManagerV1 = globals.bind(&qh, 1..=1, ()).unwrap();
        let keyboard = manager.create_virtual_keyboard(&seat, &qh, ());
        let context = xkb::Context::new(xkb::CONTEXT_NO_FLAGS);
        let keymap = xkb::Keymap::new_from_names(
            &context,
            "",
            "",
            "us",
            "",
            None,
            xkb::KEYMAP_COMPILE_NO_FLAGS,
        )
        .expect("a US keymap");
        let text = keymap.get_as_string(xkb::KEYMAP_FORMAT_TEXT_V1);
        let mut file = tempfile::tempfile().unwrap();
        file.write_all(text.as_bytes()).unwrap();
        file.write_all(&[0]).unwrap();
        file.flush().unwrap();
        file.rewind().unwrap();
        keyboard.keymap(1, file.as_fd(), text.len() as u32 + 1);
        queue.roundtrip(&mut KeyboardState).unwrap();
        Self {
            conn,
            queue,
            keyboard,
            time: 1,
        }
    }

    fn tap(&mut self, scancode: u32) {
        self.keyboard.key(self.time, scancode, 1);
        self.time += 20;
        self.keyboard.key(self.time, scancode, 0);
        self.time += 20;
        self.queue.roundtrip(&mut KeyboardState).unwrap();
        self.conn.flush().unwrap();
    }

    fn type_letters(&mut self, letters: &str) {
        const ROWS: [(&str, u32); 3] = [("qwertyuiop", 16), ("asdfghjkl", 30), ("zxcvbnm", 44)];
        for letter in letters.chars() {
            let scancode = ROWS
                .iter()
                .find_map(|(row, start)| Some(start + row.find(letter)? as u32))
                .expect("a lowercase letter");
            self.tap(scancode);
            std::thread::sleep(Duration::from_millis(30));
        }
    }
}

/// One GTK field in a window of its own, which prints what happens to it.
struct GtkField {
    child: Child,
    lines: Receiver<String>,
}

const GTK_FIELD: &str = r#"
import sys, gi
gi.require_version('Gtk', '3.0')
from gi.repository import Gtk
entry = Gtk.Entry()
if sys.argv[1] == 'password':
    entry.set_visibility(False)
    entry.set_input_purpose(Gtk.InputPurpose.PASSWORD)
    entry.connect('changed', lambda e: print('chars', len(e.get_text()), flush=True))
else:
    entry.connect('changed', lambda e: print('text', repr(e.get_text()), flush=True))
    entry.connect('preedit-changed', lambda e, p: print('preedit', repr(p), flush=True))
window = Gtk.Window(title='Field test')
window.add(entry)
window.connect('destroy', Gtk.main_quit)
window.show_all()
entry.grab_focus()
Gtk.main()
"#;

impl GtkField {
    fn start(kind: &str) -> Self {
        let mut child = Command::new("python3")
            .args(["-c", GTK_FIELD, kind])
            // Cargo points this at its build output, which GTK must not load from.
            .env_remove("LD_LIBRARY_PATH")
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .expect("python3 with GTK 3");
        let stdout = child.stdout.take().unwrap();
        let (tx, lines) = channel();
        std::thread::spawn(move || {
            for line in BufReader::new(stdout).lines().map_while(Result::ok) {
                let _ = tx.send(line);
            }
        });
        Self { child, lines }
    }

    /// Waits for a line, skipping others such as the same preedit again.
    fn expect(&self, wanted: &str) {
        let deadline = Instant::now() + Duration::from_secs(5);
        let mut seen = Vec::new();
        while let Ok(line) = self
            .lines
            .recv_timeout(deadline.saturating_duration_since(Instant::now()))
        {
            if line == wanted {
                return;
            }
            seen.push(line);
        }
        panic!("{wanted:?} never came; the field said {seen:?}");
    }
}

impl Drop for GtkField {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn field_where(
    focus: &Receiver<FocusSnapshot>,
    wait: Duration,
    wanted: impl Fn(&FieldSnapshot) -> bool,
) -> FieldSnapshot {
    let deadline = Instant::now() + wait;
    loop {
        let left = deadline.saturating_duration_since(Instant::now());
        let snapshot = focus.recv_timeout(left).expect("no such field in time");
        if let Some(field) = snapshot.field
            && wanted(&field)
        {
            return field;
        }
    }
}

#[test]
#[ignore]
fn sway_input_method_shows_accepts_and_stays_out_of_passwords() {
    let _ = env_logger::builder().is_test(false).try_init();
    let (focus_tx, focus) = channel();
    let (key_tx, keys_taken) = channel();
    // Sway focuses a text field only once the seat has a keyboard.
    let mut keyboard = Keyboard::new();
    let field = GtkField::start("plain");
    let policy = ReadPolicy {
        enabled: true,
        ..ReadPolicy::default()
    };
    let watcher = FieldWatcher::start(policy, move |snapshot| {
        let _ = focus_tx.send(snapshot);
    })
    .unwrap();
    let ghost = watcher.inline_ghost().expect("Sway has an input method");
    let keys = KeyInterceptor::start(move |key| {
        let _ = key_tx.send(key);
    })
    .unwrap();
    keys.set_keys(AcceptKeys::default());
    // The seat is taken once the young session has settled.
    field_where(&focus, Duration::from_secs(40), |_| true);

    // Nothing is taken while no suggestion shows.
    keyboard.type_letters("hello");
    field.expect("text 'hello'");
    let typed = field_where(&focus, Duration::from_secs(5), |f| f.before == "hello");
    assert_eq!(keys_taken.try_recv().ok(), None);

    ghost.show(&typed, " up on it");
    keys.set_active(true);
    field.expect("preedit ' up on it'");
    std::thread::sleep(Duration::from_millis(200));

    // Tab is taken, and an accept goes in with what is left.
    keyboard.tap(KEY_TAB);
    assert_eq!(
        keys_taken.recv_timeout(Duration::from_secs(2)).unwrap(),
        InterceptedKey::Tab
    );
    let accept = Edit {
        text: " up".into(),
        ..Edit::default()
    };
    ghost.accept(&typed, &typed.before, &typed.after, &accept, " on it");
    field.expect("text 'hello up'");
    field.expect("preedit ' on it'");

    // Any other key goes on to the field, and the ghost steps aside for it.
    keyboard.type_letters("z");
    field.expect("text 'hello upz'");
    field.expect("preedit ' on it'");
    let advanced = field_where(&focus, Duration::from_secs(5), |f| f.before == "hello upz");
    assert_eq!(keys_taken.try_recv().ok(), None);

    // The key left of 1 and Esc are taken too.
    keyboard.tap(KEY_GRAVE);
    assert_eq!(
        keys_taken.recv_timeout(Duration::from_secs(2)).unwrap(),
        InterceptedKey::Backtick
    );
    keyboard.tap(KEY_ESC);
    assert_eq!(
        keys_taken.recv_timeout(Duration::from_secs(2)).unwrap(),
        InterceptedKey::Escape
    );
    ghost.show(&advanced, "");
    keys.set_active(false);
    field.expect("preedit ''");
    std::thread::sleep(Duration::from_millis(200));

    // With the suggestion gone the keyboard is the field's again.
    keyboard.tap(KEY_GRAVE);
    assert_eq!(
        keys_taken.recv_timeout(Duration::from_millis(300)).ok(),
        None
    );
    drop(field);

    // A password field is refused and nothing of it is reported.
    let password = GtkField::start("password");
    let deadline = Instant::now() + Duration::from_secs(10);
    let refused = loop {
        let left = deadline.saturating_duration_since(Instant::now());
        let snapshot = focus.recv_timeout(left).expect("the password field");
        if matches!(snapshot.capability, Capability::Blocked(_)) {
            break snapshot;
        }
    };
    assert_eq!(refused.field, None);
    keyboard.type_letters("secret");
    password.expect("chars 6");
    while let Ok(snapshot) = focus.recv_timeout(Duration::from_millis(300)) {
        assert_eq!(snapshot.field, None, "a password field was read");
    }
    drop(password);
    drop(keys);
    drop(watcher);
}

/// A keyboard under KWin, which offers no virtual keyboard protocol: keys go
/// in through its EIS endpoint, as a remote desktop session's do, so they take
/// the same path through KWin as a real keyboard's.
struct EisKeyboard {
    child: Child,
    stdin: std::process::ChildStdin,
    lines: Receiver<String>,
}

impl EisKeyboard {
    fn new() -> Self {
        let script = concat!(env!("CARGO_MANIFEST_DIR"), "/scripts/eis-keyboard.py");
        let mut child = Command::new("python3")
            .arg(script)
            .env_remove("LD_LIBRARY_PATH")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .expect("python3 with libei and PyGObject");
        let stdin = child.stdin.take().unwrap();
        let stdout = child.stdout.take().unwrap();
        let (tx, lines) = channel();
        std::thread::spawn(move || {
            for line in BufReader::new(stdout).lines().map_while(Result::ok) {
                let _ = tx.send(line);
            }
        });
        let keyboard = Self {
            child,
            stdin,
            lines,
        };
        keyboard.answer("ready");
        keyboard
    }

    fn answer(&self, wanted: &str) {
        let line = self
            .lines
            .recv_timeout(Duration::from_secs(20))
            .expect("the EIS keyboard answered");
        assert_eq!(line, wanted);
    }

    fn send(&mut self, command: &str) {
        writeln!(self.stdin, "{command}").unwrap();
        self.stdin.flush().unwrap();
        self.answer("ok");
    }

    fn tap(&mut self, scancode: u32) {
        self.send(&format!("tap {scancode}"));
    }

    fn type_letters(&mut self, letters: &str) {
        self.send(&format!("type {letters}"));
    }
}

impl Drop for EisKeyboard {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

#[test]
#[ignore]
fn kwin_input_method_shows_accepts_and_stays_out_of_passwords() {
    let _ = env_logger::builder().is_test(false).try_init();
    let (focus_tx, focus) = channel();
    let (key_tx, keys_taken) = channel();
    let mut keyboard = EisKeyboard::new();
    let field = GtkField::start("plain");
    let policy = ReadPolicy {
        enabled: true,
        ..ReadPolicy::default()
    };
    let watcher = FieldWatcher::start(policy, move |snapshot| {
        let _ = focus_tx.send(snapshot);
    })
    .unwrap();
    let ghost = watcher
        .inline_ghost()
        .expect("KDE Plasma has an input method");
    let keys = KeyInterceptor::start(move |key| {
        let _ = key_tx.send(key);
    })
    .unwrap();
    keys.set_keys(AcceptKeys::default());
    // Typing waits for the window to have focus.
    field_where(&focus, Duration::from_secs(20), |f| f.before.is_empty());

    // Nothing is taken while no suggestion shows.
    keyboard.type_letters("hello");
    field.expect("text 'hello'");
    let typed = field_where(&focus, Duration::from_secs(10), |f| f.before == "hello");
    assert_eq!(keys_taken.try_recv().ok(), None);

    ghost.show(&typed, " up on it");
    keys.set_active(true);
    field.expect("preedit ' up on it'");
    std::thread::sleep(Duration::from_millis(200));

    // Tab is taken, and an accept goes in with what is left.
    keyboard.tap(KEY_TAB);
    assert_eq!(
        keys_taken.recv_timeout(Duration::from_secs(2)).unwrap(),
        InterceptedKey::Tab
    );
    let accept = Edit {
        text: " up".into(),
        ..Edit::default()
    };
    ghost.accept(&typed, &typed.before, &typed.after, &accept, " on it");
    field.expect("text 'hello up'");
    field.expect("preedit ' on it'");

    // Any other key goes on to the field, and the ghost steps aside for it.
    keyboard.type_letters("z");
    field.expect("text 'hello upz'");
    field.expect("preedit ' on it'");
    let advanced = field_where(&focus, Duration::from_secs(5), |f| f.before == "hello upz");
    assert_eq!(keys_taken.try_recv().ok(), None);

    // A word typed after an accept deletes and replaces around the caret.
    let replace = Edit {
        text: "s".into(),
        backward: 1,
        ..Edit::default()
    };
    ghost.accept(&advanced, &advanced.before, &advanced.after, &replace, "");
    field.expect("text 'hello ups'");

    // The key left of 1 and Esc are taken too.
    let replaced = field_where(&focus, Duration::from_secs(5), |f| f.before == "hello ups");
    ghost.show(&replaced, " on it");
    field.expect("preedit ' on it'");
    keyboard.tap(KEY_GRAVE);
    assert_eq!(
        keys_taken.recv_timeout(Duration::from_secs(2)).unwrap(),
        InterceptedKey::Backtick
    );
    keyboard.tap(KEY_ESC);
    assert_eq!(
        keys_taken.recv_timeout(Duration::from_secs(2)).unwrap(),
        InterceptedKey::Escape
    );
    ghost.show(&replaced, "");
    keys.set_active(false);
    field.expect("preedit ''");
    std::thread::sleep(Duration::from_millis(200));

    // With the suggestion gone the keyboard is the field's again.
    keyboard.tap(KEY_GRAVE);
    assert_eq!(
        keys_taken.recv_timeout(Duration::from_millis(300)).ok(),
        None
    );
    drop(field);

    // A password field is refused and nothing of it is reported.
    let password = GtkField::start("password");
    let deadline = Instant::now() + Duration::from_secs(10);
    let refused = loop {
        let left = deadline.saturating_duration_since(Instant::now());
        let snapshot = focus.recv_timeout(left).expect("the password field");
        if matches!(snapshot.capability, Capability::Blocked(_)) {
            break snapshot;
        }
    };
    assert_eq!(refused.field, None);
    keyboard.type_letters("secret");
    password.expect("chars 6");
    while let Ok(snapshot) = focus.recv_timeout(Duration::from_millis(300)) {
        assert_eq!(snapshot.field, None, "a password field was read");
    }
    drop(password);

    // KWin names the app, so an excluded one is refused before its text is used.
    let field = GtkField::start("plain");
    let named = field_where(&focus, Duration::from_secs(20), |f| f.before.is_empty());
    assert!(!named.app_id.is_empty(), "KWin named no app");
    watcher.set_policy(ReadPolicy {
        enabled: true,
        excluded_apps: vec![named.app_id.clone()],
        ..ReadPolicy::default()
    });
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let left = deadline.saturating_duration_since(Instant::now());
        let snapshot = focus.recv_timeout(left).expect("the excluded app");
        if snapshot.field.is_none() && snapshot.app_id == named.app_id {
            break;
        }
    }
    keyboard.type_letters("nope");
    field.expect("text 'nope'");
    while let Ok(snapshot) = focus.recv_timeout(Duration::from_millis(300)) {
        assert_eq!(snapshot.field, None, "an excluded app was read");
    }
    watcher.set_policy(ReadPolicy {
        enabled: true,
        ..ReadPolicy::default()
    });
    drop(field);

    // Quitting LokalBot with a suggestion on show leaves the field as it was,
    // and typing goes on as without an input method.
    let field = GtkField::start("plain");
    field_where(&focus, Duration::from_secs(20), |f| f.before.is_empty());
    keyboard.type_letters("hi");
    field.expect("text 'hi'");
    let again = field_where(&focus, Duration::from_secs(10), |f| f.before == "hi");
    ghost.show(&again, " there");
    keys.set_active(true);
    field.expect("preedit ' there'");
    drop(keys);
    drop(ghost);
    drop(watcher);
    field.expect("preedit ''");
    // The full-accept key types its character again.
    keyboard.tap(KEY_GRAVE);
    field.expect("text 'hi`'");
}
