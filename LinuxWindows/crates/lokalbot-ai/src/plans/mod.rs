pub mod antigravity;
pub mod chatgpt;
pub mod claude;
pub(crate) mod cli;
pub mod gemini;
mod loopback;

use lokalbot_core::settings::SubscriptionPlan;

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum PlanError {
    #[error("Choose a model for your {} under Settings → Models.", .0.title())]
    NoModel(SubscriptionPlan),

    #[error("Sign in with ChatGPT under Settings → Models → Think to use your ChatGPT plan.")]
    SignedOut,
    #[error(
        "Your ChatGPT sign-in expired or was disconnected. Sign in again under Settings → Models → Think."
    )]
    SignInRequired,
    #[error(
        "This ChatGPT sign-in doesn't allow requests on your plan. Sign in again and allow plan usage, or use another provider."
    )]
    PlanUsageNotGranted,
    #[error("{0}")]
    SignInFailed(String),
    #[error("ChatGPT sign-in was cancelled.")]
    SignInCancelled,
    #[error(
        "Your ChatGPT plan's usage limit for LokalBot was reached. Check usage at chatgpt.com/settings/usage."
    )]
    UsageLimitReached,
    #[error("This ChatGPT account can't use its plan in LokalBot: {0}")]
    NotEligible(String),
    #[error("ChatGPT plan requests don't support this option: {0}")]
    UnsupportedRequest(String),
    #[error("ChatGPT plan configuration error: {0}")]
    Misconfigured(String),
    #[error(
        "LokalBot keeps your ChatGPT sign-in only in the system credential store, which isn't available: {0}"
    )]
    CredentialStoreUnavailable(String),

    #[error(
        "Claude Code isn't installed on this PC. Install it, sign in by running claude in a terminal, then choose Claude plan again under Settings → Models → Think."
    )]
    ClaudeNotInstalled,
    #[error(
        "Claude Code isn't signed in. Run claude in a terminal and sign in with your Claude account. LokalBot never sees your Claude sign-in."
    )]
    ClaudeSignInRequired,
    #[error("Your Claude plan's usage limit was reached. {0}")]
    ClaudeUsageLimitReached(String),
    #[error("{0}")]
    ClaudeFailed(String),

    #[error(
        "Antigravity CLI (agy) isn't installed on this PC. Install it, sign in by running agy in a terminal, then choose Antigravity plan again under Settings → Models → Think."
    )]
    AntigravityNotInstalled,
    #[error(
        "Antigravity CLI isn't signed in. Run agy in a terminal and sign in with your Google account. LokalBot never sees your Antigravity sign-in."
    )]
    AntigravitySignInRequired,
    #[error("Your Antigravity plan's usage limit was reached. {0}")]
    AntigravityUsageLimitReached(String),
    #[error("{0}")]
    AntigravityFailed(String),

    #[error(
        "Gemini CLI isn't installed on this PC. Install it, sign in by running gemini in a terminal, then choose Gemini plan again under Settings → Models → Think."
    )]
    GeminiNotInstalled,
    #[error(
        "Gemini CLI isn't signed in. Run gemini in a terminal and sign in with your Google account. LokalBot never sees your Google sign-in."
    )]
    GeminiSignInRequired,
    #[error("Your Gemini plan's usage limit was reached. {0}")]
    GeminiUsageLimitReached(String),
    #[error("{0}")]
    GeminiFailed(String),
}

pub fn plan_error(err: &anyhow::Error) -> Option<&PlanError> {
    err.downcast_ref::<PlanError>()
}
