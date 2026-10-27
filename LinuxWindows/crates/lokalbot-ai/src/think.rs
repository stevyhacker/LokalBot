//! Think, embedding and autocomplete clients (`Engines/TextEngine.swift`,
//! `ThinkExecution.swift`, `ReasoningLevels.swift`, `EmbeddingIndex.swift`).
//!
//! The built-in backend leases the local `llama-server` for each request.
//! Ollama and OpenAI-compatible servers on another machine are refused until
//! the user approves their exact origin (`access::remote_block_reason`).
//! Anthropic's API speaks its own Messages API ([`crate::anthropic`]). A
//! ChatGPT or Claude plan ([`crate::plans`]) needs its own approval entry.

use std::ops::Range;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, OnceLock};
use std::time::Duration;

use anyhow::Result;
use serde::de::DeserializeOwned;
use serde_json::{Value, json};

use lokalbot_core::Settings;
use lokalbot_core::access::{is_loopback_url, remote_block_reason};
use lokalbot_core::settings::{
    OpenRouterDataPolicy, ReasoningLevel, SubscriptionPlan, SummarizerBackend,
};

use crate::anthropic;
use crate::catalog::{self, ModelEntry};
use crate::error::AiError;
use crate::http;
use crate::json as model_json;
use crate::plans;
use crate::runtime::{Lease, RuntimeManager};

/// The built-in model's default thinking ceiling (`highReasoningBudgetTokens`).
pub const DEFAULT_THINKING_BUDGET: u32 = 8_192;
/// Ollama's context is pinned so it never silently drops the prompt's start.
pub const OLLAMA_CONTEXT_TOKENS: u32 = 16_384;
const BUILT_IN_CONTEXT_TOKENS: u32 = 32_768;
const FALLBACK_CONTEXT_TOKENS: u32 = 16_384;
/// Generation can take minutes for a long meeting on a laptop.
const CHAT_TIMEOUT: Duration = Duration::from_secs(900);

/// One chat request: a system prompt and a single user message (context
/// blocks already joined with blank lines, as on macOS).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ChatRequest {
    pub system: String,
    pub user: String,
    /// Shared material that comes before `user`, such as a transcript.
    /// Servers that cache prompts (Anthropic) mark its end; every other
    /// server gets it joined in front of `user` with blank lines.
    pub context: Vec<String>,
    pub max_tokens: Option<u32>,
    pub temperature: Option<f32>,
    /// Thinking tokens for this task; `Some(0)` disables thinking.
    pub reasoning_budget: Option<u32>,
    /// JSON Schema the reply must satisfy (decode-time grammar on llama-server
    /// and Ollama, `response_format` elsewhere).
    pub json_schema: Option<Value>,
    /// Return a reply cut off at `max_tokens` instead of failing.
    pub keep_truncated: bool,
}

impl ChatRequest {
    pub fn new(system: impl Into<String>, user: impl Into<String>) -> Self {
        Self {
            system: system.into(),
            user: user.into(),
            ..Default::default()
        }
    }

    pub fn max_tokens(mut self, tokens: u32) -> Self {
        self.max_tokens = Some(tokens);
        self
    }

    pub fn temperature(mut self, temperature: f32) -> Self {
        self.temperature = Some(temperature);
        self
    }

    pub fn reasoning_budget(mut self, tokens: u32) -> Self {
        self.reasoning_budget = Some(tokens);
        self
    }

    pub fn json_schema(mut self, schema: Value) -> Self {
        self.json_schema = Some(schema);
        self
    }

    pub fn keep_truncated(mut self) -> Self {
        self.keep_truncated = true;
        self
    }

    /// Material placed before the instruction in `user` (see [`Self::context`]).
    pub fn context(mut self, blocks: Vec<String>) -> Self {
        self.context = blocks;
        self
    }

    /// The whole user message: context blocks, then `user`, joined with
    /// blank lines.
    pub fn user_text(&self) -> String {
        if self.context.is_empty() {
            return self.user.clone();
        }
        self.context
            .iter()
            .chain(std::iter::once(&self.user))
            .cloned()
            .collect::<Vec<_>>()
            .join("\n\n")
    }
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Usage {
    pub prompt_tokens: Option<u64>,
    pub completion_tokens: Option<u64>,
}

/// A finished (or cut-off, or cancelled) reply.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Completion {
    /// Visible text, reasoning blocks removed.
    pub text: String,
    /// The reply hit `max_tokens`.
    pub truncated: bool,
    /// A stream stopped because the caller cancelled it.
    pub cancelled: bool,
    pub usage: Option<Usage>,
}

/// Request fields differ by server; keep the dialect explicit so one
/// provider's extensions never leak into another's request.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Dialect {
    LlamaServer,
    OpenAi,
    OpenRouter,
    Generic,
}

impl Dialect {
    pub fn inferred(base_url: &str) -> Self {
        let host = crate::http::host_label(base_url);
        let host = host.split(':').next().unwrap_or_default();
        if host == "api.openai.com" {
            Dialect::OpenAi
        } else if host == "openrouter.ai" || host.ends_with(".openrouter.ai") {
            Dialect::OpenRouter
        } else {
            Dialect::Generic
        }
    }
}

#[derive(Clone)]
enum Backend {
    BuiltIn {
        runtime: RuntimeManager,
        entry: &'static ModelEntry,
    },
    /// `/chat/completions` on an OpenAI-style server (including a llama-server
    /// reached directly, e.g. by the CLI through the app's marker).
    Server {
        base: String,
        model: String,
        api_key: Option<String>,
        dialect: Dialect,
        /// OpenRouter's provider data policy (other dialects ignore it).
        data_policy: OpenRouterDataPolicy,
    },
    Ollama {
        base: String,
        model: String,
    },
    /// Claude on Anthropic's Messages API.
    Anthropic(anthropic::Engine),
    ChatGptPlan(plans::chatgpt::Engine),
    ClaudePlan(plans::claude::Engine),
}

struct Inner {
    backend: Backend,
    level: ReasoningLevel,
    context_tokens: OnceLock<u32>,
    /// The local runtime, for the embedder (also used with remote Think).
    runtime: Option<RuntimeManager>,
}

/// The Think model: summaries, digests, Ask. Cheap to clone; `Send + Sync`.
#[derive(Clone)]
pub struct ThinkClient {
    inner: Arc<Inner>,
}

fn consent(url: &str, approved: &[String]) -> Result<()> {
    match remote_block_reason(url, approved) {
        Some(reason) => Err(AiError::ConsentRequired(reason).into()),
        None => Ok(()),
    }
}

fn trimmed_base(url: &str) -> String {
    url.trim().trim_end_matches('/').to_string()
}

impl ThinkClient {
    /// The Think backend `settings` select. Remote servers must be approved.
    /// An OpenAI-compatible API key comes from the platform keyring; pass it
    /// with [`with_api_key`](Self::with_api_key).
    pub fn new(runtime: &RuntimeManager, settings: &Settings) -> Result<Self> {
        let backend = match settings.summarizer_backend {
            SummarizerBackend::BuiltIn => {
                let entry = catalog::entry(&settings.built_in_model_id)
                    .filter(|e| e.kind == catalog::ModelKind::Text)
                    .ok_or_else(|| {
                        AiError::Unavailable("The selected built-in model is no longer available. Pick a model under Settings → Models.".into())
                    })?;
                Backend::BuiltIn {
                    runtime: runtime.clone(),
                    entry,
                }
            }
            SummarizerBackend::Ollama => {
                let base = trimmed_base(&settings.ollama_base_url);
                consent(&base, &settings.approved_remote_inference_origins)?;
                Backend::Ollama {
                    base,
                    model: settings.ollama_model.trim().to_string(),
                }
            }
            SummarizerBackend::OpenAICompatible => {
                let base = trimmed_base(&settings.openai_base_url);
                consent(&base, &settings.approved_remote_inference_origins)?;
                if settings.openai_model.trim().is_empty() {
                    return Err(AiError::NoModel.into());
                }
                if anthropic::is_anthropic(&base) {
                    // Claude's native Messages API: structured output within
                    // its schema subset, effort, refusals and prompt caching.
                    Backend::Anthropic(anthropic::Engine {
                        base,
                        model: settings.openai_model.trim().to_string(),
                        api_key: None,
                        level: settings.think_reasoning_level,
                    })
                } else {
                    Backend::Server {
                        dialect: Dialect::inferred(&base),
                        base,
                        model: settings.openai_model.trim().to_string(),
                        api_key: None,
                        data_policy: settings.open_router_data_policy,
                    }
                }
            }
            SummarizerBackend::ChatGptPlan | SummarizerBackend::ClaudePlan => {
                let plan = settings
                    .think_plan()
                    .expect("a plan backend names its plan");
                if !plan.is_approved(settings) {
                    return Err(AiError::ConsentRequired(plan.approval_required_message()).into());
                }
                match plan {
                    SubscriptionPlan::ChatGpt => Backend::ChatGptPlan(plans::chatgpt::Engine {
                        model: settings.chatgpt_plan_model.trim().to_string(),
                        level: settings.think_reasoning_level,
                        account: plans::chatgpt::shared(),
                    }),
                    SubscriptionPlan::Claude => Backend::ClaudePlan(plans::claude::Engine {
                        model: settings.claude_plan_model.trim().to_string(),
                        level: settings.think_reasoning_level,
                        runner: Arc::new(plans::claude::LiveRunner::default()),
                    }),
                }
            }
        };
        Ok(Self::with_runtime(
            backend,
            settings.think_reasoning_level,
            Some(runtime.clone()),
        ))
    }

    /// A llama-server reached directly (`http://127.0.0.1:17872/v1` and the
    /// marker's token), speaking the built-in dialect.
    pub fn llama_server(base_url: &str, token: &str, model_id: &str) -> Self {
        Self::from_backend(
            Backend::Server {
                base: trimmed_base(base_url),
                model: model_id.to_string(),
                api_key: Some(token.to_string()),
                dialect: Dialect::LlamaServer,
                data_policy: OpenRouterDataPolicy::PrivateOnly,
            },
            ReasoningLevel::Automatic,
        )
    }

    pub fn openai_compatible(
        base_url: &str,
        model: &str,
        api_key: Option<String>,
        approved: &[String],
    ) -> Result<Self> {
        let base = trimmed_base(base_url);
        consent(&base, approved)?;
        if anthropic::is_anthropic(&base) {
            return Ok(Self::from_backend(
                Backend::Anthropic(anthropic::Engine {
                    base,
                    model: model.to_string(),
                    api_key,
                    level: ReasoningLevel::Automatic,
                }),
                ReasoningLevel::Automatic,
            ));
        }
        Ok(Self::from_backend(
            Backend::Server {
                dialect: Dialect::inferred(&base),
                base,
                model: model.to_string(),
                api_key,
                data_policy: OpenRouterDataPolicy::PrivateOnly,
            },
            ReasoningLevel::Automatic,
        ))
    }

    pub fn ollama(base_url: &str, model: &str, approved: &[String]) -> Result<Self> {
        let base = trimmed_base(base_url);
        consent(&base, approved)?;
        Ok(Self::from_backend(
            Backend::Ollama {
                base,
                model: model.to_string(),
            },
            ReasoningLevel::Automatic,
        ))
    }

    fn from_backend(backend: Backend, level: ReasoningLevel) -> Self {
        Self::with_runtime(backend, level, None)
    }

    fn with_runtime(
        backend: Backend,
        level: ReasoningLevel,
        runtime: Option<RuntimeManager>,
    ) -> Self {
        Self {
            inner: Arc::new(Inner {
                backend,
                level,
                context_tokens: OnceLock::new(),
                runtime,
            }),
        }
    }

    /// The local embedder when its model is downloaded ("Search by meaning").
    pub fn embedder(&self) -> Option<EmbeddingClient> {
        let runtime = self.inner.runtime.as_ref()?;
        catalog::is_downloaded(runtime.paths(), catalog::embedding_entry())
            .then(|| EmbeddingClient::new(runtime))
    }

