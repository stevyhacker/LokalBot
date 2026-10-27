//! The Day Digest journal read back for display (`DayDigestPresentation.swift`)
//! and its freshness (`DayDigestLifecycle.swift`).
//!
//! The journal stays the lossless format; this only gives the UI a
//! scannable hierarchy for both new and legacy journals.

use std::sync::LazyLock;

use anyhow::Result;
use chrono::{DateTime, NaiveDate, Utc};
use regex::Regex;

use crate::library::Library;
use crate::model::*;

static SCREEN_ID: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"\[screen:(\d+)\]").expect("valid regex"));
static SCREEN_TAG: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"\s*\[screen:\d+\]").expect("valid regex"));
static NEXT_LEAD: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^Next\s+[—–-]\s+").expect("valid regex"));
static ACTIVITY_HOUR: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"\*\*([0-2][0-9]):[0-5][0-9]").expect("valid regex"));
static DECISION_LABEL: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)^\*{0,2}(?:Decision|Decisions)\*{0,2}:\*{0,2}\s*").expect("valid regex")
});
static BLOCKER_LABEL: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)^\*{0,2}(?:Blocker|Blockers)\*{0,2}:\*{0,2}\s*").expect("valid regex")
});

struct Section {
    title: String,
    body: String,
}

fn sections(markdown: &str, prefix: &str) -> Vec<Section> {
    let deeper = format!("{prefix}#");
    let mut result = Vec::new();
    let mut title: Option<String> = None;
    let mut lines: Vec<&str> = Vec::new();
    let finish = |title: &Option<String>, lines: &[&str], result: &mut Vec<Section>| {
        if let Some(title) = title {
            result.push(Section {
                title: title.clone(),
                body: lines.join("\n").trim().to_string(),
            });
        }
    };
    for line in markdown.split('\n') {
        if line.starts_with(prefix) && !line.starts_with(&deeper) {
            finish(&title, &lines, &mut result);
            title = Some(line[prefix.len()..].trim().to_string());
            lines.clear();
        } else if title.is_some() {
            lines.push(line);
        }
    }
    finish(&title, &lines, &mut result);
    result
}

fn normalized(value: &str) -> String {
    value.replace(['‑', '–', '—'], "-").trim().to_lowercase()
}

fn body<'a>(names: &[&str], sections: &'a [Section]) -> Option<&'a str> {
    sections
        .iter()
        .find(|s| names.contains(&normalized(&s.title).as_str()))
        .map(|s| s.body.as_str())
}

fn preamble(markdown: &str, prefix: &str) -> Option<String> {
    let lines: Vec<&str> = markdown
        .split('\n')
        .take_while(|l| !l.starts_with(prefix))
        .collect();
    meaningful(Some(&lines.join("\n")))
}

/// `None` for empty sections and sentinels like "_None._".
fn meaningful(value: Option<&str>) -> Option<String> {
    let clean = value?.trim();
    if clean.is_empty() {
        return None;
    }
    let sentinel = clean
        .replace(['_', '*'], "")
        .trim_matches(|c: char| c.is_whitespace() || c == '.')
        .to_lowercase();
    const EMPTY: &[&str] = &[
        "none",
        "none recorded",
        "none found in the evidence",
        "no activity was recorded",
        "no tracked app time",
        "no meetings",
    ];
    if EMPTY.contains(&sentinel.as_str()) {
        None
    } else {
        Some(clean.to_string())
    }
}

fn join_nonempty(values: &[Option<&str>]) -> String {
    values
        .iter()
        .filter_map(|v| meaningful(*v))
        .collect::<Vec<_>>()
        .join("\n\n")
}

/// Top-level `- `/`* ` items, each with its continuation lines.
fn top_level_items(markdown: &str) -> Vec<String> {
    let mut items = Vec::new();
    let mut current: Vec<&str> = Vec::new();
    for line in markdown.split('\n') {
        let is_top = line.chars().next().is_some_and(|c| !c.is_whitespace())
            && (line.starts_with("- ") || line.starts_with("* "));
        if is_top && !current.is_empty() {
            items.push(current.join("\n"));
            current.clear();
        }
        if is_top || !current.is_empty() {
            current.push(line);
        }
    }
    if !current.is_empty() {
        items.push(current.join("\n"));
    }
    items
}

fn strip_list_marker(line: &str) -> &str {
    line.strip_prefix("- ")
        .or_else(|| line.strip_prefix("* "))
        .unwrap_or(line)
}

