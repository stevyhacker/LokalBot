# Native selective one-word hybrid — 2026-10-10

> Historical evaluation of the native prototype, before app integration. The measured binary includes prior replay experiments that are not enabled here. See [the trial guide](../../../../Docs/experimental-autocomplete-hybrid.md) for the integrated switch and its separate validation.

**Result:** the native hybrid preserves the current decoder’s suggestions and adds modest next-word help. On 64 fresh synthetic phrases (738 checkpoints), Claude Opus rates **71 additions helpful, 6 neutral, 0 harmful**. Most gains are tiny words. Mean warm latency rises **36.6 → 40.2 ms (+3.6 ms, +9.9%)**; static p95 stays **81.7 → 81.6 ms**. Dynamic typing latency is statistically inconclusive. This is a quality/coverage tradeoff, not a demonstrated speed improvement.

Implemented and validated as an **opt-in local decoder experiment** (`selectiveOneWordHybrid: true`). Production defaults and the installed app remain unchanged. No release, installation, commit, or PR was made.

## Implementation

The current selected-token confidence gate (0.1) and boundary-mass fallback (0.31) evaluate **one sampled token stream**, sharing the probability calculation. Passing current suggestions remain exact. If current confidence fails but the fallback passes, the engine normalizes the complete decode with the existing normalizer and keeps only its first word. Inside-word completion keeps current behavior.

Both gate decisions are sticky: a failed gate cannot become valid again after it settles. Current EOS behavior remains intact. The cap follows normalization so it cannot bypass a question-continuation, unsafe-insertion, or context-leak suppression. Hybrid streaming publishes only the final normalized decision; no uncapped fallback is exposed. This also means first-visible UI timing needs a separate test.

The replay rejects combinations with beam search, logit caching, display stopping, altered primary thresholds, or a disabled confidence gate. It does not change the model, prompt, sampler, token budget, normalizer, or ordinary app defaults. The earlier guarded display-stop optimization was deliberately not combined with this policy.

## Frozen comparison

- Base: `193460c3def4e11aa44dc95e28bef8724c783e80`, including merged PRs #228 and #229. The working tree also contains the preceding decoder experiments.
- Model: `gemma-4-E2B.i1-Q6_K.gguf`, SHA-256 `20f49b221691c71d955e1d5a840b6e26329db4a5e1626f702fa4226e80a9c629`.
- Release executable SHA-256: `abe2d0486b5ec87d2b6fd047fbacc1c310cd8d94dd89c3fabc54dfc3c3113a36`. Both arms use this same immutable executable; weights and executable were hashed again after inference.
- Machine: Apple M4 Max, 48 GiB, macOS 27.0.1, AC power; llama.cpp `b11474`.
- 64 new phrases, 8 per category, authored by the implementing assistant before inference; 48 English and 16 Serbian (8 Latin, 8 Cyrillic). No full phrase duplicates any earlier corpus. All word boundaries and two fixed midword checkpoints per phrase: 738 cases.
- Previous 600 development and 1,361 confirmation checkpoints are now regression data. None is counted as fresh evidence.
- Fresh timing: four current/hybrid rounds in AB/BA/BA/AB order. Typing: two AB/BA rounds over 16 existing traces, each with 307 normal requests and 16 cancellations. A separate boundary-mass reference verifies the hybrid composition and is excluded from the paired speed comparison.
- **14,140 native requests**, 80 deliberate cancellations, zero replay errors. No build, unit-test run, or remote judging overlapped timed inference. Per-case rendered prompts match across arms. References never enter the generation prompt or judge packet.

The [frozen plan](plan.json), [execution receipt](execution.json), and [native analysis](analysis.json) retain the settings, source hashes, environment, orders, and results. Repetitions are latency observations, not additional quality samples.

## Fresh quality

| Metric (738 checkpoints) | Current | Hybrid |
| --- | ---: | ---: |
| Shown suggestions | 306 | 383 |
| Exact next-word reference matches | 157 | 189 |
| Shown suggestions not matching the reference | 149 | 194 |
| Reference-matching characters | 788 | 880 |
| Reference precision when shown | 51.3% | 49.3% |

All 306 current outputs are preserved; the hybrid adds 77 suggestions. It gains 32 next-word matches but also 45 nonmatching suggestions. A nonmatch can be a useful alternative, so this is not an error or human-harm count. Matching characters are reference agreement, not observed keystrokes saved. Two- and three-word matching are unchanged because only new one-word outputs are added.

Claude `claude-opus-5-5` was verified in every fresh and regression response. It saw only the typed prefix and anonymous continuations, with silence valued at zero. It saw no reference future, decoder identity, probability, timing, or product source. Tools, MCP, skills, and session persistence were disabled. Every changed case was judged, plus 64 shared shown cases and 24 anonymous repeats on the fresh corpus. The same previous utility rubric was frozen before judging.

Fresh utility distribution: **68 small gains (+1), 3 larger gains (+2), 6 neutral (0), 0 negative**. The mean relative utility over all 738 checkpoints is **+0.100**, whole-phrase bootstrap 95% interval **[0.081, 0.119]**, resampling 64 phrases. This interval captures variation across these phrases under this judge, not variation across humans or judge models.

The effect is small in practical terms: **68 of 77 additions have at most three characters**. Discounting all positive ratings on words of three characters or fewer leaves **8 improvements, 0 regressions**, with utility delta **+0.015** [0.005, 0.026]. Discounting Claude-flagged minimal-value outputs leaves **46 improvements, 0 regressions**. These are the same sensitivity rules used in the preceding study; they do not replace the primary scores.

The 64 sampled shared suggestions were identical in both arms: 45 helpful, 14 harmful, 5 neutral. **The hybrid does not remove existing bad suggestions.** This equal-category sample is diagnostic, not a population-weighted absolute quality estimate.

