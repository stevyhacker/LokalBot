//! What the Quick Recall window lists and where its keyboard is
//! (`QuickRecallResults.swift`): results grouped by kind and capped, the
//! recent items shown before typing, the selection, and what an answer asked
//! from the window reads. Nothing here searches, stores or sends anything.

use std::collections::HashSet;

use chrono::{DateTime, Datelike as _, Local, Utc};
use uuid::Uuid;

use lokalbot_core::{AskSourceScope, QuestionScope};

use crate::pages::ask::model::{self as ask_model, AnswerScope};
use crate::pages::ask::scope::{self, DateScope, Evidence, Offered, Sources};
use crate::pages::ask::search::Facet;
use crate::state::AskScope;

/// Rows of one kind listed before "Show all". A large number of screen
/// matches used to push every meeting out of view.
pub const ROWS_PER_KIND: usize = 3;
/// Recent items listed before anything is typed.
pub const RECENT_LIMIT: usize = 5;
/// Saved moments read for the recent list and to mark saved matches.
pub const SAVED_MOMENTS: usize = 200;

/// The kind of a group of rows, in the order the window lists them.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum GroupKind {
    Recent,
    Commands,
    Meetings,
    Screens,
    Files,
    AgentNotes,
    /// Commands that only hold the typed words inside a word: listed last.
    LooseCommands,
}

impl GroupKind {
    /// The heading, as a catalog key.
    pub fn title_key(self) -> &'static str {
        match self {
            GroupKind::Recent => "Recent",
            GroupKind::Commands | GroupKind::LooseCommands => "Commands",
            GroupKind::Meetings => "Meetings",
            GroupKind::Screens => "Screens",
            GroupKind::Files => "Files",
            GroupKind::AgentNotes => "Agent notes",
        }
    }

    /// The Ask source a "Show all" link narrows the Ask page to
    /// (`QuickRecallGroup.Kind.askSource`). Commands are listed in place
    /// instead, and recent items are never cut.
    pub fn ask_source(self) -> Option<AskSourceScope> {
        match self {
            GroupKind::Recent | GroupKind::Commands | GroupKind::LooseCommands => None,
            GroupKind::Meetings => Some(AskSourceScope::Meetings),
            GroupKind::Screens => Some(AskSourceScope::Screen),
            GroupKind::Files => Some(AskSourceScope::Files),
            GroupKind::AgentNotes => Some(AskSourceScope::AgentNotes),
        }
    }

    fn is_commands(self) -> bool {
        matches!(self, GroupKind::Commands | GroupKind::LooseCommands)
    }
}

/// One group of rows under a heading (`QuickRecallGroup`).
#[derive(Clone, Debug, PartialEq)]
pub struct Group<R> {
    pub kind: GroupKind,
    /// The rows shown.
    pub rows: Vec<R>,
    /// How many the search listed for this kind.
    pub total: usize,
    /// The search stopped at its own limit, so `total` is a floor.
    pub capped: bool,
}

impl<R> Group<R> {
    /// More were found than are shown, so the heading offers "Show all".
    pub fn has_more(&self) -> bool {
        self.total > self.rows.len() || self.capped
    }

    /// "7", or "40+" when the search stopped at its limit: never a count that
    /// reads as exact when it is not.
    pub fn total_label(&self) -> String {
        let total = lokalbot_i18n::number(self.total);
        if self.capped {
            format!("{total}+")
        } else {
            total
        }
    }
}

/// Everything one search found, each kind in its ranked order.
#[derive(Clone, Debug, PartialEq)]
pub struct Found<R> {
    pub commands: Vec<R>,
    /// Commands that only hold the typed words somewhere. They are listed
    /// last, so a search word that happens to sit inside a command's name
    /// does not put that command under Return.
    pub loose_commands: Vec<R>,
    pub meetings: Vec<R>,
    pub screens: Vec<R>,
    pub files: Vec<R>,
    pub agent_notes: Vec<R>,
    /// The search listed fewer than it found.
    pub truncated: bool,
    /// Screen sources the search listed. Saved moments can fold two of them
    /// into one row, so the rows alone can hide that the list was cut.
    pub screen_source_count: usize,
    /// The most the search lists of one kind.
    pub search_limit: usize,
}

