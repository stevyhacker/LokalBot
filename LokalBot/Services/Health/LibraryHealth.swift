import Foundation

enum LibraryHealthStatus: String, Codable, Comparable, Sendable {
    case pass, warn, fail

    private var rank: Int {
        switch self {
        case .pass: 0
        case .warn: 1
        case .fail: 2
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
}

enum LibraryHealthCheck: String, Codable, CaseIterable, Sendable {
    case captureRate, privateShare, activityClock, finishedRecordings, schedulers, digestCoverage

    var title: String {
        switch self {
        case .captureRate: "Screen captures per app"
        case .privateShare: "Time recorded as Private"
        case .activityClock: "Tracked time versus the clock"
        case .finishedRecordings: "Finished recordings"
        case .schedulers: "Scheduled digests and dreams"
        case .digestCoverage: "Digest coverage"
        }
    }
}

struct LibraryHealthFinding: Codable, Equatable, Sendable {
    var check: LibraryHealthCheck
    var status: LibraryHealthStatus
    var summary: String
    var measurements: [String: Double] = [:]
}

struct LibraryHealthReport: Codable, Equatable, Sendable {
    var dayKey: String
    var generatedAt: Date
    var findings: [LibraryHealthFinding]

    var status: LibraryHealthStatus { findings.map(\.status).max() ?? .pass }

    func finding(_ check: LibraryHealthCheck) -> LibraryHealthFinding? {
        findings.first { $0.check == check }
    }
}

struct LibraryHealthInput: Sendable {
    struct Recording: Equatable, Sendable {
        var meetingID: UUID
        var title: String
        var missingTranscript: MissingTranscription.Reason?
        var hasQueuedJob: Bool
    }

    struct Schedulers: Equatable, Sendable {
        var automaticInferenceAllowed: Bool
        var digestEnabled: Bool
        var previousDay: DayDigestScheduler.PastDay?
        var dreamingEnabled: Bool
        var dreamingHour: Int
        var missingDreamDays: Int
    }

    var day: DateInterval
    var now: Date
    var blocks: [ActivityBlock]
    var screenCaptureEnabled: Bool
    var captureCountsByApp: [String: Int]
    var privateShareHistory: [Double]
    var recordings: [Recording]
    var automaticTranscription = true
    var schedulers: Schedulers
    var digestCoverage: DayDigestCoverage?
}

enum LibraryHealthEvaluator {
    static let privateApp = "Private"
    static let uncapturedApps: Set<String> = ["LokalBot", "LokalBot Dev", "LokalBot UI Test Host", "loginwindow"]
    static let minimumTrackedSecondsForCapture: TimeInterval = 30 * 60
    static let privateShareWarning = 0.15
    static let privateShareBaselineFloor = 0.10
    static let digestCoverageWarning = 0.60
    static let schedulerGrace: TimeInterval = 2 * 60 * 60
    static let clockTolerance: TimeInterval = 60

    static func evaluate(_ input: LibraryHealthInput, dayKey: String,
                         calendar: Calendar = .current) -> LibraryHealthReport {
        let blocks = clampedBlocks(input.blocks, to: input.day)
        return LibraryHealthReport(dayKey: dayKey, generatedAt: input.now, findings: [
            captureRate(input, blocks),
            privateShare(input, blocks),
            activityClock(input, blocks),
            finishedRecordings(input),
            schedulers(input, calendar: calendar),
            digestCoverage(input),
        ])
    }

    static func clampedBlocks(_ blocks: [ActivityBlock], to day: DateInterval) -> [ActivityBlock] {
        blocks.compactMap { block -> ActivityBlock? in
            let start = max(block.start, day.start)
            let end = min(block.end, day.end)
            guard end > start else { return nil }
            var clamped = block
            clamped.start = start
            clamped.end = end
            return clamped
        }
        .sorted { $0.start < $1.start }
    }

    private static func total(_ blocks: [ActivityBlock]) -> TimeInterval {
        blocks.reduce(0) { $0 + $1.duration }
    }

    private static func captureRate(_ input: LibraryHealthInput, _ blocks: [ActivityBlock]) -> LibraryHealthFinding {
        guard input.screenCaptureEnabled else {
            return .init(check: .captureRate, status: .pass, summary: "Screen capture is turned off.")
        }
        let seconds = blocks.reduce(into: [String: TimeInterval]()) { $0[$1.app, default: 0] += $1.duration }
        let silent = seconds
            .filter { $0.key != privateApp && !uncapturedApps.contains($0.key)
                && $0.value >= minimumTrackedSecondsForCapture }
            .filter { (input.captureCountsByApp[$0.key] ?? 0) == 0 }
            .keys.sorted()
        guard !silent.isEmpty else {
            return .init(check: .captureRate, status: .pass,
                         summary: "Every app with 30 or more minutes tracked has screen captures.")
        }
        return .init(check: .captureRate, status: .fail,
                     summary: "No screen captures for \(silent.joined(separator: ", ")) despite 30 or more minutes tracked.",
                     measurements: ["appsWithoutCaptures": Double(silent.count)])
    }

    private static func privateShare(_ input: LibraryHealthInput, _ blocks: [ActivityBlock]) -> LibraryHealthFinding {
        let tracked = total(blocks)
        guard tracked > 0 else {
            return .init(check: .privateShare, status: .pass, summary: "No tracked activity.")
        }
        let share = total(blocks.filter { $0.app == privateApp }) / tracked
        let baseline = median(input.privateShareHistory)
        let doubled = baseline > 0 && share >= 2 * baseline && share > privateShareBaselineFloor
        let status: LibraryHealthStatus = share > privateShareWarning || doubled ? .warn : .pass
        var summary = "\(Int((share * 100).rounded()))% of tracked time was recorded as Private"
        if doubled { summary += " (7-day median \(Int((baseline * 100).rounded()))%)" }
        return .init(check: .privateShare, status: status, summary: summary + ".",
                     measurements: ["privateShare": share, "baseline": baseline])
    }

    private static func activityClock(_ input: LibraryHealthInput, _ blocks: [ActivityBlock]) -> LibraryHealthFinding {
        var overlaps = 0
        var latestEnd: Date?
        for block in blocks {
            if let latestEnd, block.start < latestEnd.addingTimeInterval(-1) { overlaps += 1 }
            latestEnd = max(latestEnd ?? block.end, block.end)
        }
        let tracked = total(blocks)
        let elapsed = max(0, min(input.now, input.day.end).timeIntervalSince(input.day.start))
        let measurements = ["trackedHours": tracked / 3_600, "elapsedHours": elapsed / 3_600,
                            "overlaps": Double(overlaps)]
        if overlaps > 0 {
            return .init(check: .activityClock, status: .fail,
                         summary: "\(overlaps) activity blocks overlap another block.", measurements: measurements)
        }
        if tracked > elapsed + clockTolerance {
            return .init(check: .activityClock, status: .fail,
                         summary: String(format: "Tracked %.1f h exceeds the %.1f h that elapsed.",
                                         tracked / 3_600, elapsed / 3_600),
                         measurements: measurements)
        }
        return .init(check: .activityClock, status: .pass,
                     summary: String(format: "%.1f h tracked, no overlaps.", tracked / 3_600),
                     measurements: measurements)
    }

    private static func finishedRecordings(_ input: LibraryHealthInput) -> LibraryHealthFinding {
        guard input.automaticTranscription else {
            return .init(check: .finishedRecordings, status: .pass,
                         summary: "Automatic transcription is off; recordings are transcribed when you ask.")
        }
        let stuck = input.recordings.filter { $0.missingTranscript != nil && !$0.hasQueuedJob }
        guard !stuck.isEmpty else {
            return .init(check: .finishedRecordings, status: .pass,
                         summary: "Every finished recording has a transcript or a queued job.")
        }
        return .init(check: .finishedRecordings, status: .fail,
                     summary: "\(stuck.count) finished recordings have no transcript and no queued job: "
                        + stuck.map(\.title).joined(separator: ", ") + ".",
                     measurements: ["stuckRecordings": Double(stuck.count)])
    }

    private static func schedulers(_ input: LibraryHealthInput, calendar: Calendar) -> LibraryHealthFinding {
        let schedulers = input.schedulers
        let startOfToday = calendar.startOfDay(for: input.now)
        var status = LibraryHealthStatus.pass
        var problems: [String] = []
        if schedulers.digestEnabled, schedulers.automaticInferenceAllowed,
           let past = schedulers.previousDay,
           DayDigestScheduler.needsFinalization(past, calendar: calendar),
           input.now.timeIntervalSince(startOfToday) >= schedulerGrace {
            status = .fail
            problems.append("yesterday's digest was not finished after midnight")
        }
        if schedulers.dreamingEnabled, schedulers.automaticInferenceAllowed, schedulers.missingDreamDays > 0,
           let due = calendar.date(bySettingHour: min(23, max(0, schedulers.dreamingHour)),
                                   minute: 0, second: 0, of: input.now),
           input.now.timeIntervalSince(due) >= schedulerGrace {
            status = max(status, schedulers.missingDreamDays >= 2 ? .fail : .warn)
            problems.append("\(schedulers.missingDreamDays) eligible days were not dreamed")
        }
        let summary = problems.isEmpty
            ? "Scheduled digests and dreams ran when due."
            : "Scheduler problem: " + problems.joined(separator: "; ") + "."
        return .init(check: .schedulers, status: status, summary: summary,
                     measurements: ["missingDreamDays": Double(schedulers.missingDreamDays)])
    }

    private static func digestCoverage(_ input: LibraryHealthInput) -> LibraryHealthFinding {
        guard let coverage = input.digestCoverage, let ratio = coverage.ratio else {
            return .init(check: .digestCoverage, status: .pass, summary: "No digest coverage recorded for this day.")
        }
        let percent = Int((ratio * 100).rounded())
        return .init(check: .digestCoverage,
                     status: ratio < digestCoverageWarning ? .warn : .pass,
                     summary: "The digest covers \(percent)% of tracked activity.",
                     measurements: ["coverage": ratio, "trackedHours": coverage.trackedSeconds / 3_600])
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}
