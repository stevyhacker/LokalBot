import SwiftUI

/// One run of an FTS5 snippet: matched runs render bold/primary.
struct SnippetSegment: Equatable {
    let text: String
    let isMatch: Bool
}

/// Splits an FTS5 snippet on «» match markers into runs. Pure; unit-tested.
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
                // Unmatched « — drop the marker, emit the tail as plain text.
                break
            }
        }
        if !rest.isEmpty {
            result.append(SnippetSegment(text: String(rest), isMatch: false))
        }
        return result
    }
}

/// Screen OCR usually re-captures the window chrome, so an FTS snippet's
/// leading line often just repeats the row title shown directly above it.
/// Drops those echo lines and collapses whitespace; «» markers survive so
/// `SnippetHighlighter` still finds the matches. Pure; unit-tested.
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

    /// Containment counts as an echo only above a length floor; short lines
    /// like an app name must match the title exactly before they're dropped.
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

/// Unified Ask result row (spec §3.2): title · kind chip · highlighted
/// snippet · timestamp — one anatomy for FTS, semantic, and screen hits.
struct ResultRow: View {
    let title: String
    let kind: String
    let snippet: String
    var timestamp: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(title).font(WorkspaceTypography.rowTitle).lineLimit(1)
                if let timestamp {
                    Text(timestamp).workspaceTextRole(.metadata)
                }
                Spacer()
                Text(kind)
                    .workspaceTextRole(.metadata)
                    .monospacedDigit()
                    .chipChrome(.compact)
            }
            highlighted
                .workspaceTextRole(.supporting)
                .lineLimit(3)
        }
        .padding(.vertical, 3)
    }

    private var highlighted: Text {
        SnippetHighlighter.segments(snippet).reduce(Text("")) { acc, seg in
            acc + (seg.isMatch
                   ? Text(seg.text).bold().foregroundStyle(.primary)
                   : Text(seg.text))
        }
    }
}
