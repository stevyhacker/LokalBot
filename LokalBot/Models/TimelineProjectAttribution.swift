import Foundation

/// Splits the day's foreground activity across the projects its coding-agent
/// sessions worked in. A window whose title names a project counts toward
/// it. Time in an app where an agent runs (Claude, Codex, a terminal, an
/// editor) goes to the agent bursts it overlaps, and only for the part those
/// bursts cover. Everything else stays unattributed. This is deterministic
/// matching on project and repository names; no model decides.
struct TimelineProjectAttribution: Sendable {
    struct Share: Equatable, Sendable {
        let project: String
        let seconds: TimeInterval
    }

    /// The day's tracked time by project, plus the time no project claims.
    struct DaySplit: Equatable, Sendable {
        var projects: [Share] = []
        var unattributedSeconds: TimeInterval = 0
    }

    /// Bursts the person started, not scheduled runs, oldest first.
    let bursts: [CodingAgentBurst]
    private let projects: [(name: String, termSets: [Set<String>])]
    private let burstProjects: [String?]

    /// Agent activity counts for a window this close to a burst's edges: a
    /// burst starts with the request, which the person typed just before.
    static let edgeMargin: TimeInterval = 2 * 60

    init(bursts source: [CodingAgentBurst]) {
        bursts = source.filter { !$0.isScheduledRun && $0.end > $0.start }
            .sorted { $0.start < $1.start }
        burstProjects = bursts.map(\.workProject)
        // The busiest project wins a title that names two.
        var activeByProject: [String: TimeInterval] = [:]
        var linksByRepository: [Set<String>: [String: Int]] = [:]
        for (burst, project) in zip(bursts, burstProjects) {
            guard let project else { continue }
            activeByProject[project, default: 0] += burst.activeDuration
            for pullRequest in burst.pullRequestReferences {
                let terms = ProjectLinks.significantTerms(pullRequest.repository)
                linksByRepository[terms, default: [:]][project, default: 0] += 1
            }
        }
        let ranked = activeByProject.keys.sorted {
            let left = activeByProject[$0] ?? 0, right = activeByProject[$1] ?? 0
            return left == right ? $0 < $1 : left > right
        }
        var termSets: [String: [Set<String>]] = [:]
        for name in ranked {
            termSets[name] = [ProjectLinks.significantTerms(name)]
        }
        // A repository a session linked names its project too, as when the
        // folder is "alpha" and the repository "logic-onchain". One named
        // after a project of the day stays that project's; any other goes to
        // the project that linked it most.
        let projectNames = Set(ranked.map(ProjectLinks.significantTerms))
        for (repository, links) in linksByRepository where !repository.isEmpty && !projectNames.contains(repository) {
            var owner: (project: String, count: Int)?
            for (project, count) in links {
                if let current = owner, current.count > count || (current.count == count && current.project < project) {
                    continue
                }
                owner = (project, count)
            }
            if let owner { termSets[owner.project, default: []].append(repository) }
        }
        projects = ranked.map { name in (name, (termSets[name] ?? []).filter { !$0.isEmpty }) }
    }

    var isEmpty: Bool { projects.isEmpty }

    /// The project this block's time goes to, by its largest share.
    func dominantProject(for block: ActivityBlock) -> String? {
        shares(for: block).first?.project
    }

    /// The block's time per project, busiest first. The shares never add up
    /// to more than the block's duration; the remainder is unattributed.
    func shares(for block: ActivityBlock) -> [Share] {
        shares(for: block, namedProject: namedProject(title: block.title, app: block.app))
    }

    /// Each block's shares, in order. A day repeats the same window titles
    /// many times, so each distinct one is matched against the projects once.
    func shares(for blocks: [ActivityBlock]) -> [[Share]] {
        var named: [String: String?] = [:]
        var result: [[Share]] = []
        result.reserveCapacity(blocks.count)
        for block in blocks {
            let key = block.app + "\u{1f}" + block.title
            let project: String?
            if let cached = named[key] {
                project = cached
            } else {
                project = namedProject(title: block.title, app: block.app)
                named[key] = project
            }
            result.append(shares(for: block, namedProject: project))
        }
        return result
    }

