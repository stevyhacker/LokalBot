import Foundation

/// Finds the proper nouns that recur across meetings (products, protocols,
/// clients, codenames) so Projects has useful content even when the overnight
/// review has not named any projects. Deterministic and local: it counts
/// capitalized terms in meeting titles, summaries, actions, and decisions,
/// and keeps only terms that are nearly always capitalized, appear in several
/// meetings, and are not people, apps, or generic work vocabulary.
enum ProjectTopicDetector {
    static let minimumMeetings = 3
    static let maximumTopics = 8

    struct Topic: Equatable, Sendable {
        let name: String
        let meetingIDs: Set<UUID>
        let lastMentioned: Date
    }

    static func topics(meetings: [Meeting], summaries: [UUID: String],
                       projections: [MeetingOutcomeProjection],
                       excludedWords: Set<String>) -> [Topic] {
        let projectionByMeeting = Dictionary(
            projections.map { ($0.meeting.id, $0) }, uniquingKeysWith: { first, _ in first })
        var surfaceForms: [String: [String: Int]] = [:]
        var meetingsByTerm: [String: Set<UUID>] = [:]
        var lastMentioned: [String: Date] = [:]
        var capitalizedCount: [String: Int] = [:]
        var lowercaseCount: [String: Int] = [:]
        let excluded = Set(excludedWords.map { $0.lowercased() }).union(stopWords).union(commonApps)

        func record(_ word: String, meeting: Meeting) {
            let key = word.lowercased()
            guard word.count >= 3, !excluded.contains(key),
                  word.rangeOfCharacter(from: .uppercaseLetters) != nil,
                  word.rangeOfCharacter(from: .letters) != nil else { return }
            capitalizedCount[key, default: 0] += 1
            surfaceForms[key, default: [:]][word, default: 0] += 1
            meetingsByTerm[key, default: []].insert(meeting.id)
            lastMentioned[key] = max(lastMentioned[key] ?? .distantPast, meeting.startedAt)
        }

        func scan(_ text: String, meeting: Meeting, skipSentenceStart: Bool) {
            for sentence in text.components(separatedBy: CharacterSet(charactersIn: ".!?:;\n")) {
                let words = tokens(sentence)
                for (index, word) in words.enumerated() {
                    if word == word.lowercased() {
                        lowercaseCount[word, default: 0] += 1
                        continue
                    }
                    if skipSentenceStart, index == 0 { continue }
                    record(word, meeting: meeting)
                }
            }
        }

        for meeting in meetings where meeting.mergedIntoMeetingID == nil {
            scan(meeting.calendarTitle ?? meeting.title, meeting: meeting, skipSentenceStart: false)
            if let summary = summaries[meeting.id] { scan(summaryBody(summary), meeting: meeting, skipSentenceStart: true) }
            if let projection = projectionByMeeting[meeting.id] {
                let texts = projection.actionReferences.map(\.text)
                    + projection.outcomes.decisionRecords.map(\.text)
                for text in texts { scan(text, meeting: meeting, skipSentenceStart: true) }
            }
        }

        return meetingsByTerm.compactMap { key, meetingIDs -> Topic? in
            guard meetingIDs.count >= minimumMeetings,
                  capitalizedCount[key, default: 0] >= 3 * lowercaseCount[key, default: 0],
                  let form = surfaceForms[key]?.max(by: { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value })?.key
            else { return nil }
            return Topic(name: form, meetingIDs: meetingIDs, lastMentioned: lastMentioned[key] ?? .distantPast)
        }
        .sorted {
            if $0.meetingIDs.count != $1.meetingIDs.count { return $0.meetingIDs.count > $1.meetingIDs.count }
            if $0.lastMentioned != $1.lastMentioned { return $0.lastMentioned > $1.lastMentioned }
            return $0.name < $1.name
        }
        .prefix(maximumTopics)
        .map { $0 }
    }

