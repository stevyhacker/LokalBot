//! Meeting and dictation transcription (`ProcessingPipeline` transcription
//! stage, `AttributedTrackTranscriber`, `DictationCoordinator` final pass).

use std::path::Path;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::time::Instant;

use anyhow::{Context, Result, anyhow};
use lokalbot_core::model::EchoReport;
use lokalbot_core::remote_transcription::{TimedWord, WindowTranscription};
use lokalbot_core::voice::{
    AudioTurn, TrackClock, TurnAnchor, VoiceSample, label_samples, label_turns,
};
use lokalbot_core::{
    AttributionMethod, AttributionSource, LibraryPaths, Segment, TimingPrecision, Transcript,
};
use parking_lot::Mutex;

use crate::asr::{Asr, Decoded, max_span_seconds};
use crate::attribution::{
    AlignedSegment, Region, Turn, attribute_words, regions, renumber_speakers, track_attribution,
};
use crate::bleed_gate::{BleedGate, envelope};
use crate::diarize::{CLUSTER_THRESHOLD, Diarizer};
use crate::echo::{EchoRemoval, echo_disabled, echo_failed, echo_no_reference, remove_echo};
use crate::language::validate_language;
use crate::models::{self, SpeechModel};
use crate::sanitize::sanitize;
use crate::text::{PromptEcho, join_texts, normalized_text, prompt_terms};
use crate::vad::{SAMPLE_RATE, Span, Vad, speech_seconds, split};
use crate::voice::{VoiceExtractor, raw_turns, voice_samples};

/// Shorter recordings are not transcribed (`AudioFileInspector.minimumTranscribableDuration`).
pub const MIN_AUDIO_SECONDS: f64 = 0.3;
/// Less detected speech than this counts as none (`ProcessingPipeline`, `DictationCoordinator`).
pub const MIN_SPEECH_SECONDS: f64 = 0.5;
/// Diarization slivers shorter than this join their neighbour instead of being decoded alone.
const MIN_PIECE_SECONDS: f64 = 0.8;
/// `RemoteTranscriptionEngine.lineWindows`: one request and one transcript line
/// per window, short enough for the speaker-bleed filter to compare.
const SERVER_WINDOW_SECONDS: f64 = 15.0;
const SERVER_WINDOW_GAP_SECONDS: f64 = 2.0;
/// `maximumConcurrentRequests`.
const SERVER_UPLOADS: usize = 3;
/// OpenAI rejects audio shorter than 0.1 s, and such slivers hold no words.
const SERVER_MINIMUM_SAMPLES: usize = SAMPLE_RATE / 10;

/// A speech-to-text server the user chose (`RemoteTranscriptionEngine`). Speech
/// detection and speaker separation still run on this computer.
pub trait SpeechServer: Send + Sync {
    /// The text of one 16 kHz mono clip. `cancel` stops a retry from waiting.
    fn transcribe(
        &self,
        samples: &[f32],
        language: Option<&str>,
        prompt: Option<&str>,
        cancel: &AtomicBool,
    ) -> Result<String>;

    /// The server times words itself, so its clips can span speaker turns.
    fn provides_word_timings(&self) -> bool {
        false
    }

    /// One clip's text, with word times relative to the clip where it gives them.
    fn transcribe_timed(
        &self,
        samples: &[f32],
        language: Option<&str>,
        prompt: Option<&str>,
        cancel: &AtomicBool,
    ) -> Result<WindowTranscription> {
        Ok(WindowTranscription {
            text: self.transcribe(samples, language, prompt, cancel)?,
            words: Vec::new(),
        })
    }
}

enum Recognizer {
    Local {
        model: &'static SpeechModel,
        asr: Box<Asr>,
    },
    Server {
        /// Stored as the transcript's `engine`.
        name: String,
        server: Arc<dyn SpeechServer>,
    },
}

/// What a recognizer reads besides the audio.
#[derive(Default)]
struct Vocabulary {
    /// Terms for a local model that takes them.
    hotwords: Vec<String>,
    /// The whole prompt for a server.
    prompt: Option<String>,
}

impl Vocabulary {
    fn is_empty(&self) -> bool {
        self.hotwords.is_empty() && self.prompt.is_none()
    }
}

#[derive(Debug, thiserror::Error)]
pub enum SpeechError {
    #[error("Recording was too short to transcribe.")]
    TooShort,
    #[error("No speech detected.")]
    NoSpeech,
    #[error("Transcription was cancelled.")]
    Cancelled,
    #[error("{0} is not downloaded yet.")]
    NotInstalled(String),
}

#[derive(Clone, Debug, PartialEq)]
pub struct TranscribeOptions {
    /// ISO code, or `None`/`"auto"` to detect.
    pub language: Option<String>,
    /// Separate speakers within each track (`multiSpeakerDiarization`).
    pub diarize: bool,
    /// "My microphone is me" (`microphoneIsUser`).
    pub microphone_is_user: bool,
    /// Names and terms to spell correctly (prompt-capable models only).
    pub vocabulary_prompt: Option<String>,
    /// The meeting's reviewed start and end, in seconds on the recording's
    /// timeline (`Meeting.contentRange`). Audio outside it is left out, and
    /// times stay on the original timeline.
    pub content_range: Option<(f64, f64)>,
    /// Measure voices for remembering speakers (never for the sample meeting).
    pub collect_voice_samples: bool,
    /// Subtract the call from the microphone copy (`echoCancellation`), with
    /// how the two tracks line up.
    pub echo: Option<TrackClock>,
    /// How the two tracks line up, for the echo check on finished rows. It
    /// runs whether or not `echo` does.
    pub clock: Option<TrackClock>,
}

impl Default for TranscribeOptions {
    fn default() -> Self {
        Self {
            language: None,
            diarize: false,
            microphone_is_user: true,
            vocabulary_prompt: None,
            content_range: None,
            collect_voice_samples: false,
            echo: None,
            clock: None,
        }
    }
}

/// A transcript with the private voice evidence that goes with it. The
/// evidence never joins the transcript or anything saved beside it in clear.
#[derive(Clone, Debug, Default)]
pub struct DetailedTranscript {
    pub transcript: Transcript,
    /// Clean diarizer turns, in the transcript's labels.
    pub turns: Vec<AudioTurn>,
    /// Voice vectors, in the transcript's labels.
    pub samples: Vec<VoiceSample>,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum TranscribeProgress {
    /// Finding speech in the tracks.
    DetectingSpeech,
    /// Separating voices within a track.
    IdentifyingSpeakers,
    /// Share of detected speech decoded so far, 0–1.
    Transcribing { fraction: f32 },
}

/// One decoded span, seconds from the start of the samples.
#[derive(Clone, Debug, PartialEq)]
pub struct RawSegment {
    pub start: f64,
    pub end: f64,
    pub text: String,
}

/// A span to decode with its label.
struct Piece {
    span: Span,
    region: Option<usize>,
}

struct TrackPlan {
    source: AttributionSource,
    path: std::path::PathBuf,
    spans: Vec<Span>,
    regions: Option<Vec<Region>>,
    /// The diarizer's turns, for attributing a server's timed words.
    diarized: Vec<Turn>,
    speech: f64,
    turns: Vec<(String, TurnAnchor)>,
    samples: Vec<VoiceSample>,
}

pub struct Transcriber {
    recognizer: Recognizer,
    vad: Vad,
    paths: LibraryPaths,
    threads: usize,
    diarizer: Mutex<Option<Arc<Diarizer>>>,
    voices: Mutex<Option<Arc<VoiceExtractor>>>,
    cancelled: AtomicBool,
}

impl Transcriber {
    /// Loads `model_id` (see [`models::transcription_models`]) with `threads`
    /// inference threads. Silero VAD is used when installed; without it an
    /// energy detector finds speech.
    pub fn load(paths: &LibraryPaths, model_id: &str, threads: usize) -> Result<Transcriber> {
        let model = models::find(model_id)
            .filter(|m| m.is_transcription())
            .ok_or_else(|| anyhow!("Unknown transcription model “{model_id}”"))?;
        if !models::is_installed(paths, model) {
            return Err(SpeechError::NotInstalled(model.display_name.to_string()).into());
        }
        let threads = effective_threads(threads);
        let started = Instant::now();
        let asr = Box::new(Asr::load(paths, model, threads)?);
        let transcriber = Self::with_recognizer(paths, threads, Recognizer::Local { model, asr });
        log::info!(
            "speech: loaded {} in {:.2}s ({threads} threads)",
            model.display_name,
            started.elapsed().as_secs_f64()
        );
        Ok(transcriber)
    }

