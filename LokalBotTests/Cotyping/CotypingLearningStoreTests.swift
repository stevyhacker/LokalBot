import AppKit
import CryptoKit
import XCTest
@testable import LokalBot

// MARK: - Local learning

final class CotypingLearningRankerTests: XCTestCase {
    private func field(
        preceding: String,
        appName: String = "TextEdit",
        bundleID: String? = "com.apple.TextEdit",
        windowTitle: String? = nil
    ) -> CotypingField {
        CotypingField(
            appName: appName, bundleID: bundleID, processID: 1, role: "AXTextArea",
            precedingText: preceding, trailingText: "", selectionLength: 0,
            caretRect: .zero, isSecure: false, caretIsExact: true,
            windowTitle: windowTitle, learningScopeKey: "document-a")
    }

    func testSanitizesAcceptedText() {
        XCTAssertEqual(
            CotypingLearningRanker.acceptedText("  thanks\u{0000}\nagain  "),
            "thanks again")
        XCTAssertNil(CotypingLearningRanker.acceptedText("ok"))
    }

    func testDoesNotLearnPromptScaffolding() {
        XCTAssertNil(CotypingLearningRanker.acceptedText("On the clipboard: secret release plan"))
        XCTAssertNil(CotypingLearningRanker.acceptedText("Previously accepted completion: send it tomorrow"))
        XCTAssertNil(CotypingLearningRanker.acceptedText("System prompt: continue the user's text"))
    }

    func testDoesNotLearnInSecureFieldsOrTerminals() {
        var secure = field(preceding: "password")
        secure.isSecure = true
        XCTAssertFalse(CotypingLearningRanker.canLearn(from: secure))
        XCTAssertFalse(CotypingLearningRanker.canLearn(from: field(
            preceding: "ls",
            appName: "Terminal",
            bundleID: "com.apple.Terminal")))
    }

    func testRankingPrefersSameBundleAndPrefixOverlap() {
        let now = Date()
        let examples = [
            CotypingLearningExample(
                id: UUID(), createdAt: now.addingTimeInterval(-30),
                appName: "Slack", bundleID: "com.tinyspeck.slackmacgap",
                surfaceClass: "chat", contextHint: nil,
                prefixTail: "quick follow up from yesterday",
                acceptedText: "sounds good to me", scopeKey: "document-a"),
            CotypingLearningExample(
                id: UUID(), createdAt: now.addingTimeInterval(-60),
                appName: "TextEdit", bundleID: "com.apple.TextEdit",
                surfaceClass: "email", contextHint: nil,
                prefixTail: "quick follow up on the contract",
                acceptedText: "I can send the final version today", scopeKey: "document-a"),
        ]

        let ranked = CotypingLearningRanker.rankedExamples(
            examples,
            for: field(preceding: "quick follow up"),
            limit: 1)

        XCTAssertEqual(ranked, ["I can send the final version today"])
    }

    func testRankingDropsWeaklyRelatedExamples() {
        let examples = [
            CotypingLearningExample(
                id: UUID(), createdAt: Date(),
                appName: "Slack", bundleID: "com.tinyspeck.slackmacgap",
                surfaceClass: "chat", contextHint: nil,
                prefixTail: "unrelated thread about dinner",
                acceptedText: "sounds good to me", scopeKey: "document-a"),
        ]

        let ranked = CotypingLearningRanker.rankedExamples(
            examples,
            for: field(preceding: "quick follow up"),
            limit: 1)

        XCTAssertEqual(ranked, [])
    }

    func testRankingQuarantinesPreviouslyPersistedPromptLeak() {
        let examples = [
            CotypingLearningExample(
                id: UUID(), createdAt: Date(),
                appName: "TextEdit", bundleID: "com.apple.TextEdit",
                surfaceClass: "email", contextHint: nil,
                prefixTail: "quick follow up",
                acceptedText: "On the clipboard: secret release plan", scopeKey: "document-a"),
            CotypingLearningExample(
                id: UUID(), createdAt: Date().addingTimeInterval(-1),
                appName: "TextEdit", bundleID: "com.apple.TextEdit",
                surfaceClass: "email", contextHint: nil,
                prefixTail: "quick follow up",
                acceptedText: "I can send the final version today", scopeKey: "document-a"),
        ]

        let ranked = CotypingLearningRanker.rankedExamples(
            examples,
            for: field(preceding: "quick follow up"),
            limit: 2)

        XCTAssertEqual(ranked, ["I can send the final version today"])
    }

