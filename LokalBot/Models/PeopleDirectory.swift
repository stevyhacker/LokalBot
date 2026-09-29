import Foundation

/// Speaker names applied in one meeting's transcript. Only user-applied
/// display names and their calendar-attendee links are read; speaker
/// evidence, suggestions, and voice-profile identities never are.
struct MeetingAppliedSpeakerNames: Equatable, Sendable {
    var names: [String] = []
    /// Applied name keyed by the opaque calendar-participant id it was linked to.
    var namesByCalendarIdentityID: [String: String] = [:]

    private struct Stored: Decodable {
        var speakerAliases: [String: String]?
        var speakerCalendarIdentityIDs: [String: String]?
    }

    static func load(from folder: URL) -> Self {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("transcript.json")),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return Self() }
        // The user's own microphone label is not another person.
        let aliases = (stored.speakerAliases ?? [:]).filter { label, _ in
            let key = Transcript.canonicalSpeakerKey(label)
            let local = key.split(separator: ":").last.map(String.init) ?? key
            return local != "me" && local != "local"
        }
        var linked: [String: String] = [:]
        for (label, identityID) in stored.speakerCalendarIdentityIDs ?? [:] {
            if let name = aliases[label] { linked[identityID] = name }
        }
        return Self(names: aliases.values.sorted(), namesByCalendarIdentityID: linked)
    }
}

/// One person the user meets, assembled from local meeting metadata:
/// calendar attendee names, speaker names the user applied, and action
/// owners. Attendee email addresses are used only as private join keys and
/// never appear in a profile, its id, or anything derived from it.
struct PersonProfile: Identifiable, Equatable, Sendable {
    struct MeetingRef: Identifiable, Equatable, Sendable {
        let id: UUID
        let title: String
        let startedAt: Date
    }

    struct DecisionRef: Identifiable, Equatable, Sendable {
        let id: String
        let text: String
        let meetingID: UUID
        let meetingTitle: String
        let meetingDate: Date
    }

    let id: String
    var name: String
    var otherNames: [String]
    var meetings: [MeetingRef]
    /// Open or deferred work this person owns.
    var theirActions: [ActionThread]
    /// The user's open work that names this person or came from a small
    /// meeting with them.
    var myActions: [ActionThread]
    var decisions: [DecisionRef]

    var lastMetAt: Date? { meetings.first?.startedAt }
    var meetingIDs: Set<UUID> { Set(meetings.map(\.id)) }
    var firstName: String { name.split(separator: " ").first.map(String.init) ?? name }
}

enum PeopleDirectory {
    static let maximumDecisions = 8
    /// A meeting with at most this many other named participants counts as
    /// "with" each of them for the user's own commitments.
    static let smallMeetingSize = 2
    /// Decisions are attributed to people only from meetings this small;
    /// an all-hands decision is not a decision made "with" each attendee.
    static let decisionMeetingSize = 4

    struct Input: Sendable {
        var meetings: [Meeting]
        var projections: [MeetingOutcomeProjection]
        var appliedNames: [UUID: MeetingAppliedSpeakerNames] = [:]
        /// The user's own names (the Mac account's full name by default);
        /// matching names are never listed as other people.
        var selfNames: [String] = PeopleDirectory.defaultSelfNames
    }

    static var defaultSelfNames: [String] {
        let name = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? [] : [name]
    }

    static func loadAppliedNames(for meetings: [Meeting], root: URL) -> [UUID: MeetingAppliedSpeakerNames] {
        var result: [UUID: MeetingAppliedSpeakerNames] = [:]
        for meeting in meetings where meeting.mergedIntoMeetingID == nil {
            let names = MeetingAppliedSpeakerNames.load(
                from: root.appendingPathComponent(meeting.relativePath, isDirectory: true))
            if !names.names.isEmpty { result[meeting.id] = names }
        }
        return result
    }

