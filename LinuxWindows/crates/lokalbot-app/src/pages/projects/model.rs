//! The Projects list and a project's page as plain data
//! (`ProjectsListPresentation.swift`): tracked projects by last activity,
//! then suggestions with where each came from; which tracked project a
//! suggestion probably belongs to; the side column's week of window time;
//! and the wording put together from counts, dates and names. Kept apart
//! from drawing so it can be tested.

use std::collections::HashSet;

use chrono::{DateTime, Local, NaiveDate, Utc};
use lokalbot_core::{ActionThread, ProjectCuration, ProjectKind, ProjectProfile, ProjectSummary};
use uuid::Uuid;

use crate::pages::people::model::{day, directional, fill, short_date};

/// A project nothing has named for this many days reads "Quiet since…";
/// the same two weeks after which other people's open work stops counting
/// as recent.
pub(super) const QUIET_AFTER_DAYS: i64 = lokalbot_core::projects::RECENT_OTHERS_ACTION_DAYS;
/// Other people's actions shown before "Show N more".
pub(super) const VISIBLE_OTHERS_ACTIONS: usize = 3;
/// Meetings shown before "Show all N".
pub(super) const VISIBLE_MEETINGS: usize = 4;
/// Windows listed before "N more windows".
pub(super) const VISIBLE_WINDOWS: usize = 3;
/// Time under a minute is not shown, as on Timeline.
pub(super) const MINIMUM_SECONDS: f64 = 60.;
/// The days of window time the side column shows.
pub(super) const REVIEW_DAYS: i64 = lokalbot_core::projects::REVIEW_DAYS;
/// Names that come up in this many meetings are suggested.
pub(super) const MINIMUM_MEETINGS: usize = lokalbot_core::projects::MINIMUM_TOPIC_MEETINGS;
/// Below this width the toolbar's Ask button shows its icon alone.
pub(super) const COMPACT_TOOLBAR_WIDTH: f32 = 720.;

/// `tracked:<UUID>`, the selection and note id of a tracked project.
pub(super) fn selection_id(id: Uuid) -> String {
    format!("tracked:{}", lokalbot_core::ids::uuid_upper(&id))
}

fn local(date: DateTime<Utc>) -> DateTime<Local> {
    date.with_timezone(&Local)
}

fn formatted(date: DateTime<Utc>, pattern: &str) -> String {
    local(date)
        .format_localized(
            lokalbot_i18n::date_pattern(pattern),
            lokalbot_i18n::date_locale(),
        )
        .to_string()
}

/// The start of a local day, for wording that takes an instant.
fn day_start(date: NaiveDate) -> DateTime<Utc> {
    lokalbot_core::time::local_day_bounds(date).0
}

// ------------------------------------------------------------------ list

/// How recently anything named a project: its newest meeting, overnight
/// review note, or day with window time.
#[derive(Clone, Copy, Debug, PartialEq)]
pub(super) enum Activity {
    NothingLinked,
    Today,
    Yesterday,
    /// Within the last `QUIET_AFTER_DAYS` days.
    Recent(DateTime<Utc>),
    Quiet(DateTime<Utc>),
}

impl Activity {
    pub fn is_quiet(self) -> bool {
        matches!(self, Activity::Quiet(_))
    }
}

pub(super) fn activity(last_active: Option<DateTime<Utc>>, now: DateTime<Utc>) -> Activity {
    let Some(last) = last_active else {
        return Activity::NothingLinked;
    };
    let days = (local(now).date_naive() - local(last).date_naive()).num_days();
    match days {
        ..=0 => Activity::Today,
        1 => Activity::Yesterday,
        days if days < QUIET_AFTER_DAYS => Activity::Recent(last),
        _ => Activity::Quiet(last),
    }
}

/// "Active today", "Active yesterday", "Last active Fri, Nov 6", "Quiet
/// since Oct 22", or that nothing is linked yet.
pub(super) fn activity_line(activity: Activity, now: DateTime<Utc>) -> String {
    match activity {
        Activity::NothingLinked => lokalbot_i18n::tr("Nothing linked yet").to_string(),
        Activity::Today => lokalbot_i18n::tr("Active today").to_string(),
        Activity::Yesterday => lokalbot_i18n::tr("Active yesterday").to_string(),
        Activity::Recent(date) => fill(lokalbot_i18n::tr("Last active %@"), &[&day(date, now)]),
        Activity::Quiet(date) => fill(
            lokalbot_i18n::tr("Quiet since %@"),
            &[&short_date(date, now)],
        ),
    }
}

/// One project in the list (`ProjectsListContent.Row`).
#[derive(Clone, Debug, PartialEq)]
pub(super) struct Row {
    /// The project's id, which is also the list's selection.
    pub id: String,
    pub name: String,
    /// "Active today", "Quiet since Oct 22", "In 4 meetings"…
    pub detail: String,
    pub is_suggestion: bool,
    /// Drawn a little fainter: nothing has named the project for weeks.
    pub is_quiet: bool,
    /// The user's own open actions on the project.
    pub open_actions: usize,
}

