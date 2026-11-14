//! What Today decides before it draws (`TodayPanels.swift`, `TodayAgenda.swift`,
//! `TodayDreamSelection`): when the panels form two columns, the bars of So far
//! today, what Needs attention says about itself, today's one list of
//! meetings, the recap line under a recorded meeting, the digest line, the
//! page's layout and the rows of "Before you join". Display-only: nothing here
//! is stored or sent.

use std::collections::HashSet;

use chrono::{DateTime, NaiveDate, Utc};
use lokalbot_ai::upcoming::UpcomingEvidence;
use lokalbot_core::calendar::CalendarEvent;
use lokalbot_core::calendar::upcoming as selector;
use lokalbot_core::{ActionThread, DayDigest, Meeting};
use uuid::Uuid;

/// Rows Needs attention shows on the page.
pub(super) const ATTENTION_LIMIT: usize = 3;
/// Apps So far today names before folding the rest into "Other".
pub(super) const APP_LIMIT: usize = 4;

/// Fills a Mac catalog string's fields (`%lld`, `%@`, `%d`, or numbered
/// `%1$lld`, `%2$@`) with `values`, in order unless numbered. The lookup
/// itself is the caller's `lokalbot_i18n::tr`, so the key stays a literal the
/// catalog checks can see.
pub(crate) fn fill(template: &str, values: &[&str]) -> String {
    let mut out = String::with_capacity(template.len());
    let mut rest = template;
    let mut next = 0;
    while let Some(start) = rest.find('%') {
        out.push_str(&rest[..start]);
        let after = &rest[start + 1..];
        // "%%" is a literal percent sign.
        if let Some(tail) = after.strip_prefix('%') {
            out.push('%');
            rest = tail;
            continue;
        }
        let digits = after.chars().take_while(char::is_ascii_digit).count();
        let (position, spec) = match after[digits..].strip_prefix('$') {
            Some(spec) if digits > 0 => (after[..digits].parse::<usize>().ok(), spec),
            _ => (None, after),
        };
        let length = ["lld", "ld", "@", "d"]
            .iter()
            .find(|candidate| spec.starts_with(**candidate))
            .map(|candidate| candidate.len());
        let Some(length) = length else {
            out.push('%');
            rest = after;
            continue;
        };
        let index = match position {
            Some(position) => position.saturating_sub(1),
            None => {
                next += 1;
                next - 1
            }
        };
        out.push_str(values.get(index).copied().unwrap_or(""));
        let consumed = template.len() - spec.len() + length;
        rest = &template[consumed..];
    }
    out.push_str(rest);
    out
}

/// A phrase GPUI draws as one shaped line, starting with the mark of its own
/// direction when that is right-to-left. Without it a translated phrase that
/// starts with a number ("2 متأخرة", "3ح 57م") loses the number in an Arabic
/// or Urdu interface. The mark is for shaping only, as in
/// `ui::text::paragraph`; left-to-right text is returned as it is.
pub(crate) fn directional(text: impl Into<String>) -> String {
    let text = text.into();
    if lokalbot_i18n::content_is_rtl(&text) && !text.starts_with('\u{200f}') {
        format!("\u{200f}{text}")
    } else {
        text
    }
}

// ---------------------------------------------------------------- columns

/// One column or two (`TodayColumns`). The panels sit side by side when the
/// page is wide enough for a readable leading column beside the fixed
/// trailing one, and stack in reading order otherwise. Widths are logical
/// pixels at the standard text size and grow with larger text.
pub(super) mod columns {
    /// The trailing column (So far today, Yesterday).
    pub const TRAILING_WIDTH: f32 = 336.;
    /// The narrowest leading column (Needs attention, Meetings today) that
    /// still reads well beside the trailing one.
    pub const LEADING_MINIMUM_WIDTH: f32 = 480.;
    /// Between the columns, and between panels in a column.
    pub const GAP: f32 = 16.;
    /// The page's widest, side padding included: two columns, or cards that
    /// span the page (`WorkspaceMetric.todayMaxWidth`).
    pub const WIDE_PAGE: f32 = 1064.;
    /// A page whose panels can only form one column
    /// (`WorkspaceMetric.todayReadingMaxWidth`).
    pub const READING_PAGE: f32 = 780.;

    /// How much wider than at the standard text size the columns are.
    pub fn factor(text_scale: f32) -> f32 {
        text_scale.max(0.5)
    }

    pub fn trailing_width(text_scale: f32) -> f32 {
        (TRAILING_WIDTH * factor(text_scale)).round()
    }

    /// The narrowest page content, inside its side padding, that shows two
    /// columns.
    pub fn two_column_minimum_width(text_scale: f32) -> f32 {
        (LEADING_MINIMUM_WIDTH * factor(text_scale)).round() + GAP + trailing_width(text_scale)
    }

    /// `width` is the page content inside its side padding. A side with no
    /// panels leaves no gutter: the page is one column.
    pub fn count(width: f32, text_scale: f32, has_leading: bool, has_trailing: bool) -> usize {
        if has_leading && has_trailing && width >= two_column_minimum_width(text_scale) {
            2
        } else {
            1
        }
    }

    /// Two columns and the cards that span them use the full width; panels
    /// that can only ever form one column keep the narrower reading width.
    pub fn page_maximum_width(has_leading: bool, has_trailing: bool) -> f32 {
        if has_leading != has_trailing {
            READING_PAGE
        } else {
            WIDE_PAGE
        }
    }
}

// ------------------------------------------------------------- app bars

/// One app's row in So far today (`TodayAppBars.Bar`).
#[derive(Clone, Debug, PartialEq)]
pub(super) struct AppBar {
    /// The app as captured; empty for the folded tail, which reads "Other".
    pub label: String,
    pub seconds: f64,
    /// 0…1, where the longest row is 1.
    pub fraction: f64,
    pub is_other: bool,
}

