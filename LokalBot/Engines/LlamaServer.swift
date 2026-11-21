import Foundation
import Darwin

enum MainLLMRuntimePolicy {
    static let contextTokens = 32_768
    static let highReasoningBudgetTokens = 8_192
    static let serverExtraArguments = [
        "--cache-ram", "2048",
        "--reasoning", "on",
    ]

    static func requestOverrides(for modelID: String) -> [String: Any] {
        switch modelID {
        case "lfm2.5-2.6b":
            return [
                "temperature": 0.1,
                "top_k": 50,
                "repeat_penalty": 1.1,
            ]
        case "ministral-3-3b-instruct-2512":
            return ["temperature": 0.05]
        default:
            return [:]
        }
    }
}

actor LlamaServer {

    static let shared = LlamaServer(
        role: .main, contextTokens: MainLLMRuntimePolicy.contextTokens,
        extraArgs: MainLLMRuntimePolicy.serverExtraArguments,
        runtimeAllowanceBytes: 3 * 1_073_741_824)
    static let embedder = LlamaServer(role: .embedder, contextTokens: 2_048,
                                      extraArgs: ["--embeddings", "-b", "2048", "-ub", "2048",
                                                  "--parallel", "1"],
                                      runtimeAllowanceBytes: 384 * 1_048_576)
    static let cotyping = LlamaServer(
        role: .cotyping, contextTokens: 4_096,
        extraArgs: ["--parallel", "1", "--cache-ram", "512"],
        runtimeAllowanceBytes: 768 * 1_048_576)

    nonisolated let port: Int
    nonisolated let role: LlamaServerRole?
    nonisolated let contextTokens: Int
    private let extraArgs: [String]
    private let environment: [String: String]
    private let runtimeAllowanceBytes: Int64
    nonisolated var baseURL: URL { URL(string: "http://127.0.0.1:\(port)/v1")! }

    init(role: LlamaServerRole, contextTokens: Int, extraArgs: [String],
         environment: [String: String] = [:],
         runtimeAllowanceBytes: Int64 = 512 * 1_048_576) {
        self.init(port: role.port, role: role, contextTokens: contextTokens,
                  extraArgs: extraArgs, environment: environment,
                  runtimeAllowanceBytes: runtimeAllowanceBytes)
    }

    init(port: Int, contextTokens: Int, extraArgs: [String],
         runtimeAllowanceBytes: Int64 = 512 * 1_048_576) {
        self.init(port: port, role: nil, contextTokens: contextTokens,
                  extraArgs: extraArgs, environment: [:],
                  runtimeAllowanceBytes: runtimeAllowanceBytes)
    }

    private init(port: Int, role: LlamaServerRole?, contextTokens: Int, extraArgs: [String],
                 environment: [String: String], runtimeAllowanceBytes: Int64) {
        self.port = port
        self.role = role
        self.contextTokens = contextTokens
        self.extraArgs = extraArgs
        self.environment = environment
        self.runtimeAllowanceBytes = runtimeAllowanceBytes
    }

    private var process: Process?
    private var processStartedAt: Date?
    private var loadedModelPath: String?
    private var loadedAuthenticationToken: String?
    private var residencyGeneration: UUID?
    private var outputTail: LlamaServerOutputTail?
    private let startup = AsyncSingleFlight()
    private let ownerID = UUID()
    private var ownershipLock: LocalRuntimeOwnershipLock?

    func authenticationToken() -> String {
        if let loadedAuthenticationToken { return loadedAuthenticationToken }
        if let markerToken = readPidMarker()?.authenticationToken {
            loadedAuthenticationToken = markerToken
            persistAuthenticationToken(markerToken)
            return markerToken
        }
        if let data = try? Data(contentsOf: authenticationTokenURL),
           let saved = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           saved.count >= 32 {
            loadedAuthenticationToken = saved
            return saved
        }
        let created = Self.makeAuthenticationToken()
        loadedAuthenticationToken = created
        persistAuthenticationToken(created)
        return created
    }

    enum ServerError: LocalizedError {
        case binaryMissing
        case modelMissing(String)
        case failedToStart(String)
        var errorDescription: String? {
            switch self {
            case .binaryMissing: "Bundled llama-server is missing from the app."
            case .modelMissing(let name): "Model \(name) is not downloaded yet (Settings → Models)."
            case .failedToStart(let detail): "Local LLM server failed to start: \(detail)"
            }
        }
    }
    static let startupHealthInterval: Duration = .milliseconds(500)
    static let startupHealthAttempts = 600


    func ensureRunning(modelAt url: URL) async throws {
        while true {
            if let process, process.isRunning, loadedModelPath == url.path,
               await healthy(), await healthyServingExpectedConfiguration(modelAt: url) {
                await registerResidency(modelAt: url)
                return
            }
            try await startup.run { [weak self] in
                guard let self else {
                    throw ServerError.failedToStart("server was released during startup")
                }
                try await self.ensureRunningOnce(modelAt: url)
            }
            guard loadedModelPath == url.path else { continue }
            await registerResidency(modelAt: url)
            return
        }
    }

    private func ensureRunningOnce(modelAt url: URL) async throws {
        if let process, process.isRunning, loadedModelPath == url.path,
           await healthy(), await healthyServingExpectedConfiguration(modelAt: url) {
            return
        }
        try await start(modelAt: url)
    }

    private nonisolated var residencyID: String { role?.residencyID ?? "llama-server:\(port)" }

    private func registerResidency(modelAt url: URL) async {
        let identity = activeProcessIdentity(modelAt: url)
        let generation = UUID()
        residencyGeneration = generation
        await ModelResidency.shared.register(
            id: residencyID,
            label: url.lastPathComponent,
            bytes: estimatedResidentBytes(modelAt: url),
            processIdentifier: identity?.processIdentifier,
            processStartTime: identity?.startTime,
            generation: generation,
            unload: { [weak self] in await self?.stop() })
    }

    private func activeProcessIdentity(
        modelAt url: URL
    ) -> SystemResourceSampler.ProcessIdentity? {
        if let process, process.isRunning,
           loadedModelPath == url.path,
           let usage = SystemResourceSampler.processUsage(for: process.processIdentifier) {
            return usage.identity
        }
        guard let marker = readPidMarker(),
              marker.ownerID == ownerID,
              marker.port == port,
              marker.modelPath == url.path,
              marker.contextTokens == Optional(contextTokens),
              marker.extraArgs == Optional(extraArgs),
              kill(marker.pid, 0) == 0,
              Self.processPath(for: marker.pid) == marker.binaryPath,
              let usage = SystemResourceSampler.processUsage(for: marker.pid)
        else { return nil }
        return usage.identity
    }

    private func start(modelAt url: URL) async throws {
        await stop()
        ownershipLock = try LocalRuntimeOwnershipLock.acquire(
            at: pidMarkerURL.appendingPathExtension("owner-lock"))
        let binary: URL
        do { binary = try installedBinary() } catch { ownershipLock = nil; throw error }
        if claimOrphanedMarker() {
            await stopRecordedServerIfOwned()
        }
        var listeners = Self.listeningPIDs(onPort: port)
        if !listeners.isEmpty, !(await Self.stopOrphanedHelpers(listeners, port: port)).isEmpty {
            listeners = Self.listeningPIDs(onPort: port)
        }
        guard listeners.isEmpty else {
            ownershipLock = nil
            throw ServerError.failedToStart(
                "port \(port) is already in use. Close the other LokalBot instance or local server and try again")
        }
        let loadReservation = await ModelResidency.shared.willLoad(
            id: residencyID,
            bytes: estimatedResidentBytes(modelAt: url),
            currentReservedBytes: { Int64(clamping: ModelRuntimeRegistry.shared.totalEstimatedBytes) })
        do {
            try Task.checkCancellation()
            let authenticationToken = authenticationToken()
            let process = Process()
            process.executableURL = binary
            process.arguments = [
                "-m", url.path,
                "--host", "127.0.0.1", "--port", String(port),
                "-c", String(contextTokens),
                "-ngl", "99",
                "--jinja",
                "--no-webui",
                "--api-key", authenticationToken,
            ] + extraArgs
            if !environment.isEmpty {
                process.environment = ProcessInfo.processInfo.environment
                    .merging(environment) { _, added in added }
            }
            process.standardOutput = FileHandle.nullDevice
            let output = LlamaServerOutputTail()
            let errorPipe = Pipe()
            output.attach(to: errorPipe)
            process.standardError = errorPipe
            process.terminationHandler = { [weak self] process in
                let processIdentifier = process.processIdentifier
                let status = process.terminationStatus
                let reason = process.terminationReason == .exit ? "exit" : "signal"
                Task {
                    await self?.processDidTerminate(
                        processIdentifier,
                        status: status,
                        reason: reason)
                }
            }
            try process.run()
            self.process = process
            outputTail = output
            processStartedAt = Date()
            loadedModelPath = url.path
            loadedAuthenticationToken = authenticationToken
            writePidMarker(LocalLlamaServerMarker(
                pid: process.processIdentifier,
                port: port,
                binaryPath: binary.path,
                modelPath: url.path,
                contextTokens: contextTokens,
                extraArgs: extraArgs,
                authenticationToken: authenticationToken,
                ownerID: ownerID,
                ownerPID: getpid(),
                ownerStartTime: SystemResourceSampler.processUsage(for: getpid())?.startTime,
                processStartTime: SystemResourceSampler.processUsage(for: process.processIdentifier)?.startTime))

            for _ in 0..<Self.startupHealthAttempts {
                try await Task.sleep(for: Self.startupHealthInterval)
                if !process.isRunning {
                    throw ServerError.failedToStart(
                        await startupFailure("llama-server exited during startup", output: output))
                }
                if await healthy() {
                    output.serverIsReady()
                    return
                }
            }
            throw ServerError.failedToStart(
                await startupFailure("server did not become healthy in time", output: output))
        } catch {
            await ModelResidency.shared.cancelLoad(loadReservation)
            await stop()
            throw error
        }
    }

    private func estimatedResidentBytes(modelAt url: URL) -> Int64 {
        var total = ModelResidency.weightBytes(at: url)
        if let projectorFlag = extraArgs.firstIndex(of: "--mmproj"),
           extraArgs.indices.contains(projectorFlag + 1) {
            total = Self.saturatingAdd(
                total,
                ModelResidency.weightBytes(
                    at: URL(fileURLWithPath: extraArgs[projectorFlag + 1])))
        }
        return Self.saturatingAdd(total, max(0, runtimeAllowanceBytes))
    }

    private func startupFailure(_ summary: String, output: LlamaServerOutputTail) async -> String {
        await output.settle()
        let lines = output.lines
        if !lines.isEmpty {
            lokalbotLog("llama-server startup output port=\(port): " + lines.joined(separator: " | "))
        }
        return output.reason.map { "\(summary): \($0)" } ?? summary
    }

    private nonisolated static func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? .max : result.partialValue
    }

    func stop() async {
        let old = process
        let generation = residencyGeneration
        process = nil
        processStartedAt = nil
        loadedModelPath = nil
        loadedAuthenticationToken = nil
        residencyGeneration = nil
        outputTail = nil
        if let old {
            removePidMarker(ifMatching: old.processIdentifier)
            if old.isRunning {
                old.terminate()
                for _ in 0..<40 {
                    if !old.isRunning { break }
                    try? await Task.sleep(for: .milliseconds(50))
                }
                if old.isRunning {
                    kill(old.processIdentifier, SIGKILL)
                }
            }
        } else if ownershipLock != nil {
            await stopRecordedServerIfOwned()
        }
        if let generation {
            await ModelResidency.shared.unregister(
                id: residencyID,
                ifGenerationMatches: generation)
        }
        ownershipLock = nil
    }

    private func processDidTerminate(
        _ processIdentifier: pid_t,
        status: Int32,
        reason: String
    ) async {
        guard process?.processIdentifier == processIdentifier else { return }
        let uptime = processStartedAt.map { Date().timeIntervalSince($0) }
        let model = loadedModelPath.map {
            URL(fileURLWithPath: $0).lastPathComponent
        } ?? "unknown"
        let uptimeDescription = uptime.map {
            String(format: "%.2fs", $0)
        } ?? "unknown"
        let output = outputTail
        let generation = residencyGeneration
        outputTail = nil
        process = nil
        processStartedAt = nil
        loadedModelPath = nil
        loadedAuthenticationToken = nil
        residencyGeneration = nil
        ownershipLock = nil
        removePidMarker(ifMatching: processIdentifier)
        if let generation {
            await ModelResidency.shared.unregister(
                id: residencyID,
                ifGenerationMatches: generation)
        }
        var lastOutput: [String] = []
        if let output, output.isReady {
            await output.settle()
            lastOutput = output.lines
        }
        lokalbotLog(
            "llama-server terminated unexpectedly port=\(port) pid=\(processIdentifier) "
                + "model=\(model) reason=\(reason) status=\(status) uptime="
                + uptimeDescription
                + (lastOutput.isEmpty ? "" : " output: " + lastOutput.joined(separator: " | ")))
    }

    private func stopRecordedServerIfOwned() async {
        guard ownershipLock != nil, let marker = readPidMarker(),
              marker.ownerID == ownerID,
              let startTime = marker.processStartTime,
              SystemResourceSampler.processUsage(for: marker.pid)?.startTime == startTime else { return }
        let pid = marker.pid
        guard marker.port == port else {
            removePidMarker(ifMatching: pid)
            return
        }
        guard kill(pid, 0) == 0 else {
            removePidMarker(ifMatching: pid)
            return
        }
        guard Self.processPath(for: pid) == marker.binaryPath else { return }
        kill(pid, SIGTERM)
        for _ in 0..<40 {
            if SystemResourceSampler.processUsage(for: pid)?.startTime != startTime {
                removePidMarker(ifMatching: pid)
                return
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        if SystemResourceSampler.processUsage(for: pid)?.startTime == startTime { kill(pid, SIGKILL) }
        removePidMarker(ifMatching: pid)
    }

    private func claimOrphanedMarker() -> Bool {
        guard ownershipLock != nil, var marker = readPidMarker(),
              LocalRuntimeOwnershipPolicy.canClaim(
                marker: marker,
                ownerIsAlive: marker.ownerPID.map { kill($0, 0) == 0 || errno == EPERM } ?? true,
                liveOwnerStartTime: marker.ownerPID.flatMap { SystemResourceSampler.processUsage(for: $0)?.startTime },
                liveHelperStartTime: SystemResourceSampler.processUsage(for: marker.pid)?.startTime),
              marker.port == port,
              Self.processPath(for: marker.pid) == marker.binaryPath else { return false }
        marker.ownerID = ownerID
        marker.ownerPID = getpid()
        marker.ownerStartTime = SystemResourceSampler.processUsage(for: getpid())?.startTime
        writePidMarker(marker)
        return readPidMarker()?.ownerID == ownerID
    }

    private func readPidMarker() -> LocalLlamaServerMarker? {
        guard let data = try? Data(contentsOf: pidMarkerURL) else { return nil }
        return try? JSONDecoder().decode(LocalLlamaServerMarker.self, from: data)
    }

    private func writePidMarker(_ marker: LocalLlamaServerMarker) {
        do {
            try FileManager.default.createDirectory(
                at: pidMarkerURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(marker)
            try data.write(to: pidMarkerURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: pidMarkerURL.path)
        } catch {
        }
    }

    private func removePidMarker(ifMatching processIdentifier: pid_t) {
        guard readPidMarker()?.pid == processIdentifier else { return }
        try? FileManager.default.removeItem(at: pidMarkerURL)
    }

    private var pidMarkerURL: URL {
        LocalLlamaServerAuthentication.markerURL(port: port)
    }

    private var authenticationTokenURL: URL {
        AppDirectories.localServerSupport
            .appendingPathComponent("llama-server-\(port).auth-token")
    }

    private func persistAuthenticationToken(_ token: String) {
        do {
            try FileManager.default.createDirectory(
                at: authenticationTokenURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try Data(token.utf8).write(to: authenticationTokenURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: authenticationTokenURL.path)
        } catch {
            lokalbotLog("llama-server: could not persist localhost authentication token")
        }
    }

    private func healthy() async -> Bool {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/health")!)
        if let token = loadedAuthenticationToken ?? readPidMarker()?.authenticationToken {
            LocalLlamaServerAuthentication.apply(to: &request, token: token)
        }
        request.timeoutInterval = 2
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    private func healthyServing(modelAt url: URL) async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("models"))
        guard let token = loadedAuthenticationToken ?? readPidMarker()?.authenticationToken else {
            return false
        }
        LocalLlamaServerAuthentication.apply(to: &request, token: token)
        request.timeoutInterval = 2
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
        return Self.servesModel(at: url, names: Self.servedModelNames(from: data))
    }

    private func healthyServingExpectedConfiguration(modelAt url: URL) async -> Bool {
        guard await healthyServing(modelAt: url),
              let marker = readPidMarker(),
              marker.ownerID == ownerID,
              marker.port == port,
              marker.modelPath == url.path,
              marker.contextTokens == Optional(contextTokens),
              marker.extraArgs == Optional(extraArgs),
              kill(marker.pid, 0) == 0,
              Self.processPath(for: marker.pid) == marker.binaryPath
        else { return false }
        return true
    }

    nonisolated static func modelMatchKey(for url: URL) -> String {
        url.lastPathComponent
    }

    nonisolated static func servesModel(at url: URL, names: Set<String>) -> Bool {
        names.contains(url.path) || names.contains(modelMatchKey(for: url))
    }

    nonisolated static func servedModelNames(from data: Data) -> Set<String> {
        guard let payload = try? JSONDecoder().decode(ModelListPayload.self, from: data) else { return [] }
        var names = Set<String>()
        for model in payload.models ?? [] {
            if let name = model.name, !name.isEmpty { names.insert(name) }
            if let model = model.model, !model.isEmpty { names.insert(model) }
        }
        for model in payload.data ?? [] {
            if let id = model.id, !id.isEmpty { names.insert(id) }
        }
        return names
    }

    nonisolated static func processPath(for pid: pid_t) -> String? {
        let bufferSize = 4096
        var buffer = [CChar](repeating: 0, count: bufferSize)
        let result = buffer.withUnsafeMutableBufferPointer { pointer in
            proc_pidpath(pid, pointer.baseAddress, UInt32(bufferSize))
        }
        guard result > 0 else { return nil }
        return String(cString: buffer)
    }

    nonisolated static func listeningPIDs(onPort port: Int) -> [pid_t] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(whereSeparator: { $0.isWhitespace })
            .compactMap { pid_t($0) }
    }

    nonisolated static func stopOrphanedHelpers(
        _ listeners: [pid_t], port: Int,
        applicationSupport: URL = AppDirectories.userApplicationSupport
    ) async -> [pid_t] {
        var stopped: [pid_t] = []
        for pid in Set(listeners).sorted() {
            guard let orphan = orphanedHelper(pid: pid, applicationSupport: applicationSupport) else {
                continue
            }
            let isGone = await terminate(pid, startTime: orphan.startTime)
            lokalbotLog("llama-server: " + (isGone ? "stopped" : "could not stop")
                        + " an orphaned helper holding port \(port) pid=\(pid) "
                        + "runtime=\(orphan.folder.lastPathComponent)")
            if isGone { stopped.append(pid) }
        }
        return stopped
    }

    nonisolated static func orphanedHelper(
        pid: pid_t, applicationSupport: URL
    ) -> (folder: URL, startTime: UInt64)? {
        let root = URL(fileURLWithPath: realPath(applicationSupport.path) ?? applicationSupport.path,
                       isDirectory: true)
        guard pid > 1, pid != getpid(),
              parentProcessIdentifier(of: pid) == 1,
              let executable = processPath(for: pid),
              let folder = OrphanedLlamaServerPolicy.runtimeFolder(forExecutable: executable, under: root),
              let startTime = SystemResourceSampler.processUsage(for: pid)?.startTime,
              let markers = recordedMarkers(in: folder)
        else { return nil }
        let hasLiveOwner = markers.contains { marker in
            guard marker.pid == pid else { return false }
            let ownerPID = marker.ownerPID ?? 0
            return OrphanedLlamaServerPolicy.markerShowsLiveOwner(
                marker,
                helperStartTime: startTime,
                ownerExists: ownerPID > 0 && (kill(ownerPID, 0) == 0 || errno == EPERM),
                liveOwnerStartTime: ownerPID > 0
                    ? SystemResourceSampler.processUsage(for: ownerPID)?.startTime : nil)
        }
        return hasLiveOwner ? nil : (folder, startTime)
    }

    nonisolated static func parentProcessIdentifier(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbi_ppid)
    }

    private nonisolated static func recordedMarkers(in folder: URL) -> [LocalLlamaServerMarker]? {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil) else { return nil }
        return files
            .filter { $0.lastPathComponent.hasPrefix("llama-server-") && $0.lastPathComponent.hasSuffix(".pid.json") }
            .compactMap { try? Data(contentsOf: $0) }
            .compactMap { try? JSONDecoder().decode(LocalLlamaServerMarker.self, from: $0) }
    }

    private nonisolated static func terminate(_ pid: pid_t, startTime: UInt64) async -> Bool {
        func isRunning() -> Bool {
            SystemResourceSampler.processUsage(for: pid)?.startTime == startTime
        }
        guard isRunning() else { return true }
        kill(pid, SIGTERM)
        for _ in 0..<40 {
            if !isRunning() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        if isRunning() { kill(pid, SIGKILL) }
        for _ in 0..<20 {
            if !isRunning() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return !isRunning()
    }

    private nonisolated static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private nonisolated static func makeAuthenticationToken() -> String {
        (UUID().uuidString + UUID().uuidString)
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
    }

    private struct ModelListPayload: Decodable {
        var models: [ListedModel]?
        var data: [ListedModel]?
    }

    private struct ListedModel: Decodable {
        var id: String?
        var name: String?
        var model: String?
    }

    private func installedBinary() throws -> URL {
        guard let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("llama-cpp", isDirectory: true),
              FileManager.default.fileExists(atPath: bundled.appendingPathComponent("llama-server").path)
        else { throw ServerError.binaryMissing }

        let installed = AppDirectories.localServerSupport
            .appendingPathComponent("llama-cpp", isDirectory: true)
        return try NativeRuntimeInstaller.install(
            bundled: bundled, root: installed, executables: ["llama-server"])
            .appendingPathComponent("llama-server")
    }
}

enum LocalRuntimeOwnershipPolicy {
    static func canClaim(marker: LocalLlamaServerMarker, ownerIsAlive: Bool,
                         liveOwnerStartTime: UInt64?, liveHelperStartTime: UInt64?) -> Bool {
        guard marker.ownerID != nil, let ownerPID = marker.ownerPID, ownerPID > 0,
              let ownerStart = marker.ownerStartTime,
              let helperStart = marker.processStartTime,
              liveHelperStartTime == helperStart else { return false }
        if ownerIsAlive {
            guard let liveOwnerStartTime else { return false }
            return liveOwnerStartTime != ownerStart
        }
        return true
    }
}

enum OrphanedLlamaServerPolicy {
    static func runtimeFolder(forExecutable path: String, under applicationSupport: URL) -> URL? {
        let root = applicationSupport.standardizedFileURL.path
        let executable = URL(fileURLWithPath: path).standardizedFileURL.path
        guard executable.hasPrefix(root + "/") else { return nil }
        let components = executable.dropFirst(root.count + 1).split(separator: "/").map(String.init)
        guard components.count >= 3,
              components[0] == AppIdentifiers.appBundleID
                || components[0].hasPrefix(AppIdentifiers.appBundleID + "."),
              components[1] == "llama-cpp",
              components.last == "llama-server" else { return nil }
        return applicationSupport.appendingPathComponent(components[0], isDirectory: true)
    }

    static func markerShowsLiveOwner(_ marker: LocalLlamaServerMarker, helperStartTime: UInt64,
                                     ownerExists: Bool, liveOwnerStartTime: UInt64?) -> Bool {
        if let recorded = marker.processStartTime, recorded != helperStartTime { return false }
        guard let ownerPID = marker.ownerPID, ownerPID > 0, ownerExists else { return false }
        guard let recordedOwnerStart = marker.ownerStartTime,
              let liveOwnerStartTime else { return true }
        return recordedOwnerStart == liveOwnerStartTime
    }
}

final class LocalRuntimeOwnershipLock {
    private let descriptor: Int32
    private init(_ descriptor: Int32) { self.descriptor = descriptor }

    static func acquire(at path: URL) throws -> LocalRuntimeOwnershipLock {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(path.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            throw LlamaServer.ServerError.failedToStart("could not establish exclusive local server ownership")
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw LlamaServer.ServerError.failedToStart("another LokalBot instance owns this local server")
        }
        return LocalRuntimeOwnershipLock(descriptor)
    }

    deinit { close(descriptor) }
}

final class LlamaServerOutputTail: @unchecked Sendable {
    static let maximumLines = 12
    static let maximumLineCharacters = 300
    static let crashMarkers = ["ggml_assert", "ggml_metal", "out of memory", "insufficient memory",
                               "failed to allocate", "terminating", "abort", "segmentation fault"]

    private let lock = NSLock()
    private var pending = Data()
    private var kept: [String] = []
    private var keepsEveryLine = true
    private var finished = false

    func attach(to pipe: Pipe) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else {
                handle.readabilityHandler = nil
                self?.finish()
                return
            }
            self.append(data)
        }
    }

    func serverIsReady() {
        lock.withLock { keepsEveryLine = false }
    }

    func append(_ data: Data) {
        lock.withLock {
            pending.append(data)
            while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                keep(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
                pending.removeSubrange(pending.startIndex...newline)
            }
            if pending.count > 4 * Self.maximumLineCharacters {
                keep(String(decoding: pending, as: UTF8.self))
                pending.removeAll()
            }
        }
    }

    func finish() {
        lock.withLock {
            if !pending.isEmpty {
                keep(String(decoding: pending, as: UTF8.self))
                pending.removeAll()
            }
            finished = true
        }
    }

    var isReady: Bool { lock.withLock { !keepsEveryLine } }
    var isFinished: Bool { lock.withLock { finished } }
    var lines: [String] { lock.withLock { kept } }

    var reason: String? {
        let lines = self.lines
        return lines.first { line in
            ["error", "failed", "ggml_assert"].contains { line.localizedCaseInsensitiveContains($0) }
        } ?? lines.last
    }

    func settle() async {
        for _ in 0..<10 where !isFinished {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func keep(_ raw: String) {
        var line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let prefix = line.range(of: #"^[0-9.]+ [A-Z] "#, options: .regularExpression) {
            line.removeSubrange(prefix)
        }
        guard !line.isEmpty else { return }
        if !keepsEveryLine {
            let lowered = line.lowercased()
            guard Self.crashMarkers.contains(where: lowered.contains),
                  !lowered.contains("last read") else { return }
        }
        kept.append(String(line.prefix(Self.maximumLineCharacters)))
        if kept.count > Self.maximumLines { kept.removeFirst(kept.count - Self.maximumLines) }
    }
}
