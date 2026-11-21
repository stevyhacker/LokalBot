import Foundation

@MainActor
final class AgentSessionController: ObservableObject {

    enum SessionState: Equatable {
        case idle, starting, ready, running
        case failed(String)
    }

    enum RecoveryAction: Equatable {
        case openModels
        case restart
    }

    struct ModelContext: Equatable {
        let name: String
        let destination: InferencePresentation

        init(settings: AppSettings) {
            switch ThinkExecution.agentResolution(settings: settings, includingCredentials: false) {
            case .ready(let endpoint):
                let resolved = ModelContext(endpoint: endpoint, settings: settings)
                name = resolved.name
                destination = resolved.destination
            case .builtIn(let modelID):
                name = ModelCatalog.entry(id: modelID, custom: settings.customBuiltInModels)?.displayName ?? modelID
                destination = .onDevice
            case .chatGPTPlan(let model):
                name = model
                destination = .remote(host: SubscriptionPlan.chatGPT.title)
            case .unsupported(let reason):
                name = settings.thinkModelDisplayName
                destination = .blocked(reason: reason)
            }
        }

        init(endpoint: AgentLLMEndpoint, settings: AppSettings) {
            name = settings.summarizerBackend == .builtIn
                ? ModelCatalog.entry(id: endpoint.model, custom: settings.customBuiltInModels)?.displayName ?? endpoint.model
                : endpoint.model
            if let plan = endpoint.plan {
                destination = .remote(host: plan.title)
            } else {
                destination = InferenceEndpointPolicy.isLoopback(endpoint.baseURL)
                    ? .onDevice : .remote(host: endpoint.baseURL.host ?? "configured server")
            }
        }
    }

    @Published private(set) var state: SessionState = .idle
    @Published private(set) var items: [AgentTranscriptItem] = []
    @Published private(set) var recoveryAction: RecoveryAction?
    @Published private(set) var sessionTitle: String?
    @Published private(set) var activeSessionFile: URL?
    @Published private(set) var modelContext: ModelContext? {
        didSet { policy.modelRunsOnThisMac = modelContext?.destination == .onDevice }
    }
    @Published private(set) var reasoningSupport: ReasoningSupport?
    @Published var workspace: URL
    @Published var draft = ""
    @Published var attachments: [AgentAttachment] = []
    @Published private(set) var sourceAttachments: [AgentAttachment] = []
    @Published private(set) var messageAttachments: [String: [AgentAttachment]] = [:]
    @Published private(set) var queuedPrompts: [AgentQueuedPrompt] = []
    @Published private(set) var queueIsPaused = false
    @Published private(set) var turnError: String?
    @Published private(set) var isSending = false
    @Published private(set) var isStopping = false
    @Published private(set) var failedPrompt: AgentQueuedPrompt?
    @Published var composerError: String?
    private var lastSubmittedPrompt: AgentQueuedPrompt?
    private var connectedEndpoint: URL?
    private var connectedPlan: SubscriptionPlan?
    private var queueDispatchTask: Task<Void, Never>?
    @Published var visibleTranscriptID: String?
    var contextResolver: AgentContextResolver { .init(root: storage.rootURL) }
    var pendingApprovals: [AgentApprovalRequest] {
        items.compactMap { if case .approval(let request) = $0 { request } else { nil } }
    }
    var hasLiveRuntime: Bool { state == .starting || state == .ready || state == .running }
    @Published private(set) var wasStopped = false
    private var writeTargetExisted: [String: Bool] = [:]

    func status(hasSavedConversation: Bool = false) -> AgentTaskStatus {
        let changed = state == .ready && pendingApprovals.isEmpty ? changedFiles(in: lastTurnItems).count : 0
        return .resolve(state: state, pendingApprovals: pendingApprovals.count, hasTurnError: turnError != nil,
                        wasStopped: wasStopped, items: items, hasSavedConversation: hasSavedConversation,
                        changedFiles: changed)
    }

    var taskStatus: String { status().title { $0 } ?? "Saved" }

    private var lastTurnItems: [AgentTranscriptItem] {
        let start = items.lastIndex { if case .user = $0 { true } else { false } } ?? items.startIndex
        return Array(items[start...])
    }

    func changedFiles(in steps: [AgentTranscriptItem]) -> [AgentChangedFile] {
        AgentChangedFile.list(in: steps, workspace: workspace, workspaceName: workspaceDisplayName,
                              existedBefore: writeTargetExisted)
    }

    func approvalTarget(_ request: AgentApprovalRequest) -> AgentFileTarget? {
        guard let path = request.path else { return nil }
        let origin = request.workspace.map { URL(fileURLWithPath: $0) } ?? workspace
        let asked = AgentFileTarget.resolve(path, workspace: origin, workspaceName: "")
        return AgentFileTarget.resolve(asked.url.path, workspace: workspace, workspaceName: workspaceDisplayName)
    }

    func approvalPlace(_ request: AgentApprovalRequest) -> AgentApprovalPresentation.Place {
        guard let target = approvalTarget(request) else { return .none }
        let isProtected = policy.protectedWriteRoots.contains { root in
            guard let root = AgentApprovalPolicy.canonicalFileURL(root) else { return true }
            return target.url.pathComponents.starts(with: root.pathComponents)
        }
        if isProtected { return .lokalbotData }
        return target.place == .workingFolder ? .workingFolder : .outside
    }

    func approvalTargetExists(_ request: AgentApprovalRequest) -> Bool {
        approvalTarget(request).map { FileManager.default.fileExists(atPath: $0.url.path) } ?? false
    }
    @Published private(set) var approvalMode: AgentApprovalMode {
        didSet { policy.mode = approvalMode }
    }

