import Foundation

struct CaptureSetupDraft: Equatable, Codable {
    var meetingMode: AppSettings.AutoRecordMode {
        didSet { if meetingMode != .manual { detectedCallMode = meetingMode } }
    }
    var dayMemory: Bool
    var contextMode: AppSettings.ScreenContextCaptureMode
    var codingAgentSessions: Bool
    private(set) var detectedCallMode: AppSettings.AutoRecordMode

    init(settings: AppSettings) {
        meetingMode = settings.autoRecordMode
        dayMemory = settings.trackingEnabled
        contextMode = settings.effectiveScreenContextCaptureMode
        codingAgentSessions = settings.codingAgentEvidenceEnabled
        detectedCallMode = settings.autoRecordMode == .manual
            ? Self.defaultDetectedCallMode : settings.autoRecordMode
    }

    static let detectedCallModes: [AppSettings.AutoRecordMode] = [.automatic, .ask]

    static var defaultDetectedCallMode: AppSettings.AutoRecordMode {
        let fresh = AppSettings().autoRecordMode
        return fresh == .manual ? .ask : fresh
    }

    var recordsDetectedCalls: Bool {
        get { meetingMode != .manual }
        set { meetingMode = newValue ? detectedCallMode : .manual }
    }

    func applying(to settings: AppSettings) -> AppSettings {
        var result = settings
        result.autoRecordMode = meetingMode
        result.trackingEnabled = dayMemory
        result.screenContextCaptureMode = contextMode
        result.screenshotsEnabled = result.screenContextCaptureMode.capturesPixels
        result.codingAgentEvidenceEnabled = codingAgentSessions
        return result
    }
}
