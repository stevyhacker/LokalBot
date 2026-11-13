import XCTest
@testable import LokalBot

final class CotypingUsageHistoryTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    func testAcceptanceCountsEachShownSuggestionOnce() {
        var history = CotypingUsageHistory()
        let now = date(2026, 10, 14)
        for _ in 0..<4 { history.recordShown(surface: "chat", model: "e2b", at: now, calendar: calendar) }
        // One suggestion taken in three word-by-word presses, another in one.
        history.recordAccept(words: 1, characters: 4, firstOfSuggestion: true, surface: "chat", model: "e2b", at: now, calendar: calendar)
        history.recordAccept(words: 1, characters: 3, firstOfSuggestion: false, surface: "chat", model: "e2b", at: now, calendar: calendar)
        history.recordAccept(words: 0, characters: 1, firstOfSuggestion: false, surface: "chat", model: "e2b", at: now, calendar: calendar)
        history.recordAccept(words: 2, characters: 9, firstOfSuggestion: true, surface: "chat", model: "e2b", at: now, calendar: calendar)

        let counts = history.summary(.week, now: now, calendar: calendar).total.suggestions
        XCTAssertEqual(counts.shown, 4)
        XCTAssertEqual(counts.used, 2)
        XCTAssertEqual(counts.accepts, 4)
        XCTAssertEqual(counts.words, 4)
        XCTAssertEqual(counts.acceptanceRate, 0.5)
        XCTAssertEqual(counts.wordsPerUsedSuggestion, 2)
        XCTAssertEqual(counts.keystrokesSaved, 13, "17 characters for 4 accept presses")
    }

    func testAcceptanceNeverExceedsWhatWasShown() {
        var counts = CotypingUsageCounts()
        counts.shown = 1
        counts.used = 2
        XCTAssertEqual(counts.acceptanceRate, 1)
        XCTAssertNil(CotypingUsageCounts().acceptanceRate)
    }

    func testShareOfTextComparesSuggestedWithTypedCharacters() {
        var history = CotypingUsageHistory()
        let now = date(2026, 10, 14)
        history.recordAccept(words: 5, characters: 30, firstOfSuggestion: true, surface: "email", model: "e2b", at: now, calendar: calendar)
        history.recordTyped(characters: 90, gapMilliseconds: nil, at: now, calendar: calendar)
        XCTAssertEqual(history.summary(.week, now: now, calendar: calendar).total.shareOfText, 0.25)
        XCTAssertNil(CotypingUsageBucket().shareOfText)
    }

    func testTimeSavedUsesYourTypingSpeedOnceMeasured() {
        var history = CotypingUsageHistory()
        let now = date(2026, 10, 14)
        // 101 characters, 1 accept press: 100 keystrokes saved.
        history.recordAccept(words: 20, characters: 101, firstOfSuggestion: true, surface: "other", model: "e2b", at: now, calendar: calendar)

        var summary = history.summary(.week, now: now, calendar: calendar)
        XCTAssertNil(summary.wordsPerMinute, "too little typing measured")
        XCTAssertEqual(summary.timeSavedSeconds, 30, accuracy: 0.001, "falls back to 40 words a minute")

        for _ in 0..<CotypingUsageHistory.minimumTypingGaps {
            history.recordTyped(characters: 1, gapMilliseconds: 200, at: now, calendar: calendar)
        }
        // Pauses longer than a second are not typing speed.
        history.recordTyped(characters: 1, gapMilliseconds: 4_000, at: now, calendar: calendar)
        summary = history.summary(.week, now: now, calendar: calendar)
        XCTAssertEqual(summary.total.typingGaps, CotypingUsageHistory.minimumTypingGaps)
        XCTAssertEqual(summary.wordsPerMinute, 60)
        XCTAssertEqual(summary.timeSavedSeconds, 20, accuracy: 0.001)
    }

    func testTypingSpeedComesFromTheWholeHistory() {
        var history = CotypingUsageHistory()
        for _ in 0..<CotypingUsageHistory.minimumTypingGaps {
            history.recordTyped(characters: 1, gapMilliseconds: 240, at: date(2026, 3, 2), calendar: calendar)
        }
        let summary = history.summary(.week, now: date(2026, 10, 14), calendar: calendar)
        XCTAssertEqual(summary.total.typingGaps, 0, "March is outside the week")
        XCTAssertEqual(summary.wordsPerMinute, 50)
    }

    func testBreakdownsByKindOfAppAndModel() {
        var history = CotypingUsageHistory()
        let now = date(2026, 10, 14)
        history.recordShown(surface: "chat", model: "e2b", at: now, calendar: calendar)
        history.recordShown(surface: "email", model: "e4b", at: now, calendar: calendar)
        history.recordAccept(words: 3, characters: 12, firstOfSuggestion: true, surface: "email", model: "e4b", at: now, calendar: calendar)
        history.recordTakenBack(surface: "email", model: "e4b", at: now, calendar: calendar)

        let total = history.summary(.week, now: now, calendar: calendar).total
        XCTAssertEqual(total.surfaces["chat"]?.shown, 1)
        XCTAssertEqual(total.surfaces["chat"]?.used, 0)
        XCTAssertEqual(total.surfaces["email"]?.used, 1)
        XCTAssertEqual(total.models["e4b"]?.words, 3)
        XCTAssertEqual(total.models["e4b"]?.takenBack, 1)
        XCTAssertEqual(total.suggestions.takenBack, 1)
    }

    func testDailyRowsAreTrimmedButMonthsKeepTheTotals() {
        var history = CotypingUsageHistory()
        history.recordAccept(words: 7, characters: 30, firstOfSuggestion: true, surface: "chat", model: "e2b",
                             at: date(2026, 1, 5), calendar: calendar)
        history.recordAccept(words: 2, characters: 10, firstOfSuggestion: true, surface: "chat", model: "e2b",
                             at: date(2026, 10, 14), calendar: calendar)
        XCTAssertEqual(Set(history.days.keys), ["2026-10-14"], "January is past the daily window")
        XCTAssertEqual(history.months["2026-01"]?.suggestions.words, 7)

        let allTime = history.summary(.allTime, now: date(2026, 10, 14), calendar: calendar)
        XCTAssertEqual(allTime.total.suggestions.words, 9)
        XCTAssertEqual(allTime.bars.count, 10, "January to October")
        XCTAssertEqual(allTime.barUnit, .month)
        XCTAssertEqual(allTime.activeBars, 2)
    }

    func testRangesHaveOneBarPerPeriodIncludingEmptyOnes() {
        var history = CotypingUsageHistory()
        let now = date(2026, 10, 14)
        history.recordAccept(words: 4, characters: 20, firstOfSuggestion: true, surface: "chat", model: "e2b",
                             at: date(2026, 10, 10), calendar: calendar)
        history.recordAccept(words: 6, characters: 30, firstOfSuggestion: true, surface: "chat", model: "e2b",
                             at: date(2026, 9, 1), calendar: calendar)

        let week = history.summary(.week, now: now, calendar: calendar)
        XCTAssertEqual(week.bars.count, 7)
        XCTAssertEqual(week.bars.first?.start, date(2026, 10, 8, hour: 0))
        XCTAssertEqual(week.bars.last?.start, date(2026, 10, 14, hour: 0))
        XCTAssertEqual(week.total.suggestions.words, 4)

        let month = history.summary(.month, now: now, calendar: calendar)
        XCTAssertEqual(month.bars.count, 30)
        XCTAssertEqual(month.total.suggestions.words, 4, "1 September is 43 days back")

        let year = history.summary(.year, now: now, calendar: calendar)
        XCTAssertEqual(year.bars.count, 12)
        XCTAssertEqual(year.bars.first?.start, date(2025, 11, 1, hour: 0))
        XCTAssertEqual(year.total.suggestions.words, 10)

        XCTAssertEqual(CotypingUsageHistory().summary(.allTime, now: now, calendar: calendar).bars.count, 1)
    }

    func testDaysFollowTheLocalCalendar() {
        var tokyo = calendar
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        // 20:00 UTC on 14 October is 05:00 on 15 October in Tokyo.
        XCTAssertEqual(CotypingUsageHistory.dayKey(date(2026, 10, 14, hour: 20), calendar: tokyo), "2026-10-15")
        XCTAssertEqual(CotypingUsageHistory.monthKey(date(2026, 10, 14), calendar: calendar), "2026-10")
    }

    func testEncodingLeavesOutZerosAndRoundTrips() throws {
        var history = CotypingUsageHistory()
        let now = date(2026, 10, 14)
        history.recordShown(surface: "chat", model: "e2b", at: now, calendar: calendar)
        history.recordTypoFixed(at: now, calendar: calendar)
        let data = try JSONEncoder().encode(history)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("\"used\""), json)
        XCTAssertFalse(json.contains("typedCharacters"), json)
        XCTAssertEqual(try JSONDecoder().decode(CotypingUsageHistory.self, from: data), history)
        XCTAssertEqual(try JSONDecoder().decode(CotypingUsageHistory.self, from: Data("{}".utf8)), CotypingUsageHistory())
        XCTAssertTrue(CotypingUsageHistory().isEmpty)
        XCTAssertFalse(history.isEmpty)
    }
}

