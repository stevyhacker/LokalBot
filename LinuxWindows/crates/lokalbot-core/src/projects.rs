//! Projects: tracked projects and recurring topics joined to meetings,
//! actions, decisions, people and window time (`ProjectLinks.swift`,
//! `ProjectTopicDetector.swift`). Matching is deterministic word matching on
//! the project's names; no model decides what belongs to a project.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::sync::LazyLock;

use anyhow::Result;
use chrono::{DateTime, Local, NaiveDate, Utc};
use regex::Regex;
use uuid::Uuid;

use crate::actions::{OutcomeProjection, attention_sorted, cluster_threads};
use crate::library::{Library, read_json, write_json};
use crate::model::*;
use crate::people::{self as people_mod, AppliedNames, PeopleInput, normalized};

pub const REVIEW_DAYS: i64 = 7;
pub const MAXIMUM_WINDOWS: usize = 6;
pub const MAXIMUM_DECISIONS: usize = 8;
pub const MAXIMUM_MENTION_CHARACTERS: usize = 180;
pub const MAXIMUM_MENTIONS_PER_MEETING: usize = 3;
pub const RECENT_OTHERS_ACTION_DAYS: i64 = 14;
pub const MINIMUM_TOPIC_MEETINGS: usize = 3;
pub const MAXIMUM_TOPICS: usize = 10;
const MAXIMUM_PERSON_PROJECTS: usize = 5;
const PERSON_PROJECT_MEETINGS: usize = 20;

const GENERIC_WORDS: &[&str] = &[
    "the",
    "and",
    "for",
    "with",
    "project",
    "work",
    "team",
    "new",
    "update",
    "updates",
    "review",
    "plan",
    "planning",
    "launch",
    "release",
    "meeting",
    "sync",
    "weekly",
    "migration",
    "improvements",
    "support",
    "feature",
    "features",
    "app",
];

/// Words of a project name that can identify it: 3+ characters, not generic.
pub fn significant_terms(name: &str) -> HashSet<String> {
    let key = normalized(name);
    let words: Vec<&str> = key.split(' ').filter(|w| !w.is_empty()).collect();
    let significant: HashSet<String> = words
        .iter()
        .filter(|w| w.chars().count() >= 3 && !GENERIC_WORDS.contains(w))
        .map(|w| w.to_string())
        .collect();
    if significant.is_empty() {
        words
            .iter()
            .filter(|w| w.chars().count() >= 2)
            .map(|w| w.to_string())
            .collect()
    } else {
        significant
    }
}

pub fn words(text: &str) -> HashSet<String> {
    normalized(text)
        .split(' ')
        .filter(|w| !w.is_empty())
        .map(str::to_string)
        .collect()
}

/// Any one of a project's names matches when all its terms are whole words.
pub fn matches_words(term_sets: &[HashSet<String>], words: &HashSet<String>) -> bool {
    term_sets
        .iter()
        .any(|terms| !terms.is_empty() && terms.is_subset(words))
}

pub fn matches(term_sets: &[HashSet<String>], text: &str) -> bool {
    let folded = crate::ids::fold(text);
    let possible = term_sets
        .iter()
        .any(|terms| !terms.is_empty() && terms.iter().all(|t| folded.contains(t.as_str())));
    possible && matches_words(term_sets, &words(text))
}

static LINE_MARKER: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^\s*(#+|[-*•]|\d+\.)\s*").expect("valid regex"));
static CHECKBOX: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^\[[ xX]\]\s*").expect("valid regex"));
static LINE_STAMP: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"\s*[—–-]?\s*\[\d{1,2}:\d{2}(:\d{2})?\]").expect("valid regex"));
static LINE_SPEAKER: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)^(Them|Me|Local|Remote|Speaker)( \d+)?( · source \d+)?:\s*")
        .expect("valid regex")
});

fn cleaned_line(raw: &str) -> String {
    let line = LINE_MARKER.replace(raw, "");
    let line = CHECKBOX.replace(&line, "");
    let line = line.replace("**", "").replace('`', "");
    let line = LINE_STAMP.replace_all(&line, "");
    LINE_SPEAKER.replace(&line, "").trim().to_string()
}

/// The line when it fits, else a window starting a little before the name.
pub fn excerpt(line: &str, term_sets: &[HashSet<String>], limit: usize) -> String {
    let text = line.trim();
    let chars: Vec<char> = text.chars().collect();
    let count = chars.len();
    if count <= limit {
        return text.to_string();
    }
    let all_terms: HashSet<&String> = term_sets.iter().flatten().collect();
    let mut anchor = 0;
    let mut index = 0;
    while index < count {
        if chars[index].is_alphanumeric() {
            let start = index;
            while index < count && chars[index].is_alphanumeric() {
                index += 1;
            }
            let word: String = chars[start..index].iter().collect();
            if words(&word).iter().any(|w| all_terms.contains(w)) {
                anchor = start;
                break;
            }
        } else {
            index += 1;
        }
    }
    let mut start = anchor
        .saturating_sub(50)
        .min(count.saturating_sub(limit - 2));
    if start > 0 && chars[start - 1] != ' ' {
        let mut next = start;
        while next < anchor && chars[next] != ' ' {
            next += 1;
        }
        start = if next < anchor { next + 1 } else { anchor };
    }
    let budget = limit - usize::from(start > 0) - 1;
    let mut end = count.min(start + budget);
    if end < count && chars[end] != ' ' {
        let mut previous = end - 1;
        while previous > anchor && chars[previous] != ' ' {
            previous -= 1;
        }
        if previous > anchor {
            end = previous;
        }
    }
    let mut result: String = chars[start..end]
        .iter()
        .collect::<String>()
        .trim()
        .to_string();
    if start > 0 {
        result = format!("…{result}");
    }
    if end < count {
        result.push('…');
    }
    result
}

