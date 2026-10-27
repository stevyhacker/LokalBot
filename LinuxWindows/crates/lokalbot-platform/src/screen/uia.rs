//! Windows: visible text and secure-field state through UI Automation, the
//! counterpart of `ScreenAccessibilityReader.resolve`. The window is walked
//! breadth-first through the control view, and every element arrives with
//! the properties in [`CACHED_PROPERTIES`] in the same cross-process call.
//! Text is visible text only (`ScreenVisibleTextPolicy`): the visible ranges
//! of text controls and the names of labels that lie fully inside their
//! viewport. Secure fields are never read, and the lines of a page that
//! overlap one are dropped.

use std::collections::{HashSet, VecDeque};
use std::ffi::c_void;
use std::time::{Duration, Instant};

use windows::Win32::Foundation::{HWND, RECT};
use windows::Win32::System::Com::{
    CLSCTX_INPROC_SERVER, CO_MTA_USAGE_COOKIE, COINIT_MULTITHREADED, CoCreateInstance,
    CoDecrementMTAUsage, CoIncrementMTAUsage, CoInitializeEx, CoUninitialize,
};
use windows::Win32::System::Variant::{VT_BOOL, VT_BSTR, VariantClear};
use windows::Win32::UI::Accessibility::{
    CUIAutomation, CUIAutomation8, IUIAutomation, IUIAutomation2, IUIAutomationCacheRequest,
    IUIAutomationElement, IUIAutomationTextPattern, IUIAutomationTextRange,
    TextPatternRangeEndpoint_End, TextPatternRangeEndpoint_Start, UIA_BoundingRectanglePropertyId,
    UIA_ButtonControlTypeId, UIA_CONTROLTYPE_ID, UIA_CheckBoxControlTypeId,
    UIA_ComboBoxControlTypeId, UIA_ControlTypePropertyId, UIA_DataItemControlTypeId,
    UIA_DocumentControlTypeId, UIA_E_TIMEOUT, UIA_EditControlTypeId, UIA_FrameworkIdPropertyId,
    UIA_HeaderControlTypeId, UIA_HeaderItemControlTypeId, UIA_HelpTextPropertyId,
    UIA_HyperlinkControlTypeId, UIA_IsOffscreenPropertyId, UIA_IsPasswordPropertyId,
    UIA_IsScrollPatternAvailablePropertyId, UIA_IsTextPatternAvailablePropertyId,
    UIA_IsValuePatternAvailablePropertyId, UIA_ListItemControlTypeId, UIA_MenuItemControlTypeId,
    UIA_NamePropertyId, UIA_PROPERTY_ID, UIA_ProcessIdPropertyId, UIA_RadioButtonControlTypeId,
    UIA_ScrollBarControlTypeId, UIA_SplitButtonControlTypeId, UIA_TabItemControlTypeId,
    UIA_TextControlTypeId, UIA_TextPatternId, UIA_TitleBarControlTypeId, UIA_TreeItemControlTypeId,
    UIA_ValueValuePropertyId, UIA_WindowControlTypeId,
};
use windows::Win32::UI::WindowsAndMessaging::GetForegroundWindow;
use windows::core::{AgileReference, HRESULT, Interface};

use super::privacy::{page_address, sanitized_document_name, settled_focus};
use super::{
    AccessibleWindow, FocusedWindow, MAX_CHARACTERS, MAX_CHILDREN, MAX_NODES, TextRead, TextReader,
    WindowRect, append_text,
};

/// How long one call may wait on the target app (UIA waits 20 s by
/// default), so a hung app holds a read for about this long.
const CALL_TIMEOUT_MS: u32 = 500;

const OWN_WINDOW: &str = "LokalBot's own windows are not read";

/// Every element is fetched with these, in the same call.
const CACHED_PROPERTIES: [UIA_PROPERTY_ID; 11] = [
    UIA_NamePropertyId,
    UIA_HelpTextPropertyId,
    UIA_ControlTypePropertyId,
    UIA_BoundingRectanglePropertyId,
    UIA_IsOffscreenPropertyId,
    UIA_IsPasswordPropertyId,
    UIA_IsTextPatternAvailablePropertyId,
    UIA_IsValuePatternAvailablePropertyId,
    UIA_IsScrollPatternAvailablePropertyId,
    UIA_ProcessIdPropertyId,
    UIA_FrameworkIdPropertyId,
];

pub(super) struct UiaReader {
    client: Option<Client>,
}

impl UiaReader {
    pub(super) fn new() -> Self {
        Self { client: None }
    }

    /// The UI Automation client, created on first use.
    fn automation(&mut self) -> windows::core::Result<IUIAutomation> {
        let client = match &mut self.client {
            Some(client) => client,
            empty => empty.insert(Client::create()?),
        };
        let automation = client.automation.resolve();
        if automation.is_err() {
            self.client = None;
        }
        automation
    }
}

