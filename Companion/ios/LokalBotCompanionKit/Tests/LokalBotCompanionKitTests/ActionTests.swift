import Foundation
import Testing
@testable import LokalBotCompanionKit

/// Dates come from the fixture: "today" is its manifest's generatedAt.
@Suite("Actions")
struct ActionTests {
    static let today = DayKey(SampleLibrary.referenceDate)

    static func store(pending: Bool = false) throws -> FixtureStore {
        try FixtureStore.sampleLibrary(configuration: .init(now: { SampleLibrary.referenceDate }, keepsChangesPending: pending))
    }

    @Test func sortsOverdueFirstThenByDueDateWithUndatedLast() async throws {
        let rows = try await Self.store().actions(.init(status: .open))
        let overdue = rows.prefix { ActionOrdering.isOverdue($0.action, today: Self.today) }
        let rest = rows.dropFirst(overdue.count)
        #expect(!overdue.isEmpty, "The sample has an overdue action")
        #expect(!rest.contains { ActionOrdering.isOverdue($0.action, today: Self.today) })
        let dated = rest.prefix { $0.action.dueDate != nil }
        #expect(dated.map { $0.action.dueDate! } == dated.map { $0.action.dueDate! }.sorted())
        #expect(rest.dropFirst(dated.count).allSatisfy { $0.action.dueDate == nil })
        #expect(rest.last?.action.dueDate == nil, "The sample has an undated action")
    }

    @Test func tiesBreakByTheNewestMeeting() {
        let today = DayKey("2026-10-30")!
        func row(_ id: String, due: String?, started: TimeInterval, status: ActionStatus = .open) -> ActionRow {
            ActionRow(meetingId: id, meetingTitle: id, meetingStartedAt: Date(timeIntervalSince1970: started),
                      action: ActionItem(id: id, text: id, dueDate: due, status: status))
        }
        let rows = [row("undated", due: nil, started: 9), row("older", due: "2026-11-05", started: 1),
                    row("newer", due: "2026-11-05", started: 2), row("overdue", due: "2026-10-01", started: 0),
                    row("doneLate", due: "2026-10-02", started: 3, status: .done)]
        #expect(ActionOrdering.sorted(rows, today: today).map(\.meetingId) == ["overdue", "doneLate", "newer", "older", "undated"])
        #expect(ActionOrdering.sorted(rows.reversed(), today: today).map(\.meetingId) == ["overdue", "doneLate", "newer", "older", "undated"])
    }

    @Test func doneActionsAreNeverOverdue() {
        let done = ActionItem(id: "d", text: "d", dueDate: Self.today.adding(days: -30).description, status: .done)
        #expect(!ActionOrdering.isOverdue(done, today: Self.today))
    }

    @Test func filtersMatchTheFFIActionFilter() async throws {
        let store = try Self.store()
        let all = await store.actions(.all)
        func ids(_ include: (ActionItem) -> Bool) -> Set<String> { Set(all.filter { include($0.action) }.map(\.id)) }
        #expect(Set(await store.actions(.myOpen).map(\.id)) == ids { $0.ownerIsUser && $0.status == .open })
        #expect(Set(await store.actions(.init(ownerUnclearOnly: true)).map(\.id)) == ids(\.ownerUnclear))
        #expect(Set(await store.actions(.init(status: .done)).map(\.id)) == ids { $0.status == .done })
        #expect(await store.actions(.init(status: .deferred)).isEmpty)
        let cut = Self.today.adding(days: 4).description
        #expect(Set(await store.actions(.init(status: .open, dueBefore: cut)).map(\.id))
                == ids { $0.status == .open && ($0.dueDate.map { $0 < cut } ?? false) })
        #expect(await store.actions(.myOpen).count >= 2 && all.count == 10)
    }

    @Test func ownerScopesCoverEveryAction() async throws {
        let rows = try await Self.store().actions(.all)
        let counts = ActionOrdering.Owner.allCases.map { owner in rows.filter { owner.matches($0.action) }.count }
        #expect(counts == [4, 5, 1])
        #expect(counts.reduce(0, +) == rows.count)
    }

    @Test func groupsFollowTheDueDates() async throws {
        let rows = try await Self.store().actions(.init(status: .open))
        let groups = ActionOrdering.grouped(rows, today: Self.today)
        #expect(groups.map(\.group) == ActionOrdering.Group.allCases.filter { group in groups.contains { $0.group == group } })
        #expect(groups.flatMap(\.rows).count == rows.count)
        for (group, members) in groups {
            for row in members {
                let distance = row.action.dueDate.flatMap(DayKey.init).map { Self.today.days(until: $0) }
                switch group {
                case .overdue: #expect(distance.map { $0 < 0 } == true)
                case .today: #expect(distance == 0)
                case .thisWeek: #expect(distance.map { (1...6).contains($0) } == true)
                case .later: #expect(distance.map { $0 > 6 } == true)
                case .earlier: Issue.record("Open actions are overdue, not earlier")
                case .noDate: #expect(distance == nil)
                }
            }
        }
        #expect(Set(groups.map(\.group)).isSuperset(of: [.overdue, .thisWeek, .noDate]))
    }

    @Test func statusChangesStayPendingUntilSynced() async throws {
        let store = try Self.store(pending: true)
        let overdue = try #require(await store.actions(.myOpen).first { ActionOrdering.isOverdue($0.action, today: Self.today) })
        try await store.setActionStatus(meetingID: overdue.meetingId, actionID: overdue.action.id, status: .done)
        let row = try #require(await store.actions(.all).first { $0.id == overdue.id })
        #expect(row.action.status == .done && row.pending)
        #expect(await store.status().pendingOps == 1)
        // People and projects reflect the change before the Mac rebuilds them.
        #expect(await store.person(id: "person:maya-chen")?.openWork.contains { $0.actionId == overdue.action.id } == false)
        #expect(await store.project(id: "7a1d0c55-2b8f-4f3a-a6c4-5e6f7a8b9c02")?
            .yourActions.first { $0.actionId == overdue.action.id }?.status == .done)
        await #expect(throws: CompanionStoreError.self) {
            try await store.setActionStatus(meetingID: "nope", actionID: "x", status: .done)
        }
    }
}
