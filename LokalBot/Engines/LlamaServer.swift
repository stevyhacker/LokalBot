import Foundation
import Darwin

/// Shared quality policy for the Main LLM. The bundled models expose much
/// larger native windows, but 32K gives summaries and Agent Mode useful
/// headroom without paying the latency and linear KV-cache cost of 128K.
///
/// "High" forces model-native thinking. App-authored requests use an 8K
/// ceiling; requests that set a smaller total output budget reserve at least
/// half of it for the visible answer (see
/// `OpenAICompatibleEngine.applyGenerationOptions`). Agent Mode uses the same
/// reasoning-enabled server with its model-native budget.
enum MainLLMRuntimePolicy {
    static let contextTokens = 32_768
    static let highReasoningBudgetTokens = 8_192
    static let serverExtraArguments = [
        "--cache-ram", "2048",
        "--reasoning", "on",
    ]

    /// Keep vendor-specific sampling guidance scoped to the built-in model
    /// that requires it. `extraBody` is merged after per-request options, so
    /// these values consistently replace the generic digest temperature.
    static func requestOverrides(for modelID: String) -> [String: Any] {
        switch modelID {
        case "lfm2.5-2.6b":
            return [
                "temperature": 0.1,
                "top_k": 50,
                "repeat_penalty": 1.1,
            ]
        case "ministral-3-3b-instruct-2512":
            // Mistral recommends temperature below 0.1 for this checkpoint.
            return ["temperature": 0.05]
        default:
            return [:]
        }
    }
}

