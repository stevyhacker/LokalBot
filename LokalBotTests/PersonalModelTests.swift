import CryptoKit
import XCTest
@testable import LokalBot

/// Phase 1 of the personal world model: "Remember …" parsing, the edit rules,
/// the encrypted store, the per-question selection, and how Ask uses them.
final class RememberIntentTests: XCTestCase {
    func testMatchesRequestsToRemember() {
        let cases: [(String, String)] = [
            ("Remember that Maya is my manager", "Maya is my manager"),
            ("remember: amounts in EUR", "Amounts in EUR"),
            ("remember:answer in bullets", "Answer in bullets"),
            ("Please remember that Atlas is the billing project.", "Atlas is the billing project."),
            ("please remember I prefer short answers", "I prefer short answers"),
            ("  Remember   I live in Belgrade  ", "I live in Belgrade"),
            ("Zapamti da je Maja moja menadžerka", "Je Maja moja menadžerka"),
            ("zapamti: odgovaraj na srpskom", "Odgovaraj na srpskom"),
            ("Molim te zapamti da živim u Beogradu", "Živim u Beogradu"),
            ("Запамти да је Маја мој менаџер", "Је Маја мој менаџер"),
        ]
        for (message, expected) in cases {
            XCTAssertEqual(RememberIntent.parse(message), expected, message)
        }
    }

    func testIgnoresQuestionsAndOtherMessages() {
        let messages = [
            "Do you remember what Maya said?",
            "Can you remember the pricing decision",
            "Remember when we moved the launch?",
            "remember what Maya said about Q3",
            "Remember who owns the budget",
            "remember how we fixed the build",
            "Remember whether we shipped",
            "Remember that?",
            "remember",
            "Remember:   ",
            "What did we decide in my last meeting?",
            "Remembering the offsite, what was the outcome",
            "Zapamti da li smo poslali ponudu",
            "zapamti kada smo pomerili lansiranje",
            "Запамти шта је Маја рекла",
            "Da li se sećaš šta smo odlučili",
        ]
        for message in messages {
            XCTAssertNil(RememberIntent.parse(message), message)
        }
    }

    func testSuggestedKindRecognizesObviousOpeningsOnly() {
        XCTAssertEqual(PersonalClaim.Kind.suggested(for: "I prefer bullet points"), .preference)
        XCTAssertEqual(PersonalClaim.Kind.suggested(for: "Answer in Serbian"), .preference)
        XCTAssertEqual(PersonalClaim.Kind.suggested(for: "My goal is 1,000 weekly users"), .goal)
        XCTAssertEqual(PersonalClaim.Kind.suggested(for: "I want to ship 1.0 this year"), .goal)
        XCTAssertEqual(PersonalClaim.Kind.suggested(for: "Maya is my manager"), .fact)
        // Principles are the person's call, never guessed.
        XCTAssertEqual(PersonalClaim.Kind.suggested(for: "I never work weekends"), .fact)
    }
}

final class PersonalModelEditTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    func testAddSanitizesAndRefusesEmptyLongAndSecretText() throws {
        var model = PersonalModel()
        let added = try model.add("  Maya   is my\u{0007}manager ", kind: .fact, origin: .added, now: now).get()
        XCTAssertEqual(added.text, "Maya is my manager")
        XCTAssertEqual(added.createdAt, now)

