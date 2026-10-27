//! The endpoint pi's `lokalbot` provider talks to (`AgentLLMEndpoint.swift`,
//! `ThinkExecution.agentResolution`).
//!
//! The built-in Think model is the llama-server `Role::Main`; a session holds
//! a [`lokalbot_ai::Lease`] on it so an unrelated model load cannot unload it
//! mid-conversation. Ollama and OpenAI-compatible servers follow the same
//! remote-origin consent as the rest of Think, and Agent Mode additionally
//! requires HTTPS for anything that is not on this computer (the extension
//! enforces it again). The ChatGPT plan is reached through a relay on this
//! computer that holds the plan's tokens
//! ([`lokalbot_ai::plans::chatgpt::relay`]); its own approval stands in for
//! the origin check.

use lokalbot_ai::plans::PlanError;
use lokalbot_core::Settings;
use lokalbot_core::access::{is_loopback_url, origin_of};
use lokalbot_core::settings::{SubscriptionPlan, SummarizerBackend};

/// Which request fields carry a reasoning level to this server. The
/// extension writes them (`applyReasoningLevel` in its index.ts).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ReasoningDialect {
    LlamaServer,
    OpenAi,
    OpenRouter,
    Ollama,
    Generic,
}

impl ReasoningDialect {
    pub fn as_str(self) -> &'static str {
        match self {
            ReasoningDialect::LlamaServer => "llama-server",
            ReasoningDialect::OpenAi => "openai",
            ReasoningDialect::OpenRouter => "openrouter",
            ReasoningDialect::Ollama => "ollama",
            ReasoningDialect::Generic => "generic",
        }
    }

    /// `ChatCompletionDialect.inferred(from:)`.
    pub fn inferred(base_url: &str) -> Self {
        let host = host(base_url).unwrap_or_default();
        if host == "api.openai.com" {
            ReasoningDialect::OpenAi
        } else if host == "openrouter.ai" || host.ends_with(".openrouter.ai") {
            ReasoningDialect::OpenRouter
        } else {
            ReasoningDialect::Generic
        }
    }
}

/// pi-ai's names for the wire formats Agent Mode uses.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub enum ProviderApi {
    /// Local and OpenAI-compatible servers.
    #[default]
    ChatCompletions,
    /// The ChatGPT plan relay.
    Responses,
}

impl ProviderApi {
    pub fn as_str(self) -> &'static str {
        match self {
            ProviderApi::ChatCompletions => "openai-completions",
            ProviderApi::Responses => "openai-responses",
        }
    }
}

/// A resolved endpoint.
#[derive(Clone, PartialEq, Eq)]
pub struct LlmEndpoint {
    /// Ends in `/v1` for llama-server and Ollama.
    pub base_url: String,
    pub model: String,
    pub context_tokens: u32,
    pub api_key: Option<String>,
    pub reasoning_dialect: ReasoningDialect,
    /// The wire format pi's provider speaks to `base_url`.
    pub api: ProviderApi,
    /// Set when requests run on a subscription plan through LokalBot's
    /// relay: `base_url` is on this computer, but the content goes to the
    /// plan's provider.
    pub plan: Option<SubscriptionPlan>,
}

impl std::fmt::Debug for LlmEndpoint {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("LlmEndpoint")
            .field("base_url", &self.base_url)
            .field("model", &self.model)
            .field("context_tokens", &self.context_tokens)
            .field("api_key", &self.api_key.as_ref().map(|_| "…"))
            .field("reasoning_dialect", &self.reasoning_dialect)
            .field("api", &self.api)
            .field("plan", &self.plan)
            .finish()
    }
}

/// Matches the built-in Think server's window, so Agent Mode compacts at the
/// same boundary; external servers use it as a conservative declared window.
pub const DEFAULT_CONTEXT_TOKENS: u32 = 32_768;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Resolution {
    /// The caller leases the built-in server and builds the endpoint from it.
    BuiltIn {
        model_id: String,
    },
    /// The caller starts a ChatGPT plan relay for the task and points pi at it.
    ChatGptPlan {
        model: String,
    },
    Ready(LlmEndpoint),
    Unsupported(String),
}

