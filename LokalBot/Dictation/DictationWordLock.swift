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
        if broken.isEmpty || broken == [.digits], Self.digitSequence(spoken) != Self.digitSequence(cleaned),
           let restored = Self.restoringDigits(spoken: spoken, cleaned: cleaned),
           Self.broken(spoken: spoken, cleaned: restored, glossary: glossary).isEmpty {
            return (restored, [])
        }
        return broken.isEmpty ? (cleaned, []) : (spoken, broken)
    }

    static let numberWordValues: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
        "seventeen": 17, "eighteen": 18, "nineteen": 19, "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]

    private static let numberTokens: NSRegularExpression? = {
        let tens = "twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety"
        let units = "one|two|three|four|five|six|seven|eight|nine"
        return try? NSRegularExpression(
            pattern: "[0-9]+|\\b(?:\(tens))[- ](?:\(units))\\b|\\p{L}+", options: [.caseInsensitive])
    }()

    private static func tokens(_ text: String) -> [(range: Range<String.Index>, text: String)] {
        guard let expression = numberTokens else { return [] }
        return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            Range(match.range, in: text).map { ($0, String(text[$0])) }
        }
    }

    private struct SpokenNumbers {
        var runEnds: [Int] = []
        var wordsBeforeRun: [[Int]] = [[]]

        init(_ spoken: String) {
            var digits = 0
            for token in DictationWordLock.tokens(spoken) {
                if token.text.first?.isNumber == true {
                    digits += token.text.count
                    runEnds.append(digits)
                    wordsBeforeRun.append([])
                } else if let value = DictationWordLock.numberValue(token.text) {
                    wordsBeforeRun[wordsBeforeRun.count - 1].append(value)
                }
            }
        }
    }

    static func restoringDigits(spoken: String, cleaned: String) -> String? {
        var remaining = Substring(digitSequence(spoken))
        guard !remaining.isEmpty else { return nil }
        let joined = joinedDigits(spoken)
        let layout = SpokenNumbers(spoken)
        var run = 0
        var spokenWords = layout.wordsBeforeRun[0]
        var consumed = 0
        var result = ""
        var last = cleaned.startIndex
        var changed = false
        var written: [Int: Int] = [:]
        var restored: [Int: Int] = [:]
        func consume(_ count: Int) {
            remaining = remaining.dropFirst(count)
            consumed += count
            while run < layout.runEnds.count, consumed >= layout.runEnds[run] {
                run += 1
                spokenWords = layout.wordsBeforeRun[run]
            }
        }
        for token in tokens(cleaned) {
            if token.text.first?.isNumber == true {
                guard remaining.hasPrefix(token.text) else { return nil }
                consume(token.text.count)
                continue
            }
            guard let value = numberValue(token.text) else { continue }
            written[value, default: 0] += 1
            if let said = spokenWords.firstIndex(of: value) {
                spokenWords.remove(at: said)
                continue
            }
            guard remaining.hasPrefix(String(value)) else { continue }
            let digits = String(value).count
            guard !joined[consumed..<(consumed + digits)].contains(true) else { return nil }
            result += cleaned[last..<token.range.lowerBound] + String(value)
            last = token.range.upperBound
            consume(digits)
            restored[value, default: 0] += 1
            changed = true
        }
        guard changed, remaining.isEmpty else { return nil }
        let said = layout.wordsBeforeRun.joined().reduce(into: [Int: Int]()) { $0[$1, default: 0] += 1 }
        guard restored.allSatisfy({ written[$0.key] == $0.value + (said[$0.key] ?? 0) }) else { return nil }
        return result + cleaned[last...]
    }

    private static func joinedDigits(_ spoken: String) -> [Bool] {
        var flags: [Bool] = []
        guard let expression = try? NSRegularExpression(pattern: "[0-9]+(?:[.,:/][0-9]+)*") else { return flags }
        for match in expression.matches(in: spoken, range: NSRange(spoken.startIndex..., in: spoken)) {
            guard let range = Range(match.range, in: spoken) else { continue }
            let token = spoken[range]
            let digits = token.filter(\.isNumber).count
            flags += Array(repeating: digits != token.count, count: digits)
        }
        return flags
    }

    private static func numberValue(_ token: String) -> Int? {
        let parts = token.lowercased().split(whereSeparator: { $0 == " " || $0 == "-" }).map(String.init)
        guard let first = parts.first, let value = numberWordValues[first] else { return nil }
        guard parts.count == 2 else { return value }
        guard value >= 20, value % 10 == 0, let unit = numberWordValues[parts[1]], (1...9).contains(unit) else { return nil }
        return value + unit
    }

    static func broken(spoken: String, cleaned: String, glossary: String? = nil) -> [Reason] {
        let corrects = selfCorrects(spoken)
        var reasons: [Reason] = []
        let heard = digitSequence(spoken)
        let written = digitSequence(cleaned)
        if heard != written {
            let added = isSubsequence(heard, of: written) && numberWordsAccount(for: cleaned, spoken: spoken)
            let dropped = isSubsequence(written, of: heard) && corrects
            if !added && !dropped { reasons.append(.digits) }
        }
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

    static let magnitudeWords: Set<String> = ["hundred", "thousand", "million", "billion", "half", "quarter"]

    static func numberWordsAccount(for written: String, spoken: String) -> Bool {
        guard saysNumberWords(spoken) else { return false }
        if words(spoken.lowercased()).contains(where: magnitudeWords.contains) { return true }
        var keptAsWords = tokens(written).compactMap { numberValue($0.text) }
        let sayable = tokens(spoken).map { token -> String in
            if token.text.first?.isNumber == true { return token.text }
            guard let value = numberValue(token.text) else { return "" }
            if let kept = keptAsWords.firstIndex(of: value) {
                keptAsWords.remove(at: kept)
                return ""
            }
            return String(value)
        }.joined()
        return isSubsequence(digitSequence(written), of: sayable)
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

    static func digitSequence(_ text: String) -> String {
        String(text.filter { $0.isASCII && $0.isNumber })
    }

    private static func isSubsequence(_ short: String, of long: String) -> Bool {
        var remaining = short[...]
        for character in long where remaining.first == character { remaining = remaining.dropFirst() }
        return remaining.isEmpty
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
