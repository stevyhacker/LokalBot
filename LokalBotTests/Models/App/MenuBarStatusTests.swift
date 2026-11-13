import AppKit
import XCTest
@testable import LokalBot

/// The menu bar panel's status block: which state leads, what waits under
/// it, the two recent meetings, and the status item's glyph states.
@MainActor
final class MenuBarStatusTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    /// 18:12 on a day far from midnight in UTC.
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 18, minute: 12))!
    }

    private func meeting(_ title: String, startedMinutesAgo: Double, minutes: Double? = 12) -> Meeting {
        let start = now.addingTimeInterval(-startedMinutesAgo * 60)
        return Meeting(
            id: UUID(), title: title, appName: "Zoom", startedAt: start,
            endedAt: minutes.map { start.addingTimeInterval($0 * 60) },
            relativePath: "meetings/\(title)")
    }

    private func event(_ id: String, startsInMinutes: Double, minutes: Double = 30) -> CalendarMeetingCandidate {
        let start = now.addingTimeInterval(startsInMinutes * 60)
        return CalendarMeetingCandidate(
            provider: "test", externalID: id, title: id, startDate: start,
            endDate: start.addingTimeInterval(minutes * 60),
            meetingURL: URL(string: "https://meet.google.com/abc-defg-hij"),
            sourceCalendarTitle: "Work", participantNames: ["Maya Chen"])
    }

    private func status(
        live: Meeting? = nil,
        dictation: MenuBarStatus.Dictation? = nil,
        attention: [MenuBarAttention] = [],
        next: CalendarMeetingCandidate? = nil,
        paused: Bool = false,
        meetings: [Meeting] = []
    ) -> MenuBarStatus {
        MenuBarStatus(
            liveMeeting: live, dictation: dictation, attention: attention, nextMeeting: next, dayMemoryPaused: paused,
            meetings: meetings, now: now, calendar: calendar)
    }

    // MARK: Which state leads

    func testIdleWhenNothingIsGoingOn() {
        let idle = status(meetings: [meeting("Standup", startedMinutesAgo: 480)])
        XCTAssertEqual(idle.block, .idle)
        XCTAssertTrue(idle.moreAttention.isEmpty)
        XCTAssertEqual(idle.tone(hasCaptureWarnings: false), .neutral)
    }

    /// Recording, dictating, needs attention, a meeting soon, paused, just
    /// stopped, idle.
    func testEachStateOutranksTheOnesAfterIt() {
        let live = meeting("Design review", startedMinutesAgo: 12, minutes: nil)
        let saved = meeting("Design review", startedMinutesAgo: 13)
        let soon = event("Roadmap", startsInMinutes: 5)
        let waiting: [MenuBarAttention] = [.settingsApproval(count: 1)]

        XCTAssertEqual(
            status(live: live, dictation: .recording, attention: waiting, next: soon, paused: true,
                   meetings: [saved]).block,
            .recording(live))
        XCTAssertEqual(
            status(dictation: .composing, attention: waiting, next: soon, paused: true, meetings: [saved]).block,
            .dictating(.composing))
        XCTAssertEqual(
            status(attention: waiting, next: soon, paused: true, meetings: [saved]).block,
            .attention(.settingsApproval(count: 1)))
        XCTAssertEqual(status(next: soon, paused: true, meetings: [saved]).block, .meetingSoon(soon))
        XCTAssertEqual(status(paused: true, meetings: [saved]).block, .paused)
        XCTAssertEqual(status(meetings: [saved]).block, .justStopped(saved))
        XCTAssertEqual(status().block, .idle)
    }

    /// Stop is never hidden behind a warning: the recording keeps the block
    /// and every waiting item is listed under it.
    func testARecordingKeepsTheBlockAndListsWhatWaitsUnderIt() {
        let live = meeting("Design review", startedMinutesAgo: 12, minutes: nil)
        let waiting: [MenuBarAttention] = [.microphoneRefused, .error("Disk is almost full."), .settingsApproval(count: 2)]
        let recording = status(live: live, attention: waiting)
        XCTAssertEqual(recording.block, .recording(live))
        XCTAssertEqual(recording.moreAttention, waiting)
        XCTAssertEqual(recording.tone(hasCaptureWarnings: false), .recording)
        XCTAssertEqual(recording.tone(hasCaptureWarnings: true), .attention,
                       "A capture warning turns the recording amber and keeps its buttons")
    }

    /// A dictation is red only while it is being spoken, and keeps what
    /// waits listed under it, as a recording does.
    func testADictationLeadsWhileItRuns() {
        let waiting: [MenuBarAttention] = [.settingsApproval(count: 1)]
        let speaking = status(dictation: .recording, attention: waiting)
        XCTAssertEqual(speaking.block, .dictating(.recording))
        XCTAssertEqual(speaking.moreAttention, waiting)
        XCTAssertEqual(speaking.tone(hasCaptureWarnings: false), .recording)
        for phase in [MenuBarStatus.Dictation.starting, .transcribing, .composing] {
            XCTAssertEqual(status(dictation: phase).tone(hasCaptureWarnings: false), .neutral)
        }
    }

    func testTheFirstWaitingItemLeadsAndTheRestFollow() {
        let waiting: [MenuBarAttention] = [.microphoneRefused, .settingsApproval(count: 1)]
        let attention = status(attention: waiting)
        XCTAssertEqual(attention.block, .attention(.microphoneRefused))
        XCTAssertEqual(attention.moreAttention, [.settingsApproval(count: 1)])
        XCTAssertEqual(attention.tone(hasCaptureWarnings: false), .attention)
    }

    func testAMeetingSoonIsTheUpcomingColour() {
        XCTAssertEqual(status(next: event("Roadmap", startsInMinutes: 5)).tone(hasCaptureWarnings: false), .upcoming)
    }

    // MARK: What needs attention

    func testAttentionItemsComeMostBlockingFirst() {
        XCTAssertEqual(
            MenuBarAttention.items(
                micRecoveryNeeded: true, corePermissionsGranted: true,
                lastError: "Could not reach the model server.", pendingApprovals: 2),
            [.microphoneRefused, .error("Could not reach the model server."), .settingsApproval(count: 2)])
        XCTAssertEqual(
            MenuBarAttention.items(
                micRecoveryNeeded: false, corePermissionsGranted: true, lastError: nil, pendingApprovals: 0),
            [])
        XCTAssertEqual(
            MenuBarAttention.items(
                micRecoveryNeeded: false, corePermissionsGranted: true, lastError: "", pendingApprovals: 0),
            [], "An empty message is not an error")
    }

    /// Both are the microphone switch. Once a start was refused only System
    /// Settings can turn it on, so that fix is the one offered.
    func testARefusedMicrophoneStandsInForTheUngrantedOne() {
        XCTAssertEqual(
            MenuBarAttention.items(
                micRecoveryNeeded: true, corePermissionsGranted: false, lastError: nil, pendingApprovals: 0),
            [.microphoneRefused])
        XCTAssertEqual(
            MenuBarAttention.items(
                micRecoveryNeeded: false, corePermissionsGranted: false, lastError: nil, pendingApprovals: 0),
            [.microphoneNotGranted])
    }

    // MARK: Just stopped

    func testJustStoppedLastsItsWindow() {
        let window = MenuBarStatus.justStoppedWindow
        var saved = meeting("Design review", startedMinutesAgo: 30)
        saved.endedAt = now.addingTimeInterval(-(window - 1))
        XCTAssertEqual(MenuBarStatus.justStopped(in: [saved], now: now)?.id, saved.id)
        saved.endedAt = now.addingTimeInterval(-(window + 1))
        XCTAssertNil(MenuBarStatus.justStopped(in: [saved], now: now))
    }

    /// The panel's clock is read every few seconds, so a recording saved a
    /// moment after the last reading still counts.
    func testARecordingSavedAfterTheLastClockReadingStillCounts() {
        var saved = meeting("Design review", startedMinutesAgo: 30)
        saved.endedAt = now.addingTimeInterval(8)
        XCTAssertEqual(MenuBarStatus.justStopped(in: [saved], now: now)?.id, saved.id)
    }

    func testOnlyARecordingMadeHereWasJustStopped() {
        var imported = meeting("Imported call", startedMinutesAgo: 5, minutes: 4)
        imported.importedFileNames = ["call.m4a"]
        var sample = meeting("Sample", startedMinutesAgo: 5, minutes: 4)
        sample.sampleID = "orders-api/en"
        let unfinished = meeting("Live", startedMinutesAgo: 5, minutes: nil)
        XCTAssertNil(MenuBarStatus.justStopped(in: [imported, sample, unfinished], now: now))
    }

    func testTheLatestOfTwoSavedRecordingsIsTheOneNamed() {
        let earlier = meeting("First half", startedMinutesAgo: 30, minutes: 29)
        let later = meeting("Second half", startedMinutesAgo: 1, minutes: 0.5)
        XCTAssertEqual(MenuBarStatus.justStopped(in: [earlier, later], now: now)?.id, later.id)
    }

    // MARK: Recent meetings

    func testRecentMeetingsAreTheFirstTwoWithWhenTheyWere() {
        let morning = meeting("Engineering standup", startedMinutesAgo: 8 * 60)
        let yesterday = meeting("Q3 roadmap planning", startedMinutesAgo: 26 * 60)
        let lastWeek = meeting("Kickoff", startedMinutesAgo: 6 * 24 * 60)
        let recent = status(meetings: [morning, yesterday, lastWeek]).recentMeetings
        XCTAssertEqual(recent.map(\.meeting.id), [morning.id, yesterday.id])
        XCTAssertEqual(recent.map(\.when), [.today(morning.startedAt), .yesterday])
        XCTAssertEqual(
            status(meetings: [lastWeek]).recentMeetings.map(\.when), [.earlier(lastWeek.startedAt)])
        XCTAssertEqual(MenuBarStatus.recentMeetingLimit, 2)
    }

    func testTheMeetingJustSavedIsListedFirstAsJustNow() {
        let morning = meeting("Engineering standup", startedMinutesAgo: 8 * 60)
        let noon = meeting("Design sync", startedMinutesAgo: 6 * 60)
        let saved = meeting("Design review", startedMinutesAgo: 13)
        // Even when the library has not put it first.
        let recent = status(meetings: [noon, morning, saved]).recentMeetings
        XCTAssertEqual(recent.map(\.meeting.id), [saved.id, noon.id])
        XCTAssertEqual(recent.map(\.when), [.justNow, .today(noon.startedAt)])
    }

    func testMergedSourcesAndTheLiveRecordingAreNotListed() {
        let live = meeting("Design review", startedMinutesAgo: 12, minutes: nil)
        var source = meeting("Part one", startedMinutesAgo: 90)
        source.mergedIntoMeetingID = UUID()
        let standup = meeting("Engineering standup", startedMinutesAgo: 8 * 60)
        let recent = status(live: live, meetings: [live, source, standup]).recentMeetings
        XCTAssertEqual(recent.map(\.meeting.id), [standup.id])
    }

    // MARK: The meeting about to start

    /// Today's rule with the menu's shorter window.
    func testTheMenuLeadsWithAMeetingOnlyOnceItIsClose() {
        let window = MenuBarStatus.soonWindow
        XCTAssertLessThan(window, TodayAgenda.nextMeetingWindow)
        let close = event("Roadmap", startsInMinutes: 5)
        let later = event("Review", startsInMinutes: window / 60 + 5)
        XCTAssertEqual(
            TodayAgenda.nextMeeting(in: [close, later], now: now, window: window)?.externalID, "Roadmap")
        XCTAssertNil(TodayAgenda.nextMeeting(in: [later], now: now, window: window))
        XCTAssertEqual(TodayAgenda.nextMeeting(in: [later], now: now)?.externalID, "Review",
                       "Today still shows it within the hour")
    }

    func testAMeetingUnderWayKeepsTheBlockUntilItIsRecordedOrOver() {
        let underWay = event("Roadmap", startsInMinutes: -10)
        let window = MenuBarStatus.soonWindow
        XCTAssertEqual(TodayAgenda.nextMeeting(in: [underWay], now: now, window: window)?.externalID, "Roadmap")
        XCTAssertNil(TodayAgenda.nextMeeting(
            in: [underWay], now: now, recordedEventIDs: ["Roadmap"], window: window))
        XCTAssertNil(TodayAgenda.nextMeeting(
            in: [event("Earlier", startsInMinutes: -60)], now: now, window: window))
    }

    // MARK: The line under "Not recording"

    func testTheRecordingHabitFollowsTheDetectorThenTheSetting() {
        XCTAssertEqual(MenuBarRecordingHabit.habit(detectedApp: "Zoom", mode: .manual), .appDetected("Zoom"))
        XCTAssertEqual(MenuBarRecordingHabit.habit(detectedApp: nil, mode: .automatic), .recordsAutomatically)
        XCTAssertEqual(MenuBarRecordingHabit.habit(detectedApp: "", mode: .ask), .asksFirst)
        XCTAssertEqual(MenuBarRecordingHabit.habit(detectedApp: nil, mode: .manual), .manualOnly)
    }

    // MARK: Sound levels

    private func health(microphone: String, system: String, level: Double? = nil) -> RecordingMemoryHealthSnapshot {
        RecordingMemoryHealthSnapshot(
            isRecording: true, microphoneStatus: microphone, microphoneLastWriteAt: nil,
            microphoneDroppedBuffers: 0, systemAudioStatus: system, systemAudioLastWriteAt: nil,
            systemAudioDroppedBuffers: 0, lastRecoveryAt: nil, systemAudioLevel: level)
    }

    func testARecordingWithoutACallIsMicrophoneOnly() {
        let line = MenuBarAudioLine(health(
            microphone: "Receiving audio", system: RecordingMemoryHealthSnapshot.notAttachedStatus))
        XCTAssertNil(line.callAudio)
        XCTAssertNil(line.callAudioLevel)
        XCTAssertTrue(line.microphone.isReceiving)
    }

    func testCallAudioCarriesItsLevelAndEachSourceItsOwnState() {
        let line = MenuBarAudioLine(health(microphone: "Receiving silence", system: "Receiving audio", level: 0.6))
        XCTAssertEqual(line.microphone.tone, .attention)
        XCTAssertFalse(line.microphone.isReceiving)
        XCTAssertEqual(line.callAudio?.tone, .good)
        XCTAssertEqual(line.callAudioLevel, 0.6)
        XCTAssertEqual(MenuBarAudioLine(health(microphone: "Receiving audio", system: "Silent")).callAudio?.tone, .idle)
    }

    // MARK: The status item's glyph

    private func alpha(_ image: NSImage, x: Double, y: Double) throws -> Double {
        let scale = 4
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(image.size.width) * scale, pixelsHigh: Int(image.size.height) * scale,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        // Bitmap rows count down from the top; image points count up.
        let color = rep.colorAt(x: Int(x * Double(scale)), y: rep.pixelsHigh - 1 - Int(y * Double(scale)))
        return Double(try XCTUnwrap(color).alphaComponent)
    }

    func testEveryGlyphStateIsATemplateImageOfTheSameSize() {
        for dimmed in [false, true] {
            for attention in [false, true] {
                let image = MenuBarIcon.image(.init(dimmed: dimmed, attention: attention))
                XCTAssertTrue(image.isTemplate, "The menu bar tints template images for light, dark and highlight")
                XCTAssertEqual(image.size, MenuBarIcon.size)
            }
        }
    }

    func testThePausedGlyphIsFaintAndTheAttentionDotIsNot() throws {
        // The middle of the waveform's centre bar.
        let ink = (x: 9.0, y: 6.5)
        XCTAssertGreaterThan(try alpha(MenuBarIcon.image(.init()), x: ink.x, y: ink.y), 0.9)
        let paused = try alpha(MenuBarIcon.image(.init(dimmed: true)), x: ink.x, y: ink.y)
        XCTAssertEqual(paused, Double(MenuBarIcon.dimmedOpacity), accuracy: 0.05)

        let badge = MenuBarIcon.badgeRect
        let both = MenuBarIcon.image(.init(dimmed: true, attention: true))
        XCTAssertGreaterThan(try alpha(both, x: badge.midX, y: badge.midY), 0.9, "The dot stays at full strength")
        XCTAssertLessThan(try alpha(MenuBarIcon.image(.init()), x: badge.midX, y: badge.midY), 0.1,
                          "The plain glyph has nothing in that corner")
    }

    /// The head's top right corner runs under the dot; a clear ring keeps the
    /// two apart.
    func testTheAttentionDotIsCutClearOfTheGlyph() throws {
        // On the head's top edge, between the dot and the ring's outer rim.
        let edge = (x: 12.2, y: 12.0)
        XCTAssertGreaterThan(try alpha(MenuBarIcon.image(.init()), x: edge.x, y: edge.y), 0.5)
        XCTAssertLessThan(try alpha(MenuBarIcon.image(.init(attention: true)), x: edge.x, y: edge.y), 0.1)
    }
}
