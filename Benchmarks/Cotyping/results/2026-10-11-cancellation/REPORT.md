**Cancellation experiment — 11 October 2026**

**Keep the current default.** Fourteen alternatives were screened with Gemma 4 E2B Q6_K and the prompt fixed. The selected cancellation candidate was tested on untouched English and Serbian Latin cases. It reduced mean cancellation return from 36.9 to 34.1 ms and time through the replacement from 188.2 to 175.4 ms, but made normal long-text generation 14.7% slower. That violates the user's no-regression condition. No candidate was adopted or installed.

The current app still uses the unconditional selective hybrid, certified search, two generation/two prefill threads and 256-token prefill chunks. Its executable and E2B hashes were checked again after the experiment. [Unchanged app receipt](unchanged-app-receipt.json).

**Untouched confirmation**

The selected `early192sync` policy preserves the existing path for at most 256 new prefill tokens. For larger prefills it decodes 192 tokens, synchronizes, then decodes the remainder in chunks of up to 2048. Only the final chunk requests logits. Model, prompt, sampler, search width/budget, spelling policy and confidence gates remain fixed.

Two counterbalanced rounds completed, AB then BA. Four were planned for acceptance. A rejection-only rule, recorded before opening the confirmation data, allowed stopping after two if a normal-generation regression was clear or output parity failed. The long-text interval was entirely above zero, so the study stopped to reject the candidate. There was no early-acceptance rule. The selected candidate is a tradeoff finalist, not a winner.

All timings below are milliseconds; negative deltas favor the experiment. Parentheses contain the paired 95% interval for the **mean delta**, not for p95.

| Normal workload | Default mean / p95 | Candidate mean / p95 | Mean delta (95% interval) |
|---|---:|---:|---:|
| Fresh English + Serbian Latin | 59.5 / 112.2 | 61.3 / 115.0 | +1.8 (+1.0 to +2.7) |
| Long text, cold/prewarm mix | 148.6 / 241.7 | 170.4 / 267.3 | +21.8 (+19.7 to +23.9) |
| Typing, backspace and retype | 55.8 / 107.6 | 57.9 / 110.7 | +2.1 (+1.0 to +3.2) |

| Cancellation workload | Default mean / p95 | Candidate mean / p95 | Mean delta (95% interval) |
|---|---:|---:|---:|
| Cancellation request → cancelled call returns | 36.9 / 92.3 | 34.1 / 78.0 | -2.8 (-4.6 to -0.9) |
| Cancellation request → replacement completes | 188.2 / 411.6 | 175.4 / 345.2 | -12.8 (-16.4 to -9.2) |

There are **413 paired delivered cancellations**, grouped into 12 original bilingual scenarios. All their replacement requests displayed a suggestion, so the shown-only replacement timing equals the replacement table. Counts below include events that completed before their timer; those are never credited as fast cancellations.

| Arm | Timers requested | Cancellation issued | Returned cancellation |
|---|---:|---:|---:|
| default | 432 | 413 | 413 |
| candidate | 432 | 417 | 417 |

| Requested interruption delay | Default mean / p95 through replacement | Candidate mean / p95 | Mean delta (95% interval) |
|---|---:|---:|---:|
| 5 ms requested delay | 197.6 / 413.1 | 189.0 / 358.8 | -8.6 (-13.8 to -3.2) |
| 20 ms requested delay | 189.2 / 416.8 | 176.1 / 345.2 | -13.1 (-17.6 to -8.0) |
| 60 ms requested delay | 176.2 / 373.7 | 159.0 / 281.0 | -17.2 (-23.7 to -10.1) |

Per-language normal-generation means:

| Workload | Language | Default ms | Candidate ms |
|---|---|---:|---:|
| fresh | en | 52.9 | 54.1 |
| fresh | sr_latn | 66.1 | 68.6 |
| long | en | 120.3 | 139.9 |
| long | sr_latn | 176.9 | 200.9 |
| dynamic | en | 45.8 | 47.2 |
| dynamic | sr_latn | 65.8 | 68.6 |

**Quality and recovery**

All **1,632/1,632** paired normal, replacement and cold-reference observations match exactly: raw prompt, returned suggestion, suppression, error and cancellation fields. Every replacement also matches its independent cold reference: **432/432 per arm**. Repeated rounds/checkpoints are included; these are not that many independent writing examples. Attempted-cancellation rows are excluded from output parity because one arm may finish before its timer.

| Workload | Language | Suggestions shown / observations, identical in both arms |
|---|---|---:|
| fresh | en | 112 / 144 |
| fresh | sr_latn | 102 / 144 |
| long | en | 96 / 96 |
| long | sr_latn | 96 / 96 |
| dynamic | en | 136 / 144 |
| dynamic | sr_latn | 134 / 144 |
| cancellation | en | 432 / 432 |
| cancellation | sr_latn | 432 / 432 |

All fourteen screening arms also had zero suggestion/prompt differences and zero recovery differences. This establishes output parity on the tested fixtures, not an improvement in subjective writing quality. No new quality-judge claim is made for identical outputs.

**Screening all fourteen alternatives**

These are mean deltas against each phase's opening same-binary default, in milliseconds. The two cohorts have different binaries and cancellation-delay coverage; do not pool their timings. Screening was one pass per alternative, with default controls before/after; small changes are exploratory and subject to drift. The independent confirmation above controls run order for the selected candidate.

