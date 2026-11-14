//! The People list and a person's page as plain data
//! (`PeopleListPresentation.swift`): who matches the search, grouped by time
//! only, each row's wording, and the wording put together from counts, dates
//! and names on the page. Kept apart from drawing so it can be tested.

use lokalbot_i18n::{directional, fill};
use std::collections::{HashMap, HashSet};

use chrono::{DateTime, Local, NaiveDate, Utc};
use lokalbot_core::people::upcoming::PersonUpcomingMeeting;
use lokalbot_core::{MeetingRef, PersonProfile};

/// Decisions shown before "Show N more".
pub(super) const VISIBLE_DECISIONS: usize = 3;
/// Meeting titles shown in the side column before "Show N more".
pub(super) const VISIBLE_SERIES: usize = 8;
/// Other invited people named on the next-meeting card.
pub(super) const VISIBLE_INVITEES: usize = 3;
/// "Last 2 weeks" reaches this many days back.
pub(super) const RECENT_DAYS: u64 = 14;

// ------------------------------------------------------------- meetings

/// One meeting as it happened (`PersonProfile.Occasion`): a call recorded in
/// several parts is one occasion with several recordings, newest first.
#[derive(Clone, Debug, PartialEq)]
pub(super) struct Occasion {
    pub recordings: Vec<MeetingRef>,
}

impl Occasion {
    /// The longest recording, which is the one worth opening.
    pub fn primary(&self) -> &MeetingRef {
        lokalbot_core::people::primary(&self.recordings)
    }

    pub fn title(&self) -> &str {
        &self.primary().title
    }

    pub fn started_at(&self) -> DateTime<Utc> {
        self.recordings
            .iter()
            .map(|r| r.started_at)
            .min()
            .unwrap_or(self.primary().started_at)
    }
}

/// Occasions that share a title, such as a weekly standup
/// (`PersonProfile.Series`). Newest first.
#[derive(Clone, Debug, PartialEq)]
pub(super) struct Series {
    pub title: String,
    pub occasions: Vec<Occasion>,
}

impl Series {
    pub fn latest(&self) -> &Occasion {
        &self.occasions[0]
    }

    /// Stable across reloads while the series keeps its title.
    pub fn key(&self) -> String {
        lokalbot_core::people::normalized(&self.title)
    }
}

/// Recordings grouped into the meetings they belong to, newest first.
pub(super) fn occasions(person: &PersonProfile) -> Vec<Occasion> {
    lokalbot_core::people::occasions(&person.meetings)
        .into_iter()
        .map(|recordings| Occasion { recordings })
        .collect()
}

/// Occasions grouped by title; the series with the newest meeting first.
pub(super) fn series(occasions: Vec<Occasion>) -> Vec<Series> {
    let mut order: Vec<String> = Vec::new();
    let mut by_key: HashMap<String, Series> = HashMap::new();
    for occasion in occasions {
        let key = lokalbot_core::people::normalized(occasion.title());
        by_key
            .entry(key.clone())
            .or_insert_with(|| {
                order.push(key);
                Series {
                    title: occasion.title().to_string(),
                    occasions: Vec::new(),
                }
            })
            .occasions
            .push(occasion);
    }
    order
        .into_iter()
        .filter_map(|key| by_key.remove(&key))
        .collect()
}

/// The person's initials as their avatar shows them: the first and last
/// words that start with a letter (`InitialsAvatar.initials`).
pub(crate) fn initials(name: &str) -> String {
    let words: Vec<&str> = name
        .split(' ')
        .filter(|w| w.chars().next().is_some_and(char::is_alphabetic))
        .collect();
    let letters = match words.as_slice() {
        [] => Vec::new(),
        [only] => vec![*only],
        [first, .., last] => vec![*first, *last],
    };
    letters
        .iter()
        .filter_map(|w| w.chars().next())
        .flat_map(char::to_uppercase)
        .collect()
}

