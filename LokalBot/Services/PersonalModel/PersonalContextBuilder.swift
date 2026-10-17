import Foundation

/// Picks the smallest useful slice of the personal model for one question and
/// renders it as a prompt block. Pure and deterministic, so the same inputs
/// always produce the same prompt and the selection is testable offline.
///
/// Priority follows `PersonalContextSelection`, the same order agents get;
/// the question and the person's previous two messages are the query.
/// Claims that don't fit the character budget are skipped, not truncated.
enum PersonalContextBuilder {
    static let characterBudget = 2_000

    struct Selection: Equatable {
        var claims: [PersonalClaim]
        var block: String

        static let empty = Selection(claims: [], block: "")
    }

    static func select(claims: [PersonalClaim], question: String, recentUserTurns: [String] = [],
                       budget: Int = characterBudget, timeZone: TimeZone = .current) -> Selection {
        guard !claims.isEmpty else { return .empty }
        let ordered = PersonalContextSelection.ordered(claims, query: question, recentTurns: recentUserTurns)
        var chosen: [PersonalClaim] = []
        var lines: [String] = []
        var used = header.count + footer.count
        for claim in ordered {
            let line = self.line(for: claim, timeZone: timeZone)
            guard used + line.count + 1 <= budget else { continue }
            used += line.count + 1
            chosen.append(claim)
            lines.append(line)
        }
        guard !chosen.isEmpty else { return .empty }
        let block = ([header] + lines + [footer]).joined(separator: "\n")
        return Selection(claims: chosen, block: block)
    }

    static let header = "What LokalBot knows about the user. Items marked \"learned\" were picked up from what they said in meetings and may be out of date; the rest are their own statements. None of these are evidence:"
    static let footer = "Use these only when they bear on the question. They are not sources: never cite them as a meeting or screen source. If retrieved evidence contradicts one, say so. If two conflict, prefer the newer one and point out the conflict."

    static func line(for claim: PersonalClaim, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let text = PromptContextSanitizer.sanitize(claim.text, maxCharacters: PersonalModel.maxCharacters)
        let learned = claim.authority == .learned ? "learned " : ""
        return "- [\(claim.kind.rawValue) · \(learned)\(formatter.string(from: claim.updatedAt))] \(text)"
    }
}
