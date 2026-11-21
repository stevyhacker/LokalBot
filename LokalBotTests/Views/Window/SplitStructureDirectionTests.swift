import AppKit
import SwiftUI
import XCTest
@testable import LokalBot

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
        let inner = try XCTUnwrap(all.last)
        XCTAssertLessThan(inner.arrangedSubviews[0].frame.minX, inner.arrangedSubviews[1].frame.minX)
    }
}