impl<R> Default for Found<R> {
    fn default() -> Self {
        Self {
            commands: Vec::new(),
            loose_commands: Vec::new(),
            meetings: Vec::new(),
            screens: Vec::new(),
            files: Vec::new(),
            agent_notes: Vec::new(),
            truncated: false,
            screen_source_count: 0,
            search_limit: crate::pages::ask::search::DISPLAY_LIMIT,
        }
    }
}

/// The groups for a typed search, in a fixed order: commands (only when the
/// typed words start words of one), meetings, screens, files, agent notes
/// while that source is on, then commands that only hold the words. Empty
/// groups are left out. `expanded` lists the kinds whose heading was asked to
/// show everything in place.
pub fn groups<R>(
    found: Found<R>,
    expanded: &HashSet<GroupKind>,
    shows_agent_notes: bool,
) -> Vec<Group<R>> {
    let screens_listed = found.screens.len().max(found.screen_source_count);
    let mut kinds: Vec<(GroupKind, Vec<R>, usize)> = Vec::new();
    let commands = found.commands.len();
    kinds.push((GroupKind::Commands, found.commands, commands));
    let meetings = found.meetings.len();
    kinds.push((GroupKind::Meetings, found.meetings, meetings));
    kinds.push((GroupKind::Screens, found.screens, screens_listed));
    let files = found.files.len();
    kinds.push((GroupKind::Files, found.files, files));
    if shows_agent_notes {
        let notes = found.agent_notes.len();
        kinds.push((GroupKind::AgentNotes, found.agent_notes, notes));
    }
    let loose = found.loose_commands.len();
    kinds.push((GroupKind::LooseCommands, found.loose_commands, loose));
    kinds
        .into_iter()
        .filter(|(_, rows, _)| !rows.is_empty())
        .map(|(kind, mut rows, listed)| {
            // Commands are counted here, never cut by a search limit.
            let capped = !kind.is_commands() && found.truncated && listed >= found.search_limit;
            let total = rows.len();
            if !expanded.contains(&kind) {
                rows.truncate(ROWS_PER_KIND);
            }
            Group {
                kind,
                rows,
                total,
                capped,
            }
        })
        .collect()
}

/// The rows Return may land on as a list appears: every row but the commands
/// that only hold the typed words inside a word. Those come last, and when
/// nothing else is listed none is selected, so Return never runs one ("cord"
/// must not start a recording); the arrow keys still reach them.
pub fn selectable_rows<R>(groups: &[Group<R>]) -> usize {
    groups
        .iter()
        .filter(|group| group.kind != GroupKind::LooseCommands)
        .map(|group| group.rows.len())
        .sum()
}

/// Before anything is typed: recent items, then every command.
pub fn idle<R>(recent: Vec<R>, commands: Vec<R>) -> Vec<Group<R>> {
    [(GroupKind::Recent, recent), (GroupKind::Commands, commands)]
        .into_iter()
        .filter(|(_, rows)| !rows.is_empty())
        .map(|(kind, rows)| Group {
            kind,
            total: rows.len(),
            rows,
            capped: false,
        })
        .collect()
}

/// Recent meetings and saved screen moments as one list, newest first
/// (`QuickRecallRecent.rows`). A meeting and a moment of the same instant list
/// the meeting first.
pub fn recent<R>(
    meetings: Vec<(DateTime<Utc>, R)>,
    saved_moments: Vec<(DateTime<Utc>, R)>,
    limit: usize,
) -> Vec<R> {
    let mut entries: Vec<(DateTime<Utc>, u8, R)> = meetings
        .into_iter()
        .map(|(at, row)| (at, 0, row))
        .chain(saved_moments.into_iter().map(|(at, row)| (at, 1, row)))
        .collect();
    entries.sort_by(|a, b| b.0.cmp(&a.0).then(a.1.cmp(&b.1)));
    entries
        .into_iter()
        .take(limit)
        .map(|(_, _, row)| row)
        .collect()
}

/// Where the keyboard is in the list: on a row, or on the Ask row pinned
/// under the results (`QuickRecallCursor`). Return opens a row and asks on
/// the Ask row; Ctrl+Return asks from anywhere.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Cursor {
    /// The selected position: rows first, then the Ask row. `None` when
    /// nothing is selected, so Return does nothing instead of asking by
    /// surprise.
    index: Option<usize>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Target {
    Row(usize),
    Ask,
}

