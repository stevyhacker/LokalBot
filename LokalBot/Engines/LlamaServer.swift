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
        role: .main, contextTokens: MainLLMRuntimePolicy.contextTokens,
        extraArgs: MainLLMRuntimePolicy.serverExtraArguments,
        runtimeAllowanceBytes: 3 * 1_073_741_824)
    /// Embeddings instance (semantic search) — small model, second port.
    /// EmbeddingGemma's GGUF carries its own mean pooling and projection, so
    /// no pooling flag is passed (one would override them). As a bidirectional
    /// encoder it must see each input in a single micro-batch; real 1,500-
    /// character OCR reaches about 950 tokens, so batch at the full context.
    static let embedder = LlamaServer(role: .embedder, contextTokens: 2_048,
                                      extraArgs: ["--embeddings", "-b", "2048", "-ub", "2048",
                                                  "--parallel", "1"],
                                      runtimeAllowanceBytes: 384 * 1_048_576)
    /// Cotyping instance — an optional separate (typically smaller/faster)
    /// model on a third port, so inline suggestions never contend with the
    /// summarizer for the shared server (no model-reload thrash).
    static let cotyping = LlamaServer(
        role: .cotyping, contextTokens: 4_096,
        extraArgs: ["--parallel", "1", "--cache-ram", "512"],
        runtimeAllowanceBytes: 768 * 1_048_576)

    nonisolated let port: Int
    /// Nil for a private instance on an explicit port (tests, replays).
    nonisolated let role: LlamaServerRole?
    nonisolated let contextTokens: Int
    private let extraArgs: [String]
    /// Added to the inherited environment of the server process.
    private let environment: [String: String]
    private let runtimeAllowanceBytes: Int64
    nonisolated var baseURL: URL { URL(string: "http://127.0.0.1:\(port)/v1")! }

    /// One of the app's servers, on this app copy's port for `role`.
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
    /// How long a started server may take to report healthy. A Mac that has
    /// just booted can page a model in for minutes, and a load that crashes
    /// ends this wait at once, so the limit only has to catch a hung server.
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
    private nonisolated var residencyID: String { role?.residencyID ?? "llama-server:\(port)" }

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
        var listeners = Self.listeningPIDs(onPort: port)
        if !listeners.isEmpty, !(await Self.stopOrphanedHelpers(listeners, port: port)).isEmpty {
            listeners = Self.listeningPIDs(onPort: port)
        }
        guard listeners.isEmpty else {
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

            // Model load can take a while for the big ones; poll /health.
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

    /// Says why a start failed, from the server's own output; the full tail
    /// goes to the diagnostics log. No request has reached it yet.
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
        // A failed start reports its own output (`startupFailure`).
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

    /// Stops LokalBot llama-servers that hold `port` after their app died:
    /// reparented to launchd, running from a LokalBot `llama-cpp` runtime,
    /// and named by no PID marker with a live owner (an app that adopted it).
    /// Another copy (Dev, UI Test Host, unit tests, an older release) can
    /// leave one behind, and it would block this server until it is killed.
    /// Returns the PIDs that are gone.
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

    /// The runtime folder and start time of `pid` when it is a LokalBot
    /// llama-server whose owning app is gone; nil otherwise.
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

    /// Every PID marker in a runtime folder; nil when the folder cannot be
    /// read, which must not pass for "no live owner".
    private nonisolated static func recordedMarkers(in folder: URL) -> [LocalLlamaServerMarker]? {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil) else { return nil }
        return files
            .filter { $0.lastPathComponent.hasPrefix("llama-server-") && $0.lastPathComponent.hasSuffix(".pid.json") }
            .compactMap { try? Data(contentsOf: $0) }
            .compactMap { try? JSONDecoder().decode(LocalLlamaServerMarker.self, from: $0) }
    }

    /// SIGTERM, then SIGKILL after two seconds. The start time keeps a reused
    /// PID from being signalled. Returns whether the process is gone.
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

    /// llama-server + dylibs are copied out of the bundle into Application
    /// Support on first run (never execute from inside Resources), then
    /// reused. Re-copied if the bundled version changes.
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
        // An unavailable identity is uncertainty, not proof a live owner died.
        if ownerIsAlive {
            guard let liveOwnerStartTime else { return false }
            return liveOwnerStartTime != ownerStart
        }
        return true
    }
}

/// Recognizes a llama-server that a LokalBot copy started and then lost. Its
/// executable sits in a `llama-cpp` runtime under one of LokalBot's
/// Application Support folders, next to the PID markers that copy writes.
enum OrphanedLlamaServerPolicy {
    /// `<applicationSupport>/me.dotenv.LokalBot[.<suffix>]` when `path` is
    /// `<that folder>/llama-cpp/…/llama-server`; nil for anything else.
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

    /// Whether `marker` shows a live app owning the helper that started at
    /// `helperStartTime`. An owner whose identity cannot be confirmed counts
    /// as alive: a helper an app may still be using is never stopped.
    static func markerShowsLiveOwner(_ marker: LocalLlamaServerMarker, helperStartTime: UInt64,
                                     ownerExists: Bool, liveOwnerStartTime: UInt64?) -> Bool {
        // A marker left by an earlier process with this PID says nothing.
        if let recorded = marker.processStartTime, recorded != helperStartTime { return false }
        guard let ownerPID = marker.ownerPID, ownerPID > 0, ownerExists else { return false }
        guard let recordedOwnerStart = marker.ownerStartTime,
              let liveOwnerStartTime else { return true }
        return recordedOwnerStart == liveOwnerStartTime
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

/// The tail of llama-server's stderr, kept in memory to explain a failure.
/// Until the first health check passes the server has seen no request, so
/// every line is kept and a failed start can say why. After that only crash
/// lines are kept: request errors can echo request text, and diagnostic logs
/// never hold transcripts or screen text (PRIVACY.md).
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

    /// The server passed its first health check.
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
            // An unterminated line cannot grow without bound.
            if pending.count > 4 * Self.maximumLineCharacters {
                keep(String(decoding: pending, as: UTF8.self))
                pending.removeAll()
            }
        }
    }

    /// End of output: the process exited.
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

    /// The first line that reports an error; the lines after it are usually
    /// its consequences ("failed to load model", "exiting").
    var reason: String? {
        let lines = self.lines
        return lines.first { line in
            ["error", "failed", "ggml_assert"].contains { line.localizedCaseInsensitiveContains($0) }
        } ?? lines.last
    }

    /// Waits briefly for the last output of an exited process.
    func settle() async {
        for _ in 0..<10 where !isFinished {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Caller holds `lock`.
    private func keep(_ raw: String) {
        var line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // "0.00.077.284 E gguf_init_from_reader: …": drop the time and level.
        if let prefix = line.range(of: #"^[0-9.]+ [A-Z] "#, options: .regularExpression) {
            line.removeSubrange(prefix)
        }
        guard !line.isEmpty else { return }
        if !keepsEveryLine {
            let lowered = line.lowercased()
            // A JSON parse error quotes the text it was reading.
            guard Self.crashMarkers.contains(where: lowered.contains),
                  !lowered.contains("last read") else { return }
        }
        kept.append(String(line.prefix(Self.maximumLineCharacters)))
        if kept.count > Self.maximumLines { kept.removeFirst(kept.count - Self.maximumLines) }
    }
}
