import Foundation

/// A coding agent whose local session transcripts LokalBot can read as
/// work evidence. Transcripts are the agent's own files; LokalBot reads an
/// explicit allowlist of transcript paths and never the agent's credentials.
enum CodingAgentKind: String, CaseIterable, Codable, Sendable {
    case claudeCode = "claude-code"
    case codex

    var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        }
    }
}

/// An outcome parsed from a command the agent ran. These are recorded
/// actions, unlike the agent's own report, which is only a claim.
enum CodingAgentAction: Hashable, Codable, Sendable {
    case commit(message: String)
    case openedPullRequest(title: String)
    /// `nil` when the command merged the current branch's PR.
    case mergedPullRequest(number: Int?)
    case release(tag: String)
    case pushed
    case ranTests

    var summary: String {
        switch self {
        case .commit(let message): "commit: \(message)"
        case .openedPullRequest(let title): "opened PR: \(title)"
        case .mergedPullRequest(let number): number.map { "merged PR #\($0)" } ?? "merged PR"
        case .release(let tag): "release: \(tag)"
        case .pushed: "pushed"
        case .ranTests: "ran tests"
        }
    }
}

/// One timestamped fact from a transcript. Tool output, file contents,
/// reasoning, and injected system or developer text never become events.
struct CodingAgentEvent: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case prompt(String)
        case reply(String)
        case toolCall
        case fileChange(String)
        case action(CodingAgentAction)
        /// A PR the agent associated with the session. Claude Code re-emits
        /// these links every turn, so they annotate work but never start,
        /// extend, or keep alive a burst on their own.
        case pullRequest(String)
        /// Timestamp-only evidence that the agent was working, such as a
        /// tool result whose content is deliberately not read.
        case activity
    }

    var at: Date
    var kind: Kind
    /// The source record's hashed id, for dropping copies a fork or resumed
    /// session carries. Hashes are per process and never persisted.
    var recordKey: Int?
    /// The folder and branch the source record names, for readers whose
    /// records carry them. A burst is labeled from its own records, so a
    /// session that moves on never relabels work that already settled.
    var workingDirectory: String?
    var branch: String?

    var isAnnotation: Bool {
        if case .pullRequest = kind { return true }
        return false
    }
}

/// One parsed session, with events already clipped to the requested day.
struct CodingAgentTranscript: Equatable, Sendable {
    var agent: CodingAgentKind
    var sessionID: String
    var title: String?
    /// Session-wide labels, for bursts whose events carry none.
    var workingDirectory: String?
    var branch: String?
    /// The session read LokalBot's own library through its CLI or MCP.
    /// Its replies may restate library content, so they are withheld to
    /// keep the digest from consuming its own output.
    var consultedLokalBot = false
    var events: [CodingAgentEvent]
}

/// A contiguous run of agent work inside one session. A new burst starts
/// after the same idle gap the day digest uses to split segments, so a
/// session left open all day never merges the whole day into one item.
struct CodingAgentBurst: Equatable, Codable, Sendable {
    var agent: CodingAgentKind
    var sessionID: String
    var title: String
    var project: String
    var branch: String?
    var start: Date
    var end: Date
    var activeDuration: TimeInterval
    var prompts: [String]
    var promptCount: Int
    var finalReply: String?
    var changedFiles: [String]
    var changedFileCount: Int
    var actions: [CodingAgentAction]
    var pullRequests: [String]
    var toolCallCount: Int

    /// Stable within a day: bursts are keyed by session and first event.
    var id: String { "\(agent.rawValue):\(sessionID):\(Int(start.timeIntervalSince1970))" }

    /// A burst idle for the full inactivity gap can never grow again: any
    /// later event starts a new burst. Only settled bursts become evidence,
    /// so a saved digest's inputs cannot change underneath it.
    func isSettled(at now: Date) -> Bool {
        now.timeIntervalSince(end) >= CodingAgentBurstBuilder.inactivityGap
    }

    /// Every request came from a schedule, not from the person at the time.
    /// Such runs often report on earlier days.
    var isScheduledRun: Bool {
        !prompts.isEmpty && prompts.allSatisfy {
            $0.hasPrefix("Scheduled automation:") || $0.hasPrefix("Scheduled task:")
        }
    }

