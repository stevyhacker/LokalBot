//! Claude through Anthropic's Messages API (`Engines/AnthropicEngine.swift`).
//!
//! Think uses it when the OpenAI-compatible server URL names
//! `api.anthropic.com`: Anthropic's OpenAI compatibility layer rejects
//! LokalBot's notes schemas (`maxItems`) and has no prompt caching.
//!
//! Prompt caching: the system prompt and the shared context (a meeting's
//! transcript) carry cache breakpoints and the varying instruction comes
//! last, so the next request over the same material reads the prefix from
//! Anthropic's 5-minute prompt cache instead of paying the full input price.

use std::collections::BTreeSet;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use anyhow::Result;
use serde_json::{Map, Value, json};

use lokalbot_core::settings::ReasoningLevel;

use crate::error::AiError;
use crate::http;
use crate::json as model_json;
use crate::think::{
    ChatRequest, Completion, ReasoningSupport, Usage, ceiling_for_budget, effort_value,
};

pub const HOST: &str = "api.anthropic.com";
const VERSION: &str = "2023-06-01";
/// Gates `fallbacks: "default"`: a safety decline is retried server-side on
/// the model Anthropic recommends for the decline's category.
const SERVER_FALLBACK_BETA: &str = "server-side-fallback-2026-07-01";
const DEFAULT_ANSWER_TOKENS: u32 = 8_192;
/// A whole reply must arrive within the request timeout even at about 25
/// tokens per second.
const MAXIMUM_WHOLE_RESPONSE_TOKENS: u32 = 20_000;
const MAXIMUM_STREAMED_TOKENS: u32 = 64_000;
const TIMEOUT: Duration = Duration::from_secs(900);

/// Whether `url` is Anthropic's API.
pub fn is_anthropic(url: &str) -> bool {
    lokalbot_core::access::origin_of(url)
        .and_then(|origin| origin.split_once("://").map(|(_, host)| host.to_string()))
        .is_some_and(|authority| authority.split(':').next() == Some(HOST))
}

/// `https://api.anthropic.com` and `…/v1` name the same API, so every
/// request is built from the origin.
pub fn versioned_root(base: &str) -> String {
    match lokalbot_core::access::origin_of(base) {
        Some(origin) => format!("{origin}/v1"),
        None => base.trim_end_matches('/').to_string(),
    }
}

/// What LokalBot relies on for one Claude model id, from Anthropic's model
/// documentation (2026-10). Ids it cannot parse (aliases, Claude 3) get no
/// effort control; unknown newer generations are treated like Claude 5.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ModelTraits {
    /// `output_config.effort` values, least first. Empty: send no effort.
    pub effort_levels: Vec<ReasoningLevel>,
    pub default_effort: Option<ReasoningLevel>,
    /// Leaving `thinking` unset runs adaptive thinking, whose tokens count
    /// toward `max_tokens`.
    pub thinks_by_default: bool,
    /// Accepts `fallbacks: "default"`.
    pub server_fallback: bool,
    pub context_tokens: Option<u32>,
}

