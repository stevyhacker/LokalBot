import XCTest
@testable import LokalBot

final class GeminiPlanEngineTests: XCTestCase {
    final class FakeRunner: GeminiCLIRunning, @unchecked Sendable {
        struct Call {
            var arguments: [String]
            var input: String
            var files: [String: String]
        }

        private let lock = NSLock()
        private var recorded: [Call] = []
        private let stdout: (Int) -> String
        private let status: Int32
        private let stderr: String

        init(status: Int32 = 0, stderr: String = "", stdout: @escaping (Int) -> String) {
            self.status = status
            self.stderr = stderr
            self.stdout = stdout
        }

        var calls: [Call] { lock.withLock { recorded } }

        func run(arguments: [String], input: Data, files: [String: Data],
                 onLine: (@Sendable (String) -> Void)?) async throws -> PlanCLIProcess.Output {
            let count: Int = lock.withLock {
                recorded.append(Call(arguments: arguments, input: String(decoding: input, as: UTF8.self),
                                     files: files.mapValues { String(decoding: $0, as: UTF8.self) }))
                return recorded.count
            }
            let output = stdout(count)
            if let onLine { output.split(separator: "\n").forEach { onLine(String($0)) } }
            return PlanCLIProcess.Output(status: status, stdout: Data(output.utf8), stderrTail: stderr)
        }
    }

    static func jsonLine(_ object: Any) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private func value(after flag: String, in arguments: [String]) -> String? {
        arguments.firstIndex(of: flag).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
    }

    // MARK: Arguments & Isolation

    func testArgumentsKeepGeminiCLIToPlainTextMode() {
        let engine = GeminiPlanEngine(model: "gemini-3.5-flash")
        let arguments = engine.arguments(streaming: false)

        XCTAssertEqual(value(after: "-p", in: arguments), "")
        XCTAssertEqual(value(after: "--output-format", in: arguments), "json")
        XCTAssertTrue(arguments.contains("--skip-trust"))
        XCTAssertEqual(value(after: "--admin-policy", in: arguments), GeminiPlanEngine.adminPolicyFile)
        XCTAssertEqual(value(after: "--extensions", in: arguments), "none")
        XCTAssertEqual(value(after: "--model", in: arguments), "gemini-3.5-flash")
        XCTAssertFalse(arguments.contains("--yolo"))
        XCTAssertFalse(arguments.contains("-y"))

        let autoArgs = GeminiPlanEngine(model: "auto").arguments(streaming: true)
        XCTAssertEqual(value(after: "--output-format", in: autoArgs), "stream-json")
        XCTAssertNil(value(after: "--model", in: autoArgs), "auto uses Gemini CLI's default router")
    }

