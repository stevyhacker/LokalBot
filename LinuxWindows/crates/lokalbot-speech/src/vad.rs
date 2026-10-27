//! Speech regions (`SpeechActivity` + `SpeechActivitySpans.swift`): Silero VAD
//! finds speech, regions are capped in length on the time axis, and each span
//! is decoded on its own so it keeps real start and end times.

use std::path::{Path, PathBuf};

use anyhow::{Result, anyhow};
use lokalbot_core::TimingPrecision;
use sherpa_onnx::{SileroVadModelConfig, VadModelConfig, VoiceActivityDetector};

pub const SAMPLE_RATE: usize = 16_000;
/// Silero processes 512-sample windows at 16 kHz.
const WINDOW: usize = 512;
/// Longest region the detector emits (`SpeechActivity`: at most 14 s).
const MAX_SPEECH_SECONDS: f32 = 14.0;
/// Audio kept around each region so word onsets and endings are not clipped.
const PADDING_SECONDS: f64 = 0.15;

/// A run of speech on the track timeline.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Span {
    pub start: f64,
    pub end: f64,
    pub precision: TimingPrecision,
}

impl Span {
    pub fn duration(&self) -> f64 {
        self.end - self.start
    }

    pub fn samples<'a>(&self, track: &'a [f32]) -> &'a [f32] {
        let from = ((self.start * SAMPLE_RATE as f64).round() as usize).min(track.len());
        let to = ((self.end * SAMPLE_RATE as f64).round() as usize).clamp(from, track.len());
        &track[from..to]
    }
}

pub struct Vad {
    model: Option<PathBuf>,
    threads: i32,
}

impl Vad {
    /// `model` is `silero_vad.onnx`; `None` uses an energy detector instead.
    pub fn new(model: Option<&Path>, threads: usize) -> Self {
        Self {
            model: model.map(Path::to_path_buf),
            threads: threads.clamp(1, 4) as i32,
        }
    }

    /// Speech regions of 16 kHz `samples`, padded slightly, in seconds.
    pub fn speech(&self, samples: &[f32]) -> Result<Vec<Span>> {
        let raw = match &self.model {
            Some(model) => silero_regions(model, self.threads, samples)?,
            None => energy_regions(samples),
        };
        Ok(pad(&raw, samples.len() as f64 / SAMPLE_RATE as f64))
    }
}

fn silero_regions(model: &Path, threads: i32, samples: &[f32]) -> Result<Vec<(f64, f64)>> {
    let config = VadModelConfig {
        silero_vad: SileroVadModelConfig {
            model: Some(model.to_string_lossy().into_owned()),
            threshold: 0.45,
            min_silence_duration: 0.4,
            min_speech_duration: 0.25,
            window_size: WINDOW as i32,
            max_speech_duration: MAX_SPEECH_SECONDS,
        },
        sample_rate: SAMPLE_RATE as i32,
        num_threads: threads,
        provider: Some("cpu".into()),
        debug: false,
        ..Default::default()
    };
    let detector = VoiceActivityDetector::create(&config, MAX_SPEECH_SECONDS + 16.0)
        .ok_or_else(|| anyhow!("could not load the voice activity model"))?;
    let mut regions = Vec::new();
    let drain = |detector: &VoiceActivityDetector, regions: &mut Vec<(f64, f64)>| {
        while let Some(segment) = detector.front() {
            let start = segment.start().max(0) as f64 / SAMPLE_RATE as f64;
            let end = start + segment.n().max(0) as f64 / SAMPLE_RATE as f64;
            if end > start {
                regions.push((start, end));
            }
            drop(segment);
            detector.pop();
        }
    };
    for window in samples.chunks(WINDOW) {
        if window.len() == WINDOW {
            detector.accept_waveform(window);
        } else {
            let mut padded = window.to_vec();
            padded.resize(WINDOW, 0.0);
            detector.accept_waveform(&padded);
        }
        drain(&detector, &mut regions);
    }
    detector.flush();
    drain(&detector, &mut regions);
    Ok(regions)
}

