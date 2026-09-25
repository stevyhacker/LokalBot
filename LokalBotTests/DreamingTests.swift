import XCTest
@testable import LokalBot

final class DreamingTests: XCTestCase {
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

    private func temporaryRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dreaming-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func sampleEvidence() throws -> DreamEvidence {
        var outcomes = MeetingOutcomes()
        outcomes.actionItems = [
            .init(text: "Send the launch checklist", owner: "Me", due: "Friday"),
            .init(text: "Review the appcast", owner: "Ana"),
        ]
        outcomes.decisions = ["Ship 0.5 next week"]
        outcomes.openQuestions = ["Who owns the release notes?"]
        return DreamEvidence(
            day: try date("2026-07-18T00:00:00Z"),
            dayKey: "2026-07-18",
            digest: "## What I worked on\n- Release prep",
            meetings: [.init(
                shortID: "abcd1234",
                title: "Release sync",
                durationLabel: "42 min",
                startedAt: try date("2026-07-18T09:00:00Z"),
                outcomes: outcomes)],
            appUsage: [],
            stats: ScreenMemoryDaySummary(
                trackedSeconds: 4 * 3600,
                appCount: 6,
                activityBlockCount: 12,
                screenshotCount: 30,
                savedMomentCount: 1),
            savedMoments: [],
            priorMeetings: [.init(dayKey: "2026-07-17", title: "Release sync")],
            openActions: ["- [ ] Fix flaky UI test — `98761234`"])
    }

    // MARK: - Scheduler

    func testShouldRunWaitsForHourAndSkipsDreamedDays() throws {
        XCTAssertFalse(DreamScheduler.shouldRun(
            at: try date("2026-07-19T03:59:00Z"), hour: 4,
            hasReportForPreviousDay: false, calendar: calendar))
        XCTAssertTrue(DreamScheduler.shouldRun(
            at: try date("2026-07-19T04:00:00Z"), hour: 4,
            hasReportForPreviousDay: false, calendar: calendar))
        XCTAssertTrue(DreamScheduler.shouldRun(
            at: try date("2026-07-19T09:30:00Z"), hour: 4,
            hasReportForPreviousDay: false, calendar: calendar))
        XCTAssertFalse(DreamScheduler.shouldRun(
            at: try date("2026-07-19T09:30:00Z"), hour: 4,
            hasReportForPreviousDay: true, calendar: calendar))
        // Defensive hour clamp: 99 behaves as 23, not as "always due".
        XCTAssertFalse(DreamScheduler.shouldRun(
            at: try date("2026-07-19T12:00:00Z"), hour: 99,
            hasReportForPreviousDay: false, calendar: calendar))
    }

    func testPreviousDayCrossesMonthBoundary() throws {
        XCTAssertEqual(
            DreamScheduler.previousDay(of: try date("2026-07-01T10:15:00Z"),
                                       calendar: calendar),
            try date("2026-06-30T00:00:00Z"))
    }

    func testSystemIdleRequiresThreeMinutesWithoutInput() {
        XCTAssertFalse(DreamScheduler.isSystemIdle(for: 179.9))
        XCTAssertTrue(DreamScheduler.isSystemIdle(for: 180))
        XCTAssertFalse(DreamScheduler.isSystemIdle(for: .nan))
    }

    func testOldestMissingTargetCatchesUpGapAcrossMultipleDays() throws {
        let completed: Set<String> = ["2026-07-15", "2026-07-16", "2026-07-18"]
        let target = try XCTUnwrap(DreamScheduler.oldestMissingTarget(
            firstEligibleDayKey: "2026-07-15",
            through: try date("2026-07-21T00:00:00Z"),
            hasReport: { completed.contains($0) },
            calendar: calendar))

        XCTAssertEqual(target.dayKey, "2026-07-17")
        XCTAssertEqual(target.day, try date("2026-07-17T00:00:00Z"))
        XCTAssertEqual(target.calendar.timeZone, calendar.timeZone)
    }

    func testOldestMissingTargetReturnsNilWhenCatchUpIsComplete() throws {
        let completed: Set<String> = ["2026-07-18", "2026-07-19", "2026-07-20"]
        XCTAssertNil(DreamScheduler.oldestMissingTarget(
            firstEligibleDayKey: "2026-07-18",
            through: try date("2026-07-20T00:00:00Z"),
            hasReport: { completed.contains($0) },
            calendar: calendar))
    }

    func testInvalidBoundaryClampsButFutureOptInBoundaryWaits() throws {
        let yesterday = try date("2026-07-20T00:00:00Z")
        let malformedTarget = try XCTUnwrap(DreamScheduler.oldestMissingTarget(
            firstEligibleDayKey: "not-a-day",
            through: yesterday,
            hasReport: { _ in false },
            calendar: calendar))
        XCTAssertEqual(malformedTarget.dayKey, "2026-07-20")

        XCTAssertNil(DreamScheduler.oldestMissingTarget(
            firstEligibleDayKey: "2026-08-01",
            through: yesterday,
            hasReport: { _ in false },
            calendar: calendar))
    }

    @MainActor
    func testStopCancelsInFlightDream() async throws {
        let current = try date("2026-07-19T04:00:00Z")
        let scheduler = DreamScheduler(calendar: calendar, now: { current })
        let started = expectation(description: "dream started")
        let cancelled = expectation(description: "dream cancelled")
        let reportedError = expectation(description: "cancellation reported as error")
        reportedError.isInverted = true

        scheduler.configure(
            .init(enabled: true, hour: 4, firstEligibleDayKey: "2026-07-18"),
            hasReport: { _ in false },
            canRun: { true },
            dream: { _ in
                started.fulfill()
                do {
                    while true { try await Task.sleep(for: .seconds(60)) }
                } catch is CancellationError {
                    cancelled.fulfill()
                    throw CancellationError()
                }
            },
            onError: { _ in reportedError.fulfill() })

        await fulfillment(of: [started], timeout: 5)
        scheduler.stop()
        await fulfillment(of: [cancelled], timeout: 5)
        await fulfillment(of: [reportedError], timeout: 0.5)
        XCTAssertFalse(scheduler.isDreaming)
    }

