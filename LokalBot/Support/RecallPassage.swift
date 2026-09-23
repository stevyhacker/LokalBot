import Foundation

/// Reading excerpts only; stored transcripts, summaries and export text remain lossless.
enum RecallPassage {
    static func excerpt(_ source: String, query: String, limit: Int = 320) -> String? {
        let lines = source.components(separatedBy: "\n").compactMap { line -> String? in
            let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
            // Generated provenance is never useful as a search passage.
            if line.contains("**Duration:**") && line.contains("**Model:**") { return nil }
            if line.range(of: #"^#{1,6}\s"#, options: .regularExpression) != nil || line.hasPrefix("```") { return nil }
            let cleaned = line
                .replacingOccurrences(of: #"^\s*(?:#{1,6}\s+|[-*•]\s+(?:\[[ xX]\]\s*)?|\d+\.\s+)"#,
                                      with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\[([^\]]+)\]\([^\)]+\)"#, with: "$1", options: .regularExpression)
                .replacingOccurrences(of: #"[*`]+"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"(?<!\w)_([^_]+)_(?!\w)"#, with: "$1", options: .regularExpression)
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return isUseful(cleaned) ? cleaned : nil
        }
        guard !lines.isEmpty else { return nil }
        let terms = tokens(query).filter { !SearchIndex.stopWords.contains($0) }
        // Prefer the line containing query terms, rather than the beginning of a summary.
        let ranked = lines.enumerated().max { lhs, rhs in
            let left = score(lhs.element, terms: terms), right = score(rhs.element, terms: terms)
            return left == right ? lhs.offset > rhs.offset : left < right
        }
        guard let selected = ranked?.element else { return nil }
        let target = selected.range(of: "«") ?? terms.compactMap {
            selected.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive])
        }.first
        let center = target.map { selected.distance(from: selected.startIndex, to: $0.lowerBound) } ?? 0
        var start = selected.index(selected.startIndex, offsetBy: max(0, center - 90))
        if start > selected.startIndex {
            while start < selected.endIndex, !selected[start].isWhitespace { start = selected.index(after: start) }
        }
        let end = selected.index(start, offsetBy: limit, limitedBy: selected.endIndex) ?? selected.endIndex
        let excerpt = String(selected[start..<end]).trimmingCharacters(in: .whitespaces)
        return (start > selected.startIndex ? "…" : "") + excerpt + (end < selected.endIndex ? "…" : "")
    }

    static func isUseful(_ text: String) -> Bool {
        let words = tokens(text)
        guard !words.isEmpty else { return false }
        let fillers: Set<String> = ["uh", "um", "hmm", "hm", "ah", "oh", "okay", "ok", "yes", "yeah"]
        guard words.contains(where: { !fillers.contains($0) && $0.count > 1 }) else { return false }
        if words.count >= 6 {
            let counts = Dictionary(words.map { ($0, 1) }, uniquingKeysWith: +)
            if Double(counts.values.max() ?? 0) / Double(words.count) > 0.55 { return false }
            if words.count >= 12, Set(words).count <= 3 { return false }
        }
        return true
    }

    static func queryMatchCount(_ text: String, query: String) -> Int {
        score(text, terms: tokens(query).filter { !SearchIndex.stopWords.contains($0) })
    }

    private static func tokens(_ text: String) -> [String] {
        text.lowercased().components(separatedBy: .alphanumerics.inverted).filter { !$0.isEmpty }
    }

    private static func score(_ text: String, terms: [String]) -> Int {
        (text.contains("«") ? 100 : 0) + terms.filter { text.localizedStandardContains($0) }.count
    }
}
