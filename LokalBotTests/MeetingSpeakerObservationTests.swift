import AudioToolbox
import XCTest
@testable import LokalBot

final class MeetingSpeakerObservationTests: XCTestCase {
    private func batch(time: Double, name: String = "Alex", reference: String = "alex", epoch: String = "grid", source: String = "meet") -> MeetingSpeakerObservationBatch {
        .init(sourceKey: source, observations: [.init(reference: reference, displayName: name,
            layoutEpoch: epoch, hostStart: time, hostEnd: time + 0.02, active: true)])
    }
    private func clock() -> RecordingAudioClock {
        let clock = RecordingAudioClock()
        clock.record(hostTime: AudioConvertNanosToHostTime(100_000_000_000), valid: true,
            startFrame: 0, frames: 48_000 * 60, sampleRate: 48_000)
        return clock
    }
    func testTwoStableObservationsEstablishAudioClockCoverage() throws {
        var accumulator = SpeakerObservationAccumulator()
        let clock = clock()
        XCTAssertNil(accumulator.consume(batch(time: 100), clock: clock))
        let interval = try XCTUnwrap(accumulator.consume(batch(time: 100.5), clock: clock))
        XCTAssertEqual(interval.range.start, 0.02, accuracy: 0.00001)
        XCTAssertEqual(interval.range.end, 0.5, accuracy: 0.00001)
    }
    func testGapsLayoutsSourcesAndStaleFramesNeverExtendThePriorSpeaker() {
        let changes = [batch(time: 102), batch(time: 100.5, epoch: "reordered"), batch(time: 100.5, source: "different-tab"), batch(time: 100)]
        for changed in changes {
            var accumulator = SpeakerObservationAccumulator()
            let clock = clock()
            _ = accumulator.consume(batch(time: 100), clock: clock)
            XCTAssertNil(accumulator.consume(changed, clock: clock))
        }
    }
    func testMultipleActiveDuplicateMutedAndSelfAreAmbiguous() {
        var multiple = batch(time: 100.5)
        multiple.observations += batch(time: 100.5, name: "Sam", reference: "sam").observations
        var duplicate = batch(time: 100.5); duplicate.observations[0].unique = false
        var muted = batch(time: 100.5); muted.observations[0].muted = true
        var local = batch(time: 100.5); local.observations[0].isSelf = true
        var missing = batch(time: 100.5); missing.reason = "source timeout"
        for ambiguous in [multiple, duplicate, muted, local, missing] {
            var accumulator = SpeakerObservationAccumulator()
            let clock = clock()
            _ = accumulator.consume(batch(time: 100), clock: clock)
            XCTAssertNil(accumulator.consume(ambiguous, clock: clock))
            XCTAssertNil(accumulator.consume(batch(time: 101), clock: clock))
        }
    }
    func testExactMeetOriginAndMeetingAssociationAreRequired() {
        XCTAssertEqual(GoogleMeetSpeakerObservationProvider.meetURL("https://meet.google.com/abc-defg-hij?authuser=0"), "https://meet.google.com/abc-defg-hij")
        for bad in ["http://meet.google.com/abc-defg-hij", "https://meet.google.com.evil.test/abc-defg-hij", "https://meet.google.com/landing", "https://evil@meet.google.com/abc-defg-hij"] {
            XCTAssertNil(GoogleMeetSpeakerObservationProvider.meetURL(bad))
        }
        var snapshot = MeetingParticipantSnapshot(processID: 1, title: "Synthetic Meet", url: "https://meet.google.com/abc-defg-hij",
            windowFrame: .init(x: 0, y: 0, width: 1000, height: 700), tiles: [], hostStart: 100, hostEnd: 100.1)
        var config = AppSettings()
        XCTAssertTrue(GoogleMeetSpeakerObservationProvider.sourceAllowed(snapshot: snapshot, config: config, expectedURL: snapshot.url))
        XCTAssertFalse(GoogleMeetSpeakerObservationProvider.sourceAllowed(snapshot: snapshot, config: config, expectedURL: "https://meet.google.com/xyz-uvwx-rst"))
        config.excludedScreenDomains = "meet.google.com"
        XCTAssertFalse(GoogleMeetSpeakerObservationProvider.sourceAllowed(snapshot: snapshot, config: config, expectedURL: nil))
        config.excludedScreenDomains = ""
        snapshot.title = "Meet - Incognito"
        XCTAssertFalse(GoogleMeetSpeakerObservationProvider.sourceAllowed(snapshot: snapshot, config: config, expectedURL: nil))
        snapshot.title = "Meet"; snapshot.hostEnd = 101
        XCTAssertFalse(GoogleMeetSpeakerObservationProvider.sourceAllowed(snapshot: snapshot, config: config, expectedURL: nil))
        snapshot.hostEnd = 100.1; snapshot.otherAudibleTabs = true
        XCTAssertFalse(GoogleMeetSpeakerObservationProvider.sourceAllowed(snapshot: snapshot, config: config, expectedURL: nil),
            "Speaker safety remains scoped to the bound Meet window")
    }
    func testOnlyNamedParticipantContainersAreAcceptedByTheAdapterContract() {
        XCTAssertEqual(MeetingParticipantAccessibilityReader.tileName(description: "Alex's tile"), "Alex")
        XCTAssertEqual(MeetingParticipantAccessibilityReader.tileName(description: "Sam’s video"), "Sam")
        for invalid in ["Alex is presenting", "Pinned Alex", "Quarterly report", "alex@example.com's tile", "You's tile"] {
            XCTAssertNil(MeetingParticipantAccessibilityReader.tileName(description: invalid))
        }
    }
    func testNewSettingsDecodeOffAndRemainIndependentOfDayMemory() throws {
        let legacy = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertFalse(legacy.identifySpeakersFromVisuals)
        XCTAssertFalse(legacy.rememberSpeakersOnMac)
        var settings = legacy
        settings.identifySpeakersFromVisuals = true
        settings.rememberSpeakersOnMac = true
        let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertTrue(restored.identifySpeakersFromVisuals)
        XCTAssertTrue(restored.rememberSpeakersOnMac)
        XCTAssertEqual(restored.screenshotsEnabled, legacy.screenshotsEnabled)
        XCTAssertEqual(restored.meetingVisualContextEnabled, legacy.meetingVisualContextEnabled)
        XCTAssertEqual(restored.screenContextCaptureMode, legacy.screenContextCaptureMode)
    }

