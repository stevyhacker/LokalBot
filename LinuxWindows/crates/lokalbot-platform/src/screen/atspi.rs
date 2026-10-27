//! Linux: visible text and secure-field state through AT-SPI, the counterpart
//! of `ScreenAccessibilityReader.resolve`.
//!
//! The reader asks the session bus where the accessibility bus is
//! (`org.a11y.Bus.GetAddress`), finds the app that owns the focused window by
//! its process and walks that window breadth-first. It never changes
//! accessibility settings (`org.a11y.Status`), so apps that build their tree
//! only for a running screen reader (Chromium, Qt) usually report nothing.

use std::collections::{HashMap, HashSet, VecDeque};
use std::time::{Duration, Instant};

use zbus::blocking::Connection;
use zbus::zvariant::{OwnedObjectPath, OwnedValue};

use super::privacy::{page_address, sanitized_document_name, settled_focus};
use super::{
    AccessibleWindow, FocusedWindow, MAX_CHARACTERS, MAX_CHILDREN, MAX_NODES, TextRead, TextReader,
    WindowRect, append_text,
};

/// Each call gives up after this long, so a wedged app costs one timeout.
const CALL_TIMEOUT: Duration = Duration::from_millis(250);
/// Whole text is read only from small, fully visible elements whose visible
/// range cannot be computed.
const MAX_WHOLE_TEXT: i32 = 2_000;
/// `ScreenAccessibilityReader.visibleText` caps a visible range.
const MAX_RANGE: i32 = 24_000;

const ROOT: &str = "/org/a11y/atspi/accessible/root";
const NULL_PATH: &str = "/org/a11y/atspi/null";
const REGISTRY: &str = "org.a11y.atspi.Registry";
const ACCESSIBLE: &str = "org.a11y.atspi.Accessible";
const APPLICATION: &str = "org.a11y.atspi.Application";
const COMPONENT: &str = "org.a11y.atspi.Component";
const TEXT: &str = "org.a11y.atspi.Text";
const DOCUMENT: &str = "org.a11y.atspi.Document";

/// `AtspiCoordType`.
const COORD_SCREEN: u32 = 0;
const COORD_WINDOW: u32 = 1;

/// `AtspiRole` values from at-spi2-core's `atspi-constants.h` (2.52).
mod role {
    pub const ALERT: u32 = 2;
    pub const CHECK_BOX: u32 = 7;
    pub const CHECK_MENU_ITEM: u32 = 8;
    pub const COLUMN_HEADER: u32 = 10;
    pub const COMBO_BOX: u32 = 11;
    pub const DIALOG: u32 = 16;
    pub const FRAME: u32 = 23;
    pub const INTERNAL_FRAME: u32 = 28;
    pub const LABEL: u32 = 29;
    pub const LIST_ITEM: u32 = 32;
    pub const MENU: u32 = 33;
    pub const MENU_ITEM: u32 = 35;
    pub const PAGE_TAB: u32 = 37;
    pub const PASSWORD_TEXT: u32 = 40;
    pub const PUSH_BUTTON: u32 = 43;
    pub const RADIO_BUTTON: u32 = 44;
    pub const RADIO_MENU_ITEM: u32 = 45;
    pub const ROW_HEADER: u32 = 47;
    pub const SCROLL_PANE: u32 = 49;
    pub const TABLE_CELL: u32 = 56;
    pub const TABLE_COLUMN_HEADER: u32 = 57;
    pub const TABLE_ROW_HEADER: u32 = 58;
    pub const TERMINAL: u32 = 60;
    pub const TEXT: u32 = 61;
    pub const TOGGLE_BUTTON: u32 = 62;
    pub const VIEWPORT: u32 = 68;
    pub const WINDOW: u32 = 69;
    pub const PARAGRAPH: u32 = 73;
    pub const AUTOCOMPLETE: u32 = 76;
    pub const EDITBAR: u32 = 77;
    pub const ENTRY: u32 = 79;
    pub const CAPTION: u32 = 81;
    pub const DOCUMENT_FRAME: u32 = 82;
    pub const HEADING: u32 = 83;
    pub const SECTION: u32 = 85;
    pub const LINK: u32 = 88;
    pub const TREE_ITEM: u32 = 91;
    pub const DOCUMENT_SPREADSHEET: u32 = 92;
    pub const DOCUMENT_PRESENTATION: u32 = 93;
    pub const DOCUMENT_TEXT: u32 = 94;
    pub const DOCUMENT_WEB: u32 = 95;
    pub const DOCUMENT_EMAIL: u32 = 96;
    pub const COMMENT: u32 = 97;
    pub const BLOCK_QUOTE: u32 = 105;
    pub const DEFINITION: u32 = 108;
    pub const STATIC: u32 = 116;
    pub const DESCRIPTION_TERM: u32 = 122;
    pub const DESCRIPTION_VALUE: u32 = 123;
    pub const FOOTNOTE: u32 = 124;
    pub const PUSH_BUTTON_MENU: u32 = 129;
}

/// `AtspiStateType` bits from `atspi-constants.h`; `GetState` returns them as
/// two 32-bit words.
mod state {
    pub const ACTIVE: u32 = 1;
    pub const DEFUNCT: u32 = 6;
    pub const EDITABLE: u32 = 7;
    pub const FOCUSED: u32 = 12;
    pub const MULTI_LINE: u32 = 17;
    pub const SHOWING: u32 = 25;
    pub const MANAGES_DESCENDANTS: u32 = 31;
}

fn has_state(words: &[u32], state: u32) -> bool {
    words
        .get((state / 32) as usize)
        .is_some_and(|word| word & (1 << (state % 32)) != 0)
}

