Historical experiment snapshot. Current adoption: **E2B remains the default; the experimental switch enables hybrid plus prefix search.** See [the trial guide](../../../../Docs/experimental-autocomplete-hybrid.md). Complete raw evidence and the original, unedited report are in [the experiment archive](../2026-10-10-experiments.tar.gz). Archive member paths are listed in [the manifest](../2026-10-10-experiments-manifest.json).

# Ranking audit and exact-prefix cache experiment — 2026-10-10

Implemented the next experiment on **origin/master `193460c3def4e11aa44dc95e28bef8724c783e80`**, including PRs [#228](https://github.com/stevyhacker/lokalbot/pull/228) and [#229](https://github.com/stevyhacker/lokalbot/pull/229). The model, production prompts and decoding settings remain fixed.

**Keep the original decoder and leave the logit cache disabled.** The corrected cache preserves every selected suggestion and suppression result, and improves average latency on the synthetic dynamic traces. It fails the predeclared held-out p95 gate: **116.90 → 139.08 ms**. The two/four-candidate quality result is unchanged. No new ranking or confidence threshold was fitted.

## What changed

The headless replay can opt into a memory-only LRU cache of full raw next-token logits keyed by exact token prefixes and an explicit scope. A hit skips native decoding, then runs the existing sampler, healing, stop and confidence logic. A miss reconciles the physical native KV history, which may lag the logical prefix after hits; failed native partial reuse falls back to a full prefill. The implementation retains one native history, not multiple native KV checkpoints.

The cache is limited to 16 rows and 32 MiB of token/logit payload, with a 30-second reuse lifetime. Hits do not extend that lifetime. Expiration is checked on access; there is no background timer promising erasure at 30 seconds. Scope changes, unknown scope, explicit clear, cancellation, memory pressure and unload clear the experimental retained state. This conservative implementation also clears native KV on scope changes, a cost the control does not pay. The normal app selector still constructs the uncached sampled runtime. Cache-plus-beam, hosted engines and recurrent/hybrid models are rejected.

The offline audit records raw sequence scores, token/healing counts, finalist diversity, fixed confidence bins and oracle headroom. It reads saved observations and never supplies reference answers to inference. Reproduction instructions are in [README](../2026-10-10-experiments.tar.gz).

## Final quality and latency

The corrected run completed **12,184 requests**: 600 quality checkpoints × four modes × four counterbalanced rounds, plus 323 dynamic steps × two modes × four alternating rounds. There were **zero unexpected errors or retries**. The initial run is archived separately; its timing is not pooled into this result.

| Quality metric | Current | Cached current | 2 candidates | 4 candidates |
|---|---:|---:|---:|---:|
| First-word matches / 600 | 187 | 187 | 189 | 189 |
| First-word agreement | 31.17% | 31.17% | 31.50% | 31.50% |
| Two consecutive reference words | 11.99% | 11.99% | 11.38% | 11.99% |
| Three consecutive reference words | 4.92% | 4.92% | 4.15% | 3.89% |
| Suggestions shown | 324 | 324 | 338 | 345 |
| Agreement when shown | 57.72% | 57.72% | 55.92% | 54.78% |
| Any finalist matches, diagnostic ceiling | 187 | 187 | 194 | 206 |

All four repetitions give the same text and suppression for each quality checkpoint. The cache matches the control across **2,400 paired quality observations**. The original, two-candidate and four-candidate outputs and all rendered prompts also match the [previous updated-master experiment](../2026-10-10-candidates-master/REPORT.md) exactly. The small candidate gains therefore retain the earlier uncertainty: +0.33 percentage points, with phrase-clustered intervals spanning zero. Repeated runs are not new independent quality examples.

The two/three-word denominators are 492/386. Exact reference agreement penalizes valid alternative wording and does not measure human acceptance. Suppression remains in the quality denominator.

| Warm engine latency, ms | Current | Cached current | 2 candidates | 4 candidates |
|---|---:|---:|---:|---:|
| Mean | 41.76 | 41.48 | 58.91 | 67.22 |
| Median | 28.62 | 23.01 | 72.99 | 91.30 |
| p95 | 83.93 | 101.09 | 100.48 | 113.97 |

Latency pools 2,400 requests per mode. It measures tokenization, prefill, generation and normalization after warmup; it excludes model load, request construction, inter-request pauses, keyboard debounce, accessibility and overlay presentation. Confidence rejections are included. These are not first-partial-display or end-to-end UI measurements.

## Sequential typing and cancellation

The dynamic fixture contains 16 original synthetic traces: four development and twelve held out before the first run. Each trace includes forward typing, backspace, branching, retyping, repeats, scope changes, explicit clear, unknown scope, a real cold-prefill cancellation and recovery. It serializes requests with 0/8/20 ms pauses and 2 ms cancellation deadlines. The development and held-out phrases include English, Serbian Latin/Cyrillic, French, punctuation and longer context. Production prompt clipping still applies; separate native tests cover prompts beyond 512 tokens.

After the cleanup fix, all **1,228 noncancelled dynamic pairs** match in text, suppression and prompt, including **920 pairs from held-out traces**. All 128 intentional cancellations occurred, published no text, and the cache retained no entries after cancellation. Bounds and invalidation checks passed. The repeated dynamic traces also show no output variation within either mode.

| Held-out dynamic latency, ms | Current | Cached current |
|---|---:|---:|
| Mean | 85.70 | 72.34 |
| Median | 82.50 | 79.16 |
| p95 | 116.90 | 139.08 |
| p99 | 240.72 | 268.49 |

Mean improvement is **13.36 ms**, with a paired whole-trace bootstrap 95% interval of **7.56–19.01 ms** (3,000 resamples over twelve traces, grouping repetitions). The p95 regression is **18.97%**. This is a small stress fixture, not a frequency-weighted sample of real user activity; its held-out portion has now been observed and used for a correctness repair, so it is not a fresh blind confirmation set.

The action breakdown below pools all sixteen traces and four rounds. Counts are observations, not independent phrases.

| Action | Count | Current mean | Cache mean | Current p95 | Cache p95 |
|---|---:|---:|---:|---:|---:|
| forward | 524 | 76.57 | 53.22 | 100.51 | 95.37 |
| backspace | 128 | 72.88 | 67.50 | 102.62 | 110.92 |
| branch | 64 | 76.68 | 80.42 | 96.40 | 110.99 |
| retype | 64 | 86.12 | 56.93 | 108.50 | 111.02 |
| recover | 64 | 87.02 | 44.76 | 106.67 | 103.21 |
| repeat | 64 | 86.04 | 11.92 | 105.00 | 13.51 |
| scope-change | 64 | 86.68 | 138.87 | 106.06 | 267.97 |
| unscoped | 64 | 87.78 | 137.89 | 109.77 | 267.49 |
| clear | 64 | 124.13 | 136.83 | 249.60 | 268.49 |
| start | 64 | 75.27 | 81.25 | 228.24 | 244.94 |
| recover-after-cancel | 64 | 148.79 | 141.36 | 306.56 | 262.72 |

Forward typing improves. The largest tail penalty comes from the experimental policy of clearing native KV on scope changes and unknown scope. These are **cache plus invalidation-policy** costs; this comparison does not isolate the cost of memoization alone. Exact repeats improve most, but the production coordinator's existing completed-suggestion cache can already restore valid tails before invoking the engine. It also covers some backspace and typing-through paths when field identity and the request fingerprint still match. Therefore even the continuing-edit subset below is not an estimate of incremental UI benefit.

As descriptive post-run subsets, excluding exact repeats leaves held-out mean **85.67 → 75.68 ms** and p95 **118.22 → 140.92 ms**. Continuing edits only (forward/backspace/branch/retype/recover) give mean **79.20 → 57.47 ms** and p95 **104.23 → 108.37 ms**. These subsets do not replace the predeclared overall gate.

Cancellation-to-request-completion p95 is **1.74 ms** for the control and **91.00 ms** for the corrected cache. This starts when cancellation is issued, excludes the configured delay, and waits for the request to finish; the cache additionally joins backend work before clearing buffers. The manifest calls this task quiescence; the control does not explicitly synchronize its GPU here, so this is not a comparable measurement of backend completion.

Including cancelled steps in the held-out request pool gives mean **81.66 → 69.64 ms** and p95 **114.24 → 137.99 ms**. Summing each cancellation request and its immediately following recovery gives paired mean **149.71 → 156.01 ms**, p95 **265.99 → 299.75 ms**, over 48 held-out pairs. These sums exclude the programmed between-request pause; they help distinguish work shifted into cancellation cleanup from work avoided.

Across the dynamic runs the cache recorded 3,680 hits and 6,652 misses, with at most 16 retained rows / 16.03 MiB payload. Submitted native tokens were 43,252 for the control and 50,660 for the cache, including tokens submitted to aborted batches. Scope-triggered cold prefills explain most of the extra submitted work. These counts are not completed GPU operations or energy measurements.

| Quality process peak RSS range | GiB |
|---|---:|
| sampled | 3.8842–3.8849 |
| cache | 3.9138–3.9185 |
| beam2 | 3.9227–3.9242 |
| beam4 | 3.9956–3.9978 |

The payload limit excludes sampler scratch, transient allocations, native KV and model weights. RSS is whole-process memory and does not isolate GPU memory.

## Ranking and confidence audit

The four-candidate decoder chooses 189 first-word reference matches. At least one finalist matches at 206 checkpoints, leaving 17 missed selections. Uniform random selection among nonempty finalists, including duplicates, would yield **189.08 expected matches**. This is diagnostic headroom, not an achievable reference-aware ranker. At 212 checkpoints finalists include exact duplicate nonempty normalized text; simply removing duplicates changes **zero** first choices. Two-candidate search has only five missed selections (194 oracle versus 189 selected).

Score-margin bins are not consistently ordered by reference agreement, and several missed selections are valid alternative wording. Longer suggestions and token/healing counts are recorded for inspection, but no length penalty, diversity heuristic or threshold was chosen from these results. A ranking improvement needs separate development and fresh confirmation data.

The current decoder's observed raw first-word gate bins are:

| Raw gate value | Checkpoints | Displayed first-word reference agreement |
|---|---:|---:|
| 0.1-0.25 | 126 | 41.27% |
| 0.25-0.5 | 64 | 68.75% |
| 0.5+ | 22 | 86.36% |
| below-0.1 | 276 | 0.00% |

These are **not calibrated acceptance probabilities**. Values below 0.1 already suppress output, so zero displayed matches in that bin cannot reveal how often the hidden continuation would have been useful. Midword suggestions bypass this gate. Candidate arrays retain their raw diagnostics, while this table uses the sampled decoder's actual gate; pruned alternatives cannot be recovered from the saved traces.

## Correctness repair during evaluation

The initial frozen run found three cache-only output/suppression mismatches immediately after cancellation, while its 2,400 static quality pairs matched. Its source and all observations remain in the archive under `initial/` and `initial-source/`.

The new cache cleared native data buffers while backend work could still be outstanding after an aborted decode. Cleanup now calls `llama_synchronize` before zeroing those buffers. The pinned API documents the synchronization boundary, and its [KV clearing implementation](https://github.com/ggml-org/llama.cpp/blob/b11474/src/llama-kv-cache.cpp#L352-L363) directly clears backing buffers. The fix is limited to the new cache/explicit replay-clear path. A 96-cycle native regression varies cancellation timing and verifies the next suggestion against cold output. It passed, and the entire four-round comparison was rerun with the corrected Release binary. The initial observations are evidence of the bug, not valid final latency or parity results.

## Frozen setup and validation

- Apple M4 Max, 48 GiB, macOS 27.0.1, AC power; inference runs serially. Normal desktop background activity was not disabled.
- Model: `gemma-4-E2B.i1-Q6_K.gguf`, SHA-256 `20f49b221691c71d955e1d5a840b6e26329db4a5e1626f702fa4226e80a9c629`. Pinned runtime: llama.cpp `b11474`, full GPU offload.
- Final Release executable SHA-256: `da3d792cef84157618e28f2a2a5de0723629b05c722242d4fd36f524a721f3ef`. The runner verified app, runtime/model identity, source and prompt hashes. All 600 quality prompts match the earlier experiment.
- Fixed sampler: temperature 0.1, top-k 20, top-p 0.7, min-p 0.08, repeat penalty 1.05, seed `0x00C0FFEE`, six free tokens and four output words; existing healing, confidence and normalization retained.
- The 600 quality checkpoints reuse the existing synthetic public/challenge set. Dynamic traces are original synthetic data. References and scope/control labels never enter the prompt. No personal writing, saved memory, live screen capture or hosted inference was used.
- Release build, whole-repository strict SwiftLint and **41 Python tests passed**. Across the non-UI Swift selection and focused model reruns: **200 unique tests, 192 passed, 8 skipped, zero failures**. The eight skips require a separate compact fallback model that is absent; the actual Gemma cache/candidate tests ran. The final 14 native-focused tests passed, including the 96-cycle regression.
- No local UI tests ran. This work was built and benchmarked; it was **not installed, committed, pushed or released**. Enabling the cache in the coordinator would still require real focus/privacy lifecycle integration and hosted UI validation.

The next useful cache experiment would compare invalidation policies under the same lifecycle constraints and measure incremental value after the existing suggestion cache. The current evidence supports keeping both candidate search and logit reuse opt-in.

Evidence: [manifest](manifest.json), [summary](summary.json), [analysis](analysis.json), [validation](validation.json), [source/base integration](integration.json), [sampled confidence audit](ranking-audit-sampled.json), [four-candidate audit](ranking-audit-beam4.json), [raw archive (archive)](../2026-10-10-experiments.tar.gz), [archive checksums](archive-manifest.json), [corpus attribution](ATTRIBUTION.md) and [license (archive)](../2026-10-10-experiments.tar.gz).