// --------------------------------------------------------- topic detector

const COMMON_APPS: &[&str] = &[
    "chrome",
    "google",
    "safari",
    "firefox",
    "slack",
    "zoom",
    "discord",
    "telegram",
    "notion",
    "github",
    "gitlab",
    "figma",
    "claude",
    "chatgpt",
    "openai",
    "anthropic",
    "cursor",
    "xcode",
    "finder",
    "meet",
    "teams",
    "microsoft",
    "apple",
    "mac",
    "macos",
    "ios",
    "iphone",
    "android",
    "whatsapp",
    "viber",
    "signal",
    "spotify",
    "youtube",
    "twitter",
    "linkedin",
    "gmail",
    "calendar",
    "jira",
    "linear",
    "loom",
    "docs",
    "sheets",
    "drive",
    "dropbox",
    "vscode",
    "zed",
    "windows",
    "linux",
    "ubuntu",
    "edge",
    "outlook",
    "libreoffice",
    "thunderbird",
    "davinci",
    "resolve",
    "explorer",
];

const TOPIC_STOP_WORDS: &[&str] = &[
    "the",
    "and",
    "for",
    "with",
    "from",
    "into",
    "onto",
    "about",
    "after",
    "before",
    "this",
    "that",
    "these",
    "those",
    "its",
    "our",
    "your",
    "their",
    "they",
    "them",
    "she",
    "his",
    "her",
    "him",
    "are",
    "was",
    "were",
    "been",
    "being",
    "does",
    "did",
    "done",
    "have",
    "has",
    "had",
    "will",
    "would",
    "should",
    "could",
    "can",
    "may",
    "might",
    "must",
    "not",
    "yes",
    "all",
    "any",
    "some",
    "each",
    "every",
    "both",
    "either",
    "neither",
    "other",
    "another",
    "such",
    "only",
    "also",
    "just",
    "very",
    "more",
    "most",
    "less",
    "least",
    "many",
    "much",
    "few",
    "first",
    "last",
    "next",
    "new",
    "old",
    "same",
    "different",
    "own",
    "there",
    "here",
    "then",
    "than",
    "when",
    "where",
    "what",
    "which",
    "who",
    "why",
    "how",
    "once",
    "while",
    "until",
    "because",
    "per",
    "via",
    "but",
    "nor",
    "yet",
    "please",
    "thanks",
    "thank",
    "okay",
    "monday",
    "tuesday",
    "wednesday",
    "thursday",
    "friday",
    "saturday",
    "sunday",
    "january",
    "february",
    "march",
    "april",
    "june",
    "july",
    "august",
    "september",
    "october",
    "november",
    "december",
    "today",
    "tomorrow",
    "yesterday",
    "week",
    "weekly",
    "daily",
    "monthly",
    "quarter",
    "key",
    "points",
    "decisions",
    "decision",
    "action",
    "actions",
    "items",
    "item",
    "open",
    "questions",
    "question",
    "summary",
    "recap",
    "notes",
    "note",
    "steps",
    "step",
    "template",
    "language",
    "duration",
    "model",
    "words",
    "meeting",
    "meetings",
    "team",
    "discussion",
    "update",
    "updates",
    "review",
    "plan",
    "planning",
    "sync",
    "standup",
    "stand-up",
    "demo",
    "day",
    "call",
    "product",
    "agenda",
    "follow-up",
    "followup",
    "owner",
    "owners",
    "local",
    "speaker",
    "source",
    "unknown",
    "likely",
    "agreed",
    "discussed",
    "confirmed",
    "need",
    "needs",
    "check",
    "share",
    "send",
    "look",
    "ask",
    "set",
    "add",
    "use",
    "make",
    "keep",
    "get",
    "tldr",
    "api",
    "apis",
    "json",
    "sdk",
    "prs",
    "llm",
    "llms",
    "poc",
    "mvp",
    "eta",
    "ui",
    "ux",
    "url",
    "urls",
    "http",
    "https",
    "sql",
    "csv",
    "pdf",
    "ids",
    "okr",
    "okrs",
    "kpi",
    "kpis",
    "gpu",
    "cpu",
    "ram",
    "eod",
    "eow",
    "fyi",
    "tbd",
    "utc",
    "cet",
    "cest",
    "usd",
    "eur",
    "moe",
    "qa",
    "faq",
    "etc",
    "asap",
    "cto",
    "ceo",
    "cfo",
    "dev",
    "devs",
    "ops",
    "repo",
    "repos",
    "doc",
    "labs",
    "inc",
    "ltd",
    "llc",
];

