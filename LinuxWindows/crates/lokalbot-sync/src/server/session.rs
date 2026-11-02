//! One accepted connection: the preface, then either pairing or a session.
//!
//! A session has two threads. The reader turns packets into events; the
//! worker (this connection's thread) handles events one at a time: hello,
//! catch-up, ops, questions, live pushes, pings and revocation.

use std::net::{SocketAddr, TcpStream};
use std::sync::Arc;
use std::sync::atomic::AtomicBool;
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::time::{Duration, Instant};

use serde_json::Value;

use super::{AskSink, OpOutcome, ServerInner};
use crate::error::{Result, SyncError};
use crate::keys::KEY_LEN;
use crate::messages::{Envelope, Message};
use crate::net::unmap;
use crate::records::now_iso;
use crate::wire::{
    Channel, Inbox, PAIRING_ID_LEN, PREFACE_PAIRING, PREFACE_SESSION, PROTOCOL_VERSION, RawConn,
    SCHEMA_VERSION, Tuning, pairing_handshake, remote_static, session_handshake,
};

/// How long the host waits for the phone to close after a final message, so
/// closing never cuts off data the phone has not read yet.
const LINGER: Duration = Duration::from_secs(2);

pub(crate) enum Event {
    Message(Message),
    /// The phone sent something unreadable.
    Invalid(String),
    /// The Mac published or removed a record.
    Changed,
    /// The Mac removed this device.
    Revoke,
    /// The answer to this session's question is complete.
    AskFinished,
    /// The connection closed, went quiet, or the server stopped.
    Closed,
}

pub(super) fn serve(inner: &Arc<ServerInner>, stream: TcpStream, peer: SocketAddr) -> Result<()> {
    let tuning = inner.tuning();
    let mut conn = RawConn::new(stream, &tuning)?;
    let preface = conn.recv_packet()?;
    match preface.as_slice() {
        [PREFACE_PAIRING, pairing_id @ ..] if pairing_id.len() == PAIRING_ID_LEN => {
            serve_pairing(inner, conn, pairing_id, &tuning)
        }
        [PREFACE_SESSION] => serve_session(inner, conn, peer, &tuning),
        _ => Ok(()),
    }
}

fn serve_pairing(
    inner: &Arc<ServerInner>,
    mut conn: RawConn,
    pairing_id: &[u8],
    tuning: &Tuning,
) -> Result<()> {
    // An unknown, expired or cancelled offer gets no handshake at all.
    let Some(offer) = inner.offer_for(pairing_id) else {
        return Ok(());
    };
    let mut handshake = pairing_handshake(false, &inner.private_key, &offer.secret)?;
    conn.read_handshake(&mut handshake)?; // -> e
    conn.write_handshake(&mut handshake)?; // <- e, ee, s, es
    conn.read_handshake(&mut handshake)?; // -> s, se, psk (fails on a wrong secret)
    let device_key = remote_static(&handshake)?;
    if !inner.consume_offer(pairing_id) {
        return Ok(());
    }
    let (channel, mut inbox) = conn.into_channel(handshake.into_transport_mode()?)?;
    let result = pair_device(inner, &channel, &mut inbox, &device_key, tuning);
    channel.close();
    result
}

fn pair_device(
    inner: &Arc<ServerInner>,
    channel: &Channel,
    inbox: &mut Inbox,
    device_key: &[u8; KEY_LEN],
    tuning: &Tuning,
) -> Result<()> {
    let deadline = Instant::now() + tuning.handshake_timeout;
    let (device_id, device_name, platform) = loop {
        match inbox.recv(channel, tuning, Some(deadline))? {
            Message::PairRequest {
                device_id,
                device_name,
                platform,
            } => break (device_id, device_name, platform),
            Message::Ping | Message::Unknown => {}
            _ => return Err(SyncError::protocol("Expected a pairing request.")),
        }
    };
    if device_id.trim().is_empty() || !matches!(platform.as_str(), "ios" | "ipados" | "android") {
        let _ = channel.send(&Message::Error {
            code: "bad_request".into(),
            message:
                "The pairing request needs a device id and a platform of ios, ipados or android."
                    .into(),
        });
        return Err(SyncError::protocol("Malformed pairing request."));
    }
    let approved = await_approval(inner, channel, &device_name, &platform, tuning);
    if approved {
        inner.store.lock().add_device(
            &device_id,
            &device_name,
            &platform,
            device_key,
            &now_iso(),
        )?;
    }
    channel.send(&Message::PairResult {
        approved,
        mac_name: inner.mac_name.clone(),
    })?;
    if approved {
        inner.delegate.devices_changed();
    }
    linger_inbox(channel, inbox, tuning);
    Ok(())
}

