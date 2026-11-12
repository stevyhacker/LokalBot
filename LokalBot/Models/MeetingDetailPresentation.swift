import Foundation

extension Transcript {
    /// "0:12", "37:05", "1:02:09": the compact time people read beside a
    /// line. `stamp` keeps the fixed-width form for exports and files.
    static func shortStamp(_ time: TimeInterval) -> String {
        let seconds = max(0, Int(time.isFinite ? time : 0))
        return seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// Display-only values for a saved meeting's page: who spoke, how long, what
/// is being said at the playhead, and whose each action is. Nothing here is
/// stored, sent to a model, or treated as an identity decision.
enum MeetingDetailPresentation {
    // MARK: Header

    /// "Today at 1:00 PM", "Yesterday at 3:10 PM", then "Nov 6, 2026 at 3:00 PM".
    static func dateText(_ date: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter.string(from: date)
    }

    struct Speaker: Identifiable, Equatable {
        /// The transcript's canonical speaker key ("me", "them 2").
        let id: String
        let name: String
        let colorIndex: Int
        let isUser: Bool
        /// A call voice nobody has named yet.
        let needsName: Bool
    }

    /// Everyone who spoke, you first, then in order of first speaking.
    static func speakers(in transcript: Transcript?, presentation: MeetingSpeakerPresentation) -> [Speaker] {
        guard let transcript else { return [] }
        let roster = transcript.speakerRoster
        let unnamed = Set(unnamedSpeakerKeys(in: transcript))
        var seen = Set<String>()
        let ordered = transcript.segments.compactMap { segment -> Speaker? in
            let key = Transcript.canonicalSpeakerKey(segment.speaker)
            guard seen.insert(key).inserted else { return nil }
            return Speaker(id: key, name: presentation.speaker(key, in: transcript),
                           colorIndex: presentation.colorIndex(for: key),
                           isUser: roster[key]?.identity == .user, needsName: unnamed.contains(key))
        }
        return ordered.filter(\.isUser) + ordered.filter { !$0.isUser }
    }

    /// Call voices without a saved name, in order of first speaking.
    static func unnamedSpeakerKeys(in transcript: Transcript?) -> [String] {
        guard let transcript else { return [] }
        var seen = Set<String>()
        return transcript.segments.compactMap { segment in
            let speaker = Transcript.canonicalSpeakerKey(segment.speaker)
            guard segment.resolvedAttribution.source == .system || speaker.hasPrefix("them"),
                  transcript.speakerAliases[speaker] == nil, seen.insert(speaker).inserted else { return nil }
            return speaker
        }
    }

    // MARK: Speech time

    /// Seconds of transcribed speech per speaker key, from segment bounds.
    static func speechSeconds(in transcript: Transcript?) -> [String: TimeInterval] {
        var result: [String: TimeInterval] = [:]
        for segment in transcript?.segments ?? []
        where segment.start.isFinite && segment.end.isFinite && segment.end > segment.start && segment.start >= 0 {
            result[Transcript.canonicalSpeakerKey(segment.speaker), default: 0] += segment.end - segment.start
        }
        return result
    }

    /// Whole minutes for "12 min of speech"; any speech at all reads as one.
    static func speechMinutes(_ seconds: TimeInterval) -> Int {
        max(1, Int((seconds / 60).rounded()))
    }

    // MARK: Playhead caption

    struct Caption: Equatable {
        let segmentIndex: Int
        let speakerKey: String
        let text: String
        let start: TimeInterval
    }

    /// Finds the line being said at a time. Built once per transcript so the
    /// player can ask on every clock tick.
    struct PlayheadIndex {
        private let captions: [Caption]

        init(display: Transcript.DisplayIndex = .init()) {
            captions = display.segments.map {
                Caption(segmentIndex: $0.id, speakerKey: $0.speakerKey, text: $0.text, start: $0.segment.start)
            }.sorted { $0.start == $1.start ? $0.segmentIndex < $1.segmentIndex : $0.start < $1.start }
        }

        var isEmpty: Bool { captions.isEmpty }

        /// The latest line that has started; before any speech, the first.
        func caption(at time: TimeInterval) -> Caption? {
            var lower = 0, upper = captions.count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if captions[middle].start <= time { lower = middle + 1 } else { upper = middle }
            }
            return lower > 0 ? captions[lower - 1] : captions.first
        }
    }

    // MARK: Actions

    struct ActionGroups: Equatable {
        var forYou: [OutcomeActionReference] = []
        var forOthers: [OutcomeActionReference] = []
    }

    /// The meeting's actions split by whose they are, keeping their order.
    static func groups(_ actions: [OutcomeActionReference]) -> ActionGroups {
        ActionGroups(forYou: actions.filter(\.isForUser), forOthers: actions.filter { !$0.isForUser })
    }

    /// Someone else's action whose owner is missing or only a placeholder
    /// voice ("Speaker 2"): the row asks for a real owner.
    static func ownerNeedsAttention(owner: String?, displayOwner: String?, isForUser: Bool) -> Bool {
        if isForUser { return false }
        guard let owner, !ownerKey(owner).isEmpty else { return true }
        return [owner, displayOwner ?? ""].contains { name in
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return Transcript.isPlaceholderSpeakerName(trimmed)
                || ["other speaker", "unresolved speaker"].contains(trimmed.lowercased())
        }
    }

    enum DueUrgency: Equatable { case overdue, soon, later }

    /// The Actions list's rule for one action: open work past its due day is
    /// overdue, due within the attention window is soon, the rest is later.
    static func dueUrgency(resolved: Date?, status: OutcomeStatus, now: Date = Date(),
                           calendar: Calendar = .current) -> DueUrgency {
        guard status == .open, let resolved else { return .later }
        let today = calendar.startOfDay(for: now)
        if resolved < today { return .overdue }
        let soon = calendar.date(byAdding: .day, value: ActionAttentionOrder.dueSoonWindowDays, to: today) ?? today
        return resolved <= soon ? .soon : .later
    }

    struct OwnerOption: Identifiable, Equatable {
        enum Kind: Equatable { case you, speaker, invited, none }
        let id: String
        /// What the menu shows.
        let title: String
        /// What is saved as the owner; empty clears it.
        let value: String
        let kind: Kind
        let isSelected: Bool
    }

    /// Owner choices for one action: you, this meeting's other speakers,
    /// invited people who are not already among them, and no owner.
    static func ownerOptions(
        owner: String?, isForUser: Bool, speakers: [Speaker], storedNames: [String: String], invited: [String]
    ) -> [OwnerOption] {
        let current = owner.map(ownerKey) ?? ""
        var options = [OwnerOption(id: "you", title: "You", value: "Me", kind: .you, isSelected: isForUser)]
        var taken = Set<String>()
        var anySelected = isForUser
        for speaker in speakers where !speaker.isUser {
            let stored = storedNames[speaker.id] ?? speaker.name
            guard taken.insert(ownerKey(speaker.name)).inserted else { continue }
            taken.insert(ownerKey(stored))
            // By name, not by voice: "Them" on an action is not the person
            // that voice was named as afterwards, until someone says so.
            let selected = !anySelected && !current.isEmpty
                && [speaker.name, stored].map(ownerKey).contains(current)
            anySelected = anySelected || selected
            options.append(.init(id: "speaker:\(speaker.id)", title: speaker.name, value: stored,
                                 kind: .speaker, isSelected: selected))
        }
        for name in invited {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, taken.insert(ownerKey(trimmed)).inserted else { continue }
            let selected = !anySelected && current == ownerKey(trimmed)
            anySelected = anySelected || selected
            options.append(.init(id: "invited:\(ownerKey(trimmed))", title: trimmed, value: trimmed,
                                 kind: .invited, isSelected: selected))
        }
        options.append(.init(id: "none", title: "No owner", value: "", kind: .none,
                             isSelected: !anySelected && current.isEmpty))
        return options
    }

    struct OwnerCorrection: Equatable {
        let text: String?
        let owner: String
        let due: String?
    }

    /// Saving a new owner from the row's menu keeps a corrected wording and a
    /// corrected or cleared due date exactly as they are. Nil when the choice
    /// is already the action's owner.
    static func ownerCorrection(_ option: OwnerOption, for reference: OutcomeActionReference) -> OwnerCorrection? {
        let sameOwner = ownerKey(option.value) == ownerKey(reference.owner ?? "")
        if sameOwner, option.kind != .you || reference.isForUser { return nil }
        return OwnerCorrection(
            text: reference.textWasCorrected ? reference.text : nil,
            owner: option.value,
            due: reference.dueWasCorrected ? (reference.due ?? "") : nil)
    }

    /// The name the transcript itself uses for each speaker ("Them 2", or a
    /// saved alias): what an owner is saved as, whatever the page shows.
    static func storedSpeakerNames(in transcript: Transcript?, speakers: [Speaker]) -> [String: String] {
        guard let transcript else { return [:] }
        return Dictionary(speakers.map { ($0.id, transcript.displaySpeaker(for: $0.id)) },
                          uniquingKeysWith: { first, _ in first })
    }

    private static func ownerKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    // MARK: List row

    /// "1:00 PM · 50 min · Zoom": when, how long, then where it happened.
    static func rowSubtitle(time: String, duration: String, source: String?) -> String {
        ([time, duration] + (source.map { [$0] } ?? [])).filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