/// A recurring capitalized term (`ProjectTopicDetector.Topic`).
#[derive(Clone, Debug, PartialEq)]
pub struct Topic {
    pub name: String,
    pub meeting_ids: HashSet<Uuid>,
    pub last_mentioned: DateTime<Utc>,
}

fn topic_tokens(text: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut current = String::new();
    for c in text.chars() {
        if c.is_alphanumeric() || (c == '-' && !current.is_empty()) {
            current.push(c);
        } else if !current.is_empty() {
            out.push(current.trim_matches('-').to_string());
            current.clear();
        }
    }
    if !current.is_empty() {
        out.push(current.trim_matches('-').to_string());
    }
    out.retain(|w| !w.is_empty());
    out
}

fn within_one_edit(lhs: &str, rhs: &str) -> bool {
    let (left, right): (Vec<char>, Vec<char>) = (lhs.chars().collect(), rhs.chars().collect());
    if left.len().abs_diff(right.len()) > 1 {
        return false;
    }
    let (mut i, mut j, mut edits) = (0, 0, 0);
    while i < left.len() && j < right.len() {
        if left[i] == right[j] {
            i += 1;
            j += 1;
            continue;
        }
        edits += 1;
        if edits > 1 {
            return false;
        }
        match left.len().cmp(&right.len()) {
            std::cmp::Ordering::Greater => i += 1,
            std::cmp::Ordering::Less => j += 1,
            std::cmp::Ordering::Equal => {
                i += 1;
                j += 1;
            }
        }
    }
    edits + (left.len() - i) + (right.len() - j) <= 1
}

fn summary_body(summary: &str) -> String {
    summary
        .lines()
        .filter(|line| {
            let trimmed = line.trim();
            !trimmed.starts_with("# ")
                && !trimmed.contains("**Duration:**")
                && !trimmed.contains("**Template:**")
                && !trimmed.contains("**Model:**")
        })
        .collect::<Vec<_>>()
        .join("\n")
}

/// Proper nouns that recur across three or more meetings.
pub fn detect_topics(
    meetings: &[&Meeting],
    summaries: &HashMap<Uuid, String>,
    projections: &HashMap<Uuid, &OutcomeProjection>,
    excluded_words: &HashSet<String>,
) -> Vec<Topic> {
    let excluded: HashSet<String> = excluded_words
        .iter()
        .map(|w| w.to_lowercase())
        .chain(TOPIC_STOP_WORDS.iter().map(|w| w.to_string()))
        .chain(COMMON_APPS.iter().map(|w| w.to_string()))
        .collect();
    let near_names: Vec<String> = excluded_words
        .iter()
        .map(|w| w.to_lowercase())
        .filter(|w| w.chars().count() >= 5)
        .collect();
    let mut surface: HashMap<String, BTreeMap<String, usize>> = HashMap::new();
    let mut meetings_by_term: HashMap<String, HashSet<Uuid>> = HashMap::new();
    let mut last: HashMap<String, DateTime<Utc>> = HashMap::new();
    let mut capitalized: HashMap<String, usize> = HashMap::new();
    let mut lowercase: HashMap<String, usize> = HashMap::new();
    let mut sentence_starts: HashMap<String, HashSet<Uuid>> = HashMap::new();
    let mut sentence_dates: HashMap<String, DateTime<Utc>> = HashMap::new();

    let mut scan = |text: &str, meeting: &Meeting, skip_sentence_start: bool| {
        for sentence in text.split(['.', '!', '?', ':', ';', '\n']) {
            for (index, word) in topic_tokens(sentence).into_iter().enumerate() {
                let key = word.to_lowercase();
                if word == key {
                    *lowercase.entry(word).or_default() += 1;
                    continue;
                }
                if skip_sentence_start && index == 0 {
                    if word.chars().count() >= 3 && !excluded.contains(&key) {
                        sentence_starts
                            .entry(key.clone())
                            .or_default()
                            .insert(meeting.id);
                        let date = sentence_dates.entry(key).or_insert(meeting.started_at);
                        *date = (*date).max(meeting.started_at);
                    }
                    continue;
                }
                if word.chars().count() < 3
                    || excluded.contains(&key)
                    || !word.chars().any(char::is_uppercase)
                    || !word.chars().any(char::is_alphabetic)
                {
                    continue;
                }
                *capitalized.entry(key.clone()).or_default() += 1;
                *surface
                    .entry(key.clone())
                    .or_default()
                    .entry(word.clone())
                    .or_default() += 1;
                meetings_by_term
                    .entry(key.clone())
                    .or_default()
                    .insert(meeting.id);
                let date = last.entry(key).or_insert(meeting.started_at);
                *date = (*date).max(meeting.started_at);
            }
        }
    };
    for meeting in meetings.iter().filter(|m| !m.is_merged_source()) {
        scan(
            meeting.calendar_title.as_deref().unwrap_or(&meeting.title),
            meeting,
            false,
        );
        if let Some(summary) = summaries.get(&meeting.id) {
            scan(&summary_body(summary), meeting, true);
        }
        if let Some(projection) = projections.get(&meeting.id) {
            for reference in projection.action_references() {
                scan(&reference.text, meeting, true);
            }
            for decision in &projection.outcomes.decision_records {
                scan(&decision.text, meeting, true);
            }
        }
    }
    for (key, ids) in sentence_starts {
        if let Some(set) = meetings_by_term.get_mut(&key) {
            set.extend(ids);
            if let Some(date) = sentence_dates.get(&key) {
                let entry = last.entry(key).or_insert(*date);
                *entry = (*entry).max(*date);
            }
        }
    }
    let mut topics: Vec<Topic> = meetings_by_term
        .into_iter()
        .filter_map(|(key, ids)| {
            if ids.len() < MINIMUM_TOPIC_MEETINGS
                || capitalized.get(&key).copied().unwrap_or(0)
                    < 3 * lowercase.get(&key).copied().unwrap_or(0)
                || (key.chars().count() >= 5
                    && near_names.iter().any(|n| {
                        n.chars().next() == key.chars().next() && within_one_edit(n, &key)
                    }))
            {
                return None;
            }
            let forms = surface.get(&key)?;
            let form = forms
                .iter()
                .max_by(|a, b| a.1.cmp(b.1).then(b.0.cmp(a.0)))
                .map(|(f, _)| f.clone())?;
            Some(Topic {
                name: form,
                last_mentioned: last.get(&key).copied().unwrap_or_default(),
                meeting_ids: ids,
            })
        })
        .collect();
    topics.sort_by(|a, b| {
        b.meeting_ids
            .len()
            .cmp(&a.meeting_ids.len())
            .then(b.last_mentioned.cmp(&a.last_mentioned))
            .then(a.name.cmp(&b.name))
    });
    topics.truncate(MAXIMUM_TOPICS);
    topics
}

