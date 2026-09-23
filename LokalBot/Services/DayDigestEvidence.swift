import Foundation

/// One retained, privacy-scrubbed screen-context record used by the day digest.
/// Pixels never enter this value; `text` is the same local Accessibility/OCR
/// text already stored in the screen-memory index.
struct DayScreenContext: Equatable, Sendable {
    var snapshotID: Int64
    var capturedAt: Date
    var app: String
    var windowTitle: String
    var text: String
}

/// Meeting evidence folded into the workday summary without making the day
/// pipeline parse meeting artifacts itself.
struct DayDigestMeetingEvidence: Equatable, Sendable {
    var id: UUID
    var title: String
    var app: String
    var startedAt: Date
    var endedAt: Date
    var sourceSummary: String
    var outcomes: String
    /// Latest write among the summary/outcomes files consumed for this meeting.
    /// It is evidence even when the meeting's own end time is unchanged.
    var artifactModifiedAt: Date?
}

enum DayDigestMeetingArtifacts {
    static let fileNames = [
        "summary.md",
        MeetingOutcomes.fileName,
        MeetingOutcomeState.fileName,
    ]

    static func latestModifiedAt(in folder: URL) -> Date? {
        // Archive-only corrections are not consumed by the current digest.
        let hasCurrentOutcomes = FileManager.default.fileExists(
            atPath: folder.appendingPathComponent(MeetingOutcomes.fileName).path)
        return fileNames.compactMap { name -> Date? in
            guard name != MeetingOutcomeState.fileName || hasCurrentOutcomes else { return nil }
            let url = folder.appendingPathComponent(name)
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            return attributes?[.modificationDate] as? Date
        }.max()
    }
}

/// One deterministic slice of the day that receives a substantive-work
/// eligibility pass. Character pressure may split a long active session, while
/// a real idle gap always starts a new slice. Metadata-only slices stay in the
/// lossless journal without becoming visible summary items.
struct DayDigestSummarySegment: Equatable, Sendable {
    var start: Date
    var end: Date
    var activeDuration: TimeInterval
    var evidence: String
    var eventCount: Int
    var sourceIDs: [Int64]
}

/// Complete, ordered evidence for one local calendar day. The model consumes
/// bounded chunks of this value, while the journal's chronological log is
/// rendered directly so model brevity or failure can never omit activity.
struct DayDigestEvidence: Equatable, Sendable {
    struct Activity: Equatable, Sendable {
        var id: Int64
        var start: Date
        var end: Date
        var app: String
        var title: String
        var contexts: [DayScreenContext]
    }

    var day: Date
    var interval: DateInterval
    var activities: [Activity]
    var standaloneContexts: [DayScreenContext]
    var meetings: [DayDigestMeetingEvidence]

    var isEmpty: Bool {
        activities.isEmpty && standaloneContexts.isEmpty && meetings.isEmpty
    }

    var latestEvidenceAt: Date? {
        let activityEnd = activities.map(\.end).max()
        let contextCapture = standaloneContexts.map(\.capturedAt).max()
        let meetingEnd = meetings.map(\.endedAt).max()
        let meetingArtifact = meetings.compactMap(\.artifactModifiedAt).max()
        return [activityEnd, contextCapture, meetingEnd, meetingArtifact]
            .compactMap { $0 }
            .max()
    }

    static func build(
        day: Date,
        blocks: [ActivityBlock],
        screenContexts: [DayScreenContext],
        meetings: [DayDigestMeetingEvidence],
        calendar: Calendar = .current
    ) -> DayDigestEvidence {
        let interval = ActivityStore.dayInterval(containing: day, calendar: calendar)
        let clipped = blocks.compactMap { block -> Activity? in
            let start = max(block.start, interval.start)
            let end = min(block.end, interval.end)
            guard end > start else { return nil }
            return Activity(id: block.id, start: start, end: end, app: block.app,
                            title: block.title, contexts: [])
        }.sorted { lhs, rhs in
            lhs.start == rhs.start ? lhs.id < rhs.id : lhs.start < rhs.start
        }

        var activities = clipped
        var standalone: [DayScreenContext] = []
        let contexts = deduplicated(screenContexts)
            .filter { interval.contains($0.capturedAt) }
            .sorted { lhs, rhs in
                lhs.capturedAt == rhs.capturedAt
                    ? lhs.snapshotID < rhs.snapshotID
                    : lhs.capturedAt < rhs.capturedAt
            }

        for context in contexts {
            if let index = activities.firstIndex(where: {
                context.capturedAt >= $0.start && context.capturedAt < $0.end
            }) {
                activities[index].contexts.append(context)
            } else {
                standalone.append(context)
            }
        }

        return DayDigestEvidence(
            day: day,
            interval: interval,
            activities: activities,
            standaloneContexts: standalone,
            meetings: meetings.sorted { lhs, rhs in
                lhs.startedAt == rhs.startedAt
                    ? lhs.id.uuidString < rhs.id.uuidString
                    : lhs.startedAt < rhs.startedAt
            })
    }

    /// Full-day evidence for LLM summarization. Every summary-worthy activity
    /// and meeting appears in exactly one segment, and each long block contributes
    /// evenly spaced context in proportion to its duration rather than letting
    /// the morning exhaust a global cap. An idle gap creates a hard boundary,
    /// so short morning work cannot be obscured by an afternoon session.
    func summarySegments(
        maxCharacters: Int = 12_000,
        inactivityGap: TimeInterval = 10 * 60,
        maxSegments: Int = 8
    ) -> [DayDigestSummarySegment] {
        guard maxCharacters > 0, maxSegments > 0 else { return [] }
        let events = summaryEvents()
        guard !events.isEmpty else { return [] }

        var sessions: [[SummaryEvent]] = []
        for event in events {
            if let previousEnd = sessions.last?.map(\.end).max(),
               event.start.timeIntervalSince(previousEnd) <= inactivityGap {
                sessions[sessions.count - 1].append(event)
            } else {
                sessions.append([event])
            }
        }

        // More than eight isolated sessions are rare, but merging the shortest
        // adjacent pair preserves every event without letting a few brief
        // interruptions consume most of the bounded UI.
        while sessions.count > maxSegments {
            var smallestIndex = 0
            var smallestDuration = coveredDuration(
                of: sessions[0] + sessions[1])
            if sessions.count > 2 {
                for index in 1..<(sessions.count - 1) {
                    let combinedDuration = coveredDuration(
                        of: sessions[index] + sessions[index + 1])
                    if combinedDuration < smallestDuration {
                        smallestIndex = index
                        smallestDuration = combinedDuration
                    }
                }
            }
            sessions[smallestIndex].append(
                contentsOf: sessions.remove(at: smallestIndex + 1))
        }

        var allocations = Array(repeating: 1, count: sessions.count)
        while allocations.reduce(0, +) < maxSegments {
            let candidates = sessions.indices.filter {
                allocations[$0] < sessions[$0].count
            }
            guard let index = candidates.max(by: { lhs, rhs in
                sessionWeight(sessions[lhs]) / Double(allocations[lhs])
                    < sessionWeight(sessions[rhs]) / Double(allocations[rhs])
            }) else { break }
            allocations[index] += 1
        }

        var groups: [[SummaryEvent]] = []
        for index in sessions.indices {
            let session = sessions[index]
            let count = allocations[index]
            for part in 0..<count {
                let lower = part * session.count / count
                let upper = (part + 1) * session.count / count
                if lower < upper { groups.append(Array(session[lower..<upper])) }
            }
        }
        return groups.map {
            makeSummarySegment(events: $0, maxCharacters: maxCharacters)
        }
    }

