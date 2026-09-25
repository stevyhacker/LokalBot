import Foundation

enum LibraryInputPolicy {
    static let maximumMeetingCount = 1_000
    static let maximumSearchHits = 500
    static let maximumQueryCharacters = 4_096
    static let maximumQuestionCharacters = 16_384
}

/// Shared substring search over on-disk meeting artifacts. Case-insensitive,
/// recency-ordered, and capped so the CLI and MCP expose one behavior.
enum LibrarySearch {
    static let defaultLimit = 50

    static func hits(
        query: String,
        limit: Int = defaultLimit,
        meetings: [Meeting]? = nil
    ) throws -> [SessionFormatter.SearchHit] {
        let needle = query.lowercased()
        let all = try meetings ?? SessionLookup.loadAllMeetings()

        var hits: [SessionFormatter.SearchHit] = []
        for meeting in all {
            let short = SessionLookup.shortID(meeting.id)
            if meeting.title.lowercased().contains(needle) {
                hits.append(.init(
                    meeting_id: short,
                    meeting_title: meeting.title,
                    match_kind: "title",
                    snippet: meeting.title,
                    timestamp: nil))
            }
            if let summary = SessionLookup.summaryMarkdown(for: meeting),
               let snippet = snippet(in: summary, around: needle) {
                hits.append(.init(
                    meeting_id: short,
                    meeting_title: meeting.title,
                    match_kind: "summary",
                    snippet: snippet,
                    timestamp: nil))
            }
            if let transcript = SessionLookup.transcript(for: meeting) {
                for segment in transcript.segments where segment.text.lowercased().contains(needle) {
                    hits.append(.init(
                        meeting_id: short,
                        meeting_title: meeting.title,
                        match_kind: "transcript",
                        snippet: segment.text,
                        timestamp: Transcript.stamp(segment.start)))
                    if hits.count >= limit { break }
                }
            }
            if hits.count >= limit { break }
        }
        return Array(hits.prefix(limit))
    }

    static func snippet(in haystack: String, around needle: String) -> String? {
        guard let range = haystack.range(of: needle, options: .caseInsensitive) else { return nil }
        let start = haystack.index(
            range.lowerBound,
            offsetBy: -40,
            limitedBy: haystack.startIndex) ?? haystack.startIndex
        let end = haystack.index(
            range.upperBound,
            offsetBy: 40,
            limitedBy: haystack.endIndex) ?? haystack.endIndex
        var snippet = String(haystack[start..<end])
        if start != haystack.startIndex { snippet = "…" + snippet }
        if end != haystack.endIndex { snippet += "…" }
        return snippet
    }
}
