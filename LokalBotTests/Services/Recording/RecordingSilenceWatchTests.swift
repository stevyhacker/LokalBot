import XCTest
@testable import LokalBot

final class RecordingSilenceWatchTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_794_936_662) // 2026-11-17 17:31:02 UTC

    /// Seconds of sound per minute, spread evenly over the minute and fed once
    /// a second, as the recording tick does. Returns the second the watch first
    /// answered true, if it did.
    private func replay(_ perMinute: [TimeInterval], watch: inout RecordingSilenceWatch) -> TimeInterval? {
        var total: TimeInterval = 0
        for second in 0..<(perMinute.count * 60) {
            total += perMinute[second / 60] / 60
            if watch.observe(soundSeconds: total, at: start.addingTimeInterval(TimeInterval(second))) {
                return TimeInterval(second)
            }
        }
        return nil
    }

    /// Reconstructed from the recording of 2026-11-17 (18:31–10:30 local):
    /// the microphone's seconds above -50 dBFS in each minute of the call and
    /// the minutes after it, measured from mic.m4a, plus meeting audio sized
    /// from the system track's per-minute level (digital silence from 18:53 to
    /// the end). The call ended at 18:52; the recording ran until the next
    /// morning, 16 hours. With the watch it stops at about 19:08 and keeps the
    /// call.
    func testTheNightOfNovember17StopsAQuarterHourAfterTheCall() throws {
        let microphone: [TimeInterval] = [19, 2.5, 57, 50, 55.5, 13.5, 37.5, 50.5, 49.5, 27, 44.5,
                                          28, 2, 20, 31.5, 14.5, 47.5, 35.5, 32, 22.5, 18, 6, 1.5]
        let meetingAudio: [TimeInterval] = [30, 30, 0, 30, 10] + Array(repeating: 30, count: 17) + [0]
        var perMinute = zip(microphone, meetingAudio).map { $0 + $1 }
        // After the call the microphone passed the level for half a second in
        // thirteen minutes of the night and was otherwise quiet.
        var night = Array(repeating: 0.0, count: 16 * 60)
        for minute in [0, 2, 22, 42, 43, 60, 63, 67, 168, 215, 216, 250, 378] { night[minute] = 0.5 }
        perMinute += night

        var watch = RecordingSilenceWatch(startedAt: start)
        let stoppedAt = try XCTUnwrap(replay(perMinute, watch: &watch), "the recording must stop on its own")
        let callEnd: TimeInterval = 22 * 60
        XCTAssertGreaterThan(stoppedAt, callEnd, "nothing in the call may stop it")
        XCTAssertEqual(stoppedAt, callEnd + RecordingSilenceWatch.quietLimit, accuracy: 2 * 60)
        let contentEnd = watch.lastActivityAt.timeIntervalSince(start)
        XCTAssertGreaterThanOrEqual(contentEnd, callEnd - 60, "the cut keeps the end of the call")
        XCTAssertLessThanOrEqual(contentEnd, callEnd + 60)
    }

    func testSoundThatIsNotTalkingNeverKeepsTheRecording() {
        // A cough, a door or a chime: half a second every five minutes.
        var perMinute = Array(repeating: 0.0, count: 60)
        for minute in stride(from: 0, to: 60, by: 5) { perMinute[minute] = 0.5 }
        var watch = RecordingSilenceWatch(startedAt: start)
        XCTAssertEqual(replay(perMinute, watch: &watch) ?? 0, RecordingSilenceWatch.quietLimit, accuracy: 1)
        XCTAssertEqual(watch.lastActivityAt, start, "nobody ever talked, so the content ends at the start")
    }

    func testTalkingBeforeTheLimitStartsTheWaitAgain() throws {
        // Fourteen quiet minutes, one minute of talking, then quiet again.
        let perMinute = Array(repeating: 0.0, count: 14) + [20] + Array(repeating: 0.0, count: 20)
        var watch = RecordingSilenceWatch(startedAt: start)
        let stoppedAt = try XCTUnwrap(replay(perMinute, watch: &watch))
        let lastTalk = watch.lastActivityAt.timeIntervalSince(start)
        XCTAssertEqual(lastTalk, 15 * 60, accuracy: 60, "the talking was in the fifteenth minute")
        XCTAssertEqual(stoppedAt, lastTalk + RecordingSilenceWatch.quietLimit, accuracy: 1)
    }

    func testTwoSecondsOfSoundInAMinuteCountsAsTalking() {
        var watch = RecordingSilenceWatch(startedAt: start)
        let early = start.addingTimeInterval(RecordingSilenceWatch.quietLimit - 60)
        XCTAssertFalse(watch.observe(soundSeconds: 0, at: early))
        XCTAssertFalse(watch.observe(soundSeconds: 1.9, at: early.addingTimeInterval(30)))
        XCTAssertEqual(watch.lastActivityAt, start, "1.9 s is not enough")
        XCTAssertFalse(watch.observe(soundSeconds: 2, at: early.addingTimeInterval(59)))
        XCTAssertEqual(watch.lastActivityAt, early.addingTimeInterval(59))
    }

    func testSoundSpreadThinnerThanTheWindowDoesNotAddUp() {
        // One second of sound every 61 s never puts 2 s inside one minute.
        var watch = RecordingSilenceWatch(startedAt: start)
        var total: TimeInterval = 0
        var stopped = false
        for second in 0...Int(RecordingSilenceWatch.quietLimit) + 5 {
            if second > 0, second % 61 == 0 { total += 1 }
            stopped = watch.observe(soundSeconds: total, at: start.addingTimeInterval(TimeInterval(second)))
            if stopped { break }
        }
        XCTAssertTrue(stopped)
        XCTAssertEqual(watch.lastActivityAt, start)
    }

    func testAReplacedMeterOrAClockSetBackStartsCountingAgain() {
        var watch = RecordingSilenceWatch(startedAt: start)
        XCTAssertFalse(watch.observe(soundSeconds: 500, at: start.addingTimeInterval(10)))
        XCTAssertEqual(watch.lastActivityAt, start, "a first sample proves nothing")
        XCTAssertFalse(watch.observe(soundSeconds: 0, at: start.addingTimeInterval(11)))
        XCTAssertFalse(watch.observe(soundSeconds: 0, at: start.addingTimeInterval(5)))
        XCTAssertEqual(watch.lastActivityAt, start)
        XCTAssertTrue(watch.observe(soundSeconds: 0, at: start.addingTimeInterval(RecordingSilenceWatch.quietLimit)))
    }

    func testALongSleepEndsTheRecordingWithTheContentBeforeIt() {
        var watch = RecordingSilenceWatch(startedAt: start)
        XCTAssertFalse(watch.observe(soundSeconds: 0, at: start))
        XCTAssertFalse(watch.observe(soundSeconds: 30, at: start.addingTimeInterval(60)))
        // The Mac sleeps for an hour; the timer's next tick comes after it.
        XCTAssertTrue(watch.observe(soundSeconds: 30, at: start.addingTimeInterval(3_660)))
        XCTAssertEqual(watch.lastActivityAt, start.addingTimeInterval(60))
    }

    func testTheMeterCountsOnlySoundAboveTheTalkingLevel() {
        let meter = RecordingSoundMeter()
        meter.record(rms: 0.000_3, frames: 4_800, sampleRate: 48_000) // about -70 dBFS: room noise
        meter.record(rms: 0.003, frames: 4_800, sampleRate: 48_000) // just under -50 dBFS
        meter.record(rms: .nan, frames: 4_800, sampleRate: 48_000)
        meter.record(rms: 0.05, frames: 4_800, sampleRate: 0)
        XCTAssertEqual(meter.soundSeconds, 0)
        meter.record(rms: 0.05, frames: 4_800, sampleRate: 48_000) // about -26 dBFS: speech
        meter.record(rms: RecordingSoundMeter.soundRMSThreshold, frames: 16_000, sampleRate: 16_000)
        XCTAssertEqual(meter.soundSeconds, 1.1, accuracy: 1e-9)
    }

    func testTheMeterIsSafeToFeedFromBothWriters() {
        let meter = RecordingSoundMeter()
        DispatchQueue.concurrentPerform(iterations: 2) { _ in
            for _ in 0..<1_000 { meter.record(rms: 0.1, frames: 480, sampleRate: 48_000) }
        }
        XCTAssertEqual(meter.soundSeconds, 20, accuracy: 1e-6)
    }
}
