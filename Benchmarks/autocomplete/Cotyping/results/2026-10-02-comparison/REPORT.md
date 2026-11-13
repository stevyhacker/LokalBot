# Cotyping comparison and performance experiment — 2026-10-02

This records the initial latency investigation. The subsequent
[quality report](../2026-10-02-quality/REPORT.md) contains the completed
quality changes, held-out evaluation and direct matched Cotabby run.

LokalBot's current local engine is already fast once loaded. On this M4 Max,
the measured warm median is **35 ms**, with **53 ms p95** before the change.
The candidate token-ranking optimization preserves every output, but changes
the full warm engine mean by only **1.2%**. This is too small to establish a
material product speedup. A model replacement or a more aggressive debounce
is not supported by this experiment.

The larger opportunities are cold readiness, reusing hybrid-model prompt state,
completion relevance, and the path from a keystroke to the displayed suggestion.
Those need separate measurements before adoption.

## Comparison evidence

| Area | LokalBot today | Cotabby upstream | Cotypist |
| --- | --- | --- | --- |
| Local inference | LFM2.5 1.2B Instruct, in-process llama.cpp; local server fallback | In-process native runtime; base-model catalog; additional Apple/endpoint engines | Vendor documents local Gemma inference; internal implementation and latency percentiles are not public in the reviewed material |
| Repeated typing | Partial KV reuse for attention models; hybrid/recurrent models fully prefill again | Bounded native state checkpoint supports hybrid/recurrent/sliding-window restoration, with at most eight replayed tokens | Documents suggestions updating after each keystroke; no comparable cache benchmark |
| Generation delay | 20/25/55 ms adaptive local tiers after the first timing sample | 15/25/55 ms local tiers | Undocumented |
| Active-field context | 2,500 characters / 150 words; 2,048-token runtime context | 14,000 characters / 2,400 words, token-budgeted within 4,096 context tokens | Documents per-app/domain instructions and optional personalization; internal budgets undocumented |
| Acceptance and streaming | Word acceptance, type-through, token healing, coalesced monotonic streaming; streaming off by default | Word acceptance, token healing, coalesced streaming, typing-cadence presentation controls; streaming off by default | Emphasizes the next word or two, word-by-word Tab, and correcting a suggestion by typing another letter |
| Quality evidence | 28 synthetic safety/word-completion scenarios; keyword hits are only a weak relevance proxy | Published 1,337-phrase corpus with 7,437 next-word checkpoints per context condition | Product documentation and demos; no matched public corpus found in reviewed sources |

