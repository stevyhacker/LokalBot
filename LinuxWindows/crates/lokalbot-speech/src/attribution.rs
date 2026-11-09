//! Speaker labels and attribution (`AttributedTrackTranscriber`).
//!
//! Diarization partitions the audio before recognition: the track timeline is
//! cut at every turn boundary, so text is never divided across speakers and
//! overlapping voices never inherit a majority label. The microphone gives
//! `local`, `local N`, `local unclear`; system audio gives `them`, `them N`,
//! `them unclear`. A server that times words is the exception: its clips span turns,
//! and [`attribute_words`] splits its text at the words where the speaker changes.

use lokalbot_core::remote_transcription::TimedWord;
use lokalbot_core::{
    AttributionMethod, AttributionSource, Segment, SpeakerAttribution, SpeakerIdentity,
    TimingPrecision,
};

/// A diarizer turn on the track timeline.
#[derive(Clone, Debug, PartialEq)]
pub struct Turn {
    pub start: f64,
    pub end: f64,
    pub speaker: i32,
}

/// A stretch of the timeline with one label.
#[derive(Clone, Debug, PartialEq)]
pub struct Region {
    pub start: f64,
    pub end: f64,
    pub speaker: String,
    pub attribution: SpeakerAttribution,
}

pub fn prefix(source: AttributionSource) -> &'static str {
    match source {
        AttributionSource::Microphone => "local",
        _ => "them",
    }
}

/// `SpeakerAttribution.applyingMicrophoneDefault`: microphone track,
/// diarization and legacy speech follow "My microphone is me".
pub fn apply_microphone_default(
    attribution: SpeakerAttribution,
    microphone_is_user: bool,
) -> SpeakerAttribution {
    let follows = attribution.source == AttributionSource::Microphone
        && matches!(
            attribution.method,
            AttributionMethod::Track | AttributionMethod::Diarization | AttributionMethod::Legacy
        );
    if !follows {
        return attribution;
    }
    SpeakerAttribution {
        identity: if microphone_is_user {
            SpeakerIdentity::User
        } else {
            SpeakerIdentity::Unresolved
        },
        ..attribution
    }
}

/// Attribution of undiarized speech on a track.
pub fn track_attribution(
    source: AttributionSource,
    microphone_is_user: bool,
) -> SpeakerAttribution {
    let identity = if source == AttributionSource::System {
        SpeakerIdentity::Other
    } else {
        SpeakerIdentity::Unresolved
    };
    apply_microphone_default(
        SpeakerAttribution {
            source,
            identity,
            method: AttributionMethod::Track,
        },
        microphone_is_user,
    )
}

