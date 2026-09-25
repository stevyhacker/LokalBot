import XCTest
@testable import LokalBot

final class LibrarySearchTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("librarysearch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("LOKALBOT_STORAGE_ROOT", root.path, 1)

        try MeetingFixture.write([
            .init(
                id: UUID(uuidString: "AAAAAAAA-1111-4222-8333-444444444444")!,
                title: "Cache planning",
                startedAt: Date(timeIntervalSince1970: 1_780_000_000),
                summary: "## TL;DR\nWe chose Redis for the caching layer.",
                transcriptLines: ["Let us talk caching.", "Redis has pub sub support."]),
            .init(
                id: UUID(uuidString: "BBBBBBBB-1111-4222-8333-444444444444")!,
                title: "Weekly planning",
                startedAt: Date(timeIntervalSince1970: 1_770_000_000),
                summary: "## TL;DR\nStatus updates only.",
                transcriptLines: ["Nothing about datastores here."]),
        ], under: root)
    }

    override func tearDown() {
        unsetenv("LOKALBOT_STORAGE_ROOT")
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    func testFindsTitleSummaryAndTranscriptKinds() throws {
        let redis = try LibrarySearch.hits(query: "redis")
        XCTAssertEqual(Set(redis.map(\.match_kind)), ["summary", "transcript"])
        XCTAssertTrue(redis.allSatisfy { $0.meeting_title == "Cache planning" })

        let cache = try LibrarySearch.hits(query: "cache")
        XCTAssertEqual(cache.first?.match_kind, "title")
    }

    func testTranscriptHitCarriesTimestamp() throws {
        let hits = try LibrarySearch.hits(query: "pub sub")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].match_kind, "transcript")
        XCTAssertEqual(hits[0].timestamp, "00:00:10")
    }

    func testRecencyOrderAcrossMeetings() throws {
        let hits = try LibrarySearch.hits(query: "planning")
        XCTAssertEqual(hits.first?.meeting_title, "Cache planning")
        XCTAssertTrue(hits.contains { $0.meeting_title == "Weekly planning" })
    }

    func testLimitCapsHits() throws {
        XCTAssertEqual(try LibrarySearch.hits(query: "e", limit: 2).count, 2)
    }

    func testNoMatchReturnsEmpty() throws {
        XCTAssertTrue(try LibrarySearch.hits(query: "zzzznotthere").isEmpty)
    }

    func testUnicodeCaseExpansionUsesOriginalStringIndices() throws {
        XCTAssertEqual(LibrarySearch.snippet(in: "İzmir budget", around: "BUDGET"), "İzmir budget")
        XCTAssertEqual(LibrarySearch.snippet(in: "Cafe\u{301} and İZMİR Budget", around: "budget"),
                       "Cafe\u{301} and İZMİR Budget")
        try MeetingFixture.write([
            .init(id: UUID(), title: "Unicode summary", startedAt: Date(),
                  summary: "İzmir budget", transcriptLines: []),
        ], under: root)
        XCTAssertTrue(try LibrarySearch.hits(query: "BUDGET").contains { $0.snippet == "İzmir budget" })
    }
}
