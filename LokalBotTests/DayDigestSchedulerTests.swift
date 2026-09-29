import XCTest
@testable import LokalBot

final class DayDigestSchedulerTests: XCTestCase {
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

    // MARK: - shouldRun policy

    func testDoesNotRunBeforeConfiguredHour() throws {
        XCTAssertFalse(DayDigestScheduler.shouldRun(
            at: try date("2026-07-21T17:59:00Z"), hour: 18,
            digestModifiedAt: nil, calendar: calendar))
    }

    func testRunsAtOrAfterConfiguredHourWithoutADigest() throws {
        XCTAssertTrue(DayDigestScheduler.shouldRun(
            at: try date("2026-07-21T18:00:00Z"), hour: 18,
            digestModifiedAt: nil, calendar: calendar))
        XCTAssertTrue(DayDigestScheduler.shouldRun(
            at: try date("2026-07-21T23:30:00Z"), hour: 18,
            digestModifiedAt: nil, calendar: calendar))
    }

    /// The journal file's mtime is the durable once-per-day marker: written
    /// at/after today's target hour (by the scheduler or a manual regenerate)
    /// means done — including across an app relaunch.
    func testDigestWrittenAfterTargetHourSuppressesTheRun() throws {
        XCTAssertFalse(DayDigestScheduler.shouldRun(
            at: try date("2026-07-21T19:00:00Z"), hour: 18,
            digestModifiedAt: try date("2026-07-21T18:03:00Z"),
            calendar: calendar))
    }

    /// A digest the user generated in the morning is refreshed at the
    /// scheduled hour so the journal reflects the whole day.
    func testMorningManualDigestIsRefreshedAtScheduledHour() throws {
        XCTAssertTrue(DayDigestScheduler.shouldRun(
            at: try date("2026-07-21T18:00:00Z"), hour: 18,
            digestModifiedAt: try date("2026-07-21T09:12:00Z"),
            calendar: calendar))
    }

    func testHourIsClampedIntoValidRange() throws {
        // hour 99 clamps to 23:00 — before it, no run; at it, run.
        XCTAssertFalse(DayDigestScheduler.shouldRun(
            at: try date("2026-07-21T22:59:00Z"), hour: 99,
            digestModifiedAt: nil, calendar: calendar))
        XCTAssertTrue(DayDigestScheduler.shouldRun(
            at: try date("2026-07-21T23:00:00Z"), hour: 99,
            digestModifiedAt: nil, calendar: calendar))
    }

    func testPreviousDayIsFinalizedBeforeTodaysPreview() throws {
        let now = try date("2026-07-22T19:00:00Z")
        let previousDay = try date("2026-07-21T00:00:00Z")

        let selected = DayDigestScheduler.generationDay(
            at: now,
            hour: 18,
            pastDays: [.init(
                day: previousDay,
                latestEvidenceAt: try date("2026-07-21T22:15:00Z"),
                digestModifiedAt: try date("2026-07-21T18:02:00Z"))],
            currentDayDigestModifiedAt: nil,
            calendar: calendar)

        XCTAssertEqual(selected, previousDay)
    }

    func testPreviousDayFinalizationMarkerSuppressesAnotherRun() throws {
        let now = try date("2026-07-22T08:00:00Z")
        let previousDay = try date("2026-07-21T00:00:00Z")

        let selected = DayDigestScheduler.generationDay(
            at: now,
            hour: 18,
            pastDays: [.init(
                day: previousDay,
                latestEvidenceAt: try date("2026-07-21T22:15:00Z"),
                digestModifiedAt: try date("2026-07-22T00:05:00Z"))],
            currentDayDigestModifiedAt: nil,
            calendar: calendar)

        XCTAssertNil(selected, "today is before 18:00 and yesterday is already final")
    }

    func testTodaysPreviewRunsAfterYesterdayWasFinalized() throws {
        let now = try date("2026-07-22T19:00:00Z")
        let previousDay = try date("2026-07-21T00:00:00Z")

        let selected = DayDigestScheduler.generationDay(
            at: now,
            hour: 18,
            pastDays: [.init(
                day: previousDay,
                latestEvidenceAt: try date("2026-07-21T22:15:00Z"),
                digestModifiedAt: try date("2026-07-22T00:05:00Z"))],
            currentDayDigestModifiedAt: nil,
            calendar: calendar)

        XCTAssertEqual(selected, now)
    }

