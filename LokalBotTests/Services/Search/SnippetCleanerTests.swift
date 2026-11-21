import XCTest
@testable import LokalBot

final class SnippetCleanerTests: XCTestCase {

    func testDropsLeadingLineThatEchoesTitle() {
        let snippet = "«NuPhyIO» - HID device connected - Google Chrome - Stevan\n"
            + "this button also has an action to…"
        XCTAssertEqual(
            SnippetCleaner.withoutTitleEcho(
                snippet, title: "NuPhyIO - HID device connected - Google Chrome - Stevan"),
            "this button also has an action to…")
    }

    func testDropsLeadingMidTitleFragmentWithEllipsis() {
        let snippet = "…device connected - Google Chrome - Stevan\nreal «evidence» text"
        XCTAssertEqual(
            SnippetCleaner.withoutTitleEcho(
                snippet, title: "NuPhyIO - HID device connected - Google Chrome - Stevan"),
            "real «evidence» text")
    }

    func testKeepsNonEchoEvidenceWithMarkers() {
        XCTAssertEqual(
            SnippetCleaner.withoutTitleEcho(
                "shipping «cross» chain support next week", title: "PR #132"),
            "shipping «cross» chain support next week")
    }

    func testSnippetThatOnlyEchoesTitleBecomesNil() {
        XCTAssertNil(
            SnippetCleaner.withoutTitleEcho(
                "«Nuphy» IO mac keys not working : r/NuPhy",
                title: "Nuphy IO mac keys not working : r/NuPhy"))
    }

    func testCollapsesNewlinesAndWhitespaceRuns() {
        XCTAssertEqual(
            SnippetCleaner.withoutTitleEcho(
                "left   pane\nright  pane", title: "Unrelated window title"),
            "left pane right pane")
    }

    func testShortLineIsDroppedOnlyOnExactMatch() {
        XCTAssertEqual(
            SnippetCleaner.withoutTitleEcho("Chrome\ndetails here", title: "Chrome"),
            "details here")
        XCTAssertEqual(
            SnippetCleaner.withoutTitleEcho(
                "Chrome\ndetails here", title: "Google Chrome - Stevan"),
            "Chrome details here")
    }

    func testEmptyTitlePassesSnippetThroughCollapsed() {
        XCTAssertEqual(
            SnippetCleaner.withoutTitleEcho("a   b\nc", title: ""),
            "a b c")
    }
}
