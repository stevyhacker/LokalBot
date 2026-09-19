import Combine
import Foundation
import CryptoKit

/// One line in the chat transcript. `activity` holds the tool steps the
/// assistant ran for this turn (shown as chips above its answer). Codable so
/// conversations persist; `isPending` is transient and never written.
struct ChatMessage: Identifiable, Equatable, Codable {
    struct Activity: Identifiable, Equatable, Codable {
        let id: UUID
        let tool: String
        let icon: String
        var text: String
        var done: Bool

        init(id: UUID = UUID(), tool: String, icon: String, text: String, done: Bool) {
            self.id = id; self.tool = tool; self.icon = icon; self.text = text; self.done = done
        }
    }

    let id: UUID
    let role: ChatRole
    var text: String
    /// When this turn entered the conversation. Legacy messages retain the
    /// conversation date for ordering but are marked estimated in the UI.
    var createdAt: Date
    var createdAtIsEstimated: Bool
    var activity: [Activity]
    /// Sources enabled for this specific question. Empty on legacy turns.
    var sourceScopes: [AskSourceScope]
    /// Optional calendar-day constraint applied to this turn. Kept separate
    /// from source scopes so a date filter never silently grants a source.
    var dayScopeKey: String?
    /// Civil days represented by screen moments explicitly attached to the
    /// prompt. OCR itself remains ephemeral; these keys preserve provenance.
    var attachedScreenDayKeys: [String]
    var meetingIDs: Set<UUID>?
    var screenSnapshotIDs: Set<Int64>?
    /// Version-1 turns did not persist enough source/day/attachment provenance
    /// to replay or retry them safely under a narrower modern scope.
    fileprivate var legacyScopeIsAmbiguous: Bool
    /// The assistant turn is still being generated. Transient — never persisted.
    var isPending: Bool
    /// The turn failed (engine unreachable, no model, …) — rendered as an error.
    var isError: Bool

    init(id: UUID = UUID(), role: ChatRole, text: String,
         createdAt: Date = Date(), activity: [Activity] = [],
         sourceScopes: [AskSourceScope] = [], dayScope: Date? = nil,
         dayScopeKey: String? = nil, createdAtIsEstimated: Bool = false,
         attachedScreenDayKeys: [String] = [],
         meetingIDs: Set<UUID>? = nil, screenSnapshotIDs: Set<Int64>? = nil,
         isPending: Bool = false, isError: Bool = false) {
        self.id = id; self.role = role; self.text = text
        self.createdAt = createdAt; self.createdAtIsEstimated = createdAtIsEstimated
        self.activity = activity; self.sourceScopes = sourceScopes
        self.dayScopeKey = dayScopeKey ?? dayScope.map { AskDayScope.key(for: $0) }
        self.meetingIDs = meetingIDs
        self.screenSnapshotIDs = screenSnapshotIDs
        self.attachedScreenDayKeys = attachedScreenDayKeys
        legacyScopeIsAmbiguous = false
        sourceScopeSchemaVersion = Self.currentSourceScopeSchemaVersion
        self.isPending = isPending; self.isError = isError
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, text, createdAt, createdAtIsEstimated, activity, sourceScopes
        case dayScope, attachedScreenDayKeys, sourceScopeSchemaVersion, meetingIDs, screenSnapshotIDs
        case legacyScopeIsAmbiguous, isError
    }