/// The first word of the person's name (`PersonProfile.firstName`).
pub(super) fn first_name(person: &PersonProfile) -> &str {
    person
        .name
        .split(' ')
        .find(|w| !w.is_empty())
        .unwrap_or(&person.name)
}

// ----------------------------------------------------------------- list

/// The list's groups: calendar meetings in the next week, then when you
/// last met.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub(super) enum Group {
    ComingUp,
    Recent,
    Earlier,
}

impl Group {
    pub fn title(self) -> &'static str {
        match self {
            Group::ComingUp => lokalbot_i18n::tr("Coming up"),
            Group::Recent => lokalbot_i18n::tr("Last 2 weeks"),
            Group::Earlier => lokalbot_i18n::tr("Earlier"),
        }
    }
}

/// Which way open work runs, as one badge. Work the user owes shows first:
/// when both directions are open, the badge counts the user's.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Badge {
    YouOwe(usize),
    OwesYou(usize),
}

impl Badge {
    pub fn new(you_owe: usize, owes_you: usize) -> Option<Self> {
        if you_owe > 0 {
            Some(Badge::YouOwe(you_owe))
        } else if owes_you > 0 {
            Some(Badge::OwesYou(owes_you))
        } else {
            None
        }
    }

    /// Amber for the user's own work, quiet for the other person's.
    pub fn needs_attention(self) -> bool {
        matches!(self, Badge::YouOwe(_))
    }

    pub fn text(self) -> String {
        directional(match self {
            Badge::YouOwe(count) => fill(
                lokalbot_i18n::tr("You owe %lld"),
                &[&lokalbot_i18n::number(count)],
            ),
            Badge::OwesYou(count) => fill(
                lokalbot_i18n::tr("Owes you %lld"),
                &[&lokalbot_i18n::number(count)],
            ),
        })
    }
}

#[derive(Clone, Debug, PartialEq)]
pub(super) struct Row {
    /// The person's ID.
    pub id: String,
    pub name: String,
    /// The next meeting's title under Coming up, else the latest one's.
    pub detail: String,
    /// The next meeting's time, else the day you last met.
    pub when: String,
    pub badge: Option<Badge>,
}

#[derive(Clone, Debug, PartialEq)]
pub(super) struct Section {
    pub group: Group,
    pub rows: Vec<Row>,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub(super) struct ListContent {
    pub sections: Vec<Section>,
}

impl ListContent {
    /// Every row's person ID, in the order shown.
    pub fn person_ids(&self) -> impl Iterator<Item = &str> {
        self.sections
            .iter()
            .flat_map(|s| s.rows.iter().map(|r| r.id.as_str()))
    }

    pub fn is_empty(&self) -> bool {
        self.sections.is_empty()
    }

    /// Where a person's row sits among the list's children, counting each
    /// group's heading row, so the list can scroll to it.
    pub fn child_index(&self, person_id: &str) -> Option<usize> {
        let mut index = 0;
        for section in &self.sections {
            index += 1;
            if let Some(row) = section.rows.iter().position(|r| r.id == person_id) {
                return Some(index + row);
            }
            index += section.rows.len();
        }
        None
    }