/// Asks the delegate on its own thread, so the connection keeps pinging
/// while the person decides. No answer within the timeout is a refusal.
fn await_approval(
    inner: &Arc<ServerInner>,
    channel: &Channel,
    name: &str,
    platform: &str,
    tuning: &Tuning,
) -> bool {
    let (answer, answered) = mpsc::channel();
    let delegate = Arc::clone(&inner.delegate);
    let (name, platform) = (name.to_owned(), platform.to_owned());
    let spawned = std::thread::Builder::new()
        .name("lokalbot-sync-approval".into())
        .spawn(move || {
            let _ = answer.send(delegate.approve_pairing(name, platform));
        });
    if spawned.is_err() {
        return false;
    }
    let deadline = Instant::now() + tuning.approval_timeout;
    loop {
        let left = deadline.saturating_duration_since(Instant::now());
        if left.is_zero() {
            return false;
        }
        match answered.recv_timeout(tuning.tick().min(left)) {
            Ok(approved) => return approved,
            Err(RecvTimeoutError::Disconnected) => return false,
            Err(RecvTimeoutError::Timeout) => {
                if channel.since_last_sent() >= tuning.ping_interval
                    && channel.send(&Message::Ping).is_err()
                {
                    return false;
                }
            }
        }
    }
}

fn serve_session(
    inner: &Arc<ServerInner>,
    mut conn: RawConn,
    peer: SocketAddr,
    tuning: &Tuning,
) -> Result<()> {
    let mut handshake = session_handshake(&inner.private_key, None)?;
    conn.read_handshake(&mut handshake)?; // -> e, es, s, ss
    let device_key = remote_static(&handshake)?;
    let (device, revoked) = {
        let store = inner.store.lock();
        let device = store.device_by_key(&device_key)?;
        let revoked = device.is_none() && store.is_revoked(&device_key)?;
        (device, revoked)
    };
    if device.is_none() && !revoked {
        // A key this Mac never paired learns nothing, not even that it
        // reached LokalBot.
        return Ok(());
    }
    conn.write_handshake(&mut handshake)?; // <- e, ee, se
    let (channel, mut inbox) = conn.into_channel(handshake.into_transport_mode()?)?;
    let Some(device) = device else {
        let _ = channel.send(&Message::Revoked);
        linger_inbox(&channel, &mut inbox, tuning);
        channel.close();
        return Ok(());
    };
    run_session(inner, channel, inbox, device.device_id, peer, tuning)
}

fn run_session(
    inner: &Arc<ServerInner>,
    channel: Arc<Channel>,
    mut inbox: Inbox,
    device_id: String,
    peer: SocketAddr,
    tuning: &Tuning,
) -> Result<()> {
    let (events, received) = mpsc::channel();
    let session_id = inner.register(&device_id, events.clone(), Arc::clone(&channel));
    // `stop` closes the sessions it finds; one that finished its handshake
    // just after must not live on.
    if !inner.running() {
        inner.unregister(session_id);
        channel.close();
        return Ok(());
    }
    let address = unmap(peer.ip()).to_string();
    let _ = inner
        .store
        .lock()
        .touch_device(&device_id, &now_iso(), Some(&address));
    inner.delegate.devices_changed();

    let reader = {
        let channel = Arc::clone(&channel);
        let events = events.clone();
        let tuning = tuning.clone();
        std::thread::Builder::new()
            .name("lokalbot-sync-reader".into())
            .spawn(move || read_loop(&channel, &mut inbox, &events, &tuning))?
    };
    let mut worker = Worker {
        inner,
        channel: Arc::clone(&channel),
        events,
        received,
        tuning: tuning.clone(),
        sent_seq: 0,
        syncing: false,
        asked: false,
    };
    let result = worker.run();
    channel.close();
    inner.unregister(session_id);
    let _ = inner
        .store
        .lock()
        .touch_device(&device_id, &now_iso(), None);
    inner.delegate.devices_changed();
    let _ = reader.join();
    result
}

