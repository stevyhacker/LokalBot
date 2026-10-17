import AppKit

/// Selection actions: a system-wide shortcut reads the text selected in the
/// frontmost app, the panel runs the Think model on it (optionally with
/// matching work memory), and the result replaces the selection, goes in at
/// the cursor, or is copied. Nothing here is persisted.
@MainActor
final class SelectionActionsController: ObservableObject {
    enum Phase: Equatable {
        case idle
        /// Reading the selection before the panel opens.
        case capturing
        case choosing
        case generating
        case finished
        case failed(String)
    }

    enum DeliveryOutcome: Equatable {
        case inserted
        /// Pasted, but the app never read it; the result stays on the clipboard.
        case unconfirmed(String)
        /// Not pasted, for this reason; the result is on the clipboard.
        case copied(String)
    }

    struct Dependencies {
        /// True when LokalBot itself is the frontmost app.
        var isLokalBotFrontmost: @MainActor () -> Bool = { FocusReturn.frontmostOtherApplication() == nil }
        var capture: @MainActor () async -> SelectionCaptureResult
        var makeEngine: @MainActor () async throws -> TextEngine
        var memory: @MainActor (String) async -> SelectionMemoryContext
        var deliver: @MainActor (String, SelectionCaptureResult) async -> DeliveryOutcome
        var copy: @MainActor (String) -> Void
        var returnFocus: @MainActor (SelectionSource) -> Void
        var openPanel: @MainActor () -> Void
        var report: @MainActor (String) -> Void
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var capture = SelectionCaptureResult()
    @Published private(set) var action: SelectionAction?
    @Published private(set) var output = ""
    @Published private(set) var memorySources: [SelectionMemoryContext.Source] = []
    @Published private(set) var modelName: String?
    /// Why the last result could not be pasted back; shown above it.
    @Published private(set) var notice: String?

    private let dependencies: Dependencies
    private var task: Task<Void, Never>?
    /// Bumped by every new request, so a superseded one never writes state.
    private var generation = 0

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    /// The shortcut was pressed. Reads the selection first, because opening
    /// the panel moves focus away from it.
    func invoke() {
        guard !dependencies.isLokalBotFrontmost() else {
            // Pressed while LokalBot is in front: keep any open panel's state.
            if phase == .idle { phase = .choosing }
            dependencies.openPanel()
            return
        }
        let current = begin()
        phase = .capturing
        task = Task { [weak self] in
            guard let self else { return }
            let result = await self.dependencies.capture()
            guard current == self.generation else { return }
            self.capture = result
            self.phase = .choosing
            self.task = nil
            self.dependencies.openPanel()
        }
    }

    func run(_ action: SelectionAction) {
        guard capture.issue == nil, capture.hasSelection || action.worksWithoutSelection else { return }
        let current = begin(keepingCapture: true)
        self.action = action
        phase = .generating
        let selection = capture.text
        task = Task { [weak self] in
            guard let self else { return }
            do {
                var memory = SelectionMemoryContext.empty
                if action.usesMemory {
                    memory = await self.dependencies.memory(
                        SelectionActionPrompt.memoryQuery(action: action, selection: selection))
                    try Task.checkCancellation()
                    guard current == self.generation else { return }
                    self.memorySources = memory.sources
                }
                let engine = try await self.dependencies.makeEngine()
                try Task.checkCancellation()
                guard current == self.generation else { return }
                self.modelName = engine.displayName
                let raw = try await engine.generateStreaming(
                    system: SelectionActionPrompt.systemPrompt(usesMemory: action.usesMemory),
                    prompt: SelectionActionPrompt.userPrompt(action: action, selection: selection, memory: memory),
                    context: [],
                    options: SelectionActionPrompt.options
                ) { [weak self] partial in
                    guard let self, current == self.generation else { return }
                    self.output = SelectionActionPrompt.normalizedOutput(partial, selection: selection)
                }
                try Task.checkCancellation()
                guard current == self.generation else { return }
                let text = SelectionActionPrompt.normalizedOutput(raw, selection: selection)
                self.output = text
                self.phase = text.isEmpty
                    ? .failed("The model returned no text. Try again or reword the instruction.")
                    : .finished
            } catch {
                guard current == self.generation, !Task.isCancelled, !(error is CancellationError) else { return }
                lokalbotLog("selection action failed: \(error.localizedDescription)")
                self.phase = .failed(ChatViewModel.friendlyFailureMessage(for: error))
            }
            if current == self.generation { self.task = nil }
        }
    }