    @MainActor
    func testSuccessfulCatchUpDoesNotApplyFailureBackoffToNextDay() async throws {
        let current = try date("2026-07-21T04:00:00Z")
        let scheduler = DreamScheduler(calendar: calendar, now: { current })
        var completed: Set<String> = ["2026-07-20"]
        var dreamed: [String] = []
        let first = expectation(description: "first missing day dreamed")
        let second = expectation(description: "second missing day dreamed")

        scheduler.configure(
            .init(enabled: true, hour: 4, firstEligibleDayKey: "2026-07-18"),
            hasReport: { completed.contains($0) },
            canRun: { true },
            dream: { target in
                XCTAssertTrue(target.isAutomatic)
                dreamed.append(target.dayKey)
                completed.insert(target.dayKey)
                if dreamed.count == 1 { first.fulfill() }
                if dreamed.count == 2 { second.fulfill() }
            },
            onError: { XCTFail($0) })

        await fulfillment(of: [first], timeout: 5)
        while scheduler.isDreaming { await Task.yield() }
        scheduler.tick()
        await fulfillment(of: [second], timeout: 5)
        XCTAssertEqual(dreamed, ["2026-07-18", "2026-07-19"])
        scheduler.stop()
    }

    @MainActor
    func testCaughtUpSchedulerDoesNotRescanHistoryEveryMinute() throws {
        let current = try date("2026-07-21T04:00:00Z")
        let scheduler = DreamScheduler(calendar: calendar, now: { current })
        var reportChecks = 0

        scheduler.configure(
            .init(enabled: true, hour: 4, firstEligibleDayKey: "2026-07-18"),
            hasReport: { _ in
                reportChecks += 1
                return true
            },
            canRun: { true },
            dream: { _ in XCTFail("All days are already complete") },
            onError: { XCTFail($0) })

        XCTAssertEqual(reportChecks, 3)
        scheduler.tick()
        XCTAssertEqual(reportChecks, 3)
        scheduler.stop()
    }

    @MainActor
    func testManualDreamRunsWhenAutomationIsDisabledAndBypassesScheduleGates() async throws {
        let current = try date("2026-07-19T12:00:00Z")
        let scheduler = DreamScheduler(calendar: calendar, now: { current })
        let started = expectation(description: "manual dream started")
        var dreamedDayKey: String?

        scheduler.configure(
            .init(enabled: false, hour: 23, firstEligibleDayKey: ""),
            hasReport: { _ in true },
            canRun: { false },
            dream: { target in
                XCTAssertFalse(target.isAutomatic)
                dreamedDayKey = target.dayKey
                started.fulfill()
            },
            onError: { XCTFail($0) })

        scheduler.dreamNow()

        await fulfillment(of: [started], timeout: 5)
        while scheduler.isDreaming { await Task.yield() }
        XCTAssertEqual(dreamedDayKey, "2026-07-18")
        scheduler.stop()
    }

    func testDreamingActivationBoundaryDefaultsAndRoundTrips() throws {
        let defaults = AppSettings()
        XCTAssertTrue(defaults.dreamingEnabled)
        XCTAssertNil(defaults.dreamingFirstEligibleDayKey)

        var settings = AppSettings()
        settings.dreamingEnabled = true
        settings.dreamingFirstEligibleDayKey = "2026-07-18"
        let decoded = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.dreamingFirstEligibleDayKey, "2026-07-18")

