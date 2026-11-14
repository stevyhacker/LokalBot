//! What the Actions page decides before it draws (`ActionsListPresentation.swift`
//! and `ActionAttentionOrder` in `ActionThreads.swift`): which threads the
//! status, search and Filter menu list, in what order and under which
//! headings, the wording of every row, the chips of the active filters, the
//! people and projects an action belongs to, which rows are selected, and the
//! corrections the details pane saves. Display-only: nothing here is stored
//! or sent.

use std::collections::{HashMap, HashSet};

use chrono::{DateTime, Datelike as _, Local, NaiveDate, Utc};
use lokalbot_core::action_completion::CompletionHint;
use lokalbot_core::{ActionCorrection, ActionStatus, ActionThread, PersonProfile, ProjectProfile};
use uuid::Uuid;

use crate::pages::today::model::fill;
use crate::ui::action_row::DueTone;

/// Meetings the Filter menu offers, newest first.
pub(super) const MAXIMUM_MEETING_CHOICES: usize = 40;
/// The Done list's first heading reaches back this many days, today included.
pub(super) const RECENTLY_DONE_DAYS: i64 = 7;
/// People or projects the details pane names for one action.
pub(super) const MAXIMUM_LINKS: usize = 4;

/// The statuses the page lists, in the order of its segmented control.
pub(super) const STATUSES: [ActionStatus; 3] = [
    ActionStatus::Open,
    ActionStatus::Deferred,
    ActionStatus::Done,
];

/// The catalog key for a status as a state. "Open" on its own is the verb on
/// buttons, which most languages translate differently (`stateKey`).
pub(super) fn state_key(status: ActionStatus) -> &'static str {
    match status {
        ActionStatus::Open => "Open (status)",
        ActionStatus::Deferred => "Deferred",
        ActionStatus::Done => "Done",
    }
}

// ----------------------------------------------------------------- filter

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(super) enum DueFilter {
    #[default]
    Any,
    Overdue,
    Dated,
    Undated,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(super) enum Grouping {
    #[default]
    Due,
    Meeting,
    None,
}

/// What the page lists: one status, a search, and the choices of its Filter
/// menu (`ActionsListFilter`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct ListFilter {
    pub status: ActionStatus,
    pub query: String,
    pub due: DueFilter,
    pub person_id: Option<String>,
    pub project_id: Option<String>,
    /// Every meeting with this title, so a weekly standup is one choice.
    pub meeting_title: Option<String>,
    /// Open actions nobody has mentioned for three weeks.
    pub stale_only: bool,
    pub grouping: Grouping,
}

impl Default for ListFilter {
    fn default() -> Self {
        Self {
            status: ActionStatus::Open,
            query: String::new(),
            due: DueFilter::Any,
            person_id: None,
            project_id: None,
            meeting_title: None,
            stale_only: false,
            grouping: Grouping::Due,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub(super) enum ChipKind {
    Due,
    Person,
    Project,
    Meeting,
    Stale,
}

/// One active Filter menu choice, shown as a removable chip.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct Chip {
    pub kind: ChipKind,
    pub label: String,
}

impl ListFilter {
    /// The stale review only exists among open actions.
    pub fn is_stale_review(&self) -> bool {
        self.status == ActionStatus::Open && self.stale_only
    }

    pub fn trimmed_query(&self) -> &str {
        self.query.trim()
    }

    /// Filter menu choices that narrow the list; each shows as a chip.
    pub fn has_menu_filters(&self) -> bool {
        self.due != DueFilter::Any
            || self.person_id.is_some()
            || self.project_id.is_some()
            || self.meeting_title.is_some()
            || self.is_stale_review()
    }

    pub fn narrows_list(&self) -> bool {
        self.has_menu_filters() || !self.trimmed_query().is_empty()
    }

    pub fn clear_filters(&mut self) {
        self.query.clear();
        self.due = DueFilter::Any;
        self.person_id = None;
        self.project_id = None;
        self.meeting_title = None;
        self.stale_only = false;
    }

    /// Done actions are outside the People and Projects read models, and the
    /// stale review is about open work, so leaving Open drops what cannot
    /// apply.
    pub fn show(&mut self, status: ActionStatus) {
        self.status = status;
        if status != ActionStatus::Open {
            self.stale_only = false;
        }
        if status == ActionStatus::Done {
            self.person_id = None;
            self.project_id = None;
        }
    }

    /// The active Filter menu choices, in the order the menu lists them.
    pub fn chips(&self, links: &ThreadLinks) -> Vec<Chip> {
        let mut chips = Vec::new();
        let due = match self.due {
            DueFilter::Any => None,
            DueFilter::Overdue => Some(lokalbot_i18n::tr("Overdue")),
            DueFilter::Dated => Some(lokalbot_i18n::tr("Has a date")),
            DueFilter::Undated => Some(lokalbot_i18n::tr("No date")),
        };
        if let Some(label) = due {
            chips.push(Chip {
                kind: ChipKind::Due,
                label: label.to_string(),
            });
        }
        if let Some(id) = &self.person_id {
            let name = links
                .person_name(id)
                .unwrap_or_else(|| lokalbot_i18n::tr("Person"));
            chips.push(Chip {
                kind: ChipKind::Person,
                label: fill(lokalbot_i18n::tr("With %@"), &[name]),
            });
        }
        if let Some(id) = &self.project_id {
            let name = links
                .project_name(id)
                .unwrap_or_else(|| lokalbot_i18n::tr("Project"));
            chips.push(Chip {
                kind: ChipKind::Project,
                label: fill(lokalbot_i18n::tr("Project: %@"), &[name]),
            });
        }
        if let Some(title) = &self.meeting_title {
            chips.push(Chip {
                kind: ChipKind::Meeting,
                label: fill(lokalbot_i18n::tr("From %@"), &[title]),
            });
        }
        if self.is_stale_review() {
            chips.push(Chip {
                kind: ChipKind::Stale,
                label: lokalbot_i18n::tr("Not mentioned in 3 weeks").to_string(),
            });
        }
        chips
    }

    pub fn remove(&mut self, chip: ChipKind) {
        match chip {
            ChipKind::Due => self.due = DueFilter::Any,
            ChipKind::Person => self.person_id = None,
            ChipKind::Project => self.project_id = None,
            ChipKind::Meeting => self.meeting_title = None,
            ChipKind::Stale => self.stale_only = false,
        }
    }
}

// ------------------------------------------------------------------ links

/// A person or project an action belongs to.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct Link {
    pub id: String,
    pub name: String,
}

/// What one person or project contributes to [`ThreadLinks`]: its own open
/// and deferred work for the user, as action reference ids.
#[derive(Clone, Debug, Default)]
pub(super) struct LinkSource {
    pub id: String,
    pub name: String,
    /// Ids folded into this person.
    pub aliases: Vec<String>,
    pub references: HashSet<String>,
    pub tracked: bool,
}

/// The people and projects an action belongs to, looked up backwards from the
/// People and Projects read models (`ActionThreadLinks`). Those models list
/// the user's open and deferred work per person and per project; nothing new
/// is derived here.
#[derive(Clone, Debug, Default)]
pub(super) struct ThreadLinks {
    /// People and projects with at least one of the user's actions.
    pub people: Vec<Link>,
    pub projects: Vec<Link>,
    /// Action reference id to positions in `people` and `projects`. A thread
    /// is found by its references, so re-threading does not lose the link.
    people_by_reference: HashMap<String, Vec<usize>>,
    projects_by_reference: HashMap<String, Vec<usize>>,
    /// Ids of people folded into another person.
    person_aliases: HashMap<String, String>,
}

fn reference_ids(threads: &[ActionThread]) -> HashSet<String> {
    threads
        .iter()
        .flat_map(|t| t.references.iter().map(|r| r.id.clone()))
        .collect()
}

impl ThreadLinks {
    pub fn new(people: &[PersonProfile], projects: &[ProjectProfile]) -> Self {
        let people = people.iter().map(|person| LinkSource {
            id: person.id.clone(),
            name: person.name.clone(),
            aliases: person.member_ids.clone(),
            references: reference_ids(&person.my_actions),
            tracked: false,
        });
        let projects = projects.iter().map(|project| LinkSource {
            id: project.id.clone(),
            name: project.name.clone(),
            aliases: Vec::new(),
            references: reference_ids(&project.my_actions),
            tracked: project.is_tracked(),
        });
        Self::from_sources(people.collect(), projects.collect())
    }