/// The timeline of a track cut at every turn boundary: one active speaker
/// gives `prefix N` (numbered by first appearance), overlap gives
/// `prefix unclear`, no turn keeps the track label. Equal neighbours merge.
pub fn regions(
    duration: f64,
    turns: &[Turn],
    source: AttributionSource,
    microphone_is_user: bool,
) -> Vec<Region> {
    if !duration.is_finite() || duration <= 0.0 {
        return Vec::new();
    }
    let prefix = prefix(source);
    let mut valid: Vec<&Turn> = turns
        .iter()
        .filter(|t| {
            t.start.is_finite()
                && t.end.is_finite()
                && t.end > t.start
                && t.end > 0.0
                && t.start < duration
        })
        .collect();
    valid.sort_by(|a, b| a.start.total_cmp(&b.start));
    let mut order: Vec<i32> = Vec::new();
    for turn in &valid {
        if !order.contains(&turn.speaker) {
            order.push(turn.speaker);
        }
    }
    let mut bounds: Vec<f64> = vec![0.0, duration];
    for turn in &valid {
        bounds.push(turn.start.max(0.0));
        bounds.push(turn.end.min(duration));
    }
    bounds.sort_by(f64::total_cmp);
    bounds.dedup();
    let mut out: Vec<Region> = Vec::new();
    for pair in bounds.windows(2) {
        let (start, end) = (pair[0], pair[1]);
        if end <= start {
            continue;
        }
        let mut speakers: Vec<i32> = valid
            .iter()
            .filter(|t| t.start < end && t.end > start)
            .map(|t| t.speaker)
            .collect();
        speakers.sort_unstable();
        speakers.dedup();
        let overlapping = speakers.len() > 1;
        let speaker = match speakers.as_slice() {
            [one] => format!(
                "{prefix} {}",
                order.iter().position(|s| s == one).unwrap_or(0) + 1
            ),
            [] => prefix.to_string(),
            _ => format!("{prefix} unclear"),
        };
        let method = if overlapping {
            AttributionMethod::OverlappingSpeech
        } else if speakers.is_empty() {
            AttributionMethod::Track
        } else {
            AttributionMethod::Diarization
        };
        let identity = if source == AttributionSource::System && !overlapping {
            SpeakerIdentity::Other
        } else {
            SpeakerIdentity::Unresolved
        };
        let attribution = apply_microphone_default(
            SpeakerAttribution {
                source,
                identity,
                method,
            },
            microphone_is_user,
        );
        match out.last_mut() {
            Some(last)
                if last.speaker == speaker
                    && last.attribution == attribution
                    && (last.end - start).abs() < 1e-9 =>
            {
                last.end = end;
            }
            _ => out.push(Region {
                start,
                end,
                speaker,
                attribution,
            }),
        }
    }
    out
}

/// Renumbers `prefix N` labels by first appearance among the segments that
/// carry text, so a voice that never said anything (residual bleed, a cough)
/// does not leave the first speaker labelled `local 2`.
pub fn renumber_speakers(segments: &mut [lokalbot_core::Segment]) {
    let mut order: Vec<String> = Vec::new();
    let mut sorted: Vec<usize> = (0..segments.len()).collect();
    sorted.sort_by(|&a, &b| segments[a].start.total_cmp(&segments[b].start));
    for &index in &sorted {
        let label = &segments[index].speaker;
        if numbered(label).is_some() && !order.contains(label) {
            order.push(label.clone());
        }
    }
    for segment in segments.iter_mut() {
        if let (Some(prefix), Some(position)) = (
            numbered(&segment.speaker),
            order.iter().position(|l| *l == segment.speaker),
        ) {
            segment.speaker = format!("{prefix} {}", position + 1);
        }
    }
}

/// The prefix of a `local N` / `them N` label.
fn numbered(label: &str) -> Option<&'static str> {
    let (prefix, number) = label.split_once(' ')?;
    let prefix = match prefix {
        "local" => "local",
        "them" => "them",
        _ => return None,
    };
    number.parse::<u32>().ok().map(|_| prefix)
}

/// Words this close to a speaker turn take that speaker (`wordGapTolerance`).
/// Diarizer turn edges and word edges disagree by a few hundred milliseconds.
const WORD_GAP_TOLERANCE: f64 = 1.0;
/// A pause this long between words starts a new segment (`wordPauseSplit`).
const WORD_PAUSE_SPLIT: f64 = 0.75;
/// No segment grows past this (`maxSegmentSeconds`).
const MAX_SEGMENT_SECONDS: f64 = 15.0;

/// One clip's text, with its words on the track's timeline.
#[derive(Clone, Debug, PartialEq)]
pub struct AlignedSegment {
    pub start: f64,
    pub end: f64,
    pub text: String,
    pub precision: TimingPrecision,
    /// Empty: the clip keeps one speaker, chosen at its midpoint.
    pub words: Vec<TimedWord>,
}

#[derive(Clone, Debug, PartialEq)]
struct WordSpeaker {
    id: Option<i32>,
    label: String,
    attribution: SpeakerAttribution,
}

struct SpeakerPiece {
    start: f64,
    end: f64,
    speaker: WordSpeaker,
    text: String,
    precision: TimingPrecision,
}