    /// Transcribes through `server`; `name` is stored as the transcript's
    /// `engine`. The caller has checked that the server may receive audio.
    pub fn with_server(
        paths: &LibraryPaths,
        threads: usize,
        name: String,
        server: Arc<dyn SpeechServer>,
    ) -> Transcriber {
        let threads = effective_threads(threads);
        Self::with_recognizer(paths, threads, Recognizer::Server { name, server })
    }

    fn with_recognizer(
        paths: &LibraryPaths,
        threads: usize,
        recognizer: Recognizer,
    ) -> Transcriber {
        let vad_model = models::vad_model();
        let vad = if models::is_installed(paths, vad_model) {
            Vad::new(
                Some(&models::model_file(paths, vad_model, vad_model.files[0])),
                threads,
            )
        } else {
            log::warn!(
                "speech: {} is not installed; using the energy detector",
                vad_model.display_name
            );
            Vad::new(None, threads)
        };
        Transcriber {
            recognizer,
            vad,
            paths: paths.clone(),
            threads,
            diarizer: Mutex::new(None),
            voices: Mutex::new(None),
            cancelled: AtomicBool::new(false),
        }
    }

    /// Name stored as the transcript's `engine`.
    pub fn display_name(&self) -> &str {
        match &self.recognizer {
            Recognizer::Local { model, .. } => model.display_name,
            Recognizer::Server { name, .. } => name,
        }
    }

    fn accepts_prompt(&self) -> bool {
        match &self.recognizer {
            Recognizer::Local { model, .. } => model.supports_prompt,
            Recognizer::Server { .. } => true,
        }
    }

    fn max_span(&self) -> f64 {
        match &self.recognizer {
            Recognizer::Local { asr, .. } => max_span_seconds(asr.family()),
            Recognizer::Server { .. } => SERVER_WINDOW_SECONDS,
        }
    }

    /// Refuses a language this model can't be told to use, before any audio is read.
    fn check_language(&self, language: Option<&str>) -> Result<()> {
        let id = match &self.recognizer {
            Recognizer::Local { model, .. } => model.id,
            Recognizer::Server { .. } => lokalbot_core::remote_transcription::MODEL_ID,
        };
        validate_language(id, self.display_name(), language)?;
        Ok(())
    }

    fn decode(
        &self,
        samples: &[f32],
        language: Option<&str>,
        vocabulary: &Vocabulary,
        word_timings: bool,
    ) -> Result<Decoded> {
        match &self.recognizer {
            Recognizer::Local { asr, .. } => asr.decode(samples, language, &vocabulary.hotwords),
            Recognizer::Server { server, .. } => {
                if samples.len() < SERVER_MINIMUM_SAMPLES {
                    return Ok(Decoded::default());
                }
                if word_timings {
                    let reply = server.transcribe_timed(
                        samples,
                        language,
                        vocabulary.prompt.as_deref(),
                        &self.cancelled,
                    )?;
                    return Ok(Decoded {
                        text: reply.text,
                        words: reply.words,
                        ..Default::default()
                    });
                }
                let text = server.transcribe(
                    samples,
                    language,
                    vocabulary.prompt.as_deref(),
                    &self.cancelled,
                )?;
                Ok(Decoded {
                    text,
                    ..Default::default()
                })
            }
        }
    }

    /// Sends every piece to the server, at most three at a time, keeping their
    /// order. The first failure stops the rest.
    fn upload_pieces(
        &self,
        pieces: &[Piece],
        samples: &[f32],
        language: Option<&str>,
        vocabulary: &Vocabulary,
        word_timings: bool,
        advance: &mut dyn FnMut(f64),
    ) -> Result<Vec<Decoded>> {
        let next = AtomicUsize::new(0);
        let failed = AtomicBool::new(false);
        let (sender, receiver) = std::sync::mpsc::channel();
        let mut decoded = vec![Decoded::default(); pieces.len()];
        let mut first_error = None;
        std::thread::scope(|scope| {
            for _ in 0..SERVER_UPLOADS.min(pieces.len()) {
                let (sender, next, failed) = (sender.clone(), &next, &failed);
                scope.spawn(move || {
                    loop {
                        let index = next.fetch_add(1, Ordering::Relaxed);
                        if index >= pieces.len()
                            || failed.load(Ordering::Relaxed)
                            || self.cancelled.load(Ordering::Relaxed)
                        {
                            return;
                        }
                        let result = self.decode(
                            pieces[index].span.samples(samples),
                            language,
                            vocabulary,
                            word_timings,
                        );
                        failed.fetch_or(result.is_err(), Ordering::Relaxed);
                        let _ = sender.send((index, result));
                    }
                });
            }
            drop(sender);
            for (index, result) in receiver {
                match result {
                    Ok(text) => {
                        decoded[index] = text;
                        advance(pieces[index].span.duration());
                    }
                    Err(error) => {
                        first_error.get_or_insert(error);
                    }
                }
            }
        });
        self.check_cancelled()?;
        match first_error {
            Some(error) => Err(error),
            None => Ok(decoded),
        }
    }

    /// Stops the transcription in progress at the next span; it returns
    /// [`SpeechError::Cancelled`].
    pub fn cancel(&self) {
        self.cancelled.store(true, Ordering::Relaxed);
    }

    fn check_cancelled(&self) -> Result<()> {
        if self.cancelled.load(Ordering::Relaxed) {
            Err(SpeechError::Cancelled.into())
        } else {
            Ok(())
        }
    }

