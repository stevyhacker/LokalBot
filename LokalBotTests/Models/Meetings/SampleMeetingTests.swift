import CryptoKit
import XCTest
@testable import LokalBot

final class SampleMeetingTests: XCTestCase {
    private func temporaryDirectory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testRecordingFollowsTheInterfaceLanguageThenEnglish() {
        XCTAssertEqual(SampleMeeting.recording(for: "en"), SampleMeeting.english)
        XCTAssertEqual(SampleMeeting.recording(for: "de").id, "orders-api/de")
        XCTAssertEqual(SampleMeeting.recording(for: "de-CH").id, "orders-api/de")
        XCTAssertEqual(SampleMeeting.recording(for: "zh-Hans").id, "orders-api/zh")
        XCTAssertEqual(SampleMeeting.recording(for: "zh-Hant").id, "orders-api/zh")
        XCTAssertEqual(SampleMeeting.recording(for: "sr-Latn").id, "orders-api/sr-Latn")
        XCTAssertEqual(SampleMeeting.recording(for: "fr"), SampleMeeting.english)
        XCTAssertEqual(SampleMeeting.recording(for: "ja"), SampleMeeting.english)
    }

    func testEveryRecordingIsBundledAndImportsWithItsTitle() async throws {
        for recording in SampleMeeting.recordings {
            let storage = StorageManager(rootURL: try temporaryDirectory("SampleLibrary"))
            let url = try XCTUnwrap(SampleMeeting.audioURL(for: recording), "\(recording.fileName) is bundled")
            let meeting = try await MeetingImportService.importRecording(from: url, storage: storage, sample: recording)
            XCTAssertEqual(meeting.title, recording.title)
            XCTAssertEqual(meeting.sampleID, recording.id)
            let duration = try XCTUnwrap(meeting.recordedDuration)
            XCTAssertTrue((180...300).contains(duration), "\(recording.id) runs \(duration) s")
        }
    }

    func testBundledSampleImportsAsTheMarkedSampleDatedNow() async throws {
        let storage = StorageManager(rootURL: try temporaryDirectory("SampleLibrary"))
        let url = try XCTUnwrap(SampleMeeting.audioURL(for: SampleMeeting.english), "the app bundles the sample recording")
        let now = Date()

        let meeting = try await MeetingImportService.importRecording(
            from: url, storage: storage, now: now, sample: SampleMeeting.english)

        XCTAssertEqual(meeting.title, "Sample: Orders API delivery window")
        XCTAssertEqual(meeting.sampleID, "orders-api/en")
        XCTAssertTrue(meeting.isSample)
        XCTAssertFalse(meeting.isOwnWork)
        XCTAssertTrue(meeting.isImported)
        let duration = try XCTUnwrap(meeting.recordedDuration)
        XCTAssertGreaterThan(duration, 200)
        XCTAssertLessThan(duration, 240)
        XCTAssertEqual(try XCTUnwrap(meeting.endedAt).timeIntervalSince(now), 0, accuracy: 1)
        let meta = try JSONSerialization.jsonObject(with: Data(
            contentsOf: meeting.folderURL(in: storage).appendingPathComponent("meta.json"))) as? [String: Any]
        XCTAssertEqual(meta?["sampleID"] as? String, "orders-api/en")
    }

