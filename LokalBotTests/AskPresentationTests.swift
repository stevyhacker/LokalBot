import XCTest
@testable import LokalBot

/// Display rules of the Ask page: the order and count of matches, where the
/// keyboard is among them, what the sources menu says, how an answer's
/// citations group into sources, the passage a citation quotes, and the
/// questions an empty page suggests.
final class AskPresentationTests: XCTestCase {
    private let meetingA = UUID()
    private let meetingB = UUID()

    // MARK: Matches

    func testMatchesListMeetingsThenScreenMomentsThenFiles() {
        let matches = sampleMatches()
        XCTAssertEqual(matches.count, 4)
        guard case .meeting(let first)? = matches.row(at: 0), case .meeting(let second)? = matches.row(at: 1),
              case .screen(let screen)? = matches.row(at: 2), case .file(let file)? = matches.row(at: 3) else {
            return XCTFail("rows are not in list order")
        }
        XCTAssertEqual(first.id, meetingA)
        XCTAssertEqual(second.id, meetingB)
        XCTAssertEqual(screen.primary.snapshotID, 7)
        XCTAssertEqual(file.id, 11)
        XCTAssertNil(matches.row(at: 4))
        XCTAssertNil(matches.row(at: -1))
        XCTAssertEqual(matches.screenIDs, [7, 8], "folded moments of a listed session count too")
    }

    func testMatchCountNamesMeetingsOnlyWhenNothingElseMatched() {
        var matches = AskMatches()
        matches.meetings = [group(meetingA, kinds: [.segment, .summary, .outcome])]
        XCTAssertEqual(matches.countLabel(), "3 in 1 meeting")

        matches.meetings.append(group(meetingB, kinds: [.segment]))
        XCTAssertEqual(matches.countLabel(), "4 in 2 meetings")
        XCTAssertEqual(matches.countLabel(localize: { $0 == "%1$lld in %2$lld meetings" ? "%1$lld / %2$lld" : $0 }),
                       "4 / 2")

        XCTAssertEqual(sampleMatches().countLabel(), "4", "mixed sources are counted as sources")

        matches.isTruncated = true
        XCTAssertEqual(matches.countLabel(), "2+", "a cut list never reads as a total")
    }

    func testMatchesCopyASearchResult() {
        var result = RecallSearch.Result()
        result.meetings = [group(meetingA, kinds: [.segment])]
        result.isTruncated = true
        let matches = AskMatches(result)
        XCTAssertEqual(matches.meetings.map(\.id), [meetingA])
        XCTAssertTrue(matches.isTruncated)
        XCTAssertTrue(AskMatches().isEmpty)
    }

    // MARK: Keyboard

    func testDownMovesFromTheFieldIntoTheMatchesAndUpReturns() {
        var cursor = AskMatchCursor()
        XCTAssertFalse(cursor.isInMatches)
        XCTAssertFalse(cursor.move(.up, count: 3), "Up in the field stays the field's key")
        XCTAssertNil(cursor.index)

        XCTAssertTrue(cursor.move(.down, count: 3))
        XCTAssertEqual(cursor.index, 0)
        XCTAssertTrue(cursor.move(.down, count: 3))
        XCTAssertTrue(cursor.move(.down, count: 3))
        XCTAssertTrue(cursor.move(.down, count: 3))
        XCTAssertEqual(cursor.index, 2, "Down stops at the last match")

        XCTAssertTrue(cursor.move(.up, count: 3))
        XCTAssertTrue(cursor.move(.up, count: 3))
        XCTAssertEqual(cursor.index, 0)
        XCTAssertTrue(cursor.move(.up, count: 3))
        XCTAssertNil(cursor.index, "Up from the first match returns to the field, where Return asks")
    }

    func testCursorNeverPointsPastTheMatches() {
        var cursor = AskMatchCursor(index: 4)
        cursor.clamp(count: 2)
        XCTAssertEqual(cursor.index, 1)
        cursor.clamp(count: 0)
        XCTAssertNil(cursor.index)

        var empty = AskMatchCursor(index: 1)
        XCTAssertFalse(empty.move(.down, count: 0), "with no matches the arrow keys belong to the field")
        XCTAssertNil(empty.index)

        var picked = AskMatchCursor(index: 1)
        picked.returnToField()
        XCTAssertFalse(picked.isInMatches)
    }

    // MARK: Sources menu