/// The list as it is drawn: tracked projects by last activity, then
/// suggestions in the order they are offered.
#[derive(Clone, Debug, Default, PartialEq)]
pub(super) struct ListContent {
    pub tracked: Vec<Row>,
    pub suggested: Vec<Row>,
}

impl ListContent {
    /// `query` matches a project's name or any of its other names. A
    /// suggestion hidden a moment ago leaves before the next refresh.
    pub fn build(
        projects: &[&ProjectProfile],
        hidden: &[String],
        query: &str,
        now: DateTime<Utc>,
    ) -> Self {
        let needle = query.trim().to_lowercase();
        let matching: Vec<&ProjectProfile> = projects
            .iter()
            .copied()
            .filter(|project| {
                needle.is_empty()
                    || std::iter::once(&project.name)
                        .chain(&project.other_names)
                        .any(|name| name.to_lowercase().contains(&needle))
            })
            .collect();
        // Most recently active first; a project nothing names yet goes last.
        let mut tracked: Vec<&ProjectProfile> = matching
            .iter()
            .copied()
            .filter(|p| p.is_tracked())
            .collect();
        tracked.sort_by(|left, right| {
            right
                .last_active
                .cmp(&left.last_active)
                .then_with(|| left.name.to_lowercase().cmp(&right.name.to_lowercase()))
        });
        // Suggestions keep the order they are offered in: names from
        // meetings by how many meetings, then the overnight review's.
        let suggested = matching.iter().copied().filter(|p| {
            !p.is_tracked() && !hidden.contains(&lokalbot_core::people::normalized(&p.name))
        });
        ListContent {
            tracked: tracked
                .into_iter()
                .map(|project| {
                    let activity = activity(project.last_active, now);
                    Row {
                        id: project.id.clone(),
                        name: project.name.clone(),
                        detail: activity_line(activity, now),
                        is_suggestion: false,
                        is_quiet: activity.is_quiet(),
                        open_actions: project.my_actions.len(),
                    }
                })
                .collect(),
            suggested: suggested
                .map(|project| Row {
                    id: project.id.clone(),
                    name: project.name.clone(),
                    detail: suggestion_source(project),
                    is_suggestion: true,
                    is_quiet: false,
                    open_actions: 0,
                })
                .collect(),
        }
    }

    /// Every row's project id, in the order shown.
    pub fn project_ids(&self) -> impl Iterator<Item = &str> {
        self.tracked
            .iter()
            .chain(&self.suggested)
            .map(|row| row.id.as_str())
    }

    pub fn is_empty(&self) -> bool {
        self.tracked.is_empty() && self.suggested.is_empty()
    }

    /// What opens once a suggestion leaves the list: the suggestion after
    /// it, else the first one left. None when it was the last suggestion,
    /// and then the page opens the first tracked project.
    pub fn selection_after_removing(&self, id: &str) -> Option<String> {
        let Some(index) = self.suggested.iter().position(|row| row.id == id) else {
            return self.suggested.first().map(|row| row.id.clone());
        };
        self.suggested[index + 1..]
            .iter()
            .chain(&self.suggested[..index])
            .next()
            .map(|row| row.id.clone())
    }

    /// The row's position among the list's children: a heading leads each
    /// group that has rows.
    pub fn child_index(&self, id: &str) -> Option<usize> {
        let mut index = 0;
        for group in [&self.tracked, &self.suggested] {
            if group.is_empty() {
                continue;
            }
            index += 1;
            if let Some(position) = group.iter().position(|row| row.id == id) {
                return Some(index + position);
            }
            index += group.len();
        }
        None
    }
}

/// Where a suggestion came from: "In 4 meetings" for a name that recurs
/// across meetings, "From overnight review" for work the review named.
pub(super) fn suggestion_source(project: &ProjectProfile) -> String {
    if project.kind == ProjectKind::SuggestedReview {
        return lokalbot_i18n::tr("From overnight review").to_string();
    }
    let count = project.meetings.len();
    directional(fill(
        lokalbot_i18n::tr(if count == 1 {
            "In %lld meeting"
        } else {
            "In %lld meetings"
        }),
        &[&lokalbot_i18n::number(count)],
    ))
}

/// Beside the project's name in the toolbar: its last activity, "Tracked
/// since Nov 1" while nothing names it, or "Suggested".
pub(super) fn subtitle(
    project: &ProjectProfile,
    tracked_since: Option<DateTime<Utc>>,
    now: DateTime<Utc>,
) -> String {
    // Its own key: beside one project the word is singular, and the list's
    // "Suggested" heading is not in every language.
    if !project.is_tracked() {
        return lokalbot_i18n::tr("Suggested (one project)").to_string();
    }
    let activity = activity(project.last_active, now);
    if activity == Activity::NothingLinked
        && let Some(since) = tracked_since
    {
        return fill(
            lokalbot_i18n::tr("Tracked since %@"),
            &[&short_date(since, now)],
        );
    }
    activity_line(activity, now)
}

