import XCTest
@testable import LokalBot

final class LibrarySearchPrefilterTests: XCTestCase {
    private var root: URL!
    private var previousStorageRoot: String?

    override func setUpWithError() throws {
        previousStorageRoot = ProcessInfo.processInfo.environment["LOKALBOT_STORAGE_ROOT"]
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("librarysearch-prefilter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("LOKALBOT_STORAGE_ROOT", root.path, 1)
    }

    override func tearDown() {
        if let previousStorageRoot {
            setenv("LOKALBOT_STORAGE_ROOT", previousStorageRoot, 1)
        } else {
            unsetenv("LOKALBOT_STORAGE_ROOT")
        }
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    func testMatchesTheOriginalSearchAcrossTrickyText() throws {
        try writeTrickyLibrary()
        let queries = [
            "izvestaj", "IZVEŠTAJ budzetu", "cafe", "CAFÉ", "café", "izmir", "strasse", "STRASSE", "finance",
            "kelvin", "οδος", "ΟΔΟΣ", "извештај", "буџету", "ǆemal", "nation",
            "api", "API limit", "ana", "q3", "rapid", "ban", "anan", "nan", "xpor", "ports", "50", "k",
            "\"pricing decision\"", "\"decision twice\"", "pricing decision", "\"decision on pricing\"",
            "\"path/to/file\"", "path to file", "\"tabs here\"", "\"double spaces\"", "newlines double",
            "\"e-mail\"", "e-mail", "2.0.1", "\"2.0.1\"", "\"...\"", "\"a\"", "\"ab\"",
            "\"said \"hi\"\"", "\"said \\\"hi\\\"\"", "users", "c:\\users", "\"c:\\users\"", "bell", "\"bell\u{7}char\"", "said hi",
            "line two", "\"one\ntwo\"",
            "对比度", "设置", "深色模式", "logo", "比如logo", "회의록", "공유", "かっこう", "がっこう", "日本語",
            "escaped", "izvestaj escaped", "utf16", "corrupt", "telescope checksum", "\"telescope checksum\"",
            "ιabc", "\u{345}abc", "abc",
            "the", "we", "roadmap item", "don't send", "?!", "a", "zzzzznotthere", "  spaced   out  ",
        ]
        var withHits = 0
        for query in queries {
            let found = try assertMatchesReference(query)
            if found { withHits += 1 }
        }
        XCTAssertGreaterThan(withHits, 60, "most queries should find something, or the comparison proves little")
    }

    func testRandomLibrariesMatchTheOriginalSearch() throws {
        var rng = SeededRandom(seed: 20_261_118)
        var texts: [String] = []
        var specs: [MeetingFixture.Spec] = []
        for index in 0..<10 {
            let lines = (0..<12).map { _ in RandomText.make(length: Int.random(in: 3...20, using: &rng), using: &rng) }
            texts += lines
            specs.append(.init(title: RandomText.make(length: 4, using: &rng),
                               startedAt: Date(timeIntervalSince1970: 1_790_000_000 + Double(index) * 3_600),
                               summary: index.isMultiple(of: 3) ? nil : RandomText.make(length: 30, using: &rng),
                               transcriptLines: index == 4 ? [] : lines))
        }
        try MeetingFixture.write(specs, under: root)

        var withHits = 0
        for _ in 0..<60 {
            let source = LibrarySearch.folded(texts[Int.random(in: 0..<texts.count, using: &rng)])
            let scalars = Array(source.unicodeScalars)
            guard !scalars.isEmpty else { continue }
            let start = Int.random(in: 0..<scalars.count, using: &rng)
            let end = min(scalars.count, start + Int.random(in: 1...10, using: &rng))
            var piece = String.UnicodeScalarView()
            piece.append(contentsOf: scalars[start..<end])
            let query = String(piece)
            if try assertMatchesReference(query) { withHits += 1 }
            _ = try assertMatchesReference("\"\(query)\"")
        }
        XCTAssertGreaterThan(withHits, 30)
    }

    func testPrefilterNeverMissesAMatchInRandomText() throws {
        var rng = SeededRandom(seed: 7)
        var checked = 0
        var skipped = 0
        for iteration in 0..<1_500 {
            let text = RandomText.make(length: Int.random(in: 1...24, using: &rng), using: &rng)
            let haystack = LibrarySearch.folded(text)
            let scalars = Array(haystack.unicodeScalars)
            var queries: [[String]] = []
            if !scalars.isEmpty {
                let start = Int.random(in: 0..<scalars.count, using: &rng)
                let end = min(scalars.count, start + Int.random(in: 1...8, using: &rng))
                var piece = String.UnicodeScalarView()
                piece.append(contentsOf: scalars[start..<end])
                queries.append(LibrarySearch.searchTerms(String(piece)))
                queries.append([LibrarySearch.folded(String(piece))].filter { !$0.isEmpty })
            }
            let other = LibrarySearch.folded(RandomText.make(length: 3, using: &rng))
            queries.append(LibrarySearch.searchTerms(other))
            for terms in queries where !terms.isEmpty {
                guard var prefilter = LibrarySearchPrefilter(terms: terms) else { continue }
                checked += 1
                let matches = terms.contains { haystack.range(of: $0) != nil }
                let mayMatch = prefilter.mayMatch(text)
                if !mayMatch { skipped += 1 }
                XCTAssertTrue(!matches || mayMatch, "missed \(terms) in \(Self.scalars(text))")
                if iteration.isMultiple(of: 5) {
                    let data = try Self.transcriptJSON(["first", text])
                    XCTAssertTrue(!matches || prefilter.mayMatch(transcriptJSON: data),
                                  "missed \(terms) in JSON for \(Self.scalars(text))")
                }
            }
        }
        XCTAssertGreaterThan(checked, 1_500)
        XCTAssertGreaterThan(skipped, 500, "the prefilter should rule out most unrelated text")
    }

    func testPrefilterReadsTranscriptJSONAndGivesUpOnWhatItCannotRead() throws {
        var telescope = try XCTUnwrap(LibrarySearchPrefilter(terms: ["telescope"]))
        XCTAssertFalse(telescope.mayMatch(transcriptJSON: try Self.transcriptJSON(["Budget review.", "Nothing else."])))
        XCTAssertTrue(telescope.mayMatch(transcriptJSON: try Self.transcriptJSON(["Budget.", "The TELESCOPE broke."])))
        XCTAssertFalse(telescope.mayMatch(transcriptJSON: Data(#"{"telescope": "x", "speaker": "telescope"}"#.utf8)),
                       "only text values count")
        XCTAssertTrue(telescope.mayMatch(transcriptJSON: Data(#"{"segments":[{"text":"tele\u0073cope"}]}"#.utf8)))
        let utf16 = try XCTUnwrap(String(decoding: try Self.transcriptJSON(["telescope"]), as: UTF8.self)
            .data(using: .utf16))
        XCTAssertTrue(telescope.mayMatch(transcriptJSON: utf16))
        XCTAssertTrue(telescope.mayMatch(transcriptJSON: Data([0x7B, 0x22, 0x74, 0x65, 0x78, 0x74, 0x22, 0x3A, 0x22,
                                                               0xC3, 0x28, 0x22, 0x7D])), "invalid UTF-8")

        var accented = try XCTUnwrap(LibrarySearchPrefilter(terms: ["izvestaj"]))
        XCTAssertTrue(accented.mayMatch(transcriptJSON: try Self.transcriptJSON(["Poslaću IZVEŠTAJ sutra."])))
        XCTAssertTrue(accented.mayMatch("izve\u{301}s\u{30C}taj"))
        XCTAssertFalse(accented.mayMatch("izvesti taj"))

        var phrase = try XCTUnwrap(LibrarySearchPrefilter(terms: ["decision on pricing"]))
        XCTAssertTrue(phrase.mayMatch("The decision, on\npricing."))
        XCTAssertFalse(phrase.mayMatch("The decision on prices."), "a phrase needs all of its words")

        var iota = try XCTUnwrap(LibrarySearchPrefilter(terms: ["ιabc"]))
        XCTAssertTrue(iota.mayMatch("\u{345}abc"), "U+0345 alone folds to ι")

        XCTAssertNil(LibrarySearchPrefilter(terms: ["..."]), "nothing to look for")
        XCTAssertNil(LibrarySearchPrefilter(terms: ["कि"]), "a vowel sign is a mark")
        var none = try XCTUnwrap(LibrarySearchPrefilter(terms: []))
        XCTAssertFalse(none.mayMatch("anything"))
    }

    func testFoldedSkipsCollapsingOnlyWhenNothingChanges() {
        for text in ["a b", "a  b", " a", "a ", "", " ", "a\u{A0}b", "a\tb", "a\nb", "a \u{301}b", "\u{600} x",
                     "x \u{600}y", "a \u{200D}b", "naïve CAFÉ", "日本 語", "a\u{3000}b", "a\u{1C}b", "e\u{301} x"] {
            XCTAssertEqual(Array(LibrarySearch.folded(text).unicodeScalars),
                           Array(ReferenceLibrarySearch.folded(text).unicodeScalars), Self.scalars(text))
        }
        var rng = SeededRandom(seed: 3)
        for _ in 0..<3_000 {
            let text = RandomText.make(length: Int.random(in: 0...14, using: &rng), using: &rng)
            XCTAssertEqual(Array(LibrarySearch.folded(text).unicodeScalars),
                           Array(ReferenceLibrarySearch.folded(text).unicodeScalars), Self.scalars(text))
        }
    }

    @discardableResult
    private func assertMatchesReference(_ query: String, file: StaticString = #filePath, line: UInt = #line) throws -> Bool {
        let calls: [(limit: Int, perMeeting: Int?, requireAll: Bool)] = [
            (LibrarySearch.defaultLimit, LibrarySearch.maximumTranscriptHitsPerMeeting, true),
            (3, LibrarySearch.maximumTranscriptHitsPerMeeting, true),
            (LibraryInputPolicy.maximumSearchHits, nil, false),
        ]
        var found = false
        for call in calls {
            let expected = try ReferenceLibrarySearch.hits(query: query, limit: call.limit,
                                                           transcriptHitsPerMeeting: call.perMeeting,
                                                           requireAllWords: call.requireAll)
            let actual = try LibrarySearch.hits(query: query, limit: call.limit,
                                                transcriptHitsPerMeeting: call.perMeeting,
                                                requireAllWords: call.requireAll)
            XCTAssertEqual(try Self.encoded(actual), try Self.encoded(expected),
                           "query \(Self.scalars(query)) limit \(call.limit)", file: file, line: line)
            if call.limit == LibrarySearch.defaultLimit { found = !expected.isEmpty }
        }
        return found
    }

    private func writeTrickyLibrary() throws {
        var roadmap: [String] = []
        for index in 0..<9 { roadmap.append("We talked about the roadmap, item \(index).") }
        let base = 1_790_000_000.0
        try MeetingFixture.write([
            .init(title: "Sastanak o budžetu", startedAt: Date(timeIntervalSince1970: base),
                  summary: "## TL;DR\nPoslaću IZVEŠTAJ o budžetu.",
                  transcriptLines: [
                      "Poslaću izveštaj o budžetu sutra.", "CAFÉ i café i cafe\u{301} su isto.",
                      "İzmir ofis, Straße, ﬁnance, \u{212A}elvin.", "ΟΔΟΣ και οδός.", "Извештај о буџету.",
                      "ǅemal and ŉation.",
                  ]),
            .init(title: "API review", startedAt: Date(timeIntervalSince1970: base - 3_600),
                  summary: "Rapid growth this quarter. " + String(repeating: "Filler. ", count: 20) + "The API limit stays.",
                  transcriptLines: [
                      "The API limit is 50 for q3.", "Rapid growth, banana exports.",
                      "We said \"pricing decision\" twice, then the decision on pricing.", "path/to/file and C:\\Users\\ana",
                      "tabs\there and\nnewlines  double  spaces", "Ana said \"hi\".", "e-mail and 2.0.1", "line one\nline two",
                      "one\ntwo", "bell\u{7}char", "...", "a", "ab",
                  ]),
            .init(title: "设计评审", startedAt: Date(timeIntervalSince1970: base - 7_200),
                  summary: "深色模式下设置页面的对比度",
                  transcriptLines: ["深色模式下设置页面的对比度不够。", "比如logo再大一点", "회의록을 공유했어요", "がっこう と かっこう",
                                    "日本語"]),
            .init(title: "Notes only", startedAt: Date(timeIntervalSince1970: base - 10_800),
                  summary: "Notes only: telescope checksum."),
            .init(title: "Long sync", startedAt: Date(timeIntervalSince1970: base - 14_400), transcriptLines: roadmap),
            .init(title: "Telescope", startedAt: Date(timeIntervalSince1970: base - 18_000),
                  transcriptLines: ["The telescope checksum failed.", "\u{345}abc", "ιabc"]),
        ], under: root)

        let escapedID = UUID()
        let utf16ID = UUID()
        let corruptID = UUID()
        try MeetingFixture.write([
            .init(id: escapedID, title: "Escaped", startedAt: Date(timeIntervalSince1970: base - 21_600)),
            .init(id: utf16ID, title: "Wide", startedAt: Date(timeIntervalSince1970: base - 25_200)),
            .init(id: corruptID, title: "Broken", startedAt: Date(timeIntervalSince1970: base - 28_800)),
        ], under: root)
        let escaped = #"{"engine":"x","segments":[{"start":1,"end":2,"speaker":"me","text":"caf\u00e9 and izve\u0161taj escaped"}]}"#
        try Data(escaped.utf8).write(to: transcriptURL(escapedID))
        let wide = try XCTUnwrap(String(decoding: try Self.transcriptJSON(["utf16 izveštaj"]), as: UTF8.self)
            .data(using: .utf16))
        try wide.write(to: transcriptURL(utf16ID))
        try Data(#"{"engine":"x","segments":[{"start":1,"end":2,"speaker":"me","text":"corrupt"#.utf8)
            .write(to: transcriptURL(corruptID))
    }

    private func transcriptURL(_ id: UUID) -> URL {
        root.appendingPathComponent("meetings/2026/07/\(SessionLookup.shortID(id))-fixture/transcript.json")
    }

    private static func transcriptJSON(_ lines: [String]) throws -> Data {
        let segments = lines.enumerated().map { index, line in
            Transcript.Segment(start: Double(index), end: Double(index) + 1, speaker: "me", text: line, confidence: nil)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(Transcript(segments: segments, engine: "test"))
    }

    private static func encoded(_ hits: [SessionFormatter.SearchHit]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(hits), as: UTF8.self)
    }

    private static func scalars(_ text: String) -> String {
        text.unicodeScalars.map { String($0.value, radix: 16) }.joined(separator: " ")
    }
}

private struct SeededRandom: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

private enum RandomText {
    static let pieces: [String] = {
        var pieces = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".map(String.init)
        pieces += [" ", " ", " ", "  ", ".", ",", "-", "'", "\"", "\\", "/", "\n", "\t", "\r\n", "?", "\u{1}", "\u{7F}",
                   "\u{85}", "\u{A0}", "\u{2028}", "\u{3000}", "\u{202F}", "\u{600}", "\u{200D}", "\u{FE0F}", "\u{345}"]
        let ranges: [ClosedRange<UInt32>] = [
            0x00C0...0x017F, 0x01C4...0x01CC, 0x0300...0x0345, 0x0386...0x03CE, 0x0400...0x045F, 0x1E9E...0x1E9E,
            0x1F00...0x1F20, 0x1F80...0x1F88, 0x2000...0x200D, 0x212A...0x212B, 0x3041...0x3096, 0x3099...0x309C,
            0x30A1...0x30C0, 0x1100...0x1112, 0x1161...0x1175, 0xAC00...0xAC10, 0x4E00...0x4E20, 0xF900...0xF905,
            0xFB00...0xFB06, 0xFF21...0xFF3A, 0xFF66...0xFF9F, 0x0905...0x0915, 0x093E...0x094D, 0x1F600...0x1F605,
            0x1D400...0x1D405, 0x10400...0x10410,
        ]
        for range in ranges {
            for value in range {
                if let scalar = Unicode.Scalar(value) { pieces.append(String(scalar)) }
            }
        }
        pieces += ["izveštaj", "café", "cafe\u{301}", "İzmir", "straße", "ﬁnance", "深色模式", "회의록", "извештај", "ΟΔΟΣ",
                   "ǅemal", "ŉation", "がっこう", "か\u{3099}"]
        return pieces
    }()

    static func make(length: Int, using rng: inout SeededRandom) -> String {
        var text = ""
        for _ in 0..<length { text += pieces[Int.random(in: 0..<pieces.count, using: &rng)] }
        return text
    }
}

private enum ReferenceLibrarySearch {
    private struct Candidate {
        var hit: SessionFormatter.SearchHit
        var meeting: Int
        var kind: Int
        var position: Int
        var matched: [String]
        var exact: Bool
    }

    static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func hits(
        query: String,
        limit: Int,
        meetings: [Meeting]? = nil,
        transcriptHitsPerMeeting: Int?,
        requireAllWords: Bool
    ) throws -> [SessionFormatter.SearchHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let quoted = trimmed.count > 2 && trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"")
        let phrase = folded(quoted ? String(trimmed.dropFirst().dropLast()) : trimmed)
        guard !phrase.isEmpty else { return [] }
        let terms = quoted ? [phrase] : LibrarySearch.searchTerms(phrase)
        let all = try meetings ?? SessionLookup.loadAllMeetings()

        var candidates: [Candidate] = []
        var coverage: [Int: Set<String>] = [:]
        func consider(_ text: String, meeting index: Int, kind: Int, position: Int,
                      hit: (String) -> SessionFormatter.SearchHit?) {
            let haystack = folded(text)
            let matched = terms.filter { LibrarySearch.wordRange(of: $0, in: haystack) != nil }
            guard let first = matched.first else { return }
            let exact = haystack.contains(phrase)
            guard let value = (exact ? hit(phrase) : nil) ?? hit(first) else { return }
            coverage[index, default: []].formUnion(matched)
            candidates.append(Candidate(hit: value, meeting: index, kind: kind, position: position,
                                        matched: matched, exact: exact))
        }

        for (index, meeting) in all.enumerated() {
            let short = SessionLookup.shortID(meeting.id)
            let sample: Bool? = meeting.isSample ? true : nil
            consider(meeting.title, meeting: index, kind: 0, position: 0) { _ in
                .init(meeting_id: short, meeting_title: meeting.title, match_kind: "title",
                      snippet: meeting.title, timestamp: nil, sample: sample)
            }
            if let summary = SessionLookup.summaryMarkdown(for: meeting) {
                consider(summary, meeting: index, kind: 1, position: 0) { needle in
                    LibrarySearch.snippet(in: summary, around: needle).map {
                        .init(meeting_id: short, meeting_title: meeting.title, match_kind: "summary",
                              snippet: $0, timestamp: nil, sample: sample)
                    }
                }
            }
            if let transcript = SessionLookup.transcript(for: meeting) {
                for (position, segment) in transcript.segments.enumerated() {
                    consider(segment.text, meeting: index, kind: 2, position: position) { _ in
                        .init(meeting_id: short, meeting_title: meeting.title, match_kind: "transcript",
                              snippet: segment.text, timestamp: Transcript.stamp(segment.start),
                              sample: sample)
                    }
                }
            }
        }

        var meetingsWithTerm: [String: Int] = [:]
        for words in coverage.values { for word in words { meetingsWithTerm[word, default: 0] += 1 } }
        let total = Double(max(1, all.count))
        func weight(_ words: [String]) -> Double {
            var sum = 0.0
            for word in words {
                let meetingsWithWord = Double(max(1, meetingsWithTerm[word] ?? 1))
                sum += log(1 + total / meetingsWithWord)
            }
            return sum
        }
        var meetingWeights: [Int: Double] = [:]
        for (meeting, words) in coverage { meetingWeights[meeting] = weight(Array(words)) }

        let complete = requireAllWords ? Set(coverage.filter { $0.value.count == terms.count }.keys) : []
        var ranked: [(candidate: Candidate, score: Double)] = []
        for candidate in candidates where complete.isEmpty || complete.contains(candidate.meeting) {
            ranked.append((candidate, weight(candidate.matched)))
        }
        ranked.sort { lhs, rhs in
            if lhs.candidate.exact != rhs.candidate.exact { return lhs.candidate.exact }
            let left = meetingWeights[lhs.candidate.meeting] ?? 0
            let right = meetingWeights[rhs.candidate.meeting] ?? 0
            if left != right { return left > right }
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.candidate.meeting != rhs.candidate.meeting { return lhs.candidate.meeting < rhs.candidate.meeting }
            if lhs.candidate.kind != rhs.candidate.kind { return lhs.candidate.kind < rhs.candidate.kind }
            return lhs.candidate.position < rhs.candidate.position
        }

        var transcriptHits: [Int: Int] = [:]
        var hits: [SessionFormatter.SearchHit] = []
        for (candidate, _) in ranked where hits.count < limit {
            if candidate.kind == 2, let transcriptHitsPerMeeting {
                let count = transcriptHits[candidate.meeting, default: 0]
                guard count < transcriptHitsPerMeeting else { continue }
                transcriptHits[candidate.meeting] = count + 1
            }
            hits.append(candidate.hit)
        }
        return hits
    }
}