    static let legacyCreatedAtFallback = Date.distantPast
    private static let currentSourceScopeSchemaVersion = 2
    fileprivate var sourceScopeSchemaVersion: Int

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        role = try c.decode(ChatRole.self, forKey: .role)
        text = try c.decode(String.self, forKey: .text)
        let decodedCreatedAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        createdAt = decodedCreatedAt ?? Self.legacyCreatedAtFallback
        createdAtIsEstimated = try c.decodeIfPresent(
            Bool.self, forKey: .createdAtIsEstimated) ?? (decodedCreatedAt == nil)
        activity = try c.decodeIfPresent([Activity].self, forKey: .activity) ?? []
        sourceScopes = try c.decodeIfPresent([AskSourceScope].self, forKey: .sourceScopes) ?? []
        legacyScopeIsAmbiguous = try c.decodeIfPresent(
            Bool.self, forKey: .legacyScopeIsAmbiguous) ?? false
        let rawDayScope = try? c.decode(String.self, forKey: .dayScope)
        dayScopeKey = rawDayScope.flatMap { AskDayScope.isCanonicalKey($0) ? $0 : nil }
        if c.contains(.dayScope), dayScopeKey == nil {
            // Older builds persisted an absolute Date. Its originating time
            // zone was never saved, so converting it to a civil day after the
            // user travels can move the retrieval boundary. Drop the unknown
            // day and prevent a retry from silently widening the old request.
            legacyScopeIsAmbiguous = true
        }
        attachedScreenDayKeys = try c.decodeIfPresent(
            [String].self, forKey: .attachedScreenDayKeys)?.filter(AskDayScope.isCanonicalKey)
            ?? []
        sourceScopeSchemaVersion = try c.decodeIfPresent(
            Int.self, forKey: .sourceScopeSchemaVersion) ?? 1
        isError = try c.decodeIfPresent(Bool.self, forKey: .isError) ?? false
        meetingIDs = try c.decodeIfPresent(Set<UUID>.self, forKey: .meetingIDs)
        screenSnapshotIDs = try c.decodeIfPresent(Set<Int64>.self, forKey: .screenSnapshotIDs)
        isPending = false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(role, forKey: .role)
        try c.encode(text, forKey: .text)
        try c.encode(createdAt, forKey: .createdAt)
        if createdAtIsEstimated {
            try c.encode(true, forKey: .createdAtIsEstimated)
        }
        if !activity.isEmpty { try c.encode(activity, forKey: .activity) }
        if !sourceScopes.isEmpty { try c.encode(sourceScopes, forKey: .sourceScopes) }
        try c.encodeIfPresent(dayScopeKey, forKey: .dayScope)
        try c.encodeIfPresent(meetingIDs, forKey: .meetingIDs)
        try c.encodeIfPresent(screenSnapshotIDs, forKey: .screenSnapshotIDs)
        if !attachedScreenDayKeys.isEmpty {
            try c.encode(attachedScreenDayKeys, forKey: .attachedScreenDayKeys)
        }
        try c.encode(Self.currentSourceScopeSchemaVersion, forKey: .sourceScopeSchemaVersion)
        if legacyScopeIsAmbiguous {
            try c.encode(true, forKey: .legacyScopeIsAmbiguous)
        }
        if isError { try c.encode(isError, forKey: .isError) }
    }
}

/// A saved chat conversation — the unit of history persisted to disk.
struct Conversation: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var messages: [ChatMessage]

    init(id: UUID = UUID(), title: String = ChatViewModel.newChatTitle,
         createdAt: Date = Date(), updatedAt: Date = Date(), messages: [ChatMessage] = []) {
        self.id = id; self.title = title; self.createdAt = createdAt
        self.updatedAt = updatedAt; self.messages = messages
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, createdAt, updatedAt, messages
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title)
            ?? ChatViewModel.newChatTitle
        let conversationCreatedAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
            ?? Date()
        createdAt = conversationCreatedAt
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
            ?? conversationCreatedAt
        let decoded = try c.decodeIfPresent([ChatMessage].self, forKey: .messages) ?? []
        messages = decoded.map { message in
            var migrated = message
            if migrated.createdAt == ChatMessage.legacyCreatedAtFallback {
                migrated.createdAt = conversationCreatedAt
                migrated.createdAtIsEstimated = true
            }
            if migrated.sourceScopeSchemaVersion < 2 {
                // Version 1 also omitted pinned-screen provenance. Even a
                // Meetings-only label could have hidden OCR in its prompt, so
                // every old turn is unsafe to retry or reuse in a narrower
                // source/day request.
                migrated.legacyScopeIsAmbiguous = true
                // Version 1 overloaded Today as a source and, when selected
                // alone, as a one-day grant to every source. Mixed selections
                // had asymmetric rules, handled conservatively below.
                let legacyScopes = Set(migrated.sourceScopes)
                if legacyScopes.contains(.today) {
                    // Old messages did not record a per-turn date, while mixed
                    // version-1 scopes also date-limited sources asymmetrically.
                    // Even an exact timestamp cannot recover the originating
                    // time zone, so restore source types without fabricating a
                    // civil day or retrying under semantics the turn never had.
                    // Its existing answer remains safe history for full scope.
                    if legacyScopes != AskSourceScope.defaults {
                        migrated.sourceScopes = AskSourceScope.allCases
                    }
                    migrated.dayScopeKey = nil
                    migrated.legacyScopeIsAmbiguous = true
                }
                migrated.sourceScopeSchemaVersion = 2
            }
            return migrated
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(messages, forKey: .messages)
    }
}

/// Persists chat conversations as one JSON file per conversation under
/// `<root>/chats/`, mirroring the file-per-document layout used for meetings
/// and journals. Personal scale: the whole set loads into memory and each
/// save rewrites a single small file atomically.
@MainActor
final class ChatStore {
    private let dir: URL
    private let encryptionKey: @MainActor () throws -> SymmetricKey

