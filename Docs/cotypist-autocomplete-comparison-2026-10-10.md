# Cotypist and LokalBot autocomplete: installed-artifact comparison

Research date: 2026-10-10. This is an analysis report, not an implementation change.

The LokalBot source snapshot below predates PRs #228 and #229. The subsequent [candidate decoder experiment on updated master](../Benchmarks/Cotyping/results/2026-10-10-candidates-master/REPORT.md) includes both merges and fresh fixed-model measurements.

## Main result

Cotypist's completion engine is materially more elaborate than LokalBot's
current decoder. Recovered code shows **multiple competing continuations,
repeated score-based pruning, per-sequence constraints, shared KV state, and
conditional token-history adjustments to logits**. This is supported by
control flow, not just class names or bundled product copy.

LokalBot uses **one token-healed continuation followed by low-temperature
sampling**, a first-word confidence gate, and a short whole-suggestion display.
Its personalization retrieves accepted examples into the prompt. The most
useful difference to investigate is therefore candidate selection and reuse,
not merely changing the model or sampling temperature.

This does **not** establish that Cotypist produces better suggestions or has
lower latency. Its configured model also differs from LokalBot's repository
default, and no controlled runtime comparison was conducted.

## Scope and evidence

The target is `/Applications/Cotypist.app`, version **2026.5**, build **81**, arm64.
Its executable SHA-256 is
`8cb2475a56de0dcee2d1f9bdc05a6e45b4679e430710d2c7a67dc0c092143529`.
LokalBot source was inspected at
`32381e9f8e8137c95d1b94984549a62cdb004aab` (0.10.3 release merge).

