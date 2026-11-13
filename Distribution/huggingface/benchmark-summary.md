# LokalBot local-stack benchmarks — extracted numbers

Every number below is copied verbatim from a file in this repository; the **Source** column or line is the path to check. Nothing here is estimated or invented. All measurements to date were taken on a single machine: an **Apple M4 Max, 48 GB** of unified memory. These are engine-level benchmarks, not end-to-end UI timings. The repository index of every report is `Benchmarks/README.md`.

## Current default stack

The defaults on a fresh install total about **9.6 GB** of model files if every role is used (`README.md`, "Local AI, your choice").

| Role | Default model | Format | Model files | Headline result | Source |
| --- | --- | --- | ---: | --- | --- |
| Transcription | Qwen3-ASR 1.7B | MLX 8-bit | 2.47 GB | 17.6% WER on 27 minutes of AMI Mix-Headset audio; only Gemini 3.8 Flash scored lower (16.7%, within the error) | `README.md`, `Benchmarks/transcribe/CloudSTT/results/2026-09-30/REPORT.md` |
| Speaker diarization | Nemotron 3 (preview) via FluidAudio | Core ML | ~0.20 GB | 14.56% DER vs 43.44% for the previous default; 500× real time | `Benchmarks/transcribe/NemotronDiarization/results/2026-09-23/REPORT.md` |
| Summaries and chat | Qwen3.5 4B | `Q4_K_M` | 2.74 GB | 26-minute meeting summarized in 33.4 s warm / 59.8 s cold | `Benchmarks/think/SummaryEfficiency/results-2026-09-09.json` |
| Semantic search | EmbeddingGemma 2 | `Q8_0` | 0.31 GB | Correct passage first for 43/48 queries vs 40/48 for Harrier 0.6B | `Benchmarks/search/EmbeddingGemma2/2026-10-07/REPORT.md` |
| Autocomplete | Gemma 4 E2B Base | `Q6_K` | 3.85 GB | 0 unsafe results in 140 checks; 23.1% next-word accuracy vs 20.7% for LFM2.5 (tied in English); right when shown 50%; 56 / 102 ms median / p95 per keystroke | `Benchmarks/autocomplete/Cotyping/results/2026-10-15-engine-benchmark/REPORT.md` |
| Screen text (opt-in) | Apple Vision | Built into macOS | — | 0.971 token F1 at 119.6 ms per synthetic screenshot | `Benchmarks/search/OCR/SYNTHETIC-RESULTS-2026-06-24.md` |

Alternatives remain selectable in the app: Parakeet, Granite Speech, Whisper large-v3 turbo, SenseVoice, and GigaAM for transcription, Pyannote Community-1 for diarization, and LFM2.5 1.2B Instruct `Q4_K_M` (0.73 GB, the Lightweight preset) for autocomplete (`README.md`).

## Speaker diarization — Nemotron 3 vs Pyannote Community-1

Four independent English AMI test meetings, each evaluated as headset mix and distant-microphone audio: **8 conditions, 184.55 minutes of audio**, four speakers in every reference. DER adds missed speech, false alarms, and speaker confusion, divided by reference speaker time; overlap is scored and no speaker-count hints were used. Speed is the warm median over three runs on the 17.49-minute ES2004a headset recording. Source: `Benchmarks/transcribe/NemotronDiarization/results/2026-09-23/REPORT.md` (scores in `Benchmarks/transcribe/NemotronDiarization/results/2026-09-23/scores.json`).

| System | DER, zero collar | DER, 250 ms collar | Correct speaker count | Audio / processing time | Peak process RSS |
| --- | ---: | ---: | ---: | ---: | ---: |
| Pyannote Community-1 via FluidAudio (previous LokalBot default) | 43.44% | 30.45% | 5/8 | 243× | 0.68 GiB |
| FluidAudio community defaults + overlap | 43.61% | 30.44% | 5/8 | — | 0.66 GiB |
| **Nemotron 3 offline, full-precision Core ML (current default)** | **14.56%** | **8.34%** | **8/8** | **500×** | 0.67 GiB |
| Nemotron 3 fast128 | 14.51% | 8.19% | 8/8 | 365× | 0.64 GiB |
| Nemotron 3 c128 W8A8 (CPU/ANE) | 15.73% | 9.34% | 7/8 | 480× | 0.63 GiB |

