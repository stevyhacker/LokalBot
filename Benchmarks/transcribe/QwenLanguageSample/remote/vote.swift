// Each window's own vote, as TranscriptLanguageVote.dominant(in: [text], aliases:
// serbianCroatianAliases) casts it: a JSON array of texts on stdin, an array of
// [code or null, weight] on stdout. Serbian Cyrillic votes Serbian (SerbianLatinScript
// .isSerbianCyrillic), Serbian/Croatian/Bosnian/Montenegrin count as Croatian, and the
// weight is the text's Character count.
//
//   swiftc -O vote.swift -o $QLS_OUT/vote
import Foundation
import NaturalLanguage

let aliases = Dictionary(uniqueKeysWithValues: ["sr", "hr", "bs", "cnr", "sh"].map { ($0, "hr") })
let otherCyrillic: Set<Character> = ["ы", "э", "ё", "щ", "ъ", "й", "і", "ї", "є", "ґ", "ў", "ѓ", "ќ", "ѕ",
                                     "ә", "ғ", "қ", "ң", "ө", "ұ", "ү", "һ"]

func baseCode(_ language: String) -> String {
    String(language.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "")
}

func isSerbianCyrillic(_ text: String) -> Bool {
    let lowered = text.lowercased()
    return lowered.contains(where: { $0 == "ђ" || $0 == "ћ" }) && !lowered.contains(where: { otherCyrillic.contains($0) })
}

func vote(_ text: String) -> String? {
    guard text.split(whereSeparator: \.isWhitespace).count >= 3 else { return nil }
    let code: String
    if isSerbianCyrillic(text) {
        code = "sr"
    } else {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let top = recognizer.languageHypotheses(withMaximum: 1).max(by: { $0.value < $1.value }),
              top.value >= 0.5 else { return nil }
        code = baseCode(top.key.rawValue)
    }
    return aliases[code] ?? code
}

let texts = try JSONDecoder().decode([String].self, from: FileHandle.standardInput.readDataToEndOfFile())
let votes: [[Any]] = texts.map { text in
    guard let code = vote(text) else { return [NSNull(), 0] }
    return [code, text.count]
}
FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: votes))
