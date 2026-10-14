import Foundation

// In-app meeting assistant (the "Chat" section). A small agent loop on top of
// the same `TextEngine` the summariser uses: the model answers questions about
// the user's on-device meetings and may call tools (search / list / read) to
// ground its answers. Inspired by the `lokalbot-cli` tool surface — same
// `list` / `get` / `search` capabilities, exposed to the LLM as callable tools.
//
// The local backends only speak single-shot `generate(system:prompt:context:)`
// (no native function-calling), so tool use is a prompt-driven ReAct loop with
// a deliberately simple JSON protocol and tolerant parsing — smaller local
// GGUFs may emit sloppy output, so the protocol degrades to a plain answer
// rather than fail.

// MARK: - Value types

enum ChatRole: String, Equatable, Sendable, Codable {
    case user, assistant
}

/// One callable tool advertised to the model. Pure value type so the system
/// prompt can be built and unit-tested without an engine or the file system.
struct ChatToolSpec: Equatable, Sendable {
    struct Argument: Equatable, Sendable {
        let name: String
        let description: String
        let required: Bool
    }
    let name: String
    /// One-line description of what the tool does (shown to the model).
    let summary: String
    let arguments: [Argument]
}

/// A parsed tool invocation. Arguments are coerced to strings on parse (numbers
/// and bools stringified) so every tool reads them the same way regardless of
/// how the model quoted them.
struct ChatToolCall: Equatable, Sendable {
    let name: String
    let arguments: [String: String]

    /// Trimmed, non-empty argument value, or nil.
    func string(_ key: String) -> String? {
        guard let value = arguments[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    func int(_ key: String) -> Int? { string(key).flatMap(Int.init) }

    /// Canonical JSON re-serialisation, so the running transcript records exactly
    /// one well-formed tool call back to the model regardless of how it was typed.
    var json: String {
        let pairs = arguments.keys.sorted().map { key in
            "\(Self.encode(key)): \(Self.encode(arguments[key] ?? ""))"
        }
        return "{\"tool\": \(Self.encode(name)), \"arguments\": {\(pairs.joined(separator: ", "))}}"
    }

    private static func encode(_ string: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: string,
                                                     options: [.fragmentsAllowed]),
              let text = String(data: data, encoding: .utf8) else { return "\"\(string)\"" }
        return text
    }
}

/// What the model produced this step: a tool call, or its final answer.
enum ChatAction: Equatable {
    case call(ChatToolCall)
    case answer(String)
}

/// Result of running a tool: the full `text` fed back to the model, plus a short
/// `summary` surfaced in the UI activity row.
struct ChatToolResult: Sendable {
    let text: String
    let summary: String
    var evidence = ChatEvidence()
}

/// UI-facing progress events emitted while the agent runs.
enum ChatAgentEvent: Sendable {
    case toolStarted(ChatToolCall)
    case toolFinished(name: String, summary: String)
    case answerPartial(String)
}

/// Executes tools and supplies their catalogue + ambient library context.
@MainActor
protocol ChatToolRunner: AnyObject {
    var specs: [ChatToolSpec] { get }
    /// Compact, always-available context (e.g. recent meeting titles) folded into
    /// the system prompt so simple questions can be answered without a tool call.
    func libraryOverview() -> String
    func run(_ call: ChatToolCall) async -> ChatToolResult
    func attachedScreenEvidence(ids: Set<Int64>, dayScopeKey: String?) -> ChatEvidence
}

extension ChatToolRunner {
    func attachedScreenEvidence(ids: Set<Int64>, dayScopeKey: String?) -> ChatEvidence { ChatEvidence() }
}

// MARK: - Prompt + parsing (pure, unit-tested)

/// Builds the system prompt and parses the model's output into a `ChatAction`.
/// Everything here is pure and `nonisolated static` so the protocol can be
/// tested without an engine.
enum ChatPrompt {

    /// The dream-maintained work memory as ambient chat context. Empty unless
    /// dreaming is enabled and the memory actually holds something, so the
    /// prompt never grows a vacant section.
    static func workMemoryContext(memory: DreamMemory?, dreamingEnabled: Bool) -> String {
        guard dreamingEnabled, let memory, !memory.isEmpty else { return "" }
        return PromptContextSanitizer.sanitize(memory.markdown(), maxCharacters: 6_000)
    }

    /// Lets the model resolve "yesterday" or "last Tuesday". It goes last in
    /// the system prompt, so the tool list and library overview before it
    /// stay a reusable cached prefix.
    static func currentTimeLine(now: Date = Date(), timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEEE, d MMMM yyyy, HH:mm"
        return "Current local time: \(formatter.string(from: now)) (\(timeZone.identifier)). "
            + "Resolve relative dates such as \"yesterday\" or \"last Tuesday\" from it."
    }