impl TextReader for UiaReader {
    fn read(&mut self, window: &FocusedWindow, include_text: bool, deadline: Duration) -> TextRead {
        let started = Instant::now();
        // UI Automation would answer from LokalBot's own UI thread, which may
        // be waiting on this one; its windows are never recorded anyway.
        if window.pid == Some(std::process::id()) {
            return TextRead::Unavailable(OWN_WINDOW.into());
        }
        if window.id == 0 {
            return TextRead::Unavailable("there is no window to read".into());
        }
        let _com = ComScope::enter();
        match self.automation() {
            Ok(automation) => read_window(&automation, window, include_text, started, deadline),
            Err(err) => {
                TextRead::Unavailable(format!("UI Automation is unavailable: {}", err.message()))
            }
        }
    }

    fn name(&self) -> &'static str {
        "uia"
    }
}

/// The UI Automation client, kept between reads. It lives in the MTA, which
/// stays up while the client exists even when no thread is inside it.
struct Client {
    automation: AgileReference<IUIAutomation>,
    _mta: MtaUsage,
}

impl Client {
    fn create() -> windows::core::Result<Self> {
        // SAFETY: COM bookkeeping and an in-process object; the MTA usage is
        // returned when `MtaUsage` drops, after the client is released.
        unsafe {
            let mta = MtaUsage(CoIncrementMTAUsage()?);
            let automation: IUIAutomation =
                CoCreateInstance(&CUIAutomation8, None, CLSCTX_INPROC_SERVER)
                    .or_else(|_| CoCreateInstance(&CUIAutomation, None, CLSCTX_INPROC_SERVER))?;
            if let Ok(automation) = automation.cast::<IUIAutomation2>() {
                let _ = automation.SetConnectionTimeout(CALL_TIMEOUT_MS);
                let _ = automation.SetTransactionTimeout(CALL_TIMEOUT_MS);
            }
            Ok(Self {
                automation: AgileReference::new(&automation)?,
                _mta: mta,
            })
        }
    }
}

/// Keeps the MTA initialized (`CoIncrementMTAUsage`) until dropped.
struct MtaUsage(CO_MTA_USAGE_COOKIE);

// SAFETY: the cookie is an opaque token that CoDecrementMTAUsage accepts
// from any thread.
unsafe impl Send for MtaUsage {}

impl Drop for MtaUsage {
    fn drop(&mut self) {
        // SAFETY: returns the cookie of the matching CoIncrementMTAUsage.
        let _ = unsafe { CoDecrementMTAUsage(self.0) };
    }
}

/// Balances `CoInitializeEx` on this thread. A thread already in another
/// apartment keeps it; the agile client works there too.
struct ComScope {
    initialized: bool,
}

impl ComScope {
    fn enter() -> Self {
        // SAFETY: plain COM initialization for the calling thread; balanced
        // in `drop` when it succeeded.
        let result = unsafe { CoInitializeEx(None, COINIT_MULTITHREADED) };
        Self {
            initialized: result.is_ok(),
        }
    }
}

impl Drop for ComScope {
    fn drop(&mut self) {
        if self.initialized {
            // SAFETY: matches the successful CoInitializeEx above.
            unsafe { CoUninitialize() };
        }
    }
}

/// `ScreenAccessibilityReader.resolve` for one window.
fn read_window(
    automation: &IUIAutomation,
    window: &FocusedWindow,
    include_text: bool,
    started: Instant,
    deadline: Duration,
) -> TextRead {
    let hwnd = HWND(window.id as usize as *mut c_void);
    let Ok(cache) = cache_request(automation) else {
        return TextRead::Unavailable("UI Automation could not prepare a request".into());
    };
    // SAFETY: UI Automation validates the handle; a stale one fails.
    let root = match unsafe { automation.ElementFromHandleBuildCache(hwnd, &cache) } {
        Ok(root) => root,
        Err(err) if err.code() == HRESULT(UIA_E_TIMEOUT as i32) => return TextRead::TimedOut,
        Err(_) => {
            return TextRead::Unavailable("the window is not exposed to UI Automation".into());
        }
    };
    let node = Node::cached(&root);
    if node.process == Some(std::process::id()) {
        return TextRead::Unavailable(OWN_WINDOW.into());
    }
    if window.pid.is_some() && node.process.is_some() && node.process != window.pid {
        return TextRead::Changed("the window belongs to another process".into());
    }
    let process = node.process.or(window.pid);
    let title = cached_name(&root);
    let frame = node.rect;
    let focus = focus_state(automation, &cache, process);
    if started.elapsed() >= deadline {
        return TextRead::TimedOut;
    }

    // The walk leaves a quarter of the deadline for the checks below (the
    // Mac walks for 140 of its 180 ms).
    let walk_until = started + (deadline - deadline / 4);
    let mut found = walk(automation, &cache, &root, frame, include_text, walk_until);
    remove_secure_lines(&mut found);

    // UI Automation answers asynchronously to the app. Never attach one
    // window's text to a different window, title or focus.
    // SAFETY: no arguments; returns a possibly null handle.
    if unsafe { GetForegroundWindow() } != hwnd {
        return TextRead::Changed("focused window changed during read".into());
    }
    // SAFETY: one call that refreshes the root's cached properties.
    let Ok(current) = (unsafe { root.BuildUpdatedCache(&cache) }) else {
        return TextRead::Changed("window stopped answering during read".into());
    };
    if cached_name(&current) != title {
        return TextRead::Changed("window title changed during read".into());
    }
    if Node::cached(&current).rect != frame {
        return TextRead::Changed("window frame changed during read".into());
    }
    let final_focus = focus_state(automation, &cache, process);
    let (accepted, focused_secure_field) = settled_focus(focus, final_focus);
    if !accepted {
        let describe = |value: Option<bool>| match value {
            Some(true) => "secure",
            Some(false) => "plain",
            None => "unknown",
        };
        return TextRead::Changed(format!(
            "focused-field state changed during read ({} to {})",
            describe(focus),
            describe(final_focus)
        ));
    }
    let address = page_address(None, &found.web_area_urls);
    TextRead::Read(AccessibleWindow {
        text: found.text.parts.join("\n"),
        source_url: address.source_url,
        document_name: found.document_name,
        focused_secure_field,
        window_title: title.map(|name| {
            if name.is_empty() {
                window.title.clone()
            } else {
                name
            }
        }),
        has_web_content: found.has_web_content,
        contains_secure_field: found.contains_secure_field,
        framed_urls: address.framed_urls,
        has_unattributed_web_content: address.has_unattributed_web_content,
    })
}

