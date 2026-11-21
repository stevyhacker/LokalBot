import Foundation

struct DailyEvidenceMeeting: Equatable, Sendable {
    var meeting: Meeting
    var summary: String
    var projection: MeetingOutcomeProjection?
    var artifactModifiedAt: Date?

    var outcomes: MeetingOutcomes {
        projection?.outcomes ?? MeetingOutcomes()
    }

    var actionReferences: [OutcomeActionReference] {
        projection?.actionReferences ?? []
    }

    var activeActionReferences: [OutcomeActionReference] {
        actionReferences.filter { $0.status != .done }
    }

    var activeOutcomes: MeetingOutcomes {
        var result = outcomes
        result.actionItems = activeActionReferences.map(\.effectiveAction)
        return result
    }
}

struct DailyEvidenceSnapshot: Equatable, Sendable {
    struct Coverage: OptionSet, Equatable, Sendable {
        let rawValue: Int

        static let activityBlocks = Coverage(rawValue: 1 << 0)
        static let screenContexts = Coverage(rawValue: 1 << 1)
        static let screenSummary = Coverage(rawValue: 1 << 2)
        static let all: Coverage = [.activityBlocks, .screenContexts, .screenSummary]
    }

    var day: Date
    var interval: DateInterval
    var coverage: Coverage = .all
    var activityBlocks: [ActivityBlock]
    var screenContexts: [DayScreenContext]
    var screenEvidenceAt: Date?
    var meetings: [DailyEvidenceMeeting]
    var savedMoments: [ScreenMemorySavedMoment]
    var stats: ScreenMemoryDaySummary
    var appUsage: [ScreenMemoryAppUsage]
    var codingAgentBursts: [CodingAgentBurst] = []

    var latestEvidenceAt: Date? {
        var values: [Date] = activityBlocks.map(\.end)
        values += screenContexts.map(\.capturedAt)
        if let screenEvidenceAt { values.append(screenEvidenceAt) }
        values += meetings.compactMap { meeting -> Date? in
            [meeting.meeting.endedAt, meeting.artifactModifiedAt].compactMap { $0 }.max()
        }
        values += savedMoments.flatMap { [$0.capturedAt, $0.savedAt] }
        values += codingAgentBursts.map(\.end)
        return values.max()
    }

    var isEmpty: Bool {
        activityBlocks.isEmpty && screenContexts.isEmpty && meetings.isEmpty
            && savedMoments.isEmpty && stats.trackedSeconds <= 0 && codingAgentBursts.isEmpty
    }

    var signature: String {
        var fields = [
            String(interval.start.timeIntervalSinceReferenceDate),
            String(interval.end.timeIntervalSinceReferenceDate),
            String(coverage.rawValue),
            String(screenEvidenceAt?.timeIntervalSinceReferenceDate ?? 0),
        ]
        fields += activityBlocks.map {
            "block|\($0.id)|\($0.start.timeIntervalSinceReferenceDate)|"
                + "\($0.end.timeIntervalSinceReferenceDate)|\($0.app)|\($0.title)"
        }
        fields += screenContexts.map {
            "screen|\($0.snapshotID)|\($0.capturedAt.timeIntervalSinceReferenceDate)|"
                + "\($0.app)|\($0.windowTitle)|\($0.text)"
        }
        for item in meetings {
            fields.append(
                "meeting|\(item.meeting.id.uuidString)|"
                    + "\(item.meeting.startedAt.timeIntervalSinceReferenceDate)|"
                    + "\(item.meeting.endedAt?.timeIntervalSinceReferenceDate ?? 0)|"
                    + "\(item.meeting.title)|\(item.meeting.appName)|\(item.summary)")
            fields += item.actionReferences.map {
                let owner = $0.owner ?? ""
                let due = $0.due ?? ""
                return "action|\($0.id)|\($0.status.rawValue)|\($0.text)|"
                    + "\(owner)|\(due)|"
                    + "\($0.stateUpdatedAt.timeIntervalSinceReferenceDate)|\($0.isThreadExcluded)"
            }
            fields += item.outcomes.decisions.map { "decision|\($0)" }
            fields += item.outcomes.openQuestions.map { "question|\($0)" }
        }
        fields += savedMoments.map {
            "moment|\($0.snapshotID)|\($0.savedAt.timeIntervalSinceReferenceDate)|"
                + "\($0.app)|\($0.windowTitle)|\($0.captureTrigger)|"
                + "\($0.note)|\($0.ocrExcerpt)"
        }
        fields += appUsage.map {
            "usage|\($0.app)|\($0.durationSeconds)|\($0.blockCount)"
        }
        fields.append(
            "stats|\(stats.trackedSeconds)|\(stats.appCount)|"
                + "\(stats.activityBlockCount)|\(stats.screenshotCount)|"
                + "\(stats.savedMomentCount)")
        fields += codingAgentBursts.map { "agent|" + $0.signatureFields.joined(separator: "|") }
        return Self.fnv1a(fields.joined(separator: "\u{1f}"))
    }

