import Foundation

/// Everything needed to spawn one pi RPC subprocess.
struct PiLaunchPlan: Equatable {
    let executable: URL
    let arguments: [String]
    let environment: [String: String]
    let workingDirectory: URL
}

/// What the working folder is, for the extension's environment prompt section.
enum AgentWorkspaceKind: String {
    case agentWorkspace = "agent-workspace"
    case chosenFolder = "chosen-folder"

    static let environmentKey = "LOKALBOT_AGENT_WORKSPACE_KIND"
}

/// Builds the exact pi launch contract from the 2026-07-09 spec. pi is
/// fully isolated from the user's ~/.pi and any repo-local pi config
/// (--no-extensions/-e, --no-skills/--skill, --no-prompt-templates,
/// --no-approve) and fully offline (--offline + PI_SKIP_VERSION_CHECK —
/// pi ships install telemetry and update checks enabled by default).
/// Context files are disabled because pi's upward discovery is not confined
/// to the selected workspace. Workspace files remain available through the
/// read tool, whose extension hook canonicalizes paths and asks before any
/// out-of-workspace access. LokalBot's own system prompt replaces pi's
/// coding-agent prompt; the extension appends the per-run environment.
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
        // A plan relay is on this Mac; the model is not. The extension's
        // environment section says who serves it.
        environment["LOKALBOT_LLM_SERVED_BY"] = endpoint.plan.map { "\($0.providerName) on the user's \($0.title)" }
        // The host rewrites this file when the Agent reasoning level changes;
        // the extension reads it for every model request. Absent: Automatic.
        environment["LOKALBOT_LLM_REASONING_FILE"] = reasoningLevelFile?.path
        environment[AgentWorkspaceKind.environmentKey] = workspaceKind?.rawValue
        let privateRootsJSON = try? JSONEncoder().encode(privateRoots.map { $0.standardizedFileURL.path })
        // An encoding failure must stop the extension at startup, never omit
        // the protected roots. `null` is rejected by its launch validation.
        environment["LOKALBOT_AGENT_PRIVATE_ROOTS"] = privateRootsJSON.map {
            String(decoding: $0, as: UTF8.self)
        } ?? "null"
        // A credential-free endpoint must not inherit a key for another
        // service from the parent process (including injected test sessions).
        // The extension takes the key at startup and removes it from the
        // environment that the agent's shell commands inherit.
        environment["LOKALBOT_LLM_API_KEY"] = endpoint.apiKey
        if let agentAccessCapability {
            environment[AgentAccessGate.capabilityEnvironmentKey] = agentAccessCapability
        }
        environment["PI_SKIP_VERSION_CHECK"] = "1"
        environment["PI_TELEMETRY"] = "0"
        // Bun's transpiler cache, pi's compile cache and jiti's extension cache
        // would keep compiled copies of pi and of the approval extension in
        // ~/Library/Caches/bun and the temporary folder, outside the verified
        // runtime. Later launches would run those copies instead.
        environment["BUN_RUNTIME_TRANSPILER_CACHE_PATH"] = "0"
        environment["NODE_DISABLE_COMPILE_CACHE"] = "1"
        environment["JITI_FS_CACHE"] = "false"
        environment["PI_CODING_AGENT_DIR"] = sessionDirectory.deletingLastPathComponent()
            .appendingPathComponent("pi-config", isDirectory: true).path
        if let helpersDirectory {
            // lokalbot-cli lives in Contents/Helpers; the bundled skill
            // invokes it by name, so it must be on the agent's PATH.
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
