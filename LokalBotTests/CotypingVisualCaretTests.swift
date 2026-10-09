import AppKit
import XCTest
@testable import LokalBot

/// The caret found from a field's text on screen, for Chrome text areas that
/// report no caret position. Global Cocoa coordinates (y up).
final class CotypingVisualCaretTests: XCTestCase {
    private typealias Locator = CotypingVisualCaretLocator
    /// A GitHub comment box: 797×103 with 14 pt text inset 13 pt.
    private let field = CGRect(x: 1170, y: 300, width: 797, height: 103)

    private func line(_ text: String, minX: CGFloat = 1183, baseline: CGFloat, size: CGFloat = 14) -> Locator.RecognizedLine {
        let width = CotypingInlineGhostLayout.width(of: text, font: .systemFont(ofSize: size))
        return Locator.RecognizedLine(
            text: text, minX: minX, maxX: minX + width, baseline: baseline,
            box: CGRect(x: minX, y: baseline - 3, width: width, height: 13))
    }

    func testTheCaretIsAtTheEndOfTheLineThatEndsTheTypedText() throws {
        let first = line("Thanks for the quick review, I will push the fixes", baseline: 375)
        let second = line("in a follow-up later", baseline: 354)
        let found = try XCTUnwrap(Locator.locate(
            lines: [first, second],
            precedingText: "Thanks for the quick review, I will push the fixes in a follow-up later",
            fieldFrame: field))
        XCTAssertEqual(found.caretX, second.maxX, accuracy: 0.01)
        XCTAssertEqual(found.baseline, 354)
        XCTAssertEqual(found.pointSize, 14, accuracy: 0.05)
        XCTAssertEqual(found.lineMinX, 1183)
        XCTAssertEqual(found.lineMaxX, field.maxX - 13, accuracy: 0.01)
    }

    func testATypedSpaceMovesTheCaretOneSpacePastTheLastLetter() throws {
        let typed = line("Looks good, just a", baseline: 375)
        let found = try XCTUnwrap(Locator.locate(lines: [typed], precedingText: "Looks good, just a ", fieldFrame: field))
        let space = CotypingInlineGhostLayout.width(of: " ", font: .systemFont(ofSize: found.pointSize))
        XCTAssertEqual(found.caretX, typed.maxX + space, accuracy: 0.01)
    }

    func testSmallRecognitionMistakesStillMatch() {
        let recognized = line("Looks g0od, just a few rninor things", baseline: 375)
        XCTAssertNotNil(Locator.locate(
            lines: [recognized], precedingText: "Looks good, just a few minor things", fieldFrame: field))
    }

    func testOtherTextOnScreenIsNotTakenForTheCaretsLine() {
        let unrelated = line("Paste, drop, or click to add files", baseline: 375)
        XCTAssertNil(Locator.locate(
            lines: [unrelated], precedingText: "Looks good, just a few minor things", fieldFrame: field))
        // A line that holds more than the paragraph has text after the caret.
        let longer = line("Looks good, just a few minor things and more after it", baseline: 375)
        XCTAssertNil(Locator.locate(lines: [longer], precedingText: "Looks good, just a", fieldFrame: field))
    }

    func testAnEmptyNewLineHasNothingToFind() {
        let previous = line("Looks good", baseline: 375)
        XCTAssertNil(Locator.locate(lines: [previous], precedingText: "Looks good\n", fieldFrame: field))
        XCTAssertNil(Locator.locate(lines: [previous], precedingText: "Looks good\na", fieldFrame: field))
        // Too little on the caret's line to be found: not looked for at all.
        XCTAssertFalse(Locator.hasEnoughText("Looks good\nab"))
        XCTAssertFalse(Locator.hasEnoughText("Looks good\nab   "))
        XCTAssertTrue(Locator.hasEnoughText("Looks good\nabc"))
    }