fn read_loop(channel: &Channel, inbox: &mut Inbox, events: &Sender<Event>, tuning: &Tuning) {
    loop {
        match inbox.poll(channel) {
            Ok(Some(message)) => {
                if events.send(Event::Message(message)).is_err() {
                    return;
                }
            }
            Ok(None) => {
                if channel.is_closed() {
                    return;
                }
                if inbox.idle() >= tuning.idle_timeout {
                    let _ = events.send(Event::Closed);
                    return;
                }
            }
            Err(SyncError::Protocol(message)) => {
                let _ = events.send(Event::Invalid(message));
                return;
            }
            Err(_) => {
                let _ = events.send(Event::Closed);
                return;
            }
        }
    }
}

/// Waits briefly for the phone to close before the host does.
fn linger_inbox(channel: &Channel, inbox: &mut Inbox, tuning: &Tuning) {
    let deadline = Instant::now() + LINGER;
    while let Ok(message) = inbox.recv(channel, tuning, Some(deadline)) {
        if message == Message::Bye {
            break;
        }
    }
}

struct Worker<'a> {
    inner: &'a Arc<ServerInner>,
    channel: Arc<Channel>,
    events: Sender<Event>,
    received: Receiver<Event>,
    tuning: Tuning,
    /// Every record with a seq up to this one has been sent.
    sent_seq: u64,
    syncing: bool,
    asked: bool,
}

