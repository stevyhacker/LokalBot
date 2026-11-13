import XCTest
@testable import LokalBot

final class ClaudePlanEngineTests: XCTestCase {
    final class FakeRunner: ClaudeCodeRunning, @unchecked Sendable {
        struct Call {
            var arguments: [String]
            var input: String
            var files: [String: String]
        }

        private let lock = NSLock()
        private var recorded: [Call] = []
        private let stdout: (Int) -> String
        private let lines: [String]

        init(lines: [String] = [], stdout: @escaping (Int) -> String) {
            self.stdout = stdout
            self.lines = lines
        }

        var calls: [Call] { lock.withLock { recorded } }

        func run(arguments: [String], input: Data, files: [String: Data],
                 onLine: (@Sendable (String) -> Void)?) async throws -> ClaudeCodeProcess.Output {
            let count: Int = lock.withLock {
                recorded.append(Call(arguments: arguments, input: String(decoding: input, as: UTF8.self),
                                     files: files.mapValues { String(decoding: $0, as: UTF8.self) }))
                return recorded.count
            }
            let output = stdout(count)
            if let onLine { output.split(separator: "\n").forEach { onLine(String($0)) } }
            return ClaudeCodeProcess.Output(status: 0, stdout: Data(output.utf8), stderrTail: "")
        }
    }

    static func jsonLine(_ object: Any) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    static func result(_ fields: [String: Any]) -> String {
        var object: [String: Any] = ["type": "result", "subtype": "success", "is_error": false,
                                     "stop_reason": "end_turn", "result": "",
                                     "usage": ["input_tokens": 10, "cache_creation_input_tokens": 100,
                                               "cache_read_input_tokens": 50, "output_tokens": 7]]
        object.merge(fields) { _, new in new }
        return jsonLine(object)
    }

    private func value(after flag: String, in arguments: [String]) -> String? {
        arguments.firstIndex(of: flag).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
    }

    // MARK: Arguments

