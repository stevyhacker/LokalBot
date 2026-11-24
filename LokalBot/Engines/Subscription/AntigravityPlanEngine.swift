import Foundation

protocol AntigravityRunning: Sendable {
    func run(arguments: [String], input: Data, files: [String: Data],
             onLine: (@Sendable (String) -> Void)?) async throws -> PlanCLIProcess.Output
}

struct LiveAntigravityRunner: AntigravityRunning {
    func run(arguments: [String], input: Data, files: [String: Data],
             onLine: (@Sendable (String) -> Void)?) async throws -> PlanCLIProcess.Output {
        guard let executable = await AntigravityLocator.shared.executable() else {
            throw AntigravityPlanError.notInstalled
        }
        return try await PlanCLIProcess.withPrivateDirectory(
            prefix: "LokalBot-agy",
            files: files,
            failedError: AntigravityPlanError.failed
        ) { directory in
            try await PlanCLIProcess.run(
                executable: executable,
                arguments: arguments,
                environment: AntigravityCLI.environment(for: executable),
                workingDirectory: directory,
                input: input,
                programName: "Antigravity CLI",
                notInstalledError: AntigravityPlanError.notInstalled,
                failedError: AntigravityPlanError.failed,
                onLine: onLine)
        }
    }
}

struct AntigravityPlanEngine: TextEngine {
    var model: String
    var reasoningLevel: ThinkReasoningLevel = .automatic
    var runner: AntigravityRunning = LiveAntigravityRunner()

    static let agentName = "lokalbot-think"
    static let agentFilePath = ".agents/agents/\(agentName).md"
    static let hooksFilePath = ".agents/hooks.json"
    static let settingsFilePath = "settings.json"
    static let schemaFilePath = "schema.json"
    static let logFilePath = "agy.log"
    static let fallbackSystemPrompt = "You are a helpful assistant."

    static let denyNonFinishMatcher =
        "^([^f].*|f([^i].*|$)|fi([^n].*|$)|fin([^i].*|$)|fini([^s].*|$)|finis([^h].*|$)|finish.+)$"

    static let sessionSettingsJSON = Data("""
    {
      "toolPermission": "strict",
      "allowNonWorkspaceAccess": false,
      "disableSlashCommands": true,
      "permissions": {
        "allow": [],
        "ask": [],
        "deny": [
          "command(*)",
          "read_file(*)",
          "write_file(*)",
          "read_url(*)",
          "execute_url(*)",
          "mcp(*)",
          "unsandboxed(*)"
        ]
      }
    }
    """.utf8)

    static let hooksJSON = Data("""
    {
      "lokalbot-deny-tools": {
        "PreToolUse": [
          {
            "matcher": "\(denyNonFinishMatcher)",
            "hooks": [
              {
                "type": "command",
                "command": "printf '{\\"decision\\":\\"deny\\",\\"reason\\":\\"Tools are disabled for LokalBot Think requests.\\"}\\n'",
                "timeout": 5
              }
            ]
          }
        ]
      }
    }
    """.utf8)

    var displayName: String { "Antigravity plan — \(model.isEmpty ? "Antigravity default" : model)" }
    var checkpointIdentity: String { "\(displayName)|antigravity-plan|agy" }
    var accountsForGenerationRequests: Bool { true }
    var structuredOutputEnumLimit: Int? { 500 }

    var traits: (support: ReasoningSupport, thinksByDefault: Bool) {
        let name = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if AntigravityCLI.hasExplicitEffortSuffix(name) || name.contains("orchestrator") {
            return (.unavailable, true)
        }
        if name.isEmpty || name.contains("neon") || name.contains("hydrogen") {
            return (ReasoningSupport(levels: [.low, .medium, .high, .xhigh]), true)
        }
        return (ReasoningSupport(levels: [.low, .medium, .high]), true)
    }

    func effort(for options: TextGenerationOptions?) -> ThinkReasoningLevel? {
        let (support, thinksByDefault) = traits
        guard support.isAdjustable else { return nil }
        let reasoning = options?.reasoning ?? .modelDefault
        if let level = support.requestLevel(reasoningLevel, reasoning: reasoning) { return level }
        guard thinksByDefault, reasoning == .off else { return nil }
        return support.clamp(.off)
    }

    func generate(system: String, prompt: String, context: [String]) async throws -> String {
        try await request(system: system, prompt: prompt, context: context, schema: nil, options: nil, onPartial: nil)
    }

    func generate(system: String, prompt: String, context: [String],
                  options: TextGenerationOptions) async throws -> String {
        try await request(system: system, prompt: prompt, context: context, schema: nil, options: options,
                          onPartial: nil)
    }

    func generate(system: String, prompt: String, context: [String],
                  schema: [String: Any]) async throws -> String {
        try await request(system: system, prompt: prompt, context: context, schema: schema, options: nil,
                          onPartial: nil)
    }

