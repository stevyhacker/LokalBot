import XCTest
@testable import LokalBot

final class MeetingSpeakerSuggestionTests: XCTestCase {
    func testMatchingSuppliedNamesShareOneChoiceAndPreserveCalendarIdentity() throws {
        let guest = try XCTUnwrap(CalendarParticipantIdentity(id: "ana", name: "Ana Petrović", emailAddress: "ana@example.com"))
        let result = MeetingSpeakerSuggestion.choices(calendar: [guest],
            participants: [.init(name: "ANA   Petrović", source: .accessibility)], hints: ["Ana Petrović"])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.calendar, guest)
        XCTAssertEqual(result.first?.sources, ["Meet", "Calendar"])
        XCTAssertEqual(result.first?.accessibilityID, "speaker.rename.calendarCandidate.0")
    }

    func testSameNameGuestsWithDifferentEmailsRemainSeparateFromMeetSuggestion() throws {
        let guests = try ["alex@one.example", "alex@two.example"].enumerated().map { index, email in
            try XCTUnwrap(CalendarParticipantIdentity(id: "guest-\(index)", name: "Alex Kim", emailAddress: email))
        }
        let result = MeetingSpeakerSuggestion.choices(calendar: guests,
            participants: [.init(name: "Alex Kim", source: .accessibility)], hints: ["Alex Kim"])
        XCTAssertEqual(result.count, 3)
        XCTAssertNil(result[0].calendar)
        XCTAssertEqual(result.compactMap { $0.calendar?.id }, guests.map(\.id))
        XCTAssertEqual(result.map(\.sources), [["Meet"], ["Calendar"], ["Calendar"]])
    }

    func testEmailDerivedNameDoesNotCombineWithObservedName() throws {
        let guest = try XCTUnwrap(CalendarParticipantIdentity(id: "ana", name: nil, emailAddress: "ana.petrovic@example.com"))
        let result = MeetingSpeakerSuggestion.choices(calendar: [guest],
            participants: [.init(name: "Ana Petrovic", source: .accessibility)], hints: [])
        XCTAssertEqual(result.count, 2)
        XCTAssertNil(result[0].calendar)
        XCTAssertEqual(result[1].sources, ["Calendar", "Name from email"])
        XCTAssertNil(result[1].calendar?.name)
    }

    func testEmailGuessMakesOtherwiseMatchingCalendarChoiceAmbiguous() throws {
        let guests = try [
            XCTUnwrap(CalendarParticipantIdentity(id: "named", name: "Alex Kim", emailAddress: "alex@one.example")),
            XCTUnwrap(CalendarParticipantIdentity(id: "guessed", name: nil, emailAddress: "alex.kim@two.example")),
        ]
        let result = MeetingSpeakerSuggestion.choices(calendar: guests,
            participants: [.init(name: "Alex Kim", source: .accessibility)], hints: [])
        XCTAssertEqual(result.count, 3)
        XCTAssertNil(result[0].calendar)
    }

    func testHistoricalOCRAndSelfAreNotLinkedToRemoteCalendarGuests() throws {
        let guest = try XCTUnwrap(CalendarParticipantIdentity(id: "ana", name: "Ana Petrović", emailAddress: "ana@example.com"))
        for participant in [MeetingParticipantName(name: "Ana Petrović", source: .ocr),
                            .init(name: "Ana Petrović", source: .accessibility, isSelf: true)] {
            let result = MeetingSpeakerSuggestion.choices(calendar: [guest], participants: [participant], hints: [])
            XCTAssertEqual(result.count, 2)
            XCTAssertNil(result[0].calendar)
            XCTAssertEqual(result[0].sources, participant.isSelf ? ["Meet", "You"] : ["Screen"])
        }
    }

    func testSimilarNamesDoNotMerge() throws {
        let guest = try XCTUnwrap(CalendarParticipantIdentity(id: "ana", name: "Ana Petrović", emailAddress: "ana@example.com"))
        for name in ["Ana", "Ana Petrovic", "Anna Petrović"] {
            let result = MeetingSpeakerSuggestion.choices(calendar: [guest],
                participants: [.init(name: name, source: .accessibility)], hints: [])
            XCTAssertEqual(result.count, 2, name)
        }
    }

    func testHintsJoinSameListWithoutDuplicatingExistingChoices() throws {
        let guest = try XCTUnwrap(CalendarParticipantIdentity(id: "ana", name: "Ana Petrović", emailAddress: "ana@example.com"))
        let result = MeetingSpeakerSuggestion.choices(calendar: [guest], participants: [],
            hints: ["Ana Petrović", " Sam Lee ", "sam lee", "", "   "])
        XCTAssertEqual(result.compactMap(\.name), ["Ana Petrović", "Sam Lee"])
        XCTAssertEqual(result[1].sources, ["Suggested name"])
        XCTAssertNil(result[1].calendar)
    }

    func testUnnamedMailboxRemainsSelectableAndOrderHasStableIDs() throws {
        let guest = try XCTUnwrap(CalendarParticipantIdentity(id: "room", name: nil, emailAddress: "room123@example.com"))
        let first = MeetingSpeakerSuggestion.choices(calendar: [guest], participants: [], hints: [])
        let second = MeetingSpeakerSuggestion.choices(calendar: [guest], participants: [], hints: [])
        XCTAssertEqual(first.map(\.id), second.map(\.id))
        XCTAssertEqual(first.first?.calendar?.emailAddress, "room123@example.com")
        XCTAssertNil(first.first?.name)
    }
}