    fn language<'a>(&self, language: Option<&'a str>) -> Option<&'a str> {
        language
            .map(str::trim)
            .filter(|l| !l.is_empty() && !l.eq_ignore_ascii_case("auto"))
    }

    fn vocabulary(&self, prompt: Option<&str>) -> Vocabulary {
        match &self.recognizer {
            Recognizer::Local { model, .. } if model.supports_prompt => Vocabulary {
                hotwords: prompt_terms(prompt),
                prompt: None,
            },
            Recognizer::Local { .. } => Vocabulary::default(),
            Recognizer::Server { .. } => Vocabulary {
                hotwords: Vec::new(),
                prompt: prompt
                    .map(str::trim)
                    .filter(|p| !p.is_empty())
                    .map(str::to_string),
            },
        }
    }

    fn prompt_echo(&self, prompt: Option<&str>) -> Option<PromptEcho> {
        if self.accepts_prompt() {
            PromptEcho::new(prompt)
        } else {
            None
        }
    }

    fn diarizer(&self) -> Option<Arc<Diarizer>> {
        let mut slot = self.diarizer.lock();
        if let Some(diarizer) = slot.as_ref() {
            return Some(Arc::clone(diarizer));
        }
        let [segmentation, embedding] = models::diarization_models() else {
            return None;
        };
        if !models::is_installed(&self.paths, segmentation)
            || !models::is_installed(&self.paths, embedding)
        {
            log::warn!("speech: speaker models are not installed; skipping speaker separation");
            return None;
        }
        let loaded = Diarizer::load(
            &models::model_file(&self.paths, segmentation, segmentation.files[0]),
            &models::model_file(&self.paths, embedding, embedding.files[0]),
            self.threads,
            CLUSTER_THRESHOLD,
        );
        match loaded {
            Ok(diarizer) => {
                let diarizer = Arc::new(diarizer);
                *slot = Some(Arc::clone(&diarizer));
                Some(diarizer)
            }
            Err(error) => {
                log::warn!("speech: {error:#}; skipping speaker separation");
                None
            }
        }
    }

    /// The voice model, once. Without it a meeting is still transcribed; only
    /// its voices aren't measured.
    fn voice_extractor(&self) -> Option<Arc<VoiceExtractor>> {
        let mut slot = self.voices.lock();
        if let Some(extractor) = slot.as_ref() {
            return Some(Arc::clone(extractor));
        }
        match load_voice_extractor(&self.paths, self.threads) {
            Ok(extractor) => {
                let extractor = Arc::new(extractor);
                *slot = Some(Arc::clone(&extractor));
                Some(extractor)
            }
            Err(error) => {
                log::warn!("speech: {error:#}; voices are not measured");
                None
            }
        }
    }

    /// Transcribes 16 kHz mono samples span by span (no speakers). `prompt`
    /// is the user's vocabulary, for the live preview.
    pub fn transcribe_samples(
        &self,
        samples_16k: &[f32],
        language: Option<&str>,
        prompt: Option<&str>,
    ) -> Result<Vec<RawSegment>> {
        self.cancelled.store(false, Ordering::Relaxed);
        self.check_language(language)?;
        let spans = self.vad.speech(samples_16k)?;
        let pieces: Vec<Piece> = split(&spans, self.max_span())
            .into_iter()
            .map(|span| Piece { span, region: None })
            .collect();
        let language = self.language(language);
        let vocabulary = self.vocabulary(prompt);
        let echo = self.prompt_echo(prompt);
        let mut out = Vec::new();
        for piece in &pieces {
            self.check_cancelled()?;
            let decoded = self.decode(
                piece.span.samples(samples_16k),
                language,
                &vocabulary,
                false,
            )?;
            for (start, end, text, _) in self.segments_of(&decoded, piece.span) {
                if !echo.as_ref().is_some_and(|e| e.matches(&text)) {
                    out.push(RawSegment { start, end, text });
                }
            }
        }
        Ok(out)
    }

    /// Transcribes a meeting's tracks into one speaker-attributed transcript:
    /// microphone speech is `local…`, system audio `them…`, segments sorted by
    /// start. A track that fails does not stop the other; the first error is
    /// returned at the end, as on macOS.
    pub fn transcribe_meeting(
        &self,
        mic: Option<&Path>,
        system: Option<&Path>,
        options: &TranscribeOptions,
        progress: &mut dyn FnMut(TranscribeProgress),
    ) -> Result<Transcript> {
        self.transcribe_meeting_detailed(mic, system, options, progress)
            .map(|detailed| detailed.transcript)
    }

    /// [`Self::transcribe_meeting`] with the turns and voice samples that
    /// remembering speakers needs.
    pub fn transcribe_meeting_detailed(
        &self,
        mic: Option<&Path>,
        system: Option<&Path>,
        options: &TranscribeOptions,
        progress: &mut dyn FnMut(TranscribeProgress),
    ) -> Result<DetailedTranscript> {
        self.cancelled.store(false, Ordering::Relaxed);
        self.check_language(options.language.as_deref())?;
        let started = Instant::now();
        let language = self.language(options.language.as_deref());
        let prompt = options.vocabulary_prompt.as_deref();
        let vocabulary = self.vocabulary(prompt);
        let mut first_error: Option<anyhow::Error> = None;

        progress(TranscribeProgress::DetectingSpeech);
        let (cleaned, echo_report) = self.clean_microphone(mic, system, options)?;
        // A cleaned copy has had the far side subtracted; otherwise fall back
        // to gating the frames the far side explains.
        let gate = match (mic, system, &cleaned) {
            (Some(mic), Some(system), None) => detect_bleed(mic, system),
            _ => None,
        };
        let mut plans = Vec::new();
        for (source, path) in [
            (AttributionSource::Microphone, mic),
            (AttributionSource::System, system),
        ] {
            let Some(path) = path else { continue };
            let heard = Heard::of(source, gate.as_ref(), cleaned.as_deref());
            match self.plan_track(source, path, options, heard, progress) {
                Ok(Some(plan)) => plans.push(plan),
                Ok(None) => {}
                Err(error)
                    if error
                        .downcast_ref::<SpeechError>()
                        .is_some_and(|e| matches!(e, SpeechError::Cancelled)) =>
                {
                    return Err(error);
                }
                Err(error) => {
                    log::warn!("speech: {} track failed: {error:#}", track_name(source));
                    first_error.get_or_insert(error);
                }
            }
        }

        let total_speech: f64 = plans.iter().map(|p| p.speech).sum();
        let mut done = 0.0;
        progress(TranscribeProgress::Transcribing { fraction: 0.0 });
        let mut segments = Vec::new();
        for plan in &plans {
            let heard = Heard::of(plan.source, gate.as_ref(), cleaned.as_deref());
            match self.decode_track(
                plan,
                language,
                &vocabulary,
                options,
                heard,
                &mut |seconds| {
                    done += seconds;
                    let fraction = if total_speech > 0.0 {
                        (done / total_speech).min(1.0) as f32
                    } else {
                        1.0
                    };
                    progress(TranscribeProgress::Transcribing { fraction });
                },
            ) {
                Ok(mut track) => {
                    let report = sanitize(&mut track, prompt);
                    if report.changed() {
                        log::info!(
                            "speech: transcript cleanup track={} changed={} removed={} removed_words={}",
                            track_name(plan.source),
                            report.changed_segments,
                            report.removed_segments,
                            report.removed_words
                        );
                    }
                    segments.append(&mut track.segments);
                }
                Err(error)
                    if error
                        .downcast_ref::<SpeechError>()
                        .is_some_and(|e| matches!(e, SpeechError::Cancelled)) =>
                {
                    return Err(error);
                }
                Err(error) => {
                    log::warn!(
                        "speech: {} track failed: {error:#}",
                        track_name(plan.source)
                    );
                    first_error.get_or_insert(error);
                }
            }
        }
        if let Some(error) = first_error {
            return Err(error);
        }
        segments.sort_by(|a, b| a.start.total_cmp(&b.start).then(a.end.total_cmp(&b.end)));
        self.check_for_echo(&mut segments, mic, system, options);
        let mut transcript = Transcript {
            segments,
            engine: self.display_name().to_string(),
            echo_report,
            ..Default::default()
        };
        sanitize(&mut transcript, prompt);
        progress(TranscribeProgress::Transcribing { fraction: 1.0 });
        let audio: f64 = plans
            .iter()
            .map(|p| p.spans.last().map_or(0.0, |s| s.end))
            .fold(0.0, f64::max);
        log::info!(
            "speech: meeting transcribed engine={} audio={audio:.1}s speech={total_speech:.1}s elapsed={:.1}s segments={}",
            self.display_name(),
            started.elapsed().as_secs_f64(),
            transcript.segments.len()
        );
        // Labeled now because `renumber_speakers` changed them while decoding.
        let mut turns = Vec::new();
        let mut samples = Vec::new();
        for plan in &plans {
            turns.extend(label_turns(&plan.turns, &transcript, plan.source));
            samples.extend(label_samples(&plan.samples, &transcript, plan.source));
        }
        Ok(DetailedTranscript {
            transcript,
            turns,
            samples,
        })
    }

    /// The microphone with the far side subtracted, when that is asked for
    /// and it passes. Failing here only means the track is used as recorded.
    /// Words alone only mark a microphone row as possible echo; removing a
    /// full duplicate also takes matching waveform evidence
    /// (`EchoWaveformEvidence`, `SpeakerBleedFilter`).
    fn check_for_echo(
        &self,
        segments: &mut Vec<Segment>,
        mic: Option<&Path>,
        system: Option<&Path>,
        options: &TranscribeOptions,
    ) {
        let clock = options
            .clock
            .as_ref()
            .or(options.echo.as_ref())
            .unwrap_or(&TrackClock::Unknown);
        let analysis = match (mic, system) {
            (Some(mic), Some(system)) => {
                crate::echo_evidence::analyze(segments, mic, system, clock, &|| {
                    self.cancelled.load(Ordering::Relaxed)
                })
                .unwrap_or_else(|error| {
                    log::warn!("speech: the echo check could not read the tracks: {error:#}");
                    Default::default()
                })
            }
            _ => Default::default(),
        };
        for index in &analysis.suspected {
            segments[*index].attribution = Some(lokalbot_core::speaker_bleed::suspected_echo());
        }
        let bleed = lokalbot_core::speaker_bleed::filter_bleed(segments, &analysis.verified);
        if bleed.changed() {
            log::info!(
                "speech: speaker bleed removed={} removed_words={} suspected={}",
                bleed.removed_segments,
                bleed.removed_words,
                bleed.suspected.len()
            );
        }
    }

    fn clean_microphone(
        &self,
        mic: Option<&Path>,
        system: Option<&Path>,
        options: &TranscribeOptions,
    ) -> Result<(Option<Vec<f32>>, Option<EchoReport>)> {
        let Some(mic) = mic else {
            return Ok((None, None));
        };
        let Some(clock) = &options.echo else {
            return Ok((None, Some(echo_disabled())));
        };
        let Some(system) = system else {
            return Ok((None, Some(echo_no_reference())));
        };
        let tracks = lokalbot_audio::read_mono_16k(mic)
            .and_then(|mic| Ok((mic, lokalbot_audio::read_mono_16k(system)?)));
        let (mic, system) = match tracks {
            Ok(tracks) => tracks,
            Err(error) => {
                log::warn!("speech: echo cancellation could not read the tracks: {error}");
                return Ok((None, Some(echo_failed())));
            }
        };
        let removal = remove_echo(&mic, &system, clock, &|| {
            self.cancelled.load(Ordering::Relaxed)
        });
        match removal {
            Some(EchoRemoval { cleaned, report }) => Ok((cleaned, Some(report))),
            None => Err(SpeechError::Cancelled.into()),
        }
    }

    fn plan_track(
        &self,
        source: AttributionSource,
        path: &Path,
        options: &TranscribeOptions,
        heard: Heard<'_>,
        progress: &mut dyn FnMut(TranscribeProgress),
    ) -> Result<Option<TrackPlan>> {
        let samples = read_track(path, heard, options.content_range)?;
        let duration = samples.len() as f64 / SAMPLE_RATE as f64;
        if duration < MIN_AUDIO_SECONDS {
            log::info!(
                "speech: transcription track skipped track={} reason=no-audio",
                track_name(source)
            );
            return Ok(None);
        }
        self.check_cancelled()?;
        let spans = self.vad.speech(&samples)?;
        let speech = speech_seconds(&spans);
        if speech < MIN_SPEECH_SECONDS {
            log::info!(
                "speech: transcription track skipped track={} reason=no-speech",
                track_name(source)
            );
            return Ok(None);
        }
        let mut track_regions = None;
        let mut diarized = Vec::new();
        let mut raw = Vec::new();
        let mut voices = Vec::new();
        if options.diarize
            && let Some(diarizer) = self.diarizer()
        {
            progress(TranscribeProgress::IdentifyingSpeakers);
            self.check_cancelled()?;
            let started = Instant::now();
            match diarizer.turns(&samples) {
                Ok(turns) => {
                    let speakers = distinct_speakers(&turns);
                    log::info!(
                        "speech: speakers track={} voices={speakers} turns={} elapsed={:.1}s",
                        track_name(source),
                        turns.len(),
                        started.elapsed().as_secs_f64()
                    );
                    if !turns.is_empty() {
                        track_regions = Some(regions(
                            duration,
                            &turns,
                            source,
                            options.microphone_is_user,
                        ));
                    }
                    raw = raw_turns(&turns);
                    diarized = turns.clone();
                    if options.collect_voice_samples
                        && let Some(extractor) = self.voice_extractor()
                    {
                        voices = voice_samples(&extractor, &samples, &turns, source, &|| {
                            self.cancelled.load(Ordering::Relaxed)
                        });
                    }
                }
                Err(error) => log::warn!(
                    "speech: speaker separation failed on {}: {error:#}",
                    track_name(source)
                ),
            }
        }
        Ok(Some(TrackPlan {
            source,
            path: path.to_path_buf(),
            spans,
            regions: track_regions,
            diarized,
            speech,
            turns: raw,
            samples: voices,
        }))
    }

    fn decode_track(
        &self,
        plan: &TrackPlan,
        language: Option<&str>,
        vocabulary: &Vocabulary,
        options: &TranscribeOptions,
        heard: Heard<'_>,
        advance: &mut dyn FnMut(f64),
    ) -> Result<Transcript> {
        let started = Instant::now();
        let samples = read_track(&plan.path, heard, options.content_range)?;
        let max_span = self.max_span();
        let uploading = matches!(self.recognizer, Recognizer::Server { .. });
        // A server that times words hears neighbouring turns together, and its words
        // say who spoke. Turns don't cut the clips, which stay as short as any other.
        let word_timed = plan.regions.is_some()
            && matches!(&self.recognizer, Recognizer::Server { server, .. }
                if server.provides_word_timings());
        // Without speaker turns a server gets neighbouring speech in one request.
        let spans = if uploading && (plan.regions.is_none() || word_timed) {
            merge_spans(&plan.spans, SERVER_WINDOW_GAP_SECONDS, max_span)
        } else {
            plan.spans.clone()
        };
        let cut_at = if word_timed {
            None
        } else {
            plan.regions.as_deref()
        };
        let pieces = pieces(&spans, cut_at, max_span);
        let fallback = track_attribution(plan.source, options.microphone_is_user);
        let label = crate::attribution::prefix(plan.source);
        let echo = self.prompt_echo(options.vocabulary_prompt.as_deref());
        let uploaded = if uploading {
            Some(self.upload_pieces(&pieces, &samples, language, vocabulary, word_timed, advance)?)
        } else {
            None
        };
        let duration = samples.len() as f64 / SAMPLE_RATE as f64;
        if word_timed {
            let uploaded = uploaded.unwrap_or_default();
            let aligned = word_timed_clips(&pieces, &uploaded, echo.as_ref());
            log::info!(
                "speech: word-timed={}/{} clips",
                aligned.iter().filter(|clip| !clip.words.is_empty()).count(),
                aligned.len()
            );
            let mut segments = attribute_words(
                &aligned,
                duration,
                &plan.diarized,
                plan.source,
                options.microphone_is_user,
                options.content_range.unwrap_or((0.0, duration)),
            );
            renumber_speakers(&mut segments);
            return Ok(Transcript {
                segments,
                engine: self.display_name().to_string(),
                ..Default::default()
            });
        }
        let mut segments = Vec::new();
        for (index, piece) in pieces.iter().enumerate() {
            self.check_cancelled()?;
            let decoded = if let Some(uploaded) = &uploaded {
                uploaded[index].clone()
            } else {
                let decoded =
                    match self.decode(piece.span.samples(&samples), language, vocabulary, false) {
                        Ok(decoded) => decoded,
                        Err(error) if piece.span.duration() < 1.0 => {
                            // Losing a sliver is better than failing the meeting.
                            log::warn!(
                                "speech: skipped a {:.2}s span the model rejected: {error:#}",
                                piece.span.duration()
                            );
                            advance(piece.span.duration());
                            continue;
                        }
                        Err(error) => return Err(error),
                    };
                advance(piece.span.duration());
                decoded
            };
            log::debug!(
                "speech: piece {:.2}-{:.2} text={:?} tokens={} stamps={:?}",
                piece.span.start,
                piece.span.end,
                decoded.text,
                decoded.tokens.len(),
                decoded
                    .timestamps
                    .iter()
                    .map(|t| (t * 100.0).round() / 100.0)
                    .collect::<Vec<_>>()
            );
            let (speaker, attribution) =
                match piece.region.and_then(|i| plan.regions.as_ref()?.get(i)) {
                    Some(region) => (region.speaker.clone(), region.attribution),
                    None => (label.to_string(), fallback),
                };
            for (start, end, text, precision) in self.segments_of(&decoded, piece.span) {
                if echo.as_ref().is_some_and(|e| e.matches(&text)) {
                    continue;
                }
                segments.push(Segment {
                    start,
                    end,
                    speaker: speaker.clone(),
                    text,
                    confidence: None,
                    timing_precision: Some(precision),
                    attribution: Some(attribution),
                });
            }
        }
        renumber_speakers(&mut segments);
        let elapsed = started.elapsed().as_secs_f64();
        log::info!(
            "speech: transcription track done track={} engine={} duration={duration:.2}s speech={:.2}s elapsed={elapsed:.2}s rtfx={:.1}x segments={}",
            track_name(plan.source),
            self.display_name(),
            plan.speech,
            if elapsed > 0.0 {
                duration / elapsed
            } else {
                0.0
            },
            segments.len()
        );
        Ok(Transcript {
            segments,
            engine: self.display_name().to_string(),
            ..Default::default()
        })
    }

    /// Text of one decoded span as timeline segments: token timestamps split a
    /// long span at pauses over 1 s and at sentence ends after ~200
    /// characters (`ParakeetEngine` grouping); otherwise the span is one row.
    fn segments_of(
        &self,
        decoded: &Decoded,
        span: Span,
    ) -> Vec<(f64, f64, String, TimingPrecision)> {
        let text = normalized_text(&decoded.text);
        if text.is_empty() {
            return Vec::new();
        }
        if let Some(rows) = token_rows(decoded, span)
            && rows.len() > 1
        {
            return rows;
        }
        vec![(span.start, span.end, text, span.precision)]
    }

    /// Dictation: one pass, no speakers.
    pub fn transcribe_dictation(
        &self,
        samples_16k: &[f32],
        language: Option<&str>,
    ) -> Result<String> {
        self.transcribe_dictation_with_prompt(samples_16k, language, None)
    }

    /// Dictation with the vocabulary prompt; an empty result with at least
    /// 1 s of speech is retried once without it (`DictationCoordinator`).
    pub fn transcribe_dictation_with_prompt(
        &self,
        samples_16k: &[f32],
        language: Option<&str>,
        prompt: Option<&str>,
    ) -> Result<String> {
        self.cancelled.store(false, Ordering::Relaxed);
        self.check_language(language)?;
        if (samples_16k.len() as f64) < MIN_AUDIO_SECONDS * SAMPLE_RATE as f64 {
            return Err(SpeechError::TooShort.into());
        }
        let spans = self.vad.speech(samples_16k)?;
        let speech = speech_seconds(&spans);
        if speech < MIN_SPEECH_SECONDS {
            return Err(SpeechError::NoSpeech.into());
        }
        // Short dictations decode as one window so pauses keep their context.
        let windows = merge_spans(&spans, 2.0, self.max_span());
        let language = self.language(language);
        let decode = |vocabulary: &Vocabulary, echo: Option<&PromptEcho>| -> Result<String> {
            let mut texts = Vec::new();
            for window in &windows {
                self.check_cancelled()?;
                let text = normalized_text(
                    &self
                        .decode(window.samples(samples_16k), language, vocabulary, false)?
                        .text,
                );
                if !text.is_empty() && !echo.is_some_and(|e| e.matches(&text)) {
                    texts.push(text);
                }
            }
            Ok(join_texts(texts.iter().map(String::as_str)))
        };
        let vocabulary = self.vocabulary(prompt);
        let echo = self.prompt_echo(prompt);
        let mut text = decode(&vocabulary, echo.as_ref())?;
        if text.is_empty() && speech >= 1.0 && !vocabulary.is_empty() {
            text = decode(&Vocabulary::default(), None)?;
        }
        if text.is_empty() {
            return Err(SpeechError::NoSpeech.into());
        }
        Ok(text)
    }
}

