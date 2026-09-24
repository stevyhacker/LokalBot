import Combine
import Foundation

enum AgentSavedSessionOpenError: LocalizedError {
    case unavailable, alreadyOpen, missingWorkspace, maximumLiveSessions
    var errorDescription: String? {
        switch self {
        case .unavailable: "That saved task is no longer available. Refresh the task list and try again."
        case .alreadyOpen: "That task is already open."
        case .missingWorkspace: "The task’s working folder no longer exists. Choose a new folder before sending."
        case .maximumLiveSessions: "Four agents are already working. Stop one before starting another task. You can still browse every saved task."
        }
    }
}

/// A persistent task catalog with lazily loaded transcripts. The four-process
/// resource limit applies to execution, never navigation or saved history.
@MainActor
final class AgentSessionTabs: ObservableObject {
    static let maximumLiveSessions = 4

    struct Tab: Identifiable {
        let id: UUID
        let number: Int
        let controller: AgentSessionController
        var record: AgentTaskRecord
        var saved: AgentSavedSession?
        @MainActor var title: String { record.title ?? controller.sessionTitle ?? saved?.title ?? "New task" }
    }

    @Published private(set) var tabs: [Tab] = []
    @Published private(set) var selectedID = UUID()
    @Published var error: String?
    @Published var searchRequest = 0
    @Published var findRequest = 0
    @Published var resultsRequest = 0
    @Published var composerFocusRequest = 0
    @Published var textSize: Double = 15
    private let makeController: @MainActor () -> AgentSessionController
    private let store: AgentTaskStore
    private var nextNumber = 1
    private var observations: [UUID: Set<AnyCancellable>] = [:]
    private var saveTask: Task<Void, Never>?
    private var loadingHistory = false
    private var canPersist = true
    private var runtimeTransitionInProgress = false

    convenience init(settings: @escaping () -> AppSettings, storage: StorageManager,
                     thinkExecution: ThinkExecution? = nil) {
        let execution = thinkExecution ?? ThinkExecution(storage: storage)
        self.init {
            AgentSessionController(settings: settings, storage: storage, thinkExecution: execution)
        }
    }

    init(makeController: @escaping @MainActor () -> AgentSessionController) {
        self.makeController = makeController
        let first = makeController()
        store = AgentTaskStore(directory: first.sessionStorageDirectory)
        do {
            let records = try store.load()
            for (index, record) in records.enumerated() {
                let controller = index == 0 ? first : makeController()
                controller.workspace = record.workspace
                controller.draft = record.draft
                controller.attachments = record.attachments
                controller.restoreQueue(record.queuedPrompts)
                controller.restoreSources(record.sources)
                tabs.append(Tab(id: record.id, number: nextNumber, controller: controller, record: record))
                nextNumber += 1
            }
        } catch {
            canPersist = false
            self.error = "Couldn’t read task metadata. Existing metadata was preserved: \(error.localizedDescription)"
        }
        if tabs.isEmpty {
            let record = AgentTaskRecord(id: UUID(), workspace: first.workspace)
            tabs = [Tab(id: record.id, number: nextNumber, controller: first, record: record)]
            nextNumber += 1
        }
        selectedID = tabs.first(where: { !$0.record.isArchived })?.id ?? tabs[0].id
        for tab in tabs { observe(tab) }
    }

    var selectedTab: Tab? { tabs.first { $0.id == selectedID } }
    var canOpenAnotherSavedSession: Bool { true }
    func ensureSelectedController() -> AgentSessionController {
        guard let selectedTab, !selectedTab.record.isArchived else { return addSession().controller }
        return selectedTab.controller
    }

    @discardableResult func addSession() -> Tab {
        let controller = makeController()
        let record = AgentTaskRecord(id: UUID(), workspace: controller.workspace)
        let tab = Tab(id: record.id, number: nextNumber, controller: controller, record: record)
        nextNumber += 1
        tabs.append(tab); selectedID = tab.id
        observe(tab); persistSoon()
        return tab
    }

    func select(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        selectedID = id
        Task { await loadSelectedPreview(id) }
    }

    func selectNeighbor(_ offset: Int) {
        let visible = orderedTasks.filter { !$0.record.isArchived }
        guard !visible.isEmpty else { return }
        let index = visible.firstIndex { $0.id == selectedID } ?? 0
        select(visible[(index + offset + visible.count) % visible.count].id)
    }

    var orderedTasks: [Tab] {
        tabs.sorted {
            if $0.record.isPinned != $1.record.isPinned { return $0.record.isPinned }
            return $0.record.modifiedAt > $1.record.modifiedAt
        }
    }

