import Foundation

enum PromptContextSanitizer {
    private static let space: Unicode.Scalar = " "
    private static let newline: Unicode.Scalar = "\n"
    private static let newlineScalars = CharacterSet.newlines
    private static let controlScalars = CharacterSet.controlCharacters
    private static let inlineWhitespace = CharacterSet.whitespaces
    private static let ellipsis: Character = "\u{2026}"

    static func sanitize(_ text: String, maxCharacters: Int? = nil) -> String {
        var folded = String.UnicodeScalarView()
        folded.reserveCapacity(text.unicodeScalars.count)
        for scalar in text.unicodeScalars {
            if newlineScalars.contains(scalar) {
                folded.append(newline)
            } else if controlScalars.contains(scalar) {
                folded.append(space)
            } else {
                folded.append(scalar)
            }
        }

        let cleanedLines = String(folded)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { collapseInlineWhitespace(String($0)) }

        var lines: [String] = []
        var pendingBlank = false
        for line in cleanedLines {
            if line.isEmpty {
                pendingBlank = !lines.isEmpty
            } else {
                if pendingBlank { lines.append("") }
                pendingBlank = false
                lines.append(line)
            }
        }

        let trimmed = lines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let cap = maxCharacters else { return trimmed }
        guard cap > 0 else { return "" }
        guard trimmed.count > cap else { return trimmed }
        return hardCap(trimmed, to: cap)
    }

    private static func collapseInlineWhitespace(_ line: String) -> String {
        var result = String.UnicodeScalarView()
        result.reserveCapacity(line.unicodeScalars.count)
        var pendingSpace = false
        for scalar in line.unicodeScalars {
            if inlineWhitespace.contains(scalar) {
                pendingSpace = true
            } else {
                if pendingSpace, !result.isEmpty { result.append(space) }
                pendingSpace = false
                result.append(scalar)
            }
        }
        return String(result)
    }

    private static func hardCap(_ text: String, to cap: Int) -> String {
        let budget = cap - 1
        guard budget > 0 else { return String(text.prefix(cap)) }

        let head = text.prefix(budget)
        if let breakIndex = head.lastIndex(where: { $0.isWhitespace }) {
            let word = head[..<breakIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            if !word.isEmpty { return word + String(ellipsis) }
        }
        return String(head) + String(ellipsis)
    }
}
