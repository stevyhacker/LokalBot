import Foundation

struct RawCalendarEvent: Equatable {
    var title: String?
    var isAllDay: Bool
    var isCanceled: Bool
    var isDeclinedByMe: Bool
    var availabilityFree: Bool
    var availabilityUnavailable: Bool
    var hasAttendees: Bool
    var hasMeetingURL: Bool
}

enum CalendarEventFilter {
    static func isRecordableMeeting(_ event: RawCalendarEvent) -> Bool {
        let title = event.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty else { return false }
        if event.isAllDay || event.isCanceled || event.isDeclinedByMe { return false }
        if event.availabilityUnavailable { return false }
        if event.availabilityFree && !event.hasAttendees && !event.hasMeetingURL { return false }
        return true
    }
}
