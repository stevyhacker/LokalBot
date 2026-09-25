import XCTest
@testable import LokalBot

final class UpcomingMeetingPreparationTests: XCTestCase {
    private var root: URL!
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UpcomingMeetingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testScheduleIncludesEndedAndDistantMeetingsAcrossTheWholeDay() {
        let previousDay = event(
            id: "previous-day", title: "Previous day", startsIn: -18_000, duration: 1_800)
        let ended = event(id: "ended", title: "Ended", startsIn: -7_200, duration: 1_800)
        let soon = event(id: "soon", title: "Soon", startsIn: 600, duration: 1_800)
        let evening = event(id: "evening", title: "Evening", startsIn: 64_800, duration: 1_800)
        let nextDay = event(id: "next-day", title: "Next day", startsIn: 82_800, duration: 1_800)

        let schedule = UpcomingMeetingSelector.schedule(
            from: [nextDay, evening, previousDay, soon, ended],
            on: now,
            calendar: utcCalendar)

        XCTAssertEqual(schedule.map(\.externalID), ["ended", "soon", "evening"])
    }

    func testSelectorPrefersActiveThenSoonestAndExcludesCurrentRecording() {
        let active = event(id: "active", title: "Live", startsIn: -600, duration: 1_800)
        let soon = event(id: "soon", title: "Soon", startsIn: 600, duration: 1_800)
        let later = event(id: "later", title: "Later", startsIn: 1_200, duration: 1_800)
        let evening = event(id: "evening", title: "Evening", startsIn: 64_800, duration: 1_800)

        XCTAssertEqual(
            UpcomingMeetingSelector.primary(
                from: [later, evening, soon, active], now: now)?.externalID,
            "active")
        XCTAssertEqual(
            UpcomingMeetingSelector.primary(
                from: [later, evening, soon, active], now: now,
                excludingEventID: "active")?.externalID,
            "soon")
        XCTAssertEqual(
            UpcomingMeetingSelector.primary(from: [evening], now: now)?.externalID,
            "evening")
    }

    func testTodayLeavesOutPersonalAppointmentsAndKeepsSoloMeetingsWithoutRecording() {
        func solo(_ id: String, _ title: String, startsIn: TimeInterval) -> CalendarMeetingCandidate {
            let start = now.addingTimeInterval(startsIn)
            return CalendarMeetingCandidate(provider: "test", externalID: id, title: title, startDate: start,
                endDate: start.addingTimeInterval(3_600), meetingURL: nil, sourceCalendarTitle: "Personal")
        }
        let dentist = solo("dentist", "12:15 zubar", startsIn: 600)
        let doctor = solo("doctor", "Doktor Lena vakcina", startsIn: 900)
        let standup = solo("standup", "Product Standup", startsIn: 1_800)
        var invited = solo("invited", "Roadmap chat", startsIn: 7_200)
        invited.participantNames = ["Ana"]
        let demoDay = event(id: "demo", title: "Demo Day", startsIn: 16_200, duration: 3_600)

        XCTAssertEqual(UpcomingMeetingSelector.kind(of: dentist), .personal)
        XCTAssertEqual(UpcomingMeetingSelector.kind(of: doctor), .personal)
        XCTAssertEqual(UpcomingMeetingSelector.kind(of: standup), .soloMeeting)
        XCTAssertEqual(UpcomingMeetingSelector.kind(of: invited), .meeting)
        XCTAssertEqual(UpcomingMeetingSelector.kind(of: demoDay), .meeting)

        let schedule = UpcomingMeetingSelector.schedule(
            from: [demoDay, invited, standup, doctor, dentist], on: now, calendar: utcCalendar)
        XCTAssertEqual(schedule.map(\.externalID), ["standup", "invited", "demo"],
                       "Personal appointments cannot hide the day's meetings")
        XCTAssertEqual(UpcomingMeetingSelector.primary(from: schedule, now: now)?.externalID, "standup")
    }

