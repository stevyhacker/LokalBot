//! Speech model catalog: transcription models plus voice activity detection
//! and speaker separation, all sherpa-onnx exports pinned by URL, size and
//! SHA-256 (GitHub release assets of `k2-fsa/sherpa-onnx`).
//!
//! Each model is one download: a `.tar.bz2` archive extracted into
//! [`model_dir`], or a single file saved straight into it. The engine
//! downloads [`download_info`] to [`download_dest`], extracts archives into
//! `model_dir`, then calls [`finish_install`], which flattens the archive's
//! top folder, checks the files and writes the install marker.

use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail};
use lokalbot_core::LibraryPaths;
use serde::{Deserialize, Serialize};

const MARKER: &str = ".lokalbot-installed.json";

/// How a transcription model decodes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Family {
    /// Qwen3-ASR: conv front end + encoder + LLM decoder; takes a language and hotwords per span.
    Qwen3Asr,
    /// NeMo transducer (Parakeet TDT); token timestamps, automatic language.
    NemoTransducer,
    /// SenseVoice CTC; language fixed per recognizer.
    SenseVoice,
    /// Whisper encoder/decoder; language fixed per recognizer, 30 s windows.
    Whisper,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ModelKind {
    Transcription(Family),
    VoiceActivity,
    SpeakerSegmentation,
    SpeakerEmbedding,
}

/// One pinned download.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct DownloadInfo {
    pub url: &'static str,
    pub sha256: &'static str,
    pub size: u64,
    /// Top folder inside a `.tar.bz2`; `None` for a single file.
    pub archive_root: Option<&'static str>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SpeechModel {
    /// Stable id stored in settings (`transcriptionModel`) and used for the folder name.
    pub id: &'static str,
    pub display_name: &'static str,
    pub kind: ModelKind,
    /// ISO 639 codes the model transcribes (empty for support models).
    pub languages: &'static [&'static str],
    pub archive: DownloadInfo,
    /// Files that must exist in the model folder once installed.
    pub files: &'static [&'static str],
    /// Short description for the model picker.
    pub summary: &'static str,
    pub license: &'static str,
    /// Uses the vocabulary prompt (names and terms) as decoding context.
    pub supports_prompt: bool,
}

impl SpeechModel {
    pub fn family(&self) -> Option<Family> {
        match self.kind {
            ModelKind::Transcription(family) => Some(family),
            _ => None,
        }
    }

    pub fn is_transcription(&self) -> bool {
        self.family().is_some()
    }

    pub fn supports_language(&self, code: &str) -> bool {
        self.languages.contains(&code)
    }
}

/// Qwen3-ASR's languages (model card), as ISO codes.
const QWEN3_LANGUAGES: &[&str] = &[
    "zh", "en", "yue", "ar", "de", "fr", "es", "pt", "id", "it", "ko", "ru", "th", "vi", "ja",
    "tr", "hi", "ms", "nl", "sv", "da", "fi", "pl", "cs", "fil", "fa", "el", "hu", "mk", "ro",
];
const PARAKEET_V3_LANGUAGES: &[&str] = &[
    "bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it", "lv", "lt", "mt",
    "pl", "pt", "ro", "sk", "sl", "es", "sv", "ru", "uk",
];
const SENSE_VOICE_LANGUAGES: &[&str] = &["zh", "en", "ja", "ko", "yue"];
/// Whisper covers ~100 languages; these are the ones the language picker offers.
const WHISPER_LANGUAGES: &[&str] = &[
    "en", "de", "es", "fr", "it", "nl", "pt", "pl", "sv", "da", "no", "tr", "ru", "sr", "zh",
    "yue", "ja", "ko", "ar", "hi", "th", "vi",
];

pub const DEFAULT_TRANSCRIPTION_MODEL: &str = "qwen3-asr-0.6b";
pub const VAD_MODEL: &str = "silero-vad";
pub const SEGMENTATION_MODEL: &str = "pyannote-segmentation-3.0";
pub const EMBEDDING_MODEL: &str = "speaker-titanet-small";

