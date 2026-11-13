# Inference Broker (Step 1: Leases + Idle Unload) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Spec:** `Docs/superpowers/specs/2026-07-11-inference-broker-design.md` — read it first; it explains every decision this plan encodes.

**Goal:** One actor (`InferenceBroker`) owns when the three shared llama-servers start and stop: consumers hold leases per request, leased models are pinned against `ModelResidency` eviction, and idle servers unload after a linger — fixing mid-request eviction, forever-resident summarizers, and the never-released `ask_library` server.

**Architecture:** Three new files (`InferenceLease.swift` vocabulary + pure `LeaseBook`, `InferenceBroker.swift` actor with injectable runtime hooks, `LeasedTextEngine.swift` decorator), plus surgical edits: `ModelResidencyPolicy` gains a `pinned` set, `makeTextEngine` returns lease-wrapped engines instead of calling `ensureRunning`, `EmbeddingIndex` wraps batches in `withLease`, Agent Mode holds a session lease, `ask_library` wakes hold a TTL lease, and the Settings resource monitor shows "in use — chat (interactive)" notes.

**Tech Stack:** Swift 5.10 actors + XCTest, macOS 15+, XcodeGen-generated project. No new dependencies.

## Global Constraints

- **Nothing leaves the Mac.** The broker adds no network surface — it only decides when existing localhost llama-server processes run. (CLAUDE.md invariant.)
- **Branch:** `inference-broker`, cut from `agent-access`. Before starting, run `git status` — the working tree must be clean and `LokalBot/Services/AgentAccessManager.swift` must exist (the agent-access implementation must be committed first). If either check fails, stop and reconcile with the human before writing any code.
- The `.xcodeproj` is generated: run `xcodegen generate` after adding any new source or test file, and include `LokalBot.xcodeproj` in that task's commit. Never edit the project file by hand.
- Unit tests use scheme **LokalBot** (NOT "LokalBot Dev"): `xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' test -only-testing:LokalBotTests/<ClassName> 2>&1 | tail -5`
- Running tests regenerates `default.profraw` — it is gitignored; never commit one.
- Test files live flat in `LokalBotTests/`, named `<Thing>Tests.swift`, `import XCTest` + `@testable import LokalBot`.
- **Swift 5.10, Swift 5 language mode:** no `count(where:)` on collections (Swift 6 stdlib), no strict-concurrency-only constructs. `switch` expressions in computed properties are fine (used throughout the codebase).
- In a TDD step for a compiled language, "test fails" usually means **the build fails** with "cannot find X in scope" — that is the expected red state, not a problem.
- Commit after every task, imperative subject line, no conventional-commit prefixes (match `git log`: "Add whole-app resource monitor to Settings"). Every commit message ends with the trailer line `Claude-Session: https://claude.ai/code/session_011BB4m5LTgHFUBH7odNkfRW`.
- **Do not modify:** `LlamaServer.swift` internals (single-flight, adoption, reclaim), `GraniteSpeechEngine` (its private server 17875 stays outside the broker), `LlamaCotypingRuntime` / `LocalLlamaCotypingEngine` (in-process cotyping stays outside), the explicit `LlamaServer.*.stop()` calls in `HeadlessCommands.swift` (process exit must not wait for a linger), the `AppLifecycle` termination stops, and any `.appleIntelligence`/`.ollama`/`.openAICompatible` engine code (not our servers).

## File Map

| File | Task | Change |
|---|---|---|
| `LokalBot/Engines/InferenceLease.swift` | 1 | **Create** — `InferencePriority`, `InferenceRole`, `InferenceLease`, `LeaseBook` |
| `LokalBotTests/LeaseBookTests.swift` | 1 | **Create** |
| `LokalBot/Engines/ModelResidency.swift` | 2 | Modify — `pinned:` param on policy; `pinnedIDs`/`leaseDescriptions`/`setLeaseState` on ledger |
| `LokalBotTests/ModelResidencyTests.swift` | 2 | Modify — append 5 tests |
| `LokalBot/Engines/InferenceBroker.swift` | 3 | **Create** — the actor |
| `LokalBotTests/InferenceBrokerTests.swift` | 3 | **Create** |
| `LokalBot/Engines/LeasedTextEngine.swift` | 4 | **Create** — `TextEngine` decorator |
| `LokalBotTests/LeasedTextEngineTests.swift` | 4 | **Create** |
| `LokalBot/Services/ProcessingPipeline.swift` | 5 | Modify — `makeTextEngine` signature + `.builtIn` case; day-digest purpose |
| `LokalBot/LokalBotApp.swift` | 5 | Modify — chat + cotyping closures pass priority/purpose |
| `LokalBot/Views/ModelsView.swift` | 5 | Modify — test button passes priority/purpose |
| `LokalBot/Services/EmbeddingIndex.swift` | 6 | Modify — `embed` wraps in `withLease` |
| `LokalBot/Agent/AgentSessionController.swift` | 7 | Modify — session lease |
| `LokalBot/Services/AgentAccessManager.swift` | 8 | Modify — TTL wake lease |
| `LokalBotTests/AgentAccessManagerTests.swift` | 8 | Modify — append 2 tests |
| `LokalBot/Views/ResourceMonitorSection.swift` | 9 | Modify — lease notes |
| `LokalBotTests/ResourceMonitorPresentationTests.swift` | 9 | **Create** |
| `CLAUDE.md` | 10 | Modify — one architecture sentence |

---

### Task 1: Lease vocabulary + LeaseBook

Pure types: priorities, the three server roles, the lease value, and `LeaseBook` — the broker's bookkeeping, kept clock-free and I/O-free so it unit-tests the way `ModelResidencyPolicy` does.

**Files:**
- Create: `LokalBot/Engines/InferenceLease.swift`
- Test: `LokalBotTests/LeaseBookTests.swift`

**Interfaces:**
- Consumes: nothing (Foundation only).
- Produces (used by Tasks 2–9):
  - `enum InferencePriority: Int, Comparable, CaseIterable, Sendable` — `.interactive = 0`, `.agent = 1`, `.background = 2`; `var label: String`.
  - `enum InferenceRole: String, CaseIterable, Sendable` — `.mainLLM`, `.embedder`, `.cotypingServer`; `var serverPort: Int` (17872/17873/17874); `init?(serverPort: Int)`; `var residencyID: String` (`"llama-server:<port>"`); `var defaultLingerSeconds: TimeInterval` (600/600/900).
  - `struct InferenceLease: Identifiable, Equatable, Sendable` — `id: UUID`, `role`, `priority`, `purpose: String`.
  - `struct LeaseBook` — `records: [Record]` (read-only), `mutating func acquire(role:priority:purpose:expiresAt:) -> InferenceLease`, `@discardableResult mutating func release(id: UUID) -> Bool`, `func record(id: UUID) -> Record?`, `func activeCount(for: InferenceRole) -> Int`, `var pinnedResidencyIDs: Set<String>`, `var descriptionsByResidencyID: [String: [String]]`. `Record` carries `lease: InferenceLease`, `expiresAt: Date?`.

- [ ] **Step 1: Write the failing test**

Create `LokalBotTests/LeaseBookTests.swift`:

```swift
import XCTest
@testable import LokalBot

final class LeaseBookTests: XCTestCase {

    func testRoleVocabularyMatchesLlamaServerTrio() {
        XCTAssertEqual(InferenceRole.mainLLM.serverPort, 17872)
        XCTAssertEqual(InferenceRole.embedder.serverPort, 17873)
        XCTAssertEqual(InferenceRole.cotypingServer.serverPort, 17874)
        XCTAssertEqual(InferenceRole.mainLLM.residencyID, "llama-server:17872")
        XCTAssertEqual(InferenceRole(serverPort: 17873), .embedder)
        // Granite's private ASR server stays outside the broker (spec §10).
        XCTAssertNil(InferenceRole(serverPort: 17875))
        XCTAssertTrue(InferencePriority.interactive < .agent)
        XCTAssertTrue(InferencePriority.agent < .background)
        XCTAssertEqual(InferencePriority.interactive.label, "interactive")
        XCTAssertEqual(InferenceRole.mainLLM.defaultLingerSeconds, 600)
        XCTAssertEqual(InferenceRole.embedder.defaultLingerSeconds, 600)
        XCTAssertEqual(InferenceRole.cotypingServer.defaultLingerSeconds, 900)
    }

    func testAcquireAndReleaseTrackCountsPerRole() {
        var book = LeaseBook()
        let chat = book.acquire(role: .mainLLM, priority: .interactive, purpose: "chat")
        let summary = book.acquire(role: .mainLLM, priority: .background, purpose: "summary")
        _ = book.acquire(role: .embedder, priority: .background, purpose: "embeddings")

        XCTAssertNotEqual(chat.id, summary.id)
        XCTAssertEqual(book.activeCount(for: .mainLLM), 2)
        XCTAssertEqual(book.activeCount(for: .embedder), 1)
        XCTAssertEqual(book.activeCount(for: .cotypingServer), 0)

        XCTAssertTrue(book.release(id: chat.id))
        XCTAssertEqual(book.activeCount(for: .mainLLM), 1)
        XCTAssertFalse(book.release(id: chat.id), "double release must be a no-op")
    }

    func testPinnedResidencyIDsCoverEveryOpenLease() {
        var book = LeaseBook()
        XCTAssertTrue(book.pinnedResidencyIDs.isEmpty)
        let chat = book.acquire(role: .mainLLM, priority: .interactive, purpose: "chat")
        _ = book.acquire(role: .embedder, priority: .background, purpose: "embeddings")
        XCTAssertEqual(book.pinnedResidencyIDs, ["llama-server:17872", "llama-server:17873"])
        book.release(id: chat.id)
        XCTAssertEqual(book.pinnedResidencyIDs, ["llama-server:17873"])
    }

    func testDescriptionsOrderedByPriorityThenPurpose() {
        var book = LeaseBook()
        _ = book.acquire(role: .mainLLM, priority: .background, purpose: "summary")
        _ = book.acquire(role: .mainLLM, priority: .interactive, purpose: "chat")
        _ = book.acquire(role: .embedder, priority: .background, purpose: "embeddings")

        XCTAssertEqual(book.descriptionsByResidencyID, [
            "llama-server:17872": ["chat (interactive)", "summary (background)"],
            "llama-server:17873": ["embeddings (background)"],
        ])
    }

    func testRecordKeepsExpiry() {
        var book = LeaseBook()
        let deadline = Date(timeIntervalSince1970: 1_000_000)
        let ttl = book.acquire(role: .mainLLM, priority: .agent, purpose: "ask_library",
                               expiresAt: deadline)
        let open = book.acquire(role: .mainLLM, priority: .interactive, purpose: "chat")
        XCTAssertEqual(book.record(id: ttl.id)?.expiresAt, deadline)
        XCTAssertNotNil(book.record(id: open.id))
        XCTAssertNil(book.record(id: open.id)?.expiresAt)
        book.release(id: ttl.id)
        XCTAssertNil(book.record(id: ttl.id))
    }
}
```

- [ ] **Step 2: Regenerate the project and run the test to verify it fails**

Run:
```bash
xcodegen generate
xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' test -only-testing:LokalBotTests/LeaseBookTests 2>&1 | tail -5
```
Expected: **TEST FAILED** — build error, `cannot find 'InferenceRole' in scope` / `cannot find 'LeaseBook' in scope`.

- [ ] **Step 3: Write the implementation**

Create `LokalBot/Engines/InferenceLease.swift`:

