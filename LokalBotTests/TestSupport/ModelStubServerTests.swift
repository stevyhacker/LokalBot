import XCTest
@testable import LokalBot

final class ModelStubServerTests: XCTestCase {
    private var server: ModelStubServer!

    override func setUpWithError() throws {
        server = try ModelStubServer()
    }

    override func tearDown() {
        server?.stop()
    }

    private func post(system: String, maxTokens: Int = 100) async throws -> (Int, [String: Any]) {
        var request = URLRequest(url: server.baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "stub-model", "max_tokens": maxTokens,
            "messages": [["role": "system", "content": system], ["role": "user", "content": "u"]],
        ])
        request.timeoutInterval = 5
        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, json)
    }

    private func content(_ json: [String: Any]) -> (String?, String?) {
        let choice = (json["choices"] as? [[String: Any]])?.first
        let message = choice?["message"] as? [String: Any]
        return (message?["content"] as? String, choice?["finish_reason"] as? String)
    }

    func testRulesMatchBySystemMarkerAndOrder() async throws {
        try await server.load([
            StubRule.http(503, retryAfter: 1, system: "FOCUS", nth: 1),
            StubRule.reply("{\"ok\":true}", system: "FOCUS"),
        ])
        let first = try await post(system: "FOCUS prompt")
        XCTAssertEqual(first.0, 503)
        let second = try await post(system: "FOCUS prompt")
        XCTAssertEqual(second.0, 200)
        XCTAssertEqual(content(second.1).0, "{\"ok\":true}")
        let requests = try await server.requests()
        XCTAssertEqual(requests.map(\.system), ["FOCUS prompt", "FOCUS prompt"])
        XCTAssertEqual(requests.first?.maxTokens, 100)
    }

    func testReasoningBehaviourTruncatesWhenTheBudgetIsTooSmall() async throws {
        let answer = String(repeating: "x", count: 400) // about 100 tokens
        try await server.load([StubRule.reasoning(answer, tokens: 1_400, system: "S")])
        let small = try await post(system: "S", maxTokens: 1_450)
        XCTAssertEqual(content(small.1).1, "length")
        let large = try await post(system: "S", maxTokens: 2_048)
        XCTAssertEqual(content(large.1).0, answer)
        XCTAssertEqual(content(large.1).1, "stop")
    }

    func testUnmatchedRequestFailsFastWith500() async throws {
        try await server.load([StubRule.reply("x", system: "ONLY-THIS")])
        let started = Date()
        let result = try await post(system: "something else")
        XCTAssertEqual(result.0, 500)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertEqual((result.1["error"] as? [String: Any])?["message"] as? String, "no scenario rule")
    }
}
