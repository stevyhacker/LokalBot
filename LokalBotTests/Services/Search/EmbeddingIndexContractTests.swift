import XCTest
@testable import LokalBot

/// The embedding contract that has to change together with the model: prompts,
/// request options, response decoding, score floors, and obsolete-model cleanup.
final class EmbeddingIndexContractTests: XCTestCase {
    private func vectorData(_ values: [Float]) -> Data {
        values.withUnsafeBufferPointer { buffer in
            Data(bytes: buffer.baseAddress!, count: buffer.count * MemoryLayout<Float>.stride)
        }
    }

    func testRequestUsesTheModelPromptAndDisablesPromptCaching() throws {
        let body = EmbeddingIndex.embeddingRequestBody(
            ["budget review"], prefix: EmbeddingIndex.queryPrefix)

        XCTAssertEqual(body["input"] as? [String], ["task: search result | query: budget review"])
        XCTAssertEqual(body["model"] as? String, EmbeddingIndex.modelID)
        // A bidirectional encoder must never reuse another input's cached prompt.
        XCTAssertEqual(body["cache_prompt"] as? Bool, false)
        XCTAssertEqual(
            EmbeddingIndex.embeddingRequestBody(["notes"], prefix: EmbeddingIndex.documentPrefix)["input"]
                as? [String],
            ["title: none | text: notes"])
    }

    func testResponseVectorsFollowInputIndexAndAreNormalized() throws {
        let response = Data("""
            {"data": [
                {"index": 1, "embedding": [0.0, 2.0]},
                {"index": 0, "embedding": [3.0, 4.0]}
            ]}
            """.utf8)

        let vectors = try EmbeddingIndex.embeddingVectors(fromResponse: response)

        XCTAssertEqual(vectors.count, 2)
        XCTAssertEqual(vectors[0][0], 0.6, accuracy: 1e-6)
        XCTAssertEqual(vectors[0][1], 0.8, accuracy: 1e-6)
        XCTAssertEqual(vectors[1], [0, 1])
    }

    func testResponseWithoutDataIsRejected() {
        XCTAssertThrowsError(try EmbeddingIndex.embeddingVectors(fromResponse: Data("{}".utf8)))
    }

    /// EmbeddingGemma 2 scores unrelated meeting chunks around 0.59, above
    /// Harrier's 0.45 floor, so the recalibrated floor must drop them.
    func testMeetingRankingDropsChunksBelowTheEmbeddingFloor() {
        let meetingID = UUID()
        let candidates = [
            EmbeddingIndex.Candidate(meetingID: meetingID, start: 10, text: "unrelated",
                                     vector: vectorData([0.55, 0.83])),
            EmbeddingIndex.Candidate(meetingID: meetingID, start: 20, text: "related",
                                     vector: vectorData([0.70, 0.71])),
        ]

        let hits = EmbeddingIndex.rank(candidates, against: [1, 0], limit: 10)

        XCTAssertEqual(hits.map(\.text), ["related"])
    }

    func testObsoleteEmbedderFilesAreRemovedByExactNameOnly() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("obsolete-embedders-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let kept = [EmbeddingIndex.modelFile, "Qwen3.5-4B-Q4_K_M.gguf", "harrier-oss-v2-custom.gguf"]
        let removed = EmbeddingIndex.obsoleteModelFiles.flatMap { [$0, $0 + ".sha256"] }
        for name in kept + removed {
            XCTAssertTrue(FileManager.default.createFile(
                atPath: folder.appendingPathComponent(name).path, contents: Data("x".utf8)))
        }

        EmbeddingIndex.removeObsoleteModels(in: folder)

        let remaining = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        XCTAssertEqual(remaining, kept.sorted())
        XCTAssertFalse(EmbeddingIndex.obsoleteModelFiles.contains(EmbeddingIndex.modelFile))
    }
}
