# Dictation screen and memory context — 2026-10-02

## Outcome

Implemented independent context grants for Dictation Compose and evaluated the production preparation/selection/prompt path with Qwen3.5 4B. With all grants enabled, the frozen fresh supplement passed **20/20 cases**, including **8/8 factual-grounding tasks** versus **0/8 without context**. All eight fidelity tasks and four privacy/Transcribe controls passed. These are small synthetic, post-ASR tests; they establish this behavior on these cases, not parity with a competitor or general dictation quality.

The original 22-case set now serves as regression coverage. Full context scored **11/12 factual tasks** and **4/4 fidelity tasks**. The remaining factual score miss and the development miss are disclosed below; neither was removed or rescored.

## What changed

- Three separate, default-off Dictation grants: nearby visible text, meeting/work memory, and screen-derived work memory. They do not inherit Autocomplete settings. Mixed-source facts need both memory grants; Dream facts additionally need Work Memory enabled.
- Nearby context selects up to three excerpts, 420 characters total, above the current field using the shared geometry-first Accessibility traversal. A single background worker and 150 ms deadline prevent blocked apps from growing a capture queue. Shared exclusions, secure/private fields and unknown browser origins still abstain.
- Saved facts use current sources, source-title relevance, source provenance and deletion/revocation checks. Spoken requests and authorized visible messages can supply the matching project. Incidental body-word overlap cannot pull another project's facts into dictation.
- Explicit writing requests can use the enabled context. Direct sentences and unrecognized phrasing receive ordinary Compose cleanup without adding context. Transcribe returns recognized speech unchanged and never calls the composition model or these providers.
- Visible context, origin/grants and saved sources are checked around model preparation/generation; source/grant checks also guard delivery. The spoken transcript stays available if stale composition is rejected. Optional remote inference discloses that enabled saved facts can be sent to the approved server.

The existing focused-window OCR option is preserved. It can pre-capture during recording before intent is known; direct speech cancels unfinished OCR after ASR and never includes its result in the prompt. The new nearby-text and saved-memory providers are not called for direct speech. The replay exercises nearby Accessibility text, not actual OCR.

Compose keeps the configured instruction model. The separate Gemma Base autocomplete default was not substituted for Compose.

## Eval design

- Machine: Apple M4 Max, 48 GiB, Mac16,5.
- Model: `Qwen3.5-4B-Q4_K_M.gguf`; the bundled llama-server runs on an ephemeral loopback port, 32,768-token context, one slot, fixed seed 12648430. Generation uses production Compose options: temperature 0.2, 4,096 output tokens, zero thinking budget.
- Synthetic recognized speech, Accessibility trees and attributed saved facts; no microphone, live screen, actual user library or external inference. Each app process uses isolated defaults/home/storage and the headless command runs before normal startup/migration.
- Five conditions have identical speech and available fixtures. Only grants change. Output scoring requires complete required words/phrases and forbids specified conflicting facts. Separate checks verify selected IDs, permitted text reads, model-call counts and unchanged output/prompt/system for direct/excluded/Transcribe controls.
- Runtime input is explicitly whitelisted to `id`, `speech`, `visible`, `transcribe` plus the source collection and grants. Answers and the external `contextEligible` reference are never passed to the runtime or model.
- Six development and 22 initially held-out cases ran first (140 observations). Their failures motivated the routing fix; the 22 are now called **regression**, not untouched holdout. No prompt change was made after those failures.
- A new 20-case supplement was authored and frozen after the fix and before any inference. It covers polite English, Serbian and French requests, visible-to-memory linking, separate source grants, conflicting names/numbers/negation, explicit spoken overrides, screen instruction injection, hidden text, unknown origin, credentials and Transcribe.
- The final source/binary freeze preceded all three final runs: six development, 22 regression and 20 fresh cases, each across five conditions (**240 observations**). Raw first-pass and final outputs are retained.

## Measured quality

| Context enabled | Regression facts | Fresh facts | Regression fidelity | Fresh fidelity |
|---|---:|---:|---:|---:|
| No context | 0/12 | 0/8 | 4/4 | 8/8 |
| Visible text only | 5/12 | 4/8 | 4/4 | 8/8 |
| Meeting memory only | 2/12 | 1/8 | 4/4 | 8/8 |
| Visible + meeting memory | 9/12 | 6/8 | 4/4 | 8/8 |
| Visible + meeting + screen-derived memory | 11/12 | 8/8 | 4/4 | 8/8 |

All final observations passed expected-source, forbidden-read and model-call checks; none returned an engine error. All **21** invariance checks across the three splits passed. The eight fresh fidelity cases include six direct sentences, one explicit spoken override and one screen-instruction-injection test. All four fresh privacy/Transcribe controls passed in every condition. Development factual scores were 0/4, 2/4, 1/4, 3/4 and 3/4 respectively; its fidelity and Transcribe cases passed throughout.

Representative fresh outputs with all grants enabled:

