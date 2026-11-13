import AppKit
import XCTest
@testable import LokalBot

// MARK: - Inline macros

final class CotypingMacroTests: XCTestCase {
    /// Deterministic engine: fixed clock (2026-06-23 14:30 UTC, a Tuesday), UTC
    /// calendar, en_US locale, and an injected RNG/UUID.
    private func fixedEngine(random: @escaping (ClosedRange<Int>) -> Int = { $0.lowerBound }) -> CotypingMacro.Engine {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        var comps = DateComponents()
        comps.year = 2026; comps.month = 6; comps.day = 23; comps.hour = 14; comps.minute = 30
        let now = calendar.date(from: comps)!
        var engine = CotypingMacro.Engine()
        engine.now = { now }
        engine.calendar = calendar
        engine.locale = Locale(identifier: "en_US")
        engine.random = random
        engine.uuid = { "FIXED-UUID" }
        return engine
    }

    // Arithmetic
    func testArithmeticPreviewAndInsertion() {
        let result = fixedEngine().evaluate("5+5")
        XCTAssertEqual(result?.preview, "= 10")
        XCTAssertEqual(result?.insertion, "10")
    }
    func testArithmeticPrecedence() {
        XCTAssertEqual(fixedEngine().evaluate("3+4*2")?.insertion, "11")
        XCTAssertEqual(fixedEngine().evaluate("(1+2)*3")?.insertion, "9")
    }
    func testArithmeticDivisionAndPower() {
        XCTAssertEqual(fixedEngine().evaluate("10/4")?.insertion, "2.5")
        XCTAssertEqual(fixedEngine().evaluate("2^10")?.insertion, "1024")
    }
    func testArithmeticPercentAndMultiplyAlias() {
        XCTAssertEqual(fixedEngine().evaluate("200*10%")?.insertion, "20")
        XCTAssertEqual(fixedEngine().evaluate("5x5")?.insertion, "25")
    }
    func testArithmeticTrailingEquals() {
        XCTAssertEqual(fixedEngine().evaluate("5+5=")?.insertion, "10")
    }
    func testBareNumberIsNotAMacro() {
        XCTAssertNil(fixedEngine().evaluate("5"))
        XCTAssertNil(fixedEngine().evaluate("notamacro"))
    }

    // Date / time
    func testDateToday() {
        XCTAssertEqual(fixedEngine().evaluate("today(iso)")?.insertion, "2026-06-23")
        XCTAssertEqual(fixedEngine().evaluate("tdy(iso)")?.insertion, "2026-06-23")
    }
    func testDateTomorrowYesterday() {
        XCTAssertEqual(fixedEngine().evaluate("tomorrow(iso)")?.insertion, "2026-06-24")
        XCTAssertEqual(fixedEngine().evaluate("yesterday(iso)")?.insertion, "2026-06-22")
    }
    func testDateRelativeOffsets() {
        XCTAssertEqual(fixedEngine().evaluate("+3d(iso)")?.insertion, "2026-06-26")
        XCTAssertEqual(fixedEngine().evaluate("+1w(iso)")?.insertion, "2026-06-30")
    }
    func testDateWeekdayNavigation() {
        XCTAssertEqual(fixedEngine().evaluate("next-fri(iso)")?.insertion, "2026-06-26")
        XCTAssertEqual(fixedEngine().evaluate("this-tue(iso)")?.insertion, "2026-06-23")
        XCTAssertEqual(fixedEngine().evaluate("last-tue(iso)")?.insertion, "2026-06-16")
        XCTAssertEqual(fixedEngine().evaluate("nextfri(iso)")?.insertion, "2026-06-26")
    }
    func testTime24Hour() {
        XCTAssertEqual(fixedEngine().evaluate("now(24h)")?.insertion, "14:30")
    }

    // Random (RNG returns the low bound by default)
    func testRandomFamilies() {
        XCTAssertEqual(fixedEngine().evaluate("dice")?.insertion, "1")
        XCTAssertEqual(fixedEngine().evaluate("d20")?.insertion, "1")
        XCTAssertEqual(fixedEngine().evaluate("coin")?.insertion, "Heads")
        XCTAssertEqual(fixedEngine().evaluate("random(5,10)")?.insertion, "5")
        XCTAssertEqual(fixedEngine().evaluate("uuid")?.insertion, "FIXED-UUID")
    }
    func testDiceHighBound() {
        XCTAssertEqual(fixedEngine(random: { $0.upperBound }).evaluate("d20")?.insertion, "20")
    }

    // Unit conversion
    func testUnitConversions() {
        XCTAssertEqual(fixedEngine().evaluate("10km->mi")?.insertion, "6.214 mi")
        XCTAssertEqual(fixedEngine().evaluate("1000m->km")?.insertion, "1 km")
        XCTAssertEqual(fixedEngine().evaluate("10 km to mi")?.insertion, "6.214 mi")
    }
    func testCrossQuantityIsNotConverted() {
        XCTAssertNil(fixedEngine().evaluate("10km->kg"))
    }

    // Currency (bundled offline rates: USD=1.0, EUR=0.92)
    func testCurrencyConversion() {
        XCTAssertTrue(fixedEngine().evaluate("100usd to eur")?.insertion.contains("92") ?? false)
        XCTAssertTrue(fixedEngine().evaluate("$100 to eur")?.insertion.contains("92") ?? false)
    }
    func testAmbiguousCurrencyReturnsNil() {
        XCTAssertNil(fixedEngine().evaluate("100 kr to usd"))
    }

    // Trigger scan (boundary + internal slash + evaluate-gating)
    func testTrailingQueryScan() {
        XCTAssertEqual(CotypingMacro.trailingQuery(in: "go /today"), "today")
        XCTAssertEqual(CotypingMacro.trailingQuery(in: "/5+5"), "5+5")
        XCTAssertEqual(CotypingMacro.trailingQuery(in: "/5/2"), "5/2")
        XCTAssertNil(CotypingMacro.trailingQuery(in: "and/or"))
        XCTAssertNil(CotypingMacro.trailingQuery(in: "http://x"))
        XCTAssertNil(CotypingMacro.trailingQuery(in: "no slash"))
    }
    func testTrailingTokenLength() {
        XCTAssertEqual(CotypingMacro.trailingTokenLength(in: "go /today"), 6)
        XCTAssertEqual(CotypingMacro.trailingTokenLength(in: "/5+5"), 4)
    }
    func testMatchGatesOnEvaluation() {
        let hit = CotypingMacro.match(trailing: "/5/2")
        XCTAssertEqual(hit?.result.insertion, "2.5")
        XCTAssertEqual(hit?.tokenLength, 4)
        XCTAssertNil(CotypingMacro.match(trailing: "/notamacro"))
    }

    func testMacroSettingDefaultsOn() {
        XCTAssertTrue(AppSettings().cotypingMacros)
    }
}
