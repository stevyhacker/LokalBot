import Foundation
import LokalBotSync

extension CompanionServerFactory {
    /// The `lokalbot-sync` crate: the local package `Vendor/lokalbot-sync`,
    /// built by `Scripts/build-sync-xcframework.sh`.
    static let live = CompanionServerFactory(
        makeServer: { configuration, events in
            try CompanionSyncServer(configuration: configuration, events: events)
        },
        generateStaticKey: {
            let key = LokalBotSync.generateStaticKey()
            return CompanionStaticKey(privateKey: key.privateKey, publicKey: key.publicKey)
        },
        publicKey: { try LokalBotSync.publicKeyFor(privateKey: $0) },
        keyFingerprint: { LokalBotSync.keyFingerprint(publicKey: $0) },
        localAddresses: { LokalBotSync.localAddresses() })
}

/// `SyncServer` behind the app's `CompanionServer`. The crate's calls are
/// blocking and thread-safe; the host calls them from its own queue.
final class CompanionSyncServer: CompanionServer, @unchecked Sendable {
    private let server: SyncServer

    init(configuration: CompanionServerFactory.Configuration, events: CompanionServerEvents) throws {
        server = try SyncServer(
            config: ServerConfig(
                dbPath: configuration.databasePath,
                macName: configuration.macName,
                staticPrivateKey: configuration.staticPrivateKey,
                port: UInt16(clamping: configuration.port)),
            delegate: CompanionSyncDelegate(events: events))
    }

    func start() throws { try server.start() }
    func stop() { server.stop() }
    func boundPort() -> Int { Int(server.boundPort()) }

    func publish(kind: String, key: String, bodyJSON: String) throws -> Bool {
        try server.publish(kind: kind, key: key, bodyJson: bodyJSON)
    }

    func remove(kind: String, key: String) throws -> Bool {
        try server.remove(kind: kind, key: key)
    }

    func recordKeys(kind: String) throws -> [String] {
        try server.recordKeys(kind: kind)
    }

    func setManifest(bodyJSON: String) throws {
        try server.setManifest(bodyJson: bodyJSON)
    }

    func beginPairing(addresses: [String]) throws -> CompanionPairingOffer {
        let offer = server.beginPairing(addresses: addresses)
        return CompanionPairingOffer(
            qrPayload: offer.qrPayload, pairingID: offer.pairingId,
            expiresAt: Self.date(offer.expiresAt) ?? Date().addingTimeInterval(5 * 60))
    }

    func cancelPairing() { server.cancelPairing() }

    func pairedDevices() throws -> [CompanionPairedDevice] {
        try server.pairedDevices().map {
            CompanionPairedDevice(
                id: $0.deviceId, name: $0.name, platform: $0.platform,
                pairedAt: Self.date($0.pairedAt), lastSeenAt: $0.lastSeenAt.flatMap(Self.date),
                lastAddress: $0.lastAddress)
        }
    }

    func removeDevice(id: String) throws { try server.removeDevice(deviceId: id) }

    func connectedDeviceIDs() -> Set<String> { Set(server.connectedDeviceIds()) }

    /// The crate writes ISO 8601 UTC, with or without fractional seconds.
    static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

/// The crate's callback interface, forwarded to the app on the crate's threads.
private final class CompanionSyncDelegate: ServerDelegate, @unchecked Sendable {
    private let events: CompanionServerEvents

    init(events: CompanionServerEvents) {
        self.events = events
    }

    func approvePairing(deviceName: String, platform: String) -> Bool {
        events.approvePairing(deviceName: deviceName, platform: platform)
    }

    func applyOp(opJson: String) -> OpOutcome {
        let result = events.applyOp(opJson)
        return OpOutcome(status: result.status.rawValue, message: result.message)
    }

    func ask(requestJson: String, sink: AskSink) {
        events.ask(requestJson, output: CompanionAskSinkOutput(sink: sink))
    }

    func devicesChanged() {
        events.devicesChanged()
    }
}

/// `AskSink` works from any thread and ignores calls after the answer ends.
private final class CompanionAskSinkOutput: CompanionAskOutput, @unchecked Sendable {
    private let sink: AskSink

    init(sink: AskSink) {
        self.sink = sink
    }

    func delta(_ text: String) { sink.delta(text: text) }
    func done(_ resultJSON: String) { sink.done(resultJson: resultJSON) }
    func failed(_ message: String) { sink.failed(message: message) }
}