/// Where each word begins in `text`, matched in order on its letters and digits.
/// `None` when a word can't be found, so the caller keeps the clip whole rather
/// than guessing a cut (`wordStarts`).
fn word_starts(words: &[TimedWord], text: &str) -> Option<Vec<usize>> {
    let mut cursor = 0;
    let mut starts = Vec::with_capacity(words.len());
    for word in words {
        let key = word.text.split_whitespace().next().unwrap_or(&word.text);
        let core = key.trim_matches(|c: char| !c.is_alphanumeric());
        if core.is_empty() {
            return None;
        }
        let at = cursor + text[cursor..].find(core)?;
        starts.push(at);
        cursor = at + core.len();
    }
    Some(starts)
}

/// Splits each clip where its words change speaker, pause, or would outgrow
/// [`MAX_SEGMENT_SECONDS`] (`AttributedTrackTranscriber.attribute`). One active turn
/// names the speaker, overlapping turns are unclear, and words away from every turn
/// keep the track label. Text is cut from the clip, never divided proportionally.
/// Speaker pieces then widen to the edges of their own turns, without crossing a
/// neighbour, so acoustic turns stay supported.
pub fn attribute_words(
    aligned: &[AlignedSegment],
    duration: f64,
    turns: &[Turn],
    source: AttributionSource,
    microphone_is_user: bool,
    (lower, upper): (f64, f64),
) -> Vec<Segment> {
    let prefix = prefix(source);
    let mut valid: Vec<&Turn> = turns
        .iter()
        .filter(|t| {
            t.start.is_finite()
                && t.end.is_finite()
                && t.end > t.start
                && t.end > 0.0
                && t.start < duration
        })
        .collect();
    valid.sort_by(|a, b| a.start.total_cmp(&b.start));
    let mut order: Vec<i32> = Vec::new();
    for turn in &valid {
        if !order.contains(&turn.speaker) {
            order.push(turn.speaker);
        }
    }
    let track_identity = if source == AttributionSource::System {
        SpeakerIdentity::Other
    } else {
        SpeakerIdentity::Unresolved
    };
    let attribution = |identity, method| {
        apply_microphone_default(
            SpeakerAttribution {
                source,
                identity,
                method,
            },
            microphone_is_user,
        )
    };
    let distance = |turn: &Turn, time: f64| (turn.start - time).max(time - turn.end);
    let speaker_at = |time: f64| -> WordSpeaker {
        let mut active: Vec<i32> = valid
            .iter()
            .filter(|t| t.start <= time && time < t.end)
            .map(|t| t.speaker)
            .collect();
        active.sort_unstable();
        active.dedup();
        if active.is_empty()
            && let Some(nearest) = valid
                .iter()
                .min_by(|a, b| distance(a, time).total_cmp(&distance(b, time)))
            && distance(nearest, time) <= WORD_GAP_TOLERANCE
        {
            active.push(nearest.speaker);
        }
        match active.as_slice() {
            [one] => WordSpeaker {
                id: Some(*one),
                label: format!(
                    "{prefix} {}",
                    order.iter().position(|s| s == one).unwrap_or(0) + 1
                ),
                attribution: attribution(track_identity, AttributionMethod::Diarization),
            },
            [] => WordSpeaker {
                id: None,
                label: prefix.to_string(),
                attribution: attribution(track_identity, AttributionMethod::Track),
            },
            _ => WordSpeaker {
                id: None,
                label: format!("{prefix} unclear"),
                attribution: attribution(
                    SpeakerIdentity::Unresolved,
                    AttributionMethod::OverlappingSpeech,
                ),
            },
        }
    };

    let mut pieces: Vec<SpeakerPiece> = Vec::new();
    for item in aligned {
        let text = item.text.as_str();
        let starts = (!item.words.is_empty())
            .then(|| word_starts(&item.words, text))
            .flatten();
        let Some(starts) = starts else {
            let middle = (item.start + item.end) / 2.0;
            if middle >= lower && middle <= upper {
                pieces.push(SpeakerPiece {
                    start: item.start,
                    end: item.end,
                    speaker: speaker_at(middle),
                    text: text.to_string(),
                    precision: item.precision,
                });
            }
            continue;
        };
        let mut run: Option<(usize, usize, WordSpeaker)> = None;
        let mut close = |run: &mut Option<(usize, usize, WordSpeaker)>, next: Option<usize>| {
            let Some((first, last, speaker)) = run.take() else {
                return;
            };
            let from = if first == 0 { 0 } else { starts[first] };
            let to = next.map_or(text.len(), |next| starts[next]);
            let clamp = |time: f64| time.max(item.start).min(item.end);
            let mut start = clamp(item.words[first].start);
            let mut end = clamp(item.words[last].end);
            if end <= start {
                end = item.end.min(start + 0.01);
                start = start.min(item.start.max(end - 0.01));
            }
            pieces.push(SpeakerPiece {
                start,
                end,
                speaker,
                text: text[from..to].to_string(),
                precision: TimingPrecision::Token,
            });
        };
        for (index, word) in item.words.iter().enumerate() {
            let middle = (word.start + word.end) / 2.0;
            if middle < lower || middle > upper {
                close(&mut run, Some(index));
                continue;
            }
            let who = speaker_at(middle);
            match &mut run {
                Some((first, last, speaker))
                    if *speaker == who
                        && word.start - item.words[*last].end < WORD_PAUSE_SPLIT
                        && word.end - item.words[*first].start <= MAX_SEGMENT_SECONDS =>
                {
                    *last = index;
                }
                _ => {
                    close(&mut run, Some(index));
                    run = Some((index, index, who));
                }
            }
        }
        close(&mut run, None);
    }

    pieces.sort_by(|a, b| a.start.total_cmp(&b.start));
    for index in 0..pieces.len() {
        let Some(id) = pieces[index].speaker.id else {
            continue;
        };
        let floor = if index > 0 {
            pieces[index - 1].end
        } else {
            lower
        };
        let ceiling = pieces.get(index + 1).map_or(upper, |next| next.start);
        let (mut start, mut end) = (pieces[index].start, pieces[index].end);
        for turn in &valid {
            if turn.speaker == id && turn.start < end && turn.end > start {
                start = floor.max(start.min(turn.start));
                end = ceiling.min(end.max(turn.end));
            }
        }
        if end > start {
            pieces[index].start = start;
            pieces[index].end = end;
        }
    }
    pieces
        .into_iter()
        .filter_map(|piece| {
            let text = piece.text.trim();
            (!text.is_empty() && piece.end > piece.start).then(|| Segment {
                start: piece.start,
                end: piece.end,
                speaker: piece.speaker.label,
                text: text.to_string(),
                confidence: None,
                timing_precision: Some(piece.precision),
                attribution: Some(piece.speaker.attribution),
            })
        })
        .collect()
}

