import Foundation
import LokalBotCompanionKit
@preconcurrency import LokalBotSync
import UIKit

/// The device's copy of the Mac's library, kept by the Rust sync core
/// (Companion/protocol/ffi.md). Its calls block, so reads and local changes
/// run on one serial queue and network calls (pairing, sync, Ask) on another,
/// so a slow Mac never holds up the screens.
final class RustStore: CompanionStore, @unchecked Sendable {
    /// The name the Mac shows when it asks to allow this device.
    let deviceName: String
    private let client: SyncClient
    private let local = DispatchQueue(label: "me.dotenv.LokalBot.companion.store", qos: .userInitiated)
    private let network = DispatchQueue(label: "me.dotenv.LokalBot.companion.network", qos: .utility)

    init(client: SyncClient, deviceName: String) {
        self.client = client
        self.deviceName = deviceName
    }

    /// Opens the store in Application Support with this device's Keychain key,
    /// making the key on first launch.
    @MainActor
    static func open(deviceName: String = DeviceName.current) throws -> RustStore {
        let key = try DeviceIdentity.privateKey { generateStaticKey().privateKey }
        let config = ClientConfig(
            dbPath: try CompanionStorage.databaseURL().path,
            deviceId: try DeviceIdentity.deviceID(),
            deviceName: deviceName,
            platform: UIDevice.current.userInterfaceIdiom == .pad ? "ipados" : "ios",
            staticPrivateKey: key)
        return RustStore(client: try SyncClient(config: config), deviceName: deviceName)
    }

    // MARK: Running calls