    /// Sets the API key for an OpenAI-compatible server or Anthropic's API
    /// (no effect otherwise).
    pub fn with_api_key(self, key: Option<String>) -> Self {
        let mut backend = self.inner.backend.clone();
        let key = key.filter(|k| !k.trim().is_empty());
        match &mut backend {
            Backend::Server {
                api_key, dialect, ..
            } if *dialect != Dialect::LlamaServer => *api_key = key,
            Backend::Anthropic(engine) => engine.api_key = key,
            _ => {}
        }
        Self::with_runtime(backend, self.inner.level, self.inner.runtime.clone())
    }

    /// Sets OpenRouter's provider data policy (no effect on other servers).
    pub fn with_openrouter_data_policy(self, policy: OpenRouterDataPolicy) -> Self {
        let mut backend = self.inner.backend.clone();
        if let Backend::Server { data_policy, .. } = &mut backend {
            *data_policy = policy;
        }
        Self::with_runtime(backend, self.inner.level, self.inner.runtime.clone())
    }

    pub fn with_reasoning_level(self, level: ReasoningLevel) -> Self {
        let mut backend = self.inner.backend.clone();
        match &mut backend {
            Backend::Anthropic(engine) => engine.level = level,
            Backend::ChatGptPlan(engine) => engine.level = level,
            Backend::ClaudePlan(engine) => engine.level = level,
            _ => {}
        }
        Self::with_runtime(backend, level, self.inner.runtime.clone())
    }

    /// The subscription plan this client runs on, if any.
    pub fn plan(&self) -> Option<SubscriptionPlan> {
        match &self.inner.backend {
            Backend::ChatGptPlan(_) => Some(SubscriptionPlan::ChatGpt),
            Backend::ClaudePlan(_) => Some(SubscriptionPlan::Claude),
            _ => None,
        }
    }

    // ---------------------------------------------------------- identity

    /// The model's name: "Qwen3.5 4B", "llama3.1:8b", "gpt-4.1-mini".
    pub fn model_label(&self) -> String {
        let named = |model: &str, fallback: &str| {
            if model.trim().is_empty() {
                fallback.to_string()
            } else {
                model.trim().to_string()
            }
        };
        match &self.inner.backend {
            Backend::BuiltIn { entry, .. } => entry.display_name.to_string(),
            Backend::Server { model, .. } | Backend::Ollama { model, .. } => {
                named(model, "default model")
            }
            Backend::Anthropic(engine) => named(&engine.model, "default model"),
            Backend::ChatGptPlan(engine) => named(&engine.model, SubscriptionPlan::ChatGpt.title()),
            Backend::ClaudePlan(engine) => named(&engine.model, "Claude Code default"),
        }
    }

    /// "on this PC", or the remote host.
    pub fn location(&self) -> String {
        match &self.inner.backend {
            Backend::BuiltIn { .. } => "on this PC".into(),
            Backend::Server { base, .. } | Backend::Ollama { base, .. } => {
                if is_loopback_url(base) {
                    "on this PC".into()
                } else {
                    crate::http::host_label(base)
                }
            }
            Backend::Anthropic(engine) => crate::http::host_label(&engine.base),
            Backend::ChatGptPlan(_) => SubscriptionPlan::ChatGpt.destination_host().into(),
            Backend::ClaudePlan(_) => SubscriptionPlan::Claude.destination_host().into(),
        }
    }

    /// "Qwen3.5 4B · on this PC", "llama3.1:8b · Ollama on this PC",
    /// "gpt-4.1 · api.openai.com".
    pub fn display_name(&self) -> String {
        if let Some(plan) = self.plan() {
            let model = self.model_label();
            return if model == plan.title() {
                model
            } else {
                format!("{model} · {}", plan.title())
            };
        }
        match &self.inner.backend {
            Backend::Ollama { .. } if self.is_local() => {
                format!("{} · Ollama on this PC", self.model_label())
            }
            Backend::Ollama { .. } => {
                format!("{} · Ollama at {}", self.model_label(), self.location())
            }
            _ => format!("{} · {}", self.model_label(), self.location()),
        }
    }

    /// Whether prompts stay on this machine.
    pub fn is_local(&self) -> bool {
        match &self.inner.backend {
            Backend::BuiltIn { .. } => true,
            Backend::Server { base, .. } | Backend::Ollama { base, .. } => is_loopback_url(base),
            Backend::Anthropic(_) | Backend::ChatGptPlan(_) | Backend::ClaudePlan(_) => false,
        }
    }

    pub fn is_built_in(&self) -> bool {
        matches!(self.inner.backend, Backend::BuiltIn { .. })
    }

    /// The built-in model runs on the CPU build (no GPU found or chosen).
    pub fn runs_on_cpu(&self) -> bool {
        match &self.inner.backend {
            Backend::BuiltIn { runtime, .. } => !runtime
                .active_backend()
                .is_some_and(crate::runtime::LlamaBackend::is_gpu),
            _ => false,
        }
    }

    /// Changes whenever a different model or server would answer; part of
    /// generation checkpoints.
    pub fn checkpoint_identity(&self) -> String {
        match &self.inner.backend {
            Backend::BuiltIn { entry, .. } => format!("built-in|{}|{}", entry.id, entry.sha256),
            Backend::Server {
                base,
                model,
                dialect,
                ..
            } => format!("server|{base}|{model}|{dialect:?}"),
            Backend::Ollama { base, model } => format!("ollama|{base}|{model}"),
            Backend::Anthropic(engine) => {
                format!("anthropic|{}|{}|messages", engine.base, engine.model)
            }
            Backend::ChatGptPlan(engine) => format!("chatgpt-plan|{}|responses", engine.model),
            Backend::ClaudePlan(engine) => format!("claude-plan|{}|claude-code", engine.model),
        }
    }

    /// The privacy sentence the chat prompts carry (`inferencePrivacy`).
    pub fn inference_privacy(&self) -> String {
        if let Some(plan) = self.plan() {
            return format!(
                "This response uses the user's {} with {}, which the user approved. Questions and supplied context are sent there; do not claim that all processing stays on this PC.",
                plan.title(),
                plan.provider_name()
            );
        }
        if self.is_local() {
            "This response uses a server on this PC. Its operator controls any onward processing."
                .into()
        } else {
            format!(
                "This response uses the user-approved remote inference server at {}. Questions and supplied context are sent there; do not claim that all processing stays on this PC.",
                self.location()
            )
        }
    }

    /// The most enum values a schema may hold in total, or `None` when the
    /// server compiles schemas locally (`structuredOutputEnumLimit`).
    pub fn structured_output_enum_limit(&self) -> Option<usize> {
        match &self.inner.backend {
            Backend::BuiltIn { .. } | Backend::Ollama { .. } => None,
            // Anthropic publishes no enum limit, only that oversized schemas
            // fail to compile; keep the ceiling used for other hosted servers.
            Backend::Anthropic(_) | Backend::ClaudePlan(_) => Some(500),
            // OpenAI documents 1,000 enum values for strict structured outputs.
            Backend::ChatGptPlan(_) => Some(1_000),
            Backend::Server { dialect, base, .. } => match dialect {
                Dialect::LlamaServer => None,
                Dialect::OpenAi => Some(1_000),
                Dialect::OpenRouter => Some(500),
                Dialect::Generic => (!is_loopback_url(base)).then_some(500),
            },
        }
    }

    /// Output space a structured reply needs beyond its content.
    pub fn minimum_structured_output_tokens(&self) -> u32 {
        match &self.inner.backend {
            // A reasoning model that cannot turn reasoning off spends part of
            // the output on it.
            Backend::ChatGptPlan(engine) => {
                let support = plans::chatgpt::Engine::reasoning_support(&engine.model);
                if support.levels.is_empty() || support.levels.contains(&ReasoningLevel::Off) {
                    512
                } else {
                    2_048
                }
            }
            _ => 512,
        }
    }

    /// The model's context window (`MeetingSummaryGenerator.contextTokenLimit`).
    pub fn context_tokens(&self) -> u32 {
        *self
            .inner
            .context_tokens
            .get_or_init(|| match &self.inner.backend {
                Backend::BuiltIn { .. } => BUILT_IN_CONTEXT_TOKENS,
                Backend::Ollama { .. } => OLLAMA_CONTEXT_TOKENS,
                Backend::Server {
                    base,
                    model,
                    api_key,
                    dialect,
                    ..
                } => discover_context(base, model, api_key.as_deref(), *dialect).unwrap_or(
                    match dialect {
                        Dialect::LlamaServer => BUILT_IN_CONTEXT_TOKENS,
                        _ => FALLBACK_CONTEXT_TOKENS,
                    },
                ),
                Backend::Anthropic(engine) => {
                    engine.discover_context().unwrap_or(FALLBACK_CONTEXT_TOKENS)
                }
                Backend::ChatGptPlan(engine) => plans::chatgpt::context_tokens(&engine.model),
                // Claude Code's default window on subscription plans.
                Backend::ClaudePlan(_) => 200_000,
            })
    }

    /// Exact prompt tokens from llama-server's `/tokenize`; `None` elsewhere.
    pub fn token_count(&self, text: &str) -> Result<Option<usize>> {
        let tokenize = |root: &str, token: Option<&str>| -> Result<Option<usize>> {
            let agent = http::agent(root, Duration::from_secs(60));
            let reply = http::post_json(
                &agent,
                &format!("{root}/tokenize"),
                token,
                &json!({"content": text, "add_special": false}),
            )?;
            if !reply.ok() {
                return Err(AiError::BadResponse(
                    "the local tokenizer returned an invalid response".into(),
                )
                .into());
            }
            let count = reply
                .json()?
                .get("tokens")
                .and_then(Value::as_array)
                .map(Vec::len);
            count.map(Some).ok_or_else(|| {
                AiError::BadResponse("the local tokenizer returned an invalid response".into())
                    .into()
            })
        };
        match &self.inner.backend {
            Backend::BuiltIn { runtime, entry } => {
                let lease = runtime.main_server(entry)?;
                tokenize(&lease.root_url(), Some(lease.token()))
            }
            Backend::Server {
                base,
                api_key,
                dialect: Dialect::LlamaServer,
                ..
            } => tokenize(base.trim_end_matches("/v1"), api_key.as_deref()),
            _ => Ok(None),
        }
    }

    /// Keeps the built-in server loaded across a multi-request job.
    pub fn hold(&self) -> Result<Option<Lease>> {
        match &self.inner.backend {
            Backend::BuiltIn { runtime, entry } => runtime.main_server(entry).map(Some),
            _ => Ok(None),
        }
    }

    // ---------------------------------------------------------- requests

    /// The reply text. A reply cut off at `max_tokens` fails with
    /// [`AiError::Truncated`] unless the request keeps truncated replies.
    pub fn complete(&self, request: &ChatRequest) -> Result<String> {
        finish_text(self.complete_full(request)?, request)
    }

    /// Like [`complete`](Self::complete) but reports truncation instead of
    /// failing, so a structured caller can salvage complete records.
    pub fn complete_full(&self, request: &ChatRequest) -> Result<Completion> {
        match &self.inner.backend {
            Backend::BuiltIn { runtime, entry } => {
                // A server that died mid-job is restarted and the request
                // replayed once (`LeasedTextEngine`).
                for attempt in 0..2 {
                    let lease = runtime.main_server(entry)?;
                    let body = chat_body(
                        Dialect::LlamaServer,
                        entry.id,
                        request,
                        self.request_level(request),
                        Some(DEFAULT_THINKING_BUDGET),
                        entry.request_overrides,
                    );
                    match post_chat(&lease.base_url(), Some(lease.token()), &body) {
                        Err(err)
                            if attempt == 0
                                && matches!(
                                    err.downcast_ref::<AiError>(),
                                    Some(AiError::ServerUnreachable(_))
                                ) =>
                        {
                            lease.mark_unreachable();
                        }
                        other => return other,
                    }
                }
                unreachable!("the replay loop returns")
            }
            Backend::Server {
                base,
                model,
                api_key,
                dialect,
                data_policy,
            } => {
                let default_thinking =
                    (*dialect == Dialect::LlamaServer).then_some(DEFAULT_THINKING_BUDGET);
                let body = with_data_policy(
                    chat_body(
                        *dialect,
                        model,
                        request,
                        self.request_level(request),
                        default_thinking,
                        &[],
                    ),
                    *data_policy,
                );
                with_retry(|| post_chat(base, api_key.as_deref(), &body))
            }
            Backend::Ollama { base, model } => {
                let model = self.ollama_model(base, model)?;
                let body = ollama_body(&model, request, self.request_level(request), false);
                with_retry(|| post_ollama(base, &body))
            }
            Backend::Anthropic(engine) => engine.complete(request),
            Backend::ChatGptPlan(engine) => {
                with_retry(|| engine.respond(request, None, &mut |_| {}))
            }
            Backend::ClaudePlan(engine) => with_retry(|| engine.respond(request, None, None)),
        }
    }

