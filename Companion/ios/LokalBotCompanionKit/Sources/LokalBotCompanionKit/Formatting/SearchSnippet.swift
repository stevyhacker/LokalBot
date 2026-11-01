import Foundation

/// A search snippet split into plain text and matched words. The sync core's
/// full-text search marks matches with `«` and `»`; without markers the
/// searched terms themselves are matched.
public enum SearchSnippet {
    public struct Part: Equatable, Sendable {
        public var text: String
        public var isMatch: Bool
    }

    public static func parts(_ snippet: String, query: String = "") -> [Part] {
        if snippet.contains("«") {
            var parts: [Part] = []
            var rest = Substring(snippet)
            while let open = rest.firstIndex(of: "«") {
                if open > rest.startIndex { parts.append(Part(text: String(rest[..<open]), isMatch: false)) }
                let afterOpen = rest.index(after: open)
                guard let close = rest[afterOpen...].firstIndex(of: "»") else {
                    rest = rest[afterOpen...]
                    break
                }
                parts.append(Part(text: String(rest[afterOpen..<close]), isMatch: true))
                rest = rest[rest.index(after: close)...]
            }
            if !rest.isEmpty { parts.append(Part(text: String(rest), isMatch: false)) }
            return parts
        }
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return [Part(text: snippet, isMatch: false)] }
        var parts: [Part] = []
        var cursor = snippet.startIndex
        while cursor < snippet.endIndex {
            let match = terms.compactMap {
                snippet.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive], range: cursor..<snippet.endIndex)
            }.min { $0.lowerBound < $1.lowerBound }
            guard let match else { break }
            if match.lowerBound > cursor { parts.append(Part(text: String(snippet[cursor..<match.lowerBound]), isMatch: false)) }
            parts.append(Part(text: String(snippet[match]), isMatch: true))
            cursor = match.upperBound
        }
        if cursor < snippet.endIndex { parts.append(Part(text: String(snippet[cursor...]), isMatch: false)) }
        return parts
    }
}
