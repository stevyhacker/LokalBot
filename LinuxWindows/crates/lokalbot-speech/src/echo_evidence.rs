//! A narrow fallback for near-identical digital echoes
//! (`EchoWaveformEvidence.swift`). Normal room echoes are handled by echo
//! cancellation; words alone can't authorize deleting speech.

use std::collections::HashSet;
use std::path::Path;

use anyhow::Result;
use lokalbot_audio::TrackReader;
use lokalbot_core::speaker_bleed::{acoustic_candidates, has_identity_decision};
use lokalbot_core::voice::TrackClock;
use lokalbot_core::{AttributionSource, Segment, Transcript};

use crate::echo::{correlation, estimate_delay};

const SAMPLE_RATE: u32 = lokalbot_audio::SAMPLE_RATE;
/// An echo's waveform is compared only over this much speech.
const MIN_SECONDS: f64 = 1.0;
const MAX_SECONDS: f64 = 30.0;
/// One second at 16 kHz.
const MIN_SAMPLES: usize = 16_000;
/// The two spans may differ by this many samples.
const MAX_LENGTH_DIFFERENCE: usize = 32;
/// Below this the call track is silent.
const MIN_REFERENCE_POWER: f64 = 0.000_001;
/// This uncalibrated conservative flag means uncertainty, never identity.
const SUSPECTED_CORRELATION: f64 = 0.75;
/// Accepts only near-exact copies, not two people speaking the same words, or
/// a mixture containing a quiet reply.
const IDENTICAL_CORRELATION: f64 = 0.999;
const DECIMATION: usize = 16;
const SEARCH_RADIUS: i64 = 20;

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct EchoAnalysis {
    /// Rows the waveform proves are copies of the call track.
    pub verified: HashSet<usize>,
    /// Rows whose loudness follows the call track. It never deletes speech.
    pub suspected: HashSet<usize>,
}

/// Measures the microphone rows of `segments` against the call track.
pub fn analyze(
    segments: &[Segment],
    mic: &Path,
    system: &Path,
    clock: &TrackClock,
    cancelled: &dyn Fn() -> bool,
) -> Result<EchoAnalysis> {
    let removable = acoustic_candidates(segments);
    let indices: Vec<usize> = segments
        .iter()
        .enumerate()
        .filter(|(_, segment)| is_measured(segment))
        .map(|(index, _)| index)
        .collect();
    let mut result = EchoAnalysis::default();
    if indices.is_empty() {
        return Ok(result);
    }
    let mut mic = SpanReader::open(mic)?;
    let mut system = SpanReader::open(system)?;
    for index in indices {
        if cancelled() {
            break;
        }
        let segment = &segments[index];
        // With clock anchors, a row they can't map isn't compared. Without
        // any, the same second on each track is the best known alignment.
        let reference = match clock {
            TrackClock::Unknown => Some((segment.start, segment.end)),
            known => known
                .reference_range(segment.start, segment.end)
                .map(|range| (range.start, range.end)),
        };
        let Some((from, to)) = reference else {
            continue;
        };
        let (Ok(microphone), Ok(reference)) = (
            mic.samples(segment.start, segment.end),
            system.samples(from, to),
        ) else {
            continue;
        };
        // Acoustic suspicion doesn't require the recognizer to choose identical
        // words, or even the same language.
        if suspected_echo(&microphone, &reference) {
            result.suspected.insert(index);
        }
        if removable.contains(&index) && near_identical(&microphone, &reference) {
            result.verified.insert(index);
        }
    }
    Ok(result)
}

fn is_measured(segment: &Segment) -> bool {
    let attribution = Transcript::resolved_attribution(segment);
    let duration = segment.end - segment.start;
    attribution.source == AttributionSource::Microphone
        && !has_identity_decision(&attribution)
        && segment.start.is_finite()
        && segment.end.is_finite()
        && (MIN_SECONDS..=MAX_SECONDS).contains(&duration)
}