fn load_voice_extractor(paths: &LibraryPaths, threads: usize) -> Result<VoiceExtractor> {
    let [_, embedding] = models::diarization_models() else {
        anyhow::bail!("no voice model");
    };
    if !models::is_installed(paths, embedding) {
        anyhow::bail!("the voice model is not installed");
    }
    VoiceExtractor::load(
        &models::model_file(paths, embedding, embedding.files[0]),
        threads,
    )
}

/// Voice samples of a call track that was already transcribed, in `transcript`'s
/// labels, for learning from saved meetings. Needs no speech model, and never
/// downloads the voice model: `Err` means analysis can't run now.
pub fn analyze_call_voices(
    paths: &LibraryPaths,
    track: &Path,
    transcript: &Transcript,
    threads: usize,
    cancelled: &dyn Fn() -> bool,
) -> Result<Vec<VoiceSample>> {
    let [segmentation, embedding] = models::diarization_models() else {
        anyhow::bail!("no voice model");
    };
    anyhow::ensure!(
        models::is_installed(paths, segmentation) && models::is_installed(paths, embedding),
        "the voice model is not installed"
    );
    let threads = effective_threads(threads);
    let samples = read_track(track, Heard::default(), None)?;
    let diarizer = Diarizer::load(
        &models::model_file(paths, segmentation, segmentation.files[0]),
        &models::model_file(paths, embedding, embedding.files[0]),
        threads,
        CLUSTER_THRESHOLD,
    )?;
    if cancelled() {
        return Err(SpeechError::Cancelled.into());
    }
    let turns = diarizer.turns(&samples)?;
    let extractor = load_voice_extractor(paths, threads)?;
    let raw = voice_samples(
        &extractor,
        &samples,
        &turns,
        AttributionSource::System,
        cancelled,
    );
    if cancelled() {
        return Err(SpeechError::Cancelled.into());
    }
    Ok(label_samples(&raw, transcript, AttributionSource::System))
}

