import XCTest
@testable import LokalBot

final class MeetingNoteExportServiceTests: XCTestCase {
    private var base: URL!
    private var library: URL!
    private var vault: URL!
    private var calendar: Calendar!
    private var service: MeetingNoteExportService!
    private let meetingID = UUID(uuidString: "4F7C2A91-0000-4000-8000-000000000001")!
    private let noteName = "2026-09-29 Atlas release sync (4f7c2a91).md"
    private let summary = """
        ## TL;DR

        - **You:** Atlas ships Friday. — [00:00:00]

        ## Action items

        ### Me
        - [ ] Send the release notes

        ### Others
        - [ ] Ana: Update the install guide — due Thursday

        ## Open questions

        None
        """

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingNoteExport-\(UUID().uuidString)", isDirectory: true)
        library = base.appendingPathComponent("library", isDirectory: true)
        vault = base.appendingPathComponent("vault", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Podgorica"))
        service = MeetingNoteExportService(root: library, calendar: calendar)

        try MeetingFixture.write([
            .init(id: meetingID, title: "Atlas release sync",
                  startedAt: Date(timeIntervalSince1970: 1_790_668_800),
                  summary: summary,
                  transcriptLines: ["Atlas ships Friday.", "I'll update the install guide by Thursday."]),
        ], under: library)
        try updateMeeting { $0.participantNameHints = ["Ana Petrović"] }
        let send = MeetingOutcomes.ActionItem(text: "Send the release notes", owner: "Me", isForUser: true)
        let guide = MeetingOutcomes.ActionItem(
            text: "Update the install guide", owner: "Ana", due: "Thursday", isForUser: false)
        try MeetingOutcomes(actionItems: [send, guide]).write(to: meetingFolder)
        var state = MeetingOutcomeState()
        state.actions[send.id] = .init(status: .done, userEdited: true)
        try MeetingOutcomeStore.writeState(state, to: meetingFolder)
        try trackProject("Atlas")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: base)
        super.tearDown()
    }

    func testObsidianNoteHasPropertiesLinksAndTheActionsAsLokalBotShowsThem() throws {
        let report = try service.export(configuration(.obsidian))

        let url = vault.appendingPathComponent(noteName)
        XCTAssertEqual(report.written, [url])
        XCTAssertEqual(report.failures, [])
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("""
            ---
            aliases:
              - "Atlas release sync"
            date: 2026-09-29
            time: "10:00"
            duration: "30 min"
            app: "Fixture"
            people:
              - "[[Ana Petrović]]"
            projects:
              - "[[Atlas]]"
            tags:
              - lokalbot/meeting
            lokalbot-id: "4f7c2a91"
            source: LokalBot
            ---

            \(MeetingNoteExportService.generatedFileMarker)

            # Atlas release sync

            ## TL;DR
            """), text)
        XCTAssertEqual(try line(containing: "release notes", in: text), "- [x] Send the release notes")
        XCTAssertTrue(text.contains("- [ ] Ana: Update the install guide — due Thursday"))
        XCTAssertTrue(text.contains("## Open questions"))
        XCTAssertTrue(text.contains("## Transcript\n\nAtlas ships Friday."))

        for file in [url, GeneratedFileWriter.sidecarURL(for: url)] {
            let mode = try XCTUnwrap(FileManager.default.attributesOfItem(
                atPath: file.path)[.posixPermissions] as? NSNumber).intValue & 0o777
            XCTAssertEqual(mode, 0o600, file.lastPathComponent)
        }
    }

    func testMarkdownAndLogseqNotesUseTheirOwnSyntax() throws {
        let markdownFolder = vault.appendingPathComponent("markdown", isDirectory: true)
        _ = try service.export(configuration(.markdown, to: markdownFolder))
        let markdown = try String(contentsOf: markdownFolder.appendingPathComponent(noteName), encoding: .utf8)
        XCTAssertTrue(markdown.hasPrefix(MeetingNoteExportService.generatedFileMarker + "\n\n# Atlas release sync\n\n"))
        XCTAssertTrue(markdown.contains("- **When:** September 29, 2026, 10:00 · 30 min"))
        XCTAssertTrue(markdown.contains("- **People:** Ana Petrović"))
        XCTAssertTrue(markdown.contains("- **Projects:** Atlas"))
        XCTAssertTrue(markdown.contains("- **Meeting:** `4f7c2a91`"))
        XCTAssertFalse(markdown.contains("[["))

        let logseqFolder = vault.appendingPathComponent("logseq", isDirectory: true)
        _ = try service.export(configuration(.logseq, to: logseqFolder))
        let logseq = try String(contentsOf: logseqFolder.appendingPathComponent(noteName), encoding: .utf8)
        XCTAssertTrue(logseq.hasPrefix("""
            date:: 2026-09-29
            people:: [[Ana Petrović]]
            projects:: [[Atlas]]
            tags:: lokalbot, meeting
            lokalbot-id:: 4f7c2a91
            source:: LokalBot

            \(MeetingNoteExportService.generatedFileMarker)
            """), logseq)
        XCTAssertEqual(try line(containing: "release notes", in: logseq), "- DONE Send the release notes")
        XCTAssertTrue(logseq.contains("- TODO Ana: Update the install guide — due Thursday"))
    }

    func testRefreshesAnUnchangedNoteButLeavesAnEditedOneAlone() throws {
        _ = try service.export(configuration(.obsidian))
        let url = vault.appendingPathComponent(noteName)

        try "## TL;DR\n\n- The launch moved to Monday.".write(
            to: meetingFolder.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
        let refreshed = try service.export(configuration(.obsidian))
        XCTAssertEqual(refreshed.written, [url])
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("The launch moved to Monday."))

        try "My own notes on the launch".write(to: url, atomically: true, encoding: .utf8)
        try "## TL;DR\n\n- The launch moved again.".write(
            to: meetingFolder.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
        let report = try service.export(configuration(.obsidian))

        XCTAssertEqual(report.written, [])
        XCTAssertEqual(report.failures, [], "an edited note is the person's, not a failure")
        XCTAssertNotNil(report.fingerprints[meetingID])
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "My own notes on the launch")
    }

    func testDeletedOrMovedNoteIsNotWrittenAgain() throws {
        _ = try service.export(configuration(.obsidian))
        let url = vault.appendingPathComponent(noteName)
        let archive = vault.appendingPathComponent("Archive", isDirectory: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url, to: archive.appendingPathComponent(noteName))

        let afterMove = try service.export(configuration(.obsidian))
        XCTAssertEqual(afterMove.written, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        try FileManager.default.removeItem(at: archive)
        let afterDelete = try service.export(configuration(.obsidian))
        XCTAssertEqual(afterDelete.written, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testNoteKeepsItsNameWhenTheMeetingIsRenamed() throws {
        _ = try service.export(configuration(.obsidian))
        try updateMeeting { $0.title = "Atlas launch review" }

        let report = try service.export(configuration(.obsidian))

        let url = vault.appendingPathComponent(noteName)
        XCTAssertEqual(report.written, [url])
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("  - \"Atlas launch review\"\n"))
        XCTAssertTrue(text.contains("# Atlas launch review\n"))
        XCTAssertEqual(try markdownFiles(), [noteName])
    }

    func testUnchangedMeetingsAreSkippedUntilTheirSourcesChange() throws {
        let first = try service.export(configuration(.obsidian))
        let url = vault.appendingPathComponent(noteName)
        // Without the note and its sidecar, a meeting that is looked at gets
        // a new note; one that is skipped does not.
        try FileManager.default.removeItem(at: url)
        try FileManager.default.removeItem(at: GeneratedFileWriter.sidecarURL(for: url))

        let second = try service.export(configuration(.obsidian), previous: first.fingerprints)
        XCTAssertEqual(second.written, [])
        XCTAssertEqual(second.fingerprints, first.fingerprints)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        try MeetingOutcomeStore.writeState(MeetingOutcomeState(), to: meetingFolder)
        let third = try service.export(configuration(.obsidian), previous: second.fingerprints)
        XCTAssertEqual(third.written, [url], "reopening the action changed the meeting's sources")
        XCTAssertEqual(try line(containing: "release notes", in: String(contentsOf: url, encoding: .utf8)),
                       "- [ ] Send the release notes")
    }

    func testTranscriptCanBeLeftOutAndCredentialsAreRedacted() throws {
        try "## TL;DR\n\n- Use the staging password: hunter2-staging-secret for the demo.".write(
            to: meetingFolder.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)

        _ = try service.export(configuration(.obsidian, includesTranscript: false))

        let text = try String(contentsOf: vault.appendingPathComponent(noteName), encoding: .utf8)
        XCTAssertFalse(text.contains("## Transcript"))
        XCTAssertFalse(text.contains("Atlas ships Friday."))
        XCTAssertFalse(text.contains("hunter2-staging-secret"))
        XCTAssertTrue(text.contains("[REDACTED]"))
    }

    func testOnlyFinishedMeetingsWithNotesAreExported() throws {
        let recording = UUID()
        let transcriptOnly = UUID()
        try MeetingFixture.write([
            .init(id: recording, title: "Still recording", startedAt: Date(timeIntervalSince1970: 1_790_700_000),
                  summary: "## TL;DR\n\n- Live."),
            .init(id: transcriptOnly, title: "Not summarized", startedAt: Date(timeIntervalSince1970: 1_790_710_000),
                  transcriptLines: ["Only a transcript."]),
        ], under: library)
        try updateMeeting(recording) { $0.endedAt = nil }

        _ = try service.export(configuration(.markdown, includesTranscript: false))
        XCTAssertEqual(try markdownFiles(), [noteName])

        _ = try service.export(configuration(.markdown, includesTranscript: true))
        XCTAssertEqual(try markdownFiles().count, 2)
        XCTAssertFalse(try markdownFiles().contains { $0.contains("Still recording") })
    }

    func testFileNamesLeaveOutCharactersVaultsReject() throws {
        var meeting = try XCTUnwrap(SessionLookup.loadAllMeetings(root: library).first)
        meeting.title = "..Q3 / Q4: plan [draft] #2 | v1?"
        XCTAssertEqual(service.fileName(for: meeting), "2026-09-29 Q3 Q4 plan draft 2 v1 (4f7c2a91).md")
        XCTAssertEqual(MeetingNoteExportService.meetingID(inFileName: service.fileName(for: meeting)), "4f7c2a91")
        XCTAssertNil(MeetingNoteExportService.meetingID(inFileName: "Weekly notes (draft).md"))

        meeting.title = String(repeating: "Long title ", count: 20)
        let name = service.fileName(for: meeting)
        XCTAssertLessThanOrEqual(name.count, "2026-09-29  (4f7c2a91).md".count + 80)
        XCTAssertFalse(name.contains("  ("))
    }

    func testTitlesAreQuotedInProperties() throws {
        try updateMeeting { $0.title = #"Q3: "Atlas" \ review"# }

        _ = try service.export(configuration(.obsidian))

        let name = try XCTUnwrap(try markdownFiles().first)
        let text = try String(contentsOf: vault.appendingPathComponent(name), encoding: .utf8)
        XCTAssertTrue(text.contains(#"  - "Q3: \"Atlas\" \\ review""#), text)
    }

    // MARK: - Helpers

    private var meetingFolder: URL {
        library.appendingPathComponent("meetings/2026/07/4f7c2a91-fixture", isDirectory: true)
    }

    private func configuration(_ format: DailyMemoryExportKind, to folder: URL? = nil,
                               includesTranscript: Bool = true) -> MeetingNoteExportConfiguration {
        MeetingNoteExportConfiguration(
            destinationDirectory: folder ?? vault, format: format, includesTranscript: includesTranscript)
    }

    private func updateMeeting(_ id: UUID? = nil, _ change: (inout Meeting) -> Void) throws {
        let meetings = try SessionLookup.loadAllMeetings(root: library, includeMergedSources: true)
        var meeting = try XCTUnwrap(meetings.first { $0.id == (id ?? meetingID) })
        change(&meeting)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(meeting).write(
            to: library.appendingPathComponent(meeting.relativePath).appendingPathComponent("meta.json"))
    }

    private func trackProject(_ name: String) throws {
        let folder = library.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let curation = ProjectCuration(tracked: [
            .init(id: UUID(), name: name, otherNames: [], createdAt: Date(timeIntervalSince1970: 1_790_000_000)),
        ])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(curation).write(to: folder.appendingPathComponent(ProjectCuration.fileName))
    }

    private func line(containing needle: String, in text: String) throws -> String {
        try XCTUnwrap(text.components(separatedBy: "\n").first { $0.contains(needle) })
    }

    private func markdownFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: vault.path)
            .filter { $0.hasSuffix(".md") && !$0.hasPrefix(".") }
            .sorted()
    }
}
