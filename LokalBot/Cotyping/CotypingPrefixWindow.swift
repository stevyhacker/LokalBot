// Contains code ported from Cotabby (https://github.com/FuJacob/cotabby),
// copyright the Cotabby authors, under the GNU AGPL v3.0
// (LICENSES/AGPL-3.0.txt). Modified for LokalBot since 23 June 2026.
// See THIRD_PARTY_NOTICES.md.

import Foundation

/// Pure rules for "should we generate, and on how much context." Ported from
/// Cotabby's `SuggestionRequestFactory.shouldGenerateSuggestion` +
/// `truncatedPromptPrefix`.
enum CotypingPrefixWindow {
    /// Generate only when there is at least one non-whitespace character before
    /// the caret (no suggestions on a blank field), and not while everything
    /// before it is numbers without a single letter: a verification code, a
    /// phone number or an amount has no prose to continue. A word brings
    /// suggestions back.
    static func shouldGenerate(for precedingText: String) -> Bool {
        guard !precedingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return !isNumbersOnly(precedingText)
    }

    /// Digits with no letters, such as `482 913`, `+382 67 123 456` or `12.50`.
    static func isNumbersOnly(_ text: String) -> Bool {
        text.contains(where: \.isNumber) && !text.contains(where: \.isLetter)
    }

    /// Bound the latest text without rewriting paragraph breaks, list indentation,
    /// or the exact whitespace at the caret. These are prediction inputs.
    ///
    /// A window cut from longer text starts at a sentence or paragraph
    /// boundary near its front. The model keeps what it has read for the
    /// unchanged start of the prompt, and a window that moved by one character
    /// per keystroke would make it read the whole window again every time.
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

    /// Just after the first line break or sentence end in the front quarter
    /// of `window`, or its own start when there is none.
    private static func stableStart(of window: Substring) -> Substring.Index {
        let front = window.prefix(window.count / 4)
        var index = front.startIndex
        while index < front.endIndex {
            let next = window.index(after: index)
            if window[index] == "\n" { return next }
            // A full stop after a letter ends a sentence; "1. " numbers a list.
            if ".?!".contains(window[index]), next < window.endIndex, window[next] == " ",
               index > window.startIndex, window[window.index(before: index)].isLetter {
                return window.index(after: next)
            }
            index = next
        }
        return window.startIndex
    }
}
