import AVFoundation
import LokalBotSync
import os
import XCTest
@testable import LokalBot

/// The app's adapter over the `lokalbot-sync` crate: keys, records, and a
/// pairing offer through the real host store. The listener is never started,
/// so the test binds no port.
final class CompanionSyncHostTests: XCTestCase {
    private var fixture: CompanionFixtureLibrary!

    override func setUpWithError() throws {
        fixture = try CompanionFixtureLibrary.make()
    }

    override func tearDown() {
        fixture?.remove()
        fixture = nil
    }

    func testRecordsAndPairingGoThroughTheCrate() throws {
        let factory = CompanionServerFactory.live
        let key = factory.generateStaticKey()
        XCTAssertEqual(key.privateKey.count, 32)
        XCTAssertEqual(try factory.publicKey(key.privateKey), key.publicKey)
        let fingerprint = factory.keyFingerprint(key.publicKey)
        XCTAssertEqual(fingerprint.count, 16)
        XCTAssertTrue(CompanionBonjourAdvertiser.instanceName(fingerprint: fingerprint).hasPrefix("LokalBot-"))

        let database = fixture.root.appendingPathComponent("companion", isDirectory: true)
        try FileManager.default.createDirectory(at: database, withIntermediateDirectories: true)
        let server = try factory.makeServer(
            .init(databasePath: database.appendingPathComponent("companion.sqlite").path,
                  macName: "Test Mac", staticPrivateKey: key.privateKey, port: 0),
            CompanionNoEvents())

        let publisher = CompanionPublisher(
            sink: server,
            context: .init(root: fixture.root, activityDatabaseURL: fixture.activityDatabaseURL,
                           sharing: CompanionSharing(), macName: "Test Mac"),
            calendar: fixture.calendar, debounce: .milliseconds(1), clock: { [now = fixture.now] in now })
        publisher.reconcileAll()
        let report = publisher.flush()
        XCTAssertEqual(report.failed, 0)
        XCTAssertGreaterThan(report.changed, 0)
        let meetingKey = fixture.designReview.id.uuidString.lowercased()
        XCTAssertTrue(try server.recordKeys(kind: "meeting").contains(meetingKey))
        XCTAssertTrue(try server.recordKeys(kind: "day").contains(fixture.dayKey))

        // Identical bodies are no-ops; a deleted meeting becomes a tombstone.
        publisher.reconcileAll()
        XCTAssertEqual(publisher.flush().changed, 0)
        try FileManager.default.removeItem(at: fixture.designReview.folderURL(in: StorageManager(rootURL: fixture.root)))
        publisher.meetingsChanged([fixture.designReview.id], days: [fixture.designReview.startedAt])
        XCTAssertGreaterThan(publisher.flush().removed, 0)
        XCTAssertFalse(try server.recordKeys(kind: "meeting").contains(meetingKey))

        let offer = try server.beginPairing(addresses: ["192.168.1.20", "100.101.102.103"])
        XCTAssertTrue(offer.qrPayload.hasPrefix("lokalbot://pair?d="), offer.qrPayload)
        XCTAssertGreaterThan(offer.expiresAt, Date())
        XCTAssertLessThanOrEqual(offer.expiresAt, Date().addingTimeInterval(5 * 60 + 5))
        server.cancelPairing()
        XCTAssertEqual(try server.pairedDevices(), [])
        XCTAssertEqual(server.connectedDeviceIDs(), [])
    }
}