/// The loudness contour tolerates room coloration and playback delay.
pub fn suspected_echo(microphone: &[f32], reference: &[f32]) -> bool {
    if microphone.len() < MIN_SAMPLES
        || microphone.len().abs_diff(reference.len()) > MAX_LENGTH_DIFFERENCE
        || !microphone.iter().all(|s| s.is_finite())
        || !reference.iter().all(|s| s.is_finite())
    {
        return false;
    }
    let power = reference
        .iter()
        .map(|s| f64::from(*s) * f64::from(*s))
        .sum::<f64>()
        / reference.len() as f64;
    power > MIN_REFERENCE_POWER
        && estimate_delay(microphone, reference).correlation >= SUSPECTED_CORRELATION
}

/// Decimated waveform comparison keeps the bounded fallback inexpensive.
pub fn near_identical(microphone: &[f32], reference: &[f32]) -> bool {
    if microphone.len() < MIN_SAMPLES
        || microphone.len().abs_diff(reference.len()) > MAX_LENGTH_DIFFERENCE
    {
        return false;
    }
    let estimate = estimate_delay(microphone, reference);
    if !estimate.is_reliable() {
        return false;
    }
    let decimated = |samples: &[f32]| -> Vec<f64> {
        samples
            .iter()
            .step_by(DECIMATION)
            .map(|s| f64::from(*s))
            .collect()
    };
    let (mic, remote) = (decimated(microphone), decimated(reference));
    let center = estimate.samples / DECIMATION as i64;
    (center - SEARCH_RADIUS..=center + SEARCH_RADIUS)
        .any(|shift| correlation(&mic, &remote, shift) >= IDENTICAL_CORRELATION)
}

/// Reads spans of a track at 16 kHz without holding the track in memory.
struct SpanReader {
    reader: TrackReader,
    rate: u32,
}

impl SpanReader {
    fn open(path: &Path) -> Result<Self> {
        let reader = TrackReader::open(path)?;
        let rate = reader.sample_rate();
        Ok(Self { reader, rate })
    }

