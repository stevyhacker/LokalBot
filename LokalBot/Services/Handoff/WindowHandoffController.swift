import AppKit

enum WindowHandoffTarget: String, CaseIterable, Identifiable {
    case agentMode = "Agent Mode"
    case claudeCode = "Claude Code"
    case codex = "Codex"
    case copy = "Copy"

    var id: String { rawValue }

    var agent: ActionAgentHandoff? {
        switch self {
        case .claudeCode: .claudeCode
        case .codex: .codex
        case .agentMode, .copy: nil
        }
    }

    var manifestID: String {
        switch self {
        case .agentMode: "agent-mode"
        case .claudeCode: "claude-code"
        case .codex: "codex"
        case .copy: "clipboard"
        }
    }
}

@MainActor
final class WindowHandoffController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case capturing
        case writing
        case ready
        case handingOff
    }

    struct Dependencies {
        var isLokalBotFrontmost: @MainActor () -> Bool = { FocusReturn.frontmostOtherApplication() == nil }
        var capture: @MainActor () async -> WindowHandoffCapture
        var makeEngine: @MainActor () async throws -> TextEngine
        var targets: @MainActor () -> [WindowHandoffTarget]
        var writePackage: @MainActor (WindowHandoffCapture, String) throws -> WindowHandoffPackage
        var deliver: @MainActor (WindowHandoffPackage, WindowHandoffTarget) async -> String?
        var returnFocus: @MainActor (SelectionSource) -> Void
        var openPanel: @MainActor () -> Void
        var closePanel: @MainActor () -> Void
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var capture = WindowHandoffCapture()
    @Published var brief = ""
    @Published var target: WindowHandoffTarget = .agentMode
    @Published private(set) var targets: [WindowHandoffTarget] = []
    @Published private(set) var modelName: String?
    @Published private(set) var briefIsTemplate = false
    @Published private(set) var notice: String?
    @Published private(set) var needsSourceWindow = false

    private let dependencies: Dependencies
    private var task: Task<Void, Never>?
    private var generation = 0

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    var canHandOff: Bool {
        phase == .ready && capture.hasContent
            && !brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && targets.contains(target)
    }

    func invoke() {
        guard !dependencies.isLokalBotFrontmost() else {
            if phase == .idle { needsSourceWindow = true }
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
            self.targets = self.dependencies.targets()
            if !self.targets.contains(self.target), let first = self.targets.first { self.target = first }
            self.dependencies.openPanel()
            guard result.hasContent else {
                self.phase = .ready
                self.task = nil
                return
            }
            self.writeBrief(generation: current)
        }
    }

    func skipBrief() {
        guard phase == .writing else { return }
        task?.cancel()
        task = nil
        generation += 1
        useTemplate(notice: nil)
    }

    func rewriteBrief() {
        guard phase == .ready, capture.hasContent else { return }
        task?.cancel()
        generation += 1
        writeBrief(generation: generation)
    }

    func handOff() {
        guard canHandOff else { return }
        let current = generation
        let chosen = target, captured = capture, text = brief
        phase = .handingOff
        notice = nil
        task = Task { [weak self] in
            guard let self else { return }
            let failure: String?
            do {
                let package = try self.dependencies.writePackage(captured, text)
                failure = await self.dependencies.deliver(package, chosen)
            } catch {
                lokalbotLog("hand off package failed: \(error.localizedDescription)")
                failure = "LokalBot couldn't save the handoff: \(error.localizedDescription)"
            }
            guard current == self.generation else { return }
            self.task = nil
            if let failure {
                self.notice = failure
                self.phase = .ready
                return
            }
            let source = captured.source
            self.finish()
            self.dependencies.closePanel()
            if chosen == .copy, let source { self.dependencies.returnFocus(source) }
        }
    }

    func dismiss() {
        let source = capture.source
        finish()
        dependencies.closePanel()
        if let source { dependencies.returnFocus(source) }
    }

    func panelClosed() {
        guard phase != .idle || needsSourceWindow else { return }
        finish()
    }

    func stop() {
        finish()
    }

    private func writeBrief(generation current: Int) {
        phase = .writing
        brief = ""
        briefIsTemplate = false
        notice = nil
        let captured = capture
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let engine = try await self.dependencies.makeEngine()
                try Task.checkCancellation()
                guard current == self.generation else { return }
                self.modelName = engine.displayName
                let raw = try await engine.generateStreaming(
                    system: WindowHandoffBriefPrompt.system,
                    prompt: WindowHandoffBriefPrompt.userPrompt(captured),
                    context: [],
                    options: WindowHandoffBriefPrompt.options
                ) { [weak self] partial in
                    guard let self, current == self.generation else { return }
                    self.brief = WindowHandoffBriefPrompt.normalizedBrief(partial)
                }
                try Task.checkCancellation()
                guard current == self.generation else { return }
                let text = WindowHandoffBriefPrompt.normalizedBrief(raw)
                if text.isEmpty {
                    self.useTemplate(notice: "The model returned no brief, so LokalBot filled in a simple one.")
                } else {
                    self.brief = text
                    self.phase = .ready
                }
            } catch {
                guard current == self.generation, !Task.isCancelled, !(error is CancellationError) else { return }
                lokalbotLog("hand off brief failed: \(error.localizedDescription)")
                self.useTemplate(notice: ChatViewModel.friendlyFailureMessage(for: error))
            }
            if current == self.generation { self.task = nil }
        }
    }

    private func useTemplate(notice: String?) {
        brief = WindowHandoffBriefPrompt.templateBrief(capture)
        briefIsTemplate = true
        self.notice = notice
        phase = .ready
    }

    private func begin() -> Int {
        task?.cancel()
        task = nil
        generation += 1
        capture = WindowHandoffCapture()
        brief = ""
        modelName = nil
        briefIsTemplate = false
        notice = nil
        needsSourceWindow = false
        return generation
    }

    private func finish() {
        _ = begin()
        phase = .idle
    }
}
