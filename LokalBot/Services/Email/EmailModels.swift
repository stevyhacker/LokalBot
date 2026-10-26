import Foundation

/// One connected mailbox. Several can be connected; each keeps its own
/// sign-in, cursor, and downloaded conversations.
struct EmailAccount: Codable, Equatable, Identifiable, Sendable {
    enum Provider: String, Codable, Sendable {
        case gmail
    }

    var id: UUID
    var provider: Provider
    /// The mailbox address, lowercased.
    var address: String
    /// Other addresses this mailbox sends as (Gmail "Send mail as"), lowercased.
    var aliases: [String]
    var connectedAt: Date
    var sync = EmailSyncState()

    /// Every address that means "me" for this mailbox.
    var ownedAddresses: Set<String> { Set([address] + aliases) }
}

struct EmailSyncState: Codable, Equatable, Sendable {
    /// Gmail's `historyId` after the last complete pass. Nil until the first
    /// window scan finishes, and again after Gmail expires the history.
    var historyID: String?
    /// Calendar people and the last time each was on the calendar. Their
    /// threads keep qualifying for the window after that, so a calendar that
    /// is briefly unavailable (at launch, or with calendar use paused) never
    /// deletes mail or triggers new searches.
    var people: [String: Date] = [:]
    /// People whose older threads were searched to the end. Someone who joins
    /// the calendar later gets one search of their own; someone a capped scan
    /// never reached stays unsearched until a pass reaches them.
    var searchedAddresses: Set<String> = []
    /// Threads Gmail couldn't return last time, checked again next pass.
    var retryThreadIDs: Set<String> = []
    var lastAttemptAt: Date?
    var lastSuccessAt: Date?
    var lastError: String?
    /// The account must sign in again before it can sync.
    var needsSignIn = false
    var threadCount = 0
    var messageCount = 0
    /// The last scan stopped at `EmailScope.maxThreadsPerScan`.
    var capped = false
}

struct EmailAddress: Codable, Hashable, Sendable {
    var name: String?
    /// Lowercased.
    var address: String
}

struct EmailAttachment: Codable, Equatable, Sendable {
    var name: String
    var mimeType: String
    var size: Int
}

/// One message as LokalBot keeps it: who, when, and the text. Attachment
/// contents are never downloaded.
struct EmailMessage: Codable, Equatable, Identifiable, Sendable {
    /// The provider's id (Gmail message id).
    var id: String
    /// The `Message-ID` header, which matches the same message in another
    /// account.
    var internetMessageID: String?
    var date: Date
    var from: EmailAddress?
    var to: [EmailAddress]
    var cc: [EmailAddress]
    var subject: String
    /// Sent by the account (Gmail's SENT label). A `From` header with the
    /// person's address proves nothing; anyone can write it.
    var fromMe: Bool
    /// Mailing list, newsletter, or machine-sent (`EmailScope.isBulk`).
    var isBulk: Bool
    /// Plain text, HTML converted, quoted history kept, capped at
    /// `EmailScope.maxBodyCharacters`.
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

/// A conversation that qualified for download, with only its messages
/// inside the window, oldest first.
struct EmailThread: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var accountID: UUID
    var subject: String
    var messages: [EmailMessage]

    var lastMessageAt: Date? { messages.last?.date }

    /// Every address in the thread, lowercased.
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

/// One signed-in Gmail session. Stored in the Keychain only.
struct EmailCredentials: Codable, Equatable, Sendable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
}

protocol EmailSecretStore: Sendable {
    func googleClient() -> GoogleOAuthClient?
    func setGoogleClient(_ client: GoogleOAuthClient?)
    /// Nil when the account was never signed in or signed out; throws when
    /// the Keychain can't be read right now, which is not a sign-out.
    func credentials(for accountID: UUID) throws -> EmailCredentials?
    func setCredentials(_ credentials: EmailCredentials?, for accountID: UUID)
}

/// Keychain items under the app's own service, like the ChatGPT sign-in.
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