/// onnxruntime slows down past a few threads: on Linux 4–8 threads were
/// fastest and 16 slower; on Windows (i5-13400F) Qwen3-ASR was fastest at 4
/// and took 4× longer at 16. Requests are capped accordingly.
fn effective_threads(requested: usize) -> usize {
    let cap = if cfg!(target_os = "windows") { 4 } else { 8 };
    requested.clamp(1, cap)
}

/// What the models hear of a track: the microphone with the far side
/// subtracted or gated. The recording itself never changes.
#[derive(Clone, Copy, Default)]
struct Heard<'a> {
    gate: Option<&'a BleedGate>,
    cleaned: Option<&'a [f32]>,
}

impl<'a> Heard<'a> {
    fn of(
        source: AttributionSource,
        gate: Option<&'a BleedGate>,
        cleaned: Option<&'a [f32]>,
    ) -> Self {
        if source == AttributionSource::Microphone {
            Self { gate, cleaned }
        } else {
            Self::default()
        }
    }
}

fn read_track(
    path: &Path,
    heard: Heard<'_>,
    content_range: Option<(f64, f64)>,
) -> Result<Vec<f32>> {
    let mut samples = match heard.cleaned {
        Some(samples) => samples.to_vec(),
        None => lokalbot_audio::read_mono_16k(path)
            .with_context(|| format!("could not read {}", path.display()))?,
    };
    if let Some(gate) = heard.gate {
        gate.apply(&mut samples);
    }
    if let Some(range) = content_range {
        limit_to_range(&mut samples, range);
    }
    Ok(samples)
}

/// Silences audio before the range and drops audio after it, so speech is
/// cut at both boundaries and every time keeps its place on the recording
/// (`AttributedTrackTranscriber` partitions the audio the same way).
fn limit_to_range(samples: &mut Vec<f32>, (start, end): (f64, f64)) {
    if !(start.is_finite() && end.is_finite() && start >= 0.0 && end > start) {
        return;
    }
    let at = |seconds: f64| ((seconds * SAMPLE_RATE as f64).round() as usize).min(samples.len());
    let (first, last) = (at(start), at(end));
    samples.truncate(last);
    samples[..first].fill(0.0);
}

