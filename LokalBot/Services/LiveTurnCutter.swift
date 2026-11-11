import Foundation

/// Cuts one live track into turns while it is being recorded. It hears only
/// the voice-activity model's verdict on each 256 ms chunk, and closes a turn
/// once the pause after it is long enough, so the turn can be transcribed
/// while the speaker is still quiet. No audio and no model: the caller runs
/// the model and reads the turn's samples.
///
/// The rules are FluidAudio's streaming ones (`VadManager.processStreamingChunk`)
/// with two additions: a long turn closes at its first quiet chunk, and a
/// turn with no pause at all is handed over at a maximum length.
/// Benchmarks/LiveTurns measured the settings.
struct LiveTurnCutter: Equatable, Sendable {
    struct Settings: Equatable, Sendable {
        /// Frames the voice-activity model judges at a time.
        var chunkFrames: Int64 = 4_096
        var sampleRate = 16_000.0
        /// A chunk at or above this probability is speech, as after a meeting.
        var speechThreshold: Float = 0.85
        /// A chunk below this one is quiet. In between, nothing changes.
        var quietThreshold: Float = 0.70
        /// Quiet chunks that close a turn: two are a pause of about half a second.
        var quietChunksToClose = 2
        /// A turn this long closes at its first quiet chunk. Several voices
        /// on one track leave shorter pauses between them than one voice
        /// leaves inside a sentence, and a long turn has context to spare.
        var eagerAfterSeconds: Double? = 4
        /// A turn with no pause is handed over at this length.
        var maximumTurnSeconds = 15.0
        /// Audio kept before the first speech chunk and after the last.
        var paddingSeconds = 0.1
        /// Less than one chunk of speech is what a length cut leaves behind
        /// when the speaker stops right after it, not a turn.
        var minimumTurnSeconds = 0.25
    }

    struct Turn: Equatable, Sendable {
        /// Frames on the track's timeline.
        var start: Int64
        var end: Int64
        /// Cut by length, not by a pause.
        var forced: Bool
    }

    var settings = Settings()
    /// Frames heard so far.
    private(set) var processed: Int64 = 0
    /// Where the turn being spoken starts, if someone is speaking.
    private(set) var openStart: Int64?
    /// Frames heard when the current pause began.
    private var quietSince: Int64?
    private var lastEnd: Int64 = 0

    init(settings: Settings = Settings(), startingAt frame: Int64 = 0) {
        self.settings = settings
        processed = frame
        lastEnd = frame
    }

    /// The open turn has reached a pause that may close it.
    var isPausing: Bool { quietSince != nil }

    /// Takes the verdict on the next chunk and returns the turn it closed.
    /// `quietPoint` picks where to cut a turn that reached the maximum
    /// length, between the two frames it is given; without it the cut is at
    /// the end of the chunk.
    mutating func consume(probability: Float,
                          quietPoint: (_ from: Int64, _ to: Int64) -> Int64 = { _, to in to }) -> Turn? {
        processed += settings.chunkFrames
        let padding = Int64(settings.paddingSeconds * settings.sampleRate)
        if probability >= settings.speechThreshold {
            quietSince = nil
            if openStart == nil {
                openStart = max(lastEnd, processed - settings.chunkFrames - padding)
            }
        } else if probability < settings.quietThreshold, let start = openStart {
            let pauseStart = quietSince ?? processed
            quietSince = pauseStart
            let speechEnd = pauseStart - settings.chunkFrames
            let quietChunks = Int((processed - pauseStart) / settings.chunkFrames) + 1
            if quietChunks >= chunksToClose(turnFrames: speechEnd - start) {
                openStart = nil
                quietSince = nil
                return close(start: start, end: min(processed, speechEnd + padding), forced: false)
            }
        }
        if let start = openStart, quietSince == nil,
           Double(processed - start) / settings.sampleRate >= settings.maximumTurnSeconds {
            let cut = min(processed, max(start, quietPoint(start, processed)))
            openStart = cut
            return close(start: start, end: cut, forced: true)
        }
        return nil
    }

    private func chunksToClose(turnFrames: Int64) -> Int {
        if let eager = settings.eagerAfterSeconds, Double(turnFrames) / settings.sampleRate >= eager { return 1 }
        return max(1, settings.quietChunksToClose)
    }

    private mutating func close(start: Int64, end: Int64, forced: Bool) -> Turn? {
        guard Double(end - start) / settings.sampleRate >= settings.minimumTurnSeconds else { return nil }
        lastEnd = end
        return Turn(start: start, end: end, forced: forced)
    }
}
