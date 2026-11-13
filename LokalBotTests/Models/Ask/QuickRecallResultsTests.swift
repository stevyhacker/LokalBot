import XCTest
@testable import LokalBot

/// What the Quick Recall window lists, where its keyboard is, and what an
/// answer asked from it reads.
final class QuickRecallResultsTests: XCTestCase {
    // MARK: Grouping

    func testGroupsKeepAFixedOrderAndListThreeOfEachKind() {
        var found = QuickRecallGrouping.Found()
        found.commands = commands(1)
        found.meetings = meetings(7)
        found.screens = screens(11)
        found.screenSourceCount = 11
        found.files = files(1)
        found.agentNotes = notes(2)

        let groups = QuickRecallGrouping.groups(found, showsAgentNotes: true)

        XCTAssertEqual(groups.map(\.kind), [.commands, .meetings, .screens, .files, .agentNotes])
        XCTAssertEqual(groups.map(\.rows.count), [1, 3, 3, 1, 2])
        XCTAssertEqual(groups.map(\.total), [1, 7, 11, 1, 2])
        XCTAssertEqual(groups.map(\.hasMore), [false, true, true, false, false])
        XCTAssertEqual(groups[1].totalLabel, "7")
        XCTAssertEqual(groups[1].rows.map(\.id), found.meetings.prefix(3).map(\.id), "the best three, in ranked order")
    }

    /// Forty screen matches used to push every meeting below the fold.
    /// A search word that only sits inside a command's name ("ion" in "Start
    /// dictation") must not put that command under Return.
    func testLooselyMatchingCommandsComeAfterTheSearchResults() {
        var found = QuickRecallGrouping.Found()
        found.looseCommands = commands(2)
        found.meetings = commands(1)
        let groups = QuickRecallGrouping.groups(found, showsAgentNotes: false)
        XCTAssertEqual(groups.map(\.kind), [.meetings, .looseCommands])
        XCTAssertEqual(groups.last?.kind.title, "Commands")
        XCTAssertFalse(groups.last?.isCapped ?? true)
    }

    func testManyScreenMatchesLeaveMeetingsInView() {
        var found = QuickRecallGrouping.Found()
        found.meetings = meetings(2)
        found.screens = screens(40)
        found.screenSourceCount = 40

        let rows = QuickRecallGrouping.groups(found, showsAgentNotes: false).flatMap(\.rows)

        XCTAssertEqual(rows.count, 5)
        XCTAssertEqual(rows.prefix(2).map(\.id), found.meetings.map(\.id))
    }

    func testEmptyKindsAreLeftOutAndCommandsNeedAMatch() {
        var found = QuickRecallGrouping.Found()
        found.screens = screens(1)
        found.screenSourceCount = 1

        XCTAssertEqual(QuickRecallGrouping.groups(found, showsAgentNotes: true).map(\.kind), [.screens])
        XCTAssertTrue(QuickRecallGrouping.groups(QuickRecallGrouping.Found(), showsAgentNotes: true).isEmpty)
    }

    func testAgentNotesHaveAGroupOnlyWhileTheirSettingIsOn() {
        var found = QuickRecallGrouping.Found()
        found.files = files(1)
        found.agentNotes = notes(2)

        XCTAssertEqual(QuickRecallGrouping.groups(found, showsAgentNotes: true).map(\.kind), [.files, .agentNotes])
        XCTAssertEqual(QuickRecallGrouping.groups(found, showsAgentNotes: false).map(\.kind), [.files])
    }

