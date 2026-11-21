use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail};
use lokalbot_core::LibraryPaths;
use serde::{Deserialize, Serialize};

const MARKER: &str = ".lokalbot-installed.json";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Family {
    Qwen3Asr,
    NemoTransducer,
    SenseVoice,
    Whisper,
    NemoCtc,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ModelKind {
    Transcription(Family),
    VoiceActivity,
    SpeakerSegmentation,
    SpeakerEmbedding,
    SpeechSynthesis,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct DownloadInfo {
    pub url: &'static str,
    pub sha256: &'static str,
    pub size: u64,
    pub archive_root: Option<&'static str>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SpeechModel {
    pub id: &'static str,
    pub display_name: &'static str,
    pub kind: ModelKind,
    pub languages: &'static [&'static str],
    pub archive: DownloadInfo,
    pub files: &'static [&'static str],
    pub summary: &'static str,
    pub license: &'static str,
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

const QWEN3_LANGUAGES: &[&str] = &[
    "zh", "en", "yue", "ar", "de", "fr", "es", "pt", "id", "it", "ko", "ru", "th", "vi", "ja",
    "tr", "hi", "ms", "nl", "sv", "da", "fi", "pl", "cs", "fil", "fa", "el", "hu", "mk", "ro",
];
const PARAKEET_V3_LANGUAGES: &[&str] = &[
    "bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it", "lv", "lt", "mt",
    "pl", "pt", "ro", "sk", "sl", "es", "sv", "ru", "uk",
];
const SENSE_VOICE_LANGUAGES: &[&str] = &["zh", "en", "ja", "ko", "yue"];
const WHISPER_LANGUAGES: &[&str] = &[
    "en", "de", "es", "fr", "it", "nl", "pt", "pl", "sv", "da", "no", "tr", "ru", "uk", "sr", "zh",
    "yue", "ja", "ko", "ar", "hi", "th", "vi",
];

pub const DEFAULT_TRANSCRIPTION_MODEL: &str = "qwen3-asr-0.6b";
pub const VAD_MODEL: &str = "silero-vad";
pub const SEGMENTATION_MODEL: &str = "pyannote-segmentation-3.0";
pub const EMBEDDING_MODEL: &str = "speaker-titanet-small";
pub const KOKORO_MODEL: &str = "kokoro-82m";

static MODELS: [SpeechModel; 10] = [
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
            sha256: "1495e91b59d7fc53ddca91f3431758ec99f8fa253fdb0e1e851be0f72b14b0f9",
            size: 487_211_443,
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
        id: "parakeet-v2",
        display_name: "Parakeet TDT 0.6B v2",
        kind: ModelKind::Transcription(Family::NemoTransducer),
        languages: &["en"],
        archive: DownloadInfo {
            url: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8.tar.bz2",
            sha256: "6fc4426b54aa549a0019b8a75b8dea59164e71790a37ac56a045ad57f915f714",
            size: 482_440_461,
            archive_root: Some("sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8"),
        },
        files: &[
            "encoder.int8.onnx",
            "decoder.int8.onnx",
            "joiner.int8.onnx",
            "tokens.txt",
        ],
        summary: "English only, slightly higher recall.",
        license: "CC-BY-4.0",
        supports_prompt: false,
    },
    SpeechModel {
        id: "gigaam-russian",
        display_name: "GigaAM (Russian)",
        kind: ModelKind::Transcription(Family::NemoCtc),
        languages: &["ru"],
        archive: DownloadInfo {
            url: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-nemo-ctc-giga-am-v3-russian-2025-12-16.tar.bz2",
            sha256: "e1291d704460cab4a01716081170c86c12f6b15338a1534f71cc5956922adb52",
            size: 163_286_197,
            archive_root: Some("sherpa-onnx-nemo-ctc-giga-am-v3-russian-2025-12-16"),
        },
        files: &["model.int8.onnx", "tokens.txt"],
        summary: "Russian only.",
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
        license: "Apache-2.0",
        supports_prompt: false,
    },
    SpeechModel {
        id: KOKORO_MODEL,
        display_name: "Kokoro 82M",
        kind: ModelKind::SpeechSynthesis,
        languages: &[],
        archive: DownloadInfo {
            url: "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/kokoro-multi-lang-v1_0.tar.bz2",
            sha256: "60703707bc05ccd48d60e1eb723f38b07d6e474795a0b6a588d7220400e0f7a4",
            size: 349_886_476,
            archive_root: Some("kokoro-multi-lang-v1_0"),
        },
        files: &[
            "model.onnx",
            "voices.bin",
            "tokens.txt",
            "lexicon-us-en.txt",
            "lexicon-zh.txt",
            "espeak-ng-data/phontab",
        ],
        summary: "Reads summaries and answers aloud.",
        license: "Apache-2.0",
        supports_prompt: false,
    },
];

const WHISPER_TURBO_SHA256: &str =
    "b11acbbcd660b44a8e0df33724feb5aaa709cf65668f2823d59f656312544f22";

