import Foundation
import Testing
@testable import LokalBotCompanionKit

@Suite("Records")
struct RecordDecodingTests {
    @Test func bundledSampleLibraryMatchesTheProtocolFixture() throws {
        // Tests/LokalBotCompanionKitTests/<file> → Companion/
        var companion = URL(filePath: #filePath)
        for _ in 0..<5 { companion.deleteLastPathComponent() }
        let fixture = companion.appending(path: "protocol/fixtures/sample-library.json")
        let bundled = try #require(SampleLibrary.url)
        #expect(try Data(contentsOf: bundled) == Data(contentsOf: fixture),
                "Copy Companion/protocol/fixtures/sample-library.json into the kit's Resources")
    }

    @Test func decodesTheWholeSampleLibrary() async throws {
        let envelopes = try SampleLibrary.envelopes()
        #expect(envelopes.count == 19)
        let kinds = Dictionary(grouping: envelopes, by: \.kind).mapValues(\.count)
        #expect(kinds == ["manifest": 1, "meeting": 6, "transcript": 2, "day": 4, "person": 4, "project": 2])
        for envelope in envelopes {
            if case .unknown = envelope.body { Issue.record("Unknown body for \(envelope.kind)") }
            if case .tombstone = envelope.body { Issue.record("Unexpected tombstone \(envelope.key)") }
        }
    }

    @Test func meetingFields() async throws {
        let store = try FixtureStore.sampleLibrary()
        let meeting = try #require(await store.meeting(id: "3f6c2a10-8a4e-4d2b-9b1e-0a1b2c3d4e01"))
        #expect(meeting.title == "Design review — onboarding")
        #expect(meeting.timeZoneOffsetMinutes == 60)
        #expect(meeting.timeZone.secondsFromGMT() == 3600)
        // `day` is the Mac-local day of `startedAt`, and the meeting ended after it began.
        var macCalendar = Calendar(identifier: .gregorian)
        macCalendar.timeZone = meeting.timeZone
        #expect(DayKey(meeting.startedAt, calendar: macCalendar).description == meeting.day)
        #expect(meeting.endedAt.timeIntervalSince(meeting.startedAt) == meeting.durationSeconds)
        #expect(meeting.people.map(\.displayName) == ["Maya Chen", "Ben Ortiz"])
        #expect(meeting.projects.map(\.name) == ["Onboarding", "Pricing"])
        #expect(meeting.notesMarkdown == "- Ask legal about the pricing tiers before the Northwind call")
        #expect(meeting.actions.count == 3)
        let first = try #require(meeting.actions.first)
        #expect(first.ownerIsUser && !first.ownerUnclear)
        #expect(first.dueDate.flatMap(DayKey.init) != nil && first.dueText != nil)
        #expect(first.citations.first?.start == 721.4)
        #expect(meeting.openQuestions.first?.citations.isEmpty == true)
        #expect(meeting.hasTranscript)
        #expect(meeting.mergedInto == nil)

        let unclear = try #require(await store.meeting(id: "3f6c2a10-8a4e-4d2b-9b1e-0a1b2c3d4e02")?.actions.last)
        #expect(unclear.owner == nil && unclear.ownerUnclear && unclear.dueDate == nil)
    }

    @Test func transcriptDayPersonProject() async throws {
        let store = try FixtureStore.sampleLibrary()
        let transcript = try #require(await store.transcript(meetingID: "3f6c2a10-8a4e-4d2b-9b1e-0a1b2c3d4e01"))
        #expect(transcript.segments.count == 10)
        #expect(transcript.segments[1].colorIndex == 0 && transcript.segments[1].speaker == "You")
        #expect(transcript.segmentIndex(at: 724) == 3)
        #expect(transcript.segmentIndex(at: 1500) == 5)

        // The day of the design review, which has a digest and a full timeline.
        let review = try #require(await store.meeting(id: "3f6c2a10-8a4e-4d2b-9b1e-0a1b2c3d4e01"))
        let day = try #require(await store.day(review.day))
        #expect(day.digest?.sections.blockers == ["Waiting on legal review of the pricing tiers."])
        #expect(day.timeline?.sessions.count == 6)
        #expect(day.timeline?.sessions[3].kind == .agent)
        #expect(day.timeline?.sessions[1].meetingId == "3f6c2a10-8a4e-4d2b-9b1e-0a1b2c3d4e01")
        #expect(day.timeline?.sessions[0].windowTitles == ["OnboardingFlow.swift", "Terminal — swift test"])
        #expect(day.timeline?.byProject.last?.isOther == true)
        #expect(day.timeline?.savedMoments.first?.label == "Pricing table idea")
        // The sample's "today" (its manifest's generatedAt) has no digest yet.
        #expect(await store.day(DayKey(SampleLibrary.referenceDate).description)?.digest == nil)
        #expect(await store.manifest()?.generatedAt == SampleLibrary.referenceDate)

        let maya = try #require(await store.person(id: "person:maya-chen"))
        #expect(maya.openWork.first?.theirs == false)
        #expect(maya.meetingIds.count == 4)
        #expect(maya.firstName == "Maya")

        let pricing = try #require(await store.project(id: "7a1d0c55-2b8f-4f3a-a6c4-5e6f7a8b9c02"))
        #expect(pricing.waitingOnOthers.map(\.owner) == ["Alex Romero", "Priya Nair"])
        #expect(pricing.timeThisWeekSeconds == 8880)

        let manifest = try #require(await store.manifest())
        #expect(manifest.macName == "Sample Mac" && manifest.dataClasses.windowTitles && manifest.historyDays == 0)
    }

