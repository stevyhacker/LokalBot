import AppKit
import XCTest
@testable import LokalBot

// MARK: - Streaming SSE parsing

final class CotypingStreamingTests: XCTestCase {
    func testParsesTextDelta() {
        XCTAssertEqual(cotypingParseSSEDelta(#"data: {"choices":[{"text":"eive"}]}"#), "eive")
    }

    func testIgnoresDoneSentinel() {
        XCTAssertNil(cotypingParseSSEDelta("data: [DONE]"))
        XCTAssertEqual(cotypingParseSSEEvent("data: [DONE]"),
                       CotypingSSEEvent(delta: nil, isTerminal: true))
    }

    func testFinishReasonMarksTerminalChunk() {
        XCTAssertEqual(
            cotypingParseSSEEvent(
                #"data: {"choices":[{"text":"","finish_reason":"stop"}]}"#),
            CotypingSSEEvent(delta: "", isTerminal: true))
    }

    func testIgnoresNonDataLines() {
        XCTAssertNil(cotypingParseSSEDelta(""))
        XCTAssertNil(cotypingParseSSEDelta(": keep-alive"))
        XCTAssertNil(cotypingParseSSEDelta("event: message"))
    }

    func testEmptyTextDeltaIsEmptyNotNil() {
        XCTAssertEqual(cotypingParseSSEDelta(#"data: {"choices":[{"text":""}]}"#), "")
    }
}