final class CotypingUsageStoreTests: XCTestCase {
    @MainActor
    func testUsagePersistsWithTheSuggestionAndReloads() async throws {
        let name = "cotyping-usage-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { suite.removePersistentDomain(forName: name) }

        let store = CotypingStatsStore(defaults: suite)
        store.recordSuggestionShown(surface: "chat", model: "e2b")
        store.recordSuggestionAccept(words: 2, characters: 9, firstOfSuggestion: true, surface: "chat", model: "e2b")
        store.recordTyped(characters: 1, gapMilliseconds: 150)
        store.suggestionCompleted()
        await store.waitForPendingPersistence()

        let reloaded = CotypingStatsStore(defaults: suite).usage.summary(.week).total
        XCTAssertEqual(reloaded.suggestions.shown, 1)
        XCTAssertEqual(reloaded.suggestions.used, 1)
        XCTAssertEqual(reloaded.suggestions.words, 2)
        XCTAssertEqual(reloaded.typedCharacters, 1)
        XCTAssertEqual(reloaded.typingGaps, 1)
    }

    @MainActor
    func testTypingAloneWaitsForTheNextBoundaryAndIsFlushedOnQuit() async throws {
        let persistence = RecordingUsagePersistence()
        let name = "cotyping-usage-typing-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { suite.removePersistentDomain(forName: name) }
        let store = CotypingStatsStore(defaults: suite, persistence: persistence)

        store.recordTyped(characters: 1, gapMilliseconds: nil)
        store.recordTyped(characters: 1, gapMilliseconds: 120)
        await store.waitForPendingPersistence()
        let beforeFlush = await persistence.usage()
        XCTAssertTrue(beforeFlush.isEmpty, "typing must not write on every key")

        await store.flushPersistence()
        let flushed = await persistence.usage()
        XCTAssertEqual(flushed.count, 1)
        XCTAssertEqual(flushed.last?.summary(.week).total.typedCharacters, 2)

        // A generation writes the counters; the unchanged history is not written again.
        store.recordGeneration(latencyMs: 80)
        await store.waitForPendingPersistence()
        let afterGeneration = await persistence.usage()
        XCTAssertEqual(afterGeneration.count, 1)
    }