    @Test func ignoresUnknownKeysAndKindsAndReadsNewStatusesAsOpen() async throws {
        let json = """
        [{ "kind": "meeting", "key": "m1", "version": 1, "seq": 1, "deleted": false, "sortKey": "2026-10-30T09:30:00.000Z",
           "futureField": 1,
           "body": { "id": "m1", "title": "T", "startedAt": "2026-10-30T09:30:00Z", "endedAt": "2026-10-30T10:00:00.000Z",
                     "day": "2026-10-30", "timeZoneOffsetMinutes": 0, "durationSeconds": 1800, "people": [], "projects": [],
                     "actions": [ { "id": "a", "text": "x", "ownerIsUser": true, "ownerUnclear": false,
                                    "status": "cancelled", "importance": 2, "citations": [], "confidence": 0.9 } ],
                     "decisions": [], "openQuestions": [], "hasTranscript": false, "somethingNew": { "a": 1 } } },
         { "kind": "calendar", "key": "c", "version": 1, "seq": 2, "deleted": false, "sortKey": "x", "body": { "y": 1 } }]
        """
        let envelopes = try CompanionJSON.decode([RecordEnvelope].self, from: json)
        guard case .meeting(let meeting) = envelopes[0].body else { Issue.record("meeting"); return }
        #expect(meeting.actions[0].status == .open)
        if case .unknown = envelopes[1].body {} else { Issue.record("expected unknown kind") }
    }

    @Test func tombstonesAndVersionsApplyLikeTheSyncCore() async throws {
        let store = try FixtureStore.sampleLibrary()
        let tombstone = """
        [{ "kind": "meeting", "key": "3f6c2a10-8a4e-4d2b-9b1e-0a1b2c3d4e06", "version": 2, "seq": 40, "deleted": true,
           "sortKey": "2026-10-27T08:00:00.000Z", "body": {} },
         { "kind": "meeting", "key": "3f6c2a10-8a4e-4d2b-9b1e-0a1b2c3d4e05", "version": 0, "seq": 41, "deleted": true,
           "sortKey": "2026-10-29T10:00:00.000Z", "body": {} }]
        """
        await store.importRecords(try CompanionJSON.decode([RecordEnvelope].self, from: tombstone))
        #expect(await store.meeting(id: "3f6c2a10-8a4e-4d2b-9b1e-0a1b2c3d4e06") == nil)
        // An older version never replaces a newer one.
        #expect(await store.meeting(id: "3f6c2a10-8a4e-4d2b-9b1e-0a1b2c3d4e05") != nil)
    }

    @Test func instantsRoundTripWithMilliseconds() {
        let date = CompanionJSON.parseInstant("2026-10-31T07:12:00.250Z")!
        #expect(CompanionJSON.formatInstant(date) == "2026-10-31T07:12:00.250Z")
        #expect(CompanionJSON.parseInstant("2026-10-31T07:12:00Z") != nil)
        #expect(CompanionJSON.parseInstant("yesterday") == nil)
    }

    @Test func askRequestEncodesWithoutNulls() async throws {
        let request = AskRequest(requestId: "r", conversationId: "c", question: "Q?")
        let json = try CompanionJSON.encodeString(request)
        #expect(json == #"{"conversationId":"c","history":[],"question":"Q?","requestId":"r"}"#)
        let result = try CompanionJSON.decode(AskResult.self, from: """
        { "requestId": "r", "answer": "A [1]", "citations": [ { "index": 1, "meetingId": "m", "at": 724, "label": "L · 12:04" },
          { "index": 2, "label": "screen moment at 14:32" } ], "engineLabel": "Qwen3.6 35B", "location": "elsewhere",
          "answeredAt": "2026-10-31T07:15:02.000Z" }
        """)
        #expect(result.citations[1].meetingId == nil)
        #expect(result.location == .remote)
    }
}