    init(rootURL: URL, encryptionKey: @escaping @MainActor () throws -> SymmetricKey = {
        try KeychainSecrets.symmetricKey(account: "chat-key")
    }) {
        dir = rootURL.appendingPathComponent("chats", isDirectory: true)
        self.encryptionKey = encryptionKey
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private func fileURL(_ id: UUID) -> URL {
        dir.appendingPathComponent("\(id.uuidString).json.enc")
    }

    func loadAll() -> [Conversation] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { return [] }
        let key = try? encryptionKey()
        var result: [Conversation] = []
        for file in files {
            switch file.pathExtension {
            case "enc":
                guard let key,
                      let data = try? Data(contentsOf: file),
                      let box = try? AES.GCM.SealedBox(combined: data),
                      let plain = try? AES.GCM.open(box, using: key),
                      let convo = try? Self.decoder.decode(Conversation.self, from: plain)
                else { continue }
                result.append(convo)
            case "json":
                // Legacy plaintext (pre-encryption): load it, then migrate to a
                // sealed file — deleting the plaintext only once the encrypted
                // copy is safely written.
                guard let data = try? Data(contentsOf: file),
                      let convo = try? Self.decoder.decode(Conversation.self, from: data)
                else { continue }
                result.append(convo)
                if save(convo) { try? FileManager.default.removeItem(at: file) }
            default:
                continue
            }
        }
        return result.sorted { $0.updatedAt > $1.updatedAt }
    }

    func loadAllInBackground() async -> [Conversation] {
        let dir = dir, key = try? encryptionKey()
        let loaded = await Task.detached(priority: .userInitiated) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            var conversations: [UUID: Conversation] = [:]
            var legacy: [UUID: URL] = [:]
            // Encrypted copies win if an earlier migration left both files.
            for file in files.sorted(by: { $0.pathExtension == "json" && $1.pathExtension != "json" }) {
                guard let data = try? Data(contentsOf: file) else { continue }
                let plain: Data
                if file.pathExtension == "enc", let key,
                   let box = try? AES.GCM.SealedBox(combined: data),
                   let decrypted = try? AES.GCM.open(box, using: key) {
                    plain = decrypted
                } else if file.pathExtension == "json" {
                    plain = data
                } else { continue }
                guard let conversation = try? decoder.decode(Conversation.self, from: plain) else { continue }
                conversations[conversation.id] = conversation
                if file.pathExtension == "json" { legacy[conversation.id] = file }
            }
            return (conversations, legacy)
        }.value
        // Legacy writes remain on the store owner so they cannot race save/delete.
        // Verify the plaintext still exists: deletion during hydration wins.
        for (id, file) in loaded.1 where FileManager.default.fileExists(atPath: file.path) {
            if let conversation = loaded.0[id], save(conversation) {
                try? FileManager.default.removeItem(at: file)
            }
        }
        return loaded.0.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Encode → AES-GCM seal (per-install Keychain key) → atomic write. Returns
    /// whether the sealed file landed, so the migration above never discards
    /// plaintext before its encrypted replacement exists.
    @discardableResult
    func save(_ conversation: Conversation) -> Bool {
        guard let key = try? encryptionKey(),
              let data = try? Self.encoder.encode(conversation),
              let combined = try? AES.GCM.seal(data, using: key).combined else { return false }
        do {
            try combined.write(to: fileURL(conversation.id), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: fileURL(id))
        // Drop any legacy plaintext that was never migrated.
        try? FileManager.default.removeItem(
            at: dir.appendingPathComponent("\(id.uuidString).json"))
    }
}

/// Drives the Chat section: owns the message list and runs `ChatAgent` against
/// the same `TextEngine` the summariser uses (resolved lazily per send via
/// `ThinkExecution.makeTextEngine`, so it always reflects the current
/// Settings → Models choice and boots the built-in server on first use).
@MainActor
final class ChatViewModel: ObservableObject {
    struct QuestionScope: Equatable {
        var sources: Set<AskSourceScope>
        var dayScopeKey: String?
        var meetingIDs: Set<UUID>?
        var screenSnapshotIDs: Set<Int64>?
    }
    enum ResponsePhase: Equatable {
        case preparingEngine
        case startingAssistant
    }

    @Published private(set) var messages: [ChatMessage] = []
    @Published var draft = ""
    @Published private(set) var isResponding = false
    @Published private(set) var responsePhase: ResponsePhase?
    /// All saved conversations, most-recently-updated first (drives the list).
    @Published private(set) var conversations: [Conversation] = []
    /// The conversation currently shown in the transcript.
    @Published private(set) var currentID: UUID
    @Published private(set) var isLoadingHistory = false
    private var historyTask: Task<Void, Never>?
    private var historyTouched = false
    private var deletedDuringHydration: Set<UUID> = []
    var readingOffsets: [UUID: CGFloat] = [:]