// --------------------------------------------------------------- profiles

struct MeetingText<'a> {
    meeting: &'a Meeting,
    title_words: HashSet<String>,
    words: HashSet<String>,
    summary_lines: Vec<String>,
    outcome_texts: Vec<String>,
    transcript: Vec<(f64, String)>,
    transcript_words: HashSet<String>,
}

struct Context<'a> {
    texts: Vec<MeetingText<'a>>,
    threads: Vec<ActionThread>,
    projections: &'a [OutcomeProjection],
    activity: Vec<ActivityBlock>,
    people: &'a [PersonProfile],
    window_start: DateTime<Utc>,
    now: DateTime<Utc>,
    today: NaiveDate,
}

fn summary_mentions(
    term_sets: &[HashSet<String>],
    meeting_id: Uuid,
    lines: &[String],
) -> Vec<ProjectMention> {
    let mut out = Vec::new();
    for raw in lines {
        if raw.starts_with("# ") || !matches_words(term_sets, &words(raw)) {
            continue;
        }
        let line = cleaned_line(raw);
        if line.chars().count() < 12 || !matches(term_sets, &line) {
            continue;
        }
        out.push(ProjectMention {
            meeting_id,
            text: excerpt(&line, term_sets, MAXIMUM_MENTION_CHARACTERS),
            seek: None,
        });
        if out.len() == MAXIMUM_MENTIONS_PER_MEETING {
            break;
        }
    }
    out
}

fn transcript_mentions(
    term_sets: &[HashSet<String>],
    meeting_id: Uuid,
    lines: &[(f64, String)],
) -> Vec<ProjectMention> {
    let mut out = Vec::new();
    let mut index = 0;
    while index < lines.len() && out.len() < MAXIMUM_MENTIONS_PER_MEETING {
        if !matches(term_sets, &lines[index].1) {
            index += 1;
            continue;
        }
        let mut text = lines[index].1.clone();
        let mut next = index + 1;
        while text.chars().count() < 100 && next < lines.len() && next <= index + 2 {
            text = format!("{text} {}", lines[next].1);
            next += 1;
        }
        out.push(ProjectMention {
            meeting_id,
            text: excerpt(&text, term_sets, MAXIMUM_MENTION_CHARACTERS),
            seek: Some(lines[index].0),
        });
        index = next;
    }
    out
}

fn is_recent(thread: &ActionThread, today: NaiveDate) -> bool {
    if thread.resolved_due_date.is_some_and(|due| due >= today) {
        return true;
    }
    let cutoff = today - chrono::Duration::days(RECENT_OTHERS_ACTION_DAYS);
    crate::time::local_day(thread.latest().meeting_started_at) >= cutoff
}