    func testMeetingTitlesAreRecognizedWithoutMatchingInsideOtherWords() {
        for title in ["Product Standup", "Sync on onchain roadmap", "1:1 with Ana", "Weekly planning",
                      "Interview with Thrackle", "Team call", "Sastanak sa timom", "All-hands"] {
            XCTAssertTrue(UpcomingMeetingSelector.looksLikeMeeting(title), title)
        }
        for title in ["12:15 zubar", "Doktor Lena vakcina", "Gym", "Lunch", "Recall groceries", "Pick up Demonstration kit"] {
            XCTAssertFalse(UpcomingMeetingSelector.looksLikeMeeting(title), title)
        }
    }

    func testPresentationLabelsPastMeetingAsEnded() {
        let ended = event(id: "ended", title: "Ended", startsIn: -3_600, duration: 1_800)

        XCTAssertEqual(
            UpcomingMeetingPresentation.statusLabel(event: ended, now: now),
            "Ended")
        XCTAssertTrue(
            UpcomingMeetingPresentation.timeLabel(
                event: ended,
                now: now,
                calendar: utcCalendar).hasSuffix(" · Ended"))
    }

    func testSignatureChangesWhenCalendarEvidenceChanges() {
        let first = event(
            id: "series",
            title: "Atlas review",
            startsIn: 600,
            duration: 1_800,
            participants: ["Ana"])
        let revised = CalendarMeetingCandidate(
            provider: first.provider,
            externalID: first.externalID,
            title: "Atlas launch review",
            startDate: first.startDate,
            endDate: first.endDate,
            meetingURL: first.meetingURL,
            sourceCalendarTitle: first.sourceCalendarTitle,
            participantNames: ["Ana", "Marko"])

        let firstEvidence = UpcomingMeetingEvidence(
            event: first, relatedMeetings: [], decisions: [], commitments: [], projects: [])
        let revisedEvidence = UpcomingMeetingEvidence(
            event: revised, relatedMeetings: [], decisions: [], commitments: [], projects: [])

        XCTAssertNotEqual(firstEvidence.signature, revisedEvidence.signature)
    }

    func testCompilerUsesParticipantHistoryOutcomesAndProjectMemory() throws {
        let related = try meeting(
            title: "Launch checkpoint",
            daysAgo: 7,
            participants: ["Ana Petrović"],
            summary: "Ana reviewed the Atlas launch. The team kept the staged rollout.",
            outcomes: MeetingOutcomes(
                actionItems: [.init(text: "Send the rollout checklist", owner: "Me", due: "Friday")],
                decisions: ["Keep the Atlas rollout staged."],
                openQuestions: []))
        _ = try meeting(
            title: "Unrelated finance call",
            daysAgo: 1,
            participants: ["Marko"],
            summary: "Quarterly budget review.",
            outcomes: MeetingOutcomes(decisions: ["Freeze travel spend."]))
        let memory = DreamMemory(
            updatedAt: now,
            activeProjects: [.init(
                name: "Atlas",
                status: "Staged launch awaiting the final checklist",
                lastActiveDay: "2033-05-17",
                evidence: [])])
        let upcoming = event(
            id: "atlas-review",
            title: "Atlas launch review",
            startsIn: 1_200,
            duration: 1_800,
            participants: ["Ana Petrovic"])

        let evidence = UpcomingMeetingPreparationCompiler.compile(
            event: upcoming,
            meetings: loadMeetings(),
            storageRoot: root,
            memory: memory,
            now: now)

        XCTAssertEqual(evidence.relatedMeetings.map(\.meeting.id), [related.id])
        XCTAssertEqual(evidence.decisions.map(\.text), ["Keep the Atlas rollout staged."])
        XCTAssertEqual(evidence.commitments.map(\.text), ["Send the rollout checklist"])
        XCTAssertEqual(evidence.commitments.first?.owner, "Me")
        XCTAssertEqual(evidence.commitments.first?.isForUser, true)
        XCTAssertEqual(evidence.projects.map(\.name), ["Atlas"])
        XCTAssertTrue(evidence.fallbackBrief.contains("Keep the Atlas rollout staged"))
        XCTAssertTrue(evidence.fallbackBrief.contains("Owner: You."))
        XCTAssertTrue(evidence.promptContext.contains("using saved corrections and status"))
    }

