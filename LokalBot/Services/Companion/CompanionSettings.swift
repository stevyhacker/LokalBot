import Foundation

enum CompanionHistoryWindow: Int, Codable, CaseIterable, Identifiable, Sendable {
    case all = 0
    case days30 = 30
    case days90 = 90
    case days365 = 365

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .all: "All history"
        case .days30: "Last 30 days"
        case .days90: "Last 90 days"
        case .days365: "Last year"
        }
    }

    func startOfWindow(now: Date, calendar: Calendar = .current) -> Date? {
        guard self != .all else { return nil }
        let today = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: -(rawValue - 1), to: today) ?? today
    }

    func contains(_ date: Date, now: Date, calendar: Calendar = .current) -> Bool {
        guard let start = startOfWindow(now: now, calendar: calendar) else { return true }
        return date >= start
    }
}

struct CompanionSharing: Equatable, Sendable {
    static let defaultPort = 17890
    static let portRange = 1024...65535

    static func clampedPort(_ port: Int) -> Int {
        min(portRange.upperBound, max(portRange.lowerBound, port))
    }

    struct DataClasses: Equatable, Sendable, Codable {
        var meetings = true
        var transcripts = true
        var digests = true
        var timeline = true
        var windowTitles = true
        var people = true
        var projects = true

        var sharesTranscripts: Bool { meetings && transcripts }
        var sharesWindowTitles: Bool { timeline && windowTitles }

        var effective: Self {
            var result = self
            result.transcripts = sharesTranscripts
            result.windowTitles = sharesWindowTitles
            return result
        }

        static let all = DataClasses()
    }

    var enabled: Bool
    var dataClasses: DataClasses
    var history: CompanionHistoryWindow
    var answersQuestions: Bool
    var acceptsRecordings: Bool
    var port: Int
    var advertisesOnBonjour: Bool

    init(enabled: Bool = true, dataClasses: DataClasses = .all,
         history: CompanionHistoryWindow = .all, answersQuestions: Bool = true,
         acceptsRecordings: Bool = true, port: Int = defaultPort, advertisesOnBonjour: Bool = true) {
        self.enabled = enabled
        self.dataClasses = dataClasses
        self.history = history
        self.answersQuestions = answersQuestions
        self.acceptsRecordings = acceptsRecordings
        self.port = Self.clampedPort(port)
        self.advertisesOnBonjour = advertisesOnBonjour
    }

    init(settings: AppSettings) {
        self.init(
            enabled: settings.companionSharingEnabled,
            dataClasses: DataClasses(
                meetings: settings.companionShareMeetings,
                transcripts: settings.companionShareTranscripts,
                digests: settings.companionShareDigests,
                timeline: settings.companionShareTimeline,
                windowTitles: settings.companionShareWindowTitles,
                people: settings.companionSharePeople,
                projects: settings.companionShareProjects),
            history: settings.companionHistory,
            answersQuestions: settings.companionAnswersQuestions,
            acceptsRecordings: settings.companionAcceptsRecordings,
            port: settings.companionPort,
            advertisesOnBonjour: settings.companionAdvertisesOnBonjour)
    }

    var recordScope: RecordScope {
        RecordScope(dataClasses: dataClasses, history: history)
    }

    struct RecordScope: Equatable, Sendable {
        var dataClasses: DataClasses
        var history: CompanionHistoryWindow
    }
}

extension AppSettings {
    var companionSharing: CompanionSharing { CompanionSharing(settings: self) }
}
