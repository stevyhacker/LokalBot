//! Think on the user's own ChatGPT or Claude plan instead of an API key
//! (`Engines/Subscription/`). Signing in alone sends no content; Think uses a
//! plan only after the user approves its consent entry
//! ([`SubscriptionPlan::consent_key`]). Plan errors stop the request; nothing
//! falls back to another provider or billing path.

pub mod chatgpt;
pub mod claude;
mod loopback;

use lokalbot_core::settings::SubscriptionPlan;

/// Failures a plan reports to the user (`ChatGPTPlanError`,
/// `ClaudePlanError`, `SubscriptionPlanError`).
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
    /// ChatGPT sign-ins are kept only in the system credential store.
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
}

/// The [`PlanError`] inside an `anyhow::Error`, if any.
pub fn plan_error(err: &anyhow::Error) -> Option<&PlanError> {
    err.downcast_ref::<PlanError>()
}
