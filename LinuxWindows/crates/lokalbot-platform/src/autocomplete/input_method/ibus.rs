//! The input method on GNOME: an IBus engine, spoken to over IBus's own D-Bus.
//!
//! GNOME has no input method protocol for ordinary apps. GNOME Shell runs IBus
//! itself and hands it every text field, so LokalBot takes part as one of its
//! engines, which the user chooses as an input source next to their layouts.
//! Their other input sources keep working, and nothing reaches this engine
//! unless it is the chosen one.
//!
//! While it is chosen the desktop asks it about every key press in a text field.
//! All it does with one is compare it to the accept keys while a suggestion
//! shows, and answer whether it was taken. Keys are neither kept nor logged.
//!
//! IBus finds engines through a component file read when it starts: packages
//! install one, and `lokalbot --ibus-component` prints it for other installs.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicU32, Ordering};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use anyhow::Context as _;
use crossbeam_channel::{Receiver, RecvTimeoutError, Sender};
use parking_lot::Mutex;
use zbus::blocking::Connection;
use zbus::object_server::SignalEmitter;
use zbus::zvariant::{OwnedObjectPath, Structure, Value};

use super::super::policy::ReadPolicy;
use super::super::{AcceptKeys, FocusHandler, InputSourceSteps, InterceptedKey};
use super::surface::{self, Request};
use super::{Command, Content, Core, Handle, Output, Surrounding, content, wlroots::EVDEV_GRAVE};

const COMPONENT: &str = "com.lokalbot.LokalBot.IBus";
const ENGINE: &str = "lokalbot";
const FACTORY_PATH: &str = "/org/freedesktop/IBus/Factory";
/// How often to look for IBus, and check it is still there.
const CHECK_EVERY: Duration = Duration::from_secs(3);
const CALL_TIMEOUT: Duration = Duration::from_secs(1);

/// `IBusModifierType`: the bit on a release.
const RELEASE_MASK: u32 = 1 << 30;
/// Shift, Control, Alt, Super, AltGr and the virtual Super, Hyper and Meta. Caps
/// Lock and Num Lock leave a key plain.
const HELD_MODIFIERS: u32 = 1 | (1 << 2) | (1 << 3) | (1 << 6) | (1 << 7) | (0b111 << 26);
/// `IBUS_ENGINE_PREEDIT_CLEAR`: focus leaving drops the ghost, never types it.
const PREEDIT_CLEAR: u32 = 0;

mod keysym {
    pub const TAB: u32 = 0xff09;
    pub const ESCAPE: u32 = 0xff1b;
    pub const RIGHT: u32 = 0xff53;
    pub const SHIFT_L: u32 = 0xffe1;
    pub const HYPER_R: u32 = 0xffee;
    pub const ISO_LEVEL3_SHIFT: u32 = 0xfe03;
    pub const CAPS_LOCK: u32 = 0xffe5;
    pub const NUM_LOCK: u32 = 0xff7f;
}

/// What IBus tells the engine, for the route's thread.
pub(in super::super) enum EngineEvent {
    FocusIn,
    FocusOut,
    Surrounding(Surrounding),
    ContentType {
        purpose: u32,
        hint: u32,
    },
    /// A key went on to the field while a ghost showed.
    KeyGivenBack,
}

/// The IBus content purposes that differ from `zwp_text_input_v3`'s, which
/// [`Content`] speaks, and its private hint.
fn content_from_ibus(purpose: u32, hint: u32) -> Content {
    const IBUS_PURPOSE_TERMINAL: u32 = 10;
    const IBUS_HINT_PRIVATE: u32 = 1 << 11;
    Content {
        purpose: if purpose == IBUS_PURPOSE_TERMINAL {
            content::PURPOSE_TERMINAL
        } else {
            purpose
        },
        hint: if hint & IBUS_HINT_PRIVATE != 0 {
            content::HINT_SENSITIVE_DATA
        } else {
            0
        },
    }
}