    func generate(system: String, prompt: String, context: [String],
                  schema: [String: Any],
                  options: TextGenerationOptions) async throws -> String {
        try await request(system: system, prompt: prompt, context: context, schema: schema, options: options,
                          onPartial: nil)
    }

    func generateStreaming(system: String, prompt: String, context: [String],
                           options: TextGenerationOptions,
                           onPartial: @escaping @MainActor (String) -> Void) async throws -> String {
        let streamsPartials = MeetingGenerationBudget.current == nil
        let result = try await request(system: system, prompt: prompt, context: context, schema: nil,
                                       options: options, onPartial: streamsPartials ? onPartial : nil)
        await onPartial(result)
        return result
    }

    func arguments(structured: Bool, options: TextGenerationOptions?) -> [String] {
        var arguments = [
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--disable-slash-commands",
            "--agent", Self.agentName,
            "--settings", Self.settingsFilePath,
            "--log-file", Self.logFilePath,
        ]
        if structured {
            arguments += ["--json-schema", Self.schemaFilePath]
        }
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedModel.isEmpty {
            arguments += ["--model", trimmedModel]
        }
        if let effort = effort(for: options) {
            arguments += ["--effort", effort.rawValue]
        }
        return arguments
    }

    static func agentMarkdown(systemPrompt: String) -> Data {
        let body = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? fallbackSystemPrompt : systemPrompt
        let markdown = """
        ---
        name: \(agentName)
        description: Text-only response assistant for LokalBot Think
        tools:
          - finish
        mcpServers: []
        skills: []
        plugins: []
        commandExecutionPolicy: "off"
        ---
        \(body)
        """
        return Data(markdown.utf8)
    }

