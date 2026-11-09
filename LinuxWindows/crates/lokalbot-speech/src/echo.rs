//! Subtracts the meeting's remote audio from the microphone copy the models
//! hear (`EchoCanceller.swift`, `EchoCancelledTrack.swift`). The recording
//! stays untouched.
//!
//! With the user on speakers, the remote voice travels through the room back
//! into the microphone. The system track is the very signal that echo was made
//! from, so the echo is predictable where the user's voice is not: an adaptive
//! filter learns the path from the speakers into the microphone, and what its
//! prediction doesn't explain is the user.

use lokalbot_core::model::{EchoReport, EchoStatus};
use lokalbot_core::voice::TrackClock;

use crate::vad::SAMPLE_RATE;

/// 96 ms at 16 kHz: the room's echo tail plus leftover clock drift.
const TAPS: usize = 1_536;
const STEP: f32 = 0.25;
/// Adaptation freezes when the microphone is louder than the reference could
/// explain: that is the user talking, and the filter would learn to cancel them.
const DOUBLE_TALK_MARGIN: f32 = 1.6;
const REFERENCE_PEAK_WINDOW: f32 = 0.05;
const SUPPRESSION_FRAME: f64 = 0.02;
const SUPPRESSION_RATIO: f32 = 2.0;
const SUPPRESSION_GAIN: f32 = 0.03;
const SUPPRESSION_ATTACK: f32 = 0.5;
const SUPPRESSION_RELEASE: f32 = 0.8;
/// Window energy standing for a reference RMS of about 0.01 (-40 dBFS).
const REFERENCE_ACTIVITY_FLOOR: f32 = TAPS as f32 * 1e-4;

const CHUNK_SECONDS: f64 = 30.0;
/// A marginal result is more safely transcribed from the untouched track.
const MINIMUM_ACCEPTED_REDUCTION_DB: f64 = 6.0;
const RELIABLE_CORRELATION: f64 = 0.55;
const FRAME_SECONDS: f64 = 0.01;
const SAFETY_FRAMES: i64 = 1;
const MAXIMUM_LEAD: f64 = 0.5;
const MAXIMUM_LAG: f64 = 0.1;

/// Normalized LMS rather than a fixed filter, because the path isn't fixed:
/// the capture clocks drift and the room changes.
pub struct EchoCanceller {
    weights: Vec<f32>,
    /// Every sample twice, so the latest `TAPS` are always one contiguous slice.
    history: Vec<f32>,
    head: usize,
    window_energy: f32,
    reference_peak: f32,
    peak_decay: f32,
    suppression_gain: f32,
    samples_since_refresh: usize,
    microphone_energy: f64,
    residual_energy: f64,
}

impl Default for EchoCanceller {
    fn default() -> Self {
        let window = (REFERENCE_PEAK_WINDOW * SAMPLE_RATE as f32).max(1.0);
        Self {
            weights: vec![0.0; TAPS],
            history: vec![0.0; 2 * TAPS],
            head: 0,
            window_energy: 0.0,
            reference_peak: 0.0,
            peak_decay: (-1.0 / window).exp(),
            suppression_gain: 1.0,
            samples_since_refresh: 0,
            microphone_energy: 0.0,
            residual_energy: 0.0,
        }
    }
}

