import Foundation

final class RecordingSoundMeter: @unchecked Sendable {
    static let soundRMSThreshold: Float = 0.003_16

    private let lock = NSLock()
    private var seconds: TimeInterval = 0

    func record(rms: Float, frames: Int, sampleRate: Double) {
        guard rms >= Self.soundRMSThreshold, frames > 0, sampleRate > 0 else { return }
        let duration = Double(frames) / sampleRate
        lock.withLock { seconds += duration }
    }

    var soundSeconds: TimeInterval { lock.withLock { seconds } }
}

struct RecordingSilenceWatch {
    static let quietLimit: TimeInterval = 15 * 60
    static let minimumSound: TimeInterval = 2
    static let activityWindow: TimeInterval = 60

    private(set) var lastActivityAt: Date
    private var samples: [(at: Date, seconds: TimeInterval)] = []

    init(startedAt: Date) {
        lastActivityAt = startedAt
    }

    mutating func observe(soundSeconds: TimeInterval, at now: Date) -> Bool {
        if let last = samples.last, soundSeconds < last.seconds || now < last.at {
            samples.removeAll()
        }
        samples.append((now, soundSeconds))
        let windowStart = now.addingTimeInterval(-Self.activityWindow)
        while samples.count > 1, samples[1].at <= windowStart { samples.removeFirst() }
        if soundSeconds - samples[0].seconds >= Self.minimumSound {
            lastActivityAt = max(lastActivityAt, now)
        }
        return now.timeIntervalSince(lastActivityAt) >= Self.quietLimit
    }
}
