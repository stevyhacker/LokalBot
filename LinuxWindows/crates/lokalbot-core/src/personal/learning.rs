//! The deterministic half of the overnight learning pass (`PersonalLearning`):
//! which of the person's own lines from a day may be read. The model call and
//! the grounding checks are in `lokalbot-ai`. Lines without a first-person word
//! are never sent; other speakers' lines are never included.

use std::collections::{HashMap, HashSet};

use anyhow::Result;
use chrono::NaiveDate;
use uuid::Uuid;

use super::TypedSource;
use super::dictation_log::Entry as DictationEntry;
use crate::coding_agents::CodingAgentBurst;
use crate::dream::day_key;
use crate::ids;
use crate::library::{Library, sha256_hex};
use crate::model::{
    ChatRole, Conversation, MeetingOutcomes, Segment, SpeakerAttribution, SpeakerIdentity,
    Transcript,
};
use crate::text::sanitize;
use crate::time::{local_day, local_day_bounds};

pub const MAX_PER_NIGHT: usize = 3;
pub const MAX_UTTERANCES: usize = 40;
/// Typed lines share the budget but never crowd meetings out.
pub const MAX_TYPED_UTTERANCES: usize = 15;
pub const UTTERANCE_CHARACTER_BUDGET: usize = 6_000;
pub const MAX_TURN_CHARACTERS: usize = 400;
pub const MINIMUM_WORDS: usize = 5;

#[derive(Clone, Debug, PartialEq)]
pub enum UtteranceSource {
    /// Consecutive microphone segments of one meeting, joined.
    Meeting(Uuid),
    Typed(TypedSource),
}

/// One line of the person's own words. `handle` is what the model cites.
#[derive(Clone, Debug, PartialEq)]
pub struct Utterance {
    pub handle: String,
    pub source: UtteranceSource,
    /// The meeting title or "typed to Claude Code", shown to the model.
    pub label: String,
    pub day_key: String,
    pub text: String,
}

impl Utterance {
    pub fn is_typed(&self) -> bool {
        matches!(self.source, UtteranceSource::Typed(_))
    }
}

/// Something the person typed or dictated that day.
#[derive(Clone, Debug, PartialEq)]
pub struct TypedLine {
    pub source: TypedSource,
    pub text: String,
}

impl TypedLine {
    pub fn label(&self) -> String {
        match &self.source {
            TypedSource::CodingAgent { name } => format!("typed to {name}"),
            TypedSource::Ask { .. } => "typed in Ask".into(),
            TypedSource::Dictation { app } if app.is_empty() => "dictated".into(),
            TypedSource::Dictation { app } => format!("dictated in {app}"),
        }
    }
}

/// How many first-person words a line has (English and Serbian).
pub fn self_reference_score(text: &str) -> usize {
    const WORDS: &[&str] = &[
        "i",
        "i'm",
        "im",
        "i've",
        "i'd",
        "i'll",
        "my",
        "me",
        "mine",
        "myself",
        "ja",
        "moj",
        "moja",
        "moje",
        "moji",
        "mene",
        "meni",
        "sam",
        "imam",
        "zivim",
        "radim",
        "zelim",
        "planiram",
        "hocu",
        "ја",
        "мој",
        "моја",
        "моје",
        "мене",
        "мени",
        "сам",
        "имам",
        "живим",
        "радим",
        "желим",
        "планирам",
        "хоћу",
    ];
    ids::fold(text)
        .split(|c: char| !c.is_alphabetic() && c != '\'')
        .map(|word| word.trim_matches('\''))
        .filter(|word| WORDS.contains(word))
        .count()
}

fn word_count(text: &str) -> usize {
    text.split_whitespace().count()
}

fn is_own_speech(segment: &Segment, key: &str) -> bool {
    if !MeetingOutcomes::is_microphone_speaker(&segment.speaker) || key.ends_with("unclear") {
        return false;
    }
    match segment.attribution {
        // Older transcripts follow "My microphone is me".
        None => SpeakerAttribution::microphone_is_user(),
        Some(_) => Transcript::resolved_attribution(segment).identity == SpeakerIdentity::User,
    }
}

/// "local 1", "source2:local 3": one voice diarization told apart.
fn is_numbered_voice(key: &str) -> bool {
    let local = key.rsplit(':').next().unwrap_or(key);
    local
        .strip_prefix("local ")
        .is_some_and(|n| !n.is_empty() && n.chars().all(|c| c.is_ascii_digit()))
}