fn profile(
    id: String,
    name: String,
    kind: ProjectKind,
    other_names: Vec<String>,
    term_sets: Vec<HashSet<String>>,
    context: &Context,
) -> ProjectProfile {
    let mut linked: Vec<(&Meeting, Vec<ProjectMention>)> = Vec::new();
    let mut titled: HashSet<Uuid> = HashSet::new();
    for text in &context.texts {
        if matches_words(&term_sets, &text.title_words) {
            titled.insert(text.meeting.id);
        }
        let in_text = matches_words(&term_sets, &text.words);
        let in_transcript = matches_words(&term_sets, &text.transcript_words);
        if !in_text && !in_transcript {
            continue;
        }
        let mut mentions = summary_mentions(&term_sets, text.meeting.id, &text.summary_lines);
        if mentions.is_empty() {
            mentions = transcript_mentions(&term_sets, text.meeting.id, &text.transcript);
        }
        if mentions.is_empty()
            && let Some(outcome) = text.outcome_texts.iter().find(|o| matches(&term_sets, o))
        {
            mentions.push(ProjectMention {
                meeting_id: text.meeting.id,
                text: excerpt(outcome, &term_sets, MAXIMUM_MENTION_CHARACTERS),
                seek: None,
            });
        }
        linked.push((text.meeting, mentions));
    }
    linked.sort_by_key(|(m, _)| std::cmp::Reverse(m.started_at));
    let linked_ids: HashSet<Uuid> = linked.iter().map(|(m, _)| m.id).collect();

    let actions: Vec<ActionThread> = context
        .threads
        .iter()
        .filter(|t| {
            matches(&term_sets, &t.text)
                || t.references.iter().any(|r| titled.contains(&r.meeting_id))
        })
        .cloned()
        .collect();
    let (mut mine, mut others, mut older) = (Vec::new(), Vec::new(), Vec::new());
    for thread in attention_sorted(actions, context.today) {
        if thread.is_for_user() {
            mine.push(thread);
        } else if is_recent(&thread, context.today) {
            others.push(thread);
        } else {
            older.push(thread);
        }
    }

    let mut per_day: BTreeMap<String, f64> = BTreeMap::new();
    let mut per_window: HashMap<(String, String), f64> = HashMap::new();
    for block in context
        .activity
        .iter()
        .filter(|b| b.end > context.window_start && b.start < context.now)
    {
        if !matches(&term_sets, &block.title) {
            continue;
        }
        let start = block.start.max(context.window_start);
        let end = block.end.min(context.now);
        if end <= start {
            continue;
        }
        let seconds = (end - start).num_milliseconds() as f64 / 1000.0;
        *per_day
            .entry(crate::time::local_day(start).format("%Y-%m-%d").to_string())
            .or_default() += seconds;
        let title = crate::timeline::strip_browser_chrome(&block.title);
        *per_window.entry((block.app.clone(), title)).or_default() += seconds;
    }
    let mut days: Vec<(String, f64)> = per_day.into_iter().collect();
    days.sort_by(|a, b| b.0.cmp(&a.0));
    let mut windows: Vec<ProjectWindowTime> = per_window
        .into_iter()
        .map(|((app, title), seconds)| ProjectWindowTime {
            app,
            title,
            seconds,
        })
        .collect();
    windows.sort_by(|a, b| {
        b.seconds
            .partial_cmp(&a.seconds)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then(a.title.cmp(&b.title))
    });
    windows.truncate(MAXIMUM_WINDOWS);

    let mut decisions: Vec<(MeetingRef, Decision)> = context
        .projections
        .iter()
        .filter(|p| linked_ids.contains(&p.meeting.id))
        .flat_map(|p| {
            p.outcomes
                .decision_records
                .iter()
                .filter(|d| matches(&term_sets, &d.text))
                .map(move |d| (people_mod::meeting_ref(&p.meeting), d.clone()))
        })
        .collect();
    decisions.sort_by_key(|(m, _)| std::cmp::Reverse(m.started_at));
    decisions.truncate(MAXIMUM_DECISIONS);

    let mut related: Vec<(&PersonProfile, usize)> = context
        .people
        .iter()
        .map(|p| {
            (
                p,
                p.meetings
                    .iter()
                    .filter(|m| linked_ids.contains(&m.id))
                    .count(),
            )
        })
        .filter(|(_, n)| *n > 0)
        .collect();
    related.sort_by_key(|a| std::cmp::Reverse(a.1));
    let people: Vec<String> = related
        .into_iter()
        .take(8)
        .map(|(p, _)| p.name.clone())
        .collect();

    let mut last_active = linked.first().map(|(m, _)| m.started_at);
    if let Some((day, _)) = days.first()
        && let Ok(date) = NaiveDate::parse_from_str(day, "%Y-%m-%d")
    {
        let start = crate::time::local_day_bounds(date).0;
        last_active = Some(last_active.map_or(start, |l| l.max(start)));
    }
    let week_seconds = days.iter().map(|(_, s)| s).sum();
    ProjectProfile {
        id,
        kind,
        name,
        other_names,
        meetings: linked
            .iter()
            .map(|(m, _)| people_mod::meeting_ref(m))
            .collect(),
        mentions: linked
            .into_iter()
            .flat_map(|(_, mentions)| mentions)
            .collect(),
        my_actions: mine,
        others_actions: others,
        older_others_actions: older,
        decisions,
        people,
        week_seconds,
        days,
        windows,
        last_active,
        summary: None,
    }
}

