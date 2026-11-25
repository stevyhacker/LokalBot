import AppKit
import CoreGraphics

enum SyntheticWindowImage {
    static func make(width: Int = 1_500, height: Int = 1_000, caret: Bool, lineCount: Int = 12) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 0.97, green: 0.97, blue: 0.96, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1))
        for line in 0..<lineCount {
            var x = 60
            let y = height - 80 - line * 60
            for word in 0..<14 {
                let length = 30 + (line * 7 + word * 13) % 70
                context.fill(CGRect(x: x, y: y, width: length, height: 18))
                x += length + 14
            }
        }
        if caret {
            context.fill(CGRect(x: 640, y: height - 80 - lineCount * 60, width: 2, height: 22))
        }
        return context.makeImage()
    }

    static func rendered(width: Int = 1_500, height: Int = 1_000) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 26),
                                                         .foregroundColor: NSColor.black]
        for line in 0..<22 {
            let text = "Line \(line + 1): the design review moved to Thursday; budget notes and launch checklist"
            NSAttributedString(string: text, attributes: attributes)
                .draw(at: CGPoint(x: 40, y: height - 60 - line * 42))
        }
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }
}
