//! Owns the sync host while sharing is on (`CompanionHost.swift`): this
//! computer's static key, the listener, the mDNS announcement, the publisher
//! that keeps records current, and the device list Settings shows.

use std::collections::HashSet;
use std::net::IpAddr;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::Weak;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use anyhow::Result;
use chrono::{DateTime, NaiveDate, Utc};
use crossbeam_channel::{Receiver, RecvTimeoutError, Sender, bounded};
use lokalbot_core::{Library, Settings};
use lokalbot_sync::{AskSink, OpOutcome, ServerConfig, ServerDelegate, SyncServer, UploadOutcome};
use parking_lot::{Mutex, RwLock};
use uuid::Uuid;

use super::advertise::{Advertiser, MdnsAdvertiser};
use super::ask::{AskEngine, AskResponder};
use super::ops;
use super::publisher::{Context, Publisher, RecordSink};
use super::recordings;
use super::sharing::{Sharing, today};
use super::{
    CompanionCommand, CompanionDevice, CompanionPairing, CompanionSnapshot, CompanionStatus,
    PairingRequest,
};

/// How often the host looks for a new day, moved network or changed notes.
const TICK: Duration = Duration::from_secs(60);
/// Today's record is rebuilt this often while there is activity.
const REFRESH_MINUTES: i64 = 15;
/// An unanswered prompt expires with the device's pairing request.
const APPROVAL_TIMEOUT: Duration = Duration::from_secs(120);
const REPUBLISH_TIMEOUT: Duration = Duration::from_secs(30);
/// A burst of edits costs one pass.
const PUBLISH_DEBOUNCE: Duration = Duration::from_secs(2);

/// Set to 1 by development runs: listens on loopback only and never announces.
const LOOPBACK_VARIABLE: &str = "LOKALBOT_COMPANION_LOOPBACK";

pub(super) enum HostMessage {
    Apply(Sharing),
    Command(CompanionCommand),
    EvidenceChanged(Vec<NaiveDate>),
    LibraryChanged,
    DayChanged(NaiveDate),
    DevicesChanged,
    ApprovalChanged(Option<PairingRequest>),
    Stop,
}

/// What the host needs from the machine, so its lifecycle can run in tests
/// without the credential store, a real interface, or the local network.
pub(super) trait Environment: Send + Sync {
    fn settings(&self) -> Settings;
    /// Only the private half of the key is kept.
    fn static_key(&self) -> Result<[u8; 32]>;
    /// This machine's private LAN and Tailscale addresses.
    fn addresses(&self) -> Vec<String>;
    fn computer_name(&self) -> String;
    /// Listen on loopback only.
    fn loopback_only(&self) -> bool;
    /// Whether the local network announcement may run at all.
    fn announces(&self) -> bool;
    fn advertiser(&self) -> Box<dyn Advertiser>;
    /// A device's recording is now this meeting: queue it for processing and
    /// show it, wherever the person is in the app.
    fn recording_stored(&self, meeting_id: Uuid);
}

pub(super) struct LiveEnvironment {
    pub shared: Arc<crate::Shared>,
    pub pipeline: crate::pipeline::Pipeline,
}

impl Environment for LiveEnvironment {
    fn settings(&self) -> Settings {
        self.shared.settings()
    }

    fn static_key(&self) -> Result<[u8; 32]> {
        crate::secrets::companion_static_key()
    }

    fn addresses(&self) -> Vec<String> {
        if self.loopback_only() {
            return vec!["127.0.0.1".to_string()];
        }
        lokalbot_sync::local_addresses()
    }

    fn computer_name(&self) -> String {
        computer_name()
    }

    fn loopback_only(&self) -> bool {
        loopback_requested(std::env::var(LOOPBACK_VARIABLE).ok().as_deref())
    }

    fn announces(&self) -> bool {
        !self.loopback_only()
    }

    fn advertiser(&self) -> Box<dyn Advertiser> {
        Box::new(MdnsAdvertiser::default())
    }

