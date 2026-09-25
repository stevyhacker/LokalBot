import XCTest
import SQLite3
@testable import LokalBot

@MainActor
final class EmbeddingIndexIntegrationTests: XCTestCase {
    /// Opt-in, non-UI proof using a copied library and already downloaded model.
    /// No fixture path means no downloads, server launches, or library reads.
    func testHarrierRebuildAndRetrievalWhenFixtureProvided() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["LOKALBOT_EMBEDDING_FIXTURE"] else {
            throw XCTSkip("Set LOKALBOT_EMBEDDING_FIXTURE to an isolated library manifest.")
        }
        struct Query: Decodable {
            let id: String
            let query: String
            let language: String
            let relevantMeetings: [String]
        }
        struct Fixture: Decodable {
            let libraryRoot: String
            let meetingCount: Int
            let queries: [Query]
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let fixture = try decoder.decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let root = URL(fileURLWithPath: fixture.libraryRoot).standardizedFileURL.resolvingSymlinksInPath()
        let temporary = FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
        // Reject live-library roots even if a fixture was accidentally pointed
        // at one. The test writes vectors and StorageManager may repair metadata.
        let sharedTemporary = URL(fileURLWithPath: "/private/tmp")
            .standardizedFileURL.resolvingSymlinksInPath()
        guard root.path.hasPrefix(sharedTemporary.path + "/") || root.path.hasPrefix(temporary.path + "/") else {
            XCTFail("The integration fixture must use a temporary copied library.")
            return
        }
        let storage = StorageManager(rootURL: root)
        let meetings = storage.loadMeetings()
        XCTAssertEqual(meetings.count, fixture.meetingCount)
        let databaseURL = root.appendingPathComponent("harrier-validation.sqlite")
        let index = EmbeddingIndex(databaseURL: databaseURL, storage: storage)
        let database = try XCTUnwrap(SQLiteDatabase(url: databaseURL))
        do {
            let started = Date()
            for meeting in meetings { try await index.index(meeting) }
            let indexSeconds = Date().timeIntervalSince(started)
            XCTAssertTrue(index.hasEmbeddings)
            XCTAssertEqual(database.firstDouble("SELECT COUNT(*) FROM embedded_meetings"), Double(meetings.count))
            XCTAssertEqual(database.firstDouble(
                "SELECT COUNT(*) FROM embedded_meetings WHERE model_id != ?1", bind: [EmbeddingIndex.indexVersion]), 0)
            let vectorCount = database.firstDouble("SELECT COUNT(*) FROM embeddings") ?? 0
            XCTAssertGreaterThan(vectorCount, Double(meetings.count))
            var rows: [[String: Any]] = []
            for query in fixture.queries {
                let start = Date()
                let hits = await index.search(query.query, limit: 10)
                let meetingIDs = hits.map { String($0.meetingID.uuidString.lowercased().prefix(8)) }
                let firstRelevant = meetingIDs.firstIndex { query.relevantMeetings.contains($0) }
                rows.append([
                    "id": query.id, "language": query.language, "top10": meetingIDs,
                    "scores": hits.map(\.score), "rank": firstRelevant.map { $0 + 1 } ?? 0,
                    "seconds": Date().timeIntervalSince(start),
                ])
                XCTAssertFalse(hits.isEmpty, query.id)
                XCTAssertNotNil(
                    firstRelevant,
                    "\(query.id) returned no relevant meeting in its top 10 results")
            }
            // Running the backfill again must reuse the same model version,
            // not duplicate rows or silently erase freshly rebuilt vectors.
            for meeting in meetings { try await index.index(meeting) }
            XCTAssertEqual(database.firstDouble("SELECT COUNT(*) FROM embeddings"), vectorCount)
            if let report = environment["LOKALBOT_EMBEDDING_REPORT"] {
                let result: [String: Any] = [
                    "model_version": EmbeddingIndex.indexVersion, "meetings": meetings.count,
                    "vectors": vectorCount, "index_seconds": indexSeconds, "rows": rows,
                ]
                try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                    .write(to: URL(fileURLWithPath: report))
            }
            await LlamaServer.embedder.stop()
        } catch {
            await LlamaServer.embedder.stop()
            throw error
        }
    }
}