/// "2 open actions for you", on hover over the number on a row.
pub(super) fn open_actions(count: usize) -> String {
    directional(fill(
        lokalbot_i18n::tr(if count == 1 {
            "%lld open action for you"
        } else {
            "%lld open actions for you"
        }),
        &[&lokalbot_i18n::number(count)],
    ))
}

/// "Show 2 hidden suggestions".
pub(super) fn show_hidden(count: usize) -> String {
    directional(fill(
        lokalbot_i18n::tr(if count == 1 {
            "Show %lld hidden suggestion"
        } else {
            "Show %lld hidden suggestions"
        }),
        &[&lokalbot_i18n::number(count)],
    ))
}

// ------------------------------------------------------------ selection

/// The tracked project a suggestion probably belongs to
/// (`ProjectSuggestionHome.Match`).
#[derive(Clone, Debug, PartialEq)]
pub(super) struct Home {
    pub tracked_id: Uuid,
    pub name: String,
    /// How many of the suggestion's meetings the project already has.
    pub shared_meetings: usize,
}

fn meeting_ids(project: &ProjectProfile) -> HashSet<Uuid> {
    project.meetings.iter().map(|m| m.id).collect()
}

/// How many of the suggestion's meetings the project already has, when that
/// is at least half of them; None otherwise, and for a suggestion no
/// meeting names.
pub(super) fn shared_meetings(
    suggestion: &HashSet<Uuid>,
    project: &HashSet<Uuid>,
) -> Option<usize> {
    if suggestion.is_empty() {
        return None;
    }
    let shared = suggestion.intersection(project).count();
    (shared > 0 && shared * 2 >= suggestion.len()).then_some(shared)
}

/// The tracked project that already has at least half of the suggestion's
/// meetings: the one sharing the most when several do, the first in the
/// list on a tie. Deterministic; no model decides.
pub(super) fn suggestion_home(
    suggestion: &ProjectProfile,
    projects: &[&ProjectProfile],
) -> Option<Home> {
    if suggestion.is_tracked() {
        return None;
    }
    let meetings = meeting_ids(suggestion);
    let mut best: Option<Home> = None;
    for project in projects {
        let Some(tracked_id) = project.tracked_id() else {
            continue;
        };
        let Some(shared) = shared_meetings(&meetings, &meeting_ids(project)) else {
            continue;
        };
        if shared > best.as_ref().map_or(0, |b| b.shared_meetings) {
            best = Some(Home {
                tracked_id,
                name: project.name.clone(),
                shared_meetings: shared,
            });
        }
    }
    best
}

/// A suggestion that was just tracked stays on screen, already as tracked,
/// until the next load delivers its tracked profile
/// (`ProjectsWorkspaceView.settlingProfile`). Nothing is written from this
/// copy: its evidence is about to be replaced.
pub(super) fn settling_profile(
    selection: Option<&str>,
    curation: &ProjectCuration,
    projects: &[ProjectProfile],
) -> Option<ProjectProfile> {
    let selection = selection?;
    if projects.iter().any(|p| p.id == selection) {
        return None;
    }
    let tracked = curation
        .tracked
        .iter()
        .find(|t| selection_id(t.id) == selection)?;
    let key = lokalbot_core::people::normalized(&tracked.name);
    let suggestion = projects
        .iter()
        .find(|p| !p.is_tracked() && lokalbot_core::people::normalized(&p.name) == key)?;
    let mut settled = suggestion.clone();
    settled.id = selection.to_string();
    settled.kind = ProjectKind::Tracked;
    Some(settled)
}

/// The projects the list and the page draw: while a just-tracked suggestion
/// settles, its tracked copy stands in for the suggestion, so the row moves
/// under Tracked at once and stays selected.
pub(super) fn list_projects<'a>(
    projects: &'a [ProjectProfile],
    settling: Option<&'a ProjectProfile>,
) -> Vec<&'a ProjectProfile> {
    let Some(settling) = settling else {
        return projects.iter().collect();
    };
    let key = lokalbot_core::people::normalized(&settling.name);
    std::iter::once(settling)
        .chain(
            projects
                .iter()
                .filter(|p| p.is_tracked() || lokalbot_core::people::normalized(&p.name) != key),
        )
        .collect()
}

// ------------------------------------------------------------------ page

/// Nothing names the project yet: no meeting, action, decision, overnight
/// review note, person, or window time.
pub(super) fn is_empty(project: &ProjectProfile) -> bool {
    project.meetings.is_empty()
        && project.my_actions.is_empty()
        && project.others_actions.is_empty()
        && project.older_others_actions.is_empty()
        && project.decisions.is_empty()
        && project.review_notes.is_empty()
        && project.people.is_empty()
        && project.week_seconds < MINIMUM_SECONDS
}

/// Other people's open work in one list: what was mentioned recently or is
/// due ahead first, then the older work.
pub(super) fn others_actions(project: &ProjectProfile) -> Vec<&ActionThread> {
    project
        .others_actions
        .iter()
        .chain(&project.older_others_actions)
        .collect()
}

