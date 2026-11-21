//! Meeting detection (`MeetingDetector.swift`, `MeetingMatcher.swift`,
//! `BrowserMeetingSession.StartGate`).
//!
//! Microphone evidence comes from the meeting app's own WASAPI capture session
//! on Windows or its PulseAudio/PipeWire source output on Linux. Zoom, Webex, Tencent Meeting and VooV Meeting
//! start at once; Teams, Slack, Discord, Feishu, Lark, DingTalk and WeCom need
//! 12 s of sustained evidence (gaps up to 6 s tolerated). A meeting ends
//! `stop_debounce` after its evidence disappears.
//!
//! Google Meet can also use the browser's title and microphone. On Windows,
//! Telemost and MTS Link browser calls use a verified room and its joined-call
//! controls for start, and its bound tab or window for continuation. An
//! explicit end in the accessibility tree ([`browser`]) stops immediately.
//!
//! The calendar ([`CalendarHint`], `MeetingDetector.swift`) adds evidence but
//! never replaces it: a browser holding the microphone during an event with
//! a conferencing link is a call even without a Meet title, a chat app starts
//! without the sustained wait while an event is on, and a native app gets
//! extra stop grace inside its event's scheduled window. Apps detected only
//! through sustained microphone use keep the configured stop delay.
//!
//! Poll [`MeetingDetector::poll`] every ~2 s from one background thread.

use std::collections::HashMap;
use std::time::{Duration, Instant};

pub(crate) mod browser;
#[cfg(target_os = "linux")]
mod linux;
#[cfg(windows)]
mod win32;

pub use browser::meet_url;
use browser::{BrowserDocument, Verdict};
use lokalbot_core::calendar::{MeetingService, meeting_room};
use lokalbot_core::settings::{AdditionalCallApp, normalized_executable_name as normalized};

/// A meeting the detector is tracking.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DetectedMeeting {
    /// The app's name, such as "Zoom", "Tencent Meeting" or "Google Meet".
    pub app_name: String,
    /// The app or browser supplying detection evidence ("Zoom.exe", "chrome").
    pub process_name: String,
    pub pid: u32,
    /// The top process of the app, whose tree plays the call's sound.
    pub audio_pid: u32,
    /// The room, when the browser's accessibility tree named it.
    pub meeting_url: Option<String>,
    /// The meeting's name from a browser tab title ("Meet – Weekly sync"),
    /// when it has one.
    pub title_hint: Option<String>,
}

/// What the calendar says about now; set before each poll.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct CalendarHint {
    /// A calendar event is active (`calendarBacked` for native apps).
    pub active: bool,
    /// The active event's conferencing link, if any.
    pub meeting_url: Option<String>,
    /// Browser calls count only with `meeting_url` (`requireCalendarForBrowser`).
    pub require_for_browser: bool,
    /// Stop grace for a native app while its event is in its scheduled window
    /// (`calendarBackedGrace`). Browser and sustained-microphone calls never get it.
    pub grace: Option<Duration>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum DetectorEvent {
    Started(DetectedMeeting),
    Ended(DetectedMeeting),
}

/// One process holding an active microphone stream.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(crate) struct CaptureStream {
    pub pid: u32,
    /// Executable file name as the OS reports it.
    pub process_name: String,
    /// PulseAudio `application.name`, when known.
    pub app_name: Option<String>,
    /// Executable names of the parent processes, nearest first (Windows).
    pub ancestors: Vec<String>,
    /// Their process ids, in the same order.
    pub ancestor_pids: Vec<u32>,
}

impl CaptureStream {
    /// The topmost process in this stream's chain that belongs to the app.
    fn app_root(&self, belongs: impl Fn(&str) -> bool) -> u32 {
        let mut root = self.pid;
        for (name, pid) in self.ancestors.iter().zip(&self.ancestor_pids) {
            if belongs(name) {
                root = *pid;
            }
        }
        root
    }
}

/// A top-level window, for browser tab titles.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(crate) struct WindowTitle {
    /// Executable name, or a Linux app id / `WM_CLASS`.
    pub app: String,
    pub title: String,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(crate) struct Evidence {
    pub capturing: Vec<CaptureStream>,
    pub windows: Vec<WindowTitle>,
    /// Meeting documents read from the accessibility tree.
    pub documents: Vec<BrowserDocument>,
}

pub(crate) trait EvidenceSource: Send {
    fn collect(&mut self) -> anyhow::Result<Evidence>;
    fn limitation(&self) -> Option<String> {
        None
    }
}

/// The macOS stop debounce default and range (`stopDebounceSeconds`).
pub const DEFAULT_STOP_DEBOUNCE: Duration = Duration::from_secs(15);
const MIN_STOP_DEBOUNCE: Duration = Duration::from_secs(5);
const MAX_STOP_DEBOUNCE: Duration = Duration::from_secs(120);
/// `nativeAudioMinimumConfirmationDuration`.
const SUSTAINED_START: Duration = Duration::from_secs(12);
/// `nativeAudioConfirmationGapTolerance`.
const SUSTAINED_GAP: Duration = Duration::from_secs(6);
/// `BrowserMeetingSession.StartGate`: in call for 2 s, gaps up to 4 s.
const BROWSER_START: Duration = Duration::from_secs(2);
const BROWSER_GAP: Duration = Duration::from_secs(4);
/// A Meet title reported through [`MeetingDetector::observe_window`] counts
/// for this long after the tab lost focus.
const OBSERVED_TITLE_LIFETIME: Duration = Duration::from_secs(10 * 60);

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
enum AppKind {
    Zoom,
    Webex,
    Teams,
    Slack,
    Discord,
    TencentMeeting,
    VoovMeeting,
    Feishu,
    Lark,
    DingTalk,
    WeCom,
    #[cfg(windows)]
    TelemostDesktop,
    TelemostWeb,
    MtsLink,
    Meet,
    Express,
    ConfiguredDesktop,
    MicrophoneBrowser,
    /// A browser call on a conferencing site other than Meet, known from the
    /// calendar event's link ("Zoom", "Teams", …).
    WebCall(&'static str),
}

impl AppKind {
    fn name(self) -> &'static str {
        match self {
            Self::Zoom => "Zoom",
            Self::Webex => "Webex",
            Self::Teams => "Teams",
            Self::Slack => "Slack",
            Self::Discord => "Discord",
            Self::TencentMeeting => "Tencent Meeting",
            Self::VoovMeeting => "VooV Meeting",
            Self::Feishu => "Feishu",
            Self::Lark => "Lark",
            Self::DingTalk => "DingTalk",
            Self::WeCom => "WeCom",
            #[cfg(windows)]
            Self::TelemostDesktop => "Yandex Telemost",
            Self::TelemostWeb => "Yandex Telemost",
            Self::MtsLink => "MTS Link",
            Self::Meet => "Google Meet",
            Self::Express => "eXpress",
            Self::ConfiguredDesktop => "Desktop call",
            Self::MicrophoneBrowser => "Browser call",
            Self::WebCall(name) => name,
        }
    }

    fn in_browser(self) -> bool {
        matches!(
            self,
            Self::Meet
                | Self::TelemostWeb
                | Self::MtsLink
                | Self::WebCall(_)
                | Self::MicrophoneBrowser
        )
    }

    fn requires_room(self) -> bool {
        matches!(self, Self::TelemostWeb | Self::MtsLink)
    }

    fn requires_sustained_mic(self) -> bool {
        matches!(
            self,
            Self::Express | Self::ConfiguredDesktop | Self::MicrophoneBrowser
        )
    }

    /// Dedicated conferencing apps start at once; chat apps make short sounds
    /// and need sustained evidence (`requiresSustainedAudioForStart`).
    fn needs_sustained_evidence(self) -> bool {
        matches!(
            self,
            Self::Teams
                | Self::Slack
                | Self::Discord
                | Self::Feishu
                | Self::Lark
                | Self::DingTalk
                | Self::WeCom
        ) || self.is_telemost_desktop()
    }

