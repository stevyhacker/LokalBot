import XCTest
@testable import LokalBot

final class LibraryHealthTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }

    private func block(_ app: String, _ start: Date, _ end: Date) -> ActivityBlock {
        ActivityBlock(app: app, title: "", start: start, end: end)
    }

    /// A healthy weekday: evaluated day Sep 29, "now" Sep 30 09:00.
    private func input(_ change: (inout LibraryHealthInput) -> Void = { _ in }) -> LibraryHealthInput {
        var value = LibraryHealthInput(
            day: DateInterval(start: date(29, 0), end: date(30, 0)),
            now: date(30, 9),
            blocks: [block("Xcode", date(29, 9), date(29, 11)), block("Google Chrome", date(29, 11), date(29, 12))],
            screenCaptureEnabled: true,
            captureCountsByApp: ["Xcode": 12, "Google Chrome": 4],
            privateShareHistory: [0.02, 0.03, 0.01],
            recordings: [],
            schedulers: .init(
                automaticInferenceAllowed: true,
                digestEnabled: true,
                previousDay: .init(day: date(29, 0), latestEvidenceAt: date(29, 12), digestModifiedAt: date(30, 0, 5)),
                dreamingEnabled: true,
                dreamingHour: 4,
                missingDreamDays: 0),
            digestCoverage: DayDigestCoverage(coveredSeconds: 9_000, trackedSeconds: 10_800))
        change(&value)
        return value
    }

    private func evaluate(_ value: LibraryHealthInput) -> LibraryHealthReport {
        LibraryHealthEvaluator.evaluate(value, dayKey: "2026-09-29", calendar: calendar)
    }

    func testHealthyDayPassesEveryCheck() {
        let report = evaluate(input())
        XCTAssertEqual(report.status, .pass)
        XCTAssertEqual(report.findings.map(\.check), LibraryHealthCheck.allCases)
    }

    func testAppWithThirtyMinutesTrackedAndNoCapturesFails() {
        let report = evaluate(input { $0.captureCountsByApp["Google Chrome"] = 0 })
        let finding = report.finding(.captureRate)
        XCTAssertEqual(finding?.status, .fail)
        XCTAssertTrue(finding?.summary.contains("Google Chrome") == true)
    }

    func testCaptureRatePassesWhenCaptureIsDisabled() {
        let report = evaluate(input {
            $0.screenCaptureEnabled = false
            $0.captureCountsByApp = [:]
        })
        XCTAssertEqual(report.finding(.captureRate)?.status, .pass)
    }

    /// Capture never records LokalBot itself or the lock screen, so time
    /// there must not read as an app capture has gone silent for.
    func testCaptureRateIgnoresLokalBotsOwnWindowsAndTheLockScreen() {
        let report = evaluate(input {
            $0.blocks.append(self.block("LokalBot", date(29, 13), date(29, 14)))
            $0.blocks.append(self.block("LokalBot Dev", date(29, 14), date(29, 15)))
            $0.blocks.append(self.block("loginwindow", date(29, 15), date(29, 16)))
        })
        XCTAssertEqual(report.finding(.captureRate)?.status, .pass)
    }

    /// With automatic transcription off, the app never repairs a missing
    /// transcript on its own, so that is the user's choice, not a failure.
    func testFinishedRecordingsPassWhenAutomaticTranscriptionIsOff() {
        let report = evaluate(input {
            $0.automaticTranscription = false
            $0.recordings = [.init(meetingID: UUID(), title: "Standup", missingTranscript: .neverTranscribed,
                                   hasQueuedJob: false)]
        })
        XCTAssertEqual(report.finding(.finishedRecordings)?.status, .pass)
    }

    func testPrivateTimeAboveFifteenPercentWarns() {
        let report = evaluate(input { $0.blocks.append(self.block("Private", date(29, 13), date(29, 14))) })
        XCTAssertEqual(report.finding(.privateShare)?.status, .warn)
    }

    func testPrivateTimeDoublingItsBaselineWarns() {
        let report = evaluate(input {
            $0.blocks = [self.block("Xcode", date(29, 9), date(29, 17, 48)),
                         self.block("Private", date(29, 17, 48), date(29, 19))]
            $0.privateShareHistory = [0.05, 0.05, 0.06]
            $0.captureCountsByApp = ["Xcode": 20]
        })
        XCTAssertEqual(report.finding(.privateShare)?.status, .warn)
    }

    func testOverlappingBlocksFail() {
        let report = evaluate(input { $0.blocks.append(self.block("Slack", date(29, 10), date(29, 10, 20))) })
        XCTAssertEqual(report.finding(.activityClock)?.status, .fail)
    }

    func testTrackedTimeBeyondWallClockFails() {
        let report = evaluate(input {
            $0.day = DateInterval(start: date(30, 0), end: date(31, 0))
            $0.now = date(30, 1)
            $0.blocks = [self.block("Xcode", date(30, 0), date(30, 3))]
            $0.captureCountsByApp = ["Xcode": 3]
        })
        XCTAssertEqual(report.finding(.activityClock)?.status, .fail)
    }

    func testBlocksSpanningMidnightAreClampedToTheDay() {
        let report = evaluate(input {
            $0.blocks = [self.block("Xcode", date(28, 23, 30), date(29, 0, 30)),
                         self.block("Xcode", date(29, 23, 30), date(30, 0, 30))]
            $0.captureCountsByApp = ["Xcode": 2]
        })
        XCTAssertEqual(report.finding(.activityClock)?.status, .pass)
        let clamped = LibraryHealthEvaluator.clampedBlocks(
            [block("Xcode", date(28, 23, 30), date(29, 0, 30))],
            to: DateInterval(start: date(29, 0), end: date(30, 0)))
        XCTAssertEqual(clamped.first?.duration, 1_800)
    }

    func testFinishedRecordingWithoutTranscriptOrJobFails() {
        let stuck = LibraryHealthInput.Recording(
            meetingID: UUID(), title: "Standup", missingTranscript: .neverTranscribed, hasQueuedJob: false)
        XCTAssertEqual(evaluate(input { $0.recordings = [stuck] }).finding(.finishedRecordings)?.status, .fail)
        var queued = stuck
        queued.hasQueuedJob = true
        XCTAssertEqual(evaluate(input { $0.recordings = [queued] }).finding(.finishedRecordings)?.status, .pass)
    }

    func testUnfinalizedYesterdayDigestFailsOnlyAfterTheGrace() {
        let late = input { $0.schedulers.previousDay?.digestModifiedAt = date(29, 18) }
        XCTAssertEqual(evaluate(late).finding(.schedulers)?.status, .fail)
        var early = late
        early.now = date(30, 1)
        XCTAssertEqual(evaluate(early).finding(.schedulers)?.status, .pass)
    }

    func testDisabledOrUnapprovedDigestIsNotASchedulerFailure() {
        let disabled = input {
            $0.schedulers.previousDay?.digestModifiedAt = nil
            $0.schedulers.digestEnabled = false
        }
        XCTAssertEqual(evaluate(disabled).finding(.schedulers)?.status, .pass)
        let unapproved = input {
            $0.schedulers.previousDay?.digestModifiedAt = nil
            $0.schedulers.automaticInferenceAllowed = false
        }
        XCTAssertEqual(evaluate(unapproved).finding(.schedulers)?.status, .pass)
    }

    func testMissingDreamsWarnForOneDayAndFailForTwo() {
        XCTAssertEqual(evaluate(input { $0.schedulers.missingDreamDays = 1 }).finding(.schedulers)?.status, .warn)
        XCTAssertEqual(evaluate(input { $0.schedulers.missingDreamDays = 2 }).finding(.schedulers)?.status, .fail)
    }

    func testDigestCoverageBelowSixtyPercentWarns() {
        let low = input { $0.digestCoverage = DayDigestCoverage(coveredSeconds: 4_000, trackedSeconds: 10_000) }
        XCTAssertEqual(evaluate(low).finding(.digestCoverage)?.status, .warn)
        XCTAssertEqual(evaluate(input { $0.digestCoverage = nil }).finding(.digestCoverage)?.status, .pass)
    }
}
