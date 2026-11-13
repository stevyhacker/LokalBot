import AudioToolbox
import Foundation

/// Meeting files use elapsed meeting time, including periods with no captured
/// audio. Each recorder fills to the same monotonic origin before writing a
/// buffer; late attachments and recovered devices therefore cannot move later
/// speech to the beginning of a file. Small clock/resampler jitter is tolerated
/// without repeatedly inserting sub-buffer silence.
struct RecordingAudioTimeline: Sendable {
    let originHostTime: Double
    let originInstant: ContinuousClock.Instant
    static let jitterTolerance: TimeInterval = 0.02

    init(originHostTime: Double, originInstant: ContinuousClock.Instant = .now) {
        self.originHostTime = originHostTime
        self.originInstant = originInstant
    }

    /// Core Audio host time can pause during sleep. The continuous meeting
    /// clock retains that gap, while the buffer's age on the host clock keeps
    /// callback/queue latency out of the placement. Capture both observations
    /// together in the callback and perform this work on the writer queue.
    func hostTimeOnTimeline(bufferHostTime: Double, callbackHostTime: Double,
                            callbackInstant: ContinuousClock.Instant) -> Double {
        let elapsed = originInstant.duration(to: callbackInstant).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        return originHostTime + seconds - max(0, callbackHostTime - bufferHostTime)
    }

    func silenceFrames(before hostTime: Double, framesWritten: Int64, sampleRate: Double) -> Int64 {
        guard originHostTime.isFinite, hostTime.isFinite,
              sampleRate.isFinite, sampleRate > 0, framesWritten >= 0 else { return 0 }
        let target = ((hostTime - originHostTime) * sampleRate).rounded()
        guard target > Double(framesWritten), target < Double(Int64.max) else { return 0 }
        let missing = Int64(target) - framesWritten
        return Double(missing) > Self.jitterTolerance * sampleRate ? missing : 0
    }
}

struct AudioClockSpan: Codable, Equatable, Sendable {
    var hostStart: Double
    var hostEnd: Double
    var startFrame: Int64
    var endFrame: Int64
    var sampleRate: Double
    var generation: Int
}

/// Receives anchors on the audio writer queue, only AFTER successful writes.
/// No locks, allocations, conversion or I/O are added to the real-time callback.
final class RecordingAudioClock: @unchecked Sendable {
    private let lock = NSLock()
    private var spans: [AudioClockSpan] = []
    private var liveStartIndex = 0
    private var generation = 0
    private var invalidated = false
    private var fileSampleRate: Double?
    static func hostSeconds(_ ticks: UInt64) -> Double {
        Double(AudioConvertHostTimeToNanos(ticks)) / 1_000_000_000
    }
    static var now: Double { hostSeconds(AudioGetCurrentHostTime()) }

    func record(hostTime: UInt64, valid: Bool, startFrame: Int64, frames: Int64, sampleRate: Double) {
        lock.lock()
        defer { lock.unlock() }
        guard !invalidated, valid, frames > 0, sampleRate.isFinite, sampleRate > 0 else {
            generation += 1
            return
        }
        let start = Self.hostSeconds(hostTime)
        let end = start + Double(frames) / sampleRate
        guard start.isFinite, end > start else { generation += 1; return }
        if let fileSampleRate, fileSampleRate != sampleRate {
            // The recorder rejects incompatible reattachments. If a caller
            // nevertheless supplies one, never reinterpret old file frames.
            generation += 1
            return
        }
        fileSampleRate = sampleRate
        if let last = spans.last, start < last.hostEnd - 0.002 {
            // Retain historical file anchors for offline alignment, but a
            // backwards clock must never reuse them for a live observation.
            liveStartIndex = spans.count
            generation += 1
            return
        }
        if let last = spans.last, last.generation == generation,
           last.sampleRate == sampleRate, last.endFrame == startFrame,
           abs(last.hostEnd - start) <= 0.002,
           abs(last.hostStart + Double(startFrame - last.startFrame) / sampleRate - start) <= 0.005 {
            spans[spans.count - 1].hostEnd = end
            spans[spans.count - 1].endFrame = startFrame + frames
        } else {
            generation += 1
            // Retain the compact map for post-recording alignment. On an
            // excessively fragmented capture, missing coverage fails closed.
            guard spans.count < 65_536 else { return }
            spans.append(AudioClockSpan(hostStart: start, hostEnd: end, startFrame: startFrame,
                                        endFrame: startFrame + frames, sampleRate: sampleRate, generation: generation))
        }
    }

    func discontinuity() {
        lock.lock()
        generation += 1
        lock.unlock()
    }

