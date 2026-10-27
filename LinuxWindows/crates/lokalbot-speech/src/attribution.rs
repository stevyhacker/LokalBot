//! Speaker labels and attribution (`AttributedTrackTranscriber`).
//!
//! Diarization partitions the audio before recognition: the track timeline is
//! cut at every turn boundary, so text is never divided across speakers and
//! overlapping voices never inherit a majority label. The microphone gives
//! `local`, `local N`, `local unclear`; system audio gives `them`, `them N`,
//! `them unclear`.

use lokalbot_core::{AttributionMethod, AttributionSource, SpeakerAttribution, SpeakerIdentity};

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

#[cfg(test)]
mod tests {
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
