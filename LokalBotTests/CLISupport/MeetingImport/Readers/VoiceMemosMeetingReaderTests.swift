import SQLite3
import XCTest
@testable import LokalBot

final class VoiceMemosMeetingReaderTests: XCTestCase {
    private let reader = VoiceMemosMeetingReader.self

    private func temporaryDirectory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // MARK: The library folder

    func testLibraryFolderRoundTrip() throws {
        let folder = try VoiceMemoFixture.libraryFolder(in: temporaryDirectory("vm-library"))

        let scan = try reader.read(folder)

        XCTAssertEqual(scan.meetings.count, 3)
        let pricing = try XCTUnwrap(scan.meetings.first { $0.sourceID == VoiceMemoFixture.pricingID })
        XCTAssertEqual(pricing.source, .voiceMemos)
        XCTAssertEqual(pricing.title, "Pricing call with Ana", "ZENCRYPTEDTITLE wins over a date-shaped label")
        XCTAssertEqual(pricing.startedAt, Date(timeIntervalSinceReferenceDate: VoiceMemoFixture.pricingDate))
        XCTAssertEqual(pricing.duration, 42.5)
        XCTAssertEqual(pricing.lines, VoiceMemoFixture.pricingLines)
        XCTAssertTrue(pricing.lines.allSatisfy { $0.speaker == nil && !$0.isMe }, "Voice Memos names no speakers")
        XCTAssertTrue(pricing.participants.isEmpty)
        XCTAssertNil(pricing.notes)
        XCTAssertTrue(pricing.actionItems.isEmpty)
        XCTAssertEqual(pricing.audioURL, folder.appendingPathComponent("20260304 101500-1B4E28BA.m4a").standardizedFileURL)
        XCTAssertEqual(pricing.origin, pricing.audioURL)

        let standup = try XCTUnwrap(scan.meetings.first { $0.sourceID == VoiceMemoFixture.standupID })
        XCTAssertEqual(standup.title, "Standup notes", "an older row's title is its ZCUSTOMLABEL")
        XCTAssertEqual(standup.startedAt, Date(timeIntervalSinceReferenceDate: VoiceMemoFixture.standupDate))
        XCTAssertTrue(standup.lines.isEmpty, "no transcript, so LokalBot transcribes it")
        XCTAssertEqual(standup.audioURL?.lastPathComponent, "20260305 090000-2C5F39CB.m4a",
                       "an absolute ZPATH is found by its name in the folder")

        // Its row is still only in the write-ahead log, which an immutable
        // read skips, so it comes from the file.
        let unlisted = try XCTUnwrap(scan.meetings.first { $0.sourceID == VoiceMemoFixture.unlistedID })
        XCTAssertEqual(unlisted.title, VoiceMemosMeetingReader.untitled)
        XCTAssertEqual(unlisted.startedAt, VoiceMemoFixture.localDate(2026, 3, 7, 8, 15, 0), "the file name is the local start")
        XCTAssertEqual(unlisted.duration, 2.5)
        XCTAssertEqual(unlisted.lines, [.init(start: 0, end: 2.5, text: "Call Leo about the invoice.")])

        XCTAssertFalse(scan.meetings.contains { $0.audioURL?.lastPathComponent.hasPrefix("20260306") == true },
                       "a recording in Recently Deleted stays out, also as a loose file")
        XCTAssertEqual(scan.problems.count, 1)
        let problem = try XCTUnwrap(scan.problems.first)
        XCTAssertEqual(URL(fileURLWithPath: problem.path).resolvingSymlinksInPath(), folder.resolvingSymlinksInPath())
        XCTAssertTrue(problem.reason.hasPrefix("1 recording isn't on this Mac"), problem.reason)
        XCTAssertFalse(problem.reason.contains("Only in iCloud"), "a reason never quotes a title")
    }