    /// The burst committed, opened or merged a pull request, released,
    /// pushed, ran tests, or linked a pull request.
    var recordedOutcome: Bool { !actions.isEmpty || !pullRequests.isEmpty }

    /// The same requests, reply, actions, pull requests, and tool calls in
    /// the same session. A settled burst's work never changes, but how it is
    /// presented can: a session is renamed, and bursts saved by earlier
    /// readers carry the session's folder and branch, file names relative to
    /// another folder, and edges moved by activity on the other side of
    /// midnight.
    func hasSameWork(as other: CodingAgentBurst) -> Bool {
        agent == other.agent && sessionID == other.sessionID
            && prompts == other.prompts && promptCount == other.promptCount
            && finalReply == other.finalReply && actions == other.actions
            && pullRequests == other.pullRequests && toolCallCount == other.toolCallCount
    }

    /// Every field the digest can read, in a fixed order, for evidence
    /// signatures that change exactly when the burst's content does.
    var signatureFields: [String] {
        [
            id, agent.rawValue, sessionID, title, project, branch ?? "",
            String(start.timeIntervalSince1970), String(end.timeIntervalSince1970),
            String(activeDuration), prompts.joined(separator: "\u{1e}"), String(promptCount),
            finalReply ?? "", changedFiles.joined(separator: "\u{1e}"), String(changedFileCount),
            actions.map(\.summary).joined(separator: "\u{1e}"),
            pullRequests.joined(separator: "\u{1e}"), String(toolCallCount),
        ]
    }

    /// Model-facing evidence in the same shape as the digest's other work
    /// sources: substantive content first, trace metadata last and labeled.
    func evidenceText(calendar: Calendar = .current, maxPrompts: Int = 4) -> String {
        var lines = [
            "WORK SOURCE: AGENT SESSION [agent:\(agent.rawValue):\(sessionID.prefix(8))]",
            "Agent: \(agent.displayName)",
        ]
        // A request or placeholder title names no work; the requests below
        // already say what was asked.
        if titleNamesWork { lines.append("Session: \(title)") }
        lines.append("Project: \(workProject ?? "unknown")" + (branch.map { " (branch \($0))" } ?? ""))
        if isScheduledRun {
            lines.append(
                "Scheduled run: its report is omitted because it may describe other days; "
                    + "only recorded actions show what happened in this session.")
        }
        if prompts.isEmpty {
            lines.append("Requests: continued work from an earlier request")
        } else {
            lines.append("Requests:")
            lines += prompts.prefix(maxPrompts).map { "- \($0)" }
            let remaining = promptCount - min(maxPrompts, prompts.count)
            if remaining > 0 { lines.append("- (+\(remaining) more)") }
        }
        if !changedFiles.isEmpty {
            let hidden = changedFileCount - changedFiles.count
            lines.append(
                "Changed files (\(changedFileCount)): " + changedFiles.joined(separator: ", ")
                    + (hidden > 0 ? ", +\(hidden) more" : ""))
        }
        if !actions.isEmpty {
            lines.append("Recorded actions: " + actions.map(\.summary).joined(separator: "; "))
        }
        if !pullRequests.isEmpty {
            lines.append("Pull requests: " + pullRequests.joined(separator: ", "))
        }
        if let finalReply, !isScheduledRun {
            lines.append("Agent's final report (a claim; corroborate with actions): \(finalReply)")
        }
        lines.append(
            "LOW-PRIORITY TRACE METADATA — do not summarize directly:\n"
                + "\(Self.time(start, calendar))–\(Self.time(end, calendar)); "
                + "active=\(Int((activeDuration / 60).rounded()))m; tool_calls=\(toolCallCount)")
        return lines.joined(separator: "\n")
    }

    private static func time(_ date: Date, _ calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }
}

/// A GitHub-style pull request a session linked.
struct CodingAgentPullRequest: Hashable, Sendable {
    var owner: String
    var repository: String
    var number: Int

    init?(url: String) {
        let parts = url.split(separator: "/")
        guard parts.count >= 6, parts[parts.count - 2] == "pull",
              let number = Int(parts[parts.count - 1]) else { return nil }
        owner = String(parts[parts.count - 4])
        repository = String(parts[parts.count - 3])
        self.number = number
    }
}