    func testCompilerDeduplicatesCommitmentsAndKeepsLatestCorrection() throws {
        let earlierAction = MeetingOutcomes.ActionItem(
            text: "I will send the revised launch proposal",
            owner: "Me",
            due: "Friday")
        let laterAction = MeetingOutcomes.ActionItem(
            text: "Send the revised launch proposal",
            owner: "Me",
            due: "Monday")
        _ = try meeting(
            title: "Atlas planning",
            daysAgo: 7,
            participants: ["Ana"],
            summary: "Reviewed the Atlas proposal.",
            outcomes: MeetingOutcomes(actionItems: [earlierAction]))
        let latest = try meeting(
            title: "Atlas review",
            daysAgo: 2,
            participants: ["Ana"],
            summary: "Reviewed the revised Atlas proposal.",
            outcomes: MeetingOutcomes(actionItems: [laterAction]))
        var state = MeetingOutcomeState()
        state.actions[laterAction.id] = .init(
            dueOverride: "Tuesday",
            textCorrection: "Send Acme the revised launch proposal",
            userEdited: true)
        try MeetingOutcomeStore.writeState(
            state,
            to: latest.folderURL(in: StorageManager(rootURL: root)))

        let evidence = UpcomingMeetingPreparationCompiler.compile(
            event: event(
                id: "atlas",
                title: "Atlas launch review",
                startsIn: 900,
                duration: 1_800,
                participants: ["Ana"]),
            meetings: loadMeetings(),
            storageRoot: root,
            memory: nil,
            now: now)

        XCTAssertEqual(evidence.commitments.count, 1)
        XCTAssertEqual(evidence.commitments[0].text, "Send Acme the revised launch proposal")
        XCTAssertEqual(evidence.commitments[0].due, "Tuesday")
        XCTAssertEqual(evidence.commitments[0].sourceMeetingCount, 2)
    }

    func testCompilerFallsBackToRecurringCalendarTitleWithoutParticipants() throws {
        let prior = try meeting(
            title: "Browser meeting",
            calendarTitle: "Weekly Product Sync",
            daysAgo: 14,
            participants: [],
            summary: "Reviewed onboarding activation.",
            outcomes: MeetingOutcomes(decisions: ["Keep onboarding as the first milestone."]))
        let upcoming = event(
            id: "series",
            title: "Weekly Product Sync",
            startsIn: 900,
            duration: 1_800)

        let evidence = UpcomingMeetingPreparationCompiler.compile(
            event: upcoming,
            meetings: loadMeetings(),
            storageRoot: root,
            memory: nil,
            now: now)

        XCTAssertEqual(evidence.relatedMeetings.first?.meeting.id, prior.id)
        XCTAssertEqual(evidence.decisions.first?.text, "Keep onboarding as the first milestone.")
    }

    func testCompilerDoesNotPullUnrelatedRecentWork() throws {
        _ = try meeting(
            title: "Finance review",
            daysAgo: 1,
            participants: ["Marko"],
            summary: "Reviewed the annual budget.",
            outcomes: MeetingOutcomes(decisions: ["Reduce travel spend."]))
        let upcoming = event(
            id: "design",
            title: "Design critique",
            startsIn: 900,
            duration: 1_800,
            participants: ["Ana"])

        let evidence = UpcomingMeetingPreparationCompiler.compile(
            event: upcoming,
            meetings: loadMeetings(),
            storageRoot: root,
            memory: nil,
            now: now)

        XCTAssertFalse(evidence.hasPreparationContext)
        XCTAssertTrue(evidence.relatedMeetings.isEmpty)
        XCTAssertEqual(
            evidence.fallbackBrief,
            "No related decisions or commitments were found in LokalBot yet.")
    }

