import EventKit
import Foundation

final class EventKitCalendarEventProvider: ObservableObject, CalendarEventProviding {
    static let lookBehind: TimeInterval = 15 * 60
    static let lookAhead: TimeInterval = 90 * 60
    static let cacheTTL: TimeInterval = 30

    @Published private(set) var authorizationStatus: CalendarAuthorizationStatus
    @Published private(set) var accessRequestError: String?
    private let store: EKEventStore
    private var detectionCache: (fetchedAt: Date, candidates: [CalendarMeetingCandidate])?
    private var dayCache: (
        interval: DateInterval,
        fetchedAt: Date,
        candidates: [CalendarMeetingCandidate]
    )?
    private var aheadCache: (days: Int, fetchedAt: Date, candidates: [CalendarMeetingCandidate])?

    init(store: EKEventStore = EKEventStore()) {
        self.store = store
        authorizationStatus = Self.map(EKEventStore.authorizationStatus(for: .event))
    }

    func requestAccess(_ completion: @escaping (Bool) -> Void) {
        accessRequestError = nil
        store.requestFullAccessToEvents { [weak self] granted, error in
            let errorMessage = error.map(Self.accessRequestMessage)
            let errorDescription = error?.localizedDescription
            DispatchQueue.main.async {
                self?.detectionCache = nil
                self?.dayCache = nil
                self?.aheadCache = nil
                self?.accessRequestError = errorMessage
                self?.refreshAuthorizationStatus()
                if let errorDescription {
                    lokalbotLog("calendar access request failed error=\(errorDescription)")
                }
                completion(granted)
            }
        }
    }

    func refreshAuthorizationStatus() {
        let latest = Self.map(EKEventStore.authorizationStatus(for: .event))
        if latest != authorizationStatus {
            detectionCache = nil
            dayCache = nil
            aheadCache = nil
            authorizationStatus = latest
        }
    }

    func meetingCandidates(now: Date) -> [CalendarMeetingCandidate] {
        guard authorizationStatus == .fullAccess else { return [] }
        if let detectionCache,
           now >= detectionCache.fetchedAt,
           now.timeIntervalSince(detectionCache.fetchedAt) < Self.cacheTTL {
            return detectionCache.candidates
        }
        let candidates = fetchCandidates(
            from: now.addingTimeInterval(-Self.lookBehind),
            to: now.addingTimeInterval(Self.lookAhead))
        detectionCache = (now, candidates)
        return candidates
    }

    func meetingCandidates(on date: Date,
                           calendar: Calendar = .current) -> [CalendarMeetingCandidate] {
        guard authorizationStatus == .fullAccess,
              let interval = calendar.dateInterval(of: .day, for: date) else { return [] }
        let fetchedAt = Date()
        if let dayCache,
           dayCache.interval == interval,
           fetchedAt >= dayCache.fetchedAt,
           fetchedAt.timeIntervalSince(dayCache.fetchedAt) < Self.cacheTTL {
            return dayCache.candidates
        }
        let candidates = fetchCandidates(from: interval.start, to: interval.end)
        dayCache = (interval, fetchedAt, candidates)
        return candidates
    }

    func meetingCandidates(from now: Date, days: Int,
                           calendar: Calendar = .current) -> [CalendarMeetingCandidate] {
        guard authorizationStatus == .fullAccess, days > 0,
              let end = calendar.date(byAdding: .day, value: days, to: now) else { return [] }
        let fetchedAt = Date()
        if let aheadCache,
           aheadCache.days == days,
           fetchedAt >= aheadCache.fetchedAt,
           fetchedAt.timeIntervalSince(aheadCache.fetchedAt) < Self.cacheTTL {
            return aheadCache.candidates
        }
        let candidates = fetchCandidates(from: now, to: end)
        aheadCache = (days, fetchedAt, candidates)
        return candidates
    }

    func attendeeAddresses(from start: Date, to end: Date) -> Set<String> {
        guard authorizationStatus == .fullAccess, start < end else { return [] }
        var addresses: Set<String> = []
        for candidate in fetchCandidates(from: start, to: end) {
            for identity in candidate.resolvedParticipantIdentities {
                if let address = identity.emailAddress { addresses.insert(address) }
            }
        }
        return addresses
    }

    private func fetchCandidates(from start: Date, to end: Date) -> [CalendarMeetingCandidate] {
        let predicate = store.predicateForEvents(
            withStart: start,
            end: end,
            calendars: nil)
        return store.events(matching: predicate)
            .compactMap(Self.candidate(from:))
            .sorted { $0.startDate < $1.startDate }
    }

    static func candidate(from event: EKEvent) -> CalendarMeetingCandidate? {
        let meetingURL = ConferenceURLDetector.firstMeetingURL(in: event.url?.absoluteString)
            ?? ConferenceURLDetector.firstMeetingURL(in: event.location)
            ?? ConferenceURLDetector.firstMeetingURL(in: event.notes)
        let raw = RawCalendarEvent(
            title: event.title,
            isAllDay: event.isAllDay,
            isCanceled: event.status == .canceled,
            isDeclinedByMe: declinedByCurrentUser(event),
            availabilityFree: event.availability == .free,
            availabilityUnavailable: event.availability == .unavailable,
            hasAttendees: event.attendees?.isEmpty == false,
            hasMeetingURL: meetingURL != nil)
        guard CalendarEventFilter.isRecordableMeeting(raw),
              let start = event.startDate, let end = event.endDate,
              let title = event.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty
        else { return nil }
        let participants = participantIdentities(from: event)
        return CalendarMeetingCandidate(
            provider: "eventkit",
            externalID: occurrenceID(event, start: start),
            title: title,
            startDate: start,
            endDate: end,
            meetingURL: meetingURL,
            sourceCalendarTitle: event.calendar?.title,
            participantNames: participants.compactMap(\.name),
            participantIdentities: participants,
            agenda: CalendarAgenda.sanitize(event.notes))
    }

    private static func occurrenceID(_ event: EKEvent, start: Date) -> String {
        let base = event.eventIdentifier ?? event.calendarItemIdentifier
        return "\(base)#\(Int(start.timeIntervalSince1970))"
    }

    private static func declinedByCurrentUser(_ event: EKEvent) -> Bool {
        event.attendees?.contains { $0.isCurrentUser && $0.participantStatus == .declined } ?? false
    }

    private static func participantIdentities(
        from event: EKEvent
    ) -> [CalendarParticipantIdentity] {
        let identities: [CalendarParticipantIdentity] = event.attendees?.compactMap { participant -> CalendarParticipantIdentity? in
            guard !participant.isCurrentUser,
                  participant.participantStatus != .declined else { return nil }
            return CalendarParticipantIdentity(
                name: participant.name,
                emailAddress: CalendarParticipantIdentity.emailAddress(
                    from: participant.url))
        } ?? []
        return CalendarParticipantIdentity.normalized(identities)
    }

    private static func map(_ status: EKAuthorizationStatus) -> CalendarAuthorizationStatus {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .fullAccess: return .fullAccess
        case .writeOnly: return .writeOnly
        @unknown default: return .denied
        }
    }

    private static func accessRequestMessage(_ error: Error) -> String {
        let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !detail.isEmpty else { return "Calendar access couldn’t be requested." }
        return "Calendar access couldn’t be requested. \(detail)"
    }
}