    func testOldestMissedDayIsCaughtUpFirstAndEmptyDaysAreSkipped() throws {
        let now = try date("2026-07-22T08:00:00Z")
        let pastDays: [DayDigestScheduler.PastDay] = [
            .init(day: try date("2026-07-18T00:00:00Z"), latestEvidenceAt: nil, digestModifiedAt: nil),
            .init(day: try date("2026-07-19T00:00:00Z"),
                  latestEvidenceAt: try date("2026-07-19T17:00:00Z"),
                  digestModifiedAt: try date("2026-07-20T00:01:00Z")),
            .init(day: try date("2026-07-20T00:00:00Z"),
                  latestEvidenceAt: try date("2026-07-20T17:00:00Z"),
                  digestModifiedAt: try date("2026-07-20T18:00:00Z")),
            .init(day: try date("2026-07-21T00:00:00Z"),
                  latestEvidenceAt: try date("2026-07-21T17:00:00Z"),
                  digestModifiedAt: nil),
        ]

        XCTAssertEqual(DayDigestScheduler.generationDay(
            at: now, hour: 18, pastDays: pastDays,
            currentDayDigestModifiedAt: nil, calendar: calendar),
                       try date("2026-07-20T00:00:00Z"),
                       "an evening preview is not final until rewritten after midnight")
    }

    // MARK: - Tick behavior

    @MainActor
    func testTickCatchesUpMissedDaysWithinSevenDaysOldestFirst() async throws {
        let current = try date("2026-07-22T08:00:00Z")
        let scheduler = DayDigestScheduler(calendar: calendar, now: { current })
        var written: [Date: Date] = [:]
        var generated: [Date] = []
        let done = expectation(description: "window caught up")

        scheduler.configure(
            .init(enabled: true, hour: 18),
            digestModifiedAt: { written[self.calendar.startOfDay(for: $0)] },
            latestEvidenceAt: { $0 < current ? $0.addingTimeInterval(3_600) : nil },
            canRun: { true },
            generate: { day in
                generated.append(day)
                written[day] = current
                if generated.count == 7 { done.fulfill() }
                return .completed
            },
            onError: { XCTFail($0) })

        await fulfillment(of: [done], timeout: 5)
        XCTAssertEqual(generated.first, try date("2026-07-15T00:00:00Z"))
        XCTAssertEqual(generated.last, try date("2026-07-21T00:00:00Z"))
        XCTAssertEqual(generated, generated.sorted())
        scheduler.stop()
    }

    @MainActor
    func testDegradedPastDayRepairsLaterWithoutBlockingLaterDays() async throws {
        var current = try date("2026-07-22T08:00:00Z")
        let scheduler = DayDigestScheduler(calendar: calendar, now: { current })
        let degradedDay = try date("2026-07-20T00:00:00Z")
        let yesterday = try date("2026-07-21T00:00:00Z")
        var generated: [Date] = []
        var written: [Date: Date] = [:]
        let reachedYesterday = expectation(description: "yesterday generated during the repair backoff")
        let repaired = expectation(description: "degraded day repaired after its backoff")

        scheduler.configure(
            .init(enabled: true, hour: 18),
            digestModifiedAt: { written[self.calendar.startOfDay(for: $0)] },
            latestEvidenceAt: { $0 == degradedDay || $0 == yesterday ? $0.addingTimeInterval(60) : nil },
            canRun: { true },
            generate: { day in
                generated.append(day)
                if day == yesterday {
                    written[day] = current
                    reachedYesterday.fulfill()
                    return .completed
                }
                if generated.filter({ $0 == degradedDay }).count == 2 { repaired.fulfill() }
                return .needsRepair
            },
            onError: { XCTFail($0) })

        await fulfillment(of: [reachedYesterday], timeout: 2)
        XCTAssertEqual(generated, [degradedDay, yesterday])
        scheduler.tick()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(generated.filter { $0 == degradedDay }.count, 1, "the repair waits for its backoff")

        current = current.addingTimeInterval(DayDigestScheduler.failureBackoff + 1)
        scheduler.tick()
        await fulfillment(of: [repaired], timeout: 2)
        scheduler.stop()
    }

