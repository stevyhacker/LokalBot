//! The Mac's end: `SyncServer` publishes records into its database and
//! serves paired devices over TCP.

mod session;
pub(crate) mod store;

use std::collections::HashMap;
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::mpsc::Sender;
use std::thread::JoinHandle;
use std::time::Duration;

use parking_lot::Mutex;
use serde_json::Value;

use crate::error::{Result, SyncError};
use crate::keys::{self, KEY_LEN};
use crate::messages::Message;
use crate::pairing::Payload;
use crate::records::{KINDS, MANIFEST, MANIFEST_KEY, iso_from_unix, now_iso, unix_now};
use crate::wire::{Channel, PAIRING_ID_LEN, Tuning};

use self::store::HostStore;

/// More simultaneous connections than any person's devices need.
const MAX_CONNECTIONS: usize = 64;

#[derive(Clone, Debug, uniffi::Record)]
pub struct ServerConfig {
    /// `<library>/companion/companion.sqlite`.
    pub db_path: String,
    pub mac_name: String,
    pub static_private_key: Vec<u8>,
    /// 17890 by default; 0 picks a free port (see `bound_port`).
    pub port: u16,
}

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct PairingOffer {
    /// `lokalbot://pair?d=…`, the text of the QR code.
    pub qr_payload: String,
    /// base64url, as `pid` in the payload.
    pub pairing_id: String,
    /// ISO 8601 UTC.
    pub expires_at: String,
}

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct PairedDevice {
    pub device_id: String,
    pub name: String,
    /// `ios`, `ipados` or `android`.
    pub platform: String,
    /// ISO 8601 UTC.
    pub paired_at: String,
    pub last_seen_at: Option<String>,
    /// The IP address of the device's last connection.
    pub last_address: Option<String>,
}

/// What became of a phone's op.
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct OpOutcome {
    /// `applied`, `unmatched` or `rejected`.
    pub status: String,
    pub message: Option<String>,
}

/// Implemented by the Mac app. Called on background threads.
#[uniffi::export(callback_interface)]
pub trait ServerDelegate: Send + Sync {
    /// Asks the person whether to pair this device. May block up to 120 s;
    /// no answer by then counts as a refusal.
    fn approve_pairing(&self, device_name: String, platform: String) -> bool;
    /// Applies a phone's op. Republish the affected records before returning;
    /// they reach the phone before the op's result.
    fn apply_op(&self, op_json: String) -> OpOutcome;
    /// Answers a question through `sink`. May return before the answer is
    /// finished; the sink works from any thread.
    fn ask(&self, request_json: String, sink: Arc<AskSink>);
    /// A device paired, was removed, connected or disconnected.
    fn devices_changed(&self);
}

/// Streams one answer back to the phone that asked. Calls after the answer
/// finished or the phone disconnected are ignored.
#[derive(uniffi::Object)]
pub struct AskSink {
    channel: Arc<Channel>,
    request_id: String,
    finished: AtomicBool,
    events: Sender<session::Event>,
}

#[uniffi::export]
impl AskSink {
    /// The next part of the answer text.
    pub fn delta(&self, text: String) {
        if self.finished.load(Ordering::SeqCst) || self.channel.is_closed() {
            return;
        }
        let _ = self.channel.send(&Message::AskDelta {
            request_id: self.request_id.clone(),
            text,
        });
    }

    /// The final answer: records.md's Ask result, as JSON.
    pub fn done(&self, result_json: String) {
        if self.finished.swap(true, Ordering::SeqCst) {
            return;
        }
        let message = match serde_json::from_str::<Value>(&result_json) {
            Ok(Value::Object(mut result)) => {
                result.insert("requestId".into(), Value::String(self.request_id.clone()));
                Message::AskDone {
                    request_id: self.request_id.clone(),
                    result: Value::Object(result),
                }
            }
            _ => Message::AskFailed {
                request_id: self.request_id.clone(),
                message: "The Mac produced an unreadable answer.".into(),
            },
        };
        let _ = self.channel.send(&message);
        let _ = self.events.send(session::Event::AskFinished);
    }

    /// The Mac could not answer.
    pub fn failed(&self, message: String) {
        if self.finished.swap(true, Ordering::SeqCst) {
            return;
        }
        let _ = self.channel.send(&Message::AskFailed {
            request_id: self.request_id.clone(),
            message,
        });
        let _ = self.events.send(session::Event::AskFinished);
    }
}

/// The open pairing offer.
#[derive(Clone)]
pub(crate) struct Offer {
    pairing_id: [u8; PAIRING_ID_LEN],
    secret: [u8; KEY_LEN],
    expires_at: i64,
}

