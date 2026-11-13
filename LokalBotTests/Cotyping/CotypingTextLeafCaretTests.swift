import XCTest
@testable import LokalBot

/// The leaf-derived caret fallback for Chromium/Electron editables. The main
/// scenario's numbers are real: measured via an AX probe against Discord's
/// message composer (Slate contenteditable) with the draft "test this u".
final class CotypingTextLeafCaretTests: XCTestCase {
    private let composerFrame = CGRect(x: 455, y: 1052, width: 795, height: 56)
    private let composerLeaf = CotypingTextLeafCaret.Leaf(
        frame: CGRect(x: 455, y: 1069, width: 69, height: 22), text: "test this u")

    private func derive(
        leaves: [CotypingTextLeafCaret.Leaf],
        fieldText: String,
        caretLocation: Int,
        isRightToLeft: Bool = false
    ) -> CGRect? {
        CotypingTextLeafCaret.caretRect(
            elementFrame: composerFrame,
            leaves: leaves,
            fieldText: fieldText,
            caretLocation: caretLocation,
            isRightToLeft: isRightToLeft)
    }

    func testDiscordComposerCaretIsLeafTrailingEdge() {
        let rect = derive(leaves: [composerLeaf], fieldText: "test this u", caretLocation: 11)
        XCTAssertEqual(rect, CGRect(x: 524, y: 1069, width: 1, height: 22))
    }

    func testTrailingNewlineFromContenteditableIsTolerated() {
        // Draft/Slate keep a trailing "\n" in the reported value while the
        // caret index stays at the visible end of the text.
        let rect = derive(leaves: [composerLeaf], fieldText: "test this u\n", caretLocation: 11)
        XCTAssertEqual(rect?.origin.x, 524)
    }

    func testMidTextCaretRefusesDerivation() {
        XCTAssertNil(derive(leaves: [composerLeaf], fieldText: "test this u", caretLocation: 5))
    }

    func testCaretIsAtTextEndPreCheck() {
        XCTAssertTrue(CotypingTextLeafCaret.caretIsAtTextEnd(fieldText: "\n", caretLocation: 0))
        XCTAssertTrue(CotypingTextLeafCaret.caretIsAtTextEnd(fieldText: "ab\n", caretLocation: 2))
        XCTAssertFalse(CotypingTextLeafCaret.caretIsAtTextEnd(fieldText: "ab\ncd", caretLocation: 2))
        // After the line break the caret is on a new line.
        XCTAssertFalse(CotypingTextLeafCaret.caretIsAtTextEnd(fieldText: "ab\n", caretLocation: 3))
    }

    /// Return in a textarea starts a new line; the last run's edge is the end
    /// of the line above, not the caret.
    func testACaretOnANewLineAfterTheTextRefuses() {
        XCTAssertNil(derive(leaves: [composerLeaf], fieldText: "test this u\n", caretLocation: 12))
        XCTAssertNil(derive(leaves: [composerLeaf], fieldText: "test this u\n\n", caretLocation: 13))
    }

    /// A run can stop before a space typed at the end of the text. The caret
    /// is then one space past the run, so the suggestion does not touch the
    /// last word.
    func testASpaceTheRunLeavesOutMovesTheCaretOneSpace() throws {
        let rect = try XCTUnwrap(derive(leaves: [composerLeaf], fieldText: "test this u ", caretLocation: 12))
        XCTAssertGreaterThan(rect.origin.x, 524 + 3)
        XCTAssertLessThan(rect.origin.x, 524 + 6)
        XCTAssertEqual(rect.origin.y, 1069)

        let two = try XCTUnwrap(derive(leaves: [composerLeaf], fieldText: "test this u  ", caretLocation: 13))
        XCTAssertEqual(two.origin.x - 524, (rect.origin.x - 524) * 2, accuracy: 0.01)
    }

    func testASpaceInsideTheRunIsNotCountedAgain() {
        // Web editors keep a typed trailing space as a no-break space.
        let withSpace = CotypingTextLeafCaret.Leaf(
            frame: CGRect(x: 455, y: 1069, width: 73, height: 22), text: "test this u\u{00A0}")
        XCTAssertEqual(derive(leaves: [withSpace], fieldText: "test this u ", caretLocation: 12)?.origin.x, 528)
        XCTAssertEqual(derive(leaves: [withSpace], fieldText: "test this u\u{00A0}", caretLocation: 12)?.origin.x, 528)
        // A run with more trailing spaces than the field is not this text.
        XCTAssertNil(derive(leaves: [withSpace], fieldText: "test this u", caretLocation: 11))
    }