    fn samples(&mut self, start: f64, end: f64) -> Result<Vec<f32>> {
        let rate = f64::from(self.rate);
        let first = (start.max(0.0) * rate).round() as u64;
        let frames = ((end - start).max(0.0) * rate).round() as usize;
        self.reader.seek_frame(first)?;
        let mut samples = Vec::with_capacity(frames);
        while samples.len() < frames {
            let read = self
                .reader
                .read_mono(frames - samples.len(), &mut samples)?;
            if read == 0 {
                break;
            }
        }
        Ok(if self.rate == SAMPLE_RATE {
            samples
        } else {
            lokalbot_audio::resample(&samples, self.rate, SAMPLE_RATE)
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use lokalbot_core::{SpeakerAttribution, TimingPrecision};

    /// Speech-like audio: bursts of a tone, so its loudness has a contour.
    fn speech(seconds: f64, pitch: f32) -> Vec<f32> {
        let count = (seconds * SAMPLE_RATE as f64) as usize;
        (0..count)
            .map(|i| {
                let t = i as f32 / SAMPLE_RATE as f32;
                let contour = ((t * 3.1).sin() * (t * 1.3).sin()).abs();
                contour * (t * pitch).sin() * 0.3
            })
            .collect()
    }

    fn delayed(samples: &[f32], by: usize) -> Vec<f32> {
        let mut out = vec![0.0; by];
        out.extend_from_slice(&samples[..samples.len() - by]);
        out
    }

    fn mic_row(start: f64, end: f64, text: &str) -> Segment {
        Segment {
            start,
            end,
            speaker: "me".into(),
            text: text.into(),
            confidence: None,
            timing_precision: Some(TimingPrecision::Span),
            attribution: Some(SpeakerAttribution::microphone_user()),
        }
    }

    fn remote_row(start: f64, end: f64, text: &str) -> Segment {
        Segment {
            speaker: "them".into(),
            attribution: Some(SpeakerAttribution::system_other()),
            ..mic_row(start, end, text)
        }
    }

    #[test]
    fn an_exact_digital_copy_is_near_identical_at_its_delay() {
        let far = speech(4.0, 900.0);
        let copy = delayed(&far, 320);
        assert!(near_identical(&copy, &far));
        assert!(suspected_echo(&copy, &far));
    }

    #[test]
    fn another_voice_saying_the_same_thing_is_not_a_copy() {
        let far = speech(4.0, 900.0);
        let other = speech(4.0, 1_370.0);
        assert!(!near_identical(&other, &far));
    }

    #[test]
    fn a_quiet_reply_mixed_in_keeps_the_copy_from_being_removed() {
        let far = speech(4.0, 900.0);
        let reply = speech(4.0, 2_100.0);
        let mixed: Vec<f32> = delayed(&far, 160)
            .iter()
            .zip(&reply)
            .map(|(a, b)| a + b * 0.3)
            .collect();
        assert!(!near_identical(&mixed, &far));
    }

    #[test]
    fn short_mismatched_or_silent_spans_say_nothing() {
        let far = speech(4.0, 900.0);
        assert!(!suspected_echo(&far[..8_000], &far[..8_000]));
        assert!(!near_identical(&far[..8_000], &far[..8_000]));
        assert!(!suspected_echo(&far, &far[..far.len() - 100]));
        assert!(!near_identical(&far, &far[..far.len() - 100]));
        assert!(!suspected_echo(&far, &vec![0.0; far.len()]));
        let mut broken = far.clone();
        broken[100] = f32::NAN;
        assert!(!suspected_echo(&broken, &far));
    }

    #[test]
    fn tracks_on_disk_verify_only_rows_the_words_also_match() {
        let dir = tempfile::tempdir().unwrap();
        let far = speech(12.0, 900.0);
        let mic = dir.path().join("mic.wav");
        let system = dir.path().join("system.wav");
        lokalbot_audio::write_wav_16k(&mic, &delayed(&far, 320)).unwrap();
        lokalbot_audio::write_wav_16k(&system, &far).unwrap();
        let words = "We should move the launch to Thursday";
        let segments = vec![
            remote_row(1.0, 5.0, words),
            mic_row(1.1, 5.1, words),
            // Follows the call track too, but its words differ: only suspected.
            mic_row(6.0, 10.0, "Completely different words came out here"),
        ];
        let analysis = analyze(
            &segments,
            &mic,
            &system,
            &TrackClock::SharedTimeline,
            &|| false,
        )
        .unwrap();
        assert_eq!(analysis.verified, HashSet::from([1]));
        assert!(analysis.suspected.contains(&1));
        assert!(analysis.suspected.contains(&2));
    }

    #[test]
    fn a_confirmed_or_out_of_range_row_is_not_measured() {
        let mut confirmed = mic_row(1.0, 5.0, "words");
        confirmed.attribution = Some(SpeakerAttribution {
            source: AttributionSource::Microphone,
            identity: lokalbot_core::SpeakerIdentity::User,
            method: lokalbot_core::AttributionMethod::Confirmation,
        });
        assert!(!is_measured(&confirmed));
        assert!(!is_measured(&mic_row(1.0, 1.5, "too short")));
        assert!(!is_measured(&mic_row(1.0, 40.0, "too long")));
        assert!(!is_measured(&remote_row(1.0, 5.0, "the other side")));
        assert!(is_measured(&mic_row(1.0, 5.0, "words")));
    }

    #[test]
    fn a_row_the_anchors_cant_map_is_not_compared() {
        let dir = tempfile::tempdir().unwrap();
        let far = speech(6.0, 900.0);
        let mic = dir.path().join("mic.wav");
        let system = dir.path().join("system.wav");
        lokalbot_audio::write_wav_16k(&mic, &far).unwrap();
        lokalbot_audio::write_wav_16k(&system, &far).unwrap();
        let segments = vec![mic_row(1.0, 5.0, "words spoken here for a while")];
        let timing = lokalbot_core::voice::RecordingAudioTiming {
            version: 1,
            microphone: Vec::new(),
            system: Vec::new(),
            timeline_origin_host_time: None,
        };
        let analysis = analyze(
            &segments,
            &mic,
            &system,
            &TrackClock::Anchored(timing),
            &|| false,
        )
        .unwrap();
        assert_eq!(analysis, EchoAnalysis::default());
        let unanchored =
            analyze(&segments, &mic, &system, &TrackClock::Unknown, &|| false).unwrap();
        assert!(unanchored.suspected.contains(&0));
    }
}
