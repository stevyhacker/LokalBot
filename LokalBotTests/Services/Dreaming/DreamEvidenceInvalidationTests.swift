import XCTest
@testable import LokalBot

@MainActor
final class DreamEvidenceInvalidationTests: XCTestCase {
    private var calendar: Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(secondsFromGMT: 0)!
        return result
    }

    func testCorrectionInvalidatesLaterComparisonWindowsWithoutGoingBeyondThem() throws {
        let sourceDay = date("2026-08-03T12:00:00Z")
        let keys = DreamEvidenceInvalidation.dayKeys(
            affectedDays: [sourceDay, sourceDay.addingTimeInterval(60)],
            through: date("2026-09-04T12:00:00Z"), calendar: calendar)
        XCTAssertEqual(keys.count, 14)
        XCTAssertTrue(keys.contains("2026-08-03"))
        XCTAssertTrue(keys.contains("2026-08-06"), "Thursday can cite Monday's still-open action")
        XCTAssertTrue(keys.contains("2026-08-16"))
        XCTAssertFalse(keys.contains("2026-08-02"))
        XCTAssertFalse(keys.contains("2026-08-17"))
        let recent = DreamEvidenceInvalidation.dayKeys(
            affectedDays: [sourceDay], through: date("2026-08-06T12:00:00Z"), calendar: calendar)
        XCTAssertEqual(recent.count, 4)
        let digestOnly = DreamEvidenceInvalidation.dayKeys(
            affectedDays: [sourceDay], through: Date(), calendar: calendar, comparisonWindowDays: 1)
        XCTAssertEqual(digestOnly, ["2026-08-03"])
    }

    func testAffectedDreamIsCancelledBeforeItsReportExistsAndRebuilt() async throws {
        let current = date("2026-08-07T04:00:00Z")
        let scheduler = DreamScheduler(calendar: calendar, now: { current })
        defer { scheduler.stop() }
        let started = expectation(description: "Thursday dream captured Monday action")
        let cancelled = expectation(description: "Stale dream cancelled")
        let refreshed = expectation(description: "Fresh dream committed")
        var attempts = 0
        var committed: Set<String> = []
        scheduler.configure(
            .init(enabled: true, hour: 4, firstEligibleDayKey: "2026-08-06"),
            hasReport: { committed.contains($0) }, canRun: { true },
            dream: { target in
                attempts += 1
                if attempts == 1 {
                    started.fulfill()
                    do {
                        try await Task.sleep(for: .seconds(30))
                        XCTFail("Cancelled evidence reached persistence")
                    } catch is CancellationError {
                        cancelled.fulfill()
                        throw CancellationError()
                    }
                }
                try Task.checkCancellation()
                committed.insert(target.dayKey)
                refreshed.fulfill()
            }, onError: { XCTFail($0) })
        await fulfillment(of: [started], timeout: 3)
        let affected = DreamEvidenceInvalidation.dayKeys(
            affectedDays: [date("2026-08-03T12:00:00Z")], through: current, calendar: calendar)
        scheduler.reconsiderReports(invalidating: affected)
        await fulfillment(of: [cancelled, refreshed], timeout: 3)
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(committed, ["2026-08-06"])
    }

    func testInvalidatingOldSourceReopensCompletedLaterReport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dream-invalidation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DreamStore(root: root)
        let current = date("2026-08-07T04:00:00Z")
        let report = DreamReport(day: "2026-08-06", generatedAt: current, engineName: nil,
                                 narrative: "Monday's proposal is still open")
        try store.save(report)
        let scheduler = DreamScheduler(calendar: calendar, now: { current })
        defer { scheduler.stop() }
        let regenerated = expectation(description: "Completed later report regenerated")
        scheduler.configure(
            .init(enabled: true, hour: 4, firstEligibleDayKey: "2026-08-06"),
            hasReport: { store.hasReport(forDayKey: $0) }, canRun: { true },
            dream: { target in
                var updated = report
                updated.narrative = "Monday's proposal is complete"
                try store.save(updated)
                regenerated.fulfill()
            }, onError: { XCTFail($0) })
        let keys = DreamEvidenceInvalidation.dayKeys(
            affectedDays: [date("2026-08-03T12:00:00Z")], through: current, calendar: calendar)
        for key in keys { try store.invalidateReport(forDayKey: key) }
        scheduler.reconsiderReports(invalidating: keys)
        await fulfillment(of: [regenerated], timeout: 3)
        XCTAssertEqual(store.report(forDayKey: "2026-08-06")?.narrative, "Monday's proposal is complete")
    }

    func testSourceMutationCancelsDreamOutsideComparisonWindowWhenMemoryWasRead() async throws {
        let current = date("2026-09-20T04:00:00Z")
        let scheduler = DreamScheduler(calendar: calendar, now: { current })
        defer { scheduler.stop() }
        let started = expectation(description: "New dream consumed older memory")
        let cancelled = expectation(description: "Inherited source mutation cancels new dream")
        let rebuilt = expectation(description: "Fresh memory is reconsidered")
        var attempts = 0
        var completed: Set<String> = []
        scheduler.configure(
            .init(enabled: true, hour: 4, firstEligibleDayKey: "2026-09-19"),
            hasReport: { completed.contains($0) }, canRun: { true },
            dream: { target in
                attempts += 1
                if attempts == 1 {
                    started.fulfill()
                    do {
                        try await Task.sleep(for: .seconds(30))
                        XCTFail("Dream using invalidated memory was not cancelled")
                    } catch is CancellationError {
                        cancelled.fulfill()
                        throw CancellationError()
                    }
                }
                completed.insert(target.dayKey)
                rebuilt.fulfill()
            }, onError: { XCTFail($0) })
        await fulfillment(of: [started], timeout: 3)
        scheduler.reconsiderReports(invalidating: ["2026-08-03"], cancellingInFlight: true)
        await fulfillment(of: [cancelled, rebuilt], timeout: 3)
        XCTAssertEqual(attempts, 2)
    }

    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
}