impl Cursor {
    /// The first row is selected when there is one. With no rows nothing is,
    /// and the Ask row waits for an arrow key or Ctrl+Return.
    pub fn reset(&mut self, row_count: usize) {
        self.index = (row_count > 0).then_some(0);
    }

    /// Arrow keys go round the rows and the Ask row.
    pub fn move_by(&mut self, offset: isize, row_count: usize, has_ask: bool) {
        let count = row_count + usize::from(has_ask);
        if count == 0 {
            self.index = None;
            return;
        }
        self.index = Some(match self.index {
            Some(current) if current < count => {
                (current as isize + offset).rem_euclid(count as isize) as usize
            }
            _ if offset >= 0 => 0,
            _ => count - 1,
        });
    }

    pub fn target(&self, row_count: usize, has_ask: bool) -> Option<Target> {
        let index = self.index?;
        if index < row_count {
            Some(Target::Row(index))
        } else if has_ask && index == row_count {
            Some(Target::Ask)
        } else {
            None
        }
    }

    /// Keeps the Ask row selected when the rows above it change.
    pub fn select(&mut self, target: Target, row_count: usize) {
        self.index = Some(match target {
            Target::Row(row) => row.min(row_count.saturating_sub(1)),
            Target::Ask => row_count,
        });
    }
}

// ------------------------------------------------------------------ asking

/// What an answer asked from Quick Recall reads (`QuickRecallAskScope`). A
/// word or a short phrase is a search the person then asks about: the answer
/// is limited to the listed meetings and screen moments. A full question
/// reads everything in every source; so does a "Remember …" statement, and a
/// search that listed no meeting or screen moment to limit it to. Which is
/// which is Ask's own rule (`AnswerScope`), so both decide alike.
pub fn ask_scope(
    query: &str,
    meeting_ids: Vec<Uuid>,
    screen_ids: Vec<i64>,
    is_remember_statement: bool,
) -> AskScope {
    let has_matches = !meeting_ids.is_empty() || !screen_ids.is_empty();
    match AnswerScope::resolve(query, has_matches, is_remember_statement) {
        AnswerScope::ChosenSources => {
            scope::ask_scope(Sources::default(), DateScope::AnyTime, &Evidence::default())
        }
        // The same narrowing as Ask's handed-over matches (`selectEvidence`):
        // only meetings and screens, each to the listed ones.
        AnswerScope::ListedMatches => scope::ask_scope(
            Sources::default(),
            DateScope::AnyTime,
            &Evidence {
                meetings: Some(meeting_ids),
                screens: Some(screen_ids),
                ..Evidence::default()
            },
        ),
    }
}

/// Whether the Ask row should say the answer comes from the listed matches.
/// While a word's matches are still being found it does: the question waits
/// for them.
pub fn reads_listed_matches(
    query: &str,
    has_matches: bool,
    searching: bool,
    is_remember_statement: bool,
) -> bool {
    AnswerScope::resolve(query, has_matches || searching, is_remember_statement)
        == AnswerScope::ListedMatches
}

/// Where answers are written (`InferencePresentation`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Place {
    OnDevice,
    Remote(String),
    Blocked,
}

/// Where Think answers, as the Ask composer says it (`composer::inference`),
/// with the remote host named.
pub fn place(settings: &lokalbot_core::Settings) -> Place {
    use lokalbot_core::access;
    use lokalbot_core::settings::SummarizerBackend;
    if let Some(plan) = settings.think_plan() {
        // A plan has its own approval entry, never a URL origin.
        return if plan.is_approved(settings) {
            Place::Remote(plan.destination_host().to_string())
        } else {
            Place::Blocked
        };
    }
    let url = match settings.summarizer_backend {
        SummarizerBackend::Ollama => Some(settings.ollama_base_url.clone()),
        SummarizerBackend::OpenAICompatible => Some(settings.openai_base_url.clone()),
        SummarizerBackend::BuiltIn
        | SummarizerBackend::ChatGptPlan
        | SummarizerBackend::ClaudePlan => None,
    };
    let Some(url) = url.filter(|url| !access::is_loopback_url(url)) else {
        return Place::OnDevice;
    };
    if access::remote_block_reason(&url, &settings.approved_remote_inference_origins).is_some() {
        return Place::Blocked;
    }
    let host = access::origin_of(&url)
        .and_then(|origin| origin.split_once("://").map(|(_, host)| host.to_string()))
        .unwrap_or(url);
    Place::Remote(host)
}

