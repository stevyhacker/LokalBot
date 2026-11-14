//! What Ask decides and shows, without drawing it (`AskRouting.swift`,
//! `AskPresentation.swift`): where matches sit, what Return does, what an
//! answer reads, what the sources menu says, how citations group into an
//! answer's sources list, and which questions an empty page suggests. Nothing
//! here changes what a question may read beyond `AnswerScope`.

use chrono::{DateTime, Datelike as _, Local, Utc};
use lokalbot_core::{ChatMessage, ChatRole, QuestionScope};
use uuid::Uuid;

use super::scope::{Offered, Source, Sources};
use super::search::Facet;
use crate::ui::citations::CitationSource;

// ------------------------------------------------------------ the page

/// `AskPhase.Page`: a new question has the field mid-page; a conversation
/// docks it below the thread.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PageKind {
    NewQuestion,
    Conversation,
}

/// `AskPhase.MatchesPlacement`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MatchesPlacement {
    UnderField,
    TrayAboveField,
}

/// `AskPhase`: typing never replaces the conversation.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct AskPhase {
    pub page: PageKind,
    /// The field holds text, so its matches are listed.
    pub typing: bool,
}

impl AskPhase {
    /// `AskRouter.phase`.
    pub fn new(query: &str, has_messages: bool) -> Self {
        Self {
            page: if has_messages {
                PageKind::Conversation
            } else {
                PageKind::NewQuestion
            },
            typing: !query.trim().is_empty(),
        }
    }

    pub fn shows_suggestions(self) -> bool {
        self.page == PageKind::NewQuestion && !self.typing
    }

    pub fn matches_placement(self) -> Option<MatchesPlacement> {
        self.typing.then_some(match self.page {
            PageKind::NewQuestion => MatchesPlacement::UnderField,
            PageKind::Conversation => MatchesPlacement::TrayAboveField,
        })
    }
}

/// `AskIntent.isQuestion`: two or more words ending in "?", or three or more
/// that start with a question or request word.
pub fn is_question(query: &str) -> bool {
    const STARTS: &[&str] = &[
        "what",
        "why",
        "how",
        "when",
        "where",
        "who",
        "whom",
        "whose",
        "which",
        "did",
        "do",
        "does",
        "is",
        "are",
        "was",
        "were",
        "can",
        "could",
        "should",
        "would",
        "will",
        "has",
        "have",
        "had",
        "summarize",
        "summarise",
        "explain",
        "list",
        "tell",
        "compare",
        "remind",
        "draft",
    ];
    let words: Vec<&str> = query.split_whitespace().collect();
    let Some(first) = words.first() else {
        return false;
    };
    if query.trim().ends_with('?') {
        return words.len() >= 2;
    }
    let lead = first
        .trim_matches(|c: char| c.is_ascii_punctuation())
        .to_lowercase();
    words.len() >= 3 && STARTS.contains(&lead.as_str())
}

/// What Return does in Ask (`AskReturnAction`): it asks. Only after the arrow
/// keys moved onto a match does it open that match.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ReturnAction {
    OpenResult,
    Ask,
    Nothing,
}

pub fn return_action(query: &str, results: usize, picked_with_keyboard: bool) -> ReturnAction {
    if picked_with_keyboard && results > 0 {
        ReturnAction::OpenResult
    } else if query.trim().is_empty() {
        ReturnAction::Nothing
    } else {
        ReturnAction::Ask
    }
}

/// What an answer asked from the field reads (`AskAnswerScope`). A full
/// question reads everything in the sources and dates the two menus show,
/// whether or not matches are listed. A word or short phrase is a search the
/// person then asks about, so its answer reads the listed matches. A
/// "Remember …" statement is saved as it is and limits nothing. Scope already
/// set on purpose (a meeting handed over, an attached screen, the menu's
/// "Only …" state) is not this type's to change.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AnswerScope {
    ChosenSources,
    ListedMatches,
}

impl AnswerScope {
    /// Anything longer than a short phrase is a question in any language:
    /// `is_question` only knows English question words.
    pub const FULL_QUESTION_WORDS: usize = 4;

    pub fn is_full_question(query: &str) -> bool {
        is_question(query) || query.split_whitespace().count() >= Self::FULL_QUESTION_WORDS
    }

    pub fn resolve(query: &str, has_matches: bool, is_remember_statement: bool) -> Self {
        if !has_matches || is_remember_statement || Self::is_full_question(query) {
            AnswerScope::ChosenSources
        } else {
            AnswerScope::ListedMatches
        }
    }
}

/// Where the keyboard is (`AskMatchCursor`): in the field (`None`), where
/// Return asks, or on a match, where Return opens it.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct MatchCursor {
    index: Option<usize>,
}