#[cfg(test)]
mod tests {
    fn word(text: &str, start: f64, end: f64) -> TimedWord {
        TimedWord {
            text: text.into(),
            start,
            end,
        }
    }

    fn clip(start: f64, end: f64, text: &str, words: Vec<TimedWord>) -> AlignedSegment {
        AlignedSegment {
            start,
            end,
            text: text.into(),
            precision: TimingPrecision::Span,
            words,
        }
    }

    #[test]
    fn a_clip_splits_at_the_word_where_the_speaker_changes() {
        let turns = [
            Turn {
                start: 0.0,
                end: 2.0,
                speaker: 0,
            },
            Turn {
                start: 2.0,
                end: 4.0,
                speaker: 1,
            },
        ];
        let aligned = [clip(
            0.0,
            4.0,
            "Are you there? Yes, I am.",
            vec![
                word("Are", 0.1, 0.4),
                word("you", 0.5, 0.8),
                word("there?", 0.9, 1.4),
                word("Yes,", 2.2, 2.6),
                word("I", 2.7, 2.8),
                word("am.", 2.9, 3.3),
            ],
        )];
        let segments = attribute_words(
            &aligned,
            4.0,
            &turns,
            AttributionSource::System,
            false,
            (0.0, 4.0),
        );
        assert_eq!(segments.len(), 2);
        assert_eq!(segments[0].text, "Are you there?");
        assert_eq!(segments[0].speaker, "them 1");
        assert_eq!(segments[1].text, "Yes, I am.");
        assert_eq!(segments[1].speaker, "them 2");
        // Pieces widen to the edges of their own turns.
        assert_eq!(segments[0].start, 0.0);
        assert_eq!(segments[1].end, 4.0);
        assert_eq!(segments[0].timing_precision, Some(TimingPrecision::Token));
        let attribution = segments[0].attribution.unwrap();
        assert_eq!(attribution.method, AttributionMethod::Diarization);
        assert_eq!(attribution.identity, SpeakerIdentity::Other);
    }

