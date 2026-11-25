import AppKit
import SwiftUI
import XCTest
@testable import LokalBot

@MainActor
final class TimelineToolbarLayoutTests: XCTestCase {
    private struct MeasuredToolbar {
        let sidebar: NSRect
        let datePill: NSRect
        let trailing: NSRect
        let leadingInset: CGFloat
        let trailingInset: CGFloat
    }

    private func measureTimelineToolbar(day: Date) throws -> MeasuredToolbar {
        let app = AppState()
        let model = CaptureModel()
        model.selectDay(day, app: app)
        let root = NavigationSplitView {
            List { Text("Timeline") }
                .listStyle(.sidebar)
                .navigationSplitViewColumnWidth(min: LBTokens.Metric.sidebarMinWidth,
                                                ideal: LBTokens.Metric.sidebarWidth, max: 260)
        } detail: {
            TimelineContentView(model: model)
                .environmentObject(app)
        }
        let window = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: 1_200, height: 740),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        let host = NSHostingView(rootView: root)
        window.contentView = host
        defer { window.close() }

        for _ in 0..<8 {
            host.layoutSubtreeIfNeeded()
            window.layoutIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        let themeFrame = try XCTUnwrap(window.contentView?.superview)
        let hostingViews = toolbarHostingViews(in: themeFrame)
            .sorted { $0.convert($0.bounds, to: themeFrame).minX < $1.convert($1.bounds, to: themeFrame).minX }
        XCTAssertGreaterThanOrEqual(hostingViews.count, 3, "Timeline toolbar should host sidebar, date, and action items")

        let sidebarView = hostingViews[0]
        let dateView = try XCTUnwrap(hostingViews.dropFirst().first {
            $0.convert($0.bounds, to: themeFrame).minX < window.frame.width * 0.5 && $0.bounds.width > 80
        })
        let trailingView = try XCTUnwrap(hostingViews.first {
            $0.convert($0.bounds, to: themeFrame).minX > window.frame.width * 0.5
        })

        dateView.displayIfNeeded()
        let rootLayer = try XCTUnwrap(dateView.layer)
        let contentFrames = (rootLayer.sublayers ?? [])
            .filter { !String(describing: type(of: $0)).contains("Backing") && $0.frame.width > 0 && $0.frame.height > 0 }
            .map(\.frame)
        XCTAssertFalse(contentFrames.isEmpty, "Date toolbar pill should draw its label layers")

        let contentMinX = try XCTUnwrap(contentFrames.map(\.minX).min())
        let contentMaxX = try XCTUnwrap(contentFrames.map(\.maxX).max())
        return MeasuredToolbar(
            sidebar: sidebarView.convert(sidebarView.bounds, to: themeFrame),
            datePill: dateView.convert(dateView.bounds, to: themeFrame),
            trailing: trailingView.convert(trailingView.bounds, to: themeFrame),
            leadingInset: contentMinX,
            trailingInset: dateView.bounds.width - contentMaxX)
    }

    private func toolbarHostingViews(in view: NSView) -> [NSView] {
        let match = String(describing: type(of: view)).contains("ToolbarItemHostingView") ? [view] : []
        return match + view.subviews.flatMap { toolbarHostingViews(in: $0) }
    }

    func testDatePillHasSymmetricPaddingAlignedWithToolbarRowOnToday() throws {
        let measured = try measureTimelineToolbar(day: Date())
        XCTAssertGreaterThanOrEqual(measured.leadingInset, 4,
                                    "Date pill leading padding should clear the capsule edge")
        XCTAssertGreaterThanOrEqual(measured.trailingInset, 4,
                                    "Date pill trailing padding should clear the capsule edge when showing Today")
        XCTAssertEqual(measured.leadingInset, measured.trailingInset, accuracy: 1.5,
                       "Date pill leading and trailing padding should match")
        XCTAssertEqual(measured.datePill.minY, measured.sidebar.minY, accuracy: 1)
        XCTAssertEqual(measured.datePill.height, measured.sidebar.height, accuracy: 1)
        XCTAssertEqual(measured.datePill.minY, measured.trailing.minY, accuracy: 1)
        XCTAssertEqual(measured.datePill.height, measured.trailing.height, accuracy: 1)
    }

    func testDatePillKeepsSymmetricPaddingWithoutRelativeDayLabel() throws {
        let earlier = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -5, to: Date()))
        let measured = try measureTimelineToolbar(day: earlier)
        XCTAssertGreaterThanOrEqual(measured.leadingInset, 4)
        XCTAssertGreaterThanOrEqual(measured.trailingInset, 4)
        XCTAssertEqual(measured.leadingInset, measured.trailingInset, accuracy: 2.5)
    }
}
