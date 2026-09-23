import CryptoKit
import XCTest
@testable import LokalBot

/// Persistence for the Chat section's conversation history: the on-disk
/// round-trip through `ChatStore`, that the transient `isPending` flag is never
/// written (while `isError` and tool `activity` are), and that `loadAll`
/// returns conversations most-recently-updated first.
@MainActor
final class ChatStoreTests: XCTestCase {

    private var root: URL!
    private let encryptionKey = SymmetricKey(data: Data(repeating: 0xA5, count: 32))

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testSaveAndLoadRoundTrip() throws {
        let store = makeStore()
        let questionDate = Date(timeIntervalSince1970: 1_700_000_000)
        let answerDate = questionDate.addingTimeInterval(12)
        let dayScope = Date(timeIntervalSince1970: 1_699_920_000)
        let conversation = Conversation(
            title: "Pricing decision",
            messages: [
                ChatMessage(
                    role: .user,
                    text: "What did we decide on pricing?",
                    createdAt: questionDate,
                    sourceScopes: [.meetings],
                    dayScope: dayScope),
                ChatMessage(role: .assistant, text: "You chose tiered pricing.",
                            createdAt: answerDate,
                            activity: [.init(tool: "search_meetings", icon: "magnifyingglass",
                                             text: "Searched meetings", done: true)]),
            ])
        store.save(conversation)

        let loaded = store.loadAll()
        XCTAssertEqual(loaded.count, 1)
        let restored = try XCTUnwrap(loaded.first)
        XCTAssertEqual(restored.id, conversation.id)
        XCTAssertEqual(restored.title, "Pricing decision")
        XCTAssertEqual(restored.messages.map(\.text),
                       ["What did we decide on pricing?", "You chose tiered pricing."])
        XCTAssertEqual(restored.messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(restored.messages.map(\.createdAt), [questionDate, answerDate])
        XCTAssertEqual(restored.messages.first?.sourceScopes, [.meetings])
        XCTAssertEqual(restored.messages.first?.dayScopeKey, AskDayScope.key(for: dayScope))
        XCTAssertNil(restored.messages.last?.dayScopeKey)
        XCTAssertEqual(restored.messages.last?.activity.first?.tool, "search_meetings",
                       "tool activity chips should survive persistence")
    }

    func testIsPendingIsNeverPersistedButErrorIs() throws {
        let message = ChatMessage(role: .assistant, text: "partial answer",
                                  isPending: true, isError: true)
        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: data)
        XCTAssertFalse(decoded.isPending, "the in-flight flag must not survive a round-trip")
        XCTAssertTrue(decoded.isError, "the error flag must survive a round-trip")
        XCTAssertEqual(decoded.text, "partial answer")
        XCTAssertEqual(decoded.id, message.id, "a message's stable id must survive")
    }

    func testLoadAllSortsByUpdatedAtDescending() {
        let store = makeStore()
        store.save(Conversation(title: "older", updatedAt: Date(timeIntervalSince1970: 1_000),
                                messages: [ChatMessage(role: .user, text: "a")]))
        store.save(Conversation(title: "newer", updatedAt: Date(timeIntervalSince1970: 2_000),
                                messages: [ChatMessage(role: .user, text: "b")]))
        XCTAssertEqual(store.loadAll().map(\.title), ["newer", "older"])
    }

    func testDeleteRemovesConversationFromDisk() {
        let store = makeStore()
        let conversation = Conversation(title: "temp", messages: [ChatMessage(role: .user, text: "x")])
        store.save(conversation)
        XCTAssertEqual(store.loadAll().count, 1)
        store.delete(conversation.id)
        XCTAssertTrue(store.loadAll().isEmpty, "deleting must remove the conversation file")
    }

    func testFilesOnDiskAreEncrypted() throws {
        let store = makeStore()
        store.save(Conversation(title: "Secret pricing strategy",
                                messages: [ChatMessage(role: .user, text: "raise prices 20%")]))

        let chats = root.appendingPathComponent("chats", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: chats, includingPropertiesForKeys: nil)
        let encrypted = files.filter { $0.pathExtension == "enc" }
        XCTAssertEqual(encrypted.count, 1, "conversation should persist as a single sealed .enc file")

        let raw = try Data(contentsOf: try XCTUnwrap(encrypted.first))
        let asText = String(decoding: raw, as: UTF8.self)
        XCTAssertFalse(asText.contains("Secret pricing strategy"), "title must not be readable on disk")
        XCTAssertFalse(asText.contains("raise prices 20%"), "message must not be readable on disk")
        XCTAssertEqual(store.loadAll().first?.title, "Secret pricing strategy", "but it must decrypt back")
    }