    @MainActor
    func testClearingStatisticsLeavesTheMeasurementsAndViceVersa() async throws {
        let persistence = RecordingUsagePersistence()
        let name = "cotyping-usage-clear-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { suite.removePersistentDomain(forName: name) }
        let store = CotypingStatsStore(defaults: suite, persistence: persistence)

        store.recordGeneration(latencyMs: 80)
        store.recordSuggestionShown(surface: "chat", model: "e2b")
        store.clearUsage()
        await store.flushPersistence()
        XCTAssertTrue(store.usage.isEmpty)
        XCTAssertEqual(store.stats.generations, 1)
        let removals = await persistence.removals()
        XCTAssertEqual(removals, 1)

        store.recordSuggestionShown(surface: "chat", model: "e2b")
        store.clear()
        XCTAssertFalse(store.usage.isEmpty)
        XCTAssertEqual(store.stats, CotypingStats())
    }
}

private actor RecordingUsagePersistence: CotypingStatsPersisting {
    private var snapshots: [CotypingUsageHistory] = []
    private var removeCount = 0

    func persist(_ stats: CotypingStats) {}
    func remove() {}
    func persistUsage(_ usage: CotypingUsageHistory) { snapshots.append(usage) }
    func removeUsage() { removeCount += 1 }

    func usage() -> [CotypingUsageHistory] { snapshots }
    func removals() -> Int { removeCount }
}