/// The busiest apps with at least a minute each, up to `cap`, then the rest
/// as one "Other" row (`AppTimePresentation.rows`), each as a share of the
/// longest row.
pub(super) fn app_bars(per_app: &[(String, f64)], cap: usize) -> Vec<AppBar> {
    let mut sorted: Vec<&(String, f64)> = per_app.iter().filter(|(_, s)| *s > 0.).collect();
    sorted.sort_by(|a, b| b.1.total_cmp(&a.1));
    let mut rows: Vec<AppBar> = Vec::new();
    let mut other = 0.;
    let mut folded = 0;
    for (label, seconds) in sorted {
        if *seconds >= 60. && rows.len() < cap {
            rows.push(AppBar {
                label: label.clone(),
                seconds: *seconds,
                fraction: 0.,
                is_other: false,
            });
        } else {
            other += seconds;
            folded += 1;
        }
    }
    if folded > 0 {
        rows.push(AppBar {
            label: String::new(),
            seconds: other,
            fraction: 0.,
            is_other: true,
        });
    }
    let longest = rows.iter().map(|r| r.seconds).fold(0., f64::max);
    for row in &mut rows {
        row.fraction = if longest > 0. {
            (row.seconds / longest).clamp(0., 1.)
        } else {
            0.
        };
    }
    rows
}

// -------------------------------------------------------- needs attention

/// What Needs attention says about itself (`TodayAttentionSummary`): how
/// many actions are open, how many of those are overdue, and how many it
/// leaves to Actions.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(super) struct AttentionSummary {
    pub open: usize,
    pub overdue: usize,
    /// Rows on the page.
    pub shown: usize,
    /// Open actions the panel leaves to the Actions page.
    pub remainder: usize,
}

impl AttentionSummary {
    pub fn new(threads: &[ActionThread], limit: usize, today: NaiveDate) -> Self {
        let open = threads.len();
        let shown = open.min(limit);
        Self {
            open,
            overdue: threads.iter().filter(|t| t.is_overdue(today)).count(),
            shown,
            remainder: open - shown,
        }
    }

    /// The footer appears only when Actions holds more than the rows shown.
    pub fn shows_footer(&self) -> bool {
        self.remainder > 0
    }
}

// ----------------------------------------------------------------- agenda

/// Within this a calendar meeting earns the card at the top of Today, and
/// its status reads in the accent (`TodayAgenda.nextMeetingWindow`).
pub(super) const NEXT_MEETING_WINDOW_SECONDS: i64 = 60 * 60;

/// Where a meeting stands in the day.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum EntryStatus {
    Recording,
    Recorded,
    Ended,
    InProgress,
    StartingNow,
    Upcoming { minutes: i64 },
}

/// One line of Meetings today: a recording made today or a calendar event
/// nothing was recorded for (`TodayAgenda.Entry`).
#[derive(Clone, Debug, PartialEq)]
pub(super) struct Entry {
    pub id: String,
    /// The recording, when this is one.
    pub meeting: Option<Meeting>,
    pub title: String,
    pub start: DateTime<Utc>,
    pub status: EntryStatus,
    /// Starts within the hour, so its status reads in the accent.
    pub is_soon: bool,
}

#[derive(Clone, Debug, PartialEq)]
pub(super) enum AgendaRow {
    Entry(Box<Entry>),
    /// The line between what has started and what is still ahead.
    Now(DateTime<Utc>),
}

/// Where a calendar event stands at `now`.
pub(super) fn event_status(event: &CalendarEvent, now: DateTime<Utc>) -> EntryStatus {
    match selector::status(event, now) {
        selector::EventStatus::Ended => EntryStatus::Ended,
        selector::EventStatus::InProgress => EntryStatus::InProgress,
        selector::EventStatus::StartingNow => EntryStatus::StartingNow,
        selector::EventStatus::InMinutes(minutes) => EntryStatus::Upcoming { minutes },
        selector::EventStatus::InHours { hours, minutes } => EntryStatus::Upcoming {
            minutes: hours * 60 + minutes,
        },
    }
}

/// The calendar events in `events` some recording is linked to. They are
/// listed once, as that recording, and never offered again as the next
/// meeting. Any recording claims its event, a merged source included.
pub(super) fn recorded_event_ids(
    recordings: &[&Meeting],
    events: &[CalendarEvent],
) -> HashSet<String> {
    let wanted: HashSet<&str> = events.iter().map(|e| e.external_id.as_str()).collect();
    recordings
        .iter()
        .filter_map(|m| m.calendar_event_id.as_deref())
        .filter(|id| wanted.contains(id))
        .map(str::to_string)
        .collect()
}

/// Today's recordings and calendar events as one list, earliest first. A
/// recording that stores its calendar event stands in for that event.
pub(super) fn agenda_entries(
    recordings: &[&Meeting],
    events: &[CalendarEvent],
    live_meeting: Option<Uuid>,
    now: DateTime<Utc>,
) -> Vec<Entry> {
    let today = lokalbot_core::time::local_day(now);
    let mut seen = HashSet::new();
    let recorded = recorded_event_ids(recordings, events);
    let mut entries: Vec<Entry> = recordings
        .iter()
        .filter(|m| {
            m.is_own_work()
                && lokalbot_core::time::local_day(m.started_at) == today
                && seen.insert(m.id)
        })
        .map(|m| Entry {
            id: format!("recording-{}", m.id),
            meeting: Some((*m).clone()),
            title: m.display_title(),
            start: m.started_at,
            status: if Some(m.id) == live_meeting {
                EntryStatus::Recording
            } else {
                EntryStatus::Recorded
            },
            is_soon: false,
        })
        .collect();
    let mut seen_events = HashSet::new();
    entries.extend(
        events
            .iter()
            .filter(|e| {
                !recorded.contains(&e.external_id) && seen_events.insert(e.external_id.clone())
            })
            .map(|e| {
                let ahead = (e.start - now).num_seconds();
                Entry {
                    id: format!("event-{}", e.external_id),
                    meeting: None,
                    title: e.title.clone(),
                    start: e.start,
                    status: event_status(e, now),
                    is_soon: ahead > 0 && ahead <= NEXT_MEETING_WINDOW_SECONDS,
                }
            }),
    );
    entries.sort_by(|a, b| {
        a.start
            .cmp(&b.start)
            // At the same minute the recording is the thing that happened.
            .then_with(|| b.meeting.is_some().cmp(&a.meeting.is_some()))
            .then_with(|| a.id.cmp(&b.id))
    });
    entries
}

