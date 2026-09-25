import XCTest
@testable import LokalBot

/// The model-memory governor: pure LRU eviction policy, and the ledger's
/// register/touch/evict behavior with recorded unload hooks.
@MainActor
final class ModelResidencyTests: XCTestCase {

    private func entry(_ id: String, gb: Int64, age: TimeInterval) -> ModelResidencyPolicy.Entry {
        .init(id: id, bytes: gb * 1_073_741_824,
              lastUsed: Date(timeIntervalSince1970: 1_000_000 - age))
    }

    // MARK: - Policy

    func testNoEvictionWhenEverythingFits() {
        let victims = ModelResidencyPolicy.evictions(
            residents: [entry("a", gb: 4, age: 100)],
            incomingID: "b", incomingBytes: 4 * 1_073_741_824,
            budgetBytes: 8 * 1_073_741_824)
        XCTAssertTrue(victims.isEmpty)
    }

    func testEvictsLeastRecentlyUsedFirstUntilItFits() {
        let victims = ModelResidencyPolicy.evictions(
            residents: [entry("newest", gb: 3, age: 10),
                        entry("oldest", gb: 6, age: 300),
                        entry("middle", gb: 2, age: 100)],
            incomingID: "incoming", incomingBytes: 5 * 1_073_741_824,
            budgetBytes: 10 * 1_073_741_824)
        // 3+6+2+5 = 16 GB against 10: dropping "oldest" (6) reaches 10 exactly.
        XCTAssertEqual(victims, ["oldest"])
    }

    func testEvictsSeveralWhenOneIsNotEnough() {
        let victims = ModelResidencyPolicy.evictions(
            residents: [entry("old", gb: 2, age: 300), entry("mid", gb: 2, age: 200),
                        entry("new", gb: 2, age: 10)],
            incomingID: "incoming", incomingBytes: 7 * 1_073_741_824,
            budgetBytes: 9 * 1_073_741_824)
        XCTAssertEqual(victims, ["old", "mid"])
    }

    func testIncomingIDIsNeverAVictim() {
        // A model swap on the same runtime replaces in place: its old row must
        // not be evicted (the runtime restart handles the old weights).
        let victims = ModelResidencyPolicy.evictions(
            residents: [entry("server", gb: 8, age: 300), entry("other", gb: 4, age: 10)],
            incomingID: "server", incomingBytes: 9 * 1_073_741_824,
            budgetBytes: 12 * 1_073_741_824)
        XCTAssertEqual(victims, ["other"])
    }

    func testOversizedIncomingEvictsEverythingElseAndStillLoads() {
        let victims = ModelResidencyPolicy.evictions(
            residents: [entry("a", gb: 2, age: 100), entry("b", gb: 2, age: 200)],
            incomingID: "huge", incomingBytes: 64 * 1_073_741_824,
            budgetBytes: 16 * 1_073_741_824)
        XCTAssertEqual(Set(victims), ["a", "b"])
    }

    func testNonEvictableRuntimeReservationsReduceAvailableBudget() {
        let victims = ModelResidencyPolicy.evictions(
            residents: [entry("old", gb: 3, age: 100), entry("new", gb: 2, age: 10)],
            incomingID: "incoming", incomingBytes: 2 * 1_073_741_824,
            reservedBytes: 4 * 1_073_741_824,
            budgetBytes: 8 * 1_073_741_824)
        XCTAssertEqual(victims, ["old"])
    }

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

    // MARK: - Ledger

