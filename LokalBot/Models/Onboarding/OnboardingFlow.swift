import Foundation

enum OnboardingStep: Int, CaseIterable, Codable, Identifiable, Sendable {
    case choose, access, download

    var id: Int { rawValue }

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

enum OnboardingPermissionState: Equatable, Sendable {
    case needed
    case waiting
    case allowed
    case allowedAfterRestart
    case turnedOff

    var isAllowed: Bool { self == .allowed || self == .allowedAfterRestart }
}

struct OnboardingAccess: Equatable, Sendable {
    struct Row: Equatable, Identifiable, Sendable {
        let permission: AppPermission
        let state: OnboardingPermissionState
        var id: AppPermission { permission }
    }

    var rows: [Row]

    static func permissions(for draft: CaptureSetupDraft) -> [AppPermission] {
        var result: [AppPermission] = [.microphone]
        if draft.dayMemory { result.append(.accessibility) }
        if draft.dayMemory && draft.contextMode.capturesPixels { result.append(.screenRecording) }
        return result
    }

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

    var restartPermissions: [AppPermission] {
        rows.filter { $0.state == .allowedAfterRestart }.map(\.permission)
    }

    var showsSettingsGuide: Bool {
        rows.contains {
            $0.permission.guidanceStyle == .guidedOverlay && ($0.state == .needed || $0.state == .waiting)
        }
    }
}

struct OnboardingResumeState: Equatable, Codable {
    var step: OnboardingStep
    var draft: CaptureSetupDraft
    var baseline: CaptureSetupDraft
    var includeAutocomplete: Bool
    var opensSampleMeeting: Bool
    var reopensAfterRestart = false
}

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

enum OnboardingLaunch: Equatable {
    case markFinished
    case open
    case stayClosed(clearsResume: Bool)

    static func decision(finished: Bool, coreGranted: Bool,
                         resume: OnboardingResumeState?, agentSetupPending: Bool) -> OnboardingLaunch {
        if finished {
            guard let resume else { return .stayClosed(clearsResume: false) }
            return resume.reopensAfterRestart ? .open : .stayClosed(clearsResume: true)
        }
        if coreGranted && resume == nil { return .markFinished }
        return agentSetupPending ? .stayClosed(clearsResume: false) : .open
    }
}
