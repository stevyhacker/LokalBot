import Foundation

protocol GeminiCLIRunning: Sendable {
    func run(arguments: [String], input: Data, files: [String: Data],
             onLine: (@Sendable (String) -> Void)?) async throws -> PlanCLIProcess.Output
}

struct LiveGeminiCLIRunner: GeminiCLIRunning {
    func run(arguments: [String], input: Data, files: [String: Data],
             onLine: (@Sendable (String) -> Void)?) async throws -> PlanCLIProcess.Output {
        guard let executable = await GeminiCLILocator.shared.executable() else {
            throw GeminiPlanError.notInstalled
        }
        return try await PlanCLIProcess.withPrivateDirectory(
            prefix: "LokalBot-gemini",
            files: files,
            failedError: GeminiPlanError.failed
        ) { directory in
            let systemPromptPath = directory.appendingPathComponent(GeminiPlanEngine.systemPromptFile).path
            let systemSettingsPath = directory.appendingPathComponent(GeminiPlanEngine.systemSettingsFile).path
            return try await PlanCLIProcess.run(
                executable: executable,
                arguments: arguments,
                environment: GeminiCLI.environment(
                    for: executable,
                    systemPromptPath: systemPromptPath,
                    systemSettingsPath: systemSettingsPath),
                workingDirectory: directory,
                input: input,
                programName: "Gemini CLI",
                notInstalledError: GeminiPlanError.notInstalled,
                failedError: GeminiPlanError.failed,
                onLine: onLine)
        }
    }
}

struct GeminiPlanEngine: TextEngine {
    var model: String
    var runner: GeminiCLIRunning = LiveGeminiCLIRunner()

    static let systemPromptFile = "system-prompt.md"
    static let systemSettingsFile = "system-settings.json"
    static let adminPolicyFile = "deny-all.toml"
    static let fallbackSystemPrompt = "You are a helpful assistant."

    static let adminPolicyTOML = Data("""
    [[rule]]
    toolName = "*"
    decision = "deny"
    priority = 999
    """.utf8)

    static let systemSettingsJSON = Data("""
    {
      "tools": {
        "core": [],
        "exclude": ["*"]
      },
      "mcp": {
        "allowed": [],
        "excluded": ["*"]
      },
      "hooksConfig": {
        "enabled": false
      },
      "skills": {
        "enabled": false
      },
      "general": {
        "defaultApprovalMode": "plan"
      },
      "privacy": {
        "usageStatisticsEnabled": false
      }
    }
    """.utf8)

    var displayName: String { "Gemini plan — \(model.isEmpty ? "Gemini CLI default" : model)" }
    var checkpointIdentity: String { "\(displayName)|gemini-plan|gemini-cli" }
    var accountsForGenerationRequests: Bool { true }
    var structuredOutputEnumLimit: Int? { 500 }

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

    func arguments(streaming: Bool) -> [String] {
        var arguments = [
            "-p", "",
            "--output-format", streaming ? "stream-json" : "json",
            "--skip-trust",
            "--admin-policy", Self.adminPolicyFile,
            "--extensions", "none",
        ]
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed.lowercased() != "auto" {
            arguments += ["--model", trimmed]
        }
        return arguments
    }

    static func input(prompt: String, context: [String]) -> Data {
        let parts = (context + [prompt]).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return Data(parts.joined(separator: "\n\n").utf8)
    }