/// Text views and fields whose visible character range is read
/// (`kAXVisibleCharacterRangeAttribute`). Password fields are never read.
fn is_text_view(role: u32) -> bool {
    matches!(
        role,
        role::TEXT
            | role::ENTRY
            | role::PARAGRAPH
            | role::TERMINAL
            | role::DOCUMENT_TEXT
            | role::SECTION
            | role::BLOCK_QUOTE
            | role::COMMENT
            | role::DEFINITION
            | role::DESCRIPTION_TERM
            | role::DESCRIPTION_VALUE
            | role::FOOTNOTE
            | role::EDITBAR
            | role::AUTOCOMPLETE
    )
}

/// Labels and controls that show their name, read only when fully visible
/// (`ScreenVisibleTextPolicy` labels).
fn is_label(role: u32) -> bool {
    is_window(role)
        || matches!(
            role,
            role::LABEL
                | role::STATIC
                | role::CAPTION
                | role::HEADING
                | role::LINK
                | role::LIST_ITEM
                | role::TABLE_CELL
                | role::TREE_ITEM
                | role::COLUMN_HEADER
                | role::ROW_HEADER
                | role::TABLE_COLUMN_HEADER
                | role::TABLE_ROW_HEADER
                | role::PUSH_BUTTON
                | role::TOGGLE_BUTTON
                | role::PUSH_BUTTON_MENU
                | role::CHECK_BOX
                | role::RADIO_BUTTON
                | role::MENU_ITEM
                | role::CHECK_MENU_ITEM
                | role::RADIO_MENU_ITEM
                | role::PAGE_TAB
        )
}

fn is_window(role: u32) -> bool {
    matches!(
        role,
        role::FRAME | role::DIALOG | role::WINDOW | role::ALERT
    )
}

/// `ScreenAccessibilityReader.isTextEntry`: only an input can hold a secret.
fn is_text_entry(role: u32) -> bool {
    matches!(
        role,
        role::TEXT
            | role::PASSWORD_TEXT
            | role::ENTRY
            | role::COMBO_BOX
            | role::EDITBAR
            | role::AUTOCOMPLETE
            | role::TERMINAL
    )
}

fn is_document(role: u32) -> bool {
    matches!(
        role,
        role::DOCUMENT_FRAME
            | role::DOCUMENT_TEXT
            | role::DOCUMENT_WEB
            | role::DOCUMENT_SPREADSHEET
            | role::DOCUMENT_PRESENTATION
            | role::DOCUMENT_EMAIL
    )
}

/// Containers that clip their descendants (`clipsChildren`).
fn clips_children(role: u32) -> bool {
    is_window(role)
        || matches!(
            role,
            role::SCROLL_PANE
                | role::VIEWPORT
                | role::INTERNAL_FRAME
                | role::DOCUMENT_WEB
                | role::DOCUMENT_FRAME
        )
}

/// `CotypingSecureFieldDetector.isSecure`: a password field, or an element
/// whose name or description names a secret. Labels such as "Password" match
/// too, which keeps their text out; only text entries make the window count
/// as showing a secure field.
fn is_secure(role: u32, labels: &[Option<&str>]) -> bool {
    role == role::PASSWORD_TEXT
        || labels
            .iter()
            .flatten()
            .any(|label| super::privacy::names_a_secret(label))
}

/// How an app's toolkit answers.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Toolkit {
    /// Coordinate type for extents and points.
    coords: u32,
    /// Whether `Text.GetOffsetAtPoint` is worth asking.
    offsets: bool,
    /// Entries that hide their text (a `GtkEntry` without visibility) still
    /// report it in full and as plain text, so no entry is known not to be a
    /// password field.
    reveals_hidden_entries: bool,
}

/// GTK 4 places every element at the origin in screen coordinates, never
/// answers `GetOffsetAtPoint` before 4.16 and returns hidden entry text
/// before 4.20; Chromium answers `GetOffsetAtPoint` only in screen
/// coordinates. So GTK 4 is read in window coordinates, the rest in screen
/// coordinates.
fn toolkit_for(name: &str, version: &str) -> Toolkit {
    let mut numbers = version
        .split('.')
        .map(|part| part.trim().parse::<u32>().unwrap_or(0));
    let major = numbers.next().unwrap_or(0);
    let minor = numbers.next().unwrap_or(0);
    if name.eq_ignore_ascii_case("gtk") && major >= 4 {
        let at_least = |wanted: u32| major > 4 || minor >= wanted;
        Toolkit {
            coords: COORD_WINDOW,
            offsets: at_least(16),
            reveals_hidden_entries: !at_least(20),
        }
    } else {
        Toolkit {
            coords: COORD_SCREEN,
            offsets: true,
            reveals_hidden_entries: false,
        }
    }
}

/// The focus state of the focused elements: any secure one makes it secure,
/// any unknown one unknown.
fn combined_focus(elements: impl IntoIterator<Item = Option<bool>>) -> Option<bool> {
    let mut focus = None;
    for secure in elements {
        match secure {
            Some(true) => return Some(true),
            None => focus = Some(None),
            Some(false) => {
                focus.get_or_insert(Some(false));
            }
        }
    }
    focus.flatten()
}

/// Extents as a rectangle, when they describe one: GTK reports `G_MININT`
/// coordinates for widgets that are not shown, applications report -1 sizes.
fn rect((x, y, width, height): (i32, i32, i32, i32)) -> Option<WindowRect> {
    const LIMIT: i32 = 1 << 24;
    let position = -LIMIT..LIMIT;
    let size = 1..LIMIT;
    (position.contains(&x)
        && position.contains(&y)
        && size.contains(&width)
        && size.contains(&height))
    .then_some(WindowRect {
        x,
        y,
        width: width as u32,
        height: height as u32,
    })
}