/// "The user did X" → "Did X", keeping the journal's facts in the user's voice.
fn direct_voice(value: &str) -> String {
    let clean = value.trim();
    let first_name = crate::people::user_full_name(None)
        .and_then(|n| n.split_whitespace().next().map(|f| format!("{f} ")));
    let mut prefixes: Vec<String> = ["The user ", "the user ", "User ", "user "]
        .iter()
        .map(|p| p.to_string())
        .collect();
    prefixes.extend(first_name);
    for prefix in &prefixes {
        if let Some(rest) = clean.strip_prefix(prefix.as_str()) {
            let mut chars = rest.chars();
            return match chars.next() {
                Some(first) => first.to_uppercase().collect::<String>() + chars.as_str(),
                None => String::new(),
            };
        }
    }
    clean.to_string()
}

const IGNORED_WORDS: &[&str] = &[
    "a", "an", "and", "are", "as", "at", "be", "been", "being", "by", "for", "from", "in", "is",
    "of", "on", "or", "that", "the", "this", "to", "was", "were", "with",
];

fn meaningful_words(value: &str) -> Vec<String> {
    crate::ids::fold(value)
        .split(|c: char| !c.is_alphanumeric())
        .filter(|w| !w.is_empty() && !IGNORED_WORDS.contains(w))
        .map(str::to_string)
        .collect()
}

/// `DayDigestTextSimilarity.isSimilar`.
pub fn is_similar(lhs: &str, rhs: &str) -> bool {
    let left_words = meaningful_words(lhs);
    let right_words = meaningful_words(rhs);
    if left_words.is_empty() || right_words.is_empty() {
        return false;
    }
    let left_text = left_words.join(" ");
    let right_text = right_words.join(" ");
    if left_text == right_text {
        return true;
    }
    let (shorter, longer) = if left_text.chars().count() <= right_text.chars().count() {
        (&left_text, &right_text)
    } else {
        (&right_text, &left_text)
    };
    if shorter.chars().count() >= 16 && longer.contains(shorter.as_str()) {
        return true;
    }
    let left: std::collections::HashSet<&String> = left_words.iter().collect();
    let right: std::collections::HashSet<&String> = right_words.iter().collect();
    if left == right && left.len() >= 2 {
        return true;
    }
    let shared = left.intersection(&right).count();
    let smaller = left.len().min(right.len());
    shared >= 4 && smaller > 0 && shared as f64 / smaller as f64 >= 0.8
}

fn focus_block(markdown: &str) -> DigestTask {
    let raw = strip_list_marker(markdown).trim();
    let mut sources: Vec<i64> = Vec::new();
    for caps in SCREEN_ID.captures_iter(raw) {
        if let Ok(id) = caps[1].parse::<i64>()
            && !sources.contains(&id)
        {
            sources.push(id);
        }
    }
    let visible = SCREEN_TAG.replace_all(raw, "").trim().to_string();
    let untitled = |visible: &str, sources: Vec<i64>| DigestTask {
        title: direct_voice(visible),
        has_heading: false,
        status: TaskStatus::Unknown,
        summary: String::new(),
        next_step: None,
        time_range: None,
        screen_sources: sources,
    };
    let Some(after) = visible.strip_prefix("**") else {
        return untitled(&visible, sources);
    };
    let Some(end) = after.find("**") else {
        return untitled(&visible, sources);
    };
    let heading = &after[..end];
    let remainder = after[end + 2..].trim();
    let remainder = remainder
        .strip_prefix('—')
        .map(str::trim)
        .unwrap_or(remainder);
    let (status, summary) = status_lead(remainder);
    let (time_range, title) = match heading.split_once(" · ") {
        Some((range, title)) => (Some(range.to_string()), direct_voice(title)),
        None => (None, direct_voice(heading)),
    };
    DigestTask {
        title,
        has_heading: true,
        status,
        summary: direct_voice(summary),
        next_step: None,
        time_range,
        screen_sources: sources,
    }
}

fn status_lead(summary: &str) -> (TaskStatus, &str) {
    for (lead, status) in [
        ("Completed.", TaskStatus::Completed),
        ("In progress.", TaskStatus::InProgress),
        ("Blocked.", TaskStatus::Blocked),
    ] {
        if let Some(rest) = summary.strip_prefix(lead) {
            return (status, rest.trim());
        }
    }
    (TaskStatus::Unknown, summary)
}