    func testDayEvidenceAndActionListsLeaveTheSampleOut() throws {
        let root = try temporaryDirectory("SampleEvidence")
        let storage = StorageManager(rootURL: root)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_784_376_000)
        var own = Meeting(id: UUID(), title: "Design review", appName: "Zoom",
                          startedAt: now.addingTimeInterval(-3_600), endedAt: now.addingTimeInterval(-1_800),
                          relativePath: try storage.reserveMeetingFolder(
                              title: "Design review", startedAt: now.addingTimeInterval(-3_600)))
        own.hasSystemTrack = true
        var sample = Meeting(id: UUID(), title: SampleMeeting.english.title, appName: MeetingImportService.appName,
                             startedAt: now.addingTimeInterval(-600), endedAt: now.addingTimeInterval(-390),
                             relativePath: try storage.reserveMeetingFolder(
                                 title: SampleMeeting.english.title, startedAt: now.addingTimeInterval(-600)))
        sample.sampleID = SampleMeeting.english.id
        for meeting in [own, sample] {
            try storage.saveMeta(meeting)
            try MeetingOutcomes(
                actionItems: [.init(text: "Update the API spec for \(meeting.title)", owner: "Me")],
                decisions: []).write(to: meeting.folderURL(in: storage))
        }

        let snapshot = try FileDailyEvidenceSource(root: root, calendar: calendar).snapshot(
            for: now, meetings: [own, sample], includeDetailedActivity: false)
        XCTAssertEqual(snapshot.meetings.map(\.meeting.id), [own.id])

