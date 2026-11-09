//! Read aloud with Kokoro 82M (`KokoroSpeechEngine.swift`). The Mac runs
//! sherpa-onnx's command-line tool; here the library runs in-process, so the
//! audio stays in memory unless the user exports it.

use std::sync::Arc;
use std::sync::OnceLock;
use std::sync::atomic::{AtomicBool, Ordering};

use anyhow::{Result, anyhow};
use lokalbot_core::LibraryPaths;
use regex::Regex;
use sherpa_onnx::{
    GenerationConfig, OfflineTts, OfflineTtsConfig, OfflineTtsKokoroModelConfig,
    OfflineTtsModelConfig,
};

use crate::models;

pub const MIN_SPEED: f64 = 0.5;
pub const MAX_SPEED: f64 = 2.0;
pub const DEFAULT_VOICE: &str = "af_heart";

/// The Mac's `--num-threads=2`: reading aloud should not take over the computer.
const THREADS: i32 = 2;

/// One of the voices the Mac offers (`KokoroVoice`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Voice {
    /// Stored in settings (`speechVoice`).
    pub id: &'static str,
    pub display_name: &'static str,
    pub speaker_id: i32,
}

pub const VOICES: [Voice; 9] = [
    Voice {
        id: "af_heart",
        display_name: "Heart",
        speaker_id: 3,
    },
    Voice {
        id: "af_bella",
        display_name: "Bella",
        speaker_id: 2,
    },
    Voice {
        id: "af_sarah",
        display_name: "Sarah",
        speaker_id: 9,
    },
    Voice {
        id: "af_sky",
        display_name: "Sky",
        speaker_id: 10,
    },
    Voice {
        id: "am_adam",
        display_name: "Adam",
        speaker_id: 11,
    },
    Voice {
        id: "am_puck",
        display_name: "Puck",
        speaker_id: 18,
    },
    Voice {
        id: "bf_emma",
        display_name: "Emma",
        speaker_id: 21,
    },
    Voice {
        id: "bm_fable",
        display_name: "Fable",
        speaker_id: 25,
    },
    Voice {
        id: "bm_george",
        display_name: "George",
        speaker_id: 26,
    },
];

/// The stored voice, or Heart when a library holds one this build doesn't know.
pub fn voice(id: &str) -> Voice {
    VOICES
        .iter()
        .copied()
        .find(|voice| voice.id == id)
        .unwrap_or(VOICES[0])
}

/// The stored speed within what the model takes; anything unusable reads at 1×.
pub fn clamped_speed(speed: f64) -> f64 {
    if speed.is_finite() {
        speed.clamp(MIN_SPEED, MAX_SPEED)
    } else {
        1.0
    }
}

#[derive(Debug, thiserror::Error)]
pub enum SynthesisError {
    #[error("There is no text to read aloud.")]
    EmptyText,
    #[error("Reading aloud was cancelled.")]
    Cancelled,
}