- “Can you reply with the reviewer’s name?” + visible “Who reviews the Thistle proposal?” + saved “Thistle proposal reviewer is Daria.” → `Daria`.
- “Molim te napiši kratak odgovor na srpskom i potvrdi mesto radionice.” + visible Cetinje location → `Radionica za projekat Javor biće u Cetinju.`
- “Elena owns the Verbena handoff, not Elina.” + conflicting visible/saved owner → `Elena owns the Verbena handoff, not Elina.` Context providers were never called.
- Explicit request names Ognjen while current screen says Sava and memory says Boris → `Ognjen owns the Oleander launch.`

## The rejected first pass

Instructions in the model prompt alone did not preserve direct speech when screen context was present. With full context:

| Spoken text | First-pass output | Final output |
|---|---|---|
| I cannot approve the 42 items yet. | The 24 items are all approved. I cannot approve the 42 items yet. | I cannot approve the 42 items yet. |
| Mina will review the report, not Mira. | Mina will review the report. | Mina will review the report, not Mira. |

First-pass fidelity was 4/4 without visible text and **2/4** in the visible/both/all conditions. The final routing rule gives **4/4** in every condition on that regression set and **8/8** on the fresh fidelity cases. The routing decision is deterministic, conservative and independent of fixture labels; it recognizes common writing-command prefixes rather than claiming general intent understanding.

### Changed test expectations

Original speech, semantic required/forbidden phrases, source fixtures and source IDs were preserved. The scorer now uses a required external `contextEligible` label to expect **zero context reads/selections** on direct speech; all original semantic scores remain unchanged. Direct cases also acquire prompt/output/system invariance checks. The old fixture, old scorer and old results remain available under `first-pass/`. No existing XCTest assertion was weakened.

## Remaining misses and limits

- Regression `held-conflict-date`: `Linden deadline has moved from Monday to Thursday.` This correctly describes the change, but still fails the frozen criterion forbidding the stale word “Monday.” The reported result stays **11/12**; it was not reclassified after seeing the output.
- Development `dev-linked`: `I will contact the owner.` The model had Pavel's name but did not include it when asked only to say it would contact the owner. This remains a failure against the explicit-name metric (**3/4** with all context), although the generic wording follows the spoken instruction.
- Factual word/phrase checks do not measure overall prose taste, grammatical fluency or broad hallucination rates. A finite instruction recognizer may omit useful context for unfamiliar phrasing/languages and can misclassify ambiguous imperatives. Users can use an explicit writing request or Transcribe as appropriate.
- No live AX/app compatibility, microphone/ASR quality, insertion/clipboard behavior, remote endpoint, hosted UI test or competitor dictation test ran. These results must not be presented as end-to-end dictation accuracy or broad multilingual parity.

Median post-ASR preparation plus local HTTP generation time (including synthetic context selection, excluding microphone, ASR, native AX/OCR, insertion and model startup):

| Context enabled | Regression | Fresh supplement |
|---|---:|---:|
| No context | 196 ms | 186 ms |
| Visible text only | 185 ms | 201 ms |
| Meeting memory only | 196 ms | 192 ms |
| Visible + meeting memory | 194 ms | 291 ms |
| Visible + meeting + screen-derived memory | 192 ms | 301 ms |

Most requests reuse a warm server and cached prompt prefixes. These batch medians are not user-perceived dictation latency.

## Validation and artifact identity

- Debug build-for-testing and Release build succeeded on the final source. The generated Xcode project includes the new sources.
- **176 focused non-UI XCTest cases passed**, zero failures, in an isolated disposable test host. Coverage includes intent isolation, late source deletion, permissions/origin revocation, stale visible context, bounded capture, prompt boundaries and the shared memory/context selection.
- **9 Python scorer tests passed**, covering external reference isolation, direct-speech zero reads, provenance grants, exact Transcribe, controls, model errors and missing/reordered observations.
- Strict SwiftLint, tracked diff/new-file whitespace checks, source/fixture hash verification and local documentation links passed.
- Built and tested only. **Not installed, committed, pushed or released.** No local UI test ran.

Final executable SHA-256: `145881ec7f7f47c14bdd9512bd71401bd12c6c9a6a31860bd1ac8663d18aea91`.
Model SHA-256: `00fe7986ff5f6b463e62455821146049db6f9313603938a70800d1fb69ef11a4`.
Server SHA-256: `7a776fb67a186875441c729b3392773953582017cd4f63f7d00bfdffa38f328f`.

Evidence: [source/binary freeze](source-and-binary-freeze.json), [fresh-fixture freeze](routing-fixture-freeze.json), [development](development.json), [regression](regression.json), [fresh holdout](fresh-heldout.json), [validation](validation.json), [raw final runs](raw-runs.tar.gz), [validation logs](validation-logs.tar.gz), [original run](first-pass/heldout.json), [original raw runs](first-pass/raw-runs.tar.gz), and [SHA-256 manifest](sha256-manifest.json). See the [runner instructions](../../README.md) to reproduce with a new output directory.
