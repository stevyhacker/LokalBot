import AppKit
import Darwin
import Foundation

/// Pauses media that was actively playing when dictation begins and resumes
/// exactly that media when the dictation capture ends. AppleScript work runs in
/// short-lived helper processes off the main actor and is forcibly bounded so
/// an unresponsive media app can never delay push-to-talk indefinitely.
enum MediaPlaybackController {
    struct PauseSession: Sendable {
        fileprivate let targets: [PausedTarget]

        var isEmpty: Bool { targets.isEmpty }
        var processNames: [String] {
            Array(Set(targets.flatMap(\.processNames))).sorted()
        }
    }

    private struct PauseTarget: Sendable {
        let controlBundleID: String
        var processNames: Set<String> = []
    }

    fileprivate struct PausedTarget: Sendable {
        let controlBundleID: String
        let processNames: [String]
        /// Opaque state returned by the pause script. QuickTime uses document
        /// names; browsers use a per-dictation DOM marker token.
        let resumeToken: String
    }

    static func pauseActiveMediaPlayers(reason: String) async -> PauseSession {
        let targets = activePauseTargets()
        guard !targets.isEmpty else { return PauseSession(targets: []) }

        let runningBundleIDs = await MainActor.run {
            Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        }
        let token = UUID().uuidString
        let paused = await withTaskGroup(of: PausedTarget?.self) { group in
            for target in targets where runningBundleIDs.contains(target.controlBundleID) {
                group.addTask {
                    guard let script = pauseScript(
                        for: target.controlBundleID,
                        browserMarker: token),
                          let result = await runAppleScript(script),
                          !result.isEmpty,
                          result != "false",
                          result != "0" else { return nil }
                    return PausedTarget(
                        controlBundleID: target.controlBundleID,
                        processNames: target.processNames.sorted(),
                        resumeToken: result == "browser" ? token : result)
                }
            }
            var result: [PausedTarget] = []
            for await target in group {
                if let target { result.append(target) }
            }
            return result
        }

        let session = PauseSession(targets: paused)
        if !session.isEmpty {
            lokalbotLog(
                "media paused for \(reason): \(session.processNames.joined(separator: ", "))")
        }
        return session
    }