fn focus_blocks(markdown: &str) -> Vec<DigestTask> {
    let clean = markdown.trim();
    if clean.is_empty() {
        return Vec::new();
    }
    let items = top_level_items(clean);
    if items.is_empty() {
        vec![focus_block(clean)]
    } else {
        items.iter().map(|i| focus_block(i)).collect()
    }
}

fn comparison_text(task: &DigestTask) -> String {
    if task.has_heading {
        format!("{} {}", task.title, task.summary)
    } else {
        task.title.clone()
    }
}

fn removing_similar_content(value: &str, existing: &[String]) -> Option<String> {
    let clean = meaningful(Some(value))?;
    let items = top_level_items(&clean);
    if items.is_empty() {
        return (!existing.iter().any(|e| is_similar(&clean, e))).then_some(clean);
    }
    let mut comparisons: Vec<String> = existing.iter().filter(|e| !e.is_empty()).cloned().collect();
    let mut accepted = Vec::new();
    for item in items {
        let comparison = strip_list_marker(&item).to_string();
        if comparisons.iter().any(|c| is_similar(&comparison, c)) {
            continue;
        }
        accepted.push(item);
        comparisons.push(comparison);
    }
    meaningful(Some(&accepted.join("\n")))
}

fn removing_label(label: &Regex, text: &str) -> Option<String> {
    let found = label.find(text)?;
    let rest = text[found.end()..].trim();
    (!rest.is_empty()).then(|| rest.to_string())
}

/// `Next — <task>: <step>`; the longest matching task title wins.
fn next_step(text: &str, tasks: &[DigestTask]) -> Option<(Option<usize>, String, String)> {
    let lead = NEXT_LEAD.find(text)?;
    let rest = &text[lead.end()..];
    let candidates = [rest.to_string(), direct_voice(rest)];
    let mut best: Option<(usize, String)> = None;
    for (index, task) in tasks.iter().enumerate() {
        if !task.has_heading || task.title.is_empty() {
            continue;
        }
        let prefix = format!("{}:", task.title).to_lowercase();
        let Some(candidate) = candidates
            .iter()
            .find(|c| c.to_lowercase().starts_with(&prefix))
        else {
            continue;
        };
        let step = candidate
            .chars()
            .skip(prefix.chars().count())
            .collect::<String>()
            .trim()
            .to_string();
        if step.is_empty() {
            continue;
        }
        if best
            .as_ref()
            .is_none_or(|(b, _)| tasks[*b].title.chars().count() < task.title.chars().count())
        {
            best = Some((index, step));
        }
    }
    if let Some((index, step)) = best {
        return Some((Some(index), tasks[index].title.clone(), step));
    }
    let (title, step) = rest.split_once(": ")?;
    let (title, step) = (title.trim(), step.trim());
    (!title.is_empty() && !step.is_empty()).then(|| (None, title.to_string(), step.to_string()))
}

struct FollowUps {
    tasks: Vec<DigestTask>,
    decisions: Vec<String>,
    blockers: Vec<String>,
    other: Vec<DigestTask>,
}

fn follow_ups(markdown: Option<&str>, tasks: Vec<DigestTask>, existing: &[String]) -> FollowUps {
    let mut result = FollowUps {
        tasks,
        decisions: Vec::new(),
        blockers: Vec::new(),
        other: Vec::new(),
    };
    let Some(clean) = meaningful(markdown) else {
        return result;
    };
    let mut comparisons: Vec<String> = existing.iter().filter(|e| !e.is_empty()).cloned().collect();
    let is_new = |text: &str, comparisons: &mut Vec<String>| {
        if comparisons.iter().any(|c| is_similar(text, c)) {
            return false;
        }
        comparisons.push(text.to_string());
        true
    };
    let items = top_level_items(&clean);
    let items = if items.is_empty() {
        vec![clean.clone()]
    } else {
        items
    };
    for item in items {
        let text = strip_list_marker(&item).trim().to_string();
        if let Some(decision) = removing_label(&DECISION_LABEL, &text) {
            if is_new(&decision, &mut comparisons) {
                result.decisions.push(direct_voice(&decision));
            }
        } else if let Some(blocker) = removing_label(&BLOCKER_LABEL, &text) {
            if is_new(&blocker, &mut comparisons) {
                result.blockers.push(direct_voice(&blocker));
            }
        } else if let Some((index, title, step)) = next_step(&text, &result.tasks) {
            match index {
                None => {
                    if is_new(&step, &mut comparisons) {
                        let mut block = focus_block(&format!("**{title}**"));
                        block.next_step = Some(direct_voice(&step));
                        result.other.push(block);
                    }
                }
                Some(index) => {
                    if result.tasks[index].next_step.is_none()
                        && !is_similar(&step, &comparison_text(&result.tasks[index]))
                    {
                        result.tasks[index].next_step = Some(direct_voice(&step));
                    }
                }
            }
        } else if is_new(&text, &mut comparisons) {
            result.other.push(focus_block(&text));
        }
    }
    result
}