        XCTAssertEqual(model.add("   ", kind: .fact, origin: .added, now: now).failure, .empty)
        let long = String(repeating: "a", count: PersonalModel.maxCharacters + 1)
        XCTAssertEqual(model.add(long, kind: .fact, origin: .added, now: now).failure,
                       .tooLong(PersonalModel.maxCharacters + 1))
        XCTAssertEqual(model.add("My key is sk_live_abcdefghijklmnop1234", kind: .fact, origin: .added, now: now).failure,
                       .looksSecret)
        XCTAssertEqual(model.claims.count, 1)
    }

    func testDuplicateTextRefreshesInsteadOfAdding() throws {
        var model = PersonalModel()
        let first = try model.add("Maya is my manager.", kind: .fact, origin: .added, now: now).get()
        let later = now.addingTimeInterval(60)
        let again = try model.add("maya  IS my manager", kind: .preference, origin: .added, now: later).get()
        XCTAssertEqual(again.id, first.id)
        XCTAssertEqual(again.kind, .fact)
        XCTAssertEqual(model.claims.count, 1)
        XCTAssertEqual(model.claims[0].updatedAt, later)
    }

    func testFullModelRefusesNewClaimsButNeverEvicts() throws {
        var model = PersonalModel()
        for index in 0..<PersonalModel.maxClaims {
            _ = try model.add("Fact number \(index)", kind: .fact, origin: .added, now: now).get()
        }
        XCTAssertEqual(model.add("One more", kind: .fact, origin: .added, now: now).failure, .full)
        XCTAssertEqual(model.claims.count, PersonalModel.maxClaims)
        // A duplicate still refreshes when full.
        XCTAssertNoThrow(try model.add("Fact number 3", kind: .fact, origin: .added, now: now).get())
    }

    func testUpdateEditsKindTextAndMergesIntoDuplicates() throws {
        var model = PersonalModel()
        let maya = try model.add("Maya is my manager", kind: .fact, origin: .added, now: now).get()
        let dana = try model.add("Dana runs platform", kind: .fact, origin: .added, now: now).get()
        let edited = try model.update(id: dana.id, text: "Maya is my manager.", kind: .principle,
                                      alwaysUse: true, now: now).get()
        XCTAssertEqual(edited.id, dana.id)
        XCTAssertEqual(edited.kind, .principle)
        XCTAssertTrue(edited.alwaysUse)
        XCTAssertEqual(model.claims.map(\.id), [dana.id])
        XCTAssertFalse(model.claims.contains { $0.id == maya.id })
        XCTAssertEqual(model.update(id: UUID(), kind: .goal, now: now).failure, .notFound)
        XCTAssertEqual(model.update(id: dana.id, text: " ", now: now).failure, .empty)
    }

    func testRemoveAndMarkUsed() throws {
        var model = PersonalModel()
        let first = try model.add("First", kind: .fact, origin: .added, now: now).get()
        let second = try model.add("Second", kind: .fact, origin: .added, now: now).get()
        let used = now.addingTimeInterval(5)
        model.markUsed(ids: [second.id], at: used)
        XCTAssertNil(model.claims.first { $0.id == first.id }?.lastUsedAt)
        XCTAssertEqual(model.claims.first { $0.id == second.id }?.lastUsedAt, used)
        model.remove(ids: [first.id])
        XCTAssertEqual(model.claims.map(\.id), [second.id])
    }
}

@MainActor
final class PersonalModelStoreTests: XCTestCase {
    private var root: URL!
    private let key = SymmetricKey(data: Data(repeating: 0x5C, count: 32))
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersonalModelStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeStore(key: SymmetricKey? = nil) -> PersonalModelStore {
        let resolved = key ?? self.key
        return PersonalModelStore(root: root, encryptionKey: { resolved })
    }

    func testMissingFileLoadsEmpty() throws {
        XCTAssertEqual(try makeStore().load(), PersonalModel())
    }

    func testEncryptedRoundTripIsNotReadableAsPlaintext() throws {
        let store = makeStore()
        var model = PersonalModel()
        _ = model.add("Maya Chen is my manager", kind: .fact,
                      origin: .said(conversationID: UUID(), messageID: UUID()), now: now)
        try store.save(model)

        XCTAssertEqual(try store.load(), model)
        let raw = try Data(contentsOf: store.encryptedURL)
        XCTAssertNil(String(data: raw, encoding: .utf8)?.range(of: "Maya"))
        let permissions = try FileManager.default.attributesOfItem(atPath: store.encryptedURL.path)[.posixPermissions]
        XCTAssertEqual((permissions as? NSNumber)?.intValue, 0o600)
        XCTAssertThrowsError(try makeStore(key: SymmetricKey(size: .bits256)).load()) { error in
            XCTAssertEqual(error as? PersonalModelStore.LoadError, .unreadable)
        }
    }