/// UI Automation refuses requests for a moment while another thread of the
/// process is still setting it up, so this tries for a few milliseconds.
fn cache_request(automation: &IUIAutomation) -> windows::core::Result<IUIAutomationCacheRequest> {
    let started = Instant::now();
    loop {
        match new_cache_request(automation) {
            Err(_) if started.elapsed() < Duration::from_millis(20) => std::thread::yield_now(),
            result => return result,
        }
    }
}

fn new_cache_request(
    automation: &IUIAutomation,
) -> windows::core::Result<IUIAutomationCacheRequest> {
    // SAFETY: builds a request object in this process.
    unsafe {
        let request = automation.CreateCacheRequest()?;
        // Every element we are handed gets its properties, whatever its view.
        request.SetTreeFilter(&automation.RawViewCondition()?)?;
        for property in CACHED_PROPERTIES {
            request.AddProperty(property)?;
        }
        Ok(request)
    }
}

/// Whether the focused element is secure, when it belongs to the window's
/// process; `None` when that is unknown.
fn focus_state(
    automation: &IUIAutomation,
    cache: &IUIAutomationCacheRequest,
    process: Option<u32>,
) -> Option<bool> {
    // SAFETY: one call; the element comes back with its properties cached.
    let focused = unsafe { automation.GetFocusedElementBuildCache(cache) }.ok()?;
    let node = Node::cached(&focused);
    if process.is_none() || node.process != process {
        return None;
    }
    node.secure
}

#[derive(Default)]
struct Text {
    parts: Vec<String>,
    seen: HashSet<String>,
    total: usize,
}

impl Text {
    /// [`append_text`] with CR LF line ends made LF. False once full.
    fn append(&mut self, raw: &str) -> bool {
        append_text(
            &unix_lines(raw),
            &mut self.parts,
            &mut self.seen,
            &mut self.total,
            MAX_CHARACTERS,
        )
    }

    fn is_full(&self) -> bool {
        self.total >= MAX_CHARACTERS
    }

    fn remove(&mut self, indices: &HashSet<usize>) {
        let mut index = 0;
        self.parts.retain(|_| {
            let keep = !indices.contains(&index);
            index += 1;
            keep
        });
    }
}

fn unix_lines(text: &str) -> String {
    text.replace("\r\n", "\n").replace('\r', "\n")
}

#[derive(Default)]
struct Findings {
    text: Text,
    /// Elements whose visible ranges were read, in walk order.
    sources: Vec<RangeSource>,
    /// Web documents' addresses in walk order, outermost first.
    web_area_urls: Vec<Option<String>>,
    document_name: Option<String>,
    has_web_content: bool,
    contains_secure_field: bool,
}

/// The lines read from one element's visible ranges. A page's ranges hold
/// the values of its inputs, so the lines stay removable until the walk
/// knows which secure fields show inside it.
struct RangeSource {
    pattern: IUIAutomationTextPattern,
    /// Each line kept in [`Text::parts`]: its index there and its range.
    lines: Vec<(usize, IUIAutomationTextRange)>,
    /// Secure text entries inside the element that are not password fields
    /// (those show bullets), whose values may be in the lines.
    secure_fields: Vec<IUIAutomationElement>,
}

struct Pending {
    element: IUIAutomationElement,
    viewport: Option<WindowRect>,
    /// The ancestor whose visible ranges already hold this element's text,
    /// as an index into [`Findings::sources`].
    covered: Option<usize>,
}