static MODELS: [SpeechModel; 7] = [
    SpeechModel {
        id: DEFAULT_TRANSCRIPTION_MODEL,
        display_name: "Qwen3-ASR 0.6B",
        kind: ModelKind::Transcription(Family::Qwen3Asr),
        languages: QWEN3_LANGUAGES,
        archive: DownloadInfo {
            url: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25.tar.bz2",
            sha256: "393f8a14e2f5fb96746aaab342997a40641001fbd5bf9592a080a8329178ee96",
            size: 878_702_423,
            archive_root: Some("sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25"),
        },
        files: &[
            "conv_frontend.onnx",
            "encoder.int8.onnx",
            "decoder.int8.onnx",
            "tokenizer/vocab.json",
            "tokenizer/merges.txt",
            "tokenizer/tokenizer_config.json",
        ],
        summary: "30 languages and 22 Chinese dialects. Uses meeting names and terms as hints.",
        license: "Apache-2.0",
        supports_prompt: true,
    },
    SpeechModel {
        id: "parakeet-v3",
        display_name: "Parakeet TDT 0.6B v3",
        kind: ModelKind::Transcription(Family::NemoTransducer),
        languages: PARAKEET_V3_LANGUAGES,
        archive: DownloadInfo {
            url: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8.tar.bz2",
            sha256: "5793d0fd397c5778d2cf2126994d58e9d56b1be7c04d13c7a15bb1b4eafb16bf",
            size: 487_170_055,
            archive_root: Some("sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8"),
        },
        files: &[
            "encoder.int8.onnx",
            "decoder.int8.onnx",
            "joiner.int8.onnx",
            "tokens.txt",
        ],
        summary: "Fast, with word timings. 25 European languages, detected automatically.",
        license: "CC-BY-4.0",
        supports_prompt: false,
    },
    SpeechModel {
        id: "sense-voice",
        display_name: "SenseVoice (zh/ja/ko/yue/en)",
        kind: ModelKind::Transcription(Family::SenseVoice),
        languages: SENSE_VOICE_LANGUAGES,
        archive: DownloadInfo {
            url: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09.tar.bz2",
            sha256: "7305f7905bfcf77fa0b39388a313f3da35c68d971661a65475b56fb2162c8e63",
            size: 165_783_878,
            archive_root: Some("sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09"),
        },
        files: &["model.int8.onnx", "tokens.txt"],
        summary: "Chinese, Japanese, Korean, Cantonese and English. Very fast.",
        license: "FunASR Model License",
        supports_prompt: false,
    },
    SpeechModel {
        id: "whisper-large-v3-turbo",
        display_name: "Whisper large-v3 turbo",
        kind: ModelKind::Transcription(Family::Whisper),
        languages: WHISPER_LANGUAGES,
        archive: DownloadInfo {
            url: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-whisper-turbo.tar.bz2",
            sha256: WHISPER_TURBO_SHA256,
            size: 563_790_207,
            archive_root: Some("sherpa-onnx-whisper-turbo"),
        },
        files: &[
            "turbo-encoder.int8.onnx",
            "turbo-decoder.int8.onnx",
            "turbo-tokens.txt",
        ],
        summary: "About 100 languages. Slower on most computers.",
        license: "MIT",
        supports_prompt: false,
    },
    SpeechModel {
        id: VAD_MODEL,
        display_name: "Silero VAD",
        kind: ModelKind::VoiceActivity,
        languages: &[],
        archive: DownloadInfo {
            url: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx",
            sha256: "9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6",
            size: 643_854,
            archive_root: None,
        },
        files: &["silero_vad.onnx"],
        summary: "Finds speech in recordings.",
        license: "MIT",
        supports_prompt: false,
    },
    SpeechModel {
        id: SEGMENTATION_MODEL,
        display_name: "Pyannote segmentation 3.0",
        kind: ModelKind::SpeakerSegmentation,
        languages: &[],
        archive: DownloadInfo {
            url: "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2",
            sha256: "24615ee884c897d9d2ba09bb4d30da6bb1b15e685065962db5b02e76e4996488",
            size: 6_958_444,
            archive_root: Some("sherpa-onnx-pyannote-segmentation-3-0"),
        },
        files: &["model.onnx"],
        summary: "Finds where each voice speaks.",
        license: "MIT",
        supports_prompt: false,
    },
    SpeechModel {
        id: EMBEDDING_MODEL,
        display_name: "NeMo TitaNet small",
        kind: ModelKind::SpeakerEmbedding,
        languages: &[],
        archive: DownloadInfo {
            url: "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/nemo_en_titanet_small.onnx",
            sha256: "ad4a1802485d8b34c722d2a9d04249662f2ece5d28a7a039063ca22f515a789e",
            size: 40_257_283,
            archive_root: None,
        },
        files: &["nemo_en_titanet_small.onnx"],
        summary: "Tells voices apart.",
        // NVIDIA's NGC card for titanet_small (the model sherpa-onnx
        // converted) puts it under the NeMo toolkit's license.
        license: "Apache-2.0",
        supports_prompt: false,
    },
];