    func testLegacyPlaintextIsMigratedToEncrypted() throws {
        let chats = root.appendingPathComponent("chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
        let conversationID = UUID()
        let firstMessageID = UUID()
        let secondMessageID = UUID()
        let legacyCreatedAt = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-08-01T09:00:00Z"))
        let legacyJSON = """
        {
          "id": "\(conversationID.uuidString)",
          "title": "legacy",
          "createdAt": "2026-08-01T09:00:00Z",
          "updatedAt": "2026-08-01T10:00:00Z",
          "messages": [
            {"id": "\(firstMessageID.uuidString)", "role": "user", "text": "old"},
            {"id": "\(secondMessageID.uuidString)", "role": "assistant", "text": "answer"}
          ]
        }
        """
        try Data(legacyJSON.utf8)
            .write(to: chats.appendingPathComponent("\(conversationID.uuidString).json"))

        let loaded = makeStore().loadAll()
        XCTAssertEqual(loaded.first?.title, "legacy", "legacy plaintext must still load")
        XCTAssertEqual(loaded.first?.messages.first?.createdAt, legacyCreatedAt,
                       "legacy turns should inherit the conversation creation time")
        XCTAssertEqual(
            loaded.first?.messages.last?.createdAt,
            legacyCreatedAt,
            "legacy turns should use only the known conversation-level date")
        XCTAssertNil(loaded.first?.messages.first?.dayScopeKey,
                     "legacy turns should decode without inventing a day scope")
        XCTAssertTrue(loaded.first?.messages.first?.createdAtIsEstimated == true,
                      "legacy turns must not present an invented exact timestamp")

        let files = try FileManager.default.contentsOfDirectory(at: chats, includingPropertiesForKeys: nil)
        XCTAssertTrue(files.contains { $0.pathExtension == "enc" }, "should have migrated to a sealed file")
        XCTAssertFalse(files.contains { $0.lastPathComponent == "\(conversationID.uuidString).json" },
                       "plaintext must be removed once the sealed copy exists")
    }

    func testLegacyTodayScopeMigratesWithoutInventingUnknownTurnDay() throws {
        let chats = root.appendingPathComponent("chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
        let conversationID = UUID()
        let legacyJSON = """
        {
          "id": "\(conversationID.uuidString)",
          "title": "legacy today",
          "createdAt": "2026-08-01T09:00:00Z",
          "updatedAt": "2026-08-01T10:00:00Z",
          "messages": [
            {"role": "user", "text": "today", "sourceScopes": ["Today"]},
            {"role": "assistant", "text": "answer", "sourceScopes": ["Today"], "isError": true}
          ]
        }
        """
        try Data(legacyJSON.utf8)
            .write(to: chats.appendingPathComponent("\(conversationID.uuidString).json"))

        let messages = try XCTUnwrap(makeStore().loadAll().first?.messages)

        XCTAssertEqual(Set(try XCTUnwrap(messages.first).sourceScopes), AskSourceScope.defaults)
        XCTAssertNil(messages.first?.dayScopeKey,
                     "an old turn has no trustworthy per-message civil day")
        XCTAssertNil(messages.last?.dayScopeKey)
        XCTAssertTrue(messages.allSatisfy(\.createdAtIsEstimated))

        let model = ChatViewModel(
            makeEngine: { SequencedChatEngine([]) },
            tools: BlockingChatRunner(),
            store: makeStore())
        XCTAssertFalse(model.canRetry(try XCTUnwrap(model.messages.last?.id)),
                       "an unrepresentable legacy Today scope must not be retried")
    }

    func testLegacyTodayInstantDoesNotGuessCivilDayWithoutOriginalTimeZone() throws {
        let chats = root.appendingPathComponent("chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
        let conversationID = UUID()
        let legacyJSON = """
        {
          "id": "\(conversationID.uuidString)",
          "title": "legacy today with timestamps",
          "createdAt": "2026-08-31T10:00:00Z",
          "updatedAt": "2026-08-31T10:01:00Z",
          "messages": [
            {
              "role": "user",
              "text": "today",
              "createdAt": "2026-08-31T10:00:00Z",
              "sourceScopes": ["Today"]
            },
            {
              "role": "assistant",
              "text": "old answer",
              "createdAt": "2026-08-31T10:01:00Z",
              "sourceScopes": ["Today"],
              "isError": true
            }
          ]
        }
        """
        try Data(legacyJSON.utf8)
            .write(to: chats.appendingPathComponent("\(conversationID.uuidString).json"))

        let store = makeStore()
        let messages = try XCTUnwrap(store.loadAll().first?.messages)

        XCTAssertFalse(messages.contains(where: \.createdAtIsEstimated))
        XCTAssertEqual(Set(try XCTUnwrap(messages.first).sourceScopes), AskSourceScope.defaults)
        XCTAssertTrue(messages.allSatisfy { $0.dayScopeKey == nil },
                      "an exact instant still lacks the original civil-day time zone")

        let model = ChatViewModel(
            makeEngine: { SequencedChatEngine([]) },
            tools: BlockingChatRunner(),
            store: store)
        XCTAssertFalse(model.canRetry(try XCTUnwrap(model.messages.last?.id)))
    }

    func testLegacyDefaultScopeDoesNotInventGlobalTodayFilter() throws {
        let chats = root.appendingPathComponent("chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
        let conversationID = UUID()
        let legacyJSON = """
        {
          "id": "\(conversationID.uuidString)",
          "title": "legacy default",
          "createdAt": "2026-08-01T09:00:00Z",
          "updatedAt": "2026-08-01T10:00:00Z",
          "messages": [
            {"role": "user", "text": "all", "sourceScopes": ["Meetings", "Today", "Screen"]},
            {"role": "assistant", "text": "answer", "sourceScopes": ["Meetings", "Today", "Screen"], "isError": true}
          ]
        }
        """
        try Data(legacyJSON.utf8)
            .write(to: chats.appendingPathComponent("\(conversationID.uuidString).json"))

        let messages = try XCTUnwrap(makeStore().loadAll().first?.messages)

        XCTAssertEqual(Set(try XCTUnwrap(messages.first).sourceScopes), AskSourceScope.defaults)
        XCTAssertNil(messages.first?.dayScopeKey)
        XCTAssertNil(messages.last?.dayScopeKey)

        let model = ChatViewModel(
            makeEngine: { SequencedChatEngine([]) },
            tools: BlockingChatRunner(),
            store: makeStore())
        XCTAssertFalse(model.canRetry(try XCTUnwrap(model.messages.last?.id)),
                       "legacy default had an unrepresentable Activity-day rule")
    }

    func testLegacyV1TurnsRequireFullHistoryScopeAndCannotRetry() throws {
        let chats = root.appendingPathComponent("chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
        let conversationID = UUID()
        let legacyJSON = """
        {
          "id": "\(conversationID.uuidString)",
          "title": "legacy pinned context",
          "createdAt": "2026-08-31T10:00:00Z",
          "updatedAt": "2026-08-31T10:03:00Z",
          "messages": [
            {
              "role": "user",
              "text": "What was on screen?",
              "createdAt": "2026-08-31T10:00:00Z",
              "sourceScopes": ["Meetings"]
            },
            {
              "role": "assistant",
              "text": "Legacy answer that may include pinned OCR",
              "createdAt": "2026-08-31T10:01:00Z",
              "sourceScopes": ["Meetings"]
            },
            {
              "role": "user",
              "text": "Try the old context again",
              "createdAt": "2026-08-31T10:02:00Z",
              "sourceScopes": ["Meetings"]
            },
            {
              "role": "assistant",
              "text": "old failure",
              "createdAt": "2026-08-31T10:03:00Z",
              "sourceScopes": ["Meetings"],
              "isError": true
            }
          ]
        }
        """
        try Data(legacyJSON.utf8)
            .write(to: chats.appendingPathComponent("\(conversationID.uuidString).json"))

        let store = makeStore()
        let messages = try XCTUnwrap(store.loadAll().first?.messages)
        let meetingsOnly = ChatViewModel.finalizedHistory(
            from: messages,
            allowedScopes: [.meetings])
        let fullScope = ChatViewModel.finalizedHistory(from: messages)

        XCTAssertTrue(meetingsOnly.isEmpty,
                      "unknown legacy attachments must not enter narrow history")
        XCTAssertEqual(fullScope.map(\.text), [
            "What was on screen?",
            "Legacy answer that may include pinned OCR",
        ])

        let model = ChatViewModel(
            makeEngine: { SequencedChatEngine([]) },
            tools: BlockingChatRunner(),
            store: store)
        XCTAssertFalse(model.canRetry(try XCTUnwrap(model.messages.last?.id)),
                       "v1 retry cannot reconstruct hidden pinned context")
    }

    func testLegacyDateEncodedDayScopeIsDiscardedAsTimezoneAmbiguous() throws {
        let chats = root.appendingPathComponent("chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
        let conversationID = UUID()
        let legacyJSON = """
        {
          "id": "\(conversationID.uuidString)",
          "title": "date migration",
          "createdAt": "2026-08-31T10:00:00Z",
          "updatedAt": "2026-08-31T10:00:00Z",
          "messages": [
            {
              "role": "user",
              "text": "scoped",
              "createdAt": "2026-08-31T10:00:00Z",
              "sourceScopes": ["Meetings"],
              "sourceScopeSchemaVersion": 2,
              "dayScope": "2026-08-31T10:00:00Z"
            },
            {
              "role": "assistant",
              "text": "old answer",
              "createdAt": "2026-08-31T10:01:00Z",
              "sourceScopes": ["Meetings"],
              "sourceScopeSchemaVersion": 2,
              "dayScope": "2026-08-31T10:00:00Z",
              "isError": true
            }
          ]
        }
        """
        try Data(legacyJSON.utf8)
            .write(to: chats.appendingPathComponent("\(conversationID.uuidString).json"))

        let store = makeStore()
        let messages = try XCTUnwrap(store.loadAll().first?.messages)

        XCTAssertTrue(messages.allSatisfy { $0.dayScopeKey == nil },
                      "an instant cannot recover its original civil-day time zone")
        XCTAssertTrue(store.loadAll().first?.messages.allSatisfy {
            $0.dayScopeKey == nil
        } == true, "the encrypted migration must remain stable on later loads")

        let model = ChatViewModel(
            makeEngine: { SequencedChatEngine([]) },
            tools: BlockingChatRunner(),
            store: store)
        XCTAssertFalse(model.canRetry(try XCTUnwrap(model.messages.last?.id)),
                       "an ambiguous legacy day must never retry without its boundary")
    }

    func testChatFailuresUseActionableUserFacingCopy() {
        let download = ChatViewModel.friendlyFailureMessage(
            for: ModelDownloadManager.PreparationError.failed("raw transport details"))
        XCTAssertTrue(download.contains("could not be downloaded"))
        XCTAssertTrue(download.contains("try again"))
        XCTAssertFalse(download.contains("raw transport details"))

        let remote = ChatViewModel.friendlyFailureMessage(
            for: TextEngineError.serverUnreachable(
                "http://127.0.0.1:11434",
                transportCode: nil))
        XCTAssertTrue(remote.contains("could not be reached"))
        XCTAssertFalse(remote.contains("127.0.0.1"))

        let unauthorized = ChatViewModel.friendlyFailureMessage(
            for: TextEngineError.httpStatus(
                code: 401, detail: "raw provider detail", retryAfter: nil))
        XCTAssertTrue(unauthorized.contains("API key"))
        XCTAssertFalse(unauthorized.contains("raw provider detail"))

        let rateLimited = ChatViewModel.friendlyFailureMessage(
            for: TextEngineError.httpStatus(
                code: 429, detail: "raw provider detail", retryAfter: 2))
        XCTAssertTrue(rateLimited.contains("rate-limited"))
        XCTAssertFalse(rateLimited.contains("raw provider detail"))
    }

    func testCompactConversationTitlesFavorTheQuestionSubject() {
        XCTAssertEqual(
            ChatViewModel.compactTitle(
                from: "give me the best tasks i should do today, i know there was more context"),
            "The best tasks I should do today")
        XCTAssertEqual(
            ChatViewModel.compactTitle(
                from: "give me a short task title and description for this task: "
                    + "Vault-provider research — quick comparison of providers"),
            "Vault-provider research — quick…")

        let conversation = Conversation(
            title: "give me a short task title and description for…",
            messages: [ChatMessage(
                role: .user,
                text: "give me a short task title and description for this task: "
                    + "Vault-provider research — quick comparison of providers")])
        XCTAssertEqual(
            ChatViewModel.displayTitle(for: conversation),
            "Vault-provider research — quick…")
    }

    func testTranscriptPresentationGroupsDatesAndRepeatedScopes() {
        let first = ChatMessage(
            role: .user,
            text: "First",
            createdAt: .distantPast,
            sourceScopes: [.meetings],
            createdAtIsEstimated: true)
        let second = ChatMessage(
            role: .user,
            text: "Second",
            createdAt: .distantPast,
            sourceScopes: [.meetings],
            createdAtIsEstimated: true)
        let changed = ChatMessage(
            role: .user,
            text: "Third",
            sourceScopes: [.screen])

        XCTAssertEqual(
            ChatTranscriptPresentation.dateDividerTitle(for: first, after: nil),
            "Earlier conversation")
        XCTAssertNil(ChatTranscriptPresentation.dateDividerTitle(for: second, after: first))
        XCTAssertTrue(ChatTranscriptPresentation.questionScopeChanged(first, after: nil))
        XCTAssertFalse(ChatTranscriptPresentation.questionScopeChanged(second, after: first))
        XCTAssertTrue(ChatTranscriptPresentation.questionScopeChanged(changed, after: second))
        XCTAssertTrue(ChatTranscriptPresentation.isLongQuestion(String(repeating: "x", count: 181)))
    }

    func testFinalizedHistoryExcludesFailedAndUnansweredPairs() {
        let messages = [
            ChatMessage(role: .user, text: "Completed question"),
            ChatMessage(role: .assistant, text: "Completed answer"),
            ChatMessage(role: .user, text: "Failed question"),
            ChatMessage(role: .assistant, text: "Could not answer", isError: true),
            ChatMessage(role: .user, text: "Pending question"),
            ChatMessage(role: .assistant, text: "", isPending: true),
        ]

        let history = ChatViewModel.finalizedHistory(from: messages)

        XCTAssertEqual(history, [
            .init(role: .user, text: "Completed question"),
            .init(role: .assistant, text: "Completed answer"),
        ])
    }

    func testFinalizedHistoryRespectsCurrentSourceAndDayScope() throws {
        let calendar = Calendar(identifier: .gregorian)
        let monday = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 31)))
        let tuesday = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: monday))
        let messages = [
            ChatMessage(
                role: .user,
                text: "Screen question",
                sourceScopes: [.screen],
                dayScope: monday),
            ChatMessage(role: .assistant, text: "Screen answer"),
            ChatMessage(
                role: .user,
                text: "Meeting question",
                sourceScopes: [.meetings],
                dayScope: monday),
            ChatMessage(role: .assistant, text: "Meeting answer"),
            ChatMessage(
                role: .user,
                text: "Another day",
                sourceScopes: [.meetings],
                dayScope: tuesday),
            ChatMessage(role: .assistant, text: "Another answer"),
            ChatMessage(
                role: .user,
                text: "Mixed attached day",
                sourceScopes: [.meetings, .screen],
                dayScope: monday,
                attachedScreenDayKeys: [AskDayScope.key(for: tuesday, calendar: calendar)]),
            ChatMessage(role: .assistant, text: "Mixed answer"),
        ]

        let history = ChatViewModel.finalizedHistory(
            from: messages,
            allowedScopes: [.meetings],
            dayScope: monday,
            calendar: calendar)

        XCTAssertEqual(history, [
            .init(role: .user, text: "Meeting question"),
            .init(role: .assistant, text: "Meeting answer"),
        ])
    }

    func testPersistedScreenAttachmentCannotRetryWithoutEphemeralOCR() throws {
        let store = makeStore()
        let failed = ChatMessage(role: .assistant, text: "failed", isError: true)
        store.save(Conversation(
            title: "Attachment",
            messages: [
                ChatMessage(
                    role: .user,
                    text: "What is this?",
                    sourceScopes: [.screen],
                    attachedScreenDayKeys: ["2026-09-01"]),
                failed,
            ]))
        let model = ChatViewModel(
            makeEngine: { SequencedChatEngine([]) },
            tools: BlockingChatRunner(),
            store: store)

        XCTAssertFalse(model.canRetry(failed.id))
    }

    func testScopedHistoryExcludesAttachedScreenFromAnotherDay() throws {
        let calendar = Calendar(identifier: .gregorian)
        let monday = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 31)))
        let tuesday = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: monday))
        let messages = [
            ChatMessage(
                role: .user,
                text: "Mixed-day question",
                sourceScopes: [.meetings, .screen],
                dayScope: monday,
                attachedScreenDayKeys: [AskDayScope.key(for: tuesday, calendar: calendar)]),
            ChatMessage(role: .assistant, text: "Mixed-day answer"),
        ]

        let history = ChatViewModel.finalizedHistory(
            from: messages,
            allowedScopes: [.meetings, .screen],
            dayScope: monday,
            calendar: calendar)

        XCTAssertTrue(history.isEmpty)
    }

    private func makeStore() -> ChatStore {
        ChatStore(rootURL: root, encryptionKey: { [encryptionKey] in encryptionKey })
    }
}

