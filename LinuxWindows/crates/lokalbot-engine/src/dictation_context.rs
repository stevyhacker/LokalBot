//! Where a Compose writing request gets its context
//! (`DictationScreenContextCapture`, `DictationVisibleContextCapture`,
//! `DictationGrounding`): the focused window, the text above the field, and
//! saved facts. Each has its own grant, and nothing read here is saved.

use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use anyhow::Result;
use crossbeam_channel::Receiver;

use lokalbot_ai::autocomplete::memory::{self, Query, Selection};
use lokalbot_ai::dictation::{ComposeProviders, SavedFacts, ScreenContext, memory_policy};
use lokalbot_ai::think::ThinkClient;
use lokalbot_core::Settings;
use lokalbot_platform::autocomplete::focused;
use lokalbot_platform::autocomplete::policy::{self, ReadPolicy};
use lokalbot_platform::focus::{self, FocusRead};
use lokalbot_platform::screen::{self, FocusedWindow, TextRead, WindowRect, privacy};
use lokalbot_platform::{FocusSnapshot, FrontApp};

use crate::Shared;

const METADATA_DEADLINE: Duration = Duration::from_millis(300);
const TEXT_DEADLINE: Duration = Duration::from_millis(600);
const VISIBLE_DEADLINE: Duration = Duration::from_millis(300);
const FOCUS_DEADLINE: Duration = Duration::from_millis(600);
/// The longest side OCR reads (`DictationCaptureSizing`).
const OCR_MAX_DIMENSION: u32 = 4_096;
/// How long Compose waits for a capture that began during recording.
const SCREEN_WAIT: Duration = Duration::from_secs(20);

/// The app and field that owned focus at the press, when context may be read
/// from it (`DictationScreenPrivacy.allowsCapture`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct ContextTarget {
    pub front: FrontApp,
    pub pid: u32,
    pub identity: Option<String>,
}

impl ContextTarget {
    pub(crate) fn of(snapshot: &FocusSnapshot) -> Option<Self> {
        if snapshot.blocks_context_capture() || snapshot.front.is_self() {
            return None;
        }
        Some(Self {
            front: snapshot.front.clone(),
            pid: snapshot.pid()?,
            identity: snapshot.identity.clone(),
        })
    }

    /// Password managers and the capture exclusions (`isExcluded`).
    pub(crate) fn is_excluded(&self, settings: &Settings) -> bool {
        is_excluded(&self.front, settings)
    }

    /// The bound field still has focus and may still be read.
    fn focus_matches(&self) -> bool {
        let Some(identity) = self.identity.as_deref() else {
            return false;
        };
        match focus::read_focus(FOCUS_DEADLINE) {
            FocusRead::Snapshot(snapshot) => {
                !snapshot.blocks_context_capture()
                    && snapshot.pid() == Some(self.pid)
                    && snapshot.identity.as_deref() == Some(identity)
            }
            _ => false,
        }
    }
}

pub(crate) fn is_excluded(front: &FrontApp, settings: &Settings) -> bool {
    policy::is_excluded(
        &front.app_name,
        &front.app_id,
        &settings.excluded_app_list(),
    ) || lokalbot_platform::privacy::is_password_manager(&front.app_name, &front.app_id)
}

/// The exact window a context belongs to. A process is too broad: switching
/// documents in one app must invalidate the captured title and address.
#[derive(Clone, Debug, PartialEq, Eq)]
struct ScreenIdentity {
    window: u64,
    title: String,
    rect: Option<WindowRect>,
    url: Option<String>,
}

/// One screen context and what it must keep matching.
#[derive(Clone, Debug)]
pub(crate) struct CapturedScreen {
    context: ScreenContext,
    identity: ScreenIdentity,
}

fn observation(
    target: &ContextTarget,
    window: &FocusedWindow,
    accessible: &screen::AccessibleWindow,
) -> privacy::Observation {
    privacy::Observation {
        app_name: target.front.app_name.clone(),
        app_id: target.front.app_id.clone(),
        window_title: accessible
            .window_title
            .clone()
            .or_else(|| Some(window.title.clone()).filter(|t| !t.is_empty())),
        source_url: accessible.source_url.clone(),
        focused_secure_field: accessible.focused_secure_field,
        has_web_content: accessible.has_web_content,
        contains_secure_field: accessible.contains_secure_field,
        framed_urls: accessible.framed_urls.clone(),
        has_unattributed_web_content: accessible.has_unattributed_web_content,
    }
}

fn permitted(observation: &privacy::Observation, settings: &Settings) -> bool {
    privacy::permits_content(
        observation,
        &settings.excluded_app_list(),
        &settings.excluded_domain_list(),
        false,
    ) && !observation
        .window_title
        .as_deref()
        .is_some_and(lokalbot_platform::privacy::is_private_window)
}

/// The window a dictation was pasted into, read once, only while Learn from my
/// dictation is on. Held in memory to decide whether to keep the words.
pub(crate) struct LearningSurface {
    window_title: Option<String>,
    page_url: Option<String>,
    has_web_content: bool,
}

