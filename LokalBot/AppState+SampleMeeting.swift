import Foundation

/// "Try a sample meeting" (`SampleMeeting`): open the sample, or add it once
/// the models it needs are on this Mac.
extension AppState {
    var sampleMeeting: Meeting? { meetings.first(where: \.isSample) }

    func trySampleMeeting() {
        if let sample = sampleMeeting {
            openMeeting(sample.id)
        } else if modelRoles.snapshot.meetingReady {
            importSampleMeeting()
        } else {
            showsSampleSetup = true
        }
    }

    /// Asks the suggested question with the sample as the only source.
    func askSampleQuestion(_ meeting: Meeting) {
        openAsk(query: settings.appLanguage.localized(SampleMeeting.question),
                submit: true, meetingIDs: [meeting.id])
    }

    /// The sample can be added again at any time, so removing it doesn't ask first.
    func removeSampleMeeting(_ meeting: Meeting) {
        guard meeting.isSample else { return }
        deleteMeetings([meeting.id])
    }
}
