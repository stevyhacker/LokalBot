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
    /// [`Self::finish_runtime_update`] is at work, including between retries.
    runtime_updating: Arc<AtomicBool>,
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
            runtime_updating: Arc::new(AtomicBool::new(false)),
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

    /// Counts `id` as downloading without fetching anything, so a test can
    /// hold a caller at "waiting for the model".
    #[cfg(test)]
    pub(crate) fn pretend_downloading(&self, id: &str) {
        self.active
            .lock()
            .insert(id.to_string(), Arc::new(AtomicBool::new(false)));
    }

    /// How far the first running download among `ids` is. `Some(None)` is one
    /// that hasn't reported yet; `None` means nothing is downloading.
    pub fn download_progress(&self, ids: &[String]) -> Option<Option<f32>> {
        let id = ids.iter().find(|id| self.is_downloading(id))?;
        Some(self.progress.lock().get(id).copied())
    }

    /// [`Self::ensure`] for a download the user asked for, so the llama.cpp
    /// runtime is the one they chose. Fails with why `ids` are not installed.
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
    /// A download someone else started is waited for, and `Ok(true)` means
    /// every id is installed.
    pub fn ensure(&self, ids: &[String], allow_download: bool) -> Result<bool> {
        let missing = self.missing(ids);
        if missing.is_empty() {
            return Ok(true);
        }
        if !allow_download {
            return Ok(false);
        }
        // Nobody asked to set up CUDA here, so built-in models get what they
        // run on until they do.
        install_all(
            &missing,
            |id| self.is_downloading(id),
            |id| self.is_installed(id),
            |id| self.download_tracked(id, false),
            || std::thread::sleep(std::time::Duration::from_millis(200)),
        )?;
        Ok(true)
    }

    /// Run at launch. An app update can move to another llama.cpp build, and
    /// every feature counts the runtime as missing until it's there. Someone
    /// who had set it up shouldn't have to find that out, so this fetches the
    /// new build in the background, keeps trying when that fails, and removes
    /// what the older versions installed once it's there. CUDA stays an
    /// explicit download; built-in models run on Vulkan or CPU until then.
    pub fn finish_runtime_update(&self) {
        if !self.shared.runtime.has_other_builds() {
            return;
        }
        self.runtime_updating.store(true, Ordering::Release);
        let this = self.clone();
        let spawned = std::thread::Builder::new()
            .name("lokalbot-runtime-update".into())
            .spawn(move || {
                this.update_runtime();
                this.runtime_updating.store(false, Ordering::Release);
            });
        if let Err(err) = spawned {
            self.runtime_updating.store(false, Ordering::Release);
            log::warn!("could not start the llama.cpp update: {err}");
        }
    }

    /// [`Self::finish_runtime_update`] may still bring the runtime. For work
    /// that checks for it once per launch.
    pub fn runtime_updating(&self) -> bool {
        self.runtime_updating.load(Ordering::Acquire)
    }

    fn update_runtime(&self) {
        let runtime = &self.shared.runtime;
        let pending = || runtime.update_pending() && !self.shared.is_shutting_down();
        retry_runtime_update(
            pending,
            || self.download_tracked(RUNTIME_ID, false),
            |delay| {
                let started = std::time::Instant::now();
                while started.elapsed() < delay && pending() {
                    std::thread::sleep(std::time::Duration::from_secs(5));
                }
            },
        );
        if runtime.remove_other_builds() {
            self.shared.message(
                "LokalBot updated llama.cpp. Set up CUDA again in Settings → Models. \
                 Built-in models use Vulkan or CPU until then.",
            );
        }
        self.publish_status();
    }

    pub fn cancel(&self, id: &str) {
        if let Some(flag) = self.active.lock().get(id) {
            flag.store(true, Ordering::Relaxed);
        }
    }

    pub fn delete(&self, id: &str) {
        let paths = self.shared.library.paths().clone();
        let result = match Self::resolve(id) {
            // With its digest sidecar: a sidecar left behind would vouch for
            // whatever file is put at that path later.
            Some(ModelRef::Gguf(entry)) => {
                lokalbot_ai::catalog::delete_model(&paths, entry).map_err(anyhow::Error::from)
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
        self.download_tracked(id, true)
    }

    /// With `explicit` false, the llama.cpp runtime is what built-in models
    /// run on, never CUDA.
    fn download_tracked(&self, id: &str, explicit: bool) -> Result<()> {
        let cancel = Arc::new(AtomicBool::new(false));
        {
            let mut active = self.active.lock();
            if active.contains_key(id) {
                return Ok(());
            }
            active.insert(id.to_string(), cancel.clone());
        }
        let result = self.download_inner(id, &cancel, explicit);
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

    fn download_inner(&self, id: &str, cancel: &AtomicBool, explicit: bool) -> Result<()> {
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
                let runtime = &self.shared.runtime;
                if explicit {
                    runtime.ensure_runtime(&settings, cancel, &mut progress)
                } else {
                    runtime.install_for_built_in_models(&settings, cancel, &mut progress)
                }
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

/// How long to wait after a failed runtime update. Offline at launch is the
/// usual reason, and an app can stay open for days.
fn runtime_update_delay(failures: u32) -> std::time::Duration {
    std::time::Duration::from_secs(match failures {
        0 | 1 => 60,
        2 => 5 * 60,
        3 => 15 * 60,
        _ => 60 * 60,
    })
}

/// Tries until nothing is pending. Cancelling in Settings ends it for this
/// launch; a failure is only logged, since nobody asked for this download.
fn retry_runtime_update(
    pending: impl Fn() -> bool,
    mut fetch: impl FnMut() -> Result<()>,
    mut wait: impl FnMut(std::time::Duration),
) {
    let mut failures = 0;
    while pending() {
        match fetch() {
            Ok(()) => return,
            Err(err) if format!("{err:#}").contains("cancelled") => return,
            Err(err) => log::warn!("updating the llama.cpp runtime failed: {err:#}"),
        }
        failures += 1;
        wait(runtime_update_delay(failures));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::{Cell, RefCell};

    fn ids(names: &[&str]) -> Vec<String> {
        names.iter().map(|name| name.to_string()).collect()
    }

    #[test]
    fn a_failed_runtime_update_is_tried_again_later() {
        let attempts = Cell::new(0);
        let mut waits = Vec::new();
        retry_runtime_update(
            || true,
            || {
                attempts.set(attempts.get() + 1);
                if attempts.get() < 5 {
                    Err(anyhow!("network unreachable"))
                } else {
                    Ok(())
                }
            },
            |delay| waits.push(delay.as_secs()),
        );
        assert_eq!(attempts.get(), 5);
        assert_eq!(waits, [60, 300, 900, 3600]);
    }

    #[test]
    fn cancelling_a_runtime_update_ends_it_for_this_launch() {
        let attempts = Cell::new(0);
        retry_runtime_update(
            || true,
            || {
                attempts.set(attempts.get() + 1);
                Err(anyhow!("download cancelled"))
            },
            |_| panic!("waited after a cancel"),
        );
        assert_eq!(attempts.get(), 1);
    }

    #[test]
    fn a_runtime_update_stops_once_nothing_is_pending() {
        let attempts = Cell::new(0);
        retry_runtime_update(
            || attempts.get() < 2,
            || {
                attempts.set(attempts.get() + 1);
                Err(anyhow!("network unreachable"))
            },
            |_| {},
        );
        assert_eq!(attempts.get(), 2, "someone set it up meanwhile, or quit");
    }

    /// A library an older LokalBot used, with this build's CPU archive already
    /// in the download folder, so these tests fetch nothing.
    #[cfg(unix)]
    fn updated_library(
        backend: &str,
        older: &str,
    ) -> (
        tempfile::TempDir,
        Models,
        std::path::PathBuf,
        Arc<Mutex<Vec<EngineEvent>>>,
    ) {
        let dir = tempfile::tempdir().unwrap();
        let library =
            lokalbot_core::Library::open(lokalbot_core::LibraryPaths::new(dir.path())).unwrap();
        let settings = lokalbot_core::Settings {
            llama_backend: backend.into(),
            ..Default::default()
        };
        let root = library.paths().runtimes_dir().join("llama-cpp");
        let folder = root.join(older);
        std::fs::create_dir_all(&folder).unwrap();
        std::fs::write(folder.join("install.json"), b"{}").unwrap();
        std::fs::write(
            root.join("backend.json"),
            br#"{"build":"b11669","backend":"cpu"}"#,
        )
        .unwrap();

        let asset = lokalbot_ai::runtime::asset(lokalbot_ai::runtime::LlamaBackend::Cpu).unwrap();
        let downloads = root.join(".downloads");
        std::fs::create_dir_all(&downloads).unwrap();
        let archive = downloads.join(asset.name);
        let mut builder = tar::Builder::new(flate2::write::GzEncoder::new(
            std::fs::File::create(&archive).unwrap(),
            flate2::Compression::fast(),
        ));
        let script = b"#!/bin/sh\necho 'version: test'\n";
        let mut header = tar::Header::new_gnu();
        header.set_size(script.len() as u64);
        header.set_mode(0o755);
        builder
            .append_data(&mut header, "upstream/llama-server", script.as_slice())
            .unwrap();
        let file = builder.into_inner().unwrap().finish().unwrap();
        file.set_len(asset.size).unwrap();
        lokalbot_ai::download::write_sidecar(&archive, asset.sha256).unwrap();

        let events = Arc::new(Mutex::new(Vec::new()));
        let seen = events.clone();
        let shared = Shared::for_tests(library, settings, move |event| seen.lock().push(event));
        (dir, Models::new(shared), folder, events)
    }

    #[cfg(unix)]
    fn wait_for_update(models: &Models) {
        let started = std::time::Instant::now();
        while models.runtime_updating() {
            assert!(started.elapsed().as_secs() < 60, "the update never ended");
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
    }

    #[cfg(unix)]
    fn messages(events: &Mutex<Vec<EngineEvent>>) -> Vec<String> {
        events
            .lock()
            .iter()
            .filter_map(|event| match event {
                EngineEvent::Message { text, .. } => Some(text.clone()),
                _ => None,
            })
            .collect()
    }

    /// The upgrade check: without [`Models::finish_runtime_update`], think,
    /// search and on-device autocomplete all stay unavailable after an update.
    #[test]
    #[cfg(unix)]
    fn launching_after_an_update_brings_the_runtime_back() {
        let (_dir, models, older, events) = updated_library("auto", "b11669-ubuntu-x64");
        assert!(!models.is_installed(RUNTIME_ID));

        models.finish_runtime_update();
        wait_for_update(&models);

        assert!(models.is_installed(RUNTIME_ID));
        assert!(!older.exists());
        assert!(!models.shared.runtime.has_other_builds());
        assert_eq!(messages(&events), Vec::<String>::new());
    }

    #[test]
    #[cfg(unix)]
    fn an_update_tells_someone_on_cuda_to_set_it_up_again() {
        let (_dir, models, older, events) = updated_library("cuda", "b11669-ubuntu-cuda-13.4-x64");

        models.finish_runtime_update();
        wait_for_update(&models);

        assert!(models.is_installed(RUNTIME_ID), "built-in models work");
        assert_eq!(models.shared.runtime.installed_backend(), None);
        assert!(!older.exists());
        let told = messages(&events);
        assert_eq!(told.len(), 1, "{told:?}");
        assert!(told[0].contains("Set up CUDA again"), "{told:?}");
    }

    #[test]
    #[cfg(unix)]
    fn background_work_never_starts_a_cuda_download() {
        let (_dir, models, _older, _events) = updated_library("cuda", "b11669-ubuntu-x64");

        // Only the CPU archive is there; a CUDA download would fail this.
        assert!(models.ensure(&ids(&[RUNTIME_ID]), true).unwrap());

        assert!(models.is_installed(RUNTIME_ID));
        assert_eq!(models.shared.runtime.installed_backend(), None);
    }

    /// Processing a meeting while Settings was downloading the same model
    /// went on without it, and the job failed.
    #[test]
    #[cfg(unix)]
    fn ensure_waits_for_a_download_someone_else_started() {
        let (_dir, models, _older, _events) = updated_library("auto", "b11669-ubuntu-x64");
        models.pretend_downloading(RUNTIME_ID);
        // That download ends without installing anything.
        let other = {
            let models = models.clone();
            std::thread::spawn(move || {
                std::thread::sleep(std::time::Duration::from_millis(300));
                models.active.lock().remove(RUNTIME_ID);
            })
        };

        assert!(models.ensure(&ids(&[RUNTIME_ID]), true).unwrap());

        assert!(models.is_installed(RUNTIME_ID));
        other.join().unwrap();
    }

    #[test]
    fn deleting_a_model_removes_its_digest_sidecar() {
        let dir = tempfile::tempdir().unwrap();
        let library =
            lokalbot_core::Library::open(lokalbot_core::LibraryPaths::new(dir.path())).unwrap();
        let shared = Shared::for_tests(library, Default::default(), |_| {});
        let entry = lokalbot_ai::catalog::all_entries().next().unwrap();
        let path = lokalbot_ai::catalog::model_path(shared.library.paths(), entry);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, b"GGUF").unwrap();
        lokalbot_ai::download::write_sidecar(&path, entry.sha256).unwrap();
        let sidecar = lokalbot_ai::download::sidecar_path(&path);
        assert!(sidecar.exists());

        Models::new(shared).delete(entry.id);

        assert!(!path.exists());
        assert!(!sidecar.exists());
    }

    #[test]
    fn nothing_starts_at_launch_without_an_older_runtime() {
        let dir = tempfile::tempdir().unwrap();
        let library =
            lokalbot_core::Library::open(lokalbot_core::LibraryPaths::new(dir.path())).unwrap();
        let shared = Shared::for_tests(library, Default::default(), |_| {});
        let models = Models::new(shared);
        models.finish_runtime_update();
        assert!(!models.runtime_updating());
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
