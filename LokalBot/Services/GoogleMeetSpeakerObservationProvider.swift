import AppKit
import CryptoKit
import ScreenCaptureKit

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
        var issue: SpeakerObservationIssue?
        var verifiedTileNames = Set<String>()
        if tiles.contains(where: { $0.speaking == nil || $0.requiresNameVerification }) {
            if !CGPreflightScreenCaptureAccess() {
                issue = .screenPermission
            } else {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                let candidates = content.windows.map {
                    CaptureWindow(id: $0.windowID, processID: $0.owningApplication?.processID, frame: $0.frame)
                }
                if let windowID = Self.captureWindowID(snapshot: before, windows: candidates),
                   let window = content.windows.first(where: { $0.windowID == windowID }) {
                    try await frames.start(window: window)
                    if let frame = frames.frame(), frame.hostTime > lastFrameTime,
                       abs(RecordingAudioClock.now - frame.hostTime) < 0.75 {
                        lastFrameTime = frame.hostTime
                        frameTime = frame.hostTime
                        for index in tiles.indices {
                            let tile = tiles[index]
                            let cacheKey = source + "|" + epoch + "|" + tile.name
                            let cached = (verifiedNames[cacheKey] ?? 0) >= frame.hostTime - 5
                            let result = await Task.detached(priority: .utility) { [frames] in
                                let named = cached || frames.verifiesName(tile, in: frame, window: before.windowFrame)
                                let active = named && frames.activeTile(tile, in: frame, window: before.windowFrame, verifyName: false)
                                return (named, active)
                            }.value
                            if result.0 {
                                if !cached { verifiedNames[cacheKey] = frame.hostTime }
                                verifiedTileNames.insert(tile.name)
                            }
                            if tile.speaking == nil { tiles[index].speaking = result.1 }
                        }
                        if verifiedNames.count > 120 { verifiedNames = verifiedNames.filter { $0.value > frame.hostTime - 5 } }
                    } else { issue = .waitingForFrame }
                } else { issue = .windowChanged }
            } catch { issue = .frameUnavailable }
            }
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
        tiles.removeAll { $0.requiresNameVerification && !verifiedTileNames.contains($0.name) }
        let participants = MeetingParticipantName.merging([], tiles.map {
            .init(name: $0.name, source: verifiedTileNames.contains($0.name) ? .ocr : .accessibility, isSelf: $0.isSelf)
        })
        // A remote audio track cannot establish who owns an unidentified self tile.
        let selfKnown = !before.selfNames.isEmpty || before.tiles.contains(where: \.isSelf)
        let now = frameTime ?? (before.hostStart + before.hostEnd) / 2
        let uncertainty = frameTime == nil ? (before.hostEnd - before.hostStart) / 2 : 0.025
        let observations = tiles.map { tile in
            ParticipantObservation(reference: Self.digest(ParticipantObservation.nameKey(tile.name)), displayName: tile.name,
                layoutEpoch: epoch, hostStart: now - uncertainty, hostEnd: now + max(uncertainty, 0.001),
                active: issue == nil && selfKnown && tile.speaking == true, muted: tile.muted, isSelf: tile.isSelf,
                unique: !tile.sharedRoom && duplicates[ParticipantObservation.nameKey(tile.name)]?.count == 1)
        }
        if issue == nil && tiles.isEmpty { issue = .layoutUnavailable }
        if issue == nil && !selfKnown { issue = .selfIdentityUnavailable }
        return .init(sourceKey: source, observations: observations, reason: issue?.explanation, issue: issue, participants: participants)
    }

    nonisolated private static func digest(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
    func stop() async { monitor.stop(); lastFrameTime = 0; verifiedNames = [:]; await frames.stop() }
}
