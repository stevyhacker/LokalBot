//! Compact evidence and its validation (`MeetingNotesEvidence.swift`).
//!
//! Model IDs (`s#`, `p#`) are local to one transcript snapshot; accepted
//! records carry the stable `segment-…` IDs.

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::sync::LazyLock;

use regex::Regex;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};
use uuid::Uuid;

use lokalbot_core::model::{
    ActionItem, Decision, DecisionAttribution, MeetingOutcomes, OutcomeSourceCitation,
    OwnerResolution, SpeakerIdentity,
};
use lokalbot_core::settings::NoteTemplate;

use super::ownership::{self, Claim as OwnershipClaim, Ownership};
use super::view::{View, identity_label};
use crate::json;

pub const OWNERSHIP_POLICY_VERSION: &str = "action-evidence-v4";

/// One evidence row: `s#|p#|text`.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Unit {
    pub source: String,
    pub speaker: String,
    pub text: String,
    #[serde(default)]
    pub is_user_commitment: bool,
}

impl Unit {
    pub fn line(&self) -> String {
        format!("{}|{}|{}", self.source, self.speaker, self.text)
    }
}

/// A record the model returned that did not pass a check, queued for repair.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Rejection {
    pub sources: Vec<String>,
    pub kind: String,
    pub reason: String,
    #[serde(default)]
    pub text: Option<String>,
    /// An unresolved action that a successful ownership repair replaces.
    #[serde(default)]
    pub action_id: Option<String>,
}

/// An accepted record, listed on continuation pages so the model does not repeat it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Record {
    pub kind: String,
    pub source: String,
    pub text: String,
}

impl Record {
    pub fn key(&self) -> String {
        format!(
            "{}|{}|{}",
            self.kind,
            self.source,
            similarity_normalized(&self.text)
        )
    }
}

/// A narrative fact, reported speech of one speaker (`SummaryClaimEvidence.Claim`).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Claim {
    pub section: String,
    pub text: String,
    #[serde(rename = "speaker_id")]
    pub speaker_id: String,
    #[serde(rename = "source_segment_id")]
    pub segment_id: String,
    pub quote: String,
}

#[derive(Clone, Debug, Default)]
pub struct Validated {
    pub claims: Vec<Claim>,
    pub outcomes: MeetingOutcomes,
    pub rejected: Vec<Rejection>,
    pub complete: bool,
    pub has_more: Option<bool>,
    pub records: Vec<Record>,
}

/// `OutcomeTextSimilarity.normalized`: case- and diacritic-folded alphanumeric words.
pub fn similarity_normalized(text: &str) -> String {
    lokalbot_core::ids::fold(text)
        .split(|c: char| !c.is_alphanumeric())
        .filter(|w| !w.is_empty())
        .collect::<Vec<_>>()
        .join(" ")
}

pub fn similarity_tokens(text: &str) -> BTreeSet<String> {
    similarity_normalized(text)
        .split(' ')
        .filter(|w| !w.is_empty())
        .map(str::to_string)
        .collect()
}

/// Jaccard similarity of the token sets ≥ `threshold`.
pub fn is_similar(lhs: &str, rhs: &str, threshold: f64) -> bool {
    let left = similarity_tokens(lhs);
    let right = similarity_tokens(rhs);
    let union = left.union(&right).count();
    union > 0 && left.intersection(&right).count() as f64 / union as f64 >= threshold
}

/// Rendered sections per template (`SummaryClaimEvidence.sections(for:)`).
pub fn claim_sections(template: NoteTemplate) -> Vec<&'static str> {
    match template {
        NoteTemplate::Meeting => vec!["TL;DR", "Key points", "Decisions", "Open questions"],
        NoteTemplate::Lecture => vec![
            "TL;DR",
            "Concepts",
            "Definitions",
            "Examples",
            "Questions to review",
        ],
        NoteTemplate::StudyGuide => {
            vec!["TL;DR", "Key concepts", "Flashcards", "Practice questions"]
        }
        NoteTemplate::Podcast => vec!["TL;DR", "Topics", "Quotes", "Insights"],
        NoteTemplate::Freeform => vec!["TL;DR", "Key points"],
    }
}

/// Sections the model may use: the template's plus Decisions and Open questions.
pub fn sections(template: NoteTemplate) -> Vec<&'static str> {
    let mut sections = claim_sections(template);
    for name in ["Decisions", "Open questions"] {
        if !sections.contains(&name) {
            sections.push(name);
        }
    }
    sections
}