    func testTypingMovesTheCaretAlongItsLineUntilTheLineEnds() throws {
        let found = try XCTUnwrap(Locator.locate(
            lines: [line("Looks good", baseline: 375)], precedingText: "Looks good", fieldFrame: field))
        let font = NSFont.systemFont(ofSize: found.pointSize)
        XCTAssertEqual(Locator.caretX(for: found, precedingText: "Looks good"), found.caretX)
        XCTAssertEqual(
            try XCTUnwrap(Locator.caretX(for: found, precedingText: "Looks good, just")),
            found.caretX + CotypingInlineGhostLayout.width(of: ", just", font: font), accuracy: 0.01)
        XCTAssertEqual(
            try XCTUnwrap(Locator.caretX(for: found, precedingText: "Looks go")),
            found.caretX - CotypingInlineGhostLayout.width(of: "od", font: font), accuracy: 0.01)
        // A line break, a long way from where the caret was found, or other
        // text: look again.
        XCTAssertNil(Locator.caretX(for: found, precedingText: "Looks good\n"))
        XCTAssertNil(Locator.caretX(for: found, precedingText: "Looks good" + String(repeating: " more", count: 9)))
        XCTAssertNil(Locator.caretX(for: found, precedingText: "Something else entirely"))
        // A word past the field's edge wraps onto the next line.
        let narrow = CGRect(x: 1170, y: 300, width: 160, height: 60)
        let short = try XCTUnwrap(Locator.locate(
            lines: [line("Looks good", baseline: 340)], precedingText: "Looks good", fieldFrame: narrow))
        XCTAssertNotNil(Locator.caretX(for: short, precedingText: "Looks good, ok"))
        XCTAssertNil(Locator.caretX(for: short, precedingText: "Looks good, just wonderful"))
    }

    /// A capture can be a frame behind the typing, and recognition can miss
    /// a final full stop. Taking the end of what was recognized for the
    /// caret put the ghost over the last letters typed.
    func testACaptureThatLacksTheLastLettersStillPutsTheCaretAfterThem() throws {
        let behind = line("Looks goo", baseline: 375)
        let found = try XCTUnwrap(Locator.locate(lines: [behind], precedingText: "Looks good", fieldFrame: field))
        let font = NSFont.systemFont(ofSize: found.pointSize)
        XCTAssertEqual(found.caretX, behind.maxX + CotypingInlineGhostLayout.width(of: "d", font: font), accuracy: 0.01)
        XCTAssertEqual(found.precedingText, "Looks good")

        let noStop = line("Thanks, see you tomorrow", baseline: 375)
        let stopped = try XCTUnwrap(Locator.locate(
            lines: [noStop], precedingText: "Thanks, see you tomorrow. ", fieldFrame: field))
        XCTAssertEqual(
            stopped.caretX,
            noStop.maxX + CotypingInlineGhostLayout.width(of: ". ", font: .systemFont(ofSize: stopped.pointSize)),
            accuracy: 0.01)
        // A line that shows everything is taken as it is.
        let whole = line("Looks good", baseline: 375)
        XCTAssertEqual(
            try XCTUnwrap(Locator.locate(lines: [whole], precedingText: "Looks good", fieldFrame: field)).caretX,
            whole.maxX, accuracy: 0.01)
    }

    /// The field's right text edge is only estimated, so a word typed close
    /// to it may already be on the next line. Following the caret along the
    /// line put the ghost on the line above, and its wrapped words on the
    /// word just typed. Spaces never wrap.
    func testLettersTypedNearTheLineEndAreFoundAgain() throws {
        let narrow = CGRect(x: 1170, y: 300, width: 160, height: 60)
        let short = try XCTUnwrap(Locator.locate(
            lines: [line("Looks good", baseline: 340)], precedingText: "Looks good", fieldFrame: narrow))
        XCTAssertNotNil(Locator.caretX(for: short, precedingText: "Looks good, okay"))
        XCTAssertNil(Locator.caretX(for: short, precedingText: "Looks good, ok then"))

        let full = try XCTUnwrap(Locator.locate(
            lines: [line("Looks good, okay", baseline: 340)], precedingText: "Looks good, okay", fieldFrame: narrow))
        XCTAssertNotNil(Locator.caretX(for: full, precedingText: "Looks good, okay  "))
        XCTAssertNil(Locator.caretX(for: full, precedingText: "Looks good, okay t"))
    }

