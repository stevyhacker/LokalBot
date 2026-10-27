import Foundation

/// Welcome choices are staged. Back/Continue and reopening the wizard do not
/// change capture settings; applying updates only the fields this wizard owns.
struct CaptureSetupDraft: Equatable {
    var meetingMode: AppSettings.AutoRecordMode
    var dayMemory: Bool
    var contextMode: AppSettings.ScreenContextCaptureMode
    /// The master switch for reading Claude Code and Codex sessions. The
    /// per-agent switches and folder exclusions stay with Settings.
    var codingAgentSessions: Bool

    init(settings: AppSettings) {
        meetingMode = settings.autoRecordMode
        dayMemory = settings.trackingEnabled
        contextMode = settings.effectiveScreenContextCaptureMode
        codingAgentSessions = settings.codingAgentEvidenceEnabled
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
