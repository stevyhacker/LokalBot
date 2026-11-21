import Foundation

enum ScreenSearch {
    static let fullTextLimit = 100

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

    static func ranked(
        query: String,
        keyword: [ActivityStore.OCRHit],
        coverage: [Int64: Double],
        meanings: [Int64: EmbeddingIndex.ScreenMeaningMatch],
        limit: Int,
        screenshots: ([Int64]) -> [Int64: ActivityStore.Screenshot],
        texts: ([Int64]) -> [Int64: String]
    ) -> [ActivityStore.OCRHit] {
        let terms = ScreenSearchRanking.terms(query)
        var keywordByID: [Int64: ActivityStore.OCRHit] = [:]
        for hit in keyword where keywordByID[hit.snapshotID] == nil { keywordByID[hit.snapshotID] = hit }
        let ranked = ScreenSearchRanking.rank(
            meanings: meanings.mapValues(\.meaning),
            keyword: keyword.map { (snapshotID: $0.snapshotID, coverage: coverage[$0.snapshotID] ?? 0) },
            lookup: ScreenSearchRanking.isLookup(terms),
            limit: limit)
        let meaningOnly = ranked.compactMap { item in
            keywordByID[item.snapshotID] == nil && meanings[item.snapshotID] != nil ? item.snapshotID : nil
        }
        let shots = screenshots(meaningOnly)
        let passages = texts(meaningOnly)
        return ranked.compactMap { item in
            if var hit = keywordByID[item.snapshotID] {
                hit.isSemantic = item.isSemantic
                return hit
            }
            guard meanings[item.snapshotID] != nil, let shot = shots[item.snapshotID] else { return nil }
            let title = shot.windowTitle.isEmpty ? shot.app : shot.windowTitle
            var hit = ActivityStore.OCRHit(
                snapshotID: shot.id, ts: shot.ts, app: shot.app, windowTitle: shot.windowTitle,
                snippet: passages[item.snapshotID].flatMap { RecallPassage.excerpt($0, query: query) } ?? title)
            hit.isSemantic = true
            return hit
        }
    }
}
