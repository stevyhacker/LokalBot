import AppKit
import XCTest
@testable import LokalBot

// MARK: - Emoji autocomplete + adaptive debounce

final class CotypingEmojiTests: XCTestCase {
    func testOpenPrefixMatch() {
        let match = CotypingEmoji.match(trailing: "I love :roc")
        XCTAssertEqual(match?.glyph, "\u{1f680}")
        XCTAssertEqual(match?.shortcode, "rocket")
        XCTAssertEqual(match?.typedLength, 4)
    }

    func testClosedExactMatch() {
        let match = CotypingEmoji.match(trailing: "ship it :rocket:")
        XCTAssertEqual(match?.glyph, "\u{1f680}")
        XCTAssertEqual(match?.typedLength, 8)
    }

    func testSynonymResolves() {
        XCTAssertEqual(CotypingEmoji.match(trailing: "haha :lol")?.glyph, "\u{1f602}")
    }

    func testRequiresWordBoundary() {
        XCTAssertNil(CotypingEmoji.match(trailing: "http://exa"))
        XCTAssertNil(CotypingEmoji.match(trailing: "12:30"))
        XCTAssertNil(CotypingEmoji.match(trailing: "foo::bar"))
    }

    func testNoMatchForUnknown() {
        XCTAssertNil(CotypingEmoji.match(trailing: "see :zzzzz"))
    }

    func testTooShortOpenQuery() {
        XCTAssertNil(CotypingEmoji.match(trailing: "a :x"))
    }

    func testTrailingTokenLength() {
        XCTAssertEqual(CotypingEmoji.trailingTokenLength(in: "I love :roc"), 4)
        XCTAssertEqual(CotypingEmoji.trailingTokenLength(in: "go :rocket:"), 8)
        XCTAssertNil(CotypingEmoji.trailingTokenLength(in: "no token here"))
    }

    func testEmojiSettingDefaultsOn() {
        XCTAssertTrue(AppSettings().cotypingEmoji)
    }
}