    static let approvalModeDefaultsKey = "lokalbotv3.agent.approvalMode"

    private let settings: () -> AppSettings
    private let storage: StorageManager
    private let runtimeRoot: URL
    private let sessionsDirectory: URL
    private let defaultWorkspace: URL
    private let broker: InferenceBroker
    private let thinkExecution: ThinkExecution
    private let makeTransport: ((PiLaunchPlan) async throws -> PiLineTransport)?
    private let accessGate: AgentAccessGate
    private let approvalModeDefaults: UserDefaults

    private var policy = AgentApprovalPolicy()
    private var folder = AgentTranscriptFolder()
    private var client: PiRPCClient?
    private var process: PiProcess?
    private var eventTask: Task<Void, Never>?
    private var deltaFlushTask: Task<Void, Never>?
    private var pendingTextDelta = ""
    private var nextRequestID = 0
    private var launchMode: LaunchMode = .fresh
    private var lifecycleGeneration = 0
    private var failureTeardownInProgress = false
    private var llmLease: InferenceLease?
    private var builtInModel: URL?
    private var modelWaits: Set<Task<InferenceLease, Error>> = []
    private var planRelay: ChatGPTPlanRelay?
    private var accessCapability: AgentAccessCapability?
    private let reasoningLevelFile = FileManager.default.temporaryDirectory
        .appendingPathComponent("lokalbot-agent-reasoning-\(UUID().uuidString).json")
    private var writtenReasoningLevel: ThinkReasoningLevel?

    init(settings: @escaping () -> AppSettings,
         storage: StorageManager,
         runtimeRoot: URL = AgentRuntimeLayout.defaultRoot,
         sessionsDirectory: URL = AgentRuntimeLayout.sessionsDirectory,
         defaultWorkspace: URL? = nil,
         broker: InferenceBroker = .shared,
         thinkExecution: ThinkExecution? = nil,
         accessGate: AgentAccessGate? = nil,
         makeTransport: ((PiLaunchPlan) async throws -> PiLineTransport)? = nil,
         approvalModeDefaults: UserDefaults? = nil) {
        let defaults = approvalModeDefaults ?? Self.defaultApprovalModeDefaults
        let restoredMode = (defaults.object(forKey: Self.approvalModeDefaultsKey) as? Int)
            .flatMap(AgentApprovalMode.init(rawValue:)) ?? .askBeforeChanges
        self.settings = settings
        self.storage = storage
        self.runtimeRoot = runtimeRoot
        self.sessionsDirectory = sessionsDirectory
        self.defaultWorkspace = defaultWorkspace ?? AppDirectories.agentWorkspace(forLibraryRoot: storage.rootURL)
        self.broker = broker
        self.thinkExecution = thinkExecution ?? ThinkExecution(storage: storage)
        self.accessGate = accessGate ?? AgentAccessGate(root: storage.rootURL)
        self.makeTransport = makeTransport
        self.approvalModeDefaults = defaults
        self.approvalMode = restoredMode
        self.policy = AgentApprovalPolicy(
            mode: restoredMode,
            protectedWriteRoots: [storage.rootURL, AppDirectories.applicationSupport,
                                  sessionsDirectory, runtimeRoot, Bundle.main.bundleURL])
        self.workspace = self.defaultWorkspace
    }

    private static var defaultApprovalModeDefaults: UserDefaults {
        if let suite = UITestRuntime.defaultsSuiteName,
           let defaults = UserDefaults(suiteName: suite) {
            return defaults
        }
        return .standard
    }

