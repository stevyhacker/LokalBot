// Contains code ported from Cotabby (https://github.com/FuJacob/cotabby),
// copyright the Cotabby authors, under the GNU AGPL v3.0
// (LICENSES/AGPL-3.0.txt). Modified for LokalBot since 18 October 2026.
// See THIRD_PARTY_NOTICES.md.

//! Linux: the focused field through AT-SPI2, the accessibility bus GTK,
//! Qt, Firefox, Chromium and Electron apps publish to (`CotypingAXHelper`,
//! `CotypingFocusTracker`).
//!
//! The watcher registers for focus, caret and text-change events, reads the
//! focused object when one arrives (coalesced, so a burst of typing costs one
//! read), and polls the last field with Cotabby's backoff for toolkits that
//! miss events. Exclusions are checked from the owning process before any
//! text is requested; secure fields are recognized from their role and
//! labels and never read.
//!
//! Some toolkits (GTK 4) report "screen" coordinates relative to their
//! window; those are moved by the window's position on the X screen.

use std::collections::HashMap;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use anyhow::Context as _;
use crossbeam_channel::{Receiver, RecvTimeoutError, Sender, unbounded};
use parking_lot::Mutex;
use unicode_segmentation::UnicodeSegmentation as _;
use zbus::blocking::Connection;
use zbus::zvariant::{DynamicDeserialize, DynamicType, OwnedObjectPath, OwnedValue, Structure};

use super::geometry::{FieldStyle, Rect, Rgb};
use super::policy::{self, FlickerGate, PollBackoff, ReadPolicy, reasons};
use super::visible::{self, NodeKind, VisibleSource};
use super::{Capability, Edit, FieldSnapshot, FocusHandler, FocusSnapshot, InsertTarget};

const REGISTRY: &str = "org.a11y.atspi.Registry";
const ROOT_PATH: &str = "/org/a11y/atspi/accessible/root";
const ACCESSIBLE: &str = "org.a11y.atspi.Accessible";
const TEXT: &str = "org.a11y.atspi.Text";
const EDITABLE_TEXT: &str = "org.a11y.atspi.EditableText";
const COMPONENT: &str = "org.a11y.atspi.Component";
const DOCUMENT: &str = "org.a11y.atspi.Document";
const COLLECTION: &str = "org.a11y.atspi.Collection";
const APPLICATION: &str = "org.a11y.atspi.Application";

/// Every call gives up after this, so a stuck app costs one missed read.
const CALL_TIMEOUT: Duration = Duration::from_millis(250);
/// Poll cadence before backoff (`CotypingFocusTracker.defaultIntervalMs`).
const POLL_INTERVAL: Duration = Duration::from_millis(200);
/// Events arriving this close together are read once.
const COALESCE: Duration = Duration::from_millis(8);
/// Time for the walk that finds the text above a field.
const VISIBLE_BUDGET: Duration = Duration::from_millis(120);

/// `ATSPI_COORD_TYPE_SCREEN`.
const COORD_SCREEN: u32 = 0;
/// `ATSPI_COORD_TYPE_WINDOW`.
const COORD_WINDOW: u32 = 1;

mod role {
    //! `AtspiRole` values used here.
    pub const COMBO_BOX: u32 = 11;
    pub const DIALOG: u32 = 16;
    pub const FILE_CHOOSER: u32 = 19;
    pub const FRAME: u32 = 23;
    pub const LABEL: u32 = 29;
    pub const MENU: u32 = 33;
    pub const MENU_BAR: u32 = 34;
    pub const PASSWORD_TEXT: u32 = 40;
    pub const POPUP_MENU: u32 = 41;
    pub const SCROLL_PANE: u32 = 49;
    pub const TERMINAL: u32 = 60;
    pub const TEXT: u32 = 61;
    pub const TOOL_BAR: u32 = 63;
    pub const TREE: u32 = 65;
    pub const TREE_TABLE: u32 = 66;
    pub const VIEWPORT: u32 = 68;
    pub const WINDOW: u32 = 69;
    pub const PARAGRAPH: u32 = 73;
    pub const ENTRY: u32 = 79;
    pub const CAPTION: u32 = 81;
    pub const DOCUMENT_FRAME: u32 = 82;
    pub const HEADING: u32 = 83;
    pub const LINK: u32 = 88;
    pub const DOCUMENT_TEXT: u32 = 94;
    pub const DOCUMENT_WEB: u32 = 95;
    pub const STATIC: u32 = 116;
}

mod state {
    //! `AtspiStateType` bits.
    pub const EDITABLE: u32 = 7;
    pub const FOCUSED: u32 = 12;
    pub const MULTI_LINE: u32 = 17;
    pub const SHOWING: u32 = 25;
    pub const SINGLE_LINE: u32 = 26;
    pub const VISIBLE: u32 = 30;
    pub const READ_ONLY: u32 = 43;

    pub fn has(states: u64, bit: u32) -> bool {
        states & (1u64 << bit) != 0
    }
}

/// An accessible object: its owner's bus name and its path.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
struct Obj {
    bus: String,
    path: String,
}

impl Obj {
    fn new(bus: impl Into<String>, path: impl Into<String>) -> Self {
        Self {
            bus: bus.into(),
            path: path.into(),
        }
    }

    fn from_pair((bus, path): (String, OwnedObjectPath)) -> Option<Self> {
        let path = path.as_str().to_string();
        (!bus.is_empty() && path != "/org/a11y/atspi/null").then_some(Self { bus, path })
    }

    fn key(&self) -> String {
        format!("{}{}", self.bus, self.path)
    }
}

/// The accessibility bus.
#[derive(Clone)]
struct Bus {
    conn: Connection,
}

impl Bus {
    fn connect() -> anyhow::Result<Self> {
        let session = Connection::session().context("no D-Bus session bus")?;
        let reply = session
            .call_method(
                Some("org.a11y.Bus"),
                "/org/a11y/bus",
                Some("org.a11y.Bus"),
                "GetAddress",
                &(),
            )
            .context("the accessibility bus (at-spi2-core) is not running")?;
        let address: String = reply.body().deserialize()?;
        let conn = zbus::blocking::connection::Builder::address(address.as_str())?
            .method_timeout(CALL_TIMEOUT)
            .build()
            .context("could not connect to the accessibility bus")?;
        Ok(Self { conn })
    }

