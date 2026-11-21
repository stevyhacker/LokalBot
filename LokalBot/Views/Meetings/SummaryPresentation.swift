import SwiftUI

enum SummaryPresentation {
    struct MetadataItem: Equatable {
        let label: String
        let value: String
    }

    struct Parts: Equatable {
        var metadata: [MetadataItem]
        var body: String
    }

    static func split(_ markdown: String) -> Parts {
        var lines = markdown.components(separatedBy: "\n")
        for (index, line) in lines.enumerated().prefix(4) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if trimmed.hasPrefix("#") { continue }
            guard let items = parseMetadataLine(trimmed), items.count >= 2 else { break }
            lines.remove(at: index)
            return Parts(
                metadata: items.filter {
                    $0.label != "Sources" && !($0.label == "App" && $0.value == "Merged meetings")
                },
                body: lines.joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return Parts(metadata: [], body: markdown)
    }

    static func meetingBody(_ markdown: String, meeting: Meeting) -> String {
        guard meeting.isMergedMeeting else { return markdown }
        return markdown.components(separatedBy: "\n").enumerated().compactMap { index, line in
            if line.hasPrefix("This is a non-destructive merge. Source evidence remains on disk for provenance,") {
                return nil
            }
            let heading = "# \(meeting.title)"
            if index == 0, line == heading || line.hasPrefix(heading + " — ") {
                return "# \(meeting.displayTitle)" + line.dropFirst(heading.count)
            }
            return line
        }.joined(separator: "\n")
    }

    static func recap(_ markdown: String) -> String? {
        let body = split(markdown).body
        let lines = body.components(separatedBy: "\n")
        if let heading = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).lowercased() == "## tl;dr" }) {
            let section = lines.dropFirst(heading + 1).prefix { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
                .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !section.isEmpty && section.lowercased() != "none" { return recapText(section) }
        }
        return body.components(separatedBy: "\n\n").lazy.compactMap { paragraph -> String? in
            let content = paragraph.components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
                .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty, content.lowercased() != "none",
                  !content.hasPrefix("- "), !content.hasPrefix("* "), !content.hasPrefix("|") else { return nil }
            return recapText(content)
        }.first
    }

    private static func recapText(_ section: String) -> String? {
        let text = section.components(separatedBy: "\n").map { line in
            line
                .replacingOccurrences(of: #"^\s*[-*•]\s+(?:\*\*[^*\n]+:\*\*\s*)?"#,
                                      with: "• ", options: .regularExpression)
                .replacingOccurrences(of: #"\s*[—–-]\s*\[\d{1,2}:\d{2}(?::\d{2})?\]\s*$"#,
                                      with: "", options: .regularExpression)
        }.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func parseMetadataLine(_ line: String) -> [MetadataItem]? {
        var items: [MetadataItem] = []
        for piece in line.components(separatedBy: " · ") {
            let trimmed = piece.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("**"),
                  let labelEnd = trimmed.range(of: ":**") else { return nil }
            let label = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)..<labelEnd.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[labelEnd.upperBound...])
                .trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty, !value.isEmpty else { return nil }
            items.append(MetadataItem(label: label, value: value))
        }
        return items.isEmpty ? nil : items
    }
}

struct MeetingRecapView: View {
    let text: String
    var font: AppFont = .scaledSystem(size: 15)
    @State private var isExpanded = false

    private var points: [String] {
        text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array((isExpanded ? points : Array(points.prefix(5))).enumerated()), id: \.offset) { _, point in
                pointText(point)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("meeting.recap.text")
            }
            if points.count > 5 {
                Button(isExpanded ? "Show Less" : "Show \(points.count - 5) More Points") { isExpanded.toggle() }
                    .buttonStyle(.plain)
                    .font(AppFont.scaled(.callout).weight(.semibold))
                    .foregroundStyle(Brand.teal)
                    .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
                    .accessibilityIdentifier("meeting.recap.expand")
            }
        }
    }

    private func pointText(_ point: String) -> SelectableDigestText {
        var text = SelectableDigestText(point, font: font)
        text.readingLineSpacing = 3
        return text
    }
}

struct SummaryMetadataRow: View {
    let items: [SummaryPresentation.MetadataItem]
    var searchQuery = ""
    var activeMatchIndex: Int?

    var body: some View {
        SearchHighlightedText(
            Self.displayText(for: items),
            query: searchQuery,
            activeMatchIndex: activeMatchIndex)
            .font(AppFont.scaled(.callout))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("summary.metadata")
    }

    static func displayText(
        for items: [SummaryPresentation.MetadataItem]
    ) -> String {
        items.map { "\($0.label) \($0.value)" }.joined(separator: "  ·  ")
    }
}