/// The evidence of one transcript snapshot.
pub struct Evidence<'a> {
    pub view: View<'a>,
    pub units: Vec<Unit>,
    /// `p#` → canonical speaker key.
    pub speakers: BTreeMap<String, String>,
    pub roster_json: String,
    pub is_english: bool,
    pub meeting_id: Uuid,
}

impl<'a> Evidence<'a> {
    pub fn new(view: View<'a>, meeting_id: Uuid, is_english: bool) -> Self {
        let speakers: BTreeMap<String, String> = view
            .roster
            .keys()
            .enumerate()
            .map(|(i, key)| (format!("p{}", i + 1), key.clone()))
            .collect();
        let compact: HashMap<&str, &str> = speakers
            .iter()
            .map(|(p, key)| (key.as_str(), p.as_str()))
            .collect();
        let roster_values: Vec<Value> = speakers
            .iter()
            .map(|(p, key)| {
                let person = &view.roster[key];
                json!({"id": p, "identity": identity_label(person.identity), "name": person.name, "speaker_id": person.id})
            })
            .collect();
        let roster_json = serde_json::to_string(&json::sort_keys(Value::Array(roster_values)))
            .unwrap_or_else(|_| "[]".into());
        let mut units: Vec<Unit> = view
            .prompt_turns(1_000)
            .into_iter()
            // Suspected echo repeats a remote participant, whose own row carries the words.
            .filter(|(index, _)| {
                view.attributions[*index].method
                    != lokalbot_core::model::AttributionMethod::SuspectedEcho
            })
            .map(|(index, text)| Unit {
                source: View::citation_id(index),
                speaker: compact
                    .get(view.keys[index].as_str())
                    .copied()
                    .unwrap_or("p0")
                    .to_string(),
                text,
                is_user_commitment: false,
            })
            .collect();
        let mut evidence = Self {
            view,
            units: Vec::new(),
            speakers,
            roster_json,
            is_english,
            meeting_id,
        };
        // The user's own undertakings are listed for the model.
        let texts = evidence.joined_texts(&units);
        let ownership = evidence.ownership(&texts);
        let mut flagged = BTreeSet::new();
        for unit in &mut units {
            if !flagged.insert(unit.source.clone()) {
                continue;
            }
            let Some(row) = evidence.view.index_of(&unit.source) else {
                continue;
            };
            let is_user = evidence
                .view
                .roster
                .get(&evidence.view.keys[row])
                .is_some_and(|s| s.identity == SpeakerIdentity::User);
            if !is_user {
                continue;
            }
            unit.is_user_commitment = ownership.states_commitment(row)
                || texts
                    .get(&unit.source)
                    .is_some_and(|t| ownership::is_bare_acceptance(t));
        }
        drop(ownership);
        evidence.units = units;
        evidence
    }

    /// Each source's visible text (its pieces joined).
    fn joined_texts(&self, units: &[Unit]) -> HashMap<String, String> {
        let mut texts: HashMap<String, String> = HashMap::new();
        for unit in units {
            texts
                .entry(unit.source.clone())
                .and_modify(|t| {
                    t.push(' ');
                    t.push_str(&unit.text);
                })
                .or_insert_with(|| unit.text.clone());
        }
        texts
    }