    /// Compatibility view used by existing callers and tests.
    func summaryChunks(maxCharacters: Int = 12_000) -> [String] {
        summarySegments(maxCharacters: maxCharacters).map(\.evidence)
    }

    func renderDocument(summary: String, calendar: Calendar = .current) -> String {
        let cleanSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let summaryBody = cleanSummary.isEmpty
            ? "_No grounded summary was generated. The chronological log below is complete._"
            : cleanSummary
        return [
            "## Day summary\n\n\(summaryBody)",
            "## Meetings\n\n\(meetingsSection(calendar: calendar))",
            "## Time allocation\n\n\(timeAllocationSection())",
            "## Full activity log\n\n\(chronologicalLog(calendar: calendar))",
        ].joined(separator: "\n\n") + "\n"
    }

    private static func deduplicated(_ contexts: [DayScreenContext]) -> [DayScreenContext] {
        var result: [DayScreenContext] = []
        var previousFingerprint: String?
        for context in contexts.sorted(by: {
            $0.capturedAt == $1.capturedAt
                ? $0.snapshotID < $1.snapshotID
                : $0.capturedAt < $1.capturedAt
        }) {
            let text = PromptContextSanitizer.sanitize(context.text)
            let fingerprint = [context.app.lowercased(), context.windowTitle.lowercased(), text]
                .joined(separator: "\u{1f}")
            guard fingerprint != previousFingerprint else { continue }
            previousFingerprint = fingerprint
            var sanitized = context
            sanitized.text = text
            result.append(sanitized)
        }
        return result
    }

    private func representativeContexts(
        _ contexts: [DayScreenContext],
        limit: Int = 3
    ) -> [DayScreenContext] {
        guard limit > 0 else { return [] }
        guard contexts.count > limit else { return contexts }
        return evenlySpacedIndices(count: contexts.count, limit: limit).map {
            contexts[$0]
        }
    }

    /// A long uninterrupted app/window block used to expose only three screen
    /// samples—the same evidence depth as a five-minute task. Increase breadth
    /// with active duration while keeping excerpts inside a fixed character
    /// budget, so hours of work are represented across their full span.
    private func summaryContexts(for activity: Activity) -> [DayScreenContext] {
        let duration = max(0, activity.end.timeIntervalSince(activity.start))
        let proportionalLimit = Int(ceil(duration / (30 * 60))) + 1
        return representativeContexts(
            activity.contexts,
            limit: min(12, max(2, proportionalLimit)))
    }

    private struct SummaryEvent {
        var start: Date
        var end: Date
        var order: Int
        var text: String
        var sourceIDs: [Int64]
        var app: String
        var title: String
    }

    private func sessionWeight(_ events: [SummaryEvent]) -> Double {
        let duration = coveredDuration(of: events)
        return duration > 0 ? duration : Double(events.count)
    }

    /// Union the recorded intervals so overlapping meeting and app evidence is
    /// not double-counted when deciding how much narrative space a segment gets.
    private func coveredDuration(of events: [SummaryEvent]) -> TimeInterval {
        let intervals = events.compactMap { event -> DateInterval? in
            guard event.end > event.start else { return nil }
            return DateInterval(start: event.start, end: event.end)
        }.sorted { $0.start < $1.start }
        guard var current = intervals.first else { return 0 }
        var total: TimeInterval = 0
        for interval in intervals.dropFirst() {
            if interval.start <= current.end {
                current = DateInterval(
                    start: current.start,
                    end: max(current.end, interval.end))
            } else {
                total += current.duration
                current = interval
            }
        }
        return total + current.duration
    }

    private func summaryEvents() -> [SummaryEvent] {
        var events: [SummaryEvent] = []
        for activity in activities where !isSystemOnlySummaryActivity(app: activity.app) {
            let contexts = summaryContexts(for: activity)
            let perContextBudget = contexts.isEmpty
                ? 0
                : max(360, min(1_200, 8_400 / contexts.count))
            var lines = ["WORK SOURCE: ACTIVITY"]
            if !activity.title.isEmpty {
                lines.append(
                    "Possible task context (weak; corroborate before summarizing): "
                        + activity.title)
            }
            for context in contexts {
                let source = context.snapshotID > 0 ? "[screen:\(context.snapshotID)]" : "[screen]"
                let text = summaryExcerpt(
                    context.text,
                    maxCharacters: perContextBudget)
                if !text.isEmpty {
                    lines.append("Screen context \(source):\n\(text)")
                }
            }
            lines.append(
                "LOW-PRIORITY TRACE METADATA — do not summarize directly:\n"
                    + "\(time(activity.start))–\(time(activity.end)); "
                    + "app=\(activity.app); "
                    + "window=\(activity.title.isEmpty ? "Unknown" : activity.title); "
                    + "duration=\(duration(activity.end.timeIntervalSince(activity.start)))")
            events.append(SummaryEvent(
                start: activity.start,
                end: activity.end,
                order: 1,
                text: lines.joined(separator: "\n"),
                sourceIDs: contexts.map(\.snapshotID).filter { $0 > 0 },
                app: activity.app,
                title: activity.title))
        }
        for context in standaloneContexts where !isSystemOnlySummaryActivity(app: context.app) {
            let source = context.snapshotID > 0 ? "[screen:\(context.snapshotID)]" : "[screen]"
            let text = summaryExcerpt(context.text, maxCharacters: 1_200)
            events.append(SummaryEvent(
                start: context.capturedAt,
                end: context.capturedAt,
                order: 2,
                text: """
                    WORK SOURCE: SCREEN CONTEXT \(source)
                    Captured work text: \(text)
                    LOW-PRIORITY TRACE METADATA — do not summarize directly:
                    \(time(context.capturedAt)); app=\(context.app); window=\(context.windowTitle.isEmpty ? "Unknown" : context.windowTitle)
                    """,
                sourceIDs: context.snapshotID > 0 ? [context.snapshotID] : [],
                app: context.app,
                title: context.windowTitle))
        }
        for meeting in meetings {
            var lines = ["WORK SOURCE: MEETING", "Task context: \(meeting.title)"]
            let sourceSummary = PromptContextSanitizer.sanitize(
                meeting.sourceSummary, maxCharacters: 6_000)
            if !sourceSummary.isEmpty { lines.append("Source summary:\n" + sourceSummary) }
            let outcomes = PromptContextSanitizer.sanitize(
                meeting.outcomes, maxCharacters: 3_000)
            if !outcomes.isEmpty { lines.append("Outcomes:\n" + outcomes) }
            lines.append(
                "LOW-PRIORITY TRACE METADATA — do not summarize directly:\n"
                    + "\(time(meeting.startedAt))–\(time(meeting.endedAt)); "
                    + "app=\(meeting.app)")
            events.append(SummaryEvent(
                start: meeting.startedAt,
                end: meeting.endedAt,
                order: 0,
                text: lines.joined(separator: "\n"),
                sourceIDs: [],
                app: meeting.app,
                title: meeting.title))
        }
        events.sort { lhs, rhs in
            if lhs.start == rhs.start { return lhs.order < rhs.order }
            return lhs.start < rhs.start
        }
        return events
    }

