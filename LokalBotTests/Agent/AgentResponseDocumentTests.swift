import AppKit
import XCTest
@testable import LokalBot

@MainActor
final class AgentResponseDocumentTests: XCTestCase {
    func testSharedParserPreservesContentAndLinksAcrossNativeRendering() throws {
        let markdown = """
        ## Overview

        A **strong** point and [source](lokalbot-source://meeting/123).

        - Parent
          - Child with `notes.md`
        12. Ordered item
        - [x] Done

        ```swift
        let value = 1
        ```

        | Name | State |
        | --- | --- |
        | Agent | Ready |
        """
        let document = AgentResponseDocument.render(markdown, fontSize: 15)
        XCTAssertEqual(document.string, SelectableDigestText.searchableText(from: markdown))
        let source = (document.string as NSString).range(of: "source")
        XCTAssertEqual(document.attribute(.link, at: source.location, effectiveRange: nil) as? URL,
                       URL(string: "lokalbot-source://meeting/123"))
        let code = (document.string as NSString).range(of: "notes.md")
        XCTAssertNotNil(document.attribute(.backgroundColor, at: code.location, effectiveRange: nil))
    }

    func testHeadingScaleTracksReadingSizeAndStandaloneBoldLabels() throws {
        for size: CGFloat in [12, 15, 20] {
            let document = AgentResponseDocument.render("## Heading\n\n**Section label**\n\nBody with **emphasis**.", fontSize: size)
            let heading = try font(in: document, at: "Heading")
            let section = try font(in: document, at: "Section label")
            let body = try font(in: document, at: "Body")
            let emphasis = try font(in: document, at: "emphasis")
            XCTAssertEqual(body.pointSize, size)
            XCTAssertEqual(heading.pointSize, size + 3)
            XCTAssertEqual(section.pointSize, heading.pointSize)
            XCTAssertEqual(emphasis.pointSize, body.pointSize)
        }
    }

    func testWrappedListLinesHaveHangingIndentsWithoutChangingCopiedText() throws {
        let document = AgentResponseDocument.render("- A long parent item\n  - A nested item\n12. An ordered item", fontSize: 15)
        let parent = try paragraph(in: document, at: "A long")
        let nested = try paragraph(in: document, at: "A nested")
        let ordered = try paragraph(in: document, at: "An ordered")
        XCTAssertGreaterThan(parent.headIndent, parent.firstLineHeadIndent)
        XCTAssertGreaterThan(nested.headIndent, parent.headIndent)
        XCTAssertGreaterThan(ordered.headIndent, parent.headIndent)
        XCTAssertEqual(document.string, "• A long parent item\n  • A nested item\n12. An ordered item")
    }

    func testFindHighlightDoesNotDropLinksOrParagraphAttributes() throws {
        let document = AgentResponseDocument.render("## Notes\n\n- [Meeting notes](https://example.com/notes)", fontSize: 15, searchQuery: "notes")
        let first = (document.string as NSString).range(of: "Notes")
        let link = (document.string as NSString).range(of: "Meeting notes")
        XCTAssertNotNil(document.attribute(.backgroundColor, at: first.location, effectiveRange: nil))
        XCTAssertNotNil(document.attribute(.backgroundColor, at: link.location + 8, effectiveRange: nil))
        XCTAssertNotNil(document.attribute(.link, at: link.location, effectiveRange: nil))
        XCTAssertGreaterThan(try paragraph(in: document, at: "Meeting").headIndent, 0)
    }

    private func font(in document: NSAttributedString, at text: String) throws -> NSFont {
        let range = (document.string as NSString).range(of: text)
        return try XCTUnwrap(document.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)
    }

    private func paragraph(in document: NSAttributedString, at text: String) throws -> NSParagraphStyle {
        let range = (document.string as NSString).range(of: text)
        return try XCTUnwrap(document.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)
    }
}
