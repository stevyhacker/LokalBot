import Foundation

/// A calendar event that could line up with a recording: already filtered down
/// to a real, recordable meeting (see ``CalendarEventFilter``) and stripped of
/// EventKit so the matching layer and its tests never import `EventKit`.
struct CalendarMeetingCandidate: Equatable, Sendable {
    /// Source provider tag, e.g. "eventkit". Persisted on the `Meeting`.
    let provider: String
    /// Stable per-occurrence identifier (event id + occurrence start) so the
    /// repeat-suppression cooldown is keyed on this exact meeting instance.
    let externalID: String
    let title: String
    let startDate: Date
    let endDate: Date
    /// Conferencing link found on the event (Meet/Zoom/Teams/…), if any. The
    /// signal that lets a browser's audio count as a meeting without a window
    /// title match.
    let meetingURL: URL?
    let sourceCalendarTitle: String?
    var participantNames: [String] = []
    var participantIdentities: [CalendarParticipantIdentity] = []
    /// Sanitized invitation agenda, held in memory. A recording keeps it
    /// only when agenda use is enabled.
    var agenda: String?

    /// Structured identities when the provider supplies them, otherwise a
    /// backwards-compatible projection of the legacy name-only roster.
    var resolvedParticipantIdentities: [CalendarParticipantIdentity] {
        let structured = CalendarParticipantIdentity.normalized(participantIdentities)
        return structured.isEmpty
            ? CalendarParticipantIdentity.fromLegacyNames(participantNames)
            : structured
    }

    /// Grace before an event's scheduled start during which it already counts
    /// as active — a *beat* early (people click Join ~a minute ahead), not a
    /// long pre-roll. A generous value here is what made auto-record fire whole
    /// minutes before a meeting actually began.
    static let earlyJoinGrace: TimeInterval = 60

    /// Is this event happening at `now`? In progress, or within `earlyJoin`
    /// before its start. Calendar end never *stops* a recording — only audio
    /// does — so this is deliberately start-biased.
    func isActive(at now: Date, earlyJoin: TimeInterval = CalendarMeetingCandidate.earlyJoinGrace) -> Bool {
        now >= startDate.addingTimeInterval(-earlyJoin) && now <= endDate
    }
}

extension Array where Element == CalendarMeetingCandidate {
    /// The single event that best represents "what is happening now": an
    /// in-progress event (most recently started) beats one about to start; with
    /// none in progress, the soonest upcoming wins. Nil when none is active.
    func activeCandidate(at now: Date, earlyJoin: TimeInterval = CalendarMeetingCandidate.earlyJoinGrace) -> CalendarMeetingCandidate? {
        let active = filter { $0.isActive(at: now, earlyJoin: earlyJoin) }
        let inProgress = active.filter { $0.startDate <= now }
        if let started = inProgress.max(by: { $0.startDate < $1.startDate }) { return started }
        return active.min(by: { $0.startDate < $1.startDate })
    }
}