    /// Login transitions are useful in the lossless activity log, but they are
    /// not work topics and should not consume scarce overview space.
    private func isSystemOnlySummaryActivity(app: String) -> Bool {
        app.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("loginwindow") == .orderedSame
    }

    private func makeSummarySegment(
        events: [SummaryEvent],
        maxCharacters: Int
    ) -> DayDigestSummarySegment {
        let detailIndices = summaryDetailIndices(events: events, limit: 12)
        let contentBudget = max(120, Int(Double(maxCharacters) * 0.82))
        let perDetailBudget = max(120, contentBudget / max(1, detailIndices.count))
        let details = detailIndices.map { index in
            PromptContextSanitizer.sanitize(
                events[index].text,
                maxCharacters: perDetailBudget)
        }.filter { !$0.isEmpty }
        var evidence = "WORK CONTENT — primary evidence:\n"
            + details.joined(separator: "\n\n---\n\n")

        let remaining = max(0, maxCharacters - evidence.count - 72)
        if remaining > 80 {
            let perLineBudget = max(48, min(160, remaining / max(1, events.count)))
            let inventoryLines = events.map { event in
                let title = event.title.isEmpty ? "Unknown" : event.title
                return singleLine(
                    "[\(time(event.start))–\(time(event.end))] \(event.app) — \(title)",
                    maxCharacters: perLineBudget)
            }
            evidence += "\n\nLOW-PRIORITY TRACE METADATA — context only, never a work item:\n"
                + inventoryLines.joined(separator: "\n")
        }
        evidence = PromptContextSanitizer.sanitize(
            evidence, maxCharacters: maxCharacters)

        var sourceIDs: [Int64] = []
        for event in events {
            for id in event.sourceIDs where !sourceIDs.contains(id) { sourceIDs.append(id) }
        }
        return DayDigestSummarySegment(
            start: events.first?.start ?? day,
            end: events.map(\.end).max() ?? events.first?.start ?? day,
            activeDuration: coveredDuration(of: events),
            evidence: evidence,
            eventCount: events.count,
            sourceIDs: sourceIDs)
    }

    /// Meetings are already structured work evidence, so a busy interval must
    /// not sample around them merely because it contains many short activity
    /// events. Fill the remaining detail budget evenly across the interval.
    private func summaryDetailIndices(
        events: [SummaryEvent],
        limit: Int
    ) -> [Int] {
        guard !events.isEmpty, limit > 0 else { return [] }
        let meetingIndices = events.indices.filter { events[$0].order == 0 }
        if meetingIndices.count >= limit {
            return evenlySpacedIndices(count: meetingIndices.count, limit: limit)
                .map { meetingIndices[$0] }
        }

        let remainingIndices = events.indices.filter { events[$0].order != 0 }
        let remainingLimit = min(limit - meetingIndices.count, remainingIndices.count)
        let sampled = evenlySpacedIndices(
            count: remainingIndices.count,
            limit: remainingLimit
        ).map { remainingIndices[$0] }
        return (meetingIndices + sampled).sorted()
    }

    private func evenlySpacedIndices(count: Int, limit: Int) -> [Int] {
        guard count > 0, limit > 0 else { return [] }
        if limit == 1 { return [0] }
        if count <= limit { return Array(0..<count) }
        let denominator = Double(limit - 1)
        var result: [Int] = []
        for index in 0..<limit {
            let position = Int((Double(index) * Double(count - 1) / denominator).rounded())
            if !result.contains(position) { result.append(position) }
        }
        return result
    }

    private func chronologicalLog(calendar: Calendar) -> String {
        enum Event {
            case activity(Activity)
            case context(DayScreenContext)
            case meeting(DayDigestMeetingEvidence)

            var date: Date {
                switch self {
                case .activity(let value): value.start
                case .context(let value): value.capturedAt
                case .meeting(let value): value.startedAt
                }
            }

            var order: Int {
                switch self {
                case .meeting: 0
                case .activity: 1
                case .context: 2
                }
            }
        }

        var events = activities.map(Event.activity)
        events += standaloneContexts.map(Event.context)
        events += meetings.map(Event.meeting)
        events.sort { lhs, rhs in
            lhs.date == rhs.date ? lhs.order < rhs.order : lhs.date < rhs.date
        }
        guard !events.isEmpty else { return "_No activity was recorded._" }

        return events.map { event in
            switch event {
            case .activity(let activity):
                var line = "- **\(time(activity.start, calendar: calendar))–"
                    + "\(time(activity.end, calendar: calendar))** — "
                    + "**\(markdownInline(activity.app))**"
                if !activity.title.isEmpty {
                    line += " — \(markdownInline(activity.title))"
                }
                for context in representativeContexts(activity.contexts) {
                    let excerpt = singleLine(context.text, maxCharacters: 360)
                    guard !excerpt.isEmpty else { continue }
                    let source = context.snapshotID > 0
                        ? "[screen:\(context.snapshotID)]" : "screen context"
                    line += "\n  - \(source), \(time(context.capturedAt, calendar: calendar)): "
                        + markdownInline(excerpt)
                }
                return line
            case .context(let context):
                let title = context.windowTitle.isEmpty
                    ? markdownInline(context.app)
                    : "\(markdownInline(context.app)) — \(markdownInline(context.windowTitle))"
                let source = context.snapshotID > 0
                    ? "[screen:\(context.snapshotID)]" : "screen context"
                let excerpt = singleLine(context.text, maxCharacters: 360)
                return "- **\(time(context.capturedAt, calendar: calendar))** — "
                    + "**Screen context** — \(title)\n  - \(source): \(markdownInline(excerpt))"
            case .meeting(let meeting):
                return "- **\(time(meeting.startedAt, calendar: calendar))–"
                    + "\(time(meeting.endedAt, calendar: calendar))** — **Meeting** — "
                    + "\(markdownInline(meeting.title)) (\(markdownInline(meeting.app)))"
            }
        }.joined(separator: "\n")
    }

