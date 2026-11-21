import AppKit
import CryptoKit
import Foundation

enum EmailSyncSchedule {
    enum Reason: String, Equatable, Sendable {
        case firstSync = "first"
        case morning
        case launch
        case beforeMeeting = "before-meeting"
        case interval
        case manual
    }

    static let minimumGap: TimeInterval = 15 * 60
    static let interval: TimeInterval = 3 * 3_600
    static let morningHour = 6
    static let beforeMeetingLead: TimeInterval = 30 * 60

    static func due(now: Date, lastAttempt: Date?, lastSuccess: Date?, launched: Bool,
                    nextMeetingStart: () -> Date?, calendar: Calendar) -> Reason? {
        if let lastAttempt, now.timeIntervalSince(lastAttempt) < minimumGap, now >= lastAttempt { return nil }
        guard let lastSuccess else { return .firstSync }
        if let morning = calendar.date(bySettingHour: morningHour, minute: 0, second: 0, of: now),
           now >= morning, lastSuccess < morning {
            return .morning
        }
        let sinceSuccess = now.timeIntervalSince(lastSuccess)
        if launched, sinceSuccess >= minimumGap { return .launch }
        if sinceSuccess >= minimumGap, let start = nextMeetingStart(), start > now,
           start.timeIntervalSince(now) <= beforeMeetingLead {
            return .beforeMeeting
        }
        if sinceSuccess >= interval { return .interval }
        return nil
    }
}

@MainActor
final class EmailController: ObservableObject {
    @Published private(set) var accounts: [EmailAccount] = []
    @Published private(set) var hasGoogleClient = false
    @Published private(set) var usesOwnClient = false
    let hasBuiltInClient: Bool
    @Published private(set) var syncingAccountID: UUID?
    @Published private(set) var isSigningIn = false
    @Published var lastError: String?
    @Published private(set) var mailRevision = 0

    var attendeeAddresses: @MainActor () -> Set<String> = { [] }
    var nextMeetingStart: @MainActor () -> Date? = { nil }
    var canSync: @MainActor () -> Bool = { true }

    private let root: URL
    private let secrets: EmailSecretStore
    private let authorizer: GmailAuthorizer
    private let keyProvider: @MainActor () throws -> SymmetricKey
    private let now: () -> Date
    private var store: EmailStore?
    private var timer: Timer?
    private var syncTask: Task<Void, Never>?
    private var signInTask: Task<Void, Never>?
    private var manualRequests: Set<UUID> = []
    private var launchPending: Set<UUID> = []
    private var accountsLoaded = false
    private var started = false

    init(root: URL,
         secrets: EmailSecretStore = KeychainEmailSecretStore(),
         builtInClient: GoogleOAuthClient? = .builtIn(),
         authorizer: GmailAuthorizer? = nil,
         keyProvider: @escaping @MainActor () throws -> SymmetricKey = { try EmailStore.liveKey() },
         now: @escaping () -> Date = Date.init) {
        self.root = root
        self.secrets = secrets
        hasBuiltInClient = builtInClient != nil
        self.authorizer = authorizer ?? GmailAuthorizer(secrets: secrets, builtInClient: builtInClient)
        self.keyProvider = keyProvider
        self.now = now
        refreshClientState()
    }

    private func refreshClientState() {
        usesOwnClient = secrets.googleClient() != nil
        hasGoogleClient = usesOwnClient || hasBuiltInClient
    }

    func start() {
        guard !started else { return }
        started = true
        refreshClientState()
        do {
            try loadAccountsIfNeeded()
        } catch {
            lastError = error.localizedDescription
        }
        launchPending = Set(accounts.map(\.id))
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        syncTask?.cancel()
        syncTask = nil
        signInTask?.cancel()
        signInTask = nil
        started = false
    }

    private func openStore() throws -> EmailStore {
        if let store { return store }
        let opened = EmailStore(root: root, key: try keyProvider())
        store = opened
        return opened
    }

    private struct UnreadableAccounts: LocalizedError {
        let detail: String
        var errorDescription: String? { "Saved email accounts couldn't be read: \(detail)" }
    }

    private func loadAccountsIfNeeded() throws {
        guard !accountsLoaded else { return }
        if EmailStore.hasAccounts(root: root) {
            do {
                accounts = try openStore().loadAccounts()
            } catch {
                throw UnreadableAccounts(detail: error.localizedDescription)
            }
        }
        accountsLoaded = true
    }

    private func saveAccounts() throws {
        try loadAccountsIfNeeded()
        try openStore().saveAccounts(accounts)
    }

    func importGoogleClient(from url: URL) {
        do {
            let client = try GoogleOAuthClient(json: Data(contentsOf: url))
            secrets.setGoogleClient(client)
            refreshClientState()
            lastError = nil
        } catch let error as GmailError {
            lastError = error.localizedDescription
        } catch {
            lastError = "That file couldn't be read: \(error.localizedDescription)"
        }
    }

    func useBuiltInClient() {
        secrets.setGoogleClient(nil)
        refreshClientState()
    }

