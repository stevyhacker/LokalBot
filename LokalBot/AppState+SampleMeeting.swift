import Foundation

extension AppState {
    var sampleMeeting: Meeting? { meetings.first(where: \.isSample) }

    func trySampleMeeting() {
        if let sample = sampleMeeting {
            openMeeting(sample.id)
        } else {
            importSampleMeeting()
        }
    }

    func openSampleMeetingWhenReady() {
        sampleMeetingWaitsForModels = false
        importSampleMeeting()
        WindowAccess.shared.open("main")
    }

    func openWaitingSampleMeeting() {
        guard sampleMeetingWaitsForModels, modelRoles.snapshot.meetingReady else { return }
        sampleMeetingWaitsForModels = false
        importSampleMeeting()
    }

    func askSampleQuestion(_ meeting: Meeting) {
        let query = SampleMeeting.askQuestion(for: meeting, language: settings.appLanguage)
        openAsk(query: query, submit: true, meetingIDs: [meeting.id])
    }

    func precomputedSampleAnswer(query: String, meetingIDs: Set<UUID>?) -> ChatViewModel.PrecomputedAnswer? {
        guard !modelRoles.snapshot[.think].isReady, let sample = sampleMeeting else { return nil }
        let targetsSample: Bool
        if let meetingIDs {
            targetsSample = meetingIDs == [sample.id]
        } else {
            targetsSample = meetings.allSatisfy(\.isSample)
        }
        guard targetsSample,
              let answer = SampleMeeting.precomputedAskAnswer(for: sample, question: query) else {
            return nil
        }
        return ChatViewModel.PrecomputedAnswer(answer: answer, meetingTitle: sample.displayTitle)
    }

    func rerunSampleMeetingWithLocalModel(_ meeting: Meeting) {
        guard meeting.isSample else { return }
        if modelRoles.snapshot.meetingReady {
            reprocess(meeting, transcribe: true, summarize: true)
        } else {
            showsSampleSetup = true
        }
    }

    func removeSampleMeeting(_ meeting: Meeting) {
        guard meeting.isSample else { return }
        deleteMeetings([meeting.id])
    }
}
