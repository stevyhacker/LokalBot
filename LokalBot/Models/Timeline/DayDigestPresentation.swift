import Foundation

/// A display-oriented projection of the Markdown journal. The journal remains
/// the lossless export format; this model only gives the app a scannable,
/// backwards-compatible hierarchy for both old and newly generated digests.
struct DayDigestPresentation: Equatable {
    struct FocusBlock: Equatable, Identifiable {
        enum Status: Equatable {
            case completed
            case inProgress
            case blocked
        }

        let id: Int
        let timeRange: String?
        let title: String?
        /// Parsed from the journal's "Completed." style lead, which the
        /// summary no longer repeats.
        let status: Status?
        let summaryMarkdown: String
        let sourceIDs: [Int64]
        /// The journal's "Next — task: step" follow-up, shown with its task
        /// instead of repeating the task title in a separate list.
        var nextStep: String?
    }

    /// Tasks ordered for scanning: open work first, finished work last.
    struct TaskGroup: Equatable, Identifiable {
        /// The view names each kind through the interface catalog.
        enum Kind: CaseIterable {
            case blocked
            case inProgress
            case other
            case completed
        }

        let kind: Kind
        let blocks: [FocusBlock]

        var id: Kind { kind }
    }

    struct ActivityEntry: Equatable, Identifiable {
        let id: Int
        let headlineMarkdown: String
        let evidenceMarkdown: [String]
    }

    struct ActivityHourGroup: Equatable, Identifiable {
        let id: String
        let hour: String
        let entries: [ActivityEntry]

        var label: String {
            guard let value = Int(hour) else { return hour }
            return String(format: "%02d:00–%02d:59", value, value)
        }
    }

    struct TimeAllocation: Equatable, Identifiable {
        let id: Int
        let app: String
        let detail: String
        let seconds: TimeInterval
    }

    let atAGlanceMarkdown: String
    let focusBlocks: [FocusBlock]
    let otherActivityBlocks: [FocusBlock]
    let decisions: [String]
    let blockers: [String]
    /// Follow-ups that are neither a decision, a blocker, nor the next step
    /// of a listed task, such as older journals' free-form items. Shown as
    /// rows like tasks; their ids continue after the tasks' ids.
    let followUps: [FocusBlock]
    let meetingsMarkdown: String?
    let agentSessionsMarkdown: String?
    let timeAllocations: [TimeAllocation]
    let activityGroups: [ActivityHourGroup]

    /// Whether a task row shows only its title and next step, with the
    /// summary opening on demand. Task-first journals give tasks a status,
    /// and there every titled task collapses, including the ones whose status
    /// the generator left unknown. Older journals never carry a status; their
    /// summary is the only description, so it stays visible.
    func collapsesDetails(of block: FocusBlock) -> Bool {
        block.title != nil
            && (!block.summaryMarkdown.isEmpty || !block.sourceIDs.isEmpty)
            && focusBlocks.contains { $0.status != nil }
    }

    var taskGroups: [TaskGroup] {
        TaskGroup.Kind.allCases.compactMap { kind in
            let blocks = focusBlocks.filter { Self.groupKind(of: $0) == kind }
            return blocks.isEmpty ? nil : TaskGroup(kind: kind, blocks: blocks)
        }
    }

    /// Task-first journals give their tasks a status; older journals never do.
    var isTaskFirst: Bool {
        focusBlocks.contains { $0.status != nil }
    }

    /// Timeline shows a group's tasks that carry a next step, and every
    /// blocked task, in full; the rest of the group become one-line rows.
    /// Older journals have neither statuses nor next steps, and their summary
    /// is the only description, so all of their tasks stay in full.
    func timelineRows(of group: TaskGroup) -> (full: [FocusBlock], brief: [FocusBlock]) {
        guard isTaskFirst, group.kind != .blocked else { return (group.blocks, []) }
        if group.kind == .completed { return ([], group.blocks) }
        return (group.blocks.filter { $0.nextStep != nil },
                group.blocks.filter { $0.nextStep == nil })
    }