    /// Streams visible text deltas; returns the whole reply. Truncation
    /// follows [`complete`](Self::complete).
    pub fn stream(&self, request: &ChatRequest, on_delta: &mut dyn FnMut(&str)) -> Result<String> {
        let completion = self.stream_full(request, None, on_delta)?;
        finish_text(completion, request)
    }

    /// Streams until done, cut off, or `cancel` is set; then returns what
    /// arrived (`cancelled` set). Streams are never replayed.
    pub fn stream_full(
        &self,
        request: &ChatRequest,
        cancel: Option<&AtomicBool>,
        on_delta: &mut dyn FnMut(&str),
    ) -> Result<Completion> {
        match &self.inner.backend {
            Backend::BuiltIn { runtime, entry } => {
                let lease = runtime.main_server(entry)?;
                let body = chat_body(
                    Dialect::LlamaServer,
                    entry.id,
                    request,
                    self.request_level(request),
                    Some(DEFAULT_THINKING_BUDGET),
                    entry.request_overrides,
                );
                let result = stream_chat(
                    &lease.base_url(),
                    Some(lease.token()),
                    &body,
                    cancel,
                    on_delta,
                );
                if matches!(
                    result
                        .as_ref()
                        .err()
                        .and_then(|e| e.downcast_ref::<AiError>()),
                    Some(AiError::ServerUnreachable(_))
                ) {
                    lease.mark_unreachable();
                }
                result
            }
            Backend::Server {
                base,
                model,
                api_key,
                dialect,
                data_policy,
            } => {
                let default_thinking =
                    (*dialect == Dialect::LlamaServer).then_some(DEFAULT_THINKING_BUDGET);
                let body = with_data_policy(
                    chat_body(
                        *dialect,
                        model,
                        request,
                        self.request_level(request),
                        default_thinking,
                        &[],
                    ),
                    *data_policy,
                );
                match stream_chat(base, api_key.as_deref(), &body, cancel, on_delta) {
                    Err(err) if is_stream_unsupported(&err) => {
                        let completion = self.complete_full(request)?;
                        on_delta(&completion.text);
                        Ok(completion)
                    }
                    other => other,
                }
            }
            Backend::Ollama { base, model } => {
                let model = self.ollama_model(base, model)?;
                let body = ollama_body(&model, request, self.request_level(request), true);
                stream_ollama(base, &body, cancel, on_delta)
            }
            Backend::Anthropic(engine) => engine.stream(request, cancel, on_delta),
            Backend::ChatGptPlan(engine) => engine.respond(request, cancel, on_delta),
            Backend::ClaudePlan(engine) => engine.respond(request, cancel, Some(on_delta)),
        }
    }

    /// A schema-constrained reply decoded into `T`.
    pub fn complete_json<T: DeserializeOwned>(&self, request: &ChatRequest) -> Result<T> {
        let text = self.complete(request)?;
        decode_json(&text)
    }

    fn request_level(&self, request: &ChatRequest) -> Option<ReasoningLevel> {
        let support = match &self.inner.backend {
            Backend::BuiltIn { entry, .. } => ReasoningSupport::built_in(entry),
            Backend::Server {
                base,
                model,
                dialect,
                ..
            } => ReasoningSupport::known(*dialect, base, model),
            Backend::Ollama { model, .. } => ReasoningSupport::ollama(model),
            // These engines pick their own effort per request.
            Backend::Anthropic(_) | Backend::ChatGptPlan(_) | Backend::ClaudePlan(_) => {
                return None;
            }
        };
        support.request_level(self.inner.level, request.reasoning_budget)
    }

    /// An empty Ollama model name means the server's first installed model.
    fn ollama_model(&self, base: &str, model: &str) -> Result<String> {
        if !model.is_empty() {
            return Ok(model.to_string());
        }
        let agent = http::agent(base, Duration::from_secs(5));
        let reply = http::get(&agent, &format!("{base}/api/tags"), None)?;
        let mut names: Vec<String> = reply
            .json()
            .ok()
            .and_then(|v| v.get("models").and_then(Value::as_array).cloned())
            .unwrap_or_default()
            .iter()
            .filter_map(|m| m.get("name").and_then(Value::as_str).map(str::to_string))
            .collect();
        names.sort();
        names
            .into_iter()
            .next()
            .ok_or_else(|| AiError::NoModel.into())
    }
}

/// Decodes the first JSON object of a model reply into `T`.
pub fn decode_json<T: DeserializeOwned>(text: &str) -> Result<T> {
    let object = model_json::parse_object(text).ok_or_else(|| {
        AiError::BadResponse("the model's reply was not the requested JSON".into())
    })?;
    serde_json::from_value(Value::Object(object)).map_err(|err| {
        AiError::BadResponse(format!(
            "the model's reply did not match the requested JSON: {err}"
        ))
        .into()
    })
}

fn finish_text(completion: Completion, request: &ChatRequest) -> Result<String> {
    if completion.truncated && (!request.keep_truncated || completion.text.is_empty()) {
        return Err(AiError::Truncated {
            partial: completion.text,
        }
        .into());
    }
    Ok(completion.text)
}

/// One replay for transient failures (408/409/425/429/5xx, transport),
/// after the server's Retry-After (≤60 s) or about a second.
pub(crate) fn with_retry<T>(mut call: impl FnMut() -> Result<T>) -> Result<T> {
    match call() {
        Err(err) => {
            let Some(ai) = err.downcast_ref::<AiError>() else {
                return Err(err);
            };
            if !ai.is_retryable() {
                return Err(err);
            }
            let jitter = Duration::from_millis(u64::from(
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .map(|d| d.subsec_millis())
                    .unwrap_or(0)
                    % 500,
            ));
            let delay = ai
                .retry_after()
                .map(|d| d.min(Duration::from_secs(60)))
                .unwrap_or(Duration::from_secs(1) + jitter);
            std::thread::sleep(delay);
            call()
        }
        ok => ok,
    }
}

// --------------------------------------------------------------- reasoning

fn level_rank(level: ReasoningLevel) -> u8 {
    match level {
        ReasoningLevel::Automatic => 0,
        ReasoningLevel::Off => 1,
        ReasoningLevel::Minimal => 2,
        ReasoningLevel::Low => 3,
        ReasoningLevel::Medium => 4,
        ReasoningLevel::High => 5,
        ReasoningLevel::Xhigh => 6,
        ReasoningLevel::Max => 7,
    }
}

/// `reasoning_effort` spells Off as "none".
pub(crate) fn effort_value(level: ReasoningLevel) -> &'static str {
    match level {
        ReasoningLevel::Automatic => "medium",
        ReasoningLevel::Off => "none",
        ReasoningLevel::Minimal => "minimal",
        ReasoningLevel::Low => "low",
        ReasoningLevel::Medium => "medium",
        ReasoningLevel::High => "high",
        ReasoningLevel::Xhigh => "xhigh",
        ReasoningLevel::Max => "max",
    }
}

/// The most reasoning a task's own budget allows.
pub(crate) fn ceiling_for_budget(tokens: u32) -> ReasoningLevel {
    match tokens {
        0 => ReasoningLevel::Off,
        1..=512 => ReasoningLevel::Low,
        513..=4_096 => ReasoningLevel::Medium,
        _ => ReasoningLevel::High,
    }
}

/// The reasoning levels one model accepts on one server (`ReasoningSupport`).
#[derive(Clone, Debug, PartialEq)]
pub(crate) struct ReasoningSupport {
    pub levels: Vec<ReasoningLevel>,
    pub default_level: Option<ReasoningLevel>,
}

impl ReasoningSupport {
    pub(crate) fn new(levels: &[ReasoningLevel], default_level: Option<ReasoningLevel>) -> Self {
        Self {
            levels: levels.to_vec(),
            default_level,
        }
    }

    fn common() -> Self {
        use ReasoningLevel::*;
        Self::new(&[Off, Low, Medium, High], None)
    }

    fn built_in(entry: &ModelEntry) -> Self {
        use ReasoningLevel::*;
        if entry.no_reasoning_control {
            Self::new(&[], None)
        } else if entry.id == "lfm2.5-2.6b" {
            Self::new(&[Low, Medium, High], None)
        } else {
            Self::new(&[Off, Low, Medium, High], None)
        }
    }

    fn ollama(model: &str) -> Self {
        use ReasoningLevel::*;
        if model.to_lowercase().contains("gpt-oss") {
            Self::new(&[Low, Medium, High], Some(Medium))
        } else {
            Self::new(&[Off], None)
        }
    }

    fn openai(name: &str) -> Self {
        use ReasoningLevel::*;
        if name.starts_with("o1") || name.starts_with("o3") || name.starts_with("o4") {
            return Self::new(&[Low, Medium, High], Some(Medium));
        }
        if let Some(rest) = name.strip_prefix("gpt-5.") {
            let minor: String = rest.chars().take_while(char::is_ascii_digit).collect();
            if !minor.is_empty() {
                return if minor == "1" {
                    Self::new(&[Off, Low, Medium, High], Some(Off))
                } else {
                    Self::new(&[Off, Low, Medium, High, Xhigh], Some(Medium))
                };
            }
        }
        if name == "gpt-5" || name.starts_with("gpt-5-") {
            return Self::new(&[Minimal, Low, Medium, High], Some(Medium));
        }
        // GPT-6 adds Max and defaults to Medium. Sol and Luna also take
        // `none`; 6.1 Sol and Astra reject it, so newer models get no Off.
        // Astra documents no default (OpenAI's model pages, 26 October 2026).
        if name == "gpt-6" || name.starts_with("gpt-6-") || name.starts_with("gpt-6.") {
            if name.starts_with("gpt-6-sol") || name.starts_with("gpt-6-luna") {
                return Self::new(&[Off, Low, Medium, High, Xhigh, Max], Some(Medium));
            }
            let default = (!name.starts_with("gpt-6-astra")).then_some(Medium);
            return Self::new(&[Low, Medium, High, Xhigh, Max], default);
        }
        Self::new(&[], None)
    }

    fn family(name: &str) -> Option<Self> {
        use ReasoningLevel::*;
        name.contains("gpt-oss")
            .then(|| Self::new(&[Low, Medium, High], Some(Medium)))
    }

    pub(crate) fn known(dialect: Dialect, base: &str, model: &str) -> Self {
        use ReasoningLevel::*;
        let name = model.to_lowercase();
        if anthropic::is_anthropic(base) {
            return anthropic::ModelTraits::new(&name).reasoning_support();
        }
        match dialect {
            Dialect::LlamaServer => Self::new(&[Off, Low, Medium, High], None),
            Dialect::OpenAi => Self::openai(&name),
            Dialect::OpenRouter => {
                if let Some(rest) = name.strip_prefix("openai/") {
                    let support = Self::openai(rest);
                    if !support.levels.is_empty() {
                        return support;
                    }
                }
                Self::family(&name).unwrap_or_else(Self::common)
            }
            Dialect::Generic => {
                let host = crate::http::host_label(base);
                if host == "cerebras.ai" || host.ends_with(".cerebras.ai") {
                    if name.starts_with("qwen") {
                        return Self::new(&[Off, Low, Medium, High], Some(High));
                    }
                    if name.starts_with("gpt-oss") {
                        return Self::new(&[Low, Medium, High], Some(Medium));
                    }
                    if name.starts_with("gemma") {
                        return Self::new(&[Off, Low, Medium, High], Some(Off));
                    }
                    if name.starts_with("kimi") {
                        return Self::new(&[], None);
                    }
                    return Self::common();
                }
                Self::family(&name).unwrap_or_else(Self::common)
            }
        }
    }

    pub(crate) fn clamp(&self, level: ReasoningLevel) -> Option<ReasoningLevel> {
        if level == ReasoningLevel::Automatic || self.levels.is_empty() {
            return None;
        }
        self.levels
            .iter()
            .copied()
            .rfind(|l| level_rank(*l) <= level_rank(level))
            .or(self.levels.first().copied())
    }

