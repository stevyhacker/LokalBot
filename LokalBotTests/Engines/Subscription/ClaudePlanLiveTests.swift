import XCTest
@testable import LokalBot

/// Sends synthetic text through the Mac's own signed-in Claude Code, on the
/// Claude plan it is signed in with. Runs only when `LOKALBOT_CLAUDE_PLAN_LIVE`
/// is set (pass `TEST_RUNNER_LOKALBOT_CLAUDE_PLAN_LIVE=1` through xcodebuild);
/// `LOKALBOT_CLAUDE_PLAN_MODEL` overrides `haiku`.
final class ClaudePlanLiveTests: XCTestCase {
    private func liveEngine() throws -> ClaudePlanEngine {
        let environment = ProcessInfo.processInfo.environment
        guard environment["LOKALBOT_CLAUDE_PLAN_LIVE"] == "1" else {
            throw XCTSkip("Set LOKALBOT_CLAUDE_PLAN_LIVE=1 to run Claude Code on your Claude plan.")
        }
        let model = environment["LOKALBOT_CLAUDE_PLAN_MODEL"].flatMap { $0.isEmpty ? nil : $0 } ?? "haiku"
        return ClaudePlanEngine(model: model)
    }

    private let units = [
        MeetingNotesEvidence.Unit(source: "s1", speaker: "p1", text: "The fixture build ships on Friday after QA signs off."),
        MeetingNotesEvidence.Unit(source: "s2", speaker: "p2", text: "I'll write the release notes for the fixture build by Thursday."),
        MeetingNotesEvidence.Unit(source: "s3", speaker: "p1", text: "We decided to keep the old importer until version two."),
    ]

    func testSignInIsReported() async throws {
        _ = try liveEngine()
        let executable = await ClaudeCodeLocator.shared.executable(refresh: true)
        let status = try await ClaudeCodeCLI.authStatus(executable: XCTUnwrap(executable))
        XCTAssertTrue(status.loggedIn, "sign in to Claude Code before running live tests")
    }

    func testMeetingNotesSchemaIsAccepted() async throws {
        let engine = try liveEngine()
        let schema = MeetingNotesEvidence.schema(units: units, speakers: ["p1", "p2"], template: .meeting,
                                                 maximumNotes: 4, maximumActions: 3)
        let reply = try await engine.generate(
            system: "Extract meeting notes from the numbered lines as JSON that matches the schema. Cite source ids.",
            prompt: units.map(\.line).joined(separator: "\n"), context: [], schema: schema,
            options: .init(maxTokens: 2_048, reasoningBudgetTokens: 0, temperature: 0))
        let object = try JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any]
        XCTAssertNotNil(object, reply)
    }

    @MainActor
    func testStreamingCompletes() async throws {
        let engine = try liveEngine()
        var partials = 0
        let reply = try await engine.generateStreaming(
            system: "Answer in one short sentence.", prompt: "Name a primary color.", context: [],
            options: .init()) { _ in partials += 1 }
        XCTAssertFalse(reply.isEmpty)
        XCTAssertGreaterThan(partials, 0)
    }
}