    static func systemPrompt(tools: [ChatToolSpec], libraryOverview: String,
                             workMemory: String = "",
                             inferencePrivacy: String = "Inference uses the selected backend, which may be local or remote. Do not claim that all processing stays on this Mac.",
                             currentTime: String = "", factualSelection: Bool = false) -> String {
        var lines: [String] = []
        lines.append("""
        You are LokalBot's assistant. You answer questions about the user's \
        on-device meeting recordings, transcripts and summaries, and about their \
        workday context — text seen on screen and time spent in apps. The source library \
        is stored on this Mac. \(inferencePrivacy) Be concise and specific, and cite meetings by their title \
        and date. Never invent content — if the tools return nothing relevant, say \
        so plainly.
        """)
        lines.append("")
        lines.append("You can call tools to look things up. Available tools:")
        for tool in tools {
            let signature = tool.arguments
                .map { "\($0.name)\($0.required ? "" : "?")" }
                .joined(separator: ", ")
            lines.append("- \(tool.name)(\(signature)): \(tool.summary)")
            for argument in tool.arguments {
                let requirement = argument.required ? "required" : "optional"
                lines.append("    • \(argument.name) (\(requirement)): \(argument.description)")
            }
        }
        lines.append("")
        lines.append("""
        How to use tools:
        • To call a tool, reply with EXACTLY one JSON object and nothing else, e.g.
          {"tool": "search_meetings", "arguments": {"query": "pricing decision"}}
        • You then receive a line starting with "Observation:" with the result.
        • Call one tool at a time. \(factualSelection
            ? "When you have enough information, select app-owned source handles with {\"answer_sources\":[\"E1\"]}; do not write final prose."
            : "When you have enough information, reply with your final answer in plain language — no JSON, no tool call.")
        • Prefer search_meetings for questions about what was said or decided. Use \
        get_meeting to read a specific meeting's summary or transcript. Use \
        list_meetings to enumerate meetings. Use get_action_items for to-dos, \
        decisions, or follow-ups. Use search_screen for things the user \
        read or saw on screen (docs, sites, code, messages). Use activity_summary \
        for how a day was spent across apps.
        """)
        lines.append("")
        if factualSelection {
            lines.append(ChatGrounding.directive)
        } else { lines.append("""
        Citing sources:
        • When part of your final answer comes from a specific meeting, append a \
        citation marker right after that sentence: [meeting:ID], or [meeting:ID@HH:MM:SS] \
        to point at a moment in the transcript. Use the exact meeting id a tool returned \
        — never invent one. Use only a timestamp explicitly returned in an observation. \
        The app renders markers as links; don't explain them.
        • When part of your final answer comes from search_screen, append the exact \
        [screen:ID] marker that search_screen returned. The app renders it as a private, \
        local thumbnail linking to that captured moment. Never invent a screen id.
        """) }
        if !libraryOverview.isEmpty {
            lines.append("")
            lines.append("Current meeting library (navigation metadata only; call a tool before citing or describing meeting contents):")
            lines.append(libraryOverview)
        }
        if !workMemory.isEmpty {
            lines.append("")
            lines.append("""
            The user's work memory — projects and goals distilled overnight from \
            their recent workdays. Background context only: it may lag reality, \
            so verify with tools before citing it as fact.
            """)
            lines.append(workMemory)
        }
        if !currentTime.isEmpty {
            lines.append("")
            lines.append(currentTime)
        }
        return lines.joined(separator: "\n")
    }

    static func inferencePrivacy(for engine: TextEngine) -> String {
        if let leased = engine as? LeasedTextEngine { return inferencePrivacy(for: leased.base) }
        if let gated = engine as? GatedTextEngine { return inferencePrivacy(for: gated.base) }
        if engine is AppleIntelligenceEngine { return "This response uses an on-device model." }
        let url = (engine as? OpenAICompatibleEngine)?.baseURL ?? (engine as? OllamaEngine)?.baseURL
            ?? (engine as? AnthropicEngine)?.baseURL
        guard let url else { return "The inference location is unspecified; do not claim that all processing stays on this Mac." }
        if InferenceEndpointPolicy.isLoopback(url) {
            return "This response uses a server on this Mac. Its operator controls any onward processing."
        }
        return "This response uses the user-approved remote inference server at \(url.host ?? "the configured host"). Questions and supplied context are sent there; do not claim that all processing stays on this Mac."
    }

