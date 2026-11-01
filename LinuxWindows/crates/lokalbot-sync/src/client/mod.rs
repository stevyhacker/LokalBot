//! The phone's end: `SyncClient` pairs with a Mac, keeps a local copy of
//! its records, and asks it questions.

mod queries;
mod search;
mod store;

use std::collections::HashSet;
use std::net::{SocketAddr, TcpStream};
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Instant;

use parking_lot::Mutex;
use serde_json::{Value, json};

use crate::error::{Result, SyncError};
use crate::keys::{self, KEY_LEN};
use crate::messages::{Envelope, Message};
use crate::net;
use crate::pairing::Payload;
use crate::records::{MEETING, local_today, now_iso, str_field, unix_now};
use crate::wire::{
    Channel, Inbox, PREFACE_PAIRING, PREFACE_SESSION, PROTOCOL_VERSION, RawConn, SCHEMA_VERSION,
    Tuning, pairing_handshake, remote_static, session_handshake,
};

pub use self::queries::ActionFilter;
pub use self::search::SearchHit;
#[cfg(test)]
pub(crate) use self::search::cjk as search_cjk;
use self::store::{ClientStore, Pairing};

/// A code this many seconds past its expiry on this device's clock is
/// refused without trying; the Mac's clock decides the rest.
const EXPIRY_GRACE_SECS: i64 = 120;

#[derive(Clone, Debug, uniffi::Record)]
pub struct ClientConfig {
    pub db_path: String,
    /// A UUID the app keeps for this installation.
    pub device_id: String,
    pub device_name: String,
    /// `ios`, `ipados` or `android`.
    pub platform: String,
    pub static_private_key: Vec<u8>,
}

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct PairedMac {
    pub mac_name: String,
    pub mac_key_b64: String,
    pub addresses: Vec<String>,
    pub port: u16,
    /// ISO 8601 UTC.
    pub paired_at: String,
}

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct SyncReport {
    /// Records added or updated.
    pub received: u32,
    /// Tombstones applied.
    pub deleted: u32,
    /// Ops the Mac applied.
    pub ops_applied: u32,
    pub cursor: u64,
    /// The `ip:port` that answered.
    pub address: String,
    /// ISO 8601 UTC.
    pub finished_at: String,
}

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct SyncStatus {
    pub paired: bool,
    pub last_sync_at: Option<String>,
    pub last_address: Option<String>,
    pub cursor: u64,
    pub pending_ops: u32,
    pub mac_name: Option<String>,
}

/// Receives an answer's text as the Mac writes it.
#[uniffi::export(callback_interface)]
pub trait AskListener: Send + Sync {
    fn on_delta(&self, text: String);
}

/// The phone's copy of a Mac's records and its connection to that Mac.
#[derive(uniffi::Object)]
pub struct SyncClient {
    device_id: String,
    device_name: String,
    platform: String,
    private_key: [u8; KEY_LEN],
    store: Mutex<ClientStore>,
    /// One pairing or sync at a time.
    sync_lock: Mutex<()>,
    tuning: Mutex<Tuning>,
}

/// How a pairing attempt on one address ended.
enum PairAttempt {
    /// No Noise handshake: not LokalBot, or the code is unknown or expired.
    NoHandshake,
    /// The handshake reached a Mac whose key is not the one in the code.
    WrongMac,
    /// The handshake completed; this is the outcome.
    Done(Result<String>),
}

#[uniffi::export]
impl SyncClient {
    #[uniffi::constructor]
    pub fn new(config: ClientConfig) -> Result<Arc<Self>> {
        let private_key = keys::key_array(&config.static_private_key, "static private key")?;
        if config.device_id.trim().is_empty() {
            return Err(SyncError::invalid("The device id cannot be empty."));
        }
        if !matches!(config.platform.as_str(), "ios" | "ipados" | "android") {
            return Err(SyncError::invalid(
                "The platform must be ios, ipados or android.",
            ));
        }
        let store = ClientStore::open(&PathBuf::from(&config.db_path))?;
        Ok(Arc::new(Self {
            device_id: config.device_id,
            device_name: config.device_name,
            platform: config.platform,
            private_key,
            store: Mutex::new(store),
            sync_lock: Mutex::new(()),
            tuning: Mutex::new(Tuning::default()),
        }))
    }