impl ModelTraits {
    const FAMILIES: [&'static str; 5] = ["opus", "sonnet", "haiku", "fable", "mythos"];
    const SERVER_FALLBACK_MODELS: [&'static str; 4] = [
        "claude-fable-5-1",
        "claude-opus-5-5",
        "claude-opus-5",
        "claude-sonnet-5-5",
    ];

    pub fn new(model: &str) -> Self {
        use ReasoningLevel::*;
        let name = model.trim().to_lowercase();
        let parts: Vec<&str> = name.split('-').collect();
        let family = parts.get(1).copied().unwrap_or_default();
        let major = parts.get(2).and_then(|p| p.parse::<u32>().ok());
        let (Some(major), true, true) = (
            major,
            parts.first() == Some(&"claude"),
            Self::FAMILIES.contains(&family),
        ) else {
            return Self {
                effort_levels: Vec::new(),
                default_effort: None,
                thinks_by_default: false,
                server_fallback: false,
                context_tokens: None,
            };
        };
        // A dated snapshot ("claude-sonnet-4-20250514") has no minor version.
        let minor = parts
            .get(3)
            .filter(|p| p.len() <= 2)
            .and_then(|p| p.parse::<u32>().ok())
            .unwrap_or(0);
        let current = family == "fable" || family == "mythos" || major >= 5;
        let effort_levels = if current || (major == 4 && minor >= 7) {
            vec![Low, Medium, High, Xhigh, Max]
        } else if major == 4 && minor == 6 {
            vec![Low, Medium, High, Max]
        } else if major == 4 && minor == 5 && family == "opus" {
            vec![Low, Medium, High]
        } else {
            Vec::new()
        };
        // Claude Opus 5.5 and Claude Haiku 5.5 default to medium effort.
        let medium_default = major == 5 && minor == 5 && (family == "opus" || family == "haiku");
        let default_effort =
            (!effort_levels.is_empty()).then_some(if medium_default { Medium } else { High });
        Self {
            effort_levels,
            default_effort,
            thinks_by_default: current,
            server_fallback: Self::SERVER_FALLBACK_MODELS.contains(&name.as_str()),
            context_tokens: Some(if current || (major == 4 && minor >= 6) {
                1_000_000
            } else {
                200_000
            }),
        }
    }

    pub(crate) fn reasoning_support(&self) -> ReasoningSupport {
        ReasoningSupport::new(&self.effort_levels, self.default_effort)
    }

    /// The effort for one request. A chosen level is capped by the task's
    /// budget, as on other servers. On Automatic, a model that thinks by
    /// default gets the level its task budget implies, so notes and digests
    /// (budget 0) run at the lowest effort instead of spending their output
    /// allowance on thinking.
    pub(crate) fn effort(
        &self,
        level: ReasoningLevel,
        task_budget: Option<u32>,
    ) -> Option<ReasoningLevel> {
        let support = self.reasoning_support();
        if let Some(level) = support.request_level(level, task_budget) {
            return Some(level);
        }
        let budget = task_budget.filter(|_| self.thinks_by_default)?;
        support.clamp(ceiling_for_budget(budget))
    }

    /// Thinking shares `max_tokens` with the answer, so a model that thinks
    /// by default gets room for both.
    fn max_tokens(
        &self,
        requested: Option<u32>,
        effort: Option<ReasoningLevel>,
        stream: bool,
    ) -> u32 {
        let answer = requested.unwrap_or(DEFAULT_ANSWER_TOKENS).max(1);
        let thinking = if self.thinks_by_default {
            match effort.or(self.default_effort) {
                Some(ReasoningLevel::Low) => 4_096,
                Some(ReasoningLevel::Medium) => 8_192,
                _ => 16_384,
            }
        } else {
            0
        };
        (answer + thinking).min(if stream {
            MAXIMUM_STREAMED_TOKENS
        } else {
            MAXIMUM_WHOLE_RESPONSE_TOKENS
        })
    }
}

/// Anthropic's structured outputs accept a JSON Schema subset. Like the
/// official SDKs, each unsupported constraint moves into the field's
/// description, where the model still reads it, instead of failing the
/// request with a 400. LokalBot's parsers keep enforcing the real limits.
pub fn adapt_schema(schema: &Value) -> Value {
    const FORMATS: [&str; 10] = [
        "date-time",
        "time",
        "date",
        "duration",
        "email",
        "hostname",
        "uri",
        "ipv4",
        "ipv6",
        "uuid",
    ];
    const UNSUPPORTED: [&str; 11] = [
        "minimum",
        "maximum",
        "exclusiveMinimum",
        "exclusiveMaximum",
        "multipleOf",
        "minLength",
        "maxLength",
        "maxItems",
        "uniqueItems",
        "minProperties",
        "maxProperties",
    ];
    let Value::Object(object) = schema else {
        return schema.clone();
    };
    let mut node = Map::new();
    let mut notes: Vec<String> = Vec::new();
    for (key, value) in object {
        match key.as_str() {
            "properties" | "$defs" | "definitions" => {
                node.insert(
                    key.clone(),
                    match value {
                        Value::Object(map) => Value::Object(
                            map.iter()
                                .map(|(name, child)| (name.clone(), adapt_schema(child)))
                                .collect(),
                        ),
                        other => other.clone(),
                    },
                );
            }
            "items" => {
                node.insert(key.clone(), adapt_schema(value));
            }
            "anyOf" | "allOf" | "oneOf" => {
                node.insert(
                    key.clone(),
                    match value {
                        Value::Array(items) => {
                            Value::Array(items.iter().map(adapt_schema).collect())
                        }
                        other => other.clone(),
                    },
                );
            }
            "minItems" => match value.as_u64() {
                Some(count) if count > 1 => {
                    node.insert(key.clone(), json!(1));
                    notes.push(format!("minItems: {count}"));
                }
                _ => {
                    node.insert(key.clone(), value.clone());
                }
            },
            "format" => match value.as_str() {
                Some(format) if !FORMATS.contains(&format) => {
                    notes.push(format!("format: {format}"));
                }
                _ => {
                    node.insert(key.clone(), value.clone());
                }
            },
            "additionalProperties" => {
                node.insert(key.clone(), json!(false));
            }
            _ if UNSUPPORTED.contains(&key.as_str()) => {
                notes.push(format!("{key}: {}", note_value(value)));
            }
            _ => {
                node.insert(key.clone(), value.clone());
            }
        }
    }
    let is_object = match node.get("type") {
        Some(Value::String(kind)) => kind == "object",
        Some(Value::Array(kinds)) => kinds.iter().any(|k| k == "object"),
        _ => false,
    };
    if is_object {
        node.insert("additionalProperties".into(), json!(false));
    }
    if !notes.is_empty() {
        notes.sort();
        let note = format!("{{{}}}", notes.join(", "));
        let description = match node.get("description").and_then(Value::as_str) {
            Some(existing) => format!("{existing} {note}"),
            None => note,
        };
        node.insert("description".into(), json!(description));
    }
    Value::Object(node)
}

fn note_value(value: &Value) -> String {
    match value {
        Value::String(text) => text.clone(),
        other => other.to_string(),
    }
}

/// Request fields a model may reject. A 400 naming one retries once without
/// it; generation never started.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
enum OptionalField {
    Effort,
    Fallbacks,
}

/// One Claude model on Anthropic's API.
#[derive(Clone, Debug)]
pub(crate) struct Engine {
    pub base: String,
    pub model: String,
    pub api_key: Option<String>,
    pub level: ReasoningLevel,
}

impl Engine {
    pub fn traits(&self) -> ModelTraits {
        ModelTraits::new(&self.model)
    }

