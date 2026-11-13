import AppKit
import XCTest
@testable import LokalBot

/// A recognized line measured from its pixels.
final class CotypingVisualCaretInkTests: XCTestCase {
    private typealias Ink = CotypingVisualCaretInk

    private let size = CGSize(width: 400, height: 40)
    private let inset: CGFloat = 8
    private let baseline: CGFloat = 14
    private let font = NSFont.systemFont(ofSize: 14)

    /// `text` drawn at `scale` pixels per point, with a caret bar after it and
    /// other ink where asked. Boxes as recognition gives them: normalized, y up.
    private func sample(
        _ text: String, scale: CGFloat = 2, caretX: CGFloat? = nil, background: CGColor = .white,
        extraInk: CGRect? = nil
    ) throws -> (bitmap: Ink.Bitmap, line: CGRect, word: CGRect) {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        context.scaleBy(x: scale, y: scale)
        context.setFillColor(background)
        context.fill(CGRect(origin: .zero, size: size))
        let ink = NSColor(white: 0.1, alpha: 1)
        context.textPosition = CGPoint(x: inset, y: baseline)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(
            string: text, attributes: [.font: font, .foregroundColor: ink])), context)
        context.setFillColor(ink.cgColor)
        if let caretX {
            context.fill(CGRect(x: caretX, y: baseline + font.descender, width: 1, height: font.ascender - font.descender))
        }
        if let extraInk { context.fill(extraInk) }
        let bitmap = try XCTUnwrap(Ink.Bitmap(try XCTUnwrap(context.makeImage())))
        let width = CotypingInlineGhostLayout.width(of: text, font: font)
        // A box as loose as accurate recognition's: a few points past the text.
        let box = CGRect(x: (inset - 1) / size.width, y: (baseline + font.descender - 1) / size.height,
                         width: (width + 5) / size.width, height: (font.ascender - font.descender + 2) / size.height)
        return (bitmap, box, box)
    }

    private func measure(_ sample: (bitmap: Ink.Bitmap, line: CGRect, word: CGRect), scale: CGFloat = 2, lastTyped: Character? = nil) -> Ink.Line? {
        Ink.measure(sample.bitmap, line: sample.line, firstWord: sample.word, lastWord: sample.word,
                    pixelsPerPoint: scale, lastTypedLetter: lastTyped)
    }

    func testTheLineIsMeasuredFromItsInkNotItsBox() throws {
        let text = "Сегодня вечером будет встреча"
        for scale in [CGFloat(1), 2, 3] {
            let found = try XCTUnwrap(measure(try sample(text, scale: scale), scale: scale, lastTyped: "а"), "\(scale)x")
            let end = inset + CotypingInlineGhostLayout.width(of: text, font: font)
            XCTAssertEqual(CGFloat(found.columns.upperBound) / scale, end, accuracy: 1.2, "\(scale)x")
            XCTAssertEqual(CGFloat(found.columns.lowerBound) / scale, inset, accuracy: 1.5, "\(scale)x")
            XCTAssertEqual(size.height - CGFloat(found.baselineRow) / scale, baseline, accuracy: 1, "\(scale)x")
            XCTAssertNil(found.caretColumns, "\(scale)x")
        }
    }

    func testACaretAfterASpaceIsToldFromTheText() throws {
        let word = "Сегодня вечером"
        let wordEnd = inset + CotypingInlineGhostLayout.width(of: word, font: font)
        let caretX = inset + CotypingInlineGhostLayout.width(of: word + " ", font: font)
        let found = try XCTUnwrap(measure(try sample(word, caretX: caretX), lastTyped: "м"))
        let caret = try XCTUnwrap(found.caretColumns)
        XCTAssertEqual(CGFloat(caret.lowerBound) / 2, caretX, accuracy: 0.6)
        XCTAssertEqual(CGFloat(found.columns.upperBound) / 2, wordEnd, accuracy: 1)
    }

    /// A caret right after the letter is the same run of ink as the letter.
    func testACaretTouchingTheLastLetterIsToldFromIt() throws {
        let word = "Сегодня вечером"
        let caretX = inset + CotypingInlineGhostLayout.width(of: word, font: font) - 0.5
        let found = try XCTUnwrap(measure(try sample(word, caretX: caretX), lastTyped: "м"))
        let caret = try XCTUnwrap(found.caretColumns)
        XCTAssertEqual(CGFloat(caret.lowerBound) / 2, caretX, accuracy: 0.6)
        XCTAssertLessThanOrEqual(found.columns.upperBound, caret.lowerBound)
    }

    /// Thin letters, and letters that reach below the baseline, are text.
    func testLettersAtTheEndAreNotTakenForACaret() throws {
        for text in ["Иди на рај", "Hello ball", "Купи кафу и ф", "Видео сам р", "Откуда 1", "Они су и", "Такође у", "Ћао, кућа ћ"] {
            let found = try XCTUnwrap(measure(try sample(text), lastTyped: text.last), text)
            XCTAssertNil(found.caretColumns, text)
        }
    }

    func testWordsAreCountedFromTheGapsInTheInk() throws {
        for (text, words) in [("Сегодня вечером будет", 3), ("Видимо се у г", 4), ("Жду", 1), ("Здраво, Ђорђе", 2), ("Ты и я", 3)] {
            for scale in [CGFloat(1), 2, 3] {
                let found = try XCTUnwrap(measure(try sample(text, scale: scale), scale: scale, lastTyped: text.last), text)
                XCTAssertEqual(found.wordCount, words, "\(text) at \(scale)x")
            }
        }
    }

    /// As tall as a caret and reaching as low, but not a straight bar.
    func testABracketOrASlashAtTheEndIsNotACaret() throws {
        for text in ["Видимо се (сутра)", "Видимо се [сутра]", "Видимо се и/или/"] {
            let found = try XCTUnwrap(measure(try sample(text), lastTyped: text.last), text)
            XCTAssertNil(found.caretColumns, text)
        }
    }

    /// Past the word's box and not shaped like a caret: an icon, not the text.
    func testInkPastTheLastWordIsNotText() throws {
        let text = "Сегодня"
        let end = inset + CotypingInlineGhostLayout.width(of: text, font: font)
        let found = try XCTUnwrap(measure(
            try sample(text, extraInk: CGRect(x: end + 12, y: baseline - 1, width: 10, height: 10)), lastTyped: "я"))
        XCTAssertEqual(CGFloat(found.columns.upperBound) / 2, end, accuracy: 1.5)
        XCTAssertNil(found.caretColumns)
    }

    func testAFieldBorderIsNotTakenForACaret() throws {
        let text = String(repeating: "Сегодня ", count: 3)
        let found = try XCTUnwrap(measure(
            try sample(text, extraInk: CGRect(x: size.width - 1, y: 0, width: 1, height: size.height)), lastTyped: "я"))
        XCTAssertNil(found.caretColumns)
    }

    /// Without a flat background, what is ink cannot be told from what is behind it.
    func testALineOverAPictureIsNotMeasured() throws {
        let width = 800, height = 80
        var pixels = [UInt8](repeating: 0, count: width * height)
        for index in pixels.indices { pixels[index] = UInt8(truncatingIfNeeded: index &* 2_654_435_761 >> 7) }
        let context = try XCTUnwrap(pixels.withUnsafeMutableBytes { bytes in
            CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        })
        let bitmap = try XCTUnwrap(Ink.Bitmap(try XCTUnwrap(context.makeImage())))
        let box = CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.5)
        XCTAssertNil(Ink.measure(bitmap, line: box, firstWord: box, lastWord: box, pixelsPerPoint: 2, lastTypedLetter: "а"))
    }
}
