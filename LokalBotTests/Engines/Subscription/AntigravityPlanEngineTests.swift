import XCTest
@testable import LokalBot

final class AntigravityPlanEngineTests: XCTestCase {
    final class FakeRunner: AntigravityRunning, @unchecked Sendable {
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

    static func resultEvent(_ fields: [String: Any]) -> String {
        var result: [String: Any] = [
            "conversation_id": "conv-1",
            "status": "SUCCESS",
            "response": "",
            "duration_seconds": 1.2,
            "num_turns": 1,
            "usage": ["input_tokens": 100, "output_tokens": 12, "thinking_tokens": 4,
                      "cache_read_tokens": 50, "total_tokens": 112],
        ]
        result.merge(fields) { _, new in new }
        return jsonLine(["event": "result", "result": result])
    }

    private func value(after flag: String, in arguments: [String]) -> String? {
        arguments.firstIndex(of: flag).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
    }

    func testArgumentsEnforceIsolatedHeadlessStreamMode() {
        let engine = AntigravityPlanEngine(model: "gemini-4-neon")
        let arguments = engine.arguments(structured: false, options: nil)

        XCTAssertEqual(value(after: "--input-format", in: arguments), "stream-json")
        XCTAssertEqual(value(after: "--output-format", in: arguments), "stream-json")
        XCTAssertTrue(arguments.contains("--disable-slash-commands"))
        XCTAssertEqual(value(after: "--agent", in: arguments), AntigravityPlanEngine.agentName)
        XCTAssertEqual(value(after: "--settings", in: arguments), AntigravityPlanEngine.settingsFilePath)
        XCTAssertEqual(value(after: "--log-file", in: arguments), AntigravityPlanEngine.logFilePath)
        XCTAssertEqual(value(after: "--model", in: arguments), "gemini-4-neon")
        XCTAssertNil(value(after: "--json-schema", in: arguments))
        XCTAssertNil(value(after: "--effort", in: arguments))
        XCTAssertFalse(arguments.contains("--dangerously-skip-permissions"))
        XCTAssertFalse(arguments.contains("-p"))
    }

    func testEffortAvoidsConflictWithExplicitEffortSlugAndCapsByBudget() {
        let base = AntigravityPlanEngine(model: "gemini-4-neon", reasoningLevel: .xhigh)
        XCTAssertEqual(base.effort(for: nil), .xhigh)
        XCTAssertEqual(base.effort(for: .init(reasoningBudgetTokens: 4_096)), .medium)
        XCTAssertEqual(base.effort(for: .init(reasoningBudgetTokens: 0)), .low)

        let automatic = AntigravityPlanEngine(model: "gemini-3.8-flash", reasoningLevel: .automatic)
        XCTAssertEqual(automatic.effort(for: .init(reasoningBudgetTokens: 0)), .low)
        XCTAssertNil(automatic.effort(for: nil))

        let pinned = AntigravityPlanEngine(model: "gemini-4-neon-high", reasoningLevel: .low)
        XCTAssertFalse(pinned.traits.support.isAdjustable)
        XCTAssertNil(pinned.effort(for: nil))
        XCTAssertNil(value(after: "--effort", in: pinned.arguments(structured: false, options: nil)))

        let orchestrator = AntigravityPlanEngine(model: "gemini-pro-orchestrator-neon", reasoningLevel: .high)
        XCTAssertNil(orchestrator.effort(for: nil))
    }

    func testHookMatcherDeniesEveryToolExceptFinish() throws {
        let regex = try NSRegularExpression(pattern: AntigravityPlanEngine.denyNonFinishMatcher)
        func matches(_ name: String) -> Bool {
            let range = NSRange(name.startIndex..<name.endIndex, in: name)
            return regex.firstMatch(in: name, range: range) != nil
        }

        XCTAssertFalse(matches("finish"))
        for blocked in ["run_command", "view_file", "write_to_file", "search_web", "read_url_content",
                        "call_mcp_tool", "list_resources", "read_resource", "manage_task",
                        "invoke_subagent", "browser_subagent", "find_by_name", "f", "fi", "fin",
                        "fini", "finis", "finish_task", "finish2"] {
            XCTAssertTrue(matches(blocked), "PreToolUse deny matcher must block \(blocked)")
        }
    }

    func testSessionSettingsAndHooksAreValidJSON() throws {
        let settings = try XCTUnwrap(
            JSONSerialization.jsonObject(with: AntigravityPlanEngine.sessionSettingsJSON) as? [String: Any])
        XCTAssertEqual(settings["toolPermission"] as? String, "strict")
        XCTAssertEqual(settings["allowNonWorkspaceAccess"] as? Bool, false)
        XCTAssertEqual(settings["disableSlashCommands"] as? Bool, true)
        let permissions = try XCTUnwrap(settings["permissions"] as? [String: Any])
        let deny = try XCTUnwrap(permissions["deny"] as? [String])
        XCTAssertTrue(deny.contains("command(*)"))
        XCTAssertTrue(deny.contains("read_file(*)"))
        XCTAssertTrue(deny.contains("mcp(*)"))

        let hooks = try XCTUnwrap(
            JSONSerialization.jsonObject(with: AntigravityPlanEngine.hooksJSON) as? [String: Any])
        XCTAssertNotNil(hooks["lokalbot-deny-tools"])
    }