    /// Queued like a recording finished on this computer, which waits for
    /// missing models rather than downloading them with nobody here to see it.
    fn recording_stored(&self, meeting_id: Uuid) {
        let summarize = self.shared.settings().auto_summarize;
        if !self.pipeline.enqueue(meeting_id, true, summarize, false) {
            log::warn!("device recording not queued meeting={meeting_id}");
        }
        self.shared.emit(crate::EngineEvent::LibraryChanged);
    }
}

pub(super) fn loopback_requested(value: Option<&str>) -> bool {
    value.is_some_and(|value| !value.is_empty() && value != "0")
}

/// The computer's name, as the pairing code and phones show it. It's never
/// announced on the network.
pub(super) fn computer_name() -> String {
    configured_computer_name()
        .map(|name| name.trim().to_string())
        .filter(|name| !name.is_empty())
        .unwrap_or_else(|| "Computer".to_string())
}

#[cfg(windows)]
fn configured_computer_name() -> Option<String> {
    std::env::var("COMPUTERNAME").ok()
}

#[cfg(not(windows))]
fn configured_computer_name() -> Option<String> {
    let pretty = std::fs::read_to_string("/etc/machine-info")
        .ok()
        .and_then(|info| pretty_hostname(&info));
    pretty.or_else(|| std::fs::read_to_string("/proc/sys/kernel/hostname").ok())
}

#[cfg_attr(windows, allow(dead_code))]
pub(super) fn pretty_hostname(machine_info: &str) -> Option<String> {
    machine_info.lines().find_map(|line| {
        let value = line.trim().strip_prefix("PRETTY_HOSTNAME=")?;
        Some(value.trim_matches(|c| c == '"' || c == '\'').to_string())
    })
}

impl RecordSink for SyncServer {
    fn publish(&self, kind: &str, key: &str, body_json: &str) -> Result<bool> {
        Ok(SyncServer::publish(
            self,
            kind.into(),
            key.into(),
            body_json.into(),
        )?)
    }

    fn remove(&self, kind: &str, key: &str) -> Result<bool> {
        Ok(SyncServer::remove(self, kind.into(), key.into())?)
    }

    fn record_keys(&self, kind: &str) -> Result<Vec<String>> {
        Ok(SyncServer::record_keys(self, kind.into())?)
    }

    fn set_manifest(&self, body_json: &str) -> Result<()> {
        Ok(SyncServer::set_manifest(self, body_json.into())?)
    }
}

/// What the sync host's callbacks reach, from its own threads.
struct Bridge {
    library: Library,
    environment: Arc<dyn Environment>,
    host: Sender<HostMessage>,
    responder: AskResponder,
    publisher: RwLock<Option<Arc<Publisher>>>,
    approval: Mutex<Option<(u64, Sender<bool>)>>,
    next_approval: AtomicU64,
    /// Outlives the sync host, which restarts when sharing is switched off and
    /// on while an import goes on.
    importing: Mutex<HashSet<String>>,
}

impl Bridge {
    /// Blocks until the person answers or the prompt expires.
    fn approve(&self, device_name: &str, platform: &str) -> bool {
        let (answer, answered) = bounded(1);
        let id = self.next_approval.fetch_add(1, Ordering::SeqCst);
        // A newer request drops the older answer channel, which refuses it.
        *self.approval.lock() = Some((id, answer));
        let _ = self
            .host
            .send(HostMessage::ApprovalChanged(Some(PairingRequest {
                id,
                device_name: super::device_display_name(device_name),
                platform: platform.to_string(),
            })));
        let allowed = answered.recv_timeout(APPROVAL_TIMEOUT).unwrap_or(false);
        let mut approval = self.approval.lock();
        if approval.as_ref().is_some_and(|(current, _)| *current == id) {
            *approval = None;
            let _ = self.host.send(HostMessage::ApprovalChanged(None));
        }
        allowed
    }

    fn answer_approval(&self, id: u64, allow: bool) {
        if let Some((current, answer)) = self.approval.lock().as_ref()
            && *current == id
        {
            let _ = answer.send(allow);
        }
    }