[REA](https://github.com/morluto/rea) **6.3.0** was installed in a temporary
directory. The inspected REA source checkout is
`28595276faac6a01dd4930313a91fab717d29513`. Native analysis uses Ghidra
**12.1.4**, with its arm64 decompiler built from the official distribution's
bundled source. No persistent Codex registration was added. Cotypist was not
launched, injected into, patched, or re-signed; no writing-history database or
clipboard contents were opened. No local UI tests were run.

Evidence labels used below:

- **Code:** recovered machine-code control flow, cross-checked against data
  layouts/imports. Decompiled pseudocode is not original Swift source.
- **Metadata:** names, layouts, declarations, or packaged text in the binary.
  These establish that a mechanism exists, not that it ran in this session.
- **Source:** current LokalBot implementation.
- **Inference:** a design interpretation supported by the preceding evidence.
- **Unknown:** not established by this static investigation.

Raw analysis workspace: `/private/tmp/cotypist-analysis-20261010/`.
Essential observations are retained in this report because temporary files can
be removed. REA's complete dispatch inventory is **partial**: the 20,000-record
budget was reached, some ivar offsets are initialized only at runtime, and
generic/resilient/async Swift metadata has decoding limitations. Missing
records are not proof of missing functionality.

## Current LokalBot baseline

| Stage | Behavior at the inspected commit |
|---|---|
| Model | Default Gemma 4 E2B **Base Q6_K**, 3,845,328,608 bytes; LFM2.5 1.2B Instruct is the lightweight alternative. |
| Runtime | In-process llama.cpp by default; 2,048-token context/batch, Metal offload; dedicated local HTTP model-server fallback. |
| Input | Keyboard event tap plus AX focus polling. Poll interval starts at 200 ms and backs off to 600/1,200/2,000 ms. |
| Scheduling | Initial 160 ms debounce; native steady-state tiers 20/25/55 ms depending on previous generation latency. Host-publication waiting is deducted from that budget. |
| Prompt | Raw continuation with optional context preface; 2,500 characters / 500 words before caret, preface up to 900 characters. |
| Decode | One constrained token path for healing, then one sampled path. Temperature 0.1, top-p 0.7, top-k 20, min-p 0.08, repeat penalty 1.05, seed `0xC0FFEE`. |
| Confidence | At word boundaries, first-word raw probability product must remain at least 0.1. This gate is disabled during mid-word healing. |
| Presentation | Default four words, six free decode tokens. Engine supports streaming, but the normal coordinator waits for a complete suggestion before showing it. |
| Reuse | Common-prefix KV reuse for attention models; full prefill for recurrent/hybrid models. Separate 16-entry, 180-second suggestion cache. |
| Continuation | Matching typed characters consume the visible tail. Open-ended suggestions top up when two words remain, normally requesting three more. |
| Acceptance | Tab accepts a word; backtick accepts the rest. Fresh field validation precedes insertion. Escape pauses the field for ten seconds. |
| Learning | Encrypted retrieval of accepted examples, scoped to supported documents; at most 500 examples and 30-day retention. It does not fine-tune the model. |

Source anchors:
[model catalog](../LokalBot/Engines/ModelCatalog.swift#L70),
[defaults](../LokalBot/Models/AppSettings.swift#L442),
[debounce](../LokalBot/Cotyping/CotypingDebouncePolicy.swift#L13),
[prompt renderer](../LokalBot/Cotyping/CotypingPromptRenderer.swift#L63),
[native decoding](../LokalBot/Cotyping/Llama/LlamaCotypingRuntime.swift#L504),
[confidence gate](../LokalBot/Cotyping/Llama/CotypingFirstWordConfidence.swift#L14),
[whole-suggestion presentation](../LokalBot/Cotyping/CotypingCoordinator+Prediction.swift#L193),
[suggestion extension](../LokalBot/Cotyping/CotypingSuggestionExtension.swift#L9),
[learning](../LokalBot/Cotyping/CotypingLearningStore.swift#L17).

## Cotypist artifact observations

The saved preference `ModelRepository_selectedModel` is
`gemma-4-E4B-Q5_C`. Its model file is **5,166,805,632 bytes** and starts with
`9f2dc028`, rather than the normal `GGUF` magic. This identifies the configured
selection and file, not the tensor architecture, exact quantization, or model
currently resident in a running process. No attempt was made to unpack that
format. The older `gemma-4-E4B-UD-Q5_K_XL.gguf` also exists; its presence does
not make it the selected model. Historical July comparisons must not be
presented as measurements of this build.

The executable imports llama.cpp decode, logits, tokenization, model-load and
KV sequence operations, and ships `libllama`/`libggml` libraries. It also imports
model repacking, normalization override and token-cache rebuilding functions.
Their presence does not establish which transformations are active.

REA dispatch metadata evidence:
`ev_04d7f03e5963ebf2cbce648f390dd01fb8f68ee2f8446091414bdd4b1ba653cc`.

| Class / structure | Recovered state relevant to autocomplete |
|---|---|
| `GenerationManager` | Model/tokenizer/context, batch, KV cache, sequence manager, separate maximum prompt/prefix/completion/search/result/batch sizes, standby budget/tolerance, sampler and telemetry. |
| `TokenSequence` | Cached token IDs, active and valid token counts, a constraint, total logit, total log probability, next batch index, and chunk layout. |
| `DTSM` | All sequences, result cache, standby store/window, pinned keys by sequence, advanced-token/idle-step counters, pinned/unpinned cache hits and cache misses. |
| `SC` | Cache, pinned keys, maximum entries, maximum age, vocabulary size, and cache-hit depth counters. |
| `CompletionManager` | In-flight decode, latest input, pending edits and stale flag, staged result, previous completion/display, display epoch, insertion session, pending acceptance and caret polls, word alternatives and thesaurus tasks. |
| `CompletionAccessibilityMonitor` | App/focus/text-field observers plus a focused-element polling task, suspension reasons and sticky force-activated fields. |
| `NB` / `NBT` | Token/child edges, inline and multi-token adjustments, maximum order; separate database-backed training task. |
| `CompletionInserter` | Paste and restoration delays, original pasteboard item types/data, and a restoration task. |

For `GenerationManager`, REA resolves these object offsets from the actual
binary metadata: `maxPromptTokens` +144, `maxPrefixLength` +152,
`maxCompletionLength` +160, `maxSearchWidth` +168, `maxResultWidth` +176,
`maxBatchSize` +184, and `sampler` +400. This permits checking the meaning of
otherwise anonymous field accesses in pseudocode. Its class record is at
`0x100cf8e18`; the nominal Swift descriptor is at `0x100b868cc`.

## Reconstructed Cotypist generation logic

Addresses below are unslid virtual addresses in the exact executable identified
above. `FUN_...` names are Ghidra labels, not recovered original method names.
Line numbers refer to the saved pseudocode files in the evidence directory.

### 1. A bounded search over multiple continuations

**Code.** The setup function at `0x1000ea2c0` calls the generation constructor
at `0x1005b63d4`. At call site `0x1000eb03c`, arm64 registers `x5` and `x6`
both contain **9**. The constructor stores those arguments at object offsets
`+0xa8` and `+0xb0`, which the metadata independently names `maxSearchWidth`
and `maxResultWidth`.

The search function at `0x1005ab230` actually reads both fields. It uses them
as defaults/upper bounds and rejects supplied widths that exceed them. Thus
nine is a verified initialization cap on this path, **not a claim that every
request expands nine branches or shows nine suggestions**.

The same function performs this repeated sequence:

1. Check task cancellation.
2. Advance the current `TokenSequence` batch through the cache-aware decoder.
3. Process each sequence's logits using concurrent per-sequence work.
4. Merge the candidate arrays returned by those workers.
5. Apply score cutoffs, constraints and width limits; allocate/reuse the
   surviving sequence branches.
6. Repeat until the active sequence list is empty or the generation bounds
   are reached.

The branch handlers at `0x1005c196c` and `0x1005c403c` compare candidates
against indexed score cutoffs and cap the survivors. Their shared allocator
at `0x1005c3108` can copy a parent's KV state into another sequence, copy its
constraint and accumulated scores, append a selected token, and update
`activeTokenCount`, `totalLogit` and `totalLogprob`.

**Interpretation:** “beam-style, width-bounded search” accurately describes
the recovered behavior. The complete scoring equation, length adjustment and
exact beam-search variant have not been reconstructed. Calling it a standard
off-the-shelf beam search with a known formula would overstate the evidence.

Primary evidence: `rea-completion-search-code.c:299–317,658–899,1031–1151,1438–1449`;
`rea-branch-pruning-code.c:239–289,354–412,691–696,965–1022`;
`rea-branch-expansion-code.c:138–239,487–546`;
`rea-generation-main-loop-code.c:330–439,503–639`.
The last filename is an early working label; its function is the shared branch
allocator, not the entire generation loop.

### 2. A separate shortlist, greedy-extension and rescoring path

**Code.** A caller at `0x1002017d8` follows a different route:

1. Prepare the prompt/cache.
2. Obtain the highest-scoring initial token IDs via `0x1005b1540`.
3. Extend those branches through `0x1005b24c0`.
4. Optionally score the resulting candidate strings with `0x1005ae840`,
   combine score arrays, sort and cap the returned strings.

Here, the extension routine chooses the **maximum-logit next token for each
branch**; it does not perform repeated beam expansion itself. It uses distinct
sequence IDs, KV copying and a shared decode batch. The inspected stop checks
include LF, CR, comma and the supplied length limit. These stop rules belong
to this path, not necessarily all inline completions.

The scoring routine accumulates per-token candidate scores and contains the
exp/sum/log normalization chain expected for log probabilities. It uses cached
logits where possible and batches misses. An insertion-sort comparator at
`0x10020128c` orders larger scores first and treats absent scores as negative
infinity; the surrounding sort has a merge-sort path for larger arrays.
Swift floating-point ABI recovery is imperfect, so this report does not assert
a fully reconstructed mathematical ranking formula.

**Unknown:** the exact UI trigger for this caller was not traced. The binary
also has word-alternative and thesaurus state, but that alone does not prove
which of those features invokes this route. Its shortlist and result limits
come from separate caller configuration, not automatically from the engine's
nine/nine cap.

Primary evidence: `rea-candidate-search-caller-code.c:3030–3067,3332,3661,3758,4006`;
`rea-sequence-branch-code.c:94–165,568–628`;
`rea-candidate-generate-code.c:401–417,729–751,875–921`;
`rea-candidate-decode-code.c:863–1068,2160–2176`;
`rea-rescore-order-code.c:27–54`.

### 3. Reuse is part of the search algorithm

**Code.** `0x100619790` advances sequences from their `validCount`, assembles
tokens/positions/sequence IDs into a shared llama batch, requests logits for
the needed positions, and can copy KV state into lagging sequences. Candidate
scoring and token shortlisting also have cache-hit paths.

**Metadata.** `DTSM` and `SC` additionally contain pinned cache keys,
standby stores/windows, age/entry limits, hit-depth counters and skipped-pin
counters. The precise eviction policy and benefit of retaining standby
branches were not fully reconstructed.

**Comparison.** LokalBot has common-prefix KV reuse plus a small completed
suggestion cache. Its recurrent/hybrid path falls back to full prefill. Cotypist
has a richer mechanism for sharing and retaining state across competing token
sequences. The presence of KV-copy calls does not establish safe or effective
reuse for every architecture, including its configured Gemma model.

Primary evidence: `rea-sequence-advance-code.c:503–534,1054–1152,1287,1585–1611`;
`rea-sampler-next-code.c:313–329`; the class layouts above.

### 4. Constraints and confidence operate at different levels

**Code.** Cotypist carries a constraint object on each sequence, consults it
when considering candidate token text, and advances/replaces it when adding
tokens. Its sampler constructor receives float values approximately `0.05`
and `1e-10`, stored at sampler offsets `+40` and `+44`.

The sampler at `0x100612ff0` uses the first value as a cutoff for later
unconstrained candidates, exempting the first candidate. The second participates
in a relative comparison on a constrained path. An assembly check at
`0x100613438–0x100613444` confirms the floating-point cutoff comparison.
These are internal candidate filters; **they must not be described as a
universal five-percent display-confidence threshold**. The complete
probability calibration and constraint semantics remain uncertain.

**Source.** LokalBot's meaning is explicit: its first-word raw probability
product must stay at least `0.1` at a word boundary; the gate is disabled for
mid-word healing. Healing constrains the next tokens to reconstruct the typed
fragment before free sampling. Cotypist's constraint protocol is not yet
proven equivalent to those exact healing rules.

Primary evidence: `rea-sampler-constructor-code.c:574–584`;
`rea-sampler-core-code.c:44–45,183,260–268`;
`rea-generation-main-loop-code.c:565–586`;
[LokalBot healing](../LokalBot/Cotyping/Llama/CotypingTokenHealing.swift),
[LokalBot confidence](../LokalBot/Cotyping/Llama/CotypingFirstWordConfidence.swift).

### 5. Personalization can adjust logits using token history

**Code plus metadata.** This is stronger than the packaged claim that the app
learns a user's writing style:

- A count-building/training path at `0x1005e3754` creates an `NB` object; its
  layout contains token edges, child edges, inline/multi-token adjustment
  arrays and `maxOrder`.
- The sampler path at `0x1006135fc` checks an enablement flag, a positive
  strength value and the availability of the booster before calling
  `0x1005dddc4` with the sequence's cached token IDs.
- That routine walks backwards through the token history, follows trie edges
  up to `maxOrder`, reads the adjustment arrays and **adds scaled adjustments
  to candidate logits**. The direct addition is visible at the block labelled
  `LAB_1005de160`.
- A second sampler path at `0x10061564c` has the same enablement/strength
  checks and a corresponding adjustment call.

**Interpretation:** this is a history-derived, n-gram-style logit booster,
separate from the LLM weights. It is not evidence of LLM fine-tuning. The
complete count-to-adjustment formula, data collection policy and settings
mapping were not reconstructed. No personal training database was read, so
the booster being populated or enabled for this user is **unknown**.

LokalBot currently personalizes through **retrieval of accepted examples in
the prompt**, scoped to supported documents, with encryption and retention
limits. It does not have this observed trie-based logit-adjustment path.
Adopting such a mechanism would require preserving LokalBot's existing
learning consent, scope, exclusion and deletion boundaries.

Primary evidence: `rea-booster-build-code.c:824–827`;
`rea-sampler-logit-path-code.c:158–181`;
`rea-sampler-fast-path-code.c:136–162`;
`rea-booster-apply-code.c:78–157,257–314`.

## Direct comparison

| Aspect | Cotypist 2026.5 | LokalBot at the inspected commit |
|---|---|---|
| Candidate search | Repeated score pruning over multiple active continuations; initialization caps nine/nine. **Code.** | One healed then sampled continuation. **Source.** |
| Additional generation route | Top initial tokens, greedy branch extensions, optional rescoring and sorted results; UI trigger unknown. **Code/unknown.** | No equivalent multi-candidate route in the normal autocomplete engine. **Source.** |
| Confidence | Candidate cutoffs plus per-sequence constraints; complete display policy unknown. **Code/unknown.** | Explicit first-word probability-product gate and output filters. **Source.** |
| Personalization | Conditional history-trie logit adjustments; user's active training state unknown. **Code/unknown.** | Accepted-example retrieval in the prompt. **Source.** |
| Decode reuse | Cached logits, sequence sharing/copying and batched advancement; pinned/standby state also exists. **Code/metadata.** | Prefix KV reuse for attention models, recurrent full prefill, completed-suggestion cache. **Source.** |
| Mid-typing state | Pending edits, staged results, display epochs, prior completion and insertion state. Exact transition rules unknown. **Metadata.** | Generation IDs, cancellation, matching-tail consumption, fresh field validation and suggestion top-up. **Source.** |
| Input timing | AX observers and polling are present; exact debounce and display timing not recovered. **Metadata/unknown.** | Adaptive debounce, AX polling/backoff and bounded host-publication waiting. **Source.** |
| Context | Prompt coordinator, clipboard/screen-context structures and packaged prompt templates exist; exact selected-model prompt not established. **Metadata/unknown.** | Explicit bounded app/document, clipboard, visible-context, learned-example and permission-gated saved-memory inputs. **Source.** |
| Display/acceptance | Word-alternative state and pasteboard-restoration machinery exist; live timing and insertion behavior not tested. **Metadata/unknown.** | Whole suggestion, word/full acceptance, typed-through reuse and open-ended top-up. **Source.** |
| Model | Saved selection is labelled Gemma 4 E4B Q5_C; file format is opaque here. **Preference/file.** | Repository default Gemma 4 E2B Base Q6_K. **Source.** |

The comparison is asymmetric by design: LokalBot source permits exact claims
about policy and timing, while some Cotypist behavior can only be bounded by
static evidence. Unknown Cotypist behavior is not a demonstrated deficiency.

## Implications for LokalBot

These are proposed experiments, not implemented changes.

1. **Evaluate a small candidate-search mode.** Keep the current model, prompt,
   context and insertion guards fixed; compare one path with widths two and
   four before considering nine. Measure useful-word acceptance, unwanted
   suggestions, last-keystroke-to-visible p50/p95, decode work and peak memory.
   A width of nine from another application is not a justified default.
2. **Make reuse model-aware.** A branching experiment needs shared-prefix
   state and reusable candidate logits to be practical. For recurrent/hybrid
   models, first prove checkpoint correctness against a cold decode. Cotypist's
   KV-copy calls alone are not a recipe for that implementation.
3. **Compare personalization mechanisms in isolation.** A bounded local
   token-history booster could be tested against existing prompt examples,
   especially for repeated names and document vocabulary. Use only authorized
   learning data and test deletion/retention/exclusions; do not broaden data
   capture merely to imitate a competitor.
4. **Separate search quality from display policy.** More candidates can help
   ranking or an optional alternatives UI, but may add latency or unwanted
   output. Keep confidence gating and fresh field validation, and benchmark
   time to a stable useful suggestion rather than tokens per second alone.

First complete the remaining correctness work below. Candidate search does
not resolve stale context, session identity or capture-boundary errors.

## Existing correctness issues relevant to the comparison

The earlier autocomplete review was rechecked against this commit rather than
carried forward unchanged. These are current **source observations**, not new
live reproductions and not evidence that Cotypist avoids the same errors.

| Earlier finding | Current source status |
|---|---|
| F01: old memory after a changed query in the same field | Remains: changing the query retains the previous snapshot until the replacement finishes. |
| F02: recycled composer identity / indefinite title cache | Partly addressed: title/placeholder caching now has a one-second TTL, but AX/frame-first identity still lacks a navigation identity. |
| F03: visual-caret capture crosses window boundaries | Remains as a source risk: display capture excludes no windows and crops to the old field frame. This is not observed data leakage. |
| F04: OCR deadline waits for slow work anyway | Fixed in source with a cancellation-aware bounded continuation; regression tests exist. |
| F05: typing through loses open-ended extension state | Fixed in source by using `session.advanced`; regression tests exist. |

Anchors: [memory lookup](../LokalBot/Cotyping/CotypingMemoryLookup.swift#L23),
[identity](../LokalBot/Cotyping/CotypingFieldIdentity.swift#L24),
[surface cache](../LokalBot/Cotyping/CotypingAXHelper.swift#L118),
[visual capture](../LokalBot/Cotyping/CotypingVisualCaret.swift#L303),
[bounded wait](../LokalBot/Cotyping/CotypingVisualCaret.swift#L381),
[session advancement](../LokalBot/Cotyping/CotypingSessionReconciler.swift#L125).

## Validation boundary

This investigation establishes architecture and selected control flow, not
comparative suggestion quality or responsiveness. No fresh side-by-side typing
benchmark was run; no assertion that Cotypist is faster or more accurate follows
from its more elaborate data structures. An eventual comparison should freeze
models, prompts, context permissions, application versions and hardware; measure
last-keystroke-to-visible latency, recovery after divergent typing, useful-word
acceptance, unwanted correction and insertion correctness. UI validation must
use hosted CI or a remote runner under this repository's rules.

The Cotypist app and model were not modified. This work did not build, install
or release LokalBot. It added this report only; existing unrelated workspace
entries were preserved. Documentation link and whitespace checks are the
appropriate repository validation for this change.

Completed checks: all **17 local source links** resolve, referenced line anchors
are in range, the report has no trailing whitespace, `git diff --check` passes,
and the before/after workspace inventory differs only by this report. A final
SHA-256 check of Cotypist's executable matches the initial hash. Application
code is unchanged, so no app build or test suite was run for this report.

## Reproduction and evidence ledger

The temporary analysis workspace retains tool results, parsed pseudocode and
assembly excerpts. REA successfully closed its native session and wrote
`cotypist-2026.5-rea-snapshot.json` (4,956,160 bytes, 54 evidence records).
The temporary MCP server exited successfully. Reopening the target starts a
new analysis session; the installed binary hash must match before reusing
these addresses.

| Observation | Function/address | REA evidence ID |
|---|---|---|
| Layouts and dispatch metadata | `GenerationManager`, `TokenSequence`, `NB`, `DTSM`, `SC` | `ev_04d7f03e5963ebf2cbce648f390dd01fb8f68ee2f8446091414bdd4b1ba653cc` |
| Constructor field assignments | `0x1005b63d4` | `ev_83cd2bee2db4d33c194e761cb82435bf34c02a4f9b4ed5374fbfd576bb57c641` |
| Repeated bounded search | `0x1005ab230` | `ev_2b6ba2a62d0e4d325e64d5b6ac1741aa4863d093969b735600f73675a31d842e` |
| Score pruning and constraints | `0x1005c196c` | `ev_072472efc62ea5d2e29fb20b66a2b084d2a2a933acb3916b4f30b5a35075b5ac` |
| Branch allocation and score state | `0x1005c3108` | `ev_ac7f390d363cb7088b15c372e46f6631d1b94e9cf49582d73fbfde0b2d62f43c` |
| Greedy branch extension | `0x1005b24c0` | `ev_2afc99930cf7e20bb60c34749a603ad5f0494b61552e34be183022701f60276c` |
| Auxiliary candidate pipeline | `0x1002017d8` | `ev_bc647db8a2d466fa282145c29ccfb0f7f79866ce5183e7ce7d9721fa7fbd59d2` |
| Descending score comparison | `0x10020128c` | `ev_6f5ccc0ee1e53e78595b84df281a6c2dfbc26c4bb131bc5521a160fcbaa85d5b` |
| Batched sequence advancement | `0x100619790` | `ev_cdd246709ed0d0da796633352d96596380b8aa0b4d2c5984c93b196c6c9d2636` |
| Candidate cutoffs | `0x100612ff0` | `ev_1f9611123f5133c45d8dd1c908a8d78327a5503177eed8a85e9e02022ce67817` |
| Conditional booster call | `0x1006135fc` | `ev_ed23deaad9477f1aa6a6b151cd46e8c0248401041b132724963fa092bb9b6bb7` |
| History-trie logit addition | `0x1005dddc4` | `ev_bd7888f2e105b2632953a5dca770dae87b45b551d0000b35eb945c9ad61f0d49` |

Ghidra completed analysis of approximately 44,000 procedures. It reported
Swift/Objective-C recovery limitations, and several procedures contain
decompiler warnings or imperfect floating-point types. The conclusions above
rely on matched field layouts, caller/callee flow and selected machine-code
checks. They do not purport to recover Cotypist's original Swift source.