```swift
import Foundation

/// Who is waiting on an inference request, in increasing order of
/// deferability. Step 1 records priorities for the dashboard and the broker
/// API; eviction stays LRU+pins — priority-ordered eviction is a step-2
/// concern once pressure-derived budgets exist.
enum InferencePriority: Int, Comparable, CaseIterable, Sendable {
    /// The user is watching this happen (chat, cotyping, model test).
    case interactive = 0
    /// An agent is waiting (Agent Mode session, external ask_library).
    case agent = 1
    /// Pipeline work nobody is watching (summaries, digests, embeddings).
    case background = 2

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    var label: String {
        switch self {
        case .interactive: "interactive"
        case .agent: "agent"
        case .background: "background"
        }
    }
}

/// The three shared llama-server runtimes the broker owns in step 1.
/// Granite's private ASR server (17875) and the in-process cotyping runtime
/// deliberately stay outside — see the design spec §10.
enum InferenceRole: String, CaseIterable, Sendable {
    case mainLLM
    case embedder
    case cotypingServer

    var serverPort: Int {
        switch self {
        case .mainLLM: 17872
        case .embedder: 17873
        case .cotypingServer: 17874
        }
    }

    init?(serverPort: Int) {
        guard let role = Self.allCases.first(where: { $0.serverPort == serverPort }) else {
            return nil
        }
        self = role
    }

    /// Matches the ledger id `LlamaServer` registers under ("llama-server:<port>").
    var residencyID: String { "llama-server:\(serverPort)" }

    /// How long the server stays resident after its last lease releases —
    /// long enough that bursty consumers (chat follow-ups, typing) don't pay
    /// a model reload, short enough that the RAM comes back within minutes.
    var defaultLingerSeconds: TimeInterval {
        switch self {
        case .mainLLM: 600
        case .embedder: 600
        case .cotypingServer: 900
        }
    }
}

/// A claim on a running model: held for one request (or one Agent Mode
/// session). While any lease on a role is open, that model cannot be evicted
/// by the residency budget.
struct InferenceLease: Identifiable, Equatable, Sendable {
    let id: UUID
    let role: InferenceRole
    let priority: InferencePriority
    let purpose: String
}

/// Pure lease bookkeeping. The broker actor owns one; keeping the arithmetic
/// here (no clocks, no tasks, no I/O) makes it unit-testable the same way
/// `ModelResidencyPolicy` is.
struct LeaseBook {
    struct Record: Equatable {
        let lease: InferenceLease
        let expiresAt: Date?
    }

    private(set) var records: [Record] = []

    mutating func acquire(role: InferenceRole, priority: InferencePriority,
                          purpose: String, expiresAt: Date? = nil) -> InferenceLease {
        let lease = InferenceLease(id: UUID(), role: role, priority: priority, purpose: purpose)
        records.append(Record(lease: lease, expiresAt: expiresAt))
        return lease
    }

    @discardableResult
    mutating func release(id: UUID) -> Bool {
        guard let index = records.firstIndex(where: { $0.lease.id == id }) else { return false }
        records.remove(at: index)
        return true
    }

    func record(id: UUID) -> Record? {
        records.first { $0.lease.id == id }
    }

    func activeCount(for role: InferenceRole) -> Int {
        records.filter { $0.lease.role == role }.count
    }

    /// Residency ids that must never be eviction victims right now.
    var pinnedResidencyIDs: Set<String> {
        Set(records.map { $0.lease.role.residencyID })
    }

    /// Dashboard strings per residency id, e.g. "chat (interactive)",
    /// ordered by priority then purpose so the display is stable.
    var descriptionsByResidencyID: [String: [String]] {
        var out: [String: [String]] = [:]
        let ordered = records.sorted {
            ($0.lease.priority.rawValue, $0.lease.purpose)
                < ($1.lease.priority.rawValue, $1.lease.purpose)
        }
        for record in ordered {
            out[record.lease.role.residencyID, default: []]
                .append("\(record.lease.purpose) (\(record.lease.priority.label))")
        }
        return out
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run:
```bash
xcodegen generate
xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' test -only-testing:LokalBotTests/LeaseBookTests 2>&1 | tail -5
```
Expected: **TEST SUCCEEDED**, 5 tests passing.

- [ ] **Step 5: Commit**

```bash
git add LokalBot/Engines/InferenceLease.swift LokalBotTests/LeaseBookTests.swift LokalBot.xcodeproj
git commit -m "$(cat <<'EOF'
Add inference lease vocabulary and LeaseBook

Pure types for broker step 1: priorities, the three shared llama-server
roles (ports 17872-17874), the lease value, and clock-free bookkeeping.

