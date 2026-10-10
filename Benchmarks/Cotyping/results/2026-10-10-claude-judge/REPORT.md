Historical experiment snapshot. Current adoption: **E2B remains the default; the experimental switch enables hybrid plus prefix search.** See [the trial guide](../../../../Docs/experimental-autocomplete-hybrid.md). Complete raw evidence and the original, unedited report are in [the experiment archive](../2026-10-10-experiments.tar.gz). Archive member paths are listed in [the manifest](../2026-10-10-experiments-manifest.json).

# Claude Opus judge: autocomplete policies — 2026-10-10

**Decision:** prototype the selective one-word fallback hybrid next. Preserve every current suggestion exactly. When the current decoder is silent and the boundary-mass gate admits a suggestion, show only its first complete word. This is an incremental candidate for a low-distraction typing product; it is not a verified production improvement.

Claude Opus (`claude-opus-5-5`, verified in every response) rated anonymous actual continuations. Its final recommendation remains hybrid, union, current, boundary-mass, then intersection. The gate switch alone did not establish better usefulness. The hybrid and set-combination policies are **offline compositions**: their native latency and production behavior are not established. Production code, defaults, and installed app were not changed for this judging task.

All five policies were frozen before judging. The input is the same 1,361 checkpoints from 112 synthetic English/Serbian phrases used in the [native decoder experiment](../2026-10-10-decoder-loop/REPORT.md). Every one of the 213 changed decisions was judged, plus 96 shared shown suggestions (twelve per category). Another 32 cases repeated with anonymous new IDs and reversed alternative order. The judge saw only the already-typed prefix and anonymous continuation options: no future reference, model probabilities, decoder labels, benchmark success claims, or latency. It had no tools, MCP servers, source access, or session persistence. Only synthetic text was sent under the user’s explicit request.

## Primary blinded ratings

Utility is an ordinal −2 to +2 judgment relative to silence at zero. The rubric considers the whole visible text, with Tab accepting one word. Positive means worth showing, negative means weak/disruptive, and zero means neutral. These are one model’s opinions, not acceptance probabilities or observed user harm.

| Policy | Better than current | Worse than current | Tied | Helpful / unhelpful on changed cases | Utility total on changed cases |
| --- | ---: | ---: | ---: | ---: | ---: |
| Current | 0 | 0 | 213 | 67 / 35 | 72 |
| Boundary mass + guarded stop | 102 | 92 | 19 | 67 / 25 | 53 |
| Both gates must show | 35 | 67 | 111 | 0 / 0 | 0 |
| Either gate; full suggestion | 67 | 25 | 121 | 134 / 60 | 125 |
| Keep current; new-only gets one word | 77 | 2 | 134 | 144 / 37 | 151 |

This table covers the 213 changed decisions. Another 1,148 cases are identical under all five policies and contribute zero to relative utility. Current shows 638 suggestions overall, boundary mass 633, intersection 529, and union/hybrid 742. The hybrid adds 104 suggestions while retaining all existing ones; the original 35 unhelpful suggestions in the changed-case table are still present. Its two regressions are additional unhelpful outputs, not its total bad-output count.

Over all 1,361 checkpoints, hybrid’s mean utility delta is **+0.058**, whole-phrase bootstrap 95% interval **+0.045 to +0.072**. Union is **+0.039** [**+0.021, +0.058**]. Boundary mass is **−0.014** [**−0.040, +0.014**], so superiority or non-inferiority is not established. Hybrid versus union is **+0.019** [**+0.0007, +0.039**], a fragile edge without correction for multiple comparisons. These intervals resample the 112 phrases with their checkpoints grouped; they do not capture judge-model or human uncertainty.

## How large is the gain?

The 104 new hybrid suggestions receive **73 small gains (+1), 4 larger gains (+2), 25 neutral ratings, and 2 weak ratings (−1)**. Nineteen positive cases are merely “to” or “the”. The four +2 cases complete “next” with “week”, “The app keeps” with “crashing”, “stop by the” with “store”, and “water the” with “plants”. This is next-word assistance, not evidence of substantially better sentence writing.

Claude requested two sensitivity checks. Neither changes the frozen primary scores or policies.

| Post-hoc discount | Hybrid improvements / regressions vs current | Hybrid utility total | Union utility total | Current utility total |
| --- | ---: | ---: | ---: | ---: |
| Zero positive credit for judge-flagged minimal value | 42 / 2 | 116 | 125 | 72 |
| Zero positive credit for any single word of 3 characters or fewer | 20 / 2 | 94 | 125 | 72 |

The hybrid remains above current under both discounts, but **union ranks higher on discounted summed utility**. Therefore hybrid is not the universal score winner. Claude still recommends it for a low-distraction product because full union adds 25 unhelpful suggestions versus two for the hybrid. That is an explicit product tradeoff, not a statistically proven universal preference.

## Length-control diagnostic

We also asked Claude to compare current’s full suggestions with their first-word-only versions, anonymously and with the same rubric. All 109 current-only cases and the 96 already-sampled shared cases were eligible. Seventeen had identical full/capped text; 188 cases required new ratings. This is a post-hoc diagnostic, not a new population-weighted confirmation.