/// Markdown as text worth saying (`SpeechTextSanitizer`): code blocks go, links
/// keep their text, citations and markup go, whitespace collapses.
pub fn plain_text(markdown: &str) -> String {
    static RULES: OnceLock<Vec<(Regex, &'static str)>> = OnceLock::new();
    let rules = RULES.get_or_init(|| {
        [
            (r"(?s)```.*?```", " "),
            (r"`([^`]+)`", "$1"),
            (r"\[([^\]]+)\]\([^)]+\)", "$1"),
            (r"\[meeting:[^\]]+\]", " "),
            (r"(?m)^\s{0,3}#{1,6}\s*", ""),
            (r"(?m)^\s*[-*+]\s+", ""),
            (r"(?m)^\s*\d+\.\s+", ""),
            (r"[*_~>#]", ""),
            (r"\s+", " "),
        ]
        .into_iter()
        .map(|(pattern, with)| (Regex::new(pattern).expect("a valid pattern"), with))
        .collect()
    });
    let mut text = markdown.to_string();
    for (pattern, with) in rules {
        text = pattern.replace_all(&text, *with).into_owned();
    }
    text
}

/// Speech ready to play or save: mono floats at `sample_rate`.
#[derive(Clone, Debug, PartialEq)]
pub struct Speech {
    pub samples: Vec<f32>,
    pub sample_rate: u32,
}

pub struct Kokoro {
    tts: OfflineTts,
}

impl Kokoro {
    /// Loads the downloaded model. The Mac's configuration: both lexicons,
    /// espeak data for other words, two threads.
    pub fn load(paths: &LibraryPaths) -> Result<Kokoro> {
        let model = models::kokoro_model();
        if !models::is_installed(paths, model) {
            return Err(crate::transcriber::SpeechError::NotInstalled(
                model.display_name.to_string(),
            )
            .into());
        }
        let file = |name: &str| {
            Some(
                models::model_file(paths, model, name)
                    .to_string_lossy()
                    .into_owned(),
            )
        };
        let lexicon = [file("lexicon-us-en.txt"), file("lexicon-zh.txt")]
            .into_iter()
            .flatten()
            .collect::<Vec<_>>()
            .join(",");
        let config = OfflineTtsConfig {
            model: OfflineTtsModelConfig {
                kokoro: OfflineTtsKokoroModelConfig {
                    model: file("model.onnx"),
                    voices: file("voices.bin"),
                    tokens: file("tokens.txt"),
                    data_dir: file("espeak-ng-data"),
                    lexicon: Some(lexicon),
                    ..Default::default()
                },
                num_threads: THREADS,
                ..Default::default()
            },
            ..Default::default()
        };
        let tts = OfflineTts::create(&config)
            .ok_or_else(|| anyhow!("Kokoro could not load its speech model."))?;
        Ok(Kokoro { tts })
    }

    /// Reads markdown `text` with one voice at `speed` (0.5–2.0×). `cancel`
    /// stops it between sentences.
    pub fn synthesize(
        &self,
        text: &str,
        voice: Voice,
        speed: f64,
        cancel: Arc<AtomicBool>,
    ) -> Result<Speech> {
        let text = synthesis_text(text).ok_or(SynthesisError::EmptyText)?;
        let config = GenerationConfig {
            sid: voice.speaker_id,
            speed: clamped_speed(speed) as f32,
            ..Default::default()
        };
        let keep_going = {
            let cancel = cancel.clone();
            move |_: &[f32], _: f32| !cancel.load(Ordering::Relaxed)
        };
        let audio = self
            .tts
            .generate_with_config(&text, &config, Some(keep_going));
        if cancel.load(Ordering::Relaxed) {
            return Err(SynthesisError::Cancelled.into());
        }
        let audio = audio.ok_or_else(|| anyhow!("Kokoro did not write an audio file."))?;
        if audio.samples().is_empty() {
            return Err(anyhow!("Kokoro did not write an audio file."));
        }
        Ok(Speech {
            samples: audio.samples().to_vec(),
            sample_rate: audio.sample_rate().max(1) as u32,
        })
    }
}

/// What the model is given, or `None` when nothing is left to say. C strings
/// end at a NUL, so one can't reach the library.
fn synthesis_text(markdown: &str) -> Option<String> {
    let text = plain_text(&markdown.replace('\0', " "));
    let text = text.trim();
    (!text.is_empty()).then(|| text.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn voices_match_the_mac() {
        assert_eq!(voice("af_heart").speaker_id, 3);
        assert_eq!(voice("af_bella").speaker_id, 2);
        assert_eq!(voice("bm_george").speaker_id, 26);
        assert_eq!(voice("unknown").id, DEFAULT_VOICE);
        assert_eq!(VOICES.len(), 9);
    }

    #[test]
    fn speed_is_limited() {
        assert_eq!(clamped_speed(0.1), 0.5);
        assert_eq!(clamped_speed(9.0), 2.0);
        assert_eq!(clamped_speed(1.25), 1.25);
        assert_eq!(clamped_speed(f64::NAN), 1.0);
    }

    #[test]
    fn markdown_becomes_speech() {
        let markdown = "## Decisions\n\n- Ship **Friday** [meeting:abc|12:30]\n1. See [the doc](https://x.y/z) and `grep`\n\n```rust\nlet hidden = 1;\n```\n> quoted _text_ ~here~ #tag";
        assert_eq!(
            plain_text(markdown),
            "Decisions Ship Friday See the doc and grep quoted text here tag"
        );
    }

    #[test]
    fn nothing_to_say_is_an_error() {
        assert_eq!(synthesis_text("  \n```\ncode\n```\n"), None);
        assert_eq!(synthesis_text("**__**"), None);
        assert_eq!(synthesis_text("a\0b").as_deref(), Some("a b"));
    }

    /// Needs the real model: `LOKALBOT_KOKORO_ROOT=<library root with the
    /// model> cargo test -p lokalbot-speech kokoro -- --ignored`.
    #[test]
    #[ignore]
    fn reads_with_the_real_model() {
        let root = std::env::var("LOKALBOT_KOKORO_ROOT").expect("LOKALBOT_KOKORO_ROOT");
        let paths = LibraryPaths::new(std::path::Path::new(&root));
        let kokoro = Kokoro::load(&paths).unwrap();
        let cancel = Arc::new(AtomicBool::new(false));
        let say = "Here is a sample of LokalBot's voice.";
        let normal = kokoro
            .synthesize(say, voice("af_heart"), 1.0, cancel.clone())
            .unwrap();
        assert_eq!(normal.sample_rate, 24_000);
        let seconds = normal.samples.len() as f64 / normal.sample_rate as f64;
        assert!((1.0..10.0).contains(&seconds), "{seconds}");
        let fast = kokoro
            .synthesize(say, voice("am_adam"), 2.0, cancel.clone())
            .unwrap();
        assert!(
            (fast.samples.len() as f64) < normal.samples.len() as f64 * 0.75,
            "{} vs {}",
            fast.samples.len(),
            normal.samples.len()
        );
        // Words outside the lexicons, other scripts and symbols must not abort.
        for text in [
            "Ћирилица и latinica, 中文 too.",
            "The API's p99 was 3.5 ms — 🚀 great!",
            "SELECT * FROM t;",
        ] {
            kokoro
                .synthesize(text, voice("bf_emma"), 1.0, cancel.clone())
                .unwrap();
        }
        cancel.store(true, Ordering::Relaxed);
        let cancelled = kokoro.synthesize(say, voice("af_heart"), 1.0, cancel);
        assert!(cancelled.is_err());
    }
}
