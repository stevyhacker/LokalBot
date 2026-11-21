import Foundation

struct EmailAccount: Codable, Equatable, Identifiable, Sendable {
    enum Provider: String, Codable, Sendable {
        case gmail
    }

    var id: UUID
    var provider: Provider
    var address: String
    var aliases: [String]
    var connectedAt: Date
    var sync = EmailSyncState()

    var ownedAddresses: Set<String> { Set([address] + aliases) }
}

struct EmailSyncState: Codable, Equatable, Sendable {
    var historyID: String?
    var people: [String: Date] = [:]
    var searchedAddresses: Set<String> = []
    var retryThreadIDs: Set<String> = []
    var lastAttemptAt: Date?
    var lastSuccessAt: Date?
    var lastError: String?
    var needsSignIn = false
    var threadCount = 0
    var messageCount = 0
    var capped = false
}

struct EmailAddress: Codable, Hashable, Sendable {
    var name: String?
    var address: String
}

struct EmailAttachment: Codable, Equatable, Sendable {
    var name: String
    var mimeType: String
    var size: Int
}

struct EmailMessage: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var internetMessageID: String?
    var date: Date
    var from: EmailAddress?
    var to: [EmailAddress]
    var cc: [EmailAddress]
    var subject: String
    var fromMe: Bool
    var isBulk: Bool
    var body: String
    var attachments: [EmailAttachment]

    var participants: [EmailAddress] {
        var all: [EmailAddress] = []
        if let from { all.append(from) }
        all.append(contentsOf: to)
        all.append(contentsOf: cc)
        return all
    }
}

struct EmailThread: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var accountID: UUID
    var subject: String
    var messages: [EmailMessage]

    var lastMessageAt: Date? { messages.last?.date }

    var participantAddresses: Set<String> {
        var addresses: Set<String> = []
        for message in messages {
            for participant in message.participants {
                addresses.insert(participant.address)
            }
        }
        return addresses
    }
}

struct EmailCredentials: Codable, Equatable, Sendable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var clientID: String?
    var pendingRevocationTokens: [String]?
}

protocol EmailSecretStore: Sendable {
    func googleClient() -> GoogleOAuthClient?
    func setGoogleClient(_ client: GoogleOAuthClient?)
    func credentials(for accountID: UUID) throws -> EmailCredentials?
    func setCredentials(_ credentials: EmailCredentials?, for accountID: UUID)
}

struct KeychainEmailSecretStore: EmailSecretStore {
    static let googleClientAccount = "email-google-client"

    static func credentialsAccount(_ accountID: UUID) -> String {
        "email-credentials-\(accountID.uuidString.lowercased())"
    }

    func googleClient() -> GoogleOAuthClient? {
        decode(Self.googleClientAccount)
    }

    func setGoogleClient(_ client: GoogleOAuthClient?) {
        encode(client, account: Self.googleClientAccount)
    }

    func credentials(for accountID: UUID) throws -> EmailCredentials? {
        guard let data = try KeychainSecrets.existingData(account: Self.credentialsAccount(accountID)) else {
            return nil
        }
        return try? JSONDecoder().decode(EmailCredentials.self, from: data)
    }

    func setCredentials(_ credentials: EmailCredentials?, for accountID: UUID) {
        encode(credentials, account: Self.credentialsAccount(accountID))
    }

    private func decode<T: Decodable>(_ account: String) -> T? {
        guard let data = KeychainSecrets.data(account: account) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func encode<T: Encodable>(_ value: T?, account: String) {
        guard let value, let data = try? JSONEncoder().encode(value) else {
            KeychainSecrets.delete(account: account)
            return
        }
        KeychainSecrets.set(data, account: account)
    }
}