    private static func fnv1a(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }
}

protocol DailyEvidenceSource {
    func snapshot(for day: Date) throws -> DailyEvidenceSnapshot
}

struct FileDailyEvidenceSource: DailyEvidenceSource {
    var root: URL
    var screenReader: any ScreenMemoryReading
    var calendar: Calendar

    init(
        root: URL = SessionLookup.storageRootURL,
        screenReader: (any ScreenMemoryReading)? = nil,
        calendar: Calendar = .current
    ) {
        self.root = root
        self.screenReader = screenReader ?? SQLiteScreenMemoryReader(
            databaseURL: root.appendingPathComponent("lokalbotv3.sqlite"))
        self.calendar = calendar
    }

    func snapshot(for day: Date) throws -> DailyEvidenceSnapshot {
        try snapshot(
            for: day,
            meetings: SessionLookup.loadAllMeetings(root: root),
            includeDetailedActivity: true)
    }

    func snapshot(
        for day: Date,
        meetings allMeetings: [Meeting],
        activityBlocks suppliedBlocks: [ActivityBlock]? = nil,
        screenContexts suppliedContexts: [DayScreenContext]? = nil,
        codingAgentBursts suppliedBursts: [CodingAgentBurst]? = nil,
        includeDetailedActivity: Bool = true,
        includeScreenSummary: Bool = true
    ) throws -> DailyEvidenceSnapshot {
        try Task.checkCancellation()
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start)
            ?? start.addingTimeInterval(86_400)
        let interval = DateInterval(start: start, end: end)
        let meetings = allMeetings
            .filter { !$0.isSample && interval.contains($0.startedAt) }
            .sorted { $0.startedAt < $1.startedAt }
            .map { meeting in
                let folder = root.appendingPathComponent(
                    meeting.relativePath,
                    isDirectory: true)
                let summary = (try? String(
                    contentsOf: folder.appendingPathComponent("summary.md"),
                    encoding: .utf8)) ?? ""
                return DailyEvidenceMeeting(
                    meeting: meeting,
                    summary: summary,
                    projection: MeetingOutcomeProjection.load(for: meeting, root: root),
                    artifactModifiedAt: DayDigestMeetingArtifacts.latestModifiedAt(in: folder))
            }

        let databaseURL = root.appendingPathComponent("lokalbotv3.sqlite")
        let blocks: [ActivityBlock]
        let contexts: [DayScreenContext]
        let moments: [ScreenMemorySavedMoment]
        let stats: ScreenMemoryDaySummary
        let usage: [ScreenMemoryAppUsage]
        let screenEvidenceAt: Date?
        let hasDatabase = FileManager.default.fileExists(atPath: databaseURL.path)
        var coverage: DailyEvidenceSnapshot.Coverage = []

        if let suppliedBlocks {
            blocks = suppliedBlocks
            coverage.insert(.activityBlocks)
        } else if includeDetailedActivity, hasDatabase {
            blocks = try screenReader.activityBlocks(
                from: interval.start,
                to: interval.end).map {
                    ActivityBlock(
                        id: $0.id,
                        app: $0.app,
                        title: $0.windowTitle,
                        start: $0.startedAt,
                        end: $0.endedAt)
                }
            coverage.insert(.activityBlocks)
        } else {
            blocks = []
            if includeDetailedActivity { coverage.insert(.activityBlocks) }
        }

