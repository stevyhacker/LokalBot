//! Request/response correlation over pi's JSONL stream (`PiRPCClient.swift`).
//!
//! The process reader feeds every stdout record to [`RpcClient::handle_line`].
//! A `response` whose id matches a pending request completes it; everything
//! else is forwarded as an event. Results are delivered to the session's
//! sink, never awaited, so one slow acknowledgement (pi's `abort` waits for
//! idle) can never stop approvals or other events from being handled.

use std::collections::HashMap;
use std::sync::{Arc, Weak};
use std::time::{Duration, Instant};

use parking_lot::{Condvar, Mutex};

use crate::messages::{PiCommand, PiEvent, PiResponse};

pub const REQUEST_TIMEOUT: Duration = Duration::from_secs(30);

#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum RpcError {
    #[error("The agent process exited unexpectedly.")]
    TransportClosed,
    #[error("The agent did not acknowledge request {0} in time.")]
    RequestTimedOut(String),
    #[error("Duplicate agent request id: {0}.")]
    DuplicateRequestId(String),
    #[error("An RPC request command did not contain an id.")]
    InvalidCommand,
    #[error("{0}")]
    Send(String),
}

/// Where the client writes command lines (the pi process, or a test fake).
pub trait LineTransport: Send + Sync {
    fn send_line(&self, line: &str) -> Result<(), String>;
}

/// What the client reports to its session.
#[derive(Debug)]
pub enum ClientMessage<T> {
    Event(PiEvent),
    Response {
        tag: T,
        result: Result<PiResponse, RpcError>,
    },
    /// The stream ended; every pending request already failed.
    Closed {
        stderr_tail: Vec<String>,
    },
}

pub type Sink<T> = Arc<dyn Fn(ClientMessage<T>) + Send + Sync>;

struct Pending<T> {
    tag: T,
    deadline: Instant,
}

struct State<T> {
    pending: HashMap<String, Pending<T>>,
    terminal: Option<RpcError>,
}

struct Inner<T> {
    transport: Mutex<Option<Arc<dyn LineTransport>>>,
    state: Mutex<State<T>>,
    wake: Condvar,
    sink: Sink<T>,
    timeout: Duration,
}

/// Cheap to clone; every clone is the same client.
pub struct RpcClient<T: Send + 'static> {
    inner: Arc<Inner<T>>,
}

impl<T: Send + 'static> Clone for RpcClient<T> {
    fn clone(&self) -> Self {
        Self {
            inner: self.inner.clone(),
        }
    }
}

