// Contains code ported from Cotabby (https://github.com/FuJacob/cotabby),
// copyright the Cotabby authors, under the GNU AGPL v3.0
// (LICENSES/AGPL-3.0.txt). Modified for LokalBot since 18 October 2026.
// See THIRD_PARTY_NOTICES.md.

//! Windows: the focused field through UI Automation (`CotypingAXHelper`,
//! `CotypingFocusTracker`).
//!
//! A focus-changed handler follows focus, and the focused element gets
//! text-changed and text-selection-changed handlers while it has focus.
//! Reads run on the watcher's own thread, coalesced, and the last field is
//! polled with Cotabby's backoff for providers that raise no events.
//! Exclusions are checked from the owning process, and secure fields from
//! `IsPassword` and their labels, before any text is requested.
//!
//! The caret comes from the text pattern: the character before the caret,
//! else the collapsed selection, else the system caret (`GetGUIThreadInfo`),
//! else an estimate at the field's leading edge.

use std::ffi::c_void;
use std::sync::Arc;
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use anyhow::Context as _;
use crossbeam_channel::{Receiver, RecvTimeoutError, Sender, unbounded};
use parking_lot::Mutex;
use windows::Win32::Foundation::POINT;
use windows::Win32::Graphics::Gdi::ClientToScreen;
use windows::Win32::System::Com::{
    CLSCTX_INPROC_SERVER, COINIT_MULTITHREADED, CoCreateInstance, CoInitializeEx, CoUninitialize,
    SAFEARRAY,
};
use windows::Win32::System::Ole::{
    SafeArrayAccessData, SafeArrayDestroy, SafeArrayGetLBound, SafeArrayGetUBound,
    SafeArrayUnaccessData,
};
use windows::Win32::System::Variant::{VARIANT, VT_BSTR, VT_I4, VT_R4, VT_R8, VariantClear};
use windows::Win32::UI::Accessibility::{
    CUIAutomation8, IUIAutomation, IUIAutomation2, IUIAutomationCacheRequest, IUIAutomationElement,
    IUIAutomationEventHandler, IUIAutomationEventHandler_Impl,
    IUIAutomationFocusChangedEventHandler, IUIAutomationFocusChangedEventHandler_Impl,
    IUIAutomationTextPattern, IUIAutomationTextRange, IUIAutomationTreeWalker,
    IUIAutomationValuePattern, TextPatternRangeEndpoint_End, TextPatternRangeEndpoint_Start,
    TextUnit_Character, TreeScope_Element, UIA_BackgroundColorAttributeId,
    UIA_BoundingRectanglePropertyId, UIA_ComboBoxControlTypeId, UIA_ControlTypePropertyId,
    UIA_DocumentControlTypeId, UIA_EVENT_ID, UIA_EditControlTypeId, UIA_FontNameAttributeId,
    UIA_FontSizeAttributeId, UIA_ForegroundColorAttributeId, UIA_HyperlinkControlTypeId,
    UIA_IsOffscreenPropertyId, UIA_IsPasswordPropertyId, UIA_MenuBarControlTypeId,
    UIA_MenuControlTypeId, UIA_NamePropertyId, UIA_PaneControlTypeId, UIA_ScrollBarControlTypeId,
    UIA_TEXTATTRIBUTE_ID, UIA_Text_TextChangedEventId, UIA_Text_TextSelectionChangedEventId,
    UIA_TextControlTypeId, UIA_TextPatternId, UIA_TitleBarControlTypeId, UIA_ToolBarControlTypeId,
    UIA_TreeControlTypeId, UIA_ValuePatternId, UIA_WindowControlTypeId,
};
use windows::Win32::UI::WindowsAndMessaging::{
    GUITHREADINFO, GWL_STYLE, GetForegroundWindow, GetGUIThreadInfo, GetWindowLongW,
    GetWindowTextLengthW, GetWindowTextW, GetWindowThreadProcessId,
};
use windows_core::{Ref, implement};

use super::geometry::{FieldStyle, Rect, Rgb};
use super::policy::{self, FlickerGate, PollBackoff, ReadPolicy, reasons};
use super::visible::{self, NodeKind, VisibleSource};
use super::{Capability, FieldSnapshot, FocusHandler, FocusSnapshot, InsertTarget};

/// Poll cadence before backoff (`CotypingFocusTracker.defaultIntervalMs`).
const POLL_INTERVAL: Duration = Duration::from_millis(200);
/// Events arriving this close together are read once.
const COALESCE: Duration = Duration::from_millis(8);
/// UI Automation gives up on a stuck app after this.
const PROVIDER_TIMEOUT_MS: u32 = 1_000;
const VISIBLE_BUDGET: Duration = Duration::from_millis(120);
/// `ES_MULTILINE` for Win32 edit controls.
const ES_MULTILINE: i32 = 0x0004;

