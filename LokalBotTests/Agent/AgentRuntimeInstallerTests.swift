import XCTest
@testable import LokalBot

@MainActor
final class AgentRuntimeInstallerTests: XCTestCase {

    private actor VerificationProbe {
        let result: Bool
        private(set) var calls = 0

        init(result: Bool = false) {
            self.result = result
        }

        func verify() -> Bool {
            calls += 1
            return result
        }
    }

    private var sandbox: URL!

    override func setUp() async throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("installer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: sandbox)
    }

    /// zip containing bun-darwin-aarch64/bun (the layout of the real Bun release zip)
    private func makeBunFixture() throws -> URL {
        let stage = sandbox.appendingPathComponent("bun-stage/bun-darwin-aarch64", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        try Data("#!/bin/sh\necho fake-bun\n".utf8).write(to: stage.appendingPathComponent("bun"))
        let zip = sandbox.appendingPathComponent("bun-darwin-aarch64.zip")
        try run("/usr/bin/zip", ["-qr", zip.path, "bun-darwin-aarch64"],
                cwd: stage.deletingLastPathComponent())
        return zip
    }

    private func makeRuntimeTemplate() throws -> URL {
        let template = sandbox.appendingPathComponent("runtime-template", isDirectory: true)
        try FileManager.default.createDirectory(at: template, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: template.appendingPathComponent("package.json"))
        try Data("lockfileVersion = 1".utf8).write(to: template.appendingPathComponent("bun.lock"))
        return template
    }

    private var fakePackageInstaller: AgentRuntimeInstaller.PackageInstaller {
        { _, template, destination in
            let cliDir = destination.appendingPathComponent(
                "node_modules/@earendil-works/pi-coding-agent/dist/bundle", isDirectory: true)
            try FileManager.default.createDirectory(at: cliDir, withIntermediateDirectories: true)
            try FileManager.default.copyItem(
                at: template.appendingPathComponent("package.json"),
                to: destination.appendingPathComponent("package.json"))
            try FileManager.default.copyItem(
                at: template.appendingPathComponent("bun.lock"),
                to: destination.appendingPathComponent("bun.lock"))
            try Data("// cli".utf8).write(to: cliDir.appendingPathComponent("cli.js"))
        }
    }

    private func run(_ tool: String, _ args: [String], cwd: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        process.currentDirectoryURL = cwd
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "\(tool) failed")
    }

    private func manifest(
        bunZip: URL,
        corruptBunSHA: Bool = false,
        runtimeTreeSHA256: String? = nil
    ) throws -> AgentRuntimeManifest {
        AgentRuntimeManifest(
            bun: AgentRuntimeArtifact(
                name: "Bun test", url: bunZip,
                sha256: corruptBunSHA ? String(repeating: "0", count: 64)
                                      : try SHA256Verifier.hexDigest(of: bunZip),
                archiveKind: .zip),
            piRuntimeTreeSHA256: runtimeTreeSHA256)
    }

    func testInstallsVerifiedArtifactsIntoLayout() async throws {
        let root = sandbox.appendingPathComponent("agent-runtime", isDirectory: true)
        let testManifest = try manifest(bunZip: makeBunFixture())
        let installer = AgentRuntimeInstaller(
            root: root,
            runtimeTemplate: try makeRuntimeTemplate(),
            packageInstaller: fakePackageInstaller)
        await installer.installIfNeeded(manifest: testManifest)
        XCTAssertEqual(installer.phase, .installed)
        XCTAssertTrue(AgentRuntimeLayout.isInstalled(under: root, manifest: testManifest))
        XCTAssertTrue(AgentRuntimeLayout.isIntegrityValid(under: root, manifest: testManifest))
        XCTAssertTrue(FileManager.default.isExecutableFile(
            atPath: AgentRuntimeLayout.bunBinary(under: root).path))
        let markerData = try Data(contentsOf: AgentRuntimeLayout.versionMarker(under: root))
        let marker = try JSONDecoder().decode(AgentRuntimeVersionMarker.self, from: markerData)
        XCTAssertEqual(marker.bunVersion, AgentRuntimeManifest.bunVersion)
        XCTAssertEqual(marker.piVersion, AgentRuntimeManifest.piVersion)
        XCTAssertEqual(marker.bunArchiveSHA256, testManifest.bun.sha256)
        XCTAssertEqual(marker.bunBinarySHA256.count, 64)
        XCTAssertEqual(marker.piCLISHA256.count, 64)
        XCTAssertEqual(marker.piRuntimeTreeSHA256.count, 64)
        let attributes = try FileManager.default.attributesOfItem(
            atPath: AgentRuntimeLayout.versionMarker(under: root).path)
        XCTAssertEqual(attributes[.posixPermissions] as? NSNumber, NSNumber(value: 0o600))
    }

    func testInitializationUsesFastReceiptWithoutDeepVerification() async throws {
        let probe = VerificationProbe()
        let installer = AgentRuntimeInstaller(
            root: sandbox.appendingPathComponent("agent-runtime", isDirectory: true),
            runtimeTemplate: try makeRuntimeTemplate(),
            packageInstaller: fakePackageInstaller,
            installationChecker: { _, _ in true },
            runtimeVerifier: { _, _ in await probe.verify() })

        XCTAssertEqual(installer.phase, .installed)
        var calls = await probe.calls
        XCTAssertEqual(calls, 0)

        let valid = await installer.verifyInstalledState()
        XCTAssertFalse(valid)
        calls = await probe.calls
        XCTAssertEqual(calls, 1)
        guard case .failed(let message) = installer.phase else {
            return XCTFail("expected integrity failure, got \(installer.phase)")
        }
        XCTAssertTrue(message.contains("integrity"), message)
    }

