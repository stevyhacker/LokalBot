import XCTest
import SwiftUI
@testable import LokalBot

final class AppAppearanceTests: XCTestCase {
    func testDefaultTextSizeKeepsSystemTextStyles() {
        let scale = AppTextSize.standard.scale
        XCTAssertEqual(AppFont.scaled(.body).resolved(scale: scale), Font.body)
        XCTAssertEqual(AppFont.scaled(.callout).resolved(scale: scale), Font.callout)
        XCTAssertEqual(AppFont.scaled(.headline).resolved(scale: scale), Font.headline)
        XCTAssertEqual(AppFont.scaled(.callout, design: .monospaced).resolved(scale: scale),
                       Font.system(.callout, design: .monospaced))
        XCTAssertEqual(AppFont.scaled(.callout).weight(.semibold).monospacedDigit().resolved(scale: scale),
                       Font.callout.weight(.semibold).monospacedDigit())
    }

    func testLargerTextSizesScaleMacTextStyleMetrics() {
        let largest = AppTextSize.largest.scale
        XCTAssertEqual(AppFont.scaled(.body).resolved(scale: largest),
                       Font.system(size: 18, weight: .regular, design: .default))
        XCTAssertEqual(AppFont.scaled(.headline).resolved(scale: largest),
                       Font.system(size: 18, weight: .bold, design: .default))
        XCTAssertEqual(AppFont.scaledSystem(size: 14).resolved(scale: largest),
                       Font.system(size: 20, weight: .regular, design: .default))
        XCTAssertEqual(AppFont.scaled(.callout).bold().resolved(scale: AppTextSize.small.scale),
                       Font.system(size: 11, weight: .regular, design: .default).bold())
    }

    func testFontDescriptionsCompareByValueSoUnchangedTextIsNotRedrawn() {
        XCTAssertEqual(AppFont.scaled(.body).weight(.semibold), AppFont.scaled(.body).weight(.semibold))
        XCTAssertNotEqual(AppFont.scaled(.body), AppFont.scaled(.callout))
        XCTAssertEqual(EnvironmentValues().appTextScale, 1)
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
