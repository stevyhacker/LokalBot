**Experimental autocomplete trial — E2B remains the default**

Keep **Gemma 4 E2B Q6_K** (`gemma4-e2b-base-q6`) as the autocomplete model. This PR does not change the model catalog pin, prompt, sampler, token budget, normalizer or capture/network permissions. The experimental setting stays off for new and upgraded installations unless previously enabled.

In **Settings → Writing → Autocomplete**, **Experimental hybrid suggestions** enables two changes: a selective one-word fallback when the usual confidence gate stays silent, and bounded token-prefix search for words already being typed. Turn it off to restore the previous decoder immediately, including the old midword path. No restart or model download is needed. Switching cancels pending work, hides current suggestions, clears suggestion remainders and rebuilds the local engine. Autocomplete and the fast in-process runtime must be enabled; HTTP fallback retains its previous behavior.

The partial-word search compares up to four compatible token paths by raw summed log probability, retains the previous path as a candidate, and falls back to it at the 32-expansion budget. It preserves typed UTF-8 bytes and uses ordinary sampling afterward. A token already covering the whole typed fragment takes the original fast path. Prewarm and generation retain the same prompt preparation. Recurrent/hybrid model state is not rewound by the experiment.

The hybrid normalizes the complete generation before capping a fallback to one word. At word boundaries it preserves passing current suggestions. **Midword suggestions can change, including occasional regressions.** Experimental streaming publishes the final normalized result, and some suggestions take longer.

The 10 October prefix-search quality evaluation used 288 checkpoints, with exactly 250 suggestions shown by each arm and equal frequency in each language. Model weights and prompt bytes stayed fixed. Claude Opus 5.5 judged anonymous outputs.

| Model | English midword useful /96, before → after | Serbian Latin midword useful /96 | Serbian Latin midword poor /96 | Mean / p95 native ms, before → after |
|---|---:|---:|---:|---:|
| E2B | 71 → 81 | 61 → 74 | 33 → 17 | 55.3 / 88.4 → 71.0 / 145.4 |
| Luchador | 90 → 90 | 55 → 68 | 39 → 25 | 85.5 / 140.0 → 100.4 / 224.2 |

E2B is about 29% faster than fixed Luchador overall. Luchador remains stronger in English; its overall utility advantage is uncertain after matching suggestion frequency. The user chose E2B as the default. Luchador remains an evaluated alternative, not an automatic download or model migration.

These are synthetic model-judge results, not human acceptance or first-visible UI timings. Luchador’s Serbian midword p95 is 251.7 ms. Some word-form and invented-tail errors remain. The reports show failures alongside improvements. Frequency matching used per-language/model quantiles only for evaluation; **app thresholds remain 0.1 and 0.31**.

[Latest report](../Benchmarks/Cotyping/results/2026-10-10-prefix-search/REPORT.md) · [Before/after examples](../Benchmarks/Cotyping/results/2026-10-10-prefix-search/EXAMPLES.md) · [Complete experiment index](../Benchmarks/Cotyping/results/2026-10-10-experiments.md)

The headless `--cotyping-replay <input.json> --model-path <model.gguf>` entry point accepts `selectiveOneWordHybrid`, `healingMode` (`wordBoundary` or `prefixSearch`), primary/fallback thresholds, confidence tracing, healing tracing and production spelling verdicts. Explicit `healingMode` isolates the midword change independently of the hybrid gate. With it omitted, the hybrid flag selects the same combined mode as the app. Keep tracing off for timing. Rejected beam, logit-cache, early-stop and atomic-healing implementations are archived as research source, excluded from the app integration; requesting those modes is rejected.

[Integration validation](../Benchmarks/Cotyping/results/2026-10-10-pr-integration/VALIDATION.md) records the exact build, regression tests, installed-binary parity and signing verification separately from historical prototype benchmarks. UI tests run only on hosted/remote runners; this update leaves the draft PR and CI configuration unchanged.

**11 October latency follow-up**

The replay-only latency experiments keep E2B, prompt, sampler, budgets, width four and production gates fixed. Per-request ranking reuse plus a bounded-search skip proof and two CPU threads reduced fresh native mean/p95 from 67.0/142.4 to 51.6/98.9 ms on the M4 Max, with identical suggestions and frequency. The proof's incremental value is not isolated, and two threads are not established as a universal hardware default. Separate 2/14 generation/prefill threads traded a little normal speed for better cancellation-return measurements.

These controls remain **replay-only**; normal app construction uses `baseline` and existing thread selection. No new reinstall or model migration was performed. Replay accepts `searchExperiment`, `nativeThreads`, `nativeBatchThreads`, plus native-only prewarm/scope/cancellation controls. Exact-only and narrower-prefix ablations lost judged quality; the 32-expansion budget remains unchanged.

[Latency report and next steps](../Benchmarks/Cotyping/results/2026-10-11-latency/REPORT.md) · [Examples](../Benchmarks/Cotyping/results/2026-10-11-latency/EXAMPLES.md) · [Validation](../Benchmarks/Cotyping/results/2026-10-11-latency/VALIDATION.md). The formerly missing Qwen fixture was supplied: the final focused suite passed all 195 tests with no skips. CI remains untouched.
