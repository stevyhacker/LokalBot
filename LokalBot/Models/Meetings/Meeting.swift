import Foundation

struct Meeting: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var title: String
    var appName: String
    var startedAt: Date
    var endedAt: Date?
    var relativePath: String
    var hasSystemTrack: Bool = false

    var calendarProvider: String?
    var calendarEventID: String?
    var calendarTitle: String?
    var scheduledStartAt: Date?
    var scheduledEndAt: Date?
    var meetingURL: URL?
    var participantNameHints: [String]?
    var calendarParticipantIdentities: [CalendarParticipantIdentity]?
    var calendarAgenda: String?

    var mergedSourceMeetingIDs: [UUID]?

    var mergedIntoMeetingID: UUID?

    var extractedFromMeetingID: UUID?

    var importedFileNames: [String]?

    var importSource: ImportSource?

    struct ImportSource: Codable, Equatable, Sendable {
        var app: String
        var id: String
        var importedAt: Date

        var key: String { "\(app)/\(id)" }
    }

    var sampleID: String?

    var isMergedMeeting: Bool { !(mergedSourceMeetingIDs ?? []).isEmpty }
    var isMergedSource: Bool { mergedIntoMeetingID != nil }
    var isImported: Bool { !(importedFileNames ?? []).isEmpty }
    var isSample: Bool { sampleID != nil }
    var isOwnWork: Bool { !isMergedSource && !isSample }

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

    var recordedDuration: TimeInterval?

    var contentRange: ContentRange?

    var contentRangeSource: ContentRangeSource?
    enum ContentRangeSource: String, Codable { case userReviewed, confirmedCallEnd }

    var captureIntent: CaptureIntent?
    struct CaptureIntent: Codable, Equatable, Sendable {
        var systemAudioRequested: Bool
        var appBundleID: String?
        var meetingURL: URL?

        func accepts(appBundleID: String, meetingURL: URL?) -> Bool {
            guard systemAudioRequested else { return false }
            if let expected = self.appBundleID, expected != appBundleID { return false }
            if let expected = self.meetingURL, expected != meetingURL { return false }
            return true
        }
    }

    var additionalSavedAudioDuration: TimeInterval {
        guard let contentRange, contentRange.isValid, let recordedDuration else { return 0 }
        return max(0, contentRange.start) + max(0, recordedDuration - contentRange.end)
    }

    struct ContentRange: Codable, Equatable, Sendable {
        var start: TimeInterval
        var end: TimeInterval
        var isValid: Bool { start.isFinite && end.isFinite && start >= 0 && end > start }

        func applying(to transcript: Transcript) -> Transcript {
            var result = transcript
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

    var displayTitle: String {
        var cleanedTitle = Self.cleanedTitle(title)
        while isMergedMeeting, cleanedTitle.hasPrefix("Merged: "),
              cleanedTitle.range(of: #" \+ \d+ more$"#, options: .regularExpression) != nil {
            cleanedTitle = String(cleanedTitle.dropFirst("Merged: ".count))
                .replacingOccurrences(of: #" \+ \d+ more$"#, with: "", options: .regularExpression)
        }
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
