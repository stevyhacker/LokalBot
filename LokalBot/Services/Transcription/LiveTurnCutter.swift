import Foundation

struct LiveTurnCutter: Equatable, Sendable {
    struct Settings: Equatable, Sendable {
        var chunkFrames: Int64 = 4_096
        var sampleRate = 16_000.0
        var speechThreshold: Float = 0.85
        var quietThreshold: Float = 0.70
        var quietChunksToClose = 2
        var eagerAfterSeconds: Double? = 4
        var maximumTurnSeconds = 15.0
        var paddingSeconds = 0.1
        var minimumTurnSeconds = 0.25
    }

    struct Turn: Equatable, Sendable {
        var start: Int64
        var end: Int64
        var forced: Bool
    }

    var settings = Settings()
    private(set) var processed: Int64 = 0
    private(set) var openStart: Int64?
    private var quietSince: Int64?
    private var lastEnd: Int64 = 0

    init(settings: Settings = Settings(), startingAt frame: Int64 = 0) {
        self.settings = settings
        processed = frame
        lastEnd = frame
    }

    var isPausing: Bool { quietSince != nil }

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