    // Pairing and connection

    /// Pairs with the Mac in a scanned code. Blocks until the person answers
    /// on the Mac. Replaces any earlier pairing and local data.
    pub fn pair(&self, payload: String) -> Result<PairedMac> {
        let _sync = self.sync_lock.lock();
        let payload = Payload::parse(&payload)?;
        if payload.expires_at + EXPIRY_GRACE_SECS < unix_now() {
            return Err(SyncError::PairingExpired(
                "This code has expired. Show a new one on your Mac.".into(),
            ));
        }
        let tuning = self.tuning();
        let mut reached_wrong_mac = false;
        let mut reached_mac = false;
        for (socket, stream) in connections(&payload.addresses, payload.port, &tuning) {
            match self.pair_over(stream, &payload, &tuning) {
                PairAttempt::NoHandshake => reached_mac = true,
                PairAttempt::WrongMac => reached_wrong_mac = true,
                PairAttempt::Done(result) => {
                    let mac_name = result?;
                    return self.save_pairing(&payload, mac_name, socket);
                }
            }
        }
        Err(if reached_wrong_mac {
            SyncError::crypto("The computer that answered is not the Mac in this code.")
        } else if reached_mac {
            SyncError::PairingExpired(
                "Your Mac did not accept this code. It may have expired or been used; show a new one.".into(),
            )
        } else {
            SyncError::Unreachable(
                "Couldn't reach your Mac. Check that both are on the same network or Tailscale."
                    .into(),
            )
        })
    }

    pub fn paired_mac(&self) -> Result<Option<PairedMac>> {
        Ok(self.store.lock().pairing()?.map(|pairing| PairedMac {
            mac_name: pairing.mac_name,
            mac_key_b64: pairing.mac_key,
            addresses: pairing.addresses,
            port: pairing.port,
            paired_at: pairing.paired_at,
        }))
    }

    /// Connects (`extra_addresses` first, e.g. Bonjour results, then the
    /// stored ones), sends queued ops, catches up and closes.
    pub fn sync(&self, extra_addresses: Vec<String>) -> Result<SyncReport> {
        let _sync = self.sync_lock.lock();
        let tuning = self.tuning();
        let pairing = self
            .store
            .lock()
            .pairing()?
            .ok_or_else(SyncError::not_paired)?;
        let (channel, mut inbox, address) = self.connect(&pairing, &extra_addresses, &tuning)?;
        let result = self.run_sync(&channel, &mut inbox, &tuning, &address);
        if result.is_ok() {
            let _ = channel.send(&Message::Bye);
        }
        channel.close();
        self.finish(result)
    }

    /// Erases the local copy and the pairing. The Mac is not told.
    pub fn unpair(&self) -> Result<()> {
        let _sync = self.sync_lock.lock();
        self.store.lock().wipe()
    }

    pub fn status(&self) -> Result<SyncStatus> {
        let store = self.store.lock();
        let pairing = store.pairing()?;
        let (last_sync_at, last_address) = store.last_sync()?;
        Ok(SyncStatus {
            paired: pairing.is_some(),
            last_sync_at,
            last_address,
            cursor: store.cursor()?,
            pending_ops: store.pending_op_count()?,
            mac_name: pairing.map(|p| p.mac_name),
        })
    }

    // Changes from the phone

