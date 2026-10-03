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
        /// When the next stretch began, or the end of the recording.
        let endOffset: TimeInterval
        let app: String
        let title: String
        /// The site or service named in a browser tab's title ("Gmail").
        let site: String?
        let sourceURL: String
        let hasPixels: Bool
        /// The call itself (its app window or conference tab) was in front.
        let isCall: Bool

        var id: Int64 { snapshotID }
    }

    /// A distinct document, page, or window that was referenced during the
    /// call, in order of first appearance.
    struct Material: Identifiable, Equatable, Sendable {
        let id: String
        let title: String
        let app: String
        /// The site name from the tab title, else a web page's host.
        let site: String?
        let firstOffset: TimeInterval
        let firstSnapshotID: Int64
        /// Approximate time in front, from capture to the next change.
        let secondsOnScreen: TimeInterval
        /// A web address that reopens this page, when the stored one can.
        let pageURL: URL?
    }

    static let maximumMaterials = 12

    /// Every stretch in order, including the call's own window.
    var moments: [Moment] = []
    var materials: [Material] = []

    var isEmpty: Bool { materials.isEmpty }

    /// The stretch in front at an audio position.
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
        materials.map { "\($0.title) (\($0.site ?? $0.app))" }
    }

    static func build(meeting: Meeting, screenshots: [ActivityStore.Screenshot]) -> Self {
        let start = meeting.startedAt
        let end = meeting.endedAt ?? start.addingTimeInterval(meeting.recordedDuration ?? 0)
        let playable = max(0, meeting.recordedDuration ?? end.timeIntervalSince(start))
        var stretches: [(shot: ActivityStore.Screenshot, offset: TimeInterval, page: Page, isCall: Bool)] = []
        for shot in screenshots.sorted(by: { ($0.ts, $0.id) < ($1.ts, $1.id) }) {
            guard shot.ts >= start.addingTimeInterval(-5), shot.ts <= end.addingTimeInterval(5) else { continue }
            let page = page(for: shot)
            guard !page.title.isEmpty else { continue }
            let isCall = isCallWindow(shot, meeting: meeting)
            if let last = stretches.last, last.shot.app == shot.app, last.page == page, last.isCall == isCall {
                continue
            }
            let offset = min(max(0, shot.ts.timeIntervalSince(start)), playable)
            stretches.append((shot, offset, page, isCall))
        }

        let moments = stretches.indices.map { index in
            let stretch = stretches[index]
            let next = stretches.indices.contains(index + 1) ? stretches[index + 1].offset : playable
            return Moment(
                snapshotID: stretch.shot.id, capturedAt: stretch.shot.ts, offset: stretch.offset,
                endOffset: max(stretch.offset, next), app: stretch.shot.app, title: stretch.page.title,
                site: stretch.page.site ?? webHost(stretch.shot.sourceURL), sourceURL: stretch.shot.sourceURL,
                hasPixels: stretch.shot.hasPixels, isCall: stretch.isCall)
        }

        var materials: [Material] = []
        var indexByKey: [String: Int] = [:]
        for moment in moments where !moment.isCall && !isBlankPage(moment) {
            let key = materialKey(moment)
            let seconds = moment.endOffset - moment.offset
            if let index = indexByKey[key] {
                let existing = materials[index]
                materials[index] = Material(
                    id: key, title: existing.title, app: existing.app, site: existing.site,
                    firstOffset: existing.firstOffset, firstSnapshotID: existing.firstSnapshotID,
                    secondsOnScreen: existing.secondsOnScreen + seconds,
                    pageURL: existing.pageURL ?? reopenableURL(moment.sourceURL))
                continue
            }
            indexByKey[key] = materials.count
            materials.append(Material(
                id: key, title: moment.title, app: moment.app, site: moment.site,
                firstOffset: moment.offset, firstSnapshotID: moment.snapshotID, secondsOnScreen: seconds,
                pageURL: reopenableURL(moment.sourceURL)))
        }
        // A long call can touch dozens of windows; keep the ones that stayed
        // in front longest, still listed in the order they first appeared.
        if materials.count > maximumMaterials {
            let kept = Set(materials.sorted { $0.secondsOnScreen > $1.secondsOnScreen }
                .prefix(maximumMaterials).map(\.id))
            materials = materials.filter { kept.contains($0.id) }
        }
        return Self(moments: moments, materials: materials)
    }

    // MARK: - Helpers

    /// A readable page or document name and, for browser tabs, the site the
    /// tab's title names.
    struct Page: Equatable, Sendable {
        let title: String
        let site: String?
    }

    static func page(for shot: ActivityStore.Screenshot) -> Page {
        let isBrowser = browserApps.contains(shot.app.lowercased())
        // A browser's document name is the last piece of the page's URL
        // ("#inbox", a message id), not something the user would recognize.
        let document = shot.documentName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !isBrowser, !document.isEmpty { return Page(title: document, site: nil) }
        let title = TimelineWorkSession.strippingBrowserChrome(shot.windowTitle)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return Page(title: shot.app, site: nil) }
        return isBrowser ? splittingSite(from: title) : Page(title: title, site: nil)
    }

    /// "Weekly sync - you@example.com - Gmail" reads as the page "Weekly
    /// sync" on "Gmail". Account addresses and unread counts are dropped so
    /// revisits of one page group together.
    static func splittingSite(from title: String) -> Page {
        var last: (separator: String, range: Range<String.Index>)?
        for separator in [" - ", " — ", " – ", " | "] {
            guard let range = title.range(of: separator, options: .backwards) else { continue }
            if last.map({ range.lowerBound > $0.range.lowerBound }) ?? true { last = (separator, range) }
        }
        var page = title
        var site: String?
        if let last {
            let candidate = String(title[last.range.upperBound...]).trimmingCharacters(in: .whitespaces)
            if (1...32).contains(candidate.count),
               candidate.split(separator: " ").count <= 4,
               !candidate.contains("@") {
                site = candidate
                page = String(title[..<last.range.lowerBound])
            }
            page = page.components(separatedBy: last.separator)
                .filter { !isAccountAddress($0) }
                .joined(separator: last.separator)
        }
        page = page.replacingOccurrences(of: #"^\(\d+\)\s+|\s+\(\d+\)$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard !page.isEmpty else { return Page(title: title, site: nil) }
        return Page(title: page, site: site)
    }

    private static func isAccountAddress(_ segment: String) -> Bool {
        let trimmed = segment.trimmingCharacters(in: .whitespaces)
        return trimmed.contains("@") && !trimmed.contains(" ") && trimmed.contains(".")
    }

    private static func webHost(_ sourceURL: String) -> String? {
        guard let url = URL(string: sourceURL), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", let host = url.host(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Stored addresses drop their query and fragment, so a page chosen by
    /// either (a Gmail message, a YouTube video, a search) gets no link
    /// rather than one that opens the wrong page.
    static func reopenableURL(_ sourceURL: String) -> URL? {
        guard let host = webHost(sourceURL)?.lowercased(), !queryRoutedHosts.contains(host),
              let url = URL(string: sourceURL) else { return nil }
        let path = url.pathComponents.filter { $0 != "/" }
        guard let last = path.last, !["search", "results", "watch"].contains(last.lowercased()) else {
            return nil
        }
        return url
    }

    private static let queryRoutedHosts: Set<String> = [
        "mail.google.com", "google.com", "youtube.com", "m.youtube.com", "bing.com", "duckduckgo.com",
    ]

    /// The call itself (the meeting app's window or a conference tab) is not
    /// material the user referenced.
    private static func isCallWindow(_ shot: ActivityStore.Screenshot, meeting: Meeting) -> Bool {
        if let url = URL(string: shot.sourceURL), ConferenceURLDetector.isMeetingURL(url) { return true }
        let app = shot.app.lowercased()
        if browserApps.contains(app) {
            // Captures can lack the tab's URL. A tab using the camera or
            // microphone during the meeting is the call, and so is a Meet tab.
            let segments = shot.windowTitle.lowercased().components(separatedBy: " - ")
            if segments.contains(where: callStatusMarkers.contains) { return true }
            if segments.first == "meet" || shot.windowTitle.hasPrefix("Meet – ") { return true }
            if let code = meeting.meetingURL.flatMap(meetingCode), shot.documentName.hasPrefix(code) {
                return true
            }
            return false
        }
        let meetingApp = meeting.appName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !meetingApp.isEmpty, shot.app.caseInsensitiveCompare(meetingApp) == .orderedSame else {
            return false
        }
        return shot.sourceURL.isEmpty && shot.documentName.isEmpty
    }

    private static func meetingCode(_ url: URL) -> String? {
        let code = url.lastPathComponent
        return code.count >= 6 && code != "/" ? code : nil
    }

    private static let callStatusMarkers: Set<String> = [
        "camera recording", "microphone recording", "camera and microphone recording",
    ]

    private static let browserApps: Set<String> = [
        "safari", "google chrome", "chrome", "arc", "firefox", "microsoft edge", "brave browser",
        "opera", "vivaldi", "orion", "dia",
    ]

    private static func isBlankPage(_ moment: Moment) -> Bool {
        ["new tab", "start page", "favorites"].contains(moment.title.lowercased())
            && browserApps.contains(moment.app.lowercased())
    }

    /// Keyed by the readable title, not the URL: many pages share a path
    /// (every Gmail message, every YouTube video), and captures can lack
    /// the URL altogether.
    private static func materialKey(_ moment: Moment) -> String {
        moment.app.lowercased() + "|" + moment.title.lowercased()
    }
}