    func testRequestSendsContentOnStdinAndSchemaInPrivateFile() async throws {
        let runner = FakeRunner { _ in
            Self.resultEvent(["response": #"{"text":"Send Marko the Q3 budget"}"#,
                              "structured_output": ["text": "Send Marko the Q3 budget"]])
        }
        let schema: [String: Any] = [
            "type": "object",
            "properties": ["text": ["type": "string", "enum": ["Send Marko the Q3 budget"]]],
            "required": ["text"],
        ]
        let reply = try await AntigravityPlanEngine(model: "gemini-3.8-flash", runner: runner)
            .generate(system: "Write notes.", prompt: "Which action?", context: ["Transcript", " "], schema: schema)

        XCTAssertEqual(reply, #"{"text":"Send Marko the Q3 budget"}"#)
        let call = try XCTUnwrap(runner.calls.first)
        XCTAssertEqual(value(after: "--json-schema", in: call.arguments), AntigravityPlanEngine.schemaFilePath)
        XCTAssertFalse(call.arguments.contains { $0.contains("Marko") || $0.contains("Transcript") || $0.contains("Write notes.") },
                       "content and schema values must never appear in argv: \(call.arguments)")

        let inputObj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(call.input.trimmingCharacters(in: .newlines).utf8)) as? [String: Any])
        XCTAssertEqual(inputObj["event"] as? String, "user")
        let message = try XCTUnwrap(inputObj["message"] as? [String: Any])
        XCTAssertEqual(message["content"] as? String, "Transcript\n\nWhich action?")

        let agentDoc = try XCTUnwrap(call.files[AntigravityPlanEngine.agentFilePath])
        XCTAssertTrue(agentDoc.contains("name: lokalbot-think"))
        XCTAssertTrue(agentDoc.contains("Write notes."))
        XCTAssertNotNil(call.files[AntigravityPlanEngine.hooksFilePath])
        XCTAssertNotNil(call.files[AntigravityPlanEngine.settingsFilePath])
        let schemaFile = try XCTUnwrap(call.files[AntigravityPlanEngine.schemaFilePath])
        XCTAssertTrue(schemaFile.contains("Send Marko the Q3 budget"))
    }

    func testEmptySystemPromptUsesFallback() async throws {
        let runner = FakeRunner { _ in Self.resultEvent(["response": "Hi"]) }
        _ = try await AntigravityPlanEngine(model: "", runner: runner).generate(system: " ", prompt: "Hi", context: [])
        let agentDoc = try XCTUnwrap(runner.calls.first?.files[AntigravityPlanEngine.agentFilePath])
        XCTAssertTrue(agentDoc.contains(AntigravityPlanEngine.fallbackSystemPrompt))
        XCTAssertNil(value(after: "--model", in: runner.calls[0].arguments))
    }

