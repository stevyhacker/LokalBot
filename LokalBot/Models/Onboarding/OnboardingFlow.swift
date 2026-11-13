import Foundation

/// Setup's three steps, in order. Choices stay a draft until setup finishes;
/// permissions and downloads happen only through their named actions.
enum OnboardingStep: Int, CaseIterable, Codable, Identifiable, Sendable {
    case choose, access, download

    var id: Int { rawValue }

    /// The label in the window's stepper.
    var title: String {
        switch self {
        case .choose: "Choose"
        case .access: "Allow access"
        case .download: "Download"
        }
    }

    var previous: OnboardingStep? { OnboardingStep(rawValue: rawValue - 1) }
    var next: OnboardingStep? { OnboardingStep(rawValue: rawValue + 1) }
}

/// What one permission row in setup shows.
enum OnboardingPermissionState: Equatable, Sendable {
    /// Not asked yet: the row offers Allow.
    case needed
    /// System Settings was opened for it and the grant has not arrived.
    case waiting
    case allowed
    /// Granted since this launch; it takes effect after a restart.
    case allowedAfterRestart
    /// Refused earlier, so macOS will not ask again: only System Settings can
    /// turn it on.
    case turnedOff

    var isAllowed: Bool { self == .allowed || self == .allowedAfterRestart }
}

/// Setup's permission step: only what the choices need, each with its real
/// state from `PermissionManager`.
struct OnboardingAccess: Equatable, Sendable {
    struct Row: Equatable, Identifiable, Sendable {
        let permission: AppPermission
        let state: OnboardingPermissionState
        var id: AppPermission { permission }
    }

    var rows: [Row]

    /// The microphone always (Record uses it even with detection off),
    /// Accessibility for the workday, Screen Recording only for screenshots.
    static func permissions(for draft: CaptureSetupDraft) -> [AppPermission] {
        var result: [AppPermission] = [.microphone]
        if draft.dayMemory { result.append(.accessibility) }
        if draft.dayMemory && draft.contextMode.capturesPixels { result.append(.screenRecording) }
        return result
    }

    /// - Parameters:
    ///   - granted: the current grants.
    ///   - grantedAtLaunch: the grants when this launch started.
    ///   - requested: permissions whose System Settings pane setup opened.
    ///   - turnedOff: permissions macOS will not ask for again.
    init(draft: CaptureSetupDraft,
         granted: [AppPermission: Bool],
         grantedAtLaunch: [AppPermission: Bool],
         requested: Set<AppPermission>,
         turnedOff: Set<AppPermission>) {
        rows = Self.permissions(for: draft).map { permission in
            let state: OnboardingPermissionState
            if granted[permission] == true {
                state = permission.needsRelaunchAfterGrant && grantedAtLaunch[permission] != true
                    ? .allowedAfterRestart : .allowed
            } else if turnedOff.contains(permission) {
                state = .turnedOff
            } else if requested.contains(permission), permission.guidanceStyle == .guidedOverlay {
                state = .waiting
            } else {
                state = .needed
            }
            return Row(permission: permission, state: state)
        }
    }

    var allowedCount: Int { rows.filter(\.state.isAllowed).count }

    /// Granted, but working only after LokalBot restarts.
    var restartPermissions: [AppPermission] {
        rows.filter { $0.state == .allowedAfterRestart }.map(\.permission)
    }

    /// The System Settings picture is worth showing while a permission that
    /// is granted there is still to come.
    var showsSettingsGuide: Bool {
        rows.contains {
            $0.permission.guidanceStyle == .guidedOverlay && ($0.state == .needed || $0.state == .waiting)
        }
    }
}

/// What setup needs to reopen where it was after the restart a permission
/// grant requires: the step and the choices not applied yet.
struct OnboardingResumeState: Equatable, Codable {
    var step: OnboardingStep
    var draft: CaptureSetupDraft
    /// The choices the settings held when the draft was started. When the
    /// settings have changed since, the saved draft no longer describes them.
    var baseline: CaptureSetupDraft
    var includeAutocomplete: Bool
    var opensSampleMeeting: Bool
    /// Set by Restart now. A setup that was already finished once reopens
    /// after a restart only when the person asked for that restart here.
    var reopensAfterRestart = false
}

/// Keeps `OnboardingResumeState` in the app's preferences (the test suite
/// when one is set), next to the settings it belongs to.
struct OnboardingResumeStore {
    static let key = "lokalbotv3.onboarding.resume"

    let defaults: UserDefaults

    static var live: OnboardingResumeStore {
        if let suite = UITestRuntime.defaultsSuiteName, let defaults = UserDefaults(suiteName: suite) {
            return OnboardingResumeStore(defaults: defaults)
        }
        return OnboardingResumeStore(defaults: .standard)
    }

    func save(_ state: OnboardingResumeState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: Self.key)
    }

    /// The saved state, when it still belongs to `settings`.
    func load(for settings: AppSettings) -> OnboardingResumeState? {
        guard let data = defaults.data(forKey: Self.key),
              let state = try? JSONDecoder().decode(OnboardingResumeState.self, from: data),
              state.baseline == CaptureSetupDraft(settings: settings) else { return nil }
        return state
    }

    func clear() {
        guard defaults.object(forKey: Self.key) != nil else { return }
        defaults.removeObject(forKey: Self.key)
    }
}

/// What a launch does about setup.
enum OnboardingLaunch: Equatable {
    /// Every core permission is granted and nothing waits: the install
    /// predates setup, so it counts as finished.
    case markFinished
    case open
    /// Setup stays closed; a saved state that is not wanted is dropped.
    case stayClosed(clearsResume: Bool)

    /// - Parameters:
    ///   - finished: setup was finished or deferred before.
    ///   - coreGranted: every permission setup requires is granted.
    ///   - resume: the saved state that still belongs to the settings.
    ///   - agentSetupPending: an agent's setup request replaces the wizard.
    static func decision(finished: Bool, coreGranted: Bool,
                         resume: OnboardingResumeState?, agentSetupPending: Bool) -> OnboardingLaunch {
        if finished {
            guard let resume else { return .stayClosed(clearsResume: false) }
            return resume.reopensAfterRestart ? .open : .stayClosed(clearsResume: true)
        }
        // A setup interrupted by a restart continues, even though the
        // microphone grant that came with it would count as established.
        if coreGranted && resume == nil { return .markFinished }
        return agentSetupPending ? .stayClosed(clearsResume: false) : .open
    }
}
