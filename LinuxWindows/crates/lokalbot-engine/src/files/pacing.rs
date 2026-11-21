use std::time::{Duration, Instant};

pub const REST_PER_SECOND_OF_WORK: f64 = 2.0;
pub const AWAY_AFTER: f64 = 120.0;
pub const LONGEST_REST: f64 = 20.0;

pub fn rest_after(worked: f64, seconds_since_input: Option<f64>) -> f64 {
    let away = seconds_since_input.is_some_and(|idle| idle >= AWAY_AFTER);
    if worked <= 0.0 || away {
        return 0.0;
    }
    (worked * REST_PER_SECOND_OF_WORK).min(LONGEST_REST)
}

pub struct Pacer {
    clock: Box<dyn FnMut() -> Option<f64> + Send>,
    resumed: Option<Instant>,
    pub rested: f64,
}

impl Pacer {
    pub fn new(clock: Box<dyn FnMut() -> Option<f64> + Send>) -> Self {
        Self {
            clock,
            resumed: None,
            rested: 0.0,
        }
    }

    pub fn live() -> Self {
        let mut source = lokalbot_platform::activity_source();
        Self::new(Box::new(move || source.idle_seconds()))
    }

    pub fn rest_between_jobs(&mut self, stop: &dyn Fn() -> bool) {
        if let Some(resumed) = self.resumed {
            let mut left = rest_after(resumed.elapsed().as_secs_f64(), (self.clock)());
            while left > 0.0 && !stop() {
                let step = left.min(0.1);
                std::thread::sleep(Duration::from_secs_f64(step));
                self.rested += step;
                left -= step;
            }
        }
        self.resumed = Some(Instant::now());
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reading_gets_a_third_of_the_time_while_someone_is_here() {
        assert_eq!(rest_after(3.0, Some(1.0)), 6.0);
        assert_eq!(rest_after(30.0, Some(1.0)), 20.0, "a long batch rests 20 s");
        assert_eq!(rest_after(3.0, Some(119.0)), 6.0);
        assert_eq!(rest_after(3.0, Some(120.0)), 0.0, "stepped away");
        assert_eq!(rest_after(0.0, Some(1.0)), 0.0);
    }

    #[test]
    fn an_unknown_idle_time_counts_as_someone_being_here() {
        assert_eq!(rest_after(3.0, None), 6.0);
    }

    #[test]
    fn a_stop_cuts_a_rest_short() {
        let mut pacer = Pacer::new(Box::new(|| Some(0.0)));
        pacer.rest_between_jobs(&|| false);
        assert_eq!(pacer.rested, 0.0, "nothing to rest after yet");
        std::thread::sleep(Duration::from_millis(30));
        let started = Instant::now();
        pacer.rest_between_jobs(&|| true);
        assert!(started.elapsed() < Duration::from_millis(50));
        assert_eq!(pacer.rested, 0.0);
        std::thread::sleep(Duration::from_millis(30));
        pacer.rest_between_jobs(&|| false);
        assert!(pacer.rested > 0.0);
    }
}
