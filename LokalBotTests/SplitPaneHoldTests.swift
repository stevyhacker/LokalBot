import AppKit
import SwiftUI
import XCTest
@testable import LokalBot

/// A real `HSplitView` in an off-screen window, laid out like the list-and-detail
/// workspaces. Selecting a row swaps the detail's content, which must not move
/// the divider: SwiftUI re-divides from the panes' ideal widths when it does.
@MainActor
final class SplitPaneHoldTests: XCTestCase {
    func testOnlyMouseDragsCountAsDividerDrags() {
        var detector = DividerDragDetector()
        XCTAssertFalse(detector.isDrag(currentEvent: nil))
        XCTAssertFalse(detector.isDrag(currentEvent: .leftMouseDown), "selecting a row")
        XCTAssertFalse(detector.isDrag(currentEvent: .leftMouseUp), "the end of a click")
        XCTAssertFalse(detector.isDrag(currentEvent: .keyDown))
        XCTAssertTrue(detector.isDrag(currentEvent: .leftMouseDragged))
        XCTAssertTrue(detector.isDrag(currentEvent: .leftMouseUp), "the drag's last step")
        XCTAssertFalse(detector.isDrag(currentEvent: .leftMouseUp), "only one step after the drag")
    }

    private final class Selection: ObservableObject {
        @Published var page = 0
    }

    private struct Workspace: View {
        @ObservedObject var selection: Selection
        let autosaveName: String

        var body: some View {
            HSplitView {
                List { Text("Northwind") }
                    .frame(minWidth: LBTokens.Metric.contentColumnMinWidth,
                           idealWidth: LBTokens.Metric.contentColumnWidth, maxWidth: 340)
                    .splitPaneAccessibilityLabel("List", autosaveName: autosaveName,
                                                 initialWidth: LBTokens.Metric.contentColumnWidth)
                detail
                    .frame(minWidth: LBTokens.Metric.contentDetailMinWidth, maxWidth: .infinity, maxHeight: .infinity)
                    .splitPaneAccessibilityLabel("Details")
            }
            .detailSplitMinimumWidth([LBTokens.Metric.contentColumnMinWidth, LBTokens.Metric.contentDetailMinWidth])
        }

        @ViewBuilder private var detail: some View {
            if selection.page == 0 {
                Text("Loading").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading) {
                        ForEach(0..<(selection.page * 6), id: \.self) { index in
                            Text("Page \(selection.page) line \(index): a long line of text about where the project stands now, long enough to wrap.")
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: 720, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .top)
                }
                .id(selection.page)
            }
        }
    }

    private func split(in view: NSView) -> NSSplitView? {
        if let split = view as? NSSplitView { return split }
        for child in view.subviews { if let found = split(in: child) { return found } }
        return nil
    }

    private func settle(_ seconds: TimeInterval = 0.6) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    func testSelectingARowKeepsTheColumnWidth() async throws {
        let name = "LokalBot.unit-tests.split-\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: "NSSplitView Subview Frames \(name)") }
        let selection = Selection()
        let host = NSHostingView(rootView: Workspace(selection: selection, autosaveName: name))
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 960, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }
        await settle()
        let splitView = try XCTUnwrap(split(in: host))
        let opening = splitView.arrangedSubviews[0].frame.width
        var resizes = 0
        let counter = NotificationCenter.default.addObserver(
            forName: NSSplitView.didResizeSubviewsNotification, object: splitView, queue: nil) { _ in resizes += 1 }
        defer { NotificationCenter.default.removeObserver(counter) }
        var widths = [opening]
        for page in 1...3 {
            selection.page = page
            await settle()
            widths.append(splitView.arrangedSubviews[0].frame.width)
        }
        print("SPLIT-WIDTHS", widths, resizes)
        XCTAssertLessThan(resizes, 200, "putting the width back must not fight SwiftUI's layout")
        // At rest the split stays at rest, or audits and tooltips never settle.
        let atRest = resizes
        await settle(1.5)
        XCTAssertEqual(resizes, atRest, "the split kept re-laying out while idle")
        // A window resize moves the sibling pane, and settles too.
        window.setContentSize(NSSize(width: 1_200, height: 700))
        await settle()
        XCTAssertEqual(splitView.arrangedSubviews[0].frame.width, opening, accuracy: 1)
        window.setContentSize(NSSize(width: 800, height: 600))
        await settle()
        XCTAssertEqual(splitView.arrangedSubviews[0].frame.width, opening, accuracy: 1)
        let afterResize = resizes
        await settle(1.5)
        XCTAssertEqual(resizes, afterResize, "the split kept re-laying out after a window resize")
        XCTAssertEqual(opening, LBTokens.Metric.contentColumnWidth, accuracy: 1)
        for width in widths { XCTAssertEqual(width, opening, accuracy: 1, "\(widths)") }
    }
}