    static func build(_ input: Input, now: Date = Date()) -> [PersonProfile] {
        var people = Registry()
        let meetings = input.meetings.filter { $0.mergedIntoMeetingID == nil }
        var participantsByMeeting: [UUID: Set<String>] = [:]

        let isSelf = SelfMatcher(selfNames: input.selfNames)

        for meeting in meetings {
            let applied = input.appliedNames[meeting.id] ?? MeetingAppliedSpeakerNames()
            var keys = Set<String>()
            for identity in meeting.resolvedCalendarParticipantIdentities {
                let appliedName = applied.namesByCalendarIdentityID[identity.id].map(cleanedName)
                    .flatMap { isPlaceholder($0) ? nil : $0 }
                guard let name = appliedName ?? identity.name ?? nameFromAddress(identity),
                      !isSelf(name) else { continue }
                let key = people.register(email: identity.emailAddress, name: name)
                if let appliedName, let calendarName = identity.name, appliedName != calendarName {
                    people.addName(calendarName, to: key)
                }
                keys.insert(key)
            }
            for name in applied.names.map(cleanedName) where !isPlaceholder(name) && !isSelf(name) {
                let key = people.resolve(name: name, among: keys) ?? people.register(email: nil, name: name)
                keys.insert(key)
            }
            participantsByMeeting[meeting.id] = keys
            for key in keys { people.addMeeting(meeting, to: key) }
        }
        people.mergeFirstNamesIntoFullNames()

        let meetingsByID = Dictionary(uniqueKeysWithValues: meetings.map { ($0.id, $0) })
        let projections = input.projections.filter { meetingsByID[$0.meeting.id] != nil && !$0.isArchived }
        let threads = ActionThreadClusterer.cluster(projections.flatMap(\.actionReferences))
            .filter { $0.status != .done }

        // Rosters were recorded while people were still being merged; resolve
        // each stored key to the person it now belongs to.
        func roster(_ meetingID: UUID) -> Set<String> {
            Set((participantsByMeeting[meetingID] ?? []).map(people.canonical))
        }

        for thread in threads {
            let reference = thread.latestReference
            let roster = roster(reference.meetingID)
            if thread.isForUser {
                let text = thread.text
                var targets = Set(roster.filter { key in
                    people.names(of: key).contains { mentions(text, name: $0) }
                })
                if targets.isEmpty, (1...smallMeetingSize).contains(roster.count) { targets = roster }
                for key in targets { people.addMyAction(thread, to: key) }
            } else if let owner = thread.owner.map(cleanedName), isPersonName(owner), !isSelf(owner) {
                let key = people.resolve(name: owner, among: roster)
                    ?? people.resolve(name: owner, among: nil)
                    ?? people.register(email: nil, name: owner)
                if let meeting = meetingsByID[reference.meetingID] { people.addMeeting(meeting, to: key) }
                people.addTheirAction(thread, to: key)
            }
        }

        for projection in projections {
            let roster = roster(projection.meeting.id)
            guard roster.count <= decisionMeetingSize else { continue }
            for decision in projection.outcomes.decisionRecords {
                let ref = PersonProfile.DecisionRef(
                    id: projection.meeting.id.uuidString + ":" + decision.id, text: decision.text,
                    meetingID: projection.meeting.id, meetingTitle: projection.meeting.displayTitle,
                    meetingDate: projection.meeting.startedAt)
                for key in roster { people.addDecision(ref, to: key) }
            }
        }

        return people.profiles(now: now)
    }

    /// Resolves an owner label written in one meeting to a person, using the
    /// same rules as the directory: that meeting's roster first, then a
    /// unique full-name match across everyone.
    static func person(forOwner owner: String, meetingID: UUID,
                       in profiles: [PersonProfile]) -> PersonProfile? {
        let key = normalized(owner)
        guard !key.isEmpty else { return nil }
        let inMeeting = profiles.filter { $0.meetingIDs.contains(meetingID) }
        if let match = uniqueMatch(key, in: inMeeting) { return match }
        let exact = profiles.filter { ([$0.name] + $0.otherNames).map(normalized).contains(key) }
        return exact.count == 1 ? exact[0] : nil
    }

