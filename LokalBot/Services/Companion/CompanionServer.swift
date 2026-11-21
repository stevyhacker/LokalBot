import Foundation

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

protocol CompanionServerEvents: AnyObject {
    func approvePairing(deviceName: String, platform: String) -> Bool
    func applyOp(_ json: String) -> CompanionOpResult
    func ask(_ requestJSON: String, output: CompanionAskOutput)
    func devicesChanged()
    func acceptsRecordings() -> Bool
    func receiveRecording(_ json: String, fileURL: URL) -> CompanionUploadOutcome
}

struct CompanionUploadOutcome: Equatable, Sendable {
    enum Status: String, Sendable {
        case accepted
        case deferred
        case rejected
    }

    var status: Status
    var meetingID: String?
    var message: String?

    static func accepted(meetingID: UUID) -> Self {
        Self(status: .accepted, meetingID: meetingID.uuidString)
    }

    static func deferred(_ message: String) -> Self {
        Self(status: .deferred, message: message)
    }

    static func rejected(_ message: String) -> Self {
        Self(status: .rejected, message: message)
    }
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

struct CompanionStaticKey: Equatable, Sendable {
    var privateKey: Data
    var publicKey: Data
}

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