    func testRightToLeftMovesPastAMissingSpaceToTheLeft() throws {
        let word = "שלום"
        let rtlLeaf = CotypingTextLeafCaret.Leaf(
            frame: CGRect(
                x: 1100, y: 1069, width: CotypingInlineGhostLayout.width(of: word, font: .systemFont(ofSize: 16)),
                height: 22),
            text: word)
        let rect = try XCTUnwrap(derive(leaves: [rtlLeaf], fieldText: word + " ", caretLocation: 5, isRightToLeft: true))
        XCTAssertLessThan(rect.origin.x, 1100 - 3)
        XCTAssertGreaterThan(rect.origin.x, 1100 - 6)
    }

    /// A text node that wraps reports one box around all its lines. Its
    /// trailing edge is the end of the widest line, and a caret that tall puts
    /// the suggestion across both lines.
    func testARunThatWrapsOntoASecondLineRefuses() {
        let text = "Looks good, just a few minor things before we merge this one, thanks for the quick turnaround"
        let lineWidth = CotypingInlineGhostLayout.width(of: text, font: .systemFont(ofSize: 16))
        let field = CGRect(x: 455, y: 1052, width: lineWidth, height: 80)
        let oneLine = CotypingTextLeafCaret.Leaf(
            frame: CGRect(x: 455, y: 1060, width: lineWidth, height: 22), text: text)
        let wrapped = CotypingTextLeafCaret.Leaf(
            frame: CGRect(x: 455, y: 1060, width: (lineWidth / 2).rounded(.up), height: 44), text: text)
        func derive(_ leaf: CotypingTextLeafCaret.Leaf) -> CGRect? {
            CotypingTextLeafCaret.caretRect(
                elementFrame: field, leaves: [leaf], fieldText: text,
                caretLocation: (text as NSString).length, isRightToLeft: false)
        }
        XCTAssertEqual(derive(oneLine)?.origin.x, 455 + lineWidth)
        XCTAssertNil(derive(wrapped))
    }

    func testLastLeafOfStyledLineWins() {
        // A bold tail splits the line into two runs; the caret follows the last.
        let head = CotypingTextLeafCaret.Leaf(
            frame: CGRect(x: 455, y: 1069, width: 30, height: 22), text: "test ")
        let tail = CotypingTextLeafCaret.Leaf(
            frame: CGRect(x: 485, y: 1069, width: 39, height: 22), text: "this u")
        let rect = derive(leaves: [head, tail], fieldText: "test this u", caretLocation: 11)
        XCTAssertEqual(rect?.origin.x, 524)
    }

    func testNewlineOnlyLeavesAreSkipped() {
        let ghostRun = CotypingTextLeafCaret.Leaf(
            frame: CGRect(x: 455, y: 1091, width: 1, height: 22), text: "\n")
        let rect = derive(leaves: [composerLeaf, ghostRun], fieldText: "test this u", caretLocation: 11)
        XCTAssertEqual(rect?.origin.x, 524)
    }

    func testFieldTextNotEndingWithLastRunRefuses() {
        // A trailing emoji/mention the runs don't cover would put the caret
        // past the last text run — refuse rather than misplace the ghost.
        XCTAssertNil(derive(leaves: [composerLeaf], fieldText: "test this u😀", caretLocation: 13))
    }

    func testLeafOutsideElementFrameRefuses() {
        let strayLeaf = CotypingTextLeafCaret.Leaf(
            frame: CGRect(x: 1728, y: 82, width: 40, height: 19), text: "test this u")
        XCTAssertNil(derive(leaves: [strayLeaf], fieldText: "test this u", caretLocation: 11))
    }

    func testUnreasonableLineHeightRefuses() {
        let blockSizedLeaf = CotypingTextLeafCaret.Leaf(
            frame: CGRect(x: 455, y: 1052, width: 69, height: 200), text: "test this u")
        XCTAssertNil(derive(leaves: [blockSizedLeaf], fieldText: "test this u", caretLocation: 11))
    }

    func testNoLeavesRefuses() {
        XCTAssertNil(derive(leaves: [], fieldText: "\n", caretLocation: 0))
    }

    func testRightToLeftUsesLeadingEdge() {
        let rtlLeaf = CotypingTextLeafCaret.Leaf(
            frame: CGRect(x: 1100, y: 1069, width: 69, height: 22), text: "שלום")
        let rect = derive(leaves: [rtlLeaf], fieldText: "שלום", caretLocation: 4, isRightToLeft: true)
        XCTAssertEqual(rect?.origin.x, 1100)
    }
}

