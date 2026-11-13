# Live transcript, turn by turn, on this Mac — 10 November 2026

**Result: fast live text does not need Meta's API.** Cutting each track at pauses and transcribing one turn at a time shows a turn's text a median **0.5 to 0.7 s** after the speaker's last word with Parakeet, Granite fast and Qwen3-ASR 1.7B, and **0.9 s at worst**. Muse Voice Transcribe measured 0.74 s (median) on other audio. Whisper large-v3 turbo takes 1.3 to 1.4 s, 1.7 s at worst. The preview's windows, on the same recordings, take 1.7 to 3.2 s and 3.8 to 5.0 s at worst, and make more word errors because they cut mid-sentence. The app now has this as **Turn-by-turn live text** (Settings → Meetings → Processing, off by default).

What it does not give is text while a long turn is still being spoken; the app covers that by transcribing the open turn again every two seconds when the model is fast enough. A streaming recognizer the app already links gives real word-by-word text in English (words 0.34 s behind the speaker, 4.7% word error) but reads Serbian badly (43.9% with a Croatian hint), so it is not proposed as the route for both languages.

[How it was measured](../../README.md). One Apple M4 Max, 48 GB, macOS 27.2, the app's test bundle built optimized with Xcode 27.2. Models as the app pins them: Parakeet TDT 0.6B v3 and Parakeet Ultra 0.6B (Core ML, FluidAudio 0.17.7), Qwen3-ASR 1.7B MLX 8-bit (`e5450a2`), Whisper large-v3 turbo (WhisperKit 1.1.1, `v20240930`), Granite Speech 5 fast (`18ca3c1`), Silero VAD (Core ML). Granite Speech 4.1, Parakeet v2 and Qwen3-ASR 0.6B were not installed complete on this Mac and did not run.

## A call as it is recorded: one track per side

The sample call split into a microphone track and a call track, 25 hand-overs per recording. "Turns" closes a turn after two quiet 256 ms chunks, or one once the turn is 4 s long, and decodes turns one at a time. Times are from the last word of a turn to its text.

| Model | Recording | Decoding a turn: median / longest | Turns: median / 9 in 10 / worst | Windows: median / 9 in 10 / worst | Word errors: turns / windows |
| --- | --- | --- | --- | --- | --- |
| Parakeet TDT 0.6B v3 | English | 0.04 / 0.06 s | **0.50** / 0.77 / 0.81 s | 1.86 / 3.36 / 3.83 s | 3.4% / 8.7% |
| Parakeet Ultra 0.6B | English | 0.04 / 0.06 s | **0.50** / 0.77 / 0.81 s | 2.23 / 3.66 / 4.26 s | 4.7% / 12.5% |
| Granite Speech 5 fast | English | 0.02 / 0.04 s | **0.48** / 0.75 / 0.79 s | 1.74 / 3.63 / 3.97 s | 11.2% / 13.9% |
| Qwen3-ASR 1.7B (the default) | English | 0.15 / 0.29 s | **0.64** / 0.83 / 0.86 s | 1.89 / 3.37 / 4.29 s | 2.9% / 8.5% |
| Whisper large-v3 turbo | English | 0.81 / 1.00 s | **1.32** / 1.49 / 1.52 s | 3.22 / 4.29 / 5.01 s | 5.8% / 7.6% |
| Qwen3-ASR 1.7B | Serbian | 0.17 / 0.57 s | **0.71** / 0.86 / 0.94 s | 2.23 / 3.73 / 4.15 s | 22.3% / 31.8% |
| Whisper large-v3 turbo | Serbian | 0.82 / 1.30 s | **1.37** / 1.58 / 1.71 s | 2.44 / 3.68 / 4.57 s | 15.6% / 24.2% |
| Parakeet Ultra 0.6B, Croatian hint | Serbian | 0.04 / 0.08 s | **0.57** / 0.70 / 0.72 s | 2.57 / 4.13 / 4.34 s | 25.8% / 32.4% |
| Parakeet TDT 0.6B v3, Croatian hint | Serbian | 0.05 / 0.08 s | **0.58** / 0.70 / 0.73 s | 2.07 / 3.48 / 4.30 s | 29.9% / 45.5% |