/// Fallback when the VAD model is missing: 30 ms frames above an adaptive
/// noise floor, joined across pauses shorter than 0.4 s.
fn energy_regions(samples: &[f32]) -> Vec<(f64, f64)> {
    const FRAME: usize = SAMPLE_RATE * 30 / 1000;
    let energies: Vec<f32> = samples
        .chunks(FRAME)
        .map(|f| (f.iter().map(|s| s * s).sum::<f32>() / f.len().max(1) as f32).sqrt())
        .collect();
    if energies.is_empty() {
        return Vec::new();
    }
    let mut sorted = energies.clone();
    sorted.sort_by(f32::total_cmp);
    let floor = sorted[sorted.len() / 10];
    let threshold = (floor * 4.0).max(0.006);
    let frame_seconds = FRAME as f64 / SAMPLE_RATE as f64;
    let mut regions: Vec<(f64, f64)> = Vec::new();
    for (i, &energy) in energies.iter().enumerate() {
        if energy < threshold {
            continue;
        }
        let (start, end) = (i as f64 * frame_seconds, (i + 1) as f64 * frame_seconds);
        match regions.last_mut() {
            Some(last) if start - last.1 < 0.4 && end - last.0 <= MAX_SPEECH_SECONDS as f64 => {
                last.1 = end
            }
            _ => regions.push((start, end)),
        }
    }
    regions.retain(|(s, e)| e - s >= 0.25);
    regions
}

/// Widens each region by [`PADDING_SECONDS`] without crossing its neighbours.
fn pad(regions: &[(f64, f64)], duration: f64) -> Vec<Span> {
    let mut spans = Vec::with_capacity(regions.len());
    for (i, &(start, end)) in regions.iter().enumerate() {
        let floor = if i == 0 {
            0.0
        } else {
            (regions[i - 1].1 + start) / 2.0
        };
        let ceiling = regions
            .get(i + 1)
            .map_or(duration, |next| (end + next.0) / 2.0);
        let start = (start - PADDING_SECONDS).max(floor).max(0.0);
        let end = (end + PADDING_SECONDS).min(ceiling).min(duration);
        if end > start {
            spans.push(Span {
                start,
                end,
                precision: TimingPrecision::Span,
            });
        }
    }
    spans
}

/// Total speech, in seconds.
pub fn speech_seconds(spans: &[Span]) -> f64 {
    spans.iter().map(Span::duration).sum()
}

/// `SpeechActivity.split`: cuts every span into pieces of at most `max` seconds.
pub fn split(spans: &[Span], max: f64) -> Vec<Span> {
    let max = max.max(1.0 / SAMPLE_RATE as f64);
    let mut out = Vec::new();
    for span in spans {
        let mut cursor = span.start;
        while cursor < span.end {
            let next = (cursor + max).min(span.end);
            out.push(Span {
                start: cursor,
                end: next,
                precision: span.precision,
            });
            cursor = next;
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn padding_never_crosses_neighbours() {
        let spans = pad(&[(1.0, 2.0), (2.1, 3.0)], 3.05);
        assert_eq!(spans.len(), 2);
        assert!((spans[0].start - 0.85).abs() < 1e-9);
        assert!((spans[0].end - 2.05).abs() < 1e-9);
        assert!((spans[1].start - 2.05).abs() < 1e-9);
        assert!((spans[1].end - 3.05).abs() < 1e-9);
    }

    #[test]
    fn splits_long_spans() {
        let spans = split(
            &[Span {
                start: 0.0,
                end: 32.0,
                precision: TimingPrecision::Span,
            }],
            15.0,
        );
        assert_eq!(
            spans.iter().map(|s| (s.start, s.end)).collect::<Vec<_>>(),
            vec![(0.0, 15.0), (15.0, 30.0), (30.0, 32.0)]
        );
    }

    #[test]
    fn energy_fallback_finds_a_burst() {
        let mut samples = vec![0.0005f32; SAMPLE_RATE * 3];
        for (i, s) in samples[SAMPLE_RATE..SAMPLE_RATE * 2].iter_mut().enumerate() {
            *s = (i as f32 * 0.05).sin() * 0.2;
        }
        let spans = Vad::new(None, 1).speech(&samples).unwrap();
        assert_eq!(spans.len(), 1);
        assert!(
            (spans[0].start - 0.85).abs() < 0.05 && (spans[0].end - 2.15).abs() < 0.05,
            "{spans:?}"
        );
    }
}