    fn is_telemost_desktop(self) -> bool {
        #[cfg(windows)]
        if self == Self::TelemostDesktop {
            return true;
        }
        false
    }

    fn priority(self) -> u8 {
        match self {
            Self::Zoom | Self::Webex | Self::TencentMeeting | Self::VoovMeeting => 0,
            Self::Teams => 1,
            Self::Meet | Self::TelemostWeb | Self::MtsLink | Self::WebCall(_) => 2,
            #[cfg(windows)]
            Self::TelemostDesktop => 3,
            Self::Slack | Self::Feishu | Self::Lark | Self::DingTalk | Self::WeCom => 3,
            Self::Discord => 4,
            Self::Express | Self::ConfiguredDesktop => 5,
            Self::MicrophoneBrowser => 6,
        }
    }
}

#[cfg(windows)]
pub fn has_built_in_call_detection(executable: &str) -> bool {
    native_kind(executable).is_some()
        || browser_family(executable).is_some()
        || normalized(executable) == "мтс линк"
}

/// Native meeting apps by executable (Windows and Linux names).
fn native_kind(process: &str) -> Option<AppKind> {
    Some(match normalized(process).as_str() {
        "zoom" | "zoom.real" | "cpthost" | "zoomwebviewhost" | "zoomworkplace" => AppKind::Zoom,
        "ciscocollabhost" | "atmgr" | "webex" | "webexmta" | "webexhost" => AppKind::Webex,
        "ms-teams" | "teams" | "teams-for-linux" | "msteams" => AppKind::Teams,
        "slack" => AppKind::Slack,
        "discord" | "discordptb" | "discordcanary" | "vesktop" => AppKind::Discord,
        "wemeetapp" | "wemeet" | "tencentmeeting" => AppKind::TencentMeeting,
        "voovmeeting" | "voovmeetingapp" => AppKind::VoovMeeting,
        "feishu" | "bytedance-feishu" => AppKind::Feishu,
        "lark" | "bytedance-lark" => AppKind::Lark,
        "dingtalk" | "com.alibabainc.dingtalk" => AppKind::DingTalk,
        "wxwork" | "wecom" => AppKind::WeCom,
        "express" if cfg!(any(windows, test)) => AppKind::Express,
        #[cfg(windows)]
        "yandextelemost" => AppKind::TelemostDesktop,
        _ => return None,
    })
}

/// Browser executables, grouped so that helper processes share a family.
fn browser_family(process: &str) -> Option<&'static str> {
    Some(match normalized(process).as_str() {
        "chrome" | "google-chrome" | "google-chrome-stable" | "chromium" | "chromium-browser" => {
            "chrome"
        }
        "msedge" | "microsoft-edge" | "microsoft-edge-stable" => "edge",
        "firefox" | "firefox-bin" | "firefox-esr" | "librewolf" => "firefox",
        "brave" | "brave-browser" => "brave",
        "opera" => "opera",
        "vivaldi" | "vivaldi-bin" => "vivaldi",
        "arc" => "arc",
        "yandex" => "yandex",
        "zen" | "zen-bin" => "zen",
        _ => return None,
    })
}

/// The native MTS Link client uses the same room UI as its web client.
#[cfg(windows)]
fn document_family(process: &str) -> Option<&'static str> {
    if normalized(process) == "мтс линк" {
        Some("mts-link")
    } else {
        browser_family(process)
    }
}

fn document_kind(url: &str) -> Option<AppKind> {
    Some(match meeting_room(url)?.service {
        MeetingService::GoogleMeet => AppKind::Meet,
        MeetingService::Telemost => AppKind::TelemostWeb,
        MeetingService::MtsLink => AppKind::MtsLink,
    })
}

/// Browser family for a window's app (executable, desktop id or class).
fn window_browser_family(app: &str) -> Option<&'static str> {
    let lower = app.to_lowercase();
    browser_family(&lower).or_else(|| {
        let last = lower.rsplit('.').next().unwrap_or(&lower);
        browser_family(last).or(match lower.as_str() {
            "google chrome" | "com.google.chrome" => Some("chrome"),
            "microsoft edge" | "com.microsoft.edge" => Some("edge"),
            "org.mozilla.firefox" | "navigator" => Some("firefox"),
            "com.brave.browser" | "brave browser" => Some("brave"),
            _ => None,
        })
    })
}

/// Whether a window title belongs to a Google Meet tab, and the meeting name
/// it shows ("Meet – Weekly sync" → "Weekly sync"; a bare meeting code gives
/// no name).
fn meet_title(title: &str) -> Option<Option<String>> {
    let trimmed = title.trim();
    let lower = trimmed.to_lowercase();
    let rest = ["meet - ", "meet – ", "meet — "]
        .iter()
        .find_map(|prefix| lower.starts_with(prefix).then(|| &trimmed[prefix.len()..]));
    let Some(rest) = rest else {
        return lower.contains("google meet").then_some(None);
    };
    // Drop the browser's own suffix (" - Google Chrome", " — Mozilla Firefox").
    let name = [" - ", " – ", " — "]
        .iter()
        .filter_map(|separator| rest.rfind(separator).map(|at| &rest[..at]))
        .min_by_key(|name| name.len())
        .unwrap_or(rest)
        .trim();
    let is_code = {
        let parts: Vec<&str> = name.split('-').collect();
        parts.len() == 3
            && [3, 4, 3].iter().zip(&parts).all(|(len, part)| {
                part.len() == *len && part.chars().all(|c| c.is_ascii_lowercase())
            })
    };
    Some((!name.is_empty() && !is_code).then(|| name.to_string()))
}

