# Qwen3 forced aligner on CoreML vs MLX — 15 November 2026

speech-swift's CoreML forced aligner (`CoreMLForcedAligner`, `aufklarer/Qwen3-ForcedAligner-0.6B-CoreML-INT8`) attributes speakers as well as the MLX 4-bit aligner the app ships. On identical text, AMI cpWER differs by −0.10 points (−0.58…+0.36) and speaker-memory turns are unchanged. It uses about a quarter of the memory, peaking at 0.9 GB against 3.5–4.1 GB for MLX, and it never failed on the benchmark's 302 windows of up to 30 s. It is slower, at 126× real time against 210×, and its first load on a Mac takes about 13 s while the Neural Engine compiles it. FP16 is no better than INT8 and is 1.8 GB to download, against 1.1 GB.

The CoreML export takes at most 30 s of audio, so Qwen3-ASR 1.7B's merged decode windows have to shrink from ≤60 s to ≤30 s. On AMI that costs nothing measurable: WER moves by +0.14 points (−0.55…+0.72) and cpWER by −0.38 (−1.31…+0.44). The meeting consensus could not be scored this time (see [Limits](#limits)). The 30 September report measured ≤30 s windows 0.26 points behind ≤60 s on meetings.

**Recommendation:** switch to CoreML INT8 with ≤30 s windows for Qwen3-ASR 1.7B, and wrap each alignment in an autorelease pool (see [Memory](#memory)).

## Setup

- **Runtime:** `../../harness` with the app's pins as of today: the `stevyhacker/speech-swift` fork at `8e87821` (v0.0.29), FluidAudio 0.18.3 and mlx-swift 0.32.3. It ran on an Apple M4 Max with 48 GB on macOS 27.2.1.
- **Text:** Qwen3-ASR 1.7B (`aufklarer/Qwen3-ASR-1.7B-MLX-8bit`) with `en` and repetition blocking off.
  - `merge-60-off-v14`, the shipped layout: the app's ≤14 s VAD regions merged across ≤5 s pauses into ≤60 s windows. These transcripts came from the 14 November llama.cpp benchmark, which used the same pins and was byte-identical to its earlier run.
  - `merge-30-off-v14`, new: the same merge capped at 30 s. This is the layout the app can build, and it differs from 30 September's `merge-30-off`, which re-ran VAD with a 30 s cap.
- **Speakers:** Nemotron 3 diarization at the app's current revision (`25a90f97`), using the offline preset with activity threshold 0.5 and a 0.2 s minimum, run on the full recordings. Words take the speaker at their midpoint, or the nearest turn within 1 s. A window the aligner rejects goes whole to the speaker at its midpoint, as `AttributedTrackTranscriber` does.
- **Data:** CloudSTT's prepared chunks: 16 AMI Mix-Headset windows (27.4 minutes) and 106 chunks from three of the owner's meetings (73.4 minutes).
- **Aligners:**
  - MLX: `aufklarer/Qwen3-ForcedAligner-0.6B-4bit` at `f0e9f12a`, the app's copy. It trims MLX's buffer cache to 512 MB after each pass, as `QwenWordAligner` does.
  - CoreML: `aufklarer/Qwen3-ForcedAligner-0.6B-CoreML-INT8` at `a9d6ec64` and `-FP16` at `11f686d7`. Both repositories ship compiled `.mlmodelc` bundles, so loading never compiles a package. Each pass runs one forward pass and uses speech-swift's default compute units: the encoder on CPU and Neural Engine, the decoder on all units.
  - The INT4 export (`bb755f78`, April) has no `embed_tokens.fp16.bin`, which this runtime requires, so it was not run.

Intervals are 95% paired chunk-bootstrap intervals. Every row is compared with the shipped row (a), and the CoreML rows are also compared with (b), the MLX aligner on identical text.

## Results

| Condition | AMI WER | Δ vs (a) | AMI cpWER | Δ vs (a) | Δ vs (b) | Speaker memory, AMI and meetings | Failed windows | Align speed | Peak footprint |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| (a) MLX 4-bit, ≤60 s (shipped) | 17.81% | — | 34.23% | — | — | 360/417, 1,406/1,501 | 0 of 187 | 223× | 4.07 GB |
| (b) MLX 4-bit, ≤30 s | 17.95% | +0.14 (−0.55…+0.72) | 33.85% | −0.38 (−1.31…+0.44) | — | 361/417, 1,422/1,501 | 0 of 302 | 210× | 3.51 GB |
| **(c) CoreML INT8, ≤30 s** | 17.95% | +0.14 (−0.55…+0.72) | **33.75%** | −0.48 (−1.56…+0.42) | −0.10 (−0.58…+0.36) | 368/417, 1,419/1,501 | 0 of 302 | 126× | **0.89 GB** |
| (d) CoreML FP16, ≤30 s | 17.95% | +0.14 (−0.55…+0.72) | 33.68% | −0.55 (−1.54…+0.25) | −0.17 (−0.57…+0.22) | 366/417, 1,413/1,501 | 0 of 302 | 107× | 0.83 GB |
| (e) CoreML INT8, GPU only | 17.95% | +0.14 | 33.68% | −0.55 (−1.59…+0.32) | −0.17 (−0.53…+0.19) | 365/417, 1,417/1,501 | 0 of 302 | 163× | 0.80 GB¹ |
| (f) CoreML INT8, Neural Engine only | 17.95% | +0.14 | 33.75% | −0.48 (−1.56…+0.42) | −0.10 (−0.58…+0.36) | 368/417, 1,419/1,501 | 0 of 302 | 105× | 0.18 GB¹ |

¹ Peak over the full run rather than one long chunk. Neural Engine buffers are not charged to the process, so (f)'s figure understates its real use.

- **Alignment never changes the text.** Rows (b) to (f) share one transcript, so their WER is identical. The shipped row's 17.81% matches the llama.cpp benchmark's 17.80% on these pins. On 30 September it was 17.69%, with older pins and an older Nemotron revision.
- **On the same text, CoreML attributes as well as MLX.** Every CoreML row is within 0.2 points of (b) on cpWER, with intervals centred near zero, and supports as many speaker-memory turns.
- **≤30 s windows are within noise of ≤60 s on AMI.** The meeting text changes in 1.35% of words between the two layouts (+0.95…+1.79). Without the vendor consensus that cannot be called better or worse; see [Limits](#limits).
- **Default compute units put the INT8 decoder on the Neural Engine.** Row (f) gives exactly the same timings as (c). GPU only (e) is about 30% faster and just as accurate, but its first load takes 2.6 s and its warm-up 1.8 s, and its numerics differ from the other two. The app keeps speech-swift's defaults.

## Failures and the decoder limit

No window failed in any condition. The longest window was 29.9 s, against the encoder's 3,000-frame limit (30.0 s; the mel extractor gives one frame per 160 samples). The text decoder has a fixed length of 768 tokens. That covers the 15 prompt tokens, 13 audio tokens per second of audio, and each word's tokens plus two timestamp slots. Re-tokenizing the transcripts puts the densest window at about 743 tokens: 101 words in 29.9 s, 3.4 words a second. Seven of the 302 windows were above 700. The headroom is thin for fast speakers. A window that overflows keeps one speaker at its midpoint, which is the app's existing per-segment fallback, and the app logs it.

## Word boundaries on identical text

| Compared with (b), MLX 4-bit | Words | Start, median / p95 | End, median / p95 | Identical | Within 80 ms | Over 240 ms | Words that change speaker |
|---|---:|---:|---:|---:|---:|---:|---:|
| (c) CoreML INT8 | 13,637 | 0 / 480 ms | 0 / 480 ms | 81.2% | 88.5% | 7.7% | 76 (0.56%) |
| (d) CoreML FP16 | 13,637 | 0 / 480 ms | 0 / 480 ms | 81.0% | 88.5% | 7.8% | 78 (0.57%) |
| (e) CoreML INT8, GPU only | 13,637 | 0 / 400 ms | 0 / 320 ms | 84.1% | 90.5% | 6.1% | 62 (0.45%) |

Timestamps come in 80 ms steps. Most boundaries are identical, but about one in thirteen moves by more than 240 ms. The disagreement mostly comes from the MLX 4-bit weights rather than CoreML: INT8 and FP16 agree with each other on 95.1% of boundaries, with 2.2% over 240 ms, while each agrees with MLX 4-bit on 81%. Only about half a percent of words land with a different speaker, and cpWER shows no net effect.

## Speed

| | Align time, 101 min of audio | Per window, median / p95 | Load (first ever / later) |
|---|---:|---:|---:|
| (a) MLX 4-bit, ≤60 s | 27.1 s | 142 / 267 ms | 0.4 s |
| (b) MLX 4-bit, ≤30 s | 28.8 s | 103 / 140 ms | 0.4 s |
| (c) CoreML INT8 | 48.0 s | 159 / 162 ms | 13.1 s / 0.6 s |
| (d) CoreML FP16 | 56.6 s | 188 / 191 ms | 14.9 s / 0.6 s |

CoreML pays for its fixed shapes: every pass encodes 30 s of mel and decodes 768 tokens, so a 2 s window costs as much as a 30 s one. A 60-minute meeting still aligns in about 30 s. The first load in a process on a new Mac compiles the bundles for the Neural Engine. macOS caches that compilation, so later processes, and reloads after the app's idle unload, take 0.6 s.

## Memory

Peak physical footprint (`phys_footprint`, which Activity Monitor shows) was measured in a fresh process per aligner on the longest meeting chunk, `system` track, 120 s:

| Aligner | Peak footprint |
|---|---:|
| MLX 4-bit, ≤60 s windows (shipped) | 4.07 GB |
| MLX 4-bit, ≤30 s windows | 3.51 GB |
| CoreML INT8 | 0.89 GB |
| CoreML FP16 | 0.83 GB |

The MLX figures include the 512 MB scratch cap. The peak is the working set of one pass: the 4-bit weights are expanded during evaluation.

**CoreML needs an autorelease pool per pass.** Without one, the footprint over the full 122-item run grew from 0.8 GB to 4.6 GB. Each prediction returns autoreleased `MLMultiArray`s, about 12 MB a pass, and a long loop on one thread never drains them. With `autoreleasepool` around each `align` call, the full run peaked at 0.83 GB (INT8) and 0.82 GB (FP16), and the timings were identical. The app aligns a whole track in one task, so it needs the same pool.

## Limits

- **No meeting consensus.** CloudSTT's vendor outputs (OpenAI, Google and NVIDIA voters) had been deleted from `/private/tmp`. Recreating them means sending the owner's meeting audio to those APIs again, which this run did not do without asking. The meeting columns therefore compare text with the shipped layout's text, which measures change, not accuracy. On 30 September, with the consensus, re-run-VAD ≤30 s windows scored 4.59% against 4.33% for ≤60 s, and 4.41% for the shipped v14 layout. AMI, which has a human reference, shows no difference.
- **Small sets.** AMI is 27 minutes, so its intervals are about ±1 point. Each condition was run once; decoding and alignment are deterministic.
- **One layout and one language.** Speaker attribution was scored only on English and on Mix-Headset AMI audio. The aligner's other ten languages were not measured.
- **Decoder headroom.** No window overflowed the decoder's 768 tokens here, but the densest came within about 25 tokens. Faster speech, or text with many short tokens, will sometimes fall back to one speaker per segment.

## Reproduction and privacy

`../../README.md` lists the commands under "CoreML aligner". `coreml-summary.json` holds the aggregates. Audio, transcripts, diarization turns and aligned words stay in the private `SPAN_BENCH_OUT` folder. Meeting audio was read through `lokalbot-cli path`, which is read-only. Nothing was sent over the network except the public Hugging Face downloads of the CoreML weights. The source baseline is `3497953c`.