    func invalidate() {
        lock.lock()
        invalidated = true
        lock.unlock()
    }

    func snapshot() -> [AudioClockSpan] {
        lock.lock()
        defer { lock.unlock() }
        return Array(spans.dropFirst(liveStartIndex).suffix(64))
    }

    func archive() -> [AudioClockSpan] {
        lock.lock()
        defer { lock.unlock() }
        return spans
    }

    /// Both bounds must lie within a single contiguous span. Never extrapolate.
    func map(hostStart: Double, hostEnd: Double) -> SpeakerTurnAnchor? {
        lock.lock()
        defer { lock.unlock() }
        guard hostStart.isFinite, hostEnd.isFinite, hostEnd > hostStart,
              let span = spans.dropFirst(liveStartIndex).last(where: {
                  $0.hostStart <= hostStart && $0.hostEnd >= hostEnd
              }) else { return nil }
        return SpeakerTurnAnchor(start: Double(span.startFrame) / span.sampleRate + hostStart - span.hostStart,
                                 end: Double(span.startFrame) / span.sampleRate + hostEnd - span.hostStart)
    }
}

struct RecordingAudioTiming: Codable, Sendable {
    static let fileName = "audio-timing.json"
    var version = 1
    var microphone: [AudioClockSpan]
    var system: [AudioClockSpan]
    /// Version 2 captures pad both primary audio and preview CAFs to this
    /// origin. Version 1 remains decodable: its spans still map raw file time
    /// for echo/identity evidence. Never reinterpret those existing files or
    /// their saved transcripts as padded audio merely by loading the sidecar.
    var timelineOriginHostTime: Double?

    func nextBoundary(after position: Double) -> Double? {
        var boundary = Double.infinity
        var containing: AudioClockSpan?
        for span in microphone where span.sampleRate > 0 {
            let start = Double(span.startFrame) / span.sampleRate
            let end = Double(span.endFrame) / span.sampleRate
            for value in [start, end] where value.isFinite && value > position + 0.000_01 {
                boundary = min(boundary, value)
            }
            if start <= position + 0.000_01 && end > position + 0.000_01 { containing = span }
        }
        if let mic = containing, mic.hostEnd > mic.hostStart {
            let origin = Double(mic.startFrame) / mic.sampleRate
            let duration = Double(mic.endFrame - mic.startFrame) / mic.sampleRate
            for remote in system {
                for host in [remote.hostStart, remote.hostEnd] where host >= mic.hostStart && host <= mic.hostEnd {
                    let value = origin + (host - mic.hostStart) / (mic.hostEnd - mic.hostStart) * duration
                    if value > position + 0.000_01 { boundary = min(boundary, value) }
                }
            }
        }
        return boundary.isFinite ? boundary : nil
    }

    /// Map both bounds through one continuous span on each track. Padding and
    /// device gaps have no anchors, so this never extrapolates across them.
    func referenceRange(start: Double, end: Double) -> SpeakerTurnAnchor? {
        guard start.isFinite, end.isFinite, end > start,
              let mic = microphone.first(where: { Self.covers($0, start: start, end: end) }) else { return nil }
        let micStart = Double(mic.startFrame) / mic.sampleRate
        let micDuration = Double(mic.endFrame - mic.startFrame) / mic.sampleRate
        guard micDuration > 0, mic.hostEnd > mic.hostStart else { return nil }
        let hostStart = mic.hostStart + (start - micStart) / micDuration * (mic.hostEnd - mic.hostStart)
        let hostEnd = mic.hostStart + (end - micStart) / micDuration * (mic.hostEnd - mic.hostStart)
        guard let remote = system.first(where: { $0.hostStart <= hostStart && $0.hostEnd >= hostEnd
            && $0.sampleRate > 0 && $0.hostEnd > $0.hostStart }) else { return nil }
        let scale = Double(remote.endFrame - remote.startFrame) / remote.sampleRate / (remote.hostEnd - remote.hostStart)
        let origin = Double(remote.startFrame) / remote.sampleRate
        let range = SpeakerTurnAnchor(start: origin + (hostStart - remote.hostStart) * scale,
                                      end: origin + (hostEnd - remote.hostStart) * scale)
        guard range.isValid, abs(range.duration / (end - start) - 1) < 0.002 else { return nil }
        return range
    }

    private static func covers(_ span: AudioClockSpan, start: Double, end: Double) -> Bool {
        span.sampleRate > 0 && span.sampleRate.isFinite && span.hostStart.isFinite && span.hostEnd.isFinite
            && Double(span.startFrame) / span.sampleRate <= start
            && Double(span.endFrame) / span.sampleRate >= end
    }
}