    func testRankingUsesContextAndDeduplicates() {
        let now = Date()
        let examples = [
            CotypingLearningExample(
                id: UUID(), createdAt: now.addingTimeInterval(-10),
                appName: "TextEdit", bundleID: "com.apple.TextEdit",
                surfaceClass: "email", contextHint: nil,
                prefixTail: "quick follow up",
                acceptedText: "I can send the final version today", scopeKey: "document-a"),
            CotypingLearningExample(
                id: UUID(), createdAt: now.addingTimeInterval(-20),
                appName: "TextEdit", bundleID: "com.apple.TextEdit",
                surfaceClass: "email",
                contextHint: "An email being written in Mail. The window is titled \"Q3 planning\".",
                prefixTail: "quick follow up",
                acceptedText: "I can send the final version today", scopeKey: "document-a"),
            CotypingLearningExample(
                id: UUID(), createdAt: now.addingTimeInterval(-30),
                appName: "TextEdit", bundleID: "com.apple.TextEdit",
                surfaceClass: "email",
                contextHint: "An email being written in Mail. The window is titled \"Q3 planning\".",
                prefixTail: "quick follow up",
                acceptedText: "I will follow up on the Q3 planning notes", scopeKey: "document-a"),
        ]

        let ranked = CotypingLearningRanker.rankedExamples(
            examples,
            for: field(preceding: "quick follow up", windowTitle: "Q3 planning"),
            limit: 3)

        XCTAssertEqual(ranked.first, "I can send the final version today")
        XCTAssertEqual(ranked.count, 2)
    }
}

final class CotypingAcceptedSuggestionBatchTests: XCTestCase {
    private func field(preceding: String = "Please send") -> CotypingField {
        CotypingField(
            appName: "TextEdit", bundleID: "com.apple.TextEdit", processID: 1,
            role: "AXTextArea", precedingText: preceding, trailingText: "",
            selectionLength: 0, caretRect: .zero, isSecure: false,
            caretIsExact: true, learningScopeKey: "document-a")
    }

    func testAggregatesAcceptedChunksIntoOneLearningRecord() {
        var batch = CotypingAcceptedSuggestionBatch()

        batch.append(field: field(), acceptedText: " the", learningEnabled: true)
        batch.append(field: field(preceding: "Please send the"),
                     acceptedText: " final version", learningEnabled: true)
        let completion = batch.complete()

        XCTAssertEqual(completion?.acceptedChunkCount, 2)
        XCTAssertEqual(completion?.learningRecord?.field.precedingText, "Please send")
        XCTAssertEqual(completion?.learningRecord?.acceptedText, " the final version")
        XCTAssertTrue(batch.isEmpty)
        XCTAssertNil(batch.complete(), "a completed batch must not flush twice")
    }

    func testTracksStatsBoundaryWithoutLearningWhenDisabled() {
        var batch = CotypingAcceptedSuggestionBatch()
        batch.append(field: field(), acceptedText: " this", learningEnabled: false)

        let completion = batch.complete()

        XCTAssertEqual(completion?.acceptedChunkCount, 1)
        XCTAssertNil(completion?.learningRecord)
    }

    func testDiscardLearningPreservesPendingStatsBoundary() {
        var batch = CotypingAcceptedSuggestionBatch()
        batch.append(field: field(), acceptedText: " private text", learningEnabled: true)

        batch.discardLearningRecord()
        let completion = batch.complete()

        XCTAssertEqual(completion?.acceptedChunkCount, 1)
        XCTAssertNil(completion?.learningRecord)
    }
}

final class CotypingLearningStorePersistenceTests: XCTestCase {
    private func field() -> CotypingField {
        CotypingField(
            appName: "TextEdit", bundleID: "com.apple.TextEdit", processID: 1,
            role: "AXTextArea", precedingText: "Please send", trailingText: "",
            selectionLength: 0, caretRect: .zero, isSecure: false,
            caretIsExact: true, learningScopeKey: "document-a")
    }