/// People (with notes and project links) and projects, built together
/// because each refers to the other.
pub fn build_people_and_projects(
    library: &Library,
) -> Result<(Vec<PersonProfile>, Vec<ProjectProfile>)> {
    let meetings: Vec<Meeting> = library.list_own_meetings()?;
    let projections: Vec<OutcomeProjection> = meetings
        .iter()
        .filter_map(|m| library.outcome_projection(m).ok().flatten())
        .collect();
    let applied: HashMap<Uuid, AppliedNames> = library.applied_names(&meetings);
    let self_names = library.self_names();
    let curation = library.people_curation().unwrap_or_default();
    let now = Utc::now();
    let today = Local::now().date_naive();
    let mut people = people_mod::build_people(&PeopleInput {
        meetings: &meetings,
        projections: &projections,
        applied: &applied,
        self_names: &self_names,
        curation: &curation,
        today,
    });

    let summaries: HashMap<Uuid, String> = meetings
        .iter()
        .filter_map(|m| library.summary(m).ok().flatten().map(|s| (m.id, s)))
        .collect();
    let transcripts: HashMap<Uuid, Transcript> = meetings
        .iter()
        .filter_map(|m| library.transcript(m).ok().flatten().map(|t| (m.id, t)))
        .collect();
    let window_start =
        crate::time::local_day_bounds(today - chrono::Duration::days(REVIEW_DAYS - 1)).0;
    let activity = library
        .activity_blocks(window_start, now)
        .unwrap_or_default();
    let mut outcome_texts: HashMap<Uuid, Vec<String>> = HashMap::new();
    for projection in &projections {
        let mut texts: Vec<String> = projection
            .action_references()
            .into_iter()
            .map(|r| r.text)
            .collect();
        texts.extend(
            projection
                .outcomes
                .decision_records
                .iter()
                .map(|d| d.text.clone()),
        );
        outcome_texts
            .entry(projection.meeting.id)
            .or_default()
            .extend(texts);
    }
    let texts: Vec<MeetingText> = meetings
        .iter()
        .map(|meeting| {
            let summary = summaries.get(&meeting.id).cloned().unwrap_or_default();
            let outcomes = outcome_texts.remove(&meeting.id).unwrap_or_default();
            let mut title_words = words(&meeting.display_title());
            title_words.extend(words(meeting.calendar_title.as_deref().unwrap_or("")));
            let mut all_words = title_words.clone();
            all_words.extend(words(&summary));
            for text in &outcomes {
                all_words.extend(words(text));
            }
            let transcript: Vec<(f64, String)> = transcripts
                .get(&meeting.id)
                .map(|t| {
                    t.segments
                        .iter()
                        .map(|s| (s.start, Transcript::display_text(&s.text)))
                        .filter(|(_, text)| !text.is_empty())
                        .collect()
                })
                .unwrap_or_default();
            let transcript_words = transcript.iter().flat_map(|(_, t)| words(t)).collect();
            MeetingText {
                meeting,
                title_words,
                words: all_words,
                summary_lines: summary.lines().map(str::to_string).collect(),
                outcome_texts: outcomes,
                transcript,
                transcript_words,
            }
        })
        .collect();
    let threads: Vec<ActionThread> = cluster_threads(
        projections
            .iter()
            .flat_map(|p| p.action_references())
            .collect(),
    )
    .into_iter()
    .filter(|t| t.status() != ActionStatus::Done)
    .collect();
    let context = Context {
        texts,
        threads,
        projections: &projections,
        activity: activity.clone(),
        people: &people,
        window_start,
        now,
        today,
    };

    let project_curation = library.project_curation().unwrap_or_default();
    let saved_summaries = library.project_summaries().unwrap_or_default();
    let mut projects: Vec<ProjectProfile> = Vec::new();
    let mut tracked_terms: Vec<HashSet<String>> = Vec::new();
    for project in &project_curation.tracked {
        let names: Vec<String> = std::iter::once(project.name.clone())
            .chain(project.other_names.clone())
            .collect();
        let term_sets: Vec<HashSet<String>> = names.iter().map(|n| significant_terms(n)).collect();
        tracked_terms.extend(term_sets.iter().cloned());
        projects.push(profile(
            format!("tracked:{}", crate::ids::uuid_upper(&project.id)),
            project.name.clone(),
            ProjectKind::Tracked,
            project.other_names.clone(),
            term_sets,
            &context,
        ));
    }

    let mut excluded: HashSet<String> = HashSet::new();
    for person in context.people {
        for name in std::iter::once(&person.name).chain(&person.other_names) {
            excluded.extend(words(name));
        }
    }
    for name in &self_names {
        excluded.extend(words(name));
    }
    for block in &activity {
        excluded.extend(words(&block.app));
    }
    for meeting in &meetings {
        excluded.extend(words(&meeting.app_name));
    }
    excluded.extend(
        project_curation
            .hidden_names
            .iter()
            .filter(|n| !n.contains(' '))
            .cloned(),
    );
    for terms in tracked_terms.iter().filter(|t| t.len() == 1) {
        excluded.extend(terms.iter().cloned());
    }
    let meeting_refs: Vec<&Meeting> = meetings.iter().collect();
    let projection_map: HashMap<Uuid, &OutcomeProjection> =
        projections.iter().map(|p| (p.meeting.id, p)).collect();
    let hidden: HashSet<String> = project_curation
        .hidden_names
        .iter()
        .map(|n| normalized(n))
        .collect();
    let mut topic_profiles: Vec<ProjectProfile> = Vec::new();
    for topic in detect_topics(&meeting_refs, &summaries, &projection_map, &excluded) {
        let key = normalized(&topic.name);
        if hidden.contains(&key) || tracked_terms.iter().any(|t| t.contains(&key)) {
            continue;
        }
        topic_profiles.push(profile(
            format!("topic:{key}"),
            topic.name.clone(),
            ProjectKind::Suggested,
            Vec::new(),
            vec![HashSet::from([key])],
            &context,
        ));
    }
    topic_profiles.sort_by(|a, b| {
        b.meetings
            .len()
            .cmp(&a.meetings.len())
            .then(b.last_active.cmp(&a.last_active))
    });
    projects.extend(topic_profiles);
    let live: HashSet<String> = meetings
        .iter()
        .map(|m| crate::ids::uuid_upper(&m.id))
        .collect();
    for project in &mut projects {
        project.summary = saved_summaries
            .iter()
            .find(|s| {
                s.project_id == project.id
                    && s.meeting_ids
                        .iter()
                        .all(|id| live.contains(&id.to_uppercase()))
            })
            .cloned();
    }

    // People's recent notes and project links (`WorkMemoryConnections`).
    let lines: HashMap<Uuid, Vec<people_mod::SummaryLine>> = summaries
        .iter()
        .map(|(id, summary)| (*id, people_mod::summary_lines(summary)))
        .collect();
    for person in &mut people {
        if let Some((meeting, points)) = people_mod::recent_notes(person, &lines, &applied) {
            person.notes_meeting = Some(meeting);
            person.recent_notes = points;
        }
        let mut texts: Vec<String> = Vec::new();
        for occasion in people_mod::occasions(&person.meetings)
            .iter()
            .take(PERSON_PROJECT_MEETINGS)
        {
            for recording in occasion {
                for line in lines.get(&recording.id).into_iter().flatten() {
                    if people_mod::line_is_about(line, person, applied.get(&recording.id)) {
                        texts.push(line.text.clone());
                    }
                }
            }
        }
        texts.extend(person.their_actions.iter().map(|t| t.text.clone()));
        texts.extend(person.my_actions.iter().map(|t| t.text.clone()));
        texts.extend(person.decisions.iter().map(|(_, d)| d.text.clone()));
        let word_sets: Vec<HashSet<String>> = texts.iter().map(|t| words(t)).collect();
        let mut links: Vec<ProjectLink> = projects
            .iter()
            .filter_map(|project| {
                let term_sets: Vec<HashSet<String>> = std::iter::once(&project.name)
                    .chain(&project.other_names)
                    .map(|n| significant_terms(n))
                    .collect();
                let mentions = word_sets
                    .iter()
                    .filter(|w| matches_words(&term_sets, w))
                    .count();
                (mentions > 0).then(|| ProjectLink {
                    id: project.id.clone(),
                    name: project.name.clone(),
                    is_tracked: project.is_tracked(),
                    mentions,
                })
            })
            .collect();
        links.sort_by(|a, b| {
            b.is_tracked
                .cmp(&a.is_tracked)
                .then(b.mentions.cmp(&a.mentions))
                .then(a.name.cmp(&b.name))
        });
        links.truncate(MAXIMUM_PERSON_PROJECTS);
        person.projects = links.iter().map(|l| l.name.clone()).collect();
        person.project_links = links;
    }
    Ok((people, projects))
}

