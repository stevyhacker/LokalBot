#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error, uniffi::Error)]
#[uniffi(flat_error)]
pub enum SyncError {
    #[error("{0}")]
    Io(String),
    #[error("{0}")]
    Protocol(String),
    #[error("{0}")]
    Crypto(String),
    #[error("{0}")]
    Storage(String),
    #[error("{0}")]
    NotPaired(String),
    #[error("{0}")]
    Unreachable(String),
    #[error("{0}")]
    Interrupted(String),
    #[error("{0}")]
    PairingRejected(String),
    #[error("{0}")]
    PairingExpired(String),
    #[error("{0}")]
    Revoked(String),
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
        Self::NotPaired("This device is not paired with a computer.".into())
    }

    pub(crate) fn revoked() -> Self {
        Self::Revoked("Your computer removed this device. Its local copy was erased.".into())
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
