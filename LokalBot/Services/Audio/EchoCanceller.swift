import Accelerate
import Foundation

struct EchoCanceller {

    struct Configuration: Equatable {
        var taps = 1_536
        var stepSize: Float = 0.25
        var doubleTalkMargin: Float = 1.6
        var referencePeakWindow: Float = 0.05
        var suppressionFrame: TimeInterval = 0.02
        var suppressionRatio: Float = 2
        var suppressionGain: Float = 0.03
        var suppressionAttack: Float = 0.5
        var suppressionRelease: Float = 0.8

        static let `default` = Configuration()
    }

    private let configuration: Configuration
    private var weights: [Float]
    private var history: [Float]
    private var head: Int
    private var windowEnergy: Float = 0
    private var referencePeak: Float = 0
    private let peakDecay: Float
    private let sampleRate: Double
    private var suppressionGain: Float = 1
    private var samplesSinceEnergyRefresh = 0
    private let referenceActivityFloor: Float

    init(configuration: Configuration = .default,
         sampleRate: Double = SpanAudioReader.sampleRate) {
        self.configuration = configuration
        self.sampleRate = sampleRate
        weights = [Float](repeating: 0, count: configuration.taps)
        history = [Float](repeating: 0, count: 2 * configuration.taps)
        head = 0
        let window = max(1, configuration.referencePeakWindow * Float(sampleRate))
        peakDecay = exp(-1 / window)
        referenceActivityFloor = Float(configuration.taps) * 1e-4
    }

    private(set) var microphoneEnergy: Double = 0
    private(set) var residualEnergy: Double = 0

    mutating func process(microphone: [Float], reference: [Float]) throws -> [Float] {
        precondition(microphone.count == reference.count,
                     "microphone and reference must be aligned to the same length")
        guard !microphone.isEmpty else { return [] }
        try Task.checkCancellation()
        let taps = configuration.taps
        let margin = configuration.doubleTalkMargin
        let step = configuration.stepSize
        var output = [Float](repeating: 0, count: microphone.count)
        var predictions = [Float](repeating: 0, count: microphone.count)
        var active = [Bool](repeating: false, count: microphone.count)

        try weights.withUnsafeMutableBufferPointer { w in
            try history.withUnsafeMutableBufferPointer { h in
                let weightBase = w.baseAddress!
                let historyBase = h.baseAddress!
                for n in 0..<microphone.count {
                    if n.isMultiple(of: 4_096) { try Task.checkCancellation() }
                    head = head == 0 ? taps - 1 : head - 1
                    let x = reference[n]
                    let leaving = h[head]
                    h[head] = x
                    h[head + taps] = x
                    windowEnergy += x * x - leaving * leaving
                    referencePeak = max(abs(x), referencePeak * peakDecay)

                    let window = historyBase + head
                    var predicted: Float = 0
                    vDSP_dotpr(window, 1, weightBase, 1, &predicted, vDSP_Length(taps))
                    let d = microphone[n]
                    let error = d - predicted
                    output[n] = error
                    predictions[n] = predicted
                    active[n] = windowEnergy > referenceActivityFloor

                    samplesSinceEnergyRefresh += 1
                    if samplesSinceEnergyRefresh >= taps {
                        vDSP_svesq(window, 1, &windowEnergy, vDSP_Length(taps))
                        samplesSinceEnergyRefresh = 0
                    }

                    guard abs(d) <= margin * referencePeak, windowEnergy > 1e-6 else { continue }
                    var scale = step * error / windowEnergy
                    vDSP_vsma(window, 1, &scale, weightBase, 1, weightBase, 1, vDSP_Length(taps))
                }
            }
        }
        let suppressed = try suppressResidual(output, predictions: predictions)
        for n in 0..<suppressed.count where active[n] {
            if n.isMultiple(of: 4_096) { try Task.checkCancellation() }
            microphoneEnergy += Double(microphone[n]) * Double(microphone[n])
            residualEnergy += Double(suppressed[n]) * Double(suppressed[n])
        }
        return suppressed
    }

