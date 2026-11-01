import Foundation

/// The block structure of the Markdown the Mac sends (summaries, notes,
/// digests, answers): headings, paragraphs, lists and quotes. Inline styling
/// is left to `AttributedString(markdown:)`.
public struct MarkdownDocument: Sendable, Hashable {
    public enum Block: Sendable, Hashable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case bullets([String])
        case numbered([String])
        case quote(String)
    }

    public var blocks: [Block]

    public init(blocks: [Block]) {
        self.blocks = blocks
    }

    public init(_ markdown: String) {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var bullets: [String] = []
        var numbered: [String] = []
        var quote: [String] = []

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))) }
            if !bullets.isEmpty { blocks.append(.bullets(bullets)) }
            if !numbered.isEmpty { blocks.append(.numbered(numbered)) }
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: " "))) }
            paragraph = []; bullets = []; numbered = []; quote = []
        }

        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flush()
            } else if let heading = Self.heading(line) {
                flush()
                blocks.append(heading)
            } else if let item = Self.bullet(line) {
                if bullets.isEmpty { flush() }
                bullets.append(item)
            } else if let item = Self.numberedItem(line) {
                if numbered.isEmpty { flush() }
                numbered.append(item)
            } else if line.hasPrefix(">") {
                if quote.isEmpty { flush() }
                quote.append(line.dropFirst().trimmingCharacters(in: .whitespaces))
            } else if !bullets.isEmpty, rawLine.first?.isWhitespace == true {
                bullets[bullets.count - 1] += " " + line
            } else {
                if !bullets.isEmpty || !numbered.isEmpty || !quote.isEmpty { flush() }
                paragraph.append(line)
            }
        }
        flush()
        self.blocks = blocks
    }

    public var isEmpty: Bool { blocks.isEmpty }

    /// The blocks under the first heading named one of `titles`, up to the
    /// next heading of the same or a higher level.
    public func section(named titles: Set<String>) -> MarkdownDocument? {
        guard let start = blocks.firstIndex(where: {
            if case .heading(_, let text) = $0 { return titles.contains(Self.normalizedTitle(text)) }
            return false
        }), case .heading(let level, _) = blocks[start] else { return nil }
        let rest = blocks[(start + 1)...]
        let end = rest.firstIndex(where: { if case .heading(let next, _) = $0 { return next <= level }; return false }) ?? blocks.endIndex
        return MarkdownDocument(blocks: Array(blocks[(start + 1)..<end]))
    }

    /// Everything except the sections named `titles`.
    public func removingSections(named titles: Set<String>) -> MarkdownDocument {
        var kept: [Block] = []
        var skippingLevel: Int?
        for block in blocks {
            if case .heading(let level, let text) = block {
                if let skipping = skippingLevel, level > skipping { continue }
                skippingLevel = titles.contains(Self.normalizedTitle(text)) ? level : nil
                if skippingLevel != nil { continue }
            } else if skippingLevel != nil {
                continue
            }
            kept.append(block)
        }
        return MarkdownDocument(blocks: kept)
    }

    static func normalizedTitle(_ text: String) -> String {
        text.lowercased().trimmingCharacters(in: .whitespaces.union(.punctuationCharacters))
    }

    private static func heading(_ line: String) -> Block? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return .heading(level: hashes, text: line.dropFirst(hashes + 1).trimmingCharacters(in: .whitespaces))
    }

    private static func bullet(_ line: String) -> String? {
        for marker in ["- ", "* ", "+ ", "• "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count))
        }
        return nil
    }

    private static func numberedItem(_ line: String) -> String? {
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return String(rest.dropFirst(2))
    }
}

/// What the Summary tab shows as Recap: the summary's Recap section. Action
/// items, decisions and open questions come from the meeting's structured
/// fields, so those sections are left out of a summary without one.
public enum SummaryPresentation {
    static let recapTitles: Set<String> = ["recap", "summary", "overview"]
    static let structuredTitles: Set<String> = [
        "action items", "actions", "decisions", "open questions", "questions", "next steps",
    ]

    public static func recap(_ markdown: String?) -> MarkdownDocument? {
        guard let markdown, !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let document = MarkdownDocument(markdown)
        if let recap = document.section(named: recapTitles), !recap.isEmpty { return recap }
        let rest = document.removingSections(named: structuredTitles)
        return rest.isEmpty ? nil : rest
    }
}

public enum MarkdownInline {
    /// Inline Markdown (bold, italics, code, links) as styled text; plain text
    /// when it doesn't parse.
    public static func attributed(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                           failurePolicy: .returnPartiallyParsedIfPossible)))
            ?? AttributedString(text)
    }
}
