//! `TranscriptSanitizer`: removes only objectively pathological ASR output —
//! extreme repetition, rows that merely repeat the vocabulary prompt, and
//! precisely timed rows too fast to be speech. Ordinary emphasis is kept.

use lokalbot_core::{Segment, TimingPrecision, Transcript};

use crate::text::{PromptEcho, normalized_text};

/// A precisely timed row with at least this many words at this rate is not
/// speech (a forced aligner packing invented words into a near-silent gap).
const IMPLAUSIBLE_MIN_WORDS: usize = 8;
const IMPLAUSIBLE_WORDS_PER_SECOND: f64 = 10.0;

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct SanitizeReport {
    pub changed_segments: usize,
    pub removed_segments: usize,
    pub removed_words: usize,
}

impl SanitizeReport {
    pub fn changed(&self) -> bool {
        self.changed_segments > 0 || self.removed_segments > 0
    }
}

struct Word {
    normalized: String,
    end: usize,
}

fn words(text: &str) -> Vec<Word> {
    let mut out = Vec::new();
    let mut start: Option<usize> = None;
    for (index, c) in text.char_indices() {
        let in_word = c.is_alphanumeric() || c == '\'' || c == '’';
        match (in_word, start) {
            (true, None) => start = Some(index),
            (false, Some(s)) => {
                out.push(Word {
                    normalized: text[s..index].to_lowercase(),
                    end: index,
                });
                start = None;
            }
            _ => {}
        }
    }
    if let Some(s) = start {
        out.push(Word {
            normalized: text[s..].to_lowercase(),
            end: text.len(),
        });
    }
    out
}

fn is_bleed_filter_safe(precision: Option<TimingPrecision>) -> bool {
    matches!(
        precision,
        Some(TimingPrecision::Span | TimingPrecision::Token)
    )
}

/// Sanitizes `transcript` in place. `prompt` is the vocabulary prompt the
/// transcript was made with, when known.
pub fn sanitize(transcript: &mut Transcript, prompt: Option<&str>) -> SanitizeReport {
    let echo = PromptEcho::new(prompt);
    let mut report = SanitizeReport::default();
    let mut kept: Vec<Segment> = Vec::with_capacity(transcript.segments.len());
    for segment in transcript.segments.drain(..) {
        let original = normalized_text(&segment.text);
        if original.is_empty() {
            kept.push(segment);
            continue;
        }
        let character_cleaned = collapse_extreme_character_runs(&original);
        let original_words = words(&character_cleaned);
        if echo.as_ref().is_some_and(|e| e.matches(&original)) {
            report.removed_segments += 1;
            report.removed_words += original_words.len();
            continue;
        }
        let mut final_text = character_cleaned.clone();
        let mut remaining = original_words.len();
        let duration = (segment.end - segment.start).max(0.25);
        let rate = original_words.len() as f64 / duration;
        if original_words.len() >= 32 && rate >= 6.0 {
            let (collapsed, removed) =
                collapse_repeated_cycles(&original_words, &character_cleaned);
            let impossible_rate = original_words.len() >= 80 && rate >= 12.0;
            let dominated_by_loop = removed as f64 / original_words.len() as f64 >= 0.8;
            if removed > 0 && (impossible_rate || dominated_by_loop) {
                final_text = collapsed;
                report.removed_words += removed;
                remaining -= removed;
            }
        }
        if is_bleed_filter_safe(segment.timing_precision)
            && remaining >= IMPLAUSIBLE_MIN_WORDS
            && remaining as f64 / duration >= IMPLAUSIBLE_WORDS_PER_SECOND
        {
            report.removed_segments += 1;
            report.removed_words += remaining;
            continue;
        }
        let final_text = normalized_text(&final_text);
        if final_text == original {
            kept.push(segment);
            continue;
        }
        report.changed_segments += 1;
        kept.push(Segment {
            text: final_text,
            ..segment
        });
    }
    transcript.segments = kept;
    report
}

/// Collapses runs of 8 or more identical letters or punctuation marks to 3;
/// digits are never collapsed (amounts, identifiers).
fn collapse_extreme_character_runs(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut run: Vec<char> = Vec::new();
    let flush = |run: &mut Vec<char>, out: &mut String| {
        if let Some(&first) = run.first() {
            let collapse = run.len() >= 8 && (first.is_alphabetic() || is_punctuation(first));
            let keep = if collapse { 3 } else { run.len() };
            out.extend(run.iter().take(keep));
            run.clear();
        }
    };
    for c in text.chars() {
        if let Some(&first) = run.first()
            && !first.to_lowercase().eq(c.to_lowercase())
        {
            flush(&mut run, &mut out);
        }
        run.push(c);
    }
    flush(&mut run, &mut out);
    out
}

fn is_punctuation(c: char) -> bool {
    c.is_ascii_punctuation()
        || matches!(
            c,
            '…' | '。'
                | '，'
                | '、'
                | '！'
                | '？'
                | '¿'
                | '¡'
                | '«'
                | '»'
                | '“'
                | '”'
                | '‘'
                | '’'
        )
}

