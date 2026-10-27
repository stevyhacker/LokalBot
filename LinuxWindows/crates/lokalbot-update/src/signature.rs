//! Sparkle-compatible Ed25519 signatures over the update archive's bytes.
//!
//! The macOS app's `SUPublicEDKey` verifies these, and the release signs
//! them with the same `SPARKLE_PRIVATE_KEY` that `sign_update` uses for the
//! DMG. Sparkle's private key is base64 text in one of two forms
//! (`common_cli/Secret.swift`): a 32-byte seed, or, for keys made by older
//! Sparkle releases, the 64-byte orlp expanded secret key followed by the
//! 32-byte public key. Both sign identically.

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use ed25519_dalek::hazmat::{ExpandedSecretKey, raw_sign};
use ed25519_dalek::{Sha512, Signature, SigningKey, VerifyingKey};

#[derive(Debug, PartialEq, Eq, thiserror::Error)]
pub enum SignatureError {
    #[error("the public key is not a base64 Ed25519 key")]
    InvalidPublicKey,
    /// Never echoes the key text, which may be the secret itself.
    #[error("the private key is not a base64 Sparkle Ed25519 key (32 or 96 bytes)")]
    InvalidPrivateKey,
    #[error("the signature is not a base64 Ed25519 signature")]
    Malformed,
    #[error("the signature does not match the archive and the update key")]
    Mismatch,
}

/// The key installed copies trust.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PublicKey(VerifyingKey);

impl PublicKey {
    pub fn from_base64(text: &str) -> Result<Self, SignatureError> {
        let bytes: [u8; 32] = STANDARD
            .decode(text.trim())
            .ok()
            .and_then(|bytes| bytes.try_into().ok())
            .ok_or(SignatureError::InvalidPublicKey)?;
        VerifyingKey::from_bytes(&bytes)
            .map(Self)
            .map_err(|_| SignatureError::InvalidPublicKey)
    }

    /// `SUPublicEDKey` from `LokalBot/Info.plist`.
    pub fn embedded() -> Self {
        Self::from_base64(crate::PUBLIC_KEY).expect("the embedded update key is valid")
    }

    pub fn to_base64(&self) -> String {
        STANDARD.encode(self.0.as_bytes())
    }

    /// Checks `signature` (base64) over `message`. Strict verification
    /// rejects small-order keys and non-canonical signatures.
    pub fn verify(&self, message: &[u8], signature: &str) -> Result<(), SignatureError> {
        let signature = decode_signature(signature)?;
        self.0
            .verify_strict(message, &signature)
            .map_err(|_| SignatureError::Mismatch)
    }
}

/// Parses a base64 signature without checking it.
pub fn decode_signature(text: &str) -> Result<Signature, SignatureError> {
    let bytes: [u8; 64] = STANDARD
        .decode(text.trim())
        .ok()
        .and_then(|bytes| bytes.try_into().ok())
        .ok_or(SignatureError::Malformed)?;
    Ok(Signature::from_bytes(&bytes))
}

/// The release key. Only the release tool and tests hold one.
pub struct SecretKey {
    expanded: ExpandedSecretKey,
    public: VerifyingKey,
}

impl SecretKey {
    /// Reads Sparkle's base64 private key text (surrounding whitespace is
    /// ignored, as `sign_update --ed-key-file` does).
    pub fn from_sparkle(text: &str) -> Result<Self, SignatureError> {
        let bytes = STANDARD
            .decode(text.trim())
            .map_err(|_| SignatureError::InvalidPrivateKey)?;
        match bytes.len() {
            32 => {
                let seed: [u8; 32] = bytes.try_into().expect("checked length");
                let signing = SigningKey::from_bytes(&seed);
                Ok(Self {
                    expanded: ExpandedSecretKey::from(&seed),
                    public: signing.verifying_key(),
                })
            }
            96 => {
                let expanded: [u8; 64] = bytes[..64].try_into().expect("checked length");
                let public: [u8; 32] = bytes[64..].try_into().expect("checked length");
                let public = VerifyingKey::from_bytes(&public)
                    .map_err(|_| SignatureError::InvalidPrivateKey)?;
                let expanded = ExpandedSecretKey::from_bytes(&expanded);
                // The stored public half must belong to the secret half, or
                // every signature would fail to verify.
                if VerifyingKey::from(&expanded) != public {
                    return Err(SignatureError::InvalidPrivateKey);
                }
                Ok(Self { expanded, public })
            }
            _ => Err(SignatureError::InvalidPrivateKey),
        }
    }

    pub fn public_key(&self) -> PublicKey {
        PublicKey(self.public)
    }

