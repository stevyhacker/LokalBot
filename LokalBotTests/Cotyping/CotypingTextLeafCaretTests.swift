import XCTest
@testable import LokalBot

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
        XCTAssertFalse(CotypingTextLeafCaret.caretIsAtTextEnd(fieldText: "ab\n", caretLocation: 3))
    }

    func testACaretOnANewLineAfterTheTextRefuses() {
        XCTAssertNil(derive(leaves: [composerLeaf], fieldText: "test this u\n", caretLocation: 12))
        XCTAssertNil(derive(leaves: [composerLeaf], fieldText: "test this u\n\n", caretLocation: 13))
    }

    func testASpaceTheRunLeavesOutMovesTheCaretOneSpace() throws {
        let rect = try XCTUnwrap(derive(leaves: [composerLeaf], fieldText: "test this u ", caretLocation: 12))
        XCTAssertGreaterThan(rect.origin.x, 524 + 3)
        XCTAssertLessThan(rect.origin.x, 524 + 6)
        XCTAssertEqual(rect.origin.y, 1069)

        let two = try XCTUnwrap(derive(leaves: [composerLeaf], fieldText: "test this u  ", caretLocation: 13))
        XCTAssertEqual(two.origin.x - 524, (rect.origin.x - 524) * 2, accuracy: 0.01)
    }

    func testASpaceInsideTheRunIsNotCountedAgain() {
        let withSpace = CotypingTextLeafCaret.Leaf(
            frame: CGRect(x: 455, y: 1069, width: 73, height: 22), text: "test this u\u{00A0}")
        XCTAssertEqual(derive(leaves: [withSpace], fieldText: "test this u ", caretLocation: 12)?.origin.x, 528)
        XCTAssertEqual(derive(leaves: [withSpace], fieldText: "test this u\u{00A0}", caretLocation: 12)?.origin.x, 528)
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

final class CotypingCaretGeometryTests: XCTestCase {
    func testTheCaretIsTheTrailingEdgeOfTheCharacterBeforeIt() {
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
        XCTAssertEqual(CotypingCaretGeometry.caret(
            emptyRangeRect: empty, previousCharacterRect: CGRect(x: 40, y: 100, width: 400, height: 14),
            isRightToLeft: false), empty)
        XCTAssertEqual(CotypingCaretGeometry.caret(
            emptyRangeRect: empty, previousCharacterRect: CGRect(x: 40, y: 100, width: 0, height: 0),
            isRightToLeft: false), empty)
    }

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
