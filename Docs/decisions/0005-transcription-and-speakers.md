# 0005. Transcription and speakers

- Status: Accepted
- Date: 2026-11-20

## Context

Transcription turns a meeting's microphone and system tracks, and dictation, into text, labels who spoke, and lets voice memory name speakers across meetings. The Mac app runs Qwen3-ASR on llama.cpp, Whisper, Parakeet and Apple Speech locally, with a CoreML forced aligner, echo cancellation and FluidAudio diarization; the Windows and Linux app runs Parakeet and Qwen3-ASR through onnxruntime with TitaNet voices. Both can send audio to a transcription server the user approves. These decisions were moved here from code comments when the code stopped carrying comments ([ADR 0001](0001-code-carries-no-comments.md)).

## Engines and models

### Qwen3-ASR runs on the bundled llama.cpp server through `/completion`

Both tiers, 1.7B (`LlamaServerRole.qwenASR`) and 0.6B (`LlamaServerRole.qwenASRCompact`), run ggml-org's Q8_0 GGUFs. Against speech-swift's MLX builds on identical windows (Benchmarks/transcribe/QwenLlamaCpp), 1.7B scored AMI WER 17.76% vs 17.80% and Serbian with `sr` and a vocabulary list 12.4% vs 13.4%, about 10–17% slower, in a 2.3 GB server instead of up to 8.5 GB of MLX allocations; 0.6B against MLX 4-bit scored AMI WER 19.47% vs 20.90% (cpWER −0.74), FLEURS 3–4 points and Serbian 11 points better, about 30% slower, in a 1.6 GB server instead of a 2.5 GB process. llama-server's own `/v1/audio/transcriptions` is not used: it puts the language in a user instruction, ignores the system turn and leaves the `language X<asr_text>` prefix in the text. Each window goes to `/completion` with speech-swift's prompt instead, token for token.

Where: `LokalBot/Engines/QwenLlamaASR.swift` (`QwenLlamaASR`).

### The llama.cpp server gets a fixed media marker, three parallel slots and no host prompt cache

llama.cpp randomizes its media marker per process unless it is set, and the prompt must contain the server's marker exactly once. The default 8 GiB host prompt cache grew the benchmark server to 14 GB. Qwen3-ASR requests always send `cache_prompt: false`, because enabling prompt caching across parallel multimodal slots corrupted KV reuse in llama.cpp b12774 and raised Serbian WER from 27.1% to 51-72%; with prompt caching off, `--cache-ram 0` avoids reserving unused host RAM. The server runs with `--parallel 3 --ubatch-size 2048` and `-c 6144` (2,048 tokens per slot, above the ~1,360-token ceiling of a 30 s audio window plus vocabulary prompt and 768 output tokens), and `SpanTranscription.segments(maxConcurrent:)` reads spans sequentially from `SpanAudioReader` while keeping at most three decode requests in flight and returning segments in span order. Measured on the bundled EN/SR/DE sample tracks (35 spans, 672.1 s of audio), three parallel slots cut wall time from 39.27 s (17.12x RT) to 22.16 s (30.33x RT, 1.77x faster) with 13.63% vs 13.44% overall WER (+384 MiB GPU KV/compute, -256 MiB host prompt cache).

Where: `LokalBot/Engines/QwenLlamaASR.swift` (`QwenLlamaASR.mediaMarker`, `QwenLlamaASR.maxConcurrentWindows`, `QwenLlamaASR.contextTokens`, `QwenLlamaASR.serverArguments`), `LokalBot/Engines/SpeechActivitySpans.swift` (`SpanTranscription.segments`), `LokalBot/Engines/QwenASREngine.swift` (`QwenASREngine.transcribe`).

### Pinned models load only reviewed, immutable files

The MLX loader discovers safetensors by extension, so an unreviewed leftover shard in a pinned snapshot is rejected instead of silently joining the pinned weights. WhisperKit searches a nested Hub cache before the model folder and can populate it on a tokenizer parse failure; that mutable fallback is never accepted as the configured pinned tokenizer. The Nemotron diarizer uses the v2 CoreML export, which fixes ANE compilation on M3 and keeps the GA checkpoint weights, from an immutable, integrity-checked cache rather than the upstream downloader's mutable `main` revision.

Where: `LokalBot/Engines/PinnedSpeechModels.swift` (`PinnedModelSnapshot.validateDiscoveredFiles`), `LokalBot/Engines/TranscriptionEngine.swift` (`WhisperEngine.performPreparation`), `LokalBot/Services/Transcription/NemotronDiarizationModels.swift` (`NemotronDiarizationModels`).

### Parakeet archives replaced upstream stay accepted