fn time_allocations(markdown: &str) -> Vec<DigestTimeAllocation> {
    let mut rows = Vec::new();
    for line in markdown.split('\n') {
        let clean = line.trim();
        if !(clean.starts_with('|') && clean.ends_with('|') && clean.len() >= 2) {
            continue;
        }
        let columns: Vec<String> = clean[1..clean.len() - 1]
            .split('|')
            .map(|c| c.trim().to_string())
            .collect();
        if columns.len() < 2 {
            continue;
        }
        let (first, second) = (&columns[0], &columns[1]);
        if normalized(first) == "app" || first.replace('-', "").is_empty() {
            continue;
        }
        rows.push(DigestTimeAllocation {
            app: unescape_table(first),
            detail: unescape_table(second),
            seconds: duration_seconds(second),
        });
    }
    rows
}

fn duration_seconds(value: &str) -> f64 {
    if value.trim() == "<1m" {
        return 30.0;
    }
    let mut seconds = 0.0;
    for token in value.to_lowercase().split_whitespace() {
        if let Some(hours) = token.strip_suffix('h').and_then(|h| h.parse::<f64>().ok()) {
            seconds += hours * 3600.0;
        } else if let Some(minutes) = token.strip_suffix('m').and_then(|m| m.parse::<f64>().ok()) {
            seconds += minutes * 60.0;
        }
    }
    seconds
}

fn unescape_table(value: &str) -> String {
    value
        .replace("\\|", "|")
        .replace("\\*", "*")
        .replace("\\_", "_")
        .replace("\\[", "[")
        .replace("\\]", "]")
        .replace("\\\\", "\\")
}

fn activity_groups(markdown: &str) -> Vec<DigestActivityGroup> {
    let mut groups: Vec<DigestActivityGroup> = Vec::new();
    for item in top_level_items(markdown) {
        let mut lines = item.split('\n');
        let Some(first) = lines.next() else { continue };
        let headline = strip_list_marker(first).to_string();
        let evidence: Vec<String> = lines
            .filter_map(|l| {
                let clean = l.trim();
                (!clean.is_empty()).then(|| strip_list_marker(clean).to_string())
            })
            .collect();
        let hour = ACTIVITY_HOUR
            .captures(first)
            .map(|c| c[1].to_string())
            .unwrap_or_else(|| "Other".into());
        let entry = DigestActivityEntry { headline, evidence };
        match groups.iter_mut().find(|g| g.hour == hour) {
            Some(group) => group.entries.push(entry),
            None => groups.push(DigestActivityGroup {
                hour,
                entries: vec![entry],
            }),
        }
    }
    groups
}

