//! `CalendarAgenda.sanitize` (`MeetingGenerationContext.swift`): the agenda
//! part of an invitation, without joining instructions, links, phone numbers,
//! addresses or markup. Kept only when the user turns on agenda use.

use std::sync::LazyLock;

use regex::Regex;

pub const MAX_AGENDA_CHARACTERS: usize = 1_200;

static LINE_BREAK_TAGS: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?i)<br\s*/?>|</p>|</li>").expect("valid regex"));
static TAGS: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"<[^>]+>").expect("valid regex"));
static LINKS: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?i)https?://\S+|www\.\S+").expect("valid regex"));
static EMAILS: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}").expect("valid regex")
});
static WHITESPACE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\s+").expect("valid regex"));

const JOINING_MARKERS: &[&str] = &[
    "join zoom",
    "join the meeting",
    "join meeting",
    "join with google meet",
    "join by phone",
    "click here to join",
    "microsoft teams meeting",
    "meeting id",
    "passcode",
    "password:",
    "dial-in",
    "dial in",
    "one tap mobile",
    "find your local number",
    "pin:",
    "phone numbers",
    "google meet",
    "zoom meeting",
    "teams meeting",
    "learn more about",
    "meeting options",
    "join on your computer",
    "for organizers",
    "sip:",
    "h.323",
    "webex",
    "-::~:~::",
    "do not delete or change",
    "invitation from google calendar",
    "reply for",
    "you are receiving this",
    "forwarding this invitation",
    "view all guest info",
];

/// The invitation's agenda, or `None` when nothing meaningful is left.
pub fn sanitize_agenda(notes: Option<&str>) -> Option<String> {
    let text = notes.filter(|n| !n.is_empty())?;
    let text = LINE_BREAK_TAGS.replace_all(text, "\n");
    let text = TAGS.replace_all(&text, " ");
    let text = text.replace("&nbsp;", " ").replace("&amp;", "&");
    let lines: Vec<String> = text
        .split([
            '\n', '\r', '\u{0B}', '\u{0C}', '\u{85}', '\u{2028}', '\u{2029}',
        ])
        .filter_map(|raw| {
            let line = LINKS.replace_all(raw, "");
            let line = EMAILS.replace_all(&line, "");
            let line = line.trim();
            if line.is_empty() || is_joining_boilerplate(line) {
                return None;
            }
            if !line.chars().any(char::is_alphabetic) {
                return None;
            }
            Some(WHITESPACE.replace_all(line, " ").into_owned())
        })
        .collect();
    let joined = lines.join("\n");
    let count = joined.chars().count();
    if count < 12 {
        return None;
    }
    if count > MAX_AGENDA_CHARACTERS {
        let cut: String = joined.chars().take(MAX_AGENDA_CHARACTERS).collect();
        return Some(cut + "…");
    }
    Some(joined)
}

fn is_joining_boilerplate(line: &str) -> bool {
    let lower = line.to_lowercase();
    if JOINING_MARKERS.iter().any(|marker| lower.contains(marker)) {
        return true;
    }
    // Separator rules and bare phone numbers.
    if line
        .chars()
        .all(|c| "-_=~─━.:*#".contains(c) || c.is_whitespace())
    {
        return true;
    }
    let digits = line.chars().filter(char::is_ascii_digit).count();
    let length = line.chars().count().max(1);
    digits >= 7 && digits as f64 / length as f64 > 0.35
}
