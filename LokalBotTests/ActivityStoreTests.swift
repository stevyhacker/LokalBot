import XCTest
import CoreGraphics
@testable import LokalBot

@MainActor
final class ActivityStoreTests: XCTestCase {
    func testDayIntervalUsesCalendarDayAcrossSpringDST() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Podgorica"))

        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 29, hour: 12)))
        let interval = ActivityStore.dayInterval(containing: day, calendar: calendar)

        XCTAssertEqual(interval.duration, 23 * 60 * 60)
    }

    func testDayIntervalUsesCalendarDayAcrossFallDST() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Podgorica"))

        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 12)))
        let interval = ActivityStore.dayInterval(containing: day, calendar: calendar)

        XCTAssertEqual(interval.duration, 25 * 60 * 60)
    }

    func testInsertScreenshotStoresTriggerTitleAndLinksOCRRow() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ActivityStoreTests-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ActivityStore(databaseURL: url)

        let id = try store.insertScreenshot(
            ts: Date(), path: "/tmp/a.heic.enc", app: "Safari",
            windowTitle: "Quarterly report — Google Docs", trigger: "window_change",
            ocr: "Q3 revenue grew 14 percent")
        XCTAssertGreaterThan(id, 0)

        let shot = try XCTUnwrap(store.screenshots(on: Date()).first)
        XCTAssertEqual(shot.app, "Safari")
        XCTAssertEqual(shot.windowTitle, "Quarterly report — Google Docs")
        XCTAssertEqual(shot.trigger, "window_change")

        let hit = try XCTUnwrap(store.searchOCR("revenue").first)
        XCTAssertEqual(hit.snapshotID, id)
        XCTAssertEqual(hit.id, id)
        XCTAssertEqual(hit.windowTitle, "Quarterly report — Google Docs")
        XCTAssertEqual(store.screenshot(id: id)?.id, id)
        XCTAssertEqual(store.ocrText(snapshotID: id), "Q3 revenue grew 14 percent")

        // Window titles are indexed too: a query matching only the title hits.
        XCTAssertEqual(store.searchOCR("quarterly").count, 1)
    }

    func testDayScreenContextsReturnTheWholeDayInOrderWithPerCaptureCap() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ActivityStoreTests-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ActivityStore(databaseURL: url)
        let interval = ActivityStore.dayInterval(containing: Date())
        _ = try store.insertScreenshot(
            ts: interval.start.addingTimeInterval(-1),
            path: "", app: "Before", ocr: "outside previous day")
        let firstID = try store.insertScreenshot(
            ts: interval.start.addingTimeInterval(60),
            path: "", app: "Xcode", windowTitle: "Editor",
            ocr: "first evidence is intentionally long")
        let secondID = try store.insertScreenshot(
            ts: interval.start.addingTimeInterval(20 * 60 * 60),
            path: "", app: "Safari", windowTitle: "Documentation",
            ocr: "late evidence is intentionally long")
        _ = try store.insertScreenshot(
            ts: interval.end,
            path: "", app: "After", ocr: "outside next day")

        let contexts = store.screenContexts(on: interval.start, maxCharactersPerCapture: 14)

        XCTAssertEqual(contexts.map(\.snapshotID), [firstID, secondID])
        XCTAssertEqual(contexts.map(\.app), ["Xcode", "Safari"])
        XCTAssertEqual(contexts.map(\.windowTitle), ["Editor", "Documentation"])
        XCTAssertTrue(contexts.allSatisfy { $0.text.count <= 14 })
        XCTAssertEqual(contexts.last?.capturedAt, interval.start.addingTimeInterval(20 * 60 * 60))
    }

    func testLatestDayEvidenceIncludesActivityAndScreenContext() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ActivityStoreTests-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ActivityStore(databaseURL: url)
        let interval = ActivityStore.dayInterval(containing: Date())
        let screenTime = interval.start.addingTimeInterval(2 * 60 * 60)
        _ = try store.insertScreenshot(
            ts: screenTime, path: "", app: "Notes", ocr: "planning")
        XCTAssertEqual(store.latestEvidenceAt(on: interval.start), screenTime)

        let blockEnd = interval.start.addingTimeInterval(4 * 60 * 60)
        XCTAssertTrue(store.insert(ActivityBlock(
            app: "Xcode",
            title: "Implementation",
            start: interval.start.addingTimeInterval(3 * 60 * 60),
            end: blockEnd)))

        XCTAssertEqual(store.latestEvidenceAt(on: interval.start), blockEnd)
    }

    func testTextOnlyContextPersistsSanitizedProvenanceWithoutPretendingPixelsExist() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ActivityStoreTests-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ActivityStore(databaseURL: url)
        let capturedAt = Date()
        let meetingID = UUID().uuidString

        let id = try store.insertScreenshot(
            ts: capturedAt,
            path: "",
            app: "Safari",
            windowTitle: "Project brief",
            trigger: "typing_pause",
            textSource: "accessibility_redacted",
            ocr: "Visible project context [REDACTED]",
            sourceURL: "https://example.com/project",
            documentName: "Brief.md",
            meetingID: meetingID,
            privacyRedactions: 1)

        XCTAssertTrue(store.screenshots(on: capturedAt).isEmpty)
        let moment = try XCTUnwrap(
            store.screenshots(on: capturedAt, includingTextOnly: true).first)
        XCTAssertEqual(moment.id, id)
        XCTAssertFalse(moment.hasPixels)
        XCTAssertEqual(moment.sourceURL, "https://example.com/project")
        XCTAssertEqual(moment.documentName, "Brief.md")
        XCTAssertEqual(moment.meetingID, meetingID)
        XCTAssertEqual(moment.privacyRedactionCount, 1)
        XCTAssertEqual(store.ocrText(snapshotID: id), "Visible project context [REDACTED]")

        let reader = SQLiteScreenMemoryReader(databaseURL: url)
        let detail = try XCTUnwrap(reader.screenshotDetail(snapshotID: id))
        XCTAssertFalse(detail.hasEncryptedPixels)
        XCTAssertEqual(detail.sourceURL, "https://example.com/project")
        XCTAssertEqual(detail.documentName, "Brief.md")
        XCTAssertEqual(detail.meetingID, meetingID)
        XCTAssertEqual(detail.privacyRedactionCount, 1)
    }

    func testScreenshotAndOCRFiltersUseHalfOpenDateRangeAndExactApp() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ActivityStoreTests-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ActivityStore(databaseURL: url)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let safariID = try store.insertScreenshot(
            ts: base, path: "/tmp/safari.heic.enc", app: "Safari",
            ocr: "shared launch checklist")
        _ = try store.insertScreenshot(
            ts: base.addingTimeInterval(60), path: "/tmp/xcode.heic.enc", app: "Xcode",
            ocr: "shared compile checklist")
        _ = try store.insertScreenshot(
            ts: base.addingTimeInterval(120), path: "/tmp/later.heic.enc", app: "Safari",
            ocr: "shared later checklist")
        let interval = DateInterval(start: base, end: base.addingTimeInterval(120))

        XCTAssertEqual(
            store.screenshots(in: interval, app: "sAfArI").map(\.id),
            [safariID])
        XCTAssertEqual(
            store.searchOCR(
                "shared", filter: ScreenSearchFilter(interval: interval, app: "SAFARI"))
                .map(\.snapshotID),
            [safariID])
    }

    func testSavedMomentsPersistNotesAndBookmarkState() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ActivityStoreTests-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ActivityStore(databaseURL: url)
        let snapshotID = try store.insertScreenshot(
            ts: Date(), path: "/tmp/moment.heic.enc", app: "Notes",
            windowTitle: "Project plan", trigger: "manual", ocr: "launch plan")

        try store.saveMoment(snapshotID: snapshotID, note: "Decision source")
        let createdAt = try XCTUnwrap(store.savedMoments().first?.createdAt)
        XCTAssertTrue(store.screenshot(id: snapshotID)?.isBookmarked == true)
        XCTAssertEqual(store.screenshots(bookmarkedOnly: true).map(\.id), [snapshotID])

        try store.saveMoment(snapshotID: snapshotID, note: "Updated note")
        let saved = try XCTUnwrap(store.savedMoments().first)
        XCTAssertEqual(saved.snapshotID, snapshotID)
        XCTAssertEqual(saved.note, "Updated note")
        XCTAssertEqual(saved.createdAt, createdAt)

        // A second store proves bookmark state is durable rather than cached.
        let reopened = ActivityStore(databaseURL: url)
        XCTAssertEqual(reopened.savedMoments().first?.note, "Updated note")
        try reopened.removeSavedMoment(snapshotID: snapshotID)
        XCTAssertTrue(reopened.savedMoments().isEmpty)
        XCTAssertFalse(reopened.screenshot(id: snapshotID)?.isBookmarked ?? true)
    }

    func testPerceptualHashesPersistAndNearDuplicatesShareAGroup() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ActivityStoreTests-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ActivityStore(databaseURL: url)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let firstHash: UInt64 = 0x00FF_00FF_00FF_00FF
        let nearHash = firstHash ^ 0b101
        let farHash = ~firstHash
        let firstID = try store.insertScreenshot(
            ts: base, path: "/tmp/one.heic.enc", app: "Safari", ocr: "one",
            perceptualHash: firstHash)
        let nearID = try store.insertScreenshot(
            ts: base.addingTimeInterval(1), path: "/tmp/two.heic.enc", app: "Safari",
            ocr: "two", perceptualHash: nearHash)
        let farID = try store.insertScreenshot(
            ts: base.addingTimeInterval(2), path: "/tmp/three.heic.enc", app: "Safari",
            ocr: "three", perceptualHash: farHash)

        let first = try XCTUnwrap(store.screenshot(id: firstID))
        let near = try XCTUnwrap(store.screenshot(id: nearID))
        let far = try XCTUnwrap(store.screenshot(id: farID))
        XCTAssertEqual(first.perceptualHash, firstHash)
        XCTAssertEqual(near.perceptualHash, nearHash)
        XCTAssertEqual(first.similarityGroupID, firstID)
        XCTAssertEqual(near.similarityGroupID, firstID)
        XCTAssertEqual(far.similarityGroupID, farID)
    }

    func testPerceptualGroupingDoesNotDriftAwayFromItsRepresentative() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ActivityStoreTests-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ActivityStore(databaseURL: url)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let representative: UInt64 = 0
        let nearRepresentative = representative ^ 0b11_1111
        let nearPreviousButFarFromRepresentative = nearRepresentative ^ (0b11_1111 << 6)

        let firstID = try store.insertScreenshot(
            ts: base, path: "/tmp/drift-one.heic.enc", app: "Safari", ocr: "one",
            perceptualHash: representative)
        let secondID = try store.insertScreenshot(
            ts: base.addingTimeInterval(1), path: "/tmp/drift-two.heic.enc", app: "Safari",
            ocr: "two", perceptualHash: nearRepresentative)
        let thirdID = try store.insertScreenshot(
            ts: base.addingTimeInterval(2), path: "/tmp/drift-three.heic.enc", app: "Safari",
            ocr: "three", perceptualHash: nearPreviousButFarFromRepresentative)

        XCTAssertEqual(store.screenshot(id: firstID)?.similarityGroupID, firstID)
        XCTAssertEqual(store.screenshot(id: secondID)?.similarityGroupID, firstID)
        XCTAssertEqual(store.screenshot(id: thirdID)?.similarityGroupID, thirdID)
    }

    func testSearchOCRKeepsGroupedEvidenceAndCitationOnTheSameCapture() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ActivityStoreTests-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ActivityStore(databaseURL: url)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let firstHash: UInt64 = 0x00FF_00FF_00FF_00FF
        let firstID = try store.insertScreenshot(
            ts: base,
            path: "/tmp/first.heic.enc",
            app: "Safari",
            windowTitle: "Pull request #42",
            ocr: "failover failover failover exact recovery steps",
            perceptualHash: firstHash)
        _ = try store.insertScreenshot(
            ts: base.addingTimeInterval(90),
            path: "/tmp/latest.heic.enc",
            app: "Safari",
            windowTitle: "Pull request #42",
            ocr: "a long status page with one failover reference among many unrelated words",
            perceptualHash: firstHash ^ 0b101)

        let hit = try XCTUnwrap(store.searchOCR("failover").first)

        XCTAssertEqual(hit.snapshotID, firstID, "the citation must open the snippet's source")
        XCTAssertEqual(hit.ts, base)
        XCTAssertEqual(hit.similarityGroupID, firstID)
        XCTAssertEqual(hit.captureCount, 2)
        XCTAssertTrue(hit.snippet.contains("exact recovery steps"),
                      "the group should retain its strongest-ranked evidence snippet")
        XCTAssertEqual(store.screenshot(id: hit.snapshotID)?.ts, hit.ts)
    }

    func testFallbackGroupingKeepsChangedNumericEvidenceWithItsSource() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ActivityStoreTests-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ActivityStore(databaseURL: url)
        let base = Calendar.current.startOfDay(for: Date()).addingTimeInterval(3_600)
        let firstID = try store.insertScreenshot(
            ts: base, path: "", app: "Notes", windowTitle: "Budget",
            ocr: "budget budget budget is 10 dollars")
        _ = try store.insertScreenshot(
            ts: base.addingTimeInterval(60), path: "", app: "Notes", windowTitle: "Budget",
            ocr: "This longer revised document now lists the budget as 50 dollars with other details")

        let hit = try XCTUnwrap(store.searchOCR("budget").first)

        XCTAssertEqual(hit.captureCount, 2)
        XCTAssertEqual(hit.snapshotID, firstID)
        XCTAssertEqual(hit.ts, base)
        XCTAssertTrue(hit.snippet.contains("10 dollars"))
        XCTAssertFalse(hit.snippet.contains("50 dollars"))
    }

    func testSearchOCRFallsBackToAppWindowAndDayForUngroupedCaptures() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ActivityStoreTests-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ActivityStore(databaseURL: url)
        let first = Calendar.current.startOfDay(for: Date()).addingTimeInterval(60 * 60)
        _ = try store.insertScreenshot(
            ts: first, path: "/tmp/first.heic.enc", app: "Notes",
            windowTitle: "Launch plan", ocr: "private beta checklist")
        let latestID = try store.insertScreenshot(
            ts: first.addingTimeInterval(60), path: "/tmp/latest.heic.enc", app: "Notes",
            windowTitle: "Launch plan", ocr: "private beta owners")

        let hits = store.searchOCR("private beta")

        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.snapshotID, latestID)
        XCTAssertEqual(hits.first?.captureCount, 2)
        XCTAssertNil(hits.first?.similarityGroupID)
    }

    func testSearchOCRAppliesResultLimitAfterCollapsingDuplicateScenes() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ActivityStoreTests-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ActivityStore(databaseURL: url)
        let first = Calendar.current.startOfDay(for: Date()).addingTimeInterval(60 * 60)
        for minute in 0..<5 {
            _ = try store.insertScreenshot(
                ts: first.addingTimeInterval(Double(minute * 60)),
                path: "/tmp/duplicate-\(minute).heic.enc",
                app: "Safari",
                windowTitle: "Pull request #42",
                ocr: "release checklist status")
        }
        _ = try store.insertScreenshot(
            ts: first.addingTimeInterval(6 * 60),
            path: "/tmp/other.heic.enc",
            app: "Xcode",
            windowTitle: "Release.swift",
            ocr: "release checklist implementation")

        let hits = store.searchOCR("release checklist", limit: 2)

        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(hits.map(\.captureCount).sorted(), [1, 5])
    }

    func testDeleteScreenshotRemovesOCRBookmarkAndSemanticVector() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ActivityStoreTests-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ActivityStore(databaseURL: url)
        let snapshotID = try store.insertScreenshot(
            ts: Date(), path: "/tmp/delete.heic.enc", app: "Safari",
            ocr: "delete this source")
        try store.saveMoment(snapshotID: snapshotID)
        let database = try XCTUnwrap(SQLiteDatabase(url: url))
        try database.execute("""
            CREATE TABLE screen_embeddings (
                snapshot_id INTEGER PRIMARY KEY, ts REAL NOT NULL,
                app TEXT NOT NULL, text TEXT NOT NULL, vec BLOB NOT NULL,
                model_id TEXT NOT NULL DEFAULT '');
            """)
        try database.runChecked("""
            INSERT INTO screen_embeddings (snapshot_id, ts, app, text, vec, model_id)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6)
            """, bind: [snapshotID, Date().timeIntervalSince1970, "Safari", "delete", Data([0]), "test"])

        try store.deleteScreenshot(id: snapshotID)

        XCTAssertNil(store.screenshot(id: snapshotID))
        XCTAssertNil(store.ocrText(snapshotID: snapshotID))
        XCTAssertTrue(store.savedMoments().isEmpty)
        XCTAssertFalse(try database.hasRowChecked(
            "SELECT 1 FROM screen_embeddings WHERE snapshot_id = ?1", bind: [snapshotID]))
    }

    func testReciprocalRankFusionIsStableAndRewardsAgreement() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let keyword = [
            ActivityStore.OCRHit(
                snapshotID: 1, ts: now, app: "Safari", snippet: "keyword one"),
            ActivityStore.OCRHit(
                snapshotID: 2, ts: now, app: "Xcode", snippet: "keyword two"),
        ]
        let semantic = [
            EmbeddingIndex.ScreenHit(
                snapshotID: 2, ts: now, app: "Xcode", text: "semantic two", score: 0.9),
            EmbeddingIndex.ScreenHit(
                snapshotID: 3, ts: now, app: "Notes", text: "semantic three", score: 0.8),
        ]

        let ranked = ScreenSearchRanker.fuse(
            keyword: keyword, semantic: semantic, limit: 3)

        XCTAssertEqual(ranked.map(\.snapshotID), [2, 1, 3])
        XCTAssertEqual(ranked.first?.keywordRank, 2)
        XCTAssertEqual(ranked.first?.semanticRank, 1)
        XCTAssertGreaterThan(ranked[0].score, ranked[1].score)
    }

    func testSemanticScreenRankingUsesCosineAndDeterministicTieBreaks() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let vectorData: ([Float]) -> Data = { values in
            values.withUnsafeBufferPointer { buffer in
                Data(bytes: buffer.baseAddress!, count: buffer.count * MemoryLayout<Float>.stride)
            }
        }
        let candidates = [
            EmbeddingIndex.ScreenCandidate(
                snapshotID: 3, ts: now, app: "Notes", text: "weak",
                vector: vectorData([0.2, 0.8])),
            EmbeddingIndex.ScreenCandidate(
                snapshotID: 2, ts: now, app: "Xcode", text: "tie",
                vector: vectorData([0.8, 0.2])),
            EmbeddingIndex.ScreenCandidate(
                snapshotID: 1, ts: now, app: "Safari", text: "tie",
                vector: vectorData([0.8, 0.2])),
        ]

        let ranked = EmbeddingIndex.rankScreen(
            candidates, against: [1, 0], limit: 2)

        XCTAssertEqual(ranked.map(\.snapshotID), [1, 2])
        XCTAssertEqual(ranked.map(\.score), [0.8, 0.8])
    }

    func testSearchOCRRelaxedFallbackRescuesNaturalLanguage() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ActivityStoreTests-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ActivityStore(databaseURL: url)
        try store.insertScreenshot(ts: Date(), path: "/tmp/a.heic.enc", app: "Safari",
                                   ocr: "kubernetes deployment rollback steps")

        // Strict ANDs the stop words and misses…
        XCTAssertTrue(store.searchOCR("what were the rollback steps").isEmpty)
        // …the relaxed OR query rescues the content terms.
        XCTAssertFalse(store.searchOCR("what were the rollback steps",
                                       matchAll: false, dropStopWords: true).isEmpty)
    }

    func testMigratesLegacySchemaPreservingRows() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ActivityStoreTests-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        // Plant the pre-event-driven schema: screenshots without window_title /
        // capture_trigger, ocr_fts with only (text, ts, app).
        do {
            let legacy = try XCTUnwrap(SQLiteDatabase(url: url))
            legacy.exec("""
                CREATE TABLE screenshots (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    ts REAL NOT NULL, path TEXT NOT NULL, app TEXT NOT NULL);
                CREATE VIRTUAL TABLE ocr_fts USING fts5(
                    text, ts UNINDEXED, app UNINDEXED,
                    tokenize='unicode61 remove_diacritics 2');
                """)
            legacy.run("INSERT INTO screenshots (ts, path, app) VALUES (?1, ?2, ?3)",
                       bind: [Date().timeIntervalSince1970, "/tmp/legacy.heic.enc", "Notes"])
            legacy.run("INSERT INTO ocr_fts (text, ts, app) VALUES (?1, ?2, ?3)",
                       bind: ["grocery list milk eggs", Date().timeIntervalSince1970, "Notes"])
        }

        let store = ActivityStore(databaseURL: url)

        // Legacy rows survive with default trigger/title, and stay searchable.
        let legacyShot = try XCTUnwrap(store.screenshots(on: Date()).first)
        XCTAssertEqual(legacyShot.app, "Notes")
        XCTAssertEqual(legacyShot.trigger, "interval")
        XCTAssertEqual(legacyShot.windowTitle, "")
        XCTAssertEqual(store.searchOCR("grocery").count, 1)

        // New-shape inserts work on the migrated tables.
        try store.insertScreenshot(ts: Date(), path: "/tmp/new.heic.enc", app: "Xcode",
                                   windowTitle: "build log", trigger: "app_switch",
                                   ocr: "compile succeeded")
        XCTAssertEqual(store.searchOCR("compile").first?.windowTitle, "build log")
        XCTAssertEqual(store.screenshots(on: Date()).count, 2)
    }

    func testLegacyOCRMigrationUsesTimestampInsteadOfDivergedFTSRowID() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ActivityStoreTests-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        do {
            let legacy = try XCTUnwrap(SQLiteDatabase(url: url))
            try legacy.execute("""
                CREATE TABLE screenshots (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    ts REAL NOT NULL, path TEXT NOT NULL, app TEXT NOT NULL);
                CREATE VIRTUAL TABLE ocr_fts USING fts5(
                    text, ts UNINDEXED, app UNINDEXED,
                    tokenize='unicode61 remove_diacritics 2');
                """)
            try legacy.runChecked(
                "INSERT INTO screenshots (ts, path, app) VALUES (?1, ?2, ?3)",
                bind: [base.timeIntervalSince1970, "/tmp/no-ocr.heic.enc", "Notes"])
            try legacy.runChecked(
                "INSERT INTO screenshots (ts, path, app) VALUES (?1, ?2, ?3)",
                bind: [base.addingTimeInterval(10).timeIntervalSince1970,
                       "/tmp/with-ocr.heic.enc", "Notes"])
            // Empty OCR was never inserted in the legacy FTS table, so this
            // row's FTS rowid is 1 while its real screenshot id is 2.
            try legacy.runChecked(
                "INSERT INTO ocr_fts (text, ts, app) VALUES (?1, ?2, ?3)",
                bind: ["linked to the second frame",
                       base.addingTimeInterval(10).timeIntervalSince1970, "Notes"])
        }

        let store = ActivityStore(databaseURL: url)
        let hit = try XCTUnwrap(store.searchOCR("second").first)
        XCTAssertEqual(hit.snapshotID, 2)
        XCTAssertEqual(store.screenshot(id: hit.snapshotID)?.path, "/tmp/with-ocr.heic.enc")
    }

    func testExistingV2OCRMigrationRepairsZeroSnapshotID() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ActivityStoreTests-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let capturedAt = Date(timeIntervalSince1970: 1_700_000_000)

        do {
            let legacy = try XCTUnwrap(SQLiteDatabase(url: url))
            try legacy.execute("""
                CREATE TABLE screenshots (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    ts REAL NOT NULL, path TEXT NOT NULL, app TEXT NOT NULL,
                    window_title TEXT NOT NULL DEFAULT '',
                    capture_trigger TEXT NOT NULL DEFAULT 'interval');
                CREATE VIRTUAL TABLE ocr_fts USING fts5(
                    text, window_title, ts UNINDEXED, app UNINDEXED,
                    text_source UNINDEXED, snapshot_id UNINDEXED,
                    tokenize='unicode61 remove_diacritics 2');
                """)
            try legacy.runChecked(
                "INSERT INTO screenshots (ts, path, app) VALUES (?1, ?2, ?3)",
                bind: [capturedAt.timeIntervalSince1970, "/tmp/v2.heic.enc", "Xcode"])
            try legacy.runChecked("""
                INSERT INTO ocr_fts (
                    text, window_title, ts, app, text_source, snapshot_id
                ) VALUES (?1, ?2, ?3, ?4, 'ocr', 0)
                """, bind: ["repair this orphan", "Editor",
                              capturedAt.timeIntervalSince1970, "xcode"])
        }

        let store = ActivityStore(databaseURL: url)
        let hit = try XCTUnwrap(store.searchOCR("orphan").first)
        XCTAssertEqual(hit.snapshotID, 1)
        XCTAssertEqual(store.ocrText(snapshotID: 1), "repair this orphan")
    }

    func testScreenshotAndOCRRowsRollbackTogetherWhenOCRInsertFails() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ActivityStoreTests-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ActivityStore(databaseURL: url)
        let database = try XCTUnwrap(SQLiteDatabase(url: url))
        try database.execute("DROP TABLE ocr_fts")

        XCTAssertThrowsError(try store.insertScreenshot(
            ts: Date(), path: "/tmp/rollback.heic.enc", app: "Safari",
            ocr: "this OCR insert must fail"))

        XCTAssertEqual(
            try database.firstDoubleChecked("SELECT COUNT(*) FROM screenshots"), 0,
            "The screenshot row must roll back when its searchable OCR pair fails")
    }

    // MARK: - Capture policy

    func testCapturePolicyCooldownAndIdleFallback() {
        var policy = ScreenCapturePolicy(eventCooldown: 20)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)

        // First ever check always captures.
        XCTAssertTrue(policy.shouldCapture(trigger: .appSwitch, idleInterval: 180, now: t0))
        policy.noteCheck(at: t0)

        // Event triggers inside the cooldown are dropped; after it, allowed.
        XCTAssertFalse(policy.shouldCapture(trigger: .appSwitch, idleInterval: 180,
                                            now: t0.addingTimeInterval(5)))
        XCTAssertFalse(policy.shouldCapture(trigger: .windowChange, idleInterval: 180,
                                            now: t0.addingTimeInterval(19)))
        XCTAssertTrue(policy.shouldCapture(trigger: .windowChange, idleInterval: 180,
                                           now: t0.addingTimeInterval(21)))

        // The interval trigger waits for the full idle window…
        XCTAssertFalse(policy.shouldCapture(trigger: .interval, idleInterval: 180,
                                            now: t0.addingTimeInterval(60)))
        XCTAssertTrue(policy.shouldCapture(trigger: .interval, idleInterval: 180,
                                           now: t0.addingTimeInterval(181)))

        // …and manual always fires.
        XCTAssertTrue(policy.shouldCapture(trigger: .manual, idleInterval: 180,
                                           now: t0.addingTimeInterval(1)))
    }

    func testAutomaticScreenCapturesPauseDuringMeetingRecording() {
        XCTAssertFalse(ScreenshotService.shouldCaptureDuringMeetingRecording(
            trigger: .appSwitch,
            recordingActive: true))
        XCTAssertFalse(ScreenshotService.shouldCaptureDuringMeetingRecording(
            trigger: .windowChange,
            recordingActive: true))
        XCTAssertFalse(ScreenshotService.shouldCaptureDuringMeetingRecording(
            trigger: .interval,
            recordingActive: true))

        // Explicit user action still works while recording.
        XCTAssertTrue(ScreenshotService.shouldCaptureDuringMeetingRecording(
            trigger: .manual,
            recordingActive: true))
        XCTAssertTrue(ScreenshotService.shouldCaptureDuringMeetingRecording(
            trigger: .interval,
            recordingActive: false))
        XCTAssertTrue(ScreenshotService.shouldCaptureDuringMeetingRecording(
            trigger: .typingPause,
            recordingActive: true,
            visualContextEnabled: true))
    }

    func testAutomaticScreenCaptureSkipsTheLokalBotProcessButManualCaptureDoesNot() {
        let ownProcessID: pid_t = 42
        let automaticTriggers: [ScreenCaptureTrigger] = [
            .appSwitch, .windowChange, .click, .typingPause,
            .scrollSettled, .clipboardChange, .interval,
        ]

        for trigger in automaticTriggers {
            XCTAssertTrue(ScreenshotService.shouldSkipAutomaticSelfCapture(
                trigger: trigger,
                frontmostProcessID: ownProcessID,
                ownProcessID: ownProcessID))
        }
        XCTAssertFalse(ScreenshotService.shouldSkipAutomaticSelfCapture(
            trigger: .manual,
            frontmostProcessID: ownProcessID,
            ownProcessID: ownProcessID))
        XCTAssertFalse(ScreenshotService.shouldSkipAutomaticSelfCapture(
            trigger: .click,
            frontmostProcessID: 99,
            ownProcessID: ownProcessID))
    }

    func testCaptureLayoutIncludesOnlyThePolicyCheckedFocusedWindow() throws {
        let windows = [
            // The AX title and frame identify one focused window rather than
            // selecting a different window of the same app by array order.
            ScreenshotCaptureLayout.Window(
                id: 10, processID: 42, appName: "Safari", title: "Other tab",
                frame: CGRect(x: 100, y: 100, width: 600, height: 500)),
            ScreenshotCaptureLayout.Window(
                id: 11, processID: 42, appName: "Safari", title: "Focused report",
                frame: CGRect(x: 1_100, y: 100, width: 700, height: 500)),
            ScreenshotCaptureLayout.Window(
                id: 20, processID: 90, appName: "1Password", title: "Secrets",
                frame: CGRect(x: 1_200, y: 200, width: 400, height: 400)),
            ScreenshotCaptureLayout.Window(
                id: 21, processID: 91, appName: "Signal", title: "Private chat",
                frame: CGRect(x: 1_650, y: 50, width: 300, height: 500)),
            ScreenshotCaptureLayout.Window(
                id: 23, processID: 93, appName: "Safari", title: "Private Browsing — Start Page",
                frame: CGRect(x: 1_020, y: 20, width: 360, height: 320)),
            // Windows on another display also stay outside the window filter.
            ScreenshotCaptureLayout.Window(
                id: 22, processID: 92, appName: "1Password", title: "Vault",
                frame: CGRect(x: 20, y: 20, width: 300, height: 300)),
        ]

        let selection = try XCTUnwrap(ScreenshotCaptureLayout.selection(
            windows: windows,
            frontmostProcessID: 42,
            focusedWindowTitle: "Focused report",
            focusedWindowFrame: CGRect(x: 1_100, y: 100, width: 700, height: 500),
            excludedApps: ["1password", "SIGNAL"]))

        // All other windows stay outside the filter, including an ordinary
        // background browser whose excluded domain is not known here.
        XCTAssertEqual(selection.windowID, 11)
    }

    func testCaptureLayoutDoesNotFallBackWithoutTheCheckedWindow() {
        let selection = ScreenshotCaptureLayout.selection(
            windows: [],
            frontmostProcessID: 42,
            focusedWindowTitle: "",
            focusedWindowFrame: nil,
            excludedApps: [])

        XCTAssertNil(selection)
    }

    func testCaptureLayoutRejectsAmbiguousAndPrivateFocusedWindows() {
        let frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let windows = [
            ScreenshotCaptureLayout.Window(id: 1, processID: 42, appName: "Safari", title: "Report", frame: frame),
            ScreenshotCaptureLayout.Window(id: 2, processID: 42, appName: "Safari", title: "Report", frame: frame),
        ]
        XCTAssertNil(ScreenshotCaptureLayout.selection(
            windows: windows, frontmostProcessID: 42, focusedWindowTitle: "Report",
            focusedWindowFrame: frame, excludedApps: []))
        XCTAssertNil(ScreenshotCaptureLayout.selection(
            windows: Array(windows.prefix(1)), frontmostProcessID: 42, focusedWindowTitle: "Report",
            focusedWindowFrame: frame, excludedApps: ["Safari"]))
        XCTAssertNil(ScreenshotCaptureLayout.selection(
            windows: [.init(id: 3, processID: 42, appName: "Safari", title: "Private Window", frame: frame)],
            frontmostProcessID: 42, focusedWindowTitle: "Private Window",
            focusedWindowFrame: frame, excludedApps: []))
    }

    func testCaptureFileNamesAndInFlightGateCannotCollide() {
        let root = URL(fileURLWithPath: "/tmp/screenshot-path-test", isDirectory: true)
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000.125)
        let first = ScreenshotService.captureFileURL(
            rootURL: root, timestamp: timestamp,
            identifier: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let second = ScreenshotService.captureFileURL(
            rootURL: root, timestamp: timestamp,
            identifier: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)

        XCTAssertNotEqual(first, second)
        XCTAssertTrue(first.lastPathComponent.hasPrefix("1700000000125-"))

        var gate = ScreenshotCaptureGate()
        XCTAssertTrue(gate.begin())
        XCTAssertFalse(gate.begin())
        gate.end()
        XCTAssertTrue(gate.begin())
    }

    func testFocusedWindowTitleLookupRunsOffMainAndReturnsValue() async {
        let lookup = FocusedWindowTitleLookup { _ in
            Thread.isMainThread ? "main" : "background"
        }

        let result = await lookup.title(for: 42)

        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.title, "background")
    }

    func testFocusedWindowTitleLookupFailsClosedAtWholeOperationDeadline() async {
        let lookup = FocusedWindowTitleLookup(deadlineMilliseconds: 20) { _ in
            Thread.sleep(forTimeInterval: 0.2)
            return "too late"
        }
        let started = ContinuousClock.now

        let result = await lookup.title(for: 42)

        XCTAssertTrue(result.timedOut)
        XCTAssertNil(result.title)
        XCTAssertLessThan(started.duration(to: .now), .milliseconds(150))
    }

    func testStalledWindowTitleLookupDoesNotQueueAnotherTarget() async {
        let blocker = DispatchSemaphore(value: 0)
        let probe = ActivityResolverInvocationProbe()
        let lookup = FocusedWindowTitleLookup(deadlineMilliseconds: 20) { _ in
            probe.recordInvocation()
            blocker.wait()
            return "late"
        }
        defer { blocker.signal() }

        let first = Task { await lookup.title(for: 42) }
        for _ in 0..<20 where probe.invocationCount == 0 {
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(probe.invocationCount, 1)
        let firstResult = await first.value
        XCTAssertTrue(firstResult.timedOut)

        let started = ContinuousClock.now
        let second = await lookup.title(for: 43)

        XCTAssertTrue(second.timedOut)
        XCTAssertLessThan(started.duration(to: .now), .milliseconds(20))
        XCTAssertEqual(probe.invocationCount, 1)
    }

    func testScreenshotWindowFocusValidationFailsClosedOnTimeoutOrChange() {
        let snapshot = ScreenAccessibilitySnapshot(
            text: "Report", sourceURL: "https://example.com/report", documentName: nil,
            focusedSecureField: false, windowTitle: "Report",
            windowFrame: CGRect(x: 0, y: 0, width: 800, height: 600), hasWebContent: true)
        XCTAssertTrue(ScreenshotWindowFocusValidation.matches(
            expected: snapshot, current: .init(snapshot: snapshot, timedOut: false)))
        XCTAssertFalse(ScreenshotWindowFocusValidation.matches(
            expected: snapshot, current: .timeout))
        XCTAssertFalse(ScreenshotWindowFocusValidation.matches(
            expected: snapshot, current: .init(snapshot: nil, timedOut: false)))
        var changed = snapshot
        changed.sourceURL = "https://private.example/account"
        XCTAssertFalse(ScreenshotWindowFocusValidation.matches(
            expected: snapshot, current: .init(snapshot: changed, timedOut: false)))
        changed = snapshot
        changed.focusedSecureField = nil
        XCTAssertFalse(ScreenshotWindowFocusValidation.matches(
            expected: snapshot, current: .init(snapshot: changed, timedOut: false)))
        changed = snapshot
        changed.windowFrame = CGRect(x: 100, y: 100, width: 800, height: 600)
        XCTAssertFalse(ScreenshotWindowFocusValidation.matches(
            expected: snapshot, current: .init(snapshot: changed, timedOut: false)))
    }

    func testActivitySamplerRemovesTerminationObserverWhenStopped() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ActivityStoreTests-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let sampler = ActivitySampler(
            store: ActivityStore(databaseURL: url),
            notificationCenter: NotificationCenter())

        XCTAssertFalse(sampler.hasTerminationObserver)
        sampler.start()
        XCTAssertTrue(sampler.hasTerminationObserver)
        sampler.stop()
        XCTAssertFalse(sampler.hasTerminationObserver)
    }

    func testActivityOnlySamplerNeverPersistsExcludedOrUnknownTitles() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ActivityPrivacyTests-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ActivityStore(databaseURL: url)
        let sampler = ActivitySampler(store: store)
        sampler.excludedDomains = { ["private.test"] }
        let base = Date().addingTimeInterval(-90)
        let safe = ScreenAccessibilitySnapshot(
            text: "", sourceURL: "https://public.test/document", documentName: nil,
            focusedSecureField: false, windowTitle: "Public report", windowFrame: nil)
        var privateWindow = safe
        privateWindow.windowTitle = "Sensitive account — Private Window"
        var excludedDomain = safe
        excludedDomain.sourceURL = "https://private.test/account"
        excludedDomain.windowTitle = "Sensitive banking title"
        var unknownURL = safe
        unknownURL.sourceURL = nil
        unknownURL.windowTitle = "Unverified browser title"
        var unknownSecureState = safe
        unknownSecureState.focusedSecureField = nil
        unknownSecureState.windowTitle = "Unknown secure title"
        let samples: [ScreenAccessibilityCaptureResult] = [
            .init(snapshot: safe, timedOut: false),
            .init(snapshot: privateWindow, timedOut: false),
            .init(snapshot: excludedDomain, timedOut: false),
            .init(snapshot: unknownURL, timedOut: false),
            .timeout,
            .init(snapshot: unknownSecureState, timedOut: false),
            .init(snapshot: safe, timedOut: false),
        ]
        for (index, sample) in samples.enumerated() {
            sampler.recordSample(appName: "Safari", bundleIdentifier: "com.apple.Safari",
                                 accessibility: sample, at: base.addingTimeInterval(Double(index * 10)))
        }
        sampler.stop()

        let blocks = store.blocks(in: DateInterval(start: base, end: Date().addingTimeInterval(1)))
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(blocks.map(\.title), ["Public report", "", "Public report"])
        XCTAssertEqual(blocks.map(\.app), ["Safari", "Private", "Safari"])
        XCTAssertEqual(blocks[1].duration, 50)
    }

    func testClearOCRTextRemovesOnlyRowsOlderThanCutoff() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ActivityStoreTests-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ActivityStore(databaseURL: url)

        let old = Date(timeIntervalSinceNow: -3 * 86_400)
        try store.insertScreenshot(ts: old, path: "/tmp/old.heic.enc", app: "Safari",
                                   ocr: "ancient invoice number")
        try store.insertScreenshot(ts: Date(), path: "/tmp/new.heic.enc", app: "Xcode",
                                   ocr: "fresh build log")

        store.clearOCRText(olderThan: Date(timeIntervalSinceNow: -86_400))

        XCTAssertTrue(store.searchOCR("invoice").isEmpty)
        XCTAssertEqual(store.searchOCR("fresh").count, 1)
        // Pixel bookkeeping untouched: text pruning is independent of paths.
        XCTAssertEqual(store.screenshotPaths(olderThan: Date()).count, 2)
    }

    func testRetentionPreservesSavedMomentPixelsOCRAndEmbeddingUntilUnsaved() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ActivityStoreTests-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ActivityStore(databaseURL: url)
        let old = Date(timeIntervalSinceNow: -3 * 86_400)
        let cutoff = Date(timeIntervalSinceNow: -86_400)
        let savedID = try store.insertScreenshot(
            ts: old, path: "/tmp/saved-moment.heic.enc", app: "Notes",
            ocr: "saved launch decision")
        let ordinaryID = try store.insertScreenshot(
            ts: old, path: "/tmp/ordinary.heic.enc", app: "Safari",
            ocr: "ordinary expired context")
        try store.saveMoment(snapshotID: savedID, note: "Keep this")

        let database = try XCTUnwrap(SQLiteDatabase(url: url))
        try database.execute("""
            CREATE TABLE screen_embeddings (
                snapshot_id INTEGER PRIMARY KEY, ts REAL NOT NULL,
                app TEXT NOT NULL, text TEXT NOT NULL, vec BLOB NOT NULL,
                model_id TEXT NOT NULL DEFAULT '');
            """)
        for (id, text) in [(savedID, "saved"), (ordinaryID, "ordinary")] {
            try database.runChecked("""
                INSERT INTO screen_embeddings (snapshot_id, ts, app, text, vec, model_id)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6)
                """, bind: [id, old.timeIntervalSince1970, "Test", text, Data([0]), "test"])
        }

        XCTAssertEqual(
            Set(store.screenshotPaths(olderThan: cutoff)),
            Set(["/tmp/ordinary.heic.enc"]))
        XCTAssertTrue(store.clearOCRText(olderThan: cutoff))
        XCTAssertEqual(store.ocrText(snapshotID: savedID), "saved launch decision")
        XCTAssertNil(store.ocrText(snapshotID: ordinaryID))
        XCTAssertTrue(try database.hasRowChecked(
            "SELECT 1 FROM screen_embeddings WHERE snapshot_id = ?1", bind: [savedID]))
        XCTAssertFalse(try database.hasRowChecked(
            "SELECT 1 FROM screen_embeddings WHERE snapshot_id = ?1", bind: [ordinaryID]))

        try store.removeSavedMoment(snapshotID: savedID)
        XCTAssertEqual(
            Set(store.screenshotPaths(olderThan: cutoff)),
            Set(["/tmp/saved-moment.heic.enc", "/tmp/ordinary.heic.enc"]))
        XCTAssertTrue(store.clearOCRText(olderThan: cutoff))
        XCTAssertNil(store.ocrText(snapshotID: savedID))
        XCTAssertFalse(try database.hasRowChecked(
            "SELECT 1 FROM screen_embeddings WHERE snapshot_id = ?1", bind: [savedID]))
    }

    func testOrphanRetentionRechecksLinkBookmarkAndTimestampBeforeDeleting() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrphanRetentionScopeTests-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ActivityStore(databaseURL: url)
        let database = try XCTUnwrap(SQLiteDatabase(url: url))
        let old = Date(timeIntervalSince1970: 1_800_000_000)
        for (rowID, snapshotID) in [(501, 0), (502, 9_001), (503, 9_002), (504, 9_003)] {
            try database.runChecked("""
                INSERT INTO ocr_fts (rowid, text, window_title, ts, app, text_source, snapshot_id)
                VALUES (?1, 'orphan fixture', '', ?2, 'Notes', 'ocr', ?3)
                """, bind: [rowID, old.timeIntervalSince1970, snapshotID])
            try database.runChecked("INSERT INTO ocr_metadata (rowid, snapshot_id, ts) VALUES (?1, ?2, ?3)",
                                    bind: [rowID, snapshotID, old.timeIntervalSince1970])
        }
        try database.execute("CREATE TABLE screen_embeddings (snapshot_id INTEGER PRIMARY KEY, ts REAL NOT NULL)")
        for snapshotID in [9_001, 9_002, 9_003] {
            try database.runChecked("INSERT INTO screen_embeddings (snapshot_id, ts) VALUES (?1, ?2)",
                                    bind: [snapshotID, old.timeIntervalSince1970])
        }
        let review = try store.orphanedScreenEvidence(olderThan: old.addingTimeInterval(1))
        XCTAssertEqual(review.text.count, 4)
        XCTAssertEqual(review.vectors.count, 3)

        let linkedID = try store.insertScreenshot(ts: old, path: "", app: "Notes", ocr: "")
        try database.runChecked("UPDATE ocr_fts SET snapshot_id = ?1 WHERE rowid = 501", bind: [linkedID])
        try database.runChecked("UPDATE ocr_metadata SET snapshot_id = ?1 WHERE rowid = 501", bind: [linkedID])
        try database.runChecked("INSERT INTO screenshots (id, ts, path, app) VALUES (9001, ?1, '', 'Notes')",
                                bind: [old.timeIntervalSince1970])
        try store.saveMoment(snapshotID: 9_001)
        try database.runChecked("UPDATE ocr_fts SET ts = ?1 WHERE rowid = 504",
                                bind: [old.addingTimeInterval(100).timeIntervalSince1970])
        try database.runChecked("UPDATE screen_embeddings SET ts = ?1 WHERE snapshot_id = 9003",
                                bind: [old.addingTimeInterval(100).timeIntervalSince1970])

        try store.clearOrphanedScreenEvidence(review)

        XCTAssertTrue(try database.hasRowChecked("SELECT 1 FROM ocr_fts WHERE rowid = 501"))
        XCTAssertTrue(try database.hasRowChecked("SELECT 1 FROM ocr_fts WHERE rowid = 502"))
        XCTAssertTrue(try database.hasRowChecked("SELECT 1 FROM ocr_fts WHERE rowid = 504"))
        XCTAssertFalse(try database.hasRowChecked("SELECT 1 FROM ocr_fts WHERE rowid = 503"))
        XCTAssertTrue(try database.hasRowChecked("SELECT 1 FROM ocr_metadata WHERE rowid = 501"))
        XCTAssertTrue(try database.hasRowChecked("SELECT 1 FROM ocr_metadata WHERE rowid = 502"))
        XCTAssertFalse(try database.hasRowChecked("SELECT 1 FROM ocr_metadata WHERE rowid = 503"))
        XCTAssertTrue(try database.hasRowChecked("SELECT 1 FROM screen_embeddings WHERE snapshot_id = 9001"))
        XCTAssertTrue(try database.hasRowChecked("SELECT 1 FROM screen_embeddings WHERE snapshot_id = 9003"))
        XCTAssertFalse(try database.hasRowChecked("SELECT 1 FROM screen_embeddings WHERE snapshot_id = 9002"))
    }
}

private final class ActivityResolverInvocationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var invocationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func recordInvocation() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}
