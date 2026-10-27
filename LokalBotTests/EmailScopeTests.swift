import XCTest
@testable import LokalBot

final class EmailScopeTests: XCTestCase {
    private let now = GmailFixtures.now
    private var windowStart: Date { EmailScope.windowStart(now: now) }

    private func message(_ id: String, from: String, labels: [String] = ["INBOX"], daysAgo: Double = 1,
                         to: String = GmailFixtures.me, headers: [String: String] = [:],
                         plain: String? = "Hello", html: String? = nil) -> FakeGmailMessage {
        FakeGmailMessage(id: id, labels: labels, date: now.addingTimeInterval(-daysAgo * 86_400), from: from,
                         to: to, extraHeaders: headers, plain: plain, html: html)
    }

    private func resource(_ messages: [FakeGmailMessage], format: GmailClient.ThreadFormat = .metadata) throws
        -> GmailThreadResource {
        let json = GmailFixtures.json(["id": "t1", "messages": messages.map { $0.resource(threadID: "t1", format: format) }])
        return try JSONDecoder().decode(GmailThreadResource.self, from: json)
    }

    // MARK: Searches

    func testSearchesUseEpochSecondsAndSkipBulkTabs() {
        let after = Date(timeIntervalSince1970: 1_792_224_000)
        XCTAssertEqual(EmailScope.sentQuery(after: after), "in:sent after:1792224000")
        let searches = EmailScope.participantSearches(addresses: ["ana@x.com", "bad address@x.com", "{evil}@x.com"],
                                                      after: after)
        XCTAssertEqual(searches, [EmailScope.ParticipantSearch(
            query: "{from:ana@x.com to:ana@x.com cc:ana@x.com} after:1792224000"
                + " -category:promotions -category:social -category:updates -category:forums",
            addresses: ["ana@x.com"])])
    }

    func testParticipantSearchesAreChunked() {
        let addresses = Set((0..<31).map { "person\($0)@example.com" })
        let searches = EmailScope.participantSearches(addresses: addresses, after: now)
        XCTAssertEqual(searches.map(\.addresses.count), [15, 15, 1])
        XCTAssertEqual(searches.map { $0.query.components(separatedBy: "from:").count - 1 }, [15, 15, 1])
        XCTAssertEqual(searches.reduce(into: Set<String>()) { $0.formUnion($1.addresses) }, addresses)
    }

    // MARK: Who counts

    func testRobotsAndCalendarResourcesAreNotPeople() {
        let attendees: Set<String> = [
            "Ana@Example.com", "noreply@zoom.us", "c_1888abc@resource.calendar.google.com",
            "team-x@group.calendar.google.com", GmailFixtures.me, "calendar-notification@google.com",
        ]
        XCTAssertEqual(EmailScope.knownPeople(attendees, excluding: [GmailFixtures.me, GmailFixtures.alias]),
                       ["ana@example.com"])
    }

    func testBulkSignals() throws {
        let human = try resource([message("1", from: "Ana <ana@x.com>")]).messages![0]
        XCTAssertFalse(EmailScope.isBulk(human))
        for (labels, headers, from) in [
            (["CATEGORY_PROMOTIONS"], [String: String](), "ana@x.com"),
            (["INBOX"], ["List-Unsubscribe": "<mailto:u@x.com>"], "ana@x.com"),
            (["INBOX"], ["Precedence": "bulk"], "ana@x.com"),
            (["INBOX"], ["Auto-Submitted": "auto-generated"], "ana@x.com"),
            (["INBOX"], [:], "Shop <no-reply@shop.example>"),
        ] {
            let bulk = try resource([message("1", from: from, labels: labels, headers: headers)]).messages![0]
            XCTAssertTrue(EmailScope.isBulk(bulk), "\(labels) \(headers) \(from)")
        }
        let reply = try resource([message("1", from: "ana@x.com", headers: ["Auto-Submitted": "no"])]).messages![0]
        XCTAssertFalse(EmailScope.isBulk(reply))
    }

    // MARK: Qualifying

    func testThreadsYouWroteInAlwaysQualify() throws {
        let thread = try resource([
            message("1", from: "news@shop.example", labels: ["CATEGORY_PROMOTIONS"]),
            message("2", from: GmailFixtures.alias, labels: ["SENT"], to: "news@shop.example"),
        ])
        XCTAssertTrue(EmailScope.qualifies(thread, people: [], windowStart: windowStart))
    }

    func testCalendarPeopleQualifyOnlyOutsideBulkMail() throws {
        let known: Set<String> = ["ana@x.com"]
        XCTAssertTrue(EmailScope.qualifies(try resource([message("1", from: "Ana <ana@x.com>")]),
                                           people: known, windowStart: windowStart))
        XCTAssertTrue(EmailScope.qualifies(try resource([message("1", from: "bob@y.com", to: "ana@x.com, me@example.com")]),
                                           people: known, windowStart: windowStart))
        XCTAssertFalse(EmailScope.qualifies(try resource([message("1", from: "ana@x.com", labels: ["CATEGORY_UPDATES"])]),
                                            people: known, windowStart: windowStart))
        XCTAssertFalse(EmailScope.qualifies(try resource([message("1", from: "stranger@z.com")]),
                                            people: known, windowStart: windowStart))
    }

