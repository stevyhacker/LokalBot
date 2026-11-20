// Contains code ported from Cotabby (https://github.com/FuJacob/cotabby),
// copyright the Cotabby authors, under the GNU AGPL v3.0
// (LICENSES/AGPL-3.0.txt). Modified for LokalBot since 23 June 2026.
// See THIRD_PARTY_NOTICES.md.

import AppKit
import Foundation

@MainActor
final class CotypingSpellChecker {
    private let documentTag = NSSpellChecker.uniqueSpellDocumentTag()
    private var lastVerdict: (window: String, applies: Bool)?

    func verdictsApply(context: String) -> Bool {
        let window = context.suffix(CotypingSpellLanguageGate.contextWindowCharacters)
        if let lastVerdict, lastVerdict.window == window { return lastVerdict.applies }
        let applies = CotypingSpellLanguageGate.spellVerdictsApply(
            context: String(window),
            availableLanguages: NSSpellChecker.shared.availableLanguages)
        lastVerdict = (String(window), applies)
        return applies
    }

    func wordPrefixIsValidWord(context: String) -> Bool {
        let partial = CotypingMidWord.currentPartialWord(in: context)
        guard partial.count >= 2, verdictsApply(context: context) else { return true }
        return !isTypo(partial)
    }

    func isTypo(_ word: String) -> Bool {
        guard !word.isEmpty else { return false }
        let range = NSSpellChecker.shared.checkSpelling(
            of: word, startingAt: 0, language: nil, wrap: false,
            inSpellDocumentWithTag: documentTag, wordCount: nil)
        return range.location == 0 && range.length == (word as NSString).length
    }

    func bestCorrection(for word: String) -> String? {
        let range = NSRange(location: 0, length: (word as NSString).length)
        let guesses = NSSpellChecker.shared.guesses(
            forWordRange: range, in: word, language: nil, inSpellDocumentWithTag: documentTag) ?? []
        let candidate = guesses
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && $0.lowercased() != word.lowercased() && !$0.contains(" ") }
        guard let candidate else { return nil }
        return CotypingCaseTransfer.applying(caseOf: word, to: candidate)
    }

    func isCompletableWordPrefix(_ word: String) -> Bool {
        guard !word.isEmpty else { return false }
        let range = NSRange(location: 0, length: (word as NSString).length)
        let completions = NSSpellChecker.shared.completions(
            forPartialWordRange: range, in: word, language: nil,
            inSpellDocumentWithTag: documentTag) ?? []
        return completions.contains { completion in
            completion.count > word.count
                && completion.lowercased().hasPrefix(word.lowercased())
        }
    }
}
