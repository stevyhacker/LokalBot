**Autocomplete decoder — E2B remains the default**

Native autocomplete now always uses the faster hybrid decoder. **Gemma 4 E2B Q6_K** (`gemma4-e2b-base-q6`) remains the default model. Model weights, prompt, sampler, token budget, normalizer and capture/network permissions are unchanged.

**Settings → Writing → Autocomplete → Enable autocomplete** still controls whether suggestions are enabled. The separate **Experimental hybrid suggestions** toggle and saved preference have been removed. Previously saved true or false values are ignored and omitted when settings are next saved, so an old off value cannot select the legacy decoder. The model selection and other autocomplete settings are preserved. The HTTP fallback retains its existing behavior.

The native app factory always enables selective one-word fallback, bounded prefix search, per-request ranking reuse and the bounded-search skip proof, with two generation and two prefill threads. The former decoder remains available only through explicit headless replay controls for historical comparisons. There is no decoder rollback switch in the app.

The partial-word search compares up to four compatible token paths by raw summed log probability, retains the previous path as a candidate, and falls back to it at the 32-expansion budget. It preserves typed UTF-8 bytes and uses ordinary sampling afterward. A token already covering the whole typed fragment takes the original fast path. Prewarm and generation retain the same prompt preparation. Recurrent/hybrid model state is not rewound by prefix search.

The hybrid normalizes the complete generation before capping a fallback to one word. At word boundaries it preserves passing current suggestions. **Midword suggestions can change, including occasional regressions.** Hybrid streaming publishes the final normalized result, and some suggestions take longer.

The 10 October prefix-search quality evaluation used 288 checkpoints, with exactly 250 suggestions shown by each arm and equal frequency in each language. Model weights and prompt bytes stayed fixed. Claude Opus 5.5 judged anonymous outputs.

| Model | English midword useful /96, before → after | Serbian Latin midword useful /96 | Serbian Latin midword poor /96 | Mean / p95 native ms, before → after |
|---|---:|---:|---:|---:|
| E2B | 71 → 81 | 61 → 74 | 33 → 17 | 55.3 / 88.4 → 71.0 / 145.4 |
| Luchador | 90 → 90 | 55 → 68 | 39 → 25 | 85.5 / 140.0 → 100.4 / 224.2 |

E2B is about 29% faster than fixed Luchador overall. Luchador remains stronger in English; its overall utility advantage is uncertain after matching suggestion frequency. The user chose E2B as the default. Luchador remains an evaluated alternative, not an automatic download or model migration.

These are synthetic model-judge results, not human acceptance or first-visible UI timings. Luchador’s Serbian midword p95 is 251.7 ms. Some word-form and invented-tail errors remain. The reports show failures alongside improvements. Frequency matching used per-language/model quantiles only for evaluation; **app thresholds remain 0.1 and 0.31**.

[Latest report](../Benchmarks/Cotyping/results/2026-10-10-prefix-search/REPORT.md) · [Before/after examples](../Benchmarks/Cotyping/results/2026-10-10-prefix-search/EXAMPLES.md) · [Complete experiment index](../Benchmarks/Cotyping/results/2026-10-10-experiments.md)

The headless `--cotyping-replay <input.json> --model-path <model.gguf>` entry point accepts `selectiveOneWordHybrid`, `healingMode` (`wordBoundary` or `prefixSearch`), primary/fallback thresholds, confidence tracing, healing tracing and production spelling verdicts. Explicit `healingMode` isolates the midword change independently of the hybrid gate. The replay flag is independent of saved app settings and intentionally retains historical baseline defaults. Use `selectiveOneWordHybrid: true`, `searchExperiment: "certified"` and `nativeThreads: 2` to match the current app factory. Keep tracing off for timing. Rejected beam, logit-cache, early-stop and atomic-healing implementations are archived as research source, excluded from the app integration; requesting those modes is rejected.

[Integration validation](../Benchmarks/Cotyping/results/2026-10-10-pr-integration/VALIDATION.md) records the exact build, regression tests, installed-binary parity and signing verification separately from historical prototype benchmarks. UI tests run only on hosted/remote runners; this update leaves the draft PR and CI configuration unchanged.

**11 October latency study and adoption**

The latency experiments kept E2B, prompt, sampler, budgets, width four and production gates fixed. Per-request ranking reuse plus a bounded-search skip proof and two CPU threads reduced fresh native mean/p95 from 67.0/142.4 to 51.6/98.9 ms on the M4 Max, with identical suggestions and frequency. The proof's incremental value is not isolated, and two threads are not established as a universal hardware default. Separate 2/14 generation/prefill threads traded a little normal speed for better cancellation-return measurements.

At the user's request, the app now selects **`certified` search with two generation and two prefill threads** for every native autocomplete engine. This reuses per-request scalar rankings, skips an identical-state restore only with valid logits provenance, and skips a bounded search when its score bound proves it cannot beat the retained path. The replay constructor deliberately keeps its historical baseline defaults; use `searchExperiment: "certified"` and `nativeThreads: 2` to reproduce the app's configuration. E2B and the prompt remain unchanged. Replay accepts `searchExperiment`, `nativeThreads`, `nativeBatchThreads`, plus native-only prewarm/scope/cancellation controls. Exact-only and narrower-prefix ablations lost judged quality; the 32-expansion budget remains unchanged.

[Latency report and next steps](../Benchmarks/Cotyping/results/2026-10-11-latency/REPORT.md) · [Examples](../Benchmarks/Cotyping/results/2026-10-11-latency/EXAMPLES.md) · [Validation](../Benchmarks/Cotyping/results/2026-10-11-latency/VALIDATION.md). The formerly missing Qwen fixture was supplied: the latency study's focused suite passed all 195 tests with no skips. [Default activation and install validation](../Benchmarks/Cotyping/results/2026-10-11-fast-default/VALIDATION.md) records the subsequent production integration separately. CI remains untouched.

The two-thread choice is measured on this M4 Max. Long-prefill cancellation took longer to return in the follow-up (95.6 vs 80.8 ms); first-visible UI latency and other hardware remain unmeasured. The user chose this candidate as the standard decoder and subsequently requested removal of the separate toggle. [Always-enabled integration validation](../Benchmarks/Cotyping/results/2026-10-11-always-hybrid/VALIDATION.md) records that change; earlier toggle and rollback instructions describe historical builds.
