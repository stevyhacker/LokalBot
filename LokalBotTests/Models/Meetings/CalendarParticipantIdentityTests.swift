import XCTest
@testable import LokalBot

final class CalendarParticipantIdentityTests: XCTestCase {
    func testMissingCalendarNamesOfferEditableEmailSuggestionsWithoutChangingMetadata() throws {
        for (address, expected) in [
            ("ana@example.com", "Ana"),
            ("ana.petrovic+meetings@example.com", "Ana Petrovic"),
            ("alex_kim@example.com", "Alex Kim"),
            ("jean-luc@example.com", "Jean Luc"),
        ] {
            let guest = try XCTUnwrap(CalendarParticipantIdentity(id: "guest", name: nil, emailAddress: address))
            XCTAssertEqual(guest.suggestedSpeakerName, expected)
            XCTAssertNil(guest.name)
            let encoded = try JSONEncoder().encode(guest)
            let restored = try JSONDecoder().decode(CalendarParticipantIdentity.self, from: encoded)
            XCTAssertEqual(restored, guest)
            XCTAssertNil(restored.name)
            XCTAssertEqual(restored.suggestedSpeakerName, expected)
            XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("suggestedSpeakerName"))
        }
    }

    func testDisplayNamesWinAndAmbiguousMailboxHandlesNeedManualNames() throws {
        let named = try XCTUnwrap(CalendarParticipantIdentity(name: "Ana Petrović", emailAddress: "alias@example.com"))
        XCTAssertEqual(named.suggestedSpeakerName, "Ana Petrović")
        for address in ["support@example.com", "no-reply@example.com", "room123@example.com",
                        "a9b81c7d@example.com", "a@example.com", "person=alias@example.com"] {
            let guest = try XCTUnwrap(CalendarParticipantIdentity(name: nil, emailAddress: address))
            XCTAssertNil(guest.suggestedSpeakerName, address)
        }
    }

    func testSameSuggestedNameDoesNotMergeDistinctGuests() throws {
        let first = try XCTUnwrap(CalendarParticipantIdentity(id: "one", name: nil, emailAddress: "ana@one.example"))
        let second = try XCTUnwrap(CalendarParticipantIdentity(id: "two", name: nil, emailAddress: "ana@two.example"))
        let guests = CalendarParticipantIdentity.normalized([first, second])
        XCTAssertEqual(guests.map(\.suggestedSpeakerName), ["Ana", "Ana"])
        XCTAssertEqual(guests.map(\.id), ["one", "two"])
    }

    func testExtractsAndNormalizesMailtoAddress() {
        XCTAssertEqual(
            CalendarParticipantIdentity.emailAddress(
                from: URL(string: "mailto:Ana.Petrovic%2BMeetings@Example.COM?subject=Hello")),
            "ana.petrovic+meetings@example.com")
        XCTAssertNil(CalendarParticipantIdentity.emailAddress(
            from: URL(string: "urn:uuid:participant-123")))
    }

    func testDeduplicatesByEmailAndPrefersAvailableName() throws {
        let emailOnly = try XCTUnwrap(CalendarParticipantIdentity(
            id: "first",
            name: nil,
            emailAddress: "ANA@example.com"))
        let named = try XCTUnwrap(CalendarParticipantIdentity(
            id: "second",
            name: " Ana Petrović ",
            emailAddress: "ana@example.com"))

        let result = CalendarParticipantIdentity.normalized([emailOnly, named])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.id, "first")
        XCTAssertEqual(result.first?.name, "Ana Petrović")
        XCTAssertEqual(result.first?.emailAddress, "ana@example.com")
    }

    func testSameNameWithDifferentEmailsRemainsDistinct() throws {
        let first = try XCTUnwrap(CalendarParticipantIdentity(
            id: "first", name: "Alex Kim", emailAddress: "alex@one.example"))
        let second = try XCTUnwrap(CalendarParticipantIdentity(
            id: "second", name: "Alex Kim", emailAddress: "alex@two.example"))

        XCTAssertEqual(CalendarParticipantIdentity.normalized([first, second]).count, 2)
    }

    func testLegacyNameIdentityIsStableAcrossLoads() {
        let first = CalendarParticipantIdentity.fromLegacyNames(["Ana Petrović"])
        let second = CalendarParticipantIdentity.fromLegacyNames(["Ana Petrović"])

        XCTAssertEqual(first.map(\.id), second.map(\.id))
    }

    func testMeetingMetadataRoundTripsStructuredCalendarIdentities() throws {
        var meeting = Meeting(
            id: UUID(),
            title: "Design review",
            appName: "Zoom",
            startedAt: Date(timeIntervalSince1970: 1_000),
            endedAt: Date(timeIntervalSince1970: 2_000),
            relativePath: "meetings/2026/08/28-design-review")
        meeting.calendarParticipantIdentities = [try XCTUnwrap(
            CalendarParticipantIdentity(
                id: "fixture-ana",
                name: "Ana Petrović",
                emailAddress: "ana@example.com"))]

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Meeting.self, from: encoder.encode(meeting))

        XCTAssertEqual(decoded.resolvedCalendarParticipantIdentities, [
            try XCTUnwrap(CalendarParticipantIdentity(
                id: "fixture-ana",
                name: "Ana Petrović",
                emailAddress: "ana@example.com")),
        ])
    }
}