    func connectGmail(loginHint: String? = nil) {
        signInTask?.cancel()
        lastError = nil
        isSigningIn = true
        let authorizer = authorizer
        signInTask = Task {
            defer { isSigningIn = false }
            do {
                try loadAccountsIfNeeded()
                let signIn = try await authorizer.signIn(loginHint: loginHint) { url in
                    await MainActor.run { NSWorkspace.shared.open(url) }
                }
                var account: EmailAccount
                if let existing = accounts.first(where: { $0.address == signIn.address }) {
                    account = existing
                    account.sync.needsSignIn = false
                    account.sync.lastError = nil
                } else {
                    account = EmailAccount(id: UUID(), provider: .gmail, address: signIn.address,
                                           aliases: signIn.aliases, connectedAt: now())
                }
                account.aliases = signIn.aliases
                await authorizer.save(signIn.credentials, for: account.id)
                upsert(account)
                try saveAccounts()
                lokalbotLog("email gmail account connected accounts=\(accounts.count)")
                requestSync(account.id)
            } catch is CancellationError {
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func cancelSignIn() {
        signInTask?.cancel()
        Task { await authorizer.cancelSignIn() }
    }

    @discardableResult
    func disconnect(_ accountID: UUID) async -> Bool {
        if syncingAccountID == accountID {
            syncTask?.cancel()
        }
        manualRequests.remove(accountID)
        launchPending.remove(accountID)
        let tokens = await authorizer.forget(accountID)
        do {
            try loadAccountsIfNeeded()
            accounts.removeAll { $0.id == accountID }
            try openStore().deleteAccountData(accountID)
            try saveAccounts()
        } catch {
            lastError = "This account couldn't be removed completely: \(error.localizedDescription)"
        }
        mailRevision &+= 1
        var confirmed = true
        for token in tokens {
            if !(await authorizer.revoke(token: token)) { confirmed = false }
        }
        lokalbotLog("email account disconnected revoked=\(confirmed) accounts=\(accounts.count)")
        return confirmed
    }

    func requestSync(_ accountID: UUID? = nil) {
        if let accountID {
            manualRequests.insert(accountID)
        } else {
            manualRequests.formUnion(accounts.map(\.id))
        }
        tick()
    }

    func mailbox() -> EmailMailbox? {
        guard accountsLoaded, !accounts.isEmpty, let store = try? openStore() else { return nil }
        return EmailMailbox(store: store, accounts: accounts)
    }

    private func upsert(_ account: EmailAccount) {
        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[index] = account
        } else {
            accounts.append(account)
        }
    }

    func tick() {
        guard started, accountsLoaded, syncTask == nil, !accounts.isEmpty, canSync() else { return }
        let current = now()
        var meeting: Date??
        let nextMeeting: () -> Date? = {
            if let meeting { return meeting }
            let start = self.nextMeetingStart()
            meeting = .some(start)
            return start
        }
        var chosen: (EmailAccount, EmailSyncSchedule.Reason)?
        for account in accounts where !account.sync.needsSignIn {
            if manualRequests.contains(account.id) {
                chosen = (account, .manual)
                break
            }
            if let reason = EmailSyncSchedule.due(now: current, lastAttempt: account.sync.lastAttemptAt,
                                                  lastSuccess: account.sync.lastSuccessAt,
                                                  launched: launchPending.contains(account.id),
                                                  nextMeetingStart: nextMeeting, calendar: .current) {
                chosen = (account, reason)
                break
            }
        }
        guard let (account, reason) = chosen else { return }
        manualRequests.remove(account.id)
        launchPending.remove(account.id)
        sync(account, reason: reason)
    }

    private func sync(_ account: EmailAccount, reason: EmailSyncSchedule.Reason) {
        let store: EmailStore
        do {
            store = try openStore()
        } catch {
            lastError = "Email couldn't be opened: \(error.localizedDescription)"
            return
        }
        var attempted = account
        attempted.sync.lastAttemptAt = now()
        upsert(attempted)
        let attendees = attendeeAddresses()
        let syncer = GmailSyncer(client: authorizer.client(for: account), store: store, now: now())
        syncingAccountID = account.id
        lokalbotLog("email sync start reason=\(reason.rawValue)")
        syncTask = Task {
            var result = attempted
            do {
                result = try await syncer.sync(attempted, attendees: attendees)
                result.sync.lastSuccessAt = now()
                result.sync.lastError = nil
                lokalbotLog("email sync done threads=\(result.sync.threadCount) messages=\(result.sync.messageCount) "
                            + "people=\(result.sync.people.count) attendees=\(attendees.count) capped=\(result.sync.capped)")
            } catch is CancellationError {
                result.sync.lastError = nil
            } catch GmailError.signInRequired {
                result.sync.needsSignIn = true
                result.sync.lastError = GmailError.signInRequired(account.address).localizedDescription
            } catch {
                result.sync.lastError = error.localizedDescription
                lokalbotLog("email sync failed: \(type(of: error))")
            }
            finish(result)
        }
    }

    private func finish(_ result: EmailAccount) {
        syncTask = nil
        syncingAccountID = nil
        guard accounts.contains(where: { $0.id == result.id }) else {
            try? openStore().deleteAccountData(result.id)
            return
        }
        upsert(result)
        mailRevision &+= 1
        do {
            try saveAccounts()
        } catch {
            lastError = "Email sync state couldn't be saved: \(error.localizedDescription)"
        }
        tick()
    }
}

struct EmailMailbox: Sendable {
    let store: EmailStore
    let accounts: [EmailAccount]

    func sources() -> [EmailMeetingContext.Source] {
        var sources: [EmailMeetingContext.Source] = []
        for account in accounts {
            for thread in store.threads(accountID: account.id) {
                sources.append(EmailMeetingContext.Source(account: account, thread: thread))
            }
        }
        return sources
    }
}
