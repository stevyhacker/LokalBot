//! Autocomplete on a server (`CotypingServerRoute.swift`): Think's Ollama or
//! OpenAI-compatible server, or another one the user names. The route is
//! built from settings for every request, so a change applies to the next
//! keystroke. Typing goes to a server only after its origin is approved for
//! autocomplete (`approved_remote_autocomplete_origins`); Think's approval
//! does not cover it. A loopback server needs no approval, since nothing
//! leaves the computer.
//!
//! Raw text completion where the server offers it, chat continuation
//! otherwise. A failed request is never replayed: a newer keystroke supersedes
//! it anyway. There is no prefill: a server keeps its own cache.

use std::collections::HashSet;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use anyhow::Result;
use lokalbot_core::Settings;
use lokalbot_core::access::{is_loopback_url, is_private_network_url, origin_of};
use lokalbot_core::settings::{
    CotypingBackend, CotypingServerRequestStyle, OpenRouterDataPolicy, SummarizerBackend,
};
use parking_lot::Mutex;

use super::client::{Cancelled, Completion, Timings};
use super::healing;
use super::normalize::{self, Normalized, Suppression};
use super::prompt::Request;
use crate::anthropic;
use crate::error::AiError;
use crate::prompts;
use crate::remote_gate::{self, Blocked, Priority, Wait};
use crate::think::{self, ChatRequest, CompletionClient, CompletionRequest, Dialect};

/// A completion slower than this is no longer worth showing.
pub const DEADLINE: Duration = Duration::from_secs(15);
/// Room for reasoning a model cannot turn off, on top of the phrase.
const REASONING_ROOM_TOKENS: u32 = 2_048;
const MINIMUM_CHAT_TOKENS: u32 = 32;

/// The credential store account for "Another server"'s key.
pub const API_KEY_ACCOUNT: &str = "autocomplete-server-api-key";

/// One resolved autocomplete server.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Endpoint {
    pub base_url: String,
    pub model: String,
    pub api_key: Option<String>,
    pub dialect: Dialect,
    pub request_style: CotypingServerRequestStyle,
    pub data_policy: OpenRouterDataPolicy,
    pub origin: String,
}

impl Endpoint {
    /// Loopback: the prompt never leaves this computer.
    pub fn is_on_this_computer(&self) -> bool {
        is_loopback_url(&self.base_url)
    }

    /// A server the user runs themselves, which takes llama.cpp's sampling
    /// fields. Hosted APIs may reject unknown fields.
    pub fn is_self_hosted(&self) -> bool {
        self.is_on_this_computer() || is_private_network_url(&self.base_url)
    }

    /// Whether the first request goes through chat rather than raw completion.
    pub fn starts_with_chat(&self) -> bool {
        match self.request_style {
            CotypingServerRequestStyle::Chat => true,
            CotypingServerRequestStyle::TextCompletion => false,
            // OpenAI and Anthropic offer no raw completions for current
            // models, and OpenRouter's raw route continues text as gibberish
            // on many hosts. Servers people run themselves offer them.
            CotypingServerRequestStyle::Automatic => {
                anthropic::is_anthropic(&self.base_url)
                    || matches!(self.dialect, Dialect::OpenAi | Dialect::OpenRouter)
            }
        }
    }

    /// The server and model, without the key.
    pub fn identity(&self) -> String {
        let path = self
            .base_url
            .split_once("://")
            .and_then(|(_, rest)| rest.split_once('/'))
            .map_or("", |(_, path)| path);
        format!("{}|/{path}|{}", self.origin, self.model)
    }
}

/// What to change before a selected server can be used.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Problem {
    /// Think runs on the built-in model or a plan, not a server.
    ThinkHasNoServer,
    MissingUrl,
    BadUrl,
    Unencrypted {
        origin: String,
    },
    NeedsApproval {
        origin: String,
    },
    MissingOllamaModel,
    MissingThinkModel,
    MissingModel,
}

/// Where the next completion goes (`CotypingRoute`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Route {
    OnDevice,
    Server(Endpoint),
    Unavailable(Problem),
}

/// The API keys a route may need, read from the credential store only when
/// asked. `None` for presentation and decisions about context.
pub struct Keys<'a> {
    /// Think's OpenAI-compatible key.
    pub think: &'a dyn Fn() -> Option<String>,
    pub server: &'a dyn Fn() -> Option<String>,
}