/// The breadth-first walk of `resolve`, bounded by [`MAX_NODES`],
/// [`MAX_CHARACTERS`], [`MAX_CHILDREN`] per element and `until`.
fn walk(
    automation: &IUIAutomation,
    cache: &IUIAutomationCacheRequest,
    root: &IUIAutomationElement,
    viewport: Option<WindowRect>,
    include_text: bool,
    until: Instant,
) -> Findings {
    let mut found = Findings::default();
    // SAFETY: returns a walker object in this process.
    let Ok(walker) = (unsafe { automation.ControlViewWalker() }) else {
        return found;
    };
    let own = std::process::id();
    let mut queue = VecDeque::from([Pending {
        element: root.clone(),
        viewport,
        covered: None,
    }]);
    let mut visited = 0;
    while let Some(next) = queue.pop_front() {
        if visited >= MAX_NODES || found.text.is_full() || Instant::now() >= until {
            break;
        }
        visited += 1;
        let node = Node::cached(&next.element);
        if node.process == Some(own) {
            continue;
        }
        if node.secure == Some(true) && is_text_entry(node.control_type) {
            found.contains_secure_field = true;
            if node.password != Some(true)
                && let Some(source) = next.covered
            {
                found.sources[source]
                    .secure_fields
                    .push(next.element.clone());
            }
        }
        if node.web_document {
            found.has_web_content = true;
            // A link's address is not the page's origin; only a document's
            // own value (its URL in Chromium and Gecko) establishes it.
            let url = node
                .value_pattern
                .then(|| current_string(&next.element, UIA_ValueValuePropertyId))
                .flatten();
            if found.document_name.is_none()
                && let Some(file) = url.as_deref().filter(|url| url.starts_with("file:"))
            {
                found.document_name = sanitized_document_name(Some(file));
            }
            found.web_area_urls.push(url);
        }
        let mut covered = next.covered;
        if include_text {
            let reads = node.reads(next.viewport, covered.is_some());
            if reads.name
                && let Some(name) = cached_name(&next.element)
            {
                found.text.append(&name);
            }
            if reads.ranges
                && let Some(source) = visible_ranges(&next.element, &mut found.text, until)
            {
                found.sources.push(source);
                covered = Some(found.sources.len() - 1);
            }
        }
        if !node.walks_children() {
            continue;
        }
        // Children past MAX_NODES would never be visited; do not fetch them.
        let room = MAX_NODES
            .saturating_sub(visited + queue.len())
            .min(MAX_CHILDREN);
        if room == 0 || Instant::now() >= until {
            continue;
        }
        let viewport = node.child_viewport(next.viewport);
        // SAFETY: each call returns the next element with its properties
        // cached, or an error after the last one.
        let mut child = unsafe { walker.GetFirstChildElementBuildCache(&next.element, cache) }.ok();
        let mut taken = 0;
        while let Some(element) = child {
            taken += 1;
            child = if taken < room && Instant::now() < until {
                // SAFETY: as for the first child.
                unsafe { walker.GetNextSiblingElementBuildCache(&element, cache) }.ok()
            } else {
                None
            };
            queue.push_back(Pending {
                element,
                viewport,
                covered,
            });
        }
    }
    found
}

/// Appends the text of the element's visible ranges (UI Automation's
/// `AXVisibleCharacterRange`); `None` when none of it was text.
fn visible_ranges(
    element: &IUIAutomationElement,
    text: &mut Text,
    until: Instant,
) -> Option<RangeSource> {
    // SAFETY: COM calls on interfaces owned here; the strings are copied.
    unsafe {
        let pattern = element
            .GetCurrentPatternAs::<IUIAutomationTextPattern>(UIA_TextPatternId)
            .ok()?;
        let ranges = pattern.GetVisibleRanges().ok()?;
        let mut lines = Vec::new();
        let mut found = false;
        for index in 0..ranges.Length().unwrap_or(0) {
            if Instant::now() >= until {
                break;
            }
            let Ok(range) = ranges.GetElement(index) else {
                continue;
            };
            let Ok(value) = range.GetText(MAX_CHARACTERS as i32) else {
                continue;
            };
            let value = value.to_string();
            found |= !value.trim().is_empty();
            let kept = text.parts.len();
            let more = text.append(&value);
            if text.parts.len() > kept {
                lines.push((kept, range));
            }
            if !more {
                break;
            }
        }
        found.then_some(RangeSource {
            pattern,
            lines,
            secure_fields: Vec::new(),
        })
    }
}