    func testRegisterUpsertsTouchAndUnregister() {
        let residency = ModelResidency(budgetBytes: .max)
        residency.register(id: "a", label: "model-a", bytes: 100,
                           processIdentifier: 123, processStartTime: 456, unload: {})
        residency.register(id: "b", label: "model-b", bytes: 50, unload: {})
        XCTAssertEqual(residency.totalBytes, 150)
        XCTAssertEqual(residency.residents.first { $0.id == "a" }?.processIdentifier, 123)
        XCTAssertEqual(residency.residents.first { $0.id == "a" }?.processStartTime, 456)

        residency.register(id: "a", label: "model-a2", bytes: 70, unload: {})
        XCTAssertEqual(residency.residents.count, 2)
        XCTAssertEqual(residency.totalBytes, 120)
        XCTAssertEqual(residency.residents.first { $0.id == "a" }?.label, "model-a2")
        XCTAssertNil(residency.residents.first { $0.id == "a" }?.processIdentifier)
        XCTAssertNil(residency.residents.first { $0.id == "a" }?.processStartTime)

        let before = residency.residents.first { $0.id == "b" }!.lastUsed
        residency.touch(id: "b")
        XCTAssertGreaterThanOrEqual(residency.residents.first { $0.id == "b" }!.lastUsed, before)

        residency.unregister(id: "a")
        XCTAssertEqual(residency.residents.map(\.id), ["b"])
    }

    func testWillLoadRunsUnloadHooksForVictimsOnly() async {
        final class Unloads { var ids: [String] = [] }
        let unloads = Unloads()
        let residency = ModelResidency(budgetBytes: 10)
        residency.register(id: "old", label: "old", bytes: 6) { unloads.ids.append("old") }
        residency.register(id: "new", label: "new", bytes: 3) { unloads.ids.append("new") }
        residency.touch(id: "new")

        await residency.willLoad(id: "incoming", bytes: 5)
        XCTAssertEqual(unloads.ids, ["old"])
        XCTAssertEqual(residency.residents.map(\.id), ["new"])

        // The incoming runtime registers itself after its load completes.
        residency.register(id: "incoming", label: "incoming", bytes: 5, unload: {})
        XCTAssertEqual(residency.totalBytes, 8)
    }

