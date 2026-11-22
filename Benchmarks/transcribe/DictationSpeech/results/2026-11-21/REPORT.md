# The speech step of a long dictation — 2026-11-21

## Outcome

On 32 recordings of 30 to 134 seconds (43.1 minutes of one speaker reading continuously), timing the exact call dictation
makes after the shortcut is released:

| Model, language setting | Word error rate | Median time | Paired time vs. the first row | × real time |
|---|---:|---:|---:|---:|
| Qwen3-ASR 1.7B, Automatic (the default) | 3.40% | 7.95 s | 1.00 | 10.7 |
| Qwen3-ASR 1.7B, English | 3.40% | 4.51 s | 0.57 | 18.8 |
| Parakeet Ultra 0.6B | 3.59% (+0.19, −0.50 to +0.85) | 0.69 s | 0.084 | 121.7 |
| Parakeet TDT 0.6B v3 | 3.95% (+0.55, −0.42 to +1.79) | 0.69 s | 0.085 | 111.3 |

- **On Automatic, Qwen3-ASR transcribes a dictation twice.** `QwenASREngine.decodeOnAuto` first decodes a language sample
  without a language; with up to 12 speech spans the sample is every span, and after the vote all spans are decoded again with
  the voted language. 18 of the 32 recordings were decoded fully twice, and the other 14 (more than 12 spans) decoded 12 extra.
  With English set, the text was identical in all 32 recordings and the time was 0.57 of Automatic's (0.51 to 0.62). The
  language-free pass is thrown away when the vote is English.
- **Parakeet was about twelve times faster than Qwen3-ASR on Automatic (seven times faster than with English set), with no
  accuracy difference this sample can detect** on read speech: the paired intervals include zero. Qwen3-ASR was ahead on
  `test-clean` (1.72% vs 2.40% for Ultra) and behind on `test-other` (5.15% vs 4.83%). The repository's earlier meeting
  benchmarks found Qwen3-ASR slightly ahead on meeting audio (CloudSTT AMI 17.6% vs Parakeet v3's 19.2%, overlapping
  intervals; WhistleComparison 7.65% vs Parakeet Ultra's 8.89%; both with Qwen3-ASR on MLX and earlier pins), so this is not a
  case for changing the default model, only for offering Parakeet for dictation.
- **Parakeet ignores the vocabulary hint** (`acceptsVocabularyPrompt`), so names a person has added don't help it; this run
  sent no vocabulary to any model.
- A repeat of the first row at the end gave identical text and a paired time of 1.00 (0.87 to 1.01).

## By length and subset

Median seconds per recording (word error rate):

| | 30 s (8) | 60 s (8) | 90 s (8) | 120 s (8) | test-clean (16) | test-other (16) |
|---|---:|---:|---:|---:|---:|---:|
| Qwen3-ASR, Automatic | 4.06 (3.56%) | 6.64 (4.46%) | 8.57 (3.71%) | 10.33 (2.79%) | 7.60 (1.72%) | 7.99 (5.15%) |
| Qwen3-ASR, English | 2.20 (3.56%) | 3.53 (4.46%) | 4.87 (3.71%) | 5.99 (2.79%) | 4.20 (1.72%) | 4.57 (5.15%) |
| Parakeet Ultra | 0.33 (2.56%) | 0.50 (3.18%) | 0.71 (4.57%) | 0.90 (3.44%) | 0.61 (2.40%) | 0.69 (4.83%) |
| Parakeet v3 | 0.33 (2.70%) | 0.50 (3.18%) | 0.71 (6.24%) | 0.90 (3.27%) | 0.60 (2.92%) | 0.69 (5.02%) |

## Eval design

- **Recordings:** `../../long-dictation-v1.json`, frozen at 2026-11-22T01:08Z before any model ran: LibriSpeech `test-clean`
  and `test-other`, per subset the first 16 chapters in speaker/chapter order that were long enough, targets cycling 30, 60,
  90 and 120 s, consecutive utterances from the chapter's start joined with 0.4 s of silence. 6,356 reference words.
- **Runner:** `LokalBot Dev --dictation-speech-replay` from a Debug build of this branch (commit in each `runs/*/manifest.json`),
  calling `DictationCoordinator.transcribe` with the model and language set, no vocabulary, in a disposable home with the
  already-downloaded models cloned in; Qwen3-ASR 1.7B Q8_0 GGUF on the bundled llama-server, Parakeet through FluidAudio
  0.18.3 (the app's pins). One warm-up transcription, then three passes over every recording, the middle pass reversed.
  Configurations ran one after another: Qwen3-ASR Automatic, Parakeet v3, Parakeet Ultra, Qwen3-ASR English, Qwen3-ASR
  Automatic again. Apple M4 Pro, 48 GB, macOS 26.7.3, nothing else running.
- **Scoring** (`../../score.py`): first pass for accuracy, after the Whisper English normalizer and the spelling map of
  `Benchmarks/think/ModelAlternatives/2026-09-07/`; time is each recording's median over the three passes, then the median over
  recordings; paired time is the median over recordings of the ratio to the first row; intervals are a paired 2,000-sample
  bootstrap over recordings. Aggregates in `summary.json`; outputs and the app's logs (which show spans and the double decode
  per recording) in `raw-runs.tar.gz`.

## Not covered

- **Read speech, not dictation:** no fillers, restarts or thinking pauses; spontaneous speech has more pauses, so more spans.
  Both models may have seen LibriSpeech's training set; these are its test sets.
- **The rest of release-to-text** (cleanup, paste) and the live preview are outside the timer.
- **Other languages:** with a non-English vote the second decode may matter more; not measured.
- **Whether the language-free pass could be kept:** its text isn't returned, so whether it matches the pinned pass when every
  span came back in the voted language wasn't measured.
