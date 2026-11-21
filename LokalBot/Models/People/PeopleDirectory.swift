import Foundation

struct MeetingAppliedSpeakerNames: Equatable, Sendable {
    var names: [String] = []
    var namesByCalendarIdentityID: [String: String] = [:]
    var namesBySpeakerKey: [String: String] = [:]

    private struct Stored: Decodable {
        var speakerAliases: [String: String]?
        var speakerCalendarIdentityIDs: [String: String]?
    }

    static func load(from folder: URL) -> Self {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("transcript.json")),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return Self() }
        let aliases = (stored.speakerAliases ?? [:]).filter { label, _ in
            let key = Transcript.canonicalSpeakerKey(label)
            let local = key.split(separator: ":").last.map(String.init) ?? key
            return local != "me" && local != "local"
        }
        var linked: [String: String] = [:]
        for (label, identityID) in stored.speakerCalendarIdentityIDs ?? [:] {
            if let name = aliases[label] { linked[identityID] = name }
        }
        var bySpeaker: [String: String] = [:]
        for (label, name) in aliases { bySpeaker[Transcript.canonicalSpeakerKey(label)] = name }
        return Self(names: aliases.values.sorted(), namesByCalendarIdentityID: linked,
                    namesBySpeakerKey: bySpeaker)
    }

    func name(forSpeaker label: String) -> String? {
        namesBySpeakerKey[Transcript.canonicalSpeakerKey(label)]
    }
}

struct PersonProfile: Identifiable, Equatable, Sendable {
    struct MeetingRef: Identifiable, Equatable, Sendable {
        let id: UUID
        let title: String
        let startedAt: Date
        var endedAt: Date?
        var calendarEventID: String?
        var participantCount = 0

        var duration: TimeInterval { max(0, (endedAt ?? startedAt).timeIntervalSince(startedAt)) }
    }

    struct Occasion: Identifiable, Equatable, Sendable {
        let recordings: [MeetingRef]

        var id: UUID { primary.id }
        var primary: MeetingRef {
            recordings.max { $0.duration == $1.duration ? $0.startedAt < $1.startedAt : $0.duration < $1.duration }
                ?? recordings[0]
        }
        var title: String { primary.title }
        var startedAt: Date { recordings.map(\.startedAt).min() ?? primary.startedAt }
    }

    struct Series: Identifiable, Equatable, Sendable {
        let title: String
        let occasions: [Occasion]

        var id: String { PeopleDirectory.normalized(title) }
        var latest: Occasion { occasions[0] }
    }

    struct DecisionRef: Identifiable, Equatable, Sendable {
        let id: String
        let text: String
        let meetingID: UUID
        let meetingTitle: String
        let meetingDate: Date
    }

    struct NotePoint: Identifiable, Equatable, Sendable {
        var id: String { text }
        let text: String
        let speaker: String?
        let meetingID: UUID
        let seek: TimeInterval?
    }

    struct RecentNotes: Equatable, Sendable {
        let meetingID: UUID
        let meetingTitle: String
        let meetingDate: Date
        let isLatestMeeting: Bool
        let points: [NotePoint]
    }

    struct ProjectLink: Identifiable, Equatable, Sendable {
        let id: String
        let name: String
        let isTracked: Bool
        let mentions: Int
    }

    let id: String
    var name: String
    var otherNames: [String]
    var memberIDs: [String] = []
    var meetings: [MeetingRef]
    var theirActions: [ActionThread]
    var myActions: [ActionThread]
    var decisions: [DecisionRef]
    var recentNotes: RecentNotes?
    var projects: [ProjectLink] = []

    var lastMetAt: Date? { meetings.first?.startedAt }
    var meetingIDs: Set<UUID> { Set(meetings.map(\.id)) }
    var firstName: String { name.split(separator: " ").first.map(String.init) ?? name }
    var openCount: Int { myActions.count + theirActions.count }

    var occasions: [Occasion] { PeopleDirectory.occasions(meetings) }
    var meetingCount: Int { occasions.count }

    var series: [Series] { PeopleDirectory.series(occasions) }

    func occasions(since date: Date) -> Int { occasions.filter { $0.startedAt >= date }.count }
}

enum PeopleDirectory {
    static let maximumDecisions = 8
    static let smallMeetingSize = 2
    static let decisionMeetingSize = 4
    static let recordingGapTolerance: TimeInterval = 15 * 60

    struct Input: Sendable {
        var meetings: [Meeting]
        var projections: [MeetingOutcomeProjection]
        var appliedNames: [UUID: MeetingAppliedSpeakerNames] = [:]
        var selfNames: [String] = PeopleDirectory.defaultSelfNames
        var curation = PeopleCuration()
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
        people.addChosenNames(input.curation.names)
        people.applyMerges(input.curation.merges)

