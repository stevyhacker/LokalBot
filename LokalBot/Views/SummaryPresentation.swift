import SwiftUI

/// The pipeline writes a bold inline provenance line under the summary title
/// ("**Duration:** 32m · **App:** Zoom · … · **Model:** …"). Rendered as body
/// markdown it reads like debug output. These helpers lift that line out so
/// views can show it as a quiet metadata row while the raw `summary.md`
/// (exports, CLI, MCP) keeps the full header.
enum SummaryPresentation {
    struct MetadataItem: Equatable {
        let label: String
        let value: String
    }

    struct Parts: Equatable {
        var metadata: [MetadataItem]
        var body: String
    }

    /// Extracts the provenance line: the first non-empty, non-heading line
    /// among the leading lines, consisting of at least two `**Label:** value`
    /// pairs joined by "·". Requiring two pairs keeps a body that opens with
    /// ordinary bold text ("**Next steps:** …") intact.
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
            // Older merge drafts start with implementation details instead of
            // meeting content. They remain available in the saved Markdown.
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

    /// Extract a reading preview without changing the stored/exported Markdown.
    /// Headings may share a paragraph with their content in older summaries.
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

    /// The recap is reading copy. Speaker attribution and playback citations
    /// remain in Full Summary and the transcript, not in this compact preview.
    private static func recapText(_ section: String) -> String? {
        let text = section.components(separatedBy: "\n").map { line in
            line
                .replacingOccurrences(of: #"^\s*[-*•]\s+(?:\*\*[^*\n]+:\*\*\s*)?"#,
                                      with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\s*[—–-]\s*\[\d{1,2}:\d{2}(?::\d{2})?\]\s*$"#,
                                      with: "", options: .regularExpression)
        }.joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
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

/// State belongs to the selected meeting's view, so every meeting opens compact.
struct MeetingRecapView: View {
    let text: String
    @State private var isExpanded = false
    @State private var fullHeight: CGFloat = 0
    @State private var collapsedHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SelectableDigestText(text, font: WorkspaceTypography.body)
                .lineLimit(isExpanded ? nil : 3)
                .truncationMode(.tail)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    if !isExpanded { collapsedHeight = height }
                }
                .background(alignment: .topLeading) {
                    SelectableDigestText(text, font: WorkspaceTypography.body)
                        .fixedSize(horizontal: false, vertical: true)
                        .hidden()
                        .accessibilityHidden(true)
                        .allowsHitTesting(false)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                            fullHeight = $0
                        }
                }
                .accessibilityIdentifier("meeting.recap.text")
            if isExpanded || fullHeight > collapsedHeight + 1 {
                Button {
                    isExpanded.toggle()
                } label: {
                    Label(isExpanded ? "Show less" : "Show more",
                          systemImage: isExpanded ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.plain)
                .font(WorkspaceTypography.metadataEmphasis)
                .foregroundStyle(Brand.teal)
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
                .accessibilityIdentifier("meeting.recap.expand")
            }
        }
    }
}

/// One quiet, wrapping metadata line for a generated summary's provenance.
struct SummaryMetadataRow: View {
    let items: [SummaryPresentation.MetadataItem]
    var searchQuery = ""
    var activeMatchIndex: Int?

    var body: some View {
        SearchHighlightedText(
            Self.displayText(for: items),
            query: searchQuery,
            activeMatchIndex: activeMatchIndex)
            .font(WorkspaceTypography.metadata)
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
