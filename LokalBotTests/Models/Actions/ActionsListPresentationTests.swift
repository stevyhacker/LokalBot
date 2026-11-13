import XCTest
@testable import LokalBot

/// The Actions page's list: what each status shows, in which groups and
/// order, what every Filter choice keeps, and how rows and details are worded.
@MainActor
final class ActionsListPresentationTests: XCTestCase {
    /// Due phrases resolve in the current calendar, so the tests keep to it.
    private let calendar = Calendar.current
    private let locale = Locale(identifier: "en_US")
    /// Tuesday, 10 November 2026, at noon.
    private var now: Date!

    override func setUpWithError() throws {
        now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 12)))
    }

    // MARK: Groups and order

    func testOpenActionsGroupAsOverdueThenNextSevenDaysThenTheRestNewestFirst() throws {
        let threads = [
            thread("Undated from last week", meeting: "Hiring debrief", daysAgo: 4),
            thread("Due far ahead", meeting: "Borealis sync", daysAgo: 5, due: "2026-11-19"),
            thread("Overdue yesterday", meeting: "1:1 with Maya", daysAgo: 8, due: "2026-11-09"),
            thread("Due on the last day of the window", meeting: "Weekly review", daysAgo: 1, due: "2026-11-17"),
            thread("Undated from today", meeting: "Engineering standup", daysAgo: 0),
            thread("Overdue last week", meeting: "Atlas planning", daysAgo: 12, due: "2026-11-05"),
            thread("Due today", meeting: "Hiring debrief", daysAgo: 1, due: "2026-11-10"),
            thread("Due after the offsite", meeting: "Atlas planning", daysAgo: 1, due: "after the offsite"),
            thread("Old and undated", meeting: "Design review", daysAgo: 14),
        ]
        let content = build(threads)

        XCTAssertEqual(content.sections.map(\.id), ["overdue", "soon", "later"])
        XCTAssertEqual(content.sections.map(\.title), ["Overdue", "Next 7 days", "Later or no date"])
        XCTAssertEqual(content.sections.map(\.isLate), [true, false, false], "only Overdue has the red heading")
        XCTAssertEqual(texts(content.sections[0]), ["Overdue last week", "Overdue yesterday"], "overdue by date")
        XCTAssertEqual(texts(content.sections[1]), ["Due today", "Due on the last day of the window"])
        XCTAssertEqual(texts(content.sections[2]), [
            "Undated from today", "Due after the offsite", "Undated from last week", "Due far ahead", "Old and undated",
        ], "later, unclear and undated actions list by newest meeting")
        XCTAssertEqual(content.order, content.sections.flatMap { $0.rows.map(\.id) })
        XCTAssertEqual(content.openCount, 9)

        // Dated groups name the meeting; the rest also say which day it was.
        XCTAssertEqual(content.sections[0].rows.map(\.source), ["Atlas planning", "1:1 with Maya"])
        XCTAssertEqual(content.sections[2].rows.map(\.source), [
            "Engineering standup · Today", "Atlas planning · Yesterday", "Hiring debrief · Fri, Nov 6",
            "Borealis sync · Thu, Nov 5", "Design review · Oct 27",
        ])
    }

    func testAttentionBucketsMatchTheSortedOrder() {
        let overdue = thread("Overdue item for bucket", meeting: "A", daysAgo: 9, due: "2026-11-09")
        let today = thread("Today item for bucket", meeting: "B", daysAgo: 1, due: "2026-11-10")
        let edge = thread("Edge item for bucket", meeting: "C", daysAgo: 1, due: "2026-11-17")
        let later = thread("Later item for bucket", meeting: "D", daysAgo: 1, due: "2026-11-18")
        let unclear = thread("Unclear item for bucket", meeting: "E", daysAgo: 1, due: "once the budget lands")
        let buckets = [overdue, today, edge, later, unclear].map {
            ActionAttentionOrder.bucket(for: $0, now: now, calendar: calendar)
        }
        XCTAssertEqual(buckets, [.overdue, .soon, .soon, .later, .later])
        XCTAssertEqual(ActionAttentionOrder.sorted([unclear, later, edge, today, overdue], now: now, calendar: calendar)
            .map(\.text), [overdue, today, edge, unclear, later].map(\.text))
    }

    func testGroupingByMeetingAndByNothing() throws {
        let said = [
            reference("Draft the eviction policy document", meeting: "Engineering standup", daysAgo: 5, due: "next week"),
            reference("Draft the eviction policy document", meeting: "Design review meeting", daysAgo: 0, due: "by Thursday"),
        ]
        let twice = try XCTUnwrap(ActionThreadClusterer.cluster(said).first)
        XCTAssertTrue(twice.hasMultipleMeetings)
        let designID = said[1].meetingID
        let threads = [
            twice,
            thread("Ask Maya which regions need cluster mode", meeting: "Design review meeting", daysAgo: 0,
                   meetingID: designID),
            thread("Write up the Redis decision", meeting: "Design review meeting", daysAgo: 0, due: "2026-11-13",
                   meetingID: designID),
            thread("Send the interview feedback", meeting: "Hiring debrief", daysAgo: 1, due: "2026-11-10"),
        ]

        var filter = ActionsListFilter()
        filter.grouping = .meeting
        let byMeeting = build(threads, filter)
        XCTAssertEqual(byMeeting.sections.map(\.title), ["Design review meeting · Today", "Hiring debrief · Yesterday"])
        XCTAssertEqual(texts(byMeeting.sections[0]), [
            "Draft the eviction policy document", "Write up the Redis decision", "Ask Maya which regions need cluster mode",
        ], "inside a meeting the attention order still applies")
        XCTAssertEqual(byMeeting.sections[0].rows.map(\.source), ["Also in 1 other meeting", "", ""],
                       "the heading names the meeting, so a row only says where else it was said")

        filter.grouping = .none
        let flat = build(threads, filter)
        XCTAssertEqual(flat.sections.map(\.title), [nil])
        XCTAssertEqual(texts(flat.sections[0]), [
            "Send the interview feedback", "Draft the eviction policy document", "Write up the Redis decision",
            "Ask Maya which regions need cluster mode",
        ])
        XCTAssertEqual(flat.sections[0].rows[1].source, "In 2 meetings · Today")
    }

    func testDoneListsByCompletionDayAndDeferredListsNewestFirst() {
        let threads = [
            thread("Open one stays out", meeting: "Standup", daysAgo: 0),
            thread("Done long ago", meeting: "Borealis sync", daysAgo: 21, status: .done, changedDaysAgo: 14),
            thread("Done today", meeting: "Design review", daysAgo: 0, status: .done, changedDaysAgo: 0),
            thread("Done six days ago", meeting: "Standup", daysAgo: 7, status: .done, changedDaysAgo: 6),
            thread("Done a week ago", meeting: "Standup", daysAgo: 9, status: .done, changedDaysAgo: 7),
            thread("Deferred older", meeting: "Weekly review", daysAgo: 25, due: "2026-11-01", status: .deferred),
            thread("Deferred newer", meeting: "Design review", daysAgo: 14, status: .deferred),
        ]
        var filter = ActionsListFilter()
        filter.show(.done)
        let done = build(threads, filter)
        XCTAssertEqual(done.sections.map(\.title), ["Last 7 days", "Earlier"])
        XCTAssertEqual(texts(done.sections[0]), ["Done today", "Done six days ago"])
        XCTAssertEqual(texts(done.sections[1]), ["Done a week ago", "Done long ago"])
        XCTAssertEqual(done.sections.flatMap(\.rows).map(\.due?.text), [
            "Done Today", "Done Wed, Nov 4", "Done Nov 3", "Done Oct 27",
        ])
        XCTAssertEqual(done.sections[0].rows[0].source, "Design review")

        filter.show(.deferred)
        let deferred = build(threads, filter)
        XCTAssertEqual(deferred.sections.map(\.title), [nil], "the deferred list has no headings")
        XCTAssertEqual(texts(deferred.sections[0]), ["Deferred newer", "Deferred older"])
        XCTAssertEqual(deferred.sections[0].rows.map(\.source), ["Design review · Oct 27", "Weekly review · Oct 16"])
        XCTAssertEqual(deferred.sections[0].rows[1].due, .init(text: "Due Sun, Nov 1", tone: .calm),
                       "a deferred action is not overdue")
        XCTAssertEqual(deferred.openCount, 1, "the open count ignores what the list shows")
    }

    // MARK: Filters

    func testEachDueFilter() {
        let threads = [
            thread("Overdue filter item", meeting: "A", daysAgo: 9, due: "2026-11-06"),
            thread("Upcoming filter item", meeting: "B", daysAgo: 1, due: "2026-11-12"),
            thread("Unclear filter item", meeting: "C", daysAgo: 1, due: "after the offsite"),
            thread("Undated filter item", meeting: "D", daysAgo: 2),
        ]
        func listed(_ due: ActionsListFilter.Due) -> Set<String> {
            var filter = ActionsListFilter()
            filter.due = due
            return Set(build(threads, filter).sections.flatMap(\.rows).map(\.thread.text))
        }
        XCTAssertEqual(listed(.any).count, 4)
        XCTAssertEqual(listed(.overdue), ["Overdue filter item"])
        XCTAssertEqual(listed(.dated), ["Overdue filter item", "Upcoming filter item"])
        XCTAssertEqual(listed(.undated), ["Unclear filter item", "Undated filter item"],
                       "a phrase that names no day counts as no date")
    }

    func testPersonProjectAndMeetingFilters() throws {
        let maya = thread("Share the failover benchmark results", meeting: "1:1 with Maya Chen", daysAgo: 8)
        let said = [
            reference("Draft the eviction policy document", meeting: "Engineering standup", daysAgo: 5),
            reference("Draft the eviction policy document", meeting: "Design review meeting", daysAgo: 0),
        ]
        let atlas = try XCTUnwrap(ActionThreadClusterer.cluster(said).first)
        let other = thread("Reply to the security review questions", meeting: "Engineering standup", daysAgo: 4)
        let threads = [maya, atlas, other]
        let links = ActionThreadLinks(
            people: [
                person("person:maya", "Maya Chen", members: ["person:maya-c"], actions: [maya, atlas]),
                person("person:nobody", "No Actions", actions: []),
            ],
            projects: [
                project("topic:redis", "Redis", tracked: false, actions: [atlas]),
                project("tracked:atlas", "Atlas", tracked: true, actions: [atlas]),
            ])

        XCTAssertEqual(links.people, [.init(id: "person:maya", name: "Maya Chen")],
                       "only people with one of the user's actions are offered")
        XCTAssertEqual(links.projects.map(\.name), ["Atlas", "Redis"], "tracked projects lead")
        XCTAssertEqual(links.people(for: atlas).map(\.name), ["Maya Chen"])
        XCTAssertEqual(links.projects(for: atlas).map(\.id), ["tracked:atlas", "topic:redis"])
        XCTAssertTrue(links.people(for: other).isEmpty)
        XCTAssertTrue(links.projects(for: maya).isEmpty)

        func listed(_ change: (inout ActionsListFilter) -> Void) -> [String] {
            var filter = ActionsListFilter()
            change(&filter)
            return build(threads, filter, links: links).sections.flatMap(\.rows).map(\.thread.text).sorted()
        }
        XCTAssertEqual(listed { $0.personID = "person:maya" },
                       ["Draft the eviction policy document", "Share the failover benchmark results"])
        XCTAssertEqual(listed { $0.personID = "person:maya-c" }.count, 2, "an id folded into a person still finds them")
        XCTAssertEqual(listed { $0.projectID = "tracked:atlas" }, ["Draft the eviction policy document"])
        XCTAssertEqual(listed { $0.personID = "person:maya"; $0.projectID = "tracked:atlas" },
                       ["Draft the eviction policy document"])
        XCTAssertEqual(listed { $0.personID = "person:gone" }, [])
        XCTAssertEqual(listed { $0.meetingTitle = "engineering standup" },
                       ["Draft the eviction policy document", "Reply to the security review questions"],
                       "a meeting filter covers every meeting with that title, and every mention of a thread")
        XCTAssertEqual(build(threads).meetingTitles, ["Design review meeting", "Engineering standup", "1:1 with Maya Chen"])

        var filter = ActionsListFilter()
        filter.due = .overdue
        filter.personID = "person:maya-c"
        filter.projectID = "tracked:atlas"
        filter.meetingTitle = "Engineering standup"
        filter.staleOnly = true
        XCTAssertEqual(filter.chips(links: links).map(\.label), [
            "Overdue", "With Maya Chen", "Project: Atlas", "From Engineering standup", "Not mentioned in 3 weeks",
        ])
        filter.remove(.person)
        filter.remove(.stale)
        XCTAssertEqual(filter.chips(links: links).map(\.kind), [.due, .project, .meeting])
        XCTAssertTrue(build(threads, filter, links: links).isEmpty)
        XCTAssertEqual(ActionListWording.emptyText(for: filter), "No open actions match these filters.")
        filter.clearFilters()
        XCTAssertFalse(filter.narrowsList)
        XCTAssertEqual(ActionListWording.emptyText(for: filter), "Nothing open. Actions from new meetings show up here.")
    }

    func testStaleReviewListsOpenActionsNobodyMentionedForThreeWeeks() {
        let threads = [
            thread("Fresh action item", meeting: "Standup", daysAgo: 2),
            thread("Stale by a day", meeting: "Design review meeting", daysAgo: 22),
            thread("Stale exactly", meeting: "Engineering standup", daysAgo: 21),
            thread("Almost stale", meeting: "Standup", daysAgo: 20),
            thread("Old but due ahead", meeting: "Planning", daysAgo: 30, due: "2026-11-20"),
            thread("Old and deferred", meeting: "Planning", daysAgo: 40, status: .deferred),
        ]
        XCTAssertEqual(build(threads).staleCount, 2)
        XCTAssertEqual(ActionListWording.staleSummary(count: 2), "2 open actions haven’t been mentioned in 3 weeks.")
        XCTAssertEqual(ActionListWording.staleSummary(count: 1), "1 open action hasn’t been mentioned in 3 weeks.")

        var filter = ActionsListFilter()
        filter.staleOnly = true
        let review = build(threads, filter)
        XCTAssertEqual(review.sections.map(\.title), ["Still open?"])
        XCTAssertEqual(texts(review.sections[0]), ["Stale exactly", "Stale by a day"])
        XCTAssertEqual(review.sections[0].rows.map(\.source), [
            "Engineering standup · last mentioned Oct 20", "Design review meeting · last mentioned Oct 19",
        ])

        // The review is about open work: leaving Open ends it.
        filter.show(.deferred)
        XCTAssertFalse(filter.staleOnly)
        XCTAssertEqual(texts(build(threads, filter).sections[0]), ["Old and deferred"])
        filter.personID = "person:maya"
        filter.show(.done)
        XCTAssertNil(filter.personID, "done actions are outside People and Projects")
    }

    func testSearchCombinesWithFiltersAndReadsTextMeetingAndDuePhrase() {
        let threads = [
            thread("Send the Atlas timeline", meeting: "Atlas planning", daysAgo: 1, due: "after the offsite"),
            thread("Confirm the agenda", meeting: "Atlas planning", daysAgo: 12, due: "2026-11-05"),
            thread("Review the pull request", meeting: "Engineering standup", daysAgo: 0, due: "2026-11-11"),
        ]
        func listed(_ query: String, due: ActionsListFilter.Due = .any) -> [String] {
            var filter = ActionsListFilter()
            filter.query = query
            filter.due = due
            return build(threads, filter).sections.flatMap(\.rows).map(\.thread.text)
        }
        XCTAssertEqual(listed("  atlas "), ["Confirm the agenda", "Send the Atlas timeline"], "text or meeting title")
        XCTAssertEqual(listed("OFFSITE"), ["Send the Atlas timeline"], "the due phrase is searched too")
        XCTAssertEqual(listed("atlas", due: .overdue), ["Confirm the agenda"])
        XCTAssertEqual(listed("pull", due: .overdue), [])
        var filter = ActionsListFilter()
        filter.query = "nothing like this"
        XCTAssertTrue(filter.narrowsList)
        XCTAssertFalse(filter.hasMenuFilters, "a search shows no chip")
    }

    func testAnActionJustChangedStaysListedUntilTheViewChanges() throws {
        let done = thread("Ticked a moment ago", meeting: "Standup", daysAgo: 9, due: "2026-11-05", status: .done,
                          changedDaysAgo: 0)
        let open = thread("Still open item", meeting: "Standup", daysAgo: 1)
        XCTAssertEqual(texts(build([done, open]).sections[0]), ["Still open item"])

        let kept = build([done, open], kept: [done.id])
        XCTAssertEqual(kept.sections.map(\.id), ["overdue", "later"], "the row keeps its place")
        XCTAssertEqual(kept.sections[0].rows.first?.due, .init(text: "Due Thu, Nov 5", tone: .calm),
                       "finished work no longer reads as overdue")
        XCTAssertEqual(kept.openCount, 1)
    }

    // MARK: Wording

    func testDueWording() throws {
        func label(_ due: String?, status: OutcomeStatus = .open) -> ActionsListContent.DueLabel? {
            ActionListWording.dueLabel(
                for: thread("Wording for a due label", meeting: "Standup", daysAgo: 12, due: due, status: status),
                now: now, calendar: calendar, locale: locale)
        }
        XCTAssertEqual(label("2026-11-05"), .init(text: "Was due Thu, Nov 5", tone: .late))
        XCTAssertEqual(label("2026-11-09"), .init(text: "Was due Mon, Nov 9", tone: .late))
        XCTAssertEqual(label("2026-11-10"), .init(text: "Due today", tone: .soon))
        XCTAssertEqual(label("2026-11-11"), .init(text: "Due tomorrow", tone: .soon))
        XCTAssertEqual(label("2026-11-12"), .init(text: "Due Thu, Nov 12", tone: .soon))
        XCTAssertEqual(label("2026-11-17"), .init(text: "Due Tue, Nov 17", tone: .soon))
        XCTAssertEqual(label("2026-11-18"), .init(text: "Due Wed, Nov 18", tone: .calm))
        XCTAssertEqual(label("after the offsite"), .init(text: "Due “after the offsite”", tone: .calm))
        XCTAssertNil(label(nil))
        XCTAssertEqual(label("2026-11-05", status: .deferred), .init(text: "Due Thu, Nov 5", tone: .calm))
        XCTAssertEqual(label("2026-11-10", status: .done), .init(text: "Due today", tone: .calm))

        // A language supplies the words; the date follows its locale.
        let translated = ActionListWording.dueLabel(
            for: thread("Wording in another language", meeting: "Standup", daysAgo: 12, due: "2026-11-05"),
            now: now, calendar: calendar, locale: locale,
            localize: { $0 == "Was due %@" ? "Rok je bio %@" : $0 })
        XCTAssertEqual(translated?.text, "Rok je bio Thu, Nov 5")

        XCTAssertEqual(day(0), "Today")
        XCTAssertEqual(day(1), "Yesterday")
        XCTAssertEqual(day(6), "Wed, Nov 4")
        XCTAssertEqual(day(7), "Nov 3")
        XCTAssertEqual(day(400), "Oct 6, 2025")

        let hint = ActionCompletionHint(
            threadID: "thread", snapshotID: 7,
            capturedAt: try XCTUnwrap(calendar.date(from: DateComponents(
                year: 2026, month: 11, day: 9, hour: 17, minute: 48))),
            app: "Mail", title: "Re: failover", cue: "Message sent")
        // The system puts a narrow no-break space before "PM".
        XCTAssertEqual(ActionListWording.completionHint(hint, calendar: calendar, locale: locale),
                       "Mail showed “Message sent” · Mon 5:48\u{202F}PM")
        XCTAssertEqual(ActionListWording.completionHintSentence(hint, calendar: calendar, locale: locale),
                       "Mail showed “Message sent” on Mon 5:48\u{202F}PM, after this was said.")
        var filter = ActionsListFilter()
        filter.show(.done)
        XCTAssertEqual(ActionListWording.emptyText(for: filter), "Nothing done yet.")
        filter.show(.deferred)
        XCTAssertEqual(ActionListWording.emptyText(for: filter), "Nothing deferred.")
        filter.due = .dated
        XCTAssertEqual(ActionListWording.emptyText(for: filter), "No deferred actions match these filters.")
    }

    func testDetailsSayWhatWasSaidAndSaveCorrectionsOnTheRightMention() throws {
        let older = reference("Draft the eviction policy document", meeting: "Engineering standup", daysAgo: 5,
                              due: "next week")
        let newer = reference("Draft the eviction policy document", meeting: "Design review meeting", daysAgo: 0,
                              due: "by Thursday")
        let twice = try XCTUnwrap(ActionThreadClusterer.cluster([older, newer]).first)
        XCTAssertEqual(ActionDetailsPresentation.mentionsHeading(for: twice), "Said in 2 meetings")
        XCTAssertEqual(ActionDetailsPresentation.dueNote(for: twice), "You said “by Thursday”. Before that, “next week”.")
        XCTAssertEqual(ActionDetailsPresentation.dueTitle(for: twice, calendar: calendar, locale: locale), "Thu, Nov 12")

        let once = thread("Send the Atlas timeline to Sarah", meeting: "Atlas planning", daysAgo: 1,
                          due: "after the offsite")
        XCTAssertEqual(ActionDetailsPresentation.mentionsHeading(for: once), "What was said")
        XCTAssertEqual(ActionDetailsPresentation.dueTitle(for: once, locale: locale), "Pick a date")
        XCTAssertEqual(ActionDetailsPresentation.dueNote(for: once), "You said “after the offsite”.")
        let undated = thread("Unblock the index rebuild", meeting: "Standup", daysAgo: 0)
        XCTAssertEqual(ActionDetailsPresentation.dueTitle(for: undated, locale: locale), "No date")
        XCTAssertNil(ActionDetailsPresentation.dueNote(for: undated))
        let typed = thread("Clean up the feature flags", meeting: "Standup", daysAgo: 3, due: "2026-11-30")
        XCTAssertNil(ActionDetailsPresentation.dueNote(for: typed), "a typed day was not said")

        // A due day goes on the newest mention and leaves other fields alone.
        let friday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 13, hour: 9)))
        XCTAssertEqual(ActionDetailsPresentation.dueCorrection(friday, for: twice, calendar: calendar), .init(
            actionID: newer.action.id, meetingID: newer.meetingID, text: nil, owner: nil, due: "2026-11-13"))
        XCTAssertEqual(ActionDetailsPresentation.dueCorrection(nil, for: twice, calendar: calendar).due, "",
                       "No date is saved as an explicit clear")
        var corrected = newer
        corrected.text = "Draft the eviction policy"
        corrected.textWasCorrected = true
        corrected.owner = "Me"
        corrected.ownerWasCorrected = true
        let kept = try XCTUnwrap(ActionThreadClusterer.cluster([corrected]).first)
        let change = ActionDetailsPresentation.dueCorrection(friday, for: kept, calendar: calendar)
        XCTAssertEqual(change.text, "Draft the eviction policy", "a saved wording is written back unchanged")
        XCTAssertEqual(change.owner, "Me")

        // "Not mine" clears the owner of every mention and nothing else.
        let notMine = ActionDetailsPresentation.notMineCorrections(for: twice)
        XCTAssertEqual(Set(notMine.map(\.meetingID)), [older.meetingID, newer.meetingID])
        XCTAssertTrue(notMine.allSatisfy { $0.owner == "" && $0.text == nil && $0.due == nil })
    }

    func testNotMineAndDueCorrectionsGoThroughTheOutcomeIndex() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("actions-list-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageManager(rootURL: root)
        let meeting = Meeting(id: UUID(), title: "Design review meeting", appName: "Meet",
                              startedAt: now.addingTimeInterval(-3_600), endedAt: now,
                              relativePath: "meetings/design-review")
        let folder = meeting.folderURL(in: storage)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try MeetingOutcomes(actionItems: [
            .init(text: "Draft the eviction policy document", owner: "Me", due: "by Thursday"),
            .init(text: "Unblock the index rebuild today", owner: "Me"),
        ]).write(to: folder)
        let index = OutcomeIndex(storage: storage)
        index.refresh(meetings: [meeting])
        let draft = try XCTUnwrap(index.userActionThreads.first { $0.text.hasPrefix("Draft") })

        let change = ActionDetailsPresentation.dueCorrection(
            try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 20))), for: draft)
        XCTAssertTrue(index.correctAction(actionID: change.actionID, meetingID: change.meetingID,
                                          text: change.text, owner: change.owner, due: change.due))
        let moved = try XCTUnwrap(index.userActionThreads.first { $0.text.hasPrefix("Draft") })
        XCTAssertEqual(moved.due, "2026-11-20")
        XCTAssertFalse(moved.latestReference.textWasCorrected, "choosing a day must not record a wording correction")
        XCTAssertEqual(ActionDetailsPresentation.dueNote(for: moved), "You said “by Thursday”.",
                       "what was said stays beside the corrected day")

        for change in ActionDetailsPresentation.notMineCorrections(for: moved) {
            XCTAssertTrue(index.correctAction(actionID: change.actionID, meetingID: change.meetingID,
                                              text: change.text, owner: change.owner, due: change.due))
        }
        XCTAssertEqual(index.userActionThreads.map(\.text), ["Unblock the index rebuild today"])
        XCTAssertEqual(index.projection(for: meeting.id)?.actionReferences.first { $0.text.hasPrefix("Draft") }?.due,
                       "2026-11-20", "Not mine keeps the corrected day")
    }

    // MARK: Selection

    func testSelectionFollowsClicksModifiersAndArrowKeys() {
        let order = ["a", "b", "c", "d", "e"]
        var selection = ActionListSelection()
        XCTAssertEqual(selection.current(in: order), ["a"], "the first row is selected when the page opens")
        XCTAssertEqual(selection.current(in: []), [])

        selection.click("c", order: order)
        XCTAssertEqual(selection.current(in: order), ["c"])
        selection.click("e", command: true, order: order)
        XCTAssertEqual(selection.current(in: order), ["c", "e"])
        selection.click("c", command: true, order: order)
        XCTAssertEqual(selection.current(in: order), ["e"])
        selection.click("e", command: true, order: order)
        XCTAssertEqual(selection.current(in: order), ["e"], "the last row cannot be deselected")

        selection.click("b", shift: true, order: order)
        XCTAssertEqual(selection.current(in: order), ["b", "c", "d", "e"], "Shift takes the range from the anchor")
        selection.click("d", shift: true, order: order)
        XCTAssertEqual(selection.current(in: order), ["d", "e"])

        // ⌘-click from the implicit first row adds to it.
        var fresh = ActionListSelection()
        fresh.click("c", command: true, order: order)
        XCTAssertEqual(fresh.current(in: order), ["a", "c"])

        selection.click("b", order: order)
        XCTAssertEqual(selection.move(by: 1, order: order), "c")
        XCTAssertEqual(selection.move(by: 1, extending: true, order: order), "d")
        XCTAssertEqual(selection.current(in: order), ["c", "d"])
        XCTAssertEqual(selection.move(by: -1, extending: true, order: order), "c")
        XCTAssertEqual(selection.current(in: order), ["c"])
        XCTAssertEqual(selection.move(by: -1, order: order), "b")
        selection.click("e", order: order)
        XCTAssertEqual(selection.move(by: 1, order: order), "e", "the selection stops at the last row")
        selection.click("a", order: order)
        XCTAssertEqual(selection.move(by: -1, order: order), "a")
        XCTAssertNil(selection.move(by: 1, order: []))

        selection.selectAll(in: order)
        XCTAssertEqual(selection.current(in: order), order)
        selection.collapse(in: order)
        XCTAssertEqual(selection.current(in: order).count, 1)

        // A filter that hides the chosen row shows the first one instead,
        // and the choice returns with the row.
        selection.click("d", order: order)
        XCTAssertEqual(selection.current(in: ["a", "b"]), ["a"])
        XCTAssertEqual(selection.current(in: order), ["d"])
    }

    // MARK: Fixtures

    private func build(_ threads: [ActionThread], _ filter: ActionsListFilter = .init(),
                       links: ActionThreadLinks = .init(), kept: Set<String> = []) -> ActionsListContent {
        // Threads arrive newest meeting first, as the outcome index publishes them.
        let published = threads.sorted {
            $0.latestReference.meetingStartedAt > $1.latestReference.meetingStartedAt
        }
        return ActionsListContent.build(threads: published, filter: filter, links: links, kept: kept, now: now,
                                        calendar: calendar, locale: locale)
    }

    private func texts(_ section: ActionsListContent.Section) -> [String] {
        section.rows.map(\.thread.text)
    }

    private func day(_ daysAgo: Int) -> String {
        ActionListWording.day(date(daysAgo: daysAgo), now: now, calendar: calendar, locale: locale)
    }

    private func date(daysAgo: Int) -> Date {
        calendar.date(byAdding: .day, value: -daysAgo, to: now) ?? now
    }

    private func thread(_ text: String, meeting: String, daysAgo: Int, due: String? = nil,
                        status: OutcomeStatus = .open, changedDaysAgo: Int? = nil,
                        meetingID: UUID = UUID()) -> ActionThread {
        ActionThreadClusterer.cluster([reference(text, meeting: meeting, daysAgo: daysAgo, due: due, status: status,
                                                 changedDaysAgo: changedDaysAgo, meetingID: meetingID)])[0]
    }

    private func reference(_ text: String, meeting: String, daysAgo: Int, due: String? = nil,
                           status: OutcomeStatus = .open, changedDaysAgo: Int? = nil,
                           meetingID: UUID = UUID()) -> OutcomeActionReference {
        let startedAt = date(daysAgo: daysAgo)
        let action = MeetingOutcomes.ActionItem(
            text: text, owner: "Me", due: due,
            citations: [.init(meetingID: meetingID, segmentID: "segment-\(UUID().uuidString)", start: 24, end: 30,
                              speaker: "Me", excerpt: "I’ll " + text.lowercased() + ".")])
        return OutcomeActionReference(
            meetingID: meetingID, meetingTitle: meeting, meetingStartedAt: startedAt, action: action,
            status: status, text: action.displayText, owner: "Me", due: due,
            stateUpdatedAt: changedDaysAgo.map { date(daysAgo: $0) } ?? startedAt,
            textWasCorrected: false, ownerWasCorrected: false, dueWasCorrected: false)
    }

    private func person(_ id: String, _ name: String, members: [String] = [], actions: [ActionThread]) -> PersonProfile {
        PersonProfile(id: id, name: name, otherNames: [], memberIDs: [id] + members, meetings: [],
                      theirActions: [], myActions: actions, decisions: [])
    }

    private func project(_ id: String, _ name: String, tracked: Bool, actions: [ActionThread]) -> ProjectProfile {
        ProjectProfile(id: id, name: name, kind: tracked ? .tracked(UUID()) : .suggestedTopic, otherNames: [],
                       meetings: [], myActions: actions, othersActions: [], olderOthersActions: [], decisions: [],
                       reviewNotes: [], days: [], windows: [], people: [], lastActive: nil)
    }
}
