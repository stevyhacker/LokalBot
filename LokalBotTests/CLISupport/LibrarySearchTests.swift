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

    func testLocalDayIsTheUsersCalendarDayNotUTC() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let day = try XCTUnwrap(LibraryInputPolicy.localDay("2026-10-02", calendar: calendar))

        XCTAssertEqual(day, try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-02T07:00:00Z")))
        XCTAssertNil(LibraryInputPolicy.localDay("2026-02-30", calendar: calendar))
        XCTAssertNil(LibraryInputPolicy.localDay("2026-10-2", calendar: calendar))
        XCTAssertNil(LibraryInputPolicy.localDay("October 2", calendar: calendar))
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
        XCTAssertEqual(try LibrarySearch.hits(query: "planning").count, 2)
        XCTAssertEqual(try LibrarySearch.hits(query: "planning", limit: 1).count, 1)
    }

    func testNoMatchReturnsEmpty() throws {
        XCTAssertTrue(try LibrarySearch.hits(query: "zzzznotthere").isEmpty)
    }

    func testWordsMatchInAnyOrderAndAQuotedQueryNeedsTheExactPhrase() throws {
        try MeetingFixture.write([
            .init(id: UUID(), title: "Pricing review", startedAt: Date(timeIntervalSince1970: 1_790_000_000),
                  summary: "", transcriptLines: ["We made the final decision on pricing today."]),
        ], under: root)
        let loose = try LibrarySearch.hits(query: "pricing decision")
        XCTAssertTrue(loose.contains { $0.snippet == "We made the final decision on pricing today." })
        XCTAssertTrue(try LibrarySearch.hits(query: "\"pricing decision\"").isEmpty)
        XCTAssertEqual(try LibrarySearch.hits(query: "\"decision on pricing\"").first?.match_kind, "transcript")
    }

    func testMatchingIgnoresAccentsAndSkipsApostropheFragments() throws {
        try MeetingFixture.write([
            .init(id: UUID(), title: "Sastanak", startedAt: Date(timeIntervalSince1970: 1_790_000_000),
                  summary: "", transcriptLines: ["Poslaću izveštaj o budžetu sutra."]),
        ], under: root)
        XCTAssertEqual(try LibrarySearch.hits(query: "izvestaj budzetu").first?.snippet,
                       "Poslaću izveštaj o budžetu sutra.")
        XCTAssertEqual(LibrarySearch.searchTerms(LibrarySearch.folded("Don't send it")), ["don", "send", "it"])
        XCTAssertEqual(LibrarySearch.searchTerms("e"), ["e"])
    }

    func testRareWordsOutrankCommonOnesAndOneMeetingCannotFillTheList() throws {
        var lines: [String] = []
        for index in 0..<12 { lines.append("We talked about the roadmap, item \(index).") }
        try MeetingFixture.write([
            .init(id: UUID(), title: "Long sync", startedAt: Date(timeIntervalSince1970: 1_795_000_000),
                  summary: "", transcriptLines: lines),
            .init(id: UUID(), title: "Vendor call", startedAt: Date(timeIntervalSince1970: 1_760_000_000),
                  summary: "", transcriptLines: ["We talked about the Kafka migration plan."]),
        ], under: root)
        let hits = try LibrarySearch.hits(query: "what did we decide about the kafka migration")
        XCTAssertEqual(hits.first?.meeting_title, "Vendor call", "the rare words lead, not the common ones")
        let broad = try LibrarySearch.hits(query: "talked")
        XCTAssertEqual(broad.filter { $0.meeting_title == "Long sync" }.count, LibrarySearch.maximumTranscriptHitsPerMeeting)
        XCTAssertTrue(broad.contains { $0.meeting_title == "Vendor call" })
    }

    func testShortWordsMatchOnlyWholeWordsAndTheSnippetFindsThem() throws {
        try MeetingFixture.write([
            .init(id: UUID(), title: "Rapid growth", startedAt: Date(timeIntervalSince1970: 1_791_000_000),
                  summary: "Rapid growth this quarter. " + String(repeating: "Filler. ", count: 20) + "The API limit stays at 50.",
                  transcriptLines: ["Banana exports grew."]),
        ], under: root)
        let hits = try LibrarySearch.hits(query: "api")
        XCTAssertEqual(hits.map(\.match_kind), ["summary"], "\"Rapid\" in the title is not the API")
        XCTAssertTrue(hits.first?.snippet.contains("API limit") == true, hits.first?.snippet ?? "")
        XCTAssertTrue(try LibrarySearch.hits(query: "ana").isEmpty, "\"Banana\" is not Ana")
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