    var currentQuestionScope: QuestionScope? {
        guard let question = messages.last(where: { $0.role == .user }) else { return nil }
        return QuestionScope(
            sources: question.sourceScopes.isEmpty
                ? AskSourceScope.defaults
                : Set(question.sourceScopes),
            dayScopeKey: question.dayScopeKey,
            meetingIDs: question.meetingIDs, screenSnapshotIDs: question.screenSnapshotIDs)
    }

    nonisolated static let newChatTitle = "New conversation"

    /// Prompt chips shown on the empty state.
    let suggestions = [
        "What did we decide in my last meeting?",
        "List my recent meetings",
        "Search my meetings for action items",
    ]

    private let makeEngine: () async throws -> TextEngine
    private let tools: ChatToolRunner
    private let store: ChatStore
    /// Re-read per send so an overnight dream lands in the next question
    /// without restarting the app. Empty when dreaming is off or has nothing.
    private let workMemory: () -> String
    private var task: Task<Void, Never>?
    private struct RetryPayload {
        var prompt: String
        var displayText: String
        var scopes: Set<AskSourceScope>
        var dayScopeKey: String?
        var attachedScreenDayKeys: [String]
        var meetingIDs: Set<UUID>?
        var screenSnapshotIDs: Set<Int64>?
    }
    private var retryPayloads: [UUID: RetryPayload] = [:]
    private var activeAssistantID: UUID?

#if DEBUG
    /// Exposes identifiers, never hidden prompt contents, for lifecycle tests.
    var retainedRetryPayloadIDs: Set<UUID> { Set(retryPayloads.keys) }
#endif

    init(makeEngine: @escaping () async throws -> TextEngine, tools: ChatToolRunner,
         store: ChatStore, workMemory: @escaping () -> String = { "" },
         deferHistoryLoading: Bool = false) {
        self.makeEngine = makeEngine
        self.tools = tools
        self.store = store
        self.workMemory = workMemory
        let saved = deferHistoryLoading ? [] : store.loadAll()
        if let latest = saved.first {
            conversations = saved
            currentID = latest.id
            messages = latest.messages
        } else {
            let fresh = Conversation()
            conversations = [fresh]
            currentID = fresh.id
        }
        if deferHistoryLoading {
            isLoadingHistory = true
            historyTask = Task { @MainActor [weak self, store] in
                let saved = await store.loadAllInBackground()
                guard let self else { return }
                let retained = saved.filter { !self.deletedDuringHydration.contains($0.id) }
                if !self.historyTouched, self.messages.isEmpty, self.draft.isEmpty, let latest = retained.first {
                    self.conversations = retained
                    self.currentID = latest.id
                    self.messages = latest.messages
                } else {
                    let existing = Set(self.conversations.map(\.id))
                    self.conversations += retained.filter { !existing.contains($0.id) }
                    self.conversations.sort { $0.updatedAt > $1.updatedAt }
                }
                self.isLoadingHistory = false
                self.deletedDuringHydration = []
            }
        }
    }

    func waitForHistory() async { await historyTask?.value }
    func preserveSelectionDuringHistoryLoad() { historyTouched = true }

    /// Send the current draft (or an explicit `prompt`, e.g. a suggestion chip).
    /// `displayText` keeps model-only context such as attached OCR excerpts out
    /// of the visible transcript while still sending it in the current turn.
    func send(_ prompt: String? = nil, displayText: String? = nil,
              sourceScopes: Set<AskSourceScope> = AskSourceScope.defaults,
              dayScope: Date? = nil,
              attachedScreenDates: [Date] = [],
              meetingIDs: Set<UUID>? = nil, screenSnapshotIDs: Set<Int64>? = nil) {
        sendResolved(
            prompt,
            displayText: displayText,
            sourceScopes: sourceScopes,
            dayScopeKey: dayScope.map { AskDayScope.key(for: $0) },
            attachedScreenDayKeys: Array(Set(
                attachedScreenDates.map { AskDayScope.key(for: $0) })).sorted(),
            meetingIDs: meetingIDs, screenSnapshotIDs: screenSnapshotIDs)
    }

