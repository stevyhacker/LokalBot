//! Sends speech clips to the transcription server the user approved
//! (`RemoteTranscriptionEngine`), in OpenAI's `/audio/transcriptions` shape.
//! Redirects are not followed, so a clip can't leave the approved origin.

use std::collections::HashSet;
use std::sync::LazyLock;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use anyhow::Result;
use lokalbot_core::remote_transcription::{
    RemoteTranscription, RemoteTranscriptionError, TimedWord, WindowTranscription,
};
use parking_lot::Mutex;
use serde_json::Value;
use sha2::{Digest as _, Sha256};

use crate::error::AiError;
use crate::http::{self, Reply};

const MAXIMUM_ATTEMPTS: u32 = 3;
/// A slow CPU server can spend well over a minute on one span.
const REQUEST_TIMEOUT: Duration = Duration::from_secs(600);
const MAXIMUM_COOLDOWN: Duration =
    Duration::from_secs(crate::remote_gate::MAXIMUM_COOLDOWN_SECONDS as u64);

#[derive(Debug, PartialEq, Eq, thiserror::Error)]
pub enum ServerError {
    #[error("{}", rejection(*.status, .detail))]
    Rejected { status: u16, detail: String },
    #[error("Could not reach the transcription server: {0}")]
    Unreachable(String),
    #[error("The transcription server did not return transcript text.")]
    InvalidResponse,
    #[error("Transcription was cancelled.")]
    Cancelled,
}

fn rejection(status: u16, detail: &str) -> String {
    let summary = match status {
        401 | 403 => format!("The transcription server rejected the API key (HTTP {status})."),
        404 => "The transcription server has no transcription endpoint at this URL (HTTP 404). Check the server URL.".to_string(),
        413 => "The transcription server refused the audio as too large (HTTP 413).".to_string(),
        429 => "The transcription server is rate limiting requests (HTTP 429). Try again later.".to_string(),
        _ => format!("The transcription server returned HTTP {status}."),
    };
    if detail.is_empty() {
        summary
    } else {
        format!("{summary} {detail}")
    }
}

/// Servers and models that refused the word-timing fields during this run
/// (`WordTimingRejections`). Kept in memory only: a server that adds support is
/// asked again after the next launch.
static WORD_TIMING_REJECTIONS: LazyLock<Mutex<HashSet<String>>> = LazyLock::new(Default::default);

/// One approved server, its key held for the life of one transcription.
pub struct Client {
    endpoint: String,
    model: String,
    api_key: String,
    agent: ureq::Agent,
    /// This server and model are known to time words.
    word_timings: bool,
    word_timing_key: String,
    /// Pause before a retry; tests shorten it.
    base_backoff: Duration,
}

impl Client {
    /// Refuses an unconfigured, invalid, unencrypted or unapproved server.
    pub fn new(
        server: &RemoteTranscription,
        api_key: String,
    ) -> Result<Self, RemoteTranscriptionError> {
        let endpoint = server.validated_endpoint()?;
        let agent = http::agent(&endpoint, REQUEST_TIMEOUT);
        Ok(Self {
            endpoint,
            model: server.trimmed_model().to_string(),
            api_key,
            agent,
            word_timings: server.requests_word_timings(),
            word_timing_key: server.word_timing_key(),
            base_backoff: Duration::from_secs(2),
        })
    }

    /// Changes when the server, the model or the key does; holds no secret.
    pub fn identity(&self) -> String {
        let key = hex::encode(Sha256::digest(self.api_key.as_bytes()));
        format!("{}|{}|{key}", self.endpoint, self.model)
    }

    /// The server times words, and hasn't refused to during this run.
    pub fn provides_word_timings(&self) -> bool {
        self.word_timings
            && !WORD_TIMING_REJECTIONS
                .lock()
                .contains(&self.word_timing_key)
    }

