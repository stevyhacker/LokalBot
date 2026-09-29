import XCTest
import SwiftUI
@testable import LokalBot

final class AppAppearanceTests: XCTestCase {
    override func tearDown() {
        AppTextScale.current = 1
        super.tearDown()
    }

    func testDefaultTextSizeKeepsSystemTextStyles() {
        AppTextScale.current = AppTextSize.standard.scale
        XCTAssertEqual(Font.scaled(.body), Font.body)
        XCTAssertEqual(Font.scaled(.callout), Font.callout)
        XCTAssertEqual(Font.scaled(.headline), Font.headline)
        XCTAssertEqual(Font.scaled(.callout, design: .monospaced), Font.system(.callout, design: .monospaced))
    }

    func testLargerTextSizesScaleMacTextStyleMetrics() {
        AppTextScale.current = AppTextSize.largest.scale
        XCTAssertEqual(Font.scaled(.body), Font.system(size: 18, weight: .regular, design: .default))
        XCTAssertEqual(Font.scaled(.headline), Font.system(size: 18, weight: .bold, design: .default))
        XCTAssertEqual(Font.scaledSystem(size: 14), Font.system(size: 20, weight: .regular, design: .default))
        AppTextScale.current = AppTextSize.small.scale
        XCTAssertEqual(Font.scaled(.callout), Font.system(size: 11, weight: .regular, design: .default))
    }

    func testThemeAndTextSizeRoundTripAndDefault() throws {
        let fresh = AppSettings()
        XCTAssertEqual(fresh.appTheme, .system)
        XCTAssertEqual(fresh.textSize, .standard)
        var settings = AppSettings()
        settings.appTheme = .dark
        settings.textSize = .larger
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.appTheme, .dark)
        XCTAssertEqual(decoded.textSize, .larger)
        XCTAssertNil(AppTheme.system.appearance)
        XCTAssertEqual(AppTheme.dark.appearance?.name, .darkAqua)
        XCTAssertEqual(AppTheme.light.appearance?.name, .aqua)
    }
}