impl<T: Send + 'static> RpcClient<T> {
    pub fn new(sink: Sink<T>, timeout: Duration) -> Self {
        let client = Self {
            inner: Arc::new(Inner {
                transport: Mutex::new(None),
                state: Mutex::new(State {
                    pending: HashMap::new(),
                    terminal: None,
                }),
                wake: Condvar::new(),
                sink,
                timeout,
            }),
        };
        let weak = Arc::downgrade(&client.inner);
        let _ = std::thread::Builder::new()
            .name("lokalbot-pi-rpc-timeouts".into())
            .spawn(move || watch_timeouts(weak));
        client
    }

    /// Set once the process is running (the reader may already be feeding lines).
    pub fn attach(&self, transport: Arc<dyn LineTransport>) {
        *self.inner.transport.lock() = Some(transport);
    }

    /// Sends `command`; its acknowledgement (or failure) arrives at the sink
    /// as a `Response` carrying `tag`.
    pub fn request(&self, command: PiCommand, tag: T) {
        let Some(id) = command.id().map(str::to_string) else {
            (self.inner.sink)(ClientMessage::Response {
                tag,
                result: Err(RpcError::InvalidCommand),
            });
            return;
        };
        {
            let mut state = self.inner.state.lock();
            if let Some(terminal) = state.terminal.clone() {
                drop(state);
                (self.inner.sink)(ClientMessage::Response {
                    tag,
                    result: Err(terminal),
                });
                return;
            }
            if state.pending.contains_key(&id) {
                drop(state);
                (self.inner.sink)(ClientMessage::Response {
                    tag,
                    result: Err(RpcError::DuplicateRequestId(id)),
                });
                return;
            }
            state.pending.insert(
                id.clone(),
                Pending {
                    tag,
                    deadline: Instant::now() + self.inner.timeout,
                },
            );
        }
        self.inner.wake.notify_all();
        if let Err(error) = self.write(&command) {
            self.fail(&id, RpcError::Send(error));
        }
    }

    /// For lines pi never acknowledges (`extension_ui_response`).
    pub fn send(&self, command: &PiCommand) -> Result<(), RpcError> {
        if let Some(terminal) = self.inner.state.lock().terminal.clone() {
            return Err(terminal);
        }
        self.write(command).map_err(RpcError::Send)
    }

    fn write(&self, command: &PiCommand) -> Result<(), String> {
        let transport = self.inner.transport.lock().clone();
        match transport {
            Some(transport) => transport.send_line(&command.json_line()),
            None => Err("The agent process is not running.".into()),
        }
    }

    fn fail(&self, id: &str, error: RpcError) {
        let pending = self.inner.state.lock().pending.remove(id);
        if let Some(pending) = pending {
            (self.inner.sink)(ClientMessage::Response {
                tag: pending.tag,
                result: Err(error),
            });
        }
    }

    /// One stdout record.
    pub fn handle_line(&self, line: &str) {
        let Some(event) = PiEvent::decode(line) else {
            (self.inner.sink)(ClientMessage::Event(PiEvent::ExtensionError {
                message: "The agent emitted a malformed RPC frame; it was ignored.".into(),
            }));
            return;
        };
        if let PiEvent::Response(response) = &event
            && let Some(id) = response.id.as_deref()
        {
            let pending = self.inner.state.lock().pending.remove(id);
            if let Some(pending) = pending {
                (self.inner.sink)(ClientMessage::Response {
                    tag: pending.tag,
                    result: Ok(response.clone()),
                });
                return;
            }
        }
        (self.inner.sink)(ClientMessage::Event(event));
    }

    /// The stream ended: fail what is pending and report the close once.
    pub fn handle_close(&self, stderr_tail: Vec<String>) {
        let pending = {
            let mut state = self.inner.state.lock();
            if state.terminal.is_some() {
                return;
            }
            state.terminal = Some(RpcError::TransportClosed);
            std::mem::take(&mut state.pending)
        };
        self.inner.wake.notify_all();
        *self.inner.transport.lock() = None;
        for (_, pending) in pending {
            (self.inner.sink)(ClientMessage::Response {
                tag: pending.tag,
                result: Err(RpcError::TransportClosed),
            });
        }
        (self.inner.sink)(ClientMessage::Closed { stderr_tail });
    }

    pub fn pending_count(&self) -> usize {
        self.inner.state.lock().pending.len()
    }
}