impl MatchCursor {
    pub fn index(self) -> Option<usize> {
        self.index
    }

    pub fn is_in_matches(self) -> bool {
        self.index.is_some()
    }

    /// Down moves from the field into the matches and along them; Up from the
    /// first match returns to the field. `false` when the key isn't the
    /// cursor's to handle, so the field keeps it.
    pub fn step(&mut self, down: bool, count: usize) -> bool {
        if count == 0 {
            self.index = None;
            return false;
        }
        self.index = match (down, self.index) {
            (true, None) => Some(0),
            (true, Some(current)) => Some((current + 1).min(count - 1)),
            (false, None) => return false,
            (false, Some(current)) => current.min(count).checked_sub(1),
        };
        true
    }

    /// Matches that arrive or leave never strand the cursor past the list.
    pub fn clamp(&mut self, count: usize) {
        if let Some(current) = self.index {
            self.index = (count > 0).then(|| current.min(count - 1));
        }
    }

    pub fn return_to_field(&mut self) {
        self.index = None;
    }
}

/// "3 in 1 meeting" when only meetings matched, else the number of sources;
/// a list that was cut says "40+" (`AskMatches.countLabel`).
pub fn matches_count_label(
    meetings: usize,
    passages: usize,
    others: usize,
    truncated: bool,
) -> String {
    let count = meetings + others;
    if truncated {
        return directional(&format!("{}+", lokalbot_i18n::number(count)));
    }
    if others > 0 || meetings == 0 {
        return lokalbot_i18n::number(count);
    }
    directional(&if meetings == 1 {
        mac("%lld in 1 meeting", &[&lokalbot_i18n::number(passages)])
    } else {
        mac(
            "%1$lld in %2$lld meetings",
            &[
                &lokalbot_i18n::number(passages),
                &lokalbot_i18n::number(meetings),
            ],
        )
    })
}

// ------------------------------------------------------- the sources menu

/// The sources menu's button and first rows (`AskScopeSummary`): the chosen
/// sources and finer filters, or, when the question is limited to earlier
/// matches or to evidence another page handed over, what that is.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ScopeSummary {
    pub title: String,
    /// Limited to particular meetings or screen moments.
    pub narrowed: bool,
    /// A match-type or screen-app filter is on.
    pub has_filters: bool,
    /// What the question is limited to, for the checked "Only …" row.
    pub narrowed_to: Option<String>,
    /// The row that widens it again.
    pub widen_title: Option<String>,
}

pub struct ScopeInput<'a> {
    /// The sources chosen in the menu.
    pub sources: Sources,
    /// What the bound question still reads, for a limit that holds no meeting
    /// and no screen moment.
    pub effective: Sources,
    pub offered: Offered,
    pub meeting_ids: Option<&'a [Uuid]>,
    pub screen_ids: Option<&'a [i64]>,
    /// What widening goes back to.
    pub widen_to: Sources,
    pub facet: Facet,
    pub screen_app: Option<&'a str>,
}

pub const SCOPE_TITLE_LIMIT: usize = 34;

pub fn scope_summary(
    input: &ScopeInput,
    meeting_title: impl Fn(Uuid) -> Option<String>,
) -> ScopeSummary {
    let narrowed = input.meeting_ids.is_some() || input.screen_ids.is_some();
    let narrowed_to = narrowed.then(|| {
        shortened(
            &narrowed_label(input, &meeting_title).unwrap_or_else(|| remaining_sources(input)),
        )
    });
    let chosen = input.sources.summary(input.offered);
    let mut parts = vec![narrowed_to.clone().unwrap_or_else(|| shortened(&chosen))];
    if input.facet != Facet::All {
        parts.push(input.facet.label().to_string());
    }
    if let Some(app) = input.screen_app.filter(|app| !app.is_empty()) {
        parts.push(app.to_string());
    }
    ScopeSummary {
        title: parts.join(" · "),
        narrowed,
        has_filters: input.facet != Facet::All || input.screen_app.is_some_and(|a| !a.is_empty()),
        narrowed_to,
        widen_title: narrowed.then(|| input.widen_to.summary(input.offered)),
    }
}

/// One meeting by its title; otherwise how many meetings and screen moments.
fn narrowed_label(
    input: &ScopeInput,
    meeting_title: &impl Fn(Uuid) -> Option<String>,
) -> Option<String> {
    let meetings = input.meeting_ids.unwrap_or_default();
    let screens = input.screen_ids.unwrap_or_default();
    if screens.is_empty()
        && let [only] = meetings
        && let Some(title) = meeting_title(*only)
        && !title.trim().is_empty()
    {
        return Some(title.trim().to_string());
    }
    let mut parts = Vec::new();
    if !meetings.is_empty() {
        parts.push(mac_count(meetings.len(), "%lld meeting", "%lld meetings"));
    }
    if !screens.is_empty() {
        parts.push(mac_count(
            screens.len(),
            "%lld screen moment",
            "%lld screen moments",
        ));
    }
    (!parts.is_empty()).then(|| directional(&parts.join(", ")))
}