    /// `upcoming` holds each person's next calendar meeting, by person ID;
    /// it is empty without calendar use, and then there is no Coming up.
    /// `query` matches a person's name or any other name they appear as.
    pub fn build(
        people: &[PersonProfile],
        hidden: &HashSet<String>,
        upcoming: &HashMap<String, PersonUpcomingMeeting>,
        query: &str,
        now: DateTime<Utc>,
    ) -> Self {
        let needle = query.trim().to_lowercase();
        let matching: Vec<&PersonProfile> = people
            .iter()
            .filter(|p| !hidden.contains(&p.id))
            .filter(|p| {
                needle.is_empty()
                    || std::iter::once(&p.name)
                        .chain(p.other_names.iter())
                        .any(|n| n.to_lowercase().contains(&needle))
            })
            .collect();
        let today = now.with_timezone(&Local).date_naive();
        let recent_start = lokalbot_core::time::local_day_bounds(
            today
                .checked_sub_days(chrono::Days::new(RECENT_DAYS))
                .unwrap_or(today),
        )
        .0;

        let mut coming_up: Vec<&PersonProfile> = Vec::new();
        let mut recent: Vec<&PersonProfile> = Vec::new();
        let mut earlier: Vec<&PersonProfile> = Vec::new();
        for person in matching {
            if upcoming.contains_key(&person.id) {
                coming_up.push(person);
            } else if person.last_met().is_some_and(|last| last >= recent_start) {
                recent.push(person);
            } else {
                earlier.push(person);
            }
        }
        let by_recency = |a: &&PersonProfile, b: &&PersonProfile| {
            b.last_met()
                .cmp(&a.last_met())
                .then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
        };
        coming_up.sort_by(|a, b| {
            let start = |p: &PersonProfile| upcoming.get(&p.id).map(|m| m.start);
            start(a).cmp(&start(b)).then_with(|| by_recency(a, b))
        });
        recent.sort_by(by_recency);
        earlier.sort_by(by_recency);

        let sections = [
            (Group::ComingUp, coming_up),
            (Group::Recent, recent),
            (Group::Earlier, earlier),
        ]
        .into_iter()
        .filter(|(_, members)| !members.is_empty())
        .map(|(group, members)| Section {
            group,
            rows: members
                .into_iter()
                .map(|person| {
                    let next = (group == Group::ComingUp)
                        .then(|| upcoming.get(&person.id))
                        .flatten();
                    row(person, next, now)
                })
                .collect(),
        })
        .collect();
        ListContent { sections }
    }
}

fn row(person: &PersonProfile, next: Option<&PersonUpcomingMeeting>, now: DateTime<Utc>) -> Row {
    let (detail, when) = match next {
        Some(next) => (next.title.clone(), upcoming_time(next, now)),
        None => (
            occasions(person)
                .first()
                .map(|o| o.title().to_string())
                .unwrap_or_else(|| lokalbot_i18n::tr("Named in actions").to_string()),
            person.last_met().map(|d| day(d, now)).unwrap_or_default(),
        ),
    };
    Row {
        id: person.id.clone(),
        name: person.name.clone(),
        detail,
        when: directional(when),
        badge: Badge::new(person.my_actions.len(), person.their_actions.len()),
    }
}

// -------------------------------------------------------------- wording

/// The moment on the local clock.
pub(crate) fn local(date: DateTime<Utc>) -> DateTime<Local> {
    date.with_timezone(&Local)
}

/// The moment on the local clock in a date pattern, in the interface's
/// locale (`lokalbot_i18n::date_pattern`).
pub(crate) fn formatted(date: DateTime<Utc>, pattern: &str) -> String {
    local(date)
        .format_localized(
            lokalbot_i18n::date_pattern(pattern),
            lokalbot_i18n::date_locale(),
        )
        .to_string()
}

/// "Nov 10", with the year once it is not this year
/// (`lokalbot_i18n::short_date` on the local days).
pub(crate) fn short_date(date: DateTime<Utc>, now: DateTime<Utc>) -> String {
    lokalbot_i18n::short_date(local(date).date_naive(), local(now).date_naive())
}

/// "Today", "Yesterday", "Fri, Nov 6" for the rest of the past week, then
/// "Oct 27" (`lokalbot_i18n::day_label` on the local days).
pub(crate) fn day(date: DateTime<Utc>, now: DateTime<Utc>) -> String {
    lokalbot_i18n::day_label(local(date).date_naive(), local(now).date_naive())
}

/// "Thu 2:00 PM", or the time alone for a meeting today. A meeting under way
/// still shows when it started.
pub(super) fn upcoming_time(meeting: &PersonUpcomingMeeting, now: DateTime<Utc>) -> String {
    let time = lokalbot_core::time::clock_time(meeting.start);
    if local(meeting.start).date_naive() == local(now).date_naive() {
        time
    } else {
        format!("{} {time}", formatted(meeting.start, "%a"))
    }
}

/// "2:00 – 2:30 PM": a twelve-hour clock says AM or PM once when both ends
/// share it, as the Mac's interval format does.
pub(super) fn time_range(start: DateTime<Utc>, end: DateTime<Utc>) -> String {
    let pattern = lokalbot_i18n::date_pattern("%-I:%M %p");
    let clock = |date: DateTime<Utc>, pattern: &str| {
        local(date)
            .format_localized(pattern, lokalbot_i18n::date_locale())
            .to_string()
    };
    if pattern == "%-I:%M %p" && clock(start, "%p") == clock(end, "%p") {
        return format!("{} – {}", clock(start, "%-I:%M"), clock(end, pattern));
    }
    format!("{} – {}", clock(start, pattern), clock(end, pattern))
}

/// How far away a day is: "today", "tomorrow", "in 3 days".
fn days_away(days: i64) -> String {
    match days {
        ..=0 => lokalbot_i18n::tr("today").to_string(),
        1 => lokalbot_i18n::tr("tomorrow").to_string(),
        days => lokalbot_i18n::format(
            "in {days} days",
            &[("days", lokalbot_i18n::number(days as usize))],
        ),
    }
}

/// "Next meeting in 2 days · Thu, Nov 12, 2:00 – 2:30 PM", or "In progress
/// · …" while it is under way.
pub(super) fn next_meeting_line(meeting: &PersonUpcomingMeeting, now: DateTime<Utc>) -> String {
    let lead = if meeting.is_in_progress(now) {
        lokalbot_i18n::tr("In progress").to_string()
    } else {
        let days = (local(meeting.start).date_naive() - local(now).date_naive()).num_days();
        fill(lokalbot_i18n::tr("Next meeting %@"), &[&days_away(days)])
    };
    let day = formatted(meeting.start, "%a, %b %-d");
    let same_day = local(meeting.start).date_naive() == local(meeting.end).date_naive();
    let time = if meeting.end > meeting.start && same_day {
        time_range(meeting.start, meeting.end)
    } else {
        lokalbot_core::time::clock_time(meeting.start)
    };
    directional(format!("{lead} · {day}, {time}"))
}

/// "Also invited: Daniel Ortiz, Priya Nair +2", or "Just the two of you".
pub(super) fn invited(others: &[String]) -> String {
    if others.is_empty() {
        return lokalbot_i18n::tr("Just the two of you").to_string();
    }
    let mut names = others
        .iter()
        .take(VISIBLE_INVITEES)
        .cloned()
        .collect::<Vec<_>>()
        .join(", ");
    if others.len() > VISIBLE_INVITEES {
        names.push_str(&format!(" +{}", others.len() - VISIBLE_INVITEES));
    }
    fill(lokalbot_i18n::tr("Also invited: %@"), &[&names])
}

/// "31 meetings since Mar 4", "Met once, Oct 22", or "Named in actions" for
/// someone who only owns an action.
pub(super) fn subtitle(person: &PersonProfile, now: DateTime<Utc>) -> String {
    let occasions = occasions(person);
    let Some(first) = occasions.last().map(Occasion::started_at) else {
        return lokalbot_i18n::tr("Named in actions").to_string();
    };
    let day = short_date(first, now);
    directional(if occasions.len() == 1 {
        fill(lokalbot_i18n::tr("Met once, %@"), &[&day])
    } else {
        fill(
            lokalbot_i18n::tr("%lld meetings since %@"),
            &[&lokalbot_i18n::number(occasions.len()), &day],
        )
    })
}

/// "Design review meeting · Nov 10".
pub(crate) fn meeting_link(title: &str, date: DateTime<Utc>, now: DateTime<Utc>) -> String {
    format!("{title} · {}", short_date(date, now))
}

/// Under a title in the side column: "22 meetings · Nov 10" for a series,
/// the date alone for a single meeting.
pub(super) fn series_detail(series: &Series, now: DateTime<Utc>) -> String {
    let day = short_date(series.latest().started_at(), now);
    let count = series.occasions.len();
    if count <= 1 {
        return day;
    }
    directional(format!(
        "{} · {day}",
        fill(
            lokalbot_i18n::tr("%lld meetings"),
            &[&lokalbot_i18n::number(count)]
        )
    ))
}

/// "2 recordings" beside a call recorded in parts, nothing for one.
pub(super) fn recordings_note(occasion: &Occasion) -> Option<String> {
    let count = occasion.recordings.len();
    (count > 1).then(|| {
        directional(lokalbot_i18n::format(
            "{count} recordings",
            &[("count", lokalbot_i18n::number(count))],
        ))
    })
}

/// A series' date row: "Tue, Nov 10".
pub(super) fn occasion_day(occasion: &Occasion) -> String {
    formatted(occasion.started_at(), "%a, %b %-d")
}

/// "Restore 2 hidden entries".
pub(super) fn restore_hidden(count: usize) -> String {
    let template = if count == 1 {
        lokalbot_i18n::tr("Restore %lld hidden entry")
    } else {
        lokalbot_i18n::tr("Restore %lld hidden entries")
    };
    fill(template, &[&lokalbot_i18n::number(count)])
}

/// "Show 3 more" or "Show fewer".
pub(crate) fn show_more(expanded: bool, hidden: usize) -> String {
    if expanded {
        lokalbot_i18n::tr("Show fewer").to_string()
    } else {
        fill(
            lokalbot_i18n::tr("Show %lld more"),
            &[&lokalbot_i18n::number(hidden)],
        )
    }
}

/// How many rows stay behind "Show N more".
pub(crate) fn hidden_count(total: usize, visible: usize) -> usize {
    total.saturating_sub(visible)
}

/// The day the list's wording was made for: rows say "Today" and "Thu".
pub(super) fn local_day(now: DateTime<Utc>) -> NaiveDate {
    local(now).date_naive()
}

/// Below this width the toolbar's Ask button shows its icon alone.
pub(super) const COMPACT_TOOLBAR_WIDTH: f32 = 720.;

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::{Duration, TimeZone as _};
    use lokalbot_core::model::{CalendarParticipantIdentity, Meeting};
    use lokalbot_core::people::{PeopleInput, build_people};

