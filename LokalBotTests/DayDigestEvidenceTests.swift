import XCTest
@testable import LokalBot

final class DayDigestEvidenceTests: XCTestCase {
    /// Digest times were written with a new `DateFormatter` each; the
    /// calendar's own hour and minute must read the same everywhere.
    func testClockStampMatchesAPOSIXFormatterAcrossCalendarsAndTimeZones() throws {
        let zones = ["UTC", "Europe/Podgorica", "America/St_Johns", "Asia/Kathmandu", "Pacific/Chatham"]
        let calendars: [Calendar.Identifier] = [.gregorian, .buddhist, .japanese, .persian, .hebrew, .islamicUmmAlQura]
        // Every 37 minutes across the 2026 spring clock change, and one day in each season.
        let starts = [1_774_656_000.0, 1_782_000_000, 1_792_800_000, 1_767_225_600]
        for zone in zones {
            for identifier in calendars {
                var calendar = Calendar(identifier: identifier)
                calendar.timeZone = try XCTUnwrap(TimeZone(identifier: zone))
                let formatter = DateFormatter()
                formatter.calendar = calendar
                formatter.timeZone = calendar.timeZone
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = "HH:mm"
                for start in starts {
                    for step in 0..<120 {
                        let date = Date(timeIntervalSince1970: start + Double(step) * 37 * 60)
                        XCTAssertEqual(calendar.clockStamp(date), formatter.string(from: date),
                                       "\(zone) \(identifier) \(date.timeIntervalSince1970)")
                    }
                }
            }
        }
    }

    private actor GenerationRecorder {
        struct Call: Equatable, Sendable {
            var isFocus: Bool
            var maxTokens: Int?
            var reasoningBudgetTokens: Int?
            var temperature: Double?
        }

        private(set) var calls: [Call] = []
        private(set) var aggregationPrompts: [String] = []

        func record(isFocus: Bool, options: TextGenerationOptions, prompt: String = "") -> Int {
            if !isFocus { aggregationPrompts.append(prompt) }
            calls.append(Call(
                isFocus: isFocus,
                maxTokens: options.maxTokens,
                reasoningBudgetTokens: options.reasoningBudgetTokens,
                temperature: options.temperature))
            return calls.filter { $0.isFocus == isFocus }.count
        }
    }

    private actor SleepRecorder {
        private(set) var delays: [TimeInterval] = []
        func record(_ delay: TimeInterval) { delays.append(delay) }
    }

    private struct StructuredDigestEngine: TextEngine {
        let recorder: GenerationRecorder
        var invalidFirstFocus = false
        var alwaysInvalidFocus = false
        var failedFocusCalls: Set<Int> = []
        var failedFinalCalls: Set<Int> = []
        var focusHTTPStatus: [Int: Int] = [:]
        var finalHTTPStatus: [Int: Int] = [:]
        var truncatedFocusCalls: Set<Int> = []
        var truncatedFinalCalls: Set<Int> = []
        var invalidFinal = false
        var nonSubstantiveFocusIndices: Set<Int> = []
        var bestAvailableFocusIndices: Set<Int> = []
        var focusResponses: [Int: String] = [:]
        var finalResponse: String?
        var displayName: String { "structured-test" }

        func generate(system: String, prompt: String, context: [String]) async throws -> String {
            "unused"
        }

