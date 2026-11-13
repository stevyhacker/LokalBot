import XCTest
@testable import LokalBot

/// Pure-logic coverage for the llama-server lifecycle owner. Booting the real
/// subprocess belongs to e2e; these tests pin the invariants the rest of the
/// app builds on: loopback-only base URLs, the three distinct roles/ports, and
/// the /v1/models response parsing that health checks depend on.
final class LlamaServerTests: XCTestCase {

    func testOutputTailSaysWhyAStartFailed() {
        let tail = LlamaServerOutputTail()
        // Chunks split lines, as pipe reads do.
        // The shape of llama-server's real output for a corrupt model file.
        tail.append(Data("0.00.077.101 I llama_model_loader: loaded meta data\n0.00.077.284 E gguf_init_from_reader: failed ".utf8))
        tail.append(Data("to read header\n0.00.077.456 E llama_model_load_from_file_impl: failed to load model\n".utf8))
        tail.append(Data("0.00.077.732 E srv  llama_server: exiting due to model loading error".utf8))
        tail.finish()

        XCTAssertTrue(tail.isFinished)
        XCTAssertEqual(tail.lines.count, 4)
        XCTAssertEqual(tail.lines.last, "srv  llama_server: exiting due to model loading error")
        XCTAssertEqual(tail.reason, "gguf_init_from_reader: failed to read header")
    }

    /// Once the server answers requests, its errors can quote request text.
    func testOutputTailKeepsOnlyCrashLinesOnceServing() {
        let tail = LlamaServerOutputTail()
        tail.serverIsReady()
        tail.append(Data("""
            srv  log_server_r: request: POST /v1/chat/completions 127.0.0.1 200
            srv  send_error: error: [json.exception.parse_error.101] parse error; last read: '"Notes from the board meeting abort
            ggml_metal_graph_compute: command buffer 0 failed with status 5
            error: Insufficient Memory (00000008:kIOGPUCommandBufferCallbackErrorOutOfMemory)

            """.utf8))

        XCTAssertEqual(tail.lines, [
            "ggml_metal_graph_compute: command buffer 0 failed with status 5",
            "error: Insufficient Memory (00000008:kIOGPUCommandBufferCallbackErrorOutOfMemory)",
        ])
    }

    func testOutputTailIsBounded() {
        let tail = LlamaServerOutputTail()
        tail.append(Data((1...20).map { "line \($0)\n" }.joined().utf8))
        tail.append(Data((String(repeating: "x", count: 1_000) + "\n").utf8))

        XCTAssertEqual(tail.lines.count, LlamaServerOutputTail.maximumLines)
        XCTAssertEqual(tail.lines.first, "line 10")
        XCTAssertEqual(tail.lines.last?.count, LlamaServerOutputTail.maximumLineCharacters)
    }

    /// The privacy story requires every built-in server to be reachable only
    /// via loopback. A non-loopback base URL here would be a data-exfiltration
    /// bug, not a configuration choice.
    func testSharedServersAreLoopbackOnlyAndOnDistinctPorts() {
        let servers: [(LlamaServer, LlamaServerRole)] = [
            (.shared, .main), (.embedder, .embedder), (.cotyping, .cotyping),
        ]
        for (server, role) in servers {
            XCTAssertEqual(server.role, role)
            XCTAssertEqual(server.port, role.port)
            XCTAssertEqual(server.baseURL.host, "127.0.0.1")
            XCTAssertEqual(server.baseURL.port, role.port)
        }
        XCTAssertEqual(Set(servers.map(\.0.port)).count, 3, "roles must not share a port")
    }

    func testServedModelNamesParsesBothLlamaServerShapes() throws {
        let payload = Data("""
        {"models":[{"name":"qwen.gguf","model":"/models/qwen.gguf"}],
         "data":[{"id":"lfm.gguf"},{"id":""}]}
        """.utf8)

        let names = LlamaServer.servedModelNames(from: payload)

        XCTAssertEqual(names, ["qwen.gguf", "/models/qwen.gguf", "lfm.gguf"])
    }

    func testServedModelNamesIsEmptyForMalformedPayload() {
        XCTAssertEqual(LlamaServer.servedModelNames(from: Data("not json".utf8)), [])
        XCTAssertEqual(LlamaServer.servedModelNames(from: Data("{}".utf8)), [])
    }

    func testModelMatchKeyUsesFileName() {
        let url = URL(fileURLWithPath: "/tmp/models/qwen3.5-4b-q4.gguf")
        XCTAssertEqual(LlamaServer.modelMatchKey(for: url), "qwen3.5-4b-q4.gguf")
    }

    func testServingModelAcceptsFullPathAndFilenameButRejectsAnotherFile() throws {
        let model = URL(fileURLWithPath: "/models/granite.gguf")
        let payload = Data("""
        {"models":[{"name":"/models/granite.gguf","model":"/models/granite.gguf"}],
         "data":[{"id":"/models/granite.gguf"}]}
        """.utf8)
        XCTAssertTrue(LlamaServer.servesModel(at: model, names: LlamaServer.servedModelNames(from: payload)))
        XCTAssertTrue(LlamaServer.servesModel(at: model, names: ["granite.gguf"]))
        XCTAssertFalse(LlamaServer.servesModel(at: model, names: ["/other/granite.gguf"]))
        XCTAssertFalse(LlamaServer.servesModel(at: model, names: ["qwen.gguf"]))
        XCTAssertFalse(LlamaServer.servesModel(at: model, names: []))
    }

