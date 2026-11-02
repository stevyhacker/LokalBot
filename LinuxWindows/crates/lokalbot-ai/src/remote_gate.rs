//! One admission gate for every external Think and autocomplete server, keyed by
//! origin (`RemoteInferenceGate.swift`). Every request waits for a slot, so
//! background digests and overnight reviews can't starve meeting notes, and a
//! rate limit pauses every caller of that origin instead of each one trying again
//! a second later. The built-in runtime has its own leases and never comes here.
//!
//! The gate lives in one process, like the Mac's actor.

use std::collections::{HashMap, HashSet};
use std::sync::OnceLock;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use anyhow::Result;
use parking_lot::{Condvar, Mutex};

use crate::error::AiError;

/// `RemoteRequestQueue.maximumCooldown`, in seconds.
pub const MAXIMUM_COOLDOWN_SECONDS: f64 = 60.0;
/// How often a waiter looks at its cancel flag, its deadline and the cooldown.
const WAIT_TICK: Duration = Duration::from_millis(50);

/// `InferencePriority`, most urgent first.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum Priority {
    /// The person is watching this happen (chat, autocomplete, model check).
    Interactive,
    /// An agent is waiting.
    Agent,
    /// Processing the person will open next: notes for a meeting that just ended.
    Pipeline,
    /// Scheduled work nobody is waiting for (digests, overnight review, briefs).
    Background,
}

impl Priority {
    pub fn label(self) -> &'static str {
        match self {
            Self::Interactive => "interactive",
            Self::Agent => "agent",
            Self::Pipeline => "pipeline",
            Self::Background => "background",
        }
    }
}

/// `RemoteRequestQueue.Limits`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Limits {
    pub maximum_concurrent: usize,
    pub maximum_background: usize,
}

