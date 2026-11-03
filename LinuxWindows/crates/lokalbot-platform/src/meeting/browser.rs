//! What a browser's accessibility tree says about a call
//! (`BrowserMeetingSession.swift`). Only a supported meeting document and its
//! call controls count, and no pixels, participant names or page text are kept.
//!
//! The tree is optional evidence. Where it can't be read (a Chromium with no
//! screen reader on Linux, a large page, a slow app) detection falls back to
//! the window title and the browser's microphone.

use std::collections::HashMap;
use std::time::{Duration, Instant};

/// All of a poll's windows give up after this long.
pub(crate) const READ_DEADLINE: Duration = Duration::from_secs(1);
pub(crate) const MAX_WINDOWS: usize = 32;
pub(crate) const MAX_NODES: usize = 3_000;
#[cfg(target_os = "linux")]
pub(crate) const MAX_DEPTH: usize = 30;
#[cfg(target_os = "linux")]
pub(crate) const MAX_CHILDREN: usize = 500;
/// Longer labels are page text, not a control's name.
pub(crate) const MAX_LABEL: usize = 160;
/// How long a window without a Meet document isn't walked again, unless a
/// new title says a tab came to the front (`QuietWindowCache.maximumAge`).
const QUIET_MAX_AGE: Duration = Duration::from_secs(30);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum CallState {
    InCall,
    Ended,
    /// A Meet document without call controls: the waiting room, or controls
    /// that couldn't be read.
    Unavailable,
}

/// One Meet document found in a browser window.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct BrowserDocument {
    pub family: &'static str,
    pub url: String,
    pub state: CallState,
}

/// What the documents of one browser say.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum Verdict {
    /// Nothing was read: the title and microphone decide.
    Unknown,
    /// Call controls are on screen, in the one document named when it is known.
    InCall(Option<String>),
    /// A Meet document is open without call controls.
    NotInCall,
    /// The document says the call is over.
    Ended,
}

/// The canonical meeting-room URL, or `None` for anything that is not an exact
/// `https://meet.google.com/abc-defg-hij` document. Meet also serves the room
/// as `/meet/abc-defg-hij`; both give the short form calendar links use.
pub fn meet_url(raw: &str) -> Option<String> {
    let rest = raw
        .get(..8)
        .filter(|scheme| scheme.eq_ignore_ascii_case("https://"))
        .map(|_| &raw[8..])?;
    let end = rest.find(['/', '?', '#']).unwrap_or(rest.len());
    let (authority, tail) = rest.split_at(end);
    let host = authority.strip_suffix(":443").unwrap_or(authority);
    if !host.eq_ignore_ascii_case("meet.google.com") {
        return None;
    }
    let path = tail.split(['?', '#']).next().unwrap_or("");
    let path = path.strip_prefix("/meet").unwrap_or(path);
    let code = path.strip_prefix('/')?;
    let parts: Vec<&str> = code.split('-').collect();
    let is_code = parts.len() == 3
        && [3, 4, 3].iter().zip(&parts).all(|(length, part)| {
            part.len() == *length && part.bytes().all(|b| b.is_ascii_lowercase())
        });
    is_code.then(|| format!("https://meet.google.com/{code}"))
}

/// `BrowserMeetingSession.state`: which call state the labels show.
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
    // Meet's page after a call offers to rejoin it or go home, whatever its
    // heading says. With the call controls gone, that pair is end evidence
    // where the wording is not.
    if !leave && offers("rejoin") && offers("return to home screen") {
        CallState::Ended
    } else {
        CallState::Unavailable
    }
}

/// What `documents` say about `family`'s call. `expected` is the room a call
/// already in progress is bound to: another room's document says nothing about it.
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
                CallState::Ended => Verdict::Ended,
                CallState::Unavailable => Verdict::NotInCall,
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
        // Several calls can't name one room, but a call is on.
        [_, ..] => Verdict::InCall(None),
        [] if own
            .iter()
            .all(|document| document.state == CallState::Ended) =>
        {
            Verdict::Ended
        }
        [] => Verdict::NotInCall,
    }
}

/// The labels of one document while a window is walked.
#[derive(Debug, Default)]
pub(crate) struct DocumentLabels {
    pub url: Option<String>,
    pub buttons: Vec<String>,
    pub messages: Vec<String>,
}

impl DocumentLabels {
    pub fn add_button(&mut self, label: Option<String>) {
        self.buttons
            .extend(label.filter(|label| label.chars().count() <= MAX_LABEL));
    }

    pub fn add_message(&mut self, label: Option<String>) {
        self.messages
            .extend(label.filter(|label| label.chars().count() <= MAX_LABEL));
    }

    pub fn into_document(self, family: &'static str) -> Option<BrowserDocument> {
        let state = call_state(&self.buttons, &self.messages);
        Some(BrowserDocument {
            family,
            url: self.url?,
            state,
        })
    }
}

/// Browser windows whose last complete read found no Meet document, so a
/// window keeping its title isn't walked on every poll (`QuietWindowCache`).
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

    /// Forgets windows that closed.
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
        }
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
        // A word that only starts the same doesn't offer the action.
        let lookalike = labels(&["Leave callback", "Turn on microphone"]);
        assert_eq!(call_state(&lookalike, &[]), CallState::Unavailable);
    }

    #[test]
    fn the_end_is_read_from_the_page() {
        let message = labels(&["You left the meeting"]);
        assert_eq!(call_state(&[], &message), CallState::Ended);
        let after = labels(&["Rejoin", "Return to home screen"]);
        assert_eq!(call_state(&after, &[]), CallState::Ended);
        // Call controls beside a rejoin offer are not the end.
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
