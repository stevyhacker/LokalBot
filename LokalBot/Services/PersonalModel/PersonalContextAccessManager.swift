import Combine
import Foundation

/// App-side owner of the Personal context grant (Settings → Privacy). While it
/// is on, the app keeps `control/personal-context.json` in step with the
/// claims the person shared, so `lokalbot-cli` and its MCP server can answer
/// without the app running and without reading the encrypted personal model.
/// Every failure removes the shared copy rather than leaving a stale one.
@MainActor
final class PersonalContextAccessManager: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var sharedCount = 0
    @Published private(set) var lastError: String?

    private let gate: PersonalContextAccessGate
    private let claims: () -> [PersonalClaim]?
    private let now: () -> Date

    init(gate: PersonalContextAccessGate, claims: @escaping () -> [PersonalClaim]?,
         now: @escaping () -> Date = Date.init) {
        self.gate = gate
        self.claims = claims
        self.now = now
    }

    func start() {
        isEnabled = gate.isEnabled
        if isEnabled {
            refresh(claims())
        } else {
            gate.removeProjection()
        }
    }

    func setEnabled(_ enabled: Bool) {
        if enabled {
            do {
                try gate.enable()
            } catch {
                lastError = "LokalBot couldn't turn on personal context access: \(error.localizedDescription)"
                return
            }
            isEnabled = true
            refresh(claims())
        } else {
            gate.disable()
            isEnabled = false
            lastError = nil
        }
    }

    /// Rewrites the shared copy from `current`; nil means the personal model
    /// couldn't be read, so nothing is shared until it can be.
    func refresh(_ current: [PersonalClaim]?) {
        let shared = (current ?? []).filter { $0.sharing == .agents }
        sharedCount = shared.count
        guard gate.isEnabled else {
            gate.removeProjection()
            return
        }
        guard current != nil else {
            gate.removeProjection()
            lastError = "LokalBot couldn't read what it remembers about you, so agents get nothing until it can."
            return
        }
        let projected = shared.map(PersonalContextProjection.Claim.init)
        // Answers stamp lastUsedAt, which agents never see; skip those rewrites.
        if gate.readProjection()?.claims == projected {
            lastError = nil
            return
        }
        do {
            try gate.writeProjection(PersonalContextProjection(generatedAt: now(), claims: projected))
            lastError = nil
        } catch {
            gate.removeProjection()
            lastError = "LokalBot couldn't update what agents can read, so it removed the shared copy: \(error.localizedDescription)"
        }
    }
}
