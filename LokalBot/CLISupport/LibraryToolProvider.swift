import Foundation

/// One tool as advertised by `tools/list`.
struct ToolDefinition {
    var name: String
    var description: String
    var inputSchema: JSONValue

    var json: JSONValue {
        .object([
            "name": .string(name),
            "description": .string(description),
            "inputSchema": inputSchema,
        ])
    }
}

/// Stable machine-readable failure codes for MCP tool calls.
enum ToolErrorCode: String {
    case accessDisabled = "access_disabled"
    case screenAccessDisabled = "screen_access_disabled"
    case personalContextDisabled = "personal_context_disabled"
    case personalContextUnavailable = "personal_context_unavailable"
    case screenMemoryUnavailable = "screen_memory_unavailable"
    case screenshotNotFound = "screenshot_not_found"
    case appNotRunning = "app_not_running"
    case engineUnavailable = "engine_unavailable"
    case modelLoadingTimeout = "model_loading_timeout"
    case meetingNotFound = "meeting_not_found"
    case ambiguousID = "ambiguous_id"
    case unknownTool = "unknown_tool"
    case invalidArguments = "invalid_arguments"
}

/// Outcome of a `tools/call` in MCP content-result form.
struct ToolResult {
    var text: String
    var isError: Bool

    static func text(_ text: String) -> ToolResult {
        ToolResult(text: text, isError: false)
    }

    static func error(_ code: ToolErrorCode, _ message: String) -> ToolResult {
        ToolResult(text: "[\(code.rawValue)] \(message)", isError: true)
    }

    var json: JSONValue {
        .object([
            "content": .array([
                .object(["type": "text", "text": .string(text)]),
            ]),
            "isError": .bool(isError),
        ])
    }
}

/// Separates the MCP wire layer from the owner of the meeting library.
protocol LibraryToolProvider {
    var tools: [ToolDefinition] { get }
    func call(name: String, arguments: JSONValue?) async -> ToolResult
}
