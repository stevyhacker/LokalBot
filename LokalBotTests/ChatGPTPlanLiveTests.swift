import XCTest
@testable import LokalBot

/// Sends Agent Mode's requests to the ChatGPT plan route with the sign-in
/// this Mac's LokalBot already holds: first the bodies pi-ai 1.3.0's
/// Responses client builds for a tool turn and its follow-up (instructions
/// as a developer message, top-level function tools, encrypted reasoning
/// replayed with the call and its output), then a real pi turn through
/// `ChatGPTPlanRelay`. Runs only when
/// `LOKALBOT_CHATGPT_PLAN_LIVE=1` (pass `TEST_RUNNER_LOKALBOT_CHATGPT_PLAN_LIVE=1`
/// through xcodebuild). A test build's first Keychain read asks for approval;
/// a refreshed token is saved back, so the app stays signed in.
/// `LOKALBOT_CHATGPT_PLAN_MODEL` overrides the first listed model.
final class ChatGPTPlanLiveTests: XCTestCase {
    private struct Reply {
        var status = 0
        var outcome: String?
        var items: [[String: Any]] = []
        var text = ""
        var error: String?
    }

    private static let instructions = "You are a test agent. When asked for a code word, call lookup_code and answer with the code word only."
    private static let tool: [String: Any] = [
        "type": "function",
        "name": "lookup_code",
        "description": "Returns the code word stored in a numbered box.",
        "parameters": [
            "type": "object",
            "properties": ["box": ["type": "integer"]],
            "required": ["box"],
            "additionalProperties": false,
        ] as [String: Any],
    ]

    private func liveModel() async throws -> String {
        let environment = ProcessInfo.processInfo.environment
        guard environment["LOKALBOT_CHATGPT_PLAN_LIVE"] == "1" else {
            throw XCTSkip("Set LOKALBOT_CHATGPT_PLAN_LIVE=1 to send requests on your ChatGPT plan.")
        }
        let status = await ChatGPTPlanAccount.shared.status()
        guard status.allowsPlanUsage else {
            throw XCTSkip("Sign in with ChatGPT in LokalBot before running live tests.")
        }
        if let model = environment["LOKALBOT_CHATGPT_PLAN_MODEL"], !model.isEmpty { return model }
        let models = try await ChatGPTPlanAccount.shared.models()
        print("chatgpt plan live: models=\(models.map(\.slug))")
        return try XCTUnwrap(models.first?.slug)
    }

    private func body(model: String, input: [[String: Any]]) -> [String: Any] {
        [
            "model": model,
            "input": input,
            "stream": true,
            "prompt_cache_key": "lokalbot-live-\(name)",
            "store": false,
            "tools": [Self.tool],
            "reasoning": ["effort": "low", "summary": "auto"],
            "include": ["reasoning.encrypted_content"],
        ]
    }

