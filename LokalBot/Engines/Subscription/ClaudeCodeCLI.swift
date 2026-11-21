import Foundation

enum ClaudeCodeCLI {
    static func candidatePaths(home: String) -> [String] {
        [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.npm-global/bin/claude",
            "\(home)/.bun/bin/claude",
            "\(home)/.volta/bin/claude",
        ]
    }

    static func locate(environment: [String: String] = ProcessInfo.processInfo.environment,
                       home: String = NSHomeDirectory(),
                       isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> URL? {
        let pathDirectories = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        var seen: Set<String> = []
        for path in pathDirectories.map({ "\($0)/claude" }) + candidatePaths(home: home)
        where seen.insert(path).inserted && path.hasPrefix("/") && isExecutable(path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    static func locateWithLoginShell(environment: [String: String] = ProcessInfo.processInfo.environment) async -> URL? {
        let shell = environment["SHELL"].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? "/bin/zsh"
        guard FileManager.default.isExecutableFile(atPath: shell),
              let output = try? await ClaudeCodeProcess.run(
                executable: URL(fileURLWithPath: shell),
                arguments: ["-lc", "command -v claude"],
                environment: environment,
                timeout: .seconds(5)) else { return nil }
        let path = String(decoding: output.stdout, as: UTF8.self)
            .split(separator: "\n").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    static func environment(for executable: URL,
                            base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = base
        environment.removeValue(forKey: "CLAUDECODE")
        var path = [executable.deletingLastPathComponent().path]
        path += (base["PATH"] ?? "").split(separator: ":").map(String.init)
        path += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        var seen: Set<String> = []
        environment["PATH"] = path.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
        return environment
    }

    struct AuthStatus: Equatable, Sendable {
        var loggedIn: Bool
        var authMethod: String?
        var email: String?
        var subscriptionType: String?

        init(loggedIn: Bool, authMethod: String? = nil, email: String? = nil, subscriptionType: String? = nil) {
            self.loggedIn = loggedIn
            self.authMethod = authMethod
            self.email = email
            self.subscriptionType = subscriptionType
        }

        init?(json data: Data) {
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let loggedIn = json["loggedIn"] as? Bool else { return nil }
            self.loggedIn = loggedIn
            authMethod = json["authMethod"] as? String
            email = json["email"] as? String
            subscriptionType = json["subscriptionType"] as? String
        }

        var usesSubscription: Bool { authMethod == "claude.ai" }

        var planName: String? {
            guard let subscriptionType, !subscriptionType.isEmpty else { return nil }
            return subscriptionType.prefix(1).uppercased() + subscriptionType.dropFirst()
        }
    }

    static func authStatus(executable: URL) async throws -> AuthStatus {
        let output = try await ClaudeCodeProcess.run(
            executable: executable, arguments: ["auth", "status"],
            environment: environment(for: executable), timeout: .seconds(20))
        guard let status = AuthStatus(json: output.stdout) else {
            throw ClaudePlanError.failed("Claude Code didn't report its sign-in status. Update Claude Code and try again.")
        }
        return status
    }

    static func version(executable: URL) async -> String? {
        guard let output = try? await ClaudeCodeProcess.run(
            executable: executable, arguments: ["--version"],
            environment: environment(for: executable), timeout: .seconds(20)) else { return nil }
        let text = String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : String(text.prefix(80))
    }
}

actor ClaudeCodeLocator {
    static let shared = ClaudeCodeLocator()
    private var cached: URL?

    func executable(refresh: Bool = false) async -> URL? {
        if !refresh, let cached, FileManager.default.isExecutableFile(atPath: cached.path) { return cached }
        var found = ClaudeCodeCLI.locate()
        if found == nil { found = await ClaudeCodeCLI.locateWithLoginShell() }
        cached = found
        return found
    }
}

enum ClaudePlanError: LocalizedError, Equatable, Sendable {
    case notInstalled
    case signInRequired
    case usageLimitReached(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            "Claude Code isn't installed on this Mac. Install it, sign in by running claude in Terminal, then choose Claude plan again under Settings → Models → Think."
        case .signInRequired:
            "Claude Code isn't signed in. Open Terminal, run claude, and sign in with your Claude account. LokalBot never sees your Claude sign-in."
        case .usageLimitReached(let detail):
            "Your Claude plan's usage limit was reached. \(detail)".trimmingCharacters(in: .whitespaces)
        case .failed(let detail):
            detail
        }
    }
}

enum ClaudeCodeProcess {
    typealias Output = PlanCLIProcess.Output

    static func run(executable: URL, arguments: [String], environment: [String: String],
                    workingDirectory: URL? = nil, input: Data = Data(),
                    timeout: Duration = .seconds(900),
                    onLine: (@Sendable (String) -> Void)? = nil) async throws -> Output {
        try await PlanCLIProcess.run(
            executable: executable,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            input: input,
            timeout: timeout,
            programName: "Claude Code",
            notInstalledError: ClaudePlanError.notInstalled,
            failedError: ClaudePlanError.failed,
            onLine: onLine)
    }
}
