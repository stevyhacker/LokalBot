# Critique and plan for the prefix-search latency arms

## Bottom line

The arm set is sound, and keeping changed variants out of immediate adoption is the right gate. Make three changes before running it:

1. **Tighten arm 1's "already identical" check.** Matching token IDs does not mean the logits buffer is valid.
2. **Key arm 2's memo on the exact candidate set the search consumes.** Raw top-(width+1) is not enough if fragment filtering or suppression comes first.
3. **Add an A/A determinism control and a per-stage latency breakdown.** Without them, parity failures and timing deltas can't be interpreted.

Also add one exact arm that may beat all of these: a **certified search skip**, which uses the memoized baseline log probabilities to prove that no branch can win.

## Correctness critique

**Arm 1: skip restore when physical tokens match the target**
- **The logits buffer is the real hazard.** Token-ID equality says nothing about which position the current logits came from. After any branch decode, the buffer holds that branch's last-position output.
  - Skip the restore only if the last successful decode produced logits for exactly the target's final position, in this request.
  - Track this with a "logits valid for (sequence, position, token)" tag. Invalidate it on every decode, `seq_rm`, failure, and cancellation.
- **The mirror must be authoritative.** Update the physical-token mirror only after a decode succeeds. A failed or cancelled decode should mark the mirror unknown, not leave it half-advanced.
  - "Equal" must also mean no extra cells beyond the target. An overshoot still needs `seq_rm`.
- **Batch vs single-token floating point.** Metal kernels differ between batch size 1 and larger batches (mat-vec vs mat-mat, attention tiling, reduction order). So KV values and logits from a prefill batch are not guaranteed to be bitwise equal to incremental decode.
  - Today's restore recomputes the last position single-token. If that position was originally produced inside a prefill batch, skipping the restore changes the numerical path.
  - Record a provenance bit (computed via batch or via single-token) and log it with any parity diff.
  - With raw summed log probabilities and a 0.0001 margin, near-ties can flip. Log the minimum winner-vs-runner-up gap per case so you can see how close each case came.
- **The final sampler replay must be unaffected.** Confirm that skipping restore changes no sampler state (penalty history, RNG, grammar) before the replay.

**Arm 2: per-request memo of baseline top-k IDs and log probabilities**
- **Memoize what the expansion actually consumes.** If the search filters candidates for consistency with the typed fragment, or applies suppression, before taking the top width, then raw top-(width+1) can miss the compatible tokens.
  - Store the post-filter, post-suppression candidate list in its exact order, with deterministic tie-breaking, e.g. a stable sort by token ID.
- **Use the same normalization.** Compute log-softmax over the full vocabulary with the same function and precision the search uses. Don't renormalize over the stored top-k.
- **Key on more than the request.** Use (request ID, full prompt+path token sequence, suppression state, width). Never let entries outlive the request, including on cancellation.
- **Expected parity.** The baseline values come from incremental single-token decode on the same KV, so they should match the search's recomputation bitwise, except when restore fell back to full prefill.
  - Any diff should appear only in fallback cases. If it appears elsewhere, there is a bug.
  - In fallback cases the memo is arguably more self-consistent. It still counts as an output change under your rule.

**Arms 3–5 (width 2, budget 8, exact-prefix-only)** are expected to change outputs. Classify them as research from the start and don't spend parity effort on them.

**Arm 6 (CPU threads)**
- With full Metal offload, a thread count of 14 can hurt through efficiency-core scheduling and spin contention. Set the thread count and the batch thread count separately.
- Still check parity: any op that runs on the CPU can change reduction order.
- Control power and thermal state: on AC power, Low Power Mode off, the same background load for every arm.

## Missed necessary experiments

1. **A/A determinism control.** Run the reference build twice, interleaved, under identical conditions.
   - If the reference itself isn't bitwise stable, including after long-context prewarm and cancellation recovery, "zero output change" has no meaning.
   - Do this first.
2. **Per-stage latency and deterministic counters.** For each request, record:
   - prefill, baseline, search, restores, replay, and total time;
   - expansions used, decode calls, tokens decoded, prefill fallbacks, restore skips, and budget exhaustions.
   - Counters are noise-free and explain the p95. Find out whether the 145 ms tail comes from budget exhaustion, prefill fallbacks, or long fragments.