    fn refuse_approval(&self) {
        if let Some((_, answer)) = self.approval.lock().take() {
            let _ = answer.send(false);
        }
    }
}

pub(super) struct Delegate {
    bridge: Weak<Bridge>,
}

impl ServerDelegate for Delegate {
    fn approve_pairing(&self, device_name: String, platform: String) -> bool {
        self.bridge
            .upgrade()
            .is_some_and(|bridge| bridge.approve(&device_name, &platform))
    }

    fn apply_op(&self, op_json: String) -> OpOutcome {
        let turned_off = || OpOutcome {
            status: "rejected".into(),
            message: Some("Sharing is turned off on your computer.".into()),
        };
        let Some(bridge) = self.bridge.upgrade() else {
            return turned_off();
        };
        let Some(publisher) = bridge.publisher.read().clone() else {
            return turned_off();
        };
        let outcome = ops::apply(&bridge.library, &op_json);
        // The changed records reach the device before the op's result.
        if outcome.result.status == "applied"
            && let Some(meeting_id) = outcome.meeting_id
        {
            publisher.republish_now(meeting_id, REPUBLISH_TIMEOUT);
        }
        outcome.result
    }

    fn ask(&self, request_json: String, sink: Arc<AskSink>) {
        let Some(bridge) = self.bridge.upgrade() else {
            sink.failed("Sharing with phones and tablets is turned off on your computer.".into());
            return;
        };
        if bridge.publisher.read().is_none() {
            sink.failed("Sharing with phones and tablets is turned off on your computer.".into());
            return;
        }
        let sharing = Sharing::new(&bridge.environment.settings());
        bridge.responder.answer(&request_json, sharing, sink);
    }

    fn devices_changed(&self) {
        if let Some(bridge) = self.bridge.upgrade() {
            let _ = bridge.host.send(HostMessage::DevicesChanged);
        }
    }

    fn accepts_recordings(&self) -> bool {
        self.bridge.upgrade().is_some_and(|bridge| {
            let sharing = Sharing::new(&bridge.environment.settings());
            bridge.publisher.read().is_some() && sharing.enabled && sharing.accepts_recordings
        })
    }

    fn receive_recording(&self, recording_json: String, file_path: String) -> UploadOutcome {
        // The sync host keeps a whole file, so waiting costs no second transfer.
        let turned_off = || {
            recordings::deferred("Sharing with phones and tablets is turned off on your computer.")
        };
        let Some(bridge) = self.bridge.upgrade() else {
            return turned_off();
        };
        let Some(publisher) = bridge.publisher.read().clone() else {
            return turned_off();
        };
        let sharing = Sharing::new(&bridge.environment.settings());
        if !sharing.enabled {
            return turned_off();
        }
        if !sharing.accepts_recordings {
            return recordings::deferred(
                "This computer isn't accepting recordings. Turn on \"Accept recordings from my devices\" in its settings.",
            );
        }
        let id = serde_json::from_str::<serde_json::Value>(&recording_json)
            .ok()
            .and_then(|recording| recording["id"].as_str().map(str::to_owned))
            .unwrap_or_default();
        if !bridge.importing.lock().insert(id.clone()) {
            return recordings::deferred("This computer is already importing this recording.");
        }
        let received = recordings::receive(
            &bridge.library,
            &recording_json,
            Path::new(&file_path),
            Utc::now(),
        );
        bridge.importing.lock().remove(&id);
        if let Some(meeting_id) = received.new_meeting {
            bridge.environment.recording_stored(meeting_id);
            // Its record is there for the sync that follows the upload.
            publisher.republish_now(meeting_id, REPUBLISH_TIMEOUT);
        }
        received.outcome
    }
}

struct Running {
    server: Arc<SyncServer>,
    publisher: Arc<Publisher>,
    fingerprint: String,
    sharing: Sharing,
}

