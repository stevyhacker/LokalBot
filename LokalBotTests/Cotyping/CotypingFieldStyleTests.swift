import AppKit
import XCTest
@testable import LokalBot

// MARK: - Ghost styling (host font/color match)

final class CotypingFieldStyleTests: XCTestCase {
    func testIsEmpty() {
        XCTAssertTrue(CotypingFieldStyle().isEmpty)
        XCTAssertFalse(CotypingFieldStyle(fontName: "Helvetica").isEmpty)
        XCTAssertFalse(CotypingFieldStyle(colorHex: "336699").isEmpty)
        XCTAssertFalse(CotypingFieldStyle(backgroundColorHex: "000000").isEmpty)
        XCTAssertFalse(CotypingFieldStyle(fontPointSize: 16).isEmpty)
    }

    func testHexRoundTrip() {
        let color = NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        let hex = CotypingTextColorCodec.hexString(from: color)
        XCTAssertEqual(hex, "336699")
        let back = CotypingTextColorCodec.nsColor(fromHex: hex)
        XCTAssertEqual(back?.redComponent ?? 0, 51.0 / 255, accuracy: 0.001)
        XCTAssertEqual(back?.greenComponent ?? 0, 102.0 / 255, accuracy: 0.001)
        XCTAssertEqual(back?.blueComponent ?? 0, 153.0 / 255, accuracy: 0.001)
    }

    func testHexParseRejectsInvalid() {
        XCTAssertNil(CotypingTextColorCodec.nsColor(fromHex: nil))
        XCTAssertNil(CotypingTextColorCodec.nsColor(fromHex: "xyz"))
        XCTAssertNil(CotypingTextColorCodec.nsColor(fromHex: "12345"))   // 5 digits
        XCTAssertNil(CotypingTextColorCodec.nsColor(fromHex: "GGGGGG"))
        XCTAssertNotNil(CotypingTextColorCodec.nsColor(fromHex: "FFFFFF"))
    }

    func testGhostColorDimsHostColor() {
        let color = CotypingGhostStyle.ghostColor(from: CotypingFieldStyle(colorHex: "336699"))
        XCTAssertEqual(color?.alphaComponent ?? 0, CotypingGhostStyle.ghostOpacity, accuracy: 0.001)
        XCTAssertEqual(color?.redComponent ?? 0, 51.0 / 255, accuracy: 0.001)
    }

    func testGhostColorNilWithoutHex() {
        XCTAssertNil(CotypingGhostStyle.ghostColor(from: nil))
        XCTAssertNil(CotypingGhostStyle.ghostColor(from: CotypingFieldStyle(fontName: "Helvetica")))
    }

    func testMatchHostStyleDefaultsOn() {
        XCTAssertTrue(AppSettings().cotypingMatchHostStyle)
    }

    func testResolvedGhostColorDimsReadableForeground() {
        let style = CotypingFieldStyle(colorHex: "FFFFFF", backgroundColorHex: "000000")
        let color = CotypingGhostStyle.resolvedGhostColor(from: style, isDarkEnvironment: false)
        XCTAssertEqual(color.alphaComponent, CotypingGhostStyle.ghostOpacity, accuracy: 0.001)
        XCTAssertGreaterThan(CotypingGhostStyle.relativeLuminance(of: color), 0.9) // stays white
    }

    func testResolvedGhostColorUsesBackgroundWhenNoForeground() {
        let onDark = CotypingGhostStyle.resolvedGhostColor(
            from: CotypingFieldStyle(backgroundColorHex: "1E1E1E"), isDarkEnvironment: false)
        XCTAssertGreaterThan(CotypingGhostStyle.relativeLuminance(of: onDark), 0.9)  // light hint
        let onLight = CotypingGhostStyle.resolvedGhostColor(
            from: CotypingFieldStyle(backgroundColorHex: "FFFFFF"), isDarkEnvironment: true)
        XCTAssertLessThan(CotypingGhostStyle.relativeLuminance(of: onLight), 0.1)    // dark hint
    }