/// Built-in LLM backend, part 3 of 3: the bundled llama-server subprocess
/// lifecycle. One model loaded at a time; switching models restarts the server.
/// Stopped when the app quits.
actor LlamaServer {

    /// Chat/completions instance (summaries, digests, Q&A).
    static let shared = LlamaServer(
        port: 17872, contextTokens: MainLLMRuntimePolicy.contextTokens,
        extraArgs: MainLLMRuntimePolicy.serverExtraArguments,
        runtimeAllowanceBytes: 3 * 1_073_741_824)
    /// Embeddings instance (semantic search) — small model, second port.
    static let embedder = LlamaServer(port: 17873, contextTokens: 2_048,
                                      extraArgs: ["--embeddings", "--pooling", "last",
                                                  "--parallel", "1", "--cache-ram", "256"],
                                      runtimeAllowanceBytes: 384 * 1_048_576)
    /// Cotyping instance — an optional separate (typically smaller/faster)
    /// model on a third port, so inline suggestions never contend with the
    /// summarizer for the shared server (no model-reload thrash).
    static let cotyping = LlamaServer(
        port: 17874, contextTokens: 2_048,
        extraArgs: ["--parallel", "1", "--cache-ram", "512"],
        runtimeAllowanceBytes: 768 * 1_048_576)

    nonisolated let port: Int
    nonisolated let contextTokens: Int
    private let extraArgs: [String]
    private let runtimeAllowanceBytes: Int64
    nonisolated var baseURL: URL { URL(string: "http://127.0.0.1:\(port)/v1")! }

    init(port: Int, contextTokens: Int, extraArgs: [String],
         runtimeAllowanceBytes: Int64 = 512 * 1_048_576) {
        self.port = port
        self.contextTokens = contextTokens
        self.extraArgs = extraArgs
        self.runtimeAllowanceBytes = runtimeAllowanceBytes
    }

    private var process: Process?
    private var processStartedAt: Date?
    private var loadedModelPath: String?
    private var loadedAuthenticationToken: String?
    private var residencyGeneration: UUID?
    private let startup = AsyncSingleFlight()
    private let ownerID = UUID()
    private var ownershipLock: LocalRuntimeOwnershipLock?

    /// Shared bearer required by this private localhost server. It is created
    /// with 256 bits of randomness, stored mode 0600, and can be obtained
    /// before the lazy server boot so leased engines carry the right header.
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
            // A caller for a different model may have owned the flight we just
            // awaited. Loop so this request starts one replacement flight;
            // callers for the same model return together without duplicate
            // subprocess starts or health polling.
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

    /// This server's row in the app-wide model-memory ledger. Adopted healthy
    /// servers register too — their weights are just as resident as ours.
    private nonisolated var residencyID: String { "llama-server:\(port)" }

    private func registerResidency(modelAt url: URL) async {
        // Diagnostics must never gate inference. When libproc cannot provide a
        // stable process identity, retain the model row with its weight-size
        // estimate and let a later successful registration add live telemetry.
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
        // An orphan can be claimed only after its owning app exited and this
        // instance acquired the exclusive runtime lock.
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
        // A live app owns its helper even when this app wants the same model.
        // Never adopt it: our later eviction/shutdown would interrupt its work.
        if claimOrphanedMarker() {
            await stopRecordedServerIfOwned()
        }
        guard Self.listeningPIDs(onPort: port).isEmpty else {
            ownershipLock = nil
            throw ServerError.failedToStart(
                "port \(port) is already in use. Close the other LokalBot instance or local server and try again")
        }
        // Make room before the subprocess mmaps the weights: evict the
        // least-recently-used other models if this one would bust the budget.
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
                "-ngl", "99",           // full Metal offload
                "--jinja",              // correct chat templates (qwen3, gpt-oss)
                "--no-webui",
                "--api-key", authenticationToken,
            ] + extraArgs
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
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

            // Model load can take a while for the big ones; poll /health.
            for _ in 0..<240 {
                try await Task.sleep(for: .milliseconds(500))
                if !process.isRunning {
                    throw ServerError.failedToStart("llama-server exited during startup")
                }
                if await healthy() { return }
            }
            throw ServerError.failedToStart("server did not become healthy in time")
        } catch {
            await ModelResidency.shared.cancelLoad(loadReservation)
            await stop()
            throw error
        }
    }

    /// Weight files are not the whole llama footprint: prompt cache, KV, and
    /// multimodal projector allocations can be several GiB. Keep an explicit
    /// per-role allowance and include any `--mmproj` file in admission.
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
            // A healthy server can be adopted from a previous app process. It
            // has a validated PID marker but no Foundation `Process` handle;
            // still terminate it so eviction and the resource ledger reflect
            // real memory residency instead of only hiding the row.
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
        lokalbotLog(
            "llama-server terminated unexpectedly port=\(port) pid=\(processIdentifier) "
                + "model=\(model) reason=\(reason) status=\(status) uptime="
                + uptimeDescription)
        let generation = residencyGeneration
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
        // The old owned helper can be from the previous bundled runtime. Its
        // exact executable and start identity, not a filename suffix, prove it.
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
            // Best-effort orphan recovery only; startup must not depend on it.
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
        AppDirectories.applicationSupport
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

    /// llama.cpp builds report either the model's full path or its filename.
    /// Do not reduce a reported absolute path to a basename: a different file
    /// with the same name must fail. The caller also verifies the PID marker's
    /// exact model path, executable, context size and arguments before reuse.
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

    /// PIDs listening on `port`, via `lsof` (best-effort; empty if unavailable).
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

    /// llama-server + dylibs are copied out of the bundle into Application
    /// Support on first run (never execute from inside Resources), then
    /// reused. Re-copied if the bundled version changes.
    private func installedBinary() throws -> URL {
        guard let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("llama-cpp", isDirectory: true),
              FileManager.default.fileExists(atPath: bundled.appendingPathComponent("llama-server").path)
        else { throw ServerError.binaryMissing }

        let installed = AppDirectories.applicationSupport
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
        // An unavailable identity is uncertainty, not proof a live owner died.
        if ownerIsAlive {
            guard let liveOwnerStartTime else { return false }
            return liveOwnerStartTime != ownerStart
        }
        return true
    }
}

/// Held for the entire helper lifetime, including health checks and shutdown.
/// A second instance fails explicitly instead of sharing a process it can kill.
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