    private func meetingsSection(calendar: Calendar) -> String {
        guard !meetings.isEmpty else { return "_None._" }
        return meetings.map { meeting in
            var lines = [
                "### \(time(meeting.startedAt, calendar: calendar)) — \(markdownInline(meeting.title))",
                "- App: \(markdownInline(meeting.app))",
                "- Duration: \(duration(meeting.endedAt.timeIntervalSince(meeting.startedAt)))",
            ]
            let summary = singleLine(meeting.sourceSummary, maxCharacters: 600)
            if !summary.isEmpty { lines.append("- Source summary: \(markdownInline(summary))") }
            let outcomes = singleLine(meeting.outcomes, maxCharacters: 400)
            if !outcomes.isEmpty { lines.append("- Outcomes: \(markdownInline(outcomes))") }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    private func timeAllocationSection() -> String {
        let activitiesByApp: [String: [Activity]] = Dictionary(
            grouping: activities,
            by: { activity in activity.app }
        )
        var totals: [(app: String, seconds: TimeInterval)] = []
        totals.reserveCapacity(activitiesByApp.count)
        for (app, appActivities) in activitiesByApp {
            var seconds: TimeInterval = 0
            for activity in appActivities {
                seconds += activity.end.timeIntervalSince(activity.start)
            }
            totals.append((app: app, seconds: seconds))
        }
        totals.sort { lhs, rhs in
            lhs.seconds == rhs.seconds ? lhs.app < rhs.app : lhs.seconds > rhs.seconds
        }
        guard !totals.isEmpty else { return "_No tracked app time._" }
        var lines = ["| App | Tracked time |", "| --- | ---: |"]
        lines += totals.map { app, seconds in
            "| \(markdownTable(app)) | \(duration(seconds)) |"
        }
        return lines.joined(separator: "\n")
    }

    /// Remove recurring Accessibility chrome only from the model-facing
    /// excerpt. The deterministic journal below retains the original scrubbed
    /// evidence verbatim, including source IDs, for inspection and export.
    private func summaryExcerpt(_ value: String, maxCharacters: Int) -> String {
        var result = PromptContextSanitizer.sanitize(value)
        let recurringChrome = [
            "this button also has an action to zoom the window",
            "Bookmarks New Tab Back Forward Reload",
            "Chrome Apps Saved Tab Groups Separator",
            "Hide sidebar Back Forward Chat actions",
            "Toggle pinned summary Toggle bottom panel Toggle side panel",
        ]
        for phrase in recurringChrome {
            result = result.replacingOccurrences(
                of: phrase, with: "", options: .caseInsensitive)
        }
        return PromptContextSanitizer.sanitize(result, maxCharacters: maxCharacters)
    }

    private func time(_ date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int(seconds.rounded()) / 60)
        if minutes == 0 { return "<1m" }
        if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)m" }
        return "\(minutes)m"
    }

    private func singleLine(_ value: String, maxCharacters: Int) -> String {
        PromptContextSanitizer.sanitize(value, maxCharacters: maxCharacters)
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
    }

    private func markdownInline(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "*", with: "\\*")
            .replacingOccurrences(of: "_", with: "\\_")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
    }

    private func markdownTable(_ value: String) -> String {
        markdownInline(value).replacingOccurrences(of: "|", with: "\\|")
    }
}

struct DayDigestGeneratedFocusBlock: Equatable, Sendable {
    var task: String
    var workDone: String
    var status: String
    var outcome: String
    var nextStep: String
    var sourceIDs: [Int64]
}

/// Conservative lexical overlap detection for short, structured digest text.
/// It catches copied or lightly rephrased facts without treating every mention
/// of the same project as redundant.
enum DayDigestTextSimilarity {
    private static let ignoredWords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "been", "being", "by",
        "for", "from", "in", "is", "of", "on", "or", "that", "the", "this",
        "to", "was", "were", "with",
    ]

    static func isSimilar(_ lhs: String, _ rhs: String) -> Bool {
        let leftWords = meaningfulWords(in: lhs)
        let rightWords = meaningfulWords(in: rhs)
        guard !leftWords.isEmpty, !rightWords.isEmpty else { return false }

        let leftText = leftWords.joined(separator: " ")
        let rightText = rightWords.joined(separator: " ")
        if leftText == rightText { return true }

        let shorter = leftText.count <= rightText.count ? leftText : rightText
        let longer = leftText.count <= rightText.count ? rightText : leftText
        if shorter.count >= 16, longer.contains(shorter) { return true }

        let left = Set(leftWords)
        let right = Set(rightWords)
        if left == right, left.count >= 2 { return true }

        let sharedCount = left.intersection(right).count
        let smallerCount = min(left.count, right.count)
        guard sharedCount >= 4, smallerCount > 0 else { return false }
        return Double(sharedCount) / Double(smallerCount) >= 0.8
    }

    private static func meaningfulWords(in value: String) -> [String] {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { !ignoredWords.contains($0) }
    }
}

enum DayDigestGenerationQuality: String, Codable, Equatable, Sendable {
    case complete
    case partial
    case fallback

    var needsRepair: Bool { self != .complete }
}

struct DayDigestOverviewGeneration: Equatable, Sendable {
    var summary: String
    var quality: DayDigestGenerationQuality
}

/// Converts deterministic, gap-aware evidence segments into the compact
/// human layer shown above the lossless journal. A first model pass rejects
/// metadata-only segments and extracts structured work candidates. A second
/// pass groups those candidates by task; code retains every accepted candidate
/// even if that aggregation pass fails or omits one.
enum DayDigestOverviewGenerator {
    /// Display limits for journal task copy. Sized so titles wrap and
    /// summaries stay complete sentences instead of ending on an ellipsis.
    private enum FieldLimit {
        static let titleCharacters = 160
        static let summaryWords = 120
        static let workDoneWords = 80
        static let bulletCharacters = 1_200
    }

    private struct FocusDraft: Decodable {
        var substantive: Bool
        var task: String
        var workDone: String
        var status: String
        var outcome: String
        var nextStep: String
        var sourceIDs: [Int64]

        enum CodingKeys: String, CodingKey {
            case substantive
            case task
            case workDone = "work_done"
            case status
            case outcome
            case nextStep = "next_step"
            case sourceIDs = "source_ids"
        }
    }

    private struct ParsedFocus {
        var block: DayDigestGeneratedFocusBlock?
        var isSubstantive: Bool
    }

    private struct DigestDraft: Decodable {
        struct Task: Decodable {
            var title: String
            var status: String
            var summary: String
            var nextStep: String
            var blockIndices: [Int]

            enum CodingKeys: String, CodingKey {
                case title
                case status
                case summary
                case nextStep = "next_step"
                case blockIndices = "block_indices"
            }
        }

        var tasks: [Task]
        var decisions: [String]
        var blockers: [String]
    }

    private struct NormalizedTask: Equatable {
        var title: String
        var status: String
        var summary: String
        var nextStep: String
        var blockIndices: [Int]
    }

    private struct FallbackActivity {
        var title: String
        var duration: TimeInterval
        var firstSeenAt: Date
    }

    static func generate(
        evidence: DayDigestEvidence,
        engine: TextEngine,
        customPrompt: String,
        calendar: Calendar = .current
    ) async throws -> String {
        try await generateResult(
            evidence: evidence,
            engine: engine,
            customPrompt: customPrompt,
            calendar: calendar).summary
    }

