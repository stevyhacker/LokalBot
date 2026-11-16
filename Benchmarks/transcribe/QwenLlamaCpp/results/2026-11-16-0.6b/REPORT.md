# Qwen3-ASR 0.6B: llama.cpp vs MLX (2026-11-16)

**Verdict.** Qwen3-ASR 0.6B is more accurate on llama.cpp than on MLX. On identical windows with identical prompts, ggml-org's Q8_0 GGUF beat the app's MLX 4-bit weights everywhere:

- **AMI, shipped 0.6B layout:** 19.47% WER against 20.90% (Δ −1.43, 95% CI −2.20…−0.55).
- **AMI speaker attribution:** cpWER 35.06% against 35.80% (Δ −0.74, −1.33…−0.15), with the CoreML aligner the app now uses.
- **FLEURS:** 3–4 points better in German, Japanese and Russian.
- **Serbian:** 11–14 points better. With `sr` and a vocabulary list it scored 35.0% against 46.0% and recovered 12 of the 12 names instead of 11.

Most of the gain is probably the weights rather than the runtime: Q8_0 keeps 8 bits per weight, where the MLX build has 4.

The costs:
- **Speed:** about 30% lower throughput, 62–72× real time on English against 89–103×.
- **Download:** 1.02 GB instead of 0.72 GB.
- **One runaway window:** llama.cpp has no repetition stop, and one 8.3 s meeting window looped until the token cap ("hey," 70 times). That window holds 68 of llama.cpp's 74 invented-run words on meetings. The app's transcript sanitizer removes this pattern; see [Repetition](#repetition-and-the-token-cap).

Memory is lower: llama-server peaked at a 1.6 GB footprint, while the MLX run peaked at a 2.5 GB process footprint, 1.4 GB of it MLX allocations.

**Recommendation:** move the compact tier to llama.cpp with the Q8_0 GGUF.

## Setup

- **Machine:** Apple M4 Max with 48 GB, macOS 27.2.1. The two backends ran one after the other, each in its own process.
- **MLX:** `aufklarer/Qwen3-ASR-0.6B-MLX-4bit` at `bc441bd1`, the app's pinned snapshot (708 MB of weights), through the speech-swift fork at `8e87821` (v0.0.29) with mlx-swift 0.32.3 and FluidAudio 0.18.3.
- **llama.cpp:** `ggml-org/Qwen3-ASR-0.6B-GGUF` at revision `928ab958557df9aa2ef1c93e0e83c7ad0933fae2`:
  - `Qwen3-ASR-0.6B-Q8_0.gguf`: 804,749,248 bytes, SHA-256 `bca25981…f6aa1971`.
  - `mmproj-Qwen3-ASR-0.6B-Q8_0.gguf`: 214,392,480 bytes, SHA-256 `41a342b5…2e36603d`.
  - Together that is 1.02 GB. They ran on the app's pinned llama-server v1.0.0 (build 12359) with `-ngl 99 -c 4096 --parallel 1 --cache-ram 256`, the 1.7B tier's flags.
  - The repository also has bf16 files, and there is no smaller quantization from ggml-org.
- **Prompt and decoding:** the same as the [1.7B run](../2026-11-14/REPORT.md). Qwen's own prompt goes through `/completion`, decoding is greedy, the token cap is `min(768, max(128, 18 × seconds))`, and the language code is passed verbatim.
- **Layouts:**
  - `merge-15-v14` is the app's 0.6B word-attribution layout: 14 s VAD regions merged across pauses of up to 5 s into windows of up to 15 s.
  - `engine-15` is the plain path for tracks without speaker separation and for dictation.
  - Both keep speech-swift's default decoding, whose repetition block only starts above 15 s, so it never engages on either layout. The two backends therefore decode under the same rules.
- **Data:** CloudSTT's chunks: 16 AMI Mix-Headset windows (27.4 min) and 106 chunks from three meetings (73.4 min). Also the five FLEURS tracks from `fetch_fleurs.py`: German, Japanese, Russian and Serbian, plus a code-switched English/German track.
- **Attribution:** each backend's `merge-15-v14` words were timed by the CoreML INT8 forced aligner and assigned to Nemotron 3 turns, as in the [CoreML aligner report](../../../QwenSpanLength/results/2026-11-15/REPORT.md). All 1,138 windows aligned without a failure.

Intervals are 95% paired bootstrap intervals over AMI windows, meeting chunks or FLEURS utterances.

## English

| | MLX 4-bit | llama.cpp Q8_0 | Δ llama − MLX (95% CI) |
|---|---:|---:|---:|
| AMI WER, `merge-15-v14` (shipped) | 20.90% | **19.47%** | −1.43 (−2.20…−0.55) |
| AMI WER, `engine-15` | 20.90% | **19.61%** | −1.29 (−2.09…−0.32) |
| AMI cpWER, `merge-15-v14` + CoreML aligner | 35.80% | **35.06%** | −0.74 (−1.33…−0.15) |
| Speaker-memory turns, AMI / meetings | 363/417, 1,411/1,501 | 358/417, 1,427/1,501 | — |
| AMI vs Qwen3-ASR 1.7B text, `merge-15-v14` | 8.62% | 6.51% | −2.11 (−3.56…−0.74) |
| Meetings vs Qwen3-ASR 1.7B text, `merge-15-v14` | 6.11% | 5.93% | −0.19 (−1.22…+1.54) |
| Meetings vs Qwen3-ASR 1.7B text, `engine-15` | 6.42% | **5.42%** | −0.99 (−1.51…−0.51) |
| Speed, AMI / meetings (`merge-15-v14`) | 103× / 89× | 72× / 62× | — |

- **AMI improves on both layouts**, mostly through fewer deletions (14.4% against 15.6%).
- **The meetings have no human transcript, and CloudSTT's vendor consensus was not regenerated.** This run did not send the owner's meeting audio to OpenAI or Google again. As a stand-in reference, meeting text was compared with Qwen3-ASR 1.7B's shipped transcripts. On that measure, llama.cpp's 0.6B text is 1.0 point closer to 1.7B on the plain path. On the merged path it is 0.2 points closer, with an interval that includes zero, because the runaway window below adds 68 words.
- **The backends disagree on 5.1–5.5% of meeting words and 6.7–6.9% of AMI words.** That is three to four times the 1.7B tiers' 1.7%, as expected when the weight precision also changes. Only 15 of the 106 meeting chunks came out identical.

## Repetition and the token cap

| Layout | Windows at the token cap, MLX / llama.cpp | Invented-run words on meetings vs MLX | … vs 1.7B, MLX / llama.cpp |
|---|---:|---:|---:|
| `merge-15-v14` | 0 / 1 (of 571) | 74 | 7 / 68 |
| `engine-15` | 0 / 0 (of 766) | 4 | 0 / 4 |
| FLEURS, `e15-oracle` and `e15-vote` | 2 / 0 (of 168 each) | — | — |

The only llama.cpp loop was an 8.3 s window on a meeting's system track. MLX decoded 8 words there; llama.cpp produced "hey," 70 times and stopped at the 149-token cap. The app's `TranscriptSanitizer` already collapses such a burst: it drops long repeated cycles at speaking rates no person reaches, and this one runs at about 9 words a second. MLX hit the cap in two Japanese FLEURS windows on the plain path, which is also why its Japanese CER there was 31.9%. Neither runtime used a repetition block on these windows.

## FLEURS (error rate, CER for Japanese; MLX → llama.cpp)

| Condition | German | Japanese | Russian | Serbian | English + German |
|---|---:|---:|---:|---:|---:|
| `merge-15`, true language | 10.2% → **7.3%** | 15.6% → **12.7%** | 14.6% → **10.9%** | 44.6% → **33.1%** | 15.6% → 14.9% (auto) |
| `merge-15`, auto | 10.9% → **7.5%** | 16.5% → 14.2% | 15.1% → **10.9%** | 52.9% → **47.5%** | 15.6% → 14.9% |
| `engine-15`, true language | 10.2% → 7.6% | 31.9% → **12.7%** | 14.9% → **11.1%** | 45.2% → **32.6%** | 11.6% → 10.3% (auto) |
| `engine-15`, auto | 12.3% → **7.5%** | 17.0% → 14.6% | 15.5% → **11.1%** | 53.1% → **47.8%** | 11.6% → 10.3% |

Bold marks a difference whose interval excludes zero. No language got worse.

| Serbian (5.3 min), `merge-15` | MLX | llama.cpp | Δ (95% CI) | Names recovered, MLX / llama.cpp |
|---|---:|---:|---:|---:|
| `sr` | 44.6% | 33.1% | −11.5 (−15.5…−7.6) | 5 / 8 of 12 |
| `sr` + vocabulary | 46.0% | **35.0%** | −10.9 (−16.1…−6.4) | 11 / 12 of 12 |
| auto + vocabulary | 52.5% | **38.4%** | −14.1 (−18.3…−9.6) | 11 / 12 of 12 |

The harness's vote-and-pin left Serbian on auto for both backends. Its vote has no Serbian/Croatian alias, while the app's has one, and in the app such a track would pin to `hr`. The 0.6B tier stays well behind 1.7B on Serbian: the 1.7B tier scored 12.4% with `sr` and a vocabulary list on llama.cpp.

## Speed and memory

| | MLX 4-bit | llama.cpp Q8_0 |
|---|---:|---:|
| English, `merge-15-v14` / `engine-15` | 92× / 87× real time | 65× / 62× |
| FLEURS, pinned language | 56× | 66× |
| Whole job (127 items, 11 conditions) | 347 s | 440 s |
| Load | 0.5 s | 4.1 s (server start) |
| Peak memory | 2.52 GB process footprint (MLX allocations 1.42 GB) | 1.63 GB server footprint (2.19 GB RSS with the mapped GGUF) + 0.52 GB harness |
| Download | 0.72 GB | 1.02 GB |

llama.cpp is about 30% slower on English. A 60-minute meeting track still decodes in about a minute.

## Limits

- **No meeting accuracy.** Meeting scores are agreement with Qwen3-ASR 1.7B's text, which is itself wrong in places, not with the vendor consensus or a human reference.
- **Small sets.** AMI is 27 minutes. Each FLEURS track has 30 utterances, and its code-switched track is synthetic.
- **Precision and runtime are confounded.** The Q8_0 GGUF and the MLX 4-bit build differ in both runtime and weight precision. Each arm was run once; both decode greedily.
- **Only English was attributed.** Speaker attribution and cpWER were measured on English only.

## Reproduction and privacy

`../../README.md` has the commands: `TIER=0.6b` for `make_backend_jobs.py`, `run_backend.sh` and `score_backends.py`. `summary.json` holds the aggregates. Audio, transcripts, diarization turns and aligned words stay in the private `SPAN_BENCH_OUT` folder. Meeting audio was read through `lokalbot-cli path`. Nothing was sent over the network except the public Hugging Face downloads of the two model snapshots and localhost requests to llama-server.
