//! Calendar-assisted meetings: the pure policy behind `LokalBot/Services/Calendar/`
//! (`CalendarEventFilter`, `CalendarMeetingCandidate`, `MeetingMatcher`,
//! `ConferenceURLDetector`) and the calendar fields a recording writes to
//! `meta.json` (`RecordingController.swift`). Providers live in
//! `lokalbot-platform`; nothing here reads a calendar or the network.

mod agenda;
mod conference;
mod identity;
mod suggestion;
pub mod upcoming;

#[cfg(test)]
mod tests;

use std::time::Duration;

use chrono::{DateTime, Utc};

use crate::model::{CalendarParticipantIdentity, Meeting};

pub use agenda::{MAX_AGENDA_CHARACTERS, sanitize_agenda};
pub use conference::{CONFERENCE_HOSTS, first_meeting_url, is_meeting_url, url_host};
pub use identity::resolved_meeting_identities;
pub use suggestion::{SpeakerSuggestion, SuggestionSource};

/// Look-around window of the detector: a meeting joined up to 15 min late
/// still matches, and one starting within 90 min is visible early.
pub const LOOK_BEHIND: Duration = Duration::from_secs(15 * 60);
pub const LOOK_AHEAD: Duration = Duration::from_secs(90 * 60);
/// A beat before an event's start during which it already counts as active
/// (people click Join about a minute early), not a long pre-roll.
pub const EARLY_JOIN_GRACE: Duration = Duration::from_secs(60);
/// Detection may not restart a calendar event the user stopped recording
/// for this long (`calendarRepeatCooldown`).
pub const REPEAT_COOLDOWN: Duration = Duration::from_secs(5 * 60);
/// Extra stop grace for a native app while its calendar event is still in
/// its scheduled window (`calendarBackedGrace`).
pub const CALENDAR_BACKED_GRACE: Duration = Duration::from_secs(180);

/// The `calendarProvider` values this port writes.
pub mod provider {
    /// A subscribed iCalendar feed (an `https`/`webcal` link).
    pub const ICS: &str = "ics";
    /// A CalDAV calendar collection.
    pub const CALDAV: &str = "caldav";
    /// Evolution Data Server, which includes GNOME Online Accounts (Linux).
    pub const EDS: &str = "eds";
}

/// The fields meeting filtering needs, independent of any calendar format
/// (`RawCalendarEvent`).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct RawCalendarEvent {
    pub title: Option<String>,
    pub is_all_day: bool,
    pub is_canceled: bool,
    /// The user declined this invitation.
    pub is_declined_by_me: bool,
    /// Shown as free (`TRANSP:TRANSPARENT`); focus and hold blocks use it.
    pub availability_free: bool,
    /// Out of office.
    pub availability_unavailable: bool,
    pub has_attendees: bool,
    pub has_meeting_url: bool,
}

/// A recordable meeting: a real title, and not one of the non-meeting shapes
/// (all-day, cancelled, declined, out of office, or a solo focus block with
/// free time, no attendees and no conferencing link).
pub fn is_recordable_meeting(event: &RawCalendarEvent) -> bool {
    let title = event.title.as_deref().map(str::trim).unwrap_or_default();
    if title.is_empty() {
        return false;
    }
    if event.is_all_day || event.is_canceled || event.is_declined_by_me {
        return false;
    }
    if event.availability_unavailable {
        return false;
    }
    !(event.availability_free && !event.has_attendees && !event.has_meeting_url)
}

/// A calendar event that could line up with a recording, already filtered to
/// a recordable meeting (`CalendarMeetingCandidate`).
#[derive(Clone, Debug, PartialEq)]
pub struct CalendarEvent {
    /// See [`provider`]. Saved as `calendarProvider`.
    pub provider: String,
    /// One occurrence: `<uid>#<start epoch seconds>`, so the repeat cooldown
    /// is keyed on this exact meeting instance.
    pub external_id: String,
    pub title: String,
    pub start: DateTime<Utc>,
    pub end: DateTime<Utc>,
    /// The conferencing link found on the event (Meet, Zoom, Teams, …).
    pub meeting_url: Option<String>,
    pub source_calendar_title: Option<String>,
    pub participant_names: Vec<String>,
    pub participant_identities: Vec<CalendarParticipantIdentity>,
    /// Sanitized invitation agenda, held in memory. A recording keeps it
    /// only when agenda use is on.
    pub agenda: Option<String>,
}