@MainActor
final class ChatViewModelStateTests: XCTestCase {
    private var root: URL!
    private let encryptionKey = SymmetricKey(data: Data(repeating: 0xC7, count: 32))

    func testExplicitNavigationEmitsWhenConversationIDDoesNotChange() {
        let model = makeModel(engine: SequencedChatEngine([]), runner: BlockingChatRunner())
        let id = model.currentID
        let revision = model.navigationRevision
        model.select(id)
        XCTAssertEqual(model.currentID, id)
        XCTAssertEqual(model.navigationRevision, revision + 1)
        model.newConversation()
        XCTAssertEqual(model.currentID, id)
        XCTAssertEqual(model.navigationRevision, revision + 2)
    }

    func testDeferredHistoryRestoresEncryptedConversation() async {
        let store = makeStore()
        let saved = Conversation(title: "Saved", messages: [ChatMessage(
            role: .user, text: "Private question", createdAt: Date(timeIntervalSince1970: 1_700_000_000))])
        store.save(saved)
        let model = ChatViewModel(makeEngine: { SequencedChatEngine([]) }, tools: BlockingChatRunner(),
                                  store: store, deferHistoryLoading: true)
        XCTAssertTrue(model.isLoadingHistory)
        XCTAssertTrue(model.messages.isEmpty)
        await model.waitForHistory()
        XCTAssertFalse(model.isLoadingHistory)
        XCTAssertEqual(model.currentID, saved.id)
        XCTAssertEqual(model.messages, saved.messages)
    }