    static func streamInput(prompt: String, context: [String]) throws -> Data {
        let parts = (context + [prompt]).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let content = parts.joined(separator: "\n\n")
        let message: [String: Any] = [
            "event": "user",
            "message": ["content": content],
        ]
        var data = try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys])
        data.append(0x0A)
        return data
    }

    struct Reply: Equatable {
        var text: String
        var truncated: Bool
        var inputTokens: Int?
        var outputTokens: Int?
        var cachedTokens: Int?
    }

    static func parseStreamLine(_ line: String) -> (delta: String?, result: [String: Any]?) {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return (nil, nil) }
        switch json["event"] as? String {
        case "step_update":
            guard let step = json["step_update"] as? [String: Any],
                  step["step_type"] as? String == "agent_response",
                  let delta = step["text_delta"] as? String, !delta.isEmpty else { return (nil, nil) }
            return (delta, nil)
        case "result":
            guard let result = json["result"] as? [String: Any] else { return (nil, nil) }
            return (nil, result)
        default:
            return (nil, nil)
        }
    }

    static func parseResult(_ json: [String: Any], wantsStructured: Bool) throws -> Reply {
        let status = (json["status"] as? String ?? "").uppercased()
        let errorMessage = (json["error"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if status != "SUCCESS" {
            throw failure(message: errorMessage.isEmpty ? "status \(status)" : errorMessage)
        }
        let finishedReason = (json["finished_reason"] as? String ?? "").lowercased()
        let response = (json["response"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var text = response
        var isStructured = false
        if wantsStructured, let structured = json["structured_output"],
           JSONSerialization.isValidJSONObject(structured),
           let data = try? JSONSerialization.data(withJSONObject: structured, options: [.sortedKeys]) {
            text = String(decoding: data, as: UTF8.self)
            isStructured = true
        }
        let truncated = finishedReason == "max_tokens" || finishedReason == "length"
        guard truncated || !text.isEmpty else { throw TextEngineError.badResponse("Antigravity returned no text") }
        if wantsStructured, !isStructured, !truncated {
            guard let object = ClaudePlanEngine.jsonText(in: text) else {
                throw TextEngineError.badResponse("Antigravity returned no structured output")
            }
            text = object
        }
        let usage = json["usage"] as? [String: Any]
        return Reply(
            text: text,
            truncated: truncated,
            inputTokens: usage?["input_tokens"] as? Int,
            outputTokens: usage?["output_tokens"] as? Int,
            cachedTokens: usage?["cache_read_tokens"] as? Int)
    }

    static func failure(message: String) -> Error {
        let lowered = message.lowercased()
        if lowered.contains("authentication") || lowered.contains("please sign in")
            || lowered.contains("not signed in") || lowered.contains("unauthenticated")
            || lowered.contains("login") || lowered.contains("401") {
            return AntigravityPlanError.signInRequired
        }
        if lowered.contains("quota") || lowered.contains("usage limit") || lowered.contains("rate limit")
            || lowered.contains("limit reached") || lowered.contains("resource_exhausted")
            || lowered.contains("exhausted") || lowered.contains("429") {
            return AntigravityPlanError.usageLimitReached(String(message.prefix(300)))
        }
        if lowered.contains("503") || lowered.contains("502") || lowered.contains("504")
            || lowered.contains("500") || lowered.contains("529")
            || lowered.contains("overloaded") || lowered.contains("temporarily unavailable") {
            let code = lowered.contains("503") ? 503 : lowered.contains("529") ? 529 : 500
            return TextEngineError.httpStatus(code: code, detail: String(message.prefix(600)), retryAfter: nil)
        }
        let detail = message.isEmpty ? "the request failed" : String(message.prefix(600))
        return TextEngineError.badResponse("Antigravity CLI: \(detail)")
    }

    static func reply(from output: PlanCLIProcess.Output, wantsStructured: Bool) throws -> Reply {
        var result: [String: Any]?
        for line in String(decoding: output.stdout, as: UTF8.self).split(separator: "\n") {
            if let parsed = parseStreamLine(String(line)).result { result = parsed }
        }
        guard let result else {
            let stderr = AntigravityCLI.stripANSI(output.stderrTail).trimmingCharacters(in: .whitespacesAndNewlines)
            lokalbotLog("antigravity plan run failed status=\(output.status) stderrBytes=\(stderr.utf8.count)")
            let lowered = stderr.lowercased()
            if lowered.contains("authentication") || lowered.contains("please sign in")
                || lowered.contains("not signed in") || lowered.contains("log in") {
                throw AntigravityPlanError.signInRequired
            }
            if lowered.contains("quota") || lowered.contains("rate limit") || lowered.contains("usage limit") {
                throw AntigravityPlanError.usageLimitReached(String(stderr.prefix(300)))
            }
            throw AntigravityPlanError.failed(
                "Antigravity CLI exited without a result (status \(output.status)). Update agy and try again.")
        }
        return try parseResult(result, wantsStructured: wantsStructured)
    }

    private func request(
        system: String,
        prompt: String,
        context: [String],
        schema: [String: Any]?,
        options: TextGenerationOptions?,
        onPartial: (@MainActor (String) -> Void)?
    ) async throws -> String {
        let arguments = arguments(structured: schema != nil, options: options)
        let input = try Self.streamInput(prompt: prompt, context: context)
        var files: [String: Data] = [
            Self.agentFilePath: Self.agentMarkdown(systemPrompt: system),
            Self.hooksFilePath: Self.hooksJSON,
            Self.settingsFilePath: Self.sessionSettingsJSON,
        ]
        if let schema {
            files[Self.schemaFilePath] = try JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])
        }
        let budget = MeetingGenerationBudget.current
        let reservation = try await budget?.reserve(input: MeetingGenerationBudget.promptTokens,
                                                    output: options?.maxTokens ?? 4_096)
        let started = ProcessInfo.processInfo.systemUptime
        var metric = GenerationCallTelemetry(stage: MeetingGenerationBudget.stage, outcome: "failed", wallSeconds: 0)
        do {
            let partials = onPartial.map(PartialForwarder.init)
            let output: PlanCLIProcess.Output
            do {
                output = try await runner.run(
                    arguments: arguments,
                    input: input,
                    files: files,
                    onLine: partials.map { forwarder in { @Sendable line in forwarder.consume(line) } })
                partials?.finish()
            } catch {
                partials?.finish()
                throw error
            }
            let reply = try Self.reply(from: output, wantsStructured: schema != nil)
            metric.inputTokens = reply.inputTokens
            metric.outputTokens = reply.outputTokens
            metric.cachedTokens = reply.cachedTokens
            metric.outcome = reply.truncated ? "truncated" : "complete"
            if reply.truncated {
                if budget != nil { throw TruncatedStructuredResponse(content: strippingReasoning(reply.text)) }
                throw TextEngineError.outputTruncated
            }
            metric.wallSeconds = ProcessInfo.processInfo.systemUptime - started
            metric.log()
            if let reservation { await budget?.finish(reservation, metric: metric) }
            return strippingReasoning(reply.text)
        } catch {
            if error is CancellationError { metric.outcome = "cancelled" }
            metric.wallSeconds = ProcessInfo.processInfo.systemUptime - started
            metric.log()
            if let reservation { await budget?.finish(reservation, metric: metric) }
            throw error
        }
    }

    private final class PartialForwarder: @unchecked Sendable {
        private let onPartial: @MainActor (String) -> Void
        private let lock = NSLock()
        private var text = ""
        private var lastEmission = -Double.infinity
        private var finished = false

        init(_ onPartial: @escaping @MainActor (String) -> Void) {
            self.onPartial = onPartial
        }

        func consume(_ line: String) {
            guard let delta = AntigravityPlanEngine.parseStreamLine(line).delta else { return }
            let snapshot: String? = lock.withLock {
                text += delta
                let now = ProcessInfo.processInfo.systemUptime
                guard now - lastEmission >= 0.033 else { return nil }
                lastEmission = now
                return text
            }
            guard let snapshot else { return }
            let onPartial = onPartial
            Task { @MainActor in
                if !self.isFinished { onPartial(snapshot) }
            }
        }

        var isFinished: Bool { lock.withLock { finished } }

        func finish() {
            lock.withLock { finished = true }
        }
    }
}
