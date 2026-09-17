import AppKit
import CryptoKit
import ScreenCaptureKit

struct MeetingSpeakerObservationBatch: Sendable {
    var sourceKey: String
    var observations: [ParticipantObservation]
    var reason: String?
    var issue: SpeakerObservationIssue?
}

@MainActor protocol MeetingSpeakerObservationProvider: AnyObject {
    func observe(config: AppSettings, expectedMeetingURL: URL?, capturedBundleID: String, visual: Bool) async -> MeetingSpeakerObservationBatch
    func stop() async
}

@MainActor final class GoogleMeetSpeakerObservationProvider: MeetingSpeakerObservationProvider {
    struct CaptureWindow: Sendable {
        var id: CGWindowID
        var processID: pid_t?
        var frame: CGRect
    }

    private let reader = MeetingParticipantAccessibilityReader()
    private let frames = MeetingSpeakerFrameSource()
    private let monitor = MeetingSpeakerSourceMonitor()
    private var boundURL: String?
    private var lastFrameTime: Double = 0
    private var verifiedNames: [String: Double] = [:]

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

    /// AX and ScreenCaptureKit do not share a window-title contract. Associate
    /// their windows by process and the complete frame, requiring uniqueness.
    /// The selected Meet URL and privacy checks are revalidated after capture.
    nonisolated static func captureWindowID(snapshot: MeetingParticipantSnapshot, windows: [CaptureWindow]) -> CGWindowID? {
        let frame = snapshot.windowFrame
        guard frame.minX.isFinite, frame.minY.isFinite, frame.width.isFinite, frame.height.isFinite,
              frame.width > 0, frame.height > 0 else { return nil }
        let matching = windows.filter {
            $0.processID == snapshot.processID
                && abs($0.frame.minX - frame.minX) < 3 && abs($0.frame.minY - frame.minY) < 3
                && abs($0.frame.width - frame.width) < 3 && abs($0.frame.height - frame.height) < 3
        }
        return matching.count == 1 ? matching.first?.id : nil
    }

    private func unavailable(_ issue: SpeakerObservationIssue, source: String = "") async -> MeetingSpeakerObservationBatch {
        if issue != .waitingForFrame { await frames.stop(); verifiedNames = [:] }
        return MeetingSpeakerObservationBatch(sourceKey: source, observations: [], reason: issue.explanation, issue: issue)
    }