    func testSourcesMenuNamesTheChosenSources() {
        let all = AskScopeSummary.make(input(), meetingTitle: { _ in nil })
        XCTAssertEqual(all.title, "All sources")
        XCTAssertFalse(all.isNarrowed)
        XCTAssertFalse(all.hasFilters)
        XCTAssertNil(all.narrowedTo)
        XCTAssertNil(all.widenTitle)

        let some = AskScopeSummary.make(input(sources: [.meetings, .screen]), meetingTitle: { _ in nil })
        XCTAssertEqual(some.title, "Meetings, Screen")

        // Files is part of "All sources" even while it is not offered.
        let withoutFiles = AskScopeSummary.make(
            input(sources: [.meetings, .today, .screen], available: [.meetings, .today, .screen]),
            meetingTitle: { _ in nil })
        XCTAssertEqual(withoutFiles.title, "All sources")
    }

    func testSourcesMenuShowsWhatAFollowUpIsLimitedTo() {
        let one = AskScopeSummary.make(
            input(sources: [.meetings, .today], meetingIDs: [meetingA], screenIDs: [],
                  before: AskSourceScope.defaults),
            meetingTitle: { $0 == self.meetingA ? "Design review meeting" : nil })
        XCTAssertTrue(one.isNarrowed)
        XCTAssertEqual(one.title, "Design review meeting")
        XCTAssertEqual(one.narrowedTo, "Design review meeting")
        XCTAssertEqual(one.widenTitle, "All sources")

        let several = AskScopeSummary.make(
            input(sources: [.meetings, .screen], meetingIDs: [meetingA, meetingB], screenIDs: [7, 8, 9],
                  before: [.meetings, .screen]),
            meetingTitle: { _ in "ignored" })
        XCTAssertEqual(several.title, "2 meetings, 3 screen moments")
        XCTAssertEqual(several.widenTitle, "Meetings, Screen",
                       "widening returns to the sources chosen before the limit, and says which")

        let moment = AskScopeSummary.make(input(sources: [.screen], screenIDs: [7]), meetingTitle: { _ in nil })
        XCTAssertEqual(moment.title, "1 screen moment")
        XCTAssertEqual(moment.widenTitle, "All sources")

        let untitled = AskScopeSummary.make(input(sources: [.meetings], meetingIDs: [meetingA]),
                                            meetingTitle: { _ in nil })
        XCTAssertEqual(untitled.title, "1 meeting")

        // Only files matched: no meeting or screen moment is left to name.
        let files = AskScopeSummary.make(input(sources: [.meetings, .files], meetingIDs: [], screenIDs: []),
                                         meetingTitle: { _ in nil })
        XCTAssertTrue(files.isNarrowed)
        XCTAssertEqual(files.title, "Files", "a source limited to nothing is not named")
        let nothing = AskScopeSummary.make(input(sources: [.meetings], meetingIDs: [], screenIDs: []),
                                           meetingTitle: { _ in nil })
        XCTAssertEqual(nothing.title, "No matches")
    }

    func testSourcesMenuShowsFinerFiltersAndShortensLongNames() {
        var filtered = input()
        filtered.facet = .summaries
        filtered.screenApp = "Safari"
        let summary = AskScopeSummary.make(filtered, meetingTitle: { _ in nil })
        XCTAssertEqual(summary.title, "All sources · Summaries · Safari")
        XCTAssertTrue(summary.hasFilters)
        XCTAssertFalse(summary.isNarrowed)

        let long = String(repeating: "Quarterly planning ", count: 4)
        let narrowed = AskScopeSummary.make(input(sources: [.meetings], meetingIDs: [meetingA]),
                                            meetingTitle: { _ in long })
        XCTAssertEqual(narrowed.title.count, AskScopeSummary.maximumTitleLength)
        XCTAssertTrue(narrowed.title.hasSuffix("…"))
    }

    func testSourcesMenuWordingGoesThroughTheCatalog() {
        let summary = AskScopeSummary.make(
            input(sources: [.meetings], meetingIDs: [meetingA, meetingB], before: AskSourceScope.defaults),
            meetingTitle: { _ in nil },
            localize: { ["%lld meetings": "%lld Besprechungen", "All sources": "Alle Quellen"][$0] ?? $0 })
        XCTAssertEqual(summary.title, "2 Besprechungen")
        XCTAssertEqual(summary.widenTitle, "Alle Quellen")
    }

    // MARK: Sources under an answer

