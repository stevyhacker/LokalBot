import CryptoKit
import XCTest
@testable import LokalBot

final class PinnedModelSnapshotTests: XCTestCase {
    private actor Downloads {
        var urls: [URL] = []
        func record(_ url: URL) { urls.append(url) }
    }

    func testPinnedDownloadRepairsChangedCacheBeforeReturning() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pinned-model-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("verified".utf8)
        let file = PinnedModelSnapshot.File(path: "model.safetensors", bytes: Int64(bytes.count),
                                            digest: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), isGitBlob: false)
        let revision = String(repeating: "a", count: 40)
        let snapshot = PinnedModelSnapshot(repository: "fixture/model", revision: revision, files: [file])
        let calls = Downloads()
        let download: PinnedModelSnapshot.Downloader = { url in
            await calls.record(url)
            let temporary = root.appendingPathComponent("download-\(UUID())")
            try bytes.write(to: temporary)
            return temporary
        }
        try await snapshot.prepare(in: root, download: download)
        try await snapshot.prepare(in: root, download: download)
        var urls = await calls.urls
        XCTAssertEqual(urls.count, 1)
        XCTAssertEqual(urls.first?.path, "/fixture/model/resolve/\(revision)/model.safetensors")
        try Data("tampered".utf8).write(to: root.appendingPathComponent(file.path))
        try await snapshot.prepare(in: root, download: download)
        urls = await calls.urls
        XCTAssertEqual(urls.count, 2)
        XCTAssertNoThrow(try snapshot.verify(in: root))
    }

    func testBadDownloadCannotReplaceExistingCache() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pinned-reject-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent("config.json")
        try Data("old".utf8).write(to: destination)
        let snapshot = PinnedModelSnapshot(repository: "fixture/model", revision: String(repeating: "b", count: 40),
            files: [.init(path: "config.json", bytes: 6, digest: "ce013625030ba8dba906f756967f9e9ca394464a", isGitBlob: true)])
        do {
            try await snapshot.prepare(in: root, download: { _ in
                let temporary = root.appendingPathComponent("download")
                try Data("wrong!".utf8).write(to: temporary)
                return temporary
            })
            XCTFail("Unverified publisher response must never become a model")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: destination), Data("old".utf8))
        try Data("hello\n".utf8).write(to: destination)
        XCTAssertNoThrow(try snapshot.verify(in: root), "ordinary files use Git blob hashing, including its header")
    }

    func testUnpinnedExtraWeightsAreRejected() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pinned-extra-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("hello\n".utf8).write(to: root.appendingPathComponent("model.safetensors"))
        try Data("extra".utf8).write(to: root.appendingPathComponent("extra.safetensors"))
        let snapshot = PinnedModelSnapshot(repository: "fixture/model", revision: String(repeating: "b", count: 40),
            files: [.init(path: "model.safetensors", bytes: 6, digest: "ce013625030ba8dba906f756967f9e9ca394464a", isGitBlob: true)])
        do {
            try await snapshot.prepare(in: root, download: { _ in throw CancellationError() })
            XCTFail("A dependency must not discover additional unreviewed weights")
        } catch PinnedModelSnapshot.SnapshotError.unexpectedWeights {}
    }

    func testModelChildSymlinkCannotRedirectDownloadOrVerification() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pinned-link-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("cache")
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: cache.appendingPathComponent("weights"), withDestinationURL: outside)
        let snapshot = PinnedModelSnapshot(repository: "fixture/model", revision: String(repeating: "b", count: 40),
            files: [.init(path: "weights/model.bin", bytes: 6, digest: "ce013625030ba8dba906f756967f9e9ca394464a", isGitBlob: true)])
        let calls = Downloads()
        do {
            try await snapshot.prepare(in: cache, download: { url in
                await calls.record(url)
                throw CancellationError()
            })
            XCTFail("A child symlink must not redirect model installation")
        } catch PinnedModelSnapshot.SnapshotError.invalidPath {}
        let urls = await calls.urls
        XCTAssertTrue(urls.isEmpty)
        try Data("hello\n".utf8).write(to: outside.appendingPathComponent("model.bin"))
        XCTAssertThrowsError(try snapshot.verify(in: cache))
    }

    func testRepositoryRootVocabularyUsesItsOwnPinnedRemotePath() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pinned-prefix-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = PinnedModelSnapshot(repository: "fixture/model", revision: String(repeating: "b", count: 40),
            files: [.init(path: "vocab.json", bytes: 6, digest: "ce013625030ba8dba906f756967f9e9ca394464a", isGitBlob: true, remotePath: "vocab.json")],
            remotePrefix: "q8/")
        let calls = Downloads()
        try await snapshot.prepare(in: root, download: { url in
            await calls.record(url)
            let temporary = root.appendingPathComponent("download")
            try Data("hello\n".utf8).write(to: temporary)
            return temporary
        })
        let urls = await calls.urls
        XCTAssertEqual(urls.first?.path, "/fixture/model/resolve/\(snapshot.revision)/vocab.json")
        XCTAssertNoThrow(try snapshot.verify(in: root))
    }

    func testExtraCoreMLBundleFileCannotChangeWhatTheLoaderReads() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pinned-coreml-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let component = root.appendingPathComponent("Model.mlmodelc")
        try FileManager.default.createDirectory(at: component, withIntermediateDirectories: true)
        try Data("hello\n".utf8).write(to: component.appendingPathComponent("model.mil"))
        let snapshot = PinnedModelSnapshot(repository: "fixture/model", revision: String(repeating: "b", count: 40),
            files: [.init(path: "Model.mlmodelc/model.mil", bytes: 6, digest: "ce013625030ba8dba906f756967f9e9ca394464a", isGitBlob: true)])
        XCTAssertNoThrow(try snapshot.verify(in: root))
        try Data("unreviewed".utf8).write(to: component.appendingPathComponent("model.mlmodel"))
        XCTAssertThrowsError(try snapshot.verify(in: root))
        do {
            try await snapshot.prepare(in: root, download: { _ in throw CancellationError() })
            XCTFail("Unpinned compiled-model files must not reach CoreML")
        } catch PinnedModelSnapshot.SnapshotError.unexpectedWeights {}
    }
}