    func testVerifiedMeetCanBeObservedWhileAnotherAppIsForeground() {
        XCTAssertTrue(GoogleMeetSpeakerObservationProvider.windowAllowed(capturedBundleID: "com.google.Chrome",
            foregroundBundleID: "com.openai.codex", expectedURL: "https://meet.google.com/abc-defg-hij"))
        for url in [nil, "https://example.com/abc-defg-hij", "https://meet.google.com/landing"] as [String?] {
            XCTAssertFalse(GoogleMeetSpeakerObservationProvider.windowAllowed(capturedBundleID: "com.google.Chrome",
                foregroundBundleID: "com.openai.codex", expectedURL: url))
        }
        XCTAssertFalse(GoogleMeetSpeakerObservationProvider.windowAllowed(capturedBundleID: "us.zoom.xos",
            foregroundBundleID: "com.google.Chrome", expectedURL: "https://meet.google.com/abc-defg-hij"))
    }

    func testSpeakingTransitionsAndTileOrderAreNotLayoutChanges() {
        let alice = MeetingParticipantTile(name: "Alice", frame: .init(x: 0, y: 0, width: 200, height: 150), speaking: true, muted: false, isSelf: false)
        var bob = alice; bob.name = "Bob"; bob.frame.origin.x = 220; bob.speaking = false
        var silentAlice = alice; silentAlice.speaking = false
        var activeBob = bob; activeBob.speaking = true
        XCTAssertTrue(GoogleMeetSpeakerObservationProvider.sameLayout([alice, bob], [activeBob, silentAlice]))
        activeBob.frame.origin.x += 20
        XCTAssertFalse(GoogleMeetSpeakerObservationProvider.sameLayout([alice, bob], [activeBob, silentAlice]))
        var changedName = alice; changedName.name = "Eve"
        XCTAssertFalse(GoogleMeetSpeakerObservationProvider.sameLayout([alice], [changedName]))
    }

    func testCaptureWindowUsesUniqueProcessAndFullFrameInsteadOfCrossAPITitleEquality() {
        var snapshot = MeetingParticipantSnapshot(processID: 42, title: "Meet - Example - Google Chrome",
            url: "https://meet.google.com/abc-defg-hij", windowFrame: .init(x: -1200, y: 40, width: 1100, height: 800),
            tiles: [], hostStart: 100, hostEnd: 100.1)
        let window = GoogleMeetSpeakerObservationProvider.CaptureWindow(id: 7, processID: 42, frame: snapshot.windowFrame)
        var unrelated = window; unrelated.id = 8; unrelated.processID = 43
        XCTAssertEqual(GoogleMeetSpeakerObservationProvider.captureWindowID(snapshot: snapshot, windows: [unrelated, window]), 7)
        snapshot.title = "Meet - Example"
        XCTAssertEqual(GoogleMeetSpeakerObservationProvider.captureWindowID(snapshot: snapshot, windows: [window]), 7)
        var rounded = window; rounded.frame.origin.x += 1; rounded.frame.size.height -= 1
        XCTAssertEqual(GoogleMeetSpeakerObservationProvider.captureWindowID(snapshot: snapshot, windows: [rounded]), 7)
    }