    fn ownership<'s>(&'s self, texts: &HashMap<String, String>) -> Ownership<'s, 'a> {
        let by_row: HashMap<usize, String> = texts
            .iter()
            .filter_map(|(source, text)| self.view.index_of(source).map(|row| (row, text.clone())))
            .collect();
        Ownership {
            view: &self.view,
            is_english: self.is_english,
            text: Box::new(move |row| by_row.get(&row).cloned()),
        }
    }

    /// The user prompt for some units (`MeetingNotesGenerator.prompt`).
    pub fn prompt(&self, units: &[Unit]) -> String {
        let commitments: BTreeSet<&str> = units
            .iter()
            .filter(|u| u.is_user_commitment)
            .map(|u| u.source.as_str())
            .collect();
        let mut commitments: Vec<&str> = commitments.into_iter().collect();
        commitments.sort_by_key(|s| s.trim_start_matches('s').parse::<usize>().unwrap_or(0));
        let priority = if commitments.is_empty() {
            String::new()
        } else {
            format!(
                "\nExplicit user commitments: {}. Include these actions; use nearby context to resolve what the user accepted.\n",
                commitments.join(", ")
            )
        };
        let rows: Vec<String> = units.iter().map(Unit::line).collect();
        format!(
            "Speaker roster: {}{priority}\nEvidence rows are source|speaker|spoken text:\n{}",
            self.roster_json,
            rows.join("\n")
        )
    }

    pub fn speaker_ids(&self) -> Vec<String> {
        self.speakers.keys().cloned().collect()
    }

    /// The structured-output schema for some units.
    pub fn schema(
        &self,
        units: &[Unit],
        template: NoteTemplate,
        maximum_notes: usize,
        maximum_actions: usize,
        action_texts: Option<&[String]>,
    ) -> Value {
        schema(
            units,
            &self.speaker_ids(),
            template,
            maximum_notes,
            maximum_actions,
            action_texts,
        )
    }

    /// `MeetingNotesEvidence.validate`.
    pub fn validate(
        &self,
        output: &str,
        units: &[Unit],
        template: NoteTemplate,
        maximum_notes: usize,
        maximum_actions: usize,
    ) -> Validated {
        let parsed = json::complete_records(output, &["notes", "actions"]);
        let mut result = Validated {
            complete: parsed.complete && parsed.malformed_records == 0,
            ..Default::default()
        };
        let object = json::parse_object(output);
        result.has_more = object
            .as_ref()
            .and_then(|o| o.get("has_more"))
            .and_then(Value::as_bool);
        if result.has_more != Some(false) {
            result.complete = false;
        }
        let empty = Vec::new();
        let notes = parsed.arrays.get("notes").unwrap_or(&empty);
        let actions = parsed.arrays.get("actions").unwrap_or(&empty);
        if notes.len() > maximum_notes || actions.len() > maximum_actions {
            result.complete = false;
        }
        let mut visible: HashMap<String, Vec<&Unit>> = HashMap::new();
        for unit in units {
            visible.entry(unit.source.clone()).or_default().push(unit);
        }
        let visible_text = |id: &str| -> Option<String> {
            visible.get(id).map(|parts| {
                parts
                    .iter()
                    .map(|u| u.text.as_str())
                    .collect::<Vec<_>>()
                    .join(" ")
            })
        };
        let texts: HashMap<String, String> = visible
            .keys()
            .filter_map(|k| visible_text(k).map(|t| (k.clone(), t)))
            .collect();
        let ownership = self.ownership(&texts);
        let view = &self.view;
        let citation = |row: usize, visible: &str| OutcomeSourceCitation {
            meeting_id: Some(self.meeting_id),
            segment_id: view.segment_ids[row].clone(),
            start: view.transcript.segments[row].start,
            end: view.transcript.segments[row].end,
            speaker: view.transcript.segments[row].speaker.clone(),
            excerpt: crate::sanitize::prefix(visible, 600),
        };
        let reject =
            |result: &mut Validated, item: &Map<String, Value>, reason: &str, kind: &str| {
                let sources = item
                    .get("source")
                    .and_then(Value::as_str)
                    .map(|s| vec![s.to_string()])
                    .unwrap_or_default();
                let text = (kind == "actions")
                    .then(|| {
                        item.get("text")
                            .and_then(Value::as_str)
                            .map(|t| crate::sanitize::prefix(t, 280))
                    })
                    .flatten();
                result.rejected.push(Rejection {
                    sources,
                    kind: kind.into(),
                    reason: reason.into(),
                    text,
                    action_id: None,
                });
            };

        for item in notes.iter().take(maximum_notes) {
            let Some(source) = item
                .get("source")
                .and_then(Value::as_str)
                .filter(|s| visible.contains_key(*s))
            else {
                reject(&mut result, item, "unknown_source", "notes");
                continue;
            };
            let Some(row) = view.index_of(source) else {
                reject(&mut result, item, "unknown_source", "notes");
                continue;
            };
            let visible_source = visible_text(source).unwrap_or_default();
            let expected = visible
                .get(source)
                .and_then(|parts| parts.first())
                .map(|u| u.speaker.as_str());
            let text = item
                .get("text")
                .and_then(Value::as_str)
                .filter(|t| !t.trim().is_empty() && t.chars().count() <= 280)
                .and_then(|t| self.prose(t, expected));
            let section = item.get("section").and_then(Value::as_str);
            let (Some(text), Some(section)) =
                (text, section.filter(|s| valid_section(s, template)))
            else {
                reject(&mut result, item, "invalid_note", "notes");
                continue;
            };
            if EMPTY_OUTCOME.is_match(&text) {
                reject(&mut result, item, "empty_outcome", "notes");
                continue;
            }
            let Some(person) = view.roster.get(&view.keys[row]) else {
                reject(&mut result, item, "unknown_speaker", "notes");
                continue;
            };
            let quote = crate::sanitize::prefix(&visible_source, 600);
            result.records.push(Record {
                kind: "notes".into(),
                source: source.to_string(),
                text: text.clone(),
            });
            if template == NoteTemplate::Freeform || claim_sections(template).contains(&section) {
                result.claims.push(Claim {
                    section: section.to_string(),
                    text: text.clone(),
                    speaker_id: person.id.clone(),
                    segment_id: view.segment_ids[row].clone(),
                    quote: quote.clone(),
                });
            }
            let label = person.label();
            if section == "Decisions" {
                let mut decision = Decision::new(&text, vec![citation(row, &visible_source)]);
                decision.attribution = Some(DecisionAttribution {
                    speaker_id: person.id.clone(),
                    speaker_label: label,
                    identity: person.identity,
                    quote,
                });
                result.outcomes.decision_records.push(decision);
            } else if section == "Open questions" {
                result
                    .outcomes
                    .open_questions
                    .push(format!("{label}: {text}"));
            }
        }

        for item in actions.iter().take(maximum_actions) {
            let primary = item.get("source").and_then(Value::as_str);
            let context = item
                .get("context")
                .and_then(Value::as_array)
                .filter(|c| c.len() <= 2);
            let (Some(primary), Some(context)) = (primary, context) else {
                reject(&mut result, item, "invalid_action", "actions");
                continue;
            };
            let Some(context): Option<Vec<String>> = context
                .iter()
                .map(|v| v.as_str().map(str::to_string))
                .collect()
            else {
                reject(&mut result, item, "invalid_action", "actions");
                continue;
            };
            let mut seen = BTreeSet::new();
            let mut ids: Vec<String> = std::iter::once(primary.to_string())
                .chain(context.iter().cloned())
                .filter(|id| seen.insert(id.clone()))
                .collect();
            if !ids
                .iter()
                .all(|id| visible.contains_key(id) && view.index_of(id).is_some())
            {
                reject(&mut result, item, "unknown_source", "actions");
                continue;
            }
            let row = |id: &str| view.index_of(id).unwrap_or(0);
            let primary_index = row(primary);
            if !context
                .iter()
                .all(|id| row(id).abs_diff(primary_index) <= 8)
            {
                reject(&mut result, item, "distant_action_context", "actions");
                continue;
            }
            let raw_text = item
                .get("text")
                .and_then(Value::as_str)
                .filter(|t| !crate::sanitize::collapse(t).is_empty() && t.chars().count() <= 280);
            let raw_due = item
                .get("due")
                .and_then(Value::as_str)
                .filter(|d| d.chars().count() <= 80);
            let owner = item
                .get("owner")
                .and_then(Value::as_str)
                .filter(|o| *o == "source" || *o == "unknown" || self.speakers.contains_key(*o));
            let basis = item
                .get("basis")
                .and_then(Value::as_str)
                .filter(|b| ["commitment", "assignment", "request", "unclear"].contains(b));
            let importance = item
                .get("importance")
                .and_then(Value::as_i64)
                .filter(|i| (1..=5).contains(i));
            let (Some(raw_text), Some(raw_due), Some(owner), Some(basis), Some(importance)) =
                (raw_text, raw_due, owner, basis, importance)
            else {
                reject(&mut result, item, "invalid_action", "actions");
                continue;
            };
            let cited_text = ids
                .iter()
                .filter_map(|id| visible_text(id))
                .collect::<Vec<_>>()
                .join(" ");
            let due = spoken_due(
                raw_due,
                &visible.keys().cloned().collect(),
                Some(&cited_text),
            );
            let quote = match item.get("quote") {
                None => None,
                Some(Value::String(raw)) => {
                    let mut value = crate::sanitize::collapse(raw);
                    let chars: Vec<char> = value.chars().collect();
                    if chars.len() > 1
                        && ((chars[0] == '"' && chars[chars.len() - 1] == '"')
                            || (chars[0] == '“' && chars[chars.len() - 1] == '”'))
                    {
                        value = chars[1..chars.len() - 1]
                            .iter()
                            .collect::<String>()
                            .trim()
                            .to_string();
                    }
                    Some(value)
                }
                Some(_) => {
                    reject(&mut result, item, "invalid_action", "actions");
                    continue;
                }
            };
            if quote.as_ref().is_some_and(|q| q.chars().count() > 1_000) {
                reject(&mut result, item, "invalid_action", "actions");
                continue;
            }
            // A quote found word for word in one cited row re-anchors the task there.
            let mut anchor = primary.to_string();
            if let Some(quote) = quote.as_deref().filter(|q| !q.is_empty()) {
                let matches: Vec<&String> = ids
                    .iter()
                    .filter(|id| {
                        crate::sanitize::collapse(&visible_text(id).unwrap_or_default())
                            .contains(quote)
                    })
                    .collect();
                if matches.len() == 1 {
                    anchor = matches[0].clone();
                    let anchor_index = row(&anchor);
                    if !ids.iter().all(|id| row(id).abs_diff(anchor_index) <= 8) {
                        reject(&mut result, item, "distant_action_context", "actions");
                        continue;
                    }
                }
            }
            let visible_source = visible_text(&anchor).unwrap_or_default();
            if ownership::is_bare_acceptance(&visible_source) && ids.len() == 1 {
                reject(&mut result, item, "missing_task_context", "actions");
                continue;
            }
            if ownership::is_conversation_management(&visible_source) {
                reject(&mut result, item, "conversation_management", "actions");
                continue;
            }
            let anchor_row = row(&anchor);
            let user_reply = if basis == "request" || basis == "assignment" {
                self.user_reply(anchor_row)
            } else {
                None
            };
            let owner_key = self.speakers.get(owner).cloned();
            let claim = OwnershipClaim {
                owner: owner_key.as_deref(),
                names_source: owner == "source",
                basis,
                quote: quote.as_deref(),
                task: raw_text,
            };
            let context_rows: Vec<usize> = context.iter().map(|id| row(id)).collect();
            let finding = ownership.resolve(
                &claim,
                primary_index,
                &context_rows,
                (anchor != primary).then_some(anchor_row),
                user_reply.as_deref(),
            );
            let attribution = finding.attribution.clone();
            if basis == "commitment"
                && attribution.resolution == OwnerResolution::Unresolved
                && attribution.rejection != Some(ownership::RejectionReason::QuoteNotFound)
                && !finding.cites_undertaking
            {
                let contradicted = finding.cites_only_refused_undertakings
                    || if self.is_english {
                        !finding.looks_forward
                            || ownership::undertaking_is_negated_or_questioned(&visible_source)
                    } else {
                        visible_source.contains('?')
                    };
                if contradicted {
                    reject(&mut result, item, "unsupported_commitment", "actions");
                    continue;
                }
            }
            if let Some(found) = ids.iter().position(|id| row(id) == finding.anchor)
                && found != 0
            {
                let moved = ids.remove(found);
                ids.insert(0, moved);
            }
            let anchor = ids[0].clone();
            let compact_owner = attribution
                .speaker_id
                .as_ref()
                .filter(|_| attribution.resolution != OwnerResolution::Unresolved)
                .and_then(|key| {
                    self.speakers
                        .iter()
                        .find(|(_, k)| *k == key)
                        .map(|(p, _)| p.clone())
                });
            let expected = compact_owner.or_else(|| {
                visible
                    .get(&anchor)
                    .and_then(|p| p.first())
                    .map(|u| u.speaker.clone())
            });
            let Some(text) = self.prose(raw_text, expected.as_deref()) else {
                reject(&mut result, item, "speaker_reference", "actions");
                continue;
            };
            // A past/status report is not a pending task.
            if STATUS_PREFIX.is_match(&text) && !FORWARD_WORDS.is_match(&text) {
                reject(&mut result, item, "status_not_task", "actions");
                continue;
            }
            let resolved_owner = match attribution.resolution {
                OwnerResolution::User => Some("Me".to_string()),
                OwnerResolution::Other => attribution
                    .speaker_id
                    .as_ref()
                    .and_then(|k| view.roster.get(k))
                    .map(|s| s.name.clone()),
                OwnerResolution::Unresolved => None,
            };
            let citations: Vec<OutcomeSourceCitation> = ids
                .iter()
                .map(|id| citation(row(id), &visible_text(id).unwrap_or_default()))
                .collect();
            let rejection = attribution.rejection;
            let action = ActionItem::new(
                &text,
                resolved_owner.as_deref(),
                (!due.is_empty()).then_some(due.as_str()),
                Some(attribution.resolution == OwnerResolution::User),
                importance as u8,
                citations,
                Some(attribution.into_core()),
            );
            result.records.push(Record {
                kind: "actions".into(),
                source: anchor.clone(),
                text: text.clone(),
            });
            if let Some(reason) = rejection.and_then(|r| r.repair_reason()) {
                result.rejected.push(Rejection {
                    sources: vec![anchor],
                    kind: "actions".into(),
                    reason: reason.into(),
                    text: Some(text),
                    action_id: Some(action.id.clone()),
                });
            }
            result.outcomes.action_items.push(action);
        }
        result
    }

    /// The user's key when the user speaks the next turn after a request.
    fn user_reply(&self, index: usize) -> Option<String> {
        let segments = &self.view.transcript.segments;
        let requester = &self.view.keys[index];
        let mut end = segments[index].end;
        for (next, segment) in segments.iter().enumerate().skip(index + 1) {
            let key = &self.view.keys[next];
            if key == requester {
                end = end.max(segment.end);
                continue;
            }
            if self.view.texts[next].is_empty() || !self.view.is_own_voice(next) {
                continue;
            }
            if segment.start - end > 15.0 {
                return None;
            }
            return self
                .view
                .roster
                .get(key)
                .filter(|s| s.identity == SpeakerIdentity::User)
                .map(|_| key.clone());
        }
        None
    }

    /// Model text as stored prose, or `None` when it names a speaker ID.
    fn prose(&self, text: &str, expected_speaker: Option<&str>) -> Option<String> {
        let mut value = crate::sanitize::collapse(text);
        if let Some(expected) = expected_speaker {
            let identity = self
                .speakers
                .get(expected)
                .and_then(|k| self.view.roster.get(k))
                .map(|s| s.identity);
            if identity != Some(SpeakerIdentity::User) && SECOND_PERSON.is_match(&value) {
                return None;
            }
            if let Ok(prefix) = Regex::new(&format!(
                r"(?i)^(?:(?:Speaker|User)\s+)?{}\b[ :,-]*",
                regex::escape(expected)
            )) && let Some(m) = prefix.find(&value)
            {
                value = value[m.end()..].to_string();
                let mut chars = value.chars();
                if let Some(first) = chars.next() {
                    value = first.to_uppercase().collect::<String>() + chars.as_str();
                }
            }
        }
        let contains_reference = self.speakers.keys().any(|id| {
            Regex::new(&format!(r"\b{}\b", regex::escape(id))).is_ok_and(|r| r.is_match(&value))
        });
        (!value.is_empty() && !contains_reference).then_some(value)
    }
}

