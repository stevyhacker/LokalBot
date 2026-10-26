import AppKit
import AudioToolbox
import Foundation

/// Polls Core Audio's process list for new audio-producing apps and publishes
/// them as candidates for automatic recording. A second detection signal next
/// to `MeetingDetector`'s "is the mic in use" — catches the cases the mic
/// signal misses (Zoom call with mic muted, a meeting in a browser tab the
/// user opened *before* unmuting). Pattern from Seminarly's
/// `AudioSourceMonitor`, adapted to LokalBot's coordinator.
@MainActor
final class AudioSourceMonitor: ObservableObject {

    /// The most recently detected new audio source. `AppState` observes this
    /// candidate and decides whether it is safe to start recording.
    @Published private(set) var detectedProcess: AudioProcess?

    /// Set by `AppState` while a recording is in flight. Suppresses new
    /// detections because the app being recorded is itself producing output.
    var isRecordingActive = false {
        didSet {
            if isRecordingActive {
                detectedProcess = nil
                candidateExpiryTask?.cancel()
                candidateExpiryTask = nil
            }
        }
    }

    /// Bundle IDs of conferencing/meeting apps prioritized over generic audio
    /// sources (so a Spotify track that started 200 ms before Zoom didn't win
    /// the race). The native list mirrors `MeetingDetector.knownApps` plus
    /// the browser set, augmented with a few extras from Seminarly's list.
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

    /// Bundle IDs whose audio is uninteresting — our own app and a few system
    /// processes that emit short blips Core Audio still reports as "running".
    private static let ignoredBundleIDs: Set<String> = [
        "me.dotenv.LokalBot",
        "com.apple.controlcenter",
        "com.apple.SystemSounds",
        "com.apple.finder",
        "com.apple.notificationcenterui",
    ]

    /// Pure media/music players. They emit continuous output but are never
    /// meetings, so — unlike an unknown app — they must not become recording
    /// candidates. Browsers are intentionally absent: a Google Meet call
    /// runs inside one, so it stays recordable.
    nonisolated static let mediaBundleIDs: Set<String> = [
        // Streaming music
        "com.spotify.client",          // Spotify
        "com.apple.Music",             // Apple Music
        "com.apple.iTunes",            // iTunes (legacy)
        "com.amazon.music",            // Amazon Music
        "com.tidal.desktop",           // TIDAL
        "com.deezer.deezer-desktop",   // Deezer
        "com.netease.163music",        // NetEase Cloud Music
        "com.tencent.QQMusicMac",      // QQ Music
        // Local-library / audiophile players
        "com.swinsian.Swinsian",       // Swinsian
        "com.audirvana.Audirvana",     // Audirvana
        "com.foobar2000.mac",          // foobar2000
        "com.roon.Roon",               // Roon
        "com.coppertino.Vox",          // VOX
        "tv.plex.plexamp",             // Plexamp
        // Podcasts & video players (also never meetings)
        "com.apple.podcasts",          // Apple Podcasts
        "com.apple.TV",                // Apple TV
        "com.apple.QuickTimePlayerX",  // QuickTime Player
        "org.videolan.vlc",            // VLC
        "com.colliderli.iina",         // IINA
    ]

    /// Whether `bundleID` is a pure media player that should never become an
    /// automatic-recording candidate. See ``mediaBundleIDs``.
    nonisolated static func isMediaPlayer(_ bundleID: String) -> Bool {
        mediaBundleIDs.contains(bundleID)
    }

    private static let pollInterval: TimeInterval = 3.0
    private static let candidateTimeout: TimeInterval = 20.0

    private var pollTimer: Timer?
    private var pollTask: Task<Void, Never>?
    /// AudioObjectIDs already running output the last time we polled. A new
    /// detection fires only on a not-running → running transition.
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

    /// Consumes the current candidate (caller is starting a recording on it).
    @discardableResult
    func accept() -> AudioProcess? {
        candidateExpiryTask?.cancel()
        candidateExpiryTask = nil
        let process = detectedProcess
        detectedProcess = nil
        return process
    }

    /// Re-seed against the *current* audio state after a recording ends so
    /// apps that started playing audio mid-meeting do not become fresh
    /// automatic-recording candidates.
    func reseed() {
        seedCurrentState()
    }

    // MARK: - Private

    private func seedCurrentState() {
        let processes = MeetingDetector.currentAudioProcesses()
        knownActiveObjectIDs = Set(processes.filter(\.isRunningOutput).map(\.objectID))
    }

    /// The Core Audio query reads several properties of every audio process
    /// from coreaudiod and LaunchServices; it ran on the main thread every
    /// three seconds. It now runs on a utility thread and only the result is
    /// applied here.
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

    private func apply(_ processes: [AudioProcess]) {
        let active = processes.filter(\.isRunningOutput)
        let activeIDs = Set(active.map(\.objectID))

        let newlyActiveIDs = activeIDs.subtracting(knownActiveObjectIDs)
        knownActiveObjectIDs = activeIDs

        guard !newlyActiveIDs.isEmpty, detectedProcess == nil else { return }

        let candidates = active.filter { process in
            guard newlyActiveIDs.contains(process.objectID) else { return false }
            if let bundleID = process.bundleID {
                if Self.ignoredBundleIDs.contains(bundleID) { return false }
                if Self.isMediaPlayer(bundleID) { return false }
            }
            return true
        }

        let meetingApp = candidates.first { process in
            guard let bundleID = process.bundleID else { return false }
            return Self.meetingBundleIDs.contains(bundleID)
        }

        if let best = meetingApp ?? candidates.first {
            detectedProcess = best
            scheduleCandidateExpiry()
        }
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
