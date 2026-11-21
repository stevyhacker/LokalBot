import DigUpKit
import Foundation

enum ScreenSearchRanking {
    enum Modality: Hashable, Sendable, CaseIterable {
        case text
        case image
    }

    struct Score: Sendable {
        let snapshotID: Int64
        let modality: Modality
        let cosine: Float
    }

    struct Meaning: Equatable, Sendable {
        let z: Double
        let cosine: Float
        let modality: Modality
    }

    struct Ranked: Equatable, Sendable, Identifiable {
        let snapshotID: Int64
        let score: Double
        let meaning: Meaning?
        let coverage: Double
        let keywordRank: Int?

        var id: Int64 { snapshotID }
        var isSemantic: Bool { keywordRank == nil || coverage < 0.5 }
    }

    static let zGate = 2.0
    static let wordWeight = 2.0
    private static let minimumDeviation = 0.02
    private static let modalityMinimumCount = 20

    static func meaning(_ scores: [Score]) -> [Int64: Meaning] {
        guard !scores.isEmpty else { return [:] }
        var sum: [Modality: Double] = [:], count: [Modality: Int] = [:]
        for score in scores {
            sum[score.modality, default: 0] += Double(score.cosine)
            count[score.modality, default: 0] += 1
        }
        let overall = sum.values.reduce(0, +) / Double(max(count.values.reduce(0, +), 1))
        var means: [Modality: Double] = [:]
        for modality in Modality.allCases {
            if let n = count[modality], n >= modalityMinimumCount, let total = sum[modality] {
                means[modality] = total / Double(n)
            } else {
                means[modality] = overall
            }
        }
        let centered = scores.map { Double($0.cosine) - means[$0.modality, default: overall] }
        let mean = centered.reduce(0, +) / Double(centered.count)
        let variance = centered.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(centered.count)
        let deviation = max(variance.squareRoot(), minimumDeviation)
        var best: [Int64: Meaning] = [:]
        for (score, value) in zip(scores, centered) {
            let z = (value - mean) / deviation
            if z > (best[score.snapshotID]?.z ?? -.infinity) {
                best[score.snapshotID] = Meaning(z: z, cosine: score.cosine, modality: score.modality)
            }
        }
        return best
    }

    static func terms(_ query: String) -> [String] {
        Searcher.terms(query)
    }

    static func isLookup(_ terms: [String]) -> Bool {
        !terms.isEmpty && terms.allSatisfy {
            $0.contains(where: \.isNumber) && ($0.contains(where: \.isLetter) || $0.count >= 4)
        }
    }

    static func coverage(of terms: [String], in texts: [String]) -> Double {
        guard !terms.isEmpty else { return 0 }
        let words = Set(texts.flatMap { text in
            folded(text).components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        })
        let found = terms.map(folded).filter { term in words.contains { $0.hasPrefix(term) } }
        return Double(found.count) / Double(terms.count)
    }

    private static func folded(_ text: String) -> String {
        SearchText.normalized(text).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    static func rank(
        meanings: [Int64: Meaning],
        keyword: [(snapshotID: Int64, coverage: Double)],
        lookup: Bool,
        limit: Int
    ) -> [Ranked] {
        guard limit > 0 else { return [] }
        let (meaningWeight, wordsWeight) = lookup ? (0.5, wordWeight * 2) : (1.0, wordWeight)
        var keywordRank: [Int64: Int] = [:]
        var coverage: [Int64: Double] = [:]
        for (offset, hit) in keyword.enumerated() where keywordRank[hit.snapshotID] == nil {
            keywordRank[hit.snapshotID] = offset + 1
            coverage[hit.snapshotID] = hit.coverage
        }
        var candidates = Set(meanings.filter { $0.value.z >= zGate }.keys)
        for (id, share) in coverage where share >= 0.5 { candidates.insert(id) }
        let ranked = candidates.map { id -> Ranked in
            let meaning = meanings[id]
            let share = coverage[id] ?? 0
            let score = meaningWeight * max(meaning?.z ?? 0, 0) + wordsWeight * pow(share, 1.5)
            return Ranked(snapshotID: id, score: score, meaning: meaning, coverage: share,
                          keywordRank: keywordRank[id])
        }
        return ranked.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if (lhs.coverage >= 0.5) != (rhs.coverage >= 0.5) { return lhs.coverage >= 0.5 }
            let left = lhs.keywordRank ?? .max, right = rhs.keywordRank ?? .max
            if left != right { return left < right }
            return lhs.snapshotID > rhs.snapshotID
        }
        .prefix(limit)
        .map { $0 }
    }
}