final class AutocompleteStatisticsPresentationTests: XCTestCase {
    private func counts(shown: Int, used: Int = 0, words: Int = 0) -> CotypingUsageCounts {
        var counts = CotypingUsageCounts()
        counts.shown = shown
        counts.used = used
        counts.words = words
        return counts
    }

    func testBreakdownRowsSkipUnusedEntriesAndPutTheBusiestFirst() {
        var bucket = CotypingUsageBucket()
        bucket.surfaces = ["chat": counts(shown: 10, used: 4, words: 9),
                           "email": counts(shown: 3, used: 2, words: 20),
                           "terminal": CotypingUsageCounts()]
        bucket.models = ["e2b": counts(shown: 10), "e4b": counts(shown: 30), "old": CotypingUsageCounts()]

        let surfaces = AutocompleteStatisticsPresentation.surfaceRows(bucket, .english)
        XCTAssertEqual(surfaces.map(\.id), ["email", "chat"])
        XCTAssertEqual(surfaces.first?.title, "Email")
        XCTAssertEqual(AutocompleteStatisticsPresentation.surfaceRows(bucket, .simplifiedChinese).first?.title, "邮件")

        let models = AutocompleteStatisticsPresentation.modelRows(bucket) { $0.uppercased() }
        XCTAssertEqual(models.map(\.title), ["E4B", "E2B"])
    }

    func testTimeSavedReadsAsAnApproximateDuration() {
        XCTAssertEqual(AutocompleteStatisticsPresentation.timeSaved(0), "0")
        let minutes = AutocompleteStatisticsPresentation.timeSaved(41 * 60)
        XCTAssertTrue(minutes.hasPrefix("≈ ") && minutes.contains("41"), minutes)
        let hours = AutocompleteStatisticsPresentation.timeSaved(3 * 3_600 + 25 * 60)
        XCTAssertTrue(hours.contains("3") && hours.contains("25"), hours)
    }

    func testMissingRatesShowADashNotZero() {
        XCTAssertEqual(AutocompleteStatisticsPresentation.percent(nil), "—")
        XCTAssertEqual(AutocompleteStatisticsPresentation.decimal(nil), "—")
        XCTAssertEqual(AutocompleteStatisticsPresentation.wordsDetail(CotypingUsageCounts(), .english), "None accepted yet")
    }

    func testTheWordAxisLeavesHeadroomAndAFloor() {
        var history = CotypingUsageHistory()
        history.recordAccept(words: 100, characters: 500, firstOfSuggestion: true, surface: "chat", model: "e2b", at: Date())
        XCTAssertEqual(AutocompleteStatisticsPresentation.wordCeiling(history.summary(.week)), 110)
        XCTAssertEqual(AutocompleteStatisticsPresentation.wordCeiling(CotypingUsageHistory().summary(.week)), 10)
    }
}
