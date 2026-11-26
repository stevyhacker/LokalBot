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
        window.orderBack(nil)
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

        let ink = try horizontalInkBounds(in: dateView)
        return MeasuredToolbar(
            sidebar: sidebarView.convert(sidebarView.bounds, to: themeFrame),
            datePill: dateView.convert(dateView.bounds, to: themeFrame),
            trailing: trailingView.convert(trailingView.bounds, to: themeFrame),
            leadingInset: ink.minX,
            trailingInset: dateView.bounds.width - ink.maxX)
    }

    private func horizontalInkBounds(in view: NSView) throws -> (minX: CGFloat, maxX: CGFloat) {
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        var minPixel = rep.pixelsWide
        var maxPixel = -1
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 {
                if x < minPixel { minPixel = x }
                if x > maxPixel { maxPixel = x }
            }
        }
        XCTAssertLessThan(minPixel, rep.pixelsWide, "Date toolbar pill should draw visible content")
        XCTAssertGreaterThanOrEqual(maxPixel, 0, "Date toolbar pill should draw visible content")
        return (CGFloat(minPixel) / scale, CGFloat(maxPixel + 1) / scale)
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
        XCTAssertEqual(measured.leadingInset, measured.trailingInset, accuracy: 2.0,
                       "Date pill leading and trailing padding should match")
        XCTAssertEqual(measured.datePill.midY, measured.sidebar.midY, accuracy: 1)
        XCTAssertEqual(measured.datePill.midY, measured.trailing.midY, accuracy: 1)
        XCTAssertEqual(measured.datePill.height, measured.trailing.height, accuracy: 1)
    }

    func testDatePillKeepsSymmetricPaddingWithoutRelativeDayLabel() throws {
        let earlier = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -5, to: Date()))
        let measured = try measureTimelineToolbar(day: earlier)
        XCTAssertGreaterThanOrEqual(measured.leadingInset, 4)
        XCTAssertGreaterThanOrEqual(measured.trailingInset, 4)
        XCTAssertEqual(measured.leadingInset, measured.trailingInset, accuracy: 3.0)
    }
}
