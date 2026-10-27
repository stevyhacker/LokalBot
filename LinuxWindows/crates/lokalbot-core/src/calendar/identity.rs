//! `CalendarParticipantIdentity.swift`: one remote attendee of the calendar
//! event matched to a meeting.
//!
//! The email address stays in local meeting metadata only, so the rename
//! sheet can tell same-named attendees apart. Transcripts keep the opaque
//! `id`, never the address.

use std::sync::LazyLock;

use regex::Regex;
use unicode_normalization::UnicodeNormalization as _;
use unicode_normalization::char::is_combining_mark;

use crate::model::CalendarParticipantIdentity;

static WHITESPACE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\s+").expect("valid regex"));
static ROLE_SUFFIX: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)\s*\((host|co-host|organizer|presenter|you|me)\)\s*").expect("valid regex")
});

/// Mailboxes that name a team, a room or a robot rather than a person.
const SHARED_MAILBOXES: &[&str] = &[
    "admin",
    "all",
    "calendar",
    "contact",
    "events",
    "hello",
    "info",
    "mail",
    "noreply",
    "notifications",
    "office",
    "reception",
    "room",
    "sales",
    "support",
    "team",
    "me",
    "you",
    "everyone",
    "presentation",
    "presenting",
    "sharedroom",
];

impl CalendarParticipantIdentity {
    /// A normalized identity, or `None` when neither the name nor the address
    /// is usable. A blank `id` gets a fresh uppercase UUID, as on macOS.
    pub fn new(id: &str, name: Option<&str>, email_address: Option<&str>) -> Option<Self> {
        let name = name.and_then(Self::normalized_display_name);
        let email_address = email_address.and_then(Self::normalized_email_address);
        if name.is_none() && email_address.is_none() {
            return None;
        }
        let id = id.trim();
        Some(Self {
            id: if id.is_empty() {
                uuid::Uuid::new_v4().to_string().to_uppercase()
            } else {
                id.to_string()
            },
            name,
            email_address,
        })
    }

    /// An editable picker suggestion, never an automatic speaker identity.
    /// Calendars often give an address without a display name; metadata
    /// keeps that absence so automatic naming cannot treat a guess as fact.
    pub fn suggested_speaker_name(&self) -> Option<String> {
        if let Some(name) = &self.name {
            return Some(name.clone());
        }
        let address = self.email_address.as_deref()?;
        let local = address.split('@').next()?.split('+').next()?;
        let words: Vec<&str> = local
            .split(['.', '-', '_'])
            .filter(|w| !w.is_empty())
            .collect();
        if !(1..=4).contains(&words.len())
            || !words.iter().all(|w| {
                (1..=24).contains(&w.chars().count()) && w.chars().all(char::is_alphabetic)
            })
        {
            return None;
        }
        let mailbox = words.concat().to_lowercase();
        if SHARED_MAILBOXES.contains(&mailbox.as_str()) {
            return None;
        }
        let capitalized: Vec<String> = words.iter().map(|w| capitalize(w)).collect();
        Self::normalized_display_name(&capitalized.join(" "))
    }

    /// Accepts only `mailto:` participants, so opaque provider identifiers
    /// are never mistaken for addresses.
    pub fn email_from_participant_uri(uri: &str) -> Option<String> {
        let trimmed = uri.trim();
        let (scheme, rest) = trimmed.split_once(':')?;
        if !scheme.eq_ignore_ascii_case("mailto") {
            return None;
        }
        let encoded = rest.split('?').next().unwrap_or_default();
        let address = percent_decode(encoded);
        Self::normalized_email_address(&address)
    }

    pub fn normalized_email_address(raw: &str) -> Option<String> {
        let email = raw.trim().to_lowercase();
        let length = email.chars().count();
        if !(3..=254).contains(&length) || email.contains(char::is_whitespace) {
            return None;
        }
        let parts: Vec<&str> = email.split('@').collect();
        (parts.len() == 2 && !parts[0].is_empty() && !parts[1].is_empty()).then_some(email)
    }

