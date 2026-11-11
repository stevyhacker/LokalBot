import Foundation

/// The next calendar meeting with one person, as People shows it. It holds
/// names only: an invited address without a display name is left out.
struct PersonUpcomingMeeting: Equatable, Sendable {
    let eventID: String
    let title: String
    let start: Date
    let end: Date
    /// Everyone else invited, by display name, in the invitation's order.
    /// The person and the user are not listed.
    let others: [String]

    func isInProgress(at now: Date) -> Bool { start <= now && end > now }
}

/// Matches upcoming calendar events to people through the keys
/// `PeopleDirectory` already registers for an attendee: the address, then the
/// name. Nothing is stored; a match lasts as long as the page shows it.
enum PeopleUpcomingMeetings {
    /// "Coming up" looks this many days ahead.
    static let windowDays = 7

    /// The soonest event for each person, keyed by person id. `events` is nil
    /// while Calendar use is off or access is missing, and then nobody has one.
    ///
    /// An attendee with an address is the person registered under that
    /// address, or the one still known only by that full name. An attendee
    /// without an address is the one person carrying that full name, or, for a
    /// lone first name, the one person whose full name starts with it. Two
    /// people who share a name are never guessed between.
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
            // Each attendee as (the person they are, the name to show).
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

    /// Calendar events are read only while Calendar use is on and access has
    /// been granted. Otherwise nothing is fetched and nothing is asked for.
    static func events(
        calendarEnabled: Bool,
        authorization: CalendarAuthorizationStatus,
        fetch: () -> [CalendarMeetingCandidate]
    ) -> [CalendarMeetingCandidate]? {
        guard calendarEnabled, authorization == .fullAccess else { return nil }
        return fetch()
    }

    /// Looks attendees up by the directory's own keys without ever holding an
    /// address: a person's ids are hashes of those keys.
    private struct Index {
        /// Every id folded into a person, to that person's id.
        var personByMemberID: [String: String] = [:]
        /// Normalized full names (shown and other) to the people carrying them.
        var peopleByName: [String: Set<String>] = [:]
        /// First word of a full name of two or more words.
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
                // A person so far known only by this name takes the address
                // when the directory next sees it; someone registered under
                // another address stays a different person.
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
