import Foundation

/// Ranked screen search: keyword hits from the screen-text index and meaning
/// matches from text and picture vectors (`EmbeddingIndex.screenMeanings`),
/// ranked together the way DigUp ranks files (`ScreenSearchRanking`). Ask,
/// Quick Recall and the assistant's `search_screen` share it.
enum ScreenSearch {
    /// How many OR-fallback hits get their full text read to count the
    /// query's words; the rest are counted from their snippet and title.
    static let fullTextLimit = 100

    /// The share of the query's words each keyword hit holds. Hits found by
    /// the all-words search hold them all; for the OR fallback the capture's
    /// text is read. A query of only stopwords counts every hit it found.
    static func coverage(query: String, hits: [ActivityStore.OCRHit], matchedAll: Bool,
                         text: (Int64) -> String?) -> [Int64: Double] {
        let terms = ScreenSearchRanking.terms(query)
        var coverage: [Int64: Double] = [:]
        for (index, hit) in hits.enumerated() where coverage[hit.snapshotID] == nil {
            if matchedAll || terms.isEmpty {
                coverage[hit.snapshotID] = matchedAll ? 1 : 0.5
                continue
            }
            let full = index < fullTextLimit ? text(hit.snapshotID) : nil
            coverage[hit.snapshotID] = ScreenSearchRanking.coverage(
                of: terms, in: [full ?? hit.snippet, hit.windowTitle])
        }
        return coverage
    }

    /// Keyword hits and meaning matches as one ranked list. A capture found
    /// only by meaning gets its text's best passage as the snippet, or its
    /// window title when it has no text (a picture-only match), and is marked
    /// `isSemantic`.
    @MainActor
    static func ranked(
        query: String,
        keyword: [ActivityStore.OCRHit],
        coverage: [Int64: Double],
        meanings: [Int64: EmbeddingIndex.ScreenMeaningMatch],
        limit: Int,
        screenshot: (Int64) -> ActivityStore.Screenshot?
    ) -> [ActivityStore.OCRHit] {
        let terms = ScreenSearchRanking.terms(query)
        var keywordByID: [Int64: ActivityStore.OCRHit] = [:]
        for hit in keyword where keywordByID[hit.snapshotID] == nil { keywordByID[hit.snapshotID] = hit }
        let ranked = ScreenSearchRanking.rank(
            meanings: meanings.mapValues(\.meaning),
            keyword: keyword.map { (snapshotID: $0.snapshotID, coverage: coverage[$0.snapshotID] ?? 0) },
            lookup: ScreenSearchRanking.isLookup(terms),
            limit: limit)
        return ranked.compactMap { item in
            if var hit = keywordByID[item.snapshotID] {
                hit.isSemantic = item.isSemantic
                return hit
            }
            guard let match = meanings[item.snapshotID], let shot = screenshot(item.snapshotID) else { return nil }
            let title = shot.windowTitle.isEmpty ? shot.app : shot.windowTitle
            var hit = ActivityStore.OCRHit(
                snapshotID: shot.id, ts: shot.ts, app: shot.app, windowTitle: shot.windowTitle,
                snippet: match.text.flatMap { RecallPassage.excerpt($0, query: query) } ?? title)
            hit.isSemantic = true
            return hit
        }
    }
}
