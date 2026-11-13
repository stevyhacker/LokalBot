import XCTest
@testable import LokalBot

/// Screen search ranks DigUp's way: meaning on the query's scale per kind of
/// vector, plus a bonus for the query's words; one common word no longer
/// outranks a clear meaning match.
final class ScreenSearchRankingTests: XCTestCase {
    private typealias Ranking = ScreenSearchRanking

    func testAStandoutCaptureClearsTheGateAndTheCrowdDoesNot() {
        var scores = (1...200).map { Ranking.Score(snapshotID: Int64($0), modality: .text,
                                                   cosine: 0.58 + Float($0 % 7) * 0.002) }
        scores.append(.init(snapshotID: 999, modality: .text, cosine: 0.74))
        let meaning = Ranking.meaning(scores)

        XCTAssertGreaterThanOrEqual(meaning[999]?.z ?? 0, Ranking.zGate)
        XCTAssertEqual(meaning.filter { $0.value.z >= Ranking.zGate }.map(\.key), [999])
    }

    func testPicturesAreScoredOnTheirOwnScale() {
        // Text vectors score higher than picture vectors for the same topic; a
        // picture that stands out among pictures must still win.
        var scores = (1...100).map { Ranking.Score(snapshotID: Int64($0), modality: .text,
                                                   cosine: 0.70 + Float($0 % 5) * 0.003) }
        scores += (101...200).map { Ranking.Score(snapshotID: Int64($0), modality: .image,
                                                  cosine: 0.58 + Float($0 % 5) * 0.003) }
        scores.append(.init(snapshotID: 300, modality: .image, cosine: 0.68))
        let meaning = Ranking.meaning(scores)

        let best = meaning.max { $0.value.z < $1.value.z }
        XCTAssertEqual(best?.key, 300, "0.68 is low for text but far above the other pictures")
        XCTAssertEqual(best?.value.modality, .image)
        XCTAssertGreaterThanOrEqual(best?.value.z ?? 0, Ranking.zGate)
    }

    func testACaptureKeepsItsBestVector() {
        let scores = (1...40).flatMap { id -> [Ranking.Score] in
            [.init(snapshotID: Int64(id), modality: .text, cosine: 0.60),
             .init(snapshotID: Int64(id), modality: .image, cosine: id == 7 ? 0.80 : 0.60)]
        }
        let meaning = Ranking.meaning(scores)
        XCTAssertEqual(meaning.count, 40)
        XCTAssertEqual(meaning[7]?.modality, .image)
        XCTAssertEqual(meaning[7]?.cosine, 0.80)
    }

    func testOneCommonWordNoLongerBuriesAMeaningMatch() {
        // The OR fallback found five captures sharing one of three words; a
        // sixth capture stands out by meaning alone. Fusion put the keyword
        // rows first; this ranking puts the meaning match first.
        let meanings: [Int64: Ranking.Meaning] = [
            10: .init(z: 3.4, cosine: 0.71, modality: .image),
            1: .init(z: 0.4, cosine: 0.60, modality: .text),
        ]
        let keyword = (1...5).map { (snapshotID: Int64($0), coverage: 1.0 / 3.0) }

        let ranked = Ranking.rank(meanings: meanings, keyword: keyword, lookup: false, limit: 10)

        XCTAssertEqual(ranked.map(\.snapshotID), [10], "captures with one of three words don't qualify")
        XCTAssertTrue(ranked[0].isSemantic)
    }

    func testCapturesWithAllTheWordsStillLead() {
        let meanings: [Int64: Ranking.Meaning] = [
            10: .init(z: 2.1, cosine: 0.69, modality: .text),
            2: .init(z: 1.5, cosine: 0.66, modality: .text),
        ]
        let keyword: [(snapshotID: Int64, coverage: Double)] = [(2, 1), (3, 1), (4, 0.5)]

        let ranked = Ranking.rank(meanings: meanings, keyword: keyword, lookup: false, limit: 10)

        XCTAssertEqual(ranked.map(\.snapshotID), [2, 10, 3, 4])
        XCTAssertFalse(ranked[0].isSemantic)
        XCTAssertEqual(ranked[0].keywordRank, 1)
    }

    func testALookupWeighsItsWordsOverMeaning() {
        // DigUp splits "INV-2041" into "inv" and "2041"; a code written as one word is a lookup.
        XCTAssertTrue(Ranking.isLookup(Ranking.terms("INV2041")))
        XCTAssertTrue(Ranking.isLookup(Ranking.terms("2041")))
        XCTAssertFalse(Ranking.isLookup(Ranking.terms("payment declined error")))
        let meanings: [Int64: Ranking.Meaning] = [9: .init(z: 4.5, cosine: 0.75, modality: .image)]

        let ranked = Ranking.rank(meanings: meanings, keyword: [(snapshotID: 1, coverage: 1)],
                                  lookup: true, limit: 10)

        XCTAssertEqual(ranked.map(\.snapshotID), [1, 9])
    }

    func testCoverageCountsWordsAndTheirLongerForms() {
        let terms = Ranking.terms("deploy failed staging")
        XCTAssertEqual(Ranking.coverage(of: terms, in: ["Deployment FAILED on prod"]), 2.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(Ranking.coverage(of: terms, in: ["nothing here", "staging deploy failed"]), 1)
        XCTAssertEqual(Ranking.coverage(of: [], in: ["anything"]), 0)
        XCTAssertEqual(Ranking.coverage(of: Ranking.terms("café"), in: ["Cafe menu"]), 1,
                       "diacritics don't matter")
    }

    func testTiesAreDeterministic() {
        let keyword: [(snapshotID: Int64, coverage: Double)] = [(5, 1), (4, 1)]
        let first = Ranking.rank(meanings: [:], keyword: keyword, lookup: false, limit: 10)
        let second = Ranking.rank(meanings: [:], keyword: keyword, lookup: false, limit: 10)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.map(\.snapshotID), [5, 4], "equal scores keep keyword order")
        XCTAssertTrue(Ranking.rank(meanings: [:], keyword: keyword, lookup: false, limit: 0).isEmpty)
        XCTAssertTrue(Ranking.meaning([]).isEmpty)
    }
}
