import Foundation

/// Serbian, Croatian, Bosnian and Montenegrin are one language written in two
/// scripts. Speech models drift between them mid-meeting: Qwen3-ASR pinned to
/// Serbian writes about half its windows in Cyrillic, and on auto-detect it
/// slips into Macedonian or Russian spellings of Serbian words. A transcript
/// that switches script line by line is hard to read and to search, so
/// meeting transcripts in this language are kept in Latin script, the script
/// LokalBot's own Serbian interface uses.
enum SerbianLatinScript {
    /// Base language codes that NaturalLanguage and speech models give
    /// Serbian, Croatian, Bosnian and Montenegrin speech.
    static let languageCodes: Set<String> = ["sr", "hr", "bs", "cnr", "sh"]

    static func containsCyrillic(_ text: String) -> Bool {
        text.unicodeScalars.contains { isCyrillic($0) }
    }

    /// Cyrillic text with ђ or ћ, letters only Serbian writes (Macedonian
    /// has ѓ and ќ in their place), and none that only another Cyrillic
    /// language writes. Apple's language recognizer reads Serbian Cyrillic
    /// as Kazakh with full confidence.
    static func isSerbianCyrillic(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.contains(where: { $0 == "ђ" || $0 == "ћ" })
            && !lowered.contains(where: { otherCyrillicLetters.contains($0) })
    }

    /// Letters of Russian, Ukrainian, Belarusian, Macedonian and Kazakh that
    /// Serbian does not use.
    private static let otherCyrillicLetters: Set<Character> = [
        "ы", "э", "ё", "щ", "ъ", "й", "і", "ї", "є", "ґ", "ў", "ѓ", "ќ", "ѕ",
        "ә", "ғ", "қ", "ң", "ө", "ұ", "ү", "һ",
    ]

    /// `text` with every Cyrillic letter spelled in Serbian Latin. Letters
    /// outside the Serbian alphabet, which appear when a model drifts into
    /// Russian, Macedonian or Ukrainian, take their closest Serbian Latin
    /// spelling. Everything else is left exactly as it was.
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
            // An uppercase digraph letter is title case ("Ljubljana") unless
            // it sits in an uppercase word ("LJUBLJANA").
            let neighbours = [index > 0 ? characters[index - 1] : nil,
                              index + 1 < characters.count ? characters[index + 1] : nil]
            let inUppercaseWord = neighbours.contains { $0.map { $0.isLetter && $0.isUppercase } == true }
            output += inUppercaseWord ? spelled.uppercased() : first.uppercased() + spelled.dropFirst()
        }
        return output
    }

    /// `transcript` with its Cyrillic lines in Latin script when it is in
    /// this language: transcribed with the language set to one of its codes,
    /// or, on auto-detect, voted at least 80% Serbian, Croatian, Bosnian or
    /// Montenegrin. Any other transcript is returned unchanged, so a Russian
    /// or Ukrainian meeting keeps its script.
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
        // Serbian Cyrillic.
        "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "ђ": "đ", "е": "e", "ж": "ž",
        "з": "z", "и": "i", "ј": "j", "к": "k", "л": "l", "љ": "lj", "м": "m", "н": "n",
        "њ": "nj", "о": "o", "п": "p", "р": "r", "с": "s", "т": "t", "ћ": "ć", "у": "u",
        "ф": "f", "х": "h", "ц": "c", "ч": "č", "џ": "dž", "ш": "š",
        // Russian, Bulgarian and Belarusian letters a drifting model writes.
        "й": "j", "ы": "i", "э": "e", "ю": "ju", "я": "ja", "ё": "jo", "щ": "šč",
        "ъ": "", "ь": "", "ў": "u",
        // Macedonian.
        "ѓ": "đ", "ќ": "ć", "ѕ": "dz",
        // Ukrainian.
        "і": "i", "ї": "ji", "є": "je", "ґ": "g",
    ]
}