    fn call<R>(
        &self,
        obj: &Obj,
        iface: &str,
        method: &str,
        body: &(impl serde::Serialize + DynamicType),
    ) -> anyhow::Result<R>
    where
        R: for<'d> DynamicDeserialize<'d>,
    {
        let reply = self.conn.call_method(
            Some(obj.bus.as_str()),
            obj.path.as_str(),
            Some(iface),
            method,
            body,
        )?;
        Ok(reply.body().deserialize::<R>()?)
    }

    fn property(&self, obj: &Obj, iface: &str, name: &str) -> anyhow::Result<OwnedValue> {
        self.call(
            obj,
            "org.freedesktop.DBus.Properties",
            "Get",
            &(iface, name),
        )
    }

    fn string_property(&self, obj: &Obj, iface: &str, name: &str) -> Option<String> {
        String::try_from(self.property(obj, iface, name).ok()?).ok()
    }

    fn int_property(&self, obj: &Obj, iface: &str, name: &str) -> Option<i32> {
        i32::try_from(self.property(obj, iface, name).ok()?).ok()
    }

    fn role(&self, obj: &Obj) -> Option<u32> {
        self.call(obj, ACCESSIBLE, "GetRole", &()).ok()
    }

    fn role_name(&self, obj: &Obj) -> Option<String> {
        self.call(obj, ACCESSIBLE, "GetRoleName", &()).ok()
    }

    fn states(&self, obj: &Obj) -> Option<u64> {
        let words: Vec<u32> = self.call(obj, ACCESSIBLE, "GetState", &()).ok()?;
        Some(
            words
                .iter()
                .take(2)
                .enumerate()
                .fold(0u64, |acc, (i, w)| acc | (u64::from(*w) << (32 * i))),
        )
    }

    fn name(&self, obj: &Obj) -> String {
        self.string_property(obj, ACCESSIBLE, "Name")
            .unwrap_or_default()
    }

    fn description(&self, obj: &Obj) -> String {
        self.string_property(obj, ACCESSIBLE, "Description")
            .unwrap_or_default()
    }

    fn parent(&self, obj: &Obj) -> Option<Obj> {
        let value = self.property(obj, ACCESSIBLE, "Parent").ok()?;
        let structure = Structure::try_from(value).ok()?;
        let fields = structure.fields();
        let bus: String = fields.first()?.try_clone().ok()?.try_into().ok()?;
        let path: OwnedObjectPath = fields.get(1)?.try_clone().ok()?.try_into().ok()?;
        Obj::from_pair((bus, path))
    }

    fn children(&self, obj: &Obj) -> Vec<Obj> {
        self.call::<Vec<(String, OwnedObjectPath)>>(obj, ACCESSIBLE, "GetChildren", &())
            .map(|children| children.into_iter().filter_map(Obj::from_pair).collect())
            .unwrap_or_default()
    }

    fn interfaces(&self, obj: &Obj) -> Vec<String> {
        self.call(obj, ACCESSIBLE, "GetInterfaces", &())
            .unwrap_or_default()
    }

    fn attributes(&self, obj: &Obj) -> HashMap<String, String> {
        self.call(obj, ACCESSIBLE, "GetAttributes", &())
            .unwrap_or_default()
    }

    fn application(&self, obj: &Obj) -> Option<Obj> {
        self.call::<(String, OwnedObjectPath)>(obj, ACCESSIBLE, "GetApplication", &())
            .ok()
            .and_then(Obj::from_pair)
    }

    fn pid(&self, bus_name: &str) -> Option<u32> {
        let reply = self
            .conn
            .call_method(
                Some("org.freedesktop.DBus"),
                "/org/freedesktop/DBus",
                Some("org.freedesktop.DBus"),
                "GetConnectionUnixProcessID",
                &(bus_name,),
            )
            .ok()?;
        reply.body().deserialize::<u32>().ok()
    }

    fn extents(&self, obj: &Obj, coords: u32) -> Option<Rect> {
        let (x, y, w, h): (i32, i32, i32, i32) =
            self.call(obj, COMPONENT, "GetExtents", &(coords,)).ok()?;
        rect(x, y, w, h)
    }

    fn character_extents(&self, obj: &Obj, offset: i32, coords: u32) -> Option<Rect> {
        let (x, y, w, h): (i32, i32, i32, i32) = self
            .call(obj, TEXT, "GetCharacterExtents", &(offset, coords))
            .ok()?;
        rect(x, y, w, h)
    }

    /// The toolkit's major version ("GTK", 4), from the application object.
    fn toolkit(&self, app: &Obj) -> Option<(String, u32)> {
        let name = self.string_property(app, APPLICATION, "ToolkitName")?;
        let version = self.string_property(app, APPLICATION, "Version")?;
        let major = version.split('.').next()?.trim().parse().ok()?;
        Some((name, major))
    }

    fn text(&self, obj: &Obj, start: i32, end: i32) -> Option<String> {
        self.call(obj, TEXT, "GetText", &(start, end)).ok()
    }

    fn caret_offset(&self, obj: &Obj) -> Option<i32> {
        self.int_property(obj, TEXT, "CaretOffset")
    }

    fn character_count(&self, obj: &Obj) -> Option<i32> {
        self.int_property(obj, TEXT, "CharacterCount")
    }

    fn selection(&self, obj: &Obj) -> Option<(i32, i32)> {
        let count: i32 = self.call(obj, TEXT, "GetNSelections", &()).ok()?;
        if count <= 0 {
            return None;
        }
        self.call(obj, TEXT, "GetSelection", &(0i32,)).ok()
    }

