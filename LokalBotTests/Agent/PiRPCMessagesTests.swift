import XCTest
@testable import LokalBot

final class PiRPCMessagesTests: XCTestCase {

    // MARK: - Command encoding

    func testPromptEncodesSingleLine() throws {
        let line = PiCommand.prompt(id: "req-1", message: "Hello\nworld", streamingBehavior: nil).jsonLine
        XCTAssertFalse(line.contains("\n"), "must be one JSONL record")
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(obj["type"] as? String, "prompt")
        XCTAssertEqual(obj["id"] as? String, "req-1")
        XCTAssertEqual(obj["message"] as? String, "Hello\nworld")
        XCTAssertNil(obj["streamingBehavior"])
    }

    func testPromptWithSteeringBehavior() throws {
        let line = PiCommand.prompt(id: "req-2", message: "x", streamingBehavior: "steer").jsonLine
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(obj["streamingBehavior"] as? String, "steer")
    }

    func testUIConfirmResponseEncoding() throws {
        let line = PiCommand.uiConfirmResponse(requestID: "uuid-2", confirmed: true).jsonLine
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(obj["type"] as? String, "extension_ui_response")
        XCTAssertEqual(obj["id"] as? String, "uuid-2")
        XCTAssertEqual(obj["confirmed"] as? Bool, true)
    }

    func testUICancelResponseEncoding() throws {
        let line = PiCommand.uiCancelResponse(requestID: "uuid-3").jsonLine
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(obj["cancelled"] as? Bool, true)
    }

    func testSimpleCommandTypes() throws {
        for (command, type) in [
            (PiCommand.steer(id: "a", message: "m"), "steer"),
            (.abort(id: "a"), "abort"),
            (.newSession(id: "a"), "new_session"),
            (.getState(id: "a"), "get_state"),
            (.getMessages(id: "a"), "get_messages"),
            (.getSessionStats(id: "a"), "get_session_stats"),
        ] {
            let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(command.jsonLine.utf8)) as? [String: Any])
            XCTAssertEqual(obj["type"] as? String, type)
        }
    }

    // MARK: - Event decoding

    func testDecodesResponse() {
        let event = PiEvent.decode(line: #"{"id": "req-1", "type": "response", "command": "prompt", "success": true}"#)
        XCTAssertEqual(event, .response(PiResponse(
            id: "req-1", command: "prompt", success: true, error: nil, dataJSON: nil)))
    }

    func testResponsePreservesDataForSessionRestoration() {
        let event = PiEvent.decode(line: #"{"id":"h1","type":"response","command":"get_messages","success":true,"data":{"messages":[{"role":"user","content":"Hi"}]}}"#)
        guard case .response(let response) = event else {
            return XCTFail("expected response event, got \(String(describing: event))")
        }
        XCTAssertEqual(response.dataJSON, #"{"messages":[{"content":"Hi","role":"user"}]}"#)
    }

    func testDecodesLifecycleEvents() {
        XCTAssertEqual(PiEvent.decode(line: #"{"type": "agent_start"}"#), .agentStart)
        XCTAssertEqual(PiEvent.decode(line: #"{"type": "agent_settled"}"#), .agentSettled)
    }

    func testDecodesTextDelta() {
        let line = #"{"type":"message_update","message":{"role":"assistant","content":[]},"assistantMessageEvent":{"type":"text_delta","contentIndex":0,"delta":"Hello ","partial":{}}}"#
        XCTAssertEqual(PiEvent.decode(line: line), .messageUpdate(.textDelta("Hello ")))
    }

    func testDecodesMessageEndJoiningTextBlocks() {
        let line = #"{"type":"message_end","message":{"role":"assistant","content":[{"type":"thinking","thinking":"hmm"},{"type":"text","text":"Hello "},{"type":"text","text":"world"}]}}"#
        XCTAssertEqual(PiEvent.decode(line: line), .messageEnd(role: "assistant", text: "Hello world"))
    }

    func testDecodesToolLifecycle() {
        let start = PiEvent.decode(line: #"{"type":"tool_execution_start","toolCallId":"call_abc123","toolName":"bash","args":{"command":"ls -la"}}"#)
        XCTAssertEqual(start, .toolExecutionStart(callID: "call_abc123", name: "bash",
                                                  argsJSON: #"{"command":"ls -la"}"#))
        let update = PiEvent.decode(line: #"{"type":"tool_execution_update","toolCallId":"call_abc123","toolName":"bash","args":{"command":"ls -la"},"partialResult":{"content":[{"type":"text","text":"partial output so far..."}],"details":{}}}"#)
        XCTAssertEqual(update, .toolExecutionUpdate(callID: "call_abc123", output: "partial output so far..."))
        let end = PiEvent.decode(line: #"{"type":"tool_execution_end","toolCallId":"call_abc123","toolName":"bash","result":{"content":[{"type":"text","text":"total 48"}],"details":{}},"isError":false}"#)
        XCTAssertEqual(end, .toolExecutionEnd(callID: "call_abc123", output: "total 48", isError: false))
    }

    /// Displayed tool args keep paths readable: "/Users/…", not "\/Users\/…".
    func testToolArgsDoNotEscapeSlashes() {
        let start = PiEvent.decode(line: #"{"type":"tool_execution_start","toolCallId":"call_1","toolName":"read","args":{"path":"/Users/me/notes.md"}}"#)
        XCTAssertEqual(start, .toolExecutionStart(callID: "call_1", name: "read",
                                                  argsJSON: #"{"path":"/Users/me/notes.md"}"#))
    }

    func testDecodesExtensionUIConfirmRequest() {
        let line = #"{"type":"extension_ui_request","id":"uuid-2","method":"confirm","title":"lokalbot_tool_approval","message":"{\"tool\":\"bash\"}"}"#
        XCTAssertEqual(PiEvent.decode(line: line), .extensionUIRequest(PiUIRequest(
            id: "uuid-2", method: "confirm",
            title: "lokalbot_tool_approval", message: #"{"tool":"bash"}"#)))
    }

    func testUnknownEventTypeIsPreserved() {
        XCTAssertEqual(PiEvent.decode(line: #"{"type":"queue_update","steering":[]}"#), .unknown(type: "queue_update"))
    }

    func testGarbageLineDecodesToNil() {
        XCTAssertNil(PiEvent.decode(line: "not json"))
        XCTAssertNil(PiEvent.decode(line: "[1,2,3]"))
    }
}