    /// The search lists at most `displayLimit` of a kind. A kind that filled
    /// it while the search says more matched reads "40+", never "40".
    func testACappedKindNeverReadsAsAnExactTotal() {
        var found = QuickRecallGrouping.Found()
        found.meetings = meetings(7)
        found.screens = screens(RecallSearch.displayLimit)
        found.screenSourceCount = RecallSearch.displayLimit
        found.isTruncated = true

        let groups = QuickRecallGrouping.groups(found, showsAgentNotes: false)

        XCTAssertEqual(groups.map(\.totalLabel), ["7", "\(RecallSearch.displayLimit)+"])
        XCTAssertEqual(groups.map(\.isCapped), [false, true])

        found.isTruncated = false
        XCTAssertEqual(QuickRecallGrouping.groups(found, showsAgentNotes: false).map(\.totalLabel),
                       ["7", "\(RecallSearch.displayLimit)"], "exactly forty that were all listed is a total")
    }

    /// A saved moment can stand for a whole screen source, so there can be
    /// fewer rows than the sources the search listed and cut.
    func testScreensFoldedBySavedMomentsStillSayTheListWasCut() {
        var found = QuickRecallGrouping.Found()
        found.screens = screens(38)
        found.screenSourceCount = RecallSearch.displayLimit
        found.isTruncated = true

        let group = QuickRecallGrouping.groups(found, showsAgentNotes: false)[0]

        XCTAssertTrue(group.isCapped)
        XCTAssertEqual(group.totalLabel, "38+")
        XCTAssertTrue(group.hasMore)
    }

    /// A capped kind keeps "Show all" even when its three rows are all it
    /// lists here; commands are counted, never capped.
    func testCommandsExpandInPlaceAndAreNeverCapped() {
        var found = QuickRecallGrouping.Found()
        found.commands = commands(RecallSearch.displayLimit + 5)
        found.isTruncated = true

        let folded = QuickRecallGrouping.groups(found, showsAgentNotes: false)[0]
        XCTAssertEqual(folded.rows.count, 3)
        XCTAssertEqual(folded.totalLabel, "\(RecallSearch.displayLimit + 5)")
        XCTAssertFalse(folded.isCapped)

        let open = QuickRecallGrouping.groups(found, expanded: [.commands], showsAgentNotes: false)[0]
        XCTAssertEqual(open.rows.count, RecallSearch.displayLimit + 5)
        XCTAssertFalse(open.hasMore)
    }

    func testShowAllNarrowsAskToTheKindsOwnSource() {
        XCTAssertEqual(QuickRecallGroup.Kind.meetings.askSource, .meetings)
        XCTAssertEqual(QuickRecallGroup.Kind.screens.askSource, .screen)
        XCTAssertEqual(QuickRecallGroup.Kind.files.askSource, .files)
        XCTAssertEqual(QuickRecallGroup.Kind.agentNotes.askSource, .agentNotes)
        XCTAssertNil(QuickRecallGroup.Kind.commands.askSource)
        XCTAssertNil(QuickRecallGroup.Kind.recent.askSource)
    }

    func testBeforeTypingListsRecentThenEveryCommand() {
        let groups = QuickRecallGrouping.idle(recent: meetings(2), commands: commands(9))
        XCTAssertEqual(groups.map(\.kind), [.recent, .commands])
        XCTAssertEqual(groups.map(\.rows.count), [2, 9])
        XCTAssertEqual(groups.map(\.hasMore), [false, false])
        XCTAssertEqual(QuickRecallGrouping.idle(recent: [], commands: commands(2)).map(\.kind), [.commands])
    }

    // MARK: Recent

    func testRecentMergesMeetingsAndSavedMomentsByTime() {
        let first = UUID(), second = UUID()
        let rows = QuickRecallRecent.rows(
            meetings: [
                .init(id: first, title: "Holiday shoot planning", duration: "32 min", startedAt: time(300)),
                .init(id: second, title: "Mac refresh planning", duration: "45 min", startedAt: time(100)),
            ],
            savedMoments: [saved(7, at: time(200), note: "Delivery checklist", app: "Pages")])

        XCTAssertEqual(rows.map(\.title), ["Holiday shoot planning", "Delivery checklist", "Mac refresh planning"])
        XCTAssertEqual(rows.map(\.qualifier), ["32 min", "Pages", "45 min"])
        XCTAssertEqual(rows.map(\.isSaved), [false, true, false])
        XCTAssertEqual(rows.map(\.timestamp), [time(300), time(200), time(100)])
        XCTAssertNil(rows[0].snippet, "a recent item has one line")
        guard case .recentMeeting(let id) = rows[0].destination else { return XCTFail("opens the meeting") }
        XCTAssertEqual(id, first)
        XCTAssertEqual(rows[1].snapshotID, 7)
    }

