//! How hard a big read works the computer (`IndexPacing`): a folder's first pass
//! in Files, or the picture vectors of saved screens. While the person is at the
//! computer, reading gets about a third of the time: after each batch it rests
//! twice as long as the batch took. After two minutes without input it goes at
//! full speed, and the next input slows it again after the current batch.

use std::time::{Duration, Instant};

/// Seconds of rest for each second of work while the person is at the computer.
pub const REST_PER_SECOND_OF_WORK: f64 = 2.0;
/// No input for this long: they stepped away.
pub const AWAY_AFTER: f64 = 120.0;
/// A long batch never holds reading up for longer than this.
pub const LONGEST_REST: f64 = 20.0;

/// How long to rest after `worked` seconds of reading, given the seconds since
/// the last input. When nothing can tell (a desktop that doesn't say, or a
/// headless session), the person counts as being there.
pub fn rest_after(worked: f64, seconds_since_input: Option<f64>) -> f64 {
    let away = seconds_since_input.is_some_and(|idle| idle >= AWAY_AFTER);
    if worked <= 0.0 || away {
        return 0.0;
    }
    (worked * REST_PER_SECOND_OF_WORK).min(LONGEST_REST)
}

/// Rests between a pass's jobs, in short sleeps, so a stop never waits on a rest
/// (`FileIndexPacer`).
pub struct Pacer {
    clock: Box<dyn FnMut() -> Option<f64> + Send>,
    resumed: Option<Instant>,
    /// Seconds rested so far, for the pass report.
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

    /// The person's keyboard and mouse pace it. Reading the idle time needs no
    /// permission and says nothing about which key or where.
    pub fn live() -> Self {
        let mut source = lokalbot_platform::activity_source();
        Self::new(Box::new(move || source.idle_seconds()))
    }

    /// Between jobs: rests after the job that just finished, if the person is
    /// here. Returns early once `stop` says so.
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