    static func tokens(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        for character in text {
            if character.isLetter || character.isNumber || (character == "-" && !current.isEmpty) {
                current.append(character)
            } else if !current.isEmpty {
                words.append(current.trimmingCharacters(in: CharacterSet(charactersIn: "-")))
                current = ""
            }
        }
        if !current.isEmpty { words.append(current.trimmingCharacters(in: CharacterSet(charactersIn: "-"))) }
        return words.filter { !$0.isEmpty }
    }

    /// Summary text without the generated title and metadata lines.
    private static func summaryBody(_ summary: String) -> String {
        summary.components(separatedBy: "\n")
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.hasPrefix("# ") && !trimmed.contains("**Duration:**")
                    && !trimmed.contains("**Template:**") && !trimmed.contains("**Model:**")
            }
            .joined(separator: "\n")
    }

    /// Apps and services people mention without it being their project.
    static let commonApps: Set<String> = [
        "chrome", "google", "safari", "firefox", "slack", "zoom", "discord", "telegram", "notion",
        "github", "gitlab", "figma", "claude", "chatgpt", "openai", "anthropic", "cursor", "xcode",
        "finder", "meet", "teams", "microsoft", "apple", "mac", "macos", "ios", "iphone", "android",
        "whatsapp", "viber", "signal", "spotify", "youtube", "twitter", "linkedin", "gmail", "calendar",
        "jira", "linear", "loom", "docs", "sheets", "drive", "dropbox", "vscode", "zed",
    ]

    private static let stopWords: Set<String> = [
        // Function words and sentence starters.
        "the", "and", "for", "with", "from", "into", "onto", "about", "after", "before", "this", "that",
        "these", "those", "its", "our", "your", "their", "they", "them", "she", "his", "her", "him",
        "are", "was", "were", "been", "being", "does", "did", "done", "have", "has", "had", "will",
        "would", "should", "could", "can", "may", "might", "must", "not", "yes", "all", "any", "some",
        "each", "every", "both", "either", "neither", "other", "another", "such", "only", "also",
        "just", "very", "more", "most", "less", "least", "many", "much", "few", "first", "last",
        "next", "new", "old", "same", "different", "own", "there", "here", "then", "than", "when",
        "where", "what", "which", "who", "why", "how", "once", "while", "until", "because", "per",
        "via", "but", "nor", "yet", "please", "thanks", "thank", "okay",
        // Dates and times.
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "january",
        "february", "march", "april", "june", "july", "august", "september", "october", "november",
        "december", "today", "tomorrow", "yesterday", "week", "weekly", "daily", "monthly", "quarter",
        // Meeting and notes vocabulary.
        "key", "points", "decisions", "decision", "action", "actions", "items", "item", "open",
        "questions", "question", "summary", "recap", "notes", "note", "steps", "step", "template",
        "language", "duration", "model", "words", "meeting", "meetings", "team", "discussion",
        "update", "updates", "review", "plan", "planning", "sync", "standup", "stand-up", "demo",
        "day", "call", "product", "agenda", "follow-up", "followup", "owner", "owners", "local",
        "speaker", "source", "unknown", "likely", "agreed", "discussed", "confirmed", "need", "needs",
        "check", "share", "send", "look", "ask", "set", "add", "use", "make", "keep", "get", "tldr",
        // Generic technical acronyms.
        "api", "apis", "json", "sdk", "prs", "llm", "llms", "poc", "mvp", "eta", "ui", "ux", "url",
        "urls", "http", "https", "sql", "csv", "pdf", "ids", "okr", "okrs", "kpi", "kpis", "gpu",
        "cpu", "ram", "eod", "eow", "fyi", "tbd", "utc", "cet", "cest", "usd", "eur", "moe", "qa",
        "faq", "etc", "asap", "cto", "ceo", "cfo", "dev", "devs", "ops", "repo", "repos", "doc",
    ]
}