    pub fn from_sources(people: Vec<LinkSource>, projects: Vec<LinkSource>) -> Self {
        let mut links = Self::default();
        for person in people.into_iter().filter(|p| !p.references.is_empty()) {
            let index = links.people.len();
            for member in person.aliases.iter().filter(|m| **m != person.id) {
                links
                    .person_aliases
                    .insert(member.clone(), person.id.clone());
            }
            for reference in person.references {
                links
                    .people_by_reference
                    .entry(reference)
                    .or_default()
                    .push(index);
            }
            links.people.push(Link {
                id: person.id,
                name: person.name,
            });
        }
        // Projects the user tracks lead; suggested ones follow.
        let (tracked, suggested): (Vec<_>, Vec<_>) =
            projects.into_iter().partition(|project| project.tracked);
        for project in tracked
            .into_iter()
            .chain(suggested)
            .filter(|p| !p.references.is_empty())
        {
            let index = links.projects.len();
            for reference in project.references {
                links
                    .projects_by_reference
                    .entry(reference)
                    .or_default()
                    .push(index);
            }
            links.projects.push(Link {
                id: project.id,
                name: project.name,
            });
        }
        links
    }

    fn links_for<'a>(
        thread: &ActionThread,
        list: &'a [Link],
        by_reference: &HashMap<String, Vec<usize>>,
    ) -> Vec<&'a Link> {
        let mut indexes: Vec<usize> = thread
            .references
            .iter()
            .filter_map(|r| by_reference.get(&r.id))
            .flatten()
            .copied()
            .collect();
        indexes.sort_unstable();
        indexes.dedup();
        indexes.into_iter().filter_map(|ix| list.get(ix)).collect()
    }

    pub fn people_for(&self, thread: &ActionThread) -> Vec<&Link> {
        Self::links_for(thread, &self.people, &self.people_by_reference)
    }

    pub fn projects_for(&self, thread: &ActionThread) -> Vec<&Link> {
        Self::links_for(thread, &self.projects, &self.projects_by_reference)
    }

    fn person_id<'a>(&'a self, id: &'a str) -> &'a str {
        self.person_aliases.get(id).map_or(id, String::as_str)
    }

    pub fn person_name(&self, id: &str) -> Option<&str> {
        let id = self.person_id(id);
        self.people
            .iter()
            .find(|p| p.id == id)
            .map(|p| p.name.as_str())
    }

    pub fn project_name(&self, id: &str) -> Option<&str> {
        self.projects
            .iter()
            .find(|p| p.id == id)
            .map(|p| p.name.as_str())
    }

    pub fn is_with(&self, thread: &ActionThread, person_id: &str) -> bool {
        let id = self.person_id(person_id);
        self.people_for(thread).iter().any(|p| p.id == id)
    }

    pub fn is_in(&self, thread: &ActionThread, project_id: &str) -> bool {
        self.projects_for(thread).iter().any(|p| p.id == project_id)
    }
}

// ---------------------------------------------------------------- wording

fn format_day(date: NaiveDate, pattern: &str) -> String {
    date.format_localized(
        lokalbot_i18n::date_pattern(pattern),
        lokalbot_i18n::date_locale(),
    )
    .to_string()
}

/// "Thu, Nov 12".
pub(super) fn weekday_date(date: NaiveDate) -> String {
    format_day(date, "%a, %b %-d")
}

/// "Today", "Yesterday", "Fri, Nov 6" for the rest of the past week, then
/// "Oct 27", with the year once it is not this year.
pub(super) fn day_label(date: NaiveDate, today: NaiveDate) -> String {
    match (today - date).num_days() {
        0 => lokalbot_i18n::tr("Today").to_string(),
        1 => lokalbot_i18n::tr("Yesterday").to_string(),
        2..=6 => weekday_date(date),
        _ if date.year() == today.year() => format_day(date, "%b %-d"),
        _ => format_day(date, "%b %-d, %Y"),
    }
}

/// [`day_label`] for a moment, on its local day.
pub(super) fn day(at: DateTime<Utc>, today: NaiveDate) -> String {
    day_label(lokalbot_core::time::local_day(at), today)
}

/// The due words on a row and how they read.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct DueLabel {
    pub text: String,
    pub tone: DueTone,
}

/// The due text on a row. Overdue open work reads as "Was due", due today or
/// within the week keeps the amber tone, and a later date, a phrase that
/// names no day, and work that is no longer open stay quiet. The Done list
/// shows when the action was completed instead.
pub(super) fn due_label(
    thread: &ActionThread,
    listing: ActionStatus,
    today: NaiveDate,
) -> Option<DueLabel> {
    if listing == ActionStatus::Done && thread.status() == ActionStatus::Done {
        return Some(DueLabel {
            text: fill(
                lokalbot_i18n::tr("Done %@"),
                &[&day(completion_date(thread), today)],
            ),
            tone: DueTone::Calm,
        });
    }
    let phrase = thread
        .due
        .as_deref()
        .map(str::trim)
        .filter(|p| !p.is_empty())?;
    let Some(date) = thread.resolved_due_date else {
        return Some(DueLabel {
            text: fill(lokalbot_i18n::tr("Due “%@”"), &[phrase]),
            tone: DueTone::Calm,
        });
    };
    let open = thread.status() == ActionStatus::Open;
    let days_ahead = (date - today).num_days();
    if days_ahead < 0 && open {
        return Some(DueLabel {
            text: fill(lokalbot_i18n::tr("Was due %@"), &[&weekday_date(date)]),
            tone: DueTone::Overdue,
        });
    }
    let window = lokalbot_core::actions::DUE_SOON_WINDOW_DAYS as i64;
    let tone = if open && (0..=window).contains(&days_ahead) {
        DueTone::Soon
    } else {
        DueTone::Calm
    };
    let text = match days_ahead {
        0 => lokalbot_i18n::tr("Due today").to_string(),
        1 => lokalbot_i18n::tr("Due tomorrow").to_string(),
        _ => fill(lokalbot_i18n::tr("Due %@"), &[&weekday_date(date)]),
    };
    Some(DueLabel { text, tone })
}