    /// The chosen level, no higher than the task's budget allows, clamped to
    /// what the model accepts. Automatic leaves the server's default, except
    /// that a no-reasoning task never goes to a model that reasons by default.
    pub(crate) fn request_level(
        &self,
        level: ReasoningLevel,
        task_budget: Option<u32>,
    ) -> Option<ReasoningLevel> {
        if level == ReasoningLevel::Automatic {
            let reasons_by_default = self
                .default_level
                .is_some_and(|d| level_rank(d) > level_rank(ReasoningLevel::Off));
            return (task_budget == Some(0)
                && reasons_by_default
                && self.levels.contains(&ReasoningLevel::Off))
            .then_some(ReasoningLevel::Off);
        }
        let ceiling = task_budget.map(ceiling_for_budget).unwrap_or(level);
        let chosen = if level_rank(ceiling) < level_rank(level) {
            ceiling
        } else {
            level
        };
        self.clamp(chosen)
    }
}

/// The reasoning levels the Think model in `settings` accepts, and the level
/// its server uses when none is sent (`ReasoningSupport.known(for:)`). Agent
/// Mode offers only these and clamps its choice to them.
pub fn reasoning_choices(settings: &Settings) -> (Vec<ReasoningLevel>, Option<ReasoningLevel>) {
    let support = match settings.summarizer_backend {
        SummarizerBackend::BuiltIn => catalog::entry(&settings.built_in_model_id)
            .map(ReasoningSupport::built_in)
            .unwrap_or_else(ReasoningSupport::common),
        SummarizerBackend::Ollama => ReasoningSupport::ollama(settings.ollama_model.trim()),
        SummarizerBackend::OpenAICompatible => {
            let base = trimmed_base(&settings.openai_base_url);
            ReasoningSupport::known(
                Dialect::inferred(&base),
                &base,
                settings.openai_model.trim(),
            )
        }
        SummarizerBackend::ChatGptPlan => {
            plans::chatgpt::Engine::reasoning_support(settings.chatgpt_plan_model.trim())
        }
        SummarizerBackend::ClaudePlan => plans::claude::traits(&settings.claude_plan_model).0,
    };
    (support.levels, support.default_level)
}

fn is_openai_reasoning_model(model: &str) -> bool {
    let name = model.to_lowercase();
    name.starts_with("o1")
        || name.starts_with("o3")
        || name.starts_with("o4")
        || name.starts_with("gpt-5")
        || name.starts_with("gpt-6")
}

// ------------------------------------------------------------- chat bodies

/// The `/chat/completions` body for one dialect (`makeChatRequest`,
/// `applyGenerationOptions`). Keys are sorted so a grammar-constrained server
/// generates schema properties in a stable order.
pub(crate) fn chat_body(
    dialect: Dialect,
    model: &str,
    request: &ChatRequest,
    level: Option<ReasoningLevel>,
    default_thinking: Option<u32>,
    overrides: &[(&str, f64)],
) -> Value {
    let mut body = json!({
        "model": model,
        "messages": [
            {"role": "system", "content": request.system},
            {"role": "user", "content": request.user_text()},
        ],
    });
    if let Some(schema) = &request.json_schema {
        body["response_format"] = json!({
            "type": "json_schema",
            "json_schema": {"name": "response", "strict": true, "schema": schema},
        });
    }
    let max_tokens = request.max_tokens.map(|t| t.max(1));
    let temperature = request.temperature.map(|t| f64::from(t.max(0.0)));
    match dialect {
        Dialect::LlamaServer => {
            if let Some(max) = max_tokens {
                body["max_tokens"] = json!(max);
            }
            if let Some(t) = temperature {
                body["temperature"] = json!(t);
            }
            let requested = level
                .and_then(|l| l.budget_tokens())
                .or(request.reasoning_budget)
                .or(default_thinking);
            if let Some(requested) = requested {
                let effective = max_tokens
                    .map(|m| requested.min(m / 2))
                    .unwrap_or(requested);
                body["thinking_budget_tokens"] = json!(effective);
                if effective == 0 {
                    // A zero budget alone still opens Qwen's thinking turn and
                    // can exhaust a short reply before any visible text.
                    body["chat_template_kwargs"] = json!({"enable_thinking": false});
                }
            }
        }
        Dialect::Generic => {
            if let Some(max) = max_tokens {
                body["max_tokens"] = json!(max);
            }
            if let Some(t) = temperature {
                body["temperature"] = json!(t);
            }
            if let Some(level) = level {
                body["reasoning_effort"] = json!(effort_value(level));
            }
        }
        Dialect::OpenRouter => {
            if let Some(max) = max_tokens {
                body["max_tokens"] = json!(max);
            }
            if let Some(level) = level {
                body["reasoning"] = if level == ReasoningLevel::Off {
                    json!({"effort": "none"})
                } else {
                    json!({"effort": effort_value(level), "exclude": true})
                };
                if level == ReasoningLevel::Off
                    && let Some(t) = temperature
                {
                    body["temperature"] = json!(t);
                }
            } else {
                if let Some(budget) = request.reasoning_budget {
                    body["reasoning"] = if budget == 0 {
                        json!({"effort": "none"})
                    } else {
                        let effective = max_tokens
                            .map(|m| budget.min(m / 2))
                            .unwrap_or(budget)
                            .max(1);
                        json!({"max_tokens": effective, "exclude": true})
                    };
                }
                if request.reasoning_budget.unwrap_or(0) == 0
                    && let Some(t) = temperature
                {
                    body["temperature"] = json!(t);
                }
            }
            let mut provider = json!({"data_collection": "deny"});
            if request.json_schema.is_some()
                || request.reasoning_budget.is_some()
                || level.is_some()
            {
                provider["require_parameters"] = json!(true);
            }
            body["provider"] = provider;
        }
        Dialect::OpenAi => {
            if let Some(max) = max_tokens {
                body["max_completion_tokens"] = json!(max);
            }
            let reasoning_model = is_openai_reasoning_model(model);
            if !reasoning_model && let Some(t) = temperature {
                body["temperature"] = json!(t);
            }
            if let Some(level) = level {
                body["reasoning_effort"] = json!(effort_value(level));
            } else if reasoning_model
                && let Some(budget) = request.reasoning_budget.filter(|b| *b > 0)
            {
                body["reasoning_effort"] = json!(effort_value(ceiling_for_budget(budget)));
            }
        }
    }
    for (key, value) in overrides {
        body[*key] = json!(value);
    }
    model_json::sort_keys(body)
}

/// OpenRouter's `provider.data_collection` from the user's policy. Bodies
/// without a provider block (other dialects) are unchanged.
pub(crate) fn with_data_policy(mut body: Value, policy: OpenRouterDataPolicy) -> Value {
    if let Some(provider) = body.get_mut("provider").and_then(Value::as_object_mut) {
        provider.insert("data_collection".into(), json!(policy.data_collection()));
    }
    body
}

fn parse_chat_completion(json: &Value) -> Result<Completion> {
    let choice = json
        .get("choices")
        .and_then(Value::as_array)
        .and_then(|c| c.first())
        .ok_or_else(|| AiError::BadResponse("unexpected /chat/completions payload".into()))?;
    let message = choice
        .get("message")
        .ok_or_else(|| AiError::BadResponse("unexpected /chat/completions payload".into()))?;
    if let Some(refusal) = message
        .get("refusal")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|r| !r.is_empty())
    {
        return Err(AiError::BadResponse(format!(
            "model refusal: {}",
            refusal.chars().take(600).collect::<String>()
        ))
        .into());
    }
    let finish = choice.get("finish_reason").and_then(Value::as_str);
    if finish == Some("content_filter") {
        return Err(
            AiError::BadResponse("response was stopped by the content filter".into()).into(),
        );
    }
    let truncated = finish == Some("length");
    let content = match message.get("content").and_then(Value::as_str) {
        Some(content) => content.to_string(),
        None if truncated => String::new(),
        None => {
            return Err(AiError::BadResponse("chat completion contained no text".into()).into());
        }
    };
    let usage = json.get("usage").map(|u| Usage {
        prompt_tokens: u.get("prompt_tokens").and_then(Value::as_u64),
        completion_tokens: u.get("completion_tokens").and_then(Value::as_u64),
    });
    let text = if truncated {
        model_json::visible_text_of_truncated(&content)
    } else {
        model_json::strip_reasoning(&content)
    };
    Ok(Completion {
        text,
        truncated,
        cancelled: false,
        usage,
    })
}

fn post_chat(base: &str, bearer: Option<&str>, body: &Value) -> Result<Completion> {
    let agent = http::agent(base, CHAT_TIMEOUT);
    let reply = http::post_json(&agent, &format!("{base}/chat/completions"), bearer, body)?;
    if !reply.ok() {
        return Err(reply.status_error().into());
    }
    parse_chat_completion(&reply.json()?)
}

/// A rejected stream generated nothing; the caller retries without streaming.
#[derive(Debug, thiserror::Error)]
#[error("the server does not stream chat completions")]
struct StreamUnsupported;

fn is_stream_unsupported(err: &anyhow::Error) -> bool {
    err.downcast_ref::<StreamUnsupported>().is_some()
}

/// Hides `<think>…</think>` spans in streamed text, even when a tag is split
/// across deltas.
#[derive(Default)]
struct ThinkFilter {
    pending: String,
    inside: bool,
}

impl ThinkFilter {
    fn push(&mut self, delta: &str) -> String {
        self.pending.push_str(delta);
        let mut out = String::new();
        loop {
            let tag = if self.inside { "</think>" } else { "<think>" };
            if let Some(at) = self.pending.find(tag) {
                if !self.inside {
                    out.push_str(&self.pending[..at]);
                }
                self.pending.drain(..at + tag.len());
                self.inside = !self.inside;
                continue;
            }
            // Keep a possible partial tag for the next delta.
            let keep = (1..tag.len())
                .rev()
                .find(|n| self.pending.ends_with(&tag[..*n]))
                .unwrap_or(0);
            let flush = self.pending.len() - keep;
            if !self.inside {
                out.push_str(&self.pending[..flush]);
            }
            self.pending.drain(..flush);
            return out;
        }
    }

    fn finish(&mut self) -> String {
        let rest = std::mem::take(&mut self.pending);
        if self.inside { String::new() } else { rest }
    }
}

fn stream_chat(
    base: &str,
    bearer: Option<&str>,
    body: &Value,
    cancel: Option<&AtomicBool>,
    on_delta: &mut dyn FnMut(&str),
) -> Result<Completion> {
    let mut body = body.clone();
    body["stream"] = json!(true);
    let agent = http::agent(base, CHAT_TIMEOUT);
    let url = format!("{base}/chat/completions");
    let mut stream = http::post_stream(&agent, &url, bearer, &body)?;
    if let Some(error) = stream.error.take() {
        if [400, 404, 405, 422, 501].contains(&stream.status) {
            return Err(StreamUnsupported.into());
        }
        return Err(error.status_error().into());
    }
    let mut filter = ThinkFilter::default();
    let mut content = String::new();
    let mut non_streaming = String::new();
    let mut terminal = false;
    let mut truncated = false;
    while let Some(line) = stream.next_line(base)? {
        if cancel.is_some_and(|c| c.load(Ordering::Relaxed)) {
            return Ok(Completion {
                text: model_json::strip_reasoning(&content),
                truncated: false,
                cancelled: true,
                usage: None,
            });
        }
        let Some(payload) = line.strip_prefix("data:") else {
            if non_streaming.len() < 1_048_576 {
                non_streaming.push_str(&line);
            }
            continue;
        };
        let payload = payload.trim();
        if payload == "[DONE]" {
            terminal = true;
            break;
        }
        let Ok(event) = serde_json::from_str::<Value>(payload) else {
            continue;
        };
        if event.get("error").is_some() {
            return Err(AiError::BadResponse("chat stream reported an error".into()).into());
        }
        let Some(choice) = event
            .get("choices")
            .and_then(Value::as_array)
            .and_then(|c| c.first())
        else {
            continue;
        };
        if let Some(text) = choice
            .get("delta")
            .and_then(|d| d.get("content"))
            .and_then(Value::as_str)
        {
            let visible = filter.push(text);
            if !visible.is_empty() {
                content.push_str(&visible);
                on_delta(&visible);
            }
        }
        if let Some(reason) = choice.get("finish_reason").and_then(Value::as_str) {
            truncated = reason == "length";
            terminal = true;
            break;
        }
    }
    let rest = filter.finish();
    if !rest.is_empty() {
        content.push_str(&rest);
        on_delta(&rest);
    }
    if !terminal && content.is_empty() && !non_streaming.trim().is_empty() {
        // Some servers ignore `stream: true`; use that single response.
        let json: Value = serde_json::from_str(&non_streaming)
            .map_err(|_| AiError::BadResponse("unexpected /chat/completions payload".into()))?;
        let completion = parse_chat_completion(&json)?;
        on_delta(&completion.text);
        return Ok(completion);
    }
    if !terminal {
        return Err(AiError::BadResponse("chat stream ended before completion".into()).into());
    }
    let text = if truncated {
        content.trim().to_string()
    } else {
        model_json::strip_reasoning(&content)
    };
    Ok(Completion {
        text,
        truncated,
        cancelled: false,
        usage: None,
    })
}

