import CryptoKit
import XCTest
@testable import LokalBot

final class GmailSyncTests: XCTestCase {
    private let now = GmailFixtures.now
    private var root: URL!
    private var store: EmailStore!
    private var server: FakeGmailServer!

    override func setUpWithError() throws {
        root = try GmailFixtures.temporaryRoot()
        store = EmailStore(root: root, key: GmailFixtures.key())
        server = FakeGmailServer()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func message(_ id: String, from: String, labels: [String] = ["INBOX"], daysAgo: Double = 1,
                         to: String = GmailFixtures.me, headers: [String: String] = [:],
                         plain: String = "Hello") -> FakeGmailMessage {
        FakeGmailMessage(id: id, labels: labels, date: now.addingTimeInterval(-daysAgo * 86_400),
                         from: from, to: to, extraHeaders: headers, plain: plain)
    }

    private func account() -> EmailAccount {
        EmailAccount(id: UUID(), provider: .gmail, address: GmailFixtures.me, aliases: [], connectedAt: now)
    }

    private func syncer(at date: Date? = nil, limit: Int = EmailScope.maxThreadsPerScan) -> GmailSyncer {
        let client = GmailClient(accessToken: { "token" }, tokenRejected: { _ in "token" },
                                 transport: server.transport, sleep: { _ in })
        var syncer = GmailSyncer(client: client, store: store, now: date ?? now)
        syncer.threadLimit = limit
        return syncer
    }

    /// A mailbox with one thread of each kind.
    private func seedMailbox() {
        server.put("a1", [message("a1-1", from: "ana@x.com"),
                          message("a1-2", from: GmailFixtures.me, labels: ["SENT"], to: "ana@x.com")])
        server.put("b2", [message("b2-1", from: "Ana <ana@x.com>", plain: "Agenda for Thursday")])
        server.put("c3", [message("c3-1", from: "ana@x.com", labels: ["CATEGORY_PROMOTIONS"])])
        server.put("d4", [message("d4-1", from: "stranger@z.com")])
        server.put("e5", [message("e5-1", from: GmailFixtures.alias, labels: ["SENT"], to: "vendor@v.com")])
        server.put("f6", [message("f6-1", from: "ana@x.com", labels: ["TRASH"])])
        server.markRead()
    }

    // MARK: First pass

    func testFirstPassStoresConversationsAndSkipsEverythingElse() async throws {
        seedMailbox()

        let synced = try await syncer().sync(account(), attendees: ["Ana@X.com", "noreply@zoom.us"])

        XCTAssertEqual(store.threadIDs(accountID: synced.id), ["a1", "b2", "e5"])
        XCTAssertEqual(synced.aliases, [GmailFixtures.alias])
        XCTAssertEqual(synced.sync.historyID, String(server.historyID))
        XCTAssertEqual(synced.sync.searchedAddresses, ["ana@x.com"])
        XCTAssertEqual(synced.sync.people, ["ana@x.com": now])
        XCTAssertEqual(synced.sync.threadCount, 3)
        XCTAssertEqual(synced.sync.messageCount, 4)
        XCTAssertFalse(synced.sync.capped)
        XCTAssertEqual(try store.thread(accountID: synced.id, threadID: "b2")?.messages.first?.body,
                       "Agenda for Thursday")
        // The bulk and stranger threads were never downloaded with bodies.
        XCTAssertFalse(server.requests.contains { request in
            request.url?.path.hasSuffix("/threads/c3") == true || request.url?.path.hasSuffix("/threads/d4") == true
        })
    }

    func testEveryRequestIsAReadOnlyGetToGmail() async throws {
        seedMailbox()
        let first = try await syncer().sync(account(), attendees: ["ana@x.com"])
        server.put("g7", [message("g7-1", from: "ana@x.com")])
        _ = try await syncer().sync(first, attendees: ["ana@x.com", "bob@y.com"])

        XCTAssertFalse(server.requests.isEmpty)
        for request in server.requests {
            XCTAssertEqual(request.httpMethod, "GET", request.url?.absoluteString ?? "")
            XCTAssertEqual(request.url?.host, "gmail.googleapis.com")
            XCTAssertNil(request.httpBody)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
        }
    }

    // MARK: Later passes

    func testLaterPassRechecksOnlyChangedThreads() async throws {
        seedMailbox()
        let first = try await syncer().sync(account(), attendees: ["ana@x.com"])
        let fetchesBefore = server.requestCount(pathSuffix: "/threads/a1")

        // Ana's thread is trashed, a new one arrives, and a newsletter lands.
        server.put("b2", [message("b2-1", from: "ana@x.com", labels: ["TRASH"])])
        server.put("h8", [message("h8-1", from: "ana@x.com", plain: "New date: Friday")])
        server.put("i9", [message("i9-1", from: "ana@x.com", labels: ["CATEGORY_UPDATES"])])
        let second = try await syncer().sync(first, attendees: ["ana@x.com"])

        XCTAssertEqual(store.threadIDs(accountID: second.id), ["a1", "e5", "h8"])
        XCTAssertEqual(second.sync.historyID, String(server.historyID))
        XCTAssertEqual(server.requestCount(pathSuffix: "/threads/a1"), fetchesBefore, "unchanged threads aren't refetched")
        XCTAssertEqual(server.requestCount(pathSuffix: "/history"), 1)
    }

    func testANewCalendarPersonGetsOneSearchOfTheirOwn() async throws {
        seedMailbox()
        server.put("j10", [message("j10-1", from: "bob@y.com", daysAgo: 30, plain: "Intro")])
        server.markRead()
        let first = try await syncer().sync(account(), attendees: ["ana@x.com"])
        XCTAssertFalse(store.threadIDs(accountID: first.id).contains("j10"))

        let second = try await syncer().sync(first, attendees: ["ana@x.com", "bob@y.com"])
        XCTAssertTrue(store.threadIDs(accountID: second.id).contains("j10"))
        XCTAssertEqual(second.sync.searchedAddresses, ["ana@x.com", "bob@y.com"])
        let searches = server.queries.filter { $0.hasPrefix("{") }
        XCTAssertEqual(searches.count, 2)
        XCTAssertTrue(searches[1].contains("from:bob@y.com"))
        XCTAssertFalse(searches[1].contains("ana@x.com"), "people already searched aren't searched again")

        _ = try await syncer().sync(second, attendees: ["ana@x.com", "bob@y.com"])
        XCTAssertEqual(server.queries.filter { $0.hasPrefix("{") }.count, 2)
    }

    func testExpiredHistoryRescansTheWindow() async throws {
        seedMailbox()
        let first = try await syncer().sync(account(), attendees: ["ana@x.com"])
        server.remove("b2")
        server.historyExpired = true

        let second = try await syncer().sync(first, attendees: ["ana@x.com"])

        XCTAssertEqual(store.threadIDs(accountID: second.id), ["a1", "e5"])
        XCTAssertEqual(server.queries.filter { $0.hasPrefix("in:sent") }.count, 2)
    }

    func testMailOlderThanTheWindowAgesOut() async throws {
        seedMailbox()
        let first = try await syncer().sync(account(), attendees: ["ana@x.com"])
        XCTAssertEqual(store.threadIDs(accountID: first.id).count, 3)

        // 89.5 days later every seeded message is outside the window.
        let later = try await syncer(at: now.addingTimeInterval(89.5 * 86_400)).sync(first, attendees: ["ana@x.com"])

        XCTAssertEqual(store.threadIDs(accountID: later.id), [])
        XCTAssertEqual(later.sync.threadCount, 0)
    }

    func testAnInterruptedPassKeepsTheOldCursorAndRepeatsCleanly() async throws {
        seedMailbox()
        server.failThreadFetchesAfter = 1
        let original = account()
        do {
            _ = try await syncer().sync(original, attendees: ["ana@x.com"])
            XCTFail("expected the pass to fail")
        } catch {
            XCTAssertEqual(error as? GmailError, .requestFailed(status: 429, reason: "RESOURCE_EXHAUSTED"))
        }
        XCTAssertNil(original.sync.historyID)

        server.failThreadFetchesAfter = nil
        let retried = try await syncer().sync(original, attendees: ["ana@x.com"])
        XCTAssertEqual(store.threadIDs(accountID: retried.id), ["a1", "b2", "e5"])
        XCTAssertEqual(retried.sync.messageCount, 4)
    }

    func testABrieflyEmptyCalendarDeletesNothingAndSearchesNothing() async throws {
        seedMailbox()
        let first = try await syncer().sync(account(), attendees: ["ana@x.com"])
        // Ana replies while the calendar can't be read (launch, calendar use paused).
        server.put("b2", [message("b2-1", from: "Ana <ana@x.com>", plain: "Agenda for Thursday"),
                          message("b2-2", from: "ana@x.com", plain: "Moved to 10:00")])
        let queriesBefore = server.queries.count

        let second = try await syncer(at: now.addingTimeInterval(3_600)).sync(first, attendees: [])

        XCTAssertEqual(store.threadIDs(accountID: second.id), ["a1", "b2", "e5"])
        XCTAssertEqual(try store.thread(accountID: second.id, threadID: "b2")?.messages.count, 2)
        XCTAssertEqual(server.queries.count, queriesBefore, "nobody is searched again")
        XCTAssertEqual(second.sync.people, ["ana@x.com": now], "Ana is remembered from when she was seen")
        XCTAssertEqual(second.sync.searchedAddresses, ["ana@x.com"])
    }

    func testPeopleAreForgottenAfterTheWindow() async throws {
        seedMailbox()
        let first = try await syncer().sync(account(), attendees: ["ana@x.com"])
        let later = try await syncer(at: now.addingTimeInterval(91 * 86_400)).sync(first, attendees: [])
        XCTAssertEqual(later.sync.people, [:])
        XCTAssertEqual(later.sync.searchedAddresses, [])
    }

    func testACappedScanLeavesPeopleItNeverSearched() async throws {
        seedMailbox()
        // The two threads you wrote in fill the limit; Ana's search never runs.
        let capped = try await syncer(limit: 2).sync(account(), attendees: ["ana@x.com"])
        XCTAssertTrue(capped.sync.capped)
        XCTAssertEqual(capped.sync.searchedAddresses, [])
        XCTAssertEqual(store.threadIDs(accountID: capped.id), ["a1", "e5"])

        let next = try await syncer().sync(capped, attendees: ["ana@x.com"])
        XCTAssertEqual(next.sync.searchedAddresses, ["ana@x.com"])
        XCTAssertEqual(store.threadIDs(accountID: next.id), ["a1", "b2", "e5"])
        XCTAssertFalse(next.sync.capped)
    }

    func testOneUnreadableThreadIsSkippedAndKept() async throws {
        seedMailbox()
        let first = try await syncer().sync(account(), attendees: ["ana@x.com"])
        server.put("b2", [message("b2-1", from: "ana@x.com"), message("b2-2", from: "ana@x.com")])
        server.put("h8", [message("h8-1", from: "ana@x.com")])
        server.failingThreads = ["b2"]

        let second = try await syncer().sync(first, attendees: ["ana@x.com"])

        XCTAssertEqual(store.threadIDs(accountID: second.id), ["a1", "b2", "e5", "h8"])
        XCTAssertEqual(try store.thread(accountID: second.id, threadID: "b2")?.messages.count, 1,
                       "the stored copy stays as it was")
        XCTAssertEqual(second.sync.historyID, String(server.historyID), "the other changes still move the cursor")
        XCTAssertEqual(second.sync.retryThreadIDs, ["b2"])

        // Next pass, with no new changes, the thread is read again.
        server.failingThreads = []
        server.markRead()
        let third = try await syncer().sync(second, attendees: ["ana@x.com"])
        XCTAssertEqual(try store.thread(accountID: third.id, threadID: "b2")?.messages.count, 2)
        XCTAssertEqual(third.sync.retryThreadIDs, [])
    }

    func testAThreadMissedByTheFirstScanIsReadNextPass() async throws {
        seedMailbox()
        server.failingThreads = ["b2"]
        let first = try await syncer().sync(account(), attendees: ["ana@x.com"])
        XCTAssertEqual(store.threadIDs(accountID: first.id), ["a1", "e5"])
        XCTAssertEqual(first.sync.retryThreadIDs, ["b2"])

        server.failingThreads = []
        let second = try await syncer().sync(first, attendees: ["ana@x.com"])
        XCTAssertEqual(store.threadIDs(accountID: second.id), ["a1", "b2", "e5"])
    }

    func testManyFailuresAtOnceEndThePass() async throws {
        for index in 0..<5 {
            server.put("s\(index)", [message("s\(index)-1", from: GmailFixtures.me, labels: ["SENT"], to: "x@y.com")])
        }
        server.failingThreads = ["s0", "s1", "s2", "s3", "s4"]
        do {
            _ = try await syncer().sync(account(), attendees: [])
            XCTFail("expected the pass to end")
        } catch {
            XCTAssertEqual(error as? GmailError, .requestFailed(status: 500, reason: nil))
        }
    }

    func testALostConnectionIsRetried() async throws {
        seedMailbox()
        server.dropNextConnection = true
        let synced = try await syncer().sync(account(), attendees: ["ana@x.com"])
        XCTAssertEqual(store.threadIDs(accountID: synced.id), ["a1", "b2", "e5"])
    }

    func testAThreadWhoseQualifyingReplyAgesOutIsRemoved() async throws {
        server.put("k1", [
            message("k1-1", from: GmailFixtures.me, labels: ["SENT"], daysAgo: 89, to: "shop@store.example"),
            message("k1-2", from: "shop@store.example", daysAgo: 1, headers: ["List-Unsubscribe": "<mailto:u@x>"]),
        ])
        server.markRead()
        let first = try await syncer().sync(account(), attendees: [])
        XCTAssertEqual(store.threadIDs(accountID: first.id), ["k1"])

        let later = try await syncer(at: now.addingTimeInterval(2 * 86_400)).sync(first, attendees: [])
        XCTAssertEqual(store.threadIDs(accountID: later.id), [], "only the newsletter's message was left")
    }

    // MARK: Client

    func testRateLimitsAreRetriedAndAnExpiredTokenIsRefreshedOnce() async throws {
        let attempts = AttemptLog()
        let client = GmailClient(
            accessToken: { "old" },
            tokenRejected: { rejected in
                XCTAssertEqual(rejected, "old")
                return "new"
            },
            transport: { request in
                let attempt = attempts.next()
                switch attempt {
                case 1:
                    return (Data(), GmailFixtures.response(request, 401))
                case 2:
                    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer new")
                    return (GmailFixtures.json(["error": ["errors": [["reason": "userRateLimitExceeded"]]]]),
                            GmailFixtures.response(request, 403))
                case 3:
                    return (Data(), GmailFixtures.response(request, 429, headers: ["Retry-After": "2"]))
                default:
                    return (GmailFixtures.json(["emailAddress": "me@example.com", "historyId": "7"]),
                            GmailFixtures.response(request, 200))
                }
            },
            sleep: { duration in attempts.slept(duration) })

        let profile = try await client.profile()

        XCTAssertEqual(profile, GmailProfile(emailAddress: "me@example.com", historyId: "7"))
        XCTAssertEqual(attempts.count, 4)
        XCTAssertEqual(attempts.sleeps, [.seconds(2), .seconds(2)])
    }

    func testReadingStarringAndArchivingDontRefetchThreads() throws {
        let json = GmailFixtures.json(["historyId": "9", "history": [
            ["labelsRemoved": [["message": ["id": "m1", "threadId": "read"], "labelIds": ["UNREAD"]]]],
            ["labelsAdded": [["message": ["id": "m2", "threadId": "starred"], "labelIds": ["STARRED", "IMPORTANT"]]]],
            ["labelsRemoved": [["message": ["id": "m3", "threadId": "archived"], "labelIds": ["INBOX"]]]],
            ["labelsAdded": [["message": ["id": "m4", "threadId": "trashed"], "labelIds": ["TRASH"]]]],
            ["labelsAdded": [["message": ["id": "m5", "threadId": "promoted"], "labelIds": ["CATEGORY_PROMOTIONS"]]]],
            ["messagesAdded": [["message": ["id": "m6", "threadId": "new"]]]],
            ["messagesDeleted": [["message": ["id": "m7", "threadId": "deleted"]]]],
        ]])
        let page = try JSONDecoder().decode(GmailHistoryList.self, from: json)
        var touched: Set<String> = []
        for change in page.history ?? [] { touched.formUnion(change.threadIDs) }
        XCTAssertEqual(touched, ["trashed", "promoted", "new", "deleted"])
    }

    func testADisabledGmailAPISaysSo() {
        XCTAssertEqual(GmailError.requestFailed(status: 403, reason: "accessNotConfigured").localizedDescription,
                       "The Gmail API isn't enabled in your Google Cloud project. Enable it there, then try again.")
        XCTAssertEqual(GmailError.requestFailed(status: 500, reason: nil).localizedDescription,
                       "Gmail returned HTTP 500.")
    }

    func testRequestsEscapePlusAndRefuseOddIDs() {
        let request = GmailClient.request("threads", query: [URLQueryItem(name: "q", value: "from:a+b@x.com")],
                                          token: "t")
        XCTAssertTrue(request.url!.absoluteString.contains("q=from:a%2Bb@x.com"))
        XCTAssertEqual(GmailClient.pathSafe("18f3a9c0d1e2"), "18f3a9c0d1e2")
        XCTAssertEqual(GmailClient.pathSafe("../profile"), "invalid")
    }

    final class AttemptLog: @unchecked Sendable {
        private let lock = NSLock()
        private var attempts = 0
        private var durations: [Duration] = []
        var count: Int { lock.withLock { attempts } }
        var sleeps: [Duration] { lock.withLock { durations } }
        func next() -> Int { lock.withLock { attempts += 1; return attempts } }
        func slept(_ duration: Duration) { lock.withLock { durations.append(duration) } }
    }
}
