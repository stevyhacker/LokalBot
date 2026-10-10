Historical experiment snapshot. Current adoption: **E2B remains the default; the experimental switch enables hybrid plus prefix search.** See [the trial guide](../../../../Docs/experimental-autocomplete-hybrid.md). Complete raw evidence and the original, unedited report are in [the experiment archive](../2026-10-10-experiments.tar.gz). Archive member paths are listed in [the manifest](../2026-10-10-experiments-manifest.json).

# Confidence calibration and model confirmation — 10 October 2026

**Luchador remains the experimental default pick under the requested fallback rule: none of the four new candidates beats its predeclared word-start score. It is not a demonstrated universal upgrade over E2B.** At equal frequency, its combined English/Serbian Latin advantage over E2B is only +0.021 utility, with a 95% scenario-cluster interval of −0.177 to +0.214. E2B is faster and had fewer poor Serbian Latin outputs.

The experiment, native replay controls, model downloads, fresh Claude judgments and timing runs are complete. [selection.json](selection.json) records the choice and pinned rollback model. The installed app and app defaults were **not changed** in this experiment; the existing draft PR and CI were left alone. The learned cutoffs remain replay controls.

## Matched-frequency confirmation

Every arm showed **140/192 suggestions**, exactly **70/96 in English and 70/96 in Serbian Latin**. That consists of 38/64 word-start suggestions and 32/32 midword suggestions per language. No Cyrillic input cases enter selection. The judge still penalized unwanted script/language switches out of Latin.

Useful means Claude utility >0; poor means <0. Remaining shown suggestions are neutral. Utility is an ordinal −2…+2 score relative to silence, not a human acceptance rate. “E2B single gate” is the legacy decoder with its own matched-frequency cutoff; “E2B hybrid” is the previously enabled hybrid design. All rows below are calibrated comparison configurations.

| Model | Word-start utility (primary) | Overall utility | Useful / poor of 140 shown | English useful / poor of 70 | Serbian Latin useful / poor of 70 | Mean / p95 ms |
|---|---:|---:|---:|---:|---:|---:|
| Luchador E4B hybrid | 0.703 | 0.672 | 107 / 24 | 60 / 4 | 47 / 20 | 74.5 / 124.3 |
| Stock Gemma E4B IT hybrid | 0.656 | 0.646 | 108 / 26 | 61 / 5 | 47 / 21 | 72.7 / 124.2 |
| Gemma E2B hybrid | 0.586 | 0.651 | 109 / 21 | 57 / 9 | 52 / 12 | 53.0 / 82.7 |
| Qwen3 4B Base hybrid | 0.562 | 0.453 | 96 / 35 | 55 / 10 | 41 / 25 | 57.4 / 87.3 |
| Salamandra 2B hybrid | 0.430 | 0.276 | 89 / 34 | 56 / 7 | 33 / 27 | 26.4 / 45.8 |
| YugoGPT 7B hybrid | 0.578 | 0.542 | 107 / 22 | 58 / 6 | 49 / 16 | 87.2 / 138.5 |
| E2B single gate | 0.430 | 0.547 | 96 / 32 | 55 / 11 | 41 / 21 | 53.5 / 82.8 |

The Luchador vs stock IT difference is unresolved: primary utility difference +0.047, 95% interval −0.031 to +0.125. Their sizes (~6.33 GB) and latency are nearly identical. Stock IT does not establish an advantage over the fine-tune. Qwen3 4B and YugoGPT do not improve the combined tradeoff; Salamandra is much faster but has weak Serbian Latin quality here. This round covers E2B, Luchador and all four Claude additions; the earlier LFM2.5/Qwen3.5/base-E4B runs are not mixed into this matched-frequency ranking.

**The clearest decoder result is the E2B hybrid:** compared with the matched single gate, it gives 13 more useful suggestions and 11 fewer poor ones at essentially the same latency. Overall utility improves +0.104 [0.021, 0.193]; word-start utility +0.156 [0.031, 0.289]. This is evidence for the selective hybrid versus the single gate, both calibrated to equal frequency—not proof that threshold fitting alone caused the gain.

## What calibration changed

