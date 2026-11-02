//! One-shot reads of the focused object for dictation and selection actions,
//! separate from the watcher: identity and privacy, the selection, the text
//! before the caret, and the text above the field.

use std::collections::{HashMap, VecDeque};
use std::time::{Duration, Instant};

use zbus::zvariant::OwnedObjectPath;

use super::super::focused::{Field, FieldRead, SelectionRead};
use super::super::policy::{self, ReadPolicy};
use super::super::visible;
use super::super::{FieldSnapshot, Rect};
use super::{
    AtspiSource, Bus, COLLECTION, DOCUMENT, EDITABLE_TEXT, Obj, REGISTRY, ROOT_PATH, TEXT,
    placement, role, state,
};

/// `ATSPI_STATE_ACTIVE`: the window with the keyboard.
const ACTIVE: u32 = 1;
/// How far the walk looks for a selection in read-only content.
const SELECTION_WALK_NODES: usize = 400;
const SELECTION_WALK_TIME: Duration = Duration::from_millis(250);

enum Located {
    /// The bus is unreachable or the app publishes nothing.
    Silent,
    NoFocus,
    Focused(Obj, u32),
}

/// The focused descendant of an app: one `Collection` query when the toolkit
/// supports it, else a short walk through showing objects.
fn find_focused(bus: &Bus, app: &Obj) -> Option<Obj> {
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
    if let Ok(found) = bus.call::<Vec<(String, OwnedObjectPath)>>(
        app,
        COLLECTION,
        "GetMatches",
        &(rule, 0u32, 1i32, true),
    ) && let Some(obj) = found.into_iter().find_map(Obj::from_pair)
    {
        return Some(obj);
    }
    let started = Instant::now();
    let mut queue = VecDeque::from([app.clone()]);
    let mut seen = 0;
    while let Some(obj) = queue.pop_front() {
        if seen > 400 || started.elapsed() > Duration::from_millis(150) {
            break;
        }
        seen += 1;
        let states = bus.states(&obj).unwrap_or(0);
        if state::has(states, state::FOCUSED) && obj != *app {
            return Some(obj);
        }
        if obj != *app && !state::has(states, state::SHOWING) {
            continue;
        }
        queue.extend(bus.children(&obj).into_iter().take(64));
    }
    None
}

/// Finds the focused object of `pid`, or without a pid (a Wayland desktop that
/// does not say what is in front) of the one app whose window is active.
fn locate(bus: &Bus, pid: Option<u32>) -> Located {
    let root = Obj::new(REGISTRY, ROOT_PATH);
    let own = std::process::id();
    let mut published = false;
    let mut found: Vec<(Obj, u32)> = Vec::new();
    for app in bus.children(&root) {
        let Some(app_pid) = bus.pid(&app.bus) else {
            continue;
        };
        if app_pid == own {
            continue;
        }
        match pid {
            Some(pid) if app_pid != pid => continue,
            Some(_) => {}
            None => {
                let active = bus.children(&app).iter().any(|window| {
                    bus.states(window)
                        .is_some_and(|s| state::has(s, ACTIVE) && state::has(s, state::SHOWING))
                });
                if !active {
                    continue;
                }
            }
        }
        published = true;
        if let Some(obj) = find_focused(bus, &app) {
            found.push((obj, app_pid));
        }
    }
    match found.len() {
        1 => {
            let (obj, pid) = found.remove(0);
            Located::Focused(obj, pid)
        }
        // Several apps claiming the keyboard cannot be told apart.
        _ if !found.is_empty() => Located::Silent,
        _ if published => Located::NoFocus,
        _ => Located::Silent,
    }
}

/// Identity and privacy from metadata; only the selection's offsets are read.
fn describe(bus: &Bus, obj: &Obj, pid: u32) -> Field {
    let object_role = bus.role(obj).unwrap_or(0);
    let states = bus.states(obj).unwrap_or(0);
    let role_name = bus.role_name(obj).unwrap_or_default();
    let name = bus.name(obj);
    let description = bus.description(obj);
    let attributes = bus.attributes(obj);
    let secure = object_role == role::PASSWORD_TEXT
        || policy::is_secure_field([
            role_name.as_str(),
            name.as_str(),
            description.as_str(),
            attributes
                .get("placeholder-text")
                .map_or("", String::as_str),
        ]);
    let mut field = Field {
        pid,
        key: obj.key(),
        secure,
        terminal: object_role == role::TERMINAL,
        ..Field::default()
    };
    if secure {
        return field;
    }
    let interfaces = bus.interfaces(obj);
    let has_text = interfaces.iter().any(|i| i == TEXT);
    field.editable = has_text
        && (interfaces.iter().any(|i| i == EDITABLE_TEXT) || state::has(states, state::EDITABLE))
        && state::has(states, state::EDITABLE)
        && !state::has(states, state::READ_ONLY);
    if field.editable {
        field.selection = bus.selection(obj).filter(|(start, end)| start != end);
    }
    field
}