// ------------------------------------------------------------------ Ollama

fn ollama_body(
    model: &str,
    request: &ChatRequest,
    level: Option<ReasoningLevel>,
    stream: bool,
) -> Value {
    let mut body = json!({
        "model": model,
        "stream": stream,
        "messages": [
            {"role": "system", "content": request.system},
            {"role": "user", "content": request.user_text()},
        ],
    });
    if let Some(schema) = &request.json_schema {
        body["format"] = schema.clone();
    }
    // Thinking tokens count against `num_predict`; a zero budget turns the
    // thinking turn off. Only gpt-oss takes a graded level.
    match level {
        Some(level) if level != ReasoningLevel::Off => body["think"] = json!(effort_value(level)),
        Some(_) => body["think"] = json!(false),
        None if request.reasoning_budget == Some(0) => body["think"] = json!(false),
        None => {}
    }
    let mut options = json!({"num_ctx": OLLAMA_CONTEXT_TOKENS});
    if let Some(max) = request.max_tokens {
        options["num_predict"] = json!(max.max(1));
    }
    if let Some(t) = request.temperature {
        options["temperature"] = json!(f64::from(t.max(0.0)));
    }
    body["options"] = options;
    if request.json_schema.is_some() {
        model_json::sort_keys(body)
    } else {
        body
    }
}

fn post_ollama(base: &str, body: &Value) -> Result<Completion> {
    let agent = http::agent(base, CHAT_TIMEOUT);
    let reply = http::post_json(&agent, &format!("{base}/api/chat"), None, body)?;
    if !reply.ok() {
        return Err(reply.status_error().into());
    }
    let json = reply.json()?;
    let content = json
        .get("message")
        .and_then(|m| m.get("content"))
        .and_then(Value::as_str)
        .ok_or_else(|| AiError::BadResponse("unexpected /api/chat payload".into()))?;
    let truncated = json.get("done_reason").and_then(Value::as_str) == Some("length");
    let usage = Some(Usage {
        prompt_tokens: json.get("prompt_eval_count").and_then(Value::as_u64),
        completion_tokens: json.get("eval_count").and_then(Value::as_u64),
    });
    let text = if truncated {
        model_json::visible_text_of_truncated(content)
    } else {
        model_json::strip_reasoning(content)
    };
    Ok(Completion {
        text,
        truncated,
        cancelled: false,
        usage,
    })
}

fn stream_ollama(
    base: &str,
    body: &Value,
    cancel: Option<&AtomicBool>,
    on_delta: &mut dyn FnMut(&str),
) -> Result<Completion> {
    let agent = http::agent(base, CHAT_TIMEOUT);
    let mut stream = http::post_stream(&agent, &format!("{base}/api/chat"), None, body)?;
    if let Some(error) = stream.error.take() {
        return Err(error.status_error().into());
    }
    let mut filter = ThinkFilter::default();
    let mut content = String::new();
    let mut truncated = false;
    let mut done = false;
    while let Some(line) = stream.next_line(base)? {
        if cancel.is_some_and(|c| c.load(Ordering::Relaxed)) {
            return Ok(Completion {
                text: content.trim().to_string(),
                truncated: false,
                cancelled: true,
                usage: None,
            });
        }
        let Ok(event) = serde_json::from_str::<Value>(line.trim()) else {
            continue;
        };
        if let Some(error) = event.get("error").and_then(Value::as_str) {
            return Err(AiError::BadResponse(error.chars().take(600).collect()).into());
        }
        if let Some(text) = event
            .get("message")
            .and_then(|m| m.get("content"))
            .and_then(Value::as_str)
        {
            let visible = filter.push(text);
            if !visible.is_empty() {
                content.push_str(&visible);
                on_delta(&visible);
            }
        }
        if event.get("done").and_then(Value::as_bool) == Some(true) {
            truncated = event.get("done_reason").and_then(Value::as_str) == Some("length");
            done = true;
            break;
        }
    }
    content.push_str(&filter.finish());
    if !done {
        return Err(AiError::BadResponse("chat stream ended before completion".into()).into());
    }
    Ok(Completion {
        text: content.trim().to_string(),
        truncated,
        cancelled: false,
        usage: None,
    })
}

// ---------------------------------------------------------- context window

/// `ServerContextWindowCatalog`: OpenRouter's endpoints, llama-server's
/// `/props`, then model-list fields. No content is sent.
fn discover_context(
    base: &str,
    model: &str,
    api_key: Option<&str>,
    dialect: Dialect,
) -> Option<u32> {
    let agent = http::agent(base, Duration::from_secs(5));
    if dialect == Dialect::OpenRouter {
        // The model id alone: no API key and no content (PRIVACY.md).
        let url = format!("https://openrouter.ai/api/v1/models/{model}/endpoints");
        let json = http::get(&agent, &url, None)
            .ok()
            .filter(|r| r.ok())?
            .json()
            .ok()?;
        return json
            .pointer("/data/endpoints")
            .and_then(Value::as_array)?
            .iter()
            .filter_map(|e| {
                let context = e.get("context_length").and_then(Value::as_u64);
                let prompt = e.get("max_prompt_tokens").and_then(Value::as_u64);
                match (context, prompt) {
                    (Some(a), Some(b)) => Some(a.min(b)),
                    (a, b) => a.or(b),
                }
            })
            .min()
            .map(|n| n.min(u64::from(u32::MAX)) as u32);
    }
    let root = base.trim_end_matches("/v1");
    if (dialect == Dialect::LlamaServer || is_loopback_url(base))
        && let Some(json) = http::get(&agent, &format!("{root}/props"), api_key)
            .ok()
            .filter(|r| r.ok())
            .and_then(|r| r.json().ok())
    {
        let n_ctx = json
            .get("n_ctx")
            .or_else(|| json.pointer("/default_generation_settings/n_ctx"))
            .and_then(Value::as_u64);
        if let Some(n) = n_ctx.filter(|n| *n > 0) {
            return Some(n.min(u64::from(u32::MAX)) as u32);
        }
    }
    let json = http::get(&agent, &format!("{base}/models"), api_key)
        .ok()
        .filter(|r| r.ok())?
        .json()
        .ok()?;
    let models = json.get("data").and_then(Value::as_array)?;
    let entry = models
        .iter()
        .find(|m| m.get("id").and_then(Value::as_str) == Some(model))?;
    [
        "max_model_len",
        "context_window",
        "context_length",
        "max_context_length",
        "loaded_context_length",
        "max_input_tokens",
    ]
    .iter()
    .find_map(|key| entry.get(*key).and_then(Value::as_u64))
    .map(|n| n.min(u64::from(u32::MAX)) as u32)
}

// --------------------------------------------------------------- embeddings

/// EmbeddingGemma's own retrieval prompts (`EmbeddingIndex`).
pub const DOCUMENT_PREFIX: &str = "title: none | text: ";
pub const QUERY_PREFIX: &str = "task: search result | query: ";
pub const SIMILARITY_PREFIX: &str = "task: sentence similarity | query: ";
/// Bounds for one embedding request, so a typed query never waits long.
const EMBED_MAX_INPUTS: usize = 8;
const EMBED_MAX_CHARS: usize = 2_000;

#[derive(Clone)]
enum EmbedTarget {
    BuiltIn(RuntimeManager),
    Server { base: String, token: Option<String> },
}

/// `/v1/embeddings` on the embedder server; vectors come back L2-normalized.
#[derive(Clone)]
pub struct EmbeddingClient {
    target: EmbedTarget,
}

impl EmbeddingClient {
    pub fn new(runtime: &RuntimeManager) -> Self {
        Self {
            target: EmbedTarget::BuiltIn(runtime.clone()),
        }
    }

    /// An embeddings server reached directly (tests, CLI).
    pub fn for_server(base_url: &str, token: Option<String>) -> Self {
        Self {
            target: EmbedTarget::Server {
                base: trimmed_base(base_url),
                token,
            },
        }
    }

    pub fn embed_documents(&self, texts: &[String]) -> Result<Vec<Vec<f32>>> {
        self.embed(texts, DOCUMENT_PREFIX)
    }

    pub fn embed_query(&self, query: &str) -> Result<Vec<f32>> {
        self.embed(&[query.to_string()], QUERY_PREFIX)?
            .into_iter()
            .next()
            .ok_or_else(|| AiError::BadResponse("unexpected /v1/embeddings payload".into()).into())
    }

    /// One vector per text, in order, `prefix` prepended to each.
    pub fn embed(&self, texts: &[String], prefix: &str) -> Result<Vec<Vec<f32>>> {
        let mut out = Vec::with_capacity(texts.len());
        if texts.is_empty() {
            return Ok(out);
        }
        let lease = match &self.target {
            EmbedTarget::BuiltIn(runtime) => Some(runtime.embedder_server()?),
            EmbedTarget::Server { .. } => None,
        };
        let (base, token) = match (&self.target, &lease) {
            (EmbedTarget::Server { base, token }, _) => (base.clone(), token.clone()),
            (_, Some(lease)) => (lease.base_url(), Some(lease.token().to_string())),
            _ => unreachable!("a built-in target always holds a lease"),
        };
        let agent = http::agent(&base, Duration::from_secs(120));
        for range in request_ranges(texts) {
            let body = json!({
                "input": texts[range.clone()].iter().map(|t| format!("{prefix}{t}")).collect::<Vec<_>>(),
                "model": catalog::EMBEDDING_ID,
                "cache_prompt": false,
            });
            let reply = match http::post_json(
                &agent,
                &format!("{base}/embeddings"),
                token.as_deref(),
                &body,
            ) {
                Ok(reply) => reply,
                Err(err) => {
                    if let Some(lease) = &lease {
                        lease.mark_unreachable();
                    }
                    return Err(err);
                }
            };
            if !reply.ok() {
                return Err(reply.status_error().into());
            }
            let vectors = vectors_from_response(&reply.json()?)?;
            if vectors.len() != range.len() {
                return Err(AiError::BadResponse(
                    "the embedder returned the wrong number of vectors".into(),
                )
                .into());
            }
            out.extend(vectors);
        }
        Ok(out)
    }
}

/// Runs of texts within the per-request limits; an over-long text goes alone.
pub fn request_ranges(texts: &[String]) -> Vec<Range<usize>> {
    let mut ranges = Vec::new();
    let mut start = 0;
    let mut characters = 0;
    for (index, text) in texts.iter().enumerate() {
        let count = text.chars().count();
        if index > start
            && (index - start == EMBED_MAX_INPUTS || characters + count > EMBED_MAX_CHARS)
        {
            ranges.push(start..index);
            start = index;
            characters = 0;
        }
        characters += count;
    }
    if start < texts.len() {
        ranges.push(start..texts.len());
    }
    ranges
}

