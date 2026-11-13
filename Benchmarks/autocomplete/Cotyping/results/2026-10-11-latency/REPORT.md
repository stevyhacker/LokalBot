**E2B autocomplete latency experiments — 11 October 2026**

The strongest confirmed native-generation result is **per-request ranking reuse + bounded-search skip proof + two CPU threads**. On this M4 Max, mean latency fell **67.0 → 51.6 ms (23.0%)** and p95 **142.4 → 98.9 ms (30.5%)** on fresh English/Serbian Latin text. **All 1,496 paired non-cancelled observations in the primary study matched the current decoder exactly**, including suppression decisions and repeated measurements. This covers 728 distinct request IDs, many deliberately related. The 95% scenario-bootstrap interval for mean reduction is **21.6–24.4%**.

**Keep E2B as the default.** At the end of this study, the installed app was unchanged and the new controls were replay-only. The user subsequently requested activation of the fastest candidate: [default activation and install validation](../2026-10-11-fast-default/VALIDATION.md) records that separate integration. The measurements and frozen source in this report remain the original study; they are not new UI timings or release evidence.

| Workload | Current mean / p95 ms | Candidate mean / p95 ms | Mean reduction |
|---|---:|---:|---:|
| Fresh EN + Serbian Latin | 67.0 / 142.4 | 51.6 / 98.9 | 23.0% |
| Typing, backspace and recovery | 102.9 / 248.3 | 81.4 / 199.7 | 20.9% |
| Long fields, cold/prewarmed mix | 169.0 / 289.6 | 149.3 / 251.7 | 11.6% |
| Unicode, digraphs and code switching | 131.6 / 239.0 | 100.9 / 179.4 | 23.4% |

English mean latency improved **58.5 → 45.7 ms (21.9%)**; Serbian Latin **75.6 → 57.5 ms (23.9%)**. Every fresh arm retaining the same outputs showed **111/144 suggestions**: **61/72 English and 50/72 Serbian Latin**. Production gates stayed at 0.1/0.31. The older matched-frequency development set remained 250/288; do not mix those coverage figures.

Among the 333 nonempty suggestions per primary arm (111 repeated three times), mean native time was **79.9 → 60.6 ms** and p95 **151.7 → 105.6 ms**. The benefit is not driven only by faster silent responses.

**What was tested**

Eleven new variants, **75 serial replay runs and 11,064 measured requests**, excluding 600 warmups, across two separately pinned binaries. E2B weights, raw prompt text, sampler, token/word budgets and per-dataset confidence settings stayed fixed. Metal offload stayed enabled. The ordinary native thread setting on this machine is 14; reducing CPU workers did not switch inference off the GPU.

| Variant | Development mean / p95 ms | Fresh mean / p95 ms | Changed fresh outputs /144 |
|---|---:|---:|---:|
| Current decoder | 75.3 / 156.1 | 67.0 / 142.4 | 0 |
| Skip identical-state restores only | 76.9 / 158.1 | Not advanced | — |
| Reuse scalar candidate rankings | 70.7 / 131.7 | 60.5 / 117.4 | 0 |
| Reuse + bounded-search skip proof | 68.7 / 127.7 | 61.4 / 120.4 | 0 |
| 2 CPU threads only | 63.7 / 127.9 | 57.7 / 114.1 | 0 |
| Reuse + 2 CPU threads | 59.3 / 114.8 | 51.2 / 98.2 | 0 |
| Reuse + 4 CPU threads | 61.0 / 117.5 | 52.2 / 98.9 | 0 |
| Reuse + proof + 2 CPU threads | 58.5 / 111.4 | 51.6 / 98.9 | 0 |
| Two prefix paths | 69.1 / 127.8 | 58.7 / 114.6 | 11 |
| Eight search expansions | 69.9 / 130.5 | 60.5 / 119.6 | 1 |
| Exact typed prefix only | 90.9 / 154.8 | 84.5 / 159.4 | 80 |

The table's main confirmation rows use three counterbalanced fresh rounds. Other fresh ablations use one round and are exploratory. Root-restore skipping alone was slower in screening and did not advance. Ranking reuse stores only ordered candidate IDs and full-vocabulary-normalized scalar scores within one request, avoiding repeated search work without the old full-logit LRU's retained buffers. Identical-state reuse requires authoritative single-token logits provenance, not just equal token IDs. The extra skip proof bounds alternatives at their first divergence from the retained baseline path; it does not claim a globally optimal unrestricted continuation.