    /// A Tuesday at noon, local time, so the day words do not depend on the
    /// machine's time zone.
    fn now() -> DateTime<Utc> {
        Local
            .with_ymd_and_hms(2026, 11, 10, 12, 0, 0)
            .unwrap()
            .with_timezone(&Utc)
    }

    fn meeting(title: &str, hours_ago: i64, attendees: &[(&str, &str)]) -> Meeting {
        let start = now() - Duration::hours(hours_ago);
        let mut meeting = Meeting::new(
            title,
            "Meet",
            start,
            &format!("meetings/{title}-{hours_ago}"),
        );
        meeting.ended_at = Some(start + Duration::minutes(30));
        meeting.calendar_participant_identities = Some(
            attendees
                .iter()
                .enumerate()
                .filter_map(|(index, (name, email))| {
                    CalendarParticipantIdentity::new(
                        &format!("{title}-{hours_ago}-{index}"),
                        Some(name),
                        Some(email),
                    )
                })
                .collect(),
        );
        meeting
    }

    fn build(meetings: &[Meeting]) -> Vec<PersonProfile> {
        build_people(&PeopleInput {
            meetings,
            projections: &[],
            applied: &HashMap::new(),
            self_names: &["Sam Reed".to_string()],
            curation: &Default::default(),
            today: now().with_timezone(&Local).date_naive(),
        })
    }

