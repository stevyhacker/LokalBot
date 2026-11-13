# Inference Broker (Step 1: Leases + Idle Unload) — Design

**Date:** 2026-07-11
**Status:** Draft — written for review; decisions carried over from the agent-access brainstorming transcript
**Branch:** `inference-broker` (cut from `agent-access` after the agent-access implementation lands, or from `master` once that branch merges)
**Scope decision:** Step 1 is the mechanical lease layer only: one actor owns when the three shared llama-servers start and stop, callers hold leases per request, leased models are pinned against eviction, and idle servers unload after a linger. Pressure-derived budgets, meeting-aware admission, deferral queues, and priority-ordered eviction are step 2+ (§11).

---

## 1. Why

From the brainstorming transcript:

> The broker is one actor that owns every model lifecycle. Engines stop owning processes and instead request leases: `actor InferenceBroker { func lease(_ model: ModelNeed, priority: Priority, purpose: String) async throws -> ModelLease }` — lease is refcounted; release triggers eviction eligibility.

and the sequencing decision: "Agent access first; broker second, own branch/spec. Step 1 is mechanical — the runtime refactor gets clean review on its own branch." The agent-access spec (§5) also promises: "This watcher becomes a P1 broker lease later."

Step 1 fixes three concrete holes in today's behavior:

1. **Mid-request eviction.** `ModelResidency` sets a resident's `lastUsed` only when `ensureRunning` succeeds. A long generation (an Agent Mode conversation, a chat answer, a map-reduce summary chunk) keeps no claim on its model, so an unrelated load — the embedder indexing a meeting, cotyping booting its model — can evict the Main LLM *while it is answering*, killing the request. Leases pin the model for the duration of every request.
2. **No idle unload.** Once a summary runs, the summarizer stays resident until something else needs the RAM. On a 16–24 GB machine that is multiple GB held hostage for hours. With leases, "no open lease + linger elapsed" is a well-defined idle signal, and the broker stops the server.
3. **The external consumer never releases.** `AgentAccessManager` (agent-access branch) starts the Main LLM on every `ask_library` wake and never stops it — an external MCP client can leave a 4 GB model resident forever. A TTL lease (renewed per wake by re-acquiring) returns the RAM ten minutes after the last question.

The transcript's `ModelNeed` resolves in step 1 as `(role, model URL)` — the model choice already lives at each call site (`ModelCatalog` resolution, embedder's fixed model), so the broker doesn't need a need-description type yet.

## 2. Decisions

| Question | Decision |
|---|---|
| Build a ledger? | No — `ModelResidency`/`ModelRuntimeRegistry` already landed with the resource monitor. Step 1 adds a **lease layer on top**: pins + descriptions flow into the existing ledger; `willLoad` stays the single admission point. |
| Eviction ordering | Unchanged LRU, plus "pinned ids are never victims". Priority-ordered eviction is step 2 — with linger unloads, most rows are gone before eviction matters (YAGNI). Priorities are still recorded and displayed. |
| How call sites adopt leases | A `LeasedTextEngine` decorator created inside `ProcessingPipeline.makeTextEngine` wraps every `TextEngine` call in `broker.withLease`. Covers summarize / outcomes / day digest / chat / headless `--chat` / cotyping-HTTP / ModelsView test with **no call-site surgery** beyond optional priority/purpose parameters. |
| Which backends are brokered | Only `.builtIn` (our llama-server). Apple Intelligence, Ollama, and user-pointed OpenAI-compatible servers are not our processes to manage. |
| Long-lived consumers | Agent Mode holds one session lease from `resolveEndpoint` to `shutdown`/failure. `ask_library` wakes hold a TTL lease (600 s), re-acquired (not renewed) per wake so a crashed server is revived by the acquire's `ensure`. |
| `renew` API | Cut. Re-acquiring a fresh lease and releasing the old one is strictly more robust (ensure runs every time) and removes an API with no other consumer. |
| Linger constants | mainLLM 600 s, embedder 600 s, cotyping 900 s (typing is bursty all day). Constants on `InferenceRole`, overridable in the broker init for tests. |
| Out of step 1 | Granite ASR's private server (17875, per-instance, short-lived by design) and the in-process cotyping runtime (`LlamaCotypingRuntime`, already touch/evict-integrated) stay outside the broker until step 2. |

## 3. Current state (what already exists)