static EMPTY_OUTCOME: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)^none(?: explicitly)?(?: (?:settled|recorded|identified|mentioned|made))?(?: in (?:this|the) (?:segment|part|meeting))?[.!]?$").expect("valid regex")
});
static STATUS_PREFIX: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)^(?:reported|completed|created|merged|updated|discussed|noted|confirmed|mentioned|stated|explained)\b").expect("valid regex")
});
static FORWARD_WORDS: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)\b(?:will|shall|going to|next|needs to|must)\b").expect("valid regex")
});
static SECOND_PERSON: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?i)\b(?:you|your|yours|yourself)\b").expect("valid regex"));
static SOURCE_ID: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^[sS]\d+$").expect("valid regex"));
static YEAR: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?:^|[^0-9])((?:19|20)\d{2})(?:[^0-9]|$)").expect("valid regex"));

fn valid_section(section: &str, template: NoteTemplate) -> bool {
    if template == NoteTemplate::Freeform {
        return !crate::sanitize::collapse(section).is_empty()
            && section.chars().count() <= 80
            && !section.contains(['\n', '\r', '#'])
            && !section.eq_ignore_ascii_case("Action items");
    }
    sections(template).contains(&section)
}

/// The due date as spoken, or "" (`MeetingNotesEvidence.spokenDue`): a copied
/// source ID or a year nobody said is dropped.
pub fn spoken_due(raw: &str, source_ids: &BTreeSet<String>, cited_text: Option<&str>) -> String {
    let value = raw.trim();
    let bare = value.trim_matches(|c| "[]()".contains(c));
    if source_ids.contains(bare) || SOURCE_ID.is_match(bare) {
        return String::new();
    }
    if let Some(cited) = cited_text {
        for caps in YEAR.captures_iter(value) {
            if !cited.contains(&caps[1]) {
                return String::new();
            }
        }
    }
    value.to_string()
}

