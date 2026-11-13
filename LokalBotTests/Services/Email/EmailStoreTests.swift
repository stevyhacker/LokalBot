import CryptoKit
import XCTest
@testable import LokalBot

final class EmailStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try GmailFixtures.temporaryRoot()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func thread(accountID: UUID, id: String = "18f3a9", subject: String = "Ugovor za jun") -> EmailThread {
        EmailThread(id: id, accountID: accountID, subject: subject, messages: [
            EmailMessage(id: "m1", internetMessageID: "<m1@x>", date: GmailFixtures.now,
                         from: EmailAddress(name: "Ana", address: "ana@x.com"),
                         to: [EmailAddress(name: nil, address: GmailFixtures.me)], cc: [],
                         subject: subject, fromMe: false, isBulk: false, body: "Šaljem nacrt ugovora.", attachments: []),
        ])
    }

    func testMailIsSealedOnDiskAndReadsBack() throws {
        let store = EmailStore(root: root, key: GmailFixtures.key())
        let accountID = UUID()
        var account = EmailAccount(id: accountID, provider: .gmail, address: GmailFixtures.me,
                                   aliases: [GmailFixtures.alias], connectedAt: GmailFixtures.now)
        account.sync.historyID = "42"
        try store.saveAccounts([account])
        try store.saveThread(thread(accountID: accountID))

        XCTAssertEqual(try store.loadAccounts(), [account])
        XCTAssertEqual(try store.thread(accountID: accountID, threadID: "18f3a9"), thread(accountID: accountID))
        XCTAssertTrue(EmailStore.hasAccounts(root: root))

        let files = try FileManager.default.subpathsOfDirectory(atPath: store.directory.path)
            .map { store.directory.appendingPathComponent($0) }
            .filter { !$0.hasDirectoryPath && $0.pathExtension == "enc" }
        XCTAssertEqual(files.count, 2)
        for file in files {
            let bytes = try Data(contentsOf: file)
            for secret in ["ana@x.com", "nacrt", "Ugovor", GmailFixtures.me] {
                XCTAssertNil(bytes.range(of: Data(secret.utf8)), "\(secret) in \(file.lastPathComponent)")
            }
            let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
            XCTAssertEqual(permissions, 0o600)
        }
    }

    func testAnotherKeyCannotReadIt() throws {
        let accountID = UUID()
        try EmailStore(root: root, key: GmailFixtures.key()).saveThread(thread(accountID: accountID))
        let other = EmailStore(root: root, key: GmailFixtures.key())
        XCTAssertThrowsError(try other.thread(accountID: accountID, threadID: "18f3a9"))
        XCTAssertEqual(other.threads(accountID: accountID), [], "an unreadable file is skipped, not fatal")
    }

    func testDeletingOneAccountKeepsTheOthers() throws {
        let store = EmailStore(root: root, key: GmailFixtures.key())
        let first = UUID()
        let second = UUID()
        try store.saveThread(thread(accountID: first))
        try store.saveThread(thread(accountID: second, id: "abc"))

        try store.deleteAccountData(first)

        XCTAssertEqual(store.threadIDs(accountID: first), [])
        XCTAssertEqual(store.threadIDs(accountID: second), ["abc"])
        try store.deleteAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.path))
    }

    func testNothingIsReadBeforeAnAccountExists() {
        XCTAssertFalse(EmailStore.hasAccounts(root: root))
    }
}