/// Looks for speaker bleed between the tracks, one track in memory at a time.
fn detect_bleed(mic: &Path, system: &Path) -> Option<BleedGate> {
    let mic_envelope = envelope(&lokalbot_audio::read_mono_16k(mic).ok()?);
    let system_envelope = envelope(&lokalbot_audio::read_mono_16k(system).ok()?);
    let gate = BleedGate::from_envelopes(&mic_envelope, &system_envelope)?;
    log::info!(
        "speech: speaker bleed delay={}ms level={:.1}dB gated={:.1}s of microphone audio",
        gate.delay_ms,
        gate.gain_db,
        gate.gated_seconds()
    );
    Some(gate)
}

fn track_name(source: AttributionSource) -> &'static str {
    match source {
        AttributionSource::Microphone => "mic",
        _ => "system",
    }
}

fn distinct_speakers(turns: &[Turn]) -> usize {
    let mut ids: Vec<i32> = turns.iter().map(|t| t.speaker).collect();
    ids.sort_unstable();
    ids.dedup();
    ids.len()
}

/// Joins spans separated by at most `max_gap` while the window stays within `max_length`.
fn merge_spans(spans: &[Span], max_gap: f64, max_length: f64) -> Vec<Span> {
    let mut out: Vec<Span> = Vec::new();
    for span in spans {
        match out.last_mut() {
            Some(last)
                if span.start - last.end <= max_gap && span.end - last.start <= max_length =>
            {
                last.end = span.end
            }
            _ => out.push(*span),
        }
    }
    split(&out, max_length)
}

/// VAD spans cut where one voice hands over to another (each piece has one
/// label). Stretches of a span outside every turn join the neighbouring voice
/// (the padding around a turn is not a new speaker), slivers fold into their
/// longer neighbour, then pieces are capped at `max` seconds.
fn pieces(spans: &[Span], track_regions: Option<&[Region]>, max: f64) -> Vec<Piece> {
    let Some(track_regions) = track_regions else {
        return split(spans, max)
            .into_iter()
            .map(|span| Piece { span, region: None })
            .collect();
    };
    let unlabelled =
        |index: usize| track_regions[index].attribution.method == AttributionMethod::Track;
    let mut out = Vec::new();
    for span in spans {
        let mut parts: Vec<(f64, f64, usize)> = Vec::new();
        for (index, region) in track_regions.iter().enumerate() {
            let start = span.start.max(region.start);
            let end = span.end.min(region.end);
            if end > start {
                parts.push((start, end, index));
            }
        }
        if parts.iter().any(|p| !unlabelled(p.2)) {
            let mut i = 0;
            while i < parts.len() {
                if !unlabelled(parts[i].2) {
                    i += 1;
                    continue;
                }
                let target = if i > 0 && !unlabelled(parts[i - 1].2) {
                    i - 1
                } else {
                    i + 1
                };
                if target == i + 1 && (target >= parts.len() || unlabelled(parts[target].2)) {
                    i += 1;
                    continue;
                }
                let (start, end) = (
                    parts[i].0.min(parts[target].0),
                    parts[i].1.max(parts[target].1),
                );
                parts[target].0 = start;
                parts[target].1 = end;
                parts.remove(i);
                i = i.saturating_sub(1);
            }
        }
        // Neighbours with the same label are one piece.
        parts.dedup_by(|next, previous| {
            if track_regions[next.2].speaker == track_regions[previous.2].speaker
                && track_regions[next.2].attribution == track_regions[previous.2].attribution
            {
                previous.1 = next.1;
                true
            } else {
                false
            }
        });
        // Fold slivers into the longer neighbour so no word is decoded alone.
        let mut i = 0;
        while parts.len() > 1 && i < parts.len() {
            if parts[i].1 - parts[i].0 >= MIN_PIECE_SECONDS {
                i += 1;
                continue;
            }
            let previous = (i > 0).then(|| parts[i - 1].1 - parts[i - 1].0);
            let next = parts.get(i + 1).map(|p| p.1 - p.0);
            let into_previous = match (previous, next) {
                (Some(p), Some(n)) => p >= n,
                (Some(_), None) => true,
                _ => false,
            };
            if into_previous {
                parts[i - 1].1 = parts[i].1;
            } else {
                parts[i + 1].0 = parts[i].0;
            }
            parts.remove(i);
        }
        for (start, end, region) in parts {
            for piece in split(
                &[Span {
                    start,
                    end,
                    precision: span.precision,
                }],
                max,
            ) {
                out.push(Piece {
                    span: piece,
                    region: Some(region),
                });
            }
        }
    }
    out
}

/// A server's clips with their words moved onto the track's timeline. A clip with
/// no text, or that only repeats the prompt, is left out.
fn word_timed_clips(
    pieces: &[Piece],
    uploaded: &[Decoded],
    echo: Option<&PromptEcho>,
) -> Vec<AlignedSegment> {
    pieces
        .iter()
        .zip(uploaded)
        .filter_map(|(piece, decoded)| {
            let text = normalized_text(&decoded.text);
            if text.is_empty() || echo.is_some_and(|echo| echo.matches(&text)) {
                return None;
            }
            let (start, end) = (piece.span.start, piece.span.end);
            Some(AlignedSegment {
                start,
                end,
                text,
                precision: piece.span.precision,
                words: decoded
                    .words
                    .iter()
                    .map(|word| TimedWord {
                        text: word.text.clone(),
                        start: end.min(start + word.start),
                        end: end.min(start + word.end),
                    })
                    .collect(),
            })
        })
        .collect()
}

/// Rows from token timestamps, or `None` when the tokens do not spell the text.
fn token_rows(decoded: &Decoded, span: Span) -> Option<Vec<(f64, f64, String, TimingPrecision)>> {
    if decoded.tokens.is_empty() || decoded.tokens.len() != decoded.timestamps.len() {
        return None;
    }
    let spelled: String = decoded.tokens.iter().map(|t| t.replace('▁', " ")).collect();
    let squash = |s: &str| s.chars().filter(|c| !c.is_whitespace()).collect::<String>();
    if squash(&spelled) != squash(&decoded.text) {
        return None;
    }
    let mut rows = Vec::new();
    let mut text = String::new();
    let mut row_start: Option<f64> = None;
    let mut last_time = 0.0f64;
    for (token, &stamp) in decoded.tokens.iter().zip(&decoded.timestamps) {
        let time = (span.start + stamp as f64).clamp(span.start, span.end);
        let piece = token.replace('▁', " ");
        let gap = row_start.is_some() && time - last_time > 1.0;
        let sentence_end = text.chars().count() >= 200
            && text.trim_end().ends_with(['.', '?', '!', '。', '？', '！']);
        if (gap || sentence_end) && !text.trim().is_empty() {
            rows.push((
                row_start.unwrap_or(span.start),
                time.max(last_time),
                std::mem::take(&mut text),
            ));
            row_start = None;
        }
        if row_start.is_none() && !piece.trim().is_empty() {
            row_start = Some(time);
        }
        text.push_str(&piece);
        last_time = time;
    }
    if !text.trim().is_empty() {
        rows.push((row_start.unwrap_or(span.start), span.end, text));
    }
    let rows: Vec<_> = rows
        .into_iter()
        .filter_map(|(start, end, text)| {
            let text = normalized_text(&text);
            (!text.is_empty() && end > start).then_some((start, end, text, TimingPrecision::Token))
        })
        .collect();
    (!rows.is_empty()).then_some(rows)
}

#[cfg(test)]
mod server_tests {
    use super::*;
    use std::sync::atomic::AtomicUsize;

