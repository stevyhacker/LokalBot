import XCTest
@testable import LokalBot

final class MeetingSpeakerSuggestionTests: XCTestCase {
    func testCalendarGuestsKeepTheirIdentityAndMatchingHintsDoNotDuplicateThem() throws {
        let guest = try XCTUnwrap(CalendarParticipantIdentity(id: "ana", name: "Ana Petrović", emailAddress: "ana@example.com"))
        let result = MeetingSpeakerSuggestion.choices(calendar: [guest], hints: ["ANA   Petrović"])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.calendar, guest)
        XCTAssertEqual(result.first?.sources, ["Calendar"])
        XCTAssertEqual(result.first?.accessibilityID, "speaker.rename.calendarCandidate.0")
    }

    func testSameNameGuestsWithDifferentEmailsRemainSeparate() throws {
        let guests = try ["alex@one.example", "alex@two.example"].enumerated().map { index, email in
            try XCTUnwrap(CalendarParticipantIdentity(id: "guest-\(index)", name: "Alex Kim", emailAddress: email))
        }
        let result = MeetingSpeakerSuggestion.choices(calendar: guests, hints: ["Alex Kim"])
        XCTAssertEqual(result.compactMap { $0.calendar?.id }, guests.map(\.id))
        XCTAssertEqual(result.map(\.sources), [["Calendar"], ["Calendar"]])
    }

    func testEmailDerivedNameIsLabelled() throws {
        let guest = try XCTUnwrap(CalendarParticipantIdentity(id: "ana", name: nil, emailAddress: "ana.petrovic@example.com"))
        let result = MeetingSpeakerSuggestion.choices(calendar: [guest], hints: [])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].sources, ["Calendar", "Name from email"])
        XCTAssertNil(result[0].calendar?.name)
    }

    func testSimilarHintsDoNotMergeWithAGuest() throws {
        let guest = try XCTUnwrap(CalendarParticipantIdentity(id: "ana", name: "Ana Petrović", emailAddress: "ana@example.com"))
        for name in ["Ana", "Ana Petrovic", "Anna Petrović"] {
            let result = MeetingSpeakerSuggestion.choices(calendar: [guest], hints: [name])
            XCTAssertEqual(result.count, 2, name)
        }
    }

    func testHintsJoinSameListWithoutDuplicatingExistingChoices() throws {
        let guest = try XCTUnwrap(CalendarParticipantIdentity(id: "ana", name: "Ana Petrović", emailAddress: "ana@example.com"))
        let result = MeetingSpeakerSuggestion.choices(calendar: [guest],
            hints: ["Ana Petrović", " Sam Lee ", "sam lee", "", "   "])
        XCTAssertEqual(result.compactMap(\.name), ["Ana Petrović", "Sam Lee"])
        XCTAssertEqual(result[1].sources, ["Suggested name"])
        XCTAssertNil(result[1].calendar)
    }

    func testSearchMatchesEveryQueryWordInNameOrEmailIgnoringCaseAndAccents() throws {
        let guests = try [
            ("ana", "Ana Petrović", "ana@example.com"),
            ("djordje", "Đorđe Ilić", "g.ilic@studio.example"),
            ("room", nil, "room123@example.com"),
        ].map { try XCTUnwrap(CalendarParticipantIdentity(id: $0.0, name: $0.1, emailAddress: $0.2)) }
        let choices = MeetingSpeakerSuggestion.choices(calendar: guests, hints: ["Sam Lee"])
        func search(_ query: String) -> [String] {
            choices.filter { $0.matches(query) }.map(\.id)
        }

        XCTAssertEqual(search(""), choices.map(\.id))
        XCTAssertEqual(search("   "), choices.map(\.id))
        XCTAssertEqual(search("PETROVIC"), ["calendar:ana"])
        XCTAssertEqual(search("petrovic ana"), ["calendar:ana"], "word order does not matter")
        XCTAssertEqual(search("ana sam"), [], "every word must match the same suggestion")
        XCTAssertEqual(search("dorde"), ["calendar:djordje"])
        XCTAssertEqual(search("djordje"), ["calendar:djordje"])
        XCTAssertEqual(search("Đorđe"), ["calendar:djordje"])
        XCTAssertEqual(search("studio"), ["calendar:djordje"], "email addresses are searchable")
        XCTAssertEqual(search("room123"), ["calendar:room"], "unnamed mailboxes stay findable")
        XCTAssertEqual(search("lee"), ["hint:sam lee"])
        XCTAssertEqual(search("zoe"), [])
    }

    func testUnnamedMailboxRemainsSelectableAndOrderHasStableIDs() throws {
        let guest = try XCTUnwrap(CalendarParticipantIdentity(id: "room", name: nil, emailAddress: "room123@example.com"))
        let first = MeetingSpeakerSuggestion.choices(calendar: [guest], hints: [])
        let second = MeetingSpeakerSuggestion.choices(calendar: [guest], hints: [])
        XCTAssertEqual(first.map(\.id), second.map(\.id))
        XCTAssertEqual(first.first?.calendar?.emailAddress, "room123@example.com")
        XCTAssertNil(first.first?.name)
    }
}