Claude-Session: https://claude.ai/code/session_011BB4m5LTgHFUBH7odNkfRW
EOF
)"
```

---

### Task 2: Pin-aware eviction + lease state on ModelResidency

`ModelResidencyPolicy` learns to skip pinned ids when choosing victims; the `ModelResidency` ledger publishes the broker's pin set + lease descriptions (for `willLoad` and the Task-9 dashboard). Pinned residents still count toward the budget total — a pin protects weights from eviction, it doesn't create free RAM.

**Files:**
- Modify: `LokalBot/Engines/ModelResidency.swift`
- Test: `LokalBotTests/ModelResidencyTests.swift` (append tests; the file already exists with a shared `entry(_:gb:age:)` helper)

**Interfaces:**
- Consumes: nothing new.
- Produces (used by Tasks 3 and 9):
  - `ModelResidencyPolicy.evictions(residents:incomingID:incomingBytes:reservedBytes:pinned:budgetBytes:)` — new `pinned: Set<String> = []` parameter (defaulted, so every existing call site compiles unchanged).
  - `ModelResidency.pinnedIDs: Set<String>` and `ModelResidency.leaseDescriptions: [String: [String]]` — `@Published private(set)`.
  - `@MainActor func setLeaseState(pinned: Set<String>, descriptions: [String: [String]])` on `ModelResidency`.

- [ ] **Step 1: Write the failing tests**

Append to `LokalBotTests/ModelResidencyTests.swift`, inside the existing `@MainActor final class ModelResidencyTests` (it already defines `private func entry(_ id: String, gb: Int64, age: TimeInterval) -> ModelResidencyPolicy.Entry` — reuse it, don't redefine it):

```swift
    func testPinnedResidentIsNeverAVictim() {
        let victims = ModelResidencyPolicy.evictions(
            residents: [
                entry("pinned-old", gb: 4, age: 500),
                entry("unpinned-new", gb: 4, age: 10),
            ],
            incomingID: "incoming", incomingBytes: 4 * 1_073_741_824,
            pinned: ["pinned-old"],
            budgetBytes: 8 * 1_073_741_824)
        XCTAssertEqual(victims, ["unpinned-new"],
                       "the pinned LRU row must be skipped in favor of a fresher unpinned one")
    }

    func testOversizedIncomingSparesPinnedResidents() {
        let victims = ModelResidencyPolicy.evictions(
            residents: [
                entry("pinned", gb: 2, age: 300),
                entry("idle", gb: 2, age: 100),
            ],
            incomingID: "huge", incomingBytes: 32 * 1_073_741_824,
            pinned: ["pinned"],
            budgetBytes: 8 * 1_073_741_824)
        XCTAssertEqual(victims, ["idle"],
                       "best-effort oversized load still spares leased models")
    }

    func testPinnedBytesStillConsumeBudget() {
        // 4 GB pinned + 4 GB incoming exactly fills an 8 GB budget: nothing to
        // evict. Add 1 GB more of unpinned residents and it must be the victim
        // — pins are protection, not free RAM.
        let fits = ModelResidencyPolicy.evictions(
            residents: [entry("pinned", gb: 4, age: 100)],
            incomingID: "incoming", incomingBytes: 4 * 1_073_741_824,
            pinned: ["pinned"],
            budgetBytes: 8 * 1_073_741_824)
        XCTAssertEqual(fits, [])

        let overflow = ModelResidencyPolicy.evictions(
            residents: [entry("pinned", gb: 4, age: 100), entry("small", gb: 1, age: 10)],
            incomingID: "incoming", incomingBytes: 4 * 1_073_741_824,
            pinned: ["pinned"],
            budgetBytes: 8 * 1_073_741_824)
        XCTAssertEqual(overflow, ["small"])
    }

    func testWillLoadHonorsPublishedPins() async {
        let residency = ModelResidency(budgetBytes: 8 * 1_073_741_824)
        final class Unloads { var ids: [String] = [] }
        let unloads = Unloads()
        residency.register(id: "pinned-old", label: "Pinned", bytes: 4 * 1_073_741_824,
                           unload: { unloads.ids.append("pinned-old") })
        residency.register(id: "idle-new", label: "Idle", bytes: 4 * 1_073_741_824,
                           unload: { unloads.ids.append("idle-new") })
        // Make "idle-new" strictly fresher, so "pinned-old" is the LRU choice —
        // then pin it.
        residency.touch(id: "idle-new")
        residency.setLeaseState(pinned: ["pinned-old"], descriptions: [:])

        await residency.willLoad(id: "incoming", bytes: 4 * 1_073_741_824)

        XCTAssertEqual(unloads.ids, ["idle-new"])
        XCTAssertEqual(residency.residents.map(\.id), ["pinned-old"])
    }

    func testSetLeaseStatePublishesPinsAndDescriptions() {
        let residency = ModelResidency(budgetBytes: 8 * 1_073_741_824)
        residency.setLeaseState(
            pinned: ["llama-server:17872"],
            descriptions: ["llama-server:17872": ["chat (interactive)"]])
        XCTAssertEqual(residency.pinnedIDs, ["llama-server:17872"])
        XCTAssertEqual(residency.leaseDescriptions["llama-server:17872"], ["chat (interactive)"])

        residency.setLeaseState(pinned: [], descriptions: [:])
        XCTAssertTrue(residency.pinnedIDs.isEmpty)
        XCTAssertTrue(residency.leaseDescriptions.isEmpty)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:
```bash
xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' test -only-testing:LokalBotTests/ModelResidencyTests 2>&1 | tail -5
```
Expected: **TEST FAILED** — build error, `extra argument 'pinned' in call` and `value of type 'ModelResidency' has no member 'setLeaseState'`.

- [ ] **Step 3: Implement the policy + ledger changes**

In `LokalBot/Engines/ModelResidency.swift`, make three edits.

**Edit 1** — replace the whole `evictions` function (including its doc comment) in `enum ModelResidencyPolicy`:

Current:
```swift
    /// IDs to evict, least-recently-used first, so the surviving residents
    /// plus the incoming load fit `budgetBytes`. The incoming id is never a
    /// victim. When the newcomer alone exceeds the budget, everything else is
    /// evicted and the load proceeds best-effort — refusing to load would
    /// break the feature the user just asked for.
    static func evictions(residents: [Entry], incomingID: String,
                          incomingBytes: Int64, reservedBytes: Int64 = 0,
                          budgetBytes: Int64) -> [String] {
        let kept = residents.filter { $0.id != incomingID }
        var total = kept.reduce(0) { $0 + $1.bytes }
        total = total.addingReportingOverflow(max(0, incomingBytes)).overflow
            ? .max : total + max(0, incomingBytes)
        total = total.addingReportingOverflow(max(0, reservedBytes)).overflow
            ? .max : total + max(0, reservedBytes)
        guard total > budgetBytes else { return [] }
        var victims: [String] = []
        for entry in kept.sorted(by: { $0.lastUsed < $1.lastUsed }) {
            guard total > budgetBytes else { break }
            victims.append(entry.id)
            total -= entry.bytes
        }
        return victims
    }
```

New:
```swift
    /// IDs to evict, least-recently-used first, so the surviving residents
    /// plus the incoming load fit `budgetBytes`. The incoming id is never a
    /// victim, and neither is any pinned id — an open inference lease means a
    /// request is running against those weights right now. Pinned bytes still
    /// count toward the total, so admission stays honest. When the newcomer
    /// alone exceeds the budget, everything unpinned is evicted and the load
    /// proceeds best-effort — refusing to load would break the feature the
    /// user just asked for.
    static func evictions(residents: [Entry], incomingID: String,
                          incomingBytes: Int64, reservedBytes: Int64 = 0,
                          pinned: Set<String> = [],
                          budgetBytes: Int64) -> [String] {
        let kept = residents.filter { $0.id != incomingID }
        var total = kept.reduce(0) { $0 + $1.bytes }
        total = total.addingReportingOverflow(max(0, incomingBytes)).overflow
            ? .max : total + max(0, incomingBytes)
        total = total.addingReportingOverflow(max(0, reservedBytes)).overflow
            ? .max : total + max(0, reservedBytes)
        guard total > budgetBytes else { return [] }
        var victims: [String] = []
        for entry in kept.sorted(by: { $0.lastUsed < $1.lastUsed })
        where !pinned.contains(entry.id) {
            guard total > budgetBytes else { break }
            victims.append(entry.id)
            total -= entry.bytes
        }
        return victims
    }
```

**Edit 2** — in `final class ModelResidency`, directly below the existing `@Published private(set) var residents: [Resident] = []` line, add:

```swift
    /// Residency ids currently pinned by open inference leases (pushed by
    /// `InferenceBroker`). Pinned rows are never eviction victims; they still
    /// count toward the budget. Descriptions are dashboard strings per id,
    /// e.g. "chat (interactive)".
    @Published private(set) var pinnedIDs: Set<String> = []
    @Published private(set) var leaseDescriptions: [String: [String]] = [:]
```

and directly below the existing `func touch(id: String)` function, add:

```swift
    func setLeaseState(pinned: Set<String>, descriptions: [String: [String]]) {
        pinnedIDs = pinned
        leaseDescriptions = descriptions
    }
```

**Edit 3** — in `willLoad`, pass the pins through. Current call:

```swift
        let victims = ModelResidencyPolicy.evictions(
            residents: residents.map { .init(id: $0.id, bytes: $0.bytes, lastUsed: $0.lastUsed) },
            incomingID: id, incomingBytes: bytes, reservedBytes: reservedBytes,
            budgetBytes: budgetBytes)
```

New:

```swift
        let victims = ModelResidencyPolicy.evictions(
            residents: residents.map { .init(id: $0.id, bytes: $0.bytes, lastUsed: $0.lastUsed) },
            incomingID: id, incomingBytes: bytes, reservedBytes: reservedBytes,
            pinned: pinnedIDs,
            budgetBytes: budgetBytes)
```

- [ ] **Step 4: Run the tests to verify they pass (old tests included)**

Run:
```bash
xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' test -only-testing:LokalBotTests/ModelResidencyTests 2>&1 | tail -5
```
Expected: **TEST SUCCEEDED** — all pre-existing tests plus the 5 new ones. The pre-existing tests compile unchanged because `pinned:` is defaulted.

- [ ] **Step 5: Commit**

```bash
git add LokalBot/Engines/ModelResidency.swift LokalBotTests/ModelResidencyTests.swift
git commit -m "$(cat <<'EOF'
Teach model residency about lease pins

Pinned residency ids (pushed by the upcoming InferenceBroker) are never
eviction victims but still count toward the RAM budget; the ledger
publishes pin state and lease descriptions for willLoad and the
resource monitor.

Claude-Session: https://claude.ai/code/session_011BB4m5LTgHFUBH7odNkfRW
EOF
)"
```

---

### Task 3: InferenceBroker actor

The actor: `lease`/`release`/`withLease`, injectable `RuntimeHooks` (defaulting to the live `LlamaServer` trio), pin pushes to `ModelResidency`, per-role linger unload, and TTL expiry. Tests run against recorder hooks and a recorder sink with tiny lingers — no real llama-server anywhere.

**Files:**
- Create: `LokalBot/Engines/InferenceBroker.swift`
- Test: `LokalBotTests/InferenceBrokerTests.swift`

**Interfaces:**
- Consumes: `LeaseBook`, `InferenceRole`, `InferencePriority`, `InferenceLease` (Task 1); `ModelResidency.setLeaseState` (Task 2); `LlamaServer.shared/.embedder/.cotyping` `ensureRunning(modelAt:)`/`stop()` (existing); global `lokalbotLog(_:)` (existing).
- Produces (used by Tasks 4–8):
  - `actor InferenceBroker` with `static let shared`.
  - `struct RuntimeHooks { let ensure: (URL) async throws -> Void; let stop: () async -> Void }` (nested in the actor).
  - `init(hooks: [InferenceRole: RuntimeHooks]? = nil, lingerSeconds: [InferenceRole: TimeInterval] = [:], leaseStateSink: (@MainActor (Set<String>, [String: [String]]) -> Void)? = nil)`.
  - `func lease(_ role: InferenceRole, model: URL, priority: InferencePriority, purpose: String, expiresAfter ttl: TimeInterval? = nil) async throws -> InferenceLease`
  - `func release(_ lease: InferenceLease) async`
  - `nonisolated func withLease<T>(_ role: InferenceRole, model: URL, priority: InferencePriority, purpose: String, _ body: () async throws -> T) async throws -> T`
  - `func activeLeaseCount(_ role: InferenceRole) -> Int`

- [ ] **Step 1: Write the failing tests**

Create `LokalBotTests/InferenceBrokerTests.swift`:

```swift
import XCTest
@testable import LokalBot

@MainActor
final class InferenceBrokerTests: XCTestCase {

    // MARK: - Test doubles

    private actor HookRecorder {
        private(set) var events: [String] = []
        func record(_ event: String) { events.append(event) }
        func count(of event: String) -> Int { events.filter { $0 == event }.count }
    }

    @MainActor
    private final class SinkRecorder {
        private(set) var pinnedHistory: [Set<String>] = []
        private(set) var descriptionsHistory: [[String: [String]]] = []
        func record(pinned: Set<String>, descriptions: [String: [String]]) {
            pinnedHistory.append(pinned)
            descriptionsHistory.append(descriptions)
        }
        var lastPinned: Set<String> { pinnedHistory.last ?? [] }
        var lastDescriptions: [String: [String]] { descriptionsHistory.last ?? [:] }
    }

    private struct TestFailure: Error {}

    /// Never touched by the fake hooks — just a value to pass around.
    private let modelURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("broker-test-fake.gguf")

    private func makeBroker(recorder: HookRecorder, sink: SinkRecorder,
                            linger: TimeInterval = 0.05,
                            failingRoles: Set<InferenceRole> = []) -> InferenceBroker {
        var hooks: [InferenceRole: InferenceBroker.RuntimeHooks] = [:]
        for role in InferenceRole.allCases {
            hooks[role] = InferenceBroker.RuntimeHooks(
                ensure: { _ in
                    if failingRoles.contains(role) { throw TestFailure() }
                    await recorder.record("ensure:\(role.rawValue)")
                },
                stop: { await recorder.record("stop:\(role.rawValue)") })
        }
        return InferenceBroker(
            hooks: hooks,
            lingerSeconds: Dictionary(uniqueKeysWithValues:
                InferenceRole.allCases.map { ($0, linger) }),
            leaseStateSink: { pinned, descriptions in
                sink.record(pinned: pinned, descriptions: descriptions)
            })
    }

    /// Polls instead of sleeping fixed intervals so timing tests stay robust
    /// on loaded machines.
    private func waitUntil(timeout: TimeInterval = 3,
                           _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return await condition()
    }

    // MARK: - Tests

    func testLeaseBootsRuntimePinsAndCounts() async throws {
        let recorder = HookRecorder()
        let sink = SinkRecorder()
        let broker = makeBroker(recorder: recorder, sink: sink)

        let lease = try await broker.lease(.mainLLM, model: modelURL,
                                           priority: .interactive, purpose: "chat")

        let ensures = await recorder.count(of: "ensure:mainLLM")
        XCTAssertEqual(ensures, 1)
        XCTAssertEqual(sink.lastPinned, ["llama-server:17872"])
        XCTAssertEqual(sink.lastDescriptions["llama-server:17872"], ["chat (interactive)"])
        let active = await broker.activeLeaseCount(.mainLLM)
        XCTAssertEqual(active, 1)
        await broker.release(lease)
    }

    func testReleaseUnpinsImmediatelyThenStopsAfterLinger() async throws {
        let recorder = HookRecorder()
        let sink = SinkRecorder()
        let broker = makeBroker(recorder: recorder, sink: sink, linger: 0.05)

        let lease = try await broker.lease(.mainLLM, model: modelURL,
                                           priority: .background, purpose: "summary")
        await broker.release(lease)

        XCTAssertEqual(sink.lastPinned, [], "pin must drop at release, not at unload")
        let stoppedBeforeLinger = await recorder.count(of: "stop:mainLLM")
        XCTAssertEqual(stoppedBeforeLinger, 0, "stop must wait for the linger")
        let stopped = await waitUntil { await recorder.count(of: "stop:mainLLM") == 1 }
        XCTAssertTrue(stopped, "idle server must stop after the linger elapses")
    }

    func testNewLeaseCancelsPendingLinger() async throws {
        let recorder = HookRecorder()
        let sink = SinkRecorder()
        let broker = makeBroker(recorder: recorder, sink: sink, linger: 0.2)

        let first = try await broker.lease(.mainLLM, model: modelURL,
                                           priority: .background, purpose: "summary")
        await broker.release(first)
        let second = try await broker.lease(.mainLLM, model: modelURL,
                                            priority: .interactive, purpose: "chat")

        // Wait well past the linger; the cancelled task must never stop the server.
        try await Task.sleep(nanoseconds: 500_000_000)
        let stops = await recorder.count(of: "stop:mainLLM")
        XCTAssertEqual(stops, 0)
        await broker.release(second)
    }

    func testEnsureFailureLeavesNoLeaseOrPin() async {
        let recorder = HookRecorder()
        let sink = SinkRecorder()
        let broker = makeBroker(recorder: recorder, sink: sink,
                                failingRoles: [.mainLLM])

        do {
            _ = try await broker.lease(.mainLLM, model: modelURL,
                                       priority: .interactive, purpose: "chat")
            XCTFail("expected the ensure failure to propagate")
        } catch {
            XCTAssertTrue(error is TestFailure)
        }
        XCTAssertEqual(sink.lastPinned, [])
        let active = await broker.activeLeaseCount(.mainLLM)
        XCTAssertEqual(active, 0)
    }

    func testWithLeaseReleasesOnSuccessAndOnThrow() async throws {
        let recorder = HookRecorder()
        let sink = SinkRecorder()
        let broker = makeBroker(recorder: recorder, sink: sink)

        let value = try await broker.withLease(.embedder, model: modelURL,
                                               priority: .background,
                                               purpose: "embeddings") { 42 }
        XCTAssertEqual(value, 42)
        var active = await broker.activeLeaseCount(.embedder)
        XCTAssertEqual(active, 0)

        do {
            _ = try await broker.withLease(.embedder, model: modelURL,
                                           priority: .background,
                                           purpose: "embeddings") { () async throws -> Int in
                throw TestFailure()
            }
            XCTFail("expected the body error to propagate")
        } catch {
            XCTAssertTrue(error is TestFailure)
        }
        active = await broker.activeLeaseCount(.embedder)
        XCTAssertEqual(active, 0)
        XCTAssertEqual(sink.lastPinned, [])
    }

    func testTTLLeaseExpiresOnItsOwn() async throws {
        let recorder = HookRecorder()
        let sink = SinkRecorder()
        let broker = makeBroker(recorder: recorder, sink: sink, linger: 0.05)

        _ = try await broker.lease(.mainLLM, model: modelURL, priority: .agent,
                                   purpose: "ask_library", expiresAfter: 0.05)

        let released = await waitUntil { await broker.activeLeaseCount(.mainLLM) == 0 }
        XCTAssertTrue(released, "TTL lease must release itself")
        let stopped = await waitUntil { await recorder.count(of: "stop:mainLLM") == 1 }
        XCTAssertTrue(stopped, "expiry must start the linger like any release")
    }

    func testSecondLeaseOnSameRoleKeepsRuntimeAlive() async throws {
        let recorder = HookRecorder()
        let sink = SinkRecorder()
        let broker = makeBroker(recorder: recorder, sink: sink, linger: 0.05)

        let chat = try await broker.lease(.mainLLM, model: modelURL,
                                          priority: .interactive, purpose: "chat")
        let summary = try await broker.lease(.mainLLM, model: modelURL,
                                             priority: .background, purpose: "summary")
        XCTAssertEqual(sink.lastDescriptions["llama-server:17872"],
                       ["chat (interactive)", "summary (background)"])

        await broker.release(chat)
        // Well past the 0.05 s linger — the surviving lease must hold the runtime.
        try await Task.sleep(nanoseconds: 300_000_000)
        let stopsWhileHeld = await recorder.count(of: "stop:mainLLM")
        XCTAssertEqual(stopsWhileHeld, 0)
        XCTAssertEqual(sink.lastPinned, ["llama-server:17872"])

        await broker.release(summary)
        let stopped = await waitUntil { await recorder.count(of: "stop:mainLLM") == 1 }
        XCTAssertTrue(stopped)
    }
}
```

- [ ] **Step 2: Regenerate the project and run the tests to verify they fail**

Run:
```bash
xcodegen generate
xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' test -only-testing:LokalBotTests/InferenceBrokerTests 2>&1 | tail -5
```
Expected: **TEST FAILED** — build error, `cannot find 'InferenceBroker' in scope`.

- [ ] **Step 3: Write the implementation**

Create `LokalBot/Engines/InferenceBroker.swift`:

```swift
import Foundation

/// One actor owns when the shared llama-server runtimes start and stop.
/// Consumers no longer call `ensureRunning` directly; they take a lease for
/// the duration of a request (or a session), which
///  - boots the server on demand,
///  - pins the model against `ModelResidency` eviction while any lease is open,
///  - unloads the server after `lingerSeconds` without leases, returning RAM.
///
/// Step 1 is deliberately mechanical: no admission control, no pressure-derived
/// budgets, no priority-ordered eviction. Priorities are recorded for the
/// dashboard and for step 2 (see the design spec §11).
actor InferenceBroker {

    /// How the broker starts/stops one role's runtime. Injected so unit tests
    /// run against recorders instead of real llama-server processes.
    struct RuntimeHooks {
        let ensure: (URL) async throws -> Void
        let stop: () async -> Void
    }

    static let shared = InferenceBroker()

    private let hooks: [InferenceRole: RuntimeHooks]
    private let lingerSeconds: [InferenceRole: TimeInterval]
    private let leaseStateSink: @MainActor (Set<String>, [String: [String]]) -> Void

    private var book = LeaseBook()
    /// Bumped on every acquire; a linger task only stops the runtime when the
    /// generation it captured is still current (no acquire happened since).
    private var generations: [InferenceRole: UInt64] = [:]
    private var lingerTasks: [InferenceRole: Task<Void, Never>] = [:]
    private var expiryTasks: [UUID: Task<Void, Never>] = [:]

    init(hooks: [InferenceRole: RuntimeHooks]? = nil,
         lingerSeconds: [InferenceRole: TimeInterval] = [:],
         leaseStateSink: (@MainActor (Set<String>, [String: [String]]) -> Void)? = nil) {
        self.hooks = hooks ?? [
            .mainLLM: RuntimeHooks(
                ensure: { try await LlamaServer.shared.ensureRunning(modelAt: $0) },
                stop: { await LlamaServer.shared.stop() }),
            .embedder: RuntimeHooks(
                ensure: { try await LlamaServer.embedder.ensureRunning(modelAt: $0) },
                stop: { await LlamaServer.embedder.stop() }),
            .cotypingServer: RuntimeHooks(
                ensure: { try await LlamaServer.cotyping.ensureRunning(modelAt: $0) },
                stop: { await LlamaServer.cotyping.stop() }),
        ]
        self.lingerSeconds = lingerSeconds
        self.leaseStateSink = leaseStateSink ?? { pinned, descriptions in
            ModelResidency.shared.setLeaseState(pinned: pinned, descriptions: descriptions)
        }
    }

    // MARK: - Leasing

    /// Books the lease (pinning the model *before* the load so an eviction
    /// can't race the boot), then boots the runtime if needed. On ensure
    /// failure the lease is released and the error propagates unchanged, so
    /// callers keep seeing `LlamaServer.ServerError`.
    func lease(_ role: InferenceRole, model: URL, priority: InferencePriority,
               purpose: String,
               expiresAfter ttl: TimeInterval? = nil) async throws -> InferenceLease {
        generations[role, default: 0] += 1
        lingerTasks[role]?.cancel()
        lingerTasks[role] = nil
        let expiresAt = ttl.map { Date().addingTimeInterval($0) }
        let lease = book.acquire(role: role, priority: priority, purpose: purpose,
                                 expiresAt: expiresAt)
        await pushLeaseState()
        do {
            try await runtimeHooks(for: role).ensure(model)
        } catch {
            book.release(id: lease.id)
            await pushLeaseState()
            throw error
        }
        if let ttl { scheduleExpiry(for: lease, after: ttl) }
        return lease
    }

    func release(_ lease: InferenceLease) async {
        expiryTasks[lease.id]?.cancel()
        expiryTasks[lease.id] = nil
        guard book.release(id: lease.id) else { return }
        await pushLeaseState()
        if book.activeCount(for: lease.role) == 0 {
            scheduleLinger(for: lease.role)
        }
    }

    /// Scoped lease for one request: acquire, run `body`, always release.
    nonisolated func withLease<T>(_ role: InferenceRole, model: URL,
                                  priority: InferencePriority, purpose: String,
                                  _ body: () async throws -> T) async throws -> T {
        let acquired = try await lease(role, model: model, priority: priority,
                                       purpose: purpose)
        do {
            let value = try await body()
            await release(acquired)
            return value
        } catch {
            await release(acquired)
            throw error
        }
    }

    func activeLeaseCount(_ role: InferenceRole) -> Int {
        book.activeCount(for: role)
    }

    // MARK: - Idle unload

    private func scheduleLinger(for role: InferenceRole) {
        let generation = generations[role, default: 0]
        let delay = lingerSeconds[role] ?? role.defaultLingerSeconds
        lingerTasks[role] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.lingerFired(role: role, generation: generation)
        }
    }

    private func lingerFired(role: InferenceRole, generation: UInt64) async {
        guard generations[role, default: 0] == generation,
              book.activeCount(for: role) == 0 else { return }
        lingerTasks[role] = nil
        lokalbotLog("inference broker: stopping idle \(role.rawValue) after linger")
        // Documented race (spec §7): if a new lease lands while this stop is
        // in flight, its ensure serializes behind the stop on the LlamaServer
        // actor and restarts the server — rare and wasteful, never incorrect.
        await runtimeHooks(for: role).stop()
    }

    // MARK: - TTL expiry

    private func scheduleExpiry(for lease: InferenceLease, after ttl: TimeInterval) {
        expiryTasks[lease.id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(ttl * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.expiryFired(leaseID: lease.id)
        }
    }

    private func expiryFired(leaseID: UUID) async {
        guard let record = book.record(id: leaseID),
              let expiresAt = record.expiresAt, expiresAt <= Date() else { return }
        await release(record.lease)
    }

    // MARK: - Plumbing

    private func runtimeHooks(for role: InferenceRole) -> RuntimeHooks {
        guard let roleHooks = hooks[role] else {
            preconditionFailure("no runtime hooks for \(role.rawValue)")
        }
        return roleHooks
    }

    private func pushLeaseState() async {
        let pinned = book.pinnedResidencyIDs
        let descriptions = book.descriptionsByResidencyID
        await leaseStateSink(pinned, descriptions)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run:
```bash
xcodegen generate
xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' test -only-testing:LokalBotTests/InferenceBrokerTests 2>&1 | tail -5
```
Expected: **TEST SUCCEEDED**, 7 tests passing. If a timing test flakes on a heavily loaded machine, re-run once; the polls allow 3 s, so repeated failure is a real bug, not noise.

- [ ] **Step 5: Commit**

```bash
git add LokalBot/Engines/InferenceBroker.swift LokalBotTests/InferenceBrokerTests.swift LokalBot.xcodeproj
git commit -m "$(cat <<'EOF'
Add InferenceBroker actor with leases, linger unload, and TTL expiry

Leases pin models against residency eviction for the duration of a
request; the last release starts a per-role linger after which the
runtime stops and its RAM returns. Runtime hooks are injectable so the
tests run against recorders instead of llama-server.

Claude-Session: https://claude.ai/code/session_011BB4m5LTgHFUBH7odNkfRW
EOF
)"
```

---

### Task 4: LeasedTextEngine decorator

A `TextEngine` wrapper that runs every call under `broker.withLease`. **Critical detail:** the `TextEngine` protocol extension (in `LokalBot/Engines/TextEngine.swift`) provides default implementations of `generate(system:prompt:context:schema:)`, `complete(_:)`, and `completeStreaming(_:onPartial:)`. The decorator must implement **all four** protocol methods explicitly and forward to `base` — otherwise the extension defaults would silently bypass `OpenAICompatibleEngine`'s own schema/raw-completions/SSE overrides.

**Files:**
- Create: `LokalBot/Engines/LeasedTextEngine.swift`
- Test: `LokalBotTests/LeasedTextEngineTests.swift`

**Interfaces:**
- Consumes: `TextEngine` + `CompletionRequest` (existing, `LokalBot/Engines/TextEngine.swift`); `InferenceBroker.withLease` (Task 3); `InferenceRole`/`InferencePriority` (Task 1).
- Produces (used by Task 5): `struct LeasedTextEngine: TextEngine` with memberwise init `(base: TextEngine, broker: InferenceBroker, role: InferenceRole, modelURL: URL, priority: InferencePriority, purpose: String)`.

- [ ] **Step 1: Write the failing tests**

Create `LokalBotTests/LeasedTextEngineTests.swift`:

```swift
import XCTest
@testable import LokalBot