/// Pinned after downloading the release asset (GitHub publishes no digest for it).
const WHISPER_TURBO_SHA256: &str =
    "b11acbbcd660b44a8e0df33724feb5aaa709cf65668f2823d59f656312544f22";

/// Every speech model: transcription models first, then VAD and speaker separation.
pub fn all() -> &'static [SpeechModel] {
    &MODELS
}

pub fn transcription_models() -> &'static [SpeechModel] {
    &MODELS[..4]
}

pub fn vad_model() -> &'static SpeechModel {
    &MODELS[4]
}

/// Segmentation and speaker-embedding models used for "Separate speakers".
pub fn diarization_models() -> &'static [SpeechModel] {
    &MODELS[5..7]
}

pub fn find(id: &str) -> Option<&'static SpeechModel> {
    MODELS.iter().find(|m| m.id == id)
}

/// Models a transcription needs besides the transcription model itself.
pub fn supporting_ids(diarize: bool) -> Vec<String> {
    let mut ids = vec![VAD_MODEL.to_string()];
    if diarize {
        ids.extend(diarization_models().iter().map(|m| m.id.to_string()));
    }
    ids
}

/// `<root>/models/speech/<id>/`.
pub fn model_dir(paths: &LibraryPaths, model: &SpeechModel) -> PathBuf {
    paths.models_dir().join("speech").join(model.id)
}

/// Absolute path of one of the model's files.
pub fn model_file(paths: &LibraryPaths, model: &SpeechModel, file: &str) -> PathBuf {
    let mut path = model_dir(paths, model);
    for part in file.split('/') {
        path.push(part);
    }
    path
}

pub fn is_archive(model: &SpeechModel) -> bool {
    model.archive.archive_root.is_some()
}

/// What to download for a model, for the engine's downloader.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ModelDownload {
    pub url: String,
    pub sha256: String,
    pub size: u64,
    /// A `.tar.bz2` to extract into [`model_dir`] (otherwise the file is the model).
    pub archive: bool,
}

pub fn download_info(model: &SpeechModel) -> ModelDownload {
    ModelDownload {
        url: model.archive.url.to_string(),
        sha256: model.archive.sha256.to_string(),
        size: model.archive.size,
        archive: is_archive(model),
    }
}

/// Where the download goes: archives into `<root>/models/speech/.downloads/`,
/// single files straight to their final path inside [`model_dir`].
pub fn download_dest(paths: &LibraryPaths, model: &SpeechModel) -> PathBuf {
    let name = model.archive.url.rsplit('/').next().unwrap_or(model.id);
    if is_archive(model) {
        paths
            .models_dir()
            .join("speech")
            .join(".downloads")
            .join(name)
    } else {
        model_file(paths, model, model.files.first().copied().unwrap_or(name))
    }
}

#[derive(Serialize, Deserialize)]
struct Marker {
    id: String,
    sha256: String,
}

/// Whether every file is present and the install marker matches the pinned download.
pub fn is_installed(paths: &LibraryPaths, model: &SpeechModel) -> bool {
    let dir = model_dir(paths, model);
    let marker = std::fs::read(dir.join(MARKER))
        .ok()
        .and_then(|bytes| serde_json::from_slice::<Marker>(&bytes).ok());
    marker.is_some_and(|m| m.id == model.id && m.sha256 == model.archive.sha256)
        && files_present(paths, model)
}

fn files_present(paths: &LibraryPaths, model: &SpeechModel) -> bool {
    model.files.iter().all(|file| {
        std::fs::metadata(model_file(paths, model, file)).is_ok_and(|m| m.is_file() && m.len() > 0)
    })
}

/// Finishes an install after the engine downloaded (and, for archives,
/// extracted) the model into [`model_dir`]: moves the archive's top folder
/// up, drops sample audio shipped with it, checks every file and writes the
/// marker [`is_installed`] looks for.
pub fn finish_install(paths: &LibraryPaths, model: &SpeechModel) -> Result<()> {
    let dir = model_dir(paths, model);
    std::fs::create_dir_all(&dir).with_context(|| format!("could not create {}", dir.display()))?;
    if let Some(root) = model.archive.archive_root {
        let nested = dir.join(root);
        if nested.is_dir() {
            flatten(&nested, &dir)?;
        }
    }
    let samples = dir.join("test_wavs");
    if samples.is_dir() {
        let _ = std::fs::remove_dir_all(&samples);
    }
    let missing: Vec<&str> = model
        .files
        .iter()
        .copied()
        .filter(|file| {
            !std::fs::metadata(model_file(paths, model, file))
                .is_ok_and(|m| m.is_file() && m.len() > 0)
        })
        .collect();
    if !missing.is_empty() {
        bail!(
            "{} is incomplete: missing {}",
            model.display_name,
            missing.join(", ")
        );
    }
    let marker = Marker {
        id: model.id.to_string(),
        sha256: model.archive.sha256.to_string(),
    };
    std::fs::write(dir.join(MARKER), serde_json::to_vec_pretty(&marker)?)
        .context("could not write the install marker")?;
    Ok(())
}