    pub fn normalized_display_name(raw: &str) -> Option<String> {
        let collapsed = WHITESPACE.replace_all(raw, " ");
        let without_roles = ROLE_SUFFIX.replace_all(collapsed.trim(), " ");
        let name = WHITESPACE
            .replace_all(&without_roles, " ")
            .trim()
            .to_string();
        let length = name.chars().count();
        if !(2..=80).contains(&length)
            || !name.chars().any(char::is_alphabetic)
            || name.contains('@')
            || name.to_lowercase().contains("http")
        {
            return None;
        }
        Some(name)
    }

    /// Deduplicates by address first, and by name only when an address is
    /// missing. A same-name, different-address pair stays two people.
    pub fn normalized(
        identities: &[CalendarParticipantIdentity],
    ) -> Vec<CalendarParticipantIdentity> {
        let mut result: Vec<CalendarParticipantIdentity> = Vec::new();
        for input in identities {
            let Some(identity) = Self::new(
                &input.id,
                input.name.as_deref(),
                input.email_address.as_deref(),
            ) else {
                continue;
            };
            if let Some(email) = &identity.email_address
                && let Some(index) = result
                    .iter()
                    .position(|r| r.email_address.as_ref() == Some(email))
            {
                result[index] = merged(&result[index], &identity);
                continue;
            }
            if let Some(name_key) = identity.name.as_deref().map(name_key) {
                let same_name: Vec<usize> = (0..result.len())
                    .filter(|&i| {
                        result[i].name.as_deref().map(self::name_key) == Some(name_key.clone())
                    })
                    .collect();
                if identity.email_address.is_some()
                    && let Some(&index) = same_name
                        .iter()
                        .find(|&&i| result[i].email_address.is_none())
                {
                    result[index] = merged(&result[index], &identity);
                    continue;
                }
                if identity.email_address.is_none() && same_name.len() == 1 {
                    result[same_name[0]] = merged(&result[same_name[0]], &identity);
                    continue;
                }
            }
            result.push(identity);
        }
        result
    }

    /// Name-only rosters from older metadata, with ids stable across loads.
    pub fn from_legacy_names(names: &[String]) -> Vec<CalendarParticipantIdentity> {
        let identities: Vec<CalendarParticipantIdentity> = names
            .iter()
            .filter_map(|raw| {
                let name = Self::normalized_display_name(raw)?;
                Some(Self {
                    id: format!("legacy-name:{}", name_key(&name)),
                    name: Some(name),
                    email_address: None,
                })
            })
            .collect();
        Self::normalized(&identities)
    }
}

/// `Meeting.resolvedCalendarParticipantIdentities`.
pub fn resolved_meeting_identities(
    meeting: &crate::model::Meeting,
) -> Vec<CalendarParticipantIdentity> {
    let structured = CalendarParticipantIdentity::normalized(
        meeting
            .calendar_participant_identities
            .as_deref()
            .unwrap_or_default(),
    );
    if structured.is_empty() {
        CalendarParticipantIdentity::from_legacy_names(
            meeting
                .participant_name_hints
                .as_deref()
                .unwrap_or_default(),
        )
    } else {
        structured
    }
}

fn merged(
    first: &CalendarParticipantIdentity,
    second: &CalendarParticipantIdentity,
) -> CalendarParticipantIdentity {
    CalendarParticipantIdentity {
        id: first.id.clone(),
        name: first.name.clone().or_else(|| second.name.clone()),
        email_address: first
            .email_address
            .clone()
            .or_else(|| second.email_address.clone()),
    }
}

/// Case-, accent- and width-insensitive name key.
pub(crate) fn name_key(name: &str) -> String {
    name.nfkd()
        .filter(|c| !is_combining_mark(*c))
        .collect::<String>()
        .to_lowercase()
}

fn capitalize(word: &str) -> String {
    let mut chars = word.chars();
    match chars.next() {
        Some(first) => first
            .to_uppercase()
            .chain(chars.flat_map(char::to_lowercase))
            .collect(),
        None => String::new(),
    }
}

fn percent_decode(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%'
            && i + 2 < bytes.len()
            && let (Some(high), Some(low)) = (hex(bytes[i + 1]), hex(bytes[i + 2]))
        {
            out.push(high << 4 | low);
            i += 3;
            continue;
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8(out).unwrap_or_else(|_| text.to_string())
}

fn hex(byte: u8) -> Option<u8> {
    (byte as char).to_digit(16).map(|d| d as u8)
}
