Historical experiment snapshot. Current adoption: **E2B remains the default; the experimental switch enables hybrid plus prefix search.** See [the trial guide](../../../../Docs/experimental-autocomplete-hybrid.md). Complete raw evidence and the original, unedited report are in [the experiment archive](../2026-10-10-experiments.tar.gz). Archive member paths are listed in [the manifest](../2026-10-10-experiments-manifest.json).

**Serbian Latin midword completion: fixed-prompt confirmation, 10 October 2026**

Bounded search through the typed fragment improved Claude-rated Serbian Latin suggestions for both E2B and Luchador. The native sampled engine now selects this path in source. The installed app, saved model choice, draft PR and its CI were not changed. [Exact examples](EXAMPLES.md) include regressions as well as wins.

The old decoder greedily chose each token while reconstructing the already typed fragment. Locally plausible pieces sometimes produced malformed word completions. The fix compares up to four compatible paths using summed raw log probabilities, includes the exact old path, and falls back to it after 32 search expansions. It replays the selected path before ordinary sampling. If the first old token already covers the fragment, it skips the search. It preserves the typed UTF-8 bytes; the search does not score or generate free continuation tokens. Word-boundary behavior stays identical.

The first candidate, atomic last-token healing, failed a separate fresh evaluation and was rejected. Its corpus then became development data. After Claude’s methodological advice, the prefix-search candidate and acceptance guards were frozen before evaluating the second, independent confirmation corpus. See the [rejected experiment](../2026-10-10-midword/REPORT.md), [Claude advice](../2026-10-10-midword/claude-next-advice/ADVICE.md), [frozen plan](plan.json) and [frozen decision](decision.json).

The confirmation uses 48 new paired English/Serbian Latin scenarios: 96 sentences and 288 checkpoints, with 48 word-boundary and 96 midword checkpoints per language. Every arm shows exactly 250/288 suggestions (86.8%), 125/144 in each language: 29/48 word boundaries plus all 96 midword cases. No malformed midword output was removed to equalize frequency. No Cyrillic cases are included.

Raw production prompt bytes match across all four arms and all timing rounds. Model weights, hybrid behavior, sampler and budgets are fixed: temperature 0.1, top-p 0.7, top-k 20, min-p 0.08, repetition penalty 1.05, seed 0xC0FFEE, six free tokens and at most four displayed words. Per-language/model confidence quantiles set the boundary quota, using no quality labels and the previously selected fallback/primary ratio 3.1. Control and fixed decoders use identical cutoffs within each model/language. These transductive quantiles are evaluation controls, not deployed calibration or acceptance probabilities. Production spelling verdicts are resolved once and frozen for every arm.

Fresh Claude Opus 5.5 judgments were blind to model, implementation and latency. Only synthetic typed prefixes and anonymous continuations went to Claude; intended future text, source code and private writing did not. Identical suggestions share one rating. All 25 batches completed, covering 268 nonempty cases and 24 reverse-order repeat cases. Silence is utility 0; useful means utility +1/+2, poor means −1/−2. These are ratings of the visible suggestion, with separate first-word scores, not exact-reference accuracy.

| Model / decoder | English useful / poor (96 midword) | Serbian Latin useful / poor (96 midword) | All useful / poor (250 shown) |
|---|---:|---:|---:|
| E2B · previous | 71 / 17 | 61 / 33 | 170 / 61 |
| E2B · prefix search | 81 / 7 | 74 / 17 | 193 / 35 |
| Luchador · previous | 90 / 3 | 55 / 39 | 188 / 51 |
| Luchador · prefix search | 90 / 3 | 68 / 25 | 201 / 37 |

For Serbian midword, useful suggestions rise by 13/96 for each model. Poor suggestions fall 33→17 for E2B (48.5% fewer) and 39→25 for Luchador (35.9% fewer). E2B’s English useful count rises 71→81; Luchador stays 90→90. This is an aggregate improvement, not a guarantee for every prefix: Luchador changes a good `longer rope.` to malformed `longet for a chicken.`, and E2B changes good `otvorena pitanja.` to awkward `otvorenija pitanja.` in the examples.

| Paired utility change (−2…+2 scale) | Mean change | 95% clustered interval |
|---|---:|---:|
| E2B fix · Serbian midword | +0.542 | [+0.229, +0.854] |
| Luchador fix · Serbian midword | +0.448 | [+0.229, +0.677] |
| E2B fix · English midword | +0.354 | [+0.156, +0.583] |
| Luchador fix · English midword | -0.010 | [-0.125, +0.094] |
| Fixed Luchador minus fixed E2B · all | +0.056 | [-0.104, +0.222] |
| Fixed Luchador minus fixed E2B · English | +0.264 | [+0.132, +0.396] |
| Fixed Luchador minus fixed E2B · Serbian Latin | -0.153 | [-0.431, +0.139] |

Intervals use 5,000 paired bootstrap resamples over 48 scenario clusters, keeping translations and nearby checkpoints together. They are conditional on this synthetic corpus, fitted quotas and one judge. Repeat ratings agree exactly on 25/43 options (58.1%) and in sign on 35/43 (81.4%); this is meaningful judge noise. English non-inferiority was only a preregistered point-count guard, not a powered formal trial.