@MainActor
final class LeasedTextEngineTests: XCTestCase {

    private actor CallRecorder {
        private(set) var events: [String] = []
        func record(_ event: String) { events.append(event) }
        func count(of event: String) -> Int { events.filter { $0 == event }.count }
    }

    /// Records calls into the same recorder as the broker hooks so ordering
    /// between "ensure" and the engine call is observable.
    private struct RecordingEngine: TextEngine {
        let recorder: CallRecorder
        var displayName: String { "recording-engine" }

        func generate(system: String, prompt: String, context: [String]) async throws -> String {
            await recorder.record("generate")
            return "plain:\(prompt)"
        }

        func generate(system: String, prompt: String, context: [String],
                      schema: [String: Any]) async throws -> String {
            await recorder.record("generate-schema")
            return "schema:\(prompt)"
        }

        func complete(_ request: CompletionRequest) async throws -> String {
            await recorder.record("complete")
            return "complete:\(request.prompt)"
        }

        func completeStreaming(_ request: CompletionRequest,
                               onPartial: @escaping @Sendable (String) -> Void) async throws -> String {
            await recorder.record("stream")
            onPartial("partial-chunk")
            return "stream:\(request.prompt)"
        }
    }

    private struct TestFailure: Error {}

    private struct ThrowingEngine: TextEngine {
        var displayName: String { "throwing-engine" }
        func generate(system: String, prompt: String, context: [String]) async throws -> String {
            throw TestFailure()
        }
    }

    private let modelURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("leased-engine-fake.gguf")

    private func makeBroker(recorder: CallRecorder) -> InferenceBroker {
        var hooks: [InferenceRole: InferenceBroker.RuntimeHooks] = [:]
        for role in InferenceRole.allCases {
            hooks[role] = InferenceBroker.RuntimeHooks(
                ensure: { _ in await recorder.record("ensure:\(role.rawValue)") },
                stop: { await recorder.record("stop:\(role.rawValue)") })
        }
        return InferenceBroker(hooks: hooks,
                               leaseStateSink: { _, _ in })
    }

    private var completionRequest: CompletionRequest {
        CompletionRequest(prompt: "the-prompt", maxTokens: 8, temperature: 0.2,
                          topP: 0.9, topK: 40, minP: 0.05, repeatPenalty: 1.1,
                          seed: 7, stop: [])
    }

    private func makeEngine(recorder: CallRecorder,
                            broker: InferenceBroker) -> LeasedTextEngine {
        LeasedTextEngine(base: RecordingEngine(recorder: recorder), broker: broker,
                         role: .mainLLM, modelURL: modelURL,
                         priority: .background, purpose: "summary")
    }

    func testGenerateEnsuresBeforeBaseCallAndReleasesAfter() async throws {
        let recorder = CallRecorder()
        let broker = makeBroker(recorder: recorder)
        let engine = makeEngine(recorder: recorder, broker: broker)

        let reply = try await engine.generate(system: "s", prompt: "p", context: [])

        XCTAssertEqual(reply, "plain:p")
        let events = await recorder.events
        XCTAssertEqual(events, ["ensure:mainLLM", "generate"],
                       "the runtime must be ensured before the base engine runs")
        let active = await broker.activeLeaseCount(.mainLLM)
        XCTAssertEqual(active, 0, "the per-call lease must release when the call returns")
    }

    func testAllFourProtocolMethodsForwardToBase() async throws {
        let recorder = CallRecorder()
        let broker = makeBroker(recorder: recorder)
        let engine = makeEngine(recorder: recorder, broker: broker)

        let schema = try await engine.generate(system: "s", prompt: "p", context: [],
                                               schema: ["type": "object"])
        XCTAssertEqual(schema, "schema:p")

        let completion = try await engine.complete(completionRequest)
        XCTAssertEqual(completion, "complete:the-prompt")

        var partials: [String] = []
        let streamed = try await engine.completeStreaming(completionRequest) { partials.append($0) }
        XCTAssertEqual(streamed, "stream:the-prompt")
        XCTAssertEqual(partials, ["partial-chunk"])

        // One lease (one ensure) per call — three calls, three ensures.
        let ensures = await recorder.count(of: "ensure:mainLLM")
        XCTAssertEqual(ensures, 3)
        let baseCalls = await recorder.events.filter { !$0.hasPrefix("ensure:") && !$0.hasPrefix("stop:") }
        XCTAssertEqual(baseCalls, ["generate-schema", "complete", "stream"],
                       "each wrapper must hit the base engine's own method, not a protocol default")
    }