    func testPlaintextSeedIsReadThenReplacedByEncryptedCopy() throws {
        let store = makeStore()
        var model = PersonalModel()
        _ = model.add("Amounts in EUR", kind: .preference, origin: .added, now: now)
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(model).write(to: store.plaintextURL)

        XCTAssertEqual(try store.load(), model)
        try store.save(model)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.plaintextURL.path))
        XCTAssertEqual(try store.load(), model)
    }

    func testUnreadableOrNewerFileIsNeverOverwritten() throws {
        let store = makeStore()
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        let garbage = Data("not sealed".utf8)
        try garbage.write(to: store.encryptedURL)

        let controller = PersonalModelController(store: store, now: { self.now })
        XCTAssertTrue(controller.currentClaims().isEmpty)
        XCTAssertNotNil(controller.loadError)
        XCTAssertEqual(controller.remember("Maya is my manager", origin: .added).failure, .unavailable)
        XCTAssertEqual(try Data(contentsOf: store.encryptedURL), garbage)

        var newer = PersonalModel()
        newer.version = PersonalModel.currentVersion + 1
        try store.save(newer)
        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(error as? PersonalModelStore.LoadError, .newerVersion(PersonalModel.currentVersion + 1))
        }
    }

    func testControllerPersistsEditsAndForgetAllRemovesFiles() throws {
        let store = makeStore()
        let controller = PersonalModelController(store: store, now: { self.now })
        let claim = try controller.remember("I prefer short answers", origin: .added).get()
        XCTAssertEqual(claim.kind, .preference)
        _ = controller.update(claim.id, alwaysUse: true)

        let reopened = PersonalModelController(store: store)
        XCTAssertEqual(reopened.currentClaims().map(\.id), [claim.id])
        XCTAssertEqual(reopened.claim(id: claim.id)?.alwaysUse, true)

        XCTAssertNoThrow(try reopened.forgetAll().get())
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.encryptedURL.path))
        XCTAssertTrue(PersonalModelController(store: store).currentClaims().isEmpty)
    }
}

final class PersonalContextBuilderTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_790_000_000)
    private let utc = TimeZone(identifier: "UTC")!

    private func claim(_ text: String, _ kind: PersonalClaim.Kind, minutes: Double,
                       alwaysUse: Bool = false) -> PersonalClaim {
        PersonalClaim(kind: kind, text: text, origin: .added, alwaysUse: alwaysUse,
                      createdAt: base.addingTimeInterval(minutes * 60))
    }

    func testEmptyModelAddsNothing() {
        XCTAssertEqual(PersonalContextBuilder.select(claims: [], question: "Anything"), .empty)
    }

    func testPriorityOrderAndRenderedBlock() {
        let oldFact = claim("Dana runs the platform team", .fact, minutes: 1)
        let budgetFact = claim("The Atlas budget is owned by finance", .fact, minutes: 2)
        let preference = claim("Answer in bullet points", .preference, minutes: 3)
        let pinned = claim("I live in Belgrade", .fact, minutes: 0, alwaysUse: true)
        let principle = claim("No work that requires relocating my family", .principle, minutes: 4)
        let goal = claim("Ship LokalBot 1.0 this year", .goal, minutes: 5)

        let selection = PersonalContextBuilder.select(
            claims: [oldFact, budgetFact, preference, pinned, principle, goal],
            question: "Who owns the Atlas budget?",
            timeZone: utc)

        XCTAssertEqual(selection.claims.map(\.id), [
            pinned.id, principle.id, preference.id, budgetFact.id, goal.id, oldFact.id,
        ])
        let lines = selection.block.components(separatedBy: "\n")
        XCTAssertEqual(lines.first, PersonalContextBuilder.header)
        XCTAssertEqual(lines.last, PersonalContextBuilder.footer)
        XCTAssertEqual(lines[1], "- [fact · 2026-09-21] I live in Belgrade")
        XCTAssertTrue(selection.block.contains("- [principle · 2026-09-21] No work that requires relocating my family"))
    }

    func testRecentTurnsAndDiacriticsCountAsMatches() {
        let older = claim("Đorđe leads the Niš office", .fact, minutes: 1)
        let newer = claim("Coffee with the design team on Fridays", .fact, minutes: 2)
        let selection = PersonalContextBuilder.select(
            claims: [older, newer],
            question: "What about him?",
            recentUserTurns: ["Who is Djordje? Something about the nis office"])
        XCTAssertEqual(selection.claims.first?.id, older.id)
    }

    func testBudgetSkipsClaimsThatDoNotFit() {
        let long = claim(String(repeating: "word ", count: 50), .fact, minutes: 3)
        let short = claim("Short fact", .fact, minutes: 1)
        let budget = PersonalContextBuilder.header.count + PersonalContextBuilder.footer.count + 60
        let selection = PersonalContextBuilder.select(claims: [long, short], question: "", budget: budget)
        XCTAssertEqual(selection.claims.map(\.id), [short.id])
        XCTAssertLessThanOrEqual(selection.block.count, budget)

        let none = PersonalContextBuilder.select(claims: [long], question: "", budget: 10)
        XCTAssertEqual(none, .empty)
    }
}

