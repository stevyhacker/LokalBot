//! The one error type every FFI call returns.

/// Errors crossing the FFI. Each variant carries a human-readable message;
/// Swift sees `SyncError.Io(message:)`, Kotlin `SyncException.Io`.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error, uniffi::Error)]
#[uniffi(flat_error)]
pub enum SyncError {
    /// Socket or file system failure, including timeouts.
    #[error("{0}")]
    Io(String),
    /// The peer broke the protocol or sent something unreadable.
    #[error("{0}")]
    Protocol(String),
    /// A handshake or decryption failed, or a key did not match.
    #[error("{0}")]
    Crypto(String),
    /// The local SQLite store failed.
    #[error("{0}")]
    Storage(String),
    /// The call needs a paired Mac and there is none.
    #[error("{0}")]
    NotPaired(String),
    /// No address of the Mac answered with a handshake.
    #[error("{0}")]
    Unreachable(String),
    /// The person declined the pairing on the Mac, or did not answer.
    #[error("{0}")]
    PairingRejected(String),
    /// The pairing code expired, was used or was cancelled.
    #[error("{0}")]
    PairingExpired(String),
    /// The Mac removed this device; the local copy has been erased.
    #[error("{0}")]
    Revoked(String),
    /// An argument was malformed.
    #[error("{0}")]
    InvalidInput(String),
}

pub type Result<T, E = SyncError> = std::result::Result<T, E>;

impl SyncError {
    pub(crate) fn io(message: impl Into<String>) -> Self {
        Self::Io(message.into())
    }

    pub(crate) fn protocol(message: impl Into<String>) -> Self {
        Self::Protocol(message.into())
    }

    pub(crate) fn crypto(message: impl Into<String>) -> Self {
        Self::Crypto(message.into())
    }

    pub(crate) fn invalid(message: impl Into<String>) -> Self {
        Self::InvalidInput(message.into())
    }

    pub(crate) fn not_paired() -> Self {
        Self::NotPaired("This device is not paired with a Mac.".into())
    }

    pub(crate) fn revoked() -> Self {
        Self::Revoked("The Mac removed this device. Its local copy was erased.".into())
    }
}

impl From<std::io::Error> for SyncError {
    fn from(error: std::io::Error) -> Self {
        Self::Io(error.to_string())
    }
}

impl From<rusqlite::Error> for SyncError {
    fn from(error: rusqlite::Error) -> Self {
        Self::Storage(error.to_string())
    }
}

impl From<snow::Error> for SyncError {
    fn from(error: snow::Error) -> Self {
        Self::Crypto(error.to_string())
    }
}