The offline model reduced speaker confusion from **8.87% to 1.77%**, missed speech from **15.34% to 8.40%**, and false alarms from **19.23% to 4.38%** (percentage points of reference speaker time), and beat the baseline on all eight conditions. The report's caveat applies: this is a comparison against the pinned FluidAudio implementation and its configurations, not a claim about every implementation of Pyannote Community-1. It does not cover more than four speakers, other languages, or end-to-end name attribution.

## Summaries and action items — Qwen3.5 4B

Replay of LokalBot's production summary and action extractor with `Qwen3.5-4B-Q4_K_M.gguf` on llama.cpp **b10173**. Cold includes runtime startup; warm reuses the loaded runtime. ASR time is excluded. Source: `Benchmarks/think/SummaryEfficiency/results-2026-09-09.json`.

| Meeting | Transcript | Cold | Warm | Outcome |
| --- | ---: | ---: | ---: | --- |
| 26-minute meeting | 4,477 words | 59.8 s | 33.4 s | Complete |
| 91-minute meeting | 11,229 words | 71.5 s | 74.2 s | Complete |

Decode speed across these runs was about 85 tokens/s (`Benchmarks/README.md`). These are timings, not a summary-quality score.

In the 2026-09-07 pilot, MiniCPM5-2B `Q4_K_M` was smaller (1.561 GB vs 2.741 GB) and faster on long context (18.68 s vs 32.41 s), but it looped on one summary and misattributed action items, so Qwen3.5 4B remains the default (`Benchmarks/think/ModelAlternatives/2026-09-07/REPORT.md`).

## Semantic search — EmbeddingGemma 2 vs Harrier

48 authored queries (24 English, 24 Serbian/Montenegrin in Latin and Cyrillic) against a 60-passage synthetic corpus; relevant passage IDs fixed before inference. Both models used Q8 weights on the same llama.cpp build, each with its own prompts: Harrier returns 1,024 dimensions, EmbeddingGemma 2 returns 768. Source: `Benchmarks/search/EmbeddingGemma2/2026-10-07/REPORT.md`.

| Measure | Harrier 0.6B Q8 (previous default) | EmbeddingGemma 2 Q8 (current default) |
| --- | ---: | ---: |
| Correct passage ranked first | 40/48 (83.3%) | **43/48 (89.6%)** |
| Correct passage in top five | 47/48 (97.9%) | **48/48 (100%)** |
| English top one | 22/24 | **23/24** |
| Serbian/Montenegrin top one | 18/24 | **20/24** |
| Mean reciprocal rank | 0.903 | **0.944** |
| Repeated query latency, median | 13.1 ms | **9.0 ms** |
| Model file | 0.64 GB | **0.31 GB** |

The 6-point gain is within noise on 48 correlated queries (95% interval −4 to +17 points); EmbeddingGemma 2 was adopted because it matched or beat Harrier at half the size, half the idle memory, and faster queries. Harrier had replaced Qwen3 Embedding 0.6B (35/48) in September (`Benchmarks/think/ModelAlternatives/2026-09-07/REPORT.md`).

## Transcription — Qwen3-ASR 1.7B

