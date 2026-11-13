import XCTest
@testable import LokalBot

/// Effective states for the optional context grants, and the rehearsal's
/// account of which sources a suggestion used.
final class CotypingContextReportTests: XCTestCase {
    private typealias Availability = CotypingContextAvailability
    private typealias Inventory = CotypingContextAvailability.Inventory

    private func settings(visible: Bool = false, meetings: Bool = false, screen: Bool = false,
                          autocomplete: Bool = true) -> AppSettings {
        var settings = AppSettings()
        settings.cotypingEnabled = autocomplete
        settings.cotypingUseVisibleContext = visible
        settings.cotypingUseMeetingMemory = meetings
        settings.cotypingUseScreenMemory = screen
        return settings
    }

    private func availability(_ settings: AppSettings, accessibility: Bool = true,
                              inventory: Inventory = .init()) -> Availability {
        Availability(settings: settings, accessibilityGranted: accessibility, inventory: inventory)
    }

    func testGrantsThatAreOffSayNothing() {
        let state = availability(settings())
        XCTAssertEqual(state.visibleText, .off)
        XCTAssertEqual(state.meetingMemory, .off)
        XCTAssertEqual(state.screenMemory, .off)
        XCTAssertNil(state.screenMemory.message)
    }

    func testVisibleTextNamesTheMissingPrerequisite() {
        XCTAssertEqual(availability(settings(visible: true, autocomplete: false)).visibleText,
                       .unavailable("Unavailable: autocomplete is off."))
        XCTAssertEqual(availability(settings(visible: true), accessibility: false).visibleText,
                       .unavailable("Unavailable: Accessibility permission is needed to read nearby text."))
        guard case .available = availability(settings(visible: true)).visibleText else {
            return XCTFail("visible text should be available")
        }
    }

    func testMeetingMemoryStates() {
        let on = settings(meetings: true)
        XCTAssertEqual(availability(on, inventory: .init(libraryReady: false, recentMeetings: 4)).meetingMemory,
                       .unavailable("Unavailable: the library is still loading."))
        guard case .nothingSaved = availability(on).meetingMemory else {
            return XCTFail("an empty library has nothing to use")
        }
        XCTAssertEqual(availability(on, inventory: .init(recentMeetings: 12, meetingFacts: 1)).meetingMemory,
                       .available("Available: 12 meetings and 1 saved fact from the last 90 days."))
        XCTAssertEqual(availability(on, inventory: .init(recentMeetings: 1)).meetingMemory,
                       .available("Available: 1 meeting from the last 90 days."))
    }

    /// The switch used to look active while Overnight review, turned off,
    /// silently kept it from doing anything.
    func testScreenMemoryIsAvailableWhileOvernightReviewIsOff() {
        let state = availability(settings(screen: true),
                                 inventory: .init(screenFacts: 2, overnightReviewOn: false)).screenMemory
        XCTAssertEqual(state, .available("Available: 2 saved facts from the last 90 days."))
    }

    func testScreenMemoryNamesTheOtherGrantMixedFactsNeed() {
        let mixed = Inventory(mixedFacts: 3)
        XCTAssertEqual(availability(settings(screen: true), inventory: mixed).screenMemory,
                       .unavailable("Unavailable: the 3 saved facts also draw on meetings. Turn on Use meeting and work memory."))
        XCTAssertEqual(availability(settings(meetings: true, screen: true), inventory: mixed).screenMemory,
                       .available("Available: 3 saved facts from the last 90 days."))
        XCTAssertEqual(availability(settings(screen: true), inventory: .init(screenFacts: 1, mixedFacts: 2)).screenMemory,
                       .available("Available: 1 saved fact from the last 90 days. 2 more also draw on meetings and need Use meeting and work memory."))
    }

    func testNothingSavedSaysWhetherMoreIsComing() {
        let reviewing = availability(settings(screen: true)).screenMemory
        let stopped = availability(settings(screen: true), inventory: .init(overnightReviewOn: false)).screenMemory
        XCTAssertEqual(reviewing, .nothingSaved(
            "Nothing to use yet: no screen-derived work memory is saved. Overnight review adds it."))
        XCTAssertEqual(stopped, .nothingSaved(
            "Nothing to use yet: no screen-derived work memory is saved, and Overnight review is off, so none is being added."))
    }