Cotabby source was pinned to
[`7724926b3e93f14e3b576ba46ff52c4f64d9712d`](https://github.com/FuJacob/cotabby/tree/7724926b3e93f14e3b576ba46ff52c4f64d9712d).
See its [runtime architecture](https://github.com/FuJacob/cotabby/blob/7724926b3e93f14e3b576ba46ff52c4f64d9712d/ARCHITECTURE.md),
[debounce policy](https://github.com/FuJacob/cotabby/blob/7724926b3e93f14e3b576ba46ff52c4f64d9712d/Cotabby/Support/Suggestion/Request/DebouncePolicy.swift),
and [typing cadence](https://github.com/FuJacob/cotabby/blob/7724926b3e93f14e3b576ba46ff52c4f64d9712d/Cotabby/Support/Suggestion/Streaming/TypingCadence.swift).
This is an upstream source comparison; installed Cotabby is 0.6.2-beta.

Cotabby's [published quality run](https://github.com/FuJacob/cotabby/blob/7724926b3e93f14e3b576ba46ff52c4f64d9712d/benchmarks/phrase-prediction/1337-full-20260925/summary.txt)
reports 37.50% exact next-word accuracy with screen context and 31.01% without
it, using Qwen3.5 0.8B Base. Those scores **cannot be compared numerically** with
LokalBot's small safety suite: corpus, model, context, and scoring differ.

Cotypist's [usage guide](https://cotypist.app/help/tips),
[personalization documentation](https://cotypist.app/help/personalization), and
[press kit](https://cotypist.app/press) establish its documented behavior.
Installed Cotypist is 2026.4. Neither competitor was driven through its UI on
this Mac. Repository rules require a remote runner for UI tests. The older
LokalBot side-by-side report contains **0/0 actual captures** and cannot establish
relative latency or quality. There is no substantiated three-product speed ranking.

## What was measured

- Apple M4 Max, 48 GiB; optimized **Release** builds; pinned llama.cpp **v0.5.0**.
- Source baseline `530bcc2cc1c28c28adf6db3899ab14d5d615fd46`, plus the same headless
  benchmark isolation change on both sides. Other work was preserved.
- Identical LFM2.5 1.2B GGUF, seed, 3-word setting, app-context fixtures, and
  28-scenario suite. Learning and clipboard disabled; streaming timing enabled.
- Four fresh-process runs per variant. Exact executable/model SHA-256 values and
  settings are recorded in [before/manifest.json](before/manifest.json) and
  [after/manifest.json](after/manifest.json).
- Warm statistics use runs 2–4 and omit each process's first request. The first
  full run is retained in the raw data but excluded for Metal compilation.
  Percentiles use nearest rank. The second request is retained, including its
  roughly 200 ms latency. There is no selective removal of slower warm cases.
- This boundary includes model generation and normalization. It excludes input
  monitoring, debounce, host text publication, AX validation, and overlay display.
  “First partial” means the first non-empty normalized engine callback.
- Runs were sequential before/after, not a randomized crossover. Sub-millisecond
  differences are small enough to be run noise; no statistical significance claim.

| Warm measurement | Before | Candidate |
| --- | ---: | ---: |
| Completion mean, 81 requests | 42.19 ms | 41.69 ms |
| Completion median | 35 ms | 35 ms |
| Completion p95 | 53 ms | 52 ms |
| First normalized partial mean, 78 visible results | 33.27 ms | 32.59 ms |
| First normalized partial p95 | 39 ms | 37 ms |
| Eligible mid-word completion mean, 36 requests | 35.78 ms | 34.92 ms |
| Safety cases per run | 28/28 | 28/28 |
| Word-completion cases per run | 12/13 | 12/13 |

All text and suppression decisions match across all eight runs. The thirteenth
word-completion case intentionally suppresses insertion strictly inside an
existing word. This confirms behavior preservation on the suite, not general
semantic accuracy or multilingual parity. Keyword hits remain 15/64.

The first request in subsequent fresh processes still takes **about 9.4 seconds**
on both sides. Model admission/loading, runtime setup, and priming are inside that
number. The initial Metal-compilation run can be slower. The app already requests
prewarm on enable/launch and supported-field focus; these cold harness numbers do
not prove a user waits nine seconds during ordinary typing. Readiness should be
measured explicitly during enable, reload, and memory-pressure recovery.

Raw cases and the aggregation are in [summary.json](summary.json), [before](before),
and [after](after).

## Candidate change and its limits

Token healing previously copied the logits and repeatedly scanned the full
vocabulary to find up to 64 candidates. The candidate uses a bounded heap:
O(V log 64) work, O(64) temporary storage, and the same token ordering, lower-ID
tie break, NaN/infinity handling, scan cutoff, and fallback behavior.

The optimized component benchmark uses the **exact original Int32 argmax**.
An initial exploratory version used an Int index and overstated the baseline
because Swift optimized the two representations differently; its timings are
not the results below.

| CPU selection workload, median | Original | Candidate |
| --- | ---: | ---: |
| 65,536-token vocabulary, match at rank 64 | 1.084 ms | 0.068 ms |
| 262,144-token vocabulary, match at rank 64 | 4.271 ms | 0.233 ms |
| 65,536-token vocabulary, match at rank 1 | 0.021 ms | 0.058 ms |

Worst-case ranking is about **16–18× faster**, while the first-candidate case
pays about 0.04 ms extra because the heap selects all candidates up front. This
is a small CPU optimization, not a 16× autocomplete speedup. See
[token-ranking.json](token-ranking.json). The optional 4× worst-case performance
gate fails when the original repeated-argmax implementation is restored behind
the benchmark seam; its failed control is retained in
[token-ranking-reverted.json](token-ranking-reverted.json).

The headless benchmark also now calls the engine runner directly instead of
initializing the live coordinator's encrypted learning store. The previous path
blocked in `SecItemCopyMatching` even with learning disabled; the fixed command
completed all eight runs without that dependency. Benchmark settings are imported
through cfprefsd into a unique temporary suite, and a missing streaming-timing
field rejects runs whose settings were not actually applied.

## Where a considerable improvement could come from

1. **Measure the complete interaction remotely.** Record key event, host text
   publication, request start, first valid completion, first render, and acceptance
   confirmation in TextEdit, Mail, and a browser/Electron field. Use the same
   phrases and typing/Tab/backspace traces for all three products. Include cold,
   warm, rapid typing, and repeated Tab. This resolves whether an apparent delay
   comes from the model, AX work, presentation, or insertion. Target at least a
   15% p95 improvement with zero stale or duplicate insertions.
2. **Prototype bounded hybrid prompt checkpoints.** LFM2 is hybrid and currently
   reprocesses each full prompt. Cotabby's native restoration is the clearest
   architectural gap. Test a bounded in-memory checkpoint against identical
   short/long evolving prompts; compare actual decoded tokens, first-partial
   latency, peak memory, cancellation, backspace, model switch, privacy changes,
   and memory-pressure recovery. Require a successful native restoration and
   cold fallback on any mismatch. Do not treat today's logical prefix counter
   as evidence that the model physically reused state.
3. **Broaden relevance evaluation before replacing the model.** Add a held-out
   next-word/partial-word corpus spanning email, chat, documents, technical names,
   and the user's languages, including Serbian. Compare equal context budgets
   and actual accepted-keystroke savings. LokalBot's 150-word prefix ceiling is a
   plausible source of missed context; increase it only after measuring the
   accuracy/latency tradeoff and preserving capture/consent boundaries.
4. **Validate readiness and stable first-word presentation.** Test whether prewarm
   hides model loading through enable and reload, and whether showing a completed
   first word earlier improves acceptance without flicker. Existing streaming and
   short debounce already cover much of the basic mechanism; simply shortening
   the delay another five milliseconds is unlikely to be the main improvement.

## Reproduction and validation

Build the Release executable with `CODE_SIGNING_ALLOWED=NO`, then run from the
repository root, supplying the existing local GGUF path and a new output folder:

```sh
uv run --no-project python Benchmarks/autocomplete/Cotyping/run_in_process_benchmark.py \
  --app .build/XcodeDerivedData/Build/Products/Release/LokalBot.app/Contents/MacOS/LokalBot \
  --model /absolute/path/LFM2.5-1.2B-Instruct-Q4_K_M.gguf \
  --output /private/tmp/cotyping-new-run --repetitions 4

swiftc -O LokalBot/Cotyping/Llama/CotypingTokenCandidates.swift \
  Benchmarks/autocomplete/Cotyping/token-ranking.swift -o /private/tmp/cotyping-token-ranking
/private/tmp/cotyping-token-ranking --check
```

Release builds, the eight real-model runs, strict SwiftLint, and the component
performance gate passed. **67 focused unit/integration tests passed, with no
failures or skips**, covering candidate ranking, token healing/UTF-8, native
generation/cancellation, selector lifecycle/fallback, and benchmark criteria;
see [unit-tests.json](unit-tests.json). The first Xcode attempt stalled in the
test-host dynamic loader before assertions and was stopped. Retrying with
`ENABLE_DEBUG_DYLIB=NO` passed. No test expectations were changed.

UI tests were not run locally. Changes remain uncommitted; nothing was installed
or released. The source comparison and engine experiment are complete, while a
matched competitor UI comparison and the larger cache/quality experiments above
remain unverified.