    /// Tracked time per project for the day, busiest first. Durations add
    /// up like `DayActivityOverview.perApp`, so the two totals agree.
    func split(of blocks: [ActivityBlock]) -> DaySplit {
        let counted = blocks.filter { !TimelineWorkSession.isSystemOnly(app: $0.app) }
        let sharesByBlock = shares(for: counted)
        var seconds: [String: TimeInterval] = [:]
        var unattributed: TimeInterval = 0
        for (block, shares) in zip(counted, sharesByBlock) {
            var attributed: TimeInterval = 0
            for share in shares {
                seconds[share.project, default: 0] += share.seconds
                attributed += share.seconds
            }
            unattributed += max(0, block.duration - attributed)
        }
        var shares: [Share] = []
        for (project, total) in seconds where total > 0 {
            shares.append(Share(project: project, seconds: total))
        }
        return DaySplit(projects: Self.ranked(shares), unattributedSeconds: unattributed)
    }

    private func shares(for block: ActivityBlock, namedProject: String?) -> [Share] {
        let duration = block.end.timeIntervalSince(block.start)
        guard duration > 0, !projects.isEmpty else { return [] }
        if let namedProject { return [Share(project: namedProject, seconds: duration)] }
        return agentShares(for: block, duration: duration)
    }

    /// The busiest project whose name or repository the window title names.
    private func namedProject(title: String, app: String) -> String? {
        guard !projects.isEmpty, let cleaned = TimelineWorkSession.cleanedTitle(title, app: app) else { return nil }
        // Folding the title once is far cheaper than a folded search per name.
        let words = ProjectLinks.words(cleaned)
        return projects.first { ProjectLinks.matches($0.termSets, words: words) }?.name
    }

    private func agentShares(for block: ActivityBlock, duration: TimeInterval) -> [Share] {
        let runsClaudeCode = Self.hosts(app: block.app, agent: .claudeCode)
        let runsCodex = Self.hosts(app: block.app, agent: .codex)
        guard runsClaudeCode || runsCodex else { return [] }
        let window = DateInterval(start: block.start.addingTimeInterval(-Self.edgeMargin),
                                  end: block.end.addingTimeInterval(Self.edgeMargin))
        var weights: [String: TimeInterval] = [:]
        var covered: [DateInterval] = []
        for (burst, project) in zip(bursts, burstProjects) {
            // Bursts are in start order, so none after this one can overlap.
            if burst.start.addingTimeInterval(-Self.edgeMargin) >= window.end { break }
            let runsAgent = burst.agent == .claudeCode ? runsClaudeCode : runsCodex
            guard let project, runsAgent else { continue }
            let start = max(burst.start.addingTimeInterval(-Self.edgeMargin), window.start)
            let end = min(burst.end.addingTimeInterval(Self.edgeMargin), window.end)
            guard end > start else { continue }
            weights[project, default: 0] += end.timeIntervalSince(start)
            // The covered part is measured inside the block itself.
            let coveredStart = max(start, block.start), coveredEnd = min(end, block.end)
            if coveredEnd > coveredStart {
                covered.append(DateInterval(start: coveredStart, end: coveredEnd))
            }
        }
        let totalWeight = weights.values.reduce(0, +)
        let coveredSeconds = min(duration, Self.mergedDuration(covered))
        guard totalWeight > 0, coveredSeconds > 0 else { return [] }
        var shares: [Share] = []
        for (project, weight) in weights {
            let seconds: TimeInterval = coveredSeconds * weight / totalWeight
            shares.append(Share(project: project, seconds: seconds))
        }
        return Self.ranked(shares)
    }

