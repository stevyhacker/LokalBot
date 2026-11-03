//! Checks that a role's model responds, using sample content
//! (`ModelCheckController`). Checks confirm the path ran; they don't measure
//! accuracy. No meeting, screen or clipboard content is used.

use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Instant;

use anyhow::{Result, anyhow};
use lokalbot_core::Settings;
use lokalbot_core::access::remote_block_reason;
use lokalbot_core::remote_transcription::RemoteTranscription;
use lokalbot_core::settings::SummarizerBackend;
use parking_lot::Mutex;
use sha2::{Digest as _, Sha256};

use crate::models::{Models, RUNTIME_ID};
use crate::{ConnectionCheck, EngineEvent, ModelCheckResult, ModelCheckStatus, ModelRole, Shared};

/// The first ten seconds of a synthetic recording made with macOS `say`
/// (`Resources/ModelChecks`). It holds no meeting or personal audio.
const SPOKEN_SAMPLE: &[u8] = include_bytes!("../assets/model-check-speech.wav");
const WAV_HEADER_BYTES: usize = 44;

fn spoken_samples() -> Vec<f32> {
    let (pairs, _) = SPOKEN_SAMPLE[WAV_HEADER_BYTES..].as_chunks::<2>();
    pairs
        .iter()
        .map(|pair| f32::from(i16::from_le_bytes(*pair)) / 32_768.0)
        .collect()
}

/// Identifies just the configuration a role's check exercises, so unrelated
/// changes don't invalidate its result (`ModelCheckIdentity`).
pub(crate) fn identity(role: ModelRole, settings: &Settings, api_key: &str) -> Vec<String> {
    let entry_identity = |id: &str| match lokalbot_ai::catalog::entry(id) {
        Some(entry) => format!("{id}\n{}\n{}\n{}", entry.file, entry.url(), entry.sha256),
        None => id.to_string(),
    };
    match role {
        ModelRole::Transcribe => {
            let mut parts = vec![
                settings.transcription_model.clone(),
                settings.transcription_language.clone(),
                settings.transcription_prompt.clone(),
            ];
            if lokalbot_speech::models::is_remote(&settings.transcription_model) {
                let server = RemoteTranscription::from_settings(settings);
                parts.push(settings.remote_transcription_base_url.clone());
                parts.push(settings.remote_transcription_model.clone());
                parts.push(server.is_ready().to_string());
            }
            parts
        }
        ModelRole::Think => {
            let backend = format!("{:?}", settings.summarizer_backend);
            match settings.summarizer_backend {
                SummarizerBackend::BuiltIn => {
                    vec![backend, entry_identity(&settings.built_in_model_id)]
                }
                SummarizerBackend::Ollama => vec![
                    backend,
                    settings.ollama_base_url.clone(),
                    settings.ollama_model.clone(),
                    remote_block_reason(
                        &settings.ollama_base_url,
                        &settings.approved_remote_inference_origins,
                    )
                    .unwrap_or_default(),
                ],
                SummarizerBackend::OpenAICompatible => vec![
                    backend,
                    settings.openai_base_url.clone(),
                    settings.openai_model.clone(),
                    format!("{:?}", settings.open_router_data_policy),
                    remote_block_reason(
                        &settings.openai_base_url,
                        &settings.approved_remote_inference_origins,
                    )
                    .unwrap_or_default(),
                    hex::encode(Sha256::digest(api_key.as_bytes())),
                ],
                SummarizerBackend::ChatGptPlan | SummarizerBackend::ClaudePlan => {
                    let plan = settings.think_plan();
                    vec![
                        backend,
                        plan.map(|plan| plan.model(settings).to_string())
                            .unwrap_or_default(),
                        plan.is_some_and(|plan| plan.is_approved(settings))
                            .to_string(),
                    ]
                }
            }
        }
        ModelRole::Autocomplete => vec![entry_identity(&settings.cotyping_built_in_model_id)],
    }
}

/// What "Check connection" compares before it publishes (`hasChanges`).
fn connection_identity(settings: &Settings, backend: SummarizerBackend) -> Vec<String> {
    let mut config = settings.clone();
    config.summarizer_backend = backend;
    identity(
        ModelRole::Think,
        &config,
        &crate::secrets::openai_api_key().unwrap_or_default(),
    )
}

/// A check that found words only in a spoken sample's answer passes.
fn has_words(text: &str) -> bool {
    text.chars().any(char::is_alphabetic)
}

#[derive(Clone)]
pub struct ModelChecks {
    inner: Arc<Inner>,
}

struct Inner {
    shared: Arc<Shared>,
    models: Models,
    status: Mutex<ModelCheckStatus>,
    /// Changes when a run is cancelled or superseded.
    generation: AtomicU64,
    connection_generation: AtomicU64,
}

impl ModelChecks {
    pub fn new(shared: Arc<Shared>, models: Models) -> Self {
        Self {
            inner: Arc::new(Inner {
                shared,
                models,
                status: Mutex::new(ModelCheckStatus::default()),
                generation: AtomicU64::new(0),
                connection_generation: AtomicU64::new(0),
            }),
        }
    }

