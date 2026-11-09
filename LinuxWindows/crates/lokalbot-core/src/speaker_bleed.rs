//! Speaker bleed in a transcript (`SpeakerBleedFilter.swift`): a microphone
//! row that repeats a remote row. Words alone only mark uncertainty, because a
//! genuine repetition can have identical words and timing. Removing a row also
//! takes waveform evidence, which the speech crate measures from the tracks.

use std::collections::HashSet;

use crate::model::{
    AttributionMethod, AttributionSource, Segment, SpeakerAttribution, SpeakerIdentity,
    TimingPrecision, Transcript,
};

/// Longer blocks may be whole-track or fixed-window fallbacks, so their words
/// could be far apart inside the block.
const MAX_COMPARABLE_SPAN: f64 = 15.0;
/// Independent passes place the same utterance's boundaries slightly apart.
const MAX_BOUNDARY_DRIFT: f64 = 0.75;
const MIN_ALIGNED_COVERAGE: f64 = 0.85;
/// A few generic words are plausible simultaneous speech, not proof of echo.
const MIN_WORD_TOKENS: usize = 4;
/// Ideographic tokens are characters and carry less evidence than words.
const MIN_IDEOGRAPHIC_TOKENS: usize = 8;
const MAX_TEXT_BYTES: usize = 4_096;
const MAX_TOKENS: usize = 256;
const MAX_CANDIDATES: usize = 8;
/// Share of a row's words that must appear in one overlapping remote row for
/// notes evidence to treat it as possible echo.
const MIN_ECHO_WORD_COVERAGE: f64 = 0.8;
const MAX_ECHO_TIME_GAP: f64 = 2.0;

