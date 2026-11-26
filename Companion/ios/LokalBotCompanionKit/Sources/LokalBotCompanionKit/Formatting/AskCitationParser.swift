import Foundation

public enum AskCitationParser {
    public static let scheme = "lokalbot-citation"

    private static let marker = try? NSRegularExpression(pattern: #"\[(\d{1,3}(?:\s*,\s*\d{1,3})*)\](?!\()"#)
    private static let partialTail = try? NSRegularExpression(pattern: #"\[[\d,\s]*$"#)

    public static func markers(in answer: String) -> [Int] {
        var seen: [Int] = []
        for numbers in matches(in: answer).flatMap(\.numbers) where !seen.contains(numbers) {
            seen.append(numbers)
        }
        return seen
    }

    public static func linkedMarkdown(_ answer: String, valid: Set<Int>, streaming: Bool = false) -> String {
        var text = answer
        if streaming, let tail = partialTail?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(tail.range, in: text) {
            text.removeSubrange(range)
        }
        var result = ""
        var cursor = text.startIndex
        for match in matches(in: text) {
            result += text[cursor..<match.range.lowerBound]
            result += match.numbers.map { number in
                valid.contains(number) ? "[\(number)](\(scheme)://source/\(number))" : "[\(number)]"
            }.joined()
            cursor = match.range.upperBound
        }
        result += text[cursor...]
        return result
    }

    public static func citationNumber(from url: URL) -> Int? {
        guard url.scheme == scheme, url.host == "source" else { return nil }
        return Int(url.lastPathComponent)
    }

    public static func plainText(_ answer: String) -> String {
        var result = ""
        var cursor = answer.startIndex
        for match in matches(in: answer) {
            var prefix = answer[cursor..<match.range.lowerBound]
            while prefix.last == " " { prefix.removeLast() }
            result += prefix
            cursor = match.range.upperBound
        }
        result += answer[cursor...]
        return result
    }

    public static func citedMeetingTitles(from citations: [AskCitation]) -> [String] {
        var seen = Set<String>()
        var titles: [String] = []
        for citation in citations where citation.meetingId != nil {
            let candidate = citation.label
                .components(separatedBy: " · ")
                .first?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !candidate.isEmpty, seen.insert(candidate).inserted else { continue }
            titles.append(candidate)
        }
        return titles
    }

    public static func shareText(answer: String, citations: [AskCitation]) -> String {
        let body = plainText(answer).trimmingCharacters(in: .whitespacesAndNewlines)
        let titles = citedMeetingTitles(from: citations)
        guard !titles.isEmpty else { return body }
        let sources = titles.map { "- \($0)" }.joined(separator: "\n")
        return body.isEmpty ? "Sources:\n\(sources)" : "\(body)\n\nSources:\n\(sources)"
    }

    private struct Match {
        let range: Range<String.Index>
        let numbers: [Int]
    }

    private static func matches(in text: String) -> [Match] {
        guard let marker else { return [] }
        return marker.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { result in
            guard let range = Range(result.range, in: text),
                  let inner = Range(result.range(at: 1), in: text) else { return nil }
            let numbers = text[inner].split(separator: ",").compactMap {
                Int($0.trimmingCharacters(in: .whitespaces))
            }
            return Match(range: range, numbers: numbers)
        }
    }
}