- **Where the time goes.** Speech detection judges 256 ms at a time, so two quiet chunks are known 0.5 to 0.8 s after the last word, depending on where in a chunk the speaker stopped. That is nearly all of the delay for the fast models; Whisper adds about 0.8 s of decoding, which hardly changes with the length of the turn.
- **Windows.** A window waits until 4 s of a track are recorded, so a turn's last words sit in an unfinished window for up to 4 s. The last few seconds of a recording never reach a window while it is being recorded: in most runs the last hand-over got no text at all, and it is left out of the window columns. Window edges depend on how long each decode took, so their error rates move between runs (Parakeet Ultra's English windows scored 7.2% in an earlier run and 12.5% here).
- **Cost.** Turns took no more processor time than windows: 0.4 against 0.6 CPU seconds per minute of audio for Parakeet, 1.1 to 1.7 against 1.3 to 1.9 for Qwen, 1.2 to 1.5 against 1.4 to 2.1 for Whisper. Speech detection takes 0.15 ms per chunk. GPU and Neural Engine work is not in these figures.
- **What turns lose.** A turn shows nothing until its pause, so a word waits longer on average: 3.3 to 4.6 s from being spoken to being shown, against 2.6 to 3.6 s in windows. This is why the app also shows the turn in progress (below).

Muse Voice Transcribe, for comparison, delivered a turn's text 0.74 s (median), 0.83 s (95th percentile) and 1.75 s (worst) after the turn ended, over 2,014 turns of AMI meetings and a home network connection ([report](../../../MuseVoiceTranscribe/results/2026-10-27/REPORT.md)). That is other audio, so the comparison is of size, not a ranking.

## Several voices on one track

The same recordings as one mixed track, which is what the call side looks like with two remote people. Pauses between speakers are 0.5 to 0.85 s here, about the length of the pause the cutter waits for.

