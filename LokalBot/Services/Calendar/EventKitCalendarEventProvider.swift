import EventKit
import Foundation

/// `CalendarEventProviding` backed by the system calendar via EventKit. Reads
/// only — no Google/Microsoft OAuth (v1): anything synced into Apple Calendar
/// (Google, Exchange, iCloud) is visible here all the same.
///
/// `ObservableObject` so the settings UI reflects permission changes; the data
/// methods stay non-isolated so the (non-`@MainActor`) detector can read them
/// straight from its tick on the main thread.
final class EventKitCalendarEventProvider: ObservableObject, CalendarEventProviding {
    /// Look-around window: a meeting you joined up to 15 min late still matches,
    /// and one starting within 90 min is visible for early detection.
    static let lookBehind: TimeInterval = 15 * 60
    static let lookAhead: TimeInterval = 90 * 60
    /// Re-fetch at most this often — EventKit ticks (mic toggles, audio blips)
    /// shouldn't hammer the store; meetings don't change on a 30 s scale.
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
                self?.accessRequestError = errorMessage
                self?.refreshAuthorizationStatus()
                if let errorDescription {
                    lokalbotLog("calendar access request failed error=\(errorDescription)")
                }
                completion(granted)
            }
        }
    }

    /// Re-reads the TCC state (it can change in System Settings with no
    /// notification) and republishes only on a real change.
    func refreshAuthorizationStatus() {
        let latest = Self.map(EKEventStore.authorizationStatus(for: .event))
        if latest != authorizationStatus {
            detectionCache = nil
            dayCache = nil
            authorizationStatus = latest
        }
    }

    /// The detector intentionally keeps its narrow look-around window. Today
    /// uses ``meetingCandidates(on:calendar:)`` instead so a distant afternoon
    /// meeting cannot disappear from the day's schedule.
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

    /// Every recordable meeting overlapping the supplied local calendar day.
    /// This cache is independent from detector polling so widening Today does
    /// not widen automatic recording's confidence window.
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

    private func fetchCandidates(from start: Date, to end: Date) -> [CalendarMeetingCandidate] {
        let predicate = store.predicateForEvents(
            withStart: start,
            end: end,
            calendars: nil)
        return store.events(matching: predicate)
            .compactMap(Self.candidate(from:))
            .sorted { $0.startDate < $1.startDate }
    }

    // MARK: - Mapping

    /// Map an `EKEvent` to a recordable candidate, applying ``CalendarEventFilter``.
    /// Nil for non-meetings (all-day, cancelled, declined, OOO, focus blocks,
    /// untitled) or events missing a start/end.
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

    /// Per-occurrence id: the event id alone is shared across a recurring
    /// series, so fold in the occurrence start to keep occurrences distinct.
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
