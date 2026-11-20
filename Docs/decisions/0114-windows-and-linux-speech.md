# 0114. Windows and Linux: speech

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LinuxWindows/crates/lokalbot-speech/examples/`, `LinuxWindows/crates/lokalbot-speech/src/asr.rs`, `LinuxWindows/crates/lokalbot-speech/src/attribution.rs`, `LinuxWindows/crates/lokalbot-speech/src/bleed_gate.rs`, `LinuxWindows/crates/lokalbot-speech/src/diarize.rs`, `LinuxWindows/crates/lokalbot-speech/src/echo.rs`, `LinuxWindows/crates/lokalbot-speech/src/echo_evidence.rs`, `LinuxWindows/crates/lokalbot-speech/src/kokoro.rs`, `LinuxWindows/crates/lokalbot-speech/src/language.rs`, `LinuxWindows/crates/lokalbot-speech/src/lib.rs`, `LinuxWindows/crates/lokalbot-speech/src/models.rs`, `LinuxWindows/crates/lokalbot-speech/src/sanitize.rs`, `LinuxWindows/crates/lokalbot-speech/src/text.rs`, `LinuxWindows/crates/lokalbot-speech/src/transcriber.rs`, `LinuxWindows/crates/lokalbot-speech/src/vad.rs`, `LinuxWindows/crates/lokalbot-speech/src/voice.rs`.

## Decisions

### `LinuxWindows/crates/lokalbot-speech/examples/diarize.rs`

#### diarize example sweeps speaker-separation thresholds; usage command
Sweeps speaker-separation settings on a WAV with a known script.

`cargo run -p lokalbot-speech --release --example diarize -- <segmentation.onnx> <embedding.onnx> <track.wav> <scenario.json> <track name> [thresholds…]`

#### Purity is seconds of each turn whose majority truth voice matches
`diarize example main`: Purity: seconds of each turn whose majority truth voice matches the speaker's majority voice.

### `LinuxWindows/crates/lokalbot-speech/examples/dictate.rs`

#### dictate example times the dictation path; usage command
Times the dictation path on a WAV file.

`cargo run -p lokalbot-speech --release --example dictate -- <library root> <model id> <wav> [threads…]`

### `LinuxWindows/crates/lokalbot-speech/examples/evaluate.rs`

#### evaluate example scripted-meeting check; fixture layout and usage
End-to-end check on a scripted meeting: per-track word error rate,
attribution, speaker labels, timing, and the dictation path.

`cargo run -p lokalbot-speech --release --example evaluate -- --root <library> --model qwen3-asr-0.6b --fixture <dir> [--diarize] [--mic mic.wav] [--prompt] [--threads 8]`

`<dir>` holds `mic.wav`, `system.wav`, `scenario.json` (`{"turns": [{"track", "voice", "start", "end", "text"}]}`)
and optionally `dictation.wav` + `dictation.json` (`{"text"}`).

#### Log info and above to stderr via RUST_LOG without a logger dependency
`env_logger_lite`: Logs `info` and above to stderr when `RUST_LOG` is set, without a logger dependency.

### `LinuxWindows/crates/lokalbot-speech/examples/models.rs`

#### models example lists catalog; --finish completes manually extracted installs
Lists the speech model catalog and its install state; `--finish` runs
`finish_install` for every model folder that exists (after a manual
download + extract into `<root>/models/speech/<id>/`).

`cargo run -p lokalbot-speech --example models -- <library root> [--finish]`

### `LinuxWindows/crates/lokalbot-speech/examples/voice_calibration.rs`

#### voice_calibration measures voice model; chunk size, averaging, scoring protocol
Measures the voice model on labeled speech, for the matching rules in
`lokalbot_core::voice`.

`cargo run -p lokalbot-speech --example voice_calibration -- <titanet.onnx> <dir>`

`<dir>` holds `<speaker>/<recording>/*.wav` (or any format the app reads).
Each speaker/recording pair stands for one meeting: its files are cut into
6 s chunks, up to 16 chunks are averaged as `voice::voiceprint` does, and
every meeting is scored against the average of each person's other
meetings. Prints JSON: score distributions, and what the Mac's rules would
decide when the person is remembered and when they are a stranger.

#### Closed set means remembered person; open set means stranger, where naming anyone is wrong
`voice_calibration main`: Closed set: the person is remembered. Open set: they are a stranger, the
case where naming anyone is wrong.

#### Mirrors what the Mac's SpeakerVoiceMatcher.callMatches rules decide
`Decisions`: What the Mac's rules would decide (`SpeakerVoiceMatcher.callMatches`).

### `LinuxWindows/crates/lokalbot-speech/examples/voice_meeting_check.rs`

#### voice_meeting_check runs speaker memory end to end with two calls per round
Remembering speakers end to end on real voices: real speaker separation,
voice samples, naming, then a later meeting, with no speech model.

`cargo run -p lokalbot-speech --example voice_meeting_check -- <segmentation.onnx> <titanet.onnx> <dir> <library>`

`<dir>` holds `<speaker>/<recording>/*.wav`. Each round builds two calls of
the same three people from different recordings, plus one stranger in the
second. Everyone in the first call is named as a person would, then the
second call is identified. Prints what it decided about each voice.

#### Calls use 8–15 s turns per person in rotation with short pauses
`build_call`: Turns of 8–15 s from each person in rotation, with short pauses.

### `LinuxWindows/crates/lokalbot-speech/src/asr.rs`

#### Sherpa-onnx recognizer twin of macOS QwenASREngine and OnnxTranscriptionEngine
One loaded sherpa-onnx recognizer and how each model family is configured
and fed (`QwenASREngine`, `OnnxTranscriptionEngine` on macOS).

#### Longest span each model family decodes at once
`max_span_seconds`: Longest span each family decodes at once.

#### Qwen spans capped at 15 s, matching QwenASREngine
`max_span_seconds`: `QwenASREngine`: spans of at most 15 s.

#### Recognizer output times are in seconds from the span start
`Decoded`: Recognizer output for one span; times in seconds from the span start.

#### Word times from a server are relative to the clip
`Decoded.words`: Word times from a server that gives them, relative to the clip.

#### Qwen3-ASR prompt names languages in English
`qwen_language_name`: Qwen3-ASR's prompt names languages in English (`language English`).

#### Name Serbian explicitly: 44.3% vs 54.2% WER where detection reads Croatian
`qwen_language_name`: Not on the model's list, but on the Mac naming it explicitly measured
44.3% against 54.2% WER, where detection reads it as Croatian.

#### Token cap mirrors QwenASREngine.maxTokens: clamp(seconds×18, 128, 768)
`qwen_max_new_tokens`: `QwenASREngine.maxTokens`: clamp(seconds × 18, 128, 768).

#### Strip interior NULs so the C API wrapper cannot panic
`c_safe`: No interior NUL can reach the C API (the wrapper would panic).

#### SenseVoice and Whisper fix language at creation, so track it with the recognizer
`Asr.current`: Language the current recognizer was built for (SenseVoice and Whisper
fix it at creation), and the recognizer.

#### Rebuild SenseVoice and Whisper recognizers when language changes
`Asr.recognizer`: The recognizer for `language`, rebuilding SenseVoice and Whisper
recognizers when the language changes.

#### Decode takes one span of 16 kHz mono audio
`Asr.decode`: Decodes one span of 16 kHz mono audio.

#### Re-decode Parakeet spans behind silence when greedy TDT stops emitting early
`Asr.decode`: Parakeet's greedy TDT search occasionally stops emitting part-way
through a span (seen on real spans, fixed by moving the start by a
few hundred ms). When the words end well before the audio does,
decode again behind a little silence and keep the fuller result.

#### Pad spans under 100 ms because the front end needs more audio
`decode_once`: Spans shorter than 100 ms give the front end too little to read.

### `LinuxWindows/crates/lokalbot-speech/src/attribution.rs`

#### Diarization partitions audio before recognition; server word timing is the exception
Speaker labels and attribution (`AttributedTrackTranscriber`).

Diarization partitions the audio before recognition: the track timeline is
cut at every turn boundary, so text is never divided across speakers and
overlapping voices never inherit a majority label. The microphone gives
`local`, `local N`, `local unclear`; system audio gives `them`, `them N`,
`them unclear`. A server that times words is the exception: its clips span turns,
and [`attribute_words`] splits its text at the words where the speaker changes.

#### Mic track, diarization and legacy speech follow 'My microphone is me'
`apply_microphone_default`: `SpeakerAttribution.applyingMicrophoneDefault`: microphone track,
diarization and legacy speech follow "My microphone is me".

#### Track cut at turn boundaries: one speaker numbered, overlap unclear, none keeps track label
`regions`: The timeline of a track cut at every turn boundary: one active speaker
gives `prefix N` (numbered by first appearance), overlap gives
`prefix unclear`, no turn keeps the track label. Equal neighbours merge.

#### Renumber by first appearance among text-bearing segments so silent voices don't shift labels
`renumber_speakers`: Renumbers `prefix N` labels by first appearance among the segments that
carry text, so a voice that never said anything (residual bleed, a cough)
does not leave the first speaker labelled `local 2`.

#### Words within 1 s of a turn take that speaker; diarizer and word edges disagree
`WORD_GAP_TOLERANCE`: Words this close to a speaker turn take that speaker (`wordGapTolerance`).
Diarizer turn edges and word edges disagree by a few hundred milliseconds.

#### A 0.75 s pause between words starts a new segment
`WORD_PAUSE_SPLIT`: A pause this long between words starts a new segment (`wordPauseSplit`).

#### No segment grows past 15 s
`MAX_SEGMENT_SECONDS`: No segment grows past this (`maxSegmentSeconds`).

#### Empty words means the clip keeps one speaker chosen at its midpoint
`AlignedSegment.words`: Empty: the clip keeps one speaker, chosen at its midpoint.

#### Return None when a word is not found so the clip stays whole instead of guessing
`word_starts`: Where each word begins in `text`, matched in order on its letters and digits.
`None` when a word can't be found, so the caller keeps the clip whole rather
than guessing a cut (`wordStarts`).

#### Split clips at speaker change, pause or max length; text cut, never divided proportionally
`attribute_words`: Splits each clip where its words change speaker, pause, or would outgrow
[`MAX_SEGMENT_SECONDS`] (`AttributedTrackTranscriber.attribute`). One active turn
names the speaker, overlapping turns are unclear, and words away from every turn
keep the track label. Text is cut from the clip, never divided proportionally.
Speaker pieces then widen to the edges of their own turns, without crossing a
neighbour, so acoustic turns stay supported.

#### A word absent from the text must not cause a guessed cut
`a_clip_without_usable_word_times_keeps_one_speaker_at_its_midpoint`: A word the text doesn't hold: no guessing at a cut.

### `LinuxWindows/crates/lokalbot-speech/src/bleed_gate.rs`

#### Bleed gate attenuates mic frames explained by delayed system signal by 30 dB in model copy
Speaker bleed before recognition: without headphones the microphone picks
up the remote side a few tens of milliseconds after the system track
carries it. Mic frames whose energy is explained by the delayed system
signal are attenuated by 30 dB in the copy the models hear (the recording
is untouched), like the residual suppressor in macOS's `EchoCanceller`.
Nothing is gated unless the two envelopes show a clear, consistent bleed.

#### Frames are 20 ms at 16 kHz
`FRAME`: 20 ms frames at 16 kHz.

#### Speaker-to-mic delays searched are 0–400 ms
`MAX_LAG_FRAMES`: Speaker-to-microphone delays searched: 0–400 ms.

#### Log-envelope correlation of 0.5 over remote-speech frames needed before gating
`MIN_CORRELATION`: Log-envelope correlation (over remote-speech frames) needed before any gating.

#### Bleed weaker than −40 dB is left alone
`MIN_GAIN`: Bleed weaker than −40 dB is left alone.

#### Frame is bleed when mic is within +8 dB of predicted bleed
`MARGIN`: A frame is bleed when the mic is at most this far above the predicted bleed (+8 dB).

#### Keep frames around detected local speech so word edges survive
`KEEP_AROUND`: Frames kept around detected local speech so word edges survive.

#### Envelope is frame RMS of 16 kHz audio in 20 ms frames
`envelope`: Frame RMS of 16 kHz audio (20 ms frames).

#### Inputs are 16 kHz on the same timeline; None when no bleed is evident
`BleedGate::detect`: Analyses both tracks (16 kHz, same timeline); `None` when no bleed is evident.

#### Only frames where the remote side is clearly active inform bleed
`BleedGate::from_envelopes`: Only frames where the remote side is clearly active tell us about bleed.

#### Correlate log envelopes at acoustic delay, excluding local speech and double talk
`BleedGate::from_envelopes`: Where the remote side talks, a bleeding mic follows its syllables:
log envelopes correlate at the acoustic delay. Frames where the mic
is far above the typical ratio (local speech, double talk) are left
out; with headphones the mic does not follow at all.

#### Gain is the quieter quartile where the user is silent
`BleedGate::from_envelopes`: The quieter quartile: frames where the user is silent and the mic hears only bleed.

#### Keep a margin around local speech so onsets and endings are not cut
`BleedGate::from_envelopes`: Keep a margin around local speech so onsets and word endings are not cut.

#### Frame gains are applied with 5 ms ramps between frames
`BleedGate::apply`: Applies the frame gains with 5 ms ramps between frames.

### `LinuxWindows/crates/lokalbot-speech/src/diarize.rs`

#### Diarization via pyannote segmentation, embeddings and clustering replaces macOS CoreML diarizers
Speaker separation within one track: pyannote segmentation 3.0 finds who
speaks when, speaker embeddings tell the voices apart, and clustering
numbers them. Replaces macOS's Nemotron/Pyannote CoreML diarizers.

#### Threshold 0.75 for TitaNet-small; 0.7–0.8 correct, 0.5 split one voice
`CLUSTER_THRESHOLD`: Clustering threshold for TitaNet-small embeddings; lower keeps more voices
apart. 0.7–0.8 separated 2 and 4 synthetic voices correctly where 0.5
split one voice in two.

#### Tracks under 2 s are not separated
`MIN_SECONDS`: Tracks shorter than this are not worth separating.

#### Turns of 16 kHz mono samples are sorted by start
`Diarizer.turns`: Speaker turns of 16 kHz mono `samples`, sorted by start.

### `LinuxWindows/crates/lokalbot-speech/src/echo.rs`

#### Adaptive filter subtracts predictable echo of system track from mic copy; recording untouched
Subtracts the meeting's remote audio from the microphone copy the models
hear (`EchoCanceller.swift`, `EchoCancelledTrack.swift`). The recording
stays untouched.

With the user on speakers, the remote voice travels through the room back
into the microphone. The system track is the very signal that echo was made
from, so the echo is predictable where the user's voice is not: an adaptive
filter learns the path from the speakers into the microphone, and what its
prediction doesn't explain is the user.

#### 1536 taps is 96 ms at 16 kHz: echo tail plus clock drift
`TAPS`: 96 ms at 16 kHz: the room's echo tail plus leftover clock drift.

#### Freeze adaptation when mic exceeds what reference explains, to not cancel the user
`DOUBLE_TALK_MARGIN`: Adaptation freezes when the microphone is louder than the reference could
explain: that is the user talking, and the filter would learn to cancel them.

#### Window energy stands for reference RMS of about 0.01 (-40 dBFS)
`REFERENCE_ACTIVITY_FLOOR`: Window energy standing for a reference RMS of about 0.01 (-40 dBFS).

#### Marginal reductions are transcribed from the untouched track instead
`MINIMUM_ACCEPTED_REDUCTION_DB`: A marginal result is more safely transcribed from the untouched track.

#### Normalized LMS because capture clocks drift and the room changes
`EchoCanceller`: Normalized LMS rather than a fixed filter, because the path isn't fixed:
the capture clocks drift and the room changes.

#### Store every sample twice so the latest TAPS are one contiguous slice
`EchoCanceller.history`: Every sample twice, so the latest `TAPS` are always one contiguous slice.

#### Microphone and reference must be aligned and equally long
`EchoCanceller.process`: `microphone` and `reference` must be aligned and equally long.

#### Recompute window energy periodically since rounding accumulates over millions of samples
`EchoCanceller.process`: Rounding accumulates over tens of millions of samples.

#### Push echo-only frames to noise floor; gating to silence made models hallucinate
`EchoCanceller.suppress_residual`: Pushes frames that were nothing but echo down to the noise floor.
Subtraction alone leaves the echo about 13 dB down, which speech models
still transcribe; gating to silence made them hallucinate on the edges.

#### Zero reduction is correct when the user wears headphones
`EchoCanceller.reduction_db`: How much of the microphone's energy was removed. Zero is the correct
answer when the user wears headphones.

#### Correlate loudness contours; nudge estimate early one frame since filter is causal
`estimate_delay`: How far the microphone lags the system track. Correlating loudness
contours: the delay survives codecs and room colouring. A causal filter
can't reach forwards, so the estimate is nudged early by a frame.

#### Corrects small clock-rate difference; a missing reference stays silence
`resampled`: Corrects a small clock-rate difference. A missing reference stays silence.

#### Cleaned copy only when it passed; otherwise the bleed gate is used
`EchoRemoval.cleaned`: The cleaned copy, when it passed; the bleed gate is used otherwise.

#### When removal cannot finish the original speech is preserved
`echo_failed`: Removal could not finish, so the original speech was preserved.

#### Clean in 30 s windows; with a known clock, unmappable chunks stay as recorded
`remove_echo`: Cleans `microphone` in 30 s windows, keeping a chunk only when it removed
enough. A known capture gap is stronger evidence than an acoustic guess:
with a clock, a chunk it can't map is left as recorded. `None` when cancelled.

#### Don't stretch a missing tail or truncated reference over speech
`remove_echo`: Don't stretch a missing tail or truncated reference over speech.

### `LinuxWindows/crates/lokalbot-speech/src/echo_evidence.rs`

#### Waveform evidence is a narrow fallback for near-identical digital echoes; words alone can't delete speech
A narrow fallback for near-identical digital echoes
(`EchoWaveformEvidence.swift`). Normal room echoes are handled by echo
cancellation; words alone can't authorize deleting speech.

#### Echo waveform compared only over 1–30 s of speech
`MIN_SECONDS`: An echo's waveform is compared only over this much speech.

#### One second at 16 kHz
`MIN_SAMPLES`: One second at 16 kHz.

#### Compared spans may differ by at most 32 samples
`MAX_LENGTH_DIFFERENCE`: The two spans may differ by this many samples.

#### Below this power the call track is silent
`MIN_REFERENCE_POWER`: Below this the call track is silent.

#### Uncalibrated conservative flag means uncertainty, never identity
`SUSPECTED_CORRELATION`: This uncalibrated conservative flag means uncertainty, never identity.

#### Accept only near-exact copies, not same words by two people or mixtures with a quiet reply
`IDENTICAL_CORRELATION`: Accepts only near-exact copies, not two people speaking the same words, or
a mixture containing a quiet reply.

#### Verified rows are proven by waveform to be copies of the call track
`EchoAnalysis.verified`: Rows the waveform proves are copies of the call track.

#### Suspected rows follow call loudness and never delete speech
`EchoAnalysis.suspected`: Rows whose loudness follows the call track. It never deletes speech.

#### Unmappable rows are skipped with anchors; without any, same second on each track
`analyze`: With clock anchors, a row they can't map isn't compared. Without
any, the same second on each track is the best known alignment.

#### Acoustic suspicion needs neither identical words nor the same language
`analyze`: Acoustic suspicion doesn't require the recognizer to choose identical
words, or even the same language.

#### Loudness contour tolerates room coloration and playback delay
`suspected_echo`: The loudness contour tolerates room coloration and playback delay.

#### Decimated comparison keeps the bounded fallback inexpensive
`near_identical`: Decimated waveform comparison keeps the bounded fallback inexpensive.

#### Read 16 kHz spans without holding the whole track in memory
`SpanReader`: Reads spans of a track at 16 kHz without holding the track in memory.

### `LinuxWindows/crates/lokalbot-speech/src/kokoro.rs`

#### Kokoro runs in-process here versus Mac's command-line tool, so audio stays in memory
Read aloud with Kokoro 82M (`KokoroSpeechEngine.swift`). The Mac runs
sherpa-onnx's command-line tool; here the library runs in-process, so the
audio stays in memory unless the user exports it.

#### Two threads like the Mac so reading aloud doesn't take over the computer
`THREADS`: The Mac's `--num-threads=2`: reading aloud should not take over the computer.

#### Voice id is stored in settings as speechVoice
`Voice.id`: Stored in settings (`speechVoice`).

#### Fall back to Heart when a stored voice is unknown to this build
`voice`: The stored voice, or Heart when a library holds one this build doesn't know.

#### Clamp stored speed to model range; unusable values read at 1×
`clamped_speed`: The stored speed within what the model takes; anything unusable reads at 1×.

#### Sanitize markdown for speech: drop code blocks, keep link text, strip citations
`plain_text`: Markdown as text worth saying (`SpeechTextSanitizer`): code blocks go, links
keep their text, citations and markup go, whitespace collapses.

#### Mirror the Mac config: both lexicons, espeak data, two threads
`Kokoro.load`: Loads the downloaded model. The Mac's configuration: both lexicons,
espeak data for other words, two threads.

#### Speed 0.5–2.0×; cancel takes effect between sentences
`Kokoro.synthesize`: Reads markdown `text` with one voice at `speed` (0.5–2.0×). `cancel`
stops it between sentences.

#### Strip NULs because C strings end at a NUL
`synthesis_text`: What the model is given, or `None` when nothing is left to say. C strings
end at a NUL, so one can't reach the library.

#### Real-model test is ignored and needs LOKALBOT_KOKORO_ROOT
`reads_with_the_real_model`: Needs the real model: `LOKALBOT_KOKORO_ROOT=\<library root with the
model> cargo test -p lokalbot-speech kokoro -- --ignored`.

#### Out-of-lexicon words, other scripts and symbols must not abort synthesis
`reads_with_the_real_model`: Words outside the lexicons, other scripts and symbols must not abort.

### `LinuxWindows/crates/lokalbot-speech/src/language.rs`

#### Language coverage comes from pinned models' cards, not the shared picker
Which languages each transcription model can be told to use
(`TranscriptionLanguage.swift`, `TranscriptionLanguageSupport.swift`).
Coverage comes from the pinned models and their publishers' cards; a shared
language picker is not evidence of model support.

#### Auto plus LanguageCode.transcriptionSupported with the Mac's names
`TRANSCRIPTION_LANGUAGES`: `auto` plus `LanguageCode.transcriptionSupported`, with the Mac's names.

#### Parakeet v3 has Ukrainian but detects the language itself
`UkrainianSupport::Detected`: Parakeet v3 has Ukrainian but detects the language itself.

#### Saved Ukrainian choice survives model switches but unsupported models must not silently use another language
`validate_language`: Checked before reading audio or falling back to detection: a saved Ukrainian
choice survives model switches, but a model without it must not silently
transcribe in another language.

#### Model without Ukrainian explains itself whichever language is chosen
`the_picker_disables_and_explains`: A model without Ukrainian says so whichever language is chosen.

### `LinuxWindows/crates/lokalbot-speech/src/lib.rs`

#### Linux/Windows speech crate follows macOS pipeline; mic is Me, system is Them
On-device speech for LokalBot on Linux and Windows, built on sherpa-onnx:
transcription (Qwen3-ASR by default), voice activity detection, speaker
separation and attribution into a [`lokalbot_core::Transcript`].

Follows the macOS pipeline (`ProcessingPipeline`, `AttributedTrackTranscriber`,
`TranscriptSanitizer`): the microphone track is "Me" (`local…`), system
audio is "Them" (`them…`), each optionally split into voices. [`kokoro`]
reads text aloud.

### `LinuxWindows/crates/lokalbot-speech/src/models.rs`

#### Models are pinned sherpa-onnx assets; one download each; install flow and marker
Speech model catalog: transcription models plus voice activity detection
and speaker separation, all sherpa-onnx exports pinned by URL, size and
SHA-256 (GitHub release assets of `k2-fsa/sherpa-onnx`).

Each model is one download: a `.tar.bz2` archive extracted into
[`model_dir`], or a single file saved straight into it. The engine
downloads [`download_info`] to [`download_dest`], extracts archives into
`model_dir`, then calls [`finish_install`], which flattens the archive's
top folder, checks the files and writes the install marker.

#### Qwen3-ASR takes language and hotwords per span
`Family::Qwen3Asr`: Qwen3-ASR: conv front end + encoder + LLM decoder; takes a language and hotwords per span.

#### NeMo transducer gives token timestamps and automatic language
`Family::NemoTransducer`: NeMo transducer (Parakeet TDT); token timestamps, automatic language.

#### SenseVoice language is fixed per recognizer
`Family::SenseVoice`: SenseVoice CTC; language fixed per recognizer.

#### Whisper language fixed per recognizer with 30 s windows
`Family::Whisper`: Whisper encoder/decoder; language fixed per recognizer, 30 s windows.

#### GigaAM NeMo CTC supports one language and no options
`Family::NemoCtc`: NeMo CTC (GigaAM); one language, no options.

#### Top folder inside a .tar.bz2; None for single file
`DownloadInfo.archive_root`: Top folder inside a `.tar.bz2`; `None` for a single file.

#### Id is stored in settings as transcriptionModel and names the folder
`SpeechModel.id`: Stable id stored in settings (`transcriptionModel`) and used for the folder name.

#### ISO 639 codes; empty for support models
`SpeechModel.languages`: ISO 639 codes the model transcribes (empty for support models).

#### Files that must exist in the folder once installed
`SpeechModel.files`: Files that must exist in the model folder once installed.

#### Model uses vocabulary prompt as decoding context
`SpeechModel.supports_prompt`: Uses the vocabulary prompt (names and terms) as decoding context.

#### Language list taken from Qwen3-ASR model card as ISO codes
`QWEN3_LANGUAGES`: Qwen3-ASR's languages (model card), as ISO codes.

#### Whisper covers ~100 languages; list is what the picker offers
`WHISPER_LANGUAGES`: Whisper covers ~100 languages; these are the ones the language picker offers.

#### Titanet-small license follows NVIDIA NGC card under NeMo toolkit
`MODELS`: NVIDIA's NGC card for titanet_small (the model sherpa-onnx
converted) puts it under the NeMo toolkit's license.

#### Pinned after download because GitHub publishes no digest for the asset
`WHISPER_TURBO_SHA256`: Pinned after downloading the release asset (GitHub publishes no digest for it).

#### MODELS order: transcription, then VAD and speaker separation (indices relied on)
`all`: Every speech model: transcription models first, then VAD and speaker separation.

#### Remote model sends audio to user's server so nothing downloads
`is_remote`: Audio goes to the user's transcription server, so nothing downloads for it.

#### Whisper takes vocabulary on Mac but sherpa-onnx gives no way
`accepts_vocabulary`: `acceptsVocabularyPrompt`: the model reads names and terms. Whisper does on
the Mac; sherpa-onnx gives it no way to.

#### Model folder is \<root>/models/speech/\<id>/
`model_dir`: `<root>/models/speech/<id>/`.

#### Archive is a .tar.bz2 extracted into model_dir; otherwise the file is the model
`ModelDownload.archive`: A `.tar.bz2` to extract into [`model_dir`] (otherwise the file is the model).

#### Archives go to .downloads; single files straight to final path
`download_dest`: Where the download goes: archives into `<root>/models/speech/.downloads/`,
single files straight to their final path inside [`model_dir`].

#### Upstream replaced Parakeet archives 2026-11-07 with identical output; keep old installs valid
`earlier_archives`: Archives this app pinned before, whose installs stay in use.

Upstream replaced both Parakeet archives on 2026-11-07 with a new export
of the same weights, under the same names. The ones below are what this
app downloaded, checked against its pin and ran until then. The previous
model files, still in the Hugging Face mirror's history, gave the same
text as the new export on the archives' own clips and on the sample
meetings, so someone who has one installed is not made to download half
a gigabyte again. New downloads get the archive pinned in the catalog.

#### Installed means files present and marker names pinned or earlier accepted archive
`is_installed`: Whether every file is present and the install marker names the pinned
download, or an earlier one that is still accepted.

#### Flatten archive folder, drop sample audio, verify files, write marker
`finish_install`: Finishes an install after the engine downloaded (and, for archives,
extracted) the model into [`model_dir`]: moves the archive's top folder
up, drops sample audio shipped with it, checks every file and writes the
marker [`is_installed`] looks for.

#### Users with earlier Parakeet archive keep a working model after update
`a_parakeet_installed_from_the_earlier_archive_is_still_installed`: Someone who installed Parakeet before upstream replaced its archive
keeps a working model after updating the app.

#### Failed attempt already moved files up; retry completes the folder
`install_flattens_archives_and_writes_a_marker`: The failed attempt already moved the files up; complete the folder.

### `LinuxWindows/crates/lokalbot-speech/src/sanitize.rs`

#### Sanitizer removes only objectively pathological ASR output; emphasis is kept
`TranscriptSanitizer`: removes only objectively pathological ASR output —
extreme repetition, rows that merely repeat the vocabulary prompt, and
precisely timed rows too fast to be speech. Ordinary emphasis is kept.

#### Precisely timed rows with 8+ words at 10 words/s are aligner artifacts
`IMPLAUSIBLE_MIN_WORDS`: A precisely timed row with at least this many words at this rate is not
speech (a forced aligner packing invented words into a near-silent gap).

#### Prompt is the vocabulary prompt used for the transcript, when known
`sanitize`: Sanitizes `transcript` in place. `prompt` is the vocabulary prompt the
transcript was made with, when known.

#### Collapse 8+ identical letters/punctuation to 3; never digits
`collapse_extreme_character_runs`: Collapses runs of 8 or more identical letters or punctuation marks to 3;
digits are never collapsed (amounts, identifiers).

#### Delete repeated word cycles keeping two; remove only the repeated span
`collapse_repeated_cycles`: Deletes repeated word cycles (period ≤ 32, ≥ 4 repetitions, ≥ 24 redundant
words, or a single word ≥ 8 times), keeping two cycles. Only the repeated
span is removed so unrelated text keeps its exact form.

### `LinuxWindows/crates/lokalbot-speech/src/text.rs`

#### Strip Whisper control tokens, collapse whitespace; empty if nothing alphanumeric
`normalized_text`: `Transcript.normalizedText`: Whisper-style `<|…|>` control tokens removed,
whitespace collapsed, and empty when nothing alphanumeric is left.

#### Fold case and accents so name variants are one word
`folded_words`: Lowercased, accent-folded letter/digit runs (apostrophes kept inside words),
so "Marković", "Markovic" and "MARKOVIC" are one word.

#### Mirror TranscriptionPrompt.normalized: trimmed prompt or None when blank
`normalized_prompt`: `TranscriptionPrompt.normalized`: the trimmed prompt, or `None` when blank.

#### Qwen3-ASR returns the hint list itself on near-silent spans
`PromptEcho`: Text a prompt-capable model copied from its vocabulary prompt instead of
hearing (`TranscriptionPromptEcho`): on near-silent spans Qwen3-ASR returns
the hint list itself as a row of words.

#### Echo needs all prompt words and more than one listed term; a lone name may be spoken
`PromptEcho.matches`: Every word is a prompt word and the row is more than one listed term
(a lone "Mila Novak" may be someone saying a name).

#### Hotword list limits: at most 40 terms and 480 characters
`prompt_terms`: Vocabulary prompt → hotword list for Qwen3-ASR: the comma-, semicolon- or
line-separated terms, trimmed of trailing punctuation, at most 40 terms and
480 characters (`TranscriptionVocabulary` limits).

#### Join with a space between words, none between CJK characters
`join_texts`: Joins span texts: a space between words, none between CJK characters.

### `LinuxWindows/crates/lokalbot-speech/src/transcriber.rs`

#### Rust twin of macOS transcription pipeline, attributed transcriber and dictation final pass
Meeting and dictation transcription (`ProcessingPipeline` transcription
stage, `AttributedTrackTranscriber`, `DictationCoordinator` final pass).

#### Recordings under 0.3 s are not transcribed, as on Mac
`MIN_AUDIO_SECONDS`: Shorter recordings are not transcribed (`AudioFileInspector.minimumTranscribableDuration`).

#### Less than 0.5 s detected speech counts as none
`MIN_SPEECH_SECONDS`: Less detected speech than this counts as none (`ProcessingPipeline`, `DictationCoordinator`).

#### Diarization slivers under 0.8 s join a neighbour instead of decoding alone
`MIN_PIECE_SECONDS`: Diarization slivers shorter than this join their neighbour instead of being decoded alone.

#### One request and transcript line per 15 s window so bleed filter can compare
`SERVER_WINDOW_SECONDS`: `RemoteTranscriptionEngine.lineWindows`: one request and one transcript line
per window, short enough for the speaker-bleed filter to compare.

#### Concurrent uploads of 3 matches Mac's maximumConcurrentRequests
`SERVER_UPLOADS`: `maximumConcurrentRequests`.

#### OpenAI rejects audio under 0.1 s and slivers hold no words
`SERVER_MINIMUM_SAMPLES`: OpenAI rejects audio shorter than 0.1 s, and such slivers hold no words.

#### User-chosen server transcribes; speech detection and separation stay local
`SpeechServer`: A speech-to-text server the user chose (`RemoteTranscriptionEngine`). Speech
detection and speaker separation still run on this computer.

#### Takes a 16 kHz mono clip; cancel stops a retry waiting
`SpeechServer.transcribe`: The text of one 16 kHz mono clip. `cancel` stops a retry from waiting.

#### Server timing words lets clips span speaker turns
`SpeechServer.provides_word_timings`: The server times words itself, so its clips can span speaker turns.

#### Word times are relative to the clip where given
`SpeechServer.transcribe_timed`: One clip's text, with word times relative to the clip where it gives them.

#### Name is stored as the transcript engine
`Recognizer::Server.name`: Stored as the transcript's `engine`.

#### ISO code, or None/auto to detect
`TranscribeOptions.language`: ISO code, or `None`/`"auto"` to detect.

#### Separate speakers within each track (multiSpeakerDiarization)
`TranscribeOptions.diarize`: Separate speakers within each track (`multiSpeakerDiarization`).

#### Maps to the 'My microphone is me' setting
`TranscribeOptions.microphone_is_user`: "My microphone is me" (`microphoneIsUser`).

#### Names and terms to spell correctly, prompt-capable models only
`TranscribeOptions.vocabulary_prompt`: Names and terms to spell correctly (prompt-capable models only).

#### Reviewed range in seconds; outside audio left out, times stay on original timeline
`TranscribeOptions.content_range`: The meeting's reviewed start and end, in seconds on the recording's
timeline (`Meeting.contentRange`). Audio outside it is left out, and
times stay on the original timeline.

#### Measure voices for remembering speakers, never for the sample meeting
`TranscribeOptions.collect_voice_samples`: Measure voices for remembering speakers (never for the sample meeting).

#### Echo cancellation subtracts the call from the mic copy given track alignment
`TranscribeOptions.echo`: Subtract the call from the microphone copy (`echoCancellation`), with
how the two tracks line up.

#### Clock aligns tracks for the echo check on finished rows, independent of echo
`TranscribeOptions.clock`: How the two tracks line up, for the echo check on finished rows. It
runs whether or not `echo` does.

#### Private voice evidence never joins the transcript or saved files in clear
`DetailedTranscript`: A transcript with the private voice evidence that goes with it. The
evidence never joins the transcript or anything saved beside it in clear.

#### Clean diarizer turns in the transcript's labels
`DetailedTranscript.turns`: Clean diarizer turns, in the transcript's labels.

#### Voice vectors in the transcript's labels
`DetailedTranscript.samples`: Voice vectors, in the transcript's labels.

#### Fraction is share of detected speech decoded, 0–1
`TranscribeProgress::Transcribing`: Share of detected speech decoded so far, 0–1.

#### Times are seconds from the start of the samples
`RawSegment`: One decoded span, seconds from the start of the samples.

#### Diarizer turns kept to attribute a server's timed words
`TrackPlan.diarized`: The diarizer's turns, for attributing a server's timed words.

#### Lock per span so dictation and meeting passes share a transcriber without waiting for whole recordings
`Transcriber.decoding`: Held for one span on the local recognizer. A dictation and a meeting
pass can then share this transcriber: each waits for the other's
current span, never for its whole recording.

#### Silero VAD used when installed, else energy detector
`Transcriber::load`: Loads `model_id` (see [`models::transcription_models`]) with `threads`
inference threads. Silero VAD is used when installed; without it an
energy detector finds speech.

#### Caller must have checked the server may receive audio
`Transcriber::with_server`: Transcribes through `server`; `name` is stored as the transcript's
`engine`. The caller has checked that the server may receive audio.

#### Refuse unsupported language before any audio is read
`Transcriber.check_language`: Refuses a language this model can't be told to use, before any audio is read.

#### Fair unlock hands the decode lock to waiters before the caller's next span
`Transcriber.decode`: To whoever waited through this span, before this caller's next one.

#### At most three concurrent uploads, order kept, first failure stops the rest
`Transcriber.upload_pieces`: Sends every piece to the server, at most three at a time, keeping their
order. The first failure stops the rest.

#### Cancellation takes effect at the next span and returns Cancelled
`Transcriber.cancel`: Stops the transcription in progress at the next span; it returns
[`SpeechError::Cancelled`].

#### Meetings still transcribe without the voice model; voices just aren't measured
`Transcriber.voice_extractor`: The voice model, once. Without it a meeting is still transcribed; only
its voices aren't measured.

#### No speakers; prompt is the user's vocabulary for the live preview
`Transcriber.transcribe_samples`: Transcribes 16 kHz mono samples span by span (no speakers). `prompt`
is the user's vocabulary, for the live preview.

#### Mic is local, system is them, sorted by start; a failing track doesn't stop the other
`Transcriber.transcribe_meeting`: Transcribes a meeting's tracks into one speaker-attributed transcript:
microphone speech is `local…`, system audio `them…`, segments sorted by
start. A track that fails does not stop the other; the first error is
returned at the end, as on macOS.

#### Use bleed gating only when no echo-cleaned copy exists
`Transcriber.transcribe_meeting_detailed`: A cleaned copy has had the far side subtracted; otherwise fall back
to gating the frames the far side explains.

#### Label turns after decoding because renumber_speakers changed labels
`Transcriber.transcribe_meeting_detailed`: Labeled now because `renumber_speakers` changed them while decoding.

#### Echo failure falls back to recorded track; duplicate removal needs waveform evidence
`Transcriber.check_for_echo`: The microphone with the far side subtracted, when that is asked for
and it passes. Failing here only means the track is used as recorded.
Words alone only mark a microphone row as possible echo; removing a
full duplicate also takes matching waveform evidence
(`EchoWaveformEvidence`, `SpeakerBleedFilter`).

#### Word-timing servers hear neighbouring turns together and split by words
`Transcriber.decode_track`: A server that times words hears neighbouring turns together, and its words
say who spoke. Turns don't cut the clips, which stay as short as any other.

#### Without speaker turns a server gets neighbouring speech in one request
`Transcriber.decode_track`: Without speaker turns a server gets neighbouring speech in one request.

#### Skip a rejected sub-1 s span rather than fail the meeting
`Transcriber.decode_track`: Losing a sliver is better than failing the meeting.

#### Split long spans at pauses over 1 s and sentence ends after ~200 chars
`Transcriber.segments_of`: Text of one decoded span as timeline segments: token timestamps split a
long span at pauses over 1 s and at sentence ends after ~200
characters (`ParakeetEngine` grouping); otherwise the span is one row.

#### Retry once without prompt when result is empty with 1 s+ speech
`Transcriber.transcribe_dictation_with_prompt`: Dictation with the vocabulary prompt; an empty result with at least
1 s of speech is retried once without it (`DictationCoordinator`).

#### Decode short dictations as one window to keep pause context
`Transcriber.transcribe_dictation_with_prompt`: Short dictations decode as one window so pauses keep their context.

#### Needs no speech model and never downloads the voice model; Err means can't run now
`analyze_call_voices`: Voice samples of a call track that was already transcribed, in `transcript`'s
labels, for learning from saved meetings. Needs no speech model, and never
downloads the voice model: `Err` means analysis can't run now.

#### Cap onnxruntime threads: 4–8 best on Linux, 4 on Windows, 16 is slower
`effective_threads`: onnxruntime slows down past a few threads: on Linux 4–8 threads were
fastest and 16 slower; on Windows (i5-13400F) Qwen3-ASR was fastest at 4
and took 4× longer at 16. Requests are capped accordingly.

#### Models hear subtracted or gated mic; the recording never changes
`Heard`: What the models hear of a track: the microphone with the far side
subtracted or gated. The recording itself never changes.

#### Silence before range, drop after, so times keep their place on the recording
`limit_to_range`: Silences audio before the range and drops audio after it, so speech is
cut at both boundaries and every time keeps its place on the recording
(`AttributedTrackTranscriber` partitions the audio the same way).

#### Cut spans at voice handovers, join padding to neighbours, fold slivers, cap length
`pieces`: VAD spans cut where one voice hands over to another (each piece has one
label). Stretches of a span outside every turn join the neighbouring voice
(the padding around a turn is not a new speaker), slivers fold into their
longer neighbour, then pieces are capped at `max` seconds.

#### Fold slivers into the longer neighbour so no word is decoded alone
`pieces`: Fold slivers into the longer neighbour so no word is decoded alone.

#### Drop clips with no text or only the prompt repeated
`word_timed_clips`: A server's clips with their words moved onto the track's timeline. A clip with
no text, or that only repeats the prompt, is left out.

#### Use token rows only when tokens spell the text; else None
`token_rows`: Rows from token timestamps, or `None` when the tokens do not spell the text.

#### Long pauses let the energy detector find separate spans
`speech_with_pauses`: A tone with long pauses, so the energy detector finds separate spans.

#### Word-timed server gets one clip across the turn, no longer than others
`a_server_that_times_words_hears_turns_together_and_splits_them_by_word`: One clip across the turn, no longer than any other.

#### Segments stay in audio order whichever upload finishes first
`a_meeting_goes_to_the_server_three_clips_at_a_time`: In the audio's order, whichever upload finished first.

#### First answer echoed the prompt; the retry without it counts
`dictation_retries_without_the_vocabulary`: The first answer echoed the prompt; the second, without it, counts.

### `LinuxWindows/crates/lokalbot-speech/src/vad.rs`

#### Cap speech regions on time axis; decode each span separately
Speech regions (`SpeechActivity` + `SpeechActivitySpans.swift`): Silero VAD
finds speech, regions are capped in length on the time axis, and each span
is decoded on its own so it keeps real start and end times.

#### Silero VAD consumes 512-sample windows at 16 kHz
`WINDOW`: Silero processes 512-sample windows at 16 kHz.

#### Detector regions are at most 14 s, matching SpeechActivity
`MAX_SPEECH_SECONDS`: Longest region the detector emits (`SpeechActivity`: at most 14 s).

#### Pad regions so word onsets and endings are not clipped
`PADDING_SECONDS`: Audio kept around each region so word onsets and endings are not clipped.

#### No model means an energy-based detector is used instead
`Vad::new`: `model` is `silero_vad.onnx`; `None` uses an energy detector instead.

#### Takes 16 kHz samples, returns slightly padded regions in seconds
`Vad::speech`: Speech regions of 16 kHz `samples`, padded slightly, in seconds.

#### Energy fallback: 30 ms frames, adaptive floor, joins pauses under 0.4 s
`energy_regions`: Fallback when the VAD model is missing: 30 ms frames above an adaptive
noise floor, joined across pauses shorter than 0.4 s.

#### Mirrors SpeechActivity.split: pieces of at most max seconds
`split`: `SpeechActivity.split`: cuts every span into pieces of at most `max` seconds.

### `LinuxWindows/crates/lokalbot-speech/src/voice.rs`

#### Embed each diarized chunk separately because sherpa-onnx returns only turns
Voice samples for remembering speakers. macOS gets per-speaker chunk
embeddings from its diarizer; sherpa-onnx returns only turns, so each chunk
here is embedded separately from that speaker's own audio.

#### Voice chunks are 3 to 10 s of one voice, like the Mac
`MIN_CHUNK_SECONDS`: A chunk is 3–10 s of one voice, like the Mac's.

#### Call speech pauses between sentences; a pause is not another person
`CALL_PAUSE_SECONDS`: Call speech pauses between sentences, and a pause is not another person.

#### Microphone samples must sit inside one uninterrupted turn
`MICROPHONE_PAUSE_SECONDS`: A microphone sample has to sit inside one uninterrupted turn.

#### Keep 24 chunks, more than matching reads (16 call, 8 mic)
`CHUNKS_PER_VOICE`: More than matching ever reads (16 for a call voice, 8 for a microphone).

#### Voice embeddings use TitaNet-small through sherpa-onnx
`VoiceExtractor`: TitaNet-small through sherpa-onnx.

#### Reject models whose vectors differ from VOICE_DIMENSION
`VoiceExtractor::load`: Fails when the model's vectors aren't [`VOICE_DIMENSION`] long, so a
different model can't write samples under [`VOICE_MODEL`].

#### Embeds 16 kHz mono samples, None when too few
`VoiceExtractor::embed`: A voice vector of 16 kHz mono `samples`, when there are enough.

#### A chunk is one speaker's stretch plus frames that are their voice
`VoiceChunk`: One speaker's stretch of a track, and which parts of it are their voice.

#### Keep only parts of turns no other speaker overlaps
`clean_turns`: The parts of each turn no other speaker overlaps, in time order.

#### Chunks are contiguous single-voice speech; keep the longest per voice
`voice_chunks`: Windows of contiguous speech from one voice, with no other voice between
their turns. The longest of each voice are kept.

#### A pause can carry the next turn past the window end
`voice_chunks`: A pause can carry the next turn past this window's end.

#### Embed only the speaker's own frames; speaker id is diarizer's until labelled
`voice_samples`: Vectors for a track's chunks, hearing only each speaker's own frames. The
`speaker` is the diarizer's until `lokalbot_core::voice::label_samples` runs.

#### Shape diarizer turns as label_turns expects them
`raw_turns`: A diarizer turn as `lokalbot_core::voice::label_turns` wants it.

#### Pause joins first two turns; other voice ends that chunk
`chunks_hold_one_voice_and_stay_within_the_limits`: The pause joined the first two; the other voice ended that chunk.

#### Short voice dropped; long voice splits and keeps its tail
`chunks_hold_one_voice_and_stay_within_the_limits`: 2 s of voice 2 is too short; 25 s of voice 1 splits, and its 5 s tail stays.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
