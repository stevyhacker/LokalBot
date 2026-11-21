import Foundation

@MainActor
final class AgentRuntimeInstaller: ObservableObject {

    typealias PackageInstaller = (_ bun: URL, _ template: URL, _ destination: URL) async throws -> Void
    typealias InstallationChecker = (_ root: URL, _ manifest: AgentRuntimeManifest) -> Bool
    typealias RuntimeVerifier = @Sendable (URL, AgentRuntimeManifest) async -> Bool

    enum Phase: Equatable {
        case checking
        case idle
        case downloading(name: String, progress: Double)
        case installing(name: String)
        case installed
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle

    private let root: URL
    private let session: URLSession
    private let runtimeTemplate: URL
    private let packageInstaller: PackageInstaller
    private let installationChecker: InstallationChecker
    private let runtimeVerifier: RuntimeVerifier
    private var operationInProgress = false

    init(root: URL = AgentRuntimeLayout.defaultRoot,
         session: URLSession = .shared,
         runtimeTemplate: URL? = nil,
         packageInstaller: @escaping PackageInstaller = AgentRuntimeInstaller.installPackages,
         installationChecker: @escaping InstallationChecker = { root, manifest in
             AgentRuntimeLayout.isInstalled(under: root, manifest: manifest)
         },
         runtimeVerifier: @escaping RuntimeVerifier = { root, manifest in
             await AgentRuntimeInstaller.verifyInstalledRuntime(root: root, manifest: manifest)
         }) {
        self.root = root
        self.session = session
        self.runtimeTemplate = runtimeTemplate
            ?? Bundle.main.resourceURL?.appendingPathComponent("pi/runtime", isDirectory: true)
            ?? URL(fileURLWithPath: "pi/runtime", isDirectory: true)
        self.packageInstaller = packageInstaller
        self.installationChecker = installationChecker
        self.runtimeVerifier = runtimeVerifier
#if LOKALBOT_UI_TEST_HOST
        if ProcessInfo.processInfo.environment["LOKALBOT_AGENT_UI_TEST_READY"] == "1" {
            phase = .installed
        } else {
            phase = installationChecker(root, .current) ? .installed : .idle
        }
#else
        phase = installationChecker(root, .current) ? .installed : .idle
#endif
    }

    @discardableResult
    func verifyInstalledState(manifest: AgentRuntimeManifest = .current) async -> Bool {
#if LOKALBOT_UI_TEST_HOST
        if ProcessInfo.processInfo.environment["LOKALBOT_AGENT_UI_TEST_READY"] == "1" {
            phase = .installed
            return true
        }
#endif
        guard !operationInProgress else { return phase == .installed }
        operationInProgress = true
        phase = .checking
        let installed = await runtimeVerifier(root, manifest)
        operationInProgress = false
        phase = installed
            ? .installed
            : .failed("The installed Agent runtime failed its integrity check. Repair it before starting another session.")
        return installed
    }

    func installIfNeeded(manifest: AgentRuntimeManifest = .current) async {
        await install(manifest: manifest, force: false)
    }

    func repair(manifest: AgentRuntimeManifest = .current) async {
        await install(manifest: manifest, force: true)
    }

    private func install(manifest: AgentRuntimeManifest, force: Bool) async {
        guard !operationInProgress else { return }
        operationInProgress = true
        defer { operationInProgress = false }
        if !force, installationChecker(root, manifest) {
            phase = .installed
            return
        }
        let staging = root.deletingLastPathComponent()
            .appendingPathComponent("agent-runtime.staging-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

            let bunArchive = try await download(manifest.bun, into: staging)

            phase = .installing(name: manifest.bun.name)
            let bunStage = staging.appendingPathComponent("bun-extract", isDirectory: true)
            try Self.unpack(bunArchive, kind: manifest.bun.archiveKind, into: bunStage)
            let bunBinary = bunStage.appendingPathComponent("bun-darwin-aarch64/bun")
            guard FileManager.default.fileExists(atPath: bunBinary.path) else {
                throw InstallError.layout("bun binary missing from archive")
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                  ofItemAtPath: bunBinary.path)
            let bunBinaryDigest = try SHA256Verifier.hexDigest(of: bunBinary)
            if let expected = manifest.bunBinarySHA256,
               bunBinaryDigest != expected.lowercased() {
                throw InstallError.checksum(manifest.bun.name)
            }

            try Self.verifyTemplate(runtimeTemplate, manifest: manifest)

            phase = .installing(name: "pi \(AgentRuntimeManifest.piVersion)")
            let piStage = staging.appendingPathComponent("pi-install", isDirectory: true)
            try await packageInstaller(bunBinary, runtimeTemplate, piStage)
            let stagedCLI = piStage.appendingPathComponent(
                "node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js")
            guard FileManager.default.fileExists(atPath: stagedCLI.path) else {
                throw InstallError.layout("pi cli.js missing from bundle")
            }
            let piCLIDigest = try SHA256Verifier.hexDigest(of: stagedCLI)
            if let expected = manifest.piCLISHA256,
               piCLIDigest != expected.lowercased() {
                throw InstallError.checksum("pi \(AgentRuntimeManifest.piVersion)")
            }
            let piRuntimeTreeDigest = try SHA256Verifier.treeHexDigest(of: piStage)
            if let expected = manifest.piRuntimeTreeSHA256,
               piRuntimeTreeDigest != expected.lowercased() {
                throw InstallError.checksum("pi \(AgentRuntimeManifest.piVersion) runtime")
            }

            let assembled = staging.appendingPathComponent("agent-runtime", isDirectory: true)
            try FileManager.default.createDirectory(
                at: assembled.appendingPathComponent("bun", isDirectory: true),
                withIntermediateDirectories: true)
            let installedBun = assembled.appendingPathComponent("bun/bun")
            try FileManager.default.moveItem(at: bunBinary, to: installedBun)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installedBun.path)
            try FileManager.default.moveItem(at: piStage, to: assembled.appendingPathComponent("pi"))

            let packageDigest = try SHA256Verifier.hexDigest(
                of: assembled.appendingPathComponent("pi/package.json"))
            let lockDigest = try SHA256Verifier.hexDigest(
                of: assembled.appendingPathComponent("pi/bun.lock"))
            let marker = AgentRuntimeVersionMarker(
                bunVersion: AgentRuntimeManifest.bunVersion,
                piVersion: AgentRuntimeManifest.piVersion,
                bunArchiveSHA256: manifest.bun.sha256.lowercased(),
                bunBinarySHA256: bunBinaryDigest,
                piCLISHA256: piCLIDigest,
                packageJSONSHA256: packageDigest,
                lockfileSHA256: lockDigest,
                piRuntimeTreeSHA256: piRuntimeTreeDigest)
            let markerURL = AgentRuntimeLayout.versionMarker(under: assembled)
            try JSONEncoder().encode(marker).write(to: markerURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: markerURL.path)

            try? FileManager.default.removeItem(at: root)
            try FileManager.default.createDirectory(at: root.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: assembled, to: root)
            phase = .installed
        } catch {
            phase = .failed(Self.userMessage(for: error))
        }
    }

