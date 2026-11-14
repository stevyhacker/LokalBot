//! What Timeline shows for one day, without drawing it: the rail's sessions
//! and meetings under Morning, Afternoon and Evening with Away gaps
//! (`TimelineDayList.swift`), the hour strip (`TimelineDayStrip.swift`), what
//! the arrow keys walk (`TimelineListSelection`), the rail's opening width
//! (`TimelineRailMetric`), the day's actions panel (`TimelineDayActions`) and
//! the digest's state (`TodayDigestLine`, `TimelineDigestPreview`).
//!
//! Display only: nothing here is stored. A call app's session that folds into
//! its meeting keeps its activity in All captured activity.

use std::collections::HashSet;

use chrono::{DateTime, Duration, Local, NaiveDate, Timelike as _, Utc};
use lokalbot_core::{ActionStatus, ActionThread, ActivityBlock, Meeting, WorkSession};
use uuid::Uuid;

/// A stretch this long with nothing recorded gets its own "Away" line.
pub(crate) const MINIMUM_GAP_SECONDS: f64 = lokalbot_core::timeline::AWAY_MINIMUM_GAP_SECONDS;
/// A call app's session folds into a meeting that covers this much of it.
pub(crate) const FOLD_SHARE: f64 = 0.6;

// ------------------------------------------------------------------ list

/// Before noon, before five, and the rest of the day.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Part {
    Morning,
    Afternoon,
    Evening,
}

impl Part {
    /// The heading's catalog key.
    pub(crate) fn title(self) -> &'static str {
        match self {
            Part::Morning => "Morning",
            Part::Afternoon => "Afternoon",
            Part::Evening => "Evening",
        }
    }

    pub(crate) fn of_hour(hour: u32) -> Part {
        if hour < 12 {
            Part::Morning
        } else if hour < 17 {
            Part::Afternoon
        } else {
            Part::Evening
        }
    }

    fn of(at: DateTime<Utc>) -> Part {
        Part::of_hour(at.with_timezone(&Local).hour())
    }
}

#[derive(Clone, Debug, PartialEq)]
pub(crate) enum RowKind {
    /// A work session, by `WorkSession::id`.
    Work(String),
    Meeting {
        id: Uuid,
        live: bool,
    },
}

/// One session or meeting in the rail.
#[derive(Clone, Debug, PartialEq)]
pub(crate) struct Row {
    pub id: String,
    pub kind: RowKind,
    pub start: DateTime<Utc>,
    pub end: DateTime<Utc>,
    pub title: String,
    /// The second line: project and what was produced, or the apps, for
    /// work; "Meeting · app" for a meeting. Empty when the title says it all.
    pub detail: String,
    /// A session's active time; a meeting's length, in seconds.
    pub duration: f64,
    /// What colours a session's dot and its bar: its project, or its busiest
    /// app on a day without projects. `None` reads as other activity.
    /// Meetings keep their own tone.
    pub color_key: Option<String>,
    /// A title that only lists apps reads quieter than one that names work.
    pub quiet: bool,
    /// Call-app sessions folded into this meeting.
    pub folded_sessions: Vec<String>,
}

impl Row {
    pub(crate) fn is_meeting(&self) -> bool {
        matches!(self.kind, RowKind::Meeting { .. })
    }

    pub(crate) fn is_live(&self) -> bool {
        matches!(self.kind, RowKind::Meeting { live: true, .. })
    }

    pub(crate) fn meeting_row_id(meeting: Uuid) -> String {
        format!("meeting-{meeting}")
    }
}

#[derive(Clone, Debug, PartialEq)]
pub(crate) enum Entry {
    Row(Row),
    /// Nothing was recorded between two rows.
    Away {
        start: DateTime<Utc>,
        end: DateTime<Utc>,
    },
}

#[derive(Clone, Debug, PartialEq)]
pub(crate) struct Section {
    pub part: Part,
    pub entries: Vec<Entry>,
}

/// The rail's list for one day.
#[derive(Clone, Debug, Default, PartialEq)]
pub(crate) struct DayList {
    pub sections: Vec<Section>,
}

enum Item<'a> {
    Work(&'a WorkSession),
    Meeting(&'a Meeting, DateTime<Utc>),
}

impl Item<'_> {
    fn start(&self) -> DateTime<Utc> {
        match self {
            Item::Work(session) => session.start,
            Item::Meeting(meeting, _) => meeting.started_at,
        }
    }

    fn end(&self) -> DateTime<Utc> {
        match self {
            Item::Work(session) => session.end,
            Item::Meeting(_, end) => *end,
        }
    }

    fn is_meeting(&self) -> bool {
        matches!(self, Item::Meeting(..))
    }

    fn id(&self) -> String {
        match self {
            Item::Work(session) => session.id.clone(),
            Item::Meeting(meeting, _) => Row::meeting_row_id(meeting.id),
        }
    }
}