/// The list with the now line before the first entry still ahead. A day with
/// nothing ahead has no line.
pub(super) fn agenda_rows(entries: Vec<Entry>, now: DateTime<Utc>) -> Vec<AgendaRow> {
    let next = entries.iter().position(|e| e.start > now);
    let mut rows: Vec<AgendaRow> = entries
        .into_iter()
        .map(|entry| AgendaRow::Entry(Box::new(entry)))
        .collect();
    if let Some(next) = next {
        rows.insert(next, AgendaRow::Now(now));
    }
    rows
}

/// A hairline divides two meetings. The now line draws its own rule, so the
/// meeting before it has none, and the last row ends at the panel.
pub(super) fn has_hairline_after(index: usize, rows: &[AgendaRow]) -> bool {
    matches!(rows.get(index + 1), Some(AgendaRow::Entry(_)))
}

/// The meeting for the card at the top of Today: the one under way, or the
/// next one once it is within the hour. Events already recorded, and the one
/// being recorded now, are passed over (`TodayAgenda.nextMeeting`).
pub(super) fn next_meeting<'a>(
    schedule: &'a [CalendarEvent],
    now: DateTime<Utc>,
    recorded: &HashSet<String>,
) -> Option<&'a CalendarEvent> {
    let candidates: Vec<CalendarEvent> = schedule
        .iter()
        .filter(|e| !recorded.contains(&e.external_id))
        .cloned()
        .collect();
    let next = selector::primary(&candidates, now, None)?;
    if next.end <= now || (next.start - now).num_seconds() > NEXT_MEETING_WINDOW_SECONDS {
        return None;
    }
    schedule.iter().find(|e| e.external_id == next.external_id)
}

// ------------------------------------------------------------ recap line

/// The longest recap line, in characters, before it is cut at a word.
pub(super) const RECAP_MAXIMUM_CHARACTERS: usize = 220;
const OVERVIEW_SECTIONS: [&str; 4] = ["tldr", "summary", "overview", "recap"];

/// One line saying what a recorded meeting was about: the first sentence-like
/// line under its summary's TL;DR (or Summary, Overview, Recap) heading
/// (`TodayMeetingRecap.line`). `None` when the summary has no such section.
/// No model runs for this.
pub(super) fn recap_line(markdown: &str) -> Option<String> {
    let mut in_overview = false;
    for raw in markdown.lines() {
        let line = raw.trim_matches([' ', '\t']);
        if let Some(title) = heading_text(line) {
            let letters: String = title
                .to_lowercase()
                .chars()
                .filter(|c| c.is_alphabetic())
                .collect();
            in_overview = OVERVIEW_SECTIONS.contains(&letters.as_str());
            continue;
        }
        if !in_overview || line.is_empty() {
            continue;
        }
        let line = strip_list_marker(line);
        // Checkbox bullets are actions, not a recap.
        if line.starts_with('[') {
            continue;
        }
        let line = strip_speaker(line);
        let line = remove_stamps(line);
        let line = strip_trailing_dash(&line);
        let line = line.replace("**", "").replace("__", "");
        let line = line.split_whitespace().collect::<Vec<_>>().join(" ");
        let letters: String = line
            .to_lowercase()
            .chars()
            .filter(|c| c.is_alphabetic())
            .collect();
        if line.chars().count() < 8 || letters == "none" {
            continue;
        }
        return Some(shortened(&line));
    }
    None
}

/// The words of a Markdown heading (`#` to `######` and a space).
fn heading_text(line: &str) -> Option<&str> {
    let hashes = line.chars().take_while(|c| *c == '#').count();
    if !(1..=6).contains(&hashes) {
        return None;
    }
    let rest = &line[hashes..];
    rest.starts_with(char::is_whitespace)
        .then(|| rest.trim_start())
}

/// "- ", "* ", "• ", "1. " or "1) ".
fn strip_list_marker(line: &str) -> &str {
    let mut chars = line.char_indices();
    let marker_end = match chars.next() {
        Some((_, '-' | '*' | '•')) => line.chars().next().map(char::len_utf8),
        Some((_, c)) if c.is_ascii_digit() => {
            let digits = line.chars().take_while(char::is_ascii_digit).count();
            matches!(line[digits..].chars().next(), Some('.' | ')')).then_some(digits + 1)
        }
        _ => None,
    };
    match marker_end {
        Some(end) if line[end..].starts_with(char::is_whitespace) => line[end..].trim_start(),
        _ => line,
    }
}

/// A leading "**Speaker:**" label.
fn strip_speaker(line: &str) -> &str {
    let Some(rest) = line.strip_prefix("**") else {
        return line;
    };
    let Some(star) = rest.find('*') else {
        return line;
    };
    let name = &rest[..star];
    let Some(name) = name.strip_suffix(':') else {
        return line;
    };
    let length = name.chars().count();
    if !(1..=48).contains(&length) || !rest[star..].starts_with("**") {
        return line;
    }
    rest[star + 2..].trim_start()
}

/// A time stamp's length at the start of `text`: `[1:23]`, `[01:02:03]`.
fn stamp_length(text: &str) -> Option<usize> {
    let bytes = text.as_bytes();
    if bytes.first() != Some(&b'[') {
        return None;
    }
    let mut index = 1;
    let digits = bytes[index..]
        .iter()
        .take_while(|b| b.is_ascii_digit())
        .count();
    if !(1..=2).contains(&digits) {
        return None;
    }
    index += digits;
    let mut groups = 0;
    while groups < 2
        && bytes.get(index) == Some(&b':')
        && bytes.get(index + 1).is_some_and(u8::is_ascii_digit)
        && bytes.get(index + 2).is_some_and(u8::is_ascii_digit)
    {
        index += 3;
        groups += 1;
    }
    (groups > 0 && bytes.get(index) == Some(&b']')).then_some(index + 1)
}

/// A cited time or range at the start of `text`, with its optional
/// parentheses: "[00:12]", "([1:02] – [1:30])".
fn citation_length(text: &str) -> Option<usize> {
    let mut index = usize::from(text.starts_with('('));
    index += stamp_length(&text[index..])?;
    let after = &text[index..];
    let spaced = after.trim_start();
    if let Some(dash) = spaced
        .chars()
        .next()
        .filter(|c| matches!(c, '–' | '—' | '-'))
    {
        let rest = spaced[dash.len_utf8()..].trim_start();
        if let Some(second) = stamp_length(rest) {
            index = text.len() - rest.len() + second;
        }
    }
    if text[index..].starts_with(')') {
        index += 1;
    }
    Some(index)
}