/// Parses a journal (`DayDigestPresentation(markdown:)`), accepting legacy
/// layouts such as `## Today at a glance` + `## Next`.
pub fn parse_digest(markdown: &str) -> DayDigest {
    let document = sections(markdown, "## ");
    let summary_body = document
        .iter()
        .find(|s| normalized(&s.title) == "day summary")
        .map(|s| s.body.as_str())
        .unwrap_or("");
    let summary_parts = sections(summary_body, "### ");
    let summary_preamble = preamble(summary_body, "### ");

    let legacy_work = body(
        &["what i worked on", "work completed and in progress"],
        &document,
    );
    let standalone_overview = body(&["today at a glance", "at a glance", "overview"], &document);
    let standalone_focus = body(&["next", "tasks", "focus blocks"], &document);

    let overview = body(&["at a glance", "overview"], &summary_parts).or(standalone_overview);
    let focus = body(
        &["tasks", "focus blocks", "work completed and in progress"],
        &summary_parts,
    )
    .or(legacy_work)
    .or(standalone_focus);
    let other_activity = body(&["other activity", "brief activity"], &summary_parts);
    let decisions = body(
        &[
            "decisions and next steps",
            "decisions, follow-ups, and blockers",
        ],
        &summary_parts,
    );

    const KNOWN: &[&str] = &[
        "at a glance",
        "overview",
        "tasks",
        "focus blocks",
        "work completed and in progress",
        "other activity",
        "brief activity",
        "decisions and next steps",
        "decisions, follow-ups, and blockers",
    ];
    let unknown_summary: Vec<String> = summary_parts
        .iter()
        .filter(|s| !KNOWN.contains(&normalized(&s.title).as_str()))
        .map(|s| format!("### {}\n\n{}", s.title, s.body))
        .collect();

    let parsed_focus = focus_blocks(focus.unwrap_or(""));
    let parsed_other = focus_blocks(other_activity.unwrap_or(""));
    let task_comparisons: Vec<String> = parsed_focus.iter().map(comparison_text).collect();
    let mut overview_parts: Vec<Option<&str>> = vec![overview, summary_preamble.as_deref()];
    overview_parts.extend(unknown_summary.iter().map(|s| Some(s.as_str())));
    let overview_markdown = join_nonempty(&overview_parts);
    let unique_overview =
        removing_similar_content(&overview_markdown, &task_comparisons).unwrap_or_default();
    let overview_items = top_level_items(&unique_overview);
    let at_a_glance = if overview_items.is_empty() {
        unique_overview.clone()
    } else {
        overview_items
            .iter()
            .take(3)
            .cloned()
            .collect::<Vec<_>>()
            .join("\n")
    };
    let highlights: Vec<String> = if overview_items.is_empty() {
        at_a_glance
            .split("\n\n")
            .map(str::trim)
            .filter(|p| !p.is_empty())
            .map(str::to_string)
            .collect()
    } else {
        overview_items
            .iter()
            .take(3)
            .map(|i| strip_list_marker(i).trim().to_string())
            .collect()
    };

    let mut exclusions = task_comparisons.clone();
    exclusions.push(at_a_glance.clone());
    let follow = follow_ups(decisions, parsed_focus, &exclusions);
    let follow_up_text: Vec<String> = follow
        .other
        .iter()
        .map(|t| match &t.next_step {
            Some(step) => format!("{}: {step}", t.title),
            None if t.summary.is_empty() => t.title.clone(),
            None => format!("{} — {}", t.title, t.summary),
        })
        .collect();

    let meetings = body(&["meetings"], &document);
    let agent_sessions = body(&["agent sessions"], &document);
    let time_body = body(&["time allocation"], &document).unwrap_or("");
    let activity_body =
        body(&["full activity log", "chronological work log"], &document).unwrap_or("");

    DayDigest {
        day: None,
        markdown: markdown.to_string(),
        at_a_glance_markdown: at_a_glance,
        highlights,
        tasks: follow.tasks,
        other_activity: parsed_other,
        decisions: follow.decisions,
        blockers: follow.blockers,
        follow_ups: follow_up_text,
        follow_up_tasks: follow.other,
        meetings_markdown: meaningful(meetings),
        agent_sessions_markdown: meaningful(agent_sessions),
        time_allocations: time_allocations(time_body),
        activity_groups: activity_groups(activity_body),
        meta: None,
        modified_at: None,
        latest_evidence_at: None,
        is_stale: false,
    }
}

/// Timeline's task sections in order: open work first, finished work last.
pub const TASK_GROUP_ORDER: [TaskStatus; 4] = [
    TaskStatus::Blocked,
    TaskStatus::InProgress,
    TaskStatus::Unknown,
    TaskStatus::Completed,
];

/// One-line rows a section shows before "Show N more".
pub const BRIEF_ROW_LIMIT: usize = 8;

/// A status section of the task list: its tasks' indices in
/// `DayDigest::tasks`, in journal order.
#[derive(Clone, Debug, PartialEq)]
pub struct TaskGroup {
    pub status: TaskStatus,
    pub tasks: Vec<usize>,
}

/// How Timeline shows a section's tasks (`DayDigestPresentation.timelineRows`).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct TimelineRows {
    /// Shown in full, with the title, next step and summary.
    pub full: Vec<usize>,
    /// Shown as one-line rows whose summary opens on demand.
    pub brief: Vec<usize>,
}

impl DayDigest {
    /// Task-first journals give their tasks a status; older journals never do.
    pub fn is_task_first(&self) -> bool {
        self.tasks.iter().any(|t| t.status != TaskStatus::Unknown)
    }

    /// The non-empty status sections, in `TASK_GROUP_ORDER`.
    pub fn task_groups(&self) -> Vec<TaskGroup> {
        TASK_GROUP_ORDER
            .iter()
            .map(|status| TaskGroup {
                status: *status,
                tasks: (0..self.tasks.len())
                    .filter(|ix| self.tasks[*ix].status == *status)
                    .collect(),
            })
            .filter(|group| !group.tasks.is_empty())
            .collect()
    }

