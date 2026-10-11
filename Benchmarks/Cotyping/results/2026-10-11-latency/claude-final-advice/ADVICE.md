# Recommendation: Gemma E2B Q6_K Latency Work

## Fastest observed candidate
The fastest candidate is **memo + proof + 2 generation / 2 prefill threads**: 51.61 ms mean and 98.93 p95, versus a 67.04 baseline.
- That is a 23.0% mean reduction (95% CI 21.6–24.4%).
- All 1,496 paired outputs were identical.
- English and Serbian both improved.

The follow-up (51.76 ms) confirms the speed. It also shows a **cancellation-return regression**: 95.61 ms versus 80.75 current, on 12 events from one run. Two/two is the fastest configuration, but it is not the safest.

## Lowest-risk integration step
Integrate **per-request ranking memoization** behind a config flag, default off.
- It is a pure computation reuse.
- Outputs were identical everywhere, including repeats and cancellation recoveries.
- Wire generation and prefill thread counts as **separate settings**, with the current default unchanged.

This is what the evidence supports. It is not yet a reason to flip the production default.

## Thread settings
Prefer **2 generation / 14 prefill** as the candidate default.
- Normal latency: 52.73 ms, about 1 ms behind two/two.
- Cancellation return: 79.60 ms, matching current.
- Cancel + recovery: 323.26 ms, the best of the three.
- Cost: the single long-mix pass was worse (168.79 vs 162.32 ms).

Caveats:
- Both dynamic and long figures come from single passes.
- "2" is an M4 Max finding. Do not hard-code it for other chips; derive it per hardware class or measure it.

## Search-skip proof
**Keep the proof off by default** until it is ablated.
- Memo + 2 threads (51.22 ms, single pass) is indistinguishable from proof + memo + 2 (51.61 ms, three rounds).
- The proof adds correctness-sensitive logic for an unproven gain.

Leave these settings unchanged:
- **Width 2:** trends negative (−0.097, CI barely includes 0).
- **Exact-only:** clearly worse.
- **Budget 8:** has too little evidence.

## Claims you can make truthfully now
"On an M4 Max, with a frozen 144-checkpoint EN/Serbian Latin corpus, native generation latency fell about 23% with identical outputs."

Do not claim the following:
- **End-to-end gains.** Load, spelling, debounce, AX and overlay are excluded.
- **Holdout validity.** The follow-up reused the same corpus.
- **Reduced total compute from prewarm.** Prewarm only moves work, from about 219 ms to 197 ms in total.

## Next three experiments, by value

**1. Pre-registered ablation on an independent holdout corpus**
- Use newly authored or licensed/public EN and Serbian Latin text, not private writing.
- Compare {memo, memo+proof} × {14/14, 2/2, 2/14, 4/14}.
- Run at least 3 counterbalanced rounds, with dynamic and long passes repeated.
- Fix metrics and decision thresholds in advance.
- This settles the proof's contribution and the thread choice on data the configurations were not tuned on.

**2. Cancellation-to-new-suggestion benchmark**
- Run many cancellations (for example, 100 or more) across delays of 0, 5, 20 and 50 ms, in both prefill and decode phases.
- Record the issuance timestamp, return time, the GPU synchronization point and the cache-reset cost *inside* the timed window.
- Primary metric: keystroke → next visible-ready suggestion.
- This will tell you whether the two/two regression is real and where it comes from. Right now, 12 events and a pending-GPU-sync caveat do not support a mechanism claim.

**3. Hardware and conditions portability with end-to-end timing**
- Test at least one lower-core Apple Silicon machine, on battery or Low Power mode, and under background CPU load.
- Add timestamps for debounce, AX and overlay so the native gains can be stated as user-perceived latency.
- This determines whether a fixed thread count of 2 can ship as a default or must be adaptive.

Defer budget-8 and width changes until a dedicated quality evaluation has enough power to detect small regressions.