    private func run<T: Sendable>(on queue: DispatchQueue, _ work: @escaping @Sendable (SyncClient) throws -> T) async throws -> T {
        let client = client
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try work(client))
                } catch {
                    continuation.resume(throwing: Self.storeError(error))
                }
            }
        }
    }

    private func read<T: Sendable>(_ work: @escaping @Sendable (SyncClient) throws -> T) async throws -> T {
        try await run(on: local, work)
    }

    static func storeError(_ error: Error) -> Error {
        guard let error = error as? SyncError else { return error }
        switch error {
        case .Unreachable: return CompanionStoreError.unreachable
        case .NotPaired: return CompanionStoreError.notPaired
        case .PairingRejected: return CompanionStoreError.pairingRejected
        case .PairingExpired: return CompanionStoreError.pairingExpired
        case .Revoked: return CompanionStoreError.revoked
        case .Io(let message), .Protocol(let message), .Crypto(let message), .Storage(let message),
             .InvalidInput(let message):
            return CompanionStoreError.failed(message)
        }
    }

    /// Decodes record JSON; a record this build can't read is skipped rather
    /// than failing the whole list.
    private static func decode<T: Decodable>(_ type: T.Type, _ json: String?) -> T? {
        guard let json else { return nil }
        return try? CompanionJSON.decode(type, from: json)
    }

    private static func decodeAll<T: Decodable>(_ type: T.Type, _ items: [String]) -> [T] {
        items.compactMap { decode(type, $0) }
    }

    private static func limit(_ value: Int) -> UInt32 {
        value >= Int(UInt32.max) ? 0 : UInt32(max(0, value))
    }

    // MARK: Reads

    func manifest() async throws -> Manifest? {
        try await read { Self.decode(Manifest.self, try $0.manifest()) }
    }

    func meetings(fromDay: String?, toDay: String?, limit: Int) async throws -> [Meeting] {
        try await read { Self.decodeAll(Meeting.self, try $0.meetings(fromDay: fromDay, toDay: toDay, limit: Self.limit(limit))) }
    }

    func meeting(id: String) async throws -> Meeting? {
        try await read { Self.decode(Meeting.self, try $0.meeting(id: id)) }
    }

    func transcript(meetingID: String) async throws -> Transcript? {
        try await read { Self.decode(Transcript.self, try $0.transcript(meetingId: meetingID)) }
    }

    func days(limit: Int) async throws -> [String] {
        try await read { try $0.days(limit: Self.limit(limit)) }
    }

    func day(_ date: String) async throws -> DayRecord? {
        try await read { Self.decode(DayRecord.self, try $0.day(date: date)) }
    }

    func actions(_ filter: LokalBotCompanionKit.ActionFilter) async throws -> [ActionRow] {
        let ffiFilter = LokalBotSync.ActionFilter(
            mineOnly: filter.mineOnly, status: filter.status?.rawValue,
            ownerUnclearOnly: filter.ownerUnclearOnly, dueBefore: filter.dueBefore)
        return try await read { Self.decodeAll(ActionRow.self, try $0.actions(filter: ffiFilter)) }
    }

    func people() async throws -> [Person] {
        try await read { Self.decodeAll(Person.self, try $0.people()) }
    }

    func person(id: String) async throws -> Person? {
        try await read { Self.decode(Person.self, try $0.person(id: id)) }
    }

    func projects() async throws -> [Project] {
        try await read { Self.decodeAll(Project.self, try $0.projects()) }
    }

    func project(id: String) async throws -> Project? {
        try await read { Self.decode(Project.self, try $0.project(id: id)) }
    }

    func search(_ query: String, limit: Int) async throws -> [LokalBotCompanionKit.SearchHit] {
        try await read { client in
            try client.search(query: query, limit: Self.limit(limit)).map {
                LokalBotCompanionKit.SearchHit(kind: $0.kind, key: $0.key, meetingId: $0.meetingId, title: $0.title,
                                               snippet: $0.snippet, at: $0.at, date: $0.date)
            }
        }
    }

    // MARK: Changes

    func setActionStatus(meetingID: String, actionID: String, status: ActionStatus) async throws {
        try await read { try $0.setActionStatus(meetingId: meetingID, actionId: actionID, status: status.rawValue) }
    }

    // MARK: Questions

    func ask(_ request: AskRequest, extraAddresses: [String],
             onDelta: @escaping @Sendable (String) -> Void) async throws -> AskResult {
        let json = try CompanionJSON.encodeString(request)
        let listener = DeltaListener(onDelta)
        let result = try await run(on: network) { try $0.ask(requestJson: json, extraAddresses: extraAddresses, listener: listener) }
        return try CompanionJSON.decode(AskResult.self, from: result)
    }

    func queueQuestion(_ request: AskRequest) async throws {
        let json = try CompanionJSON.encodeString(request)
        try await read { try $0.queueQuestion(requestJson: json) }
    }

    func queuedQuestions() async throws -> [AskRequest] {
        try await read { Self.decodeAll(AskRequest.self, try $0.queuedQuestions()) }
    }

    func askHistory(limit: Int) async throws -> [AskExchange] {
        try await read { Self.decodeAll(AskExchange.self, try $0.askHistory(limit: Self.limit(limit))) }
    }

    // MARK: Pairing and sync

    func pair(payload: String) async throws -> LokalBotCompanionKit.PairedMac {
        try await run(on: network) { Self.converted(try $0.pair(payload: payload)) }
    }

    func pairedMac() async throws -> LokalBotCompanionKit.PairedMac? {
        try await read { try $0.pairedMac().map(Self.converted) }
    }

    func sync(extraAddresses: [String]) async throws -> LokalBotCompanionKit.SyncReport {
        try await run(on: network) { client in
            let report = try client.sync(extraAddresses: extraAddresses)
            return LokalBotCompanionKit.SyncReport(
                received: Int(report.received), deleted: Int(report.deleted), opsApplied: Int(report.opsApplied),
                cursor: report.cursor, address: report.address.isEmpty ? nil : report.address,
                finishedAt: CompanionJSON.parseInstant(report.finishedAt) ?? Date())
        }
    }

    func unpair() async throws {
        try await run(on: network) { try $0.unpair() }
    }

    func status() async throws -> LokalBotCompanionKit.SyncStatus {
        try await read { client in
            let status = try client.status()
            return LokalBotCompanionKit.SyncStatus(
                paired: status.paired, lastSyncAt: status.lastSyncAt.flatMap(CompanionJSON.parseInstant),
                lastAddress: status.lastAddress, cursor: status.cursor, pendingOps: Int(status.pendingOps),
                macName: status.macName)
        }
    }

    private static func converted(_ mac: LokalBotSync.PairedMac) -> LokalBotCompanionKit.PairedMac {
        LokalBotCompanionKit.PairedMac(macName: mac.macName, macKeyB64: mac.macKeyB64, addresses: mac.addresses,
                                       port: mac.port, pairedAt: CompanionJSON.parseInstant(mac.pairedAt) ?? Date())
    }

    // MARK: Sample library

    func loadSampleLibrary() async throws {
        let json = try SampleLibrary.json()
        _ = try await read { try $0.importRecords(envelopesJson: json) }
    }

    func isSample() async -> Bool {
        (try? await read { try $0.isSample() }) ?? false
    }
}

/// Forwards streamed answer text from the core.
private final class DeltaListener: AskListener, @unchecked Sendable {
    private let handler: @Sendable (String) -> Void

    init(_ handler: @escaping @Sendable (String) -> Void) {
        self.handler = handler
    }

    func onDelta(text: String) {
        handler(text)
    }
}
