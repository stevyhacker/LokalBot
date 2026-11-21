import Accelerate
import AVFoundation
import Foundation

final class AudioLevelMeter: @unchecked Sendable {
    static let historyLength = 32
    static let maximumAgeNanoseconds: UInt64 = 500_000_000
    private let lock = NSLock()
    private var samples: [(level: Float, at: UInt64)] = []

    func reset() {
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    func record(_ level: Float, at time: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        lock.lock()
        samples.append((min(max(level, 0), 1), time))
        if samples.count > Self.historyLength { samples.removeFirst(samples.count - Self.historyLength) }
        lock.unlock()
    }

    func recent(_ count: Int, now: UInt64 = DispatchTime.now().uptimeNanoseconds) -> [Float] {
        lock.lock()
        let tail = samples.suffix(count).map {
            (now > $0.at ? now - $0.at : 0) <= Self.maximumAgeNanoseconds ? $0.level : 0
        }
        lock.unlock()
        return Array(repeating: 0, count: max(0, count - tail.count)) + tail
    }

    static func normalized(rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let decibels = 20 * log10(rms)
        return min(max((decibels + 55) / 45, 0), 1)
    }

    static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        var total: Float = 0
        let channelCount = Int(buffer.format.channelCount)
        for channel in 0..<channelCount {
            var value: Float = 0
            vDSP_rmsqv(channels[channel], 1, &value, vDSP_Length(buffer.frameLength))
            total += value * value
        }
        return channelCount > 0 ? sqrt(total / Float(channelCount)) : 0
    }
}
