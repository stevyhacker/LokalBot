import Foundation

/// Presentation order only: never grants source authority, removes a record,
/// resolves a contradiction, or uses an evaluation label to select evidence.
enum ChatEvidenceOrdering {
    static func prioritize(_ evidence: ChatEvidence, question: String) -> ChatEvidence {
        let query = terms(question)
        guard !query.isEmpty else { return evidence }
        let ranked = evidence.excerpts.enumerated().map { index, source in
            (index: index, source: source,
             titleMatches: terms(source.meetingTitle).intersection(query).count,
             textMatches: terms(source.text).intersection(query).count)
        }.sorted { left, right in
            if left.titleMatches != right.titleMatches { return left.titleMatches > right.titleMatches }
            if left.textMatches != right.textMatches { return left.textMatches > right.textMatches }
            // Preserve the retrieval order on ties. A timestamp alone does not
            // establish which fact supersedes another or which person spoke.
            return left.index < right.index
        }
        var result = evidence
        result.excerpts = ranked.map(\.source)
        return result
    }

    private static func terms(_ text: String) -> Set<String> {
        // Transliteration is for matching only. The quoted source, speaker
        // label, and citation remain byte-for-byte owned by the tool result.
        let latin = text.applyingTransform(.toLatin, reverse: false) ?? text
        let normalized = latin.folding(options: [.caseInsensitive, .diacriticInsensitive],
                                       locale: Locale(identifier: "en_US_POSIX"))
        return Set(normalized.split { !$0.isLetter && !$0.isNumber }.map(String.init))
            .subtracting(stopWords)
    }

    private static let stopWords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "been", "by", "did", "do", "does", "for", "from",
        "has", "have", "how", "i", "in", "is", "it", "of", "on", "or", "the", "this", "to", "was", "were",
        "what", "when", "where", "which", "who", "with", "project", "meeting",
        "da", "gde", "iz", "je", "ko", "koji", "li", "na", "o", "od", "sa", "se", "sta",
        "su", "u", "za", "projekat", "projekta", "sastanak",
    ]
}
