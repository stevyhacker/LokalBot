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
    func testGapsLayoutsSourcesAndStaleObservationsNeverExtendThePriorSpeaker() {
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

    private func snapshot(speaking: Bool?, selfKnown: Bool = true) -> MeetingParticipantSnapshot {
        .init(processID: 42, title: "Meet", url: "https://meet.google.com/abc-defg-hij",
            windowFrame: .init(x: 0, y: 0, width: 1100, height: 800),
            tiles: [.init(name: "Jonathan", frame: .init(x: 10, y: 10, width: 200, height: 150),
                speaking: speaking, muted: false, isSelf: false)],
            hostStart: 100, hostEnd: 100.1, selfNames: selfKnown ? ["Alex"] : [])
    }

    func testAccessibilityNamesRemainSuggestionsWithoutExplicitSpeakingLabels() {
        for speaking in [nil, false] as [Bool?] {
            let batch = GoogleMeetSpeakerObservationProvider.accessibilityBatch(snapshot: snapshot(speaking: speaking), sourceKey: "meet")
            XCTAssertNil(batch.issue)
            XCTAssertEqual(batch.participants, [.init(name: "Jonathan", source: .accessibility)])
            XCTAssertEqual(batch.observations.map(\.active), [false])
            var accumulator = SpeakerObservationAccumulator()
            XCTAssertNil(accumulator.consume(batch, clock: clock()))
            var diagnostics = SpeakerObservationDiagnostics()
            diagnostics.record(batch, interval: nil)
            XCTAssertEqual(diagnostics.lastIssue, .noActiveSpeaker)
            XCTAssertTrue(diagnostics.missingSpeakerNamesExplanation?.contains("manual assignment") == true)
        }
    }

    func testExplicitAccessibilityActivityStillRequiresKnownSelfIdentity() {
        for selfKnown in [true, false] {
            let batch = GoogleMeetSpeakerObservationProvider.accessibilityBatch(
                snapshot: snapshot(speaking: true, selfKnown: selfKnown), sourceKey: "meet")
            XCTAssertEqual(batch.participants, [.init(name: "Jonathan", source: .accessibility)])
            XCTAssertEqual(batch.observations.map(\.active), [selfKnown])
            XCTAssertEqual(batch.issue, selfKnown ? nil : .selfIdentityUnavailable)
            XCTAssertEqual(batch.observations.first?.hostStart ?? 0, 100, accuracy: 0.00001)
            XCTAssertEqual(batch.observations.first?.hostEnd ?? 0, 100.1, accuracy: 0.00001)
        }
    }

    func testAccessibilityBatchPreservesDuplicateMutedAndSharedRoomGuards() {
        var duplicate = snapshot(speaking: true)
        var otherTile = duplicate.tiles[0]; otherTile.frame.origin.x += 300
        duplicate.tiles.append(otherTile)
        let duplicateBatch = GoogleMeetSpeakerObservationProvider.accessibilityBatch(snapshot: duplicate, sourceKey: "meet")
        XCTAssertTrue(duplicateBatch.observations.allSatisfy { !$0.unique })
        XCTAssertEqual(duplicateBatch.participants.count, 1)
        var room = snapshot(speaking: true)
        room.tiles[0].sharedRoom = true
        let roomBatch = GoogleMeetSpeakerObservationProvider.accessibilityBatch(snapshot: room, sourceKey: "meet")
        XCTAssertEqual(roomBatch.observations.first?.unique, false)
        var muted = snapshot(speaking: true)
        muted.tiles[0].muted = true
        let mutedBatch = GoogleMeetSpeakerObservationProvider.accessibilityBatch(snapshot: muted, sourceKey: "meet")
        var accumulator = SpeakerObservationAccumulator()
        XCTAssertNil(accumulator.consume(mutedBatch, clock: clock()))
    }

    func testParticipantControlsAndNamesEstablishTilesWithoutPossessiveLabels() {
        XCTAssertEqual(MeetingParticipantTileResolver.name(ownLabels: ["Alice"], descendantLabels: ["More options for Alice"]), "Alice")
        XCTAssertEqual(MeetingParticipantTileResolver.name(ownLabels: [], descendantLabels: ["Alice", "Pin Alice to your main screen"]), "Alice")
        XCTAssertEqual(MeetingParticipantTileResolver.name(ownLabels: ["Video of Alice"], descendantLabels: []), "Alice")
        XCTAssertNil(MeetingParticipantTileResolver.name(ownLabels: ["Quarterly report"], descendantLabels: ["Alice", "Speaking"]))
        XCTAssertNil(MeetingParticipantTileResolver.name(ownLabels: [], descendantLabels: ["Alice", "Bob", "Mute Alice", "Mute Bob"]))
        XCTAssertNil(MeetingParticipantTileResolver.name(ownLabels: [], descendantLabels: ["More options for Alice", "Bob"]))
    }

    func testUnstructuredTileTextIsNotPromotedWithoutTheRetiredOCRVerification() {
        XCTAssertNil(MeetingParticipantTileResolver.name(ownLabels: [], descendantLabels: ["Jonathan"]))
        XCTAssertNil(MeetingParticipantTileResolver.name(ownLabels: ["Jonathan"], descendantLabels: ["J", "Jonathan"]))
        XCTAssertNil(MeetingParticipantTileResolver.name(ownLabels: ["Presentation"], descendantLabels: ["Quarterly report"]))
    }

    func testSelfViewControlsAndRosterSuffixIdentifyTheLocalTile() {
        let frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        for control in ["Reframe", "Backgrounds and effects",
                        "Others might see more of your background. Click to view your full video."] {
            XCTAssertTrue(MeetingParticipantTileResolver.tile(name: "Alex", frame: frame, labels: [control]).isSelf)
        }
        XCTAssertEqual(MeetingParticipantTileResolver.selfName("Alex (You)"), "Alex")
        XCTAssertNil(MeetingParticipantTileResolver.selfName("Alex"))
        XCTAssertEqual(MeetingParticipantTileResolver.selfName(rowLabels: ["Alex"], descendantLabels: ["Alex", "(You)"]), "Alex")
        XCTAssertNil(MeetingParticipantTileResolver.selfName(rowLabels: ["Alex", "Sam"], descendantLabels: ["(You)"]))
        XCTAssertNil(MeetingParticipantTileResolver.selfName(rowLabels: ["Alex"], descendantLabels: ["Alex"]))
        XCTAssertFalse(MeetingParticipantTileResolver.tile(name: "Alex", frame: frame, labels: ["More options for Alex"]).isSelf)
    }

    func testParticipantPresenceNeverCreatesSpeakingEvidence() {
        let presence = MeetingParticipantName(name: "Jonathan", source: .accessibility)
        let batch = MeetingSpeakerObservationBatch(sourceKey: "meet", observations: [], participants: [presence])
        var accumulator = SpeakerObservationAccumulator()
        XCTAssertNil(accumulator.consume(batch, clock: clock()))
        XCTAssertNil(accumulator.consume(batch, clock: clock()))
        let merged = MeetingParticipantName.merging([presence], [.init(name: "Jonathan", source: .accessibility, isSelf: true)])
        XCTAssertEqual(merged.count, 1)
        XCTAssertTrue(merged[0].isSelf)
        XCTAssertEqual(merged[0].source, .accessibility)
    }

    func testHistoricalOCRNamesAndFrameDiagnosticsStillDecode() throws {
        let presence = try JSONDecoder().decode(MeetingParticipantName.self,
            from: Data(#"{"name":"Jonathan","source":"ocr","isSelf":false}"#.utf8))
        XCTAssertEqual(presence.source, .ocr)
        let merged = MeetingParticipantName.merging([presence], [.init(name: "Jonathan", source: .accessibility, isSelf: true)])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].source, .ocr)
        XCTAssertTrue(merged[0].isSelf)
        for issue in [SpeakerObservationIssue.screenPermission, .waitingForFrame, .frameUnavailable] {
            XCTAssertEqual(try JSONDecoder().decode(SpeakerObservationIssue.self,
                from: JSONEncoder().encode(issue)), issue)
        }
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