        if let suppliedContexts {
            contexts = suppliedContexts
            coverage.insert(.screenContexts)
        } else if includeDetailedActivity, hasDatabase {
            contexts = try screenReader.screenContexts(
                from: interval.start,
                to: interval.end,
                maxCharactersPerCapture: 2_000).map {
                    DayScreenContext(
                        snapshotID: $0.snapshotID,
                        capturedAt: $0.capturedAt,
                        app: $0.app,
                        windowTitle: $0.windowTitle,
                        text: $0.text)
                }
            coverage.insert(.screenContexts)
        } else {
            contexts = []
            if includeDetailedActivity { coverage.insert(.screenContexts) }
        }

        let agentBursts: [CodingAgentBurst]
        if let suppliedBursts {
            agentBursts = suppliedBursts.filter { interval.contains($0.start) }
        } else if coverage.contains(.activityBlocks), hasDatabase {
            agentBursts = ActivityStore(databaseURL: databaseURL, readOnly: true)
                .codingAgentBursts(in: interval)
        } else {
            agentBursts = []
        }

        let detailedEvidenceAt = (blocks.map(\.end) + contexts.map(\.capturedAt)).max()
        if includeScreenSummary, hasDatabase {
            coverage.insert(.screenSummary)
            moments = try screenReader.savedMoments(
                from: interval.start,
                to: interval.end,
                limit: 500)
            stats = try screenReader.daySummary(from: interval.start, to: interval.end)
            usage = try screenReader.appUsage(
                from: interval.start,
                to: interval.end,
                limit: 100)
            let storedEvidenceAt = try screenReader.latestEvidenceAt(
                from: interval.start,
                to: interval.end)
            screenEvidenceAt = [storedEvidenceAt, detailedEvidenceAt]
                .compactMap { $0 }
                .max()
        } else {
            if includeScreenSummary { coverage.insert(.screenSummary) }
            moments = []
            stats = ScreenMemoryDaySummary(
                trackedSeconds: 0,
                appCount: 0,
                activityBlockCount: 0,
                screenshotCount: 0,
                savedMomentCount: 0)
            usage = []
            screenEvidenceAt = detailedEvidenceAt
        }

        try Task.checkCancellation()
        return DailyEvidenceSnapshot(
            day: start,
            interval: interval,
            coverage: coverage,
            activityBlocks: blocks,
            screenContexts: contexts,
            screenEvidenceAt: screenEvidenceAt,
            meetings: meetings,
            savedMoments: moments,
            stats: stats,
            appUsage: usage,
            codingAgentBursts: agentBursts)
    }
}

enum DailyEvidenceArtifacts {
    struct GeneratedDigest: Equatable {
        var text: String
        var isCurrent: Bool
    }

    static func currentDigest(
        for snapshot: DailyEvidenceSnapshot,
        root: URL,
        calendar: Calendar
    ) -> String? {
        generatedDigest(for: snapshot, root: root, calendar: calendar)
            .flatMap { $0.isCurrent ? $0.text : nil }
    }

    static func generatedDigest(
        for snapshot: DailyEvidenceSnapshot,
        root: URL,
        calendar: Calendar
    ) -> GeneratedDigest? {
        let dayKey = DreamDay.key(for: snapshot.day, calendar: calendar)
        let url = root.appendingPathComponent("journal/\(dayKey).md")
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let metadata = DayDigestGenerationMetadataStore.load(for: url),
              let signature = metadata.evidenceSignature,
              DayDigestGenerationMetadataStore.journalMatches(metadata, at: url)
        else { return nil }
        let detailed: DailyEvidenceSnapshot
        if snapshot.coverage.contains([.activityBlocks, .screenContexts]) {
            detailed = snapshot
        } else {
            guard let loaded = try? FileDailyEvidenceSource(root: root, calendar: calendar)
                .snapshot(for: snapshot.day, meetings: snapshot.meetings.map(\.meeting),
                          includeScreenSummary: false) else { return nil }
            detailed = loaded
        }
        return GeneratedDigest(
            text: text,
            isCurrent: detailed.digestEvidence(calendar: calendar).contentSignature == signature)
    }
}
