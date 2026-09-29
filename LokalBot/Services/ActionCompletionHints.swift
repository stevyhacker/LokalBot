import Foundation

/// A suggestion, never a status change: a later screen capture that looks
/// like the user finished one of their open actions. The user confirms with
/// Mark Done, or dismisses it so the same capture is not offered again.
struct ActionCompletionHint: Identifiable, Equatable, Sendable {
    let threadID: String
    let snapshotID: Int64
    let capturedAt: Date
    let app: String
    let title: String
    let cue: String

    var id: String { threadID }
    var dismissalKey: String { "\(threadID)#\(snapshotID)" }
}

/// Deterministic matching of open actions to later screen captures. A hint
/// needs two things in the same capture after the action was last
/// mentioned: at least two of the action's distinctive words, and a
/// completion phrase that fits the action's verb ("message sent", "merged",
/// "submitted"). Only locally retained screen text and titles are read.
enum ActionCompletionDetector {
    static let maximumThreads = 60
    static let hitsPerThread = 6
    static let minimumMatchingTerms = 2

    struct Capture: Equatable, Sendable {
        let snapshotID: Int64
        let capturedAt: Date
        let app: String
        let title: String
        let text: String
    }

    /// Distinctive words: not stop words or generic task verbs, and either
    /// four or more letters, containing a digit, or capitalized in the source.
    static func distinctiveTerms(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { word in
                let lower = word.lowercased()
                guard !stopWords.contains(lower), !genericVerbs.contains(lower) else { return false }
                let hasDigit = word.contains { $0.isNumber }
                let isCapitalized = word.first?.isUppercase == true
                return lower.count >= 4 || (hasDigit && lower.count >= 2) || (isCapitalized && lower.count >= 3)
            }
            .map { $0.lowercased() }
            .filter { seen.insert($0).inserted }
    }

    /// Completion phrases for the action's verb, falling back to a general
    /// set when the verb is unfamiliar.
    static func cues(for actionText: String) -> [String] {
        let words = Set(actionText.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
        var result: [String] = []
        for (verbs, phrases) in cueFamilies where !words.isDisjoint(with: verbs) {
            result += phrases
        }
        return result.isEmpty ? generalCues : result
    }

    static func cue(in capture: Capture, cues: [String]) -> String? {
        let haystack = (capture.title + "\n" + capture.text).lowercased()
        return cues.first { phrase in
            haystack.range(of: #"(?<![\p{L}\p{N}])"# + NSRegularExpression.escapedPattern(for: phrase)
                           + #"(?![\p{L}\p{N}])"#, options: .regularExpression) != nil
        }
    }

    static func matches(_ capture: Capture, terms: [String]) -> Bool {
        guard terms.count >= minimumMatchingTerms else { return false }
        let words = Set((capture.title + "\n" + capture.text).lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        return terms.filter { words.contains($0) }.count >= minimumMatchingTerms
    }

    /// Evaluate threads against captures already fetched for them.
    static func hint(for thread: ActionThread, captures: [Capture],
                     dismissed: Set<String>) -> ActionCompletionHint? {
        guard thread.isForUser, thread.status == .open else { return nil }
        let terms = distinctiveTerms(thread.text)
        guard terms.count >= minimumMatchingTerms else { return nil }
        let since = thread.latestReference.meetingStartedAt
        let cues = cues(for: thread.text)
        for capture in captures.sorted(by: { $0.capturedAt > $1.capturedAt })
            where capture.capturedAt > since {
            guard !dismissed.contains("\(thread.id)#\(capture.snapshotID)"),
                  matches(capture, terms: terms),
                  let cue = cue(in: capture, cues: cues) else { continue }
            return ActionCompletionHint(
                threadID: thread.id, snapshotID: capture.snapshotID, capturedAt: capture.capturedAt,
                app: capture.app, title: capture.title, cue: cue)
        }
        return nil
    }

    /// Queries a read-only screen store per open thread. Runs off the main
    /// actor; the caller supplies a store opened read-only.
    static func hints(for threads: [ActionThread], store: ActivityStore,
                      dismissed: Set<String>, now: Date = Date()) -> [String: ActionCompletionHint] {
        var result: [String: ActionCompletionHint] = [:]
        for thread in threads.filter({ $0.isForUser && $0.status == .open }).prefix(maximumThreads) {
            let terms = distinctiveTerms(thread.text)
            guard terms.count >= minimumMatchingTerms else { continue }
            let since = thread.latestReference.meetingStartedAt
            guard since < now else { continue }
            let filter = ScreenSearchFilter(interval: DateInterval(start: since, end: now))
            let hits = store.searchOCR(terms.prefix(4).joined(separator: " "), limit: hitsPerThread,
                                       matchAll: false, filter: filter, groupResults: false)
            let captures = hits.map { hit in
                Capture(snapshotID: hit.snapshotID, capturedAt: hit.ts, app: hit.app,
                        title: hit.windowTitle,
                        text: store.ocrText(snapshotID: hit.snapshotID, maxChars: 4_000) ?? hit.snippet)
            }
            if let hint = hint(for: thread, captures: captures, dismissed: dismissed) {
                result[thread.id] = hint
            }
        }
        return result
    }

    // MARK: - Vocabulary

    private static let stopWords: Set<String> = [
        "the", "and", "for", "with", "from", "into", "onto", "about", "this", "that", "these",
        "those", "their", "them", "they", "your", "yours", "mine", "have", "will", "would",
        "should", "could", "before", "after", "next", "week", "today", "tomorrow", "friday",
        "monday", "tuesday", "wednesday", "thursday", "saturday", "sunday", "until", "also",
        "some", "more", "over", "back", "then", "when", "what", "which", "make", "sure",
        "please", "need", "needs", "still",
    ]

    private static let genericVerbs: Set<String> = [
        "send", "sends", "share", "shares", "review", "prepare", "update", "follow", "check",
        "schedule", "book", "draft", "write", "finish", "complete", "look", "take", "give",
        "provide", "create", "file", "submit", "merge", "publish", "post", "email", "reply",
        "forward", "ping", "call", "confirm", "approve", "deploy", "release", "fix", "open",
        "close", "resolve", "invite", "set", "add", "move", "get", "find", "ask",
    ]

    private static let cueFamilies: [(Set<String>, [String])] = [
        (["send", "email", "mail", "reply", "forward", "ping", "message"],
         ["message sent", "has been sent", "was sent", "email sent", "sent to", "sent mail", "sent messages"]),
        (["share", "invite"],
         ["shared with", "now has access", "invitation sent", "invite sent", "link copied"]),
        (["merge", "pr", "pull", "land"],
         ["merged", "successfully merged", "pull request merged"]),
        (["submit", "file", "apply", "upload"],
         ["submitted", "submission received", "successfully submitted", "uploaded"]),
        (["publish", "post", "deploy", "release", "ship"],
         ["published", "deployed", "released", "is live", "posted"]),
        (["schedule", "book", "reserve", "calendar"],
         ["event created", "invitation sent", "added to calendar", "booked", "confirmed", "reservation confirmed"]),
        (["review", "approve"],
         ["approved", "review submitted", "changes approved"]),
        (["fix", "resolve", "close", "finish", "complete"],
         ["resolved", "marked as done", "completed", "closed", "fixed"]),
    ]

    private static let generalCues = [
        "marked as done", "completed", "resolved", "has been sent", "message sent",
        "submitted", "merged", "published",
    ]
}