impl DayList {
    /// `sessions` are the day's sessions; recorded meetings among them are
    /// left out and come from `meetings`. `blocks` are the day's activity,
    /// for which apps a session used. `uses_project_colors`: the day's time
    /// is split by project, so a session without one reads as other activity.
    pub(crate) fn new(
        sessions: &[WorkSession],
        blocks: &[ActivityBlock],
        meetings: &[Meeting],
        now: DateTime<Utc>,
        uses_project_colors: bool,
    ) -> Self {
        let timed: Vec<(&Meeting, DateTime<Utc>)> = meetings
            .iter()
            .map(|m| (m, lokalbot_core::timeline::meeting_end(m, now)))
            .collect();
        let work: Vec<&WorkSession> = sessions.iter().filter(|s| !s.is_meeting()).collect();
        let mut folded: Vec<(Uuid, String)> = Vec::new();
        for session in &work {
            if let Some(host) = meeting_covering(session, &timed) {
                folded.push((host, session.id.clone()));
            }
        }
        let folded_ids: HashSet<&str> = folded.iter().map(|(_, id)| id.as_str()).collect();

        let mut items: Vec<Item> = work.iter().map(|s| Item::Work(s)).collect();
        items.extend(timed.iter().map(|(m, end)| Item::Meeting(m, *end)));
        // A meeting leads a session that starts with it.
        items.sort_by(|a, b| {
            a.start()
                .cmp(&b.start())
                .then(b.is_meeting().cmp(&a.is_meeting()))
                .then(a.id().cmp(&b.id()))
        });

        let mut sections: Vec<Section> = Vec::new();
        let mut latest_end: Option<DateTime<Utc>> = None;
        for item in &items {
            // The gap closes the part of the day it began in, as the list reads.
            if let Some(latest) = latest_end
                && seconds(item.start() - latest) >= MINIMUM_GAP_SECONDS
                && let Some(last) = sections.last_mut()
            {
                last.entries.push(Entry::Away {
                    start: latest,
                    end: item.start(),
                });
            }
            latest_end = Some(latest_end.map_or(item.end(), |l| l.max(item.end())));
            let row = match item {
                Item::Work(session) => {
                    // A folded call is recorded time, shown as its meeting's row.
                    if folded_ids.contains(session.id.as_str()) {
                        continue;
                    }
                    let text = work_text(
                        session,
                        &used_apps(session, blocks),
                        super::agent_work::outcome_text(
                            &lokalbot_core::coding_agents::attribution::Outcomes::of(
                                &session.agent_bursts,
                            ),
                        ),
                    );
                    Row {
                        id: session.id.clone(),
                        kind: RowKind::Work(session.id.clone()),
                        start: session.start,
                        end: session.end,
                        title: text.title,
                        detail: text.detail,
                        duration: session.active_seconds,
                        color_key: session_project(session).map(str::to_string).or_else(|| {
                            (!uses_project_colors).then(|| session.primary_app.clone())
                        }),
                        quiet: text.quiet,
                        folded_sessions: Vec::new(),
                    }
                }
                Item::Meeting(meeting, end) => {
                    let live = meeting.is_live();
                    Row {
                        id: Row::meeting_row_id(meeting.id),
                        kind: RowKind::Meeting {
                            id: meeting.id,
                            live,
                        },
                        start: meeting.started_at,
                        end: *end,
                        title: meeting.display_title(),
                        detail: meeting_detail(&meeting.app_name, live),
                        duration: seconds(*end - meeting.started_at).max(0.0),
                        color_key: None,
                        quiet: false,
                        folded_sessions: folded
                            .iter()
                            .filter(|(host, _)| *host == meeting.id)
                            .map(|(_, id)| id.clone())
                            .collect(),
                    }
                }
            };
            let part = Part::of(row.start);
            match sections.last_mut() {
                Some(section) if section.part == part => section.entries.push(Entry::Row(row)),
                _ => sections.push(Section {
                    part,
                    entries: vec![Entry::Row(row)],
                }),
            }
        }
        Self { sections }
    }

    /// Every session and meeting row, in list order.
    pub(crate) fn rows(&self) -> impl Iterator<Item = &Row> {
        self.sections.iter().flat_map(|section| {
            section.entries.iter().filter_map(|entry| match entry {
                Entry::Row(row) => Some(row),
                Entry::Away { .. } => None,
            })
        })
    }

    pub(crate) fn row_count(&self) -> usize {
        self.rows().count()
    }

    pub(crate) fn row(&self, id: &str) -> Option<&Row> {
        self.rows().find(|row| row.id == id)
    }

    /// The row that shows a session: its own, or the meeting it folded into.
    pub(crate) fn row_showing(&self, session: &str) -> Option<&Row> {
        self.rows()
            .find(|row| row.id == session || row.folded_sessions.iter().any(|s| s == session))
    }

    /// The session a digest task's "09:00–10:30" covers most, so an older
    /// digest's time range can open that session.
    pub(crate) fn work_row_in_time_range(&self, text: &str, day: NaiveDate) -> Option<&Row> {
        let (start, end) = interval_from_time_range(text, day)?;
        let mut best: Option<(&Row, f64)> = None;
        for row in self.rows().filter(|row| !row.is_meeting()) {
            let overlap = seconds(row.end.min(end) - row.start.max(start));
            if overlap > best.map_or(0.0, |(_, o)| o) {
                best = Some((row, overlap));
            }
        }
        best.map(|(row, _)| row)
    }
}

fn seconds(duration: Duration) -> f64 {
    duration.num_milliseconds() as f64 / 1000.0
}

/// "09:00–10:30" on `day`. A range that ends before it starts runs past
/// midnight and is clipped to the day.
pub(crate) fn interval_from_time_range(
    text: &str,
    day: NaiveDate,
) -> Option<(DateTime<Utc>, DateTime<Utc>)> {
    let numbers: Vec<u32> = text
        .split(|c: char| !c.is_ascii_digit())
        .filter(|part| !part.is_empty())
        .filter_map(|part| part.parse().ok())
        .collect();
    let &[h1, m1, h2, m2] = numbers.as_slice() else {
        return None;
    };
    if h1 >= 24 || h2 >= 24 || m1 >= 60 || m2 >= 60 {
        return None;
    }
    let (_, day_end) = lokalbot_core::time::local_day_bounds(day);
    let at = |hour, minute| {
        day.and_hms_opt(hour, minute, 0)?
            .and_local_timezone(Local)
            .earliest()
            .map(|t| t.with_timezone(&Utc))
    };
    let start = at(h1, m1)?;
    let raw_end = at(h2, m2)?;
    let end = if raw_end > start { raw_end } else { day_end };
    (end > start).then_some((start, end))
}

// ------------------------------------------------------------- row text

/// The project a session's title names, the one whose colour it takes.
pub(crate) fn session_project(session: &WorkSession) -> Option<&str> {
    session
        .title_names_project
        .then(|| session.project_shares.first().map(|s| s.project.as_str()))
        .flatten()
}

/// A project session's title is "projects · task"; without a task it is the
/// projects alone.
pub(crate) fn project_and_task(session: &WorkSession) -> (String, Option<String>) {
    match session.title.split_once(" · ") {
        Some((project, task)) => (project.to_string(), Some(task.to_string())),
        None => (session.title.clone(), None),
    }
}