/// A limit that holds no meeting and no screen moment names what remains.
fn remaining_sources(input: &ScopeInput) -> String {
    let mut remaining = input.effective;
    if input.meeting_ids.is_some_and(<[Uuid]>::is_empty) {
        remaining.meetings = false;
    }
    if input.screen_ids.is_some_and(<[i64]>::is_empty) {
        remaining.screen = false;
    }
    let names: Vec<&str> = Source::available(input.offered)
        .filter(|source| remaining.contains(*source))
        .map(Source::label)
        .collect();
    if names.is_empty() {
        lokalbot_i18n::tr("No matches").into()
    } else {
        names.join(", ")
    }
}

fn shortened(text: &str) -> String {
    if text.chars().count() <= SCOPE_TITLE_LIMIT {
        return text.to_string();
    }
    let cut: String = text.chars().take(SCOPE_TITLE_LIMIT - 1).collect();
    format!("{}…", cut.trim())
}

// ------------------------------------------------------ answer sources

/// The kind of source a row of the sources list stands for.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SourceKind {
    Meeting,
    Screen,
    File,
    Note,
}

/// One source an answer cited, with the numbers in the answer that point at
/// it (`AnswerSourceGroup`). Grouping never renumbers.
#[derive(Clone, Debug, PartialEq)]
pub struct SourceGroup {
    pub kind: SourceKind,
    pub key: String,
    /// 1-based numbers as the answer shows them, with their citations.
    pub entries: Vec<(usize, CitationSource)>,
}

impl SourceGroup {
    pub fn first(&self) -> &CitationSource {
        &self.entries[0].1
    }
}

/// A row per meeting, screen moment, file or note, in the order the answer
/// first cites them (`AnswerSources.groups`). `meeting_key` names the meeting
/// a citation resolves to, so a short id and a full one share a row;
/// `file_key` names a cited passage's file, so two passages of one file do.
pub fn source_groups(
    citations: &[CitationSource],
    meeting_key: impl Fn(&str) -> Option<String>,
    file_key: impl Fn(i64) -> Option<String>,
) -> Vec<SourceGroup> {
    let mut groups: Vec<SourceGroup> = Vec::new();
    for (offset, citation) in citations.iter().enumerate() {
        let (kind, key) = match citation {
            CitationSource::Meeting { id, .. } => (
                SourceKind::Meeting,
                meeting_key(id).unwrap_or_else(|| id.to_lowercase()),
            ),
            CitationSource::Screen { snapshot_id } => (SourceKind::Screen, snapshot_id.to_string()),
            CitationSource::File { id } => (
                SourceKind::File,
                file_key(*id).unwrap_or_else(|| format!("passage:{id}")),
            ),
            CitationSource::Note { id } => (SourceKind::Note, id.clone()),
        };
        let entry = (offset + 1, citation.clone());
        match groups.iter_mut().find(|g| g.kind == kind && g.key == key) {
            Some(group) => group.entries.push(entry),
            None => groups.push(SourceGroup {
                kind,
                key,
                entries: vec![entry],
            }),
        }
    }
    groups
}

/// A transcript line a citation can quote (`CitationPassage.Line`).
#[derive(Clone, Debug, PartialEq)]
pub struct PassageLine {
    pub start: f64,
    pub end: f64,
    pub speaker: String,
    pub text: String,
}

/// The line a meeting citation names (`CitationPassage.line`). Citations carry
/// whole seconds, so the line that starts in that second wins; otherwise the
/// line being said then, otherwise the last one before it.
pub fn passage_line(seconds: f64, lines: &[PassageLine]) -> Option<&PassageLine> {
    if !seconds.is_finite() || seconds < 0. {
        return None;
    }
    let second = seconds.trunc();
    lines
        .iter()
        .find(|line| line.start.is_finite() && line.start.trunc() == second)
        .or_else(|| {
            lines
                .iter()
                .find(|line| line.start <= seconds && seconds < line.end)
        })
        .or_else(|| lines.iter().rev().find(|line| line.start <= seconds))
}

