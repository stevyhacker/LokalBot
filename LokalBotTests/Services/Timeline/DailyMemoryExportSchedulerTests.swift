import XCTest
@testable import LokalBot

final class DailyMemoryExportSchedulerTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ value: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return try XCTUnwrap(formatter.date(from: value))
    }

    func testDoesNotRunBeforeConfiguredHour() throws {
        XCTAssertFalse(DailyMemoryExportScheduler.shouldRun(
            at: try date("2026-07-14T17:59:00Z"), hour: 18,
            lastSuccessfulDay: nil, calendar: calendar))
    }

    func testRunsAtOrAfterConfiguredHour() throws {
        XCTAssertTrue(DailyMemoryExportScheduler.shouldRun(
            at: try date("2026-07-14T18:00:00Z"), hour: 18,
            lastSuccessfulDay: nil, calendar: calendar))
        XCTAssertTrue(DailyMemoryExportScheduler.shouldRun(
            at: try date("2026-07-14T23:30:00Z"), hour: 18,
            lastSuccessfulDay: nil, calendar: calendar))
    }

    func testRunsOnlyOncePerLocalDay() throws {
        XCTAssertFalse(DailyMemoryExportScheduler.shouldRun(
            at: try date("2026-07-14T23:30:00Z"), hour: 18,
            lastSuccessfulDay: try date("2026-07-14T18:00:00Z"),
            calendar: calendar))
        XCTAssertTrue(DailyMemoryExportScheduler.shouldRun(
            at: try date("2026-07-15T18:00:00Z"), hour: 18,
            lastSuccessfulDay: try date("2026-07-14T18:00:00Z"),
            calendar: calendar))
    }

    @MainActor
    func testDisablingCancelsInFlightExportWorker() async throws {
        let current = try date("2026-07-14T18:00:00Z")
        let scheduler = DailyMemoryExportScheduler(calendar: calendar, now: { current })
        let started = expectation(description: "export worker started")
        let cancelled = expectation(description: "export worker cancelled")
        let unexpectedError = expectation(description: "cancellation was reported as an error")
        unexpectedError.isInverted = true

        scheduler.configure(.init(enabled: true, hour: 18, destinationID: "first")) { _, _ in
            started.fulfill()
            do {
                while true {
                    try await Task.sleep(for: .seconds(60))
                }
            } catch is CancellationError {
                cancelled.fulfill()
                throw CancellationError()
            }
        } onError: { _ in
            unexpectedError.fulfill()
        }

        await fulfillment(of: [started], timeout: 2)
        scheduler.configure(.init(enabled: false, hour: 18, destinationID: "")) { _, _ in
        } onError: { _ in
            unexpectedError.fulfill()
        }
        await fulfillment(of: [cancelled], timeout: 2)
        await fulfillment(of: [unexpectedError], timeout: 0.1)
        scheduler.stop()
    }

    @MainActor
    func testEvidenceChangeRestartsInFlightExport() async throws {
        let current = try date("2026-07-14T18:00:00Z")
        let scheduler = DailyMemoryExportScheduler(calendar: calendar, now: { current })
        let counter = ExportCallCounter()
        let started = expectation(description: "first export started")
        let cancelled = expectation(description: "stale export cancelled")
        let refreshed = expectation(description: "fresh export completed")

        scheduler.configure(.init(enabled: true, hour: 18, destinationID: "notes")) { _, pass in
            // Missed past days are checked first; this test is about today's note.
            guard pass == .refresh else { return }
            let call = await counter.next()
            if call == 1 {
                started.fulfill()
                do {
                    while true { try await Task.sleep(for: .seconds(60)) }
                } catch is CancellationError {
                    cancelled.fulfill()
                    throw CancellationError()
                }
            }
            refreshed.fulfill()
        } onError: { _ in
            XCTFail("Cancellation should not surface as an error")
        }

        await fulfillment(of: [started], timeout: 2)
        scheduler.reconsider(day: current)
        await fulfillment(of: [cancelled, refreshed], timeout: 2)
        let callCount = await counter.value
        XCTAssertEqual(callCount, 2)
        scheduler.stop()
    }

    func testNextExportPutsReopenedDaysFirstThenMissedDaysThenToday() throws {
        let morning = try date("2026-07-14T08:00:00Z")
        let evening = try date("2026-07-14T18:00:00Z")
        let week = try (7...13).map { try date("2026-07-\(String(format: "%02d", $0))T00:00:00Z") }
        func next(_ at: Date, caughtUp: Set<Date> = [], reopened: Set<Date> = [],
                  last: Date? = nil) -> (day: Date, pass: DailyMemoryExportPass)? {
            DailyMemoryExportScheduler.nextExport(
                at: at, hour: 18, lastSuccessfulDay: last, caughtUpDays: caughtUp,
                reopenedDays: reopened, calendar: calendar)
        }

        XCTAssertEqual(next(morning)?.day, week[0])
        XCTAssertEqual(next(morning)?.pass, .catchUp)
        XCTAssertEqual(next(morning, caughtUp: Set(week.prefix(3)))?.day, week[3])
        XCTAssertNil(next(morning, caughtUp: Set(week)))
        XCTAssertEqual(next(evening, caughtUp: Set(week))?.day, try date("2026-07-14T00:00:00Z"))
        XCTAssertEqual(next(evening, caughtUp: Set(week))?.pass, .refresh)
        XCTAssertNil(next(evening, caughtUp: Set(week), last: evening))

        let reopened = next(evening, reopened: [week[6]])
        XCTAssertEqual(reopened?.day, week[6])
        XCTAssertEqual(reopened?.pass, .refresh)
        // Older than the digest's catch-up window.
        XCTAssertNil(next(morning, caughtUp: Set(week), reopened: [try date("2026-07-01T00:00:00Z")]))
    }

    @MainActor
    func testDayMissedWhileAsleepIsWrittenNextMorning() async throws {
        let current = try date("2026-07-14T08:00:00Z")
        let scheduler = DailyMemoryExportScheduler(calendar: calendar, now: { current })
        let recorder = ExportRecorder()
        let done = expectation(description: "every missed day checked")
        done.expectedFulfillmentCount = DailyMemoryExportScheduler.catchUpDays

        scheduler.configure(.init(enabled: true, hour: 18, destinationID: "notes")) { day, pass in
            await recorder.record(day, pass)
            done.fulfill()
        } onError: { message in
            XCTFail(message)
        }

        await fulfillment(of: [done], timeout: 2)
        let calls = await recorder.calls
        XCTAssertEqual(calls.map(\.day), try (7...13).map { try date("2026-07-\(String(format: "%02d", $0))T00:00:00Z") })
        XCTAssertTrue(calls.allSatisfy { $0.pass == .catchUp })
        scheduler.stop()
    }

    @MainActor
    func testFinishedDigestRewritesAPastDayOnlyInsideTheWindow() async throws {
        let current = try date("2026-07-14T08:00:00Z")
        let scheduler = DailyMemoryExportScheduler(calendar: calendar, now: { current })
        let recorder = ExportRecorder()
        let caughtUp = expectation(description: "missed days checked")
        caughtUp.expectedFulfillmentCount = DailyMemoryExportScheduler.catchUpDays
        let refreshed = expectation(description: "yesterday rewritten")

        scheduler.configure(.init(enabled: true, hour: 18, destinationID: "notes")) { day, pass in
            await recorder.record(day, pass)
            if pass == .catchUp { caughtUp.fulfill() } else { refreshed.fulfill() }
        } onError: { message in
            XCTFail(message)
        }
        await fulfillment(of: [caughtUp], timeout: 2)

        scheduler.digestDidChange(on: try date("2026-07-01T12:00:00Z"))
        scheduler.digestDidChange(on: try date("2026-07-13T12:00:00Z"))
        await fulfillment(of: [refreshed], timeout: 2)
        let last = await recorder.calls.last
        XCTAssertEqual(last?.day, try date("2026-07-13T00:00:00Z"))
        XCTAssertEqual(last?.pass, .refresh)
        let count = await recorder.calls.count
        XCTAssertEqual(count, DailyMemoryExportScheduler.catchUpDays + 1)
        scheduler.stop()
    }

    @MainActor
    func testPastDayThatFailsIsTriedOnceAndDoesNotHoldBackToday() async throws {
        let clock = TestClock(try date("2026-07-14T18:00:00Z"))
        let failingDay = try date("2026-07-10T00:00:00Z")
        let scheduler = DailyMemoryExportScheduler(calendar: calendar, now: { clock.now })
        let recorder = ExportRecorder()
        let failed = expectation(description: "failure reported")
        failed.assertForOverFulfill = false
        let today = expectation(description: "today exported")

        scheduler.configure(.init(enabled: true, hour: 18, destinationID: "notes")) { day, pass in
            await recorder.record(day, pass)
            if day == failingDay { throw CocoaError(.fileWriteNoPermission) }
            if pass == .refresh { today.fulfill() }
        } onError: { _ in
            failed.fulfill()
        }
        await fulfillment(of: [failed], timeout: 2)

        // The usual retry wait applies before the next export.
        clock.now = clock.now.addingTimeInterval(16 * 60)
        scheduler.tick()
        await fulfillment(of: [today], timeout: 2)
        let calls = await recorder.calls
        XCTAssertEqual(calls.filter { $0.day == failingDay }.count, 1)
        XCTAssertEqual(calls.last?.day, try date("2026-07-14T00:00:00Z"))
        scheduler.stop()
    }
}

private actor ExportRecorder {
    private(set) var calls: [(day: Date, pass: DailyMemoryExportPass)] = []

    func record(_ day: Date, _ pass: DailyMemoryExportPass) {
        calls.append((day, pass))
    }
}

@MainActor
private final class TestClock {
    var now: Date

    init(_ now: Date) {
        self.now = now
    }
}

private actor ExportCallCounter {
    private(set) var value = 0

    func next() -> Int {
        value += 1
        return value
    }
}
