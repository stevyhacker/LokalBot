//! The Autocomplete model on its llama-server (`LocalLlamaCotypingEngine`
//! and `LlamaCotypingRuntime`, over HTTP).
//!
//! One `/completion` request per suggestion, with the raw prompt (no chat
//! template) and `cache_prompt`, so the server reuses what it read of the
//! previous prompt and only reads the newly typed tokens (macOS's
//! `IncrementalPrefill`). The response is streamed and read token by token,
//! with each token's probabilities (`n_probs`), to apply what the in-process
//! macOS decode loop applies:
//!
//! - token healing: a grammar re-types the text cut from the prompt
//!   ([`healing`](super::healing)), and only what follows is shown. When
//!   the grammar's token-by-token path through a word fragment ("to", then
//!   "mo", then "r…") is less likely than one token that spells the whole
//!   fragment ("tomorrow"), the request is restarted from that token: the
//!   case macOS's prefix search exists for;
//! - the first-word confidence gate and its one-word fallback;
//! - stop when the most likely next token ends the text, even if the
//!   sampler picked another;
//! - stop at a sentence end or a control token (`CotypingDecodeStopPolicy`),
//!   and once a line is complete unless multi-line suggestions are on. A
//!   reply that starts on a new line is kept: the normalizer joins it with a
//!   space, as the in-process runtime's output is.
//!
//! Stopping drops the connection, which llama-server notices at its next
//! token. A request still reading its prompt finishes that first, so the
//! caller keeps one request in flight at a time.

use std::time::{Duration, Instant};

use anyhow::{Result, anyhow};
use serde_json::{Value, json};

use super::confidence::{self, ConfidenceDecision};
use super::healing;
use super::normalize::{self, Normalized, Suppression};
use super::prompt::Request;
use super::stop;
use crate::error::AiError;
use crate::http;

/// Probabilities asked for per token. The gate sums boundary mass over
/// these; healing a word fragment looks among them for a token that spells
/// the whole fragment.
const GATED_PROBABILITIES: u32 = 20;
const FRAGMENT_PROBABILITIES: u32 = 40;
/// A space before the first word is one constrained token more; a word
/// fragment can take a few (`CotypingEngine.completionRequest`).
const HEALED_SPACE_TOKENS: usize = 1;
const HEALED_FRAGMENT_TOKENS: usize = 4;
/// Inline suggestions must feel instant (`completionSession`).
const REQUEST_TIMEOUT: Duration = Duration::from_secs(15);

/// The request was superseded; nothing to show.
#[derive(Debug, thiserror::Error)]
#[error("superseded")]
pub struct Cancelled;

/// What one request produced, with the server's timings for diagnostics.
#[derive(Clone, Debug, PartialEq)]
pub struct Completion {
    pub result: Normalized,
    /// The text after the healed prefix, before normalization.
    pub raw: String,
    /// The token budget ran out (the thought may go on).
    pub hit_limit: bool,
    pub timings: Timings,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Timings {
    /// Milliseconds from the request to the first streamed token.
    pub first_token_ms: Option<f64>,
    pub total_ms: f64,
    /// Prompt tokens the server read for this request (not reused).
    pub prompt_tokens: Option<u64>,
    /// Prompt tokens reused from the previous request.
    pub cached_tokens: Option<u64>,
    pub prompt_ms: Option<f64>,
    pub predicted_tokens: Option<u64>,
}

/// A client for the Autocomplete role's llama-server.
#[derive(Clone)]
pub struct Completer {
    agent: ureq::Agent,
    root_url: String,
    token: String,
}

impl Completer {
    /// `root_url` is `http://127.0.0.1:<port>` (`Lease::root_url`).
    pub fn new(root_url: &str, token: &str) -> Self {
        Self {
            agent: http::agent(root_url, REQUEST_TIMEOUT),
            root_url: root_url.trim_end_matches('/').to_string(),
            token: token.to_string(),
        }
    }