    #[test]
    fn a_long_pause_starts_a_new_segment_for_the_same_speaker() {
        let turns = [Turn {
            start: 0.0,
            end: 10.0,
            speaker: 0,
        }];
        let aligned = [clip(
            0.0,
            10.0,
            "One two",
            vec![word("One", 1.0, 1.5), word("two", 5.0, 5.5)],
        )];
        let segments = attribute_words(
            &aligned,
            10.0,
            &turns,
            AttributionSource::Microphone,
            true,
            (0.0, 10.0),
        );
        assert_eq!(segments.len(), 2);
        assert_eq!(segments[0].speaker, "local 1");
        assert_eq!(segments[1].text, "two");
        let attribution = segments[0].attribution.unwrap();
        assert_eq!(attribution.identity, SpeakerIdentity::User);
        // Widening stops at the neighbour.
        assert!(segments[0].end <= segments[1].start);
    }

    #[test]
    fn a_clip_without_usable_word_times_keeps_one_speaker_at_its_midpoint() {
        let turns = [
            Turn {
                start: 0.0,
                end: 1.0,
                speaker: 0,
            },
            Turn {
                start: 1.0,
                end: 9.0,
                speaker: 1,
            },
        ];
        let untimed = [clip(0.0, 8.0, "Whole clip", Vec::new())];
        let segments = attribute_words(
            &untimed,
            9.0,
            &turns,
            AttributionSource::System,
            false,
            (0.0, 9.0),
        );
        assert_eq!(segments.len(), 1);
        assert_eq!(segments[0].speaker, "them 2");
        assert_eq!(segments[0].timing_precision, Some(TimingPrecision::Span));
        // A word the text doesn't hold: no guessing at a cut.
        let wrong = [clip(
            0.0,
            8.0,
            "Whole clip",
            vec![word("elsewhere", 0.0, 1.0)],
        )];
        let segments = attribute_words(
            &wrong,
            9.0,
            &turns,
            AttributionSource::System,
            false,
            (0.0, 9.0),
        );
        assert_eq!(segments[0].text, "Whole clip");
    }

    #[test]
    fn overlap_is_unclear_and_words_far_from_any_turn_keep_the_track_label() {
        let turns = [
            Turn {
                start: 0.0,
                end: 3.0,
                speaker: 0,
            },
            Turn {
                start: 1.0,
                end: 3.0,
                speaker: 1,
            },
        ];
        let aligned = [clip(
            0.0,
            20.0,
            "both alone",
            vec![word("both", 2.0, 2.5), word("alone", 10.0, 10.5)],
        )];
        let segments = attribute_words(
            &aligned,
            20.0,
            &turns,
            AttributionSource::System,
            false,
            (0.0, 20.0),
        );
        assert_eq!(segments[0].speaker, "them unclear");
        assert_eq!(
            segments[0].attribution.unwrap().method,
            AttributionMethod::OverlappingSpeech
        );
        assert_eq!(segments[1].speaker, "them");
        assert_eq!(
            segments[1].attribution.unwrap().method,
            AttributionMethod::Track
        );
    }