    fn text_attributes(&self, obj: &Obj, offset: i32) -> HashMap<String, String> {
        self.call::<(HashMap<String, String>, i32, i32)>(
            obj,
            TEXT,
            "GetAttributeRun",
            &(offset, true),
        )
        .map(|(attributes, _, _)| attributes)
        .unwrap_or_default()
    }
}

/// The coordinate type to ask for and how to bring the answer to the
/// screen: window coordinates plus the window's content origin for GTK 4,
/// else screen coordinates as they are.
fn placement(window_origin: Option<(f32, f32)>) -> (u32, impl Fn(Rect) -> Rect + Copy) {
    let coords = if window_origin.is_some() {
        COORD_WINDOW
    } else {
        COORD_SCREEN
    };
    let place = move |r: Rect| match window_origin {
        Some((dx, dy)) => Rect::new(r.x + dx, r.y + dy, r.width, r.height),
        None => r,
    };
    (coords, place)
}

/// AT-SPI reports a missing rect as zeros or -1s.
fn rect(x: i32, y: i32, w: i32, h: i32) -> Option<Rect> {
    if w < 0 || h <= 0 || (x == 0 && y == 0 && w == 0 && h == 0) || x == i32::MIN || y == i32::MIN {
        return None;
    }
    Some(Rect::new(x as f32, y as f32, w as f32, h as f32))
}

/// Event subscriptions the registry forwards to apps: without one, toolkits
/// do not send the event at all.
const EVENTS: [&str; 5] = [
    "object:state-changed:focused",
    "object:text-caret-moved",
    "object:text-changed",
    "focus:",
    "window:activate",
];

fn register_events(bus: &Bus, register: bool) {
    let registry = Obj::new(REGISTRY, "/org/a11y/atspi/registry");
    let method = if register {
        "RegisterEvent"
    } else {
        "DeregisterEvent"
    };
    for event in EVENTS {
        if let Err(err) = bus.call::<()>(&registry, "org.a11y.atspi.Registry", method, &(event,)) {
            log::debug!("autocomplete: {method} {event}: {err:#}");
        }
    }
}

enum Command {
    Policy(ReadPolicy),
    Refresh,
    Event(AtspiEvent),
    Stop,
}

#[derive(Debug)]
enum AtspiEvent {
    /// An object gained (true) or lost focus.
    Focus(Obj, bool),
    /// The caret moved or the text changed in an object.
    Edit(Obj),
    /// A window came forward.
    Window,
}

/// Parses one event signal: member, sender, path and the `detail`/`detail1`
/// fields, whichever body layout the toolkit uses (`siiva{sv}` or Qt's
/// `siiv(so)`).
fn parse_event(message: &zbus::Message) -> Option<AtspiEvent> {
    let header = message.header();
    let member = header.member()?.as_str().to_string();
    let sender = header.sender()?.as_str().to_string();
    let path = header.path()?.as_str().to_string();
    let obj = Obj::new(sender, path);
    let body = message.body();
    let fields: Option<(String, i32)> = body.deserialize::<Structure>().ok().and_then(|s| {
        let fields = s.fields();
        let detail = fields.first()?.downcast_ref::<String>().ok()?;
        let detail1 = fields.get(1)?.downcast_ref::<i32>().ok()?;
        Some((detail, detail1))
    });
    match member.as_str() {
        "StateChanged" => {
            let (detail, value) = fields?;
            (detail == "focused").then_some(AtspiEvent::Focus(obj, value != 0))
        }
        "TextCaretMoved" | "TextChanged" => Some(AtspiEvent::Edit(obj)),
        "Focus" => Some(AtspiEvent::Focus(obj, true)),
        "Activate" => Some(AtspiEvent::Window),
        _ => None,
    }
}

pub(super) struct Watcher {
    commands: Sender<Command>,
    thread: Option<JoinHandle<()>>,
    listener: Option<Connection>,
    stopped: Arc<AtomicBool>,
    limitation: Arc<Mutex<Option<String>>>,
}

impl Watcher {
    pub(super) fn start(policy: ReadPolicy, handler: FocusHandler) -> anyhow::Result<Self> {
        let bus = Bus::connect()?;
        register_events(&bus, true);
        let (commands, receiver) = unbounded();
        let stopped = Arc::new(AtomicBool::new(false));
        // Events arrive on a connection of their own so a slow read never
        // backs up the signal stream.
        let listener = Bus::connect()?.conn;
        for interface in [
            "org.a11y.atspi.Event.Object",
            "org.a11y.atspi.Event.Focus",
            "org.a11y.atspi.Event.Window",
        ] {
            let rule = zbus::MatchRule::builder()
                .msg_type(zbus::message::Type::Signal)
                .interface(interface)?
                .build();
            let iterator =
                zbus::blocking::MessageIterator::for_match_rule(rule, &listener, Some(512))?;
            let tx = commands.clone();
            let stop = stopped.clone();
            std::thread::Builder::new()
                .name("lokalbot-atspi-events".into())
                .spawn(move || {
                    for message in iterator {
                        if stop.load(Ordering::Relaxed) {
                            break;
                        }
                        let Ok(message) = message else {
                            break;
                        };
                        if let Some(event) = parse_event(&message)
                            && tx.send(Command::Event(event)).is_err()
                        {
                            break;
                        }
                    }
                })?;
        }
        let limitation = Arc::new(Mutex::new(None));
        let thread_limitation = limitation.clone();
        let thread = std::thread::Builder::new()
            .name("lokalbot-autocomplete-watch".into())
            .spawn(move || {
                let mut reader = Reader::new(bus, policy, thread_limitation);
                reader.run(receiver, handler);
                register_events(&reader.bus, false);
            })?;
        Ok(Self {
            commands,
            thread: Some(thread),
            listener: Some(listener),
            stopped,
            limitation,
        })
    }

    pub(super) fn set_policy(&self, policy: ReadPolicy) {
        let _ = self.commands.send(Command::Policy(policy));
    }

    pub(super) fn refresh_now(&self) {
        let _ = self.commands.send(Command::Refresh);
    }

    pub(super) fn limitation(&self) -> Option<String> {
        self.limitation.lock().clone()
    }
}

