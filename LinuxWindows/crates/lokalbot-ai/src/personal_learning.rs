//! The overnight learning pass's model call (`PersonalLearning`). After the day's
//! review it reads only the person's own words from that day and asks the Think
//! model for at most three durable things about them. Every result must point at
//! one of those lines and be grounded in it; anything else is dropped. Which lines
//! may be read is decided in `lokalbot_core::personal::learning`.

use std::collections::HashMap;

use anyhow::Result;
use serde::Deserialize;
use serde_json::{Value, json};

use lokalbot_core::evidence::{Provenance, Source};
use lokalbot_core::personal::learning::{MAX_PER_NIGHT, Utterance, UtteranceSource};
use lokalbot_core::personal::{
    Claim, ClaimKind, LearningCandidate, MAX_CHARACTERS, Origin, TypedSource, content_words,
};

use crate::json::{extract_json_object, strip_reasoning};
use crate::prompts;
use crate::sanitize::sanitize;
use crate::think::{ChatRequest, ThinkClient, dot};

const MAX_OUTPUT_TOKENS: u32 = 1_024;
/// EmbeddingGemma 2 with the sentence-similarity prompt, measured on Serbian lines
/// against English items (2026-10-14): correct translations 0.83–0.95, unrelated
/// claims 0.73–0.79, and a wrong detail 0.80–0.90. Below the floor an item is
/// dropped. Above it, a fact or goal is saved only with a shared word root or a
/// very high score; otherwise it waits for review. Recalibrate whenever the
/// embedding model changes.
pub const CROSS_LANGUAGE_FLOOR: f32 = 0.82;
pub const CONFIDENT_SIMILARITY: f32 = 0.90;

pub fn prompt(utterances: &[Utterance], known: &[Claim]) -> String {
    let mut lines = vec![prompts::personal_learning_rules(MAX_PER_NIGHT)];
    if !known.is_empty() {
        lines.push(String::new());
        lines.push("Already known (do not repeat):".into());
        for claim in known.iter().take(40) {
            lines.push(format!("- {}", sanitize(&claim.text, Some(MAX_CHARACTERS))));
        }
    }
    lines.push(String::new());
    lines.push(format!(
        "The user's lines from {}, each with where they said, typed, or dictated it:",
        utterances
            .first()
            .map(|u| u.day_key.as_str())
            .unwrap_or("the reviewed day")
    ));
    for utterance in utterances {
        lines.push(format!(
            "{} ({}): {}",
            utterance.handle,
            sanitize(&utterance.label, Some(80)),
            utterance.text
        ));
    }
    lines.join("\n")
}

pub fn schema() -> Value {
    json!({
        "type": "object",
        "properties": {
            "items": {
                "type": "array",
                "items": {
                    "type": "object",
                    "properties": {
                        "line": {"type": "string"},
                        "kind": {"type": "string", "enum": ["fact", "goal", "preference"]},
                        "text": {"type": "string"},
                    },
                    "required": ["line", "kind", "text"],
                },
            },
        },
        "required": ["items"],
    })
}

#[derive(Deserialize)]
struct ReplyItem {
    line: String,
    kind: String,
    text: String,
}

#[derive(Deserialize)]
struct Reply {
    items: Vec<ReplyItem>,
}

/// An item the model proposed, tied to the line it cites.
#[derive(Clone, Debug, PartialEq)]
pub struct Proposal {
    pub kind: ClaimKind,
    pub text: String,
    pub utterance: Utterance,
}

/// Every item that cites a real line with a learnable kind, in reply order.
pub fn proposals(output: &str, utterances: &[Utterance]) -> Vec<Proposal> {
    let visible = strip_reasoning(output);
    let Some(reply) =
        extract_json_object(&visible).and_then(|object| serde_json::from_str::<Reply>(object).ok())
    else {
        return Vec::new();
    };
    let mut by_handle: HashMap<String, &Utterance> = HashMap::new();
    for utterance in utterances {
        by_handle
            .entry(utterance.handle.to_uppercase())
            .or_insert(utterance);
    }
    reply
        .items
        .into_iter()
        .filter_map(|item| {
            let utterance = by_handle.get(&item.line.trim().to_uppercase())?;
            let kind = match item.kind.to_lowercase().as_str() {
                "fact" => ClaimKind::Fact,
                "goal" => ClaimKind::Goal,
                "preference" => ClaimKind::Preference,
                // Principles are never learned.
                _ => return None,
            };
            Some(Proposal {
                kind,
                text: item.text,
                utterance: (*utterance).clone(),
            })
        })
        .collect()
}

