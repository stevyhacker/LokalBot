//! Streaming windowed-sinc resampler for mono audio.
//!
//! Output sample `n` sits exactly at input position `n * in_rate / out_rate`
//! (computed in integers, so hours of audio never drift). The kernel is a
//! Kaiser-windowed sinc low-pass at 90% of the lower Nyquist frequency, 16 zero
//! crossings each side, normalised per output sample for exact unity DC gain.

const ZERO_CROSSINGS: f64 = 16.0;
const KAISER_BETA: f64 = 8.6;
/// Kernel table resolution, entries per input sample.
const TABLE_STEPS: usize = 64;

pub struct Resampler {
    in_rate: u64,
    out_rate: u64,
    /// Kernel half width in input samples.
    half_width: i64,
    /// `table[i]` is the kernel at distance `i / TABLE_STEPS` input samples.
    table: Vec<f32>,
    /// Pending input; `buffer[0]` is global input index `buffer_start`.
    buffer: Vec<f32>,
    buffer_start: u64,
    input_total: u64,
    next_output: u64,
}

impl Resampler {
    pub fn new(in_rate: u32, out_rate: u32) -> Self {
        let in_rate = in_rate.max(1) as u64;
        let out_rate = out_rate.max(1) as u64;
        let cutoff = 0.45 * in_rate.min(out_rate) as f64;
        // Normalised bandwidth in cycles per input sample, times two.
        let g = 2.0 * cutoff / in_rate as f64;
        let half_width = (ZERO_CROSSINGS / g).ceil() as i64;
        let len = half_width as usize * TABLE_STEPS + 2;
        let i0_beta = bessel_i0(KAISER_BETA);
        let table = (0..len)
            .map(|i| {
                let x = i as f64 / TABLE_STEPS as f64;
                let ratio = x / half_width as f64;
                if ratio >= 1.0 {
                    return 0.0;
                }
                let window = bessel_i0(KAISER_BETA * (1.0 - ratio * ratio).sqrt()) / i0_beta;
                (g * sinc(g * x) * window) as f32
            })
            .collect();
        Self {
            in_rate,
            out_rate,
            half_width,
            table,
            buffer: Vec::new(),
            buffer_start: 0,
            input_total: 0,
            next_output: 0,
        }
    }

    pub fn is_passthrough(&self) -> bool {
        self.in_rate == self.out_rate
    }

    /// Appends every output sample that `input` makes computable to `out`.
    pub fn process(&mut self, input: &[f32], out: &mut Vec<f32>) {
        if self.is_passthrough() {
            out.extend_from_slice(input);
            self.input_total += input.len() as u64;
            self.next_output = self.input_total;
            return;
        }
        self.buffer.extend_from_slice(input);
        self.input_total += input.len() as u64;
        self.drain(out, false);
    }

    /// Emits the remaining output, treating input past the end as silence.
    pub fn flush(&mut self, out: &mut Vec<f32>) {
        if self.is_passthrough() {
            return;
        }
        self.drain(out, true);
        self.buffer.clear();
        self.buffer_start = self.input_total;
    }

    /// Output samples produced so far.
    pub fn output_len(&self) -> u64 {
        self.next_output
    }

    /// Input samples received so far.
    pub fn input_frames(&self) -> u64 {
        self.input_total
    }

    fn drain(&mut self, out: &mut Vec<f32>, flushing: bool) {
        // The last output that belongs to the input received so far.
        let total_outputs = (self.input_total * self.out_rate).div_ceil(self.in_rate);
        loop {
            let n = self.next_output;
            if n >= total_outputs {
                break;
            }
            let numerator = n * self.in_rate;
            let center = (numerator / self.out_rate) as i64;
            let frac = (numerator % self.out_rate) as f64 / self.out_rate as f64;
            if !flushing && center + self.half_width >= self.input_total as i64 {
                break;
            }
            out.push(self.sample_at(center, frac));
            self.next_output += 1;
        }
        // Keep only the history the next output still needs.
        let keep_from = {
            let numerator = self.next_output * self.in_rate;
            ((numerator / self.out_rate) as i64 - self.half_width).max(0) as u64
        };
        if keep_from > self.buffer_start {
            let drop = ((keep_from - self.buffer_start) as usize).min(self.buffer.len());
            self.buffer.drain(..drop);
            self.buffer_start += drop as u64;
        }
    }