impl Drop for Watcher {
    fn drop(&mut self) {
        self.stopped.store(true, Ordering::Relaxed);
        let _ = self.commands.send(Command::Stop);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
        // Ends the event threads, which are blocked reading this connection.
        if let Some(listener) = self.listener.take() {
            let _ = listener.close();
        }
    }
}

/// What is read once per focused object.
#[derive(Clone, Debug)]
struct Fixed {
    pid: u32,
    app_name: String,
    app_id: String,
    window_title: String,
    url: Option<String>,
    /// The object has `EditableText`.
    editable: bool,
    single_line: bool,
    /// Where the window's content is on screen, when the toolkit can only
    /// report coordinates within its window (GTK 4).
    window_relative: Option<(f32, f32)>,
    style: Option<FieldStyle>,
    /// Why this object gets no suggestion, decided from metadata alone.
    refusal: Option<Refusal>,
}

#[derive(Clone, Copy, Debug)]
enum Refusal {
    Blocked(&'static str),
    Unsupported(&'static str),
}

struct Reader {
    bus: Bus,
    policy: ReadPolicy,
    x11: super::x11::Display,
    apps: crate::activity::AppResolver,
    pids: HashMap<String, u32>,
    names: HashMap<u32, (String, String)>,
    current: Option<Obj>,
    fixed: Option<(Obj, Fixed)>,
    visible: Option<(Obj, Option<String>)>,
    last: FocusSnapshot,
    gate: FlickerGate,
    backoff: PollBackoff,
    last_active_window: Option<u32>,
    own_pid: u32,
    limitation: Arc<Mutex<Option<String>>>,
}

impl Reader {
    fn new(bus: Bus, policy: ReadPolicy, limitation: Arc<Mutex<Option<String>>>) -> Self {
        Self {
            bus,
            policy,
            x11: super::x11::Display::new(),
            apps: crate::activity::AppResolver::new(),
            pids: HashMap::new(),
            names: HashMap::new(),
            current: None,
            fixed: None,
            visible: None,
            last: FocusSnapshot::none(),
            gate: FlickerGate::default(),
            backoff: PollBackoff::default(),
            last_active_window: None,
            own_pid: std::process::id(),
            limitation,
        }
    }

    fn run(&mut self, receiver: Receiver<Command>, handler: FocusHandler) {
        // A field focused before the watcher started has sent no event yet.
        self.discover_focus();
        self.deliver(&handler);
        loop {
            let timeout = POLL_INTERVAL * self.backoff.stride();
            let dirty = match receiver.recv_timeout(timeout) {
                Ok(Command::Stop) | Err(RecvTimeoutError::Disconnected) => break,
                Ok(command) => {
                    let Some(mut dirty) = self.handle(command) else {
                        break;
                    };
                    // Read once for a burst of events.
                    let until = Instant::now() + COALESCE;
                    while let Ok(command) = receiver.recv_deadline(until) {
                        let Some(changed) = self.handle(command) else {
                            return;
                        };
                        dirty |= changed;
                    }
                    dirty
                }
                Err(RecvTimeoutError::Timeout) => {
                    let active = self.x11.active_window();
                    let id = active.as_ref().map(|w| w.id);
                    if id != self.last_active_window {
                        self.last_active_window = id;
                        self.discover_focus();
                    }
                    true
                }
            };
            if dirty {
                let changed = self.deliver(&handler);
                self.backoff.record(changed);
            }
        }
    }

    /// Applies one command. `None` to stop; otherwise whether the field
    /// needs reading again.
    fn handle(&mut self, command: Command) -> Option<bool> {
        let dirty = match command {
            Command::Stop => return None,
            Command::Policy(policy) => {
                self.policy = policy;
                self.fixed = None;
                self.visible = None;
                self.backoff.reset();
                true
            }
            Command::Refresh => {
                self.backoff.reset();
                true
            }
            Command::Event(AtspiEvent::Focus(obj, true)) => {
                self.set_current(Some(obj));
                self.backoff.reset();
                true
            }
            Command::Event(AtspiEvent::Focus(obj, false)) => {
                let lost = self.current.as_ref() == Some(&obj);
                if lost {
                    self.set_current(None);
                }
                lost
            }
            Command::Event(AtspiEvent::Edit(obj)) => {
                if self.current.as_ref() == Some(&obj) {
                    self.backoff.reset();
                    true
                } else if self.current.is_none()
                    && self
                        .bus
                        .states(&obj)
                        .is_some_and(|s| state::has(s, state::FOCUSED))
                {
                    // An editing object whose focus event came before we did.
                    self.set_current(Some(obj));
                    true
                } else {
                    // Output in another app, such as a terminal: not ours.
                    false
                }
            }
            Command::Event(AtspiEvent::Window) => {
                self.discover_focus();
                self.backoff.reset();
                true
            }
        };
        Some(dirty)
    }

    fn set_current(&mut self, obj: Option<Obj>) {
        if self.current != obj {
            self.current = obj;
            self.fixed = None;
            // Text read from around a field is forgotten when focus leaves it.
            self.visible = None;
        }
    }

    /// Finds the focused object of the active window's app when no event
    /// said: at startup and after an app switch.
    fn discover_focus(&mut self) {
        let Some(pid) = self.x11.active_window().and_then(|w| w.pid) else {
            return;
        };
        if pid == self.own_pid {
            return;
        }
        if let Some(current) = self.current.clone()
            && self.pid_of(&current.bus) == Some(pid)
            && self
                .bus
                .states(&current)
                .is_some_and(|s| state::has(s, state::FOCUSED))
        {
            return;
        }
        let root = Obj::new(REGISTRY, ROOT_PATH);
        let mut published = false;
        for app in self.bus.children(&root) {
            if self.pid_of(&app.bus) != Some(pid) {
                continue;
            }
            published = true;
            if let Some(found) = self.find_focused(&app) {
                self.set_current(Some(found));
                break;
            }
        }
        // Apps that keep their text from accessibility tools cannot get
        // suggestions; say which, so it does not look broken.
        let mut limitation = self.limitation.lock();
        if published {
            *limitation = None;
        } else if pid != self.own_pid {
            let (name, _) = self.apps.resolve(pid, None, None);
            *limitation = Some(format!(
                "{name} does not share its text with accessibility tools, so autocomplete cannot suggest there. Chromium and Electron apps share it when started with --force-renderer-accessibility, Qt apps with QT_LINUX_ACCESSIBILITY_ALWAYS_ON=1."
            ));
        }
    }

    /// The focused descendant of an app: one `Collection` query when the
    /// toolkit supports it, else a short walk through showing objects.
    fn find_focused(&self, app: &Obj) -> Option<Obj> {
        // (states, match, attributes, match, roles, match, interfaces, match, invert)
        let focused: Vec<i32> = vec![1 << state::FOCUSED, 0];
        let rule = (
            focused,
            1i32,
            HashMap::<String, String>::new(),
            1i32,
            Vec::<i32>::new(),
            1i32,
            Vec::<String>::new(),
            1i32,
            false,
        );
        if let Ok(found) = self.bus.call::<Vec<(String, OwnedObjectPath)>>(
            app,
            COLLECTION,
            "GetMatches",
            &(rule, 0u32, 1i32, true),
        ) && let Some(obj) = found.into_iter().find_map(Obj::from_pair)
        {
            return Some(obj);
        }
        let started = Instant::now();
        let mut queue = std::collections::VecDeque::from([app.clone()]);
        let mut seen = 0;
        while let Some(obj) = queue.pop_front() {
            if seen > 400 || started.elapsed() > Duration::from_millis(150) {
                break;
            }
            seen += 1;
            let states = self.bus.states(&obj).unwrap_or(0);
            if state::has(states, state::FOCUSED) && obj != *app {
                return Some(obj);
            }
            if obj != *app && !state::has(states, state::SHOWING) {
                continue;
            }
            queue.extend(self.bus.children(&obj).into_iter().take(64));
        }
        None
    }

    fn pid_of(&mut self, bus_name: &str) -> Option<u32> {
        if let Some(pid) = self.pids.get(bus_name) {
            return Some(*pid);
        }
        let pid = self.bus.pid(bus_name)?;
        self.pids.insert(bus_name.to_string(), pid);
        Some(pid)
    }

    /// Reads and delivers the focus when it changed. Returns whether it did.
    fn deliver(&mut self, handler: &FocusHandler) -> bool {
        let snapshot = self.read();
        if !self.gate.apply(&snapshot) {
            return false;
        }
        if snapshot == self.last {
            return false;
        }
        self.last = snapshot.clone();
        handler(snapshot);
        true
    }

    fn read(&mut self) -> FocusSnapshot {
        let Some(obj) = self.current.clone() else {
            return FocusSnapshot::none();
        };
        if !self.policy.enabled {
            return FocusSnapshot::none();
        }
        let fixed = match &self.fixed {
            Some((fixed_obj, fixed)) if *fixed_obj == obj => fixed.clone(),
            _ => match self.read_fixed(&obj) {
                Some(fixed) => {
                    self.fixed = Some((obj.clone(), fixed.clone()));
                    fixed
                }
                None => {
                    self.set_current(None);
                    return FocusSnapshot::none();
                }
            },
        };
        let key = obj.key();
        match fixed.refusal {
            Some(Refusal::Blocked(reason)) => {
                return FocusSnapshot::blocked(&fixed.app_name, &fixed.app_id, reason, Some(key));
            }
            Some(Refusal::Unsupported(reason)) => {
                return FocusSnapshot::unsupported(&fixed.app_name, &fixed.app_id, reason);
            }
            None => {}
        }
        match self.read_text(&obj, &fixed) {
            Ok(field) => {
                let mut field = field;
                field.visible_text = self.visible_text(&obj, &field);
                FocusSnapshot {
                    app_name: fixed.app_name.clone(),
                    app_id: fixed.app_id.clone(),
                    capability: Capability::Supported,
                    field: Some(field),
                    focus_key: Some(key),
                }
            }
            Err(refusal) => match refusal {
                Refusal::Blocked(reason) => {
                    FocusSnapshot::blocked(&fixed.app_name, &fixed.app_id, reason, Some(key))
                }
                Refusal::Unsupported(reason) => {
                    FocusSnapshot::unsupported(&fixed.app_name, &fixed.app_id, reason)
                }
            },
        }
    }

    /// Identity, privacy and the field's kind, from metadata only. `None`
    /// when the object is gone.
    fn read_fixed(&mut self, obj: &Obj) -> Option<Fixed> {
        let pid = self.pid_of(&obj.bus)?;
        let mut fixed = Fixed {
            pid,
            app_name: String::new(),
            app_id: String::new(),
            window_title: String::new(),
            url: None,
            editable: false,
            single_line: false,
            window_relative: None,
            style: None,
            refusal: None,
        };
        if pid == self.own_pid {
            // LokalBot's own windows: its practice editor feeds the engine
            // itself, and nothing else of LokalBot is read.
            fixed.app_name = "LokalBot".into();
            fixed.app_id = crate::privacy::SELF_APP_ID.into();
            fixed.refusal = Some(Refusal::Unsupported("Off in LokalBot."));
            return Some(fixed);
        }
        let (app_name, app_id) = self.app_identity(pid, obj);
        fixed.app_name = app_name;
        fixed.app_id = app_id;
        if !self.policy.allows_app(&fixed.app_name, &fixed.app_id) {
            fixed.refusal = Some(Refusal::Unsupported(
                if policy::is_terminal_app(&fixed.app_name, &fixed.app_id) {
                    reasons::TERMINAL
                } else {
                    reasons::EXCLUDED_APP
                },
            ));
            return Some(fixed);
        }
        let role = self.bus.role(obj)?;
        let states = self.bus.states(obj).unwrap_or(0);
        let role_name = self.bus.role_name(obj).unwrap_or_default();
        let name = self.bus.name(obj);
        let description = self.bus.description(obj);
        let attributes = self.bus.attributes(obj);
        // Secure fields: never read, judged before any text is touched.
        if role == role::PASSWORD_TEXT
            || policy::is_secure_field([
                role_name.as_str(),
                name.as_str(),
                description.as_str(),
                attributes
                    .get("placeholder-text")
                    .map_or("", String::as_str),
            ])
        {
            fixed.refusal = Some(Refusal::Blocked(reasons::SECURE));
            return Some(fixed);
        }
        if role == role::TERMINAL {
            fixed.refusal = Some(Refusal::Unsupported(reasons::TERMINAL));
            return Some(fixed);
        }
        let interfaces = self.bus.interfaces(obj);
        let has_text = interfaces.iter().any(|i| i == TEXT);
        fixed.editable = interfaces.iter().any(|i| i == EDITABLE_TEXT);
        let editable_state =
            state::has(states, state::EDITABLE) && !state::has(states, state::READ_ONLY);
        if !has_text || !editable_state {
            fixed.refusal = Some(Refusal::Unsupported(reasons::NOT_EDITABLE));
            return Some(fixed);
        }
        let aria = attributes.get("xml-roles").map_or("", String::as_str);
        let input_type = attributes.get("text-input-type").map_or("", String::as_str);
        if policy::is_search_field([aria, input_type, role_name.as_str()]) {
            fixed.refusal = Some(Refusal::Unsupported(reasons::SEARCH));
            return Some(fixed);
        }
        fixed.single_line = state::has(states, state::SINGLE_LINE)
            || (matches!(role, role::ENTRY | role::COMBO_BOX)
                && !state::has(states, state::MULTI_LINE));
        // Window title, file dialogs and the page address from the ancestors.
        let mut cursor = self.bus.parent(obj);
        let mut depth = 0;
        let mut frame: Option<Obj> = None;
        while let Some(node) = cursor {
            depth += 1;
            if depth > 48 {
                break;
            }
            let node_role = self.bus.role(&node).unwrap_or(0);
            if node_role == role::FILE_CHOOSER {
                fixed.refusal = Some(Refusal::Unsupported(reasons::FILE_DIALOG));
                return Some(fixed);
            }
            if fixed.url.is_none() && matches!(node_role, role::DOCUMENT_WEB | role::DOCUMENT_FRAME)
            {
                fixed.url = self.document_url(&node);
            }
            if matches!(node_role, role::FRAME | role::WINDOW | role::DIALOG) {
                fixed.window_title = self.bus.name(&node);
                frame = Some(node);
                break;
            }
            cursor = self.bus.parent(&node);
        }
        fixed.window_relative = frame.and_then(|_| self.window_origin(obj, pid));
        fixed.style = self.style(obj);
        Some(fixed)
    }

    /// The app's name and id by day memory's rules, with its window's
    /// `WM_CLASS` when that window is in front.
    fn app_identity(&mut self, pid: u32, obj: &Obj) -> (String, String) {
        if let Some(found) = self.names.get(&pid) {
            return found.clone();
        }
        let window = self.x11.active_window().filter(|w| w.pid == Some(pid));
        let (class, instance) = window.map_or((None, None), |w| (w.class, w.instance));
        let (mut name, id) = self.apps.resolve(pid, class, instance);
        if name == "Unknown app"
            && let Some(app) = self.bus.application(obj)
        {
            let toolkit_name = self.bus.name(&app);
            if !toolkit_name.is_empty() {
                name = toolkit_name;
            }
        }
        self.names.insert(pid, (name.clone(), id.clone()));
        (name, id)
    }

    fn document_url(&self, document: &Obj) -> Option<String> {
        for key in ["DocURL", "URI", "URL"] {
            if let Ok(value) =
                self.bus
                    .call::<String>(document, DOCUMENT, "GetAttributeValue", &(key,))
                && !value.is_empty()
            {
                return Some(value);
            }
        }
        let attributes: HashMap<String, String> = self
            .bus
            .call(document, DOCUMENT, "GetAttributes", &())
            .unwrap_or_default();
        ["DocURL", "URI", "URL", "url"]
            .iter()
            .find_map(|key| attributes.get(*key).filter(|v| !v.is_empty()).cloned())
    }

    /// GTK 4 cannot know where its window is: its "screen" extents are
    /// relative to the parent, and only window extents are right, measured
    /// from the window's content (inside the shadow it draws itself). Its
    /// fields are placed from window extents and where the X window's
    /// content is; `None` for toolkits that report screen coordinates.
    fn window_origin(&mut self, obj: &Obj, pid: u32) -> Option<(f32, f32)> {
        let app = self.bus.application(obj)?;
        let (toolkit, major) = self.bus.toolkit(&app)?;
        if !toolkit.eq_ignore_ascii_case("gtk") || major < 4 {
            return None;
        }
        let content = self
            .x11
            .active_window()
            .filter(|w| w.pid == Some(pid))?
            .frame?;
        Some((content.x, content.y))
    }

    fn style(&self, obj: &Obj) -> Option<FieldStyle> {
        let caret = self.bus.caret_offset(obj).unwrap_or(0).max(1) - 1;
        let attributes = self.bus.text_attributes(obj, caret);
        let style = FieldStyle {
            font_family: attributes
                .get("family-name")
                .filter(|f| !f.is_empty())
                .cloned(),
            font_points: attributes
                .get("size")
                .and_then(|s| s.trim().trim_end_matches("pt").parse::<f32>().ok())
                .filter(|s| *s > 0.0),
            color: attributes.get("fg-color").and_then(|c| Rgb::parse(c)),
            background: attributes.get("bg-color").and_then(|c| Rgb::parse(c)),
        };
        (style != FieldStyle::default()).then_some(style)
    }

    /// The live text and caret. Fails with why there is no suggestion.
    fn read_text(&self, obj: &Obj, fixed: &Fixed) -> Result<FieldSnapshot, Refusal> {
        let caret = self
            .bus
            .caret_offset(obj)
            .filter(|c| *c >= 0)
            .ok_or(Refusal::Unsupported(reasons::NO_CARET))?;
        let count = self.bus.character_count(obj).unwrap_or(caret).max(caret);
        if let Some((start, end)) = self.bus.selection(obj)
            && start != end
        {
            return Err(Refusal::Blocked(reasons::SELECTION));
        }
        let max_before = policy::MAX_BEFORE_UTF16 as i32;
        let max_after = policy::MAX_AFTER_UTF16 as i32;
        let start = (caret - max_before).max(0);
        let raw_before = self
            .bus
            .text(obj, start, caret)
            .ok_or(Refusal::Unsupported(reasons::NOT_EDITABLE))?;
        let end = (caret + max_after).min(count);
        let raw_after = if end > caret {
            self.bus.text(obj, caret, end).unwrap_or_default()
        } else {
            String::new()
        };
        // Web content marks embedded objects with U+FFFC.
        let raw_before = raw_before.replace('\u{fffc}', "");
        let raw_after = raw_after.replace('\u{fffc}', "");
        let (before, before_truncated) = policy::bounded_before(&raw_before, start > 0);
        let after = policy::bounded_after(&raw_after, end < count);

        let (coords, offset) = placement(fixed.window_relative);
        let field_frame = self.bus.extents(obj, coords).map(offset);
        let empty_range = (caret < count)
            .then(|| self.bus.character_extents(obj, caret, coords))
            .flatten()
            .map(offset)
            .map(|r| Rect::new(r.x, r.y, 0.0, r.height));
        let previous = (caret > 0 && !raw_before.ends_with('\n'))
            .then(|| self.bus.character_extents(obj, caret - 1, coords))
            .flatten()
            .map(offset);
        let rtl = policy::is_right_to_left(&before);
        let (caret_rect, caret_exact) =
            match policy::choose_caret(empty_range, previous, field_frame, rtl) {
                Some(rect) => (rect, true),
                None => match field_frame {
                    // A thin caret at the field's leading edge, as macOS estimates.
                    Some(frame) => (
                        Rect::new(frame.x + 4.0, frame.y, 1.0, frame.height.clamp(8.0, 22.0)),
                        false,
                    ),
                    None => return Err(Refusal::Unsupported(reasons::NO_CARET)),
                },
            };
        Ok(FieldSnapshot {
            focus_key: obj.key(),
            app_name: fixed.app_name.clone(),
            app_id: fixed.app_id.clone(),
            pid: fixed.pid,
            window_title: fixed.window_title.clone(),
            before,
            before_truncated,
            after,
            caret: caret_rect,
            caret_exact,
            field_frame,
            single_line: fixed.single_line,
            url: fixed.url.clone(),
            visible_text: None,
            style: fixed.style.clone(),
            target: InsertTarget {
                editable: fixed.editable.then(|| (obj.bus.clone(), obj.path.clone())),
                pid: fixed.pid,
            },
        })
    }

    /// The text above the field, read once per field and only when allowed.
    fn visible_text(&mut self, obj: &Obj, field: &FieldSnapshot) -> Option<String> {
        if !self.policy.allows_visible_text(field) {
            return None;
        }
        if let Some((cached, text)) = &self.visible
            && cached == obj
        {
            return text.clone();
        }
        let text = self.capture_visible(obj, field);
        self.visible = Some((obj.clone(), text.clone()));
        text
    }

    fn capture_visible(&self, obj: &Obj, field: &FieldSnapshot) -> Option<String> {
        let field_frame = field.field_frame?;
        let offset = self
            .fixed
            .as_ref()
            .and_then(|(_, fixed)| fixed.window_relative);
        let (coords, place) = placement(offset);
        // The window, and the nearest container with room above the field.
        let mut cursor = self.bus.parent(obj);
        let mut scope: Option<(Obj, Rect)> = None;
        let mut window: Option<(Obj, Rect)> = None;
        for _ in 0..32 {
            let Some(node) = cursor else { break };
            let frame = self.bus.extents(&node, coords).map(place);
            let node_role = self.bus.role(&node).unwrap_or(0);
            if scope.is_none()
                && let Some(frame) = frame
                && frame.contains_rect(&field_frame)
                && field_frame.y - frame.y >= 64.0
            {
                scope = Some((node.clone(), frame));
            }
            if matches!(node_role, role::FRAME | role::WINDOW | role::DIALOG) {
                window = frame.map(|frame| (node.clone(), frame));
                break;
            }
            cursor = self.bus.parent(&node);
        }
        let (_, window_frame) = window?;
        let (scope, scope_frame) = scope?;
        let mut source = AtspiSource {
            bus: &self.bus,
            offset,
            started: Instant::now(),
        };
        visible::capture(
            &mut source,
            &visible::Target {
                scope,
                scope_frame,
                window_frame,
                field: obj.clone(),
                field_frame,
            },
        )
    }
}

/// The visible-context walk over AT-SPI.
struct AtspiSource<'a> {
    bus: &'a Bus,
    offset: Option<(f32, f32)>,
    started: Instant,
}

impl VisibleSource for AtspiSource<'_> {
    type Id = Obj;

