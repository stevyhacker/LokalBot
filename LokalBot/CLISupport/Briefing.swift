import Foundation

/// `get_briefing` and `lokalbot-cli brief`: the one call an agent makes first,
/// so it knows what LokalBot holds and what it may ask before it asks the
/// user. A fixed-size, recency-weighted read in the spirit of OptMem's `wake`,
/// assembled from what LokalBot already records. Every section is gated by
/// the permission that already covers its data; with nothing granted, the
/// briefing says only which permissions are off and how to turn them on.
enum Briefing {
    static let toolName = "get_briefing"
    static let maximumCharacters = 12_000

    /// What the briefing tells the agent to call next: MCP tools for
    /// `get_briefing`, `lokalbot-cli` commands for `brief`, so an agent that
    /// can only run a shell isn't pointed at tools it can't reach.
    enum Vocabulary {
        case mcp
        case cli
    }

    struct Context {
        var root: URL
        var meetingAccess: Bool
        var screenGate: ScreenMemoryAccessGate
        var personalGate: PersonalContextAccessGate
        var screenReader: any ScreenMemoryReading
        var now: Date
        var calendar: Calendar = .current
        var vocabulary: Vocabulary = .mcp
    }

    static var definition: ToolDefinition {
        ToolDefinition(
            name: toolName,
            description: "Call this first in every session. Returns what LokalBot knows that this session may use: "
                + "which sources are available, what the user shared about themselves, their open action items, "
                + "current projects and goals, recent coding-agent work, and a timeline of recent days, weeks, and "
                + "months. Check it, and search LokalBot, before asking the user about past work or decisions.",
            inputSchema: ["type": "object", "properties": [:]])
    }

    static func render(_ context: Context) -> String {
        let screenOn = context.screenGate.isEnabled
        let profile = screenOn ? context.screenGate.profile : nil
        let cutoff = screenOn ? screenCutoff(profile?.scope, now: context.now, calendar: context.calendar) : nil
        let cutoffDay = cutoff.map { DreamRollupFormat.dayKey($0, calendar: context.calendar) }
        let revocationPending = FileManager.default.fileExists(
            atPath: context.root.appendingPathComponent(".dream-revocation-pending.json").path)
        let meetings = context.meetingAccess ? ((try? SessionLookup.loadAllMeetings(root: context.root)) ?? []) : []
        let projection = context.personalGate.isEnabled ? context.personalGate.readProjection() : nil

        var sections: [String] = []
        sections.append("""
            LokalBot briefing, \(longDay(context.now, calendar: context.calendar)). This is background from the \
            user's own Mac. Read it before asking the user about past work, decisions, or where something stands; \
            search LokalBot for anything not shown. Items not listed are unknown, not false.
            """)
        sections.append(capabilities(context, meetings: meetings, screenScope: profile?.scope, projection: projection))
        if let projection, !projection.claims.isEmpty {
            sections.append(aboutYou(projection))
        }
        if context.meetingAccess, let actions = openActions(meetings, context: context) {
            sections.append(actions)
        }
        if revocationPending {
            sections.append("LokalBot is still removing deleted material, so work memory and the timeline are "
                + "withheld until it finishes.")
        } else if let work = workMemory(context, screenOn: screenOn, cutoffDay: cutoffDay) {
            sections.append(work)
        }
        if screenOn, let agents = agentWork(context, cutoff: cutoff) {
            sections.append(agents)
        }
        if !revocationPending, context.meetingAccess, screenOn,
           let timeline = timeline(context, cutoffDay: cutoffDay) {
            sections.append(timeline)
        }
        switch context.vocabulary {
        case .mcp:
            sections.append("For more: search_meetings and get_meeting for what was said, list_meetings with "
                + "include \"summary\" for several meetings' summaries at once, get_action_items for "
                + "commitments, search_screen and get_timeline for what was on screen, get_personal_context for "
                + "what the user shared about themselves. Cite meetings by title and date from tool results, "
                + "not from this briefing.")
        case .cli:
            sections.append("For more, run lokalbot-cli: search and get for what was said, list --include "
                + "summary for several meetings' summaries at once, actions for commitments, personal-context "
                + "--task for what the user shared about themselves. Cite meetings by title and date from "
                + "command results, not from this briefing.")
        }
        let text = sections.joined(separator: "\n\n")
        guard text.count > maximumCharacters else { return text }
        return String(text.prefix(maximumCharacters - 40)) + "\n…(briefing cut at its size limit)"
    }

