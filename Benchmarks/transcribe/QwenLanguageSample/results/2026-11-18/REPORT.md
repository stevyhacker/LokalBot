# Qwen3-ASR language sampling — 18 November 2026

**Verdict.** Voting on a sample of 12 windows, and pinning on it only at 90% or more, cuts the second Qwen decode on auto-language tracks without changing a single transcript. Before and after picked the same language on all 42 track–layout pairs, and every transcript outside the speaker-region rows came out byte-identical. On long tracks, the whole AMI meetings and two of the owner's meetings, the engine decoded 54% of the windows it used to (60% of the audio). In paired runs, recognition took 226 s instead of 359 s for 182 minutes of audio, 1.59× faster. Serbian, Croatian, Bosnian and Montenegrin tracks with speaker separation gain the most. They pin Croatian, which the forced aligner cannot time, so they now stop after the sample, before the speaker-region pass the app runs on them anyway. The owner's Montenegrin meeting went from 49 and 44 window decodes per track to 12. Code-switched tracks decode exactly as before, at the same cost, and so do Japanese and Chinese tracks whenever their sample misses the rare window that votes.

## Setup

- **Code:** the app's own, through the opt-in unit test `QwenLanguageSampleReplayTests` (see the [README](../../README.md)). `before` replays the old auto path line for line. `after` is `QwenASREngine.decodeOnAuto` with `languageSampleSize = 12` and `sampleShare = 0.9`. Both use the same VAD windows, the same llama-server and `QwenASREngine.transcribeWindow`.
- **Model and server:** Qwen3-ASR 1.7B, `ggml-org/Qwen3-ASR-1.7B-GGUF` Q8_0 with its Q8_0 mmproj at revision `36a6786`, on the app's llama-server (v1.0.0, build 12359) with the app's flags, started by `QwenLlamaASR.accuracy.makeServer`.
- **Layouts:** `word` is the merged windows of up to 30 s that diarized meeting tracks use. `plain` is the VAD spans of up to 15 s that `transcribe` uses.
- **Data:** 17 FLEURS tracks of 40 utterances each (79 minutes in one language, 47 minutes code-switched), the whole AMI ES2004a and TS3003a meetings (42 minutes), and both tracks of two of the owner's meetings (98 minutes, word layout only): meeting A in English and meeting B in Montenegrin/Serbian. The code-switched tracks change language for their last 15%, 20% or 30%, alternate English and German every five utterances, or repeat four Serbian utterances and one English.
- **Machine:** Apple M4 Max with 48 GB on macOS 27.2.1. Other sessions were using the machine at the same time, including another llama-server, at load averages of 12–18 (see **Timing**).

## Accuracy and work

Decoding is greedy, so these figures do not depend on when a run happened. WER is pooled per set, with CER for Japanese and Chinese. Serbian Cyrillic is scored as Latin, as the app writes it. Non-Latin counts letters outside Latin script on tracks in Latin-script languages. Off-script counts letters outside Latin and the track's own scripts, such as Chinese characters on an English track. "Regions" rows, where the track settles on Croatian with word attribution, have no transcript here. The app decodes their speaker regions in Croatian after both paths, so only the decision and the work are compared.

| Set | Layout | Tracks | Audio | Same pin | Same text | WER/CER before → after | Non-Latin before → after | Off-script before → after | Windows decoded before → after | Audio decoded before → after |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| fleurs | word | 10 | 79 min | 10/10 | 10/10 | 6.7% → 6.7% | 0.0% → 0.0% | 0.0% → 0.0% | 334 → 260 (78%) | 112 → 92 min (83%) |
| switch | word | 7 | 47 min | 7/7 | 7/7 | 8.9% → 8.9% | 1.0% → 1.0% | 0.0% → 0.0% | 140 → 140 (100%) | 53 → 53 min (100%) |
| ami | word | 2 | 42 min | 2/2 | 2/2 | 15.9% → 15.9% | 0.0% → 0.0% | 0.0% → 0.0% | 192 → 120 (62%) | 67 → 45 min (66%) |
| meetings | word | 4 | 98 min | 4/4 | 4/4 | – | 0.0% → 0.0% | 0.0% → 0.0% | 289 → 146 (51%) | 79 → 44 min (56%) |
| all | word | 23 | 266 min | 23/23 | 23/23 | 10.1% → 10.1% | 0.3% → 0.3% | 0.0% → 0.0% | 955 → 666 (70%) | 311 → 234 min (75%) |
| fleurs | plain | 10 | 79 min | 10/10 | 10/10 | 12.4% → 12.4% | 0.1% → 0.1% | 0.0% → 0.0% | 835 → 612 (73%) | 108 → 83 min (77%) |
| switch | plain | 7 | 47 min | 7/7 | 7/7 | 13.1% → 13.1% | 3.6% → 3.6% | 0.0% → 0.0% | 407 → 407 (100%) | 48 → 48 min (100%) |
| ami | plain | 2 | 42 min | 2/2 | 2/2 | 16.8% → 16.8% | 0.0% → 0.0% | 0.0% → 0.0% | 634 → 341 (54%) | 58 → 34 min (58%) |
| all | plain | 19 | 169 min | 19/19 | 19/19 | 13.7% → 13.7% | 1.3% → 1.3% | 0.0% → 0.0% | 1876 → 1360 (72%) | 214 → 165 min (77%) |