        func generate(system: String, prompt: String, context: [String],
                      schema: [String: Any],
                      options: TextGenerationOptions) async throws -> String {
            let isFocus = system == PromptTemplates.dayDigestFocusSystem
            let index = await recorder.record(isFocus: isFocus, options: options, prompt: prompt)
            if isFocus {
                if failedFocusCalls.contains(index) {
                    throw TextEngineError.serverUnreachable(
                        "http://127.0.0.1:17872/v1",
                        transportCode: URLError.networkConnectionLost.rawValue)
                }
                if let code = focusHTTPStatus[index] {
                    throw TextEngineError.httpStatus(
                        code: code, detail: "Provider returned error", retryAfter: nil)
                }
                if truncatedFocusCalls.contains(index) {
                    throw TextEngineError.outputTruncated
                }
                if alwaysInvalidFocus || (invalidFirstFocus && index == 1) {
                    return "not valid JSON"
                }
                if nonSubstantiveFocusIndices.contains(index) {
                    return """
                        {"substantive":false,"task":"","work_done":"","status":"unknown","outcome":"","next_step":"","source_ids":[]}
                        """
                }
                if let response = focusResponses[index] { return response }
                if bestAvailableFocusIndices.contains(index) {
                    return """
                        {"substantive":false,"task":"Protocol research","work_done":"Reviewed material about a protocol without reaching a visible conclusion.","status":"unknown","outcome":"","next_step":"","source_ids":[]}
                        """
                }
                return """
                    {"substantive":true,"task":"Task \(index)","work_done":"Advanced substantive work for task \(index).","status":"in_progress","outcome":"Useful progress was recorded.","next_step":"","source_ids":[]}
                    """
            }
            if failedFinalCalls.contains(index) {
                throw TextEngineError.serverUnreachable(
                    "http://127.0.0.1:17872/v1",
                    transportCode: URLError.networkConnectionLost.rawValue)
            }
            if let code = finalHTTPStatus[index] {
                throw TextEngineError.httpStatus(
                    code: code, detail: "Provider returned error", retryAfter: nil)
            }
            if truncatedFinalCalls.contains(index) {
                throw TextEngineError.outputTruncated
            }
            if invalidFinal { return "not valid JSON" }
            if let finalResponse { return finalResponse }
            return """
                {
                  "tasks": [
                    {"title":"Task 1","status":"in_progress","summary":"Advanced the first substantive task.","next_step":"","block_indices":[0]},
                    {"title":"Task 2","status":"completed","summary":"Completed the second substantive task.","next_step":"","block_indices":[1]},
                    {"title":"Task 3","status":"completed","summary":"Completed the third substantive task.","next_step":"","block_indices":[2]}
                  ],
                  "decisions": [],
                  "blockers": []
                }
                """
        }
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private var day: Date {
        calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 4, hour: 12))!
    }

    private func time(_ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 4, hour: hour, minute: minute))!
    }

    private func block(_ id: Int64, _ hour: Int, _ title: String) -> ActivityBlock {
        ActivityBlock(
            id: id,
            app: id == 2 ? "Safari" : "Xcode",
            title: title,
            start: time(hour),
            end: time(hour, 45))
    }

    private func block(
        _ id: Int64,
        startHour: Int,
        startMinute: Int = 0,
        endHour: Int,
        endMinute: Int = 0,
        title: String,
        app: String
    ) -> ActivityBlock {
        ActivityBlock(
            id: id,
            app: app,
            title: title,
            start: time(startHour, startMinute),
            end: time(endHour, endMinute))
    }

    private func context(_ id: Int64, _ hour: Int, _ minute: Int,
                         _ text: String, app: String = "Xcode") -> DayScreenContext {
        DayScreenContext(
            snapshotID: id,
            capturedAt: time(hour, minute),
            app: app,
            windowTitle: "Work window",
            text: text)
    }

    func testDocumentListsEveryActivityBlockOnceInChronologicalOrder() {
        let blocks = [
            block(3, 17, "Release verification"),
            block(1, 9, "DayDigestEvidence.swift"),
            block(2, 13, "Issue research"),
        ]
        let contexts = [
            context(33, 17, 20, "Gatekeeper verification passed"),
            context(11, 9, 10, "Implemented the evidence builder"),
            context(22, 13, 15, "Read the failure report", app: "Safari"),
        ]
        let meeting = DayDigestMeetingEvidence(
            id: UUID(),
            title: "Launch sync",
            app: "Zoom",
            startedAt: time(15),
            endedAt: time(15, 30),
            sourceSummary: "Reviewed launch status.",
            outcomes: "Decision: ship after verification.",
            artifactModifiedAt: nil)
        let evidence = DayDigestEvidence.build(
            day: day,
            blocks: blocks,
            screenContexts: contexts,
            meetings: [meeting],
            calendar: calendar)

        let document = evidence.renderDocument(
            summary: "### Overview\nA grounded overview.", calendar: calendar)

        XCTAssertTrue(document.contains("## Day summary"))
        XCTAssertTrue(document.contains("## Full activity log"))
        XCTAssertTrue(document.contains("## Meetings"))
        XCTAssertTrue(document.contains("## Time allocation"))
        XCTAssertEqual(occurrences(of: "DayDigestEvidence.swift", in: document), 1)
        XCTAssertEqual(occurrences(of: "Issue research", in: document), 1)
        XCTAssertEqual(occurrences(of: "Release verification", in: document), 1)
        XCTAssertTrue(document.contains("[screen:11]"))
        XCTAssertTrue(document.contains("[screen:22]"))
        XCTAssertTrue(document.contains("[screen:33]"))

        let morning = document.range(of: "DayDigestEvidence.swift")!.lowerBound
        let middle = document.range(of: "Issue research")!.lowerBound
        let evening = document.range(of: "Release verification")!.lowerBound
        XCTAssertLessThan(morning, middle)
        XCTAssertLessThan(middle, evening)

        let meetings = document.range(of: "## Meetings")!.lowerBound
        let allocation = document.range(of: "## Time allocation")!.lowerBound
        let activity = document.range(of: "## Full activity log")!.lowerBound
        XCTAssertLessThan(meetings, allocation)
        XCTAssertLessThan(allocation, activity)
    }

    func testSummaryChunksCoverBeginningMiddleAndEndWithinBudget() {
        let evidence = DayDigestEvidence.build(
            day: day,
            blocks: [
                block(1, 8, "Morning implementation"),
                block(2, 13, "Midday investigation"),
                block(3, 19, "Evening verification"),
            ],
            screenContexts: [
                context(1, 8, 10, String(repeating: "morning detail ", count: 30)),
                context(2, 13, 10, String(repeating: "midday detail ", count: 30)),
                context(3, 19, 10, String(repeating: "evening detail ", count: 30)),
            ],
            meetings: [],
            calendar: calendar)

        let chunks = evidence.summaryChunks(maxCharacters: 240)
        let all = chunks.joined(separator: "\n")

        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 240 })
        XCTAssertTrue(all.contains("Morning implementation"))
        XCTAssertTrue(all.contains("Midday investigation"))
        XCTAssertTrue(all.contains("Evening verification"))
    }

    func testSummarySegmentsCreateHardBoundariesAcrossIdleGaps() {
        let evidence = DayDigestEvidence.build(
            day: day,
            blocks: [
                block(1, 8, "Morning implementation"),
                block(2, 13, "Midday investigation"),
                block(3, 19, "Evening verification"),
            ],
            screenContexts: [
                context(11, 8, 10, "morning evidence"),
                context(22, 13, 10, "midday evidence"),
                context(33, 19, 10, "evening evidence"),
            ],
            meetings: [],
            calendar: calendar)

        let segments = evidence.summarySegments(maxCharacters: 12_000)

        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(segments.map(\.sourceIDs), [[11], [22], [33]])
        XCTAssertTrue(segments[0].evidence.contains("Morning implementation"))
        XCTAssertTrue(segments[1].evidence.contains("Midday investigation"))
        XCTAssertTrue(segments[2].evidence.contains("Evening verification"))
    }

    func testBriefSubstantiveTaskCanOutrankLongerWork() async throws {
        let evidence = DayDigestEvidence.build(
            day: day,
            blocks: [
                block(
                    1,
                    startHour: 9,
                    endHour: 14,
                    title: "Main project work",
                    app: "Xcode"),
                block(
                    2,
                    startHour: 16,
                    endHour: 16,
                    endMinute: 5,
                    title: "Invoice payment",
                    app: "Safari"),
            ],
            screenContexts: [],
            meetings: [],
            calendar: calendar)

        let segments = evidence.summarySegments()
        let expectedDurations: [TimeInterval] = [5 * 60 * 60, 5 * 60]

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments.map(\.activeDuration), expectedDurations)

        let recorder = GenerationRecorder()
        let finalResponse = """
            {"tasks":[{"title":"Invoice reconciliation","status":"completed","summary":"Paid the outstanding supplier invoice.","next_step":"","block_indices":[1]},{"title":"Main project","status":"in_progress","summary":"Advanced the main project implementation.","next_step":"Continue implementation.","block_indices":[0]}],"decisions":[],"blockers":[]}
            """
        let overview = try await DayDigestOverviewGenerator.generate(
            evidence: evidence,
            engine: StructuredDigestEngine(
                recorder: recorder,
                finalResponse: finalResponse),
            customPrompt: "",
            calendar: calendar)
        let document = evidence.renderDocument(summary: overview, calendar: calendar)
        let presentation = DayDigestPresentation(markdown: document)

        XCTAssertEqual(
            presentation.focusBlocks.map(\.title),
            ["Invoice reconciliation", "Main project"])
        XCTAssertTrue(presentation.otherActivityBlocks.isEmpty)
        XCTAssertTrue(presentation.atAGlanceMarkdown.isEmpty)
        let invoice = overview.range(of: "Invoice reconciliation")!.lowerBound
        let project = overview.range(of: "Main project")!.lowerBound
        XCTAssertLessThan(invoice, project)
        XCTAssertEqual(presentation.focusBlocks[1].nextStep, "Continue implementation.")
        XCTAssertFalse(presentation.focusBlocks[1].summaryMarkdown.contains(
            "Continue implementation"))
        XCTAssertTrue(document.contains("Invoice payment"))
    }

    func testSegmentLimitPreservesLongAndBriefSessions() {
        var briefBlocks: [ActivityBlock] = []
        for index in 0..<7 {
            briefBlocks.append(block(
                Int64(index + 2),
                startHour: 10 + index,
                endHour: 10 + index,
                endMinute: 5,
                title: "Brief task \(index + 1)",
                app: "Safari"))
        }
        let evidence = DayDigestEvidence.build(
            day: day,
            blocks: [
                block(
                    1,
                    startHour: 8,
                    endHour: 8,
                    endMinute: 40,
                    title: "Main project work",
                    app: "Xcode"),
            ] + briefBlocks,
            screenContexts: [],
            meetings: [],
            calendar: calendar)

        let segments = evidence.summarySegments()

        XCTAssertEqual(segments.count, 8)
        XCTAssertEqual(segments.first?.activeDuration, 40 * 60)
        XCTAssertTrue(segments.dropFirst().allSatisfy { $0.activeDuration == 5 * 60 })
    }

    func testLongActivityReceivesBroaderScreenCoverageThanBriefActivity() {
        var longContexts: [DayScreenContext] = []
        for index in 0..<10 {
            longContexts.append(context(
                Int64(100 + index),
                9 + index / 2,
                (index % 2) * 30,
                "main project evidence \(index)"))
        }
        var briefContexts: [DayScreenContext] = []
        for index in 0..<5 {
            briefContexts.append(context(
                Int64(200 + index),
                16,
                index,
                "invoice evidence \(index)",
                app: "Safari"))
        }
        let evidence = DayDigestEvidence.build(
            day: day,
            blocks: [
                block(
                    1,
                    startHour: 9,
                    endHour: 14,
                    title: "Main project work",
                    app: "Xcode"),
                block(
                    2,
                    startHour: 16,
                    endHour: 16,
                    endMinute: 5,
                    title: "Invoice payment",
                    app: "Safari"),
            ],
            screenContexts: longContexts + briefContexts,
            meetings: [],
            calendar: calendar)

        let segments = evidence.summarySegments()

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].sourceIDs.count, 10)
        XCTAssertEqual(segments[1].sourceIDs.count, 2)
        XCTAssertEqual(occurrences(of: "Screen context [screen:", in: segments[0].evidence), 10)
        XCTAssertEqual(occurrences(of: "Screen context [screen:", in: segments[1].evidence), 2)
        XCTAssertTrue(segments[0].evidence.contains("main project evidence 0"))
        XCTAssertTrue(segments[0].evidence.contains("main project evidence 9"))
        XCTAssertTrue(segments[1].evidence.contains("invoice evidence 0"))
        XCTAssertTrue(segments[1].evidence.contains("invoice evidence 4"))
    }

    func testMeetingDetailSurvivesBusySegmentSampling() {
        var blocks: [ActivityBlock] = []
        for index in 0..<24 {
            blocks.append(ActivityBlock(
                id: Int64(index + 1),
                app: "Safari",
                title: "Activity \(index)",
                start: time(9, index),
                end: time(9, index + 1)))
        }
        let meeting = DayDigestMeetingEvidence(
            id: UUID(),
            title: "Architecture sync",
            app: "Zoom",
            startedAt: time(9, 8),
            endedAt: time(9, 9),
            sourceSummary: "## TL;DR\nKept the critical meeting detail visible.",
            outcomes: "Decision: retain the meeting evidence.",
            artifactModifiedAt: nil)
        let evidence = DayDigestEvidence.build(
            day: day,
            blocks: blocks,
            screenContexts: [],
            meetings: [meeting],
            calendar: calendar)

        let segments = evidence.summarySegments(maxSegments: 1)

        XCTAssertEqual(segments.count, 1)
        XCTAssertTrue(segments[0].evidence.contains(
            "Kept the critical meeting detail visible."))
    }

    func testMeetingOutcomesLeadAndTheSummaryHeaderIsDroppedInBusySegments() {
        var blocks: [ActivityBlock] = []
        for index in 0..<24 {
            blocks.append(ActivityBlock(
                id: Int64(index + 1),
                app: "Safari",
                title: "Activity \(index)",
                start: time(9, index),
                end: time(9, index + 1)))
        }
        var summary = "# Architecture sync — Oct 2\n"
            + "**Duration:** 45m · **App:** Zoom · **Words:** 5,210 · **Template:** Meeting · **Model:** Qwen3.5 4B\n\n"
            + "## TL;DR\n"
        for index in 0..<40 {
            summary += "- Long discussion point \(index) about the storage layer and its migration plan.\n"
        }
        let meeting = DayDigestMeetingEvidence(
            id: UUID(),
            title: "Architecture sync",
            app: "Zoom",
            startedAt: time(9, 8),
            endedAt: time(9, 9),
            sourceSummary: summary,
            outcomes: "Action items:\n- [ ] Send the migration deck (owner: Me)",
            artifactModifiedAt: nil)
        let evidence = DayDigestEvidence.build(
            day: day,
            blocks: blocks,
            screenContexts: [],
            meetings: [meeting],
            calendar: calendar)

        let segments = evidence.summarySegments(maxSegments: 1)

        XCTAssertEqual(segments.count, 1)
        XCTAssertTrue(segments[0].evidence.contains("Send the migration deck"), "actions survive a busy segment")
        XCTAssertFalse(segments[0].evidence.contains("**Duration:**"))
    }

    func testOverviewGeneratorExtractsEverySegmentBeforeTaskAggregation() async throws {
        let evidence = DayDigestEvidence.build(
            day: day,
            blocks: [
                block(1, 8, "Morning implementation"),
                block(2, 13, "Midday investigation"),
                block(3, 19, "Evening verification"),
            ],
            screenContexts: [],
            meetings: [],
            calendar: calendar)
        let recorder = GenerationRecorder()

        let overview = try await DayDigestOverviewGenerator.generate(
            evidence: evidence,
            engine: StructuredDigestEngine(recorder: recorder),
            customPrompt: "",
            calendar: calendar)

        XCTAssertTrue(overview.contains("**Task 1**"))
        XCTAssertTrue(overview.contains("**Task 2**"))
        XCTAssertTrue(overview.contains("**Task 3**"))
        XCTAssertFalse(overview.contains("08:00–08:45"))
        let calls = await recorder.calls
        XCTAssertEqual(calls.count, 4)
        XCTAssertTrue(calls.prefix(3).allSatisfy {
            $0.isFocus && $0.maxTokens == 2_048
                && $0.reasoningBudgetTokens == 256 && $0.temperature == 0.2
        })
        XCTAssertEqual(calls.last, GenerationRecorder.Call(
            isFocus: false,
            maxTokens: 1_600,
            reasoningBudgetTokens: 512,
            temperature: 0.2))
    }

    func testOverviewGeneratorRetriesOneInvalidFocusResponse() async throws {
        let evidence = DayDigestEvidence.build(
            day: day,
            blocks: [block(1, 8, "Morning implementation")],
            screenContexts: [],
            meetings: [],
            calendar: calendar)
        let recorder = GenerationRecorder()

        let overview = try await DayDigestOverviewGenerator.generate(
            evidence: evidence,
            engine: StructuredDigestEngine(
                recorder: recorder,
                invalidFirstFocus: true,
                invalidFinal: true),
            customPrompt: "",
            calendar: calendar)

        XCTAssertTrue(overview.contains("**Task 2**"))
        XCTAssertFalse(overview.localizedCaseInsensitiveContains("recorded activity"))
        let calls = await recorder.calls
        XCTAssertEqual(calls.count, 3)
        XCTAssertEqual(calls[1], GenerationRecorder.Call(
            isFocus: true,
            maxTokens: 4_096,
            reasoningBudgetTokens: 0,
            temperature: 0))
    }

    func testOverviewGeneratorRetriesTruncatedFocusWithLargerBudget() async throws {
        let evidence = DayDigestEvidence.build(
            day: day,
            blocks: [block(1, 8, "Morning implementation")],
            screenContexts: [],
            meetings: [],
            calendar: calendar)
        let recorder = GenerationRecorder()

        let overview = try await DayDigestOverviewGenerator.generate(
            evidence: evidence,
            engine: StructuredDigestEngine(
                recorder: recorder,
                truncatedFocusCalls: [1],
                invalidFinal: true),
            customPrompt: "",
            calendar: calendar)

        XCTAssertTrue(overview.contains("**Task 2**"))
        let calls = await recorder.calls
        XCTAssertEqual(calls.count, 3)
        XCTAssertEqual(calls[1], GenerationRecorder.Call(
            isFocus: true,
            maxTokens: 4_096,
            reasoningBudgetTokens: 0,
            temperature: 0))
    }

    func testOverviewGeneratorContinuesAfterTruncationRetryIsExhausted() async throws {
        let evidence = DayDigestEvidence.build(
            day: day,
            blocks: [
                block(1, 8, "Morning implementation"),
                block(2, 13, "Midday investigation"),
            ],
            screenContexts: [],
            meetings: [],
            calendar: calendar)
        let recorder = GenerationRecorder()

        let overview = try await DayDigestOverviewGenerator.generate(
            evidence: evidence,
            engine: StructuredDigestEngine(
                recorder: recorder,
                truncatedFocusCalls: [1, 2],
                invalidFinal: true),
            customPrompt: "",
            calendar: calendar)

        XCTAssertTrue(overview.contains("**Task 3**"))
        let calls = await recorder.calls
        XCTAssertEqual(calls.count, 4)
        XCTAssertTrue(calls.last?.isFocus == false)
    }

    func testOverviewResultPreservesCompletedSegmentsAfterTransportRecoveryExhausts() async throws {
        let evidence = DayDigestEvidence.build(
            day: day,
            blocks: [
                block(1, 8, "Morning implementation"),
                block(2, 13, "Midday investigation"),
            ],
            screenContexts: [],
            meetings: [],
            calendar: calendar)
        let recorder = GenerationRecorder()

        let result = try await DayDigestOverviewGenerator.generateResult(
            evidence: evidence,
            engine: StructuredDigestEngine(
                recorder: recorder,
                failedFocusCalls: [2, 3]),
            customPrompt: "",
            calendar: calendar,
            sleep: { _ in })

        XCTAssertEqual(result.quality, .partial)
        XCTAssertTrue(result.summary.contains("**Task 1**"))
        XCTAssertFalse(result.summary.contains("**Task 2**"))
        XCTAssertFalse(result.summary.contains("**Task 3**"))
        let calls = await recorder.calls
        XCTAssertEqual(calls.count, 4)
    }

    func testOverviewResultFallsBackWhenFirstTransportRecoveryExhausts() async throws {
        let evidence = DayDigestEvidence.build(
            day: day,
            blocks: [block(1, 8, "Morning implementation")],
            screenContexts: [],
            meetings: [],
            calendar: calendar)
        let recorder = GenerationRecorder()

        let result = try await DayDigestOverviewGenerator.generateResult(
            evidence: evidence,
            engine: StructuredDigestEngine(
                recorder: recorder,
                failedFocusCalls: [1, 2]),
            customPrompt: "",
            calendar: calendar,
            sleep: { _ in })

        XCTAssertEqual(result.quality, .fallback)
        XCTAssertTrue(result.summary.contains("**Morning implementation**"))
        let calls = await recorder.calls
        XCTAssertEqual(calls.count, 2)
    }

    func testOverviewResultKeepsExtractedTasksWhenAggregationRecoveryExhausts() async throws {
        let evidence = DayDigestEvidence.build(
            day: day,
            blocks: [block(1, 8, "Morning implementation")],
            screenContexts: [],
            meetings: [],
            calendar: calendar)
        let recorder = GenerationRecorder()

        let result = try await DayDigestOverviewGenerator.generateResult(
            evidence: evidence,
            engine: StructuredDigestEngine(
                recorder: recorder,
                failedFinalCalls: [1, 2]),
            customPrompt: "",
            calendar: calendar,
            sleep: { _ in })

        XCTAssertEqual(result.quality, .partial)
        XCTAssertTrue(result.summary.contains("**Task 1**"))
        let calls = await recorder.calls
        XCTAssertEqual(calls.count, 3)
    }

    func testOverviewGeneratorReplaysSegmentOnceAfterProviderError() async throws {
        let evidence = DayDigestEvidence.build(
            day: day,
            blocks: [
                block(1, 8, "Morning implementation"),
                block(2, 13, "Midday investigation"),
            ],
            screenContexts: [],
            meetings: [],
            calendar: calendar)
        let recorder = GenerationRecorder()
        let sleeps = SleepRecorder()

        let result = try await DayDigestOverviewGenerator.generateResult(
            evidence: evidence,
            engine: StructuredDigestEngine(
                recorder: recorder,
                focusHTTPStatus: [2: 503],
                finalResponse: """
                    {"tasks":[{"title":"Task 1","status":"completed","summary":"Completed the first task.","next_step":"","block_indices":[0]},{"title":"Task 3","status":"completed","summary":"Completed the replayed task.","next_step":"","block_indices":[1]}],"decisions":[],"blockers":[]}
                    """),
            customPrompt: "",
            calendar: calendar,
            sleep: { await sleeps.record($0) })

        XCTAssertEqual(result.quality, .complete)
        XCTAssertTrue(result.summary.contains("**Task 3**"))
        let calls = await recorder.calls
        XCTAssertEqual(calls.count, 4)
        XCTAssertEqual(calls[1], calls[2])
        let delays = await sleeps.delays
        XCTAssertEqual(delays.count, 1)
        XCTAssertTrue((1...1.5).contains(delays[0]))
    }

    func testOverviewGeneratorReplaysAggregationOnceAfterProviderError() async throws {
        let evidence = DayDigestEvidence.build(
            day: day,
            blocks: [block(1, 8, "Morning implementation")],
            screenContexts: [],
            meetings: [],
            calendar: calendar)
        let recorder = GenerationRecorder()

        let result = try await DayDigestOverviewGenerator.generateResult(
            evidence: evidence,
            engine: StructuredDigestEngine(
                recorder: recorder,
                finalHTTPStatus: [1: 503]),
            customPrompt: "",
            calendar: calendar,
            sleep: { _ in })

        XCTAssertEqual(result.quality, .complete)
        XCTAssertTrue(result.summary.contains("**Task 1**"))
        let calls = await recorder.calls
        XCTAssertEqual(calls.count, 3)
        XCTAssertEqual(calls[1], calls[2])
    }

    func testOverviewGeneratorDoesNotReplayPermanentProviderError() async throws {
        let evidence = DayDigestEvidence.build(
            day: day,
            blocks: [block(1, 8, "Morning implementation")],
            screenContexts: [],
            meetings: [],
            calendar: calendar)
        let recorder = GenerationRecorder()
        let sleeps = SleepRecorder()

        let result = try await DayDigestOverviewGenerator.generateResult(
            evidence: evidence,
            engine: StructuredDigestEngine(
                recorder: recorder,
                focusHTTPStatus: [1: 401]),
            customPrompt: "",
            calendar: calendar,
            sleep: { await sleeps.record($0) })

        XCTAssertEqual(result.quality, .fallback)
        let calls = await recorder.calls
        XCTAssertEqual(calls.count, 1)
        let delays = await sleeps.delays
        XCTAssertTrue(delays.isEmpty)
    }

    func testCoverageCountsOnlySegmentsThatReachedTheSummary() async throws {
        let evidence = DayDigestEvidence.build(
            day: day,
            blocks: [block(1, 8, "Morning implementation"), block(2, 13, "Midday investigation")],
            screenContexts: [],
            meetings: [],
            calendar: calendar)
        let recorder = GenerationRecorder()

        let result = try await DayDigestOverviewGenerator.generateResult(
            evidence: evidence,
            engine: StructuredDigestEngine(recorder: recorder, truncatedFocusCalls: [2, 3]),
            customPrompt: "",
            calendar: calendar,
            sleep: { _ in })

        let coverage = try XCTUnwrap(result.coverage)
        let segments = evidence.summarySegments()
        XCTAssertEqual(coverage.trackedSeconds, segments.reduce(0) { $0 + $1.activeDuration }, accuracy: 0.5)
        XCTAssertEqual(coverage.coveredSeconds, segments[0].activeDuration, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(coverage.ratio), 0.5, accuracy: 0.01)
    }

    func testMetadataPersistsCoverageAndOldFilesDecodeWithoutIt() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("coverage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let journal = folder.appendingPathComponent("2026-08-04.md")
        try Data("digest".utf8).write(to: journal)
        let coverage = DayDigestCoverage(coveredSeconds: 3_600, trackedSeconds: 7_200)

        try DayDigestGenerationMetadataStore.record(
            quality: .complete, evidenceLatestAt: nil, coverage: coverage, for: journal)
        XCTAssertEqual(DayDigestGenerationMetadataStore.loadWithoutRecovery(for: journal)?.coverage, coverage)

        let legacy = #"{"version":2,"quality":"complete","generatedAt":0,"journalModifiedAt":0,"degradedAttemptCount":0}"#
        try Data(legacy.utf8).write(to: DayDigestGenerationMetadataStore.metadataURL(for: journal))
        XCTAssertNil(DayDigestGenerationMetadataStore.loadWithoutRecovery(for: journal)?.coverage)
        XCTAssertNotNil(DayDigestGenerationMetadataStore.loadWithoutRecovery(for: journal))
    }

    func testOverviewGeneratorRetriesTruncatedAggregationWithoutReasoning() async throws {
        let evidence = DayDigestEvidence.build(
            day: day,
            blocks: [block(1, 8, "Morning implementation")],
            screenContexts: [],
            meetings: [],
            calendar: calendar)
        let recorder = GenerationRecorder()

        let overview = try await DayDigestOverviewGenerator.generate(
            evidence: evidence,
            engine: StructuredDigestEngine(
                recorder: recorder,
                truncatedFinalCalls: [1]),
            customPrompt: "",
            calendar: calendar)

        XCTAssertTrue(overview.contains("**Task 1**"))
        let calls = await recorder.calls
        XCTAssertEqual(calls.count, 3)
        XCTAssertEqual(calls.last, GenerationRecorder.Call(
            isFocus: false,
            maxTokens: 3_200,
            reasoningBudgetTokens: 0,
            temperature: 0))
    }

    func testBestAvailableActivityIsUsedWhenNoSubstantiveWorkIsFound() async throws {
        let evidence = DayDigestEvidence.build(
            day: day,
            blocks: [block(1, 9, "Protocol research")],
            screenContexts: [],
            meetings: [],
            calendar: calendar)
        let recorder = GenerationRecorder()

        let overview = try await DayDigestOverviewGenerator.generate(
            evidence: evidence,
            engine: StructuredDigestEngine(
                recorder: recorder,
                invalidFinal: true,
                bestAvailableFocusIndices: [1]),
            customPrompt: "",
            calendar: calendar)

        XCTAssertTrue(overview.contains("**Protocol research**"))
        XCTAssertTrue(overview.contains("Reviewed material about a protocol"))
        XCTAssertFalse(overview.contains("No substantive work"))
        let calls = await recorder.calls
        XCTAssertEqual(calls.count, 2)
    }

    func testLighterWorkFollowsSubstantiveTasksInsteadOfDisappearing() async throws {
        let evidence = DayDigestEvidence.build(
            day: day,
            blocks: [
                block(1, 9, "Implementation"),
                block(2, 17, "Protocol research"),
            ],
            screenContexts: [],
            meetings: [],
            calendar: calendar)
        let recorder = GenerationRecorder()

        let overview = try await DayDigestOverviewGenerator.generate(
            evidence: evidence,
            engine: StructuredDigestEngine(
                recorder: recorder,
                invalidFinal: true,
                bestAvailableFocusIndices: [2]),
            customPrompt: "",
            calendar: calendar)

        let substantive = try XCTUnwrap(overview.range(of: "**Task 1**"))
        let lighter = try XCTUnwrap(overview.range(of: "**Protocol research**"),
                                    "Identifiable lighter work stays in the digest")
        XCTAssertLessThan(substantive.lowerBound, lighter.lowerBound, "Substantive work leads")
        let calls = await recorder.calls
        XCTAssertEqual(calls.count, 3)
        let aggregationPrompts = await recorder.aggregationPrompts
        let aggregation = try XCTUnwrap(aggregationPrompts.last)
        XCTAssertTrue(aggregation.contains("Priority: primary\n  Task: Task 1"))
        XCTAssertTrue(aggregation.contains("Priority: secondary\n  Task: Protocol research"))
    }

    func testOneSegmentKeepsEachDistinctWorkItem() async throws {
        let evidence = DayDigestEvidence.build(
            day: day, blocks: [block(1, 9, "Implementation")], screenContexts: [], meetings: [], calendar: calendar)
        let recorder = GenerationRecorder()
        let focus = """
            {"substantive":true,"task":"Fix the login rate limiter","work_done":"Reset the counter after a successful login.","status":"completed","outcome":"","next_step":"","source_ids":[],"other_tasks":[
            {"substantive":true,"task":"Fix the login rate limiter","work_done":"Ran the limiter tests.","status":"completed","outcome":"","next_step":"","source_ids":[]},
            {"substantive":true,"task":"Review PR #118","work_done":"Requested changes to the proration rounding.","status":"in_progress","outcome":"","next_step":"","source_ids":[]},
            {"substantive":false,"task":"Reply to the Acme escalation","work_done":"Drafted a reply about the SAML certificate.","status":"in_progress","outcome":"","next_step":"","source_ids":[]}]}
            """

        let overview = try await DayDigestOverviewGenerator.generate(
            evidence: evidence,
            engine: StructuredDigestEngine(recorder: recorder, invalidFinal: true, focusResponses: [1: focus]),
            customPrompt: "",
            calendar: calendar)

        XCTAssertEqual(overview.components(separatedBy: "**Fix the login rate limiter**").count - 1, 1, overview)
        XCTAssertTrue(overview.contains("**Review PR #118**"), overview)
        XCTAssertTrue(overview.contains("**Reply to the Acme escalation**"), "A repeat of the main task uses no slot")
        let aggregationPrompts = await recorder.aggregationPrompts
        let aggregation = try XCTUnwrap(aggregationPrompts.last)
        XCTAssertTrue(aggregation.contains("Priority: secondary\n  Task: Reply to the Acme escalation"), aggregation)
    }

    func testFocusPromptCountsAIAssistedWorkAsSubstantive() {
        let prompt = PromptTemplates.dayDigestFocusSystem
        XCTAssertTrue(prompt.contains("Work done with an AI assistant or coding agent is the person's own work"))
        XCTAssertTrue(prompt.contains("describe that task and its result, not the assistant or the chat"))
        XCTAssertTrue(PromptTemplates.dayDigestSystem.contains("Priority: secondary"))
    }

    func testMetadataOnlySegmentUsesGenericRecordedActivityFallback() async throws {
        let evidence = DayDigestEvidence.build(
            day: day,
            blocks: [
                block(
                    1,
                    startHour: 9,
                    endHour: 10,
                    title: "New Tab",
                    app: "Safari"),
            ],
            screenContexts: [],
            meetings: [],
            calendar: calendar)
        let recorder = GenerationRecorder()

        let overview = try await DayDigestOverviewGenerator.generate(
            evidence: evidence,
            engine: StructuredDigestEngine(
                recorder: recorder,
                nonSubstantiveFocusIndices: [1]),
            customPrompt: "",
            calendar: calendar)

        XCTAssertTrue(overview.contains("**Recorded activity**"))
        XCTAssertFalse(overview.contains("No substantive work"))
        XCTAssertFalse(overview.contains("Safari"))
        XCTAssertFalse(overview.contains("New Tab"))
        let calls = await recorder.calls
        XCTAssertEqual(calls.count, 1)
    }

    func testDeterministicFallbackKeepsMeetingWorkVisible() {
        let meeting = DayDigestMeetingEvidence(
            id: UUID(),
            title: "Product standup",
            app: "Zoom",
            startedAt: time(10),
            endedAt: time(10, 30),
            sourceSummary: "## TL;DR\nReviewed deployment progress and open bugs.",
            outcomes: "Decision: keep the current deployment tool.",
            artifactModifiedAt: nil)
        let evidence = DayDigestEvidence.build(
            day: day,
            blocks: [],
            screenContexts: [],
            meetings: [meeting],
            calendar: calendar)

        let overview = DayDigestOverviewGenerator.fallback(evidence)

        XCTAssertTrue(overview.contains("**Product standup**"))
        XCTAssertTrue(overview.contains("Reviewed deployment progress"))
        XCTAssertFalse(overview.contains("No substantive work"))
    }

    func testDegradedDigestMetadataAllowsThreeBoundedAttempts() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = directory.appendingPathComponent("2026-08-20.md")
        try "digest".write(to: journal, atomically: true, encoding: .utf8)
        let evidenceDate = time(17)

        XCTAssertNotNil(DayDigestGenerationMetadataStore.completedAt(for: journal))
        for attempt in 1...DayDigestGenerationMetadataStore.maximumDegradedAttempts {
            let metadata = try DayDigestGenerationMetadataStore.record(
                quality: .fallback,
                evidenceLatestAt: evidenceDate,
                for: journal,
                generatedAt: time(18, attempt))
            XCTAssertEqual(metadata.degradedAttemptCount, attempt)
            if attempt < DayDigestGenerationMetadataStore.maximumDegradedAttempts {
                XCTAssertNil(DayDigestGenerationMetadataStore.completedAt(for: journal))
            } else {
                XCTAssertNotNil(DayDigestGenerationMetadataStore.completedAt(for: journal))
            }
        }

        let repaired = try DayDigestGenerationMetadataStore.record(
            quality: .complete,
            evidenceLatestAt: evidenceDate,
            for: journal,
            generatedAt: time(19))
        XCTAssertEqual(repaired.degradedAttemptCount, 0)
        XCTAssertNotNil(DayDigestGenerationMetadataStore.completedAt(for: journal))
    }

    func testNewMeetingArtifactResetsExhaustedDegradedRepairBudget() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = directory.appendingPathComponent("2026-08-20.md")
        try "digest".write(to: journal, atomically: true, encoding: .utf8)
        let meetingEnd = time(17)

        for attempt in 1...DayDigestGenerationMetadataStore.maximumDegradedAttempts {
            _ = try DayDigestGenerationMetadataStore.record(
                quality: .fallback,
                evidenceLatestAt: meetingEnd,
                for: journal,
                generatedAt: time(18, attempt))
        }
        XCTAssertNotNil(DayDigestGenerationMetadataStore.completedAt(for: journal))

        let artifactModifiedAt = time(17, 30)
        let evidence = DayDigestEvidence.build(
            day: day,
            blocks: [],
            screenContexts: [],
            meetings: [DayDigestMeetingEvidence(
                id: UUID(),
                title: "Architecture sync",
                app: "Meet",
                startedAt: time(16),
                endedAt: meetingEnd,
                sourceSummary: "Recovered architecture decisions.",
                outcomes: "Decision: ship.",
                artifactModifiedAt: artifactModifiedAt)],
            calendar: calendar)
        XCTAssertEqual(evidence.latestEvidenceAt, artifactModifiedAt)

        let reopened = try DayDigestGenerationMetadataStore.record(
            quality: .fallback,
            evidenceLatestAt: evidence.latestEvidenceAt,
            for: journal,
            generatedAt: time(19))

        XCTAssertEqual(reopened.degradedAttemptCount, 1)
        XCTAssertNil(DayDigestGenerationMetadataStore.completedAt(for: journal))
    }

    func testInvalidFocusOutputFallsBackToNamedActivityWithoutAppMetadata() async throws {
        let evidence = DayDigestEvidence.build(
            day: day,
            blocks: [block(1, 9, "Release dashboard")],
            screenContexts: [],
            meetings: [],
            calendar: calendar)
        let recorder = GenerationRecorder()

        let overview = try await DayDigestOverviewGenerator.generate(
            evidence: evidence,
            engine: StructuredDigestEngine(
                recorder: recorder,
                alwaysInvalidFocus: true),
            customPrompt: "",
            calendar: calendar)

        XCTAssertTrue(overview.contains("**Release dashboard**"))
        XCTAssertFalse(overview.contains("No substantive work"))
        XCTAssertFalse(overview.contains("Xcode"))
        let calls = await recorder.calls
        XCTAssertEqual(calls.count, 2)
    }

    func testAggregationGroupsSameTaskAcrossSeparateSessions() async throws {
        let evidence = DayDigestEvidence.build(
            day: day,
            blocks: [
                block(1, 9, "Release configuration"),
                block(2, 17, "Release verification"),
            ],
            screenContexts: [
                context(11, 9, 10, "Updated the release signing configuration."),
                context(22, 17, 10, "Gatekeeper verification passed."),
            ],
            meetings: [],
            calendar: calendar)
        let recorder = GenerationRecorder()
        let finalResponse = """
            {"tasks":[{"title":"Release pipeline","status":"completed","summary":"Updated the signing configuration and verified the resulting build with Gatekeeper.","next_step":"","block_indices":[0,1]}],"decisions":["Publish the verified build."],"blockers":[]}
            """

        let overview = try await DayDigestOverviewGenerator.generate(
            evidence: evidence,
            engine: StructuredDigestEngine(
                recorder: recorder,
                finalResponse: finalResponse),
            customPrompt: "",
            calendar: calendar)
        let document = evidence.renderDocument(summary: overview, calendar: calendar)
        let presentation = DayDigestPresentation(markdown: document)

        XCTAssertEqual(presentation.focusBlocks.count, 1)
        XCTAssertEqual(presentation.focusBlocks.first?.title, "Release pipeline")
        XCTAssertTrue(presentation.focusBlocks.first?.summaryMarkdown.contains(
            "signing configuration") == true)
        XCTAssertEqual(presentation.decisions, ["Publish the verified build."])
        XCTAssertFalse(overview.contains("Xcode"))
        XCTAssertFalse(overview.contains("17:00"))
    }

    func testJournalKeepsLongTaskTitlesAndCompleteSummaries() async throws {
        let title = "Oracle price-quote and price-floor logic in AggregatorSwapAdapter (PR #230)"
        let summary = """
            Implemented decimal-scaled price conversion in AggregatorSwapAdapter.sol, \
            using Math.tryMul to adjust tokenOutPrice by the tokenIn/tokenOut decimal \
            difference before deriving oracle amount-out values for a WETH/USDC quote \
            in a fork test. The changes, including the oracle price floor logic and \
            related test files, remain open as PR #230; it is unclear whether the \
            tests fully cover the new floor.
            """.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertGreaterThan(title.count, 72)
        XCTAssertGreaterThan(summary.split(whereSeparator: \.isWhitespace).count, 52)

        let evidence = DayDigestEvidence.build(
            day: day,
            blocks: [block(1, 9, "AggregatorSwapAdapter")],
            screenContexts: [
                context(11, 9, 10, "Implemented oracle price conversion for PR 230."),
            ],
            meetings: [],
            calendar: calendar)
        let recorder = GenerationRecorder()
        let finalResponse = """
            {"tasks":[{"title":"\(title)","status":"in_progress","summary":"\(summary)","next_step":"","block_indices":[0]}],"decisions":[],"blockers":[]}
            """

        let overview = try await DayDigestOverviewGenerator.generate(
            evidence: evidence,
            engine: StructuredDigestEngine(
                recorder: recorder,
                finalResponse: finalResponse),
            customPrompt: "",
            calendar: calendar)
        let presentation = DayDigestPresentation(
            markdown: evidence.renderDocument(summary: overview, calendar: calendar))

        XCTAssertEqual(presentation.focusBlocks.first?.title, title)
        XCTAssertEqual(presentation.focusBlocks.first?.status, .inProgress)
        XCTAssertEqual(presentation.focusBlocks.first?.summaryMarkdown, summary)
        XCTAssertFalse(overview.contains("…"))
    }

    func testRendererGivesEachFactOneSectionAndDeduplicatesSimilarFollowUps() async throws {
        let evidence = DayDigestEvidence.build(
            day: day,
            blocks: [block(1, 9, "Release pipeline")],
            screenContexts: [
                context(11, 9, 10, "Updated signing and verified the release build."),
            ],
            meetings: [],
            calendar: calendar)
        let recorder = GenerationRecorder()
        let finalResponse = """
            {"tasks":[{"title":"Release pipeline","status":"completed","summary":"Updated the signing configuration and verified the release build.","next_step":"Publish the verified build.","block_indices":[0]}],"decisions":["Publish verified build."],"blockers":[]}
            """

        let overview = try await DayDigestOverviewGenerator.generate(
            evidence: evidence,
            engine: StructuredDigestEngine(
                recorder: recorder,
                finalResponse: finalResponse),
            customPrompt: "",
            calendar: calendar)

        XCTAssertTrue(overview.hasPrefix("### Tasks"))
        XCTAssertFalse(overview.contains("### At a glance"))
        XCTAssertEqual(occurrences(of: "Updated the signing configuration", in: overview), 1)
        XCTAssertEqual(occurrences(of: "Publish", in: overview), 1)
        XCTAssertTrue(overview.contains("Decision: Publish verified build."))
        XCTAssertFalse(overview.contains("Next —"))
    }

    func testSummaryEvidenceLeadsWithWorkContentBeforeTraceMetadata() {
        let evidence = DayDigestEvidence.build(
            day: day,
            blocks: [block(1, 9, "Day Digest implementation")],
            screenContexts: [
                context(11, 9, 10, "Implemented task-first digest extraction."),
            ],
            meetings: [],
            calendar: calendar)

        let material = evidence.summaryChunks().joined(separator: "\n")
        let workHeader = material.range(of: "WORK CONTENT")!.lowerBound
        let workText = material.range(of: "Implemented task-first")!.lowerBound
        let metadata = material.range(of: "LOW-PRIORITY TRACE METADATA")!.lowerBound

        XCTAssertLessThan(workHeader, workText)
        XCTAssertLessThan(workText, metadata)
    }

    func testOnlyExactConsecutiveScreenDuplicatesAreCollapsed() {
        let evidence = DayDigestEvidence.build(
            day: day,
            blocks: [
                ActivityBlock(
                    id: 1, app: "Xcode", title: "Editor",
                    start: time(9), end: time(10)),
            ],
            screenContexts: [
                context(1, 9, 5, "same text"),
                context(2, 9, 6, "same text"),
                context(3, 9, 7, "different text"),
                context(4, 9, 8, "same text"),
            ],
            meetings: [],
            calendar: calendar)

        XCTAssertEqual(evidence.activities.first?.contexts.map(\.snapshotID), [1, 3, 4])
    }

    func testSummaryDropsRecurringAccessibilityChromeButJournalKeepsIt() {
        let chrome = "this button also has an action to zoom the window "
            + "Bookmarks New Tab Back Forward Reload substantive page content"
        let evidence = DayDigestEvidence.build(
            day: day,
            blocks: [block(1, 9, "Research")],
            screenContexts: [context(1, 9, 5, chrome, app: "Google Chrome")],
            meetings: [],
            calendar: calendar)

        let summaryMaterial = evidence.summaryChunks().joined(separator: "\n")
        let journal = evidence.renderDocument(summary: "Summary", calendar: calendar)

        XCTAssertFalse(summaryMaterial.localizedCaseInsensitiveContains(
            "this button also has an action to zoom the window"))
        XCTAssertFalse(summaryMaterial.localizedCaseInsensitiveContains(
            "Bookmarks New Tab Back Forward Reload"))
        XCTAssertTrue(summaryMaterial.contains("substantive page content"))
        XCTAssertTrue(journal.contains("this button also has an action to zoom the window"))
        XCTAssertTrue(journal.contains("Bookmarks New Tab Back Forward Reload"))
    }

    func testSummaryOmitsLoginWindowButJournalKeepsIt() {
        let login = ActivityBlock(
            id: 1,
            app: "loginwindow",
            title: "Login Window",
            start: time(8),
            end: time(8, 2))
        let work = ActivityBlock(
            id: 2,
            app: "Xcode",
            title: "DayDigestEvidence.swift",
            start: time(9),
            end: time(9, 45))
        let evidence = DayDigestEvidence.build(
            day: day,
            blocks: [login, work],
            screenContexts: [],
            meetings: [],
            calendar: calendar)

        let summaryMaterial = evidence.summaryChunks().joined(separator: "\n")
        let journal = evidence.renderDocument(summary: "Summary", calendar: calendar)

        XCTAssertFalse(summaryMaterial.localizedCaseInsensitiveContains("loginwindow"))
        XCTAssertTrue(summaryMaterial.contains("DayDigestEvidence.swift"))
        XCTAssertTrue(journal.localizedCaseInsensitiveContains("loginwindow"))
    }

    func testFreshnessOnlyMarksDigestWhenEvidenceIsNewer() {
        let digest = time(18)
        XCTAssertFalse(DayDigestFreshness.isStale(
            digestModifiedAt: digest,
            latestEvidenceAt: time(17, 59)))
        XCTAssertFalse(DayDigestFreshness.isStale(
            digestModifiedAt: digest,
            latestEvidenceAt: digest))
        XCTAssertTrue(DayDigestFreshness.isStale(
            digestModifiedAt: digest,
            latestEvidenceAt: time(21)))
        XCTAssertFalse(DayDigestFreshness.isStale(
            digestModifiedAt: nil,
            latestEvidenceAt: time(21)))
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }
}

