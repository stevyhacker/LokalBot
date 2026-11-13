import XCTest
@testable import LokalBot

final class CotypingMemoryLookupTests: XCTestCase {
    func testAWordStillBeingTypedIsLeftOut() {
        XCTAssertEqual(CotypingMemoryLookup.finishedWords(of: "Following up on Atl"), "Following up on ")
        XCTAssertEqual(CotypingMemoryLookup.finishedWords(of: "Following up on Atlas "), "Following up on Atlas ")
        XCTAssertEqual(CotypingMemoryLookup.finishedWords(of: "Atlas, "), "Atlas, ")
        XCTAssertEqual(CotypingMemoryLookup.finishedWords(of: "Atlas,"), "Atlas,")
        XCTAssertEqual(CotypingMemoryLookup.finishedWords(of: "Atlas"), "")
        XCTAssertEqual(CotypingMemoryLookup.finishedWords(of: ""), "")
    }

    /// Typing inside a word asks for nothing new; a finished word that could
    /// name something does, and only the newest lookup is kept.
    func testOnlyTheNewestLookupForTheFieldIsKept() {
        var lookup = CotypingMemoryLookup()
        let first = CotypingMemoryContext.Query(draft: "Following up on ")
        let second = CotypingMemoryContext.Query(draft: "Following up on Atlas ")
        XCTAssertTrue(lookup.needsLookup(anchor: "field", query: first))
        let older = lookup.begin(anchor: "field", query: first)
        XCTAssertFalse(lookup.needsLookup(anchor: "field", query: first))
        XCTAssertTrue(lookup.needsLookup(anchor: "field", query: second))
        let newer = lookup.begin(anchor: "field", query: second)

        var found = CotypingMemoryContextProvider.Snapshot()
        found.selection = CotypingMemoryContext.Selection(items: [
            .init(id: "a", title: "Atlas", text: "Atlas: launch moved to Thursday",
                  updatedAt: Date(), requiresMeetings: true)
        ])
        lookup.finish(older, with: found)
        XCTAssertTrue(lookup.snapshot.selection.items.isEmpty)
        lookup.finish(newer, with: found)
        XCTAssertEqual(lookup.snapshot.selection.items.map(\.id), ["a"])

        // Another field never sees this one's facts.
        _ = lookup.begin(anchor: "other field", query: second)
        XCTAssertTrue(lookup.snapshot.selection.items.isEmpty)
    }
}