    fn node(&mut self, id: &Obj) -> Option<visible::Node> {
        let role = self.bus.role(id)?;
        let states = self.bus.states(id).unwrap_or(0);
        let editable = state::has(states, state::EDITABLE);
        let kind = match role {
            _ if editable => NodeKind::Excluded,
            role::PASSWORD_TEXT | role::TEXT | role::ENTRY | role::COMBO_BOX => NodeKind::Excluded,
            role::TOOL_BAR
            | role::MENU_BAR
            | role::MENU
            | role::POPUP_MENU
            | role::TREE
            | role::TREE_TABLE => NodeKind::Excluded,
            role::LABEL | role::STATIC | role::PARAGRAPH | role::HEADING | role::CAPTION => {
                NodeKind::StaticText
            }
            role::LINK => NodeKind::Link,
            role::SCROLL_PANE
            | role::VIEWPORT
            | role::DOCUMENT_WEB
            | role::DOCUMENT_FRAME
            | role::DOCUMENT_TEXT
            | role::FRAME
            | role::WINDOW
            | role::DIALOG => NodeKind::ClippingContainer,
            _ => NodeKind::Container,
        };
        let (coords, place) = placement(self.offset);
        let frame = self.bus.extents(id, coords).map(place);
        Some(visible::Node {
            kind,
            frame,
            hidden: !state::has(states, state::SHOWING) && !state::has(states, state::VISIBLE),
        })
    }