impl Worker<'_> {
    fn run(&mut self) -> Result<()> {
        let deadline = Instant::now() + self.tuning.handshake_timeout;
        let (cursor, purpose) = loop {
            match self.next(Some(deadline)) {
                Some(Event::Message(Message::Hello {
                    protocol_version,
                    schema_version,
                    cursor,
                    purpose,
                    ..
                })) => {
                    if protocol_version > PROTOCOL_VERSION || schema_version > SCHEMA_VERSION {
                        self.fail(
                            "unsupported_version",
                            format!("This Mac speaks protocol {PROTOCOL_VERSION} and schema {SCHEMA_VERSION}."),
                        );
                        return Ok(());
                    }
                    break (cursor, purpose);
                }
                Some(
                    Event::Message(Message::Ping | Message::Unknown)
                    | Event::Changed
                    | Event::AskFinished,
                ) => {}
                Some(Event::Message(_)) => {
                    self.fail(
                        "unexpected_message",
                        "The first message must be hello.".into(),
                    );
                    return Ok(());
                }
                Some(Event::Invalid(message)) => {
                    self.fail("bad_message", message);
                    return Ok(());
                }
                Some(Event::Revoke) => {
                    self.revoke();
                    return Ok(());
                }
                Some(Event::Closed) | None => return Ok(()),
            }
        };
        let manifest = self.inner.store.lock().manifest()?;
        self.channel.send(&Message::Welcome {
            mac_name: self.inner.mac_name.clone(),
            server_time: now_iso(),
            manifest,
        })?;
        match purpose.as_str() {
            "sync" => {
                self.syncing = true;
                self.catch_up(cursor)?;
            }
            "ask" => {}
            other => {
                self.fail(
                    "unsupported_purpose",
                    format!("Unknown session purpose \"{other}\"."),
                );
                return Ok(());
            }
        }
        loop {
            match self.next(None) {
                Some(Event::Message(message)) => match message {
                    Message::Op { op } if self.syncing => self.apply(op)?,
                    Message::Ask { request } if !self.syncing && !self.asked => self.ask(request),
                    Message::Bye => return Ok(()),
                    _ => {}
                },
                Some(Event::Changed) => {
                    if self.syncing {
                        self.flush()?;
                    }
                }
                Some(Event::AskFinished) => {
                    self.linger();
                    return Ok(());
                }
                Some(Event::Invalid(message)) => {
                    self.fail("bad_message", message);
                    return Ok(());
                }
                Some(Event::Revoke) => {
                    self.revoke();
                    return Ok(());
                }
                Some(Event::Closed) | None => return Ok(()),
            }
        }
    }

    /// The next event, pinging while idle. `None` at the deadline.
    fn next(&self, deadline: Option<Instant>) -> Option<Event> {
        loop {
            let mut wait = self
                .tuning
                .ping_interval
                .saturating_sub(self.channel.since_last_sent());
            if let Some(deadline) = deadline {
                let left = deadline.saturating_duration_since(Instant::now());
                if left.is_zero() {
                    return None;
                }
                wait = wait.min(left);
            }
            match self
                .received
                .recv_timeout(wait.max(Duration::from_millis(1)))
            {
                Ok(event) => return Some(event),
                Err(RecvTimeoutError::Timeout) => {
                    if self.channel.since_last_sent() >= self.tuning.ping_interval
                        && self.channel.send(&Message::Ping).is_err()
                    {
                        return Some(Event::Closed);
                    }
                }
                Err(RecvTimeoutError::Disconnected) => return None,
            }
        }
    }

    /// Everything after the phone's cursor, newest first, ending `done: true`.
    fn catch_up(&mut self, cursor: u64) -> Result<()> {
        let (snapshot, keys) = {
            let store = self.inner.store.lock();
            let snapshot = store.current_seq()?;
            // A cursor beyond this database means it was recreated: send all.
            let cursor = if cursor > snapshot { 0 } else { cursor };
            (snapshot, store.changed_keys(cursor, snapshot)?)
        };
        self.send_records(&keys, snapshot)?;
        self.sent_seq = snapshot;
        Ok(())
    }

    /// Pushes records published since the last batch.
    fn flush(&mut self) -> Result<()> {
        let (latest, keys) = {
            let store = self.inner.store.lock();
            let latest = store.current_seq()?;
            if latest <= self.sent_seq {
                return Ok(());
            }
            (latest, store.changed_keys(self.sent_seq, latest)?)
        };
        self.send_records(&keys, latest)?;
        self.sent_seq = latest;
        Ok(())
    }

    /// Sends the records' current state in batches of at most `batch_bytes`
    /// of JSON (one larger record goes alone); the last is `done: true`.
    fn send_records(&self, keys: &[(String, String)], last_seq: u64) -> Result<()> {
        let mut batch: Vec<String> = Vec::new();
        let mut size = 0;
        for chunk in keys.chunks(64) {
            let envelopes: Vec<Envelope> = {
                let store = self.inner.store.lock();
                let mut envelopes = Vec::with_capacity(chunk.len());
                for (kind, key) in chunk {
                    envelopes.extend(store.envelope(kind, key)?);
                }
                envelopes
            };
            for envelope in envelopes {
                let json = serde_json::to_string(&envelope)
                    .map_err(|e| SyncError::protocol(e.to_string()))?;
                if !batch.is_empty() && size + json.len() > self.tuning.batch_bytes {
                    self.send_batch(&batch, last_seq, false)?;
                    batch.clear();
                    size = 0;
                }
                size += json.len() + 1;
                batch.push(json);
            }
        }
        self.send_batch(&batch, last_seq, true)
    }

    fn send_batch(&self, items: &[String], last_seq: u64, done: bool) -> Result<()> {
        let json = format!(
            r#"{{"type":"records","items":[{}],"lastSeq":{last_seq},"done":{done}}}"#,
            items.join(",")
        );
        self.channel.send_json(json.as_bytes())
    }

    /// Applies one op through the delegate, then sends the records it
    /// republished, then the op's result.
    fn apply(&mut self, op: Value) -> Result<()> {
        let Some(op_id) = op.get("opId").and_then(Value::as_str).map(str::to_owned) else {
            log::info!("companion session: ignored an op without opId");
            return Ok(());
        };
        let outcome = if op.get("type").and_then(Value::as_str) == Some("action.setStatus") {
            self.inner.delegate.apply_op(op.to_string())
        } else {
            OpOutcome {
                status: "rejected".into(),
                message: Some("This Mac does not know this kind of change.".into()),
            }
        };
        self.flush()?;
        let status = match outcome.status.as_str() {
            "applied" | "unmatched" | "rejected" => outcome.status,
            _ => "rejected".into(),
        };
        self.channel.send(&Message::OpResult {
            op_id,
            status,
            message: outcome.message,
        })
    }

    fn ask(&mut self, request: Value) {
        self.asked = true;
        let request_id = request
            .get("requestId")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_owned();
        let sink = Arc::new(AskSink {
            channel: Arc::clone(&self.channel),
            request_id: request_id.clone(),
            finished: AtomicBool::new(false),
            events: self.events.clone(),
        });
        if request_id.is_empty() {
            sink.failed("The question had no requestId.".into());
            return;
        }
        self.inner.delegate.ask(request.to_string(), sink);
    }

    fn fail(&self, code: &str, message: String) {
        let _ = self.channel.send(&Message::Error {
            code: code.into(),
            message,
        });
        self.linger();
    }

    fn revoke(&self) {
        let _ = self.channel.send(&Message::Revoked);
        self.linger();
    }

    fn linger(&self) {
        let deadline = Instant::now() + LINGER;
        while let Some(event) = self.next(Some(deadline)) {
            if matches!(event, Event::Closed | Event::Message(Message::Bye)) {
                break;
            }
        }
    }
}
