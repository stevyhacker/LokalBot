Historical experiment snapshot. Current adoption: **E2B remains the default; the experimental switch enables hybrid plus prefix search.** See [the trial guide](../../../../Docs/experimental-autocomplete-hybrid.md). Complete raw evidence and the original, unedited report are in [the experiment archive](../2026-10-10-experiments.tar.gz). Archive member paths are listed in [the manifest](../2026-10-10-experiments-manifest.json).

# Decoder experiment loop — 2026-10-10

The strongest **single-word** candidate is the existing sampled decoder with a boundary-mass confidence score (threshold **0.31**) and a guarded display-limit stop. On 1,361 new English/Serbian checkpoints it matches 394 first words versus 369 for the control, while nonmatching shown suggestions fall from 269 to 239. Mean warm request latency falls from 37.0 to 29.1 ms; p95 falls from 79.5 to 73.8 ms. Weights and rendered prompts are fixed.

This is a tradeoff, not an overall quality win. The predeclared objective—more matching reference characters at no higher false-show count—**did not pass confirmation**. Character credit falls 3.7%, two- and three-word matching fall, and Serbian nonmatching suggestions rise slightly. The default decoder and installed app are unchanged. The new controls remain opt-in, headless experiments.

Nine distinct changes were tried: greedy sampling, removing the repetition penalty, a larger token budget, removing suppression, cumulative-score reranking, first-word reranking, word-only confidence, boundary-mass confidence, and display-limit stopping. The strongest combination was then checked separately. Coarse calibration, local threshold refinement, an early-stop optimization, and a suppression regression/fix are all retained in the archive. Total: **36,960 benchmark requests**, including rejected attempts.

Confirmation quality uses 112 phrases, not 21,776 independent quality examples. Four Williams-square timing orders repeat the same 1,361 inputs. Each arm produces exactly the same text/suppression on all four repetitions.

| Variant | First-word matches | Nonmatching shown | Precision when shown | Matching reference characters | Mean ms | p95 ms |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Current decoder | 369/1361 | 269 | 57.84% | 2174 | 37.05 | 79.49 |
| Guarded display stop | 369/1361 | 269 | 57.84% | 2174 | 33.78 | 75.37 |
| Boundary mass, threshold 0.31 | 394/1361 | 239 | 62.24% | 2093 | 33.40 | 81.24 |
| Boundary mass + guarded stop | 394/1361 | 239 | 62.24% | 2093 | 29.09 | 73.84 |

Here “nonmatching” means the first word differs from the single reference. It does **not** establish that a suggestion is linguistically wrong. Normalized case and straight/curly apostrophes are equivalent; different words and numeric spellings are not. Character credit counts the reference span of consecutive matching words after the caret, including intervening spacing/punctuation. It is not observed keystrokes saved or user acceptance.

Paired whole-phrase bootstrap, 5,000 resamples, for the confidence variant versus control (identical with or without the stop):

- First-word match rate: **27.11% → 28.95%**, +1.84 percentage points; 95% interval **+0.59 to +3.16 points**.
- Nonmatching shown rate: **19.77% → 17.56%**, −2.20 points; 95% interval **−3.80 to −0.66 points**.
- Matching characters per checkpoint: **1.597 → 1.538**; delta −0.060, 95% interval **−0.146 to +0.017**. There is no confirmed improvement in the primary metric.
- Two-word agreement: **10.36% → 9.05%**. Three-word agreement: **4.42% → 3.96%**. Coverage stays similar: **46.88% → 46.51%**.

The combined variant saves 7.96 ms per static request on average (whole-phrase 95% interval: 6.99–8.92 ms). Guarded stopping alone saves 3.27 ms (2.62–3.97 ms), with **zero changed text or suppression decisions** in all 5,444 confirmation pairs. The same parity holds between the confidence variant and its stopped version. Peak process RSS across confirmation runs stays within **3.860–3.864 GiB**. This includes loaded weights and native buffers; the tokenizer-only boundary mask adds roughly one float per vocabulary entry.

Language results show why a single global threshold should not be promoted yet:

| Language | Checkpoints | Control matches / nonmatches | New confidence matches / nonmatches |
| --- | ---: | ---: | ---: |
| English | 1044 | 323 / 226 | 340 / 192 |
| Serbian | 317 | 46 / 43 | 54 / 47 |

The first-word gains often recover a useful small word without recovering the following phrase. For example, after “The washing machine”, the reference continues “is making a”; the new suggestion is “is a very important”, whereas the control stays quiet. After “The museum tickets sold”, it recovers “out”, but follows with a different phrase. Conversely, it suppresses the control’s good “long day and I’m” continuation after “it’s just been a”. A deterministic sample of gains/losses is saved in `qualitative-examples.json`; it is descriptive, not a blinded human rating.