    fn url(&self) -> String {
        format!("{}/completion", self.root_url)
    }

    /// Reads `request`'s healed prompt into the server's cache without
    /// generating, so the first keystroke in a newly focused field only adds
    /// what was typed (`LocalLlamaCotypingEngine.prewarm(for:)`).
    pub fn prefill(&self, request: &Request) -> Result<()> {
        let healed = healing::healed_generation(
            &request.prompt,
            &request.word_prefix,
            request.preceding_ends_with_whitespace(),
        );
        let body = json!({
            "prompt": healed.healed_prompt,
            "n_predict": 0,
            "cache_prompt": true,
            "stream": false,
        });
        let reply = http::post_json(&self.agent, &self.url(), Some(&self.token), &body)?;
        if !reply.ok() {
            return Err(reply.status_error().into());
        }
        Ok(())
    }

    /// One suggestion. `cancelled` is polled between streamed tokens; when it
    /// returns true the request is dropped and [`Cancelled`] returned.
    pub fn complete(&self, request: &Request, cancelled: &dyn Fn() -> bool) -> Result<Completion> {
        let started = Instant::now();
        let healed = healing::healed_generation(
            &request.prompt,
            &request.word_prefix,
            request.preceding_ends_with_whitespace(),
        );
        let gated = request.word_prefix.is_empty();
        let mut decoder = Decoder::new(request, &healed.required_prefix, gated);
        let mut timings = Timings::default();
        let body = request_body(request, &healed, gated);
        self.drive(&body, &mut decoder, &mut timings, started, cancelled)?;
        if let Some(cover) = decoder.restart.take() {
            // Go on from the token that spells the whole fragment, which the
            // server now reads as part of the prompt.
            let mut continued = Decoder::new(request, "", gated);
            continued.start_from(&cover, healed.required_prefix.len());
            if !continued.stopped {
                let body = cover_body(request, &healed, &cover, gated);
                self.drive(&body, &mut continued, &mut timings, started, cancelled)?;
            }
            decoder = continued;
        }
        timings.total_ms = elapsed_ms(started);
        Ok(Completion {
            result: decoder.result(),
            raw: decoder.output.clone(),
            hit_limit: decoder.hit_limit,
            timings,
        })
    }

