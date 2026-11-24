import AppKit
import SwiftUI
import XCTest
@testable import LokalBot

@MainActor
final class MenuBarRowLayoutTests: XCTestCase {
    private func heights<V: View>(
        for view: V,
        width: CGFloat = MenuBarMetric.panelWidth
    ) -> (minimum: CGFloat, ideal: CGFloat) {
        let controller = NSHostingController(rootView: view.frame(width: width))
        let minimum = controller.sizeThatFits(in: CGSize(width: width, height: 0)).height
        let ideal = controller.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
        return (minimum, ideal)
    }

    func testLastDictationRowDoesNotShrinkBelowItsTwoLineHeight() {
        let entry = DictationHistoryEntry(
            id: UUID(),
            text: "Things may have played out differently in the end",
            date: Date(timeIntervalSince1970: 1_700_000_000),
            outcome: .copied,
            appName: "Notes")
        let row = LastDictationMenuRow(
            entries: [entry],
            localized: { $0 },
            copy: { _ in true })
        let measured = heights(for: row)

        XCTAssertEqual(measured.minimum, measured.ideal, accuracy: 0.5,
                       "MenuBarExtra sizes to minimum height, so a two-line row must not compress below its ideal height")
        XCTAssertGreaterThan(measured.minimum, MenuBarMetric.rowHeight + 10,
                             "A two-line row needs vertical room for both lines and top/bottom padding")
    }

    func testSingleLineRowKeepsMinimumHeightAndGrowsAtLargeTextSize() {
        let row = Button {} label: {
            MenuBarRowLabel(title: Text("Quick Recall…"), icon: "magnifyingglass") {
                MenuBarShortcutText(label: "⌃⇧ Space")
            }
        }
        .buttonStyle(MenuBarRowStyle())

        let defaultHeights = heights(for: row)
        XCTAssertEqual(defaultHeights.minimum, MenuBarMetric.rowHeight, accuracy: 0.5)
        XCTAssertEqual(defaultHeights.ideal, MenuBarMetric.rowHeight, accuracy: 0.5)

        let largeScale: CGFloat = 1.4
        let largeWidth = (MenuBarMetric.panelWidth * largeScale).rounded()
        let largeHeights = heights(
            for: row.environment(\.appTextScale, largeScale),
            width: largeWidth)
        XCTAssertEqual(largeHeights.minimum, largeHeights.ideal, accuracy: 0.5)
        XCTAssertGreaterThan(largeHeights.minimum, MenuBarMetric.rowHeight)
    }

    func testSwitchRowDoesNotShrinkAtLargeTextSize() {
        let largeScale: CGFloat = 1.4
        let largeWidth = (MenuBarMetric.panelWidth * largeScale).rounded()
        let row = MenuBarSwitchRow(
            title: "Autocomplete",
            icon: "character.cursor.ibeam",
            help: "Turn inline autocomplete on or off",
            isOn: .constant(true))
            .environment(\.appTextScale, largeScale)

        let measured = heights(for: row, width: largeWidth)
        XCTAssertEqual(measured.minimum, measured.ideal, accuracy: 0.5)
    }
}
