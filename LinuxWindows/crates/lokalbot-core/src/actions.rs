//! Action items across meetings: the user's corrections layered over the
//! extracted outcomes (`MeetingOutcomeProjection.swift`), threads of the same
//! commitment (`ActionThreads.swift`), Today's attention order and the
//! correction workflow (`OutcomeIndex.swift`).

use std::collections::{HashMap, HashSet};

use anyhow::{Result, bail};
use chrono::{DateTime, Days, Local, NaiveDate, Utc};
use uuid::Uuid;

use crate::library::Library;
use crate::model::*;

/// Clustering never joins mentions more than 30 days apart.
pub const THREAD_MAXIMUM_SPAN_DAYS: i64 = 30;
/// "Due soon" in the attention order.
pub const DUE_SOON_WINDOW_DAYS: u64 = 7;

/// A user correction of one extracted action.
///
/// `None` leaves a field as it is. `text: Some("")` reverts to the extracted
/// text. `owner`/`due`: `Some(None)` (or a blank string) clears the value
/// explicitly ("no owner", "no due date"), `Some(Some(value))` overrides it.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ActionCorrection {
    pub text: Option<String>,
    pub owner: Option<Option<String>>,
    pub due: Option<Option<String>>,
}

/// One meeting's outcomes with the user's saved state.
#[derive(Clone, Debug, PartialEq)]
pub struct OutcomeProjection {
    pub meeting: Meeting,
    /// Prioritized (`prioritizingActionItems`).
    pub outcomes: MeetingOutcomes,
    pub state: OutcomeState,
}

impl OutcomeProjection {
    /// Every action with corrections applied, in display order.
    pub fn action_references(&self) -> Vec<ActionReference> {
        self.outcomes
            .action_items
            .iter()
            .map(|action| reference(&self.meeting, action, self.state.actions.get(&action.id)))
            .collect()
    }

    /// Outcomes with every action's corrections applied.
    pub fn corrected_outcomes(&self) -> MeetingOutcomes {
        let mut result = self.outcomes.clone();
        result.action_items = self
            .action_references()
            .iter()
            .map(ActionReference::effective_action)
            .collect();
        result
    }
}

fn reference(
    meeting: &Meeting,
    action: &ActionItem,
    saved: Option<&ActionState>,
) -> ActionReference {
    let untouched = ActionState::untouched();
    let state = saved.unwrap_or(&untouched);
    let owner = if state.owner_was_cleared {
        None
    } else {
        state
            .owner_override
            .clone()
            .or_else(|| action.owner.clone())
    };
    let due = if state.due_was_cleared {
        None
    } else {
        state.due_override.clone().or_else(|| action.due.clone())
    };
    let owner_was_corrected = state.owner_override.is_some() || state.owner_was_cleared;
    let due_was_corrected = state.due_override.is_some() || state.due_was_cleared;
    let is_for_user = if owner_was_corrected {
        owner
            .as_deref()
            .is_some_and(|o| o.trim().eq_ignore_ascii_case("me"))
    } else {
        action.is_for_user && !action.ownership_is_unclear()
    };
    let state_updated_at = if state.user_edited {
        state.updated_at
    } else {
        meeting.started_at
    };
    let original_text = action.display_text();
    let mut reference = ActionReference {
        id: format!("{}:{}", crate::ids::uuid_upper(&meeting.id), action.id),
        meeting_id: meeting.id,
        meeting_title: meeting.display_title(),
        meeting_started_at: meeting.started_at,
        action_id: action.id.clone(),
        text: state
            .text_correction
            .clone()
            .unwrap_or_else(|| original_text.clone()),
        original_text,
        owner,
        due,
        resolved_due_date: None,
        is_for_user,
        status: state.status,
        importance: action.importance,
        citations: action.citations.clone(),
        action: action.clone(),
        state_updated_at,
        text_was_corrected: state.text_correction.is_some(),
        owner_was_corrected,
        due_was_corrected,
        text_corrected_at: state.text_corrected_at,
        owner_corrected_at: state.owner_corrected_at,
        due_corrected_at: state.due_corrected_at,
        is_thread_excluded: state.is_thread_excluded,
    };
    reference.resolved_due_date =
        crate::due::resolve_at(reference.due.as_deref(), reference.due_reference_date());
    reference
}

