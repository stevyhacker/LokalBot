//! Markdown from accepted records (`SummaryClaimEvidence.render`,
//! `MeetingSummaryOutcomeSynchronizer`, `MeetingOutcomesGenerator.merge`).

use std::cmp::Ordering;
use std::collections::{BTreeSet, HashMap, HashSet};
use std::sync::LazyLock;

use regex::Regex;

use lokalbot_core::model::{ActionItem, Decision, MeetingOutcomes, OutcomeSourceCitation};
use lokalbot_core::settings::NoteTemplate;
use lokalbot_core::time::stamp;

use super::evidence::{Claim, claim_sections, is_similar, similarity_normalized};
use super::ownership::is_bare_acceptance;
use super::view::View;

static MARKDOWN_SPECIAL: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"([\\`*_{}\[\]<>])").expect("valid regex"));

fn escaped(text: &str) -> String {
    MARKDOWN_SPECIAL
        .replace_all(&crate::sanitize::collapse(text), r"\$1")
        .into_owned()
}

/// Sections of claims as reported speech: `- **Name:** text — [HH:MM:SS]`.
pub fn render_claims(claims: &[Claim], view: &View, template: NoteTemplate) -> String {
    let mut seen = HashSet::new();
    let distinct: Vec<&Claim> = claims
        .iter()
        .filter(|c| {
            seen.insert(format!(
                "{}|{}|{}",
                c.section,
                c.segment_id,
                crate::sanitize::collapse(&c.text)
            ))
        })
        .collect();
    let headings: Vec<String> = if template == NoteTemplate::Freeform && !distinct.is_empty() {
        let mut seen = HashSet::new();
        distinct
            .iter()
            .map(|c| c.section.clone())
            .filter(|s| seen.insert(s.clone()))
            .collect()
    } else {
        claim_sections(template)
            .into_iter()
            .map(str::to_string)
            .collect()
    };
    let index_of: HashMap<&str, usize> = view
        .segment_ids
        .iter()
        .enumerate()
        .map(|(i, id)| (id.as_str(), i))
        .collect();
    headings
        .iter()
        .map(|section| {
            let lines: Vec<String> = distinct
                .iter()
                .filter(|c| &c.section == section)
                .filter_map(|claim| {
                    let row = *index_of.get(claim.segment_id.as_str())?;
                    let person = view.roster.get(&claim.speaker_id)?;
                    Some(format!(
                        "- **{}:** {} — [{}]",
                        escaped(&person.label()),
                        escaped(&claim.text),
                        stamp(view.transcript.segments[row].start)
                    ))
                })
                .collect();
            format!(
                "## {}\n\n{}",
                escaped(section),
                if lines.is_empty() {
                    "None".to_string()
                } else {
                    lines.join("\n")
                }
            )
        })
        .collect::<Vec<_>>()
        .join("\n\n")
}

// ------------------------------------------------------------ synchronizer

const DECISIONS_HEADING: &str = "## Decisions";
const ACTION_ITEMS_HEADING: &str = "## Action items";

struct Block {
    heading: Option<String>,
    lines: Vec<String>,
}

fn single_line(text: &str) -> String {
    crate::sanitize::collapse(text)
}

fn citation_suffix(citations: &[OutcomeSourceCitation]) -> String {
    citations
        .iter()
        .min_by(|a, b| a.start.partial_cmp(&b.start).unwrap_or(Ordering::Equal))
        .map(|c| format!(" — [{}]", stamp(c.start)))
        .unwrap_or_default()
}