    private func sendResolved(
        _ prompt: String?,
        displayText: String?,
        sourceScopes: Set<AskSourceScope>,
        dayScopeKey: String?,
        attachedScreenDayKeys: [String],
        meetingIDs: Set<UUID>?, screenSnapshotIDs: Set<Int64>?
    ) {
        let text = (prompt ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isResponding else { return }
        historyTouched = true
        let trimmedDisplay = displayText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let visibleText = trimmedDisplay.flatMap { $0.isEmpty ? nil : $0 } ?? text
        draft = ""

        // A new question supersedes any failed turn in this conversation.
        // Discard its transient hidden prompt (which may contain attached OCR)
        // before retaining the new turn's retry payload.
        discardRetryPayloads(for: messages)

        // Only complete question/answer pairs belong in model history. A
        // failed or stopped answer must not leave its unanswered question as
        // implicit context for the next request.
        let history = Self.finalizedHistoryForKey(
            from: messages.filter { message in
                (meetingIDs == nil || (message.meetingIDs.map { $0.isSubset(of: meetingIDs ?? []) } ?? false))
                    && (screenSnapshotIDs == nil || (message.screenSnapshotIDs.map { $0.isSubset(of: screenSnapshotIDs ?? []) } ?? false))
            },
            allowedScopes: sourceScopes,
            dayScopeKey: dayScopeKey)

        let orderedScopes = AskSourceScope.allCases.filter(sourceScopes.contains)
        let sentAt = Date()
        messages.append(ChatMessage(
            role: .user, text: visibleText, createdAt: sentAt,
            sourceScopes: orderedScopes, dayScopeKey: dayScopeKey,
            attachedScreenDayKeys: attachedScreenDayKeys,
            meetingIDs: meetingIDs, screenSnapshotIDs: screenSnapshotIDs))
        let assistant = ChatMessage(
            role: .assistant, text: "", createdAt: sentAt,
            sourceScopes: orderedScopes, dayScopeKey: dayScopeKey,
            attachedScreenDayKeys: attachedScreenDayKeys,
            meetingIDs: meetingIDs, screenSnapshotIDs: screenSnapshotIDs, isPending: true)
        let assistantID = assistant.id
        let conversationID = currentID
        messages.append(assistant)
        isResponding = true
        responsePhase = .preparingEngine
        retryPayloads[assistantID] = .init(
            prompt: text, displayText: visibleText, scopes: sourceScopes,
            dayScopeKey: dayScopeKey,
            attachedScreenDayKeys: attachedScreenDayKeys,
            meetingIDs: meetingIDs, screenSnapshotIDs: screenSnapshotIDs)
        activeAssistantID = assistantID
        persist()

        task = Task { [weak self] in
            await self?.run(
                latest: text,
                history: history,
                assistantID: assistantID,
                conversationID: conversationID,
                scopes: sourceScopes,
                dayScopeKey: dayScopeKey,
                meetingIDs: meetingIDs, screenSnapshotIDs: screenSnapshotIDs)
        }
    }

    /// Cancel an in-flight response.
    func stop() {
        guard isResponding, let assistantID = activeAssistantID else { return }
        task?.cancel()
        task = nil
        if finalizeInterruptedTurn(assistantID) {
            // Persist immediately: app termination or a conversation switch may
            // happen before a provider or tool cooperatively unwinds.
            persist()
        }
        activeAssistantID = nil
        isResponding = false
        responsePhase = nil
    }

    func canRetry(_ assistantID: UUID) -> Bool {
        guard !isResponding,
              let index = messages.firstIndex(where: { $0.id == assistantID }),
              messages[index].role == .assistant,
              messages[index].isError,
              messages.last?.id == assistantID,
              let user = messages[..<index].last(where: { $0.role == .user }),
              !user.legacyScopeIsAmbiguous else { return false }
        let hasLivePayload = retryPayloads[assistantID] != nil
        guard user.attachedScreenDayKeys.isEmpty || hasLivePayload else { return false }
        return true
    }

    /// Retry an errored assistant turn without duplicating the visible user
    /// message. In-session retries preserve hidden screen/day context; a
    /// persisted error safely falls back to the preceding visible question when
    /// the original turn had no ephemeral screen attachment.
    func retry(_ assistantID: UUID) {
        guard canRetry(assistantID),
              let assistantIndex = messages.firstIndex(where: { $0.id == assistantID }),
              let userIndex = messages[..<assistantIndex].lastIndex(where: { $0.role == .user })
        else { return }
        let payload = retryPayloads[assistantID]
            ?? .init(
                prompt: messages[userIndex].text,
                displayText: messages[userIndex].text,
                scopes: Set(messages[userIndex].sourceScopes.isEmpty
                    ? AskSourceScope.allCases : messages[userIndex].sourceScopes),
                dayScopeKey: messages[userIndex].dayScopeKey,
                attachedScreenDayKeys: [],
                meetingIDs: messages[userIndex].meetingIDs,
                screenSnapshotIDs: messages[userIndex].screenSnapshotIDs)
        messages.remove(at: assistantIndex)
        messages.remove(at: userIndex)
        retryPayloads[assistantID] = nil
        sendResolved(
            payload.prompt,
            displayText: payload.displayText,
            sourceScopes: payload.scopes,
            dayScopeKey: payload.dayScopeKey,
            attachedScreenDayKeys: payload.attachedScreenDayKeys,
            meetingIDs: payload.meetingIDs, screenSnapshotIDs: payload.screenSnapshotIDs)
    }

    /// Start a new, empty conversation (persisting the current one first).
    func newConversation() {
        historyTouched = true
        stop()
        persist(touchUpdatedAt: false)
        // Already on an empty conversation? Stay put rather than pile up blanks.
        if messages.isEmpty { return }
        let fresh = Conversation()
        conversations.insert(fresh, at: 0)
        currentID = fresh.id
        messages = []
    }

    /// Switch the transcript to a previously-saved conversation.
    func select(_ id: UUID) {
        historyTouched = true
        guard id != currentID else { return }
        stop()
        persist(touchUpdatedAt: false)
        currentID = id
        messages = conversations.first { $0.id == id }?.messages ?? []
    }

    /// Delete a conversation from disk and the list.
    func delete(_ id: UUID) {
        historyTouched = true
        if isLoadingHistory { deletedDuringHydration.insert(id) }
        let deletingCurrent = id == currentID
        if deletingCurrent { stop() }
        let deletedMessages = deletingCurrent
            ? messages
            : conversations.first(where: { $0.id == id })?.messages ?? []
        discardRetryPayloads(for: deletedMessages)
        store.delete(id)
        conversations.removeAll { $0.id == id }
        guard deletingCurrent else { return }
        if let next = conversations.first {
            currentID = next.id
            messages = next.messages
        } else {
            let fresh = Conversation()
            conversations = [fresh]
            currentID = fresh.id
            messages = []
        }
    }

    private func discardRetryPayloads(for messages: [ChatMessage]) {
        let messageIDs = Set(messages.map(\.id))
        retryPayloads = retryPayloads.filter { !messageIDs.contains($0.key) }
    }

    /// Fold the live transcript back into its conversation and persist it.
    /// In-flight / empty assistant placeholders are dropped so a half-finished
    /// turn never lands on disk.
    private func persist(touchUpdatedAt: Bool = true) {
        guard let index = conversations.firstIndex(where: { $0.id == currentID }) else { return }
        let clean = messages
            .filter { !($0.role == .assistant && $0.text.isEmpty && !$0.isError) }
            .map { message -> ChatMessage in
                var copy = message
                copy.isPending = false
                return copy
            }
        var convo = conversations[index]
        convo.messages = clean
        if touchUpdatedAt { convo.updatedAt = Date() }
        if convo.title == Self.newChatTitle, let firstUser = clean.first(where: { $0.role == .user }) {
            convo.title = Self.title(from: firstUser.text)
        }
        if touchUpdatedAt {
            conversations.remove(at: index)
            conversations.insert(convo, at: 0)
        } else {
            conversations[index] = convo
        }
        if !clean.isEmpty { store.save(convo) }
    }

    static func finalizedHistory(
        from messages: [ChatMessage],
        allowedScopes: Set<AskSourceScope> = AskSourceScope.defaults,
        dayScope: Date? = nil,
        calendar: Calendar = .current
    ) -> [ChatAgent.Turn] {
        finalizedHistoryForKey(
            from: messages,
            allowedScopes: allowedScopes,
            dayScopeKey: dayScope.map { AskDayScope.key(for: $0, calendar: calendar) })
    }

    private static func finalizedHistoryForKey(
        from messages: [ChatMessage],
        allowedScopes: Set<AskSourceScope>,
        dayScopeKey: String?
    ) -> [ChatAgent.Turn] {
        var history: [ChatAgent.Turn] = []
        var pendingUser: ChatMessage?
        for message in messages {
            switch message.role {
            case .user:
                pendingUser = message
            case .assistant:
                guard let user = pendingUser else { continue }
                if !message.isPending,
                   !message.isError,
                   historyPairAllowed(
                    user,
                    allowedScopes: allowedScopes,
                    dayScopeKey: dayScopeKey) {
                    history.append(.init(role: .user, text: user.text))
                    history.append(.init(role: .assistant, text: message.text))
                }
                pendingUser = nil
            }
        }
        return history
    }

    private static func historyPairAllowed(
        _ user: ChatMessage,
        allowedScopes: Set<AskSourceScope>,
        dayScopeKey: String?
    ) -> Bool {
        if user.legacyScopeIsAmbiguous {
            return allowedScopes == AskSourceScope.defaults && dayScopeKey == nil
        }
        if let dayScopeKey,
           user.attachedScreenDayKeys.contains(where: { $0 != dayScopeKey }) {
            return false
        }
        let historicalScopes = Set(user.sourceScopes)
        if historicalScopes.isEmpty {
            guard allowedScopes == AskSourceScope.defaults, dayScopeKey == nil else { return false }
        } else if !historicalScopes.isSubset(of: allowedScopes) {
            return false
        }

        switch (user.dayScopeKey, dayScopeKey) {
        case (nil, nil): return true
        case (_?, nil): return true
        case (let historicalDay?, let allowedDay?): return historicalDay == allowedDay
        case (nil, _?): return false
        }
    }

    /// A short, stable history label derived locally from the first question.
    /// This deliberately avoids another inference request for a cosmetic title.
    static func compactTitle(from text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        var candidate = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !candidate.isEmpty else { return newChatTitle }

        if let colon = candidate.firstIndex(of: ":") {
            let lead = candidate[..<colon].lowercased()
            if lead.contains("task title") || lead.contains("for this task") {
                candidate = String(candidate[candidate.index(after: colon)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        for prefix in ["please give me ", "give me ", "please tell me ", "tell me ", "please "] {
            if candidate.lowercased().hasPrefix(prefix) {
                candidate.removeFirst(prefix.count)
                break
            }
        }

        if let comma = candidate.firstIndex(of: ","),
           candidate.distance(from: candidate.startIndex, to: comma) >= 18 {
            candidate = String(candidate[..<comma])
        }

        candidate = candidate.split(separator: " ").map { word in
            word == "i" ? "I" : String(word)
        }.joined(separator: " ")
        guard !candidate.isEmpty else { return newChatTitle }
        if let first = candidate.first {
            candidate.replaceSubrange(
                candidate.startIndex...candidate.startIndex,
                with: String(first).uppercased())
        }

        let limit = 38
        guard candidate.count > limit else { return candidate }
        let prefix = candidate.prefix(limit)
        if let boundary = prefix.lastIndex(where: \.isWhitespace) {
            return String(prefix[..<boundary]) + "…"
        }
        return String(prefix) + "…"
    }

    static func displayTitle(for conversation: Conversation) -> String {
        let stored = conversation.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard stored != newChatTitle else { return newChatTitle }
        let source = stored.hasSuffix("…")
            ? conversation.messages.first(where: { $0.role == .user })?.text ?? stored
            : stored
        return compactTitle(from: source)
    }

    private static func title(from text: String) -> String {
        compactTitle(from: text)
    }

    // MARK: - Run

    private func run(latest: String, history: [ChatAgent.Turn], assistantID: UUID,
                     conversationID: UUID, scopes: Set<AskSourceScope>,
                     dayScopeKey: String?, meetingIDs: Set<UUID>?,
                     screenSnapshotIDs: Set<Int64>?) async {
        defer {
            let stillOwnsGeneration = activeAssistantID == assistantID
            if stillOwnsGeneration {
                isResponding = false
                responsePhase = nil
                activeAssistantID = nil
                task = nil
            }
            // Conversation switches persist the interrupted terminal turn
            // before replacing `messages`; do not reorder or rewrite the newly
            // selected conversation when the cancelled task finally unwinds.
            if currentID == conversationID {
                persist(touchUpdatedAt: stillOwnsGeneration)
            }
        }
        do {
            let engine = try await makeEngine()
            try Task.checkCancellation()
            guard activeAssistantID == assistantID,
                  currentID == conversationID else { return }
            responsePhase = .startingAssistant
            let scopedTools = ScopedChatToolRunner(
                base: tools,
                scopes: scopes,
                dayScopeKey: dayScopeKey,
                meetingIDs: meetingIDs, screenSnapshotIDs: screenSnapshotIDs)
            var agent = ChatAgent(engine: engine, runner: scopedTools)
            // Dream memory is distilled from meetings, activity, and screen
            // context. Including it in a restricted question would bypass the
            // per-turn source/day boundary even though no tool could do so.
            if scopes == AskSourceScope.defaults, dayScopeKey == nil, meetingIDs == nil, screenSnapshotIDs == nil {
                agent.workMemory = workMemory()
            }
            let answer = try await agent.respond(history: history, latest: latest) { [weak self] event in
                self?.apply(event, to: assistantID)
            }
            try Task.checkCancellation()
            update(assistantID) {
                $0.text = answer
                $0.createdAt = Date()
                $0.createdAtIsEstimated = false
                $0.isPending = false
            }
            retryPayloads[assistantID] = nil
        } catch is CancellationError {
            _ = finalizeInterruptedTurn(assistantID)
        } catch {
            guard !Task.isCancelled else {
                _ = finalizeInterruptedTurn(assistantID)
                return
            }
            lokalbotLog("chat response failed: \(error.localizedDescription)")
            update(assistantID) {
                $0.text = Self.friendlyFailureMessage(for: error)
                $0.createdAt = Date()
                $0.createdAtIsEstimated = false
                $0.isError = true
                $0.isPending = false
            }
        }
    }

    nonisolated static func friendlyFailureMessage(for error: Error) -> String {
        if error is ModelDownloadManager.PreparationError {
            return "The assistant model could not be downloaded. Check your connection and free disk space, then try again."
        }
        if error is LlamaServer.ServerError {
            return "The on-device assistant could not start. Close memory-heavy apps or choose a smaller model, then try again."
        }
        if let engineError = error as? TextEngineError {
            switch engineError {
            case .noModel:
                return "No Main LLM is selected. Choose one in Settings → Models, then try again."
            case .serverUnreachable:
                return "The selected assistant could not be reached. Check its settings, then try again."
            case .httpStatus(let code, _, _):
                if code == 401 || code == 403 {
                    return "The selected assistant rejected its API key. Check the key in Settings, then try again."
                }
                if code == 429 {
                    return "The selected assistant is rate-limited. Wait briefly, then try again."
                }
                return "The assistant could not complete that request. Check the selected model in Settings, then try again."
            case .badResponse, .outputTruncated, .unavailable:
                return "The assistant could not complete that request. Check the selected model in Settings, then try again."
            }
        }
        return "The assistant could not complete that request. Check the selected model in Settings, then try again."
    }

    private func apply(_ event: ChatAgentEvent, to id: UUID) {
        guard messages.first(where: { $0.id == id })?.isPending == true else { return }
        switch event {
        case .answerPartial(let text):
            update(id) { $0.text = text }
        case .toolStarted(let call):
            update(id) {
                $0.activity.append(.init(tool: call.name, icon: Self.icon(for: call.name),
                                         text: Self.startLabel(call), done: false))
            }
        case .toolFinished(let name, let summary):
            update(id) {
                if let index = $0.activity.lastIndex(where: { $0.tool == name && !$0.done }) {
                    $0.activity[index].done = true
                    $0.activity[index].text = Self.finishLabel(name, summary: summary)
                }
            }
        }
    }

    private func update(_ id: UUID, _ mutate: (inout ChatMessage) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        mutate(&messages[index])
    }

    /// Convert an in-flight assistant placeholder into a durable, retryable
    /// terminal turn. This is deliberately idempotent because `stop()` updates
    /// immediately and the cancelled task reaches the same path later.
    @discardableResult
    private func finalizeInterruptedTurn(_ assistantID: UUID) -> Bool {
        guard let index = messages.firstIndex(where: { $0.id == assistantID }),
              messages[index].role == .assistant,
              messages[index].isPending
                || messages[index].activity.contains(where: { !$0.done }) else {
            return false
        }
        messages[index].text = "Response stopped. Retry when you're ready."
        messages[index].createdAt = Date()
        messages[index].createdAtIsEstimated = false
        messages[index].isPending = false
        messages[index].isError = true
        for activityIndex in messages[index].activity.indices
        where !messages[index].activity[activityIndex].done {
            messages[index].activity[activityIndex].done = true
            messages[index].activity[activityIndex].text += " — stopped"
        }
        return true
    }

    // MARK: - Activity presentation

    static func icon(for tool: String) -> String {
        switch tool {
        case "search_meetings": return "magnifyingglass"
        case "list_meetings": return "list.bullet"
        case "get_meeting": return "doc.text"
        case "get_action_items": return "checklist"
        case "search_screen": return "camera.viewfinder"
        case "activity_summary": return "chart.bar.doc.horizontal"
        default: return "wrench.and.screwdriver"
        }
    }

    static func startLabel(_ call: ChatToolCall) -> String {
        switch call.name {
        case "search_meetings": return "Searching meetings for “\(call.string("query") ?? "")”"
        case "list_meetings":
            return call.string("query").map { "Listing meetings matching “\($0)”" } ?? "Listing meetings"
        case "get_meeting": return "Reading meeting \(call.string("id") ?? "latest")"
        case "get_action_items":
            return call.string("id").map { "Collecting outcomes from meeting \($0)" }
                ?? "Collecting recent outcomes"
        case "search_screen": return "Searching screen text for “\(call.string("query") ?? "")”"
        case "activity_summary": return "Summarising activity for \(call.string("day") ?? "today")"
        default: return "Running \(call.name)"
        }
    }

    static func finishLabel(_ tool: String, summary: String) -> String {
        switch tool {
        case "search_meetings": return "Searched meetings — \(summary)"
        case "list_meetings": return "Listed \(summary)"
        case "get_meeting": return "Read “\(summary)”"
        case "get_action_items": return "Collected outcomes — \(summary)"
        case "search_screen": return "Searched screen text — \(summary)"
        case "activity_summary": return "Summarised \(summary)"
        default: return summary
        }
    }
}