    func testChecksumMismatchFailsAndInstallsNothing() async throws {
        let root = sandbox.appendingPathComponent("agent-runtime", isDirectory: true)
        let installer = AgentRuntimeInstaller(
            root: root,
            runtimeTemplate: try makeRuntimeTemplate(),
            packageInstaller: fakePackageInstaller)
        await installer.installIfNeeded(
            manifest: try manifest(bunZip: makeBunFixture(), corruptBunSHA: true))
        guard case .failed(let message) = installer.phase else {
            return XCTFail("expected failure, got \(installer.phase)")
        }
        XCTAssertTrue(message.contains("checksum"), message)
        XCTAssertFalse(AgentRuntimeLayout.isInstalled(under: root))
    }

    func testRuntimeTreeChecksumMismatchFailsAndInstallsNothing() async throws {
        let root = sandbox.appendingPathComponent("agent-runtime", isDirectory: true)
        let installer = AgentRuntimeInstaller(
            root: root,
            runtimeTemplate: try makeRuntimeTemplate(),
            packageInstaller: fakePackageInstaller)
        await installer.installIfNeeded(manifest: try manifest(
            bunZip: makeBunFixture(),
            runtimeTreeSHA256: String(repeating: "0", count: 64)))
        guard case .failed(let message) = installer.phase else {
            return XCTFail("expected failure, got \(installer.phase)")
        }
        XCTAssertTrue(message.contains("checksum"), message)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testRuntimeTreeChecksumMatchInstallsVerifiedTree() async throws {
        let root = sandbox.appendingPathComponent("agent-runtime", isDirectory: true)
        let template = try makeRuntimeTemplate()
        let expectedTree = sandbox.appendingPathComponent("expected-pi", isDirectory: true)
        try await fakePackageInstaller(
            URL(fileURLWithPath: "/unused/fake-bun"), template, expectedTree)
        let expectedDigest = try SHA256Verifier.treeHexDigest(of: expectedTree)
        try FileManager.default.removeItem(at: expectedTree)

        let testManifest = try manifest(
            bunZip: makeBunFixture(), runtimeTreeSHA256: expectedDigest)
        let installer = AgentRuntimeInstaller(
            root: root,
            runtimeTemplate: template,
            packageInstaller: fakePackageInstaller)
        await installer.installIfNeeded(manifest: testManifest)

        XCTAssertEqual(installer.phase, .installed)
        XCTAssertTrue(AgentRuntimeLayout.isInstalled(under: root, manifest: testManifest))
        XCTAssertTrue(AgentRuntimeLayout.isIntegrityValid(under: root, manifest: testManifest))
    }

    func testFrozenPackageInstallerCopiesManifestAndRunsExpectedCommand() async throws {
        let fakeBun = sandbox.appendingPathComponent("fake-bun")
        let script = """
        #!/bin/sh
        test "$1" = "install" || exit 11
        test "$2" = "--production" || exit 12
        test "$3" = "--frozen-lockfile" || exit 13
        test "$4" = "--ignore-scripts" || exit 14
        test -f package.json || exit 15
        test -f bun.lock || exit 16
        mkdir -p node_modules/@earendil-works/pi-coding-agent/dist/bundle
        touch node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js
        """
        try Data(script.utf8).write(to: fakeBun)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: fakeBun.path)
        let destination = sandbox.appendingPathComponent("pi-destination", isDirectory: true)

        try await AgentRuntimeInstaller.installPackages(
            bun: fakeBun,
            template: makeRuntimeTemplate(),
            destination: destination)

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("package.json").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("bun.lock").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent(
            "node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js").path))
    }

    func testAlreadyInstalledShortCircuits() async throws {
        let root = sandbox.appendingPathComponent("agent-runtime", isDirectory: true)
        let installer = AgentRuntimeInstaller(
            root: root,
            runtimeTemplate: try makeRuntimeTemplate(),
            packageInstaller: fakePackageInstaller)
        let testManifest = try manifest(bunZip: makeBunFixture())
        await installer.installIfNeeded(manifest: testManifest)
        XCTAssertEqual(installer.phase, .installed)
        try FileManager.default.removeItem(at: testManifest.bun.url)
        await installer.installIfNeeded(manifest: testManifest)
        XCTAssertEqual(installer.phase, .installed)
    }

    func testRepairForcesAtomicReinstallDespiteCurrentReceipt() async throws {
        let root = sandbox.appendingPathComponent("agent-runtime", isDirectory: true)
        let installer = AgentRuntimeInstaller(
            root: root,
            runtimeTemplate: try makeRuntimeTemplate(),
            packageInstaller: fakePackageInstaller,
            installationChecker: { _, _ in true })
        let testManifest = try manifest(bunZip: makeBunFixture())

        XCTAssertEqual(installer.phase, .installed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))

        await installer.repair(manifest: testManifest)

        XCTAssertEqual(installer.phase, .installed)
        XCTAssertTrue(FileManager.default.isExecutableFile(
            atPath: AgentRuntimeLayout.bunBinary(under: root).path))
        XCTAssertTrue(AgentRuntimeLayout.isIntegrityValid(under: root, manifest: testManifest))
    }
}