/// When the action's last mention was marked done.
pub(super) fn completion_date(thread: &ActionThread) -> DateTime<Utc> {
    thread
        .references
        .iter()
        .filter(|r| r.status == ActionStatus::Done)
        .map(|r| r.state_updated_at)
        .max()
        .unwrap_or(thread.latest().state_updated_at)
}

/// "Design review meeting", or "In 2 meetings" for an action said twice.
pub(super) fn source(thread: &ActionThread) -> String {
    if thread.meeting_count() > 1 {
        fill(
            lokalbot_i18n::tr("In %lld meetings"),
            &[&lokalbot_i18n::number(thread.meeting_count())],
        )
    } else {
        thread.latest().meeting_title.clone()
    }
}

/// Under a meeting heading the row only says where else it was said.
pub(super) fn other_meetings(thread: &ActionThread) -> String {
    match thread.meeting_count().saturating_sub(1) {
        0 => String::new(),
        1 => lokalbot_i18n::tr("Also in 1 other meeting").to_string(),
        others => fill(
            lokalbot_i18n::tr("Also in %lld other meetings"),
            &[&lokalbot_i18n::number(others)],
        ),
    }
}

/// "8 open actions haven’t been mentioned in 3 weeks."
pub(super) fn stale_summary(count: usize) -> String {
    if count == 1 {
        lokalbot_i18n::tr("1 open action hasn’t been mentioned in 3 weeks.").to_string()
    } else {
        fill(
            lokalbot_i18n::tr("%lld open actions haven’t been mentioned in 3 weeks."),
            &[&lokalbot_i18n::number(count)],
        )
    }
}

pub(super) fn empty_text(filter: &ListFilter) -> &'static str {
    match (filter.status, filter.narrows_list()) {
        (ActionStatus::Open, true) => lokalbot_i18n::tr("No open actions match these filters."),
        (ActionStatus::Deferred, true) => {
            lokalbot_i18n::tr("No deferred actions match these filters.")
        }
        (ActionStatus::Done, true) => lokalbot_i18n::tr("No done actions match these filters."),
        (ActionStatus::Open, false) => {
            lokalbot_i18n::tr("Nothing open. Actions from new meetings show up here.")
        }
        (ActionStatus::Deferred, false) => lokalbot_i18n::tr("Nothing deferred."),
        (ActionStatus::Done, false) => lokalbot_i18n::tr("Nothing done yet."),
    }
}

/// "Mon 5:48 PM", when the screen showed the cue.
fn hint_time(hint: &CompletionHint) -> String {
    let at = hint.captured_at.with_timezone(&Local);
    let locale = lokalbot_i18n::date_locale();
    format!(
        "{} {}",
        at.format_localized("%a", locale),
        at.format_localized(lokalbot_i18n::date_pattern("%-I:%M %p"), locale)
    )
}

/// "Mail showed “Message sent” · Mon 5:48 PM" beside "Looks done?" on a row.
pub(super) fn completion_hint(hint: &CompletionHint) -> String {
    format!(
        "{} · {}",
        fill(
            lokalbot_i18n::tr("%1$@ showed “%2$@”"),
            &[&hint.app, &hint.cue]
        ),
        hint_time(hint)
    )
}

/// The same evidence as a sentence, for the details pane.
pub(super) fn completion_hint_sentence(hint: &CompletionHint) -> String {
    fill(
        lokalbot_i18n::tr("%1$@ showed “%2$@” on %3$@, after this was said."),
        &[&hint.app, &hint.cue, &hint_time(hint)],
    )
}

// ------------------------------------------------------------- controls

/// How the row of controls above the list arranges itself in its width
/// (`ActionsFilterBar`'s `ViewThatFits`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum BarLayout {
    /// Status, Filter, the chips and the search field on one row.
    OneRow,
    /// The chips on a row of their own under the others.
    ChipsBelow,
    /// The search field on a row of its own as well.
    SearchBelow,
}

/// Chooses the first arrangement whose rows fit in `width`; widths are the
/// controls' own, without the bar's 16-point sides and 8-point gaps.
pub(super) fn filter_bar_layout(
    width: f32,
    status: f32,
    filter: f32,
    chips: &[f32],
    search: f32,
) -> BarLayout {
    const SIDES: f32 = 32.;
    const GAP: f32 = 8.;
    let controls = SIDES + status + GAP + filter;
    let chips_width: f32 = chips.iter().map(|chip| chip + GAP).sum();
    if controls + chips_width + GAP + search <= width {
        BarLayout::OneRow
    } else if controls + GAP + search <= width {
        BarLayout::ChipsBelow
    } else {
        BarLayout::SearchBelow
    }
}

// ------------------------------------------------------------------- list

/// One listed thread with its wording made.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct Row {
    /// Position in the threads the list was built from.
    pub thread: usize,
    pub id: String,
    /// The meeting it came from, with a day where the group does not already
    /// give one. Empty under a meeting heading.
    pub source: String,
    pub due: Option<DueLabel>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct Section {
    pub id: String,
    /// `None` for a list without headings.
    pub title: Option<String>,
    pub is_late: bool,
    pub rows: Vec<Row>,
}

/// The list as it is drawn: filtered, ordered and grouped threads with each
/// row's wording already made, so rows do no work of their own
/// (`ActionsListContent`).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(super) struct ListContent {
    pub sections: Vec<Section>,
    /// Row ids from top to bottom, for the arrow keys and range selection.
    pub order: Vec<String>,
    /// The user's open actions, whatever the list is showing.
    pub open_count: usize,
    /// Open actions the stale review would list.
    pub stale_count: usize,
    /// Meeting titles the user's actions came from, newest first.
    pub meeting_titles: Vec<String>,
    rows_by_id: HashMap<String, (usize, usize)>,
}

/// Overdue, due within the week, then later or undated (`ActionAttentionOrder.Bucket`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub(super) enum Bucket {
    Overdue,
    Soon,
    Later,
}

