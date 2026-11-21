import AppKit
import ScreenCaptureKit

@MainActor
final class CotypingBackgroundSampler {
    private var cache: [String: (luminance: CGFloat, at: Date)] = [:]
    private static let cacheTTL: TimeInterval = 300

    func cachedLuminance(forField fieldKey: String?, now: Date = Date()) -> CGFloat? {
        guard let key = Self.key(fieldKey), let hit = cache[key],
              now.timeIntervalSince(hit.at) < Self.cacheTTL else { return nil }
        return hit.luminance
    }

    func remember(_ luminance: CGFloat, forField fieldKey: String?, now: Date = Date()) {
        guard let key = Self.key(fieldKey) else { return }
        cache = cache.filter { now.timeIntervalSince($0.value.at) < Self.cacheTTL }
        cache[key] = (luminance, now)
    }

    private static func key(_ fieldKey: String?) -> String? {
        guard let fieldKey else { return nil }
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return fieldKey + (dark ? "/dark" : "/light")
    }

    func sampleLuminance(at caretRect: CGRect, forField fieldKey: String?) async -> CGFloat? {
        guard CGPreflightScreenCaptureAccess(),
              let luminance = await Self.captureLuminance(at: caretRect) else { return nil }
        remember(luminance, forField: fieldKey)
        return luminance
    }

    private static func captureLuminance(at caretRect: CGRect) async -> CGFloat? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true) else { return nil }
        let center = CGPoint(x: caretRect.midX, y: caretRect.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) ?? NSScreen.main,
              let screenNumber = (screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,
              let display = content.displays.first(where: { $0.displayID == screenNumber }),
              let config = captureConfiguration(
                for: caretRect, screenFrame: screen.frame, backingScale: screen.backingScaleFactor)
        else { return nil }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        guard let image = try? await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: config) else { return nil }
        return averageLuminance(of: image)
    }

    nonisolated static func captureConfiguration(
        for caretRect: CGRect, screenFrame: CGRect, backingScale: CGFloat
    ) -> SCStreamConfiguration? {
        let strip = CGRect(
            x: caretRect.minX - screenFrame.minX,
            y: screenFrame.maxY - caretRect.maxY,
            width: max(caretRect.width, 1) + 160,
            height: max(caretRect.height, 8)
        ).intersection(CGRect(origin: .zero, size: screenFrame.size)).integral
        guard !strip.isEmpty else { return nil }
        let scale = max(backingScale, 1)
        let config = SCStreamConfiguration()
        config.sourceRect = strip
        config.width = Int((strip.width * scale).rounded())
        config.height = Int((strip.height * scale).rounded())
        config.scalesToFit = true
        config.showsCursor = false
        return config
    }

    nonisolated static func averageLuminance(of image: CGImage) -> CGFloat? {
        var pixel: [UInt8] = [0, 0, 0, 0]
        guard let ctx = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return 0.299 * CGFloat(pixel[0]) / 255
            + 0.587 * CGFloat(pixel[1]) / 255
            + 0.114 * CGFloat(pixel[2]) / 255
    }
}