    fn children(&mut self, id: &Obj) -> Vec<Obj> {
        self.bus.children(id)
    }

    fn text(&mut self, id: &Obj) -> Option<String> {
        let name = self.bus.name(id);
        if !name.trim().is_empty() {
            return Some(name);
        }
        let count = self.bus.character_count(id)?;
        self.bus.text(id, 0, count.min(8_001))
    }

    fn within_budget(&self) -> bool {
        self.started.elapsed() < VISIBLE_BUDGET
    }
}

/// Characters (code points) taken by the last `graphemes` grapheme clusters
/// of `text`, or the first ones when `from_start`.
fn chars_in_graphemes(text: &str, graphemes: usize, from_start: bool) -> usize {
    if from_start {
        text.graphemes(true)
            .take(graphemes)
            .map(|g| g.chars().count())
            .sum()
    } else {
        text.graphemes(true)
            .rev()
            .take(graphemes)
            .map(|g| g.chars().count())
            .sum()
    }
}

/// Types an accepted chunk at the caret: `EditableText` when the field has
/// it, else XTest keystrokes into the window in front, which must belong to
/// the field's app.
pub(super) fn insert(field: &FieldSnapshot, edit: &Edit) -> anyhow::Result<()> {
    if let Some((bus_name, path)) = &field.target.editable {
        match insert_editable(&Obj::new(bus_name.clone(), path.clone()), edit) {
            Ok(()) => return Ok(()),
            Err(err) => log::debug!("autocomplete: EditableText failed, typing instead: {err:#}"),
        }
    }
    let mut display = super::x11::Display::new();
    let front = display.active_window().and_then(|w| w.pid);
    anyhow::ensure!(
        front.is_none_or(|pid| pid == field.target.pid),
        "the field's app is no longer in front"
    );
    // The grabbed Tab must be up, or the keystrokes would come back to us.
    super::x11::wait_for_grabbed_key_release(Duration::from_millis(400));
    super::x11::tap_keys(super::x11::XK_BACKSPACE, edit.backward)?;
    super::x11::tap_keys(super::x11::XK_DELETE, edit.forward)?;
    if !edit.text.is_empty() {
        // Tabs would be taken by our own grab; a suggestion never needs one.
        let text = edit.text.replace('\t', " ");
        anyhow::ensure!(
            crate::insert::type_keystrokes(&text)?,
            "this session cannot type into other apps"
        );
    }
    Ok(())
}