/// The part of the window a container's children can show: clipping
/// containers narrow it to their own extents (`clipsChildren`). Unknown
/// extents leave nothing visible below them.
fn child_viewport(
    role: u32,
    frame: Option<WindowRect>,
    viewport: Option<WindowRect>,
) -> Option<WindowRect> {
    if !clips_children(role) {
        return viewport;
    }
    viewport?.intersection(&frame?)
}

/// Points just inside the corners of `rect`.
fn corners(rect: &WindowRect) -> [(i32, i32); 4] {
    let right = rect.x + rect.width as i32 - 1;
    let bottom = rect.y + rect.height as i32 - 1;
    [
        (rect.x, rect.y),
        (right, rect.y),
        (rect.x, bottom),
        (right, bottom),
    ]
}

/// The characters between the offsets found at the corners of the visible
/// rectangle. Toolkits answer -1 where there is no character (GTK past the
/// end of a line, Chromium in padding); a single answer is no range.
fn visible_range(offsets: [i32; 4], count: i32) -> Option<(i32, i32)> {
    let mut valid = offsets
        .into_iter()
        .filter(|offset| (0..=count).contains(offset));
    let first = valid.next()?;
    let (start, last) = valid.fold((first, first), |(start, last), offset| {
        (start.min(offset), last.max(offset))
    });
    (last > start).then(|| (start, (last + 1).min(count).min(start + MAX_RANGE)))
}

/// Text from the Text interface: embedded objects (links, images, frames)
/// appear as U+FFFC and are read as children instead.
fn without_objects(text: String) -> String {
    if text.contains('\u{FFFC}') {
        text.replace('\u{FFFC}', "")
    } else {
        text
    }
}

