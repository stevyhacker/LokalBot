Historical experiment snapshot. Current adoption: **E2B remains the default; the experimental switch enables hybrid plus prefix search.** See [the trial guide](../../../../../Docs/experimental-autocomplete-hybrid.md). Complete raw evidence and the original, unedited report are in [the experiment archive](../../2026-10-10-experiments.tar.gz). Archive member paths are listed in [the manifest](../../2026-10-10-experiments-manifest.json).

# Analysis of the narrow fix: full-cover, last-token healing

## What the proposal actually does

The fragments are usually single canonical tokens that include the leading space. So "rewind last token" rewinds the same text that the current word-boundary healing rewinds. The only real change is the constraint: candidates at the rewound position become {exact fragment token} ∪ {overshoot tokens}, and partial pieces are banned.

That makes the outcome predictable per item, from one forward pass:

- **If the exact token wins the argmax**, the context is identical to canonical, so the output equals the canonical output.
- **If an overshoot token wins**, the output equals the current healing output, but only when that output also started with an overshoot.
- **Only items where current healing chose a partial piece** (e.g. `" o"` then `"st…"`) get a genuinely new result.

In effect, the proposal is a per-item switch between canonical and overshoot healing. The switch is decided by one greedy logit comparison.

## Risks

1. **Unequal comparison.** The exact token (`" mo"`) is not the probability of "the word starts with mo." It covers only continuations whose canonical tokenization keeps `" mo"` separate. Each overshoot token (`" može"`) covers one merged continuation. Greedy argmax across these is not a likelihood comparison, so which side wins will look arbitrary.
2. **Short fragments may regress to canonical failures.** `ra`, `sa`, `mo`, `po`, `ne`, `ni`, `ka` are where canonical hurt you (e.g. `ra→đanja`, `mo→ći`). If the exact token wins on those, you inherit those failures. The root cause is canonical-path bias: after `" mo"`, a model trained on canonical tokenization treats merged continuations like `že` as unlikely.
3. **Multi-token fragments.** In `svra` (the one case where lastToken differed), rewinding only the final token keeps `" sv"`. That split may not be canonical for the completed word. "Retains canonical segmentation" holds for the prefix, not for prefix + completion.
4. **Fragments that are complete words.** `sa`, `ni`, `je`, `po`, `ne` are valid Serbian words. Canonical's leading-space outputs (`" ogólnymi"`, `" cena"`) show the model reading them that way. Banning short pieces does nothing for this ambiguity.
5. **The dead branch.** With no Serbian dictionary, "known invalid word" never fires. Assert that it is a no-op, or remove it, so it doesn't confound comparisons.
6. **Problems healing can't fix.** Polish drift (`tego urządzenia`) and ijekavian/Croatian forms (`provjerim`, `cesti`) are prompt or model issues. Don't credit or blame healing for them.
7. **Sampling noise.** The six free tokens are sampled. Hidden forced steps can shift the RNG stream between variants, so some "differences" may be noise. Use greedy decoding, or a fixed seed re-synced at the first free token, or several samples per item.

## Alternatives

- **Rescoring (cheapest principled option).** Generate the canonical and healed candidates. Retokenize each full string canonically from the rewind point. Pick the one with the higher log-probability up to the next word boundary.
- **Small covering-path beam (k≈4–8).** Explore token paths that cover the fragment's bytes and compare them by total log-probability to the word boundary, not by first-token logit.
- **Canonicality-constrained decoding.** After the exact token, mask next tokens that would create a non-canonical merge. This directly targets canonical's short-fragment bias.
- **Avoid a fragment-length gate.** It is a tuning knob and invites overfitting.

## Tests that would falsify the proposal

Run all of these on the synthetic set or on new dev data, never on the frozen 48.

1. **Path audit.** Log the hidden forced path for current healing on all 32 items and classify each first token as partial, exact, or overshoot. If bad outputs like `ost→icne`, `pore→dstavljene`, `zaj→arimo`, `vis→sente`, `prim→erio` came from overshoot choices, the proposal can't change them and is falsified.
2. **Offline prediction.** At each rewound position, compute the argmax over the full-cover set. Count how often the exact token wins on short fragments where canonical was worse. A high count means it trades one failure class for another.
3. **Invariance check.** Items where current healing chose exact or overshoot must come out byte-identical. Any difference is an implementation bug.
4. **Unit tests:**
   - multibyte endings (`mož`, `če`, `zači`, `đ`)
   - NFC vs NFD input, since macOS can produce `c`+combining caron
   - `lj`/`nj`/`dž` splits
   - multi-token fragments
   - a fragment with no overshoot token (must fall back to exact)
   - fragment = complete word
   - whitespace-only boundary unchanged
5. **Canonicality rate.** Retokenize prefix + completion and report the share of non-canonical forced paths for each variant.
6. **Held-out evaluation.** Before opening the 48:
   - Pre-register the metric, rater rubric, and decision rule (e.g. paired sign test vs both baselines on SR, plus no significant EN regression).
   - Run once, report per-item wins and losses, and stop.
   - If you then change anything, you need a new held-out set.

## Bottom line

The fix is cheap and well-defined, but it is mostly a noisy selector between two existing behaviors. Run the path audit first; it tells you, without generating anything new, whether the proposal can help at all. If the audit is favorable, rescoring is likely the better next step.