/// Removes every cited time, with the space before it.
fn remove_stamps(line: &str) -> String {
    let mut out = String::with_capacity(line.len());
    let mut index = 0;
    while index < line.len() {
        let rest = &line[index..];
        if (rest.starts_with('[') || rest.starts_with('('))
            && let Some(length) = citation_length(rest)
        {
            let kept = out.trim_end().len();
            out.truncate(kept);
            index += length;
            continue;
        }
        let c = rest.chars().next().unwrap_or(' ');
        out.push(c);
        index += c.len_utf8();
    }
    out
}

/// A dash left at the end once its citation is gone.
fn strip_trailing_dash(line: &str) -> String {
    let trimmed = line.trim_end();
    match trimmed.chars().last() {
        Some(c @ ('—' | '–' | '-')) => trimmed[..trimmed.len() - c.len_utf8()]
            .trim_end()
            .to_string(),
        _ => line.to_string(),
    }
}

fn shortened(text: &str) -> String {
    if text.chars().count() <= RECAP_MAXIMUM_CHARACTERS {
        return text.to_string();
    }
    let cut: String = text.chars().take(RECAP_MAXIMUM_CHARACTERS).collect();
    let end = cut.rfind(' ').unwrap_or(cut.len());
    let kept = cut[..end].trim_matches(|c: char| {
        c.is_whitespace() || c.is_ascii_punctuation() || "…—–“”‘’«»·".contains(c)
    });
    format!("{kept}…")
}

// ---------------------------------------------------------- so far today

/// The few lines of the day digest that Today shows: its "At a glance", or
/// the titles of its first tasks when it has none (`TodayDigestHighlights`).
pub(super) fn highlights_markdown(digest: Option<&DayDigest>) -> String {
    const TASK_FALLBACK_LIMIT: usize = 3;
    let Some(digest) = digest.filter(|d| !d.markdown.is_empty()) else {
        return String::new();
    };
    let glance = digest.at_a_glance_markdown.trim();
    if !glance.is_empty() {
        return glance.to_string();
    }
    digest
        .tasks
        .iter()
        .filter(|t| t.has_heading && !t.title.trim().is_empty())
        .take(TASK_FALLBACK_LIMIT)
        .map(|t| format!("- {}", t.title.trim()))
        .collect::<Vec<_>>()
        .join("\n")
}

/// The one line under So far today that says where the digest stands
/// (`TodayDigestLine`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum DigestLine {
    /// A digest is being written, by hand or on schedule.
    Writing,
    /// No digest for today yet.
    Missing,
    Current(Option<DateTime<Utc>>),
    /// Activity arrived after the digest was written; Update rewrites it.
    Stale(Option<DateTime<Utc>>),
}

impl DigestLine {
    pub fn new(
        has_digest: bool,
        written_at: Option<DateTime<Utc>>,
        stale: bool,
        writing: bool,
    ) -> Self {
        if writing {
            DigestLine::Writing
        } else if !has_digest {
            DigestLine::Missing
        } else if stale {
            DigestLine::Stale(written_at)
        } else {
            DigestLine::Current(written_at)
        }
    }

    /// A current digest with no known time has nothing to say.
    pub fn shows_footer(self) -> bool {
        self != DigestLine::Current(None)
    }
}

// ------------------------------------------------------------------ page

/// What the page is made of (`TodayPageLayout`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum PageLayout {
    /// The day's panels. Get started stays under them until hidden.
    Sections { getting_started_below: bool },
    /// Nothing to show yet: the Get started steps are the page.
    GettingStarted,
    /// Nothing to show and Get started is hidden.
    Placeholder,
}

impl PageLayout {
    pub fn new(has_content: bool, getting_started_dismissed: bool) -> Self {
        if has_content {
            PageLayout::Sections {
                getting_started_below: !getting_started_dismissed,
            }
        } else if getting_started_dismissed {
            PageLayout::Placeholder
        } else {
            PageLayout::GettingStarted
        }
    }

    pub fn shows_sections(self) -> bool {
        matches!(self, PageLayout::Sections { .. })
    }
}

// ------------------------------------------------------- before you join

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum PreparationKind {
    Decision,
    Commitment,
    Project,
    RecentMeeting,
}

/// One thing to know before joining (`TodayPreparation.Row`).
#[derive(Clone, Debug, PartialEq)]
pub(super) struct PreparationRow {
    pub id: String,
    pub kind: PreparationKind,
    pub text: String,
    /// Where it comes from: a meeting title or an owner. An owner who is the
    /// user is `None` here and reads "You".
    pub source: Option<String>,
    pub source_is_user: bool,
    pub date: Option<NaiveDate>,
    /// The meeting it opens.
    pub target: Option<Uuid>,
}

fn reference_row(reference: &lokalbot_ai::upcoming::UpcomingReference) -> PreparationRow {
    use lokalbot_ai::upcoming::ReferenceKind;
    let owner = reference.owner.as_deref().map(str::trim).unwrap_or("");
    let commitment = reference.kind == ReferenceKind::Commitment;
    let by_owner = commitment && !owner.is_empty();
    PreparationRow {
        id: format!("{:?}-{}", reference.kind, reference.id),
        kind: if commitment {
            PreparationKind::Commitment
        } else {
            PreparationKind::Decision
        },
        text: reference.text.clone(),
        source: if by_owner && reference.is_for_user {
            None
        } else if by_owner {
            Some(owner.to_string())
        } else {
            Some(reference.meeting_title.clone())
        },
        source_is_user: by_owner && reference.is_for_user,
        date: Some(lokalbot_core::time::local_day(reference.meeting_date)),
        target: Some(reference.meeting_id),
    }
}

fn project_row(project: &lokalbot_ai::upcoming::UpcomingProject) -> PreparationRow {
    PreparationRow {
        id: format!("project-{}", project.name),
        kind: PreparationKind::Project,
        text: format!("{} — {}", project.name, project.status),
        source: None,
        source_is_user: false,
        date: lokalbot_core::dream::day_from_key(&project.last_active_day),
        target: None,
    }
}