    func testInventoryCountsOnlyWhatRetrievalCouldRead() {
        let now = Date(timeIntervalSince1970: 1_791_000_000)
        func meeting(daysAgo: Double, ended: Bool = true) -> Meeting {
            let start = now.addingTimeInterval(-daysAgo * 86_400)
            return Meeting(id: UUID(), title: "Sync", appName: "Zoom", startedAt: start,
                           endedAt: ended ? start.addingTimeInterval(1800) : nil, relativePath: "meetings/x")
        }
        let today = DreamDay.key(for: now)
        func project(_ name: String, _ kinds: [DreamEvidenceSource.Kind], day: String) -> DreamMemory.Project {
            .init(name: name, status: "active", lastActiveDay: day,
                  provenance: .init(sources: kinds.map { .init(kind: $0, id: day, dayKey: day) }, revision: 0))
        }
        let memory = DreamMemory(updatedAt: now, activeProjects: [
            project("Atlas", [.meeting], day: today),
            project("Borealis", [.screenDay], day: today),
            project("Cedar", [.digest], day: today),
            project("Stale", [.screenDay], day: "2026-01-02"),
            .init(name: "Legacy", status: "unattributed", lastActiveDay: today),
        ])
        let inventory = Inventory(
            meetings: [meeting(daysAgo: 2), meeting(daysAgo: 200), meeting(daysAgo: 1, ended: false)],
            memory: memory, libraryReady: true, overnightReviewOn: false, now: now)
        XCTAssertEqual(inventory, Inventory(recentMeetings: 1, meetingFacts: 1, screenFacts: 1,
                                            mixedFacts: 1, overnightReviewOn: false))
    }

    func testRehearsalReportsWhatASuggestionUsed() {
        let state = availability(settings(visible: true, meetings: true),
                                 inventory: .init(recentMeetings: 3))
        let before = CotypingContextStatus.rehearsal(availability: state, use: nil)
        XCTAssertEqual(before.map(\.id), ["visible", "meetings", "screen"])
        XCTAssertEqual(before.map(\.tone), [.ready, .ready, .off])
        XCTAssertEqual(before[2].detail, "Off")

        let selection = CotypingMemoryContext.Selection(items: [
            .init(id: "a", title: "Atlas launch", text: "Atlas owner is Priya.", updatedAt: Date(),
                  requiresMeetings: true),
        ])
        let used = CotypingContextStatus.rehearsal(
            availability: state,
            use: .init(visibleText: true, selection: selection, searchedMemory: true))
        XCTAssertEqual(used[0].detail, "Used the sample conversation above.")
        XCTAssertEqual(used[1].detail, "Used: Atlas launch")
        XCTAssertEqual(used.map(\.tone), [.used, .used, .off])

        let nothing = CotypingContextStatus.rehearsal(
            availability: state, use: .init(visibleText: true, searchedMemory: true))
        XCTAssertEqual(nothing[1].detail, "No relevant memory found.")
        XCTAssertEqual(nothing[1].tone, .ready)
    }

    func testRehearsalKeepsAnUnavailableSourceVisible() {
        let state = availability(settings(visible: true, screen: true, autocomplete: false))
        let rows = CotypingContextStatus.rehearsal(availability: state, use: .init(visibleText: true))
        XCTAssertEqual(rows[0].detail,
                       "Used the sample conversation above. In other apps: Unavailable: autocomplete is off.")
        XCTAssertEqual(rows[0].tone, .attention)
        XCTAssertEqual(rows[2].tone, .attention)
        XCTAssertTrue(rows[2].detail.hasPrefix("Nothing to use yet"))
    }

    func testMixedFactsAreAttributedToBothGrants() {
        let selection = CotypingMemoryContext.Selection(items: [
            .init(id: "mixed", title: "Cedar", text: "Cedar ships Friday.", updatedAt: Date(),
                  requiresMeetings: true, requiresScreenMemory: true, isWorkMemory: true),
            .init(id: "screen", title: "Borealis", text: "Borealis pricing page.", updatedAt: Date(),
                  requiresMeetings: false, requiresScreenMemory: true, isWorkMemory: true),
        ])
        let use = CotypingContextUse(selection: selection, searchedMemory: true)
        XCTAssertEqual(use.meetingSources, ["Cedar"])
        XCTAssertEqual(use.screenSources, ["Borealis", "Cedar"])
    }

    // MARK: - Sample conversation

    func testSampleConversationIsSelectedTheWayNearbyTextIs() throws {
        let snapshot = try XCTUnwrap(CotypingRehearsalConversation.snapshot())
        XCTAssertEqual(snapshot.excerpts.map(\.text), CotypingRehearsalConversation.sample.map(\.line))
        XCTAssertTrue(try XCTUnwrap(snapshot.text).contains("migration timeline"))
    }

    func testSampleConversationKeepsTheLiveLimitsAndFilters() throws {
        typealias Message = CotypingRehearsalConversation.Message
        let many = (1...6).map { Message(sender: "Sarah", text: "Note number \($0) about the plan.") }
        let nearest = try XCTUnwrap(CotypingRehearsalConversation.snapshot(of: many))
        XCTAssertEqual(nearest.excerpts.count, CotypingVisibleContext.maximumExcerpts)
        XCTAssertEqual(nearest.excerpts.last?.text, "Sarah: Note number 6 about the plan.")

        let secret = [Message(sender: "Sarah", text: "The password is hunter2."),
                      Message(sender: "Sarah", text: "Daniel starts on Thursday.")]
        let filtered = try XCTUnwrap(CotypingRehearsalConversation.snapshot(of: secret))
        XCTAssertEqual(filtered.excerpts.map(\.text), ["Sarah: Daniel starts on Thursday."])
    }
}
