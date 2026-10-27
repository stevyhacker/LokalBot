//! Speaker bleed before recognition: without headphones the microphone picks
//! up the remote side a few tens of milliseconds after the system track
//! carries it. Mic frames whose energy is explained by the delayed system
//! signal are attenuated by 30 dB in the copy the models hear (the recording
//! is untouched), like the residual suppressor in macOS's `EchoCanceller`.
//! Nothing is gated unless the two envelopes show a clear, consistent bleed.

/// 20 ms frames at 16 kHz.
const FRAME: usize = 320;
/// Speaker-to-microphone delays searched: 0–400 ms.
const MAX_LAG_FRAMES: usize = 20;
/// Log-envelope correlation (over remote-speech frames) needed before any gating.
const MIN_CORRELATION: f64 = 0.5;
/// Bleed weaker than −40 dB is left alone.
const MIN_GAIN: f64 = 0.01;
/// A frame is bleed when the mic is at most this far above the predicted bleed (+8 dB).
const MARGIN: f64 = 2.5;
const ATTENUATION: f32 = 0.03;
/// Frames kept around detected local speech so word edges survive.
const KEEP_AROUND: usize = 3;

/// Per-frame gains for the microphone track.
#[derive(Clone, Debug, PartialEq)]
pub struct BleedGate {
    pub delay_ms: u32,
    pub gain_db: f64,
    gains: Vec<f32>,
}

/// Frame RMS of 16 kHz audio (20 ms frames).
pub fn envelope(samples: &[f32]) -> Vec<f64> {
    samples
        .chunks(FRAME)
        .map(|f| {
            (f.iter().map(|&s| (s as f64) * (s as f64)).sum::<f64>() / f.len().max(1) as f64).sqrt()
        })
        .collect()
}

fn percentile(values: &mut [f64], p: f64) -> f64 {
    if values.is_empty() {
        return 0.0;
    }
    values.sort_by(f64::total_cmp);
    values[((values.len() - 1) as f64 * p).round() as usize]
}

fn correlation(a: &[f64], b: &[f64]) -> f64 {
    let n = a.len().min(b.len());
    if n < 10 {
        return 0.0;
    }
    let (ma, mb) = (
        a[..n].iter().sum::<f64>() / n as f64,
        b[..n].iter().sum::<f64>() / n as f64,
    );
    let (mut cov, mut va, mut vb) = (0.0, 0.0, 0.0);
    for i in 0..n {
        let (x, y) = (a[i] - ma, b[i] - mb);
        cov += x * y;
        va += x * x;
        vb += y * y;
    }
    if va <= 0.0 || vb <= 0.0 {
        0.0
    } else {
        cov / (va * vb).sqrt()
    }
}

impl BleedGate {
    /// Analyses both tracks (16 kHz, same timeline); `None` when no bleed is evident.
    pub fn detect(mic: &[f32], system: &[f32]) -> Option<BleedGate> {
        Self::from_envelopes(&envelope(mic), &envelope(system))
    }

    /// [`BleedGate::detect`] from precomputed [`envelope`]s.
    pub fn from_envelopes(m: &[f64], s: &[f64]) -> Option<BleedGate> {
        let n = m.len().min(s.len());
        if n < 50 {
            return None;
        }
        // Only frames where the remote side is clearly active tell us about bleed.
        let mut sorted = s[..n].to_vec();
        let floor = percentile(&mut sorted, 0.2).max(1e-5);
        let loud = percentile(&mut sorted, 0.7).max(floor * 4.0);
        // Where the remote side talks, a bleeding mic follows its syllables:
        // log envelopes correlate at the acoustic delay. Frames where the mic
        // is far above the typical ratio (local speech, double talk) are left
        // out; with headphones the mic does not follow at all.
        let log = |x: f64| (x + 1e-4).ln();
        let (mut best_lag, mut best_corr) = (0, 0.0);
        for lag in 0..=MAX_LAG_FRAMES.min(n / 4) {
            let pairs: Vec<(f64, f64)> = (lag..n)
                .filter(|&i| s[i - lag] >= loud)
                .map(|i| (log(m[i]), log(s[i - lag])))
                .collect();
            if pairs.len() < 25 {
                continue;
            }
            let mut differences: Vec<f64> = pairs.iter().map(|(a, b)| a - b).collect();
            let median = percentile(&mut differences, 0.5);
            let (a, b): (Vec<f64>, Vec<f64>) = pairs
                .into_iter()
                .filter(|(a, b)| a - b <= median + 0.7)
                .unzip();
            let corr = correlation(&a, &b);
            if corr > best_corr {
                best_corr = corr;
                best_lag = lag;
            }
        }
        if best_corr < MIN_CORRELATION {
            return None;
        }
        let delayed = |i: usize| if i >= best_lag { s[i - best_lag] } else { 0.0 };
        let mut ratios: Vec<f64> = (0..n)
            .filter(|&i| delayed(i) >= loud)
            .map(|i| m[i] / delayed(i))
            .collect();
        if ratios.len() < 25 {
            return None;
        }
        // The quieter quartile: frames where the user is silent and the mic hears only bleed.
        let gain = percentile(&mut ratios, 0.25);
        if gain < MIN_GAIN {
            return None;
        }
        let active = floor * 4.0;
        let mut bleed: Vec<bool> = (0..m.len())
            .map(|i| i < n && delayed(i) >= active && m[i] <= MARGIN * gain * delayed(i))
            .collect();
        // Keep a margin around local speech so onsets and word endings are not cut.
        let keep: Vec<bool> = bleed.iter().map(|b| !b).collect();
        for (i, kept) in keep.iter().enumerate() {
            if *kept {
                let from = i.saturating_sub(KEEP_AROUND);
                let to = (i + KEEP_AROUND + 1).min(bleed.len());
                for b in &mut bleed[from..to] {
                    *b = false;
                }
            }
        }
        let gains = bleed
            .iter()
            .map(|&b| if b { ATTENUATION } else { 1.0 })
            .collect();
        Some(BleedGate {
            delay_ms: (best_lag * FRAME * 1000 / 16_000) as u32,
            gain_db: 20.0 * gain.log10(),
            gains,
        })
    }

