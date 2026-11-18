import Foundation

/// Adds up how long a recording has carried sound loud enough to be someone
/// talking. The microphone and meeting-audio writers record into one meter
/// per recording from their own queues. The main thread reads the total
/// without waiting on either writer, so a busy encoder or a stalled Swift
/// task pool cannot hold up the silence check.
final class RecordingSoundMeter: @unchecked Sendable {
    /// About -50 dBFS RMS. Speech at a laptop microphone and remote speech in
    /// a call sit around -35 to -20 dBFS. An unattended MacBook's microphone,
    /// measured overnight on 2026-11-17, stayed between -60 and -100 dBFS and
    /// passed this level for at most half a second in any minute.
    static let soundRMSThreshold: Float = 0.003_16

    private let lock = NSLock()
    private var seconds: TimeInterval = 0

    /// Called from a writer queue for each buffer written to disk.
    func record(rms: Float, frames: Int, sampleRate: Double) {
        guard rms >= Self.soundRMSThreshold, frames > 0, sampleRate > 0 else { return }
        let duration = Double(frames) / sampleRate
        lock.withLock { seconds += duration }
    }

    /// Seconds of sound written so far, from both sources together.
    var soundSeconds: TimeInterval { lock.withLock { seconds } }
}

/// Ends a recording nobody is talking in.
///
/// The call detector keeps a recording going until it sees the call end, and
/// it reads a call whose state it cannot see as still running (see
/// `BrowserMeetingSession.lifecycleDecision`). On 2026-11-17 a Meet call
/// ended at 18:52 with its tab left open. The detector got no observation
/// after 18:51, when the app's Swift task pool appears to have stalled, and
/// the recording ran until 10:30 the next morning: 16 hours and 6 GB for 21
/// minutes of conversation. This watch reads only what the recorders wrote, from the
/// main run loop, so it ends that recording whatever the detector knows. It
/// also ends a call left open in an empty room and a manual recording
/// someone forgot.
struct RecordingSilenceWatch {
    /// How long a recording may go without anyone talking.
    static let quietLimit: TimeInterval = 15 * 60
    /// Sound within `activityWindow` that counts as talking. A cough, a door
    /// or a notification chime stays below it. During that call every minute
    /// had at least 2 s of microphone sound, with the meeting audio on top;
    /// from a minute after it ended, no minute had more than half a second.
    static let minimumSound: TimeInterval = 2
    static let activityWindow: TimeInterval = 60

    /// When someone was last heard talking. A recording this watch stops ends
    /// its content here.
    private(set) var lastActivityAt: Date
    private var samples: [(at: Date, seconds: TimeInterval)] = []

    init(startedAt: Date) {
        lastActivityAt = startedAt
    }

    /// Takes the meter's running total. True once the recording has gone
    /// `quietLimit` without anyone talking.
    mutating func observe(soundSeconds: TimeInterval, at now: Date) -> Bool {
        if let last = samples.last, soundSeconds < last.seconds || now < last.at {
            // A replaced meter or a clock set back: start counting again.
            samples.removeAll()
        }
        samples.append((now, soundSeconds))
        // The oldest sample kept is the last one at or before the window's
        // start, so the difference below spans the whole window.
        let windowStart = now.addingTimeInterval(-Self.activityWindow)
        while samples.count > 1, samples[1].at <= windowStart { samples.removeFirst() }
        if soundSeconds - samples[0].seconds >= Self.minimumSound {
            lastActivityAt = max(lastActivityAt, now)
        }
        return now.timeIntervalSince(lastActivityAt) >= Self.quietLimit
    }
}
