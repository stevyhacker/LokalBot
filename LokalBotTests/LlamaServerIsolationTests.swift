import Darwin
import XCTest
@testable import LokalBot

/// Each LokalBot copy runs its llama-servers on its own ports, and a helper a
/// dead copy left behind does not block the next start. 2026-10-09 to 10-12:
/// an orphaned UI Test Host embedder held 127.0.0.1:17873, the installed app's
/// embedder could not start, and meeting and screen embeddings silently
/// stopped; the unit-test host also wrote the installed app's PID marker.
final class LlamaServerIsolationTests: XCTestCase {

    func testReleasePortsNeverMove() {
        XCTAssertEqual(LlamaServerRole.allCases.map { $0.port(for: .release) },
                       [17_872, 17_873, 17_874, 17_875, 17_876])
        XCTAssertEqual(LlamaServerRole.allCases.map(\.releasePort),
                       [17_872, 17_873, 17_874, 17_875, 17_876])
    }

    func testEveryAppCopyGetsItsOwnPorts() {
        let ports = LocalRuntimeOwner.allCases.flatMap { owner in
            LlamaServerRole.allCases.map { $0.port(for: owner) }
        }
        XCTAssertEqual(Set(ports).count, LocalRuntimeOwner.allCases.count * LlamaServerRole.allCases.count)
    }

    func testRuntimeOwnerFollowsIdentityAndTheUnitTestHost() {
        XCTAssertEqual(LocalRuntimeOwner.resolve(identity: .release, isUnitTesting: false), .release)
        XCTAssertEqual(LocalRuntimeOwner.resolve(identity: .development, isUnitTesting: false), .development)
        XCTAssertEqual(LocalRuntimeOwner.resolve(identity: .uiTestHost, isUnitTesting: false), .uiTestHost)
        // The unit-test host carries the release bundle id.
        XCTAssertEqual(LocalRuntimeOwner.resolve(identity: .release, isUnitTesting: true), .unitTests)
    }

    func testResidencyIDsNameTheRoleNotThePort() {
        for role in LlamaServerRole.allCases {
            XCTAssertEqual(LlamaServerRole(residencyID: role.residencyID), role)
            for owner in LocalRuntimeOwner.allCases {
                XCTAssertFalse(role.residencyID.contains(String(role.port(for: owner))), role.residencyID)
            }
        }
        XCTAssertEqual(Set(LlamaServerRole.allCases.map(\.residencyID)).count, LlamaServerRole.allCases.count)
        XCTAssertNil(LlamaServerRole(residencyID: "llama-server:17873"))
    }

    func testOnlyTheUnitTestHostGetsADifferentRuntimeFolder() {
        let parent = URL(fileURLWithPath: "/Users/me/Library/Application Support", isDirectory: true)
        func folder(_ owner: LocalRuntimeOwner) -> String {
            AppDirectories.localServerSupport(for: owner, under: parent).lastPathComponent
        }
        XCTAssertEqual(folder(.release), "me.dotenv.LokalBot")
        XCTAssertEqual(folder(.development), "me.dotenv.LokalBot.dev")
        XCTAssertEqual(folder(.uiTestHost), "me.dotenv.LokalBot.uitesthost")
        XCTAssertEqual(folder(.unitTests), "me.dotenv.LokalBot.unit-tests")
    }

    func testUnitTestHostStaysOffTheInstalledAppsPortsAndMarkers() {
        XCTAssertEqual(LocalRuntimeOwner.current, .unitTests)
        let releasePorts = Set(LlamaServerRole.allCases.map(\.releasePort))
        for server in [LlamaServer.shared, .embedder, .cotyping] {
            XCTAssertFalse(releasePorts.contains(server.port), "port \(server.port)")
        }
        XCTAssertEqual(LlamaServer.embedder.port, LlamaServerRole.embedder.port(for: .unitTests))
        XCTAssertFalse(releasePorts.contains(LlamaServerRole.graniteASR.port))
        XCTAssertFalse(releasePorts.contains(URLSessionLlamaChatClient.mainServerBaseURL.port ?? 0))

        let installedApp = AppDirectories.applicationSupport(
            for: .release, under: AppDirectories.userApplicationSupport).standardizedFileURL
        XCTAssertNotEqual(AppDirectories.localServerSupport.standardizedFileURL, installedApp)
        XCTAssertNotEqual(
            LocalLlamaServerAuthentication.markerURL(port: LlamaServer.embedder.port)
                .deletingLastPathComponent().standardizedFileURL,
            installedApp)
    }

    // MARK: - Orphaned helpers