impl Default for Limits {
    fn default() -> Self {
        Self {
            maximum_concurrent: 2,
            maximum_background: 1,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Waiter {
    id: u64,
    priority: Priority,
    order: u64,
}

/// `RemoteRequestQueue`: pure bookkeeping for one origin's slots, with no clock
/// and no threads. Processing work runs at most `maximum_concurrent` requests at
/// once; background work holds at most `maximum_background` of them; someone
/// waiting on the answer is never queued behind processing work. Waiters start in
/// priority order, first come first served within a priority, and a blocked
/// background waiter never holds back one that could start. After a rate limit
/// nothing starts until the cooldown has passed.
#[derive(Debug)]
struct RequestQueue {
    limits: Limits,
    in_flight: HashMap<u64, Priority>,
    waiters: Vec<Waiter>,
    cooldown_until: f64,
    /// Consecutive rate-limited answers; resets on the first other answer.
    consecutive_rate_limits: u32,
    next_order: u64,
}

impl RequestQueue {
    fn new(limits: Limits) -> Self {
        Self {
            limits,
            in_flight: HashMap::new(),
            waiters: Vec::new(),
            cooldown_until: 0.0,
            consecutive_rate_limits: 0,
            next_order: 0,
        }
    }

    fn background_in_flight(&self) -> usize {
        self.in_flight
            .values()
            .filter(|priority| **priority == Priority::Background)
            .count()
    }

    fn processing_in_flight(&self) -> usize {
        self.in_flight
            .values()
            .filter(|priority| **priority >= Priority::Pipeline)
            .count()
    }

    fn enqueue(&mut self, id: u64, priority: Priority) {
        self.waiters.push(Waiter {
            id,
            priority,
            order: self.next_order,
        });
        self.next_order = self.next_order.wrapping_add(1);
    }

    fn cancel(&mut self, id: u64) {
        self.waiters.retain(|waiter| waiter.id != id);
    }

    /// Waiters that may start now, moved to `in_flight`.
    fn admit(&mut self, now: f64) -> Vec<u64> {
        if now < self.cooldown_until {
            return Vec::new();
        }
        let mut ordered = self.waiters.clone();
        ordered.sort_by_key(|waiter| (waiter.priority, waiter.order));
        let mut admitted = Vec::new();
        for waiter in ordered {
            if waiter.priority >= Priority::Pipeline {
                if self.processing_in_flight() >= self.limits.maximum_concurrent {
                    break;
                }
                if waiter.priority == Priority::Background
                    && self.background_in_flight() >= self.limits.maximum_background
                {
                    continue;
                }
            }
            self.in_flight.insert(waiter.id, waiter.priority);
            admitted.push(waiter.id);
        }
        self.waiters.retain(|waiter| !admitted.contains(&waiter.id));
        admitted
    }

    /// Frees a slot. A rate-limited answer starts or extends the cooldown.
    fn finish(&mut self, id: u64, rate_limited: bool, retry_after: Option<f64>, now: f64) {
        self.in_flight.remove(&id);
        if !rate_limited {
            self.consecutive_rate_limits = 0;
            return;
        }
        self.consecutive_rate_limits += 1;
        let pause = cooldown(self.consecutive_rate_limits, retry_after);
        self.cooldown_until = self.cooldown_until.max(now + pause);
    }
}

/// `RemoteRequestQueue.cooldown`: the server's `Retry-After` when given, else a
/// pause that grows with consecutive rate limits.
fn cooldown(count: u32, retry_after: Option<f64>) -> f64 {
    match retry_after {
        Some(after) => after.clamp(1.0, MAXIMUM_COOLDOWN_SECONDS),
        None => {
            (2.0 * 2f64.powi(count.saturating_sub(1).min(16) as i32)).min(MAXIMUM_COOLDOWN_SECONDS)
        }
    }
}

/// `RemoteRetryPolicy.maximumAttempts`: the gate's cooldown already paces rate
/// limits, so this bounds attempts rather than the wait. Meeting notes are worth
/// waiting for; a person watching chat would rather see the error quickly.
pub fn maximum_attempts(priority: Priority) -> u32 {
    match priority {
        Priority::Interactive | Priority::Agent => 2,
        Priority::Pipeline => 5,
        Priority::Background => 4,
    }
}

/// `RemoteRetryPolicy.backoff`: the pause before a replay that didn't fail with a
/// rate limit. Rate limits wait on the cooldown instead.
pub fn backoff(attempt: u32, retry_after: Option<Duration>, jitter: Duration) -> Duration {
    let limit = Duration::from_secs_f64(MAXIMUM_COOLDOWN_SECONDS);
    match retry_after {
        Some(after) => after.min(limit),
        None => (Duration::from_secs(2).saturating_mul(2u32.saturating_pow(attempt)) + jitter)
            .min(limit),
    }
}

fn jitter() -> Duration {
    let millis = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|elapsed| elapsed.subsec_millis())
        .unwrap_or(0);
    Duration::from_millis(u64::from(millis % 500))
}

/// `RemoteInferenceGate.origin(for:)`: scheme, host and port, in lower case.
pub fn origin(url: &str) -> String {
    lokalbot_core::access::origin_of(url).unwrap_or_else(|| url.trim().to_lowercase())
}

/// Why a waiter gave up before it got a slot.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Blocked {
    Cancelled,
    TimedOut,
}

/// How long a waiter stays in line.
#[derive(Clone, Copy, Default)]
pub struct Wait<'a> {
    pub cancel: Option<&'a AtomicBool>,
    pub deadline: Option<Instant>,
}

#[derive(Default)]
struct State {
    queues: HashMap<String, RequestQueue>,
    admitted: HashSet<u64>,
    next_id: u64,
}

pub struct Gate {
    limits: Limits,
    started: Instant,
    state: Mutex<State>,
    changed: Condvar,
    pause: fn(Duration),
}

