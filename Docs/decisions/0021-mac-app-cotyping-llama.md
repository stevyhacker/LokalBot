# 0021. Mac app: Cotyping — Llama

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LokalBot/Cotyping/Llama/`, `LokalBotTests/Cotyping/Llama/`.

## Decisions

### `LokalBot/Cotyping/Llama/CotypingEngineSelector.swift`

#### Route per completion between local, HTTP and chosen server engines
`CotypingEngineSelector`: Per-completion router between the in-process `LocalLlamaCotypingEngine`
(built-in GGUF on Apple Silicon, flag on), the existing HTTP
`CotypingEngine` (non-GGUF backends, flag off, or in-process load failure),
and a server the user chose for autocomplete (`cotypingBackend`).
Conforms to `CotypingCompleting`, so `CotypingCoordinator` is unchanged.

#### 60 s HTTP cooldown avoids reloading weights per keystroke but recovers
`CotypingEngineSelector.localRetryCooldown`: How long completions stay on HTTP after an in-process failure before
the local engine is rebuilt and retried. Long enough that a persistent
failure doesn't reload the selected model's weights on every keystroke, short
enough that a transient one (memory pressure passing) recovers soon.

#### Log HTTP fallback once per failure episode
`CotypingEngineSelector.didLogLocalFailure`: Set after the first in-process failure so the HTTP fallback is logged
once per failure episode (spec §13), not on every keystroke. Reset on a
successful local generation or a model-path change.

#### Failure cooldown routes to HTTP without rebuilding local engine
`CotypingEngineSelector.retryLocalAt`: Non-nil while a failure cooldown is active: `localIfEligible()` routes
to HTTP (without rebuilding the local engine) until this instant.

#### Free model once per switch to server route
`CotypingEngineSelector.releasedForServer`: Set once both on-device routes were released for the server route, so
the model is freed once per switch rather than checked every keystroke.

#### Generation check stops re-entrant stale operations recreating runtime after unload
`CotypingEngineSelector.lifecycleGeneration`: Invalidates work that crossed an actor suspension under an older route.
`@MainActor` prevents simultaneous mutation, but async model verification
and unloads are re-entrant: an explicit `unload()` can run while an older
generate/prewarm is awaiting verification. Without a generation check,
that older operation could resume and recreate the local runtime after
shutdown completed.

#### Block route resolution until overlapping unloads finish
`CotypingEngineSelector.unloadOperationsInFlight`: Keeps new route resolution out until every overlapping explicit unload
has stopped both runtimes.

#### Coalesce teardown so HTTP does not start before weights are freed
`CotypingEngineSelector.localUnloadTask`: Coalesces local teardown across re-entrant route changes so a second
completion cannot start HTTP while the first is still freeing weights.

#### Include requested model ID since unknown IDs fall back to recommended
`CotypingEngineSelector.LocalRouteIdentity`: The setting and catalog entry together identify the route being
resolved. Including the requested ID matters because an unknown ID
falls back to the recommended entry; changing between two bad IDs must
still invalidate an already-suspended lookup.

#### Debounce follows resolved route, restoring conservative server debounce on failure
`CotypingEngineSelector.debounceProfile`: The actual resolved route, not merely the user's preferred setting.
A local failure clears `local` and starts a cooldown before HTTP runs,
which immediately restores the conservative model-server debounce.

#### Choosing a server frees on-device model and stops llama-server
`CotypingEngineSelector.serverIfSelected`: The server route when one is selected. Switching to it frees the
on-device model and stops the dedicated llama-server first, so a model
nobody uses does not stay resident; nil keeps the on-device routes.

#### Check cheap gates before hashing GGUF so disabled users pay nothing
`CotypingEngineSelector.localIfEligible`: Short-circuit the cheap gating conditions before resolving and, for a
legacy download, hashing the GGUF. Users with local cotyping disabled
should not pay that integrity-check cost.

#### During cooldown engine already dropped; route to HTTP
`CotypingEngineSelector.localIfEligible`: Failure cooldown: the engine was already dropped (weights freed) in
handleLocalFailure, so just route to HTTP until the retry instant.

#### Release old weights before building replacement; overwrite leaked runtime
`CotypingEngineSelector.localIfEligible`: A model change must release the old in-process weights before a
replacement is built. The old implementation overwrote `local`
and leaked its runtime until deinit happened to run.

#### Join other unload; nil local does not mean weights released
`CotypingEngineSelector.localIfEligible`: Also joins an unload started by another re-entrant route change.
`local == nil` only means ownership was taken, not that the old
model has finished releasing its weights.

#### Unload HTTP copy of model before local runtime loads
`CotypingEngineSelector.localIfEligible`: The HTTP fallback may still hold the same model from a prior
failure, a previous setting, or an adopted server from an older
app process. Stop it before the local runtime starts loading.

#### Reuse route installed concurrently instead of orphaning loaded weights
`CotypingEngineSelector.localIfEligible`: A concurrent lookup may have installed this exact route while
this operation was suspended in `http.unload()`. Reuse it rather
than overwriting a live engine and orphaning its loaded weights.

#### Explicitly unload and await; runtime deinit is async and delayed
`CotypingEngineSelector.dropLocalEngine`: Drops the cached in-process engine and frees its loaded model when the
selector routes away from local (flag toggled off, Intel, or the model
stops resolving). Self-limiting: a no-op once already dropped, so it's
safe to call on every ineligible `localIfEligible()` pass. Setting
`local = nil` alone is NOT enough — the runtime actor's deinit is async
and may not run promptly, so we explicitly unload and await completion.
When the flag flips back on and the model resolves,
`localIfEligible()` rebuilds a fresh engine via `makeLocal` (cold reload
on the next generate).

#### Selecting a server frees on-device model before typing
`CotypingEngineSelector.prewarm`: Selecting a server frees the on-device model here, before typing.

#### Warm only an existing in-process engine; never build or verify
`CotypingEngineSelector.warmAfterPause`: Only an in-process engine that already exists: warming never builds
one or verifies a model, and has nothing to do on the server routes.

#### Invalidate before first suspension so verifier cannot recreate engine
`CotypingEngineSelector.unload`: Invalidate before the first suspension so a verifier already in
flight cannot recreate the local engine after this method returns.

#### Always release both paths; HTTP server may be adopted from older process
`CotypingEngineSelector.unload`: Always release both paths. The HTTP server may have been adopted
from an earlier app process and therefore need not have generated in
this selector instance to be resident.

#### Model server streams so it stops at same decode boundary
`CotypingEngineSelector.generate`: The model server is streamed even here: its client stops reading at
the same decode boundary as the in-process runtime.

#### Await local unload before HTTP fallback to avoid two resident copies
`CotypingEngineSelector.handleLocalFailure`: In-process→HTTP fallback. The HTTP path runs the same GGUF in its own
`llama-server` process, so keeping the failed local engine loaded would
leave two copies of the selected model's weights resident. A failure here is
likely memory pressure, so the unload is AWAITED — the caller must not
start the HTTP fallback (which may cold-load the server's copy) until
the local weights are actually freed. Then route to HTTP for
`localRetryCooldown` and rebuild + retry local (a cold reload, but at
most once per cooldown — never per keystroke). Logged once per failure
episode (spec §13).

#### Join in-flight teardown; nil local does not prove weights freed
`CotypingEngineSelector.handleLocalFailure`: Join a teardown already started by a re-entrant route change. Seeing
`local == nil` does not prove its weights are gone: another task may
have taken ownership and still be awaiting `engine.unload()`.

### `LokalBot/Cotyping/Llama/CotypingFirstWordConfidence.swift`

#### Replay-only modes; neither is a calibrated acceptance probability
`CotypingConfidenceBoundaryMode`: Replay-only alternatives. Neither is a calibrated acceptance probability.

#### Fallback never changes a passing decision or forced midword
`CotypingConfidenceDecision`: One sampled token stream, with independent sticky confidence decisions.
The fallback never changes a passing current decision or a forced midword.

#### Selected-token gate intentionally ignores EOS
`CotypingConfidenceDecision.accept`: The existing selected-token gate intentionally does not weigh EOS.

#### Drop word-start suggestions below 0.1 first-word probability; measured results
`CotypingFirstWordConfidence`: The confidence gate: stay quiet when the model is unsure, as Cotypist does.
A suggestion at the start of a word is dropped when the model's own
probability of its first word falls below `minimumProbability`.

The probability is the product of the emitted tokens' probabilities up to
and including the token in which the first word ends. Measured on real
replies and the user's own prompts and messages (2026-10-06, E2B): wrong
suggestions shown halve for about 1.5 points of keystrokes saved, because a
hidden suggestion usually comes back as a completion once the first letter
is typed. Suggestions inside a word are not gated: their first token is
forced to re-type the fragment, so its probability is not comparable.

#### Inspect first scalar even if token ends mid UTF-8; continuations never boundaries
`CotypingFirstWordConfidence.tokenStartsBoundary`: Inspect the first complete Unicode scalar, even if the token ends in an
incomplete UTF-8 sequence. Byte continuation tokens are never boundaries.

#### Next-word token evidences termination; wordOnly is upper bound
`CotypingFirstWordConfidence.accept`: A token that begins the next word is evidence of termination; its
particular suffix is irrelevant to first-word agreement. WordOnly
is an upper-bound heuristic. BoundaryMass retains termination mass
on this token path; it does not marginalize other tokenizations.

### `LokalBot/Cotyping/Llama/CotypingTokenCandidates.swift`

#### Single vocabulary pass replaces repeated argmax for token healing
`CotypingTokenCandidates`: The same candidates as repeated argmax with each winner removed, in one
vocabulary pass. Token healing needs at most 64 candidates; rescanning a
large vocabulary for each rejected token adds work before any ghost text.

#### Bounded worst-at-root heap needs one comparison per entry once full
`CotypingTokenCandidates.topTokens`: A bounded heap with the WORST retained candidate at the root. Most
vocabulary entries need only one comparison after the heap fills.

#### Skip NaN and -infinity, retain +infinity, matching argmax
`CotypingTokenCandidates.topTokens`: Matches argmax: skip NaN and -infinity, but retain +infinity.

#### Equal logits keep lower token ID tie break
`CotypingTokenCandidates.topTokens`: Equal logits retain the original argmax's lower-token-ID tie break.

### `LokalBot/Cotyping/Llama/CotypingTokenHealing.swift`

#### Headless controls isolate partial-word conditioning from sampling
`CotypingHealingMode`: Headless controls for isolating partial-word conditioning from sampling.

#### Search variants for comparisons; app hybrid uses certified
`CotypingSearchExperiment`: Search variants for controlled comparisons. The app hybrid uses `certified`.

#### Sum log probabilities to compare whole paths, not first greedy piece
`CotypingHealingPath`: Probability of a complete token path through the typed bytes. Summing log
probabilities compares paths rather than favoring the first greedy piece.

#### Trace is opt-in replay evidence, never emitted live
`CotypingHealingTrace`: Opt-in replay evidence; never emitted by live autocomplete.

#### Cut prompt to word boundary and require re-producing cut bytes
`CotypingTokenHealing`: Token healing for mid-word completions — the mechanism behind Cotypist's
"snaps to the word you meant" behavior (its binary calls it
`requiredPrefix` / `remainingRequiredPrefix`).

A prompt that ends mid-word ("…I wanted to follo") tokenizes unnaturally at
the tail, so a small model often treats the fragment as a finished word and
continues with " up …". Healing cuts the prompt back to the last word
boundary ("…I wanted to") and turns the cut text (" follo") into a decode
constraint: generation must re-produce those bytes through naturally
tokenized pieces (" fol"+"lo", or " follow" overshooting the boundary), and
only then run free. The ghost text is everything after the constraint, so
the suggestion extends the word the user is typing.

Pure value logic; `LlamaCotypingRuntime` enforces the constraint.

#### Skip healing for long fragments like URLs; too many forced steps
`CotypingTokenHealing.maxWordLength`: Longest word fragment worth healing. Longer runs (URLs, identifiers)
would spend many forced decode steps for text the LLM path should not
assist anyway.

#### Also remove separating whitespace since trailing space tokenizes badly
`CotypingTokenHealing.Split.healedPrompt`: The prompt to tokenize: original prompt cut at the word boundary,
with the separating whitespace run removed too (a trailing space
tokenizes as badly as a partial word).

#### Completed word plus space must not extend; replay separator then hide
`CotypingTokenHealing.split`: A completed word followed by a space must not be extended (cat -> cats).
Replay the separator through natural tokens such as " is", then hide it.

#### Match bytes not Characters since BPE pieces split UTF-8 scalars
`CotypingRequiredPrefixMatcher`: Byte-level matching of one detokenized piece against the remaining required
prefix. Bytes (not Characters) because BPE pieces can split UTF-8 scalars.

#### Prefer word-extending overshoot over constraint ending mid-word
`CotypingRequiredPrefixMatcher.extendsWord`: True when an overshoot's first extra byte continues the WORD (ASCII
letter/digit, apostrophe, or a multi-byte scalar lead). Used to prefer a
boundary-crossing token over one that lands exactly on the caret: a
constraint that ends exactly mid-word leaves the model in the same
awkward state healing exists to avoid ("tomorro" + free decode → "ow."),
while a word-extending overshoot completes the word inside the
constraint — Cotypist's `transitionExpansionLimit` behavior.

#### Withhold incomplete final scalar; malformed bytes reject generation
`CotypingUTF8TokenDecoder`: Token pieces are byte fragments, not necessarily complete Unicode scalars.
Keep an unfinished scalar for the next piece and publish only validated UTF-8.
An incomplete final scalar is withheld; malformed bytes reject the generation.

### `LokalBot/Cotyping/Llama/CotypingTokenPrefixIndex.swift`

#### Rank tokens that spell the prefix when outside global top candidates
`CotypingTokenPrefixIndex`: Fallback for a typed fragment whose compatible tokens are outside the global
top candidates. Rank only tokens that can actually spell the user's prefix;
canonical tokenization alone discards the model's preference between them.

### `LokalBot/Cotyping/Llama/IncrementalPrefill.swift`

#### Reuse KV-cache common prefix; re-prefill only the differing tail
`IncrementalPrefill`: Pure helper for KV-cache reuse. Given the token sequence currently resident
in the llama context (`cached`) and the freshly tokenized prompt (`next`),
returns the number of leading tokens they share. The runtime keeps that
prefix in the KV cache and re-prefills only `next[p...]`, which is what makes
per-keystroke decode cheap as the user types forward.

### `LokalBot/Cotyping/Llama/LlamaCotypingRuntime.swift`

#### Ignore aborts made while no decode is active
`LlamaDecodeAbortState.beginDecode`: Starts one decode scope. Abort requests made while no decode is active
are intentionally ignored, so cancelling an old request cannot poison
the next generation.

#### Runtime owns model and context, reuses KV prefix on attention models only
`LlamaCotypingRuntime`: In-process llama.cpp runtime for cotyping. Owns the model, a persistent
context + memory, and serializes all inference on the actor's executor
(off the main actor).

The KV-reuse probe (`IncrementalPrefill`) reports how much of each prompt
overlaps the previous one. On a pure-attention model this drives true
partial-prefix reuse: the shared prefix KV is kept and only the diverged
suffix is re-decoded. Hybrid/recurrent models cannot rewind their rolling
state to a prefix, so focus prefill records only the logical prompt baseline
and generation falls back to a full re-prefill; `lastPrefillTokenCount` still
surfaces the diverged-suffix length as the meaningful reuse signal either
way. The capability is cached once at load (`supportsPartialReuse`).

Built against the llama.cpp pinned in `Scripts/build/fetch-llama.sh`; symbols are
verified against the vendored dylib.

#### Serialize loads because actor methods reenter at await points
`LlamaCotypingRuntime.loadInProgress`: Actor methods are reentrant at `await` points. Serialize model loads so
concurrent prewarm and first-generation calls cannot mmap the same
weights twice while `willLoad` is suspended.

#### Epoch invalidates in-flight loads that unload() would otherwise miss
`LlamaCotypingRuntime.unloadEpoch`: Invalidates a load that was already in flight when `unload()` ran.
Actor isolation alone is insufficient here: `loadIfNeeded` suspends while
consulting the main-actor residency ledger, so `unload()` can otherwise
observe an empty runtime and return before that older load resumes and
installs its model.

#### Test seam after residency admission to exercise unload-vs-load race
`LlamaCotypingRuntime.postLoadAdmissionHook`: Test seam placed immediately after residency admission. Production uses
the no-op default; tests suspend here to deterministically exercise the
unload-vs-load race without loading a multi-gigabyte GGUF.

#### Reused softmax buffer, one float per vocabulary entry
`LlamaCotypingRuntime.probabilityScratch`: Reused for the confidence gate's softmax, one float per vocabulary entry.

#### Replay-only cancellation experiments; app policy unchanged until measured
`LlamaCotypingRuntime.replayPrefillChunkSize`: Replay-only cancellation experiments; app policy remains unchanged until measured.

#### Last suggestion time feeds the memory-pressure policy
`LlamaCotypingRuntime.lastUsedUptime`: When a suggestion was last generated, for the memory-pressure policy.

#### Tracks any GPU use and counts time asleep, unlike lastUsedUptime
`LlamaCotypingRuntime.lastDecodeInstant`: When the model last ran on the GPU for any reason: a suggestion, a
prompt read or a `touch`. Counts time asleep, unlike `lastUsedUptime`.

#### Partial KV eviction only on pure-attention models; recurrent re-prefill
`LlamaCotypingRuntime.supportsPartialReuse`: True only for pure-attention models, whose per-position KV cells can be
partially evicted (`seq_rm` at a non-zero p0). Recurrent/hybrid (SSM/Mamba)
models cannot rewind their rolling state to a prefix, so they full-reprefill.

#### Thread-safe bridge lets a superseded task abort llama_decode from outside
`LlamaCotypingRuntime.decodeAbortState`: Thread-safe bridge into llama.cpp's abort callback. A superseded Task can
flip this from outside the actor while `llama_decode` is still running.

#### Static let initializes llama backend once across all instances
`LlamaCotypingRuntime.backendReady`: Initializes the llama backend exactly once across ALL instances. Swift
guarantees a static `let` initializer runs once and is thread-safe, which
removes the cross-instance check-then-set race a `static var` flag would have
(actor isolation does not protect static storage).

#### Two threads won the M4 Max latency study; other hardware untested
`LlamaCotypingRuntime.forAutocomplete`: All app autocomplete uses the measured hybrid policy. Replay keeps its
explicit controls and baseline initializer defaults for historical parity.
Two generation/prefill threads won the fixed-E2B M4 Max latency study;
other hardware and cancellation responsiveness still need broader trials.

#### Evict LRU models before mmap if budget would be exceeded
`LlamaCotypingRuntime.loadIfNeeded`: Make room before llama mmaps the weights: evict LRU models first
if this load would push total resident weights past the budget.

#### Offload all layers to Metal, matching LlamaServer -ngl 99
`LlamaCotypingRuntime.loadIfNeeded`: full Metal offload (matches LlamaServer's -ngl 99)

#### 4096 context matches LlamaServer; prompt cut at front would change every keystroke
`LlamaCotypingRuntime.loadIfNeeded`: Matches LlamaServer.cotyping.contextTokens. A long draft and a whole
window of text must fit: a prompt cut at the front changes its start
on every keystroke, and the model would read all of it each time.

#### Probe reuse capability once at load to avoid per-call dylib warning
`LlamaCotypingRuntime.loadIfNeeded`: Cache the architecture capability once, at load: probing inside generate
would emit a dylib stderr warning on every call for recurrent models.

#### On cancelled load free pointers only if epoch unchanged; unregister own generation
`LlamaCotypingRuntime.loadIfNeeded`: If the epoch moved, the explicit unload already freed the pointers.
If only this task was cancelled while registration was suspended,
free them here. In both cases remove only this load's ledger row;
a replacement runtime may already have registered under the same ID.

#### One in-process runtime holds weights, so a single ledger row
`LlamaCotypingRuntime.residencyID`: One in-process runtime holds weights at a time, so a single ledger row.

#### Free context and model on dealloc to avoid ggml-metal teardown assertion
`LlamaCotypingRuntime.deinit`: Frees the llama context + model when the actor is deallocated. Without
this the Metal backend's residency set is still live at process exit,
which trips a teardown assertion in the vendored ggml-metal build.

#### Failed or cancelled prefill clears KV so cachedTokens stays truthful
`LlamaCotypingRuntime.prefill`: Decodes a prompt into KV without sampling so a later generation can reuse
it. Cancellation/failure clears KV because a partial prefill must never
masquerade as the prompt represented by `cachedTokens`.

#### Skip speculative prefill on recurrent models to avoid doubling first decode
`LlamaCotypingRuntime.prefill`: CoTabby avoids speculative prefills once a model cannot reuse a
prompt KV prefix. For hybrid/recurrent models this keeps focus
prewarm from doubling the first real autocomplete decode while
preserving the logical prefix baseline used for diagnostics.

#### Internal free does not advance epoch; external teardown must use unload()
`LlamaCotypingRuntime.releaseLoadedResources`: Frees the currently installed pointers without invalidating the load that
intentionally called it while switching model paths. External teardown
must go through `unload()`, which advances `unloadEpoch` first.

#### Synchronous free; unregister only the freed generation in main-actor task
`LlamaCotypingRuntime.releaseLoadedResources`: Keep this path synchronous for memory pressure, but only remove the
generation that was actually freed. A reload may register before
this main-actor task gets its turn.

#### Warning keeps model loaded while typing; critical or idle minute frees it
`LlamaCotypingRuntime.handleMemoryPressure`: Frees the model + context under memory pressure. The next `generate`
call lazily reloads via `loadIfNeeded` (or the engine routes to HTTP if
reload fails). Keeps cotyping from OOMing the app under a large model.

A warning while someone is typing leaves the model loaded: dropping it
would make their next keystroke wait for a reload. Critical pressure,
or a warning after a minute without suggestions, frees it.

#### Priming decode heats Metal pipelines, then KV is cleared
`LlamaCotypingRuntime.warmup`: Runs one priming decode so Metal pipelines are hot before the first real
keystroke, then clears the KV so generation starts from a clean cache.

#### Throwaway token after pause removes cold GPU cost; cached prompt preserved
`LlamaCotypingRuntime.touch`: Runs one throwaway token through the loaded model, so the next
suggestion after a pause does not pay for bringing the GPU and the
weights back. Never loads a model, and does not count as use for the
memory-pressure policy or the residency ledger.

Waits for the GPU, so the time it takes is the cold cost it removes.
The token goes at the next free position, as llama.cpp requires, and is
removed afterwards, so a cached prompt stays cached. A recurrent state
cannot drop one token; those models read the whole prompt on every
suggestion anyway, so their memory is cleared instead.
- Parameter minimumIdle: skip when the model ran more recently.
- Returns: whether a token was decoded.

#### Synchronize because llama_decode only queues GPU work
`LlamaCotypingRuntime.touch`: `llama_decode` only queues the GPU work, and nothing reads these
logits. Without waiting, the next suggestion would wait for the
touch's GPU work instead of finding it done.

#### Adaptive chunking only for multi-chunk prefills, protecting single-chunk path
`LlamaCotypingRuntime.decodeCancellable`: Adaptive experiments protect the existing single-chunk path. Only
a multi-chunk prefill gets an early checkpoint and a larger remainder.

#### Synchronize intermediate chunks to measure cooperative interruption
`LlamaCotypingRuntime.decodeCancellable`: A native call can queue Metal work. Include completion at each
intermediate boundary when measuring cooperative interruption.

#### Token-healing prefix constraint, overshoot preference and confidence gate semantics
`LlamaCotypingRuntime.generate`

- Parameters:
  - requiredPrefixUTF8: token-healing constraint. When non-empty,
generation must first re-produce exactly these bytes (the whitespace +
word fragment cut from the prompt tail by `CotypingTokenHealing`) via
naturally tokenized pieces, then continue freely. Only the text AFTER
the constraint (including the overshoot of a boundary-merging token
like " follow" against " follo") is emitted and returned — it is the
ghost text that extends the word the user is typing.
  - preferWordExtendingOvershoot: when the fragment is NOT a valid
standalone word, a candidate that merely lands exactly on the caret
leaves the model in the same awkward mid-word state healing exists to
avoid (free decode after "…tomorro" can emit "ow."). Prefer a
boundary-crossing candidate that keeps spelling the word — Cotypist's
transition-expansion behavior.
  - minimumFirstWordProbability: the confidence gate
(`CotypingFirstWordConfidence`); 0 turns it off. When the first
word falls below it, generation stops, `onLowConfidence` is called
and nothing is returned.

#### Clamp KV reuse to count-1 so fresh logits always exist
`LlamaCotypingRuntime.generate`: KV-reuse probe: how many leading tokens this prompt shares with the cache.
Clamp to count-1 so we ALWAYS decode >=1 token and get fresh logits for the
next-token sample — required when the new prompt equals/prefixes the cached
one (e.g. an identical re-generation), else we'd sample from stale logits.

#### Keep seq_rm failure fallback to full re-prefill; SWA window may evict prefix
`LlamaCotypingRuntime.generate`: Attention model: the shared prefix KV is kept and only the diverged
suffix is re-decoded. seq_rm dropped [reuse, end) — the diverged tail
plus any stale tokens the previous generation appended past the prompt.

Cotyping prompts are NOT guaranteed to stay inside the production
Gemma4 model's 512-token sliding window: worst case is ~850–1100
tokens (a 150-word prefix + the ~900-char preface + up to 2500 prefix
chars). The load-bearing guard is the `llama_memory_seq_rm` return
value below: it returns false when the partial removal can't be
honored (e.g. the kept prefix [0, reuse) aged out of the SWA window on
a long prompt), and we then fall through to the full re-prefill in the
`else` branch. DO NOT remove that fallback — partial reuse is only
safe when seq_rm confirms the kept prefix is still resident.

#### Recurrent models reset and full-prefill; reuse stays the diagnostic signal
`LlamaCotypingRuntime.generate`: Recurrent/hybrid model (SSM/Mamba) cannot partially rewind its rolling
state, or a partial seq_rm above was not honored. Reset and prefill the
whole prompt from position 0. `reuse` above is still the meaningful
KV-reuse *signal* callers read via lastPrefillTokenCount.

#### Constrained phase consumes at least one byte per step, so terminates
`LlamaCotypingRuntime.generate`: Constrained phase: force-decode the healed word fragment. Each step
consumes >=1 byte, so the loop terminates in \<=count steps.

#### Return nothing when no token extends the constraint
`LlamaCotypingRuntime.generate`: No vocab token can extend the constraint (pathological bytes).
Surface nothing rather than a suggestion that skips the fragment.

#### Decode failure discards partial output and propagates to HTTP fallback
`LlamaCotypingRuntime.generate`: A mid-generation decode failure discards the partial output and
propagates so the selector falls back to HTTP, rather than
surfacing a truncated ghost as if it were a complete suggestion.

#### Probability at temperature 1; unknown is 0 keeping gate closed
`LlamaCotypingRuntime.tokenProbability`: The model's probability of `token` given the current logits (softmax at
temperature 1, whatever the sampler's settings). Unknown is 0, which
keeps the gate closed rather than showing an unweighed suggestion.

#### Reuse exp(logit-max) scratch; mask is tokenizer-only, built at load
`LlamaCotypingRuntime.boundaryMass`: `probability(of:)` leaves exp(logit - max) in scratch. Reuse it instead
of another softmax or decode. The mask is tokenizer-only, built at load.

#### Vectorized softmax over vocabulary overwrites the scratch buffer
`LlamaCotypingRuntime.probability`: Softmax probability of `token`, vectorized over the whole vocabulary.
`scratch` holds one float per vocabulary entry and is overwritten.

#### Vectorized per-token argmax; NaN revealed by sum triggers scalar scan
`LlamaCotypingRuntime.argmaxToken`: Runs once per generated token over the whole vocabulary (262k entries
for Gemma), so it is vectorized. The vector maximum is wrong when a
NaN is present, which the sum reveals; the scalar scan below then
decides, as it does when every logit is -infinity.

#### Bound prompt by tokens, keep caret end, reserve output space
`LlamaCotypingRuntime.boundedPromptTokens`: Bound the physical prompt by tokens, not English character estimates.
Dense Unicode text can exceed the context even inside the character cap.
Keep the caret end and reserve space for healing plus visible generation.

#### Cheap first pass of 64 candidates before consulting prefix index
`LlamaCotypingRuntime.constrainedCandidateScanLimit`: How many global candidates to try before consulting the prefix index.
Natural text usually finds a compatible piece in this cheap first pass.

#### Rank bounded set in one pass; park exact-caret candidate for word-extending one
`LlamaCotypingRuntime.constrainedToken`: Highest-logit vocab token whose piece extends the remaining required
prefix (token healing). Ranks a bounded set in one vocabulary pass,
without copying or changing native logits. Rare fragments use a cached
byte-prefix index to find the best compatible token in the full vocabulary.

With `preferWordExtendingOvershoot`, a candidate that consumes the
remaining bytes EXACTLY is parked while the scan continues for one whose
piece crosses the caret with a word character ("… tomorrow" beating
"… tomorro"); the parked candidate is used when no such token exists.

#### Search hidden prefix path without touching sampler RNG or history
`LlamaCotypingRuntime.searchPrefixPath`: Search only the hidden prefix path. No free token is sampled or scored
here, and the sampler's RNG/history remains untouched until replay.

#### Top compatible token covering prefix cannot be beaten; keep single-decode path
`LlamaCotypingRuntime.searchPrefixPath`: A highest-ranked compatible token that already covers the prefix
cannot be beaten by a lower-ranked token followed by more factors
\<=1. Keep this common case on the original single-decode path.

#### Search keeps only per-request scalar rankings, no logits or KV snapshots
`LlamaCotypingRuntime.searchPrefixPath`: Per-request scalar rankings only: no retained logits, KV snapshots, or text history.

#### Seed search with exact previous path so pruning never drops it
`LlamaCotypingRuntime.searchPrefixPath`: Seed with the exact previous decoder path. Candidate pruning
must never remove the existing completion from consideration.

#### Log probabilities are non-positive, so unfinished path bounded by parent
`LlamaCotypingRuntime.searchPrefixPath`: Additional token log probabilities are \<=0, so an unfinished
path cannot beat a completed path above this upper bound.

#### Headless counters never persisted by live autocomplete
`CotypingReplayDiagnostics`: Headless confidence and decode counters; never persisted by live autocomplete.

#### Counts tokens submitted to native decode, including aborted ones
`CotypingReplayDiagnostics.decodedTokens`: Tokens submitted to native decode, including a decode that was aborted.

#### Raw first-word gate value, not a calibrated acceptance probability
`CotypingReplayDiagnostics.firstWordProbability`: This is the existing raw first-word gate, not a calibrated acceptance probability.

### `LokalBot/Cotyping/Llama/LlamaSamplerSpec.swift`

#### Sampler chain order mirrors llama.cpp common default; pure for unit tests
`LlamaSamplerSpec`: Value-typed description of the llama.cpp sampler chain, in apply order.
Pure so the config→chain mapping is unit-testable without libllama; the
runtime turns each case into the matching `llama_sampler_init_*` call.

Order mirrors llama.cpp's `common` default for this subset:
penalties → top_k → top_p → min_p → temp → dist (final distribution sampler).

### `LokalBot/Cotyping/Llama/LocalLlamaCotypingEngine.swift`

#### Reuse HTTP engine normalization and decode-stop policy for identical suggestions
`LocalLlamaCotypingEngine`: In-process `CotypingCompleting` conformer. Tokenizes the already-built
prompt, drives `LlamaCotypingRuntime`, and reuses the EXACT same
normalization + decode-stop policy as the HTTP engine so suggestions are
shaped identically. Stops on the stop policy, the token budget, or task
cancellation (superseded keystroke).

#### Confidence gate for word starts; 0 disables it for quality replay
`LocalLlamaCotypingEngine.minimumFirstWordProbability`: The confidence gate for suggestions at the start of a word; 0 turns it
off (the quality replay does, to compare).

#### App always enables hybrid healing; replay may select legacy path
`LocalLlamaCotypingEngine.init`: The app factory always enables hybrid healing. Replay can still
select the legacy path for controlled comparisons.

#### Handler's hold on the source ends when deinit cancels it
`LocalLlamaCotypingEngine.init`: The handler's hold on the source ends when deinit cancels it.

#### Prefill the healed prompt so mid-word KV reuse hits; generation cancels it
`LocalLlamaCotypingEngine.prewarm(for:)`: Best-effort prompt KV prefill for the focused field. A real generation
cancels this so it does not sit behind obsolete warmup work. Prefills
the HEALED prompt so a mid-word generation's KV-reuse probe hits.

#### Prefill failure is ignored; generation prefills normally or falls back
`LocalLlamaCotypingEngine.prewarm(for:)`: Prompt prefill is opportunistic; the following generation can
still run a normal prefill or fall back through the selector.

#### Warm touch is not cancelled; later suggestion waits on runtime and starts warm
`LocalLlamaCotypingEngine.warmAfterPause`: Runs one throwaway token when the loaded model has not run for
`warmAfterIdle` (`LlamaCotypingRuntime.touch`). Not cancelled by a
suggestion that arrives meanwhile: that suggestion waits for it on the
runtime, then starts warm instead of doing the same work itself.

#### Free weights when selector routes away from local to HTTP
`LocalLlamaCotypingEngine.unload`: Frees the in-process model + context. Called when the selector routes
away from local (flag toggled off, or the model stops resolving) so the
selected model's weights don't stay resident while completions go to HTTP.

#### Nil onPartial means normalize once at end, not per token
`LocalLlamaCotypingEngine.run`: `onPartial` is nil when nobody watches the suggestion form; it is then
normalized once at the end instead of after every token.

#### Use try so decode failures reach the HTTP fallback, not empty ghost
`LocalLlamaCotypingEngine.run`: `try` (not silent `await`): a thrown LlamaRuntimeError.decodeFailed
propagates out of run() → the selector's `catch let error as
LlamaRuntimeError`, so a decode failure reaches the HTTP fallback
instead of surfacing a silent empty/truncated ghost.

#### Invalid-word fragment must keep being spelled across the caret
`LocalLlamaCotypingEngine.run`: A fragment that is not a valid standalone word must keep
being spelled across the caret, not merely reach it.

#### Skip confidence gate inside a word because first token is forced
`LocalLlamaCotypingEngine.run`: Inside a word the first token is forced, so it is not weighed.

#### Cap fallback only after full normalization, which can still suppress it
`LocalLlamaCotypingEngine.run`: A fallback is capped only after full normalization, which can
still suppress it (for example when a later question mark arrives).

#### Native decode stops at same boundary as the HTTP path
`LocalLlamaCotypingEngine.run`: Native decode-stop at the SAME boundary the HTTP path stops at.

#### Cap only completed result; word definition matches offline policy
`LocalLlamaCotypingEngine.oneWordFallback`: Cap only the completed normalization result, preserving its suppression.
Matches the offline policy's Unicode word/apostrophe/hyphen definition.

#### Heal only with a word fragment at caret; boundary prompts stay byte-identical
`LocalLlamaCotypingEngine.healedGeneration`: The healed (prompt, required-prefix) pair for a request. Healing applies
only when the request carries a word fragment at the caret — the same
signal the typo gate and normalizer key off — so boundary caret
positions keep today's prompt byte-for-byte.

#### Serial onToken calls need no locking; unchecked Sendable crosses actor
`TokenAccumulator`: Reference-typed accumulator the decode closure mutates across token calls.
The runtime invokes `onToken` serially on one thread, so no synchronization
is required; marked `@unchecked Sendable` only to cross the actor boundary.

### `LokalBotTests/Cotyping/Llama/CotypingEngineSelectorTests.swift`

#### Flag off drops cached in-process engine and unloads; on rebuilds; Apple Silicon only
`testRouteAwayDropsCacheAndRebuildOnReenable`: FIX 1: when the runtime flag flips OFF the selector must drop its cached
in-process engine (and unload its model); flipping it back ON rebuilds a
fresh engine. We prove the cache is dropped by counting `makeLocal` calls
through the injectable seam: build → drop → rebuild ⇒ exactly two builds.

These selector paths only run on Apple Silicon (`isAppleSilicon`), so the
test is skipped on Intel where `localIfEligible()` always returns nil.

#### Changing GGUF used to overwrite engine without unloading; order must be unload, stop HTTP, new
`testModelChangeUnloadsOldLocalBeforeBuildingReplacement`: Changing the selected GGUF used to overwrite the cached local engine
without unloading it. Prove replacement is ordered: old local unload,
stale HTTP stop, then the new local generation.

#### Test proves selector fallback wiring only, not that llama_decode failure throws
`testLocalRuntimeErrorRoutesToHTTPFallback`: FIX 2 (selector half): a `LlamaRuntimeError` thrown by the local engine must
reach the selector's `catch let error as LlamaRuntimeError` and route the
completion to HTTP. This injects a `ThrowingLocalEngine` fake (enabled by the
`CotypingCompleting` seam on `makeLocal`), so it proves the selector's
fallback wiring — NOT that `LlamaCotypingRuntime.generate` actually throws on
a failed `llama_decode`. That runtime half is locked by compilation (the
`try await` propagation in `LlamaCotypingRuntimeTests`); a genuine
`llama_decode == 0` fault (KV exhaustion / OOM) can't be provoked
deterministically in a unit test.

#### Failed local engine unloads before HTTP fallback; cooldown before local retry
`testLocalFailureFreesModelAndCoolsDownBeforeRetry`: The HTTP fallback runs the SAME GGUF in its own llama-server process, so
a failed in-process engine must not stay loaded beside it (two model
copies resident). A failure must (1) unload the local engine's weights
BEFORE the HTTP fallback starts (the failure is likely memory pressure,
so the copies must never overlap), (2) route to HTTP without rebuilding
local for `localRetryCooldown`, and (3) rebuild + retry local once the
cooldown passes.

#### Suspended model verification must not resurrect runtime after explicit unload
`testExplicitUnloadInvalidatesSuspendedLocalResolution`: Model verification suspends outside the main actor. An older generate
and prewarm must not resume after an explicit unload and resurrect the
in-process runtime that shutdown just released.

#### Fixture uses a GGUF-magic stub; looksLikeGGUF checks only first 4 bytes
`GGUFFixture`: Builds a temp StorageManager rooted at a throwaway dir with a GGUF-magic
file and a matching custom catalog entry, so `resolvedModelURL` resolves
without a real multi-gigabyte model. `looksLikeGGUF` only checks the first 4
bytes are the ASCII magic "GGUF".

#### Inject fixture root directly; suite-wide storage override would hide the model
`GGUFFixture.init`: Inject the fixture root directly: a suite-wide storage environment
override takes priority over UserDefaults and otherwise hides this model.

### `LokalBotTests/Cotyping/Llama/CotypingFirstWordConfidenceTests.swift`

#### App switch changes midword healing as well as the confidence gate
`testNativeHybridMatchesCompositionAndNeverStreamsUncappedFallback`: Isolate confidence-gate composition under each shared healing policy.
The app switch intentionally changes midword healing as well as the gate.

#### Word-ending token counts toward first-word confidence, as in threshold measurement
`testTheFirstWordIsWeighedUpToTheTokenThatEndsIt`: The token that ends the word counts, as in the measurement the
threshold was chosen on: 0.5 × 0.3 × 0.5 = 0.075.

#### Runtime calls the callback serially; test reads only after awaiting it
`HybridCapturedResults`: The runtime calls the callback serially; the test reads only after awaiting it.

### `LokalBotTests/Cotyping/Llama/CotypingTokenCandidatesTests.swift`

#### Old implementation is the oracle; healing visits same candidates incl. rank-64 cutoff
`CotypingTokenCandidatesTests.repeatedArgmax`: The pre-optimization implementation is the behavioral oracle: healing
must visit exactly the same candidates, including its rank-64 cutoff.

### `LokalBotTests/Cotyping/Llama/CotypingTokenHealingTests.swift`

#### Fragment of exactly maxWordLength heals; longer URL-like fragments opt out
`testFragmentLengthLimitIsInclusive`: Contract: a fragment of exactly maxWordLength still heals; one more
word character (URL/identifier territory) opts out of healing.

#### Overshoot path must verify every remaining prefix byte
`testDivergingPieceIsMismatch`: Longer than the remaining prefix but diverging before its end: the
overshoot path must still verify every remaining byte.

#### BPE pieces can split a UTF-8 scalar; match at byte level
`testMatchesAtByteLevelInsideMultiByteScalar`: BPE pieces can split a UTF-8 scalar: a piece carrying only the first
byte of "ü" (0xC3) must consume that single byte, not be rejected for
failing to align on a Character boundary.

#### Contractions complete inside the constraint; apostrophe overshoot extends the word
`testApostropheExtendsTheWord`: Contractions must complete inside the constraint: overshooting
"don" with "'t" (don' -> don't) is word-extending.

#### Mid-scalar lead byte like 0xC3 counts as word-extending
`testMultiByteScalarLeadExtendsTheWord`: An overshoot can start mid-scalar; a lead byte like 0xC3 (first
byte of "ü") is always letter-ish and must count as word-extending.

#### Only the first extra byte decides whether an overshoot extends the word
`testPunctuationAndWhitespaceFirstBytesDoNotExtendTheWord`: Only the FIRST extra byte decides; letters after a boundary don't help.

#### Prefer overshoot that continues the word over one ending it at the caret
`testOvershootPreferencePairThroughMatch`: The runtime pairing: of two candidates overshooting " tomorro", the
one continuing the word (" tomorrow" -> extra "w") is preferred over
one ending it at the caret (" tomorro." -> extra ".").

#### Env flag ablation: same assertion must fail on the old decoder
`testNativePrefixSearchRetainsBaselineAndRestoresKVForSampling`: Test-only ablation: the same assertion must fail on the old decoder.

### `LokalBotTests/Cotyping/Llama/LlamaCotypingRuntimeTests.swift`

#### Test model from cache or env var, never checkout; macOS prompts for ~/Documents per host
`LlamaCotypingRuntimeTests.bundledModelPath`: Resolves the compact fallback model from the local cache or
`LOKALBOT_COTYPING_TEST_MODEL`, or skips. Never from the checkout:
macOS asks each new test host for access to ~/Documents.

#### Memory warning during suggestions keeps the model loaded to avoid reload
`testAMemoryWarningFreesTheModelOnlyAfterAMinuteIdle`: A memory warning while suggestions are coming leaves the model loaded,
so the next keystroke does not wait for a reload.

#### Test checks logical reuse signal only; CI hybrid SSM model always fully reprefills
`testReusedPrefixIsReflectedInPrefillTokenCount`: Validates the IncrementalPrefill reuse SIGNAL — the logical
`lastPrefillTokenCount` (prompt.count - sharedPrefix) — not the physical
reuse branch. The bundled CI model is hybrid SSM, so it always takes the
full-reprefill fallback; the arithmetic below holds on BOTH that fallback
and the production attention model's partial-reuse branch, so it cannot
observe physical suffix-only prefill on this fixture. The pure-attention
partial-reuse branch is exercised only on the production Gemma-4 model /
a manual run.

#### Readying after a pause never loads a model freed under memory pressure
`testTouchNeverLoadsAModel`: Readying the model after a pause must never load one: a model freed
under memory pressure stays freed until a suggestion is asked for.

#### Throwaway touch token goes after cached prompt and is removed again
`testTouchKeepsTheCachedPromptAndTheSuggestion`: The throwaway token goes after the cached prompt and comes out again,
so the next keystroke reads only what was typed and suggests the same.

### `LokalBotTests/Cotyping/Llama/LocalLlamaCotypingEngineTests.swift`

#### Test model from cache or env var, never the checkout
`LocalLlamaCotypingEngineTests.bundledModelPath`: The compact fallback model from the local cache or
`LOKALBOT_COTYPING_TEST_MODEL`, never the checkout (see
`LlamaCotypingRuntimeTests`).

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