/// The Ask row's grey line: what the answer will read, and where it is
/// written. A remote model is named, so nothing is sent by surprise.
pub fn ask_row_detail(place: &Place, reads_listed_matches: bool) -> String {
    match place {
        Place::OnDevice => lokalbot_i18n::tr(if reads_listed_matches {
            "Answers from these matches, on this PC"
        } else {
            "Answers from all your sources, on this PC"
        })
        .to_string(),
        Place::Remote(host) => lokalbot_i18n::fill(
            if reads_listed_matches {
                lokalbot_i18n::tr("Answers from these matches, using %@")
            } else {
                lokalbot_i18n::tr("Answers from all your sources, using %@")
            },
            &[host],
        ),
        Place::Blocked => lokalbot_i18n::tr("Model connection blocked").to_string(),
    }
}

/// The foot of an answer: where it was answered, then what it read ("All
/// sources", a meeting's title, "Meetings, Screen").
pub fn answer_foot_label(place: &Place, answered: bool, scope: Option<&str>) -> String {
    let place = match place {
        Place::OnDevice => lokalbot_i18n::tr(if answered {
            "Answered on this PC"
        } else {
            "On this PC"
        })
        .to_string(),
        Place::Remote(host) => lokalbot_i18n::fill(
            if answered {
                lokalbot_i18n::tr("Answered with %@")
            } else {
                lokalbot_i18n::tr("Remote · %@")
            },
            &[host],
        ),
        Place::Blocked => return lokalbot_i18n::tr("Model connection blocked").to_string(),
    };
    match scope.filter(|scope| !scope.is_empty()) {
        Some(scope) => format!("{place} · {scope}"),
        None => place,
    }
}

/// What a question was limited to, in the words the Ask screen's sources menu
/// uses: "All sources" or the sources by name; when it was bound to matches,
/// one meeting's title or how many meetings and screen moments
/// (`AskScopeSummary.narrowedTo ?? title`, with no filter).
pub fn scope_label(
    saved: &QuestionScope,
    offered: Offered,
    meeting_title: impl Fn(Uuid) -> Option<String>,
) -> String {
    let sources = Sources::from_saved(&saved.sources);
    let summary = ask_model::scope_summary(
        &ask_model::ScopeInput {
            sources,
            effective: sources,
            offered,
            meeting_ids: saved.meeting_ids.as_deref(),
            screen_ids: saved.screen_snapshot_ids.as_deref(),
            widen_to: sources,
            facet: Facet::All,
            screen_app: None,
        },
        meeting_title,
    );
    summary.narrowed_to.unwrap_or(summary.title)
}

// ------------------------------------------------------------------ quotes

/// Words the search index ignores (`SearchIndex.stopWords`), so a quote never
/// marks them.
const STOP_WORDS: &[&str] = &[
    "a", "an", "the", "and", "or", "but", "if", "of", "to", "in", "on", "at", "for", "with",
    "about", "as", "by", "from", "into", "is", "are", "was", "were", "be", "been", "being", "do",
    "does", "did", "doing", "have", "has", "had", "what", "when", "where", "who", "whom", "which",
    "why", "how", "we", "i", "you", "he", "she", "it", "they", "me", "us", "them", "my", "our",
    "your", "this", "that", "these", "those", "can", "could", "would", "should", "will", "shall",
    "may", "might", "must", "any", "some", "there",
];

/// The words of a question worth marking in a source's quote: three letters
/// or more, each once (`QuickRecallQuote.terms`).
pub fn quote_terms(question: &str) -> Vec<String> {
    let mut seen = HashSet::new();
    question
        .to_lowercase()
        .split(|c: char| !c.is_alphanumeric())
        .filter(|word| word.chars().count() >= 3 && !STOP_WORDS.contains(word))
        .filter(|word| seen.insert(word.to_string()))
        .map(str::to_string)
        .collect()
}