    func testRuntimeFolderAcceptsOnlyLokalBotLlamaCppRuntimes() {
        let support = URL(fileURLWithPath: "/Users/me/Library/Application Support", isDirectory: true)
        func folder(_ relativePath: String) -> String? {
            OrphanedLlamaServerPolicy.runtimeFolder(
                forExecutable: support.path + "/" + relativePath, under: support)?.lastPathComponent
        }
        XCTAssertEqual(folder("me.dotenv.LokalBot/llama-cpp/0c73a9/llama-server"), "me.dotenv.LokalBot")
        XCTAssertEqual(folder("me.dotenv.LokalBot.uitesthost/llama-cpp/0c73a9/llama-server"),
                       "me.dotenv.LokalBot.uitesthost")
        XCTAssertEqual(folder("me.dotenv.LokalBot.unit-tests/llama-cpp/0c73a9/llama-server"),
                       "me.dotenv.LokalBot.unit-tests")
        XCTAssertEqual(folder("me.dotenv.LokalBot.dev/llama-cpp/llama-server"), "me.dotenv.LokalBot.dev")

        XCTAssertNil(folder("me.dotenv.LokalBotOther/llama-cpp/0c73a9/llama-server"))
        XCTAssertNil(folder("com.example.Other/llama-cpp/0c73a9/llama-server"))
        XCTAssertNil(folder("me.dotenv.LokalBot/models/llama-server"))
        XCTAssertNil(folder("me.dotenv.LokalBot/llama-cpp/0c73a9/sherpa-onnx"))
        XCTAssertNil(folder("me.dotenv.LokalBot/llama-cpp/../../../bin/llama-server"))
        XCTAssertNil(OrphanedLlamaServerPolicy.runtimeFolder(
            forExecutable: "/opt/homebrew/bin/llama-server", under: support))
    }

    func testOnlyAMarkerWithALiveOwnerProtectsAHelper() {
        let marker = LocalLlamaServerMarker(
            pid: 42, port: 17_873, binaryPath: "/x/llama-server", modelPath: "/x/model.gguf",
            ownerID: UUID(), ownerPID: 7, ownerStartTime: 100, processStartTime: 500)
        func protects(_ marker: LocalLlamaServerMarker, helperStartTime: UInt64 = 500,
                      ownerExists: Bool, liveOwnerStartTime: UInt64?) -> Bool {
            OrphanedLlamaServerPolicy.markerShowsLiveOwner(
                marker, helperStartTime: helperStartTime,
                ownerExists: ownerExists, liveOwnerStartTime: liveOwnerStartTime)
        }

        XCTAssertTrue(protects(marker, ownerExists: true, liveOwnerStartTime: 100))
        // An owner whose start time cannot be read may still be the owner.
        XCTAssertTrue(protects(marker, ownerExists: true, liveOwnerStartTime: nil))
        XCTAssertFalse(protects(marker, ownerExists: false, liveOwnerStartTime: nil))
        XCTAssertFalse(protects(marker, ownerExists: true, liveOwnerStartTime: 999),
                       "the owner's PID now belongs to another process")
        XCTAssertFalse(protects(marker, helperStartTime: 501, ownerExists: true, liveOwnerStartTime: 100),
                       "the marker described an earlier process with the helper's PID")
        var unowned = marker
        unowned.ownerPID = nil
        XCTAssertFalse(protects(unowned, ownerExists: true, liveOwnerStartTime: 100))
    }
}