    func observe(config: AppSettings, expectedMeetingURL: URL?, capturedBundleID: String, visual: Bool) async -> MeetingSpeakerObservationBatch {
        let expectedURL = boundURL ?? expectedMeetingURL.flatMap { Self.meetURL($0.absoluteString) }
        guard expectedMeetingURL == nil || expectedURL != nil else { return await unavailable(.sourceRejected) }
        guard Self.windowAllowed(capturedBundleID: capturedBundleID,
            foregroundBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier, expectedURL: expectedURL) else {
            return await unavailable(capturedBundleID == "com.google.Chrome" ? .unboundBackgroundWindow : .chromeUnavailable)
        }
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome")
        guard applications.count == 1, let app = applications.first else { return await unavailable(.chromeUnavailable) }
        guard screenAvailable else {
            return await unavailable(.screenUnavailable)
        }
        monitor.start(processID: app.processIdentifier)
        let sourceRevision = monitor.revision
        let captured = await reader.capture(processID: app.processIdentifier, expectedURL: expectedURL.flatMap(URL.init(string:)))
        guard let before = captured.snapshot else {
            return await unavailable(captured.issue ?? .sourceUnavailable)
        }
        guard monitor.revision == sourceRevision,
              Self.sourceAllowed(snapshot: before, config: config, expectedURL: expectedURL) else {
            return await unavailable(.sourceRejected)
        }
        if boundURL == nil { boundURL = before.url }
        let source = Self.digest("\(app.processIdentifier)|\(before.url)|\(before.title)|\(before.windowFrame)|\(sourceRevision)")
        guard visual else {
            await frames.stop()
            verifiedNames = [:]
            return .init(sourceKey: source, observations: [], reason: nil)
        }
        guard !before.tiles.isEmpty, before.tiles.count <= 60 else {
            return await unavailable(.layoutUnavailable, source: source)
        }
        let epoch = Self.digest(before.tiles.map { "\($0.name)|\($0.frame)" }.sorted().joined(separator: "|"))
        let duplicates = Dictionary(grouping: before.tiles, by: { ParticipantObservation.nameKey($0.name) })
        var tiles = before.tiles
        var frameTime: Double?
        if tiles.contains(where: { $0.speaking == nil }) {
            guard CGPreflightScreenCaptureAccess() else {
                return await unavailable(.screenPermission, source: source)
            }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                let candidates = content.windows.map {
                    CaptureWindow(id: $0.windowID, processID: $0.owningApplication?.processID, frame: $0.frame)
                }
                guard let windowID = Self.captureWindowID(snapshot: before, windows: candidates),
                      let window = content.windows.first(where: { $0.windowID == windowID }) else { return await unavailable(.windowChanged) }
                try await frames.start(window: window)
                guard let frame = frames.frame(), frame.hostTime > lastFrameTime,
                      abs(RecordingAudioClock.now - frame.hostTime) < 0.75 else {
                    return await unavailable(.waitingForFrame, source: source)
                }
                lastFrameTime = frame.hostTime
                frameTime = frame.hostTime
                for index in tiles.indices where tiles[index].speaking == nil {
                    let tile = tiles[index]
                    let cacheKey = epoch + "|" + tile.name
                    let verify = (verifiedNames[cacheKey] ?? 0) < frame.hostTime - 5
                    let active = await Task.detached(priority: .utility) { [frames] in
                        frames.activeTile(tile, in: frame, window: before.windowFrame, verifyName: verify)
                    }.value
                    if active && verify { verifiedNames[cacheKey] = frame.hostTime }
                    tiles[index].speaking = active
                }
                if verifiedNames.count > 120 { verifiedNames = verifiedNames.filter { $0.value > frame.hostTime - 5 } }
            } catch { return await unavailable(.frameUnavailable) }
        }
        // The selected tab must remain the same recorded Meet document, even
        // when another app is foreground. Activity changes are not layout changes.
        let revalidated = await reader.capture(processID: app.processIdentifier, expectedURL: expectedURL.flatMap(URL.init(string:)))
        guard let after = revalidated.snapshot else { return await unavailable(revalidated.issue ?? .sourceUnavailable) }
        guard screenAvailable else { return await unavailable(.screenUnavailable) }
        guard monitor.revision == sourceRevision,
              after.url == before.url, after.title == before.title, after.windowFrame == before.windowFrame,
              Self.sourceAllowed(snapshot: after, config: config, expectedURL: boundURL),
              Self.sameLayout(before.tiles, after.tiles), monitor.revision == sourceRevision else { return await unavailable(.sourceChanged) }
        for index in tiles.indices {
            guard let later = after.tiles.first(where: { $0.name == tiles[index].name && $0.frame == tiles[index].frame }) else { continue }
            if later.speaking == false || later.muted { tiles[index].speaking = false }
        }
        let now = frameTime ?? (before.hostStart + before.hostEnd) / 2
        let uncertainty = frameTime == nil ? (before.hostEnd - before.hostStart) / 2 : 0.025
        let observations = tiles.map { tile in
            ParticipantObservation(reference: Self.digest(ParticipantObservation.nameKey(tile.name)), displayName: tile.name,
                layoutEpoch: epoch, hostStart: now - uncertainty, hostEnd: now + max(uncertainty, 0.001),
                active: tile.speaking == true, muted: tile.muted, isSelf: tile.isSelf,
                unique: !tile.sharedRoom && duplicates[ParticipantObservation.nameKey(tile.name)]?.count == 1)
        }
        return .init(sourceKey: source, observations: observations, reason: nil)
    }

    nonisolated private static func digest(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
    func stop() async { monitor.stop(); lastFrameTime = 0; verifiedNames = [:]; await frames.stop() }
}
