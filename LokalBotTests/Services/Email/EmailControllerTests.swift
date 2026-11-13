import CryptoKit
import XCTest
@testable import LokalBot

final class EmailSyncScheduleTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Belgrade")!
        return calendar
    }()

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    private func due(at now: Date, attempt: Date? = nil, success: Date? = nil, launched: Bool = false,
                     meeting: Date? = nil) -> EmailSyncSchedule.Reason? {
        EmailSyncSchedule.due(now: now, lastAttempt: attempt ?? success, lastSuccess: success, launched: launched,
                              nextMeetingStart: { meeting }, calendar: calendar)
    }

    func testEachLaunchChecksOnceUnlessJustChecked() {
        XCTAssertEqual(due(at: date(26, 10), success: date(26, 9), launched: true), .launch)
        XCTAssertNil(due(at: date(26, 10), success: date(26, 9, 50), launched: true))
    }

    func testTheCalendarIsReadOnlyWhenItCouldMatter() {
        var reads = 0
        _ = EmailSyncSchedule.due(now: date(26, 10), lastAttempt: date(26, 9, 55), lastSuccess: date(26, 9, 55),
                                  launched: false, nextMeetingStart: { reads += 1; return nil }, calendar: calendar)
        XCTAssertEqual(reads, 0)
    }

    func testFirstCheckRunsRightAway() {
        XCTAssertEqual(due(at: date(26, 10)), .firstSync)
    }

    func testChecksNeverRunCloserThanFifteenMinutes() {
        XCTAssertNil(due(at: date(26, 10, 14), attempt: date(26, 10), success: date(25, 10)))
        XCTAssertEqual(due(at: date(26, 10, 15), attempt: date(26, 10), success: date(25, 10)), .morning)
    }

    func testTheFirstCheckAfterSixIsTheMorningOne() {
        XCTAssertNil(due(at: date(26, 5, 59), success: date(26, 4)))
        XCTAssertEqual(due(at: date(26, 6, 30), success: date(26, 4)), .morning)
        XCTAssertNil(due(at: date(26, 7), success: date(26, 6, 30)))
    }

    func testMailIsCheckedAgainBeforeAMeeting() {
        XCTAssertEqual(due(at: date(26, 13, 35), success: date(26, 12), meeting: date(26, 14)), .beforeMeeting)
        XCTAssertNil(due(at: date(26, 13, 20), success: date(26, 12), meeting: date(26, 14)))
        XCTAssertNil(due(at: date(26, 13, 35), success: date(26, 13, 25), meeting: date(26, 14)))
    }

    func testOtherwiseEveryThreeHours() {
        XCTAssertNil(due(at: date(26, 10, 59), success: date(26, 8)))
        XCTAssertEqual(due(at: date(26, 11), success: date(26, 8)), .interval)
    }
}

@MainActor
final class EmailControllerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try GmailFixtures.temporaryRoot()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testStartingWithoutAccountsNeverAsksForTheKey() {
        let controller = EmailController(root: root, secrets: MemoryEmailSecrets(client: nil), builtInClient: nil,
                                         keyProvider: {
            XCTFail("the Keychain key is read only once an account exists")
            return GmailFixtures.key()
        })
        controller.start()
        defer { controller.stop() }

