import XCTest
@testable import LokalBot

final class ExternalAgentHandoffTests: XCTestCase {
    func testLinksUseEachAppsDocumentedRoute() throws {
        let claude = try XCTUnwrap(ExternalAgentHandoff.claude.url(prompt: "Hi"))
        XCTAssertEqual(claude.absoluteString, "claude://claude.ai/new?q=Hi")
        let codex = try XCTUnwrap(ExternalAgentHandoff.codex.url(prompt: "Hi"))
        XCTAssertEqual(codex.absoluteString, "codex://new?prompt=Hi")
    }

    /// URLSearchParams reads a bare `+` as a space and `&` as a new
    /// parameter, so both must arrive percent-encoded.
    func testPromptSurvivesQueryParsing() throws {
        let prompt = "C++ & Q&A = 100% #1?\nДоговор: Ana's \"plan\" 🚀"
        for target in ExternalAgentHandoff.allCases {
            let url = try XCTUnwrap(target.url(prompt: prompt))
            let query = try XCTUnwrap(url.query(percentEncoded: true))
            let value = try XCTUnwrap(query.split(separator: "=", maxSplits: 1).last)
            XCTAssertFalse(value.contains { "+&=# \n".contains($0) }, "\(target): \(value)")
            XCTAssertEqual(String(value).removingPercentEncoding, prompt)
        }
    }

    func testTranscriptFillsTheRoomTheNotesLeave() throws {
        var requested: [Int?] = []
        let prompt = ExternalAgentHandoff.prompt(meetingID: "abcd1234", limit: 5_000) { characters in
            requested.append(characters)
            let notes = "# Design review\n\n## Summary\nShip Friday.\n"
            guard let characters else { return notes }
            return notes + "## Transcript\n" + String(repeating: "x", count: characters)
        }
        XCTAssertEqual(requested.count, 2)
        XCTAssertNil(requested[0])
        let room = try XCTUnwrap(requested[1])
        XCTAssertGreaterThan(room, 4_500)
        XCTAssertTrue(prompt.hasPrefix("Here are my notes from a meeting recorded in LokalBot (meeting ID abcd1234)."))
        XCTAssertTrue(prompt.contains("## Transcript"))
        XCTAssertFalse(prompt.hasSuffix("[Cut short to fit.]"))
        XCTAssertLessThanOrEqual(prompt.count, 5_000)
    }

    func testLongNotesSkipTheTranscriptAndAreCutToTheLimit() {
        var requested: [Int?] = []
        let prompt = ExternalAgentHandoff.prompt(meetingID: "abcd1234", limit: 2_000) { characters in
            requested.append(characters)
            return "## Summary\n" + String(repeating: "word ", count: 1_000)
        }
        XCTAssertEqual(requested, [nil], "No room is left for a transcript window")
        XCTAssertEqual(prompt.count, 2_000)
        XCTAssertTrue(prompt.hasSuffix("[Cut short to fit.]"))
    }
}
