import XCTest
@testable import LokalBot

@MainActor
final class EmbeddingIndexChunkingTests: XCTestCase {

    func testOrdinarySegmentsKeepHistoricalChunkShape() {
        let first = String(repeating: "a", count: 260)
        let second = String(repeating: "b", count: 260)
        let transcript = Transcript(
            segments: [
                .init(start: 10, end: 11, speaker: "me", text: first, confidence: nil),
                .init(start: 12, end: 13, speaker: "them", text: second, confidence: nil),
            ],
            engine: "test")

        let chunks = EmbeddingIndex.transcriptChunks(transcript)

        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].start, 10)
        XCTAssertEqual(chunks[0].text, "Me: \(first)\nThem: \(second)\n")
    }

    func testOversizedSegmentIsSplitWithoutLosingSourceText() throws {
        let longText = (0..<700).map { "token\($0)" }.joined(separator: " ")
        let transcript = Transcript(
            segments: [
                .init(start: 42, end: 90, speaker: "me", text: longText, confidence: nil),
            ],
            engine: "test")

        let chunks = EmbeddingIndex.transcriptChunks(transcript)

        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy {
            $0.text.count <= EmbeddingIndex.transcriptChunkTargetCharacters
        })
        XCTAssertTrue(chunks.allSatisfy { $0.start == 42 })
        XCTAssertEqual(chunks.map(\.text).joined(), "Me: \(longText)\n")
    }

    func testHardLimitFlushesExistingTextBeforeLargeValidSegment() throws {
        let first = String(repeating: "a", count: 400)
        let second = String(repeating: "b", count: 1_500)
        let transcript = Transcript(
            segments: [
                .init(start: 1, end: 2, speaker: "me", text: first, confidence: nil),
                .init(start: 3, end: 4, speaker: "them", text: second, confidence: nil),
            ],
            engine: "test")

        let chunks = EmbeddingIndex.transcriptChunks(transcript)

        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks.map(\.start), [1, 3])
        XCTAssertTrue(chunks.allSatisfy {
            $0.text.count <= EmbeddingIndex.transcriptChunkHardLimitCharacters
        })
    }
}
