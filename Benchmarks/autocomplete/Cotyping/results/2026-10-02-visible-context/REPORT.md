# Visible context and saved memory for autocomplete — 2026-10-02

Autocomplete can now use the visible conversation or labels above the active
text field, and connect project names there to relevant saved facts. With both
sources enabled, Gemma includes the expected fact in **16/18** synthetic context
cases, versus **0/18** with neither source. LFM scores **15/18**. These measure
use of supplied facts within short completions, not user acceptance rates.

Gemma remains the source default for new settings and the Balanced preset;
saved model choices are preserved and Lightweight retains LFM. The earlier
[quality comparison](../2026-10-02-quality/REPORT.md) supports that choice:
6,667 held-out next-word checkpoints improved from **27.97% to 34.50%**, and
the matched Cotabby sample scored **32.74% versus 30.69%** with the same Gemma
weights. Those are results from the earlier frozen builds. This new context
evaluation does not extend the competitor comparison; Cotypist parity and
the three products' live typing experience remain unverified.

**Built and tested; not installed or released.** Installed preferences were
not changed. Visible context, meeting/work memory, and screen-derived work
memory each have a separate default-off control.

## Product behavior

Under Settings → Writing → Autocomplete, **Use visible text above the field**
reads Accessibility static text and link labels in the active input's column,
within 600 points above it and the same visible window/pane. It takes at most
three excerpts and 420 characters. Selection uses geometry before reading text;
the traversal has a 70 ms budget and 180-node limit. It does not capture pixels,
run OCR, read whole document values, or persist these excerpts.

Shared capture exclusions and autocomplete exclusions both apply. Hidden or
offscreen text, other inputs/windows, sidebars, toolbars, secure nodes, unknown
browser origins, recognized credentials and obvious instruction-injection
snippets are excluded. Apps without usable Accessibility text fall back to
ordinary completion. Heuristic text filtering is not a general prompt-injection
guarantee.

Context is validated again before display and polled while a context-backed
suggestion is active. Tab requires matching validation no older than 600 ms;
it does not traverse the surrounding screen. Focus/window/origin changes,
context changes, timeouts and permission revocation discard affected suggestions.
Context-grounded acceptances do not become learned writing examples.

When the relevant saved-memory grant is also enabled, selected visible text
can supply a project name for local retrieval. For example, a message about
the Teak handoff can supply the missing project for the draft “Sure, I'll send
it to …”; its saved owner is then available to completion. Visible terms must
match a saved source title to introduce that source. The existing two-word
body-overlap fallback uses only the user's draft and enabled window title,
so incidental nearby wording cannot qualify another project's facts.

