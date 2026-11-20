import CoreAudio
import XCTest
@testable import LokalBot

final class CalendarDetectionTests: XCTestCase {

    func testCalendarCapabilityIsConfiguredForGeneratedBuilds() throws {
        let entitlementKey = "com.apple.security.personal-information.calendars"
        let entitlementsURL = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "LokalBot", withExtension: "entitlements"))
        let data = try Data(contentsOf: entitlementsURL)
        let properties = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any])
        XCTAssertEqual(properties[entitlementKey] as? Bool, true)
    }

    func testDetectsGoogleMeetLink() {
        let url = ConferenceURLDetector.firstMeetingURL(in: "Join here: https://meet.google.com/abc-defg-hij")
        XCTAssertEqual(url?.host, "meet.google.com")
        XCTAssertTrue(ConferenceURLDetector.isMeetingURL(url))
    }

    func testDetectsTelemostAndMTSLinkCalendarRooms() {
        XCTAssertEqual(ConferenceURLDetector.firstMeetingURL(in: "https://telemost.yandex.ru/j/12345678901")?.host,
                       "telemost.yandex.ru")
        XCTAssertEqual(ConferenceURLDetector.firstMeetingURL(in: "https://my.mts-link.ru/j/1234/5678/")?.host,
                       "my.mts-link.ru")
        XCTAssertNil(ConferenceURLDetector.firstMeetingURL(in: "https://my.mts-link.ru/chats/auth"))
        XCTAssertNil(ConferenceURLDetector.firstMeetingURL(in: "https://telemost.yandex.ru/"))
    }

    func testDetectsZoomSubdomain() {
        let url = URL(string: "https://us02web.zoom.us/j/123456789")
        XCTAssertTrue(ConferenceURLDetector.isMeetingURL(url))
    }

    func testDetectsTeamsAndWebex() {
        XCTAssertTrue(ConferenceURLDetector.isMeetingURL(URL(string: "https://teams.microsoft.com/l/meetup-join/x")))
        XCTAssertTrue(ConferenceURLDetector.isMeetingURL(URL(string: "https://acme.webex.com/meet/jane")))
    }

    func testDetectsChineseMeetingLinks() {
        for link in ["https://meeting.tencent.com/dm/AbCdEf12", "https://voovmeeting.com/dm/AbCdEf12",
                     "https://vc.feishu.cn/j/123456789", "https://vc.larksuite.com/j/123456789",
                     "https://meeting.dingtalk.com/j/AbCdEf12"] {
            XCTAssertTrue(ConferenceURLDetector.isMeetingURL(URL(string: link)), link)
        }
        let invite = "腾讯会议：https://meeting.tencent.com/dm/AbCdEf12 会议号：123 456 789"
        XCTAssertEqual(ConferenceURLDetector.firstMeetingURL(in: invite)?.host, "meeting.tencent.com")
        XCTAssertFalse(ConferenceURLDetector.isMeetingURL(URL(string: "https://www.feishu.cn/docx/AbC")))
        XCTAssertFalse(ConferenceURLDetector.isMeetingURL(URL(string: "https://www.dingtalk.com/download")))
    }

    func testIgnoresNonMeetingURL() {
        XCTAssertNil(ConferenceURLDetector.firstMeetingURL(in: "Agenda at https://docs.example.com/agenda"))
        XCTAssertFalse(ConferenceURLDetector.isMeetingURL(URL(string: "https://example.com/zoom.us-lookalike")))
    }

    func testNoURLInPlainOrEmptyText() {
        XCTAssertNil(ConferenceURLDetector.firstMeetingURL(in: nil))
        XCTAssertNil(ConferenceURLDetector.firstMeetingURL(in: ""))
        XCTAssertNil(ConferenceURLDetector.firstMeetingURL(in: "No links here, just a note."))
    }

    private func raw(title: String? = "Sprint Planning",
                     allDay: Bool = false,
                     canceled: Bool = false,
                     declined: Bool = false,
                     free: Bool = false,
                     unavailable: Bool = false,
                     attendees: Bool = true,
                     meetingURL: Bool = true) -> RawCalendarEvent {
        RawCalendarEvent(title: title, isAllDay: allDay, isCanceled: canceled,
                         isDeclinedByMe: declined, availabilityFree: free,
                         availabilityUnavailable: unavailable, hasAttendees: attendees,
                         hasMeetingURL: meetingURL)
    }

    func testRecordableMeetingPasses() {
        XCTAssertTrue(CalendarEventFilter.isRecordableMeeting(raw()))
    }

    func testRejectsAllDayCanceledDeclinedEmptyOOO() {
        XCTAssertFalse(CalendarEventFilter.isRecordableMeeting(raw(allDay: true)), "all-day")
        XCTAssertFalse(CalendarEventFilter.isRecordableMeeting(raw(canceled: true)), "canceled")
        XCTAssertFalse(CalendarEventFilter.isRecordableMeeting(raw(declined: true)), "declined")
        XCTAssertFalse(CalendarEventFilter.isRecordableMeeting(raw(title: "   ")), "blank title")
        XCTAssertFalse(CalendarEventFilter.isRecordableMeeting(raw(title: nil)), "nil title")
        XCTAssertFalse(CalendarEventFilter.isRecordableMeeting(raw(unavailable: true)), "out of office")
    }

    func testRejectsSoloFocusBlock() {
        XCTAssertFalse(CalendarEventFilter.isRecordableMeeting(
            raw(free: true, attendees: false, meetingURL: false)))
    }

    func testFreeTimeStillRecordableWithAttendeesOrLink() {
        XCTAssertTrue(CalendarEventFilter.isRecordableMeeting(raw(free: true, attendees: true, meetingURL: false)))
        XCTAssertTrue(CalendarEventFilter.isRecordableMeeting(raw(free: true, attendees: false, meetingURL: true)))
    }

    private func candidate(id: String = "evt",
                           start: TimeInterval, end: TimeInterval,
                           url: String? = "https://meet.google.com/abc") -> CalendarMeetingCandidate {
        CalendarMeetingCandidate(
            provider: "test", externalID: id, title: "Meeting",
            startDate: Date(timeIntervalSince1970: start),
            endDate: Date(timeIntervalSince1970: end),
            meetingURL: url.flatMap(URL.init(string:)), sourceCalendarTitle: "Work")
    }

    func testIsActiveWindow() {
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertTrue(candidate(start: 9_700, end: 10_600).isActive(at: now))
        XCTAssertTrue(candidate(start: 10_030, end: 10_900).isActive(at: now))
        XCTAssertFalse(candidate(start: 10_120, end: 11_000).isActive(at: now))
        XCTAssertFalse(candidate(start: 10_600, end: 11_000).isActive(at: now))
        XCTAssertFalse(candidate(start: 9_000, end: 9_900).isActive(at: now))
    }

    func testActiveCandidatePrefersInProgress() {
        let now = Date(timeIntervalSince1970: 10_000)
        let upcoming = candidate(id: "soon", start: 10_030, end: 10_800)
        let live = candidate(id: "live", start: 9_800, end: 10_500)
        let result = [upcoming, live].activeCandidate(at: now)
        XCTAssertEqual(result?.externalID, "live")
    }

    func testActiveCandidateNilWhenNoneActive() {
        let now = Date(timeIntervalSince1970: 10_000)
        let past = candidate(id: "past", start: 8_000, end: 9_000)
        let future = candidate(id: "future", start: 12_000, end: 13_000)
        XCTAssertNil([past, future].activeCandidate(at: now))
    }

    func testTitleMatchAloneDoesNotRecord() {
        XCTAssertFalse(MeetingMatcher.browserCountsAsMeeting(
            titleMatchesMarker: true, hasOutputAudio: false,
            calendarBacked: false, requireCalendarForBrowser: false))
    }

    func testNoTitleNoCalendarDoesNotRecord() {
        XCTAssertFalse(MeetingMatcher.browserCountsAsMeeting(
            titleMatchesMarker: false, hasOutputAudio: true,
            calendarBacked: false, requireCalendarForBrowser: false))
    }

    func testCalendarBackedBrowserAudioDoesNotRecord() {
        XCTAssertFalse(MeetingMatcher.browserCountsAsMeeting(
            titleMatchesMarker: false, hasOutputAudio: true,
            calendarBacked: true, requireCalendarForBrowser: false))
    }

    func testCalendarWithoutAudioDoesNotRecord() {
        XCTAssertFalse(MeetingMatcher.browserCountsAsMeeting(
            titleMatchesMarker: false, hasOutputAudio: false,
            calendarBacked: true, requireCalendarForBrowser: false))
    }

    func testStrictModeRequiresCalendar() {
        XCTAssertFalse(MeetingMatcher.browserCountsAsMeeting(
            titleMatchesMarker: true, hasOutputAudio: true,
            calendarBacked: false, requireCalendarForBrowser: true))
        XCTAssertTrue(MeetingMatcher.browserCountsAsMeeting(
            titleMatchesMarker: false, hasOutputAudio: true,
            calendarBacked: true, requireCalendarForBrowser: true, verifiedSession: true))
    }

    func testSuppressesSameEventWithinCooldown() {
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertTrue(MeetingMatcher.shouldSuppressRepeat(
            eventID: "evt#1", lastEventID: "evt#1",
            lastEndedAt: Date(timeIntervalSince1970: 9_900), now: now, cooldown: 300))
    }

    func testAllowsSameEventAfterCooldown() {
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertFalse(MeetingMatcher.shouldSuppressRepeat(
            eventID: "evt#1", lastEventID: "evt#1",
            lastEndedAt: Date(timeIntervalSince1970: 9_600), now: now, cooldown: 300))
    }

    func testAllowsDifferentEventAndFirstRecording() {
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertFalse(MeetingMatcher.shouldSuppressRepeat(
            eventID: "evt#2", lastEventID: "evt#1",
            lastEndedAt: Date(timeIntervalSince1970: 9_990), now: now, cooldown: 300), "different event")
        XCTAssertFalse(MeetingMatcher.shouldSuppressRepeat(
            eventID: "evt#1", lastEventID: nil, lastEndedAt: nil, now: now, cooldown: 300), "no prior recording")
    }

    func testSplitsWhenActiveCalendarEventChanges() {
        XCTAssertTrue(MeetingMatcher.shouldSplitForCalendarHandoff(
            activeEventID: "evt#standup",
            nextEventID: "evt#planning"))
    }

    func testDoesNotSplitForSameOrMissingCalendarEvent() {
        XCTAssertFalse(MeetingMatcher.shouldSplitForCalendarHandoff(
            activeEventID: "evt#standup",
            nextEventID: "evt#standup"))
        XCTAssertFalse(MeetingMatcher.shouldSplitForCalendarHandoff(
            activeEventID: nil,
            nextEventID: "evt#planning"))
        XCTAssertFalse(MeetingMatcher.shouldSplitForCalendarHandoff(
            activeEventID: "evt#standup",
            nextEventID: nil))
    }

    func testNextCalendarEventRecordsAfterTheUserStoppedThePreviousOne() {
        XCTAssertEqual(MeetingMatcher.switchAction(
            reason: "calendar-handoff", ownsRecording: true, recordingActive: true), .split)
        XCTAssertEqual(MeetingMatcher.switchAction(
            reason: "calendar-handoff", ownsRecording: false, recordingActive: false), .start)
        XCTAssertEqual(MeetingMatcher.switchAction(
            reason: "calendar-handoff", ownsRecording: false, recordingActive: true), .ignore,
            "a recording the session does not own is left alone")
        XCTAssertEqual(MeetingMatcher.switchAction(
            reason: "meeting-app-handoff", ownsRecording: false, recordingActive: false), .ignore)
    }

    func testRecordingTitlePrefersCalendar() {
        XCTAssertEqual(MeetingMatcher.recordingTitle(
            calendarTitle: "Weekly Sync", useCalendarTitles: true, appName: "Google Chrome"), "Weekly Sync")
    }

    func testRecordingTitleFallsBackWhenTitlesOff() {
        XCTAssertEqual(MeetingMatcher.recordingTitle(
            calendarTitle: "Weekly Sync", useCalendarTitles: false, appName: "Google Chrome"), "Google Chrome meeting")
    }

    func testRecordingTitleFallsBackWhenNoCalendarTitle() {
        XCTAssertEqual(MeetingMatcher.recordingTitle(
            calendarTitle: "  ", useCalendarTitles: true, appName: "Zoom"), "Zoom meeting")
        XCTAssertEqual(MeetingMatcher.recordingTitle(
            calendarTitle: nil, useCalendarTitles: true, appName: nil), "Manual recording")
    }

    func testConfidence() {
        XCTAssertEqual(MeetingMatcher.confidence(hasApp: true, hasCalendar: true), .high)
        XCTAssertEqual(MeetingMatcher.confidence(hasApp: true, hasCalendar: false), .medium)
        XCTAssertEqual(MeetingMatcher.confidence(hasApp: false, hasCalendar: true), .low)
    }

    func testRecordingMicDoesNotKeepMeetingAliveWhenAppAudioStops() {
        XCTAssertFalse(MeetingMatcher.isMeetingOngoing(
            hasActiveSession: true, hasRunningMeetingApp: true, hasContinuingApp: true,
            startAudioActive: true, appAudioActive: false, calendarBackedBrowserWithAudio: false),
            "global mic (our own recorder) must not keep an otherwise-silent meeting open")
    }

    func testContinuesWhileAppAudioActive() {
        XCTAssertTrue(MeetingMatcher.isMeetingOngoing(
            hasActiveSession: true, hasRunningMeetingApp: true, hasContinuingApp: true,
            startAudioActive: false, appAudioActive: true, calendarBackedBrowserWithAudio: false))
    }

    func testEndsWhenAppGoneRegardlessOfMic() {
        XCTAssertFalse(MeetingMatcher.isMeetingOngoing(
            hasActiveSession: true, hasRunningMeetingApp: false, hasContinuingApp: false,
            startAudioActive: true, appAudioActive: true, calendarBackedBrowserWithAudio: false))
    }

    func testStartsOnMeetingAppOwnAudio() {
        XCTAssertTrue(MeetingMatcher.isMeetingOngoing(
            hasActiveSession: false, hasRunningMeetingApp: true, hasContinuingApp: false,
            startAudioActive: true, appAudioActive: false, calendarBackedBrowserWithAudio: false))
    }

    func testDoesNotStartOnIdleMeetingAppWithOnlyGlobalMicSignal() {
        XCTAssertFalse(MeetingMatcher.isMeetingOngoing(
            hasActiveSession: false, hasRunningMeetingApp: true, hasContinuingApp: false,
            startAudioActive: false, appAudioActive: false, calendarBackedBrowserWithAudio: false))
    }

    func testAudioMonitorAutoRecordsDedicatedNativeAppsWithoutCalendar() {
        XCTAssertTrue(MeetingDetector.shouldAutoRecordNativeAudioMonitor(
            bundleID: "us.zoom.xos", calendarBacked: false))
    }

    func testTeamsLaunchBlipDoesNotConfirmBeforeMinimumDuration() {
        XCTAssertTrue(MeetingDetector.requiresSustainedAudioForStart(
            bundleID: "com.microsoft.teams2", calendarBacked: false))
        let firstSeen = Date()
        XCTAssertFalse(MeetingMatcher.sustainedAudioConfirmed(
            firstSeenAt: firstSeen,
            now: firstSeen.addingTimeInterval(10.8),
            minimumDuration: MeetingDetector.nativeAudioMinimumConfirmationDuration))
        XCTAssertTrue(MeetingMatcher.sustainedAudioConfirmed(
            firstSeenAt: firstSeen,
            now: firstSeen.addingTimeInterval(
                MeetingDetector.nativeAudioMinimumConfirmationDuration),
            minimumDuration: MeetingDetector.nativeAudioMinimumConfirmationDuration))
    }

    func testSustainedAudioIsNotRequiredForDedicatedOrCalendarBackedStarts() {
        XCTAssertFalse(MeetingDetector.requiresSustainedAudioForStart(
            bundleID: "us.zoom.xos", calendarBacked: false))
        XCTAssertFalse(MeetingDetector.requiresSustainedAudioForStart(
            bundleID: "com.microsoft.teams2", calendarBacked: true))
        XCTAssertFalse(MeetingDetector.requiresSustainedAudioForStart(
            bundleID: "com.google.Chrome", calendarBacked: false))
    }

    func testABriefPauseInTheRemoteSideDoesNotAbandonTheWindow() {
        let firstSeen = Date()
        let lastAudioSeenAt = firstSeen.addingTimeInterval(3)
        let now = lastAudioSeenAt.addingTimeInterval(4)

        XCTAssertEqual(
            MeetingMatcher.startConfirmationGapOutcome(
                firstSeenAt: firstSeen, lastAudioSeenAt: lastAudioSeenAt, now: now,
                gapTolerance: MeetingDetector.nativeAudioConfirmationGapTolerance,
                minimumDuration: MeetingDetector.nativeAudioMinimumConfirmationDuration),
            .stillWaiting)
    }

    func testSilenceLongerThanTheGapToleranceAbandonsTheCandidate() {
        let firstSeen = Date()
        let lastAudioSeenAt = firstSeen.addingTimeInterval(1)
        let now = lastAudioSeenAt.addingTimeInterval(
            MeetingDetector.nativeAudioConfirmationGapTolerance + 0.1)

        XCTAssertEqual(
            MeetingMatcher.startConfirmationGapOutcome(
                firstSeenAt: firstSeen, lastAudioSeenAt: lastAudioSeenAt, now: now,
                gapTolerance: MeetingDetector.nativeAudioConfirmationGapTolerance,
                minimumDuration: MeetingDetector.nativeAudioMinimumConfirmationDuration),
            .abandoned)
    }

    func testATotalSpanPastTheWindowWaitsForFreshAudio() {
        let firstSeen = Date()
        let lastAudioSeenAt = firstSeen.addingTimeInterval(11)
        let now = firstSeen.addingTimeInterval(
            MeetingDetector.nativeAudioMinimumConfirmationDuration + 0.3)

        XCTAssertEqual(
            MeetingMatcher.startConfirmationGapOutcome(
                firstSeenAt: firstSeen, lastAudioSeenAt: lastAudioSeenAt, now: now,
                gapTolerance: MeetingDetector.nativeAudioConfirmationGapTolerance,
                minimumDuration: MeetingDetector.nativeAudioMinimumConfirmationDuration),
            .stillWaiting)
    }

    func testFalseStartSoundsCannotCompleteTheGateDuringQuietGrace() throws {
        let first = Date(timeIntervalSince1970: 1_000)
        for duration in [6.0, 7.6, 10.0, 10.8] {
            var candidate = MeetingMatcher.StartConfirmationState()
            for tick in stride(from: 0.0, through: duration, by: 1) {
                candidate.observeAudio(bundleID: "com.microsoft.teams2",
                    at: first.addingTimeInterval(tick), gapTolerance: 6)
            }
            candidate.observeAudio(bundleID: "com.microsoft.teams2",
                at: first.addingTimeInterval(duration), gapTolerance: 6)
            let window = try XCTUnwrap(candidate.window)
            XCTAssertFalse(MeetingMatcher.sustainedAudioConfirmed(
                firstSeenAt: window.firstSeenAt, now: window.lastAudioSeenAt, minimumDuration: 12))
            XCTAssertEqual(MeetingMatcher.startConfirmationGapOutcome(
                firstSeenAt: window.firstSeenAt, lastAudioSeenAt: window.lastAudioSeenAt,
                now: first.addingTimeInterval(12), gapTolerance: 6, minimumDuration: 12), .stillWaiting)
        }
    }

    func testAnIsolatedBlipCannotCoastToConfirmationOnToleranceAlone() {
        let firstSeen = Date()
        let lastAudioSeenAt = firstSeen.addingTimeInterval(0.5)
        let now = firstSeen.addingTimeInterval(
            MeetingDetector.nativeAudioMinimumConfirmationDuration + 1)

        XCTAssertEqual(
            MeetingMatcher.startConfirmationGapOutcome(
                firstSeenAt: firstSeen, lastAudioSeenAt: lastAudioSeenAt, now: now,
                gapTolerance: MeetingDetector.nativeAudioConfirmationGapTolerance,
                minimumDuration: MeetingDetector.nativeAudioMinimumConfirmationDuration),
            .abandoned)
    }

    func testGapToleranceBoundaryIsInclusive() {
        let firstSeen = Date()
        let lastAudioSeenAt = firstSeen
        let now = lastAudioSeenAt.addingTimeInterval(
            MeetingDetector.nativeAudioConfirmationGapTolerance)

        XCTAssertNotEqual(
            MeetingMatcher.startConfirmationGapOutcome(
                firstSeenAt: firstSeen, lastAudioSeenAt: lastAudioSeenAt, now: now,
                gapTolerance: MeetingDetector.nativeAudioConfirmationGapTolerance,
                minimumDuration: MeetingDetector.nativeAudioMinimumConfirmationDuration),
            .abandoned)
    }

    func testFreshAudioAfterExpiredGapStartsANewConfirmationWindow() throws {
        var state = MeetingMatcher.StartConfirmationState()
        let firstSeen = Date()
        let lastAudioSeenAt = firstSeen.addingTimeInterval(5)
        let restartedAt = firstSeen.addingTimeInterval(
            MeetingDetector.nativeAudioMinimumConfirmationDuration)

        XCTAssertTrue(state.observeAudio(
            bundleID: "com.microsoft.teams2",
            at: firstSeen,
            gapTolerance: MeetingDetector.nativeAudioConfirmationGapTolerance))
        XCTAssertFalse(state.observeAudio(
            bundleID: "com.microsoft.teams2",
            at: lastAudioSeenAt,
            gapTolerance: MeetingDetector.nativeAudioConfirmationGapTolerance))
        XCTAssertTrue(state.observeAudio(
            bundleID: "com.microsoft.teams2",
            at: restartedAt,
            gapTolerance: MeetingDetector.nativeAudioConfirmationGapTolerance))

        let restarted = try XCTUnwrap(state.window)
        XCTAssertEqual(restarted.firstSeenAt, restartedAt)
        XCTAssertEqual(restarted.lastAudioSeenAt, restartedAt)
        XCTAssertFalse(MeetingMatcher.sustainedAudioConfirmed(
            firstSeenAt: restarted.firstSeenAt,
            now: restartedAt,
            minimumDuration: MeetingDetector.nativeAudioMinimumConfirmationDuration))
    }

    func testPendingNativeHandoffOutlivesShortStopDebounceButNotItsAudioLease() throws {
        var state = MeetingMatcher.StartConfirmationState()
        let first = Date(timeIntervalSince1970: 1_000)
        state.observeAudio(
            bundleID: "com.microsoft.teams2",
            at: first,
            gapTolerance: MeetingDetector.nativeAudioConfirmationGapTolerance)
        state.observeAudio(
            bundleID: "com.microsoft.teams2",
            at: first.addingTimeInterval(8),
            gapTolerance: MeetingDetector.nativeAudioConfirmationGapTolerance)
        let window = try XCTUnwrap(state.window)

        XCTAssertTrue(MeetingMatcher.shouldKeepActiveSessionForPendingHandoff(
            confirmationWindow: window,
            freshCandidateBundleID: "com.microsoft.teams2",
            runningMeetingBundleIDs: ["com.microsoft.teams2"],
            now: first.addingTimeInterval(10),
            gapTolerance: MeetingDetector.nativeAudioConfirmationGapTolerance),
            "replacement confirmation must keep the current recording through a 5-10 second stop debounce")
        XCTAssertFalse(MeetingMatcher.shouldKeepActiveSessionForPendingHandoff(
            confirmationWindow: window,
            freshCandidateBundleID: nil,
            runningMeetingBundleIDs: ["com.microsoft.teams2"],
            now: first.addingTimeInterval(14.1),
            gapTolerance: MeetingDetector.nativeAudioConfirmationGapTolerance),
            "a quiet replacement must lose its bounded handoff lease")
        XCTAssertFalse(MeetingMatcher.shouldKeepActiveSessionForPendingHandoff(
            confirmationWindow: window,
            freshCandidateBundleID: "com.tinyspeck.slackmacgap",
            runningMeetingBundleIDs: ["com.microsoft.teams2", "com.tinyspeck.slackmacgap"],
            now: first.addingTimeInterval(10),
            gapTolerance: MeetingDetector.nativeAudioConfirmationGapTolerance),
            "another app's audio cannot inherit the candidate's lease")
    }

    func testRestartedConfirmationWindowRejectsStaleRecheck() throws {
        var state = MeetingMatcher.StartConfirmationState()
        let firstSeen = Date()
        state.observeAudio(
            bundleID: "com.microsoft.teams2",
            at: firstSeen,
            gapTolerance: MeetingDetector.nativeAudioConfirmationGapTolerance)
        let staleGeneration = try XCTUnwrap(state.window).generation

        state.observeAudio(
            bundleID: "com.microsoft.teams2",
            at: firstSeen.addingTimeInterval(
                MeetingDetector.nativeAudioConfirmationGapTolerance + 0.1),
            gapTolerance: MeetingDetector.nativeAudioConfirmationGapTolerance)

        let restartedGeneration = try XCTUnwrap(state.window).generation
        XCTAssertNotEqual(restartedGeneration, staleGeneration)
        XCTAssertFalse(state.acceptsRecheck(for: staleGeneration))
        XCTAssertTrue(state.acceptsRecheck(for: restartedGeneration))
    }

    func testSustainedAudioIsUnconfirmedBeforeAnyAudioWasSeen() {
        XCTAssertFalse(MeetingMatcher.sustainedAudioConfirmed(
            firstSeenAt: nil,
            now: Date(),
            minimumDuration: MeetingDetector.nativeAudioMinimumConfirmationDuration))
    }

    func testAudioMonitorRequiresCalendarForBroadCommunicationApps() {
        XCTAssertFalse(MeetingDetector.shouldAutoRecordNativeAudioMonitor(
            bundleID: "com.tinyspeck.slackmacgap", calendarBacked: false))
        XCTAssertTrue(MeetingDetector.shouldAutoRecordNativeAudioMonitor(
            bundleID: "com.tinyspeck.slackmacgap", calendarBacked: true))
    }

    func testChineseConferencingAppsStartLikeZoomAndChatAppsLikeTeams() {
        for dedicated in ["com.tencent.meeting", "com.tencent.tencentmeeting"] {
            XCTAssertTrue(MeetingDetector.shouldAutoRecordNativeAudioMonitor(
                bundleID: dedicated, calendarBacked: false), dedicated)
            XCTAssertFalse(MeetingDetector.requiresSustainedAudioForStart(
                bundleID: dedicated, calendarBacked: false), dedicated)
        }
        for chat in ["com.electron.lark", "com.larksuite.larkApp", "com.alibaba.DingTalkMac",
                     "com.tencent.WeWorkMac"] {
            XCTAssertFalse(MeetingDetector.shouldAutoRecordNativeAudioMonitor(
                bundleID: chat, calendarBacked: false), chat)
            XCTAssertTrue(MeetingDetector.requiresSustainedAudioForStart(
                bundleID: chat, calendarBacked: false), chat)
            XCTAssertFalse(MeetingDetector.requiresSustainedAudioForStart(
                bundleID: chat, calendarBacked: true), chat)
        }
        XCTAssertNil(MeetingDetector.knownApps["com.tencent.xinWeChat"],
                     "WeChat voice messages must never count as a meeting")
    }

    func testDoesNotStartWithoutMicOrCalendarAudio() {
        XCTAssertFalse(MeetingMatcher.isMeetingOngoing(
            hasActiveSession: false, hasRunningMeetingApp: true, hasContinuingApp: false,
            startAudioActive: false, appAudioActive: false, calendarBackedBrowserWithAudio: false))
    }

    func testStartsCalendarBackedBrowserOnOutputAudio() {
        XCTAssertTrue(MeetingMatcher.isMeetingOngoing(
            hasActiveSession: false, hasRunningMeetingApp: true, hasContinuingApp: false,
            startAudioActive: false, appAudioActive: false, calendarBackedBrowserWithAudio: true))
    }

    func testContinuesViaContinuingAppAfterRunningAppDropsOut() {
        XCTAssertTrue(MeetingMatcher.isMeetingOngoing(
            hasActiveSession: true, hasRunningMeetingApp: false, hasContinuingApp: true,
            startAudioActive: false, appAudioActive: true, calendarBackedBrowserWithAudio: false))
    }

    func testProviderYieldsNothingWhenAccessDenied() {
        let now = Date(timeIntervalSince1970: 10_000)
        let live = candidate(start: 9_800, end: 10_500)
        XCTAssertNil(FakeCalendarProvider(status: .denied, candidates: [live]).activeCandidate(now: now))
        XCTAssertNil(FakeCalendarProvider(status: .notDetermined, candidates: [live]).activeCandidate(now: now))
        XCTAssertEqual(
            FakeCalendarProvider(status: .fullAccess, candidates: [live]).activeCandidate(now: now)?.externalID,
            live.externalID)
    }

    private func iso() -> (JSONEncoder, JSONDecoder) {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return (e, d)
    }

    func testDecodesLegacyMeetingWithoutCalendarFields() throws {
        let json = #"""
        {"id":"7E57C0DE-0000-4000-8000-000000000001","title":"Standup","appName":"Zoom","startedAt":"2026-06-16T09:00:00Z","relativePath":"meetings/2026/06/16-standup","hasSystemTrack":true}
        """#
        let (_, decoder) = iso()
        let meeting = try decoder.decode(Meeting.self, from: Data(json.utf8))
        XCTAssertEqual(meeting.title, "Standup")
        XCTAssertTrue(meeting.hasSystemTrack)
        XCTAssertNil(meeting.calendarProvider)
        XCTAssertNil(meeting.calendarEventID)
        XCTAssertNil(meeting.scheduledStartAt)
        XCTAssertNil(meeting.meetingURL)
        XCTAssertNil(meeting.participantNameHints)
        XCTAssertNil(meeting.calendarParticipantIdentities)
    }

    func testCalendarFieldsRoundTrip() throws {
        var meeting = Meeting(
            id: UUID(), title: "Sprint Planning", appName: "Google Chrome",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_003_600),
            relativePath: "meetings/2026/06/16-sprint-planning")
        meeting.calendarProvider = "eventkit"
        meeting.calendarEventID = "evt#1700000000"
        meeting.calendarTitle = "Sprint Planning"
        meeting.scheduledStartAt = Date(timeIntervalSince1970: 1_700_000_000)
        meeting.scheduledEndAt = Date(timeIntervalSince1970: 1_700_003_600)
        meeting.meetingURL = URL(string: "https://meet.google.com/abc-defg-hij")
        meeting.participantNameHints = ["Ana", "Stevan"]
        meeting.calendarParticipantIdentities = [
            try XCTUnwrap(CalendarParticipantIdentity(
                id: "ana-calendar-id",
                name: "Ana",
                emailAddress: "ana@example.com")),
        ]

        let (encoder, decoder) = iso()
        let decoded = try decoder.decode(Meeting.self, from: encoder.encode(meeting))
        XCTAssertEqual(decoded, meeting)
    }

    func testManualMeetingOmitsCalendarKeys() throws {
        let meeting = Meeting(
            id: UUID(), title: "Manual recording", appName: "Manual",
            startedAt: Date(timeIntervalSince1970: 1), endedAt: nil,
            relativePath: "meetings/2026/06/16-manual")
        let (encoder, _) = iso()
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(meeting)) as? [String: Any])
        XCTAssertNil(object["calendarProvider"])
        XCTAssertNil(object["calendarEventID"])
        XCTAssertNil(object["meetingURL"])
        XCTAssertNil(object["participantNameHints"])
        XCTAssertNil(object["calendarParticipantIdentities"])
    }

    func testAlwaysOpenStreamsCarryNoMeetingSignal() {
        XCTAssertFalse(MeetingDetector.carriesMeetingSignal(
            bundleID: "com.microsoft.teams2.modulehost"))
        XCTAssertFalse(MeetingDetector.carriesMeetingSignal(
            bundleID: "com.microsoft.teams2.MODULEHOST"))

        XCTAssertTrue(MeetingDetector.carriesMeetingSignal(
            bundleID: "com.microsoft.teams2.helper"))
        XCTAssertTrue(MeetingDetector.carriesMeetingSignal(bundleID: "com.microsoft.teams2"))
        XCTAssertTrue(MeetingDetector.carriesMeetingSignal(bundleID: nil))
    }

    func testAlwaysOpenStreamIsDetectionOnlyButRemainsCaptureCandidate() {
        let moduleHost = AudioProcess(id: 500,
                                      name: "Microsoft Teams ModuleHost",
                                      bundleID: "com.microsoft.teams2.modulehost",
                                      objectID: AudioObjectID(500),
                                      isRunningOutput: true)
        let app = MeetingDetector.DetectedApp(name: "Teams",
                                              bundleID: "com.microsoft.teams2",
                                              pid: moduleHost.id)

        XCTAssertNil(MeetingDetector.bestOutputAudioProcess(for: app, in: [moduleHost]))
        XCTAssertEqual(
            MeetingDetector.bestCaptureAudioProcess(for: app, in: [moduleHost])?.id,
            moduleHost.id)

        let host = AudioProcess(id: 501,
                                name: "Microsoft Teams",
                                bundleID: "com.microsoft.teams2",
                                objectID: AudioObjectID(501),
                                isRunningOutput: true)
        XCTAssertEqual(
            MeetingDetector.bestOutputAudioProcess(for: app, in: [moduleHost, host])?.id,
            host.id)
    }

    func testConfirmationDurationRejectsObservedFalseStartsAndIsInclusive() {
        let minimumDuration = MeetingDetector.nativeAudioMinimumConfirmationDuration
        let start = Date(timeIntervalSince1970: 0)

        XCTAssertEqual(minimumDuration, 12)
        XCTAssertGreaterThan(minimumDuration, 10.8)
        for observed in [0.2, 7.6, 10.8] {
            XCTAssertFalse(MeetingMatcher.sustainedAudioConfirmed(
                firstSeenAt: start,
                now: start.addingTimeInterval(observed),
                minimumDuration: minimumDuration),
                "a \(observed)s stream must not confirm a start")
        }
        XCTAssertFalse(MeetingMatcher.sustainedAudioConfirmed(
            firstSeenAt: start,
            now: start.addingTimeInterval(minimumDuration - 0.001),
            minimumDuration: minimumDuration))
        XCTAssertTrue(MeetingMatcher.sustainedAudioConfirmed(
            firstSeenAt: start,
            now: start.addingTimeInterval(minimumDuration),
            minimumDuration: minimumDuration))
    }
}

private final class FakeCalendarProvider: CalendarEventProviding {
    let authorizationStatus: CalendarAuthorizationStatus
    private let candidates: [CalendarMeetingCandidate]

    init(status: CalendarAuthorizationStatus, candidates: [CalendarMeetingCandidate]) {
        self.authorizationStatus = status
        self.candidates = candidates
    }

    func requestAccess(_ completion: @escaping (Bool) -> Void) {
        completion(authorizationStatus == .fullAccess)
    }

    func meetingCandidates(now: Date) -> [CalendarMeetingCandidate] { candidates }
}