@MainActor
final class AskPersonalModelTests: XCTestCase {
    private var root: URL!
    private let key = SymmetricKey(data: Data(repeating: 0x3E, count: 32))

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskPersonalModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makePersonalModel() -> PersonalModelController {
        PersonalModelController(store: PersonalModelStore(root: root, encryptionKey: { [key] in key }))
    }

    private func makeModel(engine: RecordingChatEngine, personalModel: PersonalModelController,
                           enabled: Bool = true) -> ChatViewModel {
        ChatViewModel(
            makeEngine: { engine },
            tools: EmptyChatRunner(),
            store: ChatStore(rootURL: root, encryptionKey: { [key] in key }),
            personalModel: personalModel,
            askMemoryEnabled: { enabled })
    }

    func testRememberSavesWithoutModelAndStaysOutOfHistory() async throws {
        let engine = RecordingChatEngine(["Your manager is Maya."])
        let personal = makePersonalModel()
        let model = makeModel(engine: engine, personalModel: personal)

        model.send("Remember that Maya Chen is my manager")
        XCTAssertFalse(model.isResponding)
        XCTAssertTrue(engine.systems.isEmpty)
        let saved = try XCTUnwrap(personal.currentClaims().first)
        XCTAssertEqual(saved.text, "Maya Chen is my manager")
        let receipt = try XCTUnwrap(model.messages.last)
        XCTAssertEqual(receipt.role, .assistant)
        XCTAssertEqual(receipt.rememberReceipt?.claimID, saved.id)
        guard case .said(_, let messageID) = saved.origin else { return XCTFail("origin \(saved.origin)") }
        XCTAssertEqual(messageID, model.messages.first?.id)

        model.send("Who is my manager?")
        await waitUntil("answer did not complete") { !model.isResponding }
        let system = try XCTUnwrap(engine.systems.first)
        XCTAssertTrue(system.contains(PersonalContextBuilder.header))
        XCTAssertTrue(system.contains("Maya Chen is my manager"))
        XCTAssertFalse(engine.contexts.joined().contains("Remember that"))
        let answer = try XCTUnwrap(model.messages.last)
        XCTAssertEqual(answer.usedClaimIDs, [saved.id])
        XCTAssertNotNil(personal.claim(id: saved.id)?.lastUsedAt)
    }

    func testDateScopedRememberUsesVisibleTextAndAttachedScreenStaysAQuestion() async throws {
        let engine = RecordingChatEngine(["That page is the new pricing page."])
        let personal = makePersonalModel()
        let model = makeModel(engine: engine, personalModel: personal)

        model.send("About my work on Monday: Remember that Atlas is the billing project",
                   displayText: "Remember that Atlas is the billing project",
                   dateScope: AskDateScope(day: Date()))
        XCTAssertEqual(personal.currentClaims().map(\.text), ["Atlas is the billing project"])
        XCTAssertTrue(engine.systems.isEmpty)

        model.send("[screen excerpt] Remember that this is the pricing page",
                   displayText: "Remember that this is the pricing page",
                   attachedScreenIDs: [42])
        await waitUntil("screen question did not complete") { !model.isResponding }
        XCTAssertEqual(engine.systems.count, 1)
        XCTAssertEqual(personal.currentClaims().count, 1)
    }

    func testRefusedStatementShowsReasonAndSavesNothing() throws {
        let engine = RecordingChatEngine([])
        let personal = makePersonalModel()
        let model = makeModel(engine: engine, personalModel: personal)

        model.send("Remember: my key is sk_live_abcdefghijklmnop1234")
        XCTAssertTrue(engine.systems.isEmpty)
        XCTAssertTrue(personal.currentClaims().isEmpty)
        let receipt = try XCTUnwrap(model.messages.last)
        XCTAssertEqual(receipt.rememberReceipt, ChatMessage.RememberReceipt(claimID: nil))
        XCTAssertEqual(receipt.text, PersonalModel.EditError.looksSecret.localizedDescription)
    }