/// Rows ordered by `index`, each L2-normalized.
pub fn vectors_from_response(json: &Value) -> Result<Vec<Vec<f32>>> {
    let rows = json
        .get("data")
        .and_then(Value::as_array)
        .ok_or_else(|| AiError::BadResponse("unexpected /v1/embeddings payload".into()))?;
    let mut ordered: Vec<(usize, &Value)> = rows
        .iter()
        .enumerate()
        .map(|(offset, row)| {
            (
                row.get("index")
                    .and_then(Value::as_u64)
                    .map(|i| i as usize)
                    .unwrap_or(offset),
                row,
            )
        })
        .collect();
    ordered.sort_by_key(|(index, _)| *index);
    let mut out = Vec::with_capacity(ordered.len());
    for (_, row) in ordered {
        let embedding = row
            .get("embedding")
            .and_then(Value::as_array)
            .ok_or_else(|| AiError::BadResponse("unexpected /v1/embeddings payload".into()))?;
        // Unpooled servers return one row per token; take the first.
        let values = match embedding.first() {
            Some(Value::Array(first)) => first.clone(),
            _ => embedding.clone(),
        };
        let vector: Vec<f32> = values
            .iter()
            .filter_map(Value::as_f64)
            .map(|v| v as f32)
            .collect();
        out.push(normalized(vector));
    }
    Ok(out)
}

fn normalized(vector: Vec<f32>) -> Vec<f32> {
    let norm = vector.iter().map(|v| v * v).sum::<f32>().sqrt();
    if norm > 0.0 {
        vector.into_iter().map(|v| v / norm).collect()
    } else {
        vector
    }
}

/// Dot product: cosine similarity for normalized vectors.
pub fn dot(a: &[f32], b: &[f32]) -> f32 {
    a.iter().zip(b).map(|(x, y)| x * y).sum()
}

// ---------------------------------------------------------- raw completions

/// One raw continuation for autocomplete (`CompletionRequest`).
#[derive(Clone, Debug, PartialEq)]
pub struct CompletionRequest {
    pub prompt: String,
    pub max_tokens: u32,
    pub temperature: f32,
    pub top_p: f32,
    pub top_k: u32,
    pub min_p: f32,
    pub repeat_penalty: f32,
    pub seed: u64,
    pub stop: Vec<String>,
}

impl CompletionRequest {
    /// `CotypingConfiguration.standard` sampling with the word-based length:
    /// `max(5, ceil(words × 1.3))`, doubled for multi-line, at most 120.
    pub fn cotyping(prompt: impl Into<String>, max_words: u32, multi_line: bool) -> Self {
        let base = ((f64::from(max_words) * 1.3).ceil() as u32).max(5);
        let max_tokens = if multi_line { base * 2 } else { base }.min(120);
        Self {
            prompt: prompt.into(),
            max_tokens,
            temperature: 0.1,
            top_p: 0.7,
            top_k: 20,
            min_p: 0.08,
            repeat_penalty: 1.05,
            seed: 0x00C0_FFEE,
            stop: if multi_line {
                Vec::new()
            } else {
                vec!["\n".into()]
            },
        }
    }
}

#[derive(Clone)]
enum CompletionTarget {
    BuiltIn {
        runtime: RuntimeManager,
        entry: &'static ModelEntry,
    },
    Server {
        base: String,
        model: String,
        api_key: Option<String>,
        dialect: Dialect,
        data_policy: OpenRouterDataPolicy,
    },
}

/// Raw `/v1/completions` for autocomplete: no chat template, tight sampling,
/// a short timeout.
#[derive(Clone)]
pub struct CompletionClient {
    target: CompletionTarget,
}

const COMPLETION_TIMEOUT: Duration = Duration::from_secs(15);

impl CompletionClient {
    pub fn built_in(runtime: &RuntimeManager, entry: &'static ModelEntry) -> Self {
        Self {
            target: CompletionTarget::BuiltIn {
                runtime: runtime.clone(),
                entry,
            },
        }
    }

    /// The built-in autocomplete model from settings.
    pub fn from_settings(runtime: &RuntimeManager, settings: &Settings) -> Result<Self> {
        let entry = catalog::entry(&settings.cotyping_built_in_model_id)
            .filter(|e| e.kind == catalog::ModelKind::Text)
            .ok_or_else(|| AiError::Unavailable("The selected autocomplete model is no longer available. Pick one under Settings → Models.".into()))?;
        Ok(Self::built_in(runtime, entry))
    }

    /// Another server; a remote one needs an approved autocomplete origin.
    pub fn server(
        base_url: &str,
        model: &str,
        api_key: Option<String>,
        approved_autocomplete_origins: &[String],
    ) -> Result<Self> {
        let base = trimmed_base(base_url);
        consent(&base, approved_autocomplete_origins)?;
        Ok(Self {
            target: CompletionTarget::Server {
                dialect: Dialect::inferred(&base),
                base,
                model: model.to_string(),
                api_key,
                data_policy: OpenRouterDataPolicy::PrivateOnly,
            },
        })
    }

    /// Sets OpenRouter's provider data policy (Think's choice applies to
    /// autocomplete too).
    pub fn with_openrouter_data_policy(mut self, policy: OpenRouterDataPolicy) -> Self {
        if let CompletionTarget::Server { data_policy, .. } = &mut self.target {
            *data_policy = policy;
        }
        self
    }

    fn body(&self, request: &CompletionRequest, stream: bool) -> Value {
        let (model, llama_extensions, dialect, data_policy) = match &self.target {
            CompletionTarget::BuiltIn { entry, .. } => (
                entry.id.to_string(),
                true,
                Dialect::LlamaServer,
                OpenRouterDataPolicy::PrivateOnly,
            ),
            CompletionTarget::Server {
                model,
                dialect,
                base,
                data_policy,
                ..
            } => (
                model.clone(),
                *dialect == Dialect::LlamaServer || is_loopback_url(base),
                *dialect,
                *data_policy,
            ),
        };
        let mut body = json!({
            "model": model,
            "prompt": request.prompt,
            "max_tokens": request.max_tokens,
            "temperature": request.temperature,
            "top_p": request.top_p,
            "seed": request.seed,
            "stream": stream,
        });
        if llama_extensions {
            body["top_k"] = json!(request.top_k);
            body["min_p"] = json!(request.min_p);
            body["repeat_penalty"] = json!(request.repeat_penalty);
        }
        if !request.stop.is_empty() {
            body["stop"] = json!(request.stop);
        }
        if dialect == Dialect::OpenRouter {
            body["provider"] = json!({"data_collection": data_policy.data_collection()});
        }
        body
    }

    fn endpoint(&self) -> Result<(String, Option<String>, Option<Lease>)> {
        match &self.target {
            CompletionTarget::BuiltIn { runtime, entry } => {
                let lease = runtime.autocomplete_server(entry)?;
                Ok((
                    lease.base_url(),
                    Some(lease.token().to_string()),
                    Some(lease),
                ))
            }
            CompletionTarget::Server { base, api_key, .. } => {
                Ok((base.clone(), api_key.clone(), None))
            }
        }
    }

    pub fn complete(&self, request: &CompletionRequest) -> Result<String> {
        let (base, token, _lease) = self.endpoint()?;
        let agent = http::agent(&base, COMPLETION_TIMEOUT);
        let reply = http::post_json(
            &agent,
            &format!("{base}/completions"),
            token.as_deref(),
            &self.body(request, false),
        )?;
        if !reply.ok() {
            return Err(reply.status_error().into());
        }
        reply
            .json()?
            .pointer("/choices/0/text")
            .and_then(Value::as_str)
            .map(str::to_string)
            .ok_or_else(|| AiError::BadResponse("unexpected /completions payload".into()).into())
    }

