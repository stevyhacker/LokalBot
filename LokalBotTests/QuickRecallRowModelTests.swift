import XCTest
@testable import LokalBot

final class QuickRecallRowModelTests: XCTestCase {
    func testSavedCaptureUsesItsOwnExcerptAndReplacesItsSourceGroup() {
        let rows = QuickRecallRowModel.screens(
            groups: [
                ScreenRecallGroup(id: "slack", matches: [
                    hit(1, snippet: "The primary «Redis» capture"),
                    hit(2, snippet: "The saved «Redis» decision"),
                ]),
                ScreenRecallGroup(id: "safari", matches: [hit(3, snippet: "«Redis» review")]),
            ],
            savedMoments: [saved(2)], hasQuery: true)

        XCTAssertEqual(rows.map(\.snapshotID), [2, 3])
        XCTAssertTrue(rows[0].isSaved)
        XCTAssertEqual(rows[0].snippet, "The saved «Redis» decision")
        XCTAssertFalse(rows[1].isSaved)
    }

    /// Searching "onboarding" in the demo library listed the saved Slack
    /// moment, related only by meaning, above the one capture with the word.
    func testSemanticOnlySavedCaptureKeepsItsRankBelowTheKeywordMatch() {
        var related = hit(3, snippet: "Redis failover benchmark is booked for Thursday")
        related.isSemantic = true
        let rows = QuickRecallRowModel.screens(
            groups: [
                ScreenRecallGroup(id: "notion", matches: [hit(4, snippet: "Q3 priorities, «onboarding» first")]),
                ScreenRecallGroup(id: "slack", matches: [related]),
            ],
            savedMoments: [saved(3)], hasQuery: true)

        XCTAssertEqual(rows.map(\.snapshotID), [4, 3])
        XCTAssertFalse(rows[0].isSaved)
        XCTAssertTrue(rows[1].isSaved)
        XCTAssertEqual(rows[1].title, "Benchmark decision")
    }

    func testQueryDoesNotIncludeSavedMomentsOutsideSearchMatches() {
        let rows = QuickRecallRowModel.screens(
            groups: [ScreenRecallGroup(id: "match", matches: [hit(1, snippet: "«Redis» review")])],
            savedMoments: [saved(99)], hasQuery: true)

        XCTAssertEqual(rows.map(\.snapshotID), [1])
        XCTAssertFalse(rows[0].isSaved)
    }

    func testEmptyQueryShowsOnlyRecentSavedMoments() {
        let rows = QuickRecallRowModel.screens(
            groups: [ScreenRecallGroup(id: "old-query", matches: [hit(99, snippet: "Old result")])],
            savedMoments: (1...15).map { saved(Int64($0)) }, hasQuery: false)

        XCTAssertEqual(rows.map(\.snapshotID), (1...12).map { Int64($0) })
        XCTAssertTrue(rows.allSatisfy(\.isSaved))
        XCTAssertTrue(rows.allSatisfy { $0.snippet == nil })
    }

    func testSavedAccessibilityValueIncludesStatusWithoutSearchMarkers() {
        let rows = QuickRecallRowModel.screens(
            groups: [ScreenRecallGroup(id: "saved", matches: [hit(1, snippet: "«Redis» decision")])],
            savedMoments: [saved(1)], hasQuery: true)

        XCTAssertEqual(rows[0].accessibilityValue, "Saved. Slack. Redis decision")
    }

    /// Line two of a meeting row starts with who said it, from the search
    /// hit's speaker, or with where the words are when nobody said them.
    func testAMeetingRowStartsItsLineWithWhoSaidIt() {
        let meetingID = UUID()
        let spoken = SearchIndex.Hit(meetingID: meetingID, kind: .segment, start: 760,
                                     snippet: "Every client video ships with «captions».", speaker: "Maya Chen")
        let row = QuickRecallRowModel.meeting(hit: spoken, title: "Accessibility review",
                                              speaker: QuickRecallRowModel.meetingLead(spoken), timestamp: nil)

        XCTAssertEqual(row.id, "meeting.\(meetingID).segment.760.0")
        XCTAssertEqual(row.lead, .symbol("waveform"))
        XCTAssertEqual(row.speaker, "Maya Chen")
        XCTAssertEqual(row.snippet, "Every client video ships with «captions».")
        XCTAssertEqual(row.plainSnippet, "Maya Chen: Every client video ships with captions.")
        XCTAssertEqual(row.accessibilityValue, "Maya Chen: Every client video ships with captions.")
        XCTAssertNil(row.qualifier)
    }