    #[test]
    fn a_servers_words_move_onto_the_track_timeline_and_stay_inside_their_clip() {
        let span = |start: f64, end: f64| Span {
            start,
            end,
            precision: TimingPrecision::Span,
        };
        let pieces = [
            Piece {
                span: span(10.0, 12.0),
                region: None,
            },
            Piece {
                span: span(20.0, 21.0),
                region: None,
            },
            Piece {
                span: span(30.0, 31.0),
                region: None,
            },
        ];
        let timed = |text: &str, start: f64, end: f64| TimedWord {
            text: text.into(),
            start,
            end,
        };
        let uploaded = [
            Decoded {
                text: "Hello there".into(),
                words: vec![timed("Hello", 0.5, 1.0), timed("there", 1.5, 9.0)],
                ..Default::default()
            },
            // Nothing heard.
            Decoded::default(),
            // No word times: the clip stays whole.
            Decoded {
                text: "Plain".into(),
                ..Default::default()
            },
        ];
        let clips = word_timed_clips(&pieces, &uploaded, None);
        assert_eq!(clips.len(), 2);
        assert_eq!(clips[0].words[0].start, 10.5);
        assert_eq!(clips[0].words[1].end, 12.0);
        assert_eq!(clips[1].text, "Plain");
        assert!(clips[1].words.is_empty());
    }

    /// Samples, language and prompt of one request.
    type Seen = (usize, Option<String>, Option<String>);

    /// Answers with `reply`, remembering what it was sent.
    struct FakeServer {
        reply: String,
        fail: bool,
        calls: AtomicUsize,
        running: AtomicUsize,
        most_at_once: AtomicUsize,
        seen: Mutex<Vec<Seen>>,
    }

    impl FakeServer {
        fn new(reply: &str, fail: bool) -> Arc<Self> {
            Arc::new(Self {
                reply: reply.to_string(),
                fail,
                calls: AtomicUsize::new(0),
                running: AtomicUsize::new(0),
                most_at_once: AtomicUsize::new(0),
                seen: Mutex::new(Vec::new()),
            })
        }
    }

    impl SpeechServer for FakeServer {
        fn transcribe(
            &self,
            samples: &[f32],
            language: Option<&str>,
            prompt: Option<&str>,
            _cancel: &AtomicBool,
        ) -> Result<String> {
            self.calls.fetch_add(1, Ordering::Relaxed);
            let running = self.running.fetch_add(1, Ordering::Relaxed) + 1;
            self.most_at_once.fetch_max(running, Ordering::Relaxed);
            self.seen.lock().push((
                samples.len(),
                language.map(str::to_string),
                prompt.map(str::to_string),
            ));
            std::thread::sleep(std::time::Duration::from_millis(20));
            self.running.fetch_sub(1, Ordering::Relaxed);
            if self.fail {
                Err(anyhow!("server refused"))
            } else {
                Ok(self.reply.clone())
            }
        }
    }

    /// A tone with long pauses, so the energy detector finds separate spans.
    fn speech_with_pauses(bursts: usize) -> Vec<f32> {
        let rate = SAMPLE_RATE;
        let mut samples = Vec::new();
        for _ in 0..bursts {
            samples.extend((0..2 * rate).map(|i| {
                0.4 * (2.0 * std::f32::consts::PI * 220.0 * i as f32 / rate as f32).sin()
            }));
            samples.extend(std::iter::repeat_n(0.0, 3 * rate));
        }
        samples
    }

    fn transcriber(dir: &tempfile::TempDir, server: Arc<FakeServer>) -> Transcriber {
        Transcriber::with_server(
            &LibraryPaths::new(dir.path()),
            2,
            "whisper-1 (remote https://x.example)".to_string(),
            server,
        )
    }

    /// A server that times words: two words a clip, either side of its middle.
    struct TimingServer {
        times_words: bool,
        clips: Mutex<Vec<usize>>,
    }

    impl SpeechServer for TimingServer {
        fn transcribe(
            &self,
            samples: &[f32],
            _language: Option<&str>,
            _prompt: Option<&str>,
            _cancel: &AtomicBool,
        ) -> Result<String> {
            self.clips.lock().push(samples.len());
            Ok("First second".to_string())
        }

        fn provides_word_timings(&self) -> bool {
            self.times_words
        }

        fn transcribe_timed(
            &self,
            samples: &[f32],
            _language: Option<&str>,
            _prompt: Option<&str>,
            _cancel: &AtomicBool,
        ) -> Result<WindowTranscription> {
            self.clips.lock().push(samples.len());
            let seconds = samples.len() as f64 / SAMPLE_RATE as f64;
            let word = |text: &str, start: f64, end: f64| TimedWord {
                text: text.to_string(),
                start,
                end,
            };
            Ok(WindowTranscription {
                text: "First second".to_string(),
                words: vec![
                    word("First", 0.1, seconds / 2.0 - 0.2),
                    word("second", seconds / 2.0 + 0.2, seconds - 0.1),
                ],
            })
        }
    }

    /// Two speakers trade places inside one stretch of speech.
    fn traded_turns(server: Arc<TimingServer>, dir: &tempfile::TempDir) -> Transcript {
        let wav = dir.path().join("system.wav");
        let samples = vec![0.0f32; 20 * SAMPLE_RATE];
        lokalbot_audio::write_wav_16k(&wav, &samples).unwrap();
        let turns = vec![
            Turn {
                start: 0.0,
                end: 5.0,
                speaker: 0,
            },
            Turn {
                start: 5.0,
                end: 10.0,
                speaker: 1,
            },
        ];
        let span = Span {
            start: 0.0,
            end: 10.0,
            precision: TimingPrecision::Span,
        };
        let plan = TrackPlan {
            source: AttributionSource::System,
            path: wav,
            spans: vec![span],
            regions: Some(regions(20.0, &turns, AttributionSource::System, false)),
            diarized: turns,
            speech: 10.0,
            turns: Vec::new(),
            samples: Vec::new(),
        };
        Transcriber::with_server(
            &LibraryPaths::new(dir.path()),
            2,
            "server".to_string(),
            server,
        )
        .decode_track(
            &plan,
            None,
            &Vocabulary::default(),
            &TranscribeOptions::default(),
            Heard::default(),
            &mut |_| {},
        )
        .unwrap()
    }

    #[test]
    fn a_server_that_times_words_hears_turns_together_and_splits_them_by_word() {
        let dir = tempfile::tempdir().unwrap();
        let server = Arc::new(TimingServer {
            times_words: true,
            clips: Mutex::new(Vec::new()),
        });
        let transcript = traded_turns(server.clone(), &dir);
        // One clip across the turn, no longer than any other.
        assert_eq!(*server.clips.lock(), [10 * SAMPLE_RATE]);
        let rows: Vec<(&str, &str)> = transcript
            .segments
            .iter()
            .map(|s| (s.speaker.as_str(), s.text.as_str()))
            .collect();
        assert_eq!(rows, [("them 1", "First"), ("them 2", "second")]);
        assert!(
            transcript
                .segments
                .iter()
                .all(|s| s.timing_precision == Some(TimingPrecision::Token))
        );
        assert_eq!(transcript.segments[0].end, 5.0);
        assert_eq!(transcript.segments[1].start, 5.0);
    }

    #[test]
    fn a_server_that_doesnt_time_words_keeps_clips_cut_at_speaker_turns() {
        let dir = tempfile::tempdir().unwrap();
        let server = Arc::new(TimingServer {
            times_words: false,
            clips: Mutex::new(Vec::new()),
        });
        let transcript = traded_turns(server.clone(), &dir);
        let mut clips = server.clips.lock().clone();
        clips.sort_unstable();
        assert_eq!(clips, [5 * SAMPLE_RATE, 5 * SAMPLE_RATE]);
        assert_eq!(transcript.segments.len(), 2);
        assert_eq!(transcript.segments[0].speaker, "them 1");
        assert_eq!(transcript.segments[1].speaker, "them 2");
        assert_eq!(
            transcript.segments[0].timing_precision,
            Some(TimingPrecision::Span)
        );
    }

