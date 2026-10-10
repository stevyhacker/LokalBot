Historical experiment snapshot. Current adoption: **E2B remains the default; the experimental switch enables hybrid plus prefix search.** See [the trial guide](../../../../Docs/experimental-autocomplete-hybrid.md). Complete raw evidence and the original, unedited report are in [the experiment archive](../2026-10-10-experiments.tar.gz). Archive member paths are listed in [the manifest](../2026-10-10-experiments-manifest.json).

# Autocomplete experiments: consolidated result and next steps

2026-10-10. This consolidates the Cotypist investigation, decoder experiments, native hybrid confirmation, five-model comparison and Claude-selected follow-up queue. It adds no new inference or quality ratings. The accompanying [summary.json](summary.json) preserves model metrics and hashes of the source reports and analyses.

**Recommendation: retain Gemma 4 E2B with the selective one-word hybrid for the current trial. Treat Luchador as the strongest English-quality candidate, pending confidence calibration and human evaluation. The next implementation should expose candidate confidence and suppression traces, enabling an equal-coverage comparison.**

The hybrid has evidence of a modest improvement; it does not fix existing bad suggestions. Luchador has the largest confirmed model-judge gain, but costs more memory and latency and regresses on Serbian Cyrillic. Neither finding establishes higher human acceptance or faster visible suggestions.

## The most comparable result

These three configurations ran on the same 160 confirmation checkpoints from 32 new phrases, with the same prompt and generation budget. Timing pools three serial rounds. Useful and poor are blind Claude Opus judgments relative to silence, not human acceptance or exact-reference accuracy.

| Configuration | Useful / 160 | Poor / 160 | Exact next-word matches / 160 | Mean / p95 native latency |
|---|---:|---:|---:|---:|
| Gemma E2B, original decoder | 69 | 18 | 64 | 43.4 / 84.0 ms |
| Gemma E2B, selective hybrid | 84 | 19 | 72 | 48.1 / 84.8 ms |
| Gemma E4B Luchador, selective hybrid | 109 | 15 | 72 | 75.6 / 121.3 ms |

The hybrid adds 15 useful suggestions and one poor suggestion on this set, with about 4.7 ms extra mean cost. Luchador adds 25 useful suggestions and removes four poor suggestions relative to E2B hybrid, at about 27.5 ms extra mean cost. Its paired utility gain is +0.375 on the −2 to +2 scale, with a 95% phrase-bootstrap interval of [+0.150, +0.600].

Luchador and E2B hybrid both match the exact reference next word 72 times. Luchador shows 131 suggestions versus 110, so the quality improvement includes more useful alternative wording and greater coverage. It is not evidence that exact next-word prediction improved. The inherited gates are not calibrated across models; this is the main unresolved comparison issue.

Source: [model confirmation report](../2026-10-10-models/REPORT.md), [raw analysis](../2026-10-10-models/confirmation-analysis.json).

## What survived the decoder experiments

| Experiment | Measured result | Decision |
|---|---|---|
| Two/four candidate search | 187 → 189 next-word matches out of 600 at either width; confidence intervals include zero. Mean latency 43.2 → 58.6 / 68.0 ms. | Do not promote. Extra search and current ranking did not buy a convincing quality improvement. |
| Exact-prefix logit cache | Preserved outputs after a cancellation fix; improved some repeated/continuing edits, but held-out dynamic p95 worsened 116.9 → 139.1 ms. | Keep disabled. Any revisit must isolate invalidation costs and incremental benefit beyond the existing suggestion cache. |
| Boundary-mass gate plus guarded stopping | 369 → 394 exact first words out of 1,361; mean 37.0 → 29.1 ms. Matching reference characters fell 3.7%, and blind usefulness was inconclusive. | Not an overall replacement. Better single-word matching was not equivalent to better whole suggestions. |
| Guarded display stopping alone | Preserved tested text/suppression; saved 3.3 ms static mean. Dynamic mean improved, but pooled p95 worsened 116.8 → 123.5 ms. | A performance lead, not an established tail-latency win. Test separately from quality changes. |
| Selective one-word hybrid | On 738 fresh checkpoints, preserved all 306 original suggestions and added 77: Claude rated 71 helpful, six neutral, zero poor. Static mean 36.6 → 40.2 ms; p95 approximately unchanged. | Best supported decoder change for the trial. Gains are modest: 68 additions contain at most three characters. |

