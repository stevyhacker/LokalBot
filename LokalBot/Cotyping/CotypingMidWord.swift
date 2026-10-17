// Contains code ported from Cotabby (https://github.com/FuJacob/cotabby),
// copyright the Cotabby authors, under the GNU AGPL v3.0
// (LICENSES/AGPL-3.0.txt). Modified for LokalBot since 23 June 2026.
// See THIRD_PARTY_NOTICES.md.

import Foundation

/// Mid-word continuation rules. Ports Cotabby's `MidWordContinuationPolicy`.
///
/// When the caret sits strictly inside a word (a word character on BOTH sides),
/// the suggestion must continue that word, not start a new one. Cotabby enforces
/// this in-process by masking the first sampled token so it carries no leading
/// whitespace. LokalBot talks to an HTTP `llama-server`, so it can't mask a
/// token mid-generation; instead `CotypingTextNormalizer` reproduces the same
/// outcome at the output layer using these pure helpers: never re-type the
/// current partial word, and (strictly inside) never begin with whitespace or an
/// incompatible word tail.
enum CotypingMidWord {
    /// True only when the caret is strictly inside a word — a letter/digit
    /// immediately before AND after it. At a word end (nothing or punctuation
    /// after the caret) this is false, so ordinary next-word prediction (which
    /// wants a leading space) is left untouched — exactly Cotabby's policy.
    static func shouldForceContinuation(precedingText: String, trailingText: String) -> Bool {
        guard let before = precedingText.last, isWordCharacter(before) else { return false }
        guard let after = trailingText.first, isWordCharacter(after) else { return false }
        return true
    }

    /// The run of word characters the caret currently sits at the end of (the
    /// partial word being typed), or "" when the caret is not mid-word.
    static func currentPartialWord(in precedingText: String) -> String {
        var reversed: [Character] = []
        for character in precedingText.reversed() {
            guard isWordCharacter(character) else { break }
            reversed.append(character)
        }
        return String(reversed.reversed())
    }

    static func leadingWordRun(in text: String) -> String {
        var result = ""
        for character in text {
            guard isWordCharacter(character) else { break }
            result.append(character)
        }
        return result
    }

    /// How much already-present text to the right of the caret should be removed
    /// before accepting a forced mid-word suggestion. This only treats a prefix as
    /// an overlap when it completes either the accepted word fragment or the
    /// existing right-side word fragment, so a weak one-character common prefix
    /// like "operate" vs "ord" is left alone.
    static func acceptedTrailingOverlapCount(acceptedText: String, trailingText: String) -> Int {
        let acceptedWord = leadingWordRun(in: acceptedText)
        let trailingWord = leadingWordRun(in: trailingText)
        guard !acceptedWord.isEmpty, !trailingWord.isEmpty else { return 0 }

        var acceptedIndex = acceptedWord.startIndex
        var trailingIndex = trailingWord.startIndex
        var count = 0
        while acceptedIndex < acceptedWord.endIndex,
              trailingIndex < trailingWord.endIndex,
              acceptedWord[acceptedIndex] == trailingWord[trailingIndex] {
            count += 1
            acceptedIndex = acceptedWord.index(after: acceptedIndex)
            trailingIndex = trailingWord.index(after: trailingIndex)
        }
        return count == min(acceptedWord.count, trailingWord.count) ? count : 0
    }

    static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }
}
