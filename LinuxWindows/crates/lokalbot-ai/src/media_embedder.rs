//! EmbeddingGemma 2 with its image and audio projector, on the media
//! llama-server (`FileMediaEmbedder`). One caller at a time, one thread, and it
//! waits: Files' indexer and the picture vectors of saved screens both use it.
//!
//! Inputs travel the way the Mac's parity run qualified them: texts as given
//! (cut to one batch when longer), images as PNG sized for their budget, audio
//! as WAV, each medium as a typed content part. Searches never use this server;
//! they embed their words on the small text-only embedder.

use std::time::Duration;

use base64::Engine as _;
use serde_json::{Value, json};

use crate::http;
use crate::runtime::{Lease, RuntimeManager};
use crate::think::vectors_from_response;

/// Which vectors this pipeline makes: the model files, the llama.cpp build, the
/// image sizing and the request shapes. Bump it when any of them changes the
/// vectors; every file index then embeds again.
pub const VECTOR_VERSION: u32 = 1;
/// What the index calls its vectors (`WorkerInfo.vectorSource`).
pub fn vector_source() -> String {
    format!(
        "google/embeddinggemma-2@bfcd298 lokalbot-llama-server-vectors{VECTOR_VERSION} text-q8_0+mmproj-q8_0"
    )
}

/// What pictures of saved screens are called: model, projector, sizing and request
/// shapes. Any change embeds every retained capture again.
pub fn picture_model_id() -> String {
    format!("embeddinggemma-2-q8-mmproj-q8-image280-v{VECTOR_VERSION}")
}

/// Texts per request. One request is one llama-server batch; this keeps a long
/// document from becoming a single multi-minute request.
const TEXTS_PER_REQUEST: usize = 16;
/// The most tokens one input may have, `<bos>` and `<eos>` included.
const MAX_INPUT_TOKENS: usize = 2_048;
const REQUEST_TIMEOUT: Duration = Duration::from_secs(120);
const MODEL_NAME: &str = "embeddinggemma-2-q8";

/// Why there's no vector.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MediaError {
    /// The server answered, but not with vectors for this input (a broken
    /// picture, one too large for its batch): the file fails alone.
    Rejected(String),
    /// The server can't answer: files stay pending for the next pass.
    Unavailable(String),
}

impl std::fmt::Display for MediaError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            MediaError::Rejected(why) | MediaError::Unavailable(why) => f.write_str(why),
        }
    }
}

impl std::error::Error for MediaError {}

/// The server for one pass. Dropping it lets the model go after its idle time.
pub struct MediaEmbedder {
    base: String,
    token: Option<String>,
    lease: Option<Lease>,
}

impl MediaEmbedder {
    pub fn start(runtime: &RuntimeManager) -> anyhow::Result<Self> {
        let lease = runtime.media_embedder_server()?;
        Ok(Self {
            base: lease.root_url(),
            token: Some(lease.token().to_string()),
            lease: Some(lease),
        })
    }

    /// A server reached directly (tests).
    pub fn for_server(base: &str, token: Option<String>) -> Self {
        Self {
            base: base.trim_end_matches('/').to_string(),
            token,
            lease: None,
        }
    }

    /// One vector per text, in order.
    pub fn embed_texts(&self, texts: &[String]) -> Result<Vec<Vec<f32>>, MediaError> {
        let mut vectors = Vec::with_capacity(texts.len());
        for slice in texts.chunks(TEXTS_PER_REQUEST) {
            let inputs = slice
                .iter()
                .map(|text| self.fitted(text))
                .collect::<Result<Vec<Value>, MediaError>>()?;
            let made = self.post(&request_body(inputs))?;
            if made.len() != slice.len() {
                return Err(MediaError::Unavailable(format!(
                    "the media embedder returned {} of {} vectors",
                    made.len(),
                    slice.len()
                )));
            }
            vectors.extend(made);
        }
        Ok(vectors)
    }

    /// One picture already sized and encoded as a PNG.
    pub fn embed_image(&self, png: &[u8]) -> Result<Vec<f32>, MediaError> {
        self.embed_one(image_part(png))
    }

    /// One piece of sound as a WAV.
    pub fn embed_audio(&self, wav: &[u8]) -> Result<Vec<f32>, MediaError> {
        self.embed_one(audio_part(wav))
    }