    /// Busiest first; equal times by name, so the order never flickers.
    static func ranked(_ shares: [Share]) -> [Share] {
        shares.sorted(by: isRankedBefore)
    }

    private static func isRankedBefore(_ left: Share, _ right: Share) -> Bool {
        if left.seconds == right.seconds { return left.project < right.project }
        return left.seconds > right.seconds
    }

    private static func mergedDuration(_ intervals: [DateInterval]) -> TimeInterval {
        let ordered = intervals.sorted { $0.start < $1.start }
        guard var current = ordered.first else { return 0 }
        var total: TimeInterval = 0
        for interval in ordered.dropFirst() {
            if interval.start <= current.end {
                current = DateInterval(start: current.start, end: max(current.end, interval.end))
            } else {
                total += current.duration
                current = interval
            }
        }
        return total + current.duration
    }

    // MARK: - Where agents run

    /// The app can be where the person drives this agent: its own app, a
    /// terminal, or an editor. A chat app with no coding agent never counts,
    /// so time spent elsewhere while agents work stays unattributed.
    static func hosts(app: String, agent: CodingAgentKind) -> Bool {
        let name = app.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if sharedHosts.contains(name) || sharedHostPrefixes.contains(where: { name.hasPrefix($0) }) { return true }
        switch agent {
        case .claudeCode: return name == "claude"
        case .codex: return name == "codex" || name == "chatgpt"
        }
    }

    private static let sharedHosts: Set<String> = [
        "terminal", "iterm", "iterm2", "ghostty", "warp", "wezterm", "kitty", "alacritty",
        "hyper", "tabby", "xcode", "code", "visual studio code", "cursor", "windsurf", "zed",
        "conductor", "herdr", "opencodex",
    ]

    /// Apps whose name carries a channel, such as "T3 Code (Nightly)".
    private static let sharedHostPrefixes = ["t3 code", "zed "]
}

/// What a session's agent bursts recorded doing.
struct TimelineAgentOutcomes: Equatable, Sendable {
    var openedPullRequests: [String] = []
    var mergedPullRequests = 0
    var commits = 0

    init(_ bursts: [CodingAgentBurst]) {
        for burst in bursts {
            for action in burst.actions {
                switch action {
                case .openedPullRequest(let title): openedPullRequests.append(title)
                case .mergedPullRequest: mergedPullRequests += 1
                case .commit: commits += 1
                case .release, .pushed, .ranTests: continue
                }
            }
        }
    }

    var isEmpty: Bool { openedPullRequests.isEmpty && mergedPullRequests == 0 && commits == 0 }
}

/// One agent session's work inside a work session. An agent session that
/// pauses and resumes leaves several bursts; they read as one task.
struct TimelineAgentTask: Identifiable {
    let bursts: [CodingAgentBurst]
    var id: String { bursts[0].id }

    /// Bursts grouped by agent session, in the order each session first ran.
    static func tasks(from bursts: [CodingAgentBurst]) -> [TimelineAgentTask] {
        var order: [String] = []
        var grouped: [String: [CodingAgentBurst]] = [:]
        for burst in bursts {
            let key = "\(burst.agent.rawValue):\(burst.sessionID)"
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(burst)
        }
        return order.compactMap { key in grouped[key].map(TimelineAgentTask.init(bursts:)) }
    }

    /// The latest name: a session can be renamed as the work takes shape.
    var title: String { bursts[bursts.count - 1].workTitle }
    var project: String? { bursts.lazy.compactMap(\.workProject).first }
    var agent: CodingAgentKind { bursts[0].agent }
    var start: Date { bursts[0].start }
    var end: Date { bursts.map(\.end).max() ?? bursts[0].end }
    var request: String? { bursts.lazy.compactMap(\.prompts.first).first }
    var actions: [CodingAgentAction] { bursts.flatMap(\.actions) }
    var pullRequests: [String] { bursts.flatMap(\.pullRequests) }
}
