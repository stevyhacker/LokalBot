import Accelerate
import Foundation

/// Subtracts the meeting's remote audio from the microphone recording.
///
/// LokalBot records the raw input device, so the meeting app's own echo
/// cancellation never touches our mic track: with the user on speakers, the
/// remote voice travels through the room back into the microphone and is
/// transcribed a second time as the user. Measured on a real 49-minute call,
/// the user's own voice sat only 8.2 dB above that echo — loud enough that VAD
/// and ASR treat it as a second speaker, which is how a quarter of the mic
/// transcript ended up being the other side repeated back.
///
/// The system-audio process tap hands us the very signal the echo was made
/// from, so the echo is predictable where the user's voice is not: an adaptive
/// FIR filter learns the path from the speakers through the room into the
/// microphone, and what its prediction does not explain is the user.
///
/// Normalized LMS rather than a fixed filter, because the path is not fixed:
/// the two capture clocks drift (measured: 10 ms over 45 minutes) and the room
/// changes whenever the laptop moves.
struct EchoCanceller {

    struct Configuration: Equatable {
        /// Filter length. Covers the room's echo tail plus whatever clock
        /// drift the bulk alignment leaves behind — 96 ms at 16 kHz.
        var taps = 1_536
        /// Convergence speed against stability.
        var stepSize: Float = 0.25
        /// Double-talk threshold. Adaptation freezes when the microphone is
        /// louder than the reference could explain — that is the user talking,
        /// and left running the filter would learn to cancel *them*. This is
        /// the guard whose absence made a first attempt diverge to -17 dB.
        var doubleTalkMargin: Float = 1.6
        /// Decay window of the reference peak the detector compares against.
        var referencePeakWindow: Float = 0.05
        /// Frame the residual suppressor decides on.
        var suppressionFrame: TimeInterval = 0.02
        /// How much louder the predicted echo must be than what is left over
        /// before a frame counts as echo and nothing else.
        var suppressionRatio: Float = 2
        /// Gain such a frame is pushed down to. Subtracting the echo is not
        /// enough on its own: the adaptive filter leaves it ~13 dB down and
        /// ASR transcribes that without complaint.
        var suppressionGain: Float = 0.03
        /// Gain smoothing per frame, so suppression fades rather than clicks.
        var suppressionAttack: Float = 0.5
        var suppressionRelease: Float = 0.8
        // Two alternatives to this gain were measured on a real meeting and
        // both came out worse. Gating echo-only frames to digital silence made
        // ASR hallucinate *more* (40 invented English segments against 27):
        // the abrupt edges read as speech onsets, and the release clipped real
        // word beginnings. Filling them with comfort noise at the room's own
        // floor cut the residual echo further but masked quiet speech, costing
        // a third of the user's real words. -30 dB and no fill it is.

        static let `default` = Configuration()
    }

    private let configuration: Configuration
    private var weights: [Float]
    /// Delay line of length `2 * taps`: every sample is stored twice so the
    /// most recent `taps` samples are always one contiguous slice, which keeps
    /// the per-sample dot product a single vDSP call and needs no shifting.
    private var history: [Float]
    private var head: Int
    private var windowEnergy: Float = 0
    private var referencePeak: Float = 0
    private let peakDecay: Float
    private let sampleRate: Double
    /// Smoothed suppressor gain, carried across chunks so a boundary never
    /// steps the level.
    private var suppressionGain: Float = 1
    private var samplesSinceEnergyRefresh = 0
    /// Window energy standing for a reference RMS of about 0.01 (-40 dBFS),
    /// above which the remote side is audibly playing.
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

    /// Energy the last `process` call removed, for reporting ERLE.
    private(set) var microphoneEnergy: Double = 0
    private(set) var residualEnergy: Double = 0

    /// Cancels `reference` out of `microphone`, sample for sample. The two must
    /// already be aligned (see `EchoDelayEstimator`) and equally long. Filter
    /// state carries across calls on one canceller. `EchoCancelledTrack`
    /// starts a new one for each chunk instead: every chunk gets its own
    /// alignment and is kept or dropped on its own result.
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
                    // The slot being overwritten holds the sample leaving the
                    // window, which keeps the window energy an O(1) update.
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
                    // Scoring waits until after suppression, which is part of
                    // the cancellation; only the mark of "the remote side was
                    // audible here" is taken now, from the filter's own state.
                    active[n] = windowEnergy > referenceActivityFloor

                    samplesSinceEnergyRefresh += 1
                    if samplesSinceEnergyRefresh >= taps {
                        // Rounding accumulates over tens of millions of
                        // samples; a periodic exact sum keeps the normalizer
                        // honest without paying for it every sample.
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
        // Only score where there was echo to remove. Averaged over silence and
        // the user's own turns instead, the number would say more about who
        // talked than about the filter.
        for n in 0..<suppressed.count where active[n] {
            if n.isMultiple(of: 4_096) { try Task.checkCancellation() }
            microphoneEnergy += Double(microphone[n]) * Double(microphone[n])
            residualEnergy += Double(suppressed[n]) * Double(suppressed[n])
        }
        return suppressed
    }

    /// Pushes the frames that were nothing but echo down to the noise floor.
    ///
    /// The adaptive filter alone leaves the echo about 13 dB down, measured on
    /// a real call — quieter, but an ASR engine transcribes a -42 dBFS voice
    /// without complaint, so subtraction on its own moved the problem rather
    /// than solving it. Where the filter's own prediction says a frame was
    /// mostly echo and little survived it, what is left is residual echo and
    /// is silenced; where a lot survived, the user was talking and the frame
    /// passes untouched.
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

    /// Echo return loss enhancement in dB: how much of the microphone's energy
    /// the filter removed. Zero means it found nothing to cancel — which is
    /// the correct answer when the user wears headphones.
    var echoReturnLossDB: Double {
        guard microphoneEnergy > 0, residualEnergy > 0 else { return 0 }
        return 10 * log10(microphoneEnergy / residualEnergy)
    }
}

/// Finds how far the microphone lags the system-audio track.
///
/// The two are captured by different Core Audio paths with their own buffering,
/// and the sound additionally has to travel from the speakers to the mic: on a
/// real call the microphone ran about 146 ms behind. An adaptive filter can
/// only look backwards, so the reference has to be shifted into rough
/// alignment first — the filter then covers what is left.
///
/// Correlating loudness envelopes rather than waveforms: the bulk delay is a
/// property of the energy contour, which survives AAC encoding and room
/// colouring intact, and 10 ms frames make the search cheap enough to run on
/// probes from across the whole track.
enum EchoDelayEstimator {
    struct Estimate: Equatable {
        var samples: Int
        var correlation: Double
        var isReliable: Bool { correlation.isFinite && correlation >= 0.55 }
    }

    static let frameSeconds = 0.01
    /// Alignment must not land *later* than the true delay — a causal filter
    /// cannot reach forwards — so the estimate is nudged early by a frame.
    static let safetyFrames = 1

    /// Delay in samples, positive when the microphone lags the reference.
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

    /// Mean-removed loudness contour, one value per frame.
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

    /// Correlation of the two contours with the reference pulled `shift`
    /// frames earlier, normalized so different overlaps stay comparable.
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