/// `text` with each word that starts with one of `terms` between « and », so
/// a source's quote reads like a search result (`QuickRecallQuote.marked`).
pub fn marked(text: &str, terms: &[String]) -> String {
    if terms.is_empty() {
        return text.to_string();
    }
    let mut out = String::with_capacity(text.len() + 8);
    let mut word = String::new();
    let flush = |word: &mut String, out: &mut String| {
        if word.is_empty() {
            return;
        }
        let lowered = word.to_lowercase();
        if terms.iter().any(|term| lowered.starts_with(term.as_str())) {
            out.push('«');
            out.push_str(word);
            out.push('»');
        } else {
            out.push_str(word);
        }
        word.clear();
    };
    for c in text.chars() {
        if c.is_alphanumeric() {
            word.push(c);
        } else {
            flush(&mut word, &mut out);
            out.push(c);
        }
    }
    flush(&mut word, &mut out);
    out
}

/// A source's line under an answer: `text` around the question's words, cut
/// to `limit` characters, with those words marked (`QuickRecallQuote.line`).
pub fn quote_line(text: &str, question: &str, limit: usize) -> Option<String> {
    let plain = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if plain.is_empty() {
        return None;
    }
    let terms = quote_terms(question);
    let chars: Vec<char> = plain.chars().collect();
    if chars.len() <= limit {
        return Some(marked(&plain, &terms));
    }
    // Start a little before the first word of the question, at a word break.
    let lowered = plain.to_lowercase();
    let first = terms
        .iter()
        .filter_map(|term| lowered.find(term.as_str()))
        .min()
        .map(|byte| lowered[..byte].chars().count())
        .unwrap_or(0);
    let mut start = first.saturating_sub(limit / 4);
    while start > 0 && !chars[start - 1].is_whitespace() {
        start -= 1;
    }
    let end = (start + limit).min(chars.len());
    let mut excerpt: String = chars[start..end].iter().collect();
    excerpt = excerpt.trim().to_string();
    if start > 0 {
        excerpt.insert(0, '…');
    }
    if end < chars.len() {
        excerpt.push('…');
    }
    Some(marked(&excerpt, &terms))
}

// ------------------------------------------------------------------- text

/// A phrase GPUI draws as one shaped line, starting with the mark of its own
/// direction when that is right-to-left, so a translated "Show all 7" or
/// "3 meetings" keeps its number in Arabic and Urdu (as Today's `directional`).
pub fn directional(text: impl Into<String>) -> String {
    let text = text.into();
    if lokalbot_i18n::content_is_rtl(&text) && !text.starts_with('\u{200f}') {
        format!("\u{200f}{text}")
    } else {
        text
    }
}

// ------------------------------------------------------------------- dates