/// Apps used for at least a minute, busiest first. Apps glanced at for
/// seconds are left out, unless that leaves none.
pub(crate) fn used_apps(session: &WorkSession, blocks: &[ActivityBlock]) -> Vec<String> {
    let mine: HashSet<i64> = session.block_ids.iter().copied().collect();
    let used: Vec<String> = session
        .apps
        .iter()
        .filter(|app| {
            let app_blocks: Vec<&ActivityBlock> = blocks
                .iter()
                .filter(|b| mine.contains(&b.id) && &b.app == *app)
                .collect();
            lokalbot_core::timeline::merged_duration(&app_blocks) >= 60.0
        })
        .cloned()
        .collect();
    if used.is_empty() {
        session.apps.clone()
    } else {
        used
    }
}

#[derive(Clone, Debug, PartialEq)]
pub(crate) struct WorkText {
    pub title: String,
    pub detail: String,
    pub quiet: bool,
}

/// A session's two lines. With a project the task leads and the project
/// moves to the second line beside what the agents produced. Without one,
/// the window that named the session leads and its apps follow. A session
/// only its apps describe is one quiet line.
pub(crate) fn work_text(
    session: &WorkSession,
    used_apps: &[String],
    outcomes: Option<String>,
) -> WorkText {
    let apps = lokalbot_core::timeline::app_summary(used_apps);
    let outcomes: Vec<String> = outcomes.into_iter().collect();
    if session.title_names_project {
        let (project, task) = project_and_task(session);
        return match task {
            Some(task) => WorkText {
                title: task,
                detail: joined(std::iter::once(project).chain(outcomes)),
                quiet: false,
            },
            None => WorkText {
                title: project,
                detail: if outcomes.is_empty() {
                    apps
                } else {
                    joined(outcomes)
                },
                quiet: false,
            },
        };
    }
    if session.title_names_apps {
        return WorkText {
            title: session.title.clone(),
            detail: joined(outcomes),
            quiet: true,
        };
    }
    WorkText {
        title: session.title.clone(),
        detail: joined(std::iter::once(apps).chain(outcomes)),
        quiet: false,
    }
}

/// "Meeting · Zoom", or "Recording · Zoom" while it is being recorded.
pub(crate) fn meeting_detail(app: &str, live: bool) -> String {
    let kind = lokalbot_i18n::tr(if live { "Recording" } else { "Meeting" }).to_string();
    joined([kind, app.trim().to_string()])
}

fn joined(parts: impl IntoIterator<Item = String>) -> String {
    parts
        .into_iter()
        .filter(|part| !part.is_empty())
        .collect::<Vec<_>>()
        .join(" · ")
}

// ------------------------------------------------------- folding a call

/// The meeting a call-app session belongs to: the one that covers most of
/// it, when that is at least `FOLD_SHARE`. Work with a project and agent
/// sessions never fold.
pub(crate) fn meeting_covering(
    session: &WorkSession,
    meetings: &[(&Meeting, DateTime<Utc>)],
) -> Option<Uuid> {
    if !session.agent_bursts.is_empty() || session.title_names_project {
        return None;
    }
    let span = seconds(session.end - session.start);
    if span <= 0.0 {
        return None;
    }
    let mut best: Option<(Uuid, f64)> = None;
    for (meeting, end) in meetings {
        if !is_same_app(&session.primary_app, &meeting.app_name) {
            continue;
        }
        let overlap = seconds(session.end.min(*end) - session.start.max(meeting.started_at));
        if overlap / span >= FOLD_SHARE && overlap > best.map_or(0.0, |(_, o)| o) {
            best = Some((meeting.id, overlap));
        }
    }
    best.map(|(id, _)| id)
}

/// The sampler stores an app's own name ("zoom.us", "Microsoft Teams") and
/// a meeting the name LokalBot gives its call app ("Zoom", "Teams"), so one
/// may contain the other.
pub(crate) fn is_same_app(session_app: &str, meeting_app: &str) -> bool {
    let key = |name: &str| -> String {
        name.chars()
            .filter(|c| c.is_alphanumeric())
            .flat_map(char::to_lowercase)
            .collect()
    };
    let (left, right) = (key(session_app), key(meeting_app));
    left.chars().count() >= 3
        && right.chars().count() >= 3
        && (left.contains(&right) || right.contains(&left))
}

// ------------------------------------------------------------- selection

/// What Timeline's main area shows: the day's page (`Digest`, with no row
/// chosen in the rail), a session or meeting row, or all captured activity.
/// `None` is something opened from elsewhere that belongs to no row.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum ListSelection {
    Digest,
    Row(String),
    Raw,
    None,
}

impl ListSelection {
    /// The rail from top to bottom, for the arrow keys. The day's page
    /// stands before the first session; All captured activity, the rail's
    /// bottom row, follows the last one.
    pub(crate) fn order(list: &DayList) -> Vec<ListSelection> {
        std::iter::once(ListSelection::Digest)
            .chain(list.rows().map(|row| ListSelection::Row(row.id.clone())))
            .chain(std::iter::once(ListSelection::Raw))
            .collect()
    }

    /// The selection `step` rows away, stopping at either end. From a
    /// selection the rail does not show, any step lands on the day's page.
    pub(crate) fn moved(&self, step: isize, list: &DayList) -> ListSelection {
        let order = Self::order(list);
        let Some(index) = order.iter().position(|s| s == self) else {
            return ListSelection::Digest;
        };
        let next = (index as isize + step).clamp(0, order.len() as isize - 1) as usize;
        order[next].clone()
    }
}

// ------------------------------------------------------------ hour strip

/// One bar of the strip: the row it selects, where it starts and ends (0 at
/// the leading edge, 1 at the trailing one) and what colours it.
#[derive(Clone, Debug, PartialEq)]
pub(crate) struct Bar {
    pub id: String,
    pub start: f64,
    pub end: f64,
    pub color_key: Option<String>,
}