fn list_lines(lines: Vec<String>) -> Vec<String> {
    if lines.is_empty() {
        vec!["None".into()]
    } else {
        lines
    }
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

fn render_section(heading: &str, outcomes: &MeetingOutcomes) -> Vec<String> {
    match heading {
        DECISIONS_HEADING => {
            let mut lines = vec![heading.to_string(), String::new()];
            lines.extend(list_lines(
                outcomes
                    .decision_records
                    .iter()
                    .map(|d| {
                        format!(
                            "- {}{}",
                            single_line(&d.display_text()),
                            citation_suffix(&d.citations)
                        )
                    })
                    .collect(),
            ));
            lines
        }
        ACTION_ITEMS_HEADING => {
            let mut lines = vec![heading.to_string(), String::new(), "### Me".to_string()];
            lines.extend(action_lines(outcomes.user_action_items(), false));
            lines.extend([String::new(), "### Others".to_string()]);
            lines.extend(action_lines(outcomes.other_action_items(), true));
            if outcomes.unresolved_action_items().next().is_some() {
                lines.extend([String::new(), "### Owner unclear".to_string()]);
                lines.extend(action_lines(outcomes.unresolved_action_items(), false));
            }
            lines
        }
        _ => vec![heading.to_string()],
    }
}

fn parse_blocks(markdown: &str) -> Vec<Block> {
    let normalized = markdown.replace("\r\n", "\n");
    let mut blocks = Vec::new();
    let mut current = Block {
        heading: None,
        lines: Vec::new(),
    };
    for line in normalized.split('\n') {
        let trimmed = line.trim_matches(|c: char| c == ' ' || c == '\t');
        if trimmed.starts_with("## ") && !trimmed.starts_with("### ") {
            if !current.lines.is_empty() {
                blocks.push(current);
            }
            current = Block {
                heading: Some(trimmed.to_string()),
                lines: vec![trimmed.to_string()],
            };
        } else {
            current.lines.push(line.to_string());
        }
    }
    if !current.lines.is_empty() {
        blocks.push(current);
    }
    blocks
}

/// Replaces (or appends) the outcome sections of `summary` with ones rendered
/// from `outcomes`, so the recap can never disagree with the cards.
pub fn synchronize(summary: &str, outcomes: &MeetingOutcomes, template: NoteTemplate) -> String {
    let controlled: Vec<&str> = if template == NoteTemplate::Meeting {
        vec![DECISIONS_HEADING, ACTION_ITEMS_HEADING]
    } else {
        vec![ACTION_ITEMS_HEADING]
    };
    let rendered: Vec<Block> = controlled
        .iter()
        .map(|h| Block {
            heading: Some(h.to_string()),
            lines: render_section(h, outcomes),
        })
        .collect();
    let controlled_set: HashSet<&str> = controlled.into_iter().collect();
    let mut result: Vec<Block> = Vec::new();
    let mut inserted = false;
    let mut rendered = Some(rendered);
    for block in parse_blocks(summary) {
        if block
            .heading
            .as_deref()
            .is_some_and(|h| controlled_set.contains(h))
        {
            if let Some(rendered) = rendered.take() {
                result.extend(rendered);
                inserted = true;
            }
            continue;
        }
        result.push(block);
    }
    if !inserted && let Some(rendered) = rendered.take() {
        result.extend(rendered);
    }
    let parts: Vec<String> = result
        .into_iter()
        .map(|block| {
            let mut lines = block.lines;
            while lines.last().is_some_and(|l| l.trim().is_empty()) {
                lines.pop();
            }
            lines.join("\n")
        })
        .filter(|s| !s.is_empty())
        .collect();
    format!("{}\n", parts.join("\n\n"))
}

// ------------------------------------------------------------------- merge

fn shares_evidence(lhs: &[OutcomeSourceCitation], rhs: &[OutcomeSourceCitation]) -> bool {
    let left: HashSet<&str> = lhs.iter().map(|c| c.segment_id.as_str()).collect();
    rhs.iter().any(|c| left.contains(c.segment_id.as_str()))
}

fn speaker_id(action: &ActionItem) -> Option<&str> {
    action
        .attribution
        .as_ref()
        .and_then(|a| a.speaker_id.as_deref())
}

fn compatible_owners(lhs: &ActionItem, rhs: &ActionItem) -> bool {
    if lhs.is_for_user != rhs.is_for_user
        || lhs.ownership_is_unclear() != rhs.ownership_is_unclear()
        || speaker_id(lhs) != speaker_id(rhs)
        || lhs.attribution.as_ref().map(|a| a.basis) != rhs.attribution.as_ref().map(|a| a.basis)
    {
        return false;
    }
    if lhs.is_for_user {
        return true;
    }
    let left = similarity_normalized(lhs.owner.as_deref().unwrap_or(""));
    let right = similarity_normalized(rhs.owner.as_deref().unwrap_or(""));
    left.is_empty() || right.is_empty() || left == right
}

/// The task text is just its cited speaker's own words.
fn repeats_its_source(action: &ActionItem) -> bool {
    let text = similarity_normalized(&action.text);
    text.split(' ').count() >= 4
        && action
            .citations
            .iter()
            .any(|c| similarity_normalized(&c.excerpt).contains(&text))
}

fn duplicate_action(lhs: &ActionItem, rhs: &ActionItem) -> bool {
    if !compatible_owners(lhs, rhs) {
        return false;
    }
    if similarity_normalized(&lhs.text) == similarity_normalized(&rhs.text) {
        return true;
    }
    shares_evidence(&lhs.citations, &rhs.citations)
        && (is_similar(&lhs.text, &rhs.text, 0.65)
            || repeats_its_source(lhs)
            || repeats_its_source(rhs))
}

fn decision_speaker(decision: &Decision) -> Option<&str> {
    decision.attribution.as_ref().map(|a| a.speaker_id.as_str())
}

fn duplicate_decision(lhs: &Decision, rhs: &Decision) -> bool {
    decision_speaker(lhs) == decision_speaker(rhs)
        && (similarity_normalized(&lhs.text) == similarity_normalized(&rhs.text)
            || (shares_evidence(&lhs.citations, &rhs.citations)
                && is_similar(&lhs.text, &rhs.text, 0.65)))
}

fn preferred_text<'a>(lhs: &'a str, rhs: &'a str) -> &'a str {
    if rhs.chars().count() > lhs.chars().count() {
        rhs
    } else {
        lhs
    }
}

fn merged_citations(
    lhs: &[OutcomeSourceCitation],
    rhs: &[OutcomeSourceCitation],
    anchor: Option<&str>,
) -> Vec<OutcomeSourceCitation> {
    let mut seen = HashSet::new();
    let mut out: Vec<OutcomeSourceCitation> = lhs
        .iter()
        .chain(rhs)
        .filter(|c| seen.insert(c.segment_id.clone()))
        .cloned()
        .collect();
    out.sort_by(|a, b| {
        let a_anchor = Some(a.segment_id.as_str()) == anchor;
        let b_anchor = Some(b.segment_id.as_str()) == anchor;
        if a_anchor != b_anchor {
            return if a_anchor {
                Ordering::Less
            } else {
                Ordering::Greater
            };
        }
        a.start
            .partial_cmp(&b.start)
            .unwrap_or(Ordering::Equal)
            .then_with(|| a.segment_id.cmp(&b.segment_id))
    });
    out
}

fn rebuilt_action(
    action: &ActionItem,
    citations: Vec<OutcomeSourceCitation>,
    text: &str,
    owner: Option<&str>,
    due: Option<&str>,
    is_for_user: bool,
    importance: u8,
) -> ActionItem {
    ActionItem::new(
        text,
        if is_for_user { Some("Me") } else { owner },
        due,
        Some(is_for_user),
        importance,
        citations,
        action.attribution.clone(),
    )
}

fn merged_action(lhs: &ActionItem, rhs: &ActionItem) -> ActionItem {
    let is_for_user = lhs.is_for_user || rhs.is_for_user;
    let text = if repeats_its_source(lhs) != repeats_its_source(rhs) {
        if repeats_its_source(lhs) {
            rhs.text.as_str()
        } else {
            lhs.text.as_str()
        }
    } else {
        preferred_text(&lhs.text, &rhs.text)
    };
    let anchor = lhs.citations.first().map(|c| c.segment_id.clone());
    let citations = merged_citations(&lhs.citations, &rhs.citations, anchor.as_deref());
    rebuilt_action(
        lhs,
        citations,
        text,
        lhs.owner.as_deref().or(rhs.owner.as_deref()),
        lhs.due.as_deref().or(rhs.due.as_deref()),
        is_for_user,
        lhs.importance.max(rhs.importance),
    )
}

fn rebuilt_decision(
    text: &str,
    citations: Vec<OutcomeSourceCitation>,
    from: &Decision,
) -> Decision {
    let mut decision = Decision::new(text, citations);
    decision.attribution = from.attribution.clone();
    decision
}

fn action_order(lhs: &ActionItem, rhs: &ActionItem) -> Ordering {
    if lhs.is_for_user != rhs.is_for_user {
        return if lhs.is_for_user {
            Ordering::Less
        } else {
            Ordering::Greater
        };
    }
    let left = lhs.citations.first().map_or(f64::INFINITY, |c| c.start);
    let right = rhs.citations.first().map_or(f64::INFINITY, |c| c.start);
    if left == right {
        return lhs.text.to_lowercase().cmp(&rhs.text.to_lowercase());
    }
    left.partial_cmp(&right).unwrap_or(Ordering::Equal)
}

fn decision_order(lhs: &Decision, rhs: &Decision) -> Ordering {
    let left = lhs.citations.first().map_or(f64::INFINITY, |c| c.start);
    let right = rhs.citations.first().map_or(f64::INFINITY, |c| c.start);
    if left == right {
        return lhs.text.to_lowercase().cmp(&rhs.text.to_lowercase());
    }
    left.partial_cmp(&right).unwrap_or(Ordering::Equal)
}

/// Deterministic deduplication across parts (`MeetingOutcomesGenerator.merge`).
pub fn merge_outcomes(parts: &[MeetingOutcomes]) -> MeetingOutcomes {
    let mut actions: Vec<ActionItem> = Vec::new();
    let mut decisions: Vec<Decision> = Vec::new();
    let mut questions: Vec<String> = Vec::new();
    for part in parts {
        for action in &part.action_items {
            match actions.iter().position(|a| duplicate_action(a, action)) {
                Some(index) => actions[index] = merged_action(&actions[index], action),
                None => {
                    let anchor = action.citations.first().map(|c| c.segment_id.clone());
                    let citations = merged_citations(&action.citations, &[], anchor.as_deref());
                    actions.push(rebuilt_action(
                        action,
                        citations,
                        &action.text,
                        action.owner.as_deref(),
                        action.due.as_deref(),
                        action.is_for_user,
                        action.importance,
                    ));
                }
            }
        }
        for decision in &part.decision_records {
            match decisions
                .iter()
                .position(|d| duplicate_decision(d, decision))
            {
                Some(index) => {
                    let existing = decisions[index].clone();
                    let text = preferred_text(&existing.text, &decision.text).to_string();
                    decisions[index] = rebuilt_decision(
                        &text,
                        merged_citations(&existing.citations, &decision.citations, None),
                        &existing,
                    );
                }
                None => decisions.push(rebuilt_decision(
                    &decision.text,
                    merged_citations(&decision.citations, &[], None),
                    decision,
                )),
            }
        }
        for question in part.open_questions.iter().filter(|q| !q.is_empty()) {
            if !questions.iter().any(|q| is_similar(q, question, 0.85)) {
                questions.push(question.clone());
            }
        }
    }
    decisions.retain(|decision| {
        !actions.iter().any(|action| {
            if !shares_evidence(&action.citations, &decision.citations) {
                return false;
            }
            if let Some(statement) = &decision.attribution
                && Some(statement.speaker_id.as_str()) == speaker_id(action)
                && is_bare_acceptance(&statement.quote)
            {
                return true;
            }
            is_similar(&action.text, &decision.text, 0.65)
        })
    });
    actions.sort_by(action_order);
    decisions.sort_by(decision_order);
    MeetingOutcomes {
        schema_version: lokalbot_core::model::OUTCOMES_SCHEMA_VERSION,
        transcript_revision: None,
        action_items: actions,
        decision_records: decisions,
        open_questions: questions,
    }
}

/// Every part's first takeaway, then every part's second, and so on, so
/// the first bullets span the whole meeting.
pub fn interleaving_tldr(parts: &[Vec<Claim>]) -> Vec<Claim> {
    let takeaways: Vec<Vec<&Claim>> = parts
        .iter()
        .map(|p| p.iter().filter(|c| c.section == "TL;DR").collect())
        .collect();
    let rounds = takeaways.iter().map(Vec::len).max().unwrap_or(0);
    let mut ordered: Vec<Claim> = Vec::new();
    for round in 0..rounds {
        for part in &takeaways {
            if let Some(claim) = part.get(round) {
                ordered.push((*claim).clone());
            }
        }
    }
    for part in parts {
        ordered.extend(part.iter().filter(|c| c.section != "TL;DR").cloned());
    }
    ordered
}

pub fn distinct_claims(claims: Vec<Claim>) -> Vec<Claim> {
    let mut seen = HashSet::new();
    claims
        .into_iter()
        .filter(|c| {
            seen.insert(format!(
                "{}|{}|{}",
                c.section,
                c.speaker_id,
                similarity_normalized(&c.text)
            ))
        })
        .collect()
}

/// Three source-linked facts for a TL;DR when no part wrote one.
pub fn overview_claims(claims: &[Claim], outcomes: &MeetingOutcomes) -> Vec<Claim> {
    let user_sources: BTreeSet<&str> = outcomes
        .user_action_items()
        .flat_map(|a| a.citations.iter().map(|c| c.segment_id.as_str()))
        .collect();
    let action_sources: BTreeSet<&str> = outcomes
        .action_items
        .iter()
        .flat_map(|a| a.citations.iter().map(|c| c.segment_id.as_str()))
        .collect();
    let facts: Vec<&Claim> = claims
        .iter()
        .filter(|c| c.section != "TL;DR" && c.section != "Open questions")
        .collect();
    let mut candidates: Vec<&Claim> = facts
        .iter()
        .copied()
        .filter(|c| user_sources.contains(c.segment_id.as_str()))
        .collect();
    candidates.extend(facts.iter().copied().filter(|c| c.section == "Decisions"));
    candidates.extend(
        facts
            .iter()
            .copied()
            .filter(|c| action_sources.contains(c.segment_id.as_str())),
    );
    if !facts.is_empty() {
        candidates.extend([facts[0], facts[facts.len() / 2], facts[facts.len() - 1]]);
    }
    candidates.extend(facts.iter().copied());
    let mut sources = HashSet::new();
    let mut texts = HashSet::new();
    candidates
        .into_iter()
        .filter(|c| {
            let text = similarity_normalized(&c.text);
            if sources.contains(&c.segment_id) || texts.contains(&text) {
                return false;
            }
            sources.insert(c.segment_id.clone());
            texts.insert(text);
            true
        })
        .take(3)
        .map(|c| Claim {
            section: "TL;DR".into(),
            ..c.clone()
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use lokalbot_core::model::{ActionAttribution, AttributionBasis, OwnerResolution};

    fn citation(id: &str, start: f64, excerpt: &str) -> OutcomeSourceCitation {
        OutcomeSourceCitation {
            meeting_id: None,
            segment_id: id.into(),
            start,
            end: start + 5.0,
            speaker: "me".into(),
            excerpt: excerpt.into(),
        }
    }

    fn user_action(text: &str, id: &str, start: f64) -> ActionItem {
        let attribution = ActionAttribution {
            resolution: OwnerResolution::User,
            speaker_id: Some("me".into()),
            basis: AttributionBasis::Commitment,
            quote: None,
            rejection_reason: None,
        };
        ActionItem::new(
            text,
            Some("Me"),
            None,
            Some(true),
            3,
            vec![citation(id, start, "I'll do it")],
            Some(attribution),
        )
    }

    #[test]
    fn synchronizer_rewrites_decisions_and_action_items() {
        let mut outcomes = MeetingOutcomes::default();
        outcomes.action_items.push(user_action(
            "Send the security overview",
            "segment-0001",
            15.0,
        ));
        let unclear = ActionItem::new(
            "Prepare a 250-seat quote",
            None,
            Some("Friday"),
            None,
            3,
            vec![citation("segment-0002", 30.0, "x")],
            None,
        );
        outcomes.action_items.push(unclear);
        outcomes.decision_records.push(Decision::new(
            "Ship SSO in Q3.",
            vec![citation("segment-0001", 15.0, "x")],
        ));
        let summary = "## TL;DR\n\n- **You:** SSO ships in Q3. — [00:00:15]\n\n## Key points\n\nNone\n\n## Decisions\n\nNone\n\n## Open questions\n\nNone";
        let synced = synchronize(summary, &outcomes, NoteTemplate::Meeting);
        assert_eq!(
            synced,
            "## TL;DR\n\n- **You:** SSO ships in Q3. — [00:00:15]\n\n## Key points\n\nNone\n\n## Decisions\n\n- Ship SSO in Q3. — [00:00:15]\n\n## Action items\n\n### Me\n- [ ] Send the security overview — [00:00:15]\n\n### Others\nNone\n\n### Owner unclear\n- [ ] Prepare a 250-seat quote — due Friday — [00:00:30]\n\n## Open questions\n\nNone\n"
        );
        // Other templates only append Action items.
        let lecture = synchronize("## TL;DR\n\nNone", &outcomes, NoteTemplate::Lecture);
        assert!(lecture.starts_with("## TL;DR\n\nNone\n\n## Action items\n\n### Me\n"));
    }

    #[test]
    fn merge_deduplicates_across_parts() {
        let a = MeetingOutcomes {
            action_items: vec![user_action(
                "Send the security overview",
                "segment-0001",
                15.0,
            )],
            ..Default::default()
        };
        let b = MeetingOutcomes {
            action_items: vec![user_action(
                "Send the security overview to Northwind",
                "segment-0001",
                15.0,
            )],
            decision_records: vec![Decision::new(
                "Send the security overview",
                vec![citation("segment-0001", 15.0, "x")],
            )],
            open_questions: vec!["Them: When does SSO ship?".into(), "".into()],
            ..Default::default()
        };
        let merged = merge_outcomes(&[a, b]);
        assert_eq!(merged.action_items.len(), 1);
        assert_eq!(
            merged.action_items[0].text,
            "Send the security overview to Northwind"
        );
        assert!(
            merged.decision_records.is_empty(),
            "a decision duplicating an action is dropped"
        );
        assert_eq!(merged.open_questions, ["Them: When does SSO ship?"]);
    }

    #[test]
    fn tldr_interleaves_parts() {
        let claim = |section: &str, text: &str| Claim {
            section: section.into(),
            text: text.into(),
            speaker_id: "me".into(),
            segment_id: text.into(),
            quote: String::new(),
        };
        let parts = vec![
            vec![
                claim("TL;DR", "a1"),
                claim("TL;DR", "a2"),
                claim("Key points", "ka"),
            ],
            vec![claim("TL;DR", "b1"), claim("Key points", "kb")],
        ];
        let ordered: Vec<String> = interleaving_tldr(&parts)
            .into_iter()
            .map(|c| c.text)
            .collect();
        assert_eq!(ordered, ["a1", "b1", "a2", "ka", "kb"]);
    }
}