    func retry() {
        guard let action else { return }
        run(action)
    }

    /// Back to the list of actions, keeping the selection.
    func chooseAgain() {
        _ = begin(keepingCapture: true)
        phase = .choosing
    }

    /// Copies the result and hands focus back to the app it came from, ready
    /// for ⌘V. The panel closes.
    func copyOutput() {
        guard !output.isEmpty else { return }
        dependencies.copy(output)
        let source = capture.source
        finish()
        if let source { dependencies.returnFocus(source) }
    }

    /// Replaces the selection with the result, or inserts it at the cursor
    /// when nothing was selected. The panel closes; if the field changed
    /// meanwhile, the panel comes back with the result already copied.
    func insertOutput() {
        guard phase == .finished, !output.isEmpty, capture.canInsert else { return }
        let text = output, captured = capture, chosen = action, sources = memorySources, model = modelName
        finish()
        Task { [weak self] in
            guard let self else { return }
            switch await self.dependencies.deliver(text, captured) {
            case .inserted:
                break
            case .unconfirmed(let message):
                self.dependencies.report(message)
            case .copied(let reason):
                // Nothing newer took the panel meanwhile.
                guard self.phase == .idle else {
                    self.dependencies.report(reason)
                    return
                }
                self.capture = captured
                self.action = chosen
                self.output = text
                self.memorySources = sources
                self.modelName = model
                self.notice = reason
                self.phase = .finished
                self.dependencies.openPanel()
            }
        }
    }

    /// Closes without using a result and returns to the source app.
    func dismiss() {
        let source = capture.source
        finish()
        if let source { dependencies.returnFocus(source) }
    }

    /// The panel closed: stop generating and forget the selection.
    func panelClosed() {
        guard phase != .idle else { return }
        finish()
    }

    func stop() {
        finish()
    }

    // MARK: - State

    /// Cancels the running request and starts a new generation.
    private func begin(keepingCapture: Bool = false) -> Int {
        task?.cancel()
        task = nil
        generation += 1
        if !keepingCapture { capture = SelectionCaptureResult() }
        action = nil
        output = ""
        memorySources = []
        modelName = nil
        notice = nil
        return generation
    }

    private func finish() {
        _ = begin()
        phase = .idle
    }
}

/// Puts a selection action's result back into the field it came from.
@MainActor
enum SelectionDelivery {
    private static let inserter = CotypingInserter()

    static func deliver(_ text: String, capture: SelectionCaptureResult) async
        -> SelectionActionsController.DeliveryOutcome {
        guard let target = capture.target, let source = capture.source,
              let application = NSRunningApplication(processIdentifier: source.processID),
              await FocusReturn.activate(application) else {
            return copied(text, reason: "LokalBot could not return to the app, so the result was copied to the clipboard.")
        }
        // Let the app give keyboard focus back to its field before checking it.
        try? await Task.sleep(for: .milliseconds(120))
        let focus = await DictationFocusSnapshotExecutor.shared.capture(deadlineMilliseconds: 400)
        let check: DictationDeliveryCheck = focus.timedOut
            ? .fieldUnreadable
            : focus.snapshot.map { target.check($0) } ?? .fieldUnreadable
        guard check == .deliverable else { return copied(text, reason: message(for: check)) }
        switch await inserter.insertViaPaste(text) {
        case .pasted:
            return .inserted
        case .unconfirmed:
            return .unconfirmed(
                "LokalBot could not confirm that the app accepted the paste, so the result was left on the clipboard.")
        case .failed, .skipped:
            return copied(text, reason: "LokalBot could not paste the result, so it was copied to the clipboard.")
        }
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func message(for check: DictationDeliveryCheck) -> String {
        switch check {
        case .deliverable, .fieldUnreadable:
            "LokalBot could not confirm which field to paste into, so the result was copied to the clipboard."
        case .focusMoved:
            "Focus moved to another field, so the result was copied to the clipboard instead."
        case .selectionChanged:
            "The selection changed, so the result was copied to the clipboard instead of replacing it."
        case .secureField:
            "LokalBot does not paste into password fields, so the result was copied to the clipboard."
        }
    }

    private static func copied(_ text: String, reason: String) -> SelectionActionsController.DeliveryOutcome {
        copy(text)
        return .copied(reason)
    }
}