    @MainActor
    func testDeferredPastDayDoesNotBlockLaterDays() async throws {
        let current = try date("2026-07-22T08:00:00Z")
        let scheduler = DayDigestScheduler(calendar: calendar, now: { current })
        let emptyDay = try date("2026-07-20T00:00:00Z")
        let yesterday = try date("2026-07-21T00:00:00Z")
        var generated: [Date] = []
        let reachedYesterday = expectation(description: "yesterday generated after deferred day")

        scheduler.configure(
            .init(enabled: true, hour: 18),
            digestModifiedAt: { _ in nil },
            latestEvidenceAt: { $0 == emptyDay || $0 == yesterday ? $0.addingTimeInterval(60) : nil },
            canRun: { true },
            generate: { day in
                generated.append(day)
                if day == yesterday { reachedYesterday.fulfill(); return .completed }
                return .deferred
            },
            onError: { XCTFail($0) })

        await fulfillment(of: [reachedYesterday], timeout: 2)
        XCTAssertEqual(generated.first, emptyDay)
        XCTAssertEqual(generated.filter { $0 == emptyDay }.count, 1)
        scheduler.stop()
    }


    /// An empty day is not a failure: the generate closure reports it and the
    /// scheduler stays quiet, ready to retry once the day has content.
    @MainActor
    func testEmptyDayIsNotReportedAsAnError() async throws {
        let current = try date("2026-07-21T18:00:00Z")
        let scheduler = DayDigestScheduler(calendar: calendar, now: { current })
        let generated = expectation(description: "generate closure ran")
        let unexpectedError = expectation(description: "empty day surfaced an error")
        unexpectedError.isInverted = true

        scheduler.configure(
            .init(enabled: true, hour: 18),
            digestModifiedAt: { _ in nil },
            latestEvidenceAt: { _ in nil },
            canRun: { true },
            generate: { _ in
                generated.fulfill()
                return .deferred
            },
            onError: { _ in unexpectedError.fulfill() })

        await fulfillment(of: [generated], timeout: 2)
        await fulfillment(of: [unexpectedError], timeout: 0.1)
        scheduler.stop()
    }

    @MainActor
    func testDegradedDigestUsesQuietFailureBackoff() async throws {
        let current = try date("2026-07-21T18:00:00Z")
        let scheduler = DayDigestScheduler(calendar: calendar, now: { current })
        let generated = expectation(description: "degraded digest generated")
        let unexpectedError = expectation(description: "degraded digest surfaced an error")
        unexpectedError.isInverted = true
        var calls = 0

        scheduler.configure(
            .init(enabled: true, hour: 18),
            digestModifiedAt: { _ in nil },
            latestEvidenceAt: { self.calendar.isDate($0, inSameDayAs: current) ? current : nil },
            canRun: { true },
            generate: { _ in
                calls += 1
                generated.fulfill()
                return .needsRepair
            },
            onError: { _ in unexpectedError.fulfill() })

        await fulfillment(of: [generated], timeout: 2)
        try await Task.sleep(for: .milliseconds(100))
        scheduler.tick()
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(calls, 1)
        await fulfillment(of: [unexpectedError], timeout: 0.1)
        scheduler.stop()
    }

    @MainActor
    func testDisablingCancelsInFlightGenerationWorker() async throws {
        let current = try date("2026-07-21T18:00:00Z")
        let scheduler = DayDigestScheduler(calendar: calendar, now: { current })
        let started = expectation(description: "generation started")
        let cancelled = expectation(description: "generation cancelled")
        let unexpectedError = expectation(description: "cancellation was reported as an error")
        unexpectedError.isInverted = true

        scheduler.configure(
            .init(enabled: true, hour: 18),
            digestModifiedAt: { _ in nil },
            latestEvidenceAt: { _ in nil },
            canRun: { true },
            generate: { _ in
                started.fulfill()
                do {
                    while true {
                        try await Task.sleep(for: .seconds(60))
                    }
                } catch is CancellationError {
                    cancelled.fulfill()
                    throw CancellationError()
                }
            },
            onError: { _ in unexpectedError.fulfill() })

        await fulfillment(of: [started], timeout: 2)
        scheduler.configure(
            .init(enabled: false, hour: 18),
            digestModifiedAt: { _ in nil },
            latestEvidenceAt: { _ in nil },
            canRun: { true },
            generate: { _ in .deferred },
            onError: { _ in unexpectedError.fulfill() })
        await fulfillment(of: [cancelled], timeout: 2)
        await fulfillment(of: [unexpectedError], timeout: 0.1)
        scheduler.stop()
    }