    func rename(_ id: UUID, to title: String) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        tabs[index].record.title = clean.isEmpty ? nil : String(clean.prefix(120))
        persist()
    }

    func togglePin(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].record.isPinned.toggle(); persist()
    }

    func setArchived(_ id: UUID, _ archived: Bool) async {
        while runtimeTransitionInProgress {
            try? await Task.sleep(for: .milliseconds(10))
            if Task.isCancelled { return }
        }
        runtimeTransitionInProgress = true
        defer { runtimeTransitionInProgress = false }
        guard let tab = tabs.first(where: { $0.id == id }),
              tab.controller.state != .running, tab.controller.state != .starting else {
            error = "Stop this task before archiving it."
            return
        }
        guard await tab.controller.park() else {
            error = "This conversation has not finished saving. Try again after it is saved."
            return
        }
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].record.isArchived = archived
        if archived, selectedID == id {
            if let next = tabs.first(where: { !$0.record.isArchived }) { select(next.id) } else { _ = addSession() }
        }
        persist()
    }

    /// Read-only selection, including tasks beyond the runtime resource limit.
    func refreshHistory() async {
        guard !loadingHistory else { return }
        loadingHistory = true
        defer { loadingHistory = false }
        do {
            let saved = try await loadSavedSessions()
            for session in saved {
                if let index = tabs.firstIndex(where: {
                    $0.controller.activeSessionFile == session.fileURL || $0.record.sessionFile == session.fileURL
                }) {
                    tabs[index].saved = session
                    tabs[index].record.sessionFile = session.fileURL
                } else {
                    let controller = makeController()
                    controller.workspace = session.workspace
                    let record = AgentTaskRecord(id: UUID(), workspace: session.workspace,
                                                 sessionFile: session.fileURL, modifiedAt: session.modifiedAt)
                    let tab = Tab(id: record.id, number: nextNumber, controller: controller, record: record, saved: session)
                    nextNumber += 1; tabs.append(tab); observe(tab)
                }
            }
            await loadSelectedPreview(selectedID)
            persistSoon()
        } catch { self.error = error.localizedDescription }
    }

    private func loadSelectedPreview(_ id: UUID) async {
        guard let tab = tabs.first(where: { $0.id == id }),
              !tab.controller.hasLiveRuntime, tab.controller.items.isEmpty else { return }
        guard let saved = tab.saved else {
            if tab.record.sessionFile != nil { error = "The saved conversation is unavailable. Its draft and task metadata remain intact." }
            return
        }
        do { try await tab.controller.loadSavedPreview(saved) } catch { self.error = error.localizedDescription }
    }

    /// Serialize runtime transitions so another send cannot race an eviction.
    @discardableResult func start(_ id: UUID) async -> Bool {
        while runtimeTransitionInProgress {
            try? await Task.sleep(for: .milliseconds(10))
            if Task.isCancelled { return false }
        }
        guard let tab = tabs.first(where: { $0.id == id }), !tab.record.isArchived else { return false }
        runtimeTransitionInProgress = true
        defer { runtimeTransitionInProgress = false }
        if tab.controller.state == .ready || tab.controller.state == .running { return true }
        if tabs.filter({ $0.controller.hasLiveRuntime }).count >= Self.maximumLiveSessions {
            guard let idle = tabs.first(where: {
                $0.id != id && $0.controller.state == .ready && !$0.controller.isSending
                    && ($0.controller.items.isEmpty || $0.controller.activeSessionFile != nil)
            }) else { error = AgentSavedSessionOpenError.maximumLiveSessions.localizedDescription; return false }
            guard await idle.controller.park() else {
                error = "An idle task is still saving. Try starting this task again in a moment."
                return false
            }
        }
        // Missing saved files must not silently turn a follow-up into a fresh task.
        if let file = tab.record.sessionFile, !FileManager.default.fileExists(atPath: file.path) {
            error = AgentSavedSessionOpenError.unavailable.localizedDescription; return false
        }
        if let file = tab.record.sessionFile {
            let available = try? await loadSavedSessions()
            guard let saved = tab.saved ?? available?.first(where: { $0.fileURL == file }),
                  AgentSessionHistory.validated(saved, in: store.directory) != nil else {
                error = AgentSavedSessionOpenError.unavailable.localizedDescription; return false
            }
            if tab.controller.items.isEmpty {
                do { try await tab.controller.loadSavedPreview(saved) } catch { self.error = error.localizedDescription; return false }
            }
        }
        do { try tab.controller.prepareWorkspace() } catch {
            self.error = error.localizedDescription
            return false
        }
        guard tabs.contains(where: { $0.id == id }), !Task.isCancelled else { return false }
        await tab.controller.start()
        return tab.controller.state == .ready || tab.controller.state == .running
    }

    func loadSavedSessions() async throws -> [AgentSavedSession] {
        let directory = store.directory
        return try await Task.detached(priority: .userInitiated) { try AgentSessionHistory.load(from: directory) }.value
    }

    func isOpen(_ session: AgentSavedSession) -> Bool {
        tabs.contains { $0.controller.activeSessionFile == session.fileURL || $0.record.sessionFile == session.fileURL }
    }

    func workspaceDisplayName(for workspace: URL) -> String {
        selectedTab?.controller.workspaceDisplayName(for: workspace) ?? workspace.lastPathComponent
    }

    func openSavedSession(_ session: AgentSavedSession) async throws {
        guard let refreshed = AgentSessionHistory.validated(session, in: store.directory) else {
            throw AgentSavedSessionOpenError.unavailable
        }
        if let existing = tabs.first(where: { $0.controller.activeSessionFile == session.fileURL || $0.record.sessionFile == session.fileURL }) {
            select(existing.id); return
        }
        let tab = selectedTab?.controller.canReplaceWithSavedSession == true ? selectedTab! : addSession()
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs[index].saved = refreshed
        tabs[index].record.sessionFile = refreshed.fileURL
        tabs[index].record.workspace = refreshed.workspace
        selectedID = tab.id
        try await tab.controller.loadSavedPreview(refreshed)
        persist()
    }

    func fork(_ id: UUID, through item: AgentTranscriptItem) async {
        guard let tab = tabs.first(where: { $0.id == id }), tab.controller.state != .running,
              tab.controller.state != .starting, !tab.controller.isSending,
              let file = tab.controller.activeSessionFile ?? tab.record.sessionFile else {
            error = "Wait for this task to finish and save before branching."
            return
        }
        do {
            guard let saved = try await loadSavedSessions().first(where: { $0.fileURL == file }),
                  let index = tab.controller.items.firstIndex(where: { $0.id == item.id }) else {
                throw AgentConversationArchive.ArchiveError.unsavedMessage
            }
            let occurrence = tab.controller.items.dropFirst(index + 1).filter {
                switch ($0, item) {
                case (.user(_, let a), .user(_, let b)): a == b
                case (.assistant(_, let a, _), .assistant(_, let b, _)): a == b
                default: false
                }
            }.count
            let directory = store.directory
            let branch = try AgentConversationArchive.fork(saved, through: item,
                matchingOccurrenceFromEnd: occurrence, directory: directory)
            let new = addSession()
            try await openSavedSession(branch)
            rename(new.id, to: "Branch: \(tab.title)")
        } catch { self.error = error.localizedDescription }
    }

    /// Compatibility for callers that close a workspace: archive keeps drafts.
    func close(_ id: UUID) async { await setArchived(id, true) }

    func shutdownAll() async {
        persist()
        let controllers = tabs.map(\.controller)
        saveTask?.cancel(); saveTask = nil
        observations.removeAll()
        tabs.removeAll()
        for controller in controllers { await controller.shutdown() }
    }

    func clearSavedHistory() async throws {
        await shutdownAll()
        if FileManager.default.fileExists(atPath: store.directory.path) {
            try FileManager.default.removeItem(at: store.directory)
        }
        canPersist = true
        _ = addSession()
        persist()
    }

    private func observe(_ tab: Tab) {
        var set = Set<AnyCancellable>()
        let controller = tab.controller
        controller.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &set)
        Publishers.Merge4(controller.$draft.map { _ in () }, controller.$attachments.map { _ in () },
                          controller.$activeSessionFile.map { _ in () }, controller.$sessionTitle.map { _ in () })
            .dropFirst(4).sink { [weak self] in self?.persistSoon() }.store(in: &set)
        controller.$queuedPrompts.dropFirst().sink { [weak self] _ in self?.persistSoon() }.store(in: &set)
        controller.$state.dropFirst().sink { [weak self] state in
            guard let self, state == .running || state == .ready,
                  let index = self.tabs.firstIndex(where: { $0.id == tab.id }) else { return }
            self.tabs[index].record.modifiedAt = Date()
            self.persistSoon()
        }.store(in: &set)
        observations[tab.id] = set
    }

    private func persistSoon() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            self?.persist()
        }
    }

    func persist() {
        guard canPersist else { return }
        for index in tabs.indices {
            let controller = tabs[index].controller
            tabs[index].record.workspace = controller.workspace
            tabs[index].record.draft = controller.draft
            tabs[index].record.attachments = controller.attachments
            tabs[index].record.queuedPrompts = controller.queuedPrompts
            tabs[index].record.sources = controller.sourceAttachments
            if let file = controller.activeSessionFile { tabs[index].record.sessionFile = file }
        }
        do { try store.save(tabs.map(\.record)) } catch { self.error = "Couldn’t save task metadata: \(error.localizedDescription)" }
    }
}