The proof's incremental benefit is **not established**: memoization with two threads measured 51.2 ms in one fresh pass, versus the proof combination's repeated 51.6 ms. The latter is the strongest *confirmed* configuration, not evidence that the proof independently helps. Keep this distinction when selecting a smaller production patch.

**Separate generation and prefill threads**

A second frozen binary added independent prefill threads and recorded the actual cancellation-issuance timestamp. It reused the same corpus, so this is a follow-up, **not a new holdout**. Its three-round fresh results were:

| Configuration | Fresh mean / p95 ms | Dynamic mean ms, one pass | Long mix mean ms, one pass |
|---|---:|---:|---:|
| Current 14/14 | 68.6 / 143.2 | 105.1 | 178.6 |
| Reuse + proof, 2/2 | 51.8 / 100.1 | 82.9 | 162.3 |
| Reuse + proof, 2/14 | 52.7 / 100.8 | 83.2 | 168.8 |

All outputs matched. Splitting the threads did not improve ordinary generation overall, but cancellation exposed a tradeoff:

| Threads / search | Actual cancellation issued, ms | Request returned, ms | Immediate replacement, ms | Cancel + replacement, ms |
|---|---:|---:|---:|---:|
| Current 14/14 | 7.8 | 80.8 | 258.8 | 339.6 |
| Reuse + proof, 2/2 | 7.3 | 95.6 | 240.5 | 336.1 |
| Reuse + proof, 2/14 | 7.5 | 79.6 | 243.7 | 323.3 |

These are **12 long-prefill interruptions per arm in one follow-up pass**, requested after 5 ms. The faster normal configuration returned from cancellation later. The split setting traded about 1 ms of ordinary generation for a better cancellation-return point estimate. Do not infer a native/GPU mechanism from this alone. The explicit cold-reset cost is outside generation timing, and outstanding GPU synchronization may affect immediate replacement measurements. The useful next metric is cancellation through the *next usable suggestion*, including cleanup, rather than cancellation return alone.

**Claude quality judgment**

Claude Opus 5.5 judged all 83 changed fresh checkpoints plus 24 shared-output controls. Anonymous alternatives were deduplicated; no model/implementation labels, latency, intended future references, personal writing or product source were sent. There were 24 repeat cases, with **39/42 repeated option utility ratings agreeing exactly** and no preference/utility inconsistencies. Silence has utility 0; ratings run from −2 to +2.

| Ablation | Wins / losses / ties vs current, all 144 checkpoints | Mean utility delta, 95% scenario interval | Decision |
|---|---:|---:|---|
| Exact prefix only | 4 / 72 / 68 | −1.500 [−1.743, −1.250] | Reject: slower and much worse |
| Two prefix paths | 2 / 8 / 134 | −0.097 [−0.201, +0.007] | Keep width 4; negative trend, uncertainty includes zero |
| Eight expansions | 1 / 0 / 143 | +0.021 [0, +0.063] | One improved example is insufficient to reduce the budget |

The narrower search's losses were mostly Serbian Latin (2 wins / 7 losses); English had one loss. The exact-prefix policy often leaves the model in a poor midword state. The eight-expansion improvement avoids a repetitive tail on one Serbian prefix. The latency finalists retain identical suggestions, so their measured quality delta is zero by output equivalence; this is not a new human-acceptance claim. See [examples](EXAMPLES.md) and [judge summary](claude-quality/summary.json).

**Prewarming and closed gaps**

Prewarming already exists in the product. This study verifies its native behavior rather than introducing another prewarm trigger. On the original configuration, long-field generation fell **213.3 → 124.6 ms** after a **95.0 ms** prewarm; total work became **219.5 ms**. The fast candidate was **195.2 → 103.5 ms**, plus **94.0 ms** prewarm, totaling **197.5 ms**. This moves work earlier and does not itself save total compute. All 288 cold/prewarm output pairs across both phases matched.

