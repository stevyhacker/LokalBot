import Foundation

enum OutcomeProse {
    static func hasFirstPersonSubject(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).range(
            of: #"^(?:i(?:\s|['’](?:ll|m|ve|d)\b)|my\s)"#,
            options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func firstPersonSubject(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let possessive = trimmed.replacingOccurrences(
            of: #"^me['’]s\b"#,
            with: "My",
            options: [.regularExpression, .caseInsensitive])
        return possessive.replacingOccurrences(
            of: #"^me\b"#,
            with: "I",
            options: [.regularExpression, .caseInsensitive])
    }

    static func actionText(_ text: String, isForUser: Bool) -> String {
        isForUser ? firstPersonSubject(text) : text
    }
}