    func testGeneratorReturnsBoundedStructuredBrief() async throws {
        let prior = Meeting(
            id: UUID(), title: "Atlas review", appName: "Zoom",
            startedAt: now.addingTimeInterval(-86_400),
            endedAt: now.addingTimeInterval(-85_000),
            relativePath: "meetings/atlas")
        let decision = UpcomingMeetingReference(
            kind: .decision,
            text: "Keep the rollout staged.",
            meeting: prior,
            index: 0)
        let evidence = UpcomingMeetingEvidence(
            event: event(id: "next", title: "Atlas review", startsIn: 600, duration: 1_800),
            relatedMeetings: [.init(
                meeting: prior,
                summary: "The staged rollout remains in review.",
                participantMatches: 1,
                relevanceScore: 120)],
            decisions: [decision],
            commitments: [],
            projects: [])
        let engine = StubTextEngine(
            response: #"{"brief":"The staged rollout is still the key decision. Confirm the review status before expanding access."}"#)

        let brief = try await UpcomingMeetingBriefGenerator.generate(
            evidence: evidence,
            engine: engine)

        XCTAssertEqual(
            brief,
            "The staged rollout is still the key decision. Confirm the review status before expanding access.")
        XCTAssertLessThanOrEqual(brief.count, 700)
    }

    func testRemoteMainLLMIsNeverEligibleForPreMeetingGeneration() {
        var settings = AppSettings()
        settings.summarizerBackend = .openAICompatible
        settings.openAIBaseURL = "https://api.example.com/v1"
        XCTAssertFalse(UpcomingMeetingLocalGenerationPolicy.permitsLocalGeneration(
            settings: settings))

        settings.openAIBaseURL = "http://127.0.0.1:1234/v1"
        XCTAssertTrue(UpcomingMeetingLocalGenerationPolicy.permitsLocalGeneration(
            settings: settings))
    }

    // MARK: - Fixtures

    private func event(
        id: String,
        title: String,
        startsIn: TimeInterval,
        duration: TimeInterval,
        participants: [String] = []
    ) -> CalendarMeetingCandidate {
        let start = now.addingTimeInterval(startsIn)
        return CalendarMeetingCandidate(
            provider: "test",
            externalID: id,
            title: title,
            startDate: start,
            endDate: start.addingTimeInterval(duration),
            meetingURL: URL(string: "https://meet.google.com/abc-defg-hij"),
            sourceCalendarTitle: "Work",
            participantNames: participants)
    }

    @discardableResult
    private func meeting(
        title: String,
        calendarTitle: String? = nil,
        daysAgo: Int,
        participants: [String],
        summary: String,
        outcomes: MeetingOutcomes
    ) throws -> Meeting {
        let id = UUID()
        let relativePath = "meetings/\(id.uuidString)"
        var value = Meeting(
            id: id,
            title: title,
            appName: "Zoom",
            startedAt: now.addingTimeInterval(-TimeInterval(daysAgo) * 86_400),
            endedAt: now.addingTimeInterval(-TimeInterval(daysAgo) * 86_400 + 1_800),
            relativePath: relativePath)
        value.calendarTitle = calendarTitle
        value.participantNameHints = participants
        let folder = root.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try summary.write(
            to: folder.appendingPathComponent("summary.md"),
            atomically: true,
            encoding: .utf8)
        try outcomes.write(to: folder)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(value).write(
            to: folder.appendingPathComponent("meta.json"), options: .atomic)
        return value
    }

    private func loadMeetings() -> [Meeting] {
        StorageManager(rootURL: root).loadMeetings()
    }
}

private struct StubTextEngine: TextEngine {
    let response: String
    var displayName: String { "Stub" }

    func generate(system: String, prompt: String, context: [String]) async throws -> String {
        response
    }
}