/// IBus counts in characters, and an accept deletes around the caret.
fn surrounding_from_ibus(text: String, cursor: u32, anchor: u32) -> Surrounding {
    let byte_at = |chars: u32| -> u32 {
        text.char_indices()
            .nth(chars as usize)
            .map_or(text.len(), |(index, _)| index) as u32
    };
    let (cursor, anchor) = (byte_at(cursor), byte_at(anchor));
    Surrounding {
        text,
        cursor,
        anchor,
    }
}

/// What the key handler needs without waiting on the route's thread.
#[derive(Default)]
struct Keys {
    wanted: bool,
    accept: AcceptKeys,
    /// Keys taken and still down, by keycode, with what passing one on needs.
    taken: HashMap<u32, TakenKey>,
    latest: Option<TakenKey>,
}

#[derive(Clone, Copy)]
struct TakenKey {
    key: InterceptedKey,
    keyval: u32,
    keycode: u32,
    state: u32,
}

/// The key a press means, by the rules the other routes follow: what the
/// keymap makes of it, except the physical key left of 1.
fn intercepted(keyval: u32, keycode: u32) -> Option<InterceptedKey> {
    match keyval {
        keysym::TAB => Some(InterceptedKey::Tab),
        keysym::ESCAPE => Some(InterceptedKey::Escape),
        keysym::RIGHT => Some(InterceptedKey::RightArrow),
        _ if keycode == EVDEV_GRAVE => Some(InterceptedKey::Backtick),
        _ => None,
    }
}

fn is_modifier_key(keyval: u32) -> bool {
    (keysym::SHIFT_L..=keysym::HYPER_R).contains(&keyval)
        || keyval == keysym::ISO_LEVEL3_SHIFT
        || keyval == keysym::CAPS_LOCK
        || keyval == keysym::NUM_LOCK
}

/// One press or release, answered from `keys` alone. `true` keeps it from the
/// field.
fn decide(keys: &mut Keys, keyval: u32, keycode: u32, state: u32) -> Decision {
    if state & RELEASE_MASK != 0 {
        return if keys.taken.remove(&keycode).is_some() {
            Decision::Keep
        } else {
            Decision::Pass
        };
    }
    if keys.wanted
        && state & HELD_MODIFIERS == 0
        && let Some(key) = intercepted(keyval, keycode).filter(|key| keys.accept.takes(*key))
    {
        let taken = TakenKey {
            key,
            keyval,
            keycode,
            state,
        };
        keys.taken.insert(keycode, taken);
        keys.latest = Some(taken);
        return Decision::Take(key);
    }
    if keys.wanted && !is_modifier_key(keyval) {
        return Decision::PassBlanking;
    }
    Decision::Pass
}

#[derive(Debug, PartialEq, Eq)]
enum Decision {
    /// It goes to the field.
    Pass,
    /// It goes to the field, and the ghost steps out of the way first.
    PassBlanking,
    /// An accept key or Esc: the app decides.
    Take(InterceptedKey),
    /// The release of a key that was taken.
    Keep,
}

/// One engine. IBus makes one per input context; GNOME Shell keeps a single
/// context for the whole desktop.
struct Engine {
    path: String,
    active: Arc<Mutex<Option<String>>>,
    keys: Arc<Mutex<Keys>>,
    handle: Handle,
}

impl Engine {
    fn send(&self, event: EngineEvent) {
        self.handle.send(Command::Engine(event));
    }

    /// GNOME Shell swaps the engine around password fields, so an old engine
    /// can hear this after a new one has focus.
    fn lost_focus(&self) {
        let mut active = self.active.lock();
        if active.as_deref() == Some(self.path.as_str()) {
            *active = None;
            drop(active);
            self.send(EngineEvent::FocusOut);
        }
    }
}

