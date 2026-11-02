//! One-shot reads of the focused element for dictation and selection actions,
//! separate from the watcher: identity and privacy, the selection, the text
//! before the caret, and the text above the field. Each call runs on a thread
//! of its own, which joins the COM apartment only for that call.

use std::time::Instant;

use windows::Win32::System::Com::{
    CLSCTX_INPROC_SERVER, COINIT_MULTITHREADED, CoCreateInstance, CoInitializeEx, CoUninitialize,
};
use windows::Win32::UI::Accessibility::{
    CUIAutomation8, IUIAutomation, IUIAutomation2, IUIAutomationElement, IUIAutomationTextPattern,
    IUIAutomationTextRange, IUIAutomationTreeWalker, IUIAutomationValuePattern,
    TextPatternRangeEndpoint_End, TextPatternRangeEndpoint_Start, TextUnit_Character,
    UIA_BoundingRectanglePropertyId, UIA_ComboBoxControlTypeId, UIA_ControlTypePropertyId,
    UIA_DocumentControlTypeId, UIA_EditControlTypeId, UIA_IsOffscreenPropertyId,
    UIA_IsPasswordPropertyId, UIA_NamePropertyId, UIA_TextPatternId, UIA_ValuePatternId,
    UIA_WindowControlTypeId,
};
use windows_core::Interface as _;

use super::super::focused::{Field, FieldRead, SelectionRead};
use super::super::policy::{self, ReadPolicy};
use super::super::visible;
use super::super::{FieldSnapshot, Rect};
use super::{UiaSource, bstr, caret_range, foreground_title, normalize_newlines, runtime_key};

/// A stuck app costs one missed read.
const PROVIDER_TIMEOUT_MS: u32 = 400;
/// Counting characters to a selection's ends stops here.
const MAX_OFFSET: i32 = 2_000_000;

struct Session {
    automation: IUIAutomation,
    walker: IUIAutomationTreeWalker,
}

impl Session {
    fn open() -> Option<Self> {
        // SAFETY: COM is initialized for this thread by the caller; the
        // objects stay on it.
        unsafe {
            let automation: IUIAutomation =
                CoCreateInstance(&CUIAutomation8, None, CLSCTX_INPROC_SERVER).ok()?;
            if let Ok(timeouts) = automation.cast::<IUIAutomation2>() {
                let _ = timeouts.SetConnectionTimeout(PROVIDER_TIMEOUT_MS);
                let _ = timeouts.SetTransactionTimeout(PROVIDER_TIMEOUT_MS);
            }
            let walker = automation.ControlViewWalker().ok()?;
            Some(Self { automation, walker })
        }
    }

    fn focused(&self) -> Option<IUIAutomationElement> {
        // SAFETY: a COM call on this thread's object.
        unsafe { self.automation.GetFocusedElement() }.ok()
    }
}

/// Runs `read` with COM up on this thread and a UI Automation session.
fn with_session<T>(read: impl FnOnce(&Session) -> Option<T>) -> Option<T> {
    // SAFETY: balanced by the CoUninitialize below on this same thread.
    let initialized = unsafe { CoInitializeEx(None, COINIT_MULTITHREADED) }.is_ok();
    let result = Session::open().and_then(|session| read(&session));
    if initialized {
        // SAFETY: matches the successful CoInitializeEx above.
        unsafe { CoUninitialize() };
    }
    result
}

/// A range's start and end as characters from the document's start, counted
/// without reading any text.
unsafe fn selection_offsets(
    pattern: &IUIAutomationTextPattern,
    range: &IUIAutomationTextRange,
) -> Option<(i32, i32)> {
    // SAFETY: COM calls on the caller's thread.
    unsafe {
        if range
            .CompareEndpoints(
                TextPatternRangeEndpoint_Start,
                range,
                TextPatternRangeEndpoint_End,
            )
            .ok()?
            == 0
        {
            return None;
        }
        let document = pattern.DocumentRange().ok()?;
        let offset = |endpoint| -> Option<i32> {
            let probe = document.Clone().ok()?;
            probe
                .MoveEndpointByRange(TextPatternRangeEndpoint_End, range, endpoint)
                .ok()?;
            let moved = probe
                .MoveEndpointByUnit(
                    TextPatternRangeEndpoint_End,
                    TextUnit_Character,
                    -MAX_OFFSET,
                )
                .ok()?;
            Some(-moved)
        };
        Some((
            offset(TextPatternRangeEndpoint_Start)?,
            offset(TextPatternRangeEndpoint_End)?,
        ))
    }
}

