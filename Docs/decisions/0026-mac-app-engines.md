# 0026. Mac app: Engines

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LokalBot/Engines/`.

## Decisions

### `LokalBot/Engines/AnthropicEngine.swift`

#### Native Messages API because compat layer rejects notes schemas and lacks caching
`AnthropicAPI`: Anthropic's API, reached through the connected-provider Think connection
when its URL names `api.anthropic.com`. Think then speaks the native
Messages API: Anthropic's OpenAI compatibility layer rejects LokalBot's
notes schemas (`maxItems`, seen 2026-10-08) and has no prompt caching.

#### Beta gates fallbacks default: safety declines retried server-side on recommended model
`AnthropicAPI.serverFallbackBeta`: Gates `fallbacks: "default"`: a safety decline is retried server-side
on the model Anthropic recommends for the decline's category.

#### Origin and /v1 name same API, so build all requests from origin
`AnthropicAPI.versionedRoot`: `https://api.anthropic.com` and `…/v1` name the same API, so every
request is built from the origin.

#### Traits from Anthropic docs 2026-10; unparseable ids get no effort, unknown newer treated as 5
`AnthropicModelTraits`: What LokalBot relies on for one Claude model id, from Anthropic's model
documentation (2026-10). Ids it cannot parse (aliases, Claude 3) get no
effort control; unknown newer generations are treated like Claude 5.

#### output_config.effort values, least first; empty means send none
`AnthropicModelTraits.effortLevels`: `output_config.effort` values, least first. Empty: send no effort.

#### Unset thinking runs adaptive thinking whose tokens count toward max_tokens
`AnthropicModelTraits.thinksByDefault`: Leaving `thinking` unset runs adaptive thinking, whose tokens count
toward `max_tokens`.

#### Model accepts fallbacks default
`AnthropicModelTraits.serverFallback`: Accepts `fallbacks: "default"`.

#### Dated snapshot ids carry no minor version
`AnthropicModelTraits.init`: A dated snapshot ("claude-sonnet-4-20250514") has no minor version.

#### Opus 5.5 and Haiku 5.5 default to medium effort
`AnthropicModelTraits.init`: Claude Opus 5.5 and Claude Haiku 5.5 default to medium effort.

#### Move unsupported schema constraints into descriptions instead of failing with 400
`AnthropicSchema`: Anthropic structured outputs accept a JSON Schema subset. Like the
official SDKs, move each unsupported constraint into the field's
description, where the model still reads it, instead of failing the request
with a 400. LokalBot's parsers keep enforcing the real limits.

#### Documented unsupported keywords; minItems above 1 lowered to 1
`AnthropicSchema.unsupportedKeywords`: Documented as unsupported. `minItems` above 1 is lowered to 1 instead.

#### Cache breakpoints on system and shared context, varying instruction last, for 5-minute cache
`AnthropicEngine`: Claude through Anthropic's Messages API (`POST /v1/messages`).

Prompt caching: the system prompt and the shared context (a meeting's
transcript, a chat's history) carry cache breakpoints, and the varying
instruction comes last, so the next request over the same material reads
the prefix from Anthropic's 5-minute prompt cache instead of paying the
full input price again.

#### A 400 naming an optional field retries once without it
`AnthropicEngine.OptionalField`: Request fields a model may reject. A 400 naming one retries once
without it; generation never started.

#### Tests replace network; nil uses shared inference session
`AnthropicEngine.transport`: Tests replace the network; nil uses the shared inference session.

#### Whole reply must finish within 15-minute timeout at about 25 tokens per second
`AnthropicEngine.maximumWholeResponseTokens`: A whole reply must arrive within the shared session's 15-minute
resource timeout even at about 25 tokens per second.

#### No published enum limit, so reuse the 500 ceiling of other hosted servers
`AnthropicEngine.structuredOutputEnumLimit`: Anthropic publishes no enum limit, only that oversized schemas fail to
compile; keep the ceiling used for other hosted servers.

#### Cap by task budget; Automatic maps budget to effort; never send temperature
`AnthropicEngine.effort`: The effort for one request. A chosen level is capped by the task's
budget, as on other servers. On Automatic, a model that thinks by
default gets the level its task budget implies, so notes and digests
(budget 0) run at the lowest effort instead of spending their output
allowance on thinking. Temperature is never sent: current Claude
models reject non-default sampling.

#### Thinking shares max_tokens with the answer so allow room for both
`AnthropicEngine.maxTokens`: Thinking shares `max_tokens` with the answer, so a model that thinks
by default gets room for both.

#### Pure request construction so tests run offline without credentials
`AnthropicEngine.makeRequest`: Pure request construction, covered offline without credentials.

#### Sorted keys keep schema bytes stable for grammar and prompt cache reuse
`AnthropicEngine.makeRequest`: Sorted keys keep the schema's bytes stable across launches, so its
compiled grammar and the cached prompt prefix stay reusable.

#### Shared material first with breakpoint, instruction last; drop blank blocks the API rejects
`AnthropicEngine.userContent`: Shared material first with a breakpoint after it, the varying
instruction last. Blank blocks are dropped; the API rejects them.

#### Only optional fields the request actually sent can be treated as rejected
`AnthropicEngine.rejectedFields`: The optional fields a 400 names, limited to those the request sent.

#### Whole prompt including cache reads and writes, as other engines report it
`AnthropicEngine.Usage.promptTokens`: The whole prompt, cached or not, as other engines report it.

#### Streamed message_delta carries only counts that changed
`AnthropicEngine.Usage.merge`: A streamed `message_delta` carries only the counts that changed.

#### Join text blocks; fallback text continues declined partial so joining keeps whole reply
`AnthropicEngine.parseMessage`: Text blocks joined in order; thinking and fallback marker blocks are
not part of the answer. A server-side fallback's text continues the
declined partial, so joining keeps the whole reply.

#### Parse only data lines; event lines duplicate type and pings are skipped
`AnthropicEngine.parseStreamLine`: One `data:` line of a Messages stream. `event:` lines repeat the
payload's `type` and are skipped, as are pings and block boundaries.

#### 4xx responses mean rejected before generation, so zero output tokens
`AnthropicEngine.complete`: Anthropic validates and rate-limits before generating.

#### Stream answer text only; structured generation in a notes budget stays whole-response
`AnthropicEngine.generateStreaming`: Streams answer text only. Structured generation inside a notes budget
keeps the accounted whole-response path.

### `LokalBot/Engines/AppleIntelligenceEngine.swift`

#### FoundationModels is macOS 26 only; guard symbols so the 15.0 target compiles and falls back
`AppleIntelligenceEngine`: On-device summarization backend that satisfies `TextEngine` by running Apple
Intelligence in-process — no localhost server, no model download.

FoundationModels exists only in the macOS 26 SDK while LokalBot deploys to
15.0, so every framework symbol stays behind `#if canImport` plus
`if #available(macOS 26.0, *)`. On older systems `generate` throws instead,
which keeps the file compiling on the 15.0 target and lets the pipeline fall
back to another `TextEngine`.

#### Trim to about 3k tokens keeping the tail so the task instruction survives
`AppleIntelligenceEngine.maxPromptCharacters`: Upper bound on characters handed to the on-device model. Its context
window is small (~4k tokens shared across instructions, prompt, and the
reply), so we trim to roughly 3k tokens of input (≈4 chars/token) rather
than let the model reject an oversized prompt. We keep the *tail*: the
task instruction is appended last and must survive trimming.

#### Final throw is unreachable on macOS 26 but required so 15.0 build throws on every path
`AppleIntelligenceEngine.generate`: Unreachable once `current()` reported `.available` (only macOS 26+ with
the framework can), but required so the 15.0 build throws on every path
instead of relying solely on the guard above.

#### Same context-plus-prompt layout as localhost engines; static for unit testing
`AppleIntelligenceEngine.composePrompt`: Joins the context blocks and task prompt into one user turn, dropping
blank entries and capping length. `nonisolated`/`static` so it stays unit
testable without a model or the main actor. Mirrors the localhost engines'
`(context + [prompt]).joined("\n\n")` shape so backends agree on layout.

#### Trim the head so the trailing task instruction is preserved
`AppleIntelligenceEngine.cappedToTail`: Returns the last `limit` characters of `text` (the whole text when
shorter). Trimming the head preserves the trailing task instruction.

#### Generation failures map to badResponse so pipeline treats them like other engines
`AppleIntelligenceEngine.respond`: Single-turn request against the default system model. Generation failures
(guardrails, unsupported language, oversized prompt, …) map to
`badResponse` so the pipeline treats them like any other engine error.

#### Unknown default keeps compiling when Apple adds error cases
`AppleIntelligenceEngine.message`: Maps Apple's generation errors to short, user-facing sentences. The
`@unknown default` keeps us compiling if Apple adds cases in a later SDK.

### `LokalBot/Engines/AppleSpeechEngine.swift`

#### Vocabulary hints deduplicated and capped at Apple Speech's 100-phrase limit
`AppleSpeechVocabulary.contextualStrings`: Parses comma-, semicolon-, middot-, or newline-separated vocabulary hints
into deduplicated phrases capped at Apple Speech's 100-phrase limit.

#### macOS 26 Speech symbols behind canImport and availability to keep 15.0 target
`AppleSpeechEngine`: On-device transcription via Apple's macOS 26+ `SpeechAnalyzer` framework.

Mirrors `AppleIntelligenceEngine` by keeping macOS 26 `Speech` symbols
behind `#if canImport(Speech)` and `@available(macOS 26.0, *)` so the
macOS 15.0 deployment target stays intact.

#### Keep the full result span when some recognized words lack usable time
`AppleSpeechEngine`: Keep the full result span when some recognized words have no usable time.

### `LokalBot/Engines/FunASRNanoEngine.swift`

#### Immutable per-selection paths stop a folder change redirecting a running meeting
`FunASRNanoEngine`: Immutable per-selection paths prevent a folder change from redirecting an
already-running meeting. Only the bundled runtime is executed.

#### Load a short synthetic input to catch corrupt graphs before replacing the working model
`FunASRNanoEngine.prepare`: Loading a short synthetic input catches incompatible/corrupt graphs
before the selection replaces the current working model.

### `LokalBot/Engines/FunASRNanoModel.swift`

#### User-owned files: validation never writes receipts or moves them
`FunASRNanoModel`: The sherpa-onnx export of FunAudioLLM/Fun-ASR-Nano-2512. These files
remain owned by the user: validation never writes receipts or moves them.

#### Identity from file revisions without reading gigabytes; tokenizer changes invalidate transcripts
`FunASRNanoModel.checkpointIdentity`: Include the resolved files and their revisions without reading gigabytes
of weights on every resume. Tokenizer changes also invalidate transcripts.

#### Lightweight readiness check, symlinks allowed; runtime validates ONNX graphs later
`FunASRNanoModel.usableFile`: Lightweight readiness check; the runtime checks actual ONNX graphs
during preparation. Support symlinks used by local model caches.

#### Runtime takes language names, not ISO codes
`FunASRNanoModel.arguments`: The runtime takes language names, not the app's ISO language codes.

### `LokalBot/Engines/GraniteSpeechEngine.swift`

#### Granite runs on bundled llama.cpp server, local-only, GGUF and projector downloaded on first use
`GraniteSpeechEngine`: IBM Granite Speech 4.1/5.0 2B through the bundled llama.cpp server. The model is
local-only: first use downloads the GGUF model and multimodal projector from
Hugging Face, then LokalBot talks to llama-server's OpenAI-compatible audio
transcription endpoint on localhost.

#### Vocabulary capped to leave room in the 4,096-token server context
`GraniteSpeechEngine.maximumVocabularyCharacters`: Leave room for audio and decoded text in the 4,096-token server context.

#### Prewarm must not pin Granite for a meeting; transcription refreshes two-minute idle window
`GraniteSpeechEngine.releaseConfigurationUse`: Recording-time prewarm must not pin Granite for an entire meeting.
Actual transcription refreshes the same two-minute idle window.

#### Download via shared stack, ranged when CDN supports, validate, install atomically
`GraniteSpeechEngine.downloadIfNeeded`: Fetches one GGUF through the shared download stack (ranged when the CDN
supports it, with real progress either way), validates, and installs it
atomically.

#### Send language hint only when set; omitting it preserves real auto-detect
`GraniteSpeechEngine.makeTranscriptionRequest`: llama.cpp's transcription endpoint appends this ISO language
hint to the ASR prompt. Omitting it preserves real auto-detect.

#### Snapshot facade; shared actor serializes configuration switches but shares loaded model
`ConfiguredGraniteSpeechEngine`: Immutable façade captured with one settings snapshot. The shared actor
serializes switches between different Granite configurations while still
allowing concurrent tracks to use the same loaded model.

### `LokalBot/Engines/InferenceBroker.swift`

#### One actor owns llama-server start/stop; consumers take leases that pin and allow idle unload
`InferenceBroker`: One actor owns when the shared llama-server runtimes start and stop.
Consumers take leases instead of calling `ensureRunning` directly: a
lease boots on demand, pins the model during use, and makes the server
eligible for an idle unload after the final release.

#### Tests inject recorders instead of launching real llama-server
`InferenceBroker.RuntimeHooks`: Start/stop hooks for one role. Tests inject recorders rather than
launching real llama-server processes.

#### Claim role for a model before first lease to close actor reentrancy gap
`InferenceBroker.selectedModelPaths`: Claims the role for a model before the first lease record is inserted,
closing the actor-reentrancy gap between waking a cohort and acquisition.

#### Publish the pin before ensuring runtime; remove record and rethrow on failure
`InferenceBroker.lease`: Records and publishes the pin before ensuring the runtime. If ensure
fails, the record is removed and the original runtime error propagates.

#### Treat cancelled-ensure rollback like final release so server cannot stay resident
`InferenceBroker.lease`: ensure may already have started the runtime before the task
was cancelled. Treat rollback like the final release so a
zero-lease server cannot remain resident indefinitely.

#### Admit one model cohort at a time; different weights wait until cohort releases
`InferenceBroker.resumeEligibleWaiters`: When a role becomes free, admit one model cohort. All callers waiting
for those same weights can share the server; different weights remain
queued until the cohort releases every lease.

### `LokalBot/Engines/InferenceLease.swift`

#### Priorities only recorded; eviction stays LRU plus pins, priority eviction deferred
`InferencePriority`: Who is waiting on an inference request, in increasing order of
deferability. Step 1 records priorities for the dashboard and the broker
API; eviction stays LRU+pins — priority-ordered eviction is a step-2
concern once pressure-derived budgets exist.

#### Interactive means the user is watching: chat, cotyping, model test
`InferencePriority.interactive`: The user is watching this happen (chat, cotyping, model test).

#### Agent priority means an agent is waiting: Agent Mode or ask_library
`InferencePriority.agent`: An agent is waiting (Agent Mode session, external ask_library).

#### Pipeline is processing the person opens next, ahead of scheduled work
`InferencePriority.pipeline`: Processing the person will open next: notes for a meeting that just
ended or that they asked to summarize. Ahead of scheduled work.

#### Background is scheduled work nobody waits for
`InferencePriority.background`: Scheduled work nobody is waiting for (digests, Dream, briefs, embeddings).

#### Broker owns three shared servers; Granite's private ASR server pins ModelResidency directly
`InferenceRole`: The three shared llama-server runtimes the broker owns in step 1.
Granite's private ASR server holds direct ModelResidency pins during
preparation/transcription; it does not need a broker role.

#### Matches the ledger id LlamaServer registers under
`InferenceRole.residencyID`: Matches the ledger id `LlamaServer` registers under.

#### Linger long enough for bursty use, short enough to free RAM in minutes
`InferenceRole.defaultLingerSeconds`: How long the server stays resident after its last lease releases —
long enough that bursty consumers (chat follow-ups, typing) don't pay
a model reload, short enough that the RAM comes back within minutes.

#### While a lease is open the model cannot be evicted by the residency budget
`InferenceLease`: A claim on a running model: held for one request (or one Agent Mode
session). While any lease on a role is open, that model cannot be evicted
by the residency budget.

#### Lease holds one model path for its lifetime; other models queue
`InferenceLease.modelPath`: Canonical weights path served for the entire lifetime of this lease.
Leases on the same role but a different model are queued by the broker.

#### Pure bookkeeping without clocks or I/O so it is unit-testable
`LeaseBook`: Pure lease bookkeeping. The broker actor owns one; keeping the arithmetic
here (no clocks, no tasks, no I/O) makes it unit-testable the same way
`ModelResidencyPolicy` is.

#### Residency ids that must never be eviction victims
`LeaseBook.pinnedResidencyIDs`: Residency ids that must never be eviction victims right now.

#### Dashboard strings ordered by priority then purpose for stable display
`LeaseBook.descriptionsByResidencyID`: Dashboard strings per residency id, e.g. "chat (interactive)",
ordered by priority then purpose so the display is stable.

### `LokalBot/Engines/InferenceURLSession.swift`

#### Redirects may change path but never move prompts or credentials to another origin or port
`InferenceURLSession`: The engine entry point authorizes its configured origin. Redirects may
change a path on that origin, but cannot transfer prompts or credentials to
another server (including a different loopback port).

### `LokalBot/Engines/KokoroSpeechEngine.swift`

#### Stop playback before unlinking the plaintext WAV
`SpeechTemporaryOutputCleanup.cleanup`: Releases playback first so a caller never unlinks the plaintext WAV
while AVFoundation may still need it.

#### Create exit signal before awaits that can move the task off the launching thread
`KokoroSpeechEngine`: The awaits below can move this task off the launching thread,
where `waitUntilExit()` could wait forever.

### `LokalBot/Engines/LeasedTextEngine.swift`

#### Decorator leases per call; runtime boots on first use and is pinned only while active
`LeasedTextEngine`: A `TextEngine` decorator that runs every call under an inference lease.
Construction stays cheap; the runtime boots on first use and remains
pinned against eviction only while a call is active.

#### Streaming is single-shot so a replay cannot duplicate displayed text
`LeasedTextEngine.generateStreaming`: Streaming remains single-shot: a recovery replay could duplicate text
the user has already seen. Keep the model leased through the stream.

#### Replay once after a vanished runtime; raw and streaming stay single-shot
`LeasedTextEngine.withManagedRecovery`: A managed localhost runtime can disappear after lease acquisition but
before its HTTP response arrives. Releasing and reacquiring the lease
runs the broker's existing health/configuration check, which starts a
replacement server when needed. Generation is side-effect free, so one
replay is safe; raw/streaming completions deliberately stay single-shot
because callers may already have displayed partial text.

### `LokalBot/Engines/LlamaServer.swift`

#### 32K context balances headroom against latency and KV cost; High reasoning budget rules
`MainLLMRuntimePolicy`: Shared quality policy for the Main LLM. The bundled models expose much
larger native windows, but 32K gives summaries and Agent Mode useful
headroom without paying the latency and linear KV-cache cost of 128K.

"High" forces model-native thinking. App-authored requests use an 8K
ceiling; requests that set a smaller total output budget reserve at least
half of it for the visible answer (see
`OpenAICompatibleEngine.applyGenerationOptions`). Agent Mode uses the same
reasoning-enabled server with its model-native budget.

#### Vendor sampling overrides scoped per built-in model; extraBody merged after request options
`MainLLMRuntimePolicy.requestOverrides`: Keep vendor-specific sampling guidance scoped to the built-in model
that requires it. `extraBody` is merged after per-request options, so
these values consistently replace the generic digest temperature.

#### Mistral recommends temperature below 0.1 for this checkpoint
`MainLLMRuntimePolicy.requestOverrides`: Mistral recommends temperature below 0.1 for this checkpoint.

#### One model loaded at a time; switching restarts the server; stopped on quit
`LlamaServer`: Built-in LLM backend, part 3 of 3: the bundled llama-server subprocess
lifecycle. One model loaded at a time; switching models restarts the server.
Stopped when the app quits.

#### No pooling flag since GGUF has its own; batch at full context for single micro-batch
`LlamaServer.embedder`: Embeddings instance (semantic search) — small model, second port.
EmbeddingGemma's GGUF carries its own mean pooling and projection, so
no pooling flag is passed (one would override them). As a bidirectional
encoder it must see each input in a single micro-batch; real 1,500-
character OCR reaches about 950 tokens, so batch at the full context.

#### Separate cotyping server on third port avoids contention and model-reload thrash
`LlamaServer.cotyping`: Cotyping instance — an optional separate (typically smaller/faster)
model on a third port, so inline suggestions never contend with the
summarizer for the shared server (no model-reload thrash).

#### Role is nil for a private instance on an explicit port
`LlamaServer.role`: Nil for a private instance on an explicit port (tests, replays).

#### Added to the inherited environment of the server process
`LlamaServer.environment`: Added to the inherited environment of the server process.

#### App servers use this app copy's port for their role
`LlamaServer.init`: One of the app's servers, on this app copy's port for `role`.

#### 256-bit mode-0600 bearer, available before lazy boot so leased engines send it
`LlamaServer.authenticationToken`: Shared bearer required by this private localhost server. It is created
with 256 bits of randomness, stored mode 0600, and can be obtained
before the lazy server boot so leased engines carry the right header.

#### Health wait allows minutes for page-in; crashes end it early so limit catches hangs
`LlamaServer.startupHealthAttempts`: How long a started server may take to report healthy. A Mac that has
just booted can page a model in for minutes, and a load that crashes
ends this wait at once, so the limit only has to catch a hung server.

#### Loop so a different-model caller starts a replacement flight; same-model callers share it
`LlamaServer.ensureRunning`: A caller for a different model may have owned the flight we just
awaited. Loop so this request starts one replacement flight;
callers for the same model return together without duplicate
subprocess starts or health polling.

#### Ledger row also covers adopted healthy servers since weights are resident
`LlamaServer.residencyID`: This server's row in the app-wide model-memory ledger. Adopted healthy
servers register too — their weights are just as resident as ours.

#### Diagnostics never gate inference; keep row with estimate when process identity unavailable
`LlamaServer.registerResidency`: Diagnostics must never gate inference. When libproc cannot provide a
stable process identity, retain the model row with its weight-size
estimate and let a later successful registration add live telemetry.

#### Claim an orphan only after owner exited and exclusive runtime lock acquired
`LlamaServer.claimOrphanedMarker`: An orphan can be claimed only after its owning app exited and this
instance acquired the exclusive runtime lock.

#### Never adopt a live app's helper; our eviction or shutdown would interrupt its work
`LlamaServer.start`: A live app owns its helper even when this app wants the same model.
Never adopt it: our later eviction/shutdown would interrupt its work.

#### Evict least-recently-used models before the subprocess mmaps weights
`LlamaServer.start`: Make room before the subprocess mmaps the weights: evict the
least-recently-used other models if this one would bust the budget.

#### -ngl 99 offloads everything to Metal
`LlamaServer.start`: full Metal offload

#### --jinja gives correct chat templates for qwen3 and gpt-oss
`LlamaServer.start`: correct chat templates (qwen3, gpt-oss)

#### Weights understate footprint; add per-role allowance and mmproj file to admission
`LlamaServer.estimatedResidentBytes`: Weight files are not the whole llama footprint: prompt cache, KV, and
multimodal projector allocations can be several GiB. Keep an explicit
per-role allowance and include any `--mmproj` file in admission.

#### Explain start failure from server output; full tail goes to diagnostics log
`LlamaServer.startupFailure`: Says why a start failed, from the server's own output; the full tail
goes to the diagnostics log. No request has reached it yet.

#### Terminate adopted server by PID marker so eviction and ledger reflect real memory
`LlamaServer.stop`: A healthy server can be adopted from a previous app process. It
has a validated PID marker but no Foundation `Process` handle;
still terminate it so eviction and the resource ledger reflect
real memory residency instead of only hiding the row.

#### Failed start reports its own output via startupFailure
`LlamaServer.processDidTerminate`: A failed start reports its own output (`startupFailure`).

#### Prove old helper by exact executable and start identity, not filename suffix
`LlamaServer.stopRecordedServerIfOwned`: The old owned helper can be from the previous bundled runtime. Its
exact executable and start identity, not a filename suffix, prove it.

#### Orphan recovery is best effort; startup must not depend on it
`LlamaServer.writePidMarker`: Best-effort orphan recovery only; startup must not depend on it.

#### Never reduce reported absolute path to basename; same-named different file must fail
`LlamaServer.servesModel`: llama.cpp builds report either the model's full path or its filename.
Do not reduce a reported absolute path to a basename: a different file
with the same name must fail. The caller also verifies the PID marker's
exact model path, executable, context size and arguments before reuse.

#### Kill launchd-reparented LokalBot helpers with no live owner marker that block the port
`LlamaServer.stopOrphanedHelpers`: Stops LokalBot llama-servers that hold `port` after their app died:
reparented to launchd, running from a LokalBot `llama-cpp` runtime,
and named by no PID marker with a live owner (an app that adopted it).
Another copy (Dev, UI Test Host, unit tests, an older release) can
leave one behind, and it would block this server until it is killed.
Returns the PIDs that are gone.

#### Returns runtime folder and start time only for LokalBot helpers whose app is gone
`LlamaServer.orphanedHelper`: The runtime folder and start time of `pid` when it is a LokalBot
llama-server whose owning app is gone; nil otherwise.

#### Unreadable folder returns nil so it is not mistaken for no live owner
`LlamaServer.recordedMarkers`: Every PID marker in a runtime folder; nil when the folder cannot be
read, which must not pass for "no live owner".

#### SIGTERM then SIGKILL after two seconds; start time guards against PID reuse
`LlamaServer.terminate`: SIGTERM, then SIGKILL after two seconds. The start time keeps a reused
PID from being signalled. Returns whether the process is gone.

#### Copy binary out of bundle to Application Support; never execute from Resources
`LlamaServer.installedBinary`: llama-server + dylibs are copied out of the bundle into Application
Support on first run (never execute from inside Resources), then
reused. Re-copied if the bundled version changes.

#### Unavailable owner identity is uncertainty, not proof the owner died
`LocalLlamaServerPolicy.canClaim`: An unavailable identity is uncertainty, not proof a live owner died.

#### Orphan means executable in a llama-cpp runtime under LokalBot Application Support
`OrphanedLlamaServerPolicy`: Recognizes a llama-server that a LokalBot copy started and then lost. Its
executable sits in a `llama-cpp` runtime under one of LokalBot's
Application Support folders, next to the PID markers that copy writes.

#### Runtime folder shape is app-support/bundle-id[.suffix]/llama-cpp/.../llama-server
`OrphanedLlamaServerPolicy.runtimeFolder`: `<applicationSupport>/me.dotenv.LokalBot[.<suffix>]` when `path` is
`<that folder>/llama-cpp/…/llama-server`; nil for anything else.

#### Owner with unconfirmable identity counts as alive; helper never stopped
`OrphanedLlamaServerPolicy.markerShowsLiveOwner`: Whether `marker` shows a live app owning the helper that started at
`helperStartTime`. An owner whose identity cannot be confirmed counts
as alive: a helper an app may still be using is never stopped.

#### Marker from an earlier process with this PID says nothing
`OrphanedLlamaServerPolicy.markerShowsLiveOwner`: A marker left by an earlier process with this PID says nothing.

#### Held for entire helper lifetime so a second instance fails instead of sharing
`LocalRuntimeOwnershipLock`: Held for the entire helper lifetime, including health checks and shutdown.
A second instance fails explicitly instead of sharing a process it can kill.

#### Keep all lines until first health pass, then only crash lines, for privacy
`LlamaServerOutputTail`: The tail of llama-server's stderr, kept in memory to explain a failure.
Until the first health check passes the server has seen no request, so
every line is kept and a failed start can say why. After that only crash
lines are kept: request errors can echo request text, and diagnostic logs
never hold transcripts or screen text (PRIVACY.md).

#### Bound unterminated line growth
`LlamaServerOutputTail.append`: An unterminated line cannot grow without bound.

#### First error line is the cause; later lines are consequences
`LlamaServerOutputTail.reason`: The first line that reports an error; the lines after it are usually
its consequences ("failed to load model", "exiting").

#### Caller must hold the lock
`LlamaServerOutputTail.keep`: Caller holds `lock`.

#### Strip llama.cpp timestamp and level prefix from log lines
`LlamaServerOutputTail.keep`: "0.00.077.284 E gguf_init_from_reader: …": drop the time and level.

#### Drop JSON parse errors after start because they quote request text
`LlamaServerOutputTail.keep`: A JSON parse error quotes the text it was reading.

### `LokalBot/Engines/MetaModelAPI.swift`

#### Meta Model API origin; only fast live text still uses it, sharing key and approval
`MetaModelAPI`: Meta's Model API (`https://api.meta.ai/v1`, OpenAI-compatible chat
completions). Live Radar and Follow-through began here, for the Meta
Global AI Developer Hackathon (2026), and now run on the Think model
(`ThinkChat`); the hosted film of them and the replay harnesses still
speak this wire format. In the app, only fast live text (`MuseLiveText`)
still uses Meta: it shares this key and origin approval.

