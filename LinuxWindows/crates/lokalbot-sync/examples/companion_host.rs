//! A stand-in Mac for developing the companion apps: serves the sample
//! library, prints a pairing code, applies action status changes and answers
//! questions with a canned reply.
//!
//! ```text
//! cargo run -p lokalbot-sync --example companion_host -- [--port 17890] [--dir PATH]
//!     [--name "Dev Mac"] [--auto-approve] [--loopback]
//! ```
//!
//! While it runs, type `pair` for a new code, `devices`, `remove <device id>`,
//! `publish` to bump today's day record, or `quit`. Answer a pairing request
//! with `y` or `n`.

use std::collections::HashMap;
use std::io::BufRead as _;
use std::path::PathBuf;
use std::sync::mpsc::{self, Sender};
use std::sync::{Arc, Mutex, OnceLock, Weak};
use std::time::Duration;

use lokalbot_sync::{AskSink, OpOutcome, ServerConfig, ServerDelegate, SyncServer};
use serde_json::{Value, json};

const LIBRARY: &str = include_str!("../../../../Companion/protocol/fixtures/sample-library.json");
const CITED_MEETING: &str = "3f6c2a10-8a4e-4d2b-9b1e-0a1b2c3d4e01";

struct Options {
    port: u16,
    dir: PathBuf,
    name: String,
    auto_approve: bool,
    loopback: bool,
}

fn options() -> Options {
    let mut options = Options {
        port: 17890,
        dir: std::env::temp_dir().join("lokalbot-companion-host"),
        name: "Dev Mac".into(),
        auto_approve: false,
        loopback: false,
    };
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--port" => {
                options.port = args
                    .next()
                    .and_then(|p| p.parse().ok())
                    .expect("--port needs a number")
            }
            "--dir" => options.dir = args.next().expect("--dir needs a path").into(),
            "--name" => options.name = args.next().expect("--name needs a value"),
            "--auto-approve" => options.auto_approve = true,
            "--loopback" => options.loopback = true,
            other => {
                eprintln!("unknown argument {other}");
                std::process::exit(2);
            }
        }
    }
    options
}

/// The host's static key, kept next to its database so pairings survive
/// restarts.
fn static_key(dir: &std::path::Path) -> Vec<u8> {
    let path = dir.join("host.key");
    if let Ok(text) = std::fs::read_to_string(&path)
        && let Ok(key) = hex::decode(text.trim())
    {
        return key;
    }
    let key = lokalbot_sync::generate_static_key().private_key;
    std::fs::write(&path, hex::encode(&key)).expect("write the host key");
    key
}

struct DevMac {
    auto_approve: bool,
    /// Where the next `y`/`n` on stdin goes.
    pending_approval: Mutex<Option<Sender<bool>>>,
    /// Meeting bodies by id, edited by status ops.
    meetings: Mutex<HashMap<String, Value>>,
    server: OnceLock<Weak<SyncServer>>,
}

impl DevMac {
    fn server(&self) -> Option<Arc<SyncServer>> {
        self.server.get().and_then(Weak::upgrade)
    }

    fn print_devices(&self) {
        let Some(server) = self.server() else { return };
        let connected = server.connected_device_ids();
        match server.paired_devices() {
            Ok(devices) if devices.is_empty() => println!("No paired devices."),
            Ok(devices) => {
                for device in devices {
                    let state = if connected.contains(&device.device_id) {
                        "connected"
                    } else {
                        "offline"
                    };
                    println!(
                        "  {} — {} ({}), {state}, last seen {}",
                        device.device_id,
                        device.name,
                        device.platform,
                        device.last_seen_at.as_deref().unwrap_or("never")
                    );
                }
            }
            Err(e) => eprintln!("paired devices: {e}"),
        }
    }
}

struct Delegate(Arc<DevMac>);

