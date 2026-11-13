import XCTest
@testable import LokalBot

/// pi RPC framing rules (docs/rpc.md "Framing"): LF is the ONLY record
/// delimiter; a trailing CR is stripped; U+2028/U+2029 inside JSON strings
/// must not split records.
final class PiJSONLFrameSplitterTests: XCTestCase {

    func testSplitsOnLFOnly() {
        var splitter = PiJSONLFrameSplitter()
        let lines = splitter.append(Data("{\"a\":1}\n{\"b\":2}\n".utf8))
        XCTAssertEqual(lines, ["{\"a\":1}", "{\"b\":2}"])
    }

    func testDoesNotSplitOnUnicodeLineSeparators() {
        var splitter = PiJSONLFrameSplitter()
        let record = "{\"text\":\"one\u{2028}two\u{2029}three\"}"
        let lines = splitter.append(Data((record + "\n").utf8))
        XCTAssertEqual(lines, [record])
    }

    func testStripsSingleTrailingCR() {
        var splitter = PiJSONLFrameSplitter()
        let lines = splitter.append(Data("{\"a\":1}\r\n".utf8))
        XCTAssertEqual(lines, ["{\"a\":1}"])
    }

    func testReassemblesRecordsAcrossChunks() {
        var splitter = PiJSONLFrameSplitter()
        // Split mid-record AND mid-UTF-8-sequence (é is 2 bytes).
        let full = Data("{\"text\":\"café\"}\n".utf8)
        var collected: [String] = []
        collected += splitter.append(full.prefix(5))
        collected += splitter.append(full.dropFirst(5).prefix(9))
        collected += splitter.append(full.dropFirst(14))
        XCTAssertEqual(collected, ["{\"text\":\"café\"}"])
    }

    func testFlushReturnsUnterminatedRemainder() {
        var splitter = PiJSONLFrameSplitter()
        XCTAssertEqual(splitter.append(Data("{\"a\":1}".utf8)), [])
        XCTAssertEqual(splitter.flush(), "{\"a\":1}")
        XCTAssertNil(splitter.flush())
    }

    func testSkipsEmptyLines() {
        var splitter = PiJSONLFrameSplitter()
        XCTAssertEqual(splitter.append(Data("\n\n{\"a\":1}\n\n".utf8)), ["{\"a\":1}"])
    }

    func testOversizedFrameIsDiscardedAndFollowingFrameSurvives() {
        var splitter = PiJSONLFrameSplitter(maximumFrameBytes: 1_024)
        let oversized = String(repeating: "x", count: 2_000)
        let lines = splitter.append(Data((oversized + "\n{\"ok\":true}\n").utf8))
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("safety limit"))
        XCTAssertEqual(lines[1], #"{"ok":true}"#)
    }

    func testInvalidUTF8BecomesProtocolErrorFrame() {
        var splitter = PiJSONLFrameSplitter()
        XCTAssertTrue(splitter.append(Data([0xFF, 0x0A])).first?.contains("valid UTF-8") == true)
    }
}