        let entries = ActionItemsReport.entries(
            meetings: [own, sample], root: root, filter: ActionItemsReport.Filter(), now: now, calendar: calendar)
        XCTAssertEqual(entries.flatMap(\.meetings).map(\.title), [own.title])
        var bySample = ActionItemsReport.Filter()
        bySample.meetingID = sample.id
        XCTAssertEqual(ActionItemsReport.entries(
            meetings: [own, sample], root: root, filter: bySample, now: now, calendar: calendar).count, 1)
    }

    func testOvernightReviewLeavesTheSampleOutOfEarlierMeetingsAndActions() throws {
        let root = try temporaryDirectory("SampleDream")
        let storage = StorageManager(rootURL: root)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_784_376_000)
        let own = Meeting(id: UUID(), title: "Design review", appName: "Zoom",
                          startedAt: now.addingTimeInterval(-3_600), endedAt: now.addingTimeInterval(-1_800),
                          relativePath: try storage.reserveMeetingFolder(
                              title: "Design review", startedAt: now.addingTimeInterval(-3_600)))
        var sample = Meeting(id: UUID(), title: SampleMeeting.english.title, appName: MeetingImportService.appName,
                             startedAt: now.addingTimeInterval(-600), endedAt: now.addingTimeInterval(-390),
                             relativePath: try storage.reserveMeetingFolder(
                                 title: SampleMeeting.english.title, startedAt: now.addingTimeInterval(-600)))
        sample.sampleID = SampleMeeting.english.id
        for meeting in [own, sample] {
            try storage.saveMeta(meeting)
            try MeetingOutcomes(
                actionItems: [.init(text: "Update the API spec for \(meeting.title)", owner: "Me")],
                decisions: []).write(to: meeting.folderURL(in: storage))
        }

        let evidence = try DreamCompiler.compile(
            day: now.addingTimeInterval(86_400), storageRoot: root, calendar: calendar)

        XCTAssertEqual(evidence.priorMeetings.map(\.title), [own.title])
        XCTAssertTrue(evidence.openActions.contains { $0.contains(own.title) }, "\(evidence.openActions)")
        XCTAssertFalse(evidence.openActions.contains { $0.contains(sample.title) }, "\(evidence.openActions)")
        let meetingSources = evidence.sources.filter { $0.kind == .meeting }.map(\.id)
        XCTAssertEqual(meetingSources, [own.id.uuidString])
    }

    func testPrecomputedHydrationPopulatesTranscriptSummaryOutcomesAndAskAnswersWithoutModels() throws {
        for recording in SampleMeeting.recordings {
            let root = try temporaryDirectory("SamplePrecomputed-\(recording.language)")
            let storage = StorageManager(rootURL: root)
            let start = Date()

            let meeting = try SampleMeeting.hydratePrecomputed(recording: recording, storage: storage)
            let elapsed = Date().timeIntervalSince(start)

            XCTAssertLessThan(elapsed, 5.0, "\(recording.id) hydrated in \(elapsed)s")
            XCTAssertEqual(meeting.sampleID, recording.id)
            XCTAssertTrue(meeting.isSample)
            XCTAssertTrue(meeting.hasSystemTrack)

            let folder = meeting.folderURL(in: storage)
            let transcriptData = try Data(contentsOf: folder.appendingPathComponent("transcript.json"))
            let transcript = try JSONDecoder().decode(Transcript.self, from: transcriptData)
            XCTAssertEqual(transcript.engine, SampleMeeting.precomputedEngine)
            XCTAssertFalse(transcript.segments.isEmpty)
            XCTAssertFalse(transcript.speakerAliases.isEmpty)

            let summary = try String(contentsOf: folder.appendingPathComponent("summary.md"), encoding: .utf8)
            XCTAssertFalse(summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            let outcomes = try XCTUnwrap(MeetingOutcomes.load(from: folder))
            XCTAssertFalse(outcomes.decisionRecords.isEmpty)
            XCTAssertFalse(outcomes.actionItems.isEmpty)
            XCTAssertFalse(outcomes.openQuestions.isEmpty)
            XCTAssertEqual(outcomes.transcriptRevision, transcript.evidenceRevision)
            XCTAssertTrue(outcomes.decisionRecords.allSatisfy { !$0.citations.isEmpty })

            let question = SampleMeeting.askQuestion(for: meeting, language: .english)
            let answer = try XCTUnwrap(SampleMeeting.precomputedAskAnswer(for: meeting, question: question))
            XCTAssertFalse(answer.isEmpty)
            let citations = ChatCitationParser.extract(answer).citations
            XCTAssertFalse(citations.isEmpty, "precomputed answer for \(recording.id) must include cited timestamps")
            XCTAssertTrue(citations.allSatisfy { $0.meetingID.lowercased() == SessionLookup.shortID(meeting.id).lowercased() })
        }
    }

    @MainActor
    func testChatViewModelUsesPrecomputedSampleAnswerWithoutStartingAnEngine() async throws {
        let root = try temporaryDirectory("SamplePrecomputedChat")
        let storage = StorageManager(rootURL: root)
        let meeting = try SampleMeeting.hydratePrecomputed(recording: SampleMeeting.english, storage: storage)
        let question = SampleMeeting.askQuestion(for: meeting, language: .english)
        var engineCalled = false
        let key = SymmetricKey(data: Data(repeating: 0x42, count: 32))
        let store = ChatStore(rootURL: root, encryptionKey: { key })

        let viewModel = ChatViewModel(
            makeEngine: {
                engineCalled = true
                throw CancellationError()
            },
            tools: SampleChatToolRunner(),
            store: store,
            precomputedAnswer: { query, scopedIDs in
                guard scopedIDs == [meeting.id],
                      let reply = SampleMeeting.precomputedAskAnswer(for: meeting, question: query) else {
                    return nil
                }
                return ChatViewModel.PrecomputedAnswer(answer: reply, meetingTitle: meeting.displayTitle)
            })

        viewModel.send(question, meetingIDs: [meeting.id])

        XCTAssertFalse(engineCalled, "precomputed sample answer must not invoke the local LLM engine")
        XCTAssertEqual(viewModel.messages.count, 2)
        XCTAssertEqual(viewModel.messages.first?.role, .user)
        let assistant = try XCTUnwrap(viewModel.messages.last)
        XCTAssertEqual(assistant.role, .assistant)
        XCTAssertFalse(assistant.isPending)
        XCTAssertFalse(ChatCitationParser.extract(assistant.text).citations.isEmpty)
    }
}

@MainActor
private final class SampleChatToolRunner: ChatToolRunner {
    let specs: [ChatToolSpec] = []
    func libraryOverview() -> String { "Sample" }
    func run(_ call: ChatToolCall) async -> ChatToolResult {
        ChatToolResult(text: "", summary: "")
    }
}
