// Contains code ported from Cotabby (https://github.com/FuJacob/cotabby),
// copyright the Cotabby authors, under the GNU AGPL v3.0
// (LICENSES/AGPL-3.0.txt). Modified for LokalBot since 23 June 2026.
// See THIRD_PARTY_NOTICES.md.

import AppKit
import Foundation

/// NSSpellChecker-backed typo detection + correction for cotyping autocorrect.
/// Ports Cotabby's `CurrentWordSpellChecker`: native, instant, offline,
/// multilingual, and the same engine the system underlines with. Flags
/// non-words only — real-word errors (their/there) are out of scope. A unique
/// spell-document tag isolates our session from other text-checking state.
@MainActor
final class CotypingSpellChecker {
    private let documentTag = NSSpellChecker.uniqueSpellDocumentTag()
    /// Each keystroke asks several times about the same text; the language
    /// is recognized once.
    private var lastVerdict: (window: String, applies: Bool)?

    /// Whether typo/known-word verdicts are meaningful for the text at the
    /// caret. False when the context is confidently in a language macOS has no
    /// dictionary for (Serbian, Croatian, Montenegrin, …) — every spell-gated
    /// policy must stand down instead of flagging the whole language.
    func verdictsApply(context: String) -> Bool {
        let window = context.suffix(CotypingSpellLanguageGate.contextWindowCharacters)
        if let lastVerdict, lastVerdict.window == window { return lastVerdict.applies }
        let applies = CotypingSpellLanguageGate.spellVerdictsApply(
            context: String(window),
            availableLanguages: NSSpellChecker.shared.availableLanguages)
        lastVerdict = (String(window), applies)
        return applies
    }

    /// Shared by live prediction and headless replay. Unknown dictionary
    /// coverage must not turn every Serbian fragment into a spelling error.
    func wordPrefixIsValidWord(context: String) -> Bool {
        let partial = CotypingMidWord.currentPartialWord(in: context)
        guard partial.count >= 2, verdictsApply(context: context) else { return true }
        return !isTypo(partial)
    }

    /// True when the whole word is misspelled (range must start at 0 and span the
    /// entire word, so partly-flagged tokens like `I'm` don't misfire).
    func isTypo(_ word: String) -> Bool {
        guard !word.isEmpty else { return false }
        let range = NSSpellChecker.shared.checkSpelling(
            of: word, startingAt: 0, language: nil, wrap: false,
            inSpellDocumentWithTag: documentTag, wordCount: nil)
        return range.location == 0 && range.length == (word as NSString).length
    }

    /// The single best fix: the top native guess that's a different single word,
    /// recased to match the typo. `nil` when there's no usable guess.
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

    /// True when the partial word the caret sits in can still become a real
    /// word (native word-completion list is non-empty). Distinguishes an
    /// unfinished word ("follo" → follow…) from a genuine typo ("recieve"),
    /// which has no completions. Mirrors Cotypist's mid-word behavior: keep
    /// completing while the fragment is a live word prefix.
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
