//! The job allowance for one notes run (`MeetingGenerationBudget.swift`).

use std::time::Instant;

use lokalbot_core::settings::GenerationBudget;

#[derive(Debug, thiserror::Error)]
#[error(
    "Notes reached their processing limit. Source-linked progress was saved; summarize again to continue."
)]
pub struct Exhausted;

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Limits {
    pub seconds: f64,
    pub requests: usize,
    pub input_tokens: u64,
    pub output_tokens: u64,
    /// Standard limits cover four meeting parts and grow with the meeting.
    pub scales_with_parts: bool,
}

impl Limits {
    pub fn for_preset(preset: GenerationBudget) -> Self {
        match preset {
            GenerationBudget::Conservative => Self {
                seconds: 300.0,
                requests: 6,
                input_tokens: 125_000,
                output_tokens: 12_288,
                scales_with_parts: false,
            },
            GenerationBudget::Standard => Self {
                seconds: 600.0,
                requests: 12,
                input_tokens: 250_000,
                output_tokens: 24_576,
                scales_with_parts: true,
            },
            GenerationBudget::Generous => Self {
                seconds: 1_800.0,
                requests: 36,
                input_tokens: 750_000,
                output_tokens: 73_728,
                scales_with_parts: true,
            },
            GenerationBudget::Unlimited => Self {
                seconds: 21_600.0,
                requests: 10_000,
                input_tokens: 100_000_000,
                output_tokens: 10_000_000,
                scales_with_parts: false,
            },
        }
    }
}

const PARTS_PER_BUDGET: f64 = 4.0;
/// Output tokens per second the time allowance assumes.
const TOKENS_PER_SECOND: f64 = 35.0;

pub struct Budget {
    limits: Limits,
    started: Instant,
    requests: usize,
    input_tokens: u64,
    output_tokens: u64,
    scale: f64,
}

impl Budget {
    pub fn new(limits: Limits) -> Self {
        Self {
            limits,
            started: Instant::now(),
            requests: 0,
            input_tokens: 0,
            output_tokens: 0,
            scale: 1.0,
        }
    }

    /// `standard_parts` counts the work in standard-size parts.
    pub fn record_plan(&mut self, parts: usize, standard_parts: f64) {
        if self.limits.scales_with_parts {
            self.scale =
                (parts as f64).max(standard_parts).max(PARTS_PER_BUDGET) / PARTS_PER_BUDGET;
        }
    }

    fn request_limit(&self) -> usize {
        (self.limits.requests as f64 * self.scale).ceil() as usize
    }

    fn input_limit(&self) -> u64 {
        (self.limits.input_tokens as f64 * self.scale).ceil() as u64
    }

    fn output_limit(&self) -> u64 {
        (self.limits.output_tokens as f64 * self.scale).ceil() as u64
    }

    pub fn remaining_seconds(&self) -> f64 {
        (self.limits.seconds * self.scale - self.started.elapsed().as_secs_f64()).max(0.0)
    }

    /// Output tokens for the next call: the desired amount, shared fairly with
    /// the parts this run can still process (one repair reserved per part).
    pub fn allowance(
        &self,
        remaining_parts: usize,
        desired: u32,
        minimum: u32,
    ) -> Result<u32, Exhausted> {
        let limit = self.request_limit();
        let processable = ((limit + 1).saturating_sub(self.requests) / 2).max(1);
        let parts = remaining_parts.max(1).min(processable) as u64;
        let output_room = self.output_limit().saturating_sub(self.output_tokens) / parts;
        let time_room = (self.remaining_seconds() * TOKENS_PER_SECOND / parts as f64) as u64;
        let available = u64::from(desired).min(output_room).min(time_room);
        if self.requests >= limit || available < u64::from(minimum.max(512)) {
            return Err(Exhausted);
        }
        Ok(available as u32)
    }

    pub fn reserve(&mut self, input: u64, output: u64) -> Result<(), Exhausted> {
        if self.remaining_seconds() <= 0.0
            || self.requests >= self.request_limit()
            || self.input_tokens + input > self.input_limit()
            || self.output_tokens + output > self.output_limit()
        {
            return Err(Exhausted);
        }
        self.requests += 1;
        self.input_tokens += input;
        self.output_tokens += output;
        Ok(())
    }

    /// Unknown usage keeps the reservation; absence is never zero usage.
    pub fn finish(&mut self, reserved: u64, actual: Option<u64>) {
        if let Some(actual) = actual {
            self.output_tokens = (self.output_tokens + actual).saturating_sub(reserved);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn standard_limits_scale_with_long_meetings() {
        let mut budget = Budget::new(Limits::for_preset(GenerationBudget::Standard));
        budget.record_plan(8, 8.0);
        assert_eq!(budget.request_limit(), 24);
        assert_eq!(budget.allowance(8, 4_096, 512).unwrap(), 4_096);
        let mut small = Budget::new(Limits::for_preset(GenerationBudget::Conservative));
        small.record_plan(8, 8.0);
        assert_eq!(small.request_limit(), 6);
        // Three processable parts: 4,096 output tokens each, but 300 s at
        // 35 tokens/s caps each at about 3,500.
        let allowance = small.allowance(8, 8_192, 512).unwrap();
        assert!((3_400..=3_500).contains(&allowance), "{allowance}");
    }

    #[test]
    fn reservations_exhaust_the_job() {
        let mut budget = Budget::new(Limits {
            seconds: 600.0,
            requests: 2,
            input_tokens: 1_000,
            output_tokens: 2_000,
            scales_with_parts: false,
        });
        budget.reserve(400, 1_000).unwrap();
        budget.finish(1_000, Some(200));
        budget.reserve(400, 1_000).unwrap();
        assert!(budget.reserve(1, 1).is_err());
        assert!(budget.allowance(1, 4_096, 512).is_err());
    }
}
