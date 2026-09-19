import Foundation

/// One recorded meeting. Persisted as `meta.json` inside its own folder:
/// `meetings/YYYY/MM/dd-slug/{mic.m4a, system.m4a, meta.json}`.
struct Meeting: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var title: String
    var appName: String
    var startedAt: Date
    var endedAt: Date?
    /// Path relative to the LokalBot storage root, e.g. "meetings/2026/06/10-zoom-meeting".
    var relativePath: String
    var hasSystemTrack: Bool = false

    // MARK: Calendar provenance (optional)
    //
    // Populated only when a recording was matched to a calendar event. All
    // optional so `meta.json` written before calendar support still decodes
    // (synthesized `Codable` decodes missing keys to nil and omits nil keys on
    // encode, so manual recordings keep their old, calendar-free shape).
    var calendarProvider: String?
    var calendarEventID: String?
    var calendarTitle: String?
    var scheduledStartAt: Date?
    var scheduledEndAt: Date?
    var meetingURL: URL?
    /// Calendar attendee / roster names that can seed speaker rename
    /// suggestions. Optional so older `meta.json` files still decode.
    var participantNameHints: [String]?
    /// Structured calendar attendees. Email addresses remain in this local
    /// metadata only; transcript aliases retain opaque participant IDs.
    var calendarParticipantIdentities: [CalendarParticipantIdentity]?

    /// IDs of the source meetings when this record was created by the
    /// non-destructive merge flow. Source folders are never removed or
    /// rewritten, and speaker labels in the merged transcript stay scoped to
    /// their source meeting so identities cannot silently bleed across calls.
    var mergedSourceMeetingIDs: [UUID]?

    /// The merged meeting that folded this source out of the main library.
    /// Keeping this relationship in the source metadata lets the app hide the
    /// old row across launches without deleting its original evidence.
    var mergedIntoMeetingID: UUID?

    var isMergedMeeting: Bool { !(mergedSourceMeetingIDs ?? []).isEmpty }
    var isMergedSource: Bool { mergedIntoMeetingID != nil }

    /// Shared, read-only library projection for the app and CLI/MCP. Parent
    /// manifests cover interrupted source-marker writes; missing parents make
    /// their originals visible again. StorageManager persists these repairs.
    static func resolvingMergeRelationships(in meetings: [Meeting]) -> [Meeting] {
        var parents: [UUID: UUID] = [:]
        var sourceIDsByParent: [UUID: Set<UUID>] = [:]
        for parent in meetings.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            sourceIDsByParent[parent.id] = Set(parent.mergedSourceMeetingIDs ?? [])
            for sourceID in parent.mergedSourceMeetingIDs ?? [] where sourceID != parent.id {
                parents[sourceID] = parent.id
            }
        }
        return meetings.map { meeting in
            var resolved = meeting
            if let parentID = meeting.mergedIntoMeetingID,
               parentID != meeting.id,
               sourceIDsByParent[parentID]?.contains(meeting.id) == true {
                return resolved
            }
            resolved.mergedIntoMeetingID = parents[meeting.id]
            return resolved
        }
    }

    var resolvedCalendarParticipantIdentities: [CalendarParticipantIdentity] {
        let structured = CalendarParticipantIdentity.normalized(
            calendarParticipantIdentities ?? [])
        return structured.isEmpty
            ? CalendarParticipantIdentity.fromLegacyNames(participantNameHints ?? [])
            : structured
    }

    /// Length of the actual recorded audio (longest track), measured at
    /// finalize. The wall-clock span (`duration`) can exceed what was captured
    /// — an audio-device disruption can truncate the tracks while a
    /// calendar-backed session stays live — so this is the playable length and
    /// what `durationLabel` reports. Optional so older `meta.json` still decodes.
    var recordedDuration: TimeInterval?

    /// Seconds on the original audio timeline. Raw tracks stay intact; all
    /// derived meeting evidence is limited to this reviewable range.
    var contentRange: ContentRange?

    struct ContentRange: Codable, Equatable, Sendable {
        var start: TimeInterval
        var end: TimeInterval
        var isValid: Bool { start.isFinite && end.isFinite && start >= 0 && end > start }

        func applying(to transcript: Transcript) -> Transcript {
            var result = transcript
            // Without word alignment, a crossing segment cannot be safely
            // clipped as text. Retranscription partitions audio at the boundary.
            result.segments = transcript.segments.filter {
                isValid && $0.start >= start && $0.end <= end
            }
            return result
        }
    }

    var duration: TimeInterval? {
        endedAt.map { $0.timeIntervalSince(startedAt) }
    }


    var durationLabel: String {
        guard let d = recordedDuration ?? duration else { return "in progress" }
        let m = Int(d) / 60
        return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m) min"
    }

    /// Human title hierarchy shared by list, preview, Today, Timeline, Ask,
    /// and Agent surfaces. Calendar provenance beats generic recorder labels;
    /// otherwise preserve the original title and fall back to app + time.
    var displayTitle: String {
        let cleanedTitle = Self.cleanedTitle(title)
        if !Self.isGenericTitle(cleanedTitle) { return cleanedTitle }
        let cleanedCalendar = Self.cleanedTitle(calendarTitle ?? "")
        if !cleanedCalendar.isEmpty { return cleanedCalendar }
        if !cleanedTitle.isEmpty, cleanedTitle.caseInsensitiveCompare("Meeting") != .orderedSame {
            return cleanedTitle
        }
        let app = Self.cleanedTitle(appName)
        let time = startedAt.formatted(date: .omitted, time: .shortened)
        return app.isEmpty ? "Meeting at \(time)" : "\(app) at \(time)"
    }

    private static func cleanedTitle(_ value: String) -> String {
        value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isGenericTitle(_ value: String) -> Bool {
        guard !value.isEmpty else { return true }
        let normalized = value.lowercased()
        return normalized == "meeting"
            || normalized == "manual recording"
            || normalized == "recording"
            || normalized == "untitled meeting"
            || normalized.hasPrefix("meeting ")
    }
}