/// One row of each kind the evidence holds. A meeting with no decisions,
/// commitments or projects falls back to the closest earlier meeting
/// (`TodayPreparation.primaryRows`).
pub(super) fn preparation_rows(evidence: &UpcomingEvidence) -> Vec<PreparationRow> {
    let mut rows = Vec::new();
    rows.extend(evidence.decisions.first().map(reference_row));
    rows.extend(evidence.commitments.first().map(reference_row));
    rows.extend(evidence.projects.first().map(project_row));
    if evidence.decisions.is_empty()
        && evidence.commitments.is_empty()
        && evidence.projects.is_empty()
        && let Some(related) = evidence.related_meetings.first()
    {
        rows.push(PreparationRow {
            id: format!("related-{}", related.meeting_id),
            kind: PreparationKind::RecentMeeting,
            text: related.title.clone(),
            source: None,
            source_is_user: false,
            date: Some(lokalbot_core::time::local_day(related.started_at)),
            target: Some(related.meeting_id),
        });
    }
    rows
}

/// Everything past the first of each kind (`TodayPreparation.moreRows`).
pub(super) fn more_preparation_rows(evidence: &UpcomingEvidence) -> Vec<PreparationRow> {
    evidence
        .decisions
        .iter()
        .skip(1)
        .map(reference_row)
        .chain(evidence.commitments.iter().skip(1).map(reference_row))
        .chain(evidence.projects.iter().skip(1).map(project_row))
        .collect()
}

/// A brief the model wrote is always shown. The template brief only restates
/// the rows, so it is shown when there are no rows to read.
pub(super) fn shows_brief(generated_by_model: bool, row_count: usize) -> bool {
    generated_by_model || row_count == 0
}

// -------------------------------------------------------------- yesterday

/// Whose priorities a brief holds (`TodayDreamSelection.PrioritiesSource`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) enum PrioritiesSource {
    /// The brief covers yesterday.
    Today,
    /// An older brief's day: its weekday within the last week, its date
    /// beyond that.
    Day(NaiveDate, DayNaming),
    /// The covered day is unreadable.
    PreviousWorkday,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum DayNaming {
    Weekday,
    Date,
}

/// A brief covering yesterday is the current one; anything older is labelled
/// with its own day (`TodayDreamSelection.isCurrent`).
pub(super) fn brief_is_current(report_day: &str, today: NaiveDate) -> bool {
    today
        .pred_opt()
        .is_some_and(|yesterday| report_day == lokalbot_core::dream::day_key(yesterday))
}

