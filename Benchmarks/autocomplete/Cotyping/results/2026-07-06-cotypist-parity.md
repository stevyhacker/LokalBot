# Cotypist parity — mid-word completion fix + evaluation model (2026-07-06)

## What changed

LokalBot never completed a partly-typed word ("follo" → nothing, or a bare
spell-fix), while Cotypist snaps to the word you mean. Three stacked causes,
all fixed:

1. **Typo gate shadowed the LLM.** With autocorrect on (default), any mid-word
   fragment NSSpellChecker flags ("follo", "conversati") was intercepted before
   generation — correction offer or full suppression. Now a fragment that is a
   live prefix of a real word proceeds to the LLM
   (`CotypingSpellChecker.isCompletableWordPrefix` + `CotypingTypoGate`);
   only un-completable fragments ("recieve") keep the inline fix.
2. **No token healing.** Prompts ending mid-word tokenize unnaturally, so the
   model often continued with a new word (`follo` + " up"). The in-process
   runtime now cuts the prompt at the word boundary and decodes the cut bytes
   as a required prefix — Cotypist's own mechanism (its binary:
   `requiredPrefix`/`remainingRequiredPrefix`) — then generates free
   (`CotypingTokenHealing`, `LlamaCotypingRuntime.generate(requiredPrefixUTF8:)`).
3. **No output guard.** On the HTTP fallback, a whitespace-leading completion
   after a non-word fragment is now suppressed (`wordCompletionMismatch`)
   instead of shown broken.

## Engine benchmark (28 scenarios, `LokalBot --cotyping-bench`)

Model: gemma-4-E4B-it-UD-Q5_K_XL (in-process, M4 Max). Raw JSON:
`2026-07-06-engine-bench.json`.

- **Safety: 28/28** · scenario pass (safety + latency): 25/28
- **Word completions extending the typed word: 12/13** (13th = allowed
  suppression on the strictly-inside-word safety case)
- **Latency: avg 459 ms · p95 1798 ms** (steady-state ~200 ms; latency misses
  are the cold-load first scenario and two ~1.5–1.8 s cases)

| Scenario | Fragment | Ghost text produced |
|---|---|---|
| wc-follow | `follo` | `w up on` |
| wc-conversation | `conversati` | `on next week!` |
| wc-tomorrow | `tomorro` | `w.` |
| wc-receive | `recei` | `ve this.` |
| wc-productive | `producti` | `ve standup.` |
| wc-schedule | `schedu` | `le.` |
| wc-important | `importa` | `nt.` |
| wc-weekend | `weeke` | `nd!` |
| wc-around | `aro` | `und $1.2M` |
| wc-german | `Unterstüt` | `zung.` |
| wc-long-context | `revie` | `w these items?` |
| mid-word-budget | `bud` (+`get…` after caret) | `get review is` |
| valid-fragment-don | `don` | `'t worry.` |

## Same model as Cotypist: base vs instruct (measured)

Cotypist's exact GGUF (`gemma-4-E4B-UD-Q5_K_XL`, base) was cloned into
LokalBot's model store, registered as the custom entry
`gemma4-e4b-base-q5-xl`, and run through the identical pipeline and scenarios
(raw JSON: `2026-07-06-engine-bench-base-model.json`):

| Model | Safety | Word completions | avg | p95 |
|---|---|---|---|---|
| Instruct `-it` (LokalBot default) | 28/28 | **12/13** | 459 ms | 1798 ms |
| Base (Cotypist's file) | 26/28 | 10/13 | 564 ms | 2393 ms |

The base variant misspells across the healed boundary (`tomorro` → `ur.`,
`schedu` → `al.`) where instruct completes correctly (`w.`, `le.`). Both runs
include the word-extending-overshoot preference (below). Conclusion: in
LokalBot's pipeline the **instruct tune is strictly better** — Cotypist's
quality does not come from the base variant. Both entries remain selectable in
Settings → Cotyping → Model.

During the base-model investigation the constrained decode also gained
Cotypist's transition-expansion behavior: when the typed fragment is not a
valid standalone word, candidates that merely land exactly on the caret are
parked in favor of one that keeps spelling the word across the boundary
(`preferWordExtendingOvershoot` in `LlamaCotypingRuntime`).

## Cotypist research notes

- Runs llama.cpp in-process with **Gemma 4 E4B `UD-Q5_K_XL` (base, no `-it`)**
  — measured above: in LokalBot's pipeline the instruct variant outperforms it.
- Binary strings confirm beam-style candidate search
  (`SequenceCandidate`, `groupedByPrefix`, `minBranchProbability`,
  `maxSearchWidth`) on top of the required-prefix constraint — that is how it
  re-serves an alternative instantly when typing diverges. LokalBot regenerates
  instead (KV-reused, ~200 ms steady-state); beams are a possible follow-up.
- Autocorrect compares `originalLogprob` vs `correctedLogprob` (model-based),
  offering `correctionText` + `continuationText` together.

## Side-by-side GUI capture (25 prompts, `Benchmarks/autocomplete/Cotyping/prompts.tsv`)

Ready to run; needs two one-click macOS consents that only a human can give
(Automation: Terminal → TextEdit and Terminal → System Events — earlier
prompts timed out unattended and were recorded as denials, already cleared
with `tccutil reset AppleEvents com.apple.Terminal`). To run:

1. Double-click `Scripts/cotyping/cotyping-capture-preflight.command` (or
   `open -a Terminal Scripts/cotyping/cotyping-capture-preflight.command`).
2. Click **Allow** on both dialogs; the script verifies each grant.
3. It then auto-runs `Scripts/cotyping/run-cotyping-side-by-side.command`: installs the
   current build, drives Cotypist and LokalBot one at a time through the 25
   manifest prompts in TextEdit (~10 min, hands off the keyboard), Tab-accepts
   each suggestion, and merges the report into this folder via
   `side_by_side.py` (engine JSON folded in automatically).

The engine columns above are already final; the GUI leg adds Cotypist's
inserted text per prompt for the same manifest.
