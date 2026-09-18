import SwiftUI

/// A selectable Markdown renderer backed by one SwiftUI `Text`. Keeping the
/// whole document in one attributed string gives macOS one continuous
/// selection range, so users can drag across lines and copy only the portion
/// they need. Editorial mode preserves Ask's compact type hierarchy and
/// citation treatment without splitting the answer into selection islands.
struct SelectableDigestText: View {
    enum Style: Equatable {
        case standard
        case editorial
        case agent
    }

    let text: String
    var font: Font = .body
    var searchQuery: String = ""
    var activeMatchIndex: Int?
    var style: Style = .standard

    init(
        _ text: String,
        font: Font = .body,
        searchQuery: String = "",
        activeMatchIndex: Int? = nil,
        style: Style = .standard
    ) {
        self.text = text
        self.font = font
        self.searchQuery = searchQuery
        self.activeMatchIndex = activeMatchIndex
        self.style = style
    }

    var body: some View {
        Text(Self.attributedText(
            from: text,
            font: font,
            searchQuery: searchQuery,
            activeMatchIndex: activeMatchIndex,
            style: style))
            .lineSpacing(lineSpacing)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            .help("Select any part and press ⌘C to copy")
    }

    private var lineSpacing: CGFloat {
        switch style {
        case .editorial: return 4
        case .agent: return 2
        case .standard: return 0
        }
    }

    static func attributedText(
        from markdown: String,
        font: Font = .body,
        searchQuery: String = "",
        activeMatchIndex: Int? = nil,
        style: Style = .standard
    ) -> AttributedString {
        let lines = markdown.components(separatedBy: "\n")
        var renderedLines: [AttributedString] = []
        renderedLines.reserveCapacity(lines.count)

        var fence: Fence?
        for line in lines {
            if let activeFence = fence {
                if let delimiter = fenceDelimiter(in: line),
                   delimiter.marker == activeFence.marker,
                   delimiter.length >= activeFence.length,
                   delimiter.info.isEmpty {
                    fence = nil
                } else {
                    renderedLines.append(styledCode(
                        line,
                        font: baseFont(for: style, fallback: font)))
                }
                continue
            }

            if let delimiter = fenceDelimiter(in: line) {
                fence = Fence(marker: delimiter.marker, length: delimiter.length)
                continue
            }

            renderedLines.append(attributedLine(line, font: font, style: style))
        }

        var document = AttributedString()
        for (index, line) in renderedLines.enumerated() {
            document.append(line)
            if index < renderedLines.count - 1 {
                document.append(AttributedString("\n"))
            }
        }
        return MeetingSearchHighlighting.apply(
            to: document,
            query: searchQuery,
            activeMatchIndex: activeMatchIndex)
    }

    static func searchableText(from markdown: String) -> String {
        String(attributedText(from: markdown).characters)
    }

    private static func attributedLine(
        _ line: String,
        font: Font,
        style: Style
    ) -> AttributedString {
        let leading = line.prefix(while: { $0 == " " || $0 == "\t" })
        let content = String(line.dropFirst(leading.count))
        let trimmed = content.trimmingCharacters(in: .whitespaces)
        let baseFont = baseFont(for: style, fallback: font)
        let listIndent = String(repeating: " ", count: min(indentationColumns(leading), 24))
        if trimmed.isEmpty { return AttributedString() }
        if trimmed == "---" || trimmed == "***" || trimmed == "___" {
            return styled("────────────────────", font: baseFont,
                          foreground: .secondary)
        }
        if let heading = heading(trimmed) {
            let headingFont = headingFont(for: heading.level, style: style)
            return styledInline(
                heading.text,
                font: headingFont,
                style: style)
        }
        if let checkbox = checkboxItem(trimmed) {
            return prefixed(listIndent + (checkbox.checked ? "☑ " : "☐ "),
                            content: checkbox.text,
                            font: baseFont,
                            style: style)
        }
        if let bullet = bulletItem(trimmed) {
            return prefixed(
                listIndent + "• ",
                content: bullet,
                font: baseFont,
                style: style)
        }
        if let ordered = orderedListItem(trimmed) {
            return prefixed(
                listIndent + "\(ordered.number). ",
                content: ordered.rest,
                font: baseFont,
                style: style)
        }
        if trimmed.hasPrefix("> ") {
            return prefixed(listIndent + "▎ ", content: String(trimmed.dropFirst(2)),
                            font: baseFont.italic(),
                            foreground: .secondary,
                            style: style)
        }
        return styledInline(trimmed, font: baseFont, style: style)
    }