        let legacy = try JSONDecoder().decode(
            AppSettings.self,
            from: Data(#"{"autoTranscribe":false}"#.utf8))
        XCTAssertTrue(legacy.dreamingEnabled)
        XCTAssertNil(legacy.dreamingFirstEligibleDayKey)
    }

    // MARK: - Store

    func testStoreRoundTripPermissionsAndLatest() throws {
        let root = try temporaryRoot()
        let store = DreamStore(root: root)
        let report = DreamReport(
            day: "2026-07-18",
            generatedAt: try date("2026-07-19T04:01:00Z"),
            engineName: "Built-in — Test",
            inferenceProvenance: .init(location: .local),
            narrative: "A focused day.",
            attention: ["CI is red — `abcd1234`"],
            topActions: ["Fix CI first"])
        XCTAssertFalse(store.hasReport(forDayKey: "2026-07-18"))
        try store.save(report)
        XCTAssertTrue(store.hasReport(forDayKey: "2026-07-18"))
        XCTAssertEqual(store.report(forDayKey: "2026-07-18"), report)

        let attributes = try FileManager.default.attributesOfItem(
            atPath: store.reportJSONURL(forDayKey: "2026-07-18").path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(permissions & 0o777, 0o600)

        var newer = report
        newer.day = "2026-07-19"
        try store.save(newer)
        XCTAssertEqual(store.latestReport()?.day, "2026-07-19")

        let memory = DreamMemory(
            updatedAt: try date("2026-07-19T04:01:00Z"),
            lastDreamDay: "2026-07-18",
            activeProjects: [.init(name: "Atlas", status: "in review",
                                   lastActiveDay: "2026-07-18", evidence: ["`abcd1234`"])])
        XCTAssertNil(try store.loadMemory())
        try store.save(memory)
        XCTAssertEqual(try store.loadMemory(), memory)

        let markdown = try String(
            contentsOf: store.dreamsDirectory.appendingPathComponent("2026-07-18.md"),
            encoding: .utf8)
        XCTAssertTrue(markdown.hasPrefix(DreamStore.generatedMarker))
        XCTAssertTrue(markdown.contains("Morning brief — 2026-07-18"))
    }

    func testCombinedSaveWritesReportMarkerOnlyAfterMemorySucceeds() throws {
        let root = try temporaryRoot()
        let store = DreamStore(root: root)
        let report = DreamReport(
            day: "2026-07-18",
            generatedAt: try date("2026-07-19T04:01:00Z"),
            engineName: "Built-in — Test",
            inferenceProvenance: .init(location: .local),
            narrative: "A focused day.")
        let memory = DreamMemory(updatedAt: try date("2026-07-19T04:01:00Z"))

        // A regular file where the memory directory belongs forces the first
        // persistence phase to fail. The scheduler marker must remain absent.
        try Data("blocked".utf8).write(to: store.memoryDirectory)
        XCTAssertThrowsError(try store.save(report: report, memory: memory))
        XCTAssertFalse(store.hasReport(forDayKey: report.day))
    }

    func testCorruptOrUnsupportedMemoryIsNeverTreatedAsAbsent() throws {
        let store = DreamStore(root: try temporaryRoot())
        try FileManager.default.createDirectory(
            at: store.memoryDirectory,
            withIntermediateDirectories: true)
        let memoryURL = store.memoryDirectory.appendingPathComponent(
            "\(DreamStore.memoryFileName).json")
        let corrupt = Data(#"{"version":1,"activeProjects":"broken"}"#.utf8)
        try corrupt.write(to: memoryURL)

        XCTAssertThrowsError(try store.loadMemory()) { error in
            guard let storeError = error as? DreamStoreError,
                  case .invalidJSON = storeError else {
                return XCTFail("Expected invalidJSON, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: memoryURL), corrupt)

        var future = DreamMemory(updatedAt: try date("2026-07-19T04:01:00Z"))
        future.version = DreamMemory.currentVersion + 1
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(future).write(to: memoryURL)
        XCTAssertThrowsError(try store.loadMemory()) { error in
            guard let storeError = error as? DreamStoreError,
                  case .unsupportedMemoryVersion = storeError else {
                return XCTFail("Expected unsupportedMemoryVersion, got \(error)")
            }
        }
    }

    func testMalformedOrDayMismatchedReportIsNotACompletionMarker() throws {
        let store = DreamStore(root: try temporaryRoot())
        let report = DreamReport(
            day: "2026-07-17",
            generatedAt: try date("2026-07-18T04:01:00Z"),
            engineName: "Built-in — Test",
            inferenceProvenance: .init(location: .local),
            narrative: "A focused day.")
        try store.save(report)

        let mismatchedKey = "2026-07-18"
        try Data(contentsOf: store.reportJSONURL(forDayKey: report.day))
            .write(to: store.reportJSONURL(forDayKey: mismatchedKey))
        XCTAssertFalse(store.hasReport(forDayKey: mismatchedKey))

        let malformedKey = "2026-07-19"
        try Data("{not json".utf8).write(
            to: store.reportJSONURL(forDayKey: malformedKey))
        XCTAssertFalse(store.hasReport(forDayKey: malformedKey))
        XCTAssertEqual(store.latestReport()?.day, report.day)
    }

    func testInvalidatingReportRemovesDurableMarkerAndRendering() throws {
        let store = DreamStore(root: try temporaryRoot())
        let report = DreamReport(
            day: "2026-07-18",
            generatedAt: try date("2026-07-19T04:01:00Z"),
            engineName: "Built-in — Test",
            inferenceProvenance: .init(location: .local),
            narrative: "Before recovered processing finished.")
        try store.save(report)

        try store.invalidateReport(forDayKey: report.day)

        XCTAssertFalse(store.hasReport(forDayKey: report.day))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: store.dreamsDirectory.appendingPathComponent("\(report.day).md").path))
    }

    func testDreamServiceUsesScheduledCalendarThroughPersistence() async throws {
        let root = try temporaryRoot()
        var targetCalendar = Calendar(identifier: .gregorian)
        targetCalendar.timeZone = TimeZone(secondsFromGMT: 14 * 3_600)!
        let target = DreamScheduler.target(
            for: try date("2026-07-18T12:00:00Z"),
            calendar: targetCalendar)
        let ambientKey = DreamDay.key(for: target.day, calendar: calendar)
        XCTAssertNotEqual(ambientKey, target.dayKey)
        let journalDirectory = root.appendingPathComponent("journal", isDirectory: true)
        try FileManager.default.createDirectory(
            at: journalDirectory,
            withIntermediateDirectories: true)
        try Data("correct target digest".utf8).write(
            to: journalDirectory.appendingPathComponent("\(target.dayKey).md"))
        try Data("wrong adjacent digest".utf8).write(
            to: journalDirectory.appendingPathComponent("\(ambientKey).md"))
        let snapshot = try FileDailyEvidenceSource(root: root, calendar: target.calendar)
            .snapshot(for: target.day)
        try DayDigestGenerationMetadataStore.record(
            quality: .complete, evidenceLatestAt: snapshot.latestEvidenceAt,
            evidenceSignature: snapshot.digestEvidence(calendar: target.calendar).contentSignature,
            for: journalDirectory.appendingPathComponent("\(target.dayKey).md"))

        let evidence = try DreamCompiler.compile(
            day: target.day,
            storageRoot: root,
            calendar: target.calendar)
        XCTAssertEqual(evidence.digest, "correct target digest")
        XCTAssertEqual(
            DreamPrompts.context(evidence: evidence, memory: DreamMemory(updatedAt: Date())).first,
            "Analyzed local day: \(target.dayKey)")

        let generatedAt = try date("2026-07-19T04:01:00Z")
        let service = DreamService(
            storageRoot: root,
            makeEngine: { throw TextEngineError.unavailable("Test backend offline") },
            now: { generatedAt })

        let report = try await service.dream(target: target)

        XCTAssertEqual(report.day, target.dayKey)
        XCTAssertTrue(DreamStore(root: root).hasReport(forDayKey: target.dayKey))
    }

    func testDreamServiceRefusesToOverwriteCorruptMemory() async throws {
        let root = try temporaryRoot()
        let store = DreamStore(root: root)
        try FileManager.default.createDirectory(
            at: store.memoryDirectory,
            withIntermediateDirectories: true)
        let memoryURL = store.memoryDirectory.appendingPathComponent(
            "\(DreamStore.memoryFileName).json")
        let corrupt = Data(#"{"version":1,"workGoals":"broken"}"#.utf8)
        try corrupt.write(to: memoryURL)
        let target = DreamScheduler.target(
            for: try date("2026-07-18T12:00:00Z"),
            calendar: calendar)
        let service = DreamService(
            storageRoot: root,
            makeEngine: {
                XCTFail("The engine must not run when durable memory is corrupt")
                throw TextEngineError.unavailable("unused")
            })

        do {
            _ = try await service.dream(target: target)
            XCTFail("Expected corrupt memory to abort the dream")
        } catch let error as DreamStoreError {
            guard case .invalidJSON = error else {
                return XCTFail("Expected invalidJSON, got \(error)")
            }
        }

        XCTAssertEqual(try Data(contentsOf: memoryURL), corrupt)
        XCTAssertFalse(store.hasReport(forDayKey: target.dayKey))
    }

    func testHistoricalReportRepairNeverRegressesNewerMemory() async throws {
        let root = try temporaryRoot()
        let store = DreamStore(root: root)
        let newerMemory = DreamMemory(
            updatedAt: try date("2026-07-19T04:01:00Z"),
            lastDreamDay: "2026-07-18",
            activeProjects: [.init(
                name: "Atlas",
                status: "released",
                lastActiveDay: "2026-07-18",
                evidence: ["release verified"])],
            workGoals: [.init(
                text: "Ship 0.5",
                horizon: "done",
                lastReinforcedDay: "2026-07-18")],
            recurringPatterns: ["Protect the current state"])
        try store.save(newerMemory)
        let historicalTarget = DreamScheduler.target(
            for: try date("2026-07-17T12:00:00Z"),
            calendar: calendar)
        let regeneratedAt = try date("2026-07-20T04:01:00Z")
        let service = DreamService(
            storageRoot: root,
            makeEngine: { throw TextEngineError.unavailable("Test backend offline") },
            now: { regeneratedAt })

        _ = try await service.dream(target: historicalTarget)

        XCTAssertTrue(store.hasReport(forDayKey: historicalTarget.dayKey))
        XCTAssertEqual(try store.loadMemory(), newerMemory)
    }

    func testTodayDreamSelectionUsesCurrentDateWhenViewCrossedMidnight() throws {
        let store = DreamStore(root: try temporaryRoot())
        let latest = DreamReport(
            day: "2026-07-18",
            generatedAt: try date("2026-07-19T04:01:00Z"),
            engineName: "Built-in — Test",
            inferenceProvenance: .init(location: .local),
            narrative: "Yesterday's report.")

        let selected = TodayDreamSelection.report(
            referenceDate: try date("2026-07-19T04:02:00Z"),
            latest: latest,
            store: store,
            calendar: calendar)
        XCTAssertEqual(selected, latest)
    }

    // MARK: - Prompts / parsing

    func testDreamPromptRequestsHumanMorningBriefCopy() {
        XCTAssertTrue(DreamPrompts.system.contains("Use \"yesterday\", never a raw ISO date"))
        XCTAssertTrue(DreamPrompts.system.contains("never say \"the user\""))
        XCTAssertTrue(DreamPrompts.system.contains("never invent generic productivity advice"))
    }

    func testParseToleratesFencedJSONAndAppliesCaps() throws {
        let output = """
        Sure! Here is the retrospective:
        ```json
        {"narrative": "Busy release day.",
         "attention": ["CI red on lokalbot — `abcd1234`"],
         "repeated_work": [], "suggested_checks": [], "frictions": [],
         "top_actions": ["Fix CI", "Merge the PR", "Draft notes", "Extra item"],
         "active_projects": [{"name": "Atlas", "status": "in review",
                              "evidence": ["`abcd1234`", "e2", "e3", "e4", "e5"]}],
         "work_goals": [{"text": "Ship 0.5", "horizon": "next week",
                          "reinforced_today": true}],
         "recurring_patterns": ["Mornings go to review"]}
        ```
        """
        let synthesis = try XCTUnwrap(DreamPrompts.parse(output))
        XCTAssertEqual(synthesis.narrative, "Busy release day.")
        XCTAssertEqual(synthesis.attention, ["CI red on lokalbot — `abcd1234`"])
        XCTAssertEqual(synthesis.topActions.count, DreamPrompts.maxTopActions)
        XCTAssertEqual(synthesis.memory.activeProjects.first?.name, "Atlas")
        XCTAssertEqual(synthesis.memory.activeProjects.first?.evidence.count,
                       DreamMemory.maxEvidencePerProject)
        XCTAssertEqual(synthesis.memory.workGoals,
                       [.init(text: "Ship 0.5", horizon: "next week",
                              reinforcedToday: true)])
    }

    func testParseRejectsUnusableOutput() {
        XCTAssertNil(DreamPrompts.parse("I could not find anything to analyze."))
        XCTAssertNil(DreamPrompts.parse("""
        {"narrative": "", "attention": [], "repeated_work": [], "suggested_checks": [],
         "frictions": [], "top_actions": [], "active_projects": [], "work_goals": [],
         "recurring_patterns": []}
        """))
    }

    func testParseRejectsPartialMistypedOrSemanticallyEmptyPayloads() {
        XCTAssertNil(DreamPrompts.parse("""
        {"narrative": "A focused day.", "attention": [], "repeated_work": [],
         "suggested_checks": [], "frictions": [], "top_actions": [],
         "active_projects": [], "work_goals": []}
        """))
        XCTAssertNil(DreamPrompts.parse("""
        {"narrative": "A focused day.", "attention": [], "repeated_work": [],
         "suggested_checks": [], "frictions": [], "top_actions": "none",
         "active_projects": [], "work_goals": [], "recurring_patterns": []}
        """))
        XCTAssertNil(DreamPrompts.parse("""
        {"narrative": "A focused day.", "attention": [], "repeated_work": [],
         "suggested_checks": [], "frictions": [], "top_actions": [],
         "active_projects": [{"name": "Atlas", "status": "   ", "evidence": []}],
         "work_goals": [], "recurring_patterns": []}
        """))
        XCTAssertNil(DreamPrompts.parse("""
        {"narrative": "A focused day.", "attention": [], "repeated_work": [],
         "suggested_checks": [], "frictions": [], "top_actions": [],
         "active_projects": [],
         "work_goals": [{"text": "Ship 0.5", "horizon": "Q3"}],
         "recurring_patterns": []}
        """))
    }

    func testStrictSchemaClosesEveryObjectShape() throws {
        let schema = DreamPrompts.schema
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])

        for key in ["active_projects", "work_goals"] {
            let arraySchema = try XCTUnwrap(properties[key] as? [String: Any])
            let itemSchema = try XCTUnwrap(arraySchema["items"] as? [String: Any])
            XCTAssertEqual(itemSchema["additionalProperties"] as? Bool, false, key)
        }
    }

    func testInferenceProvenanceDistinguishesLocalAndApprovedRemoteBackends() {
        var local = AppSettings()
        local.summarizerBackend = .builtIn
        XCTAssertEqual(
            DreamInferenceProvenance(settings: local),
            .init(location: .local))

        var remote = AppSettings()
        remote.summarizerBackend = .openAICompatible
        remote.openAIBaseURL = "https://inference.example.com/v1"
        remote.approvedRemoteInferenceOrigins = ["https://inference.example.com"]
        XCTAssertEqual(
            DreamInferenceProvenance(settings: remote),
            .init(location: .remote, origin: "https://inference.example.com"))
    }

    func testReportProvenanceExplainsRemoteAndUnparseableGeneration() throws {
        let generatedAt = try date("2026-07-19T04:01:00Z")
        let remote = DreamReport(
            day: "2026-07-18",
            generatedAt: generatedAt,
            engineName: "OpenAI-compatible — test",
            inferenceProvenance: .init(
                location: .remote,
                origin: "https://inference.example.com"),
            narrative: "A focused day.")
        XCTAssertTrue(remote.provenanceDescription.contains("approved remote inference"))
        XCTAssertTrue(remote.provenanceDescription.contains("https://inference.example.com"))
        XCTAssertFalse(remote.provenanceDescription.contains("Nothing left this Mac"))

        let fallback = DreamReport(
            day: "2026-07-18",
            generatedAt: generatedAt,
            engineName: nil,
            fallbackReason: .unparseableResponse,
            narrative: "Evidence only.")
        XCTAssertTrue(fallback.provenanceDescription.contains("response could not be read"))
        XCTAssertFalse(fallback.provenanceDescription.contains("No model was reachable"))
    }

    // MARK: - Fallback compilation

    func testFallbackReportIsEvidenceOnlyAndDeterministic() throws {
        let evidence = try sampleEvidence()
        let generatedAt = try date("2026-07-19T04:01:00Z")
        let report = DreamCompiler.fallbackReport(
            from: evidence, generatedAt: generatedAt,
            reason: .engineUnavailable, note: "No model.")
        XCTAssertNil(report.engineName)
        XCTAssertTrue(report.isFallback)
        XCTAssertEqual(report.fallbackReason, .engineUnavailable)
        XCTAssertEqual(report.day, "2026-07-18")
        XCTAssertTrue(report.narrative.contains("1 recorded meeting"))
        XCTAssertTrue(report.narrative.contains("4h 0m"))
        XCTAssertEqual(report.attention,
                       ["Who owns the release notes? — `abcd1234`"])
        // The user's own commitment leads; analysis sections stay empty
        // because the fallback never infers.
        XCTAssertEqual(report.topActions.count, 1)
        XCTAssertTrue(try XCTUnwrap(report.topActions.first)
            .contains("Send the launch checklist"))
        XCTAssertFalse(try XCTUnwrap(report.topActions.first)
            .contains("completion not tracked"))
        XCTAssertTrue(report.repeatedWork.isEmpty)
        XCTAssertTrue(report.suggestedChecks.isEmpty)
        XCTAssertTrue(report.frictions.isEmpty)
        XCTAssertEqual(
            report,
            DreamCompiler.fallbackReport(from: evidence, generatedAt: generatedAt,
                                         reason: .engineUnavailable, note: "No model."))
    }

    func testFallbackDoesNotPromoteAnotherOwnersAction() throws {
        var evidence = try sampleEvidence()
        evidence.meetings[0].outcomes.actionItems = [
            .init(text: "Review the appcast", owner: "Ana"),
        ]
        evidence.openActions = ["- [ ] Review the appcast (owner: Ana) — `abcd1234`"]

        let report = DreamCompiler.fallbackReport(
            from: evidence,
            generatedAt: try date("2026-07-19T04:01:00Z"),
            reason: .engineUnavailable,
            note: "No model.")
        XCTAssertTrue(report.topActions.isEmpty)
    }

    func testEvidencePackCitesMeetingsAndKeepsWindowLabeled() throws {
        let pack = DreamCompiler.evidencePack(try sampleEvidence())
        XCTAssertTrue(pack.contains("Release sync (`abcd1234`, 42 min)"))
        XCTAssertTrue(pack.contains("decision: Ship 0.5 next week"))
        XCTAssertTrue(pack.contains("comparison window only"))
        XCTAssertTrue(pack.contains("using saved corrections and status"))
        XCTAssertLessThanOrEqual(pack.count, DreamCompiler.evidenceCharacterLimit)
    }

    // MARK: - Memory merge

    func testMemoryMergeInsertsUpdatesPrunesAndKeepsUnchangedStamps() throws {
        let existing = DreamMemory(
            updatedAt: try date("2026-07-18T04:00:00Z"),
            lastDreamDay: "2026-07-17",
            activeProjects: [
                .init(name: "Atlas", status: "waiting on review",
                      lastActiveDay: "2026-07-17", evidence: ["PR open"]),
                .init(name: "Steady", status: "background refactor",
                      lastActiveDay: "2026-07-16", evidence: []),
                .init(name: "Dusty", status: "paused",
                      lastActiveDay: "2026-05-01", evidence: []),
            ],
            workGoals: [.init(text: "Ship 0.5", horizon: "Q3",
                              lastReinforcedDay: "2026-07-10")],
            recurringPatterns: ["Mornings go to email"])
        let update = DreamMemoryUpdate(
            activeProjects: [
                .init(name: "atlas", status: "merged, awaiting release",
                      evidence: ["`abcd1234`"]),
                .init(name: "Steady", status: "background refactor", evidence: []),
                .init(name: "Beacon", status: "kickoff scheduled", evidence: []),
            ],
            workGoals: [.init(text: "ship 0.5", horizon: "next week",
                              reinforcedToday: true)],
            recurringPatterns: ["Deep work lands after 15:00"])

        let merged = existing.merging(update, dreamDay: "2026-07-18",
                                      at: try date("2026-07-19T04:01:00Z"),
                                      calendar: calendar)

        XCTAssertEqual(merged.lastDreamDay, "2026-07-18")
        let names = merged.activeProjects.map(\.name)
        XCTAssertTrue(names.contains("Atlas"))
        XCTAssertTrue(names.contains("Beacon"))
        XCTAssertTrue(names.contains("Steady"))
        // Untouched for 78 days — aged out.
        XCTAssertFalse(names.contains("Dusty"))

        let atlas = try XCTUnwrap(merged.activeProjects.first { $0.name == "Atlas" })
        XCTAssertEqual(atlas.status, "merged, awaiting release")
        XCTAssertEqual(atlas.lastActiveDay, "2026-07-18")
        // Proposed identically → not "activity"; the stamp must not refresh.
        let steady = try XCTUnwrap(merged.activeProjects.first { $0.name == "Steady" })
        XCTAssertEqual(steady.lastActiveDay, "2026-07-16")

        XCTAssertEqual(merged.workGoals.count, 1)
        XCTAssertEqual(merged.workGoals.first?.lastReinforcedDay, "2026-07-18")
        XCTAssertEqual(merged.workGoals.first?.horizon, "next week")
        XCTAssertEqual(merged.recurringPatterns, ["Deep work lands after 15:00"])

        // The model returns a full replacement list, so [] intentionally clears.
        let cleared = merged.merging(DreamMemoryUpdate(), dreamDay: "2026-07-19",
                                     at: try date("2026-07-20T04:01:00Z"),
                                     calendar: calendar)
        XCTAssertTrue(cleared.recurringPatterns.isEmpty)
    }

    func testUnreinforcedGoalEchoDoesNotRefreshOrInsertAndStillAgesOut() throws {
        let existing = DreamMemory(
            updatedAt: try date("2026-07-17T04:00:00Z"),
            workGoals: [
                .init(text: "Ship 0.5", horizon: "Q3",
                      lastReinforcedDay: "2026-07-10"),
                .init(text: "Retire legacy API", horizon: "someday",
                      lastReinforcedDay: "2026-05-01"),
            ])
        let update = DreamMemoryUpdate(workGoals: [
            .init(text: "Ship 0.5", horizon: "next week", reinforcedToday: false),
            .init(text: "Retire legacy API", horizon: "someday", reinforcedToday: false),
            .init(text: "Invented carry-forward", horizon: "unknown", reinforcedToday: false),
        ])

        let merged = existing.merging(
            update,
            dreamDay: "2026-07-18",
            at: try date("2026-07-19T04:01:00Z"),
            calendar: calendar)

        XCTAssertEqual(merged.workGoals.map(\.text), ["Ship 0.5"])
        XCTAssertEqual(merged.workGoals.first?.horizon, "Q3")
        XCTAssertEqual(merged.workGoals.first?.lastReinforcedDay, "2026-07-10")
    }

    // MARK: - Empty days

    func testSubstantivelyEmptyDayIsDetected() throws {
        var evidence = try sampleEvidence()
        XCTAssertFalse(evidence.isSubstantivelyEmpty)

        evidence.meetings = []
        evidence.digest = nil
        evidence.savedMoments = []
        evidence.stats = ScreenMemoryDaySummary(
            trackedSeconds: 0, appCount: 0, activityBlockCount: 0,
            screenshotCount: 0, savedMomentCount: 0)
        XCTAssertTrue(evidence.isSubstantivelyEmpty)

        // A brief wake to glance at something is still an empty day…
        evidence.stats = ScreenMemoryDaySummary(
            trackedSeconds: 200, appCount: 1, activityBlockCount: 1,
            screenshotCount: 2, savedMomentCount: 0)
        XCTAssertTrue(evidence.isSubstantivelyEmpty)

        // …but real tracked time, a digest, or a saved moment is not.
        evidence.stats = ScreenMemoryDaySummary(
            trackedSeconds: 3_600, appCount: 4, activityBlockCount: 6,
            screenshotCount: 20, savedMomentCount: 0)
        XCTAssertFalse(evidence.isSubstantivelyEmpty)
        evidence.stats = ScreenMemoryDaySummary(
            trackedSeconds: 0, appCount: 0, activityBlockCount: 0,
            screenshotCount: 0, savedMomentCount: 0)
        evidence.digest = "## What I worked on"
        XCTAssertFalse(evidence.isSubstantivelyEmpty)
        // The comparison window alone never makes a day substantive.
        evidence.digest = nil
        XCTAssertFalse(evidence.priorMeetings.isEmpty)
        XCTAssertFalse(evidence.openActions.isEmpty)
        XCTAssertTrue(evidence.isSubstantivelyEmpty)
    }

    func testDreamServiceSkipsEngineForEmptyDayAndWritesDurableStub() async throws {
        let root = try temporaryRoot()
        let target = DreamScheduler.target(
            for: try date("2026-07-18T12:00:00Z"),
            calendar: calendar)
        let generatedAt = try date("2026-07-19T04:01:00Z")
        let service = DreamService(
            storageRoot: root,
            makeEngine: {
                XCTFail("The engine must not run for a substantively empty day")
                throw TextEngineError.unavailable("unused")
            },
            now: { generatedAt })

        let report = try await service.dream(target: target)

        XCTAssertTrue(report.isFallback)
        XCTAssertEqual(report.fallbackReason, .emptyDay)
        let store = DreamStore(root: root)
        // The stub is still the durable "day was dreamed" marker…
        XCTAssertTrue(store.hasReport(forDayKey: target.dayKey))
        // …and advances the memory watermark so catch-up moves past the day.
        XCTAssertEqual(try store.loadMemory()?.lastDreamDay, target.dayKey)
    }

    func testTodaySelectionFallsBackToLatestSubstantiveReportWithinFiveDays() throws {
        let store = DreamStore(root: try temporaryRoot())
        let substantive = DreamReport(
            day: "2026-07-16",
            generatedAt: try date("2026-07-17T04:01:00Z"),
            engineName: "Built-in — Test",
            inferenceProvenance: .init(location: .local),
            narrative: "A real working day.")
        try store.save(substantive)
        let emptyStub = DreamReport(
            day: "2026-07-18",
            generatedAt: try date("2026-07-19T04:01:00Z"),
            engineName: nil,
            fallbackReason: .emptyDay,
            narrative: "Nothing was recorded.")
        try store.save(emptyStub)

        // Yesterday was empty (and 07-17 is missing) → surface the newest
        // substantive brief instead of the stub or nothing.
        let selected = TodayDreamSelection.report(
            referenceDate: try date("2026-07-19T08:00:00Z"),
            latest: nil,
            store: store,
            calendar: calendar)
        XCTAssertEqual(selected?.day, "2026-07-16")

        // Beyond the lookback the card goes quiet instead of resurrecting
        // stale briefs.
        XCTAssertNil(TodayDreamSelection.report(
            referenceDate: try date("2026-07-25T08:00:00Z"),
            latest: nil,
            store: store,
            calendar: calendar))
    }

    func testTodaySelectionMarksReportsFromEarlierDays() throws {
        let report = DreamReport(
            day: "2026-07-16",
            generatedAt: try date("2026-07-17T04:01:00Z"),
            engineName: "Built-in — Test",
            inferenceProvenance: .init(location: .local),
            narrative: "A real working day.")
        XCTAssertTrue(TodayDreamSelection.isCurrent(
            report,
            referenceDate: try date("2026-07-17T08:00:00Z"),
            calendar: calendar))
        XCTAssertFalse(TodayDreamSelection.isCurrent(
            report,
            referenceDate: try date("2026-07-19T08:00:00Z"),
            calendar: calendar))
    }

    func testTodayRetryIsLimitedToCurrentModelFailureFallbacks() throws {
        let referenceDate = try date("2026-07-19T08:00:00Z")
        var report = DreamReport(
            day: "2026-07-18",
            generatedAt: try date("2026-07-19T04:01:00Z"),
            engineName: nil,
            fallbackReason: .engineUnavailable,
            narrative: "Evidence only.")

        XCTAssertTrue(TodayDreamSelection.isRetryableFailure(
            report, referenceDate: referenceDate, calendar: calendar))
        report.fallbackReason = .unparseableResponse
        XCTAssertTrue(TodayDreamSelection.isRetryableFailure(
            report, referenceDate: referenceDate, calendar: calendar))
        report.fallbackReason = nil // Legacy evidence-only report.
        XCTAssertTrue(TodayDreamSelection.isRetryableFailure(
            report, referenceDate: referenceDate, calendar: calendar))

        report.fallbackReason = .emptyDay
        XCTAssertFalse(TodayDreamSelection.isRetryableFailure(
            report, referenceDate: referenceDate, calendar: calendar))
        report.fallbackReason = .engineUnavailable
        report.engineName = "Built-in — Test"
        XCTAssertFalse(TodayDreamSelection.isRetryableFailure(
            report, referenceDate: referenceDate, calendar: calendar))
        report.engineName = nil
        report.day = "2026-07-17"
        XCTAssertFalse(TodayDreamSelection.isRetryableFailure(
            report, referenceDate: referenceDate, calendar: calendar))
    }

    func testPrioritiesHeadingFramesStaleBriefsByTheirDay() throws {
        let report = DreamReport(
            day: "2026-07-16",
            generatedAt: try date("2026-07-17T04:01:00Z"),
            engineName: "Built-in — Test",
            inferenceProvenance: .init(location: .local),
            narrative: "A real working day.",
            topActions: ["Fix CI first"])

        // Yesterday's brief really is today's priorities.
        XCTAssertEqual(
            TodayDreamSelection.prioritiesHeading(
                for: report,
                referenceDate: try date("2026-07-17T08:00:00Z"),
                calendar: calendar),
            "Priorities for today")

        // A Thursday brief surfacing on Sunday must carry its own day —
        // never "for today".
        let staleHeading = TodayDreamSelection.prioritiesHeading(
            for: report,
            referenceDate: try date("2026-07-19T08:00:00Z"),
            calendar: calendar)
        XCTAssertNotEqual(staleHeading, "Priorities for today")
        let day = try XCTUnwrap(DreamDay.date(fromKey: report.day))
        XCTAssertEqual(
            staleHeading,
            "Priorities from \(day.formatted(.dateTime.weekday(.wide)))")

        // Beyond a week, a bare weekday would be ambiguous — use the date.
        XCTAssertEqual(
            TodayDreamSelection.prioritiesHeading(
                for: report,
                referenceDate: try date("2026-08-01T08:00:00Z"),
                calendar: calendar),
            "Priorities from \(day.formatted(date: .abbreviated, time: .omitted))")
    }

    func testEmptyDayProvenanceSaysNoModelRan() throws {
        let stub = DreamReport(
            day: "2026-07-18",
            generatedAt: try date("2026-07-19T04:01:00Z"),
            engineName: nil,
            fallbackReason: .emptyDay,
            narrative: "Nothing was recorded.")
        XCTAssertTrue(stub.isFallback)
        XCTAssertTrue(stub.provenanceDescription.contains("no model ran"))
        XCTAssertFalse(stub.provenanceDescription.contains("No model was reachable"))
    }

    // MARK: - Expired goals

    func testExpiredGoalIsRemovedAndNeverInserted() throws {
        let existing = DreamMemory(
            updatedAt: try date("2026-07-18T04:00:00Z"),
            workGoals: [
                .init(text: "Ship 0.5", horizon: "next week",
                      lastReinforcedDay: "2026-07-17"),
                .init(text: "Keep inbox at zero", horizon: "ongoing",
                      lastReinforcedDay: "2026-07-17"),
            ])
        let update = DreamMemoryUpdate(workGoals: [
            .init(text: "ship 0.5", horizon: "done",
                  reinforcedToday: true, expired: true),
            .init(text: "Never existed", horizon: "unknown",
                  reinforcedToday: true, expired: true),
        ])

        let merged = existing.merging(update, dreamDay: "2026-07-18",
                                      at: try date("2026-07-19T04:01:00Z"),
                                      calendar: calendar)

        XCTAssertEqual(merged.workGoals.map(\.text), ["Keep inbox at zero"])
    }

    func testParseReadsOptionalExpiredFlag() throws {
        let output = """
        {"narrative": "Wrapped up the release.", "attention": [], "repeated_work": [],
         "suggested_checks": [], "frictions": [], "top_actions": [],
         "active_projects": [],
         "work_goals": [
            {"text": "Ship 0.5", "horizon": "done", "reinforced_today": true, "expired": true},
            {"text": "Plan 0.6", "horizon": "next month", "reinforced_today": true}],
         "recurring_patterns": []}
        """
        let synthesis = try XCTUnwrap(DreamPrompts.parse(output))
        XCTAssertEqual(synthesis.memory.workGoals.map(\.expired), [true, false])
    }

    func testSystemPromptAndStrictSchemaRequireExpiredGoals() throws {
        XCTAssertTrue(DreamPrompts.system.contains("expired"))

        let properties = try XCTUnwrap(DreamPrompts.schema["properties"] as? [String: Any])
        let goals = try XCTUnwrap(properties["work_goals"] as? [String: Any])
        let items = try XCTUnwrap(goals["items"] as? [String: Any])
        let goalProperties = try XCTUnwrap(items["properties"] as? [String: Any])
        XCTAssertNotNil(goalProperties["expired"])
        let required = try XCTUnwrap(items["required"] as? [String])
        XCTAssertTrue(required.contains("expired"))
    }

    // MARK: - Pinned memory

    func testPinnedEntriesSurviveRetentionCapsAndExpiry() throws {
        let existing = DreamMemory(
            updatedAt: try date("2026-07-18T04:00:00Z"),
            activeProjects: [.init(name: "Anchor", status: "long-running",
                                   lastActiveDay: "2026-01-01", evidence: [],
                                   pinned: true)],
            workGoals: [.init(text: "North star", horizon: "always",
                              lastReinforcedDay: "2026-01-01", pinned: true)])
        // Cap pressure: a full slate of fresh proposals, none matching the
        // pinned entries, plus an expiry attempt against the pinned goal.
        var update = DreamMemoryUpdate(
            activeProjects: (1...DreamMemory.maxProjects).map {
                .init(name: "Project \($0)", status: "active", evidence: [])
            },
            workGoals: (1...DreamMemory.maxGoals).map {
                .init(text: "Goal \($0)", horizon: "soon", reinforcedToday: true)
            })
        update.workGoals.append(.init(text: "North star", horizon: "gone",
                                      reinforcedToday: true, expired: true))

        let merged = existing.merging(update, dreamDay: "2026-07-18",
                                      at: try date("2026-07-19T04:01:00Z"),
                                      calendar: calendar)

        XCTAssertTrue(merged.activeProjects.contains { $0.name == "Anchor" })
        XCTAssertTrue(merged.workGoals.contains { $0.text == "North star" })
        XCTAssertLessThanOrEqual(merged.activeProjects.count, DreamMemory.maxProjects)
        XCTAssertLessThanOrEqual(merged.workGoals.count, DreamMemory.maxGoals)
    }

    func testLegacyMemoryFilesWithoutPinnedKeyStillDecode() throws {
        let legacy = Data("""
        {"version": 1, "updatedAt": "2026-07-19T04:01:00Z", "lastDreamDay": "2026-07-18",
         "activeProjects": [{"name": "Atlas", "status": "in review",
                             "lastActiveDay": "2026-07-18", "evidence": []}],
         "workGoals": [{"text": "Ship 0.5", "horizon": "next week",
                        "lastReinforcedDay": "2026-07-18"}],
         "recurringPatterns": []}
        """.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let memory = try decoder.decode(DreamMemory.self, from: legacy)
        XCTAssertEqual(memory.activeProjects.first?.pinned, false)
        XCTAssertEqual(memory.workGoals.first?.pinned, false)
    }

    func testMarkdownMarksPinnedEntries() throws {
        let memory = DreamMemory(
            updatedAt: try date("2026-07-19T04:01:00Z"),
            activeProjects: [.init(name: "Anchor", status: "long-running",
                                   lastActiveDay: "2026-07-18", evidence: [],
                                   pinned: true)],
            workGoals: [.init(text: "North star", horizon: "always",
                              lastReinforcedDay: "2026-07-18", pinned: true)])
        let markdown = memory.markdown()
        let pinMentions = markdown.components(separatedBy: "pinned").count - 1
        XCTAssertEqual(pinMentions, 2)
    }

    func testStorePersistsProjectAndGoalPins() throws {
        let store = DreamStore(root: try temporaryRoot())
        let initial = DreamMemory(
            updatedAt: try date("2026-07-19T04:01:00Z"),
            activeProjects: [.init(name: "Anchor", status: "long-running",
                                   lastActiveDay: "2026-07-18")],
            workGoals: [.init(text: "North star", horizon: "always",
                              lastReinforcedDay: "2026-07-18")])
        try store.save(initial)

        let projectUpdate = try XCTUnwrap(store.setPinned(
            true,
            for: .project(name: "anchor"),
            at: try date("2026-07-19T05:00:00Z")))
        XCTAssertTrue(try XCTUnwrap(projectUpdate.activeProjects.first).pinned)

        let goalUpdate = try XCTUnwrap(store.setPinned(
            true,
            for: .goal(text: "north star"),
            at: try date("2026-07-19T05:01:00Z")))
        XCTAssertTrue(try XCTUnwrap(goalUpdate.workGoals.first).pinned)

        let reloaded = try XCTUnwrap(store.loadMemory())
        XCTAssertTrue(try XCTUnwrap(reloaded.activeProjects.first).pinned)
        XCTAssertTrue(try XCTUnwrap(reloaded.workGoals.first).pinned)
        XCTAssertEqual(reloaded.updatedAt, try date("2026-07-19T05:01:00Z"))
    }

    // MARK: - Power gate

    func testDreamingRequiresACPowerAndNormalPowerMode() {
        XCTAssertTrue(DreamScheduler.powerAllowsDreaming(
            isOnBattery: false, isLowPower: false))
        XCTAssertFalse(DreamScheduler.powerAllowsDreaming(
            isOnBattery: true, isLowPower: false))
        XCTAssertFalse(DreamScheduler.powerAllowsDreaming(
            isOnBattery: false, isLowPower: true))
    }

    // MARK: - Headless flag

    func testHeadlessDreamFlagParsesOptionalDay() {
        XCTAssertEqual(HeadlessCommand.parse(["LokalBot", "--dream"]),
                       .dream(dayKey: nil))
        XCTAssertEqual(HeadlessCommand.parse(["LokalBot", "--dream", "2026-07-18"]),
                       .dream(dayKey: "2026-07-18"))
        // A following flag is not a day key.
        XCTAssertEqual(HeadlessCommand.parse(["LokalBot", "--dream", "--verbose"]),
                       .dream(dayKey: nil))
    }

    func testHeadlessDigestFlagParsesOptionalDay() {
        XCTAssertEqual(HeadlessCommand.parse(["LokalBot", "--digest"]),
                       .digest(dayKey: nil))
        XCTAssertEqual(HeadlessCommand.parse(["LokalBot", "--digest", "2026-08-04"]),
                       .digest(dayKey: "2026-08-04"))
        XCTAssertEqual(HeadlessCommand.parse(["LokalBot", "--digest", "--verbose"]),
                       .digest(dayKey: nil))
    }

    func testHeadlessDreamTargetDefaultsToYesterdayAndAcceptsOlderDays() throws {
        let now = try date("2026-07-20T12:00:00Z")
        let defaultTarget = try HeadlessCommand.validatedDreamTarget(
            dayKey: nil,
            now: now,
            calendar: calendar)
        XCTAssertEqual(defaultTarget.dayKey, "2026-07-19")

        let historicalTarget = try HeadlessCommand.validatedDreamTarget(
            dayKey: "2026-07-18",
            now: now,
            calendar: calendar)
        XCTAssertEqual(historicalTarget.dayKey, "2026-07-18")
    }

    func testHeadlessDreamTargetRejectsCurrentAndFutureDays() throws {
        let now = try date("2026-07-20T12:00:00Z")
        for dayKey in ["2026-07-20", "2026-07-21"] {
            XCTAssertThrowsError(try HeadlessCommand.validatedDreamTarget(
                dayKey: dayKey,
                now: now,
                calendar: calendar)) { error in
                    XCTAssertEqual(error as? DreamDayArgumentError, .notHistorical(dayKey))
                }
        }
    }

    func testHeadlessDreamTargetRejectsNonCanonicalDay() throws {
        XCTAssertThrowsError(try HeadlessCommand.validatedDreamTarget(
            dayKey: "2026-7-18",
            now: try date("2026-07-20T12:00:00Z"),
            calendar: calendar)) { error in
                XCTAssertEqual(error as? DreamDayArgumentError, .invalidFormat("2026-7-18"))
            }
    }

    // MARK: - Redaction

    func testRedactionScrubsCredentialsFromReportAndMemory() throws {
        let report = DreamReport(
            day: "2026-07-18",
            generatedAt: try date("2026-07-19T04:01:00Z"),
            engineName: "Built-in — Test",
            narrative: "Saw password: hunter2secret in a screenshot.",
            topActions: ["Rotate api_key = sk-abcdef1234567890abcd"]).redacted()
        XCTAssertFalse(report.narrative.contains("hunter2secret"))
        XCTAssertTrue(report.narrative.contains("[REDACTED]"))
        XCTAssertFalse(try XCTUnwrap(report.topActions.first).contains("sk-abcdef"))

        let memory = DreamMemory(
            updatedAt: try date("2026-07-19T04:01:00Z"),
            activeProjects: [.init(name: "Atlas", status: "token ghp_0123456789abcdefghij noted",
                                   lastActiveDay: "2026-07-18", evidence: [])]).redacted()
        XCTAssertFalse(try XCTUnwrap(memory.activeProjects.first).status.contains("ghp_"))
    }
}