impl CalendarEvent {
    /// `<uid>#<epoch seconds>` (`occurrenceID`): the event id alone is shared
    /// by every occurrence of a recurring series.
    pub fn occurrence_id(uid: &str, start: DateTime<Utc>) -> String {
        format!("{uid}#{}", start.timestamp())
    }

    /// Structured identities when the provider gave them, else the legacy
    /// name-only roster.
    pub fn resolved_participant_identities(&self) -> Vec<CalendarParticipantIdentity> {
        let structured = CalendarParticipantIdentity::normalized(&self.participant_identities);
        if structured.is_empty() {
            CalendarParticipantIdentity::from_legacy_names(&self.participant_names)
        } else {
            structured
        }
    }

    /// In progress, or within `early_join` before its start. The calendar
    /// end never stops a recording (only audio does), so this is start-biased.
    pub fn is_active_with(&self, now: DateTime<Utc>, early_join: Duration) -> bool {
        let grace = chrono::Duration::from_std(early_join).unwrap_or_default();
        now >= self.start - grace && now <= self.end
    }

    pub fn is_active(&self, now: DateTime<Utc>) -> bool {
        self.is_active_with(now, EARLY_JOIN_GRACE)
    }
}

/// The one event that best represents "now": an in-progress event (the most
/// recently started) beats one about to start; with none in progress, the
/// soonest upcoming wins. `None` when nothing is active.
pub fn active_event(events: &[CalendarEvent], now: DateTime<Utc>) -> Option<&CalendarEvent> {
    let active: Vec<&CalendarEvent> = events.iter().filter(|e| e.is_active(now)).collect();
    if let Some(started) = active
        .iter()
        .filter(|e| e.start <= now)
        .max_by_key(|e| e.start)
    {
        return Some(started);
    }
    active.into_iter().min_by_key(|e| e.start)
}

/// Events overlapping the detector's look-around window around `now`.
pub fn detection_window(events: &[CalendarEvent], now: DateTime<Utc>) -> Vec<CalendarEvent> {
    let behind = now - chrono::Duration::from_std(LOOK_BEHIND).unwrap_or_default();
    let ahead = now + chrono::Duration::from_std(LOOK_AHEAD).unwrap_or_default();
    events
        .iter()
        .filter(|e| e.end > behind && e.start < ahead)
        .cloned()
        .collect()
}

// ------------------------------------------------------------------ matcher

/// How sure detection is about a meeting (`MeetingDetectionContext.Confidence`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum Confidence {
    Low,
    Medium,
    High,
}

pub fn confidence(has_app: bool, has_calendar: bool) -> Confidence {
    match (has_app, has_calendar) {
        (true, true) => Confidence::High,
        (true, false) => Confidence::Medium,
        (false, _) => Confidence::Low,
    }
}

/// Calendar, titles and audio are supporting metadata, never proof of a
/// call: the caller must have verified the call itself. In strict mode a
/// browser call also needs an active calendar event with a meeting link.
pub fn browser_counts_as_meeting(
    _title_matches_marker: bool,
    _has_output_audio: bool,
    calendar_backed: bool,
    require_calendar_for_browser: bool,
    verified_session: bool,
) -> bool {
    verified_session && (!require_calendar_for_browser || calendar_backed)
}

