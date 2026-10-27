//! Speaker bleed: without headphones the microphone also hears the remote
//! side, so the mic track repeats what the system track says. A microphone
//! segment is dropped when at least 80% of its words appear, in order, in the
//! system-track speech within ±1.5 s of it. Short replies ("yes", "okay")
//! are never compared: both sides plausibly say them.

use lokalbot_core::{AttributionSource, Segment};

use crate::text::folded_words;

pub const BLEED_WINDOW_SECONDS: f64 = 1.5;
pub const BLEED_MIN_SIMILARITY: f64 = 0.8;
const MIN_WORDS: usize = 3;
const MAX_WORDS: usize = 256;

fn source_of(segment: &Segment) -> AttributionSource {
    match &segment.attribution {
        Some(attribution) => attribution.source,
        None if segment.speaker.trim().eq_ignore_ascii_case("me")
            || segment.speaker.starts_with("local") =>
        {
            AttributionSource::Microphone
        }
        None if segment.speaker.starts_with("them") => AttributionSource::System,
        None => AttributionSource::Unknown,
    }
}

/// Removes microphone segments that duplicate overlapping system speech.
/// `segments` must be sorted by start. Returns how many were removed.
pub fn remove_bleed(segments: &mut Vec<Segment>) -> usize {
    let system: Vec<(f64, f64, Vec<String>)> = segments
        .iter()
        .filter(|s| source_of(s) == AttributionSource::System)
        .map(|s| (s.start, s.end, folded_words(&s.text)))
        .collect();
    if system.is_empty() {
        return 0;
    }
    let before = segments.len();
    segments.retain(|segment| {
        if source_of(segment) != AttributionSource::Microphone {
            return true;
        }
        let words = folded_words(&segment.text);
        if words.len() < MIN_WORDS || words.len() > MAX_WORDS {
            return true;
        }
        let low = segment.start - BLEED_WINDOW_SECONDS;
        let high = segment.end + BLEED_WINDOW_SECONDS;
        let nearby: Vec<String> = system
            .iter()
            .filter(|(start, end, _)| *start <= high && *end >= low)
            .flat_map(|(_, _, w)| w.iter().cloned())
            .take(4 * MAX_WORDS)
            .collect();
        if nearby.is_empty() {
            return true;
        }
        similarity(&words, &nearby) < BLEED_MIN_SIMILARITY
    });
    before - segments.len()
}

/// Share of `words` found in order in `reference` (longest common subsequence).
pub fn similarity(words: &[String], reference: &[String]) -> f64 {
    if words.is_empty() {
        return 0.0;
    }
    let mut previous = vec![0usize; reference.len() + 1];
    let mut current = vec![0usize; reference.len() + 1];
    for word in words {
        for (j, other) in reference.iter().enumerate() {
            current[j + 1] = if word == other {
                previous[j] + 1
            } else {
                previous[j + 1].max(current[j])
            };
        }
        std::mem::swap(&mut previous, &mut current);
    }
    previous[reference.len()] as f64 / words.len() as f64
}

#[cfg(test)]
mod tests {
    use super::*;
    use lokalbot_core::{SpeakerAttribution, TimingPrecision};

    fn segment(start: f64, end: f64, text: &str, mic: bool) -> Segment {
        Segment {
            start,
            end,
            speaker: if mic { "local" } else { "them" }.into(),
            text: text.into(),
            confidence: None,
            timing_precision: Some(TimingPrecision::Span),
            attribution: Some(if mic {
                SpeakerAttribution::microphone_user()
            } else {
                SpeakerAttribution::system_other()
            }),
        }
    }

    #[test]
    fn drops_mic_copies_of_remote_speech() {
        let mut segments = vec![
            segment(
                10.0,
                14.0,
                "We should move the launch to Thursday, I think.",
                false,
            ),
            segment(10.3, 14.2, "we should move the launch to thursday", true),
            segment(15.0, 16.0, "Yes, okay.", true),
            segment(15.2, 16.1, "Yes okay", false),
            segment(
                20.0,
                23.0,
                "I disagree, Friday works better for the team.",
                true,
            ),
            segment(30.0, 33.0, "we should move the launch to thursday", true),
        ];
        assert_eq!(remove_bleed(&mut segments), 1);
        assert_eq!(segments.len(), 5);
        assert!(
            segments.iter().any(|s| s.text == "Yes, okay."),
            "short replies stay"
        );
        assert!(
            segments.iter().any(|s| s.start == 30.0),
            "far from the remote copy"
        );
    }

    #[test]
    fn similarity_is_in_order_coverage() {
        let a: Vec<String> = ["a", "b", "c", "d"].map(String::from).to_vec();
        let b: Vec<String> = ["x", "a", "b", "y", "d"].map(String::from).to_vec();
        assert!((similarity(&a, &b) - 0.75).abs() < 1e-9);
    }
}
