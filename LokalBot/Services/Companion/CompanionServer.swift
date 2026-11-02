import Foundation

/// The sync host as the Mac app uses it. `CompanionSyncServer` adapts the
/// `lokalbot-sync` crate's `SyncServer`; every call blocks, so callers stay
/// off the main thread.
protocol CompanionServer: CompanionRecordSink, Sendable {
    func start() throws
    func stop()
    func boundPort() -> Int
    func beginPairing(addresses: [String]) throws -> CompanionPairingOffer
    func cancelPairing()
    func pairedDevices() throws -> [CompanionPairedDevice]
    func removeDevice(id: String) throws
    func connectedDeviceIDs() -> Set<String>
}

/// What the host asks of the Mac app, from its own threads.
protocol CompanionServerEvents: AnyObject {
    /// Blocks until the person answers or the prompt expires.
    func approvePairing(deviceName: String, platform: String) -> Bool
    /// Applies the op and republishes the records it changed before returning.
    func applyOp(_ json: String) -> CompanionOpResult
    /// May return before the answer is finished; the output outlives the call.
    func ask(_ requestJSON: String, output: CompanionAskOutput)
    func devicesChanged()
}

struct CompanionPairingOffer: Equatable, Sendable {
    var qrPayload: String
    var pairingID: String
    var expiresAt: Date
}

struct CompanionPairedDevice: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var platform: String
    var pairedAt: Date?
    var lastSeenAt: Date?
    var lastAddress: String?

    var network: CompanionNetwork? { lastAddress.flatMap(CompanionNetwork.classify) }
}

/// The Mac's long-term X25519 key for the sync host.
struct CompanionStaticKey: Equatable, Sendable {
    var privateKey: Data
    var publicKey: Data
}

/// Everything the host needs from the crate besides the server itself, so the
/// controller and the publisher can be exercised without a listener.
struct CompanionServerFactory {
    struct Configuration: Equatable {
        var databasePath: String
        var macName: String
        var staticPrivateKey: Data
        var port: Int
    }

    var makeServer: (_ configuration: Configuration, _ events: CompanionServerEvents) throws -> CompanionServer
    var generateStaticKey: () -> CompanionStaticKey
    var publicKey: (_ privateKey: Data) throws -> Data
    var keyFingerprint: (_ publicKey: Data) -> String
    var localAddresses: () -> [String]
}

enum CompanionServerError: LocalizedError {
    case unavailable
    case keychain(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "Sharing with phones and tablets is not available in this build."
        case .keychain(let detail):
            "LokalBot could not read or save its sharing key in the Keychain (\(detail))."
        }
    }
}

/// The Mac's companion key lives in the Keychain beside LokalBot's other
/// per-install keys: generic password, this app identity's service, never
/// synchronized. Only the private half is stored; the public half is derived.
enum CompanionKeyStore {
    static let account = "companion-static-key"

    static func loadOrCreate(factory: CompanionServerFactory) throws -> CompanionStaticKey {
        let existing: Data?
        do {
            existing = try KeychainSecrets.existingData(account: account)
        } catch {
            throw CompanionServerError.keychain(error.localizedDescription)
        }
        if let existing, existing.count == 32 {
            return CompanionStaticKey(privateKey: existing, publicKey: try factory.publicKey(existing))
        }
        let key = factory.generateStaticKey()
        KeychainSecrets.set(key.privateKey, account: account)
        guard (try? KeychainSecrets.existingData(account: account)) == key.privateKey else {
            throw CompanionServerError.keychain("the new key could not be read back")
        }
        return key
    }
}