/// "Show all 12" or "Show fewer" under the meetings.
pub(super) fn show_all(expanded: bool, total: usize) -> String {
    if expanded {
        lokalbot_i18n::tr("Show fewer").to_string()
    } else {
        directional(fill(
            lokalbot_i18n::tr("Show all %lld"),
            &[&lokalbot_i18n::number(total)],
        ))
    }
}

// ------------------------------------------------------------------ time

/// One bar of the side column's week.
#[derive(Clone, Debug, PartialEq)]
pub(super) struct Day {
    pub date: NaiveDate,
    /// Zero for a day with no window time that names the project.
    pub seconds: f64,
    pub is_today: bool,
}

/// The days the window time covers, oldest first and ending today, with
/// zero for a day without time (`ProjectTimePresentation.days`).
pub(super) fn days(times: &[(String, f64)], today: NaiveDate) -> Vec<Day> {
    (0..REVIEW_DAYS)
        .rev()
        .map(|offset| {
            let date = today - chrono::Duration::days(offset);
            let key = date.format("%Y-%m-%d").to_string();
            let seconds = times
                .iter()
                .filter(|(day, _)| *day == key)
                .map(|(_, seconds)| seconds)
                .sum();
            Day {
                date,
                seconds,
                is_today: offset == 0,
            }
        })
        .collect()
}

/// How tall a day's bar is, from 0 to 1 of the tallest day.
pub(super) fn fraction(day: &Day, days: &[Day]) -> f32 {
    let top = days.iter().map(|d| d.seconds).fold(0., f64::max);
    if top > 0. {
        (day.seconds / top) as f32
    } else {
        0.
    }
}

/// The windows behind "N more windows" and their time together. The
/// project counts every window; it lists only the longest.
pub(super) fn rest(project: &ProjectProfile) -> Option<(usize, f64)> {
    let shown: Vec<_> = project.windows.iter().take(VISIBLE_WINDOWS).collect();
    let count = project.window_count.max(project.windows.len()) - shown.len();
    let seconds = project.week_seconds - shown.iter().map(|w| w.seconds).sum::<f64>();
    (count > 0 && seconds >= MINIMUM_SECONDS).then_some((count, seconds))
}

/// "40h 10m", "35m"; under a minute still reads as one.
pub(super) fn duration(seconds: f64) -> String {
    directional(crate::ui::profile::duration(seconds))
}

/// "3 more windows".
pub(super) fn more_windows(count: usize) -> String {
    directional(fill(
        lokalbot_i18n::tr(if count == 1 {
            "%lld more window"
        } else {
            "%lld more windows"
        }),
        &[&lokalbot_i18n::number(count)],
    ))
}

/// "Wed, Nov 4: 8h 20m", on hover over a day's bar; a day without time says
/// so with a zero.
pub(super) fn day_time(day: &Day) -> String {
    let time = if day.seconds >= MINIMUM_SECONDS {
        crate::ui::profile::duration(day.seconds)
    } else {
        lokalbot_i18n::format("{minutes}m", &[("minutes", lokalbot_i18n::number(0))])
    };
    format!("{}: {time}", formatted(day_start(day.date), "%a, %b %-d"))
}

/// The one-letter weekday under a day's bar.
pub(super) fn weekday_letter(date: NaiveDate) -> String {
    formatted(day_start(date), "%a")
        .chars()
        .next()
        .map(|c| c.to_uppercase().collect())
        .unwrap_or_default()
}

/// The names a project is matched by, for "Time in windows whose titles name
/// Atlas, Larkspur".
pub(super) fn time_source(project: &ProjectProfile) -> String {
    let names: Vec<&str> = std::iter::once(project.name.as_str())
        .chain(project.other_names.iter().map(String::as_str))
        .collect();
    fill(
        lokalbot_i18n::tr("Time in windows whose titles name %@"),
        &[&names.join(", ")],
    )
}

// ---------------------------------------------------------------- notes

/// Whether a note was written on this computer: the port saves "on this
/// PC", and an empty location is never a server.
fn written_here(location: &str) -> bool {
    let place = location.trim();
    let place = place.strip_prefix("on ").unwrap_or(place).trim();
    place.is_empty() || place.eq_ignore_ascii_case("this PC")
}

/// When "Where it stands" was written, by which model, and where it ran:
/// "Written today, 9:12 AM, by Qwen3.5 4B on this PC", or with the server's
/// host for a model that ran elsewhere.
pub(super) fn provenance(summary: &ProjectSummary, now: DateTime<Utc>) -> String {
    let is_today = local(summary.generated_at).date_naive() == local(now).date_naive();
    let when = if is_today {
        lokalbot_core::time::clock_time(summary.generated_at)
    } else {
        short_date(summary.generated_at, now)
    };
    let model = if summary.engine_name.trim().is_empty() {
        lokalbot_i18n::tr("the Think model").to_string()
    } else {
        summary.engine_name.trim().to_string()
    };
    if written_here(&summary.location) {
        return if is_today {
            lokalbot_i18n::format(
                "Written today, {time}, by {model} on this PC",
                &[("time", when), ("model", model)],
            )
        } else {
            lokalbot_i18n::format(
                "Written {date} by {model} on this PC",
                &[("date", when), ("model", model)],
            )
        };
    }
    let location = summary.location.trim();
    let host = location.strip_prefix("on ").unwrap_or(location).trim();
    fill(
        lokalbot_i18n::tr(if is_today {
            "Written today, %1$@, by %2$@ on %3$@"
        } else {
            "Written %1$@ by %2$@ on %3$@"
        }),
        &[&when, &model, host],
    )
}