The product defaults to accepting one word with Tab (`AppSettings.cotypingAcceptGranularity = .word`). That makes the secondary first-word gains relevant, but users still see the rest of the ghost. A promising next step is **per-word confidence with adaptive visible length**, evaluated separately for word and phrase acceptance, and calibrated across languages. It should optimize useful accepted characters and correction/undo behavior, then face another fresh confirmation set. It is not implemented or claimed as a measured win here.

The dynamic regression replays 16 existing synthetic traces through forward typing, backspace, retyping, branching, repeated prefixes, long contexts, scope changes, explicit clearing, and real in-flight cancellation. Each arm runs twice in forward/reverse order: 323 requests per run, including 16 cancellations. These are previously used regression traces, not an independent quality holdout.

| Variant | Noncancelled requests | Mean ms | p95 ms | p99 ms | Cancellation-return p95 ms |
| --- | ---: | ---: | ---: | ---: | ---: |
| Current decoder | 614 | 85.37 | 116.76 | 267.75 | 1.44 |
| Guarded display stop | 614 | 74.52 | 123.50 | 256.04 | 1.61 |
| Boundary mass | 614 | 81.89 | 121.89 | 239.85 | 2.10 |
| Boundary mass + guarded stop | 614 | 75.36 | 113.87 | 231.79 | 1.93 |

The combination saves **10.01 ms** per noncancelled typing request (paired bootstrap over all 16 traces: **7.08–12.94 ms**). Its pooled p95 improvement is only **2.5%** and varies by round; this is modest evidence for tail latency. Stopping alone improves the mean but worsens pooled dynamic p95 by **5.8%**, so it does not pass a strict across-workload p95-improvement gate.

All **128 intentional cancellations** returned no suggestion text. Both stop/no-stop pairs retain identical noncancelled text/suppression and identical prompts. Cancellation-return time measures the host task, not independently observed GPU quiescence. The sum of cancellation return and the next recovery request, excluding the configured inter-step delay, averages **154.8 → 140.3 ms** for the combination; its p95 is **397.8 → 295.7 ms** across 32 pairs per arm. These sums are diagnostic components, not a measured keystroke-to-visible-suggestion time.

The development sequence below uses the same already-observed 600 checkpoints. Single-pass development timings helped screen options; the balanced confirmation/dynamic measurements above support the final latency comparison.

| Attempt | First-word matches | Nonmatching shown | Reference characters | Mean ms | p95 ms |
| --- | ---: | ---: | ---: | ---: | ---: |
| Initial control | 187 | 137 | 1122 | 40.88 | 82.05 |
| 1. Greedy | 186 | 138 | 1120 | 42.12 | 85.41 |
| 2. No repeat penalty | 187 | 137 | 1122 | 41.22 | 83.14 |
| 3. Ten free tokens instead of six | 187 | 137 | 1122 | 48.67 | 120.67 |
| 4. Disable confidence gate | 251 | 348 | 1395 | 60.15 | 87.31 |
| Four-candidate reference | 189 | 156 | 1082 | 66.78 | 113.27 |
| 5. Cumulative-score rerank | 193 | 152 | 1141 | 66.87 | 114.13 |
| 6. First-word-score rerank | 194 | 151 | 1124 | 67.79 | 117.12 |
| 7. Word-only score, threshold 0.32 | 198 | 135 | 1128 | 38.28 | 86.05 |
| 8. Boundary mass, threshold 0.31 | 205 | 137 | 1152 | 40.02 | 84.10 |
| 9. Guarded display stop | 187 | 137 | 1122 | 36.35 | 76.05 |
| Combination | 205 | 137 | 1152 | 33.91 | 75.22 |
| Final-build control | 187 | 137 | 1122 | 40.65 | 80.63 |

Reranking operates on exactly the same four normalized finalists as the original four-candidate search; candidate-set comparisons show zero changes. Cumulative ranking gains six matches over control but adds fifteen nonmatches and substantial latency. First-word ranking gains seven but adds fourteen nonmatches. Neither meets the chosen false-show budget. This agrees with the earlier [two/four-candidate study](../2026-10-10-candidates-master/REPORT.md). The prior [logit-cache experiment](../2026-10-10-cache/REPORT.md) also remains disabled; this loop does not change its policy.