impl ContextTarget {
    /// The target and what its window shows. Only text pasted into a field it could
    /// identify is kept; a password field or a blocked field keeps nothing.
    pub(crate) fn of_learning(
        read: &FocusRead,
        front: FrontApp,
    ) -> Option<(Self, LearningSurface)> {
        let FocusRead::Snapshot(snapshot) = read else {
            return None;
        };
        if snapshot.blocks_context_capture() || snapshot.identity.is_none() {
            return None;
        }
        let target = Self {
            front,
            pid: snapshot.pid()?,
            identity: snapshot.identity.clone(),
        };
        let window = screen::window_capture().focused().ok()??;
        let accessible = read_window(&window, false, METADATA_DEADLINE)?;
        let observed = observation(&target, &window, &accessible);
        if observed.focused_secure_field != Some(false) {
            return None;
        }
        let surface = LearningSurface {
            window_title: observed.window_title.clone(),
            page_url: observed.source_url.clone(),
            has_web_content: observed.has_web_content,
        };
        Some((target, surface))
    }
}

/// `DictationLearningPolicy.permits`: the same app, website and private-window
/// exclusions as nearby text. A browser whose page address can't be read can't be
/// checked against the website exclusions, so its dictation isn't kept.
pub(crate) fn learning_permits(
    target: &ContextTarget,
    surface: &LearningSurface,
    settings: &Settings,
) -> bool {
    use lokalbot_platform::privacy as rules;
    if target.is_excluded(settings) {
        return false;
    }
    if rules::is_browser(&target.front.app_name, &target.front.app_id)
        && rules::sanitized_url(surface.page_url.as_deref()).is_none()
    {
        return false;
    }
    if surface
        .window_title
        .as_deref()
        .is_some_and(rules::is_private_window)
    {
        return false;
    }
    let observed = privacy::Observation {
        app_name: target.front.app_name.clone(),
        app_id: target.front.app_id.clone(),
        window_title: surface.window_title.clone(),
        source_url: surface.page_url.clone(),
        focused_secure_field: Some(false),
        has_web_content: surface.has_web_content,
        contains_secure_field: false,
        framed_urls: Vec::new(),
        has_unattributed_web_content: false,
    };
    privacy::permits_content(
        &observed,
        &settings.excluded_app_list(),
        &settings.excluded_domain_list(),
        false,
    )
}

fn read_window(
    window: &FocusedWindow,
    include_text: bool,
    deadline: Duration,
) -> Option<screen::AccessibleWindow> {
    match screen::text_reader().read(window, include_text, deadline) {
        TextRead::Read(accessible) => Some(accessible),
        _ => None,
    }
}

/// The same window, with the same title and address, still in front and
/// allowed, and the same field still has focus.
fn still_matches(target: &ContextTarget, identity: &ScreenIdentity, settings: &Settings) -> bool {
    let Ok(Some(window)) = screen::window_capture().focused() else {
        return false;
    };
    if window.id != identity.window || window.rect != identity.rect {
        return false;
    }
    let Some(accessible) = read_window(&window, false, METADATA_DEADLINE) else {
        return false;
    };
    let observed = observation(target, &window, &accessible);
    observed.window_title.as_deref() == Some(identity.title.as_str())
        && observed.source_url == identity.url
        && permitted(&observed, settings)
        && target.focus_matches()
}

/// Reads the focused window for one request: its title and address always,
/// its accessible text when it shares enough, otherwise on-device OCR when
/// installed. The portal can prompt, and a shortcut must never prompt, so a
/// desktop that needs it gets metadata only. Returns `None` rather than any
/// other window; nothing here is written to disk.
pub(crate) fn capture_screen(
    target: &ContextTarget,
    settings: &Settings,
    paths: &lokalbot_core::LibraryPaths,
    cancelled: &AtomicBool,
) -> Option<CapturedScreen> {
    if target.is_excluded(settings) || !target.focus_matches() {
        return None;
    }
    let mut capture = screen::window_capture();
    let window = capture.focused().ok()??;
    if window.pid.is_some_and(|pid| pid != target.pid) && !cfg!(windows) {
        return None;
    }
    let accessible = read_window(&window, true, TEXT_DEADLINE)?;
    let observed = observation(target, &window, &accessible);
    if !permitted(&observed, settings) || cancelled.load(Ordering::Relaxed) {
        return None;
    }
    let title = observed.window_title.clone()?;
    let identity = ScreenIdentity {
        window: window.id,
        title: title.clone(),
        rect: window.rect,
        url: observed.source_url.clone(),
    };
    if !still_matches(target, &identity, settings) {
        return None;
    }
    let text = if privacy::has_rich_accessible_text(&accessible.text) {
        accessible.text.clone()
    } else if capture.name() != "portal" && lokalbot_ai::ocr::is_installed(paths) {
        let recognized = capture.capture(&window).ok().and_then(|image| {
            if cancelled.load(Ordering::Relaxed) {
                return None;
            }
            let image = image.bounded(OCR_MAX_DIMENSION);
            lokalbot_ai::ocr::OcrEngine::load(paths)
                .ok()?
                .recognize(&image.rgba, image.width, image.height)
                .ok()
        });
        recognized.unwrap_or_else(|| accessible.text.clone())
    } else {
        accessible.text.clone()
    };
    if cancelled.load(Ordering::Relaxed) || !still_matches(target, &identity, settings) {
        return None;
    }
    Some(CapturedScreen {
        context: ScreenContext {
            app_name: target.front.app_name.clone(),
            bundle_id: Some(target.front.app_id.clone()).filter(|id| !id.is_empty()),
            window_title: lokalbot_platform::redact(&title).0,
            visible_text: lokalbot_platform::redact(&text).0,
        },
        identity,
    })
}