/// Word overlap: at least a third of the item's content words are in the line.
pub fn is_grounded(claim: &str, line: &str) -> bool {
    let claim_words = content_words(claim);
    if claim_words.is_empty() {
        return false;
    }
    let shared = claim_words.intersection(&content_words(line)).count();
    shared >= claim_words.len().div_ceil(3).max(1)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Grounding {
    Grounded,
    NeedsReview,
    Rejected,
}

pub fn cross_language_verdict(similarity: f32, claim: &str, line: &str) -> Grounding {
    if similarity < CROSS_LANGUAGE_FLOOR {
        return Grounding::Rejected;
    }
    if similarity >= CONFIDENT_SIMILARITY || shares_word_root(claim, line) {
        return Grounding::Grounded;
    }
    Grounding::NeedsReview
}

/// The two texts' dominant languages differ, so word overlap can't apply. Unknown
/// counts as the same language: the stricter path.
pub fn is_cross_language(claim: &str, line: &str) -> bool {
    match (whatlang::detect_lang(claim), whatlang::detect_lang(line)) {
        (Some(a), Some(b)) => a != b,
        _ => false,
    }
}

/// Serbian Cyrillic to Latin, enough for the word-root check.
fn latin(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for c in text.chars() {
        let lower = c.to_lowercase().next().unwrap_or(c);
        let mapped = match lower {
            'а' => "a",
            'б' => "b",
            'в' => "v",
            'г' => "g",
            'д' => "d",
            'ђ' => "đ",
            'е' => "e",
            'ж' => "ž",
            'з' => "z",
            'и' => "i",
            'ј' => "j",
            'к' => "k",
            'л' => "l",
            'љ' => "lj",
            'м' => "m",
            'н' => "n",
            'њ' => "nj",
            'о' => "o",
            'п' => "p",
            'р' => "r",
            'с' => "s",
            'т' => "t",
            'ћ' => "ć",
            'у' => "u",
            'ф' => "f",
            'х' => "h",
            'ц' => "c",
            'ч' => "č",
            'џ' => "dž",
            'ш' => "š",
            _ => {
                out.push(c);
                continue;
            }
        };
        out.push_str(mapped);
    }
    out
}

/// A content word of the item and of the line (Cyrillic transliterated) start the
/// same way: "platform" in "platformu", "marathon" in "maraton".
pub fn shares_word_root(claim: &str, line: &str) -> bool {
    let line_words = content_words(&latin(line));
    for word in content_words(claim) {
        for other in &line_words {
            let shared = word
                .chars()
                .zip(other.chars())
                .take_while(|(a, b)| a == b)
                .count();
            let shorter = word.chars().count().min(other.chars().count());
            if shared >= 4 || (shared >= 3 && shared == shorter) {
                return true;
            }
        }
    }
    false
}

/// What a learned item depends on: its meeting, or the day's activity evidence for
/// a coding-agent request. An Ask question or dictation has none.
pub fn provenance(utterance: &Utterance, revision: u64) -> Option<Provenance> {
    let source = match &utterance.source {
        UtteranceSource::Meeting(id) => Source {
            kind: "meeting".into(),
            id: lokalbot_core::ids::uuid_upper(id),
            day_key: utterance.day_key.clone(),
        },
        UtteranceSource::Typed(TypedSource::CodingAgent { .. }) => Source {
            kind: "screenDay".into(),
            id: utterance.day_key.clone(),
            day_key: utterance.day_key.clone(),
        },
        UtteranceSource::Typed(_) => return None,
    };
    Some(Provenance {
        sources: vec![source],
        revision,
        includes_unattributed_context: false,
    })
}

fn candidate(proposal: &Proposal, needs_review: bool, revision: u64) -> LearningCandidate {
    let utterance = &proposal.utterance;
    let origin = match &utterance.source {
        UtteranceSource::Meeting(id) => Origin::Learned {
            meeting_id: *id,
            day_key: utterance.day_key.clone(),
        },
        UtteranceSource::Typed(source) => Origin::Typed {
            source: source.clone(),
            day_key: utterance.day_key.clone(),
        },
    };
    LearningCandidate {
        kind: proposal.kind,
        text: proposal.text.clone(),
        quote: Some(utterance.text.clone()),
        origin,
        evidence: provenance(utterance, revision),
        needs_review: needs_review || utterance.is_typed(),
    }
}

/// Vectors for texts, L2-normalized, or `None` when no embedder is available.
pub type Embed<'a> = &'a dyn Fn(&[String]) -> Option<Vec<Vec<f32>>>;

/// Word overlap for items in the line's language. An item the model translated
/// can't share words, so it is compared by meaning instead, when the embedder is
/// available. Without it those items are dropped. At most three.
pub fn grounded_candidates(
    output: &str,
    utterances: &[Utterance],
    embed: Option<Embed<'_>>,
    revision: u64,
) -> Vec<LearningCandidate> {
    let all = proposals(output, utterances);
    let mut verdicts: Vec<Option<Grounding>> = all
        .iter()
        .map(|proposal| {
            if is_grounded(&proposal.text, &proposal.utterance.text) {
                Some(Grounding::Grounded)
            } else if is_cross_language(&proposal.text, &proposal.utterance.text) {
                None
            } else {
                Some(Grounding::Rejected)
            }
        })
        .collect();
    let pending: Vec<usize> = (0..all.len()).filter(|&i| verdicts[i].is_none()).collect();
    if !pending.is_empty() {
        let texts: Vec<String> = pending
            .iter()
            .flat_map(|&i| [all[i].text.clone(), all[i].utterance.text.clone()])
            .collect();
        let vectors = embed
            .and_then(|embed| embed(&texts))
            .filter(|vectors| vectors.len() == texts.len());
        for (offset, &index) in pending.iter().enumerate() {
            verdicts[index] = Some(match &vectors {
                Some(vectors) => cross_language_verdict(
                    dot(&vectors[offset * 2], &vectors[offset * 2 + 1]),
                    &all[index].text,
                    &all[index].utterance.text,
                ),
                None => Grounding::Rejected,
            });
        }
    }
    let mut result = Vec::new();
    for (proposal, verdict) in all.iter().zip(verdicts) {
        if result.len() >= MAX_PER_NIGHT {
            break;
        }
        match verdict {
            Some(Grounding::Grounded) => result.push(candidate(proposal, false, revision)),
            Some(Grounding::NeedsReview) => result.push(candidate(proposal, true, revision)),
            _ => {}
        }
    }
    result
}

/// The pass over lines already gathered, so the caller can first check whether the
/// day's lines were read before. No lines, no model call.
pub fn run(
    think: &ThinkClient,
    lines: &[Utterance],
    known: &[Claim],
    revision: u64,
    embed: Option<Embed<'_>>,
) -> Result<Vec<LearningCandidate>> {
    if lines.is_empty() {
        return Ok(Vec::new());
    }
    let request = ChatRequest::new(prompts::PERSONAL_LEARNING_SYSTEM, prompt(lines, known))
        .json_schema(schema())
        .max_tokens(MAX_OUTPUT_TOKENS)
        .reasoning_budget(0)
        .temperature(0.0);
    let output = think.complete(&request)?;
    Ok(grounded_candidates(&output, lines, embed, revision))
}

#[cfg(test)]
mod tests {
    use super::*;
    use uuid::Uuid;

    fn line(handle: &str, text: &str) -> Utterance {
        Utterance {
            handle: handle.into(),
            source: UtteranceSource::Meeting(Uuid::nil()),
            label: "Weekly".into(),
            day_key: "2026-10-19".into(),
            text: text.into(),
        }
    }

    fn typed(handle: &str, text: &str) -> Utterance {
        Utterance {
            handle: handle.into(),
            source: UtteranceSource::Typed(TypedSource::Ask {
                conversation_id: Uuid::nil(),
            }),
            label: "typed in Ask".into(),
            day_key: "2026-10-19".into(),
            text: text.into(),
        }
    }

    #[test]
    fn the_prompt_holds_the_rules_known_items_and_lines() {
        let text = prompt(&[line("U1", "I live in Belgrade")], &[]);
        assert!(text.starts_with("From the user's lines below, pick at most 3 things"));
        assert!(text.contains("never translate it"));
        assert!(text.contains("Return {\"items\": []} when nothing qualifies"));
        assert!(text.contains("U1 (Weekly): I live in Belgrade"));
        assert!(!text.contains("Already known"));
    }

    #[test]
    fn items_must_cite_a_real_line_and_a_learnable_kind() {
        let lines = [line("U1", "I live in Belgrade")];
        let output = r#"Sure: {"items":[
            {"line":"u1","kind":"Fact","text":"I live in Belgrade."},
            {"line":"U9","kind":"fact","text":"Invented."},
            {"line":"U1","kind":"principle","text":"I value honesty."}
        ]}"#;
        let parsed = proposals(output, &lines);
        assert_eq!(parsed.len(), 1);
        assert_eq!(parsed[0].kind, ClaimKind::Fact);
        assert!(proposals("not json", &lines).is_empty());
    }

    #[test]
    fn grounding_needs_shared_words_in_the_same_language() {
        assert!(is_grounded(
            "I live in Belgrade.",
            "I live in Belgrade with my family"
        ));
        assert!(!is_grounded(
            "I am a doctor in Paris.",
            "I live in Belgrade with my family"
        ));
        let lines = [line("U1", "I live in Belgrade with my family")];
        let output = r#"{"items":[{"line":"U1","kind":"fact","text":"I am a doctor in Paris."}]}"#;
        assert!(grounded_candidates(output, &lines, None, 1).is_empty());
    }

    #[test]
    fn a_translated_item_is_compared_by_meaning_only_with_an_embedder() {
        let serbian = "Ja živim u Beogradu sa svojom porodicom i radim na platformi već godinama";
        let lines = [line("U1", serbian)];
        let output = r#"{"items":[{"line":"U1","kind":"fact","text":"I live in Belgrade with my family and I work on the platform."}]}"#;
        assert!(is_cross_language(
            "I live in Belgrade with my family and I work on the platform.",
            serbian
        ));
        // Without the local embedder such an item is dropped.
        assert!(grounded_candidates(output, &lines, None, 1).is_empty());

        let confident = |texts: &[String]| Some(vec![vec![1.0_f32, 0.0]; texts.len()]);
        let found = grounded_candidates(output, &lines, Some(&confident), 1);
        assert_eq!(found.len(), 1);
        assert!(!found[0].needs_review);

        // Below the floor it is dropped.
        let unrelated = |texts: &[String]| {
            Some(
                (0..texts.len())
                    .map(|i| {
                        if i % 2 == 0 {
                            vec![1.0_f32, 0.0]
                        } else {
                            vec![0.0, 1.0]
                        }
                    })
                    .collect(),
            )
        };
        assert!(grounded_candidates(output, &lines, Some(&unrelated), 1).is_empty());
    }

    #[test]
    fn a_middling_score_waits_for_review_unless_a_word_root_is_shared() {
        assert_eq!(
            cross_language_verdict(0.85, "I work as a doctor.", "Radim kao inženjer."),
            Grounding::NeedsReview
        );
        assert_eq!(
            cross_language_verdict(0.85, "I lead the platform team.", "Vodim tim za платформу."),
            Grounding::Grounded
        );
        assert_eq!(
            cross_language_verdict(0.91, "I work as a doctor.", "Radim kao inženjer."),
            Grounding::Grounded
        );
        assert_eq!(
            cross_language_verdict(0.80, "I lead the platform team.", "Vodim tim za platformu."),
            Grounding::Rejected
        );
    }

    #[test]
    fn typed_items_always_wait_and_ask_items_carry_no_evidence() {
        let lines = [typed("U1", "I live in Belgrade and I want a summary")];
        let output = r#"{"items":[{"line":"U1","kind":"fact","text":"I live in Belgrade."}]}"#;
        let found = grounded_candidates(output, &lines, None, 7);
        assert_eq!(found.len(), 1);
        assert!(found[0].needs_review);
        assert!(found[0].evidence.is_none());
        assert_eq!(
            found[0].quote.as_deref(),
            Some("I live in Belgrade and I want a summary")
        );

        let meeting = grounded_candidates(
            output,
            &[line("U1", "I live in Belgrade and I want a summary")],
            None,
            7,
        );
        assert!(!meeting[0].needs_review);
        let evidence = meeting[0].evidence.as_ref().unwrap();
        assert_eq!(evidence.revision, 7);
        assert_eq!(evidence.sources[0].kind, "meeting");
    }

    #[test]
    fn at_most_three_a_night() {
        let lines = [line(
            "U1",
            "I live in Belgrade, I lead a team, I run, I read, I cook",
        )];
        let output = r#"{"items":[
            {"line":"U1","kind":"fact","text":"I live in Belgrade."},
            {"line":"U1","kind":"fact","text":"I lead a team."},
            {"line":"U1","kind":"goal","text":"I run."},
            {"line":"U1","kind":"preference","text":"I read."}
        ]}"#;
        assert_eq!(grounded_candidates(output, &lines, None, 1).len(), 3);
    }
}
