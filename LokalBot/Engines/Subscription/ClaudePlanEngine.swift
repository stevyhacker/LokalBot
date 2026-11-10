import Foundation

/// Runs one `claude -p` request. Tests replace the child process.
protocol ClaudeCodeRunning: Sendable {
    /// `files` are written into a fresh private working directory, which
    /// `arguments` may name by relative path; it is removed afterwards.
    func run(arguments: [String], input: Data, files: [String: Data],
             onLine: (@Sendable (String) -> Void)?) async throws -> ClaudeCodeProcess.Output
}

struct LiveClaudeCodeRunner: ClaudeCodeRunning {
    func run(arguments: [String], input: Data, files: [String: Data],
             onLine: (@Sendable (String) -> Void)?) async throws -> ClaudeCodeProcess.Output {
        guard let executable = await ClaudeCodeLocator.shared.executable() else {
            throw ClaudePlanError.notInstalled
        }
        // An empty folder of its own: no project instructions or settings to
        // pick up, and the system prompt never appears in a process list.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LokalBot-claude-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        for (name, data) in files {
            let url = directory.appendingPathComponent(name)
            guard FileManager.default.createFile(atPath: url.path, contents: data,
                                                 attributes: [.posixPermissions: 0o600]) else {
                throw ClaudePlanError.failed("LokalBot couldn't prepare the Claude Code request.")
            }
        }
        return try await ClaudeCodeProcess.run(
            executable: executable, arguments: arguments,
            environment: ClaudeCodeCLI.environment(for: executable),
            workingDirectory: directory, input: input, onLine: onLine)
    }
}

/// Think on the user's Claude plan, through their own signed-in Claude Code.
///
/// Every request runs with tools, MCP servers, slash commands, settings
/// files, and customizations off, and without session persistence: the
/// prompt is never written to `~/.claude/projects`, which LokalBot itself
/// reads as coding-agent evidence. `--bare` is never used, because it
/// ignores the Claude subscription sign-in.
struct ClaudePlanEngine: TextEngine {
    var model: String
    var reasoningLevel: ThinkReasoningLevel = .automatic
    var runner: ClaudeCodeRunning = LiveClaudeCodeRunner()

    static let systemPromptFile = "system-prompt.txt"
    /// Claude Code's own coding-agent prompt would otherwise apply.
    static let fallbackSystemPrompt = "You are a helpful assistant."

    var displayName: String { "Claude plan — \(model.isEmpty ? "Claude Code default" : model)" }
    var checkpointIdentity: String { "\(displayName)|claude-plan|claude-code" }
    var accountsForGenerationRequests: Bool { true }
    var structuredOutputEnumLimit: Int? { 500 }

    /// Aliases and the default follow the newest models, which take effort
    /// low through max and think by default.
    var traits: (support: ReasoningSupport, thinksByDefault: Bool) {
        let name = model.lowercased()
        if name.isEmpty || ["default", "opus", "sonnet", "haiku", "fable", "best", "opusplan"].contains(name)
            || name.hasSuffix("[1m]") && !name.hasPrefix("claude-") {
            return (ReasoningSupport(levels: [.low, .medium, .high, .xhigh, .max]), true)
        }
        let traits = AnthropicModelTraits(model: name.replacingOccurrences(of: "[1m]", with: ""))
        return (traits.reasoningSupport, traits.thinksByDefault)
    }