/// "Writing where it stands from 4 meetings…", naming what the model is
/// given.
pub(super) fn writing(meetings: usize, has_review_notes: bool) -> String {
    if meetings == 0 {
        return lokalbot_i18n::tr("Writing where it stands from the overnight review…").to_string();
    }
    let key = match (meetings == 1, has_review_notes) {
        (true, false) => lokalbot_i18n::tr("Writing where it stands from %lld meeting…"),
        (false, false) => lokalbot_i18n::tr("Writing where it stands from %lld meetings…"),
        (true, true) => {
            lokalbot_i18n::tr("Writing where it stands from %lld meeting and the overnight review…")
        }
        (false, true) => lokalbot_i18n::tr(
            "Writing where it stands from %lld meetings and the overnight review…",
        ),
    };
    directional(fill(key, &[&lokalbot_i18n::number(meetings)]))
}

/// A point's meeting as its link reads: "Design review meeting · Nov 10",
/// or the title alone when the note kept no date.
pub(super) fn point_citation(title: &str, day_key: Option<&str>, now: DateTime<Utc>) -> String {
    match day_key.and_then(|key| NaiveDate::parse_from_str(key, "%Y-%m-%d").ok()) {
        Some(date) => format!("{title} · {}", short_date(day_start(date), now)),
        None => title.to_string(),
    }
}

/// "Overnight review · Nov 9" under the review's own words.
pub(super) fn review_citation(day_key: &str, now: DateTime<Utc>) -> String {
    let label = lokalbot_i18n::tr("Overnight review");
    match NaiveDate::parse_from_str(day_key, "%Y-%m-%d") {
        Ok(date) => format!("{label} · {}", short_date(day_start(date), now)),
        Err(_) => label.to_string(),
    }
}

// ----------------------------------------------------------- suggestions

/// The heading of a suggestion's decision: "Redis came up in 4 meetings
/// since Oct 29", or that the overnight review found the work.
pub(super) fn suggestion_title(project: &ProjectProfile, now: DateTime<Utc>) -> String {
    if project.kind == ProjectKind::SuggestedReview {
        return fill(
            lokalbot_i18n::tr("The overnight review found work on %@"),
            &[&project.name],
        );
    }
    let Some(first) = project.meetings.iter().map(|m| m.started_at).min() else {
        return project.name.clone();
    };
    let count = project.meetings.len();
    fill(
        lokalbot_i18n::tr(if count == 1 {
            "%1$@ came up in %2$lld meeting since %3$@"
        } else {
            "%1$@ came up in %2$lld meetings since %3$@"
        }),
        &[
            &project.name,
            &lokalbot_i18n::number(count),
            &short_date(first, now),
        ],
    )
}

/// Why the first answer is the one offered: the tracked project that
/// already has most of the suggestion's meetings, or that none covers it.
pub(super) fn suggestion_reason(home: Option<&Home>) -> String {
    let Some(home) = home else {
        return lokalbot_i18n::tr("No tracked project covers it.").to_string();
    };
    directional(fill(
        lokalbot_i18n::tr(if home.shared_meetings == 1 {
            "%1$lld of its meetings is already linked to %2$@, so it may be part of that project rather than a project of its own."
        } else {
            "%1$lld of its meetings are already linked to %2$@, so it may be part of that project rather than a project of its own."
        }),
        &[&lokalbot_i18n::number(home.shared_meetings), &home.name],
    ))
}

// ------------------------------------------------------------ the card

/// Whether the note's provenance fits beside "Where it stands" and its
/// button (`ViewThatFits`); otherwise it goes under the title. GPUI cannot
/// measure a line before laying it out, so this estimates the widths from
/// the text: half an em a character, a full em for wide (CJK) ones.
pub(super) fn provenance_fits_beside(
    card_width: f32,
    title: &str,
    provenance: &str,
    control: &str,
    text_scale: f32,
) -> bool {
    let scale = text_scale.max(0.5);
    let width = |text: &str, size: f32| -> f32 {
        text.chars()
            .map(|c| if is_wide(c) { size } else { size * 0.55 })
            .sum::<f32>()
            * scale
    };
    // Sparkle and gaps, the button's padding, the card's own padding.
    let title_width = width(title, 14.) + 22. * scale;
    let control_width = if control.is_empty() {
        0.
    } else {
        width(control, 12.) + 24. * scale
    };
    let needed = title_width + 12. + width(provenance, 13.) + 8. + control_width;
    needed <= card_width - 36.
}

