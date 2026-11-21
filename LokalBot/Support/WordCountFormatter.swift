import Foundation

enum WordCountFormatter {
    static func format(words: Int) -> String {
        let count = max(0, words)
        let unit = count == 1 ? "word" : "words"
        return "\(grouped(count)) \(unit)"
    }

    private static func grouped(_ count: Int) -> String {
        let digits = String(count)
        guard digits.count > 3 else { return digits }

        var result = ""
        result.reserveCapacity(digits.count + digits.count / 3)
        for (offset, character) in digits.reversed().enumerated() {
            if offset > 0, offset % 3 == 0 { result.append(",") }
            result.append(character)
        }
        return String(result.reversed())
    }
}