/// The selected server's URL as configured, before approval checks. `None`
/// on-device and for a server that is not set up.
pub fn configured_url(settings: &Settings) -> Option<String> {
    let url = match settings.cotyping_backend {
        CotypingBackend::OnDevice => return None,
        CotypingBackend::ThinkServer => match settings.summarizer_backend {
            SummarizerBackend::Ollama => {
                let base = settings.ollama_base_url.trim().trim_end_matches('/');
                if base.is_empty() {
                    return None;
                }
                format!("{base}/v1")
            }
            SummarizerBackend::OpenAICompatible => settings.openai_base_url.clone(),
            _ => return None,
        },
        CotypingBackend::Server => settings.cotyping_server_base_url.clone(),
    };
    let trimmed = url.trim().trim_end_matches('/');
    (!trimmed.is_empty()).then(|| trimmed.to_string())
}

/// `cotypingRoute(includingCredentials:)`.
pub fn route(settings: &Settings, keys: Option<&Keys>) -> Route {
    let url = configured_url(settings);
    let override_model = settings.cotyping_think_server_model.trim();
    match settings.cotyping_backend {
        CotypingBackend::OnDevice => Route::OnDevice,
        CotypingBackend::ThinkServer => match settings.summarizer_backend {
            SummarizerBackend::Ollama => {
                let model = if override_model.is_empty() {
                    settings.ollama_model.trim()
                } else {
                    override_model
                };
                server_route(settings, url, model, None, Problem::MissingOllamaModel)
            }
            SummarizerBackend::OpenAICompatible => {
                let model = if override_model.is_empty() {
                    settings.openai_model.trim()
                } else {
                    override_model
                };
                let key = keys.and_then(|keys| (keys.think)());
                server_route(settings, url, model, key, Problem::MissingThinkModel)
            }
            _ => Route::Unavailable(Problem::ThinkHasNoServer),
        },
        CotypingBackend::Server => {
            if settings.cotyping_server_base_url.trim().is_empty() {
                return Route::Unavailable(Problem::MissingUrl);
            }
            let key = keys.and_then(|keys| (keys.server)());
            server_route(
                settings,
                url,
                settings.cotyping_server_model.trim(),
                key,
                Problem::MissingModel,
            )
        }
    }
}

/// `InferenceEndpointPolicy.validate(allowsPrivateNetworkHTTP: true)`: the
/// reason `url` may not get typing yet, or `None`.
pub fn validate(url: &str, approved: &[String]) -> Option<Problem> {
    let Some(origin) =
        origin_of(url).filter(|o| o.starts_with("http://") || o.starts_with("https://"))
    else {
        return Some(Problem::BadUrl);
    };
    if is_loopback_url(url) {
        return None;
    }
    if !origin.starts_with("https://") && !is_private_network_url(url) {
        return Some(Problem::Unencrypted { origin });
    }
    if !approved.iter().any(|a| a.eq_ignore_ascii_case(&origin)) {
        return Some(Problem::NeedsApproval { origin });
    }
    None
}

fn server_route(
    settings: &Settings,
    url: Option<String>,
    model: &str,
    key: Option<String>,
    missing_model: Problem,
) -> Route {
    let Some(url) = url else {
        return Route::Unavailable(Problem::BadUrl);
    };
    if let Some(problem) = validate(&url, &settings.approved_remote_autocomplete_origins) {
        return Route::Unavailable(problem);
    }
    let Some(origin) = origin_of(&url) else {
        return Route::Unavailable(Problem::BadUrl);
    };
    if model.is_empty() {
        return Route::Unavailable(missing_model);
    }
    let dialect = Dialect::inferred(&url);
    Route::Server(Endpoint {
        base_url: url,
        model: model.to_string(),
        api_key: key
            .map(|key| key.trim().to_string())
            .filter(|key| !key.is_empty()),
        dialect,
        request_style: settings.cotyping_server_request_style,
        data_policy: settings.open_router_data_policy,
        origin,
    })
}

/// True unless the prompt stays on this computer. A server that is not set up
/// yet counts as off it.
pub fn leaves_this_computer(settings: &Settings) -> bool {
    if settings.cotyping_backend == CotypingBackend::OnDevice {
        return false;
    }
    configured_url(settings).is_none_or(|url| !is_loopback_url(&url))
}