#[zbus::interface(name = "org.freedesktop.IBus.Engine")]
impl Engine {
    async fn process_key_event(
        &self,
        #[zbus(signal_emitter)] emitter: SignalEmitter<'_>,
        keyval: u32,
        keycode: u32,
        state: u32,
    ) -> bool {
        let decision = decide(&mut self.keys.lock(), keyval, keycode, state);
        match decision {
            Decision::Pass => false,
            Decision::Keep => true,
            Decision::PassBlanking => {
                // Before the answer, so the field never gets the key with the
                // ghost still in it.
                let _ =
                    Self::update_preedit_text(&emitter, text_value(""), 0, false, PREEDIT_CLEAR)
                        .await;
                self.send(EngineEvent::KeyGivenBack);
                false
            }
            Decision::Take(key) => {
                let handler = self.handle.keys.lock().clone();
                match handler {
                    Some(handler) => {
                        handler(key);
                        true
                    }
                    None => false,
                }
            }
        }
    }

    fn set_cursor_location(&self, _x: i32, _y: i32, _w: i32, _h: i32) {}

    fn set_capabilities(&self, _caps: u32) {}

    async fn focus_in(&self, #[zbus(signal_emitter)] emitter: SignalEmitter<'_>) {
        *self.active.lock() = Some(self.path.clone());
        self.send(EngineEvent::FocusIn);
        let _ = Self::require_surrounding_text(&emitter).await;
    }

    fn focus_out(&self) {
        self.lost_focus();
    }

    fn reset(&self) {}

    async fn enable(&self, #[zbus(signal_emitter)] emitter: SignalEmitter<'_>) {
        let _ = Self::require_surrounding_text(&emitter).await;
    }

    fn disable(&self) {
        self.lost_focus();
    }

    fn page_up(&self) {}

    fn page_down(&self) {}

    fn cursor_up(&self) {}

    fn cursor_down(&self) {}

    fn set_surrounding_text(&self, text: Value<'_>, cursor_pos: u32, anchor_pos: u32) {
        if let Some(text) = text_from_value(&text) {
            self.send(EngineEvent::Surrounding(surrounding_from_ibus(
                text, cursor_pos, anchor_pos,
            )));
        }
    }

    fn property_activate(&self, _name: &str, _state: u32) {}

    fn property_show(&self, _name: &str) {}

    fn property_hide(&self, _name: &str) {}

    fn candidate_clicked(&self, _index: u32, _button: u32, _state: u32) {}

    fn process_hand_writing_event(&self, _coordinates: Vec<f64>) {}

    fn cancel_hand_writing(&self, _strokes: u32) {}