/// Suppress an automatic start that would re-record the calendar event the
/// user just stopped. A call that ended on its own never starts the cooldown,
/// and a new occurrence has another id, so it is never blocked.
pub fn should_suppress_repeat(
    event_id: Option<&str>,
    last_event_id: Option<&str>,
    last_ended_at: Option<DateTime<Utc>>,
    now: DateTime<Utc>,
    cooldown: Duration,
) -> bool {
    let (Some(event_id), Some(last_event_id), Some(last_ended_at)) =
        (event_id, last_event_id, last_ended_at)
    else {
        return false;
    };
    if event_id != last_event_id {
        return false;
    }
    let elapsed = (now - last_ended_at).to_std().unwrap_or_default();
    elapsed < cooldown
}

/// A recording backed by one calendar event splits as soon as the active
/// event changes, so back-to-back meetings are not merged during the stop
/// debounce.
pub fn should_split_for_calendar_handoff(
    active_event_id: Option<&str>,
    next_event_id: Option<&str>,
) -> bool {
    match (active_event_id, next_event_id) {
        (Some(active), Some(next)) => active != next,
        _ => false,
    }
}

/// What automatic recording does when the detector moves to another app or
/// calendar event within one call (`MeetingMatcher.SwitchAction`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SwitchAction {
    Split,
    Start,
    Ignore,
}

/// The reason a calendar event change produces.
pub const CALENDAR_HANDOFF: &str = "calendar-handoff";

/// The recording that owns the call splits. With nothing recording (the
/// user stopped the previous event), the next calendar event is a new meeting
/// and records; a recording the call does not own is left alone.
pub fn switch_action(reason: &str, owns_recording: bool, recording_active: bool) -> SwitchAction {
    if owns_recording {
        return SwitchAction::Split;
    }
    if reason == CALENDAR_HANDOFF && !recording_active {
        SwitchAction::Start
    } else {
        SwitchAction::Ignore
    }
}

/// The calendar event's title when titling is on and it has one, else
/// "<App> meeting", else "Manual recording" (`MeetingMatcher.recordingTitle`).
pub fn recording_title(
    calendar_title: Option<&str>,
    use_calendar_titles: bool,
    app_name: Option<&str>,
) -> String {
    if use_calendar_titles
        && let Some(title) = calendar_title.map(str::trim).filter(|t| !t.is_empty())
    {
        return title.to_string();
    }
    match app_name.map(str::trim).filter(|a| !a.is_empty()) {
        Some(app) => meeting_title(app),
        None => "Manual recording".to_string(),
    }
}

/// "<App> meeting", without doubling a trailing "meeting" in the app name.
pub fn meeting_title(app_name: &str) -> String {
    let trimmed = app_name.trim();
    if trimmed.is_empty() {
        return "Meeting".to_string();
    }
    if trimmed.to_lowercase().ends_with("meeting") {
        trimmed.to_string()
    } else {
        format!("{trimmed} meeting")
    }
}

// ----------------------------------------------------------------- metadata

/// Writes the calendar provenance a recording keeps in `meta.json`
/// (`RecordingController.swift`): provider, event id, title, schedule, link,
/// attendee names and identities, and the agenda only when agenda use is on.
pub fn stamp_meeting(meeting: &mut Meeting, event: &CalendarEvent, use_agenda: bool) {
    meeting.calendar_provider = Some(event.provider.clone());
    meeting.calendar_event_id = Some(event.external_id.clone());
    meeting.calendar_title = Some(event.title.clone());
    meeting.scheduled_start_at = Some(seconds(event.start));
    meeting.scheduled_end_at = Some(seconds(event.end));
    meeting.meeting_url = event.meeting_url.clone();
    meeting.participant_name_hints =
        (!event.participant_names.is_empty()).then(|| event.participant_names.clone());
    let participants = event.resolved_participant_identities();
    meeting.calendar_participant_identities = (!participants.is_empty()).then_some(participants);
    if use_agenda {
        meeting.calendar_agenda = sanitize_agenda(event.agenda.as_deref());
    }
}

/// `meta.json` dates are whole seconds.
fn seconds(value: DateTime<Utc>) -> DateTime<Utc> {
    DateTime::from_timestamp(value.timestamp(), 0).unwrap_or(value)
}