    func testRecentKeepsTheNewestFewAndPutsAMeetingBeforeAMomentOfTheSameInstant() {
        let meetings = (0..<6).map {
            QuickRecallRecent.MeetingItem(id: UUID(), title: "Meeting \($0)", duration: nil,
                                          startedAt: time(Double($0) * 10))
        }
        let rows = QuickRecallRecent.rows(meetings: meetings,
                                          savedMoments: [saved(1, at: time(50), note: "Saved", app: "Notes")])

        XCTAssertEqual(rows.count, QuickRecallGrouping.recentLimit)
        XCTAssertEqual(rows.prefix(2).map(\.title), ["Meeting 5", "Saved"])
        XCTAssertNil(rows[0].qualifier, "a meeting still recording has no length yet")
        XCTAssertTrue(QuickRecallRecent.rows(meetings: [], savedMoments: []).isEmpty)
    }

    // MARK: Selection

    func testTheFirstRowIsSelectedAndNothingIsWhenThereAreNoRows() {
        var cursor = QuickRecallCursor()
        cursor.reset(rowCount: 4)
        XCTAssertEqual(cursor.target(rowCount: 4, hasAsk: true), .row(0))

        cursor.reset(rowCount: 0)
        XCTAssertNil(cursor.target(rowCount: 0, hasAsk: true),
                     "with nothing to open, Return must not ask by itself")
    }

    func testArrowKeysReachTheAskRowAndGoRound() {
        var cursor = QuickRecallCursor()
        cursor.reset(rowCount: 2)
        cursor.move(by: 1, rowCount: 2, hasAsk: true)
        XCTAssertEqual(cursor.target(rowCount: 2, hasAsk: true), .row(1))
        cursor.move(by: 1, rowCount: 2, hasAsk: true)
        XCTAssertEqual(cursor.target(rowCount: 2, hasAsk: true), .ask, "Down from the last result is the Ask row")
        cursor.move(by: 1, rowCount: 2, hasAsk: true)
        XCTAssertEqual(cursor.target(rowCount: 2, hasAsk: true), .row(0))
        cursor.move(by: -1, rowCount: 2, hasAsk: true)
        XCTAssertEqual(cursor.target(rowCount: 2, hasAsk: true), .ask, "Up from the first result is the Ask row")
    }

    func testArrowKeysSelectTheAskRowWhenNothingMatched() {
        var cursor = QuickRecallCursor()
        cursor.reset(rowCount: 0)
        cursor.move(by: 1, rowCount: 0, hasAsk: true)
        XCTAssertEqual(cursor.target(rowCount: 0, hasAsk: true), .ask)

        var idle = QuickRecallCursor()
        idle.reset(rowCount: 0)
        idle.move(by: 1, rowCount: 0, hasAsk: false)
        XCTAssertNil(idle.target(rowCount: 0, hasAsk: false))
    }

    func testBeforeTypingTheRowsGoRoundWithoutAnAskRow() {
        var cursor = QuickRecallCursor()
        cursor.reset(rowCount: 3)
        cursor.move(by: -1, rowCount: 3, hasAsk: false)
        XCTAssertEqual(cursor.target(rowCount: 3, hasAsk: false), .row(2))
        cursor.move(by: 1, rowCount: 3, hasAsk: false)
        XCTAssertEqual(cursor.target(rowCount: 3, hasAsk: false), .row(0))
    }

