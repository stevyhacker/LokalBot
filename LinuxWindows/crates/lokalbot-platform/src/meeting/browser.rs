use std::collections::HashMap;
use std::time::{Duration, Instant};

use lokalbot_core::calendar::{MeetingService, meeting_room};

pub(crate) const READ_DEADLINE: Duration = Duration::from_secs(1);
pub(crate) const MAX_WINDOWS: usize = 32;
pub(crate) const MAX_NODES: usize = 3_000;
#[cfg(target_os = "linux")]
pub(crate) const MAX_DEPTH: usize = 30;
#[cfg(target_os = "linux")]
pub(crate) const MAX_CHILDREN: usize = 500;
pub(crate) const MAX_LABEL: usize = 160;
const QUIET_MAX_AGE: Duration = Duration::from_secs(30);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum CallState {
    InCall,
    #[cfg(any(windows, test))]
    Present,
    Ended,
    WaitingRoom,
    Unavailable,
}

#[cfg(any(windows, test))]
impl CallState {
    pub fn in_bound_window(self) -> Self {
        match self {
            Self::Unavailable => Self::Present,
            Self::WaitingRoom => Self::Ended,
            state => state,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct BrowserDocument {
    pub family: &'static str,
    pub url: String,
    pub state: CallState,
    pub host_pid: Option<u32>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum Verdict {
    Unknown,
    InCall(Option<String>),
    #[cfg(any(windows, test))]
    Present,
    NotInCall,
    Ended,
}

pub fn meet_url(raw: &str) -> Option<String> {
    meeting_room(raw)
        .filter(|room| room.service == MeetingService::GoogleMeet)
        .map(|room| room.url)
}

pub(crate) fn call_state(buttons: &[String], messages: &[String]) -> CallState {
    const ENDED: [&str; 5] = [
        "you left the meeting",
        "you've left the meeting",
        "you have left the meeting",
        "you were removed from the meeting",
        "the meeting has ended",
    ];
    if messages
        .iter()
        .any(|message| ENDED.contains(&message.to_lowercase().as_str()))
    {
        return CallState::Ended;
    }
    let buttons: Vec<String> = buttons.iter().map(|b| b.trim().to_lowercase()).collect();
    let offers = |action: &str| {
        buttons.iter().any(|button| {
            button == action
                || button.starts_with(&format!("{action} "))
                || button.starts_with(&format!("{action}("))
        })
    };
    let leave = ["leave call", "leave meeting", "hang up"]
        .iter()
        .any(|action| offers(action));
    let microphone = buttons
        .iter()
        .any(|b| b.starts_with("turn off microphone") || b.starts_with("turn on microphone"));
    if leave && microphone {
        return CallState::InCall;
    }
    if !leave && offers("rejoin") && offers("return to home screen") {
        CallState::Ended
    } else {
        CallState::Unavailable
    }
}

fn document_state(
    service: MeetingService,
    buttons: &[String],
    disabled_buttons: &[String],
    messages: &[String],
) -> CallState {
    if service == MeetingService::GoogleMeet {
        return call_state(buttons, messages);
    }
    let controls = buttons
        .iter()
        .map(|label| label.trim().to_lowercase())
        .collect::<Vec<_>>();
    let has = |labels: &[&str]| {
        controls
            .iter()
            .any(|button| labels.contains(&button.as_str()))
    };
    let mic = has(&[
        "включить микрофон",
        "выключить микрофон",
        "turn on microphone",
        "turn off microphone",
        "mute microphone",
        "unmute microphone",
    ]);
    let in_call = match service {
        MeetingService::GoogleMeet => unreachable!(),
        MeetingService::Telemost => {
            mic && has(&[
                "выйти из встречи",
                "завершить звонок",
                "leave meeting",
                "end call",
            ])
        }
        MeetingService::MtsLink => {
            let join = [
                "присоединиться к встрече",
                "join the meeting",
                "join meeting",
            ];
            let preview = has(&join)
                || disabled_buttons
                    .iter()
                    .any(|label| join.contains(&label.trim().to_lowercase().as_str()));
            if preview {
                return CallState::WaitingRoom;
            }
            mic && has(&["покинуть встречу", "leave the meeting", "leave meeting"])
                && has(&["участники", "поднять руку", "participants", "raise hand"])
        }
    };
    if in_call {
        CallState::InCall
    } else {
        CallState::Unavailable
    }
}

#[cfg(any(windows, test))]
pub(crate) fn telemost_room_frame(room: &str, frame: &str) -> bool {
    let Some(code) = room.strip_prefix("https://telemost.yandex.ru/j/") else {
        return false;
    };
    let frame = frame.split(['?', '#']).next().unwrap_or("");
    frame == format!("https://telemost.yandex.ru/private-join/{code}")
}

#[cfg(windows)]
pub(crate) fn title_names_room(title: &str, room: &str, verified: &str) -> bool {
    let title = title.to_lowercase();
    if let Some((_, code)) = room.rsplit_once('/')
        && code.len() >= 10
        && title.contains(code)
    {
        return true;
    }
    let verified = verified.trim().to_lowercase();
    !matches!(
        verified.as_str(),
        "" | "телемост"
            | "яндекс телемост"
            | "yandex telemost"
            | "telemost"
            | "мтс линк"
            | "мтс линк встречи"
            | "mts link"
            | "mts link meetings"
    ) && title.contains(&verified)
}

#[cfg(windows)]
pub(crate) fn is_post_call_page(room: &str, address: &str) -> bool {
    let address = address.split(['?', '#']).next().unwrap_or("");
    match meeting_room(room).map(|room| room.service) {
        Some(MeetingService::Telemost) => matches!(
            address,
            "https://telemost.yandex.ru" | "https://telemost.yandex.ru/"
        ),
        Some(MeetingService::MtsLink) => matches!(
            address,
            "https://mts-link.ru/meetingguest" | "https://mts-link.ru/meetingguest/"
        ),
        _ => false,
    }
}

pub(crate) fn verdict(
    documents: &[BrowserDocument],
    family: &str,
    expected: Option<&str>,
) -> Verdict {
    let own: Vec<&BrowserDocument> = documents
        .iter()
        .filter(|document| document.family == family)
        .collect();
    if let Some(expected) = expected {
        let same: Vec<&&BrowserDocument> = own
            .iter()
            .filter(|document| document.url == expected)
            .collect();
        return match same.as_slice() {
            [document] => match document.state {
                CallState::InCall => Verdict::InCall(Some(document.url.clone())),
                #[cfg(any(windows, test))]
                CallState::Present => Verdict::Present,
                CallState::Ended => Verdict::Ended,
                CallState::WaitingRoom | CallState::Unavailable => Verdict::NotInCall,
            },
            _ => Verdict::Unknown,
        };
    }
    if own.is_empty() {
        return Verdict::Unknown;
    }
    let calls: Vec<&&BrowserDocument> = own
        .iter()
        .filter(|document| document.state == CallState::InCall)
        .collect();
    match calls.as_slice() {
        [call] => Verdict::InCall(Some(call.url.clone())),
        [_, ..] if calls.iter().all(|call| meet_url(&call.url).is_some()) => Verdict::InCall(None),
        [_, ..] => Verdict::NotInCall,
        [] if own
            .iter()
            .all(|document| document.state == CallState::Ended) =>
        {
            Verdict::Ended
        }
        [] => Verdict::NotInCall,
    }
}

#[derive(Debug, Default)]
pub(crate) struct DocumentLabels {
    pub url: Option<String>,
    pub buttons: Vec<String>,
    pub messages: Vec<String>,
    pub disabled_buttons: Vec<String>,
}

impl DocumentLabels {
    pub fn add_button(&mut self, label: Option<String>) {
        self.buttons
            .extend(label.filter(|label| label.chars().count() <= MAX_LABEL));
    }

    #[cfg(any(windows, test))]
    pub fn add_disabled_button(&mut self, label: Option<String>) {
        self.disabled_buttons
            .extend(label.filter(|label| label.chars().count() <= MAX_LABEL));
    }

    pub fn add_message(&mut self, label: Option<String>) {
        self.messages
            .extend(label.filter(|label| label.chars().count() <= MAX_LABEL));
    }

    pub fn into_document(self, family: &'static str) -> Option<BrowserDocument> {
        let url = self.url?;
        let room = meeting_room(&url)?;
        let state = document_state(
            room.service,
            &self.buttons,
            &self.disabled_buttons,
            &self.messages,
        );
        Some(BrowserDocument {
            family,
            url: room.url,
            state,
            host_pid: None,
        })
    }
}

#[cfg(any(windows, test))]
#[derive(Default)]
pub(crate) struct WindowCall {
    pub labels: Option<DocumentLabels>,
    pub document_address: Option<String>,
    pub document_title: Option<String>,
    pub tabs: Vec<String>,
    google: Vec<DocumentLabels>,
    saw_document: bool,
    in_room: bool,
}

#[cfg(any(windows, test))]
#[derive(Clone, Copy, PartialEq, Eq)]
pub(crate) enum CallControl {
    Button,
    Link,
    Text,
}

#[cfg(any(windows, test))]
impl WindowCall {
    pub fn tab(&mut self, title: Option<String>) {
        if !self.saw_document
            && let Some(title) = title.filter(|title| !title.trim().is_empty())
        {
            self.tabs.push(title);
        }
    }

    pub fn document(&mut self, address: Option<String>, title: Option<String>, mts_desktop: bool) {
        let room = address
            .as_deref()
            .and_then(meeting_room)
            .filter(|room| !mts_desktop || room.service == MeetingService::MtsLink);
        let room = match room {
            Some(room) if room.service == MeetingService::GoogleMeet => {
                self.google.push(DocumentLabels {
                    url: Some(room.url),
                    ..Default::default()
                });
                None
            }
            room => room,
        };
        let embedded_mts_room = mts_desktop && self.labels.is_none() && room.is_some();
        if self.saw_document && !embedded_mts_room {
            self.in_room = self
                .labels
                .as_ref()
                .and_then(|labels| labels.url.as_deref())
                .zip(address.as_deref())
                .is_some_and(|(room, frame)| telemost_room_frame(room, frame));
            return;
        }
        self.saw_document = true;
        self.document_title = title;
        self.document_address = address;
        self.labels = room.map(|room| DocumentLabels {
            url: Some(room.url),
            ..Default::default()
        });
        self.in_room = self.labels.is_some();
    }

    pub fn control(
        &mut self,
        kind: CallControl,
        label: Option<String>,
        enabled: bool,
        offscreen: bool,
    ) {
        if let Some(meet) = self.google.last_mut() {
            if kind == CallControl::Text {
                meet.add_message(label.clone());
            } else {
                meet.add_button(label.clone());
            }
        }
        if !self.in_room || offscreen {
            return;
        }
        let Some(labels) = self.labels.as_mut() else {
            return;
        };
        if kind == CallControl::Text {
            labels.add_message(label);
        } else if kind == CallControl::Button && !enabled {
            labels.add_disabled_button(label);
        } else if kind == CallControl::Button {
            labels.add_button(label);
        }
    }

    pub fn google_calls(&mut self, family: &'static str) -> Vec<BrowserDocument> {
        self.google
            .drain(..)
            .filter_map(|labels| labels.into_document(family))
            .collect()
    }
}

#[derive(Debug, Default)]
pub(crate) struct QuietWindows {
    entries: HashMap<String, (String, Instant)>,
}

impl QuietWindows {
    pub fn is_quiet(&self, window: &str, title: &str, now: Instant) -> bool {
        self.entries.get(window).is_some_and(|(known, checked)| {
            known == title && now.saturating_duration_since(*checked) < QUIET_MAX_AGE
        })
    }

    pub fn record(&mut self, window: &str, title: &str, quiet: bool, now: Instant) {
        if quiet {
            self.entries
                .insert(window.to_string(), (title.to_string(), now));
        } else {
            self.entries.remove(window);
        }
    }

    pub fn keep(&mut self, windows: &[String]) {
        self.entries.retain(|window, _| windows.contains(window));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn labels(items: &[&str]) -> Vec<String> {
        items.iter().map(|item| item.to_string()).collect()
    }

    fn document(url: &str, state: CallState) -> BrowserDocument {
        BrowserDocument {
            family: "chrome",
            url: url.into(),
            state,
            host_pid: None,
        }
    }

    #[test]
    fn russian_room_controls_require_a_joined_call() {
        let mic_and_leave = labels(&["Включить микрофон", "Выйти из встречи"]);
        assert_eq!(
            document_state(MeetingService::Telemost, &mic_and_leave, &[], &[]),
            CallState::InCall
        );
        assert_eq!(
            document_state(
                MeetingService::Telemost,
                &labels(&["Включить микрофон"]),
                &[],
                &[]
            ),
            CallState::Unavailable
        );
        let mts_controls = labels(&["Включить микрофон", "Покинуть встречу", "Участники"]);
        let join = labels(&["Присоединиться к встрече"]);
        assert_eq!(
            document_state(MeetingService::MtsLink, &mts_controls, &join, &[]),
            CallState::WaitingRoom
        );
        assert_eq!(
            document_state(
                MeetingService::MtsLink,
                &[mts_controls.clone(), join].concat(),
                &[],
                &[]
            ),
            CallState::WaitingRoom
        );
        assert_eq!(
            document_state(MeetingService::MtsLink, &mts_controls, &[], &[]),
            CallState::InCall
        );
    }

    #[test]
    fn join_prompt_ends_only_the_already_bound_mts_room() {
        let room = "https://my.mts-link.ru/j/123/456";
        let lobby = document(room, CallState::WaitingRoom);
        assert_eq!(
            verdict(std::slice::from_ref(&lobby), "chrome", Some(room)),
            Verdict::NotInCall
        );
        assert_eq!(CallState::Unavailable.in_bound_window(), CallState::Present);
        let ended = BrowserDocument {
            state: lobby.state.in_bound_window(),
            ..lobby
        };
        assert_eq!(verdict(&[ended], "chrome", Some(room)), Verdict::Ended);
    }

    #[test]
    fn meet_keeps_its_toolbar_after_an_unrelated_frame() {
        let mut window = WindowCall::default();
        window.tab(Some("Meet".into()));
        window.control(
            CallControl::Text,
            Some("Browser settings".into()),
            true,
            false,
        );
        window.document(
            Some("https://meet.google.com/abc-defg-hij".into()),
            Some("Meet".into()),
            false,
        );
        window.document(Some("https://example.org/frame".into()), None, false);
        window.control(
            CallControl::Button,
            Some("Turn on microphone".into()),
            false,
            true,
        );
        window.control(CallControl::Link, Some("Leave call".into()), true, false);
        assert_eq!(window.tabs, ["Meet"]);
        let calls = window.google_calls("chrome");
        assert!(matches!(calls.as_slice(), [call] if call.state == CallState::InCall));
    }

    #[cfg(windows)]
    #[test]
    fn only_the_same_telemost_room_has_a_trusted_frame() {
        let room = "https://telemost.yandex.ru/j/123";
        assert!(telemost_room_frame(
            room,
            "https://telemost.yandex.ru/private-join/123?alias=1"
        ));
        assert!(!telemost_room_frame(
            room,
            "https://telemost.yandex.ru/private-join/456"
        ));
        assert!(!telemost_room_frame(
            room,
            "https://example.org/private-join/123"
        ));
        assert!(is_post_call_page(room, "https://telemost.yandex.ru/"));
        assert!(!is_post_call_page(room, "https://telemost.yandex.ru/j/456"));
        assert!(is_post_call_page(
            "https://my.mts-link.ru/j/123/456",
            "https://mts-link.ru/meetingguest/"
        ));
    }

    #[cfg(windows)]
    #[test]
    fn only_a_distinctive_title_or_room_code_keeps_the_verified_tab_present() {
        let room = "https://telemost.yandex.ru/j/12345678901234";
        assert!(title_names_room(
            "Синхронизация команды — Воспроизводится звук",
            room,
            "Синхронизация команды"
        ));
        assert!(title_names_room(
            "12345678901234 | Телемост",
            room,
            "Телемост"
        ));
        assert!(!title_names_room("Яндекс Телемост", room, "Телемост"));
    }

    #[test]
    fn only_an_exact_meet_room_is_a_meeting_document() {
        let room = Some("https://meet.google.com/abc-defg-hij".to_string());
        assert_eq!(meet_url("https://meet.google.com/abc-defg-hij"), room);
        assert_eq!(meet_url("https://meet.google.com/meet/abc-defg-hij"), room);
        assert_eq!(
            meet_url("https://MEET.google.com:443/abc-defg-hij?authuser=0"),
            room
        );
        assert_eq!(meet_url("http://meet.google.com/abc-defg-hij"), None);
        assert_eq!(meet_url("https://meet.google.com/"), None);
        assert_eq!(meet_url("https://meet.google.com/landing"), None);
        assert_eq!(meet_url("https://meet.google.com/ABC-defg-hij"), None);
        assert_eq!(meet_url("https://evil.example/abc-defg-hij"), None);
        assert_eq!(meet_url("https://user@meet.google.com/abc-defg-hij"), None);
        assert_eq!(meet_url("https://meet.google.com:8443/abc-defg-hij"), None);
        assert_eq!(meet_url("short"), None);
    }

    #[test]
    fn call_controls_decide_the_state() {
        let in_call = labels(&["Leave call", "Turn off microphone (ctrl + d)", "Chat"]);
        assert_eq!(call_state(&in_call, &[]), CallState::InCall);
        let joining = labels(&["Join now", "Turn off microphone"]);
        assert_eq!(call_state(&joining, &[]), CallState::Unavailable);
        let leave_only = labels(&["Leave call"]);
        assert_eq!(call_state(&leave_only, &[]), CallState::Unavailable);
        let lookalike = labels(&["Leave callback", "Turn on microphone"]);
        assert_eq!(call_state(&lookalike, &[]), CallState::Unavailable);
    }

    #[test]
    fn the_end_is_read_from_the_page() {
        let message = labels(&["You left the meeting"]);
        assert_eq!(call_state(&[], &message), CallState::Ended);
        let after = labels(&["Rejoin", "Return to home screen"]);
        assert_eq!(call_state(&after, &[]), CallState::Ended);
        let both = labels(&["Rejoin", "Return to home screen", "Leave call"]);
        assert_eq!(call_state(&both, &[]), CallState::Unavailable);
    }

    #[test]
    fn a_new_call_needs_one_document_with_call_controls() {
        let a = "https://meet.google.com/aaa-aaaa-aaa";
        let b = "https://meet.google.com/bbb-bbbb-bbb";
        assert_eq!(verdict(&[], "chrome", None), Verdict::Unknown);
        assert_eq!(
            verdict(&[document(a, CallState::Unavailable)], "chrome", None),
            Verdict::NotInCall
        );
        assert_eq!(
            verdict(
                &[
                    document(a, CallState::Unavailable),
                    document(b, CallState::InCall)
                ],
                "chrome",
                None
            ),
            Verdict::InCall(Some(b.into()))
        );
        assert_eq!(
            verdict(
                &[
                    document(a, CallState::InCall),
                    document(b, CallState::InCall)
                ],
                "chrome",
                None
            ),
            Verdict::InCall(None)
        );
        assert_eq!(
            verdict(&[document(a, CallState::Ended)], "chrome", None),
            Verdict::Ended
        );
        assert_eq!(
            verdict(&[document(a, CallState::InCall)], "firefox", None),
            Verdict::Unknown,
            "another browser's document says nothing"
        );
    }

    #[test]
    fn a_bound_call_only_listens_to_its_own_room() {
        let a = "https://meet.google.com/aaa-aaaa-aaa";
        let b = "https://meet.google.com/bbb-bbbb-bbb";
        let ended_elsewhere = [
            document(b, CallState::Ended),
            document(a, CallState::InCall),
        ];
        assert_eq!(
            verdict(&ended_elsewhere, "chrome", Some(a)),
            Verdict::InCall(Some(a.into()))
        );
        assert_eq!(
            verdict(&[document(a, CallState::Ended)], "chrome", Some(a)),
            Verdict::Ended
        );
        assert_eq!(
            verdict(&[document(b, CallState::Ended)], "chrome", Some(a)),
            Verdict::Unknown
        );
        assert_eq!(
            verdict(&[document(a, CallState::Unavailable)], "chrome", Some(a)),
            Verdict::NotInCall
        );
    }

    #[test]
    fn long_labels_are_page_text_and_a_document_needs_a_room() {
        let mut found = DocumentLabels::default();
        found.add_button(Some("x".repeat(MAX_LABEL + 1)));
        found.add_message(Some("y".repeat(MAX_LABEL + 1)));
        found.add_button(None);
        assert!(found.buttons.is_empty() && found.messages.is_empty());
        assert_eq!(found.into_document("chrome"), None);
    }

    #[test]
    fn a_quiet_window_is_skipped_until_its_title_changes_or_time_passes() {
        let now = Instant::now();
        let mut quiet = QuietWindows::default();
        quiet.record("w", "Docs", true, now);
        assert!(quiet.is_quiet("w", "Docs", now + Duration::from_secs(29)));
        assert!(!quiet.is_quiet("w", "Meet - abc", now));
        assert!(!quiet.is_quiet("w", "Docs", now + QUIET_MAX_AGE));
        quiet.record("w", "Docs", false, now);
        assert!(!quiet.is_quiet("w", "Docs", now));
        quiet.record("w", "Docs", true, now);
        quiet.keep(&[]);
        assert!(!quiet.is_quiet("w", "Docs", now));
    }
}