pub(super) struct Host {
    library: Library,
    environment: Arc<dyn Environment>,
    bridge: Arc<Bridge>,
    emit: Box<dyn Fn(CompanionSnapshot) + Send>,
    advertiser: Box<dyn Advertiser>,
    /// What is being announced, so a tick restarts it only when that changes.
    announced: Option<(u16, Vec<String>)>,
    running: Option<Running>,
    snapshot: CompanionSnapshot,
    /// What Settings last heard, so a tick that changed nothing stays quiet.
    emitted: Option<CompanionSnapshot>,
    reconciled_day: Option<NaiveDate>,
    last_refresh: DateTime<Utc>,
}

impl Host {
    pub fn new(
        library: Library,
        environment: Arc<dyn Environment>,
        engine: Arc<dyn AskEngine>,
        sender: Sender<HostMessage>,
        emit: Box<dyn Fn(CompanionSnapshot) + Send>,
    ) -> Self {
        let advertiser = environment.advertiser();
        let bridge = Arc::new(Bridge {
            library: library.clone(),
            environment: environment.clone(),
            host: sender,
            responder: AskResponder::new(library.clone(), engine),
            publisher: RwLock::new(None),
            approval: Mutex::new(None),
            next_approval: AtomicU64::new(1),
            importing: Mutex::new(HashSet::new()),
        });
        Self {
            library,
            environment,
            bridge,
            emit,
            advertiser,
            announced: None,
            running: None,
            snapshot: CompanionSnapshot::default(),
            emitted: None,
            reconciled_day: None,
            last_refresh: Utc::now(),
        }
    }

    pub fn run(mut self, messages: Receiver<HostMessage>) {
        loop {
            match messages.recv_timeout(TICK) {
                Ok(HostMessage::Stop) | Err(RecvTimeoutError::Disconnected) => break,
                Ok(message) => self.handle(message),
                Err(RecvTimeoutError::Timeout) => self.tick(),
            }
        }
        self.stop();
    }

    fn handle(&mut self, message: HostMessage) {
        match message {
            HostMessage::Apply(sharing) => self.apply(sharing),
            HostMessage::Command(command) => self.command(command),
            HostMessage::EvidenceChanged(days) => {
                if let Some(running) = &self.running {
                    running.publisher.evidence_changed(&days);
                }
            }
            HostMessage::LibraryChanged => {
                if let Some(running) = &self.running {
                    running.publisher.library_changed();
                }
            }
            HostMessage::DayChanged(day) => {
                if let Some(running) = &self.running {
                    running.publisher.day_changed(day);
                }
            }
            HostMessage::DevicesChanged => self.refresh_devices(),
            HostMessage::ApprovalChanged(request) => {
                if self.running.is_some() || request.is_none() {
                    self.snapshot.approval = request;
                    self.publish_snapshot();
                }
            }
            HostMessage::Stop => {}
        }
    }

    // ------------------------------------------------------------ lifecycle

    /// Start, reconfigure, or stop to match the settings.
    pub fn apply(&mut self, sharing: Sharing) {
        if !sharing.enabled {
            self.stop();
            // Nothing can finish arriving, so audio on its way has no reason to
            // stay. The devices still have their copies.
            let _ = std::fs::remove_dir_all(self.uploads_dir());
            return;
        }
        let Some(running) = &mut self.running else {
            self.start(sharing);
            return;
        };
        if running.sharing.port != sharing.port {
            self.stop();
            self.start(sharing);
            return;
        }
        running.publisher.update(Context {
            sharing,
            mac_name: self.environment.computer_name(),
        });
        running.sharing = sharing;
        self.update_announcement();
        self.publish_snapshot();
    }

    pub fn stop(&mut self) {
        self.advertiser.stop();
        self.announced = None;
        self.bridge.responder.cancel_all();
        self.bridge.refuse_approval();
        *self.bridge.publisher.write() = None;
        let was_running = self.running.take();
        let was_off = was_running.is_none() && self.snapshot.status == CompanionStatus::Off;
        if let Some(running) = was_running {
            running.publisher.stop();
            running.server.stop();
        }
        self.snapshot = CompanionSnapshot::default();
        if !was_off {
            self.publish_snapshot();
        }
    }

