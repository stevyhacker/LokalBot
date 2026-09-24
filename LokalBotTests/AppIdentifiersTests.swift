import CryptoKit
import Security
import XCTest
@testable import LokalBot

final class AppIdentifiersTests: XCTestCase {
    func testDevelopmentAndUITestHostsHaveSeparateLibraryAndSecretIdentities() {
        let parent = URL(fileURLWithPath: "/synthetic/Application Support", isDirectory: true)
        let release = AppDirectories.applicationSupport(for: .release, under: parent)
        let development = AppDirectories.applicationSupport(for: .development, under: parent)
        let uiTestHost = AppDirectories.applicationSupport(for: .uiTestHost, under: parent)

        XCTAssertEqual(release.lastPathComponent, "me.dotenv.LokalBot")
        XCTAssertEqual(development.lastPathComponent, "me.dotenv.LokalBot.dev")
        XCTAssertEqual(uiTestHost.lastPathComponent, "me.dotenv.LokalBot.uitesthost")
        XCTAssertEqual(Set([release, development, uiTestHost]).count, 3)
        XCTAssertNotEqual(AppIdentifiers.Identity.release.bundleID, AppIdentifiers.Identity.development.bundleID,
                          "KeychainSecrets must select the same isolated identity as library storage")
        XCTAssertEqual(AppDirectories.resolveLibraryRoot(applicationSupport: development, storageOverride: nil), development)
        XCTAssertNotEqual(AppDirectories.agentWorkspace(forLibraryRoot: release),
                          AppDirectories.agentWorkspace(forLibraryRoot: development))
    }

    func testExplicitFixtureRootWinsAndAgentWorkspaceIsASibling() {
        let support = URL(fileURLWithPath: "/synthetic/Application Support/me.dotenv.LokalBot.dev", isDirectory: true)
        let fixture = URL(fileURLWithPath: "/synthetic/fixtures/library", isDirectory: true)
        let resolved = AppDirectories.resolveLibraryRoot(applicationSupport: support, storageOverride: fixture.path)
        XCTAssertEqual(resolved, fixture)
        let workspace = AppDirectories.agentWorkspace(forLibraryRoot: resolved)
        XCTAssertEqual(workspace, fixture.deletingLastPathComponent()
            .appendingPathComponent("library.agent-workspace", isDirectory: true))
        XCTAssertFalse(workspace.path.hasPrefix(fixture.path + "/"))
        XCTAssertNotEqual(workspace, fixture)
        XCTAssertEqual(AppDirectories.resolveLibraryRoot(applicationSupport: support, storageOverride: ""), support)
    }

    func testEmbeddedHelperAndInstalledSymlinkUseEnclosingDevIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("LokalBot Dev.app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let helper = contents.appendingPathComponent("Helpers/lokalbot-cli")
        try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "me.dotenv.LokalBot.dev", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        try Data().write(to: helper)
        let symlink = root.appendingPathComponent("lokalbot-cli")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: helper)