/// The slot one request holds. Dropped without [`finish`](Self::finish) it frees
/// the slot as an ordinary answer, so a panic can't leak it.
pub struct Ticket<'a> {
    gate: &'a Gate,
    origin: String,
    id: u64,
    finished: bool,
}

impl Ticket<'_> {
    pub fn finish(mut self, rate_limited: bool, retry_after: Option<Duration>) {
        self.finished = true;
        self.gate.release(
            &self.origin,
            self.id,
            rate_limited,
            retry_after.map(|after| after.as_secs_f64()),
        );
    }
}

impl Drop for Ticket<'_> {
    fn drop(&mut self) {
        if !self.finished {
            self.gate.release(&self.origin, self.id, false, None);
        }
    }
}

/// The one gate this process shares.
pub fn shared() -> &'static Gate {
    static GATE: OnceLock<Gate> = OnceLock::new();
    GATE.get_or_init(|| Gate::new(Limits::default(), std::thread::sleep))
}

impl Gate {
    fn new(limits: Limits, pause: fn(Duration)) -> Self {
        Self {
            limits,
            started: Instant::now(),
            state: Mutex::new(State::default()),
            changed: Condvar::new(),
            pause,
        }
    }

    fn now(&self) -> f64 {
        self.started.elapsed().as_secs_f64()
    }

    fn pump(&self, state: &mut State, origin: &str) {
        let now = self.now();
        let Some(queue) = state.queues.get_mut(origin) else {
            return;
        };
        let admitted = queue.admit(now);
        if !admitted.is_empty() {
            state.admitted.extend(admitted);
            self.changed.notify_all();
        }
    }

    /// Waits for a slot on `origin`. Blocking.
    pub fn acquire(
        &self,
        origin: &str,
        priority: Priority,
        wait: Wait<'_>,
    ) -> Result<Ticket<'_>, Blocked> {
        if wait.cancel.is_some_and(|c| c.load(Ordering::Relaxed)) {
            return Err(Blocked::Cancelled);
        }
        let mut state = self.state.lock();
        let id = state.next_id;
        state.next_id += 1;
        let limits = self.limits;
        state
            .queues
            .entry(origin.to_string())
            .or_insert_with(|| RequestQueue::new(limits))
            .enqueue(id, priority);
        loop {
            self.pump(&mut state, origin);
            if state.admitted.remove(&id) {
                return Ok(Ticket {
                    gate: self,
                    origin: origin.to_string(),
                    id,
                    finished: false,
                });
            }
            let gave_up = if wait.cancel.is_some_and(|c| c.load(Ordering::Relaxed)) {
                Some(Blocked::Cancelled)
            } else if wait.deadline.is_some_and(|d| Instant::now() >= d) {
                Some(Blocked::TimedOut)
            } else {
                None
            };
            if let Some(reason) = gave_up {
                if let Some(queue) = state.queues.get_mut(origin) {
                    queue.cancel(id);
                }
                self.pump(&mut state, origin);
                return Err(reason);
            }
            self.changed.wait_for(&mut state, WAIT_TICK);
        }
    }

    fn release(&self, origin: &str, id: u64, rate_limited: bool, retry_after: Option<f64>) {
        let now = self.now();
        let mut state = self.state.lock();
        if let Some(queue) = state.queues.get_mut(origin) {
            queue.finish(id, rate_limited, retry_after, now);
        }
        self.pump(&mut state, origin);
    }

    /// One request that is never replayed: a stream could repeat text already shown.
    pub fn once<T>(
        &self,
        origin: &str,
        priority: Priority,
        cancel: Option<&AtomicBool>,
        operation: impl FnOnce() -> Result<T>,
    ) -> Result<T> {
        let ticket = self
            .acquire(
                origin,
                priority,
                Wait {
                    cancel,
                    deadline: None,
                },
            )
            .map_err(|_| AiError::Cancelled)?;
        let result = operation();
        finish(ticket, &result);
        result
    }

    /// A replayable request (`GatedTextEngine.replaying`). Callers must not add
    /// their own replay on top.
    pub fn replaying<T>(
        &self,
        origin: &str,
        priority: Priority,
        purpose: &str,
        mut operation: impl FnMut() -> Result<T>,
    ) -> Result<T> {
        let attempts = maximum_attempts(priority);
        let mut attempt = 0;
        loop {
            let ticket = self
                .acquire(origin, priority, Wait::default())
                .map_err(|_| AiError::Cancelled)?;
            let result = operation();
            finish(ticket, &result);
            let error = match result {
                Ok(value) => return Ok(value),
                Err(error) => error,
            };
            let ai = error.downcast_ref::<AiError>();
            let rate_limited = ai.is_some_and(AiError::is_rate_limit);
            let retry_after = ai.and_then(AiError::retry_after);
            attempt += 1;
            if !ai.is_some_and(AiError::is_retryable) || attempt >= attempts {
                return Err(error);
            }
            log::info!(
                "remote inference retry purpose={purpose} priority={} attempt={}/{attempts} rateLimited={rate_limited} error={error:#}",
                priority.label(),
                attempt + 1,
            );
            // A rate limit waits on the origin's cooldown in `acquire`.
            if !rate_limited {
                (self.pause)(backoff(attempt - 1, retry_after, jitter()));
            }
        }
    }
}

