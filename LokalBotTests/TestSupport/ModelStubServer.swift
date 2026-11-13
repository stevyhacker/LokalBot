import XCTest
@testable import LokalBot

/// Runs `Fixtures/stub-openai.ts` under Bun for one test. CI (`CI=true`)
/// requires Bun (`LOKALBOT_TEST_BUN`); locally a missing Bun skips the test.
final class ModelStubServer {
    let port: Int
    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)/v1")! }
    private var root: URL { URL(string: "http://127.0.0.1:\(port)")! }
    private let process: Process

    static func bunURL() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        var candidates: [String] = []
        if let explicit = environment["LOKALBOT_TEST_BUN"], !explicit.isEmpty { candidates.append(explicit) }
        candidates += ["/opt/homebrew/bin/bun", "\(NSHomeDirectory())/.bun/bin/bun",
                       AgentRuntimeLayout.bunBinary(under: AgentRuntimeLayout.defaultRoot).path]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: found)
        }
        if environment["CI"] == "true" {
            XCTFail("Bun is required in CI; set LOKALBOT_TEST_BUN (Scripts/ci/fetch-bun.sh)")
        }
        throw XCTSkip("Bun not found; set LOKALBOT_TEST_BUN or install the agent runtime")
    }

    init() throws {
        guard let script = Bundle(for: ModelStubServer.self).url(
            forResource: "stub-openai", withExtension: "ts", subdirectory: "Fixtures") else {
            throw XCTSkip("stub-openai.ts missing from the test bundle")
        }
        let process = Process()
        process.executableURL = try Self.bunURL()
        process.arguments = ["run", script.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        var line = Data()
        while let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty, byte != Data("\n".utf8) {
            line.append(byte)
        }
        guard let text = String(data: line, encoding: .utf8), let port = Int(text) else {
            process.terminate()
            throw NSError(domain: "ModelStubServer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "stub did not print its port"])
        }
        self.port = port
        self.process = process
    }

    deinit { stop() }

    func stop() {
        if process.isRunning { process.terminate() }
    }

    func load(_ rules: [[String: Any]]) async throws {
        var request = URLRequest(url: root.appendingPathComponent("__scenario"))
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: ["rules": rules])
        _ = try await URLSession.shared.data(for: request)
    }

    func requests() async throws -> [StubRequest] {
        let (data, _) = try await URLSession.shared.data(from: root.appendingPathComponent("__requests"))
        let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
        return items.map {
            StubRequest(index: $0["index"] as? Int ?? 0,
                        body: $0["body"] as? [String: Any] ?? [:],
                        receivedAt: $0["receivedAt"] as? Double ?? 0)
        }
    }
}

struct StubRequest {
    let index: Int
    let body: [String: Any]
    /// Milliseconds since 1970, as the stub received the request.
    let receivedAt: Double

    private func message(_ role: String) -> String {
        let messages = body["messages"] as? [[String: Any]] ?? []
        return messages.first { $0["role"] as? String == role }?["content"] as? String ?? ""
    }

    var system: String { message("system") }
    var user: String { message("user") }
    var maxTokens: Int? { (body["max_tokens"] ?? body["max_completion_tokens"]) as? Int }
}

/// Builders for stub rules; `system` matches a substring of the system prompt.
enum StubRule {
    private static func rule(_ behaviour: [String: Any], system: String?, nth: Int?, times: Int?) -> [String: Any] {
        var match: [String: Any] = [:]
        if let system { match["systemIncludes"] = system }
        if let nth { match["nth"] = nth }
        var rule: [String: Any] = ["match": match, "behaviour": behaviour]
        if let times { rule["times"] = times }
        return rule
    }

    static func reply(_ content: String, chunks: Int? = nil, system: String? = nil,
                      nth: Int? = nil, times: Int? = nil) -> [String: Any] {
        var behaviour: [String: Any] = ["kind": "reply", "content": content]
        if let chunks { behaviour["chunks"] = chunks }
        return rule(behaviour, system: system, nth: nth, times: times)
    }

    static func http(_ status: Int, retryAfter: Int? = nil, message: String? = nil, system: String? = nil,
                     nth: Int? = nil, times: Int? = nil) -> [String: Any] {
        var behaviour: [String: Any] = ["kind": "http", "status": status]
        if let retryAfter { behaviour["retryAfter"] = retryAfter }
        if let message { behaviour["message"] = message }
        return rule(behaviour, system: system, nth: nth, times: times)
    }

    static func truncate(_ content: String, keep: Double = 0.5, system: String? = nil,
                         nth: Int? = nil, times: Int? = nil) -> [String: Any] {
        rule(["kind": "truncate", "content": content, "keep": keep], system: system, nth: nth, times: times)
    }

    static func reasoning(_ content: String, tokens: Int, system: String? = nil,
                          nth: Int? = nil, times: Int? = nil) -> [String: Any] {
        rule(["kind": "reasoning", "content": content, "reasoningTokens": tokens],
             system: system, nth: nth, times: times)
    }

    static func malformed(_ variant: String, system: String? = nil,
                          nth: Int? = nil, times: Int? = nil) -> [String: Any] {
        rule(["kind": "malformed", "variant": variant], system: system, nth: nth, times: times)
    }

    static func slow(_ content: String, firstByteMs: Int, chunkMs: Int = 0, system: String? = nil,
                     nth: Int? = nil, times: Int? = nil) -> [String: Any] {
        rule(["kind": "slow", "content": content, "firstByteMs": firstByteMs, "chunkMs": chunkMs],
             system: system, nth: nth, times: times)
    }

    static func drop(system: String? = nil, nth: Int? = nil, times: Int? = nil) -> [String: Any] {
        rule(["kind": "drop"], system: system, nth: nth, times: times)
    }
}