pub(in crate::autocomplete) fn read_field(pid: Option<u32>) -> FieldRead {
    let Ok(bus) = Bus::connect() else {
        return FieldRead::Silent;
    };
    match locate(&bus, pid) {
        Located::Silent => FieldRead::Silent,
        Located::NoFocus => FieldRead::NoFocus,
        Located::Focused(obj, pid) => FieldRead::Field(describe(&bus, &obj, pid)),
    }
}

/// The process whose window is active, for a Wayland desktop that does not
/// report it another way.
pub(in crate::autocomplete) fn active_pid() -> Option<u32> {
    let bus = Bus::connect().ok()?;
    match locate(&bus, None) {
        Located::Focused(_, pid) => Some(pid),
        _ => None,
    }
}

/// The selected text of one object, with embedded-object marks removed.
fn selection_in(bus: &Bus, obj: &Obj, max_characters: usize) -> Option<String> {
    let (start, end) = bus.selection(obj)?;
    if start == end {
        return None;
    }
    let (start, end) = (start.min(end), start.max(end));
    let end = end.min(start.saturating_add(max_characters as i32));
    let text = bus.text(obj, start, end)?.replace('\u{fffc}', "");
    (!text.trim().is_empty()).then_some(text)
}

/// Read-only content keeps its selection on a text object below the document
/// that has focus.
fn selection_below(bus: &Bus, focus: &Obj, max_characters: usize) -> Option<String> {
    let mut start = focus.clone();
    let mut cursor = bus.parent(focus);
    for _ in 0..24 {
        let Some(node) = cursor else { break };
        let node_role = bus.role(&node).unwrap_or(0);
        if matches!(
            node_role,
            role::DOCUMENT_WEB | role::DOCUMENT_FRAME | role::DOCUMENT_TEXT
        ) {
            start = node;
            break;
        }
        if matches!(node_role, role::FRAME | role::WINDOW | role::DIALOG) {
            break;
        }
        cursor = bus.parent(&node);
    }
    let started = Instant::now();
    let mut queue = VecDeque::from([start]);
    let mut seen = 0;
    while let Some(obj) = queue.pop_front() {
        if seen >= SELECTION_WALK_NODES || started.elapsed() > SELECTION_WALK_TIME {
            return None;
        }
        seen += 1;
        let states = bus.states(&obj).unwrap_or(0);
        if !state::has(states, state::SHOWING) {
            continue;
        }
        if bus.interfaces(&obj).iter().any(|i| i == TEXT)
            && let Some(text) = selection_in(bus, &obj, max_characters)
        {
            return Some(text);
        }
        queue.extend(bus.children(&obj).into_iter().take(64));
    }
    None
}

pub(in crate::autocomplete) fn selected_text(pid: u32, max_characters: usize) -> SelectionRead {
    let Ok(bus) = Bus::connect() else {
        return SelectionRead::Unavailable;
    };
    let Located::Focused(obj, _) = locate(&bus, Some(pid)) else {
        return SelectionRead::Unavailable;
    };
    let field = describe(&bus, &obj, pid);
    if field.secure {
        return SelectionRead::Secure;
    }
    let text = if bus.interfaces(&obj).iter().any(|i| i == TEXT) {
        selection_in(&bus, &obj, max_characters)
    } else {
        None
    }
    .or_else(|| {
        (!field.editable)
            .then(|| selection_below(&bus, &obj, max_characters))
            .flatten()
    });
    // The same object must still have focus once the text is in hand.
    match locate(&bus, Some(pid)) {
        Located::Focused(current, _) if current == obj => {}
        _ => return SelectionRead::Unavailable,
    }
    match text {
        Some(text) => SelectionRead::Text(text),
        None if field.editable => SelectionRead::Empty,
        None => SelectionRead::Unavailable,
    }
}

