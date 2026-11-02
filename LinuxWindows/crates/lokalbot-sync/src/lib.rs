//! Companion sync for LokalBot's phone and tablet apps.
//!
//! The Mac (the host, [`SyncServer`]) publishes allowlisted JSON records and
//! serves paired devices over the local network or Tailscale; phones and
//! tablets (the clients, [`SyncClient`]) keep an end-to-end encrypted copy,
//! search it, change action status and ask the Mac questions. The wire
//! contract is `Companion/protocol/protocol.md`, the records
//! `Companion/protocol/records.md`, and this crate's foreign API
//! `Companion/protocol/ffi.md`; Swift and Kotlin call it through UniFFI.

uniffi::setup_scaffolding!();

mod client;
mod error;
mod keys;
mod messages;
mod net;
mod pairing;
mod records;
mod server;
mod wire;

#[cfg(test)]
mod tests;

pub use client::{
    ActionFilter, AskListener, ClientConfig, PairedMac, SearchHit, SyncClient, SyncReport,
    SyncStatus,
};
pub use error::SyncError;
pub use keys::StaticKey;
pub use net::is_allowed_peer;
pub use pairing::PairingInfo;
pub use server::{
    AskSink, OpOutcome, PairedDevice, PairingOffer, ServerConfig, ServerDelegate, SyncServer,
};

/// A new random X25519 static key pair.
#[uniffi::export]
pub fn generate_static_key() -> StaticKey {
    keys::generate()
}

/// The X25519 public key for a 32-byte private key.
#[uniffi::export]
pub fn public_key_for(private_key: Vec<u8>) -> Result<Vec<u8>, SyncError> {
    keys::public_key(&private_key).map(|key| key.to_vec())
}

/// First 16 hex characters of SHA-256 over a public key, as in the Bonjour
/// TXT record `k`.
#[uniffi::export]
pub fn key_fingerprint(public_key: Vec<u8>) -> String {
    keys::fingerprint(&public_key)
}

/// This machine's private LAN, Tailscale and link-local IPv4 addresses (the
/// address filter's ranges), never loopback.
#[uniffi::export]
pub fn local_addresses() -> Vec<String> {
    net::local_addresses()
}

/// Reads a scanned `lokalbot://pair?d=…` code without contacting the Mac.
#[uniffi::export]
pub fn parse_pairing_payload(payload: String) -> Result<PairingInfo, SyncError> {
    pairing::Payload::parse(&payload).map(|payload| payload.info())
}

/// The companion protocol version this crate speaks.
#[uniffi::export]
pub fn protocol_version() -> u32 {
    wire::PROTOCOL_VERSION
}