/// TextEdit and Telegram report the empty range at the caret one line above
/// where it is drawn, and Chrome reports it with no size; the character before
/// the caret is reported where it is.
final class CotypingCaretGeometryTests: XCTestCase {
    func testTheCaretIsTheTrailingEdgeOfTheCharacterBeforeIt() {
        // AX coordinates, top-left origin: the empty range sits a line high.
        let empty = CGRect(x: 721, y: 189.5, width: 3, height: 14)
        let character = CGRect(x: 714, y: 203.5, width: 7, height: 14)
        XCTAssertEqual(
            CotypingCaretGeometry.caret(emptyRangeRect: empty, previousCharacterRect: character, isRightToLeft: false),
            CGRect(x: 721, y: 203.5, width: 0, height: 14))
        XCTAssertEqual(
            CotypingCaretGeometry.caret(emptyRangeRect: empty, previousCharacterRect: character, isRightToLeft: true),
            CGRect(x: 714, y: 203.5, width: 0, height: 14))
    }

    func testTheEmptyRangeIsKeptWithoutAUsableCharacter() {
        let empty = CGRect(x: 40, y: 100, width: 1, height: 14)
        XCTAssertEqual(
            CotypingCaretGeometry.caret(emptyRangeRect: empty, previousCharacterRect: nil, isRightToLeft: false),
            empty)
        // A whole line or an empty rect is not one character.
        XCTAssertEqual(CotypingCaretGeometry.caret(
            emptyRangeRect: empty, previousCharacterRect: CGRect(x: 40, y: 100, width: 400, height: 14),
            isRightToLeft: false), empty)
        XCTAssertEqual(CotypingCaretGeometry.caret(
            emptyRangeRect: empty, previousCharacterRect: CGRect(x: 40, y: 100, width: 0, height: 0),
            isRightToLeft: false), empty)
    }

    /// A GitHub review box in Chrome: the empty range comes back with no size,
    /// which used to leave only a guess at the field's top-left corner.
    func testWithAZeroSizeEmptyRangeTheCharacterBeforeTheCaretPlacesIt() {
        let field = CGRect(x: 300, y: 200, width: 700, height: 130)
        let character = CGRect(x: 489, y: 209, width: 7, height: 20)
        for empty in [CGRect.zero, CGRect(x: 496, y: 209, width: 0, height: 0), nil] {
            XCTAssertEqual(
                CotypingCaretGeometry.caret(
                    emptyRangeRect: empty, previousCharacterRect: character, elementFrame: field,
                    isRightToLeft: false),
                CGRect(x: 496, y: 209, width: 0, height: 20))
        }
    }

    /// Without an empty range to agree with, a character is only trusted
    /// inside its own field.
    func testWithoutAnEmptyRangeACharacterOutsideTheFieldIsRefused() {
        let field = CGRect(x: 300, y: 200, width: 700, height: 130)
        XCTAssertNil(CotypingCaretGeometry.caret(
            emptyRangeRect: .zero, previousCharacterRect: CGRect(x: 0, y: 0, width: 7, height: 20),
            elementFrame: field, isRightToLeft: false))
        XCTAssertNil(CotypingCaretGeometry.caret(
            emptyRangeRect: .zero, previousCharacterRect: CGRect(x: 489, y: 209, width: 7, height: 20),
            elementFrame: nil, isRightToLeft: false))
        XCTAssertNil(CotypingCaretGeometry.caret(
            emptyRangeRect: nil, previousCharacterRect: nil, elementFrame: field, isRightToLeft: false))
    }

    /// The field's frame costs Accessibility calls; it is not read when the
    /// empty range already vouches for the character.
    func testTheFieldFrameIsReadOnlyWithoutAnEmptyRange() {
        var reads = 0
        func frame() -> CGRect? {
            reads += 1
            return CGRect(x: 300, y: 200, width: 700, height: 130)
        }
        let character = CGRect(x: 489, y: 209, width: 7, height: 20)
        _ = CotypingCaretGeometry.caret(
            emptyRangeRect: CGRect(x: 496, y: 195, width: 1, height: 20), previousCharacterRect: character,
            elementFrame: frame(), isRightToLeft: false)
        XCTAssertEqual(reads, 0)
        _ = CotypingCaretGeometry.caret(
            emptyRangeRect: .zero, previousCharacterRect: character, elementFrame: frame(), isRightToLeft: false)
        XCTAssertEqual(reads, 1)
    }
}
