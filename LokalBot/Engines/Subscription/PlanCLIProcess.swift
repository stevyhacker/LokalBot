import Foundation

enum PlanCLIProcess {
    struct Output: Sendable {
        var status: Int32
        var stdout: Data
        var stderrTail: String
    }

    static func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL? = nil,
        input: Data = Data(),
        timeout: Duration = .seconds(900),
        programName: String,
        notInstalledError: @autoclosure () -> Error,
        failedError: (String) -> Error,
        onLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> Output {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw notInstalledError()
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
        _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
        do {
            try process.run()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            throw failedError("\(programName) couldn't start: \(error.localizedDescription)")
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
            let seconds = timeout.components.seconds
            let limit = seconds < 60 ? "\(seconds) seconds"
                : seconds < 120 ? "1 minute" : "\(seconds / 60) minutes"
            throw failedError("\(programName) didn't finish within \(limit).")
        }
        return Output(status: process.terminationStatus, stdout: collector.stdout, stderrTail: collector.stderrTail)
    }

    static func withPrivateDirectory<T>(
        prefix: String,
        files: [String: Data],
        failedError: (String) -> Error,
        body: (URL) async throws -> T
    ) async throws -> T {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        for (name, data) in files {
            let url = directory.appendingPathComponent(name)
            let parent = url.deletingLastPathComponent()
            if parent.path != directory.path {
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
            }
            guard FileManager.default.createFile(atPath: url.path, contents: data,
                                                 attributes: [.posixPermissions: 0o600]) else {
                throw failedError("LokalBot couldn't prepare the request.")
            }
        }
        return try await body(directory)
    }

    static func locateWithLoginShell(
        command: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async -> URL? {
        let shell = environment["SHELL"].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? "/bin/zsh"
        guard FileManager.default.isExecutableFile(atPath: shell),
              let output = try? await run(
                executable: URL(fileURLWithPath: shell),
                arguments: ["-lc", "command -v \(command)"],
                environment: environment,
                timeout: .seconds(5),
                programName: command,
                notInstalledError: CancellationError(),
                failedError: { _ in CancellationError() }) else { return nil }
        let path = String(decoding: output.stdout, as: UTF8.self)
            .split(separator: "\n").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
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