    func testResolvedGhostColorFallsBackToEnvironmentWithoutHostColors() {
        let dark = CotypingGhostStyle.resolvedGhostColor(from: nil, isDarkEnvironment: true)
        let light = CotypingGhostStyle.resolvedGhostColor(from: nil, isDarkEnvironment: false)
        XCTAssertGreaterThan(CotypingGhostStyle.relativeLuminance(of: dark), 0.9)
        XCTAssertLessThan(CotypingGhostStyle.relativeLuminance(of: light), 0.1)
    }

    func testResolvedGhostColorOverridesForegroundIndistinguishableFromBackground() {
        // A host fg flattened to the background color (wrong-appearance capture)
        // must not paint invisible text — synthesize a legible hint instead.
        let style = CotypingFieldStyle(colorHex: "000000", backgroundColorHex: "000000")
        let color = CotypingGhostStyle.resolvedGhostColor(from: style, isDarkEnvironment: false)
        XCTAssertGreaterThan(CotypingGhostStyle.relativeLuminance(of: color), 0.9) // light, not black
    }

    func testLuminanceAndContrastExtremes() {
        let white = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        let black = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        XCTAssertEqual(CotypingGhostStyle.relativeLuminance(of: white), 1, accuracy: 0.001)
        XCTAssertEqual(CotypingGhostStyle.relativeLuminance(of: black), 0, accuracy: 0.001)
        XCTAssertGreaterThan(CotypingGhostStyle.contrastRatio(white, black), 20)
        XCTAssertEqual(CotypingGhostStyle.contrastRatio(white, white), 1, accuracy: 0.001)
    }

    func testMeasuredLuminanceDrivesGhostContrast() {
        let style = CotypingFieldStyle(colorHex: "111111")  // near-black host fg, no bg reported
        // Measured-dark background → flip to a light hint (the reported bug).
        let onDark = CotypingGhostStyle.resolvedGhostColor(
            from: style, isDarkEnvironment: false, measuredLuminance: 0.03)
        XCTAssertGreaterThan(CotypingGhostStyle.relativeLuminance(of: onDark), 0.9)
        // Measured-light background → keep the legible dark host color.
        let onLight = CotypingGhostStyle.resolvedGhostColor(
            from: style, isDarkEnvironment: true, measuredLuminance: 0.97)
        XCTAssertLessThan(CotypingGhostStyle.relativeLuminance(of: onLight), 0.2)
    }

    func testAverageLuminanceOfSolidImages() {
        XCTAssertGreaterThan(
            CotypingBackgroundSampler.averageLuminance(of: solidImage(white: 1)) ?? 0, 0.95)
        XCTAssertLessThan(
            CotypingBackgroundSampler.averageLuminance(of: solidImage(white: 0)) ?? 1, 0.05)
    }

    /// A Retina strip's worth of pixels: the far end counts as much as the caret's.
    func testAverageLuminanceCoversTheWholeStrip() {
        let rightHalf = image(width: 334, height: 42, whiteFromX: 167)
        XCTAssertEqual(CotypingBackgroundSampler.averageLuminance(of: rightHalf) ?? 0, 0.5, accuracy: 0.01)
        let lastColumns = image(width: 334, height: 42, whiteFromX: 324)
        XCTAssertEqual(CotypingBackgroundSampler.averageLuminance(of: lastColumns) ?? 0, 10.0 / 334, accuracy: 0.01)
    }

    /// A 32-pixel-wide output letterboxed some strips in black (2–4 columns,
    /// measured), darkening the background; the strip's own pixel size never does.
    func testTheBackgroundCaptureIsTheWholeStripAtItsOwnPixelSize() throws {
        let ultraWide = CGRect(x: 0, y: 0, width: 3440, height: 1440)
        let config = try XCTUnwrap(CotypingBackgroundSampler.captureConfiguration(
            for: CGRect(x: 300.3, y: 1122.4, width: 2, height: 17.5), screenFrame: ultraWide, backingScale: 1))
        XCTAssertTrue(config.scalesToFit)
        XCTAssertEqual(config.sourceRect, CGRect(x: 300, y: 300, width: 163, height: 18))
        XCTAssertEqual(config.width, 163)
        XCTAssertEqual(config.height, 18)
        let retina = try XCTUnwrap(CotypingBackgroundSampler.captureConfiguration(
            for: CGRect(x: -1500.5, y: -900.25, width: 6, height: 19.5),
            screenFrame: CGRect(x: -1728, y: -1117, width: 1728, height: 1117), backingScale: 2))
        XCTAssertTrue(retina.scalesToFit)
        XCTAssertEqual(retina.sourceRect, CGRect(x: 227, y: 880, width: 167, height: 21))
        XCTAssertEqual(retina.width, 334)
        XCTAssertEqual(retina.height, 42)
    }

