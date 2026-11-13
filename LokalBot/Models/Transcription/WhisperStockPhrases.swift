import Foundation

/// Whisper answers audio it cannot make out (a pause, a breath, a faint
/// voice leaking from the other side of a call) with an English stock phrase
/// from its subtitle-heavy training data, whatever language it was set to:
/// on Serbian speech set to Bosnian it still writes "Thank you." where
/// Qwen3-ASR writes nothing. In a track that is not in English such a row is
/// not speech, so it is dropped. English tracks keep theirs: there it can be
/// what someone said.
enum WhisperStockPhrases {
    /// Whole rows, lowercased with punctuation removed.
    static let phrases: Set<String> = [
        "thank you", "thank you very much", "thank you so much", "thank you guys",
        "thanks for watching", "thank you for watching",
    ]

    /// `transcript` without stock-phrase rows when its language is known and
    /// not English: `language` as set, or on auto-detect, a vote of at least
    /// 80% for another language.
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