    func testWillLoadHonorsPublishedPins() async {
        let residency = ModelResidency(budgetBytes: 8 * 1_073_741_824)
        final class Unloads { var ids: [String] = [] }
        let unloads = Unloads()
        residency.register(id: "pinned-old", label: "Pinned", bytes: 4 * 1_073_741_824,
                           unload: { unloads.ids.append("pinned-old") })
        residency.register(id: "idle-new", label: "Idle", bytes: 4 * 1_073_741_824,
                           unload: { unloads.ids.append("idle-new") })
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

    func testStaleGenerationCannotUnregisterReplacement() {
        let residency = ModelResidency(budgetBytes: .max)
        let oldGeneration = UUID()
        let replacementGeneration = UUID()
        residency.register(id: "server", label: "old", bytes: 100,
                           generation: oldGeneration, unload: {})
        residency.register(id: "server", label: "replacement", bytes: 200,
                           generation: replacementGeneration, unload: {})

        residency.unregister(id: "server", ifGenerationMatches: oldGeneration)
        XCTAssertEqual(residency.residents.map(\.label), ["replacement"])

        residency.unregister(id: "server", ifGenerationMatches: replacementGeneration)
        XCTAssertTrue(residency.residents.isEmpty)
    }

    func testPendingLoadsReserveBudgetUntilCancelledOrRegistered() async {
        let residency = ModelResidency(budgetBytes: 10)
        final class Unloads { var ids: [String] = [] }
        let unloads = Unloads()
        residency.register(id: "old", label: "Old", bytes: 4) {
            unloads.ids.append("old")
        }

        let first = await residency.willLoad(id: "first", bytes: 4)
        XCTAssertEqual(residency.pendingLoadBytes, 4)
        _ = await residency.willLoad(id: "second", bytes: 4)
        XCTAssertEqual(unloads.ids, ["old"], "the second admission must count the first pending load")
        XCTAssertEqual(residency.pendingLoadBytes, 8)

        residency.cancelLoad(first)
        XCTAssertEqual(residency.pendingLoadBytes, 4)
        residency.register(id: "second", label: "Second", bytes: 4, unload: {})
        XCTAssertEqual(residency.pendingLoadBytes, 0)
    }

    func testAdmissionRechecksPinsAfterEachUnload() async {
        let residency = ModelResidency(budgetBytes: 8)
        var unloadedSecond = false
        residency.register(id: "first", label: "First", bytes: 4) {
            residency.setLeaseState(pinned: ["second"], descriptions: [:])
        }
        residency.register(id: "second", label: "Second", bytes: 4) { unloadedSecond = true }
        residency.touch(id: "second")
        _ = await residency.willLoad(id: "incoming", bytes: 8)
        XCTAssertFalse(unloadedSecond)
        XCTAssertEqual(residency.residents.map(\.id), ["second"])
    }

    func testAdmissionRecomputesAfterVictimIsReplacedWithSmallerWeights() async {
        let residency = ModelResidency(budgetBytes: 10)
        var replacementUnloaded = false
        residency.register(id: "first", label: "First", bytes: 4) {
            residency.register(id: "second", label: "Replacement", bytes: 1) { replacementUnloaded = true }
        }
        residency.register(id: "second", label: "Second", bytes: 4, unload: {})
        residency.touch(id: "second")
        _ = await residency.willLoad(id: "incoming", bytes: 8)
        XCTAssertFalse(replacementUnloaded)
        XCTAssertEqual(residency.totalBytes, 1)
    }

    func testPrivateRuntimePinSurvivesBrokerPublication() async {
        let residency = ModelResidency(budgetBytes: 4)
        var evicted = false
        let pin = await residency.pin(id: "granite")
        residency.register(id: "granite", label: "Granite", bytes: 4) { evicted = true }
        residency.setLeaseState(pinned: [], descriptions: [:])
        let admission = await residency.willLoad(id: "other", bytes: 4)
        XCTAssertFalse(evicted)
        residency.cancelLoad(admission)
        residency.unpin(pin)
        _ = await residency.willLoad(id: "other", bytes: 4)
        XCTAssertTrue(evicted)
    }

    func testNonGGUFPreparationEvictsIdleGGUFBeforeLoad() async {
        let residency = ModelResidency(budgetBytes: 10)
        let registry = ModelRuntimeRegistry(residency: residency)
        var evicted = false
        residency.register(id: "gguf", label: "GGUF", bytes: 8) { evicted = true }
        await registry.reserve(id: "asr", role: "Transcribe", label: "ASR", estimatedBytes: 4)
        XCTAssertTrue(evicted)
        XCTAssertEqual(registry.totalEstimatedBytes, 4)
        XCTAssertEqual(residency.pendingLoadBytes, 0, "registry reservations must not be counted twice")
        registry.unregister(id: "asr")
        XCTAssertEqual(registry.totalEstimatedBytes, 0)
    }

    func testGGUFAdmissionCountsAnExistingNonGGUFReservation() async {
        let residency = ModelResidency(budgetBytes: 10)
        let registry = ModelRuntimeRegistry(residency: residency)
        var evicted = false
        residency.register(id: "idle-gguf", label: "Idle GGUF", bytes: 4) { evicted = true }
        await registry.reserve(
            id: "speech", role: "Transcribe", label: "Speech", estimatedBytes: 6)

        let admission = await residency.willLoad(
            id: "cotyping",
            bytes: 5,
            currentReservedBytes: { Int64(clamping: registry.totalEstimatedBytes) })

        XCTAssertTrue(evicted, "a GGUF load must include speech-first reservations")
        residency.cancelLoad(admission)
        registry.unregister(id: "speech")
    }

    func testPinWaitsForAlreadyStartedEvictionBeforeUsingRuntime() async {
        let residency = ModelResidency(budgetBytes: 4)
        var finishUnload: CheckedContinuation<Void, Never>?
        residency.register(id: "private", label: "Private", bytes: 4) {
            await withCheckedContinuation { finishUnload = $0 }
        }
        let loading = Task { await residency.willLoad(id: "incoming", bytes: 4) }
        while finishUnload == nil { await Task.yield() }
        var acquired = false
        let pinning = Task {
            let token = await residency.pin(id: "private")
            acquired = true
            return token
        }
        while !residency.pinnedIDs.contains("private") { await Task.yield() }
        XCTAssertFalse(acquired)
        finishUnload?.resume()
        let pin = await pinning.value
        _ = await loading.value
        XCTAssertTrue(acquired)
        residency.unpin(pin)
    }
}