    @MainActor
    func testCompletedSuggestionQueuesOneSnapshotWrite() async throws {
        let persistence = RecordingCotypingLearningPersistence()
        let store = CotypingLearningStore(
            storageRoot: FileManager.default.temporaryDirectory,
            persistence: persistence,
            initialSnapshot: .init())

        var batch = CotypingAcceptedSuggestionBatch()
        batch.append(field: field(), acceptedText: " the", learningEnabled: true)
        batch.append(field: field(), acceptedText: " final version", learningEnabled: true)
        let completion = try XCTUnwrap(batch.complete())
        let record = try XCTUnwrap(completion.learningRecord)
        store.recordCompletedSuggestion(field: record.field, acceptedText: record.acceptedText)
        await store.waitForPendingPersistence()

        let snapshots = await persistence.recordedSnapshots()
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots[0].examples.count, 1)
        XCTAssertEqual(snapshots[0].examples[0].acceptedText, "the final version")
        XCTAssertEqual(store.exampleCount, 1)
    }

    @MainActor
    func testTerminationFlushWaitsForQueuedLearningWrite() async {
        let persistence = RecordingCotypingLearningPersistence()
        let store = CotypingLearningStore(
            storageRoot: FileManager.default.temporaryDirectory,
            persistence: persistence,
            initialSnapshot: .init())
        store.recordCompletedSuggestion(field: field(), acceptedText: "the final version")

        await store.flushPersistence()

        let snapshots = await persistence.recordedSnapshots()
        XCTAssertEqual(snapshots.count, 1)
    }

    func testEncryptedPersistenceKeepsLegacyCombinedAESGCMFormat() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cotyping-learning-codec-\(UUID().uuidString)", isDirectory: true)
        let url = root.appendingPathComponent("cotyping-learning.enc")
        defer { try? FileManager.default.removeItem(at: root) }
        let key = SymmetricKey(size: .bits256)
        let snapshot = CotypingLearningSnapshot(examples: [
            CotypingLearningExample(
                id: UUID(), createdAt: Date(timeIntervalSince1970: 123),
                appName: "TextEdit", bundleID: "com.apple.TextEdit", surfaceClass: "email",
                contextHint: "Q3 planning", prefixTail: "Please send",
                acceptedText: "the final version", scopeKey: "document-a"),
        ])
        let persistence = EncryptedCotypingLearningPersistence(url: url, key: key)

        await persistence.persist(snapshot)

        let encrypted = try Data(contentsOf: url)
        let sealed = try AES.GCM.SealedBox(combined: encrypted)
        let plaintext = try AES.GCM.open(sealed, using: key)
        XCTAssertEqual(try JSONDecoder().decode(CotypingLearningSnapshot.self, from: plaintext), snapshot)
    }
}

private actor RecordingCotypingLearningPersistence: CotypingLearningPersisting {
    private var snapshots: [CotypingLearningSnapshot] = []

    func persist(_ snapshot: CotypingLearningSnapshot) {
        snapshots.append(snapshot)
    }

    func forget() { snapshots = [] }

    func recordedSnapshots() -> [CotypingLearningSnapshot] { snapshots }
}

final class CotypingLearningScopeTests: XCTestCase {
    func testOnlyIdentifiedDocumentsReceiveScopeKeys() throws {
        let first = try XCTUnwrap(CotypingLearningScope.key(
            bundleID: "com.apple.Safari", documentURLString: "https://docs.google.com/document/d/first/edit?x=1#cursor"))
        XCTAssertEqual(first, CotypingLearningScope.key(
            bundleID: "com.apple.Safari", documentURLString: "https://docs.google.com/document/d/first/view"))
        XCTAssertNotEqual(first, CotypingLearningScope.key(
            bundleID: "com.apple.Safari", documentURLString: "https://docs.google.com/document/d/second/edit"))
        for url in ["https://mail.google.com/", "https://app.slack.com/client/channel", "https://example.com/document/d/first"] {
            XCTAssertNil(CotypingLearningScope.key(bundleID: "com.apple.Safari", documentURLString: url))
        }
        XCTAssertNil(CotypingLearningScope.key(bundleID: "com.apple.mail", documentURLString: "file:///tmp/message"))
        XCTAssertNil(CotypingLearningScope.key(bundleID: "com.apple.TextEdit", documentURLString: nil))
        XCTAssertNotNil(CotypingLearningScope.key(bundleID: "com.apple.TextEdit", documentURLString: "file:///tmp/document.rtf"))
        XCTAssertFalse(first.contains("first"))
    }
}