The replay can retain a whole normalized candidate and its one-word alternative while recording both gate scores. Native verification reconstructs each gated output from that trace. The trace does not reject low-confidence text; it is excluded from performance comparisons. Two positive replay thresholds are configurable globally or per case; ordinary app defaults remain 0.1 and 0.31.

Seven fallback/primary ratios were fixed in advance: 0.5, 1, 2, 3.1, 5, 10 and 1,000,000 (effectively primary-only). Development Claude utility chose one ratio per model at equal word-start frequency. The chosen ratios were E2B/Luchador 3.1, stock IT/Qwen3 2, and Salamandra/YugoGPT 0.5. Language-specific cutoffs were frozen before confirmation inference.

The strict matched-frequency table uses **unlabeled confirmation confidence quantiles**, with the development ratio fixed. It is a transductive diagnostic, not deployable calibration. No confirmation quality labels set those cutoffs. The frozen development cutoffs are also evaluated independently:

| Model | Confirmation shown using frozen development cutoffs / 192 | Overall utility |
|---|---:|---:|
| Luchador E4B hybrid | 138 | 0.661 |
| Stock Gemma E4B IT hybrid | 142 | 0.630 |
| Gemma E2B hybrid | 153 | 0.688 |
| Qwen3 4B Base hybrid | 152 | 0.505 |
| Salamandra 2B hybrid | 149 | 0.312 |
| YugoGPT 7B hybrid | 154 | 0.609 |
| E2B single gate | 143 | 0.562 |

The intended 140/192 rate drifted on unseen inputs. In particular E2B reached 153 and Luchador 138, so their frozen-cutoff utility totals are not a fair equal-frequency ranking. Exact language labels are supplied by the fixture; an automatic production language router was not tested. These are score/cutoff calibrations, not calibrated probabilities of acceptance.

With the original 0.1/0.31 gates, heldout E2B hybrid shows 117/192 and Luchador 165/192. Their overall utilities are 0.542 and 0.797 respectively. That large apparent advantage shrinks substantially after matching frequency. These as-is figures are a different comparison from the main table.

## Latency beyond short prefixes

Primary latency comprises 576 actual native requests per arm in three serial, reordered rounds, with tracing disabled and confidence early exits enabled. Loading and eight warmups per process are excluded. Times include generation, token healing and normalization; they exclude debounce, accessibility, overlay rendering and first-visible UI latency.

The separate long-document stress set uses 16 fresh/shared pairs, balanced by language, with production context limits and frozen development cutoffs. Its suggestion rates are **not matched**; use it to understand prefill cost, not to rank quality. Each model has 96 measured requests:

| Model | Fresh-context mean / p95 ms | Shared-prefix mean / p95 ms |
|---|---:|---:|
| Luchador E4B hybrid | 394.0 / 529.3 | 83.5 / 124.6 |
| Stock Gemma E4B IT hybrid | 385.9 / 528.6 | 82.3 / 123.4 |
| Gemma E2B hybrid | 221.2 / 269.6 | 51.1 / 80.4 |
| Qwen3 4B Base hybrid | 413.7 / 566.6 | 59.1 / 81.7 |
| Salamandra 2B hybrid | 115.9 / 139.7 | 22.4 / 39.7 |
| YugoGPT 7B hybrid | 780.5 / 1111.3 | 78.2 / 123.2 |

Luchador has a real fresh-context cost: ~394 ms mean versus E2B ~221 ms. This is another reason to keep E2B readily selectable. The existing focus prewarm path is outside this measurement; no claim is made about observed app UI latency.

## Serbian Latin: the useful next target

The weak slice is **midword completion**, where the confidence gate is intentionally bypassed. Luchador has 15/32 poor Serbian Latin midword suggestions here versus E2B 10/32. Stock IT has a similar weakness. Word-start calibration cannot repair these cases. [EXAMPLES.md](EXAMPLES.md) shows paired wins and losses; [examples.json](examples.json) also contains the exact concatenated text and judge reasons.