/// Host of the selected server, for "sent to {host}".
pub fn configured_host(settings: &Settings) -> Option<String> {
    let url = configured_url(settings)?;
    lokalbot_core::access::host_of(&url)
}

/// The model id recorded with statistics (`cotypingStatisticsModelID`).
pub fn statistics_model_id(settings: &Settings) -> String {
    match settings.cotyping_backend {
        CotypingBackend::OnDevice => settings.cotyping_built_in_model_id.clone(),
        backend => match route(settings, None) {
            Route::Server(endpoint) => endpoint.model,
            _ => match backend {
                CotypingBackend::ThinkServer => "thinkServer".to_string(),
                _ => "server".to_string(),
            },
        },
    }
}

/// Everything about the route that changes what a completion can be, for
/// caches. The key is left out (`cotypingRouteFingerprint`).
pub fn fingerprint(settings: &Settings) -> String {
    match route(settings, None) {
        Route::OnDevice => "on-device".to_string(),
        Route::Server(endpoint) => format!(
            "server|{}|{:?}|{:?}",
            endpoint.identity(),
            endpoint.request_style,
            endpoint.data_policy
        ),
        Route::Unavailable(problem) => format!("unavailable|{problem:?}"),
    }
}

/// Why the last request to a server brought no suggestion. Writing shows it,
/// since typing elsewhere shows no error. Holds no server message: a request
/// error can quote the prompt.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Failure {
    Status(u16),
    Unreachable,
    BadReply,
    /// The model spent its whole reply reasoning.
    Reasoned,
    /// `{model} answered with no text.`
    EmptyReply,
}

/// The last problem with one server.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ServerProblem {
    /// [`Endpoint::identity`].
    pub identity: String,
    pub model: String,
    pub failure: Failure,
}

/// What a server taught this run, kept until LokalBot quits.
#[derive(Default)]
pub struct ServerMemory {
    /// Servers whose raw route answered as unsupported.
    chat_only: Mutex<HashSet<String>>,
    /// Models that spent a whole short reply on reasoning.
    reasoning: Mutex<HashSet<String>>,
}

/// One suggestion from `endpoint`. Blocking; `cancel` is checked between
/// streamed tokens and while waiting out a rate limit.
pub fn complete(
    endpoint: &Endpoint,
    request: &Request,
    cancel: &AtomicBool,
    memory: &ServerMemory,
) -> Result<(Completion, Option<Failure>)> {
    let started = Instant::now();
    // A slot on the origin's gate, shared with Think, so autocomplete can't pile
    // onto a server it's using for something else (`RemoteCotypingEngine`).
    let ticket = remote_gate::shared()
        .acquire(
            &endpoint.origin,
            Priority::Interactive,
            Wait {
                cancel: Some(cancel),
                deadline: Some(started + DEADLINE),
            },
        )
        .map_err(|blocked| match blocked {
            Blocked::Cancelled => anyhow::Error::from(Cancelled),
            Blocked::TimedOut => AiError::ServerUnreachable(endpoint.base_url.clone()).into(),
        })?;
    let result = suggest(endpoint, request, cancel, memory);
    let failure = result
        .as_ref()
        .err()
        .and_then(|err| err.downcast_ref::<AiError>());
    ticket.finish(
        failure.is_some_and(AiError::is_rate_limit),
        failure.and_then(AiError::retry_after),
    );
    if cancel.load(Ordering::Relaxed) {
        return Err(Cancelled.into());
    }
    let normalized = result?;
    let failure = (normalized.0.suppression == Some(Suppression::EmptyGeneration))
        .then_some(Failure::EmptyReply);
    let total_ms = started.elapsed().as_secs_f64() * 1000.0;
    Ok((
        Completion {
            result: normalized.0,
            raw: normalized.1,
            hit_limit: false,
            timings: Timings {
                total_ms,
                ..Timings::default()
            },
        },
        failure,
    ))
}

/// The UI's view of a failed request. A cancelled one is no problem.
pub fn failure_of(err: &anyhow::Error) -> Option<Failure> {
    if err.downcast_ref::<Cancelled>().is_some() {
        return None;
    }
    Some(match err.downcast_ref::<AiError>() {
        Some(AiError::HttpStatus { code, .. }) => Failure::Status(*code),
        Some(AiError::ServerUnreachable(_)) => Failure::Unreachable,
        Some(AiError::Unavailable(_)) => Failure::Reasoned,
        _ => Failure::BadReply,
    })
}

