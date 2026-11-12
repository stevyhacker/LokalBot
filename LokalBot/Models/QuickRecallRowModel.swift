import Foundation

/// One row of the Quick Recall window: a meeting, a screen moment, a file, a
/// saved agent note or a command. Line one is the title, a grey qualifier
/// (the app, the folder, a meeting's length) and when; line two is the
/// matching line, starting with who said it for a meeting.
struct QuickRecallRowModel: Identifiable {
    enum Destination {
        case screen(Int64)
        case meeting(SearchIndex.Hit)
        /// A recent meeting, opened at its start.
        case recentMeeting(UUID)
        case file(FileSearchHit)
        case agentNote(AgentNoteHit)
        /// A `PaletteCommand` id.
        case command(String)
    }

    /// What leads the row.
    enum Lead: Equatable {
        /// A screen moment's thumbnail.
        case thumbnail(Int64)
        /// A tile with an SF Symbol: a meeting's waveform, a command's icon.
        case symbol(String)
        /// The file's own icon, which shows its type.
        case file(path: String)
        /// The red dot of Record now.
        case recording
    }

    let id: String
    let lead: Lead
    let title: String
    /// Grey text after the title.
    let qualifier: String?
    /// Who said the matching line, or which part of the meeting it is from.
    let speaker: String?
    let snippet: String?
    let timestamp: Date?
    /// A command's keyboard shortcut, shown where a result shows when.
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

    /// The qualifier under the name earlier callers use.
    var subtitle: String { qualifier ?? "" }

    /// The matching line without its search markers, led by who said it.
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
            // A window without a title is named by its app; do not say it twice.
            qualifier: title == appName ? nil : appName,
            snippet: snippet,
            timestamp: timestamp,
            isSaved: isSaved,
            destination: .screen(snapshotID))
    }

    /// `speaker` is who said the matching line, or the part of the meeting it
    /// came from (`meetingLead`).
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

    /// What starts a meeting's matching line: the speaker of a transcript
    /// line when the search hit names one, otherwise where the words are
    /// (your notes, the summary, an outcome). A title match needs neither.
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

    /// A recent meeting before anything is typed: its title, length and start.
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

    /// Where in the file the matching line is: a PDF's page, or the time in
    /// a recording or video.
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

    /// Saved keyword matches lead the Screens group. Use their own matching
    /// capture, even when another capture is the group's primary search result.
    /// A saved capture related only by meaning keeps its ranked place, so it
    /// cannot bury a capture that contains the searched words.
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
            // A saved capture already represents this source group.
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
