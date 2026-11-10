import Foundation

/// The user's own Claude Code installation, run unmodified in print mode.
/// The user signs in to Claude Code through Anthropic's own flow
/// (`claude`, then `/login`); LokalBot never reads, stores, or forwards
/// Claude credentials, and never offers a Claude login of its own.
enum ClaudeCodeCLI {
    /// Where Claude Code's installers put `claude`, checked after PATH.
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

    /// The first executable `claude` on PATH or in a known install location.
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

    /// An app opened from Finder has a minimal PATH, so a Claude Code under a
    /// Node version manager is only found through the user's login shell.
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

    /// The child environment: LokalBot's own, with the executable's folder
    /// first on PATH so an npm-installed `claude` finds its `node`.
    static func environment(for executable: URL,
                            base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = base
        // Started from inside a Claude Code session (development), the child
        // would otherwise refuse to run as a nested session.
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

        /// True when requests draw on a Claude subscription rather than an
        /// API key or cloud provider configured for Claude Code.
        var usesSubscription: Bool { authMethod == "claude.ai" }

        var planName: String? {
            guard let subscriptionType, !subscriptionType.isEmpty else { return nil }
            return subscriptionType.prefix(1).uppercased() + subscriptionType.dropFirst()
        }
    }

    /// `claude auth status` reports the sign-in without exposing credentials.
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

/// Finds Claude Code once per launch; a manual check looks again.
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

// MARK: - Process

/// Runs one short-lived child process: writes stdin, collects stdout (or
/// hands it over line by line) and a bounded stderr tail, and terminates the
/// child when the calling task is cancelled or the timeout passes.
enum ClaudeCodeProcess {
    struct Output: Sendable {
        var status: Int32
        var stdout: Data
        var stderrTail: String
    }

    static func run(executable: URL, arguments: [String], environment: [String: String],
                    workingDirectory: URL? = nil, input: Data = Data(),
                    timeout: Duration = .seconds(900),
                    onLine: (@Sendable (String) -> Void)? = nil) async throws -> Output {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw ClaudePlanError.notInstalled
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        if let workingDirectory { process.currentDirectoryURL = workingDirectory }
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        let collector = OutputCollector(onLine: onLine)
        let finished = DispatchGroup()
        finished.enter()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                collector.finishStdout()
                finished.leave()
            } else {
                collector.appendStdout(data)
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { collector.appendStderr(data) }
        }
        finished.enter()
        process.terminationHandler = { _ in finished.leave() }

        let writer = stdin.fileHandleForWriting
        // A child that exits early closes its end: the write must fail with
        // EPIPE instead of raising SIGPIPE, which would end LokalBot.
        _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
        do {
            try process.run()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            throw ClaudePlanError.failed("Claude Code couldn't start: \(error.localizedDescription)")
        }
        DispatchQueue.global(qos: .userInitiated).async {
            try? writer.write(contentsOf: input)
            try? writer.close()
        }
        let stopper = ProcessStopper(process)
        let timeoutTask = Task {
            try? await Task.sleep(for: timeout)
            if !Task.isCancelled { stopper.stop(reason: "timed out") }
        }
        defer { timeoutTask.cancel() }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                finished.notify(queue: .global()) { continuation.resume() }
            }
        } onCancel: {
            stopper.stop(reason: "cancelled")
        }
        if Task.isCancelled { throw CancellationError() }
        if stopper.reason == "timed out" {
            // Short limits (the 20-second sign-in check) are named in seconds:
            // whole minutes turned them into "0 minutes".
            let seconds = timeout.components.seconds
            let limit = seconds < 60 ? "\(seconds) seconds"
                : seconds < 120 ? "1 minute" : "\(seconds / 60) minutes"
            throw ClaudePlanError.failed("Claude Code didn't finish within \(limit).")
        }
        return Output(status: process.terminationStatus, stdout: collector.stdout, stderrTail: collector.stderrTail)
    }

    private final class OutputCollector: @unchecked Sendable {
        private let lock = NSLock()
        private let onLine: (@Sendable (String) -> Void)?
        private var stdoutData = Data()
        private var pendingLine = Data()
        private var stderrData = Data()

        init(onLine: (@Sendable (String) -> Void)?) {
            self.onLine = onLine
        }

        var stdout: Data { lock.withLock { stdoutData } }
        var stderrTail: String { lock.withLock { String(decoding: stderrData, as: UTF8.self) } }

        func appendStdout(_ data: Data) {
            var lines: [String] = []
            lock.withLock {
                stdoutData.append(data)
                guard onLine != nil else { return }
                pendingLine.append(data)
                while let newline = pendingLine.firstIndex(of: 0x0A) {
                    lines.append(String(decoding: pendingLine[pendingLine.startIndex..<newline], as: UTF8.self))
                    pendingLine.removeSubrange(pendingLine.startIndex...newline)
                }
            }
            lines.forEach { onLine?($0) }
        }

        func finishStdout() {
            let last: String? = lock.withLock {
                guard onLine != nil, !pendingLine.isEmpty else { return nil }
                defer { pendingLine.removeAll() }
                return String(decoding: pendingLine, as: UTF8.self)
            }
            if let last { onLine?(last) }
        }

        func appendStderr(_ data: Data) {
            lock.withLock {
                stderrData.append(data)
                if stderrData.count > 16_384 { stderrData = stderrData.suffix(16_384) }
            }
        }
    }

    private final class ProcessStopper: @unchecked Sendable {
        private let process: Process
        private let lock = NSLock()
        private var stopReason: String?

        init(_ process: Process) {
            self.process = process
        }

        var reason: String? { lock.withLock { stopReason } }

        func stop(reason: String) {
            let first: Bool = lock.withLock {
                guard stopReason == nil else { return false }
                stopReason = reason
                return true
            }
            guard first, process.isRunning else { return }
            process.terminate()
            let process = process
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
    }
}