    func testReadingTheLibraryChangesNothing() throws {
        let folder = try VoiceMemoFixture.libraryFolder(in: temporaryDirectory("vm-readonly"))
        let database = folder.appendingPathComponent(VoiceMemosMeetingReader.databaseName)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        let databaseBytes = try Data(contentsOf: database)
        let logBytes = try Data(contentsOf: folder.appendingPathComponent("CloudRecordings.db-wal"))

        _ = try reader.read(folder)
        _ = try reader.read(database)

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted(), names,
                       "no -shm or other file appears")
        XCTAssertEqual(try Data(contentsOf: database), databaseBytes)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("CloudRecordings.db-wal")), logBytes)
    }

    func testTheDatabaseChosenOnItsOwnReadsItsRows() throws {
        let folder = try VoiceMemoFixture.libraryFolder(in: temporaryDirectory("vm-database"))
        let scan = try reader.read(folder.appendingPathComponent(VoiceMemosMeetingReader.databaseName))
        XCTAssertEqual(Set(scan.meetings.map(\.sourceID)), [VoiceMemoFixture.pricingID, VoiceMemoFixture.standupID])
    }

    // MARK: Files dragged out of Voice Memos

    func testDraggedOutCopyIsTheSameMeetingAsItsLibraryRow() throws {
        let root = try temporaryDirectory("vm-copy")
        let folder = try VoiceMemoFixture.libraryFolder(in: root)
        let copy = root.appendingPathComponent("Pricing call with Ana.m4a")
        try VoiceMemoFixture.Recording(
            created: Date(timeIntervalSinceReferenceDate: VoiceMemoFixture.pricingDate + 42.5),
            memoID: VoiceMemoFixture.pricingID.lowercased(), transcript: VoiceMemoFixture.pricingTranscript)
            .data().write(to: copy)

        let dragged = try XCTUnwrap(reader.read(copy).meetings.first)

        XCTAssertEqual(dragged.sourceID, VoiceMemoFixture.pricingID, "voice-memo-uuid is the row's ZUNIQUEID")
        XCTAssertEqual(dragged.title, "Pricing call with Ana", "Voice Memos names the copy after the title")
        // mvhd marks the end in whole seconds; the start is the end minus the length.
        let start = try XCTUnwrap(dragged.startedAt)
        XCTAssertEqual(start.timeIntervalSinceReferenceDate, VoiceMemoFixture.pricingDate, accuracy: 1)
        XCTAssertEqual(dragged.lines, VoiceMemoFixture.pricingLines)
        XCTAssertEqual(dragged.audioURL, copy)

        let both = ExternalMeetingReaders.scan(.voiceMemos, urls: [folder, copy])
        both.cleanup()
        XCTAssertEqual(both.scan.meetings.count, 3, "the copy and its row are one meeting")
    }

    func testQuickTimeAudioWithMetadataKeysAndLongSizes() throws {
        let file = try temporaryDirectory("vm-qta").appendingPathComponent("Layered idea.qta")
        try VoiceMemoFixture.Recording(
            duration: 12, created: Date(timeIntervalSince1970: 1_772_998_000), encoder: nil,
            transcript: VoiceMemoFixture.errandTranscript, quickTime: true,
            quickTimeItems: [("com.apple.quicktime.title", "Chorus idea"),
                             ("com.apple.quicktime.creationdate", "2026-03-08T21:30:00+0100")],
            movieLast: false, extendedMediaData: true)
            .data().write(to: file)

        XCTAssertTrue(reader.recognizes(file))
        let meeting = try XCTUnwrap(reader.read(file).meetings.first)
        XCTAssertEqual(meeting.title, "Chorus idea")
        XCTAssertEqual(meeting.startedAt, ExternalImportText.date("2026-03-08T20:30:00Z"),
                       "the creation date's offset has no colon")
        XCTAssertEqual(meeting.duration, 12)
        XCTAssertEqual(meeting.lines, [.init(start: 0, end: 2.5, text: "Call Leo about the invoice.")],
                       "a .qta keeps its transcript under com.apple.VoiceMemos.tsrp")
        XCTAssertEqual(meeting.audioURL, file)
    }

    func testAnIPhoneCopyStartsAtItsDateTag() throws {
        let file = try temporaryDirectory("vm-date").appendingPathComponent("Lecture.m4a")
        try VoiceMemoFixture.Recording(
            duration: 600, created: Date(timeIntervalSince1970: 1_749_373_000), title: "2025-06-08",
            encoder: "com.apple.VoiceMemos (iPhone Version 18.5 (Build 22F76))", dateTag: "2025-06-08T08:46:16Z")
            .data().write(to: file)

        let meeting = try XCTUnwrap(reader.read(file).meetings.first)

        XCTAssertEqual(meeting.startedAt, ExternalImportText.date("2025-06-08T08:46:16Z"),
                       "the date tag wins over the header's end minus length")
        XCTAssertEqual(meeting.title, "2025-06-08", "a title that is only a day is still a title")
        XCTAssertEqual(meeting.duration, 600)
    }

    func testSourceIDsAreStableAcrossReads() throws {
        let root = try temporaryDirectory("vm-stable")
        let folder = try VoiceMemoFixture.libraryFolder(in: root)
        let plain = root.appendingPathComponent("Errand.m4a")
        try VoiceMemoFixture.Recording(created: Date(timeIntervalSince1970: 1_772_998_000), memoID: nil)
            .data().write(to: plain)

        let first = try reader.read(folder).meetings.map(\.sourceID).sorted()
        let second = try reader.read(folder).meetings.map(\.sourceID).sorted()
        XCTAssertEqual(first, second)
        let plainID = try XCTUnwrap(reader.read(plain).meetings.first?.sourceID)
        XCTAssertEqual(plainID.count, 32, "a file without an id gets a hashed one")
        XCTAssertEqual(try reader.read(plain).meetings.first?.sourceID, plainID)
    }

    // MARK: Recognizing files

    func testRecognizesVoiceMemosFilesByNameAndHeader() throws {
        let root = try temporaryDirectory("vm-recognize")
        func write(_ name: String, _ data: Data) throws -> URL {
            let url = root.appendingPathComponent(name)
            try data.write(to: url)
            return url
        }
        XCTAssertTrue(reader.recognizes(try write("Memo.m4a", VoiceMemoFixture.Recording().data())))
        XCTAssertTrue(reader.recognizes(try write("CloudRecordings.db", Data("SQLite format 3\0".utf8))))
        XCTAssertTrue(reader.recognizes(try write("Pending.m4a", Data())), "an empty file is an iCloud-only recording")
        XCTAssertFalse(reader.recognizes(try write("notes.txt", Data("hello".utf8))))
        XCTAssertFalse(reader.recognizes(try write("song.m4a", Data("hello world, not audio".utf8))))
        XCTAssertFalse(reader.recognizes(try write("clip.wav", Data("RIFF0000WAVE".utf8))))
        XCTAssertFalse(reader.recognizes(try write("CloudRecordings.db-wal", Data("x".utf8))))
    }

    // MARK: Problems

    func testFolderWithUnreadableFilesKeepsReadingTheRest() throws {
        let root = try temporaryDirectory("vm-problems")
        try VoiceMemoFixture.Recording(title: "Good one", memoID: "6A9D7D0F-8E07-47C8-9D94-5561B8BBF97C",
                                       transcript: VoiceMemoFixture.errandTranscript)
            .data().write(to: root.appendingPathComponent("Good.m4a"))
        let ftyp = VoiceMemoFixture.box("ftyp", Data("M4A ".utf8) + VoiceMemoFixture.be32(0) + Data("M4A isommp42".utf8))
        let broken = root.appendingPathComponent("Broken.m4a")
        try (ftyp + VoiceMemoFixture.be32(1_000_000) + Data("mdat".utf8) + Data("Call Leo secret words".utf8)).write(to: broken)
        try ftyp.write(to: root.appendingPathComponent("Header only.m4a"))
        try Data().write(to: root.appendingPathComponent("Pending.m4a"))
        try Data("these are notes, not a database".utf8).write(to: root.appendingPathComponent("CloudRecordings.db"))
        try Data("unrelated".utf8).write(to: root.appendingPathComponent("readme.txt"))

        let scan = try reader.read(root)

        XCTAssertEqual(scan.meetings.map(\.title), ["Good one"])
        let problems = Dictionary(uniqueKeysWithValues: scan.problems.map {
            (URL(fileURLWithPath: $0.path).lastPathComponent, $0.reason)
        })
        XCTAssertEqual(Set(problems.keys), ["Broken.m4a", "Header only.m4a", "Pending.m4a", "CloudRecordings.db"])
        XCTAssertEqual(problems["Broken.m4a"], "the file is damaged or cut short")
        XCTAssertEqual(problems["CloudRecordings.db"], "it isn't a database")
        XCTAssertFalse(scan.problems.contains { $0.reason.contains("secret") || $0.reason.contains("notes") },
                       "reasons never quote what a file holds")
        XCTAssertThrowsError(try reader.read(broken), "a single unreadable file throws")
    }

    func testAFileMacOSWontLetUsOpenIsAProblemNotASkip() throws {
        let root = try temporaryDirectory("vm-permission")
        try VoiceMemoFixture.Recording(title: "Readable").data().write(to: root.appendingPathComponent("Readable.m4a"))
        let locked = root.appendingPathComponent("Locked.m4a")
        try VoiceMemoFixture.Recording(title: "Locked").data().write(to: locked)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }

        let scan = try reader.read(root)

        XCTAssertEqual(scan.meetings.map(\.title), ["Readable"])
        XCTAssertEqual(scan.problems.map { URL(fileURLWithPath: $0.path).lastPathComponent }, ["Locked.m4a"])
        XCTAssertTrue(scan.problems.first?.reason.contains("Full Disk Access") == true)
    }

    func testAFolderWithNothingToReadThrows() throws {
        let root = try temporaryDirectory("vm-nothing")
        try Data("unrelated".utf8).write(to: root.appendingPathComponent("readme.txt"))
        XCTAssertThrowsError(try reader.read(root))
    }

    // MARK: Older libraries

    func testOlderLibraryTakesItsTitleFromTheCompositionManifest() throws {
        let root = try temporaryDirectory("vm-composition")
        try VoiceMemoFixture.Recording(encoder: nil).data().write(to: root.appendingPathComponent("20190101 120000.m4a"))
        let composition = root.appendingPathComponent("20190101 120000.composition", isDirectory: true)
        try FileManager.default.createDirectory(at: composition, withIntermediateDirectories: true)
        try VoiceMemoFixture.Recording().data().write(to: composition.appendingPathComponent("fragment-1.m4a"))
        let manifest: [String: Any] = [
            "RCSavedRecordingTitle": "Kitchen plans",
            "RCSavedRecordingCreationDate": Date(timeIntervalSince1970: 1_546_340_400),
            "RCSavedRecordingUUID": "7BAE8E10-9F18-48D9-AEA5-6672C9CC0A8D",
        ]
        try PropertyListSerialization.data(fromPropertyList: manifest, format: .binary, options: 0)
            .write(to: composition.appendingPathComponent("manifest.plist"))

        let scan = try reader.read(root)

        XCTAssertEqual(scan.meetings.count, 1, "a composition's fragments aren't recordings of their own")
        XCTAssertEqual(scan.meetings.first?.title, "Kitchen plans")
        XCTAssertEqual(scan.meetings.first?.startedAt, Date(timeIntervalSince1970: 1_546_340_400))
        XCTAssertEqual(scan.meetings.first?.sourceID, "7BAE8E10-9F18-48D9-AEA5-6672C9CC0A8D")
    }

    // MARK: Transcripts

    func testTranscriptCodingsAndDamage() {
        func lines(_ json: String) -> [ExternalMeeting.Line] { reader.transcriptLines(from: Data(json.utf8)) }
        XCTAssertEqual(lines(#"{"attributedString":"","locale":{"identifier":"en_US","current":0}}"#), [],
                       "a recording with no speech has an empty string")
        XCTAssertEqual(lines("not json"), [])
        XCTAssertEqual(lines(#"{"attributedString":"Hello there."}"#), [.init(text: "Hello there.")])
        XCTAssertEqual(lines(#"{"attributedString":{"runs":["Hi",0," again",7],"attributeTable":[{"timeRange":[1,2]}]}}"#),
                       [.init(start: 1, end: 2, text: "Hi again")], "an index past the table leaves the run untimed")
        XCTAssertEqual(lines(#"{"attributedString":["Back",{"timeRange":[3,2]}," later",{"timeRange":[-1,4]}]}"#),
                       [.init(text: "Back later")], "a range that runs backwards or before zero is no time")

        let wrapped = VoiceMemoFixture.be32(1) + VoiceMemoFixture.be32(0) + Data(VoiceMemoFixture.errandTranscript.utf8)
            + Data([0, 0, 0])
        XCTAssertEqual(reader.transcriptLines(from: wrapped).count, 1, "a data header and zero padding are skipped")

        var runs: [String] = []
        var table: [String] = []
        for index in 0..<40 {
            runs.append("\" word\",\(index)")
            table.append("{\"timeRange\":[\(Double(index)),\(Double(index) + 1)]}")
        }
        let long = lines("{\"attributedString\":{\"runs\":[\(runs.joined(separator: ","))],"
            + "\"attributeTable\":[\(table.joined(separator: ","))]}}")
        XCTAssertEqual(long.map(\.start), [0, 30], "speech without a pause or a sentence end still breaks")
        XCTAssertEqual(long.map(\.end), [30, 40])
    }

    // MARK: Archives

    func testZippedCopiesGoThroughTheSharedScan() throws {
        let root = try temporaryDirectory("vm-zip")
        let content = root.appendingPathComponent("Memos", isDirectory: true)
        try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
        try VoiceMemoFixture.Recording(memoID: VoiceMemoFixture.unlistedID, transcript: VoiceMemoFixture.errandTranscript)
            .data().write(to: content.appendingPathComponent("Errand.m4a"))
        let zip = root.appendingPathComponent("Memos.zip")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--sequesterRsrc", content.path, zip.path]
        try ditto.run()
        ditto.waitUntilExit()

        let result = ExternalMeetingReaders.scan(.voiceMemos, urls: [zip])

        XCTAssertEqual(result.scan.problems, [])
        let audio = try XCTUnwrap(result.scan.meetings.first?.audioURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
        result.cleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
    }

    func testHintAndDefaultLocation() {
        XCTAssertTrue(reader.exportHint.contains("drag recordings to a Finder window"))
        XCTAssertEqual(reader.defaultLocations, ["~/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings"])
    }
}

// MARK: - Synthetic fixtures

/// Builds Voice Memos-shaped files from scratch: MPEG-4 and QuickTime atoms
/// and a Core Data-shaped SQLite library. Every value is made up.
private enum VoiceMemoFixture {
    struct SQLiteFailure: Error {}

    static func be32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
    static func be64(_ value: UInt64) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }

    static func box(_ type: String, _ payload: Data) -> Data {
        box(code: Data(type.utf8), payload)
    }

    static func box(code: Data, _ payload: Data) -> Data {
        be32(UInt32(8 + payload.count)) + code + payload
    }

    /// A box with a 64-bit size, as a long recording's `mdat` has.
    static func extendedBox(_ type: String, _ payload: Data) -> Data {
        be32(1) + Data(type.utf8) + be64(UInt64(16 + payload.count)) + payload
    }

    static func dataAtom(_ value: Data) -> Data { box("data", be32(1) + be32(0) + value) }

    static func iTunesItem(_ code: [UInt8], _ value: String) -> Data {
        box(code: Data(code), dataAtom(Data(value.utf8)))
    }

    static func freeform(_ name: String, _ value: String) -> Data {
        box("----", box("mean", be32(0) + Data("com.apple.iTunes".utf8)) + box("name", be32(0) + Data(name.utf8))
            + dataAtom(Data(value.utf8)))
    }

    /// QuickTime metadata: names in `keys`, values in `ilst` items typed by index.
    static func quickTimeMeta(_ items: [(String, Data)]) -> Data {
        var keys = be32(0) + be32(UInt32(items.count))
        var list = Data()
        for (index, item) in items.enumerated() {
            keys += be32(UInt32(8 + item.0.utf8.count)) + Data("mdta".utf8) + Data(item.0.utf8)
            list += box(code: be32(UInt32(index + 1)), dataAtom(item.1))
        }
        return box("meta", box("hdlr", Data(count: 25)) + box("keys", keys) + box("ilst", list))
    }

    static func movieHeader(created: Date?, duration: TimeInterval) -> Data {
        let stamp = created.map { UInt32($0.timeIntervalSince1970 + 2_082_844_800) } ?? 0
        return box("mvhd", be32(0) + be32(stamp) + be32(stamp) + be32(48_000) + be32(UInt32(duration * 48_000))
            + Data(count: 80))
    }

    struct Recording {
        var duration: TimeInterval = 42.5
        var created: Date?
        var title: String?
        var encoder: String? = "com.apple.VoiceMemos (Mac Version 26.1 (Build 25B78))"
        var memoID: String?
        var dateTag: String?
        var transcript: String?
        /// `trak/mdia/udta` instead of `trak/udta`.
        var transcriptInMedia = false
        /// A `.qta`: QuickTime brand, the transcript in `trak/meta`.
        var quickTime = false
        var quickTimeItems: [(String, String)] = []
        /// `ftyp`, `mdat`, `moov`, as Voice Memos writes; else `moov` first.
        var movieLast = true
        var extendedMediaData = false

        func data() -> Data {
            let brand = quickTime ? Data("qt  ".utf8) + be32(0) + Data("qt  ".utf8)
                : Data("M4A ".utf8) + be32(0) + Data("M4A isommp42".utf8)
            var media = box("mdhd", Data(count: 24))
            var trackUserData = Data()
            if let transcript, !quickTime {
                let userData = box("udta", box("tsrp", Data(transcript.utf8)))
                if transcriptInMedia { media += userData } else { trackUserData = userData }
            }
            var track = box("tkhd", Data(count: 84)) + box("mdia", media) + trackUserData
            if let transcript, quickTime {
                track += quickTimeMeta([("com.apple.VoiceMemos.tsrp", Data(transcript.utf8))])
            }
            var items = Data()
            if let title { items += iTunesItem([0xA9, 0x6E, 0x61, 0x6D], title) }
            if let encoder { items += iTunesItem([0xA9, 0x74, 0x6F, 0x6F], encoder) }
            if let memoID { items += freeform("voice-memo-uuid", memoID) }
            var userData = Data()
            if let dateTag { userData += box("date", Data(dateTag.utf8)) }
            if !items.isEmpty {
                userData += box("meta", be32(0) + box("hdlr", Data(count: 25)) + box("ilst", items))
            }
            var movie = movieHeader(created: created, duration: duration) + box("trak", track)
            if !userData.isEmpty { movie += box("udta", userData) }
            if !quickTimeItems.isEmpty { movie += quickTimeMeta(quickTimeItems.map { ($0.0, Data($0.1.utf8)) }) }
            let ftyp = box("ftyp", brand)
            let moov = box("moov", movie)
            let audio = Data(repeating: 0x21, count: 512)
            let mdat = extendedMediaData ? extendedBox("mdat", audio) : box("mdat", audio)
            return movieLast ? ftyp + mdat + moov : ftyp + moov + mdat
        }
    }

    struct Row {
        var uniqueID: String?
        var title: String?
        var label: String?
        var date: Double?
        var duration: Double?
        var path: String?
        var evicted: Double?
    }

    /// A library database shaped like Voice Memos' Core Data store, in WAL
    /// mode as the real one is.
    static func library(at url: URL, rows: [Row]) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK else { throw SQLiteFailure() }
        defer { sqlite3_close(handle) }
        func sql(_ value: String?) -> String { value.map { "'" + $0.replacingOccurrences(of: "'", with: "''") + "'" } ?? "NULL" }
        func sql(_ value: Double?) -> String { value.map { String($0) } ?? "NULL" }
        var script = """
            PRAGMA journal_mode=WAL;
            CREATE TABLE ZCLOUDRECORDING (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZFOLDER INTEGER,
              ZDATE TIMESTAMP, ZDURATION FLOAT, ZEVICTIONDATE TIMESTAMP, ZCUSTOMLABEL VARCHAR,
              ZCUSTOMLABELFORSORTING VARCHAR, ZENCRYPTEDTITLE VARCHAR, ZPATH VARCHAR, ZUNIQUEID VARCHAR);
            CREATE TABLE ZFOLDER (Z_PK INTEGER PRIMARY KEY, ZENCRYPTEDNAME VARCHAR, ZRANK INTEGER);
            """
        for (index, row) in rows.enumerated() {
            script += """
                INSERT INTO ZCLOUDRECORDING (Z_PK, Z_ENT, Z_OPT, ZDATE, ZDURATION, ZEVICTIONDATE, ZCUSTOMLABEL,
                  ZENCRYPTEDTITLE, ZPATH, ZUNIQUEID) VALUES (\(index + 1), 1, 1, \(sql(row.date)), \(sql(row.duration)),
                  \(sql(row.evicted)), \(sql(row.label)), \(sql(row.title)), \(sql(row.path)), \(sql(row.uniqueID)));
                """
        }
        guard sqlite3_exec(handle, script, nil, nil, nil) == SQLITE_OK else { throw SQLiteFailure() }
    }

    static let pricingID = "1B4E28BA-2FA1-11D2-883F-0016D3CCA427"
    static let standupID = "2C5F39CB-3FB2-42E3-994F-1127E4DDB538"
    static let unlistedID = "4E7B5BED-5BD4-44F5-BB61-3349F6FFD75A"
    static let pricingDate = 794_312_100.0
    static let standupDate = 794_394_000.0

    /// The separated coding: runs index an attribute table. The comma has an
    /// attribute without a time, and a pause starts the last line.
    static let pricingTranscript = """
        {"attributedString":{"runs":["Let's",0," keep",1," the",2," Team",3," plan.",4," Fifteen",5," per",6,\
        " seat",7,",",8," billed",9," annually.",10," Agreed.",11],"attributeTable":[{"timeRange":[0.5,0.9]},\
        {"timeRange":[0.9,1.4]},{"timeRange":[1.4,1.6]},{"timeRange":[1.6,3.0]},{"timeRange":[3.0,4.6]},\
        {"timeRange":[4.7,5.3]},{"timeRange":[5.3,5.6]},{"timeRange":[5.6,6.0]},{},{"timeRange":[6.1,6.6]},\
        {"timeRange":[6.6,7.4]},{"timeRange":[12.0,12.6]}]},"locale":{"identifier":"en_US","current":0}}
        """

    /// The interleaved coding: each run followed by its attributes.
    static let errandTranscript = """
        {"attributedString":["Call Leo",{"timeRange":[0,1.2]}," about the invoice.",{"timeRange":[1.2,2.5]}],\
        "locale":{"identifier":"en_GB","current":0}}
        """

    static let pricingLines: [ExternalMeeting.Line] = [
        .init(start: 0.5, end: 4.6, text: "Let's keep the Team plan."),
        .init(start: 4.7, end: 7.4, text: "Fifteen per seat, billed annually."),
        .init(start: 12.0, end: 12.6, text: "Agreed."),
    ]

    /// A `Recordings` folder: a database with a titled recording, an older
    /// one titled by its label under an absolute path, one in Recently
    /// Deleted, and one only in iCloud; a recording whose row is still only in
    /// the write-ahead log; and that log, which an immutable read ignores.
    static func libraryFolder(in root: URL) throws -> URL {
        let folder = root.appendingPathComponent("Group Containers/group.test/Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Recording(created: Date(timeIntervalSinceReferenceDate: pricingDate + 43), memoID: pricingID,
                      transcript: pricingTranscript)
            .data().write(to: folder.appendingPathComponent("20260304 101500-1B4E28BA.m4a"))
        try Recording(duration: 300, memoID: standupID)
            .data().write(to: folder.appendingPathComponent("20260305 090000-2C5F39CB.m4a"))
        try Recording(memoID: "3D6A4ADC-6CE5-45A6-AA72-2238A5EEC649")
            .data().write(to: folder.appendingPathComponent("20260306 120000-3D6A4ADC.m4a"))
        try Recording(duration: 2.5, memoID: unlistedID.lowercased(), transcript: errandTranscript, transcriptInMedia: true)
            .data().write(to: folder.appendingPathComponent("20260307 081500-4E7B5BED.m4a"))
        try Data("not a real log".utf8).write(to: folder.appendingPathComponent("CloudRecordings.db-wal"))
        try library(at: folder.appendingPathComponent(VoiceMemosMeetingReader.databaseName), rows: [
            Row(uniqueID: pricingID, title: "Pricing call with Ana", label: "2026-03-04T10:15:00Z", date: pricingDate,
                duration: 42.5, path: "20260304 101500-1B4E28BA.m4a"),
            Row(uniqueID: standupID, label: "Standup notes", date: standupDate, duration: 300,
                path: "/Users/someone/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings/20260305 090000-2C5F39CB.m4a"),
            Row(uniqueID: "3D6A4ADC-6CE5-45A6-AA72-2238A5EEC649", title: "Deleted idea", date: standupDate + 100,
                duration: 10, path: "20260306 120000-3D6A4ADC.m4a", evicted: standupDate + 200),
            Row(uniqueID: "5F8C6CFE-7DF6-46B7-8C83-4450A7AAE86B", title: "Only in iCloud", date: standupDate + 300,
                duration: 60),
        ])
        return folder
    }

    static func localDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))
    }
}
