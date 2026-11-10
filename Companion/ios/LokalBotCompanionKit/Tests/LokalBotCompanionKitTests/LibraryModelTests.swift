import Foundation
import Testing
@testable import LokalBotCompanionKit

@Suite("Library models")
@MainActor
struct LibraryModelTests {
    static let designReview = "3f6c2a10-8a4e-4d2b-9b1e-0a1b2c3d4e01"
    static let longHistoryCount = 1_205

    static func longHistoryID(_ index: Int) -> String { String(format: "meeting-%04d", index) }

    /// A library with more meetings than the Meetings list loads at once;
    /// index 0 is the oldest.
    static func longHistory() throws -> FixtureStore {
        let first = Date(timeIntervalSince1970: 1_767_603_600)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = .gmt
        let envelopes = try (0..<longHistoryCount).map { index in
            let start = first.addingTimeInterval(Double(index) * 6 * 3_600)
            let meeting = Meeting(id: longHistoryID(index), title: "Weekly sync \(index)", startedAt: start,
                                  endedAt: start.addingTimeInterval(1_800), day: DayKey(start, calendar: utc).description,
                                  timeZoneOffsetMinutes: 0, durationSeconds: 1_800)
            return #"{"kind":"meeting","key":"\#(meeting.id)","version":1,"seq":\#(index + 1),"body":\#(try CompanionJSON.encodeString(meeting))}"#
        }
        return FixtureStore(envelopes: try CompanionJSON.decode([RecordEnvelope].self, from: "[\(envelopes.joined(separator: ","))]"))
    }

    @Test func theMeetingsListGoesOnPastWhatItLoadsFirst() async throws {
        let session = CompanionSession(store: try Self.longHistory())
        await session.start()
        let model = MeetingsModel()
        func listed() -> [String] { model.groups.flatMap(\.meetings).map(\.id) }

        await model.load(session)
        #expect(listed().count == MeetingsModel.pageSize)
        #expect(!listed().contains(Self.longHistoryID(0)))
        #expect(model.hasMore)

        await model.showMore(session)
        #expect(listed().count == Self.longHistoryCount)
        #expect(listed().last == Self.longHistoryID(0))
        #expect(!model.hasMore)

        // A reload after a sync keeps what the list had reached, and there is nothing more to ask for.
        await model.load(session)
        await model.showMore(session)
        #expect(listed().count == Self.longHistoryCount)
    }