/// Deletes repeated word cycles (period ≤ 32, ≥ 4 repetitions, ≥ 24 redundant
/// words, or a single word ≥ 8 times), keeping two cycles. Only the repeated
/// span is removed so unrelated text keeps its exact form.
fn collapse_repeated_cycles(words: &[Word], text: &str) -> (String, usize) {
    if words.len() < 8 {
        return (text.to_string(), 0);
    }
    let mut removals: Vec<(usize, usize)> = Vec::new();
    let mut removed = 0;
    let mut index = 0;
    while index < words.len() {
        match longest_loop(words, index) {
            Some((period, repetitions)) => {
                let span = period * repetitions;
                let kept = period * 2;
                removals.push((words[index + kept - 1].end, words[index + span - 1].end));
                removed += span - kept;
                index += span;
            }
            None => index += 1,
        }
    }
    let mut output = text.to_string();
    for (start, end) in removals.into_iter().rev() {
        output.replace_range(start..end, "");
    }
    (output, removed)
}

fn longest_loop(words: &[Word], start: usize) -> Option<(usize, usize)> {
    let maximum_period = 32.min((words.len() - start) / 4);
    let mut best: Option<(usize, usize)> = None;
    for period in 1..=maximum_period {
        let mut repetitions = 1;
        while start + (repetitions + 1) * period <= words.len()
            && (0..period).all(|o| {
                words[start + o].normalized == words[start + repetitions * period + o].normalized
            })
        {
            repetitions += 1;
        }
        let redundant = period * repetitions.saturating_sub(2);
        let long_run = period == 1 && repetitions >= 8;
        if repetitions < 4 || !(redundant >= 24 || long_run) {
            continue;
        }
        let span = period * repetitions;
        let better = match best {
            None => true,
            Some((bp, br)) => span > bp * br || (span == bp * br && period < bp),
        };
        if better {
            best = Some((period, repetitions));
        }
    }
    best
}

#[cfg(test)]
mod tests {
    use super::*;
    use lokalbot_core::{AttributionMethod, SpeakerAttribution};

    fn segment(start: f64, end: f64, text: &str, precision: Option<TimingPrecision>) -> Segment {
        Segment {
            start,
            end,
            speaker: "them".into(),
            text: text.into(),
            confidence: None,
            timing_precision: precision,
            attribution: Some(SpeakerAttribution {
                method: AttributionMethod::Track,
                ..SpeakerAttribution::system_other()
            }),
        }
    }

    fn transcript(segments: Vec<Segment>) -> Transcript {
        Transcript {
            segments,
            engine: "test".into(),
            ..Default::default()
        }
    }

    #[test]
    fn collapses_character_runs_but_not_digits() {
        assert_eq!(
            collapse_extreme_character_runs("Nooooooooo!!!!!!!!!"),
            "Nooo!!!"
        );
        assert_eq!(
            collapse_extreme_character_runs("call 5555555555"),
            "call 5555555555"
        );
        assert_eq!(collapse_extreme_character_runs("soooo good"), "soooo good");
    }

    #[test]
    fn collapses_filler_loops_that_dominate_a_row() {
        let loop_text = vec!["thank you"; 40].join(" ");
        let mut t = transcript(vec![segment(
            0.0,
            10.0,
            &loop_text,
            Some(TimingPrecision::Span),
        )]);
        let report = sanitize(&mut t, None);
        assert_eq!(t.segments[0].text, "thank you thank you");
        assert_eq!(report.removed_words, 76);
    }

    #[test]
    fn keeps_normal_emphasis() {
        let text = "no no no no I really mean it, we cannot ship this on Friday because the tests are failing and the release notes are not written yet either";
        let mut t = transcript(vec![segment(0.0, 12.0, text, Some(TimingPrecision::Span))]);
        let report = sanitize(&mut t, None);
        assert!(!report.changed());
        assert_eq!(t.segments[0].text, text);
    }

    #[test]
    fn drops_prompt_echoes_and_impossible_rows() {
        let prompt = "Mila Novak, Orion Launch, Acme.";
        let mut t = transcript(vec![
            segment(
                0.0,
                0.4,
                "Mila Novak, Orion Launch, Acme.",
                Some(TimingPrecision::Span),
            ),
            segment(
                1.0,
                1.5,
                "one two three four five six seven eight nine",
                Some(TimingPrecision::Token),
            ),
            segment(
                2.0,
                2.5,
                "one two three four five six seven eight nine",
                Some(TimingPrecision::Coarse),
            ),
            segment(
                3.0,
                4.0,
                "  Real   speech <|en|> ",
                Some(TimingPrecision::Span),
            ),
        ]);
        let report = sanitize(&mut t, Some(prompt));
        assert_eq!(report.removed_segments, 2);
        assert_eq!(t.segments.len(), 2);
        assert_eq!(normalized_text(&t.segments[1].text), "Real speech");
    }
}