    fn embed_one(&self, input: Value) -> Result<Vec<f32>, MediaError> {
        self.post(&request_body(vec![input]))?
            .into_iter()
            .next()
            .ok_or_else(|| MediaError::Unavailable("the media embedder returned no vector".into()))
    }

    /// A text as it is sent: itself when it fits one batch, otherwise its tokens
    /// cut the way transformers cuts, the first 2,047 and `<eos>`. llama-server
    /// refuses a longer input with HTTP 500 instead of cutting it. No token is
    /// shorter than a byte, so shorter texts skip the tokenizer.
    fn fitted(&self, text: &str) -> Result<Value, MediaError> {
        if text.len() + 2 <= MAX_INPUT_TOKENS {
            return Ok(Value::String(text.to_string()));
        }
        let tokens = self.tokens(text)?;
        if tokens.len() <= MAX_INPUT_TOKENS {
            return Ok(Value::String(text.to_string()));
        }
        let mut cut: Vec<i64> = tokens[..MAX_INPUT_TOKENS - 1].to_vec();
        cut.push(tokens[tokens.len() - 1]);
        Ok(json!(cut))
    }

    fn tokens(&self, text: &str) -> Result<Vec<i64>, MediaError> {
        let reply = self.send("tokenize", &json!({"content": text, "add_special": true}))?;
        if !reply.ok() {
            return Err(MediaError::Unavailable(format!(
                "HTTP {} from the media embedder's tokenizer",
                reply.status
            )));
        }
        reply
            .json()
            .ok()
            .and_then(|json| {
                json.get("tokens")?
                    .as_array()?
                    .iter()
                    .map(Value::as_i64)
                    .collect()
            })
            .ok_or_else(|| MediaError::Unavailable("unexpected /tokenize payload".into()))
    }

    fn post(&self, body: &Value) -> Result<Vec<Vec<f32>>, MediaError> {
        let reply = self.send("v1/embeddings", body)?;
        match classify_status(reply.status, &reply.body) {
            Status::Vectors => reply
                .json()
                .ok()
                .and_then(|json| vectors_from_response(&json).ok())
                .ok_or_else(|| MediaError::Unavailable("unexpected /v1/embeddings payload".into())),
            Status::Rejected => Err(MediaError::Rejected(format!(
                "HTTP {}: {}",
                reply.status,
                String::from_utf8_lossy(&reply.body[..reply.body.len().min(200)])
            ))),
            Status::Unavailable => Err(MediaError::Unavailable(format!(
                "HTTP {} from the media embedder",
                reply.status
            ))),
        }
    }

    fn send(&self, path: &str, body: &Value) -> Result<http::Reply, MediaError> {
        let agent = http::agent(&self.base, REQUEST_TIMEOUT);
        http::post_json(
            &agent,
            &format!("{}/{path}", self.base),
            self.token.as_deref(),
            body,
        )
        .map_err(|err| {
            if let Some(lease) = &self.lease {
                lease.mark_unreachable();
            }
            MediaError::Unavailable(err.to_string())
        })
    }
}

#[derive(Debug, PartialEq, Eq)]
enum Status {
    Vectors,
    Rejected,
    Unavailable,
}

/// llama-server answers an input longer than its batch with HTTP 500, though the
/// server is fine; a picture or recording that still doesn't fit fails alone
/// instead of stopping every pass at the same file.
fn classify_status(status: u16, body: &[u8]) -> Status {
    match status {
        200 => Status::Vectors,
        401 | 408 | 429 => Status::Unavailable,
        400..=499 => Status::Rejected,
        500 if is_too_large(body) => Status::Rejected,
        _ => Status::Unavailable,
    }
}

fn is_too_large(body: &[u8]) -> bool {
    String::from_utf8_lossy(&body[..body.len().min(300)]).contains("too large to process")
}

fn request_body(inputs: Vec<Value>) -> Value {
    json!({"input": inputs, "model": MODEL_NAME, "cache_prompt": false})
}

/// A typed content part nested one level inside the input item; a flat
/// `input: [{type: image_url}]` is rejected (ggml-org/llama.cpp#30082).
fn image_part(png: &[u8]) -> Value {
    let data = base64::engine::general_purpose::STANDARD.encode(png);
    json!({"content": [{"type": "image_url",
                        "image_url": {"url": format!("data:image/png;base64,{data}")}}]})
}

