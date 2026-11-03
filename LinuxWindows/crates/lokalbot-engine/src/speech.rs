//! One loaded transcription model, shared by meeting processing and dictation,
//! released after two idle minutes like the macOS speech engines.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use anyhow::Result;
use lokalbot_ai::remote_transcription::Client;
use lokalbot_core::Settings;
use lokalbot_core::remote_transcription::{RemoteTranscription, request_key};
use parking_lot::Mutex;

use lokalbot_speech::models::{accepts_vocabulary, is_remote};
use lokalbot_speech::{SpeechServer, Transcriber};

use crate::Shared;

const IDLE_UNLOAD: Duration = Duration::from_secs(120);

#[derive(Default)]
pub struct SpeechCache {
    loaded: Mutex<Option<Loaded>>,
    /// Dictation's known names, kept for a day or until the library changes.
    dictation_terms: Mutex<Option<(String, Vec<String>)>>,
    voice_loaded: AtomicBool,
}

struct Loaded {
    /// The model id, or the server, model and key behind a transcription server.
    model_id: String,
    transcriber: Transcriber,
    last_used: Instant,
}

/// The approved server, with its key, for one transcription.
fn server_client(settings: &Settings) -> Result<Client> {
    let key = request_key(
        &settings.remote_transcription_base_url,
        &settings.openai_base_url,
        &crate::secrets::remote_transcription_api_key().unwrap_or_default(),
        || crate::secrets::openai_api_key().unwrap_or_default(),
    );
    Ok(Client::new(
        &RemoteTranscription::from_settings(settings),
        key,
    )?)
}

struct ServerClient(Client);

impl SpeechServer for ServerClient {
    fn transcribe(
        &self,
        samples: &[f32],
        language: Option<&str>,
        prompt: Option<&str>,
        cancel: &AtomicBool,
    ) -> Result<String> {
        let wav = lokalbot_audio::wav_bytes(samples, lokalbot_audio::SAMPLE_RATE);
        Ok(self.0.transcribe(&wav, language, prompt, cancel)?)
    }

    fn provides_word_timings(&self) -> bool {
        self.0.provides_word_timings()
    }

    fn transcribe_timed(
        &self,
        samples: &[f32],
        language: Option<&str>,
        prompt: Option<&str>,
        cancel: &AtomicBool,
    ) -> Result<lokalbot_core::remote_transcription::WindowTranscription> {
        let wav = lokalbot_audio::wav_bytes(samples, lokalbot_audio::SAMPLE_RATE);
        Ok(self.0.transcribe_timed(&wav, language, prompt, cancel)?)
    }
}

impl SpeechCache {
    /// Runs `f` with the transcriber for `model_id`, loading it first if needed.
    pub fn with<T>(
        &self,
        shared: &Shared,
        model_id: &str,
        f: impl FnOnce(&Transcriber) -> Result<T>,
    ) -> Result<T> {
        // Checked each time, so a revoked approval counts from the next clip.
        let settings = shared.settings();
        let server = is_remote(model_id)
            .then(|| server_client(&settings))
            .transpose()?;
        let identity = match &server {
            Some(client) => format!("{model_id}|{}", client.identity()),
            None => model_id.to_string(),
        };
        let mut loaded = self.loaded.lock();
        if loaded.as_ref().is_none_or(|l| l.model_id != identity) {
            *loaded = None;
            let threads = std::thread::available_parallelism()
                .map(|n| n.get().clamp(2, 8))
                .unwrap_or(4);
            let paths = shared.library.paths();
            let transcriber = match server {
                Some(client) => Transcriber::with_server(
                    paths,
                    threads,
                    RemoteTranscription::from_settings(&settings).transcript_engine(),
                    Arc::new(ServerClient(client)),
                ),
                None => Transcriber::load(paths, model_id, threads)?,
            };
            *loaded = Some(Loaded {
                model_id: identity,
                transcriber,
                last_used: Instant::now(),
            });
        }
        let entry = loaded.as_mut().expect("loaded above");
        entry.last_used = Instant::now();
        let result = f(&entry.transcriber);
        entry.last_used = Instant::now();
        result
    }

    /// Whether `model_id` is in memory. A pass in progress counts: it holds
    /// the model that the next one waits for.
    pub fn is_loaded(&self, model_id: &str) -> bool {
        self.loaded
            .try_lock()
            .is_none_or(|loaded| loaded.as_ref().is_some_and(|l| l.model_id == model_id))
    }

    /// Read aloud's voice model came into or left memory.
    pub fn set_voice_loaded(&self, loaded: bool) {
        self.voice_loaded.store(loaded, Ordering::Relaxed);
    }

    /// Speech models held in this process, with the role each serves. A model
    /// busy transcribing is missed for that reading; it never blocks the caller.
    pub fn loaded_models(&self) -> Vec<(&'static str, String)> {
        let mut models = Vec::new();
        if let Some(loaded) = self.loaded.try_lock()
            && let Some(loaded) = loaded.as_ref()
            && !is_remote(loaded.model_id.split('|').next().unwrap_or_default())
        {
            models.push((
                "Speech recognition",
                loaded.transcriber.display_name().to_string(),
            ));
        }
        if self.voice_loaded.load(Ordering::Relaxed) {
            models.push(("Speech synthesis", "Kokoro 82M".to_string()));
        }
        models
    }

    /// Dictation has no meeting of its own, so prompt-capable models get recent
    /// attendee and project names beside the manual vocabulary
    /// (`AppState.dictationTranscriptionSettings`).
    pub fn dictation_prompt(&self, shared: &Shared, settings: &Settings) -> String {
        if !settings.auto_transcription_vocabulary
            || !accepts_vocabulary(&settings.transcription_model)
        {
            return settings.transcription_prompt.clone();
        }
        let meetings = shared.library.list_all_meetings().unwrap_or_default();
        let key = format!(
            "{}|{}|{:?}",
            chrono::Local::now().date_naive(),
            meetings.len(),
            meetings.iter().map(|m| m.started_at).max()
        );
        let mut cached = self.dictation_terms.lock();
        let terms = match cached.as_ref() {
            Some((cached_key, terms)) if *cached_key == key => terms.clone(),
            _ => {
                let terms =
                    lokalbot_core::vocabulary::terms(&lokalbot_core::vocabulary::recent_sources(
                        &meetings,
                        shared.library.paths(),
                        chrono::Utc::now(),
                    ));
                *cached = Some((key, terms.clone()));
                terms
            }
        };
        lokalbot_core::vocabulary::prompt(&settings.transcription_prompt, &terms)
    }

    /// Frees the model when it has not been used for a while.
    pub fn release_if_idle(&self) {
        if let Some(mut loaded) = self.loaded.try_lock()
            && loaded
                .as_ref()
                .is_some_and(|l| l.last_used.elapsed() > IDLE_UNLOAD)
        {
            *loaded = None;
        }
    }
}

/// Starts the idle-release timer.
pub fn start_idle_release(cache: Arc<SpeechCache>, shared: Arc<Shared>) {
    std::thread::spawn(move || {
        while !shared.is_shutting_down() {
            std::thread::sleep(Duration::from_secs(30));
            cache.release_if_idle();
        }
    });
}
