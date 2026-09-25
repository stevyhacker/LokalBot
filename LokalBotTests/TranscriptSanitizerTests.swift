import XCTest
@testable import LokalBot

final class TranscriptSanitizerTests: XCTestCase {
    func testCollapsesImpossibleSingleWordLoopWithoutDroppingMeaningfulEdges() {
        let loop = Array(repeating: "the", count: 2_000).joined(separator: " ")
        let transcript = makeTranscript(text: "Start \(loop) ship tomorrow.", duration: 1.5)

        let result = TranscriptSanitizer.sanitize(transcript)

        XCTAssertEqual(result.changedSegments, 1)
        XCTAssertGreaterThan(result.removedWords, 1_900)
        XCTAssertEqual(result.transcript.segments[0].start, 10)
        XCTAssertEqual(result.transcript.segments[0].end, 11.5)
        XCTAssertEqual(result.transcript.segments[0].speaker, "them")
        XCTAssertEqual(result.transcript.segments[0].text, "Start the the ship tomorrow.")
    }

    func testCollapsesImpossibleMultiWordCycle() {
        let loop = Array(repeating: "um uh", count: 960).joined(separator: " ")
        let transcript = makeTranscript(text: "Before \(loop) after", duration: 4.8)

        let result = TranscriptSanitizer.sanitize(transcript)

        XCTAssertEqual(result.transcript.segments[0].text, "Before um uh um uh after")
        XCTAssertGreaterThan(result.removedWords, 1_800)
    }

    func testPreservesOrdinaryConversationalRepetition() {
        let transcript = makeTranscript(
            text: "No, no, no. I really, really mean that this is very important.",
            duration: 5)

        let result = TranscriptSanitizer.sanitize(transcript)

        XCTAssertFalse(result.changed)
        XCTAssertEqual(result.transcript.segments, transcript.segments)
        XCTAssertEqual(result.transcript.engine, transcript.engine)
        XCTAssertEqual(result.transcript.speakerAliases, transcript.speakerAliases)
    }

    func testCollapsesObservedFillerBurstsBelowOldWordCountAndRateGates() {
        for (count, duration) in [(135, 15.0), (64, 1.3)] {
            let loop = Array(repeating: "oh", count: count).joined(separator: " ")
            let result = TranscriptSanitizer.sanitize(makeTranscript(text: "\(loop).", duration: duration))
            XCTAssertEqual(result.transcript.segments[0].text, "oh oh.")
            XCTAssertEqual(result.removedWords, count - 2)
            XCTAssertFalse(TranscriptSanitizer.sanitize(result.transcript).changed)
        }
    }

    func testPreservesShortAcceptancesSlowRepetitionAndCounting() {
        for (text, duration) in [
            ("Yes, yes. I can do that.", 0.5),
            (Array(repeating: "go", count: 32).joined(separator: " "), 32.0),
            ((1...64).map(String.init).joined(separator: " "), 5.0),
        ] {
            let transcript = makeTranscript(text: text, duration: duration)
            XCTAssertEqual(TranscriptSanitizer.sanitize(transcript).transcript.segments, transcript.segments)
        }
    }

    func testImpossibleRateWithoutRepeatedCycleIsPreserved() {
        let unique = (0..<100).map { "word\($0)" }.joined(separator: " ")
        let transcript = makeTranscript(text: unique, duration: 1)

        let result = TranscriptSanitizer.sanitize(transcript)

        XCTAssertFalse(result.changed)
        XCTAssertEqual(result.transcript.segments[0].text, unique)
    }

    func testCollapsesExtremeCharacterRunAndIsIdempotent() {
        let transcript = makeTranscript(text: "Ummmmmmmmmm, yes!!!!!!!!!!", duration: 2)

        let first = TranscriptSanitizer.sanitize(transcript)
        let second = TranscriptSanitizer.sanitize(first.transcript)

        XCTAssertEqual(first.transcript.segments[0].text, "Ummm, yes!!!")
        XCTAssertTrue(first.changed)
        XCTAssertFalse(second.changed)
        XCTAssertEqual(second.transcript.segments, first.transcript.segments)
    }

    func testPreservesRepeatedDigitsInAmountsAndIdentifiers() {
        for text in [
            "The budget is 1000000000 dollars.",
            "Account 111111111111, decimal 0.000000001, and code ０００００００００１.",
        ] {
            let transcript = makeTranscript(text: text, duration: 3)
            let result = TranscriptSanitizer.sanitize(transcript)
            XCTAssertFalse(result.changed)
            XCTAssertEqual(result.transcript.segments, transcript.segments)
        }
    }

    func testLoopRemovalPreservesSurroundingNumericEvidenceAndPunctuation() {
        let loop = Array(repeating: "um", count: 135).joined(separator: " ")
        let text = "Budget: $1,000,000,000.50; \(loop); delta: -0.000000001 (ref #111111111)."
        let result = TranscriptSanitizer.sanitize(makeTranscript(text: text, duration: 10))
        XCTAssertEqual(result.transcript.segments[0].text,
                       "Budget: $1,000,000,000.50; um um; delta: -0.000000001 (ref #111111111).")
        XCTAssertEqual(result.removedWords, 133)
    }

    private func makeTranscript(text: String, duration: TimeInterval) -> Transcript {
        Transcript(
            segments: [.init(
                start: 10,
                end: 10 + duration,
                speaker: "them",
                text: text,
                confidence: 0.7)],
            engine: "test",
            speakerAliases: ["them": "Ana"])
    }
}
