//! Files sealed with AES-256-GCM, as `nonce (12) ‖ ciphertext ‖ tag (16)`
//! (`AES.GCM.SealedBox.combined`), with no associated data. Ask conversations,
//! Personal Context and the dictation learning log all share the per-install
//! `chat-key`. A Mac seals the same files with its own Keychain key, so a copied
//! file can't be opened here: callers report that and never overwrite it.

use std::sync::Arc;

use aes_gcm::aead::{Aead as _, AeadCore as _, KeyInit as _, OsRng};
use aes_gcm::{Aes256Gcm, Key, Nonce};
use anyhow::{Result, anyhow};

pub const KEY_BYTES: usize = 32;
const NONCE_BYTES: usize = 12;

pub type SealingKey = [u8; KEY_BYTES];

/// Gives the `chat-key`, creating it when the flag is set. The credential store
/// lives above this crate, so the engine installs this on the library.
pub type KeySource = Arc<dyn Fn(bool) -> Result<SealingKey> + Send + Sync>;

pub fn seal(key: &SealingKey, clear: &[u8]) -> Result<Vec<u8>> {
    let cipher = Aes256Gcm::new(Key::<Aes256Gcm>::from_slice(key));
    let nonce = Aes256Gcm::generate_nonce(&mut OsRng);
    let sealed = cipher
        .encrypt(&nonce, clear)
        .map_err(|_| anyhow!("could not encrypt the data"))?;
    let mut out = Vec::with_capacity(NONCE_BYTES + sealed.len());
    out.extend_from_slice(&nonce);
    out.extend_from_slice(&sealed);
    Ok(out)
}

/// `None` for another key or a damaged file.
pub fn open(key: &SealingKey, sealed: &[u8]) -> Option<Vec<u8>> {
    if sealed.len() < NONCE_BYTES {
        return None;
    }
    let (nonce, body) = sealed.split_at(NONCE_BYTES);
    let cipher = Aes256Gcm::new(Key::<Aes256Gcm>::from_slice(key));
    cipher.decrypt(Nonce::from_slice(nonce), body).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_sealed_box_opens_only_with_its_key() {
        let key = [7u8; KEY_BYTES];
        let sealed = seal(&key, b"hello").unwrap();
        // Nonce, the five bytes, and the tag.
        assert_eq!(sealed.len(), 12 + 5 + 16);
        assert_eq!(open(&key, &sealed).unwrap(), b"hello");
        assert!(open(&[8u8; KEY_BYTES], &sealed).is_none());
        assert!(open(&key, &sealed[..4]).is_none());
    }

    #[test]
    fn it_opens_the_layout_cryptokit_writes() {
        // `AES.GCM.seal(_, using:, nonce:)` for this key and nonce, combined.
        let key = [0x11u8; KEY_BYTES];
        let nonce = [0x22u8; NONCE_BYTES];
        let cipher = Aes256Gcm::new(Key::<Aes256Gcm>::from_slice(&key));
        let body = cipher
            .encrypt(Nonce::from_slice(&nonce), b"{}".as_slice())
            .unwrap();
        let mut combined = nonce.to_vec();
        combined.extend_from_slice(&body);
        assert_eq!(open(&key, &combined).unwrap(), b"{}");
    }
}
