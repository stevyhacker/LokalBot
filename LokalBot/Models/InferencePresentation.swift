import Foundation

/// Presentation of the configured destination, independent of whether a model
/// is downloaded or has passed a test. Authorization stays in endpoint policy.
enum InferencePresentation: Equatable {
    case onDevice
    case remote(host: String)
    case blocked(reason: String)

    init(settings: AppSettings) {
        switch settings.summarizerBackend {
        case .builtIn, .appleIntelligence:
            self = .onDevice
        case .chatGPTPlan, .claudePlan:
            guard let plan = SubscriptionPlan(backend: settings.summarizerBackend) else {
                self = .blocked(reason: "Choose a Think model under Settings → Models.")
                return
            }
            self = plan.isApproved(in: settings)
                ? .remote(host: plan.title)
                : .blocked(reason: SubscriptionPlanError.approvalRequired(plan).localizedDescription)
        case .ollama, .openAICompatible:
            let raw = settings.summarizerBackend == .ollama
                ? settings.ollamaBaseURL : settings.openAIBaseURL
            guard let url = URL(string: raw), InferenceEndpointPolicy.origin(for: url) != nil else {
                self = .blocked(reason: "Enter a valid model server URL in Settings → Models.")
                return
            }
            do {
                try InferenceEndpointPolicy.validate(url, approvedOrigins: settings.approvedRemoteInferenceOrigins)
                self = InferenceEndpointPolicy.isLoopback(url)
                    ? .onDevice : .remote(host: url.host ?? "configured server")
            } catch {
                self = .blocked(reason: error.localizedDescription)
            }
        }
    }

    var label: String {
        switch self {
        case .onDevice: "On this Mac"
        case .remote(let host): "Remote · \(host)"
        case .blocked: "Model connection blocked"
        }
    }

    var icon: String {
        switch self {
        case .onDevice: "desktopcomputer"
        case .remote: "network"
        case .blocked: "exclamationmark.triangle"
        }
    }

    var isRemote: Bool {
        if case .remote = self { return true }
        return false
    }

    var isBlocked: Bool {
        if case .blocked = self { return true }
        return false
    }

    func detail(local: String, remote: String) -> String {
        switch self {
        case .onDevice: local
        case .remote(let host): "\(remote) Server: \(host)."
        case .blocked(let reason): reason
        }
    }
}

extension AppSettings {
    /// Every server that receives what this Mac's AI features send, each
    /// named once: Think's, the transcription server and, while autocomplete
    /// is on, the server it sends typing to. The sidebar's privacy summary
    /// lists them: with autocomplete left out it read "AI: on this Mac" while
    /// every suggestion request went to a server.
    var remoteAIHosts: [String] {
        var presentations = [InferencePresentation(settings: self), transcriptionPresentation]
        if let host = cotypingRemoteHost { presentations.append(.remote(host: host)) }
        return presentations.reduce(into: [String]()) { hosts, presentation in
            if case .remote(let host) = presentation, !hosts.contains(host) { hosts.append(host) }
        }
    }
}
