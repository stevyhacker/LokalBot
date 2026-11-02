import Foundation

/// `[n]` markers in an Ask answer refer to `AskResult.citations[].index`.
/// They become links the answer view styles as teal source badges, the way the
/// Mac's editorial transcript does.
public enum AskCitationParser {
    public static let scheme = "lokalbot-citation"

    /// `[3]` or `[1, 2]`, not the label of a Markdown link `[text](url)`.
    private static let marker = try! NSRegularExpression(pattern: #"\[(\d{1,3}(?:\s*,\s*\d{1,3})*)\](?!\()"#)
    /// An unfinished marker at the end of streamed text: `[`, `[1`, `[1, `.
    private static let partialTail = try! NSRegularExpression(pattern: #"\[[\d,\s]*$"#)

    /// Citation numbers in the order they first appear.
    public static func markers(in answer: String) -> [Int] {
        var seen: [Int] = []
        for numbers in matches(in: answer).flatMap(\.numbers) where !seen.contains(numbers) {
            seen.append(numbers)
        }
        return seen
    }

    /// The answer as Markdown in which each known `[n]` links to
    /// `lokalbot-citation://source/n`. Unknown numbers stay plain text. While
    /// streaming, a marker cut off at the end is held back until it completes.
    public static func linkedMarkdown(_ answer: String, valid: Set<Int>, streaming: Bool = false) -> String {
        var text = answer
        if streaming, let tail = partialTail.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
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

    /// The answer without markers, for copying and for VoiceOver.
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

    private struct Match {
        let range: Range<String.Index>
        let numbers: [Int]
    }

    private static func matches(in text: String) -> [Match] {
        marker.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { result in
            guard let range = Range(result.range, in: text),
                  let inner = Range(result.range(at: 1), in: text) else { return nil }
            let numbers = text[inner].split(separator: ",").compactMap {
                Int($0.trimmingCharacters(in: .whitespaces))
            }
            return Match(range: range, numbers: numbers)
        }
    }
}
