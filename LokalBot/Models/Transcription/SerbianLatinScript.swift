import Foundation

enum SerbianLatinScript {
    static let languageCodes: Set<String> = ["sr", "hr", "bs", "cnr", "sh"]

    static func containsCyrillic(_ text: String) -> Bool {
        text.unicodeScalars.contains { isCyrillic($0) }
    }

    static func isSerbianCyrillic(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.contains(where: { $0 == "ђ" || $0 == "ћ" })
            && !lowered.contains(where: { otherCyrillicLetters.contains($0) })
    }

    private static let otherCyrillicLetters: Set<Character> = [
        "ы", "э", "ё", "щ", "ъ", "й", "і", "ї", "є", "ґ", "ў", "ѓ", "ќ", "ѕ",
        "ә", "ғ", "қ", "ң", "ө", "ұ", "ү", "һ",
    ]

    static func latin(_ text: String) -> String {
        guard containsCyrillic(text) else { return text }
        let characters = Array(text)
        var output = ""
        output.reserveCapacity(text.count)
        for (index, character) in characters.enumerated() {
            let lowered = character.lowercased()
            guard lowered.count == 1, let lower = lowered.first, let spelled = letters[lower] else {
                output.append(character)
                continue
            }
            guard character != lower, let first = spelled.first else {
                output += spelled
                continue
            }
            let neighbours = [index > 0 ? characters[index - 1] : nil,
                              index + 1 < characters.count ? characters[index + 1] : nil]
            let inUppercaseWord = neighbours.contains { $0.map { $0.isLetter && $0.isUppercase } == true }
            output += inUppercaseWord ? spelled.uppercased() : first.uppercased() + spelled.dropFirst()
        }
        return output
    }

    static func latinTranscript(_ transcript: Transcript,
                                language: String?) -> (transcript: Transcript, changedSegments: Int) {
        guard transcript.segments.contains(where: { containsCyrillic($0.text) }) else { return (transcript, 0) }
        if let language {
            guard languageCodes.contains(TranscriptLanguageVote.baseCode(language)) else { return (transcript, 0) }
        } else {
            guard let vote = TranscriptLanguageVote.dominant(
                      in: transcript.segments.map(\.text), aliases: TranscriptLanguageVote.serbianCroatianAliases),
                  vote.code == "hr", vote.share >= 0.8 else { return (transcript, 0) }
        }
        var result = transcript
        var changed = 0
        for index in result.segments.indices where containsCyrillic(result.segments[index].text) {
            result.segments[index].text = latin(result.segments[index].text)
            changed += 1
        }
        return (result, changed)
    }

    private static func isCyrillic(_ scalar: Unicode.Scalar) -> Bool {
        (0x0400...0x04FF).contains(scalar.value) || (0x0500...0x052F).contains(scalar.value)
    }

    private static let letters: [Character: String] = [
        "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "ђ": "đ", "е": "e", "ж": "ž",
        "з": "z", "и": "i", "ј": "j", "к": "k", "л": "l", "љ": "lj", "м": "m", "н": "n",
        "њ": "nj", "о": "o", "п": "p", "р": "r", "с": "s", "т": "t", "ћ": "ć", "у": "u",
        "ф": "f", "х": "h", "ц": "c", "ч": "č", "џ": "dž", "ш": "š",
        "й": "j", "ы": "i", "э": "e", "ю": "ju", "я": "ja", "ё": "jo", "щ": "šč",
        "ъ": "", "ь": "", "ў": "u",
        "ѓ": "đ", "ќ": "ć", "ѕ": "dz",
        "і": "i", "ї": "ji", "є": "je", "ґ": "g",
    ]
}