impl EchoCanceller {
    /// `microphone` and `reference` must be aligned and equally long.
    pub fn process(
        &mut self,
        microphone: &[f32],
        reference: &[f32],
        cancelled: &dyn Fn() -> bool,
    ) -> Option<Vec<f32>> {
        debug_assert_eq!(microphone.len(), reference.len());
        let mut output = vec![0f32; microphone.len()];
        let mut predictions = vec![0f32; microphone.len()];
        let mut active = vec![false; microphone.len()];
        for n in 0..microphone.len() {
            if n % 4_096 == 0 && cancelled() {
                return None;
            }
            self.head = if self.head == 0 {
                TAPS - 1
            } else {
                self.head - 1
            };
            let x = reference[n];
            // The slot being overwritten holds the sample leaving the window.
            let leaving = self.history[self.head];
            self.history[self.head] = x;
            self.history[self.head + TAPS] = x;
            self.window_energy += x * x - leaving * leaving;
            self.reference_peak = x.abs().max(self.reference_peak * self.peak_decay);

            let window = &self.history[self.head..self.head + TAPS];
            let predicted: f32 = window
                .iter()
                .zip(&self.weights)
                .map(|(sample, weight)| sample * weight)
                .sum();
            let d = microphone[n];
            let error = d - predicted;
            output[n] = error;
            predictions[n] = predicted;
            active[n] = self.window_energy > REFERENCE_ACTIVITY_FLOOR;

            self.samples_since_refresh += 1;
            if self.samples_since_refresh >= TAPS {
                // Rounding accumulates over tens of millions of samples.
                self.window_energy = window.iter().map(|s| s * s).sum();
                self.samples_since_refresh = 0;
            }

            if d.abs() > DOUBLE_TALK_MARGIN * self.reference_peak || self.window_energy <= 1e-6 {
                continue;
            }
            let scale = STEP * error / self.window_energy;
            for (weight, sample) in self.weights.iter_mut().zip(window) {
                *weight += scale * sample;
            }
        }
        let suppressed = self.suppress_residual(output, &predictions);
        // Only score where there was echo to remove.
        for n in 0..suppressed.len() {
            if active[n] {
                self.microphone_energy += f64::from(microphone[n]) * f64::from(microphone[n]);
                self.residual_energy += f64::from(suppressed[n]) * f64::from(suppressed[n]);
            }
        }
        Some(suppressed)
    }

    /// Pushes frames that were nothing but echo down to the noise floor.
    /// Subtraction alone leaves the echo about 13 dB down, which speech models
    /// still transcribe; gating to silence made them hallucinate on the edges.
    fn suppress_residual(&mut self, mut residual: Vec<f32>, predictions: &[f32]) -> Vec<f32> {
        let frame = ((SUPPRESSION_FRAME * SAMPLE_RATE as f64) as usize).max(1);
        let mut index = 0;
        while index < residual.len() {
            let end = (index + frame).min(residual.len());
            let predicted_energy: f32 = predictions[index..end].iter().map(|s| s * s).sum();
            let residual_energy: f32 = residual[index..end].iter().map(|s| s * s).sum();
            let echo_dominates = predicted_energy > REFERENCE_ACTIVITY_FLOOR
                && predicted_energy > SUPPRESSION_RATIO * residual_energy;
            let target = if echo_dominates {
                SUPPRESSION_GAIN
            } else {
                1.0
            };
            let smoothing = if target < self.suppression_gain {
                SUPPRESSION_ATTACK
            } else {
                SUPPRESSION_RELEASE
            };
            self.suppression_gain = smoothing * self.suppression_gain + (1.0 - smoothing) * target;
            if self.suppression_gain < 0.999 {
                for sample in &mut residual[index..end] {
                    *sample *= self.suppression_gain;
                }
            }
            index = end;
        }
        residual
    }