fn is_wide(c: char) -> bool {
    matches!(c as u32,
        0x1100..=0x115F | 0x2E80..=0xA4CF | 0xAC00..=0xD7A3 | 0xF900..=0xFAFF | 0xFE30..=0xFE4F | 0xFF00..=0xFF60 | 0xFFE0..=0xFFE6)
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::{Duration, TimeZone as _};
    use lokalbot_core::{MeetingRef, ProjectWindowTime, TrackedProject};

    /// A Tuesday at noon, local time, so day words do not depend on the
    /// machine's time zone.
    fn now() -> DateTime<Utc> {
        Local
            .with_ymd_and_hms(2026, 11, 10, 12, 0, 0)
            .unwrap()
            .with_timezone(&Utc)
    }

    fn meeting(id: u128, days_ago: i64) -> MeetingRef {
        MeetingRef {
            id: Uuid::from_u128(id),
            title: format!("Meeting {id}"),
            started_at: now() - Duration::days(days_ago),
            ended_at: None,
            calendar_event_id: None,
            participant_count: 0,
        }
    }

    fn project(id: &str, name: &str, kind: ProjectKind) -> ProjectProfile {
        ProjectProfile {
            id: id.into(),
            kind,
            name: name.into(),
            other_names: Vec::new(),
            meetings: Vec::new(),
            mentions: Vec::new(),
            my_actions: Vec::new(),
            others_actions: Vec::new(),
            older_others_actions: Vec::new(),
            decisions: Vec::new(),
            people: Vec::new(),
            week_seconds: 0.,
            days: Vec::new(),
            windows: Vec::new(),
            window_count: 0,
            last_active: None,
            summary: None,
            review_notes: Vec::new(),
        }
    }

    fn tracked(id: u128, name: &str, last_active_days_ago: Option<i64>) -> ProjectProfile {
        let mut p = project(
            &selection_id(Uuid::from_u128(id)),
            name,
            ProjectKind::Tracked,
        );
        p.last_active = last_active_days_ago.map(|d| now() - Duration::days(d));
        p
    }

    #[test]
    fn activity_reads_today_yesterday_recent_then_quiet() {
        let at = |days: i64| Some(now() - Duration::days(days));
        assert_eq!(activity(None, now()), Activity::NothingLinked);
        assert_eq!(activity(at(0), now()), Activity::Today);
        assert_eq!(activity(at(1), now()), Activity::Yesterday);
        assert!(matches!(activity(at(13), now()), Activity::Recent(_)));
        assert!(activity(at(14), now()).is_quiet());
        assert_eq!(activity_line(Activity::Today, now()), "Active today");
        assert_eq!(
            activity_line(activity(at(4), now()), now()),
            "Last active Fri, Nov 6"
        );
        assert_eq!(
            activity_line(activity(at(19), now()), now()),
            "Quiet since Oct 22"
        );
        assert_eq!(
            activity_line(Activity::NothingLinked, now()),
            "Nothing linked yet"
        );
    }

    #[test]
    fn the_list_puts_tracked_projects_by_last_activity_then_suggestions_as_offered() {
        let atlas = tracked(1, "Atlas", Some(0));
        let borealis = tracked(2, "Borealis", Some(19));
        let empty = tracked(3, "Comet", None);
        let mut redis = project("topic:redis", "Redis", ProjectKind::Suggested);
        redis.meetings = vec![
            meeting(10, 1),
            meeting(11, 2),
            meeting(12, 3),
            meeting(13, 4),
        ];
        let index = project(
            "review:index rebuild",
            "Index rebuild",
            ProjectKind::SuggestedReview,
        );
        let hidden = project("topic:weekly", "Weekly", ProjectKind::Suggested);
        let all = [&empty, &redis, &borealis, &index, &atlas, &hidden];
        let content = ListContent::build(&all, &["weekly".to_string()], "", now());
        let names: Vec<&str> = content.tracked.iter().map(|r| r.name.as_str()).collect();
        assert_eq!(names, ["Atlas", "Borealis", "Comet"]);
        assert_eq!(content.tracked[1].detail, "Quiet since Oct 22");
        assert!(content.tracked[1].is_quiet);
        let suggested: Vec<(&str, &str)> = content
            .suggested
            .iter()
            .map(|r| (r.name.as_str(), r.detail.as_str()))
            .collect();
        assert_eq!(
            suggested,
            [
                ("Redis", "In 4 meetings"),
                ("Index rebuild", "From overnight review")
            ],
            "a hidden name leaves at once"
        );
        assert_eq!(content.child_index(&atlas.id), Some(1));
        assert_eq!(content.child_index("topic:redis"), Some(5));
        assert_eq!(content.child_index("nowhere"), None);
    }

    #[test]
    fn search_matches_any_name() {
        let mut atlas = tracked(1, "Atlas", Some(0));
        atlas.other_names = vec!["Larkspur".into()];
        let borealis = tracked(2, "Borealis", Some(1));
        let content = ListContent::build(&[&atlas, &borealis], &[], " lark ", now());
        assert_eq!(content.tracked.len(), 1);
        assert_eq!(content.tracked[0].name, "Atlas");
        assert!(ListContent::build(&[&atlas], &[], "zzz", now()).is_empty());
    }

    #[test]
    fn hiding_a_suggestion_opens_the_next_one() {
        let rows = |ids: &[&str]| ListContent {
            tracked: Vec::new(),
            suggested: ids
                .iter()
                .map(|id| Row {
                    id: id.to_string(),
                    name: id.to_string(),
                    detail: String::new(),
                    is_suggestion: true,
                    is_quiet: false,
                    open_actions: 0,
                })
                .collect(),
        };
        let content = rows(&["a", "b", "c"]);
        assert_eq!(content.selection_after_removing("b").as_deref(), Some("c"));
        assert_eq!(content.selection_after_removing("c").as_deref(), Some("a"));
        assert_eq!(rows(&["a"]).selection_after_removing("a"), None);
    }

    #[test]
    fn a_suggestion_belongs_where_at_least_half_its_meetings_are() {
        let mut atlas = tracked(1, "Atlas", Some(0));
        atlas.meetings = vec![
            meeting(10, 0),
            meeting(11, 1),
            meeting(12, 2),
            meeting(20, 3),
        ];
        let mut other = tracked(2, "Other", Some(0));
        other.meetings = vec![meeting(13, 0), meeting(10, 0)];
        let mut redis = project("topic:redis", "Redis", ProjectKind::Suggested);
        redis.meetings = vec![
            meeting(10, 0),
            meeting(11, 1),
            meeting(12, 2),
            meeting(13, 3),
        ];
        let home = suggestion_home(&redis, &[&atlas, &other, &redis]).unwrap();
        assert_eq!(home.name, "Atlas");
        assert_eq!(home.shared_meetings, 3);
        assert_eq!(
            suggestion_reason(Some(&home)),
            "3 of its meetings are already linked to Atlas, so it may be part of that project rather than a project of its own."
        );
        assert_eq!(suggestion_reason(None), "No tracked project covers it.");

        let ids = |ids: &[u128]| ids.iter().map(|i| Uuid::from_u128(*i)).collect();
        assert_eq!(shared_meetings(&ids(&[1, 2]), &ids(&[2])), Some(1));
        assert_eq!(shared_meetings(&ids(&[1, 2, 3]), &ids(&[2])), None);
        assert_eq!(shared_meetings(&ids(&[]), &ids(&[2])), None);
        assert_eq!(suggestion_home(&atlas, &[&atlas]), None, "tracked has none");
    }

    #[test]
    fn a_just_tracked_suggestion_stands_in_until_the_next_load() {
        let id = Uuid::from_u128(7);
        let curation = ProjectCuration {
            tracked: vec![TrackedProject {
                id,
                name: "Redis".into(),
                other_names: Vec::new(),
                created_at: now(),
            }],
            ..Default::default()
        };
        let projects = vec![
            tracked(1, "Atlas", Some(0)),
            project("topic:redis", "Redis", ProjectKind::Suggested),
        ];
        let selection = selection_id(id);
        let settling = settling_profile(Some(&selection), &curation, &projects).unwrap();
        assert_eq!(settling.id, selection);
        assert!(settling.is_tracked());
        assert_eq!(settling.tracked_id(), Some(id));
        let shown = list_projects(&projects, Some(&settling));
        let ids: Vec<&str> = shown.iter().map(|p| p.id.as_str()).collect();
        assert_eq!(ids, [selection.as_str(), projects[0].id.as_str()]);
        assert_eq!(
            settling_profile(Some("topic:redis"), &curation, &projects),
            None
        );
        assert_eq!(settling_profile(None, &curation, &projects), None);
    }

    #[test]
    fn the_week_runs_oldest_first_to_today_with_empty_days() {
        let today = now().with_timezone(&Local).date_naive();
        let times = vec![
            ("2026-11-10".to_string(), 3_600.),
            ("2026-11-09".to_string(), 7_200.),
            ("2026-11-01".to_string(), 99.),
        ];
        let week = days(&times, today);
        assert_eq!(week.len(), 7);
        assert_eq!(week[0].date.to_string(), "2026-11-04");
        assert!(week[6].is_today);
        assert_eq!(fraction(&week[5], &week), 1.);
        assert_eq!(fraction(&week[6], &week), 0.5);
        assert_eq!(fraction(&week[0], &week), 0.);
        assert_eq!(weekday_letter(week[0].date), "W");
        assert_eq!(day_time(&week[0]), "Wed, Nov 4: 0m");
        assert_eq!(day_time(&week[5]), "Mon, Nov 9: 2h 0m");
    }

    #[test]
    fn windows_beyond_the_top_three_sum_up() {
        let window = |seconds: f64| ProjectWindowTime {
            app: "Editor".into(),
            title: "atlas".into(),
            seconds,
        };
        let mut atlas = tracked(1, "Atlas", Some(0));
        atlas.windows = vec![window(600.), window(300.), window(200.), window(100.)];
        atlas.window_count = 9;
        atlas.week_seconds = 1_500.;
        assert_eq!(rest(&atlas), Some((6, 400.)));
        atlas.week_seconds = 1_130.;
        assert_eq!(rest(&atlas), None, "under a minute is not listed");
        atlas.windows.truncate(3);
        atlas.window_count = 3;
        atlas.week_seconds = 1_100.;
        assert_eq!(rest(&atlas), None);
        assert_eq!(more_windows(1), "1 more window");
        assert_eq!(more_windows(6), "6 more windows");
    }

    #[test]
    fn an_empty_project_has_nothing_that_names_it() {
        let mut comet = tracked(3, "Comet", None);
        assert!(is_empty(&comet));
        comet.week_seconds = 59.;
        assert!(is_empty(&comet), "under a minute of window time");
        comet.people = vec!["Maya Chen".into()];
        assert!(!is_empty(&comet));
    }

    #[test]
    fn the_toolbar_says_how_recent_or_since_when_tracked() {
        let comet = tracked(3, "Comet", None);
        let since = Local
            .with_ymd_and_hms(2026, 11, 1, 9, 0, 0)
            .unwrap()
            .with_timezone(&Utc);
        assert_eq!(subtitle(&comet, Some(since), now()), "Tracked since Nov 1");
        assert_eq!(subtitle(&comet, None, now()), "Nothing linked yet");
        let atlas = tracked(1, "Atlas", Some(1));
        assert_eq!(subtitle(&atlas, Some(since), now()), "Active yesterday");
        let redis = project("topic:redis", "Redis", ProjectKind::Suggested);
        assert_eq!(subtitle(&redis, None, now()), "Suggested");
    }

    #[test]
    fn the_note_says_when_by_which_model_and_where() {
        let summary = |hours_ago: i64, location: &str| ProjectSummary {
            project_id: "tracked:A".into(),
            overview: String::new(),
            points: Vec::new(),
            open_questions: Vec::new(),
            meeting_ids: Vec::new(),
            evidence_fingerprint: String::new(),
            generated_at: now() - Duration::hours(hours_ago),
            engine_name: "Qwen3.5 4B".into(),
            location: location.into(),
        };
        assert_eq!(
            provenance(&summary(3, "on this PC"), now()),
            "Written today, 9:00 AM, by Qwen3.5 4B on this PC"
        );
        assert_eq!(
            provenance(&summary(48, ""), now()),
            "Written Nov 8 by Qwen3.5 4B on this PC"
        );
        assert_eq!(
            provenance(&summary(48, "gpu.example.com"), now()),
            "Written Nov 8 by Qwen3.5 4B on gpu.example.com"
        );
        assert_eq!(
            provenance(&summary(1, "this Mac"), now()),
            "Written today, 11:00 AM, by Qwen3.5 4B on this Mac",
            "a note the Mac wrote says so"
        );
    }

    #[test]
    fn writing_names_what_the_model_reads() {
        assert_eq!(
            writing(0, true),
            "Writing where it stands from the overnight review…"
        );
        assert_eq!(writing(1, false), "Writing where it stands from 1 meeting…");
        assert_eq!(
            writing(4, true),
            "Writing where it stands from 4 meetings and the overnight review…"
        );
    }

    #[test]
    fn a_suggestion_opens_on_where_it_came_from() {
        let mut redis = project("topic:redis", "Redis", ProjectKind::Suggested);
        redis.meetings = vec![meeting(1, 0), meeting(2, 12)];
        assert_eq!(
            suggestion_title(&redis, now()),
            "Redis came up in 2 meetings since Oct 29"
        );
        let index = project("review:x", "Index rebuild", ProjectKind::SuggestedReview);
        assert_eq!(
            suggestion_title(&index, now()),
            "The overnight review found work on Index rebuild"
        );
        assert_eq!(
            review_citation("2026-11-09", now()),
            "Overnight review · Nov 9"
        );
        assert_eq!(review_citation("soon", now()), "Overnight review");
        assert_eq!(
            point_citation("Design review", Some("2026-11-10"), now()),
            "Design review · Nov 10"
        );
        assert_eq!(
            point_citation("Design review", None, now()),
            "Design review"
        );
    }

    #[test]
    fn list_wording_counts() {
        assert_eq!(open_actions(1), "1 open action for you");
        assert_eq!(open_actions(2), "2 open actions for you");
        assert_eq!(show_hidden(2), "Show 2 hidden suggestions");
        assert_eq!(show_all(false, 12), "Show all 12");
        assert_eq!(show_all(true, 12), "Show fewer");
        let mut atlas = tracked(1, "Atlas", None);
        atlas.other_names = vec!["Larkspur".into()];
        assert_eq!(
            time_source(&atlas),
            "Time in windows whose titles name Atlas, Larkspur"
        );
    }

    #[test]
    fn the_provenance_moves_under_the_title_when_the_card_is_narrow() {
        let line = "Written today, 9:12 AM, by Qwen3.5 4B on this PC";
        assert!(provenance_fits_beside(
            620.,
            "Where it stands",
            line,
            "Update",
            1.0
        ));
        assert!(!provenance_fits_beside(
            420.,
            "Where it stands",
            line,
            "Update",
            1.0
        ));
        assert!(
            !provenance_fits_beside(620., "Where it stands", line, "Update", 1.5),
            "larger text needs more room"
        );
    }
}