#### Standard models only; contributor variants grant Meta training rights on meeting text
`MetaModelAPI.Model`: Standard models only. Contributor variants trade a discount for Meta's
right to train on the content, which meeting text must never grant.

#### Prices are US dollars per million tokens, dev.meta.ai Oct 2026
`MetaModelAPI.Model.inputPrice`: US dollars per million tokens (dev.meta.ai pricing, Oct 2026).

#### Reasoning and visible output billed at the output rate
`MetaModelAPI.cost`: Reasoning and visible output are billed at the output rate.

#### Origin approval shared with Think servers, so revoking either stops both
`MetaModelAPI.client`: The key and approval a request needs, or why it can't be sent. The
origin approval is the same list Think servers use, so revoking it in
either place stops both.

#### Shares origin gate with Think and stays on approved origin; reply shapes feed ThinkChat
`MuseChatClient`: One `/chat/completions` call with optional function tools or a strict JSON
schema, with token use, for the hosted film and the replay harnesses. Its
reply and message shapes are also what `ThinkChat` hands the radar and
Follow-through loops. Requests share the origin's `RemoteInferenceGate`
with Think and stay on the approved origin (`InferenceURLSession` rejects
cross-origin redirects).

#### Model JSON may not match tool schema, so callers validate
`MuseChatClient.ToolCall.arguments`: The JSON object string the model produced. It is not guaranteed to
match the tool's schema, so callers validate it.

#### Allowed efforts minimal through max; Muse models reject none
`MuseChatClient.reasoningEffort`: minimal, low, medium, high, xhigh or max. Muse models reject "none".

#### Reasoning tokens count against max tokens
`MuseChatClient.maxTokens`: Reasoning tokens count against this limit too.

#### Pure construction so offline tests cover the wire format
`MuseChatClient.makeRequest`: Pure construction, so the wire format is covered by offline tests.

#### tool_choice auto is the only value Meta accepts; others return 400
`MuseChatClient.makeRequest`: The only value Meta accepts; anything else is HTTP 400.

#### Append assistant text plus every tool call before tool results, as the API requires
`MuseChatClient.assistantMessage`: The assistant message to append before tool results, as the API
requires: its text plus every tool call it made.

### `LokalBot/Engines/ModelCatalog.swift`

#### Runtime split: catalog here, downloads in ModelDownloadManager, server in LlamaServer
`ModelCatalog`: Built-in LLM backend, part 1 of 3: the model catalog + on-disk validation.
A bundled llama.cpp `llama-server` (Metal) speaks the OpenAI-compatible API
on localhost. Users choose and download GGUF models on demand into
Application Support. No Ollama / LM Studio required.

Runtime split (mirrors the lifecycle/prompt/lifecycle separation): catalog
here, download orchestration in `ModelDownloadManager.swift`, the server
subprocess in `LlamaServer.swift`.

#### Legacy persisted field kept so custom-model settings still decode
`ModelCatalog.Entry.disablesThinking`: Legacy persisted hint from the pre-high-reasoning runtime. Retained
so existing custom-model settings keep decoding; the Main LLM now
applies one explicit reasoning policy at the server/request layer.

#### Older custom entries kept digest in URL fragment; migration path preserved
`ModelCatalog.Entry.expectedSHA256`: Built-ins store the digest directly. Older custom entries carried it
in the URL fragment, so preserve that migration path as well.

#### Older entries recover byte count from decimal GB value
`ModelCatalog.Entry.expectedSizeBytes`: New entries persist the exact byte count. Entries saved by the
previous build can recover it from the round-trippable decimal GB
value that was originally derived from Hugging Face's byte count.

#### Default autocomplete model qualified on shared next-word corpus
`ModelCatalog.qualityCotypingID`: Default autocomplete model qualified on the shared next-word corpus.

#### Fresh installs preselect a smaller Main LLM; larger ones stay selectable
`ModelCatalog.defaultSummarizationID`: Main LLM preselected for every fresh install. Larger models remain
available in Settings → Models for users who prefer maximum quality.

#### Cotyping pickers cap size because heavy models are counterproductive at keystroke latency
`ModelCatalog.keystrokeScaleMaxGB`: Ceiling for models offered in the cotyping pickers. Cotyping runs at
keystroke latency; the heavyweight summarization models above this
size are counterproductive there (and still selectable for the Main
LLM, where they belong).

