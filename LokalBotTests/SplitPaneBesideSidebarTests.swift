import AppKit
import SwiftUI
import XCTest
@testable import LokalBot

/// The list-and-detail workspaces sit in the main window's detail column. From
/// macOS 26 that column runs under the sidebar, so the list pane's frame is
/// wider than the list by the sidebar's width. On hosted macOS 26 the Projects
/// list therefore opened at its minimum width, and selecting a project widened
/// it to its maximum. No divider position is saved, so nothing is written to
/// the preferences.
@MainActor
final class SplitPaneBesideSidebarTests: XCTestCase {
    private final class Selection: ObservableObject {
        @Published var page = 0
    }

    /// The list as it shows: a view the size of the list's content.
    private final class ListWidth {
        weak var view: NSView?
        var value: CGFloat { view?.frame.width ?? 0 }
    }

    private struct WidthProbe: NSViewRepresentable {
        let width: ListWidth

        func makeNSView(context: Context) -> NSView {
            let view = NSView()
            width.view = view
            return view
        }

        func updateNSView(_ view: NSView, context: Context) {}
    }

    private struct Workspace: View {
        @ObservedObject var selection: Selection
        let listWidth: ListWidth

        var body: some View {
            HSplitView {
                List { Text("Northwind") }
                    .background(WidthProbe(width: listWidth))
                    .frame(minWidth: LBTokens.Metric.contentColumnMinWidth,
                           idealWidth: LBTokens.Metric.contentColumnWidth, maxWidth: 340)
                    .splitPaneAccessibilityLabel("List", initialWidth: LBTokens.Metric.contentColumnWidth)
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

    private func settle(_ seconds: TimeInterval = 0.6) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private func assertListKeepsItsOpeningWidth(_ direction: LayoutDirection) async {
        let selection = Selection()
        let listWidth = ListWidth()
        let root = NavigationSplitView {
            List { Text("Meetings") }
                .listStyle(.sidebar)
                .navigationSplitViewColumnWidth(min: LBTokens.Metric.sidebarMinWidth,
                                                ideal: LBTokens.Metric.sidebarWidth, max: 260)
        } detail: {
            Workspace(selection: selection, listWidth: listWidth)
        }
        // As in the main window: macOS 26 cannot lay out a right-to-left split
        // here, and hosted unit tests run on it.
        .splitStructureDirection()
        .environment(\.layoutDirection, direction)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 1_440, height: 900),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: root)
        window.orderBack(nil)
        defer { window.close() }
        await settle(1.2)
        XCTAssertEqual(listWidth.value, LBTokens.Metric.contentColumnWidth, accuracy: 1,
                       "\(direction): the list must open at its opening width, not at an edge of its range")
        for page in 1...3 {
            selection.page = page
            await settle()
            XCTAssertEqual(listWidth.value, LBTokens.Metric.contentColumnWidth, accuracy: 1,
                           "\(direction): showing page \(page) in the detail must not move the divider")
        }
        window.setContentSize(NSSize(width: 1_180, height: 740))
        await settle()
        XCTAssertEqual(listWidth.value, LBTokens.Metric.contentColumnWidth, accuracy: 1,
                       "\(direction): a narrower window takes its width from the detail")
    }

    func testListBesideTheSidebarOpensAtItsWidthAndKeepsIt() async {
        await assertListKeepsItsOpeningWidth(.leftToRight)
    }

    func testRightToLeftListBesideTheSidebarOpensAtItsWidthAndKeepsIt() async {
        await assertListKeepsItsOpeningWidth(.rightToLeft)
    }
}