fn suggest(
    endpoint: &Endpoint,
    request: &Request,
    cancel: &AtomicBool,
    memory: &ServerMemory,
) -> Result<(Normalized, String)> {
    if endpoint.starts_with_chat() || memory.chat_only.lock().contains(&endpoint.identity()) {
        return chat(endpoint, request, cancel, memory);
    }
    match raw(endpoint, request, cancel) {
        Err(err)
            if endpoint.request_style == CotypingServerRequestStyle::Automatic
                && rejects_text_completion(&err) =>
        {
            memory.chat_only.lock().insert(endpoint.identity());
            log::info!(
                "autocomplete server has no raw completions ({}); using chat",
                endpoint.origin
            );
            chat(endpoint, request, cancel, memory)
        }
        other => other,
    }
}

/// A server without a raw completion route, or a model it serves through chat
/// only (`rejectsTextCompletion`).
pub fn rejects_text_completion(err: &anyhow::Error) -> bool {
    let Some(AiError::HttpStatus { code, detail, .. }) = err.downcast_ref::<AiError>() else {
        return false;
    };
    match code {
        404 | 405 | 501 => true,
        400 | 422 => {
            let lowered = detail.to_lowercase();
            ["not supported", "unsupported", "chat", "does not support"]
                .iter()
                .any(|needle| lowered.contains(needle))
        }
        _ => false,
    }
}

/// Raw `/v1/completions`. The prompt goes cut back to the word boundary, and
/// only output that re-types the cut text counts: a server cannot be held to
/// that prefix, so other output is suppressed.
fn raw(
    endpoint: &Endpoint,
    request: &Request,
    cancel: &AtomicBool,
) -> Result<(Normalized, String)> {
    let healed = healing::healed_generation(
        &request.prompt,
        &request.word_prefix,
        request.preceding_ends_with_whitespace(),
    );
    // A space joins the first word's token; a cut fragment needs a few more.
    let healing_tokens = if healed.required_prefix.chars().all(char::is_whitespace) {
        0
    } else {
        4
    };
    let completion = CompletionRequest {
        prompt: healed.healed_prompt.clone(),
        max_tokens: (request.max_tokens + healing_tokens) as u32,
        temperature: request.sampling.temperature as f32,
        top_p: request.sampling.top_p as f32,
        top_k: request.sampling.top_k,
        min_p: request.sampling.min_p as f32,
        repeat_penalty: request.sampling.repeat_penalty as f32,
        seed: u64::from(request.sampling.seed),
        // The normalizer still collapses defensively.
        stop: if request.multi_line {
            Vec::new()
        } else {
            vec!["\n".to_string()]
        },
    };
    let client = CompletionClient::server(
        &endpoint.base_url,
        &endpoint.model,
        endpoint.api_key.clone(),
        std::slice::from_ref(&endpoint.origin),
    )?
    .with_openrouter_data_policy(endpoint.data_policy);
    let reply = client.stream(
        &completion,
        &mut |_, _| cancel.load(Ordering::Relaxed),
        &mut |_| {},
    )?;
    Ok((
        normalize_healed(&reply, &healed.required_prefix, request),
        reply,
    ))
}

/// `CotypingEngine.normalize`.
pub fn normalize_healed(raw: &str, required_prefix: &str, request: &Request) -> Normalized {
    if required_prefix.is_empty() {
        return normalize::normalize_detailed(raw, request);
    }
    match raw.strip_prefix(required_prefix) {
        Some(rest) => normalize::normalize_detailed(rest, request),
        None => Normalized {
            text: String::new(),
            suppression: Some(if raw.is_empty() {
                Suppression::EmptyGeneration
            } else {
                Suppression::WordCompletionMismatch
            }),
        },
    }
}