    func testCitationsGroupBySourceAndKeepTheirNumbers() {
        let citations: [ChatCitation] = [
            .init(meetingID: "aabbccdd", seconds: 12),
            .init(meetingID: "AABBCCDD", seconds: 35),
            .init(fileID: 4),
            .init(meetingID: "11223344", seconds: 8),
            .init(snapshotID: 42),
            .init(meetingID: "aabbccdd", seconds: 24),
        ]
        let groups = AnswerSources.groups(citations)
        XCTAssertEqual(groups.map(\.kind), [.meeting, .file, .meeting, .screen])
        XCTAssertEqual(groups[0].entries.map(\.number), [1, 2, 6], "numbers are the answer's own")
        XCTAssertEqual(groups[0].entries.map(\.citation.seconds), [12, 35, 24])
        XCTAssertEqual(groups[1].entries.map(\.number), [3])
        XCTAssertEqual(groups[2].entries.map(\.number), [4])
        XCTAssertEqual(groups[3].first.snapshotID, 42)
        XCTAssertEqual(Set(groups.map(\.id)).count, groups.count)
        XCTAssertTrue(AnswerSources.groups([]).isEmpty)
    }

    func testPassagesOfOneFileShareARowOnceTheFileIsKnown() {
        let citations: [ChatCitation] = [.init(fileID: 4), .init(fileID: 9), .init(fileID: 5)]
        XCTAssertEqual(AnswerSources.groups(citations).count, 3, "unknown passages stay separate")

        let paths: [Int64: String] = [4: "/docs/draft.md", 5: "/docs/draft.md", 9: "/docs/other.md"]
        let grouped = AnswerSources.groups(citations) { paths[$0] }
        XCTAssertEqual(grouped.map { $0.entries.map(\.number) }, [[1, 3], [2]])
    }

    // MARK: Quoted passages

    func testMeetingCitationQuotesTheLineThatStartsInItsSecond() {
        let lines: [CitationPassage.Line] = [
            .init(start: 0.4, end: 11.9, speaker: "Maya Chen", text: "Agreed on Redis."),
            .init(start: 12.6, end: 23.0, speaker: "Me", text: "Do we need cluster mode?"),
            .init(start: 35.2, end: 41.0, speaker: "Maya Chen", text: "Please benchmark failover latency."),
        ]
        XCTAssertEqual(CitationPassage.line(at: 12, in: lines)?.text, "Do we need cluster mode?")
        XCTAssertEqual(CitationPassage.line(at: 35, in: lines)?.speaker, "Maya Chen")
        XCTAssertEqual(CitationPassage.line(at: 20, in: lines)?.start, 12.6, "otherwise the line being said then")
        XCTAssertEqual(CitationPassage.line(at: 30, in: lines)?.start, 12.6, "otherwise the last line before it")
        XCTAssertEqual(CitationPassage.line(at: 500, in: lines)?.start, 35.2)
        XCTAssertNil(CitationPassage.line(at: 12, in: []))
        XCTAssertNil(CitationPassage.line(at: -1, in: lines))
        XCTAssertNil(CitationPassage.line(at: .nan, in: lines))
    }

    func testTranscriptLinesComeFromTheStoredTranscript() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskPresentationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertTrue(CitationPassage.transcriptLines(in: folder).isEmpty)