        XCTAssertEqual(AppIdentifiers.identity(forExecutable: helper, bundleIdentifier: "me.dotenv.lokalbot-cli"), .development)
        XCTAssertEqual(AppIdentifiers.identity(forExecutable: symlink, bundleIdentifier: nil), .development)
        XCTAssertEqual(AppIdentifiers.identity(forExecutable: nil, bundleIdentifier: nil), .release)
        XCTAssertEqual(AppIdentifiers.identity(forExecutable: nil, bundleIdentifier: "me.dotenv.LokalBot.uitesthost"), .uiTestHost)
    }

    private final class FakeEncryptionKeyStore {
        var readStatuses: [OSStatus]
        var storedData: Data?
        var addStatus: OSStatus
        var persistsAddedData: Bool
        private(set) var addedData: Data?

        init(
            readStatuses: [OSStatus],
            storedData: Data? = nil,
            addStatus: OSStatus = errSecSuccess,
            persistsAddedData: Bool = true
        ) {
            self.readStatuses = readStatuses
            self.storedData = storedData
            self.addStatus = addStatus
            self.persistsAddedData = persistsAddedData
        }

        var operations: KeychainSecrets.EncryptionKeyOperations {
            .init(
                read: { [self] _, _ in
                    let status = readStatuses.isEmpty
                        ? (storedData == nil ? errSecItemNotFound : errSecSuccess)
                        : readStatuses.removeFirst()
                    return (status, status == errSecSuccess ? storedData : nil)
                },
                add: { [self] _, _, data in
                    addedData = data
                    if addStatus == errSecSuccess, persistsAddedData { storedData = data }
                    return addStatus
                })
        }
    }

    func testHostedUnitTestsUseProcessScopedLibraryAndDefaults() throws {
        guard UITestRuntime.isUnitTesting else {
            throw XCTSkip("requires the hosted LokalBot unit-test process")
        }
        let processID = String(ProcessInfo.processInfo.processIdentifier)
        let storageRoot = try XCTUnwrap(UITestRuntime.storageRoot)
        let defaultsSuite = try XCTUnwrap(UITestRuntime.defaultsSuiteName)

        XCTAssertTrue(storageRoot.hasSuffix("lokalbot-unit-tests-\(processID)"))
        XCTAssertEqual(defaultsSuite, "me.dotenv.LokalBot.unit-tests.\(processID)")
        XCTAssertNotEqual(
            URL(fileURLWithPath: storageRoot).standardizedFileURL,
            AppDirectories.applicationSupport.standardizedFileURL)
    }

    @MainActor
    func testUITestRuntimeFlagDoesNotSelectDeterministicEncryptionKeyInProductionTarget() throws {
        guard ProcessInfo.processInfo.environment["LOKALBOT_RUN_KEYCHAIN_TESTS"] == "1" else {
            throw XCTSkip("set LOKALBOT_RUN_KEYCHAIN_TESTS=1 to run the login-Keychain integration test")
        }
        let account = "production-key-regression-\(UUID().uuidString)"
        let deterministic = Data(SHA256.hash(data: Data("lokalbot-ui-test-\(account)".utf8)))
        let originalFlag = UserDefaults.standard.object(forKey: UITestRuntime.enabledKey)

        KeychainSecrets.delete(account: account)
        UserDefaults.standard.set(true, forKey: UITestRuntime.enabledKey)
        defer {
            if let originalFlag {
                UserDefaults.standard.set(originalFlag, forKey: UITestRuntime.enabledKey)
            } else {
                UserDefaults.standard.removeObject(forKey: UITestRuntime.enabledKey)
            }
            KeychainSecrets.delete(account: account)
        }

        let key = try KeychainSecrets.symmetricKey(account: account)
        let keyData = key.withUnsafeBytes { Data($0) }

        XCTAssertNotEqual(keyData, deterministic)
    }

    func testEncryptionKeyReadFailuresNeverWriteReplacementKeys() {
        for account in ["screenshot-key", "chat-key"] {
            let store = FakeEncryptionKeyStore(
                readStatuses: [errSecInteractionNotAllowed])

            XCTAssertThrowsError(
                try KeychainSecrets.resolveSymmetricKey(
                    account: account,
                    operations: store.operations)
            ) { error in
                XCTAssertEqual(
                    error as? KeychainSecrets.EncryptionKeyFailure,
                    .operation("read", account: account, status: errSecInteractionNotAllowed))
            }
            XCTAssertNil(store.addedData)
        }
    }

    func testEncryptionKeyRejectsInvalidExistingDataWithoutReplacingIt() {
        let store = FakeEncryptionKeyStore(
            readStatuses: [errSecSuccess],
            storedData: Data(repeating: 1, count: 16))

        XCTAssertThrowsError(
            try KeychainSecrets.resolveSymmetricKey(
                account: "chat-key",
                operations: store.operations)
        ) { error in
            XCTAssertEqual(
                error as? KeychainSecrets.EncryptionKeyFailure,
                .invalidData(account: "chat-key"))
        }
        XCTAssertNil(store.addedData)
    }

    func testEncryptionKeyPropagatesFirstWriteFailure() {
        let store = FakeEncryptionKeyStore(
            readStatuses: [errSecItemNotFound],
            addStatus: errSecNotAvailable)

        XCTAssertThrowsError(
            try KeychainSecrets.resolveSymmetricKey(
                account: "screenshot-key",
                operations: store.operations)
        ) { error in
            XCTAssertEqual(
                error as? KeychainSecrets.EncryptionKeyFailure,
                .operation("save", account: "screenshot-key", status: errSecNotAvailable))
        }
        XCTAssertNotNil(store.addedData)
    }

    func testEncryptionKeyVerifiesNewKeyBeforeReturningIt() throws {
        let store = FakeEncryptionKeyStore(
            readStatuses: [errSecItemNotFound, errSecSuccess])

        let key = try KeychainSecrets.resolveSymmetricKey(
            account: "chat-key",
            operations: store.operations)

        XCTAssertEqual(key.withUnsafeBytes { Data($0) }, store.addedData)
        XCTAssertEqual(store.storedData, store.addedData)
    }

    func testEncryptionKeyRejectsMismatchedDataAfterSaving() {
        let store = FakeEncryptionKeyStore(
            readStatuses: [errSecItemNotFound, errSecSuccess],
            storedData: Data(repeating: 3, count: 32),
            persistsAddedData: false)

        XCTAssertThrowsError(
            try KeychainSecrets.resolveSymmetricKey(
                account: "chat-key",
                operations: store.operations)
        ) { error in
            XCTAssertEqual(
                error as? KeychainSecrets.EncryptionKeyFailure,
                .verification(account: "chat-key"))
        }
    }

    func testEncryptionKeyUsesConcurrentWinnerWithoutOverwritingIt() throws {
        let winningData = Data(repeating: 7, count: 32)
        let store = FakeEncryptionKeyStore(
            readStatuses: [errSecItemNotFound, errSecSuccess],
            storedData: winningData,
            addStatus: errSecDuplicateItem)

        let key = try KeychainSecrets.resolveSymmetricKey(
            account: "screenshot-key",
            operations: store.operations)

        XCTAssertEqual(key.withUnsafeBytes { Data($0) }, winningData)
        XCTAssertNotEqual(store.addedData, winningData)
        XCTAssertEqual(store.storedData, winningData)
    }
}
