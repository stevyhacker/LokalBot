import XCTest
@testable import LokalBot

final class HourLabelTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!

    private func label(_ hour: Int, _ identifier: String) -> String {
        HourLabel.format(hour, locale: Locale(identifier: identifier), timeZone: utc)
            .replacingOccurrences(of: "\u{202F}", with: " ")
    }

    func testTwelveHourLocales() {
        XCTAssertEqual(label(18, "en_US"), "6:00 PM")
        XCTAssertEqual(label(4, "en_US"), "4:00 AM")
        XCTAssertEqual(label(0, "en_US"), "12:00 AM")
    }

    func testTwentyFourHourLocales() {
        XCTAssertEqual(label(18, "en_GB"), "18:00")
        XCTAssertEqual(label(18, "de_DE"), "18:00")
        XCTAssertFalse(label(4, "de_DE").contains("AM"))
    }
}
