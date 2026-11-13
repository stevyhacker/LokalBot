import XCTest
@testable import LokalBot

/// Sends synthetic text to Anthropic's API. Runs only when `ANTHROPIC_API_KEY`
/// is set (pass `TEST_RUNNER_ANTHROPIC_API_KEY` through xcodebuild);
/// `LOKALBOT_ANTHROPIC_MODEL` overrides `claude-sonnet-5-5`.
final class AnthropicLiveTests: XCTestCase {
    private func liveEngine() throws -> AnthropicEngine {
        let environment = ProcessInfo.processInfo.environment
        guard let key = environment["ANTHROPIC_API_KEY"], !key.isEmpty else {
            throw XCTSkip("Set ANTHROPIC_API_KEY to call Anthropic's API.")
        }
        let model = environment["LOKALBOT_ANTHROPIC_MODEL"].flatMap { $0.isEmpty ? nil : $0 } ?? "claude-sonnet-5-5"
        return AnthropicEngine(baseURL: URL(string: "https://api.anthropic.com/v1")!, model: model, apiKey: key)
    }

    private let units = [
        MeetingNotesEvidence.Unit(source: "s1", speaker: "p1", text: "The fixture build ships on Friday after QA signs off."),
        MeetingNotesEvidence.Unit(source: "s2", speaker: "p2", text: "I'll write the release notes for the fixture build by Thursday."),
        MeetingNotesEvidence.Unit(source: "s3", speaker: "p1", text: "We decided to keep the old importer until version two."),
    ]

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

    func testSharedContextIsReadFromThePromptCache() async throws {
        let engine = try liveEngine()
        var lines: [String] = []
        for index in 1...160 {
            lines.append("Line \(index): the fixture team reviewed checklist item \(index) and marked it done.")
        }
        let transcript = lines.joined(separator: "\n")
        var usages: [AnthropicEngine.Usage] = []
        for question in ["How many checklist items are there?", "Which item was reviewed last?"] {
            let request = try engine.makeRequest(
                system: "Answer questions about the fixture transcript in one short sentence.",
                prompt: question, context: [transcript], schema: nil, options: .init(maxTokens: 256))
            let (data, response) = try await URLSession.shared.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, String(decoding: data, as: UTF8.self))
            usages.append(try XCTUnwrap(AnthropicEngine.parseMessage(data).usage))
        }
        XCTAssertGreaterThan(usages[0].cacheWriteTokens + usages[0].cacheReadTokens, 0, "\(usages[0])")
        XCTAssertGreaterThan(usages[1].cacheReadTokens, 0, "\(usages[1])")
    }

    @MainActor
    func testStreamingAnswer() async throws {
        let engine = try liveEngine()
        let partials = PartialCount()
        let answer = try await engine.generateStreaming(
            system: "Reply in one short sentence.", prompt: "Name a colour of the fixture sky.", context: [],
            options: .init(maxTokens: 256)) { _ in partials.count += 1 }
        XCTAssertFalse(answer.isEmpty)
        XCTAssertGreaterThan(partials.count, 0)
    }

    @MainActor
    private final class PartialCount {
        var count = 0
    }
}