3. **Replay cost when the baseline wins.** If the winner is the baseline path (probably the common case), the final replay may redo work that is already correct.
   - A guarded "skip replay when winner == baseline and KV and sampler state are verified" check is a candidate exact arm.
4. **Serbian Latin test coverage.**
   - Fragments ending in č, ć, š, ž, đ (multibyte UTF-8, possibly split across tokens).
   - The digraphs lj, nj, dž, and "dj" vs "đ".
   - Diacritic-free typing such as "sta" for "šta", which many users type in practice.
   - Mixed English/Serbian contexts.
5. **Fault injection.** Cancel during restore, during prefill fallback, and during replay. Force a decode failure. Each time, verify that the next request matches the cold reference.
6. **Paired statistics.** Report per-case paired deltas with bootstrap confidence intervals on p50, p95, and p99, not just mean and p95.

## Recommended additional exact arm: certified search skip

All search scores are sums of non-positive log probabilities. Any alternative path first diverges from the baseline at some step *i*, so its score is bounded:

> score(alt) ≤ baseline_prefix_score(*i*) + logp(best alternative candidate at *i*)

If the baseline's total score beats every such bound by more than the selection margin, the current search must return the baseline, whether by finding it or by budget-exhaustion fallback. In that case you can skip the search entirely. Arm 2's memo provides exactly the inputs needed.

- **Why it may be the biggest win:** it could remove the search from many English requests at no quality cost. That depends on how often the bound holds. Measure the hit rate; don't assume it.
- **Validity conditions:**
  - Use the same filtered, width-limited candidate set the search uses.
  - Match the margin and tie direction exactly.
  - Confirm that paths shorter than the baseline obey the same bound.
- **Also check the search's own termination.** Confirm it stops as soon as the retained baseline is the best item in the frontier.
  - If you add pruning below baseline − margin, it can change which cases exhaust the budget. That makes it an output change unless budget accounting is preserved.

## If the planned arms fail to cut latency

Next bounded steps, in order:

1. **Certified skip** (above). Exact, small, and directly targets the cost of running the search at all.
2. **Use the latency breakdown to aim.** If prefill fallback dominates the tail, make restores incremental-only with a provenance check. If replay dominates, try the guarded replay skip.
3. **Research only: search gating.** Run the search only when the fragment is ambiguous, e.g. a low baseline first-step margin, or diacritic-ambiguous Serbian. This changes outputs and needs blinded judging.
4. **Research, UX-facing: progressive refinement.** Show the baseline result immediately and swap in the search result if it arrives before a deadline. This changes visible behavior and introduces flicker risk, so it needs real-typing evaluation, not just headless runs.

## Feasible now vs large projects

| Feasible, bounded, mostly exact | Large or multi-sequence/training |
|---|---|
| A/A control, counters, stage timing | Batched branches with multiple sequences in one decode (different kernel shapes, so outputs will change bitwise; needs its own quality evaluation) |
| Arms 1, 2, 6 with the fixes above | Shared-prefix KV via `seq_cp` with unified cache management |
| Certified skip; guarded replay skip | Local token-history booster (changes the distribution; privacy and storage design needed) |
| Cancellation/fault-injection recovery tests | Fine-tuning E2B on English/Serbian typing data (data, evaluation, and redistribution work) |
| Width-2, budget-8, exact-only as blinded research | Focus prewarm beyond parity testing (lifecycle and power implications) |

## Practical recommendation

1. Run the A/A control first.
2. Then run arms 1, 2, and 6, plus the certified skip, with logits-validity tagging, a post-filter memo key, provenance logging, and per-stage counters.
3. Adopt only the arms with bitwise parity across the 288 regression cases and the new English/Serbian Latin set, including the prewarm, edit/backspace, and cancellation-recovery scenarios.
4. Use the counters to decide whether the remaining p95 gap is search frequency (fix: certified skip or gating) or restore/replay overhead (fix: provenance-aware restore, replay skip).
5. Defer batched branches and fine-tuning until the bounded exact work has been exhausted.