    /// Splits a trailing parenthetical off a task title, such as the project
    /// in "Review all open PRs (LokalBot)" or the pull request in
    /// "Staging deployment (PR #487)", so the view can show it as a tag.
    static func titleAndTag(_ title: String) -> (title: String, tag: String?) {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix(")") else { return (trimmed, nil) }
        var depth = 0
        var open: String.Index?
        for index in trimmed.indices.reversed() {
            if trimmed[index] == ")" { depth += 1 }
            if trimmed[index] == "(" {
                depth -= 1
                if depth == 0 { open = index; break }
            }
        }
        guard let open else { return (trimmed, nil) }
        let tag = trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)]
            .trimmingCharacters(in: .whitespaces)
        let head = trimmed[..<open].trimmingCharacters(in: .whitespaces)
        guard !head.isEmpty, !tag.isEmpty, tag.count <= 32 else { return (trimmed, nil) }
        return (head, tag)
    }

    var activityCount: Int {
        activityGroups.reduce(0) { $0 + $1.entries.count }
    }

    var evidenceCount: Int {
        activityGroups.reduce(0) { total, group in
            total + group.entries.reduce(0) { $0 + $1.evidenceMarkdown.count }
        }
    }

    init(markdown: String) {
        let document = Self.levelTwoSections(in: markdown)
        let summarySection = document.first(where: {
            Self.normalized($0.title) == "day summary"
        })
        let summaryBody = summarySection?.body ?? ""
        let summaryParts = Self.levelThreeSections(in: summaryBody)
        let summaryPreamble = Self.preamble(in: summaryBody, before: "### ")

        let legacyWork = document.first(where: {
            ["what i worked on", "work completed and in progress"].contains(
                Self.normalized($0.title))
        })?.body

        let standaloneOverview = document.first(where: {
            ["today at a glance", "at a glance", "overview"].contains(
                Self.normalized($0.title))
        })?.body
        let standaloneFocus = document.first(where: {
            ["next", "tasks", "focus blocks"].contains(Self.normalized($0.title))
        })?.body

        let overview = Self.body(
            named: ["at a glance", "overview"], in: summaryParts)
            ?? standaloneOverview
        let focus = Self.body(
            named: ["tasks", "focus blocks", "work completed and in progress"],
            in: summaryParts) ?? legacyWork ?? standaloneFocus
        let otherActivity = Self.body(
            named: ["other activity", "brief activity"],
            in: summaryParts)
        let decisions = Self.body(
            named: ["decisions and next steps", "decisions, follow-ups, and blockers"],
            in: summaryParts)

        let unknownSummary = summaryParts.filter {
            let title = Self.normalized($0.title)
            return !["at a glance", "overview", "tasks", "focus blocks",
                     "work completed and in progress", "other activity",
                     "brief activity", "decisions and next steps",
                     "decisions, follow-ups, and blockers"].contains(title)
        }.map { "### \($0.title)\n\n\($0.body)" }

        let parsedFocusBlocks = Self.focusBlocks(from: focus ?? "")
        let parsedOtherActivityBlocks = Self.focusBlocks(from: otherActivity ?? "")
        let taskComparisons = parsedFocusBlocks.map(Self.comparisonText)
        let overviewMarkdown = Self.joinNonempty(
            [overview, summaryPreamble] + unknownSummary)
        let uniqueOverview = Self.removingSimilarContent(
            overviewMarkdown,
            excluding: taskComparisons) ?? ""
        let conciseOverviewMarkdown = Self.conciseOverview(uniqueOverview)

        let followUps = Self.followUps(
            decisions,
            tasks: parsedFocusBlocks,
            excluding: taskComparisons + [conciseOverviewMarkdown])

        atAGlanceMarkdown = conciseOverviewMarkdown
        focusBlocks = followUps.tasks
        otherActivityBlocks = parsedOtherActivityBlocks
        self.decisions = followUps.decisions
        blockers = followUps.blockers
        self.followUps = followUps.other

        let meetings = document.first(where: {
            Self.normalized($0.title) == "meetings"
        })?.body
        meetingsMarkdown = Self.meaningful(meetings)
        agentSessionsMarkdown = Self.meaningful(document.first(where: {
            Self.normalized($0.title) == "agent sessions"
        })?.body)

        let timeBody = document.first(where: {
            Self.normalized($0.title) == "time allocation"
        })?.body ?? ""
        timeAllocations = Self.timeAllocations(from: timeBody)

        let activityBody = document.first(where: {
            ["full activity log", "chronological work log"].contains(
                Self.normalized($0.title))
        })?.body ?? ""
        activityGroups = Self.activityGroups(from: activityBody)
    }

    private struct Section {
        var title: String
        var body: String
    }

    private static func levelTwoSections(in markdown: String) -> [Section] {
        sections(in: markdown, prefix: "## ")
    }

    private static func levelThreeSections(in markdown: String) -> [Section] {
        sections(in: markdown, prefix: "### ")
    }

    private static func sections(in markdown: String, prefix: String) -> [Section] {
        var result: [Section] = []
        var title: String?
        var lines: [String] = []

        func finish() {
            guard let title else { return }
            result.append(Section(
                title: title,
                body: lines.joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)))
        }

        for line in markdown.components(separatedBy: "\n") {
            if line.hasPrefix(prefix), !line.hasPrefix(prefix + "#") {
                finish()
                title = String(line.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                lines = []
            } else if title != nil {
                lines.append(line)
            }
        }
        finish()
        return result
    }

    private static func body(named names: [String], in sections: [Section]) -> String? {
        sections.first(where: { names.contains(normalized($0.title)) })?.body
    }

    private static func normalized(_ value: String) -> String {
        value
            .replacingOccurrences(of: "‑", with: "-")
            .replacingOccurrences(of: "–", with: "-")
            .replacingOccurrences(of: "—", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func preamble(in markdown: String, before prefix: String) -> String? {
        let lines = markdown.components(separatedBy: "\n")
        let preamble = lines.prefix { !$0.hasPrefix(prefix) }
            .joined(separator: "\n")
        return meaningful(preamble)
    }

    private static func meaningful(_ value: String?) -> String? {
        guard let value else { return nil }
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        let sentinel = clean
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "*", with: "")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines
                .union(CharacterSet(charactersIn: ".")))
            .lowercased()
        let emptyValues = [
            "none", "none recorded", "none found in the evidence",
            "no activity was recorded", "no tracked app time", "no meetings",
        ]
        return emptyValues.contains(sentinel) ? nil : clean
    }

    private static func joinNonempty(_ values: [String?]) -> String {
        values.compactMap(meaningful).joined(separator: "\n\n")
    }

    /// New journals give every fact one section. Older journals can contain
    /// the same task in overview, task, and follow-up sections, so suppress
    /// copied or lightly rephrased items at presentation time as well.
    private static func removingSimilarContent(
        _ value: String?,
        excluding existing: [String]
    ) -> String? {
        guard let clean = meaningful(value) else { return nil }
        let items = topLevelItems(in: clean)
        if items.isEmpty {
            return existing.contains(where: {
                DayDigestTextSimilarity.isSimilar(clean, $0)
            }) ? nil : clean
        }

        var comparisons = existing.filter { !$0.isEmpty }
        var accepted: [String] = []
        for item in items {
            let comparison = strippingListMarker(item)
            guard !comparisons.contains(where: {
                DayDigestTextSimilarity.isSimilar(comparison, $0)
            }) else { continue }
            accepted.append(item)
            comparisons.append(comparison)
        }
        return meaningful(accepted.joined(separator: "\n"))
    }

    private static func comparisonText(_ block: FocusBlock) -> String {
        [block.title, block.summaryMarkdown]
            .compactMap { $0 }
            .joined(separator: " ")
    }

    private static func groupKind(of block: FocusBlock) -> TaskGroup.Kind {
        switch block.status {
        case .blocked: .blocked
        case .inProgress: .inProgress
        case .completed: .completed
        case nil: .other
        }
    }

    /// Splits the journal's follow-up list into decisions, blockers, and the
    /// rest, and moves each "Next — task: step" onto the task it names. Items
    /// already said by a task, the overview, or an earlier item are dropped.
    private static func followUps(
        _ markdown: String?,
        tasks: [FocusBlock],
        excluding existing: [String]
    ) -> (tasks: [FocusBlock], decisions: [String], blockers: [String], other: [FocusBlock]) {
        var tasks = tasks
        var decisions: [String] = []
        var blockers: [String] = []
        var other: [FocusBlock] = []
        func appendOther(_ markdown: String, nextStep: String? = nil) {
            var block = focusBlock(id: tasks.count + other.count, markdown: markdown)
            block.nextStep = nextStep
            other.append(block)
        }
        guard let clean = meaningful(markdown) else { return (tasks, [], [], []) }

        var comparisons = existing.filter { !$0.isEmpty }
        func isNew(_ text: String) -> Bool {
            guard !comparisons.contains(where: {
                DayDigestTextSimilarity.isSimilar(text, $0)
            }) else { return false }
            comparisons.append(text)
            return true
        }

        let items = topLevelItems(in: clean)
        for item in items.isEmpty ? [clean] : items {
            let text = strippingListMarker(item)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let decision = removingLabel(["Decision", "Decisions"], from: text) {
                if isNew(decision) { decisions.append(directVoice(decision)) }
            } else if let blocker = removingLabel(["Blocker", "Blockers"], from: text) {
                if isNew(blocker) { blockers.append(directVoice(blocker)) }
            } else if let next = nextStep(in: text, tasks: tasks) {
                guard let index = next.taskIndex else {
                    if isNew(next.step) {
                        appendOther("**\(next.title)**", nextStep: directVoice(next.step))
                    }
                    continue
                }
                guard tasks[index].nextStep == nil,
                      !DayDigestTextSimilarity.isSimilar(next.step, comparisonText(tasks[index]))
                else { continue }
                tasks[index].nextStep = directVoice(next.step)
            } else if isNew(text) {
                appendOther(text)
            }
        }
        return (tasks, decisions, blockers, other)
    }

    /// `Decision: …` and `**Blocker:** …` leads, without the label.
    private static func removingLabel(_ labels: [String], from text: String) -> String? {
        let pattern = #"^\*{0,2}(?:"# + labels.joined(separator: "|") + #")\*{0,2}:\*{0,2}\s*"#
        guard let match = text.range(
            of: pattern, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let rest = String(text[match.upperBound...]).trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? nil : rest
    }

    /// `Next — <task title>: <step>`. Task titles can contain colons, so the
    /// longest shown title that prefixes the item wins; otherwise the first
    /// colon separates an unknown title from its step.
    private static func nextStep(
        in text: String,
        tasks: [FocusBlock]
    ) -> (taskIndex: Int?, title: String, step: String)? {
        guard let lead = text.range(
            of: #"^Next\s+[—–-]\s+"#, options: .regularExpression) else { return nil }
        let rest = String(text[lead.upperBound...])
        let candidates = [rest, directVoice(rest)]
        let match = tasks.indices
            .compactMap { index -> (Int, String)? in
                guard let title = tasks[index].title, !title.isEmpty else { return nil }
                let prefix = title + ":"
                guard let candidate = candidates.first(where: {
                    $0.lowercased().hasPrefix(prefix.lowercased())
                }) else { return nil }
                let step = String(candidate.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespaces)
                return step.isEmpty ? nil : (index, step)
            }
            .max { (tasks[$0.0].title?.count ?? 0) < (tasks[$1.0].title?.count ?? 0) }
        if let match {
            return (match.0, tasks[match.0].title ?? "", match.1)
        }
        guard let colon = rest.range(of: ": ") else { return nil }
        let title = String(rest[..<colon.lowerBound]).trimmingCharacters(in: .whitespaces)
        let step = String(rest[colon.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty, !step.isEmpty else { return nil }
        return (nil, title, step)
    }

    /// The journal can retain a longer overview for export, but the default UI
    /// should answer "what mattered?" in one glance. Paragraph-style legacy
    /// summaries are kept intact; generated bullet lists show at most three.
    private static func conciseOverview(_ markdown: String) -> String {
        let items = topLevelItems(in: markdown)
        guard !items.isEmpty else { return markdown }
        return items.prefix(3).joined(separator: "\n")
    }

    private static func focusBlocks(from markdown: String) -> [FocusBlock] {
        let clean = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return [] }
        let items = topLevelItems(in: clean)
        let blocks = items.isEmpty ? [clean] : items
        return blocks.enumerated().map { focusBlock(id: $0.offset, markdown: $0.element) }
    }

    /// Task-first journals store `**task** — summary`; previous journals used
    /// `**time · topic** — summary [screen:id]`. Split both shapes for the UI
    /// without exposing Markdown syntax or private evidence identifiers.
    private static func focusBlock(id: Int, markdown: String) -> FocusBlock {
        let raw = strippingListMarker(markdown)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceIDs = screenIDs(in: raw)
        let visible = raw.replacingOccurrences(
            of: #"\s*\[screen:\d+\]"#,
            with: "",
            options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard visible.hasPrefix("**") else {
            return FocusBlock(
                id: id,
                timeRange: nil,
                title: nil,
                status: nil,
                summaryMarkdown: directVoice(visible),
                sourceIDs: sourceIDs)
        }
        let headingStart = visible.index(visible.startIndex, offsetBy: 2)
        guard let headingEnd = visible.range(
            of: "**", range: headingStart..<visible.endIndex) else {
            return FocusBlock(
                id: id,
                timeRange: nil,
                title: nil,
                status: nil,
                summaryMarkdown: directVoice(visible),
                sourceIDs: sourceIDs)
        }

        let heading = String(visible[headingStart..<headingEnd.lowerBound])
        let remainder = String(visible[headingEnd.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let (status, summary) = statusLead(in: remainder.hasPrefix("—")
            ? String(remainder.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
            : remainder)
        if let separator = heading.range(of: " · ") {
            return FocusBlock(
                id: id,
                timeRange: String(heading[..<separator.lowerBound]),
                title: directVoice(String(heading[separator.upperBound...])),
                status: status,
                summaryMarkdown: directVoice(summary),
                sourceIDs: sourceIDs)
        }
        return FocusBlock(
            id: id,
            timeRange: nil,
            title: directVoice(heading),
            status: status,
            summaryMarkdown: directVoice(summary),
            sourceIDs: sourceIDs)
    }

    /// Task summaries open with the status the generator settled on.
    private static func statusLead(in summary: String) -> (FocusBlock.Status?, String) {
        let leads: [(String, FocusBlock.Status)] = [
            ("Completed.", .completed),
            ("In progress.", .inProgress),
            ("Blocked.", .blocked),
        ]
        for (lead, status) in leads where summary.hasPrefix(lead) {
            return (status, String(summary.dropFirst(lead.count))
                .trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return (nil, summary)
    }

    private static func screenIDs(in value: String) -> [Int64] {
        guard let expression = try? NSRegularExpression(pattern: #"\[screen:(\d+)\]"#) else {
            return []
        }
        let range = NSRange(value.startIndex..., in: value)
        var result: [Int64] = []
        for match in expression.matches(in: value, range: range) {
            guard let idRange = Range(match.range(at: 1), in: value),
                  let id = Int64(value[idRange]), !result.contains(id) else { continue }
            result.append(id)
        }
        return result
    }

    private static func directVoice(_ value: String) -> String {
        var clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstName = NSFullUserName().split(whereSeparator: \Character.isWhitespace)
            .first.map(String.init)
        let prefixes = ["The user ", "the user ", "User ", "user "]
            + (firstName.map { ["\($0) "] } ?? [])
        for prefix in prefixes where clean.hasPrefix(prefix) {
            clean.removeFirst(prefix.count)
            guard let first = clean.first else { return clean }
            clean.replaceSubrange(clean.startIndex...clean.startIndex,
                                  with: String(first).uppercased())
            break
        }
        return clean
    }

    private static func topLevelItems(in markdown: String) -> [String] {
        var items: [String] = []
        var current: [String] = []
        for line in markdown.components(separatedBy: "\n") {
            let isTopLevel = line.first?.isWhitespace == false
                && (line.hasPrefix("- ") || line.hasPrefix("* "))
            if isTopLevel, !current.isEmpty {
                items.append(current.joined(separator: "\n"))
                current = []
            }
            if isTopLevel || !current.isEmpty { current.append(line) }
        }
        if !current.isEmpty { items.append(current.joined(separator: "\n")) }
        return items
    }

    private static func activityGroups(from markdown: String) -> [ActivityHourGroup] {
        let rawItems = topLevelItems(in: markdown)
        var orderedHours: [String] = []
        var grouped: [String: [ActivityEntry]] = [:]

        for (index, item) in rawItems.enumerated() {
            let lines = item.components(separatedBy: "\n")
            guard let first = lines.first else { continue }
            let headline = strippingListMarker(first)
            let evidence = lines.dropFirst().compactMap { line -> String? in
                let clean = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !clean.isEmpty else { return nil }
                return strippingListMarker(clean)
            }
            let hour = activityHour(from: first) ?? "Other"
            if grouped[hour] == nil { orderedHours.append(hour) }
            grouped[hour, default: []].append(ActivityEntry(
                id: index,
                headlineMarkdown: headline,
                evidenceMarkdown: evidence))
        }

        return orderedHours.map { hour in
            ActivityHourGroup(id: hour, hour: hour, entries: grouped[hour] ?? [])
        }
    }

    private static func activityHour(from line: String) -> String? {
        guard let match = line.range(
            of: #"\*\*([0-2][0-9]):[0-5][0-9]"#,
            options: .regularExpression) else { return nil }
        let token = line[match]
        guard let colon = token.firstIndex(of: ":") else { return nil }
        return String(token[token.index(colon, offsetBy: -2)..<colon])
    }

    private static func strippingListMarker(_ line: String) -> String {
        if line.hasPrefix("- ") || line.hasPrefix("* ") {
            return String(line.dropFirst(2))
        }
        return line
    }

    private static func timeAllocations(from markdown: String) -> [TimeAllocation] {
        var rows: [(String, String)] = []
        for line in markdown.components(separatedBy: "\n") {
            let clean = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard clean.hasPrefix("|"), clean.hasSuffix("|") else { continue }
            let columns = clean.dropFirst().dropLast().split(
                separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard columns.count >= 2 else { continue }
            let first = columns[0]
            let second = columns[1]
            guard normalized(first) != "app",
                  !first.replacingOccurrences(of: "-", with: "").isEmpty else { continue }
            rows.append((unescapeTable(first), unescapeTable(second)))
        }
        return rows.enumerated().map { index, row in
            TimeAllocation(
                id: index,
                app: row.0,
                detail: row.1,
                seconds: durationSeconds(row.1))
        }
    }

    private static func durationSeconds(_ value: String) -> TimeInterval {
        if value.trimmingCharacters(in: .whitespacesAndNewlines) == "<1m" { return 30 }
        var seconds: TimeInterval = 0
        for token in value.lowercased().split(whereSeparator: \Character.isWhitespace) {
            if token.hasSuffix("h"), let hours = Double(token.dropLast()) {
                seconds += hours * 3_600
            } else if token.hasSuffix("m"), let minutes = Double(token.dropLast()) {
                seconds += minutes * 60
            }
        }
        return seconds
    }

    private static func unescapeTable(_ value: String) -> String {
        value.replacingOccurrences(of: "\\|", with: "|")
            .replacingOccurrences(of: "\\*", with: "*")
            .replacingOccurrences(of: "\\_", with: "_")
            .replacingOccurrences(of: "\\[", with: "[")
            .replacingOccurrences(of: "\\]", with: "]")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

}

/// Collapsed task copy stays scannable; rendered overflow expands in place.
enum DayDigestTaskSummaryExpansion {
    static let collapsedLineLimit = 3

    static func hasRenderedOverflow(fullHeight: CGFloat, collapsedHeight: CGFloat) -> Bool {
        guard fullHeight > 0, collapsedHeight > 0 else { return false }
        return fullHeight > collapsedHeight + 1
    }
}