    /// The text of one WAV clip.
    pub fn transcribe(
        &self,
        wav: &[u8],
        language: Option<&str>,
        prompt: Option<&str>,
        cancel: &AtomicBool,
    ) -> Result<String, ServerError> {
        Ok(self.upload(wav, language, prompt, false, cancel)?.text)
    }

    /// The text of one WAV clip, with word times where the server gives them.
    pub fn transcribe_timed(
        &self,
        wav: &[u8],
        language: Option<&str>,
        prompt: Option<&str>,
        cancel: &AtomicBool,
    ) -> Result<WindowTranscription, ServerError> {
        self.upload(wav, language, prompt, true, cancel)
    }

    /// One clip, retried on rate limits, server errors and dropped connections. A
    /// server that answers the word-timing fields with HTTP 400 is asked again with
    /// plain `json`; when that succeeds, it stops being asked for word times until
    /// LokalBot quits.
    fn upload(
        &self,
        wav: &[u8],
        language: Option<&str>,
        prompt: Option<&str>,
        word_timings: bool,
        cancel: &AtomicBool,
    ) -> Result<WindowTranscription, ServerError> {
        let mut word_timings = word_timings && self.provides_word_timings();
        let mut refused = false;
        let boundary = format!("lokalbot-{}", uuid::Uuid::new_v4());
        let mut body = multipart_body(&boundary, &self.model, wav, language, prompt, word_timings);
        let mut headers = vec![
            (
                "Content-Type",
                format!("multipart/form-data; boundary={boundary}"),
            ),
            ("Accept", "application/json".to_string()),
        ];
        if !self.api_key.is_empty() {
            headers.push(("Authorization", format!("Bearer {}", self.api_key)));
        }
        let mut attempt = 0;
        loop {
            if cancel.load(Ordering::Relaxed) {
                return Err(ServerError::Cancelled);
            }
            let retry_after = match http::post_bytes_with(
                &self.agent,
                &self.endpoint,
                &headers,
                &body,
            ) {
                Ok(reply) if reply.ok() => {
                    let answer = transcription(&reply)?;
                    if refused {
                        // Only once plain json works: a clip the server refuses
                        // for another reason changes nothing.
                        log::info!(
                            "remote-asr word timings off for this server and model until relaunch"
                        );
                        WORD_TIMING_REJECTIONS
                            .lock()
                            .insert(self.word_timing_key.clone());
                    }
                    return Ok(answer);
                }
                Ok(reply) if word_timings && reply.status == 400 => {
                    log::info!(
                        "remote-asr word timings refused (HTTP 400), asking for text only: {}",
                        error_detail(&reply.body)
                    );
                    word_timings = false;
                    refused = true;
                    body = multipart_body(&boundary, &self.model, wav, language, prompt, false);
                    continue;
                }
                Ok(reply) => {
                    attempt += 1;
                    if !is_retryable(reply.status) || attempt >= MAXIMUM_ATTEMPTS {
                        return Err(ServerError::Rejected {
                            status: reply.status,
                            detail: error_detail(&reply.body),
                        });
                    }
                    reply.retry_after
                }
                Err(error) => {
                    attempt += 1;
                    if attempt >= MAXIMUM_ATTEMPTS {
                        let detail = match error.downcast_ref::<AiError>() {
                            Some(AiError::ServerUnreachable(_)) => {
                                "the connection failed.".to_string()
                            }
                            _ => format!("{error:#}"),
                        };
                        return Err(ServerError::Unreachable(detail));
                    }
                    None
                }
            };
            log::info!(
                "remote-asr retry attempt={}/{MAXIMUM_ATTEMPTS}",
                attempt + 1
            );
            wait(backoff(self.base_backoff, attempt - 1, retry_after), cancel);
        }
    }
}

/// `RemoteRetryPolicy.backoff`: what the server asked for, else doubling with a
/// little jitter, never longer than a minute.
fn backoff(base: Duration, attempt: u32, retry_after: Option<Duration>) -> Duration {
    if let Some(retry_after) = retry_after {
        return retry_after.min(MAXIMUM_COOLDOWN);
    }
    let jitter = Duration::from_millis(u64::from(
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.subsec_millis())
            .unwrap_or(0)
            % 500,
    ));
    (base * 2u32.saturating_pow(attempt) + jitter).min(MAXIMUM_COOLDOWN)
}