    /// Timeline shows a section's tasks that carry a next step, and every
    /// blocked task, in full; the rest become one-line rows, as does all of
    /// Done. Older journals have neither statuses nor next steps, and their
    /// summary is the only description, so all of their tasks stay in full.
    pub fn timeline_rows(&self, group: &TaskGroup) -> TimelineRows {
        if !self.is_task_first() || group.status == TaskStatus::Blocked {
            return TimelineRows {
                full: group.tasks.clone(),
                brief: Vec::new(),
            };
        }
        if group.status == TaskStatus::Completed {
            return TimelineRows {
                full: Vec::new(),
                brief: group.tasks.clone(),
            };
        }
        let (full, brief) = group
            .tasks
            .iter()
            .partition(|ix| self.tasks[**ix].next_step.is_some());
        TimelineRows { full, brief }
    }
}

/// Whether `count` one-line rows show only the first `BRIEF_ROW_LIMIT` until
/// asked for the rest. Hiding a single row would cost as much room as
/// showing it.
pub fn folds_brief_rows(count: usize) -> bool {
    count > BRIEF_ROW_LIMIT + 1
}

/// Splits a trailing parenthetical off a task title, such as the project in
/// "Review all open PRs (LokalBot)" or the pull request in "Staging
/// deployment (PR #487)", so it can show as a tag
/// (`DayDigestPresentation.titleAndTag`). Nested parentheses stay inside the
/// tag; a title that is only a parenthetical, or one over 32 characters, has
/// no tag.
pub fn title_and_tag(title: &str) -> (&str, Option<&str>) {
    let trimmed = title.trim();
    if !trimmed.ends_with(')') {
        return (trimmed, None);
    }
    let mut depth = 0;
    let mut open = None;
    for (index, ch) in trimmed.char_indices().rev() {
        if ch == ')' {
            depth += 1;
        }
        if ch == '(' {
            depth -= 1;
            if depth == 0 {
                open = Some(index);
                break;
            }
        }
    }
    let Some(open) = open else {
        return (trimmed, None);
    };
    let tag = trimmed[open + 1..trimmed.len() - 1].trim();
    let head = trimmed[..open].trim();
    if head.is_empty() || tag.is_empty() || tag.chars().count() > 32 {
        return (trimmed, None);
    }
    (head, Some(tag))
}

const MEETING_ARTIFACTS: &[&str] = &[
    "transcript.json",
    "summary.md",
    "notes.md",
    "outcomes.json",
    "outcome-state.json",
];

fn modified(path: &std::path::Path) -> Option<DateTime<Utc>> {
    std::fs::metadata(path)
        .ok()?
        .modified()
        .ok()
        .map(DateTime::<Utc>::from)
}

impl Library {
    /// The journal for `day` parsed for display, with its sidecar and whether
    /// newer activity, screen text or finished meetings exist than the
    /// journal file covers (`DayDigestFreshness`).
    pub fn day_digest(&self, day: NaiveDate) -> Result<Option<DayDigest>> {
        let Some(markdown) = self.journal_markdown(day)? else {
            return Ok(None);
        };
        let mut digest = parse_digest(&markdown);
        digest.day = Some(day);
        digest.meta = self.digest_meta(day).unwrap_or_else(|err| {
            log::warn!("unreadable digest sidecar for {day}: {err:#}");
            None
        });
        digest.modified_at = modified(&self.journal_path(day));
        digest.latest_evidence_at = self.latest_evidence_at(day)?;
        digest.is_stale = match (digest.modified_at, digest.latest_evidence_at) {
            (Some(modified), Some(latest)) => latest > modified,
            _ => false,
        };
        Ok(Some(digest))
    }