    /// Queues an `action.setStatus` op and shows the status at once, marked
    /// pending. In the sample library the change is simply kept.
    pub fn set_action_status(
        &self,
        meeting_id: String,
        action_id: String,
        status: String,
    ) -> Result<()> {
        if !matches!(status.as_str(), "open" | "done" | "deferred") {
            return Err(SyncError::invalid(
                "The status must be open, done or deferred.",
            ));
        }
        let mut store = self.store.lock();
        let mut meeting = store
            .body(MEETING, &meeting_id)?
            .ok_or_else(|| SyncError::invalid("There is no such meeting."))?;
        let action = meeting
            .get_mut("actions")
            .and_then(Value::as_array_mut)
            .and_then(|actions| {
                actions
                    .iter_mut()
                    .find(|a| str_field(a, "id") == Some(action_id.as_str()))
            })
            .ok_or_else(|| SyncError::invalid("There is no such action item."))?;
        if store.is_sample()? && store.pairing()?.is_none() {
            action["status"] = Value::String(status);
            return store.replace_body(MEETING, &meeting_id, &meeting);
        }
        if store.pairing()?.is_none() {
            return Err(SyncError::not_paired());
        }
        let op = json!({
            "type": "action.setStatus",
            "opId": uuid::Uuid::new_v4().to_string(),
            "meetingId": meeting_id,
            "actionId": action_id,
            "actionText": str_field(action, "text").unwrap_or_default(),
            "status": status,
            "at": now_iso(),
        });
        store.queue_op(&meeting_id, &action_id, &status, &op, &now_iso())
    }

    // Questions

    /// Asks the Mac, streaming the answer's text to `listener`. Returns the
    /// result JSON (records.md, Ask) and saves it to the history.
    pub fn ask(
        &self,
        request_json: String,
        extra_addresses: Vec<String>,
        listener: Box<dyn AskListener>,
    ) -> Result<String> {
        let (request_id, request) = parse_request(&request_json)?;
        let tuning = self.tuning();
        let pairing = self
            .store
            .lock()
            .pairing()?
            .ok_or_else(SyncError::not_paired)?;
        let (channel, mut inbox, _) = self.connect(&pairing, &extra_addresses, &tuning)?;
        let result = run_ask(
            &channel,
            &mut inbox,
            &tuning,
            &self.device_id,
            &request_id,
            &request,
            &*listener,
        );
        channel.close();
        let result = self.finish(result)?;
        self.store
            .lock()
            .save_answer(&request_id, &request, &result, &now_iso())?;
        Ok(result.to_string())
    }

    /// Keeps a question for the next time the Mac is reachable.
    pub fn queue_question(&self, request_json: String) -> Result<()> {
        let (request_id, request) = parse_request(&request_json)?;
        self.store
            .lock()
            .queue_question(&request_id, &request, &now_iso())
    }

    /// Queued questions (request JSON), oldest first. `ask` removes one once
    /// it is answered.
    pub fn queued_questions(&self) -> Result<Vec<String>> {
        self.store.lock().queued_questions()
    }

    /// `{ "request": …, "result": … }` JSON, newest first; 0 = all.
    pub fn ask_history(&self, limit: u32) -> Result<Vec<String>> {
        self.store.lock().ask_history(limit)
    }

    // Reads

    pub fn manifest(&self) -> Result<Option<String>> {
        self.store.lock().manifest()
    }

    /// Meetings newest first; merged meetings are hidden. 0 = no limit.
    pub fn meetings(
        &self,
        from_day: Option<String>,
        to_day: Option<String>,
        limit: u32,
    ) -> Result<Vec<String>> {
        self.store
            .lock()
            .meetings(from_day.as_deref(), to_day.as_deref(), limit)
    }

    pub fn meeting(&self, id: String) -> Result<Option<String>> {
        self.store.lock().meeting(&id)
    }

    pub fn transcript(&self, meeting_id: String) -> Result<Option<String>> {
        self.store.lock().transcript(&meeting_id)
    }

    /// Day keys that have a record, newest first. 0 = no limit.
    pub fn days(&self, limit: u32) -> Result<Vec<String>> {
        self.store.lock().days(limit)
    }

    pub fn day(&self, date: String) -> Result<Option<String>> {
        self.store.lock().day(&date)
    }

    /// ActionRow JSON (ffi.md), overdue first by this device's date.
    pub fn actions(&self, filter: ActionFilter) -> Result<Vec<String>> {
        self.store.lock().actions(&filter, &local_today())
    }