fn wait(pause: Duration, cancel: &AtomicBool) {
    let until = Instant::now() + pause;
    while Instant::now() < until && !cancel.load(Ordering::Relaxed) {
        std::thread::sleep(Duration::from_millis(50).min(pause));
    }
}

fn is_retryable(status: u16) -> bool {
    matches!(status, 408 | 425 | 429 | 500 | 502 | 503 | 504)
}

/// A multipart form in OpenAI's shape. `response_format=json` is the one every
/// provider and whisper.cpp accept; `word_timings` asks for `verbose_json` with word
/// timestamps instead. `model` is left out when empty because single-model servers
/// need none.
fn multipart_body(
    boundary: &str,
    model: &str,
    wav: &[u8],
    language: Option<&str>,
    prompt: Option<&str>,
    word_timings: bool,
) -> Vec<u8> {
    let mut fields: Vec<(&str, &str)> = Vec::new();
    if !model.is_empty() {
        fields.push(("model", model));
    }
    if word_timings {
        fields.push(("response_format", "verbose_json"));
        fields.push(("timestamp_granularities[]", "word"));
    } else {
        fields.push(("response_format", "json"));
    }
    fields.push(("temperature", "0"));
    if let Some(language) = language.filter(|l| !l.is_empty()) {
        fields.push(("language", language));
    }
    if let Some(prompt) = prompt.filter(|p| !p.is_empty()) {
        fields.push(("prompt", prompt));
    }
    let mut body = Vec::with_capacity(wav.len() + 512);
    for (name, value) in fields {
        body.extend_from_slice(
            format!(
                "--{boundary}\r\nContent-Disposition: form-data; name=\"{name}\"\r\n\r\n{value}\r\n"
            )
            .as_bytes(),
        );
    }
    body.extend_from_slice(
        format!(
            "--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n"
        )
        .as_bytes(),
    );
    body.extend_from_slice(wav);
    body.extend_from_slice(format!("\r\n--{boundary}--\r\n").as_bytes());
    body
}

/// `verbose_json`'s `words: [{word, start, end}]`. Tokens without letters or digits
/// are dropped; one word without valid times drops them all, and the clip then keeps
/// one speaker.
fn timed_words(words: &[Value]) -> Vec<TimedWord> {
    let mut timed = Vec::new();
    for word in words {
        let text = word
            .get("word")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .trim();
        if !text.chars().any(char::is_alphanumeric) {
            continue;
        }
        let time = |key: &str| word.get(key).and_then(Value::as_f64);
        let (Some(start), Some(end)) = (time("start"), time("end")) else {
            return Vec::new();
        };
        if !start.is_finite() || !end.is_finite() || start < 0.0 || end < start {
            return Vec::new();
        }
        timed.push(TimedWord {
            text: text.to_string(),
            start,
            end,
        });
    }
    timed
}

/// `{"text": …}` from OpenAI-style servers, plus any word times; a few self-hosted
/// ones answer plain text instead.
fn transcription(reply: &Reply) -> Result<WindowTranscription, ServerError> {
    if let Ok(payload) = serde_json::from_slice::<Value>(&reply.body)
        && let Some(text) = payload.get("text").and_then(Value::as_str)
    {
        return Ok(WindowTranscription {
            text: text.to_string(),
            words: payload
                .get("words")
                .and_then(Value::as_array)
                .map(|words| timed_words(words))
                .unwrap_or_default(),
        });
    }
    let plain = reply
        .content_type
        .as_deref()
        .is_some_and(|kind| kind.to_lowercase().starts_with("text/plain"));
    if plain {
        return Ok(WindowTranscription {
            text: String::from_utf8_lossy(&reply.body).into_owned(),
            words: Vec::new(),
        });
    }
    Err(ServerError::InvalidResponse)
}

