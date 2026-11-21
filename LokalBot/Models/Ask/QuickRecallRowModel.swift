import Foundation

struct QuickRecallRowModel: Identifiable {
    enum Destination {
        case screen(Int64)
        case meeting(SearchIndex.Hit)
        case recentMeeting(UUID)
        case file(FileSearchHit)
        case agentNote(AgentNoteHit)
        case command(String)
    }

    enum Lead: Equatable {
        case thumbnail(Int64)
        case symbol(String)
        case file(path: String)
        case recording
    }

    let id: String
    let lead: Lead
    let title: String
    let qualifier: String?
    let speaker: String?
    let snippet: String?
    let timestamp: Date?
    let shortcut: String?
    let isSaved: Bool
    let destination: Destination

    init(id: String, lead: Lead, title: String, qualifier: String? = nil, speaker: String? = nil,
         snippet: String? = nil, timestamp: Date? = nil, shortcut: String? = nil, isSaved: Bool = false,
         destination: Destination) {
        self.id = id
        self.lead = lead
        self.title = title
        self.qualifier = qualifier.flatMap { $0.isEmpty ? nil : $0 }
        self.speaker = speaker.flatMap { $0.isEmpty ? nil : $0 }
        self.snippet = snippet.flatMap { $0.isEmpty ? nil : $0 }
        self.timestamp = timestamp
        self.shortcut = shortcut.flatMap { $0.isEmpty ? nil : $0 }
        self.isSaved = isSaved
        self.destination = destination
    }

    var snapshotID: Int64? {
        guard case .screen(let snapshotID) = destination else { return nil }
        return snapshotID
    }

    var subtitle: String { qualifier ?? "" }

    var plainSnippet: String? {
        guard let snippet else { return nil }
        let text = SnippetHighlighter.segments(snippet).map(\.text).joined()
        return speaker.map { "\($0): \(text)" } ?? text
    }

    var accessibilityValue: String {
        [isSaved ? "Saved" : nil, qualifier, plainSnippet, shortcut]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ". ")
    }

    static func screen(
        snapshotID: Int64,
        appName: String,
        title: String,
        snippet: String?,
        timestamp: Date,
        isSaved: Bool = false
    ) -> Self {
        .init(
            id: "screen.\(snapshotID)",
            lead: .thumbnail(snapshotID),
            title: title,
            qualifier: title == appName ? nil : appName,
            snippet: snippet,
            timestamp: timestamp,
            isSaved: isSaved,
            destination: .screen(snapshotID))
    }

    static func meeting(hit: SearchIndex.Hit, title: String, speaker: String?, timestamp: Date?) -> Self {
        .init(
            id: "meeting.\(hit.meetingID).\(hit.kind.rawValue).\(hit.start)",
            lead: .symbol("waveform"),
            title: title,
            speaker: speaker,
            snippet: hit.kind == .title ? SnippetCleaner.withoutTitleEcho(hit.snippet, title: title) : hit.snippet,
            timestamp: timestamp,
            destination: .meeting(hit))
    }

    static func meetingLead(_ hit: SearchIndex.Hit, localize: (String) -> String = { $0 }) -> String? {
        switch hit.kind {
        case .segment:
            let speaker = hit.speaker.trimmingCharacters(in: .whitespacesAndNewlines)
            return speaker.isEmpty ? nil : SpeakerDisplayName.label(speaker)
        case .notes: return localize("Your notes")
        case .summary: return localize("Summary")
        case .outcome: return localize("Outcome")
        case .title: return nil
        }
    }

    static func recentMeeting(id: UUID, title: String, duration: String?, startedAt: Date) -> Self {
        .init(
            id: "recent.meeting.\(id.uuidString)",
            lead: .symbol("waveform"),
            title: title,
            qualifier: duration,
            timestamp: startedAt,
            destination: .recentMeeting(id))
    }

    static func agentNote(_ hit: AgentNoteHit) -> Self {
        .init(
            id: "agentNote.\(hit.id)",
            lead: .symbol("note.text"),
            title: hit.title,
            qualifier: hit.sourceLabel,
            snippet: hit.snippet.isEmpty ? hit.summary : hit.snippet,
            timestamp: hit.modified,
            destination: .agentNote(hit))
    }

    static func file(_ hit: FileSearchHit, localize: (String) -> String = { $0 }) -> Self {
        .init(
            id: "file.\(hit.id)",
            lead: .file(path: hit.path),
            title: hit.name,
            qualifier: hit.folder,
            speaker: hit.excerpt == nil ? nil : fileLead(hit, localize: localize),
            snippet: hit.excerpt,
            timestamp: hit.date,
            destination: .file(hit))
    }

    static func fileLead(_ hit: FileSearchHit, localize: (String) -> String = { $0 }) -> String? {
        if let page = hit.page { return String(format: localize("Page %lld"), page) }
        if let seconds = hit.seconds { return Transcript.shortStamp(seconds) }
        return nil
    }

    static func command(_ command: PaletteCommand) -> Self {
        .init(
            id: "command.\(command.id)",
            lead: command.id == "record" && command.icon == "record.circle" ? .recording : .symbol(command.icon),
            title: command.title,
            qualifier: command.detail,
            shortcut: command.shortcut,
            destination: .command(command.id))
    }

    static func screens(
        groups: [ScreenRecallGroup],
        savedMoments: [ActivityStore.SavedMoment],
        hasQuery: Bool
    ) -> [Self] {
        guard hasQuery else {
            return savedMoments.prefix(12).map { saved($0) }
        }
        let hits = Dictionary(groups.flatMap(\.matches).map { ($0.snapshotID, $0) },
                              uniquingKeysWith: { first, _ in first })
        let savedByID = Dictionary(savedMoments.map { ($0.snapshotID, $0) },
                                   uniquingKeysWith: { first, _ in first })
        let savedRows = savedMoments.compactMap { moment -> Self? in
            guard let hit = hits[moment.snapshotID], !hit.isSemantic else { return nil }
            return saved(moment, hit: hit)
        }
        let savedIDs = Set(savedRows.compactMap(\.snapshotID))
        let otherRows = groups.compactMap { group -> Self? in
            guard !group.matches.contains(where: { savedIDs.contains($0.snapshotID) }),
                  let hit = group.matches.first else { return nil }
            if let moment = savedByID[hit.snapshotID] { return saved(moment, hit: hit) }
            let title = hit.windowTitle.isEmpty ? hit.app : hit.windowTitle
            return .screen(
                snapshotID: hit.snapshotID, appName: hit.app, title: title,
                snippet: SnippetCleaner.withoutTitleEcho(hit.snippet, title: title),
                timestamp: hit.ts)
        }
        return savedRows + otherRows
    }

    static func saved(_ moment: ActivityStore.SavedMoment, hit: ActivityStore.OCRHit? = nil) -> Self {
        let title = moment.note.isEmpty
            ? (moment.windowTitle.isEmpty ? moment.app : moment.windowTitle)
            : moment.note
        return .screen(
            snapshotID: moment.snapshotID, appName: moment.app,
            title: title,
            snippet: hit.flatMap { SnippetCleaner.withoutTitleEcho($0.snippet, title: title) },
            timestamp: moment.ts, isSaved: true)
    }
}