// MARK: - Reruns and segment sizing (2026-10-01 regressions)

extension DayDigestEvidenceTests {
    /// The digest ran 16 times on 2026-10-01 and re-asked the model about
    /// every segment each time, including morning segments whose evidence had
    /// not changed.
    func testRerunReusesUnchangedSegmentAndAggregationAnswers() async throws {
        let cache = DayDigestSegmentCache()
        let recorder = GenerationRecorder()
        let engine = StructuredDigestEngine(recorder: recorder)
        let morning = [block(1, 8, "Morning implementation"), block(2, 13, "Midday investigation")]
        let first = DayDigestEvidence.build(day: day, blocks: morning, screenContexts: [], meetings: [],
                                            calendar: calendar)
        _ = try await DayDigestOverviewGenerator.generateResult(
            evidence: first, engine: engine, customPrompt: "", calendar: calendar, segmentCache: cache)
        let afterFirst = await recorder.calls.count
        XCTAssertEqual(afterFirst, 3, "two segments and one aggregation")

        _ = try await DayDigestOverviewGenerator.generateResult(
            evidence: first, engine: engine, customPrompt: "", calendar: calendar, segmentCache: cache)
        let afterRepeat = await recorder.calls.count
        XCTAssertEqual(afterRepeat, afterFirst, "unchanged evidence asks the model nothing")

        let evening = DayDigestEvidence.build(
            day: day, blocks: morning + [block(3, 19, "Evening verification")], screenContexts: [],
            meetings: [], calendar: calendar)
        _ = try await DayDigestOverviewGenerator.generateResult(
            evidence: evening, engine: engine, customPrompt: "", calendar: calendar, segmentCache: cache)
        let calls = await recorder.calls
        XCTAssertEqual(calls.dropFirst(afterRepeat).filter(\.isFocus).count, 1,
                       "only the new evening segment is extracted")
        XCTAssertEqual(calls.dropFirst(afterRepeat).filter { !$0.isFocus }.count, 1)
    }