/// A live session, as other threads see it.
struct SessionHandle {
    device_id: String,
    events: Sender<session::Event>,
    channel: Arc<Channel>,
}

#[derive(Default)]
struct Listening {
    stop: Option<Arc<AtomicBool>>,
    threads: Vec<JoinHandle<()>>,
    port: u16,
}

pub(crate) struct ServerInner {
    mac_name: String,
    configured_port: u16,
    private_key: [u8; KEY_LEN],
    public_key: [u8; KEY_LEN],
    store: Mutex<HostStore>,
    delegate: Arc<dyn ServerDelegate>,
    tuning: Mutex<Tuning>,
    loopback_only: AtomicBool,
    listening: Mutex<Listening>,
    offer: Mutex<Option<Offer>>,
    sessions: Mutex<HashMap<u64, SessionHandle>>,
    next_session: AtomicU64,
    connections: AtomicUsize,
}

/// The Mac's listener and record database.
#[derive(uniffi::Object)]
pub struct SyncServer {
    inner: Arc<ServerInner>,
}

#[uniffi::export]
impl SyncServer {
    #[uniffi::constructor]
    pub fn new(config: ServerConfig, delegate: Box<dyn ServerDelegate>) -> Result<Arc<Self>> {
        let private_key = keys::key_array(&config.static_private_key, "static private key")?;
        let public_key = keys::public_key(&private_key)?;
        let store = HostStore::open(&PathBuf::from(&config.db_path))?;
        Ok(Arc::new(Self {
            inner: Arc::new(ServerInner {
                mac_name: config.mac_name,
                configured_port: config.port,
                private_key,
                public_key,
                store: Mutex::new(store),
                delegate: Arc::from(delegate),
                tuning: Mutex::new(Tuning::default()),
                loopback_only: AtomicBool::new(false),
                listening: Mutex::new(Listening::default()),
                offer: Mutex::new(None),
                sessions: Mutex::new(HashMap::new()),
                next_session: AtomicU64::new(1),
                connections: AtomicUsize::new(0),
            }),
        }))
    }

    /// Binds `0.0.0.0:port` and `[::]:port` (either may be missing on this
    /// machine) and serves on background threads.
    pub fn start(&self) -> Result<()> {
        ServerInner::start(&self.inner)
    }

    /// Closes the listeners and every session.
    pub fn stop(&self) {
        self.inner.stop();
    }

    pub fn is_running(&self) -> bool {
        self.inner.running()
    }

    /// The port actually bound while running, else the configured one.
    pub fn bound_port(&self) -> u16 {
        self.inner.port()
    }

    /// Publishes a record body. Returns true when it changed (a new version
    /// and seq), and pushes it to connected devices.
    pub fn publish(&self, kind: String, key: String, body_json: String) -> Result<bool> {
        validate_kind_key(&kind, &key)?;
        let body: Value = serde_json::from_str(&body_json)
            .map_err(|e| SyncError::invalid(format!("The body is not JSON: {e}")))?;
        if !body.is_object() {
            return Err(SyncError::invalid("The body must be a JSON object."));
        }
        let changed = self
            .inner
            .store
            .lock()
            .publish(&kind, &key, &body, &now_iso())?
            .is_some();
        if changed {
            self.inner.broadcast(|| session::Event::Changed);
        }
        Ok(changed)
    }

    /// Replaces a record with a tombstone. Returns true if it existed.
    pub fn remove(&self, kind: String, key: String) -> Result<bool> {
        validate_kind_key(&kind, &key)?;
        let removed = self.inner.store.lock().remove(&kind, &key)?.is_some();
        if removed {
            self.inner.broadcast(|| session::Event::Changed);
        }
        Ok(removed)
    }

    /// Publishes the `manifest` record (key `library`).
    pub fn set_manifest(&self, body_json: String) -> Result<()> {
        self.publish(MANIFEST.into(), MANIFEST_KEY.into(), body_json)
            .map(|_| ())
    }

    /// Keys of the live (not deleted) records of one kind.
    pub fn record_keys(&self, kind: String) -> Result<Vec<String>> {
        self.inner.store.lock().record_keys(&kind)
    }

    pub fn current_seq(&self) -> Result<u64> {
        self.inner.store.lock().current_seq()
    }

