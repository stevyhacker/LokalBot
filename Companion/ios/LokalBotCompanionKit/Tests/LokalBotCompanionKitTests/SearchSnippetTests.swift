import Testing
@testable import LokalBotCompanionKit

@Suite("Search snippets")
struct SearchSnippetTests {
    @Test func coreMarkersBecomeMatches() {
        let parts = SearchSnippet.parts("…we keep «three» pricing «tiers».")
        #expect(parts.map(\.text) == ["…we keep ", "three", " pricing ", "tiers", "."])
        #expect(parts.map(\.isMatch) == [false, true, false, true, false])
    }

    @Test func withoutMarkersTheQueryTermsMatch() {
        let parts = SearchSnippet.parts("Share pricing tiers with legal", query: "TIERS pricing")
        #expect(parts.filter(\.isMatch).map(\.text) == ["pricing", "tiers"])
        #expect(parts.map(\.text).joined() == "Share pricing tiers with legal")
        #expect(SearchSnippet.parts("plain", query: "") == [.init(text: "plain", isMatch: false)])
        #expect(SearchSnippet.parts("open «only").map(\.text).joined() == "open only")
    }
}