    func testDisplayNameForwardsWithoutLeasing() async {
        let recorder = CallRecorder()
        let broker = makeBroker(recorder: recorder)
        let engine = makeEngine(recorder: recorder, broker: broker)

        XCTAssertEqual(engine.displayName, "recording-engine")
        let events = await recorder.events
        XCTAssertTrue(events.isEmpty, "reading displayName must not boot anything")
    }

    func testBaseEngineErrorStillReleasesLease() async {
        let recorder = CallRecorder()
        let broker = makeBroker(recorder: recorder)
        let engine = LeasedTextEngine(base: ThrowingEngine(), broker: broker,
                                      role: .mainLLM, modelURL: modelURL,
                                      priority: .interactive, purpose: "chat")

        do {
            _ = try await engine.generate(system: "s", prompt: "p", context: [])
            XCTFail("expected the base error to propagate")
        } catch {
            XCTAssertTrue(error is TestFailure)
        }
        let active = await broker.activeLeaseCount(.mainLLM)
        XCTAssertEqual(active, 0)
    }
}
```

If `CompletionRequest`'s memberwise init differs from the parameters above, open `LokalBot/Engines/TextEngine.swift`, copy its actual stored-property list into `completionRequest`, and keep `prompt: "the-prompt"` — the assertions only depend on `prompt`.

- [ ] **Step 2: Regenerate the project and run the tests to verify they fail**

Run:
```bash
xcodegen generate
xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' test -only-testing:LokalBotTests/LeasedTextEngineTests 2>&1 | tail -5
```
Expected: **TEST FAILED** — build error, `cannot find 'LeasedTextEngine' in scope`.

- [ ] **Step 3: Write the implementation**

Create `LokalBot/Engines/LeasedTextEngine.swift`:

```swift
import Foundation

/// A `TextEngine` decorator that runs every call under an `InferenceBroker`
/// lease: the runtime boots on first use (not at engine creation), stays
/// pinned against eviction for the duration of the call, and goes idle
/// (linger, then unload) when no calls are in flight.
///
/// Every protocol method is implemented explicitly. The `TextEngine`
/// extension provides defaults for the schema/complete/streaming variants;
/// relying on them here would silently bypass the base engine's own
/// overrides (e.g. `OpenAICompatibleEngine`'s raw-completions and SSE paths).
struct LeasedTextEngine: TextEngine {
    let base: TextEngine
    let broker: InferenceBroker
    let role: InferenceRole
    let modelURL: URL
    let priority: InferencePriority
    let purpose: String

    var displayName: String { base.displayName }

    func generate(system: String, prompt: String, context: [String]) async throws -> String {
        try await broker.withLease(role, model: modelURL, priority: priority, purpose: purpose) {
            try await base.generate(system: system, prompt: prompt, context: context)
        }
    }

    func generate(system: String, prompt: String, context: [String],
                  schema: [String: Any]) async throws -> String {
        try await broker.withLease(role, model: modelURL, priority: priority, purpose: purpose) {
            try await base.generate(system: system, prompt: prompt, context: context,
                                    schema: schema)
        }
    }

    func complete(_ request: CompletionRequest) async throws -> String {
        try await broker.withLease(role, model: modelURL, priority: priority, purpose: purpose) {
            try await base.complete(request)
        }
    }