/// The attribution a row keeps while it may be echo.
pub fn suspected_echo() -> SpeakerAttribution {
    SpeakerAttribution {
        source: AttributionSource::Microphone,
        identity: SpeakerIdentity::Unresolved,
        method: AttributionMethod::SuspectedEcho,
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct Token {
    word: String,
    ideographic: bool,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct BleedReport {
    pub removed_segments: usize,
    pub removed_words: usize,
    pub suspected: HashSet<usize>,
}

impl BleedReport {
    pub fn changed(&self) -> bool {
        self.removed_segments > 0 || !self.suspected.is_empty()
    }
}

fn canonical(speaker: &str) -> String {
    speaker.trim().to_lowercase()
}

/// Confirmation or a remembered voice decided who this is. A microphone's
/// default identity is not such a decision.
pub fn has_identity_decision(attribution: &SpeakerAttribution) -> bool {
    matches!(
        attribution.method,
        AttributionMethod::Confirmation | AttributionMethod::Profile
    )
}

fn is_comparable_span(segment: &Segment) -> bool {
    if !matches!(
        segment.timing_precision,
        Some(TimingPrecision::Span | TimingPrecision::Token)
    ) || !segment.start.is_finite()
        || !segment.end.is_finite()
    {
        return false;
    }
    let duration = segment.end - segment.start;
    duration > 0.0 && duration <= MAX_COMPARABLE_SPAN
}

fn spans_are_aligned(lhs: &Segment, rhs: &Segment) -> bool {
    if !is_comparable_span(lhs)
        || !is_comparable_span(rhs)
        || (lhs.start - rhs.start).abs() > MAX_BOUNDARY_DRIFT
        || (lhs.end - rhs.end).abs() > MAX_BOUNDARY_DRIFT
    {
        return false;
    }
    let overlap = lhs.end.min(rhs.end) - lhs.start.max(rhs.start);
    let longest = (lhs.end - lhs.start).max(rhs.end - rhs.start);
    overlap > 0.0 && overlap / longest >= MIN_ALIGNED_COVERAGE
}

fn is_ideographic(c: char) -> bool {
    matches!(
        c as u32,
        0x3040..=0x30FF     // Hiragana and Katakana
        | 0x31F0..=0x31FF   // Katakana phonetic extensions
        | 0x3400..=0x4DBF   // CJK Unified Ideographs Extension A
        | 0x4E00..=0x9FFF   // CJK Unified Ideographs
        | 0xF900..=0xFAFF   // CJK Compatibility Ideographs
        | 0xFF66..=0xFF9D   // Halfwidth Katakana
        | 0x20000..=0x2FA1F // Extensions B-F/I + compatibility supplement
        | 0x30000..=0x323AF // Extensions G and H
    )
}

/// Case- and punctuation-insensitive tokens. Apostrophes inside a word stay
/// inside it, so short contractions can't manufacture enough tokens.
fn comparison_tokens(text: &str) -> Option<Vec<Token>> {
    if text.len() > MAX_TEXT_BYTES {
        return None;
    }
    let mut tokens: Vec<Token> = Vec::new();
    let mut word = String::new();
    let flush = |word: &mut String, tokens: &mut Vec<Token>| {
        if !word.is_empty() {
            tokens.push(Token {
                word: word.to_lowercase(),
                ideographic: false,
            });
            word.clear();
        }
    };
    let chars: Vec<char> = text.chars().collect();
    for (index, c) in chars.iter().copied().enumerate() {
        if is_ideographic(c) {
            flush(&mut word, &mut tokens);
            tokens.push(Token {
                word: c.to_lowercase().collect(),
                ideographic: true,
            });
        } else if c.is_alphanumeric() {
            word.push(c);
        } else if (c == '\'' || c == '’') && !word.is_empty() {
            let inside = chars
                .get(index + 1)
                .is_some_and(|next| next.is_alphanumeric() && !is_ideographic(*next));
            if inside {
                word.push('\'');
            } else {
                flush(&mut word, &mut tokens);
            }
        } else {
            flush(&mut word, &mut tokens);
        }
        if tokens.len() > MAX_TOKENS {
            return None;
        }
    }
    flush(&mut word, &mut tokens);
    (tokens.len() <= MAX_TOKENS).then_some(tokens)
}

fn evidence_tokens(text: &str) -> Option<Vec<Token>> {
    let tokens = comparison_tokens(text)?;
    let ideographic = tokens.iter().filter(|t| t.ideographic).count();
    let minimum = if ideographic * 2 >= tokens.len() {
        MIN_IDEOGRAPHIC_TOKENS
    } else {
        MIN_WORD_TOKENS
    };
    (tokens.len() >= minimum).then_some(tokens)
}

fn is_remote(segment: &Segment) -> bool {
    Transcript::resolved_attribution(segment).source == AttributionSource::System
        || canonical(&segment.speaker) == "them"
}

fn is_microphone(segment: &Segment) -> bool {
    Transcript::resolved_attribution(segment).source == AttributionSource::Microphone
        || canonical(&segment.speaker) == "me"
}

struct Remote<'a> {
    segment: &'a Segment,
    tokens: Vec<Token>,
}

fn remote_rows(segments: &[Segment]) -> Vec<Remote<'_>> {
    let mut remote: Vec<Remote<'_>> = segments
        .iter()
        .filter(|segment| is_remote(segment) && is_comparable_span(segment))
        .filter_map(|segment| {
            Some(Remote {
                segment,
                tokens: evidence_tokens(&segment.text)?,
            })
        })
        .collect();
    remote.sort_by(|a, b| {
        a.segment
            .start
            .total_cmp(&b.segment.start)
            .then(a.segment.end.total_cmp(&b.segment.end))
    });
    remote
}

fn has_matching_remote(segment: &Segment, tokens: &[Token], remote: &[Remote<'_>]) -> bool {
    let first = remote.partition_point(|r| r.segment.start < segment.start - MAX_BOUNDARY_DRIFT);
    let mut found = false;
    for (scanned, candidate) in remote[first..]
        .iter()
        .take_while(|r| r.segment.start <= segment.start + MAX_BOUNDARY_DRIFT)
        .enumerate()
    {
        // Crowded timing is ambiguous; stop before work can grow with it.
        if scanned >= MAX_CANDIDATES {
            return false;
        }
        if spans_are_aligned(segment, candidate.segment) && candidate.tokens == tokens {
            found = true;
        }
    }
    found
}

/// Microphone rows that match a remote row and could be removed if the audio
/// agrees (`acousticCandidateIndices`).
pub fn acoustic_candidates(segments: &[Segment]) -> HashSet<usize> {
    let remote = remote_rows(segments);
    if remote.is_empty() {
        return HashSet::new();
    }
    segments
        .iter()
        .enumerate()
        .filter(|(_, segment)| {
            is_microphone(segment)
                && is_comparable_span(segment)
                && !has_identity_decision(&Transcript::resolved_attribution(segment))
                && evidence_tokens(&segment.text)
                    .is_some_and(|tokens| has_matching_remote(segment, &tokens, &remote))
        })
        .map(|(index, _)| index)
        .collect()
}

/// Removes a row only when a precisely timed remote row carries the same words
/// at the same time and `verified` says the waveform agrees. A row that matches
/// without that keeps its words and loses the microphone's default identity.
pub fn filter_bleed(segments: &mut Vec<Segment>, verified: &HashSet<usize>) -> BleedReport {
    let mut report = BleedReport::default();
    let matches: HashSet<usize> = {
        let remote = remote_rows(segments);
        if remote.is_empty() {
            return report;
        }
        segments
            .iter()
            .enumerate()
            .filter(|(_, segment)| {
                is_microphone(segment)
                    && is_comparable_span(segment)
                    && evidence_tokens(&segment.text)
                        .is_some_and(|tokens| has_matching_remote(segment, &tokens, &remote))
            })
            .map(|(index, _)| index)
            .collect()
    };
    let mut kept = Vec::with_capacity(segments.len());
    for (index, mut segment) in std::mem::take(segments).into_iter().enumerate() {
        if !matches.contains(&index) {
            kept.push(segment);
            continue;
        }
        let decided = has_identity_decision(&Transcript::resolved_attribution(&segment));
        if !verified.contains(&index) || decided {
            if !decided {
                segment.attribution = Some(suspected_echo());
                report.suspected.insert(index);
            }
            kept.push(segment);
            continue;
        }
        report.removed_segments += 1;
        report.removed_words += evidence_tokens(&segment.text).map_or(0, |tokens| tokens.len());
    }
    *segments = kept;
    report
}

/// Microphone rows that mostly repeat simultaneous remote speech. This needs
/// no exact span or token equality and never deletes text; callers only
/// withhold the microphone's default identity, so a remote participant's words
/// can't become the user's evidence (`nearDuplicateEchoIndices`).
pub fn near_duplicate_echo_indices(segments: &[Segment]) -> HashSet<usize> {
    let mut remote: Vec<(f64, f64, HashSet<String>)> = segments
        .iter()
        .filter(|segment| {
            (Transcript::resolved_attribution(segment).source == AttributionSource::System
                || canonical(&segment.speaker).starts_with("them"))
                && segment.start.is_finite()
                && segment.end.is_finite()
        })
        .filter_map(|segment| {
            let tokens = comparison_tokens(&segment.text)?;
            (!tokens.is_empty()).then(|| {
                (
                    segment.start,
                    segment.end,
                    tokens.into_iter().map(|t| t.word).collect(),
                )
            })
        })
        .collect();
    remote.sort_by(|a, b| a.0.total_cmp(&b.0));
    let mut result = HashSet::new();
    if remote.is_empty() {
        return result;
    }
    for (index, segment) in segments.iter().enumerate() {
        let attribution = Transcript::resolved_attribution(segment);
        if !is_microphone(segment)
            || has_identity_decision(&attribution)
            || attribution.method == AttributionMethod::SuspectedEcho
            || !segment.start.is_finite()
            || !segment.end.is_finite()
        {
            continue;
        }
        let Some(tokens) = evidence_tokens(&segment.text) else {
            continue;
        };
        // Remote spans are bounded by fixed transcription windows, so a
        // generous look-back plus a candidate cap keeps this linear.
        let first = remote.partition_point(|r| r.0 < segment.start - 60.0);
        let echoed = remote[first..]
            .iter()
            .take_while(|r| r.0 <= segment.end + MAX_ECHO_TIME_GAP)
            .take(4 * MAX_CANDIDATES)
            .filter(|r| r.1 >= segment.start - MAX_ECHO_TIME_GAP)
            .any(|r| {
                let covered = tokens.iter().filter(|t| r.2.contains(&t.word)).count();
                covered as f64 / tokens.len() as f64 >= MIN_ECHO_WORD_COVERAGE
            });
        if echoed {
            result.insert(index);
        }
    }
    result
}

impl Transcript {
    /// Likely microphone echo keeps its words and row ids but loses the
    /// microphone's default identity (`markingSuspectedEcho`).
    pub fn marking_suspected_echo(&self) -> Transcript {
        let indices = near_duplicate_echo_indices(&self.segments);
        let mut result = self.clone();
        for index in indices {
            result.segments[index].attribution = Some(suspected_echo());
        }
        result
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const WORDS: &str = "We should move the launch to Thursday";

    fn row(start: f64, end: f64, text: &str, attribution: SpeakerAttribution) -> Segment {
        Segment {
            start,
            end,
            speaker: match attribution.source {
                AttributionSource::Microphone => "me".into(),
                _ => "them".into(),
            },
            text: text.into(),
            confidence: None,
            timing_precision: Some(TimingPrecision::Span),
            attribution: Some(attribution),
        }
    }

    fn mic(start: f64, end: f64, text: &str) -> Segment {
        row(start, end, text, SpeakerAttribution::microphone_user())
    }

    fn remote(start: f64, end: f64, text: &str) -> Segment {
        row(start, end, text, SpeakerAttribution::system_other())
    }

    #[test]
    fn identical_words_alone_only_mark_the_row_as_suspected() {
        let mut rows = vec![remote(10.0, 14.0, WORDS), mic(10.2, 14.1, WORDS)];
        let report = filter_bleed(&mut rows, &HashSet::new());
        assert_eq!(report.removed_segments, 0);
        assert_eq!(report.suspected, HashSet::from([1]));
        assert_eq!(rows.len(), 2);
        let kept = Transcript::resolved_attribution(&rows[1]);
        assert_eq!(kept.identity, SpeakerIdentity::Unresolved);
        assert_eq!(kept.method, AttributionMethod::SuspectedEcho);
        assert_eq!(rows[1].text, WORDS);
    }

    #[test]
    fn waveform_evidence_removes_the_copy() {
        let mut rows = vec![remote(10.0, 14.0, WORDS), mic(10.2, 14.1, WORDS)];
        let report = filter_bleed(&mut rows, &HashSet::from([1]));
        assert_eq!(report.removed_segments, 1);
        assert_eq!(report.removed_words, 7);
        assert_eq!(rows.len(), 1);
    }

    #[test]
    fn a_confirmed_speaker_is_never_removed_or_withdrawn() {
        let confirmed = SpeakerAttribution {
            source: AttributionSource::Microphone,
            identity: SpeakerIdentity::User,
            method: AttributionMethod::Confirmation,
        };
        let mut rows = vec![remote(10.0, 14.0, WORDS), row(10.2, 14.1, WORDS, confirmed)];
        let report = filter_bleed(&mut rows, &HashSet::from([1]));
        assert!(!report.changed());
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[1].attribution, Some(confirmed));
    }

    #[test]
    fn similar_words_or_another_time_are_not_a_match() {
        let mut rows = vec![
            remote(10.0, 14.0, WORDS),
            // A paraphrase while the other side spoke.
            mic(10.2, 14.1, "We should move the launch to Friday"),
            // The same words a minute later, as someone repeating them.
            mic(70.0, 74.0, WORDS),
            // Too few words to be proof of anything.
            mic(10.2, 14.1, "Yes okay sure"),
        ];
        let report = filter_bleed(&mut rows, &HashSet::from([1, 2, 3]));
        assert!(!report.changed());
        assert_eq!(rows.len(), 4);
    }

    #[test]
    fn coarse_timing_or_a_long_block_decides_nothing() {
        let mut coarse = mic(10.2, 14.1, WORDS);
        coarse.timing_precision = Some(TimingPrecision::Coarse);
        let mut rows = vec![remote(10.0, 14.0, WORDS), coarse];
        assert!(!filter_bleed(&mut rows, &HashSet::from([1])).changed());
        let mut rows = vec![remote(10.0, 40.0, WORDS), mic(10.0, 40.0, WORDS)];
        assert!(!filter_bleed(&mut rows, &HashSet::from([1])).changed());
    }

    #[test]
    fn candidates_ignore_a_decided_row() {
        let confirmed = SpeakerAttribution {
            source: AttributionSource::Microphone,
            identity: SpeakerIdentity::User,
            method: AttributionMethod::Profile,
        };
        let rows = vec![
            remote(10.0, 14.0, WORDS),
            mic(10.2, 14.1, WORDS),
            row(10.3, 14.2, WORDS, confirmed),
        ];
        assert_eq!(acoustic_candidates(&rows), HashSet::from([1]));
    }

    #[test]
    fn tokens_treat_contractions_and_ideographs_as_the_swift_does() {
        let words = |text: &str| -> Vec<String> {
            comparison_tokens(text)
                .unwrap()
                .into_iter()
                .map(|t| t.word)
                .collect()
        };
        assert_eq!(
            words("Don’t stop, it's OK!"),
            ["don't", "stop", "it's", "ok"]
        );
        assert_eq!(words("rock' n"), ["rock", "n"]);
        assert_eq!(words("会議abc"), ["会", "議", "abc"]);
        // Few ideographs carry less evidence than the same count of words.
        assert!(evidence_tokens("会議を始め").is_none());
        assert!(evidence_tokens("今日の会議を始めます").is_some());
        assert!(evidence_tokens("three short words").is_none());
        assert!(comparison_tokens(&"x ".repeat(300)).is_none());
    }

    #[test]
    fn notes_evidence_withholds_the_microphone_identity_of_a_near_copy() {
        let transcript = Transcript {
            segments: vec![
                remote(
                    10.0,
                    20.0,
                    "We should move the launch to Thursday because of testing",
                ),
                mic(11.0, 15.0, "move the launch to Thursday"),
                mic(40.0, 44.0, "I disagree Friday works better"),
                mic(11.0, 15.0, "yes"),
            ],
            ..Default::default()
        };
        let marked = transcript.marking_suspected_echo();
        assert_eq!(
            marked.segments[1].attribution.unwrap().method,
            AttributionMethod::SuspectedEcho
        );
        assert_eq!(marked.segments[1].text, transcript.segments[1].text);
        assert_eq!(
            marked.segments[2].attribution.unwrap().method,
            AttributionMethod::Track
        );
        assert_eq!(
            marked.segments[3].attribution.unwrap().method,
            AttributionMethod::Track
        );
    }
}
