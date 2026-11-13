import XCTest
@testable import LokalBot

final class BackgroundActivityTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ value: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return try XCTUnwrap(formatter.date(from: value))
    }

    private func inputs() throws -> BackgroundActivity.Inputs {
        BackgroundActivity.Inputs(
            now: try date("2026-09-29T14:00:00Z"),
            calendar: calendar,
            locale: Locale(identifier: "en_US_POSIX"))
    }

    func testNothingRunningProducesNoActivities() throws {
        XCTAssertEqual(BackgroundActivity.derive(try inputs()), [])
    }

    func testActivitiesAreOrderedByKindPriority() throws {
        var inputs = try inputs()
        let meetingID = UUID()
        inputs.reindex = BackgroundCount(done: 1, total: 4)
        inputs.downloads = [.init(id: "qwen", name: "Qwen3 4B", fraction: 0.42)]
        inputs.dream = .init(day: try date("2026-09-26T00:00:00Z"), remainingDays: 2)
        inputs.digests = [.init(
            id: UUID(), day: try date("2026-09-28T00:00:00Z"),
            progress: DayDigestProgress(completedSegments: 3, totalSegments: 8))]
        inputs.meetings = [.init(id: meetingID, title: "Product standup", stage: .transcribing)]

        let activities = BackgroundActivity.derive(inputs)

        XCTAssertEqual(activities.map(\.kind), [.meetingProcessing, .dayDigest, .dream, .download, .reindex])
        XCTAssertEqual(activities[0].title, "Product standup")
        XCTAssertEqual(activities[0].detail, "Transcribing")
        XCTAssertEqual(activities[0].destination, .meeting(meetingID))
        XCTAssertEqual(activities[1].title, "Day digest · Yesterday")
        XCTAssertEqual(activities[1].detail, "Part 4 of 8")
        XCTAssertEqual(try XCTUnwrap(activities[1].fraction), 3.0 / 9.0, accuracy: 0.0001)
        XCTAssertEqual(activities[1].destination, .day(try date("2026-09-28T00:00:00Z")))
        XCTAssertEqual(activities[2].title, "Overnight review · Sep 26")
        XCTAssertEqual(activities[2].detail, "2 more days queued")
        XCTAssertNil(activities[2].fraction)
        XCTAssertEqual(activities[3].title, "Downloading Qwen3 4B")
        XCTAssertEqual(activities[3].detail, "42%")
        XCTAssertEqual(activities[3].destination, .models)
        XCTAssertEqual(activities[4].detail, "1 of 4 meetings")
        XCTAssertNil(activities[4].destination)
    }

    func testQueuedMeetingsAreSummarizedWithoutParkedOrFailedOnes() throws {
        var inputs = try inputs()
        inputs.meetings = [
            .init(id: UUID(), title: "A", stage: .queued),
            .init(id: UUID(), title: "B", stage: .queued),
            .init(id: UUID(), title: "C", stage: .waitingForModels),
            .init(id: UUID(), title: "D", stage: .failed("offline")),
        ]
        let queuedOnly = BackgroundActivity.derive(inputs)
        XCTAssertEqual(queuedOnly.count, 1)
        XCTAssertEqual(queuedOnly[0].detail, "2 meetings queued")
        XCTAssertNil(queuedOnly[0].destination)

        inputs.meetings.append(.init(id: UUID(), title: "E", stage: .summarizing))
        let withActive = BackgroundActivity.derive(inputs)
        XCTAssertEqual(withActive.count, 1)
        XCTAssertEqual(withActive[0].title, "E")
        XCTAssertEqual(withActive[0].detail, "Writing notes · 2 queued")
    }

    func testDigestDetailFollowsItsPhase() throws {
        var inputs = try inputs()
        let today = try date("2026-09-29T00:00:00Z")
        inputs.digests = [.init(id: UUID(), day: today, progress: nil)]
        XCTAssertEqual(BackgroundActivity.derive(inputs).first?.title, "Day digest · Today")
        XCTAssertEqual(BackgroundActivity.derive(inputs).first?.detail, "Preparing")
        XCTAssertNil(BackgroundActivity.derive(inputs).first?.fraction)

        inputs.digests[0].progress = DayDigestProgress(
            completedSegments: 8, totalSegments: 8, isAggregating: true)
        XCTAssertEqual(BackgroundActivity.derive(inputs).first?.detail, "Combining tasks")
    }

    func testFinishedReindexIsHidden() throws {
        var inputs = try inputs()
        inputs.reindex = BackgroundCount(done: 4, total: 4)
        XCTAssertEqual(BackgroundActivity.derive(inputs), [])
    }
}