    /// Streams one request into `decoder` until it ends or the decoder stops.
    fn drive(
        &self,
        body: &Value,
        decoder: &mut Decoder,
        timings: &mut Timings,
        started: Instant,
        cancelled: &dyn Fn() -> bool,
    ) -> Result<()> {
        let mut stream = http::post_stream(&self.agent, &self.url(), Some(&self.token), body)?;
        if let Some(reply) = stream.error.take() {
            return Err(reply.status_error().into());
        }
        let mut finished = false;
        while let Some(line) = stream.next_line(&self.root_url)? {
            if cancelled() {
                return Err(Cancelled.into());
            }
            let Some(payload) = line.trim().strip_prefix("data:") else {
                continue;
            };
            let payload = payload.trim();
            if payload.is_empty() || payload == "[DONE]" {
                continue;
            }
            let event: Value = serde_json::from_str(payload)
                .map_err(|_| AiError::BadResponse("unreadable completion stream".into()))?;
            if let Some(error) = event.get("error") {
                return Err(anyhow!("llama-server: {error}"));
            }
            let stop = event.get("stop").and_then(Value::as_bool) == Some(true);
            if timings.first_token_ms.is_none() && !stop {
                timings.first_token_ms = Some(elapsed_ms(started));
            }
            read_timings(&event, timings);
            let flow = decoder.feed_event(&event);
            if stop {
                if event.get("stop_type").and_then(Value::as_str) == Some("limit") {
                    decoder.hit_limit = true;
                }
                finished = true;
                break;
            }
            if flow != Flow::Continue {
                finished = true;
                break;
            }
        }
        if cancelled() {
            return Err(Cancelled.into());
        }
        if !finished && decoder.output.is_empty() && !decoder.stopped {
            return Err(AiError::BadResponse("the completion stream ended early".into()).into());
        }
        Ok(())
    }
}

fn elapsed_ms(started: Instant) -> f64 {
    started.elapsed().as_secs_f64() * 1000.0
}

fn read_timings(event: &Value, timings: &mut Timings) {
    let Some(server) = event.get("timings") else {
        return;
    };
    timings.prompt_tokens = server.get("prompt_n").and_then(Value::as_u64);
    timings.cached_tokens = server.get("cache_n").and_then(Value::as_u64);
    timings.prompt_ms = server.get("prompt_ms").and_then(Value::as_f64);
    timings.predicted_tokens = server.get("predicted_n").and_then(Value::as_u64);
}

/// The `/completion` body: the healed raw prompt, the macOS sampler, one
/// line unless multi-line suggestions are on.
pub fn request_body(request: &Request, healed: &healing::Split, gated: bool) -> Value {
    let prefix = &healed.required_prefix;
    let extra_tokens = if prefix.is_empty() {
        0
    } else if prefix.chars().all(char::is_whitespace) {
        HEALED_SPACE_TOKENS
    } else {
        HEALED_FRAGMENT_TOKENS
    };
    let sampling = request.sampling;
    let mut body = json!({
        "prompt": healed.healed_prompt,
        "n_predict": request.max_tokens + extra_tokens,
        "cache_prompt": true,
        "stream": true,
        "temperature": sampling.temperature,
        "top_p": sampling.top_p,
        "top_k": sampling.top_k,
        "min_p": sampling.min_p,
        "repeat_penalty": sampling.repeat_penalty,
        "repeat_last_n": sampling.repeat_last_n,
        "seed": sampling.seed,
        "n_probs": if gated { GATED_PROBABILITIES } else { FRAGMENT_PROBABILITIES },
        // The prompt and generation counts arrive with every token, so they
        // are known however early the stream is left.
        "timings_per_token": true,
    });
    if !prefix.is_empty() {
        body["grammar"] = Value::String(healing::grammar(prefix));
    }
    body
}

/// The request that goes on after a whole-fragment token: the healed prompt
/// with that token appended (llama-server takes text and token ids mixed),
/// and no constraint left.
fn cover_body(request: &Request, healed: &healing::Split, cover: &Cover, gated: bool) -> Value {
    let unconstrained = healing::Split {
        healed_prompt: healed.healed_prompt.clone(),
        required_prefix: String::new(),
    };
    let mut body = request_body(request, &unconstrained, gated);
    body["prompt"] = json!([healed.healed_prompt, cover.id]);
    body
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Flow {
    Continue,
    Stop,
    /// Start again from [`Decoder::restart`].
    Restart,
}

/// One candidate token of a step, as llama-server reports it.
struct Candidate {
    id: Option<i64>,
    bytes: Vec<u8>,
    logprob: f64,
    probability: f32,
}

/// A token that spells the whole word fragment at the caret.
#[derive(Clone, Debug, PartialEq)]
struct Cover {
    id: i64,
    bytes: Vec<u8>,
    logprob: f64,
    probability: f32,
}

impl Candidate {
    /// Special tokens carry no text; at the end of a reply they end it.
    fn is_end(&self) -> bool {
        self.bytes.is_empty()
    }
}

fn candidate(value: &Value) -> Option<Candidate> {
    let bytes: Vec<u8> = match value.get("bytes").and_then(Value::as_array) {
        Some(bytes) => bytes
            .iter()
            .filter_map(Value::as_u64)
            .map(|b| b.min(255) as u8)
            .collect(),
        None => value.get("token")?.as_str()?.as_bytes().to_vec(),
    };
    let logprob = value
        .get("logprob")
        .and_then(Value::as_f64)
        .or_else(|| value.get("prob").and_then(Value::as_f64).map(f64::ln))
        .unwrap_or(f64::NEG_INFINITY);
    Some(Candidate {
        id: value.get("id").and_then(Value::as_i64),
        bytes,
        logprob,
        probability: logprob.exp() as f32,
    })
}

/// The streamed decode loop of `LlamaCotypingRuntime.generate`, fed with
/// llama-server's per-token reports instead of logits.
struct Decoder<'a> {
    request: &'a Request,
    /// Required-prefix bytes still to be re-typed.
    remaining: Vec<u8>,
    utf8: Utf8Decoder,
    pub output: String,
    tokens: usize,
    gate: ConfidenceDecision,
    unsure: bool,
    malformed: bool,
    stopped: bool,
    hit_limit: bool,
    /// Healing a word fragment (`searchPrefixPath`): the log probability of
    /// the grammar's path through it so far, whether its first token covered
    /// only part of it, and the best first-step token that spells all of it.
    path_logprob: f64,
    constrained_steps: usize,
    partial_first: bool,
    best_cover: Option<Cover>,
    restart: Option<Cover>,
}

impl<'a> Decoder<'a> {
    fn new(request: &'a Request, required_prefix: &str, gated: bool) -> Self {
        Self {
            request,
            remaining: required_prefix.as_bytes().to_vec(),
            utf8: Utf8Decoder::default(),
            output: String::new(),
            tokens: 0,
            gate: ConfidenceDecision::for_autocomplete(gated),
            unsure: false,
            malformed: false,
            stopped: false,
            hit_limit: false,
            path_logprob: 0.0,
            constrained_steps: 0,
            partial_first: false,
            best_cover: None,
            restart: None,
        }
    }