    fn start(&mut self, sharing: Sharing) {
        self.snapshot.status = CompanionStatus::Starting;
        self.snapshot.action_error = None;
        self.publish_snapshot();
        match self.open(sharing) {
            Ok(running) => {
                let port = running.server.bound_port();
                log::info!("companion host listening port={port}");
                self.snapshot.status = CompanionStatus::Listening { port };
                running.publisher.reconcile_all();
                self.reconciled_day = Some(today());
                self.last_refresh = Utc::now();
                *self.bridge.publisher.write() = Some(running.publisher.clone());
                self.running = Some(running);
                self.update_announcement();
                self.refresh_devices();
            }
            Err(err) => {
                let message = format!("{err:#}");
                log::warn!("companion host failed to start: {message}");
                self.snapshot.status = CompanionStatus::Failed(message);
                self.publish_snapshot();
            }
        }
    }

    fn open(&self, sharing: Sharing) -> Result<Running> {
        let key = self.environment.static_key().map_err(|err| {
            anyhow::anyhow!(lokalbot_i18n::format(
                "LokalBot could not read or save its sharing key in the system credential store ({detail}).",
                &[("detail", format!("{err:#}"))],
            ))
        })?;
        let database = self.database_path();
        if let Some(folder) = database.parent() {
            create_private_folder(folder)?;
        }
        let name = self.environment.computer_name();
        let delegate = Delegate {
            bridge: Arc::downgrade(&self.bridge),
        };
        let server = SyncServer::new(
            ServerConfig {
                db_path: database.to_string_lossy().into_owned(),
                mac_name: name.clone(),
                static_private_key: key.to_vec(),
                port: sharing.port,
            },
            Box::new(delegate),
        )?;
        server.set_loopback_only(self.environment.loopback_only());
        server.start()?;
        let public_key = lokalbot_sync::public_key_for(key.to_vec())?;
        let publisher = Arc::new(Publisher::start(
            self.library.clone(),
            server.clone(),
            Context {
                sharing,
                mac_name: name,
            },
            PUBLISH_DEBOUNCE,
        ));
        Ok(Running {
            server,
            publisher,
            fingerprint: lokalbot_sync::key_fingerprint(public_key),
            sharing,
        })
    }

    fn uploads_dir(&self) -> PathBuf {
        self.database_path().with_file_name("uploads")
    }

    fn database_path(&self) -> PathBuf {
        self.library
            .paths()
            .root()
            .join("companion")
            .join("companion.sqlite")
    }

    /// What the sync host calls, for tests of the answers themselves.
    #[cfg(test)]
    pub fn delegate(&self) -> Delegate {
        Delegate {
            bridge: Arc::downgrade(&self.bridge),
        }
    }

    /// Today's record while there is activity, and a full reconcile once a
    /// day, which also withdraws records that left the history window.
    fn tick(&mut self) {
        let Some(running) = &self.running else {
            return;
        };
        let now = Utc::now();
        let day = today();
        if self.reconciled_day != Some(day) {
            self.reconciled_day = Some(day);
            self.last_refresh = now;
            running.publisher.reconcile_all();
        } else {
            running.publisher.check_for_changes();
            if now - self.last_refresh >= chrono::Duration::minutes(REFRESH_MINUTES) {
                self.last_refresh = now;
                running.publisher.library_changed();
                running
                    .publisher
                    .refresh_today_if_active(chrono::Duration::minutes(REFRESH_MINUTES));
            }
        }
        self.update_announcement();
        self.publish_snapshot();
    }

