//! One loaded sherpa-onnx recognizer and how each model family is configured
//! and fed (`QwenASREngine`, `OnnxTranscriptionEngine` on macOS).

use std::path::Path;
use std::sync::Arc;

use anyhow::{Result, anyhow, bail};
use lokalbot_core::LibraryPaths;
use parking_lot::Mutex;
use sherpa_onnx::{
    OfflineQwen3ASRModelConfig, OfflineRecognizer, OfflineRecognizerConfig,
    OfflineSenseVoiceModelConfig, OfflineTransducerModelConfig, OfflineWhisperModelConfig,
};

use crate::models::{Family, SpeechModel, model_file};

/// Longest span each family decodes at once.
pub fn max_span_seconds(family: Family) -> f64 {
    match family {
        // `QwenASREngine`: spans of at most 15 s.
        Family::Qwen3Asr => 15.0,
        Family::NemoTransducer | Family::SenseVoice => 30.0,
        Family::Whisper => 28.0,
    }
}

/// Recognizer output for one span; times in seconds from the span start.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Decoded {
    pub text: String,
    pub tokens: Vec<String>,
    pub timestamps: Vec<f32>,
}

/// Qwen3-ASR's prompt names languages in English (`language English`).
pub fn qwen_language_name(code: &str) -> Option<&'static str> {
    Some(match code {
        "zh" => "Chinese",
        "en" => "English",
        "yue" => "Cantonese",
        "ar" => "Arabic",
        "de" => "German",
        "fr" => "French",
        "es" => "Spanish",
        "pt" => "Portuguese",
        "id" => "Indonesian",
        "it" => "Italian",
        "ko" => "Korean",
        "ru" => "Russian",
        "th" => "Thai",
        "vi" => "Vietnamese",
        "ja" => "Japanese",
        "tr" => "Turkish",
        "hi" => "Hindi",
        "ms" => "Malay",
        "nl" => "Dutch",
        "sv" => "Swedish",
        "da" => "Danish",
        "fi" => "Finnish",
        "pl" => "Polish",
        "cs" => "Czech",
        "fil" => "Filipino",
        "fa" => "Persian",
        "el" => "Greek",
        "hu" => "Hungarian",
        "mk" => "Macedonian",
        "ro" => "Romanian",
        _ => return None,
    })
}

/// `QwenASREngine.maxTokens`: clamp(seconds × 18, 128, 768).
fn qwen_max_new_tokens(samples: usize) -> i32 {
    let seconds = samples as f64 / 16_000.0;
    ((seconds * 18.0) as i32).clamp(128, 768)
}

fn path(file: impl AsRef<Path>) -> Option<String> {
    Some(file.as_ref().to_string_lossy().into_owned())
}

/// No interior NUL can reach the C API (the wrapper would panic).
fn c_safe(value: &str) -> String {
    value.replace('\0', "")
}

pub struct Asr {
    model: &'static SpeechModel,
    family: Family,
    base: OfflineRecognizerConfig,
    /// Language the current recognizer was built for (SenseVoice and Whisper
    /// fix it at creation), and the recognizer.
    current: Mutex<(Option<String>, Arc<OfflineRecognizer>)>,
}

impl Asr {
    pub fn load(paths: &LibraryPaths, model: &'static SpeechModel, threads: usize) -> Result<Self> {
        let family = model
            .family()
            .ok_or_else(|| anyhow!("{} is not a transcription model", model.display_name))?;
        let file = |name: &str| path(model_file(paths, model, name));
        let mut config = OfflineRecognizerConfig::default();
        config.model_config.num_threads = threads.clamp(1, 64) as i32;
        config.model_config.provider = Some("cpu".into());
        match family {
            Family::Qwen3Asr => {
                config.model_config.qwen3_asr = OfflineQwen3ASRModelConfig {
                    conv_frontend: file("conv_frontend.onnx"),
                    encoder: file("encoder.int8.onnx"),
                    decoder: file("decoder.int8.onnx"),
                    tokenizer: path(model_file(paths, model, "tokenizer")),
                    max_total_len: 1024,
                    max_new_tokens: 512,
                    ..Default::default()
                };
                config.model_config.tokens = Some(String::new());
            }
            Family::NemoTransducer => {
                config.model_config.transducer = OfflineTransducerModelConfig {
                    encoder: file("encoder.int8.onnx"),
                    decoder: file("decoder.int8.onnx"),
                    joiner: file("joiner.int8.onnx"),
                };
                config.model_config.tokens = file("tokens.txt");
                config.model_config.model_type = Some("nemo_transducer".into());
                config.decoding_method = Some("greedy_search".into());
            }
            Family::SenseVoice => {
                config.model_config.sense_voice = OfflineSenseVoiceModelConfig {
                    model: file("model.int8.onnx"),
                    language: Some("auto".into()),
                    use_itn: true,
                };
                config.model_config.tokens = file("tokens.txt");
            }
            Family::Whisper => {
                config.model_config.whisper = OfflineWhisperModelConfig {
                    encoder: file("turbo-encoder.int8.onnx"),
                    decoder: file("turbo-decoder.int8.onnx"),
                    language: Some(String::new()),
                    task: Some("transcribe".into()),
                    tail_paddings: -1,
                    ..Default::default()
                };
                config.model_config.tokens = file("turbo-tokens.txt");
            }
        }
        let recognizer = create(&config, model)?;
        Ok(Self {
            model,
            family,
            base: config,
            current: Mutex::new((None, Arc::new(recognizer))),
        })
    }