- `LlamaServer` (actor, `LokalBot/Engines/LlamaServer.swift`): three static instances — `shared` :17872, `embedder` :17873, `cotyping` :17874 — with single-flight `ensureRunning(modelAt:)`, health probing, orphan adoption/reclaim, and `stop()`. On every successful ensure it registers with `ModelResidency` under id `"llama-server:<port>"` (which also refreshes `lastUsed`); `start` calls `ModelResidency.shared.willLoad` before spawning.
- `ModelResidency` (`@MainActor ObservableObject`): the GGUF ledger — budget = physical RAM / 2, `register`/`touch`/`unregister(ifGenerationMatches:)`, and `willLoad` which delegates victim choice to pure `ModelResidencyPolicy.evictions` (LRU) and runs unload hooks.
- `ModelRuntimeRegistry`: non-evictable CoreML/MLX/ONNX reservations, fed into `willLoad` as `reservedBytes`. Untouched by this design.
- Consumers call `ensureRunning` directly today: `makeTextEngine` (:495), `EmbeddingIndex.embed` (:182), `AgentSessionController.resolveEndpoint` (:276), `AgentAccessManager.startMainLLM` (:104, agent-access branch), `GraniteSpeechEngine` (own private server — out of scope).

What's missing is exactly the lease layer: nothing expresses "in use right now" (pins) or "not used for a while" (idle unload).

## 4. Architecture

Three new files plus surgical edits. Nothing new is a process or a listener; the broker is a coordination actor in front of the existing `LlamaServer` trio.

| Component | Location | Responsibility |
|---|---|---|
| `InferencePriority`, `InferenceRole`, `InferenceLease`, `LeaseBook` | `LokalBot/Engines/InferenceLease.swift` | Vocabulary + pure lease bookkeeping (acquire/release/counts/pins/dashboard strings). No clocks, no I/O — unit-tested like `ModelResidencyPolicy`. |
| `InferenceBroker` | `LokalBot/Engines/InferenceBroker.swift` | The actor. `lease`/`release`/`withLease`; runs injected `RuntimeHooks` (`ensure`/`stop` closures defaulting to the live `LlamaServer` trio); pushes pins + lease descriptions to `ModelResidency`; owns linger and TTL-expiry tasks. |
| `LeasedTextEngine` | `LokalBot/Engines/LeasedTextEngine.swift` | `TextEngine` decorator: every `generate`/`complete`/`completeStreaming` call runs inside `broker.withLease`. Construction is cheap and does not boot the server. |
| `ModelResidency` + `ModelResidencyPolicy` | modify `LokalBot/Engines/ModelResidency.swift` | Policy gains `pinned: Set<String>` (pinned never victims); ledger gains `@Published pinnedIDs` / `leaseDescriptions` + `setLeaseState`, consumed by `willLoad` and the dashboard. |
| `ProcessingPipeline.makeTextEngine` | modify `LokalBot/Services/Meetings/ProcessingPipeline.swift` | `.builtIn` case stops calling `ensureRunning`; returns `LeasedTextEngine(base: OpenAICompatibleEngine…)` with role derived from `server.port`. Signature gains `priority`/`purpose`/`broker` (defaulted). |
| Consumer edits | `LokalBotApp.swift`, `ModelsView.swift`, `EmbeddingIndex.swift`, `AgentSessionController.swift`, `AgentAccessManager.swift` | Priority/purpose parameters; embedder batch wrapped in `withLease`; session lease; TTL wake lease (§6). |
| Dashboard | modify `LokalBot/Views/Settings/ResourceMonitorSection.swift` | Model rows show "in use — chat (interactive)" while leased; the row itself disappears when the linger unload fires. |

## 5. Lease model & API

```swift
enum InferencePriority: Int, Comparable, CaseIterable, Sendable {
    case interactive = 0   // the user is watching (chat, cotyping, model test)
    case agent = 1         // an agent is waiting (Agent Mode, external ask_library)
    case background = 2    // pipeline work nobody is watching (summaries, embeddings)
}

enum InferenceRole: String, CaseIterable, Sendable {
    case mainLLM, embedder, cotypingServer
    var serverPort: Int             // 17872 / 17873 / 17874
    init?(serverPort: Int)
    var residencyID: String         // "llama-server:<port>" — matches LlamaServer's ledger id
    var defaultLingerSeconds: TimeInterval   // 600 / 600 / 900
}

struct InferenceLease: Identifiable, Equatable, Sendable {
    let id: UUID; let role: InferenceRole
    let priority: InferencePriority; let purpose: String
}

actor InferenceBroker {
    struct RuntimeHooks { let ensure: (URL) async throws -> Void; let stop: () async -> Void }
    static let shared: InferenceBroker
    init(hooks: [InferenceRole: RuntimeHooks]? = nil,          // default: live LlamaServer trio
         lingerSeconds: [InferenceRole: TimeInterval] = [:],   // test override
         leaseStateSink: (@MainActor (Set<String>, [String: [String]]) -> Void)? = nil)

    func lease(_ role: InferenceRole, model: URL, priority: InferencePriority,
               purpose: String, expiresAfter ttl: TimeInterval? = nil) async throws -> InferenceLease
    func release(_ lease: InferenceLease) async
    nonisolated func withLease<T>(_ role: InferenceRole, model: URL,
                                  priority: InferencePriority, purpose: String,
                                  _ body: () async throws -> T) async throws -> T
    func activeLeaseCount(_ role: InferenceRole) -> Int        // tests + diagnostics
}
```

