# Relevant memory for autocomplete — 2026-10-02

Autocomplete now retrieves small, relevant facts from explicitly enabled saved
sources. In a frozen synthetic factual-recall test, LFM improves from **0/12
to 11/12** correct names/details; Gemma E2B improves from **0/12 to 12/12**.
Both leave all ten unrelated-writing controls unchanged. This is a narrow
test of using supplied facts, not a claim of perfect autocomplete quality.

The implementation is built and tested, but **not committed, installed or
released**. Installed settings remain unchanged. Both new context controls
default off.

After this evaluation, Gemma was selected as the default autocomplete model
at the user's request. Existing saved model selections are preserved. The
results and source freeze here describe the evaluated build before that
subsequent default-selection change.

## What the user gets

Settings → Writing → Autocomplete has two independent controls:

- **Use meeting and work memory:** current meeting notes, summaries, corrected
  outcomes, and attributed meeting-derived Dream projects/goals.
- **Use screen-derived work memory:** attributed Dream projects/goals derived
  from screen/activity or daily-journal evidence. Mixed provenance requires
  both controls; Dream memory also requires Work Memory to remain enabled.

For a draft about a recognized project, the selected local model can use its
saved owner, place, deadline or technical detail. It receives at most **two
180-character snippets**, restricted to facts from the last **90 days**.
Source titles appear in Settings. Generic terms are filtered, matching named
topics exclude other projects, and newer same-title facts replace older ones.
Unattributed legacy Dream facts are excluded.

Retrieval reads existing local data off the UI thread. Search-index rows only
find candidate meetings; actual text is read from current source files. The
provider checks path boundaries, bounded source sizes, saved outcome corrections
and transcript revisions. It does not retrieve raw screen OCR or pixels, start
capture, or enable remote inference or external-agent access.

Source mutation and permission changes invalidate pending, visible and cached
suggestions. Snapshots check file stamps and the existing durable Dream
revocation state before presentation/acceptance. Memory-grounded acceptances
are excluded from the learning store; there is no new persistent private-fact
store. Already accepted text in another app remains there. Setup samples are
isolated; a personal preview uses the enabled context settings.

## Measurement

The original [fixture](../../memory-cases.json) contains 19 synthetic facts:
18 current facts and an outdated contradictory Atlas owner. Six draft cases
were used for development. Twelve factual cases and ten unrelated-writing
controls were held out. The [finalist source and executable](finalist-freeze.json)
were frozen before held-out inference, and no tuning followed those results.

| Held-out metric | LFM2.5 1.2B Instruct | Gemma 4 E2B Base |
| --- | ---: | ---: |
| Correct first factual word, memory off | 0/12 | 0/12 |
| Correct first factual word, memory on | **11/12** | **12/12** |
| Exact intended source selections, including empty controls | 22/22 | 22/22 |
| Unrelated controls with identical prompt and output | 10/10 | 10/10 |
| Inference errors | 0 | 0 |

Examples include Aurora's owner → `Nadja`, Meridian's location → `Tivat`,
Cobalt's database → `SQLite`, and Vesna's owner → `Dragan`. LFM's failure is
the Serbian place name `Budvi`: it produced `Budivu` despite the correct saved
fact. Retrieval improves grounding but cannot guarantee exact reproduction.
Both models scored 6/6 with context and 0/6 without on development cases.

Each pair uses the same Release executable, model bytes, seed and production
defaults (three words/five tokens). Only the source permission changes. Draft
text, surface metadata and synthetic saved facts enter inference; expected
answers and scoring labels do not. These cases intentionally provide the
factual answer in saved context. They test recall, not unseen-fact prediction.
Many prefixes closely match the saved sentence, making this an easier test
than paraphrased or ambiguous real writing.

The native production request builder, selection policy, token healing,
generation and normalization all run. Actual file retrieval and revocation
are exercised separately by unit tests; model replay never opens a user library.
The tests cover English, Serbian, French, German and Spanish examples, with
too few examples to qualify any language generally.

Raw warm generation medians are available in [summary.json](summary.json).
They exclude disk retrieval, startup, debounce, AX validation and rendering.
Shorter factual outputs explain some of the lower timings with memory on;
these results do not establish an end-to-end speed improvement. Bounded file
stamp checks still occur on the acceptance path; interaction latency has not
been measured.

## Regression and validation

- **218 non-UI Swift tests pass**, including current-source reads, stale FTS
  rows, corrections, deletion, oversized outcome dependencies, independent
  permissions, Dream retraction, in-flight revocation, preview isolation,
  generation/cache invalidation, and learning-copy prevention.
- **12 Python scorer/pairing tests pass.** Reference-label isolation,
  completeness, source selection, control prompt equality and error scoring
  are checked.
- Debug build-for-testing and Release build succeeded. Strict SwiftLint,
  diff checks and changed-document relative links pass. XcodeGen ran and
  dependency pins remain unchanged. No local UI tests ran.
- With memory disabled, all **178 ordinary-writing checkpoints per model**
  reproduce the preceding quality finalist's prompts, text, suppression and
  errors exactly. See [the comparison proof](ordinary-regression-proof.json).

The earlier [competitor/quality report](../2026-10-02-quality/REPORT.md)
remains evidence for its own frozen build: held-out next-word accuracy improved
from 27.97% to 30.43% with LFM, or 34.50% with the optional Gemma model.
The new memory feature does not extend the scope of that competitor comparison.
Cotypist parity remains unverified. The previous LFM `schedu` → `ling.`
regression and cold-start limits remain; memory does not address them.

Retrieval is lexical and deliberately small: four candidate meetings, short
excerpts, and recent attributed work memory. Long passages can be truncated;
missing index coverage, paraphrases and different titles can reduce recall.
Same-title recency filtering is not general contradiction resolution. Source
text filtering is not a guarantee against prompt injection. Broader real-world
acceptance, keystroke savings and competitor interaction tests remain unmeasured.

## Reproduction and evidence

Run [memory_replay.py](../../memory_replay.py) with the instructions in the
[benchmark README](../../README.md#saved-memory-replay). Use `--split development`
first and `--split heldout` only after freezing the candidate. Both source
controls remain off in installed preferences throughout evaluation.

The final executable SHA-256 is
`90759b77c750bfe14907907985e4a3c474e09bc0fac0d74ac7102a6bbf71490e`.
Model hashes, all per-case outputs and settings are in [LFM results](lfm-heldout.json)
and [Gemma results](gemma-heldout.json). [Validation](validation.json) records
the final checks. [raw-runs.tar.gz](raw-runs.tar.gz) preserves exact replay inputs,
observations, manifests, runtime logs, unit results and build logs;
[archive-manifest.json](archive-manifest.json) hashes each archived file.

Changed test expectations in this memory phase: none. Coordinator tests now
use an empty in-memory learning snapshot to avoid accessing the user's Keychain.
