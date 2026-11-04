import XCTest
@testable import LokalBot

@MainActor
final class CompanionRecordingReceiverTests: XCTestCase {
    private let file = URL(fileURLWithPath: "/tmp/upload.aac")
    private let id = UUID()

    private func json(format: String = "aac-adts", title: String? = "Site visit",
                      startedAt: String? = "2026-11-04T09:30:00.000Z", id: String? = nil) throws -> String {
        var recording: [String: Any] = [
            "id": id ?? self.id.uuidString.lowercased(), "format": format, "byteCount": 12,
            "deviceId": "device", "deviceName": "Stevan's iPad", "platform": "ipados",
        ]
        recording["title"] = title
        recording["startedAt"] = startedAt
        return String(decoding: try JSONSerialization.data(withJSONObject: recording), as: UTF8.self)
    }

    private final class Calls {
        var origins: [MeetingImportService.DeviceOrigin] = []
        var added: [Meeting] = []
        var existing: [Meeting] = []
    }

    private func receiver(calls: Calls,
                          importing: @escaping (MeetingImportService.DeviceOrigin) throws -> Meeting = { origin in
                              Meeting(id: origin.id, title: origin.title, appName: origin.deviceName,
                                      startedAt: origin.startedAt ?? Date(), relativePath: "x")
                          }) -> CompanionRecordingReceiver {
        CompanionRecordingReceiver(dependencies: .init(
            meetingExists: { id in calls.existing.contains { $0.id == id } },
            language: { .english },
            importRecording: { _, origin in
                calls.origins.append(origin)
                return try importing(origin)
            },
            didImport: { calls.added.append($0) }))
    }

    func testARecordingBecomesAMeetingWithItsDescription() async throws {
        let calls = Calls()
        let outcome = await receiver(calls: calls).receive(try json(), fileURL: file)

        XCTAssertEqual(outcome, .accepted(meetingID: id))
        let origin = try XCTUnwrap(calls.origins.first)
        XCTAssertEqual(origin.id, id)
        XCTAssertEqual(origin.title, "Site visit")
        XCTAssertEqual(origin.deviceName, "Stevan's iPad")
        XCTAssertEqual(origin.startedAt, CompanionSyncServer.date("2026-11-04T09:30:00.000Z"))
        XCTAssertEqual(calls.added.map(\.id), [id])
    }

    func testAnUntitledRecordingIsNamedAfterItsDevice() async throws {
        let calls = Calls()
        _ = await receiver(calls: calls).receive(try json(title: "  "), fileURL: file)
        XCTAssertEqual(calls.origins.first?.title, "Recording from Stevan's iPad")
    }

    func testARecordingAlreadyHereIsAcceptedWithoutASecondMeeting() async throws {
        let calls = Calls()
        calls.existing = [Meeting(id: id, title: "Site visit", appName: "x", startedAt: Date(), relativePath: "x")]
        let outcome = await receiver(calls: calls).receive(try json(), fileURL: file)

        XCTAssertEqual(outcome, .accepted(meetingID: id))
        XCTAssertTrue(calls.origins.isEmpty)
        XCTAssertTrue(calls.added.isEmpty)
    }

    func testARestartedHostCannotImportTheSameRecordingTwice() async throws {
        let calls = Calls()
        let started = AsyncStream<Void>.makeStream()
        let gate = AsyncStream<Void>.makeStream()
        let receiver = CompanionRecordingReceiver(dependencies: .init(
            meetingExists: { id in calls.existing.contains { $0.id == id } },
            language: { .english },
            importRecording: { _, origin in
                started.continuation.yield()
                for await _ in gate.stream { break }
                return Meeting(id: origin.id, title: origin.title, appName: origin.deviceName,
                               startedAt: Date(), relativePath: "x")
            },
            didImport: { calls.added.append($0); calls.existing.append($0) }))
        let body = try json()
        let url = file
        let first = Task { await receiver.receive(body, fileURL: url) }
        for await _ in started.stream { break }

        let second = await receiver.receive(try json(), fileURL: file)
        XCTAssertEqual(second.status, .deferred)
        gate.continuation.yield()
        let firstOutcome = await first.value
        XCTAssertEqual(firstOutcome, .accepted(meetingID: id))
        XCTAssertEqual(calls.added.count, 1)

        let third = await receiver.receive(try json(), fileURL: file)
        XCTAssertEqual(third, .accepted(meetingID: id))
        XCTAssertEqual(calls.added.count, 1)
    }

    func testWhatNoRetryCanFixIsRejected() async throws {
        let calls = Calls()
        var outcome = await receiver(calls: calls).receive("not json", fileURL: file)
        XCTAssertEqual(outcome.status, .rejected)
        outcome = await receiver(calls: calls).receive(try json(id: "../evil"), fileURL: file)
        XCTAssertEqual(outcome.status, .rejected)
        outcome = await receiver(calls: calls).receive(try json(format: "wav"), fileURL: file)
        XCTAssertEqual(outcome.status, .rejected)
        XCTAssertTrue(calls.origins.isEmpty)

        outcome = await receiver(calls: calls) { _ in
            throw MeetingImportService.ImportError.noAudio("Site visit")
        }.receive(try json(), fileURL: file)
        XCTAssertEqual(outcome.status, .rejected)
        XCTAssertTrue(calls.added.isEmpty)
    }

    func testATransientFailureIsDeferredSoTheDeviceKeepsItsCopy() async throws {
        let calls = Calls()
        let outcome = await receiver(calls: calls) { _ in
            throw MeetingImportService.ImportError.cannotCreateMeeting("Site visit", "The disk is full.")
        }.receive(try json(), fileURL: file)

        XCTAssertEqual(outcome.status, .deferred)
        XCTAssertTrue(try XCTUnwrap(outcome.message).contains("The disk is full."))
        XCTAssertTrue(calls.added.isEmpty)
    }
}