    pub fn run(&self, roles: Vec<ModelRole>) {
        {
            let mut status = self.inner.status.lock();
            if status.running {
                return;
            }
            status.running = true;
        }
        let token = self.inner.generation.fetch_add(1, Ordering::Relaxed) + 1;
        let inner = self.inner.clone();
        std::thread::spawn(move || {
            for role in roles {
                if inner.generation.load(Ordering::Relaxed) != token {
                    return;
                }
                if !inner.is_ready(role) {
                    continue;
                }
                inner.check_one(role, token);
            }
            if inner.generation.load(Ordering::Relaxed) == token {
                inner.update(|status| {
                    status.testing = None;
                    status.running = false;
                });
            }
        });
    }

    /// Stops publishing. A request already sent runs out on its own.
    pub fn cancel(&self) {
        self.inner.generation.fetch_add(1, Ordering::Relaxed);
        self.inner.update(|status| {
            status.testing = None;
            status.running = false;
        });
    }

    /// Results whose configuration changed no longer say anything.
    pub fn settings_changed(&self) {
        let settings = self.inner.shared.settings();
        let key = openai_key_for(&settings);
        let changed = {
            let mut status = self.inner.status.lock();
            let before = status.results.len();
            status
                .results
                .retain(|result| result.identity == identity(result.role, &settings, &key));
            status.results.len() != before
        };
        if changed {
            self.inner.update(|_| {});
        }
    }

    pub fn check_connection(&self, backend: SummarizerBackend) {
        let inner = self.inner.clone();
        let token = inner.connection_generation.fetch_add(1, Ordering::Relaxed) + 1;
        inner
            .shared
            .emit(EngineEvent::ConnectionCheck(ConnectionCheck {
                running: true,
                backend: Some(backend),
                ..Default::default()
            }));
        std::thread::spawn(move || {
            let mut config = inner.shared.settings();
            let before = connection_identity(&config, backend);
            config.summarizer_backend = backend;
            let result = inner.ask_think(&config);
            if inner.connection_generation.load(Ordering::Relaxed) != token {
                return;
            }
            // The form changed while this ran, so the answer is about old values.
            let latest = inner.shared.settings();
            let same = before == connection_identity(&latest, backend);
            let (reply, error) = match result {
                _ if !same => (None, None),
                Ok(reply) => (Some(reply.chars().take(120).collect()), None),
                Err(error) => (None, Some(format!("{error:#}"))),
            };
            inner
                .shared
                .emit(EngineEvent::ConnectionCheck(ConnectionCheck {
                    running: false,
                    backend: Some(backend),
                    reply,
                    error,
                }));
        });
    }
}

fn openai_key_for(settings: &Settings) -> String {
    if settings.summarizer_backend == SummarizerBackend::OpenAICompatible {
        crate::secrets::openai_api_key().unwrap_or_default()
    } else {
        String::new()
    }
}

impl Inner {
    fn update(&self, change: impl FnOnce(&mut ModelCheckStatus)) {
        let snapshot = {
            let mut status = self.status.lock();
            change(&mut status);
            status.clone()
        };
        self.shared.emit(EngineEvent::ModelChecks(snapshot));
    }

    /// `ModelRoles.snapshot[role].isReady`: nothing left to download or approve.
    fn is_ready(&self, role: ModelRole) -> bool {
        let settings = self.shared.settings();
        match role {
            ModelRole::Transcribe => {
                self.models
                    .missing(&self.models.dictation_requirements())
                    .is_empty()
                    && !self.models.transcription_server_blocked()
            }
            ModelRole::Think => self
                .models
                .missing(&self.models.think_requirements())
                .is_empty(),
            ModelRole::Autocomplete => self
                .models
                .missing(&[
                    settings.cotyping_built_in_model_id.clone(),
                    RUNTIME_ID.to_string(),
                ])
                .is_empty(),
        }
    }

    fn check_one(&self, role: ModelRole, token: u64) {
        let config = self.shared.settings();
        let key = openai_key_for(&config);
        let id = identity(role, &config, &key);
        self.update(|status| {
            status.testing = Some(role);
            status.results.retain(|result| result.role != role);
        });
        let started = Instant::now();
        let failure = self.check(role, &config).err().map(|e| format!("{e:#}"));
        if self.generation.load(Ordering::Relaxed) != token {
            return;
        }
        let latest = self.shared.settings();
        if !self.is_ready(role) || id != identity(role, &latest, &openai_key_for(&latest)) {
            return;
        }
        let result = ModelCheckResult {
            role,
            checked_at: chrono::Local::now(),
            elapsed_seconds: started.elapsed().as_secs_f64(),
            failure,
            identity: id,
        };
        self.update(|status| status.results.push(result));
    }

    fn check(&self, role: ModelRole, config: &Settings) -> Result<()> {
        match role {
            ModelRole::Transcribe => self.check_transcription(config),
            ModelRole::Think => self.ask_think(config).map(|_| ()),
            ModelRole::Autocomplete => self.check_autocomplete(config),
        }
    }