A code audit supplies a concrete hypothesis: `CotypingCoordinator+Prediction.swift` treats a fragment as a valid standalone word when the spelling-language gate cannot apply. `CotypingSpellChecker.swift` explicitly identifies unsupported Serbian/Croatian/Montenegrin dictionaries as that condition. This disables the preference for a token that extends the partial word. The fixtures held `wordPrefixIsValidWord=true` for every model; they did not run the live spelling/language classifier. The source establishes a path worth testing, not that it caused every bad sample. English midword results also bypass the live dictionary and are limited by that assumption.

A post-hoc diagnostic capped every midword suggestion to one word using the already collected blind ratings. Luchador utility **fell** 0.672→0.589; poor outputs fell only 24→22. E2B also lost utility. So a blanket one-word cap is not the next fix. See [posthoc-midword-cap.json](posthoc-midword-cap.json); this is a diagnostic on observed confirmation data, not a new validated variant.

Recommended next work: audit Serbian Latin partial-word conditioning and token healing on a new, frozen corpus; compare Luchador and E2B with realistic spelling-language verdicts and fixed deployable cutoffs. Have a native Serbian speaker rate the disagreement cases. Retain the hybrid and the E2B rollback; a language/model router is only a future hypothesis and its memory/switching latency has not been measured.

## Claude and uncertainty

Fresh blind Claude Opus 5.5 packets include only synthetic prefixes and anonymous full/one-word continuations. No future reference, model names, latency or product source is included in the authored packets. Sixteen cases repeat per split with reversed option order. Confirmation CLI calls additionally used safe mode to disable automatic repository/customization discovery; development used the existing no-tools/no-settings/no-session protocol. Requests, responses, model IDs and hashes are retained.

Repeat agreement: development 108/126 exact and 117/126 sign; confirmation 86/110 exact and 98/110 sign. Intervals use 5,000 paired bootstrap draws over 32 scenario clusters, grouping English/Serbian translations and nearby checkpoints together. They are conditional on this corpus, fitted policy and one judge; they do not include human variation, all training uncertainty or a multiple-comparison correction. No significant per-language superiority is claimed.

Claude separately reviewed the completed aggregates and agreed that the literal Luchador fallback condition is met, while its superiority over E2B is unresolved. Its advice is post-hoc interpretation, not an additional blind quality vote: [ADVICE.md](claude-interpretation/ADVICE.md). Its reference to “calibration beating the single gate” is interpreted here more precisely as the two calibrated decoder designs being compared. The long-context results above were completed after that advisory response.

## Implementation and validation

- Added opt-in confidence tracing, configurable hybrid thresholds and per-case replay cutoffs; retained the same model files, prompt, sampling and token budget.
- Six pinned model files passed SHA-256 checks and native load/replay. Salamandra metadata matches 24 layers, width 2048 and vocabulary 256,000, resolving the quantizer card’s copied 7B prose at the architecture level. YugoGPT carries generic Mistral metadata; source attribution still relies on the pinned quantizer repository, not an upstream-weight equivalence proof.
- 10,520 native benchmark calls, including 536 warmups; 4,032 primary timing calls and 576 long-context timing calls. Zero replay errors and zero repeated primary-output changes.
- 36 native runs matched their traced counterfactual outputs. The instrumented build matched the immutable previous build on all 200 reference requests, including exact prompts, text and suppression.
- Release build passed; 67 focused Swift tests passed, including native hybrid parity and new confidence invariants. All 61 Python tests and strict lint on changed Swift files passed. No local UI tests or PR CI changes.

Runtime: M4 Max, 48 GiB, macOS 27.0.1, AC power, libllama b11474. Binary SHA-256 `0cb89655ed981f0830f4a35e6487d58af585d3b700a34782b91973eefea13d24`. Base commit `193460c3def4e11aa44dc95e28bef8724c783e80`; experiment source snapshots and hashes preserve the uncommitted implementation used for the study.

Reproduction/evidence: [plan.json](plan.json), [calibration.json](calibration.json), [matched.json](matched.json), [models.json](models.json), [analysis.json](analysis.json), [long-analysis.json](long-analysis.json), [validation.json](validation.json). Every run retains input, raw output, stderr and a receipt. The model manifest contains pinned download URLs and hashes; temporary local paths may need updating for a future run.