`lease` ordering: record + pin **first**, then `ensure` — so the weights are protected the moment they register; if `ensure` throws, the record is released and the error propagates unchanged (callers keep seeing `LlamaServer.ServerError`). `release` drops the record, pushes the shrunken pin set, and — when it was the role's last lease — schedules the linger task. TTL leases additionally get an expiry task that releases them if the holder never comes back.

## 6. Consumers

| Consumer | Role | Priority | Purpose | Lease shape |
|---|---|---|---|---|
| Chat (`ChatViewModel` closure) | mainLLM | interactive | `chat` | per-call via `LeasedTextEngine` |
| Cotyping HTTP engine (`.cotyping` server) | cotypingServer | interactive | `cotyping` | per-call |
| Models "Test generation" button | mainLLM | interactive | `model test` | per-call |
| Meeting summary + outcomes | mainLLM | background | `summary` | per-call (defaults) |
| Day digest | mainLLM | background | `day digest` | per-call |
| Headless `--chat` / `--digest` | mainLLM | background | `summary` | per-call; explicit `stop()` at process exit stays |
| Embeddings (`EmbeddingIndex.embed`) | embedder | background | `embeddings` | per-batch `withLease` |
| Agent Mode session | mainLLM | interactive | `agent session` | held `resolveEndpoint` → `shutdown`/failure |
| `ask_library` wake (`AgentAccessManager`) | mainLLM | agent | `ask_library` | TTL 600 s; each wake acquires fresh, then releases the previous |

Notes:
- Map-reduce summaries lease per chunk call; between chunks the model is released but the 600 s linger keeps it warm, so there is no reload thrash and long summaries can't starve an interactive lease's pin forever.
- Because `LeasedTextEngine` defers `ensure` to the first call, **server boot moves from engine-creation time to first-request time**. `makeTextEngine` still fails fast at creation for a missing model file (`ServerError.modelMissing`); only the boot itself moves. Every call site already catches errors from the generate call, so the user-visible error surface is unchanged.
- `.appleIntelligence` / `.ollama` / `.openAICompatible` backends return undecorated engines, exactly as today.

## 7. Idle & eviction semantics

**Pinning.** `ModelResidencyPolicy.evictions` gains `pinned: Set<String>`; pinned ids are never victims — including the oversized-incoming case, which now evicts only unpinned residents and still proceeds best-effort (same posture as today). Pinned residents still count toward the running total, so a load alongside pinned models simply evicts fewer others. The broker pushes `LeaseBook.pinnedResidencyIDs` to `ModelResidency` on every acquire/release; `willLoad` reads the published set.

**Linger.** When a role's last lease releases, the broker schedules a task: sleep `lingerSeconds`, then — if the role still has zero leases **and** no acquire happened since (a per-role generation counter) — call the role's `stop()` hook. `LlamaServer.stop()` already unregisters the ledger row, so the dashboard row disappears on its own.

**Races.** Acquire bumps the role's generation and cancels any pending linger task. The one unavoidable interleaving: a linger task past its guards is already inside `stop()` when a new lease arrives — the new lease's `ensure` serializes *behind* `stop()` on the `LlamaServer` actor and restarts the server. Rare, wasteful, correct; same class of restart the single-flight already tolerates. A `stop()` fired for a server that never started (ensure failed earlier) is a no-op.

**What eviction still does.** Everything else: switching cotyping models, loading a bigger summarizer, ONNX/CoreML reservations squeezing GGUFs — LRU among unpinned rows, unchanged.

## 8. Dashboard

