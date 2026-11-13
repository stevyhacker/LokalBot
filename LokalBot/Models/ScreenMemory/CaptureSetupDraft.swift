import Foundation

/// Welcome choices are staged. Back/Continue and reopening the wizard do not
/// change capture settings; applying updates only the fields this wizard owns.
struct CaptureSetupDraft: Equatable, Codable {
    var meetingMode: AppSettings.AutoRecordMode {
        didSet { if meetingMode != .manual { detectedCallMode = meetingMode } }
    }
    var dayMemory: Bool
    var contextMode: AppSettings.ScreenContextCaptureMode
    /// The master switch for reading Claude Code and Codex sessions. The
    /// per-agent switches and folder exclusions stay with Settings.
    var codingAgentSessions: Bool
    /// What a detected call does while Meeting notes is on. Setup's switch
    /// returns to it, so turning the switch off and on keeps the choice.
    private(set) var detectedCallMode: AppSettings.AutoRecordMode

    init(settings: AppSettings) {
        meetingMode = settings.autoRecordMode
        dayMemory = settings.trackingEnabled
        contextMode = settings.effectiveScreenContextCaptureMode
        codingAgentSessions = settings.codingAgentEvidenceEnabled
        detectedCallMode = settings.autoRecordMode == .manual
            ? Self.defaultDetectedCallMode : settings.autoRecordMode
    }

    /// The two ways a detected call can start a recording.
    static let detectedCallModes: [AppSettings.AutoRecordMode] = [.automatic, .ask]

    /// A new install's own choice; setup never picks a different one.
    static var defaultDetectedCallMode: AppSettings.AutoRecordMode {
        let fresh = AppSettings().autoRecordMode
        return fresh == .manual ? .ask : fresh
    }

    /// Setup's Meeting notes switch. Off records only on Record.
    var recordsDetectedCalls: Bool {
        get { meetingMode != .manual }
        set { meetingMode = newValue ? detectedCallMode : .manual }
    }

    func applying(to settings: AppSettings) -> AppSettings {
        var result = settings
        result.autoRecordMode = meetingMode
        result.trackingEnabled = dayMemory
        // The master switch gates capture independently. Turning memory off,
        // or reopening setup while it is off, must retain the selected detail
        // level for the next explicit enable action.
        result.screenContextCaptureMode = contextMode
        result.screenshotsEnabled = result.screenContextCaptureMode.capturesPixels
        result.codingAgentEvidenceEnabled = codingAgentSessions
        return result
    }
}