    func testAMeetingLineWithoutASpeakerSaysWhereItIsFrom() {
        func lead(_ kind: SearchIndex.Kind, speaker: String = "") -> String? {
            QuickRecallRowModel.meetingLead(
                SearchIndex.Hit(meetingID: UUID(), kind: kind, start: 0, snippet: "«Atlas»", speaker: speaker),
                localize: { "[\($0)]" })
        }
        XCTAssertNil(lead(.segment), "a transcript line with no speaker starts with its words")
        XCTAssertNil(lead(.segment, speaker: "  "))
        XCTAssertEqual(lead(.segment, speaker: "Them 2"), "Speaker 2")
        XCTAssertEqual(lead(.notes), "[Your notes]")
        XCTAssertEqual(lead(.summary), "[Summary]")
        XCTAssertEqual(lead(.outcome), "[Outcome]")
        XCTAssertNil(lead(.title))
    }

    func testATitleMatchDoesNotRepeatTheTitleAsItsLine() {
        let hit = SearchIndex.Hit(meetingID: UUID(), kind: .title, start: 0,
                                  snippet: "«Atlas» roadmap review", speaker: "")
        let row = QuickRecallRowModel.meeting(hit: hit, title: "Atlas roadmap review", speaker: nil, timestamp: nil)
        XCTAssertNil(row.snippet)
        XCTAssertNil(row.plainSnippet)
    }

    func testAScreenRowNamesItsAppOnceAndAFileRowItsFolderAndPage() {
        let untitled = QuickRecallRowModel.screen(snapshotID: 1, appName: "Pages", title: "Pages",
                                                  snippet: nil, timestamp: Date(timeIntervalSince1970: 0))
        XCTAssertNil(untitled.qualifier, "a window named by its app does not say the app twice")
        XCTAssertEqual(untitled.lead, .thumbnail(1))

        let pdf = FileSearchHit(id: 3, path: "/Users/me/Documents/Atlas/Atlas pilot brief.pdf", kind: .pdf, page: 2,
                                excerpt: "The «Atlas» pilot covers 40 seats.",
                                modified: Date(timeIntervalSince1970: 0), isSemantic: false)
        let row = QuickRecallRowModel.file(pdf, localize: { $0 == "Page %lld" ? "Seite %lld" : $0 })
        XCTAssertEqual(row.lead, .file(path: pdf.path))
        XCTAssertEqual(row.qualifier, pdf.folder)
        XCTAssertEqual(row.speaker, "Seite 2")
        XCTAssertEqual(row.plainSnippet, "Seite 2: The Atlas pilot covers 40 seats.")

        let moment = FileSearchHit(id: 4, path: "/Users/me/Podcasts/sleep.mp3", kind: .audio, seconds: 754,
                                   excerpt: "about «sleep»", modified: Date(timeIntervalSince1970: 0),
                                   isSemantic: false)
        XCTAssertEqual(QuickRecallRowModel.fileLead(moment), Transcript.shortStamp(754))
        let picture = FileSearchHit(id: 5, path: "/Users/me/Pictures/a.png", kind: .image, page: nil,
                                    excerpt: nil, modified: Date(timeIntervalSince1970: 0), isSemantic: true)
        XCTAssertNil(QuickRecallRowModel.file(picture).speaker)
        XCTAssertNil(QuickRecallRowModel.file(picture).snippet)
    }

    private func hit(_ id: Int64, snippet: String) -> ActivityStore.OCRHit {
        ActivityStore.OCRHit(snapshotID: id, ts: Date(timeIntervalSince1970: 1_700_000_000),
                             app: "Slack", windowTitle: "Engineering", snippet: snippet)
    }

    private func saved(_ id: Int64) -> ActivityStore.SavedMoment {
        ActivityStore.SavedMoment(snapshotID: id, ts: Date(timeIntervalSince1970: 1_700_000_000),
                                  path: "", app: "Slack", windowTitle: "Engineering",
                                  trigger: "manual", note: "Benchmark decision", createdAt: Date())
    }
}
