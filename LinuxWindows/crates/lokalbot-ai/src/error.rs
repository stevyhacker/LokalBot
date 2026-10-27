use std::time::Duration;

/// Failures callers branch on. Wording follows the macOS `TextEngineError`,
/// `LlamaServer.ServerError` and `ModelDownloadManager` messages.
#[derive(Debug, thiserror::Error)]
pub enum AiError {
    /// The server is remote and its origin is not approved (or not HTTPS).
    #[error("{0}")]
    ConsentRequired(String),
    #[error("Can't reach {0}. Verify that the configured LLM server is available.")]
    ServerUnreachable(String),
    #[error("LLM server returned HTTP {code}: {detail}")]
    HttpStatus {
        code: u16,
        detail: String,
        retry_after: Option<Duration>,
    },
    #[error("LLM server error: {0}")]
    BadResponse(String),
    /// The reply hit `max_tokens`; `partial` holds the visible text so far.
    #[error("LLM server error: response was truncated at the model output limit")]
    Truncated { partial: String },
    #[error("No Think model is selected. Pick one in Settings → Models.")]
    NoModel,
    #[error("Model {0} is not downloaded yet (Settings → Models).")]
    ModelMissing(String),
    #[error("Local LLM server failed to start: {0}")]
    ServerStart(String),
    /// Messages contain "cancelled" so callers can recognize them in text.
    #[error("The operation was cancelled.")]
    Cancelled,
    #[error("{0}")]
    Unavailable(String),
}

impl AiError {
    /// 408/409/425/429/5xx and transport failures (`TextEngineError.isRetryable`).
    pub fn is_retryable(&self) -> bool {
        match self {
            AiError::ServerUnreachable(_) => true,
            AiError::HttpStatus { code, .. } => {
                matches!(code, 408 | 409 | 425 | 429) || (500..=599).contains(code)
            }
            _ => false,
        }
    }

    pub fn retry_after(&self) -> Option<Duration> {
        match self {
            AiError::HttpStatus { retry_after, .. } => *retry_after,
            _ => None,
        }
    }
}

/// The [`AiError`] inside an `anyhow::Error`, if any.
pub fn ai_error(err: &anyhow::Error) -> Option<&AiError> {
    err.downcast_ref::<AiError>()
}

pub(crate) fn is_cancelled(err: &anyhow::Error) -> bool {
    matches!(ai_error(err), Some(AiError::Cancelled))
}

/// Shared cancellation check for setup, downloads and inference jobs.
pub(crate) fn check_cancelled(cancel: &std::sync::atomic::AtomicBool) -> anyhow::Result<()> {
    if cancel.load(std::sync::atomic::Ordering::Relaxed) {
        Err(AiError::Cancelled.into())
    } else {
        Ok(())
    }
}