    /// How much of the microphone's energy was removed. Zero is the correct
    /// answer when the user wears headphones.
    pub fn reduction_db(&self) -> f64 {
        if self.microphone_energy <= 0.0 || self.residual_energy <= 0.0 {
            return 0.0;
        }
        10.0 * (self.microphone_energy / self.residual_energy).log10()
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub(crate) struct DelayEstimate {
    pub samples: i64,
    pub correlation: f64,
}

impl DelayEstimate {
    pub(crate) fn is_reliable(&self) -> bool {
        self.correlation.is_finite() && self.correlation >= RELIABLE_CORRELATION
    }
}

/// Mean-removed loudness contour, one value per frame.
fn envelope(samples: &[f32], frame: usize) -> Vec<f64> {
    if frame == 0 || samples.len() < frame {
        return Vec::new();
    }
    let values: Vec<f64> = samples
        .chunks_exact(frame)
        .map(|chunk| {
            let sum: f64 = chunk.iter().map(|s| f64::from(*s) * f64::from(*s)).sum();
            (sum / frame as f64).sqrt()
        })
        .collect();
    let mean = values.iter().sum::<f64>() / values.len() as f64;
    values.into_iter().map(|value| value - mean).collect()
}

pub(crate) fn correlation(mic: &[f64], reference: &[f64], shift: i64) -> f64 {
    let start = shift.max(0);
    let end = (mic.len() as i64).min(reference.len() as i64 + shift);
    if end - start <= 8 {
        return f64::NEG_INFINITY;
    }
    let (mut dot, mut mic_energy, mut reference_energy) = (0.0, 0.0, 0.0);
    for i in start..end {
        let m = mic[i as usize];
        let r = reference[(i - shift) as usize];
        dot += m * r;
        mic_energy += m * m;
        reference_energy += r * r;
    }
    if mic_energy <= 0.0 || reference_energy <= 0.0 {
        return f64::NEG_INFINITY;
    }
    dot / (mic_energy * reference_energy).sqrt()
}

/// How far the microphone lags the system track. Correlating loudness
/// contours: the delay survives codecs and room colouring. A causal filter
/// can't reach forwards, so the estimate is nudged early by a frame.
pub(crate) fn estimate_delay(microphone: &[f32], reference: &[f32]) -> DelayEstimate {
    let frame = ((FRAME_SECONDS * SAMPLE_RATE as f64) as usize).max(1);
    let mic = envelope(microphone, frame);
    let far = envelope(reference, frame);
    if mic.len() <= 8 || far.len() <= 8 {
        return DelayEstimate {
            samples: 0,
            correlation: 0.0,
        };
    }
    let lead = (MAXIMUM_LEAD / FRAME_SECONDS) as i64;
    let lag = (MAXIMUM_LAG / FRAME_SECONDS) as i64;
    let mut best = (f64::NEG_INFINITY, 0);
    for shift in -lag..=lead {
        let score = correlation(&mic, &far, shift);
        if score > best.0 {
            best = (score, shift);
        }
    }
    if best.0 <= 0.0 {
        return DelayEstimate {
            samples: 0,
            correlation: 0.0,
        };
    }
    DelayEstimate {
        samples: (best.1 - SAFETY_FRAMES) * frame as i64,
        correlation: best.0,
    }
}

/// Corrects a small clock-rate difference. A missing reference stays silence.
fn resampled(samples: &[f32], count: usize) -> Vec<f32> {
    if count == 0 {
        return Vec::new();
    }
    if samples.len() <= 1 || count == 1 {
        return vec![samples.first().copied().unwrap_or(0.0); count];
    }
    (0..count)
        .map(|index| {
            let position = index as f64 * (samples.len() - 1) as f64 / (count - 1) as f64;
            let left = position as usize;
            let right = (left + 1).min(samples.len() - 1);
            let fraction = (position - left as f64) as f32;
            samples[left] * (1.0 - fraction) + samples[right] * fraction
        })
        .collect()
}

/// The result of cleaning a microphone track.
#[derive(Clone, Debug, PartialEq)]
pub struct EchoRemoval {
    /// The cleaned copy, when it passed; the bleed gate is used otherwise.
    pub cleaned: Option<Vec<f32>>,
    pub report: EchoReport,
}

fn no_cleanup(status: EchoStatus) -> EchoRemoval {
    EchoRemoval {
        cleaned: None,
        report: EchoReport {
            status,
            reduction_db: None,
            delay_seconds: None,
            alignment_verified: false,
        },
    }
}

/// Echo removal is off for this transcription.
pub fn echo_disabled() -> EchoReport {
    no_cleanup(EchoStatus::Disabled).report
}

/// No system track to subtract.
pub fn echo_no_reference() -> EchoReport {
    no_cleanup(EchoStatus::NoReference).report
}

/// Removal could not finish, so the original speech was preserved.
pub fn echo_failed() -> EchoReport {
    no_cleanup(EchoStatus::Failed).report
}

/// Cleans `microphone` in 30 s windows, keeping a chunk only when it removed
/// enough. A known capture gap is stronger evidence than an acoustic guess:
/// with a clock, a chunk it can't map is left as recorded. `None` when cancelled.
pub fn remove_echo(
    microphone: &[f32],
    system: &[f32],
    clock: &TrackClock,
    cancelled: &dyn Fn() -> bool,
) -> Option<EchoRemoval> {
    let rate = SAMPLE_RATE as f64;
    let duration = microphone.len() as f64 / rate;
    if duration.min(system.len() as f64 / rate) <= 1.0 {
        return Some(no_cleanup(EchoStatus::Failed));
    }
    let at = |seconds: f64, len: usize| ((seconds * rate).round() as usize).min(len);
    let mut output = Vec::with_capacity(microphone.len());
    let mut position = 0.0;
    let mut accepted = 0.0;
    let mut weighted = 0.0;
    let mut delays = Vec::new();
    let mut verified = clock.is_known();
    while position < duration {
        if cancelled() {
            return None;
        }
        let end = (position + CHUNK_SECONDS)
            .min(duration)
            .min(clock.next_boundary(position).unwrap_or(duration));
        let mic = &microphone[at(position, microphone.len())..at(end, microphone.len())];
        if mic.is_empty() {
            break;
        }
        let mapped = clock.reference_range(position, end);
        let (from, to) = mapped.map_or((position, end), |r| (r.start, r.end));
        let mut can_align = !clock.is_known() || mapped.is_some();
        let remote: &[f32] = if can_align {
            &system[at(from, system.len())..at(to, system.len())]
        } else {
            &[]
        };
        // Don't stretch a missing tail or truncated reference over speech.
        if (remote.len() as f64 - (to - from) * rate).abs() > 256.0 {
            can_align = false;
        }
        let reference = resampled(remote, mic.len());
        let estimate = estimate_delay(mic, &reference);
        let mut kept = false;
        if can_align && !remote.is_empty() && estimate.is_reliable() {
            let shifted: Vec<f32> = (0..mic.len() as i64)
                .map(|index| {
                    let source = index - estimate.samples;
                    if (0..reference.len() as i64).contains(&source) {
                        reference[source as usize]
                    } else {
                        0.0
                    }
                })
                .collect();
            let mut canceller = EchoCanceller::default();
            let candidate = canceller.process(mic, &shifted, cancelled)?;
            let reduction = canceller.reduction_db();
            if reduction.is_finite() && reduction >= MINIMUM_ACCEPTED_REDUCTION_DB {
                output.extend_from_slice(&candidate);
                accepted += end - position;
                weighted += reduction * (end - position);
                delays.push(position - from + estimate.samples as f64 / rate);
                kept = true;
            }
        }
        if !kept {
            verified = false;
            output.extend_from_slice(mic);
        }
        position = end;
    }
    let reduction = if accepted > 0.0 {
        weighted / accepted
    } else {
        0.0
    };
    delays.sort_by(f64::total_cmp);
    let delay = delays.get(delays.len() / 2).copied().unwrap_or(0.0);
    let usable =
        reduction.is_finite() && reduction >= MINIMUM_ACCEPTED_REDUCTION_DB && accepted > 0.0;
    log::info!(
        "speech: echo cancellation delay={:.0}ms erle={reduction:.1}dB accepted={accepted:.0}s usable={usable}",
        delay * 1000.0
    );
    Some(if usable {
        EchoRemoval {
            cleaned: Some(output),
            report: EchoReport {
                status: EchoStatus::Applied,
                reduction_db: Some(reduction),
                delay_seconds: Some(delay),
                alignment_verified: verified,
            },
        }
    } else {
        EchoRemoval {
            cleaned: None,
            report: EchoReport {
                status: EchoStatus::Uncertain,
                reduction_db: Some(reduction),
                delay_seconds: Some(delay),
                alignment_verified: false,
            },
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Speech-like noise bursts: repeatable and with a loudness contour.
    fn voice(seed: u64, seconds: f64, offset: usize) -> Vec<f32> {
        let count = (seconds * SAMPLE_RATE as f64) as usize;
        let mut state = seed;
        (0..count)
            .map(|i| {
                state = state
                    .wrapping_mul(6_364_136_223_846_793_005)
                    .wrapping_add(1);
                let noise = ((state >> 33) as f32 / (1u64 << 31) as f32) - 0.5;
                let syllable = ((i + offset) / 2_400) % 3;
                let gain = if syllable == 0 { 0.02 } else { 0.5 };
                noise * gain
            })
            .collect()
    }

    fn rms(samples: &[f32]) -> f32 {
        (samples.iter().map(|s| s * s).sum::<f32>() / samples.len().max(1) as f32).sqrt()
    }

    fn with_echo(remote: &[f32], local: &[f32], delay: usize, gain: f32) -> Vec<f32> {
        remote
            .iter()
            .enumerate()
            .map(|(i, _)| {
                let echo = if i >= delay {
                    remote[i - delay] * gain
                } else {
                    0.0
                };
                echo + local.get(i).copied().unwrap_or(0.0)
            })
            .collect()
    }

    #[test]
    fn removes_the_far_side_and_keeps_the_user() {
        let remote = voice(7, 20.0, 0);
        let delay = 1_600;
        let mic = with_echo(&remote, &[], delay, 0.3);
        let clean = remove_echo(&mic, &remote, &TrackClock::SharedTimeline, &|| false).unwrap();
        assert_eq!(
            clean.report.status,
            EchoStatus::Applied,
            "{:?}",
            clean.report
        );
        assert!(clean.report.reduction_db.unwrap() >= MINIMUM_ACCEPTED_REDUCTION_DB);
        assert!(clean.report.alignment_verified);
        let output = clean.cleaned.unwrap();
        assert_eq!(output.len(), mic.len());
        let tail = output.len() / 2;
        assert!(rms(&output[tail..]) < rms(&mic[tail..]) * 0.2);
    }

    #[test]
    fn the_users_own_voice_survives_while_the_far_side_is_quiet() {
        let mut remote = voice(7, 20.0, 0);
        let start = 10 * SAMPLE_RATE;
        remote[start..].fill(0.0);
        let mut local = vec![0f32; remote.len()];
        let own = voice(99, 6.0, 40);
        local[start + 8_000..start + 8_000 + own.len()].copy_from_slice(&own);
        let mic = with_echo(&remote, &local, 800, 0.3);
        let clean = remove_echo(&mic, &remote, &TrackClock::SharedTimeline, &|| false).unwrap();
        if let Some(output) = clean.cleaned {
            let range = start + 8_000..start + 8_000 + own.len();
            assert!(
                rms(&output[range.clone()]) > rms(&own) * 0.8,
                "{} of {}",
                rms(&output[range]),
                rms(&own)
            );
        }
    }

    #[test]
    fn headphones_leave_the_track_as_recorded() {
        let remote = voice(7, 12.0, 0);
        let mic = voice(21, 12.0, 700);
        let clean = remove_echo(&mic, &remote, &TrackClock::SharedTimeline, &|| false).unwrap();
        assert_eq!(clean.report.status, EchoStatus::Uncertain);
        assert!(clean.cleaned.is_none());
        assert!(!clean.report.alignment_verified);
    }

    #[test]
    fn no_clock_means_never_verified() {
        let remote = voice(7, 20.0, 0);
        let mic = with_echo(&remote, &[], 1_600, 0.3);
        let clean = remove_echo(&mic, &remote, &TrackClock::Unknown, &|| false).unwrap();
        assert_eq!(clean.report.status, EchoStatus::Applied);
        assert!(!clean.report.alignment_verified);
    }

    #[test]
    fn delay_estimate_follows_the_lag() {
        let remote = voice(7, 10.0, 0);
        let mic = with_echo(&remote, &[], 2_336, 0.5);
        let estimate = estimate_delay(&mic, &remote);
        assert!(estimate.is_reliable());
        assert!((estimate.samples - 2_336).abs() <= 320, "{estimate:?}");
    }

    #[test]
    fn cancelling_stops_the_work() {
        let remote = voice(7, 5.0, 0);
        assert!(remove_echo(&remote, &remote, &TrackClock::Unknown, &|| true).is_none());
    }
}
