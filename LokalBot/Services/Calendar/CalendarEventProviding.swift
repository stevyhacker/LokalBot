import Foundation

enum CalendarAuthorizationStatus: Equatable {
    case notDetermined
    case restricted
    case denied
    case writeOnly
    case fullAccess
}

protocol CalendarEventProviding: AnyObject {
    var authorizationStatus: CalendarAuthorizationStatus { get }
    var accessRequestError: String? { get }
    func requestAccess(_ completion: @escaping (Bool) -> Void)
    func meetingCandidates(now: Date) -> [CalendarMeetingCandidate]
}

extension CalendarEventProviding {
    var accessRequestError: String? { nil }
    var hasAccess: Bool { authorizationStatus == .fullAccess }

    func activeCandidate(now: Date) -> CalendarMeetingCandidate? {
        guard hasAccess else { return nil }
        return meetingCandidates(now: now).activeCandidate(at: now)
    }
}