    // MARK: - Sections

    private static func capabilities(_ context: Context, meetings: [Meeting],
                                     screenScope: ScreenMemoryAccessProfile.Scope?,
                                     projection: PersonalContextProjection?) -> String {
        let cli = context.vocabulary == .cli
        var lines = ["## What you can ask LokalBot"]
        if context.meetingAccess {
            let own = meetings.filter(\.isOwnWork)
            if let newest = own.max(by: { $0.startedAt < $1.startedAt }) {
                lines.append("- Meetings: on. \(own.count) recorded, newest \"\(clean(newest.title, 80))\" "
                    + "(\(DreamRollupFormat.dayKey(newest.startedAt, calendar: context.calendar))). "
                    + (cli
                        ? "Commands: search, get, list, actions, people, and ask while the app runs."
                        : "Tools: search_meetings, get_meeting, list_meetings, get_action_items, list_people, "
                            + "get_person, and ask_library while the app runs."))
            } else {
                lines.append("- Meetings: on, none recorded yet.")
            }
            if let sample = meetings.first(where: \.isSample) {
                lines.append("- The library also holds LokalBot's sample meeting, \"\(clean(sample.title, 80))\": "
                    + "a made-up call with synthetic voices, not the user's work. Its results carry \"sample\": true.")
            }
        } else {
            lines.append("- Meetings: off. The user can turn on Settings → Privacy → \"Allow external agents to "
                + "read your meeting library\".")
        }
        if let screenScope {
            let window: String
            switch screenScope {
            case .today: window = "today only"
            case .recentWeek: window = "the last 7 days"
            case .retainedHistory: window = "all retained history"
            }
            lines.append("- Screen memory: on, \(window). "
                + (cli
                    ? "No lokalbot-cli command searches it."
                    : "Tools: search_screen, get_timeline, get_recent_activity, get_app_usage, "
                        + "get_screenshot_detail."))
        } else {
            lines.append("- Screen memory: off. The user can turn on Settings → Privacy → \"Allow external agents "
                + "to read screen memory\".")
        }
        if context.personalGate.isEnabled {
            if let projection {
                lines.append("- Personal Context: on, \(projection.claims.count) shared "
                    + "\(projection.claims.count == 1 ? "item" : "items"). "
                    + (cli ? "Command: personal-context." : "Tool: get_personal_context."))
            } else {
                lines.append("- Personal Context: on, but LokalBot hasn't written the shared items yet.")
            }
        } else {
            lines.append("- Personal Context: off. The user can turn on Settings → Privacy → \"Allow external agents to "
                + "read what I shared about myself\".")
        }
        return lines.joined(separator: "\n")
    }

    private static func aboutYou(_ projection: PersonalContextProjection) -> String {
        var lines = ["## About the user (shared by them)"]
        for claim in PersonalContextSelection.ordered(projection.claims, query: "").prefix(10) {
            let label = claim.source == .askedToRemember || claim.source == .addedInSettings ? "stated" : "learned"
            lines.append("- [\(claim.kind.rawValue), \(label)] \(clean(claim.text, 280))")
        }
        return lines.joined(separator: "\n")
    }

