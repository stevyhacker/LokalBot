# Nemotron 3 versus LokalBot diarization — 23 September 2026

**Recommendation: integrate the full-precision Nemotron `offline` preset as an optional post-meeting backend.** On this Mac and public test subset, it reduced diarization error by **66.5% relative** and ran **2.05× faster** than LokalBot's current configuration. It beat the current baseline on every recording condition. The existing app was not modified, rebuilt, installed, or released.

`fast128` was effectively tied on accuracy (0.05 percentage points better), but slower. The smaller W8A8 model is promising for keeping the GPU available, but its error rate was higher and it invented a fifth speaker in ES2004a's distant-microphone recording. Prefer the full-precision offline preset for the first integration. Live transcription can be evaluated separately using `low`.

## Measured quality

Apple M4 Max, 16 CPU cores, 48 GB memory; macOS 27.0 (26A428); Swift 6.4 release builds. Four independent English AMI test meetings, each evaluated as headset mix and distant-microphone audio: **8 conditions, 184.55 minutes of audio, 92.28 minutes of unique conversation**. Every reference has four speakers. Inputs and model revisions were fixed before inference; no test-set tuning or known speaker-count hints were used.

DER adds missed speech, false alarms, and speaker confusion, divided by reference speaker time. It is not a percentage of incorrectly transcribed words. Results are pooled by reference speaker duration, with overlap scored. A 250 ms collar allows boundary tolerance; the primary comparison uses none.

| System | DER, zero collar ↓ | DER, 250 ms collar ↓ | Correct speaker count | Peak process RSS |
|---|---:|---:|---:|---:|
| LokalBot current | 43.44% | 30.45% | 5/8 | 0.68 GiB |
| Current + overlapping output | 42.32% | 29.19% | 5/8 | 0.69 GiB |
| FluidAudio community defaults + overlap | 43.61% | 30.44% | 5/8 | 0.66 GiB |
| Nemotron offline | 14.56% | 8.34% | 8/8 | 0.67 GiB |
| Nemotron fast128 | 14.51% | 8.19% | 8/8 | 0.64 GiB |
| Nemotron c128 W8A8 (CPU/ANE) | 15.73% | 9.34% | 7/8 | 0.63 GiB |
| Nemotron low (streaming API) | 16.48% | 10.45% | 8/8 | 0.41 GiB |

All four Nemotron presets had lower zero-collar DER than the current baseline on all eight conditions. The offline model reduced the speaker-confusion component from **8.87% to 1.77%**, missed speech from **15.34% to 8.40%**, and false alarms from **19.23% to 4.38%**. These are percentage points of reference speaker time.

The pyannote controls matter: preserving overlap alone improved 43.44% to 42.32%; using community defaults with overlap yielded 43.61%. Neither control closed the gap or recovered the two missing speakers in TS3003a. This is a comparison against the pinned FluidAudio implementation and its configurations, not a claim about every implementation of pyannote Community-1.

## Measured runtime

Warm medians over three runs after one warm-up, on the same 17.49-minute ES2004a headset recording. File loading, feature extraction, inference, and postprocessing are included; model loading and result serialization are excluded. Inference jobs ran sequentially. All four repeated outputs were identical for each of these systems.

| System | Time for 17.49-minute recording ↓ | Audio / processing time ↑ |
|---|---:|---:|
| LokalBot current | 4.31 s | 243× |
| Nemotron offline | 2.10 s | 500× |
| Nemotron fast128 | 2.88 s | 365× |
| Nemotron c128 W8A8 (CPU/ANE) | 2.19 s | 480× |

On the first full-set pass, processing took 50.06 s for the current baseline, 24.21 s for offline, 30.68 s for fast128, and 23.20 s for W8A8. Some initial batch runs overlapped CPU-only scoring/setup activity; use the separate warm repeats for the cleaner performance comparison. This was an active workstation, not a thermally controlled lab run.

The `low` streaming API processed the complete set at **20.3× real time**, with **16.48% DER** and correct speaker counts on all eight files. Across **15,370 inference-producing calls**, median compute time was **35.37 ms**, p95 **35.60 ms**, and maximum **287.93 ms**; none exceeded the 720 ms chunk duration. Its configured audio-buffer latency is **1.04 s**, before compute, ASR, and application delivery. This was accelerated file replay in 100 ms pieces, not a live microphone/UI test.

