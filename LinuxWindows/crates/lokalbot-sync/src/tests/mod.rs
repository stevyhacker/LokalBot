//! Tests for the protocol, both stores and whole sessions between an
//! in-process host and client over loopback.

mod address;
mod client_queries;
mod host_store;
mod keys;
mod pairing;
mod search;
mod session;
mod wire;

use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, OnceLock, Weak};
use std::time::Duration;

use parking_lot::Mutex;
use serde_json::Value;
use tempfile::TempDir;

use crate::wire::Tuning;
use crate::{
    AskSink, ClientConfig, OpOutcome, ServerConfig, ServerDelegate, SyncClient, SyncServer,
};

pub(crate) const FIXTURE: &str =
    include_str!("../../../../../Companion/protocol/fixtures/sample-library.json");

pub(crate) const DESIGN_REVIEW: &str = "3f6c2a10-8a4e-4d2b-9b1e-0a1b2c3d4e01";
pub(crate) const STANDUP: &str = "3f6c2a10-8a4e-4d2b-9b1e-0a1b2c3d4e02";

pub(crate) fn fixture() -> Vec<Value> {
    serde_json::from_str::<Vec<Value>>(FIXTURE).expect("the fixture is a JSON array")
}

// Dates come from the fixture rather than being written into the tests, so
// moving the sample library in time needs no test changes.

/// A fixture record's body.
pub(crate) fn fixture_body(kind: &str, key: &str) -> Value {
    fixture()
        .into_iter()
        .find(|e| e["kind"] == kind && e["key"] == key)
        .unwrap_or_else(|| panic!("no fixture {kind} {key}"))["body"]
        .clone()
}

/// A text field of a fixture meeting, e.g. its `day` or `startedAt`.
pub(crate) fn meeting_field(id: &str, field: &str) -> String {
    fixture_body("meeting", id)[field]
        .as_str()
        .unwrap_or_else(|| panic!("meeting {id} has no {field}"))
        .to_owned()
}

/// An action's `dueDate` in the fixture.
pub(crate) fn due_date(meeting_id: &str, action_id: &str) -> String {
    fixture_body("meeting", meeting_id)["actions"]
        .as_array()
        .unwrap()
        .iter()
        .find(|a| a["id"] == action_id)
        .and_then(|a| a["dueDate"].as_str())
        .unwrap_or_else(|| panic!("{action_id} has no due date"))
        .to_owned()
}

/// The fixture's day keys, newest first.
pub(crate) fn fixture_days() -> Vec<String> {
    let mut days: Vec<String> = fixture()
        .into_iter()
        .filter(|e| e["kind"] == "day")
        .map(|e| e["key"].as_str().unwrap().to_owned())
        .collect();
    days.sort_by(|a, b| b.cmp(a));
    days
}

/// The day `offset` days after the newest fixture day, as "today".
pub(crate) fn days_after_latest(offset: i64) -> String {
    let latest = chrono::NaiveDate::parse_from_str(&fixture_days()[0], "%Y-%m-%d").unwrap();
    (latest + chrono::Duration::days(offset))
        .format("%Y-%m-%d")
        .to_string()
}

/// Short timeouts so failure paths finish quickly.
pub(crate) fn fast_tuning() -> Tuning {
    Tuning {
        ping_interval: Duration::from_millis(400),
        idle_timeout: Duration::from_secs(5),
        connect_timeout: Duration::from_secs(1),
        handshake_timeout: Duration::from_secs(5),
        approval_timeout: Duration::from_secs(3),
        ask_timeout: Duration::from_secs(5),
        offer_lifetime_secs: 300,
        batch_bytes: 512 * 1024,
    }
}

type OpHandler = Box<dyn Fn(&SyncServer, Value) -> OpOutcome + Send + Sync>;
type AskHandler = Box<dyn Fn(Value, Arc<AskSink>) + Send + Sync>;

/// A scriptable Mac app.
pub(crate) struct TestDelegate {
    pub approve: AtomicBool,
    pub approval_delay: Mutex<Duration>,
    pub approvals: Mutex<Vec<(String, String)>>,
    pub device_changes: AtomicUsize,
    pub ops: Mutex<Vec<Value>>,
    on_op: Mutex<Option<OpHandler>>,
    on_ask: Mutex<Option<AskHandler>>,
    server: OnceLock<Weak<SyncServer>>,
}

impl TestDelegate {
    pub fn on_op(&self, handler: impl Fn(&SyncServer, Value) -> OpOutcome + Send + Sync + 'static) {
        *self.on_op.lock() = Some(Box::new(handler));
    }

    pub fn on_ask(&self, handler: impl Fn(Value, Arc<AskSink>) + Send + Sync + 'static) {
        *self.on_ask.lock() = Some(Box::new(handler));
    }
}

struct SharedDelegate(Arc<TestDelegate>);

impl ServerDelegate for SharedDelegate {
    fn approve_pairing(&self, device_name: String, platform: String) -> bool {
        self.0.approvals.lock().push((device_name, platform));
        let delay = *self.0.approval_delay.lock();
        std::thread::sleep(delay);
        self.0.approve.load(Ordering::SeqCst)
    }

