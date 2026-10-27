//! Meeting and dictation transcription (`ProcessingPipeline` transcription
//! stage, `AttributedTrackTranscriber`, `DictationCoordinator` final pass).

use std::path::Path;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Instant;

use anyhow::{Context, Result, anyhow};
use lokalbot_core::{
    AttributionMethod, AttributionSource, LibraryPaths, Segment, TimingPrecision, Transcript,
};
use parking_lot::Mutex;

use crate::asr::{Asr, Decoded, max_span_seconds};
use crate::attribution::{Region, Turn, regions, renumber_speakers, track_attribution};
use crate::bleed::remove_bleed;
use crate::bleed_gate::{BleedGate, envelope};
use crate::diarize::{CLUSTER_THRESHOLD, Diarizer};
use crate::models::{self, SpeechModel};
use crate::sanitize::sanitize;
use crate::text::{PromptEcho, join_texts, normalized_text, prompt_terms};
use crate::vad::{SAMPLE_RATE, Span, Vad, speech_seconds, split};

/// Shorter recordings are not transcribed (`AudioFileInspector.minimumTranscribableDuration`).
pub const MIN_AUDIO_SECONDS: f64 = 0.3;
/// Less detected speech than this counts as none (`ProcessingPipeline`, `DictationCoordinator`).
pub const MIN_SPEECH_SECONDS: f64 = 0.5;
/// Diarization slivers shorter than this join their neighbour instead of being decoded alone.
const MIN_PIECE_SECONDS: f64 = 0.8;

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
}

impl Default for TranscribeOptions {
    fn default() -> Self {
        Self {
            language: None,
            diarize: false,
            microphone_is_user: true,
            vocabulary_prompt: None,
            content_range: None,
        }
    }
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
    speech: f64,
}

