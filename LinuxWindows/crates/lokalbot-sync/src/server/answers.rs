//! Answers outlive the connection that asked. A phone that locks or leaves
//! Wi-Fi drops its connection, but the Mac finishes the answer and keeps it;
//! asking again with the same `requestId` picks the answer up: the text so
//! far at once, then the rest as it arrives, or the finished result.

use std::collections::HashMap;
use std::sync::Arc;
use std::sync::mpsc::Sender;
use std::time::{Duration, Instant};

use parking_lot::Mutex;
use serde_json::Value;

use super::session::Event;
use crate::messages::Message;
use crate::wire::Channel;

/// At most this many finished answers are kept; the oldest go first.
const MAX_FINISHED: usize = 100;

/// Every answer the Mac is writing or kept, by device and request id.
#[derive(Default)]
pub(crate) struct Answers {
    entries: Mutex<HashMap<(String, String), Arc<Answer>>>,
}

impl Answers {
    /// The answer to `request_id` from this device, and whether it is new
    /// (the Mac still has to be asked). Finished answers older than
    /// `retention` are forgotten first, and failed ones are never kept, so
    /// asking again after a failure asks the Mac again.
    pub fn begin(
        &self,
        device_id: &str,
        request_id: &str,
        retention: Duration,
    ) -> (Arc<Answer>, bool) {
        let mut entries = self.entries.lock();
        entries.retain(|_, answer| !answer.expired(retention));
        let mut finished: Vec<(Instant, (String, String))> = entries
            .iter()
            .filter_map(|(key, answer)| answer.finished_at().map(|at| (at, key.clone())))
            .collect();
        if finished.len() > MAX_FINISHED {
            finished.sort();
            for (_, key) in finished.iter().take(finished.len() - MAX_FINISHED) {
                entries.remove(key);
            }
        }
        let key = (device_id.to_owned(), request_id.to_owned());
        if let Some(answer) = entries.get(&key) {
            return (Arc::clone(answer), false);
        }
        let answer = Arc::new(Answer {
            request_id: request_id.to_owned(),
            state: Mutex::new(State::default()),
        });
        entries.insert(key, Arc::clone(&answer));
        (answer, true)
    }

    /// A failed answer leaves, so the next ask starts over.
    fn forget(&self, answer: &Arc<Answer>) {
        self.entries
            .lock()
            .retain(|_, kept| !Arc::ptr_eq(kept, answer));
    }

    /// A removed device's answers go with it.
    pub fn forget_device(&self, device_id: &str) {
        self.entries
            .lock()
            .retain(|(device, _), _| device != device_id);
    }
}

pub(crate) struct Answer {
    request_id: String,
    state: Mutex<State>,
}

#[derive(Default)]
struct State {
    /// Every delta so far, joined.
    text: String,
    outcome: Option<Outcome>,
    finished_at: Option<Instant>,
    /// Sessions waiting for this answer; a closed one is dropped at the next
    /// send.
    listeners: Vec<Listener>,
}

struct Listener {
    channel: Arc<Channel>,
    events: Sender<Event>,
}

enum Outcome {
    Done(Value),
    Failed(String),
}

impl Answer {
    pub fn request_id(&self) -> &str {
        &self.request_id
    }

    /// Starts sending this answer to a session: the text so far as one
    /// `askDelta`, then each new delta, then the end. A finished answer is
    /// sent whole at once.
    pub fn attach(&self, channel: &Arc<Channel>, events: &Sender<Event>) {
        let mut state = self.state.lock();
        if !state.text.is_empty() {
            let _ = channel.send(&Message::AskDelta {
                request_id: self.request_id.clone(),
                text: state.text.clone(),
            });
        }
        if let Some(outcome) = &state.outcome {
            let _ = channel.send(&self.end_message(outcome));
            let _ = events.send(Event::AskFinished);
            return;
        }
        state.listeners.push(Listener {
            channel: Arc::clone(channel),
            events: events.clone(),
        });
    }

    pub fn delta(&self, text: String) {
        let mut state = self.state.lock();
        if state.outcome.is_some() {
            return;
        }
        state.text.push_str(&text);
        let message = Message::AskDelta {
            request_id: self.request_id.clone(),
            text,
        };
        state
            .listeners
            .retain(|listener| listener.channel.send(&message).is_ok());
    }

    /// Keeps the result and sends it to every waiting session.
    pub fn done(&self, result: Value) {
        self.end(Outcome::Done(result));
    }

    /// Tells every waiting session, then forgets the answer.
    pub fn failed(self: &Arc<Self>, answers: &Answers, message: String) {
        if self.end(Outcome::Failed(message)) {
            answers.forget(self);
        }
    }

    /// False if the answer had already ended.
    fn end(&self, outcome: Outcome) -> bool {
        let mut state = self.state.lock();
        if state.outcome.is_some() {
            return false;
        }
        let message = self.end_message(&outcome);
        state.outcome = Some(outcome);
        state.finished_at = Some(Instant::now());
        for listener in state.listeners.drain(..) {
            let _ = listener.channel.send(&message);
            let _ = listener.events.send(Event::AskFinished);
        }
        true
    }

    fn end_message(&self, outcome: &Outcome) -> Message {
        match outcome {
            Outcome::Done(result) => Message::AskDone {
                request_id: self.request_id.clone(),
                result: result.clone(),
            },
            Outcome::Failed(message) => Message::AskFailed {
                request_id: self.request_id.clone(),
                message: message.clone(),
            },
        }
    }

    fn finished_at(&self) -> Option<Instant> {
        self.state.lock().finished_at
    }

    fn expired(&self, retention: Duration) -> bool {
        self.finished_at()
            .is_some_and(|at| at.elapsed() >= retention)
    }
}
