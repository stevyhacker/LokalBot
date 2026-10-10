Historical experiment snapshot. Current adoption: **E2B remains the default; the experimental switch enables hybrid plus prefix search.** See [the trial guide](../../../../Docs/experimental-autocomplete-hybrid.md). Complete raw evidence and the original, unedited report are in [the experiment archive](../2026-10-10-experiments.tar.gz). Archive member paths are listed in [the manifest](../2026-10-10-experiments-manifest.json).

# Final recommendation: keep hybrid_one_word first

**Ranking for a low-distraction typing product:**
1. hybrid_one_word
2. union
3. current (the control and fallback)
4. boundary_mass
5. intersection

**Why hybrid still beats union.** Union scores higher on raw discounted utility: 125 versus 116 under the minimal-value discount, and 125 versus 94 under the short-single-word discount. That lead comes from 23 more harmful outputs (25 versus 2). In autocomplete, a wrong suggestion costs attention even when the user ignores it. Correct suggestions are only a modest benefit. Union's extra 9–31 points do not justify roughly twelve times as many harmful additions. Union remains the documented alternative if real acceptance data later shows that users tolerate noise.

**What the gain actually is.** Hybrid's advantage over current is real but small. With the discounts, the 95% CIs stay above zero, but the gain is only about 0.016–0.032 per checkpoint. Much of it is trivial: 19 of the gains are just "to" or "the," and wins drop from 77 to 42 to 20 as the discounts tighten. So hybrid is a safe, mostly incremental gain, not a major quality improvement.

**Limits of the evidence.** The scores come from one model judge, on synthetic phrases written by the same model family. There is no acceptance data. The length control was not significant, so it proves nothing. Its direction (one-word cuts of current's suggestions were more often worse) at least does not contradict hybrid's rule of leaving current's suggestions unchanged.

**Gates before any prototype claim:**
- **Parity**
  - Keep the original sampler, weights and prompt.
  - Run the full normalization and suppression pipeline first. Apply the one-word cap only to that pipeline's final output.
  - Do not stop generation early.
  - Require byte-identical parity with the offline outputs on all 1,361 checkpoints, including the 1,148 identical ones.
  - Add an explicit regression test for the early-stop/question-mark suppression bug.
- **Latency**
  - Measure the hybrid natively. The 29.1/75.4 ms figures came from a guarded-stop path that is now ruled out, so they do not carry over.
  - Gate: static and typing p50/p95 no worse than current (37.0/85.4 ms means), plus a bound on the extra cost when current is silent.
- **Confirmation**
  - Add a guard that blocks switching scripts (Cyrillic to Latin) and recheck the two Serbian losses.
  - Hold out a corpus not written by this model family, and add a second judge or human ratings.
  - Ship opt-in or shadow only, logging acceptance and dismissals against current.
  - Promote only if the harmful-output rate stays near the offline 2/104.
