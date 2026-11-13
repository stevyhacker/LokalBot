import XCTest
@testable import LokalBot

final class SpeakerNameHintExtractorTests: XCTestCase {
    func testCalendarNamesAreNormalizedAndDeduplicated() {
        let hints = SpeakerNameHintExtractor.hints(calendarNames: [
            " Ana Maria ",
            "ana maria",
            "https://example.com",
            "Chat"
        ])

        XCTAssertEqual(hints, ["Ana Maria"])
    }

    func testExtractsNamesFromParticipantRosterOCR() {
        let ocr = """
        Meeting details
        Participants (4)
        Stevan (host)
        Ana Maria
        Mute
        Copy link
        """

        let hints = SpeakerNameHintExtractor.hints(ocrText: ocr)

        XCTAssertEqual(hints, ["Stevan", "Ana Maria"])
    }

    func testIgnoresNamesOutsideRosterContext() {
        let ocr = """
        Sprint Planning
        Redis
        Please benchmark failover latency
        """

        XCTAssertTrue(SpeakerNameHintExtractor.hints(ocrText: ocr).isEmpty)
    }
}
