use crate::{domain::*, privacy};
use anyhow::{Context, Result, bail, ensure};
use reqwest::blocking::Client;
use serde_json::{Value, json};
use std::time::Duration;

pub struct Engine {
    client: Client,
    settings: Settings,
    key: Option<String>,
}
pub fn save_api_key(key: &str) -> Result<()> {
    ensure!(!key.trim().is_empty(), "API key is empty");
    keyring::Entry::new("me.dotenv.LokalBotDesktop","openrouter")?.set_password(key).context("OS credential store is unavailable; supply OPENROUTER_API_KEY in the process environment instead")
}
pub fn api_key() -> Option<String> {
    std::env::var("OPENROUTER_API_KEY")
        .ok()
        .filter(|s| !s.is_empty())
        .or_else(|| {
            keyring::Entry::new("me.dotenv.LokalBotDesktop", "openrouter")
                .ok()?
                .get_password()
                .ok()
        })
}

impl Engine {
    pub fn new(settings: Settings) -> Result<Self> {
        let key = if settings.backend == Backend::OpenRouter {
            api_key()
        } else {
            None
        };
        Self::with_key(settings, key)
    }
    pub fn with_key(settings: Settings, key: Option<String>) -> Result<Self> {
        privacy::check_inference(&settings)?;
        if settings.backend == Backend::OpenRouter {
            ensure!(
                key.as_ref().is_some_and(|s| !s.is_empty()),
                "OpenRouter needs an API key in the OS credential store or OPENROUTER_API_KEY"
            );
        }
        let key = if settings.backend == Backend::OpenRouter {
            key
        } else {
            None
        };
        let mut builder = Client::builder()
            .connect_timeout(Duration::from_secs(10))
            .timeout(Duration::from_secs(90))
            .redirect(reqwest::redirect::Policy::none());
        if privacy::is_loopback_endpoint(&settings.endpoint)? {
            // System proxy settings must never redirect plaintext local context.
            builder = builder.no_proxy();
        }
        let client = builder.build()?;
        Ok(Self {
            client,
            settings,
            key,
        })
    }
    pub fn request_body(&self, system: &str, user: Value, schema: Option<Value>) -> Value {
        let mut body = json!({"model":self.settings.model,"messages":[{"role":"system","content":system},{"role":"user","content":user}],"max_tokens":4800,"temperature":0.2,"stream":false});
        if self.settings.backend == Backend::OpenRouter {
            body["provider"] = json!({"data_collection":if self.settings.account_data_policy{"allow"}else{"deny"},"require_parameters":true});
            body["reasoning"] = json!({"effort":"low","exclude":true});
        }
        if let Some(schema) = schema {
            body["response_format"] = json!({"type":"json_schema","json_schema":{"name":"lokalbot_result","strict":true,"schema":schema}});
        }
        body
    }
    fn post(&self, suffix: &str, body: &Value) -> Result<Value> {
        let mut request = self
            .client
            .post(format!(
                "{}/{}",
                self.settings.endpoint.trim_end_matches('/'),
                suffix
            ))
            .json(body);
        if let Some(key) = &self.key {
            request = request.bearer_auth(key);
        }
        let response = request.send().context("Inference connection failed")?;
        let status = response.status();
        if !status.is_success() {
            bail!(
                "Inference returned HTTP {}. Check the model, credential, credit balance, and provider policy.",
                status.as_u16()
            );
        }
        use std::io::Read;
        let mut bytes = Vec::new();
        response.take(2 * 1024 * 1024 + 1).read_to_end(&mut bytes)?;
        ensure!(
            bytes.len() <= 2 * 1024 * 1024,
            "Inference response is too large"
        );
        serde_json::from_slice(&bytes).context("Inference returned malformed JSON")
    }
    pub fn generate(
        &self,
        purpose: &str,
        system: &str,
        user: &str,
        schema: Option<Value>,
    ) -> Result<(String, Generation)> {
        let body = self.request_body(system, json!(privacy::redact(user)), schema);
        let result = self.post("chat/completions", &body)?;
        let choice = &result["choices"][0];
        ensure!(
            choice["finish_reason"] != "length",
            "The model truncated its answer; choose a smaller context or retry"
        );
        let text = choice["message"]["content"]
            .as_str()
            .context("Inference returned no answer text")?
            .trim()
            .to_owned();
        ensure!(
            !text.is_empty() && text.len() <= 64000,
            "Inference returned empty or oversized content"
        );
        Ok((
            text,
            Generation {
                purpose: purpose.into(),
                model: result["model"]
                    .as_str()
                    .unwrap_or(&self.settings.model)
                    .into(),
                input_tokens: result["usage"]["prompt_tokens"].as_u64().unwrap_or(0),
                output_tokens: result["usage"]["completion_tokens"].as_u64().unwrap_or(0),
                cost: result["usage"]["cost"].as_f64().unwrap_or(0.),
                created_at: now(),
            },
        ))
    }
    pub fn transcribe(&self, path: &std::path::Path) -> Result<(Vec<Segment>, Generation)> {
        self.transcribe_guarded(path, || Ok(()))
    }
    pub fn transcribe_guarded(
        &self,
        path: &std::path::Path,
        mut verify: impl FnMut() -> Result<()>,
    ) -> Result<(Vec<Segment>, Generation)> {
        ensure!(
            self.settings.backend == Backend::OpenRouter && self.settings.remote_audio,
            "Remote audio transcription needs its separate opt-in"
        );
        // This API currently ignores data_collection routing. Never silently relax private-only.
        ensure!(
            self.settings.account_data_policy,
            "OpenRouter's transcription API cannot enforce private-only routing. Explicitly select account-policy routing or use local Whisper."
        );
        let parts = crate::audio::remote_audio_parts(path)?;
        let mut segments = vec![];
        let mut usage = Generation {
            purpose: "transcription".into(),
            model: self.settings.transcription_model.clone(),
            input_tokens: 0,
            output_tokens: 0,
            cost: 0.,
            created_at: now(),
        };
        use base64::Engine as _;
        for part in &parts.parts {
            verify()?;
            let data = std::fs::read(&part.path)?;
            ensure!(
                data.len() <= 25 * 1024 * 1024,
                "Audio part exceeds the upload limit"
            );
            let result=self.post("audio/transcriptions",&json!({"model":self.settings.transcription_model,"input_audio":{"data":base64::engine::general_purpose::STANDARD.encode(data),"format":"wav"},"response_format":"verbose_json"}))?;
            verify()?;
            segments.extend(transcription_segments(&result, part.offset, part.duration)?);
            usage.input_tokens += result["usage"]["input_tokens"].as_u64().unwrap_or(0);
            usage.output_tokens += result["usage"]["output_tokens"].as_u64().unwrap_or(0);
            usage.cost += result["usage"]["cost"].as_f64().unwrap_or(0.);
        }
        Ok((segments, usage))
    }
    pub fn embed(&self, texts: &[String]) -> Result<Vec<Vec<f32>>> {
        ensure!(
            !self.settings.embedding_model.is_empty(),
            "Choose an embedding model first"
        );
        let mut body = json!({"model":self.settings.embedding_model,"input":texts.iter().map(|s|privacy::redact(s)).collect::<Vec<_>>()});
        if self.settings.backend == Backend::OpenRouter {
            body["provider"] = json!({"data_collection":if self.settings.account_data_policy{"allow"}else{"deny"},"require_parameters":true});
        }
        let data = self.post("embeddings", &body)?;
        let rows = data["data"].as_array().context("Missing embeddings")?;
        ensure!(rows.len() == texts.len(), "Embedding count mismatch");
        rows.iter()
            .map(|row| {
                serde_json::from_value(row["embedding"].clone()).context("Invalid embedding")
            })
            .collect()
    }
}
pub fn transcription_segments(result: &Value, offset: f64, duration: f64) -> Result<Vec<Segment>> {
    let mut segments: Vec<Segment> = if let Some(segments) = result["segments"].as_array() {
        segments
            .iter()
            .map(|s| Segment {
                id: new_id(),
                start: s["start"].as_f64().unwrap_or(0.),
                end: s["end"].as_f64().unwrap_or(0.),
                speaker: "Unidentified".into(),
                text: s["text"].as_str().unwrap_or("").trim().into(),
            })
            .filter(|s| !s.text.is_empty())
            .collect()
    } else {
        vec![Segment {
            id: new_id(),
            start: 0.,
            end: result["duration"].as_f64().unwrap_or(duration),
            speaker: "Unidentified".into(),
            text: result["text"]
                .as_str()
                .context("Transcription returned no text")?
                .into(),
        }]
    };
    for segment in &mut segments {
        ensure!(
            segment.start.is_finite()
                && segment.end.is_finite()
                && segment.start >= 0.
                && segment.end >= segment.start
                && segment.end <= duration + 1.,
            "Remote transcription returned invalid timestamps"
        );
        segment.start = offset + segment.start.min(duration);
        segment.end = offset + segment.end.min(duration);
    }
    Ok(segments)
}

pub fn parse_json<T: serde::de::DeserializeOwned>(text: &str) -> Result<T> {
    let text = text.trim();
    let text = if text.starts_with("```") {
        text.split_once('\n')
            .map(|(_, s)| s.trim_end_matches("```").trim())
            .unwrap_or(text)
    } else {
        text
    };
    serde_json::from_str(text)
        .context("The model returned invalid structured output; nothing was saved")
}
pub fn answer_schema() -> Value {
    json!({"type":"object","additionalProperties":false,"required":["text","sources"],"properties":{"text":{"type":"string"},"sources":{"type":"array","items":{"type":"string"}}}})
}
pub fn summary_schema() -> Value {
    json!({"type":"object","additionalProperties":false,"required":["overview","decisions","actions","questions"],"properties":{"overview":{"type":"string"},"decisions":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["text","source"],"properties":{"text":{"type":"string"},"source":{"type":"string"}}}},"actions":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["id","text","owner","due","source","done","corrected"],"properties":{"id":{"type":"string"},"text":{"type":"string"},"owner":{"type":"string"},"due":{"type":"string"},"source":{"type":"string"},"done":{"type":"boolean"},"corrected":{"type":"boolean"}}}},"questions":{"type":"array","items":{"type":"string"}}}})
}
