import CryptoKit
import XCTest
@testable import LokalBot

/// A long dictation that finished after focus moved went to the clipboard, and
/// the next copy replaced it. Recent dictations keep it, across a restart too.
@MainActor
final class DictationHistoryTests: XCTestCase {
    private var root: URL!
    private let key = SymmetricKey(size: .bits256)

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func store(key: SymmetricKey? = nil) -> DictationHistoryStore {
        let key = key ?? self.key
        return DictationHistoryStore(root: root, encryptionKey: { key })
    }

    func testDictationsSurviveARestartEncryptedAndReadableOnlyByTheUser() throws {
        var history = DictationHistory()
        history.record("Check why the sync job retries forever", outcome: .copied, appName: "Ghostty")
        history.record("Thanks, I'll send it by Friday", outcome: .inserted, appName: "Slack")
        try store().save(history.entries)
        DictationHistoryStore.flush()

        let url = store().url
        XCTAssertNil(try Data(contentsOf: url).range(of: Data("sync job".utf8)), "saved in plain text")
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [DictationHistoryStore.fileName])
        XCTAssertEqual(store().load(), history)
    }

    func testAnotherKeyOrADamagedFileReadsAsEmpty() throws {
        var history = DictationHistory()
        history.record("Kept", outcome: .copied, appName: nil)
        try store().save(history.entries)
        DictationHistoryStore.flush()

        XCTAssertTrue(store(key: SymmetricKey(size: .bits256)).load().entries.isEmpty)
        try Data("not sealed".utf8).write(to: store().url)
        XCTAssertTrue(store().load().entries.isEmpty)
    }

    func testClearDeletesTheFile() throws {
        var history = DictationHistory()
        history.record("Kept", outcome: .copied, appName: nil)
        try store().save(history.entries)
        store().deleteAll()
        DictationHistoryStore.flush()

        XCTAssertFalse(FileManager.default.fileExists(atPath: store().url.path))
    }

    func testResultsOlderThanAWeekLeaveTheListAndTheFile() throws {
        let now = Date()
        let old = DictationHistoryEntry(
            id: UUID(), text: "Old", date: now.addingTimeInterval(-DictationHistory.maximumAge - 60),
            outcome: .copied, appName: nil)
        let recent = DictationHistoryEntry(
            id: UUID(), text: "Recent", date: now.addingTimeInterval(-60), outcome: .inserted, appName: nil)
        try store().save([recent, old])
        DictationHistoryStore.flush()

        XCTAssertEqual(store().load(now: now).entries, [recent])
        DictationHistoryStore.flush()
        // Read as of a time when the old one was still fresh: it is gone from the file.
        XCTAssertEqual(store().load(now: old.date).entries, [recent])

        let later = now.addingTimeInterval(DictationHistory.maximumAge)
        XCTAssertTrue(store().load(now: later).entries.isEmpty)
        DictationHistoryStore.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: store().url.path))
    }

    func testClipboardFallbacksAreKeptButPasswordFieldsAndCancellationsAreNot() {
        XCTAssertEqual(DictationHistory.outcome(for: .notDelivered(.focusMoved)), .copied)
        XCTAssertEqual(DictationHistory.outcome(for: .notDelivered(.selectionChanged)), .copied)
        XCTAssertEqual(DictationHistory.outcome(for: .notDelivered(.fieldUnreadable)), .copied)
        XCTAssertEqual(DictationHistory.outcome(for: .unconfirmed), .copied)
        XCTAssertEqual(DictationHistory.outcome(for: .failed), .copied)
        XCTAssertEqual(DictationHistory.outcome(for: .copied), .copied)
        XCTAssertEqual(DictationHistory.outcome(for: .inserted), .inserted)
        XCTAssertEqual(DictationHistory.outcome(for: .displayed), .shown)
        XCTAssertNil(DictationHistory.outcome(for: .notDelivered(.secureField)))
        XCTAssertNil(DictationHistory.outcome(for: .cancelled))
    }

    func testKeepsTheNewestFirstUpToTheLimit() {
        var history = DictationHistory()
        for index in 1...(DictationHistory.limit + 3) {
            history.record("Dictation \(index)", outcome: .copied, appName: nil)
        }

        XCTAssertEqual(history.entries.count, DictationHistory.limit)
        XCTAssertEqual(history.entries.first?.text, "Dictation \(DictationHistory.limit + 3)")
        XCTAssertEqual(history.entries.last?.text, "Dictation 4")
    }

    func testRepeatedTextMovesToTheTopInsteadOfRepeating() {
        var history = DictationHistory()
        history.record("First", outcome: .notInserted, appName: "Notes")
        history.record("Second", outcome: .inserted, appName: "Notes")
        history.record("First", outcome: .copied, appName: "Ghostty")

        XCTAssertEqual(history.entries.map(\.text), ["First", "Second"])
        XCTAssertEqual(history.entries.first?.outcome, .copied)
        XCTAssertEqual(history.entries.first?.appName, "Ghostty")
    }

    func testBlankTextIsNotKeptAndClearForgetsEverything() {
        var history = DictationHistory()
        history.record(" \n ", outcome: .copied, appName: nil)
        XCTAssertTrue(history.entries.isEmpty)

        history.record("Kept", outcome: .copied, appName: nil)
        history.removeAll()
        XCTAssertTrue(history.entries.isEmpty)
    }

    func testMenuTitleAndCaptionStayOnOneLine() {
        let entry = DictationHistoryEntry(
            id: UUID(), text: "Line one\nline two " + String(repeating: "word ", count: 30),
            date: Date(), outcome: .copied, appName: "Ghostty")

        XCTAssertTrue(entry.preview.hasPrefix("Line one line two word"))
        XCTAssertFalse(entry.menuTitle.contains("\n"))
        XCTAssertTrue(entry.menuTitle.hasSuffix("…"))
        let caption = entry.caption { $0 == "Copied to the clipboard" ? "Kopirano u privremenu memoriju" : $0 }
        XCTAssertTrue(caption.hasSuffix(" · Ghostty · Kopirano u privremenu memoriju"), caption)
    }
}