    nonisolated static func verifyInstalledRuntime(
        root: URL,
        manifest: AgentRuntimeManifest
    ) async -> Bool {
        await Task.detached(priority: .utility) {
            AgentRuntimeLayout.isIntegrityValid(under: root, manifest: manifest)
        }.value
    }

    static func installPackages(bun: URL, template: URL, destination: URL) async throws {
        let packageJSON = template.appendingPathComponent("package.json")
        let lockfile = template.appendingPathComponent("bun.lock")
        guard FileManager.default.fileExists(atPath: packageJSON.path),
              FileManager.default.fileExists(atPath: lockfile.path) else {
            throw InstallError.layout("the bundled pi package manifest is missing")
        }

        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: packageJSON,
                                         to: destination.appendingPathComponent("package.json"))
        try FileManager.default.copyItem(at: lockfile,
                                         to: destination.appendingPathComponent("bun.lock"))

        let logURL = destination.appendingPathComponent("install.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        defer {
            try? log.close()
            try? FileManager.default.removeItem(at: logURL)
        }

        let process = Process()
        process.executableURL = bun
        process.arguments = ["install", "--production", "--frozen-lockfile", "--ignore-scripts"]
        process.currentDirectoryURL = destination
        process.standardOutput = log
        process.standardError = log

        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
        try log.synchronize()
        guard status == 0 else {
            let data = (try? Data(contentsOf: logURL)) ?? Data()
            let fullDetail = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = fullDetail.map { String($0.suffix(2_000)) }
            throw InstallError.packageInstall(detail?.isEmpty == false ? detail! : "exit \(status)")
        }
    }

    private static func verifyTemplate(
        _ template: URL,
        manifest: AgentRuntimeManifest
    ) throws {
        let packageJSON = template.appendingPathComponent("package.json")
        let lockfile = template.appendingPathComponent("bun.lock")
        if let expected = manifest.packageJSONSHA256,
           try SHA256Verifier.hexDigest(of: packageJSON) != expected.lowercased() {
            throw InstallError.checksum("pi package manifest")
        }
        if let expected = manifest.lockfileSHA256,
           try SHA256Verifier.hexDigest(of: lockfile) != expected.lowercased() {
            throw InstallError.checksum("pi lockfile")
        }
    }

    private func download(_ artifact: AgentRuntimeArtifact, into staging: URL) async throws -> URL {
        phase = .downloading(name: artifact.name, progress: 0)
        let destination = staging.appendingPathComponent(artifact.url.lastPathComponent)
        if artifact.url.isFileURL {
            try FileManager.default.copyItem(at: artifact.url, to: destination)
        } else {
            phase = .downloading(name: artifact.name, progress: -1)
            let (temporary, response) = try await session.download(from: artifact.url)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw InstallError.download(artifact.name, "HTTP \(http.statusCode)")
            }
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
        phase = .downloading(name: artifact.name, progress: 1)

        guard try SHA256Verifier.hexDigest(of: destination).lowercased() == artifact.sha256.lowercased() else {
            throw InstallError.checksum(artifact.name)
        }
        return destination
    }

    static func unpack(_ archive: URL, kind: AgentArchiveKind, into directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let process = Process()
        switch kind {
        case .zip:
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-q", archive.path, "-d", directory.path]
        case .tarGz:
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.arguments = ["-xzf", archive.path, "-C", directory.path]
        }
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw InstallError.unpack(archive.lastPathComponent, process.terminationStatus)
        }
    }

    enum InstallError: Error {
        case download(String, String)
        case checksum(String)
        case unpack(String, Int32)
        case layout(String)
        case packageInstall(String)
    }

    private static func userMessage(for error: Error) -> String {
        switch error {
        case InstallError.download(let name, let detail):
            return "Couldn't download \(name) (\(detail)). Check your connection and try again."
        case InstallError.checksum(let name):
            return "The downloaded \(name) failed its checksum and was discarded. Try again; if it keeps failing, the release may have been tampered with."
        case InstallError.unpack(let file, let code):
            return "Couldn't unpack \(file) (exit \(code))."
        case InstallError.layout(let detail):
            return "Agent setup couldn't find the expected files: \(detail)."
        case InstallError.packageInstall(let detail):
            return "Couldn't install pi from the public package registry. Check your connection and try again.\n\(detail)"
        default:
            return "Setup failed: \(error.localizedDescription)"
        }
    }
}