/// A due phrase that names no day counts as no date.
pub(super) fn bucket(thread: &ActionThread, today: NaiveDate) -> Bucket {
    let Some(due) = thread.resolved_due_date else {
        return Bucket::Later;
    };
    let window = lokalbot_core::actions::DUE_SOON_WINDOW_DAYS as i64;
    if due < today {
        Bucket::Overdue
    } else if (due - today).num_days() <= window {
        Bucket::Soon
    } else {
        Bucket::Later
    }
}

fn same_title(a: &str, b: &str) -> bool {
    lokalbot_core::ids::fold(a) == lokalbot_core::ids::fold(b)
}

impl ListContent {
    pub fn is_empty(&self) -> bool {
        self.order.is_empty()
    }

    pub fn row(&self, id: &str) -> Option<&Row> {
        let (section, row) = *self.rows_by_id.get(id)?;
        self.sections.get(section)?.rows.get(row)
    }

    /// `kept`: threads whose status the user just changed in this view. They
    /// stay listed until the view or its filters change, so a ticked row does
    /// not vanish under the pointer.
    pub fn build(
        threads: &[ActionThread],
        filter: &ListFilter,
        links: &ThreadLinks,
        kept: &HashSet<String>,
        today: NaiveDate,
    ) -> Self {
        let named_with_day = |thread: &ActionThread| {
            format!(
                "{} · {}",
                source(thread),
                day(thread.latest().meeting_started_at, today)
            )
        };
        let row = |index: usize, source: String| Row {
            thread: index,
            id: threads[index].id.clone(),
            source,
            due: due_label(&threads[index], filter.status, today),
        };
        let newest_first = |mut indexes: Vec<usize>| {
            // Stable: threads from the same moment keep their order.
            indexes.sort_by(|a, b| {
                threads[*b]
                    .latest()
                    .meeting_started_at
                    .cmp(&threads[*a].latest().meeting_started_at)
            });
            indexes
        };
        let by_attention = |indexes: Vec<usize>| {
            let mut indexes = newest_first(indexes);
            indexes.sort_by(|a, b| {
                let (left, right) = (&threads[*a], &threads[*b]);
                let (first, second) = (bucket(left, today), bucket(right, today));
                first.cmp(&second).then_with(|| {
                    match (first, left.resolved_due_date, right.resolved_due_date) {
                        (Bucket::Overdue | Bucket::Soon, Some(x), Some(y)) => x.cmp(&y),
                        _ => std::cmp::Ordering::Equal,
                    }
                })
            });
            indexes
        };

        let mut content = ListContent {
            open_count: threads
                .iter()
                .filter(|t| t.status() == ActionStatus::Open)
                .count(),
            stale_count: threads.iter().filter(|t| t.is_stale(today)).count(),
            meeting_titles: meeting_titles(threads),
            ..Default::default()
        };
        let listed: Vec<usize> = (0..threads.len())
            .filter(|ix| {
                kept.contains(&threads[*ix].id) || matches(&threads[*ix], filter, links, today)
            })
            .collect();

        let mut sections: Vec<Section> = Vec::new();
        let mut add = |id: String, title: Option<String>, rows: Vec<Row>, is_late: bool| {
            if !rows.is_empty() {
                sections.push(Section {
                    id,
                    title,
                    is_late,
                    rows,
                });
            }
        };
        match filter.status {
            ActionStatus::Open if filter.is_stale_review() => {
                let rows = newest_first(listed)
                    .into_iter()
                    .map(|ix| {
                        let thread = &threads[ix];
                        let last = fill(
                            lokalbot_i18n::tr("last mentioned %@"),
                            &[&day(thread.latest().meeting_started_at, today)],
                        );
                        row(ix, format!("{} · {last}", source(thread)))
                    })
                    .collect();
                add(
                    "stale".into(),
                    Some(lokalbot_i18n::tr("Still open?").into()),
                    rows,
                    false,
                );
            }
            ActionStatus::Open => {
                let ordered = by_attention(listed);
                match filter.grouping {
                    Grouping::Due => {
                        let rows = |wanted: Bucket, with_day: bool| -> Vec<Row> {
                            ordered
                                .iter()
                                .copied()
                                .filter(|ix| bucket(&threads[*ix], today) == wanted)
                                .map(|ix| {
                                    let thread = &threads[ix];
                                    let text = if with_day {
                                        named_with_day(thread)
                                    } else {
                                        source(thread)
                                    };
                                    row(ix, text)
                                })
                                .collect()
                        };
                        let (overdue, soon, later) = (
                            rows(Bucket::Overdue, false),
                            rows(Bucket::Soon, false),
                            rows(Bucket::Later, true),
                        );
                        add(
                            "overdue".into(),
                            Some(lokalbot_i18n::tr("Overdue").into()),
                            overdue,
                            true,
                        );
                        add(
                            "soon".into(),
                            Some(lokalbot_i18n::tr("Next 7 days").into()),
                            soon,
                            false,
                        );
                        add(
                            "later".into(),
                            Some(lokalbot_i18n::tr("Later or no date").into()),
                            later,
                            false,
                        );
                    }
                    Grouping::Meeting => {
                        let mut meetings: Vec<Uuid> = Vec::new();
                        let mut by_meeting: HashMap<Uuid, Vec<usize>> = HashMap::new();
                        for ix in newest_first(ordered) {
                            let id = threads[ix].latest().meeting_id;
                            if !by_meeting.contains_key(&id) {
                                meetings.push(id);
                            }
                            by_meeting.entry(id).or_default().push(ix);
                        }
                        for id in meetings {
                            let Some(group) = by_meeting.remove(&id) else {
                                continue;
                            };
                            let first = threads[group[0]].latest();
                            let title = format!(
                                "{} · {}",
                                first.meeting_title,
                                day(first.meeting_started_at, today)
                            );
                            let rows = by_attention(group)
                                .into_iter()
                                .map(|ix| row(ix, other_meetings(&threads[ix])))
                                .collect();
                            add(format!("meeting-{id}"), Some(title), rows, false);
                        }
                    }
                    Grouping::None => {
                        let rows = ordered
                            .into_iter()
                            .map(|ix| row(ix, named_with_day(&threads[ix])))
                            .collect();
                        add("all".into(), None, rows, false);
                    }
                }
            }
            ActionStatus::Done => {
                let cutoff = today - chrono::Days::new((RECENTLY_DONE_DAYS - 1) as u64);
                let mut dated: Vec<(usize, DateTime<Utc>)> = listed
                    .into_iter()
                    .map(|ix| (ix, completion_date(&threads[ix])))
                    .collect();
                // Threads done at the same moment keep their list order.
                dated.sort_by_key(|item| std::cmp::Reverse(item.1));
                let (mut recent, mut earlier) = (Vec::new(), Vec::new());
                for (ix, date) in dated {
                    let entry = row(ix, source(&threads[ix]));
                    if lokalbot_core::time::local_day(date) >= cutoff {
                        recent.push(entry);
                    } else {
                        earlier.push(entry);
                    }
                }
                add(
                    "recent".into(),
                    Some(lokalbot_i18n::tr("Last 7 days").into()),
                    recent,
                    false,
                );
                add(
                    "earlier".into(),
                    Some(lokalbot_i18n::tr("Earlier").into()),
                    earlier,
                    false,
                );
            }
            ActionStatus::Deferred => {
                let rows = newest_first(listed)
                    .into_iter()
                    .map(|ix| row(ix, named_with_day(&threads[ix])))
                    .collect();
                add("all".into(), None, rows, false);
            }
        }

        for (section_ix, section) in sections.iter().enumerate() {
            for (row_ix, row) in section.rows.iter().enumerate() {
                content.order.push(row.id.clone());
                content
                    .rows_by_id
                    .entry(row.id.clone())
                    .or_insert((section_ix, row_ix));
            }
        }
        content.sections = sections;
        content
    }
}

