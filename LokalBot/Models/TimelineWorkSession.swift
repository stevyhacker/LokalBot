import Foundation

/// A human-scale stretch of continuous Mac activity. Timeline presents these
/// sessions instead of exposing every sampler-produced block as a separate
/// visual stripe. The underlying blocks remain available in Raw capture.
struct TimelineWorkSession: Identifiable, Equatable, Sendable {
    let id: Int64
    let blocks: [ActivityBlock]
    let start: Date
    let end: Date
    let activeDuration: TimeInterval
    let primaryApp: String
    let title: String
    let apps: [String]
    let contextSwitchCount: Int
    let notableTitles: [String]

    var appCount: Int { apps.count }

    /// Titles are observed window/document names, not generated task claims.
    /// Keep the source blocks so the label can always be inspected.
    struct TitleEvidence: Identifiable {
        let title: String
        let blocks: [ActivityBlock]
        var id: String { title.lowercased() }
        var duration: TimeInterval { TimelineWorkSession.mergedDuration(blocks) }
    }

    var titleEvidence: [TitleEvidence] {
        let byTitle = Dictionary(grouping: blocks) { Self.cleanedTitle($0.title, app: $0.app)?.lowercased() ?? "" }
        return notableTitles.map { TitleEvidence(title: $0, blocks: byTitle[$0.lowercased()] ?? []) }
    }

    /// Collapse adjacent blocks into one work session. A short gap usually
    /// represents reading, typing, or switching apps rather than a new task.
    static func sessions(
        from sourceBlocks: [ActivityBlock],
        maximumGap: TimeInterval = 5 * 60,
        maximumDuration: TimeInterval = 45 * 60
    ) -> [TimelineWorkSession] {
        let blocks = sourceBlocks
            .filter { $0.end > $0.start && !isSystemOnly(app: $0.app) }
            .sorted {
                if $0.start == $1.start { return $0.id < $1.id }
                return $0.start < $1.start
            }
        guard let first = blocks.first else { return [] }

        var groups: [[ActivityBlock]] = []
        var current = [first]
        var currentEnd = first.end
        var seenTitles = Set(cleanedTitle(first.title, app: first.app).map { [$0.lowercased()] } ?? [])

        for block in blocks.dropFirst() {
            let title = cleanedTitle(block.title, app: block.app)?.lowercased()
            let elapsed = block.start.timeIntervalSince(current[0].start)
            // Short tool/app switches stay together. A sustained, previously
            // unseen document after ten minutes is an inspectable boundary.
            // Never cut overlapping blocks: that would double-count activity.
            let sustainedChange = elapsed >= 10 * 60 && block.duration >= 3 * 60
                && title.map { !seenTitles.contains($0) } == true
            let newSegment = block.start >= currentEnd
                && (elapsed >= max(60, maximumDuration) || sustainedChange)
            if block.start.timeIntervalSince(currentEnd) <= maximumGap && !newSegment {
                current.append(block)
                currentEnd = max(currentEnd, block.end)
            } else {
                groups.append(current)
                current = [block]
                currentEnd = block.end
                seenTitles = []
            }
            if let title { seenTitles.insert(title) }
        }
        groups.append(current)
        return groups.compactMap(makeSession)
    }

    static func isSystemOnly(app: String) -> Bool {
        let normalized = app.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return [
            "loginwindow",
            "windowserver",
            "systemuiserver",
            "controlcenter",
            "notificationcenter",
        ].contains(normalized)
    }

    private static func makeSession(_ sourceBlocks: [ActivityBlock]) -> TimelineWorkSession? {
        let blocks = sourceBlocks.sorted { $0.start < $1.start }
        guard let first = blocks.first else { return nil }
        let start = first.start
        let end = blocks.map(\.end).max() ?? first.end
        let appDurations = Dictionary(grouping: blocks, by: \.app)
            .mapValues { mergedDuration($0) }
        var firstAppIndex: [String: Int] = [:]
        for (index, block) in blocks.enumerated() {
            firstAppIndex[block.app] = firstAppIndex[block.app] ?? index
        }
        let apps = appDurations.keys.sorted { lhs, rhs in
            let leftDuration = appDurations[lhs] ?? 0
            let rightDuration = appDurations[rhs] ?? 0
            if leftDuration == rightDuration {
                return (firstAppIndex[lhs] ?? .max) < (firstAppIndex[rhs] ?? .max)
            }
            return leftDuration > rightDuration
        }
        let primaryApp = apps.first ?? first.app
        let notableTitles = rankedTitles(in: blocks)
        let title = notableTitles.isEmpty
            ? apps.prefix(2).joined(separator: " and ") + (apps.count > 2 ? " and more" : "")
            : notableTitles.prefix(2).joined(separator: " · ")

        return TimelineWorkSession(
            id: first.id,
            blocks: blocks,
            start: start,
            end: end,
            activeDuration: mergedDuration(blocks),
            primaryApp: primaryApp,
            title: title,
            apps: apps,
            contextSwitchCount: contextSwitches(in: blocks),
            notableTitles: notableTitles)
    }