/// `ChatContinuationEngine`: the autocomplete instruction as the system
/// message and the rendered prompt as the user message, with thinking off. A
/// reply cut off at the budget keeps the text it has; an empty reply means the
/// model had nothing to add.
fn chat(
    endpoint: &Endpoint,
    request: &Request,
    cancel: &AtomicBool,
    memory: &ServerMemory,
) -> Result<(Normalized, String)> {
    let phrase = (request.max_tokens as u32).max(MINIMUM_CHAT_TOKENS);
    let key = format!("{}|{}", endpoint.base_url, endpoint.model);
    let reply = if memory.reasoning.lock().contains(&key) {
        chat_reply(endpoint, request, phrase + REASONING_ROOM_TOKENS, cancel)?
    } else {
        match chat_reply(endpoint, request, phrase, cancel) {
            Err(err)
                if matches!(
                    err.downcast_ref::<AiError>(),
                    Some(AiError::Truncated { .. })
                ) =>
            {
                memory.reasoning.lock().insert(key);
                log::info!(
                    "autocomplete model reasons before replying ({}); asking with room for it",
                    endpoint.origin
                );
                chat_reply(endpoint, request, phrase + REASONING_ROOM_TOKENS, cancel)?
            }
            other => other?,
        }
    };
    let reply = restoring_word_space(&reply, request);
    Ok((normalize::normalize_detailed(&reply, request), reply))
}

fn chat_reply(
    endpoint: &Endpoint,
    request: &Request,
    max_tokens: u32,
    cancel: &AtomicBool,
) -> Result<String> {
    // Anthropic serves chat completions under /v1 whichever form of its URL
    // was entered.
    let base = if anthropic::is_anthropic(&endpoint.base_url) {
        anthropic::versioned_root(&endpoint.base_url)
    } else {
        endpoint.base_url.clone()
    };
    let chat = ChatRequest::new(prompts::AUTOCOMPLETE_SYSTEM, request.prompt.clone())
        .max_tokens(max_tokens)
        .reasoning_budget(0)
        .temperature(request.sampling.temperature as f32)
        .keep_truncated();
    let completion = match think::short_chat(
        endpoint.dialect,
        &base,
        &endpoint.model,
        endpoint.api_key.as_deref(),
        endpoint.data_policy,
        &chat,
        DEADLINE,
        cancel,
    ) {
        Ok(completion) => completion,
        Err(err)
            if matches!(
                err.downcast_ref::<AiError>(),
                Some(AiError::BadResponse(detail)) if detail.contains("contained no text")
            ) =>
        {
            return Ok(String::new());
        }
        Err(err) => return Err(err),
    };
    if completion.truncated && completion.text.trim().is_empty() {
        if max_tokens > REASONING_ROOM_TOKENS {
            return Err(AiError::Unavailable(format!(
                "{} reasoned until its reply ran out and wrote no suggestion.",
                endpoint.model
            ))
            .into());
        }
        return Err(AiError::Truncated {
            partial: String::new(),
        }
        .into());
    }
    Ok(completion.text)
}

/// Chat models often leave out the space before a new word: "at a" + "higher
/// level" would show as "ahigher level". After a whole word, a reply that
/// starts with a letter or digit starts a new word, so it gets the space
/// back. Inside a word, after a fragment the spell checker does not know, when
/// the reply restates the word at the caret, and in scripts written without
/// spaces, the reply is left as it is.
pub fn restoring_word_space(reply: &str, request: &Request) -> String {
    let (Some(last), Some(first)) = (request.prefix.chars().next_back(), reply.chars().next())
    else {
        return reply.to_string();
    };
    if request.force_word_continuation
        || !request.word_prefix_is_valid_word
        || !is_spaced_word_character(last)
        || !is_spaced_word_character(first)
    {
        return reply.to_string();
    }
    let word = request.word_prefix.to_lowercase();
    if word.chars().count() >= 2 && reply.to_lowercase().starts_with(&word) {
        return reply.to_string();
    }
    format!(" {reply}")
}

