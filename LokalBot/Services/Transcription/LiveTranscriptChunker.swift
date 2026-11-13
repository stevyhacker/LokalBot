import Accelerate
import Foundation

/// Bounded live-audio windows and inexpensive signal cleanup. Speech detection
/// belongs to the shared VAD; a chunk's quietest speech is not a noise estimate.
enum LiveTranscriptChunker {
    static let minChunkSeconds: TimeInterval = 4
    static let targetChunkSeconds: TimeInterval = 12
    static let cutSearchSeconds: TimeInterval = 1.5
    static let gateHighPassCutoffHz = 120.0
    static let gateMinimumHighPassedEnergyRatio = 0.15
    static let gateAbsoluteFloor: Float = 0.003

    static func nextChunk(processedFrames: Int64, totalFrames: Int64,
                          sampleRate: Double) -> Range<Int64>? {
        guard sampleRate.isFinite, sampleRate > 0,
              processedFrames >= 0, totalFrames >= processedFrames else { return nil }
        let available = totalFrames - processedFrames
        guard Double(available) / sampleRate >= minChunkSeconds else { return nil }
        let count = min(Double(available), targetChunkSeconds * sampleRate)
        // `available` is a valid Int64, but its Double representation may round
        // up at the extreme. The normal path only converts a bounded 12 s span.
        let frames = count >= Double(available) ? available : Int64(count)
        return processedFrames..<(processedFrames + frames)
    }

    /// Choose a cut inside a quiet 200 ms window. Vector reductions avoid the
    /// repeated per-sample Swift loops over overlapping windows.
    static func refinedCutOffset(tail: [Float], sampleRate: Double) -> Int {
        guard sampleRate.isFinite, sampleRate > 0,
              sampleRate < Double(Int.max) / 2 else { return tail.count }
        let window = Int(0.2 * sampleRate)
        let hop = Int(0.05 * sampleRate)
        guard window > 0, hop > 0, tail.count > window else { return tail.count }
        var quietestStart = 0
        var quietestEnergy = Float.greatestFiniteMagnitude
        tail.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            for start in stride(from: 0, through: tail.count - window, by: hop) {
                var energy: Float = 0
                vDSP_svesq(base.advanced(by: start), 1, &energy, vDSP_Length(window))
                if energy < quietestEnergy {
                    quietestEnergy = energy
                    quietestStart = start
                }
            }
        }
        return quietestStart + window / 2
    }

    /// Returns a candidate for speech detection, NOT a positive speech verdict.
    /// Only silence and predominantly subsonic/DC drift are discarded here.
    /// Steady speech, room noise, and tones must reach VAD for classification.
    static func speechCandidate(from samples: [Float], sampleRate: Double) -> [Float]? {
        guard sampleRate.isFinite, sampleRate > 0, !samples.isEmpty else { return nil }
        let filtered = highPass(samples, sampleRate: sampleRate)
        let sourceEnergy = energy(samples)
        let filteredEnergy = energy(filtered)
        guard sourceEnergy.isFinite, filteredEnergy.isFinite, sourceEnergy > 0,
              filteredEnergy / sourceEnergy >= Float(gateMinimumHighPassedEnergyRatio),
              hasAudibleWindow(filtered, sampleRate: sampleRate) else { return nil }
        return filtered
    }

    private static func hasAudibleWindow(_ samples: [Float], sampleRate: Double) -> Bool {
        let window = max(1, Int(min(Double(samples.count), sampleRate * 0.2)))
        let hop = max(1, window / 2)
        return samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return false }
            for start in stride(from: 0, to: samples.count, by: hop) {
                let count = min(window, samples.count - start)
                var sum: Float = 0
                vDSP_svesq(base.advanced(by: start), 1, &sum, vDSP_Length(count))
                if sqrt(sum / Float(count)) > gateAbsoluteFloor { return true }
            }
            return false
        }
    }

    private static func energy(_ samples: [Float]) -> Float {
        var sum: Float = 0
        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            vDSP_svesq(base, 1, &sum, vDSP_Length(buffer.count))
        }
        return sum
    }

    /// One-pole high-pass filter, initialized without a false DC impulse.
    private static func highPass(_ samples: [Float], sampleRate: Double) -> [Float] {
        let rc = 1.0 / (2.0 * Double.pi * gateHighPassCutoffHz)
        let alpha = Float(rc / (rc + 1.0 / sampleRate))
        var result = [Float](repeating: 0, count: samples.count)
        samples.withUnsafeBufferPointer { input in
            result.withUnsafeMutableBufferPointer { output in
                var previousInput = input[0]
                var previousOutput: Float = 0
                for index in input.indices {
                    let value = input[index]
                    let clean = alpha * (previousOutput + value - previousInput)
                    output[index] = clean
                    previousInput = value
                    previousOutput = clean
                }
            }
        }
        return result
    }
}
