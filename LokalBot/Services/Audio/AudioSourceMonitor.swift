import AppKit
import AudioToolbox
import Foundation

@MainActor
final class AudioSourceMonitor: ObservableObject {

    @Published private(set) var detectedProcess: AudioProcess?

    var isRecordingActive = false {
        didSet {
            if isRecordingActive {
                detectedProcess = nil
                candidateExpiryTask?.cancel()
                candidateExpiryTask = nil
            }
        }
    }

    private static let meetingBundleIDs: Set<String> = [
        "us.zoom.xos", "us.zoom.CptHost",
        "com.microsoft.teams", "com.microsoft.teams2",
        "com.apple.FaceTime",
        "com.webex.meetingmanager", "com.cisco.webexmeetingsapp",
        "Cisco-Systems.Spark", "Cisco-Systems.SparkHelper",
        "com.tinyspeck.slackmacgap",
        "com.hnc.Discord",
        "com.google.Chrome", "com.apple.Safari", "org.mozilla.firefox",
        "com.microsoft.edgemac", "com.brave.Browser",
        "com.operasoftware.Opera", "company.thebrowser.Browser",
        "com.loom.desktop", "com.pop.pop.app", "com.riverside.app",
        "com.tencent.meeting", "com.tencent.tencentmeeting",
        "com.electron.lark", "com.bytedance.lark.helper",
        "com.larksuite.larkApp", "com.larksuite.larkApp.helper",
        "com.alibaba.DingTalkMac", "com.alibaba.DingTalk-Helper",
        "com.tencent.WeWorkMac",
    ]

    private static let ignoredBundleIDs: Set<String> = [
        AppIdentifiers.Identity.release.bundleID,
        AppIdentifiers.Identity.development.bundleID,
        AppIdentifiers.Identity.uiTestHost.bundleID,
        "com.apple.controlcenter",
        "com.apple.SystemSounds",
        "com.apple.finder",
        "com.apple.notificationcenterui",
    ]

    nonisolated static let mediaBundleIDs: Set<String> = [
        "com.spotify.client",
        "com.apple.Music",
        "com.apple.iTunes",
        "com.amazon.music",
        "com.tidal.desktop",
        "com.deezer.deezer-desktop",
        "com.netease.163music",
        "com.tencent.QQMusicMac",
        "com.swinsian.Swinsian",
        "com.audirvana.Audirvana",
        "com.foobar2000.mac",
        "com.roon.Roon",
        "com.coppertino.Vox",
        "tv.plex.plexamp",
        "com.apple.podcasts",
        "com.apple.TV",
        "com.apple.QuickTimePlayerX",
        "org.videolan.vlc",
        "com.colliderli.iina",
    ]

    nonisolated static func isMediaPlayer(_ bundleID: String) -> Bool {
        mediaBundleIDs.contains(bundleID)
    }

    private static let pollInterval: TimeInterval = 3.0
    private static let candidateTimeout: TimeInterval = 20.0

    private var pollTimer: Timer?
    private var pollTask: Task<Void, Never>?
    private var knownActiveObjectIDs: Set<AudioObjectID> = []
    private var candidateExpiryTask: Task<Void, Never>?

    func start() {
        stop()
        seedCurrentState()
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        pollTask?.cancel()
        pollTask = nil
        candidateExpiryTask?.cancel()
        candidateExpiryTask = nil
    }

    @discardableResult
    func accept() -> AudioProcess? {
        candidateExpiryTask?.cancel()
        candidateExpiryTask = nil
        let process = detectedProcess
        detectedProcess = nil
        return process
    }

    func reseed() {
        seedCurrentState()
    }

    private func seedCurrentState() {
        let processes = MeetingDetector.currentAudioProcesses()
        knownActiveObjectIDs = Set(processes.filter(\.isRunningOutput).map(\.objectID))
    }

    private func poll() {
        guard !isRecordingActive, pollTask == nil else { return }
        pollTask = Task { [weak self] in
            let processes = await Task.detached(priority: .utility) {
                MeetingDetector.currentAudioProcesses()
            }.value
            guard let self else { return }
            self.pollTask = nil
            guard !self.isRecordingActive else { return }
            self.apply(processes)
        }
    }

    func apply(_ processes: [AudioProcess]) {
        let active = processes.filter(\.isRunningOutput)
        let activeIDs = Set(active.map(\.objectID))

        let newlyActiveIDs = activeIDs.subtracting(knownActiveObjectIDs)
        knownActiveObjectIDs = activeIDs

        guard !newlyActiveIDs.isEmpty else { return }

        let candidates = active.filter { process in
            guard newlyActiveIDs.contains(process.objectID) else { return false }
            if let bundleID = process.bundleID {
                if Self.ignoredBundleIDs.contains(bundleID) { return false }
                if Self.isMediaPlayer(bundleID) { return false }
            }
            return true
        }

        let meetingApp = candidates.first(where: Self.isMeetingApp)

        if let held = detectedProcess {
            if let meetingApp, !Self.isMeetingApp(held) {
                detectedProcess = meetingApp
                scheduleCandidateExpiry()
                knownActiveObjectIDs.subtract(candidates.map(\.objectID).filter { $0 != meetingApp.objectID })
            } else {
                knownActiveObjectIDs.subtract(candidates.map(\.objectID))
            }
            return
        }

        if let best = meetingApp ?? candidates.first {
            detectedProcess = best
            scheduleCandidateExpiry()
        }
    }

    private static func isMeetingApp(_ process: AudioProcess) -> Bool {
        process.bundleID.map(meetingBundleIDs.contains) ?? false
    }

    private func scheduleCandidateExpiry() {
        candidateExpiryTask?.cancel()
        candidateExpiryTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.candidateTimeout))
            guard !Task.isCancelled else { return }
            detectedProcess = nil
        }
    }
}