#[derive(Clone, Debug, PartialEq)]
pub(crate) struct Tick {
    pub position: f64,
    pub at: DateTime<Utc>,
    /// The first hour and noon say AM or PM where the clock has them.
    pub names_day_period: bool,
}

/// The rail's hour strip: hours left to right, meetings in a lane above
/// work. Positions are fractions of a span of whole hours inside the day.
#[derive(Clone, Debug, PartialEq)]
pub(crate) struct DayStrip {
    pub meetings: Vec<Bar>,
    pub work: Vec<Bar>,
    /// One per hour, from the first hour to the last one inside the span.
    pub ticks: Vec<Tick>,
}

fn local_hour_start(at: DateTime<Utc>) -> DateTime<Utc> {
    let local = at.with_timezone(&Local);
    local
        .with_minute(0)
        .and_then(|t| t.with_second(0))
        .and_then(|t| t.with_nanosecond(0))
        .map_or(at, |t| t.with_timezone(&Utc))
}

impl DayStrip {
    /// `None` for a day with no rows inside `[day_start, day_end)`.
    pub(crate) fn new<'a>(
        rows: impl IntoIterator<Item = &'a Row>,
        day_start: DateTime<Utc>,
        day_end: DateTime<Utc>,
    ) -> Option<Self> {
        let clipped: Vec<(&Row, DateTime<Utc>, DateTime<Utc>)> = rows
            .into_iter()
            .filter_map(|row| {
                let start = row.start.max(day_start);
                let end = row.end.min(day_end);
                (end > start).then_some((row, start, end))
            })
            .collect();
        let first = clipped.iter().map(|(_, start, _)| *start).min()?;
        let last = clipped.iter().map(|(_, _, end)| *end).max()?;
        let span_start = local_hour_start(first);
        let mut span_end = last;
        // An end on the hour needs no extra hour; any other rounds up.
        let last_hour = local_hour_start(last);
        if last_hour < last {
            span_end = last_hour + Duration::hours(1);
        }
        span_end = span_end
            .max(span_start + Duration::hours(1))
            .min(day_end)
            .max(span_start + Duration::minutes(1));
        let length = seconds(span_end - span_start);
        let fraction = |at: DateTime<Utc>| seconds(at - span_start) / length;
        let mut meetings = Vec::new();
        let mut work = Vec::new();
        for (row, start, end) in clipped {
            let bar = Bar {
                id: row.id.clone(),
                start: fraction(start),
                end: fraction(end),
                color_key: row.color_key.clone(),
            };
            if row.is_meeting() {
                meetings.push(bar);
            } else {
                work.push(bar);
            }
        }
        let mut ticks = Vec::new();
        let mut cursor = span_start;
        while cursor < span_end {
            let hour = cursor.with_timezone(&Local).hour();
            ticks.push(Tick {
                position: fraction(cursor),
                at: cursor,
                names_day_period: ticks.is_empty() || hour == 12,
            });
            cursor += Duration::hours(1);
        }
        Some(Self {
            meetings,
            work,
            ticks,
        })
    }

    /// The ticks that get a label when only `count` labels fit: every
    /// second or third hour on a long day, always starting with the first.
    pub(crate) fn labelled_ticks(&self, count: usize) -> Vec<&Tick> {
        if count == 0 {
            return Vec::new();
        }
        if self.ticks.len() <= count {
            return self.ticks.iter().collect();
        }
        let stride = self.ticks.len().div_ceil(count);
        self.ticks.iter().step_by(stride).collect()
    }
}

/// A bar's place in a lane `width` wide. A short bar keeps `minimum` so it
/// can be seen, and never leaves the lane.
pub(crate) fn bar_frame(bar: &Bar, width: f32, minimum: f32) -> (f32, f32) {
    if width <= 0.0 {
        return (0.0, 0.0);
    }
    let start = bar.start.clamp(0.0, 1.0) as f32 * width;
    let end = bar.end.clamp(0.0, 1.0) as f32 * width;
    let bar_width = width.min(minimum.max(end - start));
    (start.min(width - bar_width), bar_width)
}

/// Where a click counts for a bar: its own place, widened to 12 around its
/// middle when it is drawn thinner, and kept inside the lane.
pub(crate) fn bar_hit_frame(bar: &Bar, width: f32) -> (f32, f32) {
    const MINIMUM: f32 = 12.0;
    let (x, drawn) = bar_frame(bar, width, 3.0);
    if width <= 0.0 || drawn >= MINIMUM {
        return (x, drawn);
    }
    let hit = width.min(MINIMUM);
    let left = x + drawn / 2.0 - hit / 2.0;
    (left.max(0.0).min(width - hit), hit)
}

