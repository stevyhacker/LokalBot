import Foundation

/// What saved meeting notes say about one person, and the projects named
/// around them. Deterministic line matching over summaries already on this
/// Mac; no model reads anything here.
enum PersonNotes {
    static let maximumPoints = 3
    /// Newest meetings searched for notes about the person.
    static let maximumMeetingsSearched = 8
    /// Meetings whose lines can link the person to a project.
    static let projectMeetingsSearched = 20
    static let maximumProjects = 5

    /// One bullet from a summary.
    struct SummaryLine: Equatable, Sendable {
        /// The heading it sits under, folded ("key points").
        let section: String
        /// The speaker label as written ("Them 4", "You", "Ana").
        let speaker: String?
        let text: String
        let seek: TimeInterval?
    }

    /// Sections already shown elsewhere on a person's page (actions and
    /// decisions), or that only restate the meeting's facts.
    private static let skippedSections: Set<String> = [
        "action items", "actions", "next steps", "decisions", "follow ups", "follow up",
    ]

    /// Sections that sum the meeting up, for a meeting that is only with
    /// the person.
    private static let overviewSections: Set<String> = ["tl dr", "tldr", "summary", "overview", "key points"]

    // MARK: - Summary lines

    static func lines(fromSummary markdown: String) -> [SummaryLine] {
        var result: [SummaryLine] = []
        var section = ""
        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                section = PeopleDirectory.normalized(String(line.dropFirst(3)))
                continue
            }
            guard !skippedSections.contains(section),
                  line.hasPrefix("- ") || line.hasPrefix("* ") else { continue }
            var body = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            // Checkbox bullets are actions.
            guard !body.hasPrefix("["), !body.isEmpty else { continue }
            let seek = trailingTimestamp(&body)
            let speaker = leadingSpeaker(&body)
            let text = shortened(body.replacingOccurrences(of: "**", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines))
            guard text.count >= 12, PeopleDirectory.normalized(text) != "none" else { continue }
            result.append(SummaryLine(section: section, speaker: speaker, text: text, seek: seek))
        }
        return result
    }

    private static let stamp = #"\[\d{1,2}(?::\d{2}){1,2}\]"#

    /// Removes the transcript stamps notes carry — a trailing
    /// "— [00:01:54]", a range "([00:40:44]–[00:44:40])", or stamps inside
    /// the line — and returns the first one as the moment to open.
    private static func trailingTimestamp(_ body: inout String) -> TimeInterval? {
        var first: TimeInterval?
        if let range = body.range(of: stamp, options: .regularExpression) {
            let numbers = body[range].dropFirst().dropLast().split(separator: ":").compactMap { Double($0) }
            first = numbers.reduce(0) { $0 * 60 + $1 }
        }
        let trailing: String = #"\s*(?:[—–-]\s*)?\(?\s*\#(stamp)(?:\s*[,–—-]?\s*\#(stamp))*\s*\)?\s*$"#
        if let range = body.range(of: trailing, options: .regularExpression) { body.removeSubrange(range) }
        let inline: String = #"\s*\(?\#(stamp)(?:\s*[–—-]\s*\#(stamp))?\)?"#
        body = body.replacingOccurrences(of: inline, with: "", options: .regularExpression)
        return first
    }

    /// Long notes are cut at a word near this length.
    static let maximumCharacters = 280

    private static func shortened(_ text: String) -> String {
        guard text.count > maximumCharacters else { return text }
        let cut = text.prefix(maximumCharacters)
        let end = cut.lastIndex(of: " ") ?? cut.endIndex
        return cut[..<end].trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)) + "…"
    }

    /// Removes a leading "**Them 4:**" (or a bare "Them 4:") speaker label.
    private static func leadingSpeaker(_ body: inout String) -> String? {
        if let range = body.range(of: #"^\*\*[^*]{1,48}?:\*\*\s*"#, options: .regularExpression) {
            let label = body[range].replacingOccurrences(of: "**", with: "")
                .trimmingCharacters(in: .whitespaces).dropLast()
            body.removeSubrange(range)
            return String(label).trimmingCharacters(in: .whitespaces)
        }
        if let range = body.range(of: #"^[A-Za-z]+(?: \d+)?:\s+"#, options: .regularExpression) {
            let label = body[range].trimmingCharacters(in: .whitespaces).dropLast()
            let candidate = String(label)
            guard PeopleDirectory.isPlaceholder(candidate) || isUserLabel(candidate) else { return nil }
            body.removeSubrange(range)
            return candidate
        }
        return nil
    }

    private static func isUserLabel(_ label: String) -> Bool {
        ["you", "me"].contains(PeopleDirectory.normalized(label))
    }

    // MARK: - Lines about a person

    /// A summary line said by the person or naming them, as shown on their
    /// page; nil when the line is about someone else.
    static func point(_ line: SummaryLine, meetingID: UUID, person: PersonProfile,
                      applied: MeetingAppliedSpeakerNames?) -> PersonProfile.NotePoint? {
        let names = [person.name] + person.otherNames
        let speakerName = line.speaker.flatMap { label -> String? in
            if let applied = applied?.name(forSpeaker: label) { return applied }
            return PeopleDirectory.isPlaceholder(label) || isUserLabel(label) ? nil : label
        }
        if let speakerName, isPerson(speakerName, names: names) {
            return .init(text: line.text, speaker: nil, meetingID: meetingID, seek: line.seek)
        }
        guard names.contains(where: { mayName($0, line.text) && PeopleDirectory.isNamed($0, in: line.text) }) else {
            return nil
        }
        let speaker = line.speaker.map(isUserLabel) == true ? "You" : speakerName
        return .init(text: line.text, speaker: speaker, meetingID: meetingID, seek: line.seek)
    }

    /// The newest meeting whose notes say something about the person, with
    /// up to three lines. A meeting only with them (at most
    /// `PeopleDirectory.smallMeetingSize` others) offers its overview lines
    /// when no line names them.
    static func recentNotes(for person: PersonProfile, lines: [UUID: [SummaryLine]],
                            appliedNames: [UUID: MeetingAppliedSpeakerNames]) -> PersonProfile.RecentNotes? {
        let occasions = person.occasions
        for (index, occasion) in occasions.prefix(maximumMeetingsSearched).enumerated() {
            let recordings = [occasion.primary] + occasion.recordings.filter { $0.id != occasion.primary.id }
            var points: [PersonProfile.NotePoint] = []
            var overview: [PersonProfile.NotePoint] = []
            var seen: Set<String> = []
            for recording in recordings {
                for line in lines[recording.id] ?? [] {
                    let key = PeopleDirectory.normalized(line.text)
                    if let point = point(line, meetingID: recording.id, person: person,
                                         applied: appliedNames[recording.id]) {
                        if seen.insert(key).inserted { points.append(point) }
                    } else if overviewSections.contains(line.section), !seen.contains(key) {
                        overview.append(.init(text: line.text, speaker: nil, meetingID: recording.id, seek: line.seek))
                    }
                }
            }
            let isOneOnOne = (1...PeopleDirectory.smallMeetingSize).contains(occasion.primary.participantCount)
            if points.isEmpty && isOneOnOne { points = uniqued(overview) }
            guard !points.isEmpty else { continue }
            return .init(meetingID: occasion.primary.id, meetingTitle: occasion.title,
                         meetingDate: occasion.startedAt, isLatestMeeting: index == 0,
                         points: Array(points.prefix(maximumPoints)))
        }
        return nil
    }

    // MARK: - Projects

    /// Projects whose names appear in the person's own lines, the lines
    /// naming them, their open work, and decisions with them. Tracked
    /// projects first, then by how often they come up.
    static func projects(for person: PersonProfile, lines: [UUID: [SummaryLine]],
                         appliedNames: [UUID: MeetingAppliedSpeakerNames],
                         projects: [ProjectProfile]) -> [PersonProfile.ProjectLink] {
        guard !projects.isEmpty else { return [] }
        var texts: [String] = []
        for occasion in person.occasions.prefix(projectMeetingsSearched) {
            for recording in occasion.recordings {
                for line in lines[recording.id] ?? [] {
                    if point(line, meetingID: recording.id, person: person, applied: appliedNames[recording.id]) != nil {
                        texts.append(line.text)
                    }
                }
            }
        }
        for thread in person.theirActions { texts.append(thread.text) }
        for thread in person.myActions { texts.append(thread.text) }
        for decision in person.decisions { texts.append(decision.text) }
        guard !texts.isEmpty else { return [] }
        let words: [Set<String>] = texts.map(ProjectLinks.words)

        var links: [PersonProfile.ProjectLink] = []
        for project in projects {
            let termSets: [Set<String>] = ([project.name] + project.otherNames).map(ProjectLinks.significantTerms)
            let mentions = words.filter { ProjectLinks.matches(termSets, words: $0) }.count
            guard mentions > 0 else { continue }
            links.append(.init(id: project.id, name: project.name, isTracked: project.isTracked, mentions: mentions))
        }
        let sorted = links.sorted {
            if $0.isTracked != $1.isTracked { return $0.isTracked }
            if $0.mentions != $1.mentions { return $0.mentions > $1.mentions }
            return $0.name < $1.name
        }
        return Array(sorted.prefix(maximumProjects))
    }

    // MARK: - Helpers

    private static func isPerson(_ speaker: String, names: [String]) -> Bool {
        let key = PeopleDirectory.normalized(PeopleDirectory.cleanedName(speaker))
        guard !key.isEmpty else { return false }
        return names.contains { name in
            let candidate = PeopleDirectory.normalized(name)
            return candidate == key || (!key.contains(" ") && key.count >= 3
                && candidate.split(separator: " ").first.map(String.init) == key)
        }
    }

    /// A cheap check before the word-by-word one.
    private static func mayName(_ name: String, _ text: String) -> Bool {
        guard let first = name.split(separator: " ").first else { return false }
        return text.range(of: first, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    private static func uniqued(_ points: [PersonProfile.NotePoint]) -> [PersonProfile.NotePoint] {
        var seen: Set<String> = []
        return points.filter { seen.insert(PeopleDirectory.normalized($0.text)).inserted }
    }
}