    static func resume(_ session: PauseSession, reason: String) async {
        guard !session.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            for target in session.targets {
                group.addTask {
                    guard let script = resumeScript(
                        for: target.controlBundleID,
                        token: target.resumeToken) else { return }
                    _ = await runAppleScript(script)
                }
            }
            await group.waitForAll()
        }
        lokalbotLog(
            "media resumed after \(reason): \(session.processNames.joined(separator: ", "))")
    }

    private static func activePauseTargets() -> [PauseTarget] {
        let processes = MeetingDetector.currentAudioProcesses()
        var targetsByBundleID: [String: PauseTarget] = [:]

        for process in processes {
            guard process.isRunningOutput,
                  let bundleID = process.bundleID,
                  let controlBundleID = controllableMediaBundleID(forAudioBundleID: bundleID),
                  pauseScript(for: controlBundleID, browserMarker: "probe") != nil
            else { continue }

            var target = targetsByBundleID[controlBundleID]
                ?? PauseTarget(controlBundleID: controlBundleID)
            target.processNames.insert(process.name)
            targetsByBundleID[controlBundleID] = target
        }

        return targetsByBundleID.values.sorted { $0.controlBundleID < $1.controlBundleID }
    }

    private static func controllableMediaBundleID(forAudioBundleID bundleID: String) -> String? {
        if let mediaBundleID = mediaHostBundleID(forAudioBundleID: bundleID) {
            return mediaBundleID
        }
        if let browserBundleID = MeetingDetector.hostBrowserBundleID(forAudioBundleID: bundleID) {
            return browserBundleID
        }
        return nil
    }

    private static func mediaHostBundleID(forAudioBundleID bundleID: String) -> String? {
        if AudioSourceMonitor.isMediaPlayer(bundleID) { return bundleID }
        let normalized = bundleID.lowercased()
        return AudioSourceMonitor.mediaBundleIDs.first {
            normalized.hasPrefix("\($0.lowercased()).")
        }
    }

    private static func pauseScript(for bundleID: String, browserMarker: String) -> String? {
        switch bundleID {
        case "com.spotify.client":
            return playerPauseScript(bundleID: bundleID, stateExpression: "player state is playing")
        case "com.apple.Music", "com.apple.iTunes", "com.apple.podcasts", "com.apple.TV":
            return playerPauseScript(bundleID: bundleID, stateExpression: "player state is playing")
        case "org.videolan.vlc":
            return playerPauseScript(bundleID: bundleID, stateExpression: "playing")
        case "com.apple.QuickTimePlayerX":
            return """
            tell application id "com.apple.QuickTimePlayerX"
                set pausedNames to {}
                repeat with openMovie in documents
                    try
                        if playing of openMovie then
                            set end of pausedNames to name of openMovie
                            pause openMovie
                        end if
                    end try
                end repeat
                set AppleScript's text item delimiters to ASCII character 30
                return pausedNames as text
            end tell
            """
        case "com.google.Chrome", "com.microsoft.edgemac", "com.brave.Browser",
             "company.thebrowser.Browser":
            return chromiumPauseScript(bundleID: bundleID, marker: browserMarker)
        case "com.apple.Safari":
            return safariPauseScript(marker: browserMarker)
        default:
            return nil
        }
    }

    private static func resumeScript(for bundleID: String, token: String) -> String? {
        switch bundleID {
        case "com.spotify.client", "com.apple.Music", "com.apple.iTunes",
             "com.apple.podcasts", "com.apple.TV", "org.videolan.vlc":
            return "tell application id \"\(bundleID)\" to play"
        case "com.apple.QuickTimePlayerX":
            let names = token.split(separator: Character(UnicodeScalar(30)))
                .map { "\"\(appleScriptEscaped(String($0)))\"" }
                .joined(separator: ", ")
            guard !names.isEmpty else { return nil }
            return """
            tell application id "com.apple.QuickTimePlayerX"
                set targetNames to {\(names)}
                repeat with openMovie in documents
                    try
                        if targetNames contains (name of openMovie) then play openMovie
                    end try
                end repeat
            end tell
            """
        case "com.google.Chrome", "com.microsoft.edgemac", "com.brave.Browser",
             "company.thebrowser.Browser":
            return chromiumResumeScript(bundleID: bundleID, marker: token)
        case "com.apple.Safari":
            return safariResumeScript(marker: token)
        default:
            return nil
        }
    }

    private static func playerPauseScript(bundleID: String, stateExpression: String) -> String {
        """
        tell application id "\(bundleID)"
            if \(stateExpression) then
                pause
                return "player"
            end if
        end tell
        return ""
        """
    }

    private static func chromiumPauseScript(bundleID: String, marker: String) -> String {
        let javaScript = pauseHTMLMediaJavaScript(marker: marker)
        return """
        tell application id "\(bundleID)"
            set didPause to false
            repeat with browserWindow in windows
                repeat with browserTab in tabs of browserWindow
                    try
                        set changedCount to execute browserTab javascript "\(javaScript)"
                        if (changedCount as integer) > 0 then set didPause to true
                    end try
                end repeat
            end repeat
            if didPause then return "browser"
        end tell
        return ""
        """
    }

    private static func chromiumResumeScript(bundleID: String, marker: String) -> String {
        let javaScript = resumeHTMLMediaJavaScript(marker: marker)
        return """
        tell application id "\(bundleID)"
            repeat with browserWindow in windows
                repeat with browserTab in tabs of browserWindow
                    try
                        execute browserTab javascript "\(javaScript)"
                    end try
                end repeat
            end repeat
        end tell
        """
    }

    private static func safariPauseScript(marker: String) -> String {
        let javaScript = pauseHTMLMediaJavaScript(marker: marker)
        return """
        tell application id "com.apple.Safari"
            set didPause to false
            repeat with browserWindow in windows
                repeat with browserTab in tabs of browserWindow
                    try
                        set changedCount to do JavaScript "\(javaScript)" in browserTab
                        if (changedCount as integer) > 0 then set didPause to true
                    end try
                end repeat
            end repeat
            if didPause then return "browser"
        end tell
        return ""
        """
    }

    private static func safariResumeScript(marker: String) -> String {
        let javaScript = resumeHTMLMediaJavaScript(marker: marker)
        return """
        tell application id "com.apple.Safari"
            repeat with browserWindow in windows
                repeat with browserTab in tabs of browserWindow
                    try
                        do JavaScript "\(javaScript)" in browserTab
                    end try
                end repeat
            end repeat
        end tell
        """
    }

    static func pauseHTMLMediaJavaScript(marker: String) -> String {
        let marker = javaScriptEscaped(marker)
        return """
        (() => {
          const host = location.hostname.toLowerCase();
          const conferences = ['meet.google.com', 'teams.microsoft.com', 'teams.live.com',
                               'zoom.us', 'webex.com', 'app.slack.com', 'discord.com'];
          if (conferences.some(domain => host === domain || host.endsWith('.' + domain))) return 0;
          let n = 0;
          for (const node of document.querySelectorAll('audio, video')) {
            try {
              if (!node.paused && !node.srcObject && Number.isFinite(node.duration)) {
                node.dataset.lokalbotDictationPaused = '\(marker)'; node.pause(); n++;
              }
            } catch (_) {}
          }
          return n;
        })()
        """
        .replacingOccurrences(of: "\n", with: " ")
        .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func resumeHTMLMediaJavaScript(marker: String) -> String {
        let marker = javaScriptEscaped(marker)
        return """
        (() => { for (const node of document.querySelectorAll('audio, video')) { try { if (node.dataset.lokalbotDictationPaused === '\(marker)') { delete node.dataset.lokalbotDictationPaused; node.play(); } } catch (_) {} } })()
        """
        .replacingOccurrences(of: "\n", with: " ")
        .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func appleScriptEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func javaScriptEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
    }

    private static func runAppleScript(_ source: String) async -> String? {
        let controller = ScriptProcessController()
        let execution = Task.detached(priority: .utility) { () -> String? in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", source]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            guard controller.attach(process) else { return nil }
            defer { controller.detach(process) }
            do { try process.run() } catch { return nil }
            controller.processDidStart(process)
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let timeout = Task.detached {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            controller.cancel()
        }
        defer { timeout.cancel() }
        return await withTaskCancellationHandler {
            let value = await execution.value
            return Task.isCancelled ? nil : value
        } onCancel: {
            controller.cancel()
            execution.cancel()
        }
    }
}

/// Bridges the AppleScript timeout/cancellation path to its blocking helper.
/// SIGTERM gets a brief grace period before a PID-identity-checked SIGKILL so
/// the stdout reader and `waitUntilExit()` cannot remain blocked forever.
final class ScriptProcessController: @unchecked Sendable {
    typealias ProcessStartTime = @Sendable (pid_t) -> UInt64?
    typealias SignalSender = @Sendable (pid_t, Int32) -> Void

    private let lock = NSLock()
    private let terminationGraceSeconds: TimeInterval
    private let processStartTime: ProcessStartTime
    private let sendSignal: SignalSender
    private var process: Process?
    private var cancelled = false

    init(
        terminationGraceSeconds: TimeInterval = 0.25,
        processStartTime: @escaping ProcessStartTime = {
            SystemResourceSampler.processUsage(for: $0)?.startTime
        },
        sendSignal: @escaping SignalSender = { pid, signal in
            _ = kill(pid, signal)
        }
    ) {
        self.terminationGraceSeconds = terminationGraceSeconds
        self.processStartTime = processStartTime
        self.sendSignal = sendSignal
    }

    func attach(_ process: Process) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return false }
        self.process = process
        return true
    }

    func detach(_ process: Process) {
        lock.lock()
        if self.process === process { self.process = nil }
        lock.unlock()
    }

    func processDidStart(_ process: Process) {
        lock.lock()
        let shouldTerminate = cancelled && self.process === process
        lock.unlock()
        if shouldTerminate, process.isRunning { terminate(process) }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let process = self.process
        lock.unlock()
        guard let process, process.isRunning else { return }
        terminate(process)
    }

    private func terminate(_ process: Process) {
        let pid = process.processIdentifier
        let expectedStartTime = processStartTime(pid)
        process.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + terminationGraceSeconds
        ) { [weak self, weak process] in
            guard let self, let process else { return }
            self.killIfStillAttached(
                process, pid: pid, expectedStartTime: expectedStartTime)
        }
    }

    private func killIfStillAttached(
        _ process: Process,
        pid: pid_t,
        expectedStartTime: UInt64?
    ) {
        lock.lock()
        let isSameCancelledProcess = cancelled && self.process === process
        lock.unlock()
        guard isSameCancelledProcess,
              process.isRunning,
              process.processIdentifier == pid,
              let expectedStartTime,
              processStartTime(pid) == expectedStartTime
        else { return }
        sendSignal(pid, SIGKILL)
    }
}
