import CryptoKit
import SQLite3
import XCTest
@testable import LokalBot

/// Every committed release fixture (0.6.2 … current) must survive today's
/// migration and library load with its approvals, schedules, search, and
/// encrypted data intact.
final class UpgradeMigrationTests: XCTestCase {
    private func fixtures() throws -> [URL] {
        let root = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "upgrade", withExtension: nil, subdirectory: "Fixtures"))
        let versions = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("manifest.json").path) }
        guard !versions.isEmpty else { throw XCTSkip("no upgrade fixtures committed yet") }
        return versions.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func copyLibrary(_ fixture: URL) throws -> URL {
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("upgrade-\(fixture.lastPathComponent)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.copyItem(at: fixture.appendingPathComponent("library"), to: target)
        return target
    }

    private func settings(_ fixture: URL) throws -> AppSettings {
        let plist = try XCTUnwrap(NSDictionary(contentsOf: fixture.appendingPathComponent("defaults.plist"))
                                    as? [String: Any])
        let data = try XCTUnwrap(plist[AppSettings.key] as? Data, "\(fixture.lastPathComponent): no settings blob")
        return try JSONDecoder().decode(AppSettings.self, from: data)
    }

    private func key(_ account: String) -> SymmetricKey {
        SymmetricKey(data: Data(SHA256.hash(data: Data("lokalbot-upgrade-fixture-\(account)".utf8))))
    }

    func testApprovalsAndSchedulesSurviveAndSchedulersWouldRun() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        for fixture in try fixtures() {
            let version = fixture.lastPathComponent
            let settings = try settings(fixture)
            XCTAssertTrue(settings.approvedRemoteInferenceOrigins.contains("https://openrouter.ai"), version)
            XCTAssertTrue(settings.allowsAutomaticMainInference,
                          "\(version): an approved remote server must allow scheduled runs (#113)")
            XCTAssertTrue(settings.dayDigestAutoEnabled, version)
            XCTAssertTrue(settings.dreamingEnabled, version)
            let due = calendar.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: settings.dayDigestHour, minute: 1))!
            XCTAssertTrue(DayDigestScheduler.shouldRun(at: due, hour: settings.dayDigestHour,
                                                       digestModifiedAt: nil, calendar: calendar), version)
        }
    }

    func testMeetingsStaySearchableWithoutStaleTombstones() throws {
        for fixture in try fixtures() {
            let version = fixture.lastPathComponent
            let root = try copyLibrary(fixture)
            defer { try? FileManager.default.removeItem(at: root) }
            let storage = StorageManager(rootURL: root)
            let meetings = storage.loadMeetings()
            XCTAssertFalse(meetings.isEmpty, version)
            let database = root.appendingPathComponent("lokalbotv3.sqlite")
            _ = SearchIndex.clearStaleTombstones(liveMeetingIDs: Set(meetings.map(\.id)), databaseURL: database)
            let index = SearchIndex(databaseURL: database)
            index.reindexAll(meetings, storage: storage)
            let hits = index.search("Redis")
            XCTAssertFalse(hits.isEmpty, "\(version): seeded meetings mention Redis")
            XCTAssertTrue(hits.allSatisfy { hit in meetings.contains { $0.id == hit.meetingID } }, version)
        }
    }

    /// Every release's chats (plain files from its seed, or sealed ones the
    /// app wrote) must still open with today's chat store.
    /// About you is sealed with the chat key, as each release wrote it.
    /// Releases before it have no file; the first fixture with one is the
    /// release after 0.10.7.
    @MainActor
    func testAboutYouFromEveryReleaseStillLoads() throws {
        var checked = 0
        for fixture in try fixtures() {
            let version = fixture.lastPathComponent
            let memory = fixture.appendingPathComponent("library/memory")
            let hasFile = ["personal-model.json.enc", "personal-model.json"].contains {
                FileManager.default.fileExists(atPath: memory.appendingPathComponent($0).path)
            }
            guard hasFile else { continue }
            let root = try copyLibrary(fixture)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = PersonalModelStore(root: root, encryptionKey: { self.key("chat-key") })
            let model = try store.load()
            XCTAssertFalse(model.claims.isEmpty, version)
            XCTAssertTrue(model.claims.allSatisfy { !$0.text.isEmpty }, version)
            let controller = PersonalModelController(store: store)
            XCTAssertNil(controller.loadError, version)
            XCTAssertTrue(controller.usableClaims().allSatisfy { $0.status == .confirmed }, version)
            XCTAssertTrue(controller.suggestions.allSatisfy { $0.status == .proposed }, version)
            checked += 1
        }
        if checked == 0 {
            throw XCTSkip("No release fixture has About you data yet; the first is the release after 0.10.7.")
        }
    }

    @MainActor
    func testChatsFromEveryReleaseStillLoad() throws {
        for fixture in try fixtures() {
            let version = fixture.lastPathComponent
            let root = try copyLibrary(fixture)
            defer { try? FileManager.default.removeItem(at: root) }
            let files = try FileManager.default.contentsOfDirectory(
                at: root.appendingPathComponent("chats"), includingPropertiesForKeys: nil)
                .filter { !$0.lastPathComponent.hasPrefix(".") }
            let report = ChatStore(rootURL: root, encryptionKey: { self.key("chat-key") }).loadAllReport()
            XCTAssertTrue(report.failures.isEmpty, "\(version): \(report.failures)")
            XCTAssertEqual(report.conversations.count, files.count, version)
        }
    }

    /// Runs the real migration (without its launch gate, which skips every
    /// test host) on each release's library, with the fixture's defaults and
    /// its synthetic keys in place of the Keychain.
    func testMigrationLeavesEveryReleaseReady() throws {
        for fixture in try fixtures() {
            let version = fixture.lastPathComponent
            let appSupport = FileManager.default.temporaryDirectory
                .appendingPathComponent("upgrade-support-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: appSupport) }
            let current = appSupport.appendingPathComponent("me.dotenv.LokalBot", isDirectory: true)
            try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: fixture.appendingPathComponent("library"), to: current)
            let suite = "me.dotenv.LokalBotTests.upgrade.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let plist = try XCTUnwrap(NSDictionary(contentsOf: fixture.appendingPathComponent("defaults.plist"))
                                        as? [String: Any])
            for (key, value) in plist { defaults.set(value, forKey: key) }
            try relocateScreenshotPaths(in: current)
            try sealSeededScreenshots(in: current)
            let secrets = DataMigration.SecretStore(
                read: { service, account in
                    guard service == "me.dotenv.LokalBot", ["screenshot-key", "chat-key"].contains(account) else {
                        return nil
                    }
                    return self.key(account).withUnsafeBytes { Data($0) }
                },
                write: { _, _, _ in })
            let meetingsBefore = StorageManager(rootURL: current).loadMeetings().count

            let outcome = DataMigration.migrate(appSupport: appSupport, currentDirectory: current,
                                                defaults: defaults, secrets: secrets)

            XCTAssertEqual(outcome, .ready, version)
            XCTAssertEqual(StorageManager(rootURL: current).loadMeetings().count, meetingsBefore, version)
        }
    }

    /// Each release wrote absolute screenshot paths under the folder it seeded
    /// on the CI runner. An in-place upgrade finds them under the library's
    /// own location, so point them at the copy before migrating.
    private func relocateScreenshotPaths(in library: URL) throws {
        var database: OpaquePointer?
        let url = library.appendingPathComponent("lokalbotv3.sqlite")
        guard sqlite3_open(url.path, &database) == SQLITE_OK else { throw XCTSkip("no database in \(url.path)") }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        sqlite3_prepare_v2(database, "SELECT path FROM screenshots WHERE path != '' LIMIT 1", -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return }
        let stored = String(cString: text)
        guard let range = stored.range(of: "/library/") else { return }
        let oldRoot = String(stored[..<range.lowerBound]) + "/library"
        let update = "UPDATE screenshots SET path = replace(path, '\(oldRoot)', '\(library.path)')"
        XCTAssertEqual(sqlite3_exec(database, update, nil, nil, nil), SQLITE_OK)
    }

    /// Seeds write plain demo images; every release from 0.6.2 on stores
    /// screenshots as `AES.GCM.seal(image, screenshot-key).combined`. Seal
    /// them the same way so key recovery sees what a release wrote.
    private func sealSeededScreenshots(in library: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open(library.appendingPathComponent("lokalbotv3.sqlite").path, &database) == SQLITE_OK else {
            return
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        sqlite3_prepare_v2(database, "SELECT path FROM screenshots WHERE path != ''", -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) {
            let file = URL(fileURLWithPath: String(cString: text))
            guard let plain = try? Data(contentsOf: file) else { continue }
            let sealed = try XCTUnwrap(AES.GCM.seal(plain, using: key("screenshot-key")).combined)
            try sealed.write(to: file, options: .atomic)
        }
    }
}
