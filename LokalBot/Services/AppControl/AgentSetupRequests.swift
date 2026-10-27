import Foundation

/// The request an agent left with `lokalbot-cli setup start`, shown to the
/// person in the agent setup window. Allowing it turns on the settings grant,
/// plus whichever read access the person ticks; declining leaves everything
/// off. Each request is answered once, and the answer is written back to
/// `control/setup-answer.json` for the CLI to read.
@MainActor
final class AgentSetupRequests: ObservableObject {
    @Published private(set) var pending: AgentSetup.Request?
    let controlDirectory: URL
    private let now: () -> Date

    init(controlDirectory: URL, now: @escaping () -> Date = Date.init) {
        self.controlDirectory = controlDirectory
        self.now = now
    }

    var requestURL: URL { AgentSetup.requestURL(controlDirectory: controlDirectory) }
    var answerURL: URL { AgentSetup.answerURL(controlDirectory: controlDirectory) }

    /// Picks up a request left by the CLI and says whether one is waiting.
    /// An unreadable or expired request is answered and removed.
    @discardableResult
    func check() -> Bool {
        guard FileManager.default.fileExists(atPath: requestURL.path) else {
            pending = nil
            return false
        }
        guard let request = AgentSetup.read(AgentSetup.Request.self, from: requestURL) else {
            try? FileManager.default.removeItem(at: requestURL)
            pending = nil
            return false
        }
        guard request.isLive(at: now()) else {
            answer(request, .expired, grants: [])
            return false
        }
        if pending?.nonce != request.nonce {
            pending = request
            scheduleExpiry(of: request)
        }
        return true
    }

    /// The person allowed the request, with the read access they ticked.
    func allow(meetingLibrary: Bool, screenMemory: Bool, in app: AppState) {
        guard let request = pending else { return }
        guard request.isLive(at: now()) else {
            answer(request, .expired, grants: [])
            return
        }
        app.settingsControl.setEnabled(true)
        guard app.settingsControl.isEnabled else {
            // The marker could not be written; the error is already shown.
            answer(request, .denied, grants: [])
            return
        }
        var grants: [AgentSetup.Grant] = [.settings]
        if meetingLibrary, request.grants.contains(.meetingLibrary) {
            app.agentAccess.setEnabled(true)
            if app.agentAccess.isEnabled { grants.append(.meetingLibrary) }
        }
        if screenMemory, request.grants.contains(.screenMemory) {
            app.screenMemoryAccess.setEnabled(true)
            if app.screenMemoryAccess.isEnabled { grants.append(.screenMemory) }
        }
        app.agentSettingsChanges.recordSetup(grants, caller: request.requester)
        answer(request, .approved, grants: grants)
    }

    func deny() {
        guard let request = pending else { return }
        answer(request, .denied, grants: [])
    }

    private func answer(_ request: AgentSetup.Request, _ state: SettingsRequestState, grants: [AgentSetup.Grant]) {
        try? AgentSetup.write(
            AgentSetup.Answer(nonce: request.nonce, state: state, grants: grants, answeredAt: now()),
            to: answerURL)
        // Only remove the request this answers; the CLI may have left a newer one.
        if AgentSetup.read(AgentSetup.Request.self, from: requestURL)?.nonce == request.nonce {
            try? FileManager.default.removeItem(at: requestURL)
        }
        if pending?.nonce == request.nonce { pending = nil }
    }

    private func scheduleExpiry(of request: AgentSetup.Request) {
        let delay = max(0, request.expiresAt.timeIntervalSince(now())) + 1
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, self.pending?.nonce == request.nonce else { return }
            self.answer(request, .expired, grants: [])
        }
    }
}
