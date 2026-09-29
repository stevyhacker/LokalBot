import Foundation

/// Read-only People directory for the CLI and MCP server, built with the
/// same rules as the app. Only names appear; attendee email addresses are
/// used as private join keys and never leave the directory builder.
enum PeopleReport {
    static let maximumEntries = 200

    struct Summary: Encodable, Equatable {
        let id: String
        let name: String
        let other_names: [String]
        let meeting_count: Int
        let last_met: String?
        let you_owe: Int
        let they_owe: Int
    }

    struct DecisionEntry: Encodable, Equatable {
        let text: String
        let meeting_id: String
        let meeting_title: String
        let date: String
    }

    struct Detail: Encodable, Equatable {
        let id: String
        let name: String
        let other_names: [String]
        let you_owe: [ActionItemsReport.Entry]
        let they_owe: [ActionItemsReport.Entry]
        let decisions: [DecisionEntry]
        let meetings: [ActionItemsReport.MeetingRef]
    }

    static func people(meetings: [Meeting], root: URL, now: Date = Date()) -> [PersonProfile] {
        let projections = meetings.compactMap { MeetingOutcomeProjection.load(for: $0, root: root) }
        return PeopleDirectory.build(.init(
            meetings: meetings, projections: projections,
            appliedNames: PeopleDirectory.loadAppliedNames(for: meetings, root: root)), now: now)
    }

    /// Opaque id, exact name, then a unique case-insensitive substring match.
    static func find(_ needle: String, in people: [PersonProfile]) -> PersonProfile? {
        let trimmed = needle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let byID = people.first(where: { $0.id == trimmed }) { return byID }
        let key = PeopleDirectory.normalized(trimmed)
        let exact = people.filter { ([$0.name] + $0.otherNames).map(PeopleDirectory.normalized).contains(key) }
        if exact.count == 1 { return exact[0] }
        let partial = people.filter { ([$0.name] + $0.otherNames).contains { $0.localizedCaseInsensitiveContains(trimmed) } }
        return partial.count == 1 ? partial[0] : nil
    }

    static func summaries(_ people: [PersonProfile], query: String? = nil, limit: Int = 50) -> [Summary] {
        let needle = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return people
            .filter { needle.isEmpty || ([$0.name] + $0.otherNames).contains { $0.localizedCaseInsensitiveContains(needle) } }
            .prefix(max(1, min(limit, maximumEntries)))
            .map { person in
                Summary(
                    id: person.id, name: person.name, other_names: person.otherNames,
                    meeting_count: person.meetings.count,
                    last_met: person.lastMetAt.map { SessionFormatter.iso8601.string(from: $0) },
                    you_owe: person.myActions.count, they_owe: person.theirActions.count)
            }
    }

    static func detail(_ person: PersonProfile, now: Date = Date()) -> Detail {
        Detail(
            id: person.id, name: person.name, other_names: person.otherNames,
            you_owe: person.myActions.map { ActionItemsReport.entry(for: $0, now: now) },
            they_owe: person.theirActions.map { ActionItemsReport.entry(for: $0, now: now) },
            decisions: person.decisions.map {
                DecisionEntry(text: $0.text, meeting_id: SessionLookup.shortID($0.meetingID),
                              meeting_title: $0.meetingTitle,
                              date: SessionFormatter.iso8601.string(from: $0.meetingDate))
            },
            meetings: person.meetings.prefix(20).map {
                ActionItemsReport.MeetingRef(id: SessionLookup.shortID($0.id), title: $0.title,
                                             date: SessionFormatter.iso8601.string(from: $0.startedAt))
            })
    }

    static func json<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? String(data: encoder.encode(value), encoding: .utf8)) ?? "null"
    }

    static func table(_ summaries: [Summary]) -> String {
        guard !summaries.isEmpty else { return "(no people)" }
        return SessionFormatter.renderTable(
            header: ["Name", "Meetings", "Last met", "You owe", "They owe"],
            rows: summaries.map {
                [$0.name, String($0.meeting_count), $0.last_met.map { String($0.prefix(10)) } ?? "",
                 String($0.you_owe), String($0.they_owe)]
            })
    }
}