#### Deny-set not Entry field, since Entry is persisted Codable; 2.6B LFM is not a completion model
`ModelCatalog.excludedCotypingIDs`: Models hidden from new cotyping picks. A deny-set rather than an
`Entry` field: `Entry` is Codable and persisted in
`AppSettings.customBuiltInModels`, so its stored shape must not churn.
The 2.6B LFM is an always-reasoning Main LLM candidate, not a
keystroke-latency completion model.

#### Catalog roughly ordered from tiny fallbacks to higher-quality options
`ModelCatalog.entries`: Local GGUF catalog, roughly ordered from tiny fallbacks to higher-quality
meeting-summary and cotyping options.

#### Always keep the selected model visible so a choice never silently disappears
`ModelCatalog.keystrokeScaleEntries`: The cotyping pickers' catalog: keystroke-scale built-ins plus every
custom entry, always keeping the currently selected model visible so
an existing choice never silently disappears from its own picker.

#### Downloaded models live in storage/models
`ModelCatalog.localURL`: Downloads live in \<storage>/models/.

### `LokalBot/Engines/ModelDownloadManager.swift`

#### One download path: ParallelRangeDownloader, then validate and atomically install
`ModelDownloadManager`: Built-in LLM backend, part 2 of 3: model download orchestration. Validated,
staged downloads of catalog (and, via `download(url:fileName:id:)`, arbitrary
Hugging Face) GGUF models into \<storage>/models/. One download path:
`ParallelRangeDownloader` (which falls back to a streamed single GET
internally), then validate + atomically install.

#### Downloader signature: URL, session, resume stash dir, pinned SHA-256, progress sink
`ModelDownloadManager.StagedDownloader`: Downloads a model to a staged temp file: the network URL, the session,
the resume stash directory, the pinned SHA-256 (nil when there is none),
and the progress sink.

#### Policy-breaking saved source fails identically on every retry
`ModelDownloadManager.PreparationError.unusableSource`: The saved download source breaks the download policy, so every
retry of the same source fails the same way.

#### Progress keyed by entry id, fraction 0 to 1
`ModelDownloadManager.progress`: entry id → 0…1

#### Hash legacy files once with shared task so callers do not rehash multi-GB models
`ModelDownloadManager.verifiedExistingURL`: Resolve an on-disk model only after its pinned digest has been checked.
Legacy files without a marker are hashed once; the shared verification
task prevents simultaneous summary, Agent, and cotyping callers from
hashing the same multi-gigabyte model independently.

#### Await the same single-flight download as UI to avoid races and give actionable errors
`ModelDownloadManager.ensureAvailable`: Await the same single-flight download used by the Models UI. This keeps
first-use callers (meeting summaries, day digests, Agent Mode) from
racing a second download and turns preparation failures into actionable
pipeline errors instead of a generic "model missing" response.

#### Idempotent per id; known size gates download on free disk space up front
`ModelDownloadManager.download`: Generic GGUF download keyed by an arbitrary id (catalog id, or a Hugging
Face "\<repo>/\<file>" key for browsed models). Idempotent per id.
`expectedSizeGB` (when known) gates the download on free disk space up
front instead of failing after gigabytes have moved.

#### Resume stash in models folder: same volume as install, not reaped by macOS
`ModelDownloadManager.download`: Resume stash inside the models folder (not the system temp dir):
it's on the same volume as the final install and macOS won't reap a
half-finished 17 GB download between attempts.

#### Credit already-stashed bytes in disk check so resumes that fit are not refused
`ModelDownloadManager.download`: Credit bytes an interrupted attempt already stashed: a retry only
fetches the remainder (and an invalidated stash is deleted first,
freeing the same bytes), so requiring the full size again would
refuse resumes that fit fine.

#### Downloader owns partials until return; this task removes the complete staged file on cancel
`ModelDownloadManager.download`: ParallelRangeDownloader owns resumable partials until it
returns. Once it hands back a complete staged file, that URL
is non-resumable and this task owns removing it if SHA work
is cancelled or the generation is superseded.

#### Pickers share refusal so never-downloadable custom models are flagged, not offered
`ModelDownloadManager.sourceRefusal`: Why `download` refuses a saved source before any bytes move, or nil.
The pickers share this so a custom model that can never download (a
Hugging Face link saved before pinning) is flagged, not offered.

#### Refuse plaintext so tampered downloads never reach the digest check
`ModelDownloadManager.sourceRefusal`: Every model source today (catalog, HF Browse) is HTTPS; refusing
plaintext keeps a tampered download from ever reaching the digest
check, and keeps non-HF custom URLs on the same encrypted footing.

### `LokalBot/Engines/ModelDownloadRouting.swift`

#### Only pinned HF resolve URLs reroute; mirror files accepted only when size and SHA match
`ModelDownloadRouting`: Routes pinned Hugging Face file downloads through the source chosen in
Settings → Models (see `ModelDownloadSource`).

Only `https://huggingface.co/<owner>/<repo>/resolve/<revision>/<path>` URLs
are rerouted. The Hugging Face API, GitHub archives and every other host are
untouched, and stored URLs keep their Hugging Face host, so
`ModelDownloadManager`'s pinning policy still applies to them. The chosen
mirror is tried first and each later source is a fallback. A file a mirror
served is accepted only when it matches the caller's pinned size and
SHA-256; otherwise the next source is tried. Callers verify every file again,
exactly as with Hugging Face, which stays a single direct download.

#### SettingsStore is the single place the source enters the process
`ModelDownloadRouting.source`: The source chosen in settings. `SettingsStore` is the one place it
enters the process, as with `SpeakerAttribution.microphoneIsUser`.

#### Path stays percent-encoded as in the URL
`ModelDownloadRouting.ResolvedFile`: A Hugging Face `resolve` URL split into its parts. `path` stays
percent-encoded, as it appears in the URL.

#### ModelScope follows branches not revisions; listing check keeps files matching the pin
`ModelDownloadRouting.candidates`: ModelScope follows branches, not Hugging Face revisions; the listing
check in `modelScopeServes` keeps it to files that match the pin.

#### ModelScope qualifies only on same path and pinned SHA-256; SHA-1-pinned files use HF-Mirror
`ModelDownloadRouting.modelScopeServes`: Whether ModelScope serves exactly the pinned file: its listing has the
same path with the pinned SHA-256 (and size, when both are known).
Files pinned only by a Git blob SHA-1 never qualify; HF-Mirror serves them.

#### Pass pinned size and digest: ModelScope needs digest, mirror files are checked against both
`ModelDownloadRouting.download`: Downloads `url` to a temp file through the chosen source. Pass the
caller's pinned size and SHA-256 (a 64-hex digest) when it has them:
ModelScope needs the digest, and a mirror's file is checked against both
before it is accepted.

#### Testable core takes attempt and listing closures
`ModelDownloadRouting.download`: Testable core: `attempt` downloads one candidate URL to a temp file and
`listing` returns a ModelScope repository's files by path.

#### Listings fetched once per repository per launch; failures not cached
`ModelScopeListings`: ModelScope repository listings, fetched once per repository per launch.
A failed fetch is not cached, so a later download can try again.

### `LokalBot/Engines/ModelResidency.swift`

#### One RAM budget with LRU eviction; GGUF ledger here, policy pure; CoreML/MLX non-evictable
`ModelResidency`: App-wide ledger of which model weights are resident in memory, with a RAM
budget and least-recently-used eviction. The llama runtimes (`LlamaServer`
instances and the in-process cotyping runtime) register on load, touch on
reuse, and consult `willLoad` before pulling new weights in so the app
never silently stacks a summarizer, an embedder, and a cotyping model past
what the machine can hold.

GGUF rows include weights plus a role-specific cache/KV allowance. Retained
CoreML/MLX reservations are supplied as non-evictable bytes by
`ModelRuntimeRegistry`, so every local model load consults one RAM budget.
Eviction choices live in `ModelResidencyPolicy` (pure, unit-tested); this
class owns the mutable GGUF ledger and the `@Published` UI mirror.

#### PID only for out-of-process runtimes; in-process footprint cannot be attributed
`ModelResidency.Resident.processIdentifier`: Present for out-of-process runtimes so diagnostics can report the
helper's live footprint. In-process models leave this nil because the
app footprint cannot be attributed to one model accurately.

#### Start time pairs with PID so reused PIDs are not mistaken
`ModelResidency.Resident.processStartTime`: Paired with the PID so a stale row can never be mistaken for an
unrelated process after macOS reuses that identifier.

#### Pinned by leases from InferenceBroker; never evicted but count toward budget
`ModelResidency.pinnedIDs`: Residency ids currently pinned by open inference leases (pushed by
`InferenceBroker`). Pinned rows are never eviction victims; they still
count toward the budget. Descriptions are dashboard strings per id,
e.g. "chat (interactive)".

#### Unload hooks kept out of Resident so it stays a plain Equatable value
`ModelResidency.unloaders`: Unload hooks by resident id, kept out of `Resident` so it stays a
plain Equatable value for the UI.

#### Generations stop a stale shutdown task unregistering a replacement model
`ModelResidency.registrationGenerations`: A runtime can stop and restart while an older shutdown task is still
finishing. Generations keep that stale task from unregistering the
replacement model that now occupies the same logical residency id.

#### Budget is half of physical RAM, leaving the rest for app and engines
`ModelResidency.budgetBytes`: Weights budget: half of physical RAM by default, leaving the other
half for the app, transcription engines, and everything else.

#### Private runtimes join the governor without a broker role; publish pin before use
`ModelResidency.pin`: Private runtimes participate in the same governor without requiring a
broker role. Publish the pin before preparing or using their weights.

#### Remove row only if still the caller's registration; shutdown can finish late
`ModelResidency.unregister`: Removes a row only if it is still the registration created by the
caller. Used by subprocess shutdown paths, which can finish after a
replacement process has already registered under the same id.

#### Evict LRU residents, never the incoming id, until bytes fit; call before loading
`ModelResidency.willLoad`: Evict least-recently-used residents (never `id` itself — a model swap
on the same runtime replaces in place) until `bytes` fits the budget.
Call right before loading new weights.

#### Rebuild eviction plan after every suspending unload to avoid stale victims
`ModelResidency.willLoad`: Every unload suspends. Rebuild the plan so a new pin, a smaller
replacement, or another admission cannot leave stale victims.

#### Drop ledger row first so victim's own unregister is a no-op
`ModelResidency.willLoad`: Drop the ledger row first so the victim's own unregister call
(from its unload path) is a harmless no-op.

#### Every caller registers file size so ledger entries are comparable
`ModelResidency.weightBytes`: File size of the weights at `url` (0 if unreadable) — the bytes every
caller registers with, so ledger entries stay comparable.

#### LRU victims excluding incoming and pinned; oversize newcomer evicts all unpinned and loads anyway
`ModelResidencyPolicy.evictions`: IDs to evict, least-recently-used first, so the surviving residents
plus the incoming load fit `budgetBytes`. The incoming id is never a
victim, and neither is any pinned id — an open inference lease means a
request is running against those weights right now. Pinned bytes still
count toward the total, so admission stays honest. When the newcomer
alone exceeds the budget, everything unpinned is evicted and the load
proceeds best-effort — refusing to load would break the feature the
user just asked for.

### `LokalBot/Engines/ModelRuntimeRegistry.swift`

#### Ledger for runtimes outside GGUF eviction: CoreML/MLX and ONNX helpers, lifetimes unchanged
`ModelRuntimeRegistry`: Admission and residency ledger for runtimes that do not belong to the GGUF
eviction ledger. It covers retained in-process CoreML/MLX models and
short-lived ONNX helpers, without changing their established lifetimes.

#### Placeholder before load suspends so concurrent preparations see it; non-evictable until idle unload
`ModelRuntimeRegistry.reserve`: Account for a retained in-process model before its download/load
suspends. The placeholder makes concurrent preparations and the next
GGUF admission see it. Retained runtimes remain non-evictable until
their established idle-unload path, so admission cannot interrupt
active inference.

#### Cancel admission because this ledger already owns the reservation
`ModelRuntimeRegistry.reserve`: This ledger already owns the reservation; do not count it twice.

### `LokalBot/Engines/MuseUITestTransport.swift`

#### UI-test-only modes: scripted replies or live Meta with key from file
`MuseUITestTransport`: UI-test host only. `LOKALBOT_MUSE_UI_TEST` puts Live Radar and
Follow-through in a mode the hosted UI suite can film:
- `1`: Meta Model API requests get scripted replies instead of reaching
  api.meta.ai, so no key, network, or model is used. Replies follow the
  demo call in `Docs/meta-hackathon/demo-script.md` and still pass through
  `MuseChatClient` parsing and the radar's grounding checks: a
  contradiction appears only if local search put the earlier passage in
  the request.
- `live`: requests go to Meta with the key read from the file named by
  `LOKALBOT_UI_TEST_META_API_KEY_FILE`, so the key never appears in the
  test configuration or its result bundle.
In both modes approved Follow-through steps do not open Mail or Calendar.
Screen-answer requests (the ones carrying images) get the answer the
film's synthetic captures show, which still has to pass the quote check
against the crop Vision read in the host. Live answers look up the pricing
sheet and the panel question with the real tools in the host, and answer
with a quote that has to be in what those tools returned.

#### Live mode reads key from file; scripted mode uses an ignored placeholder
`MuseUITestTransport.apiKey`: The key for `live` mode, or a placeholder the scripted replies ignore.

#### Film keeps Meta wire format though the app runs Live Radar on Think
`MuseUITestTransport.radarCall`: Live Radar's passes and screen answers for the film. The app itself
runs them on the Think model; the film keeps Meta's wire format so its
scripted replies, and a live run with the film's key, work as before.

#### 1.2 s delay keeps in-flight states visible for filming
`MuseUITestTransport.reply`: Long enough for the in-flight states to be visible.

#### For contradictions: words an earlier passage must contain
`MuseUITestTransport.Rule.conflictsWith`: For contradictions: words an earlier passage must contain.

#### Only the question picks the image; meeting title would make every answer the launch date
`MuseUITestTransport.screenAnswer`: The captures are labelled "Image N: \<app> — \<window>"; the answer names
the one that shows it. Only the question decides: the same part of the
request starts with the meeting's title, and "Launch sync" would give
every question the launch date.

#### One lookup then a quoted answer; other questions get none
`MuseUITestTransport.liveAnswer`: One lookup, then an answer quoting what it returned. Other questions
get no answer.

### `LokalBot/Engines/OnnxTranscriptionEngine.swift`

#### sherpa-onnx subprocess for SenseVoice and GigaAM; VAD regions decoded in one batch, nothing left resident
`OnnxTranscriptionEngine`: Transcription via the bundled sherpa-onnx ONNX runtime, invoked as a
subprocess (the same engine family Handy uses; mirrors the `LlamaServer`
subprocess pattern). Covers languages WhisperKit/FluidAudio handle poorly:
**SenseVoice** (Chinese / Japanese / Korean / Cantonese) and **GigaAM**
(Russian). The `sherpa-onnx-offline` binary + its onnxruntime dylibs ship in
the app bundle; the chosen model is downloaded on first use.

The track is split into VAD speech regions and decoded in a single batch
call (one model load), so each region carries the real start/end time of its
span — the same timestamp-exact approach as `CohereEngine` — and no model is
left resident afterwards.

#### Tarball top-level directory equals model-zoo archive base name
`OnnxTranscriptionEngine.Model.folderName`: Tarball top-level directory == the model-zoo archive base name.

#### Pin publisher release-asset size and hash so a replaced asset cannot change the model
`OnnxTranscriptionEngine.Model.archiveBytes`: Publisher release-asset metadata, independently pinned here so a
replaced asset cannot silently change the installed model.

#### Pass --model-type so the binary skips its load-twice probe
`OnnxTranscriptionEngine.Model.modelType`: `--model-type` value, passed so the binary skips its load-twice probe.

#### VAD regions give per-utterance timing; whole track is the fallback region
`OnnxTranscriptionEngine.transcribe`: VAD speech regions give real per-utterance timing; fall back to the
whole track as a single region when VAD is unavailable.

#### Download gives no granular fraction, so surface status text
`OnnxTranscriptionEngine.prepare`: Settings "Download" action: install the runtime + fetch the model.
`URLSession.download` gives no granular fraction here, so we surface
status text (the model row shows it).

#### Keep install idempotent for waiters entering after the first caller finished
`OnnxTranscriptionEngine.installModel`: A waiter may enter after the first caller finished but before it
observed the result; keep this operation idempotent as well.

#### Live directory appears only after validation; old cache kept until replacement completes
`OnnxTranscriptionEngine.installModel`: The live directory appears only after extraction and validation.
An incomplete old cache is kept until its replacement is complete.