fn flatten(nested: &Path, dir: &Path) -> Result<()> {
    for entry in std::fs::read_dir(nested)? {
        let entry = entry?;
        let target = dir.join(entry.file_name());
        if target.is_dir() {
            std::fs::remove_dir_all(&target)?;
        } else if target.exists() {
            std::fs::remove_file(&target)?;
        }
        std::fs::rename(entry.path(), &target).with_context(|| {
            format!(
                "could not move {} into {}",
                entry.path().display(),
                dir.display()
            )
        })?;
    }
    std::fs::remove_dir(nested)?;
    Ok(())
}

/// Removes an installed model.
pub fn uninstall(paths: &LibraryPaths, model: &SpeechModel) -> Result<()> {
    let dir = model_dir(paths, model);
    if dir.exists() {
        std::fs::remove_dir_all(&dir)
            .with_context(|| format!("could not delete {}", dir.display()))?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    const RELEASES: &str = "https://github.com/k2-fsa/sherpa-onnx/releases/download";

    #[test]
    fn catalog_is_consistent() {
        let mut ids = std::collections::HashSet::new();
        for model in all() {
            assert!(ids.insert(model.id), "duplicate id {}", model.id);
            assert!(model.archive.url.starts_with(RELEASES), "{}", model.id);
            assert_eq!(model.archive.sha256.len(), 64, "{}", model.id);
            assert!(model.archive.size > 0);
            assert!(!model.files.is_empty());
            if let Some(root) = model.archive.archive_root {
                assert!(
                    model.archive.url.ends_with(&format!("/{root}.tar.bz2")),
                    "{}",
                    model.id
                );
            } else {
                assert!(model.archive.url.ends_with(model.files[0]), "{}", model.id);
            }
        }
        assert!(
            transcription_models()
                .iter()
                .all(SpeechModel::is_transcription)
        );
        assert_eq!(vad_model().kind, ModelKind::VoiceActivity);
        assert_eq!(
            find(DEFAULT_TRANSCRIPTION_MODEL).unwrap().display_name,
            "Qwen3-ASR 0.6B"
        );
        assert_eq!(supporting_ids(false), vec!["silero-vad"]);
        assert_eq!(supporting_ids(true).len(), 3);
    }

    #[test]
    fn install_flattens_archives_and_writes_a_marker() {
        let root = tempfile::tempdir().unwrap();
        let paths = LibraryPaths::new(root.path());
        let model = find("sense-voice").unwrap();
        assert!(download_dest(&paths, model).ends_with("models/speech/.downloads/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09.tar.bz2"));
        let nested = model_dir(&paths, model).join(model.archive.archive_root.unwrap());
        std::fs::create_dir_all(nested.join("test_wavs")).unwrap();
        std::fs::write(nested.join("model.int8.onnx"), b"onnx").unwrap();
        assert!(
            finish_install(&paths, model).is_err(),
            "tokens.txt is missing"
        );
        // The failed attempt already moved the files up; complete the folder.
        std::fs::write(model_dir(&paths, model).join("tokens.txt"), b"a 0").unwrap();
        finish_install(&paths, model).unwrap();
        assert!(is_installed(&paths, model));
        assert!(!model_dir(&paths, model).join("test_wavs").exists());

        let vad = vad_model();
        let dest = download_dest(&paths, vad);
        assert_eq!(dest, model_dir(&paths, vad).join("silero_vad.onnx"));
        std::fs::create_dir_all(dest.parent().unwrap()).unwrap();
        std::fs::write(&dest, b"vad").unwrap();
        assert!(!is_installed(&paths, vad));
        finish_install(&paths, vad).unwrap();
        assert!(is_installed(&paths, vad));
        uninstall(&paths, vad).unwrap();
        assert!(!is_installed(&paths, vad));
    }
}