    func testTheAskRowStaysSelectedWhenCommandsExpandAboveIt() {
        var cursor = QuickRecallCursor()
        cursor.reset(rowCount: 3)
        cursor.move(by: -1, rowCount: 3, hasAsk: true)
        XCTAssertEqual(cursor.target(rowCount: 3, hasAsk: true), .ask)
        XCTAssertEqual(cursor.target(rowCount: 9, hasAsk: true), .row(3))
        cursor.select(.ask, rowCount: 9)
        XCTAssertEqual(cursor.target(rowCount: 9, hasAsk: true), .ask)
    }

    // MARK: What an answer reads

    /// A word, or a phrase of up to three words, is answered from the listed
    /// meetings and screen moments, as ⌘Return always was.
    func testAWordOrShortPhraseReadsTheListedMeetingsAndScreens() {
        let meeting = UUID()
        for query in ["captions", "atlas pilot", "atlas pilot dates"] {
            let scope = QuickRecallAskScope.resolve(query: query, meetingIDs: [meeting], screenIDs: [4, 5],
                                                    isRememberStatement: false)
            XCTAssertEqual(scope.answer, .listedMatches, query)
            XCTAssertEqual(scope.sources, [.meetings, .screen], query)
            XCTAssertEqual(scope.meetingIDs, [meeting], query)
            XCTAssertEqual(scope.screenSnapshotIDs, [4, 5], query)
        }
    }

    func testListedMatchesOfOneKindLeaveTheOtherSourceOut() {
        let onlyScreens = QuickRecallAskScope.resolve(query: "captions", meetingIDs: [], screenIDs: [4],
                                                      isRememberStatement: false)
        XCTAssertEqual(onlyScreens.sources, [.screen])
        XCTAssertEqual(onlyScreens.meetingIDs, [])
        XCTAssertEqual(onlyScreens.screenSnapshotIDs, [4])

        let meeting = UUID()
        let onlyMeetings = QuickRecallAskScope.resolve(query: "captions", meetingIDs: [meeting], screenIDs: [],
                                                       isRememberStatement: false)
        XCTAssertEqual(onlyMeetings.sources, [.meetings])
        XCTAssertEqual(onlyMeetings.meetingIDs, [meeting])
        XCTAssertEqual(onlyMeetings.screenSnapshotIDs, [])
    }

    /// The Ask screen's rule (`AskAnswerScope.isFullQuestion`): a full
    /// question reads everything in the sources, whatever is listed.
    func testAFullQuestionReadsEverySource() {
        for query in ["what did we decide about captions?", "podsjeti me šta smo dogovorili", "why atlas?"] {
            XCTAssertTrue(AskAnswerScope.isFullQuestion(query), query)
            let scope = QuickRecallAskScope.resolve(query: query, meetingIDs: [UUID()], screenIDs: [4],
                                                    isRememberStatement: false)
            XCTAssertEqual(scope.answer, .chosenSources, query)
            XCTAssertEqual(scope.sources, AskSourceScope.defaults, query)
            XCTAssertNil(scope.meetingIDs, query)
            XCTAssertNil(scope.screenSnapshotIDs, query)
        }
    }

    func testNothingListedOrARememberStatementLimitsNothing() {
        let none = QuickRecallAskScope.resolve(query: "captions", meetingIDs: [], screenIDs: [],
                                               isRememberStatement: false)
        XCTAssertEqual(none, QuickRecallAskScope(answer: .chosenSources, sources: AskSourceScope.defaults))

        let remember = QuickRecallAskScope.resolve(query: "Remember captions", meetingIDs: [UUID()], screenIDs: [],
                                                   isRememberStatement: true)
        XCTAssertEqual(remember, QuickRecallAskScope(answer: .chosenSources, sources: AskSourceScope.defaults))
    }

