import XCTest
@testable import LokalBot

final class RuntimeAssetSafetyTests: XCTestCase {
    private func fixture() throws -> (root: URL, bundle: URL, installed: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("runtime-assets-\(UUID())")
        let bundle = root.appendingPathComponent("bundle")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data("aaaa".utf8).write(to: bundle.appendingPathComponent("helper"))
        try Data("lib-one".utf8).write(to: bundle.appendingPathComponent("dependency.dylib"))
        return (root, bundle, root.appendingPathComponent("installed"))
    }

    func testSameSizeHelperUpdateInstallsNewContentAndPreservesOldVersion() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let old = try NativeRuntimeInstaller.install(bundled: f.bundle, root: f.installed, executables: ["helper"])
        try Data("bbbb".utf8).write(to: f.bundle.appendingPathComponent("helper"))
        let new = try NativeRuntimeInstaller.install(bundled: f.bundle, root: f.installed, executables: ["helper"])
        XCTAssertNotEqual(old, new)
        XCTAssertEqual(try Data(contentsOf: old.appendingPathComponent("helper")), Data("aaaa".utf8))
        XCTAssertEqual(try Data(contentsOf: new.appendingPathComponent("helper")), Data("bbbb".utf8))
    }

    func testMissingOrCorruptDylibIsRepairedOnReuse() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let installed = try NativeRuntimeInstaller.install(bundled: f.bundle, root: f.installed, executables: ["helper"])
        let dependency = installed.appendingPathComponent("dependency.dylib")
        try FileManager.default.removeItem(at: dependency)
        XCTAssertEqual(try NativeRuntimeInstaller.install(bundled: f.bundle, root: f.installed, executables: ["helper"]), installed)
        XCTAssertEqual(try Data(contentsOf: dependency), Data("lib-one".utf8))
        try Data("lib-two".utf8).write(to: dependency)
        _ = try NativeRuntimeInstaller.install(bundled: f.bundle, root: f.installed, executables: ["helper"])
        XCTAssertEqual(try Data(contentsOf: dependency), Data("lib-one".utf8))
    }

    func testRejectedReplacementLeavesWorkingRuntimeIntact() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let installed = try NativeRuntimeInstaller.install(bundled: f.bundle, root: f.installed, executables: ["helper"])
        try FileManager.default.createSymbolicLink(at: f.bundle.appendingPathComponent("escape"), withDestinationURL: f.root)
        XCTAssertThrowsError(try NativeRuntimeInstaller.install(bundled: f.bundle, root: f.installed, executables: ["helper"]))
        XCTAssertEqual(try Data(contentsOf: installed.appendingPathComponent("helper")), Data("aaaa".utf8))
    }

    func testRuntimeOwnershipIsExclusiveAndReleasedWithLifetime() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("runtime-lock-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        var first: LocalRuntimeOwnershipLock? = try .acquire(at: root.appendingPathComponent("owner.lock"))
        XCTAssertNotNil(first)
        XCTAssertThrowsError(try LocalRuntimeOwnershipLock.acquire(at: root.appendingPathComponent("owner.lock")))
        first = nil
        XCTAssertNoThrow(try LocalRuntimeOwnershipLock.acquire(at: root.appendingPathComponent("owner.lock")))
    }

    func testOnlyConfirmedOrphanWithSameHelperIdentityCanBeClaimed() {
        var marker = LocalLlamaServerMarker(pid: 42, port: 17872, binaryPath: "/fixture/llama-server", modelPath: "/fixture/model")
        marker.ownerID = UUID()
        marker.ownerPID = 41
        marker.ownerStartTime = 10
        marker.processStartTime = 20
        XCTAssertFalse(LocalRuntimeOwnershipPolicy.canClaim(marker: marker, ownerIsAlive: true, liveOwnerStartTime: 10, liveHelperStartTime: 20))
        XCTAssertFalse(LocalRuntimeOwnershipPolicy.canClaim(marker: marker, ownerIsAlive: true, liveOwnerStartTime: nil, liveHelperStartTime: 20))
        XCTAssertFalse(LocalRuntimeOwnershipPolicy.canClaim(marker: marker, ownerIsAlive: false, liveOwnerStartTime: nil, liveHelperStartTime: 21))
        XCTAssertTrue(LocalRuntimeOwnershipPolicy.canClaim(marker: marker, ownerIsAlive: false, liveOwnerStartTime: nil, liveHelperStartTime: 20))
        marker.ownerID = nil
        XCTAssertFalse(LocalRuntimeOwnershipPolicy.canClaim(marker: marker, ownerIsAlive: false, liveOwnerStartTime: nil, liveHelperStartTime: 20))
    }

    func testArchiveRejectsLinksBeforeExtraction() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let destination = f.root.appendingPathComponent("extracted")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let archive = f.root.appendingPathComponent("fixture.tar.bz2")
        func archiveBundle() throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.arguments = ["-cjf", archive.path, "-C", f.bundle.path, "."]
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
        }
        try archiveBundle()
        try ArchiveExtractor.extractBzip2Tar(archive, into: destination)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("helper")), Data("aaaa".utf8))
        try FileManager.default.createSymbolicLink(at: f.bundle.appendingPathComponent("escape"), withDestinationURL: f.root)
        try archiveBundle()
        XCTAssertThrowsError(try ArchiveExtractor.extractBzip2Tar(archive, into: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("escape").path))
    }
}
