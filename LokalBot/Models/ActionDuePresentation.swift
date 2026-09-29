import Foundation

enum ActionDuePresentation {
    /// ISO dates and supported relative phrases resolve against the day they
    /// were said (or corrected). Anything else stays unresolved rather than
    /// guessed, and keeps the phrase with its source date.
    static func date(_ phrase: String?, spokenAt: Date) -> Date? {
        ActionDueResolver.resolve(phrase, spokenAt: spokenAt)
    }

    static func label(_ phrase: String, spokenAt: Date) -> String {
        guard let date = date(phrase, spokenAt: spokenAt) else {
            return "\(phrase) — said on \(spokenAt.formatted(date: .abbreviated, time: .omitted))"
        }
        let resolved = date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        if isExplicitDate(phrase) { return "Due \(resolved)" }
        return "Due \(resolved) · said “\(phrase.trimmingCharacters(in: .whitespacesAndNewlines))”"
    }

    private static func isExplicitDate(_ phrase: String) -> Bool {
        phrase.trimmingCharacters(in: .whitespacesAndNewlines)
            .range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
    }
}