    func testArgumentsKeepClaudeCodeToAPlainTextModel() throws {
        let engine = ClaudePlanEngine(model: "sonnet")
        let arguments = engine.arguments(structured: false, options: nil, streaming: false)

        XCTAssertEqual(Array(arguments.prefix(3)), ["-p", "--output-format", "json"])
        XCTAssertTrue(arguments.contains("--no-session-persistence"),
                      "prompts must never land in ~/.claude/projects, which LokalBot reads as evidence")
        XCTAssertTrue(arguments.contains("--safe-mode"))
        XCTAssertTrue(arguments.contains("--disable-slash-commands"))
        XCTAssertTrue(arguments.contains("--strict-mcp-config"))
        XCTAssertEqual(value(after: "--tools", in: arguments), "")
        XCTAssertEqual(value(after: "--setting-sources", in: arguments), "")
        XCTAssertEqual(value(after: "--mcp-config", in: arguments), #"{"mcpServers":{}}"#)
        XCTAssertEqual(value(after: "--system-prompt-file", in: arguments), ClaudePlanEngine.systemPromptFile)
        XCTAssertEqual(value(after: "--model", in: arguments), "sonnet")
        XCTAssertFalse(arguments.contains("--bare"), "--bare ignores the Claude plan sign-in")
        XCTAssertFalse(arguments.contains("--dangerously-skip-permissions"))
        XCTAssertNil(value(after: "--effort", in: arguments), "Automatic leaves open tasks at the default")
    }

    func testStreamingAndStructuredArguments() throws {
        let arguments = ClaudePlanEngine(model: "").arguments(
            structured: true, options: .init(reasoningBudgetTokens: 0), streaming: true)

        XCTAssertEqual(value(after: "--input-format", in: arguments), "stream-json")
        XCTAssertEqual(value(after: "--output-format", in: arguments), "stream-json")
        XCTAssertTrue(arguments.contains("--verbose"))
        XCTAssertTrue(arguments.contains("--include-partial-messages"))
        XCTAssertNil(value(after: "--model", in: arguments), "empty uses Claude Code's default")
        // Notes run with no reasoning budget: the lowest effort, not the default.
        XCTAssertEqual(value(after: "--effort", in: arguments), "low")
        XCTAssertFalse(arguments.contains("--json-schema"), "a schema can hold meeting text")

        let plain = ClaudePlanEngine(model: "").arguments(structured: true, options: nil, streaming: false)
        XCTAssertEqual(value(after: "--output-format", in: plain), "stream-json",
                       "stream-json input needs stream-json output")
        XCTAssertTrue(plain.contains("--verbose"))
        XCTAssertFalse(plain.contains("--include-partial-messages"))
    }

    /// A notes repair lists the meeting's action items as the allowed values
    /// of a field. A command line is readable by other processes, so the
    /// schema travels on stdin with the prompt.
    func testSchemaTravelsOnStdinNeverInTheArguments() async throws {
        let runner = FakeRunner { _ in
            Self.result(["stop_reason": "tool_use", "structured_output": ["text": "Send Marko the Q3 budget"]])
        }
        let schema: [String: Any] = [
            "type": "object",
            "properties": ["text": ["type": "string", "enum": ["Send Marko the Q3 budget"]],
                           "items": ["type": "array", "maxItems": 3]],
        ]
        let reply = try await ClaudePlanEngine(model: "haiku", runner: runner)
            .generate(system: "Repair.", prompt: "Which action?", context: ["Transcript"], schema: schema)

        XCTAssertEqual(reply, #"{"text":"Send Marko the Q3 budget"}"#)
        let call = try XCTUnwrap(runner.calls.first)
        XCTAssertFalse(call.arguments.contains { $0.contains("Marko") || $0.contains("enum") },
                       "\(call.arguments)")
        XCTAssertFalse(call.arguments.contains("--json-schema"))
        XCTAssertEqual(value(after: "--input-format", in: call.arguments), "stream-json")
        let lines = try call.input.split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0]["type"] as? String, "control_request")
        let request = try XCTUnwrap(lines[0]["request"] as? [String: Any])
        XCTAssertEqual(request["subtype"] as? String, "initialize")
        XCTAssertEqual(request["jsonSchema"] as? NSDictionary, schema as NSDictionary,
                       "Claude Code gets the schema unchanged")
        XCTAssertEqual(lines[1]["type"] as? String, "user")
        let message = try XCTUnwrap(lines[1]["message"] as? [String: Any])
        let content = try XCTUnwrap(message["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["text"] as? String, "Transcript\n\nWhich action?")
    }

    func testChosenEffortIsCappedByTheTaskBudget() throws {
        let engine = ClaudePlanEngine(model: "claude-opus-5-5", reasoningLevel: .max)
        XCTAssertEqual(engine.effort(for: nil), .max)
        XCTAssertEqual(engine.effort(for: .init(reasoningBudgetTokens: 4_096)), .medium)
        XCTAssertEqual(ClaudePlanEngine(model: "opus", reasoningLevel: .xhigh).effort(for: nil), .xhigh)
    }

    // MARK: Requests

    func testRequestWritesSystemPromptToAFileAndContextToStdin() async throws {
        let runner = FakeRunner { _ in Self.result(["result": "Done."]) }
        let reply = try await ClaudePlanEngine(model: "haiku", runner: runner)
            .generate(system: "Write notes.", prompt: "Summarize.", context: ["Transcript", " "])

        XCTAssertEqual(reply, "Done.")
        let call = try XCTUnwrap(runner.calls.first)
        XCTAssertEqual(call.files, [ClaudePlanEngine.systemPromptFile: "Write notes."])
        XCTAssertEqual(call.input, "Transcript\n\nSummarize.")
        XCTAssertFalse(call.arguments.contains { $0.contains("Write notes.") || $0.contains("Transcript") },
                       "content never appears in the process arguments")
    }

    func testEmptySystemPromptReplacesClaudeCodesCodingPrompt() async throws {
        let runner = FakeRunner { _ in Self.result(["result": "Hi"]) }
        _ = try await ClaudePlanEngine(model: "", runner: runner).generate(system: " ", prompt: "Hi", context: [])
        XCTAssertEqual(runner.calls.first?.files[ClaudePlanEngine.systemPromptFile],
                       ClaudePlanEngine.fallbackSystemPrompt)
    }

    func testStructuredOutputIsReturnedAsJSON() async throws {
        let runner = FakeRunner { _ in
            Self.result(["result": "Here you go", "stop_reason": "tool_use",
                         "structured_output": ["title": "Weekly sync", "count": 2]])
        }
        let reply = try await ClaudePlanEngine(model: "sonnet", runner: runner)
            .generate(system: "s", prompt: "p", context: [], schema: ["type": "object"])
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
        XCTAssertEqual(parsed["title"] as? String, "Weekly sync")
        XCTAssertEqual(parsed["count"] as? Int, 2)
    }

    /// A Claude Code that ignores the schema sent on stdin answers in prose.
    /// That used to be returned as the structured reply, with no error.
    func testAProseReplyToASchemaRequestFails() throws {
        XCTAssertThrowsError(try ClaudePlanEngine.parseResult(
            ["type": "result", "result": "Here are the notes: the launch moved to Friday.", "stop_reason": "end_turn"],
            wantsStructured: true)) { error in
            guard case TextEngineError.badResponse = error else { return XCTFail("\(error)") }
        }
        // JSON as text is still a reply, with or without a code fence around it.
        XCTAssertEqual(try ClaudePlanEngine.parseResult(
            ["type": "result", "result": #"{"a": 1}"#, "stop_reason": "end_turn"], wantsStructured: true).text,
                       #"{"a": 1}"#)
        XCTAssertEqual(try ClaudePlanEngine.parseResult(
            ["type": "result", "result": "```json\n{\"a\": 1}\n```", "stop_reason": "end_turn"],
            wantsStructured: true).text, #"{"a": 1}"#)
        // Without a schema, prose is the answer.
        XCTAssertEqual(try ClaudePlanEngine.parseResult(
            ["type": "result", "result": "The launch moved to Friday.", "stop_reason": "end_turn"],
            wantsStructured: false).text, "The launch moved to Friday.")
        // A reply cut off at the output limit keeps its own handling.
        XCTAssertTrue(try ClaudePlanEngine.parseResult(
            ["type": "result", "result": #"{"a":"#, "stop_reason": "max_tokens"], wantsStructured: true).truncated)
    }

    @MainActor
    func testStreamingForwardsTextAndReturnsTheResult() async throws {
        let deltas = ["Hel", "lo"].map { text in
            Self.jsonLine([
                "type": "stream_event",
                "event": ["type": "content_block_delta", "delta": ["type": "text_delta", "text": text]],
            ])
        }
        let runner = FakeRunner { _ in
            (["{\"type\":\"system\",\"subtype\":\"init\"}"] + deltas + [Self.result(["result": "Hello"])])
                .joined(separator: "\n")
        }
        let partials = PartialLog()
        let reply = try await ClaudePlanEngine(model: "sonnet", runner: runner).generateStreaming(
            system: "s", prompt: "p", context: [], options: .init()) { partials.append($0) }

        XCTAssertEqual(reply, "Hello")
        XCTAssertEqual(partials.values.last, "Hello")
        XCTAssertEqual(value(after: "--output-format", in: runner.calls[0].arguments), "stream-json")
    }

    @MainActor final class PartialLog {
        private(set) var values: [String] = []
        func append(_ value: String) { values.append(value) }
    }

    // MARK: Failures

    func testSignedOutClaudeCodeAsksForSignIn() {
        let error = ClaudePlanEngine.failure(message: "Not logged in · Please run /login", apiStatus: nil)
        XCTAssertEqual(error as? ClaudePlanError, .signInRequired)
        XCTAssertThrowsError(try ClaudePlanEngine.parseResult([
            "type": "result", "subtype": "success", "is_error": true, "terminal_reason": "api_error",
            "result": "Not logged in · Please run /login",
        ], wantsStructured: false)) { error in
            XCTAssertEqual(error as? ClaudePlanError, .signInRequired)
        }
    }

    func testUsageLimitStopsAndOverloadRetries() {
        let limit = ClaudePlanEngine.failure(message: "Claude AI usage limit reached|1760000000", apiStatus: 429)
        guard case .usageLimitReached? = limit as? ClaudePlanError else { return XCTFail("\(limit)") }

        let overloaded = ClaudePlanEngine.failure(message: "API Error: 529 Overloaded", apiStatus: 529)
        XCTAssertEqual((overloaded as? TextEngineError)?.isRetryable, true)

        let other = ClaudePlanEngine.failure(message: "Something odd", apiStatus: nil)
        XCTAssertEqual((other as? TextEngineError)?.isRetryable, false)
    }

    func testUsageLimitIsNotReplayedThroughTheGate() async throws {
        let runner = FakeRunner { _ in
            Self.result(["is_error": true, "result": "Claude AI usage limit reached", "api_error_status": 429])
        }
        let gated = GatedTextEngine(base: ClaudePlanEngine(model: "sonnet", runner: runner),
                                    origin: SubscriptionPlan.claude.consentKey, priority: .background,
                                    purpose: "test", gate: RemoteInferenceGate(), sleep: { _ in })
        do {
            _ = try await gated.generate(system: "", prompt: "p", context: [])
            XCTFail("expected usage limit")
        } catch let error as ClaudePlanError {
            guard case .usageLimitReached = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(runner.calls.count, 1)
    }

    func testTruncationAndMissingResult() throws {
        XCTAssertTrue(try ClaudePlanEngine.parseResult(
            ["result": "{\"a\":", "stop_reason": "max_tokens"], wantsStructured: false).truncated)
        XCTAssertThrowsError(try ClaudePlanEngine.reply(
            from: .init(status: 1, stdout: Data("not json".utf8), stderrTail: "boom"),
            streaming: false, wantsStructured: false))
        XCTAssertThrowsError(try ClaudePlanEngine.reply(
            from: .init(status: 1, stdout: Data(), stderrTail: "Not logged in · Please run /login"),
            streaming: false, wantsStructured: false)) { error in
            XCTAssertEqual(error as? ClaudePlanError, .signInRequired)
        }
    }

    // MARK: Installation

    func testLocatePrefersPathThenKnownInstallLocations() {
        let home = "/Users/test"
        let onPath = ClaudeCodeCLI.locate(
            environment: ["PATH": "/usr/bin:/custom/bin"], home: home,
            isExecutable: { $0 == "/custom/bin/claude" || $0 == "\(home)/.local/bin/claude" })
        XCTAssertEqual(onPath?.path, "/custom/bin/claude")

        let installer = ClaudeCodeCLI.locate(environment: ["PATH": "/usr/bin"], home: home,
                                             isExecutable: { $0 == "\(home)/.local/bin/claude" })
        XCTAssertEqual(installer?.path, "\(home)/.local/bin/claude")

        XCTAssertNil(ClaudeCodeCLI.locate(environment: ["PATH": "relative/bin"], home: home,
                                          isExecutable: { $0 == "relative/bin/claude" }),
                     "a relative PATH entry is never executed")
    }

    func testChildEnvironmentFindsNodeBesideClaudeAndIsNotNested() {
        let environment = ClaudeCodeCLI.environment(
            for: URL(fileURLWithPath: "/Users/test/.nvm/versions/node/v24/bin/claude"),
            base: ["PATH": "/usr/bin:/bin", "CLAUDECODE": "1", "HOME": "/Users/test"])
        XCTAssertEqual(environment["PATH"],
                       "/Users/test/.nvm/versions/node/v24/bin:/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin")
        XCTAssertNil(environment["CLAUDECODE"])
        XCTAssertEqual(environment["HOME"], "/Users/test")
    }

    func testAuthStatusParsing() throws {
        let status = try XCTUnwrap(ClaudeCodeCLI.AuthStatus(json: Data(#"""
        {"loggedIn": true, "authMethod": "claude.ai", "apiProvider": "firstParty",
         "email": "ana@example.com", "subscriptionType": "max"}
        """#.utf8)))
        XCTAssertTrue(status.loggedIn)
        XCTAssertTrue(status.usesSubscription)
        XCTAssertEqual(status.planName, "Max")
        let signedOut = try XCTUnwrap(ClaudeCodeCLI.AuthStatus(json: Data(#"{"loggedIn": false, "authMethod": "none"}"#.utf8)))
        XCTAssertFalse(signedOut.loggedIn)
        XCTAssertNil(ClaudeCodeCLI.AuthStatus(json: Data("Usage: claude".utf8)))
    }

    // MARK: Process

    func testProcessRunnerPipesStdinAndSplitsLines() async throws {
        let lines = LineLog()
        let output = try await ClaudeCodeProcess.run(
            executable: URL(fileURLWithPath: "/bin/cat"), arguments: [], environment: [:],
            input: Data("first\nsecond".utf8), timeout: .seconds(10)) { lines.append($0) }
        XCTAssertEqual(output.status, 0)
        XCTAssertEqual(String(decoding: output.stdout, as: UTF8.self), "first\nsecond")
        XCTAssertEqual(lines.values, ["first", "second"])
    }

    func testLargeInputToAnEarlyExitingChildDoesNotCrash() async throws {
        let output = try await ClaudeCodeProcess.run(
            executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [], environment: [:],
            input: Data(repeating: 0x61, count: 4 * 1_024 * 1_024), timeout: .seconds(10))
        XCTAssertEqual(output.status, 0)
    }

    func testCancellationStopsTheChild() async throws {
        let started = ProcessInfo.processInfo.systemUptime
        let task = Task {
            try await ClaudeCodeProcess.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"],
                                            environment: [:], timeout: .seconds(60))
        }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {}
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 10)
    }

    func testMissingExecutableIsNotInstalled() async {
        do {
            _ = try await ClaudeCodeProcess.run(executable: URL(fileURLWithPath: "/nonexistent/claude"),
                                                arguments: [], environment: [:])
            XCTFail("expected notInstalled")
        } catch {
            XCTAssertEqual(error as? ClaudePlanError, .notInstalled)
        }
    }

    final class LineLog: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        var values: [String] { lock.withLock { stored } }
        func append(_ value: String) { lock.withLock { stored.append(value) } }
    }
}
