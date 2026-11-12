import XCTest
@testable import LokalBot

final class WhisperStockPhrasesTests: XCTestCase {
    private func transcript(_ texts: [String]) -> Transcript {
        Transcript(segments: texts.enumerated().map { index, text in
            .init(start: Double(index) * 4, end: Double(index) * 4 + 3, speaker: "them", text: text)
        }, engine: "whisper-large-v3-turbo (WhisperKit)")
    }

    private let serbian = [
        "Projekat kasni dvije sedmice zbog problema sa dobavljačem.",
        "Thank you.",
        "Budžet za sljedeći kvartal još nije odobren, ali radimo na tome.",
        "Thank you, guys!",
        "Hvala, vidimo se sutra na sastanku u deset.",
    ]

    func testStockPhrasesLeaveTracksInAnotherLanguage() {
        let set = WhisperStockPhrases.removing(from: transcript(serbian), language: "bs")
        XCTAssertEqual(set.removedSegments, 2)
        XCTAssertEqual(set.transcript.segments.map(\.text), [serbian[0], serbian[2], serbian[4]])

        let detected = WhisperStockPhrases.removing(from: transcript(serbian), language: nil)
        XCTAssertEqual(detected.removedSegments, 2, "On auto, a track voting Serbian-Croatian is not English")
    }

    func testEnglishTracksKeepThem() {
        let english = [
            "We are polishing the fee extraction pull request and I have a few conflicts to solve now.",
            "Thank you.",
            "Hopefully I have something by next week that we can try integrating into the interface.",
        ]
        XCTAssertEqual(WhisperStockPhrases.removing(from: transcript(english), language: "en").removedSegments, 0)
        XCTAssertEqual(WhisperStockPhrases.removing(from: transcript(english), language: nil).removedSegments, 0)
        XCTAssertEqual(WhisperStockPhrases.removing(from: transcript(serbian), language: "en").removedSegments, 0,
                       "Set to English, a Serbian call is translated: a thank-you may be one")
    }

    func testOnlyWholeRowsCount() {
        XCTAssertTrue(WhisperStockPhrases.isStockPhrase("Thank you."))
        XCTAssertTrue(WhisperStockPhrases.isStockPhrase(" thank you very much! "))
        XCTAssertFalse(WhisperStockPhrases.isStockPhrase("Thank you for the update on the budget."))
        XCTAssertFalse(WhisperStockPhrases.isStockPhrase("Hvala."))
    }
}
