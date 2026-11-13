import XCTest
@testable import LokalBot

/// The overnight Dream re-dreamed the same seven days about eight times on
/// 2026-10-01 and never kept a memory: every retention pass, digest refresh,
/// and unrelated meeting edit discarded or revoked reports, and a rate limit
/// was recorded as a finished evidence-only day.
final class DreamLoopTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func temporaryStore() throws -> DreamStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dream-loop-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return DreamStore(root: root)
    }

    private func dayKey(_ daysAgo: Int) -> String {
        let day = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!
        return DreamDay.key(for: day, calendar: Calendar.current)
    }

    private func noon(_ daysAgo: Int) -> Date {
        let start = Calendar.current.startOfDay(for: Date())
        let day = Calendar.current.date(byAdding: .day, value: -daysAgo, to: start)!
        return day.addingTimeInterval(12 * 3_600)
    }

    private func provenance(reportDay: String, meetingID: UUID, meetingDay: String,
                            revision: UInt64 = 0) -> DreamEvidenceProvenance {
        DreamEvidenceProvenance(sources: [
            .init(kind: .meeting, id: meetingID.uuidString, dayKey: meetingDay),
            .init(kind: .screenDay, id: reportDay, dayKey: reportDay),
            .init(kind: .digest, id: reportDay, dayKey: reportDay),
        ], revision: revision)
    }

    // MARK: - Retention and screen changes

    func testScreenDeletionKeepsRecentReportsAndMeetingDerivedMemory() throws {
        let store = try temporaryStore()
        let meetingID = UUID()
        // A recent report whose comparison window reaches a meeting held the
        // day after the captures that are now expiring.
        let recent = provenance(reportDay: dayKey(2), meetingID: meetingID, meetingDay: dayKey(15))
        let report = DreamReport(day: dayKey(2), generatedAt: Date(), engineName: "test",
                                 evidenceProvenance: recent, narrative: "Recent day")
        let memory = DreamMemory(
            updatedAt: Date(), lastDreamDay: dayKey(2),
            activeProjects: [.init(name: "Atlas", status: "in review", lastActiveDay: dayKey(2),
                                   provenance: recent)])
        try store.save(report: report, memory: memory)
        // The deleted day's own report read that day's screens.
        let expiring = DreamReport(
            day: dayKey(16), generatedAt: Date(), engineName: "test",
            evidenceProvenance: provenance(reportDay: dayKey(16), meetingID: UUID(), meetingDay: dayKey(16)),
            narrative: "Old day")
        try store.save(expiring)

        try store.withScreenEvidenceMutation(on: [noon(16)]) {}

        XCTAssertTrue(store.hasReport(forDayKey: dayKey(2)),
                      "deleting screens two weeks back must not revoke this week's reports")
        XCTAssertEqual(try store.loadMemory()?.activeProjects.map(\.name), ["Atlas"])
        XCTAssertFalse(store.hasReport(forDayKey: dayKey(16)), "the day that read those screens is revoked")
    }

    @MainActor func testScheduledRetentionKeepsDreamMemoryButDeletionStillRevokesIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dream-retention-\(UUID())")
        let previousRoot = ProcessInfo.processInfo.environment["LOKALBOT_STORAGE_ROOT"]
        setenv("LOKALBOT_STORAGE_ROOT", root.path, 1)
        defer {
            if let previousRoot { setenv("LOKALBOT_STORAGE_ROOT", previousRoot, 1) } else { unsetenv("LOKALBOT_STORAGE_ROOT") }
            try? FileManager.default.removeItem(at: root)
        }
        let app = AppState()
        let store = app.dreamStore
        let expiring = provenance(reportDay: dayKey(16), meetingID: UUID(), meetingDay: dayKey(16))
        let project = DreamMemory.Project(name: "Atlas", status: "in review", lastActiveDay: dayKey(2),
                                          provenance: expiring)
        try store.save(report: DreamReport(day: dayKey(16), generatedAt: Date(), engineName: "test",
                                           evidenceProvenance: expiring, narrative: "Old day"),
                       memory: DreamMemory(updatedAt: Date(), lastDreamDay: dayKey(16), activeProjects: [project]))

        try app.withScheduledRetention(on: [noon(16)]) {}
        XCTAssertTrue(store.hasReport(forDayKey: dayKey(16)), "expiry is not a deletion")
        XCTAssertEqual(try store.loadMemory()?.activeProjects.map(\.name), ["Atlas"])

        try app.withPrimaryEvidenceChange(on: [noon(16)], .removal) {}
        XCTAssertFalse(store.hasReport(forDayKey: dayKey(16)), "deleting the captures still revokes what read them")
        XCTAssertEqual(try store.loadMemory()?.activeProjects, [])
    }

    func testClearingMemoryDeletesEverythingAndRejectsADreamThatStartedBefore() throws {
        let store = try temporaryStore()
        let meetingID = UUID()
        let recent = provenance(reportDay: dayKey(2), meetingID: meetingID, meetingDay: dayKey(2))
        let pinned = DreamMemory.Project(name: "Atlas", status: "in review", lastActiveDay: dayKey(2),
                                         pinned: true, provenance: recent)
        try store.save(report: DreamReport(day: dayKey(2), generatedAt: Date(), engineName: "test",
                                           evidenceProvenance: recent, narrative: "Recent day"),
                       memory: DreamMemory(updatedAt: Date(), lastDreamDay: dayKey(2), activeProjects: [pinned]))
        let before = try store.evidenceRevision()

        try store.clearAll()

        XCTAssertFalse(store.hasReport(forDayKey: dayKey(2)))
        XCTAssertNil(try store.loadMemory(), "pinned entries are cleared too")
        let staleProvenance = provenance(reportDay: dayKey(1), meetingID: meetingID, meetingDay: dayKey(1),
                                         revision: before)
        let stale = DreamReport(day: dayKey(1), generatedAt: Date(), engineName: "test",
                                evidenceProvenance: staleProvenance, narrative: "Started before the clear")
        XCTAssertThrowsError(try store.saveGenerated(report: stale, memory: nil, basedOnRevision: before)) {
            XCTAssertTrue($0 is CancellationError)
        }
        XCTAssertFalse(store.hasReport(forDayKey: dayKey(1)))

        let after = try store.evidenceRevision()
        let freshProvenance = provenance(reportDay: dayKey(1), meetingID: meetingID, meetingDay: dayKey(1),
                                         revision: after)
        let fresh = DreamReport(day: dayKey(1), generatedAt: Date(), engineName: "test",
                                evidenceProvenance: freshProvenance, narrative: "Started after the clear")
        XCTAssertNoThrow(try store.saveGenerated(report: fresh, memory: nil, basedOnRevision: after))
        XCTAssertTrue(store.hasReport(forDayKey: dayKey(1)))
    }

    func testDeletingTheMeetingStillRevokesEverythingThatReadIt() throws {
        let store = try temporaryStore()
        let meetingID = UUID()
        let recent = provenance(reportDay: dayKey(2), meetingID: meetingID, meetingDay: dayKey(15))
        try store.save(report: DreamReport(day: dayKey(2), generatedAt: Date(), engineName: "test",
                                           evidenceProvenance: recent, narrative: "Recent day"),
                       memory: DreamMemory(updatedAt: Date(), lastDreamDay: dayKey(2),
                                           activeProjects: [.init(name: "Atlas", status: "in review",
                                                                  lastActiveDay: dayKey(2), provenance: recent)]))

        let meeting = Meeting(id: meetingID, title: "Sync", appName: "Meet", startedAt: noon(15),
                              endedAt: noon(15).addingTimeInterval(1_800), relativePath: "meetings/sync")
        try store.withMeetingEvidenceMutation(for: [meeting]) {}

        XCTAssertFalse(store.hasReport(forDayKey: dayKey(2)))
        XCTAssertEqual(try store.loadMemory()?.activeProjects, [])
    }

    // MARK: - Commit-time staleness

    func testUnrelatedChangeWhileTheModelRunsDoesNotDiscardTheDream() throws {
        let store = try temporaryStore()
        let revision = try store.evidenceRevision()
        let meetingID = UUID()
        let report = DreamReport(
            day: dayKey(1), generatedAt: Date(), engineName: "test",
            evidenceProvenance: provenance(reportDay: dayKey(1), meetingID: meetingID,
                                           meetingDay: dayKey(1), revision: revision),
            narrative: "Yesterday")

        // Tonight's meeting finished processing while yesterday was dreamed.
        try store.invalidateEvidence(affectedDayKeys: [dayKey(0)], affectedMeetingIDs: [UUID()],
                                     reportDayKeys: [dayKey(0)])

        XCTAssertNoThrow(try store.saveGenerated(report: report, memory: nil, basedOnRevision: revision))
        XCTAssertTrue(store.hasReport(forDayKey: dayKey(1)))
    }

    func testChangeToASourceTheDreamReadStillRejectsTheCommit() throws {
        let store = try temporaryStore()
        let revision = try store.evidenceRevision()
        let meetingID = UUID()
        let report = DreamReport(
            day: dayKey(1), generatedAt: Date(), engineName: "test",
            evidenceProvenance: provenance(reportDay: dayKey(1), meetingID: meetingID,
                                           meetingDay: dayKey(1), revision: revision),
            narrative: "Yesterday")

        try store.invalidateEvidence(affectedDayKeys: [dayKey(1)], affectedMeetingIDs: [meetingID],
                                     reportDayKeys: [dayKey(1)])

        XCTAssertThrowsError(try store.saveGenerated(report: report, memory: nil, basedOnRevision: revision)) {
            XCTAssertTrue($0 is CancellationError)
        }
        XCTAssertFalse(store.hasReport(forDayKey: dayKey(1)))
    }

    // MARK: - Service

    func testRateLimitedAutomaticDreamIsDeferredInsteadOfFinishedAsEvidenceOnly() async throws {
        let store = try temporaryStore()
        var target = DreamScheduler.target(for: try date("2026-07-18T12:00:00Z"), calendar: calendar)
        target.isAutomatic = true
        let service = DreamService(
            storageRoot: store.root,
            makeEngine: {
                (RateLimitedEngine(), DreamInferenceProvenance(location: .remote, origin: "https://openrouter.ai"))
            },
            compileEvidence: { target, _ in Self.evidence(dayKey: target.dayKey, day: target.day) })

        do {
            _ = try await service.dream(target: target)
            XCTFail("a rate limit must not complete the day")
        } catch is DreamService.Deferred {}
        XCTAssertFalse(store.hasReport(forDayKey: target.dayKey))

        target.transientFailures = DreamScheduler.transientAttemptsBeforeFallback - 1
        let report = try await service.dream(target: target)
        XCTAssertEqual(report.fallbackReason, .engineUnavailable,
                       "after repeated failures the morning surface still appears")
        XCTAssertTrue(store.hasReport(forDayKey: target.dayKey))
    }

    func testDreamBoundsReasoningAndOutput() async throws {
        let store = try temporaryStore()
        let target = DreamScheduler.target(for: try date("2026-07-18T12:00:00Z"), calendar: calendar)
        let recorder = OptionsRecorder()
        let service = DreamService(
            storageRoot: store.root,
            makeEngine: { (RecordingEngine(recorder: recorder), DreamInferenceProvenance(location: .local)) },
            compileEvidence: { target, _ in Self.evidence(dayKey: target.dayKey, day: target.day) })

        let report = try await service.dream(target: target)

        XCTAssertFalse(report.isFallback)
        let options = try XCTUnwrap(recorder.options.first)
        XCTAssertEqual(options.maxTokens, DreamService.maxOutputTokens)
        XCTAssertEqual(options.reasoningBudgetTokens, DreamService.reasoningBudgetTokens)
    }

    // MARK: - Scheduler

    @MainActor
    func testSchedulerRetriesADeferredDayQuietlyAndCountsAttempts() async throws {
        var current = try date("2026-07-19T05:00:00Z")
        let scheduler = DreamScheduler(calendar: calendar, now: { current })
        var seen: [Int] = []
        scheduler.configure(
            .init(enabled: true, hour: 4, firstEligibleDayKey: "2026-07-18"),
            hasReport: { _ in false },
            canRun: { true },
            dream: { target in
                seen.append(target.transientFailures)
                throw DreamService.Deferred(underlying: TextEngineError.httpStatus(
                    code: 429, detail: "Provider returned error", retryAfter: nil))
            },
            onError: { XCTFail("a deferred dream is not a user-facing error: \($0)") })
        try await waitUntil { !scheduler.isDreaming && seen.count == 1 }
        XCTAssertNil(scheduler.lastError)

        current = current.addingTimeInterval(16 * 60)
        scheduler.tick()
        try await waitUntil { !scheduler.isDreaming && seen.count == 2 }
        XCTAssertEqual(seen, [0, 1])
        scheduler.stop()
    }

    // MARK: - Helpers

    private func date(_ value: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return try XCTUnwrap(formatter.date(from: value))
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("condition never became true")
    }

    private static func evidence(dayKey: String, day: Date) -> DreamEvidence {
        DreamEvidence(
            day: day, dayKey: dayKey,
            digest: "## What I worked on\n- Release prep",
            meetings: [], appUsage: [],
            stats: ScreenMemoryDaySummary(trackedSeconds: 4 * 3_600, appCount: 3,
                                          activityBlockCount: 6, screenshotCount: 20, savedMomentCount: 0),
            savedMoments: [], priorMeetings: [], openActions: [],
            sources: [.init(kind: .digest, id: dayKey, dayKey: dayKey)])
    }

    private struct RateLimitedEngine: TextEngine {
        var displayName: String { "OpenAI-compatible — test" }
        func generate(system: String, prompt: String, context: [String]) async throws -> String {
            throw TextEngineError.httpStatus(code: 429, detail: "Provider returned error", retryAfter: nil)
        }
        func generate(system: String, prompt: String, context: [String],
                      schema: [String: Any], options: TextGenerationOptions) async throws -> String {
            throw TextEngineError.httpStatus(code: 429, detail: "Provider returned error", retryAfter: nil)
        }
    }

    private final class OptionsRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [TextGenerationOptions] = []
        var options: [TextGenerationOptions] { lock.withLock { recorded } }
        func record(_ options: TextGenerationOptions) { lock.withLock { recorded.append(options) } }
    }

    private struct RecordingEngine: TextEngine {
        let recorder: OptionsRecorder
        var displayName: String { "Built-in — test" }
        func generate(system: String, prompt: String, context: [String]) async throws -> String {
            XCTFail("Dream must pass explicit generation options")
            return ""
        }
        func generate(system: String, prompt: String, context: [String],
                      schema: [String: Any], options: TextGenerationOptions) async throws -> String {
            recorder.record(options)
            return """
            {"narrative": "Release prep moved forward.", "attention": [], "repeated_work": [],
             "suggested_checks": [], "frictions": [], "top_actions": [], "active_projects": [],
             "work_goals": [], "recurring_patterns": []}
            """
        }
    }
}

extension DreamLoopTests {
    /// The 19:07 dream was thrown away because one advice bullet was blank.
    func testBlankAdviceBulletDoesNotDiscardTheNight() throws {
        let synthesis = try XCTUnwrap(DreamPrompts.parse("""
        {"narrative": "Release prep moved forward.", "attention": ["  ", "Signing broke twice"],
         "repeated_work": [""], "suggested_checks": [], "frictions": [], "top_actions": ["Fix signing"],
         "active_projects": [], "work_goals": [], "recurring_patterns": []}
        """))
        XCTAssertEqual(synthesis.attention, ["Signing broke twice"])
        XCTAssertEqual(synthesis.repeatedWork, [])
        XCTAssertEqual(synthesis.topActions, ["Fix signing"])
    }
}
