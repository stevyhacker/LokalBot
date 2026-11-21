import Foundation

enum WhisperStockPhrases {
    static let phrases: Set<String> = [
        "thank you", "thank you very much", "thank you so much", "thank you guys",
        "thanks for watching", "thank you for watching",
    ]

    static func removing(from transcript: Transcript,
                         language: String?) -> (transcript: Transcript, removedSegments: Int) {
        guard transcript.segments.contains(where: { isStockPhrase($0.text) }),
              isNotEnglish(transcript, language: language) else { return (transcript, 0) }
        var kept = transcript
        kept.segments = transcript.segments.filter { !isStockPhrase($0.text) }
        return (kept, transcript.segments.count - kept.segments.count)
    }

    static func isStockPhrase(_ text: String) -> Bool {
        let words = text.lowercased().split(whereSeparator: { !$0.isLetter })
        return phrases.contains(words.joined(separator: " "))
    }

    private static func isNotEnglish(_ transcript: Transcript, language: String?) -> Bool {
        if let language { return TranscriptLanguageVote.baseCode(language) != "en" }
        guard let vote = TranscriptLanguageVote.dominant(
            in: transcript.segments.map(\.text), aliases: TranscriptLanguageVote.serbianCroatianAliases) else {
            return false
        }
        return vote.code != "en" && vote.share >= 0.8
    }
}