/// A matched passage as reading text: a summary's Markdown headings, bullets
/// and emphasis marks dropped and its lines joined, the «matched» markers kept
/// (what `RecallPassage.excerpt` leaves on the Mac).
pub fn plain_snippet(snippet: &str) -> String {
    let lines: Vec<&str> = snippet
        .lines()
        .map(|line| {
            let line = line.trim_start();
            let line = line.trim_start_matches('#').trim_start();
            ["- ", "* ", "• ", "> "]
                .iter()
                .find_map(|marker| line.strip_prefix(marker))
                .unwrap_or(line)
        })
        .collect();
    lines
        .join(" ")
        .replace("**", "")
        .replace("__", "")
        .replace('`', "")
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

pub const QUOTE_LIMIT: usize = 420;

/// Stored text as a short quote (`CitationPassage.quote`): search markers and
/// line breaks removed, cut at a word once it runs long.
pub fn quote(text: Option<&str>, limit: usize) -> Option<String> {
    let plain = text?
        .replace(['«', '»'], "")
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ");
    if plain.is_empty() {
        return None;
    }
    if plain.chars().count() <= limit {
        return Some(plain);
    }
    let mut cut: String = plain.chars().take(limit).collect();
    if let Some(space) = cut.rfind(char::is_whitespace)
        && cut[..space].chars().count() > limit / 2
    {
        cut.truncate(space);
    }
    Some(format!("{}…", cut.trim_end()))
}

/// `ChatViewModel.askAgainQuestion`: a finished answer's question, and the
/// sources, dates and evidence limits it was asked within. Not for a failed or
/// "Remember …" turn, a question whose scope is unknown, or one with attached
/// screens (their captured text never reached disk).
pub fn ask_again(messages: &[ChatMessage], assistant_id: Uuid) -> Option<(String, QuestionScope)> {
    let index = messages.iter().position(|m| m.id == assistant_id)?;
    let answer = &messages[index];
    if answer.role != ChatRole::Assistant || answer.is_error || answer.remember_receipt.is_some() {
        return None;
    }
    let question = messages[..index]
        .iter()
        .rev()
        .find(|m| m.role == ChatRole::User)?;
    if question.legacy_scope_is_ambiguous
        || !question.attached_screen_day_keys.is_empty()
        || question.source_scopes.is_empty()
    {
        return None;
    }
    lokalbot_core::retry_question(messages, assistant_id)
}

// ---------------------------------------------------------- an empty page

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SuggestionKind {
    Project,
    Meeting,
    Person,
    General,
    Keyword,
}

/// A question, or a single word, offered on an empty Ask page.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Suggestion {
    pub kind: SuggestionKind,
    pub text: String,
}

/// The app's general questions, when nothing of the person's own can be named.
pub const SUGGESTIONS: [&str; 3] = [
    "What did we decide in my last meeting?",
    "List my recent meetings",
    "Search my meetings for action items",
];

/// Questions about the person's own project, latest meeting and a colleague,
/// then one word to search for (`AskSuggestions.build`). With none of those
/// to name, the general questions stand in and no word is offered.
pub fn suggestions(
    latest_meeting: Option<&str>,
    person: Option<&str>,
    project: Option<&str>,
) -> Vec<Suggestion> {
    let project = named(project);
    let meeting = named(latest_meeting);
    let person = named(person);
    let mut list = Vec::new();
    if let Some(project) = &project {
        list.push(Suggestion {
            kind: SuggestionKind::Project,
            text: mac("Where does %@ stand?", &[project]),
        });
    }
    if let Some(meeting) = &meeting {
        list.push(Suggestion {
            kind: SuggestionKind::Meeting,
            text: mac("What did we decide in %@?", &[meeting]),
        });
    }
    if let Some(person) = &person {
        list.push(Suggestion {
            kind: SuggestionKind::Person,
            text: mac("What did %@ ask me to do?", &[person]),
        });
    }
    if list.is_empty() {
        return SUGGESTIONS
            .iter()
            .map(|text| Suggestion {
                kind: SuggestionKind::General,
                text: lokalbot_i18n::tr(text).to_string(),
            })
            .collect();
    }
    let names: Vec<String> = [project, meeting].into_iter().flatten().collect();
    if let Some(word) = keyword(&names) {
        list.push(Suggestion {
            kind: SuggestionKind::Keyword,
            text: word,
        });
    }
    list
}

const GENERIC_WORDS: [&str; 20] = [
    "meeting",
    "meetings",
    "review",
    "standup",
    "weekly",
    "daily",
    "monthly",
    "sync",
    "call",
    "catch",
    "untitled",
    "notes",
    "recording",
    "project",
    "team",
    "with",
    "about",
    "from",
    "and",
    "the",
];