    /// Seconds of microphone audio attenuated.
    pub fn gated_seconds(&self) -> f64 {
        self.gains.iter().filter(|g| **g < 1.0).count() as f64 * FRAME as f64 / 16_000.0
    }

    /// Applies the frame gains with 5 ms ramps between frames.
    pub fn apply(&self, mic: &mut [f32]) {
        const RAMP: usize = 80;
        for (index, frame) in mic.chunks_mut(FRAME).enumerate() {
            let gain = self.gains.get(index).copied().unwrap_or(1.0);
            let previous = if index == 0 {
                gain
            } else {
                self.gains.get(index - 1).copied().unwrap_or(1.0)
            };
            for (i, sample) in frame.iter_mut().enumerate() {
                let g = if i < RAMP && previous != gain {
                    previous + (gain - previous) * (i as f32 / RAMP as f32)
                } else {
                    gain
                };
                *sample *= g;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn burst(n: usize, ranges: &[(usize, usize)], freq: f32, amp: f32) -> Vec<f32> {
        let mut x = vec![0.0f32; n];
        for &(a, b) in ranges {
            for (i, s) in x[a..b].iter_mut().enumerate() {
                *s = (i as f32 * freq * std::f32::consts::TAU / 16_000.0).sin()
                    * amp
                    * (0.6 + 0.4 * ((i / 1600) % 2) as f32);
            }
        }
        x
    }

    #[test]
    fn gates_bleed_but_keeps_local_speech() {
        let n = 16_000 * 20;
        let remote_ranges = [(16_000, 80_000), (160_000, 240_000)];
        let system = burst(n, &remote_ranges, 300.0, 0.5);
        let local = burst(n, &[(96_000, 144_000), (200_000, 216_000)], 200.0, 0.5);
        let delay = 640; // 40 ms
        let mut mic: Vec<f32> = (0..n)
            .map(|i| {
                local[i]
                    + if i >= delay {
                        system[i - delay] * 0.125
                    } else {
                        0.0
                    }
            })
            .collect();
        let gate = BleedGate::detect(&mic, &system).expect("bleed is evident");
        assert!((gate.delay_ms as i64 - 40).abs() <= 20, "{}", gate.delay_ms);
        assert!((gate.gain_db + 18.0).abs() < 3.0, "{}", gate.gain_db);
        gate.apply(&mut mic);
        let rms = |x: &[f32]| (x.iter().map(|s| s * s).sum::<f32>() / x.len() as f32).sqrt();
        assert!(
            rms(&mic[20_000..76_000]) < 0.01,
            "bleed-only stretch is suppressed"
        );
        assert!(
            rms(&mic[100_000..140_000]) > 0.25,
            "local speech is untouched"
        );
        assert!(rms(&mic[201_000..215_000]) > 0.25, "double talk is kept");
    }

    #[test]
    fn headphones_mean_no_gate() {
        let n = 16_000 * 10;
        let system = burst(n, &[(16_000, 64_000)], 300.0, 0.5);
        let mic = burst(n, &[(80_000, 120_000)], 200.0, 0.5);
        assert!(BleedGate::detect(&mic, &system).is_none());
    }
}
