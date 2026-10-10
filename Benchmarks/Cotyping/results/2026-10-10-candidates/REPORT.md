Historical experiment snapshot. Current adoption: **E2B remains the default; the experimental switch enables hybrid plus prefix search.** See [the trial guide](../../../../Docs/experimental-autocomplete-hybrid.md). Complete raw evidence and the original, unedited report are in [the experiment archive](../2026-10-10-experiments.tar.gz). Archive member paths are listed in [the manifest](../2026-10-10-experiments-manifest.json).

# Two- and four-candidate decoder experiment — 2026-10-10

Historical run on `32381e9`, before PRs #228 and #229. See the [fresh benchmark on updated master](../2026-10-10-candidates-master/REPORT.md) for the current worktree and measurements.

Keep the current decoder as the default. With the same Gemma model and byte-identical production prompts, both experimental widths gained only **2 first-word reference matches out of 600**. Neither gain is statistically distinguishable from zero in this sample. Wider search displayed more nonmatching suggestions and increased latency. The implementation remains available as an opt-in headless experiment.

All nine runs completed: **5,400 requests, zero errors, and zero output/suppression differences between repetitions of each decoder**. No ranking or sampling settings were changed after the benchmark began.

## Selected-suggestion quality

Each column describes 600 unique checkpoints. Repeating a run does not create new quality examples. Suppression counts as a miss; “nonmatching” means disagreement with the synthetic reference, not necessarily bad writing.

| Metric | Current decoder | 2 candidates | 4 candidates |
|---|---:|---:|---:|
| First-word reference matches | 187 / 600 | 189 / 600 | 189 / 600 |
| First-word agreement | 31.17% | 31.50% | 31.50% |
| Two consecutive reference words | 11.99% | 11.38% | 11.99% |
| Three consecutive reference words | 4.92% | 4.15% | 3.89% |
| Suggestions shown | 324 (54.00%) | 338 (56.33%) | 345 (57.50%) |
| Shown without a first-word match | 137 | 149 | 156 |
| First-word agreement when shown | 57.72% | 55.92% | 54.78% |
| Any finalist matches the first word, diagnostic only | 187 | 194 | 206 |

Two-/three-word denominators contain only checkpoints with enough reference words remaining: 492 and 386, respectively.

The paired gain is **+0.33 percentage points** for each width. A category-stratified bootstrap with 3,000 paired whole-phrase resamples gives 95% intervals of **−1.48 to +2.19 points** for width 2 and **−1.35 to +2.16 points** for width 4. Width 2 has 17 gains and 15 losses; width 4 has 16 gains and 14 losses. Public word and midword checkpoints from one phrase stay in the same bootstrap cluster.

All 324 checkpoints shown by the control still produced a suggestion under both experiments. Of the **14 additional** width-2 suggestions, only **2** matched the reference; of the **21 additional** width-4 suggestions, **3** matched. Thus the small overall gain comes from increased coverage, with no net improvement on the control's shown cases for width 2 and one fewer match there for width 4.

| Checkpoint group | Count | Current matches | 2 candidates | 4 candidates |
|---|---:|---:|---:|---:|
| Public next-word | 310 | 61 (19.68%) | 64 (20.65%) | 64 (20.65%) |
| Original challenge next-word | 178 | 54 (30.34%) | 51 (28.65%) | 51 (28.65%) |
| Public midword | 112 | 72 (64.29%) | 74 (66.07%) | 74 (66.07%) |

## Latency and memory

Times cover the **complete engine request after model loading/warmup**, including tokenization, incremental prefill, decoding, search and normalization. They exclude request construction, model loading, debounce, live accessibility reads, coordinator work and overlay presentation. They are not first-visible or end-to-end typing latency. The experimental path publishes only its selected final suggestion; it does not stream unstable branch choices.

Pooled timing below contains 1,800 requests per decoder: the same 600 checkpoints in three separate processes, with order rotated across rounds.