/// "Today 10:43 AM", "Yesterday 4:00 PM", "Wed 11:47 AM" within a week, else
/// "Sep 25" (or "Sep 25, 2025" in another year): `QuickRecallDateLabel`.
pub fn date_label(at: DateTime<Utc>, now: DateTime<Local>) -> String {
    let local = at.with_timezone(&Local);
    let locale = lokalbot_i18n::date_locale();
    let time = || {
        local
            .format_localized(lokalbot_i18n::date_pattern("%-I:%M %p"), locale)
            .to_string()
    };
    let days = (now.date_naive() - local.date_naive()).num_days();
    match days {
        0 => format!("{} {}", lokalbot_i18n::tr("Today"), time()),
        1 => format!("{} {}", lokalbot_i18n::tr("Yesterday"), time()),
        2..=6 => format!(
            "{} {}",
            local.format_localized(lokalbot_i18n::date_pattern("%a"), locale),
            time()
        ),
        _ if local.year() == now.year() => local
            .format_localized(lokalbot_i18n::date_pattern("%b %-d"), locale)
            .to_string(),
        _ => local
            .format_localized(lokalbot_i18n::date_pattern("%b %-d, %Y"), locale)
            .to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone as _;

    fn found(commands: usize, meetings: usize, screens: usize) -> Found<String> {
        let rows = |prefix: &str, n: usize| (0..n).map(|i| format!("{prefix}{i}")).collect();
        Found {
            commands: rows("c", commands),
            meetings: rows("m", meetings),
            screens: rows("s", screens),
            ..Found::default()
        }
    }

    fn kinds(groups: &[Group<String>]) -> Vec<GroupKind> {
        groups.iter().map(|group| group.kind).collect()
    }

    #[test]
    fn groups_come_in_a_fixed_order_and_skip_empty_kinds() {
        let mut found = found(1, 2, 0);
        found.files = vec!["f0".into()];
        found.agent_notes = vec!["n0".into()];
        found.loose_commands = vec!["l0".into()];
        let groups = groups(found.clone(), &HashSet::new(), true);
        assert_eq!(
            kinds(&groups),
            [
                GroupKind::Commands,
                GroupKind::Meetings,
                GroupKind::Files,
                GroupKind::AgentNotes,
                GroupKind::LooseCommands,
            ]
        );
        // Agent notes are a source only while their own setting is on.
        let without_notes = super::groups(found, &HashSet::new(), false);
        assert!(!kinds(&without_notes).contains(&GroupKind::AgentNotes));
    }

    #[test]
    fn three_of_each_kind_with_show_all_for_the_rest() {
        let groups = groups(found(0, 7, 11), &HashSet::new(), false);
        assert_eq!(groups[0].rows, ["m0", "m1", "m2"]);
        assert_eq!(groups[0].total, 7);
        assert!(groups[0].has_more());
        assert_eq!(groups[0].total_label(), "7");
        assert_eq!(groups[1].rows.len(), 3);
        assert_eq!(groups[1].total_label(), "11");
        let small = super::groups(found(0, 3, 0), &HashSet::new(), false);
        assert!(!small[0].has_more());
    }

    #[test]
    fn show_all_narrows_ask_to_the_kinds_source() {
        assert_eq!(
            GroupKind::Meetings.ask_source(),
            Some(AskSourceScope::Meetings)
        );
        assert_eq!(
            GroupKind::Screens.ask_source(),
            Some(AskSourceScope::Screen)
        );
        assert_eq!(GroupKind::Files.ask_source(), Some(AskSourceScope::Files));
        assert_eq!(
            GroupKind::AgentNotes.ask_source(),
            Some(AskSourceScope::AgentNotes)
        );
        // Commands list in place; recent items are never cut.
        for kind in [
            GroupKind::Recent,
            GroupKind::Commands,
            GroupKind::LooseCommands,
        ] {
            assert_eq!(kind.ask_source(), None);
        }
    }

    #[test]
    fn an_expanded_kind_lists_everything_in_place() {
        let expanded = HashSet::from([GroupKind::Commands]);
        let groups = groups(found(5, 5, 0), &expanded, false);
        assert_eq!(groups[0].rows.len(), 5);
        assert!(!groups[0].has_more());
        assert_eq!(groups[1].rows.len(), 3);
    }

    #[test]
    fn a_search_stopped_at_its_limit_reads_as_a_floor() {
        let mut found = found(4, 40, 2);
        found.truncated = true;
        found.screen_source_count = 40;
        let groups = groups(found, &HashSet::new(), false);
        // Commands are never cut by the search limit.
        assert!(!groups[0].capped);
        assert!(groups[1].capped);
        assert_eq!(groups[1].total_label(), "40+");
        // Saved moments folded two sources into one row: still capped.
        assert!(groups[2].capped);
        assert!(groups[2].has_more());
    }

    #[test]
    fn return_never_lands_on_a_command_that_only_holds_the_words() {
        let only_loose = Found::<String> {
            loose_commands: vec!["record".into()],
            ..Found::default()
        };
        let groups = groups(only_loose, &HashSet::new(), false);
        assert_eq!(selectable_rows(&groups), 0);
        let mut cursor = Cursor::default();
        cursor.reset(selectable_rows(&groups));
        assert_eq!(cursor.target(1, true), None);
        // The arrow keys still reach it.
        cursor.move_by(1, 1, true);
        assert_eq!(cursor.target(1, true), Some(Target::Row(0)));
        let mut with_meeting = found(0, 1, 0);
        with_meeting.loose_commands = vec!["record".into()];
        let groups = super::groups(with_meeting, &HashSet::new(), false);
        assert_eq!(selectable_rows(&groups), 1);
    }

    #[test]
    fn idle_lists_recent_items_then_commands() {
        let groups = idle(vec!["r".to_string()], vec!["c".to_string()]);
        assert_eq!(kinds(&groups), [GroupKind::Recent, GroupKind::Commands]);
        assert_eq!(
            kinds(&idle(Vec::new(), vec!["c".to_string()])),
            [GroupKind::Commands]
        );
    }

    #[test]
    fn recent_items_are_newest_first_with_meetings_before_moments_at_a_tie() {
        let at = |h: u32| Utc.with_ymd_and_hms(2026, 11, 14, h, 0, 0).unwrap();
        let rows = recent(
            vec![(at(9), "meeting 9"), (at(11), "meeting 11")],
            vec![
                (at(10), "moment 10"),
                (at(11), "moment 11"),
                (at(8), "moment 8"),
            ],
            4,
        );
        assert_eq!(rows, ["meeting 11", "moment 11", "moment 10", "meeting 9"]);
    }

    #[test]
    fn the_cursor_goes_round_the_rows_and_the_ask_row() {
        let mut cursor = Cursor::default();
        assert_eq!(cursor.target(3, true), None);
        cursor.reset(3);
        assert_eq!(cursor.target(3, true), Some(Target::Row(0)));
        cursor.move_by(-1, 3, true);
        assert_eq!(cursor.target(3, true), Some(Target::Ask));
        cursor.move_by(1, 3, true);
        assert_eq!(cursor.target(3, true), Some(Target::Row(0)));
        // No rows: nothing is selected until an arrow key reaches the Ask row.
        cursor.reset(0);
        assert_eq!(cursor.target(0, true), None);
        cursor.move_by(1, 0, true);
        assert_eq!(cursor.target(0, true), Some(Target::Ask));
        // The Ask row stays selected as the rows above it change.
        cursor.select(Target::Ask, 5);
        assert_eq!(cursor.target(5, true), Some(Target::Ask));
        cursor.select(Target::Row(9), 5);
        assert_eq!(cursor.target(5, true), Some(Target::Row(4)));
    }

    #[test]
    fn a_word_asks_only_within_the_listed_meetings_and_screens() {
        let meeting = Uuid::from_u128(7);
        let scope = ask_scope("captions", vec![meeting], vec![42], false);
        assert_eq!(scope.meeting_ids, [meeting]);
        assert_eq!(scope.screen_ids, [42]);
        assert!(scope.include_meetings && scope.include_screen);
        assert!(!scope.include_activity && !scope.include_files && !scope.include_agent_notes);
        // Only screens listed: meetings are not read at all.
        let screens_only = ask_scope("captions", Vec::new(), vec![42], false);
        assert!(!screens_only.include_meetings && screens_only.include_screen);
        // A full question reads every source.
        let open = ask_scope(
            "what did we decide about captions?",
            vec![meeting],
            vec![42],
            false,
        );
        assert!(open.meeting_ids.is_empty() && open.screen_ids.is_empty());
        assert!(open.include_meetings && open.include_activity && open.include_screen);
    }

    #[test]
    fn the_ask_row_says_what_the_answer_reads_and_where() {
        assert!(reads_listed_matches("atlas", false, true, false));
        assert!(!reads_listed_matches("atlas", false, false, false));
        assert_eq!(
            ask_row_detail(&Place::OnDevice, true),
            "Answers from these matches, on this PC"
        );
        assert_eq!(
            ask_row_detail(&Place::Remote("api.example.com".into()), false),
            "Answers from all your sources, using api.example.com"
        );
        assert_eq!(
            ask_row_detail(&Place::Blocked, true),
            "Model connection blocked"
        );
    }

    #[test]
    fn the_place_names_a_remote_host_and_a_blocked_connection() {
        use lokalbot_core::settings::SummarizerBackend;
        let mut settings = lokalbot_core::Settings {
            summarizer_backend: SummarizerBackend::BuiltIn,
            ..Default::default()
        };
        assert_eq!(place(&settings), Place::OnDevice);
        settings.summarizer_backend = SummarizerBackend::OpenAICompatible;
        settings.openai_base_url = "http://127.0.0.1:1234/v1".into();
        assert_eq!(place(&settings), Place::OnDevice);
        settings.openai_base_url = "https://api.example.com/v1".into();
        assert_eq!(place(&settings), Place::Blocked);
        settings.approved_remote_inference_origins = vec!["https://api.example.com".into()];
        assert_eq!(place(&settings), Place::Remote("api.example.com".into()));
    }

    #[test]
    fn the_answer_foot_names_where_and_what() {
        assert_eq!(
            answer_foot_label(&Place::OnDevice, true, Some("All sources")),
            "Answered on this PC · All sources"
        );
        assert_eq!(
            answer_foot_label(&Place::OnDevice, false, None),
            "On this PC"
        );
        assert_eq!(
            answer_foot_label(&Place::Remote("h".into()), true, Some("")),
            "Answered with h"
        );
        assert_eq!(
            answer_foot_label(&Place::Remote("h".into()), false, Some("Meetings")),
            "Remote · h · Meetings"
        );
        assert_eq!(
            answer_foot_label(&Place::Blocked, true, Some("All sources")),
            "Model connection blocked"
        );
    }

    #[test]
    fn the_scope_label_names_what_the_question_read() {
        let offered = Offered::default();
        let title = |_: Uuid| Some("Design review".to_string());
        let all = QuestionScope {
            sources: lokalbot_core::AskSourceScope::ALL.to_vec(),
            ..QuestionScope::default()
        };
        assert_eq!(scope_label(&all, offered, title), "All sources");
        let one = QuestionScope {
            sources: vec![lokalbot_core::AskSourceScope::Meetings],
            meeting_ids: Some(vec![Uuid::from_u128(1)]),
            ..QuestionScope::default()
        };
        assert_eq!(scope_label(&one, offered, title), "Design review");
        let several = QuestionScope {
            sources: vec![
                lokalbot_core::AskSourceScope::Meetings,
                lokalbot_core::AskSourceScope::Screen,
            ],
            meeting_ids: Some(vec![Uuid::from_u128(1), Uuid::from_u128(2)]),
            screen_snapshot_ids: Some(vec![9]),
            ..QuestionScope::default()
        };
        assert_eq!(
            scope_label(&several, offered, title),
            "2 meetings, 1 screen moment"
        );
        let long = |_: Uuid| Some("A meeting title much longer than the foot allows".into());
        assert_eq!(
            scope_label(&one, offered, long),
            "A meeting title much longer than…"
        );
    }

    #[test]
    fn quotes_mark_the_questions_words() {
        assert_eq!(
            quote_terms("What did we decide on the captions? Captions!"),
            ["decide", "captions"]
        );
        assert_eq!(
            marked(
                "Every video ships with Captions, decided.",
                &quote_terms("captions decide")
            ),
            "Every video ships with «Captions», «decided»."
        );
        assert_eq!(marked("No change", &[]), "No change");
        let long = format!(
            "{} the captions are easy {}",
            "word ".repeat(80),
            "tail ".repeat(80)
        );
        let line = quote_line(&long, "captions", 120).unwrap();
        assert!(line.starts_with('…') && line.ends_with('…'));
        assert!(line.contains("«captions»"));
        assert!(line.chars().count() <= 124);
        assert_eq!(quote_line("  ", "captions", 120), None);
    }

    #[test]
    fn date_labels() {
        let now = Local.with_ymd_and_hms(2026, 10, 18, 15, 0, 0).unwrap();
        let at = |y: i32, m: u32, d: u32, h: u32| {
            Local
                .with_ymd_and_hms(y, m, d, h, 43, 0)
                .unwrap()
                .with_timezone(&Utc)
        };
        assert_eq!(date_label(at(2026, 10, 18, 10), now), "Today 10:43 AM");
        assert_eq!(date_label(at(2026, 10, 17, 13), now), "Yesterday 1:43 PM");
        assert_eq!(date_label(at(2026, 10, 14, 9), now), "Wed 9:43 AM");
        assert_eq!(date_label(at(2026, 10, 1, 9), now), "Oct 1");
        assert_eq!(date_label(at(2025, 9, 25, 9), now), "Sep 25, 2025");
    }
}