#### SenseVoice ships int8 model; NeMo-CTC ships either; prefer int8
`OnnxTranscriptionEngine.locateModel`: SenseVoice ships `model.int8.onnx`; NeMo-CTC tarballs ship `model.onnx`
and/or `model.int8.onnx`. Prefer int8.

#### Keep every exit in cleanup scope so a helper that never attaches cannot strand a row
`OnnxTranscriptionEngine.runBatch`: Cancellation can arrive while the MainActor reservation call
is suspended. Keep every subsequent exit inside this cleanup
scope so a helper that never attaches cannot strand a row.

#### Create exit signal before awaits that can move the task off the launching thread
`OnnxTranscriptionEngine.runBatch`: The awaits below can move this task off the launching thread,
where `waitUntilExit()` could wait forever.

#### sherpa-onnx-offline prints one JSON object per wav in input order on stdout
`OnnxTranscriptionEngine.parseTexts`: `sherpa-onnx-offline` prints one JSON object per wav, in input order, on
stdout: `{"lang": …, "text": "…", "timestamps": […], …}`.

#### WAV is 16 kHz mono 16-bit PCM, what sherpa-onnx expects
`OnnxTranscriptionEngine.writeWav`: MARK: - WAV writer (16 kHz mono 16-bit PCM, what sherpa-onnx expects)

#### In-memory WAV for engines that upload a span instead of a file
`OnnxTranscriptionEngine.wavData`: The same WAV in memory, for engines that upload a span instead of
handing a file to a local runtime.

#### Cancel with SIGTERM then SIGKILL so blocking read unblocks and memory is released
`ONNXProcessController`: Bridges structured Swift cancellation to the blocking sherpa subprocess.
Cancellation sends SIGTERM immediately and escalates to SIGKILL only if the
helper ignores it, guaranteeing that `readDataToEndOfFile` eventually
unblocks and model memory is released.

### `LokalBot/Engines/OpenRouterModelCatalog.swift`

#### Context window read only from approved origin, no key or content; last answer kept
`OpenRouterModelCatalog`: The context window OpenRouter publishes for the selected model. It is read
only from an OpenRouter origin the user approved for inference, and the
request carries the model id in its path and nothing else: no API key and
no meeting content. The last answer is kept so a failed lookup cannot
change a meeting's part plan and discard its partial notes.

#### Endpoint lists change, so look again once a day
`OpenRouterModelCatalog.refreshInterval`: Endpoint lists change; a running app looks again once a day.

#### Failed list read waits ten minutes so offline Mac adds no per-request timeout
`OpenRouterModelCatalog.reasoningRetryInterval`: A failed list read waits this long, so an offline Mac does not add a
timeout to every Think request.

#### Nil for unapproved origin or when OpenRouter never published a usable window
`OpenRouterModelCatalog.contextTokens`: Nil when the server is not an approved OpenRouter origin, or OpenRouter
has never published a usable window for this model.

#### Reasoning read detached from caller so a disappearing view cannot cancel it
`OpenRouterModelCatalog.reasoningSupport`: The selected model's reasoning levels from OpenRouter's model list
(`GET <base>/models`, read at most daily). Same rules as the context
window: an approved OpenRouter origin, no key, no content. Nil when
the origin does not qualify or the model is not listed.

Callers that arrive during a read wait for it, and the read runs apart
from its caller, so a Settings view that disappears cannot cancel it
into a failed attempt. Either miss would leave the menu on the generic
levels for ten minutes, without the model's own Max.

#### Reasoning object fields: supported efforts, mandatory means no Off, none means no reasoning
`OpenRouterModelCatalog.reasoningSupport`: A model's `reasoning` object: `supported_efforts`, whether reasoning is
`mandatory` (no Off), and its defaults. No object: the model does not
reason. Without listed efforts, reasoning can only be switched off.

#### Only plain author/slug ids are sent in the endpoints path
`OpenRouterModelCatalog.endpointsURL`: `<base>/models/<author>/<slug>/endpoints`. Ids that are not a plain
author/slug pair are never sent.

#### Use smallest endpoint window; one endpoint without a window makes it unknown
`OpenRouterModelCatalog.smallestWindow`: The smallest window any endpoint may route to, including endpoints
that cap the prompt below their context. One endpoint without a window
makes the answer unknown rather than optimistic.

### `LokalBot/Engines/ParallelRangeDownloader.swift`

#### Ranged parallel download writes each byte once, resumable, falls back to single GET
`ParallelRangeDownloader`: Downloads large static files through parallel HTTP byte ranges, falling
back to a single streamed GET when the server can't do ranges (or the file
is small enough that ranges don't pay off).

Hugging Face's CDN supports `Accept-Ranges: bytes` for the GGUF files in the
model catalog. A single `URLSessionDownloadTask` can sit well below the
user's available bandwidth on fast links, while a small number of ranged
requests usually keeps the pipe busier. Callers still validate the final
bytes before installing the model. Either way the caller gets one temp-file
URL back with progress reported throughout — there is exactly one download
path to reason about.

Each range streams straight into the partial file at its own offset, so
every model byte is written to disk once. Landing a range in a download
task's temp file and copying it into place wrote every byte twice: half of
the 137 GB a 0.10.8 build wrote on 2026-10-14 was that copy.

Ranged downloads are resumable: the partially assembled file and a small
manifest of completed parts live at a stable per-URL path, so a failed,
cancelled, or app-quit download picks up where it stopped instead of
re-fetching 17 GB from byte zero. Pass `stashDirectory` to keep that state
somewhere durable (the temp default can be reaped by macOS between runs).

#### Discard resume stash unless URL, size and part size match
`ParallelRangeDownloader.ResumeState`: Completed-part bookkeeping persisted next to the partial file. The
stored URL/size/partSize must match the current request exactly or the
stash is discarded — a changed upstream file must never be stitched
together from two different versions.

#### Stable per-URL stash name so retries find earlier partial
`ParallelRangeDownloader.stashName`: Stable per-URL name for resume state, so a retried download finds its
earlier partial file no matter how it was initiated.

#### Credit allocated stash bytes against disk-space precheck; partial is sparse
`ParallelRangeDownloader.stashedByteCount`: Disk bytes already held by the resume stash for `url` (0 when none).
The disk-space precheck credits these against the expected size: a
valid stash resumes and only the remainder is fetched, and an
invalidated one is deleted before parts move — freeing the same bytes
on the same volume — so either way the extra space a retry needs is
expected − stashed. Allocated size, not logical size: parts write at
their offsets, so the partial is sparse until the tail parts land.

#### Keep assembled file and manifest on failure so next attempt resumes
`ParallelRangeDownloader.downloadRanged`: On success the assembled file is handed to the caller and the
manifest deleted; on any failure (including cancellation) both stay
behind so the next attempt resumes instead of starting over.

#### Delete truncated stash on size mismatch so next attempt starts clean
`ParallelRangeDownloader.downloadRanged`: Corrupt stash (e.g. the partial file was truncated behind our
back) — throw it away so the next attempt starts clean.

#### Whole-file GET streams to disk via URLSession, not Swift byte loop
`ParallelRangeDownloader.downloadWhole`: Single download-task GET for servers without byte-range support (or
files below the acceleration threshold). URLSession streams directly
to disk instead of iterating every byte in Swift.

#### Use pwrite at absolute offsets so parts share one descriptor
`ParallelRangeDownloader.writeFully`: `pwrite` at an absolute offset: concurrent parts share one descriptor
and never move a shared file position.

#### Task callbacks serialized by session queue; lock covers hand-off to run
`ParallelRangeDownloader.RangeWriter`: Delegate for one ranged data task. It checks the response before any
byte lands, then writes each chunk at its final offset. URLSession
serializes a task's callbacks on the session's delegate queue; the
lock covers the hand-off to the task awaiting `run`.

#### Hold outcome when task completes before run is waiting
`RangeWriter.outcome`: Held when the task completes before `run` is waiting, e.g. one
cancelled before it was resumed.

#### Reject 200 reply to Range request to avoid corrupting partial file
`RangeWriter.urlSession(didReceive response)`: A server that ignores Range answers 200 with the whole file;
writing that at this part's offset would corrupt the partial.

#### Never cache parts in URLCache to avoid a second disk write
`RangeWriter.willCacheResponse`: Never copy a part into URLCache: that would be a second disk write.

### `LokalBot/Engines/PinnedSpeechModels.swift`

#### Prepare reviewed snapshot ourselves; cached and fresh bytes must match manifest
`PinnedModelSnapshot`: Prepare the reviewed snapshot ourselves before local dependency loaders
can open it. Both cached bytes and fresh downloads must match the manifest.

#### Reject unreviewed leftover safetensors shards the MLX loader would load
`PinnedModelSnapshot.validateDiscoveredFiles`: The MLX loader discovers safetensors by extension. Do not let an
unreviewed leftover shard silently join the pinned weights.

#### Reject leftover files inside compiled CoreML directories
`PinnedModelSnapshot.validateDiscoveredFiles`: CoreML consumes whole compiled directories, including any files not
named in the manifest. Reject leftovers inside those components.

#### Resolve relocated root, then refuse symlinks in model-owned children
`PinnedModelSnapshot.destination`: The storage root may itself be relocated by the user. Once resolved,
no model-owned child may redirect a read or write through a symlink.

#### Pinned digests come from Hugging Face metadata with immutable commit
Source: Hugging Face model metadata, including immutable commit and LFS/Git digests.

#### CoreML INT8 aligner fetches only compiled mlmodelc bundles, no package compile
`PinnedModelSnapshot.qwenAligner`: speech-swift's CoreML Qwen3 forced aligner (INT8-palettized encoder and
decoder, fp16 embedding table). It times the words of a whole-track
transcript for speaker attribution. Only the compiled `.mlmodelc`
bundles are fetched, so loading never compiles a package.

### `LokalBot/Engines/QwenASREngine.swift`

#### Qwen post-meeting engine VAD-splits tracks; each tier runs its own llama-server
`QwenASREngine`: Qwen3-ASR as a post-meeting engine: LokalBot keeps using its existing
file-based pipeline, VAD-splits each track into timestamped spans, then
transcribes those spans with Qwen. Both tiers run on the bundled llama.cpp
server (`QwenLlamaASR`), each on its own llama-server.

#### Transcribe whole tracks before attribution; speaker regions cost WER
`QwenASREngine.speakerAttribution`: Both tiers transcribe whole tracks before attribution. On the
benchmark, regions cost 0.6B 2.8 points of meeting WER and 9.0 of AMI
WER, which outweighs the aligner being larger than the compact model.

#### 1.7B merges to 30 s windows; 0.6B stays 15 s
`QwenASREngine.wordAttributionWindows`: Decode windows for the word-attribution path: VAD spans merged across
short pauses. 1.7B gains from long windows. Each window is one
forced-aligner segment, and the CoreML aligner takes at most 30 s, so
1.7B merges to 30 s rather than the 60 s it used with the MLX aligner;
on AMI the two were within noise. 0.6B decoded long windows 5–10×
slower for a small gain, so it stays at 15 s
(Benchmarks/transcribe/QwenSpanLength). llama.cpp decodes greedily with
no repetition block; `TranscriptSanitizer` removes runaway loops.

#### Always recheck files and server since memory pressure can evict llama-server
`QwenASREngine.prepare`: The llama-server can be evicted under memory pressure, so this
always checks the files and the server, as Granite does; both are
cheap once installed and running.

#### Decode merged windows; aligner retimes words; unaligned language falls to speaker regions
`QwenASREngine.transcribeForWordAttribution`: Decodes merged windows, because the forced aligner re-times every word
afterwards: segment granularity no longer depends on the decode window.
On auto-detect it reports the language the track settled on, so a
fallback to speaker regions decodes in it too. When that language is
one the aligner cannot time, the rest of the track is not decoded:
the speaker regions decode it instead.

#### Pin server model-memory row so it is not evicted mid-track
`QwenASREngine.transcribe`: The server's model-memory row must not be evicted mid-track.

#### Decoder takes nil language for auto-detect and drops prompt echoes
`QwenASREngine.SpanDecoder`: Decodes `spans` in `language` (nil: auto-detect) and drops prompt echoes.

#### Pinned language unalignable: caller attributes by speaker regions, track not decoded pinned
`AutoLanguageDecision.needsSpeakerRegions`: `pinned` is a language the forced aligner cannot time: the caller
attributes by speaker regions, decoded in it, so the track was
not decoded pinned here.

#### Vote on 12-span sample so most tracks decode once; benchmark figures
`QwenASREngine.languageSampleSize`: Spans decoded on auto for the first language vote. Per-window
auto-detection misfires on short or accented speech, so a track in one
language decodes better pinned to it; voting on a sample instead of the
whole track lets most tracks decode once rather than twice.

Benchmarks/transcribe/QwenLanguageSample: whole AMI meetings and the
owner's English and Serbian meetings voted 99–100% one language on
any sample of 4 to 16 spans. On code-switched FLEURS tracks the old
path left on auto, random samples (one span per group) pinned 4.3% of
the time with 8 spans and 2.9% with 12; 12 costs about 4% of the old
decode time more than 8 on long tracks.

#### Sample vote needs 90% share to pin; 80% and 85% pinned mixed tracks
`QwenASREngine.sampleShare`: The sample's vote must reach this share to pin the track without
hearing the rest. Below it, the track decodes as it did before
sampling: everything on auto, then the whole-track vote at
`pinnedLanguage`'s 80%. A sample estimates the share coarsely. At
80%, the sample of a track the whole-track vote left on auto (four
Serbian utterances to one English, 79.8%) pinned it. At 85%, random
12-span samples still pinned it 39% of the time; at 90%, 23%, and
tracks 73% or less in one language almost never. Tracks in one
language vote 99–100%, so the stricter share costs them nothing.

#### Sample longest span per equal group to hear opening, middle and end
`QwenASREngine.languageSample`: Indices of `spans` to decode first: the spans split into `count`
consecutive groups of (nearly) equal size, and the longest span of
each, so the vote hears the opening, the middle and the end, where a
late change of language would be. Every span when there are no more
than `count`, so short tracks and dictation decode as before.

#### Longest span in group wins; earliest wins ties
`QwenASREngine.languageSample`: The longest span says the most; the earliest one wins ties.

#### Sample on auto, pin whole track on strong vote, else vote whole track
`QwenASREngine.decodeOnAuto`: Decodes a track whose language is on auto-detect.

A sample of spans (`languageSample`) decodes on auto first. When one
language holds at least `sampleShare` of its text, the whole track
decodes once, pinned to it; the sampled spans decode again with the
rest, so every span is decoded the same way. Otherwise the rest
decodes on auto and the whole track votes as before: a mixed track
stays on per-window detection, and a track the sample misjudged is
still pinned, at the old cost of two passes.

With `wordAttribution`, a pinned language the forced aligner cannot
time (Croatian, for Serbian, Bosnian and Montenegrin speech) ends the
decode: the caller attributes by speaker regions, decoded in that
language, and a pass here would be thrown away.

#### Send window to /completion with speech-swift prompt; async URLSession cancels with task
`QwenASREngine.transcribeWindow`: One window through llama-server's `/completion` with speech-swift's
prompt. URLSession's async API cancels the request with the task.

#### Hub-style base/models/org/model layout is shared with aligner and old MLX weights
`QwenASREngine.hubStyleCacheDir`: The Hub-style layout `base/models/<org>/<model>` of speech-swift's
loaders: the forced aligner lives there, and so did the MLX weights both
Qwen tiers replaced. Pure path arithmetic (no I/O), so it is unit-testable.

#### Pad sub-160-sample windows with silence; mel front end yields no frames
`QwenASREngine.samplesForInference`: Qwen's mel front end drops the final STFT frame, so fewer than one
160-sample hop (10 ms at 16 kHz) produces zero encoder frames.
Speaker boundaries and VAD/split tails can be this short. Pad only the
model input with silence; retain all recorded samples and the original
span timestamps. Empty windows stay empty and are skipped by
SpanTranscription before inference.

#### Merged window keeps pause audio between spans, as benchmark windows did
`QwenASREngine.merged`: Joins consecutive speech spans separated by at most `maxGap` seconds
while the joined window stays within `maxLength`. The window keeps the
pause audio between its spans, as the benchmark's windows did.

#### Supported languages come from Qwen3-ASR model card
`QwenASREngine.supportedLanguages`: Qwen3-ASR's supported languages (model card), as ISO codes.

