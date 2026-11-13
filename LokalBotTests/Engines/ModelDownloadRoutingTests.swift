import CryptoKit
import XCTest
@testable import LokalBot

/// huggingface.co is blocked in mainland China. HF-Mirror and ModelScope serve
/// the same pinned files there, and a file is accepted only if it matches the
/// pin, so a source can fail a download but never change a model.
final class ModelDownloadRoutingTests: XCTestCase {
    private let pinned = URL(string: "https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/"
                             + "e87f176479d0855a907a41277aca2f8ee7a09523/Qwen3.5-4B-Q4_K_M.gguf")!
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("model-routing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    private func file(_ contents: String) throws -> URL {
        let url = folder.appendingPathComponent(UUID().uuidString)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func sha256(_ contents: String) -> String {
        SHA256.hash(data: Data(contents.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func listing(_ digest: String, size: Int64 = 5) -> [String: ModelDownloadRouting.ModelScopeFile] {
        ["Qwen3.5-4B-Q4_K_M.gguf": .init(path: "Qwen3.5-4B-Q4_K_M.gguf", size: size, sha256: digest)]
    }

    func testHuggingFaceStaysASingleDirectDownload() {
        XCTAssertEqual(ModelDownloadRouting.candidates(for: pinned, source: .huggingFace), [.original(pinned)])
    }

    func testMirrorsRerouteOnlyHuggingFaceFileURLs() throws {
        let mirror = try XCTUnwrap(URL(string: "https://hf-mirror.com/unsloth/Qwen3.5-4B-GGUF/resolve/"
                                       + "e87f176479d0855a907a41277aca2f8ee7a09523/Qwen3.5-4B-Q4_K_M.gguf"))
        XCTAssertEqual(ModelDownloadRouting.candidates(for: pinned, source: .hfMirror),
                       [.hfMirror(mirror), .original(pinned)])
        for untouched in ["https://huggingface.co/api/models/unsloth/Qwen3.5-4B-GGUF",
                          "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/kokoro.tar.bz2",
                          "https://models.example/model.gguf"] {
            let url = try XCTUnwrap(URL(string: untouched))
            XCTAssertEqual(ModelDownloadRouting.candidates(for: url, source: .modelScope), [.original(url)], untouched)
        }
    }

    func testModelScopeComesFirstOnItsDefaultBranchThenTheMirror() {
        let candidates = ModelDownloadRouting.candidates(for: pinned, source: .modelScope)
        XCTAssertEqual(candidates.map(\.label), ["ModelScope", "HF-Mirror", "Hugging Face"])
        XCTAssertEqual(candidates.first?.url.absoluteString,
                       "https://www.modelscope.cn/models/unsloth/Qwen3.5-4B-GGUF/resolve/master/Qwen3.5-4B-Q4_K_M.gguf")
    }

    /// ModelScope follows branches, not Hugging Face revisions, so only a file
    /// whose listed SHA-256 equals the pin is fetched there.
    func testModelScopeServesOnlyTheExactPinnedFile() throws {
        let file = try XCTUnwrap(ModelDownloadRouting.resolvedFile(pinned))
        let digest = sha256("model")
        XCTAssertTrue(ModelDownloadRouting.modelScopeServes(
            file, expectedSHA256: digest, expectedBytes: 5, listing: listing(digest)))
        XCTAssertTrue(ModelDownloadRouting.modelScopeServes(
            file, expectedSHA256: digest.uppercased(), expectedBytes: nil, listing: listing(digest)))
        XCTAssertFalse(ModelDownloadRouting.modelScopeServes(
            file, expectedSHA256: digest, expectedBytes: 5, listing: listing(sha256("changed upstream"))))
        XCTAssertFalse(ModelDownloadRouting.modelScopeServes(
            file, expectedSHA256: digest, expectedBytes: 6, listing: listing(digest)))
        XCTAssertFalse(ModelDownloadRouting.modelScopeServes(
            file, expectedSHA256: digest, expectedBytes: 5, listing: nil))
        XCTAssertFalse(ModelDownloadRouting.modelScopeServes(
            file, expectedSHA256: String(repeating: "a", count: 40), expectedBytes: 5, listing: listing(digest)),
                       "a Git blob SHA-1 pin never qualifies")
    }

    func testAFailedMirrorFallsBackToHuggingFace() async throws {
        let model = try file("model")
        var attempted: [String] = []
        let result = try await ModelDownloadRouting.download(
            from: pinned, source: .hfMirror, expectedSHA256: sha256("model"), expectedBytes: 5,
            listing: { _ in nil },
            attempt: { url in
                attempted.append(url.host ?? "")
                if url.host == "hf-mirror.com" { throw URLError(.cannotConnectToHost) }
                return model
            })
        XCTAssertEqual(result, model)
        XCTAssertEqual(attempted, ["hf-mirror.com", "huggingface.co"])
    }

    /// A mirror's file that misses the pin is deleted and the next source is
    /// tried, instead of the whole download failing its integrity check.
    func testAMirrorFileThatMissesThePinIsDiscardedForTheNextSource() async throws {
        let tampered = try file("tampered")
        let genuine = try file("model")
        let digest = sha256("model")
        var attempted: [String] = []
        let result = try await ModelDownloadRouting.download(
            from: pinned, source: .modelScope, expectedSHA256: digest, expectedBytes: 5,
            listing: { _ in self.listing(digest) },
            attempt: { url in
                attempted.append(url.host ?? "")
                return url.host == "www.modelscope.cn" ? tampered : genuine
            })
        XCTAssertEqual(result, genuine)
        XCTAssertEqual(attempted, ["www.modelscope.cn", "hf-mirror.com"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: tampered.path))
    }

    func testModelScopeIsSkippedWhenItsFileDiffersFromThePin() async throws {
        let genuine = try file("model")
        let changed = sha256("changed upstream")
        var attempted: [String] = []
        _ = try await ModelDownloadRouting.download(
            from: pinned, source: .modelScope, expectedSHA256: sha256("model"), expectedBytes: 5,
            listing: { _ in self.listing(changed) },
            attempt: { url in
                attempted.append(url.host ?? "")
                return genuine
            })
        XCTAssertEqual(attempted, ["hf-mirror.com"])
    }

    func testCancellationIsNeverRetriedOnAnotherSource() async throws {
        var attempts = 0
        do {
            _ = try await ModelDownloadRouting.download(
                from: pinned, source: .hfMirror, expectedSHA256: nil, expectedBytes: nil,
                listing: { _ in nil },
                attempt: { _ in
                    attempts += 1
                    throw CancellationError()
                })
            XCTFail("expected cancellation")
        } catch is CancellationError {}
        XCTAssertEqual(attempts, 1)
    }

    func testWhenEverySourceFailsTheChosenSourcesErrorIsReported() async throws {
        do {
            _ = try await ModelDownloadRouting.download(
                from: pinned, source: .hfMirror, expectedSHA256: nil, expectedBytes: nil,
                listing: { _ in nil },
                attempt: { url in throw URLError(url.host == "hf-mirror.com" ? .timedOut : .cannotFindHost) })
            XCTFail("expected an error")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .timedOut)
        }
    }

    @MainActor
    func testSettingsStorePublishesTheChosenSource() {
        defer { ModelDownloadRouting.source = .huggingFace }
        var settings = AppSettings()
        settings.modelDownloadSource = .modelScope
        _ = SettingsStore(initialSettings: settings)
        XCTAssertEqual(ModelDownloadRouting.source, .modelScope)
    }

    @MainActor
    func testSettingsSearchFindsTheDownloadSourceInChinese() throws {
        for query in ["镜像", "魔搭", "ModelScope", "mirror", "下载源"] {
            XCTAssertTrue(SettingDescriptor.search(query, language: .simplifiedChinese)
                .contains { $0.id == "settings.modelDownloadSource" }, query)
        }
        let descriptor = try XCTUnwrap(SettingDescriptor.all.first { $0.id == "settings.modelDownloadSource" })
        var settings = AppSettings()
        settings.modelDownloadSource = .modelScope
        XCTAssertEqual(descriptor.currentValue(in: settings, language: .simplifiedChinese),
                       "魔搭 ModelScope (modelscope.cn)")
    }
}
