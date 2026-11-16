# Qwen3-ASR 1.7B: llama.cpp vs MLX, rerun after the dependency update (2026-11-14)

**Verdict.** The dependency update didn't change the result. llama.cpp v1.0.0 (build 12359) gives the same accuracy, speed and memory as v0.9.0 (build 12110). Over 277 job items, 273 transcripts came out byte-identical, and the other 4 changed by one word each. The MLX side moved to the speech-swift fork at `8e87821` (v0.0.29) and FluidAudio 0.18.3, and its transcripts were byte-identical to the earlier run. So every accuracy figure in the [first report](../2026-11-14/REPORT.md) still holds:

- **AMI, shipped layout:** 17.80% on MLX and 17.76% on llama.cpp.
- **Meetings:** the backends disagree on 1.69% of words, against 1.70% before.
- **Serbian:** `sr` plus vocabulary gives 13.4% on MLX and 12.4% on llama.cpp, and both recover 11 of 12 names.
- **Speed:** llama.cpp is 8–13% slower per condition, against 10–17% before. Its own speed is unchanged.
- **Memory:** llama-server still peaks at a 2.3 GB footprint.

The move to llama.cpp stands as recommended. The app's `/completion` prompt, `LLAMA_MEDIA_MARKER` and prefix stripping all work on v1.0.0. llama-server's own `/v1/audio/transcriptions` is still unusable as it stands, because v1.0.0 still returns `language Serbian<asr_text>` ahead of the text.

## Setup

This run used the same machine, data, job files, models and server flags as the first run. It was an Apple M4 Max with 48 GB on macOS 27.2.1, and the backends ran one after the other with a 60 s pause between them. The only changes were the dependencies:

| | 2026-11-14 (first run) | This run |
|---|---|---|
| llama-server | v0.9.0, build 12110 | v1.0.0, build 12359 (`Scripts/build/fetch-llama.sh` on PR 501 rebased on master) |
| speech-swift fork | `33f42bc` | `8e87821` (v0.0.29) |
| FluidAudio | 0.17.7 | 0.18.3 |
| mlx-swift | 0.32.3 | 0.32.3 |