/// A brief from yesterday earns "Priorities for today"; anything older is
/// framed with its own day, so a Friday brief on Monday never reads as
/// current (`TodayDreamSelection.prioritiesSource`).
pub(super) fn priorities_source(report_day: &str, today: NaiveDate) -> PrioritiesSource {
    if brief_is_current(report_day, today) {
        return PrioritiesSource::Today;
    }
    let Some(day) = lokalbot_core::dream::day_from_key(report_day) else {
        return PrioritiesSource::PreviousWorkday;
    };
    let days_ago = (today - day).num_days();
    if days_ago <= 6 {
        PrioritiesSource::Day(day, DayNaming::Weekday)
    } else {
        PrioritiesSource::Day(day, DayNaming::Date)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use lokalbot_ai::upcoming::{
        ReferenceKind, RelatedMeeting, UpcomingProject, UpcomingReference,
    };
    use lokalbot_core::ActionStatus;

    use crate::test_support::{reference, thread};

    fn at(hour: u32, minute: u32) -> DateTime<Utc> {
        // Noon-ish local times on one day, whatever the test machine's zone:
        // built from the local day so `local_day` agrees.
        let day = NaiveDate::from_ymd_opt(2026, 11, 12).unwrap();
        day.and_hms_opt(hour, minute, 0)
            .unwrap()
            .and_local_timezone(chrono::Local)
            .single()
            .unwrap()
            .with_timezone(&Utc)
    }

    fn recording(id: u128, title: &str, start: DateTime<Utc>) -> Meeting {
        serde_json::from_value(serde_json::json!({
            "id": Uuid::from_u128(id).to_string().to_uppercase(),
            "title": title,
            "appName": "Zoom",
            "startedAt": start.to_rfc3339_opts(chrono::SecondsFormat::Secs, true),
            "endedAt": (start + chrono::Duration::minutes(25))
                .to_rfc3339_opts(chrono::SecondsFormat::Secs, true),
            "relativePath": format!("meetings/{id}"),
        }))
        .unwrap()
    }

    fn event(id: &str, start: DateTime<Utc>) -> CalendarEvent {
        CalendarEvent {
            provider: "ics".into(),
            external_id: id.into(),
            title: format!("Event {id}"),
            start,
            end: start + chrono::Duration::minutes(30),
            meeting_url: Some("https://meet.example/x".into()),
            source_calendar_title: None,
            participant_names: vec!["Maya Chen".into()],
            participant_identities: Vec::new(),
            agenda: None,
        }
    }

    #[test]
    fn fill_replaces_fields_in_order_or_by_number() {
        assert_eq!(fill("In %lldh %lldm", &["2", "10"]), "In 2h 10m");
        assert_eq!(fill("Now · %@", &["10:48 AM"]), "Now · 10:48 AM");
        assert_eq!(fill("%2$@ before %1$@", &["a", "b"]), "b before a");
        assert_eq!(fill("100%% sure, %d", &["3"]), "100% sure, 3");
        assert_eq!(fill("No fields", &["x"]), "No fields");
        assert_eq!(fill("Odd %q stays", &[]), "Odd %q stays");
    }

    #[test]
    fn right_to_left_phrases_keep_their_leading_number() {
        assert_eq!(directional("2 متأخرة"), "\u{200f}2 متأخرة");
        assert_eq!(directional("\u{200f}2 متأخرة"), "\u{200f}2 متأخرة");
        assert_eq!(directional("2 overdue"), "2 overdue");
        assert_eq!(directional("10:48"), "10:48");
    }

    #[test]
    fn two_columns_need_a_readable_leading_column_beside_the_trailing_one() {
        assert_eq!(columns::trailing_width(1.0), 336.);
        assert_eq!(columns::two_column_minimum_width(1.0), 480. + 16. + 336.);
        assert_eq!(columns::count(832., 1.0, true, true), 2);
        assert_eq!(columns::count(831., 1.0, true, true), 1);
        assert_eq!(columns::count(0., 1.0, true, true), 1);
        // The widest page, inside its padding, has room; the reading page has not.
        assert_eq!(columns::count(columns::WIDE_PAGE - 56., 1.0, true, true), 2);
        assert_eq!(
            columns::count(columns::READING_PAGE - 56., 1.0, true, true),
            1
        );
    }

    #[test]
    fn columns_grow_with_the_text_size() {
        use lokalbot_core::settings::TextSize;
        let small = columns::two_column_minimum_width(TextSize::Small.scale());
        let standard = columns::two_column_minimum_width(TextSize::Standard.scale());
        let largest = columns::two_column_minimum_width(TextSize::Largest.scale());
        assert!(small < standard && standard < largest);
        assert!(columns::trailing_width(TextSize::Largest.scale()) > 336.);
        assert_eq!(
            columns::count(900., TextSize::Standard.scale(), true, true),
            2
        );
        assert_eq!(
            columns::count(900., TextSize::Largest.scale(), true, true),
            1
        );
    }

    #[test]
    fn a_side_without_panels_leaves_no_gutter_and_keeps_the_reading_width() {
        assert_eq!(columns::count(1008., 1.0, true, false), 1);
        assert_eq!(columns::count(1008., 1.0, false, true), 1);
        assert_eq!(columns::count(1008., 1.0, false, false), 1);
        assert_eq!(columns::page_maximum_width(true, true), 1064.);
        assert_eq!(columns::page_maximum_width(false, false), 1064.);
        assert_eq!(columns::page_maximum_width(true, false), 780.);
        assert_eq!(columns::page_maximum_width(false, true), 780.);
    }

    #[test]
    fn app_bars_are_shares_of_the_longest_row() {
        let per_app = vec![
            ("Xcode".to_string(), 5400.),
            ("Safari".to_string(), 2700.),
            ("Slack".to_string(), 600.),
        ];
        let bars = app_bars(&per_app, APP_LIMIT);
        assert_eq!(
            bars.iter().map(|b| b.label.as_str()).collect::<Vec<_>>(),
            ["Xcode", "Safari", "Slack"]
        );
        assert_eq!(bars[0].fraction, 1.);
        assert_eq!(bars[1].fraction, 0.5);
        assert!((bars[2].fraction - 600. / 5400.).abs() < 1e-4);
        assert!(bars.iter().all(|b| !b.is_other));
        assert!(app_bars(&[], APP_LIMIT).is_empty());
        assert!(app_bars(&[("Idle".into(), 0.)], APP_LIMIT).is_empty());
    }

    #[test]
    fn the_folded_tail_never_runs_past_the_track() {
        let mut per_app = vec![("Xcode".to_string(), 1000.)];
        per_app.extend((0..6).map(|i| (format!("App {i}"), 400. - f64::from(i) * 10.)));
        let bars = app_bars(&per_app, 2);
        assert_eq!(bars.len(), 3);
        assert_eq!(bars[0].label, "Xcode");
        assert_eq!(bars[1].label, "App 0");
        let other = &bars[2];
        assert!(other.is_other);
        assert_eq!(other.seconds, 390. + 380. + 370. + 360. + 350.);
        assert_eq!(other.fraction, 1.);
        assert!((bars[0].fraction - 1000. / other.seconds).abs() < 1e-9);
        // Under a minute folds even with room left.
        let short = app_bars(&[("Xcode".into(), 600.), ("Finder".into(), 30.)], 4);
        assert_eq!(short.len(), 2);
        assert!(short[1].is_other);
    }

    #[test]
    fn attention_summary_counts_overdue_and_what_actions_still_holds() {
        let today = NaiveDate::from_ymd_opt(2026, 10, 20).unwrap();
        let day = |d| NaiveDate::from_ymd_opt(2026, 10, d);
        let threads: Vec<ActionThread> = [day(10), day(18), day(25), None, day(19)]
            .into_iter()
            .enumerate()
            .map(|(ix, due)| {
                thread(vec![reference(
                    &format!("a{ix}"),
                    ActionStatus::Open,
                    true,
                    due,
                    1 + ix as u32,
                )])
            })
            .collect();
        let summary = AttentionSummary::new(&threads, ATTENTION_LIMIT, today);
        assert_eq!(summary.open, 5);
        assert_eq!(summary.overdue, 3);
        assert_eq!(summary.shown, 3, "the footer names the real number of rows");
        assert_eq!(summary.remainder, 2);
        assert!(summary.shows_footer());

        let few = AttentionSummary::new(&threads[2..4], ATTENTION_LIMIT, today);
        assert_eq!(
            [few.open, few.overdue, few.shown, few.remainder],
            [2, 0, 2, 0]
        );
        assert!(!few.shows_footer());
        let none = AttentionSummary::new(&[], ATTENTION_LIMIT, today);
        assert_eq!(none, AttentionSummary::default());
        let no_rows = AttentionSummary::new(&threads, 0, today);
        assert_eq!([no_rows.shown, no_rows.remainder], [0, 5]);
    }

    #[test]
    fn recordings_and_events_merge_in_time_order_and_a_recorded_event_appears_once() {
        let now = at(11, 30);
        let mut standup = recording(1, "Engineering standup", at(10, 0));
        standup.calendar_event_id = Some("standup".into());
        let entries = agenda_entries(
            &[&standup],
            &[
                event("review", at(14, 0)),
                event("standup", at(10, 0)),
                event("early", at(9, 0)),
            ],
            None,
            now,
        );
        assert_eq!(
            entries.iter().map(|e| e.id.as_str()).collect::<Vec<_>>(),
            [
                "event-early",
                format!("recording-{}", Uuid::from_u128(1)).as_str(),
                "event-review"
            ]
        );
        assert_eq!(entries[0].status, EntryStatus::Ended);
        assert_eq!(entries[1].status, EntryStatus::Recorded);
        assert_eq!(entries[2].status, EntryStatus::Upcoming { minutes: 150 });
        assert!(!entries[2].is_soon);
    }

    #[test]
    fn the_live_recording_leads_once_and_other_days_and_samples_stay_out() {
        let now = at(11, 0);
        let live = recording(1, "Untitled", at(10, 48));
        let mut sample = recording(2, "Sample", at(9, 0));
        sample.sample_id = Some("orders-api/en".into());
        let yesterday = recording(3, "Old", at(10, 0) - chrono::Duration::days(1));
        let entries = agenda_entries(
            &[&live, &live, &sample, &yesterday],
            &[],
            Some(Uuid::from_u128(1)),
            now,
        );
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].status, EntryStatus::Recording);
    }

    #[test]
    fn at_the_same_minute_the_recording_comes_before_the_event() {
        let entries = agenda_entries(
            &[&recording(1, "Ad hoc", at(10, 0))],
            &[event("other", at(10, 0))],
            None,
            at(12, 0),
        );
        assert!(entries[0].meeting.is_some());
        assert!(entries[1].meeting.is_none());
    }

    #[test]
    fn the_now_line_sits_before_the_first_entry_still_ahead() {
        let now = at(10, 48);
        let entries = agenda_entries(
            &[&recording(1, "Standup", at(10, 0))],
            &[event("review", at(11, 0)), event("planning", at(14, 0))],
            None,
            now,
        );
        assert!(entries[1].is_soon, "within the hour reads in the accent");
        let rows = agenda_rows(entries, now);
        assert!(matches!(rows[1], AgendaRow::Now(at) if at == now));
        assert!(
            !has_hairline_after(0, &rows),
            "the now line draws its own rule"
        );
        assert!(has_hairline_after(2, &rows));
        assert!(
            !has_hairline_after(3, &rows),
            "the last row ends at the panel"
        );

        // Nothing ahead: no line. A morning before everything starts with it.
        let past = agenda_entries(&[&recording(1, "Standup", at(10, 0))], &[], None, now);
        assert!(
            agenda_rows(past, now)
                .iter()
                .all(|r| !matches!(r, AgendaRow::Now(_)))
        );
        let morning = agenda_entries(&[], &[event("review", at(11, 0))], None, at(8, 0));
        assert!(matches!(
            agenda_rows(morning, at(8, 0))[0],
            AgendaRow::Now(_)
        ));
    }

    #[test]
    fn the_next_meeting_appears_within_the_hour_only() {
        let schedule = vec![event("review", at(11, 0))];
        let none = HashSet::new();
        assert!(next_meeting(&schedule, at(9, 59), &none).is_none());
        assert_eq!(
            next_meeting(&schedule, at(10, 0), &none).map(|e| e.external_id.as_str()),
            Some("review")
        );
        assert!(next_meeting(&schedule, at(10, 48), &none).is_some());
    }

    #[test]
    fn the_next_meeting_keeps_one_under_way_and_skips_ended_and_recorded_ones() {
        let schedule = vec![event("standup", at(10, 0)), event("review", at(10, 40))];
        let none = HashSet::new();
        assert_eq!(
            next_meeting(&schedule, at(10, 20), &none).map(|e| e.external_id.as_str()),
            Some("standup"),
            "the meeting under way leads"
        );
        let recorded: HashSet<String> = ["standup".to_string()].into();
        assert_eq!(
            next_meeting(&schedule, at(10, 20), &recorded).map(|e| e.external_id.as_str()),
            Some("review")
        );
        assert!(
            next_meeting(&schedule, at(11, 30), &none).is_none(),
            "both ended"
        );
    }

    #[test]
    fn event_status_follows_the_clock() {
        let review = event("review", at(11, 0));
        assert_eq!(
            event_status(&review, at(9, 50)),
            EntryStatus::Upcoming { minutes: 70 }
        );
        assert_eq!(
            event_status(&review, at(10, 59)),
            EntryStatus::Upcoming { minutes: 1 }
        );
        assert_eq!(
            event_status(&review, at(11, 0) - chrono::Duration::seconds(30)),
            EntryStatus::StartingNow
        );
        assert_eq!(event_status(&review, at(11, 10)), EntryStatus::InProgress);
        assert_eq!(event_status(&review, at(13, 0)), EntryStatus::Ended);
    }

    #[test]
    fn the_recap_is_the_first_line_of_the_summary_overview() {
        let prose = "## TL;DR\nThe team picked Redis for the caching layer and deferred cluster mode.\n\n## Decisions\n- Adopt Redis for caching.\n";
        assert_eq!(
            recap_line(prose).as_deref(),
            Some("The team picked Redis for the caching layer and deferred cluster mode.")
        );
        let bullets = "# Notes\n\n## TL;DR\n\n- **You:** Redis was selected for the **caching** layer. — [00:01:54]\n- Second point.\n";
        assert_eq!(
            recap_line(bullets).as_deref(),
            Some("Redis was selected for the caching layer.")
        );
        let numbered = "### Overview\n1. Ana takes the rollout ([12:05] – [12:40]) next week\n";
        assert_eq!(
            recap_line(numbered).as_deref(),
            Some("Ana takes the rollout next week")
        );
    }

    #[test]
    fn the_recap_is_left_out_without_an_overview_or_with_only_actions() {
        assert_eq!(
            recap_line("## Decisions\n- Adopt Redis for caching.\n"),
            None
        );
        assert_eq!(
            recap_line("## TL;DR\n\n- [ ] Draft the document\n\n_None._\n"),
            None
        );
        assert_eq!(recap_line(""), None);
        assert_eq!(recap_line("####### TL;DR\nNot a heading at all.\n"), None);
        let long = format!("## Summary\n{}", "word ".repeat(120));
        let line = recap_line(&long).unwrap();
        assert!(line.ends_with('…'));
        assert!(line.chars().count() <= RECAP_MAXIMUM_CHARACTERS + 1);
    }

    fn digest(markdown: &str) -> DayDigest {
        lokalbot_core::parse_digest(markdown)
    }

    #[test]
    fn highlights_are_the_digests_at_a_glance_lines_or_its_first_task_titles() {
        assert_eq!(highlights_markdown(None), "");
        let glance = digest(
            "## Day summary\n\n### At a glance\n- Shoot is booked\n- Quote requested\n\n### Tasks\n- **Holiday shoot prep** — In progress. Booked.\n",
        );
        assert_eq!(
            highlights_markdown(Some(&glance)),
            "- Shoot is booked\n- Quote requested"
        );
        let mut tasks_only = glance.clone();
        tasks_only.at_a_glance_markdown.clear();
        assert_eq!(
            highlights_markdown(Some(&tasks_only)),
            "- Holiday shoot prep"
        );
    }

    #[test]
    fn digest_line_states() {
        let written = Some(at(9, 58));
        assert_eq!(
            DigestLine::new(true, written, true, true),
            DigestLine::Writing
        );
        assert_eq!(
            DigestLine::new(false, None, false, false),
            DigestLine::Missing
        );
        assert_eq!(
            DigestLine::new(true, written, true, false),
            DigestLine::Stale(written)
        );
        assert_eq!(
            DigestLine::new(true, written, false, false),
            DigestLine::Current(written)
        );
        assert!(!DigestLine::Current(None).shows_footer());
        assert!(DigestLine::Current(written).shows_footer());
        assert!(DigestLine::Missing.shows_footer());
    }

    #[test]
    fn get_started_is_the_page_only_while_there_is_nothing_else() {
        assert_eq!(
            PageLayout::new(true, false),
            PageLayout::Sections {
                getting_started_below: true
            }
        );
        assert_eq!(
            PageLayout::new(true, true),
            PageLayout::Sections {
                getting_started_below: false
            }
        );
        assert_eq!(PageLayout::new(false, false), PageLayout::GettingStarted);
        assert_eq!(PageLayout::new(false, true), PageLayout::Placeholder);
        assert!(PageLayout::new(true, true).shows_sections());
        assert!(!PageLayout::GettingStarted.shows_sections());
        assert!(!PageLayout::Placeholder.shows_sections());
    }

    fn reference_of(
        kind: ReferenceKind,
        text: &str,
        owner: Option<&str>,
        mine: bool,
    ) -> UpcomingReference {
        UpcomingReference {
            id: text.to_string(),
            kind,
            text: text.to_string(),
            meeting_id: Uuid::from_u128(7),
            meeting_title: "Design review".into(),
            meeting_date: at(11, 0) - chrono::Duration::days(7),
            owner: owner.map(str::to_string),
            is_for_user: mine,
            due: None,
            source_meeting_count: 1,
        }
    }

    fn evidence() -> UpcomingEvidence {
        UpcomingEvidence {
            event: event("review", at(11, 0)),
            related_meetings: vec![RelatedMeeting {
                meeting_id: Uuid::from_u128(7),
                title: "Atlas review".into(),
                started_at: at(11, 0) - chrono::Duration::days(7),
                summary: String::new(),
                participant_matches: 1,
                relevance_score: 1,
            }],
            decisions: Vec::new(),
            commitments: Vec::new(),
            projects: Vec::new(),
            agenda: None,
        }
    }

    #[test]
    fn preparation_rows_take_one_of_each_kind_and_count_the_rest() {
        let mut evidence = evidence();
        evidence.decisions = (0..2)
            .map(|i| {
                reference_of(
                    ReferenceKind::Decision,
                    &format!("Decision {i}"),
                    None,
                    false,
                )
            })
            .collect();
        evidence.commitments = vec![
            reference_of(
                ReferenceKind::Commitment,
                "Benchmark failover",
                Some("Daniel Ortiz"),
                false,
            ),
            reference_of(ReferenceKind::Commitment, "Send the plan", Some("Me"), true),
        ];
        evidence.projects = vec![UpcomingProject {
            name: "Atlas".into(),
            status: "Shipping".into(),
            last_active_day: "2026-11-10".into(),
        }];
        let rows = preparation_rows(&evidence);
        assert_eq!(
            rows.iter().map(|r| r.kind).collect::<Vec<_>>(),
            [
                PreparationKind::Decision,
                PreparationKind::Commitment,
                PreparationKind::Project
            ]
        );
        assert_eq!(rows[0].source.as_deref(), Some("Design review"));
        assert_eq!(rows[1].source.as_deref(), Some("Daniel Ortiz"));
        assert_eq!(rows[0].target, Some(Uuid::from_u128(7)));
        assert_eq!(rows[2].text, "Atlas — Shipping");
        assert_eq!(rows[2].date, NaiveDate::from_ymd_opt(2026, 11, 10));
        let more = more_preparation_rows(&evidence);
        assert_eq!(
            more.iter().map(|r| r.text.as_str()).collect::<Vec<_>>(),
            ["Decision 1", "Send the plan"]
        );
        assert!(more[1].source_is_user && more[1].source.is_none());
    }

    #[test]
    fn preparation_falls_back_to_the_closest_meeting_and_shows_the_template_brief_only_without_rows()
     {
        let rows = preparation_rows(&evidence());
        assert_eq!(
            rows.iter().map(|r| r.kind).collect::<Vec<_>>(),
            [PreparationKind::RecentMeeting]
        );
        assert_eq!(rows[0].target, Some(Uuid::from_u128(7)));
        assert!(shows_brief(true, 3));
        assert!(
            !shows_brief(false, 3),
            "the template brief only restates the rows"
        );
        assert!(shows_brief(false, 0));
    }

    #[test]
    fn priorities_are_today_s_for_yesterday_s_brief_and_named_for_older_ones() {
        let today = NaiveDate::from_ymd_opt(2026, 11, 16).unwrap(); // a Monday
        assert!(brief_is_current("2026-11-15", today));
        assert!(!brief_is_current("2026-11-13", today));
        assert_eq!(
            priorities_source("2026-11-15", today),
            PrioritiesSource::Today
        );
        assert_eq!(
            priorities_source("2026-11-13", today),
            PrioritiesSource::Day(
                NaiveDate::from_ymd_opt(2026, 11, 13).unwrap(),
                DayNaming::Weekday
            )
        );
        assert_eq!(
            priorities_source("2026-11-02", today),
            PrioritiesSource::Day(
                NaiveDate::from_ymd_opt(2026, 11, 2).unwrap(),
                DayNaming::Date
            )
        );
        assert_eq!(
            priorities_source("someday", today),
            PrioritiesSource::PreviousWorkday
        );
    }
}