/// Settings to endpoint, without starting anything. `api_key` is the stored
/// OpenAI-compatible key (presentation passes `None`).
pub fn resolve(settings: &Settings, api_key: Option<String>) -> Resolution {
    match settings.summarizer_backend {
        SummarizerBackend::BuiltIn => {
            match lokalbot_ai::catalog::entry(&settings.built_in_model_id)
                .filter(|entry| entry.kind == lokalbot_ai::ModelKind::Text)
            {
                Some(entry) => Resolution::BuiltIn {
                    model_id: entry.id.to_string(),
                },
                None => Resolution::Unsupported(
                    "The selected built-in model is no longer available. Pick a model under Settings → Models.".into(),
                ),
            }
        }
        SummarizerBackend::Ollama => {
            let base = settings.ollama_base_url.trim().trim_end_matches('/');
            if let Err(reason) = remote_allowed(
                base,
                settings,
                "The Ollama server URL under Settings → Models isn't a valid URL.",
                "Approve this remote Ollama server under Settings → Models before Agent Mode sends context to it.",
                "Remote Ollama servers must use HTTPS so meeting context is encrypted in transit.",
            ) {
                return Resolution::Unsupported(reason);
            }
            let model = settings.ollama_model.trim();
            if model.is_empty() {
                return Resolution::Unsupported(
                    "Pick an Ollama model under Settings → Models — Agent Mode needs an explicit model."
                        .into(),
                );
            }
            Resolution::Ready(LlmEndpoint {
                base_url: format!("{base}/v1"),
                model: model.to_string(),
                context_tokens: DEFAULT_CONTEXT_TOKENS,
                api_key: None,
                reasoning_dialect: ReasoningDialect::Ollama,
                api: ProviderApi::ChatCompletions,
                plan: None,
            })
        }
        SummarizerBackend::OpenAICompatible => {
            let base = settings.openai_base_url.trim().trim_end_matches('/');
            if let Err(reason) = remote_allowed(
                base,
                settings,
                "The server URL under Settings → Models isn't a valid URL.",
                "Approve this remote inference server under Settings → Models before Agent Mode sends context to it.",
                "Remote inference servers must use HTTPS; LokalBot will not send meeting context or API keys over HTTP.",
            ) {
                return Resolution::Unsupported(reason);
            }
            let model = settings.openai_model.trim();
            if model.is_empty() {
                return Resolution::Unsupported(
                    "Set a model name for the OpenAI-compatible server under Settings → Models."
                        .into(),
                );
            }
            Resolution::Ready(LlmEndpoint {
                base_url: anthropic_chat_root(base),
                model: model.to_string(),
                context_tokens: DEFAULT_CONTEXT_TOKENS,
                api_key: api_key.filter(|key| !key.trim().is_empty()),
                reasoning_dialect: ReasoningDialect::inferred(base),
                api: ProviderApi::ChatCompletions,
                plan: None,
            })
        }
        // pi reaches the plan through a relay that holds the tokens, so
        // nothing here reads credentials.
        SummarizerBackend::ChatGptPlan => {
            let plan = SubscriptionPlan::ChatGpt;
            if !plan.is_approved(settings) {
                return Resolution::Unsupported(plan.approval_required_message());
            }
            let model = plan.model(settings);
            if model.is_empty() {
                return Resolution::Unsupported(PlanError::NoModel(plan).to_string());
            }
            Resolution::ChatGptPlan {
                model: model.to_string(),
            }
        }
        // Claude Code is an agent of its own; `claude -p` offers no model
        // endpoint for pi to call.
        SummarizerBackend::ClaudePlan => Resolution::Unsupported(
            "Agent Mode can't run on your Claude plan yet. Switch the Think model to a built-in model, Ollama, an OpenAI-compatible server, or your ChatGPT plan under Settings → Models.".into(),
        ),
    }
}

fn remote_allowed(
    base: &str,
    settings: &Settings,
    invalid: &str,
    unapproved: &str,
    insecure: &str,
) -> Result<(), String> {
    let lower = base.to_ascii_lowercase();
    let Some(origin) =
        origin_of(base).filter(|_| lower.starts_with("http://") || lower.starts_with("https://"))
    else {
        return Err(invalid.into());
    };
    if is_loopback_url(base) {
        return Ok(());
    }
    if !settings
        .approved_remote_inference_origins
        .iter()
        .any(|approved| approved.eq_ignore_ascii_case(&origin))
    {
        return Err(unapproved.into());
    }
    if !lower.starts_with("https://") {
        return Err(insecure.into());
    }
    Ok(())
}