/// Removes the lines that overlap a secure field: the Mac never reads such
/// a field, but a page's ranges hold its value. The field's own text is not
/// read; lines whose place cannot be compared go too.
fn remove_secure_lines(found: &mut Findings) {
    let mut removed = HashSet::new();
    for source in &found.sources {
        for field in &source.secure_fields {
            // SAFETY: COM calls on interfaces the walk holds; they compare
            // range ends and return no text.
            unsafe {
                let Ok(field) = source.pattern.RangeFromChild(field) else {
                    removed.extend(source.lines.iter().map(|(index, _)| *index));
                    break;
                };
                for (index, line) in &source.lines {
                    let apart = line
                        .CompareEndpoints(
                            TextPatternRangeEndpoint_Start,
                            &field,
                            TextPatternRangeEndpoint_End,
                        )
                        .is_ok_and(|order| order >= 0)
                        || line
                            .CompareEndpoints(
                                TextPatternRangeEndpoint_End,
                                &field,
                                TextPatternRangeEndpoint_Start,
                            )
                            .is_ok_and(|order| order <= 0);
                    if !apart {
                        removed.insert(*index);
                    }
                }
            }
        }
    }
    found.text.remove(&removed);
}

/// What the cache request brought back for one element.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
struct Node {
    control_type: UIA_CONTROLTYPE_ID,
    rect: Option<WindowRect>,
    offscreen: bool,
    /// `IsPassword`; `None` when the provider did not say.
    password: Option<bool>,
    /// A password field or a field named after a secret ([`secure_status`]).
    secure: Option<bool>,
    text_pattern: bool,
    value_pattern: bool,
    scrolls: bool,
    process: Option<u32>,
    /// A browser engine's document: a page or a frame.
    web_document: bool,
}

/// What to read from one element.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
struct Reads {
    name: bool,
    ranges: bool,
}

impl Node {
    fn cached(element: &IUIAutomationElement) -> Node {
        // SAFETY: reads properties cached with the element; none of these
        // calls reaches the target app.
        unsafe {
            let control_type = element.CachedControlType().unwrap_or_default();
            let password = element.CachedIsPassword().ok().map(|value| value.as_bool());
            let labels: Vec<String> = [element.CachedName(), element.CachedHelpText()]
                .into_iter()
                .flatten()
                .map(|label| label.to_string())
                .collect();
            Node {
                control_type,
                rect: element.CachedBoundingRectangle().ok().and_then(window_rect),
                offscreen: element
                    .CachedIsOffscreen()
                    .is_ok_and(|value| value.as_bool()),
                password,
                secure: secure_status(control_type, password, &labels),
                text_pattern: cached_flag(element, UIA_IsTextPatternAvailablePropertyId),
                value_pattern: cached_flag(element, UIA_IsValuePatternAvailablePropertyId),
                scrolls: cached_flag(element, UIA_IsScrollPatternAvailablePropertyId),
                process: element
                    .CachedProcessId()
                    .ok()
                    .and_then(|id| u32::try_from(id).ok())
                    .filter(|&id| id != 0),
                web_document: control_type == UIA_DocumentControlTypeId
                    && element
                        .CachedFrameworkId()
                        .is_ok_and(|id| is_web_engine(&id.to_string())),
            }
        }
    }

    /// `ScreenVisibleTextPolicy.text`: nothing unless the element is known
    /// not to be secure, is on screen and meets the viewport; a label's name
    /// when it lies fully inside the viewport; otherwise the visible ranges
    /// of a text control. Whole values are never read: they can hold a
    /// complete hidden document.
    fn reads(&self, viewport: Option<WindowRect>, covered: bool) -> Reads {
        // A frame's document is not part of its parent document's ranges.
        let covered = covered && self.control_type != UIA_DocumentControlTypeId;
        if covered || self.offscreen || self.secure != Some(false) {
            return Reads::default();
        }
        let (Some(rect), Some(viewport)) = (self.rect, viewport) else {
            return Reads::default();
        };
        if rect.intersection(&viewport).is_none() {
            return Reads::default();
        }
        let name = is_label(self.control_type) && viewport.contains(&rect);
        Reads {
            name,
            ranges: self.text_pattern && !name,
        }
    }

    /// Windows, documents and scrolling containers clip what they hold
    /// (`clipsChildren`).
    fn child_viewport(&self, viewport: Option<WindowRect>) -> Option<WindowRect> {
        let clips = self.scrolls
            || self.control_type == UIA_WindowControlTypeId
            || self.control_type == UIA_DocumentControlTypeId;
        if !clips {
            return viewport;
        }
        viewport?.intersection(&self.rect?)
    }

    /// Offscreen subtrees, password fields and window furniture are skipped.
    fn walks_children(&self) -> bool {
        !self.offscreen && self.password != Some(true) && !is_furniture(self.control_type)
    }
}

