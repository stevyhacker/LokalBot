import XCTest
@testable import LokalBot

/// Companion records built from a synthetic library: their shape, the data
/// classes and history window, and the privacy exclusions records.md
/// promises.
final class CompanionRecordBuilderTests: XCTestCase {
    private var fixture: CompanionFixtureLibrary!

    override func setUpWithError() throws {
        fixture = try CompanionFixtureLibrary.make()
    }

    override func tearDown() {
        fixture?.remove()
        fixture = nil
    }

    private func body(_ record: CompanionRecord?) throws -> [String: Any] {
        let record = try XCTUnwrap(record)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(record.bodyJSON.utf8)) as? [String: Any])
    }

    private func record(_ records: [CompanionRecord], _ kind: CompanionRecordKind, _ key: String) -> CompanionRecord? {
        records.first { $0.kind == kind && $0.key == key }
    }

    private var designKey: String { fixture.designReview.id.uuidString.lowercased() }

    // MARK: - Privacy

    /// The exclusion contract: no record carries attendee emails, speaker
    /// evidence, calendar identity links, screenshot paths, OCR text, agenda
    /// or meeting links, Dream memory, or Personal Context. Deliberately
    /// leaking any one of them fails this test.
    func testNoRecordContainsExcludedData() throws {
        let records = fixture.records()
        XCTAssertFalse(records.isEmpty)
        for record in records {
            for secret in CompanionFixtureLibrary.secrets {
                XCTAssertFalse(record.bodyJSON.localizedCaseInsensitiveContains(secret),
                               "\(record.kind.rawValue) \(record.key) leaks “\(secret)”")
            }
        }
        // The window title is shared while that class is on…
        XCTAssertTrue(records.contains { $0.bodyJSON.contains(CompanionFixtureLibrary.windowTitleSecret) },
                      "the fixture must exercise window titles")
        // …and appears nowhere once it is off.
        var sharing = CompanionSharing()
        sharing.dataClasses.windowTitles = false
        for record in fixture.records(sharing) {
            XCTAssertFalse(record.bodyJSON.contains(CompanionFixtureLibrary.windowTitleSecret),
                           "\(record.kind.rawValue) \(record.key) leaks a window title")
            XCTAssertFalse(record.bodyJSON.contains("WINDOWTITLE"),
                           "\(record.kind.rawValue) \(record.key) leaks part of a window title")
        }
    }

    func testManifestReportsWhatDevicesReceive() throws {
        var sharing = CompanionSharing(history: .days90, answersQuestions: false)
        sharing.dataClasses.meetings = false
        let json = try XCTUnwrap(CompanionRecordBuilder.manifest(sharing: sharing, macName: "Test Mac"))
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(manifest["schemaVersion"] as? Int, 1)
        XCTAssertEqual(manifest["macName"] as? String, "Test Mac")
        XCTAssertEqual(manifest["historyDays"] as? Int, 90)
        XCTAssertEqual(manifest["askEnabled"] as? Bool, false)
        let classes = try XCTUnwrap(manifest["dataClasses"] as? [String: Bool])
        XCTAssertEqual(classes["meetings"], false)
        // A transcript needs its meeting.
        XCTAssertEqual(classes["transcripts"], false)
        XCTAssertEqual(classes["windowTitles"], true)
        XCTAssertFalse(json.contains(":null"), "optional fields are omitted, never null")
    }

    // MARK: - Meetings

    func testMeetingRecordCarriesCorrectedOutcomesAndDisplayNames() throws {
        let records = fixture.records()
        let meeting = try body(record(records, .meeting, designKey))
        XCTAssertEqual(meeting["id"] as? String, designKey)
        XCTAssertEqual(meeting["title"] as? String, "Design review — onboarding")
        XCTAssertEqual(meeting["day"] as? String, fixture.dayKey)
        XCTAssertEqual(meeting["appName"] as? String, "Zoom")
        XCTAssertEqual(meeting["durationSeconds"] as? Double, 2520)
        XCTAssertEqual(meeting["hasTranscript"] as? Bool, true)
        XCTAssertEqual(meeting["notesMarkdown"] as? String, "- Maya wants to lead the next design review")
        let summary = try XCTUnwrap(meeting["summaryMarkdown"] as? String)
        XCTAssertTrue(summary.hasPrefix("## Recap"), summary)
        XCTAssertFalse(summary.contains("**Model:**"), "the provenance line stays on the Mac")
        let started = try XCTUnwrap(meeting["startedAt"] as? String)
        XCTAssertTrue(started.hasSuffix("Z") && started.contains("."), "UTC with milliseconds: \(started)")

        let actions = try XCTUnwrap(meeting["actions"] as? [[String: Any]])
        let deck = try XCTUnwrap(actions.first { $0["id"] as? String == "act-deck" })
        XCTAssertEqual(deck["owner"] as? String, "You")
        XCTAssertEqual(deck["ownerIsUser"] as? Bool, true)
        XCTAssertEqual(deck["ownerUnclear"] as? Bool, false)
        XCTAssertEqual(deck["status"] as? String, "open")
        XCTAssertEqual(deck["dueText"] as? String, "2026-11-03")
        XCTAssertEqual(deck["dueDate"] as? String, "2026-11-03")
        let citation = try XCTUnwrap((deck["citations"] as? [[String: Any]])?.first)
        XCTAssertEqual(citation["speaker"] as? String, "Maya Chen")
        XCTAssertEqual(citation["start"] as? Double, 721.4)
        let study = try XCTUnwrap(actions.first { $0["id"] as? String == "act-study" })
        XCTAssertEqual(study["status"] as? String, "deferred", "the person's status correction is applied")
        XCTAssertEqual(study["ownerUnclear"] as? Bool, true)
        XCTAssertNil(study["owner"])
        XCTAssertEqual((meeting["decisions"] as? [[String: Any]])?.first?["text"] as? String,
                       "Ship the three-step flow behind a flag first.")
        XCTAssertEqual((meeting["openQuestions"] as? [[String: Any]])?.first?["text"] as? String,
                       "Which five customers go first?")
        let people = try XCTUnwrap(meeting["people"] as? [[String: Any]])
        XCTAssertTrue(people.contains { $0["displayName"] as? String == "Maya Chen" })
        XCTAssertTrue(people.allSatisfy { ($0["id"] as? String)?.hasPrefix("person-") == true })
        let projects = try XCTUnwrap(meeting["projects"] as? [[String: Any]])
        XCTAssertEqual(projects.first?["name"] as? String, "Onboarding")
    }

    func testTranscriptUsesDisplayNamesAndStableColors() throws {
        let transcript = try body(record(fixture.records(), .transcript, designKey))
        XCTAssertEqual(transcript["meetingId"] as? String, designKey)
        let segments = try XCTUnwrap(transcript["segments"] as? [[String: Any]])
        XCTAssertEqual(segments.map { $0["speaker"] as? String }, ["You", "Maya Chen", "Speaker 2"])
        XCTAssertEqual(segments.map { $0["colorIndex"] as? Int }, [0, 1, 2])
        XCTAssertEqual(Set(segments.flatMap(\.keys)), ["start", "end", "speaker", "colorIndex", "text"])
    }

    func testColorIndexWrapsThePaletteAndMarksUnclearVoices() {
        XCTAssertEqual(CompanionRecordBuilder.colorIndex(0, speaker: "me"), 0)
        XCTAssertEqual(CompanionRecordBuilder.colorIndex(7, speaker: "them 7"), 7)
        XCTAssertEqual(CompanionRecordBuilder.colorIndex(8, speaker: "them 8"), 1)
        XCTAssertEqual(CompanionRecordBuilder.colorIndex(3, speaker: "them unclear"), -1)
    }

    func testMergedSourcesTheSampleAndUnfinishedMeetingsAreNotShared() throws {
        let keys = Set(fixture.records().filter { $0.kind == .meeting }.map(\.key))
        XCTAssertTrue(keys.contains(fixture.mergedParent.id.uuidString.lowercased()))
        XCTAssertFalse(keys.contains(fixture.mergedSource.id.uuidString.lowercased()))
        XCTAssertFalse(keys.contains(fixture.sampleMeeting.id.uuidString.lowercased()))
    }

    // MARK: - Classes and history

    func testDisabledClassesBuildNoRecords() {
        var sharing = CompanionSharing()
        sharing.dataClasses = .init(meetings: false, transcripts: true, digests: false, timeline: false,
                                    windowTitles: true, people: false, projects: false)
        XCTAssertEqual(fixture.records(sharing), [])

        sharing.dataClasses = .all
        sharing.dataClasses.transcripts = false
        sharing.dataClasses.people = false
        let records = fixture.records(sharing)
        XCTAssertFalse(records.contains { $0.kind == .transcript })
        XCTAssertFalse(records.contains { $0.kind == .person })
        XCTAssertTrue(records.contains { $0.kind == .meeting })
        XCTAssertTrue(records.contains { $0.kind == .project })
        let meeting = records.first { $0.kind == .meeting && $0.key == designKey }
        XCTAssertTrue(meeting?.bodyJSON.contains("\"hasTranscript\":false") == true)
    }

    func testHistoryWindowLeavesOlderRecordsOut() {
        let olderKey = fixture.olderMeeting.id.uuidString.lowercased()
        let olderDay = DreamDay.key(for: fixture.olderMeeting.startedAt, calendar: fixture.calendar)
        let all = fixture.records()
        XCTAssertNotNil(record(all, .meeting, olderKey))
        XCTAssertNotNil(record(all, .day, olderDay))
        let recent = fixture.records(CompanionSharing(history: .days30))
        XCTAssertNil(record(recent, .meeting, olderKey))
        XCTAssertNil(record(recent, .day, olderDay))
        XCTAssertNotNil(record(recent, .meeting, designKey))
    }

    // MARK: - Days

    func testDayRecordHasDigestSectionsTimelineAndScreenTimes() throws {
        let day = try body(record(fixture.records(), .day, fixture.dayKey))
        XCTAssertEqual(day["date"] as? String, fixture.dayKey)
        let digest = try XCTUnwrap(day["digest"] as? [String: Any])
        let markdown = try XCTUnwrap(digest["markdown"] as? String)
        XCTAssertFalse(markdown.contains("[screen:"), markdown)
        XCTAssertFalse(markdown.contains("Full activity log"), "the raw evidence log stays on the Mac")
        let shot = fixture.day.addingTimeInterval(2000)
        let parts = fixture.calendar.dateComponents([.hour, .minute], from: shot)
        let stamp = String(format: "screen moment at %02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
        XCTAssertTrue(markdown.contains(stamp), markdown)
        XCTAssertEqual(digest["userEdited"] as? Bool, true, "a journal without generation metadata is the person's")
        let sections = try XCTUnwrap(digest["sections"] as? [String: [String]])
        XCTAssertEqual(sections["highlights"]?.count, 2)
        XCTAssertEqual(sections["tasks"], ["Send the pricing deck"])
        XCTAssertEqual(sections["decisions"], ["Ship behind a feature flag first."])
        XCTAssertEqual(sections["blockers"], ["Waiting on legal counsel."])

        let timeline = try XCTUnwrap(day["timeline"] as? [String: Any])
        let sessions = try XCTUnwrap(timeline["sessions"] as? [[String: Any]])
        XCTAssertEqual(Set(sessions.compactMap { $0["kind"] as? String }), ["work", "agent", "meeting"])
        let meetingSession = try XCTUnwrap(sessions.first { $0["meetingId"] as? String == designKey })
        XCTAssertEqual(meetingSession["kind"] as? String, "meeting")
        XCTAssertGreaterThan(timeline["trackedSeconds"] as? Double ?? 0, 0)
        let moments = try XCTUnwrap(timeline["savedMoments"] as? [[String: Any]])
        XCTAssertEqual(moments.first?["label"] as? String, "Pricing table idea")
        XCTAssertEqual((day["meetingIds"] as? [String])?.contains(designKey), true)
        let byApp = try XCTUnwrap(timeline["byApp"] as? [[String: Any]])
        XCTAssertEqual(byApp.first?["name"] as? String, "Numbers")
    }

    func testScreenCitationRewriteDropsMissingCaptures() {
        let calendar = Calendar(identifier: .gregorian)
        let time = calendar.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 14, minute: 32))!
        let text = CompanionDigestText.rewritingScreenCitations(
            "Drafted the tiers [screen:7]. Gone [screen:9]. Bare [screen].",
            time: { $0 == 7 ? time : nil }, calendar: calendar)
        XCTAssertEqual(text, "Drafted the tiers (screen moment at 14:32). Gone. Bare.")
    }

    // MARK: - Release fixtures

    /// Every committed release's library (0.6.2 … current) builds records
    /// that decode as schema v1, one meeting record per own finished meeting.
    func testEveryReleaseFixtureBuildsSchemaRecords() throws {
        let root = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "upgrade", withExtension: nil, subdirectory: "Fixtures"))
        let versions = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("library").path) }
        guard !versions.isEmpty else { throw XCTSkip("no upgrade fixtures committed yet") }
        let decoder = JSONDecoder()
        for version in versions {
            let name = version.lastPathComponent
            let library = FileManager.default.temporaryDirectory
                .appendingPathComponent("companion-upgrade-\(name)-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.copyItem(at: version.appendingPathComponent("library"), to: library)
            defer { try? FileManager.default.removeItem(at: library) }
            let loaded = CompanionLibrary.load(root: library, scope: CompanionSharing().recordScope)
            let records = CompanionRecordBuilder(
                library: loaded,
                activity: ActivityStore(databaseURL: library.appendingPathComponent("lokalbotv3.sqlite"),
                                        readOnly: true)).allRecords()
            let meetings = records.filter { $0.kind == .meeting }
            XCTAssertFalse(meetings.isEmpty, name)
            XCTAssertEqual(meetings.count, loaded.meetings.count, name)
            for record in records {
                let data = Data(record.bodyJSON.utf8)
                switch record.kind {
                case .meeting: XCTAssertNoThrow(try decoder.decode(CompanionMeetingBody.self, from: data), name)
                case .transcript: XCTAssertNoThrow(try decoder.decode(CompanionTranscriptBody.self, from: data), name)
                case .day: XCTAssertNoThrow(try decoder.decode(CompanionDayBody.self, from: data), name)
                case .person: XCTAssertNoThrow(try decoder.decode(CompanionPersonBody.self, from: data), name)
                case .project: XCTAssertNoThrow(try decoder.decode(CompanionProjectBody.self, from: data), name)
                case .manifest: XCTFail("the manifest is published on its own")
                }
                XCTAssertFalse(record.bodyJSON.contains(":null"), "\(name) \(record.kind.rawValue) has a null field")
                XCTAssertFalse(record.bodyJSON.contains("[screen:"), "\(name) \(record.kind.rawValue) has a screen id")
            }
        }
    }

    // MARK: - People and projects

    func testPeopleAndProjectsCarryNamesWorkAndMeetings() throws {
        let records = fixture.records()
        let people = records.filter { $0.kind == .person }
        let maya = try XCTUnwrap(people.first { $0.bodyJSON.contains("\"displayName\":\"Maya Chen\"") })
        let mayaBody = try body(maya)
        XCTAssertEqual(mayaBody["id"] as? String, maya.key)
        XCTAssertTrue((mayaBody["meetingIds"] as? [String])?.contains(designKey) == true)

        let projectKey = fixture.projectID.uuidString.lowercased()
        let project = try body(record(records, .project, projectKey))
        XCTAssertEqual(project["name"] as? String, "Onboarding")
        let standing = try XCTUnwrap(project["whereItStands"] as? String)
        XCTAssertTrue(standing.contains("Onboarding is on track."))
        XCTAssertTrue(standing.contains("Three steps agreed."))
        XCTAssertTrue((project["meetingIds"] as? [String])?.contains(designKey) == true)
    }
}