    fn sample_at(&self, center: i64, frac: f64) -> f32 {
        let mut acc = 0.0f64;
        let mut weight_sum = 0.0f64;
        for k in (center - self.half_width + 1)..=(center + self.half_width) {
            let distance = ((k - center) as f64 - frac).abs();
            let weight = self.kernel(distance) as f64;
            if weight == 0.0 {
                continue;
            }
            weight_sum += weight;
            if k < 0 || k < self.buffer_start as i64 {
                continue;
            }
            let index = (k as u64 - self.buffer_start) as usize;
            if let Some(&sample) = self.buffer.get(index) {
                acc += sample as f64 * weight;
            }
        }
        if weight_sum.abs() < 1e-9 {
            0.0
        } else {
            (acc / weight_sum) as f32
        }
    }

    fn kernel(&self, distance: f64) -> f32 {
        let position = distance * TABLE_STEPS as f64;
        let index = position as usize;
        if index + 1 >= self.table.len() {
            return 0.0;
        }
        let t = (position - index as f64) as f32;
        self.table[index] * (1.0 - t) + self.table[index + 1] * t
    }
}

fn sinc(x: f64) -> f64 {
    if x.abs() < 1e-12 {
        1.0
    } else {
        let px = std::f64::consts::PI * x;
        px.sin() / px
    }
}

fn bessel_i0(x: f64) -> f64 {
    let mut sum = 1.0;
    let mut term = 1.0;
    let half = x / 2.0;
    for k in 1..50 {
        term *= half / k as f64;
        let squared = term * term;
        sum += squared;
        if squared < sum * 1e-16 {
            break;
        }
    }
    sum
}

/// Resamples a whole buffer.
pub fn resample(input: &[f32], in_rate: u32, out_rate: u32) -> Vec<f32> {
    let mut resampler = Resampler::new(in_rate, out_rate);
    let mut out = Vec::with_capacity(input.len() * out_rate as usize / in_rate.max(1) as usize + 8);
    resampler.process(input, &mut out);
    resampler.flush(&mut out);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tone(freq: f64, rate: u32, seconds: f64) -> Vec<f32> {
        let frames = (rate as f64 * seconds) as usize;
        (0..frames)
            .map(|i| (i as f64 * freq * std::f64::consts::TAU / rate as f64).sin() as f32 * 0.5)
            .collect()
    }

    fn rms(samples: &[f32]) -> f32 {
        (samples.iter().map(|s| s * s).sum::<f32>() / samples.len().max(1) as f32).sqrt()
    }

    #[test]
    fn keeps_passband_tones() {
        for rate in [48_000, 44_100, 22_050, 8_000] {
            let input = tone(1000.0, rate, 1.0);
            let out = resample(&input, rate, 16_000);
            assert!(
                (out.len() as i64 - 16_000).abs() <= 1,
                "rate {rate}: {}",
                out.len()
            );
            let level = rms(&out[1000..15_000]);
            assert!(
                (level - 0.5 / 2f32.sqrt()).abs() < 0.005,
                "rate {rate}: {level}"
            );
            // Same phase as the ideal 16 kHz tone (no delay).
            let ideal = tone(1000.0, 16_000, 1.0);
            let error = rms(&out[1000..15_000]
                .iter()
                .zip(&ideal[1000..15_000])
                .map(|(a, b)| a - b)
                .collect::<Vec<_>>());
            assert!(error < 0.01, "rate {rate}: {error}");
        }
    }

    #[test]
    fn removes_frequencies_above_the_new_nyquist() {
        let input = tone(11_000.0, 48_000, 1.0);
        let out = resample(&input, 48_000, 16_000);
        assert!(
            rms(&out[1000..15_000]) < 0.002,
            "{}",
            rms(&out[1000..15_000])
        );
    }

    #[test]
    fn streaming_matches_one_shot() {
        let input = tone(440.0, 44_100, 0.5);
        let whole = resample(&input, 44_100, 16_000);
        let mut resampler = Resampler::new(44_100, 16_000);
        let mut streamed = Vec::new();
        for chunk in input.chunks(441) {
            resampler.process(chunk, &mut streamed);
        }
        resampler.flush(&mut streamed);
        assert_eq!(whole.len(), streamed.len());
        for (a, b) in whole.iter().zip(&streamed) {
            assert!((a - b).abs() < 1e-6);
        }
    }

    #[test]
    fn passthrough_copies() {
        let input = vec![0.25f32; 100];
        assert_eq!(resample(&input, 16_000, 16_000), input);
    }
}