/// Controls whose name is their visible text: the Mac's label roles (static
/// text, buttons, check boxes, radio buttons, menu items, links, the window)
/// and the items and headers UI Automation names after their text.
fn is_label(control_type: UIA_CONTROLTYPE_ID) -> bool {
    [
        UIA_TextControlTypeId,
        UIA_ButtonControlTypeId,
        UIA_SplitButtonControlTypeId,
        UIA_CheckBoxControlTypeId,
        UIA_RadioButtonControlTypeId,
        UIA_MenuItemControlTypeId,
        UIA_HyperlinkControlTypeId,
        UIA_WindowControlTypeId,
        UIA_ListItemControlTypeId,
        UIA_TabItemControlTypeId,
        UIA_TreeItemControlTypeId,
        UIA_HeaderControlTypeId,
        UIA_HeaderItemControlTypeId,
        UIA_DataItemControlTypeId,
    ]
    .contains(&control_type)
}

/// `secureFieldStatus`: a password field, or an element whose name or help
/// text names a secret (`CotypingSecureFieldDetector.isSecure`). Labels such
/// as "Password" match too, which keeps their text out; only text entries
/// make the window count as showing a secure field. A document's name is
/// the title of a whole page or file, not a field's label.
fn secure_status(
    control_type: UIA_CONTROLTYPE_ID,
    password: Option<bool>,
    labels: &[String],
) -> Option<bool> {
    let named_secret = control_type != UIA_DocumentControlTypeId
        && labels
            .iter()
            .any(|label| super::privacy::names_a_secret(label));
    if named_secret { Some(true) } else { password }
}

/// `ScreenAccessibilityReader.isTextEntry`: only an input can hold a secret.
fn is_text_entry(control_type: UIA_CONTROLTYPE_ID) -> bool {
    [
        UIA_EditControlTypeId,
        UIA_ComboBoxControlTypeId,
        UIA_DocumentControlTypeId,
    ]
    .contains(&control_type)
}

/// Title bars (caption buttons, system menu) and scroll bars: fixed names,
/// no content.
fn is_furniture(control_type: UIA_CONTROLTYPE_ID) -> bool {
    [UIA_TitleBarControlTypeId, UIA_ScrollBarControlTypeId].contains(&control_type)
}

/// Browser engines: Chromium (Chrome, Edge, Electron, WebView2), Gecko,
/// Trident and EdgeHTML. Word, Notepad and other native documents are not
/// web content and have no page address.
fn is_web_engine(framework_id: &str) -> bool {
    ["Chrome", "Gecko", "InternetExplorer", "MicrosoftEdge"]
        .iter()
        .any(|engine| framework_id.eq_ignore_ascii_case(engine))
}

/// A UI Automation rectangle; `None` when empty or implausibly large (some
/// providers report garbage bounds for hidden elements).
fn window_rect(rect: RECT) -> Option<WindowRect> {
    const LIMIT: i32 = 1 << 24;
    let width = rect.right.checked_sub(rect.left)?;
    let height = rect.bottom.checked_sub(rect.top)?;
    let plausible = (-LIMIT..LIMIT).contains(&rect.left)
        && (-LIMIT..LIMIT).contains(&rect.top)
        && (1..LIMIT).contains(&width)
        && (1..LIMIT).contains(&height);
    plausible.then_some(WindowRect {
        x: rect.left,
        y: rect.top,
        width: width as u32,
        height: height as u32,
    })
}

fn cached_name(element: &IUIAutomationElement) -> Option<String> {
    // SAFETY: reads a property cached with the element.
    unsafe { element.CachedName() }
        .ok()
        .map(|name| name.to_string())
}

/// A cached boolean property; false unless the provider reported true.
fn cached_flag(element: &IUIAutomationElement, property: UIA_PROPERTY_ID) -> bool {
    // SAFETY: the VARIANT is owned here; its union is read only as the type
    // `vt` names, and VariantClear releases what it holds.
    unsafe {
        let Ok(mut value) = element.GetCachedPropertyValue(property) else {
            return false;
        };
        let inner = &value.Anonymous.Anonymous;
        let flag = inner.vt == VT_BOOL && inner.Anonymous.boolVal.0 != 0;
        let _ = VariantClear(&mut value);
        flag
    }
}

/// A string property read from the provider now; `None` when it has none.
fn current_string(element: &IUIAutomationElement, property: UIA_PROPERTY_ID) -> Option<String> {
    // SAFETY: as in `cached_flag`; the BSTR is copied before VariantClear
    // frees it.
    unsafe {
        let mut value = element.GetCurrentPropertyValue(property).ok()?;
        let inner = &value.Anonymous.Anonymous;
        let text = (inner.vt == VT_BSTR).then(|| inner.Anonymous.bstrVal.to_string());
        let _ = VariantClear(&mut value);
        text
    }
}

#[cfg(test)]
mod tests {
    use windows::Win32::UI::Accessibility::UIA_PaneControlTypeId;
    use windows::Win32::UI::WindowsAndMessaging::GetDesktopWindow;

    use super::*;

    fn rect(x: i32, y: i32, width: u32, height: u32) -> Option<WindowRect> {
        Some(WindowRect {
            x,
            y,
            width,
            height,
        })
    }

    fn node(control_type: UIA_CONTROLTYPE_ID, area: Option<WindowRect>) -> Node {
        Node {
            control_type,
            rect: area,
            password: Some(false),
            secure: Some(false),
            ..Node::default()
        }
    }