        XCTAssertEqual(controller.accounts, [])
        XCTAssertFalse(controller.hasGoogleClient)
    }

    func testDisconnectRevokesAndDeletesOnlyThatAccountsMail() async throws {
        let key = GmailFixtures.key()
        let store = EmailStore(root: root, key: key)
        let kept = EmailAccount(id: UUID(), provider: .gmail, address: "kept@example.com", aliases: [],
                                connectedAt: GmailFixtures.now)
        var removed = EmailAccount(id: UUID(), provider: .gmail, address: GmailFixtures.me, aliases: [],
                                   connectedAt: GmailFixtures.now)
        // Recent successes keep the background check from starting.
        removed.sync.lastSuccessAt = Date()
        var keptAccount = kept
        keptAccount.sync.lastSuccessAt = Date()
        try store.saveAccounts([keptAccount, removed])
        for account in [keptAccount, removed] {
            try store.saveThread(EmailThread(id: "t1", accountID: account.id, subject: "s", messages: []))
        }
        let secrets = MemoryEmailSecrets(credentials: [
            removed.id: EmailCredentials(accessToken: "a", refreshToken: "r", expiresAt: GmailFixtures.now,
                                         pendingRevocationTokens: ["old-r"]),
            kept.id: EmailCredentials(accessToken: "a2", refreshToken: "r2", expiresAt: GmailFixtures.now),
        ])
        let revoked = RevocationLog()
        let authorizer = GmailAuthorizer(secrets: secrets, transport: { request in
            revoked.append(GmailFixtures.form(request)["token"] ?? "")
            return (Data(), GmailFixtures.response(request, 200))
        })
        let controller = EmailController(root: root, secrets: secrets, authorizer: authorizer, keyProvider: { key })
        controller.start()
        defer { controller.stop() }
        XCTAssertEqual(controller.accounts.map(\.address), ["kept@example.com", GmailFixtures.me])

        let confirmed = await controller.disconnect(removed.id)

        XCTAssertTrue(confirmed)
        XCTAssertEqual(revoked.tokens, ["old-r", "r"])
        XCTAssertNil(try secrets.credentials(for: removed.id))
        XCTAssertNotNil(try secrets.credentials(for: kept.id))
        XCTAssertEqual(controller.accounts.map(\.id), [kept.id])
        XCTAssertEqual(try store.loadAccounts().map(\.id), [kept.id])
        XCTAssertEqual(store.threadIDs(accountID: removed.id), [])
        XCTAssertEqual(store.threadIDs(accountID: kept.id), ["t1"])
    }

    func testAnUnreadableAccountListIsNeverOverwritten() async throws {
        let store = EmailStore(root: root, key: GmailFixtures.key())
        try store.saveAccounts([EmailAccount(id: UUID(), provider: .gmail, address: GmailFixtures.me, aliases: [],
                                             connectedAt: GmailFixtures.now)])
        let url = EmailStore.accountsURL(root: root)
        let before = try Data(contentsOf: url)
        // Another key, as when the Keychain item can't be read as saved.
        let controller = EmailController(root: root, secrets: MemoryEmailSecrets(), keyProvider: { GmailFixtures.key() })
        controller.start()
        defer { controller.stop() }

        XCTAssertNotNil(controller.lastError)
        await controller.disconnect(UUID())

        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testNothingSyncsBeforeTheLibraryIsReady() throws {
        let key = GmailFixtures.key()
        try EmailStore(root: root, key: key).saveAccounts([EmailAccount(
            id: UUID(), provider: .gmail, address: GmailFixtures.me, aliases: [], connectedAt: GmailFixtures.now)])
        let controller = EmailController(root: root, secrets: MemoryEmailSecrets(), keyProvider: { key })
        controller.canSync = { false }
        controller.start()
        defer { controller.stop() }
        XCTAssertNil(controller.syncingAccountID)
        XCTAssertNil(controller.accounts.first?.sync.lastAttemptAt)
    }

    func testLokalBotsClientIsReadyWithoutAnyFile() {
        let secrets = MemoryEmailSecrets(client: nil)
        let controller = EmailController(root: root, secrets: secrets, builtInClient: GmailOAuthTests.builtIn,
                                         keyProvider: { GmailFixtures.key() })
        XCTAssertTrue(controller.hasGoogleClient)
        XCTAssertTrue(controller.hasBuiltInClient)
        XCTAssertFalse(controller.usesOwnClient)

        secrets.setGoogleClient(GmailFixtures.client)
        controller.useBuiltInClient()
        XCTAssertNil(secrets.googleClient())
        XCTAssertFalse(controller.usesOwnClient)
        XCTAssertTrue(controller.hasGoogleClient)
    }

    func testImportingAClientFileReportsWhatIsWrong() throws {
        let secrets = MemoryEmailSecrets(client: nil)
        let controller = EmailController(root: root, secrets: secrets, builtInClient: nil,
                                         keyProvider: { GmailFixtures.key() })
        let web = root.appendingPathComponent("web.json")
        try GmailFixtures.json(["web": ["client_id": "x.apps.googleusercontent.com", "client_secret": "s"]])
            .write(to: web)
        controller.importGoogleClient(from: web)
        XCTAssertFalse(controller.hasGoogleClient)
        XCTAssertEqual(controller.lastError,
                       "This is a web application client. Create an OAuth client of type Desktop app instead.")

        let desktop = root.appendingPathComponent("desktop.json")
        try GmailFixtures.json(["installed": ["client_id": "x.apps.googleusercontent.com", "client_secret": "s"]])
            .write(to: desktop)
        controller.importGoogleClient(from: desktop)
        XCTAssertTrue(controller.hasGoogleClient)
        XCTAssertTrue(controller.usesOwnClient)
        XCTAssertNil(controller.lastError)
        XCTAssertEqual(secrets.googleClient()?.clientID, "x.apps.googleusercontent.com")
    }

    final class RevocationLog: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        var tokens: [String] { lock.withLock { stored } }
        func append(_ token: String) { lock.withLock { stored.append(token) } }
    }
}