    fn effort(&self, request: &ChatRequest) -> Option<ReasoningLevel> {
        self.traits().effort(self.level, request.reasoning_budget)
    }

    fn optional_fields(&self, request: &ChatRequest) -> BTreeSet<OptionalField> {
        let mut fields = BTreeSet::new();
        if self.effort(request).is_some() {
            fields.insert(OptionalField::Effort);
        }
        if self.traits().server_fallback {
            fields.insert(OptionalField::Fallbacks);
        }
        fields
    }

    /// Request headers. The key goes only to Anthropic's API.
    fn headers(&self, fallbacks: bool) -> Vec<(&'static str, String)> {
        let mut headers = vec![("anthropic-version", VERSION.to_string())];
        if let Some(key) = self.api_key.as_deref().filter(|k| !k.trim().is_empty()) {
            headers.push(("x-api-key", key.trim().to_string()));
        }
        if fallbacks {
            headers.push(("anthropic-beta", SERVER_FALLBACK_BETA.to_string()));
        }
        headers
    }

    /// Pure request construction, covered offline without credentials.
    /// Temperature is never sent: current Claude models reject non-default
    /// sampling. Keys are sorted so the schema's bytes, and with them the
    /// compiled grammar and the cached prefix, stay stable.
    fn body(
        &self,
        request: &ChatRequest,
        stream: bool,
        omitted: &BTreeSet<OptionalField>,
    ) -> Result<(Value, bool)> {
        if self.model.trim().is_empty() {
            return Err(AiError::NoModel.into());
        }
        let traits = self.traits();
        let effort = if omitted.contains(&OptionalField::Effort) {
            None
        } else {
            self.effort(request)
        };
        let mut body = json!({
            "model": self.model.trim(),
            "max_tokens": traits.max_tokens(request.max_tokens, effort, stream),
            "messages": [{"role": "user", "content": user_content(request)}],
        });
        if !request.system.is_empty() {
            body["system"] = json!([{
                "type": "text",
                "text": request.system,
                "cache_control": {"type": "ephemeral"},
            }]);
        }
        let mut output = Map::new();
        if let Some(schema) = &request.json_schema {
            output.insert(
                "format".into(),
                json!({"type": "json_schema", "schema": adapt_schema(schema)}),
            );
        }
        if let Some(effort) = effort {
            output.insert("effort".into(), json!(effort_value(effort)));
        }
        if !output.is_empty() {
            body["output_config"] = Value::Object(output);
        }
        let fallbacks = traits.server_fallback && !omitted.contains(&OptionalField::Fallbacks);
        if fallbacks {
            body["fallbacks"] = json!("default");
        }
        if stream {
            body["stream"] = json!(true);
        }
        Ok((model_json::sort_keys(body), fallbacks))
    }

    fn url(&self) -> String {
        format!("{}/messages", versioned_root(&self.base))
    }

    /// One whole reply; transient failures get one replay, and a 400 naming
    /// an optional field one retry without it.
    pub fn complete(&self, request: &ChatRequest) -> Result<Completion> {
        let attempt = |omitted: &BTreeSet<OptionalField>| -> Result<Completion> {
            let (body, fallbacks) = self.body(request, false, omitted)?;
            let headers = self.headers(fallbacks);
            crate::think::with_retry(|| {
                let agent = http::agent(&self.base, TIMEOUT);
                let reply = http::post_json_with(&agent, &self.url(), &headers, &body)?;
                if !reply.ok() {
                    return Err(reply.status_error().into());
                }
                let completion = parse_message(&reply.json()?)?;
                if let Some(usage) = &completion.usage {
                    log_cache(&self.model, usage);
                }
                Ok(completion)
            })
        };
        match attempt(&BTreeSet::new()) {
            Err(err) => {
                let rejected = rejected_fields(&err, &self.optional_fields(request));
                if rejected.is_empty() {
                    return Err(err);
                }
                log::info!("anthropic retry without={rejected:?} model={}", self.model);
                attempt(&rejected)
            }
            ok => ok,
        }
    }

