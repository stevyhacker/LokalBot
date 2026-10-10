Historical experiment snapshot. Current adoption: **E2B remains the default; the experimental switch enables hybrid plus prefix search.** See [the trial guide](../../../../Docs/experimental-autocomplete-hybrid.md). Complete raw evidence and the original, unedited report are in [the experiment archive](../2026-10-10-experiments.tar.gz). Archive member paths are listed in [the manifest](../2026-10-10-experiments-manifest.json).

# Candidate decoder experiment on updated master — 2026-10-10

The worktree now includes **origin/master `193460c3def4e11aa44dc95e28bef8724c783e80`**, with [PR #228](https://github.com/stevyhacker/lokalbot/pull/228) (autocomplete overlay/caret behavior) and [PR #229](https://github.com/stevyhacker/lokalbot/pull/229) (remote autocomplete benchmarking). A final fetch after the benchmark confirmed that this was still origin/master.

The decoder experiment was preserved and rebuilt on that revision. **Keep the current decoder as the default:** the fresh benchmark reaches the same conclusion as the [earlier pre-merge run](../2026-10-10-candidates/REPORT.md). Two- and four-candidate search each add only two first-word reference matches per 600 checkpoints, with uncertain quality gains, more nonmatching suggestions and higher latency.

## Results on updated master

All **5,400 requests** completed: 600 checkpoints × three decoders × three counterbalanced rounds, with **zero errors, zero retries, and zero output/suppression variation between repetitions**.

| Metric | Current decoder | 2 candidates | 4 candidates |
|---|---:|---:|---:|
| First-word reference matches | 187 / 600 | 189 / 600 | 189 / 600 |
| First-word agreement | 31.17% | 31.50% | 31.50% |
| Two consecutive reference words | 11.99% | 11.38% | 11.99% |
| Three consecutive reference words | 4.92% | 4.15% | 3.89% |
| Suggestions shown | 324 | 338 | 345 |
| Shown without a first-word reference match | 137 | 149 | 156 |
| First-word agreement when shown | 57.72% | 55.92% | 54.78% |
| Any finalist matches, diagnostic ceiling only | 187 | 194 | 206 |

Repeated runs are not additional independent quality examples. Suppression remains in the denominator. Two-/three-word metrics require enough remaining reference words, giving denominators of 492 and 386. Exact reference agreement can penalize valid alternate wording and does not measure human acceptance.

The paired gain is **+0.33 percentage points** at both widths. With 3,000 category-stratified, paired whole-phrase bootstrap resamples, the 95% intervals are **−1.48 to +2.19 points** for width 2 and **−1.35 to +2.16 points** for width 4. Neither establishes an improvement. Of the 14 additional suggestions shown by width 2, two match; of the 21 additional suggestions shown by width 4, three match.

| Checkpoint group | Count | Current matches | 2 candidates | 4 candidates |
|---|---:|---:|---:|---:|
| Public next-word | 310 | 61 | 64 | 64 |
| Original challenge next-word | 178 | 54 | 51 | 51 |
| Public midword | 112 | 72 | 74 | 74 |

## Fresh latency and memory measurements

These are **warm complete-engine-request timings**, including tokenization, prefill, decoding/search and normalization. They exclude request construction, model loading, keyboard/debounce handling, live accessibility reads and overlay presentation. In particular, they do not measure the UI improvements in PR #228. Experimental branches publish only the selected final suggestion, so these are not first-partial-display timings.

The main table pools 1,800 requests per decoder across the three runs.

| Metric | Current decoder | 2 candidates | 4 candidates |
|---|---:|---:|---:|
| Median latency | 29.36 ms | 73.01 ms | 91.77 ms |
| p95 latency | 88.54 ms | 100.17 ms | 116.64 ms |
| Mean latency | 43.16 ms | 58.63 ms | 68.03 ms |
| Median on the same 324 shown checkpoints | 64.98 ms | 90.75 ms | 103.97 ms |
| Peak process RSS across runs | 3.8822–3.8845 GiB | 3.9226–3.9232 GiB | 3.9973–3.9977 GiB |

The mean cost increases by **15.47 ms** with width 2 and **24.87 ms** with width 4. The matched shown-checkpoint row separates the extra cost from the control's fast confidence rejections. RSS measures the process, not isolated GPU memory or energy.

| Round and order | Current p50 / p95 | Width 2 p50 / p95 | Width 4 p50 / p95 |
|---|---:|---:|---:|
| 1: 1 → 2 → 4 | 29.01 / 83.52 ms | 73.01 / 99.72 ms | 89.11 / 113.64 ms |
| 2: 2 → 4 → 1 | 31.26 / 93.19 ms | 72.72 / 99.78 ms | 92.03 / 120.16 ms |
| 3: 4 → 1 → 2 | 28.22 / 83.89 ms | 71.61 / 100.61 ms | 93.61 / 112.85 ms |

## Integration and comparison with the previous base

The worktree was fast-forwarded from `32381e9` to `193460c`, preserving the uncommitted experiment and existing untracked files. The overlapping replay harness now supports both the merged remote benchmark path and the native candidate experiment. Native widths 2 and 4 are explicitly rejected for hosted engines by both the Python CLI and Swift replay before inference starts; remote runs cannot silently ignore the requested decoder.

The native decoder implementation itself is byte-identical to the previous experiment. Candidate expansion, per-branch token healing/UTF-8/confidence/stop state, shared KV cache, batched branch decoding and mean-log-probability final ranking are unchanged. The normal app selector still uses the original single sampled continuation. See the [algorithm and interpretation](../2026-10-10-candidates/REPORT.md#what-the-experiment-actually-changes) and [reproduction instructions](../../README.md#two--and-four-candidate-decoder-experiment).

The [cross-revision comparison](prior-comparison.json) verifies:

- The model, corpus, original challenge, selected phrase IDs and run order are unchanged.
- Every input fixture is byte-identical to its previous-run counterpart.
- Across all 5,400 paired observations, **zero rendered prompts, suggestions or suppression results changed**. Errors and requested decoder widths also match.
- The new upstream scorer preserves all earlier quality metrics; its additional retry and p90 fields do not change reference agreement.

Thus the earlier quality result survives integration of both PRs. Timing values above were measured again on the rebuilt app; they were not copied from the earlier run.

## Frozen setup

- Hardware: Apple M4 Max, 48 GiB, macOS 27.0.1, AC power. Runs were serial; ordinary desktop background activity was not disabled.
- Model: `gemma-4-E2B.i1-Q6_K.gguf`, SHA-256 `20f49b221691c71d955e1d5a840b6e26329db4a5e1626f702fa4226e80a9c629`.
- Release executable SHA-256: `e0ad7e4eabbd18253757f5094faf638344a5520a5f75e1eefbb84bda3331880c`. Runtime remains pinned llama.cpp `b11474`.
- Production prompt and settings held fixed: temperature 0.1, top-k 20, top-p 0.7, min-p 0.08, repeat penalty 1.05, seed `0x00C0FFEE`, six free tokens, four output words and the existing confidence gate. The logical per-branch context limit is 2,048 tokens; experimental KV capacity scales with width.
- Dataset: 56 public synthetic phrases selected from the existing held-out partition plus 32 original challenge phrases; 310 public next-word, 178 challenge next-word and 112 public midword checkpoints. This is an existing synthetic test set, not a new blind user sample.
- Only typed prefixes and synthetic surface metadata enter inference. References, future words and category labels stay outside inference; no personal writing, live screen context or saved memory is used.
- All 600 rendered prompts are identical across all modes and repetitions. App and source hashes were unchanged during the run.

This does not measure semantic equivalence, user acceptance, end-to-end typing latency, sustained typing/cancellation behavior, energy use or another product's runtime. The remote benchmark path was covered by offline tests; this experiment did not invoke hosted inference.

## Validation and evidence

The updated Release build and repository-wide strict SwiftLint passed. The expanded non-UI Swift selection ran **183 tests: 181 passed, 2 skipped, 0 failed**. It covers candidate decoding, native warm/cold state equivalence on the actual Gemma model, token healing/confidence, coordinator behavior, visual caret/overlay geometry, replay command parsing, HTTP healing and text-engine helpers. The two skips are existing tests requiring a separate compact fallback model that is absent. All **35 Python benchmark tests passed**, including the new guard against native candidate options on a remote engine.

No local UI tests ran. The updated experiment was built and benchmarked, **not installed or released**.

- [manifest.json](manifest.json), [summary.json](summary.json), [analysis.json](analysis.json): frozen hashes, all nine runs, paired quality intervals and pooled timing/diagnostics.
- [prior-comparison.json](prior-comparison.json), [integration.json](integration.json), [validation.json](validation.json): cross-revision proof, included PRs and test results.
- [raw-runs.tar.gz (archive)](../2026-10-10-experiments.tar.gz) and [archive-manifest.json](archive-manifest.json): inputs, references, observations, native logs, reports, implementation patch, analysis/comparison scripts and validation logs, with file checksums.
- [ATTRIBUTION.md](ATTRIBUTION.md) and [COTABBY-LICENSE.txt (archive)](../2026-10-10-experiments.tar.gz): synthetic public corpus provenance and license.

The [pre-merge results](../2026-10-10-candidates/REPORT.md) remain available as a historical snapshot.
