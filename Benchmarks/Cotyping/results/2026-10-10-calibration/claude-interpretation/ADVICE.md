Historical experiment snapshot. Current adoption: **E2B remains the default; the experimental switch enables hybrid plus prefix search.** See [the trial guide](../../../../../Docs/experimental-autocomplete-hybrid.md). Complete raw evidence and the original, unedited report are in [the experiment archive](../../2026-10-10-experiments.tar.gz). Archive member paths are listed in [the manifest](../../2026-10-10-experiments-manifest.json).

# Interpretation: calibrated autocomplete study (post-hoc, no re-rating)

## 1. What the evidence supports and what it does not

**Supported, on the primary metric (word-boundary utility, matched coverage 76/128)**

- **No candidate credibly beats Luchador.** Every point estimate against Luchador is negative:
  - stock Gemma E4B IT: −0.047 [−0.125, 0.031]
  - YugoGPT7: −0.125 [−0.281, 0.031]
  - Qwen3 4B: −0.141 [−0.281, 0.008]
  - Salamandra2: −0.273 [−0.445, −0.109], the only interval that excludes zero
- **Luchador vs E2B baseline is unresolved.** The difference is +0.117 [−0.055, 0.289], with 35 wins and 29 losses. Over all checkpoints it is +0.021 [−0.177, 0.214]. Luchador is not shown to be better than E2B.
- **Calibration beats the current single gate, but only at matched holdout coverage.** E2B calibrated scored 0.586 against 0.430 for the original gate, a difference of +0.156 [0.031, 0.289].
- **The earlier large Luchador benefit was mostly about how often it suggested.** Under the old gates Luchador scored 0.891 boundary utility with 101 suggestions shown, against 0.422 with 53 for baseline. Once frequency is equalized, most of that gap disappears.

**Not supported**

- **Per-language superiority.** All confidence intervals are pooled, so no per-language claim is significant.
- **Deployable calibration.** The matched cutoffs are holdout quantiles. The frozen development cutoffs did not hold their 38/64 boundary target:
  - Luchador EN showed 32 and SR showed 42.
  - Baseline EN showed 47 and SR showed 42.
- **Human acceptance.** There is one judge, a small synthetic corpus, and no long-context latency yet.

**The EN / SR Latin tradeoff, derived from the reported totals**

| Slice | Luchador | E2B baseline |
|---|---|---|
| EN boundary | 0.750 | 0.594 |
| SR boundary | 0.656 | 0.578 |
| EN midword (≈) | 1.28 | 1.09 |
| SR midword (≈) | −0.06 (15/32 poor) | 0.47 (10/32 poor) |
| SR all checkpoints | 0.417 (20 poor) | 0.542 (12 poor) |

- Midword is always shown at 100% coverage, so this SR deficit comes from model content, not the gate.
- Stock IT shows the same SR midword weakness (≈ −0.03), which points to the E4B family rather than the fine-tune.

**Latency (mean / p95, M4 Max, short context)**

- Luchador: 74.5 / 124 ms. E2B: 53 / 83 ms.
- Midword p95: 130 ms vs 89 ms.

## 2. The Luchador-default condition

**Does it trigger?** Read literally against the predeclared metric, yes. Nothing is better than Luchador on boundary utility: no candidate's interval favors it, and every point estimate is lower. I would report that the condition triggered.

**What should accompany it**

- "Nothing is better" is not the same as "Luchador is better than the current E2B." That comparison is a statistical tie on the primary metric.
- On the secondary measures, E2B looks better on several things this user explicitly cares about, as point estimates only: SR Latin midword, SR Latin overall, and latency (about 20 ms mean, about 40 ms p95).

**Keep two decisions separate**

1. **Model choice.** Luchador is defensible as default under the user's own rule. Its SR midword weakness is the known risk.
2. **Gate deployment.** The calibrated gate is not validated as deployable. The frozen cutoffs drifted in coverage. Under them, Luchador EN boundary utility (0.672) equals baseline (0.672), and no interval was computed for that comparison. Ship any calibrated gate as provisional, or keep the current gate, until it is tested prospectively.

**An untested option to flag as a hypothesis only:** Luchador for boundaries and E2B for midword. It looks attractive post hoc, but it is selected from this data, untested as a configuration, and carries memory and load costs.

## 3. Most useful next experiments

1. **Prospective frozen-gate confirmation, weighted toward SR Latin.**
   - Use a fresh scenario set and lock the deployed cutoffs as they would ship, with no quantile matching.
   - Compare Luchador vs E2B with per-language and per-checkpoint (boundary / midword) cluster-bootstrap intervals.
   - Size it so the SR midword difference (about 0.5 utility here) can be resolved.
   - If the hybrid matters to the user, predeclare it as a third arm now rather than adopting it from this data.
   - This one experiment answers three questions: whether the default holds, whether calibration survives deployment, and whether the SR midword gap is real.
2. **Native SR Latin human check of the judge.**
   - Have the user or a native speaker blind-rate a stratified sample of SR midword and boundary candidates, roughly 60–100 items.
   - The Serbian verdicts rest entirely on one model judge. Repeat agreement (86/110 exact) is pooled and says nothing about SR-specific validity.
   - If human ratings disagree on SR midword, the tradeoff above may not be real.

The long-context latency run is still pending. The latency comparison above should be treated as short-context only until it finishes.
