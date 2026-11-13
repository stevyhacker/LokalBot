import AppKit
import SwiftUI
import XCTest
@testable import LokalBot

/// Hosts the main window's NavigationSplitView structure in an off-screen
/// full-size-content window, with no autosaved split, and checks how far the
/// window shrinks. From macOS 26 an `HSplitView` in the detail counted the
/// sidebar twice in the minimum width, and the titlebar and toolbar are counted
/// twice in the minimum height.
@MainActor
final class MainWindowMinimumSizeTests: XCTestCase {
    private func sidebar() -> some View {
        List { Text("Meetings") }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: LBTokens.Metric.sidebarMinWidth,
                                            ideal: LBTokens.Metric.sidebarWidth, max: 260)
    }

    /// Shrinks the hosted view toward `target` and returns the window and host.
    private func shrink(_ root: some View, to target: NSSize) -> (NSWindow, NSView) {
        let window = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: 1180, height: 740),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: root)
        window.contentView = host
        func settle() {
            for _ in 0..<5 {
                host.layoutSubtreeIfNeeded()
                window.layoutIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
        }
        settle()
        window.setFrame(NSRect(origin: window.frame.origin, size: target), display: false)
        settle()
        return (window, host)
    }

    func testMainWindowSplitShrinksToSidebarPlusPanes() throws {
        let panes = [LBTokens.Metric.contentColumnMinWidth, LBTokens.Metric.contentDetailMinWidth]
        let (window, host) = shrink(NavigationSplitView { sidebar() } detail: {
            HSplitView {
                Color.clear.frame(minWidth: panes[0], idealWidth: LBTokens.Metric.contentColumnWidth, maxWidth: 340)
                Color.clear.frame(minWidth: panes[1], maxWidth: .infinity, maxHeight: .infinity)
            }
            .detailSplitMinimumWidth(panes)
        }, to: NSSize(width: 700, height: 600))
        defer { window.close() }

        // macOS 26.6 settles about 8 pt wider than macOS 27 (885 vs 877);
        // counting the sidebar twice added its whole 216 pt width.
        let panesAndDivider = panes.reduce(0, +) + 1
        XCTAssertLessThanOrEqual(window.frame.width, LBTokens.Metric.sidebarWidth + panesAndDivider + 16,
                                 "The window must shrink to the sidebar plus the split's panes")
        func splits(in view: NSView) -> [NSSplitView] {
            ((view as? NSSplitView).map { [$0] } ?? []) + view.subviews.flatMap { splits(in: $0) }
        }
        let inner = try XCTUnwrap(splits(in: host).last)
        XCTAssertEqual(inner.arrangedSubviews.count, 2)
        XCTAssertGreaterThanOrEqual(inner.arrangedSubviews[0].frame.width, panes[0] - 1)
        XCTAssertGreaterThanOrEqual(inner.arrangedSubviews[1].frame.width, panes[1] - 1,
                                    "Neither pane may be squeezed below its minimum")
    }

    func testWorkspaceMinimumHeightCountsTheToolbarOnce() {
        let workspace: CGFloat = 600
        let (window, _) = shrink(NavigationSplitView { sidebar() } detail: {
            Color.clear.workspaceMinimumHeight(workspace)
        }, to: NSSize(width: 1000, height: 300))
        defer { window.close() }

        XCTAssertLessThanOrEqual(window.frame.height, workspace + WorkspaceMetric.toolbarHeight + 1,
                                 "The window must shrink to the workspace plus one toolbar")
    }
}