/// The server's own message (`{"error": {"message": …}}`, `{"error": "…"}`, or a
/// short plain body), bounded for display.
fn error_detail(body: &[u8]) -> String {
    let message = match serde_json::from_slice::<Value>(body) {
        Ok(Value::Object(object)) => object
            .get("error")
            .and_then(|error| error.get("message"))
            .and_then(Value::as_str)
            .or_else(|| object.get("error").and_then(Value::as_str))
            .or_else(|| object.get("message").and_then(Value::as_str))
            .or_else(|| object.get("detail").and_then(Value::as_str))
            .unwrap_or_default()
            .to_string(),
        _ => String::from_utf8_lossy(&body[..body.len().min(300)]).into_owned(),
    };
    let trimmed = message.trim();
    if trimmed.chars().count() > 300 {
        let clipped: String = trimmed.chars().take(300).collect();
        format!("{clipped}…")
    } else {
        trimmed.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::http::testing::{Reply as StubReply, StubRequest, StubServer};
    use std::sync::atomic::AtomicUsize;

    fn client(server: &StubServer, key: &str) -> Client {
        let config = RemoteTranscription {
            base_url: server.url("/v1"),
            model: "whisper-1".to_string(),
            approved_origins: Vec::new(),
        };
        let mut client = Client::new(&config, key.to_string()).unwrap();
        client.base_backoff = Duration::from_millis(1);
        client
    }

    fn fields(request: &StubRequest) -> String {
        String::from_utf8_lossy(&request.body).into_owned()
    }

    fn timed_client(server: &StubServer, model: &str) -> Client {
        let mut client = client(server, "key");
        client.word_timings = true;
        client.word_timing_key = format!("test|{model}");
        client
    }

    #[test]
    fn a_server_that_times_words_is_asked_for_them() {
        let server = StubServer::start(|_| {
            StubReply::Json(
                200,
                serde_json::json!({
                    "text": "Hello there.",
                    "words": [
                        {"word": " Hello", "start": 0.1, "end": 0.4},
                        {"word": "—", "start": 0.4, "end": 0.4},
                        {"word": "there.", "start": 0.5, "end": 0.9},
                    ],
                }),
            )
        });
        let cancel = AtomicBool::new(false);
        let client = timed_client(&server, "asks");
        assert!(client.provides_word_timings());
        let reply = client
            .transcribe_timed(b"wav", None, None, &cancel)
            .unwrap();
        assert_eq!(reply.text, "Hello there.");
        assert_eq!(
            reply.words,
            [
                TimedWord {
                    text: "Hello".into(),
                    start: 0.1,
                    end: 0.4
                },
                TimedWord {
                    text: "there.".into(),
                    start: 0.5,
                    end: 0.9
                },
            ]
        );
        let form = fields(&server.requests()[0]);
        assert!(form.contains("name=\"response_format\"\r\n\r\nverbose_json\r\n"));
        assert!(form.contains("name=\"timestamp_granularities[]\"\r\n\r\nword\r\n"));
    }

    #[test]
    fn other_servers_keep_plain_json_with_no_word_fields() {
        let server = StubServer::start(|_| StubReply::Json(200, serde_json::json!({"text": "Hi"})));
        let cancel = AtomicBool::new(false);
        let client = client(&server, "key");
        assert!(!client.provides_word_timings());
        let reply = client
            .transcribe_timed(b"wav", None, None, &cancel)
            .unwrap();
        assert!(reply.words.is_empty());
        let form = fields(&server.requests()[0]);
        assert!(form.contains("name=\"response_format\"\r\n\r\njson\r\n"));
        assert!(!form.contains("timestamp_granularities"));
    }

    #[test]
    fn a_refusal_falls_back_to_text_and_is_remembered_once_text_works() {
        let server = StubServer::start(|request| {
            if String::from_utf8_lossy(&request.body).contains("verbose_json") {
                StubReply::Json(400, serde_json::json!({"error": {"message": "no words"}}))
            } else {
                StubReply::Json(200, serde_json::json!({"text": "Hi"}))
            }
        });
        let cancel = AtomicBool::new(false);
        let client = timed_client(&server, "refuses");
        let reply = client
            .transcribe_timed(b"wav", None, None, &cancel)
            .unwrap();
        assert_eq!(reply.text, "Hi");
        assert!(reply.words.is_empty());
        assert_eq!(server.requests().len(), 2);
        assert!(!client.provides_word_timings());
        // The next clip doesn't ask again.
        client
            .transcribe_timed(b"wav", None, None, &cancel)
            .unwrap();
        assert_eq!(server.requests().len(), 3);
    }

    #[test]
    fn a_clip_refused_for_another_reason_changes_nothing() {
        let server =
            StubServer::start(|_| StubReply::Json(400, serde_json::json!({"error": "bad clip"})));
        let cancel = AtomicBool::new(false);
        let client = timed_client(&server, "bad-clip");
        let error = client
            .transcribe_timed(b"wav", None, None, &cancel)
            .unwrap_err();
        assert!(matches!(error, ServerError::Rejected { status: 400, .. }));
        assert!(client.provides_word_timings());
    }

    #[test]
    fn one_word_without_valid_times_drops_them_all() {
        let words = |list: Value| timed_words(list.as_array().unwrap());
        assert!(
            words(serde_json::json!([
                {"word": "a1", "start": 0.0, "end": 0.1},
                {"word": "b2", "start": 0.2},
            ]))
            .is_empty()
        );
        assert!(words(serde_json::json!([{"word": "a1", "start": 1.0, "end": 0.5}])).is_empty());
        assert!(words(serde_json::json!([{"word": "a1", "start": -1.0, "end": 0.5}])).is_empty());
    }

    #[test]
    fn a_clip_goes_out_in_the_openai_shape() {
        let server =
            StubServer::start(|_| StubReply::Json(200, serde_json::json!({"text": " Hello "})));
        let cancel = AtomicBool::new(false);
        let text = client(&server, "secret")
            .transcribe(b"RIFFwav", Some("de"), Some("Kubernetes"), &cancel)
            .unwrap();
        assert_eq!(text, " Hello ");
        let requests = server.requests();
        assert_eq!(requests.len(), 1);
        let request = &requests[0];
        assert_eq!(request.path, "/v1/audio/transcriptions");
        assert_eq!(request.header("authorization").unwrap(), "Bearer secret");
        let form = fields(request);
        for expected in [
            "name=\"model\"\r\n\r\nwhisper-1\r\n",
            "name=\"response_format\"\r\n\r\njson\r\n",
            "name=\"temperature\"\r\n\r\n0\r\n",
            "name=\"language\"\r\n\r\nde\r\n",
            "name=\"prompt\"\r\n\r\nKubernetes\r\n",
            "name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\nRIFFwav\r\n",
        ] {
            assert!(form.contains(expected), "{expected} in {form}");
        }
    }

    #[test]
    fn no_key_and_no_hints_stay_out_of_the_request() {
        let server = StubServer::start(|_| StubReply::Json(200, serde_json::json!({"text": ""})));
        let cancel = AtomicBool::new(false);
        client(&server, "")
            .transcribe(b"wav", None, None, &cancel)
            .unwrap();
        let request = &server.requests()[0];
        assert_eq!(request.header("authorization"), None);
        let form = fields(request);
        assert!(!form.contains("name=\"language\""));
        assert!(!form.contains("name=\"prompt\""));
    }

    #[test]
    fn an_unapproved_server_gets_no_client() {
        let config = RemoteTranscription {
            base_url: "https://x.example/v1".to_string(),
            ..Default::default()
        };
        assert!(matches!(
            Client::new(&config, String::new()),
            Err(RemoteTranscriptionError::ApprovalRequired(_))
        ));
    }

    #[test]
    fn plain_text_replies_are_accepted_and_others_refused() {
        let server = StubServer::start(|_| StubReply::Text(200, "plain words".into()));
        let cancel = AtomicBool::new(false);
        assert_eq!(
            client(&server, "")
                .transcribe(b"wav", None, None, &cancel)
                .unwrap(),
            "plain words"
        );
        let reply = |content_type: Option<&str>, body: &[u8]| Reply {
            status: 200,
            body: body.to_vec(),
            retry_after: None,
            request_id: None,
            content_type: content_type.map(str::to_string),
        };
        assert_eq!(
            transcription(&reply(Some("text/html"), b"<html>")),
            Err(ServerError::InvalidResponse)
        );
        assert_eq!(
            transcription(&reply(Some("application/json"), br#"{"text": "a"}"#))
                .unwrap()
                .text,
            "a"
        );
    }

    #[test]
    fn server_errors_are_retried_and_a_bad_key_is_not() {
        let calls = std::sync::Arc::new(AtomicUsize::new(0));
        let counted = calls.clone();
        let server = StubServer::start(move |_| {
            if counted.fetch_add(1, Ordering::Relaxed) < 2 {
                StubReply::Text(503, "busy".into())
            } else {
                StubReply::Json(200, serde_json::json!({"text": "done"}))
            }
        });
        let cancel = AtomicBool::new(false);
        assert_eq!(
            client(&server, "")
                .transcribe(b"wav", None, None, &cancel)
                .unwrap(),
            "done"
        );
        assert_eq!(calls.load(Ordering::Relaxed), 3);

        let server = StubServer::start(|_| {
            StubReply::Json(
                401,
                serde_json::json!({"error": {"message": "Invalid key"}}),
            )
        });
        let error = client(&server, "bad")
            .transcribe(b"wav", None, None, &cancel)
            .unwrap_err();
        assert_eq!(
            error.to_string(),
            "The transcription server rejected the API key (HTTP 401). Invalid key"
        );
        assert_eq!(server.requests().len(), 1);
    }

    #[test]
    fn giving_up_says_what_the_server_said() {
        let server = StubServer::start(|_| StubReply::Text(500, "boom".into()));
        let cancel = AtomicBool::new(false);
        let error = client(&server, "")
            .transcribe(b"wav", None, None, &cancel)
            .unwrap_err();
        assert_eq!(
            error.to_string(),
            "The transcription server returned HTTP 500. boom"
        );
        assert_eq!(server.requests().len(), 3);
    }

    #[test]
    fn cancelling_stops_before_sending() {
        let server = StubServer::start(|_| StubReply::Text(200, "x".into()));
        let cancel = AtomicBool::new(true);
        assert_eq!(
            client(&server, "").transcribe(b"wav", None, None, &cancel),
            Err(ServerError::Cancelled)
        );
        assert!(server.requests().is_empty());
    }

    #[test]
    fn details_are_bounded() {
        assert_eq!(error_detail(br#"{"error":"nope"}"#), "nope");
        assert_eq!(error_detail(br#"{"detail":" why "}"#), "why");
        assert_eq!(error_detail(br#"{"other":1}"#), "");
        assert_eq!(error_detail(b"plain"), "plain");
        let long = format!(r#"{{"message":"{}"}}"#, "x".repeat(400));
        assert_eq!(
            error_detail(long.as_bytes()).chars().count(),
            301,
            "300 and an ellipsis"
        );
    }

    #[test]
    fn backoff_follows_the_server_up_to_a_minute() {
        let base = Duration::from_secs(2);
        assert_eq!(
            backoff(base, 0, Some(Duration::from_secs(5))),
            Duration::from_secs(5)
        );
        assert_eq!(
            backoff(base, 0, Some(Duration::from_secs(600))),
            MAXIMUM_COOLDOWN
        );
        assert!(backoff(base, 1, None) >= Duration::from_secs(4));
        assert_eq!(backoff(base, 10, None), MAXIMUM_COOLDOWN);
    }
}