    private struct Heading {
        let level: Int
        let text: String
    }

    private struct Fence {
        let marker: Character
        let length: Int
    }

    private struct FenceDelimiter {
        let marker: Character
        let length: Int
        let info: String
    }

    private static func baseFont(for style: Style, fallback: Font) -> Font {
        switch style {
        case .editorial: return WorkspaceTypography.body
        case .agent: return WorkspaceTypography.body
        case .standard: return fallback
        }
    }

    private static func headingFont(for level: Int, style: Style) -> Font {
        switch style {
        case .editorial, .agent:
            switch level {
            case 1: return WorkspaceTypography.conversationTitle
            case 2: return WorkspaceTypography.sectionTitle
            default: return WorkspaceTypography.bodyEmphasis
            }
        case .standard:
            switch level {
            case 1: return Font.title2.bold()
            case 2: return Font.title3.bold()
            default: return Font.headline
            }
        }
    }

    private static func heading(_ line: String) -> Heading? {
        let hashes = line.prefix(while: { $0 == "#" })
        let level = hashes.count
        guard (1...6).contains(level),
              line.dropFirst(level).first == " " else { return nil }
        return Heading(level: level,
                       text: String(line.dropFirst(level + 1)))
    }

    private static func checkboxItem(_ line: String) -> (checked: Bool, text: String)? {
        for marker in ["-", "*", "+"] {
            let unchecked = "\(marker) [ ] "
            let checked = "\(marker) [x] "
            let checkedUppercase = "\(marker) [X] "
            if line.hasPrefix(unchecked) {
                return (false, String(line.dropFirst(unchecked.count)))
            }
            if line.hasPrefix(checked) {
                return (true, String(line.dropFirst(checked.count)))
            }
            if line.hasPrefix(checkedUppercase) {
                return (true, String(line.dropFirst(checkedUppercase.count)))
            }
        }
        return nil
    }

