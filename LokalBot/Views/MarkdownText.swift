import SwiftUI

/// A selectable Markdown renderer backed by one SwiftUI `Text`. Keeping the
/// whole document in one attributed string gives macOS one continuous
/// selection range, so users can drag across lines and copy only the portion
/// they need. It supports headings, lists, quotes, fenced code, and GitHub
/// tables while preserving inline formatting. Editorial mode preserves Ask's
/// compact type hierarchy and citation treatment without splitting the answer
/// into selection islands.
struct SelectableDigestText: View {
    enum Style: Hashable {
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
        case .agent: return 5
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
        let key = RenderKey(markdown: markdown, font: font, style: style)
        if let cached = renderCache.object(forKey: key) {
            return MeetingSearchHighlighting.apply(
                to: cached.value, query: searchQuery, activeMatchIndex: activeMatchIndex)
        }
        let renderedLines = renderedLines(from: markdown, font: font, style: style)

        var document = AttributedString()
        for (index, line) in renderedLines.enumerated() {
            document.append(line.content)
            if index < renderedLines.count - 1 {
                document.append(AttributedString("\n"))
            }
        }
        if markdown.utf8.count <= 512_000 {
            renderCache.setObject(RenderedText(document), forKey: key, cost: markdown.utf8.count * 8)
        }
        return MeetingSearchHighlighting.apply(
            to: document,
            query: searchQuery,
            activeMatchIndex: activeMatchIndex)
    }

    /// Both native Agent text and SwiftUI summaries share exactly one parser.
    struct RenderedLine {
        let content: AttributedString
        let kind: LineKind
    }

    enum LineKind {
        case body, blank, code, table, tableHeader, quote, separator
        case heading(Int)
        case list(String)
    }

    static func renderedLines(from markdown: String, font: Font, style: Style) -> [RenderedLine] {
        let lines = markdown.components(separatedBy: "\n")
        var renderedLines: [RenderedLine] = []
        renderedLines.reserveCapacity(lines.count)

        var fence: Fence?
        var lineIndex = 0
        while lineIndex < lines.count {
            let line = lines[lineIndex]
            if let activeFence = fence {
                if let delimiter = fenceDelimiter(in: line),
                   delimiter.marker == activeFence.marker,
                   delimiter.length >= activeFence.length,
                   delimiter.info.isEmpty {
                    fence = nil
                } else {
                    renderedLines.append(.init(content: styledCode(
                        line, font: baseFont(for: style, fallback: font)), kind: .code))
                }
                lineIndex += 1
                continue
            }

            if let delimiter = fenceDelimiter(in: line) {
                fence = Fence(marker: delimiter.marker, length: delimiter.length)
                lineIndex += 1
                continue
            }

            if let table = table(
                startingAt: lineIndex,
                lines: lines,
                font: font,
                style: style) {
                renderedLines.append(contentsOf: table.lines.enumerated().map {
                    .init(content: $0.element, kind: $0.offset == 0 ? .tableHeader : .table)
                })
                lineIndex = table.nextIndex
                continue
            }

            renderedLines.append(.init(content: attributedLine(line, font: font, style: style), kind: lineKind(line)))
            lineIndex += 1
        }

        return renderedLines
    }

    private static func lineKind(_ line: String) -> LineKind {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let leading = line.prefix(while: { $0 == " " || $0 == "\t" })
        let indent = String(repeating: " ", count: min(indentationColumns(leading), 24))
        if trimmed.isEmpty { return .blank }
        if ["---", "***", "___"].contains(trimmed) { return .separator }
        if let heading = heading(trimmed) { return .heading(heading.level) }
        if let checkbox = checkboxItem(trimmed) { return .list(indent + (checkbox.checked ? "☑ " : "☐ ")) }
        if bulletItem(trimmed) != nil { return .list(indent + "• ") }
        if let ordered = orderedListItem(trimmed) { return .list(indent + "\(ordered.number). ") }
        if trimmed.hasPrefix("> ") { return .quote }
        return .body
    }

    private final class RenderKey: NSObject {
        let markdown: String
        let font: Font
        let style: Style
        init(markdown: String, font: Font, style: Style) {
            self.markdown = markdown; self.font = font; self.style = style
        }
        override var hash: Int {
            var hasher = Hasher()
            hasher.combine(markdown); hasher.combine(font); hasher.combine(style)
            return hasher.finalize()
        }
        override func isEqual(_ object: Any?) -> Bool {
            guard let other = object as? RenderKey else { return false }
            return markdown == other.markdown && font == other.font && style == other.style
        }
    }

    private final class RenderedText {
        let value: AttributedString
        init(_ value: AttributedString) { self.value = value }
    }

    private static let renderCache: NSCache<RenderKey, RenderedText> = {
        let cache = NSCache<RenderKey, RenderedText>()
        cache.countLimit = 64
        cache.totalCostLimit = 8 * 1_024 * 1_024
        return cache
    }()

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

    private struct Table {
        let lines: [AttributedString]
        let nextIndex: Int
    }

    private struct TableRow {
        let cells: [String]
        let indentation: String
    }

    private struct TableColumn {
        let alignment: TableAlignment
        let width: Int
    }

    private enum TableAlignment {
        case left
        case center
        case right
    }

    private static func baseFont(for style: Style, fallback: Font) -> Font {
        switch style {
        case .editorial: return WorkspaceTypography.body
        case .agent: return fallback
        case .standard: return fallback
        }
    }