    /// Deleting back into the first word of a wrapped line can let that
    /// word fit on the line above again.
    func testDeletingIntoTheFirstWordOfAWrappedLineIsFoundAgain() throws {
        let first = "Thanks for the quick review, I will push the fixes"
        let found = try XCTUnwrap(Locator.locate(
            lines: [line(first, baseline: 375), line("in a follow-up later", baseline: 354)],
            precedingText: first + " in a follow-up later", fieldFrame: field))
        XCTAssertNotNil(Locator.caretX(for: found, precedingText: first + " in a "))
        XCTAssertNil(Locator.caretX(for: found, precedingText: first + " i"))
        // A paragraph's first line has no line above to go back to.
        let single = try XCTUnwrap(Locator.locate(
            lines: [line("Looks good", baseline: 375)], precedingText: "Looks good", fieldFrame: field))
        XCTAssertNil(single.firstWordEndX)
        XCTAssertNotNil(Locator.caretX(for: single, precedingText: "Lo"))
    }

    /// A field whose caret is found on screen waits for it instead of a
    /// popup outside the field, unless finds there keep failing.
    @MainActor
    func testAFieldWhoseCaretIsFoundOnScreenIsKnown() {
        let visualCaret = CotypingVisualCaret()
        var viber = CotypingField(
            appName: "Viber", bundleID: "com.viber.osx", processID: 7, role: "AXTextField",
            precedingText: "Hey, are we", trailingText: "", selectionLength: 0,
            caretRect: CGRect(x: 2565, y: 180, width: 1, height: 17), inputFrameRect: CGRect(x: 2561, y: 180, width: 499, height: 17),
            isSecure: false, caretIsExact: false)
        XCTAssertFalse(visualCaret.canFind(viber, screenCaptureAllowed: { true }), "privacy not checked yet")
        visualCaret.notePermission(false, for: viber)
        XCTAssertFalse(visualCaret.canFind(viber, screenCaptureAllowed: { true }))
        visualCaret.notePermission(true, for: viber)
        XCTAssertTrue(visualCaret.canFind(viber, screenCaptureAllowed: { true }))
        XCTAssertFalse(visualCaret.canFind(viber, screenCaptureAllowed: { false }), "no Screen Recording")
        var midLine = viber
        midLine.trailingText = " later"
        XCTAssertFalse(visualCaret.canFind(midLine, screenCaptureAllowed: { true }))
        for _ in 0..<CotypingVisualCaretLocator.maximumFailedFinds { visualCaret.noteFailedFind(for: viber) }
        XCTAssertFalse(visualCaret.canFind(viber, screenCaptureAllowed: { true }), "finds keep failing")
        // Another field starts afresh, and a find that works clears the count.
        viber.inputFrameRect = CGRect(x: 2561, y: 180, width: 499, height: 34)
        XCTAssertTrue(visualCaret.canFind(viber, screenCaptureAllowed: { true }))
    }

    func testTypingIsFollowedWhenOnlyTheNewestTextIsKept() throws {
        let old = String(repeating: "a", count: 10) + " the earlier part of a long draft that keeps going"
        let new = String(old.dropFirst(3)) + " on"
        let change = try XCTUnwrap(Locator.change(from: old, to: new))
        XCTAssertEqual(change.text, " on")
        XCTAssertTrue(change.isAddition)
        let back = try XCTUnwrap(Locator.change(from: new, to: String(new.dropLast(2))))
        XCTAssertEqual(back.text, "on")
        XCTAssertFalse(back.isAddition)
    }