    private static func openActions(_ meetings: [Meeting], context: Context) -> String? {
        var filter = ActionItemsReport.Filter()
        filter.owner = .me
        filter.limit = 8
        let entries = ActionItemsReport.entries(
            meetings: meetings, root: context.root, filter: filter, now: context.now, calendar: context.calendar)
        guard !entries.isEmpty else { return nil }
        var lines = ["## The user's open action items"]
        for entry in entries {
            var line = "- \(clean(entry.text, 200))"
            if let due = entry.due_date ?? entry.due { line += " (due \(clean(due, 40))\(entry.overdue ? ", overdue" : ""))" }
            if let meeting = entry.meetings.first { line += " · from \"\(clean(meeting.title, 60))\"" }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    private struct WorkMemoryFile: Decodable {
        struct Source: Decodable { var kind: String }
        struct Provenance: Decodable {
            var sources: [Source]?
            var includesUnattributedContext: Bool?
        }
        struct Project: Decodable {
            var name: String
            var status: String
            var lastActiveDay: String
            var provenance: Provenance?
        }
        struct Goal: Decodable {
            var text: String
            var horizon: String
            var lastReinforcedDay: String
            var provenance: Provenance?
        }
        var activeProjects: [Project]?
        var workGoals: [Goal]?
    }

    /// Work memory items need the permission of every kind of source behind
    /// them: meeting access for meetings, screen access (and its history
    /// window) for screen, activity, and digest evidence. Items without
    /// source attribution are never shown.
    private static func workMemory(_ context: Context, screenOn: Bool, cutoffDay: String?) -> String? {
        let url = context.root.appendingPathComponent("memory/memory.json")
        guard let data = try? Data(contentsOf: url),
              let memory = try? JSONDecoder().decode(WorkMemoryFile.self, from: data) else { return nil }
        func allowed(_ provenance: WorkMemoryFile.Provenance?, lastDay: String) -> Bool {
            guard let provenance, provenance.includesUnattributedContext != true,
                  let sources = provenance.sources, !sources.isEmpty else { return false }
            let needsMeetings = sources.contains { $0.kind == "meeting" }
            let needsScreen = sources.contains { $0.kind != "meeting" }
            if needsMeetings && !context.meetingAccess { return false }
            if needsScreen && (!screenOn || (cutoffDay.map { lastDay < $0 } ?? false)) { return false }
            return true
        }
        let projects = (memory.activeProjects ?? []).filter { allowed($0.provenance, lastDay: $0.lastActiveDay) }
            .sorted { $0.lastActiveDay > $1.lastActiveDay }.prefix(8)
        let goals = (memory.workGoals ?? []).filter { allowed($0.provenance, lastDay: $0.lastReinforcedDay) }
            .sorted { $0.lastReinforcedDay > $1.lastReinforcedDay }.prefix(6)
        guard !projects.isEmpty || !goals.isEmpty else { return nil }
        var lines = ["## Current projects and goals (from LokalBot's overnight reviews)"]
        for project in projects {
            lines.append("- \(clean(project.name, 80)): \(clean(project.status, 160)) (last active \(project.lastActiveDay))")
        }
        for goal in goals {
            lines.append("- Goal: \(clean(goal.text, 160)) (\(clean(goal.horizon, 40)))")
        }
        return lines.joined(separator: "\n")
    }

    private static func agentWork(_ context: Context, cutoff: Date?) -> String? {
        let weekAgo = context.now.addingTimeInterval(-7 * 86_400)
        let start = max(cutoff ?? weekAgo, weekAgo)
        guard let sessions = try? context.screenReader.agentSessions(from: start, to: context.now, limit: 600),
              !sessions.isEmpty else { return nil }
        var order: [String] = []
        var byProject: [String: [ScreenMemoryAgentSession]] = [:]
        for session in sessions.sorted(by: { $0.start > $1.start }) {
            let key = session.project.isEmpty ? "(no project)" : session.project
            if byProject[key] == nil { order.append(key) }
            byProject[key, default: []].append(session)
        }
        var lines = ["## Recent coding-agent work (last 7 days)"]
        for project in order.prefix(8) {
            let group = byProject[project] ?? []
            guard let latest = group.first else { continue }
            let agents = Array(Set(group.map(\.agent))).sorted().joined(separator: ", ")
            let sessionKeys: [String] = group.map { session -> String in
                session.sessionID.isEmpty ? session.start.description : session.agent + "|" + session.sessionID
            }
            let sessionCount = Set(sessionKeys).count
            let pullRequests = Set(group.flatMap(\.pullRequests)).count
            var line = "- \(clean(project, 60)) (\(agents), \(sessionCount) "
                + "\(sessionCount == 1 ? "session" : "sessions"), latest "
                + "\(shortDay(latest.start, calendar: context.calendar)))"
            // Automated wake-ups title a session with their raw tags.
            if let titled = group.first(where: { !$0.title.isEmpty && !$0.title.hasPrefix("<") }) {
                line += ": \(clean(titled.title, 140))"
            }
            if pullRequests > 0 { line += " · \(pullRequests) pull \(pullRequests == 1 ? "request" : "requests")" }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    /// Recent days in detail, older weeks and months as one line each, all
    /// inside the screen-memory history window.
    private static func timeline(_ context: Context, cutoffDay: String?) -> String? {
        let calendar = context.calendar
        let reviews = DreamRollupFormat.reviews(root: context.root)
        var lines: [String] = []
        for offset in 0..<7 {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: context.now) else { continue }
            let key = DreamRollupFormat.dayKey(date, calendar: calendar)
            if let cutoffDay, key < cutoffDay { break }
            guard let review = reviews[key] else { continue }
            let detail = offset < 2
                ? DreamRollupFormat.sentences(review.narrative, count: 2, maxCharacters: 320)
                : DreamRollupFormat.sentences(review.narrative, count: 1, maxCharacters: 200)
            lines.append("- \(shortDay(date, calendar: calendar)): \(clean(detail, 320))")
        }
        let recentStart = calendar.date(byAdding: .day, value: -6, to: context.now).map {
            DreamRollupFormat.dayKey($0, calendar: calendar)
        } ?? ""
        let rollups = DreamRollupFormat.rollups(root: context.root).filter { rollup in
            guard DreamRollupFormat.isValid(rollup, reviews: reviews) else { return false }
            guard let cutoffDay else { return true }
            return rollup.firstDay >= cutoffDay
        }
        let weeks = rollups.filter { $0.kind == .week && $0.lastDay < recentStart }
            .sorted { $0.firstDay > $1.firstDay }.prefix(6)
        let monthsEnd = weeks.last?.firstDay ?? recentStart
        let months = rollups.filter { $0.kind == .month && $0.lastDay < monthsEnd }
            .sorted { $0.firstDay > $1.firstDay }.prefix(6)
        for week in weeks {
            let label = DreamRollupFormat.date(fromDayKey: week.firstDay, calendar: calendar)
                .map { DreamRollupFormat.week(containing: $0, calendar: calendar).label } ?? week.key
            lines.append("- \(label): \(clean(week.line, 240))")
        }
        for month in months {
            let label = DreamRollupFormat.date(fromDayKey: month.firstDay, calendar: calendar)
                .map { DreamRollupFormat.month(containing: $0, calendar: calendar).label } ?? month.key
            lines.append("- \(label): \(clean(month.line, 240))")
        }
        guard !lines.isEmpty else { return nil }
        return (["## Recent days, then weeks and months (from LokalBot's overnight reviews)"] + lines)
            .joined(separator: "\n")
    }

    // MARK: - Helpers

    private static func screenCutoff(_ scope: ScreenMemoryAccessProfile.Scope?, now: Date,
                                     calendar: Calendar) -> Date? {
        switch scope {
        case .today: calendar.startOfDay(for: now)
        case .recentWeek: now.addingTimeInterval(-7 * 86_400)
        case .retainedHistory, nil: nil
        }
    }

    private static func clean(_ text: String, _ limit: Int) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard flat.count > limit else { return flat }
        return String(flat.prefix(limit - 1)) + "…"
    }

    private static func shortDay(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEE MMM d"
        return formatter.string(from: date)
    }

    private static func longDay(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEEE d MMMM yyyy"
        return formatter.string(from: date)
    }
}