/// Every enum value in a schema, counted per occurrence.
pub fn enum_value_count(schema: &Value) -> usize {
    match schema {
        Value::Object(map) => {
            map.get("enum")
                .and_then(Value::as_array)
                .map_or(0, Vec::len)
                + map
                    .iter()
                    .filter(|(k, _)| *k != "enum")
                    .map(|(_, v)| enum_value_count(v))
                    .sum::<usize>()
        }
        Value::Array(items) => items.iter().map(enum_value_count).sum(),
        _ => 0,
    }
}

fn object(properties: Value) -> Value {
    let required: Vec<String> = properties
        .as_object()
        .map(|m| {
            m.keys()
                .cloned()
                .collect::<BTreeSet<_>>()
                .into_iter()
                .collect()
        })
        .unwrap_or_default();
    json!({"type": "object", "additionalProperties": false, "required": required, "properties": properties})
}

/// `MeetingNotesEvidence.schema`.
pub fn schema(
    units: &[Unit],
    speakers: &[String],
    template: NoteTemplate,
    maximum_notes: usize,
    maximum_actions: usize,
    action_texts: Option<&[String]>,
) -> Value {
    let mut ids: Vec<String> = units
        .iter()
        .map(|u| u.source.clone())
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect();
    ids.sort();
    let source = json!({"type": "string", "enum": ids});
    let text = json!({"type": "string", "minLength": 1, "maxLength": 280});
    let section = if template == NoteTemplate::Freeform {
        json!({"type": "string", "minLength": 1, "maxLength": 80})
    } else {
        json!({"type": "string", "enum": sections(template)})
    };
    let mut owners = vec!["source".to_string(), "unknown".to_string()];
    let mut sorted_speakers = speakers.to_vec();
    sorted_speakers.sort();
    owners.extend(sorted_speakers);
    let action_text = match action_texts {
        Some(texts) => {
            json!({"type": "string", "enum": texts.iter().cloned().collect::<BTreeSet<_>>().into_iter().collect::<Vec<_>>()})
        }
        None => text.clone(),
    };
    json::sort_keys(object(json!({
        "notes": {"type": "array", "maxItems": maximum_notes, "items": object(json!({"section": section, "text": text, "source": source}))},
        "actions": {"type": "array", "maxItems": maximum_actions, "items": object(json!({
            "text": action_text,
            "source": source,
            "context": {"type": "array", "maxItems": 2, "items": source},
            "owner": {"type": "string", "enum": owners},
            "basis": {"type": "string", "enum": ["commitment", "assignment", "request", "unclear"]},
            "quote": {"type": "string", "maxLength": 1_000},
            "due": {"type": "string", "maxLength": 80},
            "importance": {"type": "integer", "enum": [1, 2, 3, 4, 5]},
        }))},
        "has_more": {"type": "boolean"},
    })))
}