    /// Interpret one model turn. Treated as a tool call only when the output
    /// contains a JSON object whose tool name is one of `tools`; otherwise it is
    /// the final answer. The known-tool gate stops prose answers that merely
    /// quote JSON from being mistaken for tool calls.
    static func parse(_ output: String, tools: Set<String>) -> ChatAction {
        let cleaned = strippingReasoning(output).trimmingCharacters(in: .whitespacesAndNewlines)
        // 1. JSON object form: {"tool": "...", "arguments": { … }}.
        if let object = jsonObject(in: cleaned) {
            let callObject = toolCallObject(in: object)
            if let name = toolName(in: callObject), tools.contains(name) {
                return .call(ChatToolCall(
                    name: name,
                    arguments: argumentDictionary(
                        in: callObject, toolNameKeys: nameKeys)))
            }
        }
        // 2. Native function-call form some local models emit instead of JSON,
        //    e.g. <|tool_call_start|>[get_meeting(id='abc', include='summary')]<|tool_call_end|>
        if let call = pythonicCall(in: cleaned, tools: tools) {
            return .call(call)
        }
        return .answer(removingAnswerMarker(stripToolTokens(cleaned)))
    }

    /// Forced final pass: take whatever the model wrote as the answer. If it is
    /// still only a tool call, we can no longer satisfy it, so fall back.
    static func finalText(_ output: String) -> String {
        let cleaned = stripToolTokens(strippingReasoning(output))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty || looksLikeBareToolCall(cleaned) { return fallbackAnswer }
        return removingAnswerMarker(cleaned)
    }

    static let answerMarker = "FINAL_ANSWER:"