    pub fn people(&self) -> Result<Vec<String>> {
        self.store.lock().people()
    }

    pub fn person(&self, id: String) -> Result<Option<String>> {
        self.store.lock().person(&id)
    }

    pub fn projects(&self) -> Result<Vec<String>> {
        self.store.lock().projects()
    }

    pub fn project(&self, id: String) -> Result<Option<String>> {
        self.store.lock().project(&id)
    }

    /// Full-text search. 0 = the default of 50 hits.
    pub fn search(&self, query: String, limit: u32) -> Result<Vec<SearchHit>> {
        let limit = if limit == 0 {
            50
        } else {
            (limit as usize).min(500)
        };
        search::search(&self.store.lock().db, &query, limit)
    }

    // Sample library

    /// Imports an array of envelopes (e.g. fixtures/sample-library.json) and
    /// marks the store as sample data. Returns how many records changed.
    pub fn import_records(&self, envelopes_json: String) -> Result<u32> {
        let envelopes: Vec<Envelope> = serde_json::from_str(&envelopes_json)
            .map_err(|e| SyncError::invalid(format!("Not an array of record envelopes: {e}")))?;
        let mut store = self.store.lock();
        if store.pairing()?.is_some() {
            return Err(SyncError::invalid(
                "This device is paired with a Mac; unpair it first.",
            ));
        }
        let applied = store.apply(&envelopes)?;
        store.set_sample()?;
        Ok(applied.received + applied.deleted)
    }

    pub fn is_sample(&self) -> Result<bool> {
        self.store.lock().is_sample()
    }
}

/// Controls for tests.
#[cfg(test)]
impl SyncClient {
    pub(crate) fn set_tuning(&self, tuning: Tuning) {
        *self.tuning.lock() = tuning;
    }

    pub(crate) fn actions_on(&self, filter: &ActionFilter, today: &str) -> Result<Vec<String>> {
        self.store.lock().actions(filter, today)
    }

    /// Opens a sync session and returns it after the catch-up, without
    /// closing, so tests can watch live pushes.
    pub(crate) fn open_live(&self) -> Result<(Arc<Channel>, Inbox)> {
        let tuning = self.tuning();
        let pairing = self
            .store
            .lock()
            .pairing()?
            .ok_or_else(SyncError::not_paired)?;
        let (channel, mut inbox, address) = self.connect(&pairing, &[], &tuning)?;
        let report = self.run_sync(&channel, &mut inbox, &tuning, &address);
        self.finish(report)?;
        Ok((channel, inbox))
    }

    /// A session right after the handshake; the test sends `hello` itself.
    pub(crate) fn connect_raw(&self) -> Result<(Arc<Channel>, Inbox)> {
        let tuning = self.tuning();
        let pairing = self
            .store
            .lock()
            .pairing()?
            .ok_or_else(SyncError::not_paired)?;
        let (channel, inbox, _) = self.connect(&pairing, &[], &tuning)?;
        Ok((channel, inbox))
    }

    /// A session after `hello` and `welcome`.
    pub(crate) fn open_session(&self, purpose: &str, cursor: u64) -> Result<(Arc<Channel>, Inbox)> {
        let (channel, mut inbox) = self.connect_raw()?;
        self.hello(&channel, &mut inbox, &self.tuning(), cursor, purpose)?;
        Ok((channel, inbox))
    }

    pub(crate) fn apply_batch(&self, items: &[Envelope], done_last_seq: Option<u64>) -> Result<()> {
        let mut store = self.store.lock();
        store.apply(items)?;
        if let Some(last_seq) = done_last_seq {
            let cursor = store.cursor()?.max(last_seq);
            store.set_cursor(cursor)?;
        }
        Ok(())
    }
}

impl SyncClient {
    fn tuning(&self) -> Tuning {
        self.tuning.lock().clone()
    }

    /// Wipes the local copy when the Mac revoked this device.
    fn finish<T>(&self, result: Result<T>) -> Result<T> {
        if let Err(SyncError::Revoked(_)) = &result {
            self.store.lock().wipe()?;
        }
        result
    }

