Historical experiment snapshot. Current adoption: **E2B remains the default; the experimental switch enables hybrid plus prefix search.** See [the trial guide](../../../../../Docs/experimental-autocomplete-hybrid.md). Complete raw evidence and the original, unedited report are in [the experiment archive](../../2026-10-10-experiments.tar.gz). Archive member paths are listed in [the manifest](../../2026-10-10-experiments-manifest.json).

# Recommendation: keep the E2B default; don't ship Luchador yet

**Keep the current E2B default. Don't replace it.** Luchador is a credible future opt-in for English-heavy users, not a ship-now option.

**What was measured (judge-based, not human acceptance):**
- **Overall gain:** Luchador beats the installed hybrid by +0.34 on screening and +0.375 on confirmation. Both 95% intervals exclude zero, and the confirmation split replicated.
- **English:** +0.44 to +0.47, with only 5–7 poor suggestions versus 10–21 for the baseline.
- **Gemma E4B base:** essentially tied with the baseline (+0.03, not significant). Size alone isn't the source of the gain.

**Why not replace:**

1. **Much of the gain is coverage.**
   - Luchador stays silent 51 times versus 118 for the baseline, and boundary suggestions shown nearly double (141 vs 74).
   - The rubric scores silence as 0, so showing more plausible text is rewarded.
   - Reference precision falls. First-word correct per shown suggestion is about 55% for Luchador versus 65% for the baseline, on both splits.
   - On confirmation, correct first words tie at 72 vs 72.
   - The judge prefers Luchador's text, but it matches what the writer typed less often per shown suggestion. Real acceptance could plausibly move either way.

2. **Serbian Cyrillic regresses.** It scored −0.325 and −0.2, versus +0.325 and +0.05 for the baseline, with 18 and 9 poor suggestions.
   - Serbian Latin improved (1.0–1.2 vs 0.45–0.6), but the Serbian intervals span zero with only 8–16 phrases.
   - The "language choice" policy adds almost nothing over Luchador alone (0.956 vs 0.947) because it hands back the Latin gains.
   - A **script** split (Cyrillic to E2B) fits the data better. That is post-hoc and untested, and it means either two resident models (~10 GB) or reload stalls.

3. **The long-context speed gap is a problem.** Luchador's p95 is 510 ms, versus 221 ms for the baseline. Gemma E4B base is 415 ms, so this is model class, not the fine-tune. That sits well past the ~200 ms speed cliff we saw before.

4. **Download size grows** from 3.85 GB to 6.33 GB.

**The longer-context speed reversal.** The LFMs are fastest on short prompts (LFM 1.2B averages 18 ms) but slower than E2B with long context (106 vs 64 ms). The most likely cause is the app fully reprocessing recurrent prefixes; this is a hypothesis and unconfirmed. Fixing it isn't worth prioritizing: the LFMs lose on quality anyway, and LFM 1.2B scores −0.81 on Serbian with zero useful outputs.

**Fixed thresholds across tokenizers.** The 0.1/0.31 gates on first-word probability mean different things for each model. Silence ranges from 51 to 140 across the arms, so every comparison mixes model quality with operating point. Even E2B's own variants differ by 0.06–0.08 purely through silence (no losses among shown suggestions). This is the biggest methodological gap.

**Is roleplay/writing fine-tuning transferable?** Not established.
- Luchador differs from E4B base in both post-training and quantization, so the gain can't be credited to the writing LoRA.
- Gains concentrated in conversational English (chat, email, support), which is consistent with conversational post-training. The Cyrillic loss is consistent with English-centric data.
- The recipe targets roleplay rather than prefix continuation, so further gains from domain-matched prefix-to-continuation training are a hypothesis, not evidence.

**Judge caveats:** a single model family scored everything. Self-agreement was 76% exact and 89% on sign. Treat it as a ranking signal, not acceptance.

## Next experiments, ranked

1. **Matched-coverage recalibration (quality; cheapest, most informative).**
   - Calibrate gates per model and language to equal show rates, Smart Compose-style.
   - Compare judge utility and reference precision at 2–3 matched coverage points.
   - This tells you whether Luchador is a better model or just a bolder operating point. A bolder E2B threshold might capture part of the boundary gain at no size or latency cost; that is a hypothesis.

2. **Blinded human acceptance pilot (quality, decisive).**
   - E2B vs Luchador in real typing, measuring acceptance, dismissals and keystrokes saved.
   - Include Cyrillic sessions. A model that shows more suggestions also adds distraction the judge can't see.
   - No synthetic score should substitute for this before any option ships.

3. **E4B-class long-context latency (latency, gating any option).**
   - Break down where the 510 ms p95 comes from: prefix-cache misses, prompt-processing length, and context trimming.
   - Measure how much context truncation costs in utility.
   - Recurrent-state reuse belongs here only if an LFM later becomes quality-competitive.

**Deferred:** a clean ablation (E4B base vs base plus LoRA, same quantization) and a domain fine-tune. These are worth doing only if experiments 1 and 2 show a real, human-visible gain left to explain.