    const ANA: (&str, &str) = ("Ana Petrović", "ana@example.com");
    const MARKO: (&str, &str) = ("Marko Jovanović", "marko@example.com");
    const IVANA: (&str, &str) = ("Ivana Ilić", "ivana@example.com");
    const PETAR: (&str, &str) = ("Petar Lazić", "petar@example.com");
    const LENA: (&str, &str) = ("Lena Novak", "lena@example.com");

    /// Ana: met yesterday. Marko: three days ago. Petar: an hour ago.
    /// Ivana: 20 days ago. Lena: 40 days ago.
    fn library() -> Vec<PersonProfile> {
        build(&[
            meeting("Design review", 24, &[ANA]),
            meeting("Standup", 72, &[MARKO]),
            meeting("Kickoff", 1, &[PETAR]),
            meeting("Vendor check-in", 20 * 24, &[IVANA]),
            meeting("Roadmap planning", 40 * 24, &[LENA]),
        ])
    }

    fn upcoming(title: &str, in_hours: i64) -> PersonUpcomingMeeting {
        let start = now() + Duration::hours(in_hours);
        PersonUpcomingMeeting {
            event_id: title.into(),
            title: title.into(),
            start,
            end: start + Duration::minutes(30),
            others: Vec::new(),
        }
    }

