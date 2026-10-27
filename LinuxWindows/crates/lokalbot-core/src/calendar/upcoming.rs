//! Today's meeting schedule (`UpcomingMeetingSelector`,
//! `UpcomingMeetingPresentation`): which events are listed, which one leads,
//! and how their time is described.

use std::sync::LazyLock;

use chrono::{DateTime, NaiveDate, Utc};
use regex::Regex;

use super::CalendarEvent;

/// How Today treats a calendar event.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum UpcomingKind {
    /// Other people or a conferencing link: a call LokalBot can record.
    Meeting,
    /// Only the user is invited, but the title names a meeting (a standup
    /// joined from elsewhere). Listed, without Join or Record.
    SoloMeeting,
    /// Only the user, with a non-meeting title (a doctor's visit, an errand).
    /// Never listed as a meeting.
    Personal,
}

pub fn kind(event: &CalendarEvent) -> UpcomingKind {
    if event.meeting_url.is_some() || !event.resolved_participant_identities().is_empty() {
        return UpcomingKind::Meeting;
    }
    if looks_like_meeting(&event.title) {
        UpcomingKind::SoloMeeting
    } else {
        UpcomingKind::Personal
    }
}

/// Meeting words in English and Serbian. A personal appointment title rarely
/// uses them; a meeting kept on a private calendar usually does.
static MEETING_TITLE: LazyLock<Regex> = LazyLock::new(|| {
    let words = [
        r"meet(?:ing|up)?s?",
        r"calls?",
        r"syncs?",
        r"stand-?ups?",
        r"dailys?",
        r"weekly",
        r"1[:-]1",
        r"1on1",
        r"one[- ]on[- ]one",
        r"interviews?",
        r"demos?",
        r"reviews?",
        r"retros?(?:pective)?",
        r"planning",
        r"kick-?off",
        r"check-?ins?",
        r"catch[- ]?ups?",
        r"huddles?",
        r"all[- ]hands",
        r"office hours",
        r"workshops?",
        r"webinars?",
        r"presentations?",
        r"pitch(?:es)?",
        r"onboarding",
        r"sastan(?:ak|ci)",
        r"poziv",
        r"intervju",
        r"sinhronizacija",
        r"prezentacija",
    ];
    Regex::new(&format!(
        r"(?i)(?:^|[^\p{{L}}\p{{N}}])(?:{})(?:$|[^\p{{L}}\p{{N}}])",
        words.join("|")
    ))
    .expect("valid regex")
});

pub fn looks_like_meeting(title: &str) -> bool {
    MEETING_TITLE.is_match(title)
}

/// Every meeting overlapping the local `day`, including meetings that ended
/// and meetings hours away, by start then end. Personal appointments are left
/// out so they cannot take a meeting's place.
pub fn schedule(events: &[CalendarEvent], day: NaiveDate) -> Vec<CalendarEvent> {
    let (start, end) = crate::time::local_day_bounds(day);
    let mut result: Vec<CalendarEvent> = events
        .iter()
        .filter(|e| e.end > start && e.start < end)
        .filter(|e| kind(e) != UpcomingKind::Personal)
        .cloned()
        .collect();
    result.sort_by(|a, b| a.start.cmp(&b.start).then(a.end.cmp(&b.end)));
    result
}

/// The meeting whose preparation deserves emphasis: an in-progress event
/// first, otherwise the next one at any later time today. The event being
/// recorded is skipped; Today has its own live card for it.
pub fn primary<'a>(
    schedule: &'a [CalendarEvent],
    now: DateTime<Utc>,
    excluding_event_id: Option<&str>,
) -> Option<&'a CalendarEvent> {
    let mut candidates: Vec<&CalendarEvent> = schedule
        .iter()
        .filter(|e| Some(e.external_id.as_str()) != excluding_event_id && e.end >= now)
        .collect();
    candidates.sort_by(|a, b| {
        let a_active = a.start <= now;
        let b_active = b.start <= now;
        b_active.cmp(&a_active).then_with(|| {
            if a_active {
                b.start.cmp(&a.start)
            } else {
                a.start.cmp(&b.start)
            }
        })
    });
    candidates.into_iter().next()
}

/// When an event happens relative to now (`UpcomingMeetingPresentation.statusLabel`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EventStatus {
    Ended,
    InProgress,
    StartingNow,
    InMinutes(i64),
    InHours { hours: i64, minutes: i64 },
}

pub fn status(event: &CalendarEvent, now: DateTime<Utc>) -> EventStatus {
    if event.end < now {
        return EventStatus::Ended;
    }
    if event.start <= now {
        return EventStatus::InProgress;
    }
    let minutes = ((event.start - now).num_seconds() / 60).max(0);
    if minutes < 1 {
        EventStatus::StartingNow
    } else if minutes < 60 {
        EventStatus::InMinutes(minutes)
    } else {
        EventStatus::InHours {
            hours: minutes / 60,
            minutes: minutes % 60,
        }
    }
}

/// Up to four attendee names, then "+N".
pub fn participant_label(event: &CalendarEvent) -> Option<String> {
    if event.participant_names.is_empty() {
        return None;
    }
    let visible = event
        .participant_names
        .iter()
        .take(4)
        .cloned()
        .collect::<Vec<_>>()
        .join(", ");
    let remaining = event.participant_names.len().saturating_sub(4);
    Some(if remaining > 0 {
        format!("{visible} +{remaining}")
    } else {
        visible
    })
}