    /// Streams answer text. A 400 naming an optional field retries once
    /// without it; streams are otherwise never replayed.
    pub fn stream(
        &self,
        request: &ChatRequest,
        cancel: Option<&AtomicBool>,
        on_delta: &mut dyn FnMut(&str),
    ) -> Result<Completion> {
        match self.stream_once(request, &BTreeSet::new(), cancel, on_delta) {
            Err(err) => {
                let rejected = rejected_fields(&err, &self.optional_fields(request));
                if rejected.is_empty() {
                    return Err(err);
                }
                log::info!(
                    "anthropic stream retry without={rejected:?} model={}",
                    self.model
                );
                self.stream_once(request, &rejected, cancel, on_delta)
            }
            ok => ok,
        }
    }

    fn stream_once(
        &self,
        request: &ChatRequest,
        omitted: &BTreeSet<OptionalField>,
        cancel: Option<&AtomicBool>,
        on_delta: &mut dyn FnMut(&str),
    ) -> Result<Completion> {
        let (body, fallbacks) = self.body(request, true, omitted)?;
        let agent = http::agent(&self.base, TIMEOUT);
        let mut stream =
            http::post_stream_with(&agent, &self.url(), &self.headers(fallbacks), &body)?;
        if let Some(error) = stream.error.take() {
            return Err(error.status_error().into());
        }
        let mut content = String::new();
        let mut usage = CacheUsage::default();
        let mut stop_reason: Option<String> = None;
        let mut terminal = false;
        while let Some(line) = stream.next_line(&self.base)? {
            if cancel.is_some_and(|c| c.load(Ordering::Relaxed)) {
                return Ok(Completion {
                    text: model_json::strip_reasoning(&content),
                    truncated: false,
                    cancelled: true,
                    usage: None,
                });
            }
            match parse_stream_line(&line) {
                Some(StreamEvent::Text(text)) => {
                    content.push_str(&text);
                    on_delta(&text);
                }
                Some(StreamEvent::Usage(counts)) => usage.merge(&counts),
                Some(StreamEvent::Stop {
                    reason,
                    details,
                    usage: counts,
                }) => {
                    usage.merge(&counts);
                    if reason.as_deref() == Some("refusal") {
                        return Err(refusal(&details).into());
                    }
                    stop_reason = reason;
                }
                Some(StreamEvent::Done) => {
                    terminal = true;
                    break;
                }
                Some(StreamEvent::Failure(message)) => {
                    return Err(AiError::BadResponse(message).into());
                }
                None => {}
            }
        }
        if !terminal {
            return Err(
                AiError::BadResponse("Claude's stream ended before completion".into()).into(),
            );
        }
        log_cache(&self.model, &usage.usage());
        let truncated = matches!(
            stop_reason.as_deref(),
            Some("max_tokens" | "model_context_window_exceeded")
        );
        Ok(Completion {
            text: if truncated {
                model_json::visible_text_of_truncated(&content)
            } else {
                model_json::strip_reasoning(&content)
            },
            truncated,
            cancelled: false,
            usage: Some(usage.usage()),
        })
    }

