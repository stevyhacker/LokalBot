import AppKit
import CoreGraphics
import Foundation

/// The frontmost System Settings window converted into AppKit screen space.
struct SystemSettingsWindowSnapshot: Equatable {
    let processIdentifier: pid_t
    let frame: CGRect
    let visibleFrame: CGRect
}

/// Locates the privacy window so permission guidance can follow it across
/// displays and remain visually attached while it moves or resizes.
enum SystemSettingsWindowLocator {
    static let bundleIdentifier = "com.apple.systempreferences"

    private struct ScreenGeometry {
        let frame: CGRect
        let visibleFrame: CGRect
        let displayBounds: CGRect
    }

    static var isFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleIdentifier
    }

    static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }

    static func frontmostWindow() -> SystemSettingsWindowSnapshot? {
        guard isFrontmost,
              let application = NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleIdentifier)
                .max(by: { activationPriority(of: $0) < activationPriority(of: $1) }),
              let windowInfo = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                .zero) as? [[String: Any]] else {
            return nil
        }

        let candidates = windowInfo.compactMap { info -> SystemSettingsWindowSnapshot? in
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID == application.processIdentifier,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] else {
                return nil
            }

            let coreGraphicsFrame = CGRect(
                x: bounds["X"] ?? 0,
                y: bounds["Y"] ?? 0,
                width: bounds["Width"] ?? 0,
                height: bounds["Height"] ?? 0)
            let converted = appKitGeometry(from: coreGraphicsFrame)
            guard converted.frame.width > 320, converted.frame.height > 240 else {
                return nil
            }

            return SystemSettingsWindowSnapshot(
                processIdentifier: ownerPID,
                frame: converted.frame,
                visibleFrame: converted.visibleFrame)
        }

        return candidates.max(by: { area(of: $0.frame) < area(of: $1.frame) })
    }

    private static func activationPriority(of application: NSRunningApplication) -> Int {
        application.activationPolicy == .prohibited ? 0 : 1
    }

    private static func area(of rect: CGRect) -> CGFloat {
        rect.width * rect.height
    }

    private static func appKitGeometry(
        from coreGraphicsFrame: CGRect
    ) -> (frame: CGRect, visibleFrame: CGRect) {
        let screens = NSScreen.screens.compactMap { screen -> ScreenGeometry? in
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            return ScreenGeometry(
                frame: screen.frame,
                visibleFrame: screen.visibleFrame,
                displayBounds: CGDisplayBounds(CGDirectDisplayID(number.uint32Value)))
        }

        let matchedScreen = screens
            .filter { $0.displayBounds.intersects(coreGraphicsFrame) }
            .max {
                intersectionArea($0.displayBounds, coreGraphicsFrame)
                    < intersectionArea($1.displayBounds, coreGraphicsFrame)
            }

        guard let matchedScreen else {
            let visible = NSScreen.main?.visibleFrame
                ?? CGRect(origin: .zero, size: coreGraphicsFrame.size)
            return (coreGraphicsFrame, visible)
        }

        let localX = coreGraphicsFrame.minX - matchedScreen.displayBounds.minX
        let localY = coreGraphicsFrame.minY - matchedScreen.displayBounds.minY
        return (
            CGRect(
                x: matchedScreen.frame.minX + localX,
                y: matchedScreen.frame.maxY - localY - coreGraphicsFrame.height,
                width: coreGraphicsFrame.width,
                height: coreGraphicsFrame.height),
            matchedScreen.visibleFrame)
    }

    private static func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        return intersection.width * intersection.height
    }
}