| Cohort | Arm | Fresh delta | Long-text delta | Cancellation-return delta | Through-replacement delta |
|---|---|---:|---:|---:|---:|
| fixed | `sync128` | +2.50 | +9.88 | -20.98 | -15.94 |
| fixed | `last128` | +3.28 | +8.02 | -20.69 | +16.30 |
| fixed | `chunk64` | +2.93 | +34.90 | -37.12 | +46.97 |
| fixed | `sync64` | +3.26 | +33.42 | -37.92 | +12.34 |
| fixed | `last256` | +3.14 | +4.09 | +0.96 | +1.41 |
| fixed | `chunk128` | +2.45 | +9.57 | -21.67 | +15.16 |
| fixed | `batch14` | +2.92 | +3.33 | +0.69 | +7.58 |
| fixed | `last64` | +2.67 | +32.32 | -38.39 | +40.36 |
| adaptive | `early192sync` | +0.71 | +11.24 | -10.62 | -31.89 |
| adaptive | `early64sync` | +0.93 | +33.04 | -10.05 | -43.06 |
| adaptive | `batch4` | +0.87 | +0.67 | -0.41 | +0.05 |
| adaptive | `early128` | +0.37 | +21.13 | -6.47 | -15.22 |
| adaptive | `batch8` | +1.02 | +0.63 | -0.03 | +0.35 |
| adaptive | `early128sync` | -0.36 | +20.82 | -4.02 | -36.52 |

`batch4/8/14` changes only the prefill CPU thread count; generation stays at two. `chunk64/128` reduces the fixed chunk size while keeping the previous logits behavior. `last64/128/256` requests logits only on the final prefill chunk. `sync64/128` additionally synchronizes at intermediate boundaries. `early64/128/192` changes only prefills longer than 256 tokens to a small first chunk and large remainder; `sync` marks the explicit intermediate synchronization. All retain the existing cancellation checks, abort callback and cleanup.

Smaller fixed chunks can make the cancelled call return sooner while **delaying the replacement**. The synchronized 128-token variant and adaptive variants improve the replacement interval but slow ordinary long-text generation. Four/eight/fourteen prefill threads did not provide a convincing cancellation improvement in this fresh study. None cleared the combined guard. The earlier small-sample thread result remains historical evidence, not an adoption reason.

**Protocol and limits**

- Same M4 Max; serial native replays, with no concurrent model test/build work. Each process loads/prewarms the model and excludes eight warmups. The regular app stays installed; this is a headless native benchmark.
- Thirty-two new synthetic bilingual sentence pairs: eight for screening and twenty-four untouched for confirmation. Fresh/long confirmation uses all twenty-four pairs; dynamic/cancellation uses the first twelve of those pairs. Midword and word-boundary checkpoints, long fields, explicit prewarm, typing/backspace/retype and immediate post-cancellation recovery are represented. Serbian Cyrillic is excluded.
- E2B model SHA-256 `20f49b221691c71d955e1d5a840b6e26329db4a5e1626f702fa4226e80a9c629`; native llama b11474 stays pinned. Six-token/four-word budget, temperature 0.1, repeat penalty 1.05, fixed sampler seed, width four/32 expansions, gates 0.1/0.31 and native spelling verdicts are fixed. Exact observed prompts are compared, not just input prefixes.
- The first cohort requests interruption at 5/20 ms; the adaptive cohort adds 60 ms before confirmation. Measurements use the **actual issuance time**. Normal generation excludes fixture reset, spelling/request preparation and model load. Cancellation-through-replacement includes cleanup, intervening replay output and replacement preparation. It is a serialized cancellation followed by a replacement, not a concurrently queued newest request.
- Five thousand paired bootstrap draws cluster all languages, prefix positions, delays and repeated rounds by original bilingual scenario. This preserves dependence. The intervals describe scenario variation within these runs; they do not include variation between sessions or machines. P95 is an empirical pooled percentile. Neither confidence intervals nor sample counts justify a population-wide human typing claim.
- Acceptance required exact parity/recovery, no worse normal mean/p95 and per-language means, an upper 95% mean-delta bound at or below zero for every normal workload, and better cancellation return **and** replacement completion with no worse p95 and at least 100 paired delivered cancellations. Inconclusive results retain the default. These gates were not relaxed after observing results.
- First-visible overlay latency, debounce/accessibility, GPU-idle time, overlapping requests and other hardware were not measured. The pinned native header describes the abort callback as CPU-only; this is not a traced explanation of Metal behavior. No backend/dependency update was attempted.

| Cohort | Phase | Processes | Measured rows | Excluded warmups |
|---|---|---:|---:|---:|
| fixed | screen | 31 | 1808 | 248 |
| adaptive | screen | 31 | 2288 | 248 |
| adaptive | confirmation | 16 | 4128 | 128 |

**Claude advice and next step**

Claude Opus 5.5 answered a generic question about two-stage prefill, final-only logits and cancellation measurement, with tools/MCP disabled. No project details, source, model identity or benchmark measurements were supplied. The original request containing implementation details and aggregate results was blocked by automatic approval review and never sent. The generic advice is archived with its request/response hashes. It is advisory, not a review of these results or a quality judgment. Its suggestion to tolerate throughput loss was not used: the user's no-regression condition remained decisive.

The next useful experiment is a trace of cancellation issuance, native completion, cache cleanup and a concurrently queued replacement. It should identify whether obsolete queued work or rebuilding state dominates the real typing delay before changing scheduling or cache behavior. This is a hypothesis to investigate; the current study does not prove either bottleneck. Avoid another global reduction in chunk size given the measured normal-speed cost. Preserve E2B and the prompt, and reuse the same output/speed guards.

[Validation and reproduction](VALIDATION.md) · [Machine-readable results](summary.json) · [Decision](decision.json) · [Complete evidence archive](evidence.tar.gz) · [SHA-256 manifest](evidence-manifest.json)