    func testProseReplyToSchemaRequestFails() throws {
        XCTAssertThrowsError(try AntigravityPlanEngine.parseResult(
            ["status": "SUCCESS", "response": "Here are the notes: launch is Friday."],
            wantsStructured: true)) { error in
            guard case TextEngineError.badResponse = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try AntigravityPlanEngine.parseResult(
            ["status": "SUCCESS", "response": "```json\n{\"a\": 1}\n```"],
            wantsStructured: true).text, #"{"a": 1}"#)
    }

    @MainActor
    func testStreamingForwardsDeltasAndReturnsResult() async throws {
        let deltas = ["Hel", "lo"].map { chunk in
            Self.jsonLine([
                "event": "step_update",
                "step_update": ["step_type": "agent_response", "state": "ACTIVE", "text_delta": chunk],
            ])
        }
        let runner = FakeRunner { _ in
            ([Self.jsonLine(["event": "init", "conversation_id": "c1"])] + deltas
             + [Self.resultEvent(["response": "Hello\n"])]).joined(separator: "\n")
        }
        var partials: [String] = []
        let reply = try await AntigravityPlanEngine(model: "gemini-3.8-flash", runner: runner)
            .generateStreaming(system: "s", prompt: "p", context: [], options: .init()) { partials.append($0) }

        XCTAssertEqual(reply, "Hello")
        XCTAssertEqual(partials.last, "Hello")
    }

    func testErrorClassificationAndNoRetryOnUsageLimit() async throws {
        XCTAssertEqual(
            AntigravityPlanEngine.failure(message: "authentication failed or timed out") as? AntigravityPlanError,
            .signInRequired)
        guard case .usageLimitReached? = AntigravityPlanEngine.failure(
            message: "Quota exhausted for gemini-4-neon (429)") as? AntigravityPlanError else {
            return XCTFail("expected usageLimitReached")
        }
        XCTAssertEqual(
            (AntigravityPlanEngine.failure(message: "503 Service temporarily unavailable") as? TextEngineError)?.isRetryable,
            true)

        let runner = FakeRunner { _ in
            Self.resultEvent(["status": "ERROR", "error": "Quota exhausted for model"])
        }
        let gated = GatedTextEngine(
            base: AntigravityPlanEngine(model: "gemini-4-neon", runner: runner),
            origin: SubscriptionPlan.antigravity.consentKey,
            priority: .background,
            purpose: "test",
            gate: RemoteInferenceGate(),
            sleep: { _ in })
        do {
            _ = try await gated.generate(system: "", prompt: "p", context: [])
            XCTFail("expected usage limit")
        } catch let error as AntigravityPlanError {
            guard case .usageLimitReached = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(runner.calls.count, 1)
    }

    func testLocateAndEnvironmentScrubNestedVariables() {
        let home = "/Users/test"
        let found = AntigravityCLI.locate(
            environment: ["PATH": "/usr/bin"], home: home,
            isExecutable: { $0 == "\(home)/.local/bin/agy" })
        XCTAssertEqual(found?.path, "\(home)/.local/bin/agy")

        XCTAssertNil(AntigravityCLI.locate(
            environment: ["PATH": "relative/bin"], home: home,
            isExecutable: { $0 == "relative/bin/agy" }))

        let env = AntigravityCLI.environment(
            for: URL(fileURLWithPath: "/Users/test/.local/bin/agy"),
            base: [
                "PATH": "/usr/bin:/bin",
                "HOME": "/Users/test",
                "ANTIGRAVITY_AGENT": "1",
                "ANTIGRAVITY_CSRF_TOKEN": "secret",
                "AGY_ACP_FORCE_FILE_STORAGE": "1",
                "GEMINI_HOME": "/tmp/harness",
            ])
        XCTAssertNil(env["ANTIGRAVITY_AGENT"])
        XCTAssertNil(env["ANTIGRAVITY_CSRF_TOKEN"])
        XCTAssertNil(env["AGY_ACP_FORCE_FILE_STORAGE"])
        XCTAssertNil(env["GEMINI_HOME"])
        XCTAssertEqual(env["HOME"], "/Users/test")
        XCTAssertTrue(env["PATH"]?.hasPrefix("/Users/test/.local/bin:") == true)
    }

    func testParseModelsGroupsEffortVariantsAndStripsSpinner() {
        let raw = "\r⠋ Fetching available models...\r" + """
        gemini-4-neon-high             Gemini 4 Neon (High)
        gemini-4-neon-xhigh            Gemini 4 Neon (XHigh)
        gemini-4-neon-medium           Gemini 4 Neon (Medium)
        gemini-4-neon-low              Gemini 4 Neon (Low)
        gemini-pro-orchestrator-neon   Orchestrator (Neon)
        gemini-3.8-flash-high          Gemini 3.8 Flash (High)
        gemini-3.8-flash-low           Gemini 3.8 Flash (Low)
        gpt-oss-120b-medium            GPT-OSS 120B (Medium)
        """
        let models = AntigravityCLI.parseModelsOutput(Data(raw.utf8))
        XCTAssertEqual(models, [
            .init(slug: "gemini-4-neon", displayName: "Gemini 4 Neon",
                  effortLevels: [.low, .medium, .high, .xhigh]),
            .init(slug: "gemini-pro-orchestrator-neon", displayName: "Orchestrator (Neon)", effortLevels: []),
            .init(slug: "gemini-3.8-flash", displayName: "Gemini 3.8 Flash", effortLevels: [.low, .high]),
            .init(slug: "gpt-oss-120b-medium", displayName: "GPT-OSS 120B (Medium)", effortLevels: []),
        ])

        let piped = """
        Fetching available models...
        gemini-4-neon-high\tGemini 4 Neon (High)
        gemini-4-neon-low\tGemini 4 Neon (Low)
        gpt-oss-120b-medium\tGPT-OSS 120B (Medium)
        """
        XCTAssertEqual(AntigravityCLI.parseModelsOutput(Data(piped.utf8)), [
            .init(slug: "gemini-4-neon", displayName: "Gemini 4 Neon", effortLevels: [.low, .high]),
            .init(slug: "gpt-oss-120b-medium", displayName: "GPT-OSS 120B (Medium)", effortLevels: []),
        ])
    }
}
