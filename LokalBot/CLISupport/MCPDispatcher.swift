import Foundation

/// Pure MCP method routing: one JSON line in, one optional JSON line out.
struct MCPDispatcher {
    static let supportedProtocolVersions = ["2024-11-05", "2025-03-26", "2025-06-18"]

    /// Sent with `initialize` so clients that surface server instructions
    /// tell the model to orient itself before asking the user.
    static let instructions = """
        LokalBot is the user's local memory of their meetings, screen, and what they shared about \
        themselves. At the start of a session, call get_briefing. Before asking the user about past \
        work, decisions, commitments, or where something stands, search LokalBot first.
        """

    var provider: LibraryToolProvider
    var serverVersion: String

    func handle(line: String) async -> String? {
        switch MCPRequest.parse(line) {
        case .failure(let code, let message, let id):
            return MCPResponse.failure(id: id, code: code, message: message)
        case .request(let request):
            return await handle(request: request)
        }
    }

    private func handle(request: MCPRequest) async -> String? {
        guard let id = request.id else { return nil }

        switch request.method {
        case "initialize":
            let requested = request.params?["protocolVersion"]?.stringValue
            let version = Self.supportedProtocolVersions.contains(requested ?? "")
                ? requested!
                : Self.supportedProtocolVersions.last!
            return MCPResponse.success(id: id, result: .object([
                "protocolVersion": .string(version),
                "capabilities": .object(["tools": .object([:])]),
                "serverInfo": .object([
                    "name": "lokalbot",
                    "version": .string(serverVersion),
                ]),
                "instructions": .string(Self.instructions),
            ]))
        case "tools/list":
            return MCPResponse.success(id: id, result: .object([
                "tools": .array(provider.tools.map(\.json)),
            ]))
        case "tools/call":
            guard case .some(.string(let name)) = request.params?["name"] else {
                return MCPResponse.failure(
                    id: id,
                    code: -32602,
                    message: "tools/call requires params.name")
            }
            let result = await provider.call(
                name: name,
                arguments: request.params?["arguments"])
            return MCPResponse.success(id: id, result: result.json)
        case "ping":
            return MCPResponse.success(id: id, result: .object([:]))
        default:
            return MCPResponse.failure(
                id: id,
                code: -32601,
                message: "Method not found: \(request.method)")
        }
    }
}
