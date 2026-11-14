import CryptoKit
import Foundation

enum AgentArchiveKind: Equatable, Sendable {
    case zip, tarGz
}

struct AgentRuntimeArtifact: Equatable, Sendable {
    let name: String
    let url: URL
    let sha256: String        // lowercase hex
    let archiveKind: AgentArchiveKind
}

/// Pinned runtime components for Agent Mode. Bun is downloaded as a
/// checksum-verified release archive. pi is installed from the public npm
/// registry using the frozen lockfile bundled with LokalBot.
struct AgentRuntimeManifest: Equatable, Sendable {
    let bun: AgentRuntimeArtifact
    let bunBinarySHA256: String?
    let piCLISHA256: String?
    let packageJSONSHA256: String?
    let lockfileSHA256: String?
    let piRuntimeTreeSHA256: String?

    init(bun: AgentRuntimeArtifact,
         bunBinarySHA256: String? = nil,
         piCLISHA256: String? = nil,
         packageJSONSHA256: String? = nil,
         lockfileSHA256: String? = nil,
         piRuntimeTreeSHA256: String? = nil) {
        self.bun = bun
        self.bunBinarySHA256 = bunBinarySHA256
        self.piCLISHA256 = piCLISHA256
        self.packageJSONSHA256 = packageJSONSHA256
        self.lockfileSHA256 = lockfileSHA256
        self.piRuntimeTreeSHA256 = piRuntimeTreeSHA256
    }

    static let bunVersion = "1.4.4"
    static let piVersion = "1.5.2"

    static let current = AgentRuntimeManifest(
        bun: AgentRuntimeArtifact(
            name: "Bun \(bunVersion)",
            url: URL(string: "https://github.com/oven-sh/bun/releases/download/bun-v\(bunVersion)/bun-darwin-aarch64.zip")!,
            sha256: "c240d7f0ccb90c263a849fcdb09b7ee62630d921348ed6aafda86b9d577bc510",
            archiveKind: .zip),
        bunBinarySHA256: "0a2237cdcfa0d16ef501d9acca9f0026309ef348bea7393a64e8d1e3609565cc",
        piCLISHA256: "e79626f2dd6f94aa45d30f3fa63cd84319a6eefcd150b353cfaf274366926774",
        packageJSONSHA256: "493e0f739297dd7e1906cfdc394aeb3e89ec4aa3a1910fe48a4e615952490665",
        lockfileSHA256: "82710b2df114f1a091d5f04b8f7a2d6e711d79ca8c4085e7c89cc9e8776ce230",
        piRuntimeTreeSHA256: "1b3ef0bd494367a8465762f22a6dd90bd5e02196cac51acf1ce279a421e690c5")
}

struct AgentRuntimeVersionMarker: Codable, Equatable {
    let bunVersion: String
    let piVersion: String
    let bunArchiveSHA256: String
    let bunBinarySHA256: String
    let piCLISHA256: String
    let packageJSONSHA256: String
    let lockfileSHA256: String
    let piRuntimeTreeSHA256: String
}

/// On-disk layout of the installed runtime. Lives in Application Support
/// (NOT the storage root) alongside model caches and the llama-server
/// binary — it's a machine-local cache, not user data.
enum AgentRuntimeLayout {

    static var defaultRoot: URL {
        AppDirectories.applicationSupport.appendingPathComponent("agent-runtime", isDirectory: true)
    }

    static func bunBinary(under root: URL) -> URL {
        root.appendingPathComponent("bun/bun")
    }

    static func piCLI(under root: URL) -> URL {
        root.appendingPathComponent("pi/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js")
    }

    /// Cheap receipt check for opening the Agent pane. Installation already
    /// verifies every staged byte before the atomic swap, so showing the pane
    /// only needs to prove that the expected entry points and matching
    /// version receipt are present. Starting a task runs `isIntegrityValid`,
    /// the deep audit of the mutable runtime tree.
    static func isInstalled(under root: URL = defaultRoot,
                            manifest: AgentRuntimeManifest = .current) -> Bool {
        let bun = bunBinary(under: root)
        let cli = piCLI(under: root)
        let packageJSON = root.appendingPathComponent("pi/package.json")
        let lockfile = root.appendingPathComponent("pi/bun.lock")
        guard FileManager.default.isExecutableFile(atPath: bun.path),
              FileManager.default.fileExists(atPath: cli.path),
              FileManager.default.fileExists(atPath: packageJSON.path),
              FileManager.default.fileExists(atPath: lockfile.path),
              let data = try? Data(contentsOf: versionMarker(under: root)),
              let marker = try? JSONDecoder().decode(AgentRuntimeVersionMarker.self, from: data),
              marker.bunVersion == AgentRuntimeManifest.bunVersion,
              marker.piVersion == AgentRuntimeManifest.piVersion,
              marker.bunArchiveSHA256 == manifest.bun.sha256.lowercased(),
              digestReceipt(marker.bunBinarySHA256, matches: manifest.bunBinarySHA256),
              digestReceipt(marker.piCLISHA256, matches: manifest.piCLISHA256),
              digestReceipt(marker.packageJSONSHA256, matches: manifest.packageJSONSHA256),
              digestReceipt(marker.lockfileSHA256, matches: manifest.lockfileSHA256),
              digestReceipt(marker.piRuntimeTreeSHA256, matches: manifest.piRuntimeTreeSHA256) else {
            return false
        }
        return true
    }