#### Pin at 80% vote; single window never pinned; Serbian-family pins to hr
`QwenASREngine.pinnedLanguage`: With the language on auto, the track's language when one supported
language holds at least `minimumShare` (80%) of its text. Mixed-language
tracks stay on per-window detection: a 50/50 English–German track votes
up to 66% German by text length (Benchmarks/transcribe/QwenSpanLength).

A single window is never pinned: its only vote is its own decode, so
decoding it again in that language cannot correct anything. Short
dictations are one window, and pinning them doubled their decode time.

Serbian, Croatian, Bosnian and Montenegrin vote together and pin to
Croatian, which is not on the model card. Left on auto, these tracks
slip window by window into Macedonian, Russian or Chinese, and lines
come out in Chinese, Japanese or Hindi script. Pinned to `hr`,
Benchmarks/transcribe/DualASR measured 0.1% non-Latin
letters, Croatian 24.8% WER against 26.8% on auto, and the Montenegrin
meeting 38.5% against 38.3%. `sr` read Serbian better (14.5% against
17.3%) but wrote half of everything in Cyrillic.

#### Drop near-silent spans that echo the vocabulary prompt
`QwenASREngine.withoutPromptEchoes`: A near-silent span decodes to the context itself ("Mila Novak, Orion
Launch, Acme."). Dropped here so dictation never types the list and
the language vote hears only speech; the track transcriber repeats
the check for engines that do not.

### `LokalBot/Engines/QwenLlamaASR.swift`

#### llama.cpp Q8_0 GGUFs vs MLX benchmark; use /completion not audio transcriptions endpoint
`QwenLlamaASR`: Qwen3-ASR on the bundled llama.cpp server, both tiers: 1.7B
(`LlamaServerRole.qwenASR`) and 0.6B (`LlamaServerRole.qwenASRCompact`).

Benchmarks/transcribe/QwenLlamaCpp measured ggml-org's Q8_0 GGUFs against
speech-swift's MLX builds on identical windows:
- 1.7B: AMI WER 17.76% vs 17.80%, Serbian with `sr` and a vocabulary list
  12.4% vs 13.4%, about 10–17% slower, a 2.3 GB server instead of up to
  8.5 GB of MLX allocations.
- 0.6B (against MLX 4-bit): AMI WER 19.47% vs 20.90%, cpWER −0.74, FLEURS
  3–4 points better and Serbian 11 points better, about 30% slower, a
  1.6 GB server instead of a 2.5 GB process.

llama-server's own `/v1/audio/transcriptions` is not used: it puts the
language in a user instruction, ignores the system turn and leaves the
`language X<asr_text>` prefix in the text. Each window goes to `/completion`
with speech-swift's prompt instead, token for token.

#### Delete replaced MLX weights once GGUFs are installed
`QwenLlamaASR.Weights.legacyMLXDirectory`: The MLX weights this tier replaced, deleted once the GGUFs are in.

#### Fetch GGUFs through shared download stack and install atomically
`QwenLlamaASR.Weights.prepareFiles`: Fetches both GGUFs through the shared download stack (mirrors, ranged
parts, SHA-256 verification) and installs them atomically.

#### Pinned sizes and hashes come from Hugging Face tree API LFS oids
`QwenLlamaASR.accuracy`: Source: Hugging Face tree API at these revisions (LFS oids).

#### Set media marker env; llama.cpp randomizes it per process otherwise
`QwenLlamaASR.mediaMarker`: llama.cpp randomizes its media marker per process unless this is set;
the prompt must contain the server's marker exactly once.

#### 4096 context covers 30 s window audio, 768 generated tokens and context
`QwenLlamaASR.contextTokens`: A 30 s merged window is about 390 audio tokens, plus at most 768
generated tokens and the vocabulary context.

#### Cap prompt cache at 256 MB; default 8 GiB grew server to 14 GB
`QwenLlamaASR.serverArguments`: The default 8 GiB host prompt cache grew the benchmark server to 14 GB.

#### Prompt mirrors speech-swift Qwen3ASRModel: system context, user audio, assistant language
`QwenLlamaASR.prompt`: speech-swift's Qwen3ASRModel prompt: system = context, user = audio
(mtmd wraps the marker in \<|audio_start|>/\<|audio_end|>), assistant =
optional "language X", then \<asr_text>.

#### Server baseURL ends in /v1 but /completion lives at root
`QwenLlamaASR.completionURL`: `LlamaServer.baseURL` ends in /v1; /completion lives at the root.

#### Greedy decoding with no penalties or n-gram block, like speech-swift
`QwenLlamaASR.makeRequest`: Greedy with no penalties, like speech-swift. llama.cpp has no
n-gram block; the app never enables speech-swift's either (merged
windows switch it off, and ≤15 s windows never reach it).

#### Keep text after last asr_text tag when model re-emits it
`QwenLlamaASR.transcript`: Keeps what follows \<asr_text> when the model emits it again after
detecting the language itself, as speech-swift does.

#### Send IEEE-float WAV so server hears exact samples
`QwenLlamaASR.floatWAV`: 16 kHz mono IEEE-float WAV, so the server hears the exact samples.

### `LokalBot/Engines/QwenWordAligner.swift`

#### CoreML aligner replaced MLX at quarter memory; fixed 30 s, 768-token shapes
`QwenWordAligner`: Word timings for Qwen3-ASR text from speech-swift's CoreML Qwen3 forced
aligner. It lets a diarized track be transcribed whole and attributed word
by word, instead of cutting the audio into speaker regions before ASR.

The CoreML export replaced the MLX 4-bit aligner after attributing as well
on identical text (AMI cpWER −0.10, −0.58…+0.36) at about a quarter of the
memory (0.9 GB against 3.5–4.1 GB peak footprint; Benchmarks/transcribe/
QwenSpanLength/results/2026-11-15). Its shapes are fixed: at most 30 s of
audio, and one 768-token pass that holds the prompt, 13 audio tokens a
second, and each word with two timestamp slots.

#### 30 s equals 3000 mel frames with one spare for rounding
`QwenWordAligner.maxSegmentSeconds`: The audio encoder's 3,000 mel frames. The extractor makes one frame per
full 160 samples, so 30 s fits with a frame to spare for rounding at
the segment's edges. Callers keep segments within `maxSegmentSeconds`.

#### Peak footprint 0.89 GB measured while aligning long tracks
`QwenWordAligner.estimatedBytes`: Peak physical footprint while aligning long meeting tracks: 0.89 GB
on the benchmark, mostly the mapped embedding table and the decoder.

#### Aligner trained languages only; others keep region attribution
`QwenWordAligner.supportedLanguages`: Languages Qwen3-ForcedAligner-0.6B is trained on (model card). Other
languages keep region attribution rather than unmeasured timings.

#### Directory override replaces Application Support location for hardware tests
`QwenWordAligner.init`: `directory` overrides the Application Support location (hardware tests).

#### Vote language per segment so misdetected opening cannot decide it
`QwenWordAligner.detectedLanguage`: The aligner language for segment `texts` when the transcription
language was auto-detected, or nil when their dominant language is not
supported. Voted per segment, so a misdetected opening cannot decide it.

#### Prewarm downloads and verifies without loading weights into memory
`QwenWordAligner.downloadIfNeeded`: Download and verify the pinned files without loading them, so the
recording-time prewarm never holds the weights in memory.

#### Unit-test host shares release folders; never remove obsolete models there
`QwenWordAligner.downloadIfNeeded`: The unit-test host shares the release app's folders; never touch them there.

#### Old aligners deleted by exact path after current snapshot verified
`QwenWordAligner.obsoleteRepositories`: Aligners this app used before. Their folders are never read again and
are deleted, by exact path, once the current snapshot is verified.

#### Unaligned words ride on neighbours; over-long segments throw and keep one speaker
`QwenWordAligner.align`: Word timings for `text` within `samples` (16 kHz mono), relative to the
first sample. Words the aligner cannot tokenize ride on their neighbour.
Throws for a segment longer than 30 s or with more text than one pass
holds; the caller then keeps one speaker for the segment.

#### Autoreleasepool per pass; MLMultiArrays piled up 0.8 GB to 4.6 GB
`QwenWordAligner.align`: Each pass returns autoreleased MLMultiArrays (about 12 MB, mostly
logits). A track aligns in one task, so without a pool per pass
they piled up: 0.8 GB grew to 4.6 GB over 101 minutes of audio.

#### CoreML aligner keeps no scratch state; weights stay until idle unload
`QwenWordAligner.finishBatch`: Called once a track's segments are aligned. The CoreML aligner keeps
no scratch state between passes; the weights stay loaded for the next
track until the idle unload.

#### Compiled bundles need no compile; first load specializes for Neural Engine
`QwenWordAligner.performLoad`: The repository ships compiled bundles, so nothing compiles here.
The first load on a Mac still specializes them for the Neural
Engine (about 13 s); macOS caches that, and later loads take 0.6 s.

#### Aligner lives next to Qwen ASR models in same layout
`QwenWordAligner.directory`: Next to the Qwen ASR models, in the same Hub-style layout.

### `LokalBot/Engines/ReasoningLevels.swift`

#### Chosen level is default for unbudgeted tasks and ceiling for budgeted ones
`ThinkReasoningLevel`: The user's reasoning preference for Think and Agent Mode. Automatic keeps
each task's own budget and leaves an external server at its default. A
chosen level is the level for tasks that set no budget and a ceiling for
tasks that do, so a task tuned for no reasoning never starts reasoning.
Each model accepts only some levels; see `ReasoningSupport`.

#### reasoning_effort and OpenRouter effort spell Off as none
`ThinkReasoningLevel.init(effort:)`: `reasoning_effort` and OpenRouter `effort` spell Off as "none".

#### Thinking budget for llama-server; High is built-in model default
`ThinkReasoningLevel.budgetTokens`: llama-server's thinking budget. High is the built-in model's default.

#### Same budget steps map to OpenAI efforts on Automatic
`ThinkReasoningLevel.ceiling`: The most reasoning a task's own budget allows. The same steps map
budgets onto OpenAI efforts when the level is Automatic.

#### Levels sorted least first; empty means nothing LokalBot can set
`ReasoningSupport.levels`: Explicit levels, least reasoning first. Empty: nothing LokalBot can set.

#### Model's own level when request sets nothing, when known
`ReasoningSupport.defaultLevel`: What the model does when a request sets nothing, when that is known.

#### Common reasoning_effort values for servers publishing none; rejected level retries once
`ReasoningSupport.common`: `reasoning_effort`'s common values, for servers that publish nothing.
A level the model rejects gets one retry (see the engines).

#### Clamp to nearest supported level below, else lowest; nil for Automatic
`ReasoningSupport.clamp`: The supported level nearest below `level`, else the lowest one. Nil
for Automatic or a model without a control.

#### Automatic leaves default unless budget-zero task meets reasoning-by-default model
`ReasoningSupport.requestLevel`: The level one request carries: the chosen level, no higher than the
task's own budget allows, clamped to what the model accepts.

Automatic leaves the server at its default, except that a task tuned
for no reasoning is not handed to a model that reasons by default. On
2026-10-07 Cerebras Qwen, left at its default on Automatic, spent every
notes request's output on hidden reasoning and returned no notes.

#### Menu shows clamped value for stored choice model may reject
`ReasoningSupport.displayed`: The menu value for a stored choice the current model may not accept.

#### Static knowledge only; OpenRouter and Ollama publish more via resolve
`ReasoningSupport.known`: What LokalBot knows without asking the server. OpenRouter and Ollama
publish more; `resolve(for:)` reads it.

#### Read server reasoning info only from approved origins, no key or content
`ReasoningSupport.resolve`: Adds what the server publishes about the selected model: OpenRouter's
model list and Ollama's capabilities. Both are read only from origins
already allowed for inference and carry no key and no content.

#### llama-server thinking budget works for any model with thinking turn
`ReasoningSupport.builtIn`: llama-server's thinking budget works for any model with a thinking turn.

#### Ministral 3B instruct has no reasoning control
`ReasoningSupport.builtIn`: instruct only

#### LFM2.5 always reasons so Off is unavailable
`ReasoningSupport.builtIn`: always reasons

#### Only OpenAI reasoning models by generation take effort
`ReasoningSupport.openAI`: OpenAI's reasoning models, by generation. Others take no effort.