pub struct Transcriber {
    model: &'static SpeechModel,
    asr: Asr,
    vad: Vad,
    paths: LibraryPaths,
    threads: usize,
    diarizer: Mutex<Option<Arc<Diarizer>>>,
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
        let asr = Asr::load(paths, model, threads)?;
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
        log::info!(
            "speech: loaded {} in {:.2}s ({threads} threads)",
            model.display_name,
            started.elapsed().as_secs_f64()
        );
        Ok(Transcriber {
            model,
            asr,
            vad,
            paths: paths.clone(),
            threads,
            diarizer: Mutex::new(None),
            cancelled: AtomicBool::new(false),
        })
    }

    pub fn model(&self) -> &'static SpeechModel {
        self.model
    }

    /// Name stored as the transcript's `engine`.
    pub fn display_name(&self) -> &'static str {
        self.model.display_name
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

    fn hotwords(&self, prompt: Option<&str>) -> Vec<String> {
        if self.model.supports_prompt {
            prompt_terms(prompt)
        } else {
            Vec::new()
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

    /// Transcribes 16 kHz mono samples span by span (no speakers).
    pub fn transcribe_samples(
        &self,
        samples_16k: &[f32],
        language: Option<&str>,
    ) -> Result<Vec<RawSegment>> {
        self.cancelled.store(false, Ordering::Relaxed);
        let spans = self.vad.speech(samples_16k)?;
        let pieces: Vec<Piece> = split(&spans, max_span_seconds(self.asr.family()))
            .into_iter()
            .map(|span| Piece { span, region: None })
            .collect();
        let language = self.language(language);
        let mut out = Vec::new();
        for piece in &pieces {
            self.check_cancelled()?;
            let decoded = self
                .asr
                .decode(piece.span.samples(samples_16k), language, &[])?;
            for (start, end, text, _) in self.segments_of(&decoded, piece.span) {
                out.push(RawSegment { start, end, text });
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
        self.cancelled.store(false, Ordering::Relaxed);
        let started = Instant::now();
        let language = self.language(options.language.as_deref());
        let prompt = options.vocabulary_prompt.as_deref();
        let hotwords = self.hotwords(prompt);
        let mut first_error: Option<anyhow::Error> = None;

        progress(TranscribeProgress::DetectingSpeech);
        let gate = match (mic, system) {
            (Some(mic), Some(system)) => detect_bleed(mic, system),
            _ => None,
        };
        let mut plans = Vec::new();
        for (source, path) in [
            (AttributionSource::Microphone, mic),
            (AttributionSource::System, system),
        ] {
            let Some(path) = path else { continue };
            let gate = gate
                .as_ref()
                .filter(|_| source == AttributionSource::Microphone);
            match self.plan_track(source, path, options, gate, progress) {
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
            let gate = gate
                .as_ref()
                .filter(|_| plan.source == AttributionSource::Microphone);
            match self.decode_track(plan, language, &hotwords, options, gate, &mut |seconds| {
                done += seconds;
                let fraction = if total_speech > 0.0 {
                    (done / total_speech).min(1.0) as f32
                } else {
                    1.0
                };
                progress(TranscribeProgress::Transcribing { fraction });
            }) {
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
        let removed = remove_bleed(&mut segments);
        if removed > 0 {
            log::info!("speech: removed {removed} microphone segment(s) repeating system audio");
        }
        let mut transcript = Transcript {
            segments,
            engine: self.model.display_name.to_string(),
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
            self.model.display_name,
            started.elapsed().as_secs_f64(),
            transcript.segments.len()
        );
        Ok(transcript)
    }

    fn plan_track(
        &self,
        source: AttributionSource,
        path: &Path,
        options: &TranscribeOptions,
        gate: Option<&BleedGate>,
        progress: &mut dyn FnMut(TranscribeProgress),
    ) -> Result<Option<TrackPlan>> {
        let samples = read_track(path, gate, options.content_range)?;
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
            speech,
        }))
    }

    fn decode_track(
        &self,
        plan: &TrackPlan,
        language: Option<&str>,
        hotwords: &[String],
        options: &TranscribeOptions,
        gate: Option<&BleedGate>,
        advance: &mut dyn FnMut(f64),
    ) -> Result<Transcript> {
        let started = Instant::now();
        let samples = read_track(&plan.path, gate, options.content_range)?;
        let pieces = pieces(
            &plan.spans,
            plan.regions.as_deref(),
            max_span_seconds(self.asr.family()),
        );
        let fallback = track_attribution(plan.source, options.microphone_is_user);
        let label = crate::attribution::prefix(plan.source);
        let echo = if self.model.supports_prompt {
            PromptEcho::new(options.vocabulary_prompt.as_deref())
        } else {
            None
        };
        let mut segments = Vec::new();
        for piece in &pieces {
            self.check_cancelled()?;
            let decoded = match self
                .asr
                .decode(piece.span.samples(&samples), language, hotwords)
            {
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
        let duration = samples.len() as f64 / SAMPLE_RATE as f64;
        log::info!(
            "speech: transcription track done track={} engine={} duration={duration:.2}s speech={:.2}s elapsed={elapsed:.2}s rtfx={:.1}x segments={}",
            track_name(plan.source),
            self.model.display_name,
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
            engine: self.model.display_name.to_string(),
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
        if (samples_16k.len() as f64) < MIN_AUDIO_SECONDS * SAMPLE_RATE as f64 {
            return Err(SpeechError::TooShort.into());
        }
        let spans = self.vad.speech(samples_16k)?;
        let speech = speech_seconds(&spans);
        if speech < MIN_SPEECH_SECONDS {
            return Err(SpeechError::NoSpeech.into());
        }
        // Short dictations decode as one window so pauses keep their context.
        let windows = merge_spans(&spans, 2.0, max_span_seconds(self.asr.family()));
        let language = self.language(language);
        let decode = |hotwords: &[String], echo: Option<&PromptEcho>| -> Result<String> {
            let mut texts = Vec::new();
            for window in &windows {
                self.check_cancelled()?;
                let text = normalized_text(
                    &self
                        .asr
                        .decode(window.samples(samples_16k), language, hotwords)?
                        .text,
                );
                if !text.is_empty() && !echo.is_some_and(|e| e.matches(&text)) {
                    texts.push(text);
                }
            }
            Ok(join_texts(texts.iter().map(String::as_str)))
        };
        let hotwords = self.hotwords(prompt);
        let echo = if self.model.supports_prompt {
            PromptEcho::new(prompt)
        } else {
            None
        };
        let mut text = decode(&hotwords, echo.as_ref())?;
        if text.is_empty() && speech >= 1.0 && !hotwords.is_empty() {
            text = decode(&[], None)?;
        }
        if text.is_empty() {
            return Err(SpeechError::NoSpeech.into());
        }
        Ok(text)
    }
}

/// onnxruntime slows down past a few threads: on Linux 4–8 threads were
/// fastest and 16 slower; on Windows (i5-13400F) Qwen3-ASR was fastest at 4
/// and took 4× longer at 16. Requests are capped accordingly.
fn effective_threads(requested: usize) -> usize {
    let cap = if cfg!(target_os = "windows") { 4 } else { 8 };
    requested.clamp(1, cap)
}

fn read_track(
    path: &Path,
    gate: Option<&BleedGate>,
    content_range: Option<(f64, f64)>,
) -> Result<Vec<f32>> {
    let mut samples = lokalbot_audio::read_mono_16k(path)
        .with_context(|| format!("could not read {}", path.display()))?;
    if let Some(gate) = gate {
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