    fn panel_extension_received(&self, _event: Value<'_>) {}

    fn panel_extension_register_keys(&self, _data: Value<'_>) {}

    #[zbus(property)]
    fn focus_id(&self) -> (bool,) {
        (false,)
    }

    #[zbus(property)]
    fn active_surrounding_text(&self) -> (bool,) {
        (true,)
    }

    #[zbus(property)]
    fn set_content_type(&mut self, value: (u32, u32)) {
        self.send(EngineEvent::ContentType {
            purpose: value.0,
            hint: value.1,
        });
    }

    #[zbus(signal)]
    async fn commit_text(emitter: &SignalEmitter<'_>, text: Value<'_>) -> zbus::Result<()>;

    #[zbus(signal)]
    async fn update_preedit_text(
        emitter: &SignalEmitter<'_>,
        text: Value<'_>,
        cursor_pos: u32,
        visible: bool,
        mode: u32,
    ) -> zbus::Result<()>;

    #[zbus(signal)]
    async fn delete_surrounding_text(
        emitter: &SignalEmitter<'_>,
        offset: i32,
        characters: u32,
    ) -> zbus::Result<()>;

    #[zbus(signal)]
    async fn require_surrounding_text(emitter: &SignalEmitter<'_>) -> zbus::Result<()>;

    #[zbus(signal)]
    async fn forward_key_event(
        emitter: &SignalEmitter<'_>,
        keyval: u32,
        keycode: u32,
        state: u32,
    ) -> zbus::Result<()>;
}

/// `org.freedesktop.IBus.Service`: IBus ends an engine with this.
struct Service;

#[zbus::interface(name = "org.freedesktop.IBus.Service")]
impl Service {
    fn destroy(&self) {}
}

/// IBus asks this for an engine when the input source is chosen.
struct Factory {
    keys: Arc<Mutex<Keys>>,
    handle: Handle,
    active: Arc<Mutex<Option<String>>>,
    next_engine: AtomicU32,
}

#[zbus::interface(name = "org.freedesktop.IBus.Factory")]
impl Factory {
    async fn create_engine(
        &self,
        #[zbus(object_server)] server: &zbus::ObjectServer,
        name: &str,
    ) -> zbus::fdo::Result<OwnedObjectPath> {
        if name != ENGINE {
            return Err(zbus::fdo::Error::Failed(format!("no engine named {name}")));
        }
        let number = self.next_engine.fetch_add(1, Ordering::Relaxed) + 1;
        let path = format!("/org/freedesktop/IBus/Engine/{number}");
        let engine = Engine {
            path: path.clone(),
            active: self.active.clone(),
            keys: self.keys.clone(),
            handle: self.handle.clone(),
        };
        server
            .at(path.as_str(), engine)
            .await
            .map_err(|err| zbus::fdo::Error::Failed(err.to_string()))?;
        server
            .at(path.as_str(), Service)
            .await
            .map_err(|err| zbus::fdo::Error::Failed(err.to_string()))?;
        OwnedObjectPath::try_from(path).map_err(|err| zbus::fdo::Error::Failed(err.to_string()))
    }
}

/// An `IBusText` as IBus sends it: type name, attachments, the string and an
/// attribute list.
fn text_value(text: &str) -> Value<'static> {
    let attachments = HashMap::<String, Value<'static>>::new();
    let attributes = Vec::<Value<'static>>::new();
    let list = Structure::from(("IBusAttrList".to_string(), attachments.clone(), attributes));
    Value::from(Structure::from((
        "IBusText".to_string(),
        attachments,
        text.to_string(),
        Value::from(list),
    )))
}

fn text_from_value(value: &Value<'_>) -> Option<String> {
    let inner = match value {
        Value::Value(inner) => inner.as_ref(),
        other => other,
    };
    let Value::Structure(structure) = inner else {
        return None;
    };
    match structure.fields().get(2)? {
        Value::Str(text) => Some(text.to_string()),
        _ => None,
    }
}

/// The address of the session's IBus, as its clients find it.
fn bus_address() -> Option<String> {
    if let Some(address) = std::env::var("IBUS_ADDRESS").ok().filter(|a| !a.is_empty()) {
        return Some(address);
    }
    let file = std::env::var_os("IBUS_ADDRESS_FILE")
        .map(PathBuf::from)
        .or_else(default_address_file)?;
    parse_address(&std::fs::read_to_string(file).ok()?)
}

fn default_address_file() -> Option<PathBuf> {
    let machine = ["/etc/machine-id", "/var/lib/dbus/machine-id"]
        .iter()
        .find_map(|path| std::fs::read_to_string(path).ok())?;
    let display = std::env::var("WAYLAND_DISPLAY")
        .ok()
        .filter(|d| !d.is_empty())?;
    let config = std::env::var_os("XDG_CONFIG_HOME")
        .filter(|c| !c.is_empty())
        .map(PathBuf::from)
        .or_else(|| {
            std::env::var_os("HOME")
                .filter(|h| !h.is_empty())
                .map(|home| PathBuf::from(home).join(".config"))
        })?;
    Some(
        config
            .join("ibus/bus")
            .join(format!("{}-unix-{display}", machine.trim())),
    )
}

fn parse_address(file: &str) -> Option<String> {
    file.lines()
        .find_map(|line| line.strip_prefix("IBUS_ADDRESS="))
        .map(str::trim)
        .filter(|address| !address.is_empty())
        .map(str::to_string)
}

/// Joins IBus and offers the engine.
fn connect(
    address: &str,
    keys: Arc<Mutex<Keys>>,
    active: Arc<Mutex<Option<String>>>,
    handle: Handle,
) -> anyhow::Result<Connection> {
    let factory = Factory {
        keys,
        handle,
        active,
        next_engine: AtomicU32::new(0),
    };
    zbus::blocking::connection::Builder::address(address)?
        .method_timeout(CALL_TIMEOUT)
        .serve_at(FACTORY_PATH, factory)?
        .name(COMPONENT)?
        .build()
        .context("could not join IBus")
}

/// The field, through whichever engine IBus has focused.
struct Emitter {
    connection: Option<Connection>,
    active: Arc<Mutex<Option<String>>>,
    keys: Arc<Mutex<Keys>>,
    /// IBus says a field's kind only when it differs from the last one, and
    /// may say it before the focus event, so it outlives each field.
    content: Content,
}

impl Emitter {
    fn emit(&self, member: &str, body: &(impl serde::Serialize + zbus::zvariant::DynamicType)) {
        let path = self.active.lock().clone();
        let (Some(connection), Some(path)) = (&self.connection, path) else {
            return;
        };
        if let Err(err) = connection.emit_signal(
            None::<&str>,
            path.as_str(),
            "org.freedesktop.IBus.Engine",
            member,
            body,
        ) {
            log::debug!("autocomplete: could not tell IBus: {err}");
        }
    }
}

impl Output for Emitter {
    fn preedit(&mut self, text: &str) {
        self.emit(
            "UpdatePreeditText",
            &(text_value(text), 0u32, !text.is_empty(), PREEDIT_CLEAR),
        );
    }

    fn commit(&mut self, removed_before: &str, removed_after: &str, text: &str, preedit: &str) {
        let before = removed_before.chars().count() as u32;
        let after = removed_after.chars().count() as u32;
        if before > 0 || after > 0 {
            self.emit("DeleteSurroundingText", &(-(before as i32), before + after));
        }
        if !text.is_empty() {
            self.emit("CommitText", &(text_value(text),));
        }
        self.preedit(preedit);
    }

    fn release_keys(&mut self) {
        self.keys.lock().wanted = false;
    }
}

pub(super) fn start(
    policy: ReadPolicy,
    handler: FocusHandler,
    handle: Handle,
    commands: Receiver<Command>,
) -> anyhow::Result<JoinHandle<()>> {
    let (requests, questions) = crossbeam_channel::unbounded();
    let answers = handle.clone();
    std::thread::Builder::new()
        .name("lokalbot-input-method-surface".into())
        .spawn(move || surface::run(questions, answers, false))
        .context("could not start the input method's reader")?;
    let core = Core::new(policy, handler, requests.clone(), handle.limitation.clone());
    std::thread::Builder::new()
        .name("lokalbot-input-method".into())
        .spawn(move || run(core, handle, commands, requests))
        .context("could not start the input method")
}

fn run(mut core: Core, handle: Handle, commands: Receiver<Command>, requests: Sender<Request>) {
    let keys = Arc::new(Mutex::new(Keys::default()));
    let mut output = Emitter {
        connection: None,
        active: Arc::new(Mutex::new(None)),
        keys: keys.clone(),
        content: Content::default(),
    };
    let mut next_check = Instant::now();
    loop {
        let now = Instant::now();
        if now >= next_check {
            next_check = now + CHECK_EVERY;
            keep_connected(&mut output, &handle, &mut core);
        }
        let deadline = core
            .next_deadline()
            .map_or(next_check, |at| at.min(next_check));
        match commands.recv_deadline(deadline) {
            Ok(command) => match core.command(command, &mut output) {
                None => {}
                Some(Command::Stop) => {
                    let _ = requests.send(Request::Stop);
                    core.deactivate(&mut output);
                    if let Some(connection) = output.connection.take() {
                        let _ = connection.close();
                    }
                    return;
                }
                Some(Command::Keys(accept)) => keys.lock().accept = accept,
                Some(Command::Grab(wanted)) => keys.lock().wanted = wanted,
                Some(Command::PassThrough(key)) => pass_through(&keys, key, &output),
                Some(Command::Engine(event)) => on_engine(event, &mut core, &mut output),
                Some(_) => {}
            },
            Err(RecvTimeoutError::Timeout) => {}
            Err(RecvTimeoutError::Disconnected) => return,
        }
        core.tick(Instant::now(), &mut output);
    }
}

fn on_engine(event: EngineEvent, core: &mut Core, output: &mut Emitter) {
    match event {
        EngineEvent::FocusIn => {
            core.activate(output);
            core.set_limitation(None);
            // An empty field reports nothing, and neither does one whose text
            // is what was last reported. Text comes with the next change.
            let content = output.content;
            core.update(Some(content), Some(Surrounding::default()), output);
        }
        EngineEvent::FocusOut => {
            core.deactivate(output);
            output.keys.lock().taken.clear();
        }
        EngineEvent::Surrounding(surrounding) => {
            if core.refuses_text() {
                return;
            }
            core.update(None, Some(surrounding), output);
        }
        EngineEvent::ContentType { purpose, hint } => {
            output.content = content_from_ibus(purpose, hint);
            let content = output.content;
            core.update(Some(content), None, output);
        }
        EngineEvent::KeyGivenBack => core.blank_for_key(output),
    }
}

fn pass_through(keys: &Mutex<Keys>, key: InterceptedKey, output: &Emitter) {
    let Some(taken) = keys.lock().latest.filter(|taken| taken.key == key) else {
        return;
    };
    output.emit(
        "ForwardKeyEvent",
        &(taken.keyval, taken.keycode, taken.state),
    );
    output.emit(
        "ForwardKeyEvent",
        &(taken.keyval, taken.keycode, taken.state | RELEASE_MASK),
    );
}

/// Joins IBus when it appears and again after it restarts.
fn keep_connected(output: &mut Emitter, handle: &Handle, core: &mut Core) {
    if let Some(connection) = &output.connection {
        let alive = connection
            .call_method(
                Some("org.freedesktop.DBus"),
                "/org/freedesktop/DBus",
                Some("org.freedesktop.DBus"),
                "GetId",
                &(),
            )
            .is_ok();
        if alive {
            return;
        }
        log::info!("autocomplete: IBus went away");
        output.connection = None;
        *output.active.lock() = None;
        core.deactivate(output);
    }
    let Some(address) = bus_address() else {
        return;
    };
    match connect(
        &address,
        output.keys.clone(),
        output.active.clone(),
        handle.clone(),
    ) {
        Ok(connection) => {
            log::info!("autocomplete: joined IBus as an input source");
            output.connection = Some(connection);
        }
        Err(err) => log::debug!("autocomplete: {err:#}"),
    }
}

/// Where IBus reads component files from, in the order it reads them.
fn component_dirs() -> Vec<PathBuf> {
    match std::env::var("IBUS_COMPONENT_PATH") {
        Ok(path) if !path.is_empty() => path.split(':').map(PathBuf::from).collect(),
        _ => vec![PathBuf::from("/usr/share/ibus/component")],
    }
}

const COMPONENT_FILE: &str = "com.lokalbot.LokalBot.xml";

fn component_installed(dirs: &[PathBuf]) -> bool {
    dirs.iter()
        .any(|dir| Path::new(dir).join(COMPONENT_FILE).exists())
}

/// What the user does on GNOME, worded for the Settings row.
pub(super) fn steps() -> InputSourceSteps {
    let steps = lokalbot_i18n::tr(
        "On GNOME, LokalBot reaches your text fields as an input source you choose, next to your keyboard layouts. After turning on autocomplete, open GNOME Settings, then Keyboard, Input Sources, the plus button and Other, and add LokalBot. Then choose it in the input menu on the top bar, or with Super+Space. While it is chosen, the desktop shows LokalBot your key presses in text fields, and it keeps none of them. To type Chinese, Japanese or Korean, switch to that input source the same way.",
    );
    if component_installed(&component_dirs()) {
        return InputSourceSteps {
            text: steps.into(),
            command: None,
        };
    }
    let exe = std::env::current_exe()
        .map(|path| path.display().to_string())
        .unwrap_or_else(|_| "lokalbot".into());
    InputSourceSteps {
        text: format!(
            "{steps} {}",
            lokalbot_i18n::tr(
                "This copy of LokalBot is not on that list yet. Run this in a terminal once, then log out and back in:",
            )
        ),
        command: Some(setup_command(&exe)),
    }
}

fn setup_command(exe: &str) -> String {
    format!(
        "'{exe}' --ibus-component | sudo tee /usr/share/ibus/component/{COMPONENT_FILE} > /dev/null"
    )
}

/// The component file with `exe` as what IBus starts when the source is chosen
/// and LokalBot is not running.
pub(super) fn component_xml(exe: &str) -> String {
    let exe = exe
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;");
    format!(
        r#"<?xml version="1.0" encoding="utf-8"?>
<component>
  <name>{COMPONENT}</name>
  <description>LokalBot autocomplete</description>
  <exec>{exe} --autostart</exec>
  <version>1.0</version>
  <author>LokalBot</author>
  <license>GPL-3.0-or-later</license>
  <homepage>https://lokalbot.com</homepage>
  <textdomain>lokalbot</textdomain>
  <engines>
    <engine>
      <name>{ENGINE}</name>
      <longname>LokalBot</longname>
      <description>Autocomplete in other apps</description>
      <language>other</language>
      <license>GPL-3.0-or-later</license>
      <author>LokalBot</author>
      <layout>default</layout>
      <symbol>LB</symbol>
      <rank>0</rank>
    </engine>
  </engines>
</component>
"#
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    const LOCK: u32 = 1 << 1;
    const SHIFT: u32 = 1;
    const CONTROL: u32 = 1 << 2;
    const NUM_LOCK: u32 = 1 << 4;

    fn wanted() -> Keys {
        Keys {
            wanted: true,
            ..Keys::default()
        }
    }

    #[test]
    fn with_no_suggestion_every_key_goes_straight_on() {
        let mut keys = Keys::default();
        assert_eq!(decide(&mut keys, keysym::TAB, 15, 0), Decision::Pass);
        assert_eq!(decide(&mut keys, 0x61, 30, 0), Decision::Pass);
    }

    #[test]
    fn a_suggestion_takes_plain_accept_keys_and_their_releases() {
        let mut keys = wanted();
        assert_eq!(
            decide(&mut keys, keysym::TAB, 15, 0),
            Decision::Take(InterceptedKey::Tab)
        );
        assert_eq!(
            decide(&mut keys, keysym::TAB, 15, RELEASE_MASK),
            Decision::Keep
        );
        // Locks leave a key plain.
        assert_eq!(
            decide(&mut keys, keysym::ESCAPE, 1, LOCK | NUM_LOCK),
            Decision::Take(InterceptedKey::Escape)
        );
        // The physical key left of 1, whatever it types.
        assert_eq!(
            decide(&mut keys, 0xfe52, EVDEV_GRAVE, 0),
            Decision::Take(InterceptedKey::Backtick)
        );
        // Right Arrow is not bound by default.
        assert_eq!(
            decide(&mut keys, keysym::RIGHT, 106, 0),
            Decision::PassBlanking
        );
    }

    #[test]
    fn held_modifiers_leave_the_accept_keys_with_the_field() {
        let mut keys = wanted();
        assert_eq!(
            decide(&mut keys, keysym::TAB, 15, SHIFT),
            Decision::PassBlanking
        );
        assert_eq!(
            decide(&mut keys, keysym::ESCAPE, 1, CONTROL),
            Decision::PassBlanking
        );
    }

    #[test]
    fn other_keys_go_on_and_modifiers_leave_the_ghost_alone() {
        let mut keys = wanted();
        assert_eq!(decide(&mut keys, 0x61, 30, 0), Decision::PassBlanking);
        assert_eq!(
            decide(&mut keys, keysym::SHIFT_L, 42, 0),
            Decision::Pass,
            "Shift on its own"
        );
        assert_eq!(
            decide(&mut keys, 0x61, 30, RELEASE_MASK),
            Decision::Pass,
            "the release of a key that went on"
        );
    }

    #[test]
    fn the_content_type_maps_onto_the_common_checks() {
        // IBus: password, then terminal, then a private field.
        assert_eq!(content_from_ibus(8, 0).purpose, content::PURPOSE_PASSWORD);
        assert_eq!(content_from_ibus(10, 0).purpose, content::PURPOSE_TERMINAL);
        assert_eq!(
            content_from_ibus(0, 1 << 11).hint,
            content::HINT_SENSITIVE_DATA
        );
        assert_eq!(content_from_ibus(0, 1).hint, 0);
    }

    #[test]
    fn character_offsets_become_byte_offsets() {
        let text = surrounding_from_ibus("héllo wörld".into(), 2, 2);
        assert_eq!(text.cursor, 3);
        assert_eq!(text.anchor, 3);
        let end = surrounding_from_ibus("héllo".into(), 9, 5);
        assert_eq!(end.cursor as usize, "héllo".len());
        assert_eq!(end.anchor as usize, "héllo".len());
    }

    #[test]
    fn a_text_value_reads_back_with_the_signature_ibus_uses() {
        let value = text_value("hello");
        assert_eq!(value.value_signature().to_string(), "(sa{sv}sv)");
        assert_eq!(text_from_value(&value).as_deref(), Some("hello"));
        assert_eq!(text_from_value(&Value::from(3u32)), None);
    }

    #[test]
    fn the_address_comes_from_the_file_ibus_writes() {
        let file = "# comment\nIBUS_ADDRESS=unix:path=/tmp/ibus,guid=abc\nIBUS_DAEMON_PID=7\n";
        assert_eq!(
            parse_address(file).as_deref(),
            Some("unix:path=/tmp/ibus,guid=abc")
        );
        assert_eq!(parse_address("IBUS_DAEMON_PID=7\n"), None);
    }

    #[test]
    fn the_setup_command_installs_where_ibus_looks() {
        let command = setup_command("/home/a b/lokalbot");
        assert!(command.starts_with("'/home/a b/lokalbot' --ibus-component | sudo tee "));
        assert!(command.contains("/usr/share/ibus/component/com.lokalbot.LokalBot.xml"));
        assert!(!component_installed(&[PathBuf::from("/nonexistent")]));
    }

    #[test]
    fn the_component_file_names_the_engine_and_this_copy() {
        let xml = component_xml("/opt/a&b/lokalbot");
        assert!(xml.contains("<name>com.lokalbot.LokalBot.IBus</name>"));
        assert!(xml.contains("<name>lokalbot</name>"));
        assert!(xml.contains("<exec>/opt/a&amp;b/lokalbot --autostart</exec>"));
    }

    #[test]
    fn the_packaged_component_file_matches_what_the_app_prints() {
        let packaged = include_str!("../../../../../packaging/linux/com.lokalbot.LokalBot.xml");
        assert_eq!(packaged, component_xml("/usr/bin/lokalbot"));
    }
}
