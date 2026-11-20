import Foundation

struct PersonUpcomingMeeting: Equatable, Sendable {
    let eventID: String
    let title: String
    let start: Date
    let end: Date
    let others: [String]

    func isInProgress(at now: Date) -> Bool { start <= now && end > now }
}

enum PeopleUpcomingMeetings {
    static let windowDays = 7

    static func match(
        events: [CalendarMeetingCandidate]?,
        people: [PersonProfile],
        recordedEventIDs: Set<String> = [],
        selfNames: [String] = PeopleDirectory.defaultSelfNames,
        now: Date,
        calendar: Calendar = .current
    ) -> [String: PersonUpcomingMeeting] {
        guard let events, !events.isEmpty, !people.isEmpty else { return [:] }
        let windowEnd = calendar.date(byAdding: .day, value: windowDays, to: now) ?? now
        let upcoming = events
            .filter { $0.endDate > now && $0.startDate < windowEnd && !recordedEventIDs.contains($0.externalID) }
            .sorted {
                if $0.startDate != $1.startDate { return $0.startDate < $1.startDate }
                if $0.endDate != $1.endDate { return $0.endDate < $1.endDate }
                return $0.externalID < $1.externalID
            }
        guard !upcoming.isEmpty else { return [:] }

        let index = Index(people: people)
        let isSelf = PeopleDirectory.SelfMatcher(selfNames: selfNames)
        var result: [String: PersonUpcomingMeeting] = [:]
        for event in upcoming {
            var attendees: [(personID: String?, name: String?)] = []
            for identity in event.resolvedParticipantIdentities {
                let name = (identity.name ?? PeopleDirectory.nameFromAddress(identity))
                    .map(PeopleDirectory.cleanedName)
                    .flatMap { PeopleDirectory.isPlaceholder($0) ? nil : $0 }
                if let name, isSelf(name) { continue }
                let personID = index.personID(email: identity.emailAddress, name: name)
                attendees.append((personID, personID.flatMap { index.names[$0] } ?? name))
            }
            for personID in Set(attendees.compactMap(\.personID)) where result[personID] == nil {
                var seen: Set<String> = []
                let others = attendees
                    .filter { $0.personID != personID }
                    .compactMap(\.name)
                    .filter { seen.insert(PeopleDirectory.normalized($0)).inserted }
                result[personID] = PersonUpcomingMeeting(
                    eventID: event.externalID, title: event.title,
                    start: event.startDate, end: event.endDate, others: others)
            }
        }
        return result
    }

    static func events(
        calendarEnabled: Bool,
        authorization: CalendarAuthorizationStatus,
        fetch: () -> [CalendarMeetingCandidate]
    ) -> [CalendarMeetingCandidate]? {
        guard calendarEnabled, authorization == .fullAccess else { return nil }
        return fetch()
    }

    private struct Index {
        var personByMemberID: [String: String] = [:]
        var peopleByName: [String: Set<String>] = [:]
        var peopleByFirstName: [String: Set<String>] = [:]
        var names: [String: String] = [:]

        init(people: [PersonProfile]) {
            for person in people {
                names[person.id] = person.name
                for id in [person.id] + person.memberIDs { personByMemberID[id] = person.id }
                for name in [person.name] + person.otherNames {
                    let key = PeopleDirectory.normalized(name)
                    guard !key.isEmpty else { continue }
                    peopleByName[key, default: []].insert(person.id)
                    let words = key.split(separator: " ")
                    if words.count >= 2, let first = words.first {
                        peopleByFirstName[String(first), default: []].insert(person.id)
                    }
                }
            }
        }

        func personID(email: String?, name: String?) -> String? {
            let nameKey = name.map(PeopleDirectory.normalized).flatMap { $0.isEmpty ? nil : $0 }
            if let email {
                if let match = personByMemberID[PeopleDirectory.opaqueID("email:" + email.lowercased())] {
                    return match
                }
                return nameKey.flatMap { personByMemberID[PeopleDirectory.opaqueID("name:" + $0)] }
            }
            guard let nameKey else { return nil }
            if let exact = peopleByName[nameKey] { return exact.count == 1 ? exact.first : nil }
            guard !nameKey.contains(" "), nameKey.count >= 3,
                  let byFirst = peopleByFirstName[nameKey], byFirst.count == 1 else { return nil }
            return byFirst.first
        }
    }
}
