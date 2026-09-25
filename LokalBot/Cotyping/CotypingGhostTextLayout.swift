import AppKit

/// Pre-wraps popup/mirror ghost text so multi-line suggestions do not collapse
/// into a single truncated row. Inline uses `CotypingInlineGhostLayout`; popup
/// has its own chrome and independently bounded rows.
nonisolated enum CotypingGhostTextLayout {
    static let maxMirrorTextWidth: CGFloat = 420
    static let minMirrorTextWidth: CGFloat = 80
    static let maxMirrorLines = 4
    private static let screenMargin: CGFloat = 24

    struct Layout: Equatable {
        let lines: [String]
        let textSize: CGSize

        var displayText: String { lines.joined(separator: "\n") }
    }

    static func mirrorLayout(
        text: String,
        style: CotypingFieldStyle?,
        visible: CGRect?,
        maxLines: Int = maxMirrorLines
    ) -> Layout {
        let font = CotypingGhostStyle.resolvedFont(from: style)
        let maxWidth = mirrorTextWidthBudget(visible: visible)
        let lines = wrappedLines(
            text: text,
            font: font,
            maxWidth: maxWidth,
            maxLines: maxLines)
        let lineHeight = ceil(font.ascender - font.descender)
        let widestLine = lines
            .map { measuredWidth($0, font: font) }
            .max() ?? minMirrorTextWidth
        let textSize = CGSize(
            width: ceil(min(maxWidth, max(widestLine, minMirrorTextWidth))),
            height: ceil(max(CGFloat(lines.count), 1) * max(lineHeight, 1)))
        return Layout(lines: lines, textSize: textSize)
    }

    static func wrappedLines(
        text: String,
        font: NSFont,
        maxWidth: CGFloat,
        maxLines: Int = maxMirrorLines
    ) -> [String] {
        let normalized = normalizedDisplayText(text)
        guard maxLines > 0 else { return [] }
        guard !normalized.isEmpty else { return [] }

        let paragraphs = normalized.components(separatedBy: .newlines)
        var result: [String] = []
        var truncated = false
        for (paragraphIndex, paragraph) in paragraphs.enumerated() {
            var remaining = paragraph.trimmingCharacters(in: .whitespaces)
            if remaining.isEmpty {
                continue
            }
            while !remaining.isEmpty {
                guard result.count < maxLines else {
                    truncated = true
                    break
                }
                let split = splitPrefix(remaining, font: font, maxWidth: maxWidth)
                result.append(split.line)
                remaining = split.remainder
            }
            if truncated {
                break
            }
            if result.count >= maxLines,
               paragraphs.dropFirst(paragraphIndex + 1).contains(where: {
                   !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
               }) {
                truncated = true
                break
            }
        }

        if result.isEmpty {
            return []
        }
        if truncated {
            result[result.count - 1] = ellipsized(result[result.count - 1], font: font, maxWidth: maxWidth)
        }
        return result
    }

    private static func mirrorTextWidthBudget(visible: CGRect?) -> CGFloat {
        guard let visible else { return maxMirrorTextWidth }
        let screenBudget = visible.width - (screenMargin * 2)
        return min(maxMirrorTextWidth, max(minMirrorTextWidth, screenBudget))
    }

    private static func normalizedDisplayText(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines).map { line in
            line.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        }
        return lines
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func splitPrefix(
        _ text: String,
        font: NSFont,
        maxWidth: CGFloat
    ) -> (line: String, remainder: String) {
        let source = text.trimmingCharacters(in: .whitespaces)
        guard !source.isEmpty else { return ("", "") }
        guard measuredWidth(source, font: font) > maxWidth else {
            return (source, "")
        }

        let words = source.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return ("", "") }
        var line = ""
        var usedWords = 0

        for word in words {
            let candidate = line.isEmpty ? word : "\(line) \(word)"
            if measuredWidth(candidate, font: font) <= maxWidth || line.isEmpty {
                line = candidate
                usedWords += 1
            } else {
                break
            }
        }

        if measuredWidth(line, font: font) > maxWidth {
            let split = splitLongWord(line, font: font, maxWidth: maxWidth)
            let remainder = ([split.remainder] + words.dropFirst(usedWords))
                .filter { !$0.isEmpty }.joined(separator: " ")
            return (split.line, remainder)
        }

        let remainder = words.dropFirst(usedWords).joined(separator: " ")
        return (line, remainder)
    }

    private static func splitLongWord(
        _ word: String,
        font: NSFont,
        maxWidth: CGFloat
    ) -> (line: String, remainder: String) {
        var prefix = ""
        var consumed = 0
        for character in word {
            let candidate = prefix + String(character)
            if !prefix.isEmpty, measuredWidth(candidate, font: font) > maxWidth {
                break
            }
            prefix = candidate
            consumed += 1
        }
        guard consumed > 0 else { return (String(word.prefix(1)), String(word.dropFirst())) }
        return (prefix, String(word.dropFirst(consumed)))
    }

    private static func ellipsized(_ line: String, font: NSFont, maxWidth: CGFloat) -> String {
        let suffix = "..."
        var candidate = line.trimmingCharacters(in: .whitespaces)
        while !candidate.isEmpty,
              measuredWidth(candidate + suffix, font: font) > maxWidth {
            candidate.removeLast()
        }
        return candidate.isEmpty ? suffix : candidate + suffix
    }

    private static func measuredWidth(_ text: String, font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }
}
