// Contains code ported from Cotabby (https://github.com/FuJacob/cotabby),
// copyright the Cotabby authors, under the GNU AGPL v3.0
// (LICENSES/AGPL-3.0.txt). Modified for LokalBot since 23 June 2026.
// See THIRD_PARTY_NOTICES.md.

import Foundation

enum CotypingPrefixWindow {
    static func shouldGenerate(for precedingText: String) -> Bool {
        guard !precedingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return !isNumbersOnly(precedingText)
    }

    static func isNumbersOnly(_ text: String) -> Bool {
        text.contains(where: \.isNumber) && !text.contains(where: \.isLetter)
    }

    static func truncatedPrefix(
        from precedingText: String, maxCharacters: Int, maxWords: Int
    ) -> String {
        guard maxCharacters > 0, maxWords > 0 else { return "" }
        var window = Substring(precedingText.suffix(maxCharacters))
        let words = window.split(whereSeparator: { $0.isWhitespace })
        if words.count > maxWords {
            window = window[words[words.count - maxWords].startIndex...]
        }
        guard window.count < precedingText.count else { return String(window) }
        return String(window[stableStart(of: window)...])
    }

    private static func stableStart(of window: Substring) -> Substring.Index {
        let front = window.prefix(window.count / 4)
        var index = front.startIndex
        while index < front.endIndex {
            let next = window.index(after: index)
            if window[index] == "\n" { return next }
            if ".?!".contains(window[index]), next < window.endIndex, window[next] == " ",
               index > window.startIndex, window[window.index(before: index)].isLetter {
                return window.index(after: next)
            }
            index = next
        }
        return window.startIndex
    }
}