#[cfg(test)]
mod tests {
    use super::*;
    use lokalbot_core::Transcript;
    use lokalbot_core::model::Segment;

    fn northwind() -> Transcript {
        let rows = [
            (
                "them",
                "Our team loves the export feature, but we need SSO before we roll out company-wide.",
            ),
            (
                "me",
                "SSO is on the Q3 roadmap. I'll send you the security overview this week.",
            ),
            (
                "them",
                "Great. Pricing for 250 seats would help us get budget approved.",
            ),
        ];
        Transcript {
            segments: rows
                .iter()
                .enumerate()
                .map(|(i, (speaker, text))| Segment {
                    start: i as f64 * 15.0,
                    end: (i + 1) as f64 * 15.0,
                    speaker: speaker.to_string(),
                    text: text.to_string(),
                    confidence: None,
                    timing_precision: None,
                    attribution: None,
                })
                .collect(),
            engine: "test".into(),
            ..Default::default()
        }
    }

    #[test]
    fn units_roster_and_prompt_follow_macos() {
        let transcript = northwind();
        let evidence = Evidence::new(View::new(&transcript, true), Uuid::nil(), true);
        assert_eq!(
            evidence.roster_json,
            r#"[{"id":"p1","identity":"user","name":"Me","speaker_id":"me"},{"id":"p2","identity":"other","name":"Them","speaker_id":"them"}]"#
        );
        assert_eq!(evidence.units.len(), 3);
        assert_eq!(
            evidence.units[1].line(),
            "s2|p1|SSO is on the Q3 roadmap. I'll send you the security overview this week."
        );
        assert!(evidence.units[1].is_user_commitment);
        assert!(!evidence.units[0].is_user_commitment);
        let prompt = evidence.prompt(&evidence.units);
        assert!(prompt.starts_with("Speaker roster: [{\"id\":\"p1\""));
        assert!(prompt.contains("\nExplicit user commitments: s2. Include these actions; use nearby context to resolve what the user accepted.\n\nEvidence rows are source|speaker|spoken text:\ns1|p2|Our team"));
        let schema = evidence.schema(&evidence.units, NoteTemplate::Meeting, 3, 2, None);
        assert_eq!(
            schema["properties"]["actions"]["items"]["properties"]["owner"]["enum"],
            json!(["source", "unknown", "p1", "p2"])
        );
        assert_eq!(schema["required"], json!(["actions", "has_more", "notes"]));
        // section 4 + source 3, then source 3 + context 3 + owner 4 + basis 4 + importance 5.
        assert_eq!(enum_value_count(&schema), 26);
    }