    func testAuthenticationTokenIsStableAndHighEntropy() async {
        // A private instance on an unused port: the token path is derived from
        // the port, so this never touches the production token files.
        // The persisted token file is removed on both ends of the test.
        let port = 59_871
        let tokenFile = AppDirectories.localServerSupport
            .appendingPathComponent("llama-server-\(port).auth-token")
        try? FileManager.default.removeItem(at: tokenFile)
        defer { try? FileManager.default.removeItem(at: tokenFile) }
        let server = LlamaServer(port: port, contextTokens: 512, extraArgs: [])

        let first = await server.authenticationToken()
        let second = await server.authenticationToken()

        XCTAssertEqual(first, second, "token must be stable across reads")
        XCTAssertGreaterThanOrEqual(first.count, 32)
        XCTAssertFalse(first.contains("-"))
    }

    /// Opt-in native replay; never downloads models or touches production
    /// ports. Audio, responses and timing artifacts stay in the private folder.
    func testLocalGraniteRegionReplayKeepsOneProcess() async throws {
        struct Manifest: Decodable {
            struct Window: Decodable { var start: Double; var end: Double }
            var model: String
            var projector: String
            var audio: String
            var output: String
            var port: Int
            var windows: [Window]
        }
        guard let path = ProcessInfo.processInfo.environment["LOKALBOT_GRANITE_REPLAY_MANIFEST"] else {
            throw XCTSkip("Set LOKALBOT_GRANITE_REPLAY_MANIFEST for a private local runtime replay.")
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        guard (49_152...65_535).contains(manifest.port), LlamaServer.listeningPIDs(onPort: manifest.port).isEmpty,
              LocalLlamaServerAuthentication.readMarker(port: manifest.port) == nil else {
            throw XCTSkip("Replay needs an unused private port without a PID marker.")
        }
        let model = URL(fileURLWithPath: manifest.model)
        let folder = URL(fileURLWithPath: manifest.output, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let server = LlamaServer(port: manifest.port, contextTokens: 4_096,
            extraArgs: ["--mmproj", manifest.projector, "--parallel", "1", "--cache-ram", "256"])
        addTeardownBlock {
            await server.stop()
            try? FileManager.default.removeItem(at: AppDirectories.applicationSupport
                .appendingPathComponent("llama-server-\(manifest.port).auth-token"))
        }
        let started = ProcessInfo.processInfo.systemUptime
        try await server.ensureRunning(modelAt: model)
        let startupSeconds = ProcessInfo.processInfo.systemUptime - started
        let initialPID = try XCTUnwrap(LocalLlamaServerAuthentication.readMarker(port: manifest.port)?.pid)
        let token = await server.authenticationToken()
        let reader = try SpanAudioReader(url: URL(fileURLWithPath: manifest.audio))
        var rows: [[String: Any]] = []
        for (index, window) in manifest.windows.prefix(20).enumerated() {
            let wav = folder.appendingPathComponent("region-\(index).wav")
            try OnnxTranscriptionEngine.writeWav(reader.samples(from: window.start, to: window.end), to: wav)
            let checking = ProcessInfo.processInfo.systemUptime
            try await server.ensureRunning(modelAt: model)
            let reuseSeconds = ProcessInfo.processInfo.systemUptime - checking
            XCTAssertEqual(LocalLlamaServerAuthentication.readMarker(port: manifest.port)?.pid, initialPID)
            let spans = try await SpeechActivity.shared.spans(in: wav, maxSegmentSeconds: 30)
            let decoding = ProcessInfo.processInfo.systemUptime
            let segments = try await SpanTranscription.segments(in: wav, spans: spans) { samples, part in
                let input = folder.appendingPathComponent("input-\(index)-\(part).wav")
                try OnnxTranscriptionEngine.writeWav(samples, to: input)
                let request = try GraniteSpeechEngine.makeTranscriptionRequest(serverBaseURL: server.baseURL,
                    authenticationToken: token, boundary: UUID().uuidString, wav: input, language: "en",
                    modelFileName: model.lastPathComponent)
                let (data, response) = try await URLSession.shared.data(for: request)
                XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
                let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                return try XCTUnwrap(payload["text"] as? String)
            }
            rows.append(["index": index, "start": window.start, "end": window.end, "pid": initialPID,
                         "reuseSeconds": reuseSeconds, "decodeSeconds": ProcessInfo.processInfo.systemUptime - decoding,
                         "speechSpans": spans.count, "text": segments.map(\.text).joined(separator: " ")])
        }
        XCTAssertFalse(rows.isEmpty)
        let changedContext = LlamaServer(port: manifest.port, contextTokens: 8_192,
            extraArgs: ["--mmproj", manifest.projector, "--parallel", "1", "--cache-ram", "256"])
        addTeardownBlock { await changedContext.stop() }
        try await changedContext.ensureRunning(modelAt: model)
        let changedPID = try XCTUnwrap(LocalLlamaServerAuthentication.readMarker(port: manifest.port)?.pid)
        XCTAssertNotEqual(changedPID, initialPID, "configuration changes must still replace the runtime")
        let report: [String: Any] = ["startupSeconds": startupSeconds, "regions": rows,
                                     "changedContextPID": changedPID]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appendingPathComponent("replay.json"), options: .atomic)
    }
}