    #[test]
    fn controls_are_classified_like_the_mac_roles() {
        for label in [
            UIA_TextControlTypeId,
            UIA_ButtonControlTypeId,
            UIA_HyperlinkControlTypeId,
            UIA_WindowControlTypeId,
            UIA_DataItemControlTypeId,
        ] {
            assert!(is_label(label), "{label:?}");
        }
        for other in [
            UIA_EditControlTypeId,
            UIA_DocumentControlTypeId,
            UIA_PaneControlTypeId,
        ] {
            assert!(!is_label(other), "{other:?}");
        }
        assert!(is_text_entry(UIA_EditControlTypeId));
        assert!(is_text_entry(UIA_ComboBoxControlTypeId));
        assert!(is_text_entry(UIA_DocumentControlTypeId));
        assert!(!is_text_entry(UIA_TextControlTypeId));
        assert!(!is_text_entry(UIA_ButtonControlTypeId));
        assert!(is_web_engine("Chrome"));
        assert!(is_web_engine("gecko"));
        assert!(!is_web_engine("Win32"));
        assert!(!is_web_engine("XAML"));
        assert!(!is_web_engine(""));
    }

    #[test]
    fn labels_count_only_when_fully_visible() {
        let viewport = rect(0, 0, 800, 600);
        let label = node(UIA_TextControlTypeId, rect(10, 10, 100, 20));
        let name = Reads {
            name: true,
            ranges: false,
        };
        let ranges = Reads {
            name: false,
            ranges: true,
        };
        assert_eq!(label.reads(viewport, false), name);
        let clipped = node(UIA_TextControlTypeId, rect(750, 10, 100, 20));
        assert_eq!(clipped.reads(viewport, false), Reads::default());
        let clipped_text = Node {
            text_pattern: true,
            ..clipped
        };
        assert_eq!(clipped_text.reads(viewport, false), ranges);
        let outside = Node {
            rect: rect(900, 10, 100, 20),
            ..clipped_text
        };
        assert_eq!(outside.reads(viewport, false), Reads::default());
        assert_eq!(label.reads(None, false), Reads::default());
        assert_eq!(
            label.reads(viewport, true),
            Reads::default(),
            "an ancestor's visible ranges hold it"
        );
        let frame = Node {
            text_pattern: true,
            ..node(UIA_DocumentControlTypeId, rect(10, 100, 300, 200))
        };
        assert_eq!(
            frame.reads(viewport, true),
            ranges,
            "frames have ranges of their own"
        );
        let offscreen = Node {
            offscreen: true,
            ..label.clone()
        };
        assert_eq!(offscreen.reads(viewport, false), Reads::default());
        let unplaced = Node {
            rect: None,
            ..label
        };
        assert_eq!(unplaced.reads(viewport, false), Reads::default());
    }

    #[test]
    fn secure_fields_are_never_read() {
        let viewport = rect(0, 0, 800, 600);
        let field = Node {
            text_pattern: true,
            ..node(UIA_EditControlTypeId, rect(10, 10, 200, 20))
        };
        assert_eq!(
            field.reads(viewport, false),
            Reads {
                name: false,
                ranges: true
            }
        );
        let password = Node {
            password: Some(true),
            secure: Some(true),
            ..field.clone()
        };
        assert_eq!(password.reads(viewport, false), Reads::default());
        assert!(!password.walks_children());
        let named = Node {
            secure: Some(true),
            ..field.clone()
        };
        assert_eq!(named.reads(viewport, false), Reads::default());
        assert!(named.walks_children(), "only password fields end the walk");
        let unknown = Node {
            password: None,
            secure: None,
            ..field
        };
        assert_eq!(unknown.reads(viewport, false), Reads::default());
        assert!(unknown.walks_children());
    }

    #[test]
    fn fields_named_after_secrets_are_secure() {
        let labels =
            |list: &[&str]| -> Vec<String> { list.iter().map(|s| s.to_string()).collect() };
        let edit = UIA_EditControlTypeId;
        assert_eq!(
            secure_status(edit, Some(false), &labels(&["Card number"])),
            Some(true)
        );
        assert_eq!(
            secure_status(edit, Some(false), &labels(&["", "Enter the CVV"])),
            Some(true)
        );
        assert_eq!(
            secure_status(edit, Some(false), &labels(&["Email"])),
            Some(false)
        );
        assert_eq!(
            secure_status(edit, Some(true), &labels(&["Secret"])),
            Some(true)
        );
        assert_eq!(secure_status(edit, None, &labels(&["Email"])), None);
        assert_eq!(
            secure_status(
                UIA_ButtonControlTypeId,
                Some(false),
                &labels(&["Manage passwords"])
            ),
            Some(true)
        );
        assert_eq!(
            secure_status(
                UIA_DocumentControlTypeId,
                Some(false),
                &labels(&["Reset your password"])
            ),
            Some(false),
            "a page title is not a field label"
        );
    }