/// Joins consecutive segments of the person's own speech into turns. A voice they
/// confirmed as theirs wins. Otherwise, when diarization found several voices on
/// the microphone, the meeting counts only if one dominates (four times the next),
/// and then only that voice is used; with no clear winner the microphone was
/// shared and the meeting is skipped.
pub fn own_turns(segments: &[Segment]) -> Vec<String> {
    let keys: Vec<String> = segments
        .iter()
        .map(|s| Transcript::canonical_speaker_key(&s.speaker))
        .collect();
    let mine: Vec<usize> = (0..segments.len())
        .filter(|&i| is_own_speech(&segments[i], &keys[i]))
        .collect();
    let confirmed: HashSet<&str> = mine
        .iter()
        .filter(|&&i| {
            segments[i].attribution.as_ref().is_some_and(|a| {
                a.identity == SpeakerIdentity::User
                    && matches!(
                        a.method,
                        crate::model::AttributionMethod::Confirmation
                            | crate::model::AttributionMethod::Profile
                    )
            })
        })
        .map(|&i| keys[i].as_str())
        .collect();
    let mut voices: HashMap<&str, usize> = HashMap::new();
    for &i in &mine {
        if is_numbered_voice(&keys[i]) {
            *voices.entry(keys[i].as_str()).or_default() += 1;
        }
    }
    let mut ranked: Vec<(&str, usize)> = voices.into_iter().collect();
    ranked.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(b.0)));
    let accepted: HashSet<usize> = if !confirmed.is_empty() {
        mine.iter()
            .copied()
            .filter(|&i| confirmed.contains(keys[i].as_str()))
            .collect()
    } else if ranked.len() >= 2 {
        if ranked[0].1 < 4 * ranked[1].1 {
            return Vec::new();
        }
        mine.iter()
            .copied()
            .filter(|&i| keys[i] == ranked[0].0)
            .collect()
    } else {
        mine.iter().copied().collect()
    };
    let mut turns = Vec::new();
    let mut current = String::new();
    let flush = |current: &mut String, turns: &mut Vec<String>| {
        let text = sanitize(current, Some(MAX_TURN_CHARACTERS));
        if word_count(&text) >= MINIMUM_WORDS {
            turns.push(text);
        }
        current.clear();
    };
    for (index, segment) in segments.iter().enumerate() {
        if accepted.contains(&index) {
            if !current.is_empty() {
                current.push(' ');
            }
            current.push_str(&segment.text);
        } else if !current.is_empty() {
            flush(&mut current, &mut turns);
        }
    }
    if !current.is_empty() {
        flush(&mut current, &mut turns);
    }
    turns
}

/// Letters and digits only, case- and accent-folded, so a dictation and the
/// request it was pasted into compare equal despite punctuation.
fn folded_for_duplicate(text: &str) -> String {
    ids::fold(text)
        .chars()
        .filter(|c| c.is_alphanumeric())
        .collect()
}

/// The day's typed lines: requests sent to coding agents (scheduled runs
/// excluded), questions asked in Ask, and dictation kept for learning. A
/// "Remember …" message is already saved, so it is skipped, and a dictation that
/// became one of those requests is read once, from the request.
pub fn typed_lines(
    bursts: &[CodingAgentBurst],
    conversations: &[Conversation],
    dictations: &[DictationEntry],
    day: NaiveDate,
) -> Vec<TypedLine> {
    let mut lines = Vec::new();
    for burst in bursts {
        if burst.is_scheduled_run() || local_day(burst.start) != day {
            continue;
        }
        for prompt in &burst.prompts {
            lines.push(TypedLine {
                source: TypedSource::CodingAgent {
                    name: burst.agent.display_name().to_string(),
                },
                text: prompt.clone(),
            });
        }
    }
    for conversation in conversations {
        for (index, message) in conversation.messages.iter().enumerate() {
            if message.role != ChatRole::User
                || message.created_at.is_none_or(|at| local_day(at) != day)
            {
                continue;
            }
            if conversation
                .messages
                .get(index + 1)
                .is_some_and(|next| next.remember_receipt.is_some())
            {
                continue;
            }
            lines.push(TypedLine {
                source: TypedSource::Ask {
                    conversation_id: conversation.id,
                },
                text: message.text.clone(),
            });
        }
    }
    let typed_so_far: Vec<String> = lines
        .iter()
        .map(|line| folded_for_duplicate(&line.text))
        .collect();
    for entry in dictations {
        if local_day(entry.dictated_at) != day {
            continue;
        }
        let folded = folded_for_duplicate(&entry.text);
        if folded.is_empty()
            || typed_so_far
                .iter()
                .any(|t| t.contains(&folded) || folded.contains(t.as_str()))
        {
            continue;
        }
        lines.push(TypedLine {
            source: TypedSource::Dictation {
                app: entry.app_name.clone(),
            },
            text: entry.text.clone(),
        });
    }
    lines
}

