import AppKit
import XCTest
@testable import LokalBot

// MARK: - Quality metrics

final class CotypingStatsTests: XCTestCase {
    func testDefaults() {
        let stats = CotypingStats()
        XCTAssertEqual(stats.generations, 0)
        XCTAssertEqual(stats.accepts, 0)
        XCTAssertEqual(stats.charsAccepted, 0)
        XCTAssertEqual(stats.latenciesMs, [])
        XCTAssertNil(stats.avgLatencyMs)
        XCTAssertNil(stats.p95LatencyMs)
        XCTAssertEqual(stats.acceptsPerGeneration, 0)
    }

    func testRecordGenerationAndAccept() {
        var stats = CotypingStats()
        stats.recordGeneration(latencyMs: 100)
        stats.recordGeneration(latencyMs: 200)
        stats.recordAccept(charsAccepted: 12)
        XCTAssertEqual(stats.generations, 2)
        XCTAssertEqual(stats.accepts, 1)
        XCTAssertEqual(stats.charsAccepted, 12)
        XCTAssertEqual(stats.acceptsPerGeneration, 0.5, accuracy: 0.001)
    }

    func testLatencyCap() {
        var stats = CotypingStats()
        for ms in 1...55 { stats.recordGeneration(latencyMs: ms) }
        XCTAssertEqual(stats.latenciesMs.count, CotypingStats.maxLatencies)  // 50
        XCTAssertEqual(stats.latenciesMs.first, 6)  // first five dropped
        XCTAssertEqual(stats.latenciesMs.last, 55)
    }

    func testDerivedLatencyStats() {
        var stats = CotypingStats()
        [100, 200, 300, 400, 500].forEach { stats.recordGeneration(latencyMs: $0) }
        XCTAssertEqual(stats.avgLatencyMs, 300)
        XCTAssertEqual(stats.medianLatencyMs, 300)
        XCTAssertEqual(stats.p95LatencyMs, 500)   // idx = round(4*0.95) = 4
        XCTAssertEqual(stats.maxLatencyMs, 500)
    }

    func testSingleSampleLatency() {
        var stats = CotypingStats()
        stats.recordGeneration(latencyMs: 150)
        XCTAssertEqual(stats.avgLatencyMs, 150)
        XCTAssertEqual(stats.medianLatencyMs, 150)
        XCTAssertEqual(stats.p95LatencyMs, 150)
        XCTAssertEqual(stats.maxLatencyMs, 150)
    }

    func testReset() {
        var stats = CotypingStats()
        stats.recordGeneration(latencyMs: 100)
        stats.recordError()
        stats.reset()
        XCTAssertEqual(stats, CotypingStats())
    }

    func testCodableRoundTrip() throws {
        var stats = CotypingStats()
        stats.recordGeneration(latencyMs: 120)
        stats.recordGeneration(latencyMs: 340)
        stats.recordAccept(charsAccepted: 9)
        stats.recordError()
        let data = try JSONEncoder().encode(stats)
        let decoded = try JSONDecoder().decode(CotypingStats.self, from: data)
        XCTAssertEqual(decoded, stats)
    }
}

// MARK: - Live typing measurements

final class CotypingLiveMeasureTests: XCTestCase {
    private func field(_ text: String, processID: pid_t = 42, role: String = "AXTextArea") -> CotypingField {
        CotypingField(appName: "Notes", bundleID: "com.apple.Notes", processID: processID, role: role,
                      precedingText: text, trailingText: "", selectionLength: 0, caretRect: .zero,
                      isSecure: false, caretIsExact: true)
    }

    private func insertion(_ text: String, after before: String) -> CotypingInsertionCheck {
        CotypingInsertionCheck(field: field(before), inserted: text, surface: "other", startedUptimeNanoseconds: 0)
    }