/// One word worth searching for: the first name that is a single word, else
/// the longest distinctive word in the names.
pub fn keyword(names: &[String]) -> Option<String> {
    let candidates: Vec<Vec<&str>> = names
        .iter()
        .map(|name| {
            name.split(|c: char| !c.is_alphanumeric())
                .filter(|word| {
                    word.chars().count() >= 4
                        && word.chars().any(char::is_alphabetic)
                        && !GENERIC_WORDS.contains(&word.to_lowercase().as_str())
                })
                .collect()
        })
        .collect();
    if let Some(single) = candidates.iter().find(|words| words.len() == 1) {
        return Some(single[0].to_lowercase());
    }
    let mut best: Option<&str> = None;
    for word in candidates.iter().flatten() {
        if best.is_none_or(|b| b.chars().count() < word.chars().count()) {
            best = Some(word);
        }
    }
    best.map(str::to_lowercase)
}

fn named(value: Option<&str>) -> Option<String> {
    let name = value?.trim();
    if name.is_empty() {
        return None;
    }
    if name.chars().count() > 60 {
        let cut: String = name.chars().take(59).collect();
        return Some(format!("{}…", cut.trim_end()));
    }
    Some(name.to_string())
}

// ----------------------------------------------------------------- dates

/// "Nov 12 at 11:00 AM", with the year only once it isn't this year
/// (`AskDateLabel.moment`).
pub fn moment_label(at: DateTime<Utc>, now: DateTime<Local>) -> String {
    let local = at.with_timezone(&Local);
    let full = "%b %-d, %Y at %-I:%M %p";
    let pattern = if lokalbot_i18n::date_locale() != chrono::Locale::en_US {
        lokalbot_i18n::date_pattern(full)
    } else if local.year() == now.year() {
        "%b %-d at %-I:%M %p"
    } else {
        full
    };
    local
        .format_localized(pattern, lokalbot_i18n::date_locale())
        .to_string()
}

/// "Nov 12", with the year only once it isn't this year (`AskDateLabel.day`).
pub fn day_label(at: DateTime<Utc>, now: DateTime<Local>) -> String {
    let local = at.with_timezone(&Local);
    let pattern = if local.year() == now.year() {
        "%b %-d"
    } else {
        "%b %-d, %Y"
    };
    local
        .format_localized(
            lokalbot_i18n::date_pattern(pattern),
            lokalbot_i18n::date_locale(),
        )
        .to_string()
}

/// The divider a question shows above it (`visibleDateDividerTitle`): a
/// conversation that starts today needs none, as each question has its time.
pub fn visible_date_divider(
    created_at: Option<DateTime<Utc>>,
    previous: Option<Option<DateTime<Utc>>>,
    now: DateTime<Local>,
) -> Option<String> {
    if previous.is_none()
        && created_at.is_some_and(|at| at.with_timezone(&Local).date_naive() == now.date_naive())
    {
        return None;
    }
    super::transcript::date_divider(created_at, previous, now)
}

// ------------------------------------------------------------------ text