// ------------------------------------------------------------------ threads

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
struct SourceKey {
    text: String,
    owner: String,
    is_for_user: bool,
}

struct Group {
    references: Vec<ActionReference>,
    meeting_ids: HashSet<Uuid>,
    latest: DateTime<Utc>,
}

fn newest_first(a: &ActionReference, b: &ActionReference) -> std::cmp::Ordering {
    b.meeting_started_at
        .cmp(&a.meeting_started_at)
        .then_with(|| a.id.cmp(&b.id))
}

/// Joins equal canonical commitments across meetings (`ActionThreadClusterer`).
/// Unclusterable references (excluded, generic, ownerless) become threads of one.
pub fn cluster_threads(references: Vec<ActionReference>) -> Vec<ActionThread> {
    let mut sorted = references;
    sorted.sort_by(newest_first);
    let mut groups: Vec<Group> = Vec::new();
    let mut candidates: HashMap<SourceKey, Vec<usize>> = HashMap::new();
    let span = chrono::Duration::days(THREAD_MAXIMUM_SPAN_DAYS);

    for reference in sorted {
        let key = source_key(&reference);
        let mut matching = key
            .as_ref()
            .and_then(|k| candidates.get(k).cloned())
            .unwrap_or_default();
        // Newest first, so an expired group never becomes a candidate again.
        matching.retain(|&index| groups[index].latest - reference.meeting_started_at <= span);
        match matching
            .iter()
            .copied()
            .find(|&index| !groups[index].meeting_ids.contains(&reference.meeting_id))
        {
            Some(index) => {
                groups[index].meeting_ids.insert(reference.meeting_id);
                groups[index].references.push(reference);
            }
            None => {
                matching.push(groups.len());
                groups.push(Group {
                    latest: reference.meeting_started_at,
                    meeting_ids: HashSet::from([reference.meeting_id]),
                    references: vec![reference],
                });
            }
        }
        if let Some(key) = key {
            candidates.insert(key, matching);
        }
    }

    let mut threads: Vec<ActionThread> = groups
        .into_iter()
        .map(|g| make_thread(g.references))
        .collect();
    threads.sort_by(|a, b| {
        b.latest()
            .meeting_started_at
            .cmp(&a.latest().meeting_started_at)
            .then_with(|| a.id.cmp(&b.id))
    });
    threads
}

/// The first element with the greatest key (Swift's `max(by:)`).
fn first_max_by_key<T, K: Ord>(
    items: impl IntoIterator<Item = T>,
    key: impl Fn(&T) -> K,
) -> Option<T> {
    let mut best: Option<(K, T)> = None;
    for item in items {
        let k = key(&item);
        if best.as_ref().is_none_or(|(best_key, _)| k > *best_key) {
            best = Some((k, item));
        }
    }
    best.map(|(_, item)| item)
}

fn make_thread(mut references: Vec<ActionReference>) -> ActionThread {
    references.sort_by(newest_first);
    let corrected_text =
        first_max_by_key(references.iter().filter(|r| r.text_was_corrected), |r| {
            r.text_corrected_at.unwrap_or(r.state_updated_at)
        });
    let descriptive = first_max_by_key(references.iter(), |r| {
        (r.text.chars().count(), r.meeting_started_at)
    });
    let text = corrected_text
        .or(descriptive)
        .map(|r| r.text.clone())
        .unwrap_or_default();
    let corrected_owner =
        first_max_by_key(references.iter().filter(|r| r.owner_was_corrected), |r| {
            r.owner_corrected_at.unwrap_or(r.state_updated_at)
        });
    let owner = match corrected_owner {
        Some(reference) => reference.owner.clone(),
        None => references.iter().find_map(|r| r.owner.clone()),
    };
    let corrected_due = first_max_by_key(references.iter().filter(|r| r.due_was_corrected), |r| {
        r.due_corrected_at.unwrap_or(r.state_updated_at)
    });
    let due_reference = corrected_due.or_else(|| references.iter().find(|r| r.due.is_some()));
    let mut ids: Vec<&str> = references.iter().map(|r| r.id.as_str()).collect();
    ids.sort_unstable();
    let canonical_text = canonical_source_text(&references[0].action.display_text());
    ActionThread {
        id: format!("thread-{}", crate::ids::fnv_hex(&ids.join("|"))),
        canonical_text,
        text,
        owner,
        due: due_reference.and_then(|r| r.due.clone()),
        due_source_meeting_date: due_reference.map(|r| r.meeting_started_at),
        due_reference_date: due_reference.map(ActionReference::due_reference_date),
        resolved_due_date: due_reference.and_then(|r| r.resolved_due_date),
        references,
    }
}

