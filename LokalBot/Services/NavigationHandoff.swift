import Combine
import Foundation

struct AskNavigationHandoff: Equatable, Sendable {
    let query: String?
    let dayScope: Date?
    /// Nil is unrestricted; an empty collection deliberately permits no screens.
    let screenSnapshotIDs: [Int64]?
    let submit: Bool
    var meetingIDs: Set<Meeting.ID>?
    var mode: AskMode = .ask
}

enum EvidenceIntent: Equatable, Sendable { case reveal, play }

struct MeetingSeekHandoff: Equatable, Sendable {
    let meetingID: Meeting.ID
    let seconds: TimeInterval
    var intent: EvidenceIntent = .reveal
}

struct AgentLaunchContext: Equatable, Sendable {
    let title: String
    let prompt: String
    let meetingID: Meeting.ID?
    let actionID: String?
}

/// Owns the short-lived payloads passed between navigation destinations.
/// Each destination consumes its complete payload at once, so SwiftUI view
/// mounting and coalesced state updates cannot split or misroute a handoff.
@MainActor
final class NavigationHandoff: ObservableObject {
    @Published private(set) var revision: UInt = 0

    private var pendingAsk: AskNavigationHandoff?
    private var pendingMeetingSeek: MeetingSeekHandoff?
    private var pendingScreenSnapshotID: Int64?
    private var pendingTimelineDay: Date?
    private(set) var agentContext: AgentLaunchContext?

    func stageAsk(
        query: String,
        dayScope: Date?,
        screenSnapshotIDs: [Int64]?,
        submit: Bool,
        meetingIDs: Set<Meeting.ID>? = nil,
        mode: AskMode = .ask
    ) {
        pendingAsk = AskNavigationHandoff(
            query: query.isEmpty ? nil : query,
            dayScope: dayScope,
            screenSnapshotIDs: screenSnapshotIDs,
            submit: submit, meetingIDs: meetingIDs, mode: mode)
        changed()
    }

    func consumeAsk() -> AskNavigationHandoff? {
        guard let pendingAsk else { return nil }
        self.pendingAsk = nil
        changed()
        return pendingAsk
    }

    /// Every meeting navigation replaces the previous seek request. Opening a
    /// meeting without a timestamp therefore cannot inherit an older seek.
    func stageMeeting(_ meetingID: Meeting.ID, seek seconds: TimeInterval?, intent: EvidenceIntent = .reveal) {
        pendingMeetingSeek = seconds.map {
            MeetingSeekHandoff(meetingID: meetingID, seconds: max(0, $0), intent: intent)
        }
        changed()
    }

    func consumeMeetingEvidence(for meetingID: Meeting.ID) -> MeetingSeekHandoff? {
        guard let pending = pendingMeetingSeek, pending.meetingID == meetingID else { return nil }
        pendingMeetingSeek = nil
        changed()
        return pending
    }

    func consumeMeetingSeek(for meetingID: Meeting.ID) -> TimeInterval? {
        consumeMeetingEvidence(for: meetingID)?.seconds
    }

    func stageScreenSnapshot(_ snapshotID: Int64) {
        pendingScreenSnapshotID = snapshotID
        changed()
    }

    func consumeScreenSnapshot() -> Int64? {
        guard let pendingScreenSnapshotID else { return nil }
        self.pendingScreenSnapshotID = nil
        changed()
        return pendingScreenSnapshotID
    }

    func stageTimelineDay(_ day: Date) {
        pendingTimelineDay = day
        changed()
    }

    func consumeTimelineDay() -> Date? {
        guard let pendingTimelineDay else { return nil }
        self.pendingTimelineDay = nil
        changed()
        return pendingTimelineDay
    }

    func stageAgent(_ context: AgentLaunchContext?) {
        agentContext = context
        changed()
    }

    @discardableResult
    func consumeAgentContext() -> AgentLaunchContext? {
        guard let agentContext else { return nil }
        self.agentContext = nil
        changed()
        return agentContext
    }

    private func changed() {
        revision &+= 1
    }
}