Latency was measured in three serial rounds with varied arm order on an Apple M4 Max with 48 GiB, macOS 27.0.1, on AC power. Each arm has 864 measured requests; eight warmups per process were excluded. All 3,456 measured requests match the reconstructed confidence-trace result, with no output drift between timing rounds. Both tracing modes were off during timing. This covers native generation, healing and normalization; it excludes model loading, spelling classification, debounce, accessibility work, overlay display and human acceptance.

| Model / decoder | Mean / p50 / p95, all requests (ms) | Serbian midword mean / p95 (ms) |
|---|---:|---:|
| E2B · previous | 55.3 / 60.3 / 88.4 | 65.2 / 98.0 |
| E2B · prefix search | 71.0 / 65.8 / 145.4 | 100.6 / 167.7 |
| Luchador · previous | 85.5 / 85.4 / 140.0 | 101.8 / 150.7 |
| Luchador · prefix search | 100.4 / 93.6 / 224.2 | 147.3 / 251.7 |

The all-request mean cost is +15.7 ms (+28.4%) for E2B and +14.9 ms (+17.4%) for Luchador. Both pass the frozen all-request limits of mean below 1.5× control and p95 below 250 ms. The cost is concentrated in Serbian midword: +35.4 ms for E2B and +45.5 ms for Luchador. Luchador’s Serbian midword p95 is 251.7 ms, slightly above that overall threshold; this tail should remain visible when choosing a model.

A separate 32-request-per-arm long-document diagnostic used 16 fresh/shared cache pairs. It is one timing round with no judged-quality or equal-frequency ranking claim. Native prompt limits still apply; warmups do not count.

| Model / decoder | Fresh-context mean / p95 (ms) | Shared-context mean / p95 (ms) |
|---|---:|---:|
| E2B · previous | 251.4 / 317.7 | 45.0 / 76.5 |
| E2B · prefix search | 262.0 / 356.9 | 56.8 / 125.9 |
| Luchador · previous | 464.1 / 608.1 | 70.3 / 150.3 |
| Luchador · prefix search | 483.3 / 724.3 | 89.0 / 214.1 |

The fix is worth keeping for both models. Fixed Luchador remains the English quality leader in this sample. Fixed E2B is about 29% faster overall and has better Serbian point estimates; the model-to-model Serbian interval still overlaps zero. Luchador’s overall utility advantage is only +0.056 with an interval spanning zero, so this experiment does not establish one universal model winner. For balanced English/Serbian Latin use, E2B deserves a real typing trial alongside the previously selected Luchador candidate before changing a saved default.

The next quality experiment should target residual malformed first words and distracting unfinished tails, evaluated separately at the same frequency. A Serbian lexicon or stronger suppression rule can falsely reject inflections and names; measure those losses before adopting one. For speed, reuse shared-prefix work or batch prefix-search branches, requiring byte-for-byte parity on the saved outputs and a new latency run. Real acceptance/dismissal measurements and human Serbian ratings should then decide which model earns the default. These follow-ups were not implemented in this task.

Validation completed: Release app build; 117 focused non-UI Swift tests; six tests in the affected native class rerun after the final regression assertions; 61 Python tests; full-repository strict SwiftLint with caching disabled; and clean diff whitespace checks. The semantic `usisivač` regression fails with the old decoder forced, then passes with the fix enabled. Tests also check prewarm parity, UTF-8 handling, baseline-path parity, the search cap and cold rescoring after cache rollback on long input. The earlier full test pass and final six-test rerun are not 123 distinct tests. No local UI tests were run.

The implementation uses the existing native sequence with checked rewind and full-prefill fallback, then replays the chosen tokens. It does not use a scratch sequence. Width-four pruning makes it a bounded heuristic; diagnostic certification is relative to the allowed candidate policy, not a global optimality promise. Recurrent/hybrid state models and the opt-in logit-cache experiment retain their previous path. The headless `healingMode: "wordBoundary"` control reproduces the prior decoder.

The research worktree contains earlier experimental changes and unrelated work. [This request’s Swift patch (archive)](../2026-10-10-experiments.tar.gz) is isolated against snapshots from before the request. App source hashes still match the Release build used in all evals; the final test-only additions have their own [manifest (archive)](../2026-10-10-experiments.tar.gz). No app reinstall, release, commit, PR update or CI action was performed in this request.

Evidence: [analysis](analysis.json), [raw utility scores](utilities.json), [frequency cutoffs](matched.json), [guard results](selection.json), [validation](validation.json), [judge protocol (archive)](../2026-10-10-experiments.tar.gz), [judge repeats (archive)](../2026-10-10-experiments.tar.gz), [timing order](timing-plan.json), [long-context diagnostic](long-analysis.json), [binary pin](binary.json), [source manifest](source-manifest.json), [hardware](hardware.json). Native observations, inputs, prompt bytes, timings and per-run receipts are retained in each `fresh-matched-*` folder.

| Model | Quantization | File SHA-256 |
|---|---|---|
| Gemma 4 E2B | Q6_K | `20f49b221691c71d955e1d5a840b6e26329db4a5e1626f702fa4226e80a9c629` |
| Gemma 4 E4B Luchador | Q6_K | `40e7b137e3867acb2b2991e6bedc5f140f3a4f8a89083087fd0ef24d1a698358` |

The two weight files are unchanged from the preceding study. [Model pins](models.json) and [verified hashes](verified-models.json) record exact paths, sizes and available repository revisions.