impl ServerDelegate for Delegate {
    fn approve_pairing(&self, device_name: String, platform: String) -> bool {
        if self.0.auto_approve {
            println!("Pairing \"{device_name}\" ({platform}): approved automatically.");
            return true;
        }
        let (answer, answered) = mpsc::channel();
        *self.0.pending_approval.lock().unwrap() = Some(answer);
        println!("Allow \"{device_name}\" ({platform}) to read your shared LokalBot data? [y/n]");
        let approved = answered
            .recv_timeout(Duration::from_secs(115))
            .unwrap_or(false);
        self.0.pending_approval.lock().unwrap().take();
        println!(
            "{}",
            if approved {
                "Approved."
            } else {
                "Not approved."
            }
        );
        approved
    }

    fn apply_op(&self, op_json: String) -> OpOutcome {
        println!("op: {op_json}");
        let op: Value = serde_json::from_str(&op_json).unwrap_or_default();
        let field = |name: &str| {
            op.get(name)
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_owned()
        };
        let (meeting_id, action_id, text, status) = (
            field("meetingId"),
            field("actionId"),
            field("actionText"),
            field("status"),
        );
        let mut meetings = self.0.meetings.lock().unwrap();
        let Some(meeting) = meetings.get_mut(&meeting_id) else {
            return OpOutcome {
                status: "unmatched".into(),
                message: Some("No such meeting.".into()),
            };
        };
        let Some(action) = meeting["actions"].as_array_mut().and_then(|actions| {
            let by_id = actions.iter().position(|a| a["id"] == action_id.as_str());
            let index =
                by_id.or_else(|| actions.iter().position(|a| a["text"] == text.as_str()))?;
            actions.get_mut(index)
        }) else {
            return OpOutcome {
                status: "unmatched".into(),
                message: Some("No such action item.".into()),
            };
        };
        action["status"] = Value::String(status);
        let body = meeting.to_string();
        drop(meetings);
        match self
            .0
            .server()
            .map(|server| server.publish("meeting".into(), meeting_id, body))
        {
            Some(Ok(_)) => OpOutcome {
                status: "applied".into(),
                message: None,
            },
            Some(Err(e)) => OpOutcome {
                status: "rejected".into(),
                message: Some(e.to_string()),
            },
            None => OpOutcome {
                status: "rejected".into(),
                message: Some("Shutting down.".into()),
            },
        }
    }

    fn ask(&self, request_json: String, sink: Arc<AskSink>) {
        println!("question: {request_json}");
        std::thread::spawn(move || {
            let request: Value = serde_json::from_str(&request_json).unwrap_or_default();
            let parts = [
                "On 29 October the team ",
                "cut onboarding to three steps ",
                "and will ship it behind a flag first [1].",
            ];
            for part in parts {
                std::thread::sleep(Duration::from_millis(300));
                sink.delta(part.into());
            }
            let result = json!({
                "requestId": request["requestId"],
                "answer": parts.concat(),
                "citations": [ {
                    "index": 1, "meetingId": CITED_MEETING, "at": 1870,
                    "label": "Design review — onboarding · 10:01"
                } ],
                "engineLabel": "Dev host (canned answer)",
                "location": "mac",
                "answeredAt": chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true),
            });
            sink.done(result.to_string());
        });
    }

    fn devices_changed(&self) {
        println!("Devices changed:");
        self.0.print_devices();
    }
}

fn print_offer(server: &SyncServer, loopback: bool) {
    let addresses = if loopback {
        vec!["127.0.0.1".to_owned()]
    } else {
        Vec::new()
    };
    let offer = server.begin_pairing(addresses);
    let info = lokalbot_sync::parse_pairing_payload(offer.qr_payload.clone())
        .expect("our own payload parses");
    println!();
    println!(
        "Pairing code for {} at {:?} port {} (expires {}):",
        info.mac_name, info.addresses, info.port, offer.expires_at
    );
    println!("{}", offer.qr_payload);
    match qrcode::QrCode::new(offer.qr_payload.as_bytes()) {
        Ok(code) => {
            let art = code
                .render::<qrcode::render::unicode::Dense1x2>()
                .dark_color(qrcode::render::unicode::Dense1x2::Light)
                .light_color(qrcode::render::unicode::Dense1x2::Dark)
                .build();
            println!("{art}");
        }
        Err(e) => eprintln!("QR code: {e}"),
    }
}

