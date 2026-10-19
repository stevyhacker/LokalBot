import Foundation

/// `lokalbot-cli ask` and `reply` output. JSON keeps the text and its sources
/// apart, so a launcher can paste a draft without a Sources list.
extension AskLibraryOutcome {
    private struct Payload: Encodable {
        var status: String
        var code: String?
        var text: String
        var sources: [AskLibraryContext.Citation]
    }

    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }

    /// `{"status": "answered" | "not_found" | "error", "code"?, "text", "sources"}`.
    var json: String {
        let payload: Payload
        switch self {
        case .answered(let text, let citations):
            payload = Payload(status: "answered", text: text, sources: citations)
        case .notFound(let text):
            payload = Payload(status: "not_found", text: text, sources: [])
        case .failed(let code, let message):
            payload = Payload(status: "error", code: code.rawValue, text: message, sources: [])
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? String(data: encoder.encode(payload), encoding: .utf8)) ?? "{}"
    }

    /// The `--table` form: the same text as the `ask_library` MCP tool.
    var plainText: String { toolResult.text }
}