/// Whether the filter lists this thread, before the rows the user just
/// changed are added back.
pub(super) fn matches(
    thread: &ActionThread,
    filter: &ListFilter,
    links: &ThreadLinks,
    today: NaiveDate,
) -> bool {
    if thread.status() != filter.status {
        return false;
    }
    let due_matches = match filter.due {
        DueFilter::Any => true,
        DueFilter::Overdue => thread.resolved_due_date.is_some_and(|due| due < today),
        DueFilter::Dated => thread.resolved_due_date.is_some(),
        DueFilter::Undated => thread.resolved_due_date.is_none(),
    };
    if !due_matches {
        return false;
    }
    if let Some(person) = &filter.person_id
        && !links.is_with(thread, person)
    {
        return false;
    }
    if let Some(project) = &filter.project_id
        && !links.is_in(thread, project)
    {
        return false;
    }
    if let Some(title) = &filter.meeting_title
        && !thread
            .references
            .iter()
            .any(|r| same_title(&r.meeting_title, title))
    {
        return false;
    }
    if filter.is_stale_review() && !thread.is_stale(today) {
        return false;
    }
    let needle = filter.trimmed_query().to_lowercase();
    if needle.is_empty() {
        return true;
    }
    thread.text.to_lowercase().contains(&needle)
        || thread
            .due
            .as_deref()
            .is_some_and(|due| due.to_lowercase().contains(&needle))
        || thread
            .references
            .iter()
            .any(|r| r.meeting_title.to_lowercase().contains(&needle))
}

fn meeting_titles(threads: &[ActionThread]) -> Vec<String> {
    let mut references: Vec<_> = threads.iter().flat_map(|t| t.references.iter()).collect();
    references.sort_by_key(|r| std::cmp::Reverse(r.meeting_started_at));
    let mut titles: Vec<String> = Vec::new();
    for reference in references {
        if titles.len() == MAXIMUM_MEETING_CHOICES {
            break;
        }
        if !titles
            .iter()
            .any(|t| same_title(t, &reference.meeting_title))
        {
            titles.push(reference.meeting_title.clone());
        }
    }
    titles
}

// -------------------------------------------------------------- selection

/// Which rows the list acts on (`ActionListSelection`). One row is always
/// current, as in a mail list: the chosen rows that are still listed, or else
/// the first row. Ctrl-click adds or removes a row and Shift-click takes a
/// range.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(super) struct Selection {
    pub chosen: HashSet<String>,
    /// Where a Shift range starts.
    pub anchor: Option<String>,
    /// The row the arrow keys move from.
    pub lead: Option<String>,
}

impl Selection {
    pub fn current(&self, order: &[String]) -> Vec<String> {
        let listed: Vec<String> = order
            .iter()
            .filter(|id| self.chosen.contains(*id))
            .cloned()
            .collect();
        if listed.is_empty() {
            order.iter().take(1).cloned().collect()
        } else {
            listed
        }
    }

    fn range_start(&self, order: &[String]) -> Option<String> {
        self.anchor
            .clone()
            .filter(|a| order.contains(a))
            .or_else(|| self.current(order).first().cloned())
    }

    pub fn click(&mut self, id: &str, add: bool, range: bool, order: &[String]) {
        let span = range
            .then(|| self.range_start(order))
            .flatten()
            .and_then(|start| {
                let from = order.iter().position(|o| *o == start)?;
                let to = order.iter().position(|o| o == id)?;
                Some((start, from.min(to), from.max(to)))
            });
        if let Some((start, low, high)) = span {
            self.chosen = order[low..=high].iter().cloned().collect();
            self.anchor = Some(start);
        } else if add {
            let mut next: HashSet<String> = self.current(order).into_iter().collect();
            if !next.remove(id) {
                next.insert(id.to_string());
            }
            // The last row cannot be deselected: one row is always current.
            if next.is_empty() {
                next.insert(id.to_string());
            }
            self.chosen = next;
            self.anchor = Some(id.to_string());
        } else {
            self.chosen = HashSet::from([id.to_string()]);
            self.anchor = Some(id.to_string());
        }
        self.lead = Some(id.to_string());
    }

    /// Moves up or down one row and returns the row to keep in view.
    pub fn step(&mut self, by: isize, extending: bool, order: &[String]) -> Option<String> {
        let current = self.current(order);
        let start = self
            .lead
            .clone()
            .filter(|l| current.contains(l))
            .or_else(|| {
                if by > 0 {
                    current.last().cloned()
                } else {
                    current.first().cloned()
                }
            })?;
        let from = order.iter().position(|o| *o == start)?;
        let to = from
            .saturating_add_signed(by)
            .min(order.len().saturating_sub(1));
        if extending {
            let range_start = self.range_start(order).unwrap_or(start);
            if let Some(first) = order.iter().position(|o| *o == range_start) {
                self.chosen = order[first.min(to)..=first.max(to)]
                    .iter()
                    .cloned()
                    .collect();
                self.anchor = Some(range_start);
            }
        } else {
            self.chosen = HashSet::from([order[to].clone()]);
            self.anchor = Some(order[to].clone());
        }
        self.lead = Some(order[to].clone());
        self.lead.clone()
    }

    pub fn select_all(&mut self, order: &[String]) {
        if order.is_empty() {
            return;
        }
        self.chosen = order.iter().cloned().collect();
        self.anchor = order.first().cloned();
        self.lead = order.last().cloned();
    }

    /// Back to one row: the one the keyboard was on, or the first chosen.
    pub fn collapse(&mut self, order: &[String]) {
        let current = self.current(order);
        let Some(keep) = self
            .lead
            .clone()
            .filter(|l| current.contains(l))
            .or_else(|| current.first().cloned())
        else {
            return;
        };
        self.chosen = HashSet::from([keep.clone()]);
        self.anchor = Some(keep.clone());
        self.lead = Some(keep);
    }
}

