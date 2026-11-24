import AppKit
import Foundation

enum WisprVocabularyImport {
    static let maximumReplacementWords = 4

    struct Plan: Equatable, Sendable {
        var terms: [String] = []
        var snippets = 0
        var deleted = 0
        var alreadyListed = 0
        var everydayWords = 0
        var unusable = 0
        var overLimit = 0
    }

    static func plan(
        _ entries: [WisprFlowLibrary.DictionaryEntry],
        existing vocabulary: String,
        isEverydayWord: (String) -> Bool
    ) -> Plan {
        var plan = Plan()
        var seen = Set(listedTerms(vocabulary).map(TranscriptionVocabulary.normalizedKey))
        var characters = 0
        let ordered = entries.enumerated().sorted { lhs, rhs in
            let (a, b) = (lhs.element, rhs.element)
            if a.isStarred != b.isStarred { return a.isStarred }
            if a.timesUsed != b.timesUsed { return a.timesUsed > b.timesUsed }
            if (a.lastUsed ?? "") != (b.lastUsed ?? "") { return (a.lastUsed ?? "") > (b.lastUsed ?? "") }
            return lhs.offset < rhs.offset
        }.map(\.element)
        for entry in ordered {
            if entry.isDeleted { plan.deleted += 1; continue }
            if entry.isSnippet == true || (entry.isSnippet == nil && entry.replacement != nil) {
                plan.snippets += 1
                continue
            }
            guard let term = usableTerm(entry.replacement ?? entry.phrase,
                                        isReplacement: entry.replacement != nil) else {
                plan.unusable += 1
                continue
            }
            if !term.contains(" "), term == term.lowercased(), isEverydayWord(term) {
                plan.everydayWords += 1
                continue
            }
            guard seen.insert(TranscriptionVocabulary.normalizedKey(term)).inserted else {
                plan.alreadyListed += 1
                continue
            }
            guard plan.terms.count < TranscriptionVocabulary.maximumTerms,
                  characters + term.count + 2 <= TranscriptionVocabulary.maximumCharacters else {
                plan.overLimit += 1
                continue
            }
            plan.terms.append(term)
            characters += term.count + 2
        }
        return plan
    }

    static func vocabulary(_ current: String, adding terms: [String]) -> String {
        guard !terms.isEmpty else { return current }
        let list = terms.joined(separator: ", ")
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? list : trimmed + "\n" + list
    }

    @MainActor
    static func isEverydayEnglishWord(_ word: String) -> Bool {
        let checker = NSSpellChecker.shared
        guard checker.availableLanguages.contains(where: { $0.hasPrefix("en") }) else { return false }
        let miss = checker.checkSpelling(of: word, startingAt: 0, language: "en", wrap: false,
                                         inSpellDocumentWithTag: 0, wordCount: nil)
        return miss.location == NSNotFound
    }

    private static func usableTerm(_ raw: String, isReplacement: Bool) -> String? {
        let term = raw
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;.")))
        guard (2...60).contains(term.count), !term.contains(","), !term.contains(";"),
              TranscriptionVocabulary.normalizedKey(term).isEmpty == false else { return nil }
        if isReplacement, term.split(separator: " ").count > maximumReplacementWords { return nil }
        return term
    }

    private static func listedTerms(_ vocabulary: String) -> [String] {
        vocabulary
            .components(separatedBy: CharacterSet(charactersIn: ",;\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "."))) }
            .filter { !$0.isEmpty }
    }
}