unsafe fn describe(element: &IUIAutomationElement, pid: u32) -> Field {
    // SAFETY: COM calls on the caller's thread.
    unsafe {
        let password = element.CurrentIsPassword().is_ok_and(|b| b.as_bool());
        let name = bstr(element.CurrentName());
        let help = bstr(element.CurrentHelpText());
        let kind = bstr(element.CurrentLocalizedControlType());
        let secure =
            password || policy::is_secure_field([name.as_str(), help.as_str(), kind.as_str()]);
        let mut field = Field {
            pid,
            key: runtime_key(element).unwrap_or_default(),
            secure,
            ..Field::default()
        };
        if secure {
            return field;
        }
        let control = element.CurrentControlType().unwrap_or_default();
        let pattern = element
            .GetCurrentPatternAs::<IUIAutomationTextPattern>(UIA_TextPatternId)
            .ok();
        let read_only = element
            .GetCurrentPatternAs::<IUIAutomationValuePattern>(UIA_ValuePatternId)
            .ok()
            .and_then(|value| value.CurrentIsReadOnly().ok())
            .is_some_and(|b| b.as_bool());
        let editable_kind = control == UIA_EditControlTypeId
            || control == UIA_DocumentControlTypeId
            || control == UIA_ComboBoxControlTypeId;
        field.editable = pattern.is_some() && editable_kind && !read_only;
        if field.editable
            && let Some(pattern) = pattern
            && let Some(range) = caret_range(&pattern)
        {
            field.selection = selection_offsets(&pattern, &range);
        }
        field
    }
}

pub(in crate::autocomplete) fn read_field(pid: Option<u32>) -> FieldRead {
    with_session(|session| {
        let Some(element) = session.focused() else {
            return Some(FieldRead::NoFocus);
        };
        // SAFETY: COM calls on this thread's objects.
        unsafe {
            let owner = element.CurrentProcessId().ok()? as u32;
            let _ = pid;
            Some(FieldRead::Field(describe(&element, owner)))
        }
    })
    .unwrap_or(FieldRead::Silent)
}

pub(in crate::autocomplete) fn selected_text(pid: u32, max_characters: usize) -> SelectionRead {
    let read = with_session(|session| {
        let element = session.focused()?;
        // SAFETY: COM calls on this thread's objects.
        unsafe {
            if element.CurrentProcessId().ok()? as u32 != pid {
                return Some(SelectionRead::Unavailable);
            }
            let field = describe(&element, pid);
            if field.secure {
                return Some(SelectionRead::Secure);
            }
            // Web content keeps its selection on the document around the focus.
            let mut node = Some(element.clone());
            let mut text = None;
            for _ in 0..8 {
                let Some(current) = node else { break };
                if let Ok(pattern) =
                    current.GetCurrentPatternAs::<IUIAutomationTextPattern>(UIA_TextPatternId)
                    && let Some(range) = caret_range(&pattern)
                    && range
                        .CompareEndpoints(
                            TextPatternRangeEndpoint_Start,
                            &range,
                            TextPatternRangeEndpoint_End,
                        )
                        .is_ok_and(|order| order != 0)
                {
                    text = Some(normalize_newlines(&bstr(
                        range.GetText(max_characters as i32),
                    )));
                    break;
                }
                if field.editable {
                    break;
                }
                node = session.walker.GetParentElement(&current).ok();
            }
            let still_focused = session.focused().is_some_and(|current| {
                session
                    .automation
                    .CompareElements(&current, &element)
                    .is_ok_and(|same| same.as_bool())
            });
            if !still_focused {
                return Some(SelectionRead::Unavailable);
            }
            Some(match text.filter(|t| !t.trim().is_empty()) {
                Some(text) => SelectionRead::Text(text),
                None if field.editable => SelectionRead::Empty,
                None => SelectionRead::Unavailable,
            })
        }
    });
    read.unwrap_or(SelectionRead::Unavailable)
}

/// The focused element, when it is still the bound field and not a secure one.
unsafe fn bound_field(
    session: &Session,
    pid: u32,
    identity: &str,
) -> Option<(IUIAutomationElement, Field)> {
    let element = session.focused()?;
    // SAFETY: COM calls on the caller's thread.
    unsafe {
        if element.CurrentProcessId().ok()? as u32 != pid {
            return None;
        }
        let field = describe(&element, pid);
        (!field.secure && field.key == identity).then_some((element, field))
    }
}