| Rule for closing a turn | English: hand-overs caught, wait after the last word (median / worst) | Serbian | Pieces, and how many under 2 s (English / Serbian) |
| --- | --- | --- | --- |
| 1 quiet chunk | 25 of 25, 0.41 / 0.52 s | 25 of 25, 0.41 / 0.54 s | 61, 22 short / 51, 12 short |
| 2 quiet chunks | 18 of 25, 0.71 / 9.22 s | 15 of 25, 0.67 / 11.60 s | 25, 2 short / 29, 3 short |
| **2, or 1 once the turn is 4 s long (the app's)** | **23 of 25, 0.46 / 5.09 s** | **24 of 25, 0.50 / 5.97 s** | 38, 2 short / 41, 5 short |
| 2, or 1 once the turn is 3 s long | 23 of 25, 0.45 / 5.09 s | 25 of 25, 0.42 / 0.67 s | 38, 2 short / 43, 5 short |
| 3 quiet chunks | 6 of 25, 6.58 / 13.80 s | 5 of 25, 4.46 / 13.21 s | 15 / 18, none short |

- Two quiet chunks alone miss a third of the hand-overs on a shared track: the next speaker starts before the pause is long enough, and the text waits for a later pause or the 15-second limit. One quiet chunk catches all of them but cuts the call into twice as many pieces, a third of them under 2 s.
- Closing a turn at its first quiet chunk once it is 4 s long catches 23 and 24 of 25 with few short pieces, and word error rates stay where they were (Qwen English 3.3% against 3.4% and 2.5%; Serbian 22.3% against 24.6% and 22.7%; Parakeet v3 English 2.9% against 2.5% and 3.1%). With one track per side it catches all 25, as every rule does.
- With a model, the shared track gave text a median 0.51 s (Parakeet v3), 0.64 s (Qwen) and 1.32 s (Whisper) after an English hand-over, and 5 to 7 s at worst for the one or two that were missed.

## Through the app's own preview, in real time

The first 90 s of the English call written to disk at the speed it was recorded, with `LiveMeetingTranscriber` running turn by turn as it does in a meeting: 11 hand-overs, 17 lines.

| Model | Text after a hand-over's last word: median / worst | First text after a turn begins: median / worst | Times the turn in progress was shown |
| --- | --- | --- | --- |
| Parakeet TDT 0.6B v3 | 0.62 / 0.94 s | 2.15 / 7.07 s | 31 |
| Qwen3-ASR 1.7B | 0.70 / 0.96 s | 2.17 / 7.20 s | 31 |

This adds what the simulation leaves out: the preview looks for new audio every 100 ms, and a finished turn can wait behind the turn in progress being shown. The 7 s is the call's first turn: nothing is shown early until the model has answered once and proved quick.

## A streaming recognizer, for word-by-word text

FluidAudio 0.17.7, which the app already links, has `StreamingNemotronMultilingualAsrManager` for a Core ML conversion of NVIDIA Nemotron 3.5 ASR Streaming 0.6B. The app neither uses nor downloads it. Measured with the 560 ms variant (`multilingual/560ms` at `a70b9d1`, 664 MB), each turn as its own stream:

| Recording | A word is shown after it is spoken: median / 9 in 10 / worst | Text complete after a hand-over's last word: median / worst | Word errors | CPU seconds per minute of audio |
| --- | --- | --- | --- | --- |
| English (`en-US`) | 0.34 / 0.51 / 0.90 s | 0.48 / 0.79 s | 4.7% | 2.1 |
| Serbian with the Croatian hint (`hr-HR`) | 0.34 / 0.50 / 0.91 s | 0.54 / 0.69 s | 43.9% | 2.1 |

It lists Croatian among its 40 locales and not Serbian. On this recording it is about twice as wrong as Whisper, Qwen or Parakeet, so it would serve English meetings only.

## What each route would take

| Route | Languages | Text while a turn is spoken | What it takes |
| --- | --- | --- | --- |
| **Turns with the Transcribe model** (built, opt-in) | Whatever the chosen model reads | The open turn again every 2 s, when the model answers within 0.25 s and runs on this Mac | Nothing to download. Mac only so far: Windows and Linux need the cutter and a chunk-at-a-time speech detector in `lokalbot-speech`. |
| **Nemotron 3.5 streaming through FluidAudio** | 40 locales; good in English, poor in Serbian here | Yes, 0.34 s behind | A 664 MB download with its own model entry and pinned files, a streaming path in the preview, and the model running for the whole meeting (0.8 GB). The Core ML repository's licence tag is `other`; NVIDIA's model card names OpenMDW-1.1. Neither was reviewed. |
| **sherpa-onnx streaming recognizer** | The same Nemotron 3.5 model as ONNX (475 MB, int8), an English Nemotron (464 MB), English Zipformer (70 MB, upper case, no punctuation) | Yes | The runtime is already shipped: the Mac's `libsherpa-onnx-c-api.dylib` exports the online recognizer functions and the port's `sherpa-onnx` 1.13.8 crate has `OnlineRecognizer`. Neither is called today. The route for word-by-word text on Windows and Linux. Sizes are from the project's release listing; nothing was downloaded or measured here. |
| **Apple SpeechAnalyzer** | On this Mac, `SpeechTranscriber` offers 45 locales with no Serbian, Croatian or Bosnian; `DictationTranscriber` offers 54, with Croatian and no Serbian | Yes | macOS 26 or later, and the app supports macOS 15. Mac only. Not measured here. |
| **Muse Voice Transcribe** (today's fast live text) | Meta's list | Yes | Sends meeting audio to api.meta.ai, about $0.36 per meeting hour. |

## Serbian

- Whisper read the Serbian recording best (15.6% turn by turn), then Qwen (22.3%), then Parakeet with a Croatian hint (25.8% and 29.9%). Qwen wrote about half of it in Cyrillic under the app's `sr` hint; the errors are counted after transliteration.
- **Parakeet with the app's own Serbian setting is unusable**: 81 to 84% word errors, all in Cyrillic. FluidAudio treats `sr` as a Cyrillic-script language, and Parakeet's closest language, Croatian, is written in Latin. With `hr`, or with no hint, the same audio scores 24 to 30%. This is how the app behaves today after a meeting too, not something this change introduced, and it is not fixed here.
- All of this is one recording with multilingual synthetic voices. It ranks the models on that recording; it does not say how well they read a native speaker.

## Not measured

- A real meeting. One scripted call per language has no overlapping speech, no noise, none of the other side in the microphone track, and none of the hesitations that make people pause mid-sentence.
- Any Mac but an M4 Max. The delay grows by however much slower a Mac decodes a turn; the turn in progress stops being shown when a decode takes more than 0.25 s.
- The setting in the running app with a microphone. The real-time replay runs the preview's own code with real models, but it writes the two tracks itself.
- What showing the turn in progress costs in processor time and battery.
- GPU and Neural Engine use, and memory per model.
- The streaming recognizer's other variants (1,120 ms and longer chunks, which NVIDIA reports as more accurate), and the sherpa-onnx and Apple routes.

[Scores](scores.json), [pause rules compared with Parakeet v3 and Qwen](pause-rules.json).