fn source_key(reference: &ActionReference) -> Option<SourceKey> {
    if reference.is_thread_excluded {
        return None;
    }
    let text = canonical_source_text(&reference.action.display_text());
    // Short generic commitments recur naturally and are unsafe to merge.
    if significant_tokens(&text).len() < 3 {
        return None;
    }
    if reference.action.is_for_user {
        return Some(SourceKey {
            text,
            owner: String::new(),
            is_for_user: true,
        });
    }
    let owner = reference.action.owner.as_deref().map(normalized_words)?;
    if owner.is_empty() {
        return None;
    }
    Some(SourceKey {
        text,
        owner,
        is_for_user: false,
    })
}

/// Folded text without harmless leading phrases ("I will", "please").
pub fn canonical_source_text(text: &str) -> String {
    let folded = crate::ids::fold(&text.replace('’', "'"));
    let trimmed = folded.trim_matches(|c: char| c.is_whitespace() || matches!(c, '.' | '!' | '?'));
    let mut words: Vec<&str> = trimmed.split_whitespace().collect();
    for prefix in [&["i", "will"][..], &["i'll"], &["we", "will"], &["please"]] {
        if words.starts_with(prefix) {
            words.drain(..prefix.len());
            break;
        }
    }
    words.join(" ")
}

/// Folded alphanumeric words joined by spaces (`OutcomeTextSimilarity.normalized`).
pub fn normalized_words(text: &str) -> String {
    crate::ids::fold(text)
        .split(|c: char| !c.is_alphanumeric())
        .filter(|w| !w.is_empty())
        .collect::<Vec<_>>()
        .join(" ")
}

const LEADING_NOISE: &[&str] = &[
    "a", "an", "i", "ill", "me", "my", "need", "please", "the", "to", "we", "will",
];

fn significant_tokens(text: &str) -> HashSet<String> {
    normalized_words(text)
        .split(' ')
        .filter(|t| !t.is_empty() && !LEADING_NOISE.contains(t))
        .map(str::to_string)
        .collect()
}

/// Overdue work first, then work due within a week (each by due day), then
/// the rest in their existing order (`ActionAttentionOrder`).
pub fn attention_sorted(mut threads: Vec<ActionThread>, today: NaiveDate) -> Vec<ActionThread> {
    let soon = today
        .checked_add_days(Days::new(DUE_SOON_WINDOW_DAYS))
        .unwrap_or(today);
    let bucket = |thread: &ActionThread| match thread.resolved_due_date {
        None => 2,
        Some(due) if due < today => 0,
        Some(due) if due <= soon => 1,
        Some(_) => 2,
    };
    threads.sort_by_key(|thread| {
        let b = bucket(thread);
        (
            b,
            if b < 2 {
                thread.resolved_due_date
            } else {
                None
            },
        )
    });
    threads
}

fn today() -> NaiveDate {
    Local::now().date_naive()
}

// ------------------------------------------------------------------ library

impl Library {
    /// Outcomes plus saved state for one meeting, or `None` without outcomes.
    pub fn outcome_projection(&self, meeting: &Meeting) -> Result<Option<OutcomeProjection>> {
        let Some(outcomes) = self.outcomes(meeting)? else {
            return Ok(None);
        };
        let state = self.outcome_state(meeting).unwrap_or_else(|err| {
            log::warn!(
                "unreadable outcome state for {}: {err:#}",
                meeting.short_id()
            );
            OutcomeState::default()
        });
        Ok(Some(OutcomeProjection {
            meeting: meeting.clone(),
            outcomes,
            state,
        }))
    }

    /// One meeting's actions with corrections applied, in display order.
    pub fn meeting_actions(&self, meeting: &Meeting) -> Result<Vec<ActionReference>> {
        Ok(self
            .outcome_projection(meeting)?
            .map(|p| p.action_references())
            .unwrap_or_default())
    }