    #[test]
    fn validation_accepts_grounded_records_and_rejects_the_rest() {
        let transcript = northwind();
        let evidence = Evidence::new(View::new(&transcript, true), Uuid::nil(), true);
        let output = json!({
            "notes": [
                {"section": "TL;DR", "text": "SSO is the blocker for a company-wide rollout.", "source": "s1"},
                {"section": "Key points", "text": "The p1 roster entry asked for pricing.", "source": "s3"},
                {"section": "Decisions", "text": "None explicitly settled.", "source": "s2"},
                {"section": "Key points", "text": "Ghost", "source": "s9"},
            ],
            "actions": [
                {"text": "Send the security overview", "source": "s2", "context": [], "owner": "source", "basis": "commitment",
                 "quote": "I'll send you the security overview this week.", "due": "this week", "importance": 4},
                {"text": "Reported the roadmap", "source": "s2", "context": [], "owner": "source", "basis": "commitment",
                 "quote": "", "due": "", "importance": 2},
            ],
            "has_more": false,
        })
        .to_string();
        let validated = evidence.validate(&output, &evidence.units, NoteTemplate::Meeting, 10, 10);
        assert_eq!(validated.claims.len(), 1);
        assert_eq!(
            validated.claims[0].segment_id,
            "segment-0000-0000000000-0000015000"
        );
        let reasons: Vec<&str> = validated
            .rejected
            .iter()
            .map(|r| r.reason.as_str())
            .collect();
        assert!(reasons.contains(&"invalid_note"), "{reasons:?}");
        assert!(reasons.contains(&"empty_outcome"), "{reasons:?}");
        assert!(reasons.contains(&"unknown_source"), "{reasons:?}");
        assert!(reasons.contains(&"status_not_task"), "{reasons:?}");
        assert_eq!(validated.outcomes.action_items.len(), 1);
        let action = &validated.outcomes.action_items[0];
        assert!(action.is_for_user);
        assert_eq!(action.owner.as_deref(), Some("Me"));
        assert_eq!(action.due.as_deref(), Some("this week"));
        assert_eq!(
            action.citations[0].segment_id,
            "segment-0001-0000015000-0000030000"
        );
        assert!(validated.complete);
    }

    #[test]
    fn due_dates_drop_copied_ids_and_invented_years() {
        let ids: BTreeSet<String> = ["s268".to_string()].into();
        assert_eq!(spoken_due("s268", &ids, None), "");
        assert_eq!(spoken_due("[s12]", &BTreeSet::new(), None), "");
        assert_eq!(
            spoken_due("2024-01-01", &BTreeSet::new(), Some("by Friday")),
            ""
        );
        assert_eq!(
            spoken_due("by Friday", &BTreeSet::new(), Some("by Friday")),
            "by Friday"
        );
        assert_eq!(
            spoken_due("March 2026", &BTreeSet::new(), Some("ship in March 2026")),
            "March 2026"
        );
    }
}