**Public AMI meetings, against closed APIs and Parakeet.** 16 windows of 90–120 seconds from the Mix-Headset recordings of four AMI test meetings: 27.4 minutes and 4,160 reference words. Every system received the same 16 kHz mono WAV chunks with an English language hint and no custom vocabulary; the local models ran serially on MLX 0.32.3 and mlx-audio 0.5.7. Most windows contain heavy overlapped talk on one mixed channel, so deletions dominate every system's errors and absolute WER is higher than on published close-talk AMI results. Low-overlap WER covers the 4 windows where under 30% of reference words overlap another utterance (728 words); it is too small to rank systems on. Speed is audio seconds per second of request latency; API latency includes upload, with four requests in flight. Source: `Benchmarks/transcribe/CloudSTT/results/2026-09-30/REPORT.md` (aggregates in `Benchmarks/transcribe/CloudSTT/results/2026-09-30/summary.json`).

| System | WER | 95% CI | Low-overlap WER | Speed |
| --- | ---: | ---: | ---: | ---: |
| Gemini 3.8 Flash, prompted | 16.7% | 14.0–19.0% | 6.2% | 18× |
| **Qwen3-ASR 1.7B, local (current default)** | **17.6%** | 14.6–20.5% | 7.1% | 44× |
| Qwen3-ASR Flash | 18.1% | 14.6–20.8% | 6.3% | 25× |
| Qwen-Audio 3.1 ASR Flash | 18.5% | 14.6–21.8% | 5.6% | 10× |
| Parakeet TDT 0.6B v3, local | 19.2% | 15.8–22.3% | 8.1% | 129× |
| GPT-4o mini Transcribe | 21.8% | 17.5–25.7% | 7.8% | 34× |
| GPT Transcribe | 22.2% | 17.6–27.5% | 6.9% | 30× |
| GPT-4o Transcribe | 23.0% | 18.4–27.0% | 6.2% | 25× |

Gemini 3.8 Flash had lower WER than the local Qwen model in 93% of paired chunk-bootstrap samples, but on the owner's meetings it invented speech: 115 words in 15 invented spans. On those three meetings (69.9 minutes, no human reference), the local Qwen3-ASR 1.7B had the lowest disagreement with a consensus of the other vendor families, **4.2%** (95% CI 3.4–5.1%). That measures agreement, not accuracy.

**Speakers assigned after transcription.** The same AMI windows and owner meetings, run headless on the app's runtime and weights (speech-swift 0.0.26, FluidAudio 0.17.1, `aufklarer/Qwen3-ASR-1.7B-MLX-8bit`) with Nemotron 3 diarization. On identical chunks, that runtime scored 17.47% AMI WER against mlx-audio's 17.64%. The previous behaviour cut each track at every speaker turn before transcription; the current one transcribes the track in merged windows of up to 60 s, then gives each forced-aligned word the speaker active at its midpoint. cpWER (concatenated minimum-permutation WER) counts attribution errors as well as recognition errors. Source: `Benchmarks/transcribe/QwenSpanLength/results/2026-09-30/REPORT.md`.

| Measure | Speaker regions first (previous) | Transcribe, then attribute (current) |
| --- | ---: | ---: |
| AMI WER | 26.49% | **17.69%** |
| AMI cpWER | 36.52% | **33.90%** |
| Owner's meetings, disagreement with consensus | 8.30% | **4.41%** |
| Turns accepted for speaker memory, AMI / meetings | 286 of 417 / 1,319 of 1,501 | **364 of 417 / 1,405 of 1,501** |

The shipped path decoded at **48×** real time, ASR only; the forced aligner timed all 101 minutes of chunks in 34 s, 179× real time. Built into the app (Debug configuration), the change took the three meetings from 7.89% to 4.59% disagreement; that run's timings, 90 s for the 16-minute meeting and 329 s for the 57-minute one including diarization and alignment, are not production timings. AMI covers only 27 minutes, so its intervals are about ±1 point. On 5–7 minute FLEURS read-speech tracks, Qwen3-ASR 1.7B scored 4.4% WER in German, 7.1% CER in Japanese, and 10.2% WER in Russian (same file).