        let meetingsByID = Dictionary(uniqueKeysWithValues: meetings.map { ($0.id, $0) })
        let projections = input.projections.filter { meetingsByID[$0.meeting.id] != nil && !$0.isArchived }
        let threads = ActionThreadClusterer.cluster(projections.flatMap(\.actionReferences))
            .filter { $0.status != .done }

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
            let applied = input.appliedNames[projection.meeting.id] ?? MeetingAppliedSpeakerNames()
            for decision in projection.outcomes.decisionRecords {
                let ref = PersonProfile.DecisionRef(
                    id: projection.meeting.id.uuidString + ":" + decision.id, text: decision.text,
                    meetingID: projection.meeting.id, meetingTitle: projection.meeting.displayTitle,
                    meetingDate: projection.meeting.startedAt)
                var targets: Set<String> = roster.count <= decisionMeetingSize ? roster : []
                if roster.count > decisionMeetingSize {
                    if let attribution = decision.attribution, attribution.identity != .user,
                       let name = applied.name(forSpeaker: attribution.speakerLabel),
                       let key = people.resolve(name: name, among: roster) {
                        targets.insert(key)
                    }
                    for key in roster where people.names(of: key).contains(where: { isNamed($0, in: decision.text) }) {
                        targets.insert(key)
                    }
                }
                for key in targets { people.addDecision(ref, to: key) }
            }
        }
        people.applyMerges(input.curation.merges)

