import Foundation

struct QuickRecallSection: Identifiable {
    let id: String
    let title: String
    let rows: [QuickRecallRowModel]
}

struct QuickRecallRowModel: Identifiable {
    enum Destination {
        case screen(Int64)
        case meeting(SearchIndex.Hit)
        /// A `PaletteCommand` id.
        case command(String)
    }

    let id: String
    let icon: String
    let appName: String?
    let title: String
    let subtitle: String
    let snippet: String?
    let timestamp: Date?
    let captureCount: Int
    let isSaved: Bool
    let destination: Destination

    var snapshotID: Int64? {
        guard case .screen(let snapshotID) = destination else { return nil }
        return snapshotID
    }

    var accessibilityValue: String {
        [isSaved ? "Saved" : nil, subtitle, snippet.map { text in
            SnippetHighlighter.segments(text).map(\.text).joined()
        }]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ". ")
    }

    static func screen(
        snapshotID: Int64,
        appName: String,
        title: String,
        subtitle: String,
        snippet: String?,
        timestamp: Date,
        captureCount: Int = 1,
        isSaved: Bool = false
    ) -> Self {
        .init(
            id: "screen.\(snapshotID)",
            icon: "rectangle.on.rectangle",
            appName: appName,
            title: title,
            subtitle: subtitle,
            snippet: snippet,
            timestamp: timestamp,
            captureCount: max(1, captureCount),
            isSaved: isSaved,
            destination: .screen(snapshotID))
    }

    static func meeting(
        hit: SearchIndex.Hit,
        appName: String,
        title: String,
        subtitle: String,
        snippet: String?,
        timestamp: Date?
    ) -> Self {
        .init(
            id: "meeting.\(hit.meetingID).\(hit.kind.rawValue).\(hit.start)",
            icon: "waveform",
            appName: appName,
            title: title,
            subtitle: subtitle,
            snippet: snippet,
            timestamp: timestamp,
            captureCount: 1,
            isSaved: false,
            destination: .meeting(hit))
    }

    static func command(_ command: PaletteCommand) -> Self {
        .init(
            id: "command.\(command.id)",
            icon: command.icon,
            appName: nil,
            title: command.title,
            subtitle: command.subtitle,
            snippet: nil,
            timestamp: nil,
            captureCount: 1,
            isSaved: false,
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
            return savedMoments.prefix(12).map { saved($0, hit: nil) }
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
                subtitle: hit.app,
                snippet: SnippetCleaner.withoutTitleEcho(hit.snippet, title: title),
                timestamp: hit.ts, captureCount: hit.captureCount)
        }
        return savedRows + otherRows
    }

    private static func saved(_ moment: ActivityStore.SavedMoment, hit: ActivityStore.OCRHit?) -> Self {
        let title = moment.note.isEmpty
            ? (moment.windowTitle.isEmpty ? moment.app : moment.windowTitle)
            : moment.note
        return .screen(
            snapshotID: moment.snapshotID, appName: moment.app,
            title: title, subtitle: moment.app,
            snippet: hit.flatMap { SnippetCleaner.withoutTitleEcho($0.snippet, title: title) },
            timestamp: moment.ts, captureCount: hit?.captureCount ?? 1, isSaved: true)
    }
}
