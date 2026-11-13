import XCTest
@testable import LokalBot

final class MeetingGenerationContextTests: XCTestCase {
    func testAgendaDropsJoiningDetailsLinksAddressesAndMarkup() throws {
        let notes = """
        <p>Agenda:</p><ul><li>Q3 pricing tiers</li><li>Launch checklist review</li></ul>
        ────────────────────────
        Join Zoom Meeting
        https://example.zoom.us/j/123456789?pwd=abc
        Meeting ID: 123 4567 8901
        Passcode: 424242
        +1 646 558 8656 US (New York)
        Questions? ana.petrovic@example.com
        """
        let agenda = try XCTUnwrap(CalendarAgenda.sanitize(notes))
        XCTAssertTrue(agenda.contains("Q3 pricing tiers"))
        XCTAssertTrue(agenda.contains("Launch checklist review"))
        XCTAssertFalse(agenda.contains("zoom"))
        XCTAssertFalse(agenda.contains("Passcode"))
        XCTAssertFalse(agenda.contains("646"))
        XCTAssertFalse(agenda.contains("@"))
        XCTAssertNil(CalendarAgenda.sanitize("https://meet.google.com/abc-defg-hij"))
        XCTAssertNil(CalendarAgenda.sanitize(nil))
    }

    func testBlockUsesNamesAgendaAndTitlesOnlyWhenEnabled() throws {
        var meeting = Meeting(id: UUID(), title: "Pricing", appName: "Meet", startedAt: Date(),
                              endedAt: Date(), relativePath: "meetings/pricing")
        meeting.calendarTitle = "Q3 pricing review"
        meeting.calendarParticipantIdentities = [
            try XCTUnwrap(CalendarParticipantIdentity(name: "Ana Petrović", emailAddress: "ana@example.com")),
            try XCTUnwrap(CalendarParticipantIdentity(name: nil, emailAddress: "vendor@example.com")),
        ]
        meeting.calendarAgenda = "Q3 pricing tiers\nLaunch checklist"

        let full = try XCTUnwrap(MeetingGenerationContext.block(
            for: meeting, screenTitles: ["Q3 pricing.key (Keynote)"],
            options: .init(includeCalendar: true, includeAgenda: true, includeScreenTitles: true)))
        XCTAssertTrue(full.contains("Scheduled title: Q3 pricing review"))
        XCTAssertTrue(full.contains("Ana Petrović"))
        XCTAssertTrue(full.contains("Launch checklist"))
        XCTAssertTrue(full.contains("Q3 pricing.key (Keynote)"))
        XCTAssertTrue(full.contains("Never create decisions, actions"))
        XCTAssertFalse(full.contains("@"))
        XCTAssertFalse(full.localizedCaseInsensitiveContains("vendor"))

        let calendarOnly = try XCTUnwrap(MeetingGenerationContext.block(
            for: meeting, screenTitles: ["Deck"],
            options: .init(includeCalendar: true, includeAgenda: false, includeScreenTitles: false)))
        XCTAssertFalse(calendarOnly.contains("Launch checklist"))
        XCTAssertFalse(calendarOnly.contains("Deck"))

        XCTAssertNil(MeetingGenerationContext.block(
            for: meeting, screenTitles: [],
            options: .init(includeCalendar: false, includeAgenda: false, includeScreenTitles: true)))
    }
}
