import XCTest
@testable import LokalBot

final class CotypingTokenCandidatesTests: XCTestCase {
    private func ranked(_ logits: [Float], limit: Int = 64) -> [Int32] {
        logits.withUnsafeBufferPointer {
            CotypingTokenCandidates.topTokens(
                in: $0.baseAddress, vocabularySize: Int32($0.count), limit: limit)
        }
    }

    /// The pre-optimization implementation is the behavioral oracle: healing
    /// must visit exactly the same candidates, including its rank-64 cutoff.
    private func repeatedArgmax(_ logits: [Float], limit: Int) -> [Int32] {
        var scores = logits
        var result: [Int32] = []
        for _ in 0..<max(0, limit) {
            let token = scores.withUnsafeBufferPointer {
                LlamaCotypingRuntime.argmaxToken(in: $0.baseAddress, vocabularySize: Int32($0.count))
            }
            guard let token else { break }
            result.append(token)
            scores[Int(token)] = -.infinity
        }
        return result
    }

    func testMatchesPreviousHealingCandidatesForModelSizedVocabulary() {
        var seed: UInt64 = 42
        let logits = (0..<65_536).map { _ -> Float in
            seed = seed &* 6_364_136_223_846_793_005 &+ 1
            return Float(Int64(bitPattern: seed) % 100_000) / 1000
        }
        XCTAssertEqual(ranked(logits), repeatedArgmax(logits, limit: 64))
    }

    func testHeapHandlesBothVocabularyOrdersAndDifferentLimits() {
        let ascending = (0..<129).map { Float($0) }
        for logits in [ascending, Array(ascending.reversed()), Array(repeating: Float(1), count: 129)] {
            for limit in [1, 2, 3, 63, 64, 65, 129, 130] {
                XCTAssertEqual(ranked(logits, limit: limit), repeatedArgmax(logits, limit: limit))
            }
        }
    }

    func testTiesAtScanCutoffPreferLowerTokenIDs() {
        XCTAssertEqual(ranked(Array(repeating: 3, count: 128)), (0..<64).map(Int32.init))
    }

    func testNonFiniteLogitsAndInputPreservation() {
        let logits: [Float] = [.nan, -.infinity, .infinity, -2, .infinity, 0, 0, .nan]
        let originalBits = logits.map(\.bitPattern)
        XCTAssertEqual(ranked(logits), [2, 4, 5, 6, 3])
        XCTAssertEqual(ranked(logits), repeatedArgmax(logits, limit: 64))
        XCTAssertEqual(logits.map(\.bitPattern), originalBits, "Native logits must remain untouched")
        XCTAssertTrue(ranked([.nan, -.infinity]).isEmpty)
    }

    func testEmptyOrInvalidArgumentsHaveNoCandidates() {
        XCTAssertTrue(ranked([]).isEmpty)
        XCTAssertTrue(ranked([1], limit: 0).isEmpty)
        XCTAssertTrue(ranked([1], limit: -1).isEmpty)
        XCTAssertTrue(CotypingTokenCandidates.topTokens(in: nil, vocabularySize: 10, limit: 64).isEmpty)
        [Float(1)].withUnsafeBufferPointer {
            XCTAssertTrue(CotypingTokenCandidates.topTokens(in: $0.baseAddress, vocabularySize: 0, limit: 64).isEmpty)
            XCTAssertTrue(CotypingTokenCandidates.topTokens(in: $0.baseAddress, vocabularySize: -1, limit: 64).isEmpty)
        }
    }
}