pub fn all() -> &'static [SpeechModel] {
    &MODELS
}

pub fn transcription_models() -> &'static [SpeechModel] {
    &MODELS[..6]
}

pub fn vad_model() -> &'static SpeechModel {
    &MODELS[6]
}

pub fn diarization_models() -> &'static [SpeechModel] {
    &MODELS[7..9]
}

pub fn kokoro_model() -> &'static SpeechModel {
    &MODELS[9]
}

pub fn find(id: &str) -> Option<&'static SpeechModel> {
    MODELS.iter().find(|m| m.id == id)
}

pub fn is_remote(id: &str) -> bool {
    id == lokalbot_core::remote_transcription::MODEL_ID
}

pub fn accepts_vocabulary(id: &str) -> bool {
    is_remote(id) || find(id).is_some_and(|model| model.supports_prompt)
}

pub fn supporting_ids(diarize: bool) -> Vec<String> {
    let mut ids = vec![VAD_MODEL.to_string()];
    if diarize {
        ids.extend(diarization_models().iter().map(|m| m.id.to_string()));
    }
    ids
}

pub fn model_dir(paths: &LibraryPaths, model: &SpeechModel) -> PathBuf {
    paths.models_dir().join("speech").join(model.id)
}

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

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ModelDownload {
    pub url: String,
    pub sha256: String,
    pub size: u64,
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

fn earlier_archives(model: &SpeechModel) -> &'static [&'static str] {
    match model.id {
        "parakeet-v3" => &["5793d0fd397c5778d2cf2126994d58e9d56b1be7c04d13c7a15bb1b4eafb16bf"],
        "parakeet-v2" => &["157c157bc51155e03e37d2466522a3a737dd9c72bb25f36eb18912964161e1ad"],
        _ => &[],
    }
}

pub fn is_installed(paths: &LibraryPaths, model: &SpeechModel) -> bool {
    let dir = model_dir(paths, model);
    let marker = std::fs::read(dir.join(MARKER))
        .ok()
        .and_then(|bytes| serde_json::from_slice::<Marker>(&bytes).ok());
    marker.is_some_and(|m| {
        m.id == model.id
            && (m.sha256 == model.archive.sha256
                || earlier_archives(model).contains(&m.sha256.as_str()))
    }) && files_present(paths, model)
}

fn files_present(paths: &LibraryPaths, model: &SpeechModel) -> bool {
    model.files.iter().all(|file| {
        std::fs::metadata(model_file(paths, model, file)).is_ok_and(|m| m.is_file() && m.len() > 0)
    })
}

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
        assert_eq!(kokoro_model().kind, ModelKind::SpeechSynthesis);
        assert_eq!(
            find(DEFAULT_TRANSCRIPTION_MODEL).unwrap().display_name,
            "Qwen3-ASR 0.6B"
        );
        assert_eq!(supporting_ids(false), vec!["silero-vad"]);
        assert_eq!(supporting_ids(true).len(), 3);
    }

    fn installed_from(paths: &LibraryPaths, model: &SpeechModel, sha256: &str) {
        for file in model.files {
            let path = model_file(paths, model, file);
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(path, b"onnx").unwrap();
        }
        let marker = Marker {
            id: model.id.to_string(),
            sha256: sha256.to_string(),
        };
        std::fs::write(
            model_dir(paths, model).join(MARKER),
            serde_json::to_vec(&marker).unwrap(),
        )
        .unwrap();
    }

    #[test]
    fn a_parakeet_installed_from_the_earlier_archive_is_still_installed() {
        let root = tempfile::tempdir().unwrap();
        let paths = LibraryPaths::new(root.path());
        for (id, earlier) in [
            (
                "parakeet-v3",
                "5793d0fd397c5778d2cf2126994d58e9d56b1be7c04d13c7a15bb1b4eafb16bf",
            ),
            (
                "parakeet-v2",
                "157c157bc51155e03e37d2466522a3a737dd9c72bb25f36eb18912964161e1ad",
            ),
        ] {
            let model = find(id).unwrap();
            assert_ne!(
                model.archive.sha256, earlier,
                "new downloads use the new pin"
            );
            installed_from(&paths, model, earlier);
            assert!(
                is_installed(&paths, model),
                "{id} would be downloaded again"
            );
            std::fs::remove_file(model_file(&paths, model, "tokens.txt")).unwrap();
            assert!(!is_installed(&paths, model));
            installed_from(&paths, model, &"0".repeat(64));
            assert!(!is_installed(&paths, model));
            installed_from(&paths, model, model.archive.sha256);
            assert!(is_installed(&paths, model));
        }
        let other = find("sense-voice").unwrap();
        installed_from(
            &paths,
            other,
            "5793d0fd397c5778d2cf2126994d58e9d56b1be7c04d13c7a15bb1b4eafb16bf",
        );
        assert!(!is_installed(&paths, other));
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