    func start() async {
        guard !failureTeardownInProgress,
              state == .idle || isFailed else { return }
        do { try prepareWorkspace() } catch {
            composerError = error.localizedDescription
            return
        }
        let configuration = settings()
        modelContext = ModelContext(settings: configuration)
#if LOKALBOT_UI_TEST_HOST
        if ProcessInfo.processInfo.environment["LOKALBOT_AGENT_UI_TEST_APPROVAL"] == "1" {
            lifecycleGeneration += 1
            let rpc = PiRPCClient(transport: AgentUITestTransport(workspace: storage.rootURL))
            await rpc.run()
            client = rpc
            recoveryAction = nil
            state = .ready
            consumeEvents(from: rpc, generation: lifecycleGeneration)
            return
        }
        if ProcessInfo.processInfo.environment["LOKALBOT_AGENT_UI_TEST_READY"] == "1" {
            recoveryAction = nil
            state = .ready
            return
        }
#endif
        lifecycleGeneration += 1
        let generation = lifecycleGeneration
        state = .starting
        recoveryAction = nil
        do {
            let support = await ReasoningSupport.resolve(for: configuration)
            guard generation == lifecycleGeneration else { return }
            reasoningSupport = support
            writtenReasoningLevel = nil
            writeReasoningLevel()
            let endpoint = try await resolveEndpoint(settings: configuration)
            guard generation == lifecycleGeneration else {
                releaseModelConnection()
                return
            }
            modelContext = ModelContext(endpoint: endpoint, settings: configuration)
            connectedEndpoint = endpoint.baseURL
            connectedPlan = endpoint.plan
            var capabilityToken: String?
            if makeTransport == nil {
                let root = runtimeRoot
                let integrityValid = await Task.detached(priority: .utility) {
                    AgentRuntimeLayout.isIntegrityValid(under: root)
                }.value
                guard generation == lifecycleGeneration else { return }
                guard integrityValid else {
                    throw NSError(domain: "AgentRuntime", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: "The Agent runtime changed since installation. Repair it in Settings before starting this task.",
                    ])
                }
                accessGate.removeExpiredCapabilities()
                let capability = try accessGate.issueScopedCapability()
                accessCapability = capability
                capabilityToken = capability.token
            }
            let plan = makePlan(endpoint: endpoint, capabilityToken: capabilityToken)
            let transport: PiLineTransport
            var spawnedProcess: PiProcess?
            if let makeTransport {
                transport = try await makeTransport(plan)
            } else {
                let piProcess = PiProcess(plan: plan)
                try await piProcess.start()
                spawnedProcess = piProcess
                transport = piProcess
            }
            guard generation == lifecycleGeneration else {
                await spawnedProcess?.stop()
                return
            }
            process = spawnedProcess
            let rpc = PiRPCClient(transport: transport)
            await rpc.run()
            guard generation == lifecycleGeneration else {
                await spawnedProcess?.stop()
                return
            }
            client = rpc
            consumeEvents(from: rpc, generation: generation)
            captureActiveSessionFile(using: rpc, generation: generation)
            switch launchMode {
            case .fresh:
                break
            case .continueRecent:
                await restorePreviousMessages(
                    using: rpc,
                    resumedNotice: "Resumed the most recent session for this working folder.")
            case .saved(let session):
                if items.isEmpty {
                    await restorePreviousMessages(
                    using: rpc,
                    resumedNotice: "Resumed \"\(session.title)\".")
                }
            }
            guard generation == lifecycleGeneration else { return }
            state = .ready
            releaseModelBetweenTurns()
        } catch {
            guard generation == lifecycleGeneration else { return }
            revokeAccessCapability()
            setFailure(error)
        }
    }

    func shutdown() async {
        while failureTeardownInProgress {
            try? await Task.sleep(for: .milliseconds(10))
        }
        lifecycleGeneration += 1
        queueIsPaused = true
        queueDispatchTask?.cancel()
        queueDispatchTask = nil
        isSending = false
        isStopping = false
        await cancelPendingApprovals()
        eventTask?.cancel()
        eventTask = nil
        discardPendingTextDelta()
        revokeAccessCapability()
        await process?.stop()
        process = nil
        client = nil
        activeSessionFile = nil
        modelContext = nil
        resetApprovalPolicy()
        releaseModelConnection()
        try? FileManager.default.removeItem(at: reasoningLevelFile)
        writtenReasoningLevel = nil
        reasoningSupport = nil
        state = .idle
    }

    func queueDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, queuedPrompts.count < 20 else {
            composerError = "Keep up to 20 follow-ups in the queue."
            return
        }
        queuedPrompts.append(.init(text: text, attachments: attachments))
        draft = ""; attachments = []
        queueIsPaused = queueIsPaused || isStopping || turnError != nil
    }

    func restoreSources(_ sources: [AgentAttachment]) { sourceAttachments = sources }

    func restoreQueue(_ prompts: [AgentQueuedPrompt]) {
        queuedPrompts = prompts; queueIsPaused = true
    }

    func cancelQueued(_ id: UUID) { queuedPrompts.removeAll { $0.id == id } }

    func editQueued(_ id: UUID) {
        guard draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, attachments.isEmpty else {
            composerError = "Send or clear the current draft before editing a queued message."
            return
        }
        guard let queued = queuedPrompts.first(where: { $0.id == id }) else { return }
        draft = queued.text; attachments = queued.attachments
        cancelQueued(id)
    }

    @discardableResult
    func sendQueuedNow(_ id: UUID) async -> Bool {
        guard let index = queuedPrompts.firstIndex(where: { $0.id == id }),
              state == .ready || state == .running, !isSending, !isStopping else { return false }
        let prompt = queuedPrompts.remove(at: index)
        let sent = await send(prompt: prompt.text, attachments: prompt.attachments, steer: state == .running)
        if !sent, !queuedPrompts.contains(where: { $0.id == id }) {
            queuedPrompts.insert(prompt, at: min(index, queuedPrompts.count))
        }
        return sent
    }

    func addAttachment(_ attachment: AgentAttachment) {
        guard !attachments.contains(where: { $0.id == attachment.id }) else { return }
        guard attachments.count < AgentContextResolver.maximumAttachments else {
            composerError = AgentContextResolver.ContextError.tooMany.localizedDescription
            return
        }
        attachments.append(attachment)
    }

    func reviewRetry() {
        guard let failedPrompt else { return }
        guard draft.isEmpty, attachments.isEmpty else {
            composerError = "Send or clear the current draft before restoring the failed prompt."
            return
        }
        draft = failedPrompt.text; attachments = failedPrompt.attachments
        composerError = "Review before sending again. Earlier completed actions are not undone and may be repeated."
    }

    func editAsFollowUp(_ item: AgentTranscriptItem) {
        guard case .user(_, let text) = item else { return }
        guard draft.isEmpty, attachments.isEmpty else {
            composerError = "Send or clear the current draft first."
            return
        }
        draft = text
        attachments = messageAttachments[item.id] ?? []
    }

    func reviewResponseRetry(_ item: AgentTranscriptItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }),
              let prompt = items[..<index].last(where: { if case .user = $0 { true } else { false } }) else { return }
        editAsFollowUp(prompt)
        if draft == prompt.searchableText {
            composerError = "Review before sending again. Earlier completed actions are not undone and may be repeated."
        }
    }

    @discardableResult
    func send(prompt: String, attachments sources: [AgentAttachment] = [], steer: Bool = false) async -> Bool {
        guard let client, !isSending, !isStopping, state == .ready || state == .running else { return false }
        let generation = lifecycleGeneration
        let wasRunning = state == .running
        let pending = AgentQueuedPrompt(text: prompt, attachments: sources)
        let wirePrompt: String
        do {
            try requireApprovedDestination()
            wirePrompt = try contextResolver.prompt(prompt, attachments: sources)
        } catch {
            composerError = error.localizedDescription
            return false
        }
        isSending = true
        defer { if generation == lifecycleGeneration { isSending = false } }
        do {
            try await holdModelForTurn()
        } catch {
            if generation == lifecycleGeneration {
                composerError = error is CancellationError
                    ? "Stopped while waiting for the model. Nothing was sent."
                    : Self.message(for: error)
            }
            return false
        }
        guard generation == lifecycleGeneration else { return false }
        lastSubmittedPrompt = pending
        composerError = nil
        turnError = nil
        wasStopped = false
        queueIsPaused = false
        if sessionTitle == nil { sessionTitle = Self.makeSessionTitle(from: prompt) }
        folder.noteUserPrompt(prompt)
        if let item = folder.items.last { messageAttachments[item.id] = sources }
        publish()
        for source in sources where !sourceAttachments.contains(where: { $0.id == source.id }) {
            sourceAttachments.append(source)
        }
        state = .running
        do {
            writeReasoningLevel()
            let command: PiCommand = steer && wasRunning
                ? .steer(id: freshID("steer"), message: wirePrompt)
                : .prompt(id: freshID("p"), message: wirePrompt, streamingBehavior: wasRunning ? "followUp" : nil)
            let response = try await client.request(command)
            guard generation == lifecycleGeneration else { return false }
            if !response.success {
                failedPrompt = pending
                queueIsPaused = true
                if !wasRunning {
                    state = .ready
                    releaseModelBetweenTurns()
                }
                composerError = response.error ?? "The agent rejected this message. Review it before retrying."
                folder.appendNotice(composerError!, isError: true)
                publish()
                return false
            }
            if turnError == nil { failedPrompt = nil }
            return true
        } catch {
            guard generation == lifecycleGeneration else { return false }
            failedPrompt = pending
            queueIsPaused = true
            await fail(with: error)
            return false
        }
    }

    private func requireApprovedDestination() throws {
        let configuration = settings()
        if let connectedEndpoint {
            try InferenceEndpointPolicy.validate(connectedEndpoint,
                approvedOrigins: configuration.approvedRemoteInferenceOrigins)
        }
        if let connectedPlan, !connectedPlan.isApproved(in: configuration) {
            throw SubscriptionPlanError.approvalRequired(connectedPlan)
        }
    }

    func remoteApprovalsDidChange() async {
        guard state == .running || isSending else { return }
        do {
            try requireApprovedDestination()
        } catch {
            flushPendingTextDelta()
            await transitionToFailure(message: Self.message(for: error), recovery: .openModels)
        }
    }

    func deliverNextQueued() async {
        guard !Task.isCancelled, state == .ready, !isSending, !queuedPrompts.isEmpty else { return }
        let next = queuedPrompts.removeFirst()
        if !(await send(prompt: next.text, attachments: next.attachments)) {
            queuedPrompts.insert(next, at: 0)
            queueIsPaused = true
        }
    }

    private func scheduleQueuedDelivery() {
        guard !queueIsPaused, !queuedPrompts.isEmpty, queueDispatchTask == nil else { return }
        queueDispatchTask = Task { [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            while self.isSending && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(20))
            }
            guard !Task.isCancelled else { return }
            guard !self.queueIsPaused else { self.queueDispatchTask = nil; return }
            await self.deliverNextQueued()
            self.queueDispatchTask = nil
            if self.state == .ready { self.scheduleQueuedDelivery() }
        }
    }

    func abort() async {
        queueIsPaused = true
        for wait in modelWaits { wait.cancel() }
        if !isSending { queueDispatchTask?.cancel(); queueDispatchTask = nil }
        guard let client, !isStopping else { return }
        let generation = lifecycleGeneration
        isStopping = true
        if state == .running { wasStopped = true }
        defer { if generation == lifecycleGeneration { isStopping = false } }
        await cancelPendingApprovals()
        _ = try? await client.request(.abort(id: freshID("a")))
    }

    @discardableResult func park() async -> Bool {
        guard state != .running, state != .starting, !isSending else { return false }
        let saved = activeSessionFile.flatMap { file in
            (try? AgentSessionHistory.load(from: sessionsDirectory))?.first { $0.fileURL == file }
        }
        guard !hasLiveRuntime || items.isEmpty || saved != nil else { return false }
        await shutdown()
        if let saved { activeSessionFile = saved.fileURL; launchMode = .saved(saved) }
        return true
    }

    func loadSavedPreview(_ session: AgentSavedSession) async throws {
        guard !hasLiveRuntime else { return }
        let generation = lifecycleGeneration
        let directory = sessionsDirectory
        let restored = try await Task.detached(priority: .userInitiated) {
            try AgentConversationArchive.preview(for: session, directory: directory)
        }.value
        guard generation == lifecycleGeneration, !hasLiveRuntime else { return }
        folder = restored.folder
        messageAttachments = restored.attachments
        for source in restored.attachments.values.flatMap({ $0 }) where !sourceAttachments.contains(where: { $0.id == source.id }) {
            sourceAttachments.append(source)
        }
        workspace = session.workspace
        sessionTitle = session.title
        activeSessionFile = session.fileURL
        launchMode = .saved(session)
        publish()
    }

    func resumePreviousSession() async {
        guard canResumePreviousSession else { return }
        await shutdown()
        discardPendingTextDelta()
        folder = AgentTranscriptFolder()
        wasStopped = false
        writeTargetExisted.removeAll()
        resetApprovalPolicy()
        sessionTitle = nil
        draft = ""
        publish()
        launchMode = .continueRecent
        await start()
    }

    func resumeSavedSession(_ session: AgentSavedSession) async {
        await shutdown()
        discardPendingTextDelta()
        folder = AgentTranscriptFolder()
        wasStopped = false
        writeTargetExisted.removeAll()
        resetApprovalPolicy()
        workspace = session.workspace
        sessionTitle = session.title
        activeSessionFile = session.fileURL
        draft = ""
        publish()
        launchMode = .saved(session)
        await start()
    }

    func setApprovalMode(_ mode: AgentApprovalMode) async {
        guard approvalMode != mode else { return }
        policy.resetSession()
        approvalMode = mode
        approvalModeDefaults.set(mode.rawValue, forKey: Self.approvalModeDefaultsKey)

        let pendingRequests = folder.items.compactMap { item -> AgentApprovalRequest? in
            if case .approval(let request) = item { return request }
            return nil
        }
        for request in pendingRequests where policy.verdict(
            tool: request.tool,
            path: request.path,
            command: request.command,
            requestWorkspace: request.workspace,
            selectedWorkspace: workspace) == .allow {
            await respondToApproval(id: request.id, approved: true, scope: .once)
        }
    }

    var allowsLibraryLookups: Bool {
        get { policy.allowsLibraryLookups }
        set { policy.allowsLibraryLookups = newValue }
    }

    func approveWorkspaceFileChangesForAutomation() {
        policy.approveWorkspaceFileChangesForAutomation()
    }

    func respondToApproval(id: String, approved: Bool, scope: ApprovalScope) async {
        guard let client else { return }
        guard let request = pendingApprovalRequest(requestID: id) else { return }
        let approved = approved && request.canApprove
        if approved, scope == .session {
            policy.allowForSession(
                tool: request.tool,
                path: request.path,
                requestWorkspace: request.workspace,
                selectedWorkspace: workspace)
        }
        folder.resolveApproval(requestID: id)
        if !approved {
            folder.appendNotice("You denied this \(request.tool) request. Nothing changed.")
        }
        publish()
        try? await client.sendResponse(.uiConfirmResponse(requestID: id, confirmed: approved))
    }

    func denyAllPendingApprovals() async {
        for id in folder.pendingApprovalIDs {
            await respondToApproval(id: id, approved: false, scope: .once)
        }
    }

    private func consumeEvents(from client: PiRPCClient, generation: Int) {
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            guard let self else { return }
            for await event in client.events {
                guard !Task.isCancelled else { return }
                await self.handle(event, generation: generation)
            }
            guard !Task.isCancelled else { return }
            await self.handleStreamEnd(generation: generation)
        }
    }

    private func handle(_ event: PiEvent, generation: Int) async {
        guard generation == lifecycleGeneration,
              state != .idle,
              !isFailed else { return }
        if case .messageUpdate(.textDelta(let delta)) = event {
            enqueueTextDelta(delta)
            return
        }
        flushPendingTextDelta()

        switch event {
        case .agentStart:
            state = .running
            turnError = nil
            wasStopped = false
            holdModelForStartedTurn()
        case .toolExecutionStart(let callID, let name, let argsJSON):
            noteWriteTarget(callID: callID, tool: name, argsJSON: argsJSON)
        case .agentSettled:
            state = .ready
            releaseModelBetweenTurns()
        case .extensionUIRequest(let request):
            await handleUIRequest(request)
        default:
            break
        }
        folder.fold(event)
        if event == .agentSettled, let failure = folder.terminalFailure {
            turnError = failure
            queueIsPaused = true
            failedPrompt = lastSubmittedPrompt
        }
        publish()
        if event == .agentSettled { scheduleQueuedDelivery() }
    }

    private func noteWriteTarget(callID: String, tool: String, argsJSON: String) {
        guard tool.lowercased() == "write", let path = AgentStepWording.arguments(argsJSON).path else { return }
        if writeTargetExisted.count > AgentTranscriptFolder.maximumItems { writeTargetExisted.removeAll() }
        let target = AgentFileTarget.resolve(path, workspace: workspace, workspaceName: workspaceDisplayName)
        writeTargetExisted[callID] = FileManager.default.fileExists(atPath: target.url.path)
    }

    private func handleUIRequest(_ request: PiUIRequest) async {
        guard let client else { return }
        if isStopping {
            try? await client.sendResponse(.uiCancelResponse(requestID: request.id))
            return
        }
        guard request.method == "confirm" else {
            folder.appendNotice("The agent asked for an unsupported interaction (\(request.method)); declined.", isError: false)
            try? await client.sendResponse(.uiCancelResponse(requestID: request.id))
            return
        }
        let approval = Self.parseApprovalPayload(request)
        guard approval.canApprove else {
            let subject = approval.arguments == nil ? "The shell command" : "The \(approval.tool) request"
            folder.appendNotice("\(subject) could not be reviewed in full and was declined. Nothing ran.", isError: true)
            try? await client.sendResponse(.uiConfirmResponse(requestID: request.id, confirmed: false))
            return
        }
        switch policy.verdict(
            tool: approval.tool,
            path: approval.path,
            command: approval.command,
            requestWorkspace: approval.workspace,
            selectedWorkspace: workspace) {
        case .allow:
            try? await client.sendResponse(.uiConfirmResponse(requestID: request.id, confirmed: true))
        case .ask:
            if !folder.addApproval(approval) {
                folder.appendNotice(
                    "The newest tool approval exceeded safety limits or too many are already waiting; it was declined.",
                    isError: true)
                try? await client.sendResponse(.uiCancelResponse(requestID: request.id))
            }
        }
    }

    private func handleStreamEnd(generation: Int) async {
        guard generation == lifecycleGeneration,
              state != .idle,
              !isFailed else { return }
        flushPendingTextDelta()
        var detail = "The agent process exited unexpectedly."
        if let process {
            let tail = await process.stderrTail
            if !tail.isEmpty { detail += "\n" + tail.suffix(5).joined(separator: "\n") }
        }
        guard generation == lifecycleGeneration else { return }
        await transitionToFailure(message: detail, recovery: .restart)
    }

    private func resolveEndpoint(settings configuration: AppSettings) async throws -> AgentLLMEndpoint {
        releaseModelConnection()
        let connection = try await thinkExecution.prepareAgentConnection(
            settings: configuration,
            includingCredentials: makeTransport == nil,
            broker: broker)
        llmLease = connection.lease
        builtInModel = connection.lease.map { URL(fileURLWithPath: $0.modelPath) }
        planRelay = connection.relay
        return connection.endpoint
    }

    private func holdModelForTurn() async throws {
        guard let builtInModel, llmLease == nil else { return }
        let generation = lifecycleGeneration
        let broker = broker
        let wait = Task {
            try await broker.lease(.mainLLM, model: builtInModel, priority: .interactive,
                                   purpose: "agent session")
        }
        modelWaits.insert(wait)
        let lease: InferenceLease
        do {
            lease = try await wait.value
        } catch {
            modelWaits.remove(wait)
            throw error
        }
        modelWaits.remove(wait)
        guard generation == lifecycleGeneration else {
            await broker.release(lease)
            throw CancellationError()
        }
        guard llmLease == nil else {
            await broker.release(lease)
            return
        }
        llmLease = lease
    }

    private func holdModelForStartedTurn() {
        guard builtInModel != nil, llmLease == nil, modelWaits.isEmpty else { return }
        Task {
            try? await self.holdModelForTurn()
            if self.state != .running, !self.isSending { self.releaseModelBetweenTurns() }
        }
    }

    private func releaseModelBetweenTurns() {
        guard let lease = llmLease else { return }
        llmLease = nil
        let broker = self.broker
        Task { await broker.release(lease) }
    }

    func reasoningLevelDidChange() {
        guard reasoningSupport != nil else { return }
        writeReasoningLevel()
    }

    private func writeReasoningLevel() {
        guard let reasoningSupport else { return }
        let level = reasoningSupport.clamp(settings().effectiveAgentReasoningLevel) ?? .automatic
        guard level != writtenReasoningLevel else { return }
        do {
            let data = try JSONSerialization.data(withJSONObject: [
                "level": level.rawValue,
                "defaultOff": reasoningSupport.defaultLevel == .off,
            ])
            try data.write(to: reasoningLevelFile, options: .atomic)
            writtenReasoningLevel = level
        } catch {
            lokalbotLog("agent reasoning level write failed: \(error.localizedDescription)")
        }
    }

    private func makePlan(endpoint: AgentLLMEndpoint, capabilityToken: String?) -> PiLaunchPlan {
        let resources = Bundle.main.resourceURL
        let extensionDir = resources?.appendingPathComponent("pi/lokalbot-extension")
            ?? URL(fileURLWithPath: "pi/lokalbot-extension")
        let skillDir = resources?.appendingPathComponent("pi/lokalbot-cli-skill")
        let skillExists = skillDir.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        let systemPrompt = resources?.appendingPathComponent("pi/system-prompt.md")
        let systemPromptExists = systemPrompt.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        let helpers = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers")
        let sessions = sessionsDirectory
        try? FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        return PiLaunchPlanner.plan(
            bun: AgentRuntimeLayout.bunBinary(under: runtimeRoot),
            piCLI: AgentRuntimeLayout.piCLI(under: runtimeRoot),
            extensionDirectory: extensionDir,
            skillDirectory: skillExists ? skillDir : nil,
            systemPrompt: systemPromptExists ? systemPrompt : nil,
            sessionDirectory: sessions,
            workspace: workspace,
            workspaceKind: workspace.standardizedFileURL == defaultWorkspace.standardizedFileURL
                ? .agentWorkspace : .chosenFolder,
            endpoint: endpoint,
            reasoningLevelFile: reasoningLevelFile,
            helpersDirectory: FileManager.default.fileExists(atPath: helpers.path) ? helpers : nil,
            privateRoots: privateWorkspaceRoots,
            agentAccessCapability: capabilityToken,
            continuePreviousSession: launchMode.isContinueRecent,
            specificSession: launchMode.specificSession)
    }

    private func captureActiveSessionFile(using client: PiRPCClient, generation: Int) {
        guard makeTransport == nil else { return }
        let requestID = freshID("session-file")
        Task { [weak self] in
            guard let response = try? await client.request(.getSessionStats(id: requestID)),
                  response.success,
                  let file = Self.sessionFile(from: response.dataJSON),
                  let self,
                  generation == self.lifecycleGeneration else { return }
            let expectedDirectory = self.sessionsDirectory.standardizedFileURL
                .resolvingSymlinksInPath().path
            let actualDirectory = file.deletingLastPathComponent().standardizedFileURL
                .resolvingSymlinksInPath().path
            guard actualDirectory == expectedDirectory else { return }
            self.activeSessionFile = file.standardizedFileURL
        }
    }

    private static func sessionFile(from dataJSON: String?) -> URL? {
        guard let dataJSON,
              let data = dataJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = object["sessionFile"] as? String,
              !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    private var isFailed: Bool {
        if case .failed = state { return true } else { return false }
    }

    private func publish() {
        folder.enforceResourceLimits()
        items = folder.items
    }

    private func enqueueTextDelta(_ delta: String) {
        let room = max(0, AgentTranscriptFolder.maximumMessageCharacters - pendingTextDelta.count)
        if room > 0 { pendingTextDelta.append(contentsOf: delta.prefix(room)) }
        guard deltaFlushTask == nil else { return }
        deltaFlushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(33))
            guard !Task.isCancelled else { return }
            self?.flushPendingTextDelta()
        }
    }

    private func flushPendingTextDelta() {
        deltaFlushTask?.cancel()
        deltaFlushTask = nil
        guard !pendingTextDelta.isEmpty else { return }
        let delta = pendingTextDelta
        pendingTextDelta = ""
        folder.fold(.messageUpdate(.textDelta(delta)))
        publish()
    }

    private func discardPendingTextDelta() {
        deltaFlushTask?.cancel()
        deltaFlushTask = nil
        pendingTextDelta = ""
    }

    private func releaseModelConnection() {
        planRelay?.stop()
        planRelay = nil
        builtInModel = nil
        for wait in modelWaits { wait.cancel() }
        modelWaits.removeAll()
        guard let lease = llmLease else { return }
        llmLease = nil
        let broker = self.broker
        Task { await broker.release(lease) }
    }

    private func revokeAccessCapability() {
        guard let capability = accessCapability else { return }
        accessCapability = nil
        accessGate.revoke(capability)
    }

    private func cancelPendingApprovals() async {
        let ids = folder.pendingApprovalIDs
        if let client {
            for id in ids {
                try? await client.sendResponse(.uiCancelResponse(requestID: id))
            }
        }
        folder.resolveAllApprovals()
        publish()
    }

    private func freshID(_ prefix: String) -> String {
        nextRequestID += 1
        return "\(prefix)\(nextRequestID)"
    }

    private func pendingApprovalRequest(requestID: String) -> AgentApprovalRequest? {
        for item in folder.items {
            if case .approval(let request) = item, request.id == requestID { return request }
        }
        return nil
    }

    func canAllowForSession(_ request: AgentApprovalRequest) -> Bool {
        request.canApprove && AgentApprovalPolicy.canPersistApproval(
            tool: request.tool,
            path: request.path,
            requestWorkspace: request.workspace,
            selectedWorkspace: workspace,
            protectedWriteRoots: policy.protectedWriteRoots)
    }

    private func fail(with error: Error) async {
        flushPendingTextDelta()
        let message = Self.message(for: error)
        await transitionToFailure(message: message, recovery: .restart)
    }

    private func transitionToFailure(message: String, recovery: RecoveryAction) async {
        guard !failureTeardownInProgress,
              state != .idle,
              !isFailed else { return }
        failureTeardownInProgress = true
        lifecycleGeneration += 1
        let failureGeneration = lifecycleGeneration
        recoveryAction = nil
        eventTask?.cancel()
        eventTask = nil
        discardPendingTextDelta()
        let oldProcess = process
        process = nil
        client = nil
        if let file = activeSessionFile,
           let saved = (try? AgentSessionHistory.load(from: sessionsDirectory))?.first(where: { $0.fileURL == file }) {
            launchMode = .saved(saved)
        }
        modelContext = nil
        queueIsPaused = true
        isSending = false
        isStopping = false
        folder.resolveAllApprovals()
        resetApprovalPolicy()
        revokeAccessCapability()
        if failedPrompt == nil { failedPrompt = lastSubmittedPrompt }
        folder.appendNotice(message, isError: true)
        publish()
        releaseModelConnection()
        await oldProcess?.stop()
        failureTeardownInProgress = false
        guard failureGeneration == lifecycleGeneration else { return }
        state = .failed(message)
        recoveryAction = recovery
    }

    private func setFailure(_ error: Error) {
        isStopping = false
        folder.resolveAllApprovals()
        activeSessionFile = nil
        modelContext = nil
        resetApprovalPolicy()
        revokeAccessCapability()
        releaseModelConnection()
        state = .failed(Self.message(for: error))
        if case ThinkExecutionError.agentConfiguration = error {
            recoveryAction = .openModels
        } else {
            recoveryAction = .restart
        }
    }

    private func resetApprovalPolicy() {
        policy.resetSession()
        policy.mode = approvalMode
    }

    static func parseApprovalPayload(_ request: PiUIRequest) -> AgentApprovalRequest {
        if request.title == "lokalbot_tool_approval",
           let data = request.message?.data(using: .utf8),
           let payload = try? JSONDecoder().decode(ApprovalPayload.self, from: data) {
            return AgentApprovalRequest(
                id: request.id,
                tool: payload.tool,
                workspace: payload.workspace,
                path: payload.path,
                command: payload.command,
                content: payload.content,
                edits: (payload.edits ?? []).map {
                    AgentApprovalRequest.Edit(oldText: $0.oldText, newText: $0.newText)
                },
                summary: payload.summary,
                isTruncated: payload.truncated ?? false,
                arguments: payload.arguments)
        }
        return AgentApprovalRequest(
            id: request.id,
            tool: request.title ?? "action",
            workspace: nil,
            path: nil,
            command: nil,
            content: nil,
            edits: [],
            summary: request.message,
            isTruncated: false)
    }

    var workspaceDisplayName: String {
        workspaceDisplayName(for: workspace)
    }

    func workspaceDisplayName(for workspace: URL) -> String {
        if AgentWorkspacePolicy(privateRoots: privateWorkspaceRoots).containsPrivateWorkspace(workspace) {
            return "Private Library · read-only"
        }
        if workspace.standardizedFileURL == defaultWorkspace.standardizedFileURL {
            return "Agent Workspace"
        }
        return workspace.lastPathComponent.isEmpty ? workspace.path : workspace.lastPathComponent
    }

    var requiresCloseConfirmation: Bool {
        state == .running
            || !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !items.isEmpty
    }

    var canReplaceWithSavedSession: Bool {
        state == .idle
            && sessionTitle == nil
            && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && attachments.isEmpty
            && queuedPrompts.isEmpty
            && items.isEmpty
    }

    var canResumePreviousSession: Bool {
        workspaceAccessNotice == nil && Self.hasResumableSession(in: sessionsDirectory, workspace: workspace)
    }

    var sessionStorageDirectory: URL { sessionsDirectory }

    private var privateWorkspaceRoots: [URL] {
        [storage.rootURL, AppDirectories.applicationSupport, sessionsDirectory, runtimeRoot]
    }

    var workspaceAccessNotice: String? { workspaceAccessNotice(for: workspace) }

    func workspaceAccessNotice(for proposed: URL) -> String? {
        AgentWorkspacePolicy(privateRoots: privateWorkspaceRoots).containsPrivateWorkspace(proposed)
            ? AgentWorkspacePolicy.privateWorkspaceNotice : nil
    }

    func prepareWorkspace() throws {
        if let notice = workspaceAccessNotice {
            throw WorkspaceError.unavailable(notice)
        }
        if workspace.standardizedFileURL == defaultWorkspace.standardizedFileURL {
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        guard workspaceAccessNotice == nil else {
            throw WorkspaceError.unavailable(AgentWorkspacePolicy.privateWorkspaceNotice)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: workspace.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw WorkspaceError.unavailable("The task’s working folder no longer exists. Choose a new folder before sending.")
        }
    }

    private enum WorkspaceError: LocalizedError {
        case unavailable(String)
        var errorDescription: String? {
            switch self {
            case .unavailable(let message): message
            }
        }
    }

    static func hasResumableSession(in directory: URL, workspace: URL) -> Bool {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return false }
        let expectedCWD = workspace.standardizedFileURL.path
        for file in files where file.pathExtension == "jsonl" {
            guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
            defer { try? handle.close() }
            guard let data = try? handle.read(upToCount: 16 * 1024),
                  let firstLine = data.split(separator: 0x0A).first,
                  let header = try? JSONSerialization.jsonObject(with: Data(firstLine)) as? [String: Any],
                  header["type"] as? String == "session",
                  let cwd = header["cwd"] as? String else { continue }
            if URL(fileURLWithPath: cwd).standardizedFileURL.path == expectedCWD {
                return true
            }
        }
        return false
    }

    private static func makeSessionTitle(from prompt: String) -> String {
        let firstLine = prompt.split(whereSeparator: { $0.isNewline }).first.map(String.init) ?? prompt
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 36 else { return trimmed }
        let prefix = String(trimmed.prefix(35))
        let wordBoundary = prefix.lastIndex(of: " ").map { String(prefix[..<$0]) } ?? prefix
        return wordBoundary.trimmingCharacters(in: .whitespaces) + "…"
    }

    private struct ApprovalPayload: Decodable {
        struct Edit: Decodable {
            let oldText: String
            let newText: String
        }

        let tool: String
        let workspace: String?
        let path: String?
        let command: String?
        let content: String?
        let edits: [Edit]?
        let summary: String?
        let truncated: Bool?
        let arguments: String?
    }

    private enum LaunchMode {
        case fresh
        case continueRecent
        case saved(AgentSavedSession)

        var isContinueRecent: Bool {
            if case .continueRecent = self { return true }
            return false
        }

        var specificSession: URL? {
            if case .saved(let session) = self { return session.fileURL }
            return nil
        }
    }

    private func restorePreviousMessages(
        using client: PiRPCClient,
        resumedNotice: String
    ) async {
        do {
            let response = try await client.request(.getMessages(id: freshID("history")))
            guard response.success else {
                folder.appendNotice(response.error ?? "Couldn't restore the previous session.", isError: true)
                publish()
                return
            }
            let messages = Self.historyMessages(from: response.dataJSON)
            guard !messages.isEmpty else {
                folder.appendNotice("No previous conversation was found for this working folder.")
                publish()
                return
            }
            folder = AgentTranscriptFolder()
            for message in messages {
                switch message.role {
                case "user":
                    if sessionTitle == nil { sessionTitle = Self.makeSessionTitle(from: message.text) }
                    folder.noteUserPrompt(AgentContextResolver.displayPrompt(message.text))
                case "assistant":
                    if !message.text.isEmpty { folder.appendAssistantMessage(message.text) }
                    if let failure = message.failure { folder.appendNotice(failure, isError: true) }
                default:
                    break
                }
            }
            folder.appendNotice(resumedNotice)
            publish()
        } catch {
            folder.appendNotice("Couldn't restore the previous session: \(Self.message(for: error))",
                                isError: true)
            publish()
        }
    }

    private static func historyMessages(from dataJSON: String?) -> [(role: String, text: String, failure: String?)] {
        guard let dataJSON,
              let data = dataJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messages = object["messages"] as? [[String: Any]] else { return [] }
        return messages.compactMap { message in
            guard let role = message["role"] as? String,
                  role == "user" || role == "assistant" else { return nil }
            let text: String
            if let content = message["content"] as? String {
                text = content
            } else if let blocks = message["content"] as? [[String: Any]] {
                text = blocks.compactMap { block in
                    block["type"] as? String == "text" ? block["text"] as? String : nil
                }.joined()
            } else {
                return nil
            }
            let failure = role == "assistant" ? PiEvent.terminalFailure(
                stopReason: message["stopReason"] as? String,
                errorMessage: message["errorMessage"] as? String) : nil
            guard !text.isEmpty || failure != nil else { return nil }
            return (role, text, failure)
        }
    }

    private static func message(for error: Error) -> String {
        switch error {
        case ThinkExecutionError.agentConfiguration(let reason): return reason
        case PiProcessError.executableNotFound:
            return "The agent runtime isn't installed. Enable Agent Mode to download it."
        case PiRPCError.transportClosed:
            return "The agent process exited unexpectedly."
        default:
            return error.localizedDescription
        }
    }
}
