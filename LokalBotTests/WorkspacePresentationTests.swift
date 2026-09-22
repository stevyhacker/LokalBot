import XCTest
import AppKit
import SwiftUI
@testable import LokalBot

final class WorkspacePresentationTests: XCTestCase {
    func testReducedMotionDisablesEverySharedWorkspaceAnimation() {
        XCTAssertNil(WorkspaceMotion.animation(.selection, reduceMotion: true))
        XCTAssertNil(WorkspaceMotion.animation(.disclosure, reduceMotion: true))
        XCTAssertNil(WorkspaceMotion.animation(.drawer, reduceMotion: true))
        XCTAssertNil(WorkspaceMotion.animation(.autoScroll, reduceMotion: true))

        XCTAssertNotNil(WorkspaceMotion.animation(.disclosure, reduceMotion: false))
        XCTAssertNotNil(WorkspaceMotion.animation(.selection, reduceMotion: false))
        XCTAssertNotNil(WorkspaceMotion.animation(.drawer, reduceMotion: false))
        XCTAssertNotNil(WorkspaceMotion.animation(.autoScroll, reduceMotion: false))
    }

    func testReadingAndTimelineWidthsStayWithinApprovedPolicy() {
        XCTAssertGreaterThanOrEqual(WorkspaceMetric.readingMaxWidth, 720)
        XCTAssertLessThanOrEqual(WorkspaceMetric.readingMaxWidth, 800)
        XCTAssertGreaterThanOrEqual(WorkspaceMetric.timelineContextMinWidth, 420)
        XCTAssertGreaterThan(
            WorkspaceMetric.timelineDrawerBreakpoint,
            WorkspaceMetric.timelineContextMinWidth + 360)
    }

    func testCompactRadiusTokensAreNamedAndOrdered() {
        XCTAssertLessThan(Brand.Radius.tab, Brand.Radius.row)
        XCTAssertLessThan(Brand.Radius.row, Brand.Radius.control)
        XCTAssertLessThan(Brand.Radius.control, Brand.Radius.compactPanel)
        XCTAssertLessThan(Brand.Radius.compactPanel, Brand.Radius.panel)
    }

    @MainActor
    func testSupportingTextContrastOnWorkspaceSurfaces() throws {
        for (name, scheme) in [(NSAppearance.Name.aqua, ColorScheme.light), (.darkAqua, .dark)] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            var ratios: [Double] = []
            appearance.performAsCurrentDrawingAppearance {
                for textColor in [WorkspaceTextColor.supporting, WorkspaceTextColor.warning] {
                    let foreground = luminance(textColor)
                    for surface in [WorkspacePalette.canvas(for: scheme), WorkspacePalette.surface(for: scheme),
                                    WorkspacePalette.control(for: scheme)] {
                        let background = luminance(NSColor(surface))
                        ratios.append((max(foreground, background) + 0.05) / (min(foreground, background) + 0.05))
                    }
                }
            }
            XCTAssertTrue(ratios.allSatisfy { $0 >= 4.5 }, "\(name): \(ratios)")
        }
    }

    private func luminance(_ color: NSColor) -> Double {
        guard let rgb = color.usingColorSpace(.sRGB) else { return 0 }
        func linear(_ value: CGFloat) -> Double {
            let value = Double(value)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
    }
}