/// A recording's whole trip over loopback: a real listener and `SyncClient`,
/// the receiver, and the import.
final class CompanionRecordingTripTests: XCTestCase {
    @MainActor
    func testARecordingFromAPairedDeviceBecomesAMeeting() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CompanionTrip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let storage = StorageManager(rootURL: root)
        var added: [Meeting] = []
        let receiver = CompanionRecordingReceiver(dependencies: .init(
            meetingExists: { id in added.contains { $0.id == id } },
            language: { .english },
            importRecording: { url, origin in
                try await MeetingImportService.importDeviceRecording(from: url, origin: origin, storage: storage)
            },
            didImport: { added.append($0) }))
        let factory = CompanionServerFactory.live
        let events = CompanionTripEvents(receiver: receiver)
        let server = try CompanionSyncServer(
            configuration: .init(databasePath: root.appendingPathComponent("companion/companion.sqlite").path,
                                 macName: "Test Mac", staticPrivateKey: factory.generateStaticKey().privateKey, port: 0),
            events: events, loopbackOnly: true)
        try server.start()
        addTeardownBlock { server.stop() }
        let client = try SyncClient(config: ClientConfig(
            dbPath: root.appendingPathComponent("phone/companion.sqlite").path,
            deviceId: UUID().uuidString, deviceName: "Test iPad", platform: "ipados",
            staticPrivateKey: factory.generateStaticKey().privateKey))
        let offer = try server.beginPairing(addresses: ["127.0.0.1"])
        let sample = root.appendingPathComponent("sample.aac")
        try CompanionTripEvents.writeSpeechlessADTS(to: sample)

        // The crate blocks, and the receiver needs this actor, so hop off it.
        let (id, report) = try await Task.detached {
            _ = try client.pair(payload: offer.qrPayload)
            let draft = try client.beginRecording(title: "Site visit")
            try FileManager.default.copyItem(atPath: sample.path, toPath: draft.filePath)
            _ = try client.finishRecording(id: draft.id, durationSeconds: 2)
            return (draft.id, try client.uploadRecordings(extraAddresses: [], listener: CompanionTripProgress()))
        }.value

        XCTAssertEqual(report.uploaded, 1)
        let meeting = try XCTUnwrap(added.first)
        XCTAssertEqual(meeting.id, UUID(uuidString: id))
        XCTAssertEqual(meeting.title, "Site visit")
        XCTAssertEqual(meeting.appName, "Test iPad")
        XCTAssertNotNil(MeetingAudioFiles.transcribableURL(for: .mic, in: meeting.folderURL(in: storage)))
        XCTAssertEqual(try client.recordings().first?.state, "uploaded")
    }
}

private final class CompanionTripProgress: UploadListener, @unchecked Sendable {
    func onProgress(recordingId: String, sentBytes: UInt64, totalBytes: UInt64) {}
}

private final class CompanionTripEvents: CompanionServerEvents, @unchecked Sendable {
    private let receiver: CompanionRecordingReceiver

    init(receiver: CompanionRecordingReceiver) {
        self.receiver = receiver
    }

    /// Two seconds of tone, because the import measures real audio.
    static func writeSpeechlessADTS(to url: URL) throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 88_200))
        buffer.frameLength = 88_200
        let samples = try XCTUnwrap(buffer.floatChannelData)[0]
        for index in 0..<88_200 { samples[index] = 0.2 * sinf(Float(index) * 2 * .pi * 220 / 44_100) }
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000,
        ])
        try file.write(from: buffer)
    }

    func approvePairing(deviceName: String, platform: String) -> Bool { true }
    func applyOp(_ json: String) -> CompanionOpResult { CompanionOpResult(status: .rejected) }
    func ask(_ requestJSON: String, output: CompanionAskOutput) { output.failed("not in tests") }
    func devicesChanged() {}
    func acceptsRecordings() -> Bool { true }

    func receiveRecording(_ json: String, fileURL: URL) -> CompanionUploadOutcome {
        let finished = DispatchSemaphore(value: 0)
        let outcome = OSAllocatedUnfairLock<CompanionUploadOutcome?>(initialState: nil)
        Task { @MainActor [receiver] in
            let result = await receiver.receive(json, fileURL: fileURL)
            outcome.withLock { $0 = result }
            finished.signal()
        }
        finished.wait()
        return outcome.withLock { $0 } ?? .deferred("no answer")
    }
}

private final class CompanionNoEvents: CompanionServerEvents {
    func approvePairing(deviceName: String, platform: String) -> Bool { false }
    func applyOp(_ json: String) -> CompanionOpResult { CompanionOpResult(status: .rejected) }
    func ask(_ requestJSON: String, output: CompanionAskOutput) { output.failed("not in tests") }
    func devicesChanged() {}
    func acceptsRecordings() -> Bool { false }
    func receiveRecording(_ json: String, fileURL: URL) -> CompanionUploadOutcome { .rejected("not in tests") }
}