    private static func bulletItem(_ line: String) -> String? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count))
        }
        return nil
    }

    private static func indentationColumns(_ leading: Substring) -> Int {
        leading.reduce(into: 0) { columns, character in
            columns += character == "\t" ? 4 : 1
        }
    }

    private static func fenceDelimiter(in line: String) -> FenceDelimiter? {
        let leading = line.prefix(while: { $0 == " " || $0 == "\t" })
        guard leading.count <= 3 else { return nil }
        let content = String(line.dropFirst(leading.count))
        guard let marker = content.first, marker == "`" || marker == "~" else {
            return nil
        }
        let length = content.prefix(while: { $0 == marker }).count
        guard length >= 3 else { return nil }
        return FenceDelimiter(
            marker: marker,
            length: length,
            info: String(content.dropFirst(length)).trimmingCharacters(in: .whitespaces))
    }

    private static func styledCode(_ source: String, font: Font) -> AttributedString {
        var result = AttributedString(source)
        result.font = font.monospaced()
        result.backgroundColor = Color.secondary.opacity(0.12)
        return result
    }

    private static func prefixed(_ prefix: String, content: String,
                                 font: Font = .body,
                                 foreground: Color? = nil,
                                 style: Style) -> AttributedString {
        var result = styled(prefix, font: font, foreground: foreground)
        result.append(styledInline(
            content,
            font: font,
            foreground: foreground,
            style: style))
        return result
    }

    private static func styledInline(_ source: String, font: Font,
                                     foreground: Color? = nil,
                                     style: Style) -> AttributedString {
        var result = (try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(source)
        result.font = font
        if let foreground { result.foregroundColor = foreground }
        if style == .editorial { styleNumericCitations(in: &result) }
        return result
    }

    private static func styleNumericCitations(in attributedText: inout AttributedString) {
        let plainText = String(attributedText.characters)
        var searchStart = plainText.startIndex

        while searchStart < plainText.endIndex,
              let open = plainText[searchStart...].firstIndex(of: "[") {
            let afterOpen = plainText.index(after: open)
            guard let close = plainText[afterOpen...].firstIndex(of: "]") else { break }
            let digits = plainText[afterOpen..<close]
            let afterClose = plainText.index(after: close)

            if !digits.isEmpty,
               digits.allSatisfy(\.isNumber),
               let lowerBound = AttributedString.Index(open, within: attributedText),
               let upperBound = AttributedString.Index(afterClose, within: attributedText) {
                attributedText[lowerBound..<upperBound].font = WorkspaceTypography.metadataEmphasis
                attributedText[lowerBound..<upperBound].foregroundColor = Brand.teal
            }

            searchStart = afterClose
        }
    }

    private static func styled(_ source: String, font: Font,
                               foreground: Color? = nil) -> AttributedString {
        var result = AttributedString(source)
        result.font = font
        if let foreground { result.foregroundColor = foreground }
        return result
    }

    private static func orderedListItem(_ trimmed: String) -> (number: Int, rest: String)? {
        guard let dot = trimmed.firstIndex(of: "."),
              trimmed[..<dot].allSatisfy(\.isNumber),
              let number = Int(trimmed[..<dot]),
              trimmed.index(after: dot) < trimmed.endIndex,
              trimmed[trimmed.index(after: dot)] == " " else { return nil }
        return (number, String(trimmed[trimmed.index(dot, offsetBy: 2)...]))
    }
}

/// Plain transcript text with the same find highlighting used by summary
/// Markdown. Attributes preserve text selection and accessibility value.
struct SearchHighlightedText: View {
    let text: String
    let query: String
    let activeMatchIndex: Int?

    init(_ text: String, query: String, activeMatchIndex: Int? = nil) {
        self.text = text
        self.query = query
        self.activeMatchIndex = activeMatchIndex
    }

    var body: some View {
        Text(MeetingSearchHighlighting.apply(
            to: AttributedString(text),
            query: query,
            activeMatchIndex: activeMatchIndex))
    }
}

private enum MeetingSearchHighlighting {
    static func apply(
        to attributedText: AttributedString,
        query: String,
        activeMatchIndex: Int?
    ) -> AttributedString {
        var result = attributedText
        let plainText = String(result.characters)
        for (index, range) in MeetingPageSearch.ranges(
            in: plainText,
            query: query).enumerated() {
            guard let lowerBound = AttributedString.Index(range.lowerBound, within: result),
                  let upperBound = AttributedString.Index(range.upperBound, within: result) else {
                continue
            }
            result[lowerBound..<upperBound].backgroundColor = index == activeMatchIndex
                ? Color.orange.opacity(0.58)
                : Color.yellow.opacity(0.34)
        }
        return result
    }
}

/// Compatibility wrapper for older call sites. All Markdown now goes through
/// the same continuous AttributedString renderer so selection and supported
/// syntax do not drift between surfaces.
struct MarkdownText: View {
    enum Style {
        case standard
        case editorial
    }

    let text: String
    let style: Style

    init(_ text: String, style: Style = .standard) {
        self.text = text
        self.style = style
    }

    var body: some View {
        SelectableDigestText(
            text,
            style: style == .editorial ? .editorial : .standard)
    }
}