- **No transcript changed.** Every pair picked the same language, and every transcript outside the region rows is byte-identical. WER, non-Latin and off-script letters are therefore equal by construction. The decision is the only thing that could differ.
- **Long tracks gain most.** The sample is a fixed 12 windows, so its cost shrinks with length. AMI decoded 62% of its windows in the word layout and 54% in the plain layout. The owner's English meeting decoded 62%, and the Montenegrin meeting 26%.
- **Code-switched tracks fall back, as designed.** No code-switched sample reached 90%, so these tracks decoded the rest on auto and voted on the whole track as before: the same decodes, the same pins and the same text. This includes the tracks that change language in their last 15–30%. Sampled windows are never decoded twice on the fallback path, so falling back costs nothing extra.
- **Japanese and Chinese rarely vote.** `TranscriptLanguageVote` counts only windows with at least 3 space-separated words, and Qwen writes these languages without spaces. On the old path, each Japanese track was pinned on the only one of its windows that voted (1 of 27 in the word layout, 1 of 44 in the plain one), and the Chinese plain track had no voting window, so it stayed on auto. A sample decides only when it happens to hold that window. In the word layout it did for both languages, and they decoded in one pass. In the plain layout the Japanese sample missed it, and the track fell back to the old path. The output was the same either way. This is a property of the vote, not of sampling (see **Follow-ups**).

Per track:

| Track | Layout | Windows | Before pin | After pin | Decodes before → after | WER/CER before → after |
|---|---|---:|---|---|---:|---:|
| ami-ES2004a | plain | 118 | en | en | 236 → 130 | 17.4% → 17.4% |
| ami-ES2004a | word | 37 | en | en | 74 → 49 | 16.9% → 16.9% |
| ami-TS3003a | plain | 199 | en | en | 398 → 211 | 16.2% → 16.2% |
| ami-TS3003a | word | 59 | en | en | 118 → 71 | 14.8% → 14.8% |
| fleurs-bs | plain | 46 | hr | hr | 92 → 58 | 34.9% → 34.9% |
| fleurs-bs | word | 20 | hr (regions) | hr (regions) | 20 → 12 | regions |
| fleurs-de | plain | 48 | de | de | 96 → 60 | 3.7% → 3.7% |
| fleurs-de | word | 20 | de | de | 40 → 32 | 3.0% → 3.0% |
| fleurs-en | plain | 39 | en | en | 78 → 51 | 8.5% → 8.5% |
| fleurs-en | word | 14 | en | en | 28 → 26 | 4.6% → 4.6% |
| fleurs-es | plain | 47 | es | es | 94 → 59 | 4.7% → 4.7% |
| fleurs-es | word | 20 | es | es | 40 → 32 | 4.3% → 4.3% |
| fleurs-fr | plain | 43 | fr | fr | 86 → 55 | 5.0% → 5.0% |
| fleurs-fr | word | 16 | fr | fr | 32 → 28 | 5.1% → 5.1% |
| fleurs-hr | plain | 43 | hr | hr | 86 → 86 | 24.8% → 24.8% |
| fleurs-hr | word | 17 | hr (regions) | hr (regions) | 17 → 12 | regions |
| fleurs-ja | plain | 44 | ja | ja | 88 → 88 | 13.3% → 13.3% |
| fleurs-ja | word | 27 | ja | ja | 54 → 39 | 11.8% → 11.8% |
| fleurs-ru | plain | 43 | ru | ru | 86 → 55 | 7.5% → 7.5% |
| fleurs-ru | word | 18 | ru | ru | 36 → 30 | 6.4% → 6.4% |
| fleurs-sr | plain | 41 | hr | hr | 82 → 53 | 21.6% → 21.6% |
| fleurs-sr | word | 17 | hr (regions) | hr (regions) | 17 → 12 | regions |
| fleurs-zh | plain | 47 | auto | auto | 47 → 47 | 6.2% → 6.2% |
| fleurs-zh | word | 25 | zh | zh | 50 → 37 | 5.3% → 5.3% |
| meeting A mic | word | 35 | en | en | 70 → 47 | – |
| meeting A system | word | 63 | en | en | 126 → 75 | – |
| meeting B mic | word | 49 | hr (regions) | hr (regions) | 49 → 12 | regions |
| meeting B system | word | 44 | hr (regions) | hr (regions) | 44 → 12 | regions |
| switch-en-de-alternating | plain | 47 | auto | auto | 47 → 47 | 8.7% → 8.7% |
| switch-en-de-alternating | word | 19 | auto | auto | 19 → 19 | 11.4% → 11.4% |
| switch-en-de-late15 | plain | 39 | en | en | 78 → 78 | 8.8% → 8.8% |
| switch-en-de-late15 | word | 15 | en | en | 30 → 30 | 4.7% → 4.7% |
| switch-en-de-late30 | plain | 40 | auto | auto | 40 → 40 | 7.2% → 7.2% |
| switch-en-de-late30 | word | 15 | auto | auto | 15 → 15 | 5.1% → 5.1% |
| switch-en-sr-late20 | plain | 39 | en | en | 78 → 78 | 10.7% → 10.7% |
| switch-en-sr-late20 | word | 14 | en | en | 28 → 28 | 6.9% → 6.9% |
| switch-sr-en-blocks | plain | 41 | auto | auto | 41 → 41 | 21.5% → 21.5% |
| switch-sr-en-blocks | word | 15 | hr (regions) | hr (regions) | 15 → 15 | regions |
| switch-sr-en-late15 | plain | 41 | hr | hr | 82 → 82 | 21.5% → 21.5% |
| switch-sr-en-late15 | word | 17 | hr (regions) | hr (regions) | 17 → 17 | regions |
| switch-sr-en-late30 | plain | 41 | auto | auto | 41 → 41 | 15.4% → 15.4% |
| switch-sr-en-late30 | word | 16 | auto | auto | 16 → 16 | 17.4% → 17.4% |

## Timing

Wall time is only compared within pairs. In the paired runs, both paths decoded each long track back to back, alternating which went first. The first after-batch had shown why: identical work, such as the Chinese plain track's 47 decodes both times, took 35% longer minutes later while another session's llama-server shared the GPU.

| Set | Layout | Tracks | Audio | Decode before → after | RTF before → after | Speed-up |
|---|---|---:|---:|---:|---:|---:|
| ami | word | 2 | 42 min | 106 s → 85 s | 23.8× → 29.7× | 1.25× |
| meetings | word | 4 | 98 min | 145 s → 77 s | 40.4× → 76.1× | 1.88× |
| all | word | 6 | 140 min | 251 s → 162 s | 33.4× → 51.7× | 1.55× |
| ami | plain | 2 | 42 min | 108 s → 63 s | 23.4× → 39.8× | 1.70× |
| all | plain | 2 | 42 min | 108 s → 63 s | 23.4× → 39.8× | 1.70× |

| Track | Layout | Windows | Pin | Decodes before → after | Decode before → after | RTF before → after |
|---|---|---:|---|---:|---:|---:|
| ami-ES2004a | plain | 118 | en | 236 → 130 | 49.1 s → 30.1 s | 21.4× → 34.9× |
| ami-ES2004a | word | 37 | en | 74 → 49 | 55.5 s → 53.1 s | 18.9× → 19.8× |
| ami-TS3003a | plain | 199 | en | 398 → 211 | 58.7 s → 33.4 s | 25.2× → 44.2× |
| ami-TS3003a | word | 59 | en | 118 → 71 | 50.6 s → 32.0 s | 29.2× → 46.1× |
| meeting A mic | word | 35 | en | 70 → 47 | 9.1 s → 8.4 s | 178.5× → 193.1× |
| meeting A system | word | 63 | en | 126 → 75 | 88.9 s → 52.3 s | 18.6× → 31.6× |
| meeting B mic | word | 49 | hr (regions) | 49 → 12 | 32.7 s → 9.2 s | 39.8× → 140.8× |
| meeting B system | word | 44 | hr (regions) | 44 → 12 | 14.7 s → 7.2 s | 88.5× → 179.9× |

