//! Static keys, fingerprints, randomness and the base64 flavour the
//! pairing payload uses.

use base64::Engine as _;
use base64::alphabet::URL_SAFE;
use base64::engine::DecodePaddingMode;
use base64::engine::general_purpose::{GeneralPurpose, GeneralPurposeConfig, URL_SAFE_NO_PAD};
use sha2::{Digest, Sha256};
use snow::params::DHChoice;
use snow::resolvers::{CryptoResolver, DefaultResolver};

use crate::error::{Result, SyncError};

pub(crate) const KEY_LEN: usize = 32;

/// An X25519 key pair. The platform keeps the private half in the Keychain
/// or behind the Android Keystore and hands it back at construction.
#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct StaticKey {
    pub private_key: Vec<u8>,
    pub public_key: Vec<u8>,
}

impl std::fmt::Debug for StaticKey {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("StaticKey")
            .field("public_key", &fingerprint(&self.public_key))
            .finish_non_exhaustive()
    }
}

/// A fresh random static key pair.
pub(crate) fn generate() -> StaticKey {
    let private = random_bytes::<KEY_LEN>();
    let public = public_key(&private).expect("a 32-byte private key always has a public key");
    StaticKey {
        private_key: private.to_vec(),
        public_key: public.to_vec(),
    }
}

/// The X25519 public key for a 32-byte private key.
pub(crate) fn public_key(private: &[u8]) -> Result<[u8; KEY_LEN]> {
    let private = key_array(private, "private key")?;
    let mut dh = DefaultResolver
        .resolve_dh(&DHChoice::Curve25519)
        .ok_or_else(|| SyncError::crypto("X25519 is unavailable"))?;
    dh.set(&private);
    key_array(dh.pubkey(), "public key")
}

/// First 16 hex characters of SHA-256 over the public key (Bonjour TXT `k`).
pub(crate) fn fingerprint(public: &[u8]) -> String {
    let digest = Sha256::digest(public);
    hex::encode(&digest[..8])
}

pub(crate) fn key_array(bytes: &[u8], what: &str) -> Result<[u8; KEY_LEN]> {
    bytes.try_into().map_err(|_| {
        SyncError::invalid(format!(
            "The {what} must be {KEY_LEN} bytes, not {}.",
            bytes.len()
        ))
    })
}

pub(crate) fn random_bytes<const N: usize>() -> [u8; N] {
    let mut bytes = [0u8; N];
    getrandom::fill(&mut bytes).expect("the system random number generator failed");
    bytes
}

/// base64url without padding, as in the pairing payload.
pub(crate) fn b64url(bytes: &[u8]) -> String {
    URL_SAFE_NO_PAD.encode(bytes)
}

/// Decodes base64url with or without padding.
pub(crate) fn b64url_decode(text: &str) -> Result<Vec<u8>> {
    const LENIENT: GeneralPurpose = GeneralPurpose::new(
        &URL_SAFE,
        GeneralPurposeConfig::new().with_decode_padding_mode(DecodePaddingMode::Indifferent),
    );
    LENIENT
        .decode(text.trim())
        .map_err(|e| SyncError::invalid(format!("Not base64url: {e}")))
}