    static func removingAnswerMarker(_ text: String) -> String {
        guard text.hasPrefix(answerMarker) else { return text }
        return String(text.dropFirst(answerMarker.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Only an explicit final-answer prefix commits the stream to prose. An
    /// incomplete reasoning block, tool JSON, or wrapper stays completely hidden.
    static func streamingAnswer(_ text: String) -> String? {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasPrefix("<think>") {
            guard let end = cleaned.range(of: "</think>") else { return nil }
            cleaned = String(cleaned[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard cleaned.hasPrefix(answerMarker) else { return nil }
        var answer = removingAnswerMarker(cleaned)
        // Hold an incomplete tag/tool payload rather than painting it and then
        // retracting it. The final parser still validates the complete response.
        if let boundary = answer.firstIndex(where: { $0 == "<" || $0 == "{" || $0 == "`" }) {
            answer = String(answer[..<boundary])
        }
        guard answer.contains(where: \.isWhitespace),
              answer.range(of: #"^\[?\s*[A-Za-z_][A-Za-z0-9_]*\s*\("#, options: .regularExpression) == nil,
              !looksLikeBareToolCall(answer), !looksLikeToolAttempt(answer) else { return nil }
        return answer
    }

    static let fallbackAnswer =
        "I couldn't find enough information in your meetings to answer that."

    /// True when a turn that did NOT parse into a tool call still looks like
    /// the model was attempting one — wrapper tokens, a `{"tool": …` fragment
    /// that never balanced, or a bare call form with a misspelled name. The
    /// agent answers this with one schema-constrained retry instead of
    /// surfacing the garbled attempt as the answer.
    static func looksLikeToolAttempt(_ output: String) -> Bool {
        let cleaned = strippingReasoning(output).trimmingCharacters(in: .whitespacesAndNewlines)
        let stripped = stripToolTokens(cleaned)
        // Wrapper tokens around nothing usable. (Tokens around plain prose stay
        // an answer — some models wrap their answer in stray tokens.)
        if stripped.isEmpty, !cleaned.isEmpty { return true }
        // Balanced JSON carrying a tool-name key (parse() already rejected it,
        // so the name must be unknown — e.g. "search_meeting" for "search_meetings").
        if let object = jsonObject(in: stripped),
           toolName(in: toolCallObject(in: object)) != nil { return true }
        // Truncated JSON: an opening brace plus a tool-name key that never closed.
        if stripped.contains("{"),
           stripped.range(of: #""(tool|tool_name|action)"\s*:"#, options: .regularExpression) != nil {
            return true
        }
        return looksLikeBareToolCall(stripped)
    }

    /// JSON schema forcing exactly one valid tool call, used for the
    /// constrained retry. The root stays an object for OpenAI strict Structured
    /// Outputs; the nested `call` is an anyOf over closed per-tool shapes.
    static func toolCallSchema(_ tools: [ChatToolSpec]) -> [String: Any] {
        let variants: [[String: Any]] = tools.map { tool in
            var properties: [String: Any] = [:]
            for argument in tool.arguments {
                var schema: [String: Any] = ["description": argument.description]
                schema["type"] = argument.required ? "string" : ["string", "null"]
                properties[argument.name] = schema
            }
            let argumentsSchema: [String: Any] = [
                "type": "object",
                "properties": properties,
                // Strict Structured Outputs requires optional fields to be
                // required-but-nullable rather than omitted.
                "required": tool.arguments.map(\.name),
                "additionalProperties": false,
            ]
            return [
                "type": "object",
                "properties": [
                    "tool": ["type": "string", "enum": [tool.name]],
                    "arguments": argumentsSchema,
                ],
                "required": ["tool", "arguments"],
                "additionalProperties": false,
            ]
        }
        return [
            "type": "object",
            "properties": ["call": ["anyOf": variants]],
            "required": ["call"],
            "additionalProperties": false,
        ]
    }

    // MARK: Parsing helpers (pure)

    private static let nameKeys = ["tool", "name", "action", "tool_name"]
    private static let argumentKeys = ["arguments", "args", "parameters", "params", "input"]

    private static func jsonObject(in text: String) -> [String: Any]? {
        guard let json = extractJSONObject(text),
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private static func toolCallObject(in object: [String: Any]) -> [String: Any] {
        object["call"] as? [String: Any] ?? object
    }

    private static func toolName(in object: [String: Any]) -> String? {
        for key in nameKeys {
            if let name = (object[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !name.isEmpty {
                return name
            }
        }
        return nil
    }

    private static func argumentDictionary(in object: [String: Any],
                                           toolNameKeys: [String]) -> [String: String] {
        if let key = argumentKeys.first(where: { object[$0] != nil }) {
            return coerce(object[key])
        }
        // Flat shape: {"tool": "x", "query": "y"} — arguments alongside the name.
        var flat = object
        for key in toolNameKeys { flat.removeValue(forKey: key) }
        return coerce(flat)
    }

    static func coerce(_ value: Any?) -> [String: String] {
        guard let dictionary = value as? [String: Any] else { return [:] }
        var result: [String: String] = [:]
        for (key, raw) in dictionary {
            switch raw {
            case let string as String:
                result[key] = string
            case let number as NSNumber:
                result[key] = CFGetTypeID(number) == CFBooleanGetTypeID()
                    ? (number.boolValue ? "true" : "false")
                    : number.stringValue
            case is NSNull:
                continue
            default:
                if let data = try? JSONSerialization.data(withJSONObject: raw,
                                                          options: [.fragmentsAllowed]),
                   let string = String(data: data, encoding: .utf8) {
                    result[key] = string
                }
            }
        }
        return result
    }

    /// First balanced `{ … }` object in `text`, skipping over string literals so
    /// braces inside quoted values don't end the scan early. Returns nil when no
    /// balanced object exists.
    static func extractJSONObject(_ text: String) -> String? {
        let characters = Array(text)
        guard let start = characters.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < characters.count {
            let character = characters[index]
            if inString {
                if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { inString = false }
            } else {
                switch character {
                case "\"": inString = true
                case "{": depth += 1
                case "}":
                    depth -= 1
                    if depth == 0 { return String(characters[start...index]) }
                default: break
                }
            }
            index += 1
        }
        return nil
    }

    // MARK: Native function-call form

    /// Wrapper tokens local chat templates emit around tool calls.
    private static let toolTokens = [
        "<|tool_call_start|>", "<|tool_call_end|>", "<|tool_calls_begin|>", "<|tool_calls_end|>",
        "<tool_call>", "</tool_call>", "<|tool_call|>", "[TOOL_CALLS]", "<|python_tag|>",
    ]

    /// Remove tool-call wrapper tokens so they never leak into a displayed answer.
    static func stripToolTokens(_ text: String) -> String {
        var result = text
        for token in toolTokens { result = result.replacingOccurrences(of: token, with: "") }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Parse the function-call form many small models emit instead of JSON, e.g.
    /// `get_meeting(id='abc', include='summary')` (optionally bracketed and
    /// wrapped in tool tokens). Returns the first call whose name is a known
    /// tool. Arguments are read as `key=value` pairs.
    static func pythonicCall(in text: String, tools: Set<String>) -> ChatToolCall? {
        let stripped = stripToolTokens(text)
        let pattern = "([A-Za-z_][A-Za-z0-9_]*)\\s*\\(([^()]*)\\)"
        guard let regex = try? NSRegularExpression(pattern: pattern,
                                                   options: [.dotMatchesLineSeparators]) else {
            return nil
        }
        let ns = stripped as NSString
        for match in regex.matches(in: stripped, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: match.range(at: 1))
            guard tools.contains(name) else { continue }
            return ChatToolCall(name: name, arguments: parseKwargs(ns.substring(with: match.range(at: 2))))
        }
        return nil
    }

    /// `key='value', limit=5` → `["key": "value", "limit": "5"]`. A lone
    /// positional value is stored under `arg0` (tools read named keys).
    static func parseKwargs(_ body: String) -> [String: String] {
        var result: [String: String] = [:]
        var positional = 0
        for part in splitTopLevelCommas(body) {
            let token = part.trimmingCharacters(in: .whitespaces)
            guard !token.isEmpty else { continue }
            if let equals = token.firstIndex(of: "=") {
                let key = token[..<equals].trimmingCharacters(in: .whitespaces)
                let value = unquote(String(token[token.index(after: equals)...]).trimmingCharacters(in: .whitespaces))
                if !key.isEmpty { result[key] = value }
            } else {
                result["arg\(positional)"] = unquote(token)
                positional += 1
            }
        }
        return result
    }

    private static func unquote(_ text: String) -> String {
        guard text.count >= 2, let first = text.first, let last = text.last,
              first == last, first == "\"" || first == "'" else { return text }
        return String(text.dropFirst().dropLast())
    }

    /// Split on top-level commas, ignoring commas inside single/double quotes.
    private static func splitTopLevelCommas(_ text: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var quote: Character?
        for character in text {
            if let active = quote {
                if character == active { quote = nil }
                current.append(character)
            } else if character == "\"" || character == "'" {
                quote = character
                current.append(character)
            } else if character == "," {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    /// True when the whole text is just one bare tool call (JSON or native) with
    /// no prose — used by `finalText` to fall back instead of echoing a call.
    static func looksLikeBareToolCall(_ text: String) -> Bool {
        let cleaned = stripToolTokens(text).trimmingCharacters(in: .whitespacesAndNewlines)
        if let object = jsonObject(in: cleaned),
           toolName(in: toolCallObject(in: object)) != nil,
           let json = extractJSONObject(cleaned), json.count >= cleaned.count - 6 {
            return true
        }
        let pattern = "^\\[?\\s*[A-Za-z_][A-Za-z0-9_]*\\s*\\([^()]*\\)\\s*\\]?$"
        return cleaned.range(of: pattern, options: .regularExpression) != nil
    }
}

// MARK: - Agent loop

/// Runs the question → (tool calls) → answer loop against a resolved engine.
@MainActor
struct ChatAgent {
    /// Answer budget for each streamed turn (tool call or final answer).
    static let answerTokens = 2_048

    let engine: TextEngine
    let runner: ChatToolRunner
    /// A caller replaying a historical library can freeze relative dates.
    /// Interactive production callers retain the current wall clock.
    var now: () -> Date = Date.init
    /// Instrumented callers may wrap an engine while preserving the underlying
    /// engine's already-resolved privacy description.
    var inferencePrivacy: String?
    /// Hard cap on tool calls before we force a final synthesis pass. Six
    /// leaves room to search, then read a long meeting in a few transcript
    /// windows; see `adaptLimits(to:)` for small-window engines.
    var maxSteps = 6
    /// Most recent prior messages (each user or assistant message counts
    /// once) replayed as context, bounded again by `historyCharacters`.
    var historyWindow = 16
    /// Character budget for replayed messages, so a few long answers cannot
    /// crowd the tools' observations out of the context window.
    var historyCharacters = 12_000
    /// Ambient work-memory context (see `ChatPrompt.workMemoryContext`);
    /// empty when dreaming is off or has nothing yet.
    var workMemory = ""
    var initialEvidence = ChatEvidence()
    /// In-process stage observer used by offline synthetic evaluation. It is
    /// nil in normal callers and never changes an authorization decision.
    var groundingObserver: ((ChatGrounding.Stage) -> Void)?

    struct Turn: Equatable {
        let role: ChatRole
        let text: String
    }

    /// Apple's on-device model has a window of about 4K tokens, so it keeps
    /// the earlier, smaller loop and history.
    mutating func adaptLimits(to engine: TextEngine) {
        var base = engine
        while true {
            if let leased = base as? LeasedTextEngine { base = leased.base; continue }
            if let gated = base as? GatedTextEngine { base = gated.base; continue }
            break
        }
        guard base is AppleIntelligenceEngine else { return }
        maxSteps = 4
        historyWindow = 8
        historyCharacters = 4_000
    }

    /// The newest messages that fit both budgets, oldest first. A replay never
    /// starts with an assistant message whose question was cut off.
    static func replayedHistory(_ history: [Turn], maxMessages: Int, maxCharacters: Int) -> [Turn] {
        var kept: [Turn] = []
        var characters = 0
        for turn in history.reversed() {
            guard kept.count < maxMessages, characters + turn.text.count <= maxCharacters else { break }
            kept.append(turn)
            characters += turn.text.count
        }
        if kept.last?.role == .assistant { kept.removeLast() }
        return kept.reversed()
    }

    /// Produce the assistant's answer to `latest`, given prior `history`.
    /// `onEvent` fires on the main actor as tools start and finish.
    func respond(history: [Turn], latest: String,
                 onEvent: @escaping @MainActor (ChatAgentEvent) -> Void) async throws -> String {
        let toolNames = Set(runner.specs.map(\.name))
        let writing = ChatGrounding.isWritingRequest(latest)
        let groundsMeetingAnswers = !writing && (toolNames.contains("search_meetings") || toolNames.contains("get_meeting"))
        if groundsMeetingAnswers, let greeting = ChatGrounding.greeting(latest) { return greeting }
        let system = ChatPrompt.systemPrompt(tools: runner.specs,
                                             libraryOverview: runner.libraryOverview(),
                                             workMemory: workMemory,
                                             inferencePrivacy: inferencePrivacy ?? ChatPrompt.inferencePrivacy(for: engine),
                                             currentTime: ChatPrompt.currentTimeLine(now: now()), factualSelection: groundsMeetingAnswers)
        var evidence = ChatEvidenceOrdering.prioritize(initialEvidence, question: latest)
        var transcript: [String] = Self.replayedHistory(
            history, maxMessages: historyWindow, maxCharacters: historyCharacters).map {
            "\($0.role == .user ? "User" : "Assistant"): \($0.text)"
        }
        transcript.append("User: \(latest)")
        var observedTools = !ChatGrounding.sources(evidence).isEmpty
        var searchedMeetings = false

        for step in 0..<maxSteps {
            let observedEvidence = evidence
            let grounding = groundsMeetingAnswers ? "\n" + ChatGrounding.directive
                + "\nApp-owned source catalog:\n" + ChatGrounding.catalog(evidence) : ""
            let directive = step == 0
                ? "Decide how to respond to the user's last message. If you need data from a tool, reply with a single tool-call JSON object; otherwise reply with your final answer."
                : "Continue. Call another tool (one JSON object) if you still need data, or give your final answer."
            let output: String
            do {
                output = try await engine.generateStreaming(
                system: system,
                prompt: directive + (groundsMeetingAnswers ? " Use answer_sources JSON for the final selection."
                    : " Begin a final prose answer with FINAL_ANSWER: on its own line. Never use this prefix for a tool call.") + grounding,
                context: transcript,
                options: TextGenerationOptions(maxTokens: Self.answerTokens)) { partial in
                    if !groundsMeetingAnswers, let answer = ChatPrompt.streamingAnswer(partial) {
                        onEvent(.answerPartial((writing ? "Draft\n\n" : "")
                            + ChatCitationParser.verified(answer, evidence: observedEvidence, streaming: true)))
                    }
                }
            } catch TextEngineError.outputTruncated where groundsMeetingAnswers {
                // Partial planner prose/JSON never grants source or tool
                // authority. Discard it and use the existing bounded retrieval
                // and grounded selection flow. Other errors still propagate.
                output = ""
            }
            try Task.checkCancellation()

            var action = ChatPrompt.parse(output, tools: toolNames)
            // Garbled tool attempt → one retry with decode-time constraints.
            // Backends without grammar support fall back to a plain generate,
            // so this stays a best-effort second chance, never a hard gate.
            if case .answer = action, ChatPrompt.looksLikeToolAttempt(output) {
                let retried = try await engine.generate(
                    system: system,
                    prompt: "Your previous reply was not a valid tool call. Reply with exactly one JSON object of the form {\"call\": {\"tool\": \"…\", \"arguments\": { … }}} for the tool you meant to call.",
                    context: transcript,
                    schema: ChatPrompt.toolCallSchema(runner.specs),
                    options: TextGenerationOptions(
                        maxTokens: 512,
                        reasoningBudgetTokens: 128,
                        temperature: 0.1))
                try Task.checkCancellation()
                if case .call(let call) = ChatPrompt.parse(retried, tools: toolNames) {
                    action = .call(call)
                }
            }

            // A planner's premature answer must not bypass retrieval. Use the
            // normal scoped runner; no separate index or hidden corpus access.
            if groundsMeetingAnswers, !observedTools, case .answer = action,
               toolNames.contains("search_meetings") {
                action = .call(.init(name: "search_meetings", arguments: ["query": latest]))
            }

            switch action {
            case .answer(let text):
                if groundsMeetingAnswers {
                    return try await groundedAnswer(text, question: latest, evidence: evidence, searchedMeetings: searchedMeetings, onEvent: onEvent)
                }
                return (writing ? "Draft\n\n" : "") + ChatCitationParser.verified(text, evidence: evidence)
            case .call(let call):
                onEvent(.answerPartial(""))
                onEvent(.toolStarted(call))
                let result = await runner.run(call)
                try Task.checkCancellation()
                evidence.merge(result.evidence)
                evidence = ChatEvidenceOrdering.prioritize(evidence, question: latest)
                observedTools = true
                if call.name == "search_meetings", Set(call.arguments.keys) == ["query"],
                   call.string("query")?.trimmingCharacters(in: .whitespacesAndNewlines)
                    == latest.trimmingCharacters(in: .whitespacesAndNewlines) { searchedMeetings = true }
                onEvent(.toolFinished(name: call.name, summary: result.summary))
                transcript.append("Assistant: \(call.json)")
                transcript.append("Observation: \(result.text)")
            }
        }

        // Out of tool budget — force a final answer from what we gathered.
        let finalEvidence = evidence
        let forced: String
        do {
            forced = try await engine.generateStreaming(
            system: system,
            prompt: "Give your final answer now using the observations above. Do not call any more tools."
                + (groundsMeetingAnswers ? "\n" + ChatGrounding.directive + "\nApp-owned source catalog:\n"
                    + ChatGrounding.catalog(evidence) : " Begin with FINAL_ANSWER: on its own line."),
            context: transcript,
            options: TextGenerationOptions(maxTokens: Self.answerTokens)) { partial in
                if !groundsMeetingAnswers, let answer = ChatPrompt.streamingAnswer(partial) {
                    onEvent(.answerPartial((writing ? "Draft\n\n" : "")
                        + ChatCitationParser.verified(answer, evidence: finalEvidence, streaming: true)))
                }
            }
        } catch TextEngineError.outputTruncated where groundsMeetingAnswers {
            forced = ""
        }
        try Task.checkCancellation()
        if groundsMeetingAnswers { return try await groundedAnswer(forced, question: latest, evidence: evidence, searchedMeetings: searchedMeetings, onEvent: onEvent) }
        return (writing ? "Draft\n\n" : "") + ChatCitationParser.verified(ChatPrompt.finalText(forced), evidence: evidence)
    }

    private func groundedAnswer(_ output: String, question: String, evidence: ChatEvidence,
                                searchedMeetings: Bool,
                                onEvent: @escaping @MainActor (ChatAgentEvent) -> Void) async throws -> String {
        var current = evidence
        var answer = ChatGrounding.selection(output, evidence: current)
        if let answer {
            groundingObserver?(answer.sources.isEmpty ? .selectionMissing : .selectionAccepted)
        } else {
            groundingObserver?(.selectionInvalid)
        }
        var usedRecoverySearch = false
        let canSearch = runner.specs.contains { $0.name == "search_meetings" }
        let meetingRecall = evidence.excerpts.contains { $0.citation?.kind == .meeting } || evidence.excerpts.isEmpty
        // A Dream-led get_meeting can show only an obsolete record. Before
        // approving meeting recall, obtain an unrestricted original-question
        // search within the runner's authorized scope. Planner filters or a
        // Dream-derived narrower query cannot waive this coverage step.
        // The extra search shares the same one-search recovery budget.
        if canSearch, meetingRecall, !searchedMeetings {
            current = await recoveryEvidence(question: question, previous: current, onEvent: onEvent)
            try Task.checkCancellation()
            usedRecoverySearch = true
            answer = nil
        }
        if answer == nil || answer?.sources.isEmpty == true {
            answer = try await repairSelection(question: question, evidence: current)
        }
        var assessment = SupportEvaluation.notSupported
        if let answer, !answer.sources.isEmpty {
            assessment = try await supportedSelection(answer, question: question, evidence: current)
        }
        if case .supported(let supported) = assessment {
            groundingObserver?(.answerGrounded)
            return ChatCitationParser.verified(supported.rendered, evidence: current)
        }
        // Coverage already used the one extra search, but only one selection
        // repair. A structurally invalid proposal can use the remaining repair
        // against the same catalog. It still needs fresh exact anchors and an
        // independent supported verdict; a negative final verdict never enters
        // this path and is never discarded or retried unchanged.
        if usedRecoverySearch, case .invalidProposal = assessment {
            let repaired = try await repairSelection(question: question, evidence: current, invalidProposal: true)
            if !repaired.sources.isEmpty,
               case .supported(let supported) = try await supportedSelection(repaired, question: question, evidence: current) {
                groundingObserver?(.answerGrounded)
                return ChatCitationParser.verified(supported.rendered, evidence: current)
            }
            groundingObserver?(.answerAbstained)
            return ChatGrounding.noAnswer
        }
        // Empty selection is not proof of absence. Failed, empty or uncertain
        // candidates get the same bounded search/reselection, never raw prose.
        guard canSearch, meetingRecall, !usedRecoverySearch else {
            groundingObserver?(.answerAbstained)
            return ChatGrounding.noAnswer
        }
        current = await recoveryEvidence(question: question, previous: current, onEvent: onEvent)
        try Task.checkCancellation()
        let repaired = try await repairSelection(question: question, evidence: current)
        guard !repaired.sources.isEmpty,
              case .supported(let supported) = try await supportedSelection(repaired, question: question, evidence: current) else {
            groundingObserver?(.answerAbstained)
            return ChatGrounding.noAnswer
        }
        groundingObserver?(.answerGrounded)
        return ChatCitationParser.verified(supported.rendered, evidence: current)
    }

    private func recoveryEvidence(question: String, previous: ChatEvidence,
                                  onEvent: @escaping @MainActor (ChatAgentEvent) -> Void) async -> ChatEvidence {
        groundingObserver?(.recoverySearch)
        let call = ChatToolCall(name: "search_meetings", arguments: ["query": question])
        onEvent(.toolStarted(call))
        let result = await runner.run(call)
        onEvent(.toolFinished(name: call.name, summary: result.summary))
        var recovered = result.evidence
        recovered.merge(previous)
        return ChatEvidenceOrdering.prioritize(recovered, question: question)
    }

    private func repairSelection(question: String, evidence: ChatEvidence, invalidProposal: Bool = false) async throws -> ChatGrounding.Selection {
        groundingObserver?(.selectionRepair)
        guard !ChatGrounding.sources(evidence).isEmpty else { return .init(sources: []) }
        let repaired = try await engine.generate(
            system: ChatGrounding.directive,
            prompt: "Select the recorded excerpts that answer this question: " + question,
            context: (invalidProposal ? ["The previous candidate failed exact selected-source/quote validation. Select records that explicitly contain the requested facts. Never pair text from one record with another record's handle."] : [])
                + ["App-owned source catalog:\n" + ChatGrounding.catalog(evidence)],
            schema: ChatGrounding.schema,
            options: TextGenerationOptions(maxTokens: max(256, engine.minimumStructuredOutputTokens), reasoningBudgetTokens: 0, temperature: 0))
        try Task.checkCancellation()
        return ChatGrounding.selection(repaired, evidence: evidence) ?? .init(sources: [])
    }

    private enum SupportEvaluation {
        case supported(ChatGrounding.Selection)
        case invalidProposal
        case notSupported
    }

    private func supportedSelection(_ selected: ChatGrounding.Selection, question: String, evidence: ChatEvidence) async throws -> SupportEvaluation {
        // Isolated assessment: no planner draft, history or Dream memory.
        // The bounded catalog permits checking retrieved later corrections.
        // A model verdict reduces semantic errors but is not a formal entailment proof; invalid output fails closed.
        guard ChatGrounding.hasCompleteCatalog(evidence) else {
            groundingObserver?(.catalogIncomplete)
            return .notSupported
        }
        guard let request = ChatGrounding.supportRequest(question: question, selected: selected, evidence: evidence,
            currentTime: ChatPrompt.currentTimeLine(now: now())) else {
            groundingObserver?(.supportBudgetExceeded)
            return .notSupported
        }
        let verdict = try await engine.generate(
            system: ChatGrounding.supportDirective,
            prompt: request.prompt,
            context: request.context,
            schema: ChatGrounding.supportSchema,
            options: TextGenerationOptions(maxTokens: max(1_024, engine.minimumStructuredOutputTokens), reasoningBudgetTokens: 128, temperature: 0))
        try Task.checkCancellation()
        guard let proposal = ChatGrounding.proposedSelection(verdict, selected: selected, evidence: evidence) else {
            let declined = ChatGrounding.proposalDeclinesSupport(verdict)
            groundingObserver?(declined ? .proposalDeclined : .proposalInvalid)
            return declined ? .notSupported : .invalidProposal
        }
        groundingObserver?(.proposalAccepted)
        guard let verification = ChatGrounding.verificationRequest(question: question, proposal: proposal,
                  evidence: evidence, currentTime: ChatPrompt.currentTimeLine(now: now())) else {
            groundingObserver?(.verificationBudgetExceeded)
            return .notSupported
        }
        let checked = try await engine.generate(
            system: ChatGrounding.verificationDirective,
            prompt: verification.prompt,
            context: verification.context,
            schema: ChatGrounding.verificationSchema,
            options: TextGenerationOptions(maxTokens: max(512, engine.minimumStructuredOutputTokens),
                reasoningBudgetTokens: 128, temperature: 0))
        try Task.checkCancellation()
        let supported = ChatGrounding.verifiedProposal(checked)
        groundingObserver?(supported ? .verificationAccepted : .verificationRejected)
        return supported ? .supported(proposal.selection) : .notSupported
    }
}