// MARK: - Naming the work

extension CodingAgentBurst {
    /// The title came from the transcript and names the work. A session the
    /// transcript leaves untitled is labeled with its first request or a
    /// placeholder, which name a conversation instead.
    var titleNamesWork: Bool {
        guard title != CodingAgentBurstBuilder.untitled else { return false }
        if let first = prompts.first, title == CodingAgentBurstBuilder.requestTitle(first) { return false }
        return !CodingAgentText.readsAsRequest(title)
    }

    /// A short work title for a task list: the session's own title when it
    /// names the work, otherwise the deliverable its recorded actions name
    /// (an opened pull request, then a commit), then its request when that is
    /// a short instruction. "can you add a demo to the PR?" and "Untitled
    /// session" never become a task.
    var workTitle: String {
        if titleNamesWork { return title }
        var opened: String?
        var commits: [String] = []
        var provisional: [String] = []
        for action in actions {
            switch action {
            case .openedPullRequest(let title):
                if opened == nil { opened = Self.workSubject(title) }
            case .commit(let message):
                guard let subject = Self.workSubject(message) else { continue }
                if Self.isProvisionalCommit(message) {
                    provisional.append(subject)
                } else {
                    commits.append(subject)
                }
            default:
                continue
            }
        }
        if let opened { return opened }
        if let commit = commits.first { return commit }
        let requests = (title == CodingAgentBurstBuilder.untitled ? [] : [title]) + prompts.prefix(1)
        if let instruction = requests.lazy.compactMap(CodingAgentText.instruction).first {
            return instruction
        }
        if let commit = provisional.first { return commit }
        if let pullRequest = pullRequestReferences.first { return "Work on PR #\(pullRequest.number)" }
        return "\(agent.displayName) session"
    }

    /// The repository the work belongs to. A session started in a folder that
    /// names no project, such as a scratch folder or the folder holding every
    /// checkout, takes it from its pull requests, as does a sibling checkout
    /// such as `LokalBot-port`. `nil` when nothing names one.
    var workProject: String? {
        var repositories: [String] = []
        for pullRequest in pullRequestReferences
        where !repositories.contains(where: { $0.caseInsensitiveCompare(pullRequest.repository) == .orderedSame }) {
            repositories.append(pullRequest.repository)
        }
        let repository = repositories.count == 1 ? repositories.first : nil
        if CodingAgentBurstBuilder.namesNoProject(project) { return repository }
        if let repository, project.count > repository.count,
           project.lowercased().hasPrefix(repository.lowercased()),
           let separator = project.dropFirst(repository.count).first, "-_. ".contains(separator) {
            return repository
        }
        return project
    }

    var pullRequestReferences: [CodingAgentPullRequest] {
        pullRequests.compactMap(CodingAgentPullRequest.init(url:))
    }

    /// A commit or pull request title as a work title, without a
    /// conventional-commit type such as `feat(onchain):`.
    private static func workSubject(_ message: String) -> String? {
        var subject = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if let type = subject.range(of: #"^[a-z]+(\([^)]*\))?!?:\s+"#, options: .regularExpression) {
            subject.removeSubrange(type)
        }
        while subject.hasSuffix(".") { subject.removeLast() }
        guard let first = subject.first else { return nil }
        return first.uppercased() + subject.dropFirst()
    }

    /// Scaffolding that names a step rather than the work: temporary and
    /// work-in-progress commits, fixups, merges, and reverts.
    private static func isProvisionalCommit(_ message: String) -> Bool {
        message.range(
            of: #"^\s*((temporary|temp|tmp|wip|merge|revert)\b|(fixup|squash|amend)!)"#,
            options: [.regularExpression, .caseInsensitive]) != nil
    }
}

enum CodingAgentBurstBuilder {
    /// Matches `DayDigestEvidence.summarySegments(inactivityGap:)`.
    static let inactivityGap: TimeInterval = 10 * 60
    /// Longer gaps between events count as waiting, not active work.
    static let activeGapCap: TimeInterval = 5 * 60
    static let storedPrompts = 6
    static let storedFiles = 16
    /// The title of a session with neither a title nor a request.
    static let untitled = "Untitled session"