/// A letter or digit of a script that puts spaces between words: not Han,
/// kana, Hangul, Thai, Lao, Myanmar or Khmer.
fn is_spaced_word_character(c: char) -> bool {
    if !c.is_alphanumeric() {
        return false;
    }
    !matches!(
        u32::from(c),
        0x0E00..=0x0EFF
            | 0x1000..=0x109F
            | 0x1780..=0x17FF
            | 0x2E80..=0x9FFF
            | 0xAC00..=0xD7AF
            | 0xF900..=0xFAFF
            | 0xFF00..=0xFFEF
            | 0x20000..=0x3FFFF
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::autocomplete::prompt::{Extras, Field, Personalization, build_request};
    use crate::http::testing::{Reply, StubServer};
    use serde_json::json;

    fn settings() -> Settings {
        Settings {
            cotyping_backend: CotypingBackend::Server,
            cotyping_server_base_url: "https://example.com/v1/".into(),
            cotyping_server_model: "small".into(),
            approved_remote_autocomplete_origins: vec!["https://example.com".into()],
            ..Settings::default()
        }
    }

    fn endpoint(settings: &Settings) -> Endpoint {
        match route(settings, None) {
            Route::Server(endpoint) => endpoint,
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn typing_goes_only_to_an_approved_server() {
        let approved = settings();
        assert_eq!(endpoint(&approved).base_url, "https://example.com/v1");
        assert_eq!(endpoint(&approved).origin, "https://example.com");

        let mut other = approved.clone();
        other.approved_remote_autocomplete_origins.clear();
        // Think's approval never counts.
        other.approved_remote_inference_origins = vec!["https://example.com".into()];
        assert_eq!(
            route(&other, None),
            Route::Unavailable(Problem::NeedsApproval {
                origin: "https://example.com".into()
            })
        );

        let mut plain = approved.clone();
        plain.cotyping_server_base_url = "http://example.com/v1".into();
        plain.approved_remote_autocomplete_origins = vec!["http://example.com".into()];
        assert_eq!(
            route(&plain, None),
            Route::Unavailable(Problem::Unencrypted {
                origin: "http://example.com".into()
            })
        );

        // A private network may use plain HTTP, once approved.
        let mut private = approved.clone();
        private.cotyping_server_base_url = "http://192.168.1.20:8080/v1".into();
        private.approved_remote_autocomplete_origins.clear();
        assert!(matches!(
            route(&private, None),
            Route::Unavailable(Problem::NeedsApproval { .. })
        ));
        private.approved_remote_autocomplete_origins = vec!["http://192.168.1.20:8080".into()];
        assert!(endpoint(&private).is_self_hosted());

        // Loopback needs no approval: nothing leaves the computer.
        let mut local = approved.clone();
        local.cotyping_server_base_url = "http://127.0.0.1:8080/v1".into();
        local.approved_remote_autocomplete_origins.clear();
        assert!(endpoint(&local).is_on_this_computer());
        assert!(!leaves_this_computer(&local));

        assert!(leaves_this_computer(&approved));
        assert_eq!(configured_host(&approved).as_deref(), Some("example.com"));
    }

    #[test]
    fn each_missing_piece_has_its_own_reason() {
        let mut empty = settings();
        empty.cotyping_server_base_url = "  ".into();
        assert_eq!(route(&empty, None), Route::Unavailable(Problem::MissingUrl));
        let mut bad = settings();
        bad.cotyping_server_base_url = "ftp://example.com".into();
        assert_eq!(route(&bad, None), Route::Unavailable(Problem::BadUrl));
        let mut no_model = settings();
        no_model.cotyping_server_model = " ".into();
        assert_eq!(
            route(&no_model, None),
            Route::Unavailable(Problem::MissingModel)
        );
        let on_device = Settings::default();
        assert_eq!(route(&on_device, None), Route::OnDevice);
        assert!(!leaves_this_computer(&on_device));
    }

    #[test]
    fn thinks_server_uses_thinks_model_unless_overridden() {
        let mut think = Settings {
            cotyping_backend: CotypingBackend::ThinkServer,
            ..Settings::default()
        };
        assert_eq!(
            route(&think, None),
            Route::Unavailable(Problem::ThinkHasNoServer)
        );
        // A server not set up counts as off this computer.
        assert!(leaves_this_computer(&think));
        think.summarizer_backend = SummarizerBackend::Ollama;
        think.ollama_base_url = "http://localhost:11434/".into();
        think.ollama_model = String::new();
        assert_eq!(
            route(&think, None),
            Route::Unavailable(Problem::MissingOllamaModel)
        );
        think.ollama_model = "qwen".into();
        let served = endpoint(&think);
        assert_eq!(served.base_url, "http://localhost:11434/v1");
        assert_eq!(served.model, "qwen");
        think.cotyping_think_server_model = " tiny ".into();
        assert_eq!(endpoint(&think).model, "tiny");
        assert_eq!(statistics_model_id(&think), "tiny");
    }

    #[test]
    fn automatic_starts_with_chat_for_hosted_apis() {
        let mut settings = settings();
        for (url, chat) in [
            ("https://api.openai.com/v1", true),
            ("https://openrouter.ai/api/v1", true),
            ("https://api.anthropic.com/v1", true),
            ("https://example.com/v1", false),
        ] {
            settings.cotyping_server_base_url = url.into();
            settings.approved_remote_autocomplete_origins = vec![origin_of(url).unwrap()];
            assert_eq!(endpoint(&settings).starts_with_chat(), chat, "{url}");
        }
        settings.cotyping_server_request_style = CotypingServerRequestStyle::Chat;
        settings.cotyping_server_base_url = "https://example.com/v1".into();
        settings.approved_remote_autocomplete_origins = vec!["https://example.com".into()];
        assert!(endpoint(&settings).starts_with_chat());
        settings.cotyping_server_request_style = CotypingServerRequestStyle::TextCompletion;
        settings.cotyping_server_base_url = "https://api.openai.com/v1".into();
        settings.approved_remote_autocomplete_origins = vec!["https://api.openai.com".into()];
        assert!(!endpoint(&settings).starts_with_chat());
    }

    #[test]
    fn the_key_never_enters_the_identity_or_fingerprint() {
        let settings = settings();
        let keys = Keys {
            think: &|| None,
            server: &|| Some(" secret ".to_string()),
        };
        let Route::Server(keyed) = route(&settings, Some(&keys)) else {
            panic!()
        };
        assert_eq!(keyed.api_key.as_deref(), Some("secret"));
        assert!(!keyed.identity().contains("secret"));
        assert_eq!(keyed.identity(), "https://example.com|/v1|small");
        assert!(!fingerprint(&settings).contains("secret"));
        assert_eq!(route(&settings, None), {
            let mut plain = keyed.clone();
            plain.api_key = None;
            Route::Server(plain)
        });
    }

    fn request(before: &str) -> Request {
        build_request(
            &Field {
                before: before.into(),
                ..Field::default()
            },
            4,
            &Personalization::default(),
            &Extras {
                word_prefix_is_valid_word: true,
                ..Extras::default()
            },
        )
        .unwrap()
    }

    #[test]
    fn the_space_a_chat_model_leaves_out_comes_back() {
        let at_a = request("at a");
        assert_eq!(restoring_word_space("higher level", &at_a), " higher level");
        // The reply restates the word at the caret: the normalizer drops it.
        let word = request("hello wor");
        assert_eq!(restoring_word_space("world", &word), "world");
        // Scripts without spaces, and punctuation, stay.
        assert_eq!(restoring_word_space("世界", &at_a), "世界");
        assert_eq!(restoring_word_space(", then", &at_a), ", then");
        let mut fragment = request("I want to follo");
        fragment.word_prefix_is_valid_word = false;
        assert_eq!(restoring_word_space("w up", &fragment), "w up");
    }

    #[test]
    fn a_healed_reply_must_retype_the_cut_text() {
        let word = request("hello wor");
        let kept = normalize_healed(" world peace", " wor", &word);
        assert_eq!(kept.text, "ld peace");
        let off = normalize_healed(" planet", " wor", &word);
        assert_eq!(off.suppression, Some(Suppression::WordCompletionMismatch));
        let empty = normalize_healed("", " wor", &word);
        assert_eq!(empty.suppression, Some(Suppression::EmptyGeneration));
    }

    #[test]
    fn rejected_raw_routes_are_recognized() {
        let status = |code, detail: &str| -> anyhow::Error {
            AiError::HttpStatus {
                code,
                detail: detail.into(),
                retry_after: None,
            }
            .into()
        };
        assert!(rejects_text_completion(&status(404, "")));
        assert!(rejects_text_completion(&status(501, "")));
        assert!(rejects_text_completion(&status(
            400,
            "This is a chat model"
        )));
        assert!(!rejects_text_completion(&status(400, "bad seed")));
        assert!(!rejects_text_completion(&status(500, "chat")));
    }

    fn chat_reply_json(content: &str, finish: &str) -> serde_json::Value {
        json!({"choices": [{"message": {"content": content}, "finish_reason": finish}]})
    }

    fn local_endpoint(server: &StubServer, style: CotypingServerRequestStyle) -> Endpoint {
        Endpoint {
            base_url: server.url("/v1"),
            model: "tiny".into(),
            api_key: None,
            dialect: Dialect::Generic,
            request_style: style,
            data_policy: OpenRouterDataPolicy::PrivateOnly,
            origin: origin_of(&server.url("/v1")).unwrap(),
        }
    }

    #[test]
    fn a_rate_limit_on_think_pauses_autocomplete_on_the_same_server() {
        let server = StubServer::start(|request| {
            if request.path == "/v1/completions" {
                Reply::Text(404, "no such route".into())
            } else if request.json()["model"] == "think-model" {
                Reply::Json(429, json!({"error": {"message": "slow down"}}))
            } else {
                Reply::Json(200, chat_reply_json("up on it", "stop"))
            }
        });
        let think = crate::think::ThinkClient::openai_compatible(
            &server.url("/v1"),
            "think-model",
            None,
            &[],
        )
        .unwrap();
        let started = Instant::now();
        think
            .stream(&ChatRequest::new("s", "u"), &mut |_| {})
            .unwrap_err();
        let endpoint = local_endpoint(&server, CotypingServerRequestStyle::Automatic);
        let cancel = AtomicBool::new(false);
        let (done, _) = complete(
            &endpoint,
            &request("I wanted to follow"),
            &cancel,
            &ServerMemory::default(),
        )
        .unwrap();
        assert_eq!(done.result.text, " up on it");
        // The origin's two-second pause held autocomplete back too.
        assert!(started.elapsed() >= Duration::from_millis(1800));
    }

    #[test]
    fn automatic_falls_back_to_chat_once_and_remembers() {
        let server = StubServer::start(|request| {
            if request.path == "/v1/completions" {
                Reply::Text(404, "no such route".into())
            } else {
                Reply::Json(200, chat_reply_json("up on it", "stop"))
            }
        });
        let endpoint = local_endpoint(&server, CotypingServerRequestStyle::Automatic);
        let memory = ServerMemory::default();
        let cancel = AtomicBool::new(false);
        let (done, failure) =
            complete(&endpoint, &request("I wanted to follow"), &cancel, &memory).unwrap();
        assert_eq!(done.result.text, " up on it");
        assert_eq!(failure, None);
        let asked = server.requests().len();
        complete(&endpoint, &request("I wanted to follow"), &cancel, &memory).unwrap();
        // Chat from then on, without asking the raw route again.
        assert_eq!(server.requests().len(), asked + 1);
    }

    #[test]
    fn a_failed_request_is_not_replayed_and_is_reported() {
        let server = StubServer::start(|_| Reply::Text(500, "boom".into()));
        let endpoint = local_endpoint(&server, CotypingServerRequestStyle::TextCompletion);
        let memory = ServerMemory::default();
        let cancel = AtomicBool::new(false);
        let err = complete(&endpoint, &request("I wanted to"), &cancel, &memory).unwrap_err();
        assert_eq!(failure_of(&err), Some(Failure::Status(500)));
        assert_eq!(server.requests().len(), 1);
    }

    #[test]
    fn an_empty_reply_is_reported_as_no_text() {
        let server = StubServer::start(|_| Reply::Json(200, chat_reply_json("", "stop")));
        let endpoint = local_endpoint(&server, CotypingServerRequestStyle::Chat);
        let (done, failure) = complete(
            &endpoint,
            &request("I wanted to"),
            &AtomicBool::new(false),
            &ServerMemory::default(),
        )
        .unwrap();
        assert_eq!(done.result.text, "");
        assert_eq!(failure, Some(Failure::EmptyReply));
    }

    #[test]
    fn a_reply_spent_on_reasoning_gets_more_room_once() {
        let server = StubServer::start(|request| {
            if request.json()["max_tokens"].as_u64().unwrap_or(0) < 100 {
                Reply::Json(200, chat_reply_json("", "length"))
            } else {
                Reply::Json(200, chat_reply_json(" soon", "stop"))
            }
        });
        let endpoint = local_endpoint(&server, CotypingServerRequestStyle::Chat);
        let memory = ServerMemory::default();
        let cancel = AtomicBool::new(false);
        let (done, _) = complete(&endpoint, &request("See you"), &cancel, &memory).unwrap();
        assert_eq!(done.result.text, " soon");
        let asked = server.requests().len();
        complete(&endpoint, &request("See you"), &cancel, &memory).unwrap();
        assert_eq!(server.requests().len(), asked + 1);
    }
}