    fn id(name: &str, people: &[PersonProfile]) -> String {
        people.iter().find(|p| p.name == name).unwrap().id.clone()
    }

    fn content(
        people: &[PersonProfile],
        next: &HashMap<String, PersonUpcomingMeeting>,
        query: &str,
    ) -> ListContent {
        ListContent::build(people, &HashSet::new(), next, query, now())
    }

    fn names(content: &ListContent) -> Vec<Vec<&str>> {
        content
            .sections
            .iter()
            .map(|s| s.rows.iter().map(|r| r.name.as_str()).collect())
            .collect()
    }

    #[test]
    fn without_a_calendar_people_group_by_when_you_last_met() {
        let content = content(&library(), &HashMap::new(), "");
        assert_eq!(
            content.sections.iter().map(|s| s.group).collect::<Vec<_>>(),
            [Group::Recent, Group::Earlier]
        );
        assert_eq!(
            names(&content),
            [
                vec!["Petar Lazić", "Ana Petrović", "Marko Jovanović"],
                vec!["Ivana Ilić", "Lena Novak"]
            ],
            "newest first; open work no longer moves anyone up"
        );
        assert_eq!(Group::Recent.title(), "Last 2 weeks");
        assert_eq!(Group::ComingUp.title(), "Coming up");
    }

    #[test]
    fn coming_up_leads_in_meeting_order_then_recency() {
        let people = library();
        let next = HashMap::from([
            (id("Marko Jovanović", &people), upcoming("Atlas sync", 50)),
            (id("Lena Novak", &people), upcoming("Borealis review", 20)),
            (id("Ana Petrović", &people), upcoming("Atlas sync", 50)),
        ]);
        let content = content(&people, &next, "");
        assert_eq!(
            content.sections.iter().map(|s| s.group).collect::<Vec<_>>(),
            [Group::ComingUp, Group::Recent, Group::Earlier]
        );
        assert_eq!(
            names(&content),
            [
                vec!["Lena Novak", "Ana Petrović", "Marko Jovanović"],
                vec!["Petar Lazić"],
                vec!["Ivana Ilić"]
            ],
            "the sooner meeting first; two people in one meeting by who you met last"
        );
        assert_eq!(
            content.person_ids().next(),
            Some(id("Lena Novak", &people).as_str())
        );
        // Each group's heading is a row of the list too.
        assert_eq!(content.child_index(&id("Lena Novak", &people)), Some(1));
        assert_eq!(content.child_index(&id("Petar Lazić", &people)), Some(5));
        assert_eq!(content.child_index(&id("Ivana Ilić", &people)), Some(7));
        assert_eq!(content.child_index("person-nobody"), None);
    }