    /// The rect handed to the overlay puts the ghost's baseline on the line
    /// found, whichever way the overlay reads it.
    func testTheGhostIsDrawnOnTheBaselineFound() throws {
        let found = try XCTUnwrap(Locator.locate(
            lines: [line("Looks good, just a", baseline: 375)], precedingText: "Looks good, just a ", fieldFrame: field))
        let caret = Locator.caretRect(for: found, caretX: found.caretX)
        let font = CotypingGhostFontSizing.font(for: nil, caretHeight: caret.height, caretIsExact: true)
        XCTAssertEqual(font.pointSize, found.pointSize, accuracy: 0.3)
        XCTAssertEqual(CotypingInlineGhostLayout.firstBaseline(caretRect: caret, font: font), 375, accuracy: 0.5)
        // Also in the field's own font, when the field reports it.
        let reported = NSFont.systemFont(ofSize: 14)
        XCTAssertEqual(CotypingInlineGhostLayout.firstBaseline(caretRect: caret, font: reported), 375, accuracy: 0.5)
    }

    func testCaptureFollowsTheScreenCaptureExclusions() {
        func permits(app: String = "Google Chrome", bundle: String? = "com.google.Chrome", host: String? = nil,
                     secure: Bool = false, apps: [String] = [], domains: [String] = []) -> Bool {
            Locator.permitsCapture(appName: app, bundleID: bundle, host: host, isSecure: secure,
                                   excludedApps: apps, excludedDomains: domains)
        }
        XCTAssertTrue(permits())
        XCTAssertFalse(permits(secure: true))
        XCTAssertFalse(permits(apps: ["Google Chrome"]))
        // With a site excluded, a page must be known to be another site.
        XCTAssertFalse(permits(domains: ["bank.example"]))
        XCTAssertFalse(permits(host: "bank.example", domains: ["bank.example"]))
        XCTAssertTrue(permits(host: "github.com", domains: ["bank.example"]))
        XCTAssertTrue(permits(app: "TextEdit", bundle: "com.apple.TextEdit", domains: ["bank.example"]))
    }

    /// Chrome hands out a new element for the same field on every read; the
    /// caret found for it still applies, so it is not looked for again.
    @MainActor
    func testTheCaretFoundIsReusedWhenChromeHandsOutANewElement() throws {
        func chromeField(_ identity: String, text: String) -> CotypingField {
            CotypingField(
                appName: "Google Chrome", bundleID: "com.google.Chrome", processID: 42, role: "AXTextArea",
                focusIdentityKey: identity, precedingText: text, trailingText: "", selectionLength: 0,
                caretRect: CGRect(x: 1174, y: 381, width: 1, height: 22), inputFrameRect: self.field,
                isSecure: false, caretIsExact: false)
        }
        let found = try XCTUnwrap(Locator.locate(
            lines: [line("Looks good", baseline: 375)], precedingText: "Looks good", fieldFrame: self.field))
        let visualCaret = CotypingVisualCaret()
        visualCaret.remember(found, for: chromeField("element-1", text: "Looks good"))

        let next = visualCaret.resolve(chromeField("element-2", text: "Looks good, just"))
        XCTAssertTrue(next.caretIsExact)
        XCTAssertGreaterThan(next.caretRect.minX, found.caretX)
        XCTAssertEqual(next.fieldStyle?.fontPointSize, found.pointSize,
                       "the ghost is drawn at the size the caret moves by")
        // Another field of the same kind elsewhere, or other text: not reused.
        var moved = chromeField("element-3", text: "Looks good")
        moved.inputFrameRect = self.field.offsetBy(dx: 0, dy: -200)
        XCTAssertFalse(visualCaret.resolve(moved).caretIsExact)
        XCTAssertFalse(visualCaret.resolve(chromeField("element-4", text: "Something else")).caretIsExact)
    }