fn watch_timeouts<T: Send + 'static>(weak: Weak<Inner<T>>) {
    loop {
        let Some(inner) = weak.upgrade() else {
            return;
        };
        let expired: Vec<(String, T)> = {
            let mut state = inner.state.lock();
            if state.terminal.is_some() {
                return;
            }
            let now = Instant::now();
            let ids: Vec<String> = state
                .pending
                .iter()
                .filter(|(_, p)| p.deadline <= now)
                .map(|(id, _)| id.clone())
                .collect();
            let expired: Vec<(String, T)> = ids
                .into_iter()
                .filter_map(|id| state.pending.remove(&id).map(|p| (id, p.tag)))
                .collect();
            if expired.is_empty() {
                let next = state
                    .pending
                    .values()
                    .map(|p| p.deadline)
                    .min()
                    .map(|deadline| deadline.saturating_duration_since(now))
                    .unwrap_or(Duration::from_secs(1))
                    .min(Duration::from_secs(1));
                inner
                    .wake
                    .wait_for(&mut state, next.max(Duration::from_millis(10)));
            }
            expired
        };
        for (id, tag) in expired {
            (inner.sink)(ClientMessage::Response {
                tag,
                result: Err(RpcError::RequestTimedOut(id)),
            });
        }
        drop(inner);
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    /// Records every line written.
    #[derive(Default)]
    pub struct RecordingTransport {
        pub lines: Mutex<Vec<String>>,
        pub fail: Mutex<bool>,
    }

    impl LineTransport for RecordingTransport {
        fn send_line(&self, line: &str) -> Result<(), String> {
            if *self.fail.lock() {
                return Err("broken pipe".into());
            }
            self.lines.lock().push(line.to_string());
            Ok(())
        }
    }

    fn client(
        timeout: Duration,
    ) -> (
        RpcClient<&'static str>,
        Arc<RecordingTransport>,
        async_channel::Receiver<ClientMessage<&'static str>>,
    ) {
        let (tx, rx) = async_channel::unbounded();
        let sink: Sink<&'static str> = Arc::new(move |message| {
            let _ = tx.send_blocking(message);
        });
        let client = RpcClient::new(sink, timeout);
        let transport = Arc::new(RecordingTransport::default());
        client.attach(transport.clone());
        (client, transport, rx)
    }

    #[test]
    fn request_resolves_on_matching_id_and_events_flow_through() {
        let (client, transport, rx) = client(REQUEST_TIMEOUT);
        client.request(PiCommand::GetState { id: "s1".into() }, "state");
        assert!(transport.lines.lock()[0].contains("\"get_state\""));
        client.handle_line(r#"{"type":"agent_start"}"#);
        client.handle_line(r#"{"id":"other","type":"response","command":"x","success":true}"#);
        client.handle_line(r#"{"id":"s1","type":"response","command":"get_state","success":true}"#);
        assert!(matches!(
            rx.recv_blocking().unwrap(),
            ClientMessage::Event(PiEvent::AgentStart)
        ));
        // An unmatched response is an event, never stolen by another request.
        assert!(matches!(
            rx.recv_blocking().unwrap(),
            ClientMessage::Event(PiEvent::Response(_))
        ));
        match rx.recv_blocking().unwrap() {
            ClientMessage::Response { tag, result } => {
                assert_eq!(tag, "state");
                assert!(result.unwrap().success);
            }
            other => panic!("unexpected {other:?}"),
        }
        assert_eq!(client.pending_count(), 0);
    }

    #[test]
    fn transport_close_fails_pending_requests_and_later_ones() {
        let (client, _transport, rx) = client(REQUEST_TIMEOUT);
        client.request(PiCommand::Abort { id: "a1".into() }, "abort");
        client.handle_close(vec!["boom".into()]);
        assert!(matches!(
            rx.recv_blocking().unwrap(),
            ClientMessage::Response {
                tag: "abort",
                result: Err(RpcError::TransportClosed)
            }
        ));
        assert!(
            matches!(rx.recv_blocking().unwrap(), ClientMessage::Closed { stderr_tail } if stderr_tail == vec!["boom"])
        );
        client.request(PiCommand::GetState { id: "s2".into() }, "late");
        assert!(matches!(
            rx.recv_blocking().unwrap(),
            ClientMessage::Response {
                tag: "late",
                result: Err(RpcError::TransportClosed)
            }
        ));
        assert_eq!(
            client.send(&PiCommand::UiCancelResponse {
                request_id: "x".into()
            }),
            Err(RpcError::TransportClosed)
        );
    }

    #[test]
    fn ui_responses_are_written_without_waiting() {
        let (client, transport, _rx) = client(REQUEST_TIMEOUT);
        client
            .send(&PiCommand::UiConfirmResponse {
                request_id: "u1".into(),
                confirmed: true,
            })
            .unwrap();
        assert!(transport.lines.lock()[0].contains("extension_ui_response"));
        assert_eq!(client.pending_count(), 0);
    }

    #[test]
    fn requests_time_out_and_late_responses_become_events() {
        let (client, _transport, rx) = client(Duration::from_millis(100));
        client.request(PiCommand::GetState { id: "slow".into() }, "slow");
        match rx.recv_blocking().unwrap() {
            ClientMessage::Response { tag, result } => {
                assert_eq!(tag, "slow");
                assert_eq!(result, Err(RpcError::RequestTimedOut("slow".into())));
            }
            other => panic!("unexpected {other:?}"),
        }
        client
            .handle_line(r#"{"id":"slow","type":"response","command":"get_state","success":true}"#);
        assert!(matches!(
            rx.recv_blocking().unwrap(),
            ClientMessage::Event(PiEvent::Response(_))
        ));
    }

    #[test]
    fn duplicate_ids_and_send_failures_are_reported() {
        let (client, transport, rx) = client(REQUEST_TIMEOUT);
        client.request(PiCommand::GetState { id: "d".into() }, "first");
        client.request(PiCommand::GetState { id: "d".into() }, "second");
        assert!(matches!(
            rx.recv_blocking().unwrap(),
            ClientMessage::Response {
                tag: "second",
                result: Err(RpcError::DuplicateRequestId(_))
            }
        ));
        *transport.fail.lock() = true;
        client.request(PiCommand::GetState { id: "e".into() }, "broken");
        assert!(matches!(
            rx.recv_blocking().unwrap(),
            ClientMessage::Response {
                tag: "broken",
                result: Err(RpcError::Send(_))
            }
        ));
    }

    #[test]
    fn malformed_frames_become_visible_protocol_errors() {
        let (client, _transport, rx) = client(REQUEST_TIMEOUT);
        client.handle_line("not json");
        assert!(matches!(
            rx.recv_blocking().unwrap(),
            ClientMessage::Event(PiEvent::ExtensionError { message }) if message.contains("malformed")
        ));
    }
}