Upstream replaced both Parakeet archives on 2026-11-07 with a new export of the same weights under the same names. The archives this app downloaded, checked against its pin and ran until then stay accepted, because the previous model files (still in the Hugging Face mirror's history) gave the same text as the new export on the archives' own clips and on the sample meetings; nobody with one installed downloads half a gigabyte again. New downloads get the archive pinned in the catalog.

Where: `LinuxWindows/crates/lokalbot-speech/src/models.rs` (`earlier_archives`).

### Parakeet decodes a span again when its search stops early

Parakeet's greedy TDT search occasionally stops emitting part-way through a span (seen on real spans, fixed by moving the start by a few hundred ms). When the words end well before the audio does, the span is decoded again behind a little silence and the fuller result is kept.

Where: `LinuxWindows/crates/lokalbot-speech/src/asr.rs` (`Asr.decode`).

### Spans shorter than one hop are padded with silence for Qwen

Qwen's mel front end drops the final STFT frame, so fewer than one 160-sample hop (10 ms at 16 kHz) produces zero encoder frames, and speaker boundaries and VAD or split tails can be that short: a 30 s + 11-sample WAV crashed when its final split had no features and `Qwen3AudioEncoder` stacked an empty array. Only the model input is padded; all recorded samples and the original span timestamps are kept, and empty windows stay empty and are skipped by `SpanTranscription` before inference.

Where: `LokalBot/Engines/QwenASREngine.swift` (`QwenASREngine.samplesForInference`), `LokalBotTests/Engines/QwenASREngineTests.swift` (`testSubFrameAudioRetainsSamplesAndProducesEncoderFrames`).

### onnxruntime thread counts are capped

onnxruntime slows down past a few threads: on Linux 4–8 threads were fastest and 16 slower; on Windows (i5-13400F) Qwen3-ASR was fastest at 4 and took 4× longer at 16. Requested thread counts are capped accordingly.

Where: `LinuxWindows/crates/lokalbot-speech/src/transcriber.rs` (`effective_threads`).

### Model setup is single-flight

Swift actors are reentrant at every `await`, so a `guard model == nil` does not stop two callers from downloading or loading the same model concurrently. `AsyncSingleFlight` coalesces overlapping setup calls.

Where: `LokalBot/Engines/TranscriptionEngine.swift` (`AsyncSingleFlight`).

### An urgent speech call is counted only once it holds the model

While the call waits for a pass to give up another model, that pass must not wait for the call, so the call is counted only once its model is in hand.

Where: `LinuxWindows/crates/lokalbot-engine/src/speech.rs` (`SpeechCache::with`).

### A FunASR process's exit is never awaited on the launching thread's run loop

Each `await` in `runBatch` may resume on another thread. While the exit wait depended on the launching thread's run loop, a few dozen runs were enough to strand one forever.

Where: `LokalBotTests/Engines/FunASRNanoRuntimeTests.swift` (`testRepeatedRunsAllReturn`).

### Audio is read one span at a time

`SpanAudioReader` decodes 16 kHz mono Float32 windows straight from the file as each span is needed. Decoding a whole track up front held about 230 MB of samples per recorded hour per track before every speech span was copied out; reading per span keeps at most one span (seconds of audio, a few MB) resident while the ASR model works. It wraps an `AVAudioFile` and is not `Sendable`, so it is created inside the actor-isolated transcribe call and spans are read in order, since reads seek forward only.

Where: `LokalBot/Engines/SpanAudioReader.swift` (`SpanAudioReader`).

### A converted window keeps exactly the source duration

Draining `AVAudioConverter` can emit filter-tail samples beyond the source window (480,011 samples for a 30 s, 48 kHz window). Draining continues, but only the source duration is kept, so the tail cannot lengthen a speaker region or become a tiny extra ASR span.

Where: `LokalBot/Engines/SpanAudioReader.swift` (`SpanAudioReader.convert`).

### The port trims AAC encoder priming itself

Meeting tracks in any format the library selects are read as the 16 kHz mono stream the port's own WAV tracks give; a library recorded on macOS keeps AAC in `mic.m4a`/`system.m4a`, and FLAC reads the same way. Symphonia decodes them but does not trim the priming an AAC encoder adds, so the port trims it from the MP4's edit list or the `iTunSMPB` tag AVFoundation writes, as AVFoundation does on macOS, and transcript times line up with the audio on both platforms.

Where: `LinuxWindows/crates/lokalbot-audio/src/decode.rs`.

### Checkpoints are trusted only on a crash resume of the same setup

A fresh enqueue means "transcribe with today's settings", and checkpoints from an earlier failed attempt may come from a different model, so only a crash resume trusts them. Partial transcripts are invalidated when the diarization model, its weights or the turn policy change.

Where: `LokalBot/Services/Meetings/ProcessingPipeline.swift` (`ProcessingPipeline.process`), `LokalBot/Models/Speakers/DiarizationModel.swift` (`DiarizationModel.checkpointIdentity`).

## Languages

### A language the model can't write is refused, not replaced

The language is checked before reading audio or falling back to detection: a saved Ukrainian choice survives model switches, but a model without it must not silently transcribe in another language. Qwen cannot be told to write Ukrainian and Whisper can, so dictation's stand-in is a downloaded model that fits the language.

Where: `LinuxWindows/crates/lokalbot-speech/src/language.rs` (`validate_language`), `LokalBotTests/Dictation/DictationTranscriptionFallbackTests.swift` (`testTheStandInIsADownloadedModelThatFitsTheLanguage`).

### Serbian is named explicitly to Qwen

Serbian is not on Qwen3-ASR's list, but naming it explicitly measured 14.1% against 17.1% WER on 1.7B and 44.3% against 54.2% on 0.6B, where auto-detection reads it as Croatian (Benchmarks/transcribe/QwenSpanLength). The port does the same on the Mac's measurement.

Where: `LokalBot/Models/Transcription/LanguageCode.swift` (`LanguageCode.transcriptionSupported`), `LinuxWindows/crates/lokalbot-speech/src/asr.rs` (`qwen_language_name`).

### A track's language is voted over its segments by text length

Apple's recognizer judges a long string mostly by its opening, so classifying the joined transcript let one misdetected first window decide a whole track (Benchmarks/transcribe/QwenSpanLength, language section).

Where: `LokalBot/Engines/TranscriptLanguageVote.swift` (`TranscriptLanguageVote`).

### On auto, a track is pinned when one language holds 80% of its text, and a single window never is

With the language on auto, a track is pinned to a supported language that holds at least `minimumShare` (80%) of its text. Mixed-language tracks stay on per-window detection: a 50/50 English–German track votes up to 66% German by text length (Benchmarks/transcribe/QwenSpanLength). A single window's only vote is its own decode, so decoding it again in that language corrects nothing; short dictations are one window, and pinning them doubled their decode time.

Where: `LokalBot/Engines/QwenASREngine.swift` (`QwenASREngine.pinnedLanguage`).

### The first language vote decodes a 12-span sample

Per-window auto-detection misfires on short or accented speech, so a track in one language decodes better pinned to it, and voting on a sample instead of the whole track lets most tracks decode once rather than twice. In Benchmarks/transcribe/QwenLanguageSample, whole AMI meetings and the owner's English and Serbian meetings voted 99–100% one language on any sample of 4 to 16 spans. On code-switched FLEURS tracks the old path left on auto, random samples (one span per group) pinned 4.3% of the time with 8 spans and 2.9% with 12, and 12 costs about 4% of the old decode time more than 8 on long tracks.

Where: `LokalBot/Engines/QwenASREngine.swift` (`QwenASREngine.languageSampleSize`).

### A sample pins the track only at a 90% share

Below it, the track decodes as before sampling: everything on auto, then the whole-track vote at 80%. A sample estimates the share coarsely: at 80%, the sample of a track the whole-track vote left on auto (four Serbian utterances to one English, 79.8%) pinned it; at 85%, random 12-span samples still pinned it 39% of the time, at 90% 23%, and tracks 73% or less in one language almost never. Tracks in one language vote 99–100%, so the stricter share costs them nothing.

Where: `LokalBot/Engines/QwenASREngine.swift` (`QwenASREngine.sampleShare`).

### Serbian, Croatian, Bosnian and Montenegrin vote together and pin to Croatian

To a speech model they are one language. Apple's recognizer reads all of them in Latin script as Croatian (Benchmarks/transcribe/DualASR) and Serbian Cyrillic as Kazakh, with full confidence, or Ukrainian, so Cyrillic text with ђ or ћ (letters only Serbian writes; Macedonian has ѓ and ќ in their place) and none that only another Cyrillic language writes votes Serbian, and the family votes together as Croatian. Croatian is not on Qwen's model card, so these tracks used to stay on auto and slip window by window into Macedonian, Russian or Chinese, with lines in Chinese, Japanese or Hindi script. Pinned to `hr`, Benchmarks/transcribe/DualASR measured 0.1% non-Latin letters, Croatian 24.8% WER against 26.8% on auto and the Montenegrin meeting 38.5% against 38.3%, while `sr` read Serbian better (14.5% against 17.3%) but wrote half of everything in Cyrillic.

Where: `LokalBot/Engines/TranscriptLanguageVote.swift` (`TranscriptLanguageVote.serbianCroatianAliases`), `LokalBot/Engines/QwenASREngine.swift` (`QwenASREngine.pinnedLanguage`), `LokalBot/Models/Transcription/SerbianLatinScript.swift` (`SerbianLatinScript.isSerbianCyrillic`), `LokalBotTests/Engines/LanguageVoteTests.swift` (`testSerbianCroatianAndBosnianTracksPinToCroatianInEitherScript`), `LokalBotTests/Models/Transcription/SerbianLatinScriptTests.swift` (`SerbianLatinScript.isSerbianCyrillic`).

### Serbian-family meeting transcripts are kept in Latin script

Speech models drift between the two scripts mid-meeting: Qwen3-ASR pinned to Serbian writes about half its windows in Cyrillic, and on auto-detect it slips into Macedonian or Russian spellings of Serbian words. A transcript that switches script line by line is hard to read and to search, so it is kept in Latin script, the script LokalBot's own Serbian interface uses.

Where: `LokalBot/Models/Transcription/SerbianLatinScript.swift` (`SerbianLatinScript`).

### Short windows decode in the track's settled language

Decoding a few seconds at a time, auto-detection drifts into other languages and scripts, so the aligned-word path keeps the track's own language. On auto, a track the aligner cannot time falls back to speaker regions, which are too short to detect the language again (Qwen reads breaths and short replies in them as Chinese, Japanese or Russian), so they decode in the language the whole track settled on.

Where: `LokalBot/Services/Transcription/AttributedTrackTranscriber.swift` (`AttributedTrackTranscriber.alignedWordTranscript`), `LokalBotTests/Services/Transcription/WordAttributionTests.swift` (`testRegionsFallbackDecodesInTheLanguageTheTrackSettledOn`).

### Apple Speech locales are resolved over sorted lists

Apple's `supportedLocales` and `supportedLocale(equivalentTo:)` iterate an unordered set and can return arbitrary regional variants (such as `en_IN` or `en_ZA` for `"en"`). Resolving over sorted locale lists keeps the `SpeechAnalyzer` locale and module selection deterministic across runs and matches LokalBot's language picker.

Where: `LokalBot/Models/Transcription/AppleSpeechLocaleResolver.swift` (`AppleSpeechLocaleResolver`).

## Speaker attribution

### Qwen3-ASR transcribes whole tracks and attributes forced-aligned words

Both Qwen tiers transcribe the whole track, then each forced-aligned word goes to the speaker active at that moment. In Benchmarks/transcribe/QwenSpanLength, speaker regions cost 3.0 and 2.8 points of meeting WER on 1.7B and 0.6B, and 9.0 points of AMI WER on 0.6B, which outweighs the aligner being larger than the compact model.

Where: `LokalBot/Engines/TranscriptionEngine.swift` (`SpeakerAttributionStrategy.alignedWords`), `LokalBot/Engines/QwenASREngine.swift` (`QwenASREngine.speakerAttribution`).

### Word timings come from speech-swift's CoreML Qwen3 forced aligner

The CoreML export replaced the MLX 4-bit aligner after attributing as well on identical text (AMI cpWER −0.10, −0.58…+0.36) at about a quarter of the memory (0.9 GB against 3.5–4.1 GB peak footprint; Benchmarks/transcribe/QwenSpanLength/results/2026-11-15). Its shapes are fixed: at most 30 s of audio, and one 768-token pass that holds the prompt, 13 audio tokens a second, and each word with two timestamp slots. Only compiled bundles ship, because an `.mlpackage` would compile on every load.

Where: `LokalBot/Engines/QwenWordAligner.swift` (`QwenWordAligner`), `LokalBotTests/Services/Transcription/WordAttributionTests.swift` (`testAlignerLanguagesAndPinnedSnapshot`).

### Each aligner pass runs in its own autorelease pool

Each CoreML pass returns about 12 MB of autoreleased `MLMultiArray`s, mostly logits, and a track aligns in one task; without a pool per pass they piled up, and the footprint grew from 0.8 GB to 4.6 GB over 101 minutes of audio. An opt-in hardware test checks that many passes over segments of different lengths keep the footprint flat.

Where: `LokalBot/Engines/QwenWordAligner.swift` (`QwenWordAligner.align`), `LokalBotTests/Services/Transcription/WordAttributionTests.swift` (`testCachedAlignerKeepsFootprintFlatAcrossSegments`).

### Decode windows merge to 30 s for 1.7B and stay at 15 s for 0.6B

Word-attribution windows are VAD spans merged across short pauses, and each is one forced-aligner segment. 1.7B gains from long windows, but the CoreML aligner takes at most 30 s, so it merges to 30 s rather than the 60 s it used with the MLX aligner; on AMI the two were within noise. 0.6B decoded long windows 5–10× slower for a small gain, so it stays at 15 s (Benchmarks/transcribe/QwenSpanLength).

Where: `LokalBot/Engines/QwenASREngine.swift` (`QwenASREngine.wordAttributionWindows`), `LokalBotTests/Services/Transcription/WordAttributionTests.swift` (`testQwenTiersAttributeAlignedWordsWithTheirMeasuredWindows`).

### A word within 1 s of a speaker turn takes that speaker

Diarizer turn edges and aligner word edges disagree by a few hundred milliseconds; on AMI a 1 s tolerance gave 34.5% cpWER against 51.1% for a strict midpoint rule (Benchmarks/transcribe/QwenSpanLength).

Where: `LokalBot/Services/Transcription/AttributedTrackTranscriber.swift` (`AttributedTrackTranscriber.wordGapTolerance`).

### Without word timings, diarization cuts the audio before recognition

The track is cut at every turn boundary before ASR, so text is never divided proportionally across speakers and overlapping voices never inherit a majority label. The microphone gives `local`, `local N` and `local unclear`; system audio gives `them`, `them N` and `them unclear`. In the port a server that times words is the exception: its clips span turns, and `attribute_words` splits its text at the words where the speaker changes.

Where: `LokalBot/Services/Transcription/AttributedTrackTranscriber.swift` (`AttributedTrackTranscriber`), `LinuxWindows/crates/lokalbot-speech/src/attribution.rs`.

### Diarization allows one speaker at a time

Each transcript word must have one owner, and FluidAudio 0.18.2 changed the community default to keep overlaps.

Where: `LokalBot/Services/Transcription/NeuralDiarizationEngine.swift` (`NeuralDiarizationEngine.configuration`).

### TitaNet-small clusters at a 0.7–0.8 threshold

A lower threshold keeps more voices apart. 0.7–0.8 separated 2 and 4 synthetic voices correctly, where 0.5 split one voice in two.

Where: `LinuxWindows/crates/lokalbot-speech/src/diarize.rs` (`CLUSTER_THRESHOLD`).

### Slivers too short for an engine are skipped, not failed

Turn boundaries leave slivers shorter than some engines accept: Parakeet rejects audio under 0.3 s, and OpenAI rejects audio under 0.1 s, which holds no words. Losing one sliver is far better than failing the track, and with it the whole meeting, so a failing sliver is skipped, and the port does not send a server any clip under 0.1 s.

Where: `LokalBot/Services/Transcription/AttributedTrackTranscriber.swift` (`AttributedTrackTranscriber.attributedTranscript`), `LinuxWindows/crates/lokalbot-speech/src/transcriber.rs` (`SERVER_MINIMUM_SAMPLES`).

## Echo and speaker bleed

### Echo is removed only from the copy the models hear

The Mac writes a 16 kHz mono echo-cancelled sidecar of the microphone track for the ASR engines, which resample to exactly that anyway; the original `mic.m4a` is never touched and stays the recording the user plays back. Working on the recorded files rather than in the capture path costs a codec generation, since both tracks are AAC by then, but meetings already in the library can be cleaned by re-running transcription, which a capture-time canceller never could. In the port, mic frames whose energy is explained by the system signal, delayed the few tens of milliseconds the bleed takes, are attenuated by 30 dB in the models' copy, like the residual suppressor in the Mac's `EchoCanceller`, and nothing is gated unless the two envelopes show a clear, consistent bleed.

Where: `LokalBot/Services/Audio/EchoCancelledTrack.swift` (`EchoCancelledTrack`), `LinuxWindows/crates/lokalbot-speech/src/bleed_gate.rs`.

### The Mac cancels echo with an adaptive NLMS filter fed by the system track

LokalBot records the raw input device, so the meeting app's own echo cancellation never touches the mic track: with the user on speakers, the remote voice comes back through the room into the microphone and is transcribed a second time as the user. On a real 49-minute call the user's voice sat only 8.2 dB above that echo, enough for VAD and ASR to treat it as a second speaker, and a quarter of the mic transcript was the other side repeated back. The system-audio process tap gives the signal the echo was made from, so an adaptive FIR filter learns the path from the speakers through the room into the microphone, and what it does not predict is the user. It is normalized LMS rather than a fixed filter because the path moves: the two capture clocks drift (10 ms over 45 minutes) and the room changes whenever the laptop moves.

Where: `LokalBot/Services/Audio/EchoCanceller.swift` (`EchoCanceller`).

### The reference is aligned by loudness-envelope correlation first

The two tracks come through different Core Audio paths with their own buffering, and the sound also travels from the speakers to the mic: on a real call the microphone ran about 146 ms behind. An adaptive filter can only look backwards, so the reference is shifted into rough alignment first. Loudness envelopes are correlated rather than waveforms because the bulk delay is a property of the energy contour, which survives AAC encoding and room colouring, and 10 ms frames make the search cheap enough to run on probes from across the whole track.

Where: `LokalBot/Services/Audio/EchoCanceller.swift` (`EchoDelayEstimator`).

### Filter adaptation freezes during double-talk

A microphone louder than the reference could explain is the user talking, and a filter left adapting would learn to cancel them. A first attempt without this guard diverged to -17 dB.

Where: `LokalBot/Services/Audio/EchoCanceller.swift` (`EchoCanceller.Configuration.doubleTalkMargin`).

### Echo-only frames are pushed down, not gated to silence or filled with comfort noise

Subtraction alone leaves the echo about 13 dB down, which speech models still transcribe, so frames that were nothing but echo go down to -30 dB on the Mac and to the noise floor in the port. On a real meeting, gating them to digital silence made ASR hallucinate more (40 invented English segments against 27), because the abrupt edges read as speech onsets and the release clipped real word beginnings. Comfort noise at the room's own floor cut the residual echo further but masked quiet speech, costing a third of the user's real words.

Where: `LokalBot/Services/Audio/EchoCanceller.swift` (`EchoCanceller.Configuration`), `LinuxWindows/crates/lokalbot-speech/src/echo.rs` (`EchoCanceller.suppress_residual`).

### An echo-cancelled track is used only with a clear return-loss margin

Voice Isolation produced only 2.6–3.1 dB of echo return loss on the recordings used to validate this stage, while Standard mode produced at least 12.9 dB. The accepted minimum keeps a deliberate gap between those ranges: a marginal result is more safely transcribed from the untouched microphone track.

Where: `LokalBot/Services/Audio/EchoCancelledTrack.swift` (`EchoCancelledTrack.minimumAcceptedEchoReturnLossDB`).

### Words alone never delete microphone text as echo

A genuine repetition can have identical words and timing. The Mac removes a microphone segment only when a complete, precisely timed remote segment carries the same utterance at the same time: overlap cannot locate a phrase inside a long ASR block, and trimming text without word timestamps would leave the surviving words on false timestamps, so an ambiguous segment survives unchanged and the raw system track stays the clean source. Waveform evidence is a narrow fallback for near-identical digital echoes, with normal room echo left to echo cancellation; in the port words alone only mark uncertainty, and removing a row also takes waveform evidence that the speech crate measures from the tracks.

Where: `LokalBot/Models/Speakers/SpeakerBleedFilter.swift` (`SpeakerBleedFilter`), `LokalBot/Services/Audio/EchoWaveformEvidence.swift` (`EchoWaveformEvidence`), `LinuxWindows/crates/lokalbot-core/src/speaker_bleed.rs`, `LinuxWindows/crates/lokalbot-speech/src/echo_evidence.rs`.

### Suspected echo withholds the microphone's identity instead of deleting text

Microphone segments that mostly repeat simultaneous remote speech need no exact span or token equality and never lose text: callers only withhold the microphone's default identity, so a remote participant's words cannot become the user's evidence. In the notes view, mixed voices and suspected echo cannot outvote the speaker.

Where: `LokalBot/Models/Speakers/SpeakerBleedFilter.swift` (`SpeakerBleedFilter.nearDuplicateEchoIndices`), `LinuxWindows/crates/lokalbot-ai/src/notes/view.rs` (`View::new`).

## Vocabulary, silence and hallucinations

### The vocabulary prompt reads only local, name-level sources

Speech models that take a vocabulary prompt (Whisper, Qwen and Granite 5) are offered names and terms already in the library: calendar attendee display names (never addresses or names derived from addresses), speaker names the user applied in related meetings, project names (Dream projects on the Mac; pinned overnight-review projects and tracked projects in the port) and distinctive meeting-title terms. Speaker evidence, suggestions and voice-profile links are not read.

Where: `LokalBot/Models/Transcription/TranscriptionVocabulary.swift` (`TranscriptionVocabulary`), `LinuxWindows/crates/lokalbot-core/src/vocabulary.rs`.

### Only projects the person pinned become vocabulary

Unpinned Dream projects are model labels, often built from earlier mishearings ("Ave vault accounting and compliance"); as speech-model vocabulary they biased the next transcript toward the same errors. The port reads the pins from `memory/memory.json`.

Where: `LokalBot/Models/Transcription/TranscriptionVocabulary.swift` (`TranscriptionVocabulary.endorsedProjectNames`), `LinuxWindows/crates/lokalbot-core/src/vocabulary.rs` (`endorsed_project_names`).

### Generic title words and placeholder speaker labels stay out of the vocabulary

Department and format words still relate a series' meetings ("Product standup") but are ordinary words a speech model spells on its own; as vocabulary, "Product" came back in prompt-echo rows. Placeholder labels ("Them 6", "Speaker unclear", "Local speaker") and collective words carry no spelling value, and fed to a recognizer a label came back as transcript rows on silent spans.

Where: `LinuxWindows/crates/lokalbot-core/src/vocabulary.rs` (`COMMON_TITLE_WORDS`, `is_placeholder_name`).

### Words imported from Wispr Flow join the person's own vocabulary within the automatic list's budget

An import from Wispr Flow's `flow.sqlite` adds its dictionary to the person's own vocabulary. Snippets, which are text expansions that can hold addresses or signatures, and deleted entries never come in; an entry with a replacement but no snippet flag counts as a snippet; a replacement contributes its replacement only when that is a term of at most four words. One-word everyday English words stay out for the same echo reason as generic title words, words already listed are skipped, and at most 40 words and 480 characters come in, starred and most used first. The database opens like other apps' databases ([ADR 0006](0006-meetings-and-notes.md)) and only its `Dictionary` table is read. Tested with Wispr Flow 1.6.1483, whose schema runs through migration `20261106120000-add-meetings-live-captured-ms`.

Where: `LokalBot/CLISupport/MeetingImport/WisprFlowLibrary.swift` (`WisprFlowLibrary.dictionary`), `LokalBot/Models/Transcription/WisprVocabularyImport.swift` (`WisprVocabularyImport.plan`), `LokalBot/Views/ModelSetup/ModelSupportingSettings.swift` (`ModelTranscriptionOptionsSheet`), `LokalBotTests/CLISupport/MeetingImport/WisprFlowLibraryTests.swift`, `LokalBotTests/Models/Transcription/WisprVocabularyImportTests.swift`.

### Rows that echo the vocabulary prompt are dropped by one definition

On a near-silent span, prompt-capable recognizers (Qwen3-ASR, Whisper) return the hint itself or its tail ("Them 6 · source 2, Mila Novak, Orion Launch, Acme.") as a row of 8–12 words, which forced alignment packs into a sub-second row of its own. Such rows are not speech: they reach the notes model as evidence, fill speaker review and vote in language detection. The Qwen engine drops them so dictation never types the list and the language vote hears only speech, and the track transcriber, `TranscriptSanitizer` and the port's `PromptEcho` drop them by the same definition for engines that don't.

Where: `LokalBot/Models/Transcription/TranscriptionPromptEcho.swift` (`TranscriptionPromptEcho`), `LokalBot/Engines/QwenASREngine.swift` (`QwenASREngine.withoutPromptEchoes`), `LokalBot/Services/Transcription/AttributedTrackTranscriber.swift` (`AttributedTrackTranscriber.transcribe`), `LinuxWindows/crates/lokalbot-speech/src/text.rs` (`PromptEcho`).

### Audio with no detected speech is not decoded

Feeding silence to an ASR model can make it hallucinate words; given a silent stretch, Whisper writes a stock phrase such as "Thank you.", and decoding it is wasted time. A track with no detected speech (a mic muted the whole call) is skipped only on a confident "nothing here": a VAD error returns nil and the track is transcribed anyway, so real audio is never dropped. Speaker regions also cover the pauses between turns, which keeps unattributed speech, so a region without detected speech is not decoded.

Where: `LokalBot/Services/Meetings/ProcessingPipeline.swift` (`ProcessingPipeline.transcribeTrack`), `LokalBot/Services/Transcription/AttributedTrackTranscriber.swift` (`AttributedTrackTranscriber.attributedTranscript`), `LokalBotTests/Services/Transcription/WordAttributionTests.swift` (`testRegionsWithoutDetectedSpeechAreNotDecoded`).

### Silence is a finished result, not a failure to retry

An empty transcript means nothing was said; failing instead kept silent recordings in the failed list and re-ran the speech model on every launch. In the port a merged-gap repair request is recorded before it is queued, so a span that stays empty (silence, for example) is not transcribed again on every launch.

Where: `LokalBot/Services/Meetings/ProcessingPipeline.swift` (`ProcessingPipeline.process`), `LinuxWindows/crates/lokalbot-core/src/health.rs` (`mark_gap_repair_requested`).

### Whisper's English stock phrases are dropped from non-English tracks

Whisper answers audio it cannot make out (a pause, a breath, a faint voice leaking from the other side of a call) with an English stock phrase from its subtitle-heavy training data, whatever language it was set to: on Serbian speech set to Bosnian it still writes "Thank you." where Qwen3-ASR writes nothing. In a track that is not in English such a row is not speech and is dropped; English tracks keep theirs, since there it can be what someone said.

Where: `LokalBot/Models/Transcription/WhisperStockPhrases.swift` (`WhisperStockPhrases`).

### Implausibly fast rows are dropped only when precisely timed

The forced aligner packs words a model made up for a near-silent gap into a fraction of a second (8–12 words in under one), so a precisely timed row with at least `implausibleRateMinimumWords` words at that rate is not speech. Coarse or unknown timing never authorizes removal, and a collapsed filler loop is judged by the words it keeps.

Where: `LokalBot/Models/Transcription/TranscriptSanitizer.swift` (`TranscriptSanitizer.implausibleRateMinimumWords`).

### The sanitizer removes runaway repetition loops

llama.cpp decodes Qwen3-ASR greedily without speech-swift's repetition block: on the 0.6B benchmark one 8.3 s window looped "hey," until the token cap (Benchmarks/transcribe/QwenLlamaCpp/results/2026-11-16-0.6b). `TranscriptSanitizer` removes such loops.

Where: `LokalBot/Engines/QwenASREngine.swift` (`QwenASREngine.wordAttributionWindows`), `LokalBotTests/Models/Transcription/TranscriptSanitizerTests.swift` (`TranscriptSanitizer.sanitize`).

### Repeated digits are never collapsed

Extreme verbal emphasis is collapsed, but numeric runs are not: repeated digits can be an amount, an identifier or exact quoted evidence.

Where: `LokalBot/Models/Transcription/TranscriptSanitizer.swift` (`TranscriptSanitizer.collapseExtremeCharacterRuns`).

### Live chunking treats subsonic rumble as no speech

The live mic tee carried strong 10–50 Hz drift whose changing amplitude cleared the dynamics gate and made Granite emit fluent sentences in random languages. Such audio has no speech-band energy.

Where: `LokalBotTests/Services/Transcription/LiveTranscriptChunkerTests.swift` (`testAmplitudeModulatedSubsonicRumbleHasNoSpeech`).

## Transcription servers

### Audio goes only to an origin approved for transcription

A speech-to-text server the user configures speaks OpenAI's `/audio/transcriptions` API. Audio leaves the computer only for an origin approved for transcription: loopback needs no approval, plain HTTP is accepted only on the user's own network or tailnet, and redirects are not followed, so a clip cannot leave the approved origin. These approvals are separate from Think's: approving a Think server never sends it audio.

Where: `LinuxWindows/crates/lokalbot-core/src/remote_transcription.rs`, `LinuxWindows/crates/lokalbot-ai/src/remote_transcription.rs`.

### Consent is checked before every upload

An engine is built from a settings snapshot, and one meeting keeps it for hundreds of uploads, so each upload asks `RemoteTranscriptionConsent` what the person allows right now; revoking the server after the first upload keeps the rest of the audio on the Mac. `SettingsStore` is the one place consent enters the process, as with `ModelDownloadRouting.source`.

Where: `LokalBot/Engines/RemoteTranscriptionEngine.swift` (`RemoteTranscriptionConsent`), `LokalBotTests/Engines/RemoteTranscriptionEngineTests.swift` (`testUploadsStopOnceTheServerIsRevoked`).

### A withdrawn-server error outranks earlier track errors

When the microphone track failed with a server error and the server was then revoked during the system track, the first error used to win, and the meeting was marked failed instead of starting over.

Where: `LokalBotTests/Engines/WithdrawnTranscriptionServerTests.swift` (`ProcessingPipeline.trackFailure`).

### Speech detection and speaker separation stay local with a server

Even with a transcription server configured, speech detection and speaker separation run on this computer.

Where: `LinuxWindows/crates/lokalbot-app/src/pages/settings/model_setup.rs` (`ModelPatch.needs`).

### Speech is uploaded in windows of about 1 MB and attributed by words

Neighbouring speech is packed into windows (`lineWindows`, or `attributionWindows` before word attribution), each uploaded as a 16 kHz WAV of at most about 1 MB, so long meetings stay far below provider upload limits (25 MB) and per-request timeouts (60 s upstream at OpenRouter). Speaker turns are attributed word by word after transcription, as for Qwen3-ASR: cutting the audio at every turn sent each turn as its own request, one after another, without the context around it. Servers in `wordTimingModels` return the word times; for the rest, the local forced aligner finds them.

Where: `LokalBot/Engines/RemoteTranscriptionEngine.swift` (`RemoteTranscriptionEngine`).

### Word timings are requested only from models checked to return them

The models checked to return word times for `response_format=verbose_json` with `timestamp_granularities[]=word` are listed by origin; other servers get plain `json`, because several reject those fields (OpenAI's gpt-4o-transcribe models accept only `json` and `text`). On OpenRouter on 2026-10-19 the listed models placed every speaker turn within 0.25 s of its onset in 30 s windows, whichever provider served them. whisper-large-v3 is left out: one of its providers stretched a word across the pause before the next speaker.

Where: `LokalBot/Engines/RemoteTranscriptionEngine.swift` (`RemoteTranscriptionConfiguration.wordTimingModels`), `LinuxWindows/crates/lokalbot-core/src/remote_transcription.rs` (`WORD_TIMING_MODELS`).

### A server that rejects word-timing fields is asked again with plain `json`

Each upload is retried on rate limits, server errors and dropped connections. A server that answers the word-timing fields with HTTP 400 is asked again with plain `json`, and when that succeeds its origin and model are not asked for word times again until the app quits.

Where: `LokalBot/Engines/RemoteTranscriptionEngine.swift` (`RemoteTranscriptionEngine.upload`), `LinuxWindows/crates/lokalbot-ai/src/remote_transcription.rs` (`Client::upload`).

## Voice memory

### Naming a speaker teaches a voice profile that other meetings use

Naming a speaker teaches an encrypted voice profile, and later meetings offer or apply the name. A newly remembered voice can also name speakers in other recent meetings.

Where: `LinuxWindows/crates/lokalbot-core/src/voice/mod.rs`, `LinuxWindows/crates/lokalbot-app/src/pages/meetings/naming.rs` (`NamingSheet::save`).

### Voice files are sealed with a per-install key

`speaker-profiles/profiles.sealed` under the library root and `speaker-evidence/identity.sealed` in a meeting's folder hold the `Codable` JSON sealed with AES-256-GCM as `nonce ‖ ciphertext ‖ tag`, with the file's path under the root as associated data, on macOS and in the port alike. The key is per install and lives in the system credential store, so a Mac's files don't open in the port; that reads as an error, never as empty, so the files are not overwritten.

Where: `LinuxWindows/crates/lokalbot-core/src/voice/mod.rs`.

### Only vectors from the same voice model are compared

Every sample and profile names the voice model that made it. The port uses TitaNet where the Mac uses pyannote, and the two spaces are not comparable, so only vectors of `VOICE_MODEL` are ever scored or added to, whatever the other samples' length, and a model whose vectors aren't `VOICE_DIMENSION` long fails to load so it cannot write samples under `VOICE_MODEL`. On the Mac the sample fingerprint is a compatibility identifier, not the current library version: FluidAudio 0.17.5 keeps the pinned pyannote weights, preprocessing and 256-D space, and `NemotronRuntimeTests` verifies cross-version vectors on public AMI audio.

Where: `LinuxWindows/crates/lokalbot-core/src/voice/mod.rs`, `LinuxWindows/crates/lokalbot-core/src/voice/tests.rs` (`profiles_of_another_voice_model_are_never_compared_or_added_to`), `LinuxWindows/crates/lokalbot-speech/src/voice.rs` (`VoiceExtractor::load`), `LokalBot/Models/Speakers/SpeakerVoiceProfile.swift` (`SpeakerVoiceSample.fingerprint`).

### Diarizer slots map to voice samples by time, never by slot ID

Nemotron slots are anonymous, not identity embeddings, so the existing 256-D voice space is kept and `AttributedTrackTranscriber` maps samples by clean temporal coverage, never by a cross-model slot ID.

Where: `LokalBot/Services/Transcription/NeuralDiarizationEngine.swift` (`NeuralDiarizationEngine.diarizeDetailed`).

### Microphone samples count only when no call audio could have reached the microphone

A microphone is an audio source, not a person, as in the Mac's `SpeakerMicrophoneEvidence` and `AttributedTrackTranscriber`.

Where: `LinuxWindows/crates/lokalbot-core/src/voice/evidence.rs`.

### Imported audio is system audio, and its voices are never enrolled

An imported audio or video file becomes the meeting's system track, so it is diarized like call audio and, like any remote participant's, its voices are never enrolled or matched against voice profiles. The original file is only read and the meeting keeps its own AAC copy. A recording from a paired phone or tablet takes the same path but becomes the microphone track (`importDeviceRecording`).

Where: `LokalBot/Services/Meetings/MeetingImportService.swift` (`MeetingImportService`).

### Call voices are compared by each speaker's average

Call audio arrives codec-compressed, so a single 3–10 s chunk varies too much to compare on its own, and the old all-pairs chunk gate rejected every real call voice. A speaker's average over many turns is stable: on real Google Meet standups the same person scored 0.77–0.94 across meetings and different people at most 0.57.

Where: `LokalBot/Services/Speakers/SpeakerVoiceMatcher.swift` (`SpeakerVoiceMatcher.Call`), `LinuxWindows/crates/lokalbot-core/src/voice/matcher.rs` (`call`), `LokalBotTests/Models/Meetings/MeetingSpeakerIdentityTests.swift` (`SpeakerVoiceMatcherTests.testCallVoiceMatchesByItsAverageWhenSingleChunksDisagree`).

### The port shows strong voice matches for a person to apply

The port's match scores are the Mac's, measured there on pyannote vectors from real calls. On TitaNet, `voice_calibration` and `voice_meeting_check` (LibriSpeech dev-clean, 40 speakers, through Opus and varied channels) made no wrong automatic decision, but different people reached 0.72 through one narrow noisy channel, and no real call has been measured. A wrong name attributes words to the wrong person, so `NAME_SPEAKERS_AUTOMATICALLY` stays off until TitaNet is measured on real calls, and a person confirms each strong match with Apply Names.

Where: `LinuxWindows/crates/lokalbot-core/src/voice/matcher.rs`, `LinuxWindows/crates/lokalbot-engine/src/voice.rs` (`NAME_SPEAKERS_AUTOMATICALLY`).

### One serial store commits speaker decisions before they reach a transcript

Evidence, assignment journals and profile mutations go through one serial authority, and a durable decision is committed before its public transcript projection. Even a writer refreshed to the latest assignment revision cannot reintroduce deleted evidence from its original snapshot.

Where: `LinuxWindows/crates/lokalbot-core/src/voice/store.rs`, `LokalBotTests/Services/Speakers/MeetingSpeakerEvidenceStoreTests.swift` (`MeetingSpeakerEvidenceStore`).

### Voice-memory errors never fail transcription

A caller keeps its transcript and shows the service's notice.

Where: `LokalBot/Services/Speakers/MeetingSpeakerIdentityService.swift` (`MeetingSpeakerIdentityService.process`), `LinuxWindows/crates/lokalbot-core/src/voice/service.rs` (`VoiceMemory`).

### Deleting a meeting takes its voices, and its sources' voices, out of profiles

On the Mac every retained source's profile contributions are revoked, not just the generated parent's, and the parent is deleted last so a partial failure cannot restore the sources. In the port the delete goes ahead when remembered voices can't be opened (the credential store out of reach, say), because it is what the person asked for; the returned text says so rather than claiming it happened, and the upkeep pass removes the meeting's contributions the next time the voices can be opened.

Where: `LokalBot/AppState.swift` (`AppState.deleteMeetings`), `LinuxWindows/crates/lokalbot-engine/src/voice.rs` (`delete_meeting`), `LinuxWindows/crates/lokalbot-core/src/voice/service.rs` (`VoiceMemory.revoke_removed_meetings`).

### Voice samples expire with screen retention

A merge keeps its sources on disk and out of the library list, and their voice samples expire with the screen retention period all the same. Another computer's file can't be opened here and stays as it is during expiry, without holding back every meeting after it.

Where: `LokalBotTests/Services/Speakers/MeetingSpeakerIdentityServiceTests.swift` (`MeetingSpeakerIdentityService`), `LinuxWindows/crates/lokalbot-core/src/voice/store.rs` (`Store.expire`).

### Voice profiles have no one-click remove-all

Profiles are built from speakers confirmed across many meetings and cannot be brought back, so one click next to Done must not remove them all.

Where: `LokalBot/Views/Meetings/SpeakerIdentityViews.swift` (`SpeakerProfilesView.body`).

## Speaker names

### Speaker evidence stays out of the transcript and everything built on it

Voice evidence and the sealed speaker journal stay out of the transcript model and its search and export paths, the CLI and prompts; only names a person accepts reach them. Review lives inside the existing Name Speaker sheet, and in the port the journal, when this computer can open it, reaches only the speaker sheet and the recognized-voices line. Names recognized from earlier meetings start picked in the naming sheet and are applied only when the person saves.

Where: `LokalBot/Views/Meetings/SpeakerIdentityViews.swift` (`SpeakerIdentityReview`), `LinuxWindows/crates/lokalbot-app/src/pages/meetings/speaker_identity.rs`, `LinuxWindows/crates/lokalbot-app/src/pages/meetings/model.rs` (`MeetingDoc.identity`), `LinuxWindows/crates/lokalbot-core/src/voice/mod.rs`.

### Calendar attendance suggests names but never identifies a voice

The meeting's calendar guests and name hints are picker choices in Name Speaker, never a speaker attribution: even one invitee and one mixed remote track do not prove who spoke.

Where: `LokalBot/Services/Speakers/SpeakerAutoNamer.swift` (`SpeakerAutoNamer`), `LinuxWindows/crates/lokalbot-core/src/calendar/suggestion.rs`, `LinuxWindows/crates/lokalbot-app/src/pages/meetings/speaker_suggestions.rs`.

### A chosen calendar guest is kept by its opaque id, never its address

Choosing a guest saves its opaque identity with the name (`speakerCalendarIdentityIDs`), so same-named guests stay apart.

Where: `LinuxWindows/crates/lokalbot-app/src/pages/meetings/speaker_suggestions.rs`, `LinuxWindows/crates/lokalbot-app/src/pages/meetings/dialogs.rs` (`NameSpeakerSheet::save`).

### Names carry to a new transcription of the same audio by time, not by label

Diarization labels can change between runs, so names carry by retained turns in the same audio revision; in the port a speaker takes a name when at least 80% of its speech overlaps one named speaker on the same track and no other named speaker. A clean split can inherit; a merge of different people or any ambiguous overlap cannot. Ambiguous and unnamed speakers keep their defaults, so a name the user removed stays removed.

Where: `LokalBot/Services/Speakers/SpeakerIdentityResolver.swift` (`SpeakerIdentityResolver.remap`), `LinuxWindows/crates/lokalbot-core/src/voice/resolver.rs` (`remap`), `LinuxWindows/crates/lokalbot-core/src/model/transcript.rs` (`Transcript::carry_speaker_names_from`).

### A voice match never silently replaces a different name

Voice matches apply only to an unprotected assignment, and a match for a different name is withdrawn into review.

Where: `LinuxWindows/crates/lokalbot-core/src/voice/resolver.rs` (`apply`).

### The latest human decision is reapplied just before each transcript write

The final projection runs synchronously immediately before the write, so an automatic result that finishes after a human correction cannot overwrite it.

Where: `LokalBot/Services/Speakers/MeetingSpeakerIdentityService.swift` (`MeetingSpeakerIdentityService.applyingLatestDecision`), `LinuxWindows/crates/lokalbot-core/src/voice/service.rs` (`VoiceMemory.applying_latest_decision`).

### A correction first revokes the old confirmation

The old confirmation is revoked before the correction is recorded. A failure leaves a visible pending state instead of training on the wrong person.

Where: `LinuxWindows/crates/lokalbot-core/src/voice/service.rs` (`VoiceMemory.choose`).

### "My microphone is me" is one value for the whole process

As on macOS (`SpeakerAttribution.microphoneIsUser`), the meeting view, `transcript.md`, search and Ask all label microphone speech the same way.

Where: `LinuxWindows/crates/lokalbot-core/src/model/transcript.rs` (`MICROPHONE_IS_USER`).

### Friendlier speaker labels are display-only

Stored keys, aliases, owners, prompts and exports keep the canonical names ("Me", "Them 2"). "Local speaker" stays as it is, because that voice is not yet confirmed as the user.

Where: `LokalBot/Views/Meetings/MeetingSpeakerPresentation.swift` (`SpeakerDisplayName`).

## Consequences

- Many numbers here (Qwen window lengths, language shares, the 1 s word tolerance, echo gains, the cluster threshold, voice-match scores) come from named runs under `Benchmarks/transcribe/` or from real calls; changing one means measuring again, not tuning by feel.
- Text leaves a transcript only on strong timed or waveform evidence, or through the shared definitions for prompt echoes, stock phrases, loops and silence; anything uncertain is marked or withheld, never deleted.
- Voice evidence and profiles are private, sealed per install and tied to one voice model, and never reach the transcript, search, exports, the CLI or prompts; a human decision always outranks an automatic one, and voice-memory failures never fail transcription.