fn audio_part(wav: &[u8]) -> Value {
    let data = base64::engine::general_purpose::STANDARD.encode(wav);
    json!({"content": [{"type": "input_audio",
                        "input_audio": {"data": data, "format": "wav"}}]})
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::http::testing::{Reply, StubServer};

    #[test]
    fn the_source_names_the_macs_vectors() {
        assert_eq!(
            vector_source(),
            "google/embeddinggemma-2@bfcd298 lokalbot-llama-server-vectors1 text-q8_0+mmproj-q8_0"
        );
    }

    #[test]
    fn statuses_tell_a_bad_file_from_a_gone_server() {
        assert_eq!(classify_status(200, b""), Status::Vectors);
        assert_eq!(classify_status(400, b""), Status::Rejected);
        assert_eq!(classify_status(422, b""), Status::Rejected);
        assert_eq!(classify_status(401, b""), Status::Unavailable);
        assert_eq!(classify_status(408, b""), Status::Unavailable);
        assert_eq!(classify_status(429, b""), Status::Unavailable);
        assert_eq!(classify_status(503, b""), Status::Unavailable);
        assert_eq!(classify_status(500, b"boom"), Status::Unavailable);
        assert_eq!(
            classify_status(500, b"input is too large to process"),
            Status::Rejected
        );
    }

    #[test]
    fn requests_carry_typed_parts() {
        let server = StubServer::start(|request| {
            let inputs = request.json()["input"].as_array().unwrap().len();
            let data: Vec<Value> = (0..inputs)
                .map(|index| json!({"index": index, "embedding": [1.0, 0.0]}))
                .collect();
            Reply::Json(200, json!({"data": data}))
        });
        let embedder = MediaEmbedder::for_server(&server.url(""), Some("tok".into()));
        assert_eq!(embedder.embed_image(b"png").unwrap().len(), 2);
        assert_eq!(embedder.embed_audio(b"wav").unwrap().len(), 2);
        let texts: Vec<String> = (0..17).map(|i| format!("text {i}")).collect();
        assert_eq!(embedder.embed_texts(&texts).unwrap().len(), 17);
        let requests = server.requests();
        let image = requests[0].json();
        assert_eq!(image["model"], "embeddinggemma-2-q8");
        assert_eq!(image["cache_prompt"], false);
        assert_eq!(image["input"][0]["content"][0]["type"], "image_url");
        assert_eq!(
            image["input"][0]["content"][0]["image_url"]["url"],
            "data:image/png;base64,cG5n"
        );
        let audio = requests[1].json();
        assert_eq!(audio["input"][0]["content"][0]["type"], "input_audio");
        assert_eq!(
            audio["input"][0]["content"][0]["input_audio"]["format"],
            "wav"
        );
        assert_eq!(
            audio["input"][0]["content"][0]["input_audio"]["data"],
            "d2F2"
        );
        // Sixteen texts a request.
        assert_eq!(requests.len(), 4);
        assert_eq!(requests[2].json()["input"].as_array().unwrap().len(), 16);
        assert_eq!(requests[3].json()["input"].as_array().unwrap().len(), 1);
    }

    #[test]
    fn a_long_text_is_cut_to_one_batch_as_tokens() {
        let server = StubServer::start(|request| {
            let body = request.json();
            if body.get("content").is_some() {
                let tokens: Vec<i64> = (0..3000).collect();
                return Reply::Json(200, json!({"tokens": tokens}));
            }
            Reply::Json(200, json!({"data": [{"index": 0, "embedding": [1.0]}]}))
        });
        let embedder = MediaEmbedder::for_server(&server.url(""), None);
        embedder.embed_texts(&["word ".repeat(1000)]).unwrap();
        let requests = server.requests();
        let sent = requests[1].json();
        let tokens = sent["input"][0].as_array().unwrap();
        assert_eq!(tokens.len(), 2048);
        assert_eq!(tokens[2047], 2999, "ends with <eos>");
    }

    #[test]
    fn a_rejected_picture_fails_alone_and_a_dead_server_stops_the_pass() {
        let rejected = StubServer::start(|_| Reply::Json(400, json!({"error": "bad image"})));
        let embedder = MediaEmbedder::for_server(&rejected.url(""), None);
        assert!(matches!(
            embedder.embed_image(b"x"),
            Err(MediaError::Rejected(_))
        ));
        let down = StubServer::start(|_| Reply::Json(503, json!({})));
        let embedder = MediaEmbedder::for_server(&down.url(""), None);
        assert!(matches!(
            embedder.embed_image(b"x"),
            Err(MediaError::Unavailable(_))
        ));
    }
}
