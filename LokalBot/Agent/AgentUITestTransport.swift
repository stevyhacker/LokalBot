#if LOKALBOT_UI_TEST_HOST
import Foundation

/// Hosted UI fixture for the real RPC/controller/approval flow. It performs
/// no inference or tool operations, and is absent from production builds.
actor AgentUITestTransport: PiLineTransport {
    nonisolated let incoming: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    private let workspace: URL

    init(workspace: URL) {
        let stream = AsyncStream<String>.makeStream()
        incoming = stream.stream
        continuation = stream.continuation
        self.workspace = workspace
    }

    func send(line: String) async throws {
        guard let command = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let type = command["type"] as? String, let id = command["id"] as? String else { return }
        let log = workspace.appendingPathComponent("agent-ui-rpc.jsonl")
        let existing = (try? Data(contentsOf: log)) ?? Data()
        try (existing + Data((line + "\n").utf8)).write(to: log, options: .atomic)
        if type == "extension_ui_response" { return }
        try emit(["type": "response", "id": id, "command": type, "success": true])
        if type == "prompt" {
            try emit(["type": "agent_start"])
            let markdown = "## Agent result\n\n- Parent\n  - Child\n```swift\nlet value = 1\n```\n\n| Name | State |\n| --- | --- |\n| Agent | Ready |\n"
            try emit(["type": "message_start", "message": ["role": "assistant"]])
            try emit(["type": "message_update", "assistantMessageEvent": [
                "type": "text_delta", "delta": markdown,
            ]])
            try emit(["type": "message_end", "message": [
                "role": "assistant",
                "content": [["type": "text", "text": markdown]],
            ]])
            let request: [String: Any] = [
                "tool": "write", "workspace": workspace.path,
                "path": workspace.appendingPathComponent("reviewed-note.md").path,
                "content": "A proposed meeting follow-up. This fixture never writes the target.",
            ]
            let payload = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
            try emit(["type": "extension_ui_request", "id": "fixture-write", "method": "confirm",
                      "title": "lokalbot_tool_approval", "message": payload])
        } else if type == "abort" {
            try emit(["type": "agent_end"])
        }
    }

    private func emit(_ value: [String: Any]) throws {
        continuation.yield(String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self))
    }
}
#endif