| Metric | Current decoder | 2 candidates | 4 candidates |
|---|---:|---:|---:|
| Median request latency | 28.36 ms | 73.76 ms | 89.82 ms |
| p95 request latency | 85.86 ms | 99.49 ms | 114.48 ms |
| Mean request latency | 41.53 ms | 58.11 ms | 66.91 ms |
| Median on the same 324 shown checkpoints | 62.01 ms | 89.51 ms | 102.74 ms |
| Peak process RSS across runs | 3.883–3.884 GiB | 3.922–3.923 GiB | 3.995–3.998 GiB |
| Native Metal KV allocation | 36 MiB | 72 MiB | 144 MiB |

Wider search adds **16.57 ms / 25.38 ms to mean request latency**. The large median shift partly reflects the control's fast confidence rejections; the matched shown-checkpoint row confirms an additional cost even when all modes return text. Peak RSS is a process measurement, not an isolated GPU-memory or energy measurement.

| Round and order | Current p50 / p95 | Width 2 p50 / p95 | Width 4 p50 / p95 |
|---|---:|---:|---:|
| 1: 1 → 2 → 4 | 27.07 / 85.26 ms | 73.09 / 99.26 ms | 89.96 / 113.92 ms |
| 2: 2 → 4 → 1 | 30.39 / 88.27 ms | 75.00 / 100.70 ms | 89.00 / 116.68 ms |
| 3: 4 → 1 → 2 | 27.79 / 82.22 ms | 73.09 / 97.58 ms | 91.58 / 113.62 ms |

## What the experiment actually changes

The [candidate state (archive)](../2026-10-10-experiments.tar.gz) and [native runtime](../../../../LokalBot/Cotyping/Llama/LlamaCotypingRuntime.swift) implement a beam of at most two or four active token paths. This is an original bounded-search experiment motivated by the [Cotypist analysis](../../../../Docs/cotypist-autocomplete-comparison-2026-10-10.md), not a claim to reproduce its complete decoder.

1. Share the prompt's native KV state. Copy all parent sequence references to temporary slots before recycling active slots, then decode one token per surviving branch in a batch.
2. Branch during required-prefix healing as well as free continuation. Keep each branch's UTF-8, healing, text, confidence and stop state independent.
3. Keep the current penalties, top-k/top-p/min-p filters and temperature. Replace the distribution draw with ranked token expansion. Healing uses compatible alternatives from the same top-64 scan and the existing indexed fallback.
4. Prune active paths by cumulative raw log probability. Rank completed paths by mean raw, temperature-one log probability per generated token, including healing. EOG ends a path without being included in its score. This is an experimental ranking rule, not a calibrated quality estimator.
5. Apply the production normalizer to finalists and choose the highest-ranked nonempty result. Preserve the confidence threshold, stop policy, six-free-token budget and four-word output ceiling.

The logical context budget remains 2,048 tokens per branch. Native unified KV capacity is 4,096 / 8,192 tokens, with 5 / 9 sequence IDs for prompt, active and temporary references. The current decoder retains its original 2,048-token, single-sequence configuration and sampling path. The normal engine selector and saved preferences still choose it. Hybrid/recurrent models are rejected by this experiment until their native state-copy semantics have equivalent validation.

Width is a maximum number of token paths, not a guarantee of distinct visible suggestions. Width 2 reached two active paths on 440/600 checkpoints. Width 4 reached four on 322/600; it reached one, two or three on the remaining 155, 86 and 37. Duplicate nonempty normalized finalists occurred on 122 width-2 and 212 width-4 checkpoints. No diversity penalty or visible-text deduplication was added after observing results.

## Examples and interpretation

These are illustrative changes, not a separately scored human evaluation. Complete prompts and all outputs are in the raw archive.

| Typed suffix | Current suggestion | Both wider decoders | Interpretation |
|---|---|---|---|
| `Let's keep in ` | `mind that the "Nora"` | `touch!` | A reference gain and a cleaner continuation in this example. |
| `Isotopes have different ` | `numbers of neutrons.` | `number of neutrons but` | A reference loss and a visible grammatical regression. Width 4 retains the correct wording among its finalists. |
| `Please let me know what time works ` | `for you.` | `best for you.` | A reference loss that is still natural writing; exact-match scoring penalizes valid alternatives. |