    private static func mergedDuration(_ blocks: [ActivityBlock]) -> TimeInterval {
        let ordered = blocks.sorted { $0.start < $1.start }
        guard let first = ordered.first else { return 0 }
        var total: TimeInterval = 0
        var intervalStart = first.start
        var intervalEnd = first.end

        for block in ordered.dropFirst() {
            if block.start <= intervalEnd {
                intervalEnd = max(intervalEnd, block.end)
            } else {
                total += intervalEnd.timeIntervalSince(intervalStart)
                intervalStart = block.start
                intervalEnd = block.end
            }
        }
        total += intervalEnd.timeIntervalSince(intervalStart)
        return max(0, total)
    }

    private static func rankedTitles(in blocks: [ActivityBlock]) -> [String] {
        var blocksByTitle: [String: [ActivityBlock]] = [:]
        var displayTitle: [String: String] = [:]
        var firstIndex: [String: Int] = [:]

        for (index, block) in blocks.enumerated() {
            let title = cleanedTitle(block.title, app: block.app)
            guard let title else { continue }
            let key = title.lowercased()
            blocksByTitle[key, default: []].append(block)
            displayTitle[key] = displayTitle[key] ?? title
            firstIndex[key] = firstIndex[key] ?? index
        }

        let durationByTitle = blocksByTitle.mapValues { mergedDuration($0) }
        return durationByTitle.keys.sorted { lhs, rhs in
            let leftDuration = durationByTitle[lhs] ?? 0
            let rightDuration = durationByTitle[rhs] ?? 0
            if leftDuration == rightDuration {
                return (firstIndex[lhs] ?? .max) < (firstIndex[rhs] ?? .max)
            }
            return leftDuration > rightDuration
        }.compactMap { displayTitle[$0] }
    }

    private static func cleanedTitle(_ raw: String, app: String) -> String? {
        let compact = strippingBrowserChrome(
            raw
                .replacingOccurrences(of: "\n", with: " ")
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines))
        let normalized = compact.lowercased()
        let generic: Set<String> = [
            "", "home", "login", "login window", "new tab", "timeline", "today", "unknown",
        ]
        guard !generic.contains(normalized),
              normalized != app.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        else { return nil }
        // Do not truncate the grouping key: distinct long document names can
        // share a prefix. Views truncate visually and keep the full AX label.
        return compact
    }

    /// Chromium-family windows append status and identity segments to the page
    /// title ("Page - Audio playing - Google Chrome - Stevan"); Firefox appends
    /// "Page — Mozilla Firefox". Those trailing segments are browser chrome,
    /// not content — cut from the first marker segment onward so a session
    /// reads as the page the user actually saw.
    private static let browserChromeMarkers: Set<String> = [
        "google chrome", "google chrome beta", "google chrome canary", "chromium",
        "microsoft edge", "brave", "vivaldi", "opera", "arc",
        "mozilla firefox", "firefox",
        "audio playing", "camera recording", "microphone recording",
        "high memory usage",
    ]

    static func strippingBrowserChrome(_ title: String) -> String {
        for separator in [" - ", " — "] {
            let parts = title.components(separatedBy: separator)
            guard parts.count > 1 else { continue }
            let cut = parts.firstIndex {
                browserChromeMarkers.contains(
                    $0.lowercased().trimmingCharacters(in: .whitespaces))
            }
            if let cut, cut > 0 {
                return parts[..<cut].joined(separator: separator)
            }
        }
        return title
    }

    private static func contextSwitches(in blocks: [ActivityBlock]) -> Int {
        var previous: String?
        var switches = 0
        for block in blocks {
            let app = block.app.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let previous, previous != app { switches += 1 }
            previous = app
        }
        return switches
    }
}

/// The primary Timeline stream interleaves grouped work with meetings without
/// conflating meeting duration with foreground-app sampling.
enum TimelineDayItem: Identifiable {
    case work(TimelineWorkSession)
    case meeting(Meeting, end: Date)

    var id: String {
        switch self {
        case .work(let session): "work-\(session.id)"
        case .meeting(let meeting, _): "meeting-\(meeting.id.uuidString)"
        }
    }

    var start: Date {
        switch self {
        case .work(let session): session.start
        case .meeting(let meeting, _): meeting.startedAt
        }
    }

    static func items(
        sessions: [TimelineWorkSession],
        meetings: [Meeting],
        now: Date
    ) -> [TimelineDayItem] {
        let meetingItems = meetings.map {
            TimelineDayItem.meeting($0, end: CaptureTrackItem.meetingEnd($0, now: now))
        }
        return (sessions.map(TimelineDayItem.work) + meetingItems)
            .sorted { $0.start < $1.start }
    }
}
