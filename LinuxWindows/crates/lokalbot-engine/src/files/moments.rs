//! What was said at a recording's or video's matched moment, for the Ask
//! assistant (`FileMomentTranscriber`): Files finds the 30-second window by
//! meaning, and this transcribes just that window with the person's own
//! transcription model, so the answer can quote it.
//!
//! It never downloads a transcription model, waits while a meeting records so it
//! can't compete with live transcription, and keeps the text only in memory: the
//! tool's observation isn't saved with the conversation. A remote transcription
//! server receives the clip only if its origin is approved, which `SpeechCache`
//! checks each time.

use std::collections::{HashMap, VecDeque};
use std::path::Path;
use std::sync::Arc;
use std::sync::atomic::Ordering;

use lokalbot_core::files::FileHit;
use parking_lot::Mutex;

use super::media;
use crate::Shared;
use crate::models::Models;

/// The model ignores sound past 30 s of one input, so a match covers this.
const WINDOW_SECONDS: f64 = 30.0;
const CACHE_LIMIT: usize = 64;

#[derive(Default)]
struct Cache {
    words: HashMap<String, String>,
    order: VecDeque<String>,
}

impl Cache {
    fn remember(&mut self, key: String, text: String) {
        if self.words.insert(key.clone(), text).is_none() {
            self.order.push_back(key);
        }
        if self.order.len() > CACHE_LIMIT
            && let Some(old) = self.order.pop_front()
        {
            self.words.remove(&old);
        }
    }
}

pub struct MomentTranscriber {
    shared: Arc<Shared>,
    models: Models,
    cache: Mutex<Cache>,
}

impl MomentTranscriber {
    pub(crate) fn new(shared: Arc<Shared>, models: Models) -> Self {
        Self {
            shared,
            models,
            cache: Mutex::new(Cache::default()),
        }
    }

    /// The words at `hit`'s moment, or `None` when it isn't a moment,
    /// transcription isn't available, or the clip can't be read.
    pub fn passage(&self, hit: &FileHit) -> Option<String> {
        let start = hit.seconds.filter(|_| hit.is_moment())?;
        let settings = self.shared.settings();
        if self.shared.recording_active.load(Ordering::Relaxed) {
            return None;
        }
        // Never downloads: the model must already be on this computer.
        let needs = self.models.dictation_requirements();
        if !self.models.missing(&needs).is_empty() || self.models.transcription_server_blocked() {
            return None;
        }
        let modified = std::fs::metadata(&hit.path)
            .and_then(|m| m.modified())
            .ok()
            .and_then(|at| at.duration_since(std::time::UNIX_EPOCH).ok())
            .map_or(0.0, |d| d.as_secs_f64());
        let key = format!("{}|{modified}|{}", hit.path, start as i64);
        if let Some(cached) = self.cache.lock().words.get(&key) {
            return (!cached.is_empty()).then(|| cached.clone());
        }
        let samples = media::sound_clip(Path::new(&hit.path), start, WINDOW_SECONDS)?;
        let language = (settings.transcription_language != "auto")
            .then(|| settings.transcription_language.clone());
        let result =
            self.shared
                .speech
                .with(&self.shared, &settings.transcription_model, |transcriber| {
                    let segments =
                        transcriber.transcribe_samples(&samples, language.as_deref(), None)?;
                    Ok(segments
                        .into_iter()
                        .map(|segment| segment.text)
                        .collect::<Vec<_>>()
                        .join(" "))
                });
        match result {
            Ok(text) => {
                let text = text.trim().to_string();
                self.cache.lock().remember(key, text.clone());
                (!text.is_empty()).then_some(text)
            }
            Err(err) => {
                log::warn!("file search: could not transcribe a moment: {err:#}");
                None
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_cache_forgets_the_oldest() {
        let mut cache = Cache::default();
        for i in 0..(CACHE_LIMIT + 1) {
            cache.remember(format!("k{i}"), "x".into());
        }
        assert_eq!(cache.words.len(), CACHE_LIMIT);
        assert!(!cache.words.contains_key("k0"));
        assert!(cache.words.contains_key("k1"));
    }
}