fn insert_editable(obj: &Obj, edit: &Edit) -> anyhow::Result<()> {
    let bus = Bus::connect()?;
    let states = bus.states(obj).context("the field is gone")?;
    anyhow::ensure!(
        state::has(states, state::FOCUSED),
        "the field no longer has focus"
    );
    let mut caret = bus.caret_offset(obj).context("no caret")?;
    if edit.backward > 0 {
        let start = (caret - 256).max(0);
        let before = bus
            .text(obj, start, caret)
            .context("no text before the caret")?;
        let chars = chars_in_graphemes(&before, edit.backward, false) as i32;
        let deleted: bool = bus.call(obj, EDITABLE_TEXT, "DeleteText", &(caret - chars, caret))?;
        anyhow::ensure!(deleted, "the field refused the deletion");
        caret -= chars;
    }
    if edit.forward > 0 {
        let count = bus.character_count(obj).unwrap_or(caret);
        let after = bus
            .text(obj, caret, (caret + 256).min(count))
            .unwrap_or_default();
        let chars = chars_in_graphemes(&after, edit.forward, true) as i32;
        let deleted: bool = bus.call(obj, EDITABLE_TEXT, "DeleteText", &(caret, caret + chars))?;
        anyhow::ensure!(deleted, "the field refused the deletion");
    }
    if edit.text.is_empty() {
        return Ok(());
    }
    let length = edit.text.chars().count() as i32;
    let inserted: bool = bus.call(
        obj,
        EDITABLE_TEXT,
        "InsertText",
        &(caret, edit.text.as_str(), length),
    )?;
    anyhow::ensure!(inserted, "the field refused the text");
    // Some toolkits leave the caret before text inserted at it.
    if bus.caret_offset(obj) == Some(caret) {
        let _: Result<bool, _> = bus.call(obj, TEXT, "SetCaretOffset", &(caret + length,));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn missing_rects_are_none() {
        assert_eq!(rect(0, 0, 0, 0), None);
        assert_eq!(rect(-1, -1, -1, -1), None);
        assert_eq!(rect(10, 20, 0, 18), Some(Rect::new(10.0, 20.0, 0.0, 18.0)));
    }

    #[test]
    fn grapheme_counts_become_character_counts() {
        assert_eq!(chars_in_graphemes("abc", 2, false), 2);
        // "é" as e + combining acute is one grapheme of two characters.
        assert_eq!(chars_in_graphemes("caf\u{65}\u{301}", 1, false), 2);
        assert_eq!(chars_in_graphemes("\u{1F44D}\u{1F3FD} ok", 1, true), 2);
    }

    #[test]
    fn objects_from_pairs() {
        let null = (
            "org.a11y.atspi.Registry".to_string(),
            OwnedObjectPath::try_from("/org/a11y/atspi/null").unwrap(),
        );
        assert!(Obj::from_pair(null).is_none());
        let real = (
            ":1.5".to_string(),
            OwnedObjectPath::try_from("/org/a11y/atspi/accessible/7").unwrap(),
        );
        assert_eq!(
            Obj::from_pair(real).unwrap().key(),
            ":1.5/org/a11y/atspi/accessible/7"
        );
    }
}