    fn check_transcription(&self, config: &Settings) -> Result<()> {
        let language = Some(config.transcription_language.as_str())
            .filter(|language| *language != "auto" && !language.is_empty());
        let samples = spoken_samples();
        let segments =
            self.shared
                .speech
                .with(&self.shared, &config.transcription_model, |transcriber| {
                    transcriber.transcribe_samples(
                        &samples,
                        language,
                        Some(&config.transcription_prompt),
                    )
                })?;
        if segments.iter().any(|segment| has_words(&segment.text)) {
            Ok(())
        } else {
            Err(anyhow!(
                "The model returned no words for the spoken sample. Check the selected language and try again."
            ))
        }
    }

    fn ask_think(&self, config: &Settings) -> Result<String> {
        let think = self.shared.think(config)?.with_priority(
            lokalbot_ai::remote_gate::Priority::Interactive,
            "model setup check",
        );
        let reply = think.complete(&lokalbot_ai::ChatRequest::new(
            lokalbot_ai::prompts::CONNECTIVITY_TEST_SYSTEM,
            lokalbot_ai::prompts::CONNECTIVITY_TEST_PROMPT,
        ))?;
        if reply.trim().is_empty() {
            return Err(anyhow!(
                "The model returned an empty response. Try another check."
            ));
        }
        Ok(reply)
    }

    /// `previewSuggestion(precedingText:sampleOnly:)`: fixed text, no field read.
    fn check_autocomplete(&self, config: &Settings) -> Result<()> {
        let client = lokalbot_ai::CompletionClient::from_settings(&self.shared.runtime, config)?;
        let request = lokalbot_ai::CompletionRequest::cotyping(
            "The local model setup is",
            config.cotyping_max_words,
            false,
        );
        client.complete(&request).map(|_| ())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_spoken_sample_is_the_macs_ten_seconds() {
        assert_eq!(&SPOKEN_SAMPLE[..4], b"RIFF");
        assert_eq!(&SPOKEN_SAMPLE[36..40], b"data");
        // 16 kHz, mono, 16-bit.
        assert_eq!(
            u32::from_le_bytes(SPOKEN_SAMPLE[24..28].try_into().unwrap()),
            16_000
        );
        assert_eq!(
            u16::from_le_bytes(SPOKEN_SAMPLE[22..24].try_into().unwrap()),
            1
        );
        assert_eq!(
            u16::from_le_bytes(SPOKEN_SAMPLE[34..36].try_into().unwrap()),
            16
        );
        let samples = spoken_samples();
        assert_eq!(samples.len(), 160_000);
        assert!(samples.iter().any(|s| s.abs() > 0.05));
    }

    #[test]
    fn identities_ignore_unrelated_settings() {
        let settings = Settings::default();
        let mut changed = settings.clone();
        changed.day_digest_custom_prompt = "unrelated".into();
        changed.openai_model = "other".into();
        assert_eq!(
            identity(ModelRole::Transcribe, &settings, ""),
            identity(ModelRole::Transcribe, &changed, "")
        );
        assert_eq!(
            identity(ModelRole::Think, &settings, ""),
            identity(ModelRole::Think, &changed, "")
        );

        changed.transcription_language = "de".into();
        assert_ne!(
            identity(ModelRole::Transcribe, &settings, ""),
            identity(ModelRole::Transcribe, &changed, "")
        );
        assert_eq!(
            identity(ModelRole::Autocomplete, &settings, ""),
            identity(ModelRole::Autocomplete, &changed, "")
        );
    }

    #[test]
    fn a_servers_identity_covers_its_key_and_approval() {
        let mut settings = Settings {
            summarizer_backend: SummarizerBackend::OpenAICompatible,
            openai_base_url: "https://x.example/v1".into(),
            ..Default::default()
        };
        let unapproved = identity(ModelRole::Think, &settings, "a");
        assert_ne!(unapproved, identity(ModelRole::Think, &settings, "b"));
        settings
            .approved_remote_inference_origins
            .push("https://x.example".into());
        assert_ne!(unapproved, identity(ModelRole::Think, &settings, "a"));
    }

    #[test]
    fn a_transcription_servers_identity_covers_its_approval() {
        let mut settings = Settings {
            transcription_model: lokalbot_core::remote_transcription::MODEL_ID.into(),
            remote_transcription_base_url: "https://x.example/v1".into(),
            ..Default::default()
        };
        let unapproved = identity(ModelRole::Transcribe, &settings, "");
        settings
            .approved_remote_transcription_origins
            .push("https://x.example".into());
        assert_ne!(unapproved, identity(ModelRole::Transcribe, &settings, ""));
    }

    #[test]
    fn words_need_letters() {
        assert!(has_words("Hello"));
        assert!(has_words("会议"));
        assert!(!has_words(" 12, 3. "));
        assert!(!has_words(""));
    }
}