    /// Starts after a whole-fragment token: its text past the fragment is
    /// the first visible text.
    fn start_from(&mut self, cover: &Cover, fragment_len: usize) {
        let extra = cover.bytes.get(fragment_len..).unwrap_or_default().to_vec();
        if !extra.is_empty() && self.emit(&extra, cover.probability, &[]) != Flow::Continue {
            self.stopped = true;
        }
    }

    fn feed_event(&mut self, event: &Value) -> Flow {
        if self.stopped {
            return Flow::Stop;
        }
        match event
            .get("completion_probabilities")
            .and_then(Value::as_array)
        {
            Some(steps) if !steps.is_empty() => {
                for step in steps {
                    match self.feed_step(step) {
                        Flow::Continue => {}
                        Flow::Stop => {
                            self.stopped = true;
                            return Flow::Stop;
                        }
                        Flow::Restart => return Flow::Restart,
                    }
                }
                Flow::Continue
            }
            _ => {
                // Text without probabilities: weigh it as unknown (0), which
                // keeps the gate closed rather than showing it unweighed.
                let content = event.get("content").and_then(Value::as_str).unwrap_or("");
                if content.is_empty() {
                    return Flow::Continue;
                }
                let step = Candidate {
                    id: None,
                    bytes: content.as_bytes().to_vec(),
                    logprob: f64::NEG_INFINITY,
                    probability: 0.0,
                };
                let flow = self.feed_token(&step, &[]);
                if flow == Flow::Stop {
                    self.stopped = true;
                }
                flow
            }
        }
    }

    fn feed_step(&mut self, step: &Value) -> Flow {
        let Some(token) = candidate(step) else {
            return Flow::Continue;
        };
        let top: Vec<Candidate> = step
            .get("top_logprobs")
            .or_else(|| step.get("top_probs"))
            .and_then(Value::as_array)
            .map(|list| list.iter().filter_map(candidate).collect())
            .unwrap_or_default();
        self.feed_token(&token, &top)
    }