        let transcript = Transcript(segments: [
            .init(start: 3, end: 9, speaker: "me", text: "I'll draft the eviction policy."),
            .init(start: 9, end: 10, speaker: "them", text: "   "),
        ], engine: "test")
        try JSONEncoder().encode(transcript).write(to: folder.appendingPathComponent("transcript.json"))
        let lines = CitationPassage.transcriptLines(in: folder)
        XCTAssertEqual(lines.map(\.text), ["I'll draft the eviction policy."], "blank lines are not quotable")
        XCTAssertEqual(CitationPassage.line(at: 3, in: lines)?.end, 9)
    }

    func testQuotesDropSearchMarkersAndCutAtAWord() {
        XCTAssertEqual(CitationPassage.quote("12 GB per node.\n  Leave 20% headroom before «eviction» starts."),
                       "12 GB per node. Leave 20% headroom before eviction starts.")
        XCTAssertNil(CitationPassage.quote(nil))
        XCTAssertNil(CitationPassage.quote(" \n "))

        let long = Array(repeating: "headroom", count: 80).joined(separator: " ")
        let cut = try? XCTUnwrap(CitationPassage.quote(long, limit: 60))
        XCTAssertEqual(cut?.hasSuffix("…"), true)
        XCTAssertLessThanOrEqual(cut?.count ?? .max, 61)
        XCTAssertEqual(cut?.dropLast().split(separator: " ").allSatisfy { $0 == "headroom" }, true,
                       "a long quote is cut between words")
    }

    // MARK: Suggestions

    func testSuggestionsNameThePersonsOwnProjectMeetingAndColleague() {
        let suggestions = AskSuggestions.build(
            .init(latestMeetingTitle: "Design review meeting", personName: "Maya Chen", projectName: "Atlas"),
            fallback: ["General question"])
        XCTAssertEqual(suggestions.map(\.kind), [.project, .meeting, .person, .keyword])
        XCTAssertEqual(suggestions.map(\.text), [
            "Where does Atlas stand?",
            "What did we decide in Design review meeting?",
            "What did Maya Chen ask me to do?",
            "atlas",
        ])
        XCTAssertEqual(Set(suggestions.map(\.id)).count, 4)
    }

    func testSuggestionsFallBackToTheGeneralOnesWithNothingToName() {
        let suggestions = AskSuggestions.build(.init(latestMeetingTitle: "  ", personName: nil, projectName: nil),
                                               fallback: ["List my recent meetings"],
                                               localize: { $0 == "List my recent meetings" ? "Zeige Besprechungen" : $0 })
        XCTAssertEqual(suggestions, [.init(kind: .general, text: "Zeige Besprechungen")])
    }

    func testSuggestionsUseWhatExistsAndTheCatalog() {
        let onlyMeeting = AskSuggestions.build(
            .init(latestMeetingTitle: "Weekly sync", personName: nil, projectName: nil), fallback: [],
            localize: { $0 == "What did we decide in %@?" ? "Was wurde in %@ entschieden?" : $0 })
        XCTAssertEqual(onlyMeeting.map(\.text), ["Was wurde in Weekly sync entschieden?"],
                       "a title of everyday words offers no search word")

        let long = AskSuggestions.build(
            .init(latestMeetingTitle: String(repeating: "Planning ", count: 20), personName: nil, projectName: nil),
            fallback: [])
        XCTAssertLessThan(long[0].text.count, 90)
    }

    func testKeywordIsOneDistinctiveWord() {
        XCTAssertEqual(AskSuggestions.keyword(from: ["Atlas", "Design review meeting"]), "atlas")
        XCTAssertEqual(AskSuggestions.keyword(from: ["Failover benchmark review"]), "benchmark")
        XCTAssertEqual(AskSuggestions.keyword(from: ["Q3 2026 sync", "Roadmap"]), "roadmap")
        XCTAssertNil(AskSuggestions.keyword(from: ["Weekly team sync", "1:1"]))
        XCTAssertNil(AskSuggestions.keyword(from: []))
    }

    // MARK: Dates

    func testDatesAreShortAndCarryTheYearOnlyWhenItDiffers() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let locale = Locale(identifier: "en_US")
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 9)))
        let thisYear = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 11)))
        let lastYear = try XCTUnwrap(calendar.date(from: DateComponents(year: 2025, month: 3, day: 2, hour: 16, minute: 12)))

        XCTAssertEqual(AskDateLabel.day(thisYear, now: now, calendar: calendar, locale: locale), "Nov 10")
        XCTAssertEqual(AskDateLabel.day(lastYear, now: now, calendar: calendar, locale: locale), "Mar 2, 2025")
        let moment = AskDateLabel.moment(thisYear, now: now, calendar: calendar, locale: locale)
        XCTAssertTrue(moment.hasPrefix("Nov 10"), moment)
        XCTAssertTrue(moment.contains("11:00"), moment)
        XCTAssertFalse(moment.contains("2026"), moment)
    }

    // MARK: Fixtures

    private func input(sources: Set<AskSourceScope> = AskSourceScope.defaults,
                       available: [AskSourceScope] = AskSourceScope.allCases,
                       meetingIDs: Set<UUID>? = nil, screenIDs: Set<Int64>? = nil,
                       before: Set<AskSourceScope>? = nil) -> AskScopeSummary.Input {
        .init(sources: sources, available: available, meetingIDs: meetingIDs, screenIDs: screenIDs,
              sourcesBeforeEvidence: before)
    }

    private func group(_ id: UUID, kinds: [SearchIndex.Kind]) -> MeetingRecallGroup {
        MeetingRecallGroup(id: id, matches: kinds.enumerated().map { offset, kind in
            SearchIndex.Hit(meetingID: id, kind: kind, start: TimeInterval(offset * 10),
                            snippet: "«failover» \(offset)", speaker: "me")
        })
    }

    private func sampleMatches() -> AskMatches {
        var matches = AskMatches()
        matches.meetings = [group(meetingA, kinds: [.segment, .summary]), group(meetingB, kinds: [.outcome])]
        matches.screens = [ScreenRecallGroup(id: "screen-7", matches: [
            .init(snapshotID: 7, ts: Date(timeIntervalSince1970: 100), app: "Notes", snippet: "«failover»"),
            .init(snapshotID: 8, ts: Date(timeIntervalSince1970: 160), app: "Notes", snippet: "«failover» again"),
        ])]
        matches.files = [FileSearchHit(id: 11, path: "/docs/draft.md", kind: .doc, excerpt: "«failover»",
                                       modified: Date(timeIntervalSince1970: 50), isSemantic: false)]
        return matches
    }
}