impl Library {
    /// Tracked projects first, then suggested topics by meeting count.
    pub fn projects(&self) -> Result<Vec<ProjectProfile>> {
        Ok(build_people_and_projects(self)?.1)
    }

    pub fn project_curation(&self) -> Result<ProjectCuration> {
        Ok(read_json(&self.paths().projects_dir().join("tracked.json"))?.unwrap_or_default())
    }

    pub fn save_project_curation(&self, curation: &ProjectCuration) -> Result<()> {
        write_json(&self.paths().projects_dir().join("tracked.json"), curation)
    }

    /// Saved "Where it stands" notes, with profile ids (`tracked:<UUID>`) and
    /// local `YYYY-MM-DD` meeting dates.
    pub fn project_summaries(&self) -> Result<Vec<ProjectSummary>> {
        let stored: Vec<ProjectSummary> =
            read_json(&self.paths().projects_dir().join("summaries.json"))?.unwrap_or_default();
        Ok(stored.into_iter().map(summary_from_disk).collect())
    }

    /// Replaces the note for `summary.project_id`; the file stays sorted by ID.
    pub fn save_project_summary(&self, summary: ProjectSummary) -> Result<()> {
        let mut all = self.project_summaries()?;
        all.retain(|s| s.project_id != summary.project_id);
        all.push(summary);
        write_project_summaries(&self.paths().projects_dir().join("summaries.json"), all)
    }
}