    func testCaptureWindowRejectsAmbiguousMissingAndDifferentSizedWindows() {
        let snapshot = MeetingParticipantSnapshot(processID: 42, title: "Meet",
            url: "https://meet.google.com/abc-defg-hij", windowFrame: .init(x: 0, y: 0, width: 1100, height: 800),
            tiles: [], hostStart: 100, hostEnd: 100.1)
        let window = GoogleMeetSpeakerObservationProvider.CaptureWindow(id: 7, processID: 42, frame: snapshot.windowFrame)
        var duplicate = window; duplicate.id = 8
        XCTAssertNil(GoogleMeetSpeakerObservationProvider.captureWindowID(snapshot: snapshot, windows: [window, duplicate]))
        XCTAssertNil(GoogleMeetSpeakerObservationProvider.captureWindowID(snapshot: snapshot, windows: []))
        var taller = window; taller.frame.size.height += 40
        XCTAssertNil(GoogleMeetSpeakerObservationProvider.captureWindowID(snapshot: snapshot, windows: [taller]))
        var otherProcess = window; otherProcess.processID = 43
        XCTAssertNil(GoogleMeetSpeakerObservationProvider.captureWindowID(snapshot: snapshot, windows: [otherProcess]))
        var moved = window; moved.frame.origin.y += 10
        XCTAssertNil(GoogleMeetSpeakerObservationProvider.captureWindowID(snapshot: snapshot, windows: [moved]))
    }

    func testParticipantControlsAndNamesEstablishTilesWithoutPossessiveLabels() {
        XCTAssertEqual(MeetingParticipantTileResolver.name(ownLabels: ["Alice"], descendantLabels: ["More options for Alice"]), "Alice")
        XCTAssertEqual(MeetingParticipantTileResolver.name(ownLabels: [], descendantLabels: ["Alice", "Pin Alice to your main screen"]), "Alice")
        XCTAssertEqual(MeetingParticipantTileResolver.name(ownLabels: ["Video of Alice"], descendantLabels: []), "Alice")
        XCTAssertNil(MeetingParticipantTileResolver.name(ownLabels: ["Quarterly report"], descendantLabels: ["Alice", "Speaking"]))
        XCTAssertNil(MeetingParticipantTileResolver.name(ownLabels: [], descendantLabels: ["Alice", "Bob", "Mute Alice", "Mute Bob"]))
        XCTAssertNil(MeetingParticipantTileResolver.name(ownLabels: [], descendantLabels: ["More options for Alice", "Bob"]))
    }

    func testNestedTileContainersAreDeduplicatedButDuplicatePeopleRemainAmbiguous() {
        let inner = MeetingParticipantTile(name: "Alice", frame: .init(x: 10, y: 10, width: 200, height: 150), speaking: true, muted: false, isSelf: false)
        var outer = inner; outer.frame = .init(x: 0, y: 0, width: 230, height: 180)
        var other = inner; other.frame.origin.x = 300
        XCTAssertEqual(MeetingParticipantTileResolver.innermostTiles([outer, inner, other]).count, 2)
        let paired = MeetingParticipantTileResolver.tile(name: "Alice", frame: inner.frame, labels: ["Speaking", "Paired with Bob"])
        XCTAssertTrue(paired.sharedRoom)
    }

    func testDiagnosticsDistinguishMissingTilesAmbiguityAndClockGaps() throws {
        var diagnostics = SpeakerObservationDiagnostics()
        diagnostics.record(.init(sourceKey: "meet", observations: [], reason: "layout", issue: .layoutUnavailable), interval: nil)
        diagnostics.record(batch(time: 100), interval: nil)
        var ambiguous = batch(time: 100.5)
        ambiguous.observations += batch(time: 100.5, name: "Bob", reference: "bob").observations
        diagnostics.record(ambiguous, interval: nil)
        XCTAssertEqual(diagnostics.issues["layoutUnavailable"], 1)
        XCTAssertEqual(diagnostics.issues["noClockCoverage"], 1)
        XCTAssertEqual(diagnostics.issues["ambiguousSpeaker"], 1)
        let serialized = String(decoding: try JSONEncoder().encode(diagnostics), as: UTF8.self)
        XCTAssertFalse(serialized.contains("Alex"))
        XCTAssertFalse(serialized.contains("Bob"))
    }

    func testMissingSpeakerEvidenceIsDistinguishedFromDisabledAndSuccessfulCapture() {
        var diagnostics = SpeakerObservationDiagnostics()
        XCTAssertNil(diagnostics.missingSpeakerNamesExplanation)
        diagnostics.record(.init(sourceKey: "meet", observations: [], reason: "layout", issue: .layoutUnavailable), interval: nil)
        XCTAssertNotNil(diagnostics.missingSpeakerNamesExplanation)
        diagnostics.record(batch(time: 100), interval: .init(participantReference: "alex", displayName: "Alex",
            range: .init(start: 0, end: 0.5), uncertainty: 0.1, layoutEpoch: "grid"))
        XCTAssertNil(diagnostics.missingSpeakerNamesExplanation)
        var rememberingOnly = SpeakerObservationDiagnostics()
        rememberingOnly.record(.init(sourceKey: "meet", observations: [], reason: nil), interval: nil, visual: false)
        XCTAssertNil(rememberingOnly.missingSpeakerNamesExplanation)
        var legacy = SpeakerObservationDiagnostics()
        legacy.observations = 10
        legacy.issues["noActiveSpeaker"] = 10
        XCTAssertNil(legacy.missingSpeakerNamesExplanation)
        legacy.issues["windowChanged"] = 1
        XCTAssertNotNil(legacy.missingSpeakerNamesExplanation)
    }
}
