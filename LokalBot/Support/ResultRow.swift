import SwiftUI

struct SnippetSegment: Equatable {
    let text: String
    let isMatch: Bool
}

enum SnippetHighlighter {
    static func segments(_ snippet: String) -> [SnippetSegment] {
        var result: [SnippetSegment] = []
        var rest = Substring(snippet)
        while let open = rest.firstIndex(of: "«") {
            if open > rest.startIndex {
                result.append(SnippetSegment(text: String(rest[..<open]), isMatch: false))
            }
            rest = rest[rest.index(after: open)...]
            if let close = rest.firstIndex(of: "»") {
                if close > rest.startIndex {
                    result.append(SnippetSegment(text: String(rest[..<close]), isMatch: true))
                }
                rest = rest[rest.index(after: close)...]
            } else {
                break
            }
        }
        if !rest.isEmpty {
            result.append(SnippetSegment(text: String(rest), isMatch: false))
        }
        return result
    }
}

enum SnippetCleaner {
    static func withoutTitleEcho(_ snippet: String, title: String) -> String? {
        let normalizedTitle = normalize(title)
        var lines = snippet.split(separator: "\n", omittingEmptySubsequences: true)
        if !normalizedTitle.isEmpty {
            while let first = lines.first, echoes(normalize(String(first)), normalizedTitle) {
                lines.removeFirst()
            }
        }
        let joined = lines.joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    private static func echoes(_ line: String, _ title: String) -> Bool {
        if line.isEmpty || line == title { return true }
        guard min(line.count, title.count) >= 12 else { return false }
        return title.contains(line) || line.contains(title)
    }

    private static func normalize(_ text: String) -> String {
        text.replacingOccurrences(of: "«", with: "")
            .replacingOccurrences(of: "»", with: "")
            .replacingOccurrences(of: "…", with: "")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}