/// Bars in the order to draw them: the longest first, so a short bar's
/// widened click area lies over its longer neighbour's edge.
pub(crate) fn hit_order(bars: &[Bar]) -> Vec<&Bar> {
    let mut ordered: Vec<&Bar> = bars.iter().collect();
    ordered.sort_by(|a, b| {
        (b.end - b.start)
            .partial_cmp(&(a.end - a.start))
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    ordered
}

// ------------------------------------------------------------ rail width

/// The rail in a roomy window.
pub(crate) const RAIL_IDEAL_WIDTH: f32 = 352.0;
/// The rail in the default window.
pub(crate) const RAIL_MINIMUM_WIDTH: f32 = 300.0;
/// The rail's share of the body while it is between those two.
pub(crate) const RAIL_SHARE: f32 = 0.30;
/// The narrowest the rail gets: a time, a short title and a duration fit.
pub(crate) const RAIL_FLOOR_WIDTH: f32 = 260.0;
/// The widest the divider drags it.
pub(crate) const RAIL_MAXIMUM_WIDTH: f32 = 540.0;
/// The day's page keeps the minimum every detail pane has.
pub(crate) const PAGE_MINIMUM_WIDTH: f32 = 420.0;
const DIVIDER_WIDTH: f32 = 1.0;

/// The rail's opening width in a body `available` wide, until the divider
/// is dragged: a share of the body between its two sizes, both grown with
/// the text size, and never so wide that the page drops under its minimum.
pub(crate) fn rail_width(available: f32, text_scale: f32) -> f32 {
    let factor = text_scale.max(0.5);
    let ideal = (RAIL_IDEAL_WIDTH * factor).round();
    let minimum = (RAIL_MINIMUM_WIDTH * factor).round();
    let shared = ideal.min(minimum.max((available * RAIL_SHARE).round()));
    let room = (available - DIVIDER_WIDTH - PAGE_MINIMUM_WIDTH).floor();
    RAIL_FLOOR_WIDTH.max(shared.min(room))
}

// ------------------------------------------------------ the day's actions

/// The user's actions that a meeting of `day` mentioned, done ones
/// included: open work first, then the rest, each in the index's order.
pub(crate) fn day_threads(all: Vec<ActionThread>, day: NaiveDate) -> Vec<ActionThread> {
    let (open, rest): (Vec<ActionThread>, Vec<ActionThread>) = all
        .into_iter()
        .filter(|thread| {
            thread.is_for_user()
                && thread
                    .references
                    .iter()
                    .any(|r| lokalbot_core::time::local_day(r.meeting_started_at) == day)
        })
        .partition(|thread| thread.status() == ActionStatus::Open);
    open.into_iter().chain(rest).collect()
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum ActionsSummary {
    Open(usize),
    AllDone(usize),
    /// Nothing is open, and some are deferred rather than done.
    NoneOpen(usize),
}

pub(crate) fn actions_summary(threads: &[ActionThread]) -> Option<ActionsSummary> {
    if threads.is_empty() {
        return None;
    }
    let open = threads
        .iter()
        .filter(|t| t.status() == ActionStatus::Open)
        .count();
    Some(if open > 0 {
        ActionsSummary::Open(open)
    } else if threads.iter().all(|t| t.status() == ActionStatus::Done) {
        ActionsSummary::AllDone(threads.len())
    } else {
        ActionsSummary::NoneOpen(threads.len())
    })
}

/// The badge beside the panel's title.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum ActionsPill {
    Open(usize),
    AllDone,
}

/// "2 open" while anything is; "All done" once every action is done.
/// Deferred actions are neither, so a day with only those says "0 open".
pub(crate) fn actions_pill(summary: ActionsSummary) -> ActionsPill {
    match summary {
        ActionsSummary::Open(count) => ActionsPill::Open(count),
        ActionsSummary::AllDone(_) => ActionsPill::AllDone,
        ActionsSummary::NoneOpen(_) => ActionsPill::Open(0),
    }
}

/// The panel lists its actions while one is open. Once none is, it is a
/// header alone, except that rows the reader was just shown stay, so
/// ticking the last one does not take the list away.
pub(crate) fn actions_show_rows(summary: ActionsSummary, had_open: bool) -> bool {
    matches!(summary, ActionsSummary::Open(_)) || had_open
}

// ------------------------------------------------------------- the digest

/// Where the day's digest stands (`TodayDigestLine`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum DigestLine {
    /// A digest is being written, by hand or on schedule.
    Writing,
    Missing,
    Current(Option<DateTime<Utc>>),
    /// Activity arrived after the digest was written; Update rewrites it.
    Stale(Option<DateTime<Utc>>),
}

impl DigestLine {
    pub(crate) fn state(
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

    /// The Highlights panel's footer: when the digest was written, Update
    /// once it is stale, progress while it is rewritten.
    pub(crate) fn shows_footer(self, has_digest: bool) -> bool {
        has_digest
            && match self {
                DigestLine::Writing | DigestLine::Stale(_) => true,
                DigestLine::Current(written_at) => written_at.is_some(),
                DigestLine::Missing => false,
            }
    }
}

/// The catalog key of the … menu item that writes the digest. It names what
/// choosing it will do; a digest is never rewritten without being asked.
pub(crate) fn digest_menu_title(writing: bool, has_digest: bool, stale: bool) -> &'static str {
    if writing {
        "Writing digest…"
    } else if !has_digest {
        "Write digest"
    } else if stale {
        "Update digest"
    } else {
        "Rewrite digest"
    }
}

// ------------------------------------------------------------- catalog

/// A macOS catalog entry with `%@` / `%lld` fields (or their numbered
/// forms), filled in order with `values`.
pub(crate) fn fill(template: &str, values: &[&str]) -> String {
    let mut text = template.to_string();
    for (index, value) in values.iter().enumerate() {
        for spec in ["@", "lld", "ld", "d"] {
            text = text.replace(&format!("%{}${spec}", index + 1), value);
        }
    }
    let mut result = String::with_capacity(text.len());
    let mut rest = text.as_str();
    let mut next = values.iter();
    while let Some(at) = rest.find('%') {
        result.push_str(&rest[..at]);
        let after = &rest[at + 1..];
        let spec = ["lld", "ld", "@", "d"]
            .into_iter()
            .find(|spec| after.starts_with(spec));
        match (spec, spec.and_then(|_| next.next())) {
            (Some(spec), Some(value)) => {
                result.push_str(value);
                rest = &after[spec.len()..];
            }
            _ => {
                result.push('%');
                rest = after;
            }
        }
    }
    result.push_str(rest);
    result
}

/// `fill` with the key translated first.
pub(crate) fn mac(key: &str, values: &[&str]) -> String {
    fill(lokalbot_i18n::tr(key), values)
}

/// A count phrase from the macOS catalog: "%lld meeting" / "%lld meetings".
pub(crate) fn mac_count(count: usize, one: &str, many: &str) -> String {
    mac(
        if count == 1 { one } else { many },
        &[&lokalbot_i18n::number(count)],
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone as _;
    use lokalbot_core::coding_agents::attribution::Share;

    fn at(hour: u32, minute: u32) -> DateTime<Utc> {
        Local
            .with_ymd_and_hms(2026, 11, 12, hour, minute, 0)
            .earliest()
            .unwrap()
            .with_timezone(&Utc)
    }

    fn session(id: &str, app: &str, start: DateTime<Utc>, end: DateTime<Utc>) -> WorkSession {
        WorkSession {
            id: id.to_string(),
            title: format!("{id} window"),
            title_names_apps: false,
            start,
            end,
            active_seconds: seconds(end - start),
            primary_app: app.to_string(),
            apps: vec![app.to_string()],
            block_ids: Vec::new(),
            notable_titles: Vec::new(),
            context_switch_count: 0,
            meeting_id: None,
            project_shares: Vec::new(),
            agent_bursts: Vec::new(),
            title_names_project: false,
        }
    }

    fn meeting(title: &str, app: &str, start: DateTime<Utc>, end: DateTime<Utc>) -> Meeting {
        let mut meeting = Meeting::new(title, app, start, "meetings/x");
        meeting.ended_at = Some(end);
        meeting
    }

    fn ids(list: &DayList) -> Vec<String> {
        list.rows().map(|row| row.id.clone()).collect()
    }

    #[test]
    fn a_call_apps_session_folds_into_the_meeting_that_covers_it() {
        let call = session("work-1", "zoom.us", at(10, 0), at(10, 25));
        let editor = session("work-2", "Xcode", at(9, 0), at(10, 30));
        let standup = meeting("Standup", "Zoom", at(10, 0), at(10, 20));
        let list = DayList::new(
            &[editor, call],
            &[],
            std::slice::from_ref(&standup),
            at(12, 0),
            false,
        );
        let meeting_row = Row::meeting_row_id(standup.id);
        assert_eq!(ids(&list), vec!["work-2".to_string(), meeting_row.clone()]);
        let row = list.row(&meeting_row).unwrap();
        assert_eq!(row.folded_sessions, vec!["work-1".to_string()]);
        assert_eq!(row.detail, "Meeting · Zoom");
        assert_eq!(list.row_showing("work-1").unwrap().id, meeting_row);
        assert_eq!(list.row_showing("work-2").unwrap().id, "work-2");
    }

    #[test]
    fn a_call_folds_only_when_the_meeting_covers_most_of_it() {
        // 15 of 40 minutes is under the share; another app never folds.
        let long_call = session("work-1", "zoom.us", at(10, 0), at(10, 40));
        let browser = session("work-2", "Firefox", at(10, 0), at(10, 15));
        let standup = meeting("Standup", "Zoom", at(10, 0), at(10, 15));
        let list = DayList::new(
            &[long_call, browser],
            &[],
            std::slice::from_ref(&standup),
            at(12, 0),
            false,
        );
        assert_eq!(list.row_count(), 3);
        // A meeting leads a session that starts with it.
        assert_eq!(ids(&list)[0], Row::meeting_row_id(standup.id));
    }

    #[test]
    fn project_sessions_never_fold() {
        let mut call = session("work-1", "zoom.us", at(10, 0), at(10, 20));
        call.title_names_project = true;
        call.title = "Atlas · Review".into();
        let standup = meeting("Standup", "Zoom", at(10, 0), at(10, 20));
        let list = DayList::new(&[call], &[], &[standup], at(12, 0), false);
        assert_eq!(list.row_count(), 2);
    }

    #[test]
    fn apps_match_when_one_name_contains_the_other() {
        assert!(is_same_app("zoom.us", "Zoom"));
        assert!(is_same_app("Microsoft Teams", "Teams"));
        assert!(!is_same_app("Xcode", "Zoom"));
        // Too short to tell apart.
        assert!(!is_same_app("Go", "Google Meet"));
    }

    #[test]
    fn rows_fall_under_morning_afternoon_and_evening_with_away_gaps() {
        let sessions = [
            session("work-1", "Xcode", at(9, 0), at(10, 0)),
            // 9:30–11:00 overlaps, so the gap starts at 11:00, not 10:00.
            session("work-2", "Safari", at(9, 30), at(11, 0)),
            session("work-3", "Xcode", at(11, 20), at(11, 50)),
            session("work-4", "Mail", at(13, 0), at(13, 30)),
            session("work-5", "Mail", at(18, 0), at(18, 10)),
        ];
        let list = DayList::new(&sessions, &[], &[], at(20, 0), false);
        let parts: Vec<Part> = list.sections.iter().map(|s| s.part).collect();
        assert_eq!(parts, vec![Part::Morning, Part::Afternoon, Part::Evening]);
        // 11:00 to 11:20 is no gap; 11:50 to 13:00 closes the morning.
        let morning = &list.sections[0].entries;
        assert_eq!(morning.len(), 4);
        assert_eq!(
            morning[3],
            Entry::Away {
                start: at(11, 50),
                end: at(13, 0)
            }
        );
        assert!(matches!(
            list.sections[1].entries.last(),
            Some(Entry::Away { .. })
        ));
        assert_eq!(list.sections[2].entries.len(), 1);
    }

    #[test]
    fn row_text_reads_like_the_mac() {
        let mut plain = session("work-1", "Xcode", at(9, 0), at(10, 0));
        plain.title = "TimelineView.swift".into();
        let apps = vec!["Xcode".to_string(), "Terminal".to_string()];
        let text = work_text(&plain, &apps, None);
        assert_eq!(text.title, "TimelineView.swift");
        assert_eq!(text.detail, "Xcode, Terminal");
        assert!(!text.quiet);

        let mut only_apps = plain.clone();
        only_apps.title = "Xcode, Terminal".into();
        only_apps.title_names_apps = true;
        let text = work_text(&only_apps, &apps, Some("1 PR opened".into()));
        assert_eq!(text.detail, "1 PR opened");
        assert!(text.quiet);

        let mut project = plain.clone();
        project.title_names_project = true;
        project.title = "Atlas · Fix the sync".into();
        let text = work_text(&project, &apps, Some("2 commits".into()));
        assert_eq!(text.title, "Fix the sync");
        assert_eq!(text.detail, "Atlas · 2 commits");

        project.title = "Atlas".into();
        let text = work_text(&project, &apps, None);
        assert_eq!(text.title, "Atlas");
        assert_eq!(text.detail, "Xcode, Terminal");
    }

    #[test]
    fn a_session_takes_its_projects_colour_or_its_apps() {
        let mut project = session("work-1", "Xcode", at(9, 0), at(10, 0));
        project.title_names_project = true;
        project.title = "Atlas · Sync".into();
        project.project_shares = vec![Share {
            project: "Atlas".into(),
            seconds: 3600.0,
        }];
        let other = session("work-2", "Safari", at(10, 0), at(10, 30));
        let by_project = DayList::new(&[project.clone(), other.clone()], &[], &[], at(12, 0), true);
        let keys: Vec<Option<String>> = by_project.rows().map(|r| r.color_key.clone()).collect();
        assert_eq!(keys, vec![Some("Atlas".into()), None]);
        let by_app = DayList::new(&[other], &[], &[], at(12, 0), false);
        assert_eq!(
            by_app.rows().next().unwrap().color_key,
            Some("Safari".into())
        );
    }

    #[test]
    fn apps_glanced_at_for_seconds_are_left_out() {
        let block = |id: i64, app: &str, start: DateTime<Utc>, end: DateTime<Utc>| ActivityBlock {
            id,
            app: app.into(),
            title: String::new(),
            start,
            end,
        };
        let mut s = session("work-1", "Xcode", at(9, 0), at(10, 0));
        s.apps = vec!["Xcode".into(), "1Password".into()];
        s.block_ids = vec![1, 2];
        let blocks = [
            block(1, "Xcode", at(9, 0), at(10, 0)),
            block(2, "1Password", at(9, 10), at(9, 10) + Duration::seconds(8)),
        ];
        assert_eq!(used_apps(&s, &blocks), vec!["Xcode".to_string()]);
        assert_eq!(used_apps(&s, &blocks[1..]), s.apps);
    }

    #[test]
    fn arrow_keys_walk_the_page_the_rows_and_all_captured_activity() {
        let sessions = [
            session("work-1", "Xcode", at(9, 0), at(10, 0)),
            session("work-2", "Mail", at(10, 0), at(10, 30)),
        ];
        let list = DayList::new(&sessions, &[], &[], at(12, 0), false);
        let digest = ListSelection::Digest;
        assert_eq!(digest.moved(-1, &list), ListSelection::Digest);
        assert_eq!(digest.moved(1, &list), ListSelection::Row("work-1".into()));
        let last = ListSelection::Row("work-2".into());
        assert_eq!(last.moved(1, &list), ListSelection::Raw);
        assert_eq!(ListSelection::Raw.moved(1, &list), ListSelection::Raw);
        assert_eq!(
            ListSelection::Raw.moved(-1, &list),
            ListSelection::Row("work-2".into())
        );
        assert_eq!(ListSelection::None.moved(1, &list), ListSelection::Digest);
        // A day without sessions goes from its page to all captured activity.
        let empty = DayList::default();
        assert_eq!(digest.moved(1, &empty), ListSelection::Raw);
    }

    #[test]
    fn the_strip_runs_over_whole_hours_inside_the_day() {
        let sessions = [session("work-1", "Xcode", at(9, 10), at(10, 30))];
        let standup = meeting("Standup", "Zoom", at(11, 0), at(11, 20));
        let list = DayList::new(
            &sessions,
            &[],
            std::slice::from_ref(&standup),
            at(12, 0),
            false,
        );
        let (start, end) =
            lokalbot_core::time::local_day_bounds(at(9, 0).with_timezone(&Local).date_naive());
        let strip = DayStrip::new(list.rows(), start, end).unwrap();
        // 9:00 to 12:00: three hours.
        assert_eq!(strip.ticks.len(), 3);
        assert_eq!(strip.ticks[0].at, at(9, 0));
        assert!(strip.ticks[0].names_day_period);
        assert!(!strip.ticks[1].names_day_period);
        assert_eq!(strip.work.len(), 1);
        assert_eq!(strip.meetings.len(), 1);
        let bar = &strip.work[0];
        assert!((bar.start - 10.0 / 180.0).abs() < 1e-9);
        assert!((bar.end - 90.0 / 180.0).abs() < 1e-9);
        assert!((strip.meetings[0].start - 120.0 / 180.0).abs() < 1e-9);
        // An end on the hour adds no hour.
        let on_hour = [session("work-1", "Xcode", at(9, 0), at(11, 0))];
        let list = DayList::new(&on_hour, &[], &[], at(12, 0), false);
        assert_eq!(
            DayStrip::new(list.rows(), start, end).unwrap().ticks.len(),
            2
        );
        assert!(DayStrip::new(DayList::default().rows(), start, end).is_none());
    }

    #[test]
    fn noon_names_its_day_period_and_long_days_label_every_few_hours() {
        let sessions = [session("work-1", "Xcode", at(8, 0), at(19, 30))];
        let list = DayList::new(&sessions, &[], &[], at(20, 0), false);
        let (start, end) =
            lokalbot_core::time::local_day_bounds(at(9, 0).with_timezone(&Local).date_naive());
        let strip = DayStrip::new(list.rows(), start, end).unwrap();
        assert_eq!(strip.ticks.len(), 12);
        let named: Vec<usize> = strip
            .ticks
            .iter()
            .enumerate()
            .filter(|(_, t)| t.names_day_period)
            .map(|(i, _)| i)
            .collect();
        assert_eq!(named, vec![0, 4]);
        let labelled = strip.labelled_ticks(5);
        assert_eq!(labelled.len(), 4);
        assert_eq!(labelled[0].at, at(8, 0));
        assert_eq!(labelled[1].at, at(11, 0));
        assert_eq!(strip.labelled_ticks(20).len(), 12);
        assert!(strip.labelled_ticks(0).is_empty());
    }

    #[test]
    fn thin_bars_stay_visible_and_answer_clicks_around_them() {
        let bar = |start: f64, end: f64| Bar {
            id: "b".into(),
            start,
            end,
            color_key: None,
        };
        assert_eq!(bar_frame(&bar(0.5, 0.5), 200.0, 3.0), (100.0, 3.0));
        // At the trailing edge the bar stays inside the lane.
        assert_eq!(bar_frame(&bar(1.0, 1.0), 200.0, 3.0), (197.0, 3.0));
        assert_eq!(bar_hit_frame(&bar(0.5, 0.5), 200.0), (95.5, 12.0));
        assert_eq!(bar_hit_frame(&bar(0.0, 0.01), 200.0), (0.0, 12.0));
        assert_eq!(bar_hit_frame(&bar(0.25, 0.75), 200.0), (50.0, 100.0));
        let bars = [bar(0.0, 0.1), bar(0.1, 0.6), bar(0.6, 0.65)];
        let order: Vec<f64> = hit_order(&bars).iter().map(|b| b.start).collect();
        assert_eq!(order, vec![0.1, 0.0, 0.6]);
    }

    #[test]
    fn the_rail_opens_between_its_two_widths_and_leaves_the_page_its_minimum() {
        // The default window's body, a roomy one, and one in between.
        assert_eq!(rail_width(964.0, 1.0), 300.0);
        assert_eq!(rail_width(1224.0, 1.0), 352.0);
        assert_eq!(rail_width(1100.0, 1.0), 330.0);
        // Larger text asks for more, as far as the page's minimum allows.
        assert_eq!(rail_width(1600.0, 1.35), 475.0);
        assert_eq!(rail_width(964.0, 1.35), 405.0);
        assert_eq!(rail_width(800.0, 1.35), 379.0);
        // The narrowest body still gets the floor.
        assert_eq!(rail_width(681.0, 1.0), RAIL_FLOOR_WIDTH);
        assert!(RAIL_MAXIMUM_WIDTH > rail_width(1224.0, 1.0));
        // The widest rail fits beside the page in the default window.
        const { assert!(964.0 - DIVIDER_WIDTH - RAIL_MAXIMUM_WIDTH >= PAGE_MINIMUM_WIDTH) };
    }

    #[test]
    fn the_days_actions_list_open_work_first_and_count_it() {
        use crate::test_support::{reference, thread};
        let open_on_day = thread(vec![reference("a", ActionStatus::Open, true, None, 12)]);
        let done_on_day = thread(vec![reference("b", ActionStatus::Done, true, None, 12)]);
        let deferred = thread(vec![reference("c", ActionStatus::Deferred, true, None, 12)]);
        let others = thread(vec![reference("d", ActionStatus::Open, false, None, 12)]);
        let other_day = thread(vec![reference("e", ActionStatus::Open, true, None, 13)]);
        let day = lokalbot_core::time::local_day(open_on_day.references[0].meeting_started_at);
        let threads = day_threads(
            vec![
                done_on_day.clone(),
                open_on_day.clone(),
                others,
                other_day,
                deferred.clone(),
            ],
            day,
        );
        let texts: Vec<&str> = threads.iter().map(|t| t.text.as_str()).collect();
        assert_eq!(texts, vec!["Do a", "Do b", "Do c"]);

        let summary = actions_summary(&threads).unwrap();
        assert_eq!(summary, ActionsSummary::Open(1));
        assert_eq!(actions_pill(summary), ActionsPill::Open(1));
        assert!(actions_show_rows(summary, false));

        let all_done = actions_summary(std::slice::from_ref(&done_on_day)).unwrap();
        assert_eq!(actions_pill(all_done), ActionsPill::AllDone);
        // Done: only the header, unless the rows were just showing.
        assert!(!actions_show_rows(all_done, false));
        assert!(actions_show_rows(all_done, true));

        let none_open = actions_summary(&[done_on_day, deferred]).unwrap();
        assert_eq!(actions_pill(none_open), ActionsPill::Open(0));
        assert!(actions_summary(&[]).is_none());
    }

    #[test]
    fn the_digest_line_and_menu_name_what_happens_next() {
        let written = Some(at(18, 0));
        assert_eq!(
            DigestLine::state(true, written, true, true),
            DigestLine::Writing
        );
        assert_eq!(
            DigestLine::state(false, None, false, false),
            DigestLine::Missing
        );
        assert_eq!(
            DigestLine::state(true, written, true, false),
            DigestLine::Stale(written)
        );
        assert!(DigestLine::Current(written).shows_footer(true));
        assert!(!DigestLine::Current(None).shows_footer(true));
        assert!(!DigestLine::Missing.shows_footer(false));
        // The first digest being written has no footer: the body says so.
        assert!(!DigestLine::Writing.shows_footer(false));
        assert!(DigestLine::Writing.shows_footer(true));

        assert_eq!(digest_menu_title(true, true, true), "Writing digest…");
        assert_eq!(digest_menu_title(false, false, false), "Write digest");
        assert_eq!(digest_menu_title(false, true, true), "Update digest");
        assert_eq!(digest_menu_title(false, true, false), "Rewrite digest");
    }

    #[test]
    fn older_digests_open_the_session_their_time_range_covers() {
        let sessions = [
            session("work-1", "Xcode", at(9, 0), at(10, 30)),
            session("work-2", "Mail", at(10, 30), at(11, 0)),
        ];
        let list = DayList::new(&sessions, &[], &[], at(12, 0), false);
        let day = at(9, 0).with_timezone(&Local).date_naive();
        assert_eq!(
            list.work_row_in_time_range("09:00–10:30", day).unwrap().id,
            "work-1"
        );
        assert_eq!(
            list.work_row_in_time_range("10:40-11:00", day).unwrap().id,
            "work-2"
        );
        assert!(list.work_row_in_time_range("14:00–15:00", day).is_none());
        assert!(list.work_row_in_time_range("Fixture", day).is_none());
        assert!(interval_from_time_range("25:00–26:00", day).is_none());
    }

    #[test]
    fn catalog_fields_fill_in_order_or_by_number() {
        assert_eq!(fill("%lld open", &["2"]), "2 open");
        assert_eq!(fill("Away %@", &["1h 5m"]), "Away 1h 5m");
        assert_eq!(fill("%2$@ · %1$@", &["a", "b"]), "b · a");
        assert_eq!(fill("100% %@", &["done"]), "100% done");
        assert_eq!(fill("no fields", &["x"]), "no fields");
    }
}