- **Models:** `aufklarer/Qwen3-ASR-1.7B-MLX-8bit` (the app's copy), and `ggml-org/Qwen3-ASR-1.7B-GGUF` Q8_0 with its Q8_0 mmproj at revision `36a6786`.
- **Server flags:** `-ngl 99 -c 4096 --parallel 1 --cache-ram 256`, the app's flags.
- **Windows:** FluidAudio's Silero VAD produced identical decode windows under 0.18.3. Every window's start and end matched the first run in both arms, so the two runs compare the same audio.

## Accuracy

| | 2026-11-14 MLX → llama.cpp | This run MLX → llama.cpp |
|---|---|---|
| AMI WER, merge-60-off-v14 (shipped) | 17.80% → 17.76% (Δ −0.05, −0.40…+0.27) | 17.80% → 17.76% (Δ −0.05, −0.40…+0.27) |
| AMI WER, engine-15 | 18.21% → 18.78% | 18.21% → 18.78% |
| Meetings disagreement, merged / engine-15 | 1.70% / 2.11% | 1.69% / 2.11% |
| AMI disagreement, merged / engine-15 | 2.04% / 3.07% | 2.04% / 3.07% |
| FLEURS ≤60 s, true language (de / ja CER / ru / sr) | 4.5→3.9 / 7.1→6.5 / 10.2→10.0 / 14.9→13.2 | identical |
| FLEURS ≤14 s, auto (de / ja CER) | 4.5→4.9 / 7.8→8.5 | 4.5→4.7 / 7.8→8.5 |
| Serbian ≤60 s, `sr` + vocabulary | 13.4% → 12.4%, names 11 / 11 | identical |
| Serbian ≤60 s, auto: Croatian vote share | MLX 100%, llama.cpp 79% | identical |

The MLX transcripts are byte-identical to the first run's, so speech-swift 0.0.29 and FluidAudio 0.18.3 changed nothing that the Qwen3-ASR decode path or the VAD produces. On llama.cpp, 4 of 277 items changed by one substituted word each:

- Two merged-window meeting chunks.
- One German ≤14 s auto window: "höchste" became "höchster".
- One Japanese ≤14 s auto window: 示しました became 示唆しました.

These shift the German ≤14 s auto Δ from +0.3 to +0.2, and the meetings disagreement by 0.01 points. The first run's three v0.9.0 passes were byte-identical to one another, so these four words are a real, if negligible, numerical change between v0.9.0 and v1.0.0 kernels. No result's direction or significance changed. The note in the first report still applies: llama.cpp's Croatian vote of 79% falls just under the app's 80% pin threshold.

## Speed and memory

| | MLX 2026-11-14 → this run | llama.cpp 2026-11-14 → this run |
|---|---:|---:|
| English, merged ≤60 s (101 min) | 46.7× → 47.2× | 42.0× → 42.2× |
| English, ≤14 s | 46.9× → 44.3× | 39.2× → 39.3× |
| FLEURS, true language, merged / ≤14 s | 42.9× / 46.6× → 44.5× / 44.4× | 39.7× / 39.2× → 40.0× / 39.3× |
| FLEURS, vote and pin, merged / ≤14 s | 23.3× / 23.7× → 22.9× / 22.5× | 20.3× / 19.9× → 20.5× / 20.0× |
| Serbian + vocabulary, merged | 32.4× → 32.2× | 29.6× → 29.7× |
| Whole job wall time (11 conditions, 6.6 h of audio) | 608 s → 622 s | 701 s → 697 s |
| llama.cpp prefill / generation | — | 193.9 s / 457.8 s → 198.1 s / 458.0 s (346k / 86k tokens) |
| Server ready | — | 0.61 s → 3.92 s on the new binary's first launch; 0.42–0.47 s on two later launches |
| Peak memory | MLX peak 3.86 → 3.86 GB; footprint 8.5 → 7.6 GB; max RSS 2.9 → 3.0 GB | server footprint peak 2.31 → 2.35 GB; peak RSS 4.22 → 4.23 GB |

**llama.cpp v1.0.0** is as fast as v0.9.0, within 0.5% on every condition. Generation runs at the same ~189 tokens/s. Its memory is also unchanged. The 3.9 s first load was a one-time cost of the new binary. Two later launches of the same server were ready in under 0.5 s.

**MLX** is within ±5% of the first run, with no consistent direction. The merged English layout and the true-language FLEURS set got a little faster, and the ≤14 s conditions got a little slower. The first run had Spotlight indexing in the background, and each condition ran once, so this is run-to-run noise rather than a speech-swift 0.0.29 effect. The output was byte-identical. The MLX process footprint peak fell from 8.5 to 7.6 GB, and MLX's own peak allocation was the same 3.86 GB. The footprint is mostly MLX's untrimmed buffer cache, which varies with allocation timing, so this is not a dependency effect either.

The gap between the backends is therefore unchanged: llama.cpp takes 12% longer on the whole job (15% before), and it is 8–13% slower per condition (10–17% before). The narrower gap comes from MLX's noise, not from llama.cpp. It uses about a third of MLX's process footprint.

## Also checked

The opt-in end-to-end test `QwenLlamaASRTests/testCachedModelsTranscribeAWindowOnTheAppServer` passed on the app bundle's v1.0.0 server. It ran with the pinned GGUFs and the first 15 s of the FLEURS German track. Both the `de` window and the auto window returned the reference sentence, with no `language X<asr_text>` prefix.

## What was not run

The same gaps as the first run apply. No meeting reference was available, the app's prompt-echo filter was not applied, and only Q8_0 was tested, once, on this Mac.

`summary.json` holds the aggregates. Transcripts and audio stay in the private `SPAN_BENCH_OUT` folder. The first run's raw outputs are kept there under `prev-2026-11-14/`.