/// pi speaks chat completions, which Anthropic serves under `/v1` whichever
/// form of its URL was entered (`AnthropicAPI.versionedRoot`).
fn anthropic_chat_root(base: &str) -> String {
    if host(base).as_deref() == Some("api.anthropic.com") && !base.ends_with("/v1") {
        return format!("{}/v1", base.trim_end_matches('/'));
    }
    base.to_string()
}

fn host(url: &str) -> Option<String> {
    let origin = origin_of(url)?;
    let authority = origin.split_once("://")?.1;
    Some(
        authority
            .rsplit_once(':')
            .filter(|(_, port)| port.chars().all(|c| c.is_ascii_digit()))
            .map(|(host, _)| host.to_string())
            .unwrap_or_else(|| authority.to_string()),
    )
}

/// Where a task's model runs, for the composer footer (`InferencePresentation`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Destination {
    OnDevice,
    Remote(String),
    Blocked(String),
}

impl Destination {
    pub fn label(&self) -> String {
        match self {
            Destination::OnDevice => "On this PC".into(),
            Destination::Remote(host) => format!("Remote · {host}"),
            Destination::Blocked(_) => "Model connection blocked".into(),
        }
    }

    pub fn is_remote(&self) -> bool {
        matches!(self, Destination::Remote(_))
    }
}

/// The model a task uses and where it runs (`AgentSessionController.ModelContext`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ModelContext {
    pub name: String,
    pub destination: Destination,
}

impl ModelContext {
    /// What a new task would use with these settings.
    pub fn from_settings(settings: &Settings) -> Self {
        match resolve(settings, None) {
            Resolution::Ready(endpoint) => Self::from_endpoint(&endpoint, settings),
            Resolution::BuiltIn { model_id } => Self {
                name: lokalbot_ai::catalog::entry(&model_id)
                    .map(|e| e.display_name.to_string())
                    .unwrap_or(model_id),
                destination: Destination::OnDevice,
            },
            Resolution::ChatGptPlan { model } => Self {
                name: model,
                destination: Destination::Remote(SubscriptionPlan::ChatGpt.title().into()),
            },
            Resolution::Unsupported(reason) => Self {
                name: think_display_name(settings),
                destination: Destination::Blocked(reason),
            },
        }
    }

    /// Bound to a launched connection, even if Settings change later.
    pub fn from_endpoint(endpoint: &LlmEndpoint, settings: &Settings) -> Self {
        let name = if settings.summarizer_backend == SummarizerBackend::BuiltIn {
            lokalbot_ai::catalog::entry(&endpoint.model)
                .map(|e| e.display_name.to_string())
                .unwrap_or_else(|| endpoint.model.clone())
        } else {
            endpoint.model.clone()
        };
        // A plan relay listens on this computer; the plan's provider answers.
        let destination = if let Some(plan) = endpoint.plan {
            Destination::Remote(plan.title().into())
        } else if is_loopback_url(&endpoint.base_url) {
            Destination::OnDevice
        } else {
            Destination::Remote(
                host(&endpoint.base_url).unwrap_or_else(|| "configured server".into()),
            )
        };
        Self { name, destination }
    }
}