    func testDeferredHistoryPreservesInteractionAndDeletion() async {
        let store = makeStore()
        let saved = Conversation(title: "Saved", messages: [ChatMessage(role: .user, text: "Old question")])
        store.save(saved)
        let model = ChatViewModel(makeEngine: { SequencedChatEngine([]) }, tools: BlockingChatRunner(),
                                  store: store, deferHistoryLoading: true)
        let initialID = model.currentID
        model.draft = "New question being typed"
        model.delete(saved.id)
        await model.waitForHistory()
        XCTAssertEqual(model.currentID, initialID)
        XCTAssertEqual(model.draft, "New question being typed")
        XCTAssertFalse(model.conversations.contains { $0.id == saved.id })
        XCTAssertTrue(store.loadAll().isEmpty)
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatViewModelStateTests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testStopFinalizesToolActivityAndKeepsLatestTurnRetryable() async throws {
        let dayScope = Date(timeIntervalSince1970: 1_775_000_000)
        let engine = SequencedChatEngine([
            #"{"tool":"search_meetings","arguments":{"query":"pricing"}}"#,
            "Recovered answer",
        ])
        let runner = BlockingChatRunner()
        let model = makeModel(engine: engine, runner: runner)

        model.send(
            "What changed?",
            sourceScopes: [.meetings],
            dayScope: dayScope)
        await waitUntil("tool activity did not start") {
            runner.started && model.messages.last?.activity.contains { !$0.done } == true
        }

        let interruptedID = try XCTUnwrap(model.messages.last?.id)
        model.stop()

        let stopped = try XCTUnwrap(model.messages.last)
        XCTAssertEqual(stopped.id, interruptedID)
        XCTAssertTrue(stopped.isError)
        XCTAssertFalse(stopped.isPending)
        XCTAssertFalse(stopped.activity.contains { !$0.done })
        XCTAssertTrue(stopped.activity.allSatisfy { $0.text.hasSuffix("— stopped") })
        XCTAssertFalse(model.isResponding, "stop should become terminal without provider cooperation")
        XCTAssertTrue(model.canRetry(interruptedID))

        model.retry(interruptedID)
        await waitUntil("retry did not complete") {
            !model.isResponding && model.messages.last?.text == "Recovered answer"
        }

        XCTAssertEqual(model.messages.count, 2, "retry should replace the latest failed pair")
        XCTAssertEqual(model.messages.first?.sourceScopes, [.meetings])
        XCTAssertEqual(model.messages.first?.dayScopeKey, AskDayScope.key(for: dayScope))
        XCTAssertEqual(model.messages.last?.dayScopeKey, AskDayScope.key(for: dayScope))
        XCTAssertFalse(model.messages.last?.isError ?? true)
    }

    func testHiddenRetryPayloadIsSupersededAndPurgedWithConversation() async throws {
        let engine = SequencedChatEngine([
            #"{"tool":"search_meetings","arguments":{"query":"first"}}"#,
            #"{"tool":"search_meetings","arguments":{"query":"second"}}"#,
        ])
        let runner = BlockingChatRunner()
        let model = makeModel(engine: engine, runner: runner)

        model.send(
            "Hidden OCR: confidential first screen",
            displayText: "What is shown?",
            sourceScopes: [.meetings],
            attachedScreenDates: [Date()])
        await waitUntil("first response did not reach its tool") { runner.started }
        let supersededID = try XCTUnwrap(model.messages.last?.id)
        model.stop()

        XCTAssertEqual(model.retainedRetryPayloadIDs, [supersededID])

        model.send(
            "Hidden OCR: confidential second screen",
            displayText: "What changed?",
            sourceScopes: [.meetings],
            attachedScreenDates: [Date()])
        let latestID = try XCTUnwrap(model.messages.last?.id)

        XCTAssertEqual(model.retainedRetryPayloadIDs, [latestID],
                       "a new question must discard superseded hidden context")

        model.delete(model.currentID)
        XCTAssertTrue(model.retainedRetryPayloadIDs.isEmpty,
                      "deleting a conversation must discard all hidden retry context")
    }

    func testDeletingNonCurrentConversationDoesNotStopCurrentResponse() async throws {
        let store = makeStore()
        let older = Conversation(
            title: "Older",
            updatedAt: Date(timeIntervalSince1970: 1_000),
            messages: [ChatMessage(role: .user, text: "old")])
        let current = Conversation(
            title: "Current",
            updatedAt: Date(timeIntervalSince1970: 2_000),
            messages: [
                ChatMessage(role: .user, text: "current question"),
                ChatMessage(role: .assistant, text: "current answer"),
            ])
        store.save(older)
        store.save(current)

        let engine = SequencedChatEngine([
            #"{"tool":"search_meetings","arguments":{"query":"active"}}"#,
        ])
        let runner = BlockingChatRunner()
        let model = makeModel(engine: engine, runner: runner, store: store)
        XCTAssertEqual(model.currentID, current.id)

        model.send("Keep working", sourceScopes: [.meetings])
        await waitUntil("current response did not reach its tool") { runner.started }

        model.delete(older.id)
        try? await Task.sleep(for: .milliseconds(30))

        XCTAssertTrue(model.isResponding)
        XCTAssertFalse(runner.sawCancellation)
        XCTAssertFalse(model.conversations.contains { $0.id == older.id })
        XCTAssertTrue(model.messages.last?.isPending ?? false)

        model.stop()
        await waitUntil("cleanup cancellation did not finish") { !model.isResponding }
    }

    func testStartingNewConversationPersistsInterruptedTurnAsTerminal() async throws {
        let engine = SequencedChatEngine([
            #"{"tool":"search_meetings","arguments":{"query":"handoff"}}"#,
        ])
        let runner = BlockingChatRunner()
        let model = makeModel(engine: engine, runner: runner)
        let interruptedConversationID = model.currentID

        model.send("Question before switching", sourceScopes: [.meetings])
        await waitUntil("response did not begin before conversation switch") { runner.started }
        model.newConversation()

        XCTAssertNotEqual(model.currentID, interruptedConversationID)
        XCTAssertTrue(model.messages.isEmpty)
        let interrupted = try XCTUnwrap(
            model.conversations.first { $0.id == interruptedConversationID })
        let terminal = try XCTUnwrap(interrupted.messages.last)
        XCTAssertTrue(terminal.isError)
        XCTAssertFalse(terminal.isPending)
        XCTAssertFalse(terminal.activity.contains { !$0.done })

        await waitUntil("interrupted response did not unwind") { !model.isResponding }
        model.select(interruptedConversationID)
        let restoredTerminalID = try XCTUnwrap(model.messages.last?.id)
        XCTAssertTrue(model.canRetry(restoredTerminalID))
    }

    func testOnlyLatestFailedAssistantTurnCanRetry() throws {
        let store = makeStore()
        let historicalFailure = ChatMessage(
            role: .assistant,
            text: "Earlier failure",
            isError: true)
        let latestFailure = ChatMessage(
            role: .assistant,
            text: "Latest failure",
            isError: true)
        let conversation = Conversation(
            title: "Retry ordering",
            messages: [
                ChatMessage(role: .user, text: "First question"),
                historicalFailure,
                ChatMessage(role: .user, text: "Second question"),
                latestFailure,
            ])
        store.save(conversation)
        let model = makeModel(
            engine: SequencedChatEngine([]),
            runner: BlockingChatRunner(),
            store: store)

        XCTAssertFalse(model.canRetry(historicalFailure.id),
                       "retrying an older failure would rewrite conversation chronology")
        XCTAssertTrue(model.canRetry(latestFailure.id))
    }

    func testSelectingHistoryDoesNotRewriteRecencyOrder() {
        let store = makeStore()
        let older = Conversation(
            title: "Older",
            updatedAt: Date(timeIntervalSince1970: 1_000),
            messages: [ChatMessage(role: .user, text: "old")])
        let newer = Conversation(
            title: "Newer",
            updatedAt: Date(timeIntervalSince1970: 2_000),
            messages: [ChatMessage(role: .user, text: "new")])
        store.save(older)
        store.save(newer)
        let model = makeModel(
            engine: SequencedChatEngine([]),
            runner: BlockingChatRunner(),
            store: store)

        model.select(older.id)

        XCTAssertEqual(model.currentID, older.id)
        XCTAssertEqual(model.conversations.map(\.id), [newer.id, older.id])
        XCTAssertEqual(model.conversations.first?.updatedAt, newer.updatedAt)
    }

    func testSavedConversationRestoresItsLastQuestionScope() throws {
        let store = makeStore()
        let day = try XCTUnwrap(Calendar.current.date(from: DateComponents(
            year: 2026, month: 8, day: 31)))
        let meetings = Conversation(
            title: "Meetings",
            updatedAt: Date(timeIntervalSince1970: 2_000),
            messages: [
                ChatMessage(
                    role: .user, text: "meeting question",
                    sourceScopes: [.meetings], dayScope: day),
                ChatMessage(role: .assistant, text: "answer"),
            ])
        let screen = Conversation(
            title: "Screen",
            updatedAt: Date(timeIntervalSince1970: 1_000),
            messages: [
                ChatMessage(role: .user, text: "screen question", sourceScopes: [.screen]),
                ChatMessage(role: .assistant, text: "answer"),
            ])
        store.save(screen)
        store.save(meetings)

        let model = makeModel(
            engine: SequencedChatEngine([]),
            runner: BlockingChatRunner(),
            store: store)

        XCTAssertEqual(model.currentQuestionScope?.sources, [.meetings])
        XCTAssertEqual(model.currentQuestionScope?.dayScopeKey, "2026-08-31")
        model.select(screen.id)
        XCTAssertEqual(model.currentQuestionScope?.sources, [.screen])
        XCTAssertNil(model.currentQuestionScope?.dayScopeKey)
    }

    func testStaleCancelledRunDoesNotTouchRecencyAfterSwitchAwayAndBack() async throws {
        let store = makeStore()
        let older = Conversation(
            title: "Older",
            updatedAt: Date(timeIntervalSince1970: 1_000),
            messages: [ChatMessage(role: .user, text: "old")])
        let current = Conversation(
            title: "Current",
            updatedAt: Date(timeIntervalSince1970: 2_000),
            messages: [
                ChatMessage(role: .user, text: "current"),
                ChatMessage(role: .assistant, text: "answer"),
            ])
        store.save(older)
        store.save(current)
        let runner = ManuallyReleasedChatRunner()
        let model = makeModel(
            engine: SequencedChatEngine([
                #"{"tool":"search_meetings","arguments":{"query":"wait"}}"#,
            ]),
            runner: runner,
            store: store)

        model.send("Keep working", sourceScopes: [.meetings])
        await waitUntil("response did not reach non-cooperative runner") { runner.started }
        model.select(older.id)
        model.select(current.id)
        let recencyBeforeUnwind = try XCTUnwrap(
            model.conversations.first { $0.id == current.id }?.updatedAt)

        runner.release()
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(
            model.conversations.first { $0.id == current.id }?.updatedAt,
            recencyBeforeUnwind)
        XCTAssertEqual(model.conversations.map(\.id), [current.id, older.id])
    }

    func testRestrictedQuestionOmitsAmbientWorkMemory() async {
        let restrictedEngine = SequencedChatEngine(["Restricted answer"])
        let restrictedModel = ChatViewModel(
            makeEngine: { restrictedEngine },
            tools: BlockingChatRunner(),
            store: makeStore(),
            workMemory: { "PRIVATE DREAM MEMORY" })

        restrictedModel.send("Use meetings only", sourceScopes: [.meetings])
        await waitUntil("restricted answer did not complete") {
            !restrictedModel.isResponding
        }

        XCTAssertFalse(restrictedEngine.systems.joined().contains("PRIVATE DREAM MEMORY"))

        let fullEngine = SequencedChatEngine(["Full answer"])
        let fullModel = ChatViewModel(
            makeEngine: { fullEngine },
            tools: BlockingChatRunner(),
            store: makeStore(),
            workMemory: { "PRIVATE DREAM MEMORY" })

        fullModel.send("Use all context", sourceScopes: AskSourceScope.defaults)
        await waitUntil("full-scope answer did not complete") { !fullModel.isResponding }

        XCTAssertTrue(fullEngine.systems.joined().contains("PRIVATE DREAM MEMORY"))
    }

    func testAssistantTimestampRecordsCompletionRatherThanQuestionTime() async throws {
        let model = makeModel(
            engine: DelayedChatEngine(),
            runner: BlockingChatRunner())

        model.send("When did this finish?")
        await waitUntil("delayed answer did not complete") { !model.isResponding }

        let question = try XCTUnwrap(model.messages.first)
        let answer = try XCTUnwrap(model.messages.last)
        XCTAssertGreaterThan(answer.createdAt, question.createdAt)
        XCTAssertFalse(answer.createdAtIsEstimated)
    }

    private func makeStore() -> ChatStore {
        ChatStore(rootURL: root, encryptionKey: { [encryptionKey] in encryptionKey })
    }

    private func makeModel(
        engine: TextEngine,
        runner: ChatToolRunner,
        store: ChatStore? = nil
    ) -> ChatViewModel {
        ChatViewModel(
            makeEngine: { engine },
            tools: runner,
            store: store ?? makeStore())
    }

    private func waitUntil(
        _ failureMessage: String,
        timeout: TimeInterval = 2,
        condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail(failureMessage)
    }
}

private final class SequencedChatEngine: TextEngine {
    private var outputs: [String]
    private(set) var systems: [String] = []