**Serbian, Croatian, and Bosnian.** FLEURS read speech with a human reference (531, 616, and 628 words), plus the owner's 10-minute Montenegrin/Serbian call, scored against Gemini 3.8 Flash as a rough reference. Scoring transliterates Serbian Cyrillic to Latin. Both engines decoded the app's Qwen word-attribution windows, serially on the M4 Max. Source: `Benchmarks/transcribe/DualASR/results/2026-10-07/REPORT.md`.

| WER | Serbian | Croatian | Bosnian | Owner's meeting |
| --- | ---: | ---: | ---: | ---: |
| Qwen3-ASR 1.7B, language on auto (default) | 17.3% | 26.8% | 36.8% | 38.3% |
| Whisper large-v3 turbo, `bs` | **13.0%** | **13.0%** | **22.3%** | **26.9%** |

Routing those tracks to Whisper was not adopted: the owner judged the gain not worth a 1.6 GB Whisper download, about 7 extra minutes per meeting hour (17× real time against Qwen's 33–42×), and new speaker-attribution work on Whisper text. Whisper is wrong for English-led audio: on the English-led code-switched track it scored 46.9–78.8%, against 12.4% for Qwen on auto.

## Speech recognition — Granite Speech 4.1 vs Granite Speech 5

44 public clips / 271.3 seconds (24 conversational AMI clips, 20 clean LibriSpeech clips), scored with the standard Whisper English normalizer. Source: `Benchmarks/think/ModelAlternatives/2026-09-07/REPORT.md`. **Qwen3-ASR 1.7B, the current default, was not part of this run**; its results are in the section above.

| Measure | Granite 4.1 Q4 | Granite 4.1 Q8 | Granite 5 TurboCTC BF16 |
| --- | ---: | ---: | ---: |
| Normalized word-error rate | 4.42% (35/791) | 4.93% (39/791) | 5.18% (41/791) |
| AMI normalized WER | 8.83% | 9.09% | 10.13% |
| LibriSpeech normalized WER | 0.25% | 0.99% | 0.49% |
| Audio seconds processed per second | 33.2× | 29.3× | **280.2×** |
| Median clip latency | 161 ms | 187 ms | **17.5 ms** |
| Sampled peak process RSS | 2.87 GiB | 3.62 GiB | 1.05 GiB |

Granite 5 is English-only, emits unpunctuated lowercase text, and is not integrated into LokalBot. This small set does not establish a reliable accuracy ordering.

## Cotyping (inline autocomplete) — engine benchmark, 2026-10-15

Harness: `Benchmarks/autocomplete/Cotyping/engine_benchmark.py` runs LokalBot's production autocomplete engine on one model through `--cotyping-bench --model-path`. It runs before app startup on the runtime the app builds, with fresh-install settings (4 words) and nothing else from the app, and times model loading on its own. It has three parts:

- **Safety checks:** the same 28 scenarios as the earlier check, run 5 times (one first pass, then 4 warm passes). Each result is shown, allowed silence, withheld, a wrong word, unsafe, or an error; only unsafe results and errors fail.
- **Next-word accuracy:** every word boundary of 96 original synthetic phrases, 788 positions in English, Serbian (Latin and Cyrillic), German, French, and Spanish. The first suggested word must equal the next word, ignoring case and apostrophe style.
- **Typing latency:** per-keystroke time while typing 8 of those phrases one character at a time.

Release build of commit `15d7a26` (from `master` at `9bff2ca`). Source: `Benchmarks/autocomplete/Cotyping/results/2026-10-15-engine-benchmark/REPORT.md` (per-model figures in `Benchmarks/autocomplete/Cotyping/results/2026-10-15-engine-benchmark/gemma4-e2b-base-q6/summary.json` and `Benchmarks/autocomplete/Cotyping/results/2026-10-15-engine-benchmark/lfm2.5-1.2b-instruct/summary.json`).

| Measure | Gemma 4 E2B Base `Q6_K` (current default) | LFM2.5 1.2B Instruct `Q4_K_M` (Lightweight preset) |
| --- | ---: | ---: |
| Unsafe results, 28 checks × 5 passes | **0** | **0** |
| Checks: shown / withheld / allowed silence | 24 / 3 / 1 | 24 / 3 / 1 |
| Word completions | 12/13 | 12/13 |
| Next-word accuracy, 788 word positions | **23.1%** | 20.7% |
| — English, 624 positions | 25.3% | 24.2% |
| — Other languages, 164 positions | 14.6% | 7.3% |
| Suggestion shown (coverage) | 46.1% | 48.1% |
| Right when shown (precision) | **50.1%** | 43.0% |
| Per keystroke while typing, median / p95 | 56 / 102 ms | **26 / 76 ms** |
| Checks, warm median / p95 | 60 / 103 ms | **18 / 29 ms** |
| Model load | 0.65 s | 0.16 s |

Gemma minus LFM2.5 accuracy, with phrase-level paired bootstrap intervals (10,000 resamples): **+2.4 points** over all 96 phrases (95% interval −0.1 to +5.0); **+1.1 points** in English, 72 phrases (−1.4 to +3.5), a statistical tie; **+7.3 points** in other languages, 24 phrases (0.0 to +15.1). The lead comes from Serbian, where LFM2.5 shows almost nothing (2% coverage, 0% accuracy) and Gemma reaches 8–9%. Those groups are small, so read the intervals, not the points.

- Accuracy counts a missing suggestion as a miss. When unsure of the first word, LokalBot shows nothing rather than guessing, so "right when shown" is closer to what you see while typing.
- **Withheld (both models, the same 3):** `notes-list`, `comma-clause`, and `sentence-start`, open-ended continuations where the first-word confidence gate (`ef8eeef`) holds back an unsure guess. **Allowed silence (both):** `mid-word`, inside "rec|eive", where the engine declines to insert. Every one of the 5 passes showed identical suggestions for both models.
- These are engine timings only. Input monitoring, debounce, accessibility reads, screen and memory context, learning, and drawing the suggestion are not included. Accuracy uses typed text plus app and window title only, while the app also reads nearby screen text, so real suggestions have more context.
- The phrases were written for earlier LokalBot studies. The 64-phrase hybrid-confirmation set confirmed the hybrid decoder before it shipped, so it is not held out from product decisions.

Gemma 4 E2B Base became the default after the 2026-10-02 replay on Cotabby's held-out corpus: **34.50% vs 30.43%** exact next-word accuracy for LFM2.5 (2,300 vs 2,029 of 6,667 word checkpoints). That run used a different corpus, the decoder from before the hybrid, and no confidence gate, so it is not comparable with the numbers above. Source: `Benchmarks/autocomplete/Cotyping/results/2026-10-02-quality/REPORT.md`.

## Cotyping (inline autocomplete) — earlier check, superseded scoring

The July 21 and October 14 runs used the original 28-scenario pass/fail check. That check counted a held-back suggestion as a safety failure, accepted only one word tail per fragment, and reported a fresh app process's 10–40 s first request as latency (`Benchmarks/autocomplete/Cotyping/results/2026-10-15-engine-benchmark/REPORT.md`, "What changed from the old check"). Its results do not describe today's engine and are kept in the repository: `Benchmarks/autocomplete/Cotyping/results/2026-07-21-model-debounce-benchmark.md` and `Benchmarks/autocomplete/Cotyping/results/2026-10-14-engine-bench/REPORT.md`.

The July 21 matrix is reproduced below as a historical snapshot only. It used a **Debug** build of code that predates the confidence gate, the October quality and prompt changes, and the hybrid decoder; LFM2.5 was the autocomplete default at the time. Gate = 28/28 safety, ≥12/13 word completions, p95 ≤ 2000 ms. Source: `Benchmarks/autocomplete/Cotyping/results/2026-07-21-model-debounce-benchmark.md`.

| Model | Exact file | Bytes | Safety | Word completions | Avg latency | p95 latency | Gate |
| --- | --- | ---: | --- | --- | --- | --- | --- |
| LFM2.5 1.2B Instruct | `LFM2.5-1.2B-Instruct-Q4_K_M.gguf` | 730,895,584 | 28/28 | 12/13 | 143 / 143 / 151 ms (3 warmed runs) | 484 / 487 / 494 ms | Pass ×3 |
| Gemma 4 E4B Instruct | `gemma-4-E4B-it-UD-Q5_K_XL.gguf` | 6,656,152,736 | 28/28 | 12/13 | 399 ms | 1,830 ms | Pass |
| Qwen3.5 2B | `Qwen3.5-2B-Q4_K_M.gguf` | 1,280,835,840 | 27/28 | 11/13 | 437 ms | 1,629 ms | Fail quality |
| Qwen3.5 4B | `Qwen3.5-4B-Q4_K_M.gguf` | 2,740,937,888 | 27/28 | 11/13 | 434 ms | 1,652 ms | Fail quality |
| Gemma 4 E2B (base) | `gemma-4-E2B.i1-Q6_K.gguf` | 3,845,328,608 | 26/28 | 10/13 | 883 ms | 2,560 ms | Fail quality + latency |
| Gemma 4 E4B (base) | `gemma-4-E4B-UD-Q5_K_XL.gguf` | 6,700,259,616 | 26/28 | 10/13 | 697 ms | 3,022 ms | Fail quality + latency |

Supporting figures from the July and earlier sources:

- LFM2.5 keyword relevance: **15/64 hits vs 13/64** for the Gemma instruct baseline — "a weak relevance signal, not a separate gate" (`Benchmarks/autocomplete/Cotyping/results/2026-07-21-model-debounce-benchmark.md`).
- Cold Metal-kernel compilation, first scenario only: LFM2.5 **19,349 ms**, Gemma E4B instruct **127,466 ms** (same file).
- Debounce replay on LFM warmed runs: in-process debounce **35 / 55 ms** avg/p95; inferred end-to-end **178–186 / 509–519 ms** avg/p95 (same file; arithmetic replay, not a typing trace).
- Earlier engine bench (2026-07-06): Gemma E4B instruct avg **459 ms**, p95 **1798 ms**, steady-state **~200 ms**; the base variant measured avg **564 ms**, p95 **2393 ms** (`Benchmarks/autocomplete/Cotyping/results/2026-07-06-cotypist-parity.md`; raw JSON siblings `2026-07-06-engine-bench.json`, `2026-07-06-engine-bench-base-model.json`). A later side-by-side run logged avg **471 ms** / p95 **1798 ms** (`Benchmarks/autocomplete/Cotyping/results/20260706-165057-cotypist-vs-lokalbot.md`; its GUI capture leg recorded no insertions and is not usable as data).

## Screenshot OCR — real stored screenshots

Input: 15 real LokalBot screenshots exported from the encrypted local store; Apple Vision baseline min 140.8 ms / max 404.8 ms. Hardware: M4 Max. Source: `Benchmarks/search/OCR/RESULTS-2026-06-24.md`. "Overlap" = token overlap vs Apple Vision output.

| Engine | Images | Mean latency | Token overlap vs Vision | Verdict in source |
| --- | ---: | ---: | ---: | --- |
| Apple Vision `VNRecognizeTextRequest` | 15 | 243.2 ms | — | Current LokalBot baseline |
| PP-OCRv5 mobile det+rec | 5 | 18.46 s | 0.187 | Too slow |
| PP-OCRv5 server det+rec | 5 | 15.32 s | 0.147 | Too slow |
| PP-OCRv6 medium det+rec | 5 | 22.43 s | 0.208 | Too slow |
| TrOCR small printed | 3 | 2.47 s | 0.001 | Line-level; not a screenshot replacement |
| GOT-OCR 2.0 (HF, MPS, 256-token cap) | 3 | 3.70 s | 0.000 | Poor screenshot output |
| GLM-OCR (MPS, 256-token cap) | 3 | 5.74 s | 0.127 | Too slow/partial |
| PaddleOCR-VL 1.6 GGUF (256-token cap) | 3 | 1.30 s | 0.027 | Fast but heavily truncated |
| PaddleOCR-VL 1.6 GGUF (1024-token cap) | 3 | 2.74 s | 0.104 | Best non-Vision runtime, still slower and partial |
| DeepSeek-OCR GGUF (512-token cap) | 3 | 1.64 s | 0.000 | Hallucinated unrelated content |

## Screenshot OCR — synthetic set with ground truth

Input: 5 generated screenshots with ground-truth text (`Benchmarks/search/OCR/synthetic/manifest.tsv`). Metric: normalized multiset token scores; char similarity is reading-order sensitive. Hardware: M4 Max. Source: `Benchmarks/search/OCR/SYNTHETIC-RESULTS-2026-06-24.md`.

| Engine | Mean latency | Token precision | Token recall | Token F1 | Char similarity |
| --- | ---: | ---: | ---: | ---: | ---: |
| Apple Vision | 119.6 ms | 0.971 | 0.971 | 0.971 | 0.812 |
| PP-OCRv6 medium | 6.78 s | 0.960 | 0.990 | 0.974 | 0.867 |
| PaddleOCR-VL GGUF | 1.70 s | 0.871 | 0.813 | 0.777 | 0.731 |
| DeepSeek-OCR GGUF | 1.44 s | 0.844 | 0.732 | 0.741 | 0.680 |

Notes from the same file: PP-OCRv6 was the only open-source option slightly above Apple Vision on quality but **~57× slower** with a **~15 s model load**; a DeepSeek-OCR rerun with the upstream-style `Free OCR.` prompt fell to mean token F1 **0.529**. Decision in both OCR files: keep Apple Vision as the default screenshot OCR pipeline.

## Honest gaps — what is NOT yet measured

| Gap | One-line plan |
| --- | --- |
| Single-chip coverage: every number above is one M4 Max (48 GB); no 16 GB, M1, M2, or M3 results | Re-run the summary replay, `--cotyping-bench`, and the OCR harness on M1, M2, and M3 machines before claiming per-chip guidance. |
| Qwen3-ASR 1.7B's English accuracy comes from 27 minutes of overlapped AMI audio and three owner meetings scored for agreement, not accuracy; no clean read speech | Run it through the 44-clip set from `Benchmarks/think/ModelAlternatives/2026-09-07/REPORT.md` alongside Parakeet and Whisper large-v3 turbo. |
| Qwen3-ASR 1.7B speeds (44× and 48× real time) are ASR only, from headless harnesses; the only end-to-end meeting timings, with diarization and alignment, came from a Debug build | Time `LokalBot --process` on a Release build over the same meetings, reporting transcription, diarization, and alignment separately. |
| Diarization tested only on four-speaker English AMI meetings | Add five-to-eight-speaker and non-English recordings, plus LokalBot's own mic/system-track captures. |
| Search pilot is 48 authored queries | Validate EmbeddingGemma 2 with human-annotated queries over a larger real library. |
| No summarization-quality evaluation for Qwen3.5 4B | Human-rate recaps on a fixed meeting corpus (faithfulness, action-item completeness); publish rubric + raw ratings. |
| OCR sets are small (15 real + 5 synthetic screenshots) | Grow the synthetic manifest to ≥50 fixtures across app categories and re-run `score_text_outputs.py`. |
| Autocomplete numbers are engine-only, on 96 synthetic phrases (some of which confirmed the hybrid decoder), without the screen context the app reads, and say nothing about real acceptance | Measure suggestion latency and acceptance end to end while typing in real apps, on text that was not used for product decisions. |