// ---------------------------------------------------------------- details

/// "2026-11-12": a day someone chose rather than said.
fn is_explicit_date(phrase: &str) -> bool {
    let phrase = phrase.trim();
    phrase.len() == 10 && NaiveDate::parse_from_str(phrase, "%Y-%m-%d").is_ok()
}

/// The Due control: the resolved day, "Pick a date" for a phrase that names
/// no day, or "No date".
pub(super) fn due_title(thread: &ActionThread) -> String {
    match thread.resolved_due_date {
        Some(date) => weekday_date(date),
        None if thread.due.is_none() => lokalbot_i18n::tr("No date").to_string(),
        None => lokalbot_i18n::tr("Pick a date").to_string(),
    }
}

/// Due phrases as they were said, newest meeting first, without the days
/// someone typed in.
pub(super) fn said_due_phrases(thread: &ActionThread) -> Vec<String> {
    let mut phrases: Vec<String> = Vec::new();
    for phrase in thread
        .references
        .iter()
        .filter_map(|r| r.action.due.as_deref())
        .map(str::trim)
        .filter(|p| !p.is_empty() && !is_explicit_date(p))
    {
        if !phrases
            .iter()
            .any(|known| known.to_lowercase() == phrase.to_lowercase())
        {
            phrases.push(phrase.to_string());
        }
    }
    phrases
}

/// "You said “by Thursday”. Before that, “next week”."
pub(super) fn due_note(thread: &ActionThread) -> Option<String> {
    let phrases = said_due_phrases(thread);
    let latest = phrases.first()?;
    let mut note = fill(lokalbot_i18n::tr("You said “%@”."), &[latest]);
    if let Some(before) = phrases.get(1) {
        note.push(' ');
        note.push_str(&fill(lokalbot_i18n::tr("Before that, “%@”."), &[before]));
    }
    Some(note)
}

/// "Said in 2 meetings", or "What was said" for one meeting.
pub(super) fn mentions_heading(thread: &ActionThread) -> String {
    if thread.meeting_count() > 1 {
        fill(
            lokalbot_i18n::tr("Said in %lld meetings"),
            &[&lokalbot_i18n::number(thread.meeting_count())],
        )
    } else {
        lokalbot_i18n::tr("What was said").to_string()
    }
}

/// One saved correction of one meeting's action.
#[derive(Clone, Debug, PartialEq)]
pub(super) struct Correction {
    pub meeting_id: Uuid,
    pub action_id: String,
    pub change: ActionCorrection,
}

/// A due day chosen in the details pane, or none. It is saved on the newest
/// mention, whose correction a thread takes as its due date. Text and owner
/// keep whatever they are.
pub(super) fn due_correction(date: Option<NaiveDate>, thread: &ActionThread) -> Correction {
    let latest = thread.latest();
    Correction {
        meeting_id: latest.meeting_id,
        action_id: latest.action_id.clone(),
        change: ActionCorrection {
            due: Some(date.map(|d| d.format("%Y-%m-%d").to_string())),
            ..Default::default()
        },
    }
}

/// "Not mine": every mention of the user's loses its owner, so the action
/// leaves the user's list in each meeting it was said in.
pub(super) fn not_mine_corrections(thread: &ActionThread) -> Vec<Correction> {
    thread
        .references
        .iter()
        .filter(|r| r.is_for_user)
        .map(|r| Correction {
            meeting_id: r.meeting_id,
            action_id: r.action_id.clone(),
            change: ActionCorrection {
                owner: Some(None),
                ..Default::default()
            },
        })
        .collect()
}

/// The threads a status change actually changes.
pub(super) fn changing(threads: Vec<ActionThread>, status: ActionStatus) -> Vec<ActionThread> {
    threads
        .into_iter()
        .filter(|t| t.status() != status || t.is_mixed())
        .collect()
}