    /// The newest evidence for `day`: activity (clamped to the day), screen
    /// text, finished meetings' ends and their artifacts' modification times.
    pub fn latest_evidence_at(&self, day: NaiveDate) -> Result<Option<DateTime<Utc>>> {
        let (start, end) = crate::time::local_day_bounds(day);
        let (start_epoch, end_epoch) = (crate::time::to_epoch(start), crate::time::to_epoch(end));
        let from_db: Option<f64> = self.with_db(|db| {
            let mut parts = Vec::new();
            if crate::timeline::table_exists(db, "activity_blocks")? {
                parts.push("SELECT MIN(end, ?2) AS value FROM activity_blocks WHERE end > ?1 AND start < ?2");
            }
            if crate::timeline::table_exists(db, "ocr_metadata")? {
                parts.push("SELECT ts AS value FROM ocr_metadata WHERE ts >= ?1 AND ts < ?2");
            }
            if parts.is_empty() {
                return Ok(None);
            }
            let sql = format!("SELECT MAX(value) FROM ({})", parts.join(" UNION ALL "));
            Ok(db.query_row(&sql, rusqlite::params![start_epoch, end_epoch], |row| row.get(0))?)
        })?;
        let mut latest = from_db.map(crate::time::from_epoch);
        for meeting in self.list_own_meetings()? {
            if crate::time::local_day(meeting.started_at) != day || meeting.ended_at.is_none() {
                continue;
            }
            let dir = self.meeting_dir(&meeting);
            let artifact = MEETING_ARTIFACTS
                .iter()
                .filter_map(|f| modified(&dir.join(f)))
                .max();
            latest = [latest, meeting.ended_at, artifact]
                .into_iter()
                .flatten()
                .max();
        }
        Ok(latest)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn legacy_glance_and_next_layout() {
        let digest = parse_digest(
            "## Today at a glance\n\nRedis stays the caching layer. The Postgres migration continues.\n\n## Next\n\n- Draft the eviction-policy document.\n- Run the failover benchmark.\n",
        );
        assert_eq!(
            digest.highlights,
            ["Redis stays the caching layer. The Postgres migration continues."]
        );
        assert_eq!(digest.tasks.len(), 2);
        assert_eq!(digest.tasks[0].title, "Draft the eviction-policy document.");
        assert!(!digest.tasks[0].has_heading);
        assert_eq!(digest.tasks[0].status, TaskStatus::Unknown);
    }

    #[test]
    fn task_first_journal_with_follow_ups() {
        let markdown = "## Day summary\n\n### At a glance\n- Shoot is booked\n- Quote requested\n- Cut delivered\n- Fourth point\n\n### Tasks\n- **Holiday shoot prep** — In progress. Booked the studio and drafted the shot list [screen:4]\n- **09:00–10:30 · Northwind cut** — Completed. Delivered the captioned cut. [screen:7] [screen:7]\n- **Laptop quote** — Blocked. Waiting for the vendor.\n\n### Decisions and next steps\n- Decision: Shoot everything on phones.\n- Blocker: The old laptops cannot export 4K in time.\n- Next — Holiday shoot prep: Send the call sheet to Maya.\n- Next — Budget sheet: Add the trade-in values.\n\n## Meetings\n\n### 09:47 — Client call\n- App: Microsoft Teams\n\n## Time allocation\n\n| App | Tracked time |\n| --- | ---: |\n| DaVinci Resolve | 2h 5m |\n| Slack | <1m |\n\n## Full activity log\n\n- **09:00–10:30** — **DaVinci Resolve** — Northwind cut\n  - [screen:7], 09:20: Timeline export\n- **13:05–13:20** — **Slack** — #studio\n";
        let digest = parse_digest(markdown);
        assert_eq!(digest.highlights.len(), 3);
        assert_eq!(digest.tasks.len(), 3);
        assert_eq!(digest.tasks[0].status, TaskStatus::InProgress);
        assert_eq!(
            digest.tasks[0].next_step.as_deref(),
            Some("Send the call sheet to Maya.")
        );
        assert_eq!(digest.tasks[0].screen_sources, [4]);
        assert_eq!(digest.tasks[1].time_range.as_deref(), Some("09:00–10:30"));
        assert_eq!(digest.tasks[1].title, "Northwind cut");
        assert_eq!(digest.tasks[1].screen_sources, [7]);
        assert_eq!(digest.tasks[2].status, TaskStatus::Blocked);
        assert_eq!(digest.decisions, ["Shoot everything on phones."]);
        assert_eq!(
            digest.blockers,
            ["The old laptops cannot export 4K in time."]
        );
        assert_eq!(
            digest.follow_ups,
            ["Budget sheet: Add the trade-in values."]
        );
        assert!(digest.meetings_markdown.unwrap().contains("Client call"));
        assert_eq!(digest.time_allocations.len(), 2);
        assert_eq!(digest.time_allocations[0].seconds, 7500.0);
        assert_eq!(digest.time_allocations[1].seconds, 30.0);
        assert_eq!(digest.activity_groups.len(), 2);
        assert_eq!(digest.activity_groups[0].hour, "09");
        assert_eq!(digest.activity_groups[0].entries[0].evidence.len(), 1);
    }

    #[test]
    fn empty_sentinels_are_dropped() {
        let digest = parse_digest(
            "## Day summary\n\n### At a glance\n_No activity was recorded._\n\n## Meetings\n\n_None._\n",
        );
        assert!(digest.highlights.is_empty());
        assert_eq!(digest.meetings_markdown, None);
    }

    /// Timeline gives full rows to open tasks with a next step and to blocked
    /// tasks; the rest of a section, and all of Done, become one-line rows.
    #[test]
    fn timeline_rows_keep_next_steps_and_blockers_in_full() {
        let digest = parse_digest(
            "## Day summary\n\n### Tasks\n\
- **Publish the release** — Completed. Pushed the release branch.\n\
- **Fix overlay positioning (PR #169)** — In progress. Pushed a fix.\n\
- **Review open PRs** — In progress. Read three diffs.\n\
- **Generate voiceover** — Blocked. Waiting for audio credits.\n\n\
### Decisions and next steps\n\
- Next — Fix overlay positioning (PR #169): Enable text metrics in Chrome.\n",
        );
        let rows = |status: TaskStatus| {
            digest
                .task_groups()
                .iter()
                .find(|g| g.status == status)
                .map(|g| digest.timeline_rows(g))
                .unwrap_or_default()
        };
        assert!(digest.is_task_first());
        assert_eq!(
            digest
                .task_groups()
                .iter()
                .map(|g| g.status)
                .collect::<Vec<_>>(),
            [
                TaskStatus::Blocked,
                TaskStatus::InProgress,
                TaskStatus::Completed
            ]
        );
        assert_eq!(rows(TaskStatus::InProgress).full, [1]);
        assert_eq!(rows(TaskStatus::InProgress).brief, [2]);
        assert_eq!(rows(TaskStatus::Blocked).full, [3]);
        assert!(rows(TaskStatus::Completed).full.is_empty());
        assert_eq!(rows(TaskStatus::Completed).brief, [0]);

        let legacy = parse_digest(
            "## Day summary\n\n### Focus blocks\n\
- **09:00–10:30 · Fixture implementation** — User updated the Timeline UI.\n",
        );
        assert!(!legacy.is_task_first());
        let rows = legacy.timeline_rows(&legacy.task_groups()[0]);
        assert_eq!(rows.full, [0], "older journals keep every summary visible");
        assert!(rows.brief.is_empty());

        assert!(!folds_brief_rows(BRIEF_ROW_LIMIT + 1));
        assert!(folds_brief_rows(BRIEF_ROW_LIMIT + 2));
    }

    #[test]
    fn title_tag_splits_only_a_trailing_parenthetical() {
        assert_eq!(
            title_and_tag("Review all open PRs (LokalBot)"),
            ("Review all open PRs", Some("LokalBot"))
        );
        assert_eq!(
            title_and_tag("alpha: Base/Monad staging deployment (PR #487)"),
            ("alpha: Base/Monad staging deployment", Some("PR #487"))
        );
        assert_eq!(
            title_and_tag("Protocol fee extraction code review (fork 2) (alpha)"),
            (
                "Protocol fee extraction code review (fork 2)",
                Some("alpha")
            )
        );
        assert_eq!(
            title_and_tag("Fix layout (overlay (caret))"),
            ("Fix layout", Some("overlay (caret)"))
        );
        assert_eq!(
            title_and_tag("Machine maintenance, Mojo PR #230"),
            ("Machine maintenance, Mojo PR #230", None)
        );
        assert_eq!(
            title_and_tag("(LokalBot)"),
            ("(LokalBot)", None),
            "a title is never only its tag"
        );
        assert_eq!(
            title_and_tag("Ship it (and then (a long aside that keeps going))"),
            ("Ship it (and then (a long aside that keeps going))", None),
            "a long parenthetical is part of the sentence, not a tag"
        );
        assert_eq!(title_and_tag("Unbalanced)"), ("Unbalanced)", None));
    }

    #[test]
    fn similarity_matches_the_swift_rules() {
        assert!(is_similar(
            "Draft the eviction policy",
            "draft eviction policy"
        ));
        assert!(is_similar(
            "Book the photo studio for Thursday",
            "Booked? No: book the photo studio for thursday morning"
        ));
        assert!(!is_similar("Book the studio", "Send the quote"));
    }
}