    /// Every action from meetings started in the last `days` days (all when
    /// `None`). The sample meeting's actions stay on its own page.
    pub fn action_references(&self, days: Option<u32>) -> Result<Vec<ActionReference>> {
        let cutoff = days.map(|d| Utc::now() - chrono::Duration::days(i64::from(d.max(1))));
        let mut out = Vec::new();
        for meeting in self.list_own_meetings()? {
            if cutoff.is_some_and(|cutoff| meeting.started_at < cutoff) {
                continue;
            }
            match self.meeting_actions(&meeting) {
                Ok(references) => out.extend(references),
                Err(err) => log::warn!("skipping outcomes of {}: {err:#}", meeting.short_id()),
            }
        }
        Ok(out)
    }

    /// Action threads over meetings from the last `days` days, newest first.
    pub fn action_threads(&self, days: Option<u32>) -> Result<Vec<ActionThread>> {
        Ok(cluster_threads(self.action_references(days)?))
    }

    /// The user's open threads. `None`: Today's list in attention order
    /// (overdue, due within 7 days, the rest). `Some(day)`: threads mentioned
    /// in a meeting on that local day, newest first (Timeline's day view).
    pub fn needs_attention(
        &self,
        day: Option<NaiveDate>,
        limit: usize,
    ) -> Result<Vec<ActionThread>> {
        let open: Vec<ActionThread> = self
            .action_threads(None)?
            .into_iter()
            .filter(|t| t.is_for_user() && t.status() == ActionStatus::Open)
            .collect();
        let mut threads = match day {
            None => attention_sorted(open, today()),
            Some(day) => open
                .into_iter()
                .filter(|t| {
                    t.references
                        .iter()
                        .any(|r| crate::time::local_day(r.meeting_started_at) == day)
                })
                .collect(),
        };
        threads.truncate(limit);
        Ok(threads)
    }

    /// Saves a correction to `outcome-state.json` and refreshes the action
    /// list in `summary.md` (`OutcomeIndex.correctAction`).
    ///
    /// Unlike macOS, a summary without `summary-claims.json` is not archived
    /// for regeneration after an owner or text change; its action list is
    /// rewritten like any other.
    pub fn correct_action(
        &self,
        meeting: &Meeting,
        action_id: &str,
        correction: ActionCorrection,
    ) -> Result<()> {
        self.mutate_action(meeting, action_id, |state, now| {
            if let Some(text) = correction.text {
                let text = non_blank(Some(text));
                if state.text_correction != text {
                    state.text_correction = text;
                    state.text_corrected_at = state.text_correction.as_ref().map(|_| now);
                }
            }
            if let Some(owner) = correction.owner {
                let value = non_blank(owner);
                let cleared = value.is_none();
                if state.owner_override != value || state.owner_was_cleared != cleared {
                    state.owner_override = value;
                    state.owner_was_cleared = cleared;
                    state.owner_corrected_at = Some(now);
                }
            }
            if let Some(due) = correction.due {
                let value = non_blank(due);
                let cleared = value.is_none();
                if state.due_override != value || state.due_was_cleared != cleared {
                    state.due_override = value;
                    state.due_was_cleared = cleared;
                    state.due_corrected_at = Some(now);
                }
            }
        })
    }

    /// Keeps an action out of (or back in) cross-meeting threads.
    pub fn set_thread_excluded(
        &self,
        meeting: &Meeting,
        action_id: &str,
        excluded: bool,
    ) -> Result<()> {
        self.mutate_action(meeting, action_id, |state, _| {
            state.is_thread_excluded = excluded
        })
    }

    /// Sets every member of a thread to `status` (`OutcomeIndex.setStatus(_:thread:)`).
    pub fn set_thread_status(&self, thread: &ActionThread, status: ActionStatus) -> Result<()> {
        let meetings = self.list_all_meetings()?;
        for reference in thread.references.iter().filter(|r| r.status != status) {
            let Some(meeting) = meetings.iter().find(|m| m.id == reference.meeting_id) else {
                bail!("The action thread changed. Review its sources and try again.");
            };
            self.set_action_status(meeting, &reference.action_id, status)?;
        }
        Ok(())
    }