Full-precision bundles are approximately **190 MiB** each; the W8A8 bundle is **95 MiB**, plus its approximately 2 MiB host projection. The baseline's actual loaded bundle was about **21 MiB**. Peak RSS above includes loaded audio and harness buffers, and is cumulative over a process. It excludes some out-of-process accelerator allocations; it is not total system memory or a power measurement. The benchmark verified all four baseline weight files against both the installed cache and upstream LFS hashes.

## LokalBot implications

1. **Post-meeting speaker grouping:** `offline` is the leading integration candidate. It has a 30.4 s internal input buffer, which is suitable for completed recordings. Keep the existing backend available while validating representative LokalBot meetings.
2. **Remembered voices need a separate plan:** `SpeakerVoiceSample.fingerprint` and matching require the existing 256-dimensional pyannote embeddings. Nemotron's anonymous channel IDs and internal caches are not interchangeable voice profiles. Preserve a compatible embedding pass, or keep the existing backend for that feature until the replacement path is validated.
3. **Names and overlap remain application work:** improved acoustic segmentation does not identify a person or separate simultaneous words. Preserve meeting identity evidence and review, and validate the existing ASR/turn-alignment path with overlapping Nemotron segments.
4. **Existing threshold documentation is backwards:** `NeuralDiarizationEngine.swift:28` says 0.70 preserves more speakers. The pinned library defines the setting as Euclidean merge distance: larger values merge more aggressively. The control experiments do not establish that a threshold-only change would fix current behavior; no production settings were changed.

This study does **not** establish performance on five-to-eight speakers, more than eight speakers, other languages, actual LokalBot mic/system-track echo, voice-profile recognition, or end-to-end word/name attribution. It is enough to justify an integration pilot, not to declare the complete meeting pipeline fixed.

## Per-recording zero-collar DER

| Recording | Current | Offline | fast128 | W8A8 | Live low |
|---|---:|---:|---:|---:|---:|
| EN2002a_mhm | 45.69% | 14.73% | 14.88% | 15.19% | 15.59% |
| EN2002a_sdm | 46.09% | 16.44% | 16.88% | 17.66% | 17.24% |
| ES2004a_mhm | 36.90% | 9.68% | 9.77% | 9.94% | 9.87% |
| ES2004a_sdm | 41.87% | 18.10% | 15.37% | 24.90% | 29.85% |
| IS1009a_mhm | 33.68% | 19.49% | 18.50% | 19.11% | 18.60% |
| IS1009a_sdm | 35.43% | 13.02% | 13.13% | 13.22% | 13.77% |
| TS3003a_mhm | 48.54% | 9.45% | 9.38% | 9.48% | 9.27% |
| TS3003a_sdm | 48.66% | 12.48% | 13.85% | 14.09% | 17.71% |

## Reproduction and evidence

[Harness and protocol](../../README.md), [complete scores](scores.json), [warm timing runs](timings.json), [streaming call summary](streaming.json), [model and audio hashes](downloads.json), [baseline hashes](baseline-models.json), [environment and source revisions](environment.json). Raw predictions and reference RTTMs are retained in the original local benchmark artifacts and regenerated by the harness; the integration PR includes aggregate evidence. Statements about the unchanged app describe the benchmark run before the subsequent integration.

Validated: two isolated Swift release executables; seven configurations × eight full recordings = **56 scored runs**; **16 additional timing runs**; scoring sanity checks for label permutation and missed speech; complete per-file predictions and finite timestamps. No local UI tests or production changes.

Source revisions: app `32f7459b2b2a59d5cd68dec6c1116e31ed08212e`; baseline FluidAudio `87a39dfe4068fef0f1c69bfe704b2b3ef4fbc5bc`; Nemotron FluidAudio runtime `5c51c5c93afff0d89594a2a93c3103e790ba648c`; CoreML checkpoint `53445f72d5735e33406ccce7b92116bce7ab1ab7`; reference annotations `9527b7c64846fb38316a610f32e9d3466bd6d8b7`.

The tested [CoreML checkpoint](https://huggingface.co/FluidInference/nemotron-3-diarization-coreml/tree/53445f72d5735e33406ccce7b92116bce7ab1ab7) declares the final NVIDIA model as its base and OpenMDW 1.1 as its license. [NVIDIA model card](https://huggingface.co/nvidia/Nemotron-3-Diarization), [annotation source](https://github.com/nttcslab-sp/diar-forced-alignment/tree/9527b7c64846fb38316a610f32e9d3466bd6d8b7/AMI/test).