    /// As for Anthropic's API: a chosen level, capped by the task's budget;
    /// on Automatic a model that thinks by default gets the level its task
    /// budget implies, so notes and digests don't spend minutes thinking.
    func effort(for options: TextGenerationOptions?) -> ThinkReasoningLevel? {
        let (support, thinksByDefault) = traits
        let budget = options?.reasoningBudgetTokens
        if let level = support.requestLevel(reasoningLevel, taskBudget: budget) { return level }
        guard thinksByDefault, let budget else { return nil }
        return support.clamp(.ceiling(forTaskBudget: budget))
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

    // MARK: Arguments

    /// Pure argument construction, covered offline. Nothing a caller supplies
    /// is in it: a command line is readable by every process of the same
    /// user, and a schema can hold meeting text (the notes repair lists the
    /// meeting's action items as allowed values). A structured request
    /// therefore reads its schema from stdin, which takes Claude Code's
    /// stream-json input (`structuredInput`).
    func arguments(structured: Bool, options: TextGenerationOptions?, streaming: Bool) -> [String] {
        var arguments = ["-p"]
        if structured { arguments += ["--input-format", "stream-json"] }
        arguments += ["--output-format", streaming || structured ? "stream-json" : "json"]
        // Claude Code refuses stream-json output without --verbose.
        if streaming || structured { arguments.append("--verbose") }
        if streaming { arguments.append("--include-partial-messages") }
        arguments += [
            "--no-session-persistence",
            "--safe-mode",
            "--tools", "",
            "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#,
            "--disable-slash-commands",
            "--setting-sources", "",
            "--system-prompt-file", Self.systemPromptFile,
        ]
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !model.isEmpty { arguments += ["--model", model] }
        if let effort = effort(for: options) { arguments += ["--effort", effort.rawValue] }
        return arguments
    }

    static func input(prompt: String, context: [String]) -> Data {
        let parts = (context + [prompt]).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return Data(parts.joined(separator: "\n\n").utf8)
    }

    /// Stdin for a structured request, one JSON object per line: the
    /// `initialize` request Claude Code's own SDK sends, carrying the schema
    /// unchanged (`maxItems`, `minimum` included), then the prompt as a user
    /// message. Checked against Claude Code 2.1.318.
    static func structuredInput(prompt: String, context: [String], schema: [String: Any]) throws -> Data {
        let text = String(decoding: input(prompt: prompt, context: context), as: UTF8.self)
        let initialize: [String: Any] = [
            "type": "control_request",
            "request_id": "lokalbot-schema",
            "request": ["subtype": "initialize", "jsonSchema": schema] as [String: Any],
        ]
        let message: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": [["type": "text", "text": text]]] as [String: Any],
        ]
        var data = Data()
        for line in [initialize, message] {
            data.append(try JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]))
            data.append(0x0A)
        }
        return data
    }

    // MARK: Result

    struct Reply: Equatable {
        var text: String
        var truncated: Bool
        var inputTokens: Int?
        var outputTokens: Int?
        var cachedTokens: Int?
    }

    /// The final `result` object of `--output-format json` or `stream-json`.
    static func parseResult(_ json: [String: Any], wantsStructured: Bool) throws -> Reply {
        let message = (json["result"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if json["is_error"] as? Bool == true || (json["subtype"] as? String)?.hasPrefix("error") == true {
            throw failure(message: message, apiStatus: json["api_error_status"] as? Int)
        }
        let stopReason = json["stop_reason"] as? String
        if stopReason == "refusal" {
            throw TextEngineError.badResponse("model refusal: Claude declined this request")
        }
        var text = message
        var isStructured = false
        if wantsStructured, let structured = json["structured_output"],
           JSONSerialization.isValidJSONObject(structured),
           let data = try? JSONSerialization.data(withJSONObject: structured, options: [.sortedKeys]) {
            text = String(decoding: data, as: UTF8.self)
            isStructured = true
        }
        let truncated = stopReason == "max_tokens" || stopReason == "model_context_window_exceeded"
        guard truncated || !text.isEmpty else { throw TextEngineError.badResponse("Claude returned no text") }
        // A Claude Code that does not take the schema from stdin answers in
        // its own words. The caller asked for JSON, so prose is a failed
        // request here, not a reply handed on as if it were structured.
        if wantsStructured, !isStructured, !truncated {
            guard let object = Self.jsonText(in: text) else {
                throw TextEngineError.badResponse("Claude returned no structured output")
            }
            text = object
        }
        let usage = json["usage"] as? [String: Any]
        let uncached = usage?["input_tokens"] as? Int
        let cacheWrite = usage?["cache_creation_input_tokens"] as? Int ?? 0
        let cacheRead = usage?["cache_read_input_tokens"] as? Int
        return Reply(text: text, truncated: truncated,
                     inputTokens: uncached.map { $0 + cacheWrite + (cacheRead ?? 0) },
                     outputTokens: usage?["output_tokens"] as? Int,
                     cachedTokens: cacheRead)
    }

    /// `text` when it is JSON, or the JSON object inside it when the model
    /// wrapped one in a sentence or a code fence; nil when there is none.
    static func jsonText(in text: String) -> String? {
        func parses(_ candidate: String) -> Bool {
            (try? JSONSerialization.jsonObject(with: Data(candidate.utf8))) != nil
        }
        if parses(text) { return text }
        guard let object = ChatPrompt.extractJSONObject(text), parses(object) else { return nil }
        return object
    }

    /// Plan limits and a missing sign-in stop without retrying; overloads
    /// and server errors keep a status the request gate retries.
    static func failure(message: String, apiStatus: Int?) -> Error {
        let lowered = message.lowercased()
        if lowered.contains("not logged in") || lowered.contains("/login") || lowered.contains("invalid api key")
            || lowered.contains("oauth token") || apiStatus == 401 {
            return ClaudePlanError.signInRequired
        }
        if apiStatus == 429 || lowered.contains("usage limit") || lowered.contains("limit reached") {
            return ClaudePlanError.usageLimitReached(String(message.prefix(300)))
        }
        if let apiStatus, apiStatus >= 500 || apiStatus == 408 {
            return TextEngineError.httpStatus(code: apiStatus, detail: String(message.prefix(600)), retryAfter: nil)
        }
        let detail = message.isEmpty ? "the request failed" : String(message.prefix(600))
        return TextEngineError.badResponse("Claude Code: \(detail)")
    }

    /// One `stream-json` line: a text delta, the final result, or neither.
    static func parseStreamLine(_ line: String) -> (delta: String?, result: [String: Any]?) {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return (nil, nil) }
        switch json["type"] as? String {
        case "stream_event":
            guard let event = json["event"] as? [String: Any],
                  event["type"] as? String == "content_block_delta",
                  let delta = event["delta"] as? [String: Any],
                  delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String else { return (nil, nil) }
            return (text, nil)
        case "result":
            return (nil, json)
        default:
            return (nil, nil)
        }
    }

    // MARK: Run

    private func request(system: String, prompt: String, context: [String],
                         schema: [String: Any]?, options: TextGenerationOptions?,
                         onPartial: (@MainActor (String) -> Void)?) async throws -> String {
        let streaming = onPartial != nil
        let arguments = arguments(structured: schema != nil, options: options, streaming: streaming)
        let input = try schema.map { try Self.structuredInput(prompt: prompt, context: context, schema: $0) }
            ?? Self.input(prompt: prompt, context: context)
        let systemPrompt = system.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? Self.fallbackSystemPrompt : system
        let budget = MeetingGenerationBudget.current
        let reservation = try await budget?.reserve(input: MeetingGenerationBudget.promptTokens,
                                                    output: options?.maxTokens ?? 4_096)
        let started = ProcessInfo.processInfo.systemUptime
        var metric = GenerationCallTelemetry(stage: MeetingGenerationBudget.stage, outcome: "failed", wallSeconds: 0)
        do {
            let partials = onPartial.map(PartialForwarder.init)
            let output: ClaudeCodeProcess.Output
            do {
                output = try await runner.run(
                    arguments: arguments,
                    input: input,
                    files: [Self.systemPromptFile: Data(systemPrompt.utf8)],
                    onLine: partials.map { forwarder in { @Sendable line in forwarder.consume(line) } })
                partials?.finish()
            } catch {
                partials?.finish()
                throw error
            }
            let reply = try Self.reply(from: output, streaming: streaming || schema != nil,
                                       wantsStructured: schema != nil)
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

    /// `streaming` says the output is stream-json: one object per line, the
    /// result last.
    static func reply(from output: ClaudeCodeProcess.Output, streaming: Bool, wantsStructured: Bool) throws -> Reply {
        var result: [String: Any]?
        if streaming {
            for line in String(decoding: output.stdout, as: UTF8.self).split(separator: "\n") {
                if let parsed = parseStreamLine(String(line)).result { result = parsed }
            }
        } else {
            result = try? JSONSerialization.jsonObject(with: output.stdout) as? [String: Any]
        }
        guard let result else {
            let stderr = output.stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
            lokalbotLog("claude plan run failed status=\(output.status) stderrBytes=\(stderr.utf8.count)")
            let lowered = stderr.lowercased()
            if lowered.contains("not logged in") || lowered.contains("/login") {
                throw ClaudePlanError.signInRequired
            }
            throw ClaudePlanError.failed(
                "Claude Code exited without a result (status \(output.status)). Update Claude Code and try again.")
        }
        return try parseResult(result, wantsStructured: wantsStructured)
    }

    /// Forwards streamed text to the UI, at most about 30 times a second.
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
            guard let delta = ClaudePlanEngine.parseStreamLine(line).delta else { return }
            let snapshot: String? = lock.withLock {
                text += delta
                let now = ProcessInfo.processInfo.systemUptime
                guard now - lastEmission >= 0.033 else { return nil }
                lastEmission = now
                return text
            }
            guard let snapshot else { return }
            let onPartial = onPartial
            // A partial still queued when the run ends must not replace the
            // final text the caller shows next.
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
