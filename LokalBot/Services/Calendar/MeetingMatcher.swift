import Foundation

/// What the detector concluded about the current moment: the app/browser that
/// will be captured, the calendar event it lines up with (if any), how sure we
/// are, and why. Automatic detection always requires an app/audio signal; an
/// explicit user action may carry a calendar event and start mic-only.
struct MeetingDetectionContext: Equatable {
    enum Confidence: Int, Comparable {
        case low, medium, high
        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let detectedApp: MeetingDetector.DetectedApp?
    let calendarEvent: CalendarMeetingCandidate?
    let confidence: Confidence
    let reason: String
}

/// The matching layer between detection and recording. Pure policy — no
/// EventKit, AppKit, or Core Audio — so every rule here is unit-testable.
enum MeetingMatcher {
    /// Calendar, titles and output are supporting metadata, never proof of a
    /// call. The caller must verify the actual meeting document's in-call state.
    static func browserCountsAsMeeting(titleMatchesMarker: Bool,
                                       hasOutputAudio: Bool,
                                       calendarBacked: Bool,
                                       requireCalendarForBrowser: Bool,
                                       verifiedSession: Bool = false) -> Bool {
        verifiedSession && (!requireCalendarForBrowser || calendarBacked)
    }

    /// Whether a start candidate has produced audio for at least the required
    /// duration. The boundary is inclusive: exactly `minimumDuration` confirms
    /// the start, anything shorter does not. `firstSeenAt == nil` means no audio
    /// has been observed yet.
    static func sustainedAudioConfirmed(firstSeenAt: Date?,
                                        now: Date,
                                        minimumDuration: TimeInterval) -> Bool {
        guard let firstSeenAt, minimumDuration >= 0 else { return false }
        return now.timeIntervalSince(firstSeenAt) >= minimumDuration
    }

    /// The live state for one sustained-audio confirmation window. A generation
    /// identifies the exact window so a queued recheck cannot act on a newer
    /// candidate after the old window has been reset.
    struct StartConfirmationState {
        struct Window: Equatable {
            let bundleID: String
            let firstSeenAt: Date
            let lastAudioSeenAt: Date
            let generation: UInt64
        }

        private(set) var window: Window?
        private var generation: UInt64 = 0

        /// Records fresh audio and answers whether it began a new window. Audio
        /// after an expired gap is a new candidate even when the bundle id is
        /// unchanged; otherwise the abandoned window could confirm immediately.
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

    /// What a start candidate's silence means when it has no fresh audio
    /// evidence on this particular tick.
    ///
    /// Detection asks "is the app making sound right now", so a candidate mid
    /// confirmation loses that signal every time the remote side stops talking
    /// to listen — an ordinary conversational rhythm, not evidence the call
    /// ended. `abandoned` only once the *gap itself* has run past tolerance,
    /// not the instant evidence is briefly missing.
    enum StartConfirmationGapOutcome: Equatable {
        /// The gap has run too long; this candidate should be dropped.
        case abandoned
        /// Still within tolerance, but the window overall is not done yet.
        case stillWaiting
        /// The gap is within tolerance, and the total span already covers the
        /// window — confirmed despite the current instant being quiet, so a
        /// bridged gap doesn't delay the start past when a live tick would
        /// have.
        case confirmed
    }

    /// `firstSeenAt`/`lastAudioSeenAt` describe one candidate's whole history:
    /// when its audio was first observed, and when it was last observed. Pure,
    /// so the boundary cases don't need a live app or Core Audio to test.
    static func startConfirmationGapOutcome(firstSeenAt: Date,
                                            lastAudioSeenAt: Date,
                                            now: Date,
                                            gapTolerance: TimeInterval,
                                            minimumDuration: TimeInterval) -> StartConfirmationGapOutcome {
        guard now.timeIntervalSince(lastAudioSeenAt) <= gapTolerance else { return .abandoned }
        if sustainedAudioConfirmed(firstSeenAt: firstSeenAt, now: now, minimumDuration: minimumDuration) {
            return .confirmed
        }
        return .stillWaiting
    }

    static func confidence(hasApp: Bool, hasCalendar: Bool) -> MeetingDetectionContext.Confidence {
        switch (hasApp, hasCalendar) {
        case (true, true): return .high
        case (true, false): return .medium
        case (false, _): return .low
        }
    }

    /// Suppress an auto-start that would re-record the same calendar event right
    /// after one for it ended — debounced browser-helper PID churn, brief audio
    /// drops, a detector tick racing a manual stop. A genuinely new occurrence
    /// has a different `externalID`, so it is never blocked.
    static func shouldSuppressRepeat(eventID: String?,
                                     lastEventID: String?,
                                     lastEndedAt: Date?,
                                     now: Date,
                                     cooldown: TimeInterval) -> Bool {
        guard let eventID, let lastEventID, let lastEndedAt, eventID == lastEventID else { return false }
        return now.timeIntervalSince(lastEndedAt) < cooldown
    }

    /// A live recording backed by one calendar event should split immediately
    /// when the active calendar event changes. This prevents back-to-back
    /// meetings from being merged during the stop debounce.
    static func shouldSplitForCalendarHandoff(activeEventID: String?,
                                              nextEventID: String?) -> Bool {
        guard let activeEventID, let nextEventID else { return false }
        return activeEventID != nextEventID
    }

    /// The recording title: the calendar event's title when titling is on and it
    /// has one, else the app-derived "<App> meeting", else "Manual recording".
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

    /// "<App> meeting", without doubling a trailing "meeting" in the app name.
    static func meetingTitle(for appName: String) -> String {
        let trimmed = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Meeting" }
        return trimmed.localizedCaseInsensitiveContains("meeting")
            && trimmed.lowercased().hasSuffix("meeting")
            ? trimmed
            : "\(trimmed) meeting"
    }

    /// Whether the detector should treat a meeting as in progress this tick.
    ///
    /// `appAudioActive` is the *meeting app's own* audio I/O (input or output).
    /// It deliberately replaces the global "mic in use" flag: once we start
    /// recording, our own mic capture keeps the default input device "running
    /// somewhere", and before recording a global mic check can belong to a
    /// different app entirely. Start and continue both key off the selected app's
    /// own audio signal; calendar-backed browsers may also start from output
    /// audio found in their helper process.
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
