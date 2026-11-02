//! The QR code payload (protocol.md, Pairing).

use serde::{Deserialize, Serialize};

use crate::error::{Result, SyncError};
use crate::keys::{KEY_LEN, b64url, b64url_decode, key_array};
use crate::records::iso_from_unix;
use crate::wire::PAIRING_ID_LEN;

const PAYLOAD_PREFIX: &str = "lokalbot://pair?";

/// What the phone may show about a scanned code. The secret stays in Rust.
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct PairingInfo {
    pub mac_name: String,
    pub mac_key_b64: String,
    pub addresses: Vec<String>,
    pub port: u16,
    /// ISO 8601 UTC.
    pub expires_at: String,
}

/// The JSON inside the code, keys in the order protocol.md shows.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct PayloadJson {
    pub v: u32,
    pub mac_name: String,
    pub mac_key: String,
    pub addrs: Vec<String>,
    pub port: u16,
    pub pid: String,
    pub psk: String,
    pub exp: i64,
}

/// A decoded, validated payload.
#[derive(Clone, Debug)]
pub(crate) struct Payload {
    pub mac_name: String,
    pub mac_key: [u8; KEY_LEN],
    pub addresses: Vec<String>,
    pub port: u16,
    pub pairing_id: [u8; PAIRING_ID_LEN],
    pub psk: [u8; KEY_LEN],
    pub expires_at: i64,
}

impl Payload {
    pub fn info(&self) -> PairingInfo {
        PairingInfo {
            mac_name: self.mac_name.clone(),
            mac_key_b64: b64url(&self.mac_key),
            addresses: self.addresses.clone(),
            port: self.port,
            expires_at: iso_from_unix(self.expires_at),
        }
    }

    pub fn encode(&self) -> String {
        let json = PayloadJson {
            v: 1,
            mac_name: self.mac_name.clone(),
            mac_key: b64url(&self.mac_key),
            addrs: self.addresses.clone(),
            port: self.port,
            pid: b64url(&self.pairing_id),
            psk: b64url(&self.psk),
            exp: self.expires_at,
        };
        let json = serde_json::to_vec(&json).expect("the payload serialises");
        format!("{PAYLOAD_PREFIX}d={}", b64url(&json))
    }

    pub fn parse(text: &str) -> Result<Self> {
        let invalid = || SyncError::invalid("This is not a LokalBot pairing code.");
        let query = text
            .trim()
            .strip_prefix(PAYLOAD_PREFIX)
            .ok_or_else(invalid)?;
        let data = query
            .split('&')
            .find_map(|pair| pair.strip_prefix("d="))
            .ok_or_else(invalid)?;
        let json = b64url_decode(data).map_err(|_| invalid())?;
        let json: PayloadJson = serde_json::from_slice(&json).map_err(|_| invalid())?;
        if json.v != 1 {
            return Err(SyncError::invalid(
                "This pairing code is from a newer LokalBot. Update this app and try again.",
            ));
        }
        let pairing_id: [u8; PAIRING_ID_LEN] = b64url_decode(&json.pid)?
            .try_into()
            .map_err(|_| invalid())?;
        Ok(Self {
            mac_name: json.mac_name,
            mac_key: key_array(&b64url_decode(&json.mac_key)?, "Mac key")?,
            addresses: json.addrs,
            port: json.port,
            pairing_id,
            psk: key_array(&b64url_decode(&json.psk)?, "pairing secret")?,
            expires_at: json.exp,
        })
    }
}