    func testScopedQuestionsStillGetStatedClaims() async throws {
        let personal = makePersonalModel()
        _ = personal.remember("Answer in bullet points", origin: .added)
        let engine = RecordingChatEngine(["- ok"])
        let model = makeModel(engine: engine, personalModel: personal)

        model.send("Summarize the pricing meeting", sourceScopes: [.meetings])
        await waitUntil("scoped answer did not complete") { !model.isResponding }
        XCTAssertTrue(engine.systems.joined().contains("Answer in bullet points"))
    }

    func testDisabledAskMemorySendsRememberAsQuestionAndAddsNoContext() async throws {
        let personal = makePersonalModel()
        _ = personal.remember("Answer in bullet points", origin: .added)
        let engine = RecordingChatEngine(["I can't save that."])
        let model = makeModel(engine: engine, personalModel: personal, enabled: false)

        model.send("Remember that Dana runs platform")
        await waitUntil("question did not complete") { !model.isResponding }
        XCTAssertEqual(engine.systems.count, 1)
        XCTAssertFalse(engine.systems.joined().contains(PersonalContextBuilder.header))
        XCTAssertEqual(personal.currentClaims().count, 1)
        XCTAssertNil(model.messages.last?.rememberReceipt)
        XCTAssertNil(model.messages.last?.usedClaimIDs)
    }

    func testReceiptAndUsedClaimsSurviveSaveAndLoad() throws {
        let claimID = UUID()
        let conversation = Conversation(messages: [
            ChatMessage(role: .user, text: "Remember I live in Belgrade"),
            ChatMessage(role: .assistant, text: "I live in Belgrade",
                        rememberReceipt: .init(claimID: claimID)),
            ChatMessage(role: .user, text: "Where do I live?"),
            ChatMessage(role: .assistant, text: "Belgrade.", usedClaimIDs: [claimID]),
        ])
        let store = ChatStore(rootURL: root, encryptionKey: { [key] in key })
        XCTAssertTrue(store.save(conversation))
        let loaded = try XCTUnwrap(store.loadAll().first)
        XCTAssertEqual(loaded.messages[1].rememberReceipt?.claimID, claimID)
        XCTAssertEqual(loaded.messages[3].usedClaimIDs, [claimID])
        XCTAssertNil(loaded.messages[3].rememberReceipt)
    }

    private func waitUntil(_ failureMessage: String, timeout: TimeInterval = 2,
                           condition: @escaping @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail(failureMessage)
    }
}

final class PersonalContextPromptTests: XCTestCase {
    func testPersonalContextSitsAfterLibraryAndBeforeWorkMemory() {
        let prompt = ChatPrompt.systemPrompt(
            tools: [], libraryOverview: "LIBRARY", personalContext: "ABOUT THE USER",
            workMemory: "WORK MEMORY")
        guard let library = prompt.range(of: "LIBRARY"),
              let personal = prompt.range(of: "ABOUT THE USER"),
              let work = prompt.range(of: "WORK MEMORY") else {
            return XCTFail("missing a prompt section")
        }
        XCTAssertLessThan(library.lowerBound, personal.lowerBound)
        XCTAssertLessThan(personal.lowerBound, work.lowerBound)

        let without = ChatPrompt.systemPrompt(tools: [], libraryOverview: "LIBRARY")
        XCTAssertFalse(without.contains("ABOUT THE USER"))
        XCTAssertEqual(without, ChatPrompt.systemPrompt(tools: [], libraryOverview: "LIBRARY", personalContext: ""))
    }
}

private final class RecordingChatEngine: TextEngine {
    private var outputs: [String]
    private(set) var systems: [String] = []
    private(set) var contexts: [String] = []

    init(_ outputs: [String]) {
        self.outputs = outputs
    }

    var displayName: String { "Recording chat test engine" }

    func generate(system: String, prompt: String, context: [String]) async throws -> String {
        systems.append(system)
        contexts.append(contentsOf: context)
        return outputs.isEmpty ? "" : outputs.removeFirst()
    }
}

private final class EmptyChatRunner: ChatToolRunner {
    let specs: [ChatToolSpec] = []
    func libraryOverview() -> String { "" }
    func run(_ call: ChatToolCall) async -> ChatToolResult {
        ChatToolResult(text: "", summary: "")
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