    fn pair_over(&self, stream: TcpStream, payload: &Payload, tuning: &Tuning) -> PairAttempt {
        let Ok(mut conn) = RawConn::new(stream, tuning) else {
            return PairAttempt::NoHandshake;
        };
        let mut preface = vec![PREFACE_PAIRING];
        preface.extend_from_slice(&payload.pairing_id);
        let handshake = (|| -> Result<_> {
            conn.send_packet(&preface)?;
            let mut handshake = pairing_handshake(true, &self.private_key, &payload.psk)?;
            conn.write_handshake(&mut handshake)?; // -> e
            conn.read_handshake(&mut handshake)?; // <- e, ee, s, es
            Ok(handshake)
        })();
        let Ok(mut handshake) = handshake else {
            return PairAttempt::NoHandshake;
        };
        // Check the Mac's key before revealing ours in the last message.
        match remote_static(&handshake) {
            Ok(key) if key == payload.mac_key => {}
            _ => return PairAttempt::WrongMac,
        }
        let transport = (|| -> Result<_> {
            conn.write_handshake(&mut handshake)?; // -> s, se, psk
            Ok(handshake.into_transport_mode()?)
        })();
        let Ok(transport) = transport else {
            return PairAttempt::NoHandshake;
        };
        let Ok((channel, mut inbox)) = conn.into_channel(transport) else {
            return PairAttempt::NoHandshake;
        };
        let result = self.request_pairing(&channel, &mut inbox, tuning);
        let _ = channel.send(&Message::Bye);
        channel.close();
        PairAttempt::Done(result)
    }

    /// Sends the pairing request and waits for the person's answer.
    fn request_pairing(
        &self,
        channel: &Channel,
        inbox: &mut Inbox,
        tuning: &Tuning,
    ) -> Result<String> {
        // The Mac answers every request it accepted, a refusal or timeout
        // included; closing without an answer means it did not accept the
        // code (a wrong secret, or an offer that is gone).
        let not_accepted = || {
            SyncError::PairingExpired(
                "Your Mac did not accept this code. It may have expired or been used; show a new one.".into(),
            )
        };
        channel
            .send(&Message::PairRequest {
                device_id: self.device_id.clone(),
                device_name: self.device_name.clone(),
                platform: self.platform.clone(),
            })
            .map_err(|_| not_accepted())?;
        let deadline = Instant::now() + tuning.approval_timeout + tuning.handshake_timeout;
        loop {
            match inbox.recv(channel, tuning, Some(deadline)) {
                Ok(Message::PairResult {
                    approved: true,
                    mac_name,
                }) => return Ok(mac_name),
                Ok(Message::PairResult {
                    approved: false, ..
                }) => {
                    return Err(SyncError::PairingRejected(
                        "Pairing wasn't allowed on your Mac.".into(),
                    ));
                }
                Ok(Message::Error { message, .. }) => return Err(SyncError::protocol(message)),
                Ok(_) => {}
                Err(_) => return Err(not_accepted()),
            }
        }
    }

    fn save_pairing(
        &self,
        payload: &Payload,
        mac_name: String,
        socket: SocketAddr,
    ) -> Result<PairedMac> {
        let pairing = Pairing {
            mac_name: if mac_name.is_empty() {
                payload.mac_name.clone()
            } else {
                mac_name
            },
            mac_key: keys::b64url(&payload.mac_key),
            addresses: payload.addresses.clone(),
            port: payload.port,
            paired_at: now_iso(),
        };
        let store = self.store.lock();
        store.wipe()?;
        store.set_pairing(&pairing)?;
        store.set_last_address(&socket.to_string())?;
        Ok(PairedMac {
            mac_name: pairing.mac_name,
            mac_key_b64: pairing.mac_key,
            addresses: pairing.addresses,
            port: pairing.port,
            paired_at: pairing.paired_at,
        })
    }

