import DigUpKit
import Foundation

/// Screen search ranking the way DigUp ranks files (`Searcher.search`,
/// github.com/ARahim3/DigUp, MIT): meaning is how far a capture stands out for
/// this query among all stored vectors of its kind, and the query's words add a
/// bonus that grows with how many of them the capture holds.
///
/// It replaces reciprocal-rank fusion. Fusion gave the long OR-fallback keyword
/// list (any one word) the same weight as meaning, and on descriptive queries
/// it pulled the right screen down: 44 of 138 found first against 52 for text
/// meaning alone (Benchmarks/EmbeddingGemma2/2026-10-13-screen-images). Here a
/// capture qualifies by standing out in meaning or by holding at least half of
/// the query's words, so one common word can't outrank a clear meaning match,
/// while all the words of an exact lookup ("INV-2041") usually win.
enum ScreenSearchRanking {
    enum Modality: Hashable, Sendable, CaseIterable {
        /// The capture's text (OCR), embedded as a document.
        case text
        /// The captured picture itself (`ScreenImageEmbeddings`).
        case image
    }

    /// One stored vector's similarity to the query vector.
    struct Score: Sendable {
        let snapshotID: Int64
        let modality: Modality
        let cosine: Float
    }

    /// A capture's best meaning match, on this query's scale.
    struct Meaning: Equatable, Sendable {
        let z: Double
        let cosine: Float
        let modality: Modality
    }

    struct Ranked: Equatable, Sendable, Identifiable {
        let snapshotID: Int64
        let score: Double
        let meaning: Meaning?
        /// Share of the query's words the capture holds, 0…1.
        let coverage: Double
        /// 1-based place in the keyword results, if the words found it.
        let keywordRank: Int?

        var id: Int64 { snapshotID }
        /// Found by meaning alone: the list says so.
        var isSemantic: Bool { keywordRank == nil || coverage < 0.5 }
    }

    /// How far above this query's average a capture must score to count by
    /// meaning: DigUp's gate, which also gives an honest "nothing found".
    static let zGate = 2.0
    static let wordWeight = 2.0
    private static let minimumDeviation = 0.02
    /// Fewer vectors of a kind than this take the average of all kinds.
    private static let modalityMinimumCount = 20

    // MARK: - Meaning

    /// Each capture's best vector on this query's scale. Scores are centred per
    /// kind first, because text scores higher than pictures for the same topic
    /// (DigUp measured 0.75–0.86 against 0.67–0.78), then put on one z scale.
    /// Pass every stored vector, not only those in the date or app scope: the
    /// scale must not depend on the filter.
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

    // MARK: - Words

    /// The query's content words, as DigUp's keyword search sees them:
    /// normalized, with stopwords and kind words ("screenshot") dropped.
    static func terms(_ query: String) -> [String] {
        Searcher.terms(query)
    }

    /// An exact lookup: every word carries digits, like an invoice number or a
    /// version. Words then count for more than meaning (DigUp's `isLookup`).
    static func isLookup(_ terms: [String]) -> Bool {
        !terms.isEmpty && terms.allSatisfy {
            $0.contains(where: \.isNumber) && ($0.contains(where: \.isLetter) || $0.count >= 4)
        }
    }

    /// The share of `terms` that occur in any of `texts`, ignoring case and
    /// diacritics as the screen-text index does. A word matches as the start
    /// of a longer word ("deploy" in "deployment"), as keyword search does.
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

    // MARK: - Ranking

    /// Captures that stand out in meaning (z ≥ `zGate`) or hold at least half
    /// of the query's words, best first. Score: meaning z plus a word bonus
    /// that grows with coverage; for a lookup, words weigh double and meaning
    /// half. Ties go to word matches, then to keyword order, then to the newer
    /// capture.
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