    #[test]
    fn removed_lines_leave_the_rest_in_order() {
        let mut text = Text::default();
        for line in [
            "Card details",
            "4111 1111 1111 1111",
            "Expires 12/30",
            "Pay",
        ] {
            text.append(line);
        }
        text.remove(&HashSet::from([1, 3]));
        assert_eq!(text.parts, ["Card details", "Expires 12/30"]);
    }

    #[test]
    fn windows_documents_and_scrolling_panes_clip_their_children() {
        let viewport = rect(0, 0, 800, 600);
        let pane = node(UIA_PaneControlTypeId, rect(100, 100, 2000, 2000));
        assert_eq!(pane.child_viewport(viewport), viewport);
        let scrolling = Node {
            scrolls: true,
            ..pane.clone()
        };
        assert_eq!(scrolling.child_viewport(viewport), rect(100, 100, 700, 500));
        let document = node(UIA_DocumentControlTypeId, rect(-50, 200, 300, 300));
        assert_eq!(document.child_viewport(viewport), rect(0, 200, 250, 300));
        let elsewhere = node(UIA_WindowControlTypeId, rect(900, 0, 100, 100));
        assert_eq!(elsewhere.child_viewport(viewport), None);
        assert_eq!(
            node(UIA_WindowControlTypeId, None).child_viewport(viewport),
            None
        );
        assert_eq!(scrolling.child_viewport(None), None);
        assert!(pane.walks_children());
        let offscreen = Node {
            offscreen: true,
            ..pane
        };
        assert!(!offscreen.walks_children());
        assert!(!node(UIA_TitleBarControlTypeId, viewport).walks_children());
        assert!(!node(UIA_ScrollBarControlTypeId, viewport).walks_children());
    }

    #[test]
    fn rectangles_are_checked() {
        let rectangle = |left, top, right, bottom| RECT {
            left,
            top,
            right,
            bottom,
        };
        assert_eq!(
            window_rect(rectangle(10, 20, 110, 70)),
            rect(10, 20, 100, 50)
        );
        assert_eq!(
            window_rect(rectangle(-30, -40, 0, 0)),
            rect(-30, -40, 30, 40)
        );
        assert_eq!(window_rect(RECT::default()), None);
        assert_eq!(window_rect(rectangle(10, 0, 5, 5)), None);
        assert_eq!(window_rect(rectangle(i32::MIN, 0, 0, 5)), None);
        assert_eq!(window_rect(rectangle(0, 0, i32::MAX, 5)), None);
    }

    #[test]
    fn line_breaks_become_newlines() {
        assert_eq!(unix_lines("a\r\nb\rc\nd"), "a\nb\nc\nd");
        let mut text = Text::default();
        assert!(text.append(" one\r\ntwo\r\n"));
        assert_eq!(text.parts, ["one\ntwo"]);
    }

    #[test]
    fn reads_nothing_without_a_window() {
        let started = Instant::now();
        let mut reader = UiaReader::new();
        let read = reader.read(&FocusedWindow::default(), true, Duration::from_millis(200));
        assert!(matches!(read, TextRead::Unavailable(_)), "{read:?}");
        let own = FocusedWindow {
            id: 1,
            pid: Some(std::process::id()),
            ..Default::default()
        };
        assert_eq!(
            reader.read(&own, true, Duration::from_millis(200)),
            TextRead::Unavailable(OWN_WINDOW.into())
        );
        assert!(started.elapsed() < Duration::from_secs(1));
    }

    #[test]
    fn works_without_a_desktop() {
        // Over SSH (session 0) nothing is in front: the desktop window can be
        // walked but is never the foreground window. Readers set up on
        // several threads at once work, and keep working on another thread
        // after the ones that created them have ended.
        // SAFETY: no arguments.
        let desktop = unsafe { GetDesktopWindow() };
        let window = FocusedWindow {
            id: desktop.0 as usize as u64,
            ..Default::default()
        };
        let read = |reader: &mut UiaReader| {
            let started = Instant::now();
            let read = reader.read(&window, false, Duration::from_millis(200));
            let outcome = match &read {
                TextRead::Read(_) => "read".to_string(),
                other => format!("{other:?}"),
            };
            eprintln!("desktop: {outcome} in {:?}", started.elapsed());
            assert!(started.elapsed() < Duration::from_secs(5));
            assert_ne!(
                read,
                TextRead::Unavailable("UI Automation could not prepare a request".into())
            );
        };
        let mut readers: Vec<UiaReader> = std::thread::scope(|scope| {
            let threads: Vec<_> = (0..4)
                .map(|_| {
                    scope.spawn(|| {
                        let mut reader = UiaReader::new();
                        read(&mut reader);
                        reader
                    })
                })
                .collect();
            threads
                .into_iter()
                .map(|thread| thread.join().unwrap())
                .collect()
        });
        for reader in &mut readers {
            read(reader);
        }
    }
}