/// Real processes: a copy of `nc` named llama-server stands in for a helper.
final class OrphanedLlamaServerReclaimTests: XCTestCase {
    private var root: URL!
    private var helpers: [pid_t] = []

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lokalbot-orphan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for pid in helpers where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        try? FileManager.default.removeItem(at: root)
    }

    func testStopsAHelperLeftBehindByAnotherAppCopy() async throws {
        let port = try unusedPort()
        let helper = try startHelper(in: "me.dotenv.LokalBot.uitesthost", port: port, reparented: true)
        // The incident's marker: its owner, the UI Test Host, has exited.
        try writeMarker(in: "me.dotenv.LokalBot.uitesthost", helper: helper, port: port,
                        ownerPID: try exitedProcessIdentifier(), ownerStartTime: 1)

        let stopped = await LlamaServer.stopOrphanedHelpers(
            LlamaServer.listeningPIDs(onPort: port), port: port, applicationSupport: root)

        XCTAssertEqual(stopped, [helper])
        XCTAssertTrue(LlamaServer.listeningPIDs(onPort: port).isEmpty)
    }

    func testStopsAnUnrecordedHelperOfTheSameCopy() async throws {
        let port = try unusedPort()
        let helper = try startHelper(in: "me.dotenv.LokalBot.unit-tests", port: port, reparented: true)

        let stopped = await LlamaServer.stopOrphanedHelpers([helper], port: port, applicationSupport: root)

        XCTAssertEqual(stopped, [helper])
    }

    func testLeavesAHelperAdoptedByALiveApp() async throws {
        let port = try unusedPort()
        let helper = try startHelper(in: "me.dotenv.LokalBot.dev", port: port, reparented: true)
        let owner = try XCTUnwrap(SystemResourceSampler.processUsage(for: getpid()))
        try writeMarker(in: "me.dotenv.LokalBot.dev", helper: helper, port: port,
                        ownerPID: getpid(), ownerStartTime: owner.startTime)

        let stopped = await LlamaServer.stopOrphanedHelpers([helper], port: port, applicationSupport: root)

        XCTAssertTrue(stopped.isEmpty)
        XCTAssertEqual(LlamaServer.listeningPIDs(onPort: port), [helper])
    }

    func testLeavesAHelperWhoseAppIsStillRunning() async throws {
        let port = try unusedPort()
        let helper = try startHelper(in: "me.dotenv.LokalBot.dev", port: port, reparented: false)

        let stopped = await LlamaServer.stopOrphanedHelpers([helper], port: port, applicationSupport: root)

        XCTAssertTrue(stopped.isEmpty)
        XCTAssertEqual(LlamaServer.listeningPIDs(onPort: port), [helper])
    }

    func testLeavesAServerOutsideLokalBotRuntimes() async throws {
        let port = try unusedPort()
        let helper = try startHelper(in: "com.example.Other", port: port, reparented: true)

        let stopped = await LlamaServer.stopOrphanedHelpers([helper], port: port, applicationSupport: root)

        XCTAssertTrue(stopped.isEmpty)
        XCTAssertEqual(LlamaServer.listeningPIDs(onPort: port), [helper])
    }

    // MARK: - Helpers

    /// Listens on 127.0.0.1:`port` from `<root>/<folder>/llama-cpp/test/llama-server`.
    /// `reparented` makes launchd its parent, as when the owning app dies.
    private func startHelper(in folder: String, port: Int, reparented: Bool) throws -> pid_t {
        let directory = root.appendingPathComponent(folder, isDirectory: true)
            .appendingPathComponent("llama-cpp/test", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("llama-server")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/nc"), to: executable)
        // A copied platform binary is killed at launch until it is re-signed.
        guard try run("/usr/bin/codesign", ["--force", "--sign", "-", executable.path]).status == 0 else {
            throw XCTSkip("Could not sign the stand-in helper.")
        }
        let pid: pid_t
        if reparented {
            let shell = try run("/bin/sh", [
                "-c", "\"$0\" -l 127.0.0.1 \"$1\" </dev/null >/dev/null 2>&1 & echo $!",
                executable.path, String(port),
            ])
            guard let started = pid_t(shell.output.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw XCTSkip("Could not start the stand-in helper.")
            }
            pid = started
        } else {
            let process = Process()
            process.executableURL = executable
            process.arguments = ["-l", "127.0.0.1", String(port)]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            pid = process.processIdentifier
        }
        helpers.append(pid)
        for _ in 0..<100 {
            if LlamaServer.listeningPIDs(onPort: port).contains(pid) {
                XCTAssertEqual(LlamaServer.parentProcessIdentifier(of: pid) == 1, reparented)
                return pid
            }
            usleep(20_000)
        }
        throw XCTSkip("The stand-in helper did not start listening.")
    }

    private func writeMarker(in folder: String, helper: pid_t, port: Int,
                             ownerPID: pid_t, ownerStartTime: UInt64) throws {
        let marker = LocalLlamaServerMarker(
            pid: helper, port: port,
            binaryPath: LlamaServer.processPath(for: helper) ?? "",
            modelPath: "/tmp/model.gguf",
            ownerID: UUID(), ownerPID: ownerPID, ownerStartTime: ownerStartTime,
            processStartTime: SystemResourceSampler.processUsage(for: helper)?.startTime)
        try JSONEncoder().encode(marker).write(to: root
            .appendingPathComponent(folder, isDirectory: true)
            .appendingPathComponent("llama-server-\(port).pid.json"))
    }

    private func exitedProcessIdentifier() throws -> pid_t {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        return process.processIdentifier
    }

    private func unusedPort() throws -> Int {
        for _ in 0..<20 {
            let port = Int.random(in: 50_000...59_000)
            if LlamaServer.listeningPIDs(onPort: port).isEmpty { return port }
        }
        throw XCTSkip("No unused port found.")
    }

    @discardableResult
    private func run(_ path: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