/// Writes `projects/summaries.json` the way macOS reads it (`ProjectStore`):
/// a bare project UUID and ISO-8601 meeting dates. macOS decodes the file as
/// a whole, so a note that is not for a tracked project is left out.
pub(crate) fn write_project_summaries(
    path: &std::path::Path,
    summaries: Vec<ProjectSummary>,
) -> Result<()> {
    let mut disk: Vec<ProjectSummary> = summaries.into_iter().filter_map(summary_to_disk).collect();
    disk.sort_by(|a, b| a.project_id.cmp(&b.project_id));
    write_json(path, &disk)
}

fn summary_from_disk(mut summary: ProjectSummary) -> ProjectSummary {
    if let Ok(id) = Uuid::parse_str(&summary.project_id) {
        summary.project_id = format!("tracked:{}", crate::ids::uuid_upper(&id));
    }
    for point in &mut summary.points {
        if let Some(date) = point
            .meeting_date
            .as_deref()
            .and_then(crate::time::parse_iso)
        {
            point.meeting_date = Some(crate::time::local_day(date).format("%Y-%m-%d").to_string());
        }
    }
    summary
}

fn summary_to_disk(mut summary: ProjectSummary) -> Option<ProjectSummary> {
    let id = summary
        .project_id
        .strip_prefix("tracked:")
        .unwrap_or(&summary.project_id);
    let Ok(id) = Uuid::parse_str(id) else {
        log::warn!(
            "not saving a project note for untracked project {}",
            summary.project_id
        );
        return None;
    };
    summary.project_id = crate::ids::uuid_upper(&id);
    for point in &mut summary.points {
        if let Some(raw) = point.meeting_date.take() {
            point.meeting_date = if crate::time::parse_iso(&raw).is_some() {
                Some(raw)
            } else {
                NaiveDate::parse_from_str(&raw, "%Y-%m-%d").ok().map(|day| {
                    crate::time::local_day_bounds(day)
                        .0
                        .to_rfc3339_opts(chrono::SecondsFormat::Secs, true)
                })
            };
        }
    }
    Some(summary)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn project_summaries_are_stored_the_way_macos_reads_them() {
        let dir = tempfile::tempdir().unwrap();
        let library = Library::open(crate::LibraryPaths::new(dir.path())).unwrap();
        let id = Uuid::new_v4();
        let summary = ProjectSummary {
            project_id: format!("tracked:{}", crate::ids::uuid_upper(&id)),
            overview: "The order waits for the quote.".into(),
            points: vec![ProjectPoint {
                text: "Exports are slow.".into(),
                meeting_id: Some(crate::ids::uuid_upper(&Uuid::new_v4())),
                meeting_title: Some("Laptop refresh".into()),
                meeting_date: Some("2026-10-15".into()),
            }],
            open_questions: Vec::new(),
            meeting_ids: Vec::new(),
            evidence_fingerprint: "abc".into(),
            generated_at: crate::time::parse_iso("2026-10-18T09:00:00Z").unwrap(),
            engine_name: "Qwen3.5 4B".into(),
            location: "on this PC".into(),
        };
        library.save_project_summary(summary.clone()).unwrap();
        let mut untracked = summary.clone();
        untracked.project_id = "topic:northwind".into();
        library.save_project_summary(untracked).unwrap();

        let path = dir.path().join("projects").join("summaries.json");
        let raw: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
        let entries = raw.as_array().unwrap();
        assert_eq!(
            entries.len(),
            1,
            "untracked notes would break the macOS decoder"
        );
        assert_eq!(entries[0]["projectID"], crate::ids::uuid_upper(&id));
        let date = entries[0]["points"][0]["meetingDate"].as_str().unwrap();
        assert!(crate::time::parse_iso(date).is_some(), "{date}");

        let loaded = library.project_summaries().unwrap();
        assert_eq!(loaded, vec![summary]);
    }

    #[test]
    fn significant_terms_skip_generic_words() {
        let terms = significant_terms("Laptop refresh project");
        assert!(
            terms.contains("laptop") && terms.contains("refresh") && !terms.contains("project")
        );
        assert_eq!(significant_terms("QA"), HashSet::from(["qa".to_string()]));
        let sets = vec![significant_terms("Laptop refresh")];
        assert!(matches(&sets, "Price the laptop REFRESH configs"));
        assert!(!matches(&sets, "Price the laptops"));
    }

    #[test]
    fn excerpt_cuts_around_the_name() {
        let line = format!(
            "{} Northwind needs captions before launch {}",
            "word ".repeat(40),
            "tail ".repeat(40)
        );
        let cut = excerpt(&line, &[significant_terms("Northwind")], 60);
        assert!(cut.starts_with('…') && cut.ends_with('…'), "{cut}");
        assert!(cut.contains("Northwind"));
        assert!(cut.chars().count() <= 60);
    }

    #[test]
    fn one_edit_apart() {
        assert!(within_one_edit("milena", "milana"));
        assert!(within_one_edit("milena", "milen"));
        assert!(!within_one_edit("milena", "marko"));
    }
}
