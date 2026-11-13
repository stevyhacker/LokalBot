import XCTest
@testable import LokalBot

/// FTS5 snippets mark matches with «»; the highlighter splits them into
/// runs so ResultRow can bold the matched text. The old SearchHitRow parser
/// had these exact behaviors — locked here before the move.
final class SnippetHighlighterTests: XCTestCase {

    func testPlainTextIsOneUnmatchedRun() {
        XCTAssertEqual(SnippetHighlighter.segments("no markers here"),
                       [SnippetSegment(text: "no markers here", isMatch: false)])
    }

    func testSingleMatchSplitsIntoThreeRuns() {
        XCTAssertEqual(SnippetHighlighter.segments("the «failover» plan"),
                       [SnippetSegment(text: "the ", isMatch: false),
                        SnippetSegment(text: "failover", isMatch: true),
                        SnippetSegment(text: " plan", isMatch: false)])
    }

    func testMultipleMatches() {
        XCTAssertEqual(SnippetHighlighter.segments("«a» and «b»"),
                       [SnippetSegment(text: "a", isMatch: true),
                        SnippetSegment(text: " and ", isMatch: false),
                        SnippetSegment(text: "b", isMatch: true)])
    }

    func testUnmatchedOpenMarkerRendersRemainderPlain() {
        XCTAssertEqual(SnippetHighlighter.segments("broken «tail"),
                       [SnippetSegment(text: "broken ", isMatch: false),
                        SnippetSegment(text: "tail", isMatch: false)])
    }

    func testEmptySnippetYieldsNoRuns() {
        XCTAssertEqual(SnippetHighlighter.segments(""), [])
    }
}