    #[test]
    fn a_meeting_goes_to_the_server_three_clips_at_a_time() {
        let dir = tempfile::tempdir().unwrap();
        let wav = dir.path().join("system.wav");
        lokalbot_audio::write_wav_16k(&wav, &speech_with_pauses(7)).unwrap();
        let server = FakeServer::new("Hello there", false);
        let transcript = transcriber(&dir, server.clone())
            .transcribe_meeting(
                None,
                Some(&wav),
                &TranscribeOptions {
                    language: Some("de".to_string()),
                    vocabulary_prompt: Some("  Kubernetes, Ana \n".to_string()),
                    ..Default::default()
                },
                &mut |_| {},
            )
            .unwrap();
        assert_eq!(transcript.engine, "whisper-1 (remote https://x.example)");
        assert_eq!(server.calls.load(Ordering::Relaxed), 7);
        assert!(server.most_at_once.load(Ordering::Relaxed) <= SERVER_UPLOADS);
        assert_eq!(transcript.segments.len(), 7);
        // In the audio's order, whichever upload finished first.
        assert!(
            transcript
                .segments
                .windows(2)
                .all(|pair| pair[0].start < pair[1].start)
        );
        assert!(transcript.segments.iter().all(|s| s.text == "Hello there"));
        for (samples, language, prompt) in server.seen.lock().iter() {
            // Each request at most 15 s of audio.
            assert!(*samples <= 15 * SAMPLE_RATE);
            assert_eq!(language.as_deref(), Some("de"));
            assert_eq!(prompt.as_deref(), Some("Kubernetes, Ana"));
        }
    }

    #[test]
    fn a_failed_clip_fails_the_track_and_stops_the_rest() {
        let dir = tempfile::tempdir().unwrap();
        let wav = dir.path().join("system.wav");
        lokalbot_audio::write_wav_16k(&wav, &speech_with_pauses(20)).unwrap();
        let server = FakeServer::new("", true);
        let error = transcriber(&dir, server.clone())
            .transcribe_meeting(None, Some(&wav), &TranscribeOptions::default(), &mut |_| {})
            .unwrap_err();
        assert_eq!(error.to_string(), "server refused");
        assert!(server.calls.load(Ordering::Relaxed) <= SERVER_UPLOADS);
    }

    #[test]
    fn replies_that_only_repeat_the_vocabulary_are_dropped() {
        let dir = tempfile::tempdir().unwrap();
        let server = FakeServer::new("Kubernetes, Ana.", false);
        let segments = transcriber(&dir, server.clone())
            .transcribe_samples(&speech_with_pauses(1), None, Some("Kubernetes, Ana."))
            .unwrap();
        assert_eq!(server.calls.load(Ordering::Relaxed), 1);
        assert!(segments.is_empty());
    }

    #[test]
    fn dictation_retries_without_the_vocabulary() {
        let dir = tempfile::tempdir().unwrap();
        let server = FakeServer::new("Kubernetes, Ana.", false);
        let text = transcriber(&dir, server.clone())
            .transcribe_dictation_with_prompt(
                &speech_with_pauses(1),
                Some("en"),
                Some("Kubernetes, Ana."),
            )
            .unwrap();
        // The first answer echoed the prompt; the second, without it, counts.
        assert_eq!(text, "Kubernetes, Ana.");
        let seen = server.seen.lock();
        assert_eq!(seen.len(), 2);
        assert_eq!(seen[0].2.as_deref(), Some("Kubernetes, Ana."));
        assert_eq!(seen[1].2, None);
    }

    #[test]
    fn a_server_may_be_told_ukrainian() {
        let dir = tempfile::tempdir().unwrap();
        let server = FakeServer::new("Привіт", false);
        let text = transcriber(&dir, server.clone())
            .transcribe_dictation_with_prompt(&speech_with_pauses(1), Some("uk"), None)
            .unwrap();
        assert_eq!(text, "Привіт");
        assert_eq!(server.seen.lock()[0].1.as_deref(), Some("uk"));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn content_range_silences_before_and_drops_after() {
        let mut samples = vec![1.0_f32; SAMPLE_RATE * 10];
        limit_to_range(&mut samples, (2.0, 7.5));
        assert_eq!(samples.len(), SAMPLE_RATE * 15 / 2);
        let start = SAMPLE_RATE * 2;
        assert!(samples[..start].iter().all(|s| *s == 0.0));
        assert!(samples[start..].iter().all(|s| *s == 1.0));

        let mut untouched = vec![1.0_f32; 100];
        limit_to_range(&mut untouched, (5.0, 1.0));
        limit_to_range(&mut untouched, (f64::NAN, 1.0));
        assert_eq!(untouched, vec![1.0_f32; 100]);
    }
    use lokalbot_core::SpeakerAttribution;

    fn span(start: f64, end: f64) -> Span {
        Span {
            start,
            end,
            precision: TimingPrecision::Span,
        }
    }

    fn region(start: f64, end: f64, speaker: &str) -> Region {
        let method = match speaker {
            "them" => AttributionMethod::Track,
            "them unclear" => AttributionMethod::OverlappingSpeech,
            _ => AttributionMethod::Diarization,
        };
        Region {
            start,
            end,
            speaker: speaker.into(),
            attribution: SpeakerAttribution {
                method,
                ..SpeakerAttribution::system_other()
            },
        }
    }

    #[test]
    fn spans_are_cut_at_speaker_changes_without_slivers() {
        let regions = [
            region(0.0, 4.0, "them 1"),
            region(4.0, 4.2, "them unclear"),
            region(4.2, 10.0, "them 2"),
        ];
        let cut = pieces(&[span(1.0, 9.0)], Some(&regions), 15.0);
        let got: Vec<(f64, f64, Option<usize>)> = cut
            .iter()
            .map(|p| (p.span.start, p.span.end, p.region))
            .collect();
        assert_eq!(got.len(), 2);
        assert_eq!((got[0].0, got[0].2), (1.0, Some(0)));
        assert!((got[0].1 - 4.0).abs() < 1e-9);
        assert!(
            (got[1].0 - 4.0).abs() < 1e-9 && got[1].1 == 9.0 && got[1].2 == Some(2),
            "{got:?}"
        );
    }

    #[test]
    fn padding_outside_turns_joins_the_voice() {
        let regions = [
            region(0.0, 1.2, "them"),
            region(1.2, 5.0, "them 1"),
            region(5.0, 6.0, "them"),
            region(6.0, 9.0, "them 2"),
        ];
        let cut = pieces(&[span(1.0, 5.6), span(5.8, 9.0)], Some(&regions), 15.0);
        let got: Vec<(f64, f64, Option<usize>)> = cut
            .iter()
            .map(|p| (p.span.start, p.span.end, p.region))
            .collect();
        assert_eq!(got, vec![(1.0, 5.6, Some(1)), (5.8, 9.0, Some(3))]);
        // A span entirely outside every turn keeps the track label.
        let alone = pieces(&[span(5.1, 5.9)], Some(&regions), 15.0);
        assert_eq!(alone.len(), 1);
        assert_eq!(alone[0].region, Some(2));
    }

    #[test]
    fn dictation_windows_join_short_pauses() {
        let merged = merge_spans(
            &[span(0.2, 2.0), span(3.0, 5.0), span(9.0, 10.0)],
            2.0,
            15.0,
        );
        assert_eq!(
            merged.iter().map(|s| (s.start, s.end)).collect::<Vec<_>>(),
            vec![(0.2, 5.0), (9.0, 10.0)]
        );
    }

    #[test]
    fn token_rows_split_on_long_pauses() {
        let decoded = Decoded {
            text: "Hello there. How are you?".into(),
            tokens: vec![
                "▁Hello".into(),
                "▁there.".into(),
                "▁How".into(),
                "▁are".into(),
                "▁you?".into(),
            ],
            timestamps: vec![0.0, 0.4, 2.0, 2.2, 2.4],
            words: Vec::new(),
        };
        let rows = token_rows(&decoded, span(10.0, 13.0)).unwrap();
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].2, "Hello there.");
        assert!((rows[0].0 - 10.0).abs() < 1e-9);
        assert_eq!(rows[1].2, "How are you?");
        assert!((rows[1].0 - 12.0).abs() < 1e-6 && rows[1].1 == 13.0);
        let mismatched = Decoded {
            text: "Different".into(),
            ..decoded
        };
        assert!(token_rows(&mismatched, span(0.0, 3.0)).is_none());
    }
}