    fn apply_op(&self, op_json: String) -> OpOutcome {
        let op: Value = serde_json::from_str(&op_json).expect("ops are JSON");
        self.0.ops.lock().push(op.clone());
        let server = self
            .0
            .server
            .get()
            .and_then(Weak::upgrade)
            .expect("the server is alive");
        match &*self.0.on_op.lock() {
            Some(handler) => handler(&server, op),
            None => OpOutcome {
                status: "applied".into(),
                message: None,
            },
        }
    }

    fn ask(&self, request_json: String, sink: Arc<AskSink>) {
        let request: Value = serde_json::from_str(&request_json).expect("questions are JSON");
        match &*self.0.on_ask.lock() {
            Some(handler) => handler(request, sink),
            None => sink.failed("No answer configured.".into()),
        }
    }

    fn devices_changed(&self) {
        self.0.device_changes.fetch_add(1, Ordering::SeqCst);
    }
}

pub(crate) struct Host {
    pub server: Arc<SyncServer>,
    pub delegate: Arc<TestDelegate>,
    _dir: TempDir,
}

impl Host {
    /// A running loopback host serving the fixture library.
    pub fn new() -> Self {
        let host = Self::empty();
        for envelope in fixture() {
            host.server
                .publish(
                    envelope["kind"].as_str().unwrap().into(),
                    envelope["key"].as_str().unwrap().into(),
                    envelope["body"].to_string(),
                )
                .unwrap();
        }
        host
    }

    pub fn empty() -> Self {
        let dir = TempDir::new().unwrap();
        let delegate = Arc::new(TestDelegate {
            approve: AtomicBool::new(true),
            approval_delay: Mutex::new(Duration::ZERO),
            approvals: Mutex::new(Vec::new()),
            device_changes: AtomicUsize::new(0),
            ops: Mutex::new(Vec::new()),
            on_op: Mutex::new(None),
            on_ask: Mutex::new(None),
            server: OnceLock::new(),
        });
        let server = SyncServer::new(
            ServerConfig {
                db_path: dir
                    .path()
                    .join("companion/companion.sqlite")
                    .to_string_lossy()
                    .into_owned(),
                mac_name: "Test Mac".into(),
                static_private_key: crate::generate_static_key().private_key,
                port: 0,
            },
            Box::new(SharedDelegate(Arc::clone(&delegate))),
        )
        .unwrap();
        server.set_tuning(fast_tuning());
        server.set_loopback_only(true);
        server.start().unwrap();
        delegate.server.set(Arc::downgrade(&server)).ok();
        Self {
            server,
            delegate,
            _dir: dir,
        }
    }

    pub fn offer(&self) -> String {
        self.server
            .begin_pairing(vec!["127.0.0.1".into()])
            .qr_payload
    }

    /// The host database. Don't hold it across calls into the server.
    pub fn server_store(&self) -> parking_lot::MutexGuard<'_, crate::server::store::HostStore> {
        self.server.store()
    }

    /// Republishes a fixture meeting with one action's status changed.
    pub fn set_status(
        server: &SyncServer,
        meeting_id: &str,
        action_id: &str,
        status: &str,
    ) -> bool {
        let mut meeting = fixture()
            .into_iter()
            .find(|e| e["kind"] == "meeting" && e["key"] == meeting_id)
            .expect("a fixture meeting")["body"]
            .clone();
        let Some(action) = meeting["actions"]
            .as_array_mut()
            .unwrap()
            .iter_mut()
            .find(|a| a["id"] == action_id)
        else {
            return false;
        };
        action["status"] = Value::String(status.into());
        server
            .publish("meeting".into(), meeting_id.into(), meeting.to_string())
            .unwrap();
        true
    }
}

pub(crate) struct Phone {
    pub client: Arc<SyncClient>,
    pub device_id: String,
    pub dir: TempDir,
}

impl Phone {
    pub fn new() -> Self {
        Self::with_key(crate::generate_static_key().private_key)
    }

    pub fn with_key(private_key: Vec<u8>) -> Self {
        let dir = TempDir::new().unwrap();
        let device_id = uuid::Uuid::new_v4().to_string();
        let client = SyncClient::new(ClientConfig {
            db_path: dir
                .path()
                .join("companion.sqlite")
                .to_string_lossy()
                .into_owned(),
            device_id: device_id.clone(),
            device_name: "Test iPad".into(),
            platform: "ipados".into(),
            static_private_key: private_key,
        })
        .unwrap();
        client.set_tuning(fast_tuning());
        Self {
            client,
            device_id,
            dir,
        }
    }

    /// A phone paired with `host`.
    pub fn paired(host: &Host) -> Self {
        let phone = Self::new();
        phone.client.pair(host.offer()).unwrap();
        phone
    }

    pub fn sample() -> Self {
        let phone = Self::new();
        phone.client.import_records(FIXTURE.into()).unwrap();
        phone
    }

    pub fn action(&self, meeting_id: &str, action_id: &str) -> Value {
        let rows = self
            .client
            .actions_on(&Default::default(), &days_after_latest(1))
            .unwrap();
        rows.iter()
            .map(|row| serde_json::from_str::<Value>(row).unwrap())
            .find(|row| row["meetingId"] == meeting_id && row["action"]["id"] == action_id)
            .expect("the action is listed")
    }
}
