import XCTest
@testable import LokalBot

/// The ⌘K palette and the system-wide Ask window share one command list but
/// match typed words differently.
final class PaletteCommandFilterTests: XCTestCase {
    private let commands = [
        PaletteCommand(id: "record", icon: "record.circle", title: "Record now", subtitle: "Recording",
                       placement: .background, action: {}),
        PaletteCommand(id: "dictation", icon: "mic", title: "Start dictation", subtitle: "Automation",
                       placement: .background, action: {}),
        PaletteCommand(id: "nav.meetings", icon: "waveform", title: "Go to Meetings", subtitle: "Library", action: {}),
        PaletteCommand(id: "followUp", icon: "arrowshape.turn.up.right", title: "Draft follow-up for latest meeting",
                       subtitle: "Meetings", action: {}),
        PaletteCommand(id: "nav.settings", icon: "gearshape", title: "前往设置", subtitle: "设置",
                       searchAliases: "Go to Settings Settings", action: {}),
    ]

    private func ids(_ query: String, _ matching: PaletteCommandFilter.Matching) -> [String] {
        PaletteCommandFilter.filter(commands, query: query, matching: matching).map(\.id)
    }

    func testEmptyQueryMatchesNothing() {
        XCTAssertEqual(ids("", .substring), [])
        XCTAssertEqual(ids("   ", .wordPrefix), [])
    }

    func testPaletteMatchesWordsAnywhere() {
        XCTAssertEqual(ids("ion", .substring), ["dictation"], "the ⌘K palette keeps substring matching")
        XCTAssertEqual(ids("follow-up", .substring), ["followUp"])
        XCTAssertEqual(ids("GO MEET", .substring), ["nav.meetings"])
    }

    func testAskWindowMatchesOnlyWordStarts() {
        XCTAssertEqual(ids("ion", .wordPrefix), [], "a memory search must not surface Dictation")
        XCTAssertEqual(ids("rec", .wordPrefix), ["record"])
        XCTAssertEqual(ids("meet", .wordPrefix), ["nav.meetings", "followUp"])
        XCTAssertEqual(ids("draft follow", .wordPrefix), ["followUp"])
        XCTAssertEqual(ids("failover", .wordPrefix), [])
    }

    func testTranslatedCommandsMatchEnglishAliasesAndChinese() {
        XCTAssertEqual(ids("settings", .wordPrefix), ["nav.settings"])
        XCTAssertEqual(ids("设置", .wordPrefix), ["nav.settings"], "Chinese has no spaces between words")
        XCTAssertEqual(ids("设置", .substring), ["nav.settings"])
    }
}