    fn feed_token(&mut self, token: &Candidate, top: &[Candidate]) -> Flow {
        // Constrained phase: the grammar re-types the cut text.
        if !self.remaining.is_empty() {
            if token.is_end() {
                return Flow::Stop;
            }
            let fragment = !self.remaining.iter().all(u8::is_ascii_whitespace);
            let first = self.constrained_steps == 0;
            self.constrained_steps += 1;
            self.path_logprob += token.logprob;
            if first && fragment {
                self.partial_first = !covers(&token.bytes, &self.remaining);
                self.best_cover = top
                    .iter()
                    .filter(|c| {
                        c.id.is_some() && c.id != token.id && covers(&c.bytes, &self.remaining)
                    })
                    .max_by(|a, b| a.logprob.total_cmp(&b.logprob))
                    .map(|c| Cover {
                        id: c.id.unwrap_or_default(),
                        bytes: c.bytes.clone(),
                        logprob: c.logprob,
                        probability: c.probability,
                    });
            }
            // Each further token only lowers the path's probability: once it
            // is below a single whole-fragment token, that token wins.
            if self.partial_first
                && let Some(cover) = &self.best_cover
                && cover.logprob > self.path_logprob
            {
                self.restart = Some(cover.clone());
                return Flow::Restart;
            }
            match healing::match_piece(&token.bytes, &self.remaining) {
                healing::PrefixMatch::Consumes(count) => {
                    self.remaining.drain(..count);
                    return Flow::Continue;
                }
                healing::PrefixMatch::Overshoots(extra) => {
                    self.remaining.clear();
                    return self.emit(&extra, token.probability, top);
                }
                healing::PrefixMatch::Mismatch => {
                    self.malformed = true;
                    return Flow::Stop;
                }
            }
        }
        // The most likely next token ends the text: stop here, whatever the
        // sampler picked (`stopAtArgmaxEOG`).
        let argmax_ends = top.first().is_some_and(Candidate::is_end);
        if token.is_end() || argmax_ends {
            if self.gate.needs_eog_evaluation() {
                let probability = if token.is_end() {
                    token.probability
                } else {
                    top[0].probability
                };
                let boundary = self
                    .gate
                    .needs_boundary_mass(" ")
                    .then(|| boundary_mass(top));
                if !self.gate.accept(" ", probability, boundary, true) {
                    self.unsure = true;
                }
            }
            return Flow::Stop;
        }
        self.emit(&token.bytes.clone(), token.probability, top)
    }

    /// One visible piece: weighed by the gate, appended, checked against the
    /// stop policy.
    fn emit(&mut self, bytes: &[u8], probability: f32, top: &[Candidate]) -> Flow {
        let Some(text) = self.utf8.append(bytes) else {
            self.malformed = true;
            return Flow::Stop;
        };
        // A token that ends inside a character still counts toward the
        // first word's probability, as in the in-process runtime.
        if self.gate.needs_evaluation() {
            let boundary = self
                .gate
                .needs_boundary_mass(&text)
                .then(|| boundary_mass(top));
            if !self.gate.accept(&text, probability, boundary, false) {
                self.unsure = true;
                return Flow::Stop;
            }
        }
        if text.is_empty() {
            return Flow::Continue;
        }
        self.output.push_str(&text);
        self.tokens += 1;
        if stop::verdict(&self.output, self.tokens).is_some() {
            return Flow::Stop;
        }
        // The normalizer keeps the first line (or paragraph); what follows a
        // finished one is never shown.
        let shown = self.output.trim_start();
        let ended = if self.request.multi_line {
            shown.contains("\n\n")
        } else {
            shown.contains('\n')
        };
        if ended {
            return Flow::Stop;
        }
        Flow::Continue
    }