fn main() {
    let options = options();
    std::fs::create_dir_all(&options.dir).expect("create the host directory");
    let dev_mac = Arc::new(DevMac {
        auto_approve: options.auto_approve,
        pending_approval: Mutex::new(None),
        meetings: Mutex::new(HashMap::new()),
        server: OnceLock::new(),
    });
    let server = SyncServer::new(
        ServerConfig {
            db_path: options
                .dir
                .join("companion.sqlite")
                .to_string_lossy()
                .into_owned(),
            mac_name: options.name.clone(),
            static_private_key: static_key(&options.dir),
            port: options.port,
        },
        Box::new(Delegate(Arc::clone(&dev_mac))),
    )
    .expect("open the companion database");
    dev_mac.server.set(Arc::downgrade(&server)).ok();

    let envelopes: Vec<Value> = serde_json::from_str(LIBRARY).expect("the sample library parses");
    let mut changed = 0;
    for envelope in &envelopes {
        let (kind, key) = (
            envelope["kind"].as_str().unwrap(),
            envelope["key"].as_str().unwrap(),
        );
        if kind == "meeting" {
            dev_mac
                .meetings
                .lock()
                .unwrap()
                .insert(key.to_owned(), envelope["body"].clone());
        }
        if server
            .publish(kind.into(), key.into(), envelope["body"].to_string())
            .expect("publish")
        {
            changed += 1;
        }
    }
    // Each run starts from the sample library again; status changes from an
    // earlier run are published back as new versions.
    println!(
        "Published the sample library: {} records, {changed} changed, seq {}.",
        envelopes.len(),
        server.current_seq().unwrap_or(0)
    );

    server.set_loopback_only(options.loopback);
    server.start().expect("start listening");
    println!(
        "{} listening on port {}{}; key fingerprint {}.",
        options.name,
        server.bound_port(),
        if options.loopback {
            " (loopback only)"
        } else {
            ""
        },
        lokalbot_sync::key_fingerprint(
            lokalbot_sync::public_key_for(static_key(&options.dir)).expect("a valid key")
        ),
    );
    println!(
        "This machine's addresses: {:?}",
        lokalbot_sync::local_addresses()
    );
    print_offer(&server, options.loopback);
    println!("Commands: pair, devices, remove <device id>, publish, quit.");

    for line in std::io::stdin().lock().lines() {
        let Ok(line) = line else { break };
        let line = line.trim();
        if let Some(answer) = dev_mac.pending_approval.lock().unwrap().take() {
            let _ = answer.send(matches!(line, "y" | "Y" | "yes"));
            continue;
        }
        match line.split_once(' ').unwrap_or((line, "")) {
            ("pair", _) => print_offer(&server, options.loopback),
            ("devices", _) => dev_mac.print_devices(),
            ("remove", id) if !id.is_empty() => match server.remove_device(id.trim().to_owned()) {
                Ok(()) => println!("Removed {id}."),
                Err(e) => eprintln!("remove: {e}"),
            },
            ("publish", _) => {
                let today = chrono::Local::now().format("%Y-%m-%d").to_string();
                let body = json!({
                    "date": today,
                    "timeline": { "trackedSeconds": chrono::Utc::now().timestamp() % 86_400, "sessions": [],
                                  "byProject": [], "byApp": [], "savedMoments": [] },
                    "meetingIds": []
                });
                match server.publish("day".into(), today.clone(), body.to_string()) {
                    Ok(changed) => println!(
                        "Published day {today} (changed: {changed}, seq {}).",
                        server.current_seq().unwrap_or(0)
                    ),
                    Err(e) => eprintln!("publish: {e}"),
                }
            }
            ("quit" | "exit", _) => break,
            ("", _) => {}
            _ => println!("Commands: pair, devices, remove <device id>, publish, quit."),
        }
    }
    server.stop();
}
