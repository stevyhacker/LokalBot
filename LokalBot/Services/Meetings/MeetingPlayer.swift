import Foundation
import AVFoundation

@MainActor
final class MeetingPlaybackClock: ObservableObject {
    @Published private(set) var currentTime: TimeInterval = 0

    func update(to time: TimeInterval) {
        guard currentTime != time else { return }
        currentTime = time
    }
}

@MainActor
final class MeetingPlayer: NSObject, ObservableObject {

    @Published private(set) var isPlaying = false
    let clock = MeetingPlaybackClock()
    private(set) var currentTime: TimeInterval {
        get { clock.currentTime }
        set { clock.update(to: newValue) }
    }
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var windowStart: TimeInterval = 0
    @Published private(set) var windowEnd: TimeInterval = 0
    @Published private(set) var isLoaded = false
    @Published var speed: Float = 1.0 { didSet { applySpeed() } }

    private(set) var rawDuration: TimeInterval = 0
    private var players: [AVAudioPlayer] = []
    private var ticker: Timer?
    private var excerptEnd: TimeInterval?
    private var loadGeneration = 0

    var waveformSources: [WaveformAnalysis.Source] {
        players.compactMap { player in
            player.url.map { WaveformAnalysis.Source(url: $0, gain: player.volume) }
        }
    }

    private var timelinePlayer: AVAudioPlayer? {
        players.max { $0.duration < $1.duration }
    }

    func load(folder: URL, hasSystemTrack: Bool, contentRange: Meeting.ContentRange? = nil) {
        stop()
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
        rawDuration = players.map(\.duration).max() ?? 0
        duration = rawDuration
        setPlaybackRange(contentRange)
        currentTime = windowStart
        setPlayheads(to: windowStart)
        isLoaded = !players.isEmpty
    }

    private struct PreparedPlayers: @unchecked Sendable { let values: [AVAudioPlayer] }

    func loadInBackground(folder: URL, hasSystemTrack: Bool, contentRange: Meeting.ContentRange? = nil) async {
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
        rawDuration = players.map(\.duration).max() ?? 0
        duration = rawDuration
        setPlaybackRange(contentRange)
        currentTime = windowStart
        setPlayheads(to: windowStart)
        isLoaded = !players.isEmpty
    }

    func setPlaybackRange(_ range: Meeting.ContentRange?) {
        if let range, range.isValid, rawDuration > 0, range.start < rawDuration {
            windowStart = max(0, range.start)
            windowEnd = min(rawDuration, max(windowStart + 0.05, range.end))
        } else {
            windowStart = 0
            windowEnd = rawDuration
        }
        if currentTime < windowStart || currentTime > windowEnd {
            if isPlaying && currentTime >= windowEnd {
                pause()
            }
            let clamped = min(max(windowStart, currentTime), windowEnd)
            setPlayheads(to: clamped)
            currentTime = clamped
        }
    }

    private var activeRange: (start: TimeInterval, end: TimeInterval) {
        let upper = windowEnd > windowStart ? windowEnd : duration
        let lower = upper > windowStart ? windowStart : 0
        return (lower, upper)
    }

    func playPause() {
        if isPlaying { pause() } else { play() }
    }

    func play(at time: TimeInterval? = nil) {
        excerptEnd = nil
        guard !players.isEmpty else { return }
        let bounds = activeRange
        let outOfBounds = currentTime >= bounds.end || currentTime < bounds.start
        if let time {
            let clamped = min(max(bounds.start, time), bounds.end)
            setPlayheads(to: clamped)
            currentTime = clamped
        } else if bounds.end > bounds.start, outOfBounds {
            setPlayheads(to: bounds.start)
            currentTime = bounds.start
        }
        let anchor = (players.first?.deviceCurrentTime ?? 0) + 0.05
        for player in players {
            player.enableRate = true
            player.rate = speed
            player.play(atTime: anchor)
        }
        isPlaying = true
        startTicker()
    }

    func playExcerpt(from start: TimeInterval, to end: TimeInterval) {
        guard start.isFinite, end.isFinite, start >= 0, end > start, start < duration else { return }
        play(at: start)
        excerptEnd = min(end, duration)
    }

    private func applySpeed() {
        for player in players where player.enableRate { player.rate = speed }
    }

    func pause() {
        excerptEnd = nil
        for player in players { player.pause() }
        isPlaying = false
        stopTicker()
    }

    func seek(to time: TimeInterval) {
        let wasPlaying = isPlaying
        pause()
        let bounds = activeRange
        let clamped = max(bounds.start, min(time, bounds.end))
        setPlayheads(to: clamped)
        currentTime = clamped
        if wasPlaying { play() }
    }

    func stop() {
        excerptEnd = nil
        loadGeneration &+= 1
        for player in players { player.stop() }
        players = []
        isPlaying = false
        isLoaded = false
        currentTime = 0
        duration = 0
        rawDuration = 0
        windowStart = 0
        windowEnd = 0
        stopTicker()
    }

    private func setPlayheads(to time: TimeInterval) {
        for player in players { player.currentTime = min(max(0, time), player.duration) }
    }

    private func startTicker() {
        stopTicker()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let timelinePlayer = self.timelinePlayer else { return }
                let bounds = self.activeRange
                self.currentTime = min(max(bounds.start, timelinePlayer.currentTime), bounds.end)
                let stopBoundary = self.excerptEnd.map { min($0, bounds.end) } ?? bounds.end
                if stopBoundary > bounds.start, timelinePlayer.currentTime >= stopBoundary {
                    self.pause()
                    self.setPlayheads(to: stopBoundary)
                    self.currentTime = stopBoundary
                }
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
            if players.allSatisfy({ !$0.isPlaying }) {
                isPlaying = false
                currentTime = activeRange.end
                stopTicker()
            }
        }
    }
}