    /// Opens a pairing offer, replacing any open one. `addresses` go into the
    /// code; an empty list uses `local_addresses()`.
    pub fn begin_pairing(&self, addresses: Vec<String>) -> PairingOffer {
        let lifetime = self.inner.tuning.lock().offer_lifetime_secs;
        let offer = Offer {
            pairing_id: keys::random_bytes(),
            secret: keys::random_bytes(),
            expires_at: unix_now() + lifetime,
        };
        let addresses = if addresses.is_empty() {
            crate::net::local_addresses()
        } else {
            addresses
        };
        let payload = Payload {
            mac_name: self.inner.mac_name.clone(),
            mac_key: self.inner.public_key,
            addresses,
            port: self.inner.port(),
            pairing_id: offer.pairing_id,
            psk: offer.secret,
            expires_at: offer.expires_at,
        };
        *self.inner.offer.lock() = Some(offer.clone());
        PairingOffer {
            qr_payload: payload.encode(),
            pairing_id: keys::b64url(&offer.pairing_id),
            expires_at: iso_from_unix(offer.expires_at),
        }
    }

    pub fn cancel_pairing(&self) {
        *self.inner.offer.lock() = None;
    }

    pub fn paired_devices(&self) -> Result<Vec<PairedDevice>> {
        self.inner.store.lock().devices()
    }

    /// Forgets a device's key. A live session from it is told `revoked` and
    /// closes; later connections are refused the same way.
    pub fn remove_device(&self, device_id: String) -> Result<()> {
        let removed = self
            .inner
            .store
            .lock()
            .remove_device(&device_id, &now_iso())?;
        let sessions: Vec<Sender<session::Event>> = self
            .inner
            .sessions
            .lock()
            .values()
            .filter(|handle| handle.device_id == device_id)
            .map(|handle| handle.events.clone())
            .collect();
        for events in sessions {
            let _ = events.send(session::Event::Revoke);
        }
        if removed {
            self.inner.delegate.devices_changed();
        }
        Ok(())
    }

    /// Devices with an open session.
    pub fn connected_device_ids(&self) -> Vec<String> {
        let mut ids: Vec<String> = self
            .inner
            .sessions
            .lock()
            .values()
            .map(|handle| handle.device_id.clone())
            .collect();
        ids.sort();
        ids.dedup();
        ids
    }
}

/// Rust-only control for development hosts.
impl SyncServer {
    /// Listens on 127.0.0.1 and ::1 only. Takes effect at the next `start`.
    pub fn set_loopback_only(&self, loopback_only: bool) {
        self.inner
            .loopback_only
            .store(loopback_only, Ordering::SeqCst);
    }
}

/// Controls for tests.
#[cfg(test)]
impl SyncServer {
    pub(crate) fn set_tuning(&self, tuning: Tuning) {
        *self.inner.tuning.lock() = tuning;
    }

    pub(crate) fn expire_offer(&self) {
        if let Some(offer) = self.inner.offer.lock().as_mut() {
            offer.expires_at = unix_now() - 1;
        }
    }

    pub(crate) fn public_key(&self) -> [u8; KEY_LEN] {
        self.inner.public_key
    }

    pub(crate) fn store(&self) -> parking_lot::MutexGuard<'_, HostStore> {
        self.inner.store.lock()
    }
}

impl Drop for SyncServer {
    fn drop(&mut self) {
        self.inner.stop();
    }
}

fn validate_kind_key(kind: &str, key: &str) -> Result<()> {
    if !KINDS.contains(&kind) {
        return Err(SyncError::invalid(format!(
            "Unknown record kind \"{kind}\"."
        )));
    }
    if key.is_empty() {
        return Err(SyncError::invalid("A record key cannot be empty."));
    }
    Ok(())
}

impl ServerInner {
    fn running(&self) -> bool {
        self.listening.lock().stop.is_some()
    }

    fn port(&self) -> u16 {
        let listening = self.listening.lock();
        if listening.stop.is_some() {
            listening.port
        } else {
            self.configured_port
        }
    }

    fn tuning(&self) -> Tuning {
        self.tuning.lock().clone()
    }

    fn start(this: &Arc<Self>) -> Result<()> {
        let mut listening = this.listening.lock();
        if listening.stop.is_some() {
            return Ok(());
        }
        let listeners = bind(
            this.configured_port,
            this.loopback_only.load(Ordering::SeqCst),
        )?;
        let port = listeners[0].local_addr()?.port();
        let stop = Arc::new(AtomicBool::new(false));
        let mut threads = Vec::new();
        for listener in listeners {
            listener.set_nonblocking(true)?;
            let inner = Arc::clone(this);
            let stop = Arc::clone(&stop);
            threads.push(
                std::thread::Builder::new()
                    .name("lokalbot-sync-listener".into())
                    .spawn(move || inner.accept_loop(&listener, &stop))?,
            );
        }
        *listening = Listening {
            stop: Some(stop),
            threads,
            port,
        };
        Ok(())
    }