    func testIsolationFilesDenyToolsMCPHooksAndSkills() throws {
        let settings = try XCTUnwrap(
            JSONSerialization.jsonObject(with: GeminiPlanEngine.systemSettingsJSON) as? [String: Any])
        let tools = try XCTUnwrap(settings["tools"] as? [String: Any])
        XCTAssertEqual(tools["core"] as? [String], [])
        XCTAssertEqual(tools["exclude"] as? [String], ["*"])
        let mcp = try XCTUnwrap(settings["mcp"] as? [String: Any])
        XCTAssertEqual(mcp["allowed"] as? [String], [])
        XCTAssertEqual(mcp["excluded"] as? [String], ["*"])
        let hooks = try XCTUnwrap(settings["hooksConfig"] as? [String: Any])
        XCTAssertEqual(hooks["enabled"] as? Bool, false)
        let skills = try XCTUnwrap(settings["skills"] as? [String: Any])
        XCTAssertEqual(skills["enabled"] as? Bool, false)

        let toml = String(decoding: GeminiPlanEngine.adminPolicyTOML, as: UTF8.self)
        XCTAssertTrue(toml.contains(#"toolName = "*""#))
        XCTAssertTrue(toml.contains(#"decision = "deny""#))
    }

    // MARK: Requests

    func testRequestWritesSystemPromptToFileAndContextToStdin() async throws {
        let runner = FakeRunner { _ in
            Self.jsonLine([
                "session_id": "s-1",
                "response": "Done.",
                "stats": ["models": ["gemini-3.5-flash": ["tokens": ["prompt": 40, "candidates": 5, "cached": 10]]]],
            ])
        }
        let reply = try await GeminiPlanEngine(model: "gemini-3.5-flash", runner: runner)
            .generate(system: "Write notes.", prompt: "Summarize.", context: ["Transcript", " "])

        XCTAssertEqual(reply, "Done.")
        let call = try XCTUnwrap(runner.calls.first)
        XCTAssertEqual(call.files[GeminiPlanEngine.systemPromptFile], "Write notes.")
        XCTAssertNotNil(call.files[GeminiPlanEngine.systemSettingsFile])
        XCTAssertNotNil(call.files[GeminiPlanEngine.adminPolicyFile])
        XCTAssertEqual(call.input, "Transcript\n\nSummarize.")
        XCTAssertFalse(call.arguments.contains { $0.contains("Write notes.") || $0.contains("Transcript") })
    }

    func testStructuredRequestPlacesSchemaInSystemPromptFileAndExtractsJSON() async throws {
        let runner = FakeRunner { _ in
            Self.jsonLine(["response": "```json\n{\"owner\":\"Marko\"}\n```"])
        }
        let schema: [String: Any] = [
            "type": "object",
            "properties": ["owner": ["type": "string", "enum": ["Marko"]]],
            "required": ["owner"],
        ]
        let reply = try await GeminiPlanEngine(model: "gemini-2.5-pro", runner: runner)
            .generate(system: "Extract.", prompt: "Who owns it?", context: [], schema: schema)

        XCTAssertEqual(reply, #"{"owner":"Marko"}"#)
        let call = try XCTUnwrap(runner.calls.first)
        XCTAssertFalse(call.arguments.contains { $0.contains("Marko") })
        let promptFile = try XCTUnwrap(call.files[GeminiPlanEngine.systemPromptFile])
        XCTAssertTrue(promptFile.contains("Marko"))
    }

    func testProseReplyToSchemaRequestFails() throws {
        XCTAssertThrowsError(try GeminiPlanEngine.parseJSONObject(
            ["response": "The launch is next Friday."], wantsStructured: true)) { error in
            guard case TextEngineError.badResponse = error else { return XCTFail("\(error)") }
        }
    }

    @MainActor
    func testStreamingForwardsAssistantDeltasAndReturnsResult() async throws {
        let lines = [
            Self.jsonLine(["type": "init", "session_id": "s-1", "model": "gemini-3.5-flash"]),
            Self.jsonLine(["type": "message", "role": "user", "content": "p"]),
            Self.jsonLine(["type": "message", "role": "assistant", "content": "Hel", "delta": true]),
            Self.jsonLine(["type": "message", "role": "assistant", "content": "lo", "delta": true]),
            Self.jsonLine([
                "type": "result", "status": "success",
                "stats": ["input_tokens": 12, "output_tokens": 2, "cached": 4],
            ]),
        ]
        let runner = FakeRunner { _ in lines.joined(separator: "\n") }
        var partials: [String] = []
        let reply = try await GeminiPlanEngine(model: "gemini-3.5-flash", runner: runner)
            .generateStreaming(system: "s", prompt: "p", context: [], options: .init()) { partials.append($0) }

        XCTAssertEqual(reply, "Hello")
        XCTAssertEqual(partials.last, "Hello")
        XCTAssertEqual(value(after: "--output-format", in: runner.calls[0].arguments), "stream-json")
    }

    // MARK: Failures

    func testErrorClassificationAndNoRetryOnQuotaLimit() async throws {
        XCTAssertEqual(
            GeminiPlanEngine.failure(message: "API key not valid (API_KEY_INVALID)", statusCode: 400) as? GeminiPlanError,
            .signInRequired)
        guard case .failed(let detail)? = GeminiPlanEngine.failure(
            message: "Permission 'cloudaicompanion.licenses.selfAssign' denied", statusCode: 403) as? GeminiPlanError else {
            return XCTFail("expected clear Google Cloud onboarding message")
        }
        XCTAssertTrue(detail.contains("Google Cloud"))
        guard case .usageLimitReached? = GeminiPlanEngine.failure(
            message: "RESOURCE_EXHAUSTED: quota exceeded", statusCode: 429) as? GeminiPlanError else {
            return XCTFail("expected usageLimitReached")
        }
        XCTAssertEqual(
            (GeminiPlanEngine.failure(message: "Backend overloaded", statusCode: 503) as? TextEngineError)?.isRetryable,
            true)

        let runner = FakeRunner(status: 1) { _ in
            Self.jsonLine(["error": ["type": "Error", "message": "Quota exceeded", "code": 429]])
        }
        let gated = GatedTextEngine(
            base: GeminiPlanEngine(model: "gemini-3.5-flash", runner: runner),
            origin: SubscriptionPlan.gemini.consentKey,
            priority: .background,
            purpose: "test",
            gate: RemoteInferenceGate(),
            sleep: { _ in })
        do {
            _ = try await gated.generate(system: "", prompt: "p", context: [])
            XCTFail("expected usage limit")
        } catch let error as GeminiPlanError {
            guard case .usageLimitReached = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(runner.calls.count, 1)
    }

    // MARK: Discovery & Models

    func testLocateAndEnvironmentAndModelsJSON() {
        let home = "/Users/test"
        let found = GeminiCLI.locate(
            environment: ["PATH": "/usr/bin"], home: home,
            isExecutable: { $0 == "/opt/homebrew/bin/gemini" })
        XCTAssertEqual(found?.path, "/opt/homebrew/bin/gemini")

        let env = GeminiCLI.environment(
            for: URL(fileURLWithPath: "/opt/homebrew/bin/gemini"),
            base: ["PATH": "/usr/bin", "GEMINI_HOME": "/tmp/harness", "HOME": home],
            systemPromptPath: "/tmp/p/system-prompt.md",
            systemSettingsPath: "/tmp/p/system-settings.json")
        XCTAssertNil(env["GEMINI_HOME"])
        XCTAssertEqual(env["GEMINI_SYSTEM_MD"], "/tmp/p/system-prompt.md")
        XCTAssertEqual(env["GEMINI_CLI_SYSTEM_SETTINGS_PATH"], "/tmp/p/system-settings.json")
        XCTAssertEqual(env["GEMINI_CLI_TRUST_WORKSPACE"], "true")
        XCTAssertEqual(env["NO_COLOR"], "1")

        let models = GeminiCLI.parseModelsJSON(Data("""
        [
          {"modelId": "auto", "displayName": "Auto", "contextLimits": {"inputTokens": 1048576}},
          {"modelId": "gemini-2.5-pro", "displayName": "gemini-2.5-pro", "contextLimits": {"inputTokens": 1048576}},
          {"modelId": "gemini-3.5-flash", "displayName": "gemini-3.5-flash", "contextLimits": {"inputTokens": 1048576}}
        ]
        """.utf8))
        XCTAssertEqual(models, [
            .init(slug: "", displayName: "Gemini CLI default (Auto)", inputTokens: 1_048_576),
            .init(slug: "gemini-2.5-pro", displayName: "gemini-2.5-pro", inputTokens: 1_048_576),
            .init(slug: "gemini-3.5-flash", displayName: "gemini-3.5-flash", inputTokens: 1_048_576),
        ])
    }
}
