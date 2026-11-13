import AppKit
import Foundation

guard CommandLine.arguments.count == 5,
      let width = Int(CommandLine.arguments[3]),
      let height = Int(CommandLine.arguments[4]),
      width > 0, height > 0 else {
    fputs("usage: render-svg <input.svg> <output.png> <width> <height>\n", stderr)
    exit(2)
}

let source = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let size = NSSize(width: width, height: height)
guard let image = NSImage(contentsOf: source),
      let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fputs("render-svg: could not decode or allocate bitmap\n", stderr)
    exit(1)
}

bitmap.size = size
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.imageInterpolation = .high
context.cgContext.clear(CGRect(origin: .zero, size: size))
image.draw(in: NSRect(origin: .zero, size: size),
           from: .zero,
           operation: .sourceOver,
           fraction: 1,
           respectFlipped: false,
           hints: [.interpolation: NSImageInterpolation.high.rawValue])
context.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

let export = bitmap.converting(to: .sRGB,
                               renderingIntent: .relativeColorimetric) ?? bitmap
export.size = size
guard let png = export.representation(using: .png, properties: [:]) else {
    fputs("render-svg: could not encode PNG\n", stderr)
    exit(1)
}
try png.write(to: output, options: .atomic)