    /// Explicit, recursive integrity audit. This intentionally opens every pi
    /// runtime file, so it runs at installation, repair, user-requested
    /// verification and before each task starts (`AgentSessionController`,
    /// off the main actor), never on ordinary pane navigation.
    static func isIntegrityValid(under root: URL = defaultRoot,
                                 manifest: AgentRuntimeManifest = .current) -> Bool {
        guard isInstalled(under: root, manifest: manifest),
              let data = try? Data(contentsOf: versionMarker(under: root)),
              let marker = try? JSONDecoder().decode(AgentRuntimeVersionMarker.self, from: data)
        else { return false }

        let bun = bunBinary(under: root)
        let cli = piCLI(under: root)
        let packageJSON = root.appendingPathComponent("pi/package.json")
        let lockfile = root.appendingPathComponent("pi/bun.lock")
        let piRuntime = root.appendingPathComponent("pi", isDirectory: true)
        guard let bunDigest = try? SHA256Verifier.hexDigest(of: bun),
              let cliDigest = try? SHA256Verifier.hexDigest(of: cli),
              let packageDigest = try? SHA256Verifier.hexDigest(of: packageJSON),
              let lockDigest = try? SHA256Verifier.hexDigest(of: lockfile),
              let treeDigest = try? SHA256Verifier.treeHexDigest(of: piRuntime),
              bunDigest == marker.bunBinarySHA256,
              cliDigest == marker.piCLISHA256,
              packageDigest == marker.packageJSONSHA256,
              lockDigest == marker.lockfileSHA256,
              treeDigest == marker.piRuntimeTreeSHA256 else {
            return false
        }
        return true
    }

    private static func digestReceipt(_ receipt: String, matches expected: String?) -> Bool {
        guard receipt.count == 64,
              receipt.allSatisfy({ $0.isHexDigit }) else { return false }
        return expected.map { receipt == $0.lowercased() } ?? true
    }

    /// Written at install time with versions and verified artifact digests.
    static func versionMarker(under root: URL) -> URL {
        root.appendingPathComponent("version.json")
    }

    /// pi session JSONL trees live under the storage root so they follow
    /// LOKALBOT_STORAGE_ROOT (hermetic in e2e/UI tests) and land next to
    /// the rest of the user's library.
    static var sessionsDirectory: URL {
        AppDirectories.libraryRoot.appendingPathComponent("agent/sessions", isDirectory: true)
    }
}

enum SHA256Verifier {
    enum DigestError: Error {
        case notDirectory(String)
        case unsupportedTreeEntry(String)
    }

    /// Streaming digest so ~60 MB artifacts don't land in memory at once.
    static func hexDigest(of url: URL) throws -> String {
        try digest(of: url).map { String(format: "%02x", $0) }.joined()
    }

    /// Deterministic digest of a directory's complete shape and contents.
    /// Records are ordered by raw UTF-8 path, length-delimited, and tagged by
    /// file type. Symlinks hash their link text and are never followed; regular
    /// files hash their bytes. Directory records make empty/additional
    /// directories visible too. Metadata and absolute install paths are
    /// deliberately excluded so identical installs hash identically.
    static func treeHexDigest(of root: URL) throws -> String {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw DigestError.notDirectory(root.path)
        }

        var hasher = SHA256()
        try hashDirectory(root, relativePath: "", into: &hasher)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func digest(of url: URL) throws -> SHA256.Digest {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize()
    }

    private static func hashDirectory(
        _ directory: URL,
        relativePath: String,
        into hasher: inout SHA256
    ) throws {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ]
        let entries = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [])
            .sorted {
                $0.lastPathComponent.utf8.lexicographicallyPrecedes(
                    $1.lastPathComponent.utf8)
            }

        for entry in entries {
            let path = relativePath.isEmpty
                ? entry.lastPathComponent
                : "\(relativePath)/\(entry.lastPathComponent)"
            let values = try entry.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true {
                let destination = try FileManager.default.destinationOfSymbolicLink(
                    atPath: entry.path)
                updateRecord(kind: 0x6C, path: path, payload: Data(destination.utf8), into: &hasher)
            } else if values.isDirectory == true {
                updateRecord(kind: 0x64, path: path, payload: Data(), into: &hasher)
                try hashDirectory(entry, relativePath: path, into: &hasher)
            } else if values.isRegularFile == true {
                updateRecord(
                    kind: 0x66,
                    path: path,
                    payload: Data(try digest(of: entry)),
                    into: &hasher)
            } else {
                throw DigestError.unsupportedTreeEntry(entry.path)
            }
        }
    }

    private static func updateRecord(
        kind: UInt8,
        path: String,
        payload: Data,
        into hasher: inout SHA256
    ) {
        hasher.update(data: Data([kind]))
        updateLengthPrefixed(Data(path.utf8), into: &hasher)
        updateLengthPrefixed(payload, into: &hasher)
    }

    private static func updateLengthPrefixed(_ data: Data, into hasher: inout SHA256) {
        var length = UInt64(data.count).bigEndian
        withUnsafeBytes(of: &length) { bytes in
            hasher.update(data: Data(bytes))
        }
        hasher.update(data: data)
    }
}