    private mutating func suppressResidual(_ residual: [Float],
                                           predictions: [Float]) throws -> [Float] {
        let frame = max(1, Int(configuration.suppressionFrame * sampleRate))
        var output = residual
        var index = 0
        while index < residual.count {
            try Task.checkCancellation()
            let end = min(index + frame, residual.count)
            var predictedEnergy: Float = 0
            var residualEnergy: Float = 0
            for n in index..<end {
                predictedEnergy += predictions[n] * predictions[n]
                residualEnergy += residual[n] * residual[n]
            }
            let echoDominates = predictedEnergy > referenceActivityFloor
                && predictedEnergy > configuration.suppressionRatio * residualEnergy
            let target: Float = echoDominates ? configuration.suppressionGain : 1
            let smoothing = target < suppressionGain
                ? configuration.suppressionAttack : configuration.suppressionRelease
            suppressionGain = smoothing * suppressionGain + (1 - smoothing) * target
            if suppressionGain < 0.999 {
                var gain = suppressionGain
                output.withUnsafeMutableBufferPointer {
                    vDSP_vsmul($0.baseAddress! + index, 1, &gain,
                               $0.baseAddress! + index, 1, vDSP_Length(end - index))
                }
            }
            index = end
        }
        return output
    }

    var echoReturnLossDB: Double {
        guard microphoneEnergy > 0, residualEnergy > 0 else { return 0 }
        return 10 * log10(microphoneEnergy / residualEnergy)
    }
}

enum EchoDelayEstimator {
    struct Estimate: Equatable {
        var samples: Int
        var correlation: Double
        var isReliable: Bool { correlation.isFinite && correlation >= 0.55 }
    }

    static let frameSeconds = 0.01
    static let safetyFrames = 1

    static func delay(microphone: [Float], reference: [Float],
                      sampleRate: Double,
                      maximumLead: TimeInterval = 0.5,
                      maximumLag: TimeInterval = 0.1) -> Int {
        max(0, estimate(microphone: microphone, reference: reference, sampleRate: sampleRate,
                        maximumLead: maximumLead, maximumLag: maximumLag).samples)
    }

    static func estimate(microphone: [Float], reference: [Float], sampleRate: Double,
                         maximumLead: TimeInterval = 0.5, maximumLag: TimeInterval = 0.1) -> Estimate {
        let frame = max(1, Int(frameSeconds * sampleRate))
        let micEnvelope = envelope(microphone, frame: frame)
        let referenceEnvelope = envelope(reference, frame: frame)
        guard micEnvelope.count > 8, referenceEnvelope.count > 8 else { return Estimate(samples: 0, correlation: 0) }

        let maxLead = Int(maximumLead / frameSeconds)
        let maxLag = Int(maximumLag / frameSeconds)
        var bestScore = -Double.infinity
        var bestShift = 0
        for shift in -maxLag...maxLead {
            let score = correlation(micEnvelope, referenceEnvelope, shift: shift)
            if score > bestScore {
                bestScore = score
                bestShift = shift
            }
        }
        guard bestScore > 0 else { return Estimate(samples: 0, correlation: 0) }
        return Estimate(samples: (bestShift - safetyFrames) * frame, correlation: bestScore)
    }

    static func envelope(_ samples: [Float], frame: Int) -> [Double] {
        guard frame > 0, samples.count >= frame else { return [] }
        var values: [Double] = []
        values.reserveCapacity(samples.count / frame)
        var index = 0
        while index + frame <= samples.count {
            var sum: Float = 0
            samples.withUnsafeBufferPointer {
                vDSP_svesq($0.baseAddress! + index, 1, &sum, vDSP_Length(frame))
            }
            values.append(sqrt(Double(sum) / Double(frame)))
            index += frame
        }
        let mean = values.reduce(0, +) / Double(values.count)
        return values.map { $0 - mean }
    }

    static func correlation(_ mic: [Double], _ reference: [Double], shift: Int) -> Double {
        let start = max(0, shift)
        let end = min(mic.count, reference.count + shift)
        guard end - start > 8 else { return -.infinity }
        var dot = 0.0, micEnergy = 0.0, referenceEnergy = 0.0
        for i in start..<end {
            let m = mic[i], r = reference[i - shift]
            dot += m * r
            micEnergy += m * m
            referenceEnergy += r * r
        }
        guard micEnergy > 0, referenceEnergy > 0 else { return -.infinity }
        return dot / (micEnergy * referenceEnergy).squareRoot()
    }
}