    private static func uniqueMatch(_ key: String, in profiles: [PersonProfile]) -> PersonProfile? {
        let exact = profiles.filter { ([$0.name] + $0.otherNames).map(normalized).contains(key) }
        if exact.count == 1 { return exact[0] }
        let first = profiles.filter { ([$0.name] + $0.otherNames).contains { normalized($0).split(separator: " ").first.map(String.init) == key } }
        return first.count == 1 ? first[0] : nil
    }

    // MARK: - Helpers

    static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.letters.union(.decimalDigits).inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Speaker labels are per meeting ("Them 4" is someone different in
    /// every call) and collective words name no one, so neither is a person.
    static func isPlaceholder(_ name: String) -> Bool {
        let key = normalized(cleanedName(name))
        guard !key.isEmpty else { return true }
        let collective: Set<String> = [
            "you", "we", "us", "team", "everyone", "all", "both", "someone", "nobody", "the team",
            "everybody", "group", "unknown", "owner unclear",
        ]
        if collective.contains(key) { return true }
        return key.range(
            of: #"^(me|them|local|local speaker|speaker|remote|remote speaker|other speaker|unknown speaker|participant|guest)( \d+)?$"#,
            options: .regularExpression) != nil
    }

    /// Removes the "· source 2" suffixes meeting merges add to speaker names
    /// and trailing notes such as "(Them 3)" or "(host)".
    static func cleanedName(_ name: String) -> String {
        name.replacingOccurrences(of: #"(\s*·\s*source\s*\d+)+\s*$"#, with: "",
                                  options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"(\s*\([^)]*\))+\s*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Action owners are model-written and often name a group or a role
    /// ("Engineering team", "Product/research", "Go roadmap owner"). Only
    /// one to four name-like words count as a person.
    static func isPersonName(_ name: String) -> Bool {
        guard !isPlaceholder(name), !name.contains("/"), !name.contains("'s "), !name.contains("’s ") else {
            return false
        }
        let words = normalized(name).split(separator: " ").map(String.init)
        guard (1...4).contains(words.count),
              words.allSatisfy({ $0.allSatisfy(\.isLetter) }) else { return false }
        let groupWords: Set<String> = [
            "team", "teams", "owner", "owners", "group", "department", "engineering", "research",
            "product", "design", "marketing", "sales", "legal", "ops", "operations", "support",
            "company", "client", "customer", "vendor", "partner", "partners", "folks", "people",
            "crew", "squad", "lead", "leads", "management", "committee", "board", "tbd",
        ]
        return groupWords.isDisjoint(with: words)
    }

    /// The name the rename picker suggests from an attendee address. Company
    /// mailboxes are usually a first name ("dragan@…"); on public providers a
    /// single-word mailbox ("donaldkevlee@gmail…") is a handle, so only a
    /// spelled-out "first.last" counts there.
    static func nameFromAddress(_ identity: CalendarParticipantIdentity) -> String? {
        guard identity.name == nil, let name = identity.suggestedSpeakerName,
              let domain = identity.emailAddress?.split(separator: "@").last.map(String.init) else { return nil }
        guard publicMailDomains.contains(domain) else { return name }
        return name.contains(" ") ? name : nil
    }

    private static let publicMailDomains: Set<String> = [
        "gmail.com", "googlemail.com", "yahoo.com", "hotmail.com", "outlook.com", "live.com",
        "msn.com", "icloud.com", "me.com", "mac.com", "aol.com", "proton.me", "protonmail.com",
        "gmx.com", "gmx.de", "mail.com", "yandex.com", "yandex.ru", "mail.ru", "qq.com", "163.com",
        "zoho.com", "fastmail.com", "hey.com",
    ]

    /// Matches the user's own full name or a bare first name equal to theirs.
    /// When the account name is a single word ("Stevan"), any name that
    /// starts with it ("Stevan Bogosavljevic") is treated as the user too.
    struct SelfMatcher: Sendable {
        let fullNames: Set<String>
        let firstNames: Set<String>
        let singleWordNames: Set<String>

        init(selfNames: [String]) {
            fullNames = Set(selfNames.map(PeopleDirectory.normalized).filter { !$0.isEmpty })
            firstNames = Set(fullNames.compactMap { $0.split(separator: " ").first.map(String.init) })
            singleWordNames = fullNames.filter { !$0.contains(" ") }
        }

        func callAsFunction(_ name: String) -> Bool {
            let key = PeopleDirectory.normalized(PeopleDirectory.cleanedName(name))
            guard !key.isEmpty else { return false }
            if fullNames.contains(key) { return true }
            guard let first = key.split(separator: " ").first.map(String.init) else { return false }
            if !key.contains(" ") { return firstNames.contains(key) }
            return singleWordNames.contains(first)
        }
    }

    /// Whole-word match of a full name or a first name of 3+ letters.
    static func mentions(_ text: String, name: String) -> Bool {
        let words = " " + normalized(text) + " "
        let full = normalized(name)
        guard !full.isEmpty else { return false }
        if words.contains(" " + full + " ") { return true }
        guard let first = full.split(separator: " ").first, first.count >= 3,
              full.contains(" ") else { return false }
        return words.contains(" " + first + " ")
    }

    /// FNV-1a over the private join key gives a stable, opaque identifier.
    static func opaqueID(_ key: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(format: "person-%016llx", hash)
    }

    private struct Entry {
        var nameCounts: [String: Int] = [:]
        var meetings: [UUID: PersonProfile.MeetingRef] = [:]
        var theirActions: [String: ActionThread] = [:]
        var myActions: [String: ActionThread] = [:]
        var decisions: [String: PersonProfile.DecisionRef] = [:]
    }

    /// Joins calendar identities by address when present, otherwise by full
    /// normalized name. A name-only person merges into an address-keyed one
    /// when exactly one address-keyed person carries that full name.
    private struct Registry {
        var entries: [String: Entry] = [:]
        var order: [String] = []
        var keyByName: [String: Set<String>] = [:]
        /// A merged-away key points to the person it joined, so keys stored
        /// before the merge (meeting rosters) still reach the right person.
        var redirects: [String: String] = [:]

        func canonical(_ key: String) -> String {
            var current = key
            var visited: Set<String> = []
            while let next = redirects[current], visited.insert(current).inserted { current = next }
            return current
        }

        mutating func register(email: String?, name: String) -> String {
            let nameKey = normalized(name)
            let key: String
            if let email {
                key = "email:" + email.lowercased()
                // Fold an earlier name-only entry into this address.
                let nameOnly = "name:" + nameKey
                if key != nameOnly, entries[nameOnly] != nil,
                   (keyByName[nameKey] ?? []).subtracting([nameOnly]).isEmpty {
                    merge(nameOnly, into: key)
                }
            } else if let existing = keyByName[nameKey], existing.count == 1, let only = existing.first {
                key = only
            } else {
                key = "name:" + nameKey
            }
            addName(name, to: key)
            return canonical(key)
        }

        mutating func addName(_ name: String, to rawKey: String) {
            let key = canonical(rawKey)
            if entries[key] == nil { entries[key] = Entry(); order.append(key) }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let display = trimmed == trimmed.lowercased() ? trimmed.capitalized : trimmed
            entries[key]?.nameCounts[display, default: 0] += 1
            keyByName[normalized(name), default: []].insert(key)
        }

        func names(of key: String) -> [String] {
            entries[canonical(key)].map { Array($0.nameCounts.keys) } ?? []
        }

        /// Exact full-name match first, then a unique first-name match.
        func resolve(name: String, among keys: Set<String>?) -> String? {
            let target = normalized(name)
            let candidates = keys.map { Array(Set($0.map(canonical))) } ?? order
            let exact = candidates.filter { names(of: $0).map(normalized).contains(target) }
            if exact.count == 1 { return exact[0] }
            guard !target.contains(" "), target.count >= 2 else { return nil }
            let byFirst = candidates.filter { key in
                names(of: key).contains { normalized($0).split(separator: " ").first.map(String.init) == target }
            }
            return byFirst.count == 1 ? byFirst[0] : nil
        }

        mutating func addMeeting(_ meeting: Meeting, to key: String) {
            entries[canonical(key)]?.meetings[meeting.id] = .init(
                id: meeting.id, title: meeting.displayTitle, startedAt: meeting.startedAt)
        }

        mutating func addTheirAction(_ thread: ActionThread, to key: String) {
            entries[canonical(key)]?.theirActions[thread.id] = thread
        }

        mutating func addMyAction(_ thread: ActionThread, to key: String) {
            entries[canonical(key)]?.myActions[thread.id] = thread
        }

        mutating func addDecision(_ decision: PersonProfile.DecisionRef, to key: String) {
            entries[canonical(key)]?.decisions[decision.id] = decision
        }

        /// A first name alone ("Dragan", often applied to a speaker) joins the
        /// one person whose full name starts with it ("Dragan Cabarkapa").
        /// Two different attendee addresses are never joined.
        mutating func mergeFirstNamesIntoFullNames() {
            var fullNamesByFirst: [String: Set<String>] = [:]
            for key in order {
                for name in names(of: key) {
                    let words = normalized(name).split(separator: " ")
                    if words.count >= 2, let first = words.first { fullNamesByFirst[String(first), default: []].insert(key) }
                }
            }
            for key in order {
                let keys = Set(names(of: key).map(normalized))
                guard keys.count == 1, let only = keys.first, !only.contains(" "), only.count >= 3,
                      let targets = fullNamesByFirst[only], targets.count == 1,
                      let target = targets.first, target != key,
                      !(key.hasPrefix("email:") && target.hasPrefix("email:")) else { continue }
                merge(key, into: target)
            }
        }

        private func sortedByRecency(_ threads: Dictionary<String, ActionThread>.Values) -> [ActionThread] {
            threads.sorted {
                let left = $0.latestReference.meetingStartedAt, right = $1.latestReference.meetingStartedAt
                return left == right ? $0.id < $1.id : left > right
            }
        }

        private mutating func merge(_ source: String, into target: String) {
            guard let moved = entries.removeValue(forKey: source) else { return }
            order.removeAll { $0 == source }
            redirects[source] = target
            if entries[target] == nil { entries[target] = Entry(); order.append(target) }
            for (name, count) in moved.nameCounts {
                entries[target]?.nameCounts[name, default: 0] += count
                keyByName[normalized(name)]?.remove(source)
                keyByName[normalized(name), default: []].insert(target)
            }
            entries[target]?.meetings.merge(moved.meetings) { current, _ in current }
            entries[target]?.theirActions.merge(moved.theirActions) { current, _ in current }
            entries[target]?.myActions.merge(moved.myActions) { current, _ in current }
            entries[target]?.decisions.merge(moved.decisions) { current, _ in current }
        }

        func profiles(now: Date) -> [PersonProfile] {
            order.compactMap { key -> PersonProfile? in
                guard let entry = entries[key], !entry.meetings.isEmpty || !entry.theirActions.isEmpty else {
                    return nil
                }
                // Prefer the fullest name ("Ana Petrović" over "Ana"), then
                // the most frequently seen spelling.
                let names = entry.nameCounts.sorted {
                    let leftWords = $0.key.split(separator: " ").count
                    let rightWords = $1.key.split(separator: " ").count
                    if leftWords != rightWords { return leftWords > rightWords }
                    if $0.value != $1.value { return $0.value > $1.value }
                    return $0.key < $1.key
                }.map(\.key)
                guard let name = names.first else { return nil }
                let meetings = entry.meetings.values.sorted { $0.startedAt > $1.startedAt }
                let decisions = entry.decisions.values.sorted { $0.meetingDate > $1.meetingDate }
                return PersonProfile(
                    id: opaqueID(key),
                    name: name,
                    otherNames: Array(names.dropFirst()),
                    meetings: meetings,
                    theirActions: ActionAttentionOrder.sorted(sortedByRecency(entry.theirActions.values), now: now),
                    myActions: ActionAttentionOrder.sorted(sortedByRecency(entry.myActions.values), now: now),
                    decisions: Array(decisions.prefix(maximumDecisions)))
            }
            .sorted {
                let left = $0.lastMetAt ?? .distantPast, right = $1.lastMetAt ?? .distantPast
                return left == right ? $0.name < $1.name : left > right
            }
        }
    }
}