    /// Counters saved before the measurements existed must keep their values.
    func testOlderSavedCountersDecodeWithoutResetting() throws {
        let saved = Data(#"{"generations":5,"errors":1,"accepts":2,"charsAccepted":20,"latenciesMs":[100,140]}"#.utf8)
        let stats = try JSONDecoder().decode(CotypingStats.self, from: saved)
        XCTAssertEqual(stats.generations, 5)
        XCTAssertEqual(stats.accepts, 2)
        XCTAssertEqual(stats.latenciesMs, [100, 140])
        XCTAssertTrue(stats.live.isEmpty)
        let partial = try JSONDecoder().decode(CotypingStats.self, from: Data(#"{"live":{"chat":{"shown":3}}}"#.utf8))
        XCTAssertEqual(partial.live["chat"]?.shown, 3)
        XCTAssertEqual(partial.live["chat"]?.accepts, 0)
    }

    func testMeasurementsAreKeptPerSurfaceAndRoundTrip() throws {
        var stats = CotypingStats()
        stats.recordShown(latencyMs: 180, surface: "other")
        stats.recordShown(latencyMs: 320, surface: "other")
        stats.recordShown(latencyMs: 90, surface: "browser")
        stats.recordAccept(charsAccepted: 4, surface: "other")
        stats.recordAccept(charsAccepted: 6)
        stats.recordInsertion(.confirmed, surface: "other")
        stats.recordInsertion(.mismatched, count: 2, surface: "browser")
        stats.recordInsertion(.unconfirmed, surface: "browser")
        stats.recordInsertion(.pending, surface: "browser")
        stats.recordCorrection(surface: "other")
        XCTAssertEqual(stats.accepts, 2, "the lifetime counter includes accepts without a surface")
        XCTAssertEqual(stats.live["other"]?.accepts, 1)
        XCTAssertEqual(stats.live["other"]?.medianVisibleMs, 320)
        XCTAssertEqual(stats.live["browser"]?.insertionsMismatched, 2)
        XCTAssertEqual(stats.live["browser"]?.insertionsChecked, 2)
        XCTAssertEqual(stats.liveTotal.shown, 3)
        XCTAssertEqual(stats.liveTotal.insertionsUnconfirmed, 1)
        XCTAssertEqual(stats.liveRows.map(\.title), ["Native apps", "Browsers"])
        XCTAssertEqual(try JSONDecoder().decode(CotypingStats.self, from: JSONEncoder().encode(stats)), stats)
        stats.reset()
        XCTAssertTrue(stats.live.isEmpty)
    }

    func testVisibleLatencyWindowIsCapped() {
        var measure = CotypingLiveMeasure()
        for ms in 1...60 { measure.recordShown(latencyMs: ms) }
        XCTAssertEqual(measure.shown, 60)
        XCTAssertEqual(measure.visibleLatenciesMs.count, CotypingLiveMeasure.maxLatencies)
        XCTAssertEqual(measure.visibleLatenciesMs.first, 11)
        XCTAssertEqual(measure.p95VisibleMs, 58)
    }

    func testReportListsCountsAndTimingsOnly() {
        var stats = CotypingStats()
        stats.recordGeneration(latencyMs: 49)
        stats.recordShown(latencyMs: 180, surface: "other")
        stats.recordAccept(charsAccepted: 3, surface: "other")
        stats.recordInsertion(.confirmed, surface: "other")
        stats.recordShown(latencyMs: 240, surface: "chat")
        let report = stats.report(model: "Gemma 4 E2B Base")
        XCTAssertTrue(report.hasPrefix("Autocomplete typing measurements (Gemma 4 E2B Base)"))
        XCTAssertTrue(report.contains("Suggested 1 · accepted 1 · generation median 49 ms, p95 49 ms"))
        XCTAssertTrue(report.contains("| Native apps | 1 | 180 / 180 ms | 1 | 1 / 0 / 0 | 0 |"))
        XCTAssertTrue(report.contains("| Chat | 1 | 240 / 240 ms | 0 | 0 / 0 / 0 | 0 |"))
        XCTAssertTrue(report.contains("| All | 2 |"))
        XCTAssertTrue(CotypingStats().report(model: "LFM").contains("No typing measured yet"))
    }

    func testInsertionIsConfirmedWhenTheFieldShowsIt() {
        let check = insertion(" up", after: "I wanted to follow")
        XCTAssertEqual(check.outcome(live: field("I wanted to follow"), elapsedMilliseconds: 20), .pending)
        XCTAssertEqual(check.outcome(live: field("I wanted to follow up"), elapsedMilliseconds: 40), .confirmed)
        // Typing that continued, or a browser's non-breaking space, is still the same insertion.
        XCTAssertEqual(check.outcome(live: field("I wanted to follow up on it"), elapsedMilliseconds: 900), .confirmed)
        XCTAssertEqual(insertion(" soon ", after: "See you")
            .outcome(live: field("See you soon\u{00A0}"), elapsedMilliseconds: 40), .confirmed)
        // An empty field has no text before the caret to anchor on.
        XCTAssertEqual(insertion("Hello", after: "").outcome(live: field("Hello"), elapsedMilliseconds: 40), .confirmed)
    }

    func testInsertionThatNeverShowsUpIsNotCalledSuccessful() {
        let check = insertion(" up", after: "I wanted to follow")
        let late = CotypingInsertionCheck.timeoutMilliseconds
        XCTAssertEqual(check.outcome(live: field("I wanted to follow"), elapsedMilliseconds: late), .unconfirmed)
        XCTAssertEqual(check.outcome(live: field("I wanted to followup"), elapsedMilliseconds: 40), .pending)
        XCTAssertEqual(check.outcome(live: field("I wanted to followup"), elapsedMilliseconds: late), .mismatched)
        XCTAssertEqual(check.outcome(live: field("I wanted to follow  up"), elapsedMilliseconds: late), .mismatched,
                       "a doubled space is a visible difference")
        // Another field, or none, cannot say anything about this one.
        XCTAssertEqual(check.outcome(live: field("I wanted to follow up", processID: 7), elapsedMilliseconds: late),
                       .unconfirmed)
        XCTAssertEqual(check.outcome(live: nil, elapsedMilliseconds: 10), .pending)
        XCTAssertEqual(check.outcome(live: nil, elapsedMilliseconds: late), .unconfirmed)
    }

    /// Half of a 16-character insertion used to count as confirmed.
    func testATruncatedInsertionIsNotConfirmed() {
        let check = insertion(" up on the time.", after: "I wanted to follow")
        let truncated = field("I wanted to follow up on the")
        let late = CotypingInsertionCheck.timeoutMilliseconds
        XCTAssertEqual(check.outcome(live: truncated, elapsedMilliseconds: 50), .pending,
                       "part of the text may only mean the app is still publishing")
        XCTAssertEqual(check.outcome(live: truncated, elapsedMilliseconds: late), .mismatched)
        XCTAssertEqual(check.outcome(live: field("I wanted to follow up on the time."), elapsedMilliseconds: late),
                       .confirmed)
        // Once the text that preceded the caret is gone, nothing can be said either way.
        XCTAssertEqual(check.outcome(live: field("A different line"), elapsedMilliseconds: late), .unconfirmed)
        XCTAssertEqual(insertion("Hello", after: "").outcome(live: field("Hel"), elapsedMilliseconds: late), .mismatched)
        XCTAssertEqual(insertion("Hello", after: "").outcome(live: field(""), elapsedMilliseconds: late), .unconfirmed)
    }

    func testAcceptsSentBeforeTheAppPublishesAreCheckedTogether() {
        var check = insertion(" up", after: "I wanted to follow")
        check.extend(byInserting: " on", at: 1_000)
        XCTAssertEqual(check.count, 2)
        XCTAssertEqual(check.outcome(live: field("I wanted to follow up"), elapsedMilliseconds: 30), .pending)
        XCTAssertEqual(check.outcome(live: field("I wanted to follow up on"), elapsedMilliseconds: 60), .confirmed)
    }

    func testMeasurementsFlagIsRecognizedBeforeLaunch() {
        XCTAssertEqual(HeadlessCommand.parse(["LokalBot", "--cotyping-measurements"]), .cotypingMeasurements)
        XCTAssertEqual(HeadlessCommand.parse(["LokalBot", "--cotyping-bench"]), .cotypingBench)
        XCTAssertEqual(
            HeadlessCommand.parse(["LokalBot", "--cotyping-bench", "--model-path", "/m/e2b.gguf", "--passes", "3"]),
            .cotypingEngineBench(model: URL(fileURLWithPath: "/m/e2b.gguf"), passes: 3))
        XCTAssertEqual(
            HeadlessCommand.parse(["LokalBot", "--cotyping-bench", "--model-path", "/m/e2b.gguf"]),
            .cotypingEngineBench(model: URL(fileURLWithPath: "/m/e2b.gguf"), passes: 5))
    }

    func testDeletionAndUndoAreCorrections() {
        XCTAssertTrue(CotypingInputEvent(kind: .textMutation, characters: "").isCorrection)
        XCTAssertTrue(CotypingInputEvent(kind: .shortcut, characters: "", isUndo: true).isCorrection)
        XCTAssertFalse(CotypingInputEvent(kind: .textMutation, characters: "a").isCorrection)
        XCTAssertFalse(CotypingInputEvent(kind: .shortcut, characters: "").isCorrection)
        XCTAssertFalse(CotypingInputEvent(kind: .dismissal, characters: "").isCorrection)
    }
}

final class CotypingStatsStoreTests: XCTestCase {
    @MainActor
    func testPersistAndReload() async {
        let name = "cotyping-stats-test"
        UserDefaults().removePersistentDomain(forName: name)
        let suite = UserDefaults(suiteName: name)!

        let store = CotypingStatsStore(defaults: suite)
        XCTAssertEqual(store.stats, CotypingStats())

        store.recordGeneration(latencyMs: 120)
        store.recordAccept(charsAccepted: 7)
        store.recordError()
        store.suggestionCompleted()
        await store.flushPersistence()

        // A fresh store loading the same suite sees the persisted values.
        let reloaded = CotypingStatsStore(defaults: suite)
        XCTAssertEqual(reloaded.stats.generations, 1)
        XCTAssertEqual(reloaded.stats.accepts, 1)
        XCTAssertEqual(reloaded.stats.charsAccepted, 7)
        XCTAssertEqual(reloaded.stats.errors, 1)

        reloaded.clear()
        await reloaded.flushPersistence()
        XCTAssertEqual(CotypingStatsStore(defaults: suite).stats, CotypingStats())

        suite.removePersistentDomain(forName: name)
    }

    @MainActor
    func testAcceptedChunksPersistOnceAtSuggestionCompletion() async {
        let persistence = RecordingCotypingStatsPersistence()
        let name = "cotyping-stats-batch-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        let store = CotypingStatsStore(defaults: suite, persistence: persistence)

        store.recordAccept(charsAccepted: 4)
        store.recordAccept(charsAccepted: 6)
        store.recordAccept(charsAccepted: 2)
        await store.waitForPendingPersistence()
        let beforeCompletion = await persistence.recordedStats()
        XCTAssertTrue(beforeCompletion.isEmpty,
                      "accepted chunks must not each trigger a defaults write")

        store.suggestionCompleted()
        await store.waitForPendingPersistence()

        let snapshots = await persistence.recordedStats()
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots[0].accepts, 3)
        XCTAssertEqual(snapshots[0].charsAccepted, 12)
        suite.removePersistentDomain(forName: name)
    }

    @MainActor
    func testTerminationFlushPersistsDirtyAcceptedChunks() async {
        let persistence = RecordingCotypingStatsPersistence()
        let name = "cotyping-stats-flush-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        let store = CotypingStatsStore(defaults: suite, persistence: persistence)
        store.recordAccept(charsAccepted: 9)

        await store.flushPersistence()

        let snapshots = await persistence.recordedStats()
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots[0].accepts, 1)
        XCTAssertEqual(snapshots[0].charsAccepted, 9)
        suite.removePersistentDomain(forName: name)
    }
}

private actor RecordingCotypingStatsPersistence: CotypingStatsPersisting {
    private var snapshots: [CotypingStats] = []
    private var removeCount = 0

    func persist(_ stats: CotypingStats) {
        snapshots.append(stats)
    }

    func remove() {
        removeCount += 1
    }

    func persistUsage(_ usage: CotypingUsageHistory) {}
    func removeUsage() {}

    func recordedStats() -> [CotypingStats] { snapshots }
}
