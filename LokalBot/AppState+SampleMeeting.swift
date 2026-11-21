import Foundation

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

    func openSampleMeetingWhenReady() {
        guard sampleMeeting == nil, !modelRoles.snapshot.meetingReady else {
            sampleMeetingWaitsForModels = false
            importSampleMeeting()
            WindowAccess.shared.open("main")
            return
        }
        sampleMeetingWaitsForModels = true
    }

    func openWaitingSampleMeeting() {
        guard sampleMeetingWaitsForModels, modelRoles.snapshot.meetingReady else { return }
        sampleMeetingWaitsForModels = false
        importSampleMeeting()
    }

    func askSampleQuestion(_ meeting: Meeting) {
        openAsk(query: settings.appLanguage.localized(SampleMeeting.question),
                submit: true, meetingIDs: [meeting.id])
    }

    func removeSampleMeeting(_ meeting: Meeting) {
        guard meeting.isSample else { return }
        deleteMeetings([meeting.id])
    }
}
