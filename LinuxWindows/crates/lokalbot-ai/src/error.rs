use std::time::Duration;

#[derive(Debug, thiserror::Error)]
pub enum AiError {
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
    #[error("LLM server error: response was truncated at the model output limit")]
    Truncated { partial: String },
    #[error("No Think model is selected. Pick one in Settings → Models.")]
    NoModel,
    #[error("Model {0} is not downloaded yet (Settings → Models).")]
    ModelMissing(String),
    #[error("Local LLM server failed to start: {0}")]
    ServerStart(String),
    #[error(
        "An open Agent Mode task is keeping {held} loaded, so the built-in model can't be changed. Close that task, then try again."
    )]
    ModelHeld { held: String },
    #[error("The operation was cancelled.")]
    Cancelled,
    #[error("{0}")]
    Unavailable(String),
}

impl AiError {
    pub fn is_retryable(&self) -> bool {
        match self {
            AiError::ServerUnreachable(_) => true,
            AiError::HttpStatus { code, .. } => {
                matches!(code, 408 | 409 | 425 | 429) || (500..=599).contains(code)
            }
            _ => false,
        }
    }

    pub fn is_rate_limit(&self) -> bool {
        matches!(self, AiError::HttpStatus { code: 429, .. })
    }

    pub fn retry_after(&self) -> Option<Duration> {
        match self {
            AiError::HttpStatus { retry_after, .. } => *retry_after,
            _ => None,
        }
    }
}

pub fn ai_error(err: &anyhow::Error) -> Option<&AiError> {
    err.downcast_ref::<AiError>()
}

pub(crate) fn is_cancelled(err: &anyhow::Error) -> bool {
    matches!(ai_error(err), Some(AiError::Cancelled))
}

pub(crate) fn check_cancelled(cancel: &std::sync::atomic::AtomicBool) -> anyhow::Result<()> {
    if cancel.load(std::sync::atomic::Ordering::Relaxed) {
        Err(AiError::Cancelled.into())
    } else {
        Ok(())
    }
}
