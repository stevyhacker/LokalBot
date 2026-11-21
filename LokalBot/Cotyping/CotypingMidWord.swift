// Contains code ported from Cotabby (https://github.com/FuJacob/cotabby),
// copyright the Cotabby authors, under the GNU AGPL v3.0
// (LICENSES/AGPL-3.0.txt). Modified for LokalBot since 23 June 2026.
// See THIRD_PARTY_NOTICES.md.

import Foundation

enum CotypingMidWord {
    static func shouldForceContinuation(precedingText: String, trailingText: String) -> Bool {
        guard let before = precedingText.last, isWordCharacter(before) else { return false }
        guard let after = trailingText.first, isWordCharacter(after) else { return false }
        return true
    }

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