Claude Opus (`claude-opus-5-5`, verified in the CLI response) advised that multiplying by one specific next-word token understates first-word probability, while dropping that factor entirely overstates the probability of the word terminating. The implemented score uses the sum of full-vocabulary probabilities for boundary-initial tokens plus EOS. The mask is built at model load, excludes other control tokens and incomplete UTF-8 prefixes, and retains the existing apostrophe/hyphen rules. Tokens that extend the current word still count in full. Midword suggestions retain the existing ungated behavior. This is a score for the selected token path, not an exact marginal over all tokenizations or a calibrated acceptance probability.

The first coarse confidence grid selected 0.35 for both new scores. It reduced nonmatches but also reduced character credit. A pre-confirmation development-only refinement over 0.30–0.35 in 0.01 steps selected 0.32 for word-only confidence and 0.31 for boundary mass. Native reruns reproduced the offline filtering estimates. Latency fields inside calibration curves describe the low-threshold diagnostic passes; only native calibrated runs measure the cost of the fitted gate. No threshold, prompt, model, or scoring rule was retuned after confirmation began.

The initial display-stop implementation preserved the ordinary control but failed when combined with the new gate: after the synthetic prefix “Customer: The application keeps crashing. Support: Could you tell me”, it returned “what happens when it” before a later question mark would have triggered the existing `questionContinuation` suppression. The failed native run is retained. The fix shares the normalizer’s pending-question policy and defers stopping for trailing text and markup, while a cheap word-count precheck avoids repeated full normalization. The guarded version passes all 600 development pairs, all 1,361 confirmation cases in four repetitions, and the dynamic stop/no-stop comparisons. A focused regression test covers the discovered failure. These finite checks do not prove every future normalizer interaction safe.

The initially proposed 850-checkpoint confirmation subset was discarded **before any confirmation inference**: a history audit found that the complete public corpus had been evaluated on 2026-10-02. Opus then independently authored 112 new 7–14-word phrases, without supplied decoder settings, outputs, source code, or benchmark records. There are fourteen phrases in each of eight categories, including Serbian Latin and Cyrillic. No normalized phrase duplicates the original public or challenge corpus. All word boundaries and two hash-selected midword checkpoints per phrase produce the 1,361 cases. Future reference words and category labels are scoring-side only. Both the discarded proposal and the correction/freeze records are retained.

The test environment is Apple M4 Max, 48 GiB RAM, macOS 27.0.1, on AC power; the normal installed app/background processes remained running. All variants use `gemma-4-E2B.i1-Q6_K.gguf`, pinned llama.cpp `b11474`, and the production prompt builder, healing, and normalizer. Loading, mask construction and initial model priming are excluded from request latency. Measured calls include native prefill/decode, normalization and diagnostics; debounce, Accessibility, overlay rendering, and human acceptance are outside this experiment. Timed inference never ran alongside a build or test suite.

Weights SHA-256: `20f49b221691c71d955e1d5a840b6e26329db4a5e1626f702fa4226e80a9c629`. Measured final Release executable SHA-256: `836929d181908cd322c21b4f239447552cee0ad16de774684f006f06e2d56dad`. Base and refreshed origin/master are both `193460c3def4e11aa44dc95e28bef8724c783e80`, including PRs #228 and #229. Per-run receipts capture source, input, reference, model and executable hashes.

Validation completed:

- Release build succeeded. Final native source hashes match the measured Release.
- **64 non-UI Swift tests passed**, zero failures/skips, with the real model supplied to native branch/cache/cancellation tests.
- **45 Python tests passed**, including reference isolation, phrase grouping, calibration-related scoring, decoder/prompt validation, and correct audit margins for alternative rankings.
- Repository-wide strict SwiftLint and `git diff --check` passed.
- No local UI tests, installation, release, commit, push, or PR publication occurred. Unrelated initial dirty files were preserved.

The result is reviewable through [the experiment runner](../../decoder_loop.py), [typing runner](../../decoder_dynamic.py), and the [replay controls](../../README.md#decoder-optimization-loop-2026-10-10). `raw-runs.tar.gz` includes every input/output/log, initial and revised source snapshots, development plans and calibration curves, the corpus-generation request, Opus advice, native build/test logs, the implementation patch, analysis scripts, and validation receipts. It excludes model weights, app bundles and personal writing. `archive-manifest.json` provides per-file hashes and the archive hash.

**Recommendation:** keep the current production default. The confidence-plus-stop combination is the best candidate for a controlled **single-word** pilot; it improves the corresponding reference metrics and average latency. Guarded stopping is a useful performance ingredient, but its standalone dynamic tail regression needs investigation. For a broader quality gain, test per-word confidence and adaptive visible length, with separate word/phrase objectives and language-aware calibration, on another untouched fixture and a remote UI/acceptance evaluation. Wider candidate search is not the next priority on this model.
