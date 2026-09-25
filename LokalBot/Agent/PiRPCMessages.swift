import Foundation

/// Commands sent to pi over stdin (JSONL). Encoded with JSONSerialization,
/// which is guaranteed single-line without `.prettyPrinted`.
enum PiCommand: Equatable {
    case prompt(id: String, message: String, streamingBehavior: String?)
    case steer(id: String, message: String)
    case abort(id: String)
    case newSession(id: String)
    case getState(id: String)
    case getMessages(id: String)
    case getSessionStats(id: String)
    case uiConfirmResponse(requestID: String, confirmed: Bool)
    case uiCancelResponse(requestID: String)

    var jsonLine: String {
        var dict: [String: Any]
        switch self {
        case .prompt(let id, let message, let behavior):
            dict = ["type": "prompt", "id": id, "message": message]
            if let behavior { dict["streamingBehavior"] = behavior }
        case .steer(let id, let message):
            dict = ["type": "steer", "id": id, "message": message]
        case .abort(let id):
            dict = ["type": "abort", "id": id]
        case .newSession(let id):
            dict = ["type": "new_session", "id": id]
        case .getState(let id):
            dict = ["type": "get_state", "id": id]
        case .getMessages(let id):
            dict = ["type": "get_messages", "id": id]
        case .getSessionStats(let id):
            dict = ["type": "get_session_stats", "id": id]
        case .uiConfirmResponse(let requestID, let confirmed):
            dict = ["type": "extension_ui_response", "id": requestID, "confirmed": confirmed]
        case .uiCancelResponse(let requestID):
            dict = ["type": "extension_ui_response", "id": requestID, "cancelled": true]
        }
        guard JSONSerialization.isValidJSONObject(dict),
              let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else {
            assertionFailure("PiCommand must encode as a UTF-8 JSON object")
            return "{}"
        }
        return line
    }
}

struct PiResponse: Equatable {
    let id: String?
    let command: String
    let success: Bool
    let error: String?
    let dataJSON: String?
}

struct PiUIRequest: Equatable {
    let id: String
    let method: String
    let title: String?
    let message: String?
}

enum PiAssistantDelta: Equatable {
    case textDelta(String)
    case other(kind: String)
}

/// One decoded stdout record from pi RPC mode. Only the fields Agent Mode
/// displays are extracted; everything else lands in `.unknown` so protocol
/// additions never crash the client.
enum PiEvent: Equatable {
    case response(PiResponse)
    case agentStart
    case agentEnd
    case agentSettled
    case messageStart(role: String)
    case messageUpdate(PiAssistantDelta)
    case messageEnd(role: String, text: String, stopReason: String? = nil, errorMessage: String? = nil)
    case toolExecutionStart(callID: String, name: String, argsJSON: String)
    case toolExecutionUpdate(callID: String, output: String)
    case toolExecutionEnd(callID: String, output: String, isError: Bool)
    case extensionUIRequest(PiUIRequest)
    case extensionError(message: String)
    case unknown(type: String)

    /// Decode one JSONL record; nil when the line isn't a JSON object.
    static func decode(line: String) -> PiEvent? {
        guard let data = line.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = obj["type"] as? String else { return nil }
        switch type {
        case "response":
            return .response(PiResponse(
                id: obj["id"] as? String,
                command: obj["command"] as? String ?? "",
                success: obj["success"] as? Bool ?? false,
                error: obj["error"] as? String,
                dataJSON: compactJSON(obj["data"])))
        case "agent_start": return .agentStart
        case "agent_end": return .agentEnd
        case "agent_settled": return .agentSettled
        case "message_start":
            return .messageStart(role: role(of: obj["message"]))
        case "message_update":
            guard let delta = obj["assistantMessageEvent"] as? [String: Any],
                  let kind = delta["type"] as? String else {
                return .messageUpdate(.other(kind: ""))
            }
            if kind == "text_delta", let text = delta["delta"] as? String {
                return .messageUpdate(.textDelta(text))
            }
            return .messageUpdate(.other(kind: kind))
        case "message_end":
            let message = obj["message"] as? [String: Any]
            return .messageEnd(
                role: role(of: message), text: text(of: message),
                stopReason: message?["stopReason"] as? String,
                errorMessage: message?["errorMessage"] as? String)
        case "tool_execution_start":
            return .toolExecutionStart(
                callID: obj["toolCallId"] as? String ?? "",
                name: obj["toolName"] as? String ?? "",
                argsJSON: compactJSON(obj["args"]) ?? "{}")
        case "tool_execution_update":
            return .toolExecutionUpdate(
                callID: obj["toolCallId"] as? String ?? "",
                output: resultText(obj["partialResult"]))
        case "tool_execution_end":
            return .toolExecutionEnd(
                callID: obj["toolCallId"] as? String ?? "",
                output: resultText(obj["result"]),
                isError: obj["isError"] as? Bool ?? false)
        case "extension_ui_request":
            guard let id = obj["id"] as? String, let method = obj["method"] as? String else {
                return .unknown(type: type)
            }
            return .extensionUIRequest(PiUIRequest(
                id: id, method: method,
                title: obj["title"] as? String,
                message: obj["message"] as? String))
        case "extension_error":
            return .extensionError(
                message: obj["error"] as? String ?? obj["message"] as? String ?? "extension error")
        default:
            return .unknown(type: type)
        }
    }

    private static func role(of message: Any?) -> String {
        (message as? [String: Any])?["role"] as? String ?? ""
    }

    static func terminalFailure(stopReason: String?, errorMessage: String?) -> String? {
        guard stopReason == "error" || stopReason == "aborted" else { return nil }
        let detail = errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let detail, !detail.isEmpty { return detail }
        return stopReason == "aborted" ? "The model response was cancelled." : "The model could not complete this response."
    }

    /// Joins the `text` blocks of an AgentMessage `content` array.
    private static func text(of message: Any?) -> String {
        guard let content = (message as? [String: Any])?["content"] as? [[String: Any]] else { return "" }
        return content.compactMap { block in
            block["type"] as? String == "text" ? block["text"] as? String : nil
        }.joined()
    }

    /// Joins the `text` blocks of a ToolResult `content` array.
    private static func resultText(_ result: Any?) -> String {
        guard let content = (result as? [String: Any])?["content"] as? [[String: Any]] else { return "" }
        return content.compactMap { block in
            block["type"] as? String == "text" ? block["text"] as? String : nil
        }.joined(separator: "\n")
    }

    private static func compactJSON(_ value: Any?) -> String? {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(
                withJSONObject: value,
                options: [.sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