pub(in crate::autocomplete) fn text_before_caret(pid: u32, identity: &str) -> Option<String> {
    with_session(|session| {
        // SAFETY: COM calls on this thread's objects.
        unsafe {
            let (element, _) = bound_field(session, pid, identity)?;
            let pattern = element
                .GetCurrentPatternAs::<IUIAutomationTextPattern>(UIA_TextPatternId)
                .ok()?;
            let range = caret_range(&pattern)?;
            let before = range.Clone().ok()?;
            before
                .MoveEndpointByRange(
                    TextPatternRangeEndpoint_End,
                    &range,
                    TextPatternRangeEndpoint_Start,
                )
                .ok()?;
            before
                .MoveEndpointByUnit(
                    TextPatternRangeEndpoint_Start,
                    TextUnit_Character,
                    -(policy::MAX_BEFORE_UTF16 as i32),
                )
                .ok()?;
            Some(normalize_newlines(&bstr(before.GetText(-1))))
        }
    })
}

/// The page address of a browser: Chromium and Firefox report it as the value
/// of the document around the field.
unsafe fn document_url(session: &Session, element: &IUIAutomationElement) -> Option<String> {
    let mut node = element.clone();
    for _ in 0..40 {
        // SAFETY: COM calls on the caller's thread.
        unsafe {
            if node.CurrentControlType().ok() == Some(UIA_DocumentControlTypeId)
                && let Ok(value) =
                    node.GetCurrentPatternAs::<IUIAutomationValuePattern>(UIA_ValuePatternId)
                && let Ok(url) = value.CurrentValue()
            {
                let url = url.to_string();
                if url.starts_with("http://") || url.starts_with("https://") {
                    return Some(url);
                }
            }
            node = session.walker.GetParentElement(&node).ok()?;
        }
    }
    None
}

/// Text above the bound field, under `policy`.
pub(in crate::autocomplete) fn visible_text(
    pid: u32,
    identity: &str,
    app_name: &str,
    app_id: &str,
    policy: &ReadPolicy,
) -> Option<String> {
    with_session(|session| {
        // SAFETY: COM calls on this thread's objects.
        unsafe {
            let (element, before) = bound_field(session, pid, identity)?;
            if before.selection.is_some() {
                return None;
            }
            let field = FieldSnapshot {
                app_name: app_name.to_string(),
                app_id: app_id.to_string(),
                pid,
                window_title: foreground_title(pid).unwrap_or_default(),
                url: document_url(session, &element),
                ..FieldSnapshot::default()
            };
            if !policy.allows_visible_text(&field) {
                return None;
            }
            let frame_of = |node: &IUIAutomationElement| {
                node.CurrentBoundingRectangle().ok().map(|r| {
                    Rect::new(
                        r.left as f32,
                        r.top as f32,
                        (r.right - r.left) as f32,
                        (r.bottom - r.top) as f32,
                    )
                })
            };
            let field_frame = frame_of(&element).filter(|r| r.width > 0.0 && r.height > 0.0)?;
            let cache = session.automation.CreateCacheRequest().ok()?;
            for property in [
                UIA_ControlTypePropertyId,
                UIA_BoundingRectanglePropertyId,
                UIA_IsOffscreenPropertyId,
                UIA_IsPasswordPropertyId,
                UIA_NamePropertyId,
            ] {
                cache.AddProperty(property).ok()?;
            }
            let mut node = session.walker.GetParentElement(&element).ok()?;
            let mut scope: Option<(IUIAutomationElement, Rect)> = None;
            let mut window: Option<Rect> = None;
            for _ in 0..40 {
                let frame = frame_of(&node);
                if scope.is_none()
                    && let Some(frame) = frame
                    && frame.contains_rect(&field_frame)
                    && field_frame.y - frame.y >= 64.0
                {
                    scope = Some((node.clone(), frame));
                }
                if node.CurrentControlType().ok() == Some(UIA_WindowControlTypeId) {
                    window = frame;
                    break;
                }
                match session.walker.GetParentElement(&node) {
                    Ok(parent) => node = parent,
                    Err(_) => break,
                }
            }
            let window_frame = window?;
            let (scope, scope_frame) = scope?;
            let scope = scope.BuildUpdatedCache(&cache).ok()?;
            let mut source = UiaSource {
                walker: &session.walker,
                cache,
                nodes: vec![scope],
                started: Instant::now(),
            };
            let text = visible::capture(
                &mut source,
                &visible::Target {
                    scope: 0,
                    scope_frame,
                    window_frame,
                    field: usize::MAX,
                    field_frame,
                },
            );
            // Nothing read while focus moved is kept.
            let (_, after) = bound_field(session, pid, identity)?;
            (after == before).then_some(text).flatten()
        }
    })
}
