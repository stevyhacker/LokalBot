import Foundation

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

    func allow(meetingLibrary: Bool, screenMemory: Bool, files: Bool = false, in app: AppState) {
        guard let request = pending else { return }
        guard request.isLive(at: now()) else {
            answer(request, .expired, grants: [])
            return
        }
        app.settingsControl.setEnabled(true)
        guard app.settingsControl.isEnabled else {
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
        if files, request.grants.contains(.files) {
            app.filesAccess.setEnabled(true)
            if app.filesAccess.isEnabled { grants.append(.files) }
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
