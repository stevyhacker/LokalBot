//! Serves paired phones and tablets (`Services/Companion/`). Everything below
//! the switch exists only while Settings → Phones & tablets is on: with sharing
//! off nothing listens, nothing is announced and no record is built.
//!
//! `lokalbot-sync` holds the listener, Noise sessions and pairing. This module
//! decides what is shared: `builder` turns the library into allowlisted
//! records, `publisher` keeps them current, `ask` answers questions and `ops`
//! applies action changes. `host` runs the lifecycle.

mod advertise;
mod ask;
mod builder;
mod host;
mod library;
mod ops;
mod publisher;
mod records;
mod sharing;
#[cfg(test)]
mod tests;

use std::collections::BTreeSet;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread::JoinHandle;

use chrono::{DateTime, NaiveDate, Utc};
use crossbeam_channel::{Sender, unbounded};
use lokalbot_core::Settings;
use parking_lot::Mutex;

use crate::Shared;
use crate::models::Models;

pub use sharing::{HistoryWindow, clamped_port};

use sharing::Sharing;

use host::{Host, HostMessage};

/// What Settings asks of the host.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum CompanionCommand {
    /// The interactive app is running: follow the setting from now on. Tools
    /// and examples that start the engine never listen.
    Enable,
    BeginPairing,
    CancelPairing,
    RemoveDevice(String),
    /// The person's answer to a pairing request.
    AnswerPairing {
        id: u64,
        allow: bool,
    },
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub enum CompanionStatus {
    #[default]
    Off,
    Starting,
    Listening {
        port: u16,
    },
    Failed(String),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CompanionDevice {
    pub id: String,
    pub name: String,
    pub platform: String,
    pub paired_at: Option<DateTime<Utc>>,
    pub last_seen_at: Option<DateTime<Utc>>,
    pub last_address: Option<String>,
}

/// An open pairing offer. The code holds a one-time secret, so it never
/// reaches a log.
#[derive(Clone, PartialEq, Eq)]
pub struct CompanionPairing {
    pub qr_payload: String,
    pub expires_at: DateTime<Utc>,
}

impl std::fmt::Debug for CompanionPairing {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("CompanionPairing")
            .field("expires_at", &self.expires_at)
            .finish_non_exhaustive()
    }
}

/// A device that scanned the code and is waiting to be allowed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PairingRequest {
    pub id: u64,
    pub device_name: String,
    pub platform: String,
}

/// What Settings shows.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct CompanionSnapshot {
    pub status: CompanionStatus,
    pub devices: Vec<CompanionDevice>,
    pub connected_device_ids: BTreeSet<String>,
    pub pairing: Option<CompanionPairing>,
    pub approval: Option<PairingRequest>,
    pub action_error: Option<String>,
    /// Why the local network announcement isn't running, when it should be.
    pub discovery_error: Option<String>,
    /// The addresses a new device would be given. Empty means nothing on a
    /// private network or Tailscale can reach this computer.
    pub addresses: Vec<String>,
}

/// A device chooses its own name; show a bounded, single-line version.
pub fn device_display_name(raw: &str) -> String {
    let line: String = raw.chars().filter(|c| !c.is_control()).collect();
    let line = line.trim();
    if line.is_empty() {
        return "A device".into();
    }
    if line.chars().count() > 60 {
        let mut short: String = line.chars().take(59).collect();
        short.push('…');
        return short;
    }
    line.to_string()
}

/// How a paired device last reached this computer, for the device list.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CompanionNetwork {
    Tailscale,
    LocalNetwork,
}

impl CompanionNetwork {
    /// Tailscale hands out `100.64.0.0/10` and `fd7a:115c:a1e0::/48`.
    pub fn classify(address: &str) -> Option<Self> {
        let mut host = address.trim();
        if host.is_empty() {
            return None;
        }
        if let Some(rest) = host.strip_prefix('[') {
            host = rest.split(']').next().unwrap_or(rest);
        } else if host.matches(':').count() == 1 {
            host = host.split(':').next().unwrap_or(host);
        }
        let lowered = host.to_lowercase();
        let host = lowered.strip_prefix("::ffff:").unwrap_or(&lowered);
        let octets: Vec<u8> = host
            .split('.')
            .filter_map(|part| part.parse().ok())
            .collect();
        if let [first, second, _, _] = octets[..] {
            return Some(if first == 100 && (64..=127).contains(&second) {
                Self::Tailscale
            } else {
                Self::LocalNetwork
            });
        }
        Some(if host.starts_with("fd7a:115c:a1e0:") {
            Self::Tailscale
        } else {
            Self::LocalNetwork
        })
    }
}

/// The engine's handle on the host thread. Calls only queue work.
#[derive(Default)]
pub struct Companion {
    sender: Mutex<Option<Sender<HostMessage>>>,
    thread: Mutex<Option<JoinHandle<()>>>,
    enabled: AtomicBool,
}

impl Companion {
    fn send(&self, message: HostMessage) {
        if let Some(sender) = self.sender.lock().as_ref() {
            let _ = sender.send(message);
        }
    }

    pub fn settings_changed(&self, settings: &Settings) {
        if self.enabled.load(Ordering::SeqCst) {
            self.send(HostMessage::Apply(Sharing::new(settings)));
        }
    }

    pub fn command(&self, command: CompanionCommand, settings: &Settings) {
        match command {
            CompanionCommand::Enable => {
                self.enabled.store(true, Ordering::SeqCst);
                self.settings_changed(settings);
            }
            command => self.send(HostMessage::Command(command)),
        }
    }

    /// Source changes on these days, from the one route every change takes.
    pub fn evidence_changed(&self, days: &[NaiveDate]) {
        self.send(HostMessage::EvidenceChanged(days.to_vec()));
    }

    /// Files in the library changed.
    pub fn library_changed(&self) {
        self.send(HostMessage::LibraryChanged);
    }

    pub fn day_digest_changed(&self, day: NaiveDate) {
        self.send(HostMessage::DayChanged(day));
    }

    /// Stops listening and waits for the host thread.
    pub fn stop(&self) {
        self.send(HostMessage::Stop);
        self.sender.lock().take();
        if let Some(thread) = self.thread.lock().take() {
            let _ = thread.join();
        }
    }
}

/// Starts the host thread, idle until `CompanionCommand::Enable`.
pub(crate) fn start(shared: Arc<Shared>, models: Models) {
    let (sender, receiver) = unbounded();
    let environment = Arc::new(host::LiveEnvironment {
        shared: shared.clone(),
    });
    let emit = {
        let shared = Arc::downgrade(&shared);
        move |snapshot: CompanionSnapshot| {
            if let Some(shared) = shared.upgrade() {
                shared.emit(crate::EngineEvent::Companion(Box::new(snapshot)));
            }
        }
    };
    let engine = Arc::new(ask::LiveAskEngine {
        shared: shared.clone(),
        models,
    });
    let library = shared.library.clone();
    *shared.companion.sender.lock() = Some(sender.clone());
    let thread = std::thread::Builder::new()
        .name("lokalbot-companion".into())
        .spawn(move || {
            Host::new(library, environment, engine, sender, Box::new(emit)).run(receiver);
        });
    match thread {
        Ok(thread) => *shared.companion.thread.lock() = Some(thread),
        Err(err) => log::warn!("the companion host could not start: {err}"),
    }
}