/// A read of the text above the field, under this settings' exclusions.
fn visible_text(target: &ContextTarget, settings: &Settings) -> Option<String> {
    let identity = target.identity.clone()?;
    let (pid, front) = (target.pid, target.front.clone());
    let policy = ReadPolicy {
        enabled: true,
        capture_excluded_apps: settings.excluded_app_list(),
        capture_excluded_domains: settings.excluded_domain_list(),
        visible_text: true,
        ..ReadPolicy::default()
    };
    focus::with_deadline(VISIBLE_DEADLINE, move || {
        focused::visible_text(pid, &identity, &front.app_name, &front.app_id, &policy)
    })
    .flatten()
}

/// The focused window's context arrives from a capture that began during
/// recording; the rest is read when Compose asks.
pub(crate) struct LiveProviders<'a> {
    pub shared: &'a Shared,
    pub target: Option<ContextTarget>,
    pub screen: Option<Receiver<Option<CapturedScreen>>>,
    pub is_current: &'a dyn Fn() -> bool,
    identity: Option<ScreenIdentity>,
    selection: Selection,
    query: Option<Query>,
}

impl<'a> LiveProviders<'a> {
    pub(crate) fn new(
        shared: &'a Shared,
        target: Option<ContextTarget>,
        screen: Option<Receiver<Option<CapturedScreen>>>,
        is_current: &'a dyn Fn() -> bool,
    ) -> Self {
        Self {
            shared,
            target,
            screen,
            is_current,
            identity: None,
            selection: Selection::default(),
            query: None,
        }
    }
}

impl ComposeProviders for LiveProviders<'_> {
    fn cancelled(&self) -> bool {
        !(self.is_current)()
    }

    fn current_settings(&self) -> Settings {
        self.shared.settings()
    }

    fn screen(&mut self) -> Option<ScreenContext> {
        let captured = self.screen.take()?.recv_timeout(SCREEN_WAIT).ok().flatten();
        let captured = captured?;
        self.identity = Some(captured.identity);
        Some(captured.context)
    }

    fn visible(&mut self) -> Option<String> {
        let target = self.target.as_ref()?;
        visible_text(target, &self.shared.settings()).filter(|text| !text.is_empty())
    }

    fn memory(
        &mut self,
        speech: &str,
        screen: Option<&ScreenContext>,
        visible: Option<&str>,
        settings: &Settings,
    ) -> SavedFacts {
        // A spoken writing request, not typed shell or code input. The title
        // joins the query only when a window grant allows it.
        let title =
            if settings.dictation_use_screen_context || settings.dictation_use_visible_context {
                screen.map_or("", |s| s.window_title.as_str())
            } else {
                ""
            };
        let query = Query::for_field(
            memory::finished_words(speech),
            title,
            visible.unwrap_or(""),
            "Dictation",
            "",
        );
        self.selection =
            crate::autocomplete::look_up(&self.shared.library, &query, memory_policy(settings));
        self.query = Some(query);
        SavedFacts {
            text: self.selection.text(),
            source_titles: self.selection.source_titles(),
        }
    }

    /// Source edits and deletion invalidate the facts: looking up again must
    /// find the same ones.
    fn memory_is_current(&mut self, facts: &SavedFacts, current: &Settings) -> bool {
        if facts.text.is_none() {
            return true;
        }
        let Some(query) = self.query.as_ref() else {
            return false;
        };
        crate::autocomplete::look_up(&self.shared.library, query, memory_policy(current))
            == self.selection
    }

    fn visible_is_current(&mut self, text: &str, current: &Settings) -> bool {
        self.target
            .as_ref()
            .and_then(|target| visible_text(target, current))
            .as_deref()
            == Some(text)
    }

    fn screen_is_current(&mut self, _: &ScreenContext, current: &Settings) -> bool {
        match (self.target.as_ref(), self.identity.as_ref()) {
            (Some(target), Some(identity)) => still_matches(target, identity, current),
            _ => false,
        }
    }

    fn make_think(&mut self, settings: &Settings) -> Result<ThinkClient> {
        Ok(self.shared.think(settings)?.with_priority(
            lokalbot_ai::remote_gate::Priority::Interactive,
            "dictation compose",
        ))
    }
}
