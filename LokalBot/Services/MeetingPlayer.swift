import Foundation
import AVFoundation

/// Plays a meeting's two source files (mic.m4a + system.m4a) together. They
/// were recorded simultaneously, so playing both from the same offset
/// reproduces the meeting; click-to-seek from the transcript lands here.
///
/// Each track gets its own `AVAudioPlayer` and the OS mixes them at the output
/// device. This is deliberate: the mic and system files routinely differ in
/// sample rate (device-native vs. the 48 kHz tap) and channel count (mono vs.
/// stereo mixdown). Folding both into one `AVMutableComposition` + `AVAudioMix`
/// and rendering through `AVPlayer` garbles the mismatched track during
/// real-time playback — independent players resample each cleanly. (Offline
/// export can still use the composition; see `MeetingAudioAsset`.)
@MainActor
final class MeetingPlayer: NSObject, ObservableObject {

    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var isLoaded = false
    /// Playback rate (1.0 = normal). `AVAudioPlayer` honors `enableRate` + `rate`
    /// and preserves pitch while the rate changes.
    @Published var speed: Float = 1.0 { didSet { applySpeed() } }

    private var players: [AVAudioPlayer] = []
    private var ticker: Timer?
    private var loadGeneration = 0

    /// Use exactly the tracks and gains that loaded successfully for playback.
    var waveformSources: [WaveformAnalysis.Source] {
        players.compactMap { player in
            player.url.map { WaveformAnalysis.Source(url: $0, gain: player.volume) }
        }
    }

    /// The longest source owns the meeting timeline. The system track can end
    /// before the mic (or vice versa); clocking from `players.first` freezes or
    /// jumps the scrubber as soon as that shorter player finishes.
    private var timelinePlayer: AVAudioPlayer? {
        players.max { $0.duration < $1.duration }
    }

    func load(folder: URL, hasSystemTrack: Bool) {
        stop()
        // Share the file + gain policy with the offline export so what you hear
        // matches what you export.
        players = MeetingAudioAsset.playbackSources(folder: folder, hasSystemTrack: hasSystemTrack)
            .compactMap { source -> AVAudioPlayer? in
                guard let player = try? AVAudioPlayer(contentsOf: source.url) else { return nil }
                player.delegate = self
                player.enableRate = true
                player.volume = source.gain
                player.prepareToPlay()
                return player
            }
        applySpeed()
        duration = players.map(\.duration).max() ?? 0
        currentTime = 0
        isLoaded = !players.isEmpty
    }

    /// The worker exclusively owns these players until it returns. Main-actor
    /// playback takes ownership only after the generation/cancellation check.
    private struct PreparedPlayers: @unchecked Sendable { let values: [AVAudioPlayer] }

    func loadInBackground(folder: URL, hasSystemTrack: Bool) async {
        stop()
        let generation = loadGeneration
        let prepared = await Task.detached(priority: .userInitiated) {
            PreparedPlayers(values: MeetingAudioAsset.playbackSources(folder: folder, hasSystemTrack: hasSystemTrack)
                .compactMap { source in
                    guard let player = try? AVAudioPlayer(contentsOf: source.url) else { return nil }
                    player.enableRate = true
                    player.volume = source.gain
                    player.prepareToPlay()
                    return player
                })
        }.value
        guard !Task.isCancelled, generation == loadGeneration else { return }
        players = prepared.values
        for player in players { player.delegate = self }
        applySpeed()
        duration = players.map(\.duration).max() ?? 0
        currentTime = 0
        isLoaded = !players.isEmpty
    }

    func playPause() {
        if isPlaying { pause() } else { play() }
    }

    func play(at time: TimeInterval? = nil) {
        guard !players.isEmpty else { return }
        if let time {
            setPlayheads(to: time)
            currentTime = min(max(0, time), duration)
        } else if duration > 0, currentTime >= duration {
            // Replaying after reaching the end: rewind both tracks first.
            setPlayheads(to: 0)
            currentTime = 0
        }
        // Schedule against a shared device-time anchor so both tracks stay in sync.
        let anchor = (players.first?.deviceCurrentTime ?? 0) + 0.05
        for player in players {
            player.enableRate = true
            player.rate = speed
            player.play(atTime: anchor)
        }
        isPlaying = true
        startTicker()
    }

    /// Push the current `speed` to every player (live rate change).
    private func applySpeed() {
        for player in players where player.enableRate { player.rate = speed }
    }

    func pause() {
        for player in players { player.pause() }
        isPlaying = false
        stopTicker()
    }

    func seek(to time: TimeInterval) {
        let wasPlaying = isPlaying
        pause()
        let clamped = max(0, min(time, duration))
        setPlayheads(to: clamped)
        currentTime = clamped
        if wasPlaying { play() }
    }

    func stop() {
        loadGeneration &+= 1
        for player in players { player.stop() }
        players = []
        isPlaying = false
        isLoaded = false
        currentTime = 0
        duration = 0
        stopTicker()
    }

    /// Position every track at `time`, clamped to that track's own length so a
    /// shorter track doesn't reject the seek.
    private func setPlayheads(to time: TimeInterval) {
        for player in players { player.currentTime = min(max(0, time), player.duration) }
    }

    private func startTicker() {
        stopTicker()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let timelinePlayer = self.timelinePlayer else { return }
                self.currentTime = min(timelinePlayer.currentTime, self.duration)
            }
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }
}

extension MeetingPlayer: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            // The longest track decides when the meeting is over.
            if players.allSatisfy({ !$0.isPlaying }) {
                isPlaying = false
                currentTime = duration
                stopTicker()
            }
        }
    }
}