#### GPT-6 adds Max; only Sol and Luna accept none; Astra has no documented default
`ReasoningSupport.openAI`: GPT-6 adds Max and defaults to Medium. Sol and Luna also take
`none`; 6.1 Sol and Astra reject it, so newer models get no Off.
Astra documents no default (OpenAI's model pages, 26 October 2026).

#### Cerebras documented reasoning_effort values per model
`ReasoningSupport.cerebras`: Cerebras's documented `reasoning_effort` values per model.

#### Kimi accepts reasoning_effort but ignores it
`ReasoningSupport.cerebras`: accepted but ignored

#### Model families whose levels hold on any server
`ReasoningSupport.family`: Model families whose levels hold on any server.

#### Resolved answer valid only while same model and server selected
`ResolvedReasoningSupport`: A view's last `ReasoningSupport.resolve` answer, valid only while the
same model and server are selected.

### `LokalBot/Engines/RemoteInferenceGate.swift`

#### Admission policy: concurrency caps, background cap, priorities, cooldown after rate limit
`RemoteRequestQueue`: Pure bookkeeping for one remote origin's request slots. The gate actor owns
one per origin; keeping the arithmetic here (no clocks, no tasks) makes the
admission policy unit-testable the same way `LeaseBook` is.

Policy:
- processing work (meeting notes, digests, Dream, briefs) runs at most
  `maximumConcurrent` requests at once;
- background work may hold at most `maximumBackground` of them, so meeting
  notes always find a slot that scheduled digests or Dream cannot take;
- someone waiting on the answer (chat, dictation, an agent) is never queued
  behind processing work;
- waiters are admitted in priority order, first come first served within a
  priority, and a blocked background waiter never holds back a waiter that
  could start;
- after a rate limit nothing starts until the origin's cooldown has passed.

#### Admitted waiters move from waiters to inFlight in resume order
`RemoteRequestQueue.admit`: Waiters that may start now, in the order they should be resumed. They
are moved from `waiters` to `inFlight`.

#### Rate limit starts cooldown from Retry-After or exponential growth
`RemoteRequestQueue.finish`: Frees a slot. A rate-limited answer starts (or extends) the origin's
cooldown: the server's `Retry-After` when given, otherwise an
exponential pause that grows with consecutive rate limits.

#### One gate per external origin; built-in runtime scheduled by InferenceBroker
`RemoteInferenceGate`: One shared admission gate for every external Think server (OpenAI-compatible
and Ollama), keyed by origin. The managed built-in runtime is scheduled by
`InferenceBroker` instead and never passes through here.

#### Never park a task cancelled before the closure ran
`RemoteInferenceGate.acquire`: A cancellation that fired before this closure ran found no
waiter to remove; never park a cancelled task.

#### Attempt counts per priority; cooldown paces rate limits, notes wait longer
`RemoteRetryPolicy`: How patiently each kind of caller retries a transient remote failure. The
gate's shared cooldown already paces rate limits, so these counts bound the
total attempts rather than the wait. Meeting notes are worth waiting for;
a person watching chat would rather see the error quickly.

#### Backoff for non-rate-limit failures; rate limits wait on gate cooldown
`RemoteRetryPolicy.backoff`: Pause before a replay that did not fail with a rate limit (5xx, dropped
connection). Rate limits wait on the gate's cooldown instead.

#### Gate slots stop starvation; engine retries so callers must not replay
`GatedTextEngine`: A `TextEngine` decorator for external Think servers. Every request waits for
a slot on the origin's shared gate, so background digests and Dream cannot
starve meeting notes, and a rate limit pauses every caller of that origin
instead of each one hammering it again a second later. Replayable requests
are retried here, so callers must not add their own replay on top
(`handlesTransientRetries`).

#### Streaming never replays since replay could repeat shown text
`GatedTextEngine.generateStreaming`: Streaming stays single-shot: a replay could repeat text already shown.

#### Rate limit waits on origin cooldown inside acquire, no extra sleep
`GatedTextEngine.retry loop`: A rate limit waits on the origin's cooldown inside acquire().

### `LokalBot/Engines/RemoteTranscriptionEngine.swift`

#### Audio leaves Mac only for approved origins; loopback free; HTTP only on private networks
`RemoteTranscriptionConfiguration`: A speech-to-text server the user configures, speaking OpenAI's
`/audio/transcriptions` API: a cloud provider (OpenAI, Groq, OpenRouter)
or a whisper.cpp-style server on another device. Audio leaves the Mac only
for an origin approved for transcription; loopback needs no approval, and
plain HTTP is accepted only on the user's own network or tailnet.

#### Transcription approvals are separate from Think approvals
`RemoteTranscriptionConfiguration.approvedOrigins`: `AppSettings.approvedRemoteTranscriptionOrigins`. Separate from the
Think approvals: approving a Think server never sends it audio.

#### Append audio/transcriptions to base; keep full endpoint or whisper.cpp inference URL
`RemoteTranscriptionConfiguration.endpoint`: The request URL. A base such as `https://api.openai.com/v1` gets
`/audio/transcriptions` appended; a URL that already names that
endpoint, or whisper.cpp's default `/inference`, is used as is.

#### Verified word-timing models per origin; others stay plain json
`RemoteTranscriptionConfiguration.wordTimingModels`: Models checked to return word times for `response_format=verbose_json`
with `timestamp_granularities[]=word`, by origin. Other servers keep
plain `json`: several reject those fields (OpenAI's gpt-4o-transcribe
models accept only `json` and `text`). On OpenRouter, 2026-10-19, these
placed every speaker turn within 0.25 s of its onset in 30 s windows,
whichever provider served them. whisper-large-v3 is left out: one of its
providers stretched a word across the pause before the next speaker.

#### Server times words so no local forced aligner needed
`RemoteTranscriptionConfiguration.requestsWordTimings`: The server times words itself, so speaker attribution needs no local
forced aligner.

#### Key remembers word-timing rejection per server and model
`RemoteTranscriptionConfiguration.wordTimingKey`: Remembers a rejection of the word-timing fields per server and model.

#### Ready means configured and approved; gates treat it as on disk
`RemoteTranscriptionConfiguration.isReady`: Configured and allowed to receive audio. Readiness gates (automatic
processing, the Models page) treat this as the model being "on disk".

#### Disclosure shows where audio goes; loopback reads as this Mac
`RemoteTranscriptionConfiguration.presentation`: Where audio goes, for disclosures. Loopback reads as this Mac.

#### Engine label stored in transcript and checkpoint, never credentials
`RemoteTranscriptionConfiguration.transcriptEngine`: Recorded in `transcript.json` and the crash-resume checkpoint. Never
includes credentials.

#### Each upload rechecks live consent instead of trusting engine settings snapshot
`RemoteTranscriptionConsent`: What the person allows the transcription server right now. An engine is
built from a settings snapshot, and one meeting keeps it for hundreds of
uploads, so each upload asks here instead of trusting that snapshot.
`SettingsStore` is the one place it enters the process, as with
`ModelDownloadRouting.source`.

#### Nil until SettingsStore exists; engine snapshot then stands
`RemoteTranscriptionConsent.current`: Nil until a `SettingsStore` exists; the engine's own snapshot, checked
when its transcription starts, then stands.

#### Loopback servers need no approval and are never interrupted
`RemoteTranscriptionConsent.check`: Throws when audio may no longer go to `endpoint`. A server on this Mac
needs no approval and receives nothing that leaves the Mac, so it is
never interrupted.

#### Withdrawn server keeps unsent audio on this Mac
`RemoteTranscriptionError.isConsentWithdrawn`: The person withdrew the server while it was in use; the audio not yet
sent stays on this Mac.

#### Pack speech into 1 MB windows; attribute speakers by words, not per-turn requests
`RemoteTranscriptionEngine`: Transcribes through a `RemoteTranscriptionConfiguration`. Neighbouring
speech is packed into windows (`lineWindows`, or `attributionWindows`
before word attribution), and each window is uploaded as a 16 kHz WAV of at
most about 1 MB, so long meetings stay far below provider upload limits
(25 MB) and per-request timeouts (60 s upstream at OpenRouter). Speaker
turns are attributed after transcription word by word, as for Qwen3-ASR:
cutting the audio at every turn sent each turn as its own request, one
after another, without the context around it. Servers in
`wordTimingModels` return the word times; for the rest, the local forced
aligner finds them.

#### Plain transcription uses 15 s windows for speaker-bleed filter comparison
`RemoteTranscriptionEngine.lineWindows`: Plain transcription (no speaker turns, or the speaker-region fallback):
one request and one transcript line per window, short enough for the
speaker-bleed filter to compare (`SpeakerBleedFilter`).

#### Longer windows before word attribution give context, fewer requests
`RemoteTranscriptionEngine.attributionWindows`: Before word attribution: longer windows give the model more context
and need fewer requests; word times split them at turns and pauses.

#### OpenAI rejects audio under 0.1 s; slivers hold no words
`RemoteTranscriptionEngine.minimumSpanSamples`: OpenAI rejects audio shorter than 0.1 s, and such slivers hold no words.

#### Idle timeout allows slow CPU server over a minute per 30 s span
`RemoteTranscriptionEngine.requestTimeout`: Idle time without a response byte. A slow CPU server can spend well
over a minute on one 30-second span before it answers.

#### Read key once per transcription off main actor because Keychain
`RemoteTranscriptionEngine.apiKey`: Read once per transcription, off the main actor (Keychain).

#### Check consent before every upload including retries
`RemoteTranscriptionEngine.stillAllowed`: Asked before every upload, retries included: revoking the server or
choosing an on-device model stops the audio that has not been sent
yet. `AppSettings.transcriptionEngine` wires it to the live settings.

#### Nothing to download; model check sends spoken sample to prove server answers
`RemoteTranscriptionEngine.prepare`: Nothing to download: ready means configured and approved. The model
check sends the spoken sample to prove the server answers.

#### Bounded concurrent uploads; word times shifted onto track timeline
`RemoteTranscriptionEngine.segments`: Reads one span at a time, keeps at most `maximumConcurrent` uploads in
flight, and stamps each returned text with its span's real start/end.
Word times, relative to the uploaded clip, move onto the track timeline.

#### HTTP 400 retries plain json and remembers rejection until quit
`RemoteTranscriptionEngine.upload`: One span, retried on rate limits, server errors, and dropped
connections. A server that answers the word-timing fields with HTTP
400 is asked again with plain `json`; when that succeeds, its origin
and model stop asking for word times until the app quits. Internal so
tests can drive it with a stub session.

#### Remember rejection only after plain json succeeds
`RemoteTranscriptionEngine.upload`: Remembered only once plain json works, so a clip the
server refuses for another reason changes nothing.

#### json is universal format; verbose_json only for word timings; omit empty model
`RemoteTranscriptionEngine.makeRequest`: Multipart form in OpenAI's shape. `response_format=json` is the one
every provider and whisper.cpp accept; `wordTimings` asks for
`verbose_json` with word timestamps instead. `model` is omitted when
empty because single-model servers need none.

#### Words relative to uploaded clip start; nil when no usable times
`RemoteTranscriptionEngine.WindowTranscription`: One window's reply. `words` are relative to the start of the uploaded
clip; nil when the server returned no usable word times.

#### Accept OpenAI JSON or plain text; any invalid word time drops all for aligner
`RemoteTranscriptionEngine.transcription`: `{"text": …}` from OpenAI-style servers, plus `verbose_json`'s
`words: [{word, start, end}]`; a few self-hosted servers answer plain
text instead. Tokens without letters or digits are dropped; one word
without valid times drops them all, and the forced aligner times that
window instead.

#### Extract server error message in known shapes, bounded for display
`RemoteTranscriptionEngine.errorDetail`: The server's own message (`{"error": {"message": …}}`,
`{"error": "…"}`, or a short plain body), bounded for display.

#### Rejections kept in memory only so upgraded servers are retried after launch
`WordTimingRejections`: Servers and models that refused the word-timing fields during this run,
shared by every engine built from settings. Kept in memory only: a server
that adds support is asked again after the next launch.

### `LokalBot/Engines/ServerContextWindowCatalog.swift`

#### Window field names vary by server; read only from allowed servers; keep last answer
`ServerContextWindowCatalog`: The context window an OpenAI-compatible server reports for the selected
model. Model lists carry it as `max_model_len` (vLLM), `context_window`
(Groq), `context_length` (Together, DeepInfra, Fireworks), or
`max_context_length` (Mistral). Servers on this Mac report the window they
run with outside that list: llama-server's `/props` and LM Studio's
`/api/v0/models/<id>`. Anthropic's API reports `max_input_tokens` for one
model at `/v1/models/<id>`. OpenAI and Cerebras report none, so their
documented windows apply; OpenRouter has its own lookup
(`OpenRouterModelCatalog`).

It is read only from a server allowed for inference, with the API key the
inference requests already carry and no content. The last answer is kept
so a failed lookup cannot re-plan a meeting and discard its partial notes.

#### Recheck window daily since server may restart with another
`ServerContextWindowCatalog.refreshInterval`: A server can be restarted with another window; look again once a day.

#### Retry unanswering server after 10 minutes to avoid timeout per meeting
`ServerContextWindowCatalog.retryInterval`: A server that did not answer is asked again after this long, so one
that is offline does not add a timeout to every meeting.

#### Smallest window among model-list fields wins
`ServerContextWindowCatalog.modelListFields`: Model-list fields that name a window, in any order; the smallest wins.

#### Nil for disallowed, OpenRouter or unknown; apiKey read only when sending
`ServerContextWindowCatalog.contextTokens`: Nil when the server is not allowed for inference, is OpenRouter, or
has never reported a usable window for this model. `apiKey` is read
only when a request is actually sent.

#### llama-server and LM Studio publish running window outside model list
`ServerContextWindowCatalog.lookUp`: llama-server lists only the trained window and LM Studio none at
all; both publish the window they run with elsewhere.

#### Take smallest window per model from data object or bare array
`ServerContextWindowCatalog.windows(inModelList:)`: Each listed model's smallest window, from `{"data": [...]}` or a bare
array.

#### Use llama-server per-slot window
`ServerContextWindowCatalog.window(inLlamaServerProps:)`: llama-server's per-slot window.

#### Unloaded LM Studio model has no window yet
`ServerContextWindowCatalog.window(inLMStudioModel:)`: The window LM Studio loaded the model with. An unloaded model has none
yet: LM Studio picks one when it loads.

#### Model ids with unexpected characters are never sent
`ServerContextWindowCatalog.anthropicModelURL`: `<origin>/v1/models/<id>`. Ids with other characters are never sent.

#### Model ids with unexpected characters are never sent
`ServerContextWindowCatalog.lmStudioModelURL`: `<root>/api/v0/models/<publisher>/<model>`. Ids with other characters
are never sent.

### `LokalBot/Engines/SherpaOnnxRuntime.swift`

#### Copy bundled binaries to Application Support for writable stable subprocess paths
`SherpaOnnxRuntime`: Shared sherpa-onnx runtime installer. The app bundles the native binaries
as resources, then copies them to Application Support before execution so
subprocess paths are writable/stable across signed app updates.

#### Content-addressed install; validate every file on reuse
`NativeRuntimeInstaller`: A content-addressed installation keeps a running helper's dylibs stable
across app updates. Validate every file on reuse; size and a success marker
alone cannot detect same-size updates, corruption, or a missing dependency.

#### Failed copy never removes valid install; keep versions other instances run
`NativeRuntimeInstaller.install`: A failed copy never removes a valid installation. Prior content
versions stay while another app instance may still execute from one.

#### Shared flock claims dropped by kernel on exit keep version in use
`NativeRuntimeInstaller.claims`: Shared locks this process holds on the versions it installed or
reused. The kernel drops them when the process exits, crashes
included, so a version stays claimed as long as an app may run from it.

#### Claim version under install lock so no removal races
`NativeRuntimeInstaller.adopt`: Called with the install lock held, so no other install or removal
can run between claiming the version and returning it.

#### Remove stale ~50 MB versions each update (#406), best effort
`NativeRuntimeInstaller.removeUnusedVersions`: Each signed build re-signs the bundled binaries with a fresh timestamp,
so every update used to leave its previous version (about 50 MB) behind
for good (#406). A version stays while any LokalBot holds its claim or
any process executes from it. Everything else in `root` goes, including
the flat layout older releases installed and interrupted installs.
Best effort: a failure here never fails the install.

#### Claim files deleted only with version under exclusive lock
`NativeRuntimeInstaller.removeUnusedVersions`: A claim's lock lives on its file, so one is only ever deleted with its
version, under the exclusive lock taken above.

#### Nil on unreadable process list; must not mean nothing running
`NativeRuntimeInstaller.runningExecutablePaths`: Executable paths of every process this user can inspect; nil when the
list cannot be read, which must not pass for "nothing is running".

#### Validate paths and entry types; reject links and special files
`ArchiveExtractor.extractBzip2Tar`: Validate paths and entry types before extraction. Model archives must
contain ordinary files/directories, never links or special files.

### `LokalBot/Engines/SpanAudioReader.swift`

#### Decode per-span windows on demand to keep one span resident
`SpanAudioReader`: Decodes 16 kHz mono Float32 windows of an audio file on demand — one span
at a time. Transcription used to decode a whole track up front (~230 MB of
samples per recorded hour per track) and then copy every speech span out of
it; reading each span's window straight from the file keeps at most one
span (seconds of audio, a few MB) resident while the ASR model works.

Not Sendable (wraps an `AVAudioFile`): create one inside the actor-isolated
transcribe call and iterate spans in order — reads seek forward only.

#### Duration from container header without decoding
`SpanAudioReader.duration`: Track length in seconds, from the container header — no decode.

#### Window clamped to file; empty or out-of-range returns empty
`SpanAudioReader.samples`: Decodes the `[start, end)` window (seconds on the track timeline) to
16 kHz mono samples, clamped to the file's bounds. An empty or fully
out-of-range window returns `[]`.

#### Fresh converter per window avoids resampler state across non-adjacent windows
`SpanAudioReader.convert`: One-shot rate/channel conversion of a single already-read window. A
fresh converter per window is deliberate: its cost is trivial next to
the decode + ASR work, and it avoids carrying resampler state across
non-adjacent windows (spans skip the silence between them).

#### No converter priming; it would swallow milliseconds at span boundaries
`SpanAudioReader.convert`: No priming: each window is converted in isolation, and priming would
swallow the first ~milliseconds of every span boundary.

#### Drain converter but keep only source duration; filter tail adds samples
`SpanAudioReader.convert`: Draining AVAudioConverter can emit filter-tail samples beyond the
source window (e.g. 480,011 samples for a 30 s, 48 kHz window).
Those samples must not lengthen a speaker region or become a tiny
extra ASR span. Keep draining, but retain only the source duration.

### `LokalBot/Engines/SpeechActivitySpans.swift`

#### Spans carry timings only; samples decoded on demand to avoid resident track
`SpeechSpan`: A timestamped run of speech on the track timeline, produced by VAD
splitting — timings only. Engines decode each span's samples on demand
with `SpanAudioReader`, so a whole decoded track (~230 MB per recorded
hour) is never resident during transcription.

#### Fallback windows marked coarse so not mistaken for utterances
`SpeechSpan.timingPrecision`: Fallback windows are deliberately marked coarse so downstream code
cannot mistake a whole-track/fixed-window timestamp for an utterance.

#### Shared VAD span pipeline so engines cannot drift on clamping and fallback
`SpeechActivity.spans`: Shared VAD-split → timestamped-span pipeline for the engines that
transcribe per speech region (Granite, Qwen, sherpa-onnx, Cohere). One
implementation so the clamping, ≤N-second splitting, and whole-track
fallback semantics cannot drift between engines.

#### Whole-track fallback when VAD unavailable; silence stays empty; throws if unopenable
`SpeechActivity.spans`: Speech spans for `url`, each capped at `maxSegmentSeconds` when given
(nil keeps whole VAD regions). Falls back to the whole track (split the
same way) when VAD is unavailable. Successful silence stays empty, so
engines never decode it as speech. Throws only when
the audio itself cannot be opened.

#### VAD-only spans nil when unavailable, for Cohere whole-track fallback
`SpeechActivity.vadSpans`: VAD-only spans, or nil when VAD is unavailable —
for engines that need a distinct whole-track fallback (Cohere).

#### One shared per-span loop so empty-window and empty-text rules cannot drift
`SpanTranscription`: The per-span transcription loop the span-based engines (Qwen, Granite,
Cohere, sherpa-onnx) each used to carry a private copy of: decode one
span's window at a time (`SpanAudioReader`), hand the samples to the
engine, and keep non-empty normalized text stamped with the span's real
start/end. One implementation so the skip-empty-window and
drop-empty-text rules cannot drift between engines.

#### Gives span index to engine; empty-window spans skipped without calling it
`SpanTranscription.segments`: Sequential per-span decoding (Qwen, Granite, Cohere). `transcribe`
receives the span's 16 kHz mono samples plus the span's index (Granite
names its temp wavs by index); spans whose window decodes empty are
skipped without calling it.

#### Batch results may be fewer than inputs; extra spans dropped
`SpanTranscription.segments(pairing:)`: Batch pairing (sherpa-onnx decodes all wavs in one subprocess call):
stamp each returned text with its span. Extra spans without a text —
the binary can return fewer results than inputs — are dropped, like
empty texts.

### `LokalBot/Engines/TextEngine.swift`

#### Reserve output space for providers whose reasoning cannot be disabled
`TextEngine.minimumStructuredOutputTokens`: Output space required by a provider whose reasoning cannot be disabled.
Callers reserve it inside their existing job/context limits.

#### Callers must not add retries when the engine already retries
`TextEngine.handlesTransientRetries`: True when the engine already replays transient failures (rate limits,
dropped connections) itself. Callers must then not add a replay of
their own, or one failure would be retried twice over.

#### Cap on schema enum values; nil when server compiles to grammar
`TextEngine.structuredOutputEnumLimit`: The most enum values a structured-output schema may hold in total, or
nil when the server has no such limit (it compiles schemas to a local
grammar). Notes parts list their source IDs as enums and are sized to
fit.

#### Nil means provider has no supported tokenizer endpoint
`TextEngine.tokenCount`: Nil means this provider has no supported tokenizer endpoint.

#### Default ignores schema, so callers keep tolerant-parse fallback
`TextEngine.generate(schema:)`: JSON-schema-constrained generation. Backends with decode-time
constraints guarantee the reply parses against `schema` (llama-server
compiles it to a GBNF grammar; Ollama takes it as `format`). The
default ignores the schema, so callers must keep their tolerant-parse
fallback for backends that can't constrain (Apple Intelligence).

#### Default delegates to generate; OpenAI-compatible overrides with raw /v1/completions
`TextEngine.complete`: Low-latency raw text continuation for cotyping (inline autocomplete).
The default delegates to `generate` with an autocomplete instruction so
every backend works; `OpenAICompatibleEngine` overrides it to hit raw
`/v1/completions`, which is faster and behaves as a pure text continuer.

#### onPartial gets cumulative text; default is non-streaming, SSE override
`TextEngine.completeStreaming`: Streaming variant of `complete`: `onPartial` receives the cumulative
completion text as tokens arrive, so the UI can paint ghost text before
the full response finishes. Returns the final text. Default is
non-streaming; `OpenAICompatibleEngine` overrides it with SSE.

#### Nil reasoning budget inherits the engine's default
`TextGenerationOptions`: Per-request generation controls shared by the local chat backends. A nil
reasoning budget inherits the engine's default.

#### Autocomplete keeps text from a reply cut at maxTokens
`TextGenerationOptions.keepsTruncatedReply`: A reply cut off at `maxTokens` returns the text it has instead of
failing as truncated; one cut off before any visible text still fails.
OpenAI-compatible chat honors it, for autocomplete, which keeps only
a phrase anyway.

#### Explicit dialect so one provider's extensions never leak into another's request
`ChatCompletionDialect`: Request fields differ between bundled llama-server, generic compatible
servers, OpenAI, and OpenRouter. Keep the dialect explicit so one
provider's extensions can never leak into another provider's request.

#### OpenRouter reasoning dialects must never drop structured-output contract
`OpenRouterReasoningCompatibility`: OpenRouter request shape. Native uses `max_tokens`/`exclude` or
`effort: none` plus strict `json_schema`. Effort maps a numeric budget to
the supported low/high settings for always-reasoning models. Changing the
reasoning dialect must never remove the caller's structured-output contract.

#### Anthropic names its request ID header request-id
`TextEngineError.fromHTTPResponse`: Anthropic's API names the header `request-id`.

#### One bounded retry for transient failures only
`TextEngineRetryPolicy`: One bounded retry for transient transport/status failures. Permanent 4xx,
invalid payloads, cancellations, and missing configuration are never retried.

#### Validate strict-schema invariants locally to avoid billable 400s
`OpenAIStrictSchemaValidator`: OpenAI strict Structured Outputs accepts a JSON Schema subset. Validate the
invariants LokalBot relies on locally so malformed schemas never consume a
remote request merely to receive a deterministic 400 response.

#### Long meeting generation can take minutes, hence 600/900 s timeouts
`llmSession`: Generation can legitimately take minutes for a long meeting on a laptop.

#### Cotyping uses raw prompt, tight sampling, stops, low latency, not chat shape
`CompletionRequest`: One short continuation request for cotyping. Separate from `generate`'s
chat shape because inline autocomplete wants a raw prompt, tight sampling,
stop sequences, and a low latency budget.

#### Short 12/15 s completion timeouts; cancellation surfaces as URLError.cancelled
`completionSession`: Cotyping must feel instant, so completions use a short timeout rather than
`generate`'s minutes-long budget. Swift `Task` cancellation (the coordinator
supersedes stale keystrokes) surfaces here as `URLError.cancelled`.