    /// The first address that completes a session handshake.
    fn connect(
        &self,
        pairing: &Pairing,
        extra: &[String],
        tuning: &Tuning,
    ) -> Result<(Arc<Channel>, Inbox, String)> {
        let mac_key = pairing.mac_key()?;
        let (_, last_address) = self.store.lock().last_sync()?;
        let mut addresses: Vec<String> = extra.to_vec();
        addresses.extend(last_address);
        addresses.extend(pairing.addresses.iter().cloned());
        for (socket, stream) in connections(&addresses, pairing.port, tuning) {
            if let Ok((channel, inbox)) = self.session_over(stream, &mac_key, tuning) {
                return Ok((channel, inbox, socket.to_string()));
            }
        }
        Err(SyncError::Unreachable(
            "Couldn't reach your Mac. It may be asleep, or not on this network or Tailscale."
                .into(),
        ))
    }

    fn session_over(
        &self,
        stream: TcpStream,
        mac_key: &[u8; KEY_LEN],
        tuning: &Tuning,
    ) -> Result<(Arc<Channel>, Inbox)> {
        let mut conn = RawConn::new(stream, tuning)?;
        conn.send_packet(&[PREFACE_SESSION])?;
        let mut handshake = session_handshake(&self.private_key, Some(mac_key))?;
        conn.write_handshake(&mut handshake)?; // -> e, es, s, ss
        conn.read_handshake(&mut handshake)?; // <- e, ee, se
        conn.into_channel(handshake.into_transport_mode()?)
    }

    fn hello(
        &self,
        channel: &Channel,
        inbox: &mut Inbox,
        tuning: &Tuning,
        cursor: u64,
        purpose: &str,
    ) -> Result<String> {
        channel.send(&Message::Hello {
            protocol_version: PROTOCOL_VERSION,
            schema_version: crate::wire::SCHEMA_VERSION,
            device_id: self.device_id.clone(),
            cursor,
            purpose: purpose.into(),
        })?;
        let deadline = Instant::now() + tuning.handshake_timeout;
        loop {
            match inbox.recv(channel, tuning, Some(deadline))? {
                Message::Welcome { mac_name, .. } => return Ok(mac_name),
                Message::Revoked => return Err(SyncError::revoked()),
                Message::Error { code, message } => {
                    return Err(SyncError::protocol(format!("{code}: {message}")));
                }
                _ => {}
            }
        }
    }

    fn run_sync(
        &self,
        channel: &Channel,
        inbox: &mut Inbox,
        tuning: &Tuning,
        address: &str,
    ) -> Result<SyncReport> {
        let cursor = self.store.lock().cursor()?;
        let mac_name = self.hello(channel, inbox, tuning, cursor, "sync")?;
        self.update_mac_name(&mac_name)?;
        let ops = self.store.lock().take_ops_for_sending()?;
        let mut waiting: HashSet<String> = HashSet::new();
        for op in ops {
            channel.send(&Message::Op { op: op.body })?;
            waiting.insert(op.op_id);
        }
        let mut report = SyncReport {
            received: 0,
            deleted: 0,
            ops_applied: 0,
            cursor,
            address: address.to_owned(),
            finished_at: String::new(),
        };
        let mut caught_up = false;
        let mut highest_seen = cursor;
        while !caught_up || !waiting.is_empty() {
            match inbox.recv(channel, tuning, None)? {
                Message::Records {
                    items,
                    last_seq,
                    done,
                } => {
                    highest_seen = items
                        .iter()
                        .map(|item| item.seq)
                        .fold(highest_seen, u64::max);
                    let mut store = self.store.lock();
                    let applied = store.apply(&items)?;
                    report.received += applied.received;
                    report.deleted += applied.deleted;
                    if done {
                        // Only a finished batch moves the cursor, so an
                        // interrupted catch-up repeats safely.
                        let cursor = store.cursor()?.max(last_seq).max(highest_seen);
                        store.set_cursor(cursor)?;
                        report.cursor = cursor;
                        caught_up = true;
                    }
                }
                Message::OpResult {
                    op_id,
                    status,
                    message,
                } => {
                    if status == "applied" {
                        report.ops_applied += 1;
                    }
                    self.store
                        .lock()
                        .finish_op(&op_id, &status, message.as_deref(), &now_iso())?;
                    waiting.remove(&op_id);
                }
                Message::Revoked => return Err(SyncError::revoked()),
                Message::Error { code, message } => {
                    return Err(SyncError::protocol(format!("{code}: {message}")));
                }
                _ => {}
            }
        }
        report.finished_at = now_iso();
        self.store
            .lock()
            .record_sync(&report.finished_at, address)?;
        Ok(report)
    }