/// The focused object, when it is still the bound field and not a secure one.
fn bound_field(bus: &Bus, pid: u32, identity: &str) -> Option<(Obj, Field)> {
    let Located::Focused(obj, _) = locate(bus, Some(pid)) else {
        return None;
    };
    let field = describe(bus, &obj, pid);
    (!field.secure && field.key == identity).then_some((obj, field))
}

pub(in crate::autocomplete) fn text_before_caret(pid: u32, identity: &str) -> Option<String> {
    let bus = Bus::connect().ok()?;
    let (obj, _) = bound_field(&bus, pid, identity)?;
    let caret = bus.caret_offset(&obj).filter(|c| *c >= 0)?;
    let start = (caret - policy::MAX_BEFORE_UTF16 as i32).max(0);
    let text = bus.text(&obj, start, caret)?.replace('\u{fffc}', "");
    Some(text)
}

/// The window title and page address around an object.
fn surface(bus: &Bus, obj: &Obj) -> (String, Option<String>) {
    let mut title = String::new();
    let mut url = None;
    let mut cursor = bus.parent(obj);
    for _ in 0..48 {
        let Some(node) = cursor else { break };
        let node_role = bus.role(&node).unwrap_or(0);
        if url.is_none() && matches!(node_role, role::DOCUMENT_WEB | role::DOCUMENT_FRAME) {
            url = document_url(bus, &node);
        }
        if matches!(node_role, role::FRAME | role::WINDOW | role::DIALOG) {
            title = bus.name(&node);
            break;
        }
        cursor = bus.parent(&node);
    }
    (title, url)
}

fn document_url(bus: &Bus, document: &Obj) -> Option<String> {
    for key in ["DocURL", "URI", "URL"] {
        if let Ok(value) = bus.call::<String>(document, DOCUMENT, "GetAttributeValue", &(key,))
            && !value.is_empty()
        {
            return Some(value);
        }
    }
    let attributes: HashMap<String, String> = bus
        .call(document, DOCUMENT, "GetAttributes", &())
        .unwrap_or_default();
    ["DocURL", "URI", "URL", "url"]
        .iter()
        .find_map(|key| attributes.get(*key).filter(|v| !v.is_empty()).cloned())
}

/// Text above the bound field, under `policy`. Coordinates are window
/// relative, which every toolkit reports consistently within one window.
pub(in crate::autocomplete) fn visible_text(
    pid: u32,
    identity: &str,
    app_name: &str,
    app_id: &str,
    policy: &ReadPolicy,
) -> Option<String> {
    let bus = Bus::connect().ok()?;
    let (obj, before) = bound_field(&bus, pid, identity)?;
    if before.selection.is_some() {
        return None;
    }
    let (window_title, url) = surface(&bus, &obj);
    let field = FieldSnapshot {
        app_name: app_name.to_string(),
        app_id: app_id.to_string(),
        pid,
        window_title,
        url,
        ..FieldSnapshot::default()
    };
    if !policy.allows_visible_text(&field) {
        return None;
    }
    let offset = Some((0.0, 0.0));
    let (coords, place) = placement(offset);
    let field_frame: Rect = bus.extents(&obj, coords).map(place)?;
    let mut cursor = bus.parent(&obj);
    let mut scope: Option<(Obj, Rect)> = None;
    let mut window: Option<Rect> = None;
    for _ in 0..32 {
        let Some(node) = cursor else { break };
        let frame = bus.extents(&node, coords).map(place);
        let node_role = bus.role(&node).unwrap_or(0);
        if scope.is_none()
            && let Some(frame) = frame
            && frame.contains_rect(&field_frame)
            && field_frame.y - frame.y >= 64.0
        {
            scope = Some((node.clone(), frame));
        }
        if matches!(node_role, role::FRAME | role::WINDOW | role::DIALOG) {
            window = frame;
            break;
        }
        cursor = bus.parent(&node);
    }
    let window_frame = window?;
    let (scope, scope_frame) = scope?;
    let mut source = AtspiSource {
        bus: &bus,
        offset,
        started: Instant::now(),
    };
    let text = visible::capture(
        &mut source,
        &visible::Target {
            scope,
            scope_frame,
            window_frame,
            field: obj.clone(),
            field_frame,
        },
    );
    // Nothing read while focus moved is kept.
    let (_, after) = bound_field(&bus, pid, identity)?;
    (after == before).then_some(text).flatten()
}
