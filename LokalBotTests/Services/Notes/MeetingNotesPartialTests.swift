import XCTest
@testable import LokalBot

final class MeetingNotesPartialTests: XCTestCase {
    private let transcript = Transcript(segments: [
        .init(start: 0, end: 5, speaker: "me", text: "I will send the proposal."),
        .init(start: 5, end: 10, speaker: "them", text: "The release is on Friday."),
    ], engine: "fixture")

    private func fixture() throws -> (root: URL, folder: URL, meeting: Meeting) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("meeting")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try JSONEncoder().encode(transcript).write(to: folder.appendingPathComponent("transcript.json"))
        let meeting = Meeting(id: UUID(), title: "Planning", appName: "Zoom",
            startedAt: Date(), endedAt: Date(), relativePath: "meeting")
        return (root, folder, meeting)
    }

    private var partial: MeetingNotesPartial {
        var outcomes = MeetingOutcomes(actionItems: [
            .init(text: "Send the proposal", owner: "Me", isForUser: true,
                  citations: [.init(segmentID: transcript.segmentID(at: 0), start: 0, end: 5,
                                    speaker: "me", excerpt: transcript.segments[0].text)]),
        ])
        outcomes.transcriptRevision = transcript.evidenceRevision
        return .init(transcriptRevision: transcript.evidenceRevision,
            summary: "## TL;DR\n\n- The release is on Friday.", outcomes: outcomes, completedParts: 1, totalParts: 2)
    }

    private func writeLegacy(in folder: URL) throws {
        let claims = [SummaryClaimEvidence.Claim(section: "Key points", text: "The release is on Friday.",
            speakerID: "them", segmentID: transcript.segmentID(at: 1), quote: transcript.segments[1].text)]
        try SummaryClaimEvidence.savePartial(claims, transcript: transcript, in: folder)
        try JSONEncoder().encode(partial.outcomes).write(to: folder.appendingPathComponent("outcomes.partial.json"))
        try Data("# Partial notes — 1/2 parts verified\n\nOutdated rendering".utf8)
            .write(to: folder.appendingPathComponent("summary.partial.md"))
    }

    func testPartialNotesAndActionsLoadWithoutPublishingCompletedOutcomes() throws {
        let fixture = try fixture()
        try partial.write(in: fixture.folder)
        let saved = try XCTUnwrap(MeetingNotesPartial.load(in: fixture.folder, transcript: transcript))
        XCTAssertEqual(saved.completedParts, 1)
        XCTAssertEqual(saved.totalParts, 2)
        XCTAssertNotNil(SummaryPresentation.recap(saved.summary))
        XCTAssertEqual(saved.projection(for: fixture.meeting, in: fixture.folder).actionReferences.count, 1)
        XCTAssertNil(MeetingOutcomeProjection.load(for: fixture.meeting, root: fixture.root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.folder.appendingPathComponent("outcomes.json").path))
    }

    func testLegacyPartialResultsBecomeVisibleWithoutReprocessing() throws {
        let fixture = try fixture()
        try writeLegacy(in: fixture.folder)
        let saved = try XCTUnwrap(MeetingNotesPartial.load(in: fixture.folder, transcript: transcript))
        XCTAssertEqual(saved.outcomes.actionItems.count, 1)
        XCTAssertEqual(saved.progressLabel, "Partial notes · 1 of 2 parts complete")
        XCTAssertTrue(saved.summary.contains("The release is on Friday."))
        XCTAssertFalse(saved.summary.contains("Outdated rendering"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.folder.appendingPathComponent(MeetingNotesPartial.fileName).path),
                       "reading legacy progress must not rewrite the library")
    }

    func testCanonicalSnapshotDoesNotMixWithLegacyFilesFromAnotherSave() throws {
        let fixture = try fixture()
        try writeLegacy(in: fixture.folder)
        var snapshot = partial
        snapshot.summary = "Current atomic snapshot"
        try snapshot.write(in: fixture.folder)
        let saved = try XCTUnwrap(MeetingNotesPartial.load(in: fixture.folder, transcript: transcript))
        XCTAssertEqual(saved.summary, "Current atomic snapshot")
    }

    func testMalformedCanonicalSnapshotCannotFallBackToUnrelatedLegacyData() throws {
        let fixture = try fixture()
        try writeLegacy(in: fixture.folder)
        try Data("interrupted".utf8).write(to: fixture.folder.appendingPathComponent(MeetingNotesPartial.fileName))
        XCTAssertNil(MeetingNotesPartial.load(in: fixture.folder, transcript: transcript))
    }

    func testSpeakerOrTranscriptChangeRejectsBothPartialFormats() throws {
        let fixture = try fixture()
        var changed = transcript
        changed.confirmSpeaker("me", isUser: false)
        try writeLegacy(in: fixture.folder)
        XCTAssertNil(MeetingNotesPartial.load(in: fixture.folder, transcript: changed))
        try partial.write(in: fixture.folder)
        XCTAssertNil(MeetingNotesPartial.load(in: fixture.folder, transcript: changed))
    }

    func testPartialOutcomeRevisionMustAlsoMatch() throws {
        let fixture = try fixture()
        var snapshot = partial
        snapshot.outcomes.transcriptRevision = "older transcript"
        try snapshot.write(in: fixture.folder)
        XCTAssertNil(MeetingNotesPartial.load(in: fixture.folder, transcript: transcript))
        try FileManager.default.removeItem(at: fixture.folder.appendingPathComponent(MeetingNotesPartial.fileName))
        try writeLegacy(in: fixture.folder)
        try JSONEncoder().encode(snapshot.outcomes).write(to: fixture.folder.appendingPathComponent("outcomes.partial.json"))
        XCTAssertNil(MeetingNotesPartial.load(in: fixture.folder, transcript: transcript))
    }

    func testNewCompletePublicationSupersedesAnUnremovedCheckpoint() throws {
        let fixture = try fixture()
        try partial.write(in: fixture.folder)
        try partial.outcomes.write(to: fixture.folder)
        let final = fixture.folder.appendingPathComponent("summary.md")
        try Data("Complete notes".utf8).write(to: final)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: final.path)
        XCTAssertNil(MeetingNotesPartial.load(in: fixture.folder, transcript: transcript))
    }

    func testNewPartialResultsAreVisibleWithoutOverwritingAnEarlierCompletePublication() throws {
        let fixture = try fixture()
        try partial.outcomes.write(to: fixture.folder)
        let final = fixture.folder.appendingPathComponent("summary.md")
        try Data("Previous complete notes".utf8).write(to: final)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-10)], ofItemAtPath: final.path)
        try partial.write(in: fixture.folder)
        XCTAssertNotNil(MeetingNotesPartial.load(in: fixture.folder, transcript: transcript))
        XCTAssertEqual(try String(contentsOf: final, encoding: .utf8), "Previous complete notes")
    }

    func testPartialProjectionRetainsUserCorrectionsWithoutChangingStateOnDisk() throws {
        let fixture = try fixture()
        let action = try XCTUnwrap(partial.outcomes.actionItems.first)
        var state = MeetingOutcomeState()
        state.actions[action.id] = .init(status: .done, textCorrection: "Send the reviewed proposal", userEdited: true)
        try MeetingOutcomeStore.writeState(state, to: fixture.folder)
        try partial.outcomes.write(to: fixture.folder)
        let projection = partial.projection(for: fixture.meeting, in: fixture.folder)
        XCTAssertEqual(projection.actionReferences.first?.text, "Send the reviewed proposal")
        XCTAssertEqual(projection.actionReferences.first?.status, .done)
        XCTAssertEqual(MeetingOutcomeStore.loadState(from: fixture.folder), state)
    }

    func testAttributionInvalidationRemovesEveryPartialPresentationArtifact() throws {
        let fixture = try fixture()
        try writeLegacy(in: fixture.folder)
        try partial.write(in: fixture.folder)
        try MeetingAttributionArtifacts.invalidate(in: fixture.folder)
        XCTAssertNil(MeetingNotesPartial.load(in: fixture.folder, transcript: transcript))
        XCTAssertTrue(MeetingAttributionArtifacts.needsRefresh(in: fixture.folder))
        for name in [MeetingNotesPartial.fileName, "summary.partial.md", "outcomes.partial.json", "summary.claims.partial.json"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.folder.appendingPathComponent(name).path))
        }
    }
}
