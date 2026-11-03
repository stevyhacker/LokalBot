//! Which voice samples may count (`AttributedTrackTranscriber.turns/samples`,
//! `SpeakerMicrophoneEvidence.swift`). A microphone is an audio source, not a
//! person: its samples count only when nothing from the call could have
//! reached it.

use std::collections::{BTreeMap, BTreeSet};

use crate::model::{AttributionMethod, AttributionSource, Transcript};

use super::{AudioTurn, TrackClock, TurnAnchor, VoiceSample, union};

/// A transcript label backing `range`: one label, all of it from speaker
/// separation, covering at least `coverage` of the range.
fn supported_speaker(
    range: &TurnAnchor,
    transcript: &Transcript,
    source: AttributionSource,
    coverage: f64,
) -> Option<String> {
    if !range.is_valid() {
        return None;
    }
    let overlaps: Vec<_> = transcript
        .segments
        .iter()
        .map(|s| (s, Transcript::resolved_attribution(s)))
        .filter(|(s, a)| a.source == source && s.start < range.end && s.end > range.start)
        .collect();
    let labels: BTreeSet<&str> = overlaps.iter().map(|(s, _)| s.speaker.as_str()).collect();
    let [label] = labels.into_iter().collect::<Vec<_>>()[..] else {
        return None;
    };
    if overlaps
        .iter()
        .any(|(_, a)| a.method != AttributionMethod::Diarization)
    {
        return None;
    }
    let covered: f64 = union(overlaps.iter().map(|(s, _)| TurnAnchor {
        start: s.start,
        end: s.end,
    }))
    .iter()
    .map(|anchor| anchor.overlap(range))
    .sum();
    (covered >= range.duration() * coverage).then(|| label.to_string())
}

/// Raw diarizer turns as turns of transcript labels. A turn another voice
/// overlaps is left out.
pub fn label_turns(
    raw: &[(String, TurnAnchor)],
    transcript: &Transcript,
    source: AttributionSource,
) -> Vec<AudioTurn> {
    raw.iter()
        .filter(|(speaker, range)| {
            range.is_valid()
                && !raw.iter().any(|(other, r)| {
                    other != speaker && r.start < range.end && r.end > range.start
                })
        })
        .filter_map(|(_, range)| {
            let label = supported_speaker(range, transcript, source, 0.95)?;
            Some(AudioTurn {
                speaker: label,
                range: *range,
                source: Some(source),
            })
        })
        .collect()
}

/// Samples renamed to the transcript's labels. Call speech pauses between
/// sentences, and the voice model hears only the speaker's own frames, so a
/// pause is not another person.
pub fn label_samples(
    samples: &[VoiceSample],
    transcript: &Transcript,
    source: AttributionSource,
) -> Vec<VoiceSample> {
    let coverage = if source == AttributionSource::System {
        0.6
    } else {
        0.95
    };
    samples
        .iter()
        .filter(|s| s.source.is_none() || s.source == Some(source))
        .filter_map(|sample| {
            let label = supported_speaker(&sample.range, transcript, source, coverage)?;
            let mut sample = sample.clone();
            sample.speaker = label;
            sample.source = Some(source);
            Some(sample)
        })
        .collect()
}

/// What `select_microphone_samples` kept, and why each microphone sample
/// was or was not kept.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct MicrophoneEvidence {
    pub samples: Vec<VoiceSample>,
    pub counts: BTreeMap<String, u32>,
}

/// Microphone samples pass the echo checks; call samples pass through.
/// `remote_pcm` reads the call track's 16 kHz samples for a range.
pub fn select_microphone_samples(
    samples: &[VoiceSample],
    transcript: &Transcript,
    turns: &[AudioTurn],
    has_remote_track: bool,
    clock: &TrackClock,
    remote_pcm: &mut dyn FnMut(f64, f64) -> Option<Vec<f32>>,
) -> MicrophoneEvidence {
    let has_remote = has_remote_track
        || transcript
            .segments
            .iter()
            .any(|s| Transcript::resolved_attribution(s).source == AttributionSource::System);
    let remote_turns: Vec<TurnAnchor> = turns
        .iter()
        .filter(|t| t.resolved_source() == AttributionSource::System)
        .map(|t| t.range)
        .chain(
            transcript
                .segments
                .iter()
                .filter(|s| Transcript::resolved_attribution(s).source == AttributionSource::System)
                .map(|s| TurnAnchor {
                    start: s.start,
                    end: s.end,
                }),
        )
        .collect();
    let verified_echo_removal = transcript
        .echo_report
        .as_ref()
        .is_some_and(|r| r.alignment_verified);
    let mut result = MicrophoneEvidence::default();
    for sample in samples {
        if sample.source != Some(AttributionSource::Microphone) {
            result.samples.push(sample.clone());
            continue;
        }
        let duration = sample.range.duration();
        let reason = if !sample.range.is_valid() || !(3.0..=30.0).contains(&duration) {
            "invalidSample"
        } else if transcript.segments.iter().any(|segment| {
            let attribution = Transcript::resolved_attribution(segment);
            attribution.source == AttributionSource::Microphone
                && segment.start < sample.range.end
                && segment.end > sample.range.start
                && (Transcript::canonical_speaker_key(&segment.speaker) != sample.speaker
                    || !matches!(
                        attribution.method,
                        AttributionMethod::Diarization
                            | AttributionMethod::Confirmation
                            | AttributionMethod::Profile
                    ))
        }) {
            "ambiguousMicrophone"
        } else if !has_remote || verified_echo_removal {
            result.samples.push(sample.clone());
            if has_remote {
                "verifiedEchoRemoval"
            } else {
                "microphoneOnly"
            }
        } else if let Some(reference) = clock
            .reference_range((sample.range.start - 0.5).max(0.0), sample.range.end + 0.25)
            .filter(|_| has_remote_track)
        {
            // The padding includes plausible playback-to-microphone delay. A
            // diarizer miss is not silence; verify the actual waveform too.
            if remote_turns.iter().any(|t| t.overlap(&reference) > 0.0) {
                "remoteSpeech"
            } else if remote_pcm(reference.start, reference.end)
                .is_some_and(|pcm| reference_is_quiet(&pcm, reference.duration()))
            {
                result.samples.push(sample.clone());
                "quietReference"
            } else {
                "remoteAudioOrMissingSamples"
            }
        } else {
            "missingClockOrReference"
        };
        *result.counts.entry(reason.to_string()).or_insert(0) += 1;
    }
    result
}

/// Tests short windows as well as the peak, so a brief remote syllable cannot
/// disappear in the mean of a long silent interval.
pub(crate) fn reference_is_quiet(samples: &[f32], expected_duration: f64) -> bool {
    if !expected_duration.is_finite()
        || expected_duration < 3.0
        || samples.is_empty()
        || (samples.len() as f64 - expected_duration * 16_000.0).abs() > 32.0
        || samples.iter().any(|s| !s.is_finite())
    {
        return false;
    }
    samples.chunks(320).all(|window| {
        let power: f64 = window
            .iter()
            .map(|s| f64::from(*s) * f64::from(*s))
            .sum::<f64>()
            / window.len() as f64;
        power <= 0.000_000_01 && window.iter().all(|s| s.abs() <= 0.001)
    })
}
