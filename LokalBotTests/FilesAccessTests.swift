import DigUpKit
import XCTest
@testable import LokalBot

/// File search for external agents: the grant and folder list the app keeps,
/// and `search_files` over a real Files index, as the CLI and MCP see them.
@MainActor
final class FilesAccessTests: XCTestCase {
    private var root: URL!
    private var chosen: URL!
    private var other: URL!
    private var gate: FilesAccessGate!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("files-access-\(UUID().uuidString)")
        chosen = root.appendingPathComponent("Chosen", isDirectory: true)
        other = root.appendingPathComponent("Other", isDirectory: true)
        for folder in [chosen!, other!] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        gate = FilesAccessGate(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testTheGrantIsOffByDefaultAndPrivateWhenOn() throws {
        XCTAssertFalse(gate.isEnabled)
        try gate.enable()
        XCTAssertTrue(gate.isEnabled)
        let marker = try FileManager.default.attributesOfItem(atPath: gate.accessMarkerURL.path)
        XCTAssertEqual((marker[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let folder = try FileManager.default.attributesOfItem(atPath: gate.controlDirectory.path)
        XCTAssertEqual((folder[.posixPermissions] as? NSNumber)?.intValue, 0o700)

        try gate.writeProjection(FilesAccessProjection(generatedAt: Date(), folders: [chosen.path]))
        XCTAssertEqual(gate.readProjection()?.folders, [chosen.path])
        gate.disable()
        XCTAssertFalse(gate.isEnabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: gate.projectionURL.path), "revoking removes the folder list")
    }

    func testTheManagerListsFoldersOnlyWhileFilesIsOnWithAFolder() throws {
        var folders: [String]? = [chosen.path]
        let manager = FilesAccessManager(gate: gate, folders: { folders })
        manager.start()
        XCTAssertNil(gate.readProjection(), "nothing is written without the grant")

        manager.setEnabled(true)
        XCTAssertEqual(gate.readProjection()?.folders, [chosen.path])

        folders = [chosen.path, other.path]
        manager.refresh()
        XCTAssertEqual(gate.readProjection()?.folders, [chosen.path, other.path])

        folders = nil   // Files turned off
        manager.refresh()
        XCTAssertNil(gate.readProjection())
        XCTAssertTrue(gate.isEnabled, "the grant stays; there is just nothing to search")

        manager.setEnabled(false)
        XCTAssertFalse(gate.isEnabled)
    }

    func testSearchNeedsTheGrantThenFilesThenItsIndex() async throws {
        XCTAssertEqual(search("budget").failure, .disabled)
        try gate.enable()
        XCTAssertEqual(search("budget").failure, .unavailable, "Files is off: no folder list")
        try gate.writeProjection(FilesAccessProjection(generatedAt: Date(), folders: [chosen.path]))
        XCTAssertEqual(search("budget").failure, .unavailable, "no index yet")
        XCTAssertFalse(FileManager.default.fileExists(atPath: gate.indexDirectory.path),
                       "searching never creates an index")
    }

    func testFindsFilesByTheirWordsOnlyInsideTheChosenFolders() async throws {
        try write("budget.txt", in: chosen, "The quarterly budget review moved to Thursday. Finance wants travel split by team.")
        try write("garden.md", in: chosen, "Tomatoes need watering twice a week; the basil went to seed early.")
        try write("budget-elsewhere.txt", in: other, "Another quarterly budget review, in a folder agents may not search.")
        try await index(folders: [chosen, other])
        try gate.enable()
        try gate.writeProjection(FilesAccessProjection(generatedAt: Date(), folders: [chosen.path]))

        let report = try XCTUnwrap(search("quarterly budget").success)
        XCTAssertEqual(report.results.map(\.name), ["budget.txt"])
        XCTAssertEqual(report.matchedBy, "words")
        let hit = try XCTUnwrap(report.results.first)
        XCTAssertEqual(hit.kind, "doc")
        XCTAssertTrue(hit.passage?.contains("Thursday") == true)
        // The walk reports the real path (/private/var for /var).
        XCTAssertEqual(hit.path, FolderSelection.realPath(chosen.appendingPathComponent("budget.txt").path))

        XCTAssertEqual(try XCTUnwrap(search("basil", kinds: ["pdf"]).success).results.count, 0, "kinds filter")
        XCTAssertEqual(try XCTUnwrap(search("basil", kinds: ["doc"]).success).results.map(\.name), ["garden.md"])
        XCTAssertEqual(try XCTUnwrap(search("basil", after: "2999-01-01").success).results.count, 0, "date filter")

        try FileManager.default.removeItem(at: chosen.appendingPathComponent("garden.md"))
        XCTAssertEqual(try XCTUnwrap(search("basil").success).results.count, 0, "a deleted file isn't returned")
    }

    func testRejectsBadArguments() {
        XCTAssertEqual(search("  ").failure?.isInvalid, true)
        XCTAssertEqual(search("x", limit: 0).failure?.isInvalid, true)
        XCTAssertEqual(search("x", limit: FilesSearchTool.maximumLimit + 1).failure?.isInvalid, true)
        XCTAssertEqual(search("x", kinds: ["code"]).failure?.isInvalid, true)
        XCTAssertEqual(search("x", after: "31/10/2026").failure?.isInvalid, true)
    }

    func testTheToolIsRefusedWithoutItsOwnGrantEvenWithEveryOtherGrant() async throws {
        try AgentAccessGate(root: root).enable()
        try ScreenMemoryAccessGate(root: root).enable()
        try PersonalContextAccessGate(root: root).enable()
        let provider = FileLibraryToolProvider(gate: AgentAccessGate(root: root), ask: { _ in .text("") })
        XCTAssertTrue(provider.tools.contains { $0.name == FilesSearchTool.name })

        let refused = await provider.call(name: "search_files", arguments: ["query": "budget"])
        XCTAssertTrue(refused.isError)
        XCTAssertTrue(refused.text.hasPrefix("[files_access_disabled]"), refused.text)

        try gate.enable()
        let unavailable = await provider.call(name: "search_files", arguments: ["query": "budget"])
        XCTAssertTrue(unavailable.text.hasPrefix("[files_unavailable]"), unavailable.text)
        let invalid = await provider.call(name: "search_files", arguments: ["query": "budget", "kinds": "doc"])
        XCTAssertTrue(invalid.text.hasPrefix("[invalid_arguments]"), invalid.text)
    }

    // MARK: - Helpers

    private func search(_ query: String, kinds: [String]? = nil, after: String? = nil,
                        limit: Int? = nil) -> Result<FilesSearchTool.Report, FilesSearchTool.Failure> {
        FilesSearchTool.report(query: query, kinds: kinds, after: after, limit: limit, gate: gate)
    }

    private func write(_ name: String, in folder: URL, _ text: String) throws {
        try String(repeating: text + " ", count: 4).write(to: folder.appendingPathComponent(name),
                                                          atomically: true, encoding: .utf8)
    }

    /// Reads `folders` into the Files index where the CLI looks for it.
    private func index(folders: [URL]) async throws {
        let service = FileSearchService(indexFolder: gate.indexDirectory, startEmbedder: { _ in
            .init(source: WordsEmbedder.workerInfo.vectorSource, makeEmbedder: { WordsEmbedder() }, end: {})
        })
        service.apply(.init(enabled: true, folders: folders.map(\.path)))
        await service.waitUntilIdle()
        XCTAssertEqual(service.state, .ready)
    }
}

private extension Result where Failure == FilesSearchTool.Failure {
    var success: Success? { if case .success(let value) = self { value } else { nil } }
    var failure: Failure? { if case .failure(let value) = self { value } else { nil } }
}

private extension FilesSearchTool.Failure {
    var isInvalid: Bool { if case .invalid = self { true } else { false } }
}

/// Bag-of-words vectors; the agent search never uses them, the index needs them.
private final class WordsEmbedder: Embedder {
    static let workerInfo = WorkerInfo(model: "test/words", revision: "0000000", runtime: "fake", dtype: "f32",
                                       dim: 768, textOnly: false, loadSeconds: nil)
    let info = WordsEmbedder.workerInfo

    private static func vector(_ text: String) -> [Float] {
        var vector = [Float](repeating: 0, count: 768)
        for word in text.lowercased().split(whereSeparator: { !$0.isLetter }) {
            vector[abs(word.hashValue) % 768] += 1
        }
        let norm = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        return norm > 0 ? vector.map { $0 / norm } : vector.indices.map { $0 == 0 ? 1 : 0 }
    }

    func embedTexts(_ texts: [String]) throws -> [[Float]] { texts.map(Self.vector) }
    func embedImages(_ paths: [String], budget: Int) throws -> [Embedding] {
        paths.map { _ in Embedding(vector: Self.vector("picture"), error: nil) }
    }
    func embedAudio(_ paths: [String]) throws -> [Embedding] {
        paths.map { _ in Embedding(vector: Self.vector("sound"), error: nil) }
    }
    func close() {}
}