/// The person's turns from `day`'s meetings and what they typed, most
/// self-descriptive first within the budget, then put back in order with handles.
pub fn utterances(
    library: &Library,
    day: NaiveDate,
    typed: &[TypedLine],
) -> Result<Vec<Utterance>> {
    let (start, end) = local_day_bounds(day);
    let mut meetings = library.list_meetings()?;
    meetings.retain(|m| !m.is_sample() && m.started_at >= start && m.started_at < end);
    meetings.sort_by_key(|m| m.started_at);
    let key = day_key(day);
    let mut turns: Vec<(usize, usize, Utterance)> = Vec::new();
    for meeting in &meetings {
        let Ok(Some(transcript)) = library.transcript(meeting) else {
            continue;
        };
        for text in own_turns(&transcript.segments) {
            let score = self_reference_score(&text);
            let order = turns.len();
            turns.push((
                order,
                score,
                Utterance {
                    handle: String::new(),
                    source: UtteranceSource::Meeting(meeting.id),
                    label: meeting.title.clone(),
                    day_key: key.clone(),
                    text,
                },
            ));
        }
    }
    for line in typed {
        let text = sanitize(&line.text, Some(MAX_TURN_CHARACTERS));
        if word_count(&text) < MINIMUM_WORDS {
            continue;
        }
        let score = self_reference_score(&text);
        let order = turns.len();
        turns.push((
            order,
            score,
            Utterance {
                handle: String::new(),
                source: UtteranceSource::Typed(line.source.clone()),
                label: line.label(),
                day_key: key.clone(),
                text,
            },
        ));
    }
    let mut ranked: Vec<&(usize, usize, Utterance)> = turns.iter().collect();
    ranked.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
    let mut chosen: Vec<(usize, Utterance)> = Vec::new();
    let mut used = 0;
    let mut typed_count = 0;
    for (order, score, utterance) in ranked {
        if *score == 0 {
            continue;
        }
        let length = utterance.text.chars().count();
        let typed_line = utterance.is_typed();
        if chosen.len() >= MAX_UTTERANCES
            || used + length > UTTERANCE_CHARACTER_BUDGET
            || (typed_line && typed_count >= MAX_TYPED_UTTERANCES)
        {
            continue;
        }
        used += length;
        if typed_line {
            typed_count += 1;
        }
        chosen.push((*order, utterance.clone()));
    }
    chosen.sort_by_key(|(order, _)| *order);
    Ok(chosen
        .into_iter()
        .enumerate()
        .map(|(index, (_, mut utterance))| {
            utterance.handle = format!("U{}", index + 1);
            utterance
        })
        .collect())
}

/// "lines=meeting:4,typed:2,dictated:0" for the log.
pub fn line_counts(lines: &[Utterance]) -> String {
    let (mut meeting, mut typed, mut dictated) = (0, 0, 0);
    for line in lines {
        match &line.source {
            UtteranceSource::Meeting(_) => meeting += 1,
            UtteranceSource::Typed(TypedSource::Dictation { .. }) => dictated += 1,
            UtteranceSource::Typed(_) => typed += 1,
        }
    }
    format!("lines=meeting:{meeting},typed:{typed},dictated:{dictated}")
}

/// What the pass read for a day, independent of order and handles. Dictated lines
/// are left out: they are deleted once read, so a later review of the same day
/// would otherwise always look changed.
pub fn fingerprint(lines: &[Utterance]) -> String {
    let mut material: Vec<String> = lines
        .iter()
        .filter(|line| {
            !matches!(
                line.source,
                UtteranceSource::Typed(TypedSource::Dictation { .. })
            )
        })
        .map(|line| format!("{}\u{1f}{}", line.label, line.text))
        .collect();
    material.sort();
    sha256_hex(material.join("\u{1e}").as_bytes())
}

/// Whether `lines` still contain the line a learned claim quotes, ignoring case,
/// accents, punctuation and where a long line was cut off.
pub fn quote_still_said(quote: Option<&str>, lines: &[String]) -> bool {
    let Some(quote) = quote else {
        return false;
    };
    let needle = folded_for_duplicate(&quote.replace('…', ""));
    if needle.chars().count() < 12 {
        return false;
    }
    lines.iter().any(|line| {
        let haystack = folded_for_duplicate(&line.replace('…', ""));
        haystack.contains(&needle) || (haystack.chars().count() >= 12 && needle.contains(&haystack))
    })
}