    fn mutate_action(
        &self,
        meeting: &Meeting,
        action_id: &str,
        change: impl FnOnce(&mut ActionState, DateTime<Utc>),
    ) -> Result<()> {
        if self.is_read_only() {
            bail!("the library is open read-only");
        }
        let Some(mut projection) = self.outcome_projection(meeting)? else {
            bail!(
                "This action is no longer available. Reopen the meeting's actions and try again."
            );
        };
        if !projection
            .outcomes
            .action_items
            .iter()
            .any(|a| a.id == action_id)
        {
            bail!(
                "This action is no longer available. Reopen the meeting's actions and try again."
            );
        }
        let now = millis(Utc::now());
        let previous = projection
            .state
            .actions
            .get(action_id)
            .cloned()
            .unwrap_or_else(ActionState::untouched);
        let mut state = previous.clone();
        change(&mut state, now);
        state.user_edited = true;
        state.updated_at = now;
        let changed_content = previous.owner_override != state.owner_override
            || previous.owner_was_cleared != state.owner_was_cleared
            || previous.text_correction != state.text_correction
            || previous.due_override != state.due_override
            || previous.due_was_cleared != state.due_was_cleared;
        projection
            .state
            .actions
            .insert(action_id.to_string(), state);
        self.save_outcome_state(meeting, &projection.state)?;
        if changed_content && let Some(summary) = self.summary(meeting)? {
            let updated = replace_action_items(&summary, &projection.corrected_outcomes());
            if updated != summary {
                self.save_summary(meeting, &updated)?;
            }
        }
        Ok(())
    }
}

fn non_blank(value: Option<String>) -> Option<String> {
    value
        .map(|v| v.trim().to_string())
        .filter(|v| !v.is_empty())
}

// ------------------------------------------------------- summary.md section

/// `summary.md` with its `## Action items` section rendered from `outcomes`
/// (`MeetingSummaryOutcomeSynchronizer`): `### Me`, `### Others` and, when
/// needed, `### Owner unclear`.
pub fn replace_action_items(summary: &str, outcomes: &MeetingOutcomes) -> String {
    replace_sections(summary, &[("## Action items", action_section(outcomes))])
}

/// Replaces `## Decisions` (meeting template) and `## Action items`.
pub fn synchronize_summary(
    summary: &str,
    outcomes: &MeetingOutcomes,
    meeting_template: bool,
) -> String {
    let mut sections = Vec::new();
    if meeting_template {
        let decisions: Vec<String> = outcomes
            .decision_records
            .iter()
            .map(|d| {
                format!(
                    "- {}{}",
                    single_line(&d.display_text()),
                    citation_suffix(&d.citations)
                )
            })
            .collect();
        let mut lines = vec!["## Decisions".to_string(), String::new()];
        lines.extend(list_lines(decisions));
        sections.push(("## Decisions", lines));
    }
    sections.push(("## Action items", action_section(outcomes)));
    replace_sections(summary, &sections)
}

fn action_section(outcomes: &MeetingOutcomes) -> Vec<String> {
    let mut lines = vec![
        "## Action items".to_string(),
        String::new(),
        "### Me".to_string(),
    ];
    lines.extend(action_lines(outcomes.user_action_items(), false));
    lines.extend([String::new(), "### Others".to_string()]);
    lines.extend(action_lines(outcomes.other_action_items(), true));
    let unresolved: Vec<&ActionItem> = outcomes.unresolved_action_items().collect();
    if !unresolved.is_empty() {
        lines.extend([String::new(), "### Owner unclear".to_string()]);
        lines.extend(action_lines(unresolved.into_iter(), false));
    }
    lines
}

fn action_lines<'a>(
    actions: impl Iterator<Item = &'a ActionItem>,
    include_owner: bool,
) -> Vec<String> {
    list_lines(
        actions
            .map(|action| {
                let owner = if include_owner {
                    format!(
                        "{}: ",
                        single_line(action.owner.as_deref().unwrap_or("Owner not stated"))
                    )
                } else {
                    String::new()
                };
                let due = action
                    .due
                    .as_deref()
                    .map(|d| format!(" — due {}", single_line(d)))
                    .unwrap_or_default();
                format!(
                    "- [ ] {owner}{}{due}{}",
                    single_line(&action.display_text()),
                    citation_suffix(&action.citations)
                )
            })
            .collect(),
    )
}

fn list_lines(lines: Vec<String>) -> Vec<String> {
    if lines.is_empty() {
        vec!["None".into()]
    } else {
        lines
    }
}

