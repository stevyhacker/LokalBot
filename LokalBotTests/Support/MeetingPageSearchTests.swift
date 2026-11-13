import XCTest
@testable import LokalBot

final class MeetingPageSearchTests: XCTestCase {
    func testMatchesAllMeetingContentSourcesInReadingOrder() {
        let actionID = "action-1"
        let decisionID = "decision-1"
        let matches = MeetingPageSearch.matches(
            query: "cafe",
            sources: [
                .init(location: .title, text: "Café review"),
                .init(location: .meetingMetadata(.app), text: "Cafe Meet"),
                .init(
                    location: .action(id: actionID, field: .text),
                    text: "Open the cafe branch"),
                .init(
                    location: .decision(id: decisionID, field: .text),
                    text: "Keep CAFE open"),
                .init(location: .notes, text: "Café note"),
                .init(
                    location: .summary,
                    text: "CAFE appears once, then café appears again."),
                .init(location: .transcriptEngine, text: "Transcribed with cafe-asr"),
                .init(
                    location: .transcript(segmentIndex: 0, field: .speaker),
                    text: "Cafe guest"),
                .init(
                    location: .transcript(segmentIndex: 0, field: .text),
                    text: "A cafe transcript hit."),
            ])

        XCTAssertEqual(matches, [
            .init(location: .title, occurrenceIndex: 0),
            .init(location: .meetingMetadata(.app), occurrenceIndex: 0),
            .init(location: .action(id: actionID, field: .text), occurrenceIndex: 0),
            .init(location: .decision(id: decisionID, field: .text), occurrenceIndex: 0),
            .init(location: .notes, occurrenceIndex: 0),
            .init(location: .summary, occurrenceIndex: 0),
            .init(location: .summary, occurrenceIndex: 1),
            .init(location: .transcriptEngine, occurrenceIndex: 0),
            .init(
                location: .transcript(segmentIndex: 0, field: .speaker),
                occurrenceIndex: 0),
            .init(
                location: .transcript(segmentIndex: 0, field: .text),
                occurrenceIndex: 0),
        ])
    }

    func testWhitespaceOnlyQueryHasNoMatches() {
        let matches = MeetingPageSearch.matches(
            query: "  \n ",
            sources: [.init(location: .summary, text: "Text")])

        XCTAssertTrue(matches.isEmpty)
    }

    func testOnlyTranscriptBodyLocationsRequireDisclosureExpansion() {
        XCTAssertFalse(MeetingPageSearchMatch.Location
            .sectionHeader(.transcript).requiresTranscriptExpansion)
        XCTAssertTrue(MeetingPageSearchMatch.Location
            .transcriptEngine.requiresTranscriptExpansion)
        XCTAssertTrue(MeetingPageSearchMatch.Location
            .transcript(segmentIndex: 0, field: .speaker)
            .requiresTranscriptExpansion)
    }

    func testRangesAreCaseInsensitiveAndNonOverlapping() {
        let text = "Redis REDIS redis"
        let ranges = MeetingPageSearch.ranges(in: text, query: "redis")

        XCTAssertEqual(ranges.map { String(text[$0]) }, ["Redis", "REDIS", "redis"])
    }
}