Over the 182 minutes of long-track audio, recognition took 226 s instead of 359 s, 1.59× faster, for 60% of the decoded audio. Single pairs vary a lot under shared load. ES2004a in the word layout gained 4%, against 1.58× for TS3003a in the same layout. Meeting B's rows stop before the speaker-region pass, which follows on both paths and decodes the track about once more in Croatian. Its mic pair is not alternated: an outside SIGTERM stopped the first meetings batch after its `before` half, and the `after` half ran two minutes later.

## Choosing the sample

`simulate.py` replays any sample from the `before` runs, because each window's vote was recorded and a vote over windows is the sum of theirs (`simulation.json`).

| Sample | Share | One pass (word / plain) | Fallback (word / plain) | Wrong pin (word / plain) | Old path's time (word / plain) |
|---:|---:|---:|---:|---:|---:|
| 4 | 80% | 17 / 10 | 6 / 8 | 0 / **1** | 58% / 71% |
| 8 | 80% | 19 / 10 | 4 / 8 | 0 / **1** | 66% / 74% |
| 8 | 85% | 18 / 9 | 5 / 10 | 0 / 0 | 67% / 75% |
| 8 | 90% | 15 / 9 | 8 / 10 | 0 / 0 | 69% / 75% |
| 12 | 80% | 20 / 10 | 3 / 8 | 0 / **1** | 73% / 77% |
| 12 | 85% | 20 / 9 | 3 / 10 | 0 / 0 | 73% / 77% |
| **12** | **90%** | **16 / 9** | **7 / 10** | **0 / 0** | **74% / 77%** |
| 16 | 90% | 15 / 9 | 8 / 10 | 0 / 0 | 81% / 80% |

The time column is the estimate from recorded window times, over all 23 word-layout and 19 plain-layout tracks. Most FLEURS tracks have only 14–48 windows, so a sample of 12 is a large share of them. On the long tracks alone, a sample of 8 would take 55% of the old path's time and a sample of 12 would take 58%.

- **The share decides safety.** At 80%, every sample size in the table pinned the four-Serbian-to-one-English plain track. Its whole-track vote was 79.8% Croatian, so the old path left it on auto. Tracks in one language voted 99–100% on any sample, so a stricter share costs them nothing. It only sends tracks near the line back to the old path.
- **The deterministic sampler takes the longest window of each group.** Any window of a group could open that part of a meeting, so the risk was also estimated with one random window per group, 2000 times per track. On the 8 track–layouts the old path left on auto, the mean chance of a wrong pin was:

| Sample | 80% | 85% | 90% |
|---:|---:|---:|---:|
| 4 | 23.8% | 15.4% | 10.2% |
| 8 | 11.6% | 7.3% | 4.3% |
| 12 | 9.1% | 5.2% | **2.9%** |
| 16 | 11.2% | 6.2% | 3.4% |

At 12 and 90%, almost all of the remaining risk is the 79.8% track (23%). Tracks with 73% or less in one language never pinned. A wrong pin there would reverse a call the old path made by 0.2 points of share. On that kind of track, DualASR measured pinning to Croatian as better, not worse: 29.5% WER against 32.8% on auto (MLX, 60 s windows).

## What was not run

- **Qwen3-ASR 0.6B.** The compact tier uses the same code, with 15 s windows, but was not benchmarked.
- **The speaker-region pass** on tracks that settle on Croatian. It is the same after both paths. Its cost comes on top of the times above. So does the voice-activity sweep, also the same for both: 0.3–1 s per WAV track and 6–10 s per AAC meeting track.
- **References for the owner's meetings.** They were compared on decisions and output only, which were identical.
- **A quiet machine.** Other sessions shared the CPU and GPU, so absolute real-time factors depend on their load and on the tracks. Compare them only within a pair, not with the 20.5× and 40.0× that QwenLlamaCpp measured on FLEURS.

## Follow-ups

- **Japanese and Chinese rarely vote.** The vote's 3-word minimum counts spaces, so unspaced scripts almost never vote, and these tracks are pinned by chance. Counting characters for unspaced scripts would pin them reliably, and with sampling, in one pass. That changes the old path's decisions too, so it needs its own accuracy check.
