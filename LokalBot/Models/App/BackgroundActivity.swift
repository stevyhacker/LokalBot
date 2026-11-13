import Foundation

/// Long-running work shown in the sidebar progress card. The owners of each
/// kind of work stay the source of truth; `derive` maps their published state
/// into one list ordered by `Kind`.
struct BackgroundActivity: Identifiable, Equatable {
    enum Kind: Int, Comparable {
        case meetingProcessing, dayDigest, dream, download, reindex

        static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }

        var systemImage: String {
            switch self {
            case .meetingProcessing: "waveform"
            case .dayDigest: "doc.text"
            case .dream: "moon.stars"
            case .download: "arrow.down.circle"
            case .reindex: "magnifyingglass"
            }
        }
    }

    enum Destination: Equatable {
        case meeting(UUID)
        case day(Date)
        case dream
        case models
    }

    let id: String
    let kind: Kind
    let title: String
    let detail: String
    /// 0...1 when the owner knows how far along the work is.
    let fraction: Double?
    /// Where tapping the activity navigates; nil when it has no screen.
    let destination: Destination?
}

/// Completed and total units of countable work.
struct BackgroundCount: Equatable, Sendable {
    var done: Int
    var total: Int
}

extension BackgroundActivity {
    struct MeetingWork: Equatable {
        var id: UUID
        var title: String
        var stage: ProcessingPipeline.Stage
    }

    struct DigestWork: Equatable {
        var id: UUID
        var day: Date
        var progress: DayDigestProgress?
    }

    struct DreamWork: Equatable {
        var day: Date
        var remainingDays: Int
    }

    struct DownloadWork: Equatable {
        var id: String
        var name: String
        var fraction: Double
    }

    struct Inputs: Equatable {
        var meetings: [MeetingWork] = []
        var digests: [DigestWork] = []
        var dream: DreamWork?
        var downloads: [DownloadWork] = []
        var reindex: BackgroundCount?
        var now: Date = Date()
        var calendar: Calendar = .current
        var locale: Locale = .current
    }

    static func derive(_ inputs: Inputs) -> [BackgroundActivity] {
        var result: [BackgroundActivity] = []

        let active = inputs.meetings.filter { $0.stage.isActiveWork }
        let queuedCount = inputs.meetings.filter { $0.stage == .queued }.count
        let queuedSuffix = queuedCount > 0 ? " · \(queuedCount) queued" : ""
        for meeting in active {
            result.append(BackgroundActivity(
                id: "meeting-\(meeting.id)",
                kind: .meetingProcessing,
                title: meeting.title,
                detail: (meeting.stage.shortLabel ?? "Processing") + queuedSuffix,
                fraction: nil,
                destination: .meeting(meeting.id)))
        }
        if active.isEmpty, queuedCount > 0 {
            result.append(BackgroundActivity(
                id: "meeting-queue",
                kind: .meetingProcessing,
                title: "Meeting processing",
                detail: queuedCount == 1 ? "1 meeting queued" : "\(queuedCount) meetings queued",
                fraction: nil,
                destination: nil))
        }

        for digest in inputs.digests {
            result.append(BackgroundActivity(
                id: "digest-\(digest.id)",
                kind: .dayDigest,
                title: "Day digest · \(dayLabel(digest.day, inputs))",
                detail: digestDetail(digest.progress),
                fraction: digest.progress?.fraction,
                destination: .day(inputs.calendar.startOfDay(for: digest.day))))
        }

        if let dream = inputs.dream {
            let remaining = dream.remainingDays
            result.append(BackgroundActivity(
                id: "dream",
                kind: .dream,
                title: "Overnight review · \(dayLabel(dream.day, inputs))",
                detail: remaining > 0
                    ? (remaining == 1 ? "1 more day queued" : "\(remaining) more days queued")
                    : "Reviewing the day",
                fraction: nil,
                destination: .dream))
        }

        for download in inputs.downloads.sorted(by: { $0.name < $1.name }) {
            let fraction = min(1, max(0, download.fraction))
            result.append(BackgroundActivity(
                id: "download-\(download.id)",
                kind: .download,
                title: "Downloading \(download.name)",
                detail: "\(Int((fraction * 100).rounded(.down)))%",
                fraction: fraction,
                destination: .models))
        }

        if let reindex = inputs.reindex, reindex.total > 0, reindex.done < reindex.total {
            result.append(BackgroundActivity(
                id: "reindex",
                kind: .reindex,
                title: "Updating meaning search",
                detail: "\(reindex.done) of \(reindex.total) meetings",
                fraction: Double(reindex.done) / Double(reindex.total),
                destination: nil))
        }

        // Stable: kinds in priority order, owners' order within a kind.
        return result.enumerated()
            .sorted { ($0.element.kind, $0.offset) < ($1.element.kind, $1.offset) }
            .map(\.element)
    }

    private static func digestDetail(_ progress: DayDigestProgress?) -> String {
        guard let progress, progress.totalSegments > 0 else { return "Preparing" }
        if progress.isAggregating { return "Combining tasks" }
        let current = min(progress.completedSegments + 1, progress.totalSegments)
        return "Part \(current) of \(progress.totalSegments)"
    }

    private static func dayLabel(_ day: Date, _ inputs: Inputs) -> String {
        let calendar = inputs.calendar
        if calendar.isDate(day, inSameDayAs: inputs.now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: inputs.now),
           calendar.isDate(day, inSameDayAs: yesterday) { return "Yesterday" }
        return day.formatted(
            Date.FormatStyle(locale: inputs.locale, calendar: calendar, timeZone: calendar.timeZone)
                .month(.abbreviated).day())
    }
}

extension ProcessingPipeline.Stage {
    /// Model work in progress, as opposed to parked, queued, or failed.
    var isActiveWork: Bool {
        switch self {
        case .preparingTranscriptionModel, .preparingDiarizationModel, .preparingSummaryModel,
             .transcribing, .diarizing, .summarizing: true
        case .queued, .waitingForModels, .failed: false
        }
    }

    /// Compact stage name for progress surfaces.
    var shortLabel: String? {
        switch self {
        case .preparingTranscriptionModel: "Preparing transcription model"
        case .preparingDiarizationModel: "Preparing speaker model"
        case .preparingSummaryModel: "Preparing Think model"
        case .transcribing: "Transcribing"
        case .diarizing: "Separating speakers"
        case .summarizing: "Writing notes"
        case .queued, .waitingForModels, .failed: nil
        }
    }
}
