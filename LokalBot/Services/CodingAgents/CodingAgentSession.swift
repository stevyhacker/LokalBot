import Foundation

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

enum CodingAgentAction: Hashable, Codable, Sendable {
    case commit(message: String)
    case openedPullRequest(title: String)
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

protocol CodingAgentTimedEvent {
    var at: Date { get }
    var kind: CodingAgentEvent.Kind { get }
}

extension CodingAgentTimedEvent {
    var isAnnotation: Bool {
        if case .pullRequest = kind { return true }
        return false
    }
}

struct CodingAgentEvent: CodingAgentTimedEvent, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case prompt(String)
        case reply(String)
        case toolCall
        case fileChange(String)
        case action(CodingAgentAction)
        case pullRequest(String)
        case activity
    }

    var at: Date
    var kind: Kind
    var recordKey: Int?
    var workingDirectory: String?
    var branch: String?
}

struct CodingAgentTranscript: Equatable, Sendable {
    var agent: CodingAgentKind
    var sessionID: String
    var title: String?
    var workingDirectory: String?
    var branch: String?
    var consultedLokalBot = false
    var events: [CodingAgentEvent]
}

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

    var id: String { "\(agent.rawValue):\(sessionID):\(Int(start.timeIntervalSince1970))" }

    func isSettled(at now: Date) -> Bool {
        now.timeIntervalSince(end) >= CodingAgentBurstBuilder.inactivityGap
    }

    var isScheduledRun: Bool {
        !prompts.isEmpty && prompts.allSatisfy {
            $0.hasPrefix("Scheduled automation:") || $0.hasPrefix("Scheduled task:")
        }
    }

    var recordedOutcome: Bool { !actions.isEmpty || !pullRequests.isEmpty }

    func hasSameWork(as other: CodingAgentBurst) -> Bool {
        agent == other.agent && sessionID == other.sessionID
            && prompts == other.prompts && promptCount == other.promptCount
            && finalReply == other.finalReply && actions == other.actions
            && pullRequests == other.pullRequests && toolCallCount == other.toolCallCount
    }

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

    func evidenceText(calendar: Calendar = .current, maxPrompts: Int = 4) -> String {
        var lines = [
            "WORK SOURCE: AGENT SESSION [agent:\(agent.rawValue):\(sessionID.prefix(8))]",
            "Agent: \(agent.displayName)",
        ]
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

extension CodingAgentBurst {
    var titleNamesWork: Bool {
        guard title != CodingAgentBurstBuilder.untitled else { return false }
        if let first = prompts.first, title == CodingAgentBurstBuilder.requestTitle(first) { return false }
        return !CodingAgentText.readsAsRequest(title)
    }

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

    private static func workSubject(_ message: String) -> String? {
        var subject = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if let type = subject.range(of: #"^[a-z]+(\([^)]*\))?!?:\s+"#, options: .regularExpression) {
            subject.removeSubrange(type)
        }
        while subject.hasSuffix(".") { subject.removeLast() }
        guard let first = subject.first else { return nil }
        return first.uppercased() + subject.dropFirst()
    }

    private static func isProvisionalCommit(_ message: String) -> Bool {
        message.range(
            of: #"^\s*((temporary|temp|tmp|wip|merge|revert)\b|(fixup|squash|amend)!)"#,
            options: [.regularExpression, .caseInsensitive]) != nil
    }
}

enum CodingAgentBurstBuilder {
    static let inactivityGap: TimeInterval = 10 * 60
    static let activeGapCap: TimeInterval = 5 * 60
    static let storedPrompts = 6
    static let storedFiles = 16
    static let untitled = "Untitled session"

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

    static func compactingActivity<Event: CodingAgentTimedEvent>(
        _ events: [Event], calendar: Calendar = .current
    ) -> [Event] {
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