    /// The title of a session its transcript leaves untitled: its first request.
    static func requestTitle(_ prompt: String) -> String {
        CodingAgentText.truncated(prompt, maxCharacters: 80)
    }

    static func bursts(
        from transcript: CodingAgentTranscript,
        inactivityGap: TimeInterval = inactivityGap
    ) -> [CodingAgentBurst] {
        let ordered = transcript.events.enumerated().sorted { lhs, rhs in
            lhs.element.at == rhs.element.at ? lhs.offset < rhs.offset : lhs.element.at < rhs.element.at
        }.map(\.element)
        var groups: [[CodingAgentEvent]] = []
        for event in ordered where !event.isAnnotation {
            if let last = groups.last?.last, event.at.timeIntervalSince(last.at) <= inactivityGap {
                groups[groups.count - 1].append(event)
            } else {
                groups.append([event])
            }
        }
        // Annotations join the burst that was active when they were written;
        // a link re-emitted while nothing else happened is dropped.
        for annotation in ordered where annotation.isAnnotation {
            guard let index = groups.lastIndex(where: { group in
                guard let first = group.first, let last = group.last else { return false }
                return annotation.at >= first.at
                    && annotation.at.timeIntervalSince(last.at) <= inactivityGap
            }) else { continue }
            groups[index].append(annotation)
        }

        let title = transcript.title.flatMap(Self.nonEmpty)
            ?? firstPrompt(in: ordered).map(requestTitle)
            ?? untitled
        return groups.compactMap { group in
            burst(group, transcript: transcript, title: title)
        }
    }

    private static func burst(
        _ events: [CodingAgentEvent],
        transcript: CodingAgentTranscript,
        title: String
    ) -> CodingAgentBurst? {
        var prompts: [String] = [], promptCount = 0
        var reply: String?
        var files: [String] = [], seenFiles: Set<String> = []
        var actions: [CodingAgentAction] = []
        var pullRequests: [String] = []
        var toolCalls = 0
        for event in events {
            switch event.kind {
            case .prompt(let text):
                promptCount += 1
                if prompts.count < storedPrompts { prompts.append(text) }
            case .reply(let text):
                reply = text
            case .toolCall:
                toolCalls += 1
            case .fileChange(let path):
                if seenFiles.insert(path).inserted { files.append(path) }
            case .action(let action):
                if !actions.contains(action) { actions.append(action) }
            case .pullRequest(let url):
                if !pullRequests.contains(url) { pullRequests.append(url) }
            case .activity:
                break
            }
        }
        if transcript.consultedLokalBot { reply = nil }
        guard promptCount > 0 || reply != nil || !files.isEmpty || !actions.isEmpty else {
            return nil
        }
        let times = events.filter { !$0.isAnnotation }.map(\.at)
        guard let start = times.first, let end = times.last else { return nil }
        let active = zip(times, times.dropFirst()).reduce(0) { total, pair in
            total + min(pair.1.timeIntervalSince(pair.0), activeGapCap)
        }
        // A scan reads a window of days, and a long session changes branch
        // and folder within it. Labels from the session as a whole would
        // relabel this burst on every such change and as the window slides.
        let workingDirectory = events.lazy.compactMap(\.workingDirectory).first
            ?? transcript.workingDirectory
        let branch = events.reversed().lazy.compactMap(\.branch).first ?? transcript.branch
        return CodingAgentBurst(
            agent: transcript.agent,
            sessionID: transcript.sessionID,
            title: title,
            project: projectName(for: workingDirectory),
            branch: branch,
            start: start,
            end: end,
            activeDuration: active,
            prompts: prompts,
            promptCount: promptCount,
            finalReply: reply,
            changedFiles: Array(files.prefix(storedFiles)),
            changedFileCount: files.count,
            actions: actions,
            pullRequests: pullRequests,
            toolCallCount: toolCalls)
    }