    /// The base64 signature of `message`.
    pub fn sign(&self, message: &[u8]) -> String {
        let signature = raw_sign::<Sha512>(&self.expanded, message, &self.public);
        STANDARD.encode(signature.to_bytes())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sha2::Digest as _;

    /// Throwaway seeds for tests only; never the release key.
    const SEED: [u8; 32] = [7; 32];
    const OTHER_SEED: [u8; 32] = [9; 32];

    fn seed_key(seed: [u8; 32]) -> String {
        STANDARD.encode(seed)
    }

    /// Sparkle's older format: orlp's expanded key (clamped SHA-512 of the
    /// seed) followed by the public key.
    fn legacy_key(seed: [u8; 32]) -> String {
        let mut expanded: [u8; 64] = sha2::Sha512::digest(seed).into();
        expanded[0] &= 248;
        expanded[31] &= 127;
        expanded[31] |= 64;
        let public = SigningKey::from_bytes(&seed).verifying_key();
        STANDARD.encode([&expanded[..], public.as_bytes()].concat())
    }

    #[test]
    fn a_valid_signature_verifies() {
        let key = SecretKey::from_sparkle(&seed_key(SEED)).unwrap();
        let signature = key.sign(b"archive bytes");
        assert_eq!(
            key.public_key().verify(b"archive bytes", &signature),
            Ok(())
        );
    }

    #[test]
    fn both_sparkle_key_formats_sign_identically() {
        let seed = SecretKey::from_sparkle(&seed_key(SEED)).unwrap();
        let legacy = SecretKey::from_sparkle(&format!("  {}\n", legacy_key(SEED))).unwrap();
        assert_eq!(seed.public_key(), legacy.public_key());
        assert_eq!(seed.sign(b"archive"), legacy.sign(b"archive"));
        // And they match a standard Ed25519 signer.
        let standard = ed25519_dalek::Signer::sign(&SigningKey::from_bytes(&SEED), b"archive");
        assert_eq!(seed.sign(b"archive"), STANDARD.encode(standard.to_bytes()));
    }

    #[test]
    fn tampered_archives_and_signatures_fail() {
        let key = SecretKey::from_sparkle(&seed_key(SEED)).unwrap();
        let signature = key.sign(b"archive bytes");
        let public = key.public_key();
        assert_eq!(
            public.verify(b"archive bytez", &signature),
            Err(SignatureError::Mismatch)
        );
        let mut bytes = STANDARD.decode(&signature).unwrap();
        bytes[10] ^= 1;
        assert_eq!(
            public.verify(b"archive bytes", &STANDARD.encode(&bytes)),
            Err(SignatureError::Mismatch)
        );
        assert_eq!(
            public.verify(b"archive bytes", "not base64!"),
            Err(SignatureError::Malformed)
        );
        assert_eq!(
            public.verify(b"archive bytes", &STANDARD.encode([0u8; 63])),
            Err(SignatureError::Malformed)
        );
    }

    #[test]
    fn a_different_key_is_rejected() {
        let signature = SecretKey::from_sparkle(&seed_key(SEED))
            .unwrap()
            .sign(b"archive bytes");
        let other = SecretKey::from_sparkle(&seed_key(OTHER_SEED))
            .unwrap()
            .public_key();
        assert_eq!(
            other.verify(b"archive bytes", &signature),
            Err(SignatureError::Mismatch)
        );
        assert_eq!(
            PublicKey::embedded().verify(b"archive bytes", &signature),
            Err(SignatureError::Mismatch)
        );
    }

    #[test]
    fn malformed_keys_are_refused_without_echoing_them() {
        for text in [
            "",
            "c2VjcmV0",
            "not base64 at all",
            &STANDARD.encode([1u8; 64]),
        ] {
            let error = SecretKey::from_sparkle(text).err().unwrap();
            assert_eq!(error, SignatureError::InvalidPrivateKey);
            assert!(text.is_empty() || !error.to_string().contains(text));
        }
        // A legacy key whose public half belongs to another seed.
        let mut mixed = STANDARD.decode(legacy_key(SEED)).unwrap();
        let other = SigningKey::from_bytes(&OTHER_SEED).verifying_key();
        mixed[64..].copy_from_slice(other.as_bytes());
        assert!(SecretKey::from_sparkle(&STANDARD.encode(mixed)).is_err());
        assert_eq!(
            PublicKey::from_base64("AAAA"),
            Err(SignatureError::InvalidPublicKey)
        );
    }

    #[test]
    fn the_embedded_key_is_sparkles_public_key() {
        assert_eq!(PublicKey::embedded().to_base64(), crate::PUBLIC_KEY);
    }
}