    /// `max_input_tokens` of the selected model from Anthropic's model list,
    /// else the documented window. Carries the key and no content.
    pub fn discover_context(&self) -> Option<u32> {
        let agent = http::agent(&self.base, Duration::from_secs(5));
        let url = format!(
            "{}/models/{}",
            versioned_root(&self.base),
            http::form_escaped(self.model.trim())
        );
        http::get_with(&agent, &url, &self.headers(false))
            .ok()
            .filter(|reply| reply.ok())
            .and_then(|reply| reply.json().ok())
            .and_then(|json| json.get("max_input_tokens").and_then(Value::as_u64))
            .filter(|tokens| *tokens > 0)
            .map(|tokens| tokens.min(u64::from(u32::MAX)) as u32)
            .or(self.traits().context_tokens)
    }
}

/// Shared material first with a breakpoint after it, the varying instruction
/// last. Blank blocks are dropped; the API rejects them.
fn user_content(request: &ChatRequest) -> Vec<Value> {
    let mut blocks: Vec<Value> = request
        .context
        .iter()
        .filter(|text| !text.trim().is_empty())
        .map(|text| json!({"type": "text", "text": text}))
        .collect();
    if let Some(last) = blocks.last_mut() {
        last["cache_control"] = json!({"type": "ephemeral"});
    }
    if blocks.is_empty() || !request.user.trim().is_empty() {
        blocks.push(json!({"type": "text", "text": request.user}));
    }
    blocks
}

/// The optional fields a 400 names, limited to those the request sent.
fn rejected_fields(err: &anyhow::Error, sent: &BTreeSet<OptionalField>) -> BTreeSet<OptionalField> {
    let Some(AiError::HttpStatus {
        code: 400, detail, ..
    }) = err.downcast_ref::<AiError>()
    else {
        return BTreeSet::new();
    };
    let detail = detail.to_lowercase();
    let mut rejected = BTreeSet::new();
    if detail.contains("effort") {
        rejected.insert(OptionalField::Effort);
    }
    if detail.contains("fallback") {
        rejected.insert(OptionalField::Fallbacks);
    }
    rejected.intersection(sent).copied().collect()
}

#[derive(Clone, Debug, Default, PartialEq)]
struct CacheUsage {
    input: u64,
    cache_write: u64,
    cache_read: u64,
    output: Option<u64>,
}

impl CacheUsage {
    /// A streamed `message_delta` carries only the counts that changed.
    fn merge(&mut self, json: &Value) {
        let read = |key: &str| json.get(key).and_then(Value::as_u64);
        if let Some(value) = read("input_tokens") {
            self.input = value;
        }
        if let Some(value) = read("cache_creation_input_tokens") {
            self.cache_write = value;
        }
        if let Some(value) = read("cache_read_input_tokens") {
            self.cache_read = value;
        }
        if let Some(value) = read("output_tokens") {
            self.output = Some(value);
        }
    }