fn describe(focus: Option<bool>) -> &'static str {
    match focus {
        Some(true) => "secure",
        Some(false) => "plain",
        None => "unknown",
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum CallError {
    /// The app did not answer within `CALL_TIMEOUT`.
    TimedOut,
    /// The connection to the accessibility bus broke.
    Disconnected,
    /// The element is gone or does not support the call.
    Failed,
}

impl From<zbus::Error> for CallError {
    fn from(err: zbus::Error) -> Self {
        match err {
            zbus::Error::InputOutput(io) if io.kind() == std::io::ErrorKind::TimedOut => {
                CallError::TimedOut
            }
            zbus::Error::InputOutput(_) => CallError::Disconnected,
            zbus::Error::MethodError(name, _, _)
                if name.as_str() == "org.freedesktop.DBus.Error.NoReply" =>
            {
                CallError::TimedOut
            }
            _ => CallError::Failed,
        }
    }
}

/// A failure that only means the element lacks what was asked.
fn optional<T>(result: Result<T, CallError>) -> Result<Option<T>, CallError> {
    match result {
        Ok(value) => Ok(Some(value)),
        Err(CallError::Failed) => Ok(None),
        Err(err) => Err(err),
    }
}

fn call<B, R>(
    bus: &Connection,
    destination: &str,
    path: &str,
    interface: &str,
    method: &str,
    body: &B,
) -> Result<R, CallError>
where
    B: serde::Serialize + zbus::zvariant::DynamicType,
    R: serde::de::DeserializeOwned + zbus::zvariant::Type,
{
    let reply = bus.call_method(Some(destination), path, Some(interface), method, body)?;
    reply
        .body()
        .deserialize::<R>()
        .map_err(|_| CallError::Failed)
}

/// An accessible object: its app's bus name and its object path.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
struct Node {
    bus: String,
    path: OwnedObjectPath,
}

impl Node {
    fn new((bus, path): (String, OwnedObjectPath)) -> Option<Self> {
        (!bus.is_empty() && path.as_str() != NULL_PATH).then_some(Self { bus, path })
    }

    fn call<B, R>(
        &self,
        bus: &Connection,
        interface: &str,
        method: &str,
        body: &B,
    ) -> Result<R, CallError>
    where
        B: serde::Serialize + zbus::zvariant::DynamicType,
        R: serde::de::DeserializeOwned + zbus::zvariant::Type,
    {
        call(bus, &self.bus, self.path.as_str(), interface, method, body)
    }

    fn property<T: TryFrom<OwnedValue>>(
        &self,
        bus: &Connection,
        interface: &str,
        name: &str,
    ) -> Result<T, CallError> {
        let value: OwnedValue = self.call(
            bus,
            "org.freedesktop.DBus.Properties",
            "Get",
            &(interface, name),
        )?;
        T::try_from(value).map_err(|_| CallError::Failed)
    }

    fn states(&self, bus: &Connection) -> Result<Vec<u32>, CallError> {
        self.call(bus, ACCESSIBLE, "GetState", &())
    }

    fn name(&self, bus: &Connection) -> Result<String, CallError> {
        self.property(bus, ACCESSIBLE, "Name")
    }

    fn extents(&self, bus: &Connection, coords: u32) -> Result<Option<WindowRect>, CallError> {
        Ok(rect(self.call(bus, COMPONENT, "GetExtents", &coords)?))
    }

    /// Children to visit, at most `MAX_CHILDREN`. Containers that manage
    /// their descendants (large tables) build children on demand, so only
    /// the first ones are asked for.
    fn children(
        &self,
        bus: &Connection,
        manages_descendants: bool,
    ) -> Result<Vec<Node>, CallError> {
        if !manages_descendants {
            let children: Vec<(String, OwnedObjectPath)> =
                optional(self.call(bus, ACCESSIBLE, "GetChildren", &()))?.unwrap_or_default();
            return Ok(children
                .into_iter()
                .take(MAX_CHILDREN)
                .filter_map(Node::new)
                .collect());
        }
        let count: i32 = optional(self.property(bus, ACCESSIBLE, "ChildCount"))?.unwrap_or(0);
        let mut children = Vec::new();
        for index in 0..count.clamp(0, MAX_CHILDREN as i32) {
            if let Some(child) = optional(self.call(bus, ACCESSIBLE, "GetChildAtIndex", &index))? {
                children.extend(Node::new(child));
            }
        }
        Ok(children)
    }
}

/// One element waiting to be read.
struct Pending {
    node: Node,
    /// The part of the window this element can show, `None` when unknown.
    viewport: Option<WindowRect>,
    /// The parent's text was read through the Text interface, which already
    /// holds the text of its static-text children (Chromium).
    parent_text: bool,
}

/// What one walk of a window gathers.
struct Walk {
    bus: Connection,
    toolkit: Toolkit,
    include_text: bool,
    parts: Vec<String>,
    seen: HashSet<String>,
    total: usize,
    /// Web documents' addresses in walk order, outermost first.
    web_urls: Vec<Option<String>>,
    document_name: Option<String>,
    has_web_content: bool,
    contains_secure_field: bool,
    /// Elements with keyboard focus, and whether each is secure (`None` when
    /// that cannot be known).
    focused: Vec<(Node, Option<bool>)>,
}

impl Walk {
    /// Reads one element and returns its children. The window itself (`root`)
    /// is its own viewport and is always entered.
    fn visit(&mut self, pending: &Pending, root: bool) -> Result<Vec<Pending>, CallError> {
        let node = &pending.node;
        let role: u32 = node.call(&self.bus, ACCESSIBLE, "GetRole", &())?;
        let states = optional(node.states(&self.bus))?.unwrap_or_default();
        if has_state(&states, state::DEFUNCT) {
            return Ok(Vec::new());
        }
        let showing = has_state(&states, state::SHOWING);
        let focused = has_state(&states, state::FOCUSED);
        let entry = is_text_entry(role);
        // Nothing below an element outside the visible part of the window
        // can show text.
        let in_view = self.include_text && showing && pending.viewport.is_some();
        let reads_text = in_view
            && (is_text_view(role) || is_label(role))
            && !(role == role::STATIC && pending.parent_text);
        let name = if entry || focused || reads_text {
            optional(node.name(&self.bus))?
        } else {
            None
        };
        let description: Option<String> = if entry || focused {
            optional(node.property(&self.bus, ACCESSIBLE, "Description"))?
        } else {
            None
        };
        let hides_text = self.toolkit.reveals_hidden_entries
            && matches!(role, role::TEXT | role::ENTRY)
            && has_state(&states, state::EDITABLE)
            && !has_state(&states, state::MULTI_LINE);
        // `secureFieldStatus`: text is read only from elements known not to
        // be secure.
        let secure = if is_secure(role, &[name.as_deref(), description.as_deref()]) {
            Some(true)
        } else if hides_text {
            None
        } else {
            Some(false)
        };
        // An entry that may be hiding a password counts as one: with the
        // focus unknown, such a window is not captured (`focusPermitsCapture`).
        if secure != Some(false) && entry {
            self.contains_secure_field = true;
        }
        if focused {
            self.focused.push((node.clone(), secure));
        }
        if is_document(role) {
            self.document(node, role)?;
        }
        let frame = if root {
            pending.viewport
        } else if reads_text || (in_view && clips_children(role)) {
            optional(node.extents(&self.bus, self.toolkit.coords))?.flatten()
        } else {
            None
        };
        let mut text_read = false;
        if reads_text
            && secure == Some(false)
            && let (Some(frame), Some(viewport)) = (frame, pending.viewport)
            && frame.intersection(&viewport).is_some()
        {
            let text = if is_text_view(role) {
                let text = self.visible_text(node, &frame, &viewport)?;
                text_read = text.is_some();
                text
            } else if !viewport.contains(&frame) {
                None
            } else if let Some(name) = name.filter(|name| !name.trim().is_empty()) {
                Some(name)
            } else {
                let text = self.whole_text(node)?;
                text_read = text.is_some();
                text
            };
            if let Some(text) = text {
                append_text(
                    &text,
                    &mut self.parts,
                    &mut self.seen,
                    &mut self.total,
                    MAX_CHARACTERS,
                );
            }
        }
        // A menu's items open in a popup of their own; walking them would
        // spend the node budget on hidden entries (LibreOffice has hundreds).
        if (!showing || role == role::MENU) && !root {
            return Ok(Vec::new());
        }
        let viewport = child_viewport(role, frame, pending.viewport);
        let children = node.children(&self.bus, has_state(&states, state::MANAGES_DESCENDANTS))?;
        Ok(children
            .into_iter()
            .map(|node| Pending {
                node,
                viewport,
                parent_text: text_read,
            })
            .collect())
    }

    /// Web documents give the page address and frames; a document's local
    /// file gives the document name.
    fn document(&mut self, node: &Node, role: u32) -> Result<(), CallError> {
        let url = self.document_url(node)?;
        if self.document_name.is_none()
            && let Some(file) = url.as_deref().filter(|url| url.starts_with("file:"))
        {
            self.document_name = sanitized_document_name(Some(file));
        }
        if role == role::DOCUMENT_WEB {
            self.has_web_content = true;
            self.web_urls.push(url);
        }
        Ok(())
    }

    /// `DocURL` (Firefox, WebKitGTK), else `URI` (Chromium).
    fn document_url(&self, node: &Node) -> Result<Option<String>, CallError> {
        for attribute in ["DocURL", "URI"] {
            let value: Option<String> =
                optional(node.call(&self.bus, DOCUMENT, "GetAttributeValue", &attribute))?;
            if let Some(value) = value.filter(|value| !value.trim().is_empty()) {
                return Ok(Some(value));
            }
        }
        Ok(None)
    }

    /// `ScreenAccessibilityReader.visibleText`: the characters between the
    /// corners of the element's visible part, else the whole text of a small
    /// element that is fully visible. Whole values can hold hidden documents.
    fn visible_text(
        &mut self,
        node: &Node,
        frame: &WindowRect,
        viewport: &WindowRect,
    ) -> Result<Option<String>, CallError> {
        let Some(visible) = frame.intersection(viewport) else {
            return Ok(None);
        };
        let Some(count) = optional(node.property::<i32>(&self.bus, TEXT, "CharacterCount"))?
            .filter(|count| *count > 0)
        else {
            return Ok(None);
        };
        if self.toolkit.offsets {
            let mut offsets = [-1; 4];
            for (offset, (x, y)) in offsets.iter_mut().zip(corners(&visible)) {
                match node.call(
                    &self.bus,
                    TEXT,
                    "GetOffsetAtPoint",
                    &(x, y, self.toolkit.coords),
                ) {
                    Ok(found) => *offset = found,
                    // An app that never answers is not asked again.
                    Err(CallError::TimedOut) => {
                        self.toolkit.offsets = false;
                        break;
                    }
                    Err(CallError::Failed) => break,
                    Err(err) => return Err(err),
                }
            }
            if let Some((start, end)) = visible_range(offsets, count) {
                return optional(self.text(node, start, end));
            }
        }
        if viewport.contains(frame) && count <= MAX_WHOLE_TEXT {
            return optional(self.text(node, 0, count));
        }
        Ok(None)
    }

    /// The text of a fully visible label whose name is empty (Chromium list
    /// items and table cells).
    fn whole_text(&self, node: &Node) -> Result<Option<String>, CallError> {
        match optional(node.property::<i32>(&self.bus, TEXT, "CharacterCount"))? {
            Some(count) if count > 0 && count <= MAX_WHOLE_TEXT => {
                optional(self.text(node, 0, count))
            }
            _ => Ok(None),
        }
    }

    fn text(&self, node: &Node, start: i32, end: i32) -> Result<String, CallError> {
        let text: String = node.call(&self.bus, TEXT, "GetText", &(start, end))?;
        Ok(without_objects(text))
    }

    /// The focus state the walk saw.
    fn focus(&self) -> Option<bool> {
        combined_focus(self.focused.iter().map(|(_, secure)| *secure))
    }

    /// The focus state now: unknown once an element the walk saw focused has
    /// lost focus.
    fn focus_now(&self) -> Result<Option<bool>, CallError> {
        for (node, _) in &self.focused {
            let states = optional(node.states(&self.bus))?;
            if !states.is_some_and(|states| has_state(&states, state::FOCUSED)) {
                return Ok(None);
            }
        }
        Ok(self.focus())
    }
}

/// The window in front, as found among its app's top-level windows.
struct Found {
    app: Node,
    window: Node,
    active: bool,
}

pub(super) struct AtspiReader {
    bus: Option<Connection>,
    /// The process of each app on the accessibility bus. Unique bus names
    /// are never reused, so an entry stays right until its app leaves.
    pids: HashMap<String, u32>,
    toolkits: HashMap<String, Toolkit>,
}

impl AtspiReader {
    pub(super) fn new() -> Self {
        Self {
            bus: None,
            pids: HashMap::new(),
            toolkits: HashMap::new(),
        }
    }

    /// The accessibility bus, connected on first use and again after errors.
    fn bus(&mut self) -> Result<Connection, String> {
        if let Some(bus) = &self.bus {
            return Ok(bus.clone());
        }
        let session = zbus::blocking::connection::Builder::session()
            .and_then(|builder| builder.method_timeout(CALL_TIMEOUT).build())
            .map_err(|err| format!("no session bus: {err}"))?;
        let address = accessibility_bus_address(&session)?;
        let bus = zbus::blocking::connection::Builder::address(address.as_str())
            .and_then(|builder| builder.method_timeout(CALL_TIMEOUT).build())
            .map_err(|err| format!("could not connect to the accessibility bus: {err}"))?;
        self.bus = Some(bus.clone());
        Ok(bus)
    }

    fn disconnect(&mut self) {
        self.bus = None;
    }

    /// The root objects of the registered apps that belong to `pid`.
    fn apps(&mut self, bus: &Connection, pid: u32) -> Result<Vec<Node>, CallError> {
        let registered: Vec<(String, OwnedObjectPath)> =
            call(bus, REGISTRY, ROOT, ACCESSIBLE, "GetChildren", &())?;
        let names: HashSet<&str> = registered.iter().map(|(name, _)| name.as_str()).collect();
        self.pids.retain(|name, _| names.contains(name.as_str()));
        self.toolkits
            .retain(|name, _| names.contains(name.as_str()));
        let mut apps = Vec::new();
        for app in registered.into_iter().filter_map(Node::new) {
            let app_pid = match self.pids.get(&app.bus) {
                Some(pid) => Some(*pid),
                None => {
                    let found: Option<u32> = optional(call(
                        bus,
                        "org.freedesktop.DBus",
                        "/org/freedesktop/DBus",
                        "org.freedesktop.DBus",
                        "GetConnectionUnixProcessID",
                        &app.bus.as_str(),
                    ))?;
                    if let Some(found) = found {
                        self.pids.insert(app.bus.clone(), found);
                    }
                    found
                }
            };
            if app_pid == Some(pid) && !apps.contains(&app) {
                apps.push(app);
            }
        }
        Ok(apps)
    }

    /// The top-level window that is in front: the one with the ACTIVE state,
    /// else the only one titled like the focused window (GTK 4 marks no
    /// window active).
    fn find_window(
        bus: &Connection,
        apps: &[Node],
        title: &str,
    ) -> Result<Result<Found, String>, CallError> {
        let mut showing = Vec::new();
        for app in apps {
            for window in app.children(bus, false)? {
                let states = optional(window.states(bus))?.unwrap_or_default();
                if has_state(&states, state::DEFUNCT) {
                    continue;
                }
                if has_state(&states, state::ACTIVE) {
                    return Ok(Ok(Found {
                        app: app.clone(),
                        window,
                        active: true,
                    }));
                }
                if has_state(&states, state::SHOWING) {
                    showing.push((app, window));
                }
            }
        }
        if title.trim().is_empty() {
            return Ok(Err("no window of the app is active".into()));
        }
        let mut titled = Vec::new();
        for (app, window) in showing {
            if optional(window.name(bus))?.as_deref() == Some(title) {
                titled.push((app, window));
            }
        }
        Ok(match titled.len() {
            0 => Err("no window of the app is active or has the window's title".into()),
            1 => {
                let (app, window) = titled.remove(0);
                Ok(Found {
                    app: app.clone(),
                    window,
                    active: false,
                })
            }
            _ => Err("several windows of the app have the window's title".into()),
        })
    }

    fn toolkit(&mut self, bus: &Connection, app: &Node) -> Result<Toolkit, CallError> {
        if let Some(toolkit) = self.toolkits.get(&app.bus) {
            return Ok(*toolkit);
        }
        let name: Option<String> = optional(app.property(bus, APPLICATION, "ToolkitName"))?;
        let version: Option<String> = optional(app.property(bus, APPLICATION, "Version"))?;
        let found = toolkit_for(
            name.as_deref().unwrap_or(""),
            version.as_deref().unwrap_or(""),
        );
        self.toolkits.insert(app.bus.clone(), found);
        Ok(found)
    }

    fn read_window(
        &mut self,
        window: &FocusedWindow,
        pid: u32,
        include_text: bool,
        end: Instant,
    ) -> Result<TextRead, CallError> {
        let bus = match self.bus() {
            Ok(bus) => bus,
            Err(reason) => return Ok(TextRead::Unavailable(reason)),
        };
        let apps = match self.apps(&bus, pid) {
            Ok(apps) => apps,
            Err(CallError::TimedOut) => return Err(CallError::TimedOut),
            Err(_) => {
                self.disconnect();
                return Ok(TextRead::Unavailable(
                    "the accessibility registry did not answer".into(),
                ));
            }
        };
        if apps.is_empty() {
            return Ok(TextRead::Unavailable(
                "the app exposes no accessibility tree".into(),
            ));
        }
        if Instant::now() >= end {
            return Err(CallError::TimedOut);
        }
        let found = match Self::find_window(&bus, &apps, &window.title)? {
            Ok(found) => found,
            Err(reason) => return Ok(TextRead::Unavailable(reason)),
        };
        let toolkit = self.toolkit(&bus, &found.app)?;
        let title = optional(found.window.name(&bus))?;
        let extents = if include_text {
            optional(found.window.extents(&bus, toolkit.coords))?.flatten()
        } else {
            None
        };
        if Instant::now() >= end {
            return Err(CallError::TimedOut);
        }

        let mut walk = Walk {
            bus: bus.clone(),
            toolkit,
            include_text,
            parts: Vec::new(),
            seen: HashSet::new(),
            total: 0,
            web_urls: Vec::new(),
            document_name: None,
            has_web_content: false,
            contains_secure_field: false,
            focused: Vec::new(),
        };
        let mut queue = VecDeque::from([Pending {
            node: found.window.clone(),
            viewport: extents,
            parent_text: false,
        }]);
        let mut visited: HashSet<Node> = HashSet::new();
        while let Some(pending) = queue.pop_front() {
            let root = visited.is_empty();
            if !root
                && (visited.len() >= MAX_NODES
                    || walk.total >= MAX_CHARACTERS
                    || Instant::now() >= end)
            {
                break;
            }
            if !visited.insert(pending.node.clone()) {
                continue;
            }
            match walk.visit(&pending, root) {
                Ok(children) => queue.extend(children),
                Err(CallError::Failed) => {}
                Err(err) => return Err(err),
            }
        }
        if walk.toolkit != toolkit {
            self.toolkits.insert(found.app.bus.clone(), walk.toolkit);
        }

        // Calls race the app: never attach one window's text to another
        // window or to a different focus (`resolve`'s final checks).
        let Some(states) = optional(found.window.states(&bus))? else {
            return Ok(TextRead::Changed("window closed during read".into()));
        };
        if has_state(&states, state::DEFUNCT) {
            return Ok(TextRead::Changed("window closed during read".into()));
        }
        if found.active && !has_state(&states, state::ACTIVE) {
            return Ok(TextRead::Changed(
                "focused window changed during read".into(),
            ));
        }
        if optional(found.window.name(&bus))? != title {
            return Ok(TextRead::Changed("window title changed during read".into()));
        }
        if include_text
            && optional(found.window.extents(&bus, toolkit.coords))?.flatten() != extents
        {
            return Ok(TextRead::Changed("window frame changed during read".into()));
        }
        let before = walk.focus();
        let after = walk.focus_now()?;
        let (accepted, focus) = settled_focus(before, after);
        if !accepted {
            return Ok(TextRead::Changed(format!(
                "focused-field state changed during read ({} to {})",
                describe(before),
                describe(after)
            )));
        }

        let address = page_address(None, &walk.web_urls);
        Ok(TextRead::Read(AccessibleWindow {
            text: walk.parts.join("\n"),
            source_url: address.source_url,
            document_name: walk.document_name,
            focused_secure_field: focus,
            window_title: title.map(|name| {
                if name.is_empty() {
                    window.title.clone()
                } else {
                    name
                }
            }),
            has_web_content: walk.has_web_content,
            contains_secure_field: walk.contains_secure_field,
            framed_urls: address.framed_urls,
            has_unattributed_web_content: address.has_unattributed_web_content,
        }))
    }
}

/// `org.a11y.Bus.GetAddress`, asked only while the bus launcher runs: asking
/// an unowned name would start it.
fn accessibility_bus_address(session: &Connection) -> Result<String, String> {
    let owned: bool = call(
        session,
        "org.freedesktop.DBus",
        "/org/freedesktop/DBus",
        "org.freedesktop.DBus",
        "NameHasOwner",
        &"org.a11y.Bus",
    )
    .map_err(|err| format!("the session bus did not answer ({err:?})"))?;
    if !owned {
        return Err("the accessibility bus is not running".into());
    }
    call(
        session,
        "org.a11y.Bus",
        "/org/a11y/bus",
        "org.a11y.Bus",
        "GetAddress",
        &(),
    )
    .map_err(|err| format!("the accessibility bus has no address ({err:?})"))
}

impl TextReader for AtspiReader {
    fn read(&mut self, window: &FocusedWindow, include_text: bool, deadline: Duration) -> TextRead {
        let Some(pid) = window.pid else {
            return TextRead::Unavailable("the window's process is not known".into());
        };
        // LokalBot never records its own windows.
        if pid == std::process::id() {
            return TextRead::Unavailable("LokalBot's own window".into());
        }
        let end = Instant::now() + deadline;
        match self.read_window(window, pid, include_text, end) {
            Ok(read) => read,
            Err(CallError::TimedOut) => TextRead::TimedOut,
            Err(CallError::Disconnected) => {
                self.disconnect();
                TextRead::Unavailable("the accessibility bus closed".into())
            }
            Err(CallError::Failed) => TextRead::Changed("window closed during read".into()),
        }
    }

    fn name(&self) -> &'static str {
        "atspi"
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rect_at(x: i32, y: i32, width: u32, height: u32) -> WindowRect {
        WindowRect {
            x,
            y,
            width,
            height,
        }
    }

    #[test]
    fn state_bits_span_both_words() {
        // GTK 4's focused, read-only text view: [1124210688, 3072].
        let words = [1_124_210_688, 3_072];
        assert!(has_state(&words, state::FOCUSED));
        assert!(has_state(&words, state::SHOWING));
        assert!(!has_state(&words, state::ACTIVE));
        assert!(has_state(&words, 43), "READ_ONLY is in the second word");
        assert!(!has_state(&words, 44));
        assert!(!has_state(&[], state::SHOWING));
        assert!(has_state(&[1 << state::ACTIVE], state::ACTIVE));
    }

    #[test]
    fn roles_are_classified_like_the_mac() {
        for text in [role::TEXT, role::ENTRY, role::PARAGRAPH, role::TERMINAL] {
            assert!(is_text_view(text), "{text}");
        }
        for label in [
            role::LABEL,
            role::STATIC,
            role::PUSH_BUTTON,
            role::LINK,
            role::FRAME,
            role::PAGE_TAB,
        ] {
            assert!(is_label(label), "{label}");
            assert!(!is_text_view(label), "{label}");
        }
        assert!(
            !is_text_view(role::PASSWORD_TEXT),
            "password text is never read"
        );
        assert!(is_text_entry(role::PASSWORD_TEXT) && is_text_entry(role::ENTRY));
        assert!(!is_text_entry(role::LABEL), "labels cannot hold a secret");
        assert!(is_document(role::DOCUMENT_WEB) && !is_document(role::SECTION));
        for clipper in [
            role::FRAME,
            role::SCROLL_PANE,
            role::VIEWPORT,
            role::DOCUMENT_WEB,
        ] {
            assert!(clips_children(clipper), "{clipper}");
        }
        assert!(!clips_children(39), "panels do not clip");
    }

    #[test]
    fn secure_fields_follow_role_and_markers() {
        assert!(is_secure(role::PASSWORD_TEXT, &[None, None]));
        assert!(is_secure(role::ENTRY, &[Some("Card number"), None]));
        assert!(is_secure(
            role::ENTRY,
            &[Some("Code"), Some("Enter the one-time code")]
        ));
        assert!(
            is_secure(role::LABEL, &[Some("Password:")]),
            "labels stay out of the text"
        );
        assert!(!is_secure(role::ENTRY, &[Some("Search"), Some("")]));
        assert!(!is_secure(role::TEXT, &[]));
    }

    #[test]
    fn toolkits_pick_working_coordinates() {
        assert_eq!(
            toolkit_for("gtk", "3.24.41"),
            Toolkit {
                coords: COORD_SCREEN,
                offsets: true,
                reveals_hidden_entries: false,
            }
        );
        assert_eq!(
            toolkit_for("GTK", "4.14.5"),
            Toolkit {
                coords: COORD_WINDOW,
                offsets: false,
                reveals_hidden_entries: true,
            }
        );
        let gtk_4_16 = toolkit_for("GTK", "4.16.2");
        assert!(gtk_4_16.offsets && gtk_4_16.reveals_hidden_entries);
        assert!(!toolkit_for("GTK", "4.20.0").reveals_hidden_entries);
        assert_eq!(toolkit_for("GTK", "5.0").coords, COORD_WINDOW);
        assert_eq!(toolkit_for("Chromium", "153.0").coords, COORD_SCREEN);
        assert_eq!(toolkit_for("", "").coords, COORD_SCREEN);
    }

    #[test]
    fn focus_is_secure_or_unknown_when_any_element_is() {
        assert_eq!(combined_focus([]), None, "nothing focused");
        assert_eq!(combined_focus([Some(false)]), Some(false));
        assert_eq!(combined_focus([Some(false), Some(true)]), Some(true));
        assert_eq!(combined_focus([Some(false), None]), None);
        assert_eq!(combined_focus([None, Some(false)]), None);
        assert_eq!(combined_focus([None, Some(true)]), Some(true));
    }

    #[test]
    fn extents_without_a_rectangle_are_dropped() {
        assert_eq!(rect((5, 29, 700, 19)), Some(rect_at(5, 29, 700, 19)));
        assert_eq!(
            rect((i32::MIN, i32::MIN, 700, 19)),
            None,
            "GTK's hidden widgets"
        );
        assert_eq!(rect((-1, -1, -1, -1)), None);
        assert_eq!(rect((0, 0, 0, 30)), None);
        assert_eq!(rect((-20, 10, 30, 30)), Some(rect_at(-20, 10, 30, 30)));
    }

    #[test]
    fn clipping_containers_narrow_the_viewport() {
        let window = Some(rect_at(0, 0, 710, 594));
        let pane = Some(rect_at(5, 290, 700, 120));
        let viewport = child_viewport(role::SCROLL_PANE, pane, window);
        assert_eq!(viewport, pane);
        assert_eq!(
            child_viewport(39, Some(rect_at(0, 0, 2000, 2000)), viewport),
            viewport
        );
        assert_eq!(child_viewport(role::SCROLL_PANE, None, window), None);
        assert_eq!(
            child_viewport(role::VIEWPORT, Some(rect_at(900, 0, 10, 10)), window),
            None
        );
        // A row cut by the pane is not fully visible, so its label stays out.
        let viewport = viewport.expect("the pane is inside the window");
        assert!(viewport.contains(&rect_at(5, 366, 700, 19)));
        assert!(!viewport.contains(&rect_at(5, 404, 700, 19)));
        assert!(viewport.intersection(&rect_at(5, 404, 700, 19)).is_some());
    }

    #[test]
    fn corners_lie_inside_the_rectangle() {
        let visible = rect_at(5, 134, 700, 150);
        assert_eq!(
            corners(&visible),
            [(5, 134), (704, 134), (5, 283), (704, 283)]
        );
        for (x, y) in corners(&visible) {
            assert!(visible.contains(&rect_at(x, y, 1, 1)));
        }
    }

    #[test]
    fn visible_ranges_come_from_the_corners() {
        // A scrolled GTK 3 text view: lines 1 to 8 of 200.
        assert_eq!(visible_range([0, 34, 245, 279], 6_999), Some((0, 280)));
        // A GTK 3 entry or label answers -1 right of its text: no range.
        assert_eq!(visible_range([0, -1, 0, -1], 16), None);
        // A Chromium static text, every corner on a glyph.
        assert_eq!(visible_range([0, 18, 0, 18], 19), Some((0, 19)));
        assert_eq!(visible_range([-1; 4], 19), None);
        assert_eq!(
            visible_range([40, 3, 900, 12], 20),
            Some((3, 13)),
            "out-of-range offsets are ignored"
        );
        assert_eq!(visible_range([20, 20, 20, 20], 20), None);
        assert_eq!(
            visible_range([0, 100_000, 0, 100_000], 200_000),
            Some((0, MAX_RANGE))
        );
    }

    #[test]
    fn own_and_unknown_processes_are_not_read() {
        let mut reader = AtspiReader::new();
        let unknown = FocusedWindow::default();
        assert!(matches!(
            reader.read(&unknown, true, Duration::from_millis(50)),
            TextRead::Unavailable(_)
        ));
        let own = FocusedWindow {
            pid: Some(std::process::id()),
            title: "LokalBot".into(),
            ..Default::default()
        };
        assert!(matches!(
            reader.read(&own, true, Duration::from_millis(50)),
            TextRead::Unavailable(_)
        ));
        assert!(reader.bus.is_none(), "neither read touches the bus");
    }

    #[test]
    fn embedded_objects_are_removed() {
        assert_eq!(
            without_objects("First paragraph with a \u{FFFC} inside it.".into()),
            "First paragraph with a  inside it."
        );
        assert_eq!(without_objects("plain".into()), "plain");
    }

    /// Reads the window in front of a desktop session, for example a GTK
    /// window with known text, or a password dialog with a typed password:
    ///
    /// ```text
    /// LOKALBOT_ATSPI_EXPECT="Visible label alpha" \
    ///   cargo test -p lokalbot-platform atspi -- --ignored --nocapture
    /// LOKALBOT_ATSPI_SECRET="hunter2" \
    ///   cargo test -p lokalbot-platform atspi -- --ignored --nocapture
    /// ```
    #[test]
    #[ignore = "needs a desktop session with an accessible window in front"]
    fn reads_the_window_in_front() {
        let mut capture = super::super::window_capture();
        let window = match capture.focused() {
            Ok(Some(window)) => window,
            other => panic!("no window in front: {other:?}"),
        };
        let mut reader = AtspiReader::new();
        let read = reader.read(&window, true, Duration::from_millis(400));
        println!("{window:?}\n{read:#?}");
        let TextRead::Read(snapshot) = read else {
            panic!("not read");
        };
        assert!(snapshot.window_title.is_some());
        if let Ok(expected) = std::env::var("LOKALBOT_ATSPI_EXPECT") {
            assert!(snapshot.text.contains(&expected), "missing {expected:?}");
        }
        // A password typed into the window: never in the text, and the window
        // shows a secure field or its focus is not known to be plain.
        if let Ok(secret) = std::env::var("LOKALBOT_ATSPI_SECRET") {
            assert!(!snapshot.text.contains(&secret), "read a password");
            assert!(snapshot.contains_secure_field || snapshot.focused_secure_field != Some(false));
        }
        let metadata = reader.read(&window, false, Duration::from_millis(400));
        let TextRead::Read(metadata) = metadata else {
            panic!("metadata not read: {metadata:?}");
        };
        assert!(metadata.text.is_empty());
        assert_eq!(metadata.focused_secure_field, snapshot.focused_secure_field);
    }
}
