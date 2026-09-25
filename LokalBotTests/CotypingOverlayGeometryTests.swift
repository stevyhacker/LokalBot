import AppKit
import XCTest
@testable import LokalBot

final class CotypingOverlayGeometryTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    /// The core consistency property: two AX providers reporting the same line
    /// center with different caret heights (AppKit line box vs WebKit marker
    /// bounds) must place the ghost at the identical vertical center and height.
    func testInlineCentersOnCaretRegardlessOfCaretHeight() {
        let shortCaret = CotypingOverlayGeometry.inlineFrame(
            caret: CGRect(x: 100, y: 500, width: 0, height: 14),   // midY 507
            textSize: CGSize(width: 60, height: 16), lineHeight: 16, visible: screen)
        let tallCaret = CotypingOverlayGeometry.inlineFrame(
            caret: CGRect(x: 100, y: 497, width: 0, height: 20),   // midY 507
            textSize: CGSize(width: 60, height: 16), lineHeight: 16, visible: screen)
        XCTAssertEqual(shortCaret.midY, 507, accuracy: 0.5)
        XCTAssertEqual(tallCaret.midY, 507, accuracy: 0.5)
        XCTAssertEqual(shortCaret.height, tallCaret.height)
    }

    func testInlineAnchorsRightOfCaretWithGap() {
        let frame = CotypingOverlayGeometry.inlineFrame(
            caret: CGRect(x: 100, y: 500, width: 0, height: 16),
            textSize: CGSize(width: 60, height: 16), lineHeight: 16, visible: screen)
        XCTAssertEqual(frame.minX, 102)
        XCTAssertEqual(frame.width, 60)
    }

    func testAdvancedInlineFrameSlidesByAcceptedTextWidth() throws {
        let frame = CotypingOverlayGeometry.inlineFrame(
            caret: CGRect(x: 100, y: 500, width: 0, height: 16),
            textSize: CGSize(width: 160, height: 16), lineHeight: 16, visible: screen)
        let advanced = try XCTUnwrap(CotypingOverlayGeometry.advancedInlineFrame(
            from: frame,
            insertedTextSize: CGSize(width: 42, height: 16),
            remainingTextSize: CGSize(width: 118, height: 16),
            lineHeight: 16,
            visible: screen))

        XCTAssertEqual(advanced.minX, frame.minX + 42, accuracy: 0.5)
        XCTAssertEqual(advanced.midY, frame.midY, accuracy: 0.5)
        XCTAssertEqual(advanced.width, 118)
    }

    func testAdvancedInlineFrameFallsBackWhenSlideWouldOverflow() {
        let frame = CGRect(x: 1340, y: 500, width: 90, height: 16)
        let advanced = CotypingOverlayGeometry.advancedInlineFrame(
            from: frame,
            insertedTextSize: CGSize(width: 50, height: 16),
            remainingTextSize: CGSize(width: 70, height: 16),
            lineHeight: 16,
            visible: screen)

        XCTAssertNil(advanced)
    }

    func testInlineReanchorHoldsSmallSameTextDrift() {
        XCTAssertTrue(CotypingOverlayGeometry.shouldHoldInlineReanchor(
            currentFrame: CGRect(x: 120, y: 500, width: 100, height: 16),
            targetFrame: CGRect(x: 124, y: 497, width: 100, height: 16),
            millisecondsSinceLastAcceptance: nil))
    }

    func testInlineReanchorHoldsBackwardJumpInsidePostAcceptWindow() {
        XCTAssertTrue(CotypingOverlayGeometry.shouldHoldInlineReanchor(
            currentFrame: CGRect(x: 160, y: 500, width: 100, height: 16),
            targetFrame: CGRect(x: 120, y: 500, width: 100, height: 16),
            millisecondsSinceLastAcceptance: 80))
    }

    func testInlineReanchorMirrorsBackwardJumpForRTL() {
        XCTAssertTrue(CotypingOverlayGeometry.shouldHoldInlineReanchor(
            currentFrame: CGRect(x: 120, y: 500, width: 100, height: 16),
            targetFrame: CGRect(x: 160, y: 500, width: 100, height: 16),
            millisecondsSinceLastAcceptance: 80,
            isRightToLeft: true))
        XCTAssertFalse(CotypingOverlayGeometry.shouldHoldInlineReanchor(
            currentFrame: CGRect(x: 120, y: 500, width: 100, height: 16),
            targetFrame: CGRect(x: 80, y: 500, width: 100, height: 16),
            millisecondsSinceLastAcceptance: 80,
            isRightToLeft: true))
    }

    func testInlineReanchorAllowsBackwardJumpAfterHoldWindow() {
        XCTAssertFalse(CotypingOverlayGeometry.shouldHoldInlineReanchor(
            currentFrame: CGRect(x: 160, y: 500, width: 100, height: 16),
            targetFrame: CGRect(x: 120, y: 500, width: 100, height: 16),
            millisecondsSinceLastAcceptance: 450))
    }

    func testInlineReanchorAllowsForwardAndVerticalMoves() {
        XCTAssertFalse(CotypingOverlayGeometry.shouldHoldInlineReanchor(
            currentFrame: CGRect(x: 120, y: 500, width: 100, height: 16),
            targetFrame: CGRect(x: 140, y: 500, width: 100, height: 16),
            millisecondsSinceLastAcceptance: 80))
        XCTAssertFalse(CotypingOverlayGeometry.shouldHoldInlineReanchor(
            currentFrame: CGRect(x: 120, y: 500, width: 100, height: 16),
            targetFrame: CGRect(x: 120, y: 512, width: 100, height: 16),
            millisecondsSinceLastAcceptance: 80))
    }

    func testInlineClampsToRightEdgeInsteadOfOverflowing() {
        let frame = CotypingOverlayGeometry.inlineFrame(
            caret: CGRect(x: 1400, y: 500, width: 0, height: 16),
            textSize: CGSize(width: 200, height: 16), lineHeight: 16, visible: screen)
        XCTAssertLessThanOrEqual(frame.maxX, screen.maxX)
    }

    func testInlineUsesLineHeightFloorWhenTextHeightUnreliable() {
        let frame = CotypingOverlayGeometry.inlineFrame(
            caret: CGRect(x: 10, y: 500, width: 0, height: 40),
            textSize: CGSize(width: 60, height: 0), lineHeight: 18, visible: nil)
        XCTAssertEqual(frame.height, 18)
    }

    func testGhostFontSizingDerivesFromCaretHeight() {
        let size = CotypingGhostFontSizing.pointSize(
            caretHeight: 20,
            fieldMetrics: nil,
            caretIsExact: true)

        XCTAssertEqual(size, 15.6, accuracy: 0.1)
    }

    func testGhostFontSizingCapsEstimatedCaretFrames() {
        let size = CotypingGhostFontSizing.pointSize(
            caretHeight: 80,
            fieldMetrics: nil,
            caretIsExact: false)

        XCTAssertEqual(size, CotypingGhostFontSizing.maximumEstimatedGhostFontSize)
    }

    func testGhostRenderStylePreservesHostColorsWhileReplacingPointSize() throws {
        let base = CotypingFieldStyle(
            fontName: NSFont.systemFont(ofSize: 13).fontName,
            fontPointSize: 13,
            colorHex: "123456",
            backgroundColorHex: "ABCDEF")
        let render = try XCTUnwrap(CotypingGhostFontSizing.renderStyle(
            from: base,
            caretHeight: 24,
            caretIsExact: true))

        XCTAssertEqual(render.fontName, base.fontName)
        XCTAssertNotEqual(render.fontPointSize, base.fontPointSize)
        XCTAssertEqual(render.colorHex, "123456")
        XCTAssertEqual(render.backgroundColorHex, "ABCDEF")
    }

    func testGhostFontSizeStabilizerKeepsSmallestCaretHeightPerField() {
        var stabilizer = CotypingGhostFontSizeStabilizer()

        XCTAssertEqual(stabilizer.stabilizedCaretHeight(18, focusSessionKey: "field-a"), 18)
        XCTAssertEqual(stabilizer.stabilizedCaretHeight(44, focusSessionKey: "field-a"), 18)
        XCTAssertEqual(stabilizer.stabilizedCaretHeight(22, focusSessionKey: "field-b"), 22)
    }

    func testInsertedTextAdvanceUsesHostPointSizeInsteadOfGhostFloor() throws {
        let hostFont = NSFont.systemFont(ofSize: 11)
        let sourceStyle = CotypingFieldStyle(fontName: hostFont.fontName, fontPointSize: 11)
        let renderStyle = CotypingFieldStyle(fontName: hostFont.fontName, fontPointSize: 14)

        let hostAdvance = try XCTUnwrap(CotypingInsertedTextAdvance.width(
            of: "follow",
            style: sourceStyle))
        let ghostAdvance = CotypingGhostStyle.measuredTextSize("follow", style: renderStyle).width

        XCTAssertLessThan(hostAdvance, ghostAdvance)
    }

    func testInsertedTextAdvanceReturnsNilWithoutUsableHostSize() {
        XCTAssertNil(CotypingInsertedTextAdvance.width(
            of: "follow",
            style: CotypingFieldStyle(fontName: NSFont.systemFont(ofSize: 13).fontName)))
        XCTAssertNil(CotypingInsertedTextAdvance.width(
            of: "",
            style: CotypingFieldStyle(fontName: NSFont.systemFont(ofSize: 13).fontName, fontPointSize: 13)))
    }

    func testInlineLayoutWrapsInsideInputFrame() {
        let font = NSFont.systemFont(ofSize: 13)
        let inputFrame = CGRect(x: 40, y: 480, width: 240, height: 28)
        let caret = CGRect(x: 178, y: 492, width: 1, height: 16)
        let layout = CotypingInlineGhostLayout.make(
            text: "confirm renewal timing before customer update",
            caretRect: caret,
            inputFrameRect: inputFrame,
            font: font,
            visible: screen,
            isRightToLeft: false)

        XCTAssertGreaterThan(layout.lines.count, 1)
        XCTAssertGreaterThan(layout.lines[0].leadingIndent, 0)

        let contentSize = CotypingInlineGhostLayout.estimatedContentSize(
            for: layout,
            style: CotypingFieldStyle(fontName: font.fontName, fontPointSize: font.pointSize))
        let frame = layout.panelFrame(for: contentSize, caretRect: caret, visible: screen)
        XCTAssertGreaterThanOrEqual(frame.minX, inputFrame.minX + 8 - 0.5)
        XCTAssertLessThanOrEqual(frame.maxX, inputFrame.maxX - 8 + 0.5)
    }

    func testInlineLayoutStartsOverflowBelowCaretWhenFirstLineHasNoRoom() {
        let font = NSFont.systemFont(ofSize: 13)
        let inputFrame = CGRect(x: 40, y: 480, width: 180, height: 28)
        let caret = CGRect(x: 214, y: 492, width: 1, height: 16)
        let layout = CotypingInlineGhostLayout.make(
            text: "confirm renewal timing",
            caretRect: caret,
            inputFrameRect: inputFrame,
            font: font,
            visible: screen,
            isRightToLeft: false)

        XCTAssertLessThan(layout.topLineCenterOffsetFromCaret, 0)
        XCTAssertEqual(layout.lines.first?.leadingIndent, 0)
    }

    func testInlineLayoutMirrorsAnchorForRTLText() {
        let font = NSFont.systemFont(ofSize: 13)
        let inputFrame = CGRect(x: 40, y: 480, width: 260, height: 28)
        let caret = CGRect(x: 158, y: 492, width: 1, height: 16)
        // Long enough to exceed the ~104pt first-line budget so the layout
        // exercises the wrap path, where the mirrored anchor produces indent.
        let words = "\u{05d0}\u{05d1}\u{05d2} \u{05d3}\u{05d4}\u{05d5} \u{05d6}\u{05d7}\u{05d8} \u{05d9}\u{05da}\u{05db}"
        let layout = CotypingInlineGhostLayout.make(
            text: "\(words) \(words)",
            caretRect: caret,
            inputFrameRect: inputFrame,
            font: font,
            visible: screen,
            isRightToLeft: true)

        XCTAssertTrue(layout.isRightToLeft)
        XCTAssertGreaterThan(layout.lines[0].leadingIndent, 0)
        let contentSize = CotypingInlineGhostLayout.estimatedContentSize(
            for: layout,
            style: CotypingFieldStyle(fontName: font.fontName, fontPointSize: font.pointSize))
        let frame = layout.panelFrame(for: contentSize, caretRect: caret, visible: screen)
        XCTAssertLessThanOrEqual(frame.maxX, inputFrame.maxX - 8 + 0.5)
    }

    func testMirrorSitsBelowCaretAndFlipsAboveWhenNoRoom() {
        let below = CotypingOverlayGeometry.mirrorFrame(
            caret: CGRect(x: 100, y: 500, width: 0, height: 16),
            content: CGSize(width: 120, height: 24), visible: screen)
        XCTAssertEqual(below.maxY, 498, accuracy: 0.5)

        let nearBottom = CotypingOverlayGeometry.mirrorFrame(
            caret: CGRect(x: 100, y: 5, width: 0, height: 16),
            content: CGSize(width: 120, height: 24), visible: screen)
        XCTAssertGreaterThanOrEqual(nearBottom.minY, screen.minY)
    }

    func testMirrorLayoutWrapsLongSuggestionWithinBudget() {
        let font = NSFont.systemFont(ofSize: 13)
        let maxWidth: CGFloat = 140
        let lines = CotypingGhostTextLayout.wrappedLines(
            text: "Please confirm the renewal schedule before sending the customer update",
            font: font,
            maxWidth: maxWidth,
            maxLines: 4)

        XCTAssertGreaterThan(lines.count, 1)
        for line in lines {
            let width = (line as NSString).size(withAttributes: [.font: font]).width
            XCTAssertLessThanOrEqual(width, maxWidth + 0.5)
        }
    }

    func testMirrorWrapPreservesWordsAfterOversizedToken() {
        let token = String(repeating: "W", count: 24)
        let lines = CotypingGhostTextLayout.wrappedLines(
            text: token + " contract approved", font: .systemFont(ofSize: 13), maxWidth: 80, maxLines: 20)
        XCTAssertEqual(lines.joined().replacingOccurrences(of: " ", with: ""), token + "contractapproved")
        XCTAssertFalse(lines.contains { $0.hasSuffix("...") })
        let clipped = CotypingGhostTextLayout.wrappedLines(
            text: token + " contract approved", font: .systemFont(ofSize: 13), maxWidth: 80, maxLines: 2)
        XCTAssertTrue(clipped.last?.hasSuffix("...") == true)
    }

    func testMirrorLayoutPreservesExplicitLineBoundaries() {
        let font = NSFont.systemFont(ofSize: 13)
        let lines = CotypingGhostTextLayout.wrappedLines(
            text: "first line\nsecond line",
            font: font,
            maxWidth: 400,
            maxLines: 4)

        XCTAssertEqual(lines, ["first line", "second line"])
    }

    func testMirrorLayoutEllipsizesWhenRowsAreExhausted() {
        let font = NSFont.systemFont(ofSize: 13)
        let lines = CotypingGhostTextLayout.wrappedLines(
            text: "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda",
            font: font,
            maxWidth: 90,
            maxLines: 2)

        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[1].hasSuffix("..."))
    }

    func testAXRectConversionUsesContainingScreenFrame() {
        let converted = CotypingAXHelper.cocoaRect(
            fromAX: CGRect(x: 1500, y: -100, width: 2, height: 20),
            displayBounds: CGRect(x: 1440, y: -200, width: 1920, height: 1080),
            screenFrame: CGRect(x: 1440, y: 0, width: 1920, height: 1080))

        XCTAssertEqual(converted.origin.x, 1500)
        XCTAssertEqual(converted.origin.y, 960)
        XCTAssertEqual(converted.width, 2)
        XCTAssertEqual(converted.height, 20)
    }
}
