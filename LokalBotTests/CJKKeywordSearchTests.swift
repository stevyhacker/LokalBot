import XCTest
@testable import LokalBot

/// SQLite's unicode61 tokenizer indexes an unbroken run of CJK text as one
/// token, so keyword search found a Chinese word only at the start of a phrase:
/// 深色模式 matched 深色模式下设置页面…, but 对比度 and 三台设备 matched nothing.
final class CJKKeywordSearchTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cjk-search-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func index(_ specs: [MeetingFixture.Spec]) throws -> SearchIndex {
        try MeetingFixture.write(specs, under: root)
        let storage = StorageManager(rootURL: root)
        let index = SearchIndex(databaseURL: root.appendingPathComponent("lokalbotv3.sqlite"))
        index.reindexAll(storage.loadMeetings(), storage: storage)
        return index
    }

    func testChineseWordsMatchInsideAPhrase() throws {
        let review = UUID()
        let index = try index([
            .init(id: review, title: "Harbor 2.0 发布评审", startedAt: Date(timeIntervalSince1970: 1_790_000_000),
                  transcriptLines: ["回归测试我们在三台设备上都跑完了，深色模式下设置页面有几行字对比度太低。"]),
            .init(title: "Weekly sync", startedAt: Date(timeIntervalSince1970: 1_790_003_600),
                  transcriptLines: ["The dark mode contrast is fine on every device."]),
        ])

        for query in ["对比度", "三台设备", "深色模式 对比度", "设置页面"] {
            XCTAssertEqual(Set(index.search(query).map(\.meetingID)), [review], query)
        }
        let segment = try XCTUnwrap(index.search("对比度").first { $0.kind == .segment })
        XCTAssertTrue(segment.snippet.contains("«对比度»"), segment.snippet)
        XCTAssertEqual(segment.sourceText, "回归测试我们在三台设备上都跑完了，深色模式下设置页面有几行字对比度太低。")
        XCTAssertTrue(index.search("对比度 不存在").isEmpty, "every term must occur")
        XCTAssertEqual(index.matchingMeetingIDs("三台设备"), [review])
        XCTAssertTrue(index.search("对比度", kind: .title).isEmpty, "the kind filter still applies")
    }

    /// The chat tool retries a natural-language question in relaxed (OR) mode.
    /// A spaceless Chinese question is one long term, so its two-character
    /// pieces are matched instead and the passage sharing the most ranks first.
    func testRelaxedSearchRanksTheBestChineseMatchFirst() throws {
        let release = UUID()
        let index = try index([
            .init(id: release, title: "发布计划", startedAt: Date(timeIntervalSince1970: 1_790_000_000),
                  transcriptLines: ["王静负责在周二之前写好发布说明。", "大家周四一起吃饭。"]),
        ])

        XCTAssertTrue(index.search("谁负责写发布说明").isEmpty, "the whole question never occurs verbatim")
        let hits = index.search("谁负责写发布说明", matchAll: false, dropStopWords: true)
        XCTAssertEqual(hits.first?.meetingID, release)
        XCTAssertEqual(hits.first?.sourceText, "王静负责在周二之前写好发布说明。")
    }

    /// A Latin word glued to Chinese text is part of that run's token. The
    /// substring fallback runs only when FTS finds nothing, and only over rows
    /// that contain CJK text, so English rows never match by substring.
    func testLatinWordGluedToChineseIsFoundWithoutSubstringMatchingEnglish() throws {
        let interview = UUID()
        let index = try index([
            .init(id: interview, title: "用户访谈", startedAt: Date(timeIntervalSince1970: 1_790_000_000),
                  transcriptLines: ["客户说过的细节，比如logo再大一点。"]),
            .init(title: "Catalog review", startedAt: Date(timeIntervalSince1970: 1_790_003_600),
                  transcriptLines: ["The new catalogo shipped on time."]),
        ])

        XCTAssertEqual(index.search("logo").map(\.meetingID), [interview])
        XCTAssertTrue(index.search("logo").first?.snippet.contains("«logo»") == true)
        XCTAssertEqual(index.matchingMeetingIDs("logo"), [interview])
        XCTAssertEqual(index.matchingMeetingIDs("catalog"), Set(index.search("catalog").map(\.meetingID)),
                       "an English word FTS finds keeps its FTS results")
    }

    func testChineseScreenTextMatchesInsideAPhrase() throws {
        let url = root.appendingPathComponent("screens.sqlite")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = ActivityStore(databaseURL: url)
        let chinese = try store.insertScreenshot(
            ts: Date(), path: "/tmp/cjk-screen.heic.enc", app: "Feishu", windowTitle: "发布评审纪要",
            trigger: "window_change", ocr: "深色模式下设置页面有几行字对比度太低，看不太清。")
        let english = try store.insertScreenshot(
            ts: Date(), path: "/tmp/latin-screen.heic.enc", app: "Safari", windowTitle: "Quarterly report",
            trigger: "window_change", ocr: "Q3 revenue grew 14 percent")

        XCTAssertEqual(store.searchOCR("对比度").map(\.snapshotID), [chinese])
        XCTAssertEqual(store.searchOCR("对比度", groupResults: false).map(\.snapshotID), [chinese])
        XCTAssertTrue(store.searchOCR("对比度").first?.snippet.contains("«对比度»") == true)
        XCTAssertEqual(store.searchOCR("评审").map(\.snapshotID), [chinese], "window titles match too")
        XCTAssertEqual(store.searchOCR("revenue").map(\.snapshotID), [english], "English search still uses FTS")
        XCTAssertEqual(store.searchOCR("revenue 对比度", matchAll: false).count, 2,
                       "relaxed mode ORs Latin and Chinese terms")
    }
}