fn finish<T>(ticket: Ticket<'_>, result: &Result<T>) {
    let ai = result
        .as_ref()
        .err()
        .and_then(|e| e.downcast_ref::<AiError>());
    ticket.finish(
        ai.is_some_and(AiError::is_rate_limit),
        ai.and_then(AiError::retry_after),
    );
}

#[cfg(test)]
impl Gate {
    fn cooldown_remaining(&self, origin: &str) -> f64 {
        let now = self.now();
        self.state
            .lock()
            .queues
            .get(origin)
            .map_or(0.0, |queue| (queue.cooldown_until - now).max(0.0))
    }

    fn snapshot(&self, origin: &str) -> (usize, usize) {
        let state = self.state.lock();
        state
            .queues
            .get(origin)
            .map_or((0, 0), |queue| (queue.in_flight.len(), queue.waiters.len()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;
    use std::sync::atomic::AtomicU32;

    fn queue() -> RequestQueue {
        RequestQueue::new(Limits::default())
    }

    #[test]
    fn processing_runs_two_at_a_time_and_background_one() {
        let mut queue = queue();
        queue.enqueue(1, Priority::Background);
        queue.enqueue(2, Priority::Background);
        queue.enqueue(3, Priority::Pipeline);
        queue.enqueue(4, Priority::Pipeline);
        // Notes first, in order, and they fill both slots.
        assert_eq!(queue.admit(0.0), [3, 4]);
        assert_eq!(queue.waiters.len(), 2);
        queue.finish(3, false, None, 0.0);
        // One background request may take the slot; the second waits.
        assert_eq!(queue.admit(0.0), [1]);
        queue.finish(4, false, None, 0.0);
        assert_eq!(queue.admit(0.0), Vec::<u64>::new());
        queue.finish(1, false, None, 0.0);
        assert_eq!(queue.admit(0.0), [2]);
    }

    #[test]
    fn someone_waiting_on_the_answer_is_never_queued_behind_processing() {
        let mut queue = queue();
        queue.enqueue(1, Priority::Pipeline);
        queue.enqueue(2, Priority::Pipeline);
        queue.enqueue(3, Priority::Pipeline);
        assert_eq!(queue.admit(0.0), [1, 2]);
        queue.enqueue(4, Priority::Interactive);
        queue.enqueue(5, Priority::Agent);
        assert_eq!(queue.admit(0.0), [4, 5]);
        assert_eq!(queue.waiters.len(), 1);
    }

    #[test]
    fn a_blocked_background_waiter_holds_back_nobody() {
        let mut queue = queue();
        queue.enqueue(1, Priority::Background);
        assert_eq!(queue.admit(0.0), [1]);
        queue.enqueue(2, Priority::Background);
        queue.enqueue(3, Priority::Pipeline);
        assert_eq!(queue.admit(0.0), [3]);
        assert_eq!(queue.waiters[0].id, 2);
    }

    #[test]
    fn nothing_starts_during_a_cooldown_and_the_pause_grows() {
        let mut queue = queue();
        queue.enqueue(1, Priority::Interactive);
        queue.admit(0.0);
        queue.finish(1, true, None, 10.0);
        assert_eq!(queue.cooldown_until, 12.0);
        queue.enqueue(2, Priority::Interactive);
        assert!(queue.admit(11.0).is_empty());
        assert_eq!(queue.admit(12.0), [2]);
        queue.finish(2, true, None, 12.0);
        assert_eq!(queue.cooldown_until, 16.0);
        assert_eq!(queue.consecutive_rate_limits, 2);
        queue.enqueue(3, Priority::Interactive);
        assert_eq!(queue.admit(16.0), [3]);
        queue.finish(3, false, None, 16.0);
        assert_eq!(queue.consecutive_rate_limits, 0);
    }

    #[test]
    fn cooldowns_follow_the_server_up_to_a_minute() {
        assert_eq!(cooldown(1, None), 2.0);
        assert_eq!(cooldown(3, None), 8.0);
        assert_eq!(cooldown(30, None), 60.0);
        assert_eq!(cooldown(1, Some(5.0)), 5.0);
        assert_eq!(cooldown(1, Some(0.0)), 1.0);
        assert_eq!(cooldown(1, Some(600.0)), 60.0);
    }

    #[test]
    fn retry_limits_match_the_mac() {
        assert_eq!(maximum_attempts(Priority::Interactive), 2);
        assert_eq!(maximum_attempts(Priority::Agent), 2);
        assert_eq!(maximum_attempts(Priority::Pipeline), 5);
        assert_eq!(maximum_attempts(Priority::Background), 4);
        let none = Duration::ZERO;
        assert_eq!(backoff(0, None, none), Duration::from_secs(2));
        assert_eq!(backoff(2, None, none), Duration::from_secs(8));
        assert_eq!(backoff(10, None, none), Duration::from_secs(60));
        assert_eq!(
            backoff(0, Some(Duration::from_secs(5)), none),
            Duration::from_secs(5)
        );
        assert_eq!(
            backoff(0, Some(Duration::from_secs(600)), none),
            Duration::from_secs(60)
        );
    }

    #[test]
    fn origins_are_the_same_for_think_and_autocomplete_urls() {
        assert_eq!(origin("HTTPS://Example.com/v1/"), "https://example.com");
        assert_eq!(origin("http://10.0.0.2:11434"), "http://10.0.0.2:11434");
        assert_eq!(
            origin("https://example.com/v1"),
            origin("https://example.com/api/other")
        );
    }

    fn gate() -> Gate {
        Gate::new(Limits::default(), |_| {})
    }

    #[test]
    fn a_waiter_gets_the_slot_when_it_frees() {
        let gate = Arc::new(gate());
        let first = gate
            .acquire("o", Priority::Background, Wait::default())
            .ok();
        assert!(first.is_some());
        let waiter = {
            let gate = gate.clone();
            std::thread::spawn(move || {
                let ticket = gate
                    .acquire("o", Priority::Background, Wait::default())
                    .ok()
                    .unwrap();
                drop(ticket);
            })
        };
        while gate.snapshot("o") != (1, 1) {
            std::thread::sleep(Duration::from_millis(1));
        }
        drop(first);
        waiter.join().unwrap();
        assert_eq!(gate.snapshot("o"), (0, 0));
    }

    #[test]
    fn origins_do_not_share_slots() {
        let gate = gate();
        let _held = gate
            .acquire("a", Priority::Background, Wait::default())
            .ok();
        let at = Instant::now() + Duration::from_secs(5);
        let other = gate.acquire(
            "b",
            Priority::Background,
            Wait {
                cancel: None,
                deadline: Some(at),
            },
        );
        assert!(other.is_ok());
    }

    #[test]
    fn a_cancelled_or_late_waiter_leaves_the_line() {
        let gate = gate();
        let _held = gate
            .acquire("o", Priority::Background, Wait::default())
            .ok();
        let cancel = AtomicBool::new(true);
        let result = gate.acquire(
            "o",
            Priority::Background,
            Wait {
                cancel: Some(&cancel),
                deadline: None,
            },
        );
        assert_eq!(result.err(), Some(Blocked::Cancelled));
        let result = gate.acquire(
            "o",
            Priority::Background,
            Wait {
                cancel: None,
                deadline: Some(Instant::now()),
            },
        );
        assert_eq!(result.err(), Some(Blocked::TimedOut));
        assert_eq!(gate.snapshot("o"), (1, 0));
    }

    fn status(code: u16, retry_after: Option<Duration>) -> anyhow::Error {
        AiError::HttpStatus {
            code,
            detail: String::new(),
            retry_after,
        }
        .into()
    }

    #[test]
    fn replays_stop_at_the_priority_limit() {
        let gate = gate();
        let calls = AtomicU32::new(0);
        let result: Result<()> = gate.replaying("o", Priority::Interactive, "test", || {
            calls.fetch_add(1, Ordering::Relaxed);
            Err(status(503, None))
        });
        assert!(result.is_err());
        assert_eq!(calls.load(Ordering::Relaxed), 2);
        let calls = AtomicU32::new(0);
        let result: Result<()> = gate.replaying("o", Priority::Pipeline, "test", || {
            calls.fetch_add(1, Ordering::Relaxed);
            Err(status(500, None))
        });
        assert!(result.is_err());
        assert_eq!(calls.load(Ordering::Relaxed), 5);
    }

    #[test]
    fn errors_that_a_replay_cannot_help_are_not_replayed() {
        let gate = gate();
        let calls = AtomicU32::new(0);
        let result: Result<()> = gate.replaying("o", Priority::Pipeline, "test", || {
            calls.fetch_add(1, Ordering::Relaxed);
            Err(status(401, None))
        });
        assert!(result.is_err());
        assert_eq!(calls.load(Ordering::Relaxed), 1);
    }

    #[test]
    fn a_rate_limit_pauses_every_caller_of_the_origin() {
        let gate = gate();
        let result: Result<()> = gate.once("o", Priority::Interactive, None, || {
            Err(status(429, Some(Duration::from_secs(30))))
        });
        assert!(result.is_err());
        assert!(gate.cooldown_remaining("o") > 25.0);
        // Autocomplete has a deadline, and gives up rather than wait it out.
        let waited = gate.acquire(
            "o",
            Priority::Interactive,
            Wait {
                cancel: None,
                deadline: Some(Instant::now() + Duration::from_millis(60)),
            },
        );
        assert_eq!(waited.err(), Some(Blocked::TimedOut));
        // Another origin isn't paused.
        assert_eq!(gate.cooldown_remaining("other"), 0.0);
    }

    #[test]
    fn a_replay_of_a_rate_limit_waits_out_the_cooldown_instead_of_sleeping() {
        let gate = Gate::new(Limits::default(), |_| {
            panic!("a rate limit doesn't take the backoff pause")
        });
        let calls = AtomicU32::new(0);
        let started = Instant::now();
        let result = gate.replaying("o", Priority::Interactive, "test", || {
            if calls.fetch_add(1, Ordering::Relaxed) == 0 {
                Err(status(429, Some(Duration::from_secs(1))))
            } else {
                Ok("done")
            }
        });
        assert_eq!(result.unwrap(), "done");
        assert!(started.elapsed() >= Duration::from_millis(900));
    }
}