@MainActor
final class CotypingLearningPrivacyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000)

    private func field(scope: String? = "document-a", prefix: String = "renewal contract review") -> CotypingField {
        CotypingField(appName: "TextEdit", bundleID: "com.apple.TextEdit", processID: 1, role: "AXTextArea",
                      precedingText: prefix, trailingText: "", selectionLength: 0, caretRect: .zero,
                      isSecure: false, caretIsExact: true, learningScopeKey: scope)
    }

    private func example(scope: String? = "document-a", age: TimeInterval = 0) -> CotypingLearningExample {
        CotypingLearningExample(id: UUID(), createdAt: now.addingTimeInterval(-age), appName: "TextEdit",
                                bundleID: "com.apple.TextEdit", surfaceClass: "other", contextHint: nil,
                                prefixTail: "renewal contract review", acceptedText: "the confidential numbers", scopeKey: scope)
    }

    func testDifferentDocumentsMissingScopesIrrelevantPrefixesAndExpiredExamplesAbstain() {
        for target in [field(scope: "document-b"), field(scope: nil), field(prefix: "picnic dinner tomorrow")] {
            XCTAssertEqual(CotypingLearningRanker.rankedExamples([example()], for: target, limit: 5, now: now), [])
        }
        for saved in [example(scope: nil), example(age: 31 * 24 * 60 * 60)] {
            XCTAssertEqual(CotypingLearningRanker.rankedExamples([saved], for: field(), limit: 5, now: now), [])
        }
        var mail = field()
        mail.bundleID = "com.apple.mail"
        XCTAssertFalse(CotypingLearningRanker.canLearn(from: mail))
        mail.bundleID = "com.tinyspeck.slackmacgap"
        XCTAssertFalse(CotypingLearningRanker.canLearn(from: mail))
        XCTAssertEqual(CotypingLearningRanker.rankedExamples([example()], for: field(), limit: 5, now: now), ["the confidential numbers"])
    }

    func testLegacySnapshotDecodesButUnscopedExamplesArePruned() async throws {
        let encoder = JSONEncoder()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(example())) as? [String: Any])
        object.removeValue(forKey: "scopeKey")
        let legacy = try JSONDecoder().decode(CotypingLearningExample.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(legacy.scopeKey)
        let persistence = RecordingCotypingLearningPersistence()
        let current = now
        let store = CotypingLearningStore(storageRoot: FileManager.default.temporaryDirectory,
                                         persistence: persistence, initialSnapshot: .init(examples: [legacy, example(age: 31 * 86_400)]),
                                         now: { current })
        XCTAssertEqual(store.exampleCount, 0)
        await store.waitForPendingPersistence()
        let snapshots = await persistence.recordedSnapshots()
        XCTAssertEqual(snapshots.last?.examples, [])
    }

    func testForgetWaitsForOlderWriteAndBlocksNewLearningUntilDeletion() async throws {
        let persistence = BlockingCotypingLearningPersistence()
        let current = now
        let store = CotypingLearningStore(storageRoot: FileManager.default.temporaryDirectory,
                                         persistence: persistence, initialSnapshot: .init(), now: { current })
        store.recordCompletedSuggestion(field: field(), acceptedText: "the confidential numbers")
        await persistence.waitUntilWriting()
        let deletion = Task { try await store.forgetAll() }
        while !store.isForgetting { await Task.yield() }
        XCTAssertEqual(store.exampleCount, 0)
        store.recordCompletedSuggestion(field: field(), acceptedText: "another private completion")
        XCTAssertEqual(store.exampleCount, 0)
        await persistence.releaseWrite()
        try await deletion.value
        let events = await persistence.events
        XCTAssertEqual(events, ["write", "delete"])
    }

    func testForgetFailureIsReportedAndMemoryStaysEmpty() async {
        let persistence = BlockingCotypingLearningPersistence(failDeletion: true)
        let current = now
        let store = CotypingLearningStore(storageRoot: FileManager.default.temporaryDirectory,
                                         persistence: persistence, initialSnapshot: .init(examples: [example()]), now: { current })
        do { try await store.forgetAll(); XCTFail("expected deletion error") } catch { }
        XCTAssertEqual(store.exampleCount, 0)
        XCTAssertFalse(store.isForgetting)
    }

    func testEncryptedFileCanBeForgottenWithoutKeychainKey() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("learning-forget-\(UUID()).enc")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("synthetic encrypted fixture".utf8).write(to: url)
        let persistence = EncryptedCotypingLearningPersistence(url: url, key: nil)
        try await persistence.forget()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}

private actor BlockingCotypingLearningPersistence: CotypingLearningPersisting {
    private var writeContinuation: CheckedContinuation<Void, Never>?
    private let failDeletion: Bool
    private(set) var events: [String] = []

    init(failDeletion: Bool = false) { self.failDeletion = failDeletion }

    func persist(_ snapshot: CotypingLearningSnapshot) async {
        await withCheckedContinuation { writeContinuation = $0 }
        events.append("write")
    }

    func waitUntilWriting() async {
        while writeContinuation == nil { await Task.yield() }
    }

    func releaseWrite() {
        writeContinuation?.resume()
        writeContinuation = nil
    }

    func forget() throws {
        if failDeletion { throw NSError(domain: "test", code: 1) }
        events.append("delete")
    }
}
