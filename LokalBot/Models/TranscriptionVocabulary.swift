import Foundation

/// Names and terms LokalBot already knows, offered to speech models that
/// accept a vocabulary prompt (Whisper and Qwen). Every source is local and
/// already part of the library: calendar attendee display names (never
/// addresses or names derived from addresses), speaker names the user applied
/// in related meetings, Dream project names, and distinctive meeting-title
/// terms. Speaker evidence, suggestions, and voice-profile links are not read.
enum TranscriptionVocabulary {
    static let fileName = "transcription-vocabulary.json"
    static let maximumTerms = 40
    static let maximumCharacters = 480
    static let maximumRelatedMeetings = 8

    struct Sources: Equatable, Sendable {
        var attendeeNames: [String] = []
        var appliedSpeakerNames: [String] = []
        var projectNames: [String] = []
        var titleTerms: [String] = []
    }

    /// Per-meeting record so crash resumes and retries use the same prompt
    /// (and therefore reuse transcription checkpoints) even if the library
    /// changes in between.
    struct Record: Codable, Equatable, Sendable {
        var version = 1
        var terms: [String]
        var createdAt: Date
    }

    // MARK: - Assembly

    /// Priority order: attendees, then names the user applied before, then
    /// projects, then title terms. Deduplicated case- and accent-insensitively
    /// and bounded so the prompt never crowds out the audio context.
    static func terms(_ sources: Sources) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        var characters = 0
        let ordered = sources.attendeeNames + sources.appliedSpeakerNames
            + sources.projectNames + sources.titleTerms
        for raw in ordered {
            let term = raw.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            guard (2...60).contains(term.count), !isPlaceholderName(term) else { continue }
            let key = term.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            guard seen.insert(key).inserted else { continue }
            guard result.count < maximumTerms,
                  characters + term.count + 2 <= maximumCharacters else { break }
            result.append(term)
            characters += term.count + 2
        }
        return result
    }

    /// The user's own vocabulary stays first and verbatim; known terms follow.
    static func prompt(manual: String, terms: [String]) -> String {
        let manual = manual.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !terms.isEmpty else { return manual }
        let known = terms.joined(separator: ", ") + "."
        return manual.isEmpty ? known : manual + "\n" + known
    }

    static func sources(for meeting: Meeting, library: [Meeting], root: URL,
                        memory: DreamMemory?) -> Sources {
        var sources = Sources()
        sources.attendeeNames = meeting.resolvedCalendarParticipantIdentities.compactMap(\.name)
        let attendeeKeys = Set(sources.attendeeNames.map(normalizedKey))
        let seriesTitle = normalizedKey(meeting.calendarTitle ?? meeting.title)
        let related = library
            .filter { candidate in
                guard candidate.id != meeting.id, candidate.startedAt < meeting.startedAt,
                      candidate.mergedIntoMeetingID == nil else { return false }
                let names = Set(candidate.resolvedCalendarParticipantIdentities
                    .compactMap(\.name).map(normalizedKey))
                let sameSeries = !seriesTitle.isEmpty
                    && normalizedKey(candidate.calendarTitle ?? candidate.title) == seriesTitle
                    && !isGenericTitle(seriesTitle)
                return sameSeries || !names.isDisjoint(with: attendeeKeys)
            }
            .sorted { $0.startedAt > $1.startedAt }
            .prefix(maximumRelatedMeetings)
        for candidate in related {
            let url = root.appendingPathComponent(candidate.relativePath, isDirectory: true)
                .appendingPathComponent("transcript.json")
            guard let data = try? Data(contentsOf: url),
                  let transcript = try? JSONDecoder().decode(Transcript.self, from: data) else { continue }
            sources.appliedSpeakerNames += transcript.speakerAliases.values.sorted()
        }
        if let memory {
            sources.projectNames = memory.activeProjects.map(\.name)
        }
        sources.titleTerms = titleTerms(meeting.calendarTitle ?? meeting.title)
        return sources
    }

    /// Recent attendee names and projects for dictation, which has no
    /// meeting of its own. Most frequently met people come first.
    static func recentSources(library: [Meeting], memory: DreamMemory?,
                              now: Date = Date(), days: Int = 45) -> Sources {
        let cutoff = now.addingTimeInterval(-TimeInterval(days) * 86_400)
        var counts: [String: (name: String, count: Int, last: Date)] = [:]
        for meeting in library where meeting.startedAt >= cutoff && meeting.mergedIntoMeetingID == nil {
            for name in meeting.resolvedCalendarParticipantIdentities.compactMap(\.name) {
                let key = normalizedKey(name)
                let previous = counts[key]
                counts[key] = (name, (previous?.count ?? 0) + 1, max(previous?.last ?? .distantPast, meeting.startedAt))
            }
        }
        var sources = Sources()
        sources.attendeeNames = counts.values.sorted {
            $0.count == $1.count ? $0.last > $1.last : $0.count > $1.count
        }.map(\.name)
        sources.projectNames = memory?.activeProjects.map(\.name) ?? []
        return sources
    }

    // MARK: - Persistence

    static func load(from folder: URL) -> Record? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(fileName)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Record.self, from: data)
    }

    static func save(_ record: Record, to folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: folder.appendingPathComponent(fileName), options: .atomic)
    }

    // MARK: - Helpers

    private static let genericTitleWords: Set<String> = [
        "all", "and", "call", "catch", "check", "daily", "demo", "for", "hands", "in",
        "kickoff", "meeting", "monthly", "office", "hours", "on", "one", "planning",
        "quarterly", "retro", "review", "standup", "stand", "up", "sync", "team", "the",
        "to", "up", "weekly", "with", "workshop", "interview", "onboarding", "update",
    ]

    /// Capitalized or mixed-case words and acronyms from a title ("Acme",
    /// "iOS", "SDK") are likely names worth spelling; generic words are not.
    static func titleTerms(_ title: String) -> [String] {
        title.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "-" && $0 != "'" })
            .map(String.init)
            .filter { word in
                guard word.count >= 2, !genericTitleWords.contains(word.lowercased()) else { return false }
                guard word.rangeOfCharacter(from: .letters) != nil else { return false }
                let hasUpper = word.rangeOfCharacter(from: .uppercaseLetters) != nil
                let isCapitalized = word.first?.isUppercase == true
                let hasInnerUpper = word.dropFirst().contains { $0.isUppercase }
                return hasUpper && (isCapitalized || hasInnerUpper)
            }
    }

    private static func isGenericTitle(_ normalizedTitle: String) -> Bool {
        normalizedTitle.split(separator: " ").allSatisfy { genericTitleWords.contains(String($0)) }
    }

    /// Placeholder speaker labels carry no spelling value.
    private static func isPlaceholderName(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return ["me", "you", "them", "speaker", "other speaker", "unknown", "remote"].contains(lowered)
            || lowered.range(of: #"^speaker \d+$"#, options: .regularExpression) != nil
    }

    private static func normalizedKey(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
