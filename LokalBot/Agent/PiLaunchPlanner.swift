import Foundation

struct PiLaunchPlan: Equatable {
    let executable: URL
    let arguments: [String]
    let environment: [String: String]
    let workingDirectory: URL
}

enum AgentWorkspaceKind: String {
    case agentWorkspace = "agent-workspace"
    case chosenFolder = "chosen-folder"

    static let environmentKey = "LOKALBOT_AGENT_WORKSPACE_KIND"
}

enum PiLaunchPlanner {

    static func plan(bun: URL,
                     piCLI: URL,
                     extensionDirectory: URL,
                     skillDirectory: URL?,
                     systemPrompt: URL? = nil,
                     sessionDirectory: URL,
                     workspace: URL,
                     workspaceKind: AgentWorkspaceKind? = nil,
                     endpoint: AgentLLMEndpoint,
                     reasoningLevelFile: URL? = nil,
                     helpersDirectory: URL?,
                     privateRoots: [URL] = [],
                     agentAccessCapability: String? = nil,
                     continuePreviousSession: Bool = false,
                     specificSession: URL? = nil,
                     baseEnvironment: [String: String] = ProcessInfo.processInfo.environment) -> PiLaunchPlan {
        var arguments = [
            piCLI.path,
            "--mode", "rpc",
            "--provider", "lokalbot",
            "--model", endpoint.model,
            "--no-extensions", "-e", extensionDirectory.path,
            "--no-skills",
        ]
        if let specificSession {
            arguments += ["--session", specificSession.path]
        } else if continuePreviousSession {
            arguments.append("--continue")
        }
        if let skillDirectory {
            arguments += ["--skill", skillDirectory.path]
        }
        if let systemPrompt {
            arguments += ["--system-prompt", systemPrompt.path]
        }
        arguments += [
            "--no-prompt-templates",
            "--no-context-files",
            "--no-approve",
            "--session-dir", sessionDirectory.path,
            "--offline",
        ]

        var environment = baseEnvironment
        environment["LOKALBOT_LLM_BASE_URL"] = endpoint.baseURL.absoluteString
        environment["LOKALBOT_LLM_MODEL"] = endpoint.model
        environment["LOKALBOT_LLM_CTX"] = String(endpoint.contextTokens)
        environment["LOKALBOT_LLM_REASONING_DIALECT"] = endpoint.reasoningDialect.rawValue
        environment["LOKALBOT_LLM_API"] = endpoint.api.rawValue
        environment["LOKALBOT_LLM_SERVED_BY"] = endpoint.plan.map { "\($0.providerName) on the user's \($0.title)" }
        environment["LOKALBOT_LLM_REASONING_FILE"] = reasoningLevelFile?.path
        environment[AgentWorkspaceKind.environmentKey] = workspaceKind?.rawValue
        let privateRootsJSON = try? JSONEncoder().encode(privateRoots.map { $0.standardizedFileURL.path })
        environment["LOKALBOT_AGENT_PRIVATE_ROOTS"] = privateRootsJSON.map {
            String(decoding: $0, as: UTF8.self)
        } ?? "null"
        environment["LOKALBOT_LLM_API_KEY"] = endpoint.apiKey
        if let agentAccessCapability {
            environment[AgentAccessGate.capabilityEnvironmentKey] = agentAccessCapability
        }
        environment["PI_SKIP_VERSION_CHECK"] = "1"
        environment["PI_TELEMETRY"] = "0"
        environment["BUN_RUNTIME_TRANSPILER_CACHE_PATH"] = "0"
        environment["NODE_DISABLE_COMPILE_CACHE"] = "1"
        environment["JITI_FS_CACHE"] = "false"
        environment["PI_CODING_AGENT_DIR"] = sessionDirectory.deletingLastPathComponent()
            .appendingPathComponent("pi-config", isDirectory: true).path
        if let helpersDirectory {
            let existing = environment["PATH"] ?? ""
            environment["PATH"] = existing.isEmpty
                ? helpersDirectory.path
                : "\(helpersDirectory.path):\(existing)"
        }
        return PiLaunchPlan(executable: bun,
                            arguments: arguments,
                            environment: environment,
                            workingDirectory: workspace)
    }
}