    private static func table(
        startingAt index: Int,
        lines: [String],
        font: Font,
        style: Style
    ) -> Table? {
        guard index + 1 < lines.count,
              let header = tableRow(in: lines[index]),
              let alignments = tableAlignments(in: lines[index + 1]),
              header.cells.count == alignments.count,
              header.cells.count >= 2 else { return nil }

        var rows = [header.cells]
        var nextIndex = index + 2
        while nextIndex < lines.count,
              let row = tableRow(in: lines[nextIndex]),
              row.cells.count == header.cells.count {
            rows.append(row.cells)
            nextIndex += 1
        }

        let tableFont = baseFont(for: style, fallback: font).monospaced()
        let widths = zip(alignments.indices, alignments).map { columnIndex, alignment in
            let width = rows.map { row in
                String(styledInline(
                    row[columnIndex],
                    font: tableFont,
                    style: style).characters).count
            }.max() ?? 1
            return TableColumn(alignment: alignment, width: max(width, 1))
        }
        let indentation = header.indentation
        var rendered: [AttributedString] = []
        rendered.append(tableRow(
            rows[0],
            columns: widths,
            indentation: indentation,
            font: tableFont,
            style: style,
            isHeader: true))
        rendered.append(tableSeparator(
            columns: widths,
            indentation: indentation,
            font: tableFont))
        for row in rows.dropFirst() {
            rendered.append(tableRow(
                row,
                columns: widths,
                indentation: indentation,
                font: tableFont,
                style: style,
                isHeader: false))
        }
        return Table(lines: rendered, nextIndex: nextIndex)
    }

    private static func tableRow(in line: String) -> TableRow? {
        let leading = line.prefix(while: { $0 == " " || $0 == "\t" })
        guard leading.count <= 3 else { return nil }
        let content = String(line.dropFirst(leading.count))
            .trimmingCharacters(in: .whitespaces)
        guard let cells = splitTableCells(content), cells.count >= 2 else { return nil }
        return TableRow(
            cells: cells.map { $0.trimmingCharacters(in: .whitespaces) },
            indentation: String(leading))
    }

    private static func tableAlignments(in line: String) -> [TableAlignment]? {
        guard let row = tableRow(in: line) else { return nil }
        var alignments: [TableAlignment] = []
        alignments.reserveCapacity(row.cells.count)
        for cell in row.cells {
            let value = cell.trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { return nil }
            let leftColon = value.first == ":"
            let rightColon = value.last == ":"
            let start = leftColon ? value.index(after: value.startIndex) : value.startIndex
            let end = rightColon ? value.index(before: value.endIndex) : value.endIndex
            guard start < end,
                  value[start..<end].allSatisfy({ $0 == "-" }) else { return nil }
            if leftColon && rightColon {
                alignments.append(.center)
            } else if rightColon {
                alignments.append(.right)
            } else {
                alignments.append(.left)
            }
        }
        return alignments
    }

    private static func splitTableCells(_ source: String) -> [String]? {
        var characters = Array(source)
        if characters.first == "|" { characters.removeFirst() }

        var cells: [String] = []
        var current = ""
        var codeTicks = 0
        var endedWithPipe = false
        var index = 0

        while index < characters.count {
            let character = characters[index]
            if character == "\\", index + 1 < characters.count {
                current.append(character)
                index += 1
                current.append(characters[index])
                index += 1
                endedWithPipe = false
                continue
            }
            if character == "`" {
                var runLength = 0
                while index + runLength < characters.count,
                      characters[index + runLength] == "`" {
                    runLength += 1
                }
                current.append(String(repeating: "`", count: runLength))
                if codeTicks == 0 {
                    codeTicks = runLength
                } else if codeTicks == runLength {
                    codeTicks = 0
                }
                index += runLength
                endedWithPipe = false
                continue
            }
            if character == "|" && codeTicks == 0 {
                cells.append(current)
                current = ""
                endedWithPipe = true
            } else {
                current.append(character)
                endedWithPipe = false
            }
            index += 1
        }
        cells.append(current)
        if endedWithPipe { _ = cells.popLast() }
        return cells
    }

    private static func tableRow(
        _ cells: [String],
        columns: [TableColumn],
        indentation: String,
        font: Font,
        style: Style,
        isHeader: Bool
    ) -> AttributedString {
        let rowFont = isHeader ? font.bold() : font
        var result = styled(indentation, font: rowFont)
        for index in cells.indices {
            if index > 0 {
                result.append(styled(" │ ", font: rowFont))
            }
            let cell = styledInline(cells[index], font: rowFont, style: style)
            let visibleWidth = String(cell.characters).count
            let padding = max(0, columns[index].width - visibleWidth)
            let leftPadding: Int
            let rightPadding: Int
            switch columns[index].alignment {
            case .left:
                leftPadding = 0
                rightPadding = padding
            case .center:
                leftPadding = padding / 2
                rightPadding = padding - leftPadding
            case .right:
                leftPadding = padding
                rightPadding = 0
            }
            result.append(styled(
                String(repeating: " ", count: leftPadding),
                font: rowFont))
            result.append(cell)
            result.append(styled(
                String(repeating: " ", count: rightPadding),
                font: rowFont))
        }
        return result
    }

    private static func tableSeparator(
        columns: [TableColumn],
        indentation: String,
        font: Font
    ) -> AttributedString {
        var result = styled(indentation, font: font, foreground: .secondary)
        for index in columns.indices {
            if index > 0 {
                result.append(styled("─┼─", font: font, foreground: .secondary))
            }
            result.append(styled(
                String(repeating: "─", count: columns[index].width),
                font: font,
                foreground: .secondary))
        }
        return result
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
