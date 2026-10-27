import AppKit
import ScreenCaptureKit

/// Samples the average luminance of the host pixels behind the cotyping caret,
/// reusing the same ScreenCaptureKit engine (and Screen Recording grant) as the
/// screenshot pipeline. `CGWindowListCreateImage` is unavailable on current
/// SDKs, so this is the supported way to read what's actually on screen.
///
/// The overlay panel sets `sharingType = .none`, so a capture never includes our
/// own ghost. Results are cached per field and light or dark mode: a field's
/// background rarely changes, and a fresh capture would recolor the ghost a
/// moment after it appears. Not per app: one browser shows light and dark pages.
@MainActor
final class CotypingBackgroundSampler {
    private var cache: [String: (luminance: CGFloat, at: Date)] = [:]
    private static let cacheTTL: TimeInterval = 300

    /// A still-fresh luminance for the field `fieldKey` names, used to color
    /// the ghost instantly (no capture, no flash) for repeat suggestions there.
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

    /// Capture the strip behind `caretRect` and return its average luminance
    /// (0…1), caching it for `fieldKey`. `nil` when Screen Recording isn't
    /// authorized or the capture fails — the caller keeps its AX/appearance guess.
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

    /// The strip to the right of the caret, where the ghost draws, in the
    /// display's top-left point space, captured at its own pixel size.
    /// ScreenCaptureKit widens a fractional source to whole points, fits it
    /// inside the output keeping its aspect, and leaves whatever lies off the
    /// display black. Measured 2026-10-05: a 166×17 pt strip asked for at
    /// 32×3 came back with its last 2–4 columns black, pulling a white field
    /// from 0.97 to 0.85. Whole points at the backing scale need no scaling;
    /// `scalesToFit` makes a scale mismatch stretch rather than leave black
    /// (without it ScreenCaptureKit only scales down). `nil` off the display.
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

    /// Mean Rec. 601 luminance of `image`, via a 1×1 downscale that averages it.
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