#### Terminal event is [DONE] or non-null finish_reason
`cotypingParseSSEEvent`: Parses one Server-Sent-Events line from an OpenAI-style streaming
completion. A terminal event is either `[DONE]` or a choice carrying a
non-null `finish_reason`.

#### Default keeps schema; llama-server and Ollama override for sampling policy
`TextEngine.generate(schema:options:)`: Backends that cannot combine grammar constraints with request controls
still preserve the schema. Built-in llama-server and Ollama override
this path so digest extraction also gets its explicit sampling policy.

#### Chat-backend fallback for Ollama/Apple Intelligence; llama-server uses raw endpoint
`TextEngine.complete`: Chat-backend fallback: ask the model to continue the text and emit only
the continuation. Used by Ollama / Apple Intelligence; the built-in
llama-server (OpenAI-compatible) overrides this with the raw endpoint.

#### Nil uses built-in knowledge of model reasoning without asking
`OllamaEngine.reasoningSupport`: What the model accepts; nil uses what LokalBot knows without asking.

#### Sort keys with schema; dictionary order varies per launch
`OllamaEngine.chat`: Same per-launch key order problem as OpenAICompatibleEngine.

#### Length-truncated reply is a retryable error, same as OpenAI-compatible
`OllamaEngine.chat`: Same contract as the OpenAI-compatible path: a reply cut off by the
output limit is an error the caller can retry, not a finished answer.

#### Thinking tokens count against num_predict; zero budget disables thinking
`OllamaEngine.chatBody`: Ollama's thinking models think by default, and those tokens count
against `num_predict`. A zero budget turns the thinking turn off.
Of the chosen levels, only gpt-oss takes a graded one (see
`ReasoningSupport`); `think: true` fails on models that can't think.

#### Set num_ctx or Ollama's 4K default drops the prompt start
`OllamaEngine.chatBody`: Notes and digests are planned for this window. Without `num_ctx`,
Ollama uses its own default (4K on most Macs) and silently drops the
start of a longer prompt, which is where the instructions are.

#### Empty list when the Ollama server is down
`OllamaEngine.listModels`: Model names from `GET /api/tags`; empty array if the server is down.

#### Read reasoning levels from /api/show, sending only the model name
`OllamaEngine.reasoningSupport`: The model's levels from `POST /api/show` capabilities; nil if the
server does not answer. The request carries only the model name.

#### Whether raw completions carry llama.cpp top_k, min_p, repeat_penalty
`OpenAICompatibleEngine.sendsLlamaSamplingExtensions`: Whether raw completions carry llama.cpp's `top_k`/`min_p`/`repeat_penalty`.

#### Thinking ceiling nil for generic endpoints that may not understand it
`OpenAICompatibleEngine.defaultThinkingBudgetTokens`: llama-server's request-level thinking ceiling. Kept nil for generic
external endpoints that may not understand this extension.

#### Nil uses built-in knowledge of model reasoning without asking
`OpenAICompatibleEngine.reasoningSupport`: What the model accepts; nil uses what LokalBot knows without asking.

