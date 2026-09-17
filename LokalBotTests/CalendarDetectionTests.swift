import CoreAudio
import XCTest
@testable import LokalBot

/// Calendar-assisted meeting detection: the conferencing-URL parser, event
/// filtering, active-event selection, the browser-meeting decision (the Google
/// Meet reliability fix), repeat-suppression cooldown, titling, and `Meeting`
/// metadata round-tripping. All pure — no EventKit, no real calendar.
final class CalendarDetectionTests: XCTestCase {

    func testCalendarCapabilityIsConfiguredForGeneratedBuilds() throws {
        let entitlementKey = "com.apple.security.personal-information.calendars"
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let entitlementsURL = repositoryRoot
            .appendingPathComponent("LokalBot/LokalBot.entitlements")
        let data = try Data(contentsOf: entitlementsURL)
        let properties = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any])
        XCTAssertEqual(properties[entitlementKey] as? Bool, true)
    }

    // MARK: - ConferenceURLDetector

    func testDetectsGoogleMeetLink() {
        let url = ConferenceURLDetector.firstMeetingURL(in: "Join here: https://meet.google.com/abc-defg-hij")
        XCTAssertEqual(url?.host, "meet.google.com")
        XCTAssertTrue(ConferenceURLDetector.isMeetingURL(url))
    }

    func testDetectsZoomSubdomain() {
        let url = URL(string: "https://us02web.zoom.us/j/123456789")
        XCTAssertTrue(ConferenceURLDetector.isMeetingURL(url))
    }

    func testDetectsTeamsAndWebex() {
        XCTAssertTrue(ConferenceURLDetector.isMeetingURL(URL(string: "https://teams.microsoft.com/l/meetup-join/x")))
        XCTAssertTrue(ConferenceURLDetector.isMeetingURL(URL(string: "https://acme.webex.com/meet/jane")))
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

    // MARK: - CalendarEventFilter

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
        // Free time, no attendees, no meeting link → a focus/hold block.
        XCTAssertFalse(CalendarEventFilter.isRecordableMeeting(
            raw(free: true, attendees: false, meetingURL: false)))
    }

    func testFreeTimeStillRecordableWithAttendeesOrLink() {
        XCTAssertTrue(CalendarEventFilter.isRecordableMeeting(raw(free: true, attendees: true, meetingURL: false)))
        XCTAssertTrue(CalendarEventFilter.isRecordableMeeting(raw(free: true, attendees: false, meetingURL: true)))
    }

    // MARK: - Active-event selection

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
        // In progress.
        XCTAssertTrue(candidate(start: 9_700, end: 10_600).isActive(at: now))
        // Within the 1-minute early-join grace before start (a beat early).
        XCTAssertTrue(candidate(start: 10_030, end: 10_900).isActive(at: now))
        // Beyond the grace — must NOT auto-record minutes ahead of the start.
        XCTAssertFalse(candidate(start: 10_120, end: 11_000).isActive(at: now))  // 2 min out
        XCTAssertFalse(candidate(start: 10_600, end: 11_000).isActive(at: now))  // 10 min out
        // Already ended.
        XCTAssertFalse(candidate(start: 9_000, end: 9_900).isActive(at: now))
    }

    func testActiveCandidatePrefersInProgress() {
        let now = Date(timeIntervalSince1970: 10_000)
        let upcoming = candidate(id: "soon", start: 10_030, end: 10_800)   // within early-join grace
        let live = candidate(id: "live", start: 9_800, end: 10_500)        // in progress
        let result = [upcoming, live].activeCandidate(at: now)
        XCTAssertEqual(result?.externalID, "live")
    }

    func testActiveCandidateNilWhenNoneActive() {
        let now = Date(timeIntervalSince1970: 10_000)
        let past = candidate(id: "past", start: 8_000, end: 9_000)
        let future = candidate(id: "future", start: 12_000, end: 13_000)
        XCTAssertNil([past, future].activeCandidate(at: now))
    }

    // MARK: - Browser-meeting decision (the reliability fix)

    /// A tab title cannot establish that the user joined the call.
    func testTitleMatchAloneDoesNotRecord() {
        XCTAssertFalse(MeetingMatcher.browserCountsAsMeeting(
            titleMatchesMarker: true, hasOutputAudio: false,
            calendarBacked: false, requireCalendarForBrowser: false))
    }

    /// No title and no calendar → not a meeting (the pre-calendar fallback, and
    /// why a random browser tab is never recorded).
    func testNoTitleNoCalendarDoesNotRecord() {
        XCTAssertFalse(MeetingMatcher.browserCountsAsMeeting(
            titleMatchesMarker: false, hasOutputAudio: true,
            calendarBacked: false, requireCalendarForBrowser: false))
    }

    /// Calendar plus unrelated video output must never establish a call.
    func testCalendarBackedBrowserAudioDoesNotRecord() {
        XCTAssertFalse(MeetingMatcher.browserCountsAsMeeting(
            titleMatchesMarker: false, hasOutputAudio: true,
            calendarBacked: true, requireCalendarForBrowser: false))
    }

    /// Calendar event alone, with no browser audio, never starts a recording.
    func testCalendarWithoutAudioDoesNotRecord() {
        XCTAssertFalse(MeetingMatcher.browserCountsAsMeeting(
            titleMatchesMarker: false, hasOutputAudio: false,
            calendarBacked: true, requireCalendarForBrowser: false))
    }

    func testStrictModeRequiresCalendar() {
        // Title-only is rejected in strict mode...
        XCTAssertFalse(MeetingMatcher.browserCountsAsMeeting(
            titleMatchesMarker: true, hasOutputAudio: true,
            calendarBacked: false, requireCalendarForBrowser: true))
        // ...but a verified in-call session with calendar support is accepted.
        XCTAssertTrue(MeetingMatcher.browserCountsAsMeeting(
            titleMatchesMarker: false, hasOutputAudio: true,
            calendarBacked: true, requireCalendarForBrowser: true, verifiedSession: true))
    }

    // MARK: - Repeat-suppression cooldown

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

    // MARK: - Back-to-back calendar handoff

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

    // MARK: - Titling

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

    // MARK: - Confidence

    func testConfidence() {
        XCTAssertEqual(MeetingMatcher.confidence(hasApp: true, hasCalendar: true), .high)
        XCTAssertEqual(MeetingMatcher.confidence(hasApp: true, hasCalendar: false), .medium)
        XCTAssertEqual(MeetingMatcher.confidence(hasApp: false, hasCalendar: true), .low)
    }

    // MARK: - In-meeting policy (start / continue / stop)

    /// Regression: once recording starts, our own mic recorder keeps the global
    /// "mic in use" flag true. The continue decision must ignore it and key off
    /// the meeting app's OWN audio — otherwise the meeting never reads as ended
    /// and recording never stops.
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
        // Browsers carry their own title/calendar gate and never wait here.
        XCTAssertFalse(MeetingDetector.requiresSustainedAudioForStart(
            bundleID: "com.google.Chrome", calendarBacked: false))
    }

    /// `detectRunningMeetingApp` requires fresh output audio, so a candidate
    /// lost that signal entirely — not just its elapsed time — every time the
    /// remote side paused to listen rather than talk. Real log, 2026-08-26: six
    /// consecutive attempts on a live Teams call each failed after 4.2-12.7 s,
    /// two of them past the 12 s window itself. A gap this short is
    /// conversational rhythm, not the call ending, and must not restart the
    /// window.
    func testABriefPauseInTheRemoteSideDoesNotAbandonTheWindow() {
        let firstSeen = Date()
        let lastAudioSeenAt = firstSeen.addingTimeInterval(3)
        let now = lastAudioSeenAt.addingTimeInterval(4)  // a 4 s quiet turn

        XCTAssertEqual(
            MeetingMatcher.startConfirmationGapOutcome(
                firstSeenAt: firstSeen, lastAudioSeenAt: lastAudioSeenAt, now: now,
                gapTolerance: MeetingDetector.nativeAudioConfirmationGapTolerance,
                minimumDuration: MeetingDetector.nativeAudioMinimumConfirmationDuration),
            .stillWaiting)
    }

    /// Silence past the gap tolerance is what `nativeAudioMinimumConfirmationDuration`
    /// itself already guards against for a single blip — a candidate that never
    /// recurs must still be abandoned, gap-tolerant or not.
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

    /// The two anomalous log lines — "lost the audio... after=12.3s" and
    /// "after=12.7s" — show the total span already past the window at the
    /// exact instant the tick found no fresh audio. A bridged gap must confirm
    /// immediately in that case rather than waiting for evidence that both
    /// sides have already provided.
    func testATotalSpanPastTheWindowConfirmsEvenMidGap() {
        let firstSeen = Date()
        let lastAudioSeenAt = firstSeen.addingTimeInterval(11)
        let now = firstSeen.addingTimeInterval(
            MeetingDetector.nativeAudioMinimumConfirmationDuration + 0.3)

        XCTAssertEqual(
            MeetingMatcher.startConfirmationGapOutcome(
                firstSeenAt: firstSeen, lastAudioSeenAt: lastAudioSeenAt, now: now,
                gapTolerance: MeetingDetector.nativeAudioConfirmationGapTolerance,
                minimumDuration: MeetingDetector.nativeAudioMinimumConfirmationDuration),
            .confirmed)
    }

    /// The tolerance only ever bridges a gap in evidence that already exists;
    /// it cannot manufacture evidence on its own. A single blip (a
    /// notification ding) followed by real silence for the rest of the window
    /// must still be abandoned — the exact case
    /// `nativeAudioMinimumConfirmationDuration` was introduced to guard
    /// against, and this tolerance must not reopen it.
    func testAnIsolatedBlipCannotCoastToConfirmationOnToleranceAlone() {
        let firstSeen = Date()
        let lastAudioSeenAt = firstSeen.addingTimeInterval(0.5)  // one brief blip
        let now = firstSeen.addingTimeInterval(
            MeetingDetector.nativeAudioMinimumConfirmationDuration + 1)

        XCTAssertEqual(
            MeetingMatcher.startConfirmationGapOutcome(
                firstSeenAt: firstSeen, lastAudioSeenAt: lastAudioSeenAt, now: now,
                gapTolerance: MeetingDetector.nativeAudioConfirmationGapTolerance,
                minimumDuration: MeetingDetector.nativeAudioMinimumConfirmationDuration),
            .abandoned)
    }

    /// The gap boundary is inclusive, matching `sustainedAudioConfirmed`'s own
    /// inclusive boundary.
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

    /// A fresh tick cannot revive a window whose last evidence is already past
    /// tolerance. At this timestamp the old implementation saw a 12-second
    /// total span and confirmed immediately instead of starting over.
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

    /// Canceling a submitted DispatchWorkItem is not the identity check: if an
    /// obsolete callback is already queued, its captured generation must no
    /// longer match the restarted window.
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

    // MARK: - Provider access gating (denied → no candidates)

    func testProviderYieldsNothingWhenAccessDenied() {
        let now = Date(timeIntervalSince1970: 10_000)
        let live = candidate(start: 9_800, end: 10_500)
        XCTAssertNil(FakeCalendarProvider(status: .denied, candidates: [live]).activeCandidate(now: now))
        XCTAssertNil(FakeCalendarProvider(status: .notDetermined, candidates: [live]).activeCandidate(now: now))
        XCTAssertEqual(
            FakeCalendarProvider(status: .fullAccess, candidates: [live]).activeCandidate(now: now)?.externalID,
            live.externalID)
    }

    // MARK: - Meeting metadata persistence

    private func iso() -> (JSONEncoder, JSONDecoder) {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return (e, d)
    }

    /// A meta.json written before calendar support still decodes (calendar
    /// fields default to nil).
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

    /// Calendar provenance round-trips through the same ISO-8601 codec
    /// StorageManager uses for meta.json.
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

    /// Manual recordings (no calendar) keep their old, calendar-free JSON shape:
    /// nil optionals are omitted, never written as null keys.
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

    // MARK: - Streams that are open for the app's whole lifetime

    /// Measured with Teams launched and idle, 20 samples over 20 s: modulehost
    /// reported isRunningOutput and isRunningInput true in 20/20 while every
    /// helper reported false. A process in that state cannot be evidence of a
    /// call, so the start decision must not read it.
    func testAlwaysOpenStreamsCarryNoMeetingSignal() {
        XCTAssertFalse(MeetingDetector.carriesMeetingSignal(
            bundleID: "com.microsoft.teams2.modulehost"))
        XCTAssertFalse(MeetingDetector.carriesMeetingSignal(
            bundleID: "com.microsoft.teams2.MODULEHOST"))

        XCTAssertTrue(MeetingDetector.carriesMeetingSignal(
            bundleID: "com.microsoft.teams2.helper"))
        XCTAssertTrue(MeetingDetector.carriesMeetingSignal(bundleID: "com.microsoft.teams2"))
        // An unknown process is judged by the rest of the rules, not silently
        // dropped here.
        XCTAssertTrue(MeetingDetector.carriesMeetingSignal(bundleID: nil))
    }

    /// An always-open stream is not evidence that a meeting is running, but it
    /// remains a valid capture target once another signal starts the recording.
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

        // The host's own stream is still valid detection evidence.
        let host = AudioProcess(id: 501,
                                name: "Microsoft Teams",
                                bundleID: "com.microsoft.teams2",
                                objectID: AudioObjectID(501),
                                isRunningOutput: true)
        XCTAssertEqual(
            MeetingDetector.bestOutputAudioProcess(for: app, in: [moduleHost, host])?.id,
            host.id)
    }

    /// Every measured short false start is below the inclusive confirmation
    /// boundary; a real candidate confirms exactly at that boundary.
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

/// In-memory `CalendarEventProviding` for the matching tests — canned status
/// and candidates, no EventKit.
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
