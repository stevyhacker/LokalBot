//! WSOLA time stretching: playback at 0.75–2× without changing pitch, like
//! `AVAudioPlayer` with `enableRate` on macOS.
//!
//! Frames of 40 ms are overlap-added with a 50% Hann window; each frame's
//! source position is nudged by up to ±10 ms to best continue the previous
//! frame's waveform, which keeps voiced speech free of phasing artefacts.

const FRAME: usize = 640;
const HOP: usize = FRAME / 2;
const TOLERANCE: i64 = 160;

/// Source of timeline samples; positions past either end read as silence.
pub trait SampleSource {
    /// Fills `out` with samples starting at absolute frame `start`.
    fn read(&mut self, start: i64, out: &mut [f32]);
}

pub struct Wsola {
    window: Vec<f32>,
    /// Source position of the next frame (fractional, in frames).
    next_position: f64,
    /// Where the previous frame's natural continuation begins.
    continuation: Option<i64>,
    overlap: Vec<f32>,
    scratch: Vec<f32>,
    reference: Vec<f32>,
    candidates: Vec<f32>,
}

impl Wsola {
    pub fn new(position: i64) -> Self {
        let window = (0..FRAME)
            .map(|i| {
                let phase = std::f32::consts::TAU * i as f32 / FRAME as f32;
                0.5 - 0.5 * phase.cos()
            })
            .collect();
        Self {
            window,
            next_position: position as f64,
            continuation: None,
            overlap: vec![0.0; HOP],
            scratch: vec![0.0; FRAME],
            reference: vec![0.0; FRAME],
            candidates: vec![0.0; FRAME + 2 * TOLERANCE as usize],
        }
    }

    /// Source position the listener is hearing, in frames.
    pub fn position(&self) -> f64 {
        self.next_position
    }

    /// Renders one block of `HOP` output samples at `speed`.
    pub fn render(&mut self, source: &mut dyn SampleSource, speed: f64, out: &mut Vec<f32>) {
        let target = self.next_position.round() as i64;
        let offset = match self.continuation {
            None => 0,
            Some(continuation) => {
                source.read(continuation, &mut self.reference);
                source.read(target - TOLERANCE, &mut self.candidates);
                best_offset(&self.reference, &self.candidates)
            }
        };
        let start = target + offset;
        source.read(start, &mut self.scratch);
        for i in 0..HOP {
            out.push(self.overlap[i] + self.scratch[i] * self.window[i]);
        }
        for i in 0..HOP {
            self.overlap[i] = self.scratch[HOP + i] * self.window[HOP + i];
        }
        self.continuation = Some(start + HOP as i64);
        self.next_position += HOP as f64 * speed;
    }
}

/// Offset in `-TOLERANCE..=TOLERANCE` whose candidate window best matches
/// `reference` (normalised cross-correlation, coarse search then refinement).
fn best_offset(reference: &[f32], candidates: &[f32]) -> i64 {
    let score = |shift: usize| -> f32 {
        let candidate = &candidates[shift..shift + FRAME];
        let mut dot = 0.0f32;
        let mut energy = 1e-9f32;
        // Every other sample is plenty for speech and halves the cost.
        for i in (0..FRAME).step_by(2) {
            dot += reference[i] * candidate[i];
            energy += candidate[i] * candidate[i];
        }
        dot / energy.sqrt()
    };
    let span = 2 * TOLERANCE as usize;
    let mut best = TOLERANCE as usize;
    let mut best_score = f32::MIN;
    for shift in (0..=span).step_by(4) {
        let s = score(shift);
        if s > best_score {
            best_score = s;
            best = shift;
        }
    }
    let low = best.saturating_sub(3);
    let high = (best + 3).min(span);
    for shift in low..=high {
        let s = score(shift);
        if s > best_score {
            best_score = s;
            best = shift;
        }
    }
    best as i64 - TOLERANCE
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Tone {
        freq: f32,
        len: i64,
    }

    impl SampleSource for Tone {
        fn read(&mut self, start: i64, out: &mut [f32]) {
            for (i, sample) in out.iter_mut().enumerate() {
                let n = start + i as i64;
                *sample = if (0..self.len).contains(&n) {
                    (n as f32 * self.freq * std::f32::consts::TAU / 16_000.0).sin() * 0.5
                } else {
                    0.0
                };
            }
        }
    }

    fn dominant_frequency(samples: &[f32]) -> f32 {
        let crossings = samples
            .windows(2)
            .filter(|w| w[0] <= 0.0 && w[1] > 0.0)
            .count();
        crossings as f32 * 16_000.0 / samples.len() as f32
    }

    #[test]
    fn faster_playback_keeps_pitch_and_shortens_time() {
        for speed in [0.75, 1.5, 2.0] {
            let mut source = Tone {
                freq: 220.0,
                len: 16_000 * 4,
            };
            let mut wsola = Wsola::new(0);
            let mut out = Vec::new();
            while wsola.position() < 16_000.0 * 2.0 {
                wsola.render(&mut source, speed, &mut out);
            }
            let expected = 16_000.0 * 2.0 / speed;
            assert!(
                (out.len() as f64 - expected).abs() < 700.0,
                "speed {speed}: {}",
                out.len()
            );
            let freq = dominant_frequency(&out[2_000..out.len() - 2_000]);
            assert!((freq - 220.0).abs() < 6.0, "speed {speed}: {freq}");
            // Overlap-add of matched frames keeps the level steady.
            let rms = (out[2_000..out.len() - 2_000]
                .iter()
                .map(|s| s * s)
                .sum::<f32>()
                / (out.len() - 4_000) as f32)
                .sqrt();
            assert!(
                (rms - 0.5 / 2f32.sqrt()).abs() < 0.04,
                "speed {speed}: {rms}"
            );
        }
    }
}