    static func generateResult(
        evidence: DayDigestEvidence,
        engine: TextEngine,
        customPrompt: String,
        calendar: Calendar = .current
    ) async throws -> DayDigestOverviewGeneration {
        let segments = evidence.summarySegments()
        guard !segments.isEmpty else {
            return DayDigestOverviewGeneration(
                summary: fallback(evidence),
                quality: .complete)
        }
        let ranges = segments.map {
            "\(time($0.start, calendar: calendar))-\(time($0.end, calendar: calendar))"
        }.joined(separator: ",")
        lokalbotLog(
            "day digest plan model=\(engine.displayName) segments=\(segments.count) "
                + "events=\(segments.reduce(0) { $0 + $1.eventCount }) ranges=\(ranges)")

        let dateContext = [
            "Date: \(evidence.day.formatted(date: .complete, time: .omitted))",
        ]
        var substantiveBlocks: [DayDigestGeneratedFocusBlock] = []
        var fallbackBlocks: [DayDigestGeneratedFocusBlock] = []
        var degraded = false
        substantiveBlocks.reserveCapacity(segments.count)
        fallbackBlocks.reserveCapacity(segments.count)

        segmentLoop: for (index, segment) in segments.enumerated() {
            try Task.checkCancellation()
            let startedAt = Date()
            let focusPrompt = """
                Extract a substantive-work candidate from evidence segment \(index + 1) of \(segments.count).
                Decide eligibility from the work content, not from time spent or app usage.
                Allowed screen source IDs: \(segment.sourceIDs)

                \(segment.evidence)
                """
            var attempts = 1
            var output: String
            do {
                do {
                    output = try await engine.generate(
                        system: PromptTemplates.dayDigestFocusSystem,
                        prompt: focusPrompt,
                        context: dateContext,
                        schema: focusSchema,
                        options: TextGenerationOptions(
                            maxTokens: 768,
                            reasoningBudgetTokens: 256,
                            temperature: 0.2))
                } catch TextEngineError.outputTruncated {
                    attempts = 2
                    let retryStartedAt = Date()
                    do {
                        output = try await engine.generate(
                            system: PromptTemplates.dayDigestFocusSystem,
                            prompt: focusRetryPrompt + "\n\n" + focusPrompt,
                            context: dateContext,
                            schema: focusSchema,
                            options: TextGenerationOptions(
                                maxTokens: 1_600,
                                reasoningBudgetTokens: 0,
                                temperature: 0))
                        lokalbotLog(
                            "day digest segment retry index=\(index + 1) "
                                + "reason=output-limit elapsed="
                                + String(
                                    format: "%.2fs",
                                    Date().timeIntervalSince(retryStartedAt)))
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch TextEngineError.outputTruncated {
                        degraded = true
                        lokalbotLog(
                            "day digest segment retry exhausted index=\(index + 1) "
                                + "reason=output-limit elapsed="
                                + String(
                                    format: "%.2fs",
                                    Date().timeIntervalSince(retryStartedAt)))
                        continue segmentLoop
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                degraded = true
                lokalbotLog(
                    "day digest segment generation stopped index=\(index + 1) "
                        + "error=\(error.localizedDescription)")
                break segmentLoop
            }
            var parsed = parseFocus(output, segment: segment)
            if parsed == nil,
               ProcessInfo.processInfo.environment["LOKALBOT_DIGEST_DEBUG_OUTPUT"] == "1" {
                let preview = PromptContextSanitizer.sanitize(output, maxCharacters: 800)
                lokalbotLog("day digest parse preview index=\(index + 1): \(preview)")
            }
            if parsed == nil, attempts == 1 {
                attempts = 2
                let retryStartedAt = Date()
                do {
                    output = try await engine.generate(
                        system: PromptTemplates.dayDigestFocusSystem,
                        prompt: focusRetryPrompt + "\n\n" + focusPrompt,
                        context: dateContext,
                        schema: focusSchema,
                        options: TextGenerationOptions(
                            maxTokens: 1_600,
                            reasoningBudgetTokens: 0,
                            temperature: 0))
                    parsed = parseFocus(output, segment: segment)
                    if parsed == nil,
                       ProcessInfo.processInfo.environment["LOKALBOT_DIGEST_DEBUG_OUTPUT"] == "1" {
                        let preview = PromptContextSanitizer.sanitize(
                            output, maxCharacters: 800)
                        lokalbotLog(
                            "day digest retry parse preview index=\(index + 1): \(preview)")
                    }
                    lokalbotLog(
                        "day digest segment retry index=\(index + 1) parsed=\(parsed != nil) "
                            + "elapsed="
                            + String(format: "%.2fs", Date().timeIntervalSince(retryStartedAt)))
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    degraded = true
                    lokalbotLog(
                        "day digest segment retry index=\(index + 1) error="
                            + error.localizedDescription)
                    if let engineError = error as? TextEngineError,
                       case .serverUnreachable = engineError {
                        break segmentLoop
                    }
                }
            }
            if parsed == nil { degraded = true }
            if let parsed, let block = parsed.block {
                if parsed.isSubstantive {
                    substantiveBlocks.append(block)
                } else {
                    fallbackBlocks.append(block)
                }
            }
            lokalbotLog(
                "day digest segment index=\(index + 1)/\(segments.count) "
                    + "events=\(segment.eventCount) chars=\(segment.evidence.count) "
                    + "parsed=\(parsed != nil) "
                    + "substantive=\(parsed?.isSubstantive == true) "
                    + "usable=\(parsed?.block != nil) "
                    + "attempts=\(attempts) elapsed="
                    + String(format: "%.2fs", Date().timeIntervalSince(startedAt)))
        }

        let usesBestAvailableActivity = substantiveBlocks.isEmpty
        let selectedBlocks = usesBestAvailableActivity ? fallbackBlocks : substantiveBlocks
        guard !selectedBlocks.isEmpty else {
            return DayDigestOverviewGeneration(
                summary: fallback(evidence),
                quality: degraded ? .fallback : .complete)
        }

        let digest: DigestDraft?
        let digestStartedAt = Date()
        do {
            let aggregationInstruction = usesBestAvailableActivity
                ? "Retain the best grounded activity even without a concrete outcome."
                : "Rank by concrete outcome, useful progress, decision, or blocker. "
                    + "Do not rank by duration or chronology."
            let candidatesHeading = usesBestAvailableActivity
                ? "BEST AVAILABLE WORK OR ACTIVITY CANDIDATES:"
                : "SUBSTANTIVE WORK CANDIDATES:"
            let material = selectedBlocks.enumerated()
                .map { candidateMaterial($0.element, index: $0.offset) }
                .joined(separator: "\n")
            let system = usesBestAvailableActivity
                ? PromptTemplates.dayDigestFallbackSystem(custom: customPrompt)
                : PromptTemplates.dayDigestSystem(custom: customPrompt)
            let aggregationPrompt = """
                Build the daily recap from every accepted candidate below.
                Merge candidates for the same task and include every contributing
                candidate index in block_indices. \(aggregationInstruction)

                \(candidatesHeading)
                \(material)
                """
            let output: String
            do {
                output = try await engine.generate(
                    system: system,
                    prompt: aggregationPrompt,
                    context: dateContext,
                    schema: digestSchema,
                    options: TextGenerationOptions(
                        maxTokens: 1_600,
                        reasoningBudgetTokens: 512,
                        temperature: 0.2))
            } catch TextEngineError.outputTruncated {
                let retryStartedAt = Date()
                output = try await engine.generate(
                    system: system,
                    prompt: digestRetryPrompt + "\n\n" + aggregationPrompt,
                    context: dateContext,
                    schema: digestSchema,
                    options: TextGenerationOptions(
                        maxTokens: 3_200,
                        reasoningBudgetTokens: 0,
                        temperature: 0))
                lokalbotLog(
                    "day digest task aggregation retry reason=output-limit elapsed="
                        + String(format: "%.2fs", Date().timeIntervalSince(retryStartedAt)))
            }
            digest = parseDigest(output)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            degraded = true
            lokalbotLog(
                "day digest task aggregation fallback error=\(error.localizedDescription)")
            digest = nil
        }
        if digest == nil { degraded = true }
        lokalbotLog(
            "day digest task aggregation mode="
                + "\(usesBestAvailableActivity ? "best-available" : "substantive") "
                + "parsed=\(digest != nil) elapsed="
                + String(format: "%.2fs", Date().timeIntervalSince(digestStartedAt)))

        return DayDigestOverviewGeneration(
            summary: render(blocks: selectedBlocks, draft: digest),
            quality: degraded ? .partial : .complete)
    }

    private static let focusRetryPrompt = """
        The previous response was truncated or failed JSON validation.
        Retry once with a compact JSON object. Do not quote or restate the evidence.
        Keep task titles complete, including identifiers such as PR numbers.
        Write work_done as complete sentences; do not end mid-sentence.
        Keep outcome under 32 words and next_step under 28 words.
        """

    private static let digestRetryPrompt = """
        The previous response was truncated. Retry once with compact JSON.
        Include every candidate, but merge candidates that belong to the same task.
        Keep titles complete, including identifiers such as PR numbers.
        Write each summary as complete sentences; do not end mid-sentence.
        Keep each next_step, decision, or blocker under 32 words.
        Do not quote or restate candidate metadata.
        """

    static func fallback(_ evidence: DayDigestEvidence) -> String {
        if evidence.isEmpty {
            return "### At a glance\n_No activity was recorded._"
        }
        let blocks = bestAvailableFallbackBlocks(evidence)
        if !blocks.isEmpty {
            return render(blocks: blocks, draft: nil)
        }
        return "### Tasks\n- **Recorded activity** — Activity was captured, but the available context did not identify a more specific item."
    }

    /// Last-resort output for engine failures or evidence that every model
    /// pass rejected. Prefer meeting content, then the most sustained named
    /// activity contexts. This path stays deliberately conservative: it names
    /// what was present without inventing an accomplishment or outcome.
    private static func bestAvailableFallbackBlocks(
        _ evidence: DayDigestEvidence,
        limit: Int = 6
    ) -> [DayDigestGeneratedFocusBlock] {
        guard limit > 0 else { return [] }
        var blocks: [DayDigestGeneratedFocusBlock] = []

        for meeting in evidence.meetings {
            let title = cleanInline(meeting.title, maxCharacters: FieldLimit.titleCharacters)
            let workDone = fallbackMeetingSummary(meeting)
            blocks.append(DayDigestGeneratedFocusBlock(
                task: title.isEmpty ? "Recorded meeting" : title,
                workDone: workDone.isEmpty ? "Participated in the recorded meeting." : workDone,
                status: "unknown",
                outcome: cleanSummary(meeting.outcomes, maxWords: 32),
                nextStep: "",
                sourceIDs: []))
            if blocks.count == limit { return blocks }
        }

        var grouped: [String: FallbackActivity] = [:]
        for activity in evidence.activities {
            guard let title = fallbackActivityTitle(
                activity.title,
                app: activity.app
            ) else { continue }
            let key = normalizedTaskKey(title)
            let duration = max(0, activity.end.timeIntervalSince(activity.start))
            if var existing = grouped[key] {
                existing.duration += duration
                existing.firstSeenAt = min(existing.firstSeenAt, activity.start)
                grouped[key] = existing
            } else {
                grouped[key] = FallbackActivity(
                    title: title,
                    duration: duration,
                    firstSeenAt: activity.start)
            }
        }
        for context in evidence.standaloneContexts {
            guard let title = fallbackActivityTitle(
                context.windowTitle,
                app: context.app
            ) else { continue }
            let key = normalizedTaskKey(title)
            if grouped[key] == nil {
                grouped[key] = FallbackActivity(
                    title: title,
                    duration: 0,
                    firstSeenAt: context.capturedAt)
            }
        }

        let activities = grouped.values.sorted { lhs, rhs in
            if lhs.duration == rhs.duration { return lhs.firstSeenAt < rhs.firstSeenAt }
            return lhs.duration > rhs.duration
        }
        var existingKeys = Set(blocks.map { normalizedTaskKey($0.task) })
        for activity in activities {
            let key = normalizedTaskKey(activity.title)
            guard !existingKeys.contains(key) else { continue }
            existingKeys.insert(key)
            blocks.append(DayDigestGeneratedFocusBlock(
                task: activity.title,
                workDone: "Activity related to this item was recorded; no more specific outcome was visible.",
                status: "unknown",
                outcome: "",
                nextStep: "",
                sourceIDs: []))
            if blocks.count == limit { break }
        }
        return blocks
    }

    private static func fallbackMeetingSummary(
        _ meeting: DayDigestMeetingEvidence
    ) -> String {
        if let tldr = markdownSection(named: "TL;DR", in: meeting.sourceSummary) {
            let clean = cleanSummary(tldr, maxWords: FieldLimit.workDoneWords)
            if !clean.isEmpty { return clean }
        }
        let outcomes = cleanSummary(meeting.outcomes, maxWords: FieldLimit.workDoneWords)
        if !outcomes.isEmpty { return outcomes }
        return ""
    }

    private static func markdownSection(named name: String, in markdown: String) -> String? {
        guard let heading = markdown.range(
            of: "## \(name)",
            options: .caseInsensitive
        ) else { return nil }
        let remainder = markdown[heading.upperBound...]
        let end = remainder.range(of: "\n## ")?.lowerBound ?? remainder.endIndex
        return String(remainder[..<end])
    }

    private static func fallbackActivityTitle(_ raw: String, app: String) -> String? {
        var title = cleanInline(raw, maxCharacters: 120)
        let cleanApp = cleanInline(app, maxCharacters: 72)
        if !cleanApp.isEmpty,
           let suffix = title.range(
               of: " - \(cleanApp)",
               options: [.caseInsensitive, .backwards]
           ) {
            title = String(title[..<suffix.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let normalized = title.lowercased()
        let normalizedApp = cleanApp.lowercased()
        let genericTitles: Set<String> = [
            "", "home", "login", "login window", "loginwindow", "new tab", "timeline", "today",
            "unknown",
        ]
        guard !genericTitles.contains(normalized),
              normalizedApp != "loginwindow",
              normalized != normalizedApp else { return nil }
        return cleanInline(title, maxCharacters: FieldLimit.titleCharacters)
    }

    private static var focusSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "substantive": ["type": "boolean"],
                "task": ["type": "string"],
                "work_done": ["type": "string"],
                "status": [
                    "type": "string",
                    "enum": ["completed", "in_progress", "blocked", "unknown"],
                ],
                "outcome": ["type": "string"],
                "next_step": ["type": "string"],
                "source_ids": [
                    "type": "array",
                    "items": ["type": "integer"],
                    "maxItems": 2,
                ],
            ],
            "required": [
                "substantive", "task", "work_done", "status", "outcome",
                "next_step", "source_ids",
            ],
            "additionalProperties": false,
        ]
    }

    private static var digestSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "tasks": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "title": ["type": "string"],
                            "status": [
                                "type": "string",
                                "enum": [
                                    "completed", "in_progress", "blocked", "unknown",
                                ],
                            ],
                            "summary": ["type": "string"],
                            "next_step": ["type": "string"],
                            "block_indices": [
                                "type": "array",
                                "items": ["type": "integer"],
                                "minItems": 1,
                            ],
                        ],
                        "required": [
                            "title", "status", "summary", "next_step", "block_indices",
                        ],
                        "additionalProperties": false,
                    ],
                    "maxItems": 8,
                ],
                "decisions": [
                    "type": "array",
                    "items": ["type": "string"],
                    "maxItems": 4,
                ],
                "blockers": [
                    "type": "array",
                    "items": ["type": "string"],
                    "maxItems": 4,
                ],
            ],
            "required": ["tasks", "decisions", "blockers"],
            "additionalProperties": false,
        ]
    }

    private static func parseFocus(
        _ output: String,
        segment: DayDigestSummarySegment
    ) -> ParsedFocus? {
        guard let json = ChatPrompt.extractJSONObject(strippingReasoning(output)),
              let data = json.data(using: .utf8),
              let draft = try? JSONDecoder().decode(FocusDraft.self, from: data) else {
            return nil
        }
        let task = cleanInline(draft.task, maxCharacters: FieldLimit.titleCharacters)
        let workDone = cleanSummary(draft.workDone, maxWords: FieldLimit.workDoneWords)
        if task.isEmpty || workDone.isEmpty {
            return draft.substantive
                ? nil
                : ParsedFocus(block: nil, isSubstantive: false)
        }
        let allowed = Set(segment.sourceIDs)
        var sourceIDs: [Int64] = []
        for id in draft.sourceIDs where allowed.contains(id) && !sourceIDs.contains(id) {
            sourceIDs.append(id)
            if sourceIDs.count == 2 { break }
        }
        return ParsedFocus(
            block: DayDigestGeneratedFocusBlock(
                task: task,
                workDone: workDone,
                status: normalizedStatus(draft.status),
                outcome: cleanSummary(draft.outcome, maxWords: 32),
                nextStep: cleanSummary(draft.nextStep, maxWords: 28),
                sourceIDs: sourceIDs),
            isSubstantive: draft.substantive)
    }

    private static func parseDigest(_ output: String) -> DigestDraft? {
        guard let json = ChatPrompt.extractJSONObject(strippingReasoning(output)),
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(DigestDraft.self, from: data)
    }

    private static func render(
        blocks: [DayDigestGeneratedFocusBlock],
        draft: DigestDraft?
    ) -> String {
        let normalized = normalizedDigest(draft, blocks: blocks)
        guard !normalized.tasks.isEmpty else {
            return "### Tasks\n- **Recorded activity** — Activity was captured, but the available context did not identify a more specific item."
        }

        var sections = [
            "### Tasks\n" + normalized.tasks.map(renderedTask).joined(separator: "\n"),
        ]

        let followUps = uniqueFollowUps(
            tasks: normalized.tasks,
            decisions: normalized.decisions,
            blockers: normalized.blockers)
        if !followUps.isEmpty {
            sections.append(
                "### Decisions and next steps\n"
                    + followUps.map { "- \($0)" }.joined(separator: "\n"))
        }
        return sections.joined(separator: "\n\n")
    }

    private static func normalizedDigest(
        _ draft: DigestDraft?,
        blocks: [DayDigestGeneratedFocusBlock]
    ) -> (tasks: [NormalizedTask], decisions: [String], blockers: [String]) {
        let validIndices = Set(blocks.indices)
        var tasks: [NormalizedTask] = []
        var coveredIndices: Set<Int> = []

        for raw in draft?.tasks ?? [] {
            let indices = raw.blockIndices.filter(validIndices.contains)
                .reduce(into: [Int]()) { result, index in
                    if !result.contains(index) { result.append(index) }
                }
            let title = cleanInline(raw.title, maxCharacters: FieldLimit.titleCharacters)
            let summary = cleanSummary(raw.summary, maxWords: FieldLimit.summaryWords)
            guard !indices.isEmpty, !title.isEmpty, !summary.isEmpty else { continue }
            let key = normalizedTaskKey(title)
            guard !tasks.contains(where: { normalizedTaskKey($0.title) == key }) else { continue }
            tasks.append(NormalizedTask(
                title: title,
                status: normalizedStatus(raw.status),
                summary: summary,
                nextStep: cleanSummary(raw.nextStep, maxWords: 32),
                blockIndices: indices))
            coveredIndices.formUnion(indices)
        }

        for index in blocks.indices where !coveredIndices.contains(index) {
            mergeFallbackCandidate(blocks[index], index: index, into: &tasks)
        }

        let decisions = normalizedList(draft?.decisions ?? [], maxWords: 32)
        let blockers = normalizedList(draft?.blockers ?? [], maxWords: 32)
        return (tasks, decisions, blockers)
    }

    private static func candidateMaterial(
        _ block: DayDigestGeneratedFocusBlock,
        index: Int
    ) -> String {
        """
        - [candidate_index \(index)]
          Task: \(block.task)
          Work done: \(block.workDone)
          Status: \(block.status)
          Outcome: \(block.outcome.isEmpty ? "None supported" : block.outcome)
          Next step: \(block.nextStep.isEmpty ? "None supported" : block.nextStep)
        """
    }

    private static func mergeFallbackCandidate(
        _ block: DayDigestGeneratedFocusBlock,
        index: Int,
        into tasks: inout [NormalizedTask]
    ) {
        let key = normalizedTaskKey(block.task)
        if let taskIndex = tasks.firstIndex(where: { normalizedTaskKey($0.title) == key }) {
            if !tasks[taskIndex].summary.localizedCaseInsensitiveContains(block.workDone) {
                tasks[taskIndex].summary = cleanSummary(
                    tasks[taskIndex].summary + " " + candidateSummary(block),
                    maxWords: FieldLimit.summaryWords)
            }
            if block.status != "unknown" { tasks[taskIndex].status = block.status }
            if !block.nextStep.isEmpty { tasks[taskIndex].nextStep = block.nextStep }
            tasks[taskIndex].blockIndices.append(index)
            return
        }
        tasks.append(NormalizedTask(
            title: block.task,
            status: block.status,
            summary: candidateSummary(block),
            nextStep: block.nextStep,
            blockIndices: [index]))
    }

    private static func candidateSummary(_ block: DayDigestGeneratedFocusBlock) -> String {
        var summary = block.workDone
        if !block.outcome.isEmpty,
           !summary.localizedCaseInsensitiveContains(block.outcome) {
            summary += " Outcome: \(block.outcome)"
        }
        return cleanSummary(summary, maxWords: FieldLimit.summaryWords)
    }

    private static func renderedTask(_ task: NormalizedTask) -> String {
        "- **\(task.title)** — \(statusLead(task.status))\(task.summary)"
    }

    private static func uniqueFollowUps(
        tasks: [NormalizedTask],
        decisions: [String],
        blockers: [String]
    ) -> [String] {
        var accepted: [(content: String, rendered: String)] = []
        let taskContent = tasks.map { "\($0.title) \($0.summary)" }

        func append(content: String, rendered: String) {
            guard !taskContent.contains(where: {
                DayDigestTextSimilarity.isSimilar(content, $0)
            }), !accepted.contains(where: {
                DayDigestTextSimilarity.isSimilar(content, $0.content)
            }) else { return }
            accepted.append((content, rendered))
        }

        for decision in decisions {
            append(content: decision, rendered: "Decision: \(decision)")
        }
        for blocker in blockers {
            append(content: blocker, rendered: "Blocker: \(blocker)")
        }
        for task in tasks where !task.nextStep.isEmpty {
            append(
                content: task.nextStep,
                rendered: "Next — \(task.title): \(task.nextStep)")
        }
        return accepted.map { $0.rendered }
    }

    private static func statusLead(_ status: String) -> String {
        switch status {
        case "completed": return "Completed. "
        case "in_progress": return "In progress. "
        case "blocked": return "Blocked. "
        default: return ""
        }
    }

    private static func normalizedStatus(_ value: String) -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["completed", "in_progress", "blocked", "unknown"].contains(normalized)
            ? normalized : "unknown"
    }

    private static func normalizedTaskKey(_ value: String) -> String {
        cleanInline(value, maxCharacters: FieldLimit.titleCharacters).lowercased()
    }

    private static func normalizedList(_ values: [String], maxWords: Int) -> [String] {
        var result: [String] = []
        for raw in values {
            let clean = cleanBullet(raw, maxWords: maxWords)
            if !clean.isEmpty && !result.contains(clean) { result.append(clean) }
            if result.count == 4 { break }
        }
        return result
    }

    private static func cleanSummary(_ value: String, maxWords: Int) -> String {
        let withoutCitations = value.replacingOccurrences(
            of: #"\[screen:\d+\]"#,
            with: "",
            options: .regularExpression)
        return cleanBullet(withoutCitations, maxWords: maxWords)
    }

    private static func cleanBullet(_ value: String, maxWords: Int) -> String {
        var clean = cleanInline(value, maxCharacters: FieldLimit.bulletCharacters)
        while clean.hasPrefix("-") || clean.hasPrefix("•") {
            clean.removeFirst()
            clean = clean.trimmingCharacters(in: .whitespaces)
        }
        for prefix in ["The user ", "the user ", "User ", "user "] where clean.hasPrefix(prefix) {
            clean.removeFirst(prefix.count)
            if let first = clean.first {
                clean.replaceSubrange(clean.startIndex...clean.startIndex,
                                      with: String(first).uppercased())
            }
            break
        }
        let words = clean.split(whereSeparator: \Character.isWhitespace)
        guard words.count > maxWords else { return clean }
        return words.prefix(maxWords).joined(separator: " ") + "…"
    }

    private static func cleanInline(_ value: String, maxCharacters: Int) -> String {
        PromptContextSanitizer.sanitize(value, maxCharacters: maxCharacters)
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: "#*` "))
    }

    private static func time(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

struct DayDigestGenerationMetadata: Codable, Equatable, Sendable {
    static let currentVersion = 2

    var version: Int
    var quality: DayDigestGenerationQuality
    var generatedAt: Date
    var journalModifiedAt: Date
    var evidenceLatestAt: Date?
    var degradedAttemptCount: Int
    var evidenceSignature: String?
    var meetingEvidenceSignature: String?
    var journalDigest: String?
}

enum DayDigestGenerationMetadataStore {
    static let maximumDegradedAttempts = 3

    static func metadataURL(for journalURL: URL) -> URL {
        journalURL.deletingPathExtension().appendingPathExtension("meta.json")
    }

    static func load(for journalURL: URL) -> DayDigestGenerationMetadata? {
        let url = metadataURL(for: journalURL)
        guard let data = try? Data(contentsOf: url),
              let metadata = try? JSONDecoder().decode(
                DayDigestGenerationMetadata.self,
                from: data),
              (1...DayDigestGenerationMetadata.currentVersion).contains(metadata.version)
        else { return nil }
        return metadata
    }

    /// Records whether this journal still needs a model-backed repair. Repeated
    /// degraded writes for unchanged evidence increment a durable budget so a
    /// persistently crashing model cannot be relaunched forever.
    @discardableResult
    static func record(
        quality: DayDigestGenerationQuality,
        evidenceLatestAt: Date?,
        evidenceSignature: String? = nil,
        meetingEvidenceSignature: String? = nil,
        for journalURL: URL,
        generatedAt: Date = Date()
    ) throws -> DayDigestGenerationMetadata {
        let previous = load(for: journalURL)
        let sameEvidence = evidenceSignature.map { previous?.evidenceSignature == $0 }
            ?? (previous?.evidenceLatestAt == evidenceLatestAt)
        let degradedAttemptCount: Int
        if quality.needsRepair {
            let previousCount = previous?.quality.needsRepair == true && sameEvidence
                ? previous?.degradedAttemptCount ?? 0
                : 0
            degradedAttemptCount = min(
                maximumDegradedAttempts,
                previousCount + 1)
        } else {
            degradedAttemptCount = 0
        }
        let attributes = try FileManager.default.attributesOfItem(
            atPath: journalURL.path)
        let journalModifiedAt = attributes[.modificationDate] as? Date ?? generatedAt
        let metadata = DayDigestGenerationMetadata(
            version: DayDigestGenerationMetadata.currentVersion,
            quality: quality,
            generatedAt: generatedAt,
            journalModifiedAt: journalModifiedAt,
            evidenceLatestAt: evidenceLatestAt,
            degradedAttemptCount: degradedAttemptCount,
            evidenceSignature: evidenceSignature,
            meetingEvidenceSignature: meetingEvidenceSignature,
            journalDigest: ContentFingerprint.digest(try Data(contentsOf: journalURL)))
        let data = try JSONEncoder().encode(metadata)
        try data.write(to: metadataURL(for: journalURL), options: .atomic)
        return metadata
    }

    static func journalMatches(_ metadata: DayDigestGenerationMetadata, at url: URL) -> Bool {
        guard let digest = metadata.journalDigest,
              let data = try? Data(contentsOf: url) else { return false }
        return ContentFingerprint.digest(data) == digest
    }

    static func isCurrent(for journalURL: URL, evidenceSignature: String) -> Bool {
        guard let metadata = load(for: journalURL),
              metadata.evidenceSignature == evidenceSignature else { return false }
        return journalMatches(metadata, at: journalURL)
    }

    /// Legacy or externally edited journals keep their modification-time
    /// semantics. A matching degraded sidecar returns nil while a bounded quiet
    /// repair is still eligible, making the scheduler treat it as unfinished.
    static func completedAt(for journalURL: URL) -> Date? {
        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: journalURL.path),
              let modifiedAt = attributes[.modificationDate] as? Date
        else { return nil }
        guard let metadata = load(for: journalURL) else { return modifiedAt }
        let sidecarMatchesJournal = abs(
            metadata.journalModifiedAt.timeIntervalSince(modifiedAt)) < 0.5
        guard sidecarMatchesJournal else { return modifiedAt }
        if metadata.quality.needsRepair,
           metadata.degradedAttemptCount < maximumDegradedAttempts {
            return nil
        }
        return modifiedAt
    }
}

enum DayDigestFreshness {
    static func isStale(digestModifiedAt: Date?, latestEvidenceAt: Date?) -> Bool {
        guard let digestModifiedAt, let latestEvidenceAt else { return false }
        return latestEvidenceAt > digestModifiedAt
    }
}

struct DayDigestGenerationResult {
    var text: String
    var url: URL
    var quality: DayDigestGenerationQuality
}