    func testPurgedDayIsAskedAgain() async throws {
        let cache = DayDigestSegmentCache()
        let recorder = GenerationRecorder()
        let engine = StructuredDigestEngine(recorder: recorder)
        let evidence = DayDigestEvidence.build(
            day: day, blocks: [block(1, 8, "Morning implementation")], screenContexts: [], meetings: [],
            calendar: calendar)
        _ = try await DayDigestOverviewGenerator.generateResult(
            evidence: evidence, engine: engine, customPrompt: "", calendar: calendar, segmentCache: cache)
        XCTAssertEqual(cache.cachedDays, [DreamDay.key(for: day, calendar: calendar)])

        cache.purge(days: [DreamDay.key(for: day, calendar: calendar)])
        XCTAssertTrue(cache.cachedDays.isEmpty, "deleted evidence leaves no derived answer behind")
        _ = try await DayDigestOverviewGenerator.generateResult(
            evidence: evidence, engine: engine, customPrompt: "", calendar: calendar, segmentCache: cache)
        let calls = await recorder.calls
        XCTAssertEqual(calls.filter(\.isFocus).count, 2)
    }

    /// On 2026-10-01 a fragmented day used all eight segments on separate
    /// sessions, so the six-hour main block (809 events) was squeezed into a
    /// single segment's sample budget and then judged not substantive.
    func testLongSessionGetsSegmentsInProportionToItsActiveTime() {
        var blocks: [ActivityBlock] = []
        for index in 0..<36 {
            let start = time(9).addingTimeInterval(TimeInterval(index) * 600)
            blocks.append(ActivityBlock(id: Int64(index + 1), app: "Xcode", title: "Main work \(index)",
                                        start: start, end: start.addingTimeInterval(600)))
        }
        for index in 0..<7 {
            blocks.append(block(Int64(100 + index), startHour: 16 + index / 2, startMinute: (index % 2) * 30,
                                endHour: 16 + index / 2, endMinute: (index % 2) * 30 + 5,
                                title: "Brief task \(index)", app: "Safari"))
        }
        let evidence = DayDigestEvidence.build(day: day, blocks: blocks, screenContexts: [], meetings: [],
                                               calendar: calendar)

        let segments = evidence.summarySegments()

        let mainSegments = segments.filter { $0.start < time(15) }
        XCTAssertEqual(mainSegments.count, 6, "one segment per hour of the six-hour block")
        XCTAssertEqual(segments.count - mainSegments.count, 7, "brief sessions keep their own segment")
    }

    func testShortDayIsNotSplitToFillAQuota() {
        var blocks: [ActivityBlock] = []
        for index in 0..<10 {
            let start = time(9).addingTimeInterval(TimeInterval(index) * 180)
            blocks.append(ActivityBlock(id: Int64(index + 1), app: "Xcode", title: "Quick fix \(index)",
                                        start: start, end: start.addingTimeInterval(180)))
        }
        let evidence = DayDigestEvidence.build(day: day, blocks: blocks, screenContexts: [], meetings: [],
                                               calendar: calendar)
        XCTAssertEqual(evidence.summarySegments().count, 1, "a 30-minute session is one model call")
    }

    func testAggregationRoomGrowsWithCandidatesUpToTheRetryBudget() {
        XCTAssertEqual(DayDigestOverviewGenerator.aggregationTokens(candidates: 3), 1_600)
        XCTAssertEqual(DayDigestOverviewGenerator.aggregationTokens(candidates: 8), 1_600)
        XCTAssertEqual(DayDigestOverviewGenerator.aggregationTokens(candidates: 16), 2_800)
        XCTAssertEqual(DayDigestOverviewGenerator.aggregationTokens(candidates: 40),
                       DayDigestOverviewGenerator.aggregationRetryTokens)
    }
}