    func testTheAskRowSaysWhatTheAnswerReadsAndWhereItIsWritten() {
        XCTAssertTrue(QuickRecallAskScope.readsListedMatches(query: "captions", hasMatches: true, isSearching: false,
                                                             isRememberStatement: false))
        XCTAssertTrue(QuickRecallAskScope.readsListedMatches(query: "captions", hasMatches: false, isSearching: true,
                                                             isRememberStatement: false),
                      "a word waits for its matches")
        XCTAssertFalse(QuickRecallAskScope.readsListedMatches(query: "captions", hasMatches: false,
                                                              isSearching: false, isRememberStatement: false))
        XCTAssertFalse(QuickRecallAskScope.readsListedMatches(query: "what did we decide about captions?",
                                                              hasMatches: true, isSearching: false,
                                                              isRememberStatement: false))

        XCTAssertEqual(QuickRecallAskScope.askRowDetail(inference: .onDevice, readsListedMatches: true),
                       "Answers from these matches, on this Mac")
        XCTAssertEqual(QuickRecallAskScope.askRowDetail(inference: .onDevice, readsListedMatches: false),
                       "Answers from all your sources, on this Mac")
        XCTAssertEqual(QuickRecallAskScope.askRowDetail(inference: .remote(host: "api.example.com"),
                                                        readsListedMatches: true),
                       "Answers from these matches, using api.example.com",
                       "a remote model is named before anything is sent")
        XCTAssertEqual(QuickRecallAskScope.askRowDetail(inference: .blocked(reason: "No approval"),
                                                        readsListedMatches: true),
                       "Model connection blocked")
    }

    func testTheAnswerFootSaysWhereItWasAnsweredAndWhatItRead() {
        XCTAssertEqual(QuickRecallAskScope.answerFootLabel(inference: .onDevice, isAnswered: true,
                                                           scope: "3 meetings, 1 screen moment"),
                       "Answered on this Mac · 3 meetings, 1 screen moment")
        XCTAssertEqual(QuickRecallAskScope.answerFootLabel(inference: .onDevice, isAnswered: false,
                                                           scope: "All sources"),
                       "On this Mac · All sources", "nothing is called answered while it is being written")
        XCTAssertEqual(QuickRecallAskScope.answerFootLabel(inference: .remote(host: "api.example.com"),
                                                           isAnswered: true, scope: nil),
                       "Answered with api.example.com")
        XCTAssertEqual(QuickRecallAskScope.answerFootLabel(inference: .blocked(reason: "No approval"),
                                                           isAnswered: false, scope: "All sources"),
                       "Model connection blocked")
    }

    // MARK: A source's quoted line

    func testAQuoteMarksTheQuestionsWordsLikeASearchResult() {
        XCTAssertEqual(QuickRecallQuote.terms(in: "What about the Captions, and captions?"), ["captions"])
        XCTAssertEqual(
            QuickRecallQuote.line("Every client video ships with captions and audio descriptions.",
                                  question: "captions"),
            "Every client video ships with «captions» and audio descriptions.")
        XCTAssertEqual(QuickRecallQuote.marked("Captions are easy. Recaptioning is not.", terms: ["caption"]),
                       "«Captions» are easy. Recaptioning is not.", "a word that starts with the term, not one that holds it")
        XCTAssertEqual(QuickRecallQuote.marked("Übersicht für Müller", terms: ["muller"]), "Übersicht für «Müller»")
        XCTAssertEqual(QuickRecallQuote.marked("Nothing here", terms: []), "Nothing here")
    }

    func testAQuoteDropsStoredSearchMarkersAndStaysShort() {
        XCTAssertEqual(QuickRecallQuote.line("The «pilot»\nstarts Monday", question: "monday"),
                       "The pilot starts «Monday»")
        XCTAssertNil(QuickRecallQuote.line(nil, question: "pilot"))
        XCTAssertNil(QuickRecallQuote.line("  \n ", question: "pilot"))
        let long = String(repeating: "filler words keep coming ", count: 30) + "then the pilot starts Monday"
        let line = QuickRecallQuote.line(long, question: "pilot")
        XCTAssertNotNil(line)
        XCTAssertTrue(line?.contains("«pilot»") == true, "the excerpt is cut around the question's word")
        XCTAssertLessThan(line?.count ?? .max, 240)
    }

