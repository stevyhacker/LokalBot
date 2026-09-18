import XCTest
@testable import LokalBot

/// Citation-marker parsing: meeting and screen markers the assistant emits are
/// replaced with stable inline numbers and surfaced as deep-linkable sources, while
/// ordinary bracketed text passes through untouched.
final class ChatCitationTests: XCTestCase {

    func testExtractTimedMarker() {
        let (display, citations) = ChatCitationParser.extract(
            "You agreed to ship Friday [meeting:a1b2c3d4@00:14:32].")
        XCTAssertEqual(display, "You agreed to ship Friday [1].")
        XCTAssertEqual(citations, [ChatCitation(meetingID: "a1b2c3d4", seconds: 872)])
        XCTAssertEqual(citations.first?.stampText, "00:14:32")
    }

    func testExtractUntimedAndShortStampMarkers() {
        let (display, citations) = ChatCitationParser.extract(
            "Decided in kickoff [meeting:a1b2c3d4] and revisited [meeting:ffee9900@7:05].")
        XCTAssertEqual(display, "Decided in kickoff [1] and revisited [2].")
        XCTAssertEqual(citations, [
            ChatCitation(meetingID: "a1b2c3d4", seconds: nil),
            ChatCitation(meetingID: "ffee9900", seconds: 425),
        ])
    }

    func testDuplicateMarkersDedupe() {
        let (_, citations) = ChatCitationParser.extract(
            "A [meeting:a1b2c3d4@0:30]. B [meeting:a1b2c3d4@0:30]. C [meeting:a1b2c3d4@0:45].")
        XCTAssertEqual(citations.count, 2)
    }

    func testExtractScreenMarkerAlongsideMeeting() {
        let (display, citations) = ChatCitationParser.extract(
            "The design was visible here [screen:4821] and discussed later [meeting:a1b2c3d4@0:30].")
        XCTAssertEqual(display, "The design was visible here [1] and discussed later [2].")
        XCTAssertEqual(citations, [
            ChatCitation(snapshotID: 4_821),
            ChatCitation(meetingID: "a1b2c3d4", seconds: 30),
        ])
        XCTAssertEqual(citations.first?.snapshotID, 4_821)
        XCTAssertEqual(citations.first?.kind, .screen)
    }

    func testMalformedScreenMarkersStayVisible() {
        let text = "Odd [screen:abc] and [screen:0] and [screen:12@0:30] stay."
        let (display, citations) = ChatCitationParser.extract(text)
        XCTAssertEqual(display, text)
        XCTAssertTrue(citations.isEmpty)
    }

    func testTextWithoutMarkersPassesThrough() {
        let text = "No citations here — [link](https://example.com) stays, and [meeting notes] too."
        let (display, citations) = ChatCitationParser.extract(text)
        XCTAssertEqual(display, text)
        XCTAssertTrue(citations.isEmpty)
    }

    func testMalformedMarkersAreLeftInPlace() {
        let text = "Odd [meeting:ab] and [meeting:] stay."      // id too short / missing
        let (display, citations) = ChatCitationParser.extract(text)
        XCTAssertEqual(display, text)
        XCTAssertTrue(citations.isEmpty)
    }

    func testSecondsFromStampForms() {
        XCTAssertEqual(ChatCitationParser.seconds(from: "1:23"), 83)
        XCTAssertEqual(ChatCitationParser.seconds(from: "00:14:32"), 872)
        XCTAssertEqual(ChatCitationParser.seconds(from: "2:00:05"), 7_205)
        XCTAssertNil(ChatCitationParser.seconds(from: "1:99"))
        XCTAssertNil(ChatCitationParser.seconds(from: "12"))
    }

    func testEditorialMarkdownBuildsOneContinuousVisibleString() throws {
        let rendered = SelectableDigestText.attributedText(
            from: """
            # Proposed task

            **Summary:** Keep inline `code` and an ordinary [label] before [1].
            - First step [2]
            - [x] Completed step
            1. Verify the result
            > Local-only context
            """,
            style: .editorial)

        XCTAssertEqual(String(rendered.characters), """
        Proposed task

        Summary: Keep inline code and an ordinary [label] before [1].
        • First step [2]
        ☑ Completed step
        1. Verify the result
        ▎ Local-only context
        """)

        let plainText = String(rendered.characters)
        let citation = try XCTUnwrap(plainText.range(of: "[1]"))
        let lowerBound = try XCTUnwrap(
            AttributedString.Index(citation.lowerBound, within: rendered))
        let upperBound = try XCTUnwrap(
            AttributedString.Index(citation.upperBound, within: rendered))
        let citationRun = try XCTUnwrap(rendered[lowerBound..<upperBound].runs.first)

        XCTAssertEqual(citationRun.font, WorkspaceTypography.metadataEmphasis)
        XCTAssertEqual(citationRun.foregroundColor, Brand.teal)
    }

    func testAgentMarkdownRendersNestedListsAndFencedCode() {
        let rendered = SelectableDigestText.attributedText(
            from: "## Agent output\n\n- Parent\n  - Child\n+ [X] Done\n```swift\nlet value = 1\n    print(value)\n```\n",
            style: .agent)

        XCTAssertEqual(String(rendered.characters),
                       "Agent output\n\n• Parent\n  • Child\n☑ Done\nlet value = 1\n    print(value)\n")
    }
}