    #[test]
    fn words_outside_the_reviewed_range_are_left_out() {
        let turns = [Turn {
            start: 0.0,
            end: 10.0,
            speaker: 0,
        }];
        let aligned = [clip(
            0.0,
            10.0,
            "before after",
            vec![word("before", 1.0, 1.5), word("after", 6.0, 6.5)],
        )];
        let segments = attribute_words(
            &aligned,
            10.0,
            &turns,
            AttributionSource::System,
            false,
            (5.0, 10.0),
        );
        assert_eq!(segments.len(), 1);
        assert_eq!(segments[0].text, "after");
    }

    use super::*;

    fn turn(start: f64, end: f64, speaker: i32) -> Turn {
        Turn {
            start,
            end,
            speaker,
        }
    }

    #[test]
    fn labels_follow_first_appearance_and_overlap_is_unclear() {
        let turns = [turn(1.0, 4.0, 7), turn(3.5, 6.0, 2), turn(6.5, 8.0, 7)];
        let r = regions(10.0, &turns, AttributionSource::System, true);
        let labels: Vec<(&str, f64, f64)> = r
            .iter()
            .map(|r| (r.speaker.as_str(), r.start, r.end))
            .collect();
        assert_eq!(
            labels,
            vec![
                ("them", 0.0, 1.0),
                ("them 1", 1.0, 3.5),
                ("them unclear", 3.5, 4.0),
                ("them 2", 4.0, 6.0),
                ("them", 6.0, 6.5),
                ("them 1", 6.5, 8.0),
                ("them", 8.0, 10.0),
            ]
        );
        assert_eq!(r[1].attribution.identity, SpeakerIdentity::Other);
        assert_eq!(r[1].attribution.method, AttributionMethod::Diarization);
        assert_eq!(
            r[2].attribution.method,
            AttributionMethod::OverlappingSpeech
        );
        assert_eq!(r[2].attribution.identity, SpeakerIdentity::Unresolved);
        assert_eq!(r[0].attribution.method, AttributionMethod::Track);
    }

    #[test]
    fn renumbering_skips_silent_voices() {
        let segment = |start: f64, speaker: &str| lokalbot_core::Segment {
            start,
            end: start + 1.0,
            speaker: speaker.into(),
            text: "hello".into(),
            confidence: None,
            timing_precision: None,
            attribution: None,
        };
        let mut segments = vec![
            segment(5.0, "local 3"),
            segment(1.0, "local 2"),
            segment(3.0, "local unclear"),
            segment(7.0, "local 2"),
        ];
        renumber_speakers(&mut segments);
        let labels: Vec<&str> = segments.iter().map(|s| s.speaker.as_str()).collect();
        assert_eq!(
            labels,
            vec!["local 2", "local 1", "local unclear", "local 1"]
        );
    }

    #[test]
    fn microphone_default_applies_to_mic_turns() {
        let r = regions(
            5.0,
            &[turn(0.0, 5.0, 0)],
            AttributionSource::Microphone,
            true,
        );
        assert_eq!(r.len(), 1);
        assert_eq!(r[0].speaker, "local 1");
        assert_eq!(r[0].attribution.identity, SpeakerIdentity::User);
        let r = regions(
            5.0,
            &[turn(0.0, 5.0, 0)],
            AttributionSource::Microphone,
            false,
        );
        assert_eq!(r[0].attribution.identity, SpeakerIdentity::Unresolved);
        assert_eq!(
            track_attribution(AttributionSource::Microphone, true),
            SpeakerAttribution::microphone_user()
        );
        assert_eq!(
            track_attribution(AttributionSource::System, true),
            SpeakerAttribution::system_other()
        );
    }
}