Width 4's finalists include 206 possible first-word matches, but the selected suggestion achieves 189. That **17-checkpoint gap** is a diagnostic opportunity for ranking; it is not achieved quality. Duplicate finalist text also spends search capacity without adding visible alternatives. These observations justify testing a revised ranking/diversity rule on a separate development set before another frozen evaluation, rather than enabling this implementation by default.

## Frozen setup and scope

- Hardware: Apple M4 Max, 48 GiB, macOS 27.0.1, AC power. No thermal/performance warning was recorded at the start. Ordinary desktop background activity was not disabled; the benchmark processes ran serially.
- Model: `gemma-4-E2B.i1-Q6_K.gguf`, SHA-256 `20f49b221691c71d955e1d5a840b6e26329db4a5e1626f702fa4226e80a9c629`; all 36 layers offloaded to Metal.
- Runtime: pinned llama.cpp `b11474`; receipt and content-manifest hash retained. Same Release executable for all modes, SHA-256 `90c72d243852b7f448f26325b29134dd35471d4d46d10d5aafe9910f986839e8`.
- Source base: `32381e9f8e8137c95d1b94984549a62cdb004aab` plus the experiment saved in `implementation.patch` in the archive. The runner verified unchanged app and cotyping-source hashes at completion.
- Production settings: temperature 0.1, top-k 20, top-p 0.7, min-p 0.08, repeat penalty 1.05 over 64 tokens, seed `0x00C0FFEE`, confidence threshold 0.1 at word boundaries and disabled for midword completion. Only decoder width changes.
- Dataset: eight public phrases from each of seven categories, selected from the existing held-out partition; 32 original challenge phrases covering email, formatting, multilingual and long-context text; two fixed internal checkpoints per selected public phrase. Total 88 phrases and 600 checkpoints. This reuses an existing synthetic evaluation corpus, not a newly collected blind user sample.
- No future words, category labels, screen context or saved memory enter inference. Only already-typed prefixes and synthetic surface metadata are provided. All 600 rendered prompts match exactly across all nine runs.
- No live UI latency, real-user acceptance, semantic-equivalence score, sustained typing/cancellation workload, energy use or competitor runtime comparison was measured. This result is specific to the fixed model, corpus, policy and hardware.

## Validation and reproduction

The Release build and repository-wide strict SwiftLint passed. Focused non-UI XCTest ran 28 tests: **26 passed, 2 skipped, 0 failed**. The two skips are older engine tests requiring a separate compact fallback model that is absent. The new native test ran against the actual Gemma model at both widths. It checked batched candidate log probabilities after warm prompt reuse against independent cold token-path replays, including Serbian and prompts over 512 tokens, within a 0.015 tolerance; it also checked cancellation before generation and successful recovery. All **27 Python replay/benchmark tests passed**. See [validation.json](validation.json).

No local UI tests ran. The experiment was built and benchmarked, **not installed or released**.

Follow the command and algorithm notes in [the benchmark README](../../README.md). The nine runs use isolated temporary home, storage and defaults locations. `candidate_benchmark.py` rejects errors, incomplete/reordered observations, changed prompts, wrong widths, missing native-search diagnostics and app/source changes during the run.

Evidence:

- [summary.json](summary.json): all nine runs, groups and paired quality intervals.
- [analysis.json](analysis.json): pooled/matched latency, memory and branch diagnostics; `analyze.py` in the raw archive reproduces it.
- [manifest.json](manifest.json): executable/model/source/corpus/script hashes and run order.
- [raw-runs.tar.gz (archive)](../2026-10-10-experiments.tar.gz): exact inputs, references, observations, native stderr, per-run reports, implementation patch, analysis script and validation logs.
- [archive-manifest.json](archive-manifest.json): raw archive hash and contents.
- [ATTRIBUTION.md](ATTRIBUTION.md) and [COTABBY-LICENSE.txt (archive)](../2026-10-10-experiments.tar.gz): public synthetic corpus provenance and license.
