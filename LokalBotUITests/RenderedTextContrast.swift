import AppKit

/// Measures the contrast of text in a capture of one accessibility element, for
/// the labels the system's contrast audit flags.
enum RenderedTextContrast {
    /// The dominant color is the background. Anti-aliasing spreads thin glyphs
    /// over many edge shades, so the glyph color is the contrast reached by the
    /// most contrasting tenth of glyph pixels rather than one repeated color.
    /// Returns nil without a uniform background or enough glyph pixels, which
    /// rejects blank captures and isolated dark pixels.
    ///
    /// Two things in a capture are neither background nor glyph. Text drawn
    /// over a material leaves a faint halo one or two levels off the
    /// background (macOS 26 does this to small captions), which still counts
    /// as background when deciding whether it is uniform. And an element such
    /// as a toolbar title can span its whole bar, so the capture includes the
    /// window's edge highlight and the bar's separator: a line of one color
    /// across the capture is a rule, not text, and is left out.
    static func ratio(of bitmap: NSBitmapImageRep) -> Double? {
        let width = bitmap.pixelsWide, height = bitmap.pixelsHigh
        let pixels = width * height
        guard pixels > 0, let image = bitmap.cgImage,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let bytes = UnsafeMutablePointer<UInt8>.allocate(capacity: pixels * 4)
        bytes.initialize(repeating: 0, count: pixels * 4)
        defer { bytes.deallocate() }
        guard let context = CGContext(
            data: bytes, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        func color(_ x: Int, _ y: Int) -> Int {
            let offset = (y * width + x) * 4
            return (Int(bytes[offset]) << 16) | (Int(bytes[offset + 1]) << 8) | Int(bytes[offset + 2])
        }
        var everyColor: [Int: Int] = [:]
        for y in 0..<height { for x in 0..<width { everyColor[color(x, y), default: 0] += 1 } }
        guard let background = everyColor.max(by: { $0.value < $1.value })?.key else { return nil }
        func isBackground(_ rgb: Int) -> Bool {
            abs(((rgb >> 16) & 255) - ((background >> 16) & 255)) <= haloTolerance
                && abs(((rgb >> 8) & 255) - ((background >> 8) & 255)) <= haloTolerance
                && abs((rgb & 255) - (background & 255)) <= haloTolerance
        }
        /// True when one color that is not the background fills the line.
        func isRule(length: Int, _ colorAt: (Int) -> Int) -> Bool {
            var line: [Int: Int] = [:]
            for index in 0..<length { line[colorAt(index), default: 0] += 1 }
            guard let most = line.max(by: { $0.value < $1.value }), !isBackground(most.key) else { return false }
            return most.value * 10 >= length * 9
        }
        let ruleRows = Set((0..<height).filter { y in isRule(length: width) { color($0, y) } })
        let ruleColumns = Set((0..<width).filter { x in isRule(length: height) { color(x, $0) } })

        var counts: [Int: Int] = [:]
        var measured = 0, backgroundPixels = 0
        for y in 0..<height where !ruleRows.contains(y) {
            for x in 0..<width where !ruleColumns.contains(x) {
                let rgb = color(x, y)
                measured += 1
                if isBackground(rgb) { backgroundPixels += 1 }
                counts[rgb, default: 0] += 1
            }
        }
        guard backgroundPixels > measured / 2 else { return nil }
        func linear(_ byte: Int) -> Double {
            let value = Double(byte) / 255.0
            if value <= 0.04045 { return value / 12.92 }
            return pow((value + 0.055) / 1.055, 2.4)
        }
        func luminance(_ rgb: Int) -> Double {
            let red = linear((rgb >> 16) & 255)
            let green = linear((rgb >> 8) & 255)
            let blue = linear(rgb & 255)
            return red * 0.2126 + green * 0.7152 + blue * 0.0722
        }
        let backgroundLuminance = luminance(background)
        var glyph: [(ratio: Double, count: Int)] = []
        var glyphPixels = 0
        for (rgb, count) in counts where rgb != background {
            let foreground = luminance(rgb)
            let ratio = (max(foreground, backgroundLuminance) + 0.05)
                / (min(foreground, backgroundLuminance) + 0.05)
            // Edge shades barely distinct from the background are not glyph.
            guard ratio >= 1.25 else { continue }
            glyph.append((ratio, count))
            glyphPixels += count
        }
        guard glyphPixels >= 20 else { return nil }
        var covered = 0
        for entry in glyph.sorted(by: { $0.ratio > $1.ratio }) {
            covered += entry.count
            if covered * 10 >= glyphPixels { return entry.ratio }
        }
        return nil
    }

    /// How far, per 8-bit channel, a halo pixel may sit from the background.
    private static let haloTolerance = 4
}
