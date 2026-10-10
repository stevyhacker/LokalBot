Historical experiment snapshot. Current adoption: **E2B remains the default; the experimental switch enables hybrid plus prefix search.** See [the trial guide](../../../../../Docs/experimental-autocomplete-hybrid.md). Complete raw evidence and the original, unedited report are in [the experiment archive](../../2026-10-10-experiments.tar.gz). Archive member paths are listed in [the manifest](../../2026-10-10-experiments-manifest.json).

# Prefix-path search for midword completion: verdict, traps, and confirmation plan

## Verdict

The prefix-only search can work, and it is more defensible than atomic healing. With raw log-probabilities, each step only adds a value ≤ 0. That makes an unfinished path's current score an admissible upper bound. Best-first search with your stop rule is therefore uniform-cost search, and the first completed path it pops is the best path, if the search stayed exhaustive.

Your RNG note is a real asset. Forced accepts draw no random numbers, so the free phase consumes randomness identically across decoders. That allows paired per-item comparisons, using McNemar or a sign test on the "useful" flags.

## Correctness traps

1. **Width-4 pruning voids the guarantee.** If you drop children beyond the top 4, keep the best pruned score as an extra upper bound. If that bound beats the winner, the result is uncertified. Log the certification rate.
2. **Budget exhaustion needs a fallback.** If 32 expansions run out, or no completed path is found, fall back to the current word-boundary decoder. Never return the best partial path.
3. **Score the right distribution.** Use plain log-softmax of the raw logits (temperature 1). Do not score through temperature, top-k/top-p, penalties, or grammar. Temperature-scaled sums don't rank paths consistently when path lengths differ.
4. **Keep the sampler untouched during search.** Never call `llama_sampler_sample` inside the search. Call accept exactly once per token of the selected path, in order. This keeps repetition-penalty history identical to atomic healing.
5. **Exact and overshoot paths are not the same event.**
   - An overshoot path like "hello" for typed "hel" has already paid for extra characters.
   - An exact path has not yet paid for the rest of the word.
   - So the sum score favors exact paths. Separately, a winning overshoot token is an argmax choice of the completion, which removes sampler diversity for that word.
   - Run an "exact-only, no overshoot" ablation, and log how often overshoot wins.
6. **Non-canonical segmentations.** Paths like ["he","l"] were rarely seen in training. Add a canonicality check: re-tokenize the decoded path text and log whether it matches.
7. **Byte and Unicode details.**
   - Prefix matching must be byte-wise. Intermediate paths may hold partial UTF-8; Serbian č/ć/š/ž/đ are two bytes each, and byte-fallback tokens are possible.
   - The final path must be valid UTF-8.
   - Normalize input to NFC; macOS can deliver decomposed characters.
   - Get the leading "▁"/space marker right.
   - Exclude end-of-generation and control tokens from the search.
   - Test the rollback boundary for "(hel", "e-mail", "don'", and digits.
8. **KV cache hygiene.**
   - Run the search on scratch sequence IDs, then remove them completely with `seq_rm`.
   - Replay the chosen path into the native sequence at contiguous positions.
   - Take the first free-token logits only from that replay. Batched search logits can differ numerically from single-sequence decodes.
9. **Do-no-harm invariant.** Seed the search with the current baseline covering path as a candidate. Assert that when the search selects that path, the output is byte-identical to the baseline under the same seed. Every changed output should then trace to a strictly higher-scoring path, which makes regressions debuggable.

## Development work (on the burned corpus)

1. Trace all 16 English items per model that flipped useful → not useful under atomic healing, and check whether search recovers them.
2. Report how often the selected path differs from baseline, overshoot win rate, canonicality rate, certification rate, and decode count.
3. Run a Serbian headroom check first. Atomic healing didn't move Serbian, so tokenization may not be the bottleneck; E2B's Serbian competence may be.
   - On the poor Serbian items, compare the reference word's covering-path score against the selected path.
   - If the reference rarely wins, no prefix decoder will help, and the effort belongs elsewhere.

## Gating and latency

Don't add a Serbian gate preemptively. Measure first.

- Depth is usually 1–4 tokens. Batching each frontier into one `llama_decode` call makes it roughly 2–4 decodes plus the replay.
- Measure p50/p95 per-keystroke latency on target hardware against a fixed budget.

Consider a gate only if English shows a cost.

- Gate only if English regresses or misses the latency budget while Serbian improves.
- The gate is then part of the frozen system, so its detector errors count. Watch for code-switching, Serbian written without diacritics, and English names in Serbian text.
- Pre-register the gate rule before freezing the confirmation corpus. Choosing it after seeing results is selection on the test set.

Pre-register the decision criteria with the corpus, for each model:

- **English non-inferiority:** paired drop of no more than 2/96 useful (pick the margin now).
- **Serbian:** a paired improvement in useful, plus no increase in poor.
- **Latency:** p95 under budget.

## Dictionary validator

Treat it as the second option, not the alternative.

- Serbian inflection and proper names make false rejections expensive.
- With one fixed sample, a validator can only suppress output, not rerank.
- If you build it, use Hunspell sr-Latn with an inflection generator. Bypass capitalized tokens and tokens near mixed-script text. Use it only to suppress clearly invalid completions.
- Evaluate it as a separate, pre-registered arm. Don't stack it onto the search in the same confirmation run, or you can't attribute any gain.
