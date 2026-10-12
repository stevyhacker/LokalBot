import XCTest
@testable import LokalBot

/// The rules that decide whether a saved fact may reach a completion prompt,
/// and a model-free evaluation over the benchmark fixtures: every relevant
/// draft must find its fact, and every distractor must find nothing.
final class CotypingMemoryRelevanceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_000_000)
    private let policy = CotypingMemoryContext.Policy(meetings: true, screenDerived: false)

    private func fact(_ text: String, title: String = "Weekly sync",
                      id: String = "fact") -> CotypingMemoryContext.Item {
        .init(id: id, title: title, text: text, updatedAt: now, requiresMeetings: true)
    }

    private func field(_ draft: String, appName: String = "Notes", bundleID: String = "com.apple.Notes",
                       windowTitle: String? = nil) -> CotypingField {
        CotypingField(appName: appName, bundleID: bundleID, processID: 0, role: "AXTextArea",
                      precedingText: draft, trailingText: "", selectionLength: 0, caretRect: .zero,
                      isSecure: false, caretIsExact: true, windowTitle: windowTitle)
    }

    private func selected(_ draft: String, from facts: [CotypingMemoryContext.Item],
                          appName: String = "Notes", windowTitle: String? = nil) -> [String] {
        CotypingMemoryContext.select(
            items: facts, for: field(draft, appName: appName, windowTitle: windowTitle),
            includeTitle: true, policy: policy, now: now).items.map(\.id)
    }

    // MARK: - Rules

    func testEverydayWordingNeverEstablishesRelevance() {
        let commitment = fact("Marko will get back to you on Friday about the invoice.")
        XCTAssertEqual(selected("I'll get back to ", from: [commitment]), [])
        XCTAssertEqual(selected("I will get back to you on Friday ", from: [commitment]), [])
        XCTAssertEqual(selected("Let me know when you get back ", from: [commitment]), [])
        XCTAssertTrue(CotypingMemoryContext.query(for: field("I'll get back to you soon"),
                                                  includeTitle: true).all.isEmpty)
    }

    func testTwoSharedWordsNeedANameOrAThird() {
        let scoped = fact("The migration timeline was scoped at two weeks.")
        XCTAssertEqual(selected("Following up on the migration timeline ", from: [scoped]), [])
        XCTAssertEqual(selected("Following up on the migration timeline we scoped ", from: [scoped]), ["fact"])

        // The saved line writes Tamaris as a name, so a lowercase draft still finds it.
        let named = fact("The Tamaris cutover is planned for 14 October.")
        XCTAssertEqual(selected("the tamaris cutover is ", from: [named]), ["fact"])
        // One shared word is never enough, name or not.
        XCTAssertEqual(selected("I asked about Tamaris and ", from: [named]), [])
    }

    func testASentenceOpeningCapitalIsANameOnlyWhenBothSidesWriteIt() {
        let line = fact("Pricing tiers launch with the spring release.")
        XCTAssertEqual(selected("the pricing tiers are ", from: [line]), [])
        XCTAssertEqual(selected("Pricing tiers are ", from: [line]), ["fact"])
        let capitals = CotypingMemoryContext.capitalizedTerms(in: "Pricing tiers ship. Ask Bojana about Q4: Budget talks.")
        XCTAssertEqual(capitals.opening, ["pricing", "budget"])
        XCTAssertEqual(capitals.inside, ["bojana"])
    }

    func testASourceIsNamedByHalfItsTitle() {
        let price = fact("Kamenari pricing starts at 49 euros per seat.", title: "Kamenari pricing workshop")
        XCTAssertEqual(selected("Our pricing is ", from: [price]), [])
        XCTAssertEqual(selected("Kamenari pricing is ", from: [price]), ["fact"])
        // A named source brings its other lines along; one that only shares wording does not.
        let other = fact("The onboarding checklist moved to Notion.", title: "Kamenari pricing workshop", id: "other")
        XCTAssertEqual(Set(selected("Kamenari pricing is ", from: [price, other])), ["fact", "other"])
    }

    func testMeetingKindsPlatformsAndAppNamesNameNothing() {
        let commitment = fact("Marko will get back to you on Friday about the invoice.")
        XCTAssertEqual(selected("I'll get back to ", from: [commitment], windowTitle: "Weekly sync notes"), [])
        let call = fact("Ana will send the signed contract next week.", title: "Google Meet")
        XCTAssertEqual(selected("I'll send the ", from: [call], appName: "Google Chrome",
                                windowTitle: "Ostrog plan - Google Docs - Google Chrome"), [])
        // The app's own name is dropped from its window title; the document's name is kept.
        let query = CotypingMemoryContext.Query(draft: "", title: "Ostrog plan - Slack", appName: "Slack")
        XCTAssertEqual(query.own, ["ostrog"])
    }

    func testALineThatOnlyRestatesItsTitleIsLeftOut() {
        let heading = fact("# Atlas launch", title: "Atlas launch", id: "heading")
        let detail = fact("Atlas launch moved to 14 October.", title: "Atlas launch", id: "detail")
        XCTAssertEqual(selected("The Atlas launch ", from: [heading, detail]), ["detail"])
        let section = fact("## Decisions", title: "Atlas launch", id: "section")
        XCTAssertEqual(selected("The Atlas launch ", from: [section]), [])
        // A work-memory goal is its own title; it is a statement, not a heading.
        var goal = fact("Ship the Kamenari pricing page ()", title: "Ship the Kamenari pricing page", id: "goal")
        goal.isWorkMemory = true
        XCTAssertEqual(selected("We still need to ship the Kamenari pricing page ", from: [goal]), ["goal"])
    }

    /// A draft that already mentions the answer must still get the current
    /// fact. Judging "adds nothing" against the draft dropped it, and the
    /// older version of the same topic then won.
    func testAnAnswerAlreadyInTheDraftDoesNotLetAnOlderFactWin() {
        let current = fact("Atlas owner is Priya.", title: "Atlas", id: "current")
        var older = fact("Atlas owner is Nadja.", title: "Atlas", id: "older")
        older.updatedAt = now.addingTimeInterval(-30 * 86_400)
        XCTAssertEqual(selected("The Atlas owner is ", from: [older, current]), ["current"])
        XCTAssertEqual(selected("I spoke with Priya this morning. The Atlas owner is ", from: [older, current]),
                       ["current"])
        XCTAssertEqual(selected("Priya, Nadja and I met. The Atlas owner is ", from: [older, current]), ["current"])
    }

    func testEverydayWordsCanStillBeTheDetailAFactSupplies() {
        let month = fact("The Borealis launch is in November.", title: "Borealis")
        XCTAssertEqual(selected("The Borealis launch is in ", from: [month]), ["fact"])
    }

    func testSearchTermsStayNearestTheCaret() {
        let filler = (1...30).map { "topic\($0)x" }.joined(separator: " ")
        let query = CotypingMemoryContext.Query(draft: "\(filler) and the Vesna owner is ", title: "Zebra plan")
        XCTAssertEqual(query.search.count, CotypingMemoryContext.maxSearchTerms)
        XCTAssertEqual(query.search.first, "vesna")
        XCTAssertFalse(query.search.contains("zebra"), "the draft's nearest words fill the budget first")
        XCTAssertTrue(query.own.contains("zebra"), "the cap applies to the index lookup, not to matching")
        XCTAssertEqual(CotypingMemoryContext.Query(draft: "Thanks, sounds good to me").search, [])
    }

    func testOtherLanguagesKeepTheirFunctionWordsOutOfTheMatch() {
        let serbian = fact("Marko će ti se javiti sutra oko ugovora.", title: "Nedeljni sastanak")
        XCTAssertEqual(selected("Javiću ti se sutra oko ", from: [serbian]), [])
        let french = fact("Camille revient vers vous avec le budget vendredi.", title: "Point hebdo")
        XCTAssertEqual(selected("Merci pour le rapport, je reviens vers vous avec ", from: [french]), [])
        let diacritics = fact("Lovćen dashboard access goes through Ivana.")
        XCTAssertEqual(selected("Access to the Lovcen dashboard goes through ", from: [diacritics]), ["fact"])
    }

    // MARK: - Fixture evaluation

    private struct MemoryFixture: Decodable {
        struct Case: Decodable {
            var id: String
            var prefix: String
            var appName: String?
            var bundleID: String?
            var windowTitle: String?
            var kind: String
            var expectedMemoryID: String?
        }
        var asOf: Date
        var memoryItems: [CotypingMemoryContext.Item]
        var cases: [Case]
    }

    private struct VisibleFixture: Decodable {
        struct Case: Decodable {
            var id: String
            var prefix: String
            var appName: String?
            var bundleID: String?
            var windowTitle: String?
            var visibleContext: CotypingVisibleContextReplay.Fixture?
            var expectedMemoryIDs: [String]
            var memoryRequiresVisibleContext: Bool?
        }
        var asOf: Date
        var memoryItems: [CotypingMemoryContext.Item]
        var cases: [Case]
    }

    private func fixture<Value: Decodable>(_ name: String, as type: Value.Type) throws -> Value {
        // Copies of Benchmarks/Cotyping fixtures; see project.yml.
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: nil))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Data(contentsOf: url))
    }

    /// Retrieval is scored without a model: relevant drafts must select exactly
    /// their fact, and irrelevant or distracting drafts must select nothing.
    func testMemoryFixturesRecoverRelevantFactsAndIgnoreTheRest() throws {
        for name in ["memory-cases.json", "memory-relevance-cases.json"] {
            let fixture = try fixture(name, as: MemoryFixture.self)
            var recalled = 0, relevant = 0, ignored = 0, others = 0
            for item in fixture.cases {
                let ids = CotypingMemoryContext.select(
                    items: fixture.memoryItems,
                    for: field(item.prefix, appName: item.appName ?? "Notes",
                               bundleID: item.bundleID ?? "com.apple.Notes", windowTitle: item.windowTitle),
                    includeTitle: true, policy: policy, now: fixture.asOf).items.map(\.id)
                if let expected = item.expectedMemoryID {
                    relevant += 1
                    recalled += ids == [expected] ? 1 : 0
                    XCTAssertEqual(ids, [expected], "\(name) \(item.id)")
                } else {
                    others += 1
                    ignored += ids.isEmpty ? 1 : 0
                    XCTAssertEqual(ids, [], "\(name) \(item.id) borrowed unrelated memory")
                }
            }
            XCTAssertEqual(recalled, relevant, name)
            XCTAssertEqual(ignored, others, name)
            XCTAssertGreaterThan(relevant, 0, name)
            XCTAssertGreaterThan(others, 0, name)
        }
    }

    /// The visible-context fixtures were frozen before these rules changed.
    /// Their expected selections must hold with and without nearby text.
    func testVisibleContextFixturesKeepTheirFrozenSelections() throws {
        for name in ["visible-context-cases.json", "visible-memory-link-cases.json"] {
            let fixture = try fixture(name, as: VisibleFixture.self)
            XCTAssertFalse(fixture.cases.isEmpty, name)
            for visible in [false, true] {
                for item in fixture.cases {
                    var field = field(item.prefix, appName: item.appName ?? "Notes",
                                      bundleID: item.bundleID ?? "com.apple.Notes", windowTitle: item.windowTitle)
                    field.visibleContext = item.visibleContext.map(CotypingVisibleContextReplay.init)?
                        .capture(enabled: visible)
                    let ids = CotypingMemoryContext.select(
                        items: fixture.memoryItems, for: field, includeTitle: true,
                        policy: policy, now: fixture.asOf).items.map(\.id)
                    let expectsMemory = visible || !(item.memoryRequiresVisibleContext ?? false)
                    XCTAssertEqual(ids, expectsMemory ? item.expectedMemoryIDs : [],
                                   "\(name) \(item.id) visible=\(visible)")
                }
            }
        }
    }
}
