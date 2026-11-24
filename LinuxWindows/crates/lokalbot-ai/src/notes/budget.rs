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
const TOKENS_PER_SECOND: f64 = 35.0;

pub struct Budget {
    limits: Limits,
    started: Instant,
    requests: usize,
    input_tokens: u64,
    output_tokens: u64,
    scale: f64,
    may_reason: bool,
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
            may_reason: false,
        }
    }

    pub fn allow_reasoning(&mut self) {
        self.may_reason = true;
    }

    fn reasoning_factor(&self) -> f64 {
        if self.may_reason { 2.0 } else { 1.0 }
    }

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
        (self.limits.output_tokens as f64 * self.scale * self.reasoning_factor()).ceil() as u64
    }

    pub fn remaining_seconds(&self) -> f64 {
        (self.limits.seconds * self.scale * self.reasoning_factor()
            - self.started.elapsed().as_secs_f64())
        .max(0.0)
    }

    pub fn allowance(
        &self,
        remaining_parts: usize,
        desired: u32,
        minimum: u32,
    ) -> Result<u32, Exhausted> {
        let limit = self.request_limit();
        let processable = ((limit + 1).saturating_sub(self.requests) / 2).max(1);
        let parts = remaining_parts.max(1).min(processable) as u64;
        let share = self.reasoning_factor() as u64;
        let output_room = self.output_limit().saturating_sub(self.output_tokens) / parts / share;
        let time_room =
            (self.remaining_seconds() * TOKENS_PER_SECOND / parts as f64) as u64 / share;
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

    #[test]
    fn a_job_that_may_reason_doubles_its_limits_and_keeps_answer_sizes() {
        let limits = Limits {
            seconds: 600.0,
            requests: 4,
            input_tokens: 10_000,
            output_tokens: 8_000,
            scales_with_parts: false,
        };
        let plain = Budget::new(limits);
        let mut reasoning = Budget::new(limits);
        reasoning.allow_reasoning();
        assert_eq!(
            plain.allowance(2, 16_384, 512).unwrap(),
            reasoning.allowance(2, 16_384, 512).unwrap()
        );
        assert_eq!(reasoning.allowance(2, 16_384, 512).unwrap(), 4_000);
        assert!(reasoning.remaining_seconds() > 600.0);
        assert!(Budget::new(limits).reserve(0, 16_000).is_err());
        reasoning.reserve(0, 16_000).unwrap();
    }

    #[test]
    fn a_retried_request_charges_both_attempts() {
        let mut budget = Budget::new(Limits {
            seconds: 600.0,
            requests: 3,
            input_tokens: 1_000,
            output_tokens: 3_000,
            scales_with_parts: false,
        });
        budget.reserve(400, 2_000).unwrap();
        budget.finish(2_000, Some(2_000));
        budget.reserve(400, 1_000).unwrap();
        budget.finish(1_000, Some(300));
        assert!(
            budget.reserve(201, 0).is_err(),
            "both attempts' input counts"
        );
        assert!(
            budget.reserve(0, 701).is_err(),
            "both attempts' output counts"
        );
        budget.reserve(200, 700).unwrap();
        assert!(
            budget.reserve(0, 0).is_err(),
            "two attempts count as two requests"
        );
    }
}