    func testNeverReadLabelsAndOldMailDoNotQualify() throws {
        let known: Set<String> = ["ana@x.com"]
        for labels in [["SPAM"], ["TRASH"], ["DRAFT", "SENT"]] {
            XCTAssertFalse(EmailScope.qualifies(try resource([message("1", from: GmailFixtures.me, labels: labels,
                                                                      to: "ana@x.com")]),
                                                people: known, windowStart: windowStart), "\(labels)")
        }
        XCTAssertFalse(EmailScope.qualifies(try resource([message("1", from: GmailFixtures.me, labels: ["SENT"],
                                                                  daysAgo: 91)]),
                                            people: known, windowStart: windowStart))
    }

    func testASpoofedFromHeaderIsNotTheOwner() throws {
        // Anyone can put the person's own address in From; only SENT counts.
        let spoofed = try resource([message("1", from: "Me <\(GmailFixtures.me)>")])
        XCTAssertFalse(EmailScope.qualifies(spoofed, people: [], windowStart: windowStart))
        let stored = try XCTUnwrap(EmailScope.thread(
            from: try resource([message("1", from: GmailFixtures.me)], format: .full),
            accountID: UUID(), windowStart: windowStart))
        XCTAssertFalse(stored.messages[0].fromMe)
    }

    func testAStoredThreadMustStillQualifyOnItsOwn() {
        func stored(_ from: String, fromMe: Bool = false, bulk: Bool = false) -> EmailThread {
            EmailThread(id: "t", accountID: UUID(), subject: "s", messages: [
                EmailMessage(id: "m", internetMessageID: nil, date: now, from: EmailAddress(name: nil, address: from),
                             to: [EmailAddress(name: nil, address: GmailFixtures.me)], cc: [], subject: "s",
                             fromMe: fromMe, isBulk: bulk, body: "", attachments: []),
            ])
        }
        let people: Set<String> = ["ana@x.com"]
        XCTAssertTrue(EmailScope.stillQualifies(stored(GmailFixtures.me, fromMe: true, bulk: true), people: people))
        XCTAssertTrue(EmailScope.stillQualifies(stored("ana@x.com"), people: people))
        XCTAssertFalse(EmailScope.stillQualifies(stored("ana@x.com", bulk: true), people: people))
        XCTAssertFalse(EmailScope.stillQualifies(stored("stranger@z.com"), people: people))
    }

    // MARK: Building what is stored

    func testStoredThreadKeepsOnlyWindowMessagesInOrder() throws {
        var attached = message("3", from: "Ana Petrović <ana@x.com>", daysAgo: 1, plain: "Final numbers attached.")
        attached.attachment = ("budget.xlsx", "application/vnd.ms-excel", 18_000)
        attached.subject = "Re: Budget"
        let resource = try resource([
            attached,
            message("1", from: "ana@x.com", daysAgo: 120, plain: "Too old"),
            message("2", from: GmailFixtures.me, labels: ["SENT"], daysAgo: 2, to: "ana@x.com",
                    plain: nil, html: "<p>Can you send the <b>budget</b>?</p>"),
            message("4", from: "ana@x.com", labels: ["TRASH"], daysAgo: 1),
        ], format: .full)
        let accountID = UUID()

        let thread = try XCTUnwrap(EmailScope.thread(from: resource, accountID: accountID, windowStart: windowStart))

        XCTAssertEqual(thread.messages.map(\.id), ["2", "3"])
        XCTAssertEqual(thread.accountID, accountID)
        XCTAssertTrue(thread.messages[0].fromMe)
        XCTAssertEqual(thread.messages[0].body, "Can you send the budget?")
        XCTAssertEqual(thread.messages[1].from, EmailAddress(name: "Ana Petrović", address: "ana@x.com"))
        XCTAssertEqual(thread.messages[1].body, "Final numbers attached.")
        XCTAssertEqual(thread.messages[1].attachments,
                       [EmailAttachment(name: "budget.xlsx", mimeType: "application/vnd.ms-excel", size: 18_000)])
        XCTAssertEqual(thread.messages[1].internetMessageID, "<3@mail.example.com>")
        XCTAssertEqual(thread.participantAddresses, ["ana@x.com", GmailFixtures.me])
    }

    func testBodiesAreCapped() throws {
        let long = String(repeating: "a", count: EmailScope.maxBodyCharacters + 500)
        let resource = try resource([message("1", from: "ana@x.com", plain: long)], format: .full)
        let thread = try XCTUnwrap(EmailScope.thread(from: resource, accountID: UUID(), windowStart: windowStart))
        XCTAssertEqual(thread.messages[0].body.count, EmailScope.maxBodyCharacters)
    }
}
