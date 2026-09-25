import Foundation
import CryptoKit
import Darwin

/// Shared sherpa-onnx runtime installer. The app bundles the native binaries
/// as resources, then copies them to Application Support before execution so
/// subprocess paths are writable/stable across signed app updates.
enum SherpaOnnxRuntime {
    static func installedRuntime(executableName: String) throws -> (binary: URL, libDir: URL) {
        guard let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("sherpa-onnx", isDirectory: true),
              FileManager.default.fileExists(
                atPath: bundled.appendingPathComponent(executableName).path)
        else { throw RuntimeError.missing(executableName) }

        let installed = AppDirectories.applicationSupport
            .appendingPathComponent("sherpa-onnx", isDirectory: true)
        let runtime = try NativeRuntimeInstaller.install(
            bundled: bundled, root: installed,
            executables: ["sherpa-onnx-offline", "sherpa-onnx-offline-tts"])
        return (runtime.appendingPathComponent(executableName), runtime)
    }

    enum RuntimeError: LocalizedError {
        case missing(String)

        var errorDescription: String? {
            switch self {
            case .missing(let executable):
                "The bundled sherpa-onnx runtime is missing \(executable)."
            }
        }
    }
}

/// A content-addressed installation keeps a running helper's dylibs stable
/// across app updates. Validate every file on reuse; size and a success marker
/// alone cannot detect same-size updates, corruption, or a missing dependency.
enum NativeRuntimeInstaller {
    static func install(bundled: URL, root: URL, executables: [String]) throws -> URL {
        let fm = FileManager.default
        let expected = try manifest(in: bundled)
        guard executables.allSatisfy({ expected[$0] != nil }) else {
            throw InstallError.invalidContents
        }
        let encoded = try JSONSerialization.data(withJSONObject: expected, options: .sortedKeys)
        let identity = SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let lock = open(root.appendingPathComponent(".install.lock").path,
                        O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw InstallError.invalidContents }
        defer { close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { throw InstallError.invalidContents }
        defer { flock(lock, LOCK_UN) }
        let destination = root.appendingPathComponent(identity, isDirectory: true)
        if (try? manifest(in: destination)) == expected,
           executables.allSatisfy({ fm.isExecutableFile(atPath: destination.appendingPathComponent($0).path) }) {
            return destination
        }
        let staged = root.appendingPathComponent(".install-\(UUID())", isDirectory: true)
        defer { try? fm.removeItem(at: staged) }
        try fm.copyItem(at: bundled, to: staged)
        for name in executables {
            try fm.setAttributes([.posixPermissions: 0o755],
                                 ofItemAtPath: staged.appendingPathComponent(name).path)
        }
        guard try manifest(in: staged) == expected else { throw InstallError.invalidContents }
        // A failed copy never removes a valid installation. Keep prior content
        // versions because another app instance may still execute from one.
        if fm.fileExists(atPath: destination.path) {
            let backup = root.appendingPathComponent(".invalid-\(UUID())")
            try fm.moveItem(at: destination, to: backup)
            do { try fm.moveItem(at: staged, to: destination) } catch {
                try? fm.moveItem(at: backup, to: destination)
                throw error
            }
            try? fm.removeItem(at: backup)
        } else {
            try fm.moveItem(at: staged, to: destination)
        }
        return destination
    }

    static func manifest(in root: URL) throws -> [String: String] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        let rootValues = try root.resourceValues(forKeys: keys)
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        var enumerationError: Error?
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true,
              let files = FileManager.default.enumerator(at: canonicalRoot, includingPropertiesForKeys: Array(keys), errorHandler: { _, error in
                  enumerationError = error
                  return false
              }) else {
            throw InstallError.invalidContents
        }
        var result: [String: String] = [:]
        for case let file as URL in files {
            let values = try file.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true else { throw InstallError.invalidContents }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true else { throw InstallError.invalidContents }
            let canonicalFile = file.standardizedFileURL.resolvingSymlinksInPath()
            guard canonicalFile.path.hasPrefix(canonicalRoot.path + "/") else { throw InstallError.invalidContents }
            result[String(canonicalFile.path.dropFirst(canonicalRoot.path.count + 1))] = try sha256(file)
        }
        if let enumerationError { throw enumerationError }
        guard !result.isEmpty else { throw InstallError.invalidContents }
        return result
    }

    static func sha256(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    enum InstallError: LocalizedError {
        case invalidContents
        var errorDescription: String? { "The local runtime files are incomplete or invalid." }
    }
}

enum ArchiveExtractor {
    static func extractBzip2Tar(_ archive: URL, into dir: URL) throws {
        // Validate paths and entry types before extraction. Model archives must
        // contain ordinary files/directories, never links or special files.
        let names = try listing(archive, verbose: false)
        let types = try listing(archive, verbose: true)
        guard !names.isEmpty,
              names.allSatisfy({ !$0.hasPrefix("/") && !$0.split(separator: "/").contains("..") }),
              types.allSatisfy({ $0.first == "-" || $0.first == "d" }) else {
            throw ExtractionError.unsafeArchive
        }
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xjf", archive.path, "-C", dir.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ExtractionError.failed(process.terminationStatus)
        }
        try Task.checkCancellation()
    }

    private static func listing(_ archive: URL, verbose: Bool) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = [verbose ? "-tvjf" : "-tjf", archive.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ExtractionError.failed(process.terminationStatus) }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    enum ExtractionError: LocalizedError {
        case failed(Int32)
        case unsafeArchive

        var errorDescription: String? {
            switch self {
            case .failed(let code): "Could not extract model archive (tar exited \(code))."
            case .unsafeArchive: "The model archive contains unsafe paths or unsupported file types."
            }
        }
    }
}