    func completeStreaming(_ request: CompletionRequest,
                           onPartial: @escaping @Sendable (String) -> Void) async throws -> String {
        try await broker.withLease(role, model: modelURL, priority: priority, purpose: purpose) {
            try await base.completeStreaming(request, onPartial: onPartial)
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run:
```bash
xcodegen generate
xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' test -only-testing:LokalBotTests/LeasedTextEngineTests 2>&1 | tail -5
```
Expected: **TEST SUCCEEDED**, 4 tests passing.

- [ ] **Step 5: Commit**

```bash
git add LokalBot/Engines/LeasedTextEngine.swift LokalBotTests/LeasedTextEngineTests.swift LokalBot.xcodeproj
git commit -m "$(cat <<'EOF'
Add LeasedTextEngine decorator

Wraps a TextEngine so every generate/complete/streaming call runs under
a broker lease. All four protocol methods forward explicitly so the
base engine's own overrides are preserved.

Claude-Session: https://claude.ai/code/session_011BB4m5LTgHFUBH7odNkfRW
EOF
)"
```

---

### Task 5: Route makeTextEngine through the broker

`ProcessingPipeline.makeTextEngine` is the choke point — summarize, outcomes, day digest, chat, headless `--chat`, cotyping-HTTP, and the ModelsView test button all build engines here. The `.builtIn` case stops calling `ensureRunning` and returns a `LeasedTextEngine` instead; interactive call sites pass their priority/purpose. The other three backends (`.appleIntelligence`, `.ollama`, `.openAICompatible`) are not our servers and stay untouched.

**Behavior note (intended, spec §6):** server boot moves from engine-creation time to the first generate call. `makeTextEngine` still fails fast for a missing model file (`ServerError.modelMissing`); only the boot moves. Every call site already catches errors from the generate call.

No new unit test in this task: the change is pure wiring whose pieces are already covered (Task 3 proves leases boot/pin/release; Task 4 proves the decorator forwards). Verification here is compile + the full existing unit suite, and `Scripts/test/e2e.sh` exercises the live path at the end (Task 10).

**Files:**
- Modify: `LokalBot/Services/ProcessingPipeline.swift` (makeTextEngine ~line 484; generateDayDigest ~line 454)
- Modify: `LokalBot/LokalBotApp.swift` (cotyping closure ~line 320; chat closure ~line 356)
- Modify: `LokalBot/Views/ModelsView.swift` (testGeneration ~line 638)

**Interfaces:**
- Consumes: `LeasedTextEngine` (Task 4), `InferenceBroker.shared` (Task 3), `InferenceRole(serverPort:)` + `InferencePriority` (Task 1), `LlamaServer.port` (existing `nonisolated let`).
- Produces (used by Tasks 7–8 conceptually; signature consumed by all engine call sites):
  `func makeTextEngine(_ config: AppSettings, server: LlamaServer = .shared, priority: InferencePriority = .background, purpose: String = "summary", broker: InferenceBroker = .shared) async throws -> TextEngine`
  All existing call sites compile unchanged (new parameters are defaulted).

- [ ] **Step 1: Rewrite makeTextEngine's signature and `.builtIn` case**

In `LokalBot/Services/ProcessingPipeline.swift`, the current function begins:

```swift
    func makeTextEngine(_ config: AppSettings, server: LlamaServer = .shared) async throws -> TextEngine {
        switch config.summarizerBackend {
        case .builtIn:
            guard let entry = ModelCatalog.entry(id: config.builtInModelID,
                                                 custom: config.customBuiltInModels)
                    ?? ModelCatalog.entry(id: ModelCatalog.recommendedSummarizationID) else {
                throw PipelineError.badServerURL
            }
            guard let modelURL = ModelCatalog.localURL(for: entry, storage: storage) else {
                throw LlamaServer.ServerError.modelMissing(entry.displayName)
            }
            try await server.ensureRunning(modelAt: modelURL)
            return OpenAICompatibleEngine(
                baseURL: server.baseURL,
                model: entry.id,
                apiKey: nil,
                extraBody: entry.disablesThinking
                    ? ["chat_template_kwargs": ["enable_thinking": false]] : [:],
                displayNameOverride: "Built-in — \(entry.displayName)")
```

Replace that portion (signature through the end of the `.builtIn` case; the `.appleIntelligence`, `.ollama`, and `.openAICompatible` cases below it stay byte-identical):

```swift
    func makeTextEngine(_ config: AppSettings, server: LlamaServer = .shared,
                        priority: InferencePriority = .background,
                        purpose: String = "summary",
                        broker: InferenceBroker = .shared) async throws -> TextEngine {
        switch config.summarizerBackend {
        case .builtIn:
            guard let entry = ModelCatalog.entry(id: config.builtInModelID,
                                                 custom: config.customBuiltInModels)
                    ?? ModelCatalog.entry(id: ModelCatalog.recommendedSummarizationID) else {
                throw PipelineError.badServerURL
            }
            guard let modelURL = ModelCatalog.localURL(for: entry, storage: storage) else {
                throw LlamaServer.ServerError.modelMissing(entry.displayName)
            }
            let engine = OpenAICompatibleEngine(
                baseURL: server.baseURL,
                model: entry.id,
                apiKey: nil,
                extraBody: entry.disablesThinking
                    ? ["chat_template_kwargs": ["enable_thinking": false]] : [:],
                displayNameOverride: "Built-in — \(entry.displayName)")
            guard let role = InferenceRole(serverPort: server.port) else {
                // A LlamaServer outside the broker's three roles (never true
                // today) keeps the legacy boot-at-creation path.
                try await server.ensureRunning(modelAt: modelURL)
                return engine
            }
            // The server boots on the first generate call, under a lease that
            // pins it for the duration of each request.
            return LeasedTextEngine(base: engine, broker: broker, role: role,
                                    modelURL: modelURL, priority: priority,
                                    purpose: purpose)
```

- [ ] **Step 2: Label the day digest**

Same file, in `generateDayDigest(for:blocks:meetings:ocr:config:)` (~line 454). Current:

```swift
        let meetingLines = meetings.map { "Meeting: \($0.title) (\($0.durationLabel))" }
        let engine = try await makeTextEngine(config)
```

New:

```swift
        let meetingLines = meetings.map { "Meeting: \($0.title) (\($0.durationLabel))" }
        let engine = try await makeTextEngine(config, purpose: "day digest")
```

Leave `summarize` (~line 355) and `extractOutcomes` (~line 427) on the defaults — both are `.background`/"summary" (outcomes deliberately ride under the summary label; they run back-to-back on the same engine role). Leave `HeadlessCommands.runChat` untouched too: its `makeTextEngine(app.settings)` keeps the defaults, and its explicit `LlamaServer.*.stop()` calls before `exit()` must stay.

- [ ] **Step 3: Pass interactive priorities at the user-facing call sites**

**`LokalBot/LokalBotApp.swift`** — cotyping closure (~line 320). Current:

```swift
    private(set) lazy var cotypingEngine = CotypingEngineSelector(
        http: CotypingEngine(makeEngine: { [weak self] in
            guard let self else { throw TextEngineError.unavailable("LokalBot is shutting down.") }
            return try await self.pipeline.makeTextEngine(
                self.settings.cotypingTextEngineSettings,
                server: .cotyping)
        }),
```

New:

```swift
    private(set) lazy var cotypingEngine = CotypingEngineSelector(
        http: CotypingEngine(makeEngine: { [weak self] in
            guard let self else { throw TextEngineError.unavailable("LokalBot is shutting down.") }
            return try await self.pipeline.makeTextEngine(
                self.settings.cotypingTextEngineSettings,
                server: .cotyping,
                priority: .interactive,
                purpose: "cotyping")
        }),
```

**Same file** — chat closure (~line 356). Current:

```swift
    private(set) lazy var chat = ChatViewModel(
        makeEngine: { [weak self] in
            guard let self else { throw TextEngineError.unavailable("LokalBot is shutting down.") }
            return try await self.pipeline.makeTextEngine(self.settings)
        },
```

New:

```swift
    private(set) lazy var chat = ChatViewModel(
        makeEngine: { [weak self] in
            guard let self else { throw TextEngineError.unavailable("LokalBot is shutting down.") }
            return try await self.pipeline.makeTextEngine(self.settings,
                                                          priority: .interactive,
                                                          purpose: "chat")
        },
```

**`LokalBot/Views/ModelsView.swift`** — `testGeneration()` (~line 638). Current:

```swift
            let engine = try await app.pipeline.makeTextEngine(app.settings)
```

New:

```swift
            let engine = try await app.pipeline.makeTextEngine(app.settings,
                                                               priority: .interactive,
                                                               purpose: "model test")
```

- [ ] **Step 4: Build and run the full unit suite**

Run:
```bash
xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' test 2>&1 | tail -5
```
Expected: **TEST SUCCEEDED** — no existing test constructs a built-in engine against a live server inside the unit suite, so the boot-timing change is invisible here; what this run proves is that every call site still compiles and nothing else regressed.

- [ ] **Step 5: Commit**

```bash
git add LokalBot/Services/ProcessingPipeline.swift LokalBot/LokalBotApp.swift LokalBot/Views/ModelsView.swift
git commit -m "$(cat <<'EOF'
Route built-in text engines through the inference broker

makeTextEngine returns a LeasedTextEngine for the .builtIn backend:
the server boots on first request under a lease instead of at engine
creation, and chat/cotyping/model-test calls carry interactive
priority. External backends (Apple Intelligence, Ollama, custom
OpenAI-compatible) are untouched — they are not our servers.

Claude-Session: https://claude.ai/code/session_011BB4m5LTgHFUBH7odNkfRW
EOF
)"
```

---

### Task 6: EmbeddingIndex leases the embedder

The embedder is the load that most often evicts other models today (it wakes on every meeting index). Wrap each embedding batch in `withLease` so batches pin the embedder while running and it unloads ten minutes after indexing finishes.

**Files:**
- Modify: `LokalBot/Services/EmbeddingIndex.swift` (private `embed(_:prefix:storage:)`, ~line 179)

**Interfaces:**
- Consumes: `InferenceBroker.shared.withLease` (Task 3). No signature changes visible to callers.

- [ ] **Step 1: Wrap the batch in a lease**

Current function:

```swift
    private static func embed(_ texts: [String], prefix: String,
                              storage: StorageManager) async throws -> [[Float]] {
        let modelPath = try await ensureModel(storage: storage)
        try await LlamaServer.embedder.ensureRunning(modelAt: modelPath)

        var request = URLRequest(url: LlamaServer.embedder.baseURL
            .appendingPathComponent("embeddings"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "input": texts.map { prefix + $0 },
            "model": Self.modelID,
        ])
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = json["data"] as? [[String: Any]] else {
            throw TextEngineError.badResponse("unexpected /v1/embeddings payload")
        }
        return rows.compactMap { row -> [Float]? in
            guard let values = row["embedding"] as? [Double] else { return nil }
            let vector = values.map(Float.init)
            let norm = sqrt(vector.reduce(0) { $0 + $1 * $1 })
            return norm > 0 ? vector.map { $0 / norm } : vector
        }
    }
```

New — drop the bare `ensureRunning` (the lease's ensure replaces it) and run the whole HTTP exchange inside the lease so the embedder stays pinned for the batch:

```swift
    private static func embed(_ texts: [String], prefix: String,
                              storage: StorageManager) async throws -> [[Float]] {
        let modelPath = try await ensureModel(storage: storage)
        return try await InferenceBroker.shared.withLease(
            .embedder, model: modelPath, priority: .background,
            purpose: "embeddings") { () async throws -> [[Float]] in
            var request = URLRequest(url: LlamaServer.embedder.baseURL
                .appendingPathComponent("embeddings"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 120
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "input": texts.map { prefix + $0 },
                "model": Self.modelID,
            ])
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rows = json["data"] as? [[String: Any]] else {
                throw TextEngineError.badResponse("unexpected /v1/embeddings payload")
            }
            return rows.compactMap { row -> [Float]? in
                guard let values = row["embedding"] as? [Double] else { return nil }
                let vector = values.map(Float.init)
                let norm = sqrt(vector.reduce(0) { $0 + $1 * $1 })
                return norm > 0 ? vector.map { $0 / norm } : vector
            }
        }
    }
```

- [ ] **Step 2: Build and run the full unit suite**

Run:
```bash
xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' test 2>&1 | tail -5
```
Expected: **TEST SUCCEEDED**. (Embedding tests that hit a real server live in e2e, not the unit suite.)

- [ ] **Step 3: Commit**

```bash
git add LokalBot/Services/EmbeddingIndex.swift
git commit -m "$(cat <<'EOF'
Lease the embedder per embedding batch

Each batch pins the embedding server while it runs and releases it
after, so indexing can no longer be evicted mid-batch and the embedder
unloads after ten idle minutes instead of staying resident forever.

Claude-Session: https://claude.ai/code/session_011BB4m5LTgHFUBH7odNkfRW
EOF
)"
```

---

### Task 7: Agent Mode session lease

An Agent Mode conversation is minutes-long and interactive — exactly the "mid-request eviction" hole. The controller acquires one lease when it resolves a built-in endpoint and releases it on shutdown or any failure path, so the Main LLM stays pinned for the whole pi session.

No new unit test in this task, deliberately: `resolveEndpoint`'s `.builtIn` arm requires a real downloaded model file (`ModelCatalog.localURL` must resolve), which the unit suite doesn't have. The lease mechanics are proven by Task 3; the live path is covered by `LokalBot --agent "<prompt>"` in e2e. A fake test that stubs everything would only re-test the broker.

**Files:**
- Modify: `LokalBot/Agent/AgentSessionController.swift`

**Interfaces:**
- Consumes: `InferenceBroker.lease/.release` (Task 3), `InferenceLease` (Task 1).
- Produces: init gains `broker: InferenceBroker = .shared` (defaulted — `AgentSessionTabs` and the tests' `makeTransport` construction compile unchanged).

- [ ] **Step 1: Add the broker and the held lease**

Current init (~line 50):

```swift
    init(settings: @escaping () -> AppSettings,
         storage: StorageManager,
         runtimeRoot: URL = AgentRuntimeLayout.defaultRoot,
         sessionsDirectory: URL = AgentRuntimeLayout.sessionsDirectory,
         makeTransport: ((PiLaunchPlan) async throws -> PiLineTransport)? = nil) {
        self.settings = settings
        self.storage = storage
        self.runtimeRoot = runtimeRoot
        self.sessionsDirectory = sessionsDirectory
        self.makeTransport = makeTransport
        self.workspace = storage.rootURL
    }
```

New:

```swift
    init(settings: @escaping () -> AppSettings,
         storage: StorageManager,
         runtimeRoot: URL = AgentRuntimeLayout.defaultRoot,
         sessionsDirectory: URL = AgentRuntimeLayout.sessionsDirectory,
         broker: InferenceBroker = .shared,
         makeTransport: ((PiLaunchPlan) async throws -> PiLineTransport)? = nil) {
        self.settings = settings
        self.storage = storage
        self.runtimeRoot = runtimeRoot
        self.sessionsDirectory = sessionsDirectory
        self.broker = broker
        self.makeTransport = makeTransport
        self.workspace = storage.rootURL
    }
```

And next to the other stored properties (directly below `private var lifecycleGeneration = 0`), add:

```swift
    private let broker: InferenceBroker
    /// Held from resolveEndpoint (built-in engine only) until shutdown or
    /// failure, so the Main LLM cannot be evicted mid-conversation by an
    /// unrelated model load.
    private var llmLease: InferenceLease?
```

(The `broker` property is declared with the other `let`s near the top of the class; Swift doesn't care about ordering as long as init assigns it.)

- [ ] **Step 2: Acquire in resolveEndpoint**

Current `.builtIn` arm (~line 270):

```swift
        case .builtIn(let modelID):
            guard let entry = ModelCatalog.entry(id: modelID, custom: settings().customBuiltInModels)
                    ?? ModelCatalog.entry(id: modelID),
                  let modelURL = ModelCatalog.localURL(for: entry, storage: storage) else {
                throw StartError.modelConfiguration("The built-in model isn't downloaded yet. Download it under Settings → Models.")
            }
            try await LlamaServer.shared.ensureRunning(modelAt: modelURL)
            return AgentLLMEndpoint(baseURL: LlamaServer.shared.baseURL,
                                    model: entry.id,
                                    contextTokens: AgentLLMEndpoint.defaultContextTokens,
                                    apiKey: nil)
```

New:

```swift
        case .builtIn(let modelID):
            guard let entry = ModelCatalog.entry(id: modelID, custom: settings().customBuiltInModels)
                    ?? ModelCatalog.entry(id: modelID),
                  let modelURL = ModelCatalog.localURL(for: entry, storage: storage) else {
                throw StartError.modelConfiguration("The built-in model isn't downloaded yet. Download it under Settings → Models.")
            }
            releaseLLMLease()
            llmLease = try await broker.lease(.mainLLM, model: modelURL,
                                              priority: .interactive,
                                              purpose: "agent session")
            return AgentLLMEndpoint(baseURL: LlamaServer.shared.baseURL,
                                    model: entry.id,
                                    contextTokens: AgentLLMEndpoint.defaultContextTokens,
                                    apiKey: nil)
```

(`releaseLLMLease()` first handles the restart-after-failure case, where a previous session's lease may still be held.)

- [ ] **Step 3: Release on every exit path**

Add the helper near the other private helpers (e.g. below `discardPendingTextDelta()`):

```swift
    /// Fire-and-forget so the synchronous failure paths can call it; the
    /// broker serializes the release internally.
    private func releaseLLMLease() {
        guard let lease = llmLease else { return }
        llmLease = nil
        let broker = self.broker
        Task { await broker.release(lease) }
    }
```

Then insert one call in each of the four exit paths:

**`shutdown()`** — current:

```swift
    func shutdown() async {
        lifecycleGeneration += 1
        eventTask?.cancel()
        eventTask = nil
        discardPendingTextDelta()
        await process?.stop()
        process = nil
        client = nil
        state = .idle
    }
```

New:

```swift
    func shutdown() async {
        lifecycleGeneration += 1
        eventTask?.cancel()
        eventTask = nil
        discardPendingTextDelta()
        await process?.stop()
        process = nil
        client = nil
        releaseLLMLease()
        state = .idle
    }
```

**`handleStreamEnd()`** — current tail:

```swift
        folder.appendNotice(detail, isError: true)
        publish()
        state = .failed(detail)
        recoveryAction = .restart
```

New tail:

```swift
        folder.appendNotice(detail, isError: true)
        publish()
        releaseLLMLease()
        state = .failed(detail)
        recoveryAction = .restart
```

**`fail(with:)`** — current:

```swift
    private func fail(with error: Error) {
        flushPendingTextDelta()
        let message = Self.message(for: error)
        folder.appendNotice(message, isError: true)
        publish()
        state = .failed(message)
        recoveryAction = .restart
    }
```

New:

```swift
    private func fail(with error: Error) {
        flushPendingTextDelta()
        let message = Self.message(for: error)
        folder.appendNotice(message, isError: true)
        publish()
        releaseLLMLease()
        state = .failed(message)
        recoveryAction = .restart
    }
```

**`setFailure(_:)`** — current:

```swift
    private func setFailure(_ error: Error) {
        state = .failed(Self.message(for: error))
        if case StartError.modelConfiguration = error {
            recoveryAction = .openModels
        } else {
            recoveryAction = .restart
        }
    }
```

New:

```swift
    private func setFailure(_ error: Error) {
        releaseLLMLease()
        state = .failed(Self.message(for: error))
        if case StartError.modelConfiguration = error {
            recoveryAction = .openModels
        } else {
            recoveryAction = .restart
        }
    }
```

- [ ] **Step 4: Build and run the full unit suite**

Run:
```bash
xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' test 2>&1 | tail -5
```
Expected: **TEST SUCCEEDED** — the existing Agent tests (which inject `makeTransport` and use external-endpoint settings, so they never enter the `.builtIn` arm) pass unchanged.

- [ ] **Step 5: Commit**

```bash
git add LokalBot/Agent/AgentSessionController.swift
git commit -m "$(cat <<'EOF'
Hold a session lease for Agent Mode's built-in LLM

The controller leases the Main LLM from resolveEndpoint until
shutdown or failure, so a pi conversation can't have its model
evicted mid-session by an unrelated load.

Claude-Session: https://claude.ai/code/session_011BB4m5LTgHFUBH7odNkfRW
EOF
)"
```

---

### Task 8: ask_library TTL lease (AgentAccessManager)

Today every `ask_library` wake calls `LlamaServer.shared.ensureRunning` and never stops it — an external MCP client leaves a multi-GB model resident forever. Restructure the wake path: resolve the model (pure, static), then hold a **TTL lease** (600 s). Each wake acquires a fresh lease *then* releases the previous one (never dropping to zero leases, so no linger churn); re-acquiring instead of renewing means `ensure` runs every wake, reviving a crashed server. Disabling the Privacy toggle releases the lease.

> **Reconciliation note:** `AgentAccessManager.swift` and `AgentAccessManagerTests.swift` landed on the `agent-access` branch and may have moved since this plan was written (2026-07-11). Diff the "Current" blocks below against the real files before editing; if they've drifted, apply the same transformation to the current shape. The three user-facing failure strings must survive verbatim — the CLI relays them to external agents.

**Files:**
- Modify: `LokalBot/Services/AgentAccessManager.swift`
- Test: `LokalBotTests/AgentAccessManagerTests.swift` (extend the `makeManager` helper, append 2 tests; the existing 5 tests must keep passing unchanged)

**Interfaces:**
- Consumes: `InferenceBroker.lease/.release/.activeLeaseCount` (Task 3), `InferenceLease` (Task 1).
- Produces:
  - init gains `broker: InferenceBroker = .shared` (after `startEngine`); `startEngine` becomes a stored *optional* `((AppSettings, StorageManager) async -> String?)?` with no wrapping default (the old `?? { await Self.startMainLLM(...) }` default can't capture the new `broker` property from init — the fallback moves into the wake handler).
  - `static func resolveBuiltInModelURL(settings:storage:) -> ResolvedBuiltInModel` (`enum ResolvedBuiltInModel: Equatable { case model(URL); case failure(String) }`) replaces `static startMainLLM`.
  - `func wakeMainLLM(settings:storage:) async -> String?` and `func acquireOrRenewAgentLease(modelURL: URL) async -> String?` (internal, so tests reach them).
  - `static let agentLeaseTTL: TimeInterval = 600`.

- [ ] **Step 1: Write the failing tests**

In `LokalBotTests/AgentAccessManagerTests.swift`, replace the existing helper:

```swift
    private func makeManager(
        startEngine: @escaping (AppSettings, StorageManager) async -> String? = { _, _ in nil }
    ) -> AgentAccessManager {
        AgentAccessManager(
            storage: StorageManager(),
            settings: { AppSettings() },
            gate: gate,
            startEngine: startEngine)
    }
```

with:

```swift
    private func makeManager(
        startEngine: ((AppSettings, StorageManager) async -> String?)? = { _, _ in nil },
        broker: InferenceBroker = .shared
    ) -> AgentAccessManager {
        AgentAccessManager(
            storage: StorageManager(),
            settings: { AppSettings() },
            gate: gate,
            startEngine: startEngine,
            broker: broker)
    }
```

(The default stays a non-nil closure, so the five existing tests keep injecting a stub and never touch the broker.)

Then append inside the class:

```swift
    // MARK: - Wake lease

    private actor BrokerHookRecorder {
        private(set) var events: [String] = []
        func record(_ event: String) { events.append(event) }
        func count(of event: String) -> Int { events.filter { $0 == event }.count }
    }

    private func makeFakeBroker(recorder: BrokerHookRecorder) -> InferenceBroker {
        var hooks: [InferenceRole: InferenceBroker.RuntimeHooks] = [:]
        for role in InferenceRole.allCases {
            hooks[role] = InferenceBroker.RuntimeHooks(
                ensure: { _ in await recorder.record("ensure:\(role.rawValue)") },
                stop: { await recorder.record("stop:\(role.rawValue)") })
        }
        return InferenceBroker(hooks: hooks, leaseStateSink: { _, _ in })
    }

    func testWakeLeaseEnsuresEveryTimeButNeverStacks() async {
        let recorder = BrokerHookRecorder()
        let broker = makeFakeBroker(recorder: recorder)
        let manager = makeManager(startEngine: nil, broker: broker)
        let modelURL = root.appendingPathComponent("fake-model.gguf")

        let first = await manager.acquireOrRenewAgentLease(modelURL: modelURL)
        XCTAssertNil(first)
        let second = await manager.acquireOrRenewAgentLease(modelURL: modelURL)
        XCTAssertNil(second)

        let ensures = await recorder.count(of: "ensure:mainLLM")
        XCTAssertEqual(ensures, 2, "every wake re-ensures, reviving a crashed server")
        let active = await broker.activeLeaseCount(.mainLLM)
        XCTAssertEqual(active, 1, "each wake replaces the previous lease; they never stack")
    }

    func testDisableReleasesTheAgentLease() async throws {
        let recorder = BrokerHookRecorder()
        let broker = makeFakeBroker(recorder: recorder)
        let manager = makeManager(startEngine: nil, broker: broker)
        let modelURL = root.appendingPathComponent("fake-model.gguf")

        manager.setEnabled(true)
        _ = await manager.acquireOrRenewAgentLease(modelURL: modelURL)
        var active = await broker.activeLeaseCount(.mainLLM)
        XCTAssertEqual(active, 1)

        manager.setEnabled(false)
        // releaseAgentLease is fire-and-forget from the MainActor; poll briefly.
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            active = await broker.activeLeaseCount(.mainLLM)
            if active == 0 { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertEqual(active, 0, "disabling agent access must release the wake lease")
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:
```bash
xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' test -only-testing:LokalBotTests/AgentAccessManagerTests 2>&1 | tail -5
```
Expected: **TEST FAILED** — build error, `extra argument 'broker' in call` and `value of type 'AgentAccessManager' has no member 'acquireOrRenewAgentLease'`.

- [ ] **Step 3: Restructure the manager**

In `LokalBot/Services/AgentAccessManager.swift`:

**Edit 1 — stored properties and init.** Current:

```swift
    private let gate: AgentAccessGate
    private let storage: StorageManager
    private let settings: () -> AppSettings
    private let startEngine: (AppSettings, StorageManager) async -> String?

    private var watcher: DispatchSourceFileSystemObject?
    private var handlingWake = false

    init(
        storage: StorageManager,
        settings: @escaping () -> AppSettings,
        gate: AgentAccessGate = AgentAccessGate(),
        startEngine: ((AppSettings, StorageManager) async -> String?)? = nil
    ) {
        self.storage = storage
        self.settings = settings
        self.gate = gate
        self.startEngine = startEngine ?? {
            await Self.startMainLLM(settings: $0, storage: $1)
        }
    }
```

New:

```swift
    private let gate: AgentAccessGate
    private let storage: StorageManager
    private let settings: () -> AppSettings
    /// Test seam. When nil (production), wakes go through `wakeMainLLM`,
    /// which holds a TTL lease on the broker.
    private let startEngine: ((AppSettings, StorageManager) async -> String?)?
    private let broker: InferenceBroker
    /// The lease behind the most recent ask_library wake. Replaced (not
    /// stacked) on every wake; released on disable; expires on its own TTL.
    private var agentLease: InferenceLease?

    /// One external question rarely comes alone: the TTL keeps the model
    /// warm for follow-ups, then returns the RAM ten minutes after the last.
    static let agentLeaseTTL: TimeInterval = 600

    private var watcher: DispatchSourceFileSystemObject?
    private var handlingWake = false

    init(
        storage: StorageManager,
        settings: @escaping () -> AppSettings,
        gate: AgentAccessGate = AgentAccessGate(),
        startEngine: ((AppSettings, StorageManager) async -> String?)? = nil,
        broker: InferenceBroker = .shared
    ) {
        self.storage = storage
        self.settings = settings
        self.gate = gate
        self.startEngine = startEngine
        self.broker = broker
    }
```

**Edit 2 — release on disable.** In `setEnabled(_:)`, current `else` branch:

```swift
        } else {
            stopWatcher()
            gate.disable()
            isEnabled = false
        }
```

New:

```swift
        } else {
            stopWatcher()
            gate.disable()
            isEnabled = false
            releaseAgentLease()
        }
```

**Edit 3 — wake handler fallback.** Current:

```swift
    private func handleControlDirectoryChange() {
        guard !handlingWake, gate.consumeWake() else { return }
        handlingWake = true
        Task { @MainActor in
            if let failure = await startEngine(settings(), storage) {
                gate.writeWakeError(failure)
            } else {
                gate.clearWakeError()
            }
            handlingWake = false
            handleControlDirectoryChange()
        }
    }
```

New:

```swift
    private func handleControlDirectoryChange() {
        guard !handlingWake, gate.consumeWake() else { return }
        handlingWake = true
        Task { @MainActor in
            let failure: String?
            if let startEngine {
                failure = await startEngine(settings(), storage)
            } else {
                failure = await wakeMainLLM(settings: settings(), storage: storage)
            }
            if let failure {
                gate.writeWakeError(failure)
            } else {
                gate.clearWakeError()
            }
            handlingWake = false
            handleControlDirectoryChange()
        }
    }
```

**Edit 4 — replace `static startMainLLM` entirely.** Current:

```swift
    static func startMainLLM(
        settings: AppSettings,
        storage: StorageManager
    ) async -> String? {
        switch AgentLLMEndpointResolver.resolve(settings: settings) {
        case .builtIn(let modelID):
            guard let entry = ModelCatalog.entry(
                id: modelID,
                custom: settings.customBuiltInModels)
                ?? ModelCatalog.entry(id: modelID),
                let modelURL = ModelCatalog.localURL(for: entry, storage: storage) else {
                return "The built-in model isn't downloaded. Open LokalBot → Settings → Models and download it, then ask again."
            }
            do {
                try await LlamaServer.shared.ensureRunning(modelAt: modelURL)
                return nil
            } catch {
                return "LokalBot's model server failed to start: \(error.localizedDescription)"
            }
        case .ready:
            return "The Main LLM is set to an external server; ask_library answers with LokalBot's built-in engine. Pick a built-in model in LokalBot → Settings → Models."
        case .unsupported(let reason):
            return reason
        }
    }
```

New:

```swift
    enum ResolvedBuiltInModel: Equatable {
        case model(URL)
        case failure(String)
    }

    /// Pure resolution half of the wake path. The failure strings are the
    /// exact messages the CLI relays to external agents — keep them verbatim.
    static func resolveBuiltInModelURL(
        settings: AppSettings,
        storage: StorageManager
    ) -> ResolvedBuiltInModel {
        switch AgentLLMEndpointResolver.resolve(settings: settings) {
        case .builtIn(let modelID):
            guard let entry = ModelCatalog.entry(
                id: modelID,
                custom: settings.customBuiltInModels)
                ?? ModelCatalog.entry(id: modelID),
                let modelURL = ModelCatalog.localURL(for: entry, storage: storage) else {
                return .failure("The built-in model isn't downloaded. Open LokalBot → Settings → Models and download it, then ask again.")
            }
            return .model(modelURL)
        case .ready:
            return .failure("The Main LLM is set to an external server; ask_library answers with LokalBot's built-in engine. Pick a built-in model in LokalBot → Settings → Models.")
        case .unsupported(let reason):
            return .failure(reason)
        }
    }

    /// Default wake handler: resolve the built-in model, then hold a TTL
    /// lease on the Main LLM.
    func wakeMainLLM(settings: AppSettings, storage: StorageManager) async -> String? {
        switch Self.resolveBuiltInModelURL(settings: settings, storage: storage) {
        case .failure(let reason):
            return reason
        case .model(let modelURL):
            return await acquireOrRenewAgentLease(modelURL: modelURL)
        }
    }

    /// Acquires a fresh TTL lease, then releases the previous one — in that
    /// order, so the lease count never dips to zero and starts a linger.
    /// Re-acquiring instead of renewing means the broker's ensure runs on
    /// every wake: a llama-server that crashed since the last question is
    /// revived instead of trusted.
    func acquireOrRenewAgentLease(modelURL: URL) async -> String? {
        do {
            let fresh = try await broker.lease(.mainLLM, model: modelURL,
                                               priority: .agent,
                                               purpose: "ask_library",
                                               expiresAfter: Self.agentLeaseTTL)
            if let previous = agentLease {
                await broker.release(previous)
            }
            agentLease = fresh
            return nil
        } catch {
            return "LokalBot's model server failed to start: \(error.localizedDescription)"
        }
    }

    private func releaseAgentLease() {
        guard let lease = agentLease else { return }
        agentLease = nil
        let broker = self.broker
        Task { await broker.release(lease) }
    }
```

- [ ] **Step 4: Check for other startMainLLM references**

Run:
```bash
grep -rn "startMainLLM" LokalBot/ LokalBotTests/ CLI/ || echo "no references left"
```
Expected: `no references left`. If anything else calls `AgentAccessManager.startMainLLM` (possible if agent-access moved after 2026-07-11), point it at `wakeMainLLM` on a manager instance, or at `resolveBuiltInModelURL` if it only needs resolution.

- [ ] **Step 5: Run the tests to verify all 7 pass**

Run:
```bash
xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' test -only-testing:LokalBotTests/AgentAccessManagerTests 2>&1 | tail -5
```
Expected: **TEST SUCCEEDED** — the five pre-existing tests (which inject `startEngine`) plus the two new lease tests.

- [ ] **Step 6: Commit**

```bash
git add LokalBot/Services/AgentAccessManager.swift LokalBotTests/AgentAccessManagerTests.swift
git commit -m "$(cat <<'EOF'
Hold a TTL lease for ask_library wakes

Each external wake acquires a fresh 600 s lease on the Main LLM and
releases the previous one, so a crashed server is revived per wake,
questions in a burst share one warm model, and the RAM returns ten
minutes after the last question instead of never. Disabling the
Privacy toggle releases the lease immediately.

Claude-Session: https://claude.ai/code/session_011BB4m5LTgHFUBH7odNkfRW
EOF
)"
```

---

### Task 9: Dashboard lease notes

The Settings → Advanced resource monitor already lists resident models. Add a third caption line — `in use — chat (interactive)` — driven by the pin/description state Task 2 published. Only GGUF (residency-ledger) rows carry notes; `ModelRuntimeRegistry` rows (CoreML/MLX/ONNX) are not broker-managed and stay nil. The other new visible behavior needs no code here: when a linger unload fires, `LlamaServer.stop()` unregisters the row and it simply disappears.

**Files:**
- Modify: `LokalBot/Views/ResourceMonitorSection.swift`
- Test: `LokalBotTests/ResourceMonitorPresentationTests.swift` (**create** — no presentation tests exist yet)

**Interfaces:**
- Consumes: `ModelResidency.pinnedIDs` / `.leaseDescriptions` (Task 2).
- Produces: `ResourceMonitorPresentation.Model` gains `let leaseNote: String?`; `models(...)` gains `pinnedIDs: Set<String> = []`, `leaseDescriptions: [String: [String]] = [:]` (defaulted).

- [ ] **Step 1: Write the failing tests**

Create `LokalBotTests/ResourceMonitorPresentationTests.swift`:

```swift
import XCTest
@testable import LokalBot

final class ResourceMonitorPresentationTests: XCTestCase {

    private func resident(_ id: String, label: String) -> ModelResidency.Resident {
        ModelResidency.Resident(id: id, label: label, bytes: 1_073_741_824,
                                processIdentifier: nil, processStartTime: nil,
                                lastUsed: Date(timeIntervalSince1970: 1_000_000))
    }

    func testLeasedModelRowCarriesInUseNote() {
        let models = ResourceMonitorPresentation.models(
            residency: [resident("llama-server:17872", label: "Qwen 4B")],
            runtimes: [],
            snapshot: nil,
            pinnedIDs: ["llama-server:17872"],
            leaseDescriptions: ["llama-server:17872":
                ["chat (interactive)", "summary (background)"]])
        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(models[0].leaseNote,
                       "in use — chat (interactive), summary (background)")
    }

    func testUnleasedModelRowHasNoNote() {
        let models = ResourceMonitorPresentation.models(
            residency: [resident("llama-server:17873", label: "EmbeddingGemma")],
            runtimes: [],
            snapshot: nil,
            pinnedIDs: [],
            leaseDescriptions: [:])
        XCTAssertEqual(models.count, 1)
        XCTAssertNil(models[0].leaseNote)
    }

    func testPinWithoutDescriptionsStillReadsInUse() {
        let models = ResourceMonitorPresentation.models(
            residency: [resident("llama-server:17872", label: "Qwen 4B")],
            runtimes: [],
            snapshot: nil,
            pinnedIDs: ["llama-server:17872"],
            leaseDescriptions: [:])
        XCTAssertEqual(models[0].leaseNote, "in use")
    }
}
```

(With `processIdentifier: nil` and `snapshot: nil` the stale-PID filter is bypassed, so the rows always survive into the result — these tests are purely about the note.)

- [ ] **Step 2: Regenerate the project and run the tests to verify they fail**

Run:
```bash
xcodegen generate
xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' test -only-testing:LokalBotTests/ResourceMonitorPresentationTests 2>&1 | tail -5
```
Expected: **TEST FAILED** — build error, `extra argument 'pinnedIDs' in call`.

- [ ] **Step 3: Implement the presentation + view changes**

In `LokalBot/Views/ResourceMonitorSection.swift`, four edits.

**Edit 1 — the `Model` struct** (inside `enum ResourceMonitorPresentation`). Current:

```swift
    struct Model: Identifiable, Equatable {
        let id: String
        let role: String
        let label: String
        let estimatedBytes: UInt64?
        let processIdentifier: pid_t?
        let processStartTime: UInt64?
    }
```

New:

```swift
    struct Model: Identifiable, Equatable {
        let id: String
        let role: String
        let label: String
        let estimatedBytes: UInt64?
        let processIdentifier: pid_t?
        let processStartTime: UInt64?
        /// "in use — chat (interactive)" while the broker holds leases on this
        /// row; nil when idle. Only GGUF (residency) rows carry notes.
        let leaseNote: String?
    }
```

**Edit 2 — `models(...)`**. Replace the whole function with:

```swift
    static func models(residency: [ModelResidency.Resident],
                       runtimes: [ModelRuntimeRegistry.Resident],
                       snapshot: SystemResourceSampler.UsageSnapshot?,
                       pinnedIDs: Set<String> = [],
                       leaseDescriptions: [String: [String]] = [:]) -> [Model] {
        let ggufModels = residency.compactMap { resident -> Model? in
            if let processIdentifier = resident.processIdentifier,
               let snapshot {
                guard let usage = snapshot.usage(for: processIdentifier),
                      let expectedStartTime = resident.processStartTime,
                      usage.startTime == expectedStartTime else { return nil }
            }
            return Model(
                id: resident.id,
                role: role(for: resident.id),
                label: resident.label,
                estimatedBytes: resident.bytes > 0 ? UInt64(resident.bytes) : nil,
                processIdentifier: resident.processIdentifier,
                processStartTime: resident.processStartTime,
                leaseNote: leaseNote(for: resident.id, pinnedIDs: pinnedIDs,
                                     leaseDescriptions: leaseDescriptions)
            )
        }
        let otherModels = runtimes.compactMap { runtime -> Model? in
            if let processIdentifier = runtime.processIdentifier,
               let snapshot {
                guard let usage = snapshot.usage(for: processIdentifier),
                      let expectedStartTime = runtime.processStartTime,
                      usage.startTime == expectedStartTime else { return nil }
            }
            return Model(
                id: runtime.id,
                role: runtime.role,
                label: runtime.label,
                estimatedBytes: runtime.estimatedBytes,
                processIdentifier: runtime.processIdentifier,
                processStartTime: runtime.processStartTime,
                leaseNote: nil
            )
        }
        return (ggufModels + otherModels).sorted {
            if $0.role != $1.role {
                return $0.role.localizedCaseInsensitiveCompare($1.role) == .orderedAscending
            }
            return $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
        }
    }

    private static func leaseNote(for id: String, pinnedIDs: Set<String>,
                                  leaseDescriptions: [String: [String]]) -> String? {
        guard pinnedIDs.contains(id) else { return nil }
        let purposes = leaseDescriptions[id] ?? []
        return purposes.isEmpty ? "in use" : "in use — " + purposes.joined(separator: ", ")
    }
```

**Edit 3 — the view's `loadedModels`**. Current:

```swift
    private var loadedModels: [ResourceMonitorPresentation.Model] {
        ResourceMonitorPresentation.models(
            residency: residency.residents,
            runtimes: modelRuntimes.residents,
            snapshot: monitor.snapshot
        )
    }
```

New:

```swift
    private var loadedModels: [ResourceMonitorPresentation.Model] {
        ResourceMonitorPresentation.models(
            residency: residency.residents,
            runtimes: modelRuntimes.residents,
            snapshot: monitor.snapshot,
            pinnedIDs: residency.pinnedIDs,
            leaseDescriptions: residency.leaseDescriptions
        )
    }
```

**Edit 4 — `modelRow(_:)` label**. Current `VStack`:

```swift
            VStack(alignment: .leading, spacing: 1) {
                Text(model.role)
                Text(model.label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(model.label)
            }
```

New:

```swift
            VStack(alignment: .leading, spacing: 1) {
                Text(model.role)
                Text(model.label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(model.label)
                if let note = model.leaseNote {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
```

- [ ] **Step 4: Confirm no other Model constructor exists**

Adding a stored property changes the memberwise init; both construction sites were updated in Edit 2. Run:
```bash
grep -rn "ResourceMonitorPresentation.Model(" LokalBot/ LokalBotTests/ LokalBotUITests/
```
Expected: only the two calls inside `models(...)` (plus any in the new test file's future edits). If another site appears (the tree may have moved), add `leaseNote: nil` there.

- [ ] **Step 5: Run the tests to verify they pass**

Run:
```bash
xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' test -only-testing:LokalBotTests/ResourceMonitorPresentationTests 2>&1 | tail -5
```
Expected: **TEST SUCCEEDED**, 3 tests passing.

- [ ] **Step 6: Commit**

```bash
git add LokalBot/Views/ResourceMonitorSection.swift LokalBotTests/ResourceMonitorPresentationTests.swift LokalBot.xcodeproj
git commit -m "$(cat <<'EOF'
Show lease notes in the resource monitor

Resident model rows read "in use — chat (interactive)" while the
broker holds leases on them, and idle rows disappear on their own when
the linger unload fires.

Claude-Session: https://claude.ai/code/session_011BB4m5LTgHFUBH7odNkfRW
EOF
)"
```

---

### Task 10: Document the broker + full verification

**Files:**
- Modify: `CLAUDE.md` (Architecture section)

**Interfaces:** none — documentation and verification only.

- [ ] **Step 1: Add the architecture paragraph**

In `CLAUDE.md`, in the `## Architecture` section, insert a new paragraph directly after the "Meeting pipeline: …" paragraph (before the on-disk-library block). Note: the agent-access branch also edits `CLAUDE.md`, so anchor on the Architecture section as it exists, not on line numbers:

```markdown
The three shared llama-servers (main 17872, embeddings 17873, cotyping 17874) are lifecycle-managed by `InferenceBroker` (`LokalBot/Engines/InferenceBroker.swift`): consumers take per-request leases (which pin the model against `ModelResidency` eviction) instead of calling `ensureRunning` directly, and a server with no leases unloads after a linger. Agent Mode holds a session lease; external `ask_library` wakes hold a 600 s TTL lease. Granite's private ASR server and the in-process cotyping runtime stay outside the broker (step 2).
```

- [ ] **Step 2: Full unit suite + Dev build**

Run:
```bash
xcodegen generate
xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' test 2>&1 | tail -5
xcodebuild -project LokalBot.xcodeproj -scheme 'LokalBot Dev' -destination 'platform=macOS' build 2>&1 | tail -3
```
Expected: **TEST SUCCEEDED** and **BUILD SUCCEEDED**.

- [ ] **Step 3: Live proof (optional but recommended if models are downloaded)**

Run:
```bash
Scripts/build/install-app.sh && Scripts/test/e2e.sh
```
Expected: the e2e suite passes end-to-end (summarize/chat/digest/ask_library all run through the leased path against a real llama-server). Steps that need missing models or TCC grants skip rather than fail — that is the harness's normal posture. If no model is downloaded locally, note the skip in the PR description instead of blocking.

A manual smoke worth 60 seconds if running the Dev app anyway: open Settings → Advanced while a meeting summary runs — the Main LLM row should show "in use — summary (background)" and, ten idle minutes later, the row (and its RAM) should be gone.

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md
git commit -m "$(cat <<'EOF'
Document the inference broker in CLAUDE.md

Claude-Session: https://claude.ai/code/session_011BB4m5LTgHFUBH7odNkfRW
EOF
)"
```

---

## Done

All ten tasks complete means: every consumer of the three shared llama-servers goes through leases, `ModelResidency` never evicts a model mid-request, idle servers return their RAM within minutes, `ask_library` can no longer leak a resident model, and the resource monitor shows who is using what. Open a PR from `inference-broker` into `agent-access` (or `master`, if agent-access has merged) titled "Inference broker step 1: leases + idle unload", body referencing `Docs/superpowers/specs/2026-07-11-inference-broker-design.md`, ending with:

```
https://claude.ai/code/session_011BB4m5LTgHFUBH7odNkfRW
```