    /// Off-display pixels come back black, so the strip stops at the edge.
    func testTheBackgroundCaptureStopsAtTheDisplayEdge() throws {
        let ultraWide = CGRect(x: 0, y: 0, width: 3440, height: 1440)
        let config = try XCTUnwrap(CotypingBackgroundSampler.captureConfiguration(
            for: CGRect(x: 3400, y: 700, width: 2, height: 17), screenFrame: ultraWide, backingScale: 1))
        XCTAssertEqual(config.sourceRect, CGRect(x: 3400, y: 723, width: 40, height: 17))
        XCTAssertEqual(config.width, 40)
        XCTAssertNil(CotypingBackgroundSampler.captureConfiguration(
            for: CGRect(x: 5000, y: 700, width: 2, height: 17), screenFrame: ultraWide, backingScale: 1))
    }

    /// Black, then white from column `whiteFromX` to the right edge.
    private func image(width: Int, height: Int, whiteFromX: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: whiteFromX, y: 0, width: width - whiteFromX, height: height))
        return ctx.makeImage()!
    }

    private func solidImage(white: CGFloat) -> CGImage {
        let ctx = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: white, green: white, blue: white, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        return ctx.makeImage()!
    }
}

// MARK: - Background behind the ghost

@MainActor
final class CotypingBackgroundSamplerTests: XCTestCase {
    private func chromeField(
        page: String, frame: CGRect = CGRect(x: 400, y: 300, width: 640, height: 120),
        preceding: String = "draft", element: String = "element-1"
    ) -> CotypingField {
        CotypingField(
            appName: "Google Chrome", bundleID: "com.google.Chrome", processID: 42, role: "AXTextArea",
            focusIdentityKey: element, precedingText: preceding, trailingText: "", selectionLength: 0,
            caretRect: CGRect(x: 420, y: 380, width: 1, height: 18), inputFrameRect: frame,
            isSecure: false, caretIsExact: true, windowTitle: page)
    }

    private func key(_ field: CotypingField) -> String {
        CotypingFieldIdentity.background(for: field)
    }

    /// 2026-10-21: a reading from a light page in Chrome drew black ghosts in
    /// a dark Reddit comment box, because readings were kept per app.
    func testReadingFromOneFieldIsNotReusedInAnotherFieldOfTheSameApp() {
        let sampler = CotypingBackgroundSampler()
        sampler.remember(0.95, forField: key(chromeField(page: "Google")))

        XCTAssertNil(sampler.cachedLuminance(forField: key(chromeField(page: "Reddit"))))
        XCTAssertNil(sampler.cachedLuminance(forField: key(chromeField(
            page: "Google", frame: CGRect(x: 400, y: 600, width: 640, height: 40)))))
    }

    /// Chrome hands out a new element on every read; the field's reading
    /// must outlive that, or every suggestion would sample and recolor.
    func testReadingIsReusedWhileTypingInTheSameField() {
        let sampler = CotypingBackgroundSampler()
        sampler.remember(0.1, forField: key(chromeField(page: "Reddit")))

        let laterKeystroke = chromeField(page: "Reddit", preceding: "draft with more words", element: "element-2")
        XCTAssertEqual(sampler.cachedLuminance(forField: key(laterKeystroke)), 0.1)
    }

    func testReadingExpires() {
        let sampler = CotypingBackgroundSampler()
        let start = Date()
        sampler.remember(0.1, forField: "field", now: start)

        XCTAssertEqual(sampler.cachedLuminance(forField: "field", now: start.addingTimeInterval(60)), 0.1)
        XCTAssertNil(sampler.cachedLuminance(forField: "field", now: start.addingTimeInterval(301)))
    }
}