The fresh native hybrid result is stronger evidence than its earlier offline composition. The earlier 1,361-checkpoint corpus remains regression data: it contains two poor hybrid additions in Serbian, and the hybrid still retains the original decoder's weak suggestions. Dynamic typing speed improvement for the hybrid was inconclusive. Its final-only publication also needs first-visible measurement before making a responsiveness claim.

Nine decoder changes were explored, including greedy sampling, repetition-penalty removal, a larger token budget, ungated output, reranking and confidence variants. None justifies enabling wider search or increasing generation length by default. We must not assign the faster boundary-mass variant's latency to the quality-selected hybrid.

Sources: [candidate search](../2026-10-10-candidates-master/REPORT.md), [cache](../2026-10-10-cache/REPORT.md), [nine-attempt loop](../2026-10-10-decoder-loop/REPORT.md), [blind policy judge](../2026-10-10-claude-judge/REPORT.md), [native hybrid](../2026-10-10-native-hybrid/REPORT.md).

## What the five alternative models add

All rows below use the hybrid and the same 320 screening checkpoints. Long-context latency comes from a separate 32-case stress workload and must not be combined into one average with short-prefix latency.

| Model | Useful / poor out of 320 | Mean utility | Short mean / p95 | Long-context mean | Assessment |
|---|---:|---:|---:|---:|---|
| Gemma E2B | 159 / 31 | 0.603 | 46.1 / 81.2 ms | 63.5 ms | Best current balance for this multilingual trial |
| LFM2.5 1.2B Base | 111 / 64 | 0.172 | 18.2 / 34.9 ms | 106.1 ms | Fastest short calls, substantial quality loss |
| Qwen3.5 2B Base | 142 / 34 | 0.472 | 32.1 / 53.8 ms | 158.2 ms | Smaller/faster short calls, lower utility and slower long prefixes |
| LFM2.5 2.6B Base | 131 / 44 | 0.353 | 38.6 / 64.1 ms | 233.4 ms | No compelling quality/latency tradeoff in this runtime |
| Gemma E4B Base | 161 / 30 | 0.634 | 69.1 / 123.6 ms | 106.6 ms | Small, uncertain quality gain for the extra cost |
| Gemma E4B Luchador | 218 / 27 | 0.947 | 76.1 / 121.2 ms | 120.3 ms | Clear quality finalist; language and latency qualifications apply |

The smaller LFM/Qwen models are still potentially relevant if minimum memory is the main objective. They are not quality upgrades on this measured workload. Their long-context mean reversal is consistent with the current runtime fully reprocessing recurrent/hybrid prefixes; it does not establish that those architectures are intrinsically slower.

Luchador's file is 6.33 GB versus E2B's 3.85 GB. On fresh long-context transitions, Luchador averaged 474 ms versus 216 ms for E2B; with a shared context, 84 ms versus 48 ms. Existing focus prewarm may hide some transition work, but the study did not measure that in the UI. The 510 ms Luchador long-context p95 is not a measured keystroke-to-overlay delay.

Source: [model report](../2026-10-10-models/REPORT.md), [screen analysis](../2026-10-10-models/screen-analysis.json), [long-context analysis](../2026-10-10-models/long-context-analysis.json), [transition timings](../2026-10-10-models/long-context-transitions.json).

## Language is the main adoption constraint

| Confirmation group | E2B hybrid useful / poor | Luchador useful / poor |
|---|---:|---:|
| English, 120 checkpoints | 67 / 10 | 90 / 5 |
| Serbian Latin, 20 checkpoints | 10 / 2 | 14 / 1 |
| Serbian Cyrillic, 20 checkpoints | 7 / 7 | 5 / 9 |

Cyrillic regressed in both screening and confirmation. Each confirmation script subgroup has only four phrases, so the size of the effect is uncertain. E2B also has substantial Cyrillic weaknesses; retaining it is a conservative choice, not a claim that it solves Serbian autocomplete.

The predeclared offline combination of Luchador for English and E2B for all Serbian produced 107 useful and 14 poor suggestions on confirmation. This used known fixture language labels. No automatic language detector, model router, dual-model memory behavior or switching latency was implemented or measured. An automatic script router should not be presented as an already validated solution.

## Ranked next steps

