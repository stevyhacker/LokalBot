import Foundation

/// What was on screen while a meeting recorded, aligned to the meeting's
/// audio timeline. Built only from retained screen-memory rows (titles,
/// document names, URLs, and timestamps); pixels and captured text are not
/// read here. Captures expire with screen retention, so this can shrink.
struct MeetingScreenContext: Equatable, Sendable {
    /// One stretch of the same app and window, as it appeared on screen.
    struct Moment: Identifiable, Equatable, Sendable {
        let snapshotID: Int64
        let capturedAt: Date
        /// Seconds from the start of the meeting's audio.
        let offset: TimeInterval
        let app: String
        let title: String
        let sourceURL: String
        let hasPixels: Bool

        var id: Int64 { snapshotID }
    }

    /// A distinct document, page, or window that was referenced during the
    /// call, in order of first appearance.
    struct Material: Identifiable, Equatable, Sendable {
        let id: String
        let title: String
        let app: String
        let host: String?
        let firstOffset: TimeInterval
        let firstSnapshotID: Int64
        let captureCount: Int
    }

    static let maximumMaterials = 12

    var moments: [Moment] = []
    var materials: [Material] = []

    var isEmpty: Bool { moments.isEmpty }

    /// The last moment shown at or before an audio position.
    func moment(at offset: TimeInterval) -> Moment? {
        guard let first = moments.first, offset >= first.offset - 1 else { return nil }
        var low = 0
        var high = moments.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if moments[middle].offset <= offset { low = middle } else { high = middle - 1 }
        }
        return moments[low]
    }

    /// Window and document titles for use as secondary context, never the
    /// captured text itself.
    var materialTitles: [String] {
        materials.map { material in
            material.host.map { "\(material.title) (\($0))" } ?? "\(material.title) (\(material.app))"
        }
    }

    static func build(meeting: Meeting, screenshots: [ActivityStore.Screenshot]) -> Self {
        let start = meeting.startedAt
        let end = meeting.endedAt ?? start.addingTimeInterval(meeting.recordedDuration ?? 0)
        let playable = meeting.recordedDuration ?? end.timeIntervalSince(start)
        var moments: [Moment] = []
        for shot in screenshots.sorted(by: { ($0.ts, $0.id) < ($1.ts, $1.id) }) {
            guard shot.ts >= start.addingTimeInterval(-5), shot.ts <= end.addingTimeInterval(5),
                  !isCallWindow(shot, meeting: meeting) else { continue }
            let title = displayTitle(shot)
            guard !title.isEmpty else { continue }
            let offset = min(max(0, shot.ts.timeIntervalSince(start)), max(0, playable))
            if let last = moments.last, last.app == shot.app, last.title == title { continue }
            moments.append(Moment(
                snapshotID: shot.id, capturedAt: shot.ts, offset: offset, app: shot.app,
                title: title, sourceURL: shot.sourceURL, hasPixels: shot.hasPixels))
        }

        var materials: [Material] = []
        var indexByKey: [String: Int] = [:]
        var counts: [String: Int] = [:]
        for moment in moments {
            let key = materialKey(moment)
            counts[key, default: 0] += 1
            guard indexByKey[key] == nil else { continue }
            indexByKey[key] = materials.count
            materials.append(Material(
                id: key, title: moment.title, app: moment.app,
                host: URL(string: moment.sourceURL)?.host(),
                firstOffset: moment.offset, firstSnapshotID: moment.snapshotID, captureCount: 0))
        }
        materials = materials.map { material in
            Material(id: material.id, title: material.title, app: material.app, host: material.host,
                     firstOffset: material.firstOffset, firstSnapshotID: material.firstSnapshotID,
                     captureCount: counts[material.id] ?? 1)
        }
        return Self(moments: moments, materials: Array(materials.prefix(maximumMaterials)))
    }

    // MARK: - Helpers

    /// The call itself (the meeting app's window or a conference tab) is not
    /// material the user referenced.
    private static func isCallWindow(_ shot: ActivityStore.Screenshot, meeting: Meeting) -> Bool {
        if let url = URL(string: shot.sourceURL), ConferenceURLDetector.isMeetingURL(url) { return true }
        let meetingApp = meeting.appName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !meetingApp.isEmpty, shot.app.caseInsensitiveCompare(meetingApp) == .orderedSame else {
            return false
        }
        // A browser-hosted call shares the app with every other tab; only
        // the tab showing the call is excluded there.
        return shot.sourceURL.isEmpty && shot.documentName.isEmpty
            && !browserApps.contains(shot.app.lowercased())
    }

    private static let browserApps: Set<String> = [
        "safari", "google chrome", "chrome", "arc", "firefox", "microsoft edge", "brave browser",
        "opera", "vivaldi", "orion", "dia",
    ]

    private static func displayTitle(_ shot: ActivityStore.Screenshot) -> String {
        let document = shot.documentName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !document.isEmpty { return document }
        let title = TimelineWorkSession.strippingBrowserChrome(shot.windowTitle)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? shot.app : title
    }

    private static func materialKey(_ moment: Moment) -> String {
        if let url = URL(string: moment.sourceURL), let host = url.host() {
            return "url:" + host.lowercased() + url.path().lowercased()
        }
        return "title:" + moment.app.lowercased() + "|" + moment.title.lowercased()
    }
}
