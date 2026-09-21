import AppKit
import CryptoKit

struct MeetingSpeakerObservationBatch: Sendable {
    var sourceKey: String
    var observations: [ParticipantObservation]
    var reason: String?
    var issue: SpeakerObservationIssue?
    var participants: [MeetingParticipantName] = []
}

@MainActor protocol MeetingSpeakerObservationProvider: AnyObject {
    func observe(config: AppSettings, expectedMeetingURL: URL?, capturedBundleID: String, visual: Bool) async -> MeetingSpeakerObservationBatch
    func stop() async
}

@MainActor final class GoogleMeetSpeakerObservationProvider: MeetingSpeakerObservationProvider {
    private let reader = MeetingParticipantAccessibilityReader()
    private let monitor = MeetingSpeakerSourceMonitor()
    private var boundURL: String?

    private var screenAvailable: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (session["CGSSessionScreenIsLocked"] as? Bool) != true
            && (session[kCGSessionOnConsoleKey as String] as? Bool) == true
    }

    nonisolated static func meetURL(_ raw: String) -> String? {
        guard let components = URLComponents(string: raw), components.scheme == "https",
              components.host?.lowercased() == "meet.google.com", components.user == nil, components.password == nil,
              components.port == nil || components.port == 443,
              components.path.range(of: #"^/[a-z]{3}-[a-z]{4}-[a-z]{3}$"#, options: .regularExpression) != nil else { return nil }
        return "https://meet.google.com" + components.path
    }

    nonisolated static func sourceAllowed(snapshot: MeetingParticipantSnapshot, config: AppSettings, expectedURL: String?) -> Bool {
        guard let url = meetURL(snapshot.url), expectedURL == nil || expectedURL == url,
              !ScreenContextPrivacy.isPrivateWindow(title: snapshot.title),
              !ScreenContextPrivacy.isExcluded(sourceURL: url, rules: config.excludedScreenDomainList),
              !ScreenshotCaptureLayout.isExcluded(appName: "Google Chrome", excludedApps: config.excludedAppList),
              !snapshot.otherAudibleTabs,
              snapshot.hostStart.isFinite, snapshot.hostEnd.isFinite,
              snapshot.hostEnd >= snapshot.hostStart,
              snapshot.hostEnd - snapshot.hostStart <= MeetingParticipantAccessibilityReader.observationBudget else { return false }
        return true
    }

    nonisolated static func windowAllowed(capturedBundleID: String, foregroundBundleID: String?, expectedURL: String?) -> Bool {
        capturedBundleID == "com.google.Chrome"
            && (foregroundBundleID == "com.google.Chrome" || expectedURL.flatMap(meetURL) != nil)
    }

    nonisolated static func sameLayout(_ before: [MeetingParticipantTile], _ after: [MeetingParticipantTile]) -> Bool {
        func stable(_ tiles: [MeetingParticipantTile]) -> [MeetingParticipantTile] {
            tiles.map { tile in var copy = tile; copy.speaking = nil; copy.muted = false; return copy }
                .sorted { "\($0.name)|\($0.frame)" < "\($1.name)|\($1.frame)" }
        }
        return stable(before) == stable(after)
    }

    private func unavailable(_ issue: SpeakerObservationIssue, source: String = "") -> MeetingSpeakerObservationBatch {
        return MeetingSpeakerObservationBatch(sourceKey: source, observations: [], reason: issue.explanation, issue: issue)
    }

    func observe(config: AppSettings, expectedMeetingURL: URL?, capturedBundleID: String, visual: Bool) async -> MeetingSpeakerObservationBatch {
        let expectedURL = boundURL ?? expectedMeetingURL.flatMap { Self.meetURL($0.absoluteString) }
        guard expectedMeetingURL == nil || expectedURL != nil else { return unavailable(.sourceRejected) }
        guard Self.windowAllowed(capturedBundleID: capturedBundleID,
            foregroundBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier, expectedURL: expectedURL) else {
            return unavailable(capturedBundleID == "com.google.Chrome" ? .unboundBackgroundWindow : .chromeUnavailable)
        }
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome")
        guard applications.count == 1, let app = applications.first else { return unavailable(.chromeUnavailable) }
        guard screenAvailable else {
            return unavailable(.screenUnavailable)
        }
        monitor.start(processID: app.processIdentifier)
        let sourceRevision = monitor.revision
        let captured = await reader.capture(processID: app.processIdentifier, expectedURL: expectedURL.flatMap(URL.init(string:)))
        guard let before = captured.snapshot else {
            return unavailable(captured.issue ?? .sourceUnavailable)
        }
        guard monitor.revision == sourceRevision,
              Self.sourceAllowed(snapshot: before, config: config, expectedURL: expectedURL) else {
            return unavailable(.sourceRejected)
        }
        if boundURL == nil { boundURL = before.url }
        let source = Self.digest("\(app.processIdentifier)|\(before.url)|\(before.title)|\(before.windowFrame)|\(sourceRevision)")
        guard visual else {
            return .init(sourceKey: source, observations: [], reason: nil)
        }
        guard !before.tiles.isEmpty, before.tiles.count <= 60 else {
            return unavailable(.layoutUnavailable, source: source)
        }
        var tiles = before.tiles
        // The selected tab must remain the same recorded Meet document, even
        // when another app is foreground. Activity changes are not layout changes.
        let revalidated = await reader.capture(processID: app.processIdentifier, expectedURL: expectedURL.flatMap(URL.init(string:)))
        guard let after = revalidated.snapshot else { return unavailable(revalidated.issue ?? .sourceUnavailable) }
        guard screenAvailable else { return unavailable(.screenUnavailable) }
        guard monitor.revision == sourceRevision,
              after.url == before.url, after.title == before.title, after.windowFrame == before.windowFrame,
              Self.sourceAllowed(snapshot: after, config: config, expectedURL: boundURL),
              Self.sameLayout(before.tiles, after.tiles), monitor.revision == sourceRevision else { return unavailable(.sourceChanged) }
        for index in tiles.indices {
            guard let later = after.tiles.first(where: { $0.name == tiles[index].name && $0.frame == tiles[index].frame }) else { continue }
            if later.speaking != true || later.muted { tiles[index].speaking = false }
        }
        var snapshot = before
        snapshot.tiles = tiles
        return Self.accessibilityBatch(snapshot: snapshot, sourceKey: source)
    }

    /// Names remain useful for manual assignment even when Meet exposes no
    /// explicit speaking label. Missing activity never triggers pixel capture.
    nonisolated static func accessibilityBatch(snapshot: MeetingParticipantSnapshot, sourceKey: String) -> MeetingSpeakerObservationBatch {
        let epoch = Self.digest(snapshot.tiles.map { "\($0.name)|\($0.frame)" }.sorted().joined(separator: "|"))
        let duplicates = Dictionary(grouping: snapshot.tiles, by: { ParticipantObservation.nameKey($0.name) })
        let participants = MeetingParticipantName.merging([], snapshot.tiles.map {
            .init(name: $0.name, source: .accessibility, isSelf: $0.isSelf)
        })
        // A remote audio track cannot establish who owns an unidentified self tile.
        let selfKnown = !snapshot.selfNames.isEmpty || snapshot.tiles.contains(where: \.isSelf)
        let now = (snapshot.hostStart + snapshot.hostEnd) / 2
        let uncertainty = (snapshot.hostEnd - snapshot.hostStart) / 2
        let observations = snapshot.tiles.map { tile in
            ParticipantObservation(reference: Self.digest(ParticipantObservation.nameKey(tile.name)), displayName: tile.name,
                layoutEpoch: epoch, hostStart: now - uncertainty, hostEnd: now + max(uncertainty, 0.001),
                active: selfKnown && tile.speaking == true, muted: tile.muted, isSelf: tile.isSelf,
                unique: !tile.sharedRoom && duplicates[ParticipantObservation.nameKey(tile.name)]?.count == 1)
        }
        var issue: SpeakerObservationIssue?
        if snapshot.tiles.isEmpty { issue = .layoutUnavailable }
        if issue == nil && !selfKnown { issue = .selfIdentityUnavailable }
        return .init(sourceKey: sourceKey, observations: observations, reason: issue?.explanation, issue: issue, participants: participants)
    }

    nonisolated private static func digest(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
    func stop() async { monitor.stop() }
}
