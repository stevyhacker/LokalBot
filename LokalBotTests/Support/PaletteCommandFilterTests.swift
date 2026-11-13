import XCTest
@testable import LokalBot

/// Quick Recall lists the commands the ⌘K palette ran, and matches typed
/// words at least as loosely as the palette did.
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
        XCTAssertEqual(ids("ion", .substring), ["dictation"], "the ⌘K palette matched substrings")
        XCTAssertEqual(ids("follow-up", .substring), ["followUp"])
        XCTAssertEqual(ids("GO MEET", .substring), ["nav.meetings"])
    }

    func testWordStartMatching() {
        XCTAssertEqual(ids("ion", .wordPrefix), [])
        XCTAssertEqual(ids("rec", .wordPrefix), ["record"])
        XCTAssertEqual(ids("meet", .wordPrefix), ["nav.meetings", "followUp"])
        XCTAssertEqual(ids("draft follow", .wordPrefix), ["followUp"])
        XCTAssertEqual(ids("failover", .wordPrefix), [])
    }

    /// Quick Recall finds every command the palette found. Commands whose
    /// words start with what was typed come first, so Return runs the
    /// likeliest one.
    func testQuickRecallRanksWordStartsBeforeOtherMatches() {
        func ranked(_ query: String) -> [String] {
            PaletteCommandFilter.ranked(commands, query: query).map(\.id)
        }
        XCTAssertEqual(ranked("ion"), ["dictation"], "as forgiving as the palette")
        // Quick Recall lists the two parts apart: only word-start matches lead.
        let split = PaletteCommandFilter.split(commands, query: "ion")
        XCTAssertEqual(split.leading.map(\.id), [])
        XCTAssertEqual(split.loose.map(\.id), ["dictation"])
        XCTAssertEqual(PaletteCommandFilter.split(commands, query: "rec").leading.map(\.id), ["record"])
        XCTAssertEqual(ranked("rec"), ["record"])
        XCTAssertEqual(ranked("meet"), ["nav.meetings", "followUp"])
        XCTAssertEqual(ranked("m"), ["nav.meetings", "followUp", "dictation"],
                       "words that start with it first, then “Automation”, which only holds it")
        XCTAssertEqual(ids("m", .substring), ["dictation", "nav.meetings", "followUp"])
        XCTAssertEqual(ranked("failover"), [])
        XCTAssertEqual(ranked("  "), [])
        for query in ["ion", "go meet", "follow-up", "设置", "o"] {
            XCTAssertEqual(Set(ranked(query)), Set(ids(query, .substring)), query)
        }
    }

    func testBeforeTypingWhatActsInPlaceComesFirst() {
        XCTAssertEqual(PaletteCommandFilter.idleOrder(commands).map(\.id),
                       ["record", "dictation", "nav.meetings", "followUp", "nav.settings"])
    }

    func testACommandRowShowsItsShortcutAndDetailNotItsArea() {
        let record = QuickRecallRowModel.command(PaletteCommand(
            id: "record", icon: "record.circle", title: "Record now", subtitle: "Recording",
            placement: .background, shortcut: "⇧⌘R", action: {}))
        XCTAssertEqual(record.id, "command.record")
        XCTAssertEqual(record.lead, .recording)
        XCTAssertEqual(record.shortcut, "⇧⌘R")
        XCTAssertNil(record.qualifier)
        XCTAssertNil(record.snippet)

        let stop = QuickRecallRowModel.command(PaletteCommand(
            id: "record", icon: "stop.circle.fill", title: "Stop recording", subtitle: "Recording",
            placement: .background, action: {}))
        XCTAssertEqual(stop.lead, .symbol("stop.circle.fill"))

        let actions = QuickRecallRowModel.command(PaletteCommand(
            id: "nav.actions", icon: "checkmark.circle", title: "Review all actions", subtitle: "Home",
            detail: "2 open", action: {}))
        XCTAssertEqual(actions.qualifier, "2 open")
        XCTAssertEqual(actions.accessibilityValue, "2 open")
        guard case .command(let id) = actions.destination else { return XCTFail("runs the command") }
        XCTAssertEqual(id, "nav.actions")
    }

    func testTranslatedCommandsMatchEnglishAliasesAndChinese() {
        XCTAssertEqual(ids("settings", .wordPrefix), ["nav.settings"])
        XCTAssertEqual(ids("设置", .wordPrefix), ["nav.settings"], "Chinese has no spaces between words")
        XCTAssertEqual(ids("设置", .substring), ["nav.settings"])
    }
}