/// The kind of browser call a calendar link names.
fn link_kind(url: &str) -> Option<AppKind> {
    if !lokalbot_core::calendar::is_meeting_url(url) {
        return None;
    }
    let host = lokalbot_core::calendar::url_host(url)?;
    let is = |domain: &str| host == domain || host.ends_with(&format!(".{domain}"));
    Some(if let Some(kind) = document_kind(url) {
        kind
    } else if is("meet.google.com") {
        AppKind::Meet
    } else if is("zoom.us") || is("zoom.com") {
        AppKind::WebCall("Zoom")
    } else if is("teams.microsoft.com") || is("teams.live.com") {
        AppKind::WebCall("Teams")
    } else if is("webex.com") {
        AppKind::WebCall("Webex")
    } else if is("jit.si") {
        AppKind::WebCall("Jitsi Meet")
    } else if is("whereby.com") {
        AppKind::WebCall("Whereby")
    } else if is("meeting.tencent.com") || is("voovmeeting.com") {
        AppKind::WebCall("Tencent Meeting")
    } else if is("vc.feishu.cn") || is("vc.larksuite.com") {
        AppKind::WebCall("Feishu")
    } else if is("meeting.dingtalk.com") {
        AppKind::WebCall("DingTalk")
    } else {
        AppKind::WebCall("Browser call")
    })
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct Candidate {
    kind: AppKind,
    /// Browser family for Meet, so a call stays with its browser.
    family: Option<&'static str>,
    /// Normalized executable key selected by the user; display names need not be unique.
    configured_executable: Option<String>,
    meeting: DetectedMeeting,
}

impl Candidate {
    fn same_app(&self, other: &Candidate) -> bool {
        self.kind == other.kind
            && self.family == other.family
            && self.configured_executable == other.configured_executable
    }
}

/// `MeetingMatcher.StartConfirmationState` and `StartGate` in one: how long
/// a candidate's evidence has lasted.
#[derive(Clone, Debug)]
struct Confirmation {
    kind: AppKind,
    family: Option<&'static str>,
    room: Option<String>,
    configured_executable: Option<String>,
    first_seen: Instant,
    last_seen: Instant,
}

struct Active {
    candidate: Candidate,
    stop_at: Option<Instant>,
}

/// The decision logic, separate from the OS so it can be tested with a fake
/// clock and fake evidence.
struct Core {
    stop_debounce: Duration,
    own_pid: u32,
    active: Option<Active>,
    pending: Option<Confirmation>,
    /// Meet titles seen through `observe_window`, by browser family.
    observed_titles: HashMap<&'static str, (Option<String>, Instant)>,
    calendar: CalendarHint,
    detect_other_browser_calls: bool,
    additional_call_apps: HashMap<String, String>,
}

impl Core {
    fn new(own_pid: u32) -> Self {
        Self {
            stop_debounce: DEFAULT_STOP_DEBOUNCE,
            own_pid,
            active: None,
            pending: None,
            observed_titles: HashMap::new(),
            calendar: CalendarHint::default(),
            detect_other_browser_calls: false,
            additional_call_apps: HashMap::new(),
        }
    }

    fn microphone_browser_allowed(&self, windows: &[WindowTitle], family: &str) -> bool {
        if !self.detect_other_browser_calls {
            return false;
        }
        let mut own = windows
            .iter()
            .filter(|window| window_browser_family(&window.app) == Some(family));
        own.next().is_some_and(|first| {
            !crate::privacy::is_private_window(&first.title)
                && own.all(|window| !crate::privacy::is_private_window(&window.title))
        })
    }

    fn observe_window(&mut self, app: &str, title: &str, now: Instant) {
        if let (Some(family), Some(name)) = (window_browser_family(app), meet_title(title)) {
            self.observed_titles.insert(family, (name, now));
        }
    }

    /// Meeting candidates in priority order, one per app.
    /// `current` keeps an active call tied to its room, or to the browser's
    /// microphone for services that don't require room evidence.
    fn candidates(
        &mut self,
        evidence: &Evidence,
        current: Option<&Candidate>,
        now: Instant,
    ) -> Vec<Candidate> {
        let active_browser = current
            .filter(|candidate| candidate.kind.in_browser())
            .and_then(|candidate| Some((candidate.kind, candidate.family?)));
        let link_kind = self.calendar.meeting_url.as_deref().and_then(link_kind);
        let browsers_allowed =
            !self.calendar.require_for_browser || self.calendar.meeting_url.is_some();
        self.observed_titles
            .retain(|_, (_, seen)| now.duration_since(*seen) <= OBSERVED_TITLE_LIFETIME);
        let mut meet_windows: HashMap<&'static str, Option<String>> = HashMap::new();
        for window in &evidence.windows {
            if let (Some(family), Some(name)) = (
                window_browser_family(&window.app),
                meet_title(&window.title),
            ) {
                let entry = meet_windows.entry(family).or_insert(None);
                if entry.is_none() {
                    *entry = name;
                }
            }
        }
        for (family, (name, _)) in &self.observed_titles {
            let entry = meet_windows.entry(family).or_insert(None);
            if entry.is_none() {
                *entry = name.clone();
            }
        }

        let required_room = self
            .calendar
            .require_for_browser
            .then(|| self.calendar.meeting_url.as_deref().and_then(meeting_room))
            .flatten();
        let mut found: Vec<Candidate> = Vec::new();
        if browsers_allowed {
            for document in &evidence.documents {
                let Some(host_pid) = document.host_pid else {
                    continue;
                };
                let Some(kind) = document_kind(&document.url) else {
                    continue;
                };
                if kind == AppKind::Meet || host_pid == self.own_pid {
                    continue;
                }
                let active_room = current
                    .filter(|call| call.family == Some(document.family))
                    .and_then(|call| call.meeting.meeting_url.as_deref());
                let expected =
                    active_room.or_else(|| required_room.as_ref().map(|room| room.url.as_str()));
                let read = browser::verdict(&evidence.documents, document.family, expected);
                let matches_call = read == Verdict::InCall(Some(document.url.clone()));
                #[cfg(any(windows, test))]
                let still_present =
                    read == Verdict::Present && active_room == Some(document.url.as_str());
                #[cfg(not(any(windows, test)))]
                let still_present = false;
                if matches_call || still_present {
                    found.push(Candidate {
                        kind,
                        family: Some(document.family),
                        configured_executable: None,
                        meeting: DetectedMeeting {
                            app_name: kind.name().to_string(),
                            process_name: document.family.to_string(),
                            pid: host_pid,
                            audio_pid: host_pid,
                            meeting_url: Some(document.url.clone()),
                            title_hint: None,
                        },
                    });
                }
            }
        }
        for stream in &evidence.capturing {
            if stream.pid == self.own_pid {
                continue;
            }
            let names = std::iter::once(stream.process_name.as_str())
                .chain(stream.ancestors.iter().map(String::as_str));
            // Keep specialist room evidence for the desktop MTS Link client,
            // even when a helper's name was included in the custom list.
            let mts_desktop = names.clone().any(|name| normalized(name) == "мтс линк");
            let mut candidate = None;
            let mut room = None;
            let mut configured = None;
            for name in names {
                if let Some(kind) = native_kind(name) {
                    candidate = Some((kind, None, None));
                    break;
                }
                if !mts_desktop
                    && browser_family(name).is_none()
                    && let Some((key, display_name)) =
                        self.additional_call_apps.get_key_value(&normalized(name))
                {
                    configured = Some((key, display_name));
                    candidate = Some((AppKind::ConfiguredDesktop, None, None));
                    break;
                }
                if let Some(family) = browser_family(name) {
                    if !browsers_allowed {
                        break;
                    }
                    let expected = current
                        .filter(|c| c.family == Some(family))
                        .and_then(|c| c.meeting.meeting_url.as_deref());
                    let read = browser::verdict(&evidence.documents, family, expected);
                    let denied = matches!(read, Verdict::NotInCall | Verdict::Ended);
                    if let Verdict::InCall(url) = read {
                        if url
                            .as_deref()
                            .and_then(document_kind)
                            .is_some_and(AppKind::requires_room)
                        {
                            // The verified-room path above owns authorization and
                            // loopback selection for these services.
                            break;
                        }
                        room = url;
                        let hint = meet_windows.get(family).cloned().flatten();
                        candidate = Some((AppKind::Meet, Some(family), hint));
                    } else if !denied && let Some(hint) = meet_windows.get(family) {
                        candidate = Some((AppKind::Meet, Some(family), hint.clone()));
                    } else if let Some((kind, active_family)) = active_browser
                        && active_family == family
                        && read != Verdict::Ended
                        && !kind.requires_room()
                        && kind != AppKind::MicrophoneBrowser
                    {
                        // Keep the legacy microphone fallback for other calls.
                        candidate = Some((kind, Some(family), None));
                    } else if (read == Verdict::Unknown
                        || active_browser == Some((AppKind::MicrophoneBrowser, family)))
                        && self.microphone_browser_allowed(&evidence.windows, family)
                    {
                        candidate = Some((AppKind::MicrophoneBrowser, Some(family), None));
                    } else if let Some(kind) = link_kind
                        && !(denied && kind == AppKind::Meet)
                        && !kind.requires_room()
                    {
                        // The calendar's link check: the browser holds the
                        // microphone during an event with a conferencing link.
                        candidate = Some((kind, Some(family), None));
                    }
                    break;
                }
            }
            if candidate.is_none()
                && let Some(app_name) = &stream.app_name
            {
                // PulseAudio names such as "ZOOM VoiceEngine".
                let lower = app_name.to_lowercase();
                if lower.starts_with("zoom") {
                    candidate = Some((AppKind::Zoom, None, None));
                }
            }
            let Some((kind, family, title_hint)) = candidate else {
                continue;
            };
            let audio_pid = stream.app_root(|name| match (family, configured) {
                (Some(family), _) => browser_family(name) == Some(family),
                (None, Some((key, _))) => normalized(name) == *key,
                (None, None) => native_kind(name) == Some(kind),
            });
            let next = Candidate {
                kind,
                family,
                configured_executable: configured.map(|(key, _)| key.clone()),
                meeting: DetectedMeeting {
                    app_name: configured
                        .map(|(_, name)| name.clone())
                        .unwrap_or_else(|| kind.name().to_string()),
                    process_name: stream.process_name.clone(),
                    pid: if kind.requires_sustained_mic() {
                        audio_pid
                    } else {
                        stream.pid
                    },
                    audio_pid,
                    meeting_url: room,
                    title_hint,
                },
            };
            if !found.iter().any(|known| known.same_app(&next)) {
                found.push(next);
            }
        }
        found.sort_by_key(|candidate| candidate.kind.priority());
        found
    }

    /// Advances the start window of `candidate` and answers whether it may
    /// start now (`startConfirmed`).
    fn confirm(&mut self, candidate: &Candidate, now: Instant) -> bool {
        let (needed, gap) = match candidate.kind {
            kind if kind.requires_sustained_mic() => (SUSTAINED_START, SUSTAINED_GAP),
            kind if kind.in_browser() => (BROWSER_START, BROWSER_GAP),
            // A calendar-backed start skips the wait (`requiresSustainedAudioForStart`).
            kind if kind.needs_sustained_evidence() && !self.calendar.active => {
                (SUSTAINED_START, SUSTAINED_GAP)
            }
            _ => return true,
        };
        let room = candidate
            .kind
            .requires_room()
            .then(|| candidate.meeting.meeting_url.clone())
            .flatten();
        let continues = self.pending.as_ref().is_some_and(|pending| {
            pending.kind == candidate.kind
                && pending.family == candidate.family
                && pending.room == room
                && pending.configured_executable == candidate.configured_executable
                && now.duration_since(pending.last_seen) <= gap
        });
        if continues {
            if let Some(pending) = &mut self.pending {
                pending.last_seen = now;
            }
        } else {
            self.pending = Some(Confirmation {
                kind: candidate.kind,
                family: candidate.family,
                room,
                configured_executable: candidate.configured_executable.clone(),
                first_seen: now,
                last_seen: now,
            });
        }
        self.pending
            .as_ref()
            .is_some_and(|pending| now.duration_since(pending.first_seen) >= needed)
    }

    /// Drops a start window whose evidence gap ran past its tolerance.
    fn expire_pending(&mut self, now: Instant) {
        if let Some(pending) = &self.pending {
            let gap = if pending.kind.in_browser() && !pending.kind.requires_sustained_mic() {
                BROWSER_GAP
            } else {
                SUSTAINED_GAP
            };
            if now.duration_since(pending.last_seen) > gap {
                self.pending = None;
            }
        }
    }

    fn step(&mut self, evidence: &Evidence, now: Instant) -> Vec<DetectorEvent> {
        let current = self.active.as_ref().map(|active| active.candidate.clone());
        let candidates = self.candidates(evidence, current.as_ref(), now);
        let mut events = Vec::new();

        // The page says the call is over: no debounce (`browser-ended`).
        if let Some(current) = &current
            && let Some(family) = current.family
            && current.kind != AppKind::MicrophoneBrowser
            && browser::verdict(
                &evidence.documents,
                family,
                current.meeting.meeting_url.as_deref(),
            ) == Verdict::Ended
        {
            self.active = None;
            self.pending = None;
            events.push(DetectorEvent::Ended(current.meeting.clone()));
            return events;
        }

        let Some(current) = current else {
            // Only the best candidate may start; a pending window for another
            // app is replaced, like the single `startConfirmation` on macOS.
            match candidates.into_iter().next() {
                Some(candidate) => {
                    if self.confirm(&candidate, now) {
                        events.push(DetectorEvent::Started(candidate.meeting.clone()));
                        self.active = Some(Active {
                            candidate,
                            stop_at: None,
                        });
                        self.pending = None;
                    }
                }
                None => self.expire_pending(now),
            }
            return events;
        };

        if let Some(same) = candidates.iter().find(|c| c.same_app(&current)) {
            // Still in the call; follow the stream if its process changed.
            if let Some(active) = &mut self.active {
                active.stop_at = None;
                active.candidate.meeting.pid = same.meeting.pid;
                active.candidate.meeting.audio_pid = same.meeting.audio_pid;
                active.candidate.meeting.process_name = same.meeting.process_name.clone();
                if same.meeting.meeting_url.is_some() {
                    active.candidate.meeting.meeting_url = same.meeting.meeting_url.clone();
                }
                if active.candidate.meeting.title_hint.is_none() {
                    active.candidate.meeting.title_hint = same.meeting.title_hint.clone();
                }
            }
            self.pending = None;
            return events;
        }

        match candidates.iter().find(|c| !c.same_app(&current)).cloned() {
            Some(replacement) => {
                if self.confirm(&replacement, now) {
                    // Another app's call took over (`meeting-app-handoff`).
                    events.push(DetectorEvent::Ended(current.meeting));
                    events.push(DetectorEvent::Started(replacement.meeting.clone()));
                    self.active = Some(Active {
                        candidate: replacement,
                        stop_at: None,
                    });
                    self.pending = None;
                    return events;
                }
            }
            None => self.expire_pending(now),
        }

        let debounce = match (
            current.kind.in_browser(),
            current.kind.requires_sustained_mic(),
            self.calendar.grace,
        ) {
            (false, false, Some(grace)) => self.stop_debounce.max(grace),
            _ => self.stop_debounce,
        };
        let ended = self.active.as_mut().is_some_and(|active| {
            let stop_at = *active.stop_at.get_or_insert(now + debounce);
            now >= stop_at
        });
        if ended && let Some(old) = self.active.take() {
            events.push(DetectorEvent::Ended(old.candidate.meeting));
        }
        events
    }
}

/// Watches for calls. `Send`: run it on its own thread and [`poll`] every
/// ~2 s.
///
/// [`poll`]: MeetingDetector::poll
pub struct MeetingDetector {
    source: Box<dyn EvidenceSource>,
    core: Core,
    last_error: Option<String>,
}

impl MeetingDetector {
    pub fn new() -> Self {
        Self::with_source(platform_source())
    }

    pub(crate) fn with_source(source: Box<dyn EvidenceSource>) -> Self {
        Self {
            source,
            core: Core::new(std::process::id()),
            last_error: None,
        }
    }

    /// How long a meeting may lose its evidence before it ends, clamped to
    /// 5–120 s like `stopDebounceSeconds`.
    pub fn set_stop_debounce(&mut self, debounce: Duration) {
        self.core.stop_debounce = debounce.clamp(MIN_STOP_DEBOUNCE, MAX_STOP_DEBOUNCE);
    }

    /// What the calendar says about now (see [`CalendarHint`]).
    pub fn set_calendar(&mut self, hint: CalendarHint) {
        self.core.calendar = hint;
    }

    /// Update opt-in browser detection and additional native call apps.
    pub fn set_call_detection(
        &mut self,
        detect_other_browser_calls: bool,
        apps: &[AdditionalCallApp],
    ) {
        self.core.detect_other_browser_calls = detect_other_browser_calls;
        self.core.additional_call_apps = apps
            .iter()
            .filter_map(|app| Some((app.detector_key()?, app.display_name().to_string())))
            .collect();
    }

    /// Reads the current evidence and returns what changed since the last
    /// poll. A failed read counts as no evidence (and is logged once).
    pub fn poll(&mut self) -> Vec<DetectorEvent> {
        let evidence = match self.source.collect() {
            Ok(evidence) => {
                self.last_error = None;
                evidence
            }
            Err(err) => {
                let message = format!("{err:#}");
                if self.last_error.as_ref() != Some(&message) {
                    log::warn!("meeting detection: {message}");
                    self.last_error = Some(message);
                }
                Evidence::default()
            }
        };
        self.core.step(&evidence, Instant::now())
    }

    /// Feeds a window the user focused (for example each activity sample's
    /// `app_id` and `title`). On Wayland this is the only way the detector
    /// sees Google Meet tab titles.
    pub fn observe_window(&mut self, app_id: &str, title: &str) {
        self.core.observe_window(app_id, title, Instant::now());
    }

    /// The meeting in progress, if any.
    pub fn active(&self) -> Option<&DetectedMeeting> {
        self.core
            .active
            .as_ref()
            .map(|active| &active.candidate.meeting)
    }

    /// Why detection cannot work on this computer, if it cannot.
    pub fn limitation(&self) -> Option<String> {
        self.source.limitation()
    }
}

impl Default for MeetingDetector {
    fn default() -> Self {
        Self::new()
    }
}

fn platform_source() -> Box<dyn EvidenceSource> {
    #[cfg(windows)]
    {
        Box::new(win32::WasapiEvidence::new())
    }
    #[cfg(target_os = "linux")]
    {
        Box::new(linux::PulseEvidence::new())
    }
    #[cfg(not(any(windows, target_os = "linux")))]
    {
        struct Nothing;
        impl EvidenceSource for Nothing {
            fn collect(&mut self) -> anyhow::Result<Evidence> {
                Ok(Evidence::default())
            }
            fn limitation(&self) -> Option<String> {
                Some("Meeting detection is not available on this system.".into())
            }
        }
        Box::new(Nothing)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn stream(pid: u32, name: &str) -> CaptureStream {
        CaptureStream {
            pid,
            process_name: name.into(),
            ..Default::default()
        }
    }

    fn evidence(streams: &[CaptureStream]) -> Evidence {
        Evidence {
            capturing: streams.to_vec(),
            windows: Vec::new(),
            documents: Vec::new(),
        }
    }

    /// Runs `core` every 2 s for `seconds`, feeding `evidence`, and collects events.
    fn run(
        core: &mut Core,
        start: Instant,
        from: u64,
        to: u64,
        evidence: &Evidence,
    ) -> Vec<(u64, DetectorEvent)> {
        let mut events = Vec::new();
        let mut t = from;
        while t <= to {
            for event in core.step(evidence, start + Duration::from_secs(t)) {
                events.push((t, event));
            }
            t += 2;
        }
        events
    }

    #[test]
    fn verified_windows_room_can_start_with_its_microphone_muted() {
        let t0 = Instant::now();
        for (family, url, expected_name) in [
            (
                "chrome",
                "https://telemost.yandex.ru/j/123",
                "Yandex Telemost",
            ),
            ("edge", "https://my.mts-link.ru/j/123/456", "MTS Link"),
            ("mts-link", "https://my.mts-link.ru/j/123/456", "MTS Link"),
        ] {
            let mut core = Core::new(9999);
            let mut evidence = Evidence {
                documents: vec![BrowserDocument {
                    family,
                    url: url.into(),
                    state: browser::CallState::Unavailable,
                    host_pid: Some(1234),
                }],
                ..Evidence::default()
            };
            assert!(
                core.step(&evidence, t0).is_empty(),
                "a preview cannot start"
            );
            evidence.documents[0].state = browser::CallState::InCall;
            assert!(core.step(&evidence, t0 + Duration::from_secs(2)).is_empty());
            let started = core.step(&evidence, t0 + Duration::from_secs(4));
            let [DetectorEvent::Started(started)] = started.as_slice() else {
                panic!("expected one start, got {started:?}");
            };
            assert_eq!(started.app_name, expected_name);
            assert_eq!(started.audio_pid, 1234);
            assert_eq!(started.meeting_url.as_deref(), Some(url));
            {
                evidence.documents[0].state = browser::CallState::Present;
                assert!(
                    core.step(&evidence, t0 + Duration::from_secs(20))
                        .is_empty()
                );
                assert!(
                    core.step(&evidence, t0 + Duration::from_secs(50))
                        .is_empty()
                );
            }
            evidence.documents[0].state = browser::CallState::Ended;
            assert!(matches!(
                core.step(&evidence, t0 + Duration::from_secs(52))
                    .as_slice(),
                [DetectorEvent::Ended(_)]
            ));
        }
    }

    #[test]
    fn a_stale_room_binding_cannot_start_a_calendar_recording() {
        let t0 = Instant::now();
        let mut core = Core::new(9999);
        let url = "https://my.mts-link.ru/j/123/456";
        core.calendar.require_for_browser = true;
        core.calendar.meeting_url = Some(url.into());
        let stale = Evidence {
            documents: vec![BrowserDocument {
                family: "chrome",
                url: url.into(),
                state: browser::CallState::Present,
                host_pid: Some(1234),
            }],
            ..Evidence::default()
        };
        assert!(run(&mut core, t0, 0, 6, &stale).is_empty());
    }

    #[test]
    fn unknown_browser_calls_require_opt_in_a_public_window_and_sustained_microphone() {
        let t0 = Instant::now();
        let mut core = Core::new(9999);
        let mut browser = Evidence {
            capturing: vec![stream(123, "chrome.exe")],
            windows: vec![WindowTitle {
                app: "chrome.exe".into(),
                title: "Corporate video".into(),
            }],
            ..Evidence::default()
        };
        assert!(run(&mut core, t0, 0, 14, &browser).is_empty());
        core.detect_other_browser_calls = true;
        browser.windows.push(WindowTitle {
            app: "chrome.exe".into(),
            title: "New Tab - Incognito".into(),
        });
        assert!(run(&mut core, t0, 16, 30, &browser).is_empty());
        browser.windows.pop();
        browser.documents.push(BrowserDocument {
            family: "chrome",
            url: "https://my.mts-link.ru/j/123/456".into(),
            state: browser::CallState::WaitingRoom,
            host_pid: Some(123),
        });
        assert!(run(&mut core, t0, 32, 46, &browser).is_empty());
        browser.documents.clear();
        assert!(matches!(run(&mut core, t0, 48, 60, &browser).as_slice(),
            [(60, DetectorEvent::Started(meeting))] if meeting.audio_pid == 123 && meeting.meeting_url.is_none()));
        assert!(matches!(
            run(&mut core, t0, 62, 80, &Evidence::default()).as_slice(),
            [(78, DetectorEvent::Ended(_))]
        ));
    }

    #[test]
    fn express_and_a_configured_native_client_bind_their_process_tree() {
        let t0 = Instant::now();
        for (executable, display) in [
            ("eXpress.exe", "eXpress"),
            ("Brand, Client.exe", "Corporate Calls"),
        ] {
            let mut detector = MeetingDetector::new();
            detector.set_call_detection(
                false,
                &[AdditionalCallApp {
                    identifier: "Brand, Client.exe".into(),
                    name: Some("Corporate Calls".into()),
                }],
            );
            let core = &mut detector.core;
            let evidence = Evidence {
                capturing: vec![CaptureStream {
                    pid: 5,
                    process_name: "Call Helper.exe".into(),
                    ancestors: vec![executable.into()],
                    ancestor_pids: vec![7],
                    ..CaptureStream::default()
                }],
                ..Evidence::default()
            };
            assert!(matches!(run(core, t0, 0, 12, &evidence).as_slice(),
                [(12, DetectorEvent::Started(meeting))] if meeting.app_name == display && meeting.audio_pid == 7));
        }
    }

    #[test]
    fn microphone_call_apps_use_the_stop_delay_even_during_a_calendar_event() {
        let t0 = Instant::now();
        for executable in ["eXpress.exe", "CorporateClient.exe"] {
            let mut detector = MeetingDetector::new();
            detector.set_call_detection(
                false,
                &[AdditionalCallApp {
                    identifier: "CorporateClient.exe".into(),
                    name: Some("Corporate Calls".into()),
                }],
            );
            detector.set_calendar(CalendarHint {
                active: true,
                grace: Some(lokalbot_core::calendar::CALENDAR_BACKED_GRACE),
                ..Default::default()
            });
            let core = &mut detector.core;
            let call = evidence(&[stream(123, executable)]);
            assert!(run(core, t0, 0, 10, &call).is_empty(), "{executable}");
            assert!(
                matches!(
                    core.step(&call, t0 + Duration::from_secs(12)).as_slice(),
                    [DetectorEvent::Started(_)]
                ),
                "{executable}"
            );
            assert!(run(core, t0, 14, 28, &Evidence::default()).is_empty());
            assert!(
                matches!(
                    core.step(&Evidence::default(), t0 + Duration::from_secs(29)).as_slice(),
                    [DetectorEvent::Ended(meeting)] if meeting.pid == 123
                ),
                "{executable}"
            );
        }
    }

    #[test]
    fn configured_executables_with_the_same_display_name_confirm_independently() {
        let t0 = Instant::now();
        let mut detector = MeetingDetector::new();
        detector.set_call_detection(
            false,
            &["FirstClient.exe", "SecondClient.exe"].map(|identifier| AdditionalCallApp {
                identifier: identifier.into(),
                name: Some("Corporate Calls".into()),
            }),
        );
        let core = &mut detector.core;
        let first = evidence(&[stream(123, "FIRSTCLIENT.EXE")]);
        let second = evidence(&[stream(456, "secondclient.exe")]);
        assert!(run(core, t0, 0, 10, &first).is_empty());
        assert!(run(core, t0, 12, 22, &second).is_empty());
        assert!(matches!(
            core.step(&second, t0 + Duration::from_secs(24)).as_slice(),
            [DetectorEvent::Started(meeting)] if meeting.pid == 456
        ));
    }

    #[test]
    fn configured_executables_with_the_same_display_name_handoff_as_separate_apps() {
        let t0 = Instant::now();
        let mut detector = MeetingDetector::new();
        detector.set_call_detection(
            false,
            &["FirstClient.exe", "SecondClient.exe"].map(|identifier| AdditionalCallApp {
                identifier: identifier.into(),
                name: Some("Corporate Calls".into()),
            }),
        );
        let core = &mut detector.core;
        let first = evidence(&[stream(123, "FirstClient.exe")]);
        let second = evidence(&[stream(456, "SecondClient.exe")]);
        assert!(matches!(
            run(core, t0, 0, 12, &first).as_slice(),
            [(12, DetectorEvent::Started(meeting))] if meeting.pid == 123
        ));
        let both = evidence(&[
            stream(123, "FirstClient.exe"),
            stream(456, "SecondClient.exe"),
        ]);
        assert_eq!(
            core.candidates(&both, None, t0 + Duration::from_secs(12))
                .len(),
            2
        );
        assert!(run(core, t0, 14, 24, &second).is_empty());
        assert!(matches!(
            core.step(&second, t0 + Duration::from_secs(26)).as_slice(),
            [DetectorEvent::Ended(old), DetectorEvent::Started(next)]
                if old.pid == 123 && next.pid == 456 && old.app_name == next.app_name
        ));
    }

    #[cfg(windows)]
    #[test]
    fn recognizes_vendor_executables_without_classifying_mts_chat_audio_as_a_call() {
        assert_eq!(
            native_kind("YandexTelemost.exe"),
            Some(AppKind::TelemostDesktop)
        );
        assert_eq!(native_kind("TelemostSetup.exe"), None);
        assert_eq!(document_family("МТС Линк.exe"), Some("mts-link"));
        assert_eq!(native_kind("МТС Линк.exe"), None);
    }

    #[test]
    fn other_audio_does_not_authorize_an_mts_link_or_telemost_calendar_event() {
        let t0 = Instant::now();
        for url in [
            "https://my.mts-link.ru/j/123/456",
            "https://telemost.yandex.ru/j/123",
        ] {
            let mut core = Core::new(9999);
            core.calendar.meeting_url = Some(url.into());
            let evidence = Evidence {
                capturing: vec![CaptureStream {
                    pid: 1234,
                    process_name: "chrome.exe".into(),
                    ..CaptureStream::default()
                }],
                ..Evidence::default()
            };
            assert!(core.step(&evidence, t0).is_empty());
            assert!(core.step(&evidence, t0 + Duration::from_secs(3)).is_empty());
        }
    }

    #[test]
    fn another_browser_tab_using_the_microphone_does_not_keep_a_verified_room_recording() {
        let t0 = Instant::now();
        let mut core = Core::new(9999);
        let room = Evidence {
            documents: vec![BrowserDocument {
                family: "chrome",
                url: "https://telemost.yandex.ru/j/123".into(),
                state: browser::CallState::InCall,
                host_pid: Some(1234),
            }],
            ..Evidence::default()
        };
        assert!(matches!(
            run(&mut core, t0, 0, 2, &room).as_slice(),
            [(2, DetectorEvent::Started(_))]
        ));
        let unrelated = Evidence {
            capturing: vec![stream(1234, "chrome")],
            ..Evidence::default()
        };
        assert!(matches!(
            run(&mut core, t0, 4, 22, &unrelated).as_slice(),
            [(20, DetectorEvent::Ended(_))]
        ));
    }

    fn meet_room(state: browser::CallState) -> Evidence {
        Evidence {
            capturing: vec![stream(7, "chrome")],
            windows: vec![WindowTitle {
                app: "chrome".into(),
                title: "Meet - Weekly sync - Google Chrome".into(),
            }],
            documents: vec![BrowserDocument {
                family: "chrome",
                url: "https://meet.google.com/abc-defg-hij".into(),
                state,
                host_pid: None,
            }],
        }
    }

    #[test]
    fn call_controls_start_a_call_and_name_its_room() {
        let start = Instant::now();
        let mut core = Core::new(1);
        let mut in_call = meet_room(browser::CallState::InCall);
        in_call.windows.clear();
        let events = run(&mut core, start, 0, 4, &in_call);
        assert_eq!(events.len(), 1, "{events:?}");
        let DetectorEvent::Started(meeting) = &events[0].1 else {
            panic!("{events:?}");
        };
        assert_eq!(meeting.app_name, "Google Meet");
        assert_eq!(
            meeting.meeting_url.as_deref(),
            Some("https://meet.google.com/abc-defg-hij")
        );
    }

    #[test]
    fn a_readable_waiting_room_never_starts_a_call() {
        let start = Instant::now();
        let mut core = Core::new(1);
        let lobby = meet_room(browser::CallState::Unavailable);
        assert!(run(&mut core, start, 0, 30, &lobby).is_empty());
        // The same title and microphone with no readable tree is today's start.
        let mut unread = meet_room(browser::CallState::Unavailable);
        unread.documents.clear();
        let events = run(&mut core, start, 32, 36, &unread);
        assert!(matches!(events[0].1, DetectorEvent::Started(_)));
    }

    #[test]
    fn a_waiting_room_holds_back_a_calendar_link_to_meet_only() {
        let start = Instant::now();
        let mut core = Core::new(1);
        core.calendar = CalendarHint {
            active: true,
            meeting_url: Some("https://meet.google.com/abc-defg-hij".into()),
            ..Default::default()
        };
        let mut lobby = meet_room(browser::CallState::Unavailable);
        lobby.windows.clear();
        assert!(run(&mut core, start, 0, 10, &lobby).is_empty());
        core.calendar.meeting_url = Some("https://zoom.us/j/123".into());
        let events = run(&mut core, start, 12, 16, &lobby);
        assert!(matches!(events[0].1, DetectorEvent::Started(_)));
    }

    #[test]
    fn a_page_that_says_the_call_is_over_ends_it_at_once() {
        let start = Instant::now();
        let mut core = Core::new(1);
        run(
            &mut core,
            start,
            0,
            4,
            &meet_room(browser::CallState::InCall),
        );
        assert!(core.active.is_some());
        // The browser still holds the microphone and the tab keeps its title.
        let ended = meet_room(browser::CallState::Ended);
        let events = run(&mut core, start, 6, 8, &ended);
        assert_eq!(events.len(), 1, "{events:?}");
        assert_eq!(events[0].0, 6);
        assert!(matches!(events[0].1, DetectorEvent::Ended(_)));
        assert!(core.active.is_none());
    }

    #[test]
    fn an_unreadable_tree_never_ends_a_running_call() {
        let start = Instant::now();
        let mut core = Core::new(1);
        run(
            &mut core,
            start,
            0,
            4,
            &meet_room(browser::CallState::InCall),
        );
        let mut unread = evidence(&[stream(7, "chrome")]);
        unread.documents.clear();
        let lobby_like = meet_room(browser::CallState::Unavailable);
        assert!(run(&mut core, start, 6, 60, &unread).is_empty());
        assert!(run(&mut core, start, 62, 120, &lobby_like).is_empty());
        assert!(core.active.is_some());
    }

    #[test]
    fn the_macs_native_meeting_apps_are_known_on_both_platforms() {
        for (process, name) in [
            ("wemeetapp", "Tencent Meeting"),
            ("wemeetapp.exe", "Tencent Meeting"),
            ("VooVMeeting.exe", "VooV Meeting"),
            ("feishu", "Feishu"),
            ("Feishu.exe", "Feishu"),
            ("lark", "Lark"),
            ("Lark.exe", "Lark"),
            ("DingTalk.exe", "DingTalk"),
            ("com.alibabainc.dingtalk", "DingTalk"),
            ("WXWork.exe", "WeCom"),
        ] {
            assert_eq!(native_kind(process).map(AppKind::name), Some(name));
        }
        // Too broad to call a meeting, as on the Mac: its voice messages and
        // videos sound long enough to pass the wait.
        assert_eq!(native_kind("WeChat.exe"), None);
    }

    /// Dedicated conferencing apps start at once; the ones that also carry
    /// chat and voice messages need the sustained wait (`knownApps`).
    #[test]
    fn only_the_dedicated_conferencing_apps_start_at_once() {
        for process in ["wemeetapp", "voovmeeting"] {
            let mut core = Core::new(1);
            let stream = super::tests::stream(10, process);
            let events = run(&mut core, Instant::now(), 0, 2, &evidence(&[stream]));
            assert_eq!(events.len(), 1, "{process}");
        }
        for process in ["feishu", "lark", "dingtalk", "wxwork"] {
            let start = Instant::now();
            let mut core = Core::new(1);
            let held = evidence(&[stream(10, process)]);
            assert!(run(&mut core, start, 0, 10, &held).is_empty(), "{process}");
            assert_eq!(run(&mut core, start, 12, 14, &held).len(), 1, "{process}");
        }
    }

    #[test]
    fn the_audio_target_is_the_top_process_of_the_app() {
        let start = Instant::now();
        let mut core = Core::new(1);
        let helper = CaptureStream {
            pid: 30,
            process_name: "msedgewebview2.exe".into(),
            ancestors: vec![
                "msedgewebview2.exe".into(),
                "ms-teams.exe".into(),
                "explorer.exe".into(),
            ],
            ancestor_pids: vec![20, 10, 5],
            ..Default::default()
        };
        core.calendar.active = true;
        let events = run(&mut core, start, 0, 2, &evidence(&[helper]));
        let DetectorEvent::Started(meeting) = &events[0].1 else {
            panic!("{events:?}");
        };
        assert_eq!(meeting.app_name, "Teams");
        assert_eq!(meeting.pid, 30);
        assert_eq!(meeting.audio_pid, 10);

        let mut core = Core::new(1);
        let renderer = CaptureStream {
            pid: 3,
            process_name: "chrome.exe".into(),
            ancestors: vec!["chrome.exe".into(), "explorer.exe".into()],
            ancestor_pids: vec![2, 1],
            ..Default::default()
        };
        let mut call = evidence(&[renderer]);
        call.windows.push(WindowTitle {
            app: "chrome.exe".into(),
            title: "Meet - Sync - Google Chrome".into(),
        });
        let events = run(&mut core, start, 0, 4, &call);
        let DetectorEvent::Started(meeting) = &events[0].1 else {
            panic!("{events:?}");
        };
        assert_eq!(meeting.audio_pid, 2);
    }

    #[test]
    fn zoom_starts_at_once_and_ends_after_the_debounce() {
        let start = Instant::now();
        let mut core = Core::new(1);
        let zoom = evidence(&[stream(42, "Zoom.exe")]);
        let events = run(&mut core, start, 0, 10, &zoom);
        assert_eq!(events.len(), 1);
        let (t, DetectorEvent::Started(meeting)) = &events[0] else {
            panic!("{events:?}");
        };
        assert_eq!(*t, 0);
        assert_eq!(meeting.app_name, "Zoom");
        assert_eq!(meeting.pid, 42);
        // Evidence gone at 12 s; the 15 s debounce ends it at the first poll
        // after 27 s.
        let quiet = Evidence::default();
        let events = run(&mut core, start, 12, 40, &quiet);
        assert_eq!(events.len(), 1, "{events:?}");
        assert_eq!(events[0].0, 28);
        assert!(matches!(events[0].1, DetectorEvent::Ended(_)));
    }

    #[test]
    fn a_short_gap_does_not_split_the_meeting() {
        let start = Instant::now();
        let mut core = Core::new(1);
        let webex = evidence(&[stream(7, "CiscoCollabHost.exe")]);
        assert_eq!(run(&mut core, start, 0, 4, &webex).len(), 1);
        assert!(run(&mut core, start, 6, 16, &Evidence::default()).is_empty());
        assert!(run(&mut core, start, 18, 30, &webex).is_empty());
        assert!(core.active.is_some());
    }

    #[test]
    fn teams_needs_twelve_seconds_of_evidence() {
        let start = Instant::now();
        let mut core = Core::new(1);
        let teams = evidence(&[stream(9, "ms-teams.exe")]);
        let events = run(&mut core, start, 0, 20, &teams);
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].0, 12);
        assert!(matches!(&events[0].1, DetectorEvent::Started(m) if m.app_name == "Teams"));
    }

    #[test]
    fn a_ding_is_not_a_meeting() {
        let start = Instant::now();
        let mut core = Core::new(1);
        let slack = evidence(&[stream(5, "slack")]);
        assert!(run(&mut core, start, 0, 6, &slack).is_empty());
        // Silent past the 6 s gap tolerance: the window starts over.
        assert!(run(&mut core, start, 8, 20, &Evidence::default()).is_empty());
        assert!(run(&mut core, start, 22, 32, &slack).is_empty());
        let events = run(&mut core, start, 34, 34, &slack);
        assert_eq!(events.len(), 1, "12 s after 22 s");
    }

    #[test]
    fn gaps_within_tolerance_keep_the_start_window() {
        let start = Instant::now();
        let mut core = Core::new(1);
        let teams = evidence(&[stream(9, "Teams.exe")]);
        let none = Evidence::default();
        assert!(core.step(&teams, start).is_empty());
        assert!(core.step(&none, start + Duration::from_secs(4)).is_empty());
        assert!(core.step(&teams, start + Duration::from_secs(6)).is_empty());
        let events = core.step(&teams, start + Duration::from_secs(12));
        assert_eq!(events.len(), 1);
    }

    #[test]
    fn webview_children_count_as_their_app() {
        let start = Instant::now();
        let mut core = Core::new(1);
        let child = CaptureStream {
            pid: 300,
            process_name: "msedgewebview2.exe".into(),
            ancestors: vec!["msedgewebview2.exe".into(), "ms-teams.exe".into()],
            ..Default::default()
        };
        let events = run(&mut core, start, 0, 12, &evidence(&[child]));
        assert!(
            matches!(&events[..], [(12, DetectorEvent::Started(m))] if m.app_name == "Teams" && m.pid == 300)
        );
    }

    #[test]
    fn browsers_need_a_meet_title_and_two_seconds() {
        let start = Instant::now();
        let mut core = Core::new(1);
        let mut call = evidence(&[stream(77, "chrome.exe")]);
        // Microphone without a Meet tab: some other site.
        assert!(run(&mut core, start, 0, 10, &call).is_empty());
        call.windows.push(WindowTitle {
            app: "chrome.exe".into(),
            title: "Meet – Weekly sync - Google Chrome".into(),
        });
        let events = run(&mut core, start, 12, 14, &call);
        assert_eq!(events.len(), 1, "{events:?}");
        assert_eq!(events[0].0, 14);
        let DetectorEvent::Started(meeting) = &events[0].1 else {
            panic!();
        };
        assert_eq!(meeting.app_name, "Google Meet");
        assert_eq!(meeting.title_hint.as_deref(), Some("Weekly sync"));
        // Switching tabs keeps the call while the browser holds the mic.
        call.windows.clear();
        assert!(run(&mut core, start, 16, 60, &call).is_empty());
    }

    #[test]
    fn a_calendar_link_makes_a_browser_microphone_a_call() {
        let start = Instant::now();
        let mut core = Core::new(1);
        let call = evidence(&[stream(77, "chrome")]);
        assert!(run(&mut core, start, 0, 4, &call).is_empty());
        core.calendar = CalendarHint {
            active: true,
            meeting_url: Some("https://us02web.zoom.us/j/123".into()),
            ..Default::default()
        };
        let events = run(&mut core, start, 6, 8, &call);
        assert!(
            matches!(&events[..], [(8, DetectorEvent::Started(m))] if m.app_name == "Zoom" && m.title_hint.is_none()),
            "{events:?}"
        );
        // The call continues on the microphone after the event ends.
        core.calendar = CalendarHint::default();
        assert!(run(&mut core, start, 10, 60, &call).is_empty());
        assert!(core.active.is_some());
        // A Meet link names Google Meet.
        assert_eq!(
            link_kind("https://meet.google.com/abc-defg-hij"),
            Some(AppKind::Meet)
        );
        assert_eq!(link_kind("https://docs.example.com/x"), None);
    }

    #[test]
    fn strict_mode_needs_a_calendar_link_for_browser_calls() {
        let start = Instant::now();
        let mut core = Core::new(1);
        core.calendar.require_for_browser = true;
        let mut call = evidence(&[stream(77, "chrome")]);
        call.windows.push(WindowTitle {
            app: "chrome".into(),
            title: "Meet – Weekly sync - Google Chrome".into(),
        });
        assert!(run(&mut core, start, 0, 10, &call).is_empty());
        core.calendar.meeting_url = Some("https://meet.google.com/abc-defg-hij".into());
        let events = run(&mut core, start, 12, 14, &call);
        assert!(
            matches!(&events[..], [(14, DetectorEvent::Started(m))] if m.title_hint.as_deref() == Some("Weekly sync")),
            "{events:?}"
        );
    }

    #[test]
    fn calendar_backed_chat_apps_start_at_once() {
        let start = Instant::now();
        let mut core = Core::new(1);
        core.calendar.active = true;
        let events = run(
            &mut core,
            start,
            0,
            0,
            &evidence(&[stream(9, "ms-teams.exe")]),
        );
        assert!(matches!(&events[..], [(0, DetectorEvent::Started(m))] if m.app_name == "Teams"));
    }

    #[test]
    fn a_scheduled_native_meeting_gets_extra_stop_grace() {
        let start = Instant::now();
        let mut core = Core::new(1);
        core.calendar.grace = Some(Duration::from_secs(180));
        let zoom = evidence(&[stream(42, "Zoom.exe")]);
        assert_eq!(run(&mut core, start, 0, 0, &zoom).len(), 1);
        let quiet = Evidence::default();
        assert!(run(&mut core, start, 2, 180, &quiet).is_empty());
        let events = run(&mut core, start, 182, 184, &quiet);
        assert!(
            matches!(&events[..], [(182, DetectorEvent::Ended(_))]),
            "{events:?}"
        );
    }

    #[test]
    fn observed_titles_stand_in_for_window_lists() {
        let start = Instant::now();
        let mut core = Core::new(1);
        core.observe_window(
            "org.mozilla.firefox",
            "Meet - abc-defg-hij — Mozilla Firefox",
            start,
        );
        let call = evidence(&[stream(55, "firefox")]);
        let events = run(&mut core, start, 0, 2, &call);
        assert!(matches!(&events[..], [(2, DetectorEvent::Started(m))] if m.title_hint.is_none()));
    }

    #[test]
    fn our_own_microphone_is_ignored() {
        let start = Instant::now();
        let mut core = Core::new(4242);
        let ours = evidence(&[stream(4242, "zoom")]);
        assert!(run(&mut core, start, 0, 20, &ours).is_empty());
    }

    #[test]
    fn a_new_app_takes_over_after_confirming() {
        let start = Instant::now();
        let mut core = Core::new(1);
        assert_eq!(
            run(&mut core, start, 0, 0, &evidence(&[stream(1000, "zoom")])).len(),
            1
        );
        // Zoom quits and Teams starts: Teams needs 12 s, before Zoom's 15 s
        // debounce, so the meeting hands off.
        let teams = evidence(&[stream(2000, "teams-for-linux")]);
        let events = run(&mut core, start, 2, 14, &teams);
        assert_eq!(events.len(), 2, "{events:?}");
        assert_eq!(events[0].0, 14);
        assert!(matches!(&events[0].1, DetectorEvent::Ended(m) if m.app_name == "Zoom"));
        assert!(matches!(&events[1].1, DetectorEvent::Started(m) if m.app_name == "Teams"));
    }

    #[test]
    fn stop_debounce_is_clamped() {
        let mut detector = MeetingDetector::with_source(Box::new(Fixed(Evidence::default())));
        detector.set_stop_debounce(Duration::from_secs(1));
        assert_eq!(detector.core.stop_debounce, MIN_STOP_DEBOUNCE);
        detector.set_stop_debounce(Duration::from_secs(600));
        assert_eq!(detector.core.stop_debounce, MAX_STOP_DEBOUNCE);
        assert!(detector.poll().is_empty());
        assert!(detector.active().is_none());
    }

    struct Fixed(Evidence);

    impl EvidenceSource for Fixed {
        fn collect(&mut self) -> anyhow::Result<Evidence> {
            Ok(self.0.clone())
        }
    }

    #[test]
    fn meet_titles() {
        assert_eq!(
            meet_title("Meet - abc-defg-hij - Google Chrome"),
            Some(None)
        );
        assert_eq!(
            meet_title("Meet – Design review — Mozilla Firefox"),
            Some(Some("Design review".into()))
        );
        assert_eq!(meet_title("Google Meet"), Some(None));
        assert_eq!(meet_title("Meeting notes - Google Docs"), None);
        assert_eq!(meet_title("Inbox"), None);
    }

    #[test]
    fn detector_is_send() {
        fn assert_send<T: Send>() {}
        assert_send::<MeetingDetector>();
    }
}
