import Foundation

struct CalendarMeetingCandidate: Equatable, Sendable {
    let provider: String
    let externalID: String
    let title: String
    let startDate: Date
    let endDate: Date
    let meetingURL: URL?
    let sourceCalendarTitle: String?
    var participantNames: [String] = []
    var participantIdentities: [CalendarParticipantIdentity] = []
    var agenda: String?

    var resolvedParticipantIdentities: [CalendarParticipantIdentity] {
        let structured = CalendarParticipantIdentity.normalized(participantIdentities)
        return structured.isEmpty
            ? CalendarParticipantIdentity.fromLegacyNames(participantNames)
            : structured
    }

    static let earlyJoinGrace: TimeInterval = 60

    func isActive(at now: Date, earlyJoin: TimeInterval = CalendarMeetingCandidate.earlyJoinGrace) -> Bool {
        now >= startDate.addingTimeInterval(-earlyJoin) && now <= endDate
    }
}

extension Array where Element == CalendarMeetingCandidate {
    func activeCandidate(at now: Date, earlyJoin: TimeInterval = CalendarMeetingCandidate.earlyJoinGrace) -> CalendarMeetingCandidate? {
        let active = filter { $0.isActive(at: now, earlyJoin: earlyJoin) }
        let inProgress = active.filter { $0.startDate <= now }
        if let started = inProgress.max(by: { $0.startDate < $1.startDate }) { return started }
        return active.min(by: { $0.startDate < $1.startDate })
    }
}