    static func systemPromptContent(system: String, schema: [String: Any]?) throws -> Data {
        let base = system.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? fallbackSystemPrompt : system
        guard let schema else { return Data(base.utf8) }
        let schemaData = try JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])
        let schemaText = String(decoding: schemaData, as: UTF8.self)
        let full = """
        \(base)

        Respond with exactly one valid JSON object matching this JSON Schema and nothing else (no markdown fences, no commentary):
        \(schemaText)
        """
        return Data(full.utf8)
    }

    struct Reply: Equatable {
        var text: String
        var inputTokens: Int?
        var outputTokens: Int?
        var cachedTokens: Int?
    }

    enum StreamEvent {
        case delta(String)
        case error(String)
        case result(status: String, errorMessage: String?, inputTokens: Int?, outputTokens: Int?, cachedTokens: Int?)
        case ignored
    }

    static func parseStreamLine(_ line: String) -> StreamEvent {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return .ignored }
        switch type {
        case "message":
            guard json["role"] as? String == "assistant",
                  let content = json["content"] as? String, !content.isEmpty else { return .ignored }
            return .delta(content)
        case "error":
            guard json["severity"] as? String == "error",
                  let message = json["message"] as? String, !message.isEmpty else { return .ignored }
            return .error(message)
        case "result":
            let status = (json["status"] as? String ?? "").lowercased()
            let errorObj = json["error"] as? [String: Any]
            let errorMessage = errorObj?["message"] as? String
            let stats = json["stats"] as? [String: Any]
            return .result(
                status: status,
                errorMessage: errorMessage,
                inputTokens: stats?["input_tokens"] as? Int,
                outputTokens: stats?["output_tokens"] as? Int,
                cachedTokens: stats?["cached"] as? Int)
        default:
            return .ignored
        }
    }

    static func parseJSONObject(_ json: [String: Any], wantsStructured: Bool) throws -> Reply {
        if let errorObj = json["error"] as? [String: Any] {
            let message = (errorObj["message"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let code = errorObj["code"] as? Int
            throw failure(message: message, statusCode: code)
        }
        var text = (json["response"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw TextEngineError.badResponse("Gemini returned no text") }
        if wantsStructured {
            guard let object = ClaudePlanEngine.jsonText(in: text) else {
                throw TextEngineError.badResponse("Gemini returned no structured output")
            }
            text = object
        }
        let tokens = extractJSONTokenStats(json["stats"] as? [String: Any])
        return Reply(text: text, inputTokens: tokens.input, outputTokens: tokens.output, cachedTokens: tokens.cached)
    }

    private static func extractJSONTokenStats(_ stats: [String: Any]?)
        -> (input: Int?, output: Int?, cached: Int?) {
        guard let models = stats?["models"] as? [String: Any], !models.isEmpty else { return (nil, nil, nil) }
        var input = 0
        var output = 0
        var cached = 0
        var found = false
        for value in models.values {
            guard let modelStats = value as? [String: Any],
                  let tokens = modelStats["tokens"] as? [String: Any] else { continue }
            found = true
            input += tokens["prompt"] as? Int ?? tokens["input"] as? Int ?? 0
            output += tokens["candidates"] as? Int ?? 0
            cached += tokens["cached"] as? Int ?? 0
        }
        return found ? (input, output, cached) : (nil, nil, nil)
    }

    static func reply(from output: PlanCLIProcess.Output, streaming: Bool, wantsStructured: Bool) throws -> Reply {
        if streaming {
            var accumulated = ""
            var fatalError: String?
            var resultSeen = false
            var resultStatus = ""
            var resultError: String?
            var inputTokens: Int?
            var outputTokens: Int?
            var cachedTokens: Int?

            for line in String(decoding: output.stdout, as: UTF8.self).split(separator: "\n") {
                switch parseStreamLine(String(line)) {
                case .delta(let chunk):
                    accumulated += chunk
                case .error(let message):
                    fatalError = message
                case .result(let status, let err, let input, let out, let cached):
                    resultSeen = true
                    resultStatus = status
                    resultError = err
                    inputTokens = input
                    outputTokens = out
                    cachedTokens = cached
                case .ignored:
                    break
                }
            }
            if resultSeen {
                if resultStatus != "success" {
                    throw failure(message: resultError ?? fatalError ?? output.stderrTail, statusCode: nil)
                }
                var text = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { throw TextEngineError.badResponse("Gemini returned no text") }
                if wantsStructured {
                    guard let object = ClaudePlanEngine.jsonText(in: text) else {
                        throw TextEngineError.badResponse("Gemini returned no structured output")
                    }
                    text = object
                }
                return Reply(text: text, inputTokens: inputTokens, outputTokens: outputTokens,
                             cachedTokens: cachedTokens)
            }
            if let fatalError {
                throw failure(message: fatalError, statusCode: nil)
            }
            return try handleMissingResult(output)
        }

        let rawStdout = String(decoding: output.stdout, as: UTF8.self)
        if let json = (try? JSONSerialization.jsonObject(with: output.stdout) as? [String: Any])
            ?? ChatPrompt.extractJSONObject(rawStdout).flatMap({
                try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
            }) {
            return try parseJSONObject(json, wantsStructured: wantsStructured)
        }
        return try handleMissingResult(output)
    }

    private static func handleMissingResult(_ output: PlanCLIProcess.Output) throws -> Reply {
        let stderr = AntigravityCLI.stripANSI(output.stderrTail).trimmingCharacters(in: .whitespacesAndNewlines)
        lokalbotLog("gemini plan run failed status=\(output.status) stderrBytes=\(stderr.utf8.count)")
        if !stderr.isEmpty {
            let classified = failure(message: stderr, statusCode: nil)
            if classified is GeminiPlanError { throw classified }
            if let engineError = classified as? TextEngineError, engineError.isRetryable { throw engineError }
        }
        throw GeminiPlanError.failed(
            "Gemini CLI exited without a result (status \(output.status)). Sign in with gemini in Terminal or update Gemini CLI and try again.")
    }

    static func failure(message: String, statusCode: Int?) -> Error {
        let lowered = message.lowercased()
        if lowered.contains("cloudaicompanion.licenses.selfassign")
            || (lowered.contains("permission_denied") && lowered.contains("cloudcode-pa")) {
            return GeminiPlanError.failed(
                "Gemini CLI couldn't onboard this Google Cloud project (permission denied). Run gemini in Terminal to choose a Google account or project with Gemini CLI access.")
        }
        if statusCode == 401
            || lowered.contains("api_key_invalid")
            || lowered.contains("api key not valid")
            || lowered.contains("not authenticated")
            || lowered.contains("unauthenticated")
            || lowered.contains("please login")
            || lowered.contains("please sign in")
            || lowered.contains("invalid_grant")
            || lowered.contains("error authenticating") {
            return GeminiPlanError.signInRequired
        }
        if statusCode == 429
            || lowered.contains("resource_exhausted")
            || lowered.contains("quota")
            || lowered.contains("rate limit")
            || lowered.contains("usage limit")
            || lowered.contains("limit reached") {
            return GeminiPlanError.usageLimitReached(String(message.prefix(300)))
        }
        if let statusCode, statusCode >= 500 || statusCode == 408 {
            return TextEngineError.httpStatus(code: statusCode, detail: String(message.prefix(600)), retryAfter: nil)
        }
        if lowered.contains("503") || lowered.contains("502") || lowered.contains("504")
            || lowered.contains("500") || lowered.contains("overloaded") || lowered.contains("unavailable") {
            let code = lowered.contains("503") ? 503 : 500
            return TextEngineError.httpStatus(code: code, detail: String(message.prefix(600)), retryAfter: nil)
        }
        let detail = message.isEmpty ? "the request failed" : String(message.prefix(600))
        return TextEngineError.badResponse("Gemini CLI: \(detail)")
    }

    private func request(
        system: String,
        prompt: String,
        context: [String],
        schema: [String: Any]?,
        options: TextGenerationOptions?,
        onPartial: (@MainActor (String) -> Void)?
    ) async throws -> String {
        let streaming = onPartial != nil
        let arguments = arguments(streaming: streaming)
        let input = Self.input(prompt: prompt, context: context)
        let files: [String: Data] = [
            Self.systemPromptFile: try Self.systemPromptContent(system: system, schema: schema),
            Self.systemSettingsFile: Self.systemSettingsJSON,
            Self.adminPolicyFile: Self.adminPolicyTOML,
        ]
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
            let reply = try Self.reply(from: output, streaming: streaming, wantsStructured: schema != nil)
            metric.inputTokens = reply.inputTokens
            metric.outputTokens = reply.outputTokens
            metric.cachedTokens = reply.cachedTokens
            metric.outcome = "complete"
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
            guard case .delta(let delta) = GeminiPlanEngine.parseStreamLine(line) else { return }
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