Previously incomplete work now covered: exact-only/no-overshoot ablation, shared prefix ranking work, thread-count and independent batch-thread experiments, focus-style prewarming, typing/backspace/field-scope traces, Unicode normalization/digraph/ASCII/code-switching edges, and cancellation during short search and long prefill. All **216/216 cancellation recoveries** across controls and candidates matched cold references. The six native Qwen tests that previously lacked their separate fixture now ran and passed.

**Recommendation and remaining experiments**

1. Retain E2B, width 4, the 32-expansion fallback, prompt and confidence gates. Per-request ranking reuse is the smallest promising integration step. Keep the search-skip proof separate until its incremental benefit is isolated on new text.
2. Treat two CPU generation threads as a promising setting **for this M4 Max**, with generation/prefill controls separate. Two/two is the fastest confirmed native configuration; two/fourteen is the more interesting next rollout candidate when interruption responsiveness matters. Neither is established as a universal Apple Silicon default. Existing installed settings remain unchanged.
3. Run a new, pre-registered EN/Serbian Latin holdout comparing memoization with/without the proof and 14/14, 2/2, 2/14 and 4/14 threads; repeat long-field and dynamic traces. Then measure at least 100 interruptions through the next usable suggestion, with actual timer delivery, GPU synchronization and cache-reset cost inside the measured window. Follow with end-to-end debounce/AX/overlay timestamps on a remote UI runner and another Apple Silicon hardware class.

Claude's [final advisory review](claude-final-advice/ADVICE.md) favors memoization first, keeping the proof separately gated, and 2/14 as the next thread candidate because of the cancellation tradeoff. That is advice based on the same data, not an additional validation sample. Its broad statement about memo-only parity should be read within the actual tested workloads in the table; the full 1,496-observation check belongs to the proof-plus-memo finalist.

Multi-sequence batching, speculative full-logit caching, token-history learning and fine-tuning remain separate projects. They were not silently counted as completed here. The optional EuroLLM alternative and large-MoE ceiling from the earlier model queue do not isolate this fixed-E2B latency question. No private writing was mined for training or evaluation.

**Method and limits**

Primary source baseline: `43451050913894f14e37be354ee9e5b5395dc082`, based on master `193460c3def4e11aa44dc95e28bef8724c783e80`. Installed executable SHA-256 `ef6783c6e24a1d42f10ff76a353670c9e418132ddc33b73c2cd20d76baeb7b37`; E2B weight SHA-256 `20f49b221691c71d955e1d5a840b6e26329db4a5e1626f702fa4226e80a9c629`. Both remained unchanged after the study. New benchmark binaries are pinned separately in the archived metadata.

M4 Max, 48 GiB, macOS 27.0.1; release builds, isolated local storage/defaults, fixed seed `0xC0FFEE`, temperature 0.1, top-p 0.7, top-k 20, min-p 0.08, repetition penalty 1.05, six free tokens/four displayed words. Each process has eight excluded warmups. Model inference, builds and native tests were not run concurrently. Claude calls were remote and used only synthetic packets/aggregate statistics.

Native timing includes generation, healing and normalization. It excludes model load, spelling checks, explicit fixture cache resets, debounce, accessibility reads and overlay publication; prewarm is separately timed. It is **not time from keystroke to visible suggestion**. A/A controls reproduce the prior 288 saved outputs and the installed app byte-for-byte in text/suppression, and all prompt strings match within each paired comparison. The first controls averaged 74.8/75.5/75.6 ms; the copied installed app measured 75.5 ms.

Confidence intervals use 5,000 paired bootstrap draws over original scenarios, grouping both languages and nearby checkpoints: 24 fresh pairs, six dynamic source pairs, six long-field source pairs, 16 edge prefixes and three targeted cancellation prefixes. Repeated rounds are kept within their scenario rather than counted as independent examples. The long/dynamic grouping corrects the initially convenient per-trace IDs; the frozen inputs were not changed. Tail percentiles are empirical pooled observations, not confidence intervals. Do not pool latency between the two binaries/cohorts. One machine, synthetic text and one model judge do not establish user acceptance, battery cost or hardware portability.

[Validation](VALIDATION.md) · [Paired statistics](paired-analysis.json) · [Raw replay/judge/source archive](../2026-10-11-latency.tar.gz) · [SHA-256 manifest](../2026-10-11-latency-manifest.json) · [Previous experiment index](../2026-10-10-experiments.md)