    fn update_announcement(&mut self) {
        let addresses = self.environment.addresses();
        self.snapshot.addresses = addresses.clone();
        let wanted = self.running.as_ref().and_then(|running| {
            let port = match self.snapshot.status {
                CompanionStatus::Listening { port } => port,
                _ => return None,
            };
            (running.sharing.advertises && self.environment.announces())
                .then(|| (port, routable(&addresses), running.fingerprint.clone()))
        });
        let Some((port, addresses, fingerprint)) = wanted else {
            self.advertiser.stop();
            self.announced = None;
            self.snapshot.discovery_error = None;
            return;
        };
        let target = (port, addresses);
        if self.announced.as_ref() == Some(&target) {
            return;
        }
        match self.advertiser.start(port, &fingerprint, &target.1) {
            Ok(()) => {
                self.announced = Some(target);
                self.snapshot.discovery_error = None;
            }
            Err(err) => {
                // Devices paired before still try the addresses they saved.
                log::warn!("companion mDNS could not start: {err:#}");
                self.announced = None;
                self.snapshot.discovery_error = Some(format!("{err:#}"));
            }
        }
    }

    // -------------------------------------------------------------- devices

    fn command(&mut self, command: CompanionCommand) {
        match command {
            CompanionCommand::Enable => {}
            CompanionCommand::BeginPairing => self.begin_pairing(),
            CompanionCommand::CancelPairing => {
                self.snapshot.pairing = None;
                if let Some(running) = &self.running {
                    running.server.cancel_pairing();
                }
                self.publish_snapshot();
            }
            CompanionCommand::RemoveDevice(id) => self.remove_device(id),
            CompanionCommand::AnswerPairing { id, allow } => {
                self.bridge.answer_approval(id, allow);
            }
        }
    }

    fn begin_pairing(&mut self) {
        let Some(running) = &self.running else {
            return;
        };
        self.snapshot.action_error = None;
        let addresses = self.environment.addresses();
        self.snapshot.addresses = addresses.clone();
        let offer = running.server.begin_pairing(addresses);
        let expires_at = DateTime::parse_from_rfc3339(&offer.expires_at)
            .map(|at| at.with_timezone(&Utc))
            .unwrap_or_else(|_| Utc::now());
        self.snapshot.pairing = Some(CompanionPairing {
            qr_payload: offer.qr_payload,
            expires_at,
        });
        self.publish_snapshot();
    }

    fn remove_device(&mut self, id: String) {
        let Some(running) = &self.running else {
            return;
        };
        self.snapshot.action_error = None;
        if let Err(err) = running.server.remove_device(id) {
            self.snapshot.action_error = Some(err.to_string());
        }
        self.refresh_devices();
    }

    fn refresh_devices(&mut self) {
        let Some(running) = &self.running else {
            return;
        };
        let mut devices: Vec<CompanionDevice> = running
            .server
            .paired_devices()
            .unwrap_or_else(|err| {
                log::warn!("companion devices could not be read: {err}");
                Vec::new()
            })
            .into_iter()
            .map(|device| CompanionDevice {
                id: device.device_id,
                name: device.name,
                platform: device.platform,
                paired_at: parse_instant(&device.paired_at),
                last_seen_at: device.last_seen_at.as_deref().and_then(parse_instant),
                last_address: device.last_address,
            })
            .collect();
        devices.sort_by_key(|device| std::cmp::Reverse(device.paired_at));
        // A successful pairing consumes the offer.
        if devices.len() > self.snapshot.devices.len() {
            self.snapshot.pairing = None;
        }
        self.snapshot.devices = devices;
        self.snapshot.connected_device_ids =
            running.server.connected_device_ids().into_iter().collect();
        self.publish_snapshot();
    }

    fn publish_snapshot(&mut self) {
        if self.emitted.as_ref() != Some(&self.snapshot) {
            self.emitted = Some(self.snapshot.clone());
            (self.emit)(self.snapshot.clone());
        }
    }
}

/// The addresses worth announcing: real IP addresses, in the order given.
fn routable(addresses: &[String]) -> Vec<String> {
    addresses
        .iter()
        .filter(|address| address.parse::<IpAddr>().is_ok())
        .cloned()
        .collect()
}

fn parse_instant(value: &str) -> Option<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(value)
        .ok()
        .map(|at| at.with_timezone(&Utc))
}

fn create_private_folder(folder: &std::path::Path) -> Result<()> {
    std::fs::create_dir_all(folder)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt as _;
        std::fs::set_permissions(folder, std::fs::Permissions::from_mode(0o700))?;
    }
    Ok(())
}
