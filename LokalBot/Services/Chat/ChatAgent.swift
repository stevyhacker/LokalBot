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

    static func systemPrompt(tools: [ChatToolSpec], libraryOverview: String,
                             workMemory: String = "") -> String {
        var lines: [String] = []
        lines.append("""
        You are LokalBot's assistant. You answer questions about the user's \
        on-device meeting recordings, transcripts and summaries, and about their \
        workday context — text seen on screen and time spent in apps. Everything is \
        local and private. Be concise and specific, and cite meetings by their title \
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
        • Call one tool at a time. When you have enough information, reply with your \
        final answer in plain language — no JSON, no tool call.
        • Prefer search_meetings for questions about what was said or decided. Use \
        get_meeting to read a specific meeting's summary or transcript. Use \
        list_meetings to enumerate meetings. Use get_action_items for to-dos, \
        decisions, or follow-ups. Use search_screen for things the user \
        read or saw on screen (docs, sites, code, messages). Use activity_summary \
        for how a day was spent across apps.
        """)
        lines.append("")
        lines.append("""
        Citing sources:
        • When part of your final answer comes from a specific meeting, append a \
        citation marker right after that sentence: [meeting:ID], or [meeting:ID@HH:MM:SS] \
        to point at a moment in the transcript. Use the exact meeting id a tool returned \
        — never invent one. The app renders markers as links; don't explain them.
        • When part of your final answer comes from search_screen, append the exact \
        [screen:ID] marker that search_screen returned. The app renders it as a private, \
        local thumbnail linking to that captured moment. Never invent a screen id.
        """)
        if !libraryOverview.isEmpty {
            lines.append("")
            lines.append("Current meeting library (for reference):")
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
        return lines.joined(separator: "\n")
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
    let engine: TextEngine
    let runner: ChatToolRunner
    /// Hard cap on tool calls before we force a final synthesis pass.
    var maxSteps = 4
    /// How many prior turns of the conversation to replay as context.
    var historyWindow = 8
    /// Ambient work-memory context (see `ChatPrompt.workMemoryContext`);
    /// empty when dreaming is off or has nothing yet.
    var workMemory = ""

    struct Turn: Equatable {
        let role: ChatRole
        let text: String
    }

    /// Produce the assistant's answer to `latest`, given prior `history`.
    /// `onEvent` fires on the main actor as tools start and finish.
    func respond(history: [Turn], latest: String,
                 onEvent: @escaping @MainActor (ChatAgentEvent) -> Void) async throws -> String {
        let toolNames = Set(runner.specs.map(\.name))
        let system = ChatPrompt.systemPrompt(tools: runner.specs,
                                             libraryOverview: runner.libraryOverview(),
                                             workMemory: workMemory)
        var transcript: [String] = history.suffix(historyWindow).map {
            "\($0.role == .user ? "User" : "Assistant"): \($0.text)"
        }
        transcript.append("User: \(latest)")

        for step in 0..<maxSteps {
            let directive = step == 0
                ? "Decide how to respond to the user's last message. If you need meeting data, reply with a single tool-call JSON object; otherwise reply with your final answer."
                : "Continue. Call another tool (one JSON object) if you still need data, or give your final answer in plain language."
            let output = try await engine.generateStreaming(
                system: system,
                prompt: directive + " Begin a final prose answer with FINAL_ANSWER: on its own line. Never use this prefix for a tool call.",
                context: transcript,
                options: TextGenerationOptions(maxTokens: 2_048)) { partial in
                    if let answer = ChatPrompt.streamingAnswer(partial) { onEvent(.answerPartial(answer)) }
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

            switch action {
            case .answer(let text):
                return text
            case .call(let call):
                onEvent(.answerPartial(""))
                onEvent(.toolStarted(call))
                let result = await runner.run(call)
                try Task.checkCancellation()
                onEvent(.toolFinished(name: call.name, summary: result.summary))
                transcript.append("Assistant: \(call.json)")
                transcript.append("Observation: \(result.text)")
            }
        }

        // Out of tool budget — force a final answer from what we gathered.
        let forced = try await engine.generateStreaming(
            system: system,
            prompt: "Give your final answer now in plain language using the observations above. Begin with FINAL_ANSWER: on its own line. Do not call any more tools.",
            context: transcript,
            options: TextGenerationOptions(maxTokens: 2_048)) { partial in
                if let answer = ChatPrompt.streamingAnswer(partial) { onEvent(.answerPartial(answer)) }
            }
        return ChatPrompt.finalText(forced)
    }
}
