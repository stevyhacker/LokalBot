import Foundation

struct MeetingDetectionContext: Equatable {
    enum Confidence: Int, Comparable {
        case low, medium, high
        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let detectedApp: MeetingDetector.DetectedApp?
    let calendarEvent: CalendarMeetingCandidate?
    let confidence: Confidence
    let reason: String
    var detectorSessionID: UUID?
}

struct MeetingDetectionEnd {
    enum Action: Equatable {
        case ignore
        case stop(allowsAutomaticRestart: Bool)
    }

    let sessionID: UUID
    let contentEndedAt: Date?
    var confident = true

    func ownsRecording(detectorSessionID: UUID?) -> Bool {
        detectorSessionID == sessionID
    }

    func action(detectorSessionID: UUID?, startedByUser _: Bool) -> Action {
        guard ownsRecording(detectorSessionID: detectorSessionID) else { return .ignore }
        if confident { return .stop(allowsAutomaticRestart: true) }
        return .ignore
    }
}

enum MeetingMatcher {
    static func browserCountsAsMeeting(titleMatchesMarker: Bool,
                                       hasOutputAudio: Bool,
                                       calendarBacked: Bool,
                                       requireCalendarForBrowser: Bool,
                                       verifiedSession: Bool = false) -> Bool {
        verifiedSession && (!requireCalendarForBrowser || calendarBacked)
    }

    static func sustainedAudioConfirmed(firstSeenAt: Date?,
                                        now: Date,
                                        minimumDuration: TimeInterval) -> Bool {
        guard let firstSeenAt, minimumDuration >= 0 else { return false }
        return now.timeIntervalSince(firstSeenAt) >= minimumDuration
    }

    struct StartConfirmationState {
        struct Window: Equatable {
            let bundleID: String
            let firstSeenAt: Date
            let lastAudioSeenAt: Date
            let generation: UInt64
        }

        private(set) var window: Window?
        private var generation: UInt64 = 0

        @discardableResult
        mutating func observeAudio(bundleID: String,
                                   at now: Date,
                                   gapTolerance: TimeInterval) -> Bool {
            if let window,
               window.bundleID == bundleID,
               now.timeIntervalSince(window.lastAudioSeenAt) <= gapTolerance {
                self.window = Window(
                    bundleID: bundleID,
                    firstSeenAt: window.firstSeenAt,
                    lastAudioSeenAt: now,
                    generation: window.generation)
                return false
            }

            generation &+= 1
            window = Window(
                bundleID: bundleID,
                firstSeenAt: now,
                lastAudioSeenAt: now,
                generation: generation)
            return true
        }

        mutating func clear() {
            window = nil
        }

        func acceptsRecheck(for generation: UInt64) -> Bool {
            window?.generation == generation
        }
    }

    enum StartConfirmationGapOutcome: Equatable {
        case abandoned
        case stillWaiting
    }

    static func startConfirmationGapOutcome(firstSeenAt _: Date,
                                            lastAudioSeenAt: Date,
                                            now: Date,
                                            gapTolerance: TimeInterval,
                                            minimumDuration _: TimeInterval) -> StartConfirmationGapOutcome {
        guard now.timeIntervalSince(lastAudioSeenAt) <= gapTolerance else { return .abandoned }
        return .stillWaiting
    }

    static func shouldKeepActiveSessionForPendingHandoff(
        confirmationWindow: StartConfirmationState.Window?,
        freshCandidateBundleID: String?,
        runningMeetingBundleIDs: Set<String>,
        now: Date,
        gapTolerance: TimeInterval
    ) -> Bool {
        guard let confirmationWindow,
              freshCandidateBundleID == nil
                || freshCandidateBundleID == confirmationWindow.bundleID,
              runningMeetingBundleIDs.contains(confirmationWindow.bundleID),
              gapTolerance.isFinite,
              gapTolerance >= 0 else { return false }
        let gap = now.timeIntervalSince(confirmationWindow.lastAudioSeenAt)
        return gap >= 0 && gap <= gapTolerance
    }

    static func confidence(hasApp: Bool, hasCalendar: Bool) -> MeetingDetectionContext.Confidence {
        switch (hasApp, hasCalendar) {
        case (true, true): return .high
        case (true, false): return .medium
        case (false, _): return .low
        }
    }

    static func shouldSuppressRepeat(eventID: String?,
                                     lastEventID: String?,
                                     lastEndedAt: Date?,
                                     now: Date,
                                     cooldown: TimeInterval) -> Bool {
        guard let eventID, let lastEventID, let lastEndedAt, eventID == lastEventID else { return false }
        return now.timeIntervalSince(lastEndedAt) < cooldown
    }

    static func shouldSplitForCalendarHandoff(activeEventID: String?,
                                              nextEventID: String?) -> Bool {
        guard let activeEventID, let nextEventID else { return false }
        return activeEventID != nextEventID
    }

    enum SwitchAction: Equatable { case split, start, ignore }

    static func switchAction(reason: String, ownsRecording: Bool, recordingActive: Bool) -> SwitchAction {
        if ownsRecording { return .split }
        return reason == "calendar-handoff" && !recordingActive ? .start : .ignore
    }

    static func recordingTitle(calendarTitle: String?, useCalendarTitles: Bool, appName: String?) -> String {
        if useCalendarTitles {
            let title = calendarTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !title.isEmpty { return title }
        }
        guard let appName, !appName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Manual recording"
        }
        return meetingTitle(for: appName)
    }

    static func meetingTitle(for appName: String) -> String {
        let trimmed = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Meeting" }
        return trimmed.localizedCaseInsensitiveContains("meeting")
            && trimmed.lowercased().hasSuffix("meeting")
            ? trimmed
            : "\(trimmed) meeting"
    }

    static func isMeetingOngoing(hasActiveSession: Bool,
                                 hasRunningMeetingApp: Bool,
                                 hasContinuingApp: Bool,
                                 startAudioActive: Bool,
                                 appAudioActive: Bool,
                                 calendarBackedBrowserWithAudio: Bool) -> Bool {
        let canStart = !hasActiveSession && hasRunningMeetingApp
            && (startAudioActive || calendarBackedBrowserWithAudio)
        let canContinue = hasActiveSession && (hasRunningMeetingApp || hasContinuingApp)
            && appAudioActive
        return canStart || canContinue
    }
}
