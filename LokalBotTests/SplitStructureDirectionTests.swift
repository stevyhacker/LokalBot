import AppKit
import SwiftUI
import XCTest
@testable import LokalBot

/// On hosted macOS 26, opening Settings after launching in Urdu or Egyptian
/// Arabic quit the app: a split view appearing in a right-to-left
/// NavigationSplitView's detail never finished updating its constraints. There
/// the splits are built left-to-right and their panes keep the interface's
/// direction.
@MainActor
final class SplitStructureDirectionTests: XCTestCase {
    private final class Seen {
        var paneDirections: [String: LayoutDirection] = [:]
    }

    private struct DirectionProbe: View {
        @Environment(\.layoutDirection) private var direction
        let name: String
        let seen: Seen

        var body: some View {
            Color.clear.onChange(of: direction, initial: true) { seen.paneDirections[name] = direction }
        }
    }

    private func splits(in view: NSView) -> [NSSplitView] {
        ((view as? NSSplitView).map { [$0] } ?? []) + view.subviews.flatMap { splits(in: $0) }
    }

    /// The main window's shape: a sidebar and, in the detail, a list beside a
    /// page, in a right-to-left interface with the splits held left-to-right.
    /// The arrangement without the hold is never hosted: hosted unit tests run
    /// on macOS 26, where it is the one that fails.
    private func host() async -> (window: NSWindow, seen: Seen) {
        let seen = Seen()
        let root = NavigationSplitView {
            List { Text("Meetings") }
                .listStyle(.sidebar)
                .background(DirectionProbe(name: "sidebar", seen: seen))
                .splitPaneAccessibilityLabel("Workspace navigation")
        } detail: {
            HSplitView {
                List { Text("General") }
                    .background(DirectionProbe(name: "list", seen: seen))
                    .frame(minWidth: 210, idealWidth: 240, maxWidth: 280)
                    .splitPaneAccessibilityLabel("Settings navigation", initialWidth: 240)
                DirectionProbe(name: "page", seen: seen)
                    .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
                    .splitPaneAccessibilityLabel("General")
            }
            .detailSplitMinimumWidth([210, 400])
            .splitPaneAccessibilityLabel("Workspace content")
        }
        .splitStructureDirection()
        .environment(\.holdsSplitStructureLeftToRight, true)
        .environment(\.layoutDirection, .rightToLeft)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 1_180, height: 740),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: root)
        window.orderBack(nil)
        try? await Task.sleep(for: .seconds(1))
        return (window, seen)
    }

    func testOnlyMacOS26HoldsTheSplitsLeftToRight() {
        XCTAssertFalse(SplitStructureDirection.isHeldLeftToRight(onMacOS: 15))
        XCTAssertTrue(SplitStructureDirection.isHeldLeftToRight(onMacOS: 26))
        XCTAssertFalse(SplitStructureDirection.isHeldLeftToRight(onMacOS: 27))
    }

    func testHeldSplitsAreLeftToRightAndTheirPanesStayRightToLeft() async throws {
        let (window, seen) = await host()
        defer { window.close() }
        let all = splits(in: try XCTUnwrap(window.contentView))
        XCTAssertEqual(all.count, 2, "the window's split and the detail's")
        for split in all {
            XCTAssertEqual(split.userInterfaceLayoutDirection, .leftToRight)
        }
        XCTAssertEqual(seen.paneDirections, ["sidebar": .rightToLeft, "list": .rightToLeft, "page": .rightToLeft])
        // The list is the detail's first pane, beside the sidebar on the left.
        let inner = try XCTUnwrap(all.last)
        XCTAssertLessThan(inner.arrangedSubviews[0].frame.minX, inner.arrangedSubviews[1].frame.minX)
    }
}
