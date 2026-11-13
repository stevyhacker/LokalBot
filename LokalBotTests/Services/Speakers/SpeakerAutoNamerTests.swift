import XCTest
@testable import LokalBot

/// Attendance never identifies a voice, including a single invited guest.
final class SpeakerAutoNamerTests: XCTestCase {

    private func transcript(speakers: [String]) -> Transcript {
        Transcript(segments: speakers.enumerated().map { index, speaker in
            .init(start: Double(index * 10), end: Double(index * 10 + 5),
                  speaker: speaker, text: "Segment \(index).", confidence: nil)
        }, engine: "test")
    }

    private func participants(_ names: [String]) -> [CalendarParticipantIdentity] {
        names.compactMap { CalendarParticipantIdentity(name: $0, emailAddress: nil) }
    }

    func testSingleRemoteTrackWithOneAttendeeRemainsUnnamed() {
        let named = SpeakerAutoNamer.applyingAliases(
            to: transcript(speakers: ["me", "them", "me", "them"]),
            participants: participants(["Ana Petrović"]))
        XCTAssertNil(named.speakerAliases["them"])
        XCTAssertNil(named.calendarIdentityID(for: "them"))
        XCTAssertEqual(named.displaySpeaker(for: "them"), "Them")
        // Raw labels stay untouched — only the alias layer changes.
        XCTAssertTrue(named.segments.allSatisfy { $0.speaker == "me" || $0.speaker == "them" })
    }

    func testMultipleAttendeesAreSkipped() {
        let named = SpeakerAutoNamer.applyingAliases(
            to: transcript(speakers: ["me", "them"]),
            participants: participants(["Ana Petrović", "Marko Marković"]))
        XCTAssertTrue(named.speakerAliases.isEmpty)
    }

    func testNumberedSpeakersAreSkipped() {
        let named = SpeakerAutoNamer.applyingAliases(
            to: transcript(speakers: ["me", "them 1", "them 2"]),
            participants: participants(["Ana Petrović"]))
        XCTAssertTrue(named.speakerAliases.isEmpty)
    }

    func testExistingAliasIsPreserved() {
        var existing = transcript(speakers: ["me", "them"])
        existing.setSpeakerAlias("Hand-Renamed", for: "them")
        let named = SpeakerAutoNamer.applyingAliases(
            to: existing, participants: participants(["Ana Petrović"]))
        XCTAssertEqual(named.speakerAliases["them"], "Hand-Renamed")
    }

    func testNoHintsOrBlankHintsAreSkipped() {
        let base = transcript(speakers: ["me", "them"])
        XCTAssertTrue(SpeakerAutoNamer.applyingAliases(
            to: base, participants: []).speakerAliases.isEmpty)
        XCTAssertTrue(SpeakerAutoNamer.applyingAliases(
            to: base, participants: participants(["   "])).speakerAliases.isEmpty)
    }

    func testMicOnlyTranscriptWithoutRemoteSpeakerIsSkipped() {
        let named = SpeakerAutoNamer.applyingAliases(
            to: transcript(speakers: ["me", "me"]),
            participants: participants(["Ana Petrović"]))
        XCTAssertTrue(named.speakerAliases.isEmpty)
    }

    func testDuplicateEmailRepresentsOneUnambiguousAttendee() throws {
        let emailOnly = try XCTUnwrap(CalendarParticipantIdentity(
            id: "first", name: nil, emailAddress: "ana@example.com"))
        let named = try XCTUnwrap(CalendarParticipantIdentity(
            id: "second", name: "Ana Petrović", emailAddress: "ANA@example.com"))

        let result = SpeakerAutoNamer.applyingAliases(
            to: transcript(speakers: ["me", "them"]),
            participants: [emailOnly, named])

        XCTAssertEqual(result.displaySpeaker(for: "them"), "Them")
        XCTAssertNil(result.calendarIdentityID(for: "them"))
    }

    func testEmailWithoutDisplayNameIsNeverUsedAsTranscriptAlias() throws {
        let attendee = try XCTUnwrap(CalendarParticipantIdentity(
            id: "attendee", name: nil, emailAddress: "ana@example.com"))

        let result = SpeakerAutoNamer.applyingAliases(
            to: transcript(speakers: ["me", "them"]),
            participants: [attendee])

        XCTAssertTrue(result.speakerAliases.isEmpty)
        XCTAssertFalse(result.markdown.contains("ana@example.com"))
        XCTAssertEqual(attendee.suggestedSpeakerName, "Ana")
        XCTAssertFalse(result.markdown.contains("Ana"))
    }
}