    fn update_mac_name(&self, mac_name: &str) -> Result<()> {
        let store = self.store.lock();
        if let Some(mut pairing) = store.pairing()?
            && !mac_name.is_empty()
            && pairing.mac_name != mac_name
        {
            pairing.mac_name = mac_name.to_owned();
            store.set_pairing(&pairing)?;
        }
        Ok(())
    }
}

fn run_ask(
    channel: &Channel,
    inbox: &mut Inbox,
    tuning: &Tuning,
    device_id: &str,
    request_id: &str,
    request: &Value,
    listener: &dyn AskListener,
) -> Result<Value> {
    channel.send(&Message::Hello {
        protocol_version: PROTOCOL_VERSION,
        schema_version: SCHEMA_VERSION,
        device_id: device_id.to_owned(),
        cursor: 0,
        purpose: "ask".into(),
    })?;
    let mut welcomed = false;
    let mut deadline = Instant::now() + tuning.handshake_timeout;
    loop {
        let message = inbox
            .recv(channel, tuning, Some(deadline))
            .map_err(|e| match e {
                SyncError::Io(_) if welcomed => SyncError::io("Your Mac took too long to answer."),
                other => other,
            })?;
        match message {
            Message::Welcome { .. } if !welcomed => {
                welcomed = true;
                channel.send(&Message::Ask {
                    request: request.clone(),
                })?;
                deadline = Instant::now() + tuning.ask_timeout;
            }
            Message::AskDelta {
                request_id: id,
                text,
            } if id == request_id => {
                listener.on_delta(text);
                deadline = Instant::now() + tuning.ask_timeout;
            }
            Message::AskDone {
                request_id: id,
                result,
            } if id == request_id => {
                let _ = channel.send(&Message::Bye);
                return Ok(result);
            }
            Message::AskFailed {
                request_id: id,
                message,
            } if id == request_id => {
                let _ = channel.send(&Message::Bye);
                return Err(SyncError::protocol(message));
            }
            Message::Revoked => return Err(SyncError::revoked()),
            Message::Error { code, message } => {
                return Err(SyncError::protocol(format!("{code}: {message}")));
            }
            _ => {}
        }
    }
}

/// The request's id and body; the request must name `requestId` and
/// `question`.
fn parse_request(request_json: &str) -> Result<(String, Value)> {
    let request: Value = serde_json::from_str(request_json)
        .map_err(|e| SyncError::invalid(format!("The question is not JSON: {e}")))?;
    let request_id = str_field(&request, "requestId")
        .filter(|id| !id.is_empty())
        .ok_or_else(|| SyncError::invalid("The question needs a requestId."))?
        .to_owned();
    if str_field(&request, "question").is_none_or(|q| q.trim().is_empty()) {
        return Err(SyncError::invalid("The question is empty."));
    }
    Ok((request_id, request))
}

/// TCP connections to `addresses` in order, each socket address tried once
/// with the connect timeout. Names resolve lazily, one address at a time.
fn connections<'a>(
    addresses: &'a [String],
    port: u16,
    tuning: &'a Tuning,
) -> impl Iterator<Item = (SocketAddr, TcpStream)> + 'a {
    let mut seen: HashSet<SocketAddr> = HashSet::new();
    addresses
        .iter()
        .flat_map(move |address| net::resolve(address, port))
        .filter(move |socket| seen.insert(*socket))
        .filter_map(move |socket| {
            net::connect(socket, tuning.connect_timeout)
                .ok()
                .map(|stream| (socket, stream))
        })
}
