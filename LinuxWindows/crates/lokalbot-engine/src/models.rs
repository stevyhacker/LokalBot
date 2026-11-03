//! Which models are installed, and downloading the ones a feature needs.
//!
//! Ids are shared with the UI: GGUF catalog ids (`qwen3.5-4b`), speech model
//! ids (`qwen3-asr-0.6b`), `llama-runtime` for the llama.cpp binaries, and
//! `ocrs-text` and `tesseract-languages` for screen text recognition.

use std::collections::HashMap;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use anyhow::{Context as _, Result, anyhow};
use parking_lot::Mutex;

use lokalbot_core::settings::SummarizerBackend;

use crate::{BackgroundItem, BackgroundKind, DownloadUpdate, EngineEvent, ModelStatus, Shared};

pub const RUNTIME_ID: &str = "llama-runtime";

#[derive(Clone)]
pub struct Models {
    shared: Arc<Shared>,
    active: Arc<Mutex<HashMap<String, Arc<AtomicBool>>>>,
    /// How far each running download is, 0–1.
    progress: Arc<Mutex<HashMap<String, f32>>>,
}

enum ModelRef {
    Gguf(&'static lokalbot_ai::catalog::ModelEntry),
    Speech(&'static lokalbot_speech::models::SpeechModel),
    Runtime,
    Ocr,
    OcrLanguages,
}

impl Models {
    pub fn new(shared: Arc<Shared>) -> Self {
        Self {
            shared,
            active: Arc::new(Mutex::new(HashMap::new())),
            progress: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    fn resolve(id: &str) -> Option<ModelRef> {
        if id == RUNTIME_ID {
            return Some(ModelRef::Runtime);
        }
        if id == lokalbot_ai::ocr::OCR_MODEL_ID {
            return Some(ModelRef::Ocr);
        }
        if id == lokalbot_ai::ocr::OCR_LANGUAGES_ID {
            return Some(ModelRef::OcrLanguages);
        }
        if let Some(entry) = lokalbot_ai::catalog::entry(id) {
            return Some(ModelRef::Gguf(entry));
        }
        lokalbot_speech::models::find(id).map(ModelRef::Speech)
    }

    pub fn is_installed(&self, id: &str) -> bool {
        let paths = self.shared.library.paths();
        match Self::resolve(id) {
            Some(ModelRef::Gguf(entry)) => lokalbot_ai::catalog::is_downloaded(paths, entry),
            Some(ModelRef::Speech(model)) => lokalbot_speech::models::is_installed(paths, model),
            Some(ModelRef::Runtime) => self.shared.runtime.usable_backend().is_some(),
            Some(ModelRef::Ocr) => lokalbot_ai::ocr::is_installed(paths),
            Some(ModelRef::OcrLanguages) => lokalbot_ai::ocr::status(paths)
                .download
                .is_none_or(|download| download.id != lokalbot_ai::ocr::OCR_LANGUAGES_ID),
            None => false,
        }
    }

    /// A transcription server has nothing to download; it needs the approval
    /// [`Self::transcription_server_blocked`] checks.
    fn transcription_ids(settings: &lokalbot_core::Settings) -> Vec<String> {
        if lokalbot_speech::models::is_remote(&settings.transcription_model) {
            Vec::new()
        } else {
            vec![settings.transcription_model.clone()]
        }
    }

    /// The chosen transcription server isn't set up or may not receive audio yet.
    pub fn transcription_server_blocked(&self) -> bool {
        let settings = self.shared.settings();
        lokalbot_speech::models::is_remote(&settings.transcription_model)
            && !lokalbot_core::remote_transcription::RemoteTranscription::from_settings(&settings)
                .is_ready()
    }

    /// Ids the current settings need for meeting processing.
    pub fn meeting_requirements(&self, summarize: bool) -> Vec<String> {
        let settings = self.shared.settings();
        let mut ids = Self::transcription_ids(&settings);
        ids.extend(lokalbot_speech::models::supporting_ids(
            settings.multi_speaker_diarization,
        ));
        if summarize {
            ids.extend(self.think_requirements());
        }
        ids
    }

    /// Ids the Think role needs: the built-in model and runtime, or nothing
    /// for an external server.
    pub fn think_requirements(&self) -> Vec<String> {
        let settings = self.shared.settings();
        match settings.summarizer_backend {
            SummarizerBackend::BuiltIn => {
                vec![settings.built_in_model_id.clone(), RUNTIME_ID.to_string()]
            }
            _ => Vec::new(),
        }
    }

    pub fn embedding_requirements(&self) -> Vec<String> {
        vec![
            lokalbot_ai::catalog::EMBEDDING_MODEL_ID.to_string(),
            RUNTIME_ID.to_string(),
        ]
    }

    /// Screen context reads text with OCR when accessibility has little. What
    /// that takes depends on this computer: maybe nothing at all.
    pub fn screen_requirements(&self) -> Vec<String> {
        let settings = self.shared.settings();
        if settings.screen_context_capture_mode == lokalbot_core::ScreenContextMode::ActivityOnly {
            return Vec::new();
        }
        lokalbot_ai::ocr::status(self.shared.library.paths())
            .download
            .map(|download| download.id.to_string())
            .into_iter()
            .collect()
    }

    pub fn dictation_requirements(&self) -> Vec<String> {
        let settings = self.shared.settings();
        let mut ids = Self::transcription_ids(&settings);
        ids.extend(lokalbot_speech::models::supporting_ids(false));
        ids
    }

    /// A download of `id` is running.
    pub fn is_downloading(&self, id: &str) -> bool {
        self.active.lock().contains_key(id)
    }

    /// How far the first running download among `ids` is. `Some(None)` is one
    /// that hasn't reported yet; `None` means nothing is downloading.
    pub fn download_progress(&self, ids: &[String]) -> Option<Option<f32>> {
        let id = ids.iter().find(|id| self.is_downloading(id))?;
        Some(self.progress.lock().get(id).copied())
    }

    /// [`Self::ensure`], for a caller that must end with `ids` installed: this
    /// also waits out a download someone else started, and fails with why not.
    pub fn ensure_installed(&self, ids: &[String]) -> Result<()> {
        install_all(
            ids,
            |id| self.is_downloading(id),
            |id| self.is_installed(id),
            |id| self.download_blocking(id),
            || std::thread::sleep(std::time::Duration::from_millis(200)),
        )
    }

    pub fn missing(&self, ids: &[String]) -> Vec<String> {
        ids.iter()
            .filter(|id| !self.is_installed(id))
            .cloned()
            .collect()
    }

    pub fn publish_status(&self) {
        let settings = self.shared.settings();
        let mut installed: Vec<String> = lokalbot_ai::catalog::all_entries()
            .filter(|entry| lokalbot_ai::catalog::is_downloaded(self.shared.library.paths(), entry))
            .map(|entry| entry.id.to_string())
            .collect();
        installed.extend(
            lokalbot_speech::models::all()
                .iter()
                .filter(|model| {
                    lokalbot_speech::models::is_installed(self.shared.library.paths(), model)
                })
                .map(|model| model.id.to_string()),
        );
        // Built-in models stay ready on Vulkan or CPU while a CUDA selection
        // waits for setup; `runtime_backend` reports the selected runtime.
        let runtime_backend = self.shared.runtime.installed_backend();
        if self.shared.runtime.usable_backend().is_some() {
            installed.push(RUNTIME_ID.to_string());
        }
        let screen_text = lokalbot_ai::ocr::status(self.shared.library.paths());
        if lokalbot_ai::ocr::is_installed(self.shared.library.paths()) {
            installed.push(lokalbot_ai::ocr::OCR_MODEL_ID.to_string());
        }
        if lokalbot_ai::ocr::has_language_data(self.shared.library.paths()) {
            installed.push(lokalbot_ai::ocr::OCR_LANGUAGES_ID.to_string());
        }
        let ready = |ids: Vec<String>| ids.iter().all(|id| installed.contains(id));
        let status = ModelStatus {
            transcription_ready: ready(self.dictation_requirements())
                && !self.transcription_server_blocked(),
            think_ready: ready(self.think_requirements()),
            // A server needs no download, only its setup finished.
            autocomplete_ready: match lokalbot_ai::autocomplete::server::route(&settings, None) {
                lokalbot_ai::autocomplete::server::Route::OnDevice => ready(vec![
                    settings.cotyping_built_in_model_id.clone(),
                    RUNTIME_ID.to_string(),
                ]),
                lokalbot_ai::autocomplete::server::Route::Server(_) => true,
                lokalbot_ai::autocomplete::server::Route::Unavailable(_) => false,
            },
            embeddings_ready: ready(self.embedding_requirements()),
            screen_text_ready: screen_text.is_ready(),
            screen_text,
            runtime_backend,
            runtime_needs_check: self.shared.runtime.runtime_needs_check(),
            runtime_storage: self.shared.runtime.storage(),
            installed,
        };
        self.shared.emit(EngineEvent::Models(status));
    }

    /// Downloads the models the current settings need, one after another.
    pub fn prepare_for_settings(&self) {
        let mut ids = self.meeting_requirements(true);
        if self.shared.settings().semantic_search_enabled {
            ids.extend(self.embedding_requirements());
        }
        ids.extend(self.screen_requirements());
        // Think and search both need the runtime; download it once.
        let mut seen = std::collections::HashSet::new();
        ids.retain(|id| seen.insert(id.clone()));
        let missing = self.missing(&ids);
        if missing.is_empty() {
            self.shared
                .message("Everything this setup needs is already on this PC.");
            return;
        }
        let this = self.clone();
        std::thread::spawn(move || {
            for id in missing {
                if let Err(err) = this.download_blocking(&id) {
                    if !err.to_string().contains("cancelled") {
                        this.shared
                            .error(format!("Downloading {id} failed: {err:#}"));
                    }
                    break;
                }
            }
        });
    }

    pub fn download(&self, id: &str) {
        let this = self.clone();
        let id = id.to_string();
        std::thread::spawn(move || {
            if let Err(err) = this.download_blocking(&id)
                && !err.to_string().contains("cancelled")
            {
                this.shared
                    .error(format!("Downloading {id} failed: {err:#}"));
            }
        });
    }

    /// Ensures the given ids are installed, downloading them when allowed.
    /// Returns `Ok(false)` when something is missing and downloads are not allowed.
    pub fn ensure(&self, ids: &[String], allow_download: bool) -> Result<bool> {
        let missing = self.missing(ids);
        if missing.is_empty() {
            return Ok(true);
        }
        if !allow_download {
            return Ok(false);
        }
        for id in missing {
            self.download_blocking(&id)?;
        }
        Ok(true)
    }

    pub fn cancel(&self, id: &str) {
        if let Some(flag) = self.active.lock().get(id) {
            flag.store(true, Ordering::Relaxed);
        }
    }

    pub fn delete(&self, id: &str) {
        let paths = self.shared.library.paths().clone();
        let result = match Self::resolve(id) {
            Some(ModelRef::Gguf(entry)) => {
                std::fs::remove_file(lokalbot_ai::catalog::model_path(&paths, entry))
                    .map_err(anyhow::Error::from)
            }
            Some(ModelRef::Speech(model)) => lokalbot_speech::models::uninstall(&paths, model),
            Some(ModelRef::Runtime) => self.shared.runtime.uninstall(),
            Some(ModelRef::Ocr) => lokalbot_ai::ocr::delete(&paths).map_err(anyhow::Error::from),
            Some(ModelRef::OcrLanguages) => {
                lokalbot_ai::ocr::delete_languages(&paths).map_err(anyhow::Error::from)
            }
            None => Err(anyhow!("unknown model {id}")),
        };
        if let Err(err) = result {
            self.shared.error(format!("Removing {id} failed: {err:#}"));
        }
        self.publish_status();
    }

    fn download_blocking(&self, id: &str) -> Result<()> {
        let cancel = Arc::new(AtomicBool::new(false));
        {
            let mut active = self.active.lock();
            if active.contains_key(id) {
                return Ok(());
            }
            active.insert(id.to_string(), cancel.clone());
        }
        let result = self.download_inner(id, &cancel);
        self.active.lock().remove(id);
        self.progress.lock().remove(id);
        self.shared.clear_background(&format!("download:{id}"));
        let error = result.as_ref().err().map(|err| format!("{err:#}"));
        self.shared.emit(EngineEvent::Download(DownloadUpdate {
            id: id.to_string(),
            done_bytes: 0,
            total_bytes: 0,
            finished: result.is_ok(),
            error,
        }));
        self.publish_status();
        result
    }

    fn download_inner(&self, id: &str, cancel: &AtomicBool) -> Result<()> {
        let paths = self.shared.library.paths().clone();
        let model = Self::resolve(id).with_context(|| format!("unknown model {id}"))?;
        let name = match &model {
            ModelRef::Gguf(entry) => entry.display_name.to_string(),
            ModelRef::Speech(model) => model.display_name.to_string(),
            ModelRef::Runtime => "the llama.cpp runtime".to_string(),
            ModelRef::Ocr => lokalbot_ai::ocr::OCR_DISPLAY_NAME.to_string(),
            ModelRef::OcrLanguages => lokalbot_ai::ocr::OCR_LANGUAGES_DISPLAY_NAME.to_string(),
        };
        let shared = self.shared.clone();
        let id_owned = id.to_string();
        let share = self.progress.clone();
        let mut last_emit = std::time::Instant::now() - std::time::Duration::from_secs(1);
        let mut progress = move |done: u64, total: u64| {
            if last_emit.elapsed() < std::time::Duration::from_millis(250) && done < total {
                return;
            }
            last_emit = std::time::Instant::now();
            let fraction = if total > 0 {
                done as f32 / total as f32
            } else {
                0.0
            };
            share.lock().insert(id_owned.clone(), fraction);
            shared.set_background(BackgroundItem {
                id: format!("download:{id_owned}"),
                kind: BackgroundKind::Download,
                title: format!("Downloading {name}"),
                detail: format!("{:.0}%", fraction * 100.0),
                progress: Some(fraction),
            });
            shared.emit(EngineEvent::Download(DownloadUpdate {
                id: id_owned.clone(),
                done_bytes: done,
                total_bytes: total,
                finished: false,
                error: None,
            }));
        };
        match model {
            ModelRef::Gguf(entry) => {
                let spec = lokalbot_ai::catalog::download_spec(&paths, entry);
                lokalbot_ai::download::download(&spec, cancel, &mut progress)
            }
            ModelRef::Speech(model) => {
                let info = lokalbot_speech::models::download_info(model);
                let spec = lokalbot_ai::download::DownloadSpec {
                    url: info.url,
                    sha256: info.sha256,
                    size: info.size,
                    dest: lokalbot_speech::models::download_dest(&paths, model),
                };
                if let Some(parent) = spec.dest.parent() {
                    std::fs::create_dir_all(parent)?;
                }
                lokalbot_ai::download::download(&spec, cancel, &mut progress)?;
                if info.archive {
                    let target = lokalbot_speech::models::model_dir(&paths, model);
                    lokalbot_ai::download::extract_archive(&spec.dest, &target)?;
                    let _ = std::fs::remove_file(&spec.dest);
                }
                lokalbot_speech::models::finish_install(&paths, model)
            }
            ModelRef::Runtime => {
                let settings = self.shared.settings();
                self.shared
                    .runtime
                    .ensure_runtime(&settings, cancel, &mut progress)
            }
            ModelRef::Ocr => lokalbot_ai::ocr::download(&paths, cancel, &mut progress),
            ModelRef::OcrLanguages => {
                lokalbot_ai::ocr::download_languages(&paths, cancel, &mut progress)
            }
        }
    }
}

fn install_all(
    ids: &[String],
    downloading: impl Fn(&str) -> bool,
    installed: impl Fn(&str) -> bool,
    download: impl Fn(&str) -> Result<()>,
    wait: impl Fn(),
) -> Result<()> {
    for id in ids {
        while downloading(id) {
            wait();
        }
        if !installed(id) {
            download(id)?;
        }
        if !installed(id) {
            return Err(anyhow!("{id} is not installed"));
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::{Cell, RefCell};

    fn ids(names: &[&str]) -> Vec<String> {
        names.iter().map(|name| name.to_string()).collect()
    }

    #[test]
    fn a_missing_model_downloads_and_an_installed_one_does_not() {
        let installed = RefCell::new(vec!["vad".to_string()]);
        let downloads = RefCell::new(Vec::new());
        install_all(
            &ids(&["vad", "asr"]),
            |_| false,
            |id| installed.borrow().iter().any(|known| known == id),
            |id| {
                downloads.borrow_mut().push(id.to_string());
                installed.borrow_mut().push(id.to_string());
                Ok(())
            },
            || {},
        )
        .unwrap();
        assert_eq!(*downloads.borrow(), ["asr"]);
    }

    #[test]
    fn a_download_already_running_is_waited_for_not_repeated() {
        let waits = Cell::new(0);
        install_all(
            &ids(&["asr"]),
            |_| waits.get() < 3,
            |_| waits.get() >= 3,
            |_| panic!("the running download finishes it"),
            || waits.set(waits.get() + 1),
        )
        .unwrap();
        assert_eq!(waits.get(), 3);
    }

    #[test]
    fn a_failed_or_empty_download_is_an_error() {
        let failed = install_all(
            &ids(&["asr"]),
            |_| false,
            |_| false,
            |_| Err(anyhow!("no network")),
            || {},
        );
        assert_eq!(failed.unwrap_err().to_string(), "no network");
        let empty = install_all(&ids(&["asr"]), |_| false, |_| false, |_| Ok(()), || {});
        assert_eq!(empty.unwrap_err().to_string(), "asr is not installed");
    }
}