    private func send(_ body: [String: Any]) async throws -> Reply {
        var token = try await ChatGPTPlanAccount.shared.accessToken()
        for attempt in 0..<2 {
            var request = URLRequest(url: ChatGPTPlanEngine.responsesURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            var reply = Reply(status: (response as? HTTPURLResponse)?.statusCode ?? 0)
            if reply.status == 401, attempt == 0 {
                token = try await ChatGPTPlanAccount.shared.accessTokenAfterRejection(of: token)
                continue
            }
            guard (200...299).contains(reply.status) else {
                var data = Data()
                for try await byte in bytes { data.append(byte) }
                let error = ChatGPTPlanEngine.errorObject(data)
                reply.error = "\(error.code ?? "-") \(error.param ?? "-"): \(error.message ?? "")"
                return reply
            }
            for try await line in bytes.lines {
                guard line.hasPrefix("data:"),
                      let event = try? JSONSerialization.jsonObject(
                        with: Data(line.dropFirst(5).trimmingCharacters(in: .whitespaces).utf8)) as? [String: Any],
                      let type = event["type"] as? String else { continue }
                switch type {
                case "response.output_item.done":
                    if let item = event["item"] as? [String: Any] { reply.items.append(item) }
                case "response.output_text.delta":
                    reply.text += event["delta"] as? String ?? ""
                case "response.completed", "response.incomplete", "response.failed":
                    reply.outcome = type
                    let response = event["response"] as? [String: Any]
                    if let error = response?["error"] as? [String: Any] {
                        reply.error = "\(error["code"] as? String ?? "-"): \(error["message"] as? String ?? "")"
                    }
                    print("chatgpt plan live: \(type) usage=\(response?["usage"] as? [String: Any] ?? [:])")
                case "error":
                    reply.outcome = type
                    reply.error = "\(event["code"] as? String ?? "-"): \(event["message"] as? String ?? "")"
                default:
                    break
                }
            }
            print("chatgpt plan live: status=\(reply.status) outcome=\(reply.outcome ?? "none") "
                  + "items=\(reply.items.map { $0["type"] as? String ?? "?" })")
            return reply
        }
        throw ChatGPTPlanError.signInRequired
    }

    func testFunctionToolRoundTrip() async throws {
        let model = try await liveModel()
        print("chatgpt plan live: model=\(model)")
        var input: [[String: Any]] = [
            ["role": "developer", "content": Self.instructions],
            ["role": "user", "content": [["type": "input_text", "text": "What is the code word in box 7?"]]],
        ]
        let first = try await send(body(model: model, input: input))
        XCTAssertNil(first.error, "tool turn rejected: \(first.error ?? "")")
        XCTAssertEqual(first.outcome, "response.completed")
        let call = try XCTUnwrap(first.items.first { $0["type"] as? String == "function_call" },
                                 "the model did not call the tool")
        XCTAssertEqual(call["name"] as? String, "lookup_code")
        let arguments = try JSONSerialization.jsonObject(
            with: Data((call["arguments"] as? String ?? "").utf8)) as? [String: Any]
        XCTAssertEqual(arguments?["box"] as? Int, 7)

        // Replay as pi does: reasoning items as returned, the call without
        // its status, then the tool's output.
        for item in first.items {
            switch item["type"] as? String {
            case "reasoning":
                input.append(item.filter { ["type", "id", "summary", "encrypted_content"].contains($0.key) })
            case "function_call":
                input.append(item.filter { ["type", "id", "call_id", "name", "arguments"].contains($0.key) })
            default:
                break
            }
        }
        input.append(["type": "function_call_output", "call_id": try XCTUnwrap(call["call_id"] as? String),
                      "output": "heliotrope"])
        let second = try await send(body(model: model, input: input))
        XCTAssertNil(second.error, "tool result turn rejected: \(second.error ?? "")")
        XCTAssertEqual(second.outcome, "response.completed")
        XCTAssertTrue(second.text.localizedCaseInsensitiveContains("heliotrope"), second.text)
    }

    /// Agent Mode's whole path: the installed pi runtime with this build's
    /// extension speaks the Responses API to the relay, which forwards to the
    /// plan. pi reads a file in its working folder (no approval needed) and
    /// answers from it, so the turn needs a tool call, its result, and pi's
    /// replay of the encrypted reasoning. `LOKALBOT_AGENT_RUNTIME_ROOT`
    /// overrides the installed runtime.
    func testPiRunsAToolTurnOnThePlanThroughTheRelay() async throws {
        let model = try await liveModel()
        let runtime = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LOKALBOT_AGENT_RUNTIME_ROOT"]
            ?? NSHomeDirectory() + "/Library/Application Support/me.dotenv.LokalBot/agent-runtime")
        let bun = AgentRuntimeLayout.bunBinary(under: runtime)
        guard FileManager.default.isExecutableFile(atPath: bun.path) else {
            throw XCTSkip("Install Agent Mode's runtime, or set LOKALBOT_AGENT_RUNTIME_ROOT.")
        }
        let resources = try XCTUnwrap(Bundle.main.resourceURL)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lokalbot-plan-agent-\(UUID().uuidString)", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "The code word is heliotrope.\n".write(to: workspace.appendingPathComponent("notes.txt"),
                                                  atomically: true, encoding: .utf8)

        let relay = try await ChatGPTPlanRelay.start()
        defer { relay.stop() }
        let plan = PiLaunchPlanner.plan(
            bun: bun,
            piCLI: AgentRuntimeLayout.piCLI(under: runtime),
            extensionDirectory: resources.appendingPathComponent("pi/lokalbot-extension"),
            skillDirectory: nil,
            systemPrompt: resources.appendingPathComponent("pi/system-prompt.md"),
            sessionDirectory: root.appendingPathComponent("sessions", isDirectory: true),
            workspace: workspace,
            workspaceKind: .agentWorkspace,
            endpoint: AgentLLMEndpoint(baseURL: relay.baseURL, model: model, contextTokens: 128_000,
                                       apiKey: relay.key, reasoningDialect: .openAI, api: .responses,
                                       plan: .chatGPT),
            helpersDirectory: nil)
        let process = PiProcess(plan: plan)
        try await process.start()
        let watchdog = Task {
            try await Task.sleep(for: .seconds(240))
            await process.stop()
        }
        let rpc = PiRPCClient(transport: process)
        await rpc.run()
        var tools: [String] = []
        var reply = ""
        var failure: String?
        do {
            let response = try await rpc.request(.prompt(
                id: "live", message: "Read notes.txt in the working folder and reply with only the code word in it.",
                streamingBehavior: nil))
            XCTAssertTrue(response.success, response.error ?? "")
            let stream = await rpc.events
            events: for await event in stream {
                switch event {
                case .toolExecutionStart(_, let name, _):
                    tools.append(name)
                case .messageEnd("assistant", let text, let stopReason, let errorMessage):
                    if !text.isEmpty { reply = text }
                    if stopReason == "error" { failure = errorMessage ?? "error" }
                case .extensionUIRequest(let request):
                    // Nothing in this turn needs approval.
                    try await rpc.sendResponse(.uiConfirmResponse(requestID: request.id, confirmed: false))
                case .extensionError(let message):
                    failure = message
                case .agentEnd:
                    break events
                default:
                    break
                }
            }
        } catch {
            failure = error.localizedDescription
        }
        watchdog.cancel()
        await process.stop()
        print("chatgpt plan live: agent tools=\(tools) reply=\(reply.prefix(80))")
        XCTAssertNil(failure)
        XCTAssertTrue(tools.contains("read"), "pi answered without reading the file: \(tools)")
        XCTAssertTrue(reply.localizedCaseInsensitiveContains("heliotrope"), reply)
    }
}