    /// The whole prompt, cached or not, as other engines report it.
    fn usage(&self) -> Usage {
        Usage {
            prompt_tokens: Some(self.input + self.cache_write + self.cache_read),
            completion_tokens: self.output,
        }
    }
}

fn log_cache(model: &str, usage: &Usage) {
    log::info!(
        "anthropic reply model={model} prompt_tokens={:?} output_tokens={:?}",
        usage.prompt_tokens,
        usage.completion_tokens
    );
}

fn refusal(details: &Value) -> AiError {
    let mut detail = String::from("Claude declined this request");
    if let Some(category) = details.get("category").and_then(Value::as_str) {
        detail.push_str(&format!(" ({category})"));
    }
    if let Some(explanation) = details
        .get("explanation")
        .and_then(Value::as_str)
        .filter(|e| !e.is_empty())
    {
        detail.push_str(&format!(
            ": {}",
            explanation.chars().take(600).collect::<String>()
        ));
    }
    AiError::BadResponse(format!("model refusal: {detail}"))
}

/// Text blocks joined in order; thinking and fallback marker blocks are not
/// part of the answer. A server-side fallback's text continues the declined
/// partial, so joining keeps the whole reply.
pub(crate) fn parse_message(json: &Value) -> Result<Completion> {
    let content = json
        .get("content")
        .and_then(Value::as_array)
        .ok_or_else(|| AiError::BadResponse("unexpected /v1/messages payload".into()))?;
    let stop_reason = json.get("stop_reason").and_then(Value::as_str);
    if stop_reason == Some("refusal") {
        return Err(refusal(json.get("stop_details").unwrap_or(&Value::Null)).into());
    }
    let text: String = content
        .iter()
        .filter(|block| block.get("type").and_then(Value::as_str) == Some("text"))
        .filter_map(|block| block.get("text").and_then(Value::as_str))
        .collect();
    let truncated = matches!(
        stop_reason,
        Some("max_tokens" | "model_context_window_exceeded")
    );
    if !truncated && text.is_empty() {
        return Err(AiError::BadResponse("Claude returned no text".into()).into());
    }
    let usage = json.get("usage").map(|counts| {
        let mut usage = CacheUsage::default();
        usage.merge(counts);
        usage.usage()
    });
    Ok(Completion {
        text: if truncated {
            model_json::visible_text_of_truncated(&text)
        } else {
            model_json::strip_reasoning(&text)
        },
        truncated,
        cancelled: false,
        usage,
    })
}

#[derive(Clone, Debug, PartialEq)]
pub(crate) enum StreamEvent {
    Text(String),
    Usage(Value),
    /// The final counts arrive with the stop reason.
    Stop {
        reason: Option<String>,
        details: Value,
        usage: Value,
    },
    Done,
    Failure(String),
}

/// One line of a Messages stream. `event:` lines repeat the payload's `type`
/// and are skipped, as are pings and block boundaries.
pub(crate) fn parse_stream_line(line: &str) -> Option<StreamEvent> {
    let payload = line.strip_prefix("data:")?.trim();
    let event: Value = serde_json::from_str(payload).ok()?;
    match event.get("type").and_then(Value::as_str)? {
        "message_start" => event
            .pointer("/message/usage")
            .map(|usage| StreamEvent::Usage(usage.clone())),
        "content_block_delta" => {
            let delta = event.get("delta")?;
            (delta.get("type").and_then(Value::as_str) == Some("text_delta"))
                .then(|| delta.get("text").and_then(Value::as_str))
                .flatten()
                .map(|text| StreamEvent::Text(text.to_string()))
        }
        "message_delta" => {
            let delta = event.get("delta");
            Some(StreamEvent::Stop {
                reason: delta
                    .and_then(|d| d.get("stop_reason"))
                    .and_then(Value::as_str)
                    .map(str::to_string),
                details: delta
                    .and_then(|d| d.get("stop_details"))
                    .cloned()
                    .unwrap_or(Value::Null),
                usage: event.get("usage").cloned().unwrap_or(Value::Null),
            })
        }
        "message_stop" => Some(StreamEvent::Done),
        "error" => Some(StreamEvent::Failure(
            event
                .pointer("/error/message")
                .and_then(Value::as_str)
                .unwrap_or("stream reported an error")
                .chars()
                .take(600)
                .collect(),
        )),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ThinkClient;
    use crate::http::testing::{Reply, StubServer};

    fn engine(base: &str, model: &str, level: ReasoningLevel) -> Engine {
        Engine {
            base: base.into(),
            model: model.into(),
            api_key: Some("sk-ant-test".into()),
            level,
        }
    }

    fn message(text: &str, stop: &str) -> Reply {
        Reply::Json(
            200,
            json!({
                "content": [
                    {"type": "thinking", "thinking": "hidden"},
                    {"type": "text", "text": text},
                ],
                "stop_reason": stop,
                "usage": {"input_tokens": 5, "cache_creation_input_tokens": 100, "cache_read_input_tokens": 900, "output_tokens": 7},
            }),
        )
    }

    #[test]
    fn host_selects_the_messages_api_and_the_versioned_root() {
        assert!(is_anthropic("https://api.anthropic.com"));
        assert!(is_anthropic("https://API.anthropic.com/v1/"));
        assert!(!is_anthropic("https://openrouter.ai/api/v1"));
        assert_eq!(
            versioned_root("https://api.anthropic.com"),
            "https://api.anthropic.com/v1"
        );
        assert_eq!(
            versioned_root("https://api.anthropic.com/v1/"),
            "https://api.anthropic.com/v1"
        );
        let client = ThinkClient::openai_compatible(
            "https://api.anthropic.com/v1",
            "claude-sonnet-5-5",
            Some("key".into()),
            &["https://api.anthropic.com".into()],
        )
        .unwrap();
        assert_eq!(
            client.display_name(),
            "claude-sonnet-5-5 · api.anthropic.com"
        );
        assert_eq!(client.structured_output_enum_limit(), Some(500));
        assert!(client.checkpoint_identity().starts_with("anthropic|"));
    }

    #[test]
    fn model_traits_follow_anthropics_documentation() {
        use ReasoningLevel::*;
        let opus = ModelTraits::new("claude-opus-5-5");
        assert_eq!(opus.effort_levels, vec![Low, Medium, High, Xhigh, Max]);
        assert_eq!(opus.default_effort, Some(Medium));
        assert!(opus.thinks_by_default && opus.server_fallback);
        assert_eq!(opus.context_tokens, Some(1_000_000));
        let sonnet46 = ModelTraits::new("claude-sonnet-4-6");
        assert_eq!(sonnet46.effort_levels, vec![Low, Medium, High, Max]);
        assert!(!sonnet46.thinks_by_default);
        let dated = ModelTraits::new("claude-sonnet-4-20250514");
        assert!(dated.effort_levels.is_empty());
        assert_eq!(dated.context_tokens, Some(200_000));
        assert_eq!(
            ModelTraits::new("claude-opus-4-5").effort_levels,
            vec![Low, Medium, High]
        );
        assert_eq!(
            ModelTraits::new("sonnet"),
            ModelTraits::new("claude-3-haiku")
        );
        assert!(ModelTraits::new("claude-fable-5-1").server_fallback);
        // Automatic: a thinking model runs no-reasoning tasks at the lowest
        // effort; a chosen level is capped by the task's budget.
        assert_eq!(opus.effort(Automatic, Some(0)), Some(Low));
        assert_eq!(opus.effort(Automatic, None), None);
        assert_eq!(opus.effort(Max, Some(4_096)), Some(Medium));
        assert_eq!(opus.effort(Xhigh, None), Some(Xhigh));
        assert_eq!(sonnet46.effort(Automatic, Some(0)), None);
        assert_eq!(sonnet46.effort(Xhigh, None), Some(High));
    }

    #[test]
    fn schemas_move_unsupported_limits_into_descriptions() {
        let adapted = adapt_schema(&json!({
            "type": "object",
            "additionalProperties": true,
            "properties": {
                "items": {"type": "array", "minItems": 3, "maxItems": 8, "items": {"type": "string", "maxLength": 200, "format": "uri"}},
                "count": {"type": "integer", "minimum": 0, "description": "How many"},
                "when": {"type": "string", "format": "x-custom"},
            },
            "required": ["items"],
        }));
        assert_eq!(adapted["additionalProperties"], false);
        let items = &adapted["properties"]["items"];
        assert_eq!(items["minItems"], 1);
        assert!(items.get("maxItems").is_none());
        assert_eq!(items["description"], "{maxItems: 8, minItems: 3}");
        assert_eq!(items["items"]["format"], "uri");
        assert_eq!(items["items"]["description"], "{maxLength: 200}");
        assert_eq!(
            adapted["properties"]["count"]["description"],
            "How many {minimum: 0}"
        );
        assert_eq!(
            adapted["properties"]["when"]["description"],
            "{format: x-custom}"
        );
        assert!(adapted["properties"]["when"].get("format").is_none());
    }

    #[test]
    fn requests_cache_the_system_prompt_and_context_and_skip_sampling() {
        let server = StubServer::start(|_| message("{\"ok\": true}", "end_turn"));
        let engine = engine(
            &server.url(""),
            "claude-opus-5-5",
            ReasoningLevel::Automatic,
        );
        let request = ChatRequest::new("You write notes.", "Write the notes.")
            .context(vec!["Transcript part".into(), "  ".into()])
            .max_tokens(2_000)
            .temperature(0.0)
            .reasoning_budget(0)
            .json_schema(json!({"type": "object", "properties": {"ok": {"type": "boolean"}}, "required": ["ok"]}));
        let completion = engine.complete(&request).unwrap();
        assert_eq!(completion.text, "{\"ok\": true}");
        assert_eq!(completion.usage.unwrap().prompt_tokens, Some(1_005));
        let sent = server.requests().pop().unwrap();
        assert_eq!(sent.path, "/v1/messages");
        assert_eq!(sent.header("x-api-key").as_deref(), Some("sk-ant-test"));
        assert_eq!(
            sent.header("anthropic-version").as_deref(),
            Some("2023-06-01")
        );
        assert_eq!(
            sent.header("anthropic-beta").as_deref(),
            Some("server-side-fallback-2026-07-01")
        );
        assert!(
            sent.header("authorization").is_none(),
            "the key is never a bearer"
        );
        let body = sent.json();
        assert_eq!(body["system"][0]["cache_control"]["type"], "ephemeral");
        let content = body["messages"][0]["content"].as_array().unwrap();
        assert_eq!(content.len(), 2, "blank context is dropped");
        assert_eq!(content[0]["text"], "Transcript part");
        assert_eq!(content[0]["cache_control"]["type"], "ephemeral");
        assert_eq!(content[1]["text"], "Write the notes.");
        assert!(content[1].get("cache_control").is_none());
        assert_eq!(body["output_config"]["format"]["type"], "json_schema");
        assert_eq!(
            body["output_config"]["format"]["schema"]["additionalProperties"],
            false
        );
        assert_eq!(body["output_config"]["effort"], "low");
        assert_eq!(body["fallbacks"], "default");
        // Room for adaptive thinking beside the answer.
        assert_eq!(body["max_tokens"], 2_000 + 4_096);
        assert!(body.get("temperature").is_none());
        assert!(body.get("stream").is_none());
        let raw = String::from_utf8(sent.body).unwrap();
        assert!(raw.find("\"max_tokens\"").unwrap() < raw.find("\"messages\"").unwrap());
    }

    #[test]
    fn a_rejected_optional_field_is_retried_once_without_it() {
        let server = StubServer::start(|request| {
            if request.json().pointer("/output_config/effort").is_some() {
                Reply::Json(
                    400,
                    json!({"type": "error", "error": {"type": "invalid_request_error", "message": "output_config.effort: Extra inputs are not permitted"}}),
                )
            } else {
                message("Done", "end_turn")
            }
        });
        let engine = engine(&server.url(""), "claude-sonnet-4-6", ReasoningLevel::High);
        assert_eq!(
            engine.complete(&ChatRequest::new("s", "u")).unwrap().text,
            "Done"
        );
        let requests = server.requests();
        assert_eq!(requests.len(), 2);
        assert!(requests[1].json().get("output_config").is_none());
    }

    #[test]
    fn refusals_and_truncation_are_reported() {
        let refused = parse_message(&json!({
            "content": [{"type": "text", "text": "partial"}],
            "stop_reason": "refusal",
            "stop_details": {"category": "cyber", "explanation": "Not allowed."},
        }))
        .unwrap_err();
        assert_eq!(
            refused.to_string(),
            "LLM server error: model refusal: Claude declined this request (cyber): Not allowed."
        );
        let cut = parse_message(
            &json!({"content": [{"type": "text", "text": "par"}], "stop_reason": "max_tokens"}),
        )
        .unwrap();
        assert!(cut.truncated);
        assert!(parse_message(&json!({"content": [], "stop_reason": "end_turn"})).is_err());
        assert!(parse_message(&json!({"error": "x"})).is_err());
    }

    #[test]
    fn streams_text_deltas_from_messages_events() {
        let events = [
            (
                "message_start",
                json!({"type": "message_start", "message": {"usage": {"input_tokens": 3, "cache_read_input_tokens": 50}}}),
            ),
            (
                "content_block_start",
                json!({"type": "content_block_start", "index": 0, "content_block": {"type": "thinking"}}),
            ),
            (
                "content_block_delta",
                json!({"type": "content_block_delta", "index": 0, "delta": {"type": "thinking_delta", "thinking": "hm"}}),
            ),
            ("ping", json!({"type": "ping"})),
            (
                "content_block_delta",
                json!({"type": "content_block_delta", "index": 1, "delta": {"type": "text_delta", "text": "Hel"}}),
            ),
            (
                "content_block_delta",
                json!({"type": "content_block_delta", "index": 1, "delta": {"type": "text_delta", "text": "lo"}}),
            ),
            (
                "message_delta",
                json!({"type": "message_delta", "delta": {"stop_reason": "end_turn"}, "usage": {"output_tokens": 2}}),
            ),
            ("message_stop", json!({"type": "message_stop"})),
        ];
        let body: String = events
            .iter()
            .map(|(name, data)| format!("event: {name}\ndata: {data}\n\n"))
            .collect();
        let server = StubServer::start(move |_| Reply::RawSse(body.clone()));
        let engine = engine(
            &server.url("/v1"),
            "claude-opus-5-5",
            ReasoningLevel::Automatic,
        );
        let mut deltas = Vec::new();
        let completion = engine
            .stream(
                &ChatRequest::new("s", "u").max_tokens(100),
                None,
                &mut |d| deltas.push(d.to_string()),
            )
            .unwrap();
        assert_eq!(deltas, vec!["Hel", "lo"]);
        assert_eq!(completion.text, "Hello");
        assert_eq!(completion.usage.unwrap().completion_tokens, Some(2));
        let body = server.requests().pop().unwrap().json();
        assert_eq!(body["stream"], true);
        assert_eq!(body["max_tokens"], 100 + 8_192);

        let cut = StubServer::start(|_| {
            Reply::Sse(vec![
                json!({"type": "content_block_delta", "delta": {"type": "text_delta", "text": "x"}}).to_string(),
            ])
        });
        let err = engine_for(&cut)
            .stream(&ChatRequest::new("s", "u"), None, &mut |_| {})
            .unwrap_err();
        assert!(err.to_string().contains("ended before completion"));
        let refused = StubServer::start(|_| {
            Reply::Sse(vec![
                json!({"type": "message_delta", "delta": {"stop_reason": "refusal", "stop_details": {"category": "bio"}}}).to_string(),
                json!({"type": "message_stop"}).to_string(),
            ])
        });
        assert!(
            engine_for(&refused)
                .stream(&ChatRequest::new("s", "u"), None, &mut |_| {})
                .unwrap_err()
                .to_string()
                .contains("(bio)")
        );
    }

    fn engine_for(server: &StubServer) -> Engine {
        engine(
            &server.url(""),
            "claude-haiku-4-5",
            ReasoningLevel::Automatic,
        )
    }

    #[test]
    fn the_context_window_comes_from_the_model_entry() {
        let server = StubServer::start(|request| {
            if request.path == "/v1/models/claude-sonnet-5-5" {
                Reply::Json(
                    200,
                    json!({"id": "claude-sonnet-5-5", "max_input_tokens": 600_000}),
                )
            } else {
                Reply::Text(404, String::new())
            }
        });
        assert_eq!(
            engine(
                &server.url(""),
                "claude-sonnet-5-5",
                ReasoningLevel::Automatic
            )
            .discover_context(),
            Some(600_000)
        );
        let sent = server.requests().pop().unwrap();
        assert_eq!(sent.header("x-api-key").as_deref(), Some("sk-ant-test"));
        assert!(sent.body.is_empty(), "no content");
        // Unknown on the server: the documented window.
        assert_eq!(
            engine(
                &server.url(""),
                "claude-opus-4-5",
                ReasoningLevel::Automatic
            )
            .discover_context(),
            Some(200_000)
        );
    }
}
