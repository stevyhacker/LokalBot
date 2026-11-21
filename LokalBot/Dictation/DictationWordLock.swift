import Foundation

enum DictationWordLock: String, Codable, Sendable, CaseIterable {
    case off
    case digitsNamesNegation

    static let production: Self = .digitsNamesNegation

    enum Reason: String, Equatable, Sendable {
        case digits, negation, names
    }

    func kept(spoken: String, cleaned: String, glossary: String? = nil) -> (text: String, broken: [Reason]) {
        guard self == .digitsNamesNegation else { return (cleaned, []) }
        let broken = Self.broken(spoken: spoken, cleaned: cleaned, glossary: glossary)
        return (broken.isEmpty ? cleaned : spoken, broken)
    }

    static func broken(spoken: String, cleaned: String, glossary: String? = nil) -> [Reason] {
        let corrects = selfCorrects(spoken)
        var reasons: [Reason] = []
        let heard = Set(digitRuns(spoken))
        let written = Set(digitRuns(cleaned))
        let invented = !written.isSubset(of: heard) && !saysNumberWords(spoken)
        if invented || (!corrects && !heard.isSubset(of: written)) { reasons.append(.digits) }
        if !corrects, !negations(spoken).isEmpty, negations(cleaned).isEmpty { reasons.append(.negation) }
        if !corrects, !missingNames(spoken: spoken, cleaned: cleaned, glossary: glossary).isEmpty {
            reasons.append(.names)
        }
        return reasons
    }

    static let negationWords: Set<String> = [
        "not", "no", "never", "none", "nothing", "nobody", "nowhere", "neither", "nor", "cannot", "without",
    ]

    static let selfCorrectionPhrases = [
        "i mean", "sorry", "actually", "wait", "rather", "scratch that", "make that", "make it",
    ]

    static func selfCorrects(_ text: String) -> Bool {
        let lowered = text.lowercased()
        if lowered.range(of: #"\bno,"#, options: .regularExpression) != nil { return true }
        let spaced = " " + words(lowered).joined(separator: " ") + " "
        return selfCorrectionPhrases.contains { spaced.contains(" " + $0 + " ") }
    }

    static let fillerWords: Set<String> = ["uh", "um", "er", "erm", "ah", "oh", "hmm", "well", "so", "okay", "ok", "yeah", "like"]

    static func negations(_ text: String) -> Set<String> {
        var result = Set<String>()
        let normalized = text.lowercased().replacingOccurrences(of: "’", with: "'")
        for sentence in normalized.split(whereSeparator: { ".!?\n".contains($0) }) {
            var opening = true
            for word in words(String(sentence)) {
                if opening, fillerWords.contains(word) { continue }
                if word.hasSuffix("n't") || word == "cannot" {
                    result.insert("not")
                } else if negationWords.contains(word), !(opening && word == "no") {
                    result.insert(word)
                }
                opening = false
            }
        }
        return result
    }

    static func missingNames(spoken: String, cleaned: String, glossary: String?) -> [String] {
        let written = Set(words(cleaned).map { $0.lowercased() })
        let respellings = words(glossary ?? "").map { $0.lowercased() }.filter(written.contains)
        return names(spoken).filter { name in
            let key = name.lowercased()
            return !written.contains(key) && !respellings.contains { distance($0, key) <= 2 }
        }
    }

    static let numberWords: Set<String> = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve",
        "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty", "thirty", "forty",
        "fifty", "sixty", "seventy", "eighty", "ninety", "hundred", "thousand", "million", "billion", "half", "quarter",
    ]

    static func saysNumberWords(_ text: String) -> Bool {
        words(text.lowercased()).contains { numberWords.contains($0) }
    }

    static func names(_ text: String) -> [String] {
        var result: [String] = []
        var startsSentence = true
        var word = ""
        func finish() {
            guard !word.isEmpty else { return }
            if !startsSentence, word != "I", !word.hasPrefix("I'"), !word.hasPrefix("I’"),
               let first = word.first, first.isUppercase, word.dropFirst().contains(where: \.isLowercase) {
                result.append(word)
            }
            startsSentence = false
            word = ""
        }
        for character in text {
            if character.isLetter || character.isNumber || character == "'" || character == "’" {
                word.append(character)
            } else {
                finish()
                if ".!?\n".contains(character) { startsSentence = true }
            }
        }
        finish()
        return result
    }

    static func words(_ text: String) -> [String] {
        text.split { !($0.isLetter || $0.isNumber || $0 == "'" || $0 == "’") }.map(String.init)
    }

    static func digitRuns(_ text: String) -> [String] {
        let grouped = text.replacingOccurrences(of: #"(?<=\d)[,\x{00A0}\x{202F} ](?=\d{3}(?!\d))"#, with: "",
                                                options: .regularExpression)
        return grouped.split { !$0.isASCII || !$0.isNumber }.map(String.init)
    }

    private static func distance(_ lhs: String, _ rhs: String) -> Int {
        let a = Array(lhs), b = Array(rhs)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        for (i, x) in a.enumerated() {
            var current = [i + 1]
            for (j, y) in b.enumerated() {
                current.append(min(previous[j + 1] + 1, current[j] + 1, previous[j] + (x == y ? 0 : 1)))
            }
            previous = current
        }
        return previous[b.count]
    }
}