/// Titles of the meetings a change reaches beyond one meeting, each meeting
/// once, for the question asked first.
pub(super) fn confirmation_meetings(threads: &[ActionThread]) -> Vec<String> {
    let mut seen: HashSet<Uuid> = HashSet::new();
    threads
        .iter()
        .filter(|t| t.meeting_count() > 1)
        .flat_map(|t| t.references.iter())
        .filter(|r| seen.insert(r.meeting_id))
        .map(|r| r.meeting_title.clone())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::{reference, thread};
    use chrono::TimeZone as _;

    fn day_of(d: u32) -> NaiveDate {
        NaiveDate::from_ymd_opt(2026, 10, d).unwrap()
    }

    fn today() -> NaiveDate {
        day_of(30)
    }

    fn open(id: &str, due: Option<NaiveDate>, started: u32) -> ActionThread {
        thread(vec![reference(id, ActionStatus::Open, true, due, started)])
    }

    fn ids(content: &ListContent) -> Vec<Vec<String>> {
        content
            .sections
            .iter()
            .map(|s| s.rows.iter().map(|r| r.id.clone()).collect())
            .collect()
    }

    fn titles(content: &ListContent) -> Vec<Option<String>> {
        content.sections.iter().map(|s| s.title.clone()).collect()
    }

    fn build(threads: &[ActionThread], filter: &ListFilter) -> ListContent {
        ListContent::build(
            threads,
            filter,
            &ThreadLinks::default(),
            &HashSet::new(),
            today(),
        )
    }

    #[test]
    fn open_work_reads_overdue_then_next_week_then_the_rest_newest_first() {
        let threads = vec![
            open("later-old", None, 20),
            open("soon-2", Some(day_of(31)), 10),
            open("late", Some(day_of(28)), 5),
            open(
                "later-new",
                Some(NaiveDate::from_ymd_opt(2026, 11, 20).unwrap()),
                29,
            ),
            open("soon-1", Some(day_of(30)), 12),
        ];
        let content = build(&threads, &ListFilter::default());
        assert_eq!(
            titles(&content),
            [
                Some("Overdue".into()),
                Some("Next 7 days".into()),
                Some("Later or no date".into())
            ]
        );
        assert!(content.sections[0].is_late);
        let thread_ids = |names: &[&str]| -> Vec<String> {
            names
                .iter()
                .map(|n| {
                    threads
                        .iter()
                        .find(|t| t.text == format!("Do {n}"))
                        .unwrap()
                        .id
                        .clone()
                })
                .collect()
        };
        assert_eq!(
            ids(&content),
            [
                thread_ids(&["late"]),
                thread_ids(&["soon-1", "soon-2"]),
                thread_ids(&["later-new", "later-old"])
            ]
        );
        // Later rows name their day; the dated groups do not.
        assert_eq!(content.sections[0].rows[0].source, "Meeting 5");
        assert_eq!(content.sections[2].rows[1].source, "Meeting 20 · Oct 20");
        assert_eq!(content.open_count, 5);
        assert_eq!(content.order.len(), 5);
    }

    #[test]
    fn due_words_follow_the_mac() {
        let at = |due| due_label(&open("a", Some(due), 20), ActionStatus::Open, today());
        assert_eq!(
            at(day_of(28)),
            Some(DueLabel {
                text: "Was due Wed, Oct 28".into(),
                tone: DueTone::Overdue
            })
        );
        assert_eq!(at(day_of(30)).unwrap().text, "Due today");
        assert_eq!(at(day_of(31)).unwrap().text, "Due tomorrow");
        assert_eq!(at(day_of(31)).unwrap().tone, DueTone::Soon);
        let later = at(NaiveDate::from_ymd_opt(2026, 11, 7).unwrap()).unwrap();
        assert_eq!(later.text, "Due Sat, Nov 7");
        assert_eq!(later.tone, DueTone::Calm);
        // A phrase that names no day keeps its words.
        let mut vague = open("b", None, 20);
        vague.due = Some(" after the offsite ".into());
        assert_eq!(
            due_label(&vague, ActionStatus::Open, today()).unwrap().text,
            "Due “after the offsite”"
        );
        // Deferred work is never late.
        let deferred = thread(vec![reference(
            "c",
            ActionStatus::Deferred,
            true,
            Some(day_of(1)),
            1,
        )]);
        let label = due_label(&deferred, ActionStatus::Deferred, today()).unwrap();
        assert_eq!(
            (label.text.as_str(), label.tone),
            ("Due Thu, Oct 1", DueTone::Calm)
        );
        assert_eq!(
            due_label(&open("d", None, 3), ActionStatus::Open, today()),
            None
        );
    }

    #[test]
    fn the_done_list_says_when_and_splits_the_last_week() {
        let mut recent = reference("recent", ActionStatus::Done, true, None, 2);
        recent.state_updated_at = Utc.with_ymd_and_hms(2026, 10, 29, 12, 0, 0).unwrap();
        let mut old = reference("old", ActionStatus::Done, true, None, 3);
        old.state_updated_at = Utc.with_ymd_and_hms(2026, 10, 10, 12, 0, 0).unwrap();
        let threads = vec![thread(vec![old]), thread(vec![recent]), open("o", None, 4)];
        let filter = ListFilter {
            status: ActionStatus::Done,
            ..Default::default()
        };
        let content = build(&threads, &filter);
        assert_eq!(
            titles(&content),
            [Some("Last 7 days".into()), Some("Earlier".into())]
        );
        assert_eq!(content.sections[0].rows[0].id, threads[1].id);
        assert_eq!(
            content.sections[0].rows[0].due.as_ref().unwrap().text,
            "Done Yesterday"
        );
        assert_eq!(
            content.sections[1].rows[0].due.as_ref().unwrap().text,
            "Done Oct 10"
        );
    }

    #[test]
    fn stale_review_and_meeting_groups_name_their_source() {
        let threads = vec![
            open("old", None, 2),
            open("fresh", None, 29),
            thread(vec![
                reference("twice", ActionStatus::Open, true, None, 28),
                reference("twice", ActionStatus::Open, true, None, 20),
            ]),
        ];
        let stale = ListFilter {
            stale_only: true,
            ..Default::default()
        };
        let content = build(&threads, &stale);
        assert_eq!(content.stale_count, 1);
        assert_eq!(titles(&content), [Some("Still open?".into())]);
        assert_eq!(
            content.sections[0].rows[0].source,
            "Meeting 2 · last mentioned Oct 2"
        );

        let by_meeting = ListFilter {
            grouping: Grouping::Meeting,
            ..Default::default()
        };
        let content = build(&threads, &by_meeting);
        assert_eq!(
            titles(&content),
            [
                Some("Meeting 29 · Yesterday".into()),
                Some("Meeting 28 · Wed, Oct 28".into()),
                Some("Meeting 2 · Oct 2".into())
            ]
        );
        assert_eq!(
            content.sections[1].rows[0].source,
            "Also in 1 other meeting"
        );
        assert_eq!(content.sections[0].rows[0].source, "");

        let flat = ListFilter {
            grouping: Grouping::None,
            ..Default::default()
        };
        let content = build(&threads, &flat);
        assert_eq!(titles(&content), [None]);
        assert_eq!(
            content.sections[0].rows[1].source,
            "In 2 meetings · Wed, Oct 28"
        );
    }

    #[test]
    fn filters_narrow_and_kept_rows_stay() {
        let mut said = open("phrase", None, 10);
        said.due = Some("next sprint".into());
        let threads = vec![
            open("late", Some(day_of(1)), 3),
            open("undated", None, 4),
            said,
            thread(vec![reference("done", ActionStatus::Done, true, None, 5)]),
        ];
        let listed = |filter: &ListFilter, kept: &HashSet<String>| -> Vec<String> {
            ListContent::build(&threads, filter, &ThreadLinks::default(), kept, today()).order
        };
        let none = HashSet::new();
        let overdue = ListFilter {
            due: DueFilter::Overdue,
            ..Default::default()
        };
        assert_eq!(listed(&overdue, &none), [threads[0].id.clone()]);
        let undated = ListFilter {
            due: DueFilter::Undated,
            ..Default::default()
        };
        assert_eq!(
            listed(&undated, &none).len(),
            2,
            "a phrase without a day is undated"
        );
        let search = ListFilter {
            query: "  SPRINT ".into(),
            ..Default::default()
        };
        assert_eq!(listed(&search, &none), [threads[2].id.clone()]);
        let meeting = ListFilter {
            meeting_title: Some("meeting 4".into()),
            ..Default::default()
        };
        assert_eq!(listed(&meeting, &none), [threads[1].id.clone()]);
        // A row just marked done stays in the open list until the view changes.
        let kept = HashSet::from([threads[3].id.clone()]);
        assert!(listed(&ListFilter::default(), &kept).contains(&threads[3].id));
        assert!(!listed(&ListFilter::default(), &none).contains(&threads[3].id));
    }

    #[test]
    fn chips_follow_the_menu_and_leaving_open_drops_what_cannot_apply() {
        let links = ThreadLinks::from_sources(
            vec![LinkSource {
                id: "person-a".into(),
                name: "Ana Petrović".into(),
                aliases: vec!["person-old".into()],
                references: HashSet::from(["x".to_string()]),
                tracked: false,
            }],
            Vec::new(),
        );
        let mut filter = ListFilter {
            due: DueFilter::Dated,
            person_id: Some("person-old".into()),
            meeting_title: Some("Standup".into()),
            stale_only: true,
            ..Default::default()
        };
        let labels: Vec<String> = filter.chips(&links).into_iter().map(|c| c.label).collect();
        assert_eq!(
            labels,
            [
                "Has a date",
                "With Ana Petrović",
                "From Standup",
                "Not mentioned in 3 weeks"
            ]
        );
        assert!(filter.narrows_list());
        filter.remove(ChipKind::Meeting);
        assert_eq!(filter.meeting_title, None);
        filter.show(ActionStatus::Done);
        assert!(!filter.stale_only);
        assert_eq!(filter.person_id, None);
        assert_eq!(filter.due, DueFilter::Dated, "the due choice stays");
        filter.clear_filters();
        assert!(!filter.narrows_list());
        assert_eq!(empty_text(&filter), "Nothing done yet.");
    }

    #[test]
    fn links_find_people_and_projects_by_reference_tracked_first() {
        let a = thread(vec![
            reference("a", ActionStatus::Open, true, None, 5),
            reference("a", ActionStatus::Open, true, None, 4),
        ]);
        let older_id = a.references[1].id.clone();
        let source = |id: &str, tracked: bool, refs: &[&str]| LinkSource {
            id: id.into(),
            name: id.to_uppercase(),
            aliases: Vec::new(),
            references: refs.iter().map(|r| r.to_string()).collect(),
            tracked,
        };
        let links = ThreadLinks::from_sources(
            vec![
                source("maya", false, &[&older_id]),
                source("nobody", false, &[]),
            ],
            vec![
                source("topic", false, &[&older_id]),
                source("atlas", true, &[&older_id]),
            ],
        );
        assert_eq!(
            links.people.len(),
            1,
            "people without the user's work are left out"
        );
        let people: Vec<&str> = links.people_for(&a).iter().map(|l| l.id.as_str()).collect();
        assert_eq!(people, ["maya"]);
        let projects: Vec<&str> = links
            .projects_for(&a)
            .iter()
            .map(|l| l.id.as_str())
            .collect();
        assert_eq!(projects, ["atlas", "topic"]);
        assert!(links.is_in(&a, "topic"));
        assert!(!links.is_with(&open("b", None, 3), "maya"));
    }

    #[test]
    fn selection_clicks_ranges_and_keys_like_the_mac() {
        let order: Vec<String> = ["a", "b", "c", "d"].iter().map(|s| s.to_string()).collect();
        let mut selection = Selection::default();
        assert_eq!(selection.current(&order), ["a"], "the first row is current");
        selection.click("b", false, false, &order);
        selection.click("d", false, true, &order);
        assert_eq!(selection.current(&order), ["b", "c", "d"]);
        selection.click("c", true, false, &order);
        assert_eq!(selection.current(&order), ["b", "d"]);
        // The last chosen row cannot be removed.
        let mut one = Selection::default();
        one.click("a", true, false, &order);
        assert_eq!(one.current(&order), ["a"]);
        one.click("a", true, false, &order);
        assert_eq!(one.current(&order), ["a"]);
        // Arrows move from the lead and stop at the ends; Shift extends.
        let mut keys = Selection::default();
        assert_eq!(keys.step(1, false, &order).as_deref(), Some("b"));
        assert_eq!(keys.step(1, true, &order).as_deref(), Some("c"));
        assert_eq!(keys.current(&order), ["b", "c"]);
        keys.collapse(&order);
        assert_eq!(keys.current(&order), ["c"]);
        assert_eq!(keys.step(5, false, &order).as_deref(), Some("d"));
        assert_eq!(keys.step(-9, false, &order).as_deref(), Some("a"));
        keys.select_all(&order);
        assert_eq!(keys.current(&order).len(), 4);
        // Rows that leave the list fall out of the selection.
        assert_eq!(keys.current(&order[2..]), ["c", "d"]);
    }

    #[test]
    fn details_say_what_was_said_and_save_corrections_on_the_right_mention() {
        let mut newest = reference("a", ActionStatus::Open, true, None, 20);
        newest.action.due = Some("by Thursday".into());
        let mut middle = reference("a", ActionStatus::Open, false, None, 15);
        middle.action.due = Some("2026-10-22".into());
        let mut oldest = reference("a", ActionStatus::Open, true, None, 10);
        oldest.action.due = Some("next week".into());
        let a = thread(vec![newest, middle, oldest]);
        assert_eq!(said_due_phrases(&a), ["by Thursday", "next week"]);
        assert_eq!(
            due_note(&a).as_deref(),
            Some("You said “by Thursday”. Before that, “next week”.")
        );
        assert_eq!(mentions_heading(&a), "Said in 3 meetings");
        assert_eq!(due_title(&a), "No date");
        let saved = due_correction(Some(day_of(22)), &a);
        assert_eq!(saved.meeting_id, a.references[0].meeting_id);
        assert_eq!(saved.change.due, Some(Some("2026-10-22".into())));
        assert_eq!(
            (saved.change.text.clone(), saved.change.owner.clone()),
            (None, None)
        );
        assert_eq!(due_correction(None, &a).change.due, Some(None));
        let not_mine = not_mine_corrections(&a);
        assert_eq!(not_mine.len(), 2, "only the user's mentions change");
        assert!(not_mine.iter().all(|c| c.change.owner == Some(None)));
        assert_eq!(confirmation_meetings(std::slice::from_ref(&a)).len(), 3);
        assert_eq!(changing(vec![a.clone()], ActionStatus::Open).len(), 0);
        assert_eq!(changing(vec![a], ActionStatus::Done).len(), 1);
    }

    #[test]
    fn the_control_row_gives_way_like_view_that_fits() {
        // 32 sides + 250 status + 8 + 80 filter = 370 before chips and search.
        assert_eq!(
            filter_bar_layout(700., 250., 80., &[], 230.),
            BarLayout::OneRow
        );
        // 370 + 80 chip + 8 + 8 + 230 search = 696.
        assert_eq!(
            filter_bar_layout(700., 250., 80., &[80.], 230.),
            BarLayout::OneRow
        );
        assert_eq!(
            filter_bar_layout(700., 250., 80., &[100., 120.], 230.),
            BarLayout::ChipsBelow
        );
        assert_eq!(
            filter_bar_layout(600., 250., 80., &[], 230.),
            BarLayout::SearchBelow
        );
        assert_eq!(
            filter_bar_layout(f32::INFINITY, 250., 80., &[100., 120.], 230.),
            BarLayout::OneRow
        );
    }

    #[test]
    fn days_read_today_yesterday_weekday_then_date() {
        let today = today();
        assert_eq!(day_label(today, today), "Today");
        assert_eq!(day_label(day_of(29), today), "Yesterday");
        assert_eq!(day_label(day_of(26), today), "Mon, Oct 26");
        assert_eq!(day_label(day_of(23), today), "Oct 23");
        assert_eq!(
            day_label(NaiveDate::from_ymd_opt(2025, 12, 1).unwrap(), today),
            "Dec 1, 2025"
        );
        assert_eq!(
            stale_summary(1),
            "1 open action hasn’t been mentioned in 3 weeks."
        );
        assert_eq!(
            stale_summary(8),
            "8 open actions haven’t been mentioned in 3 weeks."
        );
    }
}