    @MainActor
    func testEvidenceChangeRestartsInFlightGeneration() async throws {
        let current = try date("2026-07-21T18:00:00Z")
        let scheduler = DayDigestScheduler(calendar: calendar, now: { current })
        let started = expectation(description: "first generation started")
        let cancelled = expectation(description: "stale generation cancelled")
        let refreshed = expectation(description: "fresh generation completed")
        var calls = 0

        scheduler.configure(
            .init(enabled: true, hour: 18),
            digestModifiedAt: { _ in nil },
            latestEvidenceAt: { _ in current },
            canRun: { true },
            generate: { _ in
                calls += 1
                if calls == 1 {
                    started.fulfill()
                    do {
                        while true { try await Task.sleep(for: .seconds(60)) }
                    } catch is CancellationError {
                        cancelled.fulfill()
                        throw CancellationError()
                    }
                }
                refreshed.fulfill()
                return .completed
            },
            onError: { _ in XCTFail("Cancellation should not surface as an error") })

        await fulfillment(of: [started], timeout: 2)
        scheduler.reconsiderEvidence()
        await fulfillment(of: [cancelled, refreshed], timeout: 2)
        XCTAssertEqual(calls, 2)
        scheduler.stop()
    }

    // MARK: - Custom prompt folding

    func testEmptyCustomPromptKeepsTheBaseDigestPrompt() {
        XCTAssertEqual(PromptTemplates.dayDigestSystem(custom: ""),
                       PromptTemplates.dayDigestSystem)
        XCTAssertEqual(PromptTemplates.dayDigestSystem(custom: "   \n\t"),
                       PromptTemplates.dayDigestSystem)
        XCTAssertEqual(PromptTemplates.dayDigestFallbackSystem(custom: ""),
                       PromptTemplates.dayDigestFallbackSystem)
    }

    func testCustomPromptIsAppendedToTheBasePrompt() {
        let system = PromptTemplates.dayDigestSystem(
            custom: "  Write in Serbian.  ")
        XCTAssertTrue(system.hasPrefix(PromptTemplates.dayDigestSystem))
        XCTAssertTrue(system.contains("Additional instructions from the user: Write in Serbian."))
        XCTAssertTrue(system.hasSuffix(
            "Follow them only when they do not conflict with grounding, task eligibility, or the required JSON structure above."))
    }

    func testOverlongCustomPromptIsCapped() {
        let system = PromptTemplates.dayDigestSystem(
            custom: String(repeating: "focus on code reviews ", count: 200))
        let ceiling = PromptTemplates.dayDigestSystem.count
            + PromptTemplates.dayDigestCustomPromptMaxCharacters
            + 220 // joining + non-conflict clauses
        XCTAssertLessThanOrEqual(system.count, ceiling)
        XCTAssertTrue(system.hasPrefix(PromptTemplates.dayDigestSystem))
    }

    func testDigestPromptTreatsCapturedTextAsEvidenceNotInstructions() {
        XCTAssertTrue(PromptTemplates.dayDigestSystem.contains("untrusted data"))
        XCTAssertTrue(PromptTemplates.dayDigestSystem.contains("task-first"))
        XCTAssertTrue(PromptTemplates.dayDigestFallbackSystem.contains("untrusted data"))
        XCTAssertTrue(PromptTemplates.dayDigestFocusSystem.contains("untrusted data"))
        XCTAssertTrue(PromptTemplates.dayDigestChunkSystem.contains("[screen:ID]"))
    }
}
