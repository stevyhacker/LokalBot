import XCTest
@testable import LokalBot

private struct StubToolProvider: LibraryToolProvider {
    var tools: [ToolDefinition] {
        [ToolDefinition(
            name: "echo",
            description: "echoes text back",
            inputSchema: .object(["type": "object"]))]
    }

    func call(name: String, arguments: JSONValue?) async -> ToolResult {
        guard name == "echo" else {
            return .error(.unknownTool, "no tool named \(name)")
        }
        return .text("echo:" + (arguments?["text"]?.stringValue ?? ""))
    }
}

final class MCPDispatcherTests: XCTestCase {
    private var dispatcher: MCPDispatcher {
        MCPDispatcher(provider: StubToolProvider(), serverVersion: "1.2.3")
    }

    func testInitializeEchoesKnownProtocolVersionAndServerInfo() async {
        let response = await dispatcher.handle(
            line: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}"#)
        XCTAssertNotNil(response)
        XCTAssertTrue(response!.contains(#""protocolVersion":"2024-11-05""#), response!)
        XCTAssertTrue(response!.contains(#""name":"lokalbot""#), response!)
        XCTAssertTrue(response!.contains(#""version":"1.2.3""#), response!)
        XCTAssertTrue(response!.contains(#""tools":{}"#), response!)
        // Clients that surface server instructions tell the model to orient first.
        XCTAssertTrue(response!.contains(#""instructions":"#), response!)
        XCTAssertTrue(response!.contains("call get_briefing"), response!)
    }

    func testInitializeWithUnknownVersionAnswersOurNewest() async {
        let response = await dispatcher.handle(
            line: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"9999-01-01"}}"#)
        XCTAssertTrue(response!.contains(#""protocolVersion":"2025-06-18""#), response!)
    }

    func testNotificationGetsNoResponse() async {
        let response = await dispatcher.handle(
            line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        XCTAssertNil(response)
    }

    func testToolsListIncludesProviderTools() async {
        let response = await dispatcher.handle(
            line: #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        XCTAssertTrue(response!.contains(#""name":"echo""#), response!)
        XCTAssertTrue(response!.contains(#""inputSchema""#), response!)
    }

    func testToolsCallRoutesToProvider() async {
        let response = await dispatcher.handle(
            line: #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"text":"hi"}}}"#)
        XCTAssertTrue(response!.contains("echo:hi"), response!)
        XCTAssertTrue(response!.contains(#""isError":false"#), response!)
    }

    func testToolErrorEncodesIsErrorTrueWithCode() async {
        let response = await dispatcher.handle(
            line: #"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"missing"}}"#)
        XCTAssertTrue(response!.contains(#""isError":true"#), response!)
        XCTAssertTrue(response!.contains("[unknown_tool]"), response!)
    }

    func testToolsCallWithoutNameIsInvalidParams() async {
        let response = await dispatcher.handle(
            line: #"{"jsonrpc":"2.0","id":4,"method":"tools/call"}"#)
        XCTAssertTrue(response!.contains("-32602"), response!)
    }

    func testUnknownMethodIsMethodNotFound() async {
        let response = await dispatcher.handle(
            line: #"{"jsonrpc":"2.0","id":5,"method":"resources/list"}"#)
        XCTAssertTrue(response!.contains("-32601"), response!)
    }

    func testMalformedLineGetsParseErrorResponse() async {
        let response = await dispatcher.handle(line: "not json")
        XCTAssertTrue(response!.contains("-32700"), response!)
    }

    func testPingAnswersEmptyResult() async {
        let response = await dispatcher.handle(
            line: #"{"jsonrpc":"2.0","id":6,"method":"ping"}"#)
        XCTAssertEqual(response, #"{"id":6,"jsonrpc":"2.0","result":{}}"#)
    }
}