    // MARK: When

    func testWhenIsShortAndDropsTheTimeOnceItIsOlderThanAWeek() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let locale = Locale(identifier: "en_US")
        func date(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int, year: Int = 2026) -> Date {
            calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)) ?? Date()
        }
        let now = date(11, 11, 17, 40)
        func label(_ date: Date) -> String {
            QuickRecallDateLabel.string(for: date, now: now, calendar: calendar, locale: locale)
                .replacingOccurrences(of: "\u{202F}", with: " ")
        }

        XCTAssertEqual(label(date(11, 11, 10, 43)), "Today 10:43 AM")
        XCTAssertEqual(label(date(11, 10, 16, 0)), "Yesterday 4:00 PM")
        XCTAssertEqual(label(date(11, 6, 11, 47)), "Fri 11:47 AM")
        XCTAssertEqual(label(date(11, 4, 11, 47)), "Nov 4", "a week ago is a date, not a weekday")
        XCTAssertEqual(label(date(9, 25, 13, 0)), "Sep 25")
        XCTAssertEqual(label(date(12, 30, 9, 0, year: 2025)), "Dec 30, 2025")
        XCTAssertEqual(
            QuickRecallDateLabel.string(for: date(11, 11, 10, 43), now: now, calendar: calendar,
                                        locale: Locale(identifier: "de_DE"), localize: { $0 == "Today" ? "Heute" : $0 }),
            "Heute 10:43")
    }

    // MARK: Fixtures

    private func time(_ offset: TimeInterval) -> Date { Date(timeIntervalSince1970: 1_700_000_000 + offset) }

    private func commands(_ count: Int) -> [QuickRecallRowModel] {
        (0..<count).map { index in
            QuickRecallRowModel.command(PaletteCommand(id: "c\(index)", icon: "gearshape", title: "Command \(index)",
                                                       subtitle: "Library", action: {}))
        }
    }

    private func meetings(_ count: Int) -> [QuickRecallRowModel] {
        (0..<count).map { index in
            QuickRecallRowModel.recentMeeting(id: UUID(), title: "Meeting \(index)", duration: nil,
                                              startedAt: time(Double(index)))
        }
    }

    private func screens(_ count: Int) -> [QuickRecallRowModel] {
        (0..<count).map { index in
            QuickRecallRowModel.screen(snapshotID: Int64(index), appName: "Safari", title: "Screen \(index)",
                                       snippet: nil, timestamp: time(Double(index)))
        }
    }

    private func files(_ count: Int) -> [QuickRecallRowModel] {
        (0..<count).map { index in
            QuickRecallRowModel.file(FileSearchHit(
                id: Int64(index), path: "/Users/me/Documents/File \(index).pdf", kind: .pdf, page: nil,
                excerpt: nil, modified: time(0), isSemantic: false))
        }
    }

    private func notes(_ count: Int) -> [QuickRecallRowModel] {
        (0..<count).map { index in
            QuickRecallRowModel.agentNote(AgentNoteHit(
                id: "n\(index)", agent: "claude-code", title: "Note \(index)", summary: nil, category: nil,
                workingDirectory: nil, path: "/tmp/n\(index).md", modified: time(0), snippet: ""))
        }
    }

    private func saved(_ id: Int64, at date: Date, note: String, app: String) -> ActivityStore.SavedMoment {
        ActivityStore.SavedMoment(snapshotID: id, ts: date, path: "", app: app, windowTitle: "Window",
                                  trigger: "manual", note: note, createdAt: date)
    }
}
