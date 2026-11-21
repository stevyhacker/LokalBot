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
    ActionFilter, AskListener, ClientConfig, PairedMac, RecordingInfo, SearchHit, SyncClient,
    SyncReport, SyncStatus, UploadListener, UploadReport,
};
pub use error::SyncError;
pub use keys::StaticKey;
pub use net::is_allowed_peer;
pub use pairing::PairingInfo;
pub use server::{
    AskSink, OpOutcome, PairedDevice, PairingOffer, ServerConfig, ServerDelegate, SyncServer,
    UploadOutcome,
};

#[uniffi::export]
pub fn generate_static_key() -> StaticKey {
    keys::generate()
}

#[uniffi::export]
pub fn public_key_for(private_key: Vec<u8>) -> Result<Vec<u8>, SyncError> {
    keys::public_key(&private_key).map(|key| key.to_vec())
}

#[uniffi::export]
pub fn key_fingerprint(public_key: Vec<u8>) -> String {
    keys::fingerprint(&public_key)
}

#[uniffi::export]
pub fn local_addresses() -> Vec<String> {
    net::local_addresses()
}

#[uniffi::export]
pub fn parse_pairing_payload(payload: String) -> Result<PairingInfo, SyncError> {
    pairing::Payload::parse(&payload).map(|payload| payload.info())
}

#[uniffi::export]
pub fn protocol_version() -> u32 {
    wire::PROTOCOL_VERSION
}