    pub fn family(&self) -> Family {
        self.family
    }

    /// The recognizer for `language`, rebuilding SenseVoice and Whisper
    /// recognizers when the language changes.
    fn recognizer(&self, language: Option<&str>) -> Result<Arc<OfflineRecognizer>> {
        let fixed_language = match self.family {
            Family::SenseVoice => language
                .filter(|l| self.model.supports_language(l))
                .map(str::to_string),
            Family::Whisper => language.map(str::to_string),
            Family::Qwen3Asr | Family::NemoTransducer => None,
        };
        let mut current = self.current.lock();
        if current.0 == fixed_language {
            return Ok(Arc::clone(&current.1));
        }
        let mut config = self.base.clone();
        let wanted = fixed_language.clone().unwrap_or_default();
        match self.family {
            Family::SenseVoice => {
                config.model_config.sense_voice.language = Some(if wanted.is_empty() {
                    "auto".into()
                } else {
                    wanted
                });
            }
            Family::Whisper => config.model_config.whisper.language = Some(wanted),
            _ => {}
        }
        let recognizer = Arc::new(create(&config, self.model)?);
        *current = (fixed_language, Arc::clone(&recognizer));
        Ok(recognizer)
    }

    /// Decodes one span of 16 kHz mono audio.
    pub fn decode(
        &self,
        samples: &[f32],
        language: Option<&str>,
        hotwords: &[String],
    ) -> Result<Decoded> {
        if samples.is_empty() {
            return Ok(Decoded::default());
        }
        let decoded = self.decode_once(samples, language, hotwords)?;
        if self.family != Family::NemoTransducer {
            return Ok(decoded);
        }
        // Parakeet's greedy TDT search occasionally stops emitting part-way
        // through a span (seen on real spans, fixed by moving the start by a
        // few hundred ms). When the words end well before the audio does,
        // decode again behind a little silence and keep the fuller result.
        let duration = samples.len() as f32 / 16_000.0;
        let last = decoded.timestamps.last().copied().unwrap_or(0.0);
        if duration <= 2.0 || last + 1.5 >= duration {
            return Ok(decoded);
        }
        const LEAD: usize = 4_800;
        let mut padded = vec![0.0f32; LEAD];
        padded.extend_from_slice(samples);
        let mut retry = self.decode_once(&padded, language, hotwords)?;
        if retry.text.trim().chars().count() <= decoded.text.trim().chars().count() {
            return Ok(decoded);
        }
        let lead = LEAD as f32 / 16_000.0;
        for stamp in &mut retry.timestamps {
            *stamp = (*stamp - lead).max(0.0);
        }
        log::debug!(
            "speech: transducer retry recovered {:?} (was {:?})",
            retry.text,
            decoded.text
        );
        Ok(retry)
    }

    fn decode_once(
        &self,
        samples: &[f32],
        language: Option<&str>,
        hotwords: &[String],
    ) -> Result<Decoded> {
        let recognizer = self.recognizer(language)?;
        let stream = recognizer.create_stream();
        if self.family == Family::Qwen3Asr {
            stream.set_option(
                "max_new_tokens",
                &qwen_max_new_tokens(samples.len()).to_string(),
            );
            if let Some(name) = language.and_then(qwen_language_name) {
                stream.set_option("language", name);
            }
            if !hotwords.is_empty() {
                let list = hotwords
                    .iter()
                    .map(|h| c_safe(h).replace(',', " "))
                    .collect::<Vec<_>>()
                    .join(",");
                stream.set_option("hotwords", &list);
            }
        }
        // Spans shorter than 100 ms give the front end too little to read.
        let minimum = 1_600;
        if samples.len() < minimum {
            let mut padded = samples.to_vec();
            padded.resize(minimum, 0.0);
            stream.accept_waveform(16_000, &padded);
        } else {
            stream.accept_waveform(16_000, samples);
        }
        recognizer.decode(&stream);
        let result = stream
            .get_result()
            .ok_or_else(|| anyhow!("{} returned no result", self.model.display_name))?;
        Ok(Decoded {
            text: result.text,
            tokens: result.tokens,
            timestamps: result.timestamps.unwrap_or_default(),
        })
    }
}

fn create(config: &OfflineRecognizerConfig, model: &SpeechModel) -> Result<OfflineRecognizer> {
    match OfflineRecognizer::create(config) {
        Some(recognizer) => Ok(recognizer),
        None => bail!(
            "Could not load {}. Download it again in Settings → Models.",
            model.display_name
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn qwen_settings() {
        assert_eq!(qwen_language_name("de"), Some("German"));
        assert_eq!(qwen_language_name("sr"), None);
        assert_eq!(qwen_max_new_tokens(16_000), 128);
        assert_eq!(qwen_max_new_tokens(16_000 * 15), 270);
        assert_eq!(qwen_max_new_tokens(16_000 * 60), 768);
    }
}