#### Hosted providers limit schema enums; Cerebras rejected 709 values, use 500
`OpenAICompatibleEngine.structuredOutputEnumLimit`: Cerebras rejected a 709-value notes schema on 2026-10-07 ("cannot
exceed 500"); OpenAI documents 1,000. OpenRouter and other hosted
servers route to providers with unknown limits and get the smaller
one. Servers on this Mac compile the schema to a grammar.

#### Structured output via response_format; llama-server compiles to GBNF
`OpenAICompatibleEngine.generate(schema:)`: OpenAI-standard structured output: llama-server compiles the schema to
a GBNF grammar and constrains decoding; LM Studio / vllm honour the
same `response_format` shape.

#### Nil leaves reasoning to task budget and server default
`OpenAICompatibleEngine.requestLevel`: The chosen level for one request (see `ReasoningSupport.requestLevel`),
or nil to leave reasoning to the task budget and the server's default.

#### GLM-5.3 has no disabled thinking; send effort dialect first request
`OpenAICompatibleEngine.reasoningCompatibility`: GLM-5.3 supports low/high/max, with no disabled-thinking mode.
Send its supported dialect on the first request of every part.

#### Stream only chat content; structured generation keeps accounting path
`OpenAICompatibleEngine.generateStreaming`: Stream chat content (never reasoning/tool deltas). Structured generation
keeps its existing accounting/repair path; interactive Ask has no budget.

#### Rejected stream generated nothing, so fall back to whole response
`OpenAICompatibleEngine.generateStreaming`: A rejected stream did not generate output. Preserve compatibility
with servers that only support whole chat responses.

#### Provider's error reason is in the response body
`OpenAICompatibleEngine.generateStreaming`: The provider's reason is in the body ("insufficient credits").

#### Consume single reply from servers ignoring stream=true; no duplicate paid call
`OpenAICompatibleEngine.generateStreaming`: Some servers ignore stream=true. Consume that single response;
never issue a duplicate paid generation for a successful reply.

#### Rejected request refunds output reservation but still counts the request
`OpenAICompatibleEngine.chat`: A routing/parameter rejection did not start generation.
Refund that output reservation, but still count the
physical request. Unknown transport usage stays reserved.

#### Sort body keys so grammar servers see stable property order
`OpenAICompatibleEngine.makeChatRequest`: Grammar-constrained servers generate schema properties in wire order.
Swift dictionaries hash in a per-launch order, so without sorting the
same request could ask for a verdict before its evidence on one launch
and after it on the next.

#### Unclosed think block in truncated reply is reasoning, not text
`OpenAICompatibleEngine.visibleText`: What a reader would see of a reply cut off at its limit: a thinking
block that never closed is reasoning, not text.

#### Per-dialect reasoning and token-limit handling; requestLevel replaces task budget
`OpenAICompatibleEngine.applyGenerationOptions`: llama-server counts hidden reasoning and visible content inside the same
completion limit. OpenAI exposes a qualitative reasoning effort;
OpenRouter normalizes a provider-independent reasoning object. Generic
compatible servers receive only common request fields, plus
`reasoning_effort` once the user chooses a reasoning level. A
`requestLevel` (already clamped to the model) replaces the task budget;
`reasoningFallback` is the retry after a server rejected it.

#### Zero thinking budget also needs enable_thinking false in chat template
`OpenAICompatibleEngine.applyGenerationOptions`: A zero budget alone still opens Qwen's thinking turn in the
bundled runtime and can exhaust short replies before any
visible text. Disable that turn in the chat template too.

#### Send reasoning_effort only for user-chosen level; rejected none retries at low
`OpenAICompatibleEngine.applyGenerationOptions`: Not every compatible server knows this field, so only a level
the user chose sends it. A rejected `none` retries at `low` for
models that always reason; any other rejected level retries at
the server's default.

#### OpenRouter publishes each model's efforts; chosen level is one
`OpenAICompatibleEngine.applyGenerationOptions`: OpenRouter publishes each model's efforts; the level is one.

#### Keep OpenRouter temperature only when reasoning is default or disabled
`OpenAICompatibleEngine.applyGenerationOptions`: Sampling controls vary across routed reasoning providers. Keep
temperature only for requests that leave reasoning at the model
default or explicitly disable it. Effort compatibility is
always-on thinking, so omit temperature there too.

#### OpenAI reasoning models reject custom temperature
`OpenAICompatibleEngine.applyGenerationOptions`: Current OpenAI reasoning models reject sampling knobs such as a
custom temperature. Non-reasoning chat models still accept it.

#### One low/high effort retry on reasoning mismatch, keep schema and privacy routing
`OpenAICompatibleEngine.shouldFallbackToReasoningEffort`: A reasoning-parameter mismatch allows one retry with low/high effort,
preserving the schema and privacy routing. A schema-only error is not
permission to weaken structured output. Some models report a routing
404; others return a 400 when `effort: none` is explicit.

#### Retry once when 400/422 names reasoning; rejection started no generation
`OpenAICompatibleEngine.shouldRetryRejectedReasoningLevel`: A reasoning level the user chose can be one the selected model does
not accept. Retry once (see `applyGenerationOptions`) when the server
names reasoning in a 400/422; that rejection did not start generation.

#### Hosted APIs get only OpenAI sampling fields; llama extensions are opt-in
`OpenAICompatibleEngine.completionBody`: Body for raw `/v1/completions`. `top_k`/`min_p`/`repeat_penalty` are
llama.cpp extensions a generic server ignores; hosted APIs that reject
unknown fields get only the OpenAI sampling fields, plus `extraBody`.

#### Typed text gets the same OpenRouter data policy as chat
`OpenAICompatibleEngine.completionBody`: The same provider data policy as chat: typed text is as private as Think's context.

#### Raw completions continue the prompt with no chat template
`OpenAICompatibleEngine.complete`: Raw `/v1/completions`: the model continues `request.prompt` directly with
no chat template, which is what cotyping wants.

#### Non-streaming fallback only when success has no SSE events
`OpenAICompatibleEngine.completeStreaming`: Streaming `/v1/completions` (SSE). Accumulates `choices[].text` deltas,
emitting the running text via `onPartial`. A non-streaming compatibility
fallback is allowed only when a successful response contains no SSE
events; transport and HTTP failures are surfaced without duplicating work.

#### 2xx non-SSE response means server lacks streaming; nothing was generated
`OpenAICompatibleEngine.completeStreaming`: A 2xx non-SSE response means this server does not implement the
streaming contract. No tokens were generated or shown yet.

#### Cancelled request surfaces as cancellation, not unreachable server
`sendInferenceRequest`: Task cancelled mid-request (e.g. the user pressed Stop): surface it as
cancellation, not an unreachable-server error, so callers can tell the
difference.

### `LokalBot/Engines/ThinkChat.swift`

#### Adapt chat messages and tools onto text-only Think engines via JSON turns
`ThinkChat`: Chat-shaped requests answered by the Think model chosen in Settings →
Models. Live Radar and Follow-through are written against chat messages:
a structured reply per radar pass, and one tool call per live-answer or
Follow-through turn. The Think engines take a
system prompt, a prompt and context, and return text. This turns one into
the other the way Ask's tool loop does: the tools are described in the
system prompt, each turn is asked for as one JSON object (held to a schema
where the backend can hold it), and earlier calls travel as context with
what they returned.

#### Engines don't report token use
`ThinkChat.structuredReply`: A reply held to `schema`. The system message is the system prompt and
the user message the prompt. Token use isn't reported by the engines.

#### Backends that can't hold a schema may wrap JSON in prose
`ThinkChat.structuredReply`: A backend that can't hold a schema may wrap the object in prose or a code fence.

#### Invalid tool call is asked once more, then returned as text
`ThinkChat.toolCall`: The next tool call of a loop. A reply that isn't a call to one of
`tools` is asked for once more; after that the text comes back with
no call, and the loop decides what that means.

#### Task and earlier calls become ordered context; later user message replaces ask
`ThinkChat.request`: What the engine is given. With tools, the task (the first user
message) and every earlier call with its result are context, in the
order they happened, and the prompt asks for the next call; a later
user message, such as a last-turn nudge, replaces that request.

#### Strict structured output needs closed objects and all properties required
`ThinkChat.strict`: Strict structured output wants every object closed and every property
required, so an optional property becomes one that may be null.

#### Tolerate prose wrapping, missing outer call key, and null arguments
`ThinkChat.toolCall(in:)`: The call in a reply, when it names one of the tools. Models without a
schema to hold them wrap the object in prose, or leave out the outer
`call`; arguments given as null are dropped.

### `LokalBot/Engines/ThinkExecution.swift`

#### Stop the ChatGPT plan relay when the session ends
`AgentLLMConnection.relay`: The session's ChatGPT plan relay; stop it when the session ends.

#### Single execution boundary for Think backend, models, privacy, leases, recovery
`ThinkExecution`: The complete execution boundary for LokalBot's Think role: backend
selection, local model preparation, endpoint privacy checks, runtime
leases, managed recovery, and Agent Mode endpoint resolution.

#### Query model reasoning support only when a level is chosen
`ThinkExecution.makeTextEngine`: Only a chosen level needs to know what the model accepts.

#### Anthropic URLs use native Messages API for schema, effort, caching
`ThinkExecution.makeTextEngine`: Claude's native Messages API: structured output within its
schema subset, effort, refusals, and prompt caching.

#### Share one gate per external origin so rate limits pause all callers
`ThinkExecution.makeTextEngine`: External servers share one gate per origin so scheduled work
cannot crowd out meeting notes or chat, and a rate limit pauses
every caller instead of each replaying a second later.

#### Plan credentials read per request or never; no special case needed
`ThinkExecution.makeTextEngine`: Plan credentials are read per request (OpenAI) or never read at
all (CLI-backed plans keep their own), so presentation-only
engines need no special case.

#### Shared download manager coalesces callers and validates pinned digests
`ThinkExecution.prepareBuiltInModel`: Ensure the selected built-in model is present before the first request.
The shared download manager coalesces callers and validates pinned model
digests before returning the local URL.

#### Never stack provider retry on built-in managed relaunch replay
`ThinkExecution.retryDelay`: A built-in request already gets one managed server relaunch and replay
inside `LeasedTextEngine`; never stack the provider retry on top of it.

#### Agent endpoints follow same approval and encrypted-transport policy as Think
`ThinkExecution.prepareAgentConnection`: Resolve and, for the built-in backend, lease the endpoint used for one
Agent Mode session. Remote endpoints pass through the same approval and
encrypted-transport policy as the rest of the Think role.

#### Missing ChatGPT sign-in opens Models instead of failing first turn
`ThinkExecution.prepareAgentConnection`: A missing sign-in opens Models now instead of failing the first turn.

#### Pure settings-to-endpoint resolution; runtime acquisition stays explicit
`ThinkExecution.agentResolution`: Pure settings-to-endpoint resolution shared by Agent Mode and the
external agent-access wake path. Runtime acquisition remains explicit.

#### pi reaches the plan through a token-holding relay; no credentials read
`ThinkExecution.agentResolution`: pi reaches the plan through a relay that holds the tokens, so
nothing here reads credentials.

#### CLI-backed plans offer no HTTP endpoint for Agent Mode
`ThinkExecution.agentResolution`: CLI-backed plans run their own agent binary and offer no HTTP
model endpoint for Agent Mode's runtime to call.

#### Presentation validates destination without reading Keychain each update
`ThinkExecution.agentResolution`: Presentation can validate the same destination without reading
Keychain on every view update. Launch resolution keeps credentials.

#### Anthropic is served under /v1 for chat completions whatever URL entered
`ThinkExecution.agentResolution`: Agent Mode's runtime speaks chat completions, which Anthropic
serves under /v1 whichever form of its URL was entered.

### `LokalBot/Engines/TranscriptLanguageVote.swift`

#### Vote language per segment; opening-text detection let one bad window decide
`TranscriptLanguageVote`: The dominant language of a transcript, voted over its segments by text
length. Apple's recognizer judges a long string mostly by its opening, so
classifying the joined transcript let one misdetected first window decide
a whole track (Benchmarks/transcribe/QwenSpanLength, language section).

#### Share of voting text in this language, range 0 to 1
`TranscriptLanguageVote.Result.share`: Share of the voting text in this language, 0...1.

#### Short or low-confidence segments don't vote; Qwen auto-detect misfires there
`TranscriptLanguageVote.dominant`: Segments shorter than `minimumWords` or recognized with less than
`minimumConfidence` do not vote: laughs and one-word replies are where
Qwen's own auto-detection misfires. `aliases` counts several base
codes as one language, keyed by the code they count as.

#### Serbian, Croatian, Bosnian, Montenegrin vote together as Croatian
`TranscriptLanguageVote.serbianCroatianAliases`: Serbian, Croatian, Bosnian and Montenegrin are one language to a
speech model. Apple's recognizer reads all of them in Latin script as
Croatian (Benchmarks/transcribe/DualASR) and Serbian Cyrillic as Kazakh, so
Cyrillic with Serbian's own letters votes Serbian instead. They vote
together, as Croatian.

### `LokalBot/Engines/TranscriptionEngine.swift`

#### Model list families, ONNX models for CJK and Russian, remote server option
`TranscriptionModelChoice`: User-facing transcription model list (Settings). CoreML/MLX families
(Parakeet, Qwen3-ASR, Whisper, Cohere) plus ONNX-runtime models for languages
those cover poorly — SenseVoice (CJK) and GigaAM (Russian) — via the bundled
sherpa-onnx engine. Fun-ASR-Nano uses a user-selected local ONNX folder.
A transcription server sends audio to a user-configured, approved
OpenAI-style endpoint instead (`RemoteTranscriptionEngine`).

#### Legacy choices stay decodable and deletable but hidden from new users
`TranscriptionModelChoice.isLegacy`: Superseded choices. They stay decodable (a persisted selection keeps
working) and deletable, but the Models UI hides them from new users —
every language Cohere covers is served better by Granite/Qwen/Whisper,
which add language detection, timestamps, and diarization support.

#### Remote server runs elsewhere; nothing is downloaded
`TranscriptionModelChoice.isRemote`: Runs on a server the user configures; nothing is downloaded.

#### Built into macOS, not downloaded to Application Support
`TranscriptionModelChoice.isBuiltInSystem`: Built into macOS rather than downloaded into Application Support.

#### Saved Granite Turbo selection migrates to Parakeet v2
`TranscriptionModelChoice.removedGraniteTurbo`: Granite Speech 5 TurboCTC (English only, MLX) was removed. A saved
selection of it moves to Parakeet v2, the other fast English-only model.

#### Keep decoding old display-string settings so updates don't reset model
`TranscriptionModelChoice.init(from:)`: Settings written before the raw values were stabilized persisted the
display strings. Keep decoding them so an update never silently resets
a user's model choice.

#### Remote server engine needs settings via AppSettings.transcriptionEngine(for:)
`TranscriptionModelChoice.engine`: Needs the server settings: `AppSettings.transcriptionEngine(for:)`.

#### prepare downloads and loads idempotently so any engine is driven uniformly
`TranscriptionEngine`: M2 contract (design doc §5). The app talks only to these protocols;
engines (Parakeet, WhisperKit, whisper.cpp, VibeVoice) plug in behind.
`prepare` downloads/loads the model (idempotent) so prewarm paths and the
Models UI can drive any engine through `TranscriptionModelChoice.engine`
without per-engine switches.

#### Stable model-file identity for crash-resume checkpoints
`TranscriptionEngine.checkpointIdentity`: Stable identity of the selected model files for crash-resume checkpoints.

#### Whole-track decode for word attribution; missing word times re-timed by aligner
`TranscriptionEngine.transcribeForWordAttribution`: Whole-track transcription whose words will be attributed to speakers
(`.alignedWords`), so decode windows may be longer. Segments without
the engine's own word times are re-timed by forced alignment.

#### Forced aligner fetched only for segments lacking engine word times
`TranscriptionEngine.providesWordTimings`: Word-attribution transcripts are expected to carry the engine's own
word times, so the forced aligner is fetched only for segments without them.

#### Engine-timed words fill words; the rest go to forced aligner
`WordTimedTranscript`: A whole-track transcript for word attribution. An engine that times words
itself (a transcription server answering `timestamp_granularities[]=word`)
fills `words`; the rest are left to the forced aligner.

#### Word times on track timeline; nil when engine gave none
`WordTimedTranscript.Segment.words`: On the track timeline; nil when the engine returned no word times.

#### Reuse auto-detected track language for speaker-region fallback decoding
`WordTimedTranscript.trackLanguage`: The language the engine settled on for the whole track while set to
auto-detect, if it did. When the words cannot be attributed and the
track falls back to speaker regions, those decode in this language:
a few seconds of speech are too little to detect it again.

#### Unalignable track language means attribute by speaker regions, ignore segments
`WordTimedTranscript.needsSpeakerRegions`: The engine settled on a `trackLanguage` the forced aligner cannot time
and stopped there: attribute by speaker regions decoded in it, without
`segments`, which may be incomplete.

#### Aligned words beat regions: regions cost 2.8 to 3.0 WER points
`SpeakerAttributionStrategy.alignedWords`: Transcribe the whole track, then assign each forced-aligned word to the
speaker active at that moment. Measured on Qwen3-ASR 1.7B and 0.6B in
Benchmarks/transcribe/QwenSpanLength: regions cost 3.0 and 2.8 points of meeting WER.

#### Unload idle models after quiet period to avoid pinning memory
`IdleTimer`: Releases an idle, expensive resource (a loaded transcription model) after a
quiet period — mirrors Handy's idle-unload so a long-running app doesn't pin
hundreds of MB to >1 GB of CoreML weights between meetings. Call `bump()`
after each use; `onIdle` runs only if nothing bumped during the interval.

#### Actor reentrancy at await requires coalescing concurrent setup calls
`AsyncSingleFlight`: Coalesces overlapping async setup calls. Swift actors are reentrant at
every `await`, so a simple `guard model == nil` does not prevent two callers
from downloading or loading the same model concurrently.

#### Cancellation racing success must not report Ready
`AsyncSingleFlight.run`: Cancellation racing successful completion must not report Ready.

#### Cancel shared download only when last waiter leaves
`AsyncSingleFlight.cancelWaiter`: Another consumer (for example a recording prewarm) still owns the
shared download. Cancel actual work only after its final owner leaves.

#### CoreML on Neural Engine; model download from Hugging Face is only network use
`ParakeetEngine`: Parakeet TDT 0.6B via FluidAudio — CoreML, in-process, runs on the
Neural Engine. Ultra and v3 cover 25 European languages;
v2 is English-only. The model is fetched
from Hugging Face on first use and cached; the only network access.

#### Pinned v3 snapshot uses corrected Encoder_v2 weights
`ParakeetEngine.Variant.encoderPrecision`: The pinned v3 snapshot uses the corrected Encoder_v2 weights.

#### One instance per variant avoids racing over shared state
`ParakeetEngine`: One instance per variant so the pipeline, dictation prewarm, and the
Models UI can each target a variant without racing over shared state.

#### Split segments on 1 s gaps, 200 chars, 30 s; punctuation tokens never split
`ParakeetEngine.segments`: Groups token timings into sentence-ish segments: split on silence
gaps > 1 s, on sentence-ending punctuation once a segment has grown
past ~200 chars, or after 30 s regardless. Token timing can place a
sentence's closing punctuation after the pause that follows it, so a
token with no letters or digits always stays with the words before it
and neither causes a split nor stretches the segment's end.

#### Whisper large-v3 turbo via WhisperKit: about 1.6 GB, 99 languages, timestamps
`WhisperEngine`: Whisper large-v3 turbo via WhisperKit (CoreML, ~1.6 GB, auto-downloaded
from Hugging Face on first use). 99 languages, real segment timestamps.

#### Reject WhisperKit's mutable nested Hub tokenizer cache fallback
`WhisperEngine.performPreparation`: WhisperKit searches a nested Hub cache before this folder and
can populate it on a tokenizer parse failure. Never accept that
mutable fallback as the configured pinned tokenizer.

#### Parse pinned tokenizer locally; convenience loader downloads mutable Hub files
`WhisperEngine.performPreparation`: Fail locally if the pinned tokenizer cannot be parsed. The
dependency's convenience loader otherwise downloads mutable
Hub files even when model downloads are disabled.

#### Cohere emits no timestamps; transcribe per VAD region for real timing
`CohereEngine`: Cohere Transcribe (03-2026) via FluidAudio — CoreML int8, 14 languages.
The model emits no timestamps, so each track is split into VAD speech regions
and transcribed per region, giving real per-utterance timing (with a
whole-track single-segment fallback when VAD is unavailable).

#### Stamp each VAD region transcript with its real start and end
`CohereEngine.transcribe`: Cohere returns no timestamps, so transcribe each VAD speech region
(≤14 s) on its own and stamp it with the region's real start/end —
real per-utterance timing without forced alignment. Falls back to one
whole-track segment if VAD is unavailable.

#### VAD model memory of one live track, passed through liveProbability
`LiveVoiceState`: The voice-activity model's memory of one live track, handed back and forth
through `SpeechActivity.liveProbability`.

#### VAD gate skips silent tracks to avoid ASR hallucination; errors report speech
`SpeechActivity`: Voice-activity gate over FluidAudio's Silero VAD. Lets the pipeline skip
transcribing a track with no speech (e.g. your mic while muted for the whole
call) rather than feeding silence to the ASR model, which can hallucinate
text. Conservative: any error/uncertainty reports speech so a real track is
never dropped. Idle-unloads the (small) VAD model like the ASR engines.

#### Cache segments only, keyed by path, mtime, size, to avoid double sweep
`SpeechActivity.cachedSegments`: Single-entry segments cache. The pipeline gates each track on
`speechSeconds` and the engine immediately re-requests the segments for
the same file — without this, every track is decoded and VAD-swept
twice. Deliberately segments-only: the decoded track (~230 MB per
recorded hour) is released the moment the VAD sweep finishes, and
transcription re-reads each span's window on demand (`SpanAudioReader`).
Keyed on path + mtime + size; released with the idle unload.

#### Split into regions up to 14 s with real times, or nil without VAD
`SpeechActivity.speechSegments`: Decode `url` to 16 kHz mono (transiently) and split it into ≤14 s
speech regions (Silero VAD, ASR-tuned `.default` config), or nil when
VAD is unavailable. Each region carries a real `startTime`/`endTime`,
which lets timestamp-less engines (Cohere) emit per-region segments
instead of one block per track.

#### Nil when VAD unavailable, so caller transcribes anyway
`SpeechActivity.speechSeconds`: Total seconds of detected speech in `url`, or nil when VAD is
unavailable — in which case the caller should transcribe anyway.

#### Live VAD throws when unavailable so previews stop rather than assume speech
`SpeechActivity.liveProbability`: How likely the next `liveChunkFrames` of a track being recorded are
speech. `state` is the model's memory of that track so far; pass back
the one returned. Unlike the file sweep above this throws when the
model is unavailable, so a live preview stops instead of treating
everything as speech.

#### Model judges 256 ms chunks of 16 kHz frames
`SpeechActivity.liveChunkFrames`: Frames (16 kHz) the model judges at a time: 256 ms.

### `LokalBot/Engines/TranscriptionModelStore.swift`

#### Retired model folders relative to Application Support, Granite Turbo about 0.95 GB
`TranscriptionModelStore.retiredModelFolders`: Folders of transcription models the app no longer offers, relative to
Application Support: Granite Speech 5 TurboCTC (about 0.95 GB, MLX).

#### Delete retired folders by exact path, never following symlinks
`TranscriptionModelStore.removeRetiredModels`: Deletes the retired models' folders by exact path. Never follows a
symlink in a folder's place. Returns the folders it removed.

#### Unit tests skip Documents; macOS prompts for fresh test host every time
`TranscriptionModelStore.Environment.live`: Unit tests never look in the user's Documents folder: macOS
asks a freshly built test host for access every time.

#### Transcription server counts as available once configured and approved
`TranscriptionModelStore.isDownloaded`: A transcription server has nothing on disk; it counts as available
once it is configured and approved (`RemoteTranscriptionConfiguration.isReady`).

#### User-selected folder is never an app-owned cache
`TranscriptionModelStore.cacheDirectories`: A user-selected folder is never an app-owned cache.

#### macOS manages SpeechAnalyzer system assets
`TranscriptionModelStore.cacheDirectories`: macOS manages SpeechAnalyzer's system assets.

#### UI checks install receipt only; preparation does full digest off MainActor
`TranscriptionModelStore.onnxModelExists`: UI reads the successful-install receipt and sizes; preparation does
the full digest pass off the MainActor before using any weights.

#### Skip legacy Documents cache at launch to avoid macOS access prompt
`TranscriptionModelStore.whisperModelDirectories`: Only the Application Support cache. Readiness checks run at launch, and
listing the legacy `~/Documents` cache there made macOS ask for
Documents access; preparing Whisper migrates that cache instead.

#### Best-effort migration out of Documents; MDM denial must not block download
`TranscriptionModelStore.migrateLegacyWhisperKitModels`: Move a valid cache created by older builds out of `~/Documents` before
WhisperKit checks the new Application Support download root. Migration
is deliberately best-effort at the call site: an MDM-denied legacy
folder must never prevent a clean download into the correct location.
A complete Application Support cache skips the legacy folder entirely,
so only the first preparation after an upgrade touches `~/Documents`.

#### Failed removal of old cache is harmless; don't undo migration
`TranscriptionModelStore.migrateLegacyWhisperKitModels`: The destination is now complete and recoverable. Removing the
old cache avoids cloud re-upload; a managed provider may deny
deletion, which is harmless and should not undo the migration.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