    @Test func aMeetingThisBuildCantReadDoesNotEndTheList() throws {
        let start = Date(timeIntervalSince1970: 1_767_603_600)
        func row(_ index: Int) throws -> String {
            try CompanionJSON.encodeString(Meeting(id: "m\(index)", title: "Sync \(index)", startedAt: start, endedAt: start,
                                                   day: "2026-01-05", timeZoneOffsetMinutes: 0, durationSeconds: 0))
        }
        // Three rows for a page of two, the middle one from a schema this build doesn't know.
        let rows = [try row(0), #"{"id":"m1","title":7}"#, try row(2)]
        let page = MeetingsPage(rows: rows, limit: 2)
        #expect(page.meetings.map(\.id) == ["m0"])
        #expect(page.hasMore)

        #expect(!MeetingsPage(rows: Array(rows.prefix(2)), limit: 2).hasMore)
        #expect(MeetingsPage(rows: [], limit: 2) == MeetingsPage(meetings: [], hasMore: false))
    }

    @Test func aQueuedAnswersBannerLeavesTheAnswerOutWhileAppLockIsOn() {
        let answer = "You agreed to cut onboarding to three steps [1]. " + String(repeating: "More. ", count: 60)
        let locked = QueuedAnswerBanner(question: "What did we decide?", answer: answer, appLockOn: true)
        #expect(locked.title == "Your computer answered")
        #expect(locked.subtitle == "What did we decide?")
        #expect(locked.body.isEmpty)

        let open = QueuedAnswerBanner(question: "What did we decide?", answer: answer, appLockOn: false)
        #expect(open.subtitle == locked.subtitle)
        #expect(open.body.hasPrefix("You agreed to cut onboarding to three steps."))
        #expect(open.body.count == 180)
    }

    @Test func whatTheStoreAddsToAnActionDecodes() throws {
        let fields = #""id":"a1","text":"Send the deck","ownerIsUser":true,"ownerUnclear":false,"status":"open","importance":3,"citations":[]"#
        let plain = try CompanionJSON.decode(ActionItem.self, from: "{\(fields)}")
        #expect(!plain.pending && plain.syncNote == nil)

        let pending = try CompanionJSON.decode(ActionItem.self, from: #"{\#(fields),"pending":true}"#)
        #expect(pending.pending)

        let note = #"{"status":"unmatched","requestedStatus":"done","at":"2026-11-10T09:00:00.000Z","message":"This action changed on your computer."}"#
        let refused = try CompanionJSON.decode(ActionItem.self, from: #"{\#(fields),"syncNote":\#(note)}"#)
        #expect(!refused.pending)
        #expect(refused.syncNote?.message == "This action changed on your computer.")

        // A row carries both itself; a note needn't have a message.
        let row = try CompanionJSON.decode(ActionRow.self, from: #"""
            {"meetingId":"m1","meetingTitle":"Review","meetingStartedAt":"2026-11-10T09:00:00.000Z","action":{\#(fields)},
             "pending":false,"syncNote":{"status":"rejected","requestedStatus":"done","at":"2026-11-10T09:00:00.000Z"}}
            """#)
        #expect(row.syncNote != nil && row.syncNote?.message == nil)
    }

    @Test func aMeetingsOwnActionsSayWhichWaitForTheComputer() async throws {
        let store = try ActionTests.store(pending: true)
        let action = try #require(await store.meeting(id: Self.designReview)?.actions.first)
        #expect(!action.pending)

        try await store.setActionStatus(meetingID: Self.designReview, actionID: action.id, status: .done)
        #expect(await store.meeting(id: Self.designReview)?.actions.filter(\.pending).map(\.id) == [action.id])
        #expect(await store.meetings(fromDay: nil, toDay: nil, limit: 100).flatMap(\.actions).filter(\.pending).map(\.id) == [action.id])
        // A row carries the flag itself, as the sync core's rows do.
        let row = try #require(await store.actions(.all).first { $0.pending })
        #expect(row.action.id == action.id && !row.action.pending)

        let session = CompanionSession(store: store)
        await session.start()
        let model = MeetingDetailModel(meetingID: Self.designReview)
        await model.load(session)
        #expect(model.pendingActionIDs == [action.id])
        let meeting = try #require(model.meeting)
        #expect(ActionRow(meeting: meeting, action: meeting.actions[0]).pending)
    }

    @Test func aChangeMadeWhileAQueuedQuestionIsAnsweredDoesNotWaitForTheAnswer() async throws {
        let status = SyncStatus(paired: true, lastSyncAt: SampleLibrary.referenceDate, lastAddress: "192.168.1.20:17890",
                                cursor: 19, macName: "Sample Mac")
        let store = try FixtureStore.sampleLibrary(configuration: .init(
            now: { SampleLibrary.referenceDate }, keepsChangesPending: true, pairedStatus: status))
        let session = CompanionSession(store: store)
        await session.start()
        var answered: [String] = []
        session.onQueuedAnswer = { request, _ in answered.append(request.requestId) }
        await store.queueQuestion(AskRequest(requestId: "queued-1", conversationId: "c1",
                                             question: "What did we decide about onboarding?"))

        func wait(for condition: @MainActor () async -> Bool) async throws {
            for _ in 0..<1_000 {
                if await condition() { return }
                try await Task.sleep(for: .milliseconds(5))
            }
            Issue.record("Timed out")
        }

        let sync = Task { await session.syncNow() }
        try await wait { !session.askingIDs.isEmpty }
        // The sync is over while the computer writes its answer, so the next one can start.
        #expect(!session.isSyncing)

        let action = try #require(await store.meeting(id: Self.designReview)?.actions.first)
        try await session.setActionStatus(.done, meetingID: Self.designReview, actionID: action.id)
        #expect(await store.status().pendingOps == 1)
        try await wait { await store.status().pendingOps == 0 }

        await sync.value
        try await wait { !session.isSyncing }
        #expect(answered == ["queued-1"])
        #expect(await store.queuedQuestions().isEmpty)
    }
}