    fn stop(&self) {
        let (stop, threads) = {
            let mut listening = self.listening.lock();
            (
                listening.stop.take(),
                std::mem::take(&mut listening.threads),
            )
        };
        if let Some(stop) = stop {
            stop.store(true, Ordering::SeqCst);
        }
        for thread in threads {
            let _ = thread.join();
        }
        let sessions: Vec<(Sender<session::Event>, Arc<Channel>)> = self
            .sessions
            .lock()
            .values()
            .map(|handle| (handle.events.clone(), Arc::clone(&handle.channel)))
            .collect();
        for (events, channel) in sessions {
            let _ = events.send(session::Event::Closed);
            channel.close();
        }
    }

    fn accept_loop(self: &Arc<Self>, listener: &TcpListener, stop: &AtomicBool) {
        while !stop.load(Ordering::SeqCst) {
            match listener.accept() {
                Ok((stream, peer)) => self.accept(stream, peer),
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                    std::thread::sleep(Duration::from_millis(25));
                }
                Err(e) => {
                    log::warn!("companion listener: accept failed: {e}");
                    std::thread::sleep(Duration::from_millis(100));
                }
            }
        }
    }

    fn accept(self: &Arc<Self>, stream: TcpStream, peer: SocketAddr) {
        if !crate::net::is_allowed_peer(peer.ip()) {
            log::info!("companion listener: refused {peer}, outside the allowed address ranges");
            return;
        }
        if self.connections.fetch_add(1, Ordering::SeqCst) >= MAX_CONNECTIONS {
            self.connections.fetch_sub(1, Ordering::SeqCst);
            return;
        }
        let inner = Arc::clone(self);
        let spawned = std::thread::Builder::new()
            .name("lokalbot-sync-connection".into())
            .spawn(move || {
                if let Err(e) = session::serve(&inner, stream, peer) {
                    log::debug!("companion connection from {peer} ended: {e}");
                }
                inner.connections.fetch_sub(1, Ordering::SeqCst);
            });
        if spawned.is_err() {
            self.connections.fetch_sub(1, Ordering::SeqCst);
        }
    }

    fn broadcast(&self, event: impl Fn() -> session::Event) {
        for handle in self.sessions.lock().values() {
            let _ = handle.events.send(event());
        }
    }

    fn register(
        &self,
        device_id: &str,
        events: Sender<session::Event>,
        channel: Arc<Channel>,
    ) -> u64 {
        let id = self.next_session.fetch_add(1, Ordering::SeqCst);
        self.sessions.lock().insert(
            id,
            SessionHandle {
                device_id: device_id.to_owned(),
                events,
                channel,
            },
        );
        id
    }

    fn unregister(&self, id: u64) {
        self.sessions.lock().remove(&id);
    }

    /// Takes the open offer if `pairing_id` names it and it has not expired.
    fn offer_for(&self, pairing_id: &[u8]) -> Option<Offer> {
        self.offer
            .lock()
            .clone()
            .filter(|offer| offer.pairing_id == pairing_id && offer.expires_at > unix_now())
    }

    /// Consumes the offer after a successful handshake; false if another
    /// handshake got there first or it was cancelled.
    fn consume_offer(&self, pairing_id: &[u8]) -> bool {
        let mut slot = self.offer.lock();
        if slot
            .as_ref()
            .is_some_and(|offer| offer.pairing_id == pairing_id)
        {
            *slot = None;
            true
        } else {
            false
        }
    }
}

/// Listeners for IPv6 and IPv4, IPv6 first. Where `[::]` is dual-stack
/// (Linux, macOS) the IPv4 bind may fail with "address in use" and the IPv6
/// listener serves both; where IPv6 is missing, IPv4 alone serves.
fn bind(port: u16, loopback_only: bool) -> Result<Vec<TcpListener>> {
    let (v6, v4) = if loopback_only {
        ("[::1]", "127.0.0.1")
    } else {
        ("[::]", "0.0.0.0")
    };
    let mut listeners = Vec::new();
    let mut errors = Vec::new();
    match TcpListener::bind(format!("{v6}:{port}")) {
        Ok(listener) => listeners.push(listener),
        Err(e) => errors.push(format!("{v6}: {e}")),
    }
    let port = match listeners.first() {
        Some(listener) => listener.local_addr()?.port(),
        None => port,
    };
    match TcpListener::bind(format!("{v4}:{port}")) {
        Ok(listener) => listeners.push(listener),
        Err(e) => errors.push(format!("{v4}: {e}")),
    }
    if listeners.is_empty() {
        return Err(SyncError::io(format!(
            "Couldn't listen on port {port}: {}",
            errors.join("; ")
        )));
    }
    if !errors.is_empty() {
        log::info!("companion listener: {}", errors.join("; "));
    }
    Ok(listeners)
}
