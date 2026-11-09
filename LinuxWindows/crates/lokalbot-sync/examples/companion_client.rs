//! A stand-in phone for developing against a host (the Mac app or the
//! `companion_host` example). It keeps its key and copy in one directory.
//!
//! ```text
//! cargo run -p lokalbot-sync --example companion_client -- [--dir PATH] [--name NAME] <command>
//!
//!   pair <payload>                        pair using a lokalbot://pair?d=… code
//!   sync [address…]                       sync, trying these host:port addresses first
//!   status | meetings | people | days
//!   actions [--mine] [--open]             action items, overdue first
//!   set-status <meeting> <action> <status>
//!   ask "<question>" [address…]           ask the Mac, printing the answer as it arrives
//!   search "<query>"
//!   unpair
//! ```

use std::path::{Path, PathBuf};
use std::sync::Arc;

use lokalbot_sync::{ActionFilter, AskListener, ClientConfig, SyncClient};
use serde_json::{Value, json};

struct Printer;

impl AskListener for Printer {
    fn on_delta(&self, text: String) {
        use std::io::Write as _;
        print!("{text}");
        let _ = std::io::stdout().flush();
    }
}

/// The phone's key and device id, created on first use.
fn identity(dir: &Path) -> (Vec<u8>, String) {
    let key_path = dir.join("client.key");
    let id_path = dir.join("device-id");
    let key = std::fs::read_to_string(&key_path)
        .ok()
        .and_then(|text| hex::decode(text.trim()).ok())
        .unwrap_or_else(|| {
            let key = lokalbot_sync::generate_static_key().private_key;
            std::fs::write(&key_path, hex::encode(&key)).expect("write the client key");
            key
        });
    let device_id = std::fs::read_to_string(&id_path)
        .map(|s| s.trim().to_owned())
        .unwrap_or_else(|_| {
            let id = uuid::Uuid::new_v4().to_string();
            std::fs::write(&id_path, &id).expect("write the device id");
            id
        });
    (key, device_id)
}

fn print_json_lines(rows: Vec<String>, describe: impl Fn(&Value) -> String) {
    for row in rows {
        let value: Value = serde_json::from_str(&row).unwrap_or_default();
        println!("{}", describe(&value));
    }
}

fn run(
    client: &Arc<SyncClient>,
    command: &str,
    args: &[String],
) -> Result<(), lokalbot_sync::SyncError> {
    match command {
        "pair" => {
            let payload = args.first().expect("pair needs the code");
            let info = lokalbot_sync::parse_pairing_payload(payload.clone())?;
            println!(
                "Pairing with {} at {:?} port {}; confirm on the Mac…",
                info.mac_name, info.addresses, info.port
            );
            let mac = client.pair(payload.clone())?;
            println!("Paired with {} ({}).", mac.mac_name, mac.mac_key_b64);
        }
        "sync" => {
            let report = client.sync(args.to_vec())?;
            println!(
                "Synced with {}: {} received, {} deleted, {} ops applied, cursor {}.",
                report.address, report.received, report.deleted, report.ops_applied, report.cursor
            );
        }
        "status" => println!("{:#?}", client.status()?),
        "meetings" => print_json_lines(client.meetings(None, None, 0)?, |m| {
            format!(
                "{}  {}  {}",
                m["startedAt"].as_str().unwrap_or(""),
                m["id"].as_str().unwrap_or(""),
                m["title"].as_str().unwrap_or("")
            )
        }),
        "people" => print_json_lines(client.people()?, |p| {
            p["displayName"].as_str().unwrap_or("").to_owned()
        }),
        "days" => client.days(0)?.iter().for_each(|day| println!("{day}")),
        "actions" => {
            let filter = ActionFilter {
                mine_only: args.iter().any(|a| a == "--mine"),
                status: args
                    .iter()
                    .any(|a| a == "--open")
                    .then(|| "open".to_owned()),
                ..Default::default()
            };
            print_json_lines(client.actions(filter)?, |row| {
                let action = &row["action"];
                format!(
                    "[{}{}] {}  due {}  owner {}  ({} / {} {})",
                    action["status"].as_str().unwrap_or(""),
                    if row["pending"] == true {
                        ", waiting for the Mac"
                    } else {
                        ""
                    },
                    action["text"].as_str().unwrap_or(""),
                    action["dueDate"].as_str().unwrap_or("-"),
                    action["owner"].as_str().unwrap_or("unclear"),
                    row["meetingTitle"].as_str().unwrap_or(""),
                    row["meetingId"].as_str().unwrap_or(""),
                    action["id"].as_str().unwrap_or(""),
                )
            });
        }
        "set-status" => {
            let [meeting, action, status] = args else {
                panic!("set-status needs <meeting id> <action id> <status>");
            };
            client.set_action_status(meeting.clone(), action.clone(), status.clone())?;
            println!("Queued; it reaches the Mac at the next sync.");
        }
        "ask" => {
            let question = args.first().expect("ask needs a question");
            let request = json!({
                "requestId": uuid::Uuid::new_v4().to_string(),
                "conversationId": uuid::Uuid::new_v4().to_string(),
                "question": question,
                "history": [],
            });
            let result = client.ask(request.to_string(), args[1..].to_vec(), Box::new(Printer))?;
            let result: Value = serde_json::from_str(&result).unwrap_or_default();
            println!();
            for citation in result["citations"].as_array().into_iter().flatten() {
                println!(
                    "  [{}] {} at {}s",
                    citation["index"],
                    citation["label"].as_str().unwrap_or(""),
                    citation["at"]
                );
            }
            println!(
                "({}, {})",
                result["engineLabel"].as_str().unwrap_or(""),
                result["location"].as_str().unwrap_or("")
            );
        }
        "search" => {
            let query = args.first().expect("search needs a query");
            for hit in client.search(query.clone(), 20)? {
                let at = hit.at.map(|at| format!(" at {at}s")).unwrap_or_default();
                println!(
                    "{} {}{}: {}  [{}]",
                    hit.kind, hit.title, at, hit.snippet, hit.key
                );
            }
        }
        "unpair" => {
            client.unpair()?;
            println!("Erased the local copy and the pairing.");
        }
        other => {
            eprintln!("unknown command {other}");
            std::process::exit(2);
        }
    }
    Ok(())
}

fn main() {
    let mut dir: PathBuf = std::env::temp_dir().join("lokalbot-companion-client");
    let mut name = "Dev phone".to_owned();
    let mut args: Vec<String> = std::env::args().skip(1).collect();
    loop {
        match args.first().map(String::as_str) {
            Some("--dir") if args.len() > 1 => {
                dir = args[1].clone().into();
                args.drain(..2);
            }
            Some("--name") if args.len() > 1 => {
                name = args[1].clone();
                args.drain(..2);
            }
            _ => break,
        }
    }
    let Some((command, args)) = args.split_first() else {
        eprintln!(
            "usage: companion_client [--dir PATH] [--name NAME] <pair|sync|status|meetings|people|days|actions|set-status|ask|search|unpair> …"
        );
        std::process::exit(2);
    };
    std::fs::create_dir_all(&dir).expect("create the client directory");
    let (key, device_id) = identity(&dir);
    let client = SyncClient::new(ClientConfig {
        db_path: dir.join("companion.sqlite").to_string_lossy().into_owned(),
        device_id,
        device_name: name,
        platform: "android".into(),
        static_private_key: key,
    })
    .expect("open the local copy");
    if let Err(error) = run(&client, command, args) {
        eprintln!("error: {error:?}");
        std::process::exit(1);
    }
}