fn citation_suffix(citations: &[OutcomeSourceCitation]) -> String {
    citations
        .iter()
        .min_by(|a, b| {
            a.start
                .partial_cmp(&b.start)
                .unwrap_or(std::cmp::Ordering::Equal)
        })
        .map(|c| format!(" — [{}]", crate::time::stamp(c.start)))
        .unwrap_or_default()
}

fn single_line(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// Puts the rendered sections where the first controlled section was,
/// dropping the summary's own copies; missing sections are appended.
fn replace_sections(summary: &str, rendered: &[(&str, Vec<String>)]) -> String {
    let normalized = summary.replace("\r\n", "\n");
    let mut blocks: Vec<(Option<String>, Vec<String>)> = Vec::new();
    let mut current: (Option<String>, Vec<String>) = (None, Vec::new());
    for line in normalized.split('\n') {
        let trimmed = line.trim();
        if trimmed.starts_with("## ") && !trimmed.starts_with("### ") {
            if !current.1.is_empty() {
                blocks.push(std::mem::take(&mut current));
            }
            current = (Some(trimmed.to_string()), vec![trimmed.to_string()]);
        } else {
            current.1.push(line.to_string());
        }
    }
    if !current.1.is_empty() {
        blocks.push(current);
    }
    let controlled: HashSet<&str> = rendered.iter().map(|(h, _)| *h).collect();
    let mut result: Vec<Vec<String>> = Vec::new();
    let mut inserted = false;
    for (heading, lines) in blocks {
        if heading.as_deref().is_some_and(|h| controlled.contains(h)) {
            if !inserted {
                result.extend(rendered.iter().map(|(_, lines)| lines.clone()));
                inserted = true;
            }
            continue;
        }
        result.push(lines);
    }
    if !inserted {
        result.extend(rendered.iter().map(|(_, lines)| lines.clone()));
    }
    let parts: Vec<String> = result
        .into_iter()
        .map(|mut lines| {
            while lines.last().is_some_and(|l| l.trim().is_empty()) {
                lines.pop();
            }
            lines.join("\n")
        })
        .filter(|block| !block.is_empty())
        .collect();
    parts.join("\n\n") + "\n"
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone as _;

    fn meeting(id: u128, started: DateTime<Utc>) -> Meeting {
        serde_json::from_value(serde_json::json!({
            "id": Uuid::from_u128(id).to_string(),
            "title": format!("Sync {id}"),
            "appName": "Zoom",
            "startedAt": started.to_rfc3339_opts(chrono::SecondsFormat::Secs, true),
            "relativePath": format!("meetings/x/{id}"),
        }))
        .unwrap()
    }

    fn reference_for(
        meeting: &Meeting,
        text: &str,
        owner: Option<&str>,
        due: Option<&str>,
    ) -> ActionReference {
        let action = ActionItem::new(text, owner, due, None, 3, Vec::new(), None);
        reference(meeting, &action, None)
    }

    fn tuesday() -> DateTime<Utc> {
        Utc.with_ymd_and_hms(2026, 9, 22, 8, 30, 0).unwrap()
    }

    #[test]
    fn equal_commitments_thread_across_meetings_but_not_within_one() {
        let first = meeting(1, tuesday() - chrono::Duration::days(3));
        let second = meeting(2, tuesday());
        let threads = cluster_threads(vec![
            reference_for(
                &first,
                "I will draft the eviction policy doc",
                Some("Me"),
                Some("Friday"),
            ),
            reference_for(&second, "Draft the eviction policy doc.", Some("Me"), None),
            reference_for(&second, "Draft the eviction policy doc", Some("Me"), None),
            reference_for(&second, "Send it", Some("Me"), None),
        ]);
        assert_eq!(threads.len(), 3, "{threads:#?}");
        let joined = threads.iter().find(|t| t.mention_count() == 2).unwrap();
        assert_eq!(joined.meeting_count(), 2);
        assert_eq!(joined.latest().meeting_id, second.id);
        assert_eq!(joined.due.as_deref(), Some("Friday"));
        assert!(joined.id.starts_with("thread-"));
        assert_eq!(joined.text, "I will draft the eviction policy doc");
    }

    #[test]
    fn mentions_more_than_thirty_days_apart_stay_separate() {
        let old = meeting(1, tuesday() - chrono::Duration::days(40));
        let new = meeting(2, tuesday());
        let threads = cluster_threads(vec![
            reference_for(&old, "Book the photo studio for Thursday", Some("Me"), None),
            reference_for(&new, "Book the photo studio for Thursday", Some("Me"), None),
        ]);
        assert_eq!(threads.len(), 2);
    }

    #[test]
    fn other_owners_thread_only_with_the_same_owner() {
        let a = meeting(1, tuesday() - chrono::Duration::days(1));
        let b = meeting(2, tuesday());
        let threads = cluster_threads(vec![
            reference_for(
                &a,
                "Check trade-in values for laptops",
                Some("Maya Chen"),
                None,
            ),
            reference_for(
                &b,
                "Check trade-in values for laptops",
                Some("maya  chen"),
                None,
            ),
            reference_for(&b, "Check trade-in values for laptops", Some("John"), None),
        ]);
        assert_eq!(threads.len(), 2);
        assert!(threads.iter().any(|t| t.mention_count() == 2));
    }

    #[test]
    fn attention_order_puts_overdue_then_due_soon_first() {
        let m = meeting(1, tuesday());
        let last_week = meeting(2, tuesday() - chrono::Duration::days(7));
        let threads = cluster_threads(vec![
            reference_for(&m, "Undated synthetic follow-up task", Some("Me"), None),
            reference_for(
                &m,
                "Due soon synthetic review work",
                Some("Me"),
                Some("Friday"),
            ),
            reference_for(
                &last_week,
                "Overdue synthetic budget draft",
                Some("Me"),
                Some("Thursday"),
            ),
            reference_for(
                &m,
                "Far future synthetic planning memo",
                Some("Me"),
                Some("next month"),
            ),
        ]);
        let ordered = attention_sorted(threads, NaiveDate::from_ymd_opt(2026, 9, 22).unwrap());
        let texts: Vec<&str> = ordered.iter().map(|t| t.text.as_str()).collect();
        assert_eq!(
            &texts[..2],
            [
                "Overdue synthetic budget draft",
                "Due soon synthetic review work"
            ]
        );
        assert_eq!(ordered.len(), 4);
    }

    #[test]
    fn corrections_apply_and_owner_correction_decides_for_user() {
        let m = meeting(1, tuesday());
        let action = ActionItem::new(
            "Send the deck",
            Some("Ana"),
            Some("Friday"),
            None,
            3,
            Vec::new(),
            None,
        );
        let mut state = ActionState::untouched();
        state.owner_override = Some("me".into());
        state.due_was_cleared = true;
        state.text_correction = Some("Send the final deck".into());
        state.user_edited = true;
        let r = reference(&m, &action, Some(&state));
        assert!(r.is_for_user);
        assert_eq!(r.due, None);
        assert_eq!(r.text, "Send the final deck");
        assert_eq!(r.original_text, "Send the deck");
        let effective = r.effective_action();
        assert_eq!(
            effective.attribution.unwrap().resolution,
            OwnerResolution::User
        );
    }

    #[test]
    fn canonical_text_drops_harmless_leads() {
        assert_eq!(
            canonical_source_text("I’ll send the deck!"),
            "send the deck"
        );
        assert_eq!(
            canonical_source_text("Please   Review the Čaj doc."),
            "review the caj doc"
        );
        assert_eq!(canonical_source_text("We will not ship"), "not ship");
    }

    #[test]
    fn summary_action_list_is_replaced_in_place() {
        let summary = "# Title\n\n## TL;DR\n- Recap\n\n## Action items\n- [ ] Old — Me\n\n## Open questions\n- Why?\n";
        let outcomes = MeetingOutcomes {
            action_items: vec![
                ActionItem::new(
                    "Book the studio",
                    Some("Me"),
                    Some("Thursday"),
                    None,
                    3,
                    Vec::new(),
                    None,
                ),
                ActionItem::new(
                    "Send the shot list",
                    Some("Maya"),
                    None,
                    None,
                    3,
                    Vec::new(),
                    None,
                ),
            ],
            ..Default::default()
        };
        let updated = replace_action_items(summary, &outcomes);
        assert_eq!(
            updated,
            "# Title\n\n## TL;DR\n- Recap\n\n## Action items\n\n### Me\n- [ ] Book the studio — due Thursday\n\n### Others\n- [ ] Maya: Send the shot list\n\n## Open questions\n- Why?\n"
        );
    }
}