    /// On a non-Retina display the capture is scaled up to twice its point
    /// size, not left at its own pixels in a corner of a larger image.
    func testTheCaptureIsScaledToTwiceTheFieldsPointSize() {
        let display = CGRect(x: 0, y: 0, width: 3440, height: 1440)
        let config = CotypingVisualCaret.captureConfiguration(
            for: CGRect(x: 725, y: 279, width: 796, height: 103), screenFrame: display, backingScale: 1)
        XCTAssertTrue(config.scalesToFit)
        XCTAssertEqual(config.width, 1592)
        XCTAssertEqual(config.height, 206)
        XCTAssertEqual(config.sourceRect, CGRect(x: 725, y: 1058, width: 796, height: 103))
        let retina = CotypingVisualCaret.captureConfiguration(
            for: CGRect(x: -1500, y: -900, width: 400, height: 50),
            screenFrame: CGRect(x: -1728, y: -1117, width: 1728, height: 1117), backingScale: 2)
        XCTAssertEqual(retina.width, 800)
        XCTAssertEqual(retina.sourceRect, CGRect(x: 228, y: 850, width: 400, height: 50))
    }

    /// Renders a field like GitHub's and runs the real recognizer on it.
    func testRecognitionFindsTheCaretInARenderedField() throws {
        let size = CGSize(width: 797, height: 103)
        let font = NSFont.systemFont(ofSize: 14)
        let lines = ["Thanks for the quick review, I will push the fixes", "in a follow-up later today"]
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        var baselines: [CGFloat] = []
        for (index, text) in lines.enumerated() {
            let baseline = size.height - 12 - 21 * CGFloat(index) - 3.3 - font.ascender
            baselines.append(baseline)
            NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor(white: 0.12, alpha: 1)])
                .draw(at: CGPoint(x: 13, y: baseline + font.descender))
        }
        NSGraphicsContext.restoreGraphicsState()
        let image = try XCTUnwrap(rep.cgImage)

        let recognized = CotypingVisualCaret.recognize(image, frame: field)
        let found = try XCTUnwrap(Locator.locate(
            lines: recognized, precedingText: lines.joined(separator: " "), fieldFrame: field))
        let lastLineEnd = field.minX + 13 + CotypingInlineGhostLayout.width(of: lines[1], font: font)
        XCTAssertEqual(found.caretX, lastLineEnd, accuracy: 1.5)
        XCTAssertEqual(found.baseline, field.minY + baselines[1], accuracy: 1)
        XCTAssertEqual(found.pointSize, 14, accuracy: 0.7)
    }

    // MARK: - Waiting for a find

    /// A finished suggestion waits at most its budget for the caret, then is
    /// shown beside the field. The slow find is left running for next time.
    func testTheWaitForASlowFindEndsAtItsDeadline() async {
        let find = Task { _ = try? await Task.sleep(for: .seconds(5)) }
        defer { find.cancel() }
        let start = ContinuousClock.now
        await CotypingBoundedWait.wait(for: find, milliseconds: 50)
        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
        XCTAssertFalse(find.isCancelled, "only the wait ends; the find keeps running")
    }

    func testAFindThatFinishesFirstEndsTheWaitAtOnce() async {
        let find = Task { _ = try? await Task.sleep(for: .milliseconds(10)) }
        let start = ContinuousClock.now
        await CotypingBoundedWait.wait(for: find, milliseconds: 5_000)
        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
    }

    func testCancellingTheWaiterEndsTheWait() async {
        let find = Task { _ = try? await Task.sleep(for: .seconds(5)) }
        defer { find.cancel() }
        let start = ContinuousClock.now
        let waiter = Task { await CotypingBoundedWait.wait(for: find, milliseconds: 5_000) }
        waiter.cancel()
        await waiter.value
        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
    }

    @MainActor
    func testWithNoFindRunningThereIsNothingToWaitFor() async {
        let start = ContinuousClock.now
        await CotypingVisualCaret().waitForPending(milliseconds: 5_000)
        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
    }
}