1. **Instrument and calibrate the two confidence gates.** Capture pre-suppression continuations, primary/fallback confidence trajectories, stop reasons and normalized output. Compare E2B hybrid and Luchador at several attainable equal word-boundary suggestion rates, separately by language/script. Keep model weights, prompt and sampler fixed; treat mid-word healing separately. The existing JSONL cannot support a complete gate sweep because suppressed alternatives and full confidence traces are missing. This is the best next engineering experiment because it tests whether the smaller model can recover part of the gain cheaply. The [risk–coverage framework](https://arxiv.org/abs/1705.08500) supports the comparison method, not a promised improvement.
2. **Run stock Gemma E4B IT as the first additional model.** Compare E4B base → [official IT](https://huggingface.co/google/gemma-4-E4B-it) → Luchador under unchanged settings, then under the separately labelled calibrated gates. This addresses whether ordinary instruction tuning explains most of the gain. Quantization remains a confound unless conversion and calibration recipes match. If stock IT retains English quality with fewer Cyrillic failures, prefer the simpler official candidate; that outcome has not been measured.
3. **Measure the actual typing experience before promotion.** Start with blinded, randomized comparisons of original E2B, hybrid E2B and the winning English-quality candidate. Measure accepted useful characters, dismissals, correction/undo and distraction, plus last-keystroke-to-first-visible and stable-suggestion p50/p95. Use the existing local privacy boundaries; external judging can continue on synthetic inputs. Automated UI tests belong on a hosted or remote runner. A human trial is more informative now than another round of the same judge on the same corpus.
4. **Target fresh-context latency, then bounded stopping.** Measure existing focus prewarm effectiveness and document-context trimming with quality checks. Separate new fields, shared-prefix typing, backspace, cancellation and recovery. Only then revisit guarded stopping; preserve normalization and the demonstrated question-continuation suppression regression. Require improvement in visible latency without worse tails or changed intended output, rather than optimizing token throughput alone.
5. **Use the rest of Claude's model queue to answer specific gaps.** Qwen3 4B Base tests an attention-only alternative; Salamandra 2B tests small European-language pretraining; YugoGPT tests Serbian specialization. Run both Serbian scripts and English controls. All three, along with stock E4B IT, are verified research candidates but unbenchmarked here. Exact proposed files and papers are in the [Claude test list](../2026-10-10-models/CLAUDE-TEST-LIST.md).

For the next calibration study, a concrete proposed design is 120 new development phrases and 120 separately sealed confirmation phrases, with 40 per English/Serbian-Latin/Serbian-Cyrillic group in each split. Freeze phrases, checkpoint selection, gate-fitting rules and decision criteria before candidate inference. Use matched coverage and phrase-level paired intervals; retain a separate reference-match score. These sample sizes are a proposed follow-up, not a power calculation or already frozen run. None of the earlier confirmation sets is still untouched.

After those steps, a short-continuation E2B adapter with balanced Serbian data and malformed/repeated-output negatives is a plausible quality/cost experiment. It is untrained and unproven. First test whether calibration or the official IT control explains the observed gain; otherwise training risks optimizing the wrong bottleneck.

## What remains interesting from Cotypist

The [installed-artifact investigation](../../../../Docs/cotypist-autocomplete-comparison-2026-10-10.md) established bounded multi-candidate search, shared sequence/cache mechanisms and conditional token-history logit adjustments. It did not establish Cotypist's live quality, exact ranking formula or speed. Our beam and cache results therefore reject these particular LokalBot experiments, not Cotypist's entire approach.

The remaining distinctive idea worth a later isolated test is a small local token-history booster for repeated names and document vocabulary, compared against LokalBot's existing accepted-example retrieval. It should use only already-authorized learning data and preserve scope, exclusion, retention and deletion behavior. This may be cheaper to investigate than a full fine-tune, but there is no measured LokalBot benefit yet.

## Interpretation and validation boundaries

- Do not pool quality scores or latency means across these studies: corpora, policies, binaries and judge sessions differ. Repeated timing runs do not create independent quality samples. This report uses within-study comparisons and the latest native confirmation where available.
- Scores are from synthetic corpora and one judge family. Earlier rejudging assigned different ratings to identical outputs; ratings are supporting evidence, not user preference. Confidence intervals over phrases do not quantify human or judge-model uncertainty.
- All quoted latency is warm final native request latency unless explicitly identified otherwise. Cold load, debounce, accessibility and overlay rendering are excluded. An original decoder's streaming capability does not establish when the coordinator publishes the text.
- Earlier stage reports describing the hybrid as uninstalled or uncommitted are historical snapshots. The later study used an immutable copy of the installed experimental Release binary. This aggregation did not recheck installation, PR or CI state, change settings, or execute more benchmarks.
- The proposed calibration, stock IT trial, human evaluation, routing, booster and fine-tune are not completed outcomes. Four added models remain queued. Only this consolidation and its source/link checks were performed in this step.
