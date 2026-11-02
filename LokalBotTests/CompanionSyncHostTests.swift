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

private final class CompanionNoEvents: CompanionServerEvents {
    func approvePairing(deviceName: String, platform: String) -> Bool { false }
    func applyOp(_ json: String) -> CompanionOpResult { CompanionOpResult(status: .rejected) }
    func ask(_ requestJSON: String, output: CompanionAskOutput) { output.failed("not in tests") }
    func devicesChanged() {}
}