        var rosterSizes: [UUID: Int] = [:]
        for meeting in meetings { rosterSizes[meeting.id] = roster(meeting.id).count }
        return people.profiles(now: now, rosterSizes: rosterSizes, curation: input.curation)
    }

    static func occasions(_ meetings: [PersonProfile.MeetingRef],
                          calendar: Calendar = .current) -> [PersonProfile.Occasion] {
        var groups: [[PersonProfile.MeetingRef]] = []
        for meeting in meetings.sorted(by: { $0.startedAt > $1.startedAt }) {
            if let index = groups.firstIndex(where: { group in
                group.contains { sameOccasion($0, meeting, calendar: calendar) }
            }) {
                groups[index].append(meeting)
            } else {
                groups.append([meeting])
            }
        }
        return groups.map { PersonProfile.Occasion(recordings: $0) }
    }

    static func sameOccasion(_ left: PersonProfile.MeetingRef, _ right: PersonProfile.MeetingRef,
                             calendar: Calendar = .current) -> Bool {
        guard calendar.isDate(left.startedAt, inSameDayAs: right.startedAt) else { return false }
        if let first = left.calendarEventID, let second = right.calendarEventID { return first == second }
        guard normalized(left.title) == normalized(right.title) else { return false }
        let (earlier, later) = left.startedAt <= right.startedAt ? (left, right) : (right, left)
        let earlierEnd = earlier.endedAt ?? earlier.startedAt
        return later.startedAt <= earlierEnd.addingTimeInterval(recordingGapTolerance)
    }

    static func series(_ occasions: [PersonProfile.Occasion]) -> [PersonProfile.Series] {
        var order: [String] = []
        var byKey: [String: [PersonProfile.Occasion]] = [:]
        for occasion in occasions {
            let key = normalized(occasion.title)
            if byKey[key] == nil { order.append(key) }
            byKey[key, default: []].append(occasion)
        }
        return order.compactMap { key in
            guard let group = byKey[key], let first = group.first else { return nil }
            return PersonProfile.Series(title: first.title, occasions: group)
        }
    }

    static func isNamed(_ name: String, in text: String) -> Bool {
        let nameWords = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.letters.union(.decimalDigits).inverted)
            .filter { !$0.isEmpty }
        guard let first = nameWords.first else { return false }
        var tokens: [(word: String, folded: String, startsSentence: Bool)] = []
        var startsSentence = true
        var current = ""
        func flush() {
            guard !current.isEmpty else { return }
            let folded = current.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            tokens.append((current, folded, startsSentence))
            startsSentence = false
            current = ""
        }
        for character in text {
            if character.isLetter || character.isNumber {
                current.append(character)
            } else {
                flush()
                if ".!?:\n".contains(character) { startsSentence = true }
            }
        }
        flush()
        func isCapitalized(_ word: String) -> Bool { word.first?.isUppercase == true }
        for (index, token) in tokens.enumerated() where token.folded == first && isCapitalized(token.word) {
            if nameWords.count > 1, index + nameWords.count <= tokens.count,
               zip(tokens[index...], nameWords).allSatisfy({ $0.0.folded == $0.1 }) {
                return true
            }
            guard first.count >= 3 else { continue }
            if token.startsSentence && commonWordNames.contains(first) { continue }
            return true
        }
        return false
    }

    private static let commonWordNames: Set<String> = [
        "will", "may", "mark", "grant", "bill", "chase", "sue", "rob", "pat", "max", "hope",
        "frank", "june", "april", "august", "art", "joy", "faith", "dawn", "rich", "case",
    ]

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

    static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.letters.union(.decimalDigits).inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

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

    static func cleanedName(_ name: String) -> String {
        name.replacingOccurrences(of: #"(\s*·\s*source\s*\d+)+\s*$"#, with: "",
                                  options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"(\s*\([^)]*\))+\s*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isPersonName(_ name: String) -> Bool {
        guard !isPlaceholder(name), !name.contains("/"), !name.contains("'s "), !name.contains("’s "),
              !name.contains(","), !name.contains("&"), !name.contains("+") else {
            return false
        }
        let words = normalized(name).split(separator: " ").map(String.init)
        guard !words.contains("and") else { return false }
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

    static func mentions(_ text: String, name: String) -> Bool {
        let words = " " + normalized(text) + " "
        let full = normalized(name)
        guard !full.isEmpty else { return false }
        if words.contains(" " + full + " ") { return true }
        guard let first = full.split(separator: " ").first, first.count >= 3,
              full.contains(" ") else { return false }
        return words.contains(" " + first + " ")
    }

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

    private struct Registry {
        var entries: [String: Entry] = [:]
        var order: [String] = []
        var keyByName: [String: Set<String>] = [:]
        var redirects: [String: String] = [:]
        var members: [String: [String]] = [:]
        var mergeTargetNames: [String: String] = [:]

        func key(forID id: String) -> String? {
            let known = order + Array(redirects.keys)
            return known.first { opaqueID($0) == id }.map(canonical)
        }

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
                id: meeting.id, title: meeting.displayTitle, startedAt: meeting.startedAt,
                endedAt: meeting.endedAt, calendarEventID: meeting.calendarEventID)
        }

        mutating func addChosenNames(_ names: [String: String]) {
            for (id, name) in names.sorted(by: { $0.key < $1.key }) {
                guard let key = key(forID: id), !normalized(name).isEmpty else { continue }
                addName(name, to: key)
            }
        }

        mutating func applyMerges(_ merges: [PeopleCuration.Merge]) {
            for merge in merges {
                guard let source = key(forID: merge.sourceID), let target = key(forID: merge.targetID),
                      source != target else { continue }
                if mergeTargetNames[target] == nil, let entry = entries[target] {
                    mergeTargetNames[target] = Self.rankedNames(entry).first
                }
                self.merge(source, into: target)
            }
        }

        static func rankedNames(_ entry: Entry) -> [String] {
            entry.nameCounts.sorted {
                let leftWords = $0.key.split(separator: " ").count
                let rightWords = $1.key.split(separator: " ").count
                if leftWords != rightWords { return leftWords > rightWords }
                if $0.value != $1.value { return $0.value > $1.value }
                return $0.key < $1.key
            }.map(\.key)
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
            members[target, default: [target]] += members.removeValue(forKey: source) ?? [source]
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

        func profiles(now: Date, rosterSizes: [UUID: Int] = [:],
                      curation: PeopleCuration = PeopleCuration()) -> [PersonProfile] {
            order.compactMap { key -> PersonProfile? in
                guard let entry = entries[key], !entry.meetings.isEmpty || !entry.theirActions.isEmpty else {
                    return nil
                }
                let memberIDs: [String] = [opaqueID(key)]
                    + (members[key] ?? []).filter { $0 != key }.map(opaqueID)
                guard !memberIDs.contains(where: curation.isHidden) else { return nil }
                var names = Self.rankedNames(entry)
                if let preferred = memberIDs.lazy.compactMap({ curation.names[$0] }).first
                    ?? mergeTargetNames[key] {
                    let preferredKey = normalized(preferred)
                    names = [preferred] + names.filter { normalized($0) != preferredKey }
                }
                guard let name = names.first else { return nil }
                let meetings = entry.meetings.values.map { meeting -> PersonProfile.MeetingRef in
                    var meeting = meeting
                    meeting.participantCount = rosterSizes[meeting.id] ?? 0
                    return meeting
                }.sorted { $0.startedAt > $1.startedAt }
                let decisions = entry.decisions.values.sorted {
                    $0.meetingDate == $1.meetingDate ? $0.id < $1.id : $0.meetingDate > $1.meetingDate
                }
                return PersonProfile(
                    id: opaqueID(key),
                    name: name,
                    otherNames: Array(names.dropFirst()),
                    memberIDs: memberIDs,
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