Saved sources remain bounded to current, attributed notes/outcomes/work memory,
with independent meeting and screen-derived grants, source-revocation checks
and no new persistent fact store. See the [memory implementation report](../2026-10-02-memory/REPORT.md)
and [privacy contract](../../../../../PRIVACY.md#external-agent-access).

## Context evaluation

The [original fixture](../../visible-context-cases.json) contains eight
development cases and 32 initially held-out cases: 18 factual cases, 12 exclusion
controls and two generic-writing cases. Synthetic AX trees include distracting
sidebars, hidden text, other inputs, frames and origins. They pass through the
same traversal policy used by the live AX adapter, followed by the production
retrieval policy, prompt renderer, local model, token healing and normalization.
Reference answers and selection expectations remain outside inference.

| Original factual cases | LFM2.5 1.2B Instruct | Gemma 4 E2B Base |
| --- | ---: | ---: |
| Neither context source | 0/18 | 0/18 |
| Visible text only | 12/18 | 12/18 |
| Saved memory only | 4/18 | 4/18 |
| Both | **15/18** | **16/18** |
| Both, strict first factual word | 11/18 | 14/18 |
| Current fact wins over stale saved fact | 3/4 | 4/4 |

The primary score requires the expected fact as complete lexical words anywhere
in the normal three-word/five-token continuation. Strict first-word results are
reported separately. Errors and suppressed outputs stay in the denominator.
These are small factual-recall tests with the answer supplied in context; the
0/18 baseline is not a measure of general writing quality.

Gemma's misses were the room name `Cedar` (it wrote `102 for the`) and the Serbian
place `Baru` (it wrote `18h u Mas`). LFM missed two Serbian continuations and used
the stale owner `Ivan` instead of current `Petra`. The generic reference `help`
also rejects valid alternate wording such as “Thank you for your email”; those
cases are excluded from factual accuracy. One generic LFM completion changes
from `email` to `message` with unrelated visible text. Gemma's generic outputs
are unchanged.

All 12 exclusion controls have byte-identical prompts and output in all four
conditions for each model. They cover sidebar/below-field/hidden/offscreen text,
secure fields, app/domain exclusions, unknown origin, changed window/focus,
credentials and obvious prompt injection. All expected selected sources match;
no forbidden synthetic text reads or inference errors occurred.

The first prompt-qualified run was frozen before these 32 cases were evaluated.
After adding visible-to-memory retrieval, this corpus became a regression set.
All **128 observations per model** in the final build match that first run's
prompts, outputs, suppressions, errors, selected sources and text-read IDs.
See the [comparison proof](prompt-qualified-regression-proof.json) and preserved
[initial summary](prompt-qualified-summary.json).

## Fresh visible-to-memory integration cases

The separately frozen [supplement](../../visible-memory-link-cases.json) contains
two development cases and four held-out cases. Each draft and window title is
generic; the project appears only above the field, while the answer exists only
in saved memory. Neither source alone should produce the answer or authorize
the corresponding saved-memory selection.

| Four fresh held-out cases | LFM | Gemma |
| --- | ---: | ---: |
| Neither / visible only / memory only | 0/4 each | 0/4 each |
| Both: intended memory selected | 4/4 | 4/4 |
| Both: expected factual word emitted | **4/4** | **3/4** |

LFM explicitly produces Neda, Ulcinj, Pavel and Markdown. Gemma produces the
latter three and says `her.` for the Nebula reviewer instead of naming Neda.
That is counted as a factual miss even though a pronoun can be a valid reply.
Both models score 1/2 on this supplement's development cases with both sources.
No prompt or sampler changes followed either supplemental split. Four fresh
cases establish this integration path, not broad quality parity or a model
ranking; the much larger earlier quality evaluation supports the Gemma default.

## A regression the eval caught

An intermediate retrieval candidate appended all visible terms to the existing
body-overlap query. In the Willow CSV-export case, `export` and `format`
incorrectly admitted Mistral's saved JSON-export fact. The model still wrote
`a CSV file`, so output accuracy alone would have passed it. The source-selection
gate rejected that run with **31/32** correct selections in the combined condition.

The final code separates the full topic query from draft/title body-match terms,
and production and replay use the same field-based selector. A focused Swift
regression reproduces the old selection and verifies the corrected behavior,
while preserving body-overlap retrieval driven by the user's own draft. The
[rejected result](rejected-retrieval-regression.json), source/binary fingerprints,
and raw logs are retained. The supplemental four cases had not run inference
when this correction was frozen.

## Validation and limits

- Release and Debug build-for-testing passed. **183 selected non-UI Swift tests**
  passed with zero failures or skips; **20 Python replay/scorer tests** passed.
  Strict SwiftLint, diff and local document-link checks passed.
- The final executable produced **368 visible-context observations**, covering
  all four conditions, both corpora and both models. Every expected source
  selection and privacy control passed, with zero forbidden reads or inference
  errors.
- The earlier saved-memory suite was rerun on the final executable: LFM remains
  **11/12**, Gemma **12/12**, versus 0/12 without memory. All 22 selections and
  ten unrelated-writing controls per model pass; 88 observations are preserved.
- All **178 ordinary-writing checkpoints per model** exactly match the earlier
  memory build's prompts, output, suppression and errors with context disabled.
  This checks the unchanged path, not every possible irrelevant-context case.
- Unit tests cover geometry/clipping, consent, source revocation, target/scroll
  changes, read deadlines, bounded prompts, background validation and exclusion
  from local learning. No local UI tests or live-app AX compatibility tests ran.

Warm model medians on the final original-case replay are approximately 26–27 ms
for LFM and 42–48 ms for Gemma, depending on the condition. They exclude real AX
capture, disk retrieval, startup, debounce, rendering and acceptance. Other local
work was concurrent during this session, and earlier runs had higher timings;
these are descriptive samples, not end-to-end latency or speedup claims.

Live compatibility across Mail, browsers, chat apps and different field layouts
still needs a remote UI pass. Strict full-visibility and title-matching rules may
omit useful context. Retrieval is lexical and does not resolve arbitrary stale
facts or ambiguous topics. The room-name, Serbian and pronoun misses remain
visible in the results. Gemma's 3.85 GB download and earlier cold-readiness limits
are unchanged; this work does not establish uniform improvement for every
completion or personalized competitor parity.

Changed test expectations in this visible-context phase: none. Earlier default
model and whitespace expectation changes are recorded with the prior quality
work. Dependency pins were preserved, and XcodeGen ran when the source files
were added. Unrelated digest work in the shared checkout was left intact.

## Reproduction and provenance

Use the [benchmark instructions](../../README.md#visible-context-and-memory-replay)
and `visible_context_replay.py`, first with the development split and then with
heldout after freezing the candidate. Run the supplement with
`--corpus Benchmarks/autocomplete/Cotyping/visible-memory-link-cases.json`. The runner uses
isolated defaults/storage and explicit local models; it never reads a user
library or live screen, or changes installed settings. Native inference runs
were serial within this task.

Final Release executable SHA-256:
`dcb2aed984665dc2e4d06f8e99fdaac8ca1a196ecf4d63cf6a4e54e7be3227cb`.
The [source freeze](source-freeze.json) and [binary/corpus freeze](finalist-freeze.json)
identify the final build. The source manifest explicitly excludes and records
concurrent digest-only edits; it is not an immutable whole-repository snapshot.
Prompt-qualified and rejected-candidate freezes are retained separately.

The [summary](summary.json), [validation record](validation.json),
[ordinary regression proof](ordinary-regression-proof.json),
[raw archive](raw-runs.tar.gz), and [archive manifest](archive-manifest.json)
preserve exact inputs, outputs, source selections, model hashes, build/test logs,
development experiments and rejected runs. The final source snapshot is included
in that archive. The first credential test timeout and a zero-observation
development startup cancellation are recorded rather than discarded; their
successful fixes/retries are identified in the validation record.
