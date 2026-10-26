import AppKit
import CryptoKit
import Foundation

/// When mail is checked. Checking is cheap (Gmail's change history), so it
/// runs often; nothing here runs a model.
enum EmailSyncSchedule {
    enum Reason: String, Equatable, Sendable {
        case firstSync = "first"
        case morning
        case launch
        case beforeMeeting = "before-meeting"
        case interval
        case manual
    }

    /// No two checks of one account closer than this, failures included.
    static let minimumGap: TimeInterval = 15 * 60
    static let interval: TimeInterval = 3 * 3_600
    /// Local hour after which the first check of the day counts as the morning one.
    static let morningHour = 6
    static let beforeMeetingLead: TimeInterval = 30 * 60

    /// `launched` is true until the first check after the app starts.
    /// `nextMeetingStart` is read only when it could matter.
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

/// Connected mail accounts for Settings and the background check. Mail is
/// read-only: there is no code path that sends, deletes, labels, or marks
/// anything read.
@MainActor
final class EmailController: ObservableObject {
    @Published private(set) var accounts: [EmailAccount] = []
    @Published private(set) var hasGoogleClient = false
    @Published private(set) var syncingAccountID: UUID?
    @Published private(set) var isSigningIn = false
    @Published var lastError: String?

    /// Calendar attendee addresses around now; their threads qualify.
    var attendeeAddresses: @MainActor () -> Set<String> = { [] }
    /// Start of the next meeting with attendees, for the pre-meeting check.
    var nextMeetingStart: @MainActor () -> Date? = { nil }
    /// False until the meeting library has loaded, whose attendees count too.
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
    /// Accounts not yet checked since launch.
    private var launchPending: Set<UUID> = []
    /// Saving is refused until the saved list was read, so an unreadable
    /// file is never replaced by a partial list.
    private var accountsLoaded = false
    private var started = false

    init(root: URL,
         secrets: EmailSecretStore = KeychainEmailSecretStore(),
         authorizer: GmailAuthorizer? = nil,
         keyProvider: @escaping @MainActor () throws -> SymmetricKey = { try EmailStore.liveKey() },
         now: @escaping () -> Date = Date.init) {
        self.root = root
        self.secrets = secrets
        self.authorizer = authorizer ?? GmailAuthorizer(secrets: secrets)
        self.keyProvider = keyProvider
        self.now = now
    }

    /// Loads saved accounts and starts the minute tick. Nothing touches the
    /// Keychain until an account was connected once.
    func start() {
        guard !started else { return }
        started = true
        hasGoogleClient = secrets.googleClient() != nil
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

    // MARK: Google client

    func importGoogleClient(from url: URL) {
        do {
            let client = try GoogleOAuthClient(json: Data(contentsOf: url))
            secrets.setGoogleClient(client)
            hasGoogleClient = true
            lastError = nil
        } catch let error as GmailError {
            lastError = error.localizedDescription
        } catch {
            lastError = "That file couldn't be read: \(error.localizedDescription)"
        }
    }

    // MARK: Accounts

    /// Signs in to Gmail and adds the account, or renews the sign-in of an
    /// account already connected under the same address.
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
                // Cancelled in LokalBot or in the browser.
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func cancelSignIn() {
        signInTask?.cancel()
        Task { await authorizer.cancelSignIn() }
    }

    /// Ends the account here first (tokens, downloaded mail, the account
    /// itself), then asks Google to revoke the access. Returns false when
    /// Google didn't confirm; nothing is left on this Mac either way.
    @discardableResult
    func disconnect(_ accountID: UUID) async -> Bool {
        if syncingAccountID == accountID {
            syncTask?.cancel()
        }
        manualRequests.remove(accountID)
        launchPending.remove(accountID)
        let token = await authorizer.forget(accountID)
        do {
            // An unreadable account list is never overwritten.
            try loadAccountsIfNeeded()
            accounts.removeAll { $0.id == accountID }
            try openStore().deleteAccountData(accountID)
            try saveAccounts()
        } catch {
            lastError = "This account couldn't be removed completely: \(error.localizedDescription)"
        }
        guard let token else { return true }
        let confirmed = await authorizer.revoke(token: token)
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

    private func upsert(_ account: EmailAccount) {
        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[index] = account
        } else {
            accounts.append(account)
        }
    }

    // MARK: Background check

    func tick() {
        guard started, accountsLoaded, syncTask == nil, !accounts.isEmpty, canSync() else { return }
        let current = now()
        // Read the calendar at most once a tick, and only if an account asks.
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
                lokalbotLog("email sync done threads=\(result.sync.threadCount) capped=\(result.sync.capped)")
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
        // A disconnect during the pass wins over its result, including any
        // thread it saved after the account's mail was deleted.
        guard accounts.contains(where: { $0.id == result.id }) else {
            try? openStore().deleteAccountData(result.id)
            return
        }
        upsert(result)
        do {
            try saveAccounts()
        } catch {
            lastError = "Email sync state couldn't be saved: \(error.localizedDescription)"
        }
        tick()
    }
}
