import Foundation

enum ThinkChat {
    static func structuredReply(from engine: TextEngine, messages: [[String: Any]], schema: [String: Any],
                                options: TextGenerationOptions) async throws -> MuseChatClient.Reply {
        let request = request(messages: messages, tools: [])
        let output = try await engine.generate(system: request.system, prompt: request.prompt,
                                               context: request.context, schema: schema, options: options)
        let text = strippingReasoning(output)
        return MuseChatClient.Reply(content: ChatPrompt.extractJSONObject(text) ?? text, toolCalls: [],
                                    usage: .init(), finishReason: "stop")
    }

    static func toolCall(from engine: TextEngine, messages: [[String: Any]], tools: [[String: Any]],
                         options: TextGenerationOptions) async throws -> MuseChatClient.Reply {
        let request = request(messages: messages, tools: tools)
        let names = Set(functions(tools).map(\.name))
        let schema = toolCallSchema(tools)
        let id = "call_\(messages.filter { $0["role"] as? String == "assistant" }.count)"
        var output = ""
        for prompt in [request.prompt, request.prompt + "\n\n" + retry] {
            output = try await engine.generate(system: request.system, prompt: prompt, context: request.context,
                                               schema: schema, options: options)
            try Task.checkCancellation()
            if let call = toolCall(in: output, names: names, id: id) {
                return MuseChatClient.Reply(content: "", toolCalls: [call], usage: .init(), finishReason: "tool_calls")
            }
        }
        return MuseChatClient.Reply(content: strippingReasoning(output), toolCalls: [], usage: .init(), finishReason: "stop")
    }

    static let callFormat = #"{"call": {"tool": "<name>", "arguments": { … }}}"#
    static let nextCall = "Reply with the next tool call as one JSON object."
    static let retry = "Your previous reply was not a valid tool call. Reply with exactly one JSON object of the form "
        + callFormat + " and nothing else."

    static func request(messages: [[String: Any]], tools: [[String: Any]])
        -> (system: String, prompt: String, context: [String]) {
        var system = ""
        var users: [String] = []
        var transcript: [String] = []
        for message in messages {
            switch message["role"] as? String {
            case "system":
                system = text(of: message["content"])
            case "user":
                users.append(text(of: message["content"]))
            case "assistant":
                for call in message["tool_calls"] as? [[String: Any]] ?? [] {
                    guard let function = call["function"] as? [String: Any],
                          let name = function["name"] as? String else { continue }
                    let arguments = (function["arguments"] as? String).flatMap(object(from:)) ?? [:]
                    transcript.append("Assistant: " + json(["call": ["tool": name, "arguments": arguments]]))
                }
            case "tool":
                transcript.append("Observation: " + text(of: message["content"]))
            default:
                break
            }
        }
        guard !tools.isEmpty else {
            return (system, users.joined(separator: "\n\n"), [])
        }
        let later = users.dropFirst().joined(separator: "\n\n")
        return (system + "\n\n" + toolInstructions(tools),
                later.isEmpty ? nextCall : later,
                Array(users.prefix(1)) + transcript)
    }

    private static func text(of content: Any?) -> String {
        if let text = content as? String { return text }
        return (content as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    private static func functions(_ tools: [[String: Any]])
        -> [(name: String, description: String, parameters: [String: Any])] {
        tools.compactMap { tool in
            guard let function = tool["function"] as? [String: Any], let name = function["name"] as? String else { return nil }
            return (name, function["description"] as? String ?? "", function["parameters"] as? [String: Any] ?? [:])
        }
    }

    static func toolInstructions(_ tools: [[String: Any]]) -> String {
        var lines = ["TOOLS", "Reply with exactly one JSON object and nothing else: \(callFormat). One call per reply. "
            + "Earlier calls are listed as \"Assistant:\" lines, each followed by an \"Observation:\" with what it returned."]
        for tool in functions(tools) {
            lines.append("")
            lines.append("\(tool.name): \(tool.description)")
            let properties = tool.parameters["properties"] as? [String: Any] ?? [:]
            let required = Set(tool.parameters["required"] as? [String] ?? [])
            for name in properties.keys.sorted() {
                let property = properties[name] as? [String: Any] ?? [:]
                var note = property["type"] as? String ?? "value"
                if let values = property["enum"] as? [String] { note += ", one of: " + values.joined(separator: ", ") }
                if !required.contains(name) { note += ", optional" }
                let description = (property["description"] as? String).map { ": \($0)" } ?? ""
                lines.append("  - \(name) (\(note))\(description)")
            }
        }
        return lines.joined(separator: "\n")
    }

    static func toolCallSchema(_ tools: [[String: Any]]) -> [String: Any] {
        let variants: [[String: Any]] = functions(tools).map { tool in
            let parameters = tool.parameters.isEmpty ? ["type": "object", "properties": [String: Any]()] : tool.parameters
            return [
                "type": "object",
                "properties": [
                    "tool": ["type": "string", "enum": [tool.name]],
                    "arguments": strict(parameters),
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

    static func strict(_ schema: [String: Any]) -> [String: Any] {
        var schema = schema
        if let items = schema["items"] as? [String: Any] { schema["items"] = strict(items) }
        guard let properties = schema["properties"] as? [String: Any] else { return schema }
        let required = Set(schema["required"] as? [String] ?? [])
        var closed: [String: Any] = [:]
        for (name, value) in properties {
            var property = strict(value as? [String: Any] ?? [:])
            if !required.contains(name) {
                if let type = property["type"] as? String { property["type"] = [type, "null"] }
                if let values = property["enum"] as? [Any] { property["enum"] = values + [NSNull()] }
            }
            closed[name] = property
        }
        schema["properties"] = closed
        schema["required"] = properties.keys.sorted()
        schema["additionalProperties"] = false
        return schema
    }

    static func toolCall(in output: String, names: Set<String>, id: String) -> MuseChatClient.ToolCall? {
        guard let text = ChatPrompt.extractJSONObject(strippingReasoning(output)), let reply = object(from: text) else { return nil }
        let call = reply["call"] as? [String: Any] ?? reply
        guard let name = (call["tool"] ?? call["name"]) as? String, names.contains(name) else { return nil }
        let given = call["arguments"] ?? call["parameters"]
        let arguments = (given as? [String: Any]) ?? (given as? String).flatMap(object(from:)) ?? [:]
        return MuseChatClient.ToolCall(id: id, name: name, arguments: json(arguments.filter { !($0.value is NSNull) }))
    }

    private static func object(from text: String) -> [String: Any]? {
        text.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    private static func json(_ object: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}
