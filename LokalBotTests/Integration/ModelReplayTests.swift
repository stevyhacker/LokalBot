import XCTest
@testable import LokalBot

final class ModelReplayTests: XCTestCase {
    private var server: ModelStubServer!

    override func setUpWithError() throws {
        server = try ModelStubServer()
    }

    override func tearDown() {
        server?.stop()
    }

    private func engine(_ model: String) -> OpenAICompatibleEngine {
        OpenAICompatibleEngine(baseURL: server.baseURL, model: model, apiKey: nil, chatDialect: .openRouter)
    }

    private func recordings(_ caseName: String) throws -> [ModelRecording] {
        let all = try ModelRecording.committed().filter { $0.caseName == caseName }
        XCTAssertFalse(all.isEmpty, "no committed \(caseName) recordings")
        return all
    }

    func testRecordedDigestsCoverMostOfTheSyntheticDay() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        for recording in try recordings("digest-day") {
            try await server.load(recording.stubRules())
            let result = try await DayDigestOverviewGenerator.generateResult(
                evidence: SyntheticModelPrompts.digestEvidence(calendar: calendar),
                engine: engine(recording.model), customPrompt: "", calendar: calendar, sleep: { _ in })
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(result.coverage?.ratio), 0.6, recording.model)
            XCTAssertTrue(result.summary.localizedCaseInsensitiveContains("cach")
                || result.summary.localizedCaseInsensitiveContains("evict"), recording.model)
        }
    }

    func testRecordedNotesKeepAnActionOwnedByMe() async throws {
        for recording in try recordings("notes-design-review") {
            try await server.load(recording.stubRules())
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("replay-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
            let result = try await MeetingNotesGenerator.generate(
                transcript: SyntheticModelPrompts.standupTranscript(), engine: engine(recording.model),
                template: .meeting, language: .matchTranscript, context: [], contextTokens: 32_768,
                meetingID: UUID(), folder: folder)
            XCTAssertFalse(result.outcomes.userActionItems.isEmpty,
                          "\(recording.model): the eviction-policy commitment must stay owned by me")
        }
    }

    func testRecordedRunOnStandupKeepsBothOfMyCommitmentsMine() async throws {
        let transcript = SyntheticModelPrompts.runOnStandupTranscript()
        for recording in try recordings("notes-run-on-standup") {
            try await server.load(recording.stubRules())
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("replay-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
            let result = try await MeetingNotesGenerator.generate(
                transcript: transcript, engine: engine(recording.model),
                template: .meeting, language: .matchTranscript, context: [], contextTokens: 32_768,
                meetingID: UUID(), folder: folder)
            let mine = result.outcomes.userActionItems
            XCTAssertTrue(mine.contains { $0.text.localizedCaseInsensitiveContains("export") },
                          "\(recording.model): updating the export change is mine")
            XCTAssertTrue(mine.contains { $0.text.localizedCaseInsensitiveContains("Mira") || $0.text.localizedCaseInsensitiveContains("Jonas") },
                          "\(recording.model): pinging Mira and Jonas is mine")
            for action in mine {
                XCTAssertTrue(action.citations.contains { MeetingOutcomes.isMicrophoneSpeaker($0.speaker) },
                              "\(recording.model): \(action.text) is not something I said")
            }
        }
    }

    func testRecordedAskAnswersStartWithSearchMeetingsToolCall() throws {
        for recording in try recordings("ask-answer") {
            let first = try XCTUnwrap(recording.calls.first, "\(recording.model): missing ask-answer call")
            guard case .call(let call) = ChatPrompt.parse(first.content, tools: ["search_meetings"]) else {
                XCTFail("\(recording.model): first ask-answer call did not parse as search_meetings: \(first.content)")
                continue
            }
            XCTAssertEqual(call.name, "search_meetings", recording.model)
            XCTAssertNotNil(call.string("query"), "\(recording.model): search_meetings call missing query")
        }
    }
}