/// A macOS catalog entry with `%@` / `%lld` fields (or numbered ones), filled
/// in order with `values`.
pub fn fill(template: &str, values: &[&str]) -> String {
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
pub fn mac(key: &str, values: &[&str]) -> String {
    fill(lokalbot_i18n::tr(key), values)
}

/// A count phrase from the macOS catalog: "%lld meeting" / "%lld meetings".
pub fn mac_count(count: usize, one: &str, many: &str) -> String {
    mac(
        if count == 1 { one } else { many },
        &[&lokalbot_i18n::number(count)],
    )
}

/// GPUI drops a number that starts a right-to-left line; a direction mark
/// in front keeps it. Unlike `lokalbot_i18n::directional`, any text in a
/// right-to-left interface gets it, a bare count too.
pub fn directional(text: &str) -> String {
    if lokalbot_i18n::current().rtl && !text.starts_with(lokalbot_i18n::RIGHT_TO_LEFT_MARK) {
        format!("{}{text}", lokalbot_i18n::RIGHT_TO_LEFT_MARK)
    } else {
        text.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone as _;
    use lokalbot_core::AskSourceScope;

    #[test]
    fn return_asks_unless_a_match_was_picked() {
        use ReturnAction::*;
        // The approved key rule: keywords and questions alike are asked.
        assert_eq!(return_action("redis cluster", 3, false), Ask);
        assert_eq!(return_action("redis", 0, false), Ask);
        assert_eq!(return_action("What did we decide?", 3, false), Ask);
        assert_eq!(return_action("Remember that I like tea", 3, false), Ask);
        // Arrow keys picked a row: Return opens it.
        assert_eq!(return_action("redis cluster", 3, true), OpenResult);
        assert_eq!(return_action("What did we decide?", 3, true), OpenResult);
        // Nothing to open and nothing typed.
        assert_eq!(return_action("redis", 0, true), Ask);
        assert_eq!(return_action("   ", 0, false), Nothing);
    }

    #[test]
    fn question_detection_matches_the_mac() {
        assert!(is_question("What did we decide about Redis?"));
        assert!(is_question("redis status?"));
        assert!(is_question("list my recent meetings"));
        assert!(!is_question("redis cluster"));
        assert!(!is_question("what?"));
    }

    #[test]
    fn a_full_question_reads_the_chosen_sources() {
        use AnswerScope::*;
        // A word or a short phrase is answered from its matches.
        assert_eq!(AnswerScope::resolve("failover", true, false), ListedMatches);
        assert_eq!(
            AnswerScope::resolve("redis cluster mode", true, false),
            ListedMatches
        );
        // A question, or four words in any language, reads everything chosen.
        assert_eq!(
            AnswerScope::resolve("failover benchmark?", true, false),
            ChosenSources
        );
        assert_eq!(
            AnswerScope::resolve("šta smo odlučili za klaster", true, false),
            ChosenSources
        );
        assert_eq!(
            AnswerScope::resolve("list my recent meetings", true, false),
            ChosenSources
        );
        // Nothing listed, or a statement to remember: nothing to narrow to.
        assert_eq!(
            AnswerScope::resolve("failover", false, false),
            ChosenSources
        );
        assert_eq!(AnswerScope::resolve("failover", true, true), ChosenSources);
    }

    #[test]
    fn the_phase_keeps_the_conversation_while_typing() {
        let new = AskPhase::new("", false);
        assert!(new.shows_suggestions());
        assert_eq!(new.matches_placement(), None);
        let typing = AskPhase::new("redis", false);
        assert!(!typing.shows_suggestions());
        assert_eq!(
            typing.matches_placement(),
            Some(MatchesPlacement::UnderField)
        );
        let follow_up = AskPhase::new("redis", true);
        assert_eq!(follow_up.page, PageKind::Conversation);
        assert_eq!(
            follow_up.matches_placement(),
            Some(MatchesPlacement::TrayAboveField)
        );
        assert!(!AskPhase::new("  ", true).typing);
    }

    #[test]
    fn the_cursor_moves_between_the_field_and_the_matches() {
        let mut cursor = MatchCursor::default();
        assert!(
            !cursor.step(false, 3),
            "Up in the field stays with the field"
        );
        assert!(cursor.step(true, 3));
        assert_eq!(cursor.index(), Some(0));
        cursor.step(true, 3);
        cursor.step(true, 3);
        cursor.step(true, 3);
        assert_eq!(cursor.index(), Some(2));
        cursor.step(false, 3);
        cursor.step(false, 3);
        assert!(cursor.step(false, 3));
        assert!(!cursor.is_in_matches(), "Up from the first match returns");
        cursor.step(true, 3);
        cursor.step(true, 3);
        cursor.clamp(1);
        assert_eq!(cursor.index(), Some(0));
        cursor.clamp(0);
        assert_eq!(cursor.index(), None);
        assert!(!cursor.step(true, 0));
    }

    #[test]
    fn match_counts_read_like_the_mac() {
        assert_eq!(matches_count_label(1, 3, 0, false), "3 in 1 meeting");
        assert_eq!(matches_count_label(2, 5, 0, false), "5 in 2 meetings");
        assert_eq!(matches_count_label(1, 3, 2, false), "3");
        assert_eq!(matches_count_label(0, 0, 4, false), "4");
        assert_eq!(matches_count_label(40, 90, 0, true), "40+");
    }

    fn input<'a>(meetings: Option<&'a [Uuid]>, screens: Option<&'a [i64]>) -> ScopeInput<'a> {
        ScopeInput {
            sources: Sources::default(),
            effective: Sources::default(),
            offered: Offered::default(),
            meeting_ids: meetings,
            screen_ids: screens,
            widen_to: Sources::default(),
            facet: Facet::All,
            screen_app: None,
        }
    }

    #[test]
    fn the_sources_menu_names_its_limit() {
        let design = Uuid::from_u128(7);
        let title = |id: Uuid| (id == design).then(|| "Design review meeting".to_string());
        let open = scope_summary(&input(None, None), title);
        assert_eq!(open.title, "All sources");
        assert!(!open.narrowed && open.narrowed_to.is_none() && open.widen_title.is_none());

        let one = [design];
        let narrowed = scope_summary(&input(Some(&one), Some(&[])), title);
        assert_eq!(narrowed.title, "Design review meeting");
        assert_eq!(
            narrowed.narrowed_to.as_deref(),
            Some("Design review meeting")
        );
        assert_eq!(narrowed.widen_title.as_deref(), Some("All sources"));

        let two = [design, Uuid::from_u128(8)];
        let counted = scope_summary(&input(Some(&two), Some(&[4])), title);
        assert_eq!(counted.title, "2 meetings, 1 screen moment");

        // Only files matched: the limit names what still reads.
        let mut files_only = input(Some(&[]), Some(&[]));
        files_only.offered = Offered {
            files: true,
            agent_notes: false,
        };
        files_only.effective = Sources {
            meetings: true,
            activity: false,
            screen: true,
            files: true,
            agent_notes: false,
        };
        assert_eq!(scope_summary(&files_only, title).title, "Files");
        files_only.effective.files = false;
        assert_eq!(scope_summary(&files_only, title).title, "No matches");

        let mut filtered = input(None, None);
        filtered.facet = Facet::Summaries;
        filtered.screen_app = Some("Figma");
        let summary = scope_summary(&filtered, title);
        assert_eq!(summary.title, "All sources · Summaries · Figma");
        assert!(summary.has_filters);

        let long = Uuid::from_u128(9);
        let long_title =
            |_: Uuid| Some("A very long meeting title that keeps on going".to_string());
        let cut = scope_summary(&input(Some(&[long]), None), long_title);
        assert_eq!(cut.title.chars().count(), SCOPE_TITLE_LIMIT);
        assert!(cut.title.ends_with('…'));
    }

    #[test]
    fn citations_group_by_source_without_renumbering() {
        let a = CitationSource::Meeting {
            id: "11111111-1111-4111-8111-111111111111".into(),
            at: Some(12.),
        };
        let a_short = CitationSource::Meeting {
            id: "11111111".into(),
            at: Some(35.),
        };
        let file = CitationSource::File { id: 4 };
        let same_file = CitationSource::File { id: 5 };
        let screen = CitationSource::Screen { snapshot_id: 9 };
        let groups = source_groups(
            &[
                a.clone(),
                file.clone(),
                a_short.clone(),
                screen.clone(),
                same_file.clone(),
            ],
            |id| id.starts_with("11111111").then(|| "meeting-a".to_string()),
            |id| (id == 4 || id == 5).then(|| "/docs/eviction.md".to_string()),
        );
        assert_eq!(groups.len(), 3);
        assert_eq!(groups[0].kind, SourceKind::Meeting);
        assert_eq!(
            groups[0].entries.iter().map(|e| e.0).collect::<Vec<_>>(),
            [1, 3]
        );
        assert_eq!(groups[1].kind, SourceKind::File);
        assert_eq!(
            groups[1].entries.iter().map(|e| e.0).collect::<Vec<_>>(),
            [2, 5]
        );
        assert_eq!(groups[2].entries[0].0, 4);
        // A file not known yet keeps its passage on its own row.
        let unknown = source_groups(&[file, same_file], |_| None, |_| None);
        assert_eq!(unknown.len(), 2);
    }

    #[test]
    fn a_citation_quotes_the_line_it_names() {
        let line = |start: f64, end: f64, text: &str| PassageLine {
            start,
            end,
            speaker: "Maya".into(),
            text: text.into(),
        };
        let lines = vec![
            line(2.4, 11.8, "Agreed on Redis."),
            line(12.6, 20.0, "One open question."),
            line(35.2, 40.0, "Please benchmark failover."),
        ];
        assert_eq!(
            passage_line(12., &lines).unwrap().text,
            "One open question."
        );
        assert_eq!(
            passage_line(15., &lines).unwrap().text,
            "One open question."
        );
        assert_eq!(
            passage_line(30., &lines).unwrap().text,
            "One open question."
        );
        assert_eq!(
            passage_line(35., &lines).unwrap().text,
            "Please benchmark failover."
        );
        assert_eq!(passage_line(2., &lines).unwrap().text, "Agreed on Redis.");
        assert!(passage_line(1., &lines).is_none(), "nothing said yet");
        assert!(passage_line(f64::NAN, &lines).is_none());

        assert_eq!(
            quote(Some("  «failover»\nlatency  "), QUOTE_LIMIT).as_deref(),
            Some("failover latency")
        );
        assert_eq!(quote(Some(" \n "), QUOTE_LIMIT), None);
        let long = "word ".repeat(200);
        let cut = quote(Some(&long), 40).unwrap();
        assert!(cut.ends_with('…'));
        assert!(cut.chars().count() <= 41);
        assert!(!cut.contains("wor…"), "cut at a word: {cut}");
    }

    #[test]
    fn snippets_read_as_text() {
        assert_eq!(
            plain_snippet("# «Export failure» review — Nov 10\n**Duration:** 35 min · **App"),
            "«Export failure» review — Nov 10 Duration: 35 min · App"
        );
        assert_eq!(
            plain_snippet("- Benchmark «failover» `latency`\n> quoted"),
            "Benchmark «failover» latency quoted"
        );
        assert_eq!(plain_snippet("plain words"), "plain words");
    }

    #[test]
    fn suggestions_name_the_persons_own_work() {
        let built = suggestions(
            Some("Design review meeting"),
            Some("Maya Chen"),
            Some("Atlas"),
        );
        let texts: Vec<&str> = built.iter().map(|s| s.text.as_str()).collect();
        assert_eq!(
            texts,
            [
                "Where does Atlas stand?",
                "What did we decide in Design review meeting?",
                "What did Maya Chen ask me to do?",
                "atlas",
            ]
        );
        assert_eq!(built[3].kind, SuggestionKind::Keyword);
        let meeting_only = suggestions(Some("Design review meeting"), None, None);
        assert_eq!(meeting_only.last().unwrap().text, "design");
        let none = suggestions(None, Some("  "), None);
        assert!(none.iter().all(|s| s.kind == SuggestionKind::General));
        assert_eq!(none.len(), 3);
        let long = "x".repeat(80);
        let cut = suggestions(Some(&long), None, None);
        assert!(cut[0].text.contains('…'));
    }

    #[test]
    fn keywords_skip_generic_words() {
        assert_eq!(
            keyword(&["Weekly sync".into(), "Atlas cache sizing".into()]),
            Some("sizing".into())
        );
        assert_eq!(keyword(&["Team standup".into()]), None);
        assert_eq!(keyword(&["Q4 budget review".into()]), Some("budget".into()));
    }

    #[test]
    fn ask_again_keeps_the_recorded_scope() {
        let mut question = ChatMessage::new(ChatRole::User, "Where does Atlas stand?");
        question.source_scopes = vec![AskSourceScope::Meetings];
        question.day_scope_key = Some("2026-11-10".into());
        let answer = ChatMessage::new(ChatRole::Assistant, "Atlas is moving to Redis.");
        let messages = vec![question.clone(), answer.clone()];
        let (text, scope) = ask_again(&messages, answer.id).expect("asks again");
        assert_eq!(text, "Where does Atlas stand?");
        assert_eq!(scope.sources, [AskSourceScope::Meetings]);
        assert_eq!(scope.day_scope_key.as_deref(), Some("2026-11-10"));

        let mut failed = answer.clone();
        failed.is_error = true;
        assert!(ask_again(&[question.clone(), failed.clone()], failed.id).is_none());
        let mut attached = question.clone();
        attached.attached_screen_day_keys = vec!["2026-11-10".into()];
        assert!(ask_again(&[attached, answer.clone()], answer.id).is_none());
        let mut legacy = question;
        legacy.source_scopes.clear();
        assert!(ask_again(&[legacy, answer.clone()], answer.id).is_none());
    }

    #[test]
    fn a_conversation_that_starts_today_has_no_divider() {
        let now = Local.with_ymd_and_hms(2026, 10, 18, 15, 0, 0).unwrap();
        let today = Local
            .with_ymd_and_hms(2026, 10, 18, 9, 0, 0)
            .unwrap()
            .with_timezone(&Utc);
        let older = Local
            .with_ymd_and_hms(2026, 10, 8, 9, 0, 0)
            .unwrap()
            .with_timezone(&Utc);
        assert_eq!(visible_date_divider(Some(today), None, now), None);
        assert_eq!(
            visible_date_divider(Some(today), Some(Some(older)), now).as_deref(),
            Some("Today")
        );
        assert_eq!(
            visible_date_divider(Some(older), None, now).as_deref(),
            Some("October 8, 2026")
        );
        assert_eq!(
            visible_date_divider(None, None, now).as_deref(),
            Some("Earlier conversation")
        );
    }

    #[test]
    fn mac_fields_fill_in_order() {
        assert_eq!(fill("Only %@", &["Atlas"]), "Only Atlas");
        assert_eq!(
            fill("%1$lld in %2$lld meetings", &["5", "2"]),
            "5 in 2 meetings"
        );
        assert_eq!(fill("%2$@ before %1$@", &["a", "b"]), "b before a");
        assert_eq!(fill("100% sure, %@", &["yes"]), "100% sure, yes");
    }

    #[test]
    fn dates_carry_the_year_only_when_it_differs() {
        let now = Local.with_ymd_and_hms(2026, 11, 14, 9, 0, 0).unwrap();
        let this_year = Local
            .with_ymd_and_hms(2026, 11, 12, 11, 0, 0)
            .unwrap()
            .with_timezone(&Utc);
        let last_year = Local
            .with_ymd_and_hms(2025, 11, 12, 11, 0, 0)
            .unwrap()
            .with_timezone(&Utc);
        assert_eq!(moment_label(this_year, now), "Nov 12 at 11:00 AM");
        assert_eq!(moment_label(last_year, now), "Nov 12, 2025 at 11:00 AM");
        assert_eq!(day_label(this_year, now), "Nov 12");
        assert_eq!(day_label(last_year, now), "Nov 12, 2025");
    }
}