    #[test]
    fn rows_show_the_next_or_latest_meeting_and_when() {
        let people = library();
        let next = HashMap::from([
            (id("Marko Jovanović", &people), upcoming("Atlas sync", 50)),
            (id("Lena Novak", &people), upcoming("Borealis review", 2)),
        ]);
        let content = content(&people, &next, "");
        let rows: HashMap<&str, &Row> = content
            .sections
            .iter()
            .flat_map(|s| s.rows.iter())
            .map(|r| (r.name.as_str(), r))
            .collect();
        assert_eq!(rows["Marko Jovanović"].detail, "Atlas sync");
        assert_eq!(rows["Marko Jovanović"].when, "Thu 2:00 PM");
        assert_eq!(
            rows["Lena Novak"].when, "2:00 PM",
            "a meeting today shows its time alone"
        );
        assert_eq!(rows["Petar Lazić"].detail, "Kickoff");
        assert_eq!(rows["Petar Lazić"].when, "Today");
        assert_eq!(rows["Ana Petrović"].when, "Yesterday");
        assert_eq!(rows["Ana Petrović"].detail, "Design review");
        assert_eq!(rows["Ivana Ilić"].when, "Oct 21");
    }

    #[test]
    fn search_matches_any_name_and_hidden_people_never_show() {
        let mut people = library();
        let ivana = people.iter_mut().find(|p| p.name == "Ivana Ilić").unwrap();
        ivana.other_names = vec!["Ivy".into()];
        let flat = |c: ListContent| -> Vec<String> {
            c.sections
                .into_iter()
                .flat_map(|s| s.rows.into_iter().map(|r| r.name))
                .collect()
        };
        assert_eq!(
            flat(content(&people, &HashMap::new(), " ivy ")),
            ["Ivana Ilić"]
        );
        assert_eq!(
            flat(content(&people, &HashMap::new(), "PETROV")),
            ["Ana Petrović"]
        );
        assert!(content(&people, &HashMap::new(), "nobody").is_empty());
        let hidden = HashSet::from([id("Petar Lazić", &people)]);
        let without = ListContent::build(&people, &hidden, &HashMap::new(), "", now());
        assert!(!flat(without).contains(&"Petar Lazić".to_string()));
    }

    #[test]
    fn the_badge_says_which_way_open_work_runs_and_the_users_own_shows_first() {
        assert_eq!(Badge::new(0, 0), None);
        assert_eq!(Badge::new(2, 0), Some(Badge::YouOwe(2)));
        assert_eq!(Badge::new(0, 3), Some(Badge::OwesYou(3)));
        assert_eq!(
            Badge::new(1, 4),
            Some(Badge::YouOwe(1)),
            "both ways: the user's shows"
        );
        assert_eq!(Badge::YouOwe(2).text(), "You owe 2");
        assert_eq!(Badge::OwesYou(1).text(), "Owes you 1");
        assert!(Badge::YouOwe(1).needs_attention());
        assert!(!Badge::OwesYou(1).needs_attention());
    }

    #[test]
    fn subtitle_counts_meetings_since_the_first() {
        let people = build(&[
            meeting("Standup", 2, &[ANA, MARKO]),
            meeting("Standup", 13 * 24, &[ANA]),
            meeting("Design review", 24, &[ANA]),
        ]);
        let person = |name| people.iter().find(|p| p.name == name).unwrap();
        assert_eq!(
            subtitle(person("Ana Petrović"), now()),
            "3 meetings since Oct 28"
        );
        assert_eq!(
            subtitle(person("Marko Jovanović"), now()),
            "Met once, Nov 10"
        );
        let mut owner_only = person("Marko Jovanović").clone();
        owner_only.meetings.clear();
        assert_eq!(subtitle(&owner_only, now()), "Named in actions");
    }