enum Command {
    Policy(ReadPolicy),
    Refresh,
    Focus,
    Text,
    Stop,
}

#[implement(IUIAutomationFocusChangedEventHandler)]
struct FocusEvents {
    commands: Sender<Command>,
}

impl IUIAutomationFocusChangedEventHandler_Impl for FocusEvents_Impl {
    fn HandleFocusChangedEvent(
        &self,
        _sender: Ref<IUIAutomationElement>,
    ) -> windows_core::Result<()> {
        let _ = self.commands.send(Command::Focus);
        Ok(())
    }
}

#[implement(IUIAutomationEventHandler)]
struct TextEvents {
    commands: Sender<Command>,
}

impl IUIAutomationEventHandler_Impl for TextEvents_Impl {
    fn HandleAutomationEvent(
        &self,
        _sender: Ref<IUIAutomationElement>,
        _event: UIA_EVENT_ID,
    ) -> windows_core::Result<()> {
        let _ = self.commands.send(Command::Text);
        Ok(())
    }
}

pub(super) struct Watcher {
    commands: Sender<Command>,
    thread: Option<JoinHandle<()>>,
    limitation: Arc<Mutex<Option<String>>>,
}

impl Watcher {
    pub(super) fn start(policy: ReadPolicy, handler: FocusHandler) -> anyhow::Result<Self> {
        let (commands, receiver) = unbounded();
        let (ready_tx, ready_rx) = crossbeam_channel::bounded::<Result<(), String>>(1);
        let limitation = Arc::new(Mutex::new(None));
        let thread_limitation = limitation.clone();
        let thread_commands = commands.clone();
        let thread = std::thread::Builder::new()
            .name("lokalbot-autocomplete-watch".into())
            .spawn(move || {
                // SAFETY: this thread joins the multi-threaded apartment for
                // its whole life and leaves it at the end.
                if let Err(err) = unsafe { CoInitializeEx(None, COINIT_MULTITHREADED) }.ok() {
                    let _ = ready_tx.send(Err(format!("COM: {err}")));
                    return;
                }
                match Reader::new(policy, thread_commands, thread_limitation) {
                    Ok(mut reader) => {
                        let _ = ready_tx.send(Ok(()));
                        reader.run(receiver, handler);
                        reader.unregister();
                    }
                    Err(err) => {
                        let _ = ready_tx.send(Err(format!("{err:#}")));
                    }
                }
                // SAFETY: matches the CoInitializeEx above.
                unsafe { CoUninitialize() };
            })?;
        match ready_rx.recv() {
            Ok(Ok(())) => Ok(Self {
                commands,
                thread: Some(thread),
                limitation,
            }),
            Ok(Err(err)) => {
                let _ = thread.join();
                anyhow::bail!("UI Automation is unavailable: {err}")
            }
            Err(_) => anyhow::bail!("the autocomplete watcher stopped"),
        }
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
        let _ = self.commands.send(Command::Stop);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

/// What is read once per focused element.
#[derive(Clone, Debug)]
struct Fixed {
    key: String,
    pid: u32,
    app_name: String,
    app_id: String,
    window_title: String,
    url: Option<String>,
    single_line: Option<bool>,
    style: Option<FieldStyle>,
    refusal: Option<Refusal>,
}

#[derive(Clone, Copy, Debug)]
enum Refusal {
    Blocked(&'static str),
    Unsupported(&'static str),
}

struct Reader {
    automation: IUIAutomation,
    walker: IUIAutomationTreeWalker,
    focus_handler: IUIAutomationFocusChangedEventHandler,
    text_handler: IUIAutomationEventHandler,
    policy: ReadPolicy,
    current: Option<IUIAutomationElement>,
    /// The element the text handlers are registered on.
    watched: Option<IUIAutomationElement>,
    fixed: Option<Fixed>,
    visible: Option<(String, Option<String>)>,
    last: FocusSnapshot,
    gate: FlickerGate,
    backoff: PollBackoff,
    own_pid: u32,
    limitation: Arc<Mutex<Option<String>>>,
}

impl Reader {
    fn new(
        policy: ReadPolicy,
        commands: Sender<Command>,
        limitation: Arc<Mutex<Option<String>>>,
    ) -> anyhow::Result<Self> {
        // SAFETY: COM is initialized on this thread; the objects live on it.
        unsafe {
            let automation: IUIAutomation =
                CoCreateInstance(&CUIAutomation8, None, CLSCTX_INPROC_SERVER)
                    .context("could not create UI Automation")?;
            if let Ok(timeouts) = windows_core::Interface::cast::<IUIAutomation2>(&automation) {
                let _ = timeouts.SetConnectionTimeout(PROVIDER_TIMEOUT_MS);
                let _ = timeouts.SetTransactionTimeout(PROVIDER_TIMEOUT_MS);
            }
            let walker = automation.ControlViewWalker()?;
            let focus_handler: IUIAutomationFocusChangedEventHandler = FocusEvents {
                commands: commands.clone(),
            }
            .into();
            let text_handler: IUIAutomationEventHandler = TextEvents { commands }.into();
            automation
                .AddFocusChangedEventHandler(None::<&IUIAutomationCacheRequest>, &focus_handler)
                .context("could not follow focus")?;
            Ok(Self {
                automation,
                walker,
                focus_handler,
                text_handler,
                policy,
                current: None,
                watched: None,
                fixed: None,
                visible: None,
                last: FocusSnapshot::none(),
                gate: FlickerGate::default(),
                backoff: PollBackoff::default(),
                own_pid: std::process::id(),
                limitation,
            })
        }
    }

    fn unregister(&mut self) {
        self.watch_text(None);
        // SAFETY: removes the handlers this reader added.
        unsafe {
            let _ = self
                .automation
                .RemoveFocusChangedEventHandler(&self.focus_handler);
            let _ = self.automation.RemoveAllEventHandlers();
        }
    }

    fn run(&mut self, receiver: Receiver<Command>, handler: FocusHandler) {
        self.follow_focus();
        self.deliver(&handler);
        loop {
            let timeout = POLL_INTERVAL * self.backoff.stride();
            let dirty = match receiver.recv_timeout(timeout) {
                Ok(Command::Stop) | Err(RecvTimeoutError::Disconnected) => break,
                Ok(command) => {
                    let Some(mut dirty) = self.handle(command) else {
                        break;
                    };
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
                    self.follow_focus();
                    true
                }
            };
            if dirty {
                let changed = self.deliver(&handler);
                self.backoff.record(changed);
            }
        }
    }

    fn handle(&mut self, command: Command) -> Option<bool> {
        Some(match command {
            Command::Stop => return None,
            Command::Policy(policy) => {
                self.policy = policy;
                self.fixed = None;
                self.visible = None;
                self.backoff.reset();
                true
            }
            Command::Refresh | Command::Text => {
                self.backoff.reset();
                true
            }
            Command::Focus => {
                self.follow_focus();
                self.backoff.reset();
                true
            }
        })
    }

    /// Re-reads which element has focus and moves the text handlers to it.
    fn follow_focus(&mut self) {
        // SAFETY: COM calls on this thread's objects.
        let focused = unsafe { self.automation.GetFocusedElement() }.ok();
        let same = match (&focused, &self.current) {
            (Some(a), Some(b)) => {
                unsafe { self.automation.CompareElements(a, b) }.is_ok_and(|same| same.as_bool())
            }
            (None, None) => true,
            _ => false,
        };
        if same {
            return;
        }
        self.current = focused.clone();
        self.fixed = None;
        // Text read from around a field is forgotten when focus leaves it.
        self.visible = None;
        self.watch_text(focused);
    }

    fn watch_text(&mut self, element: Option<IUIAutomationElement>) {
        // SAFETY: COM calls on this thread's objects; handlers are removed
        // from the element they were added to.
        unsafe {
            if let Some(old) = self.watched.take() {
                for event in [
                    UIA_Text_TextChangedEventId,
                    UIA_Text_TextSelectionChangedEventId,
                ] {
                    let _ = self.automation.RemoveAutomationEventHandler(
                        event,
                        &old,
                        &self.text_handler,
                    );
                }
            }
            let Some(element) = element else {
                return;
            };
            if element.CurrentProcessId().ok() == Some(self.own_pid as i32) {
                return;
            }
            let mut added = false;
            for event in [
                UIA_Text_TextChangedEventId,
                UIA_Text_TextSelectionChangedEventId,
            ] {
                added |= self
                    .automation
                    .AddAutomationEventHandler(
                        event,
                        &element,
                        TreeScope_Element,
                        None::<&IUIAutomationCacheRequest>,
                        &self.text_handler,
                    )
                    .is_ok();
            }
            if added {
                self.watched = Some(element);
            }
        }
    }

    fn deliver(&mut self, handler: &FocusHandler) -> bool {
        let snapshot = self.read();
        if !self.gate.apply(&snapshot) || snapshot == self.last {
            return false;
        }
        self.last = snapshot.clone();
        handler(snapshot);
        true
    }

    fn read(&mut self) -> FocusSnapshot {
        let Some(element) = self.current.clone() else {
            return FocusSnapshot::none();
        };
        if !self.policy.enabled {
            return FocusSnapshot::none();
        }
        let fixed = match &self.fixed {
            Some(fixed) => fixed.clone(),
            None => match self.read_fixed(&element) {
                Some(fixed) => {
                    self.fixed = Some(fixed.clone());
                    fixed
                }
                None => return FocusSnapshot::none(),
            },
        };
        let refusal = match fixed.refusal {
            Some(refusal) => Err(refusal),
            None => self.read_text(&element, &fixed),
        };
        match refusal {
            Ok(mut field) => {
                field.visible_text = self.visible_text(&element, &field);
                FocusSnapshot {
                    app_name: fixed.app_name.clone(),
                    app_id: fixed.app_id.clone(),
                    capability: Capability::Supported,
                    field: Some(field),
                    focus_key: Some(fixed.key.clone()),
                }
            }
            Err(Refusal::Blocked(reason)) => FocusSnapshot::blocked(
                &fixed.app_name,
                &fixed.app_id,
                reason,
                Some(fixed.key.clone()),
            ),
            Err(Refusal::Unsupported(reason)) => {
                FocusSnapshot::unsupported(&fixed.app_name, &fixed.app_id, reason)
            }
        }
    }

    /// Identity, privacy and the field's kind, from metadata only.
    fn read_fixed(&mut self, element: &IUIAutomationElement) -> Option<Fixed> {
        // SAFETY: COM calls on this thread's objects.
        unsafe {
            let pid = element.CurrentProcessId().ok()? as u32;
            let mut fixed = Fixed {
                key: runtime_key(element).unwrap_or_default(),
                pid,
                app_name: String::new(),
                app_id: String::new(),
                window_title: String::new(),
                url: None,
                single_line: None,
                style: None,
                refusal: None,
            };
            if pid == self.own_pid {
                fixed.app_name = "LokalBot".into();
                fixed.app_id = crate::privacy::SELF_APP_ID.into();
                fixed.refusal = Some(Refusal::Unsupported("Off in LokalBot."));
                return Some(fixed);
            }
            let (name, id) = crate::activity::app_for_pid(pid)
                .unwrap_or_else(|| ("Unknown app".into(), String::new()));
            fixed.app_name = name;
            fixed.app_id = id;
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
            let control = element.CurrentControlType().unwrap_or_default();
            let password = element.CurrentIsPassword().is_ok_and(|b| b.as_bool());
            let name = bstr(element.CurrentName());
            let help = bstr(element.CurrentHelpText());
            let kind = bstr(element.CurrentLocalizedControlType());
            let aria = bstr(element.CurrentAriaRole());
            // Secure fields: never read, judged before any text is touched.
            if password || policy::is_secure_field([name.as_str(), help.as_str(), kind.as_str()]) {
                fixed.refusal = Some(Refusal::Blocked(reasons::SECURE));
                return Some(fixed);
            }
            let text = element
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
            if text.is_none() && editable_kind && !read_only {
                // An editable field that keeps its text from UI Automation.
                *self.limitation.lock() = Some(format!(
                    "{} does not share the text of its fields with accessibility tools, so autocomplete cannot suggest there.",
                    fixed.app_name
                ));
            }
            if text.is_none() || read_only || !editable_kind {
                fixed.refusal = Some(Refusal::Unsupported(reasons::NOT_EDITABLE));
                return Some(fixed);
            }
            *self.limitation.lock() = None;
            if policy::is_search_field([aria.as_str(), kind.as_str()]) {
                fixed.refusal = Some(Refusal::Unsupported(reasons::SEARCH));
                return Some(fixed);
            }
            fixed.single_line = single_line(element, control);
            fixed.window_title = foreground_title(pid).unwrap_or_default();
            if crate::privacy::is_browser(&fixed.app_name, &fixed.app_id) {
                fixed.url = self.document_url(element);
            }
            fixed.style = text
                .as_ref()
                .and_then(|pattern| caret_range(pattern))
                .and_then(|range| style_near(&range));
            Some(fixed)
        }
    }

    /// The page address of a browser: Chromium and Firefox report it as the
    /// value of the document around the field.
    unsafe fn document_url(&self, element: &IUIAutomationElement) -> Option<String> {
        let mut node = element.clone();
        for _ in 0..40 {
            // SAFETY: COM calls on this thread's objects.
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
                node = self.walker.GetParentElement(&node).ok()?;
            }
        }
        None
    }

    fn read_text(
        &self,
        element: &IUIAutomationElement,
        fixed: &Fixed,
    ) -> Result<FieldSnapshot, Refusal> {
        // SAFETY: COM calls on this thread's objects.
        unsafe {
            let pattern = element
                .GetCurrentPatternAs::<IUIAutomationTextPattern>(UIA_TextPatternId)
                .map_err(|_| Refusal::Unsupported(reasons::NOT_EDITABLE))?;
            let caret = caret_range(&pattern).ok_or(Refusal::Unsupported(reasons::NO_CARET))?;
            if caret
                .CompareEndpoints(
                    TextPatternRangeEndpoint_Start,
                    &caret,
                    TextPatternRangeEndpoint_End,
                )
                .is_ok_and(|order| order != 0)
            {
                return Err(Refusal::Blocked(reasons::SELECTION));
            }
            let max_before = policy::MAX_BEFORE_UTF16 as i32 + 1;
            let max_after = policy::MAX_AFTER_UTF16 as i32 + 1;
            let before_range = caret
                .Clone()
                .map_err(|_| Refusal::Unsupported(reasons::NO_CARET))?;
            let moved_back = before_range
                .MoveEndpointByUnit(
                    TextPatternRangeEndpoint_Start,
                    TextUnit_Character,
                    -max_before,
                )
                .unwrap_or(0);
            let raw_before = normalize_newlines(&bstr(before_range.GetText(-1)));
            let after_range = caret
                .Clone()
                .map_err(|_| Refusal::Unsupported(reasons::NO_CARET))?;
            let moved_on = after_range
                .MoveEndpointByUnit(TextPatternRangeEndpoint_End, TextUnit_Character, max_after)
                .unwrap_or(0);
            let raw_after = normalize_newlines(&bstr(after_range.GetText(-1)));
            let (before, before_truncated) =
                policy::bounded_before(&raw_before, -moved_back >= max_before);
            let after = policy::bounded_after(&raw_after, moved_on >= max_after);

            let field_frame = element.CurrentBoundingRectangle().ok().and_then(|r| {
                let rect = Rect::new(
                    r.left as f32,
                    r.top as f32,
                    (r.right - r.left) as f32,
                    (r.bottom - r.top) as f32,
                );
                (rect.width > 0.0 && rect.height > 0.0).then_some(rect)
            });
            let empty_range = first_rect(caret.GetBoundingRectangles().ok());
            let previous = caret.Clone().ok().and_then(|previous| {
                let moved = previous
                    .MoveEndpointByUnit(TextPatternRangeEndpoint_Start, TextUnit_Character, -1)
                    .ok()?;
                if moved != -1 || raw_before.ends_with('\n') {
                    return None;
                }
                first_rect(previous.GetBoundingRectangles().ok())
            });
            let rtl = policy::is_right_to_left(&before);
            let mut caret_rect = policy::choose_caret(empty_range, previous, field_frame, rtl)
                .map(|rect| (rect, true));
            if caret_rect.is_none() {
                caret_rect = system_caret(fixed.pid).map(|rect| (rect, true));
            }
            let (caret_rect, caret_exact) = match (caret_rect, field_frame) {
                (Some(found), _) => found,
                // A thin caret at the field's leading edge, as macOS estimates.
                (None, Some(frame)) => (
                    Rect::new(frame.x + 4.0, frame.y, 1.0, frame.height.clamp(8.0, 22.0)),
                    false,
                ),
                (None, None) => return Err(Refusal::Unsupported(reasons::NO_CARET)),
            };
            let single_line = fixed.single_line.unwrap_or_else(|| {
                field_frame.is_some_and(|frame| frame.height < caret_rect.height * 2.2)
            });
            Ok(FieldSnapshot {
                focus_key: fixed.key.clone(),
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
                single_line,
                url: fixed.url.clone(),
                visible_text: None,
                style: fixed.style.clone(),
                target: InsertTarget { pid: fixed.pid },
            })
        }
    }

    fn visible_text(
        &mut self,
        element: &IUIAutomationElement,
        field: &FieldSnapshot,
    ) -> Option<String> {
        if !self.policy.allows_visible_text(field) {
            return None;
        }
        if let Some((key, text)) = &self.visible
            && *key == field.focus_key
        {
            return text.clone();
        }
        let text = self.capture_visible(element, field);
        self.visible = Some((field.focus_key.clone(), text.clone()));
        text
    }

    fn capture_visible(
        &self,
        element: &IUIAutomationElement,
        field: &FieldSnapshot,
    ) -> Option<String> {
        let field_frame = field.field_frame?;
        // SAFETY: COM calls on this thread's objects.
        unsafe {
            let cache = self.automation.CreateCacheRequest().ok()?;
            for property in [
                UIA_ControlTypePropertyId,
                UIA_BoundingRectanglePropertyId,
                UIA_IsOffscreenPropertyId,
                UIA_IsPasswordPropertyId,
                UIA_NamePropertyId,
            ] {
                cache.AddProperty(property).ok()?;
            }
            // The window, and the nearest container with room above the field.
            let mut node = self.walker.GetParentElement(element).ok()?;
            let mut scope: Option<(IUIAutomationElement, Rect)> = None;
            let mut window: Option<Rect> = None;
            for _ in 0..40 {
                let frame = node.CurrentBoundingRectangle().ok().map(|r| {
                    Rect::new(
                        r.left as f32,
                        r.top as f32,
                        (r.right - r.left) as f32,
                        (r.bottom - r.top) as f32,
                    )
                });
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
                match self.walker.GetParentElement(&node) {
                    Ok(parent) => node = parent,
                    Err(_) => break,
                }
            }
            let window_frame = window?;
            let (scope, scope_frame) = scope?;
            let scope = scope.BuildUpdatedCache(&cache).ok()?;
            let mut source = UiaSource {
                walker: &self.walker,
                cache,
                nodes: vec![scope],
                started: Instant::now(),
            };
            visible::capture(
                &mut source,
                &visible::Target {
                    scope: 0,
                    scope_frame,
                    window_frame,
                    field: usize::MAX,
                    field_frame,
                },
            )
        }
    }
}

/// The collapsed selection at the caret.
unsafe fn caret_range(pattern: &IUIAutomationTextPattern) -> Option<IUIAutomationTextRange> {
    // SAFETY: COM calls on the caller's thread.
    unsafe {
        let selection = pattern.GetSelection().ok()?;
        if selection.Length().ok()? < 1 {
            return None;
        }
        selection.GetElement(0).ok()
    }
}

/// The font and colors of the character before the caret (or at it).
unsafe fn style_near(caret: &IUIAutomationTextRange) -> Option<FieldStyle> {
    // SAFETY: COM calls on the caller's thread.
    unsafe {
        let range = caret.Clone().ok()?;
        if range
            .MoveEndpointByUnit(TextPatternRangeEndpoint_Start, TextUnit_Character, -1)
            .ok()
            != Some(-1)
        {
            let _ = range.MoveEndpointByUnit(TextPatternRangeEndpoint_End, TextUnit_Character, 1);
        }
        let attribute = |id: UIA_TEXTATTRIBUTE_ID| range.GetAttributeValue(id).ok();
        let style = FieldStyle {
            font_family: attribute(UIA_FontNameAttributeId)
                .and_then(|v| variant_text(v))
                .filter(|f| !f.is_empty()),
            font_points: attribute(UIA_FontSizeAttributeId)
                .and_then(|v| variant_f64(v))
                .map(|size| size as f32)
                .filter(|size| *size > 0.0),
            color: attribute(UIA_ForegroundColorAttributeId)
                .and_then(|v| variant_i32(v))
                .map(colorref),
            background: attribute(UIA_BackgroundColorAttributeId)
                .and_then(|v| variant_i32(v))
                .map(colorref),
        };
        (style != FieldStyle::default()).then_some(style)
    }
}

/// `COLORREF` is 0x00BBGGRR.
fn colorref(value: i32) -> Rgb {
    let value = value as u32;
    Rgb {
        r: (value & 0xff) as u8,
        g: ((value >> 8) & 0xff) as u8,
        b: ((value >> 16) & 0xff) as u8,
    }
}

/// Single-line for Win32 edit controls without `ES_MULTILINE`; documents
/// are multi-line; other edits are decided from their height later.
unsafe fn single_line(
    element: &IUIAutomationElement,
    control: windows::Win32::UI::Accessibility::UIA_CONTROLTYPE_ID,
) -> Option<bool> {
    if control == UIA_DocumentControlTypeId {
        return Some(false);
    }
    // SAFETY: COM and window calls on the caller's thread.
    unsafe {
        let hwnd = element.CurrentNativeWindowHandle().ok()?;
        if hwnd.0.is_null() {
            return None;
        }
        let class = bstr(element.CurrentClassName()).to_lowercase();
        if class == "edit" || class.starts_with("richedit") {
            return Some(GetWindowLongW(hwnd, GWL_STYLE) & ES_MULTILINE == 0);
        }
    }
    None
}

/// The foreground window's title when it belongs to `pid`.
fn foreground_title(pid: u32) -> Option<String> {
    // SAFETY: reads the caption into a buffer of the reported length.
    unsafe {
        let window = GetForegroundWindow();
        if window.0.is_null() {
            return None;
        }
        let mut owner = 0u32;
        GetWindowThreadProcessId(window, Some(&mut owner));
        if owner != pid {
            return None;
        }
        let length = GetWindowTextLengthW(window);
        if length <= 0 {
            return Some(String::new());
        }
        let mut buffer = vec![0u16; length as usize + 1];
        let copied = GetWindowTextW(window, &mut buffer);
        Some(String::from_utf16_lossy(&buffer[..copied.max(0) as usize]))
    }
}

/// The system caret of the foreground window's thread, in screen pixels,
/// when it belongs to `pid` (`GetGUIThreadInfo`).
fn system_caret(pid: u32) -> Option<Rect> {
    // SAFETY: `info` is a valid GUITHREADINFO with cbSize set.
    unsafe {
        let window = GetForegroundWindow();
        if window.0.is_null() {
            return None;
        }
        let mut owner = 0u32;
        let thread = GetWindowThreadProcessId(window, Some(&mut owner));
        if owner != pid {
            return None;
        }
        let mut info = GUITHREADINFO {
            cbSize: size_of::<GUITHREADINFO>() as u32,
            ..Default::default()
        };
        GetGUIThreadInfo(thread, &mut info).ok()?;
        if info.hwndCaret.0.is_null() {
            return None;
        }
        let caret = info.rcCaret;
        let mut origin = POINT {
            x: caret.left,
            y: caret.top,
        };
        if !ClientToScreen(info.hwndCaret, &mut origin).as_bool() {
            return None;
        }
        let height = (caret.bottom - caret.top) as f32;
        (height > 0.0).then(|| Rect::new(origin.x as f32, origin.y as f32, 0.0, height))
    }
}

fn normalize_newlines(text: &str) -> String {
    text.replace("\r\n", "\n").replace('\r', "\n")
}

fn bstr(value: windows_core::Result<windows_core::BSTR>) -> String {
    value.map(|text| text.to_string()).unwrap_or_default()
}

/// A stable key for an element: its runtime id.
unsafe fn runtime_key(element: &IUIAutomationElement) -> Option<String> {
    // SAFETY: the array is read within its bounds and destroyed after.
    unsafe {
        let array = element.GetRuntimeId().ok()?;
        let values: Vec<i32> = read_array(array);
        Some(
            values
                .iter()
                .map(|v| format!("{v:x}"))
                .collect::<Vec<_>>()
                .join("."),
        )
    }
}

/// The first rect of a `GetBoundingRectangles` array (x, y, width, height
/// quadruples of doubles).
unsafe fn first_rect(array: Option<*mut SAFEARRAY>) -> Option<Rect> {
    let values: Vec<f64> = unsafe { read_array(array?) };
    let quad = values.get(..4)?;
    let rect = Rect::new(
        quad[0] as f32,
        quad[1] as f32,
        quad[2] as f32,
        quad[3] as f32,
    );
    (rect.height > 0.0).then_some(rect)
}

/// Copies a one-dimensional `SAFEARRAY` of `T` and destroys it.
unsafe fn read_array<T: Copy>(array: *mut SAFEARRAY) -> Vec<T> {
    if array.is_null() {
        return Vec::new();
    }
    // SAFETY: the array came from UI Automation with elements of type `T`;
    // access is bracketed by Access/Unaccess and the array is destroyed once.
    unsafe {
        let lower = SafeArrayGetLBound(array, 1).unwrap_or(0);
        let upper = SafeArrayGetUBound(array, 1).unwrap_or(-1);
        let count = (upper - lower + 1).max(0) as usize;
        let mut values = Vec::new();
        let mut data: *mut c_void = std::ptr::null_mut();
        if count > 0 && SafeArrayAccessData(array, &mut data).is_ok() && !data.is_null() {
            values.extend_from_slice(std::slice::from_raw_parts(data as *const T, count));
            let _ = SafeArrayUnaccessData(array);
        }
        let _ = SafeArrayDestroy(array);
        values
    }
}

/// Reads a `VARIANT` of the expected kind and frees it.
unsafe fn variant_text(mut value: VARIANT) -> Option<String> {
    // SAFETY: the union member read matches `vt`; VariantClear frees it.
    unsafe {
        let inner = &value.Anonymous.Anonymous;
        let text = (inner.vt == VT_BSTR).then(|| inner.Anonymous.bstrVal.to_string());
        let _ = VariantClear(&mut value);
        text
    }
}

unsafe fn variant_f64(mut value: VARIANT) -> Option<f64> {
    // SAFETY: as in `variant_text`.
    unsafe {
        let inner = &value.Anonymous.Anonymous;
        let number = if inner.vt == VT_R8 {
            Some(inner.Anonymous.dblVal)
        } else if inner.vt == VT_R4 {
            Some(f64::from(inner.Anonymous.fltVal))
        } else if inner.vt == VT_I4 {
            Some(f64::from(inner.Anonymous.lVal))
        } else {
            None
        };
        let _ = VariantClear(&mut value);
        number
    }
}

unsafe fn variant_i32(mut value: VARIANT) -> Option<i32> {
    // SAFETY: as in `variant_text`.
    unsafe {
        let inner = &value.Anonymous.Anonymous;
        let number = (inner.vt == VT_I4).then(|| inner.Anonymous.lVal);
        let _ = VariantClear(&mut value);
        number
    }
}

/// The visible-context walk over UI Automation, with each node's
/// properties fetched in one cached call.
struct UiaSource<'a> {
    walker: &'a IUIAutomationTreeWalker,
    cache: IUIAutomationCacheRequest,
    nodes: Vec<IUIAutomationElement>,
    started: Instant,
}

impl VisibleSource for UiaSource<'_> {
    type Id = usize;

    fn node(&mut self, id: &usize) -> Option<visible::Node> {
        let element = self.nodes.get(*id)?;
        // SAFETY: cached property reads on this thread's objects.
        unsafe {
            let control = element.CachedControlType().ok()?;
            let password = element.CachedIsPassword().is_ok_and(|b| b.as_bool());
            let kind = if password {
                NodeKind::Excluded
            } else if control == UIA_TextControlTypeId {
                NodeKind::StaticText
            } else if control == UIA_HyperlinkControlTypeId {
                NodeKind::Link
            } else if [
                UIA_EditControlTypeId,
                UIA_ComboBoxControlTypeId,
                UIA_ToolBarControlTypeId,
                UIA_MenuBarControlTypeId,
                UIA_MenuControlTypeId,
                UIA_TreeControlTypeId,
                UIA_TitleBarControlTypeId,
                UIA_ScrollBarControlTypeId,
            ]
            .contains(&control)
            {
                NodeKind::Excluded
            } else if [
                UIA_DocumentControlTypeId,
                UIA_PaneControlTypeId,
                UIA_WindowControlTypeId,
            ]
            .contains(&control)
            {
                NodeKind::ClippingContainer
            } else {
                NodeKind::Container
            };
            let frame = element.CachedBoundingRectangle().ok().map(|r| {
                Rect::new(
                    r.left as f32,
                    r.top as f32,
                    (r.right - r.left) as f32,
                    (r.bottom - r.top) as f32,
                )
            });
            Some(visible::Node {
                kind,
                frame: frame.filter(|f| f.width > 0.0 && f.height > 0.0),
                hidden: element.CachedIsOffscreen().is_ok_and(|b| b.as_bool()),
            })
        }
    }

    fn children(&mut self, id: &usize) -> Vec<usize> {
        let Some(element) = self.nodes.get(*id).cloned() else {
            return Vec::new();
        };
        let mut children = Vec::new();
        // SAFETY: tree walks on this thread's objects.
        unsafe {
            let mut child = self
                .walker
                .GetFirstChildElementBuildCache(&element, &self.cache)
                .ok();
            while let Some(current) = child {
                if children.len() >= 80 || !self.within_budget() {
                    break;
                }
                child = self
                    .walker
                    .GetNextSiblingElementBuildCache(&current, &self.cache)
                    .ok();
                self.nodes.push(current);
                children.push(self.nodes.len() - 1);
            }
        }
        children
    }

    fn text(&mut self, id: &usize) -> Option<String> {
        let element = self.nodes.get(*id)?;
        // SAFETY: a cached property read.
        let name = unsafe { element.CachedName() }.ok()?.to_string();
        (!name.trim().is_empty()).then_some(name)
    }

    fn within_budget(&self) -> bool {
        self.started.elapsed() < VISIBLE_BUDGET
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn colorrefs_are_bgr() {
        assert_eq!(colorref(0x0000_00ff), Rgb { r: 255, g: 0, b: 0 });
        assert_eq!(colorref(0x00ff_0000), Rgb { r: 0, g: 0, b: 255 });
    }

    #[test]
    fn newlines_are_normalized() {
        assert_eq!(normalize_newlines("a\r\nb\rc\n"), "a\nb\nc\n");
    }

    #[test]
    fn the_watcher_starts_and_stops_without_a_desktop() {
        // Over SSH (session 0) there is no focused field; it must not hang.
        let policy = ReadPolicy {
            enabled: true,
            ..Default::default()
        };
        let watcher = Watcher::start(policy, Arc::new(|focus| eprintln!("focus: {focus:?}")));
        match watcher {
            Ok(watcher) => {
                std::thread::sleep(Duration::from_millis(300));
                drop(watcher);
            }
            Err(err) => eprintln!("no UI Automation here: {err:#}"),
        }
    }
}