Across 205 cases, shortening current’s suggestions was **better in 46, worse in 82, and tied in 77**. Mean utility change is -0.083, phrase-bootstrap 95% interval [-0.228, 0.067]. The average difference is inconclusive. On the 109 current-only cases it helps 19 and hurts 44. The results do not establish that one-word suggestions are always preferred, but also do not eliminate all judge length bias.

## Concrete judgments

Below are exact saved outputs. “Silent” means no suggestion. These examples illustrate the recommendation and remaining failures; they are not an independently selected quality sample.

| Typed prefix | Current | Boundary-mass output | Hybrid | Claude utility: current / new / hybrid |
| --- | --- | --- | --- | ---: |
| Please review the attached draft and send | me your comments. | Silent | me your comments. | 2 / 0 / 2 |
| We're out of milk, so I'll stop by the | Silent | store on my way | store | 0 / 2 / 2 |
| The build failed again because someone forgot to update | Silent | the . | the | 0 / -2 / 1 |
| I'm trying | Silent | to get a 198 | to | 0 / -2 / 1 |
| Библиотека ради дуже током испитног | Silent | roka, a i za | roka | 0 / -1 / -1 |

Both hybrid regressions are Serbian: “је” after a clause that already contains its auxiliary, and Latin “roka” after a Cyrillic prefix. A script-preservation rule is a separate untested candidate; account for legitimate names, technical tokens, and intentionally mixed scripts. Do not encode an exception for the one observed auxiliary.

## Reliability and limits

- The 32 repeated cases contain 44 distinct nonempty options. Exact utility agreement is **72.7%**; agreement on positive utility (“worth showing”) is **90.9%**. All utility disagreements are one point. Do not read these as 90.9% human agreement.
- One primary shared case had a neutral option tied with silence but the reported preference listed only silence. Numeric ratings were preserved; excluding the inconsistent case does not change any policy comparison. The first validation pass rejected this redundant preference inconsistency; no replacement model judgment was requested. All primary, repeat, and length-control ratings were ultimately validated.
- The 96 shared shown suggestions contain 74 helpful, 13 unhelpful, and 9 neutral ratings. They are sampled equally by category and are not a population-weighted absolute quality estimate.
- The original phrases were authored by the same model family in an independent session. The judge never saw the hidden reference, but same-family author/judge bias remains. This is not a human study or a fresh corpus relative to the preceding decoder study.
- The primary comparison evaluates five display policies derived from the two confirmed decoder outputs. It does not semantically re-evaluate every sampler and beam-search variant from the nine-attempt development loop.

## Performance and the next implementation

| Native policy already measured | Static mean / p95 | Typing mean / p95 |
| --- | ---: | ---: |
| Current | 37.05 / 79.49 ms | 85.37 / 116.76 ms |
| Boundary mass + guarded stop | 29.09 / 73.84 ms | 75.36 / 113.87 ms |
| Union, intersection, one-word fallback hybrid | Not measured | Not measured |

These timings come from the earlier native study on M4 Max with fixed Gemma E2B Q6 weights and prompt. They measure warm engine requests, not keystroke-to-overlay latency. The faster boundary gate’s timings cannot be assigned to the hybrid.

Prototype the hybrid with one token stream and two independent confidence states, keeping the original sampler, weights, and prompt. Stop for confidence only after both gates fail. Preserve the existing normalization and suppression decisions; apply the fallback cap to the final normalized suggestion. The known question-mark regression makes a new first-word early exit unsafe to assume correct. Begin with complete normalization, prove parity, then test optional early-stop optimization separately. Do not require two full model calls per keystroke.

Before promotion: require byte-identical results against these offline policy outputs on all 1,361 checkpoints and the cancellation/backspace traces; keep the current branch unchanged; reproduce the early-stop suppression regression test. Measure native static and typing p50/p95 and the extra cost of late gate failures, with a predeclared latency budget. Then use new phrases not authored by this judge family, more Serbian in both scripts, another judge or human ratings, and actual acceptance/dismissal measurements. None of those native hybrid or user-acceptance results is claimed here.

Claude’s full [final recommendation](CLAUDE-RECOMMENDATION.md) is retained verbatim. Two implementation details require care: its first advice proposed greedy sampling, which would violate the fixed-sampler experiment; and its final advice calls the previous guarded-stop path “ruled out” and cites means near a percentile gate. The existing guarded stop retained parity in the prior finite test; it is a new first-word early exit that lacks proof. Use the explicit timing table above and preserve the original sampler. Also treat its description of the hybrid as “safe” as an opinion about these ratings, not a product guarantee.

## Reproduction and validation

Use [claude_judge.py](../../claude_judge.py) and its [tests](../../test_claude_judge.py); the [README](../../README.md#blinded-usefulness-judging) documents preparation, explicit remote judging, and analysis. `protocol.json` freezes the original policy outputs, selection, rubric, ordering, and request hashes. `analysis.json` contains every changed case with scores and explanations. `raw-judging.tar.gz` retains all anonymous requests, returned judgments, repeat checks, length control, advice, paired native source observations, runner snapshots, and validation logs. The archive manifest hashes and round-trip checks every member.

**Validation:** 50 Python benchmark tests passed; `git diff --check` passed. This turn changed only benchmark tooling/documentation/results. No native source change, app build, local UI test, installation, release, commit, or push was performed. The earlier native build/tests remain evidence for the saved decoder outputs, not for an implemented hybrid.