    init(_ outputs: [String]) {
        self.outputs = outputs
    }

    var displayName: String { "Sequenced chat test engine" }

    func generate(system: String, prompt: String, context: [String]) async throws -> String {
        systems.append(system)
        return outputs.isEmpty ? "" : outputs.removeFirst()
    }
}

private final class DelayedChatEngine: TextEngine {
    var displayName: String { "Delayed chat test engine" }

    func generate(system: String, prompt: String, context: [String]) async throws -> String {
        try await Task.sleep(for: .milliseconds(30))
        return "Done"
    }
}

@MainActor
private final class BlockingChatRunner: ChatToolRunner {
    let specs = [
        ChatToolSpec(
            name: "search_meetings",
            summary: "Search meetings",
            arguments: [.init(name: "query", description: "Search query", required: true)]),
    ]
    private(set) var started = false
    private(set) var sawCancellation = false

    func libraryOverview() -> String { "Test meetings" }

    func run(_ call: ChatToolCall) async -> ChatToolResult {
        started = true
        while !Task.isCancelled {
            await Task.yield()
        }
        sawCancellation = true
        return ChatToolResult(text: "cancelled", summary: "cancelled")
    }
}

@MainActor
private final class ManuallyReleasedChatRunner: ChatToolRunner {
    let specs = [
        ChatToolSpec(
            name: "search_meetings",
            summary: "Search meetings",
            arguments: [.init(name: "query", description: "Search query", required: true)]),
    ]
    private(set) var started = false
    private var continuation: CheckedContinuation<Void, Never>?

    func libraryOverview() -> String { "Test meetings" }

    func run(_ call: ChatToolCall) async -> ChatToolResult {
        started = true
        await withCheckedContinuation { continuation = $0 }
        return ChatToolResult(text: "released", summary: "released")
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