`ResourceMonitorPresentation.Model` gains `leaseNote: String?` built from `ModelResidency.pinnedIDs` + `leaseDescriptions`: `"in use — chat (interactive)"`, joined for multiple concurrent leases, `nil` when idle. Rendered as a third caption line in the Settings → Advanced model row. Idle-lingering models show no note; after linger the row vanishes — which is itself the new visible behavior ("models loaded: 0" after ten quiet minutes).

## 9. Testing

- **`LeaseBookTests`** — pure: acquire/release/counts, pin sets, description formatting + ordering, role vocabulary round-trip (ports ↔ roles, residency ids, linger constants).
- **`ModelResidencyTests` (extended)** — pinned never victim; oversized incoming spares pinned; pins consume budget; `willLoad` honors the published pin set end-to-end.
- **`InferenceBrokerTests`** — real actor, fake `RuntimeHooks` (recorders), fake `leaseStateSink`, tiny lingers (0.05 s): ensure-then-pin ordering, release-unpins-then-stops-after-linger, new-lease-cancels-linger, ensure-failure-leaves-no-lease, `withLease` releases on success and throw, TTL expiry, two-leases-one-role refcounting. Timing assertions poll with generous deadlines (≤ 3 s) rather than sleeping exact intervals.
- **`LeasedTextEngineTests`** — recording base engine + fake-hook broker: ensure precedes the base call, all four methods pass arguments/results through, errors release the lease, `displayName` forwards.
- **`AgentAccessManagerTests` (extended)** — wake acquires an `.agent` TTL lease via fake hooks; a second wake replaces (not stacks) the lease; disable releases it. Existing five tests keep passing unchanged (they inject `startEngine`).
- **Live coverage** — `Scripts/test/e2e.sh` already exercises summarize/chat/digest/ask_library against a real llama-server; no new e2e step is required, but the suite doubles as the integration proof that leasing didn't break the pipeline.

## 10. What deliberately does not change

- Headless commands still call `LlamaServer.*.stop()` explicitly before `exit()` — process exit must not wait ten minutes for a linger.
- `AppLifecycle` termination still stops all three servers directly.
- `GraniteSpeechEngine`'s private server (17875) and `LlamaCotypingRuntime` (in-process cotyping) keep their current residency integration; broker adoption is step 2.
- `ModelRuntimeRegistry` semantics, `LlamaServer` internals (single-flight, adoption, reclaim, PID markers), storage layout, and every prompt/engine behavior.
- Nothing-leaves-the-Mac: the broker adds no network surface — it only decides when existing localhost processes run.

## 11. Step 2+ roadmap (out of scope, recorded so step 1 cuts are legible)

- Pressure-derived budget: `DISPATCH_SOURCE_TYPE_MEMORYPRESSURE` + `thermalState` shrink `budgetBytes`; evict background-leased first, then idle.
- Meeting-aware admission: `MeetingDetector` blocks `background` leases during calls so transcription never contends with a summary.
- Battery/thermal deferral queue with visible state ("2 meetings waiting — will summarize when you're plugged in").
- Shared-model mode for the 16 GB tier (one model serves chat + cotyping + summaries).
- Priority-ordered eviction; in-process cotyping + Granite under the broker; eviction/linger log in the dashboard; app-hosted MCP server holding a P1 lease.

## 12. Risks

| Risk | Mitigation |
|---|---|
| Linger/stop vs. new-lease race restarts a server | Generation counter + task cancellation make it rare; the residual interleaving is a clean restart (documented in §7), never a dropped request. |
| Timing-based broker tests flake in CI-less local runs | Tiny lingers + polling waits with wide deadlines; the pure `LeaseBook` carries the logic-heavy assertions. |
| Boot moving to first request changes perceived latency | Same total work, different timestamp; the one place a user watches (ModelsView test) already shows a spinner through the generate call. |
| Concurrent branch: agent-access is uncommitted in the same tree | Plan is written against the tree as of 2026-07-11 (AgentAccessManager landed). Task 8 tells the implementer to diff against the actual file before editing. |
| A leaked lease pins a model forever | Scoped `withLease` covers all per-call paths; the two held leases release on shutdown/failure (Agent Mode) or TTL (ask_library). `activeLeaseCount` + dashboard notes make a leak visible. |

## 13. Open questions

None blocking. Linger constants (600/600/900 s) and the ask_library TTL (600 s) are first guesses — they live in one place (`InferenceRole.defaultLingerSeconds`, `AgentAccessManager.agentLeaseTTL`) and can be tuned or made user-visible later without design changes.