## Latency

All values are milliseconds. Static columns pool four rounds (2,952 requests per arm); typing pools two rounds (614 noncancelled requests per arm).

| Workload | Current mean | Hybrid mean | Current p50 | Hybrid p50 | Current p95 | Hybrid p95 | Current p99 | Hybrid p99 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Fresh static | 36.61 | 40.22 | 23.14 | 27.22 | 81.70 | 81.59 | 100.67 | 99.36 |
| Typing traces | 84.57 | 83.89 | 80.44 | 81.04 | 120.02 | 113.64 | 233.62 | 233.30 |

Paired mean hybrid-minus-current change: static **+3.61 ms**, phrase-bootstrap 95% interval **[2.71, 4.60]**; typing **-0.68 ms**, trace-bootstrap interval **[-1.84, 0.38]**. The typing interval crosses zero; do not claim a speed gain. Only two typing checkpoints receive new fallback text, so those traces exercise the fallback far less than the static word-boundary corpus. Individual current typing p95 varies from 114.3 to 154.0 ms across the two runs; the pooled percentile is descriptive, not a proven tail improvement.

All planned cancellations completed without publishing text. Cancellation-to-host-return p95: current **1.67 ms**, hybrid **0.98 ms**, 32 cancellations per compared arm. This measures request return after cancellation, not independent GPU quiescence.

These are **warm complete engine-call timings**. They exclude cold model/mask loading, debounce, accessibility, overlay rendering, and first-visible timing. No local UI tests were run. The extra static mean cost is consistent with generating suggestions that current confidence stops early; capping display length after normalization does not avoid that decoding work.

## Concrete outputs

The caret marks exactly where the new text is inserted. Current is silent on these cases. These examples illustrate the measured behavior; [all 181 judged additions and ratings](ALL-NEW-SUGGESTIONS.md) are retained.

| Already typed (▌ is the caret) | Current | Hybrid inserts | Claude utility | Claude reason |
| --- | --- | --- | ---: | --- |
| `Give me a minute to finish what I'm ▌` | Silent | `doing` | +2 | 'What I'm doing' is the idiomatic, highly likely completion. |
| `I moved the configuration into a separate ▌` | Silent | `file` | +2 | 'Separate file' is the strongly expected completion. |
| `Check whether breakfast is included before we ▌` | Silent | `book` | +1 | 'before we book' fits breakfast/hotel context well. |
| `Одштампај само последњу ▌` | Silent | `страницу` | +2 | Natural Cyrillic noun completing the phrase. |
| `Give ▌` | Silent | `your` | +0 | Possible, but "me" or "it" seem more likely after "Give". |

## Regression and judge variability

The old 1,361-checkpoint corpus preserves all 638 current suggestions and adds the same 104 one-word outputs as the offline hybrid. The fresh native rejudgment gives **98 helpful, 4 neutral, 2 harmful**. Its two harmful cases remain:

| Already typed (▌ is the caret) | Current | Hybrid inserts | Claude utility | Claude reason |
| --- | --- | --- | ---: | --- |
| `Мачка је поново прескочила ограду и нестала ▌` | Silent | `је` | -1 | A redundant clitic 'је' after the verb is ungrammatical here. |
| `Библиотека ради дуже током испитног ▌` | Silent | `roka` | -1 | The right word, but in Latin script after a Cyrillic prefix. |

These script/grammar failures are not fixed by the hybrid. Nor should a corpus-specific exception be added for them without a broader evaluation.

The earlier judge assigned those exact same 104 outputs **77 helpful, 25 neutral, 2 harmful**. The native implementation did not improve those outputs: it reproduces them exactly. Across the two judging sessions, exact utility agreement is **75.0%** and positive-versus-nonpositive agreement is **76.0%**. The earlier packets also contained other full/capped alternatives; the new packets compare current with the native hybrid. This is judge/context variability, not a new quality gain.

Within this run, the 24 fresh repeats have **83.3% exact utility agreement** and **95.8% positive/nonpositive agreement**. Old-corpus repeats have **87.5%** and **91.7%**, respectively. No preference/utility contradictions were found. Raw responses and numeric ratings are retained rather than replacing disagreeing ratings.

## Validation and next decision

- Release build passed; **71 focused non-UI Swift tests passed, zero skipped**, including actual-model hybrid composition and streaming checks.
- **54 Python benchmark/judge tests passed**, strict SwiftLint passed, and `git diff --check` passed.
- Native composition parity: 600 development, 1,361 old confirmation, 738 fresh, and 323 typing requests; zero mismatches on noncancelled output. All repeated current/hybrid outputs and suppressions were stable.
- The current decoder matches the prior binary on all 1,961 earlier static cases. Live and archived Swift source hashes match the measured receipt. Existing unrelated files were preserved.

**Recommendation:** retain this hybrid as the next quality candidate for an opt-in user trial. It buys additional plausible next words for about 3.6 ms average static cost, while preserving current suggestions. It is not evidence of markedly better phrase writing or faster decoding. Measure actual accepted/useful characters, dismissals, script errors, and first-visible end-to-end latency before a default change. For performance work, investigate a provably safe shorter fallback decode; the earlier question-continuation regression shows why stopping immediately after one word is not equivalent to full normalization.

The implementation and benchmark entry points are documented in the [trial guide](../../../../Docs/experimental-autocomplete-hybrid.md). [Validation](validation.json), [test results](test-summary.json), [fresh ratings](fresh-judge.json), [regression ratings](regression-judge.json), and [cross-session comparison](cross-judge-stability.json) provide the detailed evidence. Raw native inputs/outputs, source snapshot, build/test logs, and judge packets/responses are in the two archives; [archive hashes](archive-manifest.json) verify their contents.