fn think_display_name(settings: &Settings) -> String {
    match settings.summarizer_backend {
        SummarizerBackend::BuiltIn => lokalbot_ai::catalog::entry(&settings.built_in_model_id)
            .map(|e| e.display_name.to_string())
            .unwrap_or_else(|| settings.built_in_model_id.clone()),
        SummarizerBackend::Ollama => settings.ollama_model.clone(),
        SummarizerBackend::OpenAICompatible => settings.openai_model.clone(),
        SummarizerBackend::ChatGptPlan | SummarizerBackend::ClaudePlan => settings
            .think_plan()
            .map(|plan| plan.title().to_string())
            .unwrap_or_default(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn settings(change: impl FnOnce(&mut Settings)) -> Settings {
        let mut settings = Settings::default();
        change(&mut settings);
        settings
    }

    #[test]
    fn the_chatgpt_plan_needs_its_approval_and_a_model() {
        let unapproved = settings(|s| {
            s.summarizer_backend = SummarizerBackend::ChatGptPlan;
            s.chatgpt_plan_model = "gpt-6.1-sol".into();
            // An API-server approval for the same company is not the plan's.
            s.approved_remote_inference_origins = vec!["https://api.openai.com".into()];
        });
        assert_eq!(
            resolve(&unapproved, None),
            Resolution::Unsupported(SubscriptionPlan::ChatGpt.approval_required_message())
        );
        let no_model = settings(|s| {
            s.summarizer_backend = SummarizerBackend::ChatGptPlan;
            s.chatgpt_plan_model = " ".into();
            SubscriptionPlan::ChatGpt.set_approved(s, true);
        });
        assert_eq!(
            resolve(&no_model, None),
            Resolution::Unsupported(PlanError::NoModel(SubscriptionPlan::ChatGpt).to_string())
        );
        let ready = settings(|s| {
            s.summarizer_backend = SummarizerBackend::ChatGptPlan;
            s.chatgpt_plan_model = " gpt-6.1-sol ".into();
            SubscriptionPlan::ChatGpt.set_approved(s, true);
        });
        // A stored API key is never the plan's credential.
        assert_eq!(
            resolve(&ready, Some("sk-unrelated".into())),
            Resolution::ChatGptPlan {
                model: "gpt-6.1-sol".into()
            }
        );
        let context = ModelContext::from_settings(&ready);
        assert_eq!(context.name, "gpt-6.1-sol");
        assert_eq!(
            context.destination,
            Destination::Remote("ChatGPT plan".into())
        );
        assert_eq!(context.destination.label(), "Remote · ChatGPT plan");
    }

    #[test]
    fn a_relayed_plan_reads_as_remote_though_it_listens_here() {
        let endpoint = LlmEndpoint {
            base_url: "http://127.0.0.1:50123/v1".into(),
            model: "gpt-6.1-sol".into(),
            context_tokens: 128_000,
            api_key: Some("relay-key".into()),
            reasoning_dialect: ReasoningDialect::OpenAi,
            api: ProviderApi::Responses,
            plan: Some(SubscriptionPlan::ChatGpt),
        };
        let context = ModelContext::from_endpoint(&endpoint, &Settings::default());
        assert_eq!(
            context.destination,
            Destination::Remote("ChatGPT plan".into()),
            "a relay on this computer still sends content to OpenAI"
        );
        assert!(!format!("{endpoint:?}").contains("relay-key"));
        assert_eq!(ProviderApi::Responses.as_str(), "openai-responses");
        assert_eq!(ProviderApi::default().as_str(), "openai-completions");
    }

    #[test]
    fn the_claude_plan_is_not_an_agent_endpoint() {
        let mut plan = settings(|s| s.summarizer_backend = SummarizerBackend::ClaudePlan);
        // Even an approved plan: Claude Code offers no model endpoint.
        SubscriptionPlan::Claude.set_approved(&mut plan, true);
        match resolve(&plan, Some("key".into())) {
            Resolution::Unsupported(reason) => {
                assert!(reason.starts_with("Agent Mode can't run on your Claude plan"));
                assert!(reason.contains("your ChatGPT plan"));
            }
            other => panic!("{other:?}"),
        }
        assert!(matches!(
            ModelContext::from_settings(&plan).destination,
            Destination::Blocked(_)
        ));
    }

    #[test]
    fn built_in_resolves_to_its_model_id() {
        assert_eq!(
            resolve(&Settings::default(), None),
            Resolution::BuiltIn {
                model_id: "qwen3.5-4b".into()
            }
        );
        assert!(matches!(
            resolve(&settings(|s| s.built_in_model_id = "nope".into()), None),
            Resolution::Unsupported(_)
        ));
    }

    #[test]
    fn ollama_requires_an_explicit_model_and_appends_v1() {
        let base = settings(|s| s.summarizer_backend = SummarizerBackend::Ollama);
        assert!(
            matches!(resolve(&base, None), Resolution::Unsupported(r) if r.contains("explicit model"))
        );
        let ready = settings(|s| {
            s.summarizer_backend = SummarizerBackend::Ollama;
            s.ollama_base_url = "http://localhost:11434/".into();
            s.ollama_model = "qwen3:8b".into();
        });
        let Resolution::Ready(endpoint) = resolve(&ready, Some("ignored".into())) else {
            panic!("expected an endpoint");
        };
        assert_eq!(endpoint.base_url, "http://localhost:11434/v1");
        assert_eq!(endpoint.api_key, None);
        assert_eq!(endpoint.reasoning_dialect, ReasoningDialect::Ollama);
        assert_eq!(endpoint.context_tokens, 32_768);
        assert_eq!(endpoint.api, ProviderApi::ChatCompletions);
        assert_eq!(endpoint.plan, None);
    }

    #[test]
    fn openai_compatible_uses_base_url_verbatim_and_requires_a_model() {
        let missing = settings(|s| s.summarizer_backend = SummarizerBackend::OpenAICompatible);
        assert!(
            matches!(resolve(&missing, None), Resolution::Unsupported(r) if r.contains("model name"))
        );
        let ready = settings(|s| {
            s.summarizer_backend = SummarizerBackend::OpenAICompatible;
            s.openai_base_url = "http://127.0.0.1:1234/v1".into();
            s.openai_model = "local-model".into();
        });
        let Resolution::Ready(endpoint) = resolve(&ready, Some("sk-test".into())) else {
            panic!("expected an endpoint");
        };
        assert_eq!(endpoint.base_url, "http://127.0.0.1:1234/v1");
        assert_eq!(endpoint.api_key.as_deref(), Some("sk-test"));
        assert_eq!(endpoint.reasoning_dialect, ReasoningDialect::Generic);
    }

    #[test]
    fn remote_servers_need_approval_and_https() {
        let unapproved = settings(|s| {
            s.summarizer_backend = SummarizerBackend::Ollama;
            s.ollama_base_url = "https://gpu.example.com".into();
            s.ollama_model = "m".into();
        });
        assert!(
            matches!(resolve(&unapproved, None), Resolution::Unsupported(r) if r.contains("Approve"))
        );
        // Approved but plain HTTP on a private network: Think may use it,
        // Agent Mode may not.
        let http = settings(|s| {
            s.summarizer_backend = SummarizerBackend::OpenAICompatible;
            s.openai_base_url = "http://192.168.1.20:8080/v1".into();
            s.openai_model = "m".into();
            s.approved_remote_inference_origins = vec!["http://192.168.1.20:8080".into()];
        });
        assert!(matches!(resolve(&http, None), Resolution::Unsupported(r) if r.contains("HTTPS")));
        let approved = settings(|s| {
            s.summarizer_backend = SummarizerBackend::OpenAICompatible;
            s.openai_base_url = "https://openrouter.ai/api/v1".into();
            s.openai_model = "z-ai/glm".into();
            s.approved_remote_inference_origins = vec!["https://openrouter.ai".into()];
        });
        let Resolution::Ready(endpoint) = resolve(&approved, None) else {
            panic!("expected an endpoint");
        };
        assert_eq!(endpoint.reasoning_dialect, ReasoningDialect::OpenRouter);
        assert_eq!(
            ModelContext::from_endpoint(&endpoint, &approved).destination,
            Destination::Remote("openrouter.ai".into())
        );
    }

    #[test]
    fn dialects_name_their_reasoning_fields() {
        assert_eq!(
            ReasoningDialect::inferred("https://api.openai.com/v1"),
            ReasoningDialect::OpenAi
        );
        assert_eq!(ReasoningDialect::LlamaServer.as_str(), "llama-server");
        assert_eq!(
            anthropic_chat_root("https://api.anthropic.com"),
            "https://api.anthropic.com/v1"
        );
    }

    #[test]
    fn presentation_for_a_new_task() {
        let context = ModelContext::from_settings(&Settings::default());
        assert_eq!(context.destination, Destination::OnDevice);
        assert_eq!(context.destination.label(), "On this PC");
        assert!(!context.name.is_empty());
    }
}