    fn result(&self) -> Normalized {
        if self.unsure {
            return Normalized::suppressed(Suppression::LowConfidence);
        }
        if self.malformed {
            return Normalized::suppressed(Suppression::UnsafeToInsert);
        }
        if !self.remaining.is_empty() {
            // The cut text was never re-typed: nothing may skip the fragment.
            return Normalized::suppressed(if self.output.is_empty() {
                Suppression::EmptyGeneration
            } else {
                Suppression::WordCompletionMismatch
            });
        }
        let normalized = normalize::normalize_detailed(&self.output, self.request);
        if self.gate.uses_fallback() {
            confidence::one_word_fallback(normalized)
        } else {
            normalized
        }
    }
}

/// Whether a token spells all of the remaining fragment (and maybe more).
fn covers(bytes: &[u8], remaining: &[u8]) -> bool {
    match healing::match_piece(bytes, remaining) {
        healing::PrefixMatch::Consumes(count) => count == remaining.len(),
        healing::PrefixMatch::Overshoots(_) => true,
        healing::PrefixMatch::Mismatch => false,
    }
}

/// The probability that a new word starts or the text ends, summed over the
/// reported candidates (`LlamaCotypingRuntime.boundaryMass`).
fn boundary_mass(top: &[Candidate]) -> f32 {
    let total: f32 = top
        .iter()
        .filter(|c| c.is_end() || confidence::token_starts_boundary(&c.bytes))
        .map(|c| c.probability)
        .sum();
    total.clamp(0.0, 1.0)
}

/// `CotypingUTF8TokenDecoder`: tokens are byte fragments; an unfinished
/// character waits for the next token, and malformed bytes reject the reply.
#[derive(Default)]
struct Utf8Decoder {
    pending: Vec<u8>,
    failed: bool,
}

impl Utf8Decoder {
    fn append(&mut self, bytes: &[u8]) -> Option<String> {
        if self.failed {
            return None;
        }
        self.pending.extend_from_slice(bytes);
        match std::str::from_utf8(&self.pending) {
            Ok(text) => {
                let text = text.to_string();
                self.pending.clear();
                Some(text)
            }
            Err(err) if err.error_len().is_none() => {
                // Incomplete at the end: keep the tail for the next token.
                let valid = err.valid_up_to();
                let text = String::from_utf8_lossy(&self.pending[..valid]).into_owned();
                self.pending.drain(..valid);
                Some(text)
            }
            Err(_) => {
                self.failed = true;
                self.pending.clear();
                None
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::autocomplete::prompt::Sampling;
    use crate::http::testing::{Reply, StubServer};

    fn request(prefix: &str, word_prefix: &str) -> Request {
        Request {
            prompt: prefix.to_string(),
            prefix: prefix.to_string(),
            after: String::new(),
            multi_line: false,
            max_tokens: 6,
            max_words: 4,
            sampling: Sampling::default(),
            force_word_continuation: false,
            word_prefix: word_prefix.to_string(),
            word_prefix_is_valid_word: true,
            conditioning_preface: None,
        }
    }

    /// A token id for tests: the same text, the same id.
    fn id(text: &str) -> u64 {
        text.bytes()
            .fold(7u64, |h, b| h.wrapping_mul(31).wrapping_add(u64::from(b)))
            % 100_000
    }

    fn token(text: &str, logprob: f64, top: &[(&str, f64)]) -> String {
        let entry = |t: &str, lp: f64| json!({"id": id(t), "token": t, "bytes": t.as_bytes(), "logprob": lp});
        json!({
            "content": text,
            "stop": false,
            "completion_probabilities": [{
                "id": id(text), "token": text, "bytes": text.as_bytes(), "logprob": logprob,
                "top_logprobs": top.iter().map(|(t, lp)| entry(t, *lp)).collect::<Vec<_>>(),
            }],
        })
        .to_string()
    }

    fn done(stop_type: &str) -> String {
        json!({
            "content": "", "stop": true, "stop_type": stop_type,
            "timings": {"prompt_n": 3, "cache_n": 40, "prompt_ms": 12.5, "predicted_n": 4},
        })
        .to_string()
    }

    fn serve(events: Vec<String>) -> StubServer {
        StubServer::start(move |_| Reply::Sse(events.clone()))
    }

    fn complete(server: &StubServer, request: &Request) -> Completion {
        Completer::new(&server.url(""), "token")
            .complete(request, &|| false)
            .unwrap()
    }

    #[test]
    fn heals_the_caret_word_and_shows_only_what_follows() {
        let server = serve(vec![
            token(" follow", -2.0, &[(" touch", -1.5), (" follow", -2.0)]),
            token(" up", -0.02, &[(" up", -0.02)]),
            token(" on", -0.3, &[(" on", -0.3)]),
            done("limit"),
        ]);
        let request = request("I wanted to follo", "follo");
        let completion = complete(&server, &request);
        assert_eq!(completion.result, Normalized::shown("w up on"));
        assert!(completion.hit_limit);
        assert_eq!(completion.timings.cached_tokens, Some(40));
        let body = server.last_json("/completion");
        assert_eq!(body["prompt"], "I wanted to");
        assert_eq!(body["n_predict"], 10);
        assert_eq!(body["cache_prompt"], true);
        assert_eq!(body["timings_per_token"], true);
        assert!(body.get("stop").is_none());
        assert_eq!(body["seed"], 0x00C0_FFEE);
        assert!(
            body["grammar"]
                .as_str()
                .unwrap()
                .starts_with("root ::= \"\\u0020\\u0066")
        );
        let auth = server.requests()[0].header("authorization");
        assert_eq!(auth.as_deref(), Some("Bearer token"));
    }

    #[test]
    fn a_whole_fragment_token_beats_an_unlikely_path_through_the_fragment() {
        // The grammar takes " to", the most likely token compatible with
        // " tomor", and must then force "mo": far less likely than " tomorrow".
        let first = vec![
            token(
                " to",
                -1.6,
                &[(" to", -1.6), (".", -2.2), (" tomorrow", -3.2)],
            ),
            token("mo", -14.2, &[(" you", -0.7)]),
            done("limit"),
        ];
        let second = vec![
            token(".", -1.0, &[(".", -1.0)]),
            token(" Thanks", -0.5, &[(" Thanks", -0.5)]),
            done("limit"),
        ];
        let server = StubServer::start(move |request| {
            if request.json()["prompt"].is_array() {
                Reply::Sse(second.clone())
            } else {
                Reply::Sse(first.clone())
            }
        });
        let tomor = request("I'll send the mockups over tomor", "tomor");
        let completion = complete(&server, &tomor);
        assert_eq!(completion.result, Normalized::shown("row."));
        let continued = server.last_json("/completion");
        assert_eq!(
            continued["prompt"],
            json!(["I'll send the mockups over", id(" tomorrow")])
        );
        assert!(continued.get("grammar").is_none());
        assert_eq!(continued["n_predict"], 6);
        // A likely path through the fragment is kept.
        let kept = serve(vec![
            token(" fol", -0.3, &[(" fol", -0.3), (" follower", -6.0)]),
            token("low", -0.1, &[("low", -0.1)]),
            token(" up", -0.1, &[(" up", -0.1)]),
            done("limit"),
        ]);
        let completion = complete(&kept, &request("I wanted to follo", "follo"));
        assert_eq!(completion.result, Normalized::shown("w up"));
        assert_eq!(kept.requests().len(), 1);
    }

    #[test]
    fn an_unsure_first_word_shows_nothing_and_a_fair_one_is_cut_to_one_word() {
        // p(" maybe") = 0.05 < 0.1, and the boundary mass after it is small.
        let unsure = serve(vec![
            token(" maybe", (0.05f64).ln(), &[(" maybe", (0.05f64).ln())]),
            token(" later", -0.1, &[(" later", -0.1)]),
            done("limit"),
        ]);
        let request = request("We could meet ", "");
        assert_eq!(
            complete(&unsure, &request).result,
            Normalized::suppressed(Suppression::LowConfidence)
        );
        // p(" Thursday") = 0.6 passes; p(" or") = 0.1 drops the product to
        // 0.06, under 0.1. A word boundary after "Thursday" (0.5 + 0.4) keeps
        // the fallback at 0.54, so the suggestion is cut to that one word.
        let fallback = serve(vec![
            token(" Thursday", (0.6f64).ln(), &[(" Thursday", (0.6f64).ln())]),
            token(
                " or",
                (0.1f64).ln(),
                &[(" or", (0.5f64).ln()), (",", (0.4f64).ln())],
            ),
            token(" Friday", -0.1, &[(" Friday", -0.1)]),
            done("limit"),
        ]);
        assert_eq!(
            complete(&fallback, &request).result,
            Normalized::shown("Thursday")
        );
    }

    #[test]
    fn stops_when_the_most_likely_token_ends_the_text() {
        let server = serve(vec![
            token(" soon", -0.1, &[(" soon", -0.1)]),
            token(" again", -0.9, &[("", -0.8), (" again", -0.9)]),
            done("limit"),
        ]);
        let completion = complete(&server, &request("See you ", ""));
        assert_eq!(completion.result, Normalized::shown("soon"));
        assert!(!completion.hit_limit);
    }

    #[test]
    fn stops_at_the_end_of_a_sentence() {
        let server = serve(vec![
            token(" care", -0.1, &[(" care", -0.1)]),
            token(" of", -0.1, &[(" of", -0.1)]),
            token(" it.", -0.1, &[(" it.", -0.1)]),
            token(" Then", -0.1, &[(" Then", -0.1)]),
            done("limit"),
        ]);
        let completion = complete(&server, &request("I can take ", ""));
        assert_eq!(completion.result, Normalized::shown("care of it."));
        assert_eq!(
            completion.raw, "care of it.",
            "the healed space is not shown"
        );
    }

    #[test]
    fn one_line_ends_the_reply_but_a_reply_may_start_on_a_new_line() {
        let server = serve(vec![
            token("\n", -0.1, &[("\n", -0.1)]),
            token("I'm", -0.1, &[("I'm", -0.1)]),
            token(" on", -0.1, &[(" on", -0.1)]),
            token(" it\n", -0.1, &[(" it\n", -0.1)]),
            token("Thanks", -0.1, &[("Thanks", -0.1)]),
            done("limit"),
        ]);
        let completion = complete(&server, &request("Hi team,", ""));
        assert_eq!(completion.result, Normalized::shown(" I'm on it"));
        assert_eq!(completion.raw, "\nI'm on it\n");
    }

    #[test]
    fn a_reply_that_never_retypes_the_cut_text_is_suppressed() {
        let server = serve(vec![done("eos")]);
        let completion = complete(&server, &request("I wanted to follo", "follo"));
        assert_eq!(
            completion.result,
            Normalized::suppressed(Suppression::EmptyGeneration)
        );
    }

    #[test]
    fn cancellation_drops_the_request() {
        let server = serve(vec![token(" a", -0.1, &[]), done("limit")]);
        let err = Completer::new(&server.url(""), "t")
            .complete(&request("x ", ""), &|| true)
            .unwrap_err();
        assert!(err.downcast_ref::<Cancelled>().is_some());
    }

    #[test]
    fn prefill_reads_the_healed_prompt_without_generating() {
        let server = StubServer::start(|_| Reply::Json(200, json!({"content": ""})));
        Completer::new(&server.url(""), "t")
            .prefill(&request("Thanks for the ", ""))
            .unwrap();
        let body = server.last_json("/completion");
        assert_eq!(body["prompt"], "Thanks for the");
        assert_eq!(body["n_predict"], 0);
    }

    #[test]
    fn utf8_split_across_tokens_is_joined() {
        let mut decoder = Utf8Decoder::default();
        let bytes = "ü".as_bytes();
        assert_eq!(decoder.append(&bytes[..1]).as_deref(), Some(""));
        assert_eq!(decoder.append(&bytes[1..]).as_deref(), Some("ü"));
        assert_eq!(decoder.append(&[0xFF]), None);
        assert_eq!(
            decoder.append(b"a"),
            None,
            "a malformed reply stays rejected"
        );
    }
}