    /// Streams the continuation. `should_stop(text, chunks)` can end decoding
    /// early (the cotyping stop policy); `on_partial` gets the running text.
    pub fn stream(
        &self,
        request: &CompletionRequest,
        should_stop: &mut dyn FnMut(&str, usize) -> bool,
        on_partial: &mut dyn FnMut(&str),
    ) -> Result<String> {
        let (base, token, _lease) = self.endpoint()?;
        let agent = http::agent(&base, COMPLETION_TIMEOUT);
        let mut stream = http::post_stream(
            &agent,
            &format!("{base}/completions"),
            token.as_deref(),
            &self.body(request, true),
        )?;
        if let Some(error) = stream.error.take() {
            return Err(error.status_error().into());
        }
        let mut text = String::new();
        let mut chunks = 0usize;
        let mut events = 0usize;
        let mut terminal = false;
        while let Some(line) = stream.next_line(&base)? {
            let Some(payload) = line.trim().strip_prefix("data:").map(str::trim) else {
                continue;
            };
            if payload.is_empty() {
                continue;
            }
            events += 1;
            if payload == "[DONE]" {
                terminal = true;
                break;
            }
            let Ok(event) = serde_json::from_str::<Value>(payload) else {
                continue;
            };
            let Some(choice) = event
                .get("choices")
                .and_then(Value::as_array)
                .and_then(|c| c.first())
            else {
                continue;
            };
            if let Some(delta) = choice
                .get("text")
                .and_then(Value::as_str)
                .filter(|d| !d.is_empty())
            {
                text.push_str(delta);
                chunks += 1;
                on_partial(&text);
                if should_stop(&text, chunks) {
                    return Ok(text);
                }
            }
            if choice.get("finish_reason").is_some_and(|r| !r.is_null()) {
                terminal = true;
                break;
            }
        }
        if !terminal {
            if events == 0 && text.is_empty() {
                // A 2xx without SSE: this server does not stream.
                let full = self.complete(request)?;
                on_partial(&full);
                return Ok(full);
            }
            return Err(AiError::BadResponse(
                "stream ended before a terminal completion event".into(),
            )
            .into());
        }
        Ok(text)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::http::testing::{Reply, StubServer};

    fn llama_stub(reply: impl Fn(&Value) -> Reply + Send + Sync + 'static) -> StubServer {
        StubServer::start(move |request| match request.path.as_str() {
            "/v1/chat/completions" => reply(&request.json()),
            "/tokenize" => Reply::Json(200, json!({"tokens": [1, 2, 3, 4]})),
            "/props" => Reply::Json(200, json!({"default_generation_settings": {"n_ctx": 8192}})),
            _ => Reply::Text(404, "nope".into()),
        })
    }

    fn chat_reply(content: &str, finish: &str) -> Reply {
        Reply::Json(
            200,
            json!({"choices": [{"message": {"role": "assistant", "content": content}, "finish_reason": finish}], "usage": {"prompt_tokens": 10, "completion_tokens": 5}}),
        )
    }

    #[test]
    fn llama_server_requests_carry_token_budget_and_sorted_schema() {
        let server = llama_stub(|_| chat_reply("<think>hidden</think>{\"answer\": 42}", "stop"));
        let client = ThinkClient::llama_server(&server.url("/v1"), "secret-token", "qwen3.5-4b");
        let schema = json!({"type": "object", "properties": {"answer": {"type": "integer"}}, "required": ["answer"], "additionalProperties": false});
        let request = ChatRequest::new("sys", "user")
            .max_tokens(100)
            .temperature(0.0)
            .reasoning_budget(0)
            .json_schema(schema);
        #[derive(serde::Deserialize)]
        struct Answer {
            answer: i64,
        }
        let answer: Answer = client.complete_json(&request).unwrap();
        assert_eq!(answer.answer, 42);
        let sent = server
            .requests()
            .into_iter()
            .find(|r| r.path == "/v1/chat/completions")
            .unwrap();
        assert_eq!(
            sent.header("authorization").as_deref(),
            Some("Bearer secret-token")
        );
        let body = sent.json();
        assert_eq!(body["thinking_budget_tokens"], 0);
        assert_eq!(body["chat_template_kwargs"]["enable_thinking"], false);
        assert_eq!(body["max_tokens"], 100);
        assert_eq!(body["response_format"]["json_schema"]["name"], "response");
        assert_eq!(body["response_format"]["json_schema"]["strict"], true);
        // Sorted keys on the wire.
        let raw = String::from_utf8(sent.body.clone()).unwrap();
        assert!(raw.find("\"max_tokens\"").unwrap() < raw.find("\"messages\"").unwrap());
        assert!(raw.find("\"messages\"").unwrap() < raw.find("\"model\"").unwrap());
        assert_eq!(client.token_count("hello").unwrap(), Some(4));
        assert_eq!(client.context_tokens(), 8192);
    }

    #[test]
    fn thinking_budget_is_capped_at_half_the_output() {
        let request = ChatRequest::new("s", "u").max_tokens(1000);
        let body = chat_body(
            Dialect::LlamaServer,
            "m",
            &request,
            None,
            Some(DEFAULT_THINKING_BUDGET),
            &[],
        );
        assert_eq!(body["thinking_budget_tokens"], 500);
        assert!(body.get("chat_template_kwargs").is_none());
        let body = chat_body(
            Dialect::LlamaServer,
            "m",
            &ChatRequest::new("s", "u"),
            None,
            Some(DEFAULT_THINKING_BUDGET),
            &[("temperature", 0.05)],
        );
        assert_eq!(body["thinking_budget_tokens"], 8192);
        assert_eq!(body["temperature"], 0.05);
        // A chosen level is the level for tasks without a budget, a ceiling otherwise.
        let support = ReasoningSupport::built_in(catalog::entry("qwen3.5-4b").unwrap());
        assert_eq!(
            support.request_level(ReasoningLevel::High, Some(256)),
            Some(ReasoningLevel::Low)
        );
        assert_eq!(
            support.request_level(ReasoningLevel::Low, None),
            Some(ReasoningLevel::Low)
        );
        assert_eq!(
            support.request_level(ReasoningLevel::Max, None),
            Some(ReasoningLevel::High)
        );
        assert_eq!(
            support.request_level(ReasoningLevel::Automatic, Some(0)),
            None
        );
        let level = support.request_level(ReasoningLevel::Off, Some(4096));
        let body = chat_body(
            Dialect::LlamaServer,
            "m",
            &ChatRequest::new("s", "u").reasoning_budget(4096),
            level,
            Some(8192),
            &[],
        );
        assert_eq!(body["thinking_budget_tokens"], 0);
    }

    #[test]
    fn dialects_get_their_own_fields() {
        let request = ChatRequest::new("s", "u")
            .max_tokens(900)
            .temperature(0.3)
            .reasoning_budget(256);
        let openai = chat_body(Dialect::OpenAi, "gpt-5-mini", &request, None, None, &[]);
        assert_eq!(openai["max_completion_tokens"], 900);
        assert!(openai.get("temperature").is_none());
        assert_eq!(openai["reasoning_effort"], "low");
        let openai_chat = chat_body(Dialect::OpenAi, "gpt-4.1", &request, None, None, &[]);
        assert!((openai_chat["temperature"].as_f64().unwrap() - 0.3).abs() < 1e-6);
        assert!(openai_chat.get("reasoning_effort").is_none());

        let router = chat_body(Dialect::OpenRouter, "meta/llama", &request, None, None, &[]);
        assert_eq!(router["reasoning"]["max_tokens"], 256);
        assert_eq!(router["reasoning"]["exclude"], true);
        assert_eq!(router["provider"]["data_collection"], "deny");
        assert_eq!(router["provider"]["require_parameters"], true);
        assert!(router.get("temperature").is_none());
        let off = chat_body(
            Dialect::OpenRouter,
            "m",
            &ChatRequest::new("s", "u")
                .reasoning_budget(0)
                .temperature(0.2),
            None,
            None,
            &[],
        );
        assert_eq!(off["reasoning"]["effort"], "none");
        assert!(off.get("temperature").is_some());

        let generic = chat_body(Dialect::Generic, "x", &request, None, None, &[]);
        assert_eq!(generic["max_tokens"], 900);
        assert!(
            generic.get("reasoning_effort").is_none()
                && generic.get("thinking_budget_tokens").is_none()
        );
        let generic = chat_body(
            Dialect::Generic,
            "x",
            &request,
            Some(ReasoningLevel::Medium),
            None,
            &[],
        );
        assert_eq!(generic["reasoning_effort"], "medium");

        assert_eq!(
            Dialect::inferred("https://api.openai.com/v1"),
            Dialect::OpenAi
        );
        assert_eq!(
            Dialect::inferred("https://openrouter.ai/api/v1"),
            Dialect::OpenRouter
        );
        assert_eq!(
            Dialect::inferred("http://localhost:1234/v1"),
            Dialect::Generic
        );
    }

    /// OpenAI's model pages on 26 October 2026. GPT-6 models used to have no
    /// levels, so a chosen level never reached the request.
    #[test]
    fn gpt_6_models_offer_their_documented_levels() {
        use ReasoningLevel::*;
        let up_to_max = vec![Low, Medium, High, Xhigh, Max];
        let known = |model| ReasoningSupport::known(Dialect::OpenAi, "", model);
        let sol = known("GPT-6.1-Sol");
        assert_eq!(sol, ReasoningSupport::new(&up_to_max, Some(Medium)));
        assert_eq!(sol.request_level(High, None), Some(High));
        assert_eq!(
            sol.request_level(High, Some(0)),
            Some(Low),
            "6.1 Sol rejects none"
        );
        for model in ["gpt-6-sol", "gpt-6-luna"] {
            let support = known(model);
            assert_eq!(support.levels[0], Off, "{model}");
            assert_eq!(support.levels[1..], up_to_max[..], "{model}");
            assert_eq!(support.default_level, Some(Medium), "{model}");
        }
        assert_eq!(
            known("gpt-6-astra"),
            ReasoningSupport::new(&up_to_max, None)
        );
        assert_eq!(
            known("gpt-6.2-sol").levels,
            up_to_max,
            "a newer GPT-6 model gets no Off"
        );

        let settings = Settings {
            summarizer_backend: SummarizerBackend::ChatGptPlan,
            chatgpt_plan_model: "gpt-6.1-sol".into(),
            ..Settings::default()
        };
        assert_eq!(reasoning_choices(&settings), (up_to_max, Some(Medium)));
        assert_eq!(plans::chatgpt::context_tokens("gpt-6.1-sol"), 922_000);

        // OpenAI's API treats GPT-6 as a reasoning model: no temperature, and
        // Automatic maps a task's budget onto an effort.
        let request = ChatRequest::new("s", "u")
            .temperature(0.3)
            .reasoning_budget(1_024);
        let body = chat_body(Dialect::OpenAi, "gpt-6.1-sol", &request, None, None, &[]);
        assert!(body.get("temperature").is_none());
        assert_eq!(body["reasoning_effort"], "medium");
    }

    #[test]
    fn truncation_is_reported_or_kept() {
        let server = llama_stub(|_| chat_reply("partial answ", "length"));
        let client = ThinkClient::llama_server(&server.url("/v1"), "t", "m");
        let err = client.complete(&ChatRequest::new("s", "u")).unwrap_err();
        assert!(
            matches!(err.downcast_ref::<AiError>(), Some(AiError::Truncated { partial }) if partial == "partial answ")
        );
        assert_eq!(
            client
                .complete(&ChatRequest::new("s", "u").keep_truncated())
                .unwrap(),
            "partial answ"
        );
        let full = client.complete_full(&ChatRequest::new("s", "u")).unwrap();
        assert!(full.truncated);
    }

    #[test]
    fn http_errors_carry_the_server_message() {
        let server = StubServer::start(|_| {
            Reply::Json(400, json!({"error": {"message": "context too long"}}))
        });
        let client = ThinkClient::llama_server(&server.url("/v1"), "t", "m");
        let err = client.complete(&ChatRequest::new("s", "u")).unwrap_err();
        assert_eq!(
            err.to_string(),
            "LLM server returned HTTP 400: context too long"
        );
    }

    #[test]
    fn transient_errors_are_retried_once() {
        let calls = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let counter = calls.clone();
        let server = StubServer::start(move |_| {
            if counter.fetch_add(1, Ordering::SeqCst) == 0 {
                Reply::Json(503, json!({"error": {"message": "busy"}}))
            } else {
                chat_reply("ok", "stop")
            }
        });
        let client = ThinkClient::openai_compatible(&server.url("/v1"), "m", None, &[]).unwrap();
        assert_eq!(client.complete(&ChatRequest::new("s", "u")).unwrap(), "ok");
        assert_eq!(calls.load(Ordering::SeqCst), 2);
    }

    #[test]
    fn streams_sse_deltas_and_hides_reasoning() {
        let server = StubServer::start(|_| {
            Reply::Sse(vec![
                json!({"choices": [{"delta": {"content": "<thi"}, "finish_reason": null}]}).to_string(),
                json!({"choices": [{"delta": {"content": "nk>secret</think>Hel"}, "finish_reason": null}]}).to_string(),
                json!({"choices": [{"delta": {"content": "lo"}, "finish_reason": null}]}).to_string(),
                json!({"choices": [{"delta": {}, "finish_reason": "stop"}]}).to_string(),
                "[DONE]".into(),
            ])
        });
        let client =
            ThinkClient::openai_compatible(&server.url("/v1"), "m", Some("key".into()), &[])
                .unwrap();
        let mut deltas = Vec::new();
        let text = client
            .stream(&ChatRequest::new("s", "u"), &mut |d| {
                deltas.push(d.to_string())
            })
            .unwrap();
        assert_eq!(text, "Hello");
        assert_eq!(deltas.concat(), "Hello");
        let sent = server.requests().pop().unwrap();
        assert_eq!(sent.json()["stream"], true);
        assert_eq!(sent.header("authorization").as_deref(), Some("Bearer key"));
    }

    #[test]
    fn stream_length_finish_is_truncation_and_cancel_returns_partial() {
        let server = StubServer::start(|_| {
            Reply::Sse(vec![
                json!({"choices": [{"delta": {"content": "cut"}, "finish_reason": null}]})
                    .to_string(),
                json!({"choices": [{"delta": {}, "finish_reason": "length"}]}).to_string(),
            ])
        });
        let client = ThinkClient::llama_server(&server.url("/v1"), "t", "m");
        let err = client
            .stream(&ChatRequest::new("s", "u"), &mut |_| {})
            .unwrap_err();
        assert!(matches!(
            err.downcast_ref::<AiError>(),
            Some(AiError::Truncated { .. })
        ));
        let cancel = AtomicBool::new(true);
        let partial = client
            .stream_full(&ChatRequest::new("s", "u"), Some(&cancel), &mut |_| {})
            .unwrap();
        assert!(partial.cancelled);
    }

    #[test]
    fn rejected_streams_fall_back_to_one_request() {
        let server = StubServer::start(|request| {
            if request.json()["stream"] == true {
                Reply::Json(400, json!({"error": {"message": "stream unsupported"}}))
            } else {
                chat_reply("whole", "stop")
            }
        });
        let client = ThinkClient::openai_compatible(&server.url("/v1"), "m", None, &[]).unwrap();
        let mut seen = String::new();
        assert_eq!(
            client
                .stream(&ChatRequest::new("s", "u"), &mut |d| seen.push_str(d))
                .unwrap(),
            "whole"
        );
        assert_eq!(seen, "whole");
    }

    #[test]
    fn ollama_uses_api_chat_with_schema_and_think() {
        let server = StubServer::start(|request| match request.path.as_str() {
            "/api/chat" if request.json()["stream"] == true => Reply::Lines(vec![
                json!({"message": {"content": "Hi "}, "done": false}).to_string(),
                json!({"message": {"content": "there"}, "done": false}).to_string(),
                json!({"done": true, "done_reason": "stop"}).to_string(),
            ]),
            "/api/chat" => Reply::Json(
                200,
                json!({"message": {"content": "{\"ok\": true}"}, "done_reason": "stop"}),
            ),
            "/api/tags" => Reply::Json(
                200,
                json!({"models": [{"name": "qwen3:8b"}, {"name": "gemma3:4b"}]}),
            ),
            _ => Reply::Text(404, String::new()),
        });
        let client = ThinkClient::ollama(&server.url(""), "", &[]).unwrap();
        let schema = json!({"type": "object"});
        let text = client
            .complete(
                &ChatRequest::new("s", "u")
                    .reasoning_budget(0)
                    .max_tokens(50)
                    .json_schema(schema),
            )
            .unwrap();
        assert_eq!(text, "{\"ok\": true}");
        let body = server.last_json("/api/chat");
        assert_eq!(body["model"], "gemma3:4b");
        assert_eq!(body["think"], false);
        assert_eq!(body["format"]["type"], "object");
        assert_eq!(body["options"]["num_ctx"], 16_384);
        assert_eq!(body["options"]["num_predict"], 50);
        let mut seen = String::new();
        assert_eq!(
            client
                .stream(&ChatRequest::new("s", "u"), &mut |d| seen.push_str(d))
                .unwrap(),
            "Hi there"
        );
        assert_eq!(seen, "Hi there");
        assert!(client.display_name().ends_with("· Ollama on this PC"));
    }

    #[test]
    fn remote_servers_need_approval_and_https() {
        let err = ThinkClient::openai_compatible("https://api.openai.com/v1", "gpt-4.1", None, &[])
            .err()
            .unwrap();
        assert!(matches!(
            err.downcast_ref::<AiError>(),
            Some(AiError::ConsentRequired(_))
        ));
        assert!(err.to_string().contains("https://api.openai.com"));
        let err = ThinkClient::ollama(
            "http://example.com:11434",
            "m",
            &["http://example.com:11434".into()],
        )
        .err()
        .unwrap();
        assert!(err.to_string().contains("HTTPS"));
        let client = ThinkClient::openai_compatible(
            "https://api.openai.com/v1",
            "gpt-4.1",
            None,
            &["https://api.openai.com".into()],
        )
        .unwrap();
        assert!(!client.is_local());
        assert_eq!(client.display_name(), "gpt-4.1 · api.openai.com");
        assert!(client.inference_privacy().contains("api.openai.com"));
        assert_eq!(client.structured_output_enum_limit(), Some(1_000));

        let mut settings = Settings {
            summarizer_backend: SummarizerBackend::OpenAICompatible,
            ..Settings::default()
        };
        settings.openai_base_url = "https://openrouter.ai/api/v1".into();
        settings.openai_model = "meta/llama".into();
        let dir = tempfile::tempdir().unwrap();
        let runtime = RuntimeManager::new(lokalbot_core::LibraryPaths::new(dir.path()), &settings);
        assert!(ThinkClient::new(&runtime, &settings).is_err());
        settings.approved_remote_inference_origins = vec!["https://openrouter.ai".into()];
        let client = ThinkClient::new(&runtime, &settings).unwrap();
        assert_eq!(client.structured_output_enum_limit(), Some(500));
    }

    #[test]
    fn built_in_client_names_the_model_on_this_pc() {
        let dir = tempfile::tempdir().unwrap();
        let settings = Settings::default();
        let runtime = RuntimeManager::new(lokalbot_core::LibraryPaths::new(dir.path()), &settings);
        let client = ThinkClient::new(&runtime, &settings).unwrap();
        assert_eq!(client.display_name(), "Qwen3.5 4B · on this PC");
        assert!(client.is_local() && client.is_built_in());
        assert_eq!(client.context_tokens(), 32_768);
        let err = client.complete(&ChatRequest::new("s", "u")).unwrap_err();
        assert!(
            matches!(
                err.downcast_ref::<AiError>(),
                Some(AiError::ModelMissing(_))
            ),
            "{err}"
        );
        let bad = Settings {
            built_in_model_id: "gone".into(),
            ..Settings::default()
        };
        assert!(ThinkClient::new(&runtime, &bad).is_err());
    }

    #[test]
    fn embeddings_are_batched_ordered_and_normalized() {
        let server = StubServer::start(|request| {
            let inputs = request.json()["input"]
                .as_array()
                .cloned()
                .unwrap_or_default();
            // Reverse the rows; the client must reorder them by index.
            let data: Vec<Value> = inputs
                .iter()
                .enumerate()
                .rev()
                .map(|(i, input)| json!({"index": i, "embedding": [input.as_str().unwrap().len() as f64, 0.0, 0.0]}))
                .collect();
            Reply::Json(200, json!({"data": data}))
        });
        let client = EmbeddingClient::for_server(&server.url("/v1"), Some("tok".into()));
        let texts: Vec<String> = (0..10).map(|i| "x".repeat(i + 1)).collect();
        let vectors = client.embed_documents(&texts).unwrap();
        assert_eq!(vectors.len(), 10);
        assert!(vectors.iter().all(|v| (dot(v, v) - 1.0).abs() < 1e-5));
        let requests = server.requests();
        assert_eq!(requests.len(), 2);
        let first = requests[0].json();
        assert_eq!(first["input"][0], format!("{DOCUMENT_PREFIX}x"));
        assert_eq!(first["model"], "embeddinggemma-2-q8");
        assert_eq!(first["cache_prompt"], false);
        assert_eq!(
            request_ranges(&["a".repeat(2_500), "b".into(), "c".into()]),
            vec![0..1, 1..3]
        );
    }

    #[test]
    fn completions_stream_with_cotyping_sampling() {
        let server = StubServer::start(|_| {
            Reply::Sse(vec![
                json!({"choices": [{"text": " world", "finish_reason": null}]}).to_string(),
                json!({"choices": [{"text": " and more", "finish_reason": null}]}).to_string(),
                json!({"choices": [{"text": "", "finish_reason": "length"}]}).to_string(),
            ])
        });
        let client = CompletionClient::server(&server.url("/v1"), "m", None, &[]).unwrap();
        let request = CompletionRequest::cotyping("Hello", 4, false);
        assert_eq!(request.max_tokens, 6);
        let mut partials = Vec::new();
        let text = client
            .stream(&request, &mut |_, chunks| chunks >= 1, &mut |p| {
                partials.push(p.to_string())
            })
            .unwrap();
        assert_eq!(text, " world");
        let body = server.last_json("/v1/completions");
        assert_eq!(body["top_k"], 20);
        assert_eq!(body["seed"], 0x00C0_FFEE);
        assert_eq!(body["stop"][0], "\n");
        assert_eq!(CompletionRequest::cotyping("x", 100, true).max_tokens, 120);
        assert!(CompletionClient::server("https://typing.example.com/v1", "m", None, &[]).is_err());
    }

    #[test]
    fn context_blocks_join_in_front_of_the_instruction_elsewhere() {
        let request =
            ChatRequest::new("s", "Instruction").context(vec!["Transcript".into(), String::new()]);
        assert_eq!(request.user_text(), "Transcript\n\n\n\nInstruction");
        let body = chat_body(Dialect::Generic, "m", &request, None, None, &[]);
        assert_eq!(body["messages"][1]["content"], request.user_text());
        let ollama = ollama_body("m", &request, None, false);
        assert_eq!(ollama["messages"][1]["content"], request.user_text());
        assert_eq!(ChatRequest::new("s", "u").user_text(), "u");
    }

    #[test]
    fn openrouter_follows_the_chosen_data_policy() {
        let request = ChatRequest::new("s", "u");
        let body = chat_body(Dialect::OpenRouter, "m", &request, None, None, &[]);
        assert_eq!(
            with_data_policy(body.clone(), OpenRouterDataPolicy::PrivateOnly)["provider"]["data_collection"],
            "deny"
        );
        let allowed = with_data_policy(body, OpenRouterDataPolicy::AccountPolicy);
        assert_eq!(allowed["provider"]["data_collection"], "allow");
        // Other dialects carry no provider block, and get none.
        let generic = with_data_policy(
            chat_body(Dialect::Generic, "m", &request, None, None, &[]),
            OpenRouterDataPolicy::AccountPolicy,
        );
        assert!(generic.get("provider").is_none());

        let dir = tempfile::tempdir().unwrap();
        let mut settings = Settings {
            summarizer_backend: SummarizerBackend::OpenAICompatible,
            openai_base_url: "https://openrouter.ai/api/v1".into(),
            openai_model: "meta/llama".into(),
            approved_remote_inference_origins: vec!["https://openrouter.ai".into()],
            ..Settings::default()
        };
        let runtime = RuntimeManager::new(lokalbot_core::LibraryPaths::new(dir.path()), &settings);
        let policy = |client: &ThinkClient| match &client.inner.backend {
            Backend::Server { data_policy, .. } => *data_policy,
            _ => panic!("not a server"),
        };
        assert_eq!(
            policy(&ThinkClient::new(&runtime, &settings).unwrap()),
            OpenRouterDataPolicy::PrivateOnly
        );
        settings.open_router_data_policy = OpenRouterDataPolicy::AccountPolicy;
        let client = ThinkClient::new(&runtime, &settings)
            .unwrap()
            .with_api_key(Some("k".into()));
        assert_eq!(policy(&client), OpenRouterDataPolicy::AccountPolicy);

        let completion = CompletionClient::server(
            "https://openrouter.ai/api/v1",
            "m",
            None,
            &["https://openrouter.ai".into()],
        )
        .unwrap();
        let body = completion.body(&CompletionRequest::cotyping("x", 4, false), false);
        assert_eq!(body["provider"]["data_collection"], "deny");
        let body = completion
            .with_openrouter_data_policy(OpenRouterDataPolicy::AccountPolicy)
            .body(&CompletionRequest::cotyping("x", 4, false), false);
        assert_eq!(body["provider"]["data_collection"], "allow");
    }

    #[test]
    fn anthropic_urls_use_the_messages_api_with_the_saved_key() {
        let dir = tempfile::tempdir().unwrap();
        let mut settings = Settings {
            summarizer_backend: SummarizerBackend::OpenAICompatible,
            openai_base_url: "https://api.anthropic.com".into(),
            openai_model: "claude-opus-5-5".into(),
            ..Settings::default()
        };
        let runtime = RuntimeManager::new(lokalbot_core::LibraryPaths::new(dir.path()), &settings);
        assert!(
            ThinkClient::new(&runtime, &settings).is_err(),
            "needs approval"
        );
        settings.approved_remote_inference_origins = vec!["https://api.anthropic.com".into()];
        let client = ThinkClient::new(&runtime, &settings)
            .unwrap()
            .with_api_key(Some("sk-ant".into()))
            .with_reasoning_level(ReasoningLevel::High);
        match &client.inner.backend {
            Backend::Anthropic(engine) => {
                assert_eq!(engine.api_key.as_deref(), Some("sk-ant"));
                assert_eq!(engine.level, ReasoningLevel::High);
                assert_eq!(engine.base, "https://api.anthropic.com");
            }
            _ => panic!("not the Messages API"),
        }
        assert!(!client.is_local());
        let (levels, default) = reasoning_choices(&settings);
        assert_eq!(levels.last(), Some(&ReasoningLevel::Max));
        assert_eq!(default, Some(ReasoningLevel::Medium));
    }

    #[test]
    fn plans_need_their_own_approval() {
        let dir = tempfile::tempdir().unwrap();
        let mut settings = Settings {
            summarizer_backend: SummarizerBackend::ChatGptPlan,
            chatgpt_plan_model: "gpt-5.5".into(),
            // An API approval for the same company does not cover the plan.
            approved_remote_inference_origins: vec!["https://api.openai.com".into()],
            ..Settings::default()
        };
        let runtime = RuntimeManager::new(lokalbot_core::LibraryPaths::new(dir.path()), &settings);
        let err = ThinkClient::new(&runtime, &settings).err().unwrap();
        assert!(matches!(
            err.downcast_ref::<AiError>(),
            Some(AiError::ConsentRequired(reason)) if reason.contains("ChatGPT plan")
        ));
        SubscriptionPlan::ChatGpt.set_approved(&mut settings, true);
        let client = ThinkClient::new(&runtime, &settings).unwrap();
        assert_eq!(client.plan(), Some(SubscriptionPlan::ChatGpt));
        assert_eq!(client.display_name(), "gpt-5.5 · ChatGPT plan");
        assert_eq!(client.location(), "api.openai.com");
        assert!(!client.is_local() && !client.is_built_in());
        assert!(client.inference_privacy().contains("ChatGPT plan"));
        assert_eq!(client.context_tokens(), 128_000);
        assert_eq!(client.structured_output_enum_limit(), Some(1_000));

        settings.summarizer_backend = SummarizerBackend::ClaudePlan;
        assert!(ThinkClient::new(&runtime, &settings).is_err());
        SubscriptionPlan::Claude.set_approved(&mut settings, true);
        let client = ThinkClient::new(&runtime, &settings).unwrap();
        assert_eq!(client.display_name(), "Claude Code default · Claude plan");
        assert_eq!(client.context_tokens(), 200_000);
        let (levels, _) = reasoning_choices(&settings);
        assert_eq!(levels.first(), Some(&ReasoningLevel::Low));
        settings.claude_plan_model = "claude-haiku-4-5".into();
        assert!(reasoning_choices(&settings).0.is_empty());
    }

    #[test]
    fn think_filter_handles_split_tags() {
        let mut filter = ThinkFilter::default();
        let mut out = String::new();
        for piece in ["a<", "think", ">x</th", "ink>b<t", "x"] {
            out.push_str(&filter.push(piece));
        }
        out.push_str(&filter.finish());
        assert_eq!(out, "ab<tx");
    }
}