    #[test]
    fn next_meeting_line_says_how_far_away_then_the_day_and_time() {
        let line = |hours: i64| next_meeting_line(&upcoming("Atlas sync", hours), now());
        assert_eq!(
            line(50),
            "Next meeting in 2 days · Thu, Nov 12, 2:00 – 2:30 PM"
        );
        assert_eq!(
            line(20),
            "Next meeting tomorrow · Wed, Nov 11, 8:00 – 8:30 AM"
        );
        assert_eq!(line(2), "Next meeting today · Tue, Nov 10, 2:00 – 2:30 PM");
        let mut under_way = upcoming("Atlas sync", 0);
        under_way.start = now() - Duration::minutes(15);
        under_way.end = now() + Duration::minutes(15);
        assert_eq!(
            next_meeting_line(&under_way, now()),
            "In progress · Tue, Nov 10, 11:45 AM – 12:15 PM"
        );
    }

    #[test]
    fn invited_names_the_others_or_says_it_is_just_the_two_of_you() {
        assert_eq!(invited(&[]), "Just the two of you");
        assert_eq!(
            invited(&["Marko Jovanović".into()]),
            "Also invited: Marko Jovanović"
        );
        let five: Vec<String> = ["A", "B", "C", "D", "E"]
            .iter()
            .map(|s| s.to_string())
            .collect();
        assert_eq!(invited(&five), "Also invited: A, B, C +2");
    }

    #[test]
    fn series_detail_counts_a_series_and_dates_a_single_meeting() {
        let people = build(&[
            meeting("Standup", 26, &[ANA]),
            meeting("Standup", 8 * 24, &[ANA]),
            meeting("Standup", 15 * 24, &[ANA]),
            meeting("Offsite", 400 * 24, &[ANA]),
        ]);
        let series = series(occasions(&people[0]));
        assert_eq!(
            series.iter().map(|s| s.title.as_str()).collect::<Vec<_>>(),
            ["Standup", "Offsite"]
        );
        assert_eq!(
            series
                .iter()
                .map(|s| series_detail(s, now()))
                .collect::<Vec<_>>(),
            ["3 meetings · Nov 9", "Oct 6, 2025"]
        );
        assert_eq!(meeting_link("Standup", now(), now()), "Standup · Nov 10");
    }

    #[test]
    fn a_call_recorded_in_parts_is_one_meeting_that_opens_its_longest_part() {
        let mut first = meeting("Design review", 3, &[ANA]);
        first.ended_at = Some(first.started_at + Duration::minutes(10));
        let mut second = meeting("Design review", 3, &[ANA]);
        second.started_at = first.started_at + Duration::minutes(12);
        second.ended_at = Some(second.started_at + Duration::minutes(40));
        let people = build(&[first.clone(), second.clone()]);
        let occasions = occasions(&people[0]);
        assert_eq!(occasions.len(), 1);
        assert_eq!(occasions[0].primary().id, second.id);
        assert_eq!(occasions[0].started_at(), first.started_at);
        assert_eq!(
            recordings_note(&occasions[0]).as_deref(),
            Some("2 recordings")
        );
    }

    #[test]
    fn show_more_counts_and_restore_wording() {
        assert_eq!(hidden_count(6, VISIBLE_DECISIONS), 3);
        assert_eq!(hidden_count(3, VISIBLE_DECISIONS), 0);
        assert_eq!(show_more(false, 3), "Show 3 more");
        assert_eq!(show_more(true, 3), "Show fewer");
        assert_eq!(restore_hidden(1), "Restore 1 hidden entry");
        assert_eq!(restore_hidden(2), "Restore 2 hidden entries");
    }

    #[test]
    fn avatars_use_the_first_and_last_names() {
        assert_eq!(initials("Maya van Dijk"), "MD");
        assert_eq!(initials("Priya"), "P");
        assert_eq!(initials("Ana  (host) Petrović"), "AP");
        assert_eq!(initials(""), "");
    }
}
