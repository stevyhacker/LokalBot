import Foundation

extension Transcript {
    static func shortStamp(_ time: TimeInterval) -> String {
        let seconds = max(0, Int(time.isFinite ? time : 0))
        return seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

enum MeetingDetailPresentation {
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
        let id: String
        let name: String
        let colorIndex: Int
        let isUser: Bool
        let needsName: Bool
    }

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

    static func speechSeconds(in transcript: Transcript?) -> [String: TimeInterval] {
        var result: [String: TimeInterval] = [:]
        for segment in transcript?.segments ?? []
        where segment.start.isFinite && segment.end.isFinite && segment.end > segment.start && segment.start >= 0 {
            result[Transcript.canonicalSpeakerKey(segment.speaker), default: 0] += segment.end - segment.start
        }
        return result
    }

    static func speechMinutes(_ seconds: TimeInterval) -> Int {
        max(1, Int((seconds / 60).rounded()))
    }

    struct Caption: Equatable {
        let segmentIndex: Int
        let speakerKey: String
        let text: String
        let start: TimeInterval
    }

    struct PlayheadIndex {
        private let captions: [Caption]

        init(display: Transcript.DisplayIndex = .init()) {
            captions = display.segments.map {
                Caption(segmentIndex: $0.id, speakerKey: $0.speakerKey, text: $0.text, start: $0.segment.start)
            }.sorted { $0.start == $1.start ? $0.segmentIndex < $1.segmentIndex : $0.start < $1.start }
        }

        var isEmpty: Bool { captions.isEmpty }

        func caption(at time: TimeInterval) -> Caption? {
            var lower = 0, upper = captions.count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if captions[middle].start <= time { lower = middle + 1 } else { upper = middle }
            }
            return lower > 0 ? captions[lower - 1] : captions.first
        }
    }

    struct ActionGroups: Equatable {
        var forYou: [OutcomeActionReference] = []
        var forOthers: [OutcomeActionReference] = []
    }

    static func groups(_ actions: [OutcomeActionReference]) -> ActionGroups {
        ActionGroups(forYou: actions.filter(\.isForUser), forOthers: actions.filter { !$0.isForUser })
    }

    struct ActionsPanel: Equatable {
        enum Line: Equatable {
            case noActions
            case nothingForYou
            case nothingForOthers
        }

        let groups: ActionGroups

        init(_ actions: [OutcomeActionReference]) {
            groups = MeetingDetailPresentation.groups(actions)
        }

        var total: Int { groups.forYou.count + groups.forOthers.count }
        var count: Int? { total == 0 ? nil : total }
        var showsBands: Bool { total > 0 }
        var forYouLine: Line? { showsBands && groups.forYou.isEmpty ? .nothingForYou : nil }
        var forOthersLine: Line? { showsBands && groups.forOthers.isEmpty ? .nothingForOthers : nil }

        func showsActionsLink(hasSavedOutcomes: Bool, isSample: Bool) -> Bool {
            !groups.forYou.isEmpty && hasSavedOutcomes && !isSample
        }
    }

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
        let title: String
        let value: String
        let kind: Kind
        let isSelected: Bool
    }

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

    static func ownerCorrection(_ option: OwnerOption, for reference: OutcomeActionReference) -> OwnerCorrection? {
        let sameOwner = ownerKey(option.value) == ownerKey(reference.owner ?? "")
        if sameOwner, option.kind != .you || reference.isForUser { return nil }
        return OwnerCorrection(
            text: reference.textWasCorrected ? reference.text : nil,
            owner: option.value,
            due: reference.dueWasCorrected ? (reference.due ?? "") : nil)
    }

    static func storedSpeakerNames(in transcript: Transcript?, speakers: [Speaker]) -> [String: String] {
        guard let transcript else { return [:] }
        return Dictionary(speakers.map { ($0.id, transcript.displaySpeaker(for: $0.id)) },
                          uniquingKeysWith: { first, _ in first })
    }

    private static func ownerKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    static func rowSubtitle(time: String, duration: String, source: String?) -> String {
        ([time, duration] + (source.map { [$0] } ?? [])).filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

enum MeetingDetailLayout {
    static let gutter: CGFloat = 24
    static let panelGap: CGFloat = 16
    static let columnMaximumWidth: CGFloat = 1360
    static let proseWidth: CGFloat = 860
    static let findFieldWidth: CGFloat = 260
    static let findFieldMinimumWidth: CGFloat = 120

    static func factor(textScale: CGFloat) -> CGFloat {
        max(textScale, 0.5) / AppTextSize.standard.scale
    }

    static func proseWidth(textScale: CGFloat) -> CGFloat {
        (proseWidth * factor(textScale: textScale)).rounded()
    }

    static func findFieldWidth(textScale: CGFloat) -> CGFloat {
        (findFieldWidth * factor(textScale: textScale)).rounded()
    }

    static func pinnedTrailingInset(paneWidth: CGFloat, scrollContentWidth: CGFloat) -> CGFloat {
        guard paneWidth > 0, scrollContentWidth > 0 else { return 0 }
        let inset = paneWidth - scrollContentWidth
        guard inset >= 1, inset <= 40 else { return 0 }
        return inset.rounded()
    }

    enum FindPlacement: Equatable {
        case hidden
        case transcriptPanel
        case pinnedBar
    }

    static func findPlacement(tab: MeetingWorkspaceTab, pageSearchPresented: Bool) -> FindPlacement {
        if pageSearchPresented { return .pinnedBar }
        return tab == .transcript ? .transcriptPanel : .hidden
    }
}
