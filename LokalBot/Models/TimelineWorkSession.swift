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
    private(set) var title: String
    /// True when no window title covered enough of the session to name it,
    /// so the title lists the session's apps instead.
    let titleNamesApps: Bool
    let apps: [String]
    let contextSwitchCount: Int
    let titleEvidence: [TitleEvidence]
    /// Tracked time per project, busiest first. Empty without coding-agent
    /// evidence for the day.
    let projectShares: [TimelineProjectAttribution.Share]
    /// The agent bursts listed under this session. Each burst belongs to the
    /// one session it overlaps most, so its outcomes are counted once.
    private(set) var agentBursts: [CodingAgentBurst] = []
    /// True when the title names the session's project and the task its
    /// agents worked on, instead of a window or its apps.
    private(set) var titleNamesProject = false
    var notableTitles: [String] { titleEvidence.map(\.title) }

    var appCount: Int { apps.count }

    /// The project the title names.
    var project: String? { titleNamesProject ? projectShares.first?.project : nil }

    var outcomes: TimelineAgentOutcomes { TimelineAgentOutcomes(agentBursts) }

    /// Titles are observed window/document names, not generated task claims.
    /// Keep the source blocks so the label can always be inspected.
    struct TitleEvidence: Identifiable, Equatable, Sendable {
        let title: String
        let blocks: [ActivityBlock]
        var id: String { title.lowercased() }
        let duration: TimeInterval
    }

    private struct TitledBlock {
        let block: ActivityBlock
        let title: String?
        /// The block's time per project, empty without agent evidence.
        var shares: [TimelineProjectAttribution.Share] = []
        /// The project that holds most of the block's time.
        var project: String? { shares.first?.project }
    }

    /// Work that moves to another project for this long starts a session.
    static let projectSwitch: TimeInterval = 10 * 60
    /// A project names the session once it holds this share of its time.
    static let projectTitleShare = 0.2
    /// A burst that overlaps no session joins the nearest one this close.
    static let burstAttachDistance: TimeInterval = 15 * 60

    /// Collapse adjacent blocks into one work session. A short gap usually
    /// represents reading, typing, or switching apps rather than a new task.
    /// With coding-agent evidence, sessions end where the work moves to
    /// another project instead of at a fixed length, and take their names
    /// from the project and its agents' tasks.
    static func sessions(
        from sourceBlocks: [ActivityBlock],
        maximumGap: TimeInterval = 5 * 60,
        maximumDuration: TimeInterval = 45 * 60,
        attribution: TimelineProjectAttribution? = nil
    ) -> [TimelineWorkSession] {
        let blocks = sourceBlocks
            .filter { $0.end > $0.start && !isSystemOnly(app: $0.app) }
            .sorted {
                if $0.start == $1.start { return $0.id < $1.id }
                return $0.start < $1.start
            }
        var titled = blocks.map { TitledBlock(block: $0, title: cleanedTitle($0.title, app: $0.app)) }
        guard let attribution, !attribution.bursts.isEmpty else {
            return appGroups(titled, maximumGap: maximumGap, maximumDuration: maximumDuration)
                .compactMap(makeSession)
        }
        let groups: [[TitledBlock]]
        if attribution.isEmpty {
            groups = appGroups(titled, maximumGap: maximumGap, maximumDuration: maximumDuration)
        } else {
            // Ranked shares, so each block's first share is its project.
            let shares = attribution.shares(for: blocks)
            for index in titled.indices { titled[index].shares = shares[index] }
            groups = projectGroups(titled, maximumGap: maximumGap, maximumDuration: maximumDuration)
        }
        return assigningAgentWork(attribution.bursts, to: groups.compactMap(makeSession))
    }

    /// Cuts at gaps, after `maximumDuration`, and where a new document holds
    /// attention for a while.
    private static func appGroups(
        _ titled: [TitledBlock],
        maximumGap: TimeInterval,
        maximumDuration: TimeInterval
    ) -> [[TitledBlock]] {
        guard let first = titled.first else { return [] }
        var groups: [[TitledBlock]] = []
        var current = [first]
        var currentEnd = first.block.end
        var seenTitles = Set(first.title.map { [$0.lowercased()] } ?? [])

        for observed in titled.dropFirst() {
            let block = observed.block
            let title = observed.title?.lowercased()
            let elapsed = block.start.timeIntervalSince(current[0].block.start)
            // Short tool/app switches stay together. A sustained, previously
            // unseen document after ten minutes is an inspectable boundary.
            // Never cut overlapping blocks: that would double-count activity.
            let sustainedChange = elapsed >= 10 * 60 && block.duration >= 3 * 60
                && title.map { !seenTitles.contains($0) } == true
            let newSegment = block.start >= currentEnd
                && (elapsed >= max(60, maximumDuration) || sustainedChange)
            if block.start.timeIntervalSince(currentEnd) <= maximumGap && !newSegment {
                current.append(observed)
                currentEnd = max(currentEnd, block.end)
            } else {
                groups.append(current)
                current = [observed]
                currentEnd = block.end
                seenTitles = []
            }
            if let title { seenTitles.insert(title) }
        }
        groups.append(current)
        return groups
    }

    /// Cuts at gaps and where the work moves to another project for at least
    /// `projectSwitch`. A brief look elsewhere stays inside the session, and a
    /// project session has no length limit. A stretch too short to stand on
    /// its own joins the work that follows it. Stretches no project claims,
    /// such as reading or chat, fall back to the app rules.
    private static func projectGroups(
        _ titled: [TitledBlock],
        maximumGap: TimeInterval,
        maximumDuration: TimeInterval
    ) -> [[TitledBlock]] {
        guard let first = titled.first else { return [] }
        var segments: [(project: String?, blocks: [TitledBlock])] = []
        var current = [first]
        var currentProject = first.project
        var currentSeconds = first.block.duration
        var currentEnd = first.block.end
        // Time each other project (or none) has held since the current one
        // was last seen, and the index where that run began.
        var pending: [String?: (index: Int, seconds: TimeInterval)] = [:]

        for observed in titled.dropFirst() {
            let block = observed.block
            let project = observed.project
            if block.start.timeIntervalSince(currentEnd) > maximumGap {
                segments.append((currentProject, current))
                current = [observed]
                currentProject = project
                currentSeconds = block.duration
                currentEnd = block.end
                pending = [:]
                continue
            }
            current.append(observed)
            currentEnd = max(currentEnd, block.end)
            if project == currentProject {
                currentSeconds += block.duration
                pending = [:]
                continue
            }
            let run = pending[project] ?? (index: current.count - 1, seconds: 0)
            let seconds = run.seconds + block.duration
            pending[project] = (run.index, seconds)
            guard seconds >= projectSwitch else { continue }
            if currentSeconds >= projectSwitch {
                // Wait for an edge no earlier block still runs across.
                guard let cut = cutIndex(in: current, from: run.index) else { continue }
                segments.append((currentProject, Array(current[..<cut])))
                current = Array(current[cut...])
            }
            // A stretch too short to stand alone joins the new project's.
            currentProject = project
            currentSeconds = seconds
            pending = [:]
        }
        segments.append((currentProject, current))

        var groups: [[TitledBlock]] = []
        for segment in segments {
            if segment.project == nil {
                groups += appGroups(segment.blocks, maximumGap: maximumGap, maximumDuration: maximumDuration)
            } else {
                groups.append(segment.blocks)
            }
        }
        return groups
    }

    /// The first index at or after `from` where no earlier block is still
    /// running, so a cut never splits overlapping activity.
    private static func cutIndex(in blocks: [TitledBlock], from start: Int) -> Int? {
        guard start > 0, start < blocks.count else { return nil }
        var runningEnd = blocks[0].block.end
        for index in 1..<blocks.count {
            if index >= start, blocks[index].block.start >= runningEnd { return index }
            runningEnd = max(runningEnd, blocks[index].block.end)
        }
        return nil
    }

    /// Lists each burst under the session it overlaps most, or the nearest
    /// one when the agent worked between sessions, then names project
    /// sessions after the task their agents worked on.
    private static func assigningAgentWork(
        _ bursts: [CodingAgentBurst],
        to sessions: [TimelineWorkSession]
    ) -> [TimelineWorkSession] {
        var assigned = Array(repeating: [CodingAgentBurst](), count: sessions.count)
        for burst in bursts {
            var best: (index: Int, overlap: TimeInterval)?
            var nearest: (index: Int, distance: TimeInterval)?
            for (index, session) in sessions.enumerated() {
                let overlap = min(burst.end, session.end).timeIntervalSince(max(burst.start, session.start))
                if overlap > 0 {
                    if overlap > (best?.overlap ?? 0) { best = (index, overlap) }
                } else if -overlap <= burstAttachDistance, -overlap < (nearest?.distance ?? .infinity) {
                    nearest = (index, -overlap)
                }
            }
            if let index = best?.index ?? nearest?.index { assigned[index].append(burst) }
        }
        var result = sessions
        for index in result.indices {
            result[index].agentBursts = assigned[index]
            result[index].nameAfterProject(bursts: bursts)
        }
        return result
    }

    /// "bizstats · Rehearse the audit runbook on staging": the busiest
    /// project, then the task of its burst that overlaps the session most.
    /// A second project that also holds a fair share is named too, as in
    /// "bizstats, alpha · …", so a review in the browser beside agent work
    /// is not lost.
    private mutating func nameAfterProject(bursts: [CodingAgentBurst]) {
        let threshold = max(60, activeDuration * Self.projectTitleShare)
        guard let top = projectShares.first, top.seconds >= threshold else { return }
        var named = [top.project]
        if projectShares.count > 1, projectShares[1].seconds >= threshold {
            named.append(projectShares[1].project)
        }
        let projects = named.joined(separator: ", ")
        let listed = agentBursts.filter { $0.workProject == top.project }
        let candidates = listed.isEmpty ? bursts.filter { $0.workProject == top.project } : listed
        var task: String?
        var longest: TimeInterval = 0
        for burst in candidates {
            let overlap = min(burst.end, end).timeIntervalSince(max(burst.start, start))
            if overlap > longest {
                longest = overlap
                task = burst.workTitle
            }
        }
        if let task {
            title = "\(projects) · \(task)"
        } else if !titleNamesApps {
            title = "\(projects) · \(title)"
        } else {
            title = projects
        }
        titleNamesProject = true
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

    private static func makeSession(_ sourceBlocks: [TitledBlock]) -> TimelineWorkSession? {
        let blocks = sourceBlocks.map(\.block)
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
        let activeDuration = mergedDuration(blocks)
        let evidence = rankedTitleEvidence(in: sourceBlocks)
        // A fleeting page should remain inspectable without naming the whole session.
        let representativeTitles = evidence.filter { $0.duration >= activeDuration * 0.2 }.map(\.title)
        // Apps glanced at for seconds (a password prompt, a notification)
        // stay in `apps` but don't inflate the title's count.
        let usedApps = apps.filter { (appDurations[$0] ?? 0) >= 60 }
        let title = representativeTitles.isEmpty
            ? appSummary(usedApps.isEmpty ? apps : usedApps)
            : representativeTitles.prefix(2).joined(separator: " · ")

        return TimelineWorkSession(
            id: first.id,
            blocks: blocks,
            start: start,
            end: end,
            activeDuration: activeDuration,
            primaryApp: primaryApp,
            title: title,
            titleNamesApps: representativeTitles.isEmpty,
            apps: apps,
            contextSwitchCount: contextSwitches(in: blocks),
            titleEvidence: evidence,
            projectShares: projectShares(of: sourceBlocks))
    }

    /// "Claude", "Claude, Safari" or "Claude, Safari +2": the two busiest
    /// apps, then how many more.
    static func appSummary(_ apps: [String]) -> String {
        let named = apps.prefix(2).joined(separator: ", ")
        return apps.count > 2 ? "\(named) +\(apps.count - 2)" : named
    }

    static func mergedDuration(_ blocks: [ActivityBlock]) -> TimeInterval {
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

    private static func projectShares(of blocks: [TitledBlock]) -> [TimelineProjectAttribution.Share] {
        var seconds: [String: TimeInterval] = [:]
        for block in blocks {
            for share in block.shares {
                seconds[share.project, default: 0] += share.seconds
            }
        }
        var shares: [TimelineProjectAttribution.Share] = []
        for (project, total) in seconds {
            shares.append(TimelineProjectAttribution.Share(project: project, seconds: total))
        }
        return TimelineProjectAttribution.ranked(shares)
    }

    private static func rankedTitleEvidence(in blocks: [TitledBlock]) -> [TitleEvidence] {
        var blocksByTitle: [String: [ActivityBlock]] = [:]
        var displayTitle: [String: String] = [:]
        var firstIndex: [String: Int] = [:]

        for (index, observed) in blocks.enumerated() {
            let block = observed.block
            guard let title = observed.title else { continue }
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
        }.map { key in
            TitleEvidence(title: displayTitle[key] ?? key, blocks: blocksByTitle[key] ?? [],
                          duration: durationByTitle[key] ?? 0)
        }
    }

    static func cleanedTitle(_ raw: String, app: String) -> String? {
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
        "audio playing", "audio muted", "camera recording", "microphone recording",
        "camera and microphone recording", "high memory usage", "pinned",
        "bluetooth device connected", "usb device connected",
    ]

    private static func isBrowserChromeSegment(_ segment: String) -> Bool {
        let lowered = segment.lowercased().trimmingCharacters(in: .whitespaces)
        // Chrome names the tab group a tab belongs to ("Part of group Work").
        return browserChromeMarkers.contains(lowered) || lowered.hasPrefix("part of group ")
    }

    static func strippingBrowserChrome(_ title: String) -> String {
        for separator in [" - ", " — "] {
            let parts = title.components(separatedBy: separator)
            guard parts.count > 1 else { continue }
            let cut = parts.firstIndex(where: isBrowserChromeSegment)
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

    var end: Date {
        switch self {
        case .work(let session): session.end
        case .meeting(_, let end): end
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

/// A row of the Timeline session rail: a session or meeting, or a long
/// stretch with no recorded activity between them.
enum TimelineRailRow: Identifiable {
    case item(TimelineDayItem)
    case away(start: Date, end: Date)

    var id: String {
        switch self {
        case .item(let item): item.id
        case .away(let start, _): "away-\(Int(start.timeIntervalSince1970))"
        }
    }

    /// Inserts an away row wherever nothing was recorded for at least
    /// `minimumGap`. Items overlap (a meeting runs over its sessions), so a
    /// gap starts at the latest end seen so far.
    static func rows(
        items: [TimelineDayItem],
        minimumGap: TimeInterval = 30 * 60
    ) -> [TimelineRailRow] {
        var rows: [TimelineRailRow] = []
        var latestEnd: Date?
        for item in items {
            if let latestEnd, item.start.timeIntervalSince(latestEnd) >= minimumGap {
                rows.append(.away(start: latestEnd, end: item.start))
            }
            rows.append(.item(item))
            latestEnd = max(latestEnd ?? item.end, item.end)
        }
        return rows
    }
}