    /// One session's bursts as a single view, for a summary that should see
    /// the session once rather than once per burst. `nil` for no bursts.
    static func merging(_ bursts: [CodingAgentBurst]) -> CodingAgentBurst? {
        let ordered = bursts.sorted { $0.start < $1.start }
        guard var merged = ordered.first else { return nil }
        var files = merged.changedFiles
        var hiddenFiles = max(0, merged.changedFileCount - merged.changedFiles.count)
        for burst in ordered.dropFirst() {
            merged.end = max(merged.end, burst.end)
            merged.activeDuration += burst.activeDuration
            merged.prompts += burst.prompts
            merged.promptCount += burst.promptCount
            merged.finalReply = burst.finalReply ?? merged.finalReply
            merged.branch = burst.branch ?? merged.branch
            for file in burst.changedFiles where !files.contains(file) { files.append(file) }
            hiddenFiles += max(0, burst.changedFileCount - burst.changedFiles.count)
            for action in burst.actions where !merged.actions.contains(action) { merged.actions.append(action) }
            for url in burst.pullRequests where !merged.pullRequests.contains(url) {
                merged.pullRequests.append(url)
            }
            merged.toolCallCount += burst.toolCallCount
        }
        merged.changedFiles = Array(files.prefix(storedFiles))
        merged.changedFileCount = files.count + hiddenFiles
        return merged
    }

    /// Drops timestamp-only events that change neither a burst boundary nor
    /// its active time. A ping is redundant when the events either side of it
    /// are within `activeGapCap` of each other: the gaps it splits count in
    /// full either way. Busy sessions log thousands of tool results, so this
    /// keeps cached transcripts small without changing any burst.
    ///
    /// Bursts are cut at midnight, so a ping is kept when its neighbors fall
    /// on different days: otherwise the next day's first event, or the
    /// scan window's start, would move the edge of a burst already saved.
    static func compactingActivity(
        _ events: [CodingAgentEvent], calendar: Calendar = .current
    ) -> [CodingAgentEvent] {
        let annotations = events.filter(\.isAnnotation)
        let ordered = events.enumerated()
            .filter { !$0.element.isAnnotation }
            .sorted { lhs, rhs in
                lhs.element.at == rhs.element.at ? lhs.offset < rhs.offset : lhs.element.at < rhs.element.at
            }
            .map(\.element)
        guard ordered.count > 2 else { return ordered + annotations }
        var kept = [ordered[0]]
        for index in 1..<(ordered.count - 1) {
            let event = ordered[index]
            if case .activity = event.kind, let previous = kept.last,
               ordered[index + 1].at.timeIntervalSince(previous.at) <= activeGapCap,
               calendar.isDate(previous.at, inSameDayAs: ordered[index + 1].at) {
                continue
            }
            kept.append(event)
        }
        kept.append(ordered[ordered.count - 1])
        return kept + annotations
    }

    /// The repository name, not the checkout folder: agent worktrees live
    /// under `<repo>/.claude/worktrees/<name>`.
    static func projectName(for workingDirectory: String?) -> String {
        guard let workingDirectory, !workingDirectory.isEmpty else { return unknownProject }
        let components = URL(fileURLWithPath: workingDirectory).standardizedFileURL.pathComponents
        if let marker = components.lastIndex(of: ".claude"), marker > 1,
           components.indices.contains(marker + 1), components[marker + 1] == "worktrees" {
            return components[marker - 1]
        }
        return components.last.flatMap(nonEmpty) ?? unknownProject
    }

    static let unknownProject = "Unknown project"

    /// A folder that holds work without naming it: no folder at all, a Claude
    /// scratch folder such as `scratch-2026-10-19-6f7eb7`, or a folder that
    /// holds checkouts, such as `~/Documents/GitHub` or the home folder.
    static func namesNoProject(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return name == unknownProject
            || checkoutFolders.contains(lowered)
            || lowered == NSUserName().lowercased()
            || lowered.range(of: #"^scratch(-[0-9a-f-]+)?$"#, options: .regularExpression) != nil
    }

    private static let checkoutFolders: Set<String> = [
        "code", "desktop", "dev", "developer", "documents", "downloads", "git", "github",
        "projects", "repos", "repositories", "scratchpad", "src", "tmp", "workspace", "workspaces",
    ]

    private static func firstPrompt(in events: [CodingAgentEvent]) -> String? {
        for event in events {
            if case .prompt(let text) = event.kind { return text }
        }
        return nil
    }

    private static func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
